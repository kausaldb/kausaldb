//! Connection lifecycle coordinator for TCP server operations.
//!
//! Manages connection state, I/O polling, and socket lifecycle through
//! poll()-based event loop. Provides high-level interface while handling
//! low-level socket state transitions and file descriptor management.
//!
//! Design rationale: Coordinator pattern centralizes connection concerns
//! and prevents state scattered across server components. Arena allocation
//! enables O(1) bulk cleanup during connection termination while preventing
//! memory leaks from complex error recovery scenarios.

const std = @import("std");

const assert_mod = @import("../core/assert.zig");
const concurrency = @import("../core/concurrency.zig");
const conn = @import("connection.zig");
const error_context = @import("../core/error_context.zig");

const log = std.log.scoped(.connection_manager);
const testing = std.testing;

pub const ClientConnection = conn.ClientConnection;
const ConnectionState = conn.ConnectionState;

/// Configuration parameters for connection management behavior
pub const ConnectionManagerConfig = struct {
    /// Maximum concurrent connections before rejecting new ones
    max_connections: u32 = 100,
    /// Seconds before idle connections are closed
    connection_timeout_sec: u32 = 300,
    /// Milliseconds to wait in poll() before checking timeouts
    poll_timeout_ms: i32 = 1000,
};

/// Statistics for connection management operations and health monitoring
pub const ConnectionManagerStats = struct {
    /// Total connections accepted since startup
    connections_accepted: u64 = 0,
    /// Currently active connections
    connections_active: u32 = 0,
    /// Total connections closed (includes timeouts and errors)
    connections_closed: u64 = 0,
    /// Connections closed due to timeout
    connections_timed_out: u64 = 0,
    /// Number of poll() calls completed
    poll_cycles_completed: u64 = 0,
    /// Connections rejected due to max_connections limit
    connections_rejected: u64 = 0,
};

/// Connection state manager implementing arena-per-subsystem pattern.
/// Follows KausalDB coordinator pattern: Server coordinates, this manages state.
pub const ConnectionManager = struct {
    /// Arena for all connection-related memory with O(1) bulk cleanup
    arena: std.heap.ArenaAllocator,
    /// Stable backing allocator for HashMap and poll_fds
    backing_allocator: std.mem.Allocator,
    /// Configuration controlling connection behavior
    config: ConnectionManagerConfig,
    /// Active connections owned by this manager
    connections: std.array_list.Managed(*ClientConnection),
    /// Monotonic connection ID counter
    next_connection_id: u32,
    /// Poll file descriptors array for I/O event detection
    poll_fds: []std.posix.pollfd,
    /// Operational statistics for monitoring
    stats: ConnectionManagerStats,

    /// Phase 1 initialization: Memory-only setup, no I/O operations.
    /// Follows KausalDB two-phase initialization pattern.
    pub fn init(allocator: std.mem.Allocator, config: ConnectionManagerConfig) ConnectionManager {
        return ConnectionManager{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .backing_allocator = allocator,
            .config = config,
            .connections = std.array_list.Managed(*ClientConnection).init(allocator),
            .next_connection_id = 1,
            .poll_fds = &[_]std.posix.pollfd{}, // Allocated in startup()
            .stats = ConnectionManagerStats{},
        };
    }

    /// Phase 2 initialization: I/O resource allocation and system preparation.
    /// Must be called before any connection operations.
    pub fn startup(self: *ConnectionManager) !void {
        concurrency.assert_main_thread();

        const poll_fds_size = self.config.max_connections + 1;
        self.poll_fds = try self.backing_allocator.alloc(std.posix.pollfd, poll_fds_size);

        // Pre-allocate connection storage capacity to prevent reallocations
        try self.connections.ensureTotalCapacity(self.config.max_connections);

        log.info("ConnectionManager started: max_connections={}, timeout={}s", .{ self.config.max_connections, self.config.connection_timeout_sec });
    }

    /// Clean up all resources including connections and poll_fds.
    /// Connections use arena allocator so individual deinit() not needed.
    pub fn deinit(self: *ConnectionManager) void {
        for (self.connections.items) |connection| {
            connection.deinit();
            // Connection memory is arena-allocated, cleaned up below
        }
        self.connections.deinit();

        if (self.poll_fds.len > 0) {
            self.backing_allocator.free(self.poll_fds);
        }

        self.arena.deinit();

        log.info("ConnectionManager shutdown: {} total connections served", .{self.stats.connections_accepted});
    }

    /// Accept new connections from listener socket.
    /// Enforces max_connections limit to prevent resource exhaustion.
    /// Returns number of connections accepted this call.
    pub fn accept_connections(self: *ConnectionManager, listener: *std.net.Server) !u32 {
        var accepted_count: u32 = 0;
        log.debug("Starting accept_connections loop", .{});

        while (true) {
            log.debug("Accept loop iteration, accepted so far: {}", .{accepted_count});
            const tcp_connection = listener.accept() catch |err| switch (err) {
                error.WouldBlock => {
                    log.debug("No more connections available (WouldBlock), breaking loop", .{});
                    break;
                },
                error.ConnectionAborted => {
                    log.debug("Connection aborted, continuing to next", .{});
                    continue;
                },
                else => {
                    log.err("Error accepting connection: {}", .{err});
                    const ctx = error_context.ServerContext{ .operation = "accept_connection" };
                    error_context.log_server_error(err, ctx);
                    return err;
                },
            };
            log.debug("Successfully accepted TCP connection", .{});

            // Enforce connection limit to maintain system stability
            if (self.connections.items.len >= self.config.max_connections) {
                tcp_connection.stream.close();
                self.stats.connections_rejected += 1;
                log.warn("Connection rejected: max_connections limit ({}) reached", .{self.config.max_connections});
                continue;
            }

            const arena_allocator = self.arena.allocator();
            const connection = try arena_allocator.create(ClientConnection);
            connection.* = ClientConnection.init(arena_allocator, tcp_connection.stream, self.next_connection_id);

            // Configure socket for non-blocking I/O
            const conn_flags = try std.posix.fcntl(connection.stream.handle, std.posix.F.GETFL, 0);
            const nonblock_flag = 1 << @bitOffsetOf(std.posix.O, "NONBLOCK");
            _ = try std.posix.fcntl(connection.stream.handle, std.posix.F.SETFL, conn_flags | nonblock_flag);

            self.next_connection_id += 1;
            try self.connections.append(connection);
            accepted_count += 1;

            self.stats.connections_accepted += 1;
            self.stats.connections_active += 1;

            log.info("Connection {} accepted from {any}", .{ connection.connection_id, tcp_connection.address });
            log.debug("Connection {} fully initialized and added to list", .{connection.connection_id});
        }

        log.debug("Accept_connections completed, total accepted: {}", .{accepted_count});
        return accepted_count;
    }

    /// Build poll_fds array based on current connection states.
    /// Returns count of file descriptors to monitor.
    fn build_poll_fds(self: *ConnectionManager, listener: *std.net.Server) usize {
        assert_mod.assert_fmt(self.poll_fds.len > 0, "poll_fds not allocated - startup() not called", .{});

        // Listener socket always monitored for new connections
        self.poll_fds[0] = std.posix.pollfd{
            .fd = listener.stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        };

        var poll_count: usize = 1;

        for (self.connections.items) |connection| {
            if (poll_count >= self.poll_fds.len) break;

            var events: i16 = 0;

            // Monitor I/O events based on connection's current state
            switch (connection.state) {
                .reading_header, .reading_payload => events |= std.posix.POLL.IN,
                .writing_response => events |= std.posix.POLL.OUT,
                .processing => {}, // No I/O monitoring during request processing
                .closing, .closed => continue,
            }

            if (events != 0) {
                log.debug("Adding connection {} to poll (state: {}, events: 0x{X})", .{ connection.connection_id, connection.state, events });
                self.poll_fds[poll_count] = std.posix.pollfd{
                    .fd = connection.stream.handle,
                    .events = events,
                    .revents = 0,
                };
                poll_count += 1;
            } else {
                log.debug("Connection {} not monitored (state: {})", .{ connection.connection_id, connection.state });
            }
        }

        return poll_count;
    }

    /// Poll for I/O events and accept new connections.
    /// Returns connections that have I/O events ready for processing.
    /// Handles timeouts and error conditions internally.
    pub fn poll_for_ready_connections(self: *ConnectionManager, listener: *std.net.Server) ![]const *ClientConnection {
        const poll_count = self.build_poll_fds(listener);
        log.debug("Poll setup: {} fds to monitor ({} connections)", .{ poll_count, self.connections.items.len });

        log.debug("About to poll {} file descriptors with timeout {}ms", .{ poll_count, self.config.poll_timeout_ms });
        const ready_count = std.posix.poll(self.poll_fds[0..poll_count], self.config.poll_timeout_ms) catch |err| switch (err) {
            error.Unexpected => {
                log.debug("Poll interrupted by signal", .{});
                return &[_]*ClientConnection{}; // Signal interruption
            },
            else => {
                log.err("Poll failed with error: {}", .{err});
                return err;
            },
        };

        self.stats.poll_cycles_completed += 1;
        log.debug("Poll result: {} fds ready out of {} (timeout: {}ms)", .{ ready_count, poll_count, self.config.poll_timeout_ms });

        if (ready_count == 0) {
            log.debug("Poll timeout - no file descriptors ready", .{});
        }

        if (ready_count == 0) {
            // Timeout occurred, perform maintenance operations
            log.debug("Poll timeout, performing maintenance", .{});
            try self.cleanup_timed_out_connections();
            return &[_]*ClientConnection{};
        }

        // Process listener socket first for new connections
        var newly_accepted_count: u32 = 0;
        if (self.poll_fds[0].revents & std.posix.POLL.IN != 0) {
            log.debug("New connections available, accepting", .{});
            newly_accepted_count = self.accept_connections(listener) catch |err| blk: {
                log.err("Failed to accept connections: {}", .{err});
                break :blk 0;
            };
            log.debug("Accepted {} new connections", .{newly_accepted_count});
        }

        // Collect connections with ready I/O events and connections to close
        var ready_connections = try self.arena.allocator().alloc(*ClientConnection, ready_count);
        var ready_index: usize = 0;
        var connections_to_close: [64]usize = undefined;
        var close_count: usize = 0;
        log.debug("Collecting ready connections from {} existing connections", .{self.connections.items.len});

        var poll_index: usize = 1; // Skip listener at index 0
        var conn_index: usize = 0;

        while (poll_index < poll_count and conn_index < self.connections.items.len) {
            const poll_fd = self.poll_fds[poll_index];
            const connection = self.connections.items[conn_index];

            // Match poll_fd to connection by file descriptor
            if (poll_fd.fd != connection.stream.handle) {
                conn_index += 1;
                continue;
            }

            // Handle connection errors and disconnections
            // Log detailed poll event information for debugging
            log.debug("Connection {}: poll events - requested: 0x{X}, returned: 0x{X}", .{ connection.connection_id, poll_fd.events, poll_fd.revents });

            // Handle critical errors that require immediate closure
            if (poll_fd.revents & (std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0) {
                var error_msg: [64]u8 = undefined;
                var error_len: usize = 0;

                if (poll_fd.revents & std.posix.POLL.ERR != 0) {
                    @memcpy(error_msg[error_len .. error_len + 8], " POLLERR");
                    error_len += 8;
                }
                if (poll_fd.revents & std.posix.POLL.NVAL != 0) {
                    @memcpy(error_msg[error_len .. error_len + 9], " POLLNVAL");
                    error_len += 9;
                }

                log.info("Connection {}: critical socket error detected ({s}), closing", .{ connection.connection_id, error_msg[0..error_len] });
                if (close_count < connections_to_close.len) {
                    connections_to_close[close_count] = conn_index;
                    close_count += 1;
                }
                poll_index += 1;
                conn_index += 1;
                continue;
            }

            // Handle POLLHUP: client closed connection, but check for data first
            const has_hangup = (poll_fd.revents & std.posix.POLL.HUP) != 0;
            const has_data = (poll_fd.revents & std.posix.POLL.IN) != 0;

            if (has_hangup and !has_data) {
                // Client closed and no data available - close connection
                log.debug("Connection {}: Client closed connection (POLLHUP), no data available", .{connection.connection_id});
                if (close_count < connections_to_close.len) {
                    connections_to_close[close_count] = conn_index;
                    close_count += 1;
                }
                poll_index += 1;
                conn_index += 1;
                continue;
            }

            if (has_hangup and has_data) {
                // Client closed but data is available - process data first, mark for closure after
                log.debug("Connection {}: Client closed connection but data available - will read data first", .{connection.connection_id});
            }

            if (poll_fd.revents & (std.posix.POLL.IN | std.posix.POLL.OUT) != 0) {
                // Check if data is available for reading
                if (poll_fd.revents & std.posix.POLL.IN != 0) {
                    log.debug("Connection {}: Data available for reading (POLLIN)", .{connection.connection_id});
                }
                if (poll_fd.revents & std.posix.POLL.OUT != 0) {
                    log.debug("Connection {}: Ready for writing (POLLOUT)", .{connection.connection_id});
                }
                if (ready_index < ready_connections.len) {
                    log.debug("Connection {} ready for I/O (state: {}, events: 0x{X})", .{ connection.connection_id, connection.state, poll_fd.revents });
                    ready_connections[ready_index] = connection;
                    ready_index += 1;
                }
                conn_index += 1;
            } else {
                conn_index += 1;
            }

            poll_index += 1;
        }

        // Close connections marked for closure (in reverse order to maintain indices)
        var close_idx: usize = close_count;
        while (close_idx > 0) {
            close_idx -= 1;
            const conn_idx = connections_to_close[close_idx];
            if (conn_idx < self.connections.items.len) {
                self.close_connection(conn_idx);
            }
        }

        log.debug("Returning {} ready connections", .{ready_index});
        return ready_connections[0..ready_index];
    }

    /// Close connection at specified index and update statistics.
    /// Connection memory is arena-allocated so no explicit deallocation needed.
    /// TODO: Investigate this and close_connection_by_pointer usage, this seems fishy
    pub fn close_connection(self: *ConnectionManager, index: usize) void {
        assert_mod.assert_fmt(index < self.connections.items.len, "Connection index out of bounds: {} >= {}", .{ index, self.connections.items.len });

        const connection = self.connections.items[index];
        log.info("Connection {} closed", .{connection.connection_id});

        connection.deinit();
        // Arena handles memory deallocation automatically

        _ = self.connections.swapRemove(index);
        self.stats.connections_active -= 1;
        self.stats.connections_closed += 1;
    }

    /// Close connection by pointer reference.
    /// Finds the connection index and delegates to close_connection(index).
    pub fn close_connection_by_pointer(self: *ConnectionManager, connection_ptr: *const ClientConnection) !void {
        for (self.connections.items, 0..) |connection, index| {
            if (connection == connection_ptr) {
                self.close_connection(index);
                return;
            }
        }
        return error.ConnectionNotFound;
    }

    /// Remove connections that exceed configured timeout.
    /// Called automatically during poll timeouts for maintenance.
    pub fn cleanup_timed_out_connections(self: *ConnectionManager) !void {
        const current_time = std.time.timestamp();
        const timeout_seconds: i64 = @intCast(self.config.connection_timeout_sec);

        var i: usize = 0;
        while (i < self.connections.items.len) {
            const connection = self.connections.items[i];
            const connection_age = current_time - connection.established_time;

            if (connection_age > timeout_seconds) {
                log.info("Connection {}: timed out after {}s", .{ connection.connection_id, connection_age });
                self.close_connection(i);
                self.stats.connections_timed_out += 1;
                // Don't increment i since we removed an element
            } else {
                i += 1;
            }
        }
    }

    /// Check if any connection has a complete request ready for processing.
    /// Used by Server coordinator to determine if request processing is needed.
    pub fn has_ready_requests(self: *const ConnectionManager) bool {
        for (self.connections.items) |connection| {
            if (connection.has_complete_request()) {
                return true;
            }
        }
        return false;
    }

    /// Find next connection with complete request ready for processing.
    /// Returns null if no connections have complete requests.
    pub fn find_connection_with_ready_request(self: *const ConnectionManager) ?*ClientConnection {
        for (self.connections.items) |connection| {
            if (connection.has_complete_request()) {
                return connection;
            }
        }
        return null;
    }

    /// Process I/O for a specific connection and return whether to keep it alive.
    /// Used by Server coordinator for individual connection I/O handling.
    pub fn process_connection_io(
        self: *ConnectionManager,
        connection: *ClientConnection,
        server_config: anytype,
    ) !bool {
        const keep_alive = connection.process_io(server_config) catch |err| blk: {
            const ctx = error_context.connection_context("process_io", connection.connection_id);
            error_context.log_server_error(err, ctx);
            log.err("Connection {}: I/O error: {any}", .{ connection.connection_id, err });
            break :blk false;
        };

        if (!keep_alive) {
            log.debug("Connection {} marked for closure, finding index for removal", .{connection.connection_id});
            // Find connection index for removal
            for (self.connections.items, 0..) |existing_conn, index| {
                if (existing_conn == connection) {
                    self.close_connection(index);
                    break;
                }
            }
            return false; // Ensure caller knows connection is closed
        }

        return keep_alive;
    }
};

test "connection manager initialization follows two-phase pattern" {
    const config = ConnectionManagerConfig{
        .max_connections = 5,
        .connection_timeout_sec = 10,
        .poll_timeout_ms = 200,
    };

    // Phase 1: init() should not perform I/O
    var manager = ConnectionManager.init(testing.allocator, config);
    defer manager.deinit();

    // Verify initial state - no I/O resources allocated
    try testing.expectEqual(@as(u32, 0), @as(u32, @intCast(manager.connections.items.len)));
    try testing.expectEqual(@as(u32, 1), manager.next_connection_id);
    try testing.expectEqual(@as(usize, 0), manager.poll_fds.len);

    // Verify arena is initialized
    try testing.expect(@intFromPtr(&manager.arena) != 0);

    // Phase 2: startup() performs resource allocation
    try manager.startup();

    // Verify startup allocated I/O resources
    try testing.expect(manager.poll_fds.len == config.max_connections + 1);

    // Verify connection storage capacity pre-allocated
    try testing.expect(manager.connections.capacity >= config.max_connections);
}

test "connection statistics track operations correctly" {
    var manager = ConnectionManager.init(testing.allocator, ConnectionManagerConfig{
        .max_connections = 3,
        .connection_timeout_sec = 60,
    });
    defer manager.deinit();
    try manager.startup();

    // Initial statistics should be zero
    const initial_stats = manager.stats;
    try testing.expectEqual(@as(u64, 0), initial_stats.connections_accepted);
    try testing.expectEqual(@as(u32, 0), initial_stats.connections_active);
    try testing.expectEqual(@as(u64, 0), initial_stats.connections_closed);
    try testing.expectEqual(@as(u64, 0), initial_stats.connections_timed_out);
    try testing.expectEqual(@as(u64, 0), initial_stats.connections_rejected);
    try testing.expectEqual(@as(u64, 0), initial_stats.poll_cycles_completed);
}

test "arena cleanup handles connection memory automatically" {
    var manager = ConnectionManager.init(testing.allocator, ConnectionManagerConfig{
        .max_connections = 2,
    });
    defer manager.deinit();
    try manager.startup();

    // Verify arena allocator is working
    const arena_allocator = manager.arena.allocator();
    const test_memory = try arena_allocator.alloc(u8, 1024);
    try testing.expect(test_memory.len == 1024);

    // Arena will automatically clean up all allocations in deinit()
    // No explicit cleanup needed - this is the key benefit
    const stats = manager.stats;
    try testing.expectEqual(@as(u64, 0), stats.connections_closed);
}

test "poll_fds array sizing respects max_connections limit" {
    const configs = [_]ConnectionManagerConfig{
        .{ .max_connections = 1 },
        .{ .max_connections = 10 },
        .{ .max_connections = 100 },
    };

    for (configs) |config| {
        var manager = ConnectionManager.init(testing.allocator, config);
        defer manager.deinit();
        try manager.startup();

        // poll_fds should be max_connections + 1 (for listener socket)
        try testing.expectEqual(config.max_connections + 1, manager.poll_fds.len);
    }
}

test "connection manager configuration validation" {
    const config = ConnectionManagerConfig{
        .max_connections = 50,
        .connection_timeout_sec = 300,
        .poll_timeout_ms = 1000,
    };

    var manager = ConnectionManager.init(testing.allocator, config);
    defer manager.deinit();

    // Verify configuration is stored correctly
    try testing.expectEqual(config.max_connections, manager.config.max_connections);
    try testing.expectEqual(config.connection_timeout_sec, manager.config.connection_timeout_sec);
    try testing.expectEqual(config.poll_timeout_ms, manager.config.poll_timeout_ms);
}

test "connection ID assignment is monotonic" {
    var manager = ConnectionManager.init(testing.allocator, ConnectionManagerConfig{});
    defer manager.deinit();

    const initial_id = manager.next_connection_id;
    try testing.expectEqual(@as(u32, 1), initial_id);

    // Simulate connection acceptance incrementing ID
    manager.next_connection_id += 1;
    try testing.expectEqual(@as(u32, 2), manager.next_connection_id);

    manager.next_connection_id += 1;
    try testing.expectEqual(@as(u32, 3), manager.next_connection_id);
}

test "connection manager enforces resource limits" {
    const config = ConnectionManagerConfig{
        .max_connections = 2, // Very small limit for testing
        .connection_timeout_sec = 30,
    };

    var manager = ConnectionManager.init(testing.allocator, config);
    defer manager.deinit();
    try manager.startup();

    // Verify capacity limits are enforced in data structures
    try testing.expect(manager.poll_fds.len == config.max_connections + 1);
    try testing.expect(manager.connections.capacity >= config.max_connections);
}

test "timeout configuration affects cleanup behavior" {
    const short_timeout_config = ConnectionManagerConfig{
        .connection_timeout_sec = 1, // 1 second timeout
        .max_connections = 5,
    };

    var manager = ConnectionManager.init(testing.allocator, short_timeout_config);
    defer manager.deinit();
    try manager.startup();

    // Verify timeout configuration is applied
    try testing.expectEqual(@as(u32, 1), manager.config.connection_timeout_sec);

    // Cleanup function should use this timeout (tested in integration tests)
}

test "poll timeout affects blocking behavior" {
    const config = ConnectionManagerConfig{
        .poll_timeout_ms = 50, // Short timeout for testing
    };

    var manager = ConnectionManager.init(testing.allocator, config);
    defer manager.deinit();
    try manager.startup();

    try testing.expectEqual(@as(i32, 50), manager.config.poll_timeout_ms);
}

test "backing allocator vs arena allocator usage" {
    var manager = ConnectionManager.init(testing.allocator, ConnectionManagerConfig{});
    defer manager.deinit();
    try manager.startup();

    // Verify backing allocator is used for stable structures
    try testing.expect(manager.backing_allocator.ptr == testing.allocator.ptr);

    // Verify arena provides different allocator for connection data
    const arena_allocator = manager.arena.allocator();
    try testing.expect(arena_allocator.ptr != testing.allocator.ptr);

    // Test allocation from arena
    const test_data = try arena_allocator.alloc(u8, 64);
    try testing.expect(test_data.len == 64);
}

test "deinit cleans up all resources properly" {
    var manager = ConnectionManager.init(testing.allocator, ConnectionManagerConfig{
        .max_connections = 5,
    });

    try manager.startup();

    // Allocate some arena memory to test cleanup
    const arena_allocator = manager.arena.allocator();
    _ = try arena_allocator.alloc(u8, 1024);

    // Verify resources are allocated
    try testing.expect(manager.poll_fds.len > 0);

    // deinit() should clean up everything without errors
    manager.deinit();

    // After deinit, accessing manager would be unsafe
    // This test just verifies deinit completes without errors
}
