//! End-to-end test for workspace statistics reporting fix
//!
//! Validates that sync_codebase properly updates block_count and edge_count
//! statistics, fixing the issue where users saw "Blocks: 0" after ingestion.
//!
//! This test demonstrates the core fix: simplified ingestion pipeline now
//! accurately tracks and reports statistics during codebase synchronization.

const std = @import("std");
const testing = std.testing;

const coordinator = @import("../../src/coordinator.zig");
const simulation_vfs = @import("../../src/core/simulation_vfs.zig");
const vfs = @import("../../src/core/vfs.zig");
const workspace_manager = @import("../../src/workspace/manager.zig");

const Coordinator = coordinator.Coordinator;
const SimulationVFS = simulation_vfs.SimulationVFS;
const WorkspaceManager = workspace_manager.WorkspaceManager;

test "workspace statistics properly updated after sync" {
    var sim_vfs = try SimulationVFS.init(testing.allocator);
    defer sim_vfs.deinit();
    var vfs_instance = vfs.VFS{ .simulation = sim_vfs };

    // Create test project structure with multiple Zig files
    try sim_vfs.create_directory("/test_project");

    // Main application file
    try sim_vfs.create_file("/test_project/main.zig",
        \\const std = @import("std");
        \\const math = @import("math.zig");
        \\const utils = @import("utils.zig");
        \\
        \\pub fn main() void {
        \\    const result = math.calculate(42);
        \\    utils.print_result(result);
        \\    std.debug.print("Application started\n", .{});
        \\}
        \\
        \\pub fn initialize_app() void {
        \\    // Setup application state
        \\}
    );

    // Math utilities
    try sim_vfs.create_file("/test_project/math.zig",
        \\const std = @import("std");
        \\
        \\pub fn calculate(x: i32) i32 {
        \\    return fibonacci(x) + square(x);
        \\}
        \\
        \\pub fn fibonacci(n: i32) i32 {
        \\    if (n <= 1) return n;
        \\    return fibonacci(n - 1) + fibonacci(n - 2);
        \\}
        \\
        \\pub fn square(x: i32) i32 {
        \\    return x * x;
        \\}
        \\
        \\fn helper_function(a: i32, b: i32) i32 {
        \\    return a + b * 2;
        \\}
    );

    // Utility functions
    try sim_vfs.create_file("/test_project/utils.zig",
        \\const std = @import("std");
        \\const math = @import("math.zig");
        \\
        \\pub fn print_result(value: i32) void {
        \\    std.debug.print("Result: {}\n", .{value});
        \\}
        \\
        \\pub fn format_output(value: i32) []const u8 {
        \\    // This would format the output
        \\    _ = value;
        \\    return "formatted";
        \\}
        \\
        \\test "utility functions" {
        \\    try std.testing.expect(math.square(4) == 16);
        \\}
    );

    // Initialize coordinator and workspace manager
    var coord = try Coordinator.init(testing.allocator, &vfs_instance);
    defer coord.deinit();

    try coord.startup();
    defer coord.shutdown();

    var workspace = try WorkspaceManager.init(testing.allocator, coord.storage_engine(), &coord);
    defer workspace.deinit();

    try workspace.startup();
    defer workspace.shutdown();

    // Link the test codebase
    try workspace.link_codebase("test_project", "/test_project");

    // Get initial statistics - should be zero
    const codebases_before = try workspace.list_codebases(testing.allocator);
    defer {
        for (codebases_before) |codebase| {
            testing.allocator.free(codebase.name);
            testing.allocator.free(codebase.path);
        }
        testing.allocator.free(codebases_before);
    }

    try testing.expectEqual(@as(usize, 1), codebases_before.len);
    try testing.expectEqualStrings("test_project", codebases_before[0].name);
    try testing.expectEqual(@as(u32, 0), codebases_before[0].block_count);
    try testing.expectEqual(@as(u32, 0), codebases_before[0].edge_count);

    // Sync the codebase - this should process the files and update statistics
    try workspace.sync_codebase("test_project");

    // Get updated statistics
    const codebases_after = try workspace.list_codebases(testing.allocator);
    defer {
        for (codebases_after) |codebase| {
            testing.allocator.free(codebase.name);
            testing.allocator.free(codebase.path);
        }
        testing.allocator.free(codebases_after);
    }

    try testing.expectEqual(@as(usize, 1), codebases_after.len);

    const synced_codebase = codebases_after[0];

    // Verify statistics were properly updated
    try testing.expectEqualStrings("test_project", synced_codebase.name);

    // Should have processed multiple blocks from the 3 files
    // Expected blocks: imports (3) + functions (~8) + test (1) ≈ 12+ blocks
    try testing.expect(synced_codebase.block_count > 0);
    try testing.expect(synced_codebase.block_count >= 10); // At least 10 semantic units

    // Edge count should be approximately 2x block count (imports + calls)
    try testing.expect(synced_codebase.edge_count > 0);
    try testing.expect(synced_codebase.edge_count >= synced_codebase.block_count * 2);

    // Verify last sync timestamp was updated
    try testing.expect(synced_codebase.last_sync_timestamp > codebases_before[0].last_sync_timestamp);

    std.debug.print("Statistics fix verified: {} blocks, {} edges processed\n", .{
        synced_codebase.block_count,
        synced_codebase.edge_count,
    });
}

test "workspace statistics persist across manager restarts" {
    var sim_vfs = try SimulationVFS.init(testing.allocator);
    defer sim_vfs.deinit();
    var vfs_instance = vfs.VFS{ .simulation = sim_vfs };

    // Create simple test project
    try sim_vfs.create_directory("/persist_test");
    try sim_vfs.create_file("/persist_test/simple.zig",
        \\const std = @import("std");
        \\
        \\pub fn main() void {
        \\    std.debug.print("Hello\n", .{});
        \\}
        \\
        \\pub fn helper() i32 {
        \\    return 42;
        \\}
    );

    // Initialize first workspace manager instance
    var coord = try Coordinator.init(testing.allocator, &vfs_instance);
    defer coord.deinit();

    try coord.startup();
    defer coord.shutdown();

    var workspace1 = try WorkspaceManager.init(testing.allocator, coord.storage_engine(), &coord);
    defer workspace1.deinit();

    try workspace1.startup();
    try workspace1.link_codebase("persist_test", "/persist_test");
    try workspace1.sync_codebase("persist_test");

    // Get statistics from first instance
    const codebases1 = try workspace1.list_codebases(testing.allocator);
    defer {
        for (codebases1) |codebase| {
            testing.allocator.free(codebase.name);
            testing.allocator.free(codebase.path);
        }
        testing.allocator.free(codebases1);
    }

    const original_block_count = codebases1[0].block_count;
    const original_edge_count = codebases1[0].edge_count;

    try testing.expect(original_block_count > 0);
    try testing.expect(original_edge_count > 0);

    workspace1.shutdown();

    // Create second workspace manager instance (simulating restart)
    var workspace2 = try WorkspaceManager.init(testing.allocator, coord.storage_engine(), &coord);
    defer workspace2.deinit();

    try workspace2.startup();
    defer workspace2.shutdown();

    // Verify statistics persisted
    const codebases2 = try workspace2.list_codebases(testing.allocator);
    defer {
        for (codebases2) |codebase| {
            testing.allocator.free(codebase.name);
            testing.allocator.free(codebase.path);
        }
        testing.allocator.free(codebases2);
    }

    try testing.expectEqual(@as(usize, 1), codebases2.len);
    try testing.expectEqualStrings("persist_test", codebases2[0].name);
    try testing.expectEqual(original_block_count, codebases2[0].block_count);
    try testing.expectEqual(original_edge_count, codebases2[0].edge_count);

    std.debug.print("Statistics persistence verified: {} blocks, {} edges retained after restart\n", .{
        codebases2[0].block_count,
        codebases2[0].edge_count,
    });
}
