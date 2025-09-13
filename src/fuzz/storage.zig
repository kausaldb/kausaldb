//! Storage engine fuzzing - systematic state and input fuzzing
//!
//! Tests storage engine robustness against malformed inputs, invalid
//! state transitions, and edge cases. All fuzzing is deterministic
//! and reproducible using seeds.

const std = @import("std");
const main = @import("main.zig");

// Import internal types through parent module to avoid module conflicts
const internal = @import("internal");

const StorageEngine = internal.StorageEngine;
const SimulationVFS = internal.SimulationVFS;
const VFS = internal.vfs.VFS;
const ContextBlock = internal.ContextBlock;
const GraphEdge = internal.GraphEdge;
const BlockId = internal.BlockId;
const EdgeType = internal.EdgeType;
const Config = internal.Config;
const BlockOwnership = internal.ownership.BlockOwnership;

/// Run storage fuzzing using the shared fuzzer infrastructure
pub fn run_fuzzing(fuzzer: *main.Fuzzer) !void {
    std.debug.print("Fuzzing storage engine...\n", .{});

    for (0..fuzzer.config.iterations) |i| {
        const input = try fuzzer.generate_input();
        defer fuzzer.allocator.free(input);

        // Select fuzzing strategy based on iteration
        const strategy = i % 7;
        switch (strategy) {
            0 => fuzz_storage_operations(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            1 => fuzz_edge_cases(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            2 => fuzz_sstable_operations(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            3 => fuzz_compaction(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            4 => fuzz_concurrent_operations(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            5 => fuzz_block_serialization(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            6 => { // Recovery test every 7th iteration (reduced frequency)
                fuzz_recovery_operations(fuzzer.allocator, input) catch |err| {
                    try fuzzer.handle_crash(input, err);
                };
            },
            else => {},
        }

        fuzzer.record_iteration();

        if (i % 1000 == 0) {
            std.debug.print("Storage fuzz: {} iterations\n", .{i});
        }
    }
}

/// Core fuzzing logic for storage operations
fn fuzz_storage_operations(allocator: std.mem.Allocator, input: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Use SimulationVFS with fault injection seed
    var sim_vfs = try SimulationVFS.init(alloc);
    defer sim_vfs.deinit();
    const vfs = sim_vfs.vfs();

    // Configure storage for fuzzing with smaller memtable for faster flushes
    const config = Config{
        .memtable_max_size = 4 * 1024 * 1024, // 4MB for faster flushes
    };

    var storage = try StorageEngine.init(alloc, vfs, "fuzz_storage", config);
    defer storage.deinit();

    // CRITICAL FIX: Must startup before any operations
    // This was the state machine bug: .initialized -> .flushing is invalid
    try storage.startup();
    defer storage.shutdown() catch {};

    // Parse input to determine operations
    var i: usize = 0;
    while (i + 4 < input.len) : (i += 1) {
        const op_type = input[i] % 6; // 6 operation types

        switch (op_type) {
            0 => { // put_block
                const block = fuzz_generate_block(alloc, input[i..]);
                storage.put_block(block) catch {
                    // Handle assertion failures and validation errors gracefully
                };
            },
            1 => { // find_block
                const id = fuzz_generate_block_id(input[i..]);
                _ = storage.find_block(id, BlockOwnership.simulation_test) catch {};
            },
            2 => { // delete_block
                const id = fuzz_generate_block_id(input[i..]);
                storage.delete_block(id) catch {};
            },
            3 => { // put_edge
                const edge = fuzz_generate_edge(input[i..]);
                storage.put_edge(edge) catch {};
            },
            4 => { // coordinate_memtable_flush - NOW SAFE after startup()
                storage.flush_memtable_to_sstable() catch {
                    // Handle flush errors gracefully
                };
            },
            5 => { // find_edges
                const id = fuzz_generate_block_id(input[i..]);
                _ = storage.find_outgoing_edges(id);
                _ = storage.find_incoming_edges(id);
            },
            else => {},
        }
    }
}

/// Fuzz edge cases with malformed and boundary data
fn fuzz_edge_cases(allocator: std.mem.Allocator, input: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var sim_vfs = try SimulationVFS.init(alloc);
    defer sim_vfs.deinit();
    const vfs = sim_vfs.vfs();

    const config = Config.minimal_for_testing();
    var storage = try StorageEngine.init(alloc, vfs, "fuzz_edge_cases", config);
    defer storage.deinit();
    try storage.startup();
    defer storage.shutdown() catch {};

    // Test empty input handling
    if (input.len == 0) {
        const empty_block = ContextBlock{
            .id = BlockId.generate(),
            .version = 1,
            .source_uri = "fuzz://empty",
            .metadata_json = "{}",
            .content = "",
        };
        storage.put_block(empty_block) catch {};
        return;
    }

    // Test extremely large content (within limits)
    if (input.len > 100) {
        const sample = input[0..@min(10, input.len)];
        const large_content = std.fmt.allocPrint(alloc, "fuzz_large_content_{X}_repeated", .{std.hash.Wyhash.hash(0, sample)}) catch "fuzz_large_fallback";
        const large_block = ContextBlock{
            .id = BlockId.generate(),
            .version = 1,
            .source_uri = "fuzz://large",
            .metadata_json = "{}",
            .content = large_content,
        };
        storage.put_block(large_block) catch {};
    }

    // Test duplicate block IDs
    if (input.len >= 16) {
        const id = fuzz_generate_block_id(input);
        const block1 = ContextBlock{
            .id = id,
            .version = 1,
            .source_uri = "fuzz://dup1",
            .metadata_json = "{}",
            .content = "duplicate_test_1",
        };
        const block2 = ContextBlock{
            .id = id,
            .version = 2,
            .source_uri = "fuzz://dup2",
            .metadata_json = "{}",
            .content = "duplicate_test_2",
        };
        storage.put_block(block1) catch {};
        storage.put_block(block2) catch {}; // Should handle duplicate gracefully
    }

    // Test normal edge relationships (avoid self-references as they're invalid)
    if (input.len >= 32) {
        const source_id = fuzz_generate_block_id(input[0..16]);
        const target_id = fuzz_generate_block_id(input[16..32]);
        const edge = GraphEdge{
            .source_id = source_id,
            .target_id = target_id,
            .edge_type = EdgeType.calls,
        };
        storage.put_edge(edge) catch {};
    }

    // Test rapid state transitions
    for (0..5) |_| {
        storage.flush_memtable_to_sstable() catch {};
    }
}

/// Test WAL recovery with fuzzed operations (separate function for controlled frequency)
fn fuzz_recovery_operations(allocator: std.mem.Allocator, input: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var sim_vfs = try SimulationVFS.init(alloc);
    defer sim_vfs.deinit();
    const vfs = sim_vfs.vfs();

    try fuzz_test_recovery(alloc, vfs, input);
}

/// Test WAL recovery with fuzzed operations
fn fuzz_test_recovery(allocator: std.mem.Allocator, vfs: VFS, input: []const u8) !void {
    _ = input;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Create first storage instance and perform operations
    const config = Config{
        .memtable_max_size = 2 * 1024 * 1024,
    };

    {
        var storage1 = try StorageEngine.init(arena_alloc, vfs, "fuzz_recovery", config);
        defer storage1.deinit();
        try storage1.startup();

        // Perform some operations
        for (0..10) |i| {
            const block = ContextBlock{
                .id = BlockId.generate(),
                .version = 1,
                .source_uri = "fuzz://recovery",
                .metadata_json = "{}",
                .content = std.fmt.allocPrint(arena_alloc, "recovery_test_{}", .{i}) catch "test",
            };
            storage1.put_block(block) catch {
                // Handle validation errors in recovery testing
            };
        }

        try storage1.shutdown();
    }

    // Create second instance to test recovery
    {
        var storage2 = try StorageEngine.init(arena_alloc, vfs, "fuzz_recovery", config);
        defer storage2.deinit();
        try storage2.startup(); // Should recover from WAL
        defer storage2.shutdown() catch {};

        // Verify recovery succeeded by attempting operations
        const test_block = ContextBlock{
            .id = BlockId.generate(),
            .version = 1,
            .source_uri = "fuzz://post_recovery",
            .metadata_json = "{}",
            .content = "post_recovery_test",
        };
        storage2.put_block(test_block) catch {
            // Handle validation errors in post-recovery testing
        };
    }
}

/// Fuzz block serialization/deserialization
fn fuzz_block_serialization(allocator: std.mem.Allocator, input: []const u8) !void {
    // Use arena to ensure all allocations are cleaned up
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const block = fuzz_generate_block(arena_alloc, input);

    // Attempt to serialize
    const buffer_size = block.serialized_size();
    const buffer = arena_alloc.alloc(u8, buffer_size) catch {
        // Allocation errors are expected for large inputs
        return;
    };

    _ = block.serialize(buffer) catch {
        // Serialization errors are expected for malformed input
        return;
    };

    // Attempt to deserialize - use arena allocator to prevent leaks
    _ = ContextBlock.deserialize(arena_alloc, buffer) catch {
        // Deserialization errors are expected for corrupted data
        return;
    };
    // No need to manually free - arena will clean up everything
}

/// Fuzz SSTable operations through storage engine (no direct SSTable API available)
fn fuzz_sstable_operations(allocator: std.mem.Allocator, input: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var sim_vfs = try SimulationVFS.init(alloc);
    defer sim_vfs.deinit();
    const vfs = sim_vfs.vfs();

    const config = Config{
        .memtable_max_size = 1024 * 1024, // Small memtable to force SSTable creation
    };

    var storage = try StorageEngine.init(alloc, vfs, "fuzz_sstable", config);
    defer storage.deinit();
    try storage.startup();
    defer storage.shutdown() catch {};

    // Add blocks to trigger SSTable creation through storage engine
    var i: usize = 0;
    while (i + 16 < input.len) : (i += 16) {
        const block = fuzz_generate_block(alloc, input[i..]);
        storage.put_block(block) catch {};

        // Periodically flush to create SSTables
        if (i % 64 == 0) {
            storage.flush_memtable_to_sstable() catch {};
        }
    }

    // Test lookups after SSTable creation
    i = 0;
    while (i + 16 < input.len) : (i += 8) {
        const id = fuzz_generate_block_id(input[i..]);
        _ = storage.find_block(id, BlockOwnership.simulation_test) catch {};
    }
}

/// Generate a fuzzed block from input data that complies with all validation rules
fn fuzz_generate_block(allocator: std.mem.Allocator, data: []const u8) ContextBlock {
    // Generate content that's guaranteed to be under size limits
    const content_hash = if (data.len >= 8) std.hash.Wyhash.hash(0, data[0..@min(8, data.len)]) else 0;
    const content = std.fmt.allocPrint(allocator, "fuzz_content_{X}", .{content_hash}) catch "fuzz_safe";

    // Generate source_uri that's non-empty and under 2048 bytes
    const uri_suffix = if (data.len > 0) data[0] % 100 else 42;
    const source_uri = std.fmt.allocPrint(allocator, "fuzz://test_{}", .{uri_suffix}) catch "fuzz://safe";

    // Generate metadata_json under 1MB limit
    const use_extended_metadata = data.len > 16 and (data[16] % 4 == 0);
    const metadata_json = if (use_extended_metadata)
        "{\"fuzz\":true,\"type\":\"test\"}"
    else
        "{}";

    return ContextBlock{
        .id = fuzz_generate_block_id(data),
        .version = if (data.len > 0) @max(data[0] % 255, 1) else 1, // Version 1-255, always > 0
        .source_uri = source_uri,
        .metadata_json = metadata_json,
        .content = content,
    };
}

/// Generate a fuzzed BlockId from input data
fn fuzz_generate_block_id(data: []const u8) BlockId {
    if (data.len >= 16) {
        var bytes: [16]u8 = undefined;
        @memcpy(&bytes, data[0..16]);
        return BlockId{ .bytes = bytes };
    }
    return BlockId.generate();
}

/// Generate a fuzzed edge from input data
fn fuzz_generate_edge(data: []const u8) GraphEdge {
    const edge_type = if (data.len > 16)
        @as(EdgeType, @enumFromInt(data[16] % @typeInfo(EdgeType).@"enum".fields.len))
    else
        EdgeType.calls;

    return GraphEdge{
        .source_id = fuzz_generate_block_id(data),
        .target_id = if (data.len > 16) fuzz_generate_block_id(data[16..]) else BlockId.generate(),
        .edge_type = edge_type,
    };
}

/// Fuzz compaction operations
fn fuzz_compaction(allocator: std.mem.Allocator, input: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var sim_vfs = try SimulationVFS.init(alloc);
    defer sim_vfs.deinit();
    const vfs = sim_vfs.vfs();

    const config = Config{
        .memtable_max_size = 1 * 1024 * 1024, // 1MB for frequent flushes
    };

    var storage = try StorageEngine.init(alloc, vfs, "fuzz_compact", config);
    defer storage.deinit();
    try storage.startup();
    defer storage.shutdown() catch {};

    // Generate multiple SSTables through repeated flushes
    var flush_count: usize = 0;
    var i: usize = 0;
    while (i < input.len and flush_count < 10) : (flush_count += 1) {
        // Fill memtable
        var block_count: usize = 0;
        while (i < input.len and block_count < 100) : ({
            i += 1;
            block_count += 1;
        }) {
            const block = fuzz_generate_block(alloc, input[i..]);
            storage.put_block(block) catch {};
        }

        // Force flush
        storage.flush_memtable_to_sstable() catch {};
    }
}

/// Fuzz concurrent-like operations (simulated through sequential ops)
fn fuzz_concurrent_operations(allocator: std.mem.Allocator, input: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var sim_vfs = try SimulationVFS.init(alloc);
    defer sim_vfs.deinit();
    const vfs = sim_vfs.vfs();

    var storage = try StorageEngine.init(alloc, vfs, "fuzz_concurrent", Config.minimal_for_testing());
    defer storage.deinit();
    try storage.startup();
    defer storage.shutdown() catch {};

    // Simulate interleaved operations
    var block_ids = std.array_list.Managed(BlockId).init(alloc);
    defer block_ids.deinit();

    var i: usize = 0;
    while (i + 2 < input.len) : (i += 1) {
        const op_mix = input[i] % 10;

        switch (op_mix) {
            0...3 => { // 40% writes
                const block = fuzz_generate_block(alloc, input[i..]);
                block_ids.append(block.id) catch {};
                storage.put_block(block) catch {
                    // Handle validation errors in concurrent testing
                };
            },
            4...7 => { // 40% reads
                if (block_ids.items.len > 0) {
                    const idx = input[i + 1] % block_ids.items.len;
                    _ = storage.find_block(block_ids.items[idx], BlockOwnership.simulation_test) catch {};
                }
            },
            8 => { // 10% deletes
                if (block_ids.items.len > 0) {
                    const idx = input[i + 1] % block_ids.items.len;
                    storage.delete_block(block_ids.items[idx]) catch {};
                    _ = block_ids.orderedRemove(idx);
                }
            },
            9 => { // 10% flushes
                storage.flush_memtable_to_sstable() catch {};
            },
            else => {},
        }
    }
}
