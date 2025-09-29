//! Network server for KausalDB client-server communication.
//!
//! Single-threaded async I/O event loop managing multiple client connections
//! through connection state machines. Focused purely on network concerns while
//! delegating database operations to ServerCoordinator.
//!
//! Design rationale: Clear separation between network I/O and database logic
//! enables better testability and follows KausalDB coordinator pattern.

const std = @import("std");
const builtin = @import("builtin");

const concurrency = @import("../core/concurrency.zig");
const connection_mod = @import("connection.zig");
const connection_manager = @import("connection_manager.zig");
const error_context = @import("../core/error_context.zig");
const signals = @import("../core/signals.zig");
const cli_protocol = @import("cli_protocol.zig");
const config_mod = @import("config.zig");
const coordinator_mod = @import("coordinator.zig");

const log = std.log.scoped(.network_server);

pub const ClientConnection = connection_mod.ClientConnection;
pub const MessageType = connection_mod.MessageType;
pub const MessageHeader = connection_mod.MessageHeader;
pub const ConnectionState = connection_mod.ConnectionState;
pub const ConnectionManager = connection_manager.ConnectionManager;
pub const ServerConfig = config_mod.ServerConfig;
pub const ServerCoordinator = coordinator_mod.ServerCoordinator;
pub const HandlerContext = cli_protocol.HandlerContext;

/// Network server statistics for monitoring I/O operations
pub const NetworkStats = struct {
    connections_accepted: u64 = 0,
    connections_active: u32 = 0,
    requests_processed: u64 = 0,
    bytes_received: u64 = 0,
    bytes_sent: u64 = 0,
    errors_encountered: u64 = 0,

    /// Format network statistics in human-readable text format
    pub fn format_human_readable(self: NetworkStats, writer: anytype) !void {
        try writer.print("Network Statistics:\n", .{});
        try writer.print("  Connections: {} accepted, {} active\n", .{ self.connections_accepted, self.connections_active });
        try writer.print("  Requests: {} processed\n", .{self.requests_processed});
        try writer.print("  Traffic: {} bytes received, {} bytes sent\n", .{ self.bytes_received, self.bytes_sent });
        try writer.print("  Errors: {} encountered\n", .{self.errors_encountered});
    }
};

/// Network server error types
pub const NetworkServerError = error{
    /// Address already in use
    AddressInUse,
    /// Too many connections
    TooManyConnections,
    /// Connection timeout
    ConnectionTimeout,
    /// Invalid request format
    InvalidRequest,
    /// Request too large
    RequestTooLarge,
    /// Response too large
    ResponseTooLarge,
    /// Client disconnected unexpectedly
    ClientDisconnected,
    /// End of stream
    EndOfStream,
} || std.mem.Allocator.Error || std.net.Stream.ReadError || std.net.Stream.WriteError;

/// Global server reference for signal handling
var global_network_server: ?*NetworkServer = null;

/// Signal handler for graceful shutdown
fn signal_handler(sig: c_int) callconv(.c) void {
    _ = sig;
    if (global_network_server) |server| {
        server.running.store(false, .monotonic);
        log.info("Received shutdown signal, initiating graceful shutdown...", .{});
    }
}

/// Pure network server implementing KausalDB coordinator pattern.
/// Handles TCP connections and I/O while delegating database operations
/// to ServerCoordinator. Follows single responsibility principle.
pub const NetworkServer = struct {
    /// Base allocator for server infrastructure
    allocator: std.mem.Allocator,
    /// Server configuration
    config: ServerConfig,
    /// Database coordinator (dependency injection)
    coordinator: *ServerCoordinator,
    /// Server start timestamp for uptime calculations
    server_start_time: i64,
    /// Network-level statistics
    stats: NetworkStats,
    /// Server running state for graceful shutdown
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Last statistics update timestamp for rate limiting
    last_stats_update: i64 = 0,

    // Network components
    listener: ?std.net.Server = null,
    connection_manager: ConnectionManager,
    handler_context: ?*HandlerContext = null,

    /// Initialize network server with database coordinator dependency.
    /// Phase 1 initialization: Memory allocation only, no I/O operations.
    pub fn init(
        allocator: std.mem.Allocator,
        server_config: ServerConfig,
        database_coordinator: *ServerCoordinator,
    ) NetworkServer {
        const conn_mgr_config = server_config.to_connection_manager_config();

        return NetworkServer{
            .allocator = allocator,
            .config = server_config,
            .coordinator = database_coordinator,
            .server_start_time = 0, // Will be set in startup()
            .listener = null,
            .connection_manager = ConnectionManager.init(allocator, conn_mgr_config),
            .handler_context = null,
            .stats = NetworkStats{},
        };
    }

    /// Phase 2 initialization: Bind socket, start managers, install signals, run server.
    /// Must be called after ServerCoordinator.startup().
    pub fn startup(self: *NetworkServer) !void {
        concurrency.assert_main_thread();

        // Record server start time
        self.server_start_time = std.time.timestamp();

        // Install signal handler for graceful shutdown
        try self.install_signal_handler();

        log.info("Starting network server on {s}:{}", .{ self.config.host, self.config.port });

        // Create CLI protocol handler context
        self.handler_context = try self.allocator.create(cli_protocol.HandlerContext);
        self.handler_context.?.* = cli_protocol.HandlerContext.init(
            self.allocator,
            self.coordinator.storage_engine_ref(),
            self.coordinator.query_engine_ref(),
            self.coordinator.workspace_manager_ref(),
            self.server_start_time,
        );

        // Manager must be started before binding to allocate poll_fds
        try self.connection_manager.startup();

        try self.bind();

        // Set running flag before starting coordination loop
        self.running.store(true, .monotonic);

        try self.run();
    }

    /// Install signal handler for graceful shutdown
    fn install_signal_handler(self: *NetworkServer) !void {
        switch (builtin.os.tag) {
            .windows => {
                return;
            },
            else => {
                // Store server instance globally for signal handler access
                global_network_server = self;

                var act = std.mem.zeroes(std.posix.Sigaction);
                act.handler = .{ .handler = signal_handler };
                act.flags = std.posix.SA.RESTART;

                _ = std.posix.sigaction(std.posix.SIG.TERM, &act, null);
                _ = std.posix.sigaction(std.posix.SIG.INT, &act, null);
            },
        }
    }

    /// Bind to socket and prepare for connections (non-blocking)
    fn bind(self: *NetworkServer) !void {
        concurrency.assert_main_thread();

        const address = try std.net.Address.parseIp4(self.config.host, self.config.port);
        self.listener = try address.listen(.{ .reuse_address = true });

        const flags = try std.posix.fcntl(self.listener.?.stream.handle, std.posix.F.GETFL, 0);
        const nonblock_flag = 1 << @bitOffsetOf(std.posix.O, "NONBLOCK");
        _ = try std.posix.fcntl(self.listener.?.stream.handle, std.posix.F.SETFL, flags | nonblock_flag);

        log.info("Network server bound to {s}:{d}", .{ self.config.host, self.bound_port() });
        log.info("Network config: max_connections={d}, timeout={d}s", .{
            self.config.max_connections,
            self.config.connection_timeout_sec,
        });
    }

    /// Query the actual port the server is bound to (useful for ephemeral ports)
    pub fn bound_port(self: *const NetworkServer) u16 {
        if (self.listener) |listener| {
            return listener.listen_address.getPort();
        }
        return self.config.port;
    }

    /// Main coordination loop: delegate I/O to ConnectionManager, handle requests.
    /// Checks for shutdown signals to enable graceful termination.
    /// Pure coordinator: polls for ready connections, processes requests.
    fn run(self: *NetworkServer) !void {
        concurrency.assert_main_thread();

        const listener = &self.listener.?;

        while (self.running.load(.monotonic)) {
            const ready_connections = self.connection_manager.poll_for_ready_connections(listener) catch |err| {
                const ctx = error_context.ServerContext{ .operation = "poll_connections" };
                error_context.log_server_error(err, ctx);
                continue; // Server must remain available despite I/O errors
            };

            for (ready_connections) |connection| {
                const keep_alive = self.connection_manager.process_connection_io(
                    connection,
                    self.config.to_connection_config(),
                ) catch |err| {
                    const ctx = error_context.connection_context("process_io", connection.connection_id);
                    error_context.log_server_error(err, ctx);
                    continue; // Individual connection errors don't stop server
                };
                _ = keep_alive;
            }

            while (self.connection_manager.find_connection_with_ready_request()) |connection| {
                try self.process_connection_request(connection);
            }

            self.update_aggregated_statistics();
        }

        log.info("Network server coordination loop exiting due to shutdown signal", .{});
    }

    /// Update server statistics by aggregating from ConnectionManager.
    /// Only update periodically to avoid unnecessary computation
    fn update_aggregated_statistics(self: *NetworkServer) void {
        // Rate limit statistics updates to reduce CPU overhead
        const current_time = std.time.timestamp();

        if (current_time - self.last_stats_update < self.config.stats_update_interval_sec) {
            return; // Update based on configured interval
        }

        self.last_stats_update = current_time;
        const conn_stats = self.connection_manager.stats;
        self.stats.connections_accepted = conn_stats.connections_accepted;
        self.stats.connections_active = conn_stats.connections_active;
    }

    /// Process a complete request from a connection by delegating to CLI handler
    fn process_connection_request(self: *NetworkServer, connection: *ClientConnection) !void {
        const payload = connection.request_payload() orelse return;
        const header = connection.current_header orelse return;

        // Use the pre-created handler context
        const handler_context = self.handler_context.?.*;

        // Delegate message processing to CLI handler
        const response_data = cli_protocol.handle_cli_message(
            handler_context,
            header.message_type,
            payload,
        ) catch |err| {
            const ctx = error_context.connection_context("cli_message_processing", connection.connection_id);
            error_context.log_server_error(err, ctx);

            const error_msg = "Internal server error processing request";
            connection.send_response(error_msg);
            self.stats.errors_encountered += 1;
            return;
        };

        // Send response back to client
        connection.send_response(response_data);
        self.stats.bytes_sent += response_data.len;
        self.stats.requests_processed += 1;
        self.stats.bytes_received += payload.len + @sizeOf(MessageHeader);

        // Only log request processing in development mode with rate limiting
        if (self.config.enable_logging and self.stats.requests_processed % 1000 == 0) {
            log.info("Processed {} requests, connection {}", .{ self.stats.requests_processed, connection.connection_id });
        }
    }

    /// Stop the network server
    pub fn shutdown(self: *NetworkServer) void {
        if (self.listener) |*listener| {
            listener.deinit();
            self.listener = null;
        }
        log.info("Network server stopped", .{});
    }

    /// Clean up all network server resources
    pub fn deinit(self: *NetworkServer) void {
        self.shutdown();

        if (self.handler_context) |ctx| {
            self.allocator.destroy(ctx);
        }

        self.connection_manager.deinit();
    }
};

const testing = std.testing;

test "NetworkServer initialization without I/O" {
    const test_config = ServerConfig{
        .port = 0, // Use ephemeral port for testing
        .data_dir = "test_network_data",
    };

    // Create a mock coordinator (normally would be real)
    var coordinator = ServerCoordinator.init(testing.allocator, test_config);
    defer coordinator.deinit();

    // Phase 1: init() should not perform I/O
    var server = NetworkServer.init(testing.allocator, test_config, &coordinator);
    defer server.deinit();

    // Verify initial state
    try testing.expectEqual(@as(u32, 0), server.stats.connections_active);
    try testing.expectEqual(@as(u64, 0), server.stats.requests_processed);
    try testing.expect(server.listener == null);
    try testing.expect(server.handler_context == null);
}

test "NetworkStats format produces readable output" {
    const stats = NetworkStats{
        .connections_accepted = 100,
        .connections_active = 10,
        .requests_processed = 500,
        .bytes_received = 1024 * 1024,
        .bytes_sent = 2 * 1024 * 1024,
        .errors_encountered = 5,
    };

    var buffer: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try stats.format_human_readable(fbs.writer());

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "100") != null);
    try testing.expect(std.mem.indexOf(u8, output, "500") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Connections:") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Requests:") != null);
}

test "NetworkServer configuration is stored correctly" {
    const test_config = ServerConfig{
        .host = "192.168.1.1",
        .port = 8080,
        .max_connections = 50,
    };

    var coordinator = ServerCoordinator.init(testing.allocator, test_config);
    defer coordinator.deinit();

    var server = NetworkServer.init(testing.allocator, test_config, &coordinator);
    defer server.deinit();

    try testing.expectEqualStrings("192.168.1.1", server.config.host);
    try testing.expectEqual(@as(u16, 8080), server.config.port);
    try testing.expectEqual(@as(u32, 50), server.config.max_connections);
}
