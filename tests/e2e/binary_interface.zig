//! End-to-end binary interface tests for KausalDB CLI.
//!
//! Tests the actual compiled binary through shell execution to validate
//! the complete user experience. These tests ensure the CLI behavior
//! matches documentation and catches regressions in binary interface.
//!
//! Design rationale: Unit tests validate internal logic, but E2E tests
//! validate the actual user experience with the compiled binary.

const std = @import("std");
const testing = std.testing;

/// Execute KausalDB binary with given arguments and return result
fn exec_kausaldb(allocator: std.mem.Allocator, args: []const []const u8) !std.process.Child.RunResult {
    var argv = try std.ArrayList([]const u8).initCapacity(allocator, args.len + 1);
    defer argv.deinit(allocator);

    try argv.append(allocator, "./zig-out/bin/kausaldb");
    for (args) |arg| {
        try argv.append(allocator, arg);
    }

    return std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
    });
}

/// Create temporary test directory for isolated testing
fn create_test_dir(allocator: std.mem.Allocator, test_name: []const u8) ![]const u8 {
    const tmp_dir = try std.fmt.allocPrint(allocator, "/tmp/kausaldb_e2e_{s}_{d}", .{ test_name, std.time.timestamp() });
    try std.fs.makeDirAbsolute(tmp_dir); // tidy:ignore-simulation
    return tmp_dir;
}

/// Clean up test directory
fn cleanup_test_dir(allocator: std.mem.Allocator, dir_path: []const u8) void {
    std.fs.deleteTreeAbsolute(dir_path) catch {}; // tidy:ignore-simulation
    allocator.free(dir_path);
}

test "e2e basic help and version commands" {
    const allocator = testing.allocator;

    // Ensure binary is built
    const build_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "./zig/zig", "build" },
    });
    defer allocator.free(build_result.stdout);
    defer allocator.free(build_result.stderr);
    try testing.expectEqual(@as(u8, 0), build_result.term.Exited);

    // Test version command
    {
        const result = try exec_kausaldb(allocator, &[_][]const u8{"version"});
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try testing.expectEqual(@as(u8, 0), result.term.Exited);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "KausalDB v0.1.0") != null);
        try testing.expectEqual(@as(usize, 0), result.stderr.len);
    }

    // Test help command
    {
        const result = try exec_kausaldb(allocator, &[_][]const u8{"help"});
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try testing.expectEqual(@as(u8, 0), result.term.Exited);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "Usage:") != null);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "Workspace Commands:") != null);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "link") != null);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "unlink") != null);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "workspace") != null);
    }

    // Test default behavior (should show help)
    {
        const result = try exec_kausaldb(allocator, &[_][]const u8{});
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try testing.expectEqual(@as(u8, 0), result.term.Exited);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "Usage:") != null);
    }
}

test "e2e workspace management flow" {
    const allocator = testing.allocator;

    // Create isolated test directory
    const test_dir = try create_test_dir(allocator, "workspace_flow");
    defer cleanup_test_dir(allocator, test_dir);

    // Change to test directory for isolated testing
    const original_cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(original_cwd);
    try std.posix.chdir(test_dir); // tidy:ignore-simulation
    defer std.posix.chdir(original_cwd) catch {}; // tidy:ignore-simulation

    // Create a simple test project structure
    try std.fs.cwd().makeDir("test_project"); // tidy:ignore-simulation
    try std.fs.cwd().writeFile(.{ .sub_path = "test_project/main.zig", .data = "const std = @import(\"std\");\n" }); // tidy:ignore-simulation
    try std.fs.cwd().writeFile(.{ .sub_path = "test_project/README.md", .data = "# Test Project\n" }); // tidy:ignore-simulation

    // Copy kausaldb binary to test directory for easier execution
    const binary_path = try std.fs.path.join(allocator, &[_][]const u8{ original_cwd, "zig-out/bin/kausaldb" });
    defer allocator.free(binary_path);

    // Test initial workspace status (empty)
    {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ binary_path, "workspace" },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try testing.expectEqual(@as(u8, 0), result.term.Exited);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "No codebases linked") != null);
    }

    // Test linking test project
    {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ binary_path, "link", "test_project" },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try testing.expectEqual(@as(u8, 0), result.term.Exited);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "✓ Linked codebase") != null);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "test_project") != null);
    }

    // Test workspace status with linked codebase
    {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ binary_path, "workspace" },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try testing.expectEqual(@as(u8, 0), result.term.Exited);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "WORKSPACE STATUS") != null);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "test_project") != null);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "Path:") != null);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "Linked:") != null);
    }

    // Test linking with custom name
    {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ binary_path, "link", "test_project", "as", "my-project" },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try testing.expectEqual(@as(u8, 0), result.term.Exited);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "✓ Linked codebase 'my-project'") != null);
    }

    // Verify both codebases are linked
    {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ binary_path, "workspace" },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try testing.expectEqual(@as(u8, 0), result.term.Exited);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "test_project") != null);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "my-project") != null);
    }

    // Test unlinking
    {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ binary_path, "unlink", "my-project" },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try testing.expectEqual(@as(u8, 0), result.term.Exited);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "✓ Unlinked codebase 'my-project'") != null);
    }

    // Verify only original codebase remains
    {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ binary_path, "workspace" },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try testing.expectEqual(@as(u8, 0), result.term.Exited);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "test_project") != null);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "my-project") == null);
    }
}

test "e2e error handling and validation" {
    const allocator = testing.allocator;

    const original_cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(original_cwd);

    const binary_path = try std.fs.path.join(allocator, &[_][]const u8{ original_cwd, "zig-out/bin/kausaldb" });
    defer allocator.free(binary_path);

    // Test unknown command
    {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ binary_path, "invalid-command" },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try testing.expectEqual(@as(u8, 1), result.term.Exited);
        try testing.expect(std.mem.indexOf(u8, result.stderr, "Unknown command") != null);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "Usage:") != null);
    }

    // Test linking non-existent path
    {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ binary_path, "link", "/nonexistent/path/12345" },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try testing.expectEqual(@as(u8, 0), result.term.Exited); // Command succeeds but shows error
        try testing.expect(std.mem.indexOf(u8, result.stderr, "does not exist") != null);
    }

    // Test unlinking non-existent codebase
    {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ binary_path, "unlink", "nonexistent-codebase" },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try testing.expectEqual(@as(u8, 0), result.term.Exited); // Command succeeds but shows error
        try testing.expect(std.mem.indexOf(u8, result.stderr, "not linked") != null);
    }

    // Test malformed link command arguments
    {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ binary_path, "link" },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try testing.expectEqual(@as(u8, 1), result.term.Exited);
        try testing.expect(std.mem.indexOf(u8, result.stderr, "Error:") != null);
    }
}

test "e2e future command placeholders" {
    const allocator = testing.allocator;

    const original_cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(original_cwd);

    const binary_path = try std.fs.path.join(allocator, &[_][]const u8{ original_cwd, "zig-out/bin/kausaldb" });
    defer allocator.free(binary_path);

    // Test find command placeholder
    {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ binary_path, "find", "function", "init" },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try testing.expectEqual(@as(u8, 0), result.term.Exited);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "Find command:") != null);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "next phase") != null);
    }

    // Test show command placeholder
    {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ binary_path, "show", "callers", "main" },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try testing.expectEqual(@as(u8, 0), result.term.Exited);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "Show command:") != null);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "next phase") != null);
    }

    // Test trace command placeholder
    {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ binary_path, "trace", "callers", "main", "--depth", "5" },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try testing.expectEqual(@as(u8, 0), result.term.Exited);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "Trace command:") != null);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "depth: 5") != null);
    }
}

test "e2e legacy command compatibility" {
    const allocator = testing.allocator;

    const original_cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(original_cwd);

    const binary_path = try std.fs.path.join(allocator, &[_][]const u8{ original_cwd, "zig-out/bin/kausaldb" });
    defer allocator.free(binary_path);

    // Test legacy status command
    {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ binary_path, "status" },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try testing.expectEqual(@as(u8, 0), result.term.Exited);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "KausalDB Status") != null);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "Legacy") != null);
    }

    // Test demo command
    {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ binary_path, "demo" },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try testing.expectEqual(@as(u8, 0), result.term.Exited);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "Storage and Query Demo") != null);
    }

    // Test analyze command (should redirect to workspace)
    {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ binary_path, "analyze" },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try testing.expectEqual(@as(u8, 0), result.term.Exited);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "Legacy Analysis") != null);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "kausaldb link") != null);
    }
}
