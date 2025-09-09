//! End-to-end test for workspace statistics reporting fix
//!
//! Validates that CLI commands properly report workspace statistics
//! after codebase synchronization via subprocess execution.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");

test "workspace statistics properly updated after sync" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "workspace_stats");
    defer test_harness.deinit();

    // Create test project with realistic code structure
    const project_path = try test_harness.create_test_project("test_project");

    // Test workspace linking via CLI
    var link_result = try test_harness.execute_command(&.{ "link", project_path, "as", "test_project" });
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
    try testing.expect(status_after.contains_output("Blocks:"));
    try testing.expect(status_after.contains_output("Edges:"));

    std.debug.print("Workspace statistics E2E test completed successfully\n", .{});
}

test "workspace statistics shown in status command" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "workspace_status");
    defer test_harness.deinit();

    // Create test project with simple structure
    const project_path = try test_harness.create_test_project("simple_project");

    // Setup workspace via CLI
    var link_result = try test_harness.execute_command(&.{ "link", project_path, "as", "simple_project" });
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
    try testing.expect(status_result.contains_output("simple_project"));
    try testing.expect(status_result.contains_output("Blocks:"));
    try testing.expect(status_result.contains_output("Edges:"));

    std.debug.print("Workspace status E2E test completed successfully\n", .{});
}
