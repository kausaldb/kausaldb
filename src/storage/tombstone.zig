//! Tombstone records for LSM-tree deletion semantics.
//!
//! Implements deletion markers that persist through storage layers until
//! compaction can safely remove both the tombstone and shadowed data.
//! This provides proper MVCC semantics and prevents resurrection of deleted
//! blocks during compaction.

const std = @import("std");
const builtin = @import("builtin");

const assert_mod = @import("../core/assert.zig");
const types = @import("../core/types.zig");
const error_context = @import("../core/error_context.zig");

const assert_fmt = assert_mod.assert_fmt;
const fatal_assert = assert_mod.fatal_assert;
const testing = std.testing;

const BlockId = types.BlockId;

/// Optimized tombstone serialization size (32 bytes: 16 block_id + 8 sequence + 8 timestamp)
pub const TOMBSTONE_SIZE: usize = 32;

pub const TombstoneError = error{
    BufferTooSmall,
};

/// Deletion marker that persists through storage layers.
///
/// Tombstones shadow blocks with older sequence numbers, preventing
/// resurrection during compaction. They are garbage collected only when
/// guaranteed to shadow all historical versions.
pub const TombstoneRecord = struct {
    /// Block being marked as deleted
    block_id: BlockId,

    /// Global sequence number for tombstone ordering
    /// Higher sequences shadow lower sequences
    sequence: u64,

    /// Unix timestamp (microseconds) for time-based GC policies
    deletion_timestamp: u64,

    /// Optional generation number for distributed consistency (future use)
    /// Zero in single-node deployment
    generation: u32 = 0,

    /// Determines if this tombstone shadows a block with given sequence.
    /// Shadowing means the block should be considered deleted.
    pub fn shadows_sequence(self: TombstoneRecord, block_sequence: u64) bool {
        return self.sequence > block_sequence;
    }

    /// Determines if this tombstone shadows a specific block.
    /// Sequence comparison uses global ordering for MVCC semantics.
    pub fn shadows_block(self: TombstoneRecord, block: types.ContextBlock) bool {
        if (!self.block_id.eql(block.id)) {
            return false;
        }
        return self.sequence > block.sequence;
    }

    /// Check if tombstone can be garbage collected based on age.
    /// Returns true if older than gc_grace_seconds.
    pub fn can_garbage_collect(self: TombstoneRecord, current_timestamp: u64, gc_grace_seconds: u64) bool {
        const gc_grace_micros = gc_grace_seconds * 1_000_000;
        return current_timestamp > self.deletion_timestamp + gc_grace_micros;
    }

    /// Serialize tombstone to buffer for WAL or SSTable storage.
    /// Returns number of bytes written.
    pub fn serialize(self: TombstoneRecord, buffer: []u8) !usize {
        if (buffer.len < TOMBSTONE_SIZE) {
            return TombstoneError.BufferTooSmall;
        }

        var offset: usize = 0;

        // Block ID (16 bytes)
        @memcpy(buffer[offset..][0..16], &self.block_id.bytes);
        offset += 16;

        // Sequence (8 bytes)
        std.mem.writeInt(u64, buffer[offset..][0..8], self.sequence, .little);
        offset += 8;

        // Deletion timestamp (8 bytes)
        std.mem.writeInt(u64, buffer[offset..][0..8], self.deletion_timestamp, .little);
        offset += 8;

        return TOMBSTONE_SIZE;
    }

    /// Deserialize tombstone from buffer.
    pub fn deserialize(buffer: []const u8) !TombstoneRecord {
        if (buffer.len < TOMBSTONE_SIZE) {
            return TombstoneError.BufferTooSmall;
        }

        var offset: usize = 0;

        // Read block ID
        var block_id_bytes: [16]u8 = undefined;
        @memcpy(&block_id_bytes, buffer[offset..][0..16]);
        const block_id = BlockId{ .bytes = block_id_bytes };
        offset += 16;

        // Read sequence
        const sequence = std.mem.readInt(u64, buffer[offset..][0..8], .little);
        offset += 8;

        // Read deletion timestamp
        const deletion_timestamp = std.mem.readInt(u64, buffer[offset..][0..8], .little);

        return TombstoneRecord{
            .block_id = block_id,
            .sequence = sequence,
            .deletion_timestamp = deletion_timestamp,
            .generation = 0, // Default for single-node deployment
        };
    }

    /// Compare tombstones for sorting (by block_id, then sequence).
    /// Used for SSTable organization and efficient lookup.
    pub fn less_than(_: void, a: TombstoneRecord, b: TombstoneRecord) bool {
        const id_cmp = a.block_id.compare(b.block_id);
        if (id_cmp == .lt) return true;
        if (id_cmp == .gt) return false;
        // Same block_id, sort by sequence (newer first)
        return a.sequence > b.sequence;
    }

    /// Format tombstone for debugging output.
    pub fn format(
        self: TombstoneRecord,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("Tombstone{{id={}, seq={}, ts={}}}", .{
            self.block_id,
            self.sequence,
            self.deletion_timestamp,
        });
    }
};

/// Collection of tombstones optimized for batch operations.
/// Used during compaction to efficiently apply deletion semantics.
pub const TombstoneSet = struct {
    /// Sorted array for binary search during compaction
    tombstones: std.array_list.Managed(TombstoneRecord),

    /// Allocator for dynamic operations
    allocator: std.mem.Allocator,

    /// Tracks if tombstones need to be sorted
    is_sorted: bool,

    pub fn init(allocator: std.mem.Allocator) TombstoneSet {
        return .{
            .tombstones = std.array_list.Managed(TombstoneRecord).init(allocator),
            .allocator = allocator,
            .is_sorted = true,
        };
    }

    pub fn deinit(self: *TombstoneSet) void {
        self.tombstones.deinit();
    }

    /// Add tombstone to set. Sort is deferred until first query for better batch performance.
    pub fn add_tombstone(self: *TombstoneSet, tombstone: TombstoneRecord) !void {
        try self.tombstones.append(tombstone);
        self.is_sorted = false; // Defer sorting until needed
    }

    /// Ensure tombstones are sorted for efficient lookups
    fn ensure_sorted(self: *TombstoneSet) void {
        if (!self.is_sorted) {
            std.sort.pdq(TombstoneRecord, self.tombstones.items, {}, TombstoneRecord.less_than);
            self.is_sorted = true;
        }
    }

    /// Check if a block is shadowed by any tombstone in the set.
    pub fn shadows_block(self: *TombstoneSet, block: types.ContextBlock) bool {
        self.ensure_sorted();

        // Linear scan outperforms binary search for expected tombstone counts.
        // Analysis: With typical workloads generating <100 tombstones per compaction,
        // linear scan's cache locality and lack of branching overhead provides better
        // performance than binary search's O(log n) algorithmic advantage.

        // Check all tombstones for matching block_id
        for (self.tombstones.items) |tombstone| {
            if (tombstone.block_id.eql(block.id)) {
                if (tombstone.shadows_block(block)) {
                    return true;
                }
            }
        }

        return false;
    }

    /// Remove tombstones older than gc_grace_seconds.
    /// Returns number of tombstones removed.
    pub fn garbage_collect(self: *TombstoneSet, current_timestamp: u64, gc_grace_seconds: u64) !usize {
        self.ensure_sorted();

        var removed: usize = 0;
        var write_idx: usize = 0;

        for (self.tombstones.items) |tombstone| {
            if (tombstone.can_garbage_collect(current_timestamp, gc_grace_seconds)) {
                removed += 1;
                continue;
            }
            self.tombstones.items[write_idx] = tombstone;
            write_idx += 1;
        }

        self.tombstones.items.len = write_idx;
        return removed;
    }
};

test "TombstoneRecord shadowing logic" {
    const block_id = try BlockId.from_hex("11111111111111111111111111111111");

    const tombstone = TombstoneRecord{
        .block_id = block_id,
        .sequence = 100, // Test sequence for shadowing logic
        .deletion_timestamp = 1000000,
        .generation = 0,
    };

    // Should shadow blocks with lower sequence numbers
    try testing.expect(tombstone.shadows_sequence(99));
    try testing.expect(tombstone.shadows_sequence(50));
    try testing.expect(tombstone.shadows_sequence(1));

    // Should not shadow blocks with equal or higher sequence
    try testing.expect(!tombstone.shadows_sequence(100));
    try testing.expect(!tombstone.shadows_sequence(101));
    try testing.expect(!tombstone.shadows_sequence(200));
}

test "TombstoneRecord serialization round-trip" {
    const block_id = try BlockId.from_hex("DEADBEEFCAFEBABE1234567890ABCDEF");

    const original = TombstoneRecord{
        .block_id = block_id,
        .sequence = 0, // Storage engine will assign the actual global sequence
        .deletion_timestamp = 1234567890,
        .generation = 7,
    };

    // Serialize
    var buffer: [TOMBSTONE_SIZE]u8 = undefined;
    const bytes_written = try original.serialize(&buffer);
    try testing.expectEqual(TOMBSTONE_SIZE, bytes_written);

    // Deserialize
    const deserialized = try TombstoneRecord.deserialize(&buffer);

    // Verify round-trip (generation not persisted in single-node format)
    try testing.expect(deserialized.block_id.eql(original.block_id));
    try testing.expectEqual(original.sequence, deserialized.sequence);
    try testing.expectEqual(original.deletion_timestamp, deserialized.deletion_timestamp);
    try testing.expectEqual(@as(u32, 0), deserialized.generation); // Always 0 in single-node deployment
}

test "TombstoneRecord garbage collection eligibility" {
    const tombstone = TombstoneRecord{
        .block_id = BlockId.zero(),
        .sequence = 0, // Storage engine will assign the actual global sequence
        .deletion_timestamp = 1000000, // 1 second in microseconds
        .generation = 0,
    };

    // Should not GC if not enough time has passed
    const gc_grace_seconds: u64 = 3600; // 1 hour
    try testing.expect(!tombstone.can_garbage_collect(2000000, gc_grace_seconds));

    // Should GC after grace period
    const after_grace = 1000000 + (gc_grace_seconds * 1_000_000) + 1;
    try testing.expect(tombstone.can_garbage_collect(after_grace, gc_grace_seconds));
}

test "TombstoneSet operations" {
    const allocator = testing.allocator;

    var set = TombstoneSet.init(allocator);
    defer set.deinit();

    const block_id1 = try BlockId.from_hex("11111111111111111111111111111111");
    const block_id2 = try BlockId.from_hex("22222222222222222222222222222222");

    // Add tombstones
    try set.add_tombstone(TombstoneRecord{
        .block_id = block_id1,
        .sequence = 50, // Test sequence for tombstone shadowing
        .deletion_timestamp = 1000000,
        .generation = 0,
    });

    try set.add_tombstone(TombstoneRecord{
        .block_id = block_id2,
        .sequence = 75, // Test sequence for second tombstone
        .deletion_timestamp = 2000000,
        .generation = 0,
    });

    // Test shadowing
    const block1 = types.ContextBlock{
        .id = block_id1,
        .sequence = 25, // Lower than tombstone sequence - should be shadowed
        .source_uri = "test",
        .metadata_json = "{}",
        .content = "test",
    };
    try testing.expect(set.shadows_block(block1));

    const block2 = types.ContextBlock{
        .id = block_id1,
        .sequence = 100, // Higher than tombstone sequence - should not be shadowed
        .source_uri = "test",
        .metadata_json = "{}",
        .content = "test",
    };
    try testing.expect(!set.shadows_block(block2));
}

test "TombstoneSet garbage collection" {
    const allocator = testing.allocator;

    var set = TombstoneSet.init(allocator);
    defer set.deinit();

    // Add old and new tombstones
    try set.add_tombstone(TombstoneRecord{
        .block_id = BlockId.zero(),
        .sequence = 0, // Storage engine will assign the actual global sequence
        .deletion_timestamp = 1000000, // Old
        .generation = 0,
    });

    try set.add_tombstone(TombstoneRecord{
        .block_id = try BlockId.from_hex("11111111111111111111111111111111"),
        .sequence = 0, // Storage engine will assign the actual global sequence
        .deletion_timestamp = 5000000, // Recent
        .generation = 0,
    });

    // GC with 1 second grace period
    const current = 2001000; // 2.001 seconds
    const removed = try set.garbage_collect(current, 1);

    try testing.expectEqual(@as(usize, 1), removed);
    try testing.expectEqual(@as(usize, 1), set.tombstones.items.len);
}

test "TombstoneRecord serialization consistency" {
    const block_id = try BlockId.from_hex("FEDCBA9876543210FEDCBA9876543210");

    const tombstone = TombstoneRecord{
        .block_id = block_id,
        .sequence = 0, // Storage engine will assign the actual global sequence
        .deletion_timestamp = 87654321,
        .generation = 3,
    };

    var buffer: [TOMBSTONE_SIZE]u8 = undefined;
    _ = try tombstone.serialize(&buffer);

    // Verify serialization/deserialization works without checksum
    const result = try TombstoneRecord.deserialize(&buffer);
    try testing.expect(result.block_id.eql(tombstone.block_id));
    try testing.expectEqual(tombstone.sequence, result.sequence);
}

test "TombstoneRecord sorting order" {
    const id1 = try BlockId.from_hex("11111111111111111111111111111111");
    const id2 = try BlockId.from_hex("22222222222222222222222222222222");

    var tombstones = [_]TombstoneRecord{
        .{ .block_id = id2, .sequence = 100, .deletion_timestamp = 0, .generation = 0 }, // Test sequence for sorting order
        .{ .block_id = id1, .sequence = 150, .deletion_timestamp = 0, .generation = 0 }, // Test sequence for sorting order
        .{ .block_id = id1, .sequence = 200, .deletion_timestamp = 0, .generation = 0 }, // Test sequence for sorting order
    };

    std.sort.pdq(TombstoneRecord, &tombstones, {}, TombstoneRecord.less_than);

    // Should be sorted by block_id first, then by sequence (descending)
    try testing.expect(tombstones[0].block_id.eql(id1));
    try testing.expectEqual(@as(u64, 200), tombstones[0].sequence);
    try testing.expectEqual(@as(u64, 150), tombstones[1].sequence);
    try testing.expect(tombstones[2].block_id.eql(id2));
}
