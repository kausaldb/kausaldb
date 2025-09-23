//! In-memory block index for the KausalDB memtable.
//!
//! This module provides fast insertion, lookup, and deletion of blocks using a HashMap
//! backed by arena allocation for content storage. Follows the arena refresh pattern
//! to eliminate dangling allocator references and enable O(1) bulk memory cleanup.

const builtin = @import("builtin");
const std = @import("std");

const context_block = @import("../core/types.zig");
const memory = @import("../core/memory.zig");
const ownership = @import("../core/ownership.zig");
const assert_mod = @import("../core/assert.zig");
const tombstone = @import("tombstone.zig");

const assert = assert_mod.assert;
const assert_fmt = assert_mod.assert_fmt;
const fatal_assert = assert_mod.fatal_assert;

const ArenaCoordinator = memory.ArenaCoordinator;
const BlockId = context_block.BlockId;
const BlockOwnership = ownership.BlockOwnership;
const ContextBlock = context_block.ContextBlock;
const OwnedBlock = ownership.OwnedBlock;
const TombstoneRecord = tombstone.TombstoneRecord;

/// In-memory block index using Arena Coordinator Pattern for efficient bulk operations.
/// Provides fast writes and reads while maintaining O(1) memory cleanup through
/// arena coordinator reset. Uses type-safe OwnedBlock system and stable coordinator interface.
///
/// Arena Coordinator Pattern: BlockIndex uses stable coordinator interface for all content
/// allocation, eliminating temporal coupling with arena resets. HashMap uses stable
/// backing allocator while content uses coordinator's current arena state.
pub const BlockIndex = struct {
    blocks: std.HashMap(
        BlockId,
        OwnedBlock,
        BlockIdContext,
        std.hash_map.default_max_load_percentage,
    ),
    tombstones: std.HashMap(
        BlockId,
        TombstoneRecord,
        BlockIdContext,
        std.hash_map.default_max_load_percentage,
    ),
    /// Arena coordinator pointer for stable allocation access (remains valid across arena resets)
    /// CRITICAL: Must be pointer to prevent coordinator struct copying corruption
    arena_coordinator: *const ArenaCoordinator,
    /// Stable backing allocator for HashMap structure
    backing_allocator: std.mem.Allocator,
    /// Track total memory used by block content strings in arena.
    /// Excludes HashMap overhead to provide clean flush threshold calculations.
    memory_used: u64,

    /// Hash context for BlockId keys in HashMap.
    /// Uses Wyhash for performance with cryptographically strong distribution.
    pub const BlockIdContext = struct {
        pub fn hash(self: @This(), block_id: BlockId) u64 {
            _ = self;
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(&block_id.bytes);
            return hasher.final();
        }

        pub fn eql(self: @This(), a: BlockId, b: BlockId) bool {
            _ = self;
            return a.eql(b);
        }
    };

    /// Initialize empty block index following Arena Coordinator Pattern.
    /// HashMap uses stable backing allocator while content uses coordinator interface
    /// to prevent dangling allocator references after arena resets.
    /// CRITICAL: ArenaCoordinator must be passed by pointer to prevent struct copying corruption.
    pub fn init(coordinator: *const ArenaCoordinator, backing: std.mem.Allocator) BlockIndex {
        const blocks = std.HashMap(
            BlockId,
            OwnedBlock,
            BlockIdContext,
            std.hash_map.default_max_load_percentage,
        ).init(backing);

        const tombstones = std.HashMap(
            BlockId,
            TombstoneRecord,
            BlockIdContext,
            std.hash_map.default_max_load_percentage,
        ).init(backing);

        return BlockIndex{
            .blocks = blocks, // HashMap uses stable backing allocator
            .tombstones = tombstones,
            .arena_coordinator = coordinator, // Stable coordinator interface
            .backing_allocator = backing,
            .memory_used = 0,
        };
    }

    /// Clean up BlockIndex resources following Arena Coordinator Pattern.
    /// Clears both blocks and tombstones HashMaps to prevent memory leaks.
    /// Content memory cleanup happens when coordinator resets its arena.
    pub fn deinit(self: *BlockIndex) void {
        self.blocks.clearAndFree();
        self.tombstones.clearAndFree();
        // Arena memory is owned by StorageEngine - no local cleanup needed
    }

    /// Insert or update a block in the index using coordinator's arena for content storage.
    /// Accepts ContextBlock and manages internal ownership tracking within the subsystem.
    pub fn put_block(self: *BlockIndex, block: ContextBlock) !void {
        // Safety: Converting pointer to integer for null pointer validation
        assert_fmt(@intFromPtr(self) != 0, "BlockIndex self pointer cannot be null", .{});

        // Skip per-operation validation to prevent performance regression
        // Validation is expensive (iterator + memory calculation + allocator testing)
        // and should only run during specific tests, not benchmarks or normal operation

        // Validate string lengths to prevent allocation of corrupted sizes
        assert_fmt(block.source_uri.len < 1024 * 1024, "source_uri too large: {} bytes", .{block.source_uri.len});
        assert_fmt(block.metadata_json.len < 1024 * 1024, "metadata_json too large: {} bytes", .{block.metadata_json.len});
        assert_fmt(block.content.len < 100 * 1024 * 1024, "content too large: {} bytes", .{block.content.len});

        // Catch null pointers masquerading as slices
        if (block.source_uri.len > 0) {
            // Safety: Converting pointer to integer for null pointer validation
            assert_fmt(@intFromPtr(block.source_uri.ptr) != 0, "source_uri has null pointer", .{});
        }
        if (block.metadata_json.len > 0) {
            // Safety: Converting pointer to integer for null pointer validation
            assert_fmt(@intFromPtr(block.metadata_json.ptr) != 0, "metadata_json has null pointer", .{});
        }
        if (block.content.len > 0) {
            // Safety: Converting pointer to integer for null pointer validation
            assert_fmt(@intFromPtr(block.content.ptr) != 0, "content has null pointer", .{});
        }

        // Clone all string content through arena coordinator for O(1) bulk deallocation
        // Large blocks use chunked copying to avoid cache misses during multi-MB allocations
        const cloned_block = if (block.content.len >= 512 * 1024) blk: {
            break :blk try self.clone_large_block(block);
        } else blk: {
            break :blk ContextBlock{
                .id = block.id,
                .sequence = block.sequence,
                .source_uri = try self.arena_coordinator.duplicate_slice(u8, block.source_uri),
                .metadata_json = try self.arena_coordinator.duplicate_slice(u8, block.metadata_json),
                .content = try self.arena_coordinator.duplicate_slice(u8, block.content),
            };
        };

        // Debug-time validation that coordinator correctly clones strings.
        // These checks ensure memory safety during development but compile to no-ops
        // in release builds for zero-overhead production performance.
        if (block.source_uri.len > 0) {
            assert_fmt(@intFromPtr(cloned_block.source_uri.ptr) != @intFromPtr(block.source_uri.ptr), "ArenaCoordinator failed to clone source_uri - returned original pointer", .{});
        }
        if (block.metadata_json.len > 0) {
            assert_fmt(@intFromPtr(cloned_block.metadata_json.ptr) != @intFromPtr(block.metadata_json.ptr), "ArenaCoordinator failed to clone metadata_json - returned original pointer", .{});
        }
        if (block.content.len > 0) {
            assert_fmt(@intFromPtr(cloned_block.content.ptr) != @intFromPtr(block.content.ptr), "ArenaCoordinator failed to clone content - returned original pointer", .{});
        }

        // Adjust memory accounting for replacement case
        // Calculate memory changes but don't update accounting until after HashMap operation succeeds
        var old_memory: usize = 0;
        if (self.blocks.get(cloned_block.id)) |existing_block| {
            const existing_data = existing_block.read(.memtable_manager);
            old_memory = existing_data.source_uri.len + existing_data.metadata_json.len + existing_data.content.len;
            fatal_assert(self.memory_used >= old_memory, "Memory accounting underflow: tracked={} removing={} - indicates heap corruption", .{ self.memory_used, old_memory });
        }

        const new_memory = cloned_block.source_uri.len + cloned_block.metadata_json.len + cloned_block.content.len;

        // Critical: Update HashMap first, then memory accounting to prevent corruption on allocation failure
        const memtable_owned_block = OwnedBlock.take_ownership(&cloned_block, .memtable_manager);
        try self.blocks.put(cloned_block.id, memtable_owned_block);

        // Update memory accounting only after successful HashMap operation
        self.memory_used = self.memory_used - old_memory + new_memory;

        // Skip per-operation validation to prevent performance regression
        // Per-operation validation causes 60-70% performance degradation in debug builds
        // Validation should be called explicitly when needed, not on every write
    }

    // REMOVED: put_block_temporary() method to eliminate raw block usage.
    // For legacy callers: use OwnedBlock.take_ownership(block, .temporary) then put_block()

    /// Find a block by ID.
    /// Returns block data if found and not tombstoned.
    pub fn find_block(self: *const BlockIndex, block_id: BlockId) ?ContextBlock {
        if (self.blocks.getPtr(block_id)) |owned_block_ptr| {
            const block = owned_block_ptr.read(.temporary).*;

            // Check if this specific block sequence is shadowed by a tombstone
            if (self.tombstones.get(block_id)) |tombstone_record| {
                if (tombstone_record.shadows_block(block)) {
                    return null;
                }
            }

            return block;
        }
        return null;
    }

    /// Remove a block from the index and update memory accounting.
    /// Arena memory cleanup happens at StorageEngine level through bulk reset.
    pub fn remove_block(self: *BlockIndex, block_id: BlockId) void {
        if (self.blocks.get(block_id)) |existing_block| {
            const block_data = existing_block.read(.memtable_manager);
            const old_memory = block_data.source_uri.len + block_data.metadata_json.len + block_data.content.len;
            fatal_assert(self.memory_used >= old_memory, "Memory accounting underflow during removal: tracked={} removing={} - indicates heap corruption", .{ self.memory_used, old_memory });
            self.memory_used -= old_memory;
        }
        _ = self.blocks.remove(block_id);
    }

    /// Clear all blocks in preparation for StorageEngine arena reset.
    /// Retains HashMap capacity for efficient reuse after StorageEngine resets arena.
    /// This is the key operation that enables O(1) bulk deallocation through StorageEngine.
    pub fn clear(self: *BlockIndex) void {
        fatal_assert(@intFromPtr(self) != 0, "BlockIndex self pointer is null - memory corruption detected", .{});

        // Skip per-operation validation to prevent performance regression
        // Clear operation validation is expensive and should be selective

        self.blocks.clearRetainingCapacity();
        // CRITICAL: Do NOT clear tombstones during flush - they must persist to prevent
        // data resurrection from older SSTables until compaction eliminates all shadowed sequences
        // Arena memory reset handled by StorageEngine - enables O(1) bulk cleanup
        self.memory_used = 0;

        // Validate cleared state in debug builds
        if (builtin.mode == .Debug) {
            fatal_assert(self.blocks.count() == 0, "Clear operation failed - blocks still present", .{});
            // Tombstones are intentionally preserved to prevent data resurrection from SSTables
            fatal_assert(self.memory_used == 0, "Clear operation failed - memory not reset", .{});
        }
    }

    /// Add tombstone record to mark block as deleted.
    /// Removes existing block if present to enforce tombstone shadowing.
    pub fn put_tombstone(self: *BlockIndex, tombstone_record: TombstoneRecord) !void {
        // Add tombstone first to ensure atomic visibility
        try self.tombstones.put(tombstone_record.block_id, tombstone_record);

        // Remove existing block after tombstone is safely added
        self.remove_block(tombstone_record.block_id);
    }

    /// Collect all tombstones for compaction processing.
    /// Caller owns returned slice and must free with provided allocator.
    pub fn collect_tombstones(self: *const BlockIndex, allocator: std.mem.Allocator) ![]TombstoneRecord {
        var tombstones_list = std.array_list.Managed(TombstoneRecord).init(allocator);
        defer tombstones_list.deinit();

        var iter = self.tombstones.iterator();
        while (iter.next()) |entry| {
            try tombstones_list.append(entry.value_ptr.*);
        }
        return tombstones_list.toOwnedSlice();
    }

    /// Large block cloning with chunked copy to improve cache locality.
    /// Standard dupe() performs large single allocations that can cause cache misses.
    /// Returns ContextBlock for unified ownership pattern with OwnedBlock wrapper.
    fn clone_large_block(self: *BlockIndex, block: ContextBlock) !ContextBlock {
        const content_buffer = try self.arena_coordinator.alloc(u8, block.content.len);

        // Chunked copying improves cache performance for multi-megabyte blocks
        const CHUNK_SIZE = 64 * 1024;
        if (block.content.len > CHUNK_SIZE) {
            var offset: usize = 0;
            while (offset < block.content.len) {
                const chunk_size = @min(CHUNK_SIZE, block.content.len - offset);
                @memcpy(content_buffer[offset .. offset + chunk_size], block.content[offset .. offset + chunk_size]);
                offset += chunk_size;
            }
        } else {
            @memcpy(content_buffer, block.content);
        }

        return ContextBlock{
            .id = block.id,
            .sequence = block.sequence,
            .source_uri = try self.arena_coordinator.duplicate_slice(u8, block.source_uri),
            .metadata_json = try self.arena_coordinator.duplicate_slice(u8, block.metadata_json),
            .content = content_buffer,
        };
    }

    /// Comprehensive invariant validation for debug builds.
    /// Validates all critical assumptions about BlockIndex internal state
    /// that could be violated by programming errors.
    pub fn validate_invariants(self: *const BlockIndex) void {
        if (builtin.mode == .Debug) {
            self.validate_memory_accounting();
            self.validate_coordinator_stability();
            self.validate_hash_consistency();
            self.validate_content_integrity();
        }
    }

    /// Validate memory accounting consistency - tracked vs actual usage.
    fn validate_memory_accounting(self: *const BlockIndex) void {
        var calculated_memory: u64 = 0;
        var iterator = self.blocks.iterator();
        while (iterator.next()) |entry| {
            const block_data = entry.value_ptr.read(.memtable_manager);
            calculated_memory += block_data.source_uri.len +
                block_data.metadata_json.len +
                block_data.content.len;
        }
        fatal_assert(self.memory_used == calculated_memory, "Memory accounting mismatch: tracked={} actual={}", .{ self.memory_used, calculated_memory });
    }

    /// Validate arena coordinator pointer stability.
    fn validate_coordinator_stability(self: *const BlockIndex) void {
        fatal_assert(@intFromPtr(self.arena_coordinator) != 0, "Arena coordinator pointer is null - struct copying corruption", .{});

        // Verify coordinator is still functional
        const test_alloc = self.arena_coordinator.alloc(u8, 1) catch {
            fatal_assert(false, "Arena coordinator non-functional - corruption detected", .{});
            return;
        };

        // Clean up test allocation immediately
        _ = test_alloc;
    }

    /// Validate HashMap consistency and detect corruption.
    fn validate_hash_consistency(self: *const BlockIndex) void {
        const expected_count = self.blocks.count();
        var actual_count: u32 = 0;

        var iterator = self.blocks.iterator();
        while (iterator.next()) |entry| {
            actual_count += 1;

            // Verify each block can be found by its ID
            const found = self.blocks.get(entry.key_ptr.*);
            fatal_assert(found != null, "Block ID corruption: stored block not findable by key", .{});
            const found_block_data = found.?.read(.memtable_manager);
            fatal_assert(found_block_data.id.eql(entry.key_ptr.*), "Block ID mismatch: key={any} stored={any}", .{ entry.key_ptr.*, found_block_data.id });
        }

        fatal_assert(actual_count == expected_count, "HashMap count corruption: expected={} actual={}", .{ expected_count, actual_count });
    }

    /// Validate content pointer integrity and detect memory corruption.
    fn validate_content_integrity(self: *const BlockIndex) void {
        var iterator = self.blocks.iterator();
        while (iterator.next()) |entry| {
            const block_data = entry.value_ptr.read(.memtable_manager);

            // Validate content pointers are not null for non-empty strings
            if (block_data.source_uri.len > 0) {
                fatal_assert(@intFromPtr(block_data.source_uri.ptr) != 0, "source_uri pointer corruption: null with length {}", .{block_data.source_uri.len});
            }
            if (block_data.metadata_json.len > 0) {
                fatal_assert(@intFromPtr(block_data.metadata_json.ptr) != 0, "metadata_json pointer corruption: null with length {}", .{block_data.metadata_json.len});
            }
            if (block_data.content.len > 0) {
                fatal_assert(@intFromPtr(block_data.content.ptr) != 0, "content pointer corruption: null with length {}", .{block_data.content.len});
            }

            // Validate string lengths are reasonable (detect corruption)
            fatal_assert(block_data.source_uri.len < 10 * 1024 * 1024, "source_uri length corruption: {} bytes too large", .{block_data.source_uri.len});
            fatal_assert(block_data.metadata_json.len < 10 * 1024 * 1024, "metadata_json length corruption: {} bytes too large", .{block_data.metadata_json.len});
            fatal_assert(block_data.content.len < 1024 * 1024 * 1024, "content length corruption: {} bytes too large", .{block_data.content.len});
        }
    }
};

const testing = std.testing;

// Test helper: Mock StorageEngine for unit tests

test "block index initialization creates empty index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const coordinator = ArenaCoordinator.init(&arena);
    var index = BlockIndex.init(&coordinator, testing.allocator);
    defer index.deinit();

    try testing.expectEqual(@as(u32, 0), @as(u32, @intCast(index.blocks.count())));
    try testing.expectEqual(@as(u64, 0), index.memory_used);
}

test "put and find block operations work correctly" {
    const allocator = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const coordinator = ArenaCoordinator.init(&arena);
    var index = BlockIndex.init(&coordinator, allocator);
    defer index.deinit();

    const block_id = BlockId.generate();
    const test_block = ContextBlock{
        .id = block_id,
        .sequence = 0, // Storage engine will assign the actual global sequence
        .source_uri = "test://example.zig",
        .metadata_json = "{}",
        .content = "test content",
    };

    try index.put_block(test_block);
    try testing.expectEqual(@as(u32, 1), @as(u32, @intCast(index.blocks.count())));

    const found_block = index.find_block(block_id);
    try testing.expect(found_block != null);
    try testing.expect(found_block.?.id.eql(block_id));
    try testing.expectEqualStrings("test content", found_block.?.content);
}

test "put block clones strings into arena" {
    const allocator = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const coordinator = ArenaCoordinator.init(&arena);
    var index = BlockIndex.init(&coordinator, allocator);
    defer index.deinit();

    const original_content = try allocator.dupe(u8, "original content");
    defer allocator.free(original_content);

    const block_id = BlockId.generate();
    const test_block = ContextBlock{
        .id = block_id,
        .sequence = 0, // Storage engine will assign the actual global sequence
        .source_uri = "test://example.zig",
        .metadata_json = "{}",
        .content = original_content,
    };

    try index.put_block(test_block);

    const found_block = index.find_block(block_id);
    try testing.expect(found_block != null);
    try testing.expectEqualStrings("original content", found_block.?.content);
    // Verify it's a different pointer (cloned, not original)
    try testing.expect(@intFromPtr(found_block.?.content.ptr) != @intFromPtr(original_content.ptr));
}

test "remove block updates count and memory accounting" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const coordinator = ArenaCoordinator.init(&arena);
    var index = BlockIndex.init(&coordinator, testing.allocator);
    defer index.deinit();

    const block_id = BlockId.generate();
    const test_block = ContextBlock{
        .id = block_id,
        .sequence = 0, // Storage engine will assign the actual global sequence
        .source_uri = "test://example.zig",
        .metadata_json = "{}",
        .content = "test content",
    };

    try index.put_block(test_block);
    const memory_before = index.memory_used;
    try testing.expect(memory_before > 0);

    index.remove_block(block_id);
    try testing.expectEqual(@as(u32, 0), @as(u32, @intCast(index.blocks.count())));
    try testing.expectEqual(@as(u64, 0), index.memory_used);
}

test "block replacement updates memory accounting correctly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const coordinator = ArenaCoordinator.init(&arena);
    var index = BlockIndex.init(&coordinator, testing.allocator);
    defer index.deinit();

    const block_id = BlockId.generate();
    const test_block = ContextBlock{
        .id = block_id,
        .sequence = 1, // Test sequence for memory accounting test
        .source_uri = "test://original.zig",
        .metadata_json = "{}",
        .content = "original content",
    };

    try index.put_block(test_block);
    const memory_after_first = index.memory_used;

    const replacement_block = ContextBlock{
        .id = block_id,
        .sequence = 2, // Test sequence for replacement validation
        .source_uri = "test://example.zig",
        .metadata_json = "{}",
        .content = "much longer content than before",
    };

    try index.put_block(replacement_block);
    const memory_after_second = index.memory_used;

    // Should still have 1 block
    try testing.expectEqual(@as(u32, 1), @as(u32, @intCast(index.blocks.count())));

    // Memory should have increased due to longer content
    try testing.expect(memory_after_second > memory_after_first);

    const found_block = index.find_block(block_id);
    try testing.expect(found_block != null);
    try testing.expectEqual(@as(u32, 2), found_block.?.sequence);
    try testing.expectEqualStrings("much longer content than before", found_block.?.content);
}

test "clear operation resets index to empty state efficiently" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const coordinator = ArenaCoordinator.init(&arena);
    var index = BlockIndex.init(&coordinator, testing.allocator);
    defer index.deinit();

    for (0..10) |i| {
        const block_id = BlockId.generate();
        const test_block = ContextBlock{
            .id = block_id,
            .sequence = 0, // Storage engine will assign the actual global sequence
            .source_uri = "test://example.zig",
            .metadata_json = "{}",
            .content = try std.fmt.allocPrint(testing.allocator, "content {}", .{i}),
        };
        defer testing.allocator.free(test_block.content);

        try index.put_block(test_block);
    }

    try testing.expectEqual(@as(u32, 10), @as(u32, @intCast(index.blocks.count())));
    try testing.expect(index.memory_used > 0);

    index.clear();
    try testing.expectEqual(@as(u32, 0), @as(u32, @intCast(index.blocks.count())));
    try testing.expectEqual(@as(u64, 0), index.memory_used);
}

test "memory accounting tracks string content accurately" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const coordinator = ArenaCoordinator.init(&arena);
    var index = BlockIndex.init(&coordinator, testing.allocator);
    defer index.deinit();

    const source_uri = "file://example.zig";
    const metadata_json = "{}";
    const content = "test content here";

    const block_id = BlockId.generate();
    const test_block = ContextBlock{
        .id = block_id,
        .sequence = 0, // Storage engine will assign the actual global sequence
        .source_uri = source_uri,
        .metadata_json = metadata_json,
        .content = content,
    };

    try index.put_block(test_block);

    const expected_memory = source_uri.len + metadata_json.len + content.len;
    try testing.expectEqual(@as(u64, expected_memory), index.memory_used);
}

test "large block content handling" {
    const allocator = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const coordinator = ArenaCoordinator.init(&arena);
    var index = BlockIndex.init(&coordinator, allocator);
    defer index.deinit();

    const large_content = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(large_content);
    @memset(large_content, 'X');

    const block_id = BlockId.generate();
    const test_block = ContextBlock{
        .id = block_id,
        .sequence = 0, // Storage engine will assign the actual global sequence
        .source_uri = "test://bulk.zig",
        .metadata_json = "{}",
        .content = large_content,
    };

    try index.put_block(test_block);

    const found_block = index.find_block(block_id);
    try testing.expect(found_block != null);
    try testing.expectEqual(@as(usize, 1024 * 1024), found_block.?.content.len);
    try testing.expectEqual(@as(u8, 'X'), found_block.?.content[0]);
    try testing.expectEqual(@as(u8, 'X'), found_block.?.content[1024 * 1024 - 1]);
}
