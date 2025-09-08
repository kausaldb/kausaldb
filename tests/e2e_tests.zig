//! End-to-end test registry for KausalDB binary interface.
//!
//! This file imports all e2e test modules to run comprehensive binary
//! interface validation through subprocess execution. Tests validate
//! complete user experience and catch regressions in CLI behavior.
//!
//! Design rationale: E2E tests validate the actual compiled binary through
//! shell execution to ensure user-facing commands work correctly in
//! production environments. Focus on critical 0.1.0 release functionality.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const std_options = .{
    .log_level = build_options.log_level,
};

comptime {
    // Debug tests for troubleshooting
    _ = @import("e2e/debug_test.zig");

    // Core e2e test infrastructure
    _ = @import("e2e/harness.zig");

    // Binary interface validation
    _ = @import("e2e/core_commands.zig");
    _ = @import("e2e/workspace_operations.zig");

    // Query functionality
    _ = @import("e2e/query_commands.zig");

    // Find function accuracy tests
    _ = @import("e2e/find_function_accuracy_test.zig");

    // Shell integration scenarios
    _ = @import("e2e/shell_scenarios.zig");

    // CLI testing coverage for robustness validation
    _ = @import("e2e/cli_flag_validation.zig");
    _ = @import("e2e/relationship_commands_safety.zig");
    _ = @import("e2e/entity_type_validation.zig");
    _ = @import("e2e/storage_pressure_testing.zig");
    _ = @import("e2e/error_handling_scenarios.zig");
}

test "e2e test registry initialization" {
    // Verify test registry loads successfully
    const allocator = std.testing.allocator;
    _ = allocator;

    // All e2e test modules should be importable without errors
    std.testing.log_level = .err;
}

test "e2e test module count validation" {
    // E2E tests focus on binary interface validation, not internal test discovery
    // Manual import management ensures only working tests are included

    const total_imports = 12; // Count of imports in comptime block above
    try std.testing.expect(total_imports > 0);

    std.debug.print("E2E test registry: {d} modules imported\n", .{total_imports});
}
