//! Fatal assertion validation framework for KausalDB testing.
//!
//! Provides enhanced fatal assertion testing with categorization and context tracking.

const std = @import("std");

pub const FatalCategory = enum {
    memory_corruption,
    state_invariant,
    data_integrity,
    data_corruption,
    resource_exhaustion,
    protocol_violation,
    invariant_violation,
    logic_error,
    security_violation,

    pub fn description(self: FatalCategory) []const u8 {
        return switch (self) {
            .memory_corruption => "MEMORY CORRUPTION",
            .state_invariant => "STATE INVARIANT",
            .data_integrity => "DATA INTEGRITY",
            .data_corruption => "DATA CORRUPTION",
            .resource_exhaustion => "RESOURCE EXHAUSTION",
            .protocol_violation => "PROTOCOL VIOLATION",
            .invariant_violation => "INVARIANT VIOLATION",
            .logic_error => "LOGIC ERROR",
            .security_violation => "SECURITY VIOLATION",
        };
    }
};

pub const FatalContext = struct {
    category: FatalCategory,
    message: []const u8,
    component: []const u8,
    operation: []const u8,
    file: []const u8,
    line: u32,
    function: []const u8,
    timestamp: u64,

    pub fn init(category: FatalCategory, message: []const u8, file: []const u8, line: u32, function: []const u8) FatalContext {
        return FatalContext{
            .category = category,
            .message = message,
            .component = "Test Component",
            .operation = "Test Operation",
            .file = file,
            .line = line,
            .function = function,
            .timestamp = @intCast(std.time.timestamp()),
        };
    }

    pub fn format_header(self: FatalContext, writer: anytype) !void {
        try writer.print("[FATAL:{s}] {s} in {s} at {s}:{d}", .{
            self.category.description(),
            self.message,
            self.function,
            self.file,
            self.line,
        });
    }

    pub fn format_diagnostic(self: FatalContext, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "[FATAL:{s}] {s} at {s}:{d} in {s}", .{
            self.category.description(),
            self.message,
            self.file,
            self.line,
            self.function,
        });
    }
};

pub fn assert_fatal_context(category: FatalCategory, message: []const u8, comptime src: std.builtin.SourceLocation) FatalContext {
    return FatalContext.init(category, message, src.file, src.line, src.fn_name);
}

pub fn validate_fatal_assertion(expected_category: FatalCategory, test_fn: anytype) !void {
    // Mock validation for testing - in real implementation would capture actual fatal assertions
    _ = expected_category;
    try test_fn();
}

// Specific fatal assertion functions for KausalDB validation

const BlockId = @import("../core/types.zig").BlockId;

pub fn fatal_assert_block_id_valid(block_id: BlockId, src: std.builtin.SourceLocation) void {
    // In production, this would trigger a fatal assertion if invalid
    // For testing, we validate the block_id is non-zero
    const zero_id = BlockId.from_bytes([_]u8{0} ** 16);
    if (block_id.eql(zero_id)) {
        std.debug.panic("Invalid BlockId: all zeros at {s}:{d}", .{ src.file, src.line });
    }
}

pub fn fatal_assert_memory_aligned(ptr: *const anyopaque, alignment: usize, src: std.builtin.SourceLocation) void {
    // Check if pointer is aligned to the specified boundary
    const addr = @intFromPtr(ptr);
    if (addr % alignment != 0) {
        std.debug.panic("Memory not aligned to {} bytes at {s}:{d}", .{ alignment, src.file, src.line });
    }
}

pub fn fatal_assert_edge_valid(edge: anytype, src: std.builtin.SourceLocation) void {
    // Validate edge has valid source and target
    if (edge.source_id == 0 or edge.target_id == 0) {
        std.debug.panic("Invalid edge with zero ID at {s}:{d}", .{ src.file, src.line });
    }
}

pub fn fatal_assert_buffer_size(size: usize, max_size: usize, src: std.builtin.SourceLocation) void {
    // Validate buffer size is within bounds
    if (size > max_size) {
        std.debug.panic("Buffer size {} exceeds maximum {} at {s}:{d}", .{ size, max_size, src.file, src.line });
    }
}

pub fn fatal_assert_buffer_bounds(pos: usize, len: usize, buffer_len: usize, src: std.builtin.SourceLocation) void {
    // Validate buffer access is within bounds
    if (pos + len > buffer_len) {
        std.debug.panic("Buffer access out of bounds: pos {} + len {} > buffer_len {} at {s}:{d}", .{ pos, len, buffer_len, src.file, src.line });
    }
}

pub fn fatal_assert_file_operation(success: bool, operation: []const u8, path: []const u8, src: std.builtin.SourceLocation) void {
    // Validate file operation succeeded
    if (!success) {
        std.debug.panic("File operation '{s}' failed for path '{s}' at {s}:{d}", .{ operation, path, src.file, src.line });
    }
}

pub fn fatal_assert_crc_valid(actual_crc: u64, expected_crc: u64, data_description: []const u8, src: std.builtin.SourceLocation) void {
    // Validate CRC checksum matches expected value
    if (actual_crc != expected_crc) {
        std.debug.panic("CRC mismatch for {s}: expected 0x{x}, got 0x{x} at {s}:{d}", .{ data_description, expected_crc, actual_crc, src.file, src.line });
    }
}

pub fn fatal_assert_wal_entry_valid(entry: anytype, src: std.builtin.SourceLocation) void {
    // Validate WAL entry has proper structure
    _ = entry;
    _ = src;
    // Mock implementation - in production would validate magic, checksums, etc.
}

pub fn fatal_assert_context_transition(from_state: anytype, to_state: anytype, src: std.builtin.SourceLocation) void {
    // Validate state transition is legal
    _ = from_state;
    _ = to_state;
    _ = src;
    // Mock implementation - in production would check valid state transitions
}

pub fn fatal_assert_protocol_invariant(condition: bool, protocol_name: []const u8, src: std.builtin.SourceLocation) void {
    // Validate protocol invariant holds
    if (!condition) {
        std.debug.panic("Protocol invariant violated for {s} at {s}:{d}", .{ protocol_name, src.file, src.line });
    }
}

pub fn fatal_assert_resource_limit(current: u64, limit: u64, resource_name: []const u8, src: std.builtin.SourceLocation) void {
    // Validate resource usage is within limits
    if (current > limit) {
        std.debug.panic("Resource limit exceeded for {s}: {d} > {d} at {s}:{d}", .{ resource_name, current, limit, src.file, src.line });
    }
}
