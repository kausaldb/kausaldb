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
const natural_cli = @import("cli/natural_commands.zig");
const natural_executor = @import("cli/natural_executor.zig");
const concurrency = @import("core/concurrency.zig");

const ExecutionContext = cli.ExecutionContext;
const NaturalExecutionContext = natural_executor.NaturalExecutionContext;

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

    // Use configurable database path - defaults to .kausal-data for production
    const db_path = std.process.getEnvVarOwned(allocator, "KAUSAL_DB_PATH") catch ".kausal-data";
    defer if (!std.mem.eql(u8, db_path, ".kausal-data")) allocator.free(db_path);

    // Detect natural language commands vs legacy commands
    const use_natural_cli = detect_natural_command(args);

    if (use_natural_cli) {
        // Use new natural language CLI
        var natural_parse_result = natural_cli.parse_natural_command(allocator, args) catch |err| switch (err) {
            natural_cli.NaturalCommandError.UnknownCommand => {
                if (args.len >= 2) {
                    std.debug.print("Unknown command: {s}\n", .{args[1]});
                }
                var natural_context = try NaturalExecutionContext.init(allocator, db_path);
                defer natural_context.deinit();
                try natural_executor.execute_natural_command(&natural_context, .{ .help = .{} });
                std.process.exit(1);
            },
            natural_cli.NaturalCommandError.InvalidSyntax, natural_cli.NaturalCommandError.MissingRequiredArgument, natural_cli.NaturalCommandError.TooManyArguments => {
                std.debug.print("Error: {}\n", .{err});
                std.process.exit(1);
            },
            else => |e| return e,
        };
        defer natural_parse_result.deinit();

        var natural_context = try NaturalExecutionContext.init(allocator, db_path);
        defer natural_context.deinit();

        try natural_executor.execute_natural_command(&natural_context, natural_parse_result.command);
    } else {
        // Use legacy CLI for backward compatibility
        var parse_result = cli.parse_command(allocator, args) catch |err| switch (err) {
            cli.CommandError.UnknownCommand => {
                if (args.len >= 2) {
                    std.debug.print("Unknown command: {s}\n", .{args[1]});
                }
                const help_result = cli.ParseResult{
                    .command = cli.Command{ .help = .{} },
                    .allocator = allocator,
                };
                var context = try ExecutionContext.init(allocator, db_path);
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

        var context = try ExecutionContext.init(allocator, db_path);
        defer context.deinit();

        try cli.execute_command(&context, parse_result);
    }
}

/// Detect whether to use natural language CLI or legacy CLI
fn detect_natural_command(args: []const [:0]const u8) bool {
    // Natural CLI provides better user experience for help/exploration workflows
    if (args.len < 2) return true;

    const command = args[1];

    // Command list drives routing between natural and legacy CLI implementations
    const natural_commands = &[_][]const u8{ "link", "unlink", "sync", "find", "show", "trace", "status" };

    for (natural_commands) |natural_cmd| {
        if (std.mem.eql(u8, command, natural_cmd)) {
            return true;
        }
    }

    // System commands available in both
    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "version")) {
        return true; // Prefer natural CLI for these
    }

    // Legacy commands
    return false;
}
