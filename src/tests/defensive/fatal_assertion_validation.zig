//! Simplified fatal assertion validation tests for KausalDB defensive programming.
//!
//! Tests the core fatal assertion framework functionality with focus on
//! practical validation scenarios and proper error categorization.

const std = @import("std");
const testing = std.testing;

const fatal_assertions = @import("../../testing/fatal_assertions.zig");
const types = @import("../../core/types.zig");

const FatalCategory = fatal_assertions.FatalCategory;
const FatalContext = fatal_assertions.FatalContext;
const BlockId = types.BlockId;

test "fatal category descriptions are correct" {
    try testing.expectEqualStrings("MEMORY CORRUPTION", FatalCategory.memory_corruption.description());
    try testing.expectEqualStrings("STATE INVARIANT", FatalCategory.state_invariant.description());
    try testing.expectEqualStrings("DATA INTEGRITY", FatalCategory.data_integrity.description());
    try testing.expectEqualStrings("DATA CORRUPTION", FatalCategory.data_corruption.description());
    try testing.expectEqualStrings("RESOURCE EXHAUSTION", FatalCategory.resource_exhaustion.description());
    try testing.expectEqualStrings("PROTOCOL VIOLATION", FatalCategory.protocol_violation.description());
    try testing.expectEqualStrings("INVARIANT VIOLATION", FatalCategory.invariant_violation.description());
    try testing.expectEqualStrings("LOGIC ERROR", FatalCategory.logic_error.description());
    try testing.expectEqualStrings("SECURITY VIOLATION", FatalCategory.security_violation.description());
}

test "fatal context initialization works correctly" {
    const src = @src();
    const context = FatalContext.init(
        .memory_corruption,
        "Test assertion message",
        src.file,
        src.line,
        src.fn_name,
    );

    try testing.expectEqual(FatalCategory.memory_corruption, context.category);
    try testing.expectEqualStrings("Test assertion message", context.message);
    try testing.expectEqualStrings("Test Component", context.component);
    try testing.expectEqualStrings("Test Operation", context.operation);
    try testing.expect(context.timestamp > 0);
}

test "fatal context formatting produces readable output" {
    const allocator = testing.allocator;

    const src = @src();
    const context = FatalContext.init(
        .data_corruption,
        "Block checksum validation failed",
        src.file,
        src.line,
        src.fn_name,
    );

    const diagnostic = try context.format_diagnostic(allocator);
    defer allocator.free(diagnostic);

    // Verify diagnostic contains key information
    try testing.expect(std.mem.indexOf(u8, diagnostic, "DATA CORRUPTION") != null);
    try testing.expect(std.mem.indexOf(u8, diagnostic, "Block checksum validation failed") != null);
}

test "block id validation passes for valid ids" {
    const valid_block_id = BlockId.from_bytes([_]u8{
        0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
        0xFE, 0xDC, 0xBA, 0x98, 0x76, 0x54, 0x32, 0x10,
    });

    // Should not panic for valid block ID
    fatal_assertions.fatal_assert_block_id_valid(valid_block_id, @src());
}

test "memory alignment validation passes for aligned pointers" {
    const allocator = testing.allocator;

    // Create aligned memory
    const aligned_memory = try allocator.alignedAlloc(u8, .@"16", 64);
    defer allocator.free(aligned_memory);

    // Should not panic for properly aligned memory
    fatal_assertions.fatal_assert_memory_aligned(aligned_memory.ptr, 16, @src());
}

test "buffer bounds validation passes for valid access" {
    const buffer_size = 1024;
    const access_pos = 100;
    const access_len = 50;

    // Should not panic for valid buffer access
    fatal_assertions.fatal_assert_buffer_bounds(access_pos, access_len, buffer_size, @src());
}

test "file operation validation passes for successful operations" {
    // Should not panic for successful operations
    fatal_assertions.fatal_assert_file_operation(true, "test_write", "/test/path", @src());
}

test "crc validation passes for matching checksums" {
    const expected_crc: u64 = 0x1234567890ABCDEF;
    const actual_crc: u64 = 0x1234567890ABCDEF;

    // Should not panic for matching checksums
    fatal_assertions.fatal_assert_crc_valid(actual_crc, expected_crc, "test data", @src());
}

test "protocol invariant validation passes for satisfied conditions" {
    // Should not panic when invariant is satisfied
    fatal_assertions.fatal_assert_protocol_invariant(true, "test_protocol", @src());
}

test "resource limit validation passes for usage within bounds" {
    const current_usage: u64 = 500;
    const limit: u64 = 1000;

    // Should not panic when usage is within limits
    fatal_assertions.fatal_assert_resource_limit(current_usage, limit, "memory", @src());
}

test "fatal assertion framework integrates with validation workflows" {
    const allocator = testing.allocator;

    // Simulate a validation workflow that uses multiple assertions

    // Step 1: Validate block ID
    const block_id = BlockId.from_bytes([_]u8{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
    });
    fatal_assertions.fatal_assert_block_id_valid(block_id, @src());

    // Step 2: Validate memory alignment
    const test_buffer = try allocator.alignedAlloc(u8, .@"8", 256);
    defer allocator.free(test_buffer);
    fatal_assertions.fatal_assert_memory_aligned(test_buffer.ptr, 8, @src());

    // Step 3: Validate buffer bounds
    const buffer_access_pos = 10;
    const buffer_access_len = 50;
    fatal_assertions.fatal_assert_buffer_bounds(buffer_access_pos, buffer_access_len, test_buffer.len, @src());

    // Step 4: Validate resource usage
    fatal_assertions.fatal_assert_resource_limit(test_buffer.len, 1024, "test_buffer", @src());

    // All validations passed - test succeeds
}

test "fatal context header formatting is consistent" {
    var buffer = std.array_list.Managed(u8).init(testing.allocator);
    defer buffer.deinit();

    const src = @src();
    const context = FatalContext.init(
        .invariant_violation,
        "Test invariant failed",
        src.file,
        src.line,
        src.fn_name,
    );

    try context.format_header(buffer.writer());
    const header = buffer.items;

    // Verify header format
    try testing.expect(std.mem.indexOf(u8, header, "INVARIANT VIOLATION") != null);
    try testing.expect(std.mem.indexOf(u8, header, "Test invariant failed") != null);
}

// NOTE: We don't test the actual panic conditions here because they would
// terminate the test process. In a real production environment, these
// assertions would be caught by the crash reporting system and logged
// with full context for debugging.
