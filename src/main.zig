/// Main entry point for `kausal` CLI.
///
const std = @import("std");
const build_options = @import("build_options");

const stdx = @import("core/stdx.zig");
const kausal_cli = @import("cli/cli.zig");

const log = std.log.scoped(.kausal_cli);

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
        stdx.log_with_timestamp(message_level, scope, format, args);
    }
}

pub const std_options: std.Options = .{
    // The comptime log_level. This needs to be debug - otherwise messages are compiled out.
    // The runtime filtering is handled by log_level_runtime.
    .log_level = .debug,
    .logFn = log_runtime,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments to override log level
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Filter out --log-level arguments and create a new args array for the CLI
    const ArrayList = std.ArrayList([]const u8);
    var filtered_args = ArrayList{};
    defer filtered_args.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--log-level") and i + 1 < args.len) {
            const level_str = args[i + 1];
            if (std.meta.stringToEnum(std.log.Level, level_str)) |level| {
                log_level_runtime = level;
                log.debug("Runtime log level set to: {s}", .{@tagName(log_level_runtime)});
            } else {
                log.warn("Invalid log level: {s}, using default: {s}", .{ level_str, @tagName(log_level_runtime) });
            }
            i += 1; // Skip the level argument
        } else {
            try filtered_args.append(allocator, args[i]);
        }
    }

    log.debug("KausalDB CLI starting with log level: {s}", .{@tagName(log_level_runtime)});

    try kausal_cli.run_with_args(filtered_args.items);
}
