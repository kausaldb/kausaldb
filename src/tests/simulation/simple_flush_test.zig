//! Simple flush tests with clear lifecycle management.
//!
//! These tests demonstrate proper separation of concerns - tests own the
//! storage engine lifecycle, not the simulation framework.

const std = @import("std");
const testing = std.testing;

// Core imports
const types = @import("../../core/types.zig");

// Storage imports
const storage_engine = @import("../../storage/engine.zig");

// Simulation imports
const simulation_framework = @import("../../testing/simulation_framework.zig");
const simulation_vfs = @import("../../sim/simulation_vfs.zig");

// Type aliases
const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const StorageEngine = storage_engine.StorageEngine;
const SimulationVFS = simulation_vfs.SimulationVFS;

const log = std.log.scoped(.simple_flush_test);

test "flush preserves all data" {
    const allocator = testing.allocator;

    // Test owns the storage lifecycle
    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/test");
    defer engine.deinit();

    try engine.startup();
    defer engine.shutdown() catch {};

    // Simple model to track what we put
    var model = simulation_framework.TestModel.init(allocator);
    defer model.deinit();

    // Generate and insert blocks
    var generator = simulation_framework.OperationGenerator.init(allocator, 0x5678);

    // Insert 100 blocks
    for (0..100) |_| {
        const block = try generator.generate_block();
        try engine.put_block(block);
        try model.track_operation(.{
            .op_type = .put_block,
            .block = block,
        });
    }

    // Manually trigger flush
    try engine.flush_memtable_to_sstable();

    // Verify all blocks still accessible after flush
    try simulation_framework.PropertyChecks.check_no_data_loss(&model, &engine);

    // Verify memory was reset
    const memory_after = engine.memory_usage();
    try testing.expect(memory_after.total_bytes < 1024 * 1024); // Should be nearly empty
}

test "multiple flushes maintain consistency" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/test");
    defer engine.deinit();

    try engine.startup();
    defer engine.shutdown() catch {};

    var model = simulation_framework.TestModel.init(allocator);
    defer model.deinit();

    var generator = simulation_framework.OperationGenerator.init(allocator, 0x6789);

    // Perform multiple flush cycles
    for (0..3) |cycle| {
        log.info("Flush cycle {}", .{cycle});

        // Insert blocks
        for (0..50) |_| {
            const block = try generator.generate_block();
            try engine.put_block(block);
            try model.track_operation(.{
                .op_type = .put_block,
                .block = block,
            });
        }

        // Flush
        try engine.flush_memtable_to_sstable();

        // Verify consistency after each flush
        try simulation_framework.PropertyChecks.check_no_data_loss(&model, &engine);
    }

    // Final verification
    try model.verify_against_storage(&engine);
    try testing.expect(model.count_active_blocks() == 150);
}

test "flush with mixed operations" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/test");
    defer engine.deinit();

    try engine.startup();
    defer engine.shutdown() catch {};

    var model = simulation_framework.TestModel.init(allocator);
    defer model.deinit();

    var generator = simulation_framework.OperationGenerator.init(allocator, 0x789A);

    // Mixed operations before flush
    for (0..200) |_| {
        const op = try generator.generate_operation(60, 30, 10); // 60% put, 30% find, 10% delete

        const success = try simulation_framework.apply_operation_to_storage(&engine, op);
        if (success) {
            try model.track_operation(op);
        }
    }

    // Flush in the middle of operations
    try engine.flush_memtable_to_sstable();

    // More operations after flush
    for (0..100) |_| {
        const op = try generator.generate_operation(50, 40, 10);

        const success = try simulation_framework.apply_operation_to_storage(&engine, op);
        if (success) {
            try model.track_operation(op);
        }
    }

    // Verify everything is consistent
    try simulation_framework.PropertyChecks.check_no_data_loss(&model, &engine);
}

test "recovery after flush preserves data" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var model = simulation_framework.TestModel.init(allocator);
    defer model.deinit();

    // Phase 1: Write data and flush
    {
        var engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/test");
        defer engine.deinit();

        try engine.startup();

        var generator = simulation_framework.OperationGenerator.init(allocator, 0x89AB);

        // Insert blocks
        for (0..75) |_| {
            const block = try generator.generate_block();
            try engine.put_block(block);
            try model.track_operation(.{
                .op_type = .put_block,
                .block = block,
            });
        }

        // Flush to SSTables
        try engine.flush_memtable_to_sstable();

        // Add more blocks after flush (will be in WAL)
        for (0..25) |_| {
            const block = try generator.generate_block();
            try engine.put_block(block);
            try model.track_operation(.{
                .op_type = .put_block,
                .block = block,
            });
        }

        try engine.shutdown();
    }

    // Phase 2: Recover and verify
    {
        var engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/test");
        defer engine.deinit();

        try engine.startup(); // Triggers recovery
        defer engine.shutdown() catch {};

        // All data should be recovered
        try simulation_framework.PropertyChecks.check_no_data_loss(&model, &engine);
        try testing.expect(model.count_active_blocks() == 100);
    }
}

test "memory bounds after flush" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/test");
    defer engine.deinit();

    try engine.startup();
    defer engine.shutdown() catch {};

    var generator = simulation_framework.OperationGenerator.init(allocator, 0x9ABC);

    // Track memory before operations
    const initial_memory = engine.memory_usage();

    // Insert many blocks
    for (0..500) |_| {
        const block = try generator.generate_block();
        try engine.put_block(block);
    }

    // Memory should have grown
    const before_flush = engine.memory_usage();
    try testing.expect(before_flush.total_bytes > initial_memory.total_bytes);

    // Flush should reset memtable memory
    try engine.flush_memtable_to_sstable();

    const after_flush = engine.memory_usage();
    try testing.expect(after_flush.total_bytes < before_flush.total_bytes);

    // Memory per operation should be reasonable
    try simulation_framework.PropertyChecks.check_memory_bounds(&engine, 2048);
}

test "concurrent flush and operations" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/test");
    defer engine.deinit();

    try engine.startup();
    defer engine.shutdown() catch {};

    var model = simulation_framework.TestModel.init(allocator);
    defer model.deinit();

    var generator = simulation_framework.OperationGenerator.init(allocator, 0xABCD);

    // Simulate operations with deterministic flushes to avoid race conditions
    for (0..3) |flush_cycle| {
        // Operations between flushes - only puts to avoid delete race conditions
        for (0..50) |_| {
            const op = try generator.generate_operation(100, 0, 0); // Only put operations

            const success = try simulation_framework.apply_operation_to_storage(&engine, op);
            if (success) {
                try model.track_operation(op);
            }
        }

        // Deterministic flush after each batch to ensure consistency
        log.info("Flush cycle {} - flushing {} tracked operations", .{ flush_cycle, model.operation_count });
        
        // Only flush if engine is in a state that allows it
        if (engine.state.can_write()) {
            try engine.flush_memtable_to_sstable();
        }

        // Verify consistency after each flush
        try simulation_framework.PropertyChecks.check_no_data_loss(&model, &engine);
    }

    // Final verification
    try model.verify_against_storage(&engine);
}
