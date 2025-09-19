//! Core E2E test harness for KausalDB binary interface testing.
//!
//! Provides unified utilities for executing the KausalDB binary, managing
//! test environments, and validating command outputs. Eliminates duplication
//! across e2e test files and ensures consistent test isolation.

const std = @import("std");
const testing = std.testing;

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
        // Try to ensure binary exists, build if needed (CI fallback)
        const relative_binary_path = try std.fs.path.join(allocator, &[_][]const u8{ "zig-out", "bin", "kausaldb" });
        defer allocator.free(relative_binary_path);
        const binary_path = try std.fs.cwd().realpathAlloc(allocator, relative_binary_path);

        // Check if binary exists, if not try to build it
        std.fs.cwd().access(binary_path, .{}) catch {
            std.debug.print("Binary not found at {s}, attempting to build...\n", .{binary_path});
            build_kausaldb_binary(allocator) catch |err| {
                std.debug.print("Failed to build binary: {}\n", .{err});
                return err;
            };

            // Verify the binary was actually built
            std.fs.cwd().access(binary_path, .{}) catch {
                std.debug.print("Binary still not found after build attempt at: {s}\n", .{binary_path});
                return error.BinaryNotFound;
            };
            std.debug.print("Binary successfully built at: {s}\n", .{binary_path});
        };
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
        // Database state is automatically cleaned up with the test workspace

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
    /// Execute KausalDB command and return structured result
    pub fn execute_command(self: *Self, args: []const []const u8) !CommandResult {
        // Build argv array with binary + args
        var argv_list = std.ArrayList([]const u8){};
        defer argv_list.deinit(self.allocator);

        try argv_list.append(self.allocator, self.binary_path);
        try argv_list.appendSlice(self.allocator, args);

        // Execute using the same pattern as working debug tests
        // Increase max_output_bytes to handle verbose debug output from successful ingestion
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = argv_list.items,
            .cwd = self.test_workspace, // Run in isolated test workspace
            .max_output_bytes = 4 * 1024 * 1024, // 4MB
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

    /// Execute external commands (git, build tools) using shell interface
    pub fn execute_shell_command(self: *Self, comptime cmd_fmt: []const u8, args: anytype) ![]const u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        const full_cmd = try std.fmt.allocPrint(arena_allocator, cmd_fmt, args);

        // Split command into argv
        var argv = std.ArrayList([]const u8){};
        defer argv.deinit(arena_allocator);

        var arg_iter = std.mem.tokenizeAny(u8, full_cmd, " \t");
        while (arg_iter.next()) |arg| {
            try argv.append(arena_allocator, arg);
        }

        if (argv.items.len == 0) return error.EmptyCommand;

        const result = try std.process.Child.run(.{
            .allocator = arena_allocator,
            .argv = argv.items,
            .cwd = self.test_workspace, // Run in isolated test workspace
            .max_output_bytes = 4 * 1024 * 1024, // 4MB
        });

        if (!process_succeeded(result.term)) {
            std.debug.print("Shell command failed: {s}\n", .{full_cmd});
            if (result.stderr.len > 0) {
                std.debug.print("Stderr: {s}\n", .{result.stderr});
            }
            return error.CommandFailed;
        }

        return try self.allocator.dupe(u8, result.stdout);
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

    /// Create enhanced test project with comprehensive entity types for testing
    pub fn create_enhanced_test_project(self: *Self, project_name: []const u8) ![]const u8 {
        const project_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.test_workspace, project_name });

        try self.cleanup_paths.append(self.allocator, project_path);

        std.fs.makeDirAbsolute(project_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Create main.zig with various entities and imports
        const main_zig_path = try std.fs.path.join(self.allocator, &[_][]const u8{ project_path, "main.zig" });
        defer self.allocator.free(main_zig_path);

        const main_content =
            \\const std = @import("std");
            \\const utils = @import("utils.zig");
            \\const testing = std.testing;
            \\
            \\const Config = struct {
            \\    debug: bool = false,
            \\    max_items: u32 = 100,
            \\};
            \\
            \\const ErrorType = error{
            \\    InvalidInput,
            \\    OutOfMemory,
            \\};
            \\
            \\pub fn main() void {
            \\    const config = Config{};
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
            \\const PI: f64 = 3.14159;
            \\var global_counter: u32 = 0;
            \\
            \\const Point = struct {
            \\    x: f32,
            \\    y: f32,
            \\
            \\    pub fn distance(self: Point, other: Point) f32 {
            \\        const dx = self.x - other.x;
            \\        const dy = self.y - other.y;
            \\        return std.math.sqrt(dx * dx + dy * dy);
            \\    }
            \\};
            \\
            \\test "calculate_value basic math" {
            \\    try testing.expect(calculate_value(21) == 43);
            \\}
            \\
            \\test "point distance calculation" {
            \\    const p1 = Point{ .x = 0, .y = 0 };
            \\    const p2 = Point{ .x = 3, .y = 4 };
            \\    try testing.expect(p1.distance(p2) == 5.0);
            \\}
        ;

        {
            const file = try std.fs.createFileAbsolute(main_zig_path, .{});
            defer file.close();
            try file.writeAll(main_content);
        }

        // Create utils.zig with more entities
        const utils_zig_path = try std.fs.path.join(self.allocator, &[_][]const u8{ project_path, "utils.zig" });
        defer self.allocator.free(utils_zig_path);

        const utils_content =
            \\const std = @import("std");
            \\const print = std.debug.print;
            \\
            \\pub const MAX_SIZE: usize = 1000;
            \\
            \\pub fn utility_function() void {
            \\    const sum = add_numbers(10, 20);
            \\    print("Utility sum: {}\n", .{sum});
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
            \\pub const Logger = struct {
            \\    level: LogLevel,
            \\
            \\    pub fn log(self: Logger, message: []const u8) void {
            \\        print("[{}] {s}\n", .{ self.level, message });
            \\    }
            \\};
            \\
            \\pub const LogLevel = enum {
            \\    debug,
            \\    info,
            \\    warn,
            \\    err,
            \\};
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

        return project_path;
    }

    /// Create large test project for storage pressure testing
    pub fn create_large_test_project(self: *Self, project_name: []const u8) ![]const u8 {
        const project_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.test_workspace, project_name });

        try self.cleanup_paths.append(self.allocator, project_path);

        std.fs.makeDirAbsolute(project_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Create multiple files to simulate a larger codebase
        const file_count = 15;

        for (0..file_count) |i| {
            const file_name = try std.fmt.allocPrint(self.allocator, "module_{d}.zig", .{i});
            defer self.allocator.free(file_name);

            const file_path = try std.fs.path.join(self.allocator, &[_][]const u8{ project_path, file_name });
            defer self.allocator.free(file_path);

            const content = try std.fmt.allocPrint(self.allocator,
                \\const std = @import("std");
                \\
                \\pub const MODULE_{d}_CONSTANT: u32 = {d};
                \\
                \\pub fn module_{d}_function(x: u32) u32 {{
                \\    return x + MODULE_{d}_CONSTANT;
                \\}}
                \\
                \\pub const Module{d}Struct = struct {{
                \\    id: u32,
                \\    data: [100]u8,
                \\
                \\    pub fn init(id: u32) Module{d}Struct {{
                \\        return Module{d}Struct{{
                \\            .id = id,
                \\            .data = [_]u8{{0}} ** 100,
                \\        }};
                \\    }}
                \\
                \\    pub fn process(self: *Module{d}Struct) u32 {{
                \\        return self.id * 2;
                \\    }}
                \\}};
                \\
                \\test "module_{d}_function test" {{
                \\    const result = module_{d}_function(10);
                \\    try std.testing.expect(result == 10 + MODULE_{d}_CONSTANT);
                \\}}
                \\
                \\test "Module{d}Struct test" {{
                \\    var instance = Module{d}Struct.init(42);
                \\    const processed = instance.process();
                \\    try std.testing.expect(processed == 84);
                \\}}
            , .{ i, i, i, i, i, i, i, i, i, i, i, i, i });
            defer self.allocator.free(content);

            const file = try std.fs.createFileAbsolute(file_path, .{});
            defer file.close();
            try file.writeAll(content);
        }

        // Create main.zig that imports several modules
        const main_path = try std.fs.path.join(self.allocator, &[_][]const u8{ project_path, "main.zig" });
        defer self.allocator.free(main_path);

        var main_content = std.ArrayList(u8){};
        defer main_content.deinit(self.allocator);

        try main_content.appendSlice(self.allocator, "const std = @import(\"std\");\n");

        // Import first 8 modules
        for (0..8) |i| {
            const import_line = try std.fmt.allocPrint(self.allocator, "const module_{d} = @import(\"module_{d}.zig\");\n", .{ i, i });
            defer self.allocator.free(import_line);
            try main_content.appendSlice(self.allocator, import_line);
        }

        try main_content.appendSlice(self.allocator,
            \\
            \\pub fn main() void {
            \\    std.debug.print("Large codebase test\n", .{});
            \\
        );

        for (0..5) |i| {
            const call_line = try std.fmt.allocPrint(self.allocator, "    _ = module_{d}.module_{d}_function({d});\n", .{ i, i, i * 10 });
            defer self.allocator.free(call_line);
            try main_content.appendSlice(self.allocator, call_line);
        }

        try main_content.appendSlice(self.allocator, "}\n");

        const main_file = try std.fs.createFileAbsolute(main_path, .{});
        defer main_file.close();
        try main_file.writeAll(main_content.items);

        return project_path;
    }

    /// Create project with substantial content for memory testing
    pub fn create_substantial_content_project(self: *Self, project_name: []const u8) ![]const u8 {
        const project_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.test_workspace, project_name });

        try self.cleanup_paths.append(self.allocator, project_path);

        std.fs.makeDirAbsolute(project_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Create a file with substantial content (large functions, many parameters, etc)
        const substantial_path = try std.fs.path.join(self.allocator, &[_][]const u8{ project_path, "substantial.zig" });
        defer self.allocator.free(substantial_path);

        var content = std.ArrayList(u8){};
        defer content.deinit(self.allocator);

        try content.appendSlice(self.allocator, "const std = @import(\"std\");\n\n");

        // Generate a large function with many parameters and substantial logic
        try content.appendSlice(self.allocator, "pub fn large_function(\n");
        for (0..20) |i| {
            const param_line = try std.fmt.allocPrint(self.allocator, "    param_{d}: u32,\n", .{i});
            defer self.allocator.free(param_line);
            try content.appendSlice(self.allocator, param_line);
        }
        try content.appendSlice(self.allocator, ") u32 {\n");
        try content.appendSlice(self.allocator, "    var result: u32 = 0;\n");

        for (0..20) |i| {
            const calc_line = try std.fmt.allocPrint(self.allocator, "    result += param_{d} * {d};\n", .{ i, i + 1 });
            defer self.allocator.free(calc_line);
            try content.appendSlice(self.allocator, calc_line);
        }

        try content.appendSlice(self.allocator, "    return result;\n}\n\n");

        // Add a large data structure
        try content.appendSlice(self.allocator, "pub const LargeStruct = struct {\n");
        for (0..50) |i| {
            const field_line = try std.fmt.allocPrint(self.allocator, "    field_{d}: [100]u8,\n", .{i});
            defer self.allocator.free(field_line);
            try content.appendSlice(self.allocator, field_line);
        }
        try content.appendSlice(self.allocator, "};\n\n");

        // Add multiple smaller functions
        for (0..30) |i| {
            const func = try std.fmt.allocPrint(self.allocator,
                \\pub fn function_{d}(a: u32, b: u32, c: u32) u32 {{
                \\    const temp1 = a * b;
                \\    const temp2 = b + c;
                \\    const temp3 = a - c;
                \\    return temp1 + temp2 - temp3 + {d};
                \\}}
                \\
            , .{ i, i });
            defer self.allocator.free(func);
            try content.appendSlice(self.allocator, func);
        }

        const file = try std.fs.createFileAbsolute(substantial_path, .{});
        defer file.close();
        try file.writeAll(content.items);

        return project_path;
    }
};

/// Build KausalDB binary to ensure latest version for testing
fn build_kausaldb_binary(allocator: std.mem.Allocator) !void {
    // Create a temporary harness just for the shell command
    var temp_harness = E2EHarness{
        .allocator = allocator,
        .binary_path = "",
        .test_workspace = "",
        .cleanup_paths = std.ArrayList([]const u8){},
    };

    _ = temp_harness.execute_shell_command("./zig/zig build", .{}) catch |err| switch (err) {
        error.CommandFailed => {
            std.debug.print("Build failed: ./zig/zig build command failed\n", .{});
            return error.BuildFailed;
        },
        else => return err,
    };
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
