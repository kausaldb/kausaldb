//! End-to-end test registry for binary interface tests.
//!
//! This file imports all e2e test modules to run binary interface
//! validation through subprocess execution.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

/// The runtime maximum log level.
/// One of: .err, .warn, .info, .debug
pub var log_level_runtime: std.log.Level = @enumFromInt(@intFromEnum(build_options.log_level));

pub fn log_runtime(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) <= @intFromEnum(log_level_runtime)) {
        std.log.defaultLog(message_level, scope, format, args);
    }
}

pub const std_options: std.Options = .{
    // The comptime log_level. This needs to be debug - otherwise messages are compiled out.
    // The runtime filtering is handled by log_level_runtime.
    .log_level = .debug,
    .logFn = log_runtime,
};

comptime {
    _ = @import("e2e/harness.zig");
    _ = @import("e2e/core_cli.zig");
    _ = @import("e2e/workspace.zig");
    _ = @import("e2e/query.zig");
    _ = @import("e2e/errors.zig");
    _ = @import("e2e/shell.zig");
    _ = @import("e2e/storage.zig");
    _ = @import("e2e/harness.zig");
}
