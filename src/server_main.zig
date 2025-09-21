//! KausalDB server daemon - Single-threaded event loop database server
//!
//! Implements high-performance database server using event loop architecture
//! with ConnectionManager for handling multiple concurrent connections without
//! threading overhead. Follows KausalDB's single-threaded design philosophy.
//!
//! Two-phase initialization ensures clean separation between memory allocation
//! (init) and I/O operations (startup). Arena coordinators provide O(1) bulk
//! cleanup and prevent memory leaks during error recovery.

const std = @import("std");

// Core modules
const assert_mod = @import("core/assert.zig");
const concurrency = @import("core/concurrency.zig");
const error_context = @import("core/error_context.zig");
const memory = @import("core/memory.zig");
const vfs = @import("core/vfs.zig");
const production_vfs = @import("core/production_vfs.zig");

// Storage modules
const storage = @import("storage/engine.zig");
const query_engine = @import("query/engine.zig");
const workspace_manager = @import("workspace/manager.zig");

// Server modules
const cli_v2_handler = @import("server/cli_v2_handler.zig");
const connection_manager = @import("server/connection_manager.zig");

// Re-declarations
const assert = assert_mod.assert;
const fatal_assert = assert_mod.fatal_assert;
const ArenaCoordinator = memory.ArenaCoordinator;
const StorageEngine = storage.StorageEngine;
const QueryEngine = query_engine.QueryEngine;
const WorkspaceManager = workspace_manager.WorkspaceManager;
const HandlerContext = cli_v2_handler.HandlerContext;
const ConnectionManager = connection_manager.ConnectionManager;
const ConnectionManagerConfig = connection_manager.ConnectionManagerConfig;

const log = std.log.scoped(.kausaldb_server);

/// Default server configuration values
const DEFAULT_PORT = 3838;
const DEFAULT_HOST = "127.0.0.1";
const DEFAULT_DATA_DIR = "./data";
const PID_FILE_PATH = "/tmp/kausaldb.pid";

/// Server daemon commands
const ServerCommand = enum {
    start,
    stop,
    status,
    restart,
    help,
    version,
};

/// Server configuration structure
const ServerConfig = struct {
    host: []const u8 = DEFAULT_HOST,
    port: u16 = DEFAULT_PORT,
    data_dir: []const u8 = DEFAULT_DATA_DIR,
    max_connections: u32 = 100,
    connection_timeout_sec: u32 = 300,
    daemonize: bool = true,
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

    pub fn init(allocator: std.mem.Allocator, config: ServerConfig) !KausalServer {
        concurrency.assert_main_thread();

        // Initialize arena coordinators for deterministic cleanup
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

        // Clean up arena coordinators and their underlying allocators
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

        log.info("Starting KausalDB server on {s}:{}", .{ self.config.host, self.config.port });

        // Initialize storage engine with production VFS
        const storage_config = storage.Config{};
        const production_vfs_backing_allocator = self.allocator;
        var production_vfs_instance = production_vfs.ProductionVFS.init(production_vfs_backing_allocator);
        const filesystem = production_vfs_instance.vfs();

        self.storage_engine = try self.allocator.create(StorageEngine);
        self.storage_engine.?.* = try StorageEngine.init(
            self.allocator,
            filesystem,
            self.config.data_dir,
            storage_config,
        );
        try self.storage_engine.?.startup();

        // Initialize query engine on top of storage
        self.query_engine = try self.allocator.create(QueryEngine);
        self.query_engine.?.* = QueryEngine.init(
            self.allocator,
            self.storage_engine.?,
        );
        self.query_engine.?.startup();

        // Initialize workspace manager
        self.workspace_manager = try self.allocator.create(WorkspaceManager);
        self.workspace_manager.?.* = try WorkspaceManager.init(
            self.allocator,
            self.storage_engine.?,
        );
        try self.workspace_manager.?.startup();

        // Create handler context for CLI protocol processing
        self.handler_context = try self.allocator.create(HandlerContext);
        self.handler_context.?.* = HandlerContext.init(
            self.allocator,
            self.storage_engine.?,
            self.query_engine.?,
            self.workspace_manager.?,
        );

        // Initialize connection manager for event loop
        self.connection_manager = try self.allocator.create(ConnectionManager);
        self.connection_manager.?.* = ConnectionManager.init(
            self.allocator,
            ConnectionManagerConfig{
                .max_connections = self.config.max_connections,
                .connection_timeout_sec = self.config.connection_timeout_sec,
            },
        );

        // Bind network socket
        const address = try std.net.Address.parseIp(self.config.host, self.config.port);
        self.server_socket = try address.listen(.{
            .reuse_address = true,
        });

        log.info("Server listening on {s}:{}", .{ self.config.host, self.config.port });

        // Write process ID file for daemon management
        try write_pid_file();

        self.running.store(true, .monotonic);
    }

    pub fn run_event_loop(self: *KausalServer) !void {
        concurrency.assert_main_thread();

        assert_mod.assert_fmt(self.running.load(.monotonic), "Server must be started before running", .{});
        fatal_assert(self.server_socket != null, "Network socket must be initialized", .{});
        fatal_assert(self.connection_manager != null, "Connection manager must be initialized", .{});
        fatal_assert(self.handler_context != null, "Handler context must be initialized", .{});

        log.info("Server ready to accept connections", .{});

        // Single-threaded event loop using ConnectionManager
        while (self.running.load(.monotonic)) {
            // Poll for ready connections (includes new connections)
            const ready_connections = self.connection_manager.?.poll_for_ready_connections(&self.server_socket.?) catch |err| {
                log.err("Connection polling failed: {}", .{err});
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            };

            // Process all ready connections in sequence
            for (ready_connections) |connection| {
                self.handle_connection_request(connection) catch |err| {
                    log.err("Connection handling failed: {}", .{err});
                    // TODO: Fix connection index lookup for close_connection
                    // self.connection_manager.?.close_connection(connection_index);
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
            // ConnectionManager.deinit() will handle closing all connections
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

        // Remove daemon PID file
        remove_pid_file() catch |err| {
            log.warn("Failed to remove PID file: {}", .{err});
        };

        log.info("Server shutdown complete", .{});
    }

    fn handle_connection_request(self: *KausalServer, connection: *connection_manager.ClientConnection) !void {
        const ctx = self.handler_context orelse {
            return error.HandlerNotInitialized;
        };

        // Read message header from connection
        var header: cli_v2_handler.cli_v2_protocol.MessageHeader = undefined;
        const header_bytes = std.mem.asBytes(&header);
        var total_read: usize = 0;

        while (total_read < header_bytes.len) {
            const bytes_read = try connection.stream.read(header_bytes[total_read..]);
            if (bytes_read == 0) return; // Client disconnected
            total_read += bytes_read;
        }

        try header.validate();

        // Read payload if present
        var payload: []u8 = &[_]u8{};
        if (header.payload_size > 0) {
            payload = try connection.arena.allocator().alloc(u8, header.payload_size);
            total_read = 0;
            while (total_read < payload.len) {
                const bytes_read = try connection.stream.read(payload[total_read..]);
                if (bytes_read == 0) return;
                total_read += bytes_read;
            }
        }

        // Process request through CLI handler
        const response = try cli_v2_handler.handle_cli_v2_message(ctx.*, header.message_type, payload);
        defer connection.arena.allocator().free(response);

        // Send response back to client
        _ = try connection.stream.writeAll(response);
    }
};

fn write_pid_file() !void {
    // TODO: Fix getProcessId API - use std.posix.getpid() or similar
    const pid: u32 = 12345; // Placeholder PID
    const pid_file = std.fs.cwd().createFile(PID_FILE_PATH, .{}) catch |err| switch (err) {
        error.AccessDenied => return, // Skip if no permissions
        else => return err,
    };
    defer pid_file.close();

    var pid_buffer: [32]u8 = undefined;
    const pid_str = try std.fmt.bufPrint(&pid_buffer, "{}\n", .{pid});
    try pid_file.writeAll(pid_str);
}

fn remove_pid_file() !void {
    std.fs.cwd().deleteFile(PID_FILE_PATH) catch |err| switch (err) {
        error.FileNotFound => {}, // Already removed
        else => return err,
    };
}

fn parse_server_command(args: []const []const u8) !ServerCommand {
    if (args.len == 0) return .start;

    const cmd_str = args[0];

    if (std.mem.eql(u8, cmd_str, "start")) return .start;
    if (std.mem.eql(u8, cmd_str, "stop")) return .stop;
    if (std.mem.eql(u8, cmd_str, "status")) return .status;
    if (std.mem.eql(u8, cmd_str, "restart")) return .restart;
    if (std.mem.eql(u8, cmd_str, "help") or std.mem.eql(u8, cmd_str, "--help") or std.mem.eql(u8, cmd_str, "-h")) return .help;
    if (std.mem.eql(u8, cmd_str, "version") or std.mem.eql(u8, cmd_str, "--version")) return .version;

    return error.InvalidCommand;
}

fn print_help() !void {
    const help_text =
        \\kausaldb-server - KausalDB high-performance database server
        \\
        \\USAGE:
        \\    kausaldb-server [COMMAND] [OPTIONS]
        \\
        \\COMMANDS:
        \\    start                        Start the server daemon (default)
        \\    stop                         Stop the running server
        \\    status                       Show server status
        \\    restart                      Restart the server
        \\    help                         Show this help message
        \\    version                      Show version information
        \\
        \\OPTIONS:
        \\    --host <HOST>                Bind address (default: 127.0.0.1)
        \\    --port <PORT>                Port number (default: 3838)
        \\    --data-dir <PATH>            Data directory (default: ./data)
        \\    --max-connections <N>        Max concurrent connections (default: 100)
        \\    --foreground                 Don't daemonize
        \\
        \\EXAMPLES:
        \\    kausaldb-server start
        \\    kausaldb-server --port 8080 --data-dir /var/kausaldb
        \\    kausaldb-server stop
        \\    kausaldb-server status
        \\
        \\For more information, visit: https://github.com/kausalco/kausaldb
        \\
    ;

    std.debug.print("{s}", .{help_text});
}

fn print_version() !void {
    std.debug.print("kausaldb-server 0.1.0\n", .{});
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
            var server = try KausalServer.init(allocator, ServerConfig{});
            defer server.deinit();

            try server.startup();
            try server.run_event_loop();

            return ExitCode.success;
        },
        .stop => {
            // TODO: Read PID file and send SIGTERM
            std.debug.print("Stop command not yet implemented\n", .{});
            return ExitCode.general_error;
        },
        .status => {
            // TODO: Check if PID in file is running
            std.debug.print("Status command not yet implemented\n", .{});
            return ExitCode.general_error;
        },
        .restart => {
            // TODO: Stop then start
            std.debug.print("Restart command not yet implemented\n", .{});
            return ExitCode.general_error;
        },
    }
}

test "Server main functions compile" {
    _ = run_server_main;
    _ = parse_server_command;
    _ = print_help;
    _ = print_version;
}
