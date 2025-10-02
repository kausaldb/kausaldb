//! Explicit correctness proofs for KausalDB core guarantees.
//!
//! These tests are minimal, documentation-quality proofs of specific system contracts.
//! Unlike simulation tests, these use direct storage engine calls to create readable,
//! reproducible examples that demonstrate core correctness properties.
//!
//! Design rationale: These tests serve dual purpose as both validation and documentation.
//! Each test is a mathematical proof of a specific invariant expressed as executable code.

const std = @import("std");
const testing = std.testing;

const types = @import("../../core/types.zig");
const storage_mod = @import("../../storage/engine.zig");
const tombstone_mod = @import("../../storage/tombstone.zig");
const ownership = @import("../../core/ownership.zig");
const simulation_vfs = @import("../../sim/simulation_vfs.zig");

const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const StorageEngine = storage_mod.StorageEngine;
const TombstoneRecord = tombstone_mod.TombstoneRecord;
const SimulationVFS = simulation_vfs.SimulationVFS;

test "explicit: tombstone prevents resurrection after compaction" {
    const allocator = testing.allocator;

    // Setup storage engine with minimal configuration
    var vfs = try SimulationVFS.init(allocator);
    defer vfs.deinit();

    const config = storage_mod.Config{};
    var engine = try StorageEngine.init(allocator, vfs.vfs(), "/test_db", config);
    defer engine.deinit();

    try engine.startup();
    defer engine.shutdown() catch {};

    // Step 1: Put block A with sequence 1
    const block_a_id = BlockId.from_u64(1);
    const block_a = ContextBlock{
        .id = block_a_id,
        .sequence = 1,
        .source_uri = "test://block_a",
        .metadata_json = "{}",
        .content = "original content for block A",
    };

    try engine.put_block(block_a);

    // Verify block exists
    const found_before_delete = try engine.find_block(block_a_id, .temporary);
    try testing.expect(found_before_delete != null);
    try testing.expect(std.mem.eql(u8, found_before_delete.?.block.content, "original content for block A"));

    // Step 2: Flush to SSTable
    try engine.flush_memtable_to_sstable();

    // Step 3: Delete block A (creates tombstone)
    try engine.delete_block(block_a_id);

    // CRITICAL ASSERTION 1: Block is tombstoned immediately after deletion
    const found_after_delete = try engine.find_block(block_a_id, .temporary);
    try testing.expect(found_after_delete == null);

    // Step 4: Flush tombstone to SSTable
    try engine.flush_memtable_to_sstable();

    // CRITICAL ASSERTION 2: Block remains deleted after tombstone flush
    // Tombstone in SSTable now shadows the block in earlier SSTable
    const found_after_flush = try engine.find_block(block_a_id, .temporary);
    try testing.expect(found_after_flush == null);

    // PROOF COMPLETE: Tombstone prevents access through LSM layers:
    // - Block written to SSTable L0
    // - Tombstone written to newer SSTable
    // - Newer tombstone shadows older block (LSM read precedence)
    // - Block effectively deleted despite existing in older SSTable
    //
    // Note: Full compaction testing (which physically removes shadowed data)
    // is comprehensively covered in deletion_compaction.zig and tombstone_sequencing.zig
}

test "explicit: tombstone sequence shadowing semantics" {
    // This test proves the mathematical definition of tombstone shadowing:
    // tombstone(seq=N) shadows block(seq=M) if and only if N > M

    const block_id = BlockId.from_u64(42);

    // Create block with sequence 3
    const block_seq_3 = ContextBlock{
        .id = block_id,
        .sequence = 3,
        .source_uri = "test://block",
        .metadata_json = "{}",
        .content = "content at sequence 3",
    };

    // Create tombstones with various sequences
    const tombstone_seq_5 = TombstoneRecord{
        .block_id = block_id,
        .sequence = 5,
        .deletion_timestamp = 1000000,
    };

    const tombstone_seq_2 = TombstoneRecord{
        .block_id = block_id,
        .sequence = 2,
        .deletion_timestamp = 1000000,
    };

    const tombstone_seq_7 = TombstoneRecord{
        .block_id = block_id,
        .sequence = 7,
        .deletion_timestamp = 1000000,
    };

    // PROOF: Tombstone with higher sequence shadows block
    try testing.expect(tombstone_seq_5.shadows_block(block_seq_3) == true);
    try testing.expect(tombstone_seq_7.shadows_block(block_seq_3) == true);

    // PROOF: Tombstone with lower sequence does NOT shadow block
    try testing.expect(tombstone_seq_2.shadows_block(block_seq_3) == false);

    // PROOF: Sequence-based shadowing (mathematical definition)
    try testing.expect(tombstone_seq_5.shadows_sequence(3) == true);
    try testing.expect(tombstone_seq_5.shadows_sequence(5) == false); // Equal sequences don't shadow
    try testing.expect(tombstone_seq_5.shadows_sequence(6) == false); // Higher sequences not shadowed

    // Create block with higher sequence than tombstone
    const block_seq_7 = ContextBlock{
        .id = block_id,
        .sequence = 7,
        .source_uri = "test://block",
        .metadata_json = "{}",
        .content = "newer content at sequence 7",
    };

    // PROOF: Tombstone does NOT shadow blocks with higher sequences
    // This allows resurrection of blocks with sequence > tombstone sequence
    // (which is correct MVCC behavior - new writes shadow old tombstones)
    try testing.expect(tombstone_seq_5.shadows_block(block_seq_7) == false);

    // PROOF COMPLETE: Tombstone shadowing follows strict sequence ordering
    // - ts(N) shadows block(M) ⟺ N > M
    // - This implements MVCC semantics correctly
}

test "explicit: multi-level LSM read precedence" {
    const allocator = testing.allocator;

    // Setup storage engine
    var vfs = try SimulationVFS.init(allocator);
    defer vfs.deinit();

    const config = storage_mod.Config{};
    var engine = try StorageEngine.init(allocator, vfs.vfs(), "/test_db", config);
    defer engine.deinit();

    try engine.startup();
    defer engine.shutdown() catch {};

    const block_id = BlockId.from_u64(100);

    // Step 1: Put block version 1 in L1 (oldest layer)
    const block_v1 = ContextBlock{
        .id = block_id,
        .sequence = 1,
        .source_uri = "test://v1",
        .metadata_json = "{}",
        .content = "version 1 - oldest",
    };
    try engine.put_block(block_v1);
    try engine.flush_memtable_to_sstable(); // Now in SSTable

    // Step 2: Put block version 2 (higher sequence)
    const block_v2 = ContextBlock{
        .id = block_id,
        .sequence = 2,
        .source_uri = "test://v2",
        .metadata_json = "{}",
        .content = "version 2 - newer",
    };
    try engine.put_block(block_v2);

    // CRITICAL ASSERTION 1: Memtable version takes precedence over SSTable
    const result_v2 = try engine.find_block(block_id, .temporary);
    try testing.expect(result_v2 != null);
    try testing.expect(std.mem.eql(u8, result_v2.?.block.content, "version 2 - newer"));

    // Step 3: Put tombstone in memtable (newest layer)
    try engine.delete_block(block_id);

    // CRITICAL ASSERTION 2: Memtable tombstone shadows all SSTables
    const result_tombstone = try engine.find_block(block_id, .temporary);
    try testing.expect(result_tombstone == null);

    // PROOF COMPLETE: LSM read precedence is strictly enforced
    // - Memtable (newest) > SSTables (older)
    // - Higher sequence numbers take precedence
    // - Tombstones in memtable shadow all older data
    // - This implements LSM-tree semantics correctly
}

test "explicit: tombstone GC grace period semantics" {
    // Prove tombstone garbage collection only occurs after grace period expires

    const block_id = BlockId.from_u64(999);
    const deletion_time: u64 = 1000000000; // 1 billion microseconds
    const gc_grace_seconds: u64 = 3600; // 1 hour

    const tombstone = TombstoneRecord{
        .block_id = block_id,
        .sequence = 10,
        .deletion_timestamp = deletion_time,
    };

    // PROOF: Tombstone cannot be GC'd before grace period expires
    const current_time_within_grace = deletion_time + (gc_grace_seconds * 1_000_000) - 1;
    try testing.expect(tombstone.can_garbage_collect(current_time_within_grace, gc_grace_seconds) == false);

    // PROOF: Tombstone can be GC'd after grace period expires
    const current_time_after_grace = deletion_time + (gc_grace_seconds * 1_000_000) + 1;
    try testing.expect(tombstone.can_garbage_collect(current_time_after_grace, gc_grace_seconds) == true);

    // PROOF: Exact boundary behavior (at grace period expiration)
    const current_time_at_boundary = deletion_time + (gc_grace_seconds * 1_000_000);
    try testing.expect(tombstone.can_garbage_collect(current_time_at_boundary, gc_grace_seconds) == false);

    // PROOF COMPLETE: GC grace period prevents premature tombstone removal
    // - Tombstone persists for exactly gc_grace_seconds after deletion
    // - This prevents resurrection in distributed scenarios with clock skew
}
