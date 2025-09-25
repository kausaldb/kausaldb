//! TCP server for client-server communication.
//!
//! Single-threaded async I/O event loop managing multiple client connections
//! through connection state machines. Uses arena-per-connection memory management
//! and abstracted networking for deterministic testing.
//!
//! Design rationale: Single-threaded model eliminates data races and enables
//! deterministic behavior. Connection state machines handle non-blocking I/O
//! without callback complexity or hidden control flow.

const std = @import("std");

const concurrency = @import("../core/concurrency.zig");
const conn = @import("connection.zig");
const connection_manager = @import("connection_manager.zig");
const ctx_block = @import("../core/types.zig");
const assert_mod = @import("../core/assert.zig");
const error_context = @import("../core/error_context.zig");
const ownership = @import("../core/ownership.zig");
const query_engine = @import("../query/engine.zig");
const signals = @import("../core/signals.zig");
const storage = @import("../storage/engine.zig");
const workspace_manager = @import("../workspace/manager.zig");
const cli_protocol = @import("cli_protocol.zig");

const assert = assert_mod.assert;
const comptime_assert = assert_mod.comptime_assert;
const comptime_no_padding = assert_mod.comptime_no_padding;
const log = std.log.scoped(.server);

pub const ClientConnection = conn.ClientConnection;
pub const MessageType = conn.MessageType;
pub const MessageHeader = conn.MessageHeader;
pub const ConnectionState = conn.ConnectionState;
pub const ConnectionManager = connection_manager.ConnectionManager;

const StorageEngine = storage.StorageEngine;
const QueryResult = query_engine.QueryResult;
const QueryEngine = query_engine.QueryEngine;
const WorkspaceManager = workspace_manager.WorkspaceManager;
const ContextBlock = ctx_block.ContextBlock;
const BlockId = ctx_block.BlockId;

/// Server configuration
pub const ServerConfig = struct {
    /// Port to listen on
    port: u16 = 8080,
    /// Host address to bind to (IPv4 string like "127.0.0.1" or "0.0.0.0")
    host: []const u8 = "127.0.0.1",
    /// Maximum number of concurrent client connections
    max_connections: u32 = 100,
    /// Connection timeout in seconds
    connection_timeout_sec: u32 = 300,
    /// Maximum request size in bytes
    max_request_size: u32 = 64 * 1024, // 64KB
    /// Maximum response size in bytes
    max_response_size: u32 = 16 * 1024 * 1024, // 16MB
    /// Enable request/response logging
    enable_logging: bool = false,

    /// Convert to connection-level configuration
    pub fn to_connection_config(self: ServerConfig) conn.ServerConfig {
        return conn.ServerConfig{
            .max_request_size = self.max_request_size,
            .max_response_size = self.max_response_size,
            .enable_logging = self.enable_logging,
        };
    }
};

/// Server error types
pub const ServerError = error{
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

/// Main TCP server coordinator.
/// Delegates connection management to ConnectionManager and focuses on
/// request processing coordination. Follows pure coordinator pattern:
/// owns no state, orchestrates operations between managers.
pub const Server = struct {
    /// Base allocator for server infrastructure
    allocator: std.mem.Allocator,
    /// Server configuration
    config: ServerConfig,
    /// Storage engine reference for request processing
    storage_engine: *StorageEngine,
    /// Query engine reference for request processing
    query_engine: *QueryEngine,
    /// Workspace manager reference for project management
    workspace_manager: *WorkspaceManager,
    /// TCP listener socket
    listener: ?std.net.Server = null,
    /// Connection state manager
    connection_manager: ConnectionManager,
    /// Server-level statistics (aggregated from managers)
    stats: ServerStats,
    /// Server start timestamp for uptime calculations
    server_start_time: i64,

    pub const ServerStats = struct {
        connections_accepted: u64 = 0,
        connections_active: u32 = 0,
        requests_processed: u64 = 0,
        bytes_received: u64 = 0,
        bytes_sent: u64 = 0,
        errors_encountered: u64 = 0,

        /// Format server statistics in human-readable text format
        ///
        /// Prints server metrics including connection counts, traffic, and errors.
        /// Used for server monitoring and debugging.
        pub fn format_human_readable(self: ServerStats, writer: anytype) !void {
            try writer.print("Server Statistics:\n");
            try writer.print("  Connections: {} accepted, {} active\n", .{ self.connections_accepted, self.connections_active });
            try writer.print("  Requests: {} processed\n", .{self.requests_processed});
            try writer.print("  Traffic: {} bytes received, {} bytes sent\n", .{ self.bytes_received, self.bytes_sent });
            try writer.print("  Errors: {} encountered\n", .{self.errors_encountered});
        }
    };

    /// Phase 1 initialization: Memory-only setup following coordinator pattern.
    /// Initializes ConnectionManager and sets up coordination structures.
    pub fn init(
        allocator: std.mem.Allocator,
        config: ServerConfig,
        storage_engine: *StorageEngine,
        query_eng: *QueryEngine,
        workspace_mgr: *WorkspaceManager,
    ) Server {
        const conn_config = connection_manager.ConnectionManagerConfig{
            .max_connections = config.max_connections,
            .connection_timeout_sec = config.connection_timeout_sec,
            .poll_timeout_ms = 1000, // Standard poll timeout
        };

        return Server{
            .allocator = allocator,
            .config = config,
            .storage_engine = storage_engine,
            .query_engine = query_eng,
            .workspace_manager = workspace_mgr,
            .listener = null,
            .connection_manager = ConnectionManager.init(allocator, conn_config),
            .stats = ServerStats{},
            .server_start_time = 0, // Will be set in startup()
        };
    }

    /// Clean up all server resources including managers
    pub fn deinit(self: *Server) void {
        self.shutdown();

        self.connection_manager.deinit();
    }

    /// Phase 2 initialization: Start managers and bind listener socket.
    /// Delegates to ConnectionManager startup and performs network binding.
    pub fn startup(self: *Server) !void {
        // Record server start time
        self.server_start_time = std.time.timestamp();

        // Manager must be started before binding to allocate poll_fds
        try self.connection_manager.startup();

        try self.bind();
        try self.run();
    }

    /// Bind to socket and prepare for connections (non-blocking)
    pub fn bind(self: *Server) !void {
        concurrency.assert_main_thread();

        const address = try std.net.Address.parseIp4(self.config.host, self.config.port);
        self.listener = try address.listen(.{ .reuse_address = true });

        const flags = try std.posix.fcntl(self.listener.?.stream.handle, std.posix.F.GETFL, 0);
        const nonblock_flag = 1 << @bitOffsetOf(std.posix.O, "NONBLOCK");
        _ = try std.posix.fcntl(self.listener.?.stream.handle, std.posix.F.SETFL, flags | nonblock_flag);

        log.info("KausalDB server bound to {s}:{d}", .{ self.config.host, self.bound_port() });
        log.info("Server config: max_connections={d}, timeout={d}s", .{ self.config.max_connections, self.config.connection_timeout_sec });
    }

    /// Query the actual port the server is bound to (useful for ephemeral ports)
    pub fn bound_port(self: *const Server) u16 {
        if (self.listener) |listener| {
            return listener.listen_address.getPort();
        }
        return self.config.port;
    }

    /// Run the coordination loop delegating to ConnectionManager for I/O.
    /// Pure coordinator: polls for ready connections, processes requests.
    pub fn run(self: *Server) !void {
        concurrency.assert_main_thread();
        try self.run_coordination_loop();
    }

    /// Main coordination loop: delegate I/O to ConnectionManager, handle requests.
    /// Demonstrates coordinator pattern - no direct I/O, only orchestration.
    /// Checks for shutdown signals to enable graceful termination.
    fn run_coordination_loop(self: *Server) !void {
        const listener = &self.listener.?;

        while (!signals.should_shutdown()) {
            const ready_connections = self.connection_manager.poll_for_ready_connections(listener) catch |err| {
                const ctx = error_context.ServerContext{ .operation = "poll_connections" };
                error_context.log_server_error(err, ctx);
                continue; // Server must remain available despite I/O errors
            };

            for (ready_connections) |connection| {
                const keep_alive = self.connection_manager.process_connection_io(connection, self.config.to_connection_config()) catch |err| {
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

        log.info("Server coordination loop exiting due to shutdown signal", .{});
    }

    /// Update server statistics by aggregating from ConnectionManager.
    /// Server owns no connection state, delegates to manager for statistics.
    pub fn update_aggregated_statistics(self: *Server) void {
        const conn_stats = self.connection_manager.stats;

        self.stats.connections_accepted = conn_stats.connections_accepted;
        self.stats.connections_active = conn_stats.connections_active;
    }

    /// Process a complete request from a connection by delegating to CLI handler
    fn process_connection_request(self: *Server, connection: *ClientConnection) !void {
        const payload = connection.request_payload() orelse return;
        const header = connection.current_header orelse return;

        // Create CLI handler context for this request
        const handler_context = cli_protocol.HandlerContext.init(
            connection.arena.allocator(),
            self.storage_engine,
            self.query_engine,
            self.workspace_manager,
            self.server_start_time,
        );

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

        if (self.config.enable_logging) {
            log.debug("Connection {d}: processed message type {} successfully", .{ connection.connection_id, header.message_type });
        }
    }

    /// Stop the server
    pub fn shutdown(self: *Server) void {
        if (self.listener) |*listener| {
            listener.deinit();
            self.listener = null;
        }
        log.info("KausalDB server stopped", .{});
    }
};

test "message header validation" {
    const testing = std.testing;

    const valid_header = MessageHeader{
        .magic = 0x4B41554C,
        .version = 1,
        .message_type = .ping_request,
        .payload_size = 1024,
    };

    try valid_header.validate();
    try testing.expectEqual(MessageType.ping_request, valid_header.message_type);
    try testing.expectEqual(@as(u64, 1024), valid_header.payload_size);

    // Test invalid magic
    const invalid_magic = MessageHeader{
        .magic = 0x12345678,
        .version = 1,
        .message_type = .ping_request,
        .payload_size = 0,
    };
    try testing.expectError(error.InvalidMagic, invalid_magic.validate());
}

test "server initialization" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var mock_storage: StorageEngine = undefined;
    var mock_query: QueryEngine = undefined;
    var mock_workspace: WorkspaceManager = undefined;

    const config = ServerConfig{ .port = 0 }; // Use ephemeral port for testing
    var server = Server.init(allocator, config, &mock_storage, &mock_query, &mock_workspace);
    defer server.deinit();

    try testing.expectEqual(@as(u32, 0), server.stats.connections_active);
    try testing.expectEqual(@as(u64, 0), server.stats.requests_processed);
}
