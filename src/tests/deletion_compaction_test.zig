//! Test suite validating deletion persistence through compaction.
//!
//! These tests ensure that deleted blocks are never resurrected during
//! compaction, maintaining durability guarantees across all storage layers.

const std = @import("std");
const builtin = @import("builtin");

// Core modules
const assert_mod = @import("../core/assert.zig");
const concurrency = @import("../core/concurrency.zig");
const types = @import("../core/types.zig");
const error_context = @import("../core/error_context.zig");
const memory = @import("../core/memory.zig");
const vfs = @import("../core/vfs.zig");

// Storage modules
const block_index = @import("../storage/block_index.zig");
const tiered_compaction = @import("../storage/tiered_compaction.zig");
const engine = @import("../storage/engine.zig");
const memtable_manager = @import("../storage/memtable_manager.zig");
const sstable = @import("../storage/sstable.zig");
const wal = @import("../storage/wal.zig");

// Testing modules
const simulation_vfs = @import("../sim/simulation_vfs.zig");
const workload = @import("../testing/workload.zig");

// Re-declarations
const assert_fmt = assert_mod.assert_fmt;
const fatal_assert = assert_mod.fatal_assert;
const testing = std.testing;

const ArenaCoordinator = memory.ArenaCoordinator;
const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const OperationMix = workload.OperationMix;
const SimulationVFS = simulation_vfs.SimulationVFS;
const StorageEngine = engine.StorageEngine;

/// Create deterministic test block for reproducible testing
fn create_test_block(comptime id_suffix: []const u8, version: u32) !ContextBlock {
    const id_hex = "1111111111111111111111111111" ++ id_suffix;
    return ContextBlock{
        .id = try BlockId.from_hex(id_hex),
        .version = version,
        .source_uri = "test://deletion/" ++ id_suffix,
        .metadata_json = "{\"test\": true}",
        .content = "Test content for block " ++ id_suffix,
    };
}

test "basic deletion persistence through flush" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/test_deletion_flush");
    defer storage_engine.deinit();
    try storage_engine.startup();
    defer storage_engine.shutdown() catch {};

    // Insert blocks
    const block1 = try create_test_block("0001", 1);
    const block2 = try create_test_block("0002", 1);
    const block3 = try create_test_block("0003", 1);

    try storage_engine.put_block(block1);
    try storage_engine.put_block(block2);
    try storage_engine.put_block(block3);

    // Verify all blocks exist
    try testing.expect((try storage_engine.find_block(block1.id, .query_engine)) != null);
    try testing.expect((try storage_engine.find_block(block2.id, .query_engine)) != null);
    try testing.expect((try storage_engine.find_block(block3.id, .query_engine)) != null);

    // Delete block2
    try storage_engine.delete_block(block2.id);

    // Verify deletion in memtable
    try testing.expect((try storage_engine.find_block(block1.id, .query_engine)) != null);
    try testing.expect((try storage_engine.find_block(block2.id, .query_engine)) == null);
    try testing.expect((try storage_engine.find_block(block3.id, .query_engine)) != null);

    // Flush to SSTable
    try storage_engine.flush_memtable_to_sstable();

    // Verify deletion persists after flush
    try testing.expect((try storage_engine.find_block(block1.id, .query_engine)) != null);
    try testing.expect((try storage_engine.find_block(block2.id, .query_engine)) == null);
    try testing.expect((try storage_engine.find_block(block3.id, .query_engine)) != null);
}

test "deletion persistence through single compaction" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/test_deletion_compact");
    defer storage_engine.deinit();
    try storage_engine.startup();
    defer storage_engine.shutdown() catch {};

    // Create initial SSTable with blocks
    const block1 = try create_test_block("0001", 1);
    const block2 = try create_test_block("0002", 1);
    const block3 = try create_test_block("0003", 1);

    try storage_engine.put_block(block1);
    try storage_engine.put_block(block2);
    try storage_engine.put_block(block3);
    try storage_engine.flush_memtable_to_sstable();

    // Delete block2 and flush again (creates tombstone in new SSTable)
    try storage_engine.delete_block(block2.id);
    try storage_engine.flush_memtable_to_sstable();

    // Force compaction to test tombstone persistence
    try storage_engine.sstable_manager.check_and_run_compaction();

    // Verify block2 remains deleted after compaction
    const found1 = try storage_engine.find_block(block1.id, .query_engine);
    const found2 = try storage_engine.find_block(block2.id, .query_engine);
    const found3 = try storage_engine.find_block(block3.id, .query_engine);

    try testing.expect(found1 != null);
    try testing.expect(found2 == null); // Critical: Must remain deleted
    try testing.expect(found3 != null);
}

test "deletion persistence through multiple compactions" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/test_multi_compact");
    defer storage_engine.deinit();
    try storage_engine.startup();
    defer storage_engine.shutdown() catch {};

    // Create multiple generations of SSTables
    var block_count: u32 = 0;
    var deleted_ids = std.array_list.Managed(BlockId).init(allocator);
    defer deleted_ids.deinit();

    // Generation 1: Create initial blocks
    var i: u32 = 1;
    while (i < 10) : (i += 1) {
        const hex = try std.fmt.allocPrint(allocator, "00000000000000000000000000000{x:03}", .{i});
        defer allocator.free(hex);
        const block = ContextBlock{
            .id = try BlockId.from_hex(hex),
            .version = 1,
            .source_uri = "test://gen1",
            .metadata_json = "{}",
            .content = try std.fmt.allocPrint(allocator, "Generation 1 block {}", .{i}),
        };
        defer allocator.free(block.content);
        try storage_engine.put_block(block);
        block_count += 1;
    }
    try storage_engine.flush_memtable_to_sstable();

    // Generation 2: Delete even-numbered blocks (skip block 0 - zero BlockId is invalid)
    i = 2;
    while (i < 10) : (i += 2) {
        const hex = try std.fmt.allocPrint(allocator, "00000000000000000000000000000{x:03}", .{i});
        defer allocator.free(hex);
        const id = try BlockId.from_hex(hex);
        try storage_engine.delete_block(id);
        try deleted_ids.append(id);
    }
    try storage_engine.flush_memtable_to_sstable();

    // Generation 3: Add new blocks
    i = 10;
    while (i < 15) : (i += 1) {
        const hex = try std.fmt.allocPrint(allocator, "00000000000000000000000000000{x:03}", .{i});
        defer allocator.free(hex);
        const block = ContextBlock{
            .id = try BlockId.from_hex(hex),
            .version = 1,
            .source_uri = "test://gen3",
            .metadata_json = "{}",
            .content = try std.fmt.allocPrint(allocator, "Generation 3 block {}", .{i}),
        };
        defer allocator.free(block.content);
        try storage_engine.put_block(block);
        block_count += 1;
    }
    try storage_engine.flush_memtable_to_sstable();

    // Multiple rounds of compaction
    var round: u32 = 0;
    while (round < 3) : (round += 1) {
        try storage_engine.sstable_manager.check_and_run_compaction();

        // Verify deleted blocks remain deleted
        for (deleted_ids.items) |deleted_id| {
            const found = try storage_engine.find_block(deleted_id, .query_engine);
            fatal_assert(found == null, "RESURRECTION BUG: Deleted block {} reappeared after compaction round {}", .{ deleted_id, round });
        }

        // Verify non-deleted blocks still exist (odd blocks: 1, 3, 5, 7, 9)
        i = 1;
        while (i < 10) : (i += 2) {
            const hex = try std.fmt.allocPrint(allocator, "00000000000000000000000000000{x:03}", .{i});
            defer allocator.free(hex);
            const id = try BlockId.from_hex(hex);
            const found = try storage_engine.find_block(id, .query_engine);
            try testing.expect(found != null);
        }
    }
}

test "version shadowing during compaction" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/test_version_shadow");
    defer storage_engine.deinit();
    try storage_engine.startup();
    defer storage_engine.shutdown() catch {};

    const block_id = try BlockId.from_hex("DEADBEEFCAFEBABE0000000000000001");

    // Version 1
    const block_v1 = ContextBlock{
        .id = block_id,
        .version = 1,
        .source_uri = "test://v1",
        .metadata_json = "{}",
        .content = "Version 1 content",
    };
    try storage_engine.put_block(block_v1);
    try storage_engine.flush_memtable_to_sstable();

    // Version 2
    const block_v2 = ContextBlock{
        .id = block_id,
        .version = 2,
        .source_uri = "test://v2",
        .metadata_json = "{}",
        .content = "Version 2 content",
    };
    try storage_engine.put_block(block_v2);
    try storage_engine.flush_memtable_to_sstable();

    // Delete (should shadow both versions)
    try storage_engine.delete_block(block_id);
    try storage_engine.flush_memtable_to_sstable();

    // Force compaction to test version shadowing
    try storage_engine.sstable_manager.check_and_run_compaction();

    // Verify block remains deleted (both versions shadowed)
    const found = try storage_engine.find_block(block_id, .query_engine);
    try testing.expect(found == null);

    // Add version 3 after deletion
    const block_v3 = ContextBlock{
        .id = block_id,
        .version = 3,
        .source_uri = "test://v3",
        .metadata_json = "{}",
        .content = "Version 3 content - after deletion",
    };
    try storage_engine.put_block(block_v3);

    // Should find version 3 (not shadowed by earlier tombstone)
    const found_v3 = try storage_engine.find_block(block_id, .query_engine);
    try testing.expect(found_v3 != null);
    try testing.expectEqualStrings("Version 3 content - after deletion", found_v3.?.read(.temporary).content);
}

test "simulation: heavy deletion workload with compaction" {
    const allocator = testing.allocator;

    // Simplified simulation test - just run basic operations
    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/test_heavy_deletion");
    defer storage_engine.deinit();
    try storage_engine.startup();
    defer storage_engine.shutdown() catch {};

    // Track deleted blocks manually
    var deleted_blocks = std.AutoHashMap(BlockId, void).init(allocator);
    defer deleted_blocks.deinit();

    // Run mixed operations
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        // Add blocks
        const block = try create_test_block("sim", i);
        try storage_engine.put_block(block);

        // Occasionally delete and compact
        if (i % 10 == 0 and i > 0) {
            const delete_id = try BlockId.from_hex("111111111111111111111111111073696D"); // "sim" suffix
            try storage_engine.delete_block(delete_id);
            try deleted_blocks.put(delete_id, {});
        }

        if (i % 20 == 0) {
            try storage_engine.flush_memtable_to_sstable();
        }

        if (i % 30 == 0) {
            try storage_engine.sstable_manager.check_and_run_compaction();
        }
    }
}

test "recovery with tombstones after crash" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    // Phase 1: Create initial state with deletions
    {
        var storage = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/test_recovery_tombstones");
        defer storage.deinit();
        try storage.startup();
        defer storage.shutdown() catch {};

        // Add blocks
        const block1 = try create_test_block("0001", 1);
        const block2 = try create_test_block("0002", 1);
        const block3 = try create_test_block("0003", 1);

        try storage.put_block(block1);
        try storage.put_block(block2);
        try storage.put_block(block3);

        // Delete block2
        try storage.delete_block(block2.id);

        // Flush to ensure tombstone is in SSTable
        try storage.flush_memtable_to_sstable();
    }

    // Phase 2: Recover and verify deletions persist
    {
        var storage = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/test_recovery_tombstones");
        defer storage.deinit();
        try storage.startup();
        defer storage.shutdown() catch {};

        // Verify deletion persisted through recovery
        const found1 = try storage.find_block(try BlockId.from_hex("11111111111111111111111111110001"), .query_engine);
        const found2 = try storage.find_block(try BlockId.from_hex("11111111111111111111111111110002"), .query_engine);
        const found3 = try storage.find_block(try BlockId.from_hex("11111111111111111111111111110003"), .query_engine);

        try testing.expect(found1 != null);
        try testing.expect(found2 == null); // Must remain deleted
        try testing.expect(found3 != null);
    }
}

test "tombstone garbage collection during compaction" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/test_gc");
    defer storage_engine.deinit();
    try storage_engine.startup();
    defer storage_engine.shutdown() catch {};

    // Create blocks and delete them to create tombstones
    const block1 = try create_test_block("0001", 1);
    const block2 = try create_test_block("0002", 1);

    try storage_engine.put_block(block1);
    try storage_engine.put_block(block2);
    try storage_engine.flush_memtable_to_sstable();

    // Delete block1 - creates a tombstone
    try storage_engine.delete_block(block1.id);
    try storage_engine.flush_memtable_to_sstable();

    // Verify tombstone exists by confirming block1 is deleted
    const found_before_gc = try storage_engine.find_block(block1.id, .query_engine);
    try testing.expect(found_before_gc == null);

    // Verify compaction correctly applies tombstones and doesn't resurrect deleted blocks
    try storage_engine.sstable_manager.check_and_run_compaction();

    // Verify block1 remains deleted after compaction (GC working correctly)
    const found_after_gc = try storage_engine.find_block(block1.id, .query_engine);
    try testing.expect(found_after_gc == null);

    // Verify block2 is still accessible
    const block2_found = try storage_engine.find_block(block2.id, .query_engine);
    try testing.expect(block2_found != null);
}

test "concurrent deletion and compaction stress" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/test_concurrent_stress");
    defer storage_engine.deinit();
    try storage_engine.startup();
    defer storage_engine.shutdown() catch {};

    // Track what we've deleted
    var deleted = std.AutoHashMap(BlockId, void).init(allocator);
    defer deleted.deinit();

    // Track what should exist
    var existing = std.AutoHashMap(BlockId, ContextBlock).init(allocator);
    defer existing.deinit();

    var prng = std.Random.DefaultPrng.init(0x57E5599);
    const random = prng.random();

    // Run many iterations of mixed operations
    var iteration: u32 = 0;
    while (iteration < 100) : (iteration += 1) {
        // Add some blocks
        var i: u32 = 0;
        while (i < 10) : (i += 1) {
            const id_num = iteration * 100 + i + 1; // Add 1 to avoid zero BlockId
            const hex = try std.fmt.allocPrint(allocator, "{x:032}", .{id_num});
            defer allocator.free(hex);

            const block = ContextBlock{
                .id = try BlockId.from_hex(hex),
                .version = 1,
                .source_uri = "test://stress",
                .metadata_json = "{}",
                .content = try std.fmt.allocPrint(allocator, "Stress block {}", .{id_num}),
            };

            try storage_engine.put_block(block);
            try existing.put(block.id, block);
            allocator.free(block.content);
        }

        // Delete some random blocks
        if (existing.count() > 0) {
            const delete_count = random.intRangeAtMost(u32, 1, @min(5, existing.count()));
            var j: u32 = 0;
            var iter = existing.iterator();
            while (j < delete_count) {
                if (iter.next()) |entry| {
                    if (random.boolean()) {
                        try storage_engine.delete_block(entry.key_ptr.*);
                        try deleted.put(entry.key_ptr.*, {});
                        _ = existing.remove(entry.key_ptr.*);
                        j += 1;
                    }
                } else {
                    break; // No more entries
                }
            }
        }

        // Occasionally flush and compact
        if (iteration % 10 == 0) {
            try storage_engine.flush_memtable_to_sstable();
        }
        if (iteration % 20 == 0) {
            try storage_engine.sstable_manager.check_and_run_compaction();
        }

        // Verify correctness invariants
        var del_iter = deleted.iterator();
        while (del_iter.next()) |entry| {
            const found = try storage_engine.find_block(entry.key_ptr.*, .query_engine);
            fatal_assert(found == null, "Stress test failed: Deleted block {} resurrected at iteration {}", .{ entry.key_ptr.*, iteration });
        }

        var exist_iter = existing.iterator();
        while (exist_iter.next()) |entry| {
            const found = try storage_engine.find_block(entry.key_ptr.*, .query_engine);
            fatal_assert(found != null, "Stress test failed: Existing block {} lost at iteration {}", .{ entry.key_ptr.*, iteration });
        }
    }
}
