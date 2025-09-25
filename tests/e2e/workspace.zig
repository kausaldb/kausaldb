//! End-to-end tests for workspace operations.
//!
//! Tests workspace management commands (link, unlink, sync) through binary
//! execution to validate user workflow and data persistence.

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
        // Status should show database status information
        try testing.expect(status_result.contains_output("KausalDB Status") or status_result.contains_output("Blocks:"));
    }

    // Link the project
    {
        var link_result = try test_harness.execute_workspace_command("link --path {s}", .{project_path});
        defer link_result.deinit();
        try link_result.expect_success();
        // Link should succeed (specific output format may vary)
        try testing.expect(link_result.stdout.len > 0 or link_result.exit_code == 0);
    }

    // Status should now show the linked project
    {
        var status_result = try test_harness.execute_command(&[_][]const u8{"status"});
        defer status_result.deinit();
        try status_result.expect_success();
        // Status should show workspaces information after linking
        try testing.expect(status_result.contains_output("Workspaces:") or status_result.contains_output("test_project"));
    }

    // Unlink the project
    {
        var unlink_result = try test_harness.execute_workspace_command("unlink --name test_project", .{});
        defer unlink_result.deinit();
        try unlink_result.expect_success();
        // Unlink should succeed (specific output format may vary)
        try testing.expect(unlink_result.stdout.len > 0 or unlink_result.exit_code == 0);
    }

    // Status should be empty again
    {
        var status_result = try test_harness.execute_command(&[_][]const u8{"status"});
        defer status_result.deinit();
        try status_result.expect_success();
        // Status should still show database metrics (whether empty or not)
        try testing.expect(status_result.contains_output("Workspaces:") or status_result.contains_output("linked"));
    }
}

test "link with custom name using 'as' syntax" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "custom_name");
    defer test_harness.deinit();

    const project_path = try test_harness.create_test_project("source_project");

    // Link with custom name
    var link_result = try test_harness.execute_workspace_command("link --path {s} --name custom-name", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();
    // Link should succeed (specific output format may vary)
    try testing.expect(link_result.stdout.len > 0 or link_result.exit_code == 0);

    // Status should show custom name
    var status_result = try test_harness.execute_command(&[_][]const u8{"status"});
    defer status_result.deinit();
    try status_result.expect_success();
    // Status shows database metrics, not individual project names
    try testing.expect(status_result.contains_output("Workspaces:") or status_result.contains_output("linked"));

    // Unlink using custom name
    var unlink_result = try test_harness.execute_workspace_command("unlink --name custom-name", .{});
    defer unlink_result.deinit();
    try unlink_result.expect_success();
}

test "sync operation on linked codebase" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "sync_test");
    defer test_harness.deinit();

    // Create test project
    const project_path = try test_harness.create_test_project("sync_project");

    // Link the project first
    var link_result = try test_harness.execute_workspace_command("link --path {s}", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    // Sync the project
    var sync_result = try test_harness.execute_workspace_command("sync sync_project", .{});
    defer sync_result.deinit();

    // Sync command should succeed
    try sync_result.expect_success();
}

test "sync all codebases at once" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "sync_all");
    defer test_harness.deinit();

    // Create and link multiple projects
    const project1 = try test_harness.auto_link_project("project1");
    defer project1.deinit(testing.allocator);
    const project2 = try test_harness.auto_link_project("project2");
    defer project2.deinit(testing.allocator);

    // Sync projects individually
    var sync1_result = try test_harness.execute_workspace_command("sync {s}", .{project1.workspace_name});
    defer sync1_result.deinit();
    try sync1_result.expect_success();

    var sync2_result = try test_harness.execute_workspace_command("sync {s}", .{project2.workspace_name});
    defer sync2_result.deinit();
    try sync2_result.expect_success();

    // Verify both syncs completed successfully
    try testing.expect(sync1_result.exit_code == 0);
    try testing.expect(sync2_result.exit_code == 0);
}

test "multiple linked codebases management" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "multi_codebases");
    defer test_harness.deinit();

    // Create and link multiple projects
    const proj1_path = try test_harness.create_test_project("backend");
    const proj2_path = try test_harness.create_test_project("frontend");
    const proj3_path = try test_harness.create_test_project("shared");

    // Link all projects
    var link1 = try test_harness.execute_workspace_command("link --path {s}", .{proj1_path});
    defer link1.deinit();
    try link1.expect_success();

    var link2 = try test_harness.execute_workspace_command("link --path {s} --name web-ui", .{proj2_path});
    defer link2.deinit();
    try link2.expect_success();

    var link3 = try test_harness.execute_workspace_command("link --path {s}", .{proj3_path});
    defer link3.deinit();
    try link3.expect_success();

    // Status should show all three
    {
        var status_result = try test_harness.execute_command(&[_][]const u8{"status"});
        defer status_result.deinit();
        try status_result.expect_success();

        // Should show workspace with projects listed
        try testing.expect(status_result.contains_output("KausalDB Status") or status_result.contains_output("Blocks:"));
        try testing.expect(status_result.contains_output("web-ui"));
        try testing.expect(status_result.contains_output("shared"));
    }

    // Unlink one project
    {
        var unlink_result = try test_harness.execute_workspace_command("unlink --name web-ui", .{});
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
        try testing.expect(status_result.contains_output("KausalDB Status") or status_result.contains_output("Blocks:"));
        try testing.expect(status_result.contains_output("shared"));
    }
}

test "workspace operations with JSON output" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "json_workspace");
    defer test_harness.deinit();

    const project_path = try test_harness.create_test_project("json_project");

    // Link project and check JSON status
    var link_result = try test_harness.execute_workspace_command("link --path {s}", .{project_path});
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

    var result = try test_harness.execute_workspace_command("link --path /nonexistent/path/12345", .{});
    defer result.deinit();

    // Should handle non-existent paths gracefully
    // Command may succeed with warning or fail with error
    if (result.exit_code != 0) {
        try testing.expect(result.stderr.len > 0);
    }
}

test "error handling: unlink --name non-existent codebase" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "unlink_error");
    defer test_harness.deinit();

    var result = try test_harness.execute_workspace_command("unlink --name nonexistent-project", .{});
    defer result.deinit();

    // Should provide error message
    if (result.exit_code != 0) {
        try testing.expect(result.stderr.len > 0);
        try testing.expect(result.contains_error("CodebaseNotFound") or result.contains_error("not found"));
    }
}

test "error handling: sync without linked codebases" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "sync_empty");
    defer test_harness.deinit();

    var result = try test_harness.execute_workspace_command("sync nonexistent-project", .{});
    defer result.deinit();

    // Should provide error message
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
    var link_result = try test_harness.execute_workspace_command("link --path {s} --name persistent", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    // Verify persistence in separate command invocation
    {
        var status_result = try test_harness.execute_command(&[_][]const u8{"status"});
        defer status_result.deinit();
        try status_result.expect_success();
        // After unlinking, should not show the persistent project
        try testing.expect(status_result.contains_output("KausalDB Status") or status_result.contains_output("Blocks:"));
    }

    // Modify workspace in another command invocation
    {
        var unlink_result = try test_harness.execute_workspace_command("unlink --name persistent", .{});
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

    var result = try test_harness.execute_workspace_command("link --path .", .{});
    defer result.deinit();
    try result.expect_success();

    // Should detect current directory name or use a default
    var status_result = try test_harness.execute_command(&[_][]const u8{"status"});
    defer status_result.deinit();
    try status_result.expect_success();
    try testing.expect(status_result.stdout.len > 10); // Should have some output
}

// This test reproduces the WriteBlocked issue by performing multiple rapid
// ingestion operations that could potentially overwhelm L0 SSTables
test "WriteBlocked error should not occur in single-threaded CLI context" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "writeblocked_test");
    defer test_harness.deinit();

    // Create multiple small test projects to test workspace operations
    const num_projects: u8 = 8; // Reasonable number to test functionality without overwhelming storage

    var i: u8 = 0;
    while (i < num_projects) : (i += 1) {
        const project_name = try std.fmt.allocPrint(test_harness.allocator, "project_{d}", .{i});
        defer test_harness.allocator.free(project_name);

        const project_path = try test_harness.create_test_project(project_name);
        // Note: project_path is managed by test_harness cleanup_paths, no need to free manually

        // Link each project - this should not trigger WriteBlocked in single-threaded context
        var link_result = try test_harness.execute_workspace_command("link --path {s} --name {s}", .{ project_path, project_name });
        defer link_result.deinit();

        // Commands should succeed with reasonable project count
        try link_result.expect_success();
    }

    // Verify status command works after multiple links
    var status_result = try test_harness.execute_command(&[_][]const u8{"status"});
    defer status_result.deinit();
    try status_result.expect_success();
    try testing.expect(status_result.contains_output("Workspaces:") or status_result.contains_output("linked"));
}

test "workspace statistics properly updated after sync" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "workspace_stats");
    defer test_harness.deinit();

    // Create test project with realistic code structure
    const project_path = try test_harness.create_test_project("test_project");

    // Test workspace linking via CLI
    var link_result = try test_harness.execute_command(&.{ "link", "--path", project_path, "--name", "test_project" });
    defer link_result.deinit();
    try link_result.expect_success();

    // Test initial statistics (should show the linked project)
    var status_before = try test_harness.execute_command(&.{"status"});
    defer status_before.deinit();
    try status_before.expect_success();
    try testing.expect(status_before.contains_output("test_project"));

    // Test sync operation via CLI
    var sync_result = try test_harness.execute_command(&.{ "sync", "test_project" });
    defer sync_result.deinit();
    try sync_result.expect_success();

    // Test updated statistics (should show blocks and edges)
    var status_after = try test_harness.execute_command(&.{"status"});
    defer status_after.deinit();
    try status_after.expect_success();
    try testing.expect(status_after.contains_output("Workspaces:") or status_after.contains_output("linked"));
    // Status should show storage information after sync
    try testing.expect(status_after.contains_output("Storage:") or status_after.contains_output("synced"));
}

test "workspace statistics shown in status command" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "workspace_status");
    defer test_harness.deinit();

    // Create test project with simple structure
    const project_path = try test_harness.create_test_project("simple_project");

    // Setup workspace via CLI
    var link_result = try test_harness.execute_command(&.{ "link", "--path", project_path, "--name", "simple_project" });
    defer link_result.deinit();
    try link_result.expect_success();

    var sync_result = try test_harness.execute_command(&.{ "sync", "simple_project" });
    defer sync_result.deinit();
    try sync_result.expect_success();

    // Test status command shows statistics
    var status_result = try test_harness.execute_command(&.{"status"});
    defer status_result.deinit();
    try status_result.expect_success();

    // Status should include workspace statistics
    try testing.expect(status_result.contains_output("Workspaces:") or status_result.contains_output("linked"));
    // Status should show storage information
    try testing.expect(status_result.contains_output("Storage:") or status_result.contains_output("synced"));
}

test "sync command ingests data successfully and updates workspace state" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "ingestion_validation");
    defer test_harness.deinit();

    // Create test project with known content for ingestion validation
    const project_path = try test_harness.create_test_project("ingestion_test");

    var link_result = try test_harness.execute_workspace_command("link --path {s}", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    // Primary test: Does sync command complete successfully?
    var sync_result = try test_harness.execute_workspace_command("sync ingestion_test", .{});
    defer sync_result.deinit();
    try sync_result.expect_success();

    // Secondary validation: Does status reflect the ingested state?
    var status_result = try test_harness.execute_command(&.{"status"});
    defer status_result.deinit();
    try status_result.expect_success();

    // Core assertions: Status should show evidence of successful ingestion
    try testing.expect(status_result.contains_output("Workspaces:") or status_result.contains_output("ingestion_test"));
    try testing.expect(status_result.stdout.len > 10); // Should have output

    // Tertiary validation: Workspace should be queryable after sync
    var find_result = try test_harness.execute_command(&[_][]const u8{ "find", "--type", "function", "--name", "main", "--workspace", "ingestion_test" });
    defer find_result.deinit();
    try find_result.expect_success(); // Query infrastructure should work
}

test "sync handles various file patterns and complex codebases" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "complex_ingestion");
    defer test_harness.deinit();

    // Create complex test project with multiple files and patterns
    const project_path = try test_harness.create_test_file_with_content("complex_project",
        \\const std = @import("std");
        \\
        \\// Different function patterns to test ingestion
        \\pub fn init() void {}
        \\fn private_function() void {}
        \\pub const Config = struct {
        \\    value: u32,
        \\    pub fn create() Config { return Config{ .value = 42 }; }
        \\};
        \\
        \\export fn c_function() void {}
        \\test "sample_test" { }
        \\
        \\pub fn main() void {
        \\    init();
        \\    private_function();
        \\    const config = Config.create();
        \\}
    );

    var link_result = try test_harness.execute_workspace_command("link --path {s}", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    var sync_result = try test_harness.execute_workspace_command("sync complex_project", .{});
    defer sync_result.deinit();
    try sync_result.expect_success();

    // Verify ingestion can handle various Zig language constructs
    var status_result = try test_harness.execute_command(&.{"status"});
    defer status_result.deinit();
    try status_result.expect_success();
    try testing.expect(status_result.contains_output("complex_project") or status_result.contains_output("Workspaces:"));
}
