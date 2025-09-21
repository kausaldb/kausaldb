//! End-to-end test registry for `kausal` and `kausal-server` binary interface.
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
    // Core consolidated test modules
    _ = @import("e2e/core_cli.zig");
    _ = @import("e2e/workspace.zig");
    _ = @import("e2e/query.zig");
    _ = @import("e2e/errors.zig");
    _ = @import("e2e/shell.zig");
    _ = @import("e2e/storage.zig");
    _ = @import("e2e/harness.zig");
}
