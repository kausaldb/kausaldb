//! Logic Fuzzer for KausalDB
//!
//! Tests system correctness by generating valid operation sequences and comparing
//! actual behavior against an ideal model. This complements the deserialization
//! fuzzer by finding logical bugs rather than parsing crashes.
//!
//! Key difference from deserialization fuzzing:
//! - Input: Seeds for valid operation sequences (not random bytes)
//! - Oracle: Model state divergence (not crashes)
//! - Finds: State corruption, consistency violations, data loss

const std = @import("std");
const main = @import("main.zig");
const internal = @import("internal");

const WorkloadGenerator = internal.WorkloadGenerator;
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

const log = std.log.scoped(.logic_fuzz);

/// Configuration for logic fuzzing
const LogicFuzzConfig = struct {
    /// Total number of operations for the fuzzing campaign
    total_operations: u32 = 10000,

    /// Operation mix for realistic workloads
    operation_mix: OperationMix = .{
        .put_block_weight = 40,
        .find_block_weight = 30,
        .delete_block_weight = 10,
        .put_edge_weight = 15,
        .find_edges_weight = 5,
    },
};

/// Statistics specific to logic fuzzing
const LogicFuzzStats = struct {
    operations_executed: u64 = 0,
    backpressure_events: u64 = 0,
    data_loss_violations: u64 = 0,
    consistency_violations: u64 = 0,
    edge_violations: u64 = 0,
    memory_violations: u64 = 0,
};

/// Run logic fuzzing campaign
pub fn run_fuzzing(fuzzer: *main.Fuzzer) !void {
    const config = LogicFuzzConfig{ .total_operations = fuzzer.config.iterations };
    var stats = LogicFuzzStats{};

    log.info("Starting logic fuzzing with {} operations", .{config.total_operations});
    log.info("Seed: 0x{X}", .{fuzzer.config.seed});

    // Initialize ONE system and ONE model for the entire campaign
    var sim_vfs = try SimulationVFS.init(fuzzer.allocator);
    defer sim_vfs.deinit();

    const vfs = sim_vfs.vfs();
    const db_path = "fuzz_logic_db";

    var storage = try StorageEngine.init(
        fuzzer.allocator,
        vfs,
        db_path,
        Config{
            .memtable_max_size = 4 * 1024 * 1024, // 4MB for faster flushes
        },
    );
    defer storage.deinit();

    try storage.startup();
    defer storage.shutdown() catch {};

    // Initialize the model (our oracle)
    var model = try ModelState.init(fuzzer.allocator);
    defer model.deinit();

    // Initialize workload generator with the main seed for deterministic operations
    var generator = WorkloadGenerator.init(
        fuzzer.allocator,
        fuzzer.config.seed,
        config.operation_mix,
    );

    // Main loop runs for thousands of operations on the SAME engine instance
    for (0..config.total_operations) |op_index| {
        const op = try generator.generate_operation();
        defer generator.cleanup_operation(op);

        // Apply operation to the real system
        const success = apply_operation_to_system(&storage, op) catch |err| {
            const err_msg = try std.fmt.allocPrint(fuzzer.allocator, "operation_failed_at_{}", .{op_index});
            defer fuzzer.allocator.free(err_msg);
            try fuzzer.handle_crash(err_msg, err);
            continue;
        };

        // Track backpressure events (when operation was rejected due to system load)
        if (!success) {
            stats.backpressure_events += 1;
        }

        // If the system succeeded, update the model
        if (success) {
            try model.apply_operation(op);
        }

        // Verify properties after each operation
        verify_properties(&model, &storage) catch |err| {
            const err_msg = try std.fmt.allocPrint(fuzzer.allocator, "property_violation_at_{}", .{op_index});
            defer fuzzer.allocator.free(err_msg);
            try fuzzer.handle_crash(err_msg, err);

            // Increment general violation counter
            stats.consistency_violations += 1;
        };

        stats.operations_executed += 1;
        fuzzer.record_iteration();
    }

    // Final verification after all operations
    try verify_all_properties(&model, &storage);

    // Print logic fuzzing specific stats
    print_stats(stats);
}

/// Apply an operation to the real storage system
fn apply_operation_to_system(storage: *StorageEngine, op: Operation) !bool {
    switch (op.op_type) {
        .put_block => {
            if (op.block) |block| {
                storage.put_block(block) catch |err| switch (err) {
                    // These are expected backpressure signals, not bugs.
                    // The operation was not successful, so we return `false`.
                    error.WriteStalled, error.WriteBlocked => return false,
                    // Any other error is an unexpected bug.
                    else => return err,
                };
                return true;
            }
            return false;
        },
        .find_block => {
            if (op.block_id) |id| {
                _ = try storage.find_block(id, .query_engine);
                return true;
            }
            return false;
        },
        .delete_block => {
            if (op.block_id) |id| {
                storage.delete_block(id) catch |err| switch (err) {
                    // Delete operations can also experience backpressure.
                    error.WriteStalled, error.WriteBlocked => return false,
                    else => return err,
                };
                return true;
            }
            return false;
        },
        .put_edge => {
            if (op.edge) |edge| {
                storage.put_edge(edge) catch |err| switch (err) {
                    // Also handle backpressure for edge writes.
                    error.WriteStalled, error.WriteBlocked => return false,
                    else => return err,
                };
                return true;
            }
            return false;
        },
        .find_edges => {
            if (op.block_id) |id| {
                _ = storage.find_outgoing_edges(id);
                return true;
            }
            return false;
        },
    }
}

/// Verify critical properties after each operation
fn verify_properties(model: *ModelState, storage: *StorageEngine) !void {
    // Check data loss - most critical property
    try PropertyChecker.check_no_data_loss(model, storage);

    // Check edge consistency
    try PropertyChecker.check_bidirectional_consistency(model, storage);
}

/// Comprehensive property verification at end of test
fn verify_all_properties(model: *ModelState, storage: *StorageEngine) !void {
    // Core properties
    try PropertyChecker.check_no_data_loss(model, storage);
    try PropertyChecker.check_consistency(model, storage);

    // Graph properties
    try PropertyChecker.check_transitivity(model, storage);
    try PropertyChecker.check_k_hop_consistency(model, storage, 3);
    try PropertyChecker.check_bidirectional_consistency(model, storage);

    // Final model verification
    try model.verify_against_system(storage);
}

/// Print logic fuzzing specific statistics
fn print_stats(stats: LogicFuzzStats) void {
    std.debug.print("\n=== Logic Fuzzing Statistics ===\n", .{});
    std.debug.print("Operations executed: {}\n", .{stats.operations_executed});

    if (stats.backpressure_events > 0) {
        std.debug.print("Backpressure events: {} ({d:.1}% of operations)\n", .{ stats.backpressure_events, @as(f64, @floatFromInt(stats.backpressure_events * 100)) / @as(f64, @floatFromInt(@max(stats.operations_executed, 1))) });
    }

    if (stats.data_loss_violations > 0 or
        stats.consistency_violations > 0 or
        stats.edge_violations > 0 or
        stats.memory_violations > 0)
    {
        std.debug.print("\n=== Violations Detected ===\n", .{});
        if (stats.data_loss_violations > 0) {
            std.debug.print("Data loss violations: {}\n", .{stats.data_loss_violations});
        }
        if (stats.consistency_violations > 0) {
            std.debug.print("Consistency violations: {}\n", .{stats.consistency_violations});
        }
        if (stats.edge_violations > 0) {
            std.debug.print("Edge violations: {}\n", .{stats.edge_violations});
        }
        if (stats.memory_violations > 0) {
            std.debug.print("Memory violations: {}\n", .{stats.memory_violations});
        }
    } else {
        std.debug.print("\nNo violations detected - system behaved correctly\n", .{});
    }
}

/// Test crash recovery behavior
pub fn fuzz_crash_recovery(fuzzer: *main.Fuzzer) !void {
    log.info("Starting crash recovery fuzzing", .{});

    for (0..fuzzer.config.iterations) |iteration| {
        const seed = fuzzer.config.seed ^ @as(u64, @intCast(iteration));

        fuzz_single_crash_recovery(fuzzer, seed) catch |err| {
            const crash_data = try std.fmt.allocPrint(
                fuzzer.allocator,
                "crash_recovery_seed_{X}",
                .{seed},
            );
            defer fuzzer.allocator.free(crash_data);
            try fuzzer.handle_crash(crash_data, err);
        };

        fuzzer.record_iteration();
    }
}

/// Test a single crash recovery scenario
fn fuzz_single_crash_recovery(fuzzer: *main.Fuzzer, seed: u64) !void {
    // Create persistent VFS that survives "crash"
    var sim_vfs = try SimulationVFS.init(fuzzer.allocator);
    defer sim_vfs.deinit();

    const vfs = sim_vfs.vfs();
    const db_path = try std.fmt.allocPrint(fuzzer.allocator, "crash_test_{}", .{seed});
    defer fuzzer.allocator.free(db_path);

    // Initialize model
    var model = try ModelState.init(fuzzer.allocator);
    defer model.deinit();

    // Phase 1: Write operations before crash
    {
        var storage = try StorageEngine.init(
            fuzzer.allocator,
            vfs,
            db_path,
            Config{
                .memtable_max_size = 4 * 1024 * 1024, // 4MB
            },
        );
        defer storage.deinit();

        try storage.startup();

        var generator = WorkloadGenerator.init(fuzzer.allocator, seed, .{});

        // Execute operations
        for (0..50) |_| {
            const op = try generator.generate_operation();
            defer generator.cleanup_operation(op);

            if (try apply_operation_to_system(&storage, op)) {
                try model.apply_operation(op);
            }
        }

        // Simulate crash (no proper shutdown)
        // storage.shutdown() deliberately not called
    }

    // Phase 2: Recovery and verification
    {
        var storage = try StorageEngine.init(
            fuzzer.allocator,
            vfs,
            db_path,
            Config{
                .memtable_max_size = 4 * 1024 * 1024, // 4MB
            },
        );
        defer storage.deinit();

        // This should trigger WAL recovery
        try storage.startup();
        defer storage.shutdown() catch {};

        // Verify all acknowledged writes survived
        try PropertyChecker.check_no_data_loss(&model, &storage);
    }
}
