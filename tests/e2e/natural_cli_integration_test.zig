//! End-to-end integration tests for natural language CLI binary interface.
//!
//! Tests natural language CLI functionality through binary execution to validate
//! complete user experience and output formatting. These tests ensure the CLI
//! behavior matches documentation and catches regressions in user-facing interface.

const std = @import("std");
const testing = std.testing;

const binary_interface = @import("binary_interface.zig");

/// Execute KausalDB binary with natural language arguments
fn exec_natural_command(allocator: std.mem.Allocator, command: []const u8) !std.process.Child.RunResult {
    return binary_interface.exec_kausaldb(allocator, &[_][]const u8{ "natural", command });
}

/// Create isolated test database for natural language testing
fn create_test_database(allocator: std.mem.Allocator, db_name: []const u8) ![]const u8 {
    const test_dir = try binary_interface.create_test_dir(allocator, db_name);

    // Initialize database in test directory
    const init_result = try binary_interface.exec_kausaldb(allocator, &[_][]const u8{ "init", "--path", test_dir, "--name", db_name });
    defer allocator.free(init_result.stdout);
    defer allocator.free(init_result.stderr);

    try testing.expectEqual(@as(u32, 0), init_result.term.Exited);
    return test_dir;
}

test "natural language basic query commands" {
    const allocator = testing.allocator;

    // Build binary to ensure latest version
    const build_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "./zig/zig", "build" },
    });
    defer allocator.free(build_result.stdout);
    defer allocator.free(build_result.stderr);
    try testing.expectEqual(@as(u32, 0), build_result.term.Exited);

    const test_db = try create_test_database(allocator, "natural_test");
    defer binary_interface.cleanup_test_dir(allocator, test_db);

    // Test basic help for natural language commands
    const help_result = try binary_interface.exec_kausaldb(allocator, &[_][]const u8{ "natural", "--help" });
    defer allocator.free(help_result.stdout);
    defer allocator.free(help_result.stderr);

    try testing.expectEqual(@as(u32, 0), help_result.term.Exited);
    try testing.expect(std.mem.indexOf(u8, help_result.stdout, "natural language") != null);
}

test "natural language simple queries" {
    const allocator = testing.allocator;

    const test_db = try create_test_database(allocator, "simple_queries");
    defer binary_interface.cleanup_test_dir(allocator, test_db);

    // Test simple natural language query
    const query_result = try exec_natural_command(allocator, "show me all functions");
    defer allocator.free(query_result.stdout);
    defer allocator.free(query_result.stderr);

    // Should succeed even with empty database
    try testing.expectEqual(@as(u32, 0), query_result.term.Exited);

    // Test malformed natural language query
    const malformed_result = try exec_natural_command(allocator, "asdfghjkl nonsense query");
    defer allocator.free(malformed_result.stdout);
    defer allocator.free(malformed_result.stderr);

    // Should provide helpful error message
    try testing.expect(malformed_result.term.Exited != 0);
    try testing.expect(std.mem.indexOf(u8, malformed_result.stderr, "understand") != null or
        std.mem.indexOf(u8, malformed_result.stderr, "parse") != null);
}

test "natural language output formatting" {
    const allocator = testing.allocator;

    const test_db = try create_test_database(allocator, "output_format");
    defer binary_interface.cleanup_test_dir(allocator, test_db);

    // Test JSON output format
    const json_result = try binary_interface.exec_kausaldb(allocator, &[_][]const u8{ "natural", "--format", "json", "find all blocks" });
    defer allocator.free(json_result.stdout);
    defer allocator.free(json_result.stderr);

    try testing.expectEqual(@as(u32, 0), json_result.term.Exited);

    // Output should be valid JSON structure
    const parsed_json = std.json.parseFromSlice(std.json.Value, allocator, json_result.stdout, .{}) catch |err| {
        std.debug.print("Invalid JSON output: {s}\nError: {}\n", .{ json_result.stdout, err });
        return err;
    };
    defer parsed_json.deinit();

    // Test table output format
    const table_result = try binary_interface.exec_kausaldb(allocator, &[_][]const u8{ "natural", "--format", "table", "find all blocks" });
    defer allocator.free(table_result.stdout);
    defer allocator.free(table_result.stderr);

    try testing.expectEqual(@as(u32, 0), table_result.term.Exited);

    // Table format should include headers and structured output
    try testing.expect(std.mem.indexOf(u8, table_result.stdout, "│") != null or
        std.mem.indexOf(u8, table_result.stdout, "|") != null);
}

test "natural language error handling" {
    const allocator = testing.allocator;

    // Test command without database initialization
    const no_db_result = try exec_natural_command(allocator, "show all functions");
    defer allocator.free(no_db_result.stdout);
    defer allocator.free(no_db_result.stderr);

    // Should fail gracefully with informative error
    try testing.expect(no_db_result.term.Exited != 0);
    try testing.expect(std.mem.indexOf(u8, no_db_result.stderr, "database") != null or
        std.mem.indexOf(u8, no_db_result.stderr, "init") != null);

    // Test invalid command line arguments
    const invalid_args_result = try binary_interface.exec_kausaldb(allocator, &[_][]const u8{ "natural", "--invalid-flag", "query" });
    defer allocator.free(invalid_args_result.stdout);
    defer allocator.free(invalid_args_result.stderr);

    try testing.expect(invalid_args_result.term.Exited != 0);
    try testing.expect(std.mem.indexOf(u8, invalid_args_result.stderr, "flag") != null or
        std.mem.indexOf(u8, invalid_args_result.stderr, "option") != null);
}

test "natural language query complexity handling" {
    const allocator = testing.allocator;

    const test_db = try create_test_database(allocator, "complexity_test");
    defer binary_interface.cleanup_test_dir(allocator, test_db);

    // Test complex multi-part natural language query
    const complex_result = try exec_natural_command(allocator, "find all functions that call other functions and show their dependencies");
    defer allocator.free(complex_result.stdout);
    defer allocator.free(complex_result.stderr);

    // Should parse and execute without crashing
    try testing.expectEqual(@as(u32, 0), complex_result.term.Exited);

    // Test very long query string
    const long_query = "show me all the functions and classes and their relationships " ++
        "including imports and dependencies and also their documentation " ++
        "and metadata in a structured format with full details";

    const long_result = try exec_natural_command(allocator, long_query);
    defer allocator.free(long_result.stdout);
    defer allocator.free(long_result.stderr);

    // Should handle gracefully without buffer overflow or crash
    try testing.expect(long_result.term.Exited == 0 or long_result.term.Exited == 1);
}
