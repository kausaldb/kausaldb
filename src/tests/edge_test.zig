//! Simple test to verify edge persistence across memtable flushes.
//!
//! This test creates blocks, adds edges, flushes the memtable, and verifies
//! that edges persist. If this test fails, it indicates the core edge
//! persistence mechanism is broken.

const std = @import("std");
const testing = std.testing;

const engine = @import("../storage/engine.zig");
const types = @import("../core/types.zig");
const vfs = @import("../core/vfs.zig");
const simulation_vfs = @import("../sim/simulation_vfs.zig");

const SimulationVFS = simulation_vfs.SimulationVFS;

const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const EdgeType = types.EdgeType;
const GraphEdge = types.GraphEdge;
const StorageEngine = engine.StorageEngine;

test "basic edge persistence across flush" {
    const allocator = testing.allocator;

    // Create temporary test directory
    const test_dir = "/tmp/kausal_edge_test";

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var storage_engine = try StorageEngine.init(allocator, sim_vfs.vfs(), test_dir, .{});
    defer storage_engine.deinit();

    try storage_engine.startup();
    defer storage_engine.shutdown() catch {};

    // Create test blocks
    const block1_id = BlockId.from_u64(1);
    const block2_id = BlockId.from_u64(2);

    const block1 = ContextBlock{
        .id = block1_id,
        .sequence = 0,
        .source_uri = "test://block1.zig",
        .metadata_json = "{}",
        .content = "fn main() { test(); }",
    };

    const block2 = ContextBlock{
        .id = block2_id,
        .sequence = 0,
        .source_uri = "test://block2.zig",
        .metadata_json = "{}",
        .content = "fn test() { return; }",
    };

    // Add blocks to storage
    try storage_engine.put_block(block1);
    try storage_engine.put_block(block2);

    // Create edge: main calls test
    const test_edge = GraphEdge{
        .source_id = block1_id,
        .target_id = block2_id,
        .edge_type = EdgeType.calls,
    };

    // Add edge to storage
    try storage_engine.put_edge(test_edge);

    // Verify edge exists before flush
    const edges_before = storage_engine.find_outgoing_edges(block1_id);
    try testing.expect(edges_before.len == 1);
    try testing.expect(edges_before[0].edge.target_id.eql(block2_id));
    try testing.expect(edges_before[0].edge.edge_type == EdgeType.calls);

    // Force memtable flush
    try storage_engine.flush_memtable_to_sstable();

    // Verify edge still exists after flush
    const edges_after = storage_engine.find_outgoing_edges(block1_id);
    try testing.expect(edges_after.len == 1);
    try testing.expect(edges_after[0].edge.target_id.eql(block2_id));
    try testing.expect(edges_after[0].edge.edge_type == EdgeType.calls);

    // Clean up test directory
    std.fs.cwd().deleteTree(test_dir) catch {};
}

test "multiple edges persistence" {
    const allocator = testing.allocator;

    // Create temporary test directory
    const test_dir = "/tmp/kausal_multi_edge_test";

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var storage_engine = try StorageEngine.init(allocator, sim_vfs.vfs(), test_dir, .{});
    defer storage_engine.deinit();

    try storage_engine.startup();
    defer storage_engine.shutdown() catch {};

    // Create test blocks
    const block1_id = BlockId.from_u64(10);
    const block2_id = BlockId.from_u64(20);
    const block3_id = BlockId.from_u64(30);

    const block1 = ContextBlock{
        .id = block1_id,
        .sequence = 0,
        .source_uri = "test://main.zig",
        .metadata_json = "{}",
        .content = "fn main() { foo(); bar(); }",
    };

    const block2 = ContextBlock{
        .id = block2_id,
        .sequence = 0,
        .source_uri = "test://foo.zig",
        .metadata_json = "{}",
        .content = "fn foo() { return; }",
    };

    const block3 = ContextBlock{
        .id = block3_id,
        .sequence = 0,
        .source_uri = "test://bar.zig",
        .metadata_json = "{}",
        .content = "fn bar() { return; }",
    };

    // Add blocks
    try storage_engine.put_block(block1);
    try storage_engine.put_block(block2);
    try storage_engine.put_block(block3);

    // Create edges: main calls foo and bar
    const edge1 = GraphEdge{
        .source_id = block1_id,
        .target_id = block2_id,
        .edge_type = EdgeType.calls,
    };

    const edge2 = GraphEdge{
        .source_id = block1_id,
        .target_id = block3_id,
        .edge_type = EdgeType.calls,
    };

    // Add edges
    try storage_engine.put_edge(edge1);
    try storage_engine.put_edge(edge2);

    // Verify edges exist before flush
    const edges_before = storage_engine.find_outgoing_edges(block1_id);
    try testing.expect(edges_before.len == 2);

    // Force memtable flush
    try storage_engine.flush_memtable_to_sstable();

    // Verify edges still exist after flush
    const edges_after = storage_engine.find_outgoing_edges(block1_id);
    try testing.expect(edges_after.len == 2);

    // Verify both edges are present (order may vary)
    var found_foo = false;
    var found_bar = false;
    for (edges_after) |owned_edge| {
        if (owned_edge.edge.target_id.eql(block2_id)) found_foo = true;
        if (owned_edge.edge.target_id.eql(block3_id)) found_bar = true;
    }
    try testing.expect(found_foo);
    try testing.expect(found_bar);

    // Clean up test directory
    std.fs.cwd().deleteTree(test_dir) catch {};
}
