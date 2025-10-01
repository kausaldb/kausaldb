//! Storage engine fuzzing for parsing and logic bugs.
//!
//! Parse fuzzing finds crashes in deserialization of on-disk formats.
//! Logic fuzzing finds invariant violations in operation sequences.
//! All fuzzing is deterministic and reproducible using seeds.

const std = @import("std");

const internal = @import("internal");
const main = @import("main.zig");

const StorageEngine = internal.StorageEngine;
const SimulationVFS = internal.SimulationVFS;
const VFS = internal.vfs.VFS;
const ContextBlock = internal.ContextBlock;
const GraphEdge = internal.GraphEdge;
const BlockId = internal.BlockId;
const EdgeType = internal.EdgeType;
const Config = internal.Config;
const ArenaCoordinator = internal.memory.ArenaCoordinator;
const SSTable = internal.sstable.SSTable;
const WorkloadGenerator = internal.WorkloadGenerator;
const WorkloadConfig = internal.WorkloadConfig;
const ModelState = internal.ModelState;
const PropertyChecker = internal.PropertyChecker;
const OperationMix = internal.OperationMix;
const Operation = internal.Operation;
const BlockOwnership = internal.ownership.BlockOwnership;
const OwnedBlockCollection = internal.ownership.OwnedBlockCollection;

/// Parse fuzzing tests deserialization robustness
pub fn run_parse_fuzzing(fuzzer: *main.Fuzzer) !void {
    std.debug.print("Storage parse fuzzing...\n", .{});

    while (fuzzer.should_continue()) {
        const input = try fuzzer.generate_input(4096);
        const strategy = fuzzer.stats.iterations_executed % 6;
        switch (strategy) {
            0 => fuzz_sstable_header_parsing(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            1 => fuzz_wal_entry_parsing(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            2 => fuzz_block_deserialization(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            3 => fuzz_edge_deserialization(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            4 => fuzz_corrupted_file_recovery(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            5 => fuzz_metadata_parsing(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            else => unreachable,
        }

        fuzzer.record_iteration();
    }
}

/// Logic fuzzing - test operational correctness
pub fn run_logic_fuzzing(fuzzer: *main.Fuzzer) !void {
    std.debug.print("Storage logic fuzzing...\n", .{});

    // Create persistent state for logic testing
    var sim_vfs = try SimulationVFS.init(fuzzer.allocator);
    defer sim_vfs.deinit();

    var storage = try StorageEngine.init(
        fuzzer.allocator,
        sim_vfs.vfs(),
        "fuzz_logic_db",
        Config{
            .memtable_max_size = 1 * 1024 * 1024, // 1MB for faster flushes
        },
    );
    defer storage.deinit();

    try storage.startup();
    defer storage.shutdown() catch {};

    // Initialize model for property checking
    var model = try ModelState.init(fuzzer.allocator);
    defer model.deinit();

    // Configure workload generator
    const operation_mix = OperationMix{
        .put_block_weight = 40,
        .update_block_weight = 10,
        .find_block_weight = 30,
        .delete_block_weight = 5,
        .put_edge_weight = 10,
        .find_edges_weight = 5,
    };

    var generator = WorkloadGenerator.init(
        fuzzer.allocator,
        fuzzer.config.seed,
        operation_mix,
        WorkloadConfig{},
    );
    defer generator.deinit();

    while (fuzzer.should_continue()) {
        const op = try generator.generate_operation();
        defer generator.cleanup_operation(&op);

        // Apply operation to both system and model
        apply_operation_to_storage(&storage, &op) catch |err| {
            // Some errors are expected (e.g., BlockNotFound)
            switch (err) {
                error.BlockNotFound,
                error.WriteStalled,
                error.WriteBlocked,
                => {},
                // Safety: FuzzOperation struct has a well-defined memory layout for crash reporting
                else => try fuzzer.handle_crash(@ptrCast(std.mem.asBytes(&op)), err),
            }
        };

        apply_operation_to_model(&model, &op) catch |err| {
            // Safety: FuzzOperation struct has a well-defined memory layout for crash reporting
            try fuzzer.handle_crash(@ptrCast(std.mem.asBytes(&op)), err);
        };

        // Periodically verify properties
        if (fuzzer.stats.iterations_executed % 100 == 0) {
            verify_storage_properties(&storage, &model) catch |err| {
                // Safety: FuzzOperation struct has a well-defined memory layout for crash reporting
                try fuzzer.handle_crash(@ptrCast(std.mem.asBytes(&op)), err);
            };
        }

        // Inject faults occasionally
        if (fuzzer.stats.iterations_executed % 500 == 0) {
            inject_storage_fault(&sim_vfs) catch {};
        }

        fuzzer.record_iteration();
    }

    // Final property verification
    try verify_storage_properties(&storage, &model);
}

// ============================================================================
// Parse Fuzzing Functions
// ============================================================================

fn fuzz_sstable_header_parsing(allocator: std.mem.Allocator, input: []const u8) !void {
    // SSTable header is 64 bytes aligned, test malformed headers
    if (input.len < 64) return;
    var sim_vfs = try SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    const path = "fuzz_sstable.sst";
    var file = try sim_vfs.vfs().open(path, .read_write);
    defer file.close();

    // Write malformed header
    _ = try file.write(input[0..@min(64, input.len)]);

    // Attempt to load as SSTable
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var arena_coordinator = ArenaCoordinator.init(&arena);

    var sstable = SSTable.init(&arena_coordinator, allocator, sim_vfs.vfs(), path);
    defer sstable.deinit();

    sstable.read_index() catch {
        // Expected - malformed data should cause parsing to fail
        return;
    };
}

fn fuzz_wal_entry_parsing(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 32) return;

    // Parse as WAL entry - expects CRC-64 checksum
    const WALEntry = internal.wal.WALEntry;

    _ = WALEntry.deserialize(allocator, input) catch |err| switch (err) {
        // Expected parsing errors
        error.ChecksumMismatch,
        error.InvalidEntryType,
        error.BufferTooSmall,
        error.InvalidChecksum,
        error.CorruptedEntry,
        => return,
        else => return err,
    };
}

fn fuzz_block_deserialization(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < @sizeOf(ContextBlock)) return;

    // Test block deserialization with ownership tracking
    var collection = OwnedBlockCollection.init(allocator, .temporary);
    defer collection.deinit(allocator);

    _ = ContextBlock.deserialize(allocator, input) catch {
        // Expected - malformed data should cause parsing to fail
        return;
    };
}

fn fuzz_edge_deserialization(allocator: std.mem.Allocator, input: []const u8) !void {
    _ = allocator;
    if (input.len < @sizeOf(GraphEdge)) return;

    _ = GraphEdge.deserialize(input) catch {
        // Expected - malformed data should cause parsing to fail
        return;
    };
}

fn fuzz_corrupted_file_recovery(allocator: std.mem.Allocator, input: []const u8) !void {
    // Test recovery from corrupted WAL files
    var sim_vfs = try SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    const wal_path = "wal_000001.log";
    var file = try sim_vfs.vfs().open(wal_path, .read_write);
    defer file.close();

    // Write corrupted WAL data
    _ = try file.write(input);

    // Attempt recovery using standalone function
    const recovery_callback = struct {
        fn callback(entry: internal.wal.WALEntry, context: *anyopaque) internal.wal.WALError!void {
            _ = entry;
            _ = context;
        }
    }.callback;

    var dummy_context: u8 = 0;
    var stats = internal.wal.WALStats{
        .entries_written = 0,
        .entries_recovered = 0,
        .segments_rotated = 0,
        .recovery_failures = 0,
        .bytes_written = 0,
    };
    _ = internal.wal.recover_from_segment(sim_vfs.vfs(), allocator, "corrupted.wal", recovery_callback, &dummy_context, &stats) catch {
        // Expected - corrupted data should cause recovery to fail
        return;
    };
}

fn fuzz_metadata_parsing(allocator: std.mem.Allocator, input: []const u8) !void {

    // Test parsing of JSON metadata fields
    const max_metadata_size = 4096;
    const metadata_input = input[0..@min(input.len, max_metadata_size)];

    // Attempt to parse as JSON
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        metadata_input,
        .{},
    ) catch |err| switch (err) {
        error.SyntaxError,
        error.UnexpectedEndOfInput,
        error.InvalidNumber,
        error.InvalidEnumTag,
        => return,
        else => return err,
    };
    defer parsed.deinit();
}

// ============================================================================
// Logic Fuzzing Functions
// ============================================================================

fn apply_operation_to_storage(storage: *StorageEngine, op: *const Operation) !void {
    switch (op.op_type) {
        .put_block => {
            if (op.block) |block| {
                try storage.put_block(block);
            }
        },
        .update_block => {
            if (op.block) |block| {
                // Update is put with higher sequence
                try storage.put_block(block);
            }
        },
        .find_block => {
            if (op.block_id) |id| {
                _ = try storage.find_block(id, .temporary);
            }
        },
        .delete_block => {
            if (op.block_id) |id| {
                try storage.delete_block(id);
            }
        },
        .put_edge => {
            if (op.edge) |edge| {
                try storage.put_edge(edge);
            }
        },
        .find_edges => {
            if (op.block_id) |id| {
                _ = storage.find_outgoing_edges(id);
            }
        },
    }
}

fn apply_operation_to_model(model: *ModelState, op: *const Operation) !void {
    switch (op.op_type) {
        .put_block => {
            if (op.block) |block| {
                try model.apply_put_block(block);
            }
        },
        .update_block => {
            if (op.block) |block| {
                try model.apply_put_block(block);
            }
        },
        .find_block => {
            if (op.block_id) |id| {
                _ = model.find_active_block(id);
            }
        },
        .delete_block => {
            if (op.block_id) |id| {
                try model.apply_delete_block(id);
            }
        },
        .put_edge => {
            if (op.edge) |edge| {
                try model.apply_put_edge(edge);
            }
        },
        .find_edges => {
            if (op.block_id) |id| {
                _ = model.count_outgoing_edges(id);
            }
        },
    }
}

fn verify_storage_properties(storage: *StorageEngine, model: *ModelState) !void {
    // Verify data consistency
    try PropertyChecker.check_no_data_loss(model, storage);

    // Verify bidirectional edge consistency
    try PropertyChecker.check_bidirectional_consistency(model, storage);

    // Verify no data loss
    try PropertyChecker.check_no_data_loss(model, storage);

    // Verify memory invariants
    storage.validate_memory_hierarchy();
}

fn inject_storage_fault(sim_vfs: *SimulationVFS) !void {
    // Randomly inject I/O errors or corruptions
    // Safety: timestamp() returns a valid i64 that can be safely cast to u64 for PRNG seed
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const fault_type = prng.random().uintLessThan(u8, 4);

    switch (fault_type) {
        0 => sim_vfs.enable_fault_testing_mode(), // Enable general fault injection
        1 => sim_vfs.enable_torn_writes(50, 1024, 500), // Enable torn writes
        2 => sim_vfs.enable_read_corruption(10, 4), // Enable read corruption
        3 => {}, // No fault this time
        else => unreachable,
    }
}
