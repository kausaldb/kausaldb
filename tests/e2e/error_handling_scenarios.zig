//! E2E tests for comprehensive CLI error handling scenarios.
//!
//! Tests systematic error conditions including malformed arguments,
//! invalid commands, edge cases, and boundary conditions to ensure
//! robust error handling throughout the CLI interface.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");

test "malformed command arguments produce clear error messages" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "malformed_args");
    defer test_harness.deinit();

    const malformed_commands = [_][]const []const u8{
        &[_][]const u8{"find"}, // Missing required arguments
        &[_][]const u8{ "find", "function" }, // Missing name argument
        &[_][]const u8{"show"}, // Missing relation type and target
        &[_][]const u8{ "show", "callers" }, // Missing target
        &[_][]const u8{"trace"}, // Missing direction and target
        &[_][]const u8{ "trace", "callees" }, // Missing target
        &[_][]const u8{"link"}, // Missing path
        &[_][]const u8{"unlink"}, // Missing workspace name
    };

    for (malformed_commands) |cmd_args| {
        var result = try test_harness.execute_command(cmd_args);
        defer result.deinit();

        // Should fail with clear error message, not crash
        try result.expect_failure();
        try testing.expect(result.exit_code != 139 and result.exit_code != 11); // No segfault

        // Should provide helpful error message
        try testing.expect(result.stderr.len > 0 or result.stdout.len > 0);

        // Common error patterns that should appear
        const has_helpful_error = result.contains_error("Missing") or
            result.contains_error("Required") or
            result.contains_error("Usage:") or
            result.contains_error("Invalid") or
            result.contains_error("Error:");
        try testing.expect(has_helpful_error);
    }
}

test "invalid command combinations are handled gracefully" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "invalid_combinations");
    defer test_harness.deinit();

    const invalid_combinations = [_][]const []const u8{
        &[_][]const u8{ "find", "function", "test", "in" }, // Missing workspace after "in"
        &[_][]const u8{ "show", "callers", "func", "in" }, // Missing workspace after "in"
        &[_][]const u8{ "trace", "callees", "func", "--depth" }, // Missing depth value
        &[_][]const u8{ "link", "path", "as" }, // Missing workspace name after "as"
        &[_][]const u8{ "find", "function", "", "in", "workspace" }, // Empty function name
        &[_][]const u8{ "show", "", "target", "in", "workspace" }, // Empty relation type
    };

    for (invalid_combinations) |cmd_args| {
        var result = try test_harness.execute_command(cmd_args);
        defer result.deinit();

        // Should handle gracefully without crashing
        try testing.expect(result.exit_code != 139 and result.exit_code != 11);

        if (result.exit_code != 0) {
            // Should provide meaningful error message
            try testing.expect(result.stderr.len > 0 or result.stdout.len > 0);
        }
    }
}

test "boundary value arguments are handled safely" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "boundary_values");
    defer test_harness.deinit();

    // Create test workspace for boundary testing
    const project_path = try test_harness.create_test_project("boundary_test");
    var link_result = try test_harness.execute_workspace_command("link {s} as boundary", .{project_path});
    defer link_result.deinit();

    if (link_result.exit_code == 0) {
        var sync_result = try test_harness.execute_workspace_command("sync boundary", .{});
        defer sync_result.deinit();

        // Test boundary values for depth parameter
        const depth_values = [_][]const u8{
            "0", // Minimum depth
            "1", // Normal minimum
            "100", // High but reasonable
            "1000", // Very high
            "99999", // Extremely high
            "-1", // Negative (should be handled gracefully)
            "abc", // Non-numeric
        };

        for (depth_values) |depth| {
            var result = try test_harness.execute_command(&[_][]const u8{ "trace", "callees", "main", "in", "boundary", "--depth", depth });
            defer result.deinit();

            // Should not crash regardless of depth value
            try testing.expect(result.exit_code != 139 and result.exit_code != 11);
        }
    }
}

test "special characters in arguments are handled correctly" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "special_chars");
    defer test_harness.deinit();

    const special_char_args = [_][]const []const u8{
        &[_][]const u8{ "find", "function", "test<>", "in", "workspace" },
        &[_][]const u8{ "find", "function", "test\"quotes\"", "in", "workspace" },
        &[_][]const u8{ "find", "function", "test'quotes'", "in", "workspace" },
        &[_][]const u8{ "find", "function", "test spaces", "in", "workspace" },
        &[_][]const u8{ "find", "function", "test\ttab", "in", "workspace" },
        &[_][]const u8{ "find", "function", "test\nnewline", "in", "workspace" },
        &[_][]const u8{ "show", "callers", "func@symbol", "in", "workspace" },
        &[_][]const u8{ "trace", "callees", "func#hash", "in", "workspace" },
    };

    for (special_char_args) |cmd_args| {
        var result = try test_harness.execute_command(cmd_args);
        defer result.deinit();

        // Should handle special characters without crashing
        try testing.expect(result.exit_code != 139 and result.exit_code != 11);
    }
}

test "extremely long arguments are handled safely" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "long_args");
    defer test_harness.deinit();

    // Create extremely long argument strings
    const long_function_name = "a" ** 1000;
    const long_workspace_name = "workspace_" ++ ("x" ** 500);
    const very_long_path = "/tmp/" ++ ("very_long_directory_name/" ** 10) ++ "file.zig";

    const long_arg_commands = [_][]const []const u8{
        &[_][]const u8{ "find", "function", long_function_name },
        &[_][]const u8{ "find", "function", "test", "in", long_workspace_name },
        &[_][]const u8{ "link", very_long_path },
        &[_][]const u8{ "show", "callers", long_function_name },
    };

    for (long_arg_commands) |cmd_args| {
        var result = try test_harness.execute_command(cmd_args);
        defer result.deinit();

        // Should handle long arguments without buffer overflow or crash
        try testing.expect(result.exit_code != 139 and result.exit_code != 11);

        // Should either succeed or fail gracefully
        if (result.exit_code != 0) {
            try testing.expect(result.stderr.len > 0 or result.stdout.len > 0);
        }
    }
}

test "unicode and non-ASCII characters in arguments" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "unicode_args");
    defer test_harness.deinit();

    const unicode_commands = [_][]const []const u8{
        &[_][]const u8{ "find", "function", "función", "in", "workspace" }, // Spanish
        &[_][]const u8{ "find", "function", "函数", "in", "workspace" }, // Chinese
        &[_][]const u8{ "show", "callers", "тест", "in", "workspace" }, // Cyrillic
        &[_][]const u8{ "trace", "callees", "नाम", "in", "workspace" }, // Hindi
    };

    for (unicode_commands) |cmd_args| {
        var result = try test_harness.execute_command(cmd_args);
        defer result.deinit();

        // Should handle unicode without crashing or corrupting memory
        try testing.expect(result.exit_code != 139 and result.exit_code != 11);
    }
}

test "concurrent command execution safety" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "concurrent_safety");
    defer test_harness.deinit();

    // Create test workspace
    const project_path = try test_harness.create_test_project("concurrent_test");
    var link_result = try test_harness.execute_workspace_command("link {s} as concurrent", .{project_path});
    defer link_result.deinit();

    if (link_result.exit_code == 0) {
        // Execute multiple commands rapidly in sequence to simulate concurrent usage
        const rapid_commands = [_][]const []const u8{
            &[_][]const u8{"status"},
            &[_][]const u8{ "find", "function", "main", "in", "concurrent" },
            &[_][]const u8{ "show", "callers", "test", "in", "concurrent" },
            &[_][]const u8{ "trace", "callees", "helper", "in", "concurrent" },
            &[_][]const u8{"status"},
        };

        for (rapid_commands) |cmd_args| {
            var result = try test_harness.execute_command(cmd_args);
            defer result.deinit();

            // Each command should complete without interference
            try testing.expect(result.exit_code != 139 and result.exit_code != 11);
        }
    }
}

test "invalid workspace references produce helpful errors" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "invalid_workspace");
    defer test_harness.deinit();

    const invalid_workspace_commands = [_][]const []const u8{
        &[_][]const u8{ "find", "function", "test", "in", "nonexistent_workspace" },
        &[_][]const u8{ "show", "callers", "func", "in", "missing_workspace" },
        &[_][]const u8{ "trace", "callees", "func", "in", "invalid_workspace" },
        &[_][]const u8{ "sync", "nonexistent_workspace" },
        &[_][]const u8{ "unlink", "missing_workspace" },
    };

    for (invalid_workspace_commands) |cmd_args| {
        var result = try test_harness.execute_command(cmd_args);
        defer result.deinit();

        // Should fail gracefully with informative error
        if (result.exit_code != 0) {
            try testing.expect(result.stderr.len > 0 or result.stdout.len > 0);

            // Should mention workspace-related error
            const has_workspace_error = result.contains_error("workspace") or
                result.contains_error("not found") or
                result.contains_error("does not exist") or
                result.contains_error("unknown");
            try testing.expect(has_workspace_error);
        }
    }
}

test "memory exhaustion scenarios are handled gracefully" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "memory_exhaustion");
    defer test_harness.deinit();

    // Create project with substantial content to potentially trigger memory issues
    const project_path = try test_harness.create_substantial_content_project("memory_test");

    // Test operations that might consume significant memory
    var link_result = try test_harness.execute_command(&[_][]const u8{ "link", project_path, "as", "memory_test" });
    defer link_result.deinit();

    // Should not crash even if memory is limited
    try testing.expect(link_result.exit_code != 139 and link_result.exit_code != 11);

    if (link_result.exit_code == 0) {
        // Test sync with substantial content
        var sync_result = try test_harness.execute_command(&[_][]const u8{ "sync", "memory_test" });
        defer sync_result.deinit();

        try testing.expect(sync_result.exit_code != 139 and sync_result.exit_code != 11);

        // Test queries that might traverse large data structures
        var query_result = try test_harness.execute_command(&[_][]const u8{ "find", "function", "large_function", "in", "memory_test" });
        defer query_result.deinit();

        try testing.expect(query_result.exit_code != 139 and query_result.exit_code != 11);
    }
}
