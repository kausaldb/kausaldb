//! Fatal assertion validation framework for KausalDB testing.
//!
//! Provides enhanced fatal assertion testing with categorization and context tracking.

const std = @import("std");

pub const FatalCategory = enum {
    memory_corruption,
    state_invariant,
    data_integrity,
    resource_exhaustion,
    protocol_violation,
    invariant_violation,

    pub fn description(self: FatalCategory) []const u8 {
        return switch (self) {
            .memory_corruption => "MEMORY CORRUPTION",
            .state_invariant => "STATE INVARIANT",
            .data_integrity => "DATA INTEGRITY",
            .resource_exhaustion => "RESOURCE EXHAUSTION",
            .protocol_violation => "PROTOCOL VIOLATION",
            .invariant_violation => "INVARIANT VIOLATION",
        };
    }
};

pub const FatalContext = struct {
    category: FatalCategory,
    message: []const u8,
    file: []const u8,
    line: u32,
    function: []const u8,

    pub fn init(category: FatalCategory, message: []const u8, file: []const u8, line: u32, function: []const u8) FatalContext {
        return FatalContext{
            .category = category,
            .message = message,
            .file = file,
            .line = line,
            .function = function,
        };
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
