//! Thin client implementation for KausalDB CLI.
//!
//! Provides low-latency RPC communication with the KausalDB server.
//! All operations are performed remotely, eliminating startup overhead.

const std = @import("std");

const assert_mod = @import("../core/assert.zig");
const protocol = @import("protocol.zig");
const types = @import("../core/types.zig");

const fatal_assert = assert_mod.fatal_assert;
const testing = std.testing;

const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const GraphEdge = types.GraphEdge;

const log = std.log.scoped(.cli_client);

/// Client configuration
pub const ClientConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 3838,
    timeout_ms: u32 = 5000,
    max_retries: u32 = 3,
};

/// Client error types
pub const ClientError = error{
    ConnectionRefused,
    ConnectionTimeout,
    ServerNotRunning,
    ProtocolError,
    InvalidResponse,
    RequestTooLarge,
    ResponseTooLarge,
} || std.net.Stream.ReadError || std.net.Stream.WriteError;

/// Thin client for server communication
pub const Client = struct {
    allocator: std.mem.Allocator,
    config: ClientConfig,
    stream: ?std.net.Stream,

    /// Initialize client structure (cold init, no I/O)
    pub fn init(allocator: std.mem.Allocator, config: ClientConfig) Client {
        return Client{
            .allocator = allocator,
            .config = config,
            .stream = null,
        };
    }

    /// Connect to server (hot startup, performs I/O)
    pub fn connect(self: *Client) !void {
        const address = try std.net.Address.parseIp(self.config.host, self.config.port);

        var retry_count: u32 = 0;
        while (retry_count < self.config.max_retries) : (retry_count += 1) {
            log.debug("Connection attempt {} of {}", .{ retry_count + 1, self.config.max_retries });

            self.stream = std.net.tcpConnectToAddress(address) catch |err| {
                log.debug("Connection attempt {} failed: {}", .{ retry_count + 1, err });

                if (retry_count == self.config.max_retries - 1) {
                    switch (err) {
                        error.ConnectionRefused => {
                            return ClientError.ServerNotRunning;
                        },
                        else => {
                            return err;
                        },
                    }
                }
                std.Thread.sleep(100 * std.time.ns_per_ms);
                continue;
            };
            break;
        }
    }

    /// Disconnect from server
    pub fn disconnect(self: *Client) void {
        if (self.stream) |stream| {
            stream.close();
            self.stream = null;
        }
    }

    /// Clean up client resources
    pub fn deinit(self: *Client) void {
        self.disconnect();
    }

    /// Read a struct from stream with WouldBlock handling
    fn read_from_stream(self: *Client, comptime T: type) !T {
        const stream = self.stream orelse return ClientError.ConnectionRefused;

        var data: T = undefined;
        const data_bytes = std.mem.asBytes(&data);
        var total_read: usize = 0;
        while (total_read < data_bytes.len) {
            const bytes_read = stream.read(data_bytes[total_read..]) catch |err| switch (err) {
                error.WouldBlock => {
                    std.Thread.sleep(1 * std.time.ns_per_ms);
                    continue;
                },
                else => return ClientError.ProtocolError,
            };

            if (bytes_read == 0) return ClientError.ProtocolError;
            total_read += bytes_read;
        }
        return data;
    }

    fn send_request(self: *Client, comptime T: type, request_type: protocol.MessageType, request: T) !void {
        const stream = self.stream orelse return ClientError.ConnectionRefused;

        const payload_size = @sizeOf(T);
        const header = protocol.MessageHeader{
            .message_type = request_type,
            .payload_size = payload_size,
        };

        try stream.writeAll(std.mem.asBytes(&header));
        try stream.writeAll(std.mem.asBytes(&request));
    }

    fn receive_response(self: *Client, comptime T: type) !T {
        const header = try self.read_from_stream(protocol.MessageHeader);
        try header.validate();

        if (header.message_type == .error_response) {
            const error_resp = try self.read_from_stream(protocol.ErrorResponse);
            log.err("Server error: {s}", .{error_resp.message_text()});
            return ClientError.ProtocolError;
        }

        if (header.payload_size != @sizeOf(T)) {
            return ClientError.InvalidResponse;
        }

        const response = try self.read_from_stream(T);

        // Validate protocol integrity for critical response types
        switch (@TypeOf(T)) {
            protocol.StatusResponse => validate_status_response(&response),
            protocol.FindResponse => validate_find_response(&response),
            else => {},
        }

        return response;
    }

    /// Validate StatusResponse integrity to catch protocol corruption
    fn validate_status_response(status: *const protocol.StatusResponse) void {
        const workspaces = status.workspaces_slice();

        fatal_assert(
            workspaces.len <= protocol.MAX_WORKSPACES_PER_STATUS,
            "Client: Invalid workspace count: {}",
            .{workspaces.len},
        );

        for (workspaces, 0..) |*workspace, i| {
            const sync_status_raw = @intFromEnum(workspace.sync_status);
            fatal_assert(
                sync_status_raw <= 3,
                "Client: Corrupted sync_status in workspace {}: {}",
                .{ i, sync_status_raw },
            );

            const name = workspace.name_text();
            fatal_assert(
                name.len > 0,
                "Client: Empty workspace name at index {}",
                .{i},
            );
        }
    }

    /// Validate FindResponse integrity to catch protocol corruption
    fn validate_find_response(response: *const protocol.FindResponse) void {
        const blocks = response.blocks_slice();

        fatal_assert(
            blocks.len <= protocol.MAX_BLOCKS_PER_RESPONSE,
            "Client: Invalid block count: {}",
            .{blocks.len},
        );

        for (blocks, 0..) |*block, i| {
            fatal_assert(
                block.uri_len <= 256,
                "Client: Corrupted uri_len in block {}: {}",
                .{ i, block.uri_len },
            );

            fatal_assert(
                block.content_preview_len <= 256,
                "Client: Corrupted content_preview_len in block {}: {}",
                .{ i, block.content_preview_len },
            );
        }
    }

    /// Find blocks matching a query
    pub fn find_blocks(self: *Client, query: []const u8, max_results: u16) !protocol.FindResponse {
        const request = protocol.FindRequest.init(query, max_results);
        try self.send_request(protocol.FindRequest, .find_request, request);
        return try self.receive_response(protocol.FindResponse);
    }

    /// Show blocks that call the target
    pub fn show_callers(self: *Client, target: []const u8, max_depth: u16) !protocol.ShowResponse {
        const request = protocol.ShowRequest.init(target, max_depth);
        try self.send_request(protocol.ShowRequest, .show_callers_request, request);
        return try self.receive_response(protocol.ShowResponse);
    }

    /// Show blocks called by the target
    pub fn show_callees(self: *Client, target: []const u8, max_depth: u16) !protocol.ShowResponse {
        const request = protocol.ShowRequest.init(target, max_depth);
        try self.send_request(protocol.ShowRequest, .show_callees_request, request);
        return try self.receive_response(protocol.ShowResponse);
    }

    /// Trace paths between source and target
    pub fn trace_paths(self: *Client, source: []const u8, target: []const u8, max_depth: u16) !protocol.TraceResponse {
        const request = protocol.TraceRequest.init(source, target, max_depth);
        try self.send_request(protocol.TraceRequest, .trace_request, request);
        return try self.receive_response(protocol.TraceResponse);
    }

    /// Alias for trace_paths - trace execution paths between source and target
    pub fn trace_execution(self: *Client, source: []const u8, target: []const u8, max_depth: u16) !protocol.TraceResponse {
        return self.trace_paths(source, target, max_depth);
    }

    /// Link a codebase to the workspace
    pub fn link_codebase(self: *Client, path: []const u8, name: []const u8) !protocol.OperationResponse {
        const request = protocol.LinkRequest.init(path, name);
        try self.send_request(protocol.LinkRequest, .link_request, request);
        return try self.receive_response(protocol.OperationResponse);
    }

    /// Unlink a codebase from the workspace
    pub fn unlink_codebase(self: *Client, name: []const u8) !protocol.OperationResponse {
        const request = protocol.SyncRequest.init(name, false);
        try self.send_request(protocol.SyncRequest, .unlink_request, request);
        return try self.receive_response(protocol.OperationResponse);
    }

    /// Sync a workspace
    pub fn sync_workspace(self: *Client, name: []const u8, force: bool) !protocol.OperationResponse {
        const request = protocol.SyncRequest.init(name, force);
        try self.send_request(protocol.SyncRequest, .sync_request, request);
        return try self.receive_response(protocol.OperationResponse);
    }

    /// Get server status
    pub fn query_status(self: *Client) !protocol.StatusResponse {
        const stream = self.stream orelse return ClientError.ConnectionRefused;

        const header = protocol.MessageHeader{
            .message_type = .status_request,
            .payload_size = 0,
        };

        try stream.writeAll(std.mem.asBytes(&header));
        return try self.receive_response(protocol.StatusResponse);
    }

    /// Ping server for liveness check
    pub fn ping(self: *Client) !void {
        const stream = self.stream orelse {
            return ClientError.ConnectionRefused;
        };

        const header = protocol.MessageHeader{
            .message_type = .ping_request,
            .payload_size = 0,
        };

        try stream.writeAll(std.mem.asBytes(&header));

        const response_header = try self.read_from_stream(protocol.MessageHeader);
        if (response_header.message_type != .pong_response) {
            return ClientError.ProtocolError;
        }
    }

    /// Check if server is running with quick connection test
    pub fn is_server_running(_: std.mem.Allocator, config: ClientConfig) bool {
        const address = std.net.Address.parseIp(config.host, config.port) catch return false;
        const stream = std.net.tcpConnectToAddress(address) catch return false;
        stream.close();
        return true;
    }
};

test "client config default values are reasonable" {
    const config = ClientConfig{};
    try testing.expectEqualStrings("127.0.0.1", config.host);
    try testing.expectEqual(@as(u16, 3838), config.port);
    try testing.expectEqual(@as(u32, 5000), config.timeout_ms);
    try testing.expectEqual(@as(u32, 3), config.max_retries);
}

test "client config custom values override defaults" {
    const config = ClientConfig{
        .host = "192.168.1.100",
        .port = 9999,
        .timeout_ms = 10000,
        .max_retries = 5,
    };
    try testing.expectEqualStrings("192.168.1.100", config.host);
    try testing.expectEqual(@as(u16, 9999), config.port);
    try testing.expectEqual(@as(u32, 10000), config.timeout_ms);
    try testing.expectEqual(@as(u32, 5), config.max_retries);
}

test "client initialization sets correct initial state" {
    const config = ClientConfig{ .host = "test.local", .port = 8080 };
    const client = Client.init(testing.allocator, config);

    try testing.expect(client.allocator.ptr == testing.allocator.ptr);
    try testing.expectEqualStrings("test.local", client.config.host);
    try testing.expectEqual(@as(u16, 8080), client.config.port);
    try testing.expect(client.stream == null);
}

test "protocol workspace validation catches corruption" {
    // Test the workspace validation logic that's used in receive_response
    const valid_workspaces = [_]protocol.WorkspaceInfo{
        protocol.WorkspaceInfo.init_with_status(
            "test-workspace",
            "/test/path",
            100,
            200,
            1640995200,
            .synced,
            1024 * 1024,
        ),
    };

    // Test that valid workspace passes validation (would not crash)
    const workspace = &valid_workspaces[0];
    const name = workspace.name_text();
    try testing.expect(name.len > 0);

    const sync_status_raw = @intFromEnum(workspace.sync_status);
    try testing.expect(sync_status_raw <= 3);
}

test "client deinit is safe with null stream" {
    var client = Client.init(testing.allocator, ClientConfig{});

    // Should not crash when stream is null
    client.deinit();
    try testing.expect(client.stream == null);
}

test "disconnect is safe with null stream" {
    var client = Client.init(testing.allocator, ClientConfig{});

    // Should not crash when stream is already null
    client.disconnect();
    try testing.expect(client.stream == null);
}

test "is_server_running handles invalid address gracefully" {
    // Test with invalid host that should fail address parsing
    const bad_config = ClientConfig{ .host = "not.a.valid.ip.address.format" };
    const result = Client.is_server_running(testing.allocator, bad_config);
    try testing.expectEqual(false, result);
}

test "is_server_running handles unreachable server gracefully" {
    // Test with valid address format but unreachable server
    const unreachable_config = ClientConfig{
        .host = "127.0.0.1",
        .port = 1, // Reserved port, unlikely to have a server
    };
    const result = Client.is_server_running(testing.allocator, unreachable_config);
    try testing.expectEqual(false, result);
}
