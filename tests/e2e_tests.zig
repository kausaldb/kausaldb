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
    _ = @import("e2e/cli_flag_validation.zig");
    _ = @import("e2e/core_commands.zig");
    _ = @import("e2e/debug_test.zig");
    _ = @import("e2e/entity_type_validation.zig");
    _ = @import("e2e/error_handling_scenarios.zig");
    _ = @import("e2e/find_function_accuracy_test.zig");
    _ = @import("e2e/harness.zig");
    _ = @import("e2e/ingestion_test.zig");
    _ = @import("e2e/query_commands.zig");
    _ = @import("e2e/relationship_commands_safety.zig");
    _ = @import("e2e/shell_scenarios.zig");
    _ = @import("e2e/storage_pressure_testing.zig");
    _ = @import("e2e/workspace_operations.zig");
    _ = @import("e2e/workspace_statistics_test.zig");
}
