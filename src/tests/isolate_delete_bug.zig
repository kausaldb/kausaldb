//! Test to isolate if the bug is related to delete operations

const std = @import("std");
const testing = std.testing;

const harness_mod = @import("../testing/harness.zig");

const OperationMix = harness_mod.OperationMix;
const SimulationRunner = harness_mod.SimulationRunner;

test "500 operations WITHOUT delete operations" {
    const allocator = testing.allocator;

    std.debug.print("\n=== 500 operations WITHOUT deletes ===\n", .{});

    var runner = try SimulationRunner.init(
        allocator,
        0x1234, // Same seed as failing test
        OperationMix{
            .put_block_weight = 90, // No deletes
            .find_block_weight = 10,
            .delete_block_weight = 0, // ZERO delete operations
            .put_edge_weight = 0,
            .find_edges_weight = 0,
        },
        &.{},
    );
    defer runner.deinit();

    runner.flush_config.operation_threshold = 20;
    runner.flush_config.enable_operation_trigger = true;

    std.debug.print("Running 500 operations with NO delete operations...\n", .{});
    try runner.run(500);

    std.debug.print("Verifying consistency...\n", .{});
    try runner.verify_consistency();

    std.debug.print("✅ 500 operations WITHOUT deletes passed\n", .{});
}

test "500 operations WITH delete operations" {
    const allocator = testing.allocator;

    std.debug.print("\n=== 500 operations WITH deletes ===\n", .{});

    var runner = try SimulationRunner.init(
        allocator,
        0x1234, // Same seed as failing test
        OperationMix{
            .put_block_weight = 85,
            .find_block_weight = 10,
            .delete_block_weight = 5, // Same as failing test
            .put_edge_weight = 0,
            .find_edges_weight = 0,
        },
        &.{},
    );
    defer runner.deinit();

    runner.flush_config.operation_threshold = 20;
    runner.flush_config.enable_operation_trigger = true;

    std.debug.print("Running 500 operations WITH delete operations...\n", .{});
    try runner.run(500);

    std.debug.print("Verifying consistency...\n", .{});
    try runner.verify_consistency();

    std.debug.print("✅ 500 operations WITH deletes passed\n", .{});
}
