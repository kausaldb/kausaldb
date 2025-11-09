//! Graph traversal correctness integration tests for query engine operations.
//!
//! These scenario tests validate graph traversal algorithms against various
//! topology scenarios to ensure correctness under cycles, depth limits,
//! bidirectional relationships, and storage layer transitions.

const std = @import("std");
const testing = std.testing;

const harness = @import("../../testing/harness.zig");
const types = @import("../../core/types.zig");

const OperationMix = harness.OperationMix;
const SimulationRunner = harness.SimulationRunner;
const ContextBlock = types.ContextBlock;
const BlockId = types.BlockId;
const GraphEdge = types.GraphEdge;
const EdgeType = types.EdgeType;

test "scenario: acyclic traversal respects depth limiting correctly" {
    const allocator = testing.allocator;

    // Graph-focused workload to create traversal scenarios
    const operation_mix = OperationMix{
        .put_block_weight = 40,
        .find_block_weight = 30, // High traversal rate
        .delete_block_weight = 0, // No deletions for clean traversal test
        .put_edge_weight = 25,
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x5001, // Deterministic seed for traversal testing
        operation_mix,
        &.{}, // No fault injection for basic correctness
    );
    defer runner.deinit();

    // Configure for depth-limited traversal testing
    runner.query_config.enable_depth_testing = true;
    runner.query_config.max_traversal_depth = 3;

    // Configure frequent flushes to test traversal across storage layers
    runner.flush_config.operation_threshold = 50;
    runner.flush_config.enable_operation_trigger = true;

    // Execute operations to create chain-like graph structures
    try runner.run(200);

    // Properties validated automatically:
    // - Depth limits are respected during traversal
    // - Graph structure remains consistent
    // - Traversal results are deterministic
    try runner.verify_consistency();
}

test "scenario: cyclic traversal terminates correctly without infinite loops" {
    const allocator = testing.allocator;

    // Graph workload with cycle creation
    const operation_mix = OperationMix{
        .put_block_weight = 35,
        .find_block_weight = 35, // High traversal rate for cycle testing
        .delete_block_weight = 0, // Clean cycles without deletions
        .put_edge_weight = 25,
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x5002,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Configure for cycle detection and handling
    runner.workload_config.allow_cycles = true;
    runner.workload_config.create_tight_cycles = true;
    runner.query_config.max_traversal_depth = 10;

    runner.flush_config.operation_threshold = 45;
    runner.flush_config.enable_operation_trigger = true;

    // Execute operations to create cyclic graph structures
    try runner.run(250);

    // Properties validated automatically:
    // - Cycles are detected and handled correctly
    // - No infinite loops during traversal
    // - Each node appears at most once in traversal results
    try runner.verify_consistency();
}

test "scenario: bidirectional traversal finds all incoming relationships correctly" {
    const allocator = testing.allocator;

    // Workload emphasizing bidirectional graph relationships
    const operation_mix = OperationMix{
        .put_block_weight = 30,
        .find_block_weight = 30, // High traversal rate
        .delete_block_weight = 5,
        .put_edge_weight = 30,
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x5003,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Configure for bidirectional validation
    runner.query_config.validate_bidirectional = true;
    runner.workload_config.use_all_edge_types = true;

    runner.flush_config.operation_threshold = 40;
    runner.flush_config.enable_operation_trigger = true;

    // Execute operations to create bidirectional relationships
    try runner.run(300);

    // Properties validated automatically:
    // - Bidirectional consistency maintained
    // - All incoming edges are discoverable
    // - Edge index remains consistent across storage layers
    try runner.verify_consistency();
}

test "scenario: complex graph topology traversal under mixed operations" {
    const allocator = testing.allocator;

    // Complex workload to create diverse graph structures
    const operation_mix = OperationMix{
        .put_block_weight = 30,
        .find_block_weight = 25,
        .delete_block_weight = 15,
        .put_edge_weight = 25,
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x5004,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Configure for complex topology creation
    runner.workload_config.allow_cycles = true;
    runner.workload_config.create_hub_nodes = true;
    runner.workload_config.target_fan_out = 4;
    runner.query_config.max_traversal_depth = 6;

    runner.flush_config.operation_threshold = 35;
    runner.flush_config.enable_operation_trigger = true;

    // Extended run to build complex graph structures
    try runner.run(400);

    // Complex topologies must maintain traversal correctness
    try runner.verify_consistency();
}

test "scenario: traversal performance under high graph density" {
    const allocator = testing.allocator;

    // Edge-heavy workload to create dense graphs
    const operation_mix = OperationMix{
        .put_block_weight = 25,
        .find_block_weight = 20,
        .delete_block_weight = 5,
        .put_edge_weight = 45, // Very high edge density
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x5005,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Configure for high-density graph creation
    runner.workload_config.target_fan_out = 6;
    runner.workload_config.create_hub_nodes = true;
    runner.query_config.max_traversal_depth = 4;

    runner.flush_config.operation_threshold = 30;
    runner.flush_config.enable_operation_trigger = true;

    // High-volume operations to create dense graphs
    try runner.run(500);

    // Dense graphs must maintain traversal efficiency
    try runner.verify_consistency();
}

test "scenario: graph traversal consistency during storage transitions" {
    const allocator = testing.allocator;

    // Query-heavy workload during frequent flushes
    const operation_mix = OperationMix{
        .put_block_weight = 25,
        .find_block_weight = 40, // Very high query rate
        .delete_block_weight = 5,
        .put_edge_weight = 25,
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x5006,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Enable depth testing during transitions
    runner.query_config.enable_depth_testing = true;
    runner.query_config.max_traversal_depth = 5;

    // Very frequent flushes to test traversal during transitions
    runner.flush_config.operation_threshold = 20;
    runner.flush_config.enable_operation_trigger = true;

    // Run with frequent storage transitions
    try runner.run(350);

    // Traversal must remain consistent across storage layer transitions
    try runner.verify_consistency();
}

test "scenario: mixed edge type filtering during traversal operations" {
    const allocator = testing.allocator;

    // Workload designed to create multiple edge types
    const operation_mix = OperationMix{
        .put_block_weight = 35,
        .find_block_weight = 25,
        .delete_block_weight = 5,
        .put_edge_weight = 30,
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x5007,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Configure for all edge types and filtering
    runner.workload_config.use_all_edge_types = true;
    runner.query_config.use_filtering = true;
    runner.query_config.max_traversal_depth = 4;

    runner.flush_config.operation_threshold = 40;
    runner.flush_config.enable_operation_trigger = true;

    // Create diverse edge types for filtering tests
    try runner.run(300);

    // Edge type filtering must work correctly during traversal
    try runner.verify_consistency();
}

test "scenario: traversal result ordering consistency" {
    const allocator = testing.allocator;

    // Workload focused on consistent result ordering
    const operation_mix = OperationMix{
        .put_block_weight = 30,
        .find_block_weight = 35, // High query rate
        .delete_block_weight = 5,
        .put_edge_weight = 25,
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x5008,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Enable result ordering validation
    runner.query_config.validate_result_ordering = true;
    runner.query_config.max_traversal_depth = 3;

    runner.flush_config.operation_threshold = 45;
    runner.flush_config.enable_operation_trigger = true;

    // Test result ordering consistency
    try runner.run(275);

    // Traversal results must maintain consistent ordering
    try runner.verify_consistency();
}

test "scenario: repeated traversal queries maintain consistency" {
    const allocator = testing.allocator;

    // Query repetition workload to test consistency
    const operation_mix = OperationMix{
        .put_block_weight = 25,
        .find_block_weight = 45, // Very high query rate
        .delete_block_weight = 5,
        .put_edge_weight = 20,
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x5009,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Configure for repeated query testing
    runner.query_config.use_repeated_queries = true;
    runner.query_config.query_repetition_rate = 0.3;

    runner.flush_config.operation_threshold = 35;
    runner.flush_config.enable_operation_trigger = true;

    // Test repeated queries for consistency
    try runner.run(325);

    // Repeated queries must return identical results
    try runner.verify_consistency();
}

const storage_mod = @import("../../storage/engine.zig");
const query_mod = @import("../../query/engine.zig");
const simulation_vfs = @import("../../sim/simulation_vfs.zig");

const StorageEngine = storage_mod.StorageEngine;
const QueryEngine = query_mod.QueryEngine;
const SimulationVFS = simulation_vfs.SimulationVFS;

test "scenario: immediate two-node cycle detection" {
    const allocator = testing.allocator;

    var vfs = try SimulationVFS.init(allocator);
    defer vfs.deinit();

    const config = storage_mod.Config{};
    var storage = try StorageEngine.init(allocator, vfs.vfs(), "/test_db", config);
    defer storage.deinit();

    try storage.startup();
    defer storage.shutdown() catch {};

    var query = QueryEngine.init(allocator, &storage);
    defer query.deinit();

    // Create blocks A and B with immediate cycle: A -> B -> A
    const block_a_id = BlockId.from_u64(10);
    const block_b_id = BlockId.from_u64(20);

    const block_a = ContextBlock{
        .id = block_a_id,
        .sequence = 1,
        .source_uri = "test://block_a",
        .metadata_json = "{}",
        .content = "Block A in cycle",
    };
    const block_b = ContextBlock{
        .id = block_b_id,
        .sequence = 2,
        .source_uri = "test://block_b",
        .metadata_json = "{}",
        .content = "Block B in cycle",
    };

    try storage.put_block(block_a);
    try storage.put_block(block_b);

    // Create cycle: A -> B -> A
    try storage.put_edge(GraphEdge{
        .source_id = block_a_id,
        .target_id = block_b_id,
        .edge_type = .calls,
    });
    try storage.put_edge(GraphEdge{
        .source_id = block_b_id,
        .target_id = block_a_id,
        .edge_type = .calls,
    });

    // CRITICAL ASSERTION 1: Traversal terminates even with large depth
    const result = try query.traverse_outgoing(block_a_id, 10);

    // CRITICAL ASSERTION 2: Both nodes appear exactly once (no duplicates)
    try testing.expect(result.blocks.len == 2);

    // Verify both blocks are present (order doesn't matter)
    var found_a = false;
    var found_b = false;
    for (result.blocks) |block| {
        if (block.block.id.eql(block_a_id)) found_a = true;
        if (block.block.id.eql(block_b_id)) found_b = true;
    }
    try testing.expect(found_a and found_b);

    // PROOF COMPLETE: Immediate cycles detected, no infinite loops or duplicates
}

test "scenario: extreme fan-out from hub node" {
    const allocator = testing.allocator;

    var vfs = try SimulationVFS.init(allocator);
    defer vfs.deinit();

    const config = storage_mod.Config{};
    var storage = try StorageEngine.init(allocator, vfs.vfs(), "/test_db", config);
    defer storage.deinit();

    try storage.startup();
    defer storage.shutdown() catch {};

    var query = QueryEngine.init(allocator, &storage);
    defer query.deinit();

    // Create hub node with 200 outbound edges (star topology)
    const hub_id = BlockId.from_u64(1);
    const hub_block = ContextBlock{
        .id = hub_id,
        .sequence = 1,
        .source_uri = "test://hub",
        .metadata_json = "{}",
        .content = "Hub node with high fan-out",
    };
    try storage.put_block(hub_block);

    // Create 200 leaf nodes
    const fan_out_count = 200;
    var i: u64 = 0;
    while (i < fan_out_count) : (i += 1) {
        const leaf_id = BlockId.from_u64(100 + i);
        const leaf_block = ContextBlock{
            .id = leaf_id,
            .sequence = 2 + i,
            .source_uri = "test://leaf",
            .metadata_json = "{}",
            .content = "Leaf node",
        };
        try storage.put_block(leaf_block);

        // Create edge from hub to leaf
        try storage.put_edge(GraphEdge{
            .source_id = hub_id,
            .target_id = leaf_id,
            .edge_type = .calls,
        });
    }

    // CRITICAL ASSERTION 1: Traversal doesn't OOM or crash
    const result = try query.traverse_outgoing(hub_id, 2);

    // CRITICAL ASSERTION 2: All 200 leaf nodes are returned (plus hub = 201 total)
    try testing.expect(result.blocks.len == fan_out_count + 1);

    // PROOF COMPLETE: Extreme fan-out handled without memory exhaustion
}

test "scenario: exact depth boundary behavior" {
    const allocator = testing.allocator;

    var vfs = try SimulationVFS.init(allocator);
    defer vfs.deinit();

    const config = storage_mod.Config{};
    var storage = try StorageEngine.init(allocator, vfs.vfs(), "/test_db", config);
    defer storage.deinit();

    try storage.startup();
    defer storage.shutdown() catch {};

    var query = QueryEngine.init(allocator, &storage);
    defer query.deinit();

    // Create chain: A -> B -> C -> D -> E (4 hops from A)
    const ids = [_]u64{ 1, 2, 3, 4, 5 };
    const names = [_][]const u8{ "A", "B", "C", "D", "E" };

    // Create all blocks
    for (ids, names, 0..) |id, name, seq| {
        const block = ContextBlock{
            .id = BlockId.from_u64(id),
            .sequence = seq,
            .source_uri = "test://chain",
            .metadata_json = "{}",
            .content = name,
        };
        try storage.put_block(block);
    }

    // Create edges: A->B, B->C, C->D, D->E
    for (0..ids.len - 1) |idx| {
        try storage.put_edge(GraphEdge{
            .source_id = BlockId.from_u64(ids[idx]),
            .target_id = BlockId.from_u64(ids[idx + 1]),
            .edge_type = .calls,
        });
    }

    // CRITICAL ASSERTION 1: depth=3 returns A, B, C, D (4 nodes, 3 hops)
    const result_depth_3 = try query.traverse_outgoing(BlockId.from_u64(1), 3);
    try testing.expect(result_depth_3.blocks.len == 4);

    // Verify E is NOT included (requires 4 hops)
    var found_e = false;
    for (result_depth_3.blocks) |block| {
        if (block.block.id.eql(BlockId.from_u64(5))) found_e = true;
    }
    try testing.expect(!found_e);

    // CRITICAL ASSERTION 2: depth=4 returns all 5 nodes
    const result_depth_4 = try query.traverse_outgoing(BlockId.from_u64(1), 4);
    try testing.expect(result_depth_4.blocks.len == 5);

    // PROOF COMPLETE: Depth boundaries are exact (off-by-one would fail)
}
