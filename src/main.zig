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

// Core modules
const assert_mod = @import("core/assert.zig");
const concurrency = @import("core/concurrency.zig");
const error_context = @import("core/error_context.zig");

// CLI v2 modules
const cli = @import("cli/cli.zig");
const client_mod = @import("cli/client.zig");
const parser = @import("cli/parser.zig");
const renderer = @import("cli/renderer.zig");

// Re-declarations
const assert = assert_mod.assert;
const fatal_assert = assert_mod.fatal_assert;
const Client = client_mod.Client;
const Command = parser.Command;
const ClientError = client_mod.ClientError;

const log = std.log.scoped(.kausal_cli);

/// Default server configuration
const DEFAULT_HOST = "127.0.0.1";
const DEFAULT_PORT = 3838;

/// Exit codes following UNIX conventions
const ExitCode = enum(u8) {
    success = 0,
    general_error = 1,
    misuse = 2,
    server_unavailable = 3,
    not_found = 4,

    fn exit(self: ExitCode) noreturn {
        std.process.exit(@intFromEnum(self));
    }
};

/// Application error types
const AppError = error{
    InvalidArguments,
    ServerUnavailable,
    CommandFailed,
    RenderingFailed,
} || std.mem.Allocator.Error || ClientError || parser.ParseError;

pub fn main() !void {
    concurrency.assert_main_thread();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const exit_code = run_main(allocator) catch |err| switch (err) {
        error.InvalidArguments => {
            std.debug.print("Error: Invalid arguments. Use --help for usage information.\n", .{});
            return ExitCode.misuse.exit();
        },
        error.ServerUnavailable => {
            std.debug.print("Error: Cannot connect to kausaldb-server. Is it running?\n", .{});
            std.debug.print("Start server with: kausaldb-server start\n", .{});
            return ExitCode.server_unavailable.exit();
        },
        error.CommandFailed => {
            std.debug.print("Error: Command execution failed\n", .{});
            return ExitCode.general_error.exit();
        },
        error.RenderingFailed => {
            std.debug.print("Error: Failed to render command output\n", .{});
            return ExitCode.general_error.exit();
        },
        else => {
            error_context.log_server_error(err, error_context.ServerContext{
                .operation = "main_execution",
                .connection_id = 0,
            });
            return ExitCode.general_error.exit();
        },
    };

    exit_code.exit();
}

fn run_main(allocator: std.mem.Allocator) !ExitCode {
    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Skip program name
    const cmd_args = if (args.len > 1) args[1..] else &[_][]const u8{};

    const command = parser.parse_command(cmd_args) catch {
        return error.InvalidArguments;
    };

    // Handle local commands that don't require server connection
    switch (command) {
        .help => {
            try print_help();
            return ExitCode.success;
        },
        .version => {
            try print_version();
            return ExitCode.success;
        },
        else => {}, // Server commands handled below
    }

    // Create client connection
    var client = Client.init(allocator, .{
        .host = DEFAULT_HOST,
        .port = DEFAULT_PORT,
        .timeout_ms = 5000,
    });
    defer client.deinit();

    // Connect to server
    client.connect() catch |err| switch (err) {
        ClientError.ConnectionRefused, ClientError.ServerNotRunning => {
            return error.ServerUnavailable;
        },
        else => return err,
    };

    // Execute command
    const result = execute_command(&client, command) catch {
        return error.CommandFailed;
    };

    // Render output
    render_result(result) catch {
        return error.RenderingFailed;
    };

    return ExitCode.success;
}

fn execute_command(client: *Client, command: Command) !cli.CommandResult {
    switch (command) {
        .find => |find_cmd| {
            const response = try client.find_blocks(find_cmd.query, find_cmd.max_results);
            return cli.CommandResult{ .find = response };
        },
        .show => |show_cmd| {
            const response = switch (show_cmd.direction) {
                .callers => try client.show_callers(show_cmd.target, show_cmd.max_depth),
                .callees => try client.show_callees(show_cmd.target, show_cmd.max_depth),
                .imports => {
                    // Handle imports direction - placeholder for now
                    return cli.CommandResult{ .show = try client.show_callers(show_cmd.target, show_cmd.max_depth) };
                },
                .exports => {
                    // Handle exports direction - placeholder for now  
                    return cli.CommandResult{ .show = try client.show_callees(show_cmd.target, show_cmd.max_depth) };
                },
            };
            return cli.CommandResult{ .show = response };
        },
        .trace => |trace_cmd| {
            const response = try client.trace_execution(trace_cmd.source, trace_cmd.target, trace_cmd.max_depth);
            return cli.CommandResult{ .trace = response };
        },
        .link => |link_cmd| {
            const response = try client.link_codebase(link_cmd.path, link_cmd.name);
            return cli.CommandResult{ .operation = response };
        },
        .unlink => |unlink_cmd| {
            const response = try client.unlink_codebase(unlink_cmd.name);
            return cli.CommandResult{ .operation = response };
        },
        .sync => |sync_cmd| {
            const name = sync_cmd.name orelse return error.InvalidArguments;
            const response = try client.sync_workspace(name, sync_cmd.force);
            return cli.CommandResult{ .operation = response };
        },
        .status => {
            const response = try client.query_status();
            return cli.CommandResult{ .status = response };
        },
        .ping => {
            try client.ping();
            return cli.CommandResult{ .ping = {} };
        },
        else => {
            fatal_assert(false, "Unreachable: local commands should be handled earlier", .{});
            unreachable;
        },
    }
}

fn render_result(result: cli.CommandResult) !void {
    const stdout = std.fs.File{ .handle = 1 };
    var stdout_buffer: [8192]u8 = undefined;
    const writer = stdout.writer(&stdout_buffer);
    
    // Create allocator for renderer context
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var render_ctx = renderer.RenderContext.init(allocator, writer, .text);
    
    switch (result) {
        .find => |response| {
            try renderer.render_find_results(&render_ctx, response, false);
        },
        .show => |response| {
            try renderer.render_show_results(&render_ctx, response, "callees");
        },
        .trace => |response| {
            // TODO: Implement trace rendering function in renderer
            _ = response;
            _ = stdout.writeAll("Trace results (trace renderer function needed)\n") catch {};
        },
        .operation => |response| {
            try renderer.render_operation_result(&render_ctx, response);
        },
        .status => |response| {
            try renderer.render_status(&render_ctx, response, false);
        },
        .ping => {
            _ = stdout.writeAll("Server is responding\n") catch {};
        },
    }
}

fn print_help() !void {
    const help_text =
        \\kausal - KausalDB command-line interface
        \\
        \\USAGE:
        \\    kausal <COMMAND> [OPTIONS]
        \\
        \\COMMANDS:
        \\    find <query>                 Find blocks matching query
        \\    show callers <target>        Show functions that call target
        \\    show callees <target>        Show functions called by target
        \\    trace <source> <target>      Find execution paths between blocks
        \\    link <path> as <name>        Link codebase to workspace
        \\    unlink <name>                Remove codebase from workspace
        \\    sync <workspace>             Sync workspace with filesystem
        \\    status                       Show server status
        \\    ping                         Test server connectivity
        \\    help                         Show this help message
        \\    version                      Show version information
        \\
        \\OPTIONS:
        \\    --max-results <N>            Limit number of results (default: 20)
        \\    --max-depth <N>              Maximum traversal depth (default: 3)
        \\    --force                      Force operation (for sync)
        \\    --format <FORMAT>            Output format: text, json, csv (default: text)
        \\    --verbose, -v                Enable verbose output
        \\    --help, -h                   Show help information
        \\    --version                    Show version information
        \\
        \\EXAMPLES:
        \\    kausal find "init"
        \\    kausal show callers "StorageEngine.put_block"
        \\    kausal trace "main" "exit"
        \\    kausal link /path/to/repo as myproject
        \\    kausal sync myproject --force
        \\    kausal status
        \\
        \\For more information, visit: https://github.com/kausalco/kausaldb
        \\
    ;

    const stdout = std.fs.File{ .handle = 1 };
    _ = stdout.writeAll(help_text) catch {};
}

fn print_version() !void {
    const stdout = std.fs.File{ .handle = 1 };
    _ = stdout.writeAll("kausal 0.1.0\n") catch {};
}

test "CLI main functions compile" {
    // Compilation test to ensure all functions are well-formed
    _ = run_main;
    _ = execute_command;
    _ = render_result;
    _ = print_help;
    _ = print_version;
}
