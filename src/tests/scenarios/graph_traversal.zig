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
