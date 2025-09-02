//! E2E tests for CLI flag parsing and validation.
//!
//! Tests standard UNIX CLI conventions and comprehensive flag support.
//! Validates proper error handling and user experience for command-line flags.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");

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

    // Test -v flag (should NOT conflict with verbose - use different flag for verbose)
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
        try testing.expect(result.contains_error("Unknown") or result.contains_error("Invalid"));
    }

    // Test unknown short flag
    {
        var result = try test_harness.execute_command(&[_][]const u8{"-x"});
        defer result.deinit();

        try result.expect_failure();
        try testing.expect(result.contains_error("Unknown") or result.contains_error("Invalid"));
    }
}

test "flag parsing handles mixed arguments correctly" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "mixed_args");
    defer test_harness.deinit();

    // Test help flag mixed with command
    {
        var result = try test_harness.execute_command(&[_][]const u8{ "find", "--help" });
        defer result.deinit();

        try result.expect_success();
        try testing.expect(result.contains_output("find") or result.contains_output("Usage:"));
    }

    // Test global flag before command
    {
        var result = try test_harness.execute_command(&[_][]const u8{ "--version", "find", "function", "test" });
        defer result.deinit();

        // Should show version, not execute find
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
        try testing.expect(result.contains_error("Invalid") or result.contains_error("Unknown"));
    }

    // Test single dash without flag
    {
        var result = try test_harness.execute_command(&[_][]const u8{"-"});
        defer result.deinit();

        try result.expect_failure();
        try testing.expect(result.contains_error("Invalid") or result.contains_error("Unknown"));
    }
}

test "help provides information about available flags" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "help_flags_info");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&[_][]const u8{"help"});
    defer result.deinit();

    try result.expect_success();

    // Should document the standard flags
    try testing.expect(result.contains_output("--help") or result.contains_output("-h"));
    try testing.expect(result.contains_output("--version") or result.contains_output("-v"));
}

test "flag consistency across all commands" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "flag_consistency");
    defer test_harness.deinit();

    const commands = [_][]const u8{ "version", "help", "status" };

    for (commands) |cmd| {
        // Each command should support --help
        var result = try test_harness.execute_command(&[_][]const u8{ cmd, "--help" });
        defer result.deinit();

        // Should either show help or execute successfully
        // Both are acceptable as long as no segfault occurs
        try testing.expect(result.exit_code != 139 and result.exit_code != 11); // No segfault
    }
}
