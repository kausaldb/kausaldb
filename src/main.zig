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

const cli = @import("cli/mod.zig");
const concurrency = @import("core/concurrency.zig");

const ExecutionContext = cli.ExecutionContext;

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

    // Parse command using structured parser
    var parse_result = cli.parse_command(allocator, args) catch |err| switch (err) {
        cli.CommandError.UnknownCommand => {
            if (args.len >= 2) {
                std.debug.print("Unknown command: {s}\n", .{args[1]});
            }
            const help_result = cli.ParseResult{
                .command = cli.Command{ .help = .{} },
                .allocator = allocator,
            };
            var context = try ExecutionContext.init(allocator, "kausal_data");
            defer context.deinit();
            try cli.execute_command(&context, help_result);
            std.process.exit(1);
        },
        cli.CommandError.InvalidArguments, cli.CommandError.MissingRequiredArgument, cli.CommandError.TooManyArguments => {
            std.debug.print("Error: {}\n", .{err});
            std.debug.print("Use 'kausaldb help' for usage information.\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer parse_result.deinit();

    // Execute command using structured executor
    var context = try ExecutionContext.init(allocator, "kausal_data");
    defer context.deinit();

    try cli.execute_command(&context, parse_result);
}
