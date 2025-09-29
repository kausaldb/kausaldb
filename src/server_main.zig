//! Binary entry point for `kausal-server` daemon.
//!
//! Clean separation between CLI parsing and server implementation.
//! Follows KausalDB coordinator pattern with proper component lifecycle.

const std = @import("std");
const build_options = @import("build_options");

const stdx = @import("core/stdx.zig");
const assert_mod = @import("core/assert.zig");
const concurrency = @import("core/concurrency.zig");
const error_context = @import("core/error_context.zig");
const daemon = @import("server/daemon.zig");
const config_mod = @import("server/config.zig");
const coordinator_mod = @import("server/coordinator.zig");
const network_server_mod = @import("server/network_server.zig");

const assert = assert_mod.assert;
const fatal_assert = assert_mod.fatal_assert;

const ServerConfig = config_mod.ServerConfig;
const ServerCoordinator = coordinator_mod.ServerCoordinator;
const NetworkServer = network_server_mod.NetworkServer;

pub const std_options: std.Options = .{
    // The comptime log_level. This needs to be debug - otherwise messages are compiled out.
    // The runtime filtering is handled by log_level_runtime.
    .log_level = .debug,
    .logFn = log_runtime,
};

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

const log = std.log.scoped(.kausaldb_server);

/// Server daemon commands
const ServerCommand = enum {
    start,
    stop,
    status,
    restart,
    help,
    version,

    fn from_string(cmd: []const u8) ?ServerCommand {
        if (std.mem.eql(u8, cmd, "start")) return .start;
        if (std.mem.eql(u8, cmd, "stop")) return .stop;
        if (std.mem.eql(u8, cmd, "status")) return .status;
        if (std.mem.eql(u8, cmd, "restart")) return .restart;
        if (std.mem.eql(u8, cmd, "help")) return .help;
        if (std.mem.eql(u8, cmd, "version")) return .version;
        return null;
    }
};

/// Exit codes following UNIX daemon conventions
const ExitCode = enum(u8) {
    success = 0,
    general_error = 1,
    misuse = 2,
    cannot_execute = 126,

    fn exit(self: ExitCode) noreturn {
        std.process.exit(@intFromEnum(self));
    }
};

/// Stop server using PID file
fn stop_server_by_port(allocator: std.mem.Allocator, port: u16) !ExitCode {
    daemon.stop_process(allocator, "/tmp", "kausaldb", port, 10) catch |err| {
        log.err("Failed to stop server: {}", .{err});
        return ExitCode.general_error;
    };
    return ExitCode.success;
}

/// Check server status using PID file
fn check_server_status(allocator: std.mem.Allocator, port: u16) !ExitCode {
    const status = try daemon.check_startup_status(allocator, "/tmp", "kausaldb", port);

    switch (status) {
        .can_start => {
            std.debug.print("Server on port {} is not running (no PID file)\n", .{port});
            return ExitCode.general_error;
        },
        .already_running => {
            const pid = try daemon.read_pid_file(allocator, "/tmp", "kausaldb", port);
            std.debug.print("Server is running (PID: {}) on port {}\n", .{ pid.?, port });
            return ExitCode.success;
        },
        .stale_pid_file => {
            std.debug.print("Server on port {} is not running (stale PID file)\n", .{port});
            daemon.remove_pid_file(allocator, "/tmp", "kausaldb", port);
            return ExitCode.general_error;
        },
    }
}

fn print_help() !void {
    const help_text =
        \\kausal-server - KausalDB high-performance database server
        \\
        \\USAGE:
        \\    kausal-server [COMMAND] [OPTIONS]
        \\
        \\COMMANDS:
        \\    start                        Start the server as a background daemon
        \\    stop                         Stop the running server gracefully
        \\    status                       Check if server is running
        \\    restart                      Stop and restart the server
        \\    help                         Show this help message
        \\    version                      Show version information
        \\
        \\OPTIONS:
        \\    --host <HOST>                Bind address (default: 127.0.0.1)
        \\    --port <PORT>                Port number (default: 3838)
        \\    --data-dir <PATH>            Data directory (default: .kausaldb-data)
        \\    --max-connections <N>        Max concurrent connections (default: 100)
        \\    --foreground                 Run in foreground (don't daemonize, useful for debugging)
        \\    --log-level <LEVEL>          Log level: debug, info, warn, err (default: info)
        \\
        \\EXAMPLES:
        \\    kausal-server start                   Start daemon with defaults
        \\    kausal-server start --foreground      Run in current terminal
        \\    kausal-server start --port 8080       Start on custom port
        \\    kausal-server stop                    Stop the server
        \\    kausal-server status                  Check server status
        \\
        \\PID file: /tmp/kausaldb-<port>.pid
        \\
        \\For more information, visit: https://github.com/kausaldb/kausaldb
        \\
    ;

    std.debug.print("{s}", .{help_text});
}

fn print_version() !void {
    std.debug.print("kausal-server 0.1.0\n", .{});
}

pub fn main() !void {
    concurrency.init();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const exit_code = run_server_main(allocator) catch |err| {
        error_context.log_server_error(err, error_context.ServerContext{
            .operation = "server_main",
        });
        return ExitCode.general_error.exit();
    };

    exit_code.exit();
}

fn run_server_main(allocator: std.mem.Allocator) !ExitCode {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const cmd_args = if (args.len > 1) args[1..] else &[_][]const u8{};

    const command = parse_server_command(cmd_args) catch {
        std.debug.print("Error: Invalid command. Use --help for usage information.\n", .{});
        return ExitCode.misuse;
    };

    switch (command) {
        .help => {
            try print_help();
            return ExitCode.success;
        },
        .version => {
            try print_version();
            return ExitCode.success;
        },
        .start => {
            return try start_server(allocator, cmd_args);
        },
        .stop => {
            const config = try config_mod.parse_server_args(allocator, cmd_args);
            return try stop_server_by_port(allocator, config.port);
        },
        .status => {
            const config = try config_mod.parse_server_args(allocator, cmd_args);
            return try check_server_status(allocator, config.port);
        },
        .restart => {
            return try restart_server(allocator, cmd_args);
        },
    }
}

fn parse_server_command(args: []const []const u8) !ServerCommand {
    if (args.len == 0) {
        return .start; // Default command
    }

    const command_str = args[0];
    return ServerCommand.from_string(command_str) orelse {
        std.debug.print("Unknown command: {s}\n", .{command_str});
        return error.InvalidCommand;
    };
}

/// Start server using coordinator pattern
fn start_server(allocator: std.mem.Allocator, cmd_args: []const []const u8) !ExitCode {
    const config = try config_mod.parse_server_args(allocator, cmd_args);

    // Check if server is already running
    const startup_status = try daemon.check_startup_status(allocator, "/tmp", "kausaldb", config.port);
    switch (startup_status) {
        .already_running => {
            const existing_pid = try daemon.read_pid_file(allocator, "/tmp", "kausaldb", config.port);
            std.debug.print("Server is already running with PID {}\n", .{existing_pid.?});
            return ExitCode.general_error;
        },
        .stale_pid_file => {
            daemon.remove_pid_file(allocator, "/tmp", "kausaldb", config.port);
        },
        .can_start => {
            // Good to start
        },
    }

    if (config.daemonize) {
        try daemon.daemonize("/tmp/kausaldb.log");
    }

    // Write PID file after daemonization
    const current_pid = stdx.getpid();
    try daemon.write_pid_file(allocator, "/tmp", "kausaldb", config.port, current_pid);

    // Create database coordinator
    var coordinator = ServerCoordinator.init(allocator, config);
    defer {
        coordinator.deinit();
        daemon.remove_pid_file(allocator, "/tmp", "kausaldb", config.port);
    }

    // Phase 2: Start database engines
    try coordinator.startup();
    defer coordinator.shutdown();

    // Create network server with coordinator dependency
    var network_server = NetworkServer.init(allocator, config, &coordinator);
    defer network_server.deinit();

    // Phase 2: Start network server
    try network_server.startup();
    defer network_server.shutdown();

    return ExitCode.success;
}

/// Restart server with proper shutdown/startup sequence
fn restart_server(allocator: std.mem.Allocator, cmd_args: []const []const u8) !ExitCode {
    const config = try config_mod.parse_server_args(allocator, cmd_args);
    _ = try stop_server_by_port(allocator, config.port);

    std.Thread.sleep(500 * std.time.ns_per_ms);

    // Verify server stopped
    const startup_status = try daemon.check_startup_status(allocator, "/tmp", "kausaldb", config.port);
    if (startup_status == .already_running) {
        std.debug.print("Failed to stop server, restart aborted\n", .{});
        return ExitCode.general_error;
    }

    return try start_server(allocator, cmd_args);
}
