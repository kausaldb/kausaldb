//! Wire protocol for KausalDB client-server communication.
//!
//! Defines packed message structures for zero-copy serialization between
//! CLI client and server. All structures are designed for direct network
//! transmission with explicit field ordering and no padding.

const std = @import("std");

const assert_mod = @import("../core/assert.zig");
const types = @import("../core/types.zig");

const ContextBlock = types.ContextBlock;
const BlockId = types.BlockId;
const GraphEdge = types.GraphEdge;
const EdgeType = types.EdgeType;

comptime {
    // Verify all protocol structures have expected sizes
    assert_mod.comptime_assert(@sizeOf(MessageHeader) == 16, "MessageHeader size mismatch");
}

/// Protocol version for compatibility checking
pub const PROTOCOL_VERSION: u16 = 1;

/// Maximum sizes for protocol fields
pub const MAX_QUERY_LENGTH = 256;
pub const MAX_PATH_LENGTH = 4096;
pub const MAX_NAME_LENGTH = 128;
pub const MAX_BLOCKS_PER_RESPONSE = 1000;
pub const MAX_EDGES_PER_RESPONSE = 10000;
pub const MAX_WORKSPACES_PER_STATUS = 10;
pub const MAX_WORKSPACE_PATH_LENGTH = 256;

/// Format bytes in human-readable format (MB, GB, etc.)
pub fn format_bytes(allocator: std.mem.Allocator, bytes: u64) ![]const u8 {
    if (bytes < 1024) {
        return try std.fmt.allocPrint(allocator, "{d} B", .{bytes});
    } else if (bytes < 1024 * 1024) {
        const kb = @as(f64, @floatFromInt(bytes)) / 1024.0;
        return try std.fmt.allocPrint(allocator, "{:.1} KB", .{kb});
    } else if (bytes < 1024 * 1024 * 1024) {
        const mb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
        return try std.fmt.allocPrint(allocator, "{:.1} MB", .{mb});
    } else {
        const gb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0);
        return try std.fmt.allocPrint(allocator, "{:.1} GB", .{gb});
    }
}

/// Format elapsed time as "2m ago", "1h 15m ago", etc.
pub fn format_time_ago(allocator: std.mem.Allocator, elapsed_seconds: i64) ![]const u8 {
    if (elapsed_seconds < 0) {
        return try allocator.dupe(u8, "in future");
    }

    const seconds = @as(u64, @intCast(elapsed_seconds));

    if (seconds < 60) {
        return try std.fmt.allocPrint(allocator, "{d}s ago", .{seconds});
    } else if (seconds < 3600) {
        const minutes = seconds / 60;
        return try std.fmt.allocPrint(allocator, "{d}m ago", .{minutes});
    } else if (seconds < 86400) {
        const hours = seconds / 3600;
        const minutes = (seconds % 3600) / 60;
        if (minutes == 0) {
            return try std.fmt.allocPrint(allocator, "{d}h ago", .{hours});
        } else {
            return try std.fmt.allocPrint(allocator, "{d}h {d}m ago", .{ hours, minutes });
        }
    } else {
        const days = seconds / 86400;
        return try std.fmt.allocPrint(allocator, "{d}d ago", .{days});
    }
}

/// Format uptime in human-readable format
pub fn format_uptime(allocator: std.mem.Allocator, uptime_seconds: u64) ![]const u8 {
    if (uptime_seconds < 60) {
        return try std.fmt.allocPrint(allocator, "{d}s", .{uptime_seconds});
    } else if (uptime_seconds < 3600) {
        const minutes = uptime_seconds / 60;
        const seconds = uptime_seconds % 60;
        if (seconds == 0) {
            return try std.fmt.allocPrint(allocator, "{d}m", .{minutes});
        } else {
            return try std.fmt.allocPrint(allocator, "{d}m {d}s", .{ minutes, seconds });
        }
    } else if (uptime_seconds < 86400) {
        const hours = uptime_seconds / 3600;
        const minutes = (uptime_seconds % 3600) / 60;
        if (minutes == 0) {
            return try std.fmt.allocPrint(allocator, "{d}h", .{hours});
        } else {
            return try std.fmt.allocPrint(allocator, "{d}h {d}m", .{ hours, minutes });
        }
    } else {
        const days = uptime_seconds / 86400;
        const hours = (uptime_seconds % 86400) / 3600;
        if (hours == 0) {
            return try std.fmt.allocPrint(allocator, "{d}d", .{days});
        } else {
            return try std.fmt.allocPrint(allocator, "{d}d {d}h", .{ days, hours });
        }
    }
}

/// Message type enumeration
pub const MessageType = enum(u16) {
    // Requests
    find_request = 0x0001,
    show_callers_request = 0x0002,
    show_callees_request = 0x0003,
    trace_request = 0x0004,
    link_request = 0x0005,
    unlink_request = 0x0006,
    sync_request = 0x0007,
    status_request = 0x0008,
    ping_request = 0x0009,
    clear_workspace_request = 0x000A,

    // Responses
    find_response = 0x8001,
    show_response = 0x8002,
    trace_response = 0x8003,
    operation_response = 0x8004,
    status_response = 0x8005,
    pong_response = 0x8006,
    error_response = 0xFFFF,
};

/// Common message header for all protocol messages
pub const MessageHeader = struct {
    magic: u32 = 0x4B41554C, // 'KAUL'
    version: u16 = PROTOCOL_VERSION,
    message_type: MessageType,
    payload_size: u64,

    pub fn validate(self: MessageHeader) !void {
        if (self.magic != 0x4B41554C) {
            return error.InvalidMagic;
        }
        if (self.version != PROTOCOL_VERSION) {
            return error.VersionMismatch;
        }
    }
};

// === Request Structures ===

/// Request to find blocks by query
pub const FindRequest = struct {
    query_len: u16,
    max_results: u16,
    include_metadata: bool,
    _padding: [3]u8 = .{0} ** 3,
    query: [MAX_QUERY_LENGTH]u8,

    pub fn init(query: []const u8, max_results: u16) FindRequest {
        var req = FindRequest{
            .query = [_]u8{0} ** MAX_QUERY_LENGTH,
            .query_len = @intCast(query.len),
            .max_results = max_results,
            .include_metadata = true,
            ._padding = .{0} ** 3,
        };
        @memcpy(req.query[0..query.len], query);
        return req;
    }

    pub fn query_text(self: *const FindRequest) []const u8 {
        return self.query[0..self.query_len];
    }
};

/// Request to show relationships
pub const ShowRequest = struct {
    target: [MAX_QUERY_LENGTH]u8,
    target_len: u16,
    max_depth: u16,
    max_results: u32,

    pub fn init(target: []const u8, max_depth: u16) ShowRequest {
        var req = ShowRequest{
            .target = [_]u8{0} ** MAX_QUERY_LENGTH,
            .target_len = @intCast(target.len),
            .max_depth = max_depth,
            .max_results = 1000,
        };
        @memcpy(req.target[0..target.len], target);
        return req;
    }

    pub fn target_text(self: *const ShowRequest) []const u8 {
        return self.target[0..self.target_len];
    }
};

/// Request to trace execution paths
pub const TraceRequest = struct {
    source: [MAX_QUERY_LENGTH]u8,
    source_len: u16,
    target: [MAX_QUERY_LENGTH]u8,
    target_len: u16,
    max_depth: u16,
    include_all_paths: bool,
    _padding: [1]u8 = .{0},

    pub fn init(source: []const u8, target: []const u8, max_depth: u16) TraceRequest {
        var req = TraceRequest{
            .source = [_]u8{0} ** MAX_QUERY_LENGTH,
            .source_len = @intCast(source.len),
            .target = [_]u8{0} ** MAX_QUERY_LENGTH,
            .target_len = @intCast(target.len),
            .max_depth = max_depth,
            .include_all_paths = false,
            ._padding = .{0},
        };
        @memcpy(req.source[0..source.len], source);
        @memcpy(req.target[0..target.len], target);
        return req;
    }

    pub fn source_text(self: *const TraceRequest) []const u8 {
        return self.source[0..self.source_len];
    }

    pub fn target_text(self: *const TraceRequest) []const u8 {
        return self.target[0..self.target_len];
    }
};

/// Request to link a codebase
pub const LinkRequest = struct {
    path_len: u16,
    name_len: u16,
    _padding: [4]u8 = .{0} ** 4,
    path: [MAX_PATH_LENGTH]u8,
    name: [MAX_NAME_LENGTH]u8,

    pub fn init(path: []const u8, name: []const u8) LinkRequest {
        var req = LinkRequest{
            .path = [_]u8{0} ** MAX_PATH_LENGTH,
            .path_len = @intCast(path.len),
            .name = [_]u8{0} ** MAX_NAME_LENGTH,
            .name_len = @intCast(name.len),
            ._padding = .{0} ** 4,
        };
        @memcpy(req.path[0..path.len], path);
        @memcpy(req.name[0..name.len], name);
        return req;
    }

    pub fn path_text(self: *const LinkRequest) []const u8 {
        return self.path[0..self.path_len];
    }

    pub fn name_text(self: *const LinkRequest) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Request to sync a workspace
pub const SyncRequest = struct {
    name: [MAX_NAME_LENGTH]u8,
    name_len: u16,
    force: bool,
    _padding: [5]u8 = .{0} ** 5,

    pub fn init(name: []const u8, force: bool) SyncRequest {
        var req = SyncRequest{
            .name = [_]u8{0} ** MAX_NAME_LENGTH,
            .name_len = @intCast(name.len),
            .force = force,
            ._padding = .{0} ** 5,
        };
        @memcpy(req.name[0..name.len], name);
        return req;
    }

    pub fn name_text(self: *const SyncRequest) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Simplified block information for responses
pub const BlockInfo = struct {
    id: BlockId,
    uri: [256]u8,
    uri_len: u16,
    content_preview: [256]u8,
    content_preview_len: u16,
    metadata_size: u16,
    _padding: [2]u8 = .{0} ** 2,

    pub fn from_block(block: ContextBlock) BlockInfo {
        var info = BlockInfo{
            .id = block.id,
            .uri = [_]u8{0} ** 256,
            .uri_len = @intCast(@min(block.source_uri.len, 256)),
            .content_preview = [_]u8{0} ** 256,
            .content_preview_len = @intCast(@min(block.content.len, 256)),
            .metadata_size = @intCast(block.metadata_json.len),
        };
        @memcpy(info.uri[0..info.uri_len], block.source_uri[0..info.uri_len]);
        @memcpy(info.content_preview[0..info.content_preview_len], block.content[0..info.content_preview_len]);
        return info;
    }
};

/// Response containing found blocks
pub const FindResponse = struct {
    block_count: u32,
    blocks: [MAX_BLOCKS_PER_RESPONSE]BlockInfo,

    pub fn init() FindResponse {
        return FindResponse{
            .block_count = 0,
            .blocks = [_]BlockInfo{std.mem.zeroes(BlockInfo)} ** MAX_BLOCKS_PER_RESPONSE,
        };
    }

    pub fn add_block(self: *FindResponse, block: ContextBlock) void {
        if (self.block_count >= MAX_BLOCKS_PER_RESPONSE) return;
        self.blocks[self.block_count] = BlockInfo.from_block(block);
        self.block_count += 1;
    }

    pub fn blocks_slice(self: FindResponse) []const BlockInfo {
        return self.blocks[0..self.block_count];
    }
};

/// Response for relationship queries
pub const ShowResponse = struct {
    block_count: u32,
    edge_count: u32,
    blocks: [MAX_BLOCKS_PER_RESPONSE]BlockInfo,
    edges: [MAX_EDGES_PER_RESPONSE]GraphEdge,

    pub fn init() ShowResponse {
        return ShowResponse{
            .block_count = 0,
            .edge_count = 0,
            .blocks = [_]BlockInfo{std.mem.zeroes(BlockInfo)} ** MAX_BLOCKS_PER_RESPONSE,
            .edges = [_]GraphEdge{GraphEdge{
                .source_id = std.mem.zeroes(BlockId),
                .target_id = std.mem.zeroes(BlockId),
                .edge_type = types.EdgeType.imports,
            }} ** MAX_EDGES_PER_RESPONSE,
        };
    }

    pub fn add_block(self: *ShowResponse, block: ContextBlock) void {
        if (self.block_count >= MAX_BLOCKS_PER_RESPONSE) return;
        self.blocks[self.block_count] = BlockInfo.from_block(block);
        self.block_count += 1;
    }

    pub fn add_edge(self: *ShowResponse, edge: GraphEdge) void {
        if (self.edge_count >= MAX_EDGES_PER_RESPONSE) return;
        self.edges[self.edge_count] = edge;
        self.edge_count += 1;
    }
};

/// Trace path information
pub const TracePath = struct {
    nodes: [256]BlockId,
    node_count: u16,
    total_distance: u16,

    pub fn init() TracePath {
        return TracePath{
            .nodes = [_]BlockId{BlockId.from_u64(0)} ** 256,
            .node_count = 0,
            .total_distance = 0,
        };
    }
};

/// Response for trace queries
pub const TraceResponse = struct {
    path_count: u16,
    paths: [100]TracePath,

    pub fn init() TraceResponse {
        return TraceResponse{
            .path_count = 0,
            .paths = [_]TracePath{TracePath.init()} ** 100,
        };
    }
};

/// Generic operation response
pub const OperationResponse = struct {
    success: bool,
    message: [256]u8,
    message_len: u16,
    _padding: [5]u8 = .{0} ** 5,

    pub fn init(success: bool, message: []const u8) OperationResponse {
        var resp = OperationResponse{
            .success = success,
            .message = [_]u8{0} ** 256,
            .message_len = @intCast(@min(message.len, 256)),
        };
        @memcpy(resp.message[0..resp.message_len], message[0..resp.message_len]);
        return resp;
    }

    pub fn message_text(self: *const OperationResponse) []const u8 {
        return self.message[0..self.message_len];
    }
};

/// Workspace sync status for user display
pub const WorkspaceSyncStatus = enum(u8) {
    synced = 0, // ✓ Recently synced, up to date
    needs_sync = 1, // ⚠ Changes detected, sync needed
    sync_error = 2, // ✗ Last sync failed
    never_synced = 3, // ⚠ Linked but never synced
};

/// Server status response
pub const WorkspaceInfo = extern struct {
    name: [MAX_NAME_LENGTH]u8,
    path: [MAX_WORKSPACE_PATH_LENGTH]u8,
    block_count: u32,
    edge_count: u32,
    last_sync_timestamp: i64,
    sync_status: WorkspaceSyncStatus,
    _padding: [7]u8 = .{0} ** 7,
    storage_bytes: u64,

    pub fn init(name: []const u8, path: []const u8, block_count: u32, edge_count: u32, last_sync: i64) WorkspaceInfo {
        return init_with_status(name, path, block_count, edge_count, last_sync, .never_synced, 0);
    }

    pub fn init_with_status(
        name: []const u8,
        path: []const u8,
        block_count: u32,
        edge_count: u32,
        last_sync: i64,
        sync_status: WorkspaceSyncStatus,
        storage_bytes: u64,
    ) WorkspaceInfo {
        var info = WorkspaceInfo{
            .name = [_]u8{0} ** MAX_NAME_LENGTH,
            .path = [_]u8{0} ** MAX_WORKSPACE_PATH_LENGTH,
            .block_count = block_count,
            .edge_count = edge_count,
            .last_sync_timestamp = last_sync,
            .sync_status = sync_status,
            .storage_bytes = storage_bytes,
        };

        if (name.len > 0) {
            const name_len = @min(name.len, MAX_NAME_LENGTH - 1);
            @memcpy(info.name[0..name_len], name[0..name_len]);
        }

        if (path.len > 0) {
            const path_len = @min(path.len, MAX_WORKSPACE_PATH_LENGTH - 1);
            @memcpy(info.path[0..path_len], path[0..path_len]);
        }

        return info;
    }

    pub fn name_text(self: *const WorkspaceInfo) []const u8 {
        const len = std.mem.indexOfScalar(u8, &self.name, 0) orelse self.name.len;
        return self.name[0..len];
    }

    pub fn path_text(self: *const WorkspaceInfo) []const u8 {
        const len = std.mem.indexOfScalar(u8, &self.path, 0) orelse self.path.len;
        return self.path[0..len];
    }

    /// Get status icon for terminal display
    pub fn status_icon(self: *const WorkspaceInfo) []const u8 {
        return switch (self.sync_status) {
            .synced => "✓",
            .needs_sync => "⚠",
            .sync_error => "✗",
            .never_synced => "⚠",
        };
    }

    /// Get human-readable status text
    pub fn status_text(self: *const WorkspaceInfo) []const u8 {
        return switch (self.sync_status) {
            .synced => "synced",
            .needs_sync => "sync needed",
            .sync_error => "sync failed",
            .never_synced => "never synced",
        };
    }

    /// Format storage size in human-readable format
    pub fn format_storage_size(self: *const WorkspaceInfo, allocator: std.mem.Allocator) ![]const u8 {
        return format_bytes(allocator, self.storage_bytes);
    }

    /// Format last sync time as "2m ago", "never", etc.
    pub fn format_last_sync(self: *const WorkspaceInfo, allocator: std.mem.Allocator, current_timestamp: i64) ![]const u8 {
        if (self.last_sync_timestamp == 0) {
            return try allocator.dupe(u8, "never");
        }

        const elapsed_seconds = current_timestamp - self.last_sync_timestamp;
        return format_time_ago(allocator, elapsed_seconds);
    }
};

pub const StatusResponse = extern struct {
    block_count: u64,
    edge_count: u64,
    sstable_count: u32,
    memtable_size: u64,
    total_disk_usage: u64,
    uptime_seconds: u64,
    workspace_count: u32,
    workspaces: [MAX_WORKSPACES_PER_STATUS]WorkspaceInfo,

    pub fn init() StatusResponse {
        return StatusResponse{
            .block_count = 0,
            .edge_count = 0,
            .sstable_count = 0,
            .memtable_size = 0,
            .total_disk_usage = 0,
            .uptime_seconds = 0,
            .workspace_count = 0,
            .workspaces = [_]WorkspaceInfo{std.mem.zeroes(WorkspaceInfo)} ** MAX_WORKSPACES_PER_STATUS,
        };
    }

    pub fn add_workspace(self: *StatusResponse, workspace: *const WorkspaceInfo) void {
        if (self.workspace_count >= MAX_WORKSPACES_PER_STATUS) return;
        self.workspaces[self.workspace_count] = workspace.*;
        self.workspace_count += 1;
    }

    pub fn workspaces_slice(self: *const StatusResponse) []const WorkspaceInfo {
        return self.workspaces[0..self.workspace_count];
    }
};

/// Error response
pub const ErrorResponse = struct {
    error_code: u32,
    message: [256]u8,
    message_len: u16,
    _padding: [2]u8 = .{0} ** 2,

    pub fn init(code: u32, message: []const u8) ErrorResponse {
        var resp = ErrorResponse{
            .error_code = code,
            .message = [_]u8{0} ** 256,
            .message_len = @intCast(@min(message.len, 256)),
        };
        @memcpy(resp.message[0..resp.message_len], message[0..resp.message_len]);
        return resp;
    }

    pub fn message_text(self: *const ErrorResponse) []const u8 {
        return self.message[0..self.message_len];
    }
};

/// Protocol error codes
pub const ErrorCode = enum(u32) {
    unknown_command = 1,
    invalid_request = 2,
    server_error = 3,
    not_found = 4,
    timeout = 5,
    too_many_results = 6,
    invalid_query = 7,
    permission_denied = 8,
};
