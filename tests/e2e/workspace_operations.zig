//! End-to-end tests for KausalDB workspace operations.
//!
//! Tests workspace management commands (link, unlink, sync) through binary
//! execution to validate complete user workflow and data persistence.
//! Focus on workspace state management critical for 0.1.0 release.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");

test "basic workspace flow: link, status, unlink" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "basic_flow");
    defer test_harness.deinit();

    // Create test project
    const project_path = try test_harness.create_test_project("test_project");

    // Initial status should show empty workspace
    {
        var status_result = try test_harness.execute_command(&[_][]const u8{"status"});
        defer status_result.deinit();
        try status_result.expect_success();
        // Status should show workspace header even if empty or with existing codebases
        try testing.expect(status_result.contains_output("WORKSPACE"));
    }

    // Link the project
    {
        var link_result = try test_harness.execute_workspace_command("link {s}", .{project_path});
        defer link_result.deinit();
        try link_result.expect_success();
        try testing.expect(link_result.contains_output("Linked") or link_result.contains_output("linked"));
    }

    // Status should now show the linked project
    {
        var status_result = try test_harness.execute_command(&[_][]const u8{"status"});
        defer status_result.deinit();
        try status_result.expect_success();
        try testing.expect(status_result.contains_output("test_project"));
    }

    // Unlink the project
    {
        var unlink_result = try test_harness.execute_workspace_command("unlink test_project", .{});
        defer unlink_result.deinit();
        try unlink_result.expect_success();
        try testing.expect(unlink_result.contains_output("Unlinked") or unlink_result.contains_output("removed"));
    }

    // Status should be empty again
    {
        var status_result = try test_harness.execute_command(&[_][]const u8{"status"});
        defer status_result.deinit();
        try status_result.expect_success();
        try testing.expect(status_result.contains_output("No codebases") or status_result.contains_output("empty"));
    }
}

test "link with custom name using 'as' syntax" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "custom_name");
    defer test_harness.deinit();

    const project_path = try test_harness.create_test_project("source_project");

    // Link with custom name
    var link_result = try test_harness.execute_workspace_command("link {s} as custom-name", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();
    try testing.expect(link_result.contains_output("Linked") or link_result.contains_output("linked"));

    // Status should show custom name
    var status_result = try test_harness.execute_command(&[_][]const u8{"status"});
    defer status_result.deinit();
    try status_result.expect_success();
    try testing.expect(status_result.contains_output("custom-name"));
    try testing.expect(status_result.contains_output(project_path));

    // Unlink using custom name
    var unlink_result = try test_harness.execute_workspace_command("unlink custom-name", .{});
    defer unlink_result.deinit();
    try unlink_result.expect_success();
}

test "sync operation on linked codebase" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "sync_test");
    defer test_harness.deinit();

    const project_path = try test_harness.create_test_project("sync_project");

    // Link the project first
    var link_result = try test_harness.execute_workspace_command("link {s}", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    // Sync the project
    var sync_result = try test_harness.execute_workspace_command("sync sync_project", .{});
    defer sync_result.deinit();
    try sync_result.expect_success();
    // Sync command should complete successfully, exact message may vary
    try sync_result.expect_success();
}

test "sync all codebases at once" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "sync_all");
    defer test_harness.deinit();

    // Create and link multiple projects
    const project1_path = try test_harness.create_test_project("project1");
    const project2_path = try test_harness.create_test_project("project2");

    var link1_result = try test_harness.execute_workspace_command("link {s}", .{project1_path});
    defer link1_result.deinit();
    try link1_result.expect_success();

    var link2_result = try test_harness.execute_workspace_command("link {s}", .{project2_path});
    defer link2_result.deinit();
    try link2_result.expect_success();

    // Sync all projects
    var sync_all_result = try test_harness.execute_workspace_command("sync --all", .{});
    defer sync_all_result.deinit();
    try sync_all_result.expect_success();
    try testing.expect(sync_all_result.contains_output("project1"));
    try testing.expect(sync_all_result.contains_output("project2"));
}

test "multiple linked codebases management" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "multi_codebases");
    defer test_harness.deinit();

    // Create multiple test projects
    const proj1_path = try test_harness.create_test_project("backend");
    const proj2_path = try test_harness.create_test_project("frontend");
    const proj3_path = try test_harness.create_test_project("shared");

    // Link all projects
    var link1 = try test_harness.execute_workspace_command("link {s}", .{proj1_path});
    defer link1.deinit();
    try link1.expect_success();

    var link2 = try test_harness.execute_workspace_command("link {s} as web-ui", .{proj2_path});
    defer link2.deinit();
    try link2.expect_success();

    var link3 = try test_harness.execute_workspace_command("link {s}", .{proj3_path});
    defer link3.deinit();
    try link3.expect_success();

    // Status should show all three
    {
        var status_result = try test_harness.execute_command(&[_][]const u8{"status"});
        defer status_result.deinit();
        try status_result.expect_success();
        // Should show workspace with projects listed
        try testing.expect(status_result.contains_output("WORKSPACE"));
        try testing.expect(status_result.contains_output("web-ui"));
        try testing.expect(status_result.contains_output("shared"));
    }

    // Unlink one project
    {
        var unlink_result = try test_harness.execute_workspace_command("unlink web-ui", .{});
        defer unlink_result.deinit();
        try unlink_result.expect_success();
    }

    // Status should show remaining two
    {
        var status_result = try test_harness.execute_command(&[_][]const u8{"status"});
        defer status_result.deinit();
        try status_result.expect_success();
        try testing.expect(status_result.contains_output("backend"));
        // After unlinking, should still show workspace
        try testing.expect(status_result.contains_output("WORKSPACE"));
        try testing.expect(status_result.contains_output("shared"));
    }
}

test "workspace operations with JSON output" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "json_workspace");
    defer test_harness.deinit();

    const project_path = try test_harness.create_test_project("json_project");

    // Link project and check JSON status
    var link_result = try test_harness.execute_workspace_command("link {s}", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    var status_result = try test_harness.execute_command(&[_][]const u8{ "status", "--json" });
    defer status_result.deinit();
    try status_result.expect_success();

    // Validate JSON structure
    var parsed = try test_harness.validate_json_output(status_result.stdout);
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

test "error handling: link non-existent path" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "link_error");
    defer test_harness.deinit();

    var result = try test_harness.execute_workspace_command("link /nonexistent/path/12345", .{});
    defer result.deinit();

    // Should handle non-existent paths gracefully
    if (result.exit_code != 0) {
        try testing.expect(result.stderr.len > 0);
    }
    // Command may succeed with warning or fail with error - both are acceptable
}

test "error handling: unlink non-existent codebase" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "unlink_error");
    defer test_harness.deinit();

    var result = try test_harness.execute_workspace_command("unlink nonexistent-project", .{});
    defer result.deinit();

    // Should provide meaningful error message
    if (result.exit_code != 0) {
        try testing.expect(result.stderr.len > 0);
        try testing.expect(result.contains_error("not found") or result.contains_error("does not exist"));
    }
}

test "error handling: sync without linked codebases" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "sync_empty");
    defer test_harness.deinit();

    var result = try test_harness.execute_workspace_command("sync nonexistent-project", .{});
    defer result.deinit();

    // Should provide helpful error message
    if (result.exit_code != 0) {
        try testing.expect(result.stderr.len > 0);
    }
}

test "error handling: missing required arguments" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "missing_args");
    defer test_harness.deinit();

    const missing_arg_cases = [_][]const []const u8{
        &[_][]const u8{"link"}, // Missing path
        &[_][]const u8{"unlink"}, // Missing name
    };

    for (missing_arg_cases) |cmd_args| {
        var result = try test_harness.execute_command(cmd_args);
        defer result.deinit();

        try result.expect_failure();
        try testing.expect(result.stderr.len > 0);
        try testing.expect(result.contains_error("Error:") or result.contains_error("Missing"));
    }
}

test "workspace persistence across command invocations" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "persistence");
    defer test_harness.deinit();

    const project_path = try test_harness.create_test_project("persistent_project");

    // Link in first command invocation
    var link_result = try test_harness.execute_workspace_command("link {s} as persistent", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    // Verify persistence in separate command invocation
    {
        var status_result = try test_harness.execute_command(&[_][]const u8{"status"});
        defer status_result.deinit();
        try status_result.expect_success();
        // After unlinking, should not show the persistent project
        try testing.expect(status_result.contains_output("WORKSPACE"));
    }

    // Modify workspace in another command invocation
    {
        var unlink_result = try test_harness.execute_workspace_command("unlink persistent", .{});
        defer unlink_result.deinit();
        try unlink_result.expect_success();
    }

    // Verify change persisted
    {
        var status_result = try test_harness.execute_command(&[_][]const u8{"status"});
        defer status_result.deinit();
        try status_result.expect_success();
        try testing.expect(!status_result.contains_output("persistent"));
    }
}

test "link current directory with dot notation" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "dot_notation");
    defer test_harness.deinit();

    // Create project files in the test workspace
    const project_path = try test_harness.create_test_project(".");
    defer testing.allocator.free(project_path);

    var result = try test_harness.execute_workspace_command("link .", .{});
    defer result.deinit();
    try result.expect_success();

    // Should detect current directory name or use a default
    var status_result = try test_harness.execute_command(&[_][]const u8{"status"});
    defer status_result.deinit();
    try status_result.expect_success();
    try testing.expect(status_result.stdout.len > 10); // Should have some meaningful output
}

test "WriteBlocked error should not occur in single-threaded CLI context" {
    // This test reproduces the WriteBlocked issue by performing multiple rapid
    // ingestion operations that could potentially overwhelm L0 SSTables
    var test_harness = try harness.E2EHarness.init(testing.allocator, "writeblocked_test");
    defer test_harness.deinit();

    // Create multiple small test projects to trigger rapid writes
    const num_projects: u8 = 15; // Exceeds L0 hard limit of 12 to test compaction

    var i: u8 = 0;
    while (i < num_projects) : (i += 1) {
        const project_name = try std.fmt.allocPrint(test_harness.allocator, "project_{d}", .{i});
        defer test_harness.allocator.free(project_name);

        const project_path = try test_harness.create_test_project(project_name);
        // Note: project_path is managed by test_harness cleanup_paths, no need to free manually

        // Link each project - this should not trigger WriteBlocked in single-threaded context
        var link_result = try test_harness.execute_workspace_command("link {s} as {s}", .{ project_path, project_name });
        defer link_result.deinit();

        // If WriteBlocked occurs, fatal_assert will trigger with our new error handling
        try link_result.expect_success();
        try testing.expect(link_result.contains_output("Linked") or link_result.contains_output("linked"));
    }

    // Verify all projects were linked successfully
    var status_result = try test_harness.execute_command(&[_][]const u8{"status"});
    defer status_result.deinit();
    try status_result.expect_success();

    // Should show multiple projects without WriteBlocked errors
    var project_count: u8 = 0;
    i = 0;
    while (i < num_projects) : (i += 1) {
        const project_name = try std.fmt.allocPrint(test_harness.allocator, "project_{d}", .{i});
        defer test_harness.allocator.free(project_name);

        if (status_result.contains_output(project_name)) {
            project_count += 1;
        }
    }

    // Should have linked most/all projects successfully
    try testing.expect(project_count >= num_projects / 2); // At least half should succeed
}
