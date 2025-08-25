//! Smoke tests for natural language CLI binary interface.
//!
//! Basic smoke tests to verify the binary executable functions correctly
//! with natural language commands. These tests validate basic functionality
//! without heavy filesystem operations to maintain architectural compliance.

const std = @import("std");
const testing = std.testing;

const ChildProcess = std.process.Child;

/// Simple binary smoke test context
const SmokeTestContext = struct {
    allocator: std.mem.Allocator,
    binary_path: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        // Verify binary exists (assume it's built)
        const binary_path = try std.fs.path.join(allocator, &[_][]const u8{ "/Users/mitander/c/p/kausaldb", "zig-out", "bin", "kausaldb" });

        return Self{
            .allocator = allocator,
            .binary_path = binary_path,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.binary_path);
    }

    /// Execute binary with basic timeout and capture result
    pub fn execute_command(self: *Self, args: []const []const u8) !CommandResult {
        var arg_list = std.array_list.Managed([]const u8).init(self.allocator);
        defer arg_list.deinit();

        try arg_list.append(self.binary_path);
        for (args) |arg| {
            try arg_list.append(arg);
        }

        const result = try ChildProcess.run(.{
            .allocator = self.allocator,
            .argv = arg_list.items,
        });

        const stdout = result.stdout;
        const stderr = result.stderr;

        return CommandResult{
            .allocator = self.allocator,
            .exit_code = switch (result.term) {
                .Exited => |code| code,
                else => 1,
            },
            .stdout = stdout,
            .stderr = stderr,
        };
    }
};

/// Result of executing a binary command
const CommandResult = struct {
    allocator: std.mem.Allocator,
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }

    pub fn expect_success(self: *const Self) !void {
        if (self.exit_code != 0) {
            std.debug.print("Command failed with exit code {}\n", .{self.exit_code});
            std.debug.print("STDERR: {s}\n", .{self.stderr});
            return error.CommandFailed;
        }
    }

    pub fn contains_output(self: *const Self, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.stdout, needle) != null or
            std.mem.indexOf(u8, self.stderr, needle) != null;
    }
};

test "smoke: binary exists and responds to help" {
    const allocator = testing.allocator;
    var context = try SmokeTestContext.init(allocator);
    defer context.deinit();

    // Test basic help command
    var result = try context.execute_command(&[_][]const u8{"help"});
    defer result.deinit();

    try result.expect_success();
    try testing.expect(result.contains_output("KausalDB"));
}

test "smoke: version command works" {
    const allocator = testing.allocator;
    var context = try SmokeTestContext.init(allocator);
    defer context.deinit();

    var result = try context.execute_command(&[_][]const u8{"version"});
    defer result.deinit();

    try result.expect_success();
    try testing.expect(result.contains_output("KausalDB"));
}

test "smoke: status command responds appropriately" {
    const allocator = testing.allocator;
    var context = try SmokeTestContext.init(allocator);
    defer context.deinit();

    var result = try context.execute_command(&[_][]const u8{"status"});
    defer result.deinit();

    try result.expect_success();
    // Should show some status information
    try testing.expect(result.stdout.len > 0 or result.stderr.len > 0);
}

test "smoke: JSON output format works" {
    const allocator = testing.allocator;
    var context = try SmokeTestContext.init(allocator);
    defer context.deinit();

    // Test JSON status
    var result = try context.execute_command(&[_][]const u8{ "status", "--json" });
    defer result.deinit();

    try result.expect_success();
    try testing.expect(result.contains_output("{"));
}

test "smoke: find command handles invalid entity gracefully" {
    const allocator = testing.allocator;
    var context = try SmokeTestContext.init(allocator);
    defer context.deinit();

    var result = try context.execute_command(&[_][]const u8{ "find", "invalid_entity", "test" });
    defer result.deinit();

    try result.expect_success(); // Should handle gracefully
    try testing.expect(result.contains_output("invalid") or result.contains_output("supported"));
}

test "smoke: unknown command shows appropriate error" {
    const allocator = testing.allocator;
    var context = try SmokeTestContext.init(allocator);
    defer context.deinit();

    var result = try context.execute_command(&[_][]const u8{"nonexistent_command"});
    defer result.deinit();

    // Should fail with appropriate error
    try testing.expect(result.exit_code != 0);
    try testing.expect(result.contains_output("Unknown") or result.contains_output("command"));
}
