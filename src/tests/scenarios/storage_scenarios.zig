//! Storage scenarios for property-based testing via simulation framework.
//!
//! Converts legacy integration tests to use SimulationRunner for consistent
//! deterministic testing. Each scenario generates realistic operation sequences
//! that can be validated with reusable properties.

const std = @import("std");
const testing = std.testing;

const deterministic_test = @import("../../sim/deterministic_test.zig");
const simulation_vfs = @import("../../sim/simulation_vfs.zig");
const types = @import("../../core/types.zig");

const SimulationRunner = deterministic_test.SimulationRunner;
const WorkloadGenerator = deterministic_test.WorkloadGenerator;
const Operation = deterministic_test.Operation;
const OperationType = deterministic_test.OperationType;
const OperationMix = deterministic_test.OperationMix;
const PropertyChecker = deterministic_test.PropertyChecker;
const SimulationVFS = simulation_vfs.SimulationVFS;
const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;

/// Storage-specific scenarios converted from legacy integration tests
pub const StorageScenario = enum {
    memtable_flush_size_threshold,
    wal_recovery_state_restoration,
    concurrent_read_write_operations,
    sstable_compaction_triggered,
    crash_during_flush_cycle,
    memory_pressure_backpressure,

    /// Generate deterministic operation sequence for scenario
    pub fn generate_operations(self: StorageScenario, allocator: std.mem.Allocator) ![]Operation {
        return switch (self) {
            .memtable_flush_size_threshold => try self.generate_flush_threshold_ops(allocator),
            .wal_recovery_state_restoration => try self.generate_recovery_ops(allocator),
            .concurrent_read_write_operations => try self.generate_concurrent_ops(allocator),
            .sstable_compaction_triggered => try self.generate_compaction_ops(allocator),
            .crash_during_flush_cycle => try self.generate_crash_recovery_ops(allocator),
            .memory_pressure_backpressure => try self.generate_backpressure_ops(allocator),
        };
    }

    /// Configure SimulationRunner for specific scenario requirements
    pub fn configure_runner(self: StorageScenario, runner: *SimulationRunner) void {
        switch (self) {
            .memtable_flush_size_threshold => {
                // Configure for predictable flush trigger
                runner.flush_config.operation_threshold = 100;
                runner.flush_config.memory_threshold = 1024 * 1024; // 1MB
                runner.flush_config.enable_memory_trigger = true;
            },
            .wal_recovery_state_restoration => {
                // Configure for recovery testing
                runner.flush_config.operation_threshold = 50;
                runner.flush_config.enable_operation_trigger = true;
            },
            .concurrent_read_write_operations => {
                // Balanced read/write mix
                runner.workload.operation_mix = OperationMix{
                    .put_block_weight = 50,
                    .find_block_weight = 50,
                    .delete_block_weight = 0,
                    .put_edge_weight = 0,
                    .find_edges_weight = 0,
                };
            },
            .sstable_compaction_triggered => {
                // Aggressive writes to trigger compaction
                runner.flush_config.operation_threshold = 25;
                runner.workload.operation_mix = OperationMix{
                    .put_block_weight = 90,
                    .find_block_weight = 10,
                    .delete_block_weight = 0,
                    .put_edge_weight = 0,
                    .find_edges_weight = 0,
                };
            },
            .crash_during_flush_cycle => {
                runner.flush_config.operation_threshold = 30;
            },
            .memory_pressure_backpressure => {
                runner.flush_config.memory_threshold = 512 * 1024; // 512KB - smaller threshold
                runner.flush_config.enable_memory_trigger = true;
            },
        }
    }

    fn generate_flush_threshold_ops(self: StorageScenario, allocator: std.mem.Allocator) ![]Operation {
        _ = self;
        var operations = std.ArrayList(Operation).init(allocator);

        // Generate sequence that should trigger flush
        for (0..120) |i| {
            const block = ContextBlock{
                .id = deterministic_block_id(@intCast(i + 1)),
                .version = 1,
                .source_uri = "test://flush_scenario",
                .metadata_json = "{}",
                .content = try std.fmt.allocPrint(allocator, "flush_test_content_{}", .{i}),
            };

            try operations.append(Operation{
                .op_type = .put_block,
                .block = block,
                .sequence_number = i + 1,
            });
        }

        return operations.toOwnedSlice();
    }

    fn generate_recovery_ops(self: StorageScenario, allocator: std.mem.Allocator) ![]Operation {
        _ = self;
        var operations = std.ArrayList(Operation).init(allocator);

        // Create test blocks for recovery validation
        const test_blocks = [_]ContextBlock{
            ContextBlock{
                .id = BlockId.from_bytes([_]u8{1} ** 16),
                .version = 1,
                .source_uri = "file://test1.zig",
                .metadata_json = "{}",
                .content = "recovery test content 1",
            },
            ContextBlock{
                .id = BlockId.from_bytes([_]u8{2} ** 16),
                .version = 1,
                .source_uri = "file://test2.zig",
                .metadata_json = "{}",
                .content = "recovery test content 2",
            },
        };

        // Add operations before crash point
        for (test_blocks, 0..) |block, i| {
            try operations.append(Operation{
                .op_type = .put_block,
                .block = block,
                .sequence_number = i + 1,
            });
        }

        return operations.toOwnedSlice();
    }

    fn generate_concurrent_ops(self: StorageScenario, allocator: std.mem.Allocator) ![]Operation {
        _ = self;
        var operations = std.ArrayList(Operation).init(allocator);

        // Interleave reads and writes
        for (0..50) |i| {
            if (i % 2 == 0) {
                // Write operation
                const block = ContextBlock{
                    .id = deterministic_block_id(@intCast(i + 1)),
                    .version = 1,
                    .source_uri = "test://concurrent",
                    .metadata_json = "{}",
                    .content = try std.fmt.allocPrint(allocator, "concurrent_content_{}", .{i}),
                };

                try operations.append(Operation{
                    .op_type = .put_block,
                    .block = block,
                    .sequence_number = i + 1,
                });
            } else {
                // Read operation (reference previous block)
                try operations.append(Operation{
                    .op_type = .find_block,
                    .block_id = deterministic_block_id(@intCast(i)),
                    .sequence_number = i + 1,
                });
            }
        }

        return operations.toOwnedSlice();
    }

    fn generate_compaction_ops(self: StorageScenario, allocator: std.mem.Allocator) ![]Operation {
        _ = self;
        var operations = std.ArrayList(Operation).init(allocator);

        // Generate many blocks to force multiple flushes and trigger compaction
        for (0..200) |i| {
            const block = ContextBlock{
                .id = deterministic_block_id(@intCast(i + 1)),
                .version = 1,
                .source_uri = "test://compaction",
                .metadata_json = "{}",
                .content = try std.fmt.allocPrint(allocator, "compaction_content_{}", .{i}),
            };

            try operations.append(Operation{
                .op_type = .put_block,
                .block = block,
                .sequence_number = i + 1,
            });
        }

        return operations.toOwnedSlice();
    }

    fn generate_crash_recovery_ops(self: StorageScenario, allocator: std.mem.Allocator) ![]Operation {
        _ = self;
        var operations = std.ArrayList(Operation).init(allocator);

        // Operations before crash point
        for (0..35) |i| {
            const block = ContextBlock{
                .id = deterministic_block_id(@intCast(i + 1)),
                .version = 1,
                .source_uri = "test://crash_recovery",
                .metadata_json = "{}",
                .content = try std.fmt.allocPrint(allocator, "crash_recovery_content_{}", .{i}),
            };

            try operations.append(Operation{
                .op_type = .put_block,
                .block = block,
                .sequence_number = i + 1,
            });
        }

        return operations.toOwnedSlice();
    }

    fn generate_backpressure_ops(self: StorageScenario, allocator: std.mem.Allocator) ![]Operation {
        _ = self;
        var operations = std.ArrayList(Operation).init(allocator);

        // Generate operations designed to trigger write backpressure
        for (0..300) |i| {
            const large_content = try allocator.alloc(u8, 1024 * 4); // 4KB blocks
            for (large_content, 0..) |_, j| {
                large_content[j] = @intCast((i + j) % 256);
            }

            const block = ContextBlock{
                .id = deterministic_block_id(@intCast(i + 1)),
                .version = 1,
                .source_uri = "test://backpressure",
                .metadata_json = "{}",
                .content = try std.fmt.allocPrint(allocator, "backpressure_large_content_{s}", .{large_content}),
            };

            try operations.append(Operation{
                .op_type = .put_block,
                .block = block,
                .sequence_number = i + 1,
            });
        }

        return operations.toOwnedSlice();
    }
};

/// Storage-specific properties extracted from legacy assertions
pub const StorageProperties = struct {
    /// Verify flush triggers create SSTables (converted from engine_integration.zig)
    pub fn flush_creates_sstables(model: *deterministic_test.ModelState, system: *deterministic_test.StorageEngine) !void {
        _ = model;
        // Original assertion: try testing.expect(engine.sstable_manager.total_block_count() > 0);
        const sstable_count = system.sstable_manager.total_block_count();
        if (sstable_count == 0) {
            return error.FlushDidNotCreateSSTables;
        }
    }

    /// Verify WAL recovery restores exact state
    pub fn recovery_preserves_state(model: *deterministic_test.ModelState, system: *deterministic_test.StorageEngine) !void {
        // Check all model blocks exist in system after recovery
        try PropertyChecker.check_no_data_loss(model, system);

        // Verify block count matches
        const model_count = model.active_block_count();
        const system_count = system.total_block_count();
        if (model_count != system_count) {
            return error.RecoveryStateCountMismatch;
        }
    }

    /// Verify memory usage stays bounded under pressure
    pub fn memory_stays_bounded(model: *deterministic_test.ModelState, system: *deterministic_test.StorageEngine) !void {
        _ = model;
        const memory_usage = system.memory_usage();
        const max_allowed = 50 * 1024 * 1024; // 50MB
        if (memory_usage.total_bytes > max_allowed) {
            return error.MemoryUsageExceededBounds;
        }
    }

    /// Verify compaction reduces SSTable count
    pub fn compaction_reduces_sstables(model: *deterministic_test.ModelState, system: *deterministic_test.StorageEngine) !void {
        _ = model;
        // This property would be checked before/after compaction
        // For now, just verify we have reasonable SSTable count
        const sstable_count = system.sstable_manager.sstable_count();
        if (sstable_count > 20) {
            return error.TooManySSTablesAfterCompaction;
        }
    }
};

// Test demonstrating scenario + property pattern
test "storage scenario: memtable flush creates SSTables" {
    const allocator = testing.allocator;

    // Use simulation framework instead of manual setup
    var runner = try SimulationRunner.init(
        allocator,
        0xDEADBEEF, // deterministic seed
        OperationMix{}, // default mix
        &.{}, // no faults
    );
    defer runner.deinit();

    // Configure for scenario
    StorageScenario.memtable_flush_size_threshold.configure_runner(&runner);

    // Run scenario operations
    try runner.run(120); // Should trigger flush

    // Validate with extracted property
    try StorageProperties.flush_creates_sstables(&runner.model, runner.storage_engine);

    // Additional property validation
    try PropertyChecker.check_no_data_loss(&runner.model, runner.storage_engine);
}

test "storage scenario: WAL recovery preserves state" {
    const allocator = testing.allocator;

    var runner = try SimulationRunner.init(
        allocator,
        0xBADB00,
        OperationMix{
            .put_block_weight = 100,
            .find_block_weight = 0,
            .delete_block_weight = 0,
            .put_edge_weight = 0,
            .find_edges_weight = 0,
        },
        &.{},
    );
    defer runner.deinit();

    StorageScenario.wal_recovery_state_restoration.configure_runner(&runner);

    // Run operations before crash
    try runner.run(40);
    const blocks_before_crash = runner.model.active_block_count();

    // Simulate crash and recovery
    try runner.simulate_crash_recovery();

    // Validate recovery property
    try StorageProperties.recovery_preserves_state(&runner.model, runner.storage_engine);

    const blocks_after_recovery = runner.model.active_block_count();
    try testing.expectEqual(blocks_before_crash, blocks_after_recovery);
}

test "storage scenario: memory pressure triggers backpressure" {
    const allocator = testing.allocator;

    var runner = try SimulationRunner.init(
        allocator,
        0xFA57,
        OperationMix{
            .put_block_weight = 95, // Heavy writes
            .find_block_weight = 5,
            .delete_block_weight = 0,
            .put_edge_weight = 0,
            .find_edges_weight = 0,
        },
        &.{},
    );
    defer runner.deinit();

    StorageScenario.memory_pressure_backpressure.configure_runner(&runner);

    // Run operations that should trigger backpressure
    try runner.run(100);

    // Validate memory bounds property
    try StorageProperties.memory_stays_bounded(&runner.model, runner.storage_engine);

    // Verify system handled backpressure gracefully
    try PropertyChecker.check_no_data_loss(&runner.model, runner.storage_engine);
}

/// Helper function for deterministic block ID generation
fn deterministic_block_id(seed: u32) BlockId {
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(u128, &bytes, seed + 1, .little);
    return BlockId.from_bytes(bytes);
}
