//! Regression test to reproduce edge loss during memtable flush operations.
//!
//! This test demonstrates the critical bug where edges are lost when memtable
//! flushes occur due to the GraphEdgeIndex being cleared along with the BlockIndex.
//! The test performs a controlled sequence: add blocks, add edges, verify edges exist,
//! force flush, then verify edges still exist after flush.
//!
//! Expected behavior: edges should persist across memtable flushes
//! Actual behavior: edges are lost when memtable is cleared during flush

const std = @import("std");
const testing = std.testing;

const harness = @import("../../testing/harness.zig");
const types = @import("../../core/types.zig");

const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const EdgeType = types.EdgeType;
const GraphEdge = types.GraphEdge;
const SimulationRunner = harness.SimulationRunner;
const OperationMix = harness.OperationMix;

/// Create a deterministic test block with predictable content
fn create_test_block(id: BlockId, content_suffix: []const u8) ContextBlock {
    return ContextBlock{
        .id = id,
        .sequence = 0, // Storage engine will assign actual sequence
        .source_uri = "test://regression.zig",
        .metadata_json = "{}",
        .content = content_suffix,
    };
}

/// Create a test edge between two blocks
fn create_test_edge(source: BlockId, target: BlockId, edge_type: EdgeType) GraphEdge {
    return GraphEdge{
        .source_id = source,
        .target_id = target,
        .edge_type = edge_type,
    };
}

test "regression: edge loss during memtable flush" {
    const allocator = testing.allocator;

    // Use a minimal operation mix to focus on the specific flush scenario
    const operation_mix = OperationMix{
        .put_block_weight = 0,
        .find_block_weight = 0,
        .delete_block_weight = 0,
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0xDEADBEEF, // Deterministic seed for reproducibility
        operation_mix,
        &.{}, // No fault injection for this regression test
    );
    defer runner.deinit();

    // Configure small memtable to force flushes easily
    runner.flush_config.memory_threshold = 4 * 1024; // 4KB threshold
    runner.flush_config.enable_memory_trigger = true;

    // Phase 1: Add initial blocks that will be referenced by edges
    const block1_id = BlockId.from_u64(1);
    const block2_id = BlockId.from_u64(2);
    const block3_id = BlockId.from_u64(3);

    const test_block1 = create_test_block(block1_id, "function authenticate_user() { }");
    const test_block2 = create_test_block(block2_id, "function validate_token() { }");
    const test_block3 = create_test_block(block3_id, "function main() { authenticate_user(); }");

    try runner.storage_engine.put_block(test_block1);
    try runner.storage_engine.put_block(test_block2);
    try runner.storage_engine.put_block(test_block3);

    // Phase 2: Add edges representing code relationships
    const edge1 = create_test_edge(block3_id, block1_id, EdgeType.calls); // main calls authenticate_user
    const edge2 = create_test_edge(block1_id, block2_id, EdgeType.calls); // authenticate_user calls validate_token

    try runner.storage_engine.put_edge(edge1);
    try runner.storage_engine.put_edge(edge2);

    // Phase 3: Verify edges exist before flush
    const outgoing_before = try runner.storage_engine.find_outgoing_edges(block3_id, .temporary);
    defer if (outgoing_before) |edges| allocator.free(edges);
    try testing.expect(outgoing_before != null);
    try testing.expect(outgoing_before.?.len == 1);
    try testing.expect(outgoing_before.?[0].target_id.eql(block1_id));

    const outgoing_auth_before = try runner.storage_engine.find_outgoing_edges(block1_id, .temporary);
    defer if (outgoing_auth_before) |edges| allocator.free(edges);
    try testing.expect(outgoing_auth_before != null);
    try testing.expect(outgoing_auth_before.?.len == 1);
    try testing.expect(outgoing_auth_before.?[0].target_id.eql(block2_id));

    // Phase 4: Force memtable flush by adding large blocks
    // Add enough data to exceed the 4KB memory threshold
    var flush_counter: u32 = 0;
    while (flush_counter < 10) : (flush_counter += 1) {
        const large_content = "x" ** 1024; // 1KB per block
        const large_block_id = BlockId.from_u64(1000 + flush_counter);
        const large_block = create_test_block(large_block_id, large_content);
        try runner.storage_engine.put_block(large_block);
    }

    // Force explicit flush to trigger the bug
    try runner.storage_engine.flush_memtable_to_sstable();

    // Phase 5: Verify edges still exist after flush (THIS SHOULD PASS BUT WILL FAIL)
    const outgoing_after = try runner.storage_engine.find_outgoing_edges(block3_id, .temporary);
    defer if (outgoing_after) |edges| allocator.free(edges);

    // The critical assertion: edges must survive memtable flush
    try testing.expect(outgoing_after != null);
    try testing.expect(outgoing_after.?.len == 1);
    try testing.expect(outgoing_after.?[0].target_id.eql(block1_id));

    const outgoing_auth_after = try runner.storage_engine.find_outgoing_edges(block1_id, .temporary);
    defer if (outgoing_auth_after) |edges| allocator.free(edges);
    try testing.expect(outgoing_auth_after != null);
    try testing.expect(outgoing_auth_after.?.len == 1);
    try testing.expect(outgoing_auth_after.?[0].target_id.eql(block2_id));
}
