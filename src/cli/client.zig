//! Thin client implementation for KausalDB CLI.
//!
//! Provides low-latency RPC communication with the KausalDB server.
//! All operations are performed remotely, eliminating startup overhead.

const std = @import("std");

const assert_mod = @import("../core/assert.zig");
const protocol = @import("protocol.zig");
const types = @import("../core/types.zig");

const fatal_assert = assert_mod.fatal_assert;

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
                            log.debug("Server not running - connection refused after {} attempts", .{retry_count + 1});
                            return ClientError.ServerNotRunning;
                        },
                        else => {
                            log.debug("Connection failed after {} attempts: {}", .{ retry_count + 1, err });
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
                    // No data available, wait briefly and retry
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

        // Add integrity validation for StatusResponse
        if (T == protocol.StatusResponse) {
            const status_response = &response;
            const workspaces = status_response.workspaces_slice();

            fatal_assert(
                workspaces.len <= protocol.MAX_WORKSPACES_PER_STATUS,
                "Invalid workspace count: {}",
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
                fatal_assert(name.len > 0, "Client: Empty workspace name at index {}", .{i});
            }
        }

        return response;
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
        const request = protocol.SyncRequest.init(name, false); // Reuse SyncRequest structure
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
        // Status request has no payload, just send header
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

    /// Check if server is running with quick connection test (no retries, no debug output)
    pub fn is_server_running(_: std.mem.Allocator, config: ClientConfig) bool {
        const address = std.net.Address.parseIp(config.host, config.port) catch return false;
        const stream = std.net.tcpConnectToAddress(address) catch return false;
        stream.close();
        return true;
    }
};
