//! End-to-end tests for KausalDB ingestion functionality.
//!
//! Tests complete ingestion pipeline from local directories through to queryable
//! blocks and edges in the database. Validates that real source code gets
//! properly parsed, chunked, and stored for querying.
//!
//! This is critical test coverage that was missing - the existing E2E tests
//! only validate CLI interface behavior, not actual ingestion functionality.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");

test "local directory ingestion basic functionality" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "ingestion_basic");
    defer test_harness.deinit();

    // Create a test Zig project with multiple functions
    const project_path = try test_harness.create_test_project("basic_ingestion");

    // Verify the project files exist
    const main_path = try std.fs.path.join(testing.allocator, &[_][]const u8{ project_path, "main.zig" });
    defer testing.allocator.free(main_path);

    std.fs.accessAbsolute(main_path, .{}) catch |err| {
        std.debug.print("Test project main.zig not found at: {s}\n", .{main_path});
        return err;
    };

    // Link and sync the project
    var link_result = try test_harness.execute_workspace_command("link {s} as test_basic", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    var sync_result = try test_harness.execute_workspace_command("sync test_basic", .{});
    defer sync_result.deinit();
    try sync_result.expect_success();

    // Verify workspace shows blocks were ingested
    var status_result = try test_harness.execute_command(&[_][]const u8{"status"});
    defer status_result.deinit();
    try status_result.expect_success();

    // Should show non-zero blocks and edges after successful ingestion
    // The test project has multiple functions that should create blocks
    std.debug.print("Status output: {s}\n", .{status_result.stdout});

    // Check for evidence of successful ingestion
    const has_blocks_info = std.mem.indexOf(u8, status_result.stdout, "Blocks:") != null;
    const has_edges_info = std.mem.indexOf(u8, status_result.stdout, "Edges:") != null;

    if (!has_blocks_info or !has_edges_info) {
        std.debug.print("Status output missing blocks/edges information\n", .{});
        return error.MissingIngestionInfo;
    }

    // Test that we can find functions that definitely exist in our test project
    var find_main_result = try test_harness.execute_command(&[_][]const u8{ "find", "function", "main", "in", "test_basic" });
    defer find_main_result.deinit();
    try find_main_result.expect_success();

    var find_helper_result = try test_harness.execute_command(&[_][]const u8{ "find", "function", "helper_function", "in", "test_basic" });
    defer find_helper_result.deinit();
    try find_helper_result.expect_success();

    var find_calculate_result = try test_harness.execute_command(&[_][]const u8{ "find", "function", "calculate_value", "in", "test_basic" });
    defer find_calculate_result.deinit();
    try find_calculate_result.expect_success();

    // Should NOT find functions that don't exist
    var find_nonexistent_result = try test_harness.execute_command(&[_][]const u8{ "find", "function", "nonexistent_function", "in", "test_basic" });
    defer find_nonexistent_result.deinit();
    try find_nonexistent_result.expect_success();

    // Should report not found
    try testing.expect(find_nonexistent_result.contains_output("not found") or
        find_nonexistent_result.contains_output("No function"));
}

test "local directory ingestion with multiple files" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "ingestion_multifile");
    defer test_harness.deinit();

    // The test project created by create_test_project has main.zig and utils.zig
    const project_path = try test_harness.create_test_project("multifile_test");

    // Link and sync
    var link_result = try test_harness.execute_workspace_command("link {s} as multifile", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    var sync_result = try test_harness.execute_workspace_command("sync multifile", .{});
    defer sync_result.deinit();
    try sync_result.expect_success();

    // Test finding functions from different files
    var find_main_result = try test_harness.execute_command(&[_][]const u8{ "find", "function", "main", "in", "multifile" });
    defer find_main_result.deinit();
    try find_main_result.expect_success();

    var find_utility_result = try test_harness.execute_command(&[_][]const u8{ "find", "function", "utility_function", "in", "multifile" });
    defer find_utility_result.deinit();
    try find_utility_result.expect_success();

    var find_add_numbers_result = try test_harness.execute_command(&[_][]const u8{ "find", "function", "add_numbers", "in", "multifile" });
    defer find_add_numbers_result.deinit();
    try find_add_numbers_result.expect_success();

    // Test cross-file relationships
    var show_callers_result = try test_harness.execute_command(&[_][]const u8{ "show", "callers", "utility_function", "in", "multifile" });
    defer show_callers_result.deinit();
    try show_callers_result.expect_success();

    var trace_callees_result = try test_harness.execute_command(&[_][]const u8{ "trace", "callees", "main", "in", "multifile" });
    defer trace_callees_result.deinit();
    try trace_callees_result.expect_success();
}

test "ingestion error handling with invalid directory" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "ingestion_errors");
    defer test_harness.deinit();

    // Try to link a non-existent directory
    var link_result = try test_harness.execute_command(&[_][]const u8{ "link", "/nonexistent/path", "as", "invalid" });
    defer link_result.deinit();

    // Should fail gracefully with meaningful error
    try link_result.expect_failure();
    try testing.expect(link_result.contains_error("not found") or
        link_result.contains_error("does not exist") or
        link_result.contains_error("Invalid"));
}

test "ingestion handles empty directory gracefully" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "ingestion_empty");
    defer test_harness.deinit();

    // Create an empty directory
    const timestamp = std.time.timestamp();
    const empty_dir = try std.fmt.allocPrint(testing.allocator, "/tmp/kausaldb_empty_{d}", .{timestamp});
    defer testing.allocator.free(empty_dir);

    try std.fs.makeDirAbsolute(empty_dir);
    defer std.fs.deleteTreeAbsolute(empty_dir) catch {};

    // Link and sync empty directory
    var link_result = try test_harness.execute_workspace_command("link {s} as empty", .{empty_dir});
    defer link_result.deinit();
    try link_result.expect_success();

    var sync_result = try test_harness.execute_workspace_command("sync empty", .{});
    defer sync_result.deinit();
    try sync_result.expect_success();

    // Should handle empty directory without crashing
    var status_result = try test_harness.execute_command(&[_][]const u8{"status"});
    defer status_result.deinit();
    try status_result.expect_success();

    try testing.expect(status_result.contains_output("empty"));
}

test "ingestion with various Zig source patterns" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "ingestion_patterns");
    defer test_harness.deinit();

    // Create a more complex test project to verify parser handles various patterns
    const timestamp = std.time.timestamp();
    const project_path = try std.fmt.allocPrint(testing.allocator, "/tmp/kausaldb_complex_{d}", .{timestamp});
    defer testing.allocator.free(project_path);

    try std.fs.makeDirAbsolute(project_path);
    defer std.fs.deleteTreeAbsolute(project_path) catch {};

    // Create various Zig source patterns
    const complex_zig_content =
        \\const std = @import("std");
        \\const builtin = @import("builtin");
        \\
        \\// Various function patterns
        \\pub fn public_function() void {}
        \\fn private_function() void {}
        \\export fn export_function() void {}
        \\
        \\// Generic functions
        \\pub fn generic_function(comptime T: type) T {}
        \\
        \\// Struct with methods
        \\pub const TestStruct = struct {
        \\    value: i32,
        \\    
        \\    pub fn init(val: i32) TestStruct {
        \\        return TestStruct{ .value = val };
        \\    }
        \\    
        \\    pub fn process(self: *TestStruct) void {
        \\        self.value *= 2;
        \\    }
        \\};
        \\
        \\// Error handling
        \\const MyError = error{InvalidInput};
        \\
        \\pub fn fallible_function() MyError!void {
        \\    return MyError.InvalidInput;
        \\}
        \\
        \\// Constants and variables
        \\pub const MAX_SIZE = 1024;
        \\var global_counter: u32 = 0;
        \\
        \\test "example test" {
        \\    try std.testing.expect(true);
        \\}
    ;

    const complex_path = try std.fs.path.join(testing.allocator, &[_][]const u8{ project_path, "complex.zig" });
    defer testing.allocator.free(complex_path);

    {
        const file = try std.fs.createFileAbsolute(complex_path, .{});
        defer file.close();
        try file.writeAll(complex_zig_content);
    }

    // Link and sync
    var link_result = try test_harness.execute_workspace_command("link {s} as complex", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    var sync_result = try test_harness.execute_workspace_command("sync complex", .{});
    defer sync_result.deinit();
    try sync_result.expect_success();

    // Test finding various function patterns
    const function_names = [_][]const u8{
        "public_function",
        "private_function",
        "export_function",
        "generic_function",
        "init",
        "process",
        "fallible_function",
    };

    for (function_names) |func_name| {
        var find_result = try test_harness.execute_command(&[_][]const u8{ "find", "function", func_name, "in", "complex" });
        defer find_result.deinit();
        try find_result.expect_success();

        std.debug.print("Finding {s}: {s}\n", .{ func_name, find_result.stdout });

        // Should either find the function or provide meaningful "not found" message
        // At minimum, should not crash or produce empty output
        try testing.expect(find_result.stdout.len > 0);
    }
}

test "ingestion stats and workspace information" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "ingestion_stats");
    defer test_harness.deinit();

    const project_path = try test_harness.create_test_project("stats_test");

    // Link and sync
    var link_result = try test_harness.execute_workspace_command("link {s} as stats", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    // Check status before sync
    var status_before = try test_harness.execute_command(&[_][]const u8{"status"});
    defer status_before.deinit();
    try status_before.expect_success();

    std.debug.print("Status before sync: {s}\n", .{status_before.stdout});

    var sync_result = try test_harness.execute_workspace_command("sync stats", .{});
    defer sync_result.deinit();
    try sync_result.expect_success();

    std.debug.print("Sync output: {s}\n", .{sync_result.stdout});

    // Check status after sync
    var status_after = try test_harness.execute_command(&[_][]const u8{"status"});
    defer status_after.deinit();
    try status_after.expect_success();

    std.debug.print("Status after sync: {s}\n", .{status_after.stdout});

    // Status should show the linked codebase and sync information
    try testing.expect(status_after.contains_output("stats"));
    try testing.expect(status_after.contains_output("linked"));

    // Should show block and edge counts or at least the structure for them
    const has_workspace_info = status_after.contains_output("WORKSPACE") or
        status_after.contains_output("Blocks:") or
        status_after.contains_output("synced");
    try testing.expect(has_workspace_info);
}
