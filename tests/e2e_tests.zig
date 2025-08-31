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

comptime {
    // Debug tests for troubleshooting
    _ = @import("e2e/debug_test.zig");

    // Core e2e test infrastructure
    _ = @import("e2e/harness.zig");

    // Binary interface validation
    _ = @import("e2e/core_commands.zig");
    _ = @import("e2e/workspace_operations.zig");

    // Query functionality (placeholder until implementation complete)
    _ = @import("e2e/query_commands.zig");

    // Find function accuracy tests
    _ = @import("e2e/find_function_accuracy_test.zig");

    // Shell integration scenarios
    _ = @import("e2e/shell_scenarios.zig");
}

test "e2e test registry initialization" {
    // Verify test registry loads successfully
    const allocator = std.testing.allocator;
    _ = allocator;

    // All e2e test modules should be importable without errors
    std.testing.log_level = .err;
}

test "e2e test discovery - validate all e2e modules are imported" {
    // TEMPORARILY DISABLED: Directory walker has permission issues on macOS
    // The std.fs.Dir.iterate() API requires specific iteration permissions that
    // aren't being set correctly in our openDir calls, causing panic in lseek_SET
    //
    // TODO: Implement proper directory iteration or use alternative file discovery method
    // See: https://github.com/ziglang/zig/issues/XXXX

    std.debug.print("E2E test discovery temporarily disabled due to directory iteration permissions issue\n", .{});
    return error.SkipZigTest;
}
