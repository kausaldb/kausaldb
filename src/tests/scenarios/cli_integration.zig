//! Integration tests for CLI client-server interaction.
//!
//! Validates the complete command execution pipeline including protocol
//! serialization, network communication, and response handling.

const std = @import("std");
const testing = std.testing;

const client_mod = @import("../../cli/client.zig");
const parser = @import("../../cli/parser.zig");
const protocol = @import("../../cli/protocol.zig");
const types = @import("../../core/types.zig");

const Client = client_mod.Client;
const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const GraphEdge = types.GraphEdge;

const log = std.log.scoped(.cli_test);

/// Read a struct from stream with WouldBlock handling and timeout
fn read_from_stream(stream: std.net.Stream, comptime T: type) !?T {
    var data: T = undefined;
    const data_bytes = std.mem.asBytes(&data);
    var total_read: usize = 0;
    var retry_count: u32 = 0;
    const max_retries = 1000; // 1 second timeout at 1ms per retry

    while (total_read < data_bytes.len) {
        const bytes_read = stream.read(data_bytes[total_read..]) catch |err| switch (err) {
            error.WouldBlock => {
                retry_count += 1;
                if (retry_count >= max_retries) {
                    log.debug("Mock server read timeout after {} retries", .{max_retries});
                    return null;
                }
                // No data available, wait briefly and retry
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (bytes_read == 0) return null;
        total_read += bytes_read;
        retry_count = 0; // Reset retry count on successful read
    }
    return data;
}

/// Write all data to stream with WouldBlock handling and timeout
fn write_all_blocking(stream: std.net.Stream, data: []const u8) !void {
    var total_written: usize = 0;
    var retry_count: u32 = 0;
    const max_retries = 1000; // 1 second timeout at 1ms per retry

    while (total_written < data.len) {
        const bytes_written = stream.write(data[total_written..]) catch |err| switch (err) {
            error.WouldBlock => {
                retry_count += 1;
                if (retry_count >= max_retries) {
                    log.debug("Mock server write timeout after {} retries", .{max_retries});
                    return error.Timeout;
                }
                // No space available, wait briefly and retry
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (bytes_written == 0) return error.EndOfStream;
        total_written += bytes_written;
        retry_count = 0; // Reset retry count on successful write
    }
}

/// Mock server for CLI testing
const MockServer = struct {
    allocator: std.mem.Allocator,
    server: std.net.Server,
    thread: ?std.Thread,
    running: std.atomic.Value(bool),
    socket_closed: bool,

    // Test data storage
    blocks: std.array_list.Managed(ContextBlock),
    edges: std.array_list.Managed(GraphEdge),

    pub fn init(allocator: std.mem.Allocator, port: u16) !MockServer {
        const address = try std.net.Address.parseIp("127.0.0.1", port);
        const server = try address.listen(.{
            .reuse_address = true,
        });

        // Make socket non-blocking to prevent hanging in accept()
        const server_flags = try std.posix.fcntl(server.stream.handle, std.posix.F.GETFL, 0);
        // Use numeric constant to avoid @bitOffsetOf LLVM optimization hang
        // Platform-specific O_NONBLOCK values from sys/fcntl.h
        const builtin = @import("builtin");
        const O_NONBLOCK: c_int = switch (builtin.os.tag) {
            .linux => 0x00000800, // O_NONBLOCK on Linux
            .macos => 0x00000004, // O_NONBLOCK on macOS
            else => 0x00000004, // Default to macOS value
        };
        _ = try std.posix.fcntl(server.stream.handle, std.posix.F.SETFL, server_flags | O_NONBLOCK);

        return MockServer{
            .allocator = allocator,
            .server = server,
            .thread = null,
            .running = std.atomic.Value(bool).init(false),
            .socket_closed = false,
            .blocks = std.array_list.Managed(ContextBlock).init(allocator),
            .edges = std.array_list.Managed(GraphEdge).init(allocator),
        };
    }

    pub fn deinit(self: *MockServer) void {
        self.stop();
        if (!self.socket_closed) {
            self.server.deinit();
        }
        self.blocks.deinit();
        self.edges.deinit();
    }

    pub fn start(self: *MockServer) !void {
        self.running.store(true, .monotonic);
        self.thread = try std.Thread.spawn(.{}, serve_loop, .{self});
    }

    pub fn stop(self: *MockServer) void {
        self.running.store(false, .monotonic);

        // Close server socket to wake up any blocking calls
        if (!self.socket_closed) {
            self.server.deinit();
            self.socket_closed = true;
        }

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    fn serve_loop(self: *MockServer) void {
        log.debug("MockServer: starting serve loop", .{});
        while (self.running.load(.monotonic)) {
            if (self.socket_closed) {
                // Socket closed while we were running
                break;
            }

            const connection = self.server.accept() catch |err| switch (err) {
                error.SocketNotListening => {
                    log.debug("MockServer: socket not listening, breaking", .{});
                    break;
                },
                error.FileDescriptorNotASocket, error.ConnectionAborted, error.NetworkSubsystemFailed => {
                    log.debug("MockServer: socket closed or connection aborted: {}, breaking", .{err});
                    break;
                },
                error.WouldBlock => {
                    // No pending connections, sleep briefly and continue
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    continue;
                },
                else => {
                    log.debug("MockServer: accept error: {}, continuing", .{err});
                    // Other errors, sleep briefly to avoid busy loop
                    std.Thread.sleep(1 * std.time.ns_per_ms);
                    continue;
                },
            };

            log.debug("MockServer: accepted new connection", .{});
            self.handle_connection(connection) catch |err| {
                log.err("MockServer: connection handling failed: {}", .{err});
            };
        }
        log.debug("MockServer: serve loop exiting", .{});
    }

    fn handle_connection(self: *MockServer, connection: std.net.Server.Connection) !void {
        defer connection.stream.close();
        log.debug("MockServer: handling new connection", .{});

        const header = (try read_from_stream(connection.stream, protocol.MessageHeader)) orelse {
            log.debug("MockServer: failed to read message header, connection closed", .{});
            return;
        };
        log.debug("MockServer: successfully read header, message_type={}, payload_size={}", .{ header.message_type, header.payload_size });

        try header.validate();
        log.debug("MockServer: header validation passed", .{});

        switch (header.message_type) {
            .ping_request => {
                log.debug("MockServer: handling ping_request", .{});
                try handle_ping(connection.stream);
            },
            .status_request => {
                log.debug("MockServer: handling status_request", .{});
                try handle_status(self, connection.stream);
            },
            .find_request => {
                log.debug("MockServer: handling find_request", .{});
                try handle_find(self, connection.stream, header.payload_size);
            },
            .show_callers_request => {
                log.debug("MockServer: handling show_callers_request", .{});
                try handle_show_callers(self, connection.stream, header.payload_size);
            },
            .show_callees_request => {
                log.debug("MockServer: handling show_callees_request", .{});
                try handle_show_callees(self, connection.stream, header.payload_size);
            },
            .trace_request => {
                log.debug("MockServer: handling trace_request", .{});
                try handle_trace(connection.stream, header.payload_size);
            },
            .link_request => {
                log.debug("MockServer: handling link_request", .{});
                try handle_link(connection.stream, header.payload_size);
            },
            .sync_request => {
                log.debug("MockServer: handling sync_request", .{});
                try handle_sync(connection.stream, header.payload_size);
            },
            else => {
                log.debug("MockServer: unknown command: {}", .{header.message_type});
                try send_error(connection.stream, @intFromEnum(protocol.ErrorCode.unknown_command), "Unknown command");
            },
        }
        log.debug("MockServer: connection handling completed successfully", .{});
    }

    fn handle_ping(stream: std.net.Stream) !void {
        const response_header = protocol.MessageHeader{
            .message_type = .pong_response,
            .payload_size = 0,
        };
        try write_all_blocking(stream, std.mem.asBytes(&response_header));
    }

    fn handle_status(self: *MockServer, stream: std.net.Stream) !void {
        var status = protocol.StatusResponse.init();
        status.block_count = @intCast(self.blocks.items.len);
        status.edge_count = @intCast(self.edges.items.len);
        status.sstable_count = 5;
        status.memtable_size = 1024 * 1024;
        status.total_disk_usage = 10 * 1024 * 1024;
        status.uptime_seconds = 3661; // 1 hour, 1 minute, 1 second

        const response_header = protocol.MessageHeader{
            .message_type = .status_response,
            .payload_size = @sizeOf(protocol.StatusResponse),
        };

        try write_all_blocking(stream, std.mem.asBytes(&response_header));
        try write_all_blocking(stream, std.mem.asBytes(&status));
    }

    fn handle_find(self: *MockServer, stream: std.net.Stream, payload_size: u64) !void {
        if (payload_size != @sizeOf(protocol.FindRequest)) {
            try send_error(stream, @intFromEnum(protocol.ErrorCode.invalid_request), "Invalid request size");
            return;
        }

        const request = (try read_from_stream(stream, protocol.FindRequest)) orelse {
            try send_error(stream, @intFromEnum(protocol.ErrorCode.invalid_request), "Failed to read request");
            return;
        };

        const query = request.query_text();

        var response = protocol.FindResponse.init();
        for (self.blocks.items) |block| {
            if (std.mem.indexOf(u8, block.source_uri, query) != null or
                std.mem.indexOf(u8, block.content, query) != null)
            {
                response.add_block(block);
                if (response.block_count >= request.max_results) break;
            }
        }

        const response_header = protocol.MessageHeader{
            .message_type = .find_response,
            .payload_size = @sizeOf(protocol.FindResponse),
        };

        try write_all_blocking(stream, std.mem.asBytes(&response_header));
        try write_all_blocking(stream, std.mem.asBytes(&response));
    }

    fn handle_show_callers(self: *MockServer, stream: std.net.Stream, payload_size: u64) !void {
        log.debug("handle_show_callers: payload_size={}, expected={}", .{ payload_size, @sizeOf(protocol.ShowRequest) });
        if (payload_size != @sizeOf(protocol.ShowRequest)) {
            log.debug("handle_show_callers: invalid request size", .{});
            try send_error(stream, @intFromEnum(protocol.ErrorCode.invalid_request), "Invalid request size");
            return;
        }

        log.debug("handle_show_callers: reading request from stream", .{});
        const request = (try read_from_stream(stream, protocol.ShowRequest)) orelse {
            log.debug("handle_show_callers: failed to read request from stream", .{});
            try send_error(stream, @intFromEnum(protocol.ErrorCode.invalid_request), "Failed to read request");
            return;
        };

        log.debug("handle_show_callers: successfully read request", .{});

        const target_query = request.target_text();
        log.debug("handle_show_callers: searching for target_query='{s}'", .{target_query});

        var target_block: ?ContextBlock = null;
        for (self.blocks.items) |block| {
            if (std.mem.indexOf(u8, block.source_uri, target_query) != null) {
                target_block = block;
                log.debug("handle_show_callers: found target block in '{s}'", .{block.source_uri});
                break;
            }
        }

        var response = protocol.ShowResponse.init();
        log.debug("handle_show_callers: initialized response, target_block found={}", .{target_block != null});

        if (target_block) |target| {
            // Find all blocks that call the target
            for (self.edges.items) |edge| {
                if (edge.target_id.eql(target.id) and edge.edge_type == .calls) {
                    // Find the source block
                    for (self.blocks.items) |block| {
                        if (block.id.eql(edge.source_id)) {
                            response.add_block(block);
                            response.add_edge(edge);
                            break;
                        }
                    }
                }
            }
        }

        const response_header = protocol.MessageHeader{
            .message_type = .show_response,
            .payload_size = @sizeOf(protocol.ShowResponse),
        };

        log.debug("handle_show_callers: sending response header and payload", .{});
        try write_all_blocking(stream, std.mem.asBytes(&response_header));
        try write_all_blocking(stream, std.mem.asBytes(&response));
        log.debug("handle_show_callers: response sent successfully", .{});
    }

    fn handle_show_callees(self: *MockServer, stream: std.net.Stream, payload_size: u64) !void {
        if (payload_size != @sizeOf(protocol.ShowRequest)) {
            try send_error(stream, @intFromEnum(protocol.ErrorCode.invalid_request), "Invalid request size");
            return;
        }

        const request = (try read_from_stream(stream, protocol.ShowRequest)) orelse {
            try send_error(stream, @intFromEnum(protocol.ErrorCode.invalid_request), "Failed to read request");
            return;
        };

        const source_query = request.target_text();

        var source_block: ?ContextBlock = null;
        for (self.blocks.items) |block| {
            if (std.mem.indexOf(u8, block.source_uri, source_query) != null) {
                source_block = block;
                break;
            }
        }

        var response = protocol.ShowResponse.init();

        if (source_block) |source| {
            // Find all blocks called by the source
            for (self.edges.items) |edge| {
                if (edge.source_id.eql(source.id) and edge.edge_type == .calls) {
                    // Find the target block
                    for (self.blocks.items) |block| {
                        if (block.id.eql(edge.target_id)) {
                            response.add_block(block);
                            response.add_edge(edge);
                            break;
                        }
                    }
                }
            }
        }

        // Send response
        const response_header = protocol.MessageHeader{
            .message_type = .show_response,
            .payload_size = @sizeOf(protocol.ShowResponse),
        };

        try write_all_blocking(stream, std.mem.asBytes(&response_header));
        try write_all_blocking(stream, std.mem.asBytes(&response));
    }

    fn handle_trace(stream: std.net.Stream, payload_size: u64) !void {
        if (payload_size != @sizeOf(protocol.TraceRequest)) {
            try send_error(stream, @intFromEnum(protocol.ErrorCode.invalid_request), "Invalid request size");
            return;
        }

        const request = (try read_from_stream(stream, protocol.TraceRequest)) orelse {
            try send_error(stream, @intFromEnum(protocol.ErrorCode.invalid_request), "Failed to read request");
            return;
        };
        _ = request; // Consumed to read from stream, but unused in mock response

        // For testing, return a simple response
        var response = protocol.TraceResponse.init();
        response.path_count = 1;
        response.paths[0].node_count = 2;
        response.paths[0].total_distance = 1;

        const response_header = protocol.MessageHeader{
            .message_type = .trace_response,
            .payload_size = @sizeOf(protocol.TraceResponse),
        };

        try write_all_blocking(stream, std.mem.asBytes(&response_header));
        try write_all_blocking(stream, std.mem.asBytes(&response));
    }

    fn handle_link(stream: std.net.Stream, payload_size: u64) !void {
        if (payload_size != @sizeOf(protocol.LinkRequest)) {
            try send_error(stream, @intFromEnum(protocol.ErrorCode.invalid_request), "Invalid request size");
            return;
        }

        const request = (try read_from_stream(stream, protocol.LinkRequest)) orelse {
            try send_error(stream, @intFromEnum(protocol.ErrorCode.invalid_request), "Failed to read request");
            return;
        };

        const path = request.path_text();
        const name = request.name_text();

        // Send success response
        const message = try std.fmt.allocPrint(std.heap.page_allocator, "Linked {s} as {s}", .{ path, name });
        defer std.heap.page_allocator.free(message);

        const response = protocol.OperationResponse.init(true, message);

        const response_header = protocol.MessageHeader{
            .message_type = .operation_response,

            .payload_size = @sizeOf(protocol.OperationResponse),
        };

        try write_all_blocking(stream, std.mem.asBytes(&response_header));
        try write_all_blocking(stream, std.mem.asBytes(&response));
    }

    fn handle_sync(stream: std.net.Stream, payload_size: u64) !void {
        if (payload_size != @sizeOf(protocol.SyncRequest)) {
            try send_error(stream, @intFromEnum(protocol.ErrorCode.invalid_request), "Invalid request size");
            return;
        }

        const request = (try read_from_stream(stream, protocol.SyncRequest)) orelse {
            try send_error(stream, @intFromEnum(protocol.ErrorCode.invalid_request), "Failed to read request");
            return;
        };

        const name = request.name_text();

        // Send success response
        const message = try std.fmt.allocPrint(std.heap.page_allocator, "Synced workspace {s}", .{name});
        defer std.heap.page_allocator.free(message);

        const response = protocol.OperationResponse.init(true, message);

        const response_header = protocol.MessageHeader{
            .message_type = .operation_response,
            .payload_size = @sizeOf(protocol.OperationResponse),
        };

        try write_all_blocking(stream, std.mem.asBytes(&response_header));
        try write_all_blocking(stream, std.mem.asBytes(&response));
    }

    fn send_error(stream: std.net.Stream, code: u32, message: []const u8) !void {
        const response = protocol.ErrorResponse.init(code, message);

        const response_header = protocol.MessageHeader{
            .message_type = .error_response,
            .payload_size = @sizeOf(protocol.ErrorResponse),
        };

        try write_all_blocking(stream, std.mem.asBytes(&response_header));
        try write_all_blocking(stream, std.mem.asBytes(&response));
    }

    pub fn add_test_data(self: *MockServer) !void {
        try self.blocks.append(ContextBlock{
            .id = BlockId.from_u64(1),
            .sequence = 1,
            .source_uri = "src/main.zig",
            .metadata_json = "{}",
            .content = "pub fn main() !void { parse_command(); }",
        });

        try self.blocks.append(ContextBlock{
            .id = BlockId.from_u64(2),
            .sequence = 2,
            .source_uri = "src/parser.zig",
            .metadata_json = "{}",
            .content = "pub fn parse_command() Command { }",
        });

        try self.blocks.append(ContextBlock{
            .id = BlockId.from_u64(3),
            .sequence = 3,
            .source_uri = "src/storage.zig",
            .metadata_json = "{}",
            .content = "pub fn init_storage() !Storage { }",
        });

        try self.edges.append(GraphEdge{
            .source_id = BlockId.from_u64(1),
            .target_id = BlockId.from_u64(2),
            .edge_type = .calls,
        });

        try self.edges.append(GraphEdge{
            .source_id = BlockId.from_u64(1),
            .target_id = BlockId.from_u64(3),
            .edge_type = .calls,
        });
    }
};

test "cli client connects to mock server" {
    const allocator = testing.allocator;

    var server = try MockServer.init(allocator, 4848);
    defer server.deinit();

    try server.start();
    defer server.stop();

    // Give server time to start
    std.Thread.sleep(200 * std.time.ns_per_ms);

    var client = Client.init(allocator, .{
        .host = "127.0.0.1",
        .port = 4848,
    });
    defer client.deinit();

    try client.connect();
    try client.ping();
}

test "cli client queries status from mock server" {
    const allocator = testing.allocator;

    var server = try MockServer.init(allocator, 4849);
    defer server.deinit();

    try server.add_test_data();
    try server.start();
    defer server.stop();

    // Give server time to start
    std.Thread.sleep(200 * std.time.ns_per_ms);

    var client = Client.init(allocator, .{
        .host = "127.0.0.1",
        .port = 4849,
    });
    defer client.deinit();
    try client.connect();

    const status = try client.query_status();
    try testing.expectEqual(@as(u64, 3), status.block_count);
    try testing.expectEqual(@as(u64, 2), status.edge_count);
    try testing.expectEqual(@as(u32, 5), status.sstable_count);
    try testing.expectEqual(@as(u64, 3661), status.uptime_seconds);
}

test "cli client finds blocks from mock server" {
    const allocator = testing.allocator;

    var server = try MockServer.init(allocator, 4850);
    defer server.deinit();

    try server.add_test_data();
    try server.start();
    defer server.stop();

    // Give server time to start
    std.Thread.sleep(200 * std.time.ns_per_ms);

    var client = Client.init(allocator, .{
        .host = "127.0.0.1",
        .port = 4850,
    });
    defer client.deinit();

    try client.connect();

    const response = try client.find_blocks("parse_command", 10);
    const blocks = response.blocks_slice();

    try testing.expectEqual(@as(usize, 2), blocks.len);

    var found_main = false;
    var found_parser = false;

    for (blocks) |block| {
        const uri = block.uri[0..block.uri_len];
        if (std.mem.eql(u8, uri, "src/main.zig")) found_main = true;
        if (std.mem.eql(u8, uri, "src/parser.zig")) found_parser = true;
    }

    try testing.expect(found_main);
    try testing.expect(found_parser);
}

test "cli client shows callers from mock server" {
    const allocator = testing.allocator;

    var server = try MockServer.init(allocator, 4851);
    defer server.deinit();

    try server.add_test_data();
    try server.start();
    defer server.stop();

    // Give server time to start
    std.Thread.sleep(200 * std.time.ns_per_ms);

    var client = Client.init(allocator, .{
        .host = "127.0.0.1",
        .port = 4851,
    });
    defer client.deinit();

    try client.connect();

    const response = try client.show_callers("parser", 3);

    try testing.expectEqual(@as(u32, 1), response.block_count);
    try testing.expectEqual(@as(u32, 1), response.edge_count);

    // Verify main.zig calls parser.zig
    const block = response.blocks[0];
    const uri = block.uri[0..block.uri_len];
    try testing.expectEqualStrings("src/main.zig", uri);
}

test "cli client handles server errors gracefully" {
    const allocator = testing.allocator;

    // Try to connect to non-existent server
    var client = Client.init(allocator, .{
        .host = "127.0.0.1",
        .port = 9999,
        .max_retries = 1,
        .timeout_ms = 100,
    });
    defer client.deinit();

    const result = client.connect();
    try testing.expectError(client_mod.ClientError.ServerNotRunning, result);
}

test "cli client handles link command" {
    const allocator = testing.allocator;

    var server = try MockServer.init(allocator, 4852);
    defer server.deinit();

    try server.start();
    defer server.stop();

    // Give server time to start
    std.Thread.sleep(200 * std.time.ns_per_ms);

    var client = Client.init(allocator, .{
        .host = "127.0.0.1",
        .port = 4852,
    });
    defer client.deinit();

    try client.connect();

    const response = try client.link_codebase("/path/to/repo", "myproject");
    try testing.expect(response.success);
    try testing.expect(std.mem.indexOf(u8, response.message_text(), "Linked") != null);
}

test "cli client handles sync command" {
    const allocator = testing.allocator;

    var server = try MockServer.init(allocator, 4853);
    defer server.deinit();

    try server.start();
    defer server.stop();

    // Give server time to start
    std.Thread.sleep(200 * std.time.ns_per_ms);

    var client = Client.init(allocator, .{
        .host = "127.0.0.1",
        .port = 4853,
    });
    defer client.deinit();

    try client.connect();

    const response = try client.sync_workspace("test_workspace", false);
    try testing.expect(response.success);
    try testing.expect(std.mem.indexOf(u8, response.message_text(), "Synced") != null);
}
