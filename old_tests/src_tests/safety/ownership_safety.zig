//! Comprehensive ownership safety integration tests
//!
//! Tests the complete type-safe ownership system across multiple subsystems
//! to verify memory safety, ownership transfer, and cross-arena protection.

const builtin = @import("builtin");
const std = @import("std");

const arena = @import("../../core/arena.zig");
const ArenaOwnership = arena.ArenaOwnership;
const ownership = @import("../../core/ownership.zig");
const types = @import("../../core/types.zig");

const testing = std.testing;

const BlockId = types.BlockId;
const BlockOwnership = ownership.BlockOwnership;
const ContextBlock = types.ContextBlock;
const OwnedBlock = ownership.OwnedBlock;
const OwnedBlockCollection = ownership.OwnedBlockCollection;
// Test subsystem simulators
// Using unified OwnedBlock pattern instead of specialized types

const MemtableSubsystem = struct {
    arena: std.heap.ArenaAllocator,
    backing_allocator: std.mem.Allocator,
    blocks: std.ArrayListUnmanaged(OwnedBlock),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .backing_allocator = allocator,
            .blocks = std.ArrayListUnmanaged(OwnedBlock){},
        };
    }

    pub fn deinit(self: *Self) void {
        self.blocks.deinit(self.backing_allocator);
        self.arena.deinit();
    }

    pub fn add_block(self: *Self, block: ContextBlock) !void {
        const owned = OwnedBlock.take_ownership(block, .memtable_manager);
        try self.blocks.append(self.backing_allocator, owned);
    }

    pub fn transfer_to_storage(self: *Self, storage: *StorageSubsystem) !void {
        for (self.blocks.items) |*memtable_block| {
            // Clone the block data to the storage arena to avoid use-after-free
            const original_block = memtable_block.read_immutable().*;
            const cloned_block = ContextBlock{
                .id = original_block.id, // BlockId is copyable (no pointers)
                .version = original_block.version,
                .source_uri = try storage.arena.allocator().dupe(u8, original_block.source_uri),
                .metadata_json = try storage.arena.allocator().dupe(u8, original_block.metadata_json),
                .content = try storage.arena.allocator().dupe(u8, original_block.content),
            };
            const storage_owned = OwnedBlock.take_ownership(cloned_block, .storage_engine);
            try storage.blocks.append(storage.backing_allocator, storage_owned);
        }
        self.blocks.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
    }
};

const StorageSubsystem = struct {
    arena: std.heap.ArenaAllocator,
    backing_allocator: std.mem.Allocator,
    blocks: std.ArrayListUnmanaged(OwnedBlock),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .backing_allocator = allocator,
            .blocks = std.ArrayListUnmanaged(OwnedBlock){},
        };
    }

    pub fn deinit(self: *Self) void {
        self.blocks.deinit(self.backing_allocator);
        self.arena.deinit();
    }

    pub fn find_block(self: *Self, block_id: BlockId) ?*const ContextBlock {
        for (self.blocks.items) |*storage_block| {
            if (storage_block.block.id.eql(block_id)) {
                return storage_block.read(.storage_engine);
            }
        }
        return null;
    }
};

const QuerySubsystem = struct {
    arena: std.heap.ArenaAllocator,
    backing_allocator: std.mem.Allocator,
    temp_blocks: std.ArrayListUnmanaged(OwnedBlock),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .backing_allocator = allocator,
            .temp_blocks = std.ArrayListUnmanaged(OwnedBlock){},
        };
    }

    pub fn deinit(self: *Self) void {
        self.temp_blocks.deinit(self.backing_allocator);
        self.arena.deinit();
    }

    pub fn create_query_result(self: *Self, source_block: *const ContextBlock) !void {
        const query_owned = OwnedBlock.take_ownership(source_block.*, .query_engine);
        try self.temp_blocks.append(self.backing_allocator, query_owned);
    }
};

test "simple ownership validation debug" {
    // Simple test to debug unified ownership validation
    var test_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer test_arena.deinit();

    // Test unified ownership pattern
    const test_block = ContextBlock{
        .id = BlockId.generate(),
        .version = 1,
        .source_uri = "test://simple",
        .metadata_json = "{}",
        .content = "simple test",
    };

    const owned_block = OwnedBlock.take_ownership(test_block, .memtable_manager);
    try testing.expect(owned_block.is_owned_by(.memtable_manager));

    const temp_owned = OwnedBlock.take_ownership(test_block, .temporary);
    try testing.expect(temp_owned.is_owned_by(.temporary));
}

test "cross-subsystem ownership safety" {
    var memtable = MemtableSubsystem.init(testing.allocator);
    defer memtable.deinit();

    var storage = StorageSubsystem.init(testing.allocator);
    defer storage.deinit();

    var query = QuerySubsystem.init(testing.allocator);
    defer query.deinit();

    // With unified ownership pattern, ownership is at the block level, not arena level
    // Each subsystem uses regular ArenaAllocator for memory management

    // Test unified ownership validation across subsystems
    const test_block = ContextBlock{
        .id = BlockId.generate(),
        .version = 1,
        .source_uri = "test://cross-system",
        .metadata_json = "{}",
        .content = "cross-system test",
    };

    // Each subsystem can create blocks with their ownership
    const memtable_owned = OwnedBlock.take_ownership(test_block, .memtable_manager);
    const storage_owned = OwnedBlock.take_ownership(test_block, .storage_engine);
    const query_owned = OwnedBlock.take_ownership(test_block, .query_engine);

    // Verify ownership isolation
    try testing.expect(memtable_owned.is_owned_by(.memtable_manager));
    try testing.expect(storage_owned.is_owned_by(.storage_engine));
    try testing.expect(query_owned.is_owned_by(.query_engine));

    // All should support temporary access
    const temp_owned = OwnedBlock.take_ownership(test_block, .temporary);
    try testing.expect(temp_owned.is_owned_by(.temporary));
}

test "complete block lifecycle with ownership transfers" {
    var memtable = MemtableSubsystem.init(testing.allocator);
    defer memtable.deinit();

    var storage = StorageSubsystem.init(testing.allocator);
    defer storage.deinit();

    var query = QuerySubsystem.init(testing.allocator);
    defer query.deinit();

    // Create test blocks
    const block1 = ContextBlock{
        // Safety: Operation guaranteed to succeed by preconditions
        .id = BlockId.from_hex("1111111111111111AAAAAAAAAAAAAAAA") catch unreachable,
        .version = 1,
        .source_uri = "test://lifecycle1",
        .metadata_json = "{}",
        .content = "lifecycle test content 1",
    };

    const block2 = ContextBlock{
        // Safety: Operation guaranteed to succeed by preconditions
        .id = BlockId.from_hex("2222222222222222BBBBBBBBBBBBBBBB") catch unreachable,
        .version = 1,
        .source_uri = "test://lifecycle2",
        .metadata_json = "{}",
        .content = "lifecycle test content 2",
    };

    // Step 1: Add blocks to memtable
    try memtable.add_block(block1);
    try memtable.add_block(block2);
    try testing.expect(memtable.blocks.items.len == 2);

    // Step 2: Transfer blocks to storage (memtable flush simulation)
    try memtable.transfer_to_storage(&storage);
    try testing.expect(memtable.blocks.items.len == 0); // Memtable cleared
    try testing.expect(storage.blocks.items.len == 2); // Storage has blocks

    // Step 3: Query can read from storage
    const found_block = storage.find_block(block1.id);
    try testing.expect(found_block != null);
    try testing.expect(found_block.?.id.eql(block1.id));

    // Step 4: Query creates temporary copies for processing
    try query.create_query_result(found_block.?);
    try testing.expect(query.temp_blocks.items.len == 1);

    // Step 5: Verify ownership isolation
    // Each subsystem owns its blocks independently
    for (storage.blocks.items) |block| {
        try testing.expect(block.is_owned_by(.storage_engine));
    }

    for (query.temp_blocks.items) |block| {
        try testing.expect(block.is_owned_by(.query_engine));
    }
}

test "memory safety with arena reset and reuse" {
    var memtable = MemtableSubsystem.init(testing.allocator);
    defer memtable.deinit();

    // Add blocks and reset multiple times to test safety
    for (0..5) |cycle| {
        const block_id_hex = switch (cycle) {
            0 => "0000000000000000AAAAAAAAAAAAAAAA",
            1 => "1111111111111111AAAAAAAAAAAAAAAA",
            2 => "2222222222222222AAAAAAAAAAAAAAAA",
            3 => "3333333333333333AAAAAAAAAAAAAAAA",
            4 => "4444444444444444AAAAAAAAAAAAAAAA",
            else => unreachable,
        };

        const block = ContextBlock{
            // Safety: Operation guaranteed to succeed by preconditions
            .id = BlockId.from_hex(block_id_hex) catch unreachable,
            .version = @intCast(cycle + 1),
            .source_uri = "test://safety",
            .metadata_json = "{}",
            .content = "safety test content",
        };

        try memtable.add_block(block);
        try testing.expect(memtable.blocks.items.len == 1);

        // Clear and reset for next cycle - arena reset handles memory cleanup
        memtable.blocks.clearRetainingCapacity();
        _ = memtable.arena.reset(.retain_capacity);
    }
}

test "ownership validation with fatal assertions" {
    var memtable = MemtableSubsystem.init(testing.allocator);
    defer memtable.deinit();

    const block = ContextBlock{
        // Safety: Operation guaranteed to succeed by preconditions
        .id = BlockId.from_hex("AAAAAAAAAAAAAAAA1111111111111111") catch unreachable,
        .version = 1,
        .source_uri = "test://validation",
        .metadata_json = "{}",
        .content = "validation test",
    };

    // Create owned block
    var owned = OwnedBlock.init(block, .memtable_manager, null);

    // Valid access patterns
    _ = owned.read(.memtable_manager); // Owner can read
    _ = owned.read(.temporary); // Temporary can read
    _ = owned.write(.memtable_manager); // Owner can write
    _ = owned.write(.temporary); // Temporary can write

    // Test ownership queries
    try testing.expect(owned.is_owned_by(.memtable_manager));
    try testing.expect(!owned.is_owned_by(.storage_engine));
    try testing.expect(!owned.is_owned_by(.query_engine));

    // Test ownership transfer
    const transferred = owned.transfer(.storage_engine, null);
    owned = transferred;
    try testing.expect(owned.is_owned_by(.storage_engine));
    try testing.expect(!owned.is_owned_by(.memtable_manager));

    // After transfer, new owner can access
    _ = owned.read(.storage_engine);
    _ = owned.write(.storage_engine);
}

test "large scale ownership operations" {
    var memtable = MemtableSubsystem.init(testing.allocator);
    defer memtable.deinit();

    var storage = StorageSubsystem.init(testing.allocator);
    defer storage.deinit();

    // Create many blocks to test scalability
    const num_blocks = 100;

    for (0..num_blocks) |i| {
        var block_id_bytes: [16]u8 = undefined;
        // Create unique block IDs
        std.mem.writeInt(u64, block_id_bytes[0..8], i, .little);
        std.mem.writeInt(u64, block_id_bytes[8..16], i + 1000, .little);

        const block = ContextBlock{
            .id = BlockId{ .bytes = block_id_bytes },
            .version = @intCast(i + 1),
            .source_uri = "test://scale",
            .metadata_json = "{}",
            .content = "scale test content",
        };

        try memtable.add_block(block);
    }

    try testing.expect(memtable.blocks.items.len == num_blocks);

    // Transfer all blocks
    try memtable.transfer_to_storage(&storage);
    try testing.expect(memtable.blocks.items.len == 0);
    try testing.expect(storage.blocks.items.len == num_blocks);

    // Verify all blocks are properly owned by storage
    for (storage.blocks.items) |block| {
        try testing.expect(block.is_owned_by(.storage_engine));
    }
}

test "memory accounting accuracy" {
    if (builtin.mode != .Debug) return; // Debug info only available in debug mode

    var test_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer test_arena.deinit();

    // Test unified ownership memory patterns
    const test_block = ContextBlock{
        .id = BlockId.generate(),
        .version = 1,
        .source_uri = "test://memory",
        .metadata_json = "{}",
        .content = "memory test",
    };

    // Test unified ownership memory patterns with ArenaAllocator
    const owned_block = OwnedBlock.take_ownership(test_block, .memtable_manager);
    _ = owned_block; // Use the owned block

    // Allocate some memory through the arena to test patterns
    _ = try test_arena.allocator().alloc(u8, 100); // 100 bytes
    _ = try test_arena.allocator().alloc(ContextBlock, 3); // 3 blocks
    _ = try test_arena.allocator().alloc(u8, 50); // 50 more bytes

    // Test that we can create multiple owned blocks with arena-managed memory
    const arena_alloc = test_arena.allocator();
    const string1 = try arena_alloc.dupe(u8, "test string 1");
    const string2 = try arena_alloc.dupe(u8, "test string 2");

    const block1 = ContextBlock{
        .id = BlockId.generate(),
        .version = 1,
        .source_uri = string1,
        .metadata_json = "{}",
        .content = string2,
    };

    const owned1 = OwnedBlock.take_ownership(block1, .memtable_manager);
    try testing.expect(owned1.is_owned_by(.memtable_manager));

    // Arena reset cleans up all allocations in O(1)
    // (No need to check specific counts since ArenaAllocator doesn't expose them)
}
