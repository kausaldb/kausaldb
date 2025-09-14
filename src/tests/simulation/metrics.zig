//! Simulation metrics test - demonstrates performance tracking in deterministic testing.

const std = @import("std");

const deterministic_test = @import("../../sim/deterministic_test.zig");
const storage_engine_mod = @import("../../storage/engine.zig");
const types = @import("../../core/types.zig");

const testing = std.testing;
const log = std.log.scoped(.simulation_metrics);

// Type aliases from deterministic test framework
const ModelState = deterministic_test.ModelState;
const OperationMix = deterministic_test.OperationMix;
const SimulationRunner = deterministic_test.SimulationRunner;
const WorkloadGenerator = deterministic_test.WorkloadGenerator;
const StorageEngine = storage_engine_mod.StorageEngine;
const BlockId = types.BlockId;

test "simulation metrics track basic operation statistics" {
    const allocator = testing.allocator;
    const seed = 0xABCDE001;

    // Use deterministic simulation runner instead of harness
    var runner = try SimulationRunner.init(allocator, seed, .{
        .put_block_weight = 70,
        .find_block_weight = 20,
        .delete_block_weight = 10,
    }, &.{});
    defer runner.deinit();

    // Run simulation with operation tracking
    try runner.run(100);

    // Verify simulation completed
    try testing.expect(runner.model.operation_count >= 100);

    log.info("Basic simulation metrics test completed successfully", .{});
    log.info("  Operations executed: {}", .{runner.model.operation_count});
}

test "simulation metrics track memory usage during write-heavy workload" {
    const allocator = testing.allocator;
    const seed = 0xABCDE002;

    // Write-heavy workload mix
    const write_heavy_mix = OperationMix{
        .put_block_weight = 85,
        .find_block_weight = 15,
        .delete_block_weight = 0,
    };

    var runner = try SimulationRunner.init(allocator, seed, write_heavy_mix, &.{});
    defer runner.deinit();

    // Track initial memory usage
    const initial_memory = runner.storage_engine.memory_usage();

    // Run write-heavy simulation
    try runner.run(200);

    // Check final memory usage
    const final_memory = runner.storage_engine.memory_usage();
    try testing.expect(final_memory.total_bytes >= initial_memory.total_bytes);

    log.info("Write-heavy workload completed:", .{});
    log.info("  Operations executed: {}", .{runner.model.operation_count});
    log.info("  Final memory: {} bytes", .{final_memory.total_bytes});
}

test "simulation validates multiple operation patterns" {
    const allocator = testing.allocator;
    const seed = 0xABCDE003;

    // Test multiple operation mixes
    const patterns = [_]OperationMix{
        .{ .put_block_weight = 60, .find_block_weight = 30, .delete_block_weight = 10 },
        .{ .put_block_weight = 30, .find_block_weight = 60, .delete_block_weight = 10 },
        .{ .put_block_weight = 80, .find_block_weight = 15, .delete_block_weight = 5 },
    };

    for (patterns, 0..) |mix, i| {
        var runner = try SimulationRunner.init(allocator, seed + i, mix, &.{});
        defer runner.deinit();

        try runner.run(150);

        // Each pattern should complete successfully
        try testing.expect(runner.model.operation_count >= 150);

        log.info("Pattern {} completed:", .{i + 1});
        log.info("  Operations executed: {}", .{runner.model.operation_count});
    }
}

test "simulation performance bounds check" {
    const allocator = testing.allocator;
    const seed = 0xABCDE004;

    // Balanced workload for performance testing
    const balanced_mix = OperationMix{
        .put_block_weight = 40,
        .find_block_weight = 40,
        .delete_block_weight = 20,
    };

    var runner = try SimulationRunner.init(allocator, seed, balanced_mix, &.{});
    defer runner.deinit();

    const start_time = std.time.milliTimestamp();
    try runner.run(300);
    const end_time = std.time.milliTimestamp();
    const duration_ms = end_time - start_time;

    // Basic performance validation
    try testing.expect(runner.model.operation_count >= 300);
    try testing.expect(duration_ms > 0); // Should take measurable time

    // Memory should be bounded
    const final_memory = runner.storage_engine.memory_usage();
    const per_op_memory = if (runner.model.operation_count > 0)
        final_memory.total_bytes / runner.model.operation_count
    else
        0;
    try testing.expect(per_op_memory < 100 * 1024); // Less than 100KB per op

    log.info("Performance bounds check completed:", .{});
    log.info("  Duration: {} ms", .{duration_ms});
    log.info("  Operations executed: {}", .{runner.model.operation_count});
    log.info("  Memory per operation: {} bytes", .{per_op_memory});
}
