//! Edge persistence validation across memtable flush operations.
//!
//! These scenario tests ensure graph edges maintain consistency and durability
//! through LSM-tree flush cycles, validating the bidirectional edge index
//! survives storage layer transitions correctly.

const std = @import("std");
const testing = std.testing;

const harness = @import("../../testing/harness.zig");
const types = @import("../../core/types.zig");

const OperationMix = harness.OperationMix;
const SimulationRunner = harness.SimulationRunner;
const BlockId = types.BlockId;
const EdgeType = types.EdgeType;

test "scenario: edge persistence across memtable flush cycles" {
    const allocator = testing.allocator;

    // Edge-heavy workload to stress persistence mechanisms
    const operation_mix = OperationMix{
        .put_block_weight = 40,
        .find_block_weight = 20,
        .delete_block_weight = 0, // No deletions for basic persistence test
        .put_edge_weight = 30,
        .find_edges_weight = 10,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x3001, // Deterministic seed for edge persistence testing
        operation_mix,
        &.{}, // No fault injection for basic correctness
    );
    defer runner.deinit();

    // Configure frequent flushes to test edge durability
    runner.flush_config.operation_threshold = 40;
    runner.flush_config.enable_operation_trigger = true;

    // Execute mixed operations with emphasis on edge creation
    try runner.run(200);

    // Properties validated automatically:
    // - All edges persist after flush
    // - Bidirectional consistency maintained
    // - Edge index matches model state
    try runner.verify_consistency();
}

test "scenario: multiple edge types persist through flush boundaries" {
    const allocator = testing.allocator;

    // Balanced mix emphasizing different edge types
    const operation_mix = OperationMix{
        .put_block_weight = 35,
        .find_block_weight = 15,
        .delete_block_weight = 5,
        .put_edge_weight = 35, // High edge creation rate
        .find_edges_weight = 10,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x3002,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Configure workload to use all edge types
    runner.workload_config.use_all_edge_types = true;

    // Aggressive flush schedule to test all edge types
    runner.flush_config.operation_threshold = 30;
    runner.flush_config.enable_operation_trigger = true;

    // Run operations to create diverse edge relationships
    try runner.run(300);

    // All edge types (imports, calls, defines, references) must persist
    try runner.verify_consistency();
}

test "scenario: edge consistency during block deletion operations" {
    const allocator = testing.allocator;

    // Mixed workload with block deletions to test edge cleanup
    const operation_mix = OperationMix{
        .put_block_weight = 40,
        .find_block_weight = 15,
        .delete_block_weight = 20, // Significant deletion rate
        .put_edge_weight = 20,
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x3003,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    runner.flush_config.operation_threshold = 35;
    runner.flush_config.enable_operation_trigger = true;

    // Run operations to create and delete interconnected blocks
    try runner.run(400);

    // Edge consistency must be maintained despite block deletions
    try runner.verify_consistency();
}

test "scenario: bidirectional edge index consistency under high load" {
    const allocator = testing.allocator;

    // Edge-dominant workload to stress bidirectional index
    const operation_mix = OperationMix{
        .put_block_weight = 30,
        .find_block_weight = 10,
        .delete_block_weight = 10,
        .put_edge_weight = 40, // Very high edge creation rate
        .find_edges_weight = 10,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x3004,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Enable bidirectional validation in queries
    runner.query_config.validate_bidirectional = true;

    // Frequent flushes to test index consistency
    runner.flush_config.operation_threshold = 25;
    runner.flush_config.enable_operation_trigger = true;

    // High-volume edge operations
    try runner.run(500);

    // Bidirectional index must remain consistent
    try runner.verify_consistency();
}

test "scenario: edge persistence through compaction cycles" {
    const allocator = testing.allocator;

    // Write-heavy with edges to trigger compaction
    const operation_mix = OperationMix{
        .put_block_weight = 50,
        .find_block_weight = 10,
        .delete_block_weight = 5,
        .put_edge_weight = 30,
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x3005,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Aggressive flush to create multiple SSTables for compaction
    runner.flush_config.operation_threshold = 20;
    runner.flush_config.enable_operation_trigger = true;

    // Extended run to trigger compaction with edges
    try runner.run(600);

    // Edges must survive compaction correctly
    try runner.verify_consistency();
}

test "scenario: complex graph topology persistence" {
    const allocator = testing.allocator;

    // Workload designed to create complex graph structures
    const operation_mix = OperationMix{
        .put_block_weight = 35,
        .find_block_weight = 15,
        .delete_block_weight = 10,
        .put_edge_weight = 35,
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x3006,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Configure workload for complex topology
    runner.workload_config.allow_cycles = true;
    runner.workload_config.create_hub_nodes = true;
    runner.workload_config.target_fan_out = 5;

    runner.flush_config.operation_threshold = 40;
    runner.flush_config.enable_operation_trigger = true;

    // Create complex graph structure
    try runner.run(450);

    // Complex topologies must maintain consistency
    try runner.verify_consistency();
}

test "scenario: edge operations under memory pressure simulation" {
    const allocator = testing.allocator;

    // High-frequency operations to simulate memory pressure
    const operation_mix = OperationMix{
        .put_block_weight = 25,
        .find_block_weight = 15,
        .delete_block_weight = 15,
        .put_edge_weight = 35,
        .find_edges_weight = 10,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x3007,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Small flush threshold to simulate memory pressure
    runner.flush_config.operation_threshold = 15;
    runner.flush_config.enable_operation_trigger = true;
    runner.flush_config.enable_memory_trigger = true;

    // High-volume operations under pressure
    try runner.run(700);

    // Edge consistency must be maintained under pressure
    try runner.verify_consistency();
}

test "scenario: edge traversal consistency during flush operations" {
    const allocator = testing.allocator;

    // Query-heavy workload to test traversal during flushes
    const operation_mix = OperationMix{
        .put_block_weight = 30,
        .find_block_weight = 25, // High query rate
        .delete_block_weight = 5,
        .put_edge_weight = 25,
        .find_edges_weight = 15, // High edge query rate
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x3008,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Enable depth testing for traversals
    runner.query_config.enable_depth_testing = true;
    runner.query_config.max_traversal_depth = 5;

    runner.flush_config.operation_threshold = 30;
    runner.flush_config.enable_operation_trigger = true;

    // Mixed read/write operations
    try runner.run(350);

    // Traversal results must be consistent across flushes
    try runner.verify_consistency();
}
