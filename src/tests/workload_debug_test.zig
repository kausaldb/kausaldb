//! Debug test to understand why workload generator isn't creating edges.
//!
//! This test creates a workload generator and inspects the operations it produces
//! to determine why integration tests show 0 edges being created.

const std = @import("std");
const testing = std.testing;

const workload = @import("../testing/workload.zig");

const WorkloadGenerator = workload.WorkloadGenerator;
const OperationType = workload.OperationType;
const OperationMix = workload.OperationMix;

test "workload generator creates edges after sufficient blocks" {
    const allocator = testing.allocator;

    // Use the same mix as the failing integration test
    const operation_mix = OperationMix{
        .put_block_weight = 35,
        .find_block_weight = 40,
        .delete_block_weight = 5,
        .put_edge_weight = 15,
        .find_edges_weight = 5,
    };

    var generator = try WorkloadGenerator.init(allocator, 0x12345, operation_mix);
    defer generator.deinit();

    // Track operation types
    var block_count: u32 = 0;
    var edge_count: u32 = 0;
    var delete_count: u32 = 0;
    var find_count: u32 = 0;
    var update_count: u32 = 0;
    var find_edges_count: u32 = 0;

    // Generate 1000 operations and count them
    for (0..1000) |i| {
        const operation = try generator.generate_operation();

        switch (operation.op_type) {
            .put_block => block_count += 1,
            .put_edge => {
                edge_count += 1;
                if (i < 100) { // Log first 100 edge operations for debugging
                    std.debug.print("Operation {}: PUT_EDGE created (total blocks: {})\n", .{ i, generator.created_blocks.items.len });
                }
            },
            .delete_block => delete_count += 1,
            .find_block => find_count += 1,
            .update_block => update_count += 1,
            .find_edges => find_edges_count += 1,
        }

        // Log every 100 operations to see progression
        if ((i + 1) % 100 == 0) {
            std.debug.print("After {} ops: blocks={}, edges={}, created_blocks={}\n", .{ i + 1, block_count, edge_count, generator.created_blocks.items.len });
        }
    }

    std.debug.print("Final counts after 1000 operations:\n");
    std.debug.print("  put_block: {}\n", .{block_count});
    std.debug.print("  put_edge: {}\n", .{edge_count});
    std.debug.print("  delete_block: {}\n", .{delete_count});
    std.debug.print("  find_block: {}\n", .{find_count});
    std.debug.print("  update_block: {}\n", .{update_count});
    std.debug.print("  find_edges: {}\n", .{find_edges_count});
    std.debug.print("  created_blocks: {}\n", .{generator.created_blocks.items.len});

    // We should have created some edges after 1000 operations
    try testing.expect(edge_count > 0);
    try testing.expect(generator.created_blocks.items.len >= 2);
}

test "workload generator operation mix distribution" {
    const allocator = testing.allocator;

    // Test with high edge probability
    const edge_heavy_mix = OperationMix{
        .put_block_weight = 10,
        .find_block_weight = 10,
        .delete_block_weight = 0,
        .put_edge_weight = 80, // 80% edges
        .find_edges_weight = 0,
    };

    var generator = try WorkloadGenerator.init(allocator, 0x54321, edge_heavy_mix);
    defer generator.deinit();

    var edge_count: u32 = 0;
    var total_after_blocks: u32 = 0;

    // Generate operations and count edges after we have blocks
    for (0..500) |_| {
        const operation = try generator.generate_operation();

        // Count operations after we have enough blocks for edges
        if (generator.created_blocks.items.len >= 2) {
            total_after_blocks += 1;
            if (operation.op_type == .put_edge) {
                edge_count += 1;
            }
        }
    }

    std.debug.print("Edge-heavy test: {} edges out of {} ops after blocks available\n", .{ edge_count, total_after_blocks });
    std.debug.print("Edge percentage: {d:.1}%\n", .{@as(f64, @floatFromInt(edge_count)) / @as(f64, @floatFromInt(total_after_blocks)) * 100.0});

    // With 80% edge weight, we should see significant edge creation
    try testing.expect(total_after_blocks > 0);
    if (total_after_blocks > 0) {
        const edge_percentage = (@as(f64, @floatFromInt(edge_count)) / @as(f64, @floatFromInt(total_after_blocks))) * 100.0;
        try testing.expect(edge_percentage > 50.0); // Should be around 80%
    }
}
