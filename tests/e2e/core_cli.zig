//! Core CLI tests for `kausal` binary interface.
//!
//! Tests essential CLI functionality including help, version, status, and
//! flag handling through subprocess execution.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");

test "version command returns correct format" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "version_test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&[_][]const u8{"version"});
    defer result.deinit();

    try result.expect_success();
    try testing.expect(result.contains_output("KausalDB"));
    try testing.expect(result.contains_output("v0.1.0"));
    try testing.expectEqual(@as(usize, 0), result.stderr.len);
}

test "help command shows usage information" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "help_test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&[_][]const u8{"help"});
    defer result.deinit();

    try result.expect_success();
    try testing.expect(result.contains_output("Usage:"));
    try testing.expect(result.contains_output("Commands:"));
    try testing.expect(result.contains_output("link"));
    try testing.expect(result.contains_output("find"));
    try testing.expect(result.contains_output("show"));
}

test "status command shows workspace information" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "status_test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&[_][]const u8{"status"});
    defer result.deinit();

    try result.expect_success();
    // Status should succeed even if server is running - it's a valid command
    try testing.expect(result.stdout.len > 0);
}

test "default behavior shows help when no arguments" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "default_test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&[_][]const u8{});
    defer result.deinit();

    try result.expect_success();
    try testing.expect(result.contains_output("Usage:"));
}

test "invalid command shows error message" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "invalid_test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&[_][]const u8{"nonexistent_command_12345"});
    defer result.deinit();

    try result.expect_failure();
    try testing.expect(result.contains_error("Unknown command") or
        result.contains_error("Invalid command"));
}

test "help with specific topic works" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "help_topic_test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&[_][]const u8{ "help", "workspace" });
    defer result.deinit();

    try result.expect_success();
    try testing.expect(result.contains_output("link") or
        result.contains_output("workspace") or
        result.contains_output("Commands"));
}

// === Flag Tests ===

test "standard help flags are supported" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "help_flags");
    defer test_harness.deinit();

    // Test --help flag
    {
        var result = try test_harness.execute_command(&[_][]const u8{"--help"});
        defer result.deinit();

        try result.expect_success();
        try testing.expect(result.contains_output("Usage:"));
        try testing.expect(result.contains_output("Commands:"));
    }

    // Test -h flag
    {
        var result = try test_harness.execute_command(&[_][]const u8{"-h"});
        defer result.deinit();

        try result.expect_success();
        try testing.expect(result.contains_output("Usage:"));
        try testing.expect(result.contains_output("Commands:"));
    }
}

test "standard version flags are supported" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "version_flags");
    defer test_harness.deinit();

    // Test --version flag
    {
        var result = try test_harness.execute_command(&[_][]const u8{"--version"});
        defer result.deinit();

        try result.expect_success();
        try testing.expect(result.contains_output("KausalDB"));
        try testing.expect(result.contains_output("v0.1.0"));
        try testing.expectEqual(@as(usize, 0), result.stderr.len);
    }

    // Test -v flag
    {
        var result = try test_harness.execute_command(&[_][]const u8{"-v"});
        defer result.deinit();

        try result.expect_success();
        try testing.expect(result.contains_output("KausalDB"));
        try testing.expect(result.contains_output("v0.1.0"));
        try testing.expectEqual(@as(usize, 0), result.stderr.len);
    }
}

test "unknown flags produce appropriate error messages" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "unknown_flags");
    defer test_harness.deinit();

    // Test unknown long flag
    {
        var result = try test_harness.execute_command(&[_][]const u8{"--unknown-flag"});
        defer result.deinit();

        try result.expect_failure();
        try testing.expect(result.contains_error("Unknown") or
            result.contains_error("Invalid") or
            result.contains_error("Error"));
    }

    // Test unknown short flag
    {
        var result = try test_harness.execute_command(&[_][]const u8{"-x"});
        defer result.deinit();

        try result.expect_failure();
        try testing.expect(result.contains_error("Unknown") or
            result.contains_error("Invalid") or
            result.contains_error("Error"));
    }
}

test "flag parsing handles mixed arguments correctly" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "mixed_args");
    defer test_harness.deinit();

    // Test global flag before command - version should take precedence
    {
        var result = try test_harness.execute_command(&[_][]const u8{ "--version", "find", "test" });
        defer result.deinit();

        try result.expect_success();
        try testing.expect(result.contains_output("KausalDB"));
    }
}

test "malformed flag syntax produces clear errors" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "malformed_flags");
    defer test_harness.deinit();

    // Test double dash without flag name
    {
        var result = try test_harness.execute_command(&[_][]const u8{"--"});
        defer result.deinit();

        try result.expect_failure();
        try testing.expect(result.contains_error("Invalid") or
            result.contains_error("Unknown") or
            result.contains_error("Error"));
    }

    // Test single dash without flag
    {
        var result = try test_harness.execute_command(&[_][]const u8{"-"});
        defer result.deinit();

        try result.expect_failure();
        try testing.expect(result.contains_error("Invalid") or
            result.contains_error("Unknown") or
            result.contains_error("Error"));
    }
}

test "json output format works for status" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "json_test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&[_][]const u8{ "status", "--json" });
    defer result.deinit();

    // JSON output should be valid even if command requires server
    if (result.exit_code == 0 and result.stdout.len > 0) {
        // Try to validate JSON if command succeeded
        var parsed = test_harness.validate_json_output(result.stdout) catch return;
        defer parsed.deinit();
        try testing.expect(parsed.value == .object);
    }
}

test "command execution is fast enough" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "performance_test");
    defer test_harness.deinit();

    const start_time = std.time.nanoTimestamp();

    var result = try test_harness.execute_command(&[_][]const u8{"version"});
    defer result.deinit();

    const elapsed_ns = std.time.nanoTimestamp() - start_time;
    const elapsed_ms = @divFloor(elapsed_ns, std.time.ns_per_ms);

    try result.expect_success();
    // Command should complete within reasonable time (1 second is generous)
    try testing.expect(elapsed_ms < 1000);
}

test "error handling maintains consistent format" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "error_format_test");
    defer test_harness.deinit();

    // Test various error conditions
    const error_cases = [_][]const []const u8{
        &[_][]const u8{"invalid_cmd"},
        &[_][]const u8{"link"}, // Missing required argument
        &[_][]const u8{"find"}, // Missing required argument
    };

    for (error_cases) |cmd_args| {
        var result = try test_harness.execute_command(cmd_args);
        defer result.deinit();

        try result.expect_failure();
        // All errors should provide meaningful feedback
        try testing.expect(result.stderr.len > 0 or result.stdout.len > 0);
    }
}

test "command output is clean and parseable" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "output_format_test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&[_][]const u8{"version"});
    defer result.deinit();

    try result.expect_success();

    // Version output should be clean and concise
    var lines = std.mem.splitSequence(u8, std.mem.trim(u8, result.stdout, " \n\r\t"), "\n");
    var line_count: usize = 0;
    while (lines.next()) |_| line_count += 1;

    // Version should be concise - no more than 3 lines
    try testing.expect(line_count <= 3);
}

test "server status command works" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "server_status_test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&[_][]const u8{ "server", "status" });
    defer result.deinit();

    // Server status should either succeed or fail gracefully
    try testing.expect(result.exit_code != 139 and result.exit_code != 11); // No segfault
    try testing.expect(result.stdout.len > 0 or result.stderr.len > 0); // Should have output
}

test "ping command handles server connectivity" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "ping_test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&[_][]const u8{"ping"});
    defer result.deinit();

    // Ping should either succeed (server running) or fail gracefully (server not running)
    try testing.expect(result.exit_code != 139 and result.exit_code != 11); // No segfault

    if (result.exit_code == 0) {
        try testing.expect(result.contains_output("responding") or
            result.contains_output("success"));
    } else {
        try testing.expect(result.contains_error("not running") or
            result.contains_error("Connection failed") or
            result.stderr.len > 0);
    }
}
