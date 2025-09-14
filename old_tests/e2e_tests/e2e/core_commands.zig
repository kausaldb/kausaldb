//! End-to-end tests for core KausalDB binary commands.
//!
//! Tests basic binary interface functionality through subprocess execution
//! to validate user-facing command behavior and output formatting.
//! Focus on essential commands that must work reliably in 0.1.0.

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
    try testing.expect(result.contains_output("Workspace Commands:"));
    try testing.expect(result.contains_output("link"));
    try testing.expect(result.contains_output("unlink"));
    try testing.expect(result.contains_output("sync"));
    try testing.expect(result.contains_output("Query Commands:"));
    try testing.expect(result.contains_output("find"));
    try testing.expect(result.contains_output("show"));
    try testing.expect(result.contains_output("trace"));
}

test "status command shows workspace information" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "status_test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&[_][]const u8{"status"});
    defer result.deinit();

    try result.expect_success();
    // Empty workspace should indicate no linked codebases
    try testing.expect(result.contains_output("WORKSPACE") or result.contains_output("No codebases"));
}

test "default behavior shows help when no arguments" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "default_test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&[_][]const u8{});
    defer result.deinit();

    try result.expect_success();
    try testing.expect(result.contains_output("Usage:"));
}

test "invalid command shows error and help" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "invalid_test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&[_][]const u8{"nonexistent_command_12345"});
    defer result.deinit();

    try result.expect_failure();
    try testing.expect(result.contains_error("Unknown command") or result.contains_error("Invalid command"));
    // Should show help on error
    try testing.expect(result.contains_output("Usage:"));
}

test "help with specific topic works" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "help_topic_test");
    defer test_harness.deinit();

    // Test help for workspace commands
    var result = try test_harness.execute_command(&[_][]const u8{ "help", "workspace" });
    defer result.deinit();

    try result.expect_success();
    try testing.expect(result.contains_output("link") or result.contains_output("workspace"));
}

test "json output format works for status" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "json_test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&[_][]const u8{ "status", "--json" });
    defer result.deinit();

    try result.expect_success();

    // Validate JSON structure
    var parsed = try test_harness.validate_json_output(result.stdout);
    defer parsed.deinit();

    // Should be valid JSON with expected structure
    try testing.expect(parsed.value == .object);
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
    // Command should complete within reasonable time (1 second is generous for version)
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
        // All errors should write to stderr, not stdout for error messages
        try testing.expect(result.stderr.len > 0);
    }
}

test "command output is clean and parseable" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "output_format_test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&[_][]const u8{"version"});
    defer result.deinit();

    try result.expect_success();

    // Version output should be clean single line
    var lines = std.mem.splitSequence(u8, std.mem.trim(u8, result.stdout, " \n\r\t"), "\n");
    var line_count: usize = 0;
    while (lines.next()) |_| line_count += 1;

    // Version should be concise - no more than 3 lines
    try testing.expect(line_count <= 3);
}
