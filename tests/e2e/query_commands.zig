//! End-to-end tests for KausalDB query commands.
//!
//! Tests natural language query functionality (find, show, trace) through
//! binary execution. Currently tests placeholder responses until query
//! execution implementation is complete for v0.1.0.
//!
//! TODO: Update tests when query execution is fully implemented.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");

test "find function command shows placeholder response" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "find_function");
    defer test_harness.deinit();

    // Create and link test project
    const project_path = try test_harness.create_test_project("find_test");
    var link_result = try test_harness.execute_workspace_command("link {s}", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    var sync_result = try test_harness.execute_workspace_command("sync find_test", .{});
    defer sync_result.deinit();
    try sync_result.expect_success();

    // Test find function command
    var result = try test_harness.execute_command(&[_][]const u8{ "find", "function", "main" });
    defer result.deinit();

    try result.expect_success();
    // TODO: Update when real search is implemented
    // Currently expects placeholder response
    try testing.expect(result.contains_output("No function named 'main' found") or
        result.contains_output("main") or
        result.contains_output("Future"));
}

test "find function with workspace specification" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "find_workspace");
    defer test_harness.deinit();

    const project_path = try test_harness.create_test_project("workspace_test");
    var link_result = try test_harness.execute_workspace_command("link {s} as testws", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    // Test workspace-specific find
    var result = try test_harness.execute_command(&[_][]const u8{ "find", "function", "calculate_value", "in", "testws" });
    defer result.deinit();

    try result.expect_success();
    // TODO: Should find the calculate_value function in main.zig when implemented
    try testing.expect(result.stdout.len > 0);
}

test "show callers command placeholder response" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "show_callers");
    defer test_harness.deinit();

    const project_path = try test_harness.create_test_project("callers_test");
    var link_result = try test_harness.execute_workspace_command("link {s}", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    // Test show callers command
    var result = try test_harness.execute_command(&[_][]const u8{ "show", "callers", "helper_function" });
    defer result.deinit();

    try result.expect_success();
    // TODO: Should show that main() calls helper_function when implemented
    try testing.expect(result.contains_output("callers") or result.contains_output("helper_function"));
}

test "trace callees command with depth parameter" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "trace_callees");
    defer test_harness.deinit();

    const project_path = try test_harness.create_test_project("trace_test");
    var link_result = try test_harness.execute_workspace_command("link {s}", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    // Test trace command with depth
    var result = try test_harness.execute_command(&[_][]const u8{ "trace", "callees", "main", "--depth", "3" });
    defer result.deinit();

    try result.expect_success();
    // TODO: Should trace main -> helper_function -> calculate_value when implemented
    try testing.expect(result.contains_output("Tracing") or result.contains_output("main"));
}

test "trace callers command shows upstream dependencies" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "trace_callers");
    defer test_harness.deinit();

    const project_path = try test_harness.create_test_project("upstream_test");
    var link_result = try test_harness.execute_workspace_command("link {s}", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    // Test trace callers
    var result = try test_harness.execute_command(&[_][]const u8{ "trace", "callers", "calculate_value" });
    defer result.deinit();

    try result.expect_success();
    // TODO: Should trace calculate_value <- helper_function <- main when implemented
    try testing.expect(result.contains_output("callers") or result.contains_output("calculate_value"));
}

test "query commands with JSON output format" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "json_queries");
    defer test_harness.deinit();

    const project_path = try test_harness.create_test_project("json_test");
    var link_result = try test_harness.execute_workspace_command("link {s}", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    // Test find with JSON output
    var find_result = try test_harness.execute_command(&[_][]const u8{ "find", "function", "main", "--json" });
    defer find_result.deinit();

    try find_result.expect_success();

    // Should produce valid JSON (even if placeholder)
    if (find_result.contains_output("{")) {
        var parsed = test_harness.validate_json_output(find_result.stdout) catch |err| {
            std.debug.print("Invalid JSON output: {s}\n", .{find_result.stdout});
            return err;
        };
        defer parsed.deinit();
        try testing.expect(parsed.value == .object);
    }

    // Test trace with JSON output
    var trace_result = try test_harness.execute_command(&[_][]const u8{ "trace", "callees", "main", "--format", "json" });
    defer trace_result.deinit();

    try trace_result.expect_success();

    // Should produce valid JSON structure for graph data
    if (trace_result.contains_output("{")) {
        var parsed = test_harness.validate_json_output(trace_result.stdout) catch |err| {
            std.debug.print("Invalid JSON output: {s}\n", .{trace_result.stdout});
            return err;
        };
        defer parsed.deinit();
        try testing.expect(parsed.value == .object);
    }
}

test "query error handling: missing arguments" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "query_errors");
    defer test_harness.deinit();

    const error_cases = [_][]const []const u8{
        &[_][]const u8{"find"}, // Missing type and name
        &[_][]const u8{ "find", "function" }, // Missing name
        &[_][]const u8{"show"}, // Missing relation and target
        &[_][]const u8{ "show", "callers" }, // Missing target
        &[_][]const u8{"trace"}, // Missing direction and target
        &[_][]const u8{ "trace", "callees" }, // Missing target
    };

    for (error_cases) |cmd_args| {
        var result = try test_harness.execute_command(cmd_args);
        defer result.deinit();

        try result.expect_failure();
        try testing.expect(result.stderr.len > 0);
        try testing.expect(result.contains_error("Error:") or
            result.contains_error("Missing") or
            result.contains_error("required"));
    }
}

test "query error handling: invalid entity types" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "invalid_types");
    defer test_harness.deinit();

    // Test invalid entity type for find
    var result = try test_harness.execute_command(&[_][]const u8{ "find", "invalid_type", "something" });
    defer result.deinit();

    // Should handle gracefully
    if (result.exit_code != 0) {
        try testing.expect(result.stderr.len > 0);
    }
}

test "query error handling: invalid trace directions" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "invalid_directions");
    defer test_harness.deinit();

    const project_path = try test_harness.create_test_project("direction_test");
    var link_result = try test_harness.execute_workspace_command("link {s}", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    // Test invalid direction
    var result = try test_harness.execute_command(&[_][]const u8{ "trace", "invalid_direction", "main" });
    defer result.deinit();

    try result.expect_success(); // Command parses but execution should handle gracefully
    try testing.expect(result.contains_output("direction") or result.contains_error("Unknown"));
}

test "query commands handle unlinked workspace gracefully" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "no_workspace");
    defer test_harness.deinit();

    // Try to query without any linked codebases
    var result = try test_harness.execute_command(&[_][]const u8{ "find", "function", "main" });
    defer result.deinit();

    try result.expect_success();
    // Should provide helpful message about linking codebases first
    try testing.expect(result.contains_output("link") or
        result.contains_output("No") or
        result.contains_output("workspace"));
}

test "query performance is reasonable" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "query_perf");
    defer test_harness.deinit();

    const project_path = try test_harness.create_test_project("perf_test");
    var link_result = try test_harness.execute_workspace_command("link {s}", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    const start_time = std.time.nanoTimestamp();

    var result = try test_harness.execute_command(&[_][]const u8{ "find", "function", "main" });
    defer result.deinit();

    const elapsed_ns = std.time.nanoTimestamp() - start_time;
    const elapsed_ms = @divFloor(elapsed_ns, std.time.ns_per_ms);

    try result.expect_success();
    // Query should complete within reasonable time (5 seconds is generous)
    try testing.expect(elapsed_ms < 5000);
}

test "cross-workspace query functionality" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "cross_workspace");
    defer test_harness.deinit();

    // Create two different projects
    const proj1_path = try test_harness.create_test_project("backend");
    const proj2_path = try test_harness.create_test_project("frontend");

    var link1 = try test_harness.execute_workspace_command("link {s} as backend", .{proj1_path});
    defer link1.deinit();
    try link1.expect_success();

    var link2 = try test_harness.execute_workspace_command("link {s} as frontend", .{proj2_path});
    defer link2.deinit();
    try link2.expect_success();

    // Query specific to backend workspace
    var backend_result = try test_harness.execute_command(&[_][]const u8{ "find", "function", "main", "in", "backend" });
    defer backend_result.deinit();
    try backend_result.expect_success();

    // Query specific to frontend workspace
    var frontend_result = try test_harness.execute_command(&[_][]const u8{ "find", "function", "main", "in", "frontend" });
    defer frontend_result.deinit();
    try frontend_result.expect_success();

    // TODO: When implemented, results should be workspace-specific
    try testing.expect(backend_result.stdout.len > 0);
    try testing.expect(frontend_result.stdout.len > 0);
}

test "complex query scenarios end-to-end" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "complex_queries");
    defer test_harness.deinit();

    const project_path = try test_harness.create_test_project("complex_test");
    var link_result = try test_harness.execute_workspace_command("link {s} as complex", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    var sync_result = try test_harness.execute_workspace_command("sync complex", .{});
    defer sync_result.deinit();
    try sync_result.expect_success();

    // Chain of queries that would be typical in real usage
    var find_result = try test_harness.execute_command(&[_][]const u8{ "find", "function", "main", "in", "complex" });
    defer find_result.deinit();
    try find_result.expect_success();

    var callers_result = try test_harness.execute_command(&[_][]const u8{ "show", "callers", "helper_function", "in", "complex" });
    defer callers_result.deinit();
    try callers_result.expect_success();

    var trace_result = try test_harness.execute_command(&[_][]const u8{ "trace", "callees", "main", "--depth", "5", "in", "complex" });
    defer trace_result.deinit();
    try trace_result.expect_success();

    // All commands should complete successfully even if returning placeholder data
    try testing.expect(find_result.stdout.len > 0);
    try testing.expect(callers_result.stdout.len > 0);
    try testing.expect(trace_result.stdout.len > 0);
}
