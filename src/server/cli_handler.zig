//! CLI protocol handler for kausal server.
//!
//! Handles client requests from the thin CLI client, translating between
//! CLI wire protocol and internal engine APIs. Integrates with existing
//! server infrastructure while maintaining clean separation of concerns.

const std = @import("std");

const assert_mod = @import("../core/assert.zig");
const cli_protocol = @import("../cli/protocol.zig");
const concurrency = @import("../core/concurrency.zig");
const error_context = @import("../core/error_context.zig");
const memory = @import("../core/memory.zig");
const query_engine = @import("../query/engine.zig");
const storage = @import("../storage/engine.zig");
const types = @import("../core/types.zig");
const workspace_manager = @import("../workspace/manager.zig");
const ownership = @import("../core/ownership.zig");

const assert = assert_mod.assert;
const fatal_assert = assert_mod.fatal_assert;

const ArenaCoordinator = memory.ArenaCoordinator;
const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const GraphEdge = types.GraphEdge;
const OwnedBlock = ownership.OwnedBlock;
const QueryEngine = query_engine.QueryEngine;
const StorageEngine = storage.StorageEngine;
const WorkspaceManager = workspace_manager.WorkspaceManager;

const log = std.log.scoped(.cli_handler);

/// CLI request handler context
pub const HandlerContext = struct {
    allocator: std.mem.Allocator,
    storage_engine: *StorageEngine,
    query_engine: *QueryEngine,
    workspace_manager: *WorkspaceManager,

    pub fn init(
        allocator: std.mem.Allocator,
        storage_eng: *StorageEngine,
        query_eng: *QueryEngine,
        workspace_mgr: *WorkspaceManager,
    ) HandlerContext {
        return HandlerContext{
            .allocator = allocator,
            .storage_engine = storage_eng,
            .query_engine = query_eng,
            .workspace_manager = workspace_mgr,
        };
    }
};

/// Handle CLI protocol messages and return response bytes
pub fn handle_cli_message(
    ctx: HandlerContext,
    message_type: cli_protocol.MessageType,
    payload: []const u8,
) ![]const u8 {
    concurrency.assert_main_thread();

    switch (message_type) {
        .ping_request => return try handle_ping_request(ctx),
        .status_request => return try handle_status_request(ctx),
        .find_request => return try handle_find_request(ctx, payload),
        .show_callers_request => return try handle_show_callers_request(ctx, payload),
        .show_callees_request => return try handle_show_callees_request(ctx, payload),
        .trace_request => return try handle_trace_request(ctx, payload),
        .link_request => return try handle_link_request(ctx, payload),
        .unlink_request => return try handle_unlink_request(ctx, payload),
        .sync_request => return try handle_sync_request(ctx, payload),
        else => return try create_error_response(
            ctx,
            @intFromEnum(cli_protocol.ErrorCode.unknown_command),
            "Unknown command",
        ),
    }
}

fn handle_ping_request(ctx: HandlerContext) ![]const u8 {
    const response_header = cli_protocol.MessageHeader{
        .message_type = .pong_response,
        .payload_size = 0,
    };

    const response_bytes = try ctx.allocator.alloc(u8, @sizeOf(cli_protocol.MessageHeader));
    @memcpy(response_bytes, std.mem.asBytes(&response_header));
    return response_bytes;
}

fn handle_status_request(ctx: HandlerContext) ![]const u8 {
    const storage_stats = ctx.storage_engine.query_statistics();

    const status = cli_protocol.StatusResponse{
        .block_count = storage_stats.total_blocks,
        .edge_count = storage_stats.total_edges,
        .sstable_count = @intCast(storage_stats.sstable_count),
        .memtable_size = storage_stats.memtable_bytes,
        .total_disk_usage = storage_stats.total_disk_bytes,
        .uptime_seconds = @intCast(@divFloor(std.time.milliTimestamp(), 1000)),
    };

    const response_header = cli_protocol.MessageHeader{
        .message_type = .status_response,
        .payload_size = @sizeOf(cli_protocol.StatusResponse),
    };

    const total_size = @sizeOf(cli_protocol.MessageHeader) + @sizeOf(cli_protocol.StatusResponse);
    const response_bytes = try ctx.allocator.alloc(u8, total_size);

    @memcpy(response_bytes[0..@sizeOf(cli_protocol.MessageHeader)], std.mem.asBytes(&response_header));
    @memcpy(response_bytes[@sizeOf(cli_protocol.MessageHeader)..], std.mem.asBytes(&status));

    return response_bytes;
}

fn handle_find_request(ctx: HandlerContext, payload: []const u8) ![]const u8 {
    if (payload.len != @sizeOf(cli_protocol.FindRequest)) {
        return try create_error_response(
            ctx,
            @intFromEnum(cli_protocol.ErrorCode.invalid_request),
            "Invalid find request size",
        );
    }

    const request = @as(*const cli_protocol.FindRequest, @ptrCast(@alignCast(payload.ptr)));
    const query_text = request.query_text();

    // Execute find query using available QueryEngine methods
    const semantic_result = ctx.query_engine.find_by_name("", "function", query_text) catch |err| {
        const ctx_info = error_context.ServerContext{
            .operation = "find_blocks",
        };
        error_context.log_server_error(err, ctx_info);

        const error_msg = try std.fmt.allocPrint(ctx.allocator, "Find query failed: {}", .{err});
        defer ctx.allocator.free(error_msg);
        return try create_error_response(ctx, @intFromEnum(cli_protocol.ErrorCode.server_error), error_msg);
    };

    // Convert semantic results to owned blocks
    var blocks = std.array_list.Managed(OwnedBlock).init(ctx.allocator);
    defer blocks.deinit();

    const max_results = @min(request.max_results, semantic_result.results.len);
    for (semantic_result.results[0..max_results]) |result| {
        try blocks.append(result.block);
    }

    // Build response
    var response = cli_protocol.FindResponse.init();
    for (blocks.items) |block| {
        if (response.block_count >= cli_protocol.MAX_BLOCKS_PER_RESPONSE) break;
        response.add_block(block.block);
    }

    return try serialize_find_response(ctx, response);
}

fn handle_show_callers_request(ctx: HandlerContext, payload: []const u8) ![]const u8 {
    if (payload.len != @sizeOf(cli_protocol.ShowRequest)) {
        return try create_error_response(
            ctx,
            @intFromEnum(cli_protocol.ErrorCode.invalid_request),
            "Invalid show request size",
        );
    }

    const request = @as(*const cli_protocol.ShowRequest, @ptrCast(@alignCast(payload.ptr))).*;
    const target_text = request.target_text();

    // Find target blocks first
    const target_result = ctx.query_engine.find_by_name("", "function", target_text) catch |err| {
        const ctx_info = error_context.ServerContext{
            .operation = "find_target_for_callers",
        };
        error_context.log_server_error(err, ctx_info);

        const error_msg = try std.fmt.allocPrint(ctx.allocator, "Target lookup failed: {}", .{err});
        defer ctx.allocator.free(error_msg);
        return try create_error_response(ctx, @intFromEnum(cli_protocol.ErrorCode.server_error), error_msg);
    };
    defer target_result.deinit();

    if (target_result.results.len == 0) {
        return try serialize_empty_show_response(ctx);
    }

    // Find callers using graph traversal
    const target_id = target_result.results[0].block.block.id;
    const callers = ctx.query_engine.find_callers("", target_id, request.max_depth) catch |err| {
        const ctx_info = error_context.ServerContext{
            .operation = "find_callers",
        };
        error_context.log_server_error(err, ctx_info);

        const error_msg = try std.fmt.allocPrint(ctx.allocator, "Caller query failed: {}", .{err});
        defer ctx.allocator.free(error_msg);
        return try create_error_response(ctx, @intFromEnum(cli_protocol.ErrorCode.server_error), error_msg);
    };
    defer callers.deinit();

    // Convert OwnedBlocks to ContextBlocks for response
    var context_blocks = std.array_list.Managed(ContextBlock).init(ctx.allocator);
    defer context_blocks.deinit();

    for (callers.blocks) |owned_block| {
        try context_blocks.append(owned_block.block);
    }

    return try serialize_show_response(ctx, context_blocks.items, &[_]GraphEdge{});
}

fn handle_show_callees_request(ctx: HandlerContext, payload: []const u8) ![]const u8 {
    if (payload.len != @sizeOf(cli_protocol.ShowRequest)) {
        return try create_error_response(
            ctx,
            @intFromEnum(cli_protocol.ErrorCode.invalid_request),
            "Invalid show request size",
        );
    }

    const request = @as(*const cli_protocol.ShowRequest, @ptrCast(@alignCast(payload.ptr))).*;
    const source_text = request.target_text();

    // Find source blocks first
    const source_result = ctx.query_engine.find_by_name("", "function", source_text) catch |err| {
        const ctx_info = error_context.ServerContext{
            .operation = "find_source_for_callees",
        };
        error_context.log_server_error(err, ctx_info);

        const error_msg = try std.fmt.allocPrint(ctx.allocator, "Source lookup failed: {}", .{err});
        defer ctx.allocator.free(error_msg);
        return try create_error_response(ctx, @intFromEnum(cli_protocol.ErrorCode.server_error), error_msg);
    };
    defer source_result.deinit();

    if (source_result.results.len == 0) {
        return try serialize_empty_show_response(ctx);
    }

    // Find callees using graph traversal
    const source_id = source_result.results[0].block.block.id;
    const callees = ctx.query_engine.find_callees("", source_id, request.max_depth) catch |err| {
        const ctx_info = error_context.ServerContext{
            .operation = "find_callees",
        };
        error_context.log_server_error(err, ctx_info);

        const error_msg = try std.fmt.allocPrint(ctx.allocator, "Callee query failed: {}", .{err});
        defer ctx.allocator.free(error_msg);
        return try create_error_response(ctx, @intFromEnum(cli_protocol.ErrorCode.server_error), error_msg);
    };
    defer callees.deinit();

    // Convert OwnedBlocks to ContextBlocks for response
    var context_blocks = std.array_list.Managed(ContextBlock).init(ctx.allocator);
    defer context_blocks.deinit();

    for (callees.blocks) |owned_block| {
        try context_blocks.append(owned_block.block);
    }

    return try serialize_show_response(ctx, context_blocks.items, &[_]GraphEdge{});
}

fn handle_trace_request(ctx: HandlerContext, payload: []const u8) ![]const u8 {
    if (payload.len != @sizeOf(cli_protocol.TraceRequest)) {
        return try create_error_response(
            ctx,
            @intFromEnum(cli_protocol.ErrorCode.invalid_request),
            "Invalid trace request size",
        );
    }

    const request = @as(*const cli_protocol.TraceRequest, @ptrCast(@alignCast(payload.ptr))).*;
    const source_text = request.source_text();
    const target_text = request.target_text();

    // Find source and target blocks
    const source_result = ctx.query_engine.find_by_name("", "function", source_text) catch |err| {
        const error_msg = try std.fmt.allocPrint(ctx.allocator, "Source lookup failed: {}", .{err});
        defer ctx.allocator.free(error_msg);
        return try create_error_response(ctx, @intFromEnum(cli_protocol.ErrorCode.server_error), error_msg);
    };
    defer source_result.deinit();

    const target_result = ctx.query_engine.find_by_name("", "function", target_text) catch |err| {
        const error_msg = try std.fmt.allocPrint(ctx.allocator, "Target lookup failed: {}", .{err});
        defer ctx.allocator.free(error_msg);
        return try create_error_response(ctx, @intFromEnum(cli_protocol.ErrorCode.server_error), error_msg);
    };
    defer target_result.deinit();

    if (source_result.results.len == 0 or target_result.results.len == 0) {
        return try serialize_empty_trace_response(ctx);
    }

    // Execute trace query
    const source_id = source_result.results[0].block.block.id;
    const target_id = target_result.results[0].block.block.id;

    // TODO: Implement path finding - for now return empty results
    _ = source_id;
    _ = target_id;
    _ = request.max_depth;

    return try serialize_empty_trace_response(ctx);
}

fn handle_link_request(ctx: HandlerContext, payload: []const u8) ![]const u8 {
    if (payload.len != @sizeOf(cli_protocol.LinkRequest)) {
        return try create_error_response(
            ctx,
            @intFromEnum(cli_protocol.ErrorCode.invalid_request),
            "Invalid link request size",
        );
    }

    const request = @as(*const cli_protocol.LinkRequest, @ptrCast(@alignCast(payload.ptr))).*;
    const path_text = request.path_text();
    const name_text = request.name_text();

    ctx.workspace_manager.link_codebase(path_text, name_text) catch |err| {
        const error_msg = try std.fmt.allocPrint(ctx.allocator, "Link operation failed: {}", .{err});
        defer ctx.allocator.free(error_msg);
        return try create_error_response(ctx, @intFromEnum(cli_protocol.ErrorCode.server_error), error_msg);
    };

    const success_msg = try std.fmt.allocPrint(ctx.allocator, "Successfully linked '{s}' as '{s}'", .{ path_text, name_text });
    defer ctx.allocator.free(success_msg);

    return try serialize_operation_response(ctx, true, success_msg);
}

fn handle_unlink_request(ctx: HandlerContext, payload: []const u8) ![]const u8 {
    if (payload.len != @sizeOf(cli_protocol.SyncRequest)) {
        return try create_error_response(
            ctx,
            @intFromEnum(cli_protocol.ErrorCode.invalid_request),
            "Invalid unlink request size",
        );
    }

    const request = @as(*const cli_protocol.SyncRequest, @ptrCast(@alignCast(payload.ptr))).*;
    const name_text = request.name_text();

    ctx.workspace_manager.unlink_codebase(name_text) catch |err| {
        const error_msg = try std.fmt.allocPrint(ctx.allocator, "Unlink operation failed: {}", .{err});
        defer ctx.allocator.free(error_msg);
        return try create_error_response(ctx, @intFromEnum(cli_protocol.ErrorCode.server_error), error_msg);
    };

    const success_msg = try std.fmt.allocPrint(ctx.allocator, "Successfully unlinked '{s}'", .{name_text});
    defer ctx.allocator.free(success_msg);

    return try serialize_operation_response(ctx, true, success_msg);
}

fn handle_sync_request(ctx: HandlerContext, payload: []const u8) ![]const u8 {
    if (payload.len != @sizeOf(cli_protocol.SyncRequest)) {
        return try create_error_response(
            ctx,
            @intFromEnum(cli_protocol.ErrorCode.invalid_request),
            "Invalid sync request size",
        );
    }

    const request = @as(*const cli_protocol.SyncRequest, @ptrCast(@alignCast(payload.ptr))).*;
    const name_text = request.name_text();

    ctx.workspace_manager.sync_codebase(name_text) catch |err| {
        const error_msg = try std.fmt.allocPrint(ctx.allocator, "Sync operation failed: {}", .{err});
        defer ctx.allocator.free(error_msg);
        return try create_error_response(ctx, @intFromEnum(cli_protocol.ErrorCode.server_error), error_msg);
    };

    const success_msg = try std.fmt.allocPrint(ctx.allocator, "Successfully synced codebase '{s}'", .{name_text});
    defer ctx.allocator.free(success_msg);

    return try serialize_operation_response(ctx, true, success_msg);
}

// === Response Serialization Helpers ===

fn serialize_find_response(ctx: HandlerContext, response: cli_protocol.FindResponse) ![]const u8 {
    const response_header = cli_protocol.MessageHeader{
        .message_type = .find_response,
        .payload_size = @sizeOf(cli_protocol.FindResponse),
    };

    const total_size = @sizeOf(cli_protocol.MessageHeader) + @sizeOf(cli_protocol.FindResponse);
    const response_bytes = try ctx.allocator.alloc(u8, total_size);

    @memcpy(response_bytes[0..@sizeOf(cli_protocol.MessageHeader)], std.mem.asBytes(&response_header));
    @memcpy(response_bytes[@sizeOf(cli_protocol.MessageHeader)..], std.mem.asBytes(&response));

    return response_bytes;
}

fn serialize_show_response(ctx: HandlerContext, blocks: []const ContextBlock, edges: []const GraphEdge) ![]const u8 {
    var response = cli_protocol.ShowResponse.init();

    for (blocks) |block| {
        if (response.block_count >= cli_protocol.MAX_BLOCKS_PER_RESPONSE) break;
        response.add_block(block);
    }

    for (edges) |edge| {
        if (response.edge_count >= cli_protocol.MAX_EDGES_PER_RESPONSE) break;
        response.add_edge(edge);
    }

    const response_header = cli_protocol.MessageHeader{
        .message_type = .show_response,
        .payload_size = @sizeOf(cli_protocol.ShowResponse),
    };

    const total_size = @sizeOf(cli_protocol.MessageHeader) + @sizeOf(cli_protocol.ShowResponse);
    const response_bytes = try ctx.allocator.alloc(u8, total_size);

    @memcpy(response_bytes[0..@sizeOf(cli_protocol.MessageHeader)], std.mem.asBytes(&response_header));
    @memcpy(response_bytes[@sizeOf(cli_protocol.MessageHeader)..], std.mem.asBytes(&response));

    return response_bytes;
}

fn serialize_empty_show_response(ctx: HandlerContext) ![]const u8 {
    const response = cli_protocol.ShowResponse.init();

    const response_header = cli_protocol.MessageHeader{
        .message_type = .show_response,
        .payload_size = @sizeOf(cli_protocol.ShowResponse),
    };

    const total_size = @sizeOf(cli_protocol.MessageHeader) + @sizeOf(cli_protocol.ShowResponse);
    const response_bytes = try ctx.allocator.alloc(u8, total_size);

    @memcpy(response_bytes[0..@sizeOf(cli_protocol.MessageHeader)], std.mem.asBytes(&response_header));
    @memcpy(response_bytes[@sizeOf(cli_protocol.MessageHeader)..], std.mem.asBytes(&response));

    return response_bytes;
}

// TODO: Fix QueryPath type - serialize_trace_response removed temporarily

fn serialize_empty_trace_response(ctx: HandlerContext) ![]const u8 {
    const response = cli_protocol.TraceResponse.init();

    const response_header = cli_protocol.MessageHeader{
        .message_type = .trace_response,
        .payload_size = @sizeOf(cli_protocol.TraceResponse),
    };

    const total_size = @sizeOf(cli_protocol.MessageHeader) + @sizeOf(cli_protocol.TraceResponse);
    const response_bytes = try ctx.allocator.alloc(u8, total_size);

    @memcpy(response_bytes[0..@sizeOf(cli_protocol.MessageHeader)], std.mem.asBytes(&response_header));
    @memcpy(response_bytes[@sizeOf(cli_protocol.MessageHeader)..], std.mem.asBytes(&response));

    return response_bytes;
}

fn serialize_operation_response(ctx: HandlerContext, success: bool, message: []const u8) ![]const u8 {
    const response = cli_protocol.OperationResponse.init(success, message);

    const response_header = cli_protocol.MessageHeader{
        .message_type = .operation_response,
        .payload_size = @sizeOf(cli_protocol.OperationResponse),
    };

    const total_size = @sizeOf(cli_protocol.MessageHeader) + @sizeOf(cli_protocol.OperationResponse);
    const response_bytes = try ctx.allocator.alloc(u8, total_size);

    @memcpy(response_bytes[0..@sizeOf(cli_protocol.MessageHeader)], std.mem.asBytes(&response_header));
    @memcpy(response_bytes[@sizeOf(cli_protocol.MessageHeader)..], std.mem.asBytes(&response));

    return response_bytes;
}

fn create_error_response(ctx: HandlerContext, error_code: u32, message: []const u8) ![]const u8 {
    const error_resp = cli_protocol.ErrorResponse.init(error_code, message);

    const response_header = cli_protocol.MessageHeader{
        .message_type = .error_response,
        .payload_size = @sizeOf(cli_protocol.ErrorResponse),
    };

    const total_size = @sizeOf(cli_protocol.MessageHeader) + @sizeOf(cli_protocol.ErrorResponse);
    const response_bytes = try ctx.allocator.alloc(u8, total_size);

    @memcpy(response_bytes[0..@sizeOf(cli_protocol.MessageHeader)], std.mem.asBytes(&response_header));
    @memcpy(response_bytes[@sizeOf(cli_protocol.MessageHeader)..], std.mem.asBytes(&error_resp));

    return response_bytes;
}
