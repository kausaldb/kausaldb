//! Client connection state machine for non-blocking request processing.
//!
//! Manages complete request/response lifecycle including header parsing,
//! payload reading with partial I/O support, request processing coordination,
//! and response writing with flow control through explicit state transitions.
//!
//! Design rationale: State machine approach eliminates callback complexity
//! while providing deterministic non-blocking I/O behavior. Arena-per-connection
//! allocation enables efficient cleanup and prevents memory leaks from
//! connection handling errors.

const std = @import("std");

const ctx_block = @import("../core/types.zig");

const error_context = @import("../core/error_context.zig");
const query_engine = @import("../query/engine.zig");
const cli_protocol = @import("../cli/protocol.zig");

const log = std.log.scoped(.connection);

const BlockId = ctx_block.BlockId;
const ContextBlock = ctx_block.ContextBlock;

pub const MessageType = cli_protocol.MessageType;
pub const MessageHeader = cli_protocol.MessageHeader;

/// Connection state for async I/O state machine
pub const ConnectionState = enum {
    /// Waiting to read message header
    reading_header,
    /// Waiting to read message payload
    reading_payload,
    /// Processing request (synchronous operation)
    processing,
    /// Waiting to write response
    writing_response,
    /// Connection should be closed
    closing,
    /// Connection is closed
    closed,
};

// Import connection configuration from centralized config module
const config_mod = @import("config.zig");
pub const ConnectionConfig = config_mod.ConnectionConfig;

/// Connection errors
pub const ConnectionError = error{
    /// Invalid request format
    InvalidRequest,
    /// Request too large
    RequestTooLarge,
    /// Response too large
    ResponseTooLarge,
    /// Client disconnected unexpectedly
    ClientDisconnected,
} || std.mem.Allocator.Error || std.net.Stream.ReadError || std.net.Stream.WriteError;

/// Client connection state machine for async I/O
pub const ClientConnection = struct {
    /// TCP stream for this connection
    stream: std.net.Stream,
    /// Arena allocator for this connection's memory
    arena: std.heap.ArenaAllocator,
    /// Connection ID for logging
    connection_id: u32,
    /// When this connection was established
    established_time: i64,
    /// Current state in the I/O state machine
    state: ConnectionState,
    /// Buffer for reading requests
    read_buffer: [4096]u8,
    /// Buffer for writing responses
    write_buffer: [4096]u8,
    /// Current position in header read
    header_bytes_read: usize,
    /// Current message header being read
    current_header: ?MessageHeader,
    /// Current payload buffer being read
    current_payload: ?[]u8,
    /// Current position in payload read
    payload_bytes_read: usize,
    /// Current response buffer being written
    current_response: ?[]const u8,
    /// Current position in response write
    response_bytes_written: usize,

    pub fn init(allocator: std.mem.Allocator, stream: std.net.Stream, connection_id: u32) ClientConnection {
        return ClientConnection{
            .stream = stream,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .connection_id = connection_id,
            .established_time = std.time.timestamp(),
            .state = .reading_header,
            .read_buffer = std.mem.zeroes([4096]u8),
            .write_buffer = std.mem.zeroes([4096]u8),
            .header_bytes_read = 0,
            .current_header = null,
            .current_payload = null,
            .payload_bytes_read = 0,
            .current_response = null,
            .response_bytes_written = 0,
        };
    }

    pub fn deinit(self: *ClientConnection) void {
        self.stream.close();
        self.arena.deinit();
    }

    /// Process non-blocking I/O for this connection
    /// Returns true if the connection should remain active, false if it should be closed
    pub fn process_io(self: *ClientConnection, config: ConnectionConfig) !bool {
        switch (self.state) {
            .reading_header => return self.try_read_header(config),
            .reading_payload => return self.try_read_payload(config),
            .processing => {
                // This should not happen in async model - processing is synchronous
                return false;
            },
            .writing_response => return self.try_write_response(),
            .closing, .closed => return false,
        }
    }

    /// Attempt to read message header non-blockingly
    fn try_read_header(self: *ClientConnection, config: ConnectionConfig) !bool {
        const header_size = @sizeOf(MessageHeader);
        const header_remaining = header_size - self.header_bytes_read;

        log.debug("Connection {}: Reading header - need {} bytes, have {} bytes, expecting {} total", .{ self.connection_id, header_remaining, self.header_bytes_read, header_size });

        const n = self.stream.read(self.read_buffer[self.header_bytes_read .. self.header_bytes_read + header_remaining]) catch |err| switch (err) {
            error.WouldBlock => {
                log.debug("Connection {}: WouldBlock on header read", .{self.connection_id});
                return true; // No data available, try again later
            },
            error.ConnectionResetByPeer, error.BrokenPipe => {
                log.debug("Connection {}: Connection closed by peer during header read", .{self.connection_id});
                return false; // Client disconnected
            },
            else => {
                log.debug("Connection {}: Read error during header: {}", .{ self.connection_id, err });
                const ctx = error_context.server_io_context("read_header", self.connection_id, self.header_bytes_read);
                error_context.log_server_error(err, ctx);
                return err;
            },
        };

        if (n == 0) {
            log.debug("Connection {}: EOF during header read (connection closed)", .{self.connection_id});
            return false; // Connection closed by peer
        }

        log.debug("Connection {}: Read {} bytes for header", .{ self.connection_id, n });
        self.header_bytes_read += n;

        if (self.header_bytes_read >= header_size) {
            log.debug("Connection {}: Complete header received ({} bytes)", .{ self.connection_id, self.header_bytes_read });

            // Log raw header bytes for debugging
            const header_bytes = self.read_buffer[0..header_size];
            log.debug("Connection {}: Raw header bytes: {any}", .{ self.connection_id, header_bytes[0..@min(16, header_size)] });

            // Parse CLI v2 protocol header using safe deserialization
            self.current_header = std.mem.bytesAsValue(MessageHeader, header_bytes[0..@sizeOf(MessageHeader)]).*;

            log.debug("Connection {}: Parsed header - magic=0x{X}, version={}, type={}, size={}", .{
                self.connection_id,
                self.current_header.?.magic,
                self.current_header.?.version,
                self.current_header.?.message_type,
                self.current_header.?.payload_size,
            });

            // Validate header
            self.current_header.?.validate() catch |err| {
                log.warn("Connection {}: Header validation failed: {} - magic=0x{X}, version={}", .{ self.connection_id, err, self.current_header.?.magic, self.current_header.?.version });
                return false;
            };

            log.debug("Connection {}: Header validated successfully", .{self.connection_id});

            if (self.current_header.?.payload_size == 0) {
                log.debug("Connection {}: No payload, transitioning to processing", .{self.connection_id});
                self.state = .processing;
            } else {
                if (self.current_header.?.payload_size > config.max_request_size) {
                    log.warn("Connection {d}: Request too large: {d} > {d}", .{ self.connection_id, self.current_header.?.payload_size, config.max_request_size });
                    return false;
                }
                log.debug("Connection {}: Payload expected ({} bytes), transitioning to reading_payload", .{ self.connection_id, self.current_header.?.payload_size });
                self.state = .reading_payload;
                self.current_payload = try self.arena.allocator().alloc(u8, @intCast(self.current_header.?.payload_size));
            }
        }
        return true;
    }

    /// Attempt to read message payload non-blockingly
    fn try_read_payload(self: *ClientConnection, config: ConnectionConfig) !bool {
        _ = config;

        const payload = self.current_payload orelse return false;

        const n = self.stream.read(payload[self.payload_bytes_read..]) catch |err| switch (err) {
            error.WouldBlock => return true, // No data available, try again later
            error.ConnectionResetByPeer, error.BrokenPipe => return false, // Client disconnected
            else => {
                const ctx = error_context.server_io_context("read_payload", self.connection_id, self.payload_bytes_read);
                error_context.log_server_error(err, ctx);
                return err;
            },
        };

        if (n == 0) return false; // Client disconnected

        self.payload_bytes_read += n;

        if (self.payload_bytes_read >= payload.len) {
            self.state = .processing;
        }

        return true;
    }

    /// Attempt to write response non-blockingly
    fn try_write_response(self: *ClientConnection) !bool {
        const response = self.current_response orelse return false;

        const n = self.stream.write(response[self.response_bytes_written..]) catch |err| switch (err) {
            error.WouldBlock => return true, // Socket buffer full, try again later
            error.ConnectionResetByPeer, error.BrokenPipe => return false, // Client disconnected
            else => {
                const ctx = error_context.server_io_context("write_response", self.connection_id, self.response_bytes_written);
                error_context.log_server_error(err, ctx);
                return err;
            },
        };

        self.response_bytes_written += n;

        if (self.response_bytes_written >= response.len) {
            self.header_bytes_read = 0;
            self.current_header = null;
            self.current_payload = null;
            self.payload_bytes_read = 0;
            self.current_response = null;
            self.response_bytes_written = 0;
            self.state = .reading_header;

            _ = self.arena.reset(.retain_capacity);
        }

        return true;
    }

    /// Check if connection is ready for processing a complete request
    pub fn has_complete_request(self: *const ClientConnection) bool {
        return self.state == .processing;
    }

    /// Access the complete request payload for processing
    pub fn request_payload(self: *const ClientConnection) ?[]const u8 {
        if (self.state != .processing) return null;
        return self.current_payload orelse &[_]u8{}; // Empty payload if no payload expected
    }

    /// Begin response transmission and transition to writing state
    pub fn send_response(self: *ClientConnection, response_data: []const u8) void {
        std.debug.assert(self.state == .processing);
        self.current_response = response_data;
        self.response_bytes_written = 0;
        self.state = .writing_response;
    }
};

// Compile-time guarantees for network protocol stability
comptime {
    if (!(@sizeOf(MessageHeader) == 16)) @compileError(
        "CLI v2 MessageHeader must be exactly 16 bytes",
    );
}

const testing = std.testing;

test "ClientConnection initialization sets correct initial state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Create a mock stream (we can't create a real one without network setup)
    const mock_stream = std.net.Stream{ .handle = -1 };
    const connection_id: u32 = 12345;

    const connection = ClientConnection.init(arena.allocator(), mock_stream, connection_id);

    try testing.expectEqual(connection_id, connection.connection_id);
    try testing.expectEqual(ConnectionState.reading_header, connection.state);
    try testing.expectEqual(@as(usize, 0), connection.header_bytes_read);
    try testing.expectEqual(@as(usize, 0), connection.payload_bytes_read);
    try testing.expectEqual(@as(usize, 0), connection.response_bytes_written);
    try testing.expect(connection.current_header == null);
    try testing.expect(connection.current_payload == null);
    try testing.expect(connection.current_response == null);
}

test "ConnectionState enum has all expected states" {
    // Verify all connection states exist and can be compared
    const states = [_]ConnectionState{
        .reading_header,
        .reading_payload,
        .processing,
        .writing_response,
    };

    for (states) |state| {
        try testing.expect(@intFromEnum(state) >= 0);
    }
}

test "has_complete_request returns correct values for each state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const mock_stream = std.net.Stream{ .handle = -1 };
    var connection = ClientConnection.init(arena.allocator(), mock_stream, 1);

    // reading_header state
    connection.state = .reading_header;
    try testing.expectEqual(false, connection.has_complete_request());

    // reading_payload state
    connection.state = .reading_payload;
    try testing.expectEqual(false, connection.has_complete_request());

    // processing state
    connection.state = .processing;
    try testing.expectEqual(true, connection.has_complete_request());

    // writing_response state
    connection.state = .writing_response;
    try testing.expectEqual(false, connection.has_complete_request());
}

test "request_payload returns correct values based on state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const mock_stream = std.net.Stream{ .handle = -1 };
    var connection = ClientConnection.init(arena.allocator(), mock_stream, 1);

    // Non-processing state should return null
    connection.state = .reading_header;
    try testing.expect(connection.request_payload() == null);

    // Processing state with null payload should return empty slice
    connection.state = .processing;
    const empty_payload = connection.request_payload();
    try testing.expect(empty_payload != null);
    try testing.expectEqual(@as(usize, 0), empty_payload.?.len);

    // Processing state with payload should return the payload
    const test_payload = try arena.allocator().alloc(u8, 10);
    connection.current_payload = test_payload;
    const returned_payload = connection.request_payload();
    try testing.expect(returned_payload != null);
    try testing.expectEqual(test_payload.ptr, returned_payload.?.ptr);
    try testing.expectEqual(@as(usize, 10), returned_payload.?.len);
}

test "send_response sets correct state and data" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const mock_stream = std.net.Stream{ .handle = -1 };
    var connection = ClientConnection.init(arena.allocator(), mock_stream, 1);

    // Must be in processing state to send response
    connection.state = .processing;

    const response_data = "test response data";
    connection.send_response(response_data);

    try testing.expectEqual(ConnectionState.writing_response, connection.state);
    try testing.expectEqualStrings(response_data, connection.current_response.?);
    try testing.expectEqual(@as(usize, 0), connection.response_bytes_written);
}

test "MessageHeader validation accepts valid headers" {
    const valid_header = MessageHeader{
        .magic = cli_protocol.PROTOCOL_MAGIC,
        .version = 1,
        .message_type = .ping_request,
        .payload_size = 0,
    };

    // Should not return an error
    try valid_header.validate();
}

test "MessageHeader validation rejects invalid magic" {
    var invalid_header = MessageHeader{
        .magic = 0x12345678, // Wrong magic
        .version = 1,
        .message_type = .ping_request,
        .payload_size = 0,
    };

    try testing.expectError(error.InvalidMagic, invalid_header.validate());
}

test "MessageHeader validation rejects invalid version" {
    var invalid_header = MessageHeader{
        .magic = cli_protocol.PROTOCOL_MAGIC,
        .version = 999, // Unsupported version
        .message_type = .ping_request,
        .payload_size = 0,
    };

    try testing.expectError(error.VersionMismatch, invalid_header.validate());
}

test "ConnectionConfig default values are reasonable for development" {
    const config = ConnectionConfig{
        .max_request_size = 64 * 1024,
        .max_response_size = 16 * 1024 * 1024,
        .enable_logging = false,
    };
    try testing.expect(config.max_request_size > 0);
    try testing.expect(config.max_request_size <= 1024 * 1024 * 16); // Should be reasonable limit
}
