//! End-to-end tests for KausalDB CLI v2.
//!
//! Tests the complete CLI experience through subprocess execution,
//! validating command parsing, output formatting, and error handling.

const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

const harness = @import("harness.zig");

const log = std.log.scoped(.cli_v2_e2e);

test "cli_v2: help command displays usage information" {
    const allocator = testing.allocator;
    var test_harness = try harness.E2EHarness.init(allocator, "help_test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&.{"help"});
    defer result.deinit();

    try testing.expect(result.exit_code == 0);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "KausalDB - Graph Database for AI Context") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "Core Commands:") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "Query Commands:") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "Workspace Commands:") != null);
}

test "cli_v2: help command with topic shows detailed help" {
    const allocator = testing.allocator;
    var test_harness = try harness.E2EHarness.init(allocator, "test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&.{ "help", "find" });
    defer result.deinit();

    try testing.expect(result.exit_code == 0);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "kausal find - Find blocks matching a query") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "--format") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "--max-results") != null);
}

test "cli_v2: version command shows version" {
    const allocator = testing.allocator;
    var test_harness = try harness.E2EHarness.init(allocator, "test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&.{"version"});
    defer result.deinit();

    try testing.expect(result.exit_code == 0);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "KausalDB v0.1.0") != null);
}

test "cli_v2: --version flag shows version" {
    const allocator = testing.allocator;
    var test_harness = try harness.E2EHarness.init(allocator, "test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&.{"--version"});
    defer result.deinit();

    try testing.expect(result.exit_code == 0);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "KausalDB v0.1.0") != null);
}

test "cli_v2: --help flag shows help" {
    const allocator = testing.allocator;
    var test_harness = try harness.E2EHarness.init(allocator, "test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&.{"--help"});
    defer result.deinit();

    try testing.expect(result.exit_code == 0);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "KausalDB - Graph Database for AI Context") != null);
}

test "cli_v2: unknown command shows error" {
    const allocator = testing.allocator;
    var test_harness = try harness.E2EHarness.init(allocator, "test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&.{"unknown_command"});
    defer result.deinit();

    try testing.expect(result.exit_code != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "Unknown command: unknown_command") != null);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "Run 'kausal help' for usage information") != null);
}

test "cli_v2: find command requires query argument" {
    const allocator = testing.allocator;
    var test_harness = try harness.E2EHarness.init(allocator, "test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&.{"find"});
    defer result.deinit();

    try testing.expect(result.exit_code != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "Missing required argument") != null);
}

test "cli_v2: show command requires direction and target" {
    const allocator = testing.allocator;
    var test_harness = try harness.E2EHarness.init(allocator, "test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&.{"show"});
    defer result.deinit();

    try testing.expect(result.exit_code != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "Missing required argument") != null);
}

test "cli_v2: trace command requires source and target" {
    const allocator = testing.allocator;
    var test_harness = try harness.E2EHarness.init(allocator, "test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&.{ "trace", "main" });
    defer result.deinit();

    try testing.expect(result.exit_code != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "Missing required argument") != null);
}

test "cli_v2: link command requires path and name" {
    const allocator = testing.allocator;
    var test_harness = try harness.E2EHarness.init(allocator, "test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&.{ "link", "/some/path" });
    defer result.deinit();

    try testing.expect(result.exit_code != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "Missing required argument") != null);
}

test "cli_v2: invalid output format shows error" {
    const allocator = testing.allocator;
    var test_harness = try harness.E2EHarness.init(allocator, "test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&.{ "find", "test", "--format", "xml" });
    defer result.deinit();

    try testing.expect(result.exit_code != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "Error:") != null);
}

test "cli_v2: invalid number argument shows error" {
    const allocator = testing.allocator;
    var test_harness = try harness.E2EHarness.init(allocator, "test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&.{ "find", "test", "--max-results", "abc" });
    defer result.deinit();

    try testing.expect(result.exit_code != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "Error:") != null);
}

test "cli_v2: server status when not running" {
    const allocator = testing.allocator;
    var test_harness = try harness.E2EHarness.init(allocator, "test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&.{ "server", "status" });
    defer result.deinit();

    // Should succeed but indicate server is not running
    try testing.expect(result.exit_code == 0);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "Server is not running") != null);
}

test "cli_v2: status command requires running server" {
    const allocator = testing.allocator;
    var test_harness = try harness.E2EHarness.init(allocator, "test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&.{"status"});
    defer result.deinit();

    try testing.expect(result.exit_code != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "Server not running") != null);
}

test "cli_v2: find command requires running server" {
    const allocator = testing.allocator;
    var test_harness = try harness.E2EHarness.init(allocator, "test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&.{ "find", "test_query" });
    defer result.deinit();

    try testing.expect(result.exit_code != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "Server not running") != null);
}

test "cli_v2: json output format for version" {
    const allocator = testing.allocator;
    var test_harness = try harness.E2EHarness.init(allocator, "test");
    defer test_harness.deinit();

    // Version command doesn't support format flags directly, but we can test the parser
    var result = try test_harness.execute_command(&.{"version"});
    defer result.deinit();

    try testing.expect(result.exit_code == 0);
    // For now, version always outputs text format
    try testing.expect(std.mem.indexOf(u8, result.stdout, "KausalDB") != null);
}

test "cli_v2: sync command with workspace name" {
    const allocator = testing.allocator;
    var test_harness = try harness.E2EHarness.init(allocator, "test");
    defer test_harness.deinit();

    // This will fail without a running server, but we're testing parsing
    var result = try test_harness.execute_command(&.{ "sync", "myworkspace", "--force" });
    defer result.deinit();

    // Should fail due to no server, not due to parsing
    try testing.expect(result.exit_code != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "Server not running") != null);
}

test "cli_v2: show command with invalid direction" {
    const allocator = testing.allocator;
    var test_harness = try harness.E2EHarness.init(allocator, "test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&.{ "show", "invalid_direction", "target" });
    defer result.deinit();

    try testing.expect(result.exit_code != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "Invalid argument") != null);
}

test "cli_v2: server command with invalid mode" {
    const allocator = testing.allocator;
    var test_harness = try harness.E2EHarness.init(allocator, "test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&.{ "server", "invalid_mode" });
    defer result.deinit();

    try testing.expect(result.exit_code != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "Invalid argument") != null);
}

test "cli_v2: too many arguments for version" {
    const allocator = testing.allocator;
    var test_harness = try harness.E2EHarness.init(allocator, "test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&.{ "version", "extra", "arguments" });
    defer result.deinit();

    try testing.expect(result.exit_code != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "Error:") != null);
}

test "cli_v2: server command with port option" {
    const allocator = testing.allocator;
    var test_harness = try harness.E2EHarness.init(allocator, "test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&.{ "server", "status", "--port", "8080" });
    defer result.deinit();

    // Should succeed but indicate server is not running on that port
    try testing.expect(result.exit_code == 0);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "Server is not running") != null);
}

test "cli_v2: status command with verbose flag" {
    const allocator = testing.allocator;
    var test_harness = try harness.E2EHarness.init(allocator, "test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&.{ "status", "--verbose" });
    defer result.deinit();

    // Should fail due to no server
    try testing.expect(result.exit_code != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "Server not running") != null);
}

test "cli_v2: find command with show metadata flag" {
    const allocator = testing.allocator;
    var test_harness = try harness.E2EHarness.init(allocator, "test");
    defer test_harness.deinit();

    var result = try test_harness.execute_command(&.{ "find", "query", "--show-metadata" });
    defer result.deinit();

    // Should fail due to no server
    try testing.expect(result.exit_code != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "Server not running") != null);
}
