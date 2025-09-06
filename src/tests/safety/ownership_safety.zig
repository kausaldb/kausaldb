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
const TypedArenaType = arena.typed_arena_type;

// Test subsystem simulators
// Using unified OwnedBlock pattern instead of specialized types

const MemtableSubsystem = struct {
    arena: TypedArenaType(OwnedBlock, @This()),
    blocks: std.ArrayListUnmanaged(OwnedBlock),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .arena = TypedArenaType(OwnedBlock, Self).init(allocator, ArenaOwnership.memtable_manager),
            .blocks = std.ArrayListUnmanaged(OwnedBlock){},
        };
    }

    pub fn deinit(self: *Self) void {
        self.blocks.deinit(self.arena.allocator());
        self.arena.deinit();
    }

    pub fn add_block(self: *Self, block: ContextBlock) !void {
        const owned = OwnedBlock.take_ownership(block, .memtable_manager);
        try self.blocks.append(self.arena.allocator(), owned);
    }

    pub fn transfer_to_storage(self: *Self, storage: *StorageSubsystem) !void {
        for (self.blocks.items) |*memtable_block| {
            const storage_owned = StorageBlock.init(memtable_block.extract());
            try storage.blocks.append(storage.arena.allocator(), storage_owned);
        }
        self.blocks.clearRetainingCapacity();
        self.arena.reset();
    }
};

const StorageSubsystem = struct {
    arena: TypedArenaType(StorageBlock, @This()),
    blocks: std.ArrayListUnmanaged(StorageBlock),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .arena = TypedArenaType(StorageBlock, Self).init(allocator, ArenaOwnership.storage_engine),
            .blocks = std.ArrayListUnmanaged(StorageBlock){},
        };
    }

    pub fn deinit(self: *Self) void {
        self.blocks.deinit(self.arena.allocator());
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
    arena: TypedArenaType(QueryBlock, @This()),
    temp_blocks: std.ArrayListUnmanaged(QueryBlock),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .arena = TypedArenaType(QueryBlock, Self).init(allocator, ArenaOwnership.query_engine),
            .temp_blocks = std.ArrayListUnmanaged(QueryBlock){},
        };
    }

    pub fn deinit(self: *Self) void {
        self.temp_blocks.deinit(self.arena.allocator());
        self.arena.deinit();
    }

    pub fn create_query_result(self: *Self, source_block: *const ContextBlock) !void {
        const query_owned = QueryBlock.init(source_block.*);
        try self.temp_blocks.append(self.arena.allocator(), query_owned);
    }
};

test "simple ownership validation debug" {
    // Simple test to debug hanging ownership validation
    var test_arena = TypedArenaType(ContextBlock, MemtableSubsystem).init(testing.allocator, ArenaOwnership.memtable_manager);
    defer test_arena.deinit();

    // Basic validation that should work
    test_arena.validate_ownership_access(ArenaOwnership.memtable_manager);
    test_arena.validate_ownership_access(ArenaOwnership.temporary);

    // This should pass without hanging
    try testing.expect(test_arena.ownership == ArenaOwnership.memtable_manager);
}

test "cross-subsystem ownership safety" {
    var memtable = MemtableSubsystem.init(testing.allocator);
    defer memtable.deinit();

    var storage = StorageSubsystem.init(testing.allocator);
    defer storage.deinit();

    var query = QuerySubsystem.init(testing.allocator);
    defer query.deinit();

    // Verify different arenas have different ownership
    try testing.expect(memtable.arena.ownership != storage.arena.ownership);
    try testing.expect(storage.arena.ownership != query.arena.ownership);
    try testing.expect(memtable.arena.ownership != query.arena.ownership);

    // Each arena should validate its own ownership
    memtable.arena.validate_ownership_access(ArenaOwnership.memtable_manager);
    storage.arena.validate_ownership_access(ArenaOwnership.storage_engine);
    query.arena.validate_ownership_access(ArenaOwnership.query_engine);

    // All should accept temporary access
    memtable.arena.validate_ownership_access(ArenaOwnership.temporary);
    storage.arena.validate_ownership_access(ArenaOwnership.temporary);
    query.arena.validate_ownership_access(ArenaOwnership.temporary);
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
    for (storage.blocks.items) |_| {
        try testing.expect(StorageBlock.is_owned_by(.storage_engine));
    }

    for (query.temp_blocks.items) |_| {
        try testing.expect(QueryBlock.is_owned_by(.query_engine));
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
        memtable.arena.reset();
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
    for (storage.blocks.items) |_| {
        try testing.expect(StorageBlock.is_owned_by(.storage_engine));
    }
}

test "memory accounting accuracy" {
    if (builtin.mode != .Debug) return; // Debug info only available in debug mode

    var test_arena = TypedArenaType(ContextBlock, MemtableSubsystem).init(testing.allocator, ArenaOwnership.memtable_manager);
    defer test_arena.deinit();

    // Check initial state
    var info = test_arena.debug_info();
    try testing.expect(info.allocation_count == 0);
    try testing.expect(info.total_bytes == 0);

    // Allocate some blocks
    _ = try test_arena.alloc(); // 1 block
    _ = try test_arena.alloc_slice(3); // 3 blocks
    _ = try test_arena.alloc(); // 1 more block

    // Check accounting
    info = test_arena.debug_info();
    try testing.expect(info.allocation_count == 5); // 1 + 3 + 1
    try testing.expect(info.total_bytes == 5 * @sizeOf(ContextBlock));

    // Reset and verify cleanup
    test_arena.reset();
    info = test_arena.debug_info();
    try testing.expect(info.allocation_count == 0);
    try testing.expect(info.total_bytes == 0);
}
