//! Thin client implementation for KausalDB CLI.
//!
//! Provides low-latency RPC communication with the KausalDB server.
//! All operations are performed remotely, eliminating startup overhead.

const std = @import("std");

const protocol = @import("protocol.zig");
const types = @import("../core/types.zig");

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
            self.stream = std.net.tcpConnectToAddress(address) catch |err| {
                if (retry_count == self.config.max_retries - 1) {
                    switch (err) {
                        error.ConnectionRefused => return ClientError.ServerNotRunning,
                        else => return err,
                    }
                }

                // 100ms between retries
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

    fn send_request(self: *Client, comptime T: type, request_type: protocol.MessageType, request: T) !void {
        const stream = self.stream orelse return ClientError.ConnectionRefused;

        // Prepare header
        const payload_size = @sizeOf(T);
        const header = protocol.MessageHeader{
            .message_type = request_type,
            .payload_size = payload_size,
        };

        // Send header
        try stream.writeAll(std.mem.asBytes(&header));

        // Send payload
        try stream.writeAll(std.mem.asBytes(&request));
    }

    fn receive_response(self: *Client, comptime T: type) !T {
        const stream = self.stream orelse return ClientError.ConnectionRefused;

        var header: protocol.MessageHeader = undefined;
        const header_bytes = std.mem.asBytes(&header);
        var total_read: usize = 0;
        while (total_read < header_bytes.len) {
            const bytes_read = try stream.read(header_bytes[total_read..]);
            if (bytes_read == 0) return ClientError.ProtocolError;
            total_read += bytes_read;
        }
        try header.validate();

        if (header.message_type == .error_response) {
            var error_resp: protocol.ErrorResponse = undefined;
            const error_bytes = std.mem.asBytes(&error_resp);
            var error_total_read: usize = 0;
            while (error_total_read < error_bytes.len) {
                const error_bytes_read = try stream.read(error_bytes[error_total_read..]);
                if (error_bytes_read == 0) return ClientError.ProtocolError;
                error_total_read += error_bytes_read;
            }
            log.err("Server error: {s}", .{error_resp.message_text()});
            return ClientError.ProtocolError;
        }

        if (header.payload_size != @sizeOf(T)) {
            return ClientError.InvalidResponse;
        }

        var response: T = undefined;
        const response_bytes = std.mem.asBytes(&response);
        var response_total_read: usize = 0;
        while (response_total_read < response_bytes.len) {
            const response_bytes_read = try stream.read(response_bytes[response_total_read..]);
            if (response_bytes_read == 0) return ClientError.ProtocolError;
            response_total_read += response_bytes_read;
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
        const stream = self.stream orelse return ClientError.ConnectionRefused;

        const header = protocol.MessageHeader{
            .message_type = .ping_request,
            .payload_size = 0,
        };

        try stream.writeAll(std.mem.asBytes(&header));

        var response_header: protocol.MessageHeader = undefined;
        const ping_bytes = std.mem.asBytes(&response_header);
        var ping_total_read: usize = 0;
        while (ping_total_read < ping_bytes.len) {
            const ping_bytes_read = try stream.read(ping_bytes[ping_total_read..]);
            if (ping_bytes_read == 0) return ClientError.ProtocolError;
            ping_total_read += ping_bytes_read;
        }
        try response_header.validate();

        if (response_header.message_type != .pong_response) {
            return ClientError.InvalidResponse;
        }
    }

    /// Check if server is running without full connection
    pub fn is_server_running(allocator: std.mem.Allocator, config: ClientConfig) bool {
        var client = Client.init(allocator, config);
        defer client.deinit();

        client.connect() catch return false;
        client.ping() catch return false;

        return true;
    }
};
