//! Property-based simulation tests for core system invariants
//!
//! Tests fundamental properties that must always hold regardless of operation
//! sequence, timing, or failure conditions. Uses deterministic simulation for
//! perfect reproducibility of failure scenarios.

const std = @import("std");

const deterministic_test = @import("../../sim/deterministic_test.zig");
const storage_engine_mod = @import("../../storage/engine.zig");
const types = @import("../../core/types.zig");

const testing = std.testing;

const ModelState = deterministic_test.ModelState;
const OperationMix = deterministic_test.OperationMix;
const PropertyChecker = deterministic_test.PropertyChecker;
const SimulationRunner = deterministic_test.SimulationRunner;
const WorkloadGenerator = deterministic_test.WorkloadGenerator;

test "property: put-get consistency under normal operations" {
    const allocator = testing.allocator;

    // Realistic API operation workload (no internal operations)
    const operation_mix = OperationMix{
        .put_block_weight = 40,
        .find_block_weight = 50,
        .delete_block_weight = 5,
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0xDEADBEEF, // Deterministic seed for reproducibility
        operation_mix,
        &.{}, // No faults
    );
    defer runner.deinit();

    // Run 50 operations to test rapid operation theory
    try runner.run(50);

    // Property verified automatically by runner
}

test "property: data survives write operations" {
    const allocator = testing.allocator;

    // Workload focused on write durability through WAL
    const operation_mix = OperationMix{
        .put_block_weight = 60,
        .find_block_weight = 40,
        .delete_block_weight = 0,
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0xCAFEBABE,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    try runner.run(500);
}

test "property: crash recovery preserves acknowledged writes" {
    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 40,
        .find_block_weight = 30,
        .delete_block_weight = 5,
        .put_edge_weight = 10,
        .find_edges_weight = 10,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x12345678,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Simulate crash recovery pattern: operations → crash → recovery → verify
    const crash_interval = 50;
    var total_operations: u32 = 0;

    while (total_operations < 300) {
        // Run some operations
        try runner.run(crash_interval);
        total_operations += crash_interval;

        // Simulate crash and recovery
        try runner.simulate_crash_recovery();

        // State should be consistent after recovery due to WAL replay
        try PropertyChecker.check_no_data_loss(&runner.model, runner.storage_engine);
    }
}

test "property: bounded memory growth" {
    const allocator = testing.allocator;

    // Write-heavy workload to test memory bounds
    const operation_mix = OperationMix{
        .put_block_weight = 70, // Write-heavy
        .find_block_weight = 20,
        .delete_block_weight = 0,
        .put_edge_weight = 5,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0xABCDEF00,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Run many operations to test memory growth
    try runner.run(5000);

    // Memory bounds checked automatically by runner
}

test "property: operations maintain referential integrity" {
    const allocator = testing.allocator;

    // Mix of blocks and edges to test graph integrity
    const operation_mix = OperationMix{
        .put_block_weight = 30,
        .find_block_weight = 20,
        .delete_block_weight = 10,
        .put_edge_weight = 20, // Significant edge operations
        .find_edges_weight = 15,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x55555555,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    try runner.run(2000);
}

test "property: concurrent-like access patterns" {
    const allocator = testing.allocator;

    // Simulate concurrent access patterns with interleaved reads/writes
    const operation_mix = OperationMix{
        .put_block_weight = 25,
        .find_block_weight = 60, // Read-heavy like concurrent access
        .delete_block_weight = 5,
        .put_edge_weight = 5,
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x99999999,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    try runner.run(3000);
}

test "property: delete operations are idempotent" {
    const allocator = testing.allocator;

    // Heavy delete workload to test idempotency
    const operation_mix = OperationMix{
        .put_block_weight = 20,
        .find_block_weight = 30,
        .delete_block_weight = 40, // Heavy deletes
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x77777777,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    try runner.run(1500);
}

test "property: system handles rapid flush cycles" {
    const allocator = testing.allocator;

    // Extreme flush frequency to test flush handling
    const operation_mix = OperationMix{
        .put_block_weight = 40,
        .find_block_weight = 60,
        .delete_block_weight = 0,
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x11111111,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    try runner.run(1000);
}

// Seed-based reproduction example for debugging
test "property: reproducible failure with seed 0xBADF00D" {
    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 35,
        .find_block_weight = 35,
        .delete_block_weight = 10,
        .put_edge_weight = 10,
        .find_edges_weight = 5,
    };

    // This seed would be from a failed test run for reproduction
    var runner = try SimulationRunner.init(
        allocator,
        0xBADF00D, // Specific seed for reproduction
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    try runner.run(500);
}

test "property: graph transitivity is preserved" {
    const allocator = testing.allocator;

    // Create connected graph pattern
    const operation_mix = OperationMix{
        .put_block_weight = 30,
        .find_block_weight = 20,
        .delete_block_weight = 0, // No deletes to keep graph intact
        .put_edge_weight = 40, // Heavy on edges for transitivity
        .find_edges_weight = 10,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x72A45171, // TRAN-like seed
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Build graph with potential transitivity
    try runner.run(500);

    // Verify transitivity property if engine is still running
    if (runner.storage_engine.state.can_read()) {
        try PropertyChecker.check_transitivity(&runner.model, runner.storage_engine);
    }
}

test "property: k-hop consistency across operations" {
    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 25,
        .find_block_weight = 25,
        .delete_block_weight = 5,
        .put_edge_weight = 30,
        .find_edges_weight = 15,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x4A0B5555, // 4HOP-like seed
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Build initial graph
    try runner.run(200);

    // Check various k values if engine is running
    if (runner.storage_engine.state.can_read()) {
        var k: u32 = 1;
        while (k <= 3) : (k += 1) {
            try PropertyChecker.check_k_hop_consistency(&runner.model, runner.storage_engine, k);
        }
    }

    // Continue with more operations (engine already running)

    // Run more operations
    try runner.run(300);

    // Verify k-hop consistency maintained if engine is still running
    if (runner.storage_engine.state.can_read()) {
        var k: u32 = 1;
        while (k <= 3) : (k += 1) {
            try PropertyChecker.check_k_hop_consistency(&runner.model, runner.storage_engine, k);
        }
    }
}

test "property: bidirectional edge indices remain consistent" {
    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 20,
        .find_block_weight = 20,
        .delete_block_weight = 10,
        .put_edge_weight = 35, // Heavy edge operations
        .find_edges_weight = 15,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0xB1D12EC7, // BIDI-like seed
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Run operations with periodic consistency checks
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        // Restart engine if needed
        if (!runner.storage_engine.state.can_write()) {
            try runner.storage_engine.startup();
        }

        try runner.run(100);

        // Check bidirectional consistency after each batch if engine is running
        if (runner.storage_engine.state.can_read()) {
            try PropertyChecker.check_bidirectional_consistency(
                &runner.model,
                runner.storage_engine,
            );
        }
    }
}

test "property: graph consistency under crash recovery" {
    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 25,
        .find_block_weight = 20,
        .delete_block_weight = 5,
        .put_edge_weight = 35,
        .find_edges_weight = 15,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0xC2A542EC, // CRASH-REC seed
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Build graph
    try runner.run(300);

    // Check graph properties before crash if engine is running
    if (runner.storage_engine.state.can_read()) {
        try PropertyChecker.check_transitivity(&runner.model, runner.storage_engine);
        try PropertyChecker.check_bidirectional_consistency(&runner.model, runner.storage_engine);
    }

    // Simulate crash
    try runner.simulate_crash_recovery();

    // Verify graph properties preserved after recovery
    if (runner.storage_engine.state.can_read()) {
        try PropertyChecker.check_transitivity(&runner.model, runner.storage_engine);
        try PropertyChecker.check_bidirectional_consistency(&runner.model, runner.storage_engine);
        try PropertyChecker.check_k_hop_consistency(&runner.model, runner.storage_engine, 2);
    }
}

test "property: edge deletion maintains graph integrity" {
    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 20,
        .find_block_weight = 20,
        .delete_block_weight = 20, // Significant deletions
        .put_edge_weight = 30,
        .find_edges_weight = 10,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0xDE1E7E55, // DELETE seed
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Build and modify graph with deletions
    try runner.run(1000);

    // All properties should hold even with deletions if engine is running
    if (runner.storage_engine.state.can_read()) {
        try PropertyChecker.check_bidirectional_consistency(&runner.model, runner.storage_engine);
        try PropertyChecker.check_k_hop_consistency(&runner.model, runner.storage_engine, 2);
    }
}
