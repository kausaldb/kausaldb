//! KausalDB main entry point and CLI interface.
//!
//! Orchestrates server startup, storage engine initialization, and signal handling
//! following KausalDB's single-threaded async I/O model. Coordinates two-phase
//! initialization and graceful shutdown across all subsystems.
//!
//! Design rationale: Single main thread eliminates data races and enables
//! deterministic behavior. Arena-per-subsystem memory management ensures
//! predictable cleanup during shutdown sequences.

const std = @import("std");
const build_options = @import("build_options");

pub const std_options: std.Options = .{
    .log_level = @enumFromInt(@intFromEnum(build_options.log_level)),
};

const commands = @import("cli/commands.zig");
const executor = @import("cli/executor.zig");
const concurrency = @import("core/concurrency.zig");

/// KausalDB main entry point and command-line interface.
///
/// Parses command-line arguments and delegates to appropriate subcommands.
/// Handles server startup, demo execution, and various database operations.
///
/// Returns error on invalid arguments or subsystem initialization failures.
pub fn main() !void {
    concurrency.init();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Handle standard UNIX flags before normal processing
    if (args.len >= 2) {
        const first_arg = args[1];
        if (std.mem.eql(u8, first_arg, "--help") or std.mem.eql(u8, first_arg, "-h")) {
            // Convert to help command
            const help_args = [_][:0]const u8{ args[0], "help" };
            var help_result = try commands.parse_command(allocator, &help_args);
            defer help_result.deinit();

            var context = try executor.ExecutionContext.init(allocator, ".kausal-data");
            defer context.deinit();
            try executor.execute_command(&context, help_result.command);
            return;
        }

        if (std.mem.eql(u8, first_arg, "--version") or std.mem.eql(u8, first_arg, "-v")) {
            // Convert to version command
            const version_args = [_][:0]const u8{ args[0], "version" };
            var version_result = try commands.parse_command(allocator, &version_args);
            defer version_result.deinit();

            var context = try executor.ExecutionContext.init(allocator, ".kausal-data");
            defer context.deinit();
            try executor.execute_command(&context, version_result.command);
            return;
        }
    }

    // Use configurable database path - defaults to .kausal-data for production
    const db_path = std.process.getEnvVarOwned(allocator, "KAUSAL_DB_PATH") catch ".kausal-data";
    defer if (!std.mem.eql(u8, db_path, ".kausal-data")) allocator.free(db_path);

    // Parse and execute command
    var parse_result = commands.parse_command(allocator, args) catch |err| switch (err) {
        commands.CommandError.UnknownCommand => {
            if (args.len >= 2) {
                std.debug.print("Unknown command: {s}\n", .{args[1]});
            }
            var context = try executor.ExecutionContext.init(allocator, db_path);
            defer context.deinit();
            try executor.execute_command(&context, .{ .help = .{} });
            std.process.exit(1);
        },
        commands.CommandError.InvalidSyntax, commands.CommandError.MissingRequiredArgument, commands.CommandError.TooManyArguments => {
            std.debug.print("Error: {}\n", .{err});
            std.process.exit(1);
        },
        else => |e| return e,
    };
    defer parse_result.deinit();

    var context = try executor.ExecutionContext.init(allocator, db_path);
    defer context.deinit();

    try executor.execute_command(&context, parse_result.command);
}
