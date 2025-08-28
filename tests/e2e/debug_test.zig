//! Simple debug test to troubleshoot e2e testing issues.
//!
//! This file contains minimal tests to isolate and fix the core problems
//! with binary execution and test environment setup.

const std = @import("std");
const testing = std.testing;

test "binary exists and is executable" {
    const binary_path = "zig-out/bin/kausaldb";

    // Check if binary file exists
    std.fs.cwd().access(binary_path, .{}) catch |err| {
        std.debug.print("Binary not found at: {s}\n", .{binary_path});
        return err;
    };

    std.debug.print("Binary found at: {s}\n", .{binary_path});
}

test "basic binary execution works" {
    const allocator = testing.allocator;

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "zig-out/bin/kausaldb", "version" },
    }) catch |err| {
        std.debug.print("Failed to execute binary: {}\n", .{err});
        return err;
    };

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const exit_code = switch (result.term) {
        .Exited => |code| code,
        .Signal => |sig| blk: {
            std.debug.print("Process terminated with signal: {}\n", .{sig});
            break :blk @as(u32, 255);
        },
        else => @as(u32, 255),
    };

    std.debug.print("Exit code: {}\n", .{exit_code});
    std.debug.print("STDOUT: {s}\n", .{result.stdout});
    std.debug.print("STDERR: {s}\n", .{result.stderr});

    try testing.expectEqual(@as(u32, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "KausalDB") != null);
}

test "help command execution" {
    const allocator = testing.allocator;

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "zig-out/bin/kausaldb", "help" },
    });

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const help_exit_code = switch (result.term) {
        .Exited => |code| code,
        .Signal => |sig| blk: {
            std.debug.print("Help process terminated with signal: {}\n", .{sig});
            break :blk @as(u32, 255);
        },
        else => @as(u32, 255),
    };

    std.debug.print("Help exit code: {}\n", .{help_exit_code});
    std.debug.print("Help STDOUT length: {}\n", .{result.stdout.len});

    try testing.expectEqual(@as(u32, 0), help_exit_code);
    try testing.expect(result.stdout.len > 0);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "Usage:") != null);
}

test "temporary directory creation" {
    const allocator = testing.allocator;

    const timestamp = std.time.timestamp();
    const test_dir = try std.fmt.allocPrint(allocator, "/tmp/kausaldb_debug_{d}", .{timestamp});
    defer allocator.free(test_dir);

    std.debug.print("Creating test directory: {s}\n", .{test_dir});

    std.fs.makeDirAbsolute(test_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {
            std.debug.print("Directory already exists (OK)\n", .{});
        },
        else => {
            std.debug.print("Failed to create directory: {}\n", .{err});
            return err;
        },
    };

    // Verify directory exists
    std.fs.accessAbsolute(test_dir, .{}) catch |err| {
        std.debug.print("Directory not accessible: {}\n", .{err});
        return err;
    };

    // Cleanup
    std.fs.deleteTreeAbsolute(test_dir) catch |err| {
        std.debug.print("Failed to cleanup directory: {}\n", .{err});
        // Don't fail the test for cleanup issues
    };

    std.debug.print("Temporary directory test passed\n", .{});
}

test "workspace command basic flow" {
    const allocator = testing.allocator;

    // Create temporary workspace
    const timestamp = std.time.timestamp();
    const workspace = try std.fmt.allocPrint(allocator, "/tmp/kausaldb_workspace_{d}", .{timestamp});
    defer allocator.free(workspace);

    try std.fs.makeDirAbsolute(workspace);
    defer std.fs.deleteTreeAbsolute(workspace) catch {};

    // Test status command in empty workspace
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "zig-out/bin/kausaldb", "status" },
    });

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const status_exit_code = switch (result.term) {
        .Exited => |code| code,
        .Signal => |sig| blk: {
            std.debug.print("Status process terminated with signal: {}\n", .{sig});
            break :blk @as(u32, 255);
        },
        else => @as(u32, 255),
    };

    std.debug.print("Status in empty workspace:\n", .{});
    std.debug.print("Exit code: {}\n", .{status_exit_code});
    std.debug.print("STDOUT: {s}\n", .{result.stdout});
    std.debug.print("STDERR: {s}\n", .{result.stderr});

    // Should succeed even in empty workspace
    try testing.expectEqual(@as(u32, 0), status_exit_code);
}
