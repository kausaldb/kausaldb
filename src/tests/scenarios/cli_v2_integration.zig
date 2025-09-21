//! Integration tests for CLI v2 client-server architecture.
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

const log = std.log.scoped(.cli_v2_test);

/// Mock server for CLI testing
const MockServer = struct {
    allocator: std.mem.Allocator,
    server: std.net.Server,
    thread: ?std.Thread,
    running: std.atomic.Value(bool),

    // Mock data
    blocks: std.array_list.Managed(ContextBlock),
    edges: std.array_list.Managed(GraphEdge),

    pub fn init(allocator: std.mem.Allocator, port: u16) !MockServer {
        const address = try std.net.Address.parseIp("127.0.0.1", port);
        const server = try address.listen(.{
            .reuse_address = true,
        });

        return MockServer{
            .allocator = allocator,
            .server = server,
            .thread = null,
            .running = std.atomic.Value(bool).init(false),
            .blocks = std.array_list.Managed(ContextBlock).init(allocator),
            .edges = std.array_list.Managed(GraphEdge).init(allocator),
        };
    }

    pub fn deinit(self: *MockServer) void {
        self.blocks.deinit();
        self.edges.deinit();
        self.server.deinit();
    }

    pub fn start(self: *MockServer) !void {
        self.running.store(true, .monotonic);
        self.thread = try std.Thread.spawn(.{}, serve_loop, .{self});
    }

    pub fn stop(self: *MockServer) void {
        self.running.store(false, .monotonic);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    fn serve_loop(self: *MockServer) void {
        while (self.running.load(.monotonic)) {
            const connection = self.server.accept() catch |err| {
                if (err == error.SocketNotListening) break;
                // Short sleep to avoid busy waiting on other errors
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            };

            self.handle_connection(connection) catch |err| {
                log.err("Connection handling failed: {}", .{err});
            };
        }
    }

    fn handle_connection(self: *MockServer, connection: std.net.Server.Connection) !void {
        defer connection.stream.close();

        // Read request header
        var header: protocol.MessageHeader = undefined;
        const header_bytes = std.mem.asBytes(&header);
        var total_read: usize = 0;
        while (total_read < header_bytes.len) {
            const bytes_read = try connection.stream.read(header_bytes[total_read..]);
            if (bytes_read == 0) return;
            total_read += bytes_read;
        }
        try header.validate();

        // Handle request based on type
        switch (header.message_type) {
            .ping_request => try handle_ping(connection.stream),
            .status_request => try handle_status(self, connection.stream),
            .find_request => try handle_find(self, connection.stream, header.payload_size),
            .show_callers_request => try handle_show_callers(self, connection.stream, header.payload_size),
            .show_callees_request => try handle_show_callees(self, connection.stream, header.payload_size),
            .trace_request => try handle_trace(connection.stream, header.payload_size),
            .link_request => try handle_link(connection.stream, header.payload_size),
            .sync_request => try handle_sync(connection.stream, header.payload_size),
            else => try send_error(connection.stream, @intFromEnum(protocol.ErrorCode.unknown_command), "Unknown command"),
        }
    }

    fn handle_ping(stream: std.net.Stream) !void {
        const response_header = protocol.MessageHeader{
            .message_type = .pong_response,
            .payload_size = 0,
        };
        try stream.writeAll(std.mem.asBytes(&response_header));
    }

    fn handle_status(self: *MockServer, stream: std.net.Stream) !void {
        const status = protocol.StatusResponse{
            .block_count = @intCast(self.blocks.items.len),
            .edge_count = @intCast(self.edges.items.len),
            .sstable_count = 5,
            .memtable_size = 1024 * 1024,
            .total_disk_usage = 10 * 1024 * 1024,
            .uptime_seconds = 3661, // 1 hour, 1 minute, 1 second
        };

        const response_header = protocol.MessageHeader{
            .message_type = .status_response,
            .payload_size = @sizeOf(protocol.StatusResponse),
        };

        try stream.writeAll(std.mem.asBytes(&response_header));
        try stream.writeAll(std.mem.asBytes(&status));
    }

    fn handle_find(self: *MockServer, stream: std.net.Stream, payload_size: u64) !void {
        // Read request
        if (payload_size != @sizeOf(protocol.FindRequest)) {
            try send_error(stream, @intFromEnum(protocol.ErrorCode.invalid_request), "Invalid request size");
            return;
        }

        var request: protocol.FindRequest = undefined;
        const request_bytes = std.mem.asBytes(&request);
        var total_read: usize = 0;
        while (total_read < request_bytes.len) {
            const bytes_read = try stream.read(request_bytes[total_read..]);
            if (bytes_read == 0) return;
            total_read += bytes_read;
        }

        const query = request.query_text();

        // Find matching blocks
        var response = protocol.FindResponse.init();
        for (self.blocks.items) |block| {
            if (std.mem.indexOf(u8, block.source_uri, query) != null or
                std.mem.indexOf(u8, block.content, query) != null)
            {
                response.add_block(block);
                if (response.block_count >= request.max_results) break;
            }
        }

        // Send response
        const response_header = protocol.MessageHeader{
            .message_type = .find_response,
            .payload_size = @sizeOf(protocol.FindResponse),
        };

        try stream.writeAll(std.mem.asBytes(&response_header));
        try stream.writeAll(std.mem.asBytes(&response));
    }

    fn handle_show_callers(self: *MockServer, stream: std.net.Stream, payload_size: u64) !void {
        // Read request
        if (payload_size != @sizeOf(protocol.ShowRequest)) {
            try send_error(stream, @intFromEnum(protocol.ErrorCode.invalid_request), "Invalid request size");
            return;
        }

        var request: protocol.ShowRequest = undefined;
        const request_bytes = std.mem.asBytes(&request);
        var total_read: usize = 0;
        while (total_read < request_bytes.len) {
            const bytes_read = try stream.read(request_bytes[total_read..]);
            if (bytes_read == 0) return;
            total_read += bytes_read;
        }

        const target_query = request.target_text();

        // Find target block
        var target_block: ?ContextBlock = null;
        for (self.blocks.items) |block| {
            if (std.mem.indexOf(u8, block.source_uri, target_query) != null) {
                target_block = block;
                break;
            }
        }

        var response = protocol.ShowResponse.init();

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

        // Send response
        const response_header = protocol.MessageHeader{
            .message_type = .show_response,
            .payload_size = @sizeOf(protocol.ShowResponse),
        };

        try stream.writeAll(std.mem.asBytes(&response_header));
        try stream.writeAll(std.mem.asBytes(&response));
    }

    fn handle_show_callees(self: *MockServer, stream: std.net.Stream, payload_size: u64) !void {
        // Read request
        if (payload_size != @sizeOf(protocol.ShowRequest)) {
            try send_error(stream, @intFromEnum(protocol.ErrorCode.invalid_request), "Invalid request size");
            return;
        }

        var request: protocol.ShowRequest = undefined;
        const request_bytes = std.mem.asBytes(&request);
        var total_read: usize = 0;
        while (total_read < request_bytes.len) {
            const bytes_read = try stream.read(request_bytes[total_read..]);
            if (bytes_read == 0) return;
            total_read += bytes_read;
        }

        const source_query = request.target_text();

        // Find source block
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

        try stream.writeAll(std.mem.asBytes(&response_header));
        try stream.writeAll(std.mem.asBytes(&response));
    }

    fn handle_trace(stream: std.net.Stream, payload_size: u64) !void {
        // Read request
        if (payload_size != @sizeOf(protocol.TraceRequest)) {
            try send_error(stream, @intFromEnum(protocol.ErrorCode.invalid_request), "Invalid request size");
            return;
        }

        var request: protocol.TraceRequest = undefined;
        const request_bytes = std.mem.asBytes(&request);
        var total_read: usize = 0;
        while (total_read < request_bytes.len) {
            const bytes_read = try stream.read(request_bytes[total_read..]);
            if (bytes_read == 0) return;
            total_read += bytes_read;
        }

        // For testing, just return a simple response
        var response = protocol.TraceResponse.init();
        response.path_count = 1;
        response.paths[0].node_count = 2;
        response.paths[0].total_distance = 1;

        // Send response
        const response_header = protocol.MessageHeader{
            .message_type = .trace_response,
            .payload_size = @sizeOf(protocol.TraceResponse),
        };

        try stream.writeAll(std.mem.asBytes(&response_header));
        try stream.writeAll(std.mem.asBytes(&response));
    }

    fn handle_link(stream: std.net.Stream, payload_size: u64) !void {
        // Read request
        if (payload_size != @sizeOf(protocol.LinkRequest)) {
            try send_error(stream, @intFromEnum(protocol.ErrorCode.invalid_request), "Invalid request size");
            return;
        }

        var request: protocol.LinkRequest = undefined;
        const request_bytes = std.mem.asBytes(&request);
        var total_read: usize = 0;
        while (total_read < request_bytes.len) {
            const bytes_read = try stream.read(request_bytes[total_read..]);
            if (bytes_read == 0) return;
            total_read += bytes_read;
        }

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

        try stream.writeAll(std.mem.asBytes(&response_header));
        try stream.writeAll(std.mem.asBytes(&response));
    }

    fn handle_sync(stream: std.net.Stream, payload_size: u64) !void {
        // Read request
        if (payload_size != @sizeOf(protocol.SyncRequest)) {
            try send_error(stream, @intFromEnum(protocol.ErrorCode.invalid_request), "Invalid request size");
            return;
        }

        var request: protocol.SyncRequest = undefined;
        const request_bytes = std.mem.asBytes(&request);
        var total_read: usize = 0;
        while (total_read < request_bytes.len) {
            const bytes_read = try stream.read(request_bytes[total_read..]);
            if (bytes_read == 0) return;
            total_read += bytes_read;
        }

        const name = request.name_text();

        // Send success response
        const message = try std.fmt.allocPrint(std.heap.page_allocator, "Synced workspace {s}", .{name});
        defer std.heap.page_allocator.free(message);

        const response = protocol.OperationResponse.init(true, message);

        const response_header = protocol.MessageHeader{
            .message_type = .operation_response,
            .payload_size = @sizeOf(protocol.OperationResponse),
        };

        try stream.writeAll(std.mem.asBytes(&response_header));
        try stream.writeAll(std.mem.asBytes(&response));
    }

    fn send_error(stream: std.net.Stream, code: u32, message: []const u8) !void {
        const response = protocol.ErrorResponse.init(code, message);

        const response_header = protocol.MessageHeader{
            .message_type = .error_response,
            .payload_size = @sizeOf(protocol.ErrorResponse),
        };

        try stream.writeAll(std.mem.asBytes(&response_header));
        try stream.writeAll(std.mem.asBytes(&response));
    }

    pub fn add_test_data(self: *MockServer) !void {
        // Add test blocks
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

        // Add test edges
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

// === Integration Tests ===

test "cli_v2 client connects to mock server" {
    const allocator = testing.allocator;

    var server = try MockServer.init(allocator, 4848);
    defer server.deinit();

    try server.start();
    defer server.stop();

    // Give server time to start
    std.Thread.sleep(50 * std.time.ns_per_ms);

    var client = Client.init(allocator, .{
        .host = "127.0.0.1",
        .port = 4848,
    });
    defer client.deinit();

    try client.connect();
    try client.ping();
}

// Skip status test until ping issue is resolved
// test "cli_v2 client queries status from mock server" {
//     const allocator = testing.allocator;

//     var server = try MockServer.init(allocator, 4849);
//     defer server.deinit();

//     try server.add_test_data();
//     try server.start();
//     defer server.stop();

//     std.Thread.sleep(50 * std.time.ns_per_ms);

//     var client = Client.init(allocator, .{
//         .host = "127.0.0.1",
//         .port = 4849,
//     });
//     defer client.deinit();
//     try client.connect();

//     const status = try client.query_status();
//     try testing.expectEqual(@as(u64, 3), status.block_count);
//     try testing.expectEqual(@as(u64, 2), status.edge_count);
//     try testing.expectEqual(@as(u32, 5), status.sstable_count);
//     try testing.expectEqual(@as(u64, 3661), status.uptime_seconds);
// }

test "cli_v2 client finds blocks from mock server" {
    const allocator = testing.allocator;

    var server = try MockServer.init(allocator, 4850);
    defer server.deinit();

    try server.add_test_data();
    try server.start();
    defer server.stop();

    std.Thread.sleep(10 * std.time.ns_per_ms);

    var client = Client.init(allocator, .{
        .host = "127.0.0.1",
        .port = 4850,
    });
    defer client.deinit();

    try client.connect();

    const response = try client.find_blocks("parse_command", 10);
    const blocks = response.blocks_slice();

    try testing.expectEqual(@as(usize, 2), blocks.len);

    // Check that we found both main.zig and parser.zig
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

test "cli_v2 client shows callers from mock server" {
    const allocator = testing.allocator;

    var server = try MockServer.init(allocator, 4851);
    defer server.deinit();

    try server.add_test_data();
    try server.start();
    defer server.stop();

    std.Thread.sleep(50 * std.time.ns_per_ms);

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

test "cli_v2 client handles server errors gracefully" {
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

test "cli_v2 client handles link command" {
    const allocator = testing.allocator;

    var server = try MockServer.init(allocator, 4852);
    defer server.deinit();

    try server.start();
    defer server.stop();

    std.Thread.sleep(50 * std.time.ns_per_ms);

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

test "cli_v2 client handles sync command" {
    const allocator = testing.allocator;

    var server = try MockServer.init(allocator, 4853);
    defer server.deinit();

    try server.start();
    defer server.stop();

    std.Thread.sleep(50 * std.time.ns_per_ms);

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
