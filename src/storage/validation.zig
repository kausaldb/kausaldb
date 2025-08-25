//! Storage validation layer for detecting corruption and invariant violations.
//!
//! Provides comprehensive validation of storage engine data structures with
//! zero overhead in release builds. Validates blocks, WAL entries, SSTables,
//! and graph relationships to catch corruption early and provide detailed
//! debugging information.
//!
//! Design rationale: Memory corruption is insidious and hard to debug. This
//! module provides systematic validation at critical points to catch issues
//! immediately rather than when they manifest as crashes. All checks compile
//! to nothing in release builds for zero runtime overhead.

const std = @import("std");
const builtin = @import("builtin");

const assert_mod = @import("../core/assert.zig");
const memory = @import("../core/memory.zig");
const context_block = @import("../core/types.zig");
const wal = @import("wal.zig");
const sstable = @import("sstable.zig");

const assert = assert_mod.assert;
const fatal_assert = assert_mod.fatal_assert;
const ContextBlock = context_block.ContextBlock;
const BlockId = context_block.BlockId;
const GraphEdge = context_block.GraphEdge;
const WALEntry = wal.WALEntry;
const SSTableHeader = sstable.SSTableHeader;
const ArenaCoordinator = memory.ArenaCoordinator;

/// Validation results for detailed error reporting.
pub const ValidationResult = struct {
    valid: bool,
    error_count: u32,
    warnings: u32,
    context: []const u8,
    details: ?[]const u8,
};

/// Validate a context block for internal consistency.
pub fn validate_block(block: *const ContextBlock) ValidationResult {
    if (builtin.mode != .Debug) {
        return .{ .valid = true, .error_count = 0, .warnings = 0, .context = "", .details = null };
    }

    var errors: u32 = 0;
    var warnings: u32 = 0;

    // Check block ID is non-zero
    if (block.id.is_zero()) {
        errors += 1;
        return .{
            .valid = false,
            .error_count = errors,
            .warnings = warnings,
            .context = "Block validation",
            .details = "Block ID cannot be zero",
        };
    }

    // Validate content is not empty
    if (block.content.len == 0) {
        warnings += 1;
    }

    // Check for null bytes in content (potential corruption)
    var null_count: usize = 0;
    for (block.content) |byte| {
        if (byte == 0) null_count += 1;
    }
    if (null_count > block.content.len / 2) {
        errors += 1;
        return .{
            .valid = false,
            .error_count = errors,
            .warnings = warnings,
            .context = "Block validation",
            .details = "Content appears corrupted (excessive null bytes)",
        };
    }

    // Validate source URI format
    if (block.source_uri.len == 0) {
        errors += 1;
    } else if (!std.mem.containsAtLeast(u8, block.source_uri, 1, "://")) {
        warnings += 1; // URI should have protocol
    }

    // Validate metadata is valid JSON if present
    if (block.metadata_json.len > 0) {
        if (block.metadata_json[0] != '{' or block.metadata_json[block.metadata_json.len - 1] != '}') {
            warnings += 1; // Metadata should be JSON object
        }
    }

    return .{
        .valid = errors == 0,
        .error_count = errors,
        .warnings = warnings,
        .context = "Block validation",
        .details = null,
    };
}

/// Validate a graph edge for consistency.
pub fn validate_edge(edge: *const GraphEdge) ValidationResult {
    if (builtin.mode != .Debug) {
        return .{ .valid = true, .error_count = 0, .warnings = 0, .context = "", .details = null };
    }

    var errors: u32 = 0;

    // Check edge endpoints are valid
    if (edge.source_id.is_zero()) {
        errors += 1;
        return .{
            .valid = false,
            .error_count = errors,
            .warnings = 0,
            .context = "Edge validation",
            .details = "Edge source_id cannot be zero",
        };
    }

    if (edge.target_id.is_zero()) {
        errors += 1;
        return .{
            .valid = false,
            .error_count = errors,
            .warnings = 0,
            .context = "Edge validation",
            .details = "Edge target_id cannot be zero",
        };
    }

    // Check for self-loops (usually indicates corruption)
    if (edge.source_id.eql(edge.target_id)) {
        return .{
            .valid = false,
            .error_count = 1,
            .warnings = 0,
            .context = "Edge validation",
            .details = "Self-loop detected (source_id == target_id)",
        };
    }

    return .{
        .valid = errors == 0,
        .error_count = errors,
        .warnings = 0,
        .context = "Edge validation",
        .details = null,
    };
}

/// Validate WAL entry structure and checksum.
pub fn validate_wal_entry(entry: *const WALEntry, data: []const u8) ValidationResult {
    if (builtin.mode != .Debug) {
        return .{ .valid = true, .error_count = 0, .warnings = 0, .context = "", .details = null };
    }

    var errors: u32 = 0;

    // Entry type validation prevents processing of corrupted WAL data.
    // Invalid types could indicate bit flips, partial writes, or malicious data.
    const valid_type = switch (entry.entry_type) {
        .put_block, .delete_block, .add_edge, .remove_edge, .checkpoint => true,
        else => false,
    };

    if (!valid_type) {
        errors += 1;
        return .{
            .valid = false,
            .error_count = errors,
            .warnings = 0,
            .context = "WAL entry validation",
            .details = "Invalid entry type",
        };
    }

    // Validate size bounds
    if (entry.size == 0 or entry.size > 10 * 1024 * 1024) { // 10MB max entry
        errors += 1;
        return .{
            .valid = false,
            .error_count = errors,
            .warnings = 0,
            .context = "WAL entry validation",
            .details = "Entry size out of bounds",
        };
    }

    // Validate data length matches declared size
    if (data.len != entry.size) {
        errors += 1;
        return .{
            .valid = false,
            .error_count = errors,
            .warnings = 0,
            .context = "WAL entry validation",
            .details = "Data length mismatch",
        };
    }

    // Validate checksum
    const computed_checksum = compute_crc64(data);
    if (computed_checksum != entry.checksum) {
        errors += 1;
        return .{
            .valid = false,
            .error_count = errors,
            .warnings = 0,
            .context = "WAL entry validation",
            .details = "Checksum mismatch",
        };
    }

    return .{
        .valid = errors == 0,
        .error_count = errors,
        .warnings = 0,
        .context = "WAL entry validation",
        .details = null,
    };
}

/// Validate SSTable header for corruption.
pub fn validate_sstable_header(header: *const SSTableHeader) ValidationResult {
    if (builtin.mode != .Debug) {
        return .{ .valid = true, .error_count = 0, .warnings = 0, .context = "", .details = null };
    }

    var errors: u32 = 0;

    // Check magic number
    if (header.magic != SSTableHeader.MAGIC) {
        errors += 1;
        return .{
            .valid = false,
            .error_count = errors,
            .warnings = 0,
            .context = "SSTable header validation",
            .details = "Invalid magic number",
        };
    }

    // Version bounds prevent processing files from incompatible future versions.
    // Upper limit guards against integer overflow attacks via crafted headers.
    if (header.version == 0 or header.version > 100) {
        errors += 1;
        return .{
            .valid = false,
            .error_count = errors,
            .warnings = 0,
            .context = "SSTable header validation",
            .details = "Invalid version number",
        };
    }

    // Enforce SSTable size limits to prevent memory exhaustion attacks
    if (header.block_count > 1_000_000) { // Sanity check: 1M blocks per SSTable max
        errors += 1;
        return .{
            .valid = false,
            .error_count = errors,
            .warnings = 0,
            .context = "SSTable header validation",
            .details = "Block count exceeds maximum",
        };
    }

    // Validate ID range
    if (header.block_count > 0 and header.min_block_id.compare(header.max_block_id) != .lt) {
        errors += 1;
        return .{
            .valid = false,
            .error_count = errors,
            .warnings = 0,
            .context = "SSTable header validation",
            .details = "Invalid block ID range (min >= max)",
        };
    }

    return .{
        .valid = errors == 0,
        .error_count = errors,
        .warnings = 0,
        .context = "SSTable header validation",
        .details = null,
    };
}

/// Validate arena coordinator state.
pub fn validate_arena_coordinator(coordinator: *const ArenaCoordinator) ValidationResult {
    if (builtin.mode != .Debug) {
        return .{ .valid = true, .error_count = 0, .warnings = 0, .context = "", .details = null };
    }

    var errors: u32 = 0;
    var warnings: u32 = 0;

    // Check arena pointer is valid
    if (coordinator.arena == null) {
        errors += 1;
        return .{
            .valid = false,
            .error_count = errors,
            .warnings = warnings,
            .context = "Arena coordinator validation",
            .details = "Arena pointer is null",
        };
    }

    // Validate arena state
    const arena = coordinator.arena.?;
    const capacity = arena.queryCapacity();

    // Check for reasonable memory usage
    if (capacity > 1024 * 1024 * 1024) { // 1GB warning threshold
        warnings += 1;
    }

    // Check for memory exhaustion
    if (capacity > 4 * 1024 * 1024 * 1024) { // 4GB error threshold
        errors += 1;
        return .{
            .valid = false,
            .error_count = errors,
            .warnings = warnings,
            .context = "Arena coordinator validation",
            .details = "Arena memory usage exceeds 4GB",
        };
    }

    return .{
        .valid = errors == 0,
        .error_count = errors,
        .warnings = warnings,
        .context = "Arena coordinator validation",
        .details = null,
    };
}

/// Validate memory buffer for common corruption patterns.
pub fn validate_buffer(buffer: []const u8, expected_pattern: ?u8) ValidationResult {
    if (builtin.mode != .Debug) {
        return .{ .valid = true, .error_count = 0, .warnings = 0, .context = "", .details = null };
    }

    if (buffer.len == 0) {
        return .{
            .valid = true,
            .error_count = 0,
            .warnings = 0,
            .context = "Buffer validation",
            .details = null,
        };
    }

    var errors: u32 = 0;

    // Check for poison pattern (0xDE indicates freed memory)
    var poison_count: usize = 0;
    for (buffer) |byte| {
        if (byte == 0xDE) poison_count += 1;
    }

    if (poison_count == buffer.len) {
        errors += 1;
        return .{
            .valid = false,
            .error_count = errors,
            .warnings = 0,
            .context = "Buffer validation",
            .details = "Buffer contains poison pattern (use-after-free)",
        };
    }

    // Check for expected pattern if provided
    if (expected_pattern) |pattern| {
        var mismatch_count: usize = 0;
        for (buffer) |byte| {
            if (byte != pattern) mismatch_count += 1;
        }

        if (mismatch_count > buffer.len / 10) { // Allow 10% deviation
            errors += 1;
            return .{
                .valid = false,
                .error_count = errors,
                .warnings = 0,
                .context = "Buffer validation",
                .details = "Buffer pattern mismatch",
            };
        }
    }

    // Check for canary values (deadbeef, cafebabe, etc)
    if (buffer.len >= 8) {
        const first_qword = std.mem.readInt(u64, buffer[0..8], .little);
        const last_qword = std.mem.readInt(u64, buffer[buffer.len - 8 ..][0..8], .little);

        const known_canaries = [_]u64{
            0xDEADBEEF_CAFEBABE,
            0xFEEDFACE_DEADC0DE,
            0xBAADF00D_DEADBEEF,
        };

        for (known_canaries) |canary| {
            if (first_qword == canary or last_qword == canary) {
                errors += 1;
                return .{
                    .valid = false,
                    .error_count = errors,
                    .warnings = 0,
                    .context = "Buffer validation",
                    .details = "Buffer contains debug canary values",
                };
            }
        }
    }

    return .{
        .valid = errors == 0,
        .error_count = errors,
        .warnings = 0,
        .context = "Buffer validation",
        .details = null,
    };
}

/// Batch validation for multiple blocks.
pub fn validate_blocks(blocks: []const ContextBlock) ValidationResult {
    if (builtin.mode != .Debug) {
        return .{ .valid = true, .error_count = 0, .warnings = 0, .context = "", .details = null };
    }

    var total_errors: u32 = 0;
    var total_warnings: u32 = 0;

    for (blocks) |*block| {
        const result = validate_block(block);
        total_errors += result.error_count;
        total_warnings += result.warnings;

        if (!result.valid) {
            return .{
                .valid = false,
                .error_count = total_errors,
                .warnings = total_warnings,
                .context = "Batch block validation",
                .details = result.details,
            };
        }
    }

    return .{
        .valid = total_errors == 0,
        .error_count = total_errors,
        .warnings = total_warnings,
        .context = "Batch block validation",
        .details = null,
    };
}

/// Simple CRC64 implementation for checksum validation.
fn compute_crc64(data: []const u8) u64 {
    const poly: u64 = 0xC96C5795D7870F42; // ECMA-182 polynomial
    var crc: u64 = 0xFFFFFFFFFFFFFFFF;

    for (data) |byte| {
        crc ^= @as(u64, byte);
        var j: u8 = 0;
        while (j < 8) : (j += 1) {
            if ((crc & 1) != 0) {
                crc = (crc >> 1) ^ poly;
            } else {
                crc = crc >> 1;
            }
        }
    }

    return crc ^ 0xFFFFFFFFFFFFFFFF;
}

// Tests
test "validate_block detects corruption" {
    // Skip validation tests in non-Debug builds since validation is compiled out
    if (builtin.mode != .Debug) return;

    const invalid_block = ContextBlock{
        .id = BlockId.zero(), // Invalid: zero ID
        .version = 1,
        .content = "test",
        .source_uri = "test://file",
        .metadata_json = "{}",
    };

    const result = validate_block(&invalid_block);
    try std.testing.expect(!result.valid);
    try std.testing.expect(result.error_count > 0);
}

test "validate_edge detects self-loops" {
    // Skip validation tests in non-Debug builds since validation is compiled out
    if (builtin.mode != .Debug) return;

    const self_loop = GraphEdge{
        .source_id = BlockId.from_u64(42),
        .target_id = BlockId.from_u64(42), // Self-loop
        .edge_type = .calls,
    };

    const result = validate_edge(&self_loop);
    try std.testing.expect(!result.valid);
}

test "validate_buffer detects poison pattern" {
    // Skip validation tests in non-Debug builds since validation is compiled out
    if (builtin.mode != .Debug) return;

    var poisoned = [_]u8{0xDE} ** 64;

    const result = validate_buffer(&poisoned, null);
    try std.testing.expect(!result.valid);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.details.?, 1, "use-after-free"));
}

test "validate_buffer detects canary values" {
    // Skip validation tests in non-Debug builds since validation is compiled out
    if (builtin.mode != .Debug) return;

    var buffer: [16]u8 = undefined;
    std.mem.writeInt(u64, buffer[0..8], 0xDEADBEEF_CAFEBABE, .little);
    std.mem.writeInt(u64, buffer[8..16], 0x1234567890ABCDEF, .little);

    const result = validate_buffer(&buffer, null);
    try std.testing.expect(!result.valid);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.details.?, 1, "canary"));
}

test "batch validation aggregates errors" {
    // Skip validation tests in non-Debug builds since validation is compiled out
    if (builtin.mode != .Debug) return;

    const blocks = [_]ContextBlock{
        .{
            .id = BlockId.from_u64(1),
            .version = 1,
            .content = "valid",
            .source_uri = "test://file1",
            .metadata_json = "{}",
        },
        .{
            .id = BlockId.zero(), // Invalid
            .version = 1,
            .content = "invalid",
            .source_uri = "test://file2",
            .metadata_json = "{}",
        },
    };

    const result = validate_blocks(&blocks);
    try std.testing.expect(!result.valid);
}
