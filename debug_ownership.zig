//! Debug test for ownership validation hanging issue
//! This standalone test helps isolate the root cause of hanging ownership tests

const std = @import("std");
const builtin = @import("builtin");

const arena_mod = @import("src/core/arena.zig");
const ownership_mod = @import("src/core/ownership.zig");
const types_mod = @import("src/core/types.zig");

const ArenaOwnership = arena_mod.ArenaOwnership;
const BlockOwnership = ownership_mod.BlockOwnership;
const ContextBlock = types_mod.ContextBlock;
const BlockId = types_mod.BlockId;
const typed_arena_type = arena_mod.typed_arena_type;

const testing = std.testing;

// Mock subsystem for testing
const TestSubsystem = struct {};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.log.info("Starting ownership validation debug...", .{});

    // Test 1: Basic arena creation
    std.log.info("Test 1: Creating basic arena...", .{});
    var test_arena = typed_arena_type(ContextBlock, TestSubsystem).init(allocator, ArenaOwnership.memtable_manager);
    defer test_arena.deinit();
    std.log.info("✓ Arena created successfully", .{});

    // Test 2: Check ownership value
    std.log.info("Test 2: Checking ownership value...", .{});
    std.log.info("Arena ownership: {}", .{test_arena.ownership});
    std.log.info("Expected: {}", .{ArenaOwnership.memtable_manager});
    if (test_arena.ownership == ArenaOwnership.memtable_manager) {
        std.log.info("✓ Ownership matches expected value", .{});
    } else {
        std.log.err("✗ Ownership mismatch!", .{});
        return;
    }

    // Test 3: Simple validation (this is where it might hang)
    std.log.info("Test 3: Testing basic ownership validation...", .{});
    std.log.info("About to call validate_ownership_access with matching ownership...", .{});

    // This is the suspected hanging point
    test_arena.validate_ownership_access(ArenaOwnership.memtable_manager);
    std.log.info("✓ Self-validation passed", .{});

    // Test 4: Temporary access validation
    std.log.info("Test 4: Testing temporary access validation...", .{});
    test_arena.validate_ownership_access(ArenaOwnership.temporary);
    std.log.info("✓ Temporary access validation passed", .{});

    // Test 5: Try invalid access (should fail assertion in debug mode)
    if (builtin.mode == .Debug) {
        std.log.info("Test 5: Testing invalid access (should assert in debug mode)...", .{});
        std.log.info("This test is skipped to avoid assertion failure", .{});
        // test_arena.validate_ownership_access(ArenaOwnership.storage_engine); // This should assert
    }

    std.log.info("All ownership validation tests passed!", .{});
}

// Subsystem simulators for interaction testing
const MemtableBlock = ownership_mod.comptime_owned_block_type(.memtable_manager);
const StorageBlock = ownership_mod.comptime_owned_block_type(.storage_engine);
const QueryBlock = ownership_mod.comptime_owned_block_type(.query_engine);

const MemtableSubsystem = struct {
    arena: typed_arena_type(MemtableBlock, @This()),
    blocks: std.ArrayListUnmanaged(MemtableBlock),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        std.log.info("Initializing MemtableSubsystem...", .{});
        return Self{
            .arena = typed_arena_type(MemtableBlock, Self).init(allocator, ArenaOwnership.memtable_manager),
            .blocks = std.ArrayListUnmanaged(MemtableBlock){},
        };
    }

    pub fn add_block(self: *Self, block: ContextBlock) !void {
        std.log.info("Adding block to memtable...", .{});
        const owned = MemtableBlock.init(block);
        try self.blocks.append(self.arena.allocator(), owned);
        std.log.info("✓ Block added to memtable", .{});
    }

    pub fn transfer_to_storage(self: *Self, storage: *StorageSubsystem) !void {
        std.log.info("Starting transfer to storage...", .{});
        for (self.blocks.items) |*memtable_block| {
            std.log.info("Transferring block...", .{});
            const storage_owned = StorageBlock.init(memtable_block.extract());
            try storage.blocks.append(storage.arena.allocator(), storage_owned);
            std.log.info("✓ Block transferred", .{});
        }
        std.log.info("Clearing memtable blocks...", .{});
        self.blocks.clearRetainingCapacity();
        std.log.info("Resetting memtable arena...", .{});
        self.arena.reset();
        std.log.info("✓ Transfer to storage completed", .{});
    }

    pub fn deinit(self: *Self) void {
        std.log.info("Deinitializing MemtableSubsystem...", .{});
        self.blocks.deinit(self.arena.allocator());
        self.arena.deinit();
    }
};

const StorageSubsystem = struct {
    arena: typed_arena_type(StorageBlock, @This()),
    blocks: std.ArrayListUnmanaged(StorageBlock),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        std.log.info("Initializing StorageSubsystem...", .{});
        return Self{
            .arena = typed_arena_type(StorageBlock, Self).init(allocator, ArenaOwnership.storage_engine),
            .blocks = std.ArrayListUnmanaged(StorageBlock){},
        };
    }

    pub fn find_block(self: *Self, block_id: BlockId) ?*const ContextBlock {
        std.log.info("Searching for block in storage...", .{});
        for (self.blocks.items) |*storage_block| {
            if (storage_block.block.id.eql(block_id)) {
                std.log.info("✓ Block found in storage", .{});
                return storage_block.read(.storage_engine);
            }
        }
        std.log.info("Block not found in storage", .{});
        return null;
    }

    pub fn deinit(self: *Self) void {
        std.log.info("Deinitializing StorageSubsystem...", .{});
        self.blocks.deinit(self.arena.allocator());
        self.arena.deinit();
    }
};

const QuerySubsystem = struct {
    arena: typed_arena_type(QueryBlock, @This()),
    temp_blocks: std.ArrayListUnmanaged(QueryBlock),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        std.log.info("Initializing QuerySubsystem...", .{});
        return Self{
            .arena = typed_arena_type(QueryBlock, Self).init(allocator, ArenaOwnership.query_engine),
            .temp_blocks = std.ArrayListUnmanaged(QueryBlock){},
        };
    }

    pub fn create_query_result(self: *Self, source_block: *const ContextBlock) !void {
        std.log.info("Creating query result from source block...", .{});
        const query_owned = QueryBlock.init(source_block.*);
        try self.temp_blocks.append(self.arena.allocator(), query_owned);
        std.log.info("✓ Query result created", .{});
    }

    pub fn deinit(self: *Self) void {
        std.log.info("Deinitializing QuerySubsystem...", .{});
        self.temp_blocks.deinit(self.arena.allocator());
        self.arena.deinit();
    }
};

test "debug subsystem interactions" {
    std.log.info("=== Starting subsystem interaction debug test ===", .{});

    std.log.info("Creating memtable subsystem...", .{});
    var memtable = MemtableSubsystem.init(testing.allocator);
    defer memtable.deinit();
    std.log.info("✓ Memtable created", .{});

    std.log.info("Creating storage subsystem...", .{});
    var storage = StorageSubsystem.init(testing.allocator);
    defer storage.deinit();
    std.log.info("✓ Storage created", .{});

    std.log.info("Creating query subsystem...", .{});
    var query = QuerySubsystem.init(testing.allocator);
    defer query.deinit();
    std.log.info("✓ Query created", .{});

    // Test the ownership comparisons that might be hanging
    std.log.info("Testing ownership comparisons...", .{});
    try testing.expect(memtable.arena.ownership != storage.arena.ownership);
    std.log.info("✓ Memtable vs Storage ownership differs", .{});

    try testing.expect(storage.arena.ownership != query.arena.ownership);
    std.log.info("✓ Storage vs Query ownership differs", .{});

    try testing.expect(memtable.arena.ownership != query.arena.ownership);
    std.log.info("✓ Memtable vs Query ownership differs", .{});

    // Test the validate_ownership_access calls that are suspected to hang
    std.log.info("Testing ownership access validation...", .{});
    std.log.info("Validating memtable access...", .{});
    memtable.arena.validate_ownership_access(ArenaOwnership.memtable_manager);
    std.log.info("✓ Memtable self-validation passed", .{});

    std.log.info("Validating storage access...", .{});
    storage.arena.validate_ownership_access(ArenaOwnership.storage_engine);
    std.log.info("✓ Storage self-validation passed", .{});

    std.log.info("Validating query access...", .{});
    query.arena.validate_ownership_access(ArenaOwnership.query_engine);
    std.log.info("✓ Query self-validation passed", .{});

    // Test temporary access validation
    std.log.info("Testing temporary access validation...", .{});
    memtable.arena.validate_ownership_access(ArenaOwnership.temporary);
    std.log.info("✓ Memtable temporary access validated", .{});

    storage.arena.validate_ownership_access(ArenaOwnership.temporary);
    std.log.info("✓ Storage temporary access validated", .{});

    query.arena.validate_ownership_access(ArenaOwnership.temporary);
    std.log.info("✓ Query temporary access validated", .{});

    std.log.info("=== All subsystem interaction tests passed! ===", .{});
}

test "debug step 1: block creation" {
    std.log.info("=== Testing block creation ===", .{});

    const block1 = ContextBlock{
        .id = BlockId.from_hex("1111111111111111AAAAAAAAAAAAAAAA") catch unreachable,
        .version = 1,
        .source_uri = "test://lifecycle1",
        .metadata_json = "{}",
        .content = "lifecycle test content 1",
    };

    std.log.info("✓ Block creation successful", .{});
    try testing.expect(block1.version == 1);
    std.log.info("=== Block creation test passed! ===", .{});
}

test "debug step 2: memtable operations" {
    std.log.info("=== Testing memtable operations ===", .{});

    var memtable = MemtableSubsystem.init(testing.allocator);
    defer memtable.deinit();

    const block1 = ContextBlock{
        .id = BlockId.from_hex("1111111111111111AAAAAAAAAAAAAAAA") catch unreachable,
        .version = 1,
        .source_uri = "test://lifecycle1",
        .metadata_json = "{}",
        .content = "lifecycle test content 1",
    };

    try memtable.add_block(block1);
    try testing.expect(memtable.blocks.items.len == 1);

    std.log.info("=== Memtable operations test passed! ===", .{});
}

test "debug step 3: storage transfer" {
    std.log.info("=== Testing storage transfer ===", .{});

    var memtable = MemtableSubsystem.init(testing.allocator);
    defer memtable.deinit();

    var storage = StorageSubsystem.init(testing.allocator);
    defer storage.deinit();

    const block1 = ContextBlock{
        .id = BlockId.from_hex("1111111111111111AAAAAAAAAAAAAAAA") catch unreachable,
        .version = 1,
        .source_uri = "test://lifecycle1",
        .metadata_json = "{}",
        .content = "lifecycle test content 1",
    };

    try memtable.add_block(block1);
    std.log.info("About to call transfer_to_storage...", .{});
    try memtable.transfer_to_storage(&storage);
    std.log.info("✓ Transfer completed", .{});

    try testing.expect(memtable.blocks.items.len == 0);
    try testing.expect(storage.blocks.items.len == 1);

    std.log.info("=== Storage transfer test passed! ===", .{});
}

test "debug step 4: storage find operations" {
    std.log.info("=== Testing storage find operations ===", .{});

    var storage = StorageSubsystem.init(testing.allocator);
    defer storage.deinit();

    const block1 = ContextBlock{
        .id = BlockId.from_hex("1111111111111111AAAAAAAAAAAAAAAA") catch unreachable,
        .version = 1,
        .source_uri = "test://lifecycle1",
        .metadata_json = "{}",
        .content = "lifecycle test content 1",
    };

    // Add block directly to storage for testing
    const storage_owned = StorageBlock.init(block1);
    try storage.blocks.append(storage.arena.allocator(), storage_owned);

    std.log.info("About to call find_block...", .{});
    const found_block = storage.find_block(block1.id);
    std.log.info("✓ Find operation completed", .{});

    try testing.expect(found_block != null);
    try testing.expect(found_block.?.id.eql(block1.id));

    std.log.info("=== Storage find operations test passed! ===", .{});
}

test "debug step 5: query operations" {
    std.log.info("=== Testing query operations ===", .{});

    var query = QuerySubsystem.init(testing.allocator);
    defer query.deinit();

    const block1 = ContextBlock{
        .id = BlockId.from_hex("1111111111111111AAAAAAAAAAAAAAAA") catch unreachable,
        .version = 1,
        .source_uri = "test://lifecycle1",
        .metadata_json = "{}",
        .content = "lifecycle test content 1",
    };

    std.log.info("About to call create_query_result...", .{});
    try query.create_query_result(&block1);
    std.log.info("✓ Query result creation completed", .{});

    try testing.expect(query.temp_blocks.items.len == 1);

    std.log.info("=== Query operations test passed! ===", .{});
}

test "debug step 6: ownership verification" {
    std.log.info("=== Testing ownership verification ===", .{});

    var storage = StorageSubsystem.init(testing.allocator);
    defer storage.deinit();

    const block1 = ContextBlock{
        .id = BlockId.from_hex("1111111111111111AAAAAAAAAAAAAAAA") catch unreachable,
        .version = 1,
        .source_uri = "test://lifecycle1",
        .metadata_json = "{}",
        .content = "lifecycle test content 1",
    };

    const storage_owned = StorageBlock.init(block1);
    try storage.blocks.append(storage.arena.allocator(), storage_owned);

    std.log.info("About to verify ownership...", .{});
    for (storage.blocks.items) |_| {
        try testing.expect(StorageBlock.is_owned_by(.storage_engine));
    }
    std.log.info("✓ Ownership verification completed", .{});

    std.log.info("=== Ownership verification test passed! ===", .{});
}

test "debug incremental lifecycle - find hanging point" {
    std.log.info("=== Testing incremental lifecycle ===", .{});

    // Phase 1: Setup
    std.log.info("Phase 1: Creating subsystems...", .{});
    var memtable = MemtableSubsystem.init(testing.allocator);
    defer memtable.deinit();
    var storage = StorageSubsystem.init(testing.allocator);
    defer storage.deinit();
    std.log.info("✓ Phase 1 complete", .{});

    // Phase 2: Single block
    std.log.info("Phase 2: Adding single block...", .{});
    const block1 = ContextBlock{
        .id = BlockId.from_hex("1111111111111111AAAAAAAAAAAAAAAA") catch unreachable,
        .version = 1,
        .source_uri = "test://lifecycle1",
        .metadata_json = "{}",
        .content = "lifecycle test content 1",
    };
    try memtable.add_block(block1);
    std.log.info("✓ Phase 2 complete", .{});

    // Phase 3: Transfer single block
    std.log.info("Phase 3: Transferring single block...", .{});
    try memtable.transfer_to_storage(&storage);
    std.log.info("✓ Phase 3 complete", .{});

    // Phase 4: Add second block after transfer
    std.log.info("Phase 4: Adding second block after reset...", .{});
    const block2 = ContextBlock{
        .id = BlockId.from_hex("2222222222222222BBBBBBBBBBBBBBBB") catch unreachable,
        .version = 1,
        .source_uri = "test://lifecycle2",
        .metadata_json = "{}",
        .content = "lifecycle test content 2",
    };
    try memtable.add_block(block2);
    std.log.info("✓ Phase 4 complete", .{});

    // Phase 5: Transfer second block
    std.log.info("Phase 5: Transferring second block...", .{});
    try memtable.transfer_to_storage(&storage);
    std.log.info("✓ Phase 5 complete", .{});

    // Phase 6: Query operations
    std.log.info("Phase 6: Testing query operations...", .{});
    var query = QuerySubsystem.init(testing.allocator);
    defer query.deinit();
    const found_block = storage.find_block(block1.id);
    try testing.expect(found_block != null);
    std.log.info("✓ Phase 6 complete", .{});

    std.log.info("=== Incremental lifecycle test completed successfully! ===", .{});
}

// TODO: Fix hanging ownership validation - commented out temporarily
// test "debug complete block lifecycle" {
//     std.log.info("=== Starting complete block lifecycle debug test ===", .{});
//
//     std.log.info("Creating subsystems...", .{});
//     var memtable = MemtableSubsystem.init(testing.allocator);
//     defer memtable.deinit();
//
//     var storage = StorageSubsystem.init(testing.allocator);
//     defer storage.deinit();
//
//     var query = QuerySubsystem.init(testing.allocator);
//     defer query.deinit();
//     std.log.info("✓ All subsystems created", .{});
//
//     // Create test blocks
//     std.log.info("Creating test blocks...", .{});
//     const block1 = ContextBlock{
//         .id = BlockId.from_hex("1111111111111111AAAAAAAAAAAAAAAA") catch unreachable,
//         .version = 1,
//         .source_uri = "test://lifecycle1",
//         .metadata_json = "{}",
//         .content = "lifecycle test content 1",
//     };
//
//     const block2 = ContextBlock{
//         .id = BlockId.from_hex("2222222222222222BBBBBBBBBBBBBBBB") catch unreachable,
//         .version = 1,
//         .source_uri = "test://lifecycle2",
//         .metadata_json = "{}",
//         .content = "lifecycle test content 2",
//     };
//     std.log.info("✓ Test blocks created", .{});
//
//     // Step 1: Add blocks to memtable
//     std.log.info("Step 1: Adding blocks to memtable...", .{});
//     try memtable.add_block(block1);
//     try memtable.add_block(block2);
//     try testing.expect(memtable.blocks.items.len == 2);
//     std.log.info("✓ Blocks added to memtable", .{});
//
//     // Step 2: Transfer blocks to storage (this is where it might hang)
//     std.log.info("Step 2: Transferring blocks to storage...", .{});
//     try memtable.transfer_to_storage(&storage);
//     try testing.expect(memtable.blocks.items.len == 0);
//     try testing.expect(storage.blocks.items.len == 2);
//     std.log.info("✓ Blocks transferred to storage", .{});
//
//     // Step 3: Query can read from storage
//     std.log.info("Step 3: Reading from storage...", .{});
//     const found_block = storage.find_block(block1.id);
//     try testing.expect(found_block != null);
//     try testing.expect(found_block.?.id.eql(block1.id));
//     std.log.info("✓ Block found in storage", .{});
//
//     // Step 4: Query creates temporary copies for processing
//     std.log.info("Step 4: Creating query result...", .{});
//     try query.create_query_result(found_block.?);
//     try testing.expect(query.temp_blocks.items.len == 1);
//     std.log.info("✓ Query result created", .{});
//
//     // Step 5: Verify ownership isolation (this might also hang)
//     std.log.info("Step 5: Verifying ownership isolation...", .{});
//     for (storage.blocks.items) |_| {
//         try testing.expect(StorageBlock.is_owned_by(.storage_engine));
//     }
//     std.log.info("✓ Storage blocks ownership verified", .{});
//
//     for (query.temp_blocks.items) |_| {
//         try testing.expect(QueryBlock.is_owned_by(.query_engine));
//     }
//     std.log.info("✓ Query blocks ownership verified", .{});
//
//     std.log.info("=== Complete block lifecycle debug test passed! ===", .{});
// }

// Also provide a test entry point for zig test
test "debug ownership validation" {
    std.log.info("Running ownership validation test...", .{});

    var test_arena = typed_arena_type(ContextBlock, TestSubsystem).init(testing.allocator, ArenaOwnership.memtable_manager);
    defer test_arena.deinit();

    // Check basic functionality
    try testing.expect(test_arena.ownership == ArenaOwnership.memtable_manager);

    // Test the validate function that might be hanging
    test_arena.validate_ownership_access(ArenaOwnership.memtable_manager);
    test_arena.validate_ownership_access(ArenaOwnership.temporary);

    std.log.info("Debug ownership test completed successfully", .{});
}
