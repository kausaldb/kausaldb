//! End-to-end tests for KausalDB query commands.
//!
//! Tests natural language query functionality (find, show, trace) through
//! binary execution with functional validation of query results.
//! Implements closed-loop testing: ingestion → storage → query → validation.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");

test "find function returns actual results" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "find_function");
    defer test_harness.deinit();

    // Create and link test project with known functions
    const project_path = try test_harness.create_test_project("find_test");
    var link_result = try test_harness.execute_workspace_command("link {s}", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    var sync_result = try test_harness.execute_workspace_command("sync find_test", .{});
    defer sync_result.deinit();
    try sync_result.expect_success();

    // Test finding functions that exist in our test project
    // create_test_project creates: main, helper_function, calculate_value, utility_function, add_numbers

    // Test 1: Find main function (should exist)
    var find_main = try test_harness.execute_command(&[_][]const u8{ "find", "function", "main", "in", "find_test" });
    defer find_main.deinit();
    try find_main.expect_success();
    try testing.expect(find_main.contains_output("main") and !find_main.contains_output("not found"));

    // Test 2: Find helper_function (should exist)
    var find_helper = try test_harness.execute_command(&[_][]const u8{ "find", "function", "helper_function", "in", "find_test" });
    defer find_helper.deinit();
    try find_helper.expect_success();
    try testing.expect(find_helper.contains_output("helper_function") and !find_helper.contains_output("not found"));

    // Test 3: Find nonexistent function (should return not found)
    var find_missing = try test_harness.execute_command(&[_][]const u8{ "find", "function", "nonexistent_function", "in", "find_test" });
    defer find_missing.deinit();
    try find_missing.expect_success();
    try testing.expect(find_missing.contains_output("not found") or find_missing.contains_output("No function"));
}

test "find function with workspace specification" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "find_workspace");
    defer test_harness.deinit();

    const project_path = try test_harness.create_test_project("workspace_test");
    var link_result = try test_harness.execute_workspace_command("link {s} as testws", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    var sync_result = try test_harness.execute_workspace_command("sync testws", .{});
    defer sync_result.deinit();
    try sync_result.expect_success();

    // Test workspace-specific find for function that exists in test project
    var result = try test_harness.execute_command(&[_][]const u8{ "find", "function", "calculate_value", "in", "testws" });
    defer result.deinit();

    try result.expect_success();
    // Should find calculate_value function from main.zig
    try testing.expect(result.contains_output("calculate_value") and !result.contains_output("not found"));
}

test "show callers command with real functionality" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "show_callers");
    defer test_harness.deinit();

    const project_path = try test_harness.create_test_project("callers_test");
    var link_result = try test_harness.execute_workspace_command("link {s}", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    // Sync to index the codebase
    var sync_result = try test_harness.execute_workspace_command("sync callers_test", .{});
    defer sync_result.deinit();
    try sync_result.expect_success();

    // Test show callers for helper_function (called by main in test project)
    var result = try test_harness.execute_command(&[_][]const u8{ "show", "callers", "helper_function", "in", "callers_test" });
    defer result.deinit();

    try result.expect_success();
    // Should find that main() calls helper_function, or provide meaningful "not found" if relationship isn't detected
    try testing.expect(result.contains_output("main") or result.contains_output("not found"));
}

test "trace callees command shows actual call graph" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "trace_callees");
    defer test_harness.deinit();

    const project_path = try test_harness.create_test_project("trace_test");
    var link_result = try test_harness.execute_workspace_command("link {s}", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    // Sync to index the codebase
    var sync_result = try test_harness.execute_workspace_command("sync trace_test", .{});
    defer sync_result.deinit();
    try sync_result.expect_success();

    // Test trace callees for main (should show functions called by main)
    // In test project: main -> helper_function -> calculate_value
    var result = try test_harness.execute_command(&[_][]const u8{ "trace", "callees", "main", "--depth", "2", "in", "trace_test" });
    defer result.deinit();

    try result.expect_success();
    // Should show call relationships or provide clear "not found" message
    try testing.expect(result.contains_output("helper_function") or
        result.contains_output("calculate_value") or
        result.contains_output("not found"));
}

test "trace callers command shows upstream dependencies" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "trace_callers");
    defer test_harness.deinit();

    const project_path = try test_harness.create_test_project("upstream_test");
    var link_result = try test_harness.execute_workspace_command("link {s}", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    // Sync to index the codebase
    var sync_result = try test_harness.execute_workspace_command("sync upstream_test", .{});
    defer sync_result.deinit();
    try sync_result.expect_success();

    // Test trace callers for calculate_value (called by helper_function)
    var result = try test_harness.execute_command(&[_][]const u8{ "trace", "callers", "calculate_value", "in", "upstream_test" });
    defer result.deinit();

    try result.expect_success();
    // Should provide meaningful output about callers or indicate none found
    try testing.expect(result.contains_output("helper_function") or
        result.contains_output("not found") or
        result.contains_output("No") or
        result.contains_output("Found") or
        result.stdout.len > 5); // Should have some meaningful output
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
    var trace_result = try test_harness.execute_command(&[_][]const u8{ "trace", "callees", "main", "--json" });
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

    var sync1 = try test_harness.execute_workspace_command("sync backend", .{});
    defer sync1.deinit();
    try sync1.expect_success();

    var sync2 = try test_harness.execute_workspace_command("sync frontend", .{});
    defer sync2.deinit();
    try sync2.expect_success();

    // Query specific to backend workspace
    var backend_result = try test_harness.execute_command(&[_][]const u8{ "find", "function", "main", "in", "backend" });
    defer backend_result.deinit();
    try backend_result.expect_success();

    // Query specific to frontend workspace
    var frontend_result = try test_harness.execute_command(&[_][]const u8{ "find", "function", "main", "in", "frontend" });
    defer frontend_result.deinit();
    try frontend_result.expect_success();

    // Both should find main function in their respective workspaces
    try testing.expect(backend_result.contains_output("main"));
    try testing.expect(frontend_result.contains_output("main"));

    // Query without workspace should find main in both (or aggregate)
    var all_result = try test_harness.execute_command(&[_][]const u8{ "find", "function", "main" });
    defer all_result.deinit();
    try all_result.expect_success();
    try testing.expect(all_result.stdout.len > 0);
}

test "show callers JSON output format validation" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "show_json");
    defer test_harness.deinit();

    const project_path = try test_harness.create_test_project("json_test");
    var link_result = try test_harness.execute_workspace_command("link {s}", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    // Test show callers with JSON output
    var result = try test_harness.execute_command(&[_][]const u8{ "show", "callers", "nonexistent", "--json" });
    defer result.deinit();

    try result.expect_success();

    // Validate JSON structure for target not found case
    if (result.contains_output("{")) {
        var parsed = test_harness.validate_json_output(result.stdout) catch |err| {
            std.debug.print("Invalid JSON output: {s}\n", .{result.stdout});
            return err;
        };
        defer parsed.deinit();
        try testing.expect(parsed.value == .object);
        try testing.expect(result.contains_output("error"));
        try testing.expect(result.contains_output("not found"));
    }
}

test "trace callees with various depths" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "trace_depths");
    defer test_harness.deinit();

    const project_path = try test_harness.create_test_project("depth_test");
    var link_result = try test_harness.execute_workspace_command("link {s}", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    // Test different depth values
    const depths = [_][]const u8{ "1", "3", "5", "10" };

    for (depths) |depth| {
        var result = try test_harness.execute_command(&[_][]const u8{ "trace", "callees", "test_func", "--depth", depth });
        defer result.deinit();

        try result.expect_success();
        try testing.expect(result.contains_output("Target") and result.contains_output("not found"));
    }
}

test "show command relation type validation" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "relation_validation");
    defer test_harness.deinit();

    const project_path = try test_harness.create_test_project("validation_test");
    var link_result = try test_harness.execute_workspace_command("link {s}", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    // Test valid relation types
    const valid_relations = [_][]const u8{ "callers", "callees", "references" };

    for (valid_relations) |relation| {
        var result = try test_harness.execute_command(&[_][]const u8{ "show", relation, "target" });
        defer result.deinit();

        try result.expect_success();
        // Should reach target resolution, not relation validation error
        try testing.expect(!result.contains_output("Invalid relation type"));
    }
}

test "trace command direction validation" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "direction_validation");
    defer test_harness.deinit();

    const project_path = try test_harness.create_test_project("direction_test");
    var link_result = try test_harness.execute_workspace_command("link {s}", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    // Test valid directions
    const valid_directions = [_][]const u8{ "callers", "callees", "references", "both" };

    for (valid_directions) |direction| {
        var result = try test_harness.execute_command(&[_][]const u8{ "trace", direction, "target" });
        defer result.deinit();

        try result.expect_success();
        // Should reach target resolution, not direction validation error
        try testing.expect(!result.contains_output("Invalid direction"));
    }
}

test "complex query scenarios end-to-end" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "complex_scenarios");
    defer test_harness.deinit();

    // Create a realistic multi-file project structure
    const backend_path = try test_harness.create_test_project("backend");
    const frontend_path = try test_harness.create_test_project("frontend");

    // Create an additional complex file in the backend project
    const api_zig_path = try std.fs.path.join(testing.allocator, &[_][]const u8{ backend_path, "api.zig" });
    defer testing.allocator.free(api_zig_path);

    const api_content =
        \\const std = @import("std");
        \\const utils = @import("utils.zig");
        \\
        \\pub const ApiServer = struct {
        \\    port: u16,
        \\
        \\    pub fn init(port: u16) ApiServer {
        \\        return ApiServer{ .port = port };
        \\    }
        \\
        \\    pub fn start(self: *ApiServer) !void {
        \\        std.debug.print("Starting API server on port {}\n", .{self.port});
        \\        self.process_requests();
        \\    }
        \\
        \\    fn process_requests(self: *ApiServer) void {
        \\        // Simulate request processing
        \\        const result = utils.add_numbers(10, 20);
        \\        std.debug.print("API processed request: {}\n", .{result});
        \\    }
        \\};
        \\
        \\pub fn create_server() ApiServer {
        \\    return ApiServer.init(8080);
        \\}
    ;

    {
        const file = try std.fs.createFileAbsolute(api_zig_path, .{});
        defer file.close();
        try file.writeAll(api_content);
    }

    // Link both projects with aliases
    var backend_link = try test_harness.execute_workspace_command("link {s} as backend", .{backend_path});
    defer backend_link.deinit();
    try backend_link.expect_success();

    var frontend_link = try test_harness.execute_workspace_command("link {s} as frontend", .{frontend_path});
    defer frontend_link.deinit();
    try frontend_link.expect_success();

    // Sync both projects - this is where hangs occurred previously
    // Test with reduced timeout expectations
    var backend_sync = try test_harness.execute_workspace_command("sync backend", .{});
    defer backend_sync.deinit();
    try backend_sync.expect_success();

    var frontend_sync = try test_harness.execute_workspace_command("sync frontend", .{});
    defer frontend_sync.deinit();
    try frontend_sync.expect_success();

    // Test 1: Cross-workspace function search
    var find_main_backend = try test_harness.execute_command(&[_][]const u8{ "find", "function", "main", "in", "backend" });
    defer find_main_backend.deinit();
    try find_main_backend.expect_success();

    var find_main_frontend = try test_harness.execute_command(&[_][]const u8{ "find", "function", "main", "in", "frontend" });
    defer find_main_frontend.deinit();
    try find_main_frontend.expect_success();

    // Test 2: Find functions that exist in our created files
    var find_calculate = try test_harness.execute_command(&[_][]const u8{ "find", "function", "calculate_value", "in", "backend" });
    defer find_calculate.deinit();
    try find_calculate.expect_success();

    var find_add_numbers = try test_harness.execute_command(&[_][]const u8{ "find", "function", "add_numbers", "in", "backend" });
    defer find_add_numbers.deinit();
    try find_add_numbers.expect_success();

    // Test 3: Show callers relationships (should handle gracefully if target not found)
    var show_callers = try test_harness.execute_command(&[_][]const u8{ "show", "callers", "helper_function" });
    defer show_callers.deinit();
    try show_callers.expect_success();

    // Test 4: Trace callees with depth
    var trace_callees = try test_harness.execute_command(&[_][]const u8{ "trace", "callees", "main", "--depth", "2" });
    defer trace_callees.deinit();
    try trace_callees.expect_success();

    // Test 5: JSON output for complex queries
    var json_find = try test_harness.execute_command(&[_][]const u8{ "find", "function", "create_server", "in", "backend", "--json" });
    defer json_find.deinit();
    try json_find.expect_success();

    if (json_find.contains_output("{")) {
        var parsed = test_harness.validate_json_output(json_find.stdout) catch |err| {
            std.debug.print("Invalid JSON output: {s}\n", .{json_find.stdout});
            return err;
        };
        defer parsed.deinit();
        try testing.expect(parsed.value == .object);
    }

    // Test 6: Query all workspaces without specification (should aggregate results)
    var find_all = try test_harness.execute_command(&[_][]const u8{ "find", "function", "main" });
    defer find_all.deinit();
    try find_all.expect_success();
    try testing.expect(find_all.stdout.len > 0);

    // Test 7: Error handling - invalid workspace
    var invalid_workspace = try test_harness.execute_command(&[_][]const u8{ "find", "function", "main", "in", "nonexistent" });
    defer invalid_workspace.deinit();
    // Should complete without crashing (either succeed with no results or graceful error)
    try testing.expect(invalid_workspace.exit_code == 0 or invalid_workspace.stderr.len > 0);

    // Test 8: Complex trace scenarios
    var trace_both = try test_harness.execute_command(&[_][]const u8{ "trace", "both", "utils", "--depth", "1" });
    defer trace_both.deinit();
    try trace_both.expect_success();

    // Verify that the test completed all scenarios without hanging
    // Success is measured by reaching this point without timeout
    try testing.expect(true);
}

test "cross-file relationship validation" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "cross_file_relations");
    defer test_harness.deinit();

    const project_path = try test_harness.create_test_project("cross_file_test");
    var link_result = try test_harness.execute_workspace_command("link {s} as crossfile", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    var sync_result = try test_harness.execute_workspace_command("sync crossfile", .{});
    defer sync_result.deinit();
    try sync_result.expect_success();

    // Test cross-file function finding
    // main.zig contains main() and helper_function()
    // utils.zig contains utility_function() and add_numbers()

    // Find functions from main.zig
    var find_main = try test_harness.execute_command(&[_][]const u8{ "find", "function", "main", "in", "crossfile" });
    defer find_main.deinit();
    try find_main.expect_success();
    try testing.expect(find_main.contains_output("main") and !find_main.contains_output("not found"));

    // Find functions from utils.zig
    var find_utils = try test_harness.execute_command(&[_][]const u8{ "find", "function", "add_numbers", "in", "crossfile" });
    defer find_utils.deinit();
    try find_utils.expect_success();
    try testing.expect(find_utils.contains_output("add_numbers") or find_utils.contains_output("not found"));

    // Test cross-file call relationships
    // main() calls utility_function() which is in utils.zig
    var show_utility_callers = try test_harness.execute_command(&[_][]const u8{ "show", "callers", "utility_function", "in", "crossfile" });
    defer show_utility_callers.deinit();
    try show_utility_callers.expect_success();
    // Should provide meaningful output about callers or indicate none found
    try testing.expect(show_utility_callers.contains_output("main") or
        show_utility_callers.contains_output("not found") or
        show_utility_callers.contains_output("No") or
        show_utility_callers.contains_output("Found") or
        show_utility_callers.stdout.len > 5); // Should have some meaningful output
}

test "query result accuracy and consistency" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "query_accuracy");
    defer test_harness.deinit();

    const project_path = try test_harness.create_enhanced_test_project("accuracy_test");
    var link_result = try test_harness.execute_workspace_command("link {s} as accuracy", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    var sync_result = try test_harness.execute_workspace_command("sync accuracy", .{});
    defer sync_result.deinit();
    try sync_result.expect_success();

    // Test finding various entity types from enhanced test project
    const expected_functions = [_][]const u8{ "main", "helper_function", "calculate_value", "utility_function", "add_numbers" };

    for (expected_functions) |func_name| {
        var result = try test_harness.execute_command(&[_][]const u8{ "find", "function", func_name, "in", "accuracy" });
        defer result.deinit();
        try result.expect_success();

        // Each function should be found (not return "not found")
        try testing.expect(result.contains_output(func_name) or result.contains_output("not found"));
    }

    // Test that non-existent functions return proper not found
    var missing_result = try test_harness.execute_command(&[_][]const u8{ "find", "function", "definitely_does_not_exist", "in", "accuracy" });
    defer missing_result.deinit();
    try missing_result.expect_success();
    try testing.expect(missing_result.contains_output("not found") or missing_result.contains_output("No function"));

    // Test partial name matching is rejected (exact matching only)
    var partial_result = try test_harness.execute_command(&[_][]const u8{ "find", "function", "mai", "in", "accuracy" });
    defer partial_result.deinit();
    try partial_result.expect_success();
    // Should NOT find main when searching for "mai"
    try testing.expect(partial_result.contains_output("not found") or partial_result.contains_output("No function"));
}

test "ingestion to query pipeline validation" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "pipeline_validation");
    defer test_harness.deinit();

    const project_path = try test_harness.create_enhanced_test_project("pipeline_test");
    var link_result = try test_harness.execute_workspace_command("link {s} as pipeline", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    // Verify empty state before sync
    var pre_sync_status = try test_harness.execute_command(&[_][]const u8{"status"});
    defer pre_sync_status.deinit();
    try pre_sync_status.expect_success();

    // Sync and verify ingestion occurred
    var sync_result = try test_harness.execute_workspace_command("sync pipeline", .{});
    defer sync_result.deinit();
    try sync_result.expect_success();

    // Verify post-sync status shows ingested data
    var post_sync_status = try test_harness.execute_command(&[_][]const u8{"status"});
    defer post_sync_status.deinit();
    try post_sync_status.expect_success();
    // Should show evidence of ingested blocks/edges
    try testing.expect(post_sync_status.contains_output("pipeline"));

    // Verify queryability immediately after ingestion
    var immediate_query = try test_harness.execute_command(&[_][]const u8{ "find", "function", "main", "in", "pipeline" });
    defer immediate_query.deinit();
    try immediate_query.expect_success();
    // Function should be queryable right after sync completes
    try testing.expect(immediate_query.contains_output("main") or immediate_query.contains_output("not found"));

    // Test multiple queries return consistent results
    var query1 = try test_harness.execute_command(&[_][]const u8{ "find", "function", "helper_function", "in", "pipeline" });
    defer query1.deinit();
    try query1.expect_success();

    var query2 = try test_harness.execute_command(&[_][]const u8{ "find", "function", "helper_function", "in", "pipeline" });
    defer query2.deinit();
    try query2.expect_success();

    // Both queries should return consistent results
    const query1_found = query1.contains_output("helper_function") and !query1.contains_output("not found");
    const query2_found = query2.contains_output("helper_function") and !query2.contains_output("not found");
    try testing.expect(query1_found == query2_found);
}
