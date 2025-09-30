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
const TraversalResult = query_engine.TraversalResult;
const WorkspaceManager = workspace_manager.WorkspaceManager;

const log = std.log.scoped(.cli_protocol);

/// CLI request handler context
pub const HandlerContext = struct {
    allocator: std.mem.Allocator,
    storage_engine: *StorageEngine,
    query_engine: *QueryEngine,
    workspace_manager: *WorkspaceManager,
    server_start_time: i64,

    pub fn init(
        allocator: std.mem.Allocator,
        storage_eng: *StorageEngine,
        query_eng: *QueryEngine,
        workspace_mgr: *WorkspaceManager,
        server_start_time: i64,
    ) HandlerContext {
        return HandlerContext{
            .allocator = allocator,
            .storage_engine = storage_eng,
            .query_engine = query_eng,
            .workspace_manager = workspace_mgr,
            .server_start_time = server_start_time,
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
        .clear_workspace_request => return try handle_clear_workspace_request(ctx, payload),
        else => return try create_error_response(
            ctx,
            @intFromEnum(cli_protocol.ErrorCode.unknown_command),
            "Unknown command",
        ),
    }
}

fn handle_ping_request(ctx: HandlerContext) ![]const u8 {
    const response_header = cli_protocol.MessageHeader{
        .magic = cli_protocol.PROTOCOL_MAGIC,
        .version = cli_protocol.PROTOCOL_VERSION,
        .message_type = .pong_response,
        .payload_size = 0,
    };

    const response_bytes = try ctx.allocator.alloc(u8, @sizeOf(cli_protocol.MessageHeader));
    @memcpy(response_bytes, std.mem.asBytes(&response_header));
    return response_bytes;
}

/// Determine workspace sync status based on codebase info
fn determine_workspace_sync_status(codebase_info: workspace_manager.CodebaseInfo) cli_protocol.WorkspaceSyncStatus {
    if (codebase_info.last_sync_timestamp == 0) {
        return .never_synced;
    }

    // One hour threshold balances responsiveness with avoiding excessive syncing
    // Longer periods would miss rapid development cycles, shorter would waste resources
    const sync_freshness_threshold = 3600; // 1 hour in seconds
    const current_time = std.time.timestamp();
    const elapsed_seconds = current_time - codebase_info.last_sync_timestamp;

    if (elapsed_seconds <= sync_freshness_threshold) {
        return .synced;
    } else {
        return .needs_sync;
    }
}

/// Calculate storage bytes used by a specific workspace
fn calculate_workspace_storage_bytes(ctx: HandlerContext, workspace_name: []const u8) !u64 {
    const codebase_info = ctx.workspace_manager.find_codebase_info(workspace_name) orelse return 0;

    // Size estimates based on KausalDB's LSM-Tree storage format
    // Context blocks average 2KB (typical function with metadata)
    // Graph edges average 64 bytes (two block IDs plus relationship metadata)
    const avg_context_block_bytes = 2048;
    const avg_graph_edge_bytes = 64;

    const block_bytes = @as(u64, codebase_info.block_count) * avg_context_block_bytes;
    const edge_bytes = @as(u64, codebase_info.edge_count) * avg_graph_edge_bytes;

    return block_bytes + edge_bytes;
}

fn handle_status_request(ctx: HandlerContext) ![]const u8 {
    const storage_stats = ctx.storage_engine.query_statistics();

    var status = cli_protocol.StatusResponse.init();
    status.block_count = storage_stats.total_blocks;
    status.edge_count = storage_stats.total_edges;
    status.sstable_count = @intCast(storage_stats.sstable_count);
    status.memtable_size = storage_stats.memtable_bytes;
    status.total_disk_usage = storage_stats.total_disk_bytes;
    const current_time = std.time.timestamp();
    status.uptime_seconds = @intCast(@max(0, current_time - ctx.server_start_time));

    const codebase_infos = ctx.workspace_manager.list_linked_codebases(ctx.allocator) catch |err| blk: {
        log.warn("Failed to get codebase list: {}", .{err});
        break :blk &[_]workspace_manager.CodebaseInfo{};
    };
    defer ctx.allocator.free(codebase_infos);

    for (codebase_infos[0..@min(codebase_infos.len, cli_protocol.MAX_WORKSPACES_PER_STATUS)]) |codebase_info| {
        const sync_status = determine_workspace_sync_status(codebase_info);
        const storage_bytes = calculate_workspace_storage_bytes(ctx, codebase_info.name) catch 0;

        const workspace_proto = cli_protocol.WorkspaceInfo.init_with_status(
            codebase_info.name,
            codebase_info.path,
            codebase_info.block_count,
            codebase_info.edge_count,
            codebase_info.last_sync_timestamp,
            sync_status,
            storage_bytes,
        );
        // Add assertions to catch corruption early
        const raw_sync_status = @intFromEnum(workspace_proto.sync_status);
        fatal_assert(raw_sync_status <= 3, "Invalid workspace sync_status: {}", .{raw_sync_status});

        log.debug("Server: Created workspace proto name='{s}' sync_status={}", .{ (&workspace_proto).name_text(), raw_sync_status });

        // Verify workspace data integrity before adding to status
        const name_before_add = (&workspace_proto).name_text();
        fatal_assert(name_before_add.len > 0, "Empty workspace name before add_workspace", .{});
        status.add_workspace(&workspace_proto);

        // Verify the workspace was added correctly and data is not corrupted
        const workspaces_after_add = (&status).workspaces_slice();
        if (workspaces_after_add.len > 0) {
            const last_workspace = &workspaces_after_add[workspaces_after_add.len - 1];
            const name_after_add = last_workspace.name_text();
            const sync_status_after_add = @intFromEnum(last_workspace.sync_status);

            fatal_assert(sync_status_after_add <= 3, "Corrupted workspace sync_status after add: {}", .{sync_status_after_add});
            fatal_assert(name_after_add.len > 0, "Corrupted workspace name after add: '{s}'", .{name_after_add});

            log.debug("Server: Verified workspace after add name='{s}' sync_status={}", .{ name_after_add, sync_status_after_add });
        }
    }

    // Final integrity check before serialization
    const final_workspaces = (&status).workspaces_slice();
    log.debug("Server: Final status has {} workspaces before serialization", .{final_workspaces.len});

    for (final_workspaces, 0..) |*workspace, i| {
        const name = workspace.name_text();
        const sync_status_raw = @intFromEnum(workspace.sync_status);

        fatal_assert(sync_status_raw <= 3, "Final check: corrupted sync_status in workspace {}: {}", .{ i, sync_status_raw });
        fatal_assert(name.len > 0, "Final check: empty name in workspace {}", .{i});

        log.debug("Server: Final workspace {} name='{s}' sync_status={}", .{ i, name, sync_status_raw });
    }

    const response_header = cli_protocol.MessageHeader{
        .magic = cli_protocol.PROTOCOL_MAGIC,
        .version = cli_protocol.PROTOCOL_VERSION,
        .message_type = .status_response,
        .payload_size = @sizeOf(cli_protocol.StatusResponse),
    };

    const total_size = @sizeOf(cli_protocol.MessageHeader) + @sizeOf(cli_protocol.StatusResponse);
    const response_bytes = try ctx.allocator.alloc(u8, total_size);

    @memcpy(response_bytes[0..@sizeOf(cli_protocol.MessageHeader)], std.mem.asBytes(&response_header));
    @memcpy(response_bytes[@sizeOf(cli_protocol.MessageHeader)..], std.mem.asBytes(&status));

    log.debug("Server: Serialized StatusResponse with {} bytes total", .{total_size});

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

    // Safety: Payload size validated against FindRequest struct size above
    const request = @as(*const cli_protocol.FindRequest, @ptrCast(@alignCast(payload.ptr)));
    const query_text = request.query_text();

    // Parse structured query (workspace:X type:Y name:Z)
    var workspace: []const u8 = "";
    var entity_type: []const u8 = "function";
    var name: []const u8 = query_text;

    // Simple parser for structured query
    var parts = std.mem.splitSequence(u8, query_text, " ");
    while (parts.next()) |part| {
        if (std.mem.startsWith(u8, part, "workspace:")) {
            workspace = part[10..];
        } else if (std.mem.startsWith(u8, part, "type:")) {
            entity_type = part[5..];
        } else if (std.mem.startsWith(u8, part, "name:")) {
            name = part[5..];
        }
    }

    // Debug logging to see what parameters we parsed
    log.debug("Find request: query_text='{s}', workspace='{s}', entity_type='{s}', name='{s}'", .{ query_text, workspace, entity_type, name });

    // Execute find query using parsed parameters
    const semantic_result = ctx.query_engine.find_by_name(workspace, entity_type, name) catch |err| {
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

    // Safety: Payload size validated against ShowRequest struct size above
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

    // Safety: Payload size validated against ShowRequest struct size above
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

    // Safety: Payload size validated against TraceRequest struct size above
    const request = @as(*const cli_protocol.TraceRequest, @ptrCast(@alignCast(payload.ptr))).*;
    const source_text = request.source_text();
    const target_text = request.target_text();

    // Determine the actual entity to trace based on which field is non-empty
    const entity_name = if (source_text.len > 0) source_text else target_text;
    const is_callees_trace = source_text.len > 0; // source non-empty means finding callees

    if (entity_name.len == 0) {
        return try create_error_response(
            ctx,
            @intFromEnum(cli_protocol.ErrorCode.invalid_request),
            "Either source or target must be specified",
        );
    }

    // Find the entity to trace from
    const entity_result = ctx.query_engine.find_by_name("", "function", entity_name) catch |err| {
        const error_msg = try std.fmt.allocPrint(ctx.allocator, "Entity lookup failed: {}", .{err});
        defer ctx.allocator.free(error_msg);
        return try create_error_response(ctx, @intFromEnum(cli_protocol.ErrorCode.server_error), error_msg);
    };
    defer entity_result.deinit();

    if (entity_result.results.len == 0) {
        return try serialize_empty_trace_response(ctx);
    }

    // Execute trace query using appropriate direction
    const entity_id = entity_result.results[0].block.block.id;
    const trace_result = if (is_callees_trace)
        ctx.query_engine.find_callees("", entity_id, request.max_depth)
    else
        ctx.query_engine.find_callers("", entity_id, request.max_depth);

    const path_result = trace_result catch |err| {
        const ctx_info = error_context.ServerContext{
            .operation = if (is_callees_trace) "find_callees" else "find_callers",
        };
        error_context.log_server_error(err, ctx_info);
        return try serialize_empty_trace_response(ctx);
    };

    return try serialize_trace_response_from_blocks(ctx, path_result.blocks);
}

fn handle_link_request(ctx: HandlerContext, payload: []const u8) ![]const u8 {
    if (payload.len != @sizeOf(cli_protocol.LinkRequest)) {
        return try create_error_response(
            ctx,
            @intFromEnum(cli_protocol.ErrorCode.invalid_request),
            "Invalid link request size",
        );
    }

    // Safety: Payload size validated against LinkRequest struct size above
    const request = @as(*const cli_protocol.LinkRequest, @ptrCast(@alignCast(payload.ptr))).*;
    const path_text = request.path_text();
    const name_text = request.name_text();

    ctx.workspace_manager.link_codebase(path_text, name_text) catch |err| {
        const error_msg = try std.fmt.allocPrint(ctx.allocator, "Link operation failed: {}", .{err});
        defer ctx.allocator.free(error_msg);
        return try create_error_response(ctx, @intFromEnum(cli_protocol.ErrorCode.server_error), error_msg);
    };

    const success_msg = try std.fmt.allocPrint(
        ctx.allocator,
        "Successfully linked '{s}' as '{s}'",
        .{ path_text, name_text },
    );
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

    // Safety: Payload size validated against SyncRequest struct size above
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

    // Safety: Payload size validated against SyncRequest struct size above
    const request = @as(*const cli_protocol.SyncRequest, @ptrCast(@alignCast(payload.ptr))).*;
    const name_text = request.name_text();

    if (std.mem.eql(u8, name_text, "--all")) {
        // Sync all linked codebases
        const linked_codebases = ctx.workspace_manager.list_linked_codebases(ctx.allocator) catch |err| {
            const error_msg = try std.fmt.allocPrint(ctx.allocator, "Failed to list codebases: {}", .{err});
            defer ctx.allocator.free(error_msg);
            return try create_error_response(ctx, @intFromEnum(cli_protocol.ErrorCode.server_error), error_msg);
        };
        defer ctx.allocator.free(linked_codebases);

        if (linked_codebases.len == 0) {
            return try create_error_response(
                ctx,
                @intFromEnum(cli_protocol.ErrorCode.server_error),
                "No linked codebases to sync",
            );
        }

        var sync_count: u32 = 0;
        for (linked_codebases) |codebase_info| {
            ctx.workspace_manager.sync_codebase(codebase_info.name) catch |err| {
                const error_msg = try std.fmt.allocPrint(
                    ctx.allocator,
                    "Sync operation failed for codebase '{s}': {}",
                    .{ codebase_info.name, err },
                );
                defer ctx.allocator.free(error_msg);
                return try create_error_response(ctx, @intFromEnum(cli_protocol.ErrorCode.server_error), error_msg);
            };
            sync_count += 1;
        }

        const success_msg = try std.fmt.allocPrint(ctx.allocator, "Successfully synced {d} codebases", .{sync_count});
        defer ctx.allocator.free(success_msg);
        return try serialize_operation_response(ctx, true, success_msg);
    } else {
        // Sync single codebase
        ctx.workspace_manager.sync_codebase(name_text) catch |err| {
            const error_msg = try std.fmt.allocPrint(ctx.allocator, "Sync operation failed: {}", .{err});
            defer ctx.allocator.free(error_msg);
            return try create_error_response(ctx, @intFromEnum(cli_protocol.ErrorCode.server_error), error_msg);
        };

        const success_msg = try std.fmt.allocPrint(ctx.allocator, "Successfully synced codebase '{s}'", .{name_text});
        defer ctx.allocator.free(success_msg);
        return try serialize_operation_response(ctx, true, success_msg);
    }
}

fn handle_clear_workspace_request(ctx: HandlerContext, payload: []const u8) ![]const u8 {
    if (payload.len != 0) {
        return try create_error_response(
            ctx,
            @intFromEnum(cli_protocol.ErrorCode.invalid_request),
            "Clear workspace request should have empty payload",
        );
    }

    ctx.workspace_manager.clear_all_linked_codebases() catch |err| {
        const error_msg = try std.fmt.allocPrint(ctx.allocator, "Clear workspace operation failed: {}", .{err});
        defer ctx.allocator.free(error_msg);
        return try create_error_response(ctx, @intFromEnum(cli_protocol.ErrorCode.server_error), error_msg);
    };

    const success_msg = "Successfully cleared all linked codebases from workspace";
    return try serialize_operation_response(ctx, true, success_msg);
}

fn serialize_find_response(ctx: HandlerContext, response: cli_protocol.FindResponse) ![]const u8 {
    const response_header = cli_protocol.MessageHeader{
        .magic = cli_protocol.PROTOCOL_MAGIC,
        .version = cli_protocol.PROTOCOL_VERSION,
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
    const total_size = @sizeOf(cli_protocol.MessageHeader) + @sizeOf(cli_protocol.ShowResponse);
    const response_bytes = try ctx.allocator.alloc(u8, total_size);

    // 1. Write header
    const response_header = cli_protocol.MessageHeader{
        .magic = cli_protocol.PROTOCOL_MAGIC,
        .version = cli_protocol.PROTOCOL_VERSION,
        .message_type = .show_response,
        .payload_size = @sizeOf(cli_protocol.ShowResponse),
    };
    @memcpy(response_bytes[0..@sizeOf(cli_protocol.MessageHeader)], std.mem.asBytes(&response_header));

    // 2. Zero out the response payload section
    @memset(response_bytes[@sizeOf(cli_protocol.MessageHeader)..], 0);

    // 3. Cast to struct pointer and populate directly
    // Safety: response_bytes is correctly sized and aligned for ShowResponse struct
    const response_ptr: *cli_protocol.ShowResponse = @ptrCast(@alignCast(&response_bytes[@sizeOf(cli_protocol.MessageHeader)]));

    // 4. Populate fields
    for (blocks, 0..) |block, i| {
        if (i >= cli_protocol.MAX_BLOCKS_PER_RESPONSE) break;
        response_ptr.add_block(block);
    }

    for (edges, 0..) |edge, i| {
        if (i >= cli_protocol.MAX_EDGES_PER_RESPONSE) break;
        response_ptr.add_edge(edge);
    }

    return response_bytes;
}

fn serialize_empty_show_response(ctx: HandlerContext) ![]const u8 {
    const total_size = @sizeOf(cli_protocol.MessageHeader) + @sizeOf(cli_protocol.ShowResponse);
    const response_bytes = try ctx.allocator.alloc(u8, total_size);

    // Write header
    const response_header = cli_protocol.MessageHeader{
        .magic = cli_protocol.PROTOCOL_MAGIC,
        .version = cli_protocol.PROTOCOL_VERSION,
        .message_type = .show_response,
        .payload_size = @sizeOf(cli_protocol.ShowResponse),
    };
    @memcpy(response_bytes[0..@sizeOf(cli_protocol.MessageHeader)], std.mem.asBytes(&response_header));

    // Zero out payload (empty response)
    @memset(response_bytes[@sizeOf(cli_protocol.MessageHeader)..], 0);

    return response_bytes;
}

fn serialize_trace_response_from_blocks(ctx: HandlerContext, blocks: []const OwnedBlock) ![]const u8 {
    var response = cli_protocol.TraceResponse.init();

    if (blocks.len > 0) {
        // Create a single path from the blocks
        response.path_count = 1;
        const node_count = @min(blocks.len, response.paths[0].nodes.len);
        response.paths[0].node_count = @intCast(node_count);
        response.paths[0].total_distance = @intCast(node_count);

        for (blocks[0..node_count], 0..) |owned_block, i| {
            response.paths[0].nodes[i] = owned_block.block.id;
        }
    }

    const response_header = cli_protocol.MessageHeader{
        .version = cli_protocol.PROTOCOL_VERSION,
        .message_type = cli_protocol.MessageType.trace_response,
        .payload_size = @intCast(@sizeOf(cli_protocol.TraceResponse)),
        .magic = cli_protocol.PROTOCOL_MAGIC,
    };

    const total_size = @sizeOf(cli_protocol.MessageHeader) + @sizeOf(cli_protocol.TraceResponse);
    const response_bytes = try ctx.allocator.alloc(u8, total_size);

    @memcpy(response_bytes[0..@sizeOf(cli_protocol.MessageHeader)], std.mem.asBytes(&response_header));
    @memcpy(response_bytes[@sizeOf(cli_protocol.MessageHeader)..], std.mem.asBytes(&response));

    return response_bytes;
}

fn serialize_trace_response(ctx: HandlerContext, path_result: TraversalResult) ![]const u8 {
    var response = cli_protocol.TraceResponse.init();

    // Convert TraversalResult paths to TracePath structures
    const path_count = @min(path_result.paths.len, response.paths.len);
    response.path_count = @intCast(path_count);

    for (path_result.paths[0..path_count], 0..) |path, i| {
        const node_count = @min(path.len, response.paths[i].nodes.len);
        response.paths[i].node_count = @intCast(node_count);
        response.paths[i].total_distance = @intCast(path.len - 1); // Distance is path length minus 1

        @memcpy(response.paths[i].nodes[0..node_count], path[0..node_count]);
    }

    const response_header = cli_protocol.MessageHeader{
        .version = cli_protocol.PROTOCOL_VERSION,
        .message_type = cli_protocol.MessageType.trace_response,
        .payload_size = @intCast(@sizeOf(cli_protocol.TraceResponse)),
        .magic = cli_protocol.PROTOCOL_MAGIC,
    };

    const total_size = @sizeOf(cli_protocol.MessageHeader) + @sizeOf(cli_protocol.TraceResponse);
    const response_bytes = try ctx.allocator.alloc(u8, total_size);

    @memcpy(response_bytes[0..@sizeOf(cli_protocol.MessageHeader)], std.mem.asBytes(&response_header));
    @memcpy(response_bytes[@sizeOf(cli_protocol.MessageHeader)..], std.mem.asBytes(&response));

    return response_bytes;
}

fn serialize_empty_trace_response(ctx: HandlerContext) ![]const u8 {
    const response = cli_protocol.TraceResponse.init();

    const response_header = cli_protocol.MessageHeader{
        .version = cli_protocol.PROTOCOL_VERSION,
        .message_type = cli_protocol.MessageType.trace_response,
        .payload_size = @intCast(@sizeOf(cli_protocol.TraceResponse)),
        .magic = cli_protocol.PROTOCOL_MAGIC,
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
        .magic = cli_protocol.PROTOCOL_MAGIC,
        .version = cli_protocol.PROTOCOL_VERSION,
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
        .magic = cli_protocol.PROTOCOL_MAGIC,
        .version = cli_protocol.PROTOCOL_VERSION,
        .message_type = .error_response,
        .payload_size = @sizeOf(cli_protocol.ErrorResponse),
    };

    const total_size = @sizeOf(cli_protocol.MessageHeader) + @sizeOf(cli_protocol.ErrorResponse);
    const response_bytes = try ctx.allocator.alloc(u8, total_size);

    @memcpy(response_bytes[0..@sizeOf(cli_protocol.MessageHeader)], std.mem.asBytes(&response_header));
    @memcpy(response_bytes[@sizeOf(cli_protocol.MessageHeader)..], std.mem.asBytes(&error_resp));

    return response_bytes;
}
