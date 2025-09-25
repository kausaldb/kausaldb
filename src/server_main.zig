//! Binary entry point for `kausal-server` daemon.
//!
//! Single-threaded database server using event loop architecture with a
//! connection manager handling concurrent connections.

const std = @import("std");
const build_options = @import("build_options");

const stdx = @import("core/stdx.zig");
const assert_mod = @import("core/assert.zig");
const concurrency = @import("core/concurrency.zig");
const error_context = @import("core/error_context.zig");
const memory = @import("core/memory.zig");
const vfs = @import("core/vfs.zig");
const production_vfs = @import("core/production_vfs.zig");
const storage = @import("storage/engine.zig");
const query_engine = @import("query/engine.zig");
const workspace_manager = @import("workspace/manager.zig");
const cli_protocol_handler = @import("server/cli_protocol.zig");
const protocol = @import("cli/protocol.zig");
const connection_manager = @import("server/connection_manager.zig");

const assert = assert_mod.assert;
const fatal_assert = assert_mod.fatal_assert;

const ArenaCoordinator = memory.ArenaCoordinator;
const StorageEngine = storage.StorageEngine;
const QueryEngine = query_engine.QueryEngine;
const WorkspaceManager = workspace_manager.WorkspaceManager;
const HandlerContext = cli_protocol_handler.HandlerContext;
const ConnectionManager = connection_manager.ConnectionManager;
const ConnectionManagerConfig = connection_manager.ConnectionManagerConfig;

const ConnectionHandlingError = error{
    ConnectionClosed,
    HandlerNotInitialized,
    InvalidHeader,
    PayloadTooLarge,
    InvalidMagic,
    VersionMismatch,
} || std.mem.Allocator.Error || std.posix.ReadError || std.posix.WriteError;

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

const log = std.log.scoped(.kausaldb_server);

/// Default server configuration values
const DEFAULT_PORT = 3838;
const DEFAULT_HOST = "127.0.0.1";
const DEFAULT_DATA_DIR = ".kausaldb-data";

fn construct_pid_file_path(allocator: std.mem.Allocator, port: u16) ![]u8 {
    return try std.fmt.allocPrint(allocator, "/tmp/kausaldb-{}.pid", .{port});
}

/// Global server reference used for signal handling
var global_server: ?*KausalServer = null;

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

/// Server configuration structure
const ServerConfig = struct {
    host: []const u8 = DEFAULT_HOST,
    port: u16 = DEFAULT_PORT,
    data_dir: []const u8 = DEFAULT_DATA_DIR,
    max_connections: u32 = 100,
    connection_timeout_sec: u32 = 300,
    daemonize: bool = true, // Default to daemon mode for production
    log_level: std.log.Level = @enumFromInt(@intFromEnum(build_options.log_level)),
    pid_file_path: ?[]const u8 = null,
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

/// KausalDB server state and coordination
const KausalServer = struct {
    allocator: std.mem.Allocator,
    config: ServerConfig,

    // Arena coordinators for subsystem memory management
    storage_arena: *ArenaCoordinator,
    query_arena: *ArenaCoordinator,
    workspace_arena: *ArenaCoordinator,

    // Database engine components
    storage_engine: ?*StorageEngine,
    query_engine: ?*QueryEngine,
    workspace_manager: ?*WorkspaceManager,

    // Network components
    server_socket: ?std.net.Server,
    connection_manager: ?*ConnectionManager,
    handler_context: ?*HandlerContext,

    // State management
    running: std.atomic.Value(bool),
    start_time: i64,

    pub fn init(allocator: std.mem.Allocator, config: ServerConfig) !KausalServer {
        concurrency.assert_main_thread();

        const storage_arena_allocator = try allocator.create(std.heap.ArenaAllocator);
        storage_arena_allocator.* = std.heap.ArenaAllocator.init(allocator);
        const storage_arena = try allocator.create(ArenaCoordinator);
        storage_arena.* = ArenaCoordinator.init(storage_arena_allocator);
        errdefer {
            storage_arena_allocator.deinit();
            allocator.destroy(storage_arena_allocator);
            allocator.destroy(storage_arena);
        }

        const query_arena_allocator = try allocator.create(std.heap.ArenaAllocator);
        query_arena_allocator.* = std.heap.ArenaAllocator.init(allocator);
        const query_arena = try allocator.create(ArenaCoordinator);
        query_arena.* = ArenaCoordinator.init(query_arena_allocator);
        errdefer {
            query_arena_allocator.deinit();
            allocator.destroy(query_arena_allocator);
            allocator.destroy(query_arena);
        }

        const workspace_arena_allocator = try allocator.create(std.heap.ArenaAllocator);
        workspace_arena_allocator.* = std.heap.ArenaAllocator.init(allocator);
        const workspace_arena = try allocator.create(ArenaCoordinator);
        workspace_arena.* = ArenaCoordinator.init(workspace_arena_allocator);
        errdefer {
            workspace_arena_allocator.deinit();
            allocator.destroy(workspace_arena_allocator);
            allocator.destroy(workspace_arena);
        }

        return KausalServer{
            .allocator = allocator,
            .config = config,
            .storage_arena = storage_arena,
            .query_arena = query_arena,
            .workspace_arena = workspace_arena,
            .storage_engine = null,
            .query_engine = null,
            .workspace_manager = null,
            .server_socket = null,
            .connection_manager = null,
            .handler_context = null,
            .running = std.atomic.Value(bool).init(false),
            .start_time = std.time.timestamp(),
        };
    }

    pub fn deinit(self: *KausalServer) void {
        concurrency.assert_main_thread();

        if (self.running.load(.monotonic)) {
            self.shutdown();
        }

        if (self.handler_context) |ctx| {
            self.allocator.destroy(ctx);
        }

        if (self.connection_manager) |cm| {
            cm.deinit();
            self.allocator.destroy(cm);
        }

        if (self.query_engine) |qe| {
            qe.deinit();
            self.allocator.destroy(qe);
        }

        if (self.storage_engine) |se| {
            se.deinit();
            self.allocator.destroy(se);
        }

        if (self.workspace_manager) |wm| {
            wm.deinit();
            self.allocator.destroy(wm);
        }

        self.workspace_arena.arena.deinit();
        self.allocator.destroy(self.workspace_arena.arena);
        self.allocator.destroy(self.workspace_arena);

        self.query_arena.arena.deinit();
        self.allocator.destroy(self.query_arena.arena);
        self.allocator.destroy(self.query_arena);

        self.storage_arena.arena.deinit();
        self.allocator.destroy(self.storage_arena.arena);
        self.allocator.destroy(self.storage_arena);
    }

    pub fn startup(self: *KausalServer) !void {
        concurrency.assert_main_thread();

        try install_signal_handler(self);

        log.info("Starting KausalDB server on {s}:{}", .{ self.config.host, self.config.port });

        const storage_config = storage.Config{};
        const production_vfs_backing_allocator = self.allocator;
        var production_vfs_instance = production_vfs.ProductionVFS.init(production_vfs_backing_allocator);
        const filesystem = production_vfs_instance.vfs();

        std.fs.cwd().makePath(self.config.data_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const abs_data_dir = if (std.fs.path.isAbsolute(self.config.data_dir))
            try self.allocator.dupe(u8, self.config.data_dir)
        else
            try std.fs.cwd().realpathAlloc(self.allocator, self.config.data_dir);
        defer self.allocator.free(abs_data_dir);

        self.storage_engine = try self.allocator.create(StorageEngine);
        self.storage_engine.?.* = try StorageEngine.init(
            self.allocator,
            filesystem,
            abs_data_dir,
            storage_config,
        );
        try self.storage_engine.?.startup();

        self.query_engine = try self.allocator.create(QueryEngine);
        self.query_engine.?.* = QueryEngine.init(
            self.allocator,
            self.storage_engine.?,
        );
        self.query_engine.?.startup();

        self.workspace_manager = try self.allocator.create(WorkspaceManager);
        self.workspace_manager.?.* = try WorkspaceManager.init(
            self.allocator,
            self.storage_engine.?,
        );
        try self.workspace_manager.?.startup();

        self.handler_context = try self.allocator.create(HandlerContext);
        self.handler_context.?.* = HandlerContext.init(
            self.allocator,
            self.storage_engine.?,
            self.query_engine.?,
            self.workspace_manager.?,
            self.start_time,
        );

        self.connection_manager = try self.allocator.create(ConnectionManager);
        self.connection_manager.?.* = ConnectionManager.init(
            self.allocator,
            ConnectionManagerConfig{
                .max_connections = self.config.max_connections,
                .connection_timeout_sec = self.config.connection_timeout_sec,
            },
        );
        try self.connection_manager.?.startup();

        const address = try std.net.Address.parseIp(self.config.host, self.config.port);

        self.server_socket = address.listen(.{
            .reuse_address = true,
        }) catch |err| {
            log.err("Failed to bind to address {any}: {}", .{ address, err });
            return err;
        };

        // Configure server socket for non-blocking I/O to prevent accept() blocking
        const server_flags = try std.posix.fcntl(self.server_socket.?.stream.handle, std.posix.F.GETFL, 0);
        const nonblock_flag = 1 << @bitOffsetOf(std.posix.O, "NONBLOCK");
        _ = try std.posix.fcntl(self.server_socket.?.stream.handle, std.posix.F.SETFL, server_flags | nonblock_flag);

        // Verify socket is actually listening
        const socket_addr = self.server_socket.?.listen_address;
        const actual_port = socket_addr.getPort();
        log.info("Server listening on {s}:{} (requested: {}, actual socket: {any})", .{ self.config.host, actual_port, self.config.port, socket_addr });

        self.running.store(true, .monotonic);
    }

    pub fn run_event_loop(self: *KausalServer) !void {
        concurrency.assert_main_thread();

        assert_mod.assert_fmt(self.running.load(.monotonic), "Server must be started before running", .{});
        fatal_assert(self.server_socket != null, "Network socket must be initialized", .{});
        fatal_assert(self.connection_manager != null, "Connection manager must be initialized", .{});
        fatal_assert(self.handler_context != null, "Handler context must be initialized", .{});

        log.info("Server ready to accept connections", .{});

        while (self.running.load(.monotonic)) {
            const ready_connections = self.connection_manager.?.poll_for_ready_connections(&self.server_socket.?) catch |err| {
                log.err("Connection polling failed: {}", .{err});
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            };

            for (ready_connections) |connection| {
                self.handle_connection_request(connection) catch |err| switch (err) {
                    ConnectionHandlingError.ConnectionClosed => {
                        self.connection_manager.?.close_connection(connection) catch |close_err| {
                            log.err("Failed to close connection {}: {}", .{ connection.connection_id, close_err });
                        };
                    },
                    else => {
                        log.err("Connection handling failed: {}", .{err});
                    },
                };
            }
        }

        log.info("Server event loop terminated", .{});
    }

    pub fn shutdown(self: *KausalServer) void {
        concurrency.assert_main_thread();

        if (!self.running.load(.monotonic)) return;

        log.info("Shutting down KausalDB server...", .{});

        self.running.store(false, .monotonic);

        // Close network socket to stop accepting connections
        if (self.server_socket) |*socket| {
            socket.deinit();
            self.server_socket = null;
        }

        // Close all active connections gracefully
        if (self.connection_manager) |cm| {
            cm.deinit();
        }

        // Shutdown components in reverse order
        if (self.workspace_manager) |wm| {
            wm.shutdown();
        }
        if (self.query_engine) |qe| {
            qe.shutdown();
        }

        if (self.storage_engine) |se| {
            se.shutdown() catch |err| {
                log.warn("Failed to shutdown storage engine: {}", .{err});
            };
        }

        // Clear global server reference
        global_server = null;

        log.info("Server shutdown complete", .{});
    }

    fn handle_connection_request(self: *KausalServer, connection: *connection_manager.ClientConnection) anyerror!void {
        const ctx = self.handler_context orelse {
            log.err("Handler context not initialized", .{});
            return ConnectionHandlingError.HandlerNotInitialized;
        };

        // Read message header from connection
        var header: protocol.MessageHeader = undefined;
        const header_bytes = std.mem.asBytes(&header);
        var total_read: usize = 0;

        while (total_read < header_bytes.len) {
            const bytes_read = connection.stream.read(header_bytes[total_read..]) catch |err| switch (err) {
                // THE FIX: Handle WouldBlock gracefully by sleeping briefly and retrying.
                error.WouldBlock => {
                    std.Thread.sleep(1 * std.time.ns_per_ms); // Prevent a tight spin-loop
                    continue;
                },
                else => |other_err| {
                    log.err("Error reading header bytes from connection {}: {}", .{ connection.connection_id, other_err });
                    return other_err;
                },
            };

            if (bytes_read == 0) {
                return ConnectionHandlingError.ConnectionClosed;
            }
            total_read += bytes_read;
        }

        header.validate() catch |err| {
            log.err("Connection {}: Header validation failed: {}", .{ connection.connection_id, err });
            return err;
        };

        // Read payload if present
        var payload: []u8 = &[_]u8{};
        if (header.payload_size > 0) {
            payload = connection.arena.allocator().alloc(u8, header.payload_size) catch |err| {
                log.err("Connection {}: Failed to allocate payload memory: {}", .{ connection.connection_id, err });
                return err;
            };

            total_read = 0;
            while (total_read < payload.len) {
                const bytes_read = connection.stream.read(payload[total_read..]) catch |err| switch (err) {
                    // APPLY THE SAME FIX to the payload read loop.
                    error.WouldBlock => {
                        std.Thread.sleep(1 * std.time.ns_per_ms);
                        continue;
                    },
                    else => |other_err| {
                        log.err("Connection {}: Error reading payload bytes: {}", .{ connection.connection_id, other_err });
                        return other_err;
                    },
                };

                if (bytes_read == 0) {
                    return ConnectionHandlingError.ConnectionClosed;
                }
                total_read += bytes_read;
            }
        } else {
            log.debug("Connection {}: No payload to read", .{connection.connection_id});
        }

        const response = try cli_protocol_handler.handle_cli_message(ctx.*, header.message_type, payload);
        defer connection.arena.allocator().free(response);

        // Send response back to client
        write_all_blocking(connection.stream, response) catch |err| {
            log.err("Connection {}: Failed to send response: {}", .{ connection.connection_id, err });
            return err;
        };
    }
};

fn signal_handler(sig: c_int) callconv(.c) void {
    _ = sig;

    if (global_server) |server| {
        // Signal the server to stop
        server.running.store(false, .monotonic);
        log.info("Received shutdown signal, initiating graceful shutdown...", .{});
    }
}

fn install_signal_handler(server: *KausalServer) !void {
    const builtin = @import("builtin");
    switch (builtin.os.tag) {
        .windows => {
            return;
        },
        else => {
            // Store server instance globally for signal handler access.
            // Gracefully shutdown the server when SIGTERM or SIGINT is received.
            global_server = server;

            var act = std.mem.zeroes(std.posix.Sigaction);
            act.handler = .{ .handler = signal_handler };
            act.flags = std.posix.SA.RESTART;

            _ = std.posix.sigaction(std.posix.SIG.TERM, &act, null);
            _ = std.posix.sigaction(std.posix.SIG.INT, &act, null);
        },
    }
}

/// Write PID to file for daemon management
fn write_pid_file(allocator: std.mem.Allocator, port: u16, pid: std.posix.pid_t) !void {
    const pid_file_path = try construct_pid_file_path(allocator, port);
    defer allocator.free(pid_file_path);

    const file = std.fs.cwd().createFile(pid_file_path, .{}) catch |err| {
        log.err("Failed to create PID file {s}: {}", .{ pid_file_path, err });
        return err;
    };
    defer file.close();

    const pid_str = try std.fmt.allocPrint(allocator, "{}\n", .{pid});
    defer allocator.free(pid_str);

    try file.writeAll(pid_str);
    log.info("Server PID {} written to {s}", .{ pid, pid_file_path });
}

/// Read PID from file
fn read_pid_file(allocator: std.mem.Allocator, port: u16) !?std.posix.pid_t {
    const pid_file_path = try construct_pid_file_path(allocator, port);
    defer allocator.free(pid_file_path);

    const file = std.fs.cwd().openFile(pid_file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const max_pid_len = 32;
    var buffer: [max_pid_len]u8 = undefined;
    const bytes_read = try file.readAll(&buffer);

    if (bytes_read == 0) return null;

    const pid_str = std.mem.trim(u8, buffer[0..bytes_read], " \n\r\t");
    return std.fmt.parseInt(std.posix.pid_t, pid_str, 10) catch null;
}

/// Remove PID file
fn remove_pid_file(allocator: std.mem.Allocator, port: u16) void {
    const pid_file_path = construct_pid_file_path(allocator, port) catch return;
    defer allocator.free(pid_file_path);

    std.fs.cwd().deleteFile(pid_file_path) catch |err| {
        log.warn("Failed to remove PID file {s}: {}", .{ pid_file_path, err });
    };
}

/// Check if process with given PID is running
fn is_process_running(pid: std.posix.pid_t) bool {
    // Check if process exists without actually sending a signal
    const result = std.c.kill(pid, 0);
    return result == 0;
}

/// Stop server using PID file
fn stop_server_by_port(allocator: std.mem.Allocator, port: u16) !ExitCode {
    const pid = try read_pid_file(allocator, port);

    if (pid == null) {
        log.info("No PID file found for port {}. Server may not be running.", .{port});
        return ExitCode.success;
    }

    const server_pid = pid.?;

    if (!is_process_running(server_pid)) {
        log.info("Process {} not running. Cleaning up stale PID file.", .{server_pid});
        remove_pid_file(allocator, port);
        return ExitCode.success;
    }

    log.info("Stopping server (PID: {}) on port {}...", .{ server_pid, port });

    // Send SIGTERM for graceful shutdown
    const kill_result = std.c.kill(server_pid, std.posix.SIG.TERM);
    if (kill_result != 0) {
        log.err("Failed to send SIGTERM to process {}: errno {}", .{ server_pid, kill_result });
        return ExitCode.general_error;
    }

    // Wait up to 10 seconds for graceful shutdown
    var attempts: u32 = 0;
    const max_attempts = 100; // 10 seconds with 100ms intervals

    while (attempts < max_attempts) {
        if (!is_process_running(server_pid)) {
            log.info("Server stopped gracefully", .{});
            remove_pid_file(allocator, port);
            return ExitCode.success;
        }

        std.Thread.sleep(100 * std.time.ns_per_ms);
        attempts += 1;
    }

    // Force kill if graceful shutdown failed
    log.warn("Graceful shutdown failed, force killing process {}", .{server_pid});
    _ = std.c.kill(server_pid, std.posix.SIG.KILL);
    remove_pid_file(allocator, port);

    return ExitCode.success;
}

/// Check server status using PID file
fn check_server_status(allocator: std.mem.Allocator, port: u16) !ExitCode {
    const pid = try read_pid_file(allocator, port);

    if (pid == null) {
        std.debug.print("Server on port {} is not running (no PID file)\n", .{port});
        return ExitCode.general_error;
    }

    const server_pid = pid.?;

    if (is_process_running(server_pid)) {
        std.debug.print("Server is running (PID: {}) on port {}\n", .{ server_pid, port });
        return ExitCode.success;
    } else {
        std.debug.print("Server on port {} is not running (stale PID file)\n", .{port});
        remove_pid_file(allocator, port);
        return ExitCode.general_error;
    }
}

/// Daemonize the current process
fn daemonize() !void {
    // Fork to create background process
    const pid = std.posix.fork() catch |err| {
        log.err("Failed to fork process: {}", .{err});
        return err;
    };

    if (pid > 0) std.process.exit(0);

    // Child process continues as daemon
    // Reset main thread ID for the child process
    concurrency.reset_main_thread();

    // Create new session to detach from terminal
    _ = std.posix.setsid() catch |err| {
        log.err("Failed to create new session: {}", .{err});
        return err;
    };

    // Keep original working directory to avoid filesystem permission issues
    // when creating data files and directories

    // Close standard file descriptors to detach from terminal
    std.posix.close(std.posix.STDIN_FILENO);
    std.posix.close(std.posix.STDOUT_FILENO);
    std.posix.close(std.posix.STDERR_FILENO);

    // Redirect stdin to /dev/null
    _ = std.posix.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0) catch {};

    // Redirect stdout and stderr to log file
    const log_fd = std.posix.open("/tmp/kausaldb.log", .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644) catch blk: {
        // Fallback to /dev/null if log file can't be created
        break :blk std.posix.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch return;
    };

    // Duplicate log_fd to stdout and stderr
    _ = std.posix.dup2(log_fd, std.posix.STDOUT_FILENO) catch {};
    _ = std.posix.dup2(log_fd, std.posix.STDERR_FILENO) catch {};

    // Close the original log_fd if it's not stdout or stderr
    if (log_fd > std.posix.STDERR_FILENO) {
        std.posix.close(log_fd);
    }
}

/// Write all data to a stream, handling WouldBlock errors and partial writes
fn write_all_blocking(stream: std.net.Stream, data: []const u8) !void {
    var total_written: usize = 0;

    while (total_written < data.len) {
        const bytes_written = stream.write(data[total_written..]) catch |err| switch (err) {
            error.WouldBlock => {
                // Wait a bit and retry
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };

        total_written += bytes_written;
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
            const config = try parse_server_config(cmd_args);

            // Check if server is already running
            const existing_pid = try read_pid_file(allocator, config.port);
            if (existing_pid) |pid| {
                if (is_process_running(pid)) {
                    std.debug.print("Server is already running with PID {}\n", .{pid});
                    return ExitCode.general_error;
                } else {
                    // Stale PID file, remove it
                    remove_pid_file(allocator, config.port);
                }
            }

            if (config.daemonize) {
                try daemonize();
            }

            // Write PID file after daemonization
            const current_pid = @as(std.posix.pid_t, @intCast(std.c.getpid()));
            try write_pid_file(allocator, config.port, current_pid);

            var server = try KausalServer.init(allocator, config);
            defer {
                server.deinit();
                remove_pid_file(allocator, config.port);
            }

            try server.startup();
            try server.run_event_loop();

            return ExitCode.success;
        },
        .stop => {
            const config = try parse_server_config(cmd_args);
            return try stop_server_by_port(allocator, config.port);
        },
        .status => {
            const config = try parse_server_config(cmd_args);
            return try check_server_status(allocator, config.port);
        },
        .restart => {
            const config = try parse_server_config(cmd_args);
            _ = try stop_server_by_port(allocator, config.port);

            std.Thread.sleep(500 * std.time.ns_per_ms);

            // Start the server again
            const existing_pid = try read_pid_file(allocator, config.port);
            if (existing_pid) |pid| {
                if (is_process_running(pid)) {
                    std.debug.print("Failed to stop server, restart aborted\n", .{});
                    return ExitCode.general_error;
                }
            }

            if (config.daemonize) {
                try daemonize();
            }

            const current_pid = @as(std.posix.pid_t, @intCast(std.c.getpid()));
            try write_pid_file(allocator, config.port, current_pid);

            var server = try KausalServer.init(allocator, config);
            defer {
                server.deinit();
                remove_pid_file(allocator, config.port);
            }

            try server.startup();
            try server.run_event_loop();

            return ExitCode.success;
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

fn parse_server_config(args: []const []const u8) !ServerConfig {
    var config = ServerConfig{};

    var i: usize = if (args.len > 0 and ServerCommand.from_string(args[0]) != null) 1 else 0;

    while (i < args.len) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try print_help();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --host requires a value\n", .{});
                return error.InvalidArgs;
            }
            config.host = args[i];
        } else if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --port requires a value\n", .{});
                return error.InvalidArgs;
            }
            config.port = std.fmt.parseInt(u16, args[i], 10) catch {
                std.debug.print("Error: Invalid port number: {s}\n", .{args[i]});
                return error.InvalidArgs;
            };
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --data-dir requires a value\n", .{});
                return error.InvalidArgs;
            }
            config.data_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--foreground") or std.mem.eql(u8, arg, "--no-daemonize")) {
            config.daemonize = false;
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --log-level requires a value\n", .{});
                return error.InvalidArgs;
            }
            const level_str = args[i];
            if (std.meta.stringToEnum(std.log.Level, level_str)) |level| {
                config.log_level = level;
                log_level_runtime = level;
            } else {
                std.debug.print("Error: Invalid log level: {s}\n", .{level_str});
                return error.InvalidArgs;
            }
        } else {
            std.debug.print("Error: Unknown argument: {s}\n", .{arg});
            return error.InvalidArgs;
        }

        i += 1;
    }

    return config;
}
