//! E2E tests for relationship commands (show callers, trace callees) safety.
//!
//! Tests memory safety and robustness of relationship traversal commands.
//! Ensures commands handle edge cases gracefully without crashes.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");

test "show callers command does not segfault with simple target" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "show_callers_basic");
    defer test_harness.deinit();

    // Create and link test project
    const project_path = try test_harness.create_test_project("callers_test");
    var link_result = try test_harness.execute_workspace_command("link {s} as testproject", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    // Sync the project to ingest code
    var sync_result = try test_harness.execute_workspace_command("sync testproject", .{});
    defer sync_result.deinit();
    try sync_result.expect_success();

    // Test show callers command - this should NOT segfault
    var result = try test_harness.execute_command(&[_][]const u8{ "show", "callers", "helper", "in", "testproject" });
    defer result.deinit();

    // Should not crash with segfault (exit codes 139 or 11)
    try testing.expect(result.exit_code != 139 and result.exit_code != 11);

    // Command may succeed or fail gracefully, but should not crash
    if (result.exit_code != 0) {
        // If it fails, should have proper error message
        try testing.expect(result.stderr.len > 0 or result.stdout.len > 0);
    }
}

test "trace callees command does not segfault with simple target" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "trace_callees_basic");
    defer test_harness.deinit();

    // Create and link test project
    const project_path = try test_harness.create_test_project("callees_test");
    var link_result = try test_harness.execute_workspace_command("link {s} as testproject", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    // Sync the project to ingest code
    var sync_result = try test_harness.execute_workspace_command("sync testproject", .{});
    defer sync_result.deinit();
    try sync_result.expect_success();

    // Test trace callees command - this should NOT segfault
    var result = try test_harness.execute_command(&[_][]const u8{ "trace", "callees", "main", "in", "testproject" });
    defer result.deinit();

    // Should not crash with segfault (exit codes 139 or 11)
    try testing.expect(result.exit_code != 139 and result.exit_code != 11);

    // Command may succeed or fail gracefully, but should not crash
    if (result.exit_code != 0) {
        // If it fails, should have proper error message
        try testing.expect(result.stderr.len > 0 or result.stdout.len > 0);
    }
}

test "show callers with various entity names handles edge cases safely" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "show_callers_edge_cases");
    defer test_harness.deinit();

    // Create and link test project
    const project_path = try test_harness.create_test_project("edge_cases_test");
    var link_result = try test_harness.execute_workspace_command("link {s} as edgetest", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    // Sync the project
    var sync_result = try test_harness.execute_workspace_command("sync edgetest", .{});
    defer sync_result.deinit();
    try sync_result.expect_success();

    const test_targets = [_][]const u8{
        "nonexistent_function",
        "calculate_value", // Function that actually exists
        "main", // Entry point function
        "helper_function", // Function that exists
        "", // Empty string - should not crash
        "very_long_function_name_that_does_not_exist_anywhere",
    };

    for (test_targets) |target| {
        var result = try test_harness.execute_command(&[_][]const u8{ "show", "callers", target, "in", "edgetest" });
        defer result.deinit();

        // Most important: should never segfault
        try testing.expect(result.exit_code != 139 and result.exit_code != 11);

        // Should either succeed or fail with clear message
        if (result.exit_code != 0) {
            // Error should be descriptive, not just a crash
            try testing.expect(result.stderr.len > 0 or result.stdout.len > 0);
        }
    }
}

test "trace callees with depth parameters handles memory safely" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "trace_callees_depth");
    defer test_harness.deinit();

    // Create and link test project
    const project_path = try test_harness.create_test_project("depth_test");
    var link_result = try test_harness.execute_workspace_command("link {s} as depthtest", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    // Sync the project
    var sync_result = try test_harness.execute_workspace_command("sync depthtest", .{});
    defer sync_result.deinit();
    try sync_result.expect_success();

    const depth_values = [_][]const u8{ "1", "3", "5", "10" };

    for (depth_values) |depth| {
        var result = try test_harness.execute_command(&[_][]const u8{ "trace", "callees", "main", "in", "depthtest", "--depth", depth });
        defer result.deinit();

        // Should not segfault regardless of depth value
        try testing.expect(result.exit_code != 139 and result.exit_code != 11);
    }
}

test "relationship commands handle missing workspace gracefully" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "missing_workspace");
    defer test_harness.deinit();

    // Test commands with workspace that doesn't exist
    {
        var result = try test_harness.execute_command(&[_][]const u8{ "show", "callers", "test", "in", "nonexistent_workspace" });
        defer result.deinit();

        try testing.expect(result.exit_code != 139 and result.exit_code != 11);
        if (result.exit_code != 0) {
            try testing.expect(result.contains_error("workspace") or result.contains_error("not found"));
        }
    }

    {
        var result = try test_harness.execute_command(&[_][]const u8{ "trace", "callees", "test", "in", "nonexistent_workspace" });
        defer result.deinit();

        try testing.expect(result.exit_code != 139 and result.exit_code != 11);
        if (result.exit_code != 0) {
            try testing.expect(result.contains_error("workspace") or result.contains_error("not found"));
        }
    }
}

test "relationship commands with JSON output format are memory safe" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "json_output_safety");
    defer test_harness.deinit();

    // Create and link test project
    const project_path = try test_harness.create_test_project("json_test");
    var link_result = try test_harness.execute_workspace_command("link {s} as jsontest", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    // Sync the project
    var sync_result = try test_harness.execute_workspace_command("sync jsontest", .{});
    defer sync_result.deinit();
    try sync_result.expect_success();

    // Test JSON output format - historically prone to formatting bugs
    {
        var result = try test_harness.execute_command(&[_][]const u8{ "show", "callers", "main", "in", "jsontest", "--json" });
        defer result.deinit();

        try testing.expect(result.exit_code != 139 and result.exit_code != 11);

        // If successful, should produce valid JSON or clear error
        if (result.exit_code == 0) {
            // Should at least not be empty if JSON format is working
            try testing.expect(result.stdout.len > 0);
        }
    }

    {
        var result = try test_harness.execute_command(&[_][]const u8{ "trace", "callees", "main", "in", "jsontest", "--json" });
        defer result.deinit();

        try testing.expect(result.exit_code != 139 and result.exit_code != 11);

        if (result.exit_code == 0) {
            try testing.expect(result.stdout.len > 0);
        }
    }
}

test "concurrent relationship queries do not interfere with memory safety" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "concurrent_queries");
    defer test_harness.deinit();

    // Create and link test project
    const project_path = try test_harness.create_test_project("concurrent_test");
    var link_result = try test_harness.execute_workspace_command("link {s} as concurrenttest", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    // Sync the project
    var sync_result = try test_harness.execute_workspace_command("sync concurrenttest", .{});
    defer sync_result.deinit();
    try sync_result.expect_success();

    // Execute multiple relationship queries in sequence (simulating rapid usage)
    const queries = [_][4][]const u8{
        .{ "show", "callers", "main", "concurrenttest" },
        .{ "trace", "callees", "helper_function", "concurrenttest" },
        .{ "show", "callers", "calculate_value", "concurrenttest" },
        .{ "trace", "callees", "add_numbers", "concurrenttest" },
    };

    for (queries) |query| {
        var result = try test_harness.execute_command(&[_][]const u8{ query[0], query[1], query[2], "in", query[3] });
        defer result.deinit();

        // Each query should complete without segfault
        try testing.expect(result.exit_code != 139 and result.exit_code != 11);
    }
}
