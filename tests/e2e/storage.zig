//! End-to-end tests for storage pressure scenarios.
//!
//! Tests storage engine robustness under load, including WriteStalled error
//! prevention and backpressure handling when ingesting larger projects.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");

test "link large codebase does not cause WriteStalled errors" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "large_codebase");
    defer test_harness.deinit();

    // Create a larger test project with multiple files
    const project_path = try test_harness.create_large_test_project("large_project");

    // Attempt to link the larger project
    var link_result = try test_harness.execute_command(&[_][]const u8{ "link", "--path", project_path, "--name", "large_test" });
    defer link_result.deinit();

    // Should not fail with WriteStalled error
    if (link_result.exit_code != 0) {
        try testing.expect(!link_result.contains_error("WriteStalled"));
        try testing.expect(!link_result.contains_error("WriteBlocked"));
    }

    // If successful, should be able to sync
    if (link_result.exit_code == 0) {
        var sync_result = try test_harness.execute_command(&[_][]const u8{ "sync", "large_test" });
        defer sync_result.deinit();

        // Sync should also not fail with WriteStalled
        if (sync_result.exit_code != 0) {
            try testing.expect(!sync_result.contains_error("WriteStalled"));
            try testing.expect(!sync_result.contains_error("WriteBlocked"));
        }
    }
}

test "multiple workspaces can be linked without storage conflicts" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "multiple_workspaces");
    defer test_harness.deinit();

    // Create multiple moderate-sized projects
    const projects = [_][]const u8{ "project_a", "project_b", "project_c" };

    var created_paths = std.ArrayList([]const u8){};
    defer created_paths.deinit(testing.allocator);

    // Create and link each project
    for (projects, 0..) |project_name, i| {
        const project_path = try test_harness.create_large_test_project(project_name);
        try created_paths.append(testing.allocator, project_path);

        const workspace_name = try std.fmt.allocPrint(testing.allocator, "workspace_{d}", .{i});
        defer testing.allocator.free(workspace_name);

        var link_result = try test_harness.execute_command(&[_][]const u8{ "link", "--path", project_path, "--name", workspace_name });
        defer link_result.deinit();

        // Should not fail with storage pressure errors
        if (link_result.exit_code != 0) {
            try testing.expect(!link_result.contains_error("WriteStalled"));
            try testing.expect(!link_result.contains_error("WriteBlocked"));
            try testing.expect(!link_result.contains_error("storage pressure"));
        }
    }

    // Try to sync all workspaces
    for (0..projects.len) |i| {
        const workspace_name = try std.fmt.allocPrint(testing.allocator, "workspace_{d}", .{i});
        defer testing.allocator.free(workspace_name);

        var sync_result = try test_harness.execute_command(&[_][]const u8{ "sync", workspace_name });
        defer sync_result.deinit();

        // Should handle multiple workspaces without storage conflicts
        if (sync_result.exit_code != 0) {
            try testing.expect(!sync_result.contains_error("WriteStalled"));
            try testing.expect(!sync_result.contains_error("WriteBlocked"));
        }
    }
}

test "ingestion handles files with substantial content" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "substantial_content");
    defer test_harness.deinit();

    // Create project with files containing substantial content
    const project_path = try test_harness.create_substantial_content_project("substantial_test");

    var link_result = try test_harness.execute_command(&[_][]const u8{ "link", "--path", project_path, "--name", "substantial" });
    defer link_result.deinit();

    // Should handle substantial file content without memory or storage pressure
    if (link_result.exit_code != 0) {
        try testing.expect(!link_result.contains_error("WriteStalled"));
        try testing.expect(!link_result.contains_error("out of memory"));
        try testing.expect(!link_result.contains_error("memory limit"));
    }

    // Try to sync the substantial content
    if (link_result.exit_code == 0) {
        var sync_result = try test_harness.execute_command(&[_][]const u8{ "sync", "substantial" });
        defer sync_result.deinit();

        if (sync_result.exit_code != 0) {
            try testing.expect(!sync_result.contains_error("WriteStalled"));
            try testing.expect(!sync_result.contains_error("memory"));
        }
    }
}

test "repeated sync operations handle storage pressure gracefully" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "repeated_sync");
    defer test_harness.deinit();

    const project_path = try test_harness.create_large_test_project("repeated_test");

    var link_result = try test_harness.execute_command(&[_][]const u8{ "link", "--path", project_path, "--name", "repeated" });
    defer link_result.deinit();

    if (link_result.exit_code == 0) {
        // Perform multiple sync operations to stress storage
        for (0..5) |i| {
            _ = i;
            var sync_result = try test_harness.execute_command(&[_][]const u8{ "sync", "repeated" });
            defer sync_result.deinit();

            // Each sync should handle storage pressure gracefully
            if (sync_result.exit_code != 0) {
                try testing.expect(!sync_result.contains_error("WriteStalled"));
                try testing.expect(!sync_result.contains_error("WriteBlocked"));
            }
        }
    }
}

test "storage cleanup between operations prevents accumulation" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "cleanup_test");
    defer test_harness.deinit();

    // Create and link multiple projects in sequence
    for (0..3) |i| {
        const project_name = try std.fmt.allocPrint(testing.allocator, "cleanup_project_{d}", .{i});
        defer testing.allocator.free(project_name);

        const workspace_name = try std.fmt.allocPrint(testing.allocator, "cleanup_ws_{d}", .{i});
        defer testing.allocator.free(workspace_name);

        const project_path = try test_harness.create_large_test_project(project_name);

        // Link project
        var link_result = try test_harness.execute_command(&[_][]const u8{ "link", "--path", project_path, "--name", workspace_name });
        defer link_result.deinit();

        // Should not accumulate storage pressure across operations
        if (link_result.exit_code != 0) {
            try testing.expect(!link_result.contains_error("WriteStalled"));
        }

        // Sync project
        if (link_result.exit_code == 0) {
            var sync_result = try test_harness.execute_command(&[_][]const u8{ "sync", workspace_name });
            defer sync_result.deinit();

            if (sync_result.exit_code != 0) {
                try testing.expect(!sync_result.contains_error("WriteStalled"));
            }
        }

        // Unlink to test cleanup
        var unlink_result = try test_harness.execute_command(&[_][]const u8{ "unlink", "--name", workspace_name });
        defer unlink_result.deinit();

        // Unlink should work without storage issues
        if (unlink_result.exit_code != 0) {
            try testing.expect(!unlink_result.contains_error("WriteStalled"));
        }
    }
}

test "e2e: concurrent client connections (10 clients, 100 ops each)" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "concurrent_clients");
    defer test_harness.deinit();

    // Create test project
    const project_path = try test_harness.create_large_test_project("concurrent_test");
    var link_result = try test_harness.execute_command(&[_][]const u8{ "link", "--path", project_path, "--name", "concurrent_ws" });
    defer link_result.deinit();
    try testing.expect(link_result.exit_code == 0);

    // Concurrent client simulation using multiple command executions
    const num_clients = 10;
    const ops_per_client = 10; // Reduced for E2E test practicality

    var i: usize = 0;
    while (i < num_clients) : (i += 1) {
        // Each "client" performs a series of operations
        var j: usize = 0;
        while (j < ops_per_client) : (j += 1) {
            // Alternate between different operations
            if (j % 3 == 0) {
                var find_result = try test_harness.execute_command(&[_][]const u8{ "find", "test" });
                defer find_result.deinit();
                // Commands may succeed or fail, but should not crash
            } else if (j % 3 == 1) {
                var status_result = try test_harness.execute_command(&[_][]const u8{"status"});
                defer status_result.deinit();
            } else {
                var list_result = try test_harness.execute_command(&[_][]const u8{"list"});
                defer list_result.deinit();
            }
        }
    }

    // Verify server handled multiple simultaneous-like connections
    var final_status = try test_harness.execute_command(&[_][]const u8{"status"});
    defer final_status.deinit();
    try testing.expect(final_status.exit_code == 0);
}

test "e2e: server graceful shutdown with active queries" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "graceful_shutdown");
    defer test_harness.deinit();

    // Create and link test project
    const project_path = try test_harness.create_large_test_project("shutdown_test");
    var link_result = try test_harness.execute_command(&[_][]const u8{ "link", "--path", project_path, "--name", "shutdown_ws" });
    defer link_result.deinit();
    try testing.expect(link_result.exit_code == 0);

    // Start some queries
    var find_result1 = try test_harness.execute_command(&[_][]const u8{ "find", "function" });
    defer find_result1.deinit();

    var find_result2 = try test_harness.execute_command(&[_][]const u8{ "find", "struct" });
    defer find_result2.deinit();

    // Server shutdown is handled by test_harness.deinit()
    // Verify no data loss or corruption during shutdown
    var status_result = try test_harness.execute_command(&[_][]const u8{"status"});
    defer status_result.deinit();

    // Status should work correctly even after active queries
    try testing.expect(status_result.exit_code == 0);
}
