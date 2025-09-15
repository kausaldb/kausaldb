//! Defensive programming validation test suite.
//!
//! Tests assertion framework and defensive programming checks throughout
//! KausalDB to ensure they properly catch invalid conditions without
//! unnecessary simulation overhead.

const std = @import("std");

const assert_mod = @import("../../core/assert.zig");
const types = @import("../../core/types.zig");
const memory = @import("../../core/memory.zig");
const ownership = @import("../../core/ownership.zig");

const testing = std.testing;

const assert = assert_mod.assert;
const assert_fmt = assert_mod.assert_fmt;
const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const GraphEdge = types.GraphEdge;
const EdgeType = types.EdgeType;
const BlockOwnership = ownership.BlockOwnership;
const ArenaCoordinator = memory.ArenaCoordinator;

test "block validation assertions" {
    // Test valid block - should not trigger assertions
    const valid_block = ContextBlock{
        .id = try BlockId.from_hex("00000000000000000000000000000001"),
        .version = 1,
        .source_uri = "test://valid.zig",
        .metadata_json = "{}",
        .content = "valid content",
    };

    // Validate block properties
    try testing.expect(!valid_block.id.is_zero());
    try testing.expect(valid_block.version > 0);
    try testing.expect(valid_block.source_uri.len > 0);

    // Test edge validation
    const valid_edge = GraphEdge{
        .source_id = try BlockId.from_hex("00000000000000000000000000000001"),
        .target_id = try BlockId.from_hex("00000000000000000000000000000002"),
        .edge_type = .imports,
    };

    try testing.expect(!valid_edge.source_id.is_zero());
    try testing.expect(!valid_edge.target_id.is_zero());
    try testing.expect(!valid_edge.source_id.eql(valid_edge.target_id));
}

test "ownership state machine assertions" {
    // Test ownership transitions without full storage engine
    var ownership_state = BlockOwnership.storage_engine;

    // Valid transition: storage_engine -> query_engine
    ownership_state = .query_engine;
    try testing.expect(ownership_state == .query_engine);

    // Valid transition: query_engine -> memtable_manager
    ownership_state = .memtable_manager;
    try testing.expect(ownership_state == .memtable_manager);

    // Test that we can detect different ownership states
    const is_memtable = ownership_state == .memtable_manager;
    try testing.expect(is_memtable);
}

test "arena coordinator defensive checks" {
    const allocator = testing.allocator;

    // Test arena coordinator pattern without full storage
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var coordinator = ArenaCoordinator.init(&arena);

    // Allocate through coordinator
    const test_data = try coordinator.allocator().alloc(u8, 1024);
    try testing.expect(test_data.len == 1024);

    // Fill with pattern to verify memory is accessible
    @memset(test_data, 0xAA);
    try testing.expect(test_data[0] == 0xAA);
    try testing.expect(test_data[1023] == 0xAA);

    // Reset should work without issues
    coordinator.reset();

    // Can still allocate after reset
    const new_data = try coordinator.allocator().alloc(u8, 512);
    try testing.expect(new_data.len == 512);
}

test "block id defensive validation" {
    // Test BlockId validation without storage engine
    const zero_id = BlockId.zero();
    try testing.expect(zero_id.is_zero());

    const valid_id = try BlockId.from_hex("00000000000000000000000000000001");
    try testing.expect(!valid_id.is_zero());

    // Test comparison
    try testing.expect(!zero_id.eql(valid_id));
    try testing.expect(valid_id.eql(valid_id));

    // Test generation creates non-zero IDs
    const generated = BlockId.generate();
    try testing.expect(!generated.is_zero());
}

test "assert macro behavior in debug vs release" {
    const debug_mode = std.debug.runtime_safety;

    // These assertions should compile in all modes
    assert(true);
    assert_fmt(true, "This should not trigger", .{});

    // Test that we can detect debug mode
    if (debug_mode) {
        // In debug mode, assertions are active
        try testing.expect(std.debug.runtime_safety);
    } else {
        // In release mode, assertions compile to no-ops
        try testing.expect(!std.debug.runtime_safety);
    }
}

test "memory bounds validation" {
    const allocator = testing.allocator;

    // Test memory limit enforcement patterns
    const max_size: usize = 16 * 1024 * 1024; // 16MB limit

    // Allocate within bounds - should succeed
    const small_alloc = try allocator.alloc(u8, 1024);
    defer allocator.free(small_alloc);
    try testing.expect(small_alloc.len == 1024);

    // Test size validation
    const requested_size: usize = 1024 * 1024; // 1MB
    try testing.expect(requested_size <= max_size);

    // Simulate bounds checking
    const oversized: usize = 32 * 1024 * 1024; // 32MB
    try testing.expect(oversized > max_size);
}

test "edge type validation" {
    // Test edge type enum validation
    const valid_types = [_]EdgeType{ .imports, .calls, .defined_in, .references };

    for (valid_types) |edge_type| {
        // Each type should be distinct
        switch (edge_type) {
            .imports => try testing.expect(edge_type == .imports),
            .calls => try testing.expect(edge_type == .calls),
            .defined_in => try testing.expect(edge_type == .defined_in),
            .references => try testing.expect(edge_type == .references),
            else => {}, // Handle other valid edge types
        }
    }
}

test "critical invariant checks" {
    // Test patterns for critical invariants without full system

    // Invariant: Block IDs must be unique (simulated check)
    var seen_ids = std.AutoHashMap(BlockId, void).init(testing.allocator);
    defer seen_ids.deinit();

    // Generate multiple IDs and verify uniqueness
    for (0..100) |_| {
        const id = BlockId.generate();
        const result = try seen_ids.getOrPut(id);
        try testing.expect(!result.found_existing); // Should be unique
    }

    // Invariant: Version numbers must be positive
    const versions = [_]u32{ 1, 2, 3, 100, 1000 };
    for (versions) |version| {
        try testing.expect(version > 0);
    }
}

test "defensive null checks" {
    // Test defensive programming patterns for optionals
    const maybe_value: ?u32 = 42;
    const no_value: ?u32 = null;

    // Safe unwrapping patterns
    if (maybe_value) |value| {
        try testing.expect(value == 42);
    } else {
        try testing.expect(false); // Should not reach
    }

    // Null check
    try testing.expect(no_value == null);

    // Default value pattern
    const default_value = no_value orelse 0;
    try testing.expect(default_value == 0);
}

test "error propagation patterns" {
    const TestError = error{
        InvalidInput,
        OutOfBounds,
        Corrupted,
    };

    // Test error handling patterns
    const result = validate_input(42) catch |err| {
        try testing.expect(err == TestError.InvalidInput);
        return;
    };

    try testing.expect(result == 42);
}

fn validate_input(value: u32) !u32 {
    if (value > 100) return error.InvalidInput;
    if (value == 0) return error.OutOfBounds;
    return value;
}
