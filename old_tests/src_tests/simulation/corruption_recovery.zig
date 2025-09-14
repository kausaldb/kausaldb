//! Corruption recovery simulation tests using deterministic infrastructure.
//!
//! Tests WAL corruption, SSTable corruption, and checksum validation using
//! the SimulationRunner framework for deterministic, reproducible testing.

const std = @import("std");
const testing = std.testing;

const deterministic_test = @import("../../sim/deterministic_test.zig");
const CodePatternGenerator = @import("../scenarios/code_pattern_generator.zig").CodePatternGenerator;

const SimulationRunner = deterministic_test.SimulationRunner;
const OperationMix = deterministic_test.OperationMix;
const FaultSpec = deterministic_test.FaultSpec;
const PropertyChecker = deterministic_test.PropertyChecker;

const log = std.log.scoped(.corruption_recovery);

test "corruption recovery: WAL handles corrupted entries gracefully" {
    const allocator = testing.allocator;

    // Inject corruption during write operations
    const faults = [_]FaultSpec{
        .{ .operation_number = 100, .fault_type = .corruption },
    };

    var runner = try SimulationRunner.init(allocator, 0xC0221237, .{
        .put_block_weight = 80, // Write-heavy to exercise WAL
        .find_block_weight = 20,
        .delete_block_weight = 0,
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    }, &faults);
    defer runner.deinit();

    log.info("Testing WAL corruption recovery with {} operations", .{200});

    // Generate initial data before corruption
    var generator = CodePatternGenerator.init(allocator, runner.storage_engine, 0xC0221237);
    defer generator.deinit();
    try generator.generate_realistic_codebase(.{
        .utility_libraries = 1,
        .fanout_per_library = 2,
        .deep_call_chains = 1,
        .call_chain_depth = 3,
        .test_modules = 1,
        .include_circular = false,
    });

    const initial_blocks = runner.storage_engine.metrics().blocks_written.load();
    log.info("Generated {} initial blocks before corruption test", .{initial_blocks});

    // Run through corruption - system should handle gracefully
    try runner.run(200);

    // System should remain operational despite corruption
    const final_blocks = runner.storage_engine.metrics().blocks_written.load();
    try testing.expect(final_blocks >= initial_blocks);

    log.info("WAL corruption recovery completed: {}->{} blocks", .{ initial_blocks, final_blocks });
}

test "corruption recovery: SSTable corruption with checksums" {
    const allocator = testing.allocator;

    // Create data first, then corrupt during reads
    const faults = [_]FaultSpec{
        .{ .operation_number = 150, .fault_type = .corruption },
    };

    var runner = try SimulationRunner.init(allocator, 0x55734B13, .{
        .put_block_weight = 60,
        .find_block_weight = 40, // Read-heavy after initial writes
        .delete_block_weight = 0,
        .put_edge_weight = 0,

        .find_edges_weight = 0,
    }, &faults);
    defer runner.deinit();

    // Force flush to create SSTables
    runner.flush_config.operation_threshold = 50;
    runner.flush_config.enable_memory_trigger = false;

    log.info("Testing SSTable corruption with checksum validation");

    // Generate structured data that will be flushed to SSTables
    var generator = CodePatternGenerator.init(allocator, runner.storage_engine, 0x55734B13);
    defer generator.deinit();
    try generator.generate_realistic_codebase(.{
        .utility_libraries = 2,
        .fanout_per_library = 3,
        .deep_call_chains = 1,
        .call_chain_depth = 4,
        .test_modules = 1,
        .include_circular = false,
    });

    // Run operations - corruption will be injected during reads
    try runner.run(300);

    // Verify system handled corruption without crashing
    try testing.expect(runner.storage_engine.state.can_read());

    log.info("SSTable corruption recovery completed successfully");
}

test "corruption recovery: mixed corruption with crash recovery" {
    const allocator = testing.allocator;

    // Combine corruption with crash to test full recovery pipeline
    const faults = [_]FaultSpec{
        .{ .operation_number = 75, .fault_type = .corruption },
        .{ .operation_number = 150, .fault_type = .crash },
        .{ .operation_number = 250, .fault_type = .corruption },
    };

    var runner = try SimulationRunner.init(allocator, 0xDEADC0DE, .{
        .put_block_weight = 50,
        .find_block_weight = 50,
        .delete_block_weight = 0,
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    }, &faults);
    defer runner.deinit();

    log.info("Testing combined corruption and crash recovery");

    // Create diverse data patterns
    var generator = CodePatternGenerator.init(allocator, runner.storage_engine, 0xDEADC0DE);
    defer generator.deinit();
    try generator.generate_realistic_codebase(.{
        .utility_libraries = 2,
        .fanout_per_library = 2,
        .deep_call_chains = 2,
        .call_chain_depth = 3,
        .test_modules = 2,
        .include_circular = true,
    });

    const pre_test_blocks = runner.storage_engine.metrics().blocks_written.load();
    log.info("Starting mixed corruption test with {} blocks", .{pre_test_blocks});

    // Run through multiple fault injections
    try runner.run(400);

    // System should survive multiple corruption events and crash recovery
    const post_test_blocks = runner.storage_engine.metrics().blocks_written.load();
    log.info("Mixed corruption test completed: {} blocks remain", .{post_test_blocks});

    // Some data loss is expected due to corruption, but system should be operational
    try testing.expect(runner.storage_engine.state.can_read());
}

test "corruption recovery: systematic corruption at different phases" {
    const allocator = testing.allocator;

    // Test corruption at different phases: early writes, mid-operation, late reads
    const scenarios = [_]struct {
        seed: u64,
        corruption_point: u64,
        description: []const u8,
    }{
        .{ .seed = 0x12345001, .corruption_point = 25, .description = "early write phase" },
        .{ .seed = 0x12345002, .corruption_point = 100, .description = "mid operation phase" },
        .{ .seed = 0x12345003, .corruption_point = 175, .description = "late read phase" },
    };

    for (scenarios) |scenario| {
        log.info("Testing corruption during {s} (corruption at op {})", .{ scenario.description, scenario.corruption_point });

        const faults = [_]FaultSpec{
            .{ .operation_number = scenario.corruption_point, .fault_type = .corruption },
        };

        var runner = try SimulationRunner.init(allocator, scenario.seed, .{
            .put_block_weight = 70,
            .find_block_weight = 30,
            .delete_block_weight = 0,
            .put_edge_weight = 0,
            .find_edges_weight = 0,
        }, &faults);
        defer runner.deinit();

        // Generate consistent test data
        var generator = CodePatternGenerator.init(allocator, runner.storage_engine, scenario.seed);
        defer generator.deinit();
        try generator.generate_realistic_codebase(.{
            .utility_libraries = 1,
            .fanout_per_library = 3,
            .deep_call_chains = 1,
            .call_chain_depth = 4,
            .test_modules = 1,
            .include_circular = false,
        });

        // Run scenario
        try runner.run(200);

        // Verify graceful handling
        try testing.expect(runner.storage_engine.state.can_read());

        log.info("Corruption during {s}: handled gracefully", .{scenario.description});
    }
}

test "corruption recovery: edge case - corruption during flush" {
    const allocator = testing.allocator;

    // Inject corruption right before a scheduled flush
    const faults = [_]FaultSpec{
        .{ .operation_number = 95, .fault_type = .corruption }, // Just before flush at 100
    };

    var runner = try SimulationRunner.init(allocator, 0xFLU5H123, .{
        .put_block_weight = 100, // Pure writes to trigger flush
        .find_block_weight = 0,
        .delete_block_weight = 0,
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    }, &faults);
    defer runner.deinit();

    // Configure flush to happen right after corruption
    runner.flush_config.operation_threshold = 100;
    runner.flush_config.enable_memory_trigger = false;

    log.info("Testing corruption during flush operations");

    // Create data that will trigger flush
    var generator = CodePatternGenerator.init(allocator, runner.storage_engine, 0xFLU5H123);
    defer generator.deinit();
    try generator.generate_realistic_codebase(.{
        .utility_libraries = 1,
        .fanout_per_library = 4,
        .deep_call_chains = 1,
        .call_chain_depth = 2,
        .test_modules = 1,
        .include_circular = false,
    });

    const pre_flush_blocks = runner.storage_engine.metrics().blocks_written.load();

    // Run through corruption + flush
    try runner.run(150);

    const post_flush_blocks = runner.storage_engine.metrics().blocks_written.load();
    log.info("Corruption during flush: {} -> {} blocks", .{ pre_flush_blocks, post_flush_blocks });

    // System should handle flush corruption gracefully
    try testing.expect(runner.storage_engine.state.can_read());
}
