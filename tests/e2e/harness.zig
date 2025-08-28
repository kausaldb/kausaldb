//! Core E2E test harness for KausalDB binary interface testing.
//!
//! Provides unified utilities for executing the KausalDB binary, managing
//! test environments, and validating command outputs. Eliminates duplication
//! across e2e test files and ensures consistent test isolation.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

/// Result of executing a KausalDB command
pub const CommandResult = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CommandResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }

    pub fn expect_success(self: *const CommandResult) !void {
        if (self.exit_code != 0) {
            std.debug.print("Command failed with exit code: {}\n", .{self.exit_code});
            std.debug.print("STDERR: {s}\n", .{self.stderr});
            return error.CommandFailed;
        }
    }

    pub fn expect_failure(self: *const CommandResult) !void {
        if (self.exit_code == 0) {
            std.debug.print("Expected command to fail but it succeeded\n", .{});
            std.debug.print("STDOUT: {s}\n", .{self.stdout});
            return error.UnexpectedSuccess;
        }
    }

    pub fn contains_output(self: *const CommandResult, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.stdout, needle) != null;
    }

    pub fn contains_error(self: *const CommandResult, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.stderr, needle) != null;
    }
};

/// Helper function to safely extract exit code from process result
pub fn safe_exit_code(term: std.process.Child.Term) u8 {
    return switch (term) {
        .Exited => |code| @intCast(code),
        .Signal => |sig| blk: {
            std.debug.print("Process terminated with signal: {}\n", .{sig});
            break :blk @as(u8, 255);
        },
        .Stopped => |sig| blk: {
            std.debug.print("Process stopped with signal: {}\n", .{sig});
            break :blk @as(u8, 255);
        },
        .Unknown => |code| blk: {
            std.debug.print("Process terminated with unknown code: {}\n", .{code});
            break :blk @as(u8, @intCast(@min(code, 255)));
        },
    };
}

/// Helper function to check if process exited successfully
pub fn process_succeeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

/// E2E test harness for binary interface testing
pub const E2EHarness = struct {
    allocator: std.mem.Allocator,
    binary_path: []const u8,
    test_workspace: []const u8,
    cleanup_paths: std.ArrayList([]const u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, test_name: []const u8) !Self {
        // Ensure binary is built before testing
        try build_kausaldb_binary(allocator);

        const binary_path = try std.fs.path.join(allocator, &[_][]const u8{ "zig-out", "bin", "kausaldb" });
        const test_workspace = try create_isolated_workspace(allocator, test_name);

        const cleanup_paths = std.ArrayList([]const u8){};

        return Self{
            .allocator = allocator,
            .binary_path = binary_path,
            .test_workspace = test_workspace,
            .cleanup_paths = cleanup_paths,
        };
    }

    pub fn deinit(self: *Self) void {
        // Clean up database state to prevent SSTable accumulation across tests
        self.cleanup_database_state();

        // Clean up all registered paths with robust error handling
        for (self.cleanup_paths.items) |path| {
            // Skip empty or obviously invalid paths
            if (path.len == 0) {
                self.allocator.free(path);
                continue;
            }

            // Only attempt cleanup on absolute paths that seem valid
            if (std.fs.path.isAbsolute(path)) {
                std.fs.deleteTreeAbsolute(path) catch {}; // Ignore all errors during cleanup
            }

            // Free the path memory
            self.allocator.free(path);
        }
        self.cleanup_paths.deinit(self.allocator);

        self.allocator.free(self.binary_path);
        std.fs.deleteTreeAbsolute(self.test_workspace) catch {};
        self.allocator.free(self.test_workspace);
    }

    /// Clean up KausalDB database state to prevent SSTable accumulation
    fn cleanup_database_state(self: *Self) void {
        // Remove .kausal-data directory to reset database state
        // This prevents WriteBlocked errors caused by accumulated SSTables
        std.fs.cwd().deleteTree(".kausal-data") catch {
            // Ignore all cleanup errors - the directory might not exist or be busy
        };

        // Also cleanup any database state in test workspace
        const db_path = std.fs.path.join(self.allocator, &[_][]const u8{ self.test_workspace, ".kausal-data" }) catch return;
        defer self.allocator.free(db_path);

        std.fs.deleteTreeAbsolute(db_path) catch |err| switch (err) {
            error.FileNotFound => {}, // Already clean
            else => {}, // Ignore cleanup errors in test workspace
        };
    }

    /// Execute KausalDB command and return structured result
    pub fn execute_command(self: *Self, args: []const []const u8) !CommandResult {
        // Build argv array with binary + args
        var argv_list = std.ArrayList([]const u8){};
        defer argv_list.deinit(self.allocator);

        try argv_list.append(self.allocator, self.binary_path);
        try argv_list.appendSlice(self.allocator, args);

        // Execute using the same pattern as working debug tests
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = argv_list.items,
        });

        const exit_code: u8 = switch (result.term) {
            .Exited => |code| @intCast(code),
            .Signal => |sig| blk: {
                std.debug.print("Process terminated with signal: {}\n", .{sig});
                // Use 255 for signals to stay within u8 range
                break :blk @as(u8, @intCast(255));
            },
            .Stopped => |sig| blk: {
                std.debug.print("Process stopped with signal: {}\n", .{sig});
                break :blk @as(u8, @intCast(255));
            },
            .Unknown => |code| blk: {
                std.debug.print("Process terminated with unknown code: {}\n", .{code});
                break :blk @as(u8, @intCast(@min(code, 255)));
            },
        };

        return CommandResult{
            .exit_code = exit_code,
            .stdout = result.stdout,
            .stderr = result.stderr,
            .allocator = self.allocator,
        };
    }

    /// Execute workspace command (link, unlink, sync)
    pub fn execute_workspace_command(self: *Self, comptime fmt: []const u8, args: anytype) !CommandResult {
        const cmd_string = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(cmd_string);

        var cmd_parts = std.mem.splitSequence(u8, cmd_string, " ");
        var cmd_args = std.ArrayList([]const u8){};
        defer cmd_args.deinit(self.allocator);

        while (cmd_parts.next()) |part| {
            if (part.len > 0) try cmd_args.append(self.allocator, part);
        }

        return self.execute_command(cmd_args.items);
    }

    /// Create test project with realistic code structure
    pub fn create_test_project(self: *Self, project_name: []const u8) ![]const u8 {
        const project_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.test_workspace, project_name });

        // Don't register paths ending with "." for cleanup as they can't be deleted safely
        if (!std.mem.endsWith(u8, project_path, "/.") and !std.mem.eql(u8, std.fs.path.basename(project_path), ".")) {
            try self.cleanup_paths.append(self.allocator, project_path);
        }

        std.fs.makeDirAbsolute(project_path) catch |err| switch (err) {
            error.PathAlreadyExists => {}, // OK if it already exists
            else => return err,
        };

        // Create main.zig with multiple functions for testing
        const main_zig_path = try std.fs.path.join(self.allocator, &[_][]const u8{ project_path, "main.zig" });
        defer self.allocator.free(main_zig_path);

        const main_content =
            \\const std = @import("std");
            \\const utils = @import("utils.zig");
            \\
            \\pub fn main() void {
            \\    std.debug.print("Hello, KausalDB!\n", .{});
            \\    helper_function();
            \\    utils.utility_function();
            \\}
            \\
            \\fn helper_function() void {
            \\    const result = calculate_value(42);
            \\    std.debug.print("Helper result: {}\n", .{result});
            \\}
            \\
            \\pub fn calculate_value(x: i32) i32 {
            \\    return x * 2 + 1;
            \\}
            \\
            \\test "calculate_value basic math" {
            \\    try std.testing.expect(calculate_value(21) == 43);
            \\}
        ;

        {
            const file = try std.fs.createFileAbsolute(main_zig_path, .{});
            defer file.close();
            try file.writeAll(main_content);
        }

        // Create utils.zig with additional functions
        const utils_zig_path = try std.fs.path.join(self.allocator, &[_][]const u8{ project_path, "utils.zig" });
        defer self.allocator.free(utils_zig_path);

        const utils_content =
            \\const std = @import("std");
            \\
            \\pub fn utility_function() void {
            \\    const sum = add_numbers(10, 20);
            \\    std.debug.print("Utility sum: {}\n", .{sum});
            \\}
            \\
            \\pub fn add_numbers(a: i32, b: i32) i32 {
            \\    return a + b;
            \\}
            \\
            \\fn private_helper(x: i32) i32 {
            \\    return x * 3;
            \\}
            \\
            \\test "add_numbers functionality" {
            \\    try std.testing.expect(add_numbers(5, 7) == 12);
            \\}
        ;

        {
            const file = try std.fs.createFileAbsolute(utils_zig_path, .{});
            defer file.close();
            try file.writeAll(utils_content);
        }

        // Create build.zig for completeness
        const build_zig_path = try std.fs.path.join(self.allocator, &[_][]const u8{ project_path, "build.zig" });
        defer self.allocator.free(build_zig_path);

        const build_content =
            \\const std = @import("std");
            \\
            \\pub fn build(b: *std.Build) void {
            \\    const exe = b.addExecutable(.{
            \\        .name = "test_project",
            \\        .root_source_file = b.path("main.zig"),
            \\        .target = b.host,
            \\    });
            \\    b.installArtifact(exe);
            \\}
        ;

        {
            const file = try std.fs.createFileAbsolute(build_zig_path, .{});
            defer file.close();
            try file.writeAll(build_content);
        }

        return project_path;
    }

    /// Validate JSON output format
    pub fn validate_json_output(self: *Self, json_string: []const u8) !std.json.Parsed(std.json.Value) {
        return std.json.parseFromSlice(std.json.Value, self.allocator, json_string, .{});
    }

    /// Wait for command completion with timeout
    pub fn execute_command_with_timeout(self: *Self, args: []const []const u8, timeout_ms: u64) !CommandResult {
        // For now, execute normally - timeout implementation can be added if needed
        _ = timeout_ms;
        return self.execute_command(args);
    }
};

/// Build KausalDB binary to ensure latest version for testing
fn build_kausaldb_binary(allocator: std.mem.Allocator) !void {
    const build_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "./zig/zig", "build" },
    });
    defer allocator.free(build_result.stdout);
    defer allocator.free(build_result.stderr);

    if (!process_succeeded(build_result.term)) {
        std.debug.print("Build failed:\nstdout: {s}\nstderr: {s}\n", .{ build_result.stdout, build_result.stderr });
        return error.BuildFailed;
    }
}

/// Create isolated workspace directory for test execution
fn create_isolated_workspace(allocator: std.mem.Allocator, test_name: []const u8) ![]const u8 {
    const timestamp = std.time.timestamp();
    var prng = std.Random.DefaultPrng.init(@as(u64, @bitCast(timestamp)));
    const random_suffix = prng.random().int(u32);
    const workspace_name = try std.fmt.allocPrint(allocator, "/tmp/kausaldb_e2e_{s}_{d}_{d}", .{ test_name, timestamp, random_suffix });

    std.fs.makeDirAbsolute(workspace_name) catch |err| switch (err) {
        error.PathAlreadyExists => {}, // OK if it already exists
        else => return err,
    };
    return workspace_name;
}

// Tests for the harness itself
test "E2EHarness basic initialization" {
    var harness = try E2EHarness.init(testing.allocator, "harness_test");
    defer harness.deinit();

    // Verify binary exists
    std.fs.cwd().access(harness.binary_path, .{}) catch |err| {
        std.debug.print("Binary not found at: {s}\n", .{harness.binary_path});
        return err;
    };

    // Verify workspace directory exists
    std.fs.accessAbsolute(harness.test_workspace, .{}) catch |err| {
        std.debug.print("Workspace not found at: {s}\n", .{harness.test_workspace});
        return err;
    };
}

test "E2EHarness command execution" {
    var harness = try E2EHarness.init(testing.allocator, "cmd_test");
    defer harness.deinit();

    var result = try harness.execute_command(&[_][]const u8{"version"});
    defer result.deinit();

    try result.expect_success();
    try testing.expect(result.contains_output("KausalDB"));
}

test "E2EHarness test project creation" {
    var harness = try E2EHarness.init(testing.allocator, "project_test");
    defer harness.deinit();

    const project_path = try harness.create_test_project("test_proj");

    // Verify project structure
    const main_path = try std.fs.path.join(testing.allocator, &[_][]const u8{ project_path, "main.zig" });
    defer testing.allocator.free(main_path);

    const utils_path = try std.fs.path.join(testing.allocator, &[_][]const u8{ project_path, "utils.zig" });
    defer testing.allocator.free(utils_path);

    std.fs.accessAbsolute(main_path, .{}) catch |err| {
        std.debug.print("main.zig not found at: {s}\n", .{main_path});
        return err;
    };

    std.fs.accessAbsolute(utils_path, .{}) catch |err| {
        std.debug.print("utils.zig not found at: {s}\n", .{utils_path});
        return err;
    };
}
