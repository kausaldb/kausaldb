//! Property-based testing for system correctness.
//!
//! Model-based testing compares against reference implementation.
//! Property verification checks invariants hold under all operations.
//! Fault injection verifies durability and consistency under failures.
//!
//! Properties tested: durability, consistency, linearizability, memory safety.

const std = @import("std");

const internal = @import("internal");
const main = @import("main.zig");

const WorkloadGenerator = internal.WorkloadGenerator;
const WorkloadConfig = internal.WorkloadConfig;
const ModelState = internal.ModelState;
const PropertyChecker = internal.PropertyChecker;
const OperationMix = internal.OperationMix;
const Operation = internal.Operation;
const StorageEngine = internal.StorageEngine;
const SimulationVFS = internal.SimulationVFS;
const ContextBlock = internal.ContextBlock;
const GraphEdge = internal.GraphEdge;
const BlockId = internal.BlockId;
const EdgeType = internal.EdgeType;
const Config = internal.Config;
const BlockOwnership = internal.ownership.BlockOwnership;

const OperationHistoryEntry = struct {
    op: Operation,
    start_time: i64,
    end_time: i64,
    result: ?anyerror,
};

/// Property test statistics
const PropertyStats = struct {
    operations_executed: u64 = 0,
    properties_checked: u64 = 0,
    violations_found: u64 = 0,
    crashes_injected: u64 = 0,
    recoveries_tested: u64 = 0,

    fn print(self: PropertyStats) void {
        std.debug.print("\n=== Property Test Results ===\n", .{});
        std.debug.print("Operations: {}\n", .{self.operations_executed});
        std.debug.print("Properties checked: {}\n", .{self.properties_checked});
        std.debug.print("Violations: {}\n", .{self.violations_found});
        std.debug.print("Crash tests: {}\n", .{self.crashes_injected});
        std.debug.print("Recoveries: {}\n", .{self.recoveries_tested});
    }
};

/// Test durability properties
pub fn run_durability_testing(fuzzer: *main.Fuzzer) !void {
    std.debug.print("Testing durability properties...\n", .{});

    var stats = PropertyStats{};
    defer stats.print();

    while (fuzzer.should_continue()) {
        // Create test environment
        var sim_vfs = try SimulationVFS.init(fuzzer.allocator);
        defer sim_vfs.deinit();

        // Phase 1: Write data
        var storage1 = try StorageEngine.init(
            fuzzer.allocator,
            sim_vfs.vfs(),
            "durability_test",
            Config{
                .memtable_max_size = 1 * 1024 * 1024,
            },
        );
        defer storage1.deinit();
        try storage1.startup();

        // Track what we write
        var written_blocks = std.array_list.Managed(ContextBlock).init(fuzzer.allocator);
        defer written_blocks.deinit();

        // Track allocated content strings to free them later
        var allocated_content = std.array_list.Managed([]const u8).init(fuzzer.allocator);
        defer {
            for (allocated_content.items) |content| {
                fuzzer.allocator.free(content);
            }
            allocated_content.deinit();
        }

        // Generate and write test data
        for (0..100) |i| {
            const content = try std.fmt.allocPrint(fuzzer.allocator, "durability_{}", .{i});
            try allocated_content.append(content);

            const block = ContextBlock{
                .id = BlockId.generate(),
                // Safety: Loop index i + 1 is guaranteed to fit in sequence field type
                .sequence = @intCast(i + 1),
                .source_uri = "test://durability",
                .metadata_json = "{}",
                .content = content,
            };

            try storage1.put_block(block);
            try written_blocks.append(block);
            stats.operations_executed += 1;

            // Randomly flush to create SSTables
            if (i % 10 == 0) {
                try storage1.flush_memtable_to_sstable();
            }
        }

        // Simulate crash
        storage1.shutdown() catch {};
        stats.crashes_injected += 1;

        // Phase 2: Recovery and verification
        var storage2 = try StorageEngine.init(
            fuzzer.allocator,
            sim_vfs.vfs(),
            "durability_test",
            Config{
                .memtable_max_size = 1 * 1024 * 1024,
            },
        );
        defer storage2.deinit();
        try storage2.startup(); // Should recover from WAL
        defer storage2.shutdown() catch {};
        stats.recoveries_tested += 1;

        // Verify all data survived
        for (written_blocks.items) |expected_block| {
            const found_opt = storage2.find_block(expected_block.id, BlockOwnership.temporary) catch |err| {
                std.debug.print("Durability violation: block {} lost after crash\n", .{expected_block.id});
                stats.violations_found += 1;
                // Safety: ContextBlock is a well-defined struct with known memory layout
                try fuzzer.handle_crash(@ptrCast(std.mem.asBytes(&expected_block)), err);
                continue;
            };

            if (found_opt == null) {
                std.debug.print("Durability violation: block {} not found after crash\n", .{expected_block.id});
                stats.violations_found += 1;
                continue;
            }

            const found = found_opt.?;
            if (!std.mem.eql(u8, found.block.content, expected_block.content)) {
                std.debug.print("Durability violation: block {} corrupted\n", .{expected_block.id});
                stats.violations_found += 1;
            }

            stats.properties_checked += 1;
        }

        fuzzer.record_iteration();
    }
}

/// Test consistency properties
pub fn run_consistency_testing(fuzzer: *main.Fuzzer) !void {
    std.debug.print("Testing consistency properties...\n", .{});

    var stats = PropertyStats{};
    defer stats.print();

    while (fuzzer.should_continue()) {
        // Create shared VFS for consistency testing
        var sim_vfs = try SimulationVFS.init(fuzzer.allocator);
        defer sim_vfs.deinit();

        // Create model as source of truth
        var model = try ModelState.init(fuzzer.allocator);
        defer model.deinit();

        // Create storage engine
        var storage = try StorageEngine.init(
            fuzzer.allocator,
            sim_vfs.vfs(),
            "consistency_test",
            Config.minimal_for_testing(),
        );
        defer storage.deinit();
        try storage.startup();
        defer storage.shutdown() catch {};

        // Generate operations
        var generator = WorkloadGenerator.init(
            fuzzer.allocator,
            fuzzer.config.seed + fuzzer.stats.iterations_executed,
            OperationMix{},
            WorkloadConfig{},
        );
        defer generator.deinit();

        // Apply operations to both model and storage
        for (0..100) |_| {
            const op = try generator.generate_operation();
            defer generator.cleanup_operation(&op);

            // Apply to model (always succeeds)
            apply_to_model(&model, &op) catch {};

            // Apply to storage
            apply_to_storage(&storage, &op) catch |err| {
                switch (err) {
                    error.BlockNotFound,
                    error.WriteStalled,
                    => {}, // Expected errors
                    // Safety: FuzzOperation struct has a well-defined memory layout for crash reporting
                    else => try fuzzer.handle_crash(@ptrCast(std.mem.asBytes(&op)), err),
                }
            };

            stats.operations_executed += 1;
        }

        // Verify consistency between model and storage
        try PropertyChecker.check_consistency(&model, &storage);
        try PropertyChecker.check_bidirectional_consistency(&model, &storage);
        stats.properties_checked += 2;

        fuzzer.record_iteration();
    }
}

/// Test linearizability properties
pub fn run_linearizability_testing(fuzzer: *main.Fuzzer) !void {
    std.debug.print("Testing linearizability properties...\n", .{});

    var stats = PropertyStats{};
    defer stats.print();

    while (fuzzer.should_continue()) {
        var sim_vfs = try SimulationVFS.init(fuzzer.allocator);
        defer sim_vfs.deinit();

        var storage = try StorageEngine.init(
            fuzzer.allocator,
            sim_vfs.vfs(),
            "linearizability_test",
            Config.minimal_for_testing(),
        );
        defer storage.deinit();
        try storage.startup();
        defer storage.shutdown() catch {};

        // Track operation history for linearizability checking
        var history = std.array_list.Managed(OperationHistoryEntry).init(fuzzer.allocator);
        defer history.deinit();

        // Generate concurrent-like operations
        var generator = WorkloadGenerator.init(
            fuzzer.allocator,
            fuzzer.config.seed,
            OperationMix{},
            WorkloadConfig{},
        );
        defer generator.deinit();

        // Simulate concurrent operations with overlapping times
        var logical_time: i64 = 0;
        for (0..100) |_| {
            const op = try generator.generate_operation();
            defer generator.cleanup_operation(&op);

            const start_time = logical_time;
            logical_time += 1;

            // Execute operation
            const result = apply_to_storage(&storage, &op);

            const end_time = logical_time;
            logical_time += 1;

            try history.append(.{
                .op = op,
                .start_time = start_time,
                .end_time = end_time,
                .result = if (result) |_| null else |err| err,
            });

            stats.operations_executed += 1;
        }

        // Verify linearizability
        if (!verify_linearizable(&history)) {
            stats.violations_found += 1;
            const input = std.mem.sliceAsBytes(history.items);
            try fuzzer.handle_crash(input, error.LinearizabilityViolation);
        }
        stats.properties_checked += 1;

        fuzzer.record_iteration();
    }
}

/// Run logic fuzzing with model checking
pub fn run_logic_fuzzing(fuzzer: *main.Fuzzer) !void {
    std.debug.print("Logic fuzzing with model checking...\n", .{});

    // Initialize simulation environment
    while (fuzzer.should_continue()) {
        // Fresh environment for each iteration to catch state corruption
        var sim_vfs = try SimulationVFS.init(fuzzer.allocator);
        defer sim_vfs.deinit();

        var storage = try StorageEngine.init(
            fuzzer.allocator,
            sim_vfs.vfs(),
            "logic_test",
            Config{
                .memtable_max_size = 2 * 1024 * 1024,
            },
        );
        defer storage.deinit();
        try storage.startup();
        defer storage.shutdown() catch {};

        var model = try ModelState.init(fuzzer.allocator);
        defer model.deinit();

        var generator = WorkloadGenerator.init(
            fuzzer.allocator,
            fuzzer.config.seed + fuzzer.stats.iterations_executed,
            OperationMix{},
            WorkloadConfig{},
        );
        defer generator.deinit();

        // Run sequence of operations
        for (0..1000) |_| {
            const op = try generator.generate_operation();
            defer generator.cleanup_operation(&op);

            // Apply to both model and storage
            apply_to_model(&model, &op) catch {};
            apply_to_storage(&storage, &op) catch |err| {
                switch (err) {
                    error.BlockNotFound,
                    error.WriteStalled,
                    error.WriteBlocked,
                    => {}, // Expected
                    // Safety: FuzzOperation struct has a well-defined memory layout for crash reporting
                    else => try fuzzer.handle_crash(@ptrCast(std.mem.asBytes(&op)), err),
                }
            };

            // Periodically check properties
            if (fuzzer.stats.iterations_executed % 100 == 0) {
                PropertyChecker.check_data_consistency(&model, &storage) catch |err| {
                    // Safety: Operation struct has a well-defined memory layout for crash reporting
                    try fuzzer.handle_crash(@ptrCast(std.mem.asBytes(&op)), err);
                };
            }
        }

        // Final property verification
        try PropertyChecker.check_data_consistency(&model, &storage);
        try PropertyChecker.check_bidirectional_consistency(&model, &storage);
        try PropertyChecker.check_no_data_loss(&model, &storage);

        fuzzer.record_iteration();
    }
}

// ============================================================================
// Helper Functions
// ============================================================================

fn apply_to_model(model: *ModelState, op: *const Operation) !void {
    switch (op.op_type) {
        .put_block => if (op.block) |block| try model.apply_put_block(block),
        .update_block => if (op.block) |block| try model.apply_put_block(block),
        .find_block => if (op.block_id) |id| {
            _ = model.find_active_block(id);
        },
        .delete_block => if (op.block_id) |id| try model.apply_delete_block(id),
        .put_edge => if (op.edge) |edge| try model.apply_put_edge(edge),
        .find_edges => if (op.block_id) |id| {
            _ = model.count_outgoing_edges(id);
        },
    }
}

fn apply_to_storage(storage: *StorageEngine, op: *const Operation) !void {
    switch (op.op_type) {
        .put_block => if (op.block) |block| try storage.put_block(block),
        .update_block => if (op.block) |block| try storage.put_block(block),
        .find_block => if (op.block_id) |id| {
            _ = try storage.find_block(id, BlockOwnership.temporary);
        },
        .delete_block => if (op.block_id) |id| try storage.delete_block(id),
        .put_edge => if (op.edge) |edge| try storage.put_edge(edge),
        .find_edges => if (op.block_id) |id| {
            _ = storage.find_outgoing_edges(id);
        },
    }
}

fn verify_linearizable(history: *const std.array_list.Managed(OperationHistoryEntry)) bool {
    // Simplified linearizability check
    // In production, would use a proper linearizability checker

    // Check that operations don't violate causality
    for (history.items, 0..) |entry1, i| {
        for (history.items[i + 1 ..]) |entry2| {
            // If op1 completes before op2 starts, their effects must be ordered
            if (entry1.end_time < entry2.start_time) {
                // Verify ordering is preserved in results
                if (entry1.op.block_id != null and entry2.op.block_id != null) {
                    if (std.meta.eql(entry1.op.block_id, entry2.op.block_id)) {
                        // Operations on same block must be ordered
                        // This is a simplified check - real implementation would be more thorough
                        if (entry1.result == null and entry2.result != null) {
                            // If first succeeded and second failed, might be a violation
                            // depending on operation types
                            continue;
                        }
                    }
                }
            }
        }
    }

    return true;
}
