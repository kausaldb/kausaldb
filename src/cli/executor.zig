//! Command executor for KausalDB CLI.
//!
//! Executes parsed commands using workspace management and query APIs.
//! Separates command parsing from execution for better testability.

const std = @import("std");

const assert_mod = @import("../core/assert.zig");
const error_context = @import("../core/error_context.zig");
const memory = @import("../core/memory.zig");
const commands = @import("commands.zig");
const output = @import("output.zig");
const production_vfs = @import("../core/production_vfs.zig");
const query_engine = @import("../query/engine.zig");
const signals = @import("../core/signals.zig");
const server = @import("../server/handler.zig");
const storage = @import("../storage/engine.zig");
const vfs = @import("../core/vfs.zig");
const workspace_manager = @import("../workspace/manager.zig");

const assert = assert_mod.assert;
const fatal_assert = assert_mod.fatal_assert;
const ArenaCoordinator = memory.ArenaCoordinator;
const types = @import("../core/types.zig");
const ContextBlock = types.ContextBlock;
const Command = commands.Command;
const OutputFormat = commands.OutputFormat;
const ProductionVFS = production_vfs.ProductionVFS;
const QueryEngine = query_engine.QueryEngine;
const StorageEngine = storage.StorageEngine;
const VFS = vfs.VFS;
const WorkspaceManager = workspace_manager.WorkspaceManager;

/// Execution context for CLI commands
pub const ExecutionContext = struct {
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    vfs: VFS,
    coordinator: *ArenaCoordinator,

    // Optional subsystems - initialized on demand
    storage_engine: ?*StorageEngine,
    query_engine: ?*QueryEngine,
    workspace_manager: ?*WorkspaceManager,

    pub fn init(allocator: std.mem.Allocator, data_dir: []const u8) !ExecutionContext {
        var prod_vfs = try allocator.create(ProductionVFS);
        prod_vfs.* = ProductionVFS.init(allocator);

        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);

        const coordinator = try allocator.create(ArenaCoordinator);
        coordinator.* = ArenaCoordinator.init(arena);

        // Ensure data directory exists and resolve to absolute path
        const absolute_data_dir = if (std.fs.path.isAbsolute(data_dir)) blk: {
            std.fs.makeDirAbsolute(data_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {}, // Directory already exists, continue
                else => return err,
            };
            break :blk try allocator.dupe(u8, data_dir);
        } else blk: {
            std.fs.cwd().makeDir(data_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {}, // Directory already exists, continue
                else => return err,
            };
            break :blk try std.fs.cwd().realpathAlloc(allocator, data_dir);
        };

        return ExecutionContext{
            .allocator = allocator,
            .data_dir = absolute_data_dir,
            .vfs = prod_vfs.vfs(),
            .coordinator = coordinator,
            .storage_engine = null,
            .query_engine = null,
            .workspace_manager = null,
        };
    }

    pub fn deinit(self: *ExecutionContext) void {
        if (self.workspace_manager) |wm| {
            wm.shutdown();
            wm.deinit();
            self.allocator.destroy(wm);
        }

        if (self.query_engine) |qe| {
            qe.shutdown();
            qe.deinit();
            self.allocator.destroy(qe);
        }

        if (self.storage_engine) |se| {
            se.shutdown() catch {};
            se.deinit();
            self.allocator.destroy(se);
        }

        // Clean up VFS - get the actual ProductionVFS instance to destroy
        // Safety: Pointer cast with alignment validation
        const prod_vfs: *ProductionVFS = @ptrCast(@alignCast(self.vfs.ptr));
        self.allocator.destroy(prod_vfs);

        self.coordinator.arena.deinit();
        self.allocator.destroy(self.coordinator.arena);
        self.allocator.destroy(self.coordinator);

        // Free the allocated data directory path
        self.allocator.free(self.data_dir);
    }

    /// Generate default workspace name based on current working directory.
    /// Always returns "default" to avoid memory management complexity.
    fn infer_workspace_name(self: *ExecutionContext) []const u8 {
        // Only try to get workspace info if workspace manager is already initialized
        // to avoid expensive I/O operations during workspace name inference
        if (self.workspace_manager) |wm| {
            const codebases = wm.list_linked_codebases(self.allocator) catch return "default";
            defer self.allocator.free(codebases);

            if (codebases.len == 1) {
                // If there's exactly one codebase, use it as the default workspace
                return codebases[0].name;
            } else if (codebases.len > 1) {
                // If there are multiple codebases, we should require explicit specification
                // but for backwards compatibility, return the first one
                return codebases[0].name;
            }
        }

        return "default";
    }

    fn ensure_storage_initialized(self: *ExecutionContext) !void {
        if (self.storage_engine != null) return;

        // Ensure data directory exists
        self.vfs.mkdir_all(self.data_dir) catch |err| switch (err) {
            vfs.VFSError.FileExists => {}, // Directory already exists
            else => return err,
        };

        const engine = try self.allocator.create(StorageEngine);
        engine.* = try StorageEngine.init_default(self.allocator, self.vfs, self.data_dir);
        try engine.startup();
        self.storage_engine = engine;
    }

    fn ensure_query_initialized(self: *ExecutionContext) !void {
        try self.ensure_storage_initialized();
        if (self.query_engine != null) return;

        const engine = try self.allocator.create(QueryEngine);
        engine.* = QueryEngine.init(self.allocator, self.storage_engine.?);
        engine.startup();
        self.query_engine = engine;
    }

    fn ensure_workspace_initialized(self: *ExecutionContext) !void {
        try self.ensure_storage_initialized();
        if (self.workspace_manager != null) return;

        const manager = try self.allocator.create(WorkspaceManager);
        manager.* = try WorkspaceManager.init(self.allocator, self.storage_engine.?);
        try manager.startup();
        self.workspace_manager = manager;
    }
};

/// Execute a CLI command
pub fn execute_command(
    context: *ExecutionContext,
    command: Command,
) !void {
    switch (command) {
        .version => execute_version_command(),
        .help => |cmd| execute_help_command(cmd),
        .link => |cmd| try execute_link_command(context, cmd),
        .unlink => |cmd| try execute_unlink_command(context, cmd),
        .sync => |cmd| try execute_sync_command(context, cmd),
        .status => |cmd| try execute_status_command(context, cmd),
        .find => |cmd| try execute_find_command(context, cmd),
        .show => |cmd| try execute_show_command(context, cmd),
        .trace => |cmd| try execute_trace_command(context, cmd),
        .server => |cmd| try execute_server_command(context, cmd),
    }
}

// === CLI Compaction Management ===

/// Proactively manage L0 SSTable pressure to prevent WriteBlocked errors in CLI context.
///
/// CLI operations are single-threaded and lack background compaction, so we must
/// aggressively compact L0 SSTables before hitting hard limits. This prevents
/// the need to disable fatal assertions, maintaining KausalDB's defensive programming philosophy.
fn ensure_cli_compaction_headroom(storage_engine: *StorageEngine) !void {
    // Check current L0 SSTable count and trigger compaction if approaching limits
    const throttle_status = storage_engine.sstable_manager.compaction_manager.query_throttle_status();
    const l0_count = throttle_status.l0_sstable_count;
    const l0_soft_threshold = 6; // Start compaction at 50% of hard limit (12)

    if (l0_count >= l0_soft_threshold) {
        // Force L0 compaction to reduce SSTable pressure
        storage_engine.sstable_manager.execute_compaction() catch |err| {
            error_context.log_storage_error(err, error_context.StorageContext{ .operation = "cli_proactive_compaction" });
            return err;
        };
    }
}

// === Command Implementations ===

fn execute_version_command() void {
    output.print_version("v0.1.0");
}

fn execute_help_command(cmd: Command.HelpCommand) void {
    if (cmd.topic) |topic| {
        show_command_help(topic);
    } else {
        show_general_help();
    }
}

fn execute_link_command(context: *ExecutionContext, cmd: Command.LinkCommand) !void {
    try context.ensure_workspace_initialized();
    const workspace = context.workspace_manager.?;

    // Resolve path to absolute path for consistent storage
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const resolved_path = std.fs.cwd().realpath(cmd.path, &path_buffer) catch |err| switch (err) {
        error.FileNotFound => {
            if (cmd.format == .json) {
                output.print_json_error(context.allocator, "Path '{s}' does not exist", .{cmd.path});
            } else {
                output.print_error(context.allocator, "Path '{s}' does not exist", .{cmd.path});
            }
            return error.FileNotFound;
        },
        else => return err,
    };

    // Proactively manage L0 compaction to prevent WriteBlocked errors during ingestion
    try ensure_cli_compaction_headroom(context.storage_engine.?);

    workspace.link_codebase(resolved_path, cmd.name) catch |err| switch (err) {
        workspace_manager.WorkspaceError.CodebaseAlreadyLinked => {
            if (cmd.format == .json) {
                output.print_json_error(context.allocator, "Codebase is already linked. Use 'kausaldb unlink {s}' first if you want to re-link it.", .{std.fs.path.basename(resolved_path)});
            } else {
                output.print_error(context.allocator, "Codebase is already linked. Use 'kausaldb unlink {s}' first if you want to re-link it.", .{std.fs.path.basename(resolved_path)});
            }
            return error.CodebaseAlreadyLinked;
        },
        workspace_manager.WorkspaceError.InvalidCodebasePath => {
            if (cmd.format == .json) {
                output.print_json_error(context.allocator, "Invalid codebase path '{s}'", .{resolved_path});
            } else {
                output.print_error(context.allocator, "Invalid codebase path '{s}'", .{resolved_path});
            }
            return error.InvalidCodebasePath;
        },
        storage.StorageError.WriteBlocked => {
            // Force aggressive L0 compaction to reduce SSTable count below hard limit
            context.storage_engine.?.sstable_manager.execute_compaction() catch |compact_err| {
                if (cmd.format == .json) {
                    output.print_json_error(context.allocator, "Storage write blocked and L0 compaction failed", .{});
                } else {
                    output.print_error(context.allocator, "Storage write blocked and L0 compaction failed: {}", .{compact_err});
                }
                return compact_err;
            };
            // Retry the link operation after L0 compaction
            return execute_link_command(context, cmd);
        },
        else => {
            if (cmd.format == .json) {
                output.print_json_error(context.allocator, "Failed to link codebase. Storage error occurred.", .{});
            } else {
                output.print_error(context.allocator, "Failed to link codebase '{s}'. This may be due to a storage issue. Please try again.", .{resolved_path});
            }
            return err;
        },
    };

    const actual_name = cmd.name orelse std.fs.path.basename(resolved_path);

    if (cmd.format == .json) {
        output.print_json_formatted(context.allocator,
            \\{{"status": "linked", "name": "{s}", "path": "{s}"}}
        , .{ actual_name, resolved_path });
        output.write_stdout("\n");
    } else {
        output.print_success(context.allocator, "Linked codebase '{s}' from {s}", .{ actual_name, resolved_path });
        // Note: "Indexing in progress..." removed as it's not actionable
    }
}

fn execute_unlink_command(context: *ExecutionContext, cmd: Command.UnlinkCommand) !void {
    try context.ensure_workspace_initialized();
    const workspace = context.workspace_manager.?;

    workspace.unlink_codebase(cmd.name) catch |err| switch (err) {
        workspace_manager.WorkspaceError.CodebaseNotFound => {
            if (cmd.format == .json) {
                output.print_json_error(context.allocator, "Codebase '{s}' not found", .{cmd.name});
            } else {
                output.print_error(context.allocator, "Codebase '{s}' not found. Use 'kausaldb workspace' to see linked codebases.", .{cmd.name});
            }
            return error.CodebaseNotFound;
        },
        storage.StorageError.WriteBlocked => {
            // Force aggressive L0 compaction to reduce SSTable count below hard limit
            context.storage_engine.?.sstable_manager.execute_compaction() catch |compact_err| {
                if (cmd.format == .json) {
                    output.print_json_error(context.allocator, "Storage write blocked and L0 compaction failed", .{});
                } else {
                    output.print_error(context.allocator, "Storage write blocked and L0 compaction failed: {}", .{compact_err});
                }
                return compact_err;
            };
            // Retry the unlink operation after L0 compaction
            return execute_unlink_command(context, cmd);
        },
        else => {
            if (cmd.format == .json) {
                output.print_json_error(context.allocator, "Failed to unlink codebase '{s}'. Storage error occurred.", .{cmd.name});
            } else {
                output.print_error(context.allocator, "Failed to unlink codebase '{s}'. This may be due to a storage issue. Please try again.", .{cmd.name});
            }
            return err;
        },
    };

    if (cmd.format == .json) {
        output.print_json_formatted(context.allocator,
            \\{{"status": "unlinked", "name": "{s}"}}
        , .{cmd.name});
        output.write_stdout("\n");
    } else {
        output.print_success(context.allocator, "Unlinked codebase '{s}'", .{cmd.name});
    }
}

fn execute_sync_command(context: *ExecutionContext, cmd: Command.SyncCommand) !void {
    try context.ensure_workspace_initialized();
    const workspace = context.workspace_manager.?;

    // Proactively manage L0 compaction to prevent WriteBlocked errors during sync operations
    try ensure_cli_compaction_headroom(context.storage_engine.?);

    if (cmd.all) {
        // Sync all codebases
        const codebases = try workspace.list_linked_codebases(context.allocator);
        defer context.allocator.free(codebases);

        if (cmd.format == .json) {
            output.write_stdout("[\n");
            for (codebases, 0..) |codebase_info, i| {
                try workspace.sync_codebase(codebase_info.name);
                output.print_json_stdout(context.allocator,
                    \\  {{"status": "synced", "name": "{s}"}}
                , .{codebase_info.name});
                if (i < codebases.len - 1) output.write_stdout(",");
                output.write_stdout("\n");
            }
            output.write_stdout("]\n");
        } else {
            output.print_stdout(context.allocator, "Syncing {} codebases...\n", .{codebases.len});
            for (codebases) |codebase_info| {
                try workspace.sync_codebase(codebase_info.name);
                output.print_success(context.allocator, "Synced '{s}'", .{codebase_info.name});
            }
        }
    } else if (cmd.name) |name| {
        // Sync specific codebase
        workspace.sync_codebase(name) catch |err| switch (err) {
            workspace_manager.WorkspaceError.CodebaseNotFound => {
                if (cmd.format == .json) {
                    output.print_json_error(context.allocator, "Codebase '{s}' not found", .{name});
                } else {
                    output.print_error(context.allocator, "Codebase '{s}' not found", .{name});
                }
                return;
            },
            else => return err,
        };

        if (cmd.format == .json) {
            output.print_json_formatted(context.allocator,
                \\{{"status": "synced", "name": "{s}"}}
            , .{name});
            output.write_stdout("\n");
        } else {
            output.print_success(context.allocator, "Synced codebase '{s}'", .{name});
        }
    } else {
        // Sync current directory - detect codebase by path
        const cwd = try std.fs.cwd().realpathAlloc(context.allocator, ".");
        defer context.allocator.free(cwd);

        // Find codebase by path
        const codebases = try workspace.list_linked_codebases(context.allocator);
        defer context.allocator.free(codebases);

        var found_codebase: ?[]const u8 = null;
        for (codebases) |codebase_info| {
            if (std.mem.startsWith(u8, cwd, codebase_info.path)) {
                found_codebase = codebase_info.name;
                break;
            }
        }

        if (found_codebase) |name| {
            try workspace.sync_codebase(name);
            if (cmd.format == .json) {
                output.print_json_formatted(context.allocator,
                    \\{{"status": "synced", "name": "{s}"}}
                , .{name});
                output.write_stdout("\n");
            } else {
                output.print_success(context.allocator, "Synced codebase '{s}'", .{name});
            }
        } else {
            if (cmd.format == .json) {
                output.print_json_error(context.allocator, "No linked codebase found for current directory", .{});
            } else {
                output.write_stdout("No linked codebase found for current directory\nUse 'kausal link .' to link this directory\n");
            }
        }
    }
}

fn execute_status_command(context: *ExecutionContext, cmd: Command.StatusCommand) !void {
    try context.ensure_workspace_initialized();
    const workspace = context.workspace_manager.?;

    const codebases = try workspace.list_linked_codebases(context.allocator);
    defer context.allocator.free(codebases);

    if (cmd.format == .json) {
        output.write_stdout("{\n");
        output.write_stdout("  \"workspace\": [\n");
        for (codebases, 0..) |codebase_info, i| {
            output.print_json_formatted(context.allocator,
                \\    {{"name": "{s}", "path": "{s}", "blocks": {}, "edges": {}}}
            , .{ codebase_info.name, codebase_info.path, codebase_info.block_count, codebase_info.edge_count });
            if (i < codebases.len - 1) output.write_stdout(",");
            output.write_stdout("\n");
        }
        output.write_stdout("  ]\n}\n");
    } else {
        output.print_workspace_header();
        if (codebases.len == 0) {
            output.print_empty_workspace(context.allocator);
        } else {
            for (codebases) |codebase_info| {
                const minutes_ago = @as(u64, @intCast(std.time.timestamp() - codebase_info.last_sync_timestamp)) / 60;
                const last_sync = if (minutes_ago == 0)
                    "Just now"
                else if (minutes_ago == 1)
                    "1 minute ago"
                else
                    try std.fmt.allocPrint(context.allocator, "{} minutes ago", .{minutes_ago});

                defer if (minutes_ago > 1) context.allocator.free(last_sync);

                output.print_workspace_status(context.allocator, codebase_info.name, codebase_info.path, codebase_info.block_count, codebase_info.edge_count, last_sync);
            }
        }
    }
}

fn execute_server_command(context: *ExecutionContext, cmd: Command.ServerCommand) !void {
    // Server mode requires storage engine initialization
    try context.ensure_storage_initialized();

    const port = cmd.port orelse 8080;
    const host = cmd.host orelse "127.0.0.1";

    output.print_stdout(context.allocator, "Starting KausalDB server on {s}:{}\n", .{ host, port });
    output.print_stdout(context.allocator, "Data directory: {s}\n", .{cmd.data_dir orelse context.data_dir});

    // Server implementation placeholder for v0.2.0
    // Network server with HTTP/gRPC interface planned for next release
    output.write_stdout("Server mode not yet implemented\n");
    output.write_stdout("This is a placeholder for the upcoming network server functionality\n");
}

fn execute_find_command(context: *ExecutionContext, cmd: Command.FindCommand) !void {
    try context.ensure_query_initialized();
    const query_eng = context.query_engine.?;

    // Entity type validation prevents unsupported queries from reaching storage
    if (!commands.validate_entity_type(cmd.entity_type)) {
        if (cmd.format == .json) {
            output.print_json_error(context.allocator, "Invalid entity type '{s}'", .{cmd.entity_type});
        } else {
            output.print_error(context.allocator, "Invalid entity type '{s}'. Valid types: function, struct, test, method, const, var, type, import", .{cmd.entity_type});
        }
        return;
    }

    // Determine workspace: use explicit workspace or infer from linked codebases
    const workspace = cmd.workspace orelse blk: {
        // Initialize workspace manager to get actual linked codebases
        try context.ensure_workspace_initialized();

        if (context.workspace_manager) |wm| {
            const codebases = wm.list_linked_codebases(context.allocator) catch break :blk "default";
            defer context.allocator.free(codebases);

            if (codebases.len >= 1) {
                // Use the first linked codebase as default workspace
                break :blk codebases[0].name;
            }
        }
        break :blk "default";
    };

    const search_result = query_eng.find_by_name(workspace, cmd.entity_type, cmd.name) catch |err| switch (err) {
        query_engine.QueryError.SemanticSearchUnavailable => {
            if (cmd.format == .json) {
                output.print_json_error(context.allocator, "Semantic search not available", .{});
            } else {
                output.write_stdout("Semantic search is not available yet.\nMake sure codebases are linked and synced.\n");
            }
            return;
        },
        else => return err,
    };
    defer search_result.deinit();

    if (cmd.format == .json) {
        output.write_stdout("{\n");
        output.print_stdout(context.allocator, "  \"query\": {{\"type\": \"{s}\", \"name\": \"{s}\", \"workspace\": \"{s}\"}},\n", .{ cmd.entity_type, cmd.name, workspace });
        output.print_stdout(context.allocator, "  \"total_matches\": {},\n", .{search_result.total_matches});
        output.write_stdout("  \"results\": [\n");
        for (search_result.results, 0..) |result, i| {
            const block = result.block.block;
            const block_id_hex = try block.id.to_hex(context.allocator);
            defer context.allocator.free(block_id_hex);
            output.print_json_stdout(context.allocator,
                \\    {{"name": "{s}", "id": "{s}", "source": "{s}", "similarity": {d:.3}}}
            , .{ extract_entity_name(block), block_id_hex, block.source_uri, result.similarity_score });
            if (i < search_result.results.len - 1) output.write_stdout(",");
            output.write_stdout("\n");
        }
        output.write_stdout("  ]\n}\n");
    } else {
        if (search_result.total_matches == 0) {
            output.print_stdout(context.allocator, "No {s} named '{s}' found", .{ cmd.entity_type, cmd.name });
            if (cmd.workspace) |ws| {
                output.print_stdout(context.allocator, " in workspace '{s}'", .{ws});
            }
            output.write_stdout(".\n");
        } else {
            // Success message with checkmark
            const workspace_part = if (cmd.workspace) |ws| 
                try std.fmt.allocPrint(context.allocator, " in workspace '{s}'", .{ws})
            else 
                try context.allocator.dupe(u8, "");
            defer context.allocator.free(workspace_part);
            
            output.print_success(context.allocator, "Found {} {s} named '{s}'{s}", .{ 
                search_result.total_matches, cmd.entity_type, cmd.name, workspace_part 
            });

            // Format all results in one go
            for (search_result.results) |result| {
                const block = result.block.block;
                const block_id_hex = try block.id.to_hex(context.allocator);
                defer context.allocator.free(block_id_hex);

                const formatted_id = output.format_block_id(context.allocator, block_id_hex) catch block_id_hex;
                defer if (formatted_id.ptr != block_id_hex.ptr) context.allocator.free(formatted_id);
                
                const compact_id = output.format_block_id_compact(context.allocator, block_id_hex) catch block_id_hex;
                defer if (compact_id.ptr != block_id_hex.ptr) context.allocator.free(compact_id);

                const preview = if (block.content.len > 0) blk: {
                    // Keep original formatting with newlines preserved
                    const p = if (block.content.len > 200)
                        try std.fmt.allocPrint(context.allocator, "{s}...", .{block.content[0..200]})
                    else
                        try context.allocator.dupe(u8, block.content);
                    break :blk p;
                } else try context.allocator.dupe(u8, "");
                defer context.allocator.free(preview);

                // Format multiline preview preserving original indentation exactly
                const indented_preview = try std.fmt.allocPrint(context.allocator, "│           {s}", .{preview});
                defer context.allocator.free(indented_preview);
                const formatted_preview = try std.mem.replaceOwned(u8, context.allocator, indented_preview, "\n", "\n│           ");
                defer context.allocator.free(formatted_preview);
                
                // Card-like frame for each result with multiline preview  
                const result_card = try std.fmt.allocPrint(context.allocator,
                    \\
                    \\┌─ {s} [{s}]
                    \\│  Source: {s}
                    \\│  ID:     {s}
                    \\│  Preview:
                    \\{s}
                    \\└─────────────────────────────────────────────────────────────────────────
                    \\
                , .{ extract_entity_name(block), formatted_id, block.source_uri, compact_id, formatted_preview });
                defer context.allocator.free(result_card);
                
                output.write_stdout(result_card);
            }
        }
    }
}

fn execute_show_command(context: *ExecutionContext, cmd: Command.ShowCommand) !void {
    try context.ensure_query_initialized();
    const query_eng = context.query_engine.?;

    // Relation validation ensures only supported graph traversal patterns
    if (!commands.validate_relation_type(cmd.relation_type)) {
        if (cmd.format == .json) {
            output.print_json_error(context.allocator, "Invalid relation type '{s}'", .{cmd.relation_type});
        } else {
            output.print_error(context.allocator, "Invalid relation type '{s}'. Valid relations: callers, callees, references", .{cmd.relation_type});
        }
        return;
    }

    const workspace = cmd.workspace orelse context.infer_workspace_name();

    const target_id = if (is_block_id(cmd.target)) blk: {
        const block_id = types.BlockId.from_hex(cmd.target) catch {
            if (cmd.format == .json) {
                output.print_json_error(context.allocator, "Invalid BlockId format: '{s}'", .{cmd.target});
            } else {
                output.print_error(context.allocator, "Invalid BlockId format: '{s}'", .{cmd.target});
            }
            return;
        };
        break :blk block_id;
    } else blk: {
        const search_result = query_eng.find_by_name(workspace, "function", cmd.target) catch |err| switch (err) {
            query_engine.QueryError.SemanticSearchUnavailable => {
                if (cmd.format == .json) {
                    output.print_json_error(context.allocator, "Semantic search not available", .{});
                } else {
                    output.write_stdout("Semantic search is not available yet.\n");
                    output.write_stdout("Make sure codebases are linked and synced.\n");
                }
                return;
            },
            else => return err,
        };
        defer search_result.deinit();

        if (search_result.total_matches == 0) {
            if (cmd.format == .json) {
                output.print_json_stdout(context.allocator,
                    \\{{"error": "Target '{s}' not found"}}
                , .{cmd.target});
            } else {
                output.print_stdout(context.allocator, "Target '{s}' not found", .{cmd.target});
                if (cmd.workspace) |ws| {
                    output.print_stdout(context.allocator, " in workspace '{s}'", .{ws});
                }
                output.write_stdout(".\n");
            }
            return;
        }

        if (search_result.total_matches > 1) {
            if (cmd.format == .json) {
                output.print_json_error(context.allocator, "Multiple matches found for '{s}'. Use specific BlockId from 'find' command.", .{cmd.target});
            } else {
                output.print_disambiguation_error(context.allocator, cmd.target, "function", search_result.total_matches);
            }
            return;
        }

        break :blk search_result.results[0].block.block.id;
    };

    const traversal_result = (if (std.mem.indexOf(u8, cmd.relation_type, "callers") != null) blk: {
        break :blk query_eng.find_callers(workspace, target_id, 1);
    } else if (std.mem.indexOf(u8, cmd.relation_type, "callees") != null) blk: {
        break :blk query_eng.find_callees(workspace, target_id, 1);
    } else blk: {
        break :blk query_eng.find_references(workspace, target_id, 1);
    }) catch |err| {
        if (cmd.format == .json) {
            output.print_json_stdout(context.allocator,
                \\{{"error": "Failed to execute traversal query"}}
            , .{});
        } else {
            output.print_error(context.allocator, "Failed to execute traversal query", .{});
        }
        return err;
    };
    defer traversal_result.deinit();

    // Output results
    if (cmd.format == .json) {
        output.write_stdout("{\n");
        output.print_stdout(context.allocator, "  \"query\": {{\"relation\": \"{s}\", \"target\": \"{s}\", \"workspace\": \"{s}\"}},\n", .{ cmd.relation_type, cmd.target, workspace });
        output.print_stdout(context.allocator, "  \"total_matches\": {},\n", .{traversal_result.blocks.len});
        output.write_stdout("  \"results\": [\n");
        for (traversal_result.blocks, 0..) |owned_block, i| {
            const block = owned_block.read(.query_engine);
            output.print_json_stdout(context.allocator,
                \\    {{"name": "{s}", "source": "{s}", "depth": {}}}
            , .{ extract_entity_name(block.*), block.source_uri, traversal_result.depths[i] });
            if (i < traversal_result.blocks.len - 1) output.write_stdout(",");
            output.write_stdout("\n");
        }
        output.write_stdout("  ]\n}\n");
    } else {
        if (traversal_result.blocks.len == 0) {
            output.print_stdout(context.allocator, "No {s} found for '{s}'", .{ cmd.relation_type, cmd.target });
            if (cmd.workspace) |ws| {
                output.print_stdout(context.allocator, " in workspace '{s}'", .{ws});
            }
            output.write_stdout(".\n");
        } else {
            output.print_stdout(context.allocator, "Found {} {s} for '{s}'", .{ traversal_result.blocks.len, cmd.relation_type, cmd.target });
            if (cmd.workspace) |ws| {
                output.print_stdout(context.allocator, " in workspace '{s}'", .{ws});
            }
            output.write_stdout(":\n\n");

            for (traversal_result.blocks, 0..) |owned_block, i| {
                const block = owned_block.read(.query_engine);
                output.print_stdout(context.allocator, "{}. {s}\n", .{ i + 1, extract_entity_name(block.*) });
                output.print_stdout(context.allocator, "   Source: {s}\n", .{block.source_uri});

                if (block.content.len > 0) {
                    const preview = if (block.content.len > 100)
                        try std.fmt.allocPrint(context.allocator, "{s}...", .{block.content[0..100]})
                    else
                        try context.allocator.dupe(u8, block.content);
                    defer context.allocator.free(preview);

                    output.print_stdout(context.allocator, "   Preview: {s}\n", .{preview});
                }
                output.write_stdout("\n");
            }
        }
    }
}

fn execute_trace_command(context: *ExecutionContext, cmd: Command.TraceCommand) !void {
    try context.ensure_query_initialized();
    const query_eng = context.query_engine.?;

    // Direction validation prevents invalid multi-hop traversal requests
    if (!commands.validate_direction(cmd.direction)) {
        if (cmd.format == .json) {
            output.print_json_stdout(context.allocator,
                \\{{"error": "Invalid direction '{s}'"}}
            , .{cmd.direction});
        } else {
            output.print_stderr(context.allocator, "Error: Invalid direction '{s}'\n", .{cmd.direction});
            output.write_stdout("Valid directions: callers, callees, both, references\n");
        }
        return;
    }

    const depth = cmd.depth orelse 3;
    const workspace = cmd.workspace orelse context.infer_workspace_name();

    const target_id = if (is_block_id(cmd.target)) blk: {
        const block_id = types.BlockId.from_hex(cmd.target) catch {
            if (cmd.format == .json) {
                output.print_json_error(context.allocator, "Invalid BlockId format: '{s}'", .{cmd.target});
            } else {
                output.print_error(context.allocator, "Invalid BlockId format: '{s}'", .{cmd.target});
            }
            return;
        };
        break :blk block_id;
    } else blk: {
        const search_result = query_eng.find_by_name(workspace, "function", cmd.target) catch |err| switch (err) {
            query_engine.QueryError.SemanticSearchUnavailable => {
                if (cmd.format == .json) {
                    output.write_stdout("{\"error\": \"Semantic search not available\"}\n");
                } else {
                    output.write_stdout("Semantic search is not available yet.\n");
                    output.write_stdout("Make sure codebases are linked and synced.\n");
                }
                return;
            },
            else => return err,
        };
        defer search_result.deinit();

        if (search_result.total_matches == 0) {
            if (cmd.format == .json) {
                output.print_json_stdout(context.allocator,
                    \\{{"error": "Target '{s}' not found"}}
                , .{cmd.target});
            } else {
                output.print_stdout(context.allocator, "Target '{s}' not found", .{cmd.target});
                if (cmd.workspace) |ws| {
                    output.print_stdout(context.allocator, " in workspace '{s}'", .{ws});
                }
                output.write_stdout(".\n");
            }
            return;
        }

        if (search_result.total_matches > 1) {
            if (cmd.format == .json) {
                output.print_json_error(context.allocator, "Multiple matches found for '{s}'. Use specific BlockId from 'find' command.", .{cmd.target});
            } else {
                output.print_disambiguation_error(context.allocator, cmd.target, "function", search_result.total_matches);
            }
            return;
        }

        break :blk search_result.results[0].block.block.id;
    };

    // Execute the appropriate traversal query based on direction
    const traversal_result = (if (std.mem.eql(u8, cmd.direction, "callers")) blk: {
        break :blk query_eng.find_callers(workspace, target_id, depth);
    } else if (std.mem.eql(u8, cmd.direction, "callees")) blk: {
        break :blk query_eng.find_callees(workspace, target_id, depth);
    } else if (std.mem.eql(u8, cmd.direction, "references") or std.mem.eql(u8, cmd.direction, "both")) blk: {
        // references/both - bidirectional traversal
        break :blk query_eng.find_references(workspace, target_id, depth);
    } else blk: {
        // Default to callees for unknown directions
        break :blk query_eng.find_callees(workspace, target_id, depth);
    }) catch |err| {
        if (cmd.format == .json) {
            output.print_json_stdout(context.allocator,
                \\{{"error": "Failed to execute traversal query"}}
            , .{});
        } else {
            output.print_error(context.allocator, "Failed to execute traversal query", .{});
        }
        return err;
    };
    defer traversal_result.deinit();

    // Output results
    if (cmd.format == .json) {
        output.write_stdout("{\n");
        output.print_stdout(context.allocator, "  \"query\": {{\"direction\": \"{s}\", \"target\": \"{s}\", \"depth\": {}, \"workspace\": \"{s}\"}},\n", .{ cmd.direction, cmd.target, depth, workspace });
        output.print_stdout(context.allocator, "  \"total_matches\": {},\n", .{traversal_result.blocks.len});
        output.write_stdout("  \"results\": [\n");
        for (traversal_result.blocks, 0..) |owned_block, i| {
            const block = owned_block.read(.query_engine);
            output.print_json_stdout(context.allocator,
                \\    {{"name": "{s}", "source": "{s}", "depth": {}}}
            , .{ extract_entity_name(block.*), block.source_uri, traversal_result.depths[i] });
            if (i < traversal_result.blocks.len - 1) output.write_stdout(",");
            output.write_stdout("\n");
        }
        output.write_stdout("  ]\n}\n");
    } else {
        if (traversal_result.blocks.len == 0) {
            output.print_stdout(context.allocator, "No {s} found for '{s}' (depth: {})", .{ cmd.direction, cmd.target, depth });
            if (cmd.workspace) |ws| {
                output.print_stdout(context.allocator, " in workspace '{s}'", .{ws});
            }
            output.write_stdout(".\n");
        } else {
            output.print_stdout(context.allocator, "Trace {s} from '{s}' (depth: {})", .{ cmd.direction, cmd.target, depth });
            if (cmd.workspace) |ws| {
                output.print_stdout(context.allocator, " in workspace '{s}'", .{ws});
            }
            output.write_stdout(":\n\n");

            for (traversal_result.blocks, 0..) |owned_block, i| {
                const block = owned_block.read(.query_engine);
                const block_depth = traversal_result.depths[i];

                // Create indentation based on depth
                var depth_spaces = std.array_list.Managed(u8).init(context.allocator);
                defer depth_spaces.deinit();
                var d: u32 = 0;
                while (d < block_depth) : (d += 1) {
                    try depth_spaces.appendSlice("  ");
                }
                const depth_indicator = depth_spaces.items;

                output.print_stdout(context.allocator, "{s}{}. {s} (depth: {})\n", .{ depth_indicator, i + 1, extract_entity_name(block.*), block_depth });
                output.print_stdout(context.allocator, "{s}   Source: {s}\n", .{ depth_indicator, block.source_uri });

                if (block.content.len > 0) {
                    const preview = if (block.content.len > 100)
                        try std.fmt.allocPrint(context.allocator, "{s}...", .{block.content[0..100]})
                    else
                        try context.allocator.dupe(u8, block.content);
                    defer context.allocator.free(preview);

                    output.print_stdout(context.allocator, "{s}   Preview: {s}\n", .{ depth_indicator, preview });
                }
                output.write_stdout("\n");
            }
        }
    }
}

// === Helper Functions ===

/// Check if a string looks like a BlockId (32 hex characters)
fn is_block_id(target: []const u8) bool {
    if (target.len != 32) return false;

    for (target) |char| {
        switch (char) {
            '0'...'9', 'a'...'f', 'A'...'F' => {},
            else => return false,
        }
    }
    return true;
}

/// Extract entity name from block content or metadata
fn extract_entity_name(block: ContextBlock) []const u8 {
    // Try to parse metadata first for a clean name
    if (block.metadata_json.len > 0) {
        // Simple JSON parsing for "name" field
        if (std.mem.indexOf(u8, block.metadata_json, "\"name\":\"")) |start| {
            const name_start = start + 8; // Length of "\"name\":\""
            if (std.mem.indexOfPos(u8, block.metadata_json, name_start, "\"")) |end| {
                return block.metadata_json[name_start..end];
            }
        }
    }

    // Fallback to extracting from source URI
    if (std.mem.lastIndexOf(u8, block.source_uri, "#")) |hash_pos| {
        return block.source_uri[hash_pos + 1 ..];
    }

    // Final fallback to first line of content
    if (std.mem.indexOf(u8, block.content, "\n")) |newline| {
        const first_line = block.content[0..newline];
        if (first_line.len > 50) {
            return first_line[0..50];
        }
        return first_line;
    }

    return "unknown";
}

fn show_general_help() void {
    output.write_stdout(
        \\KausalDB - Code-native graph database
        \\
        \\Usage:
        \\  kausal <command> [options]
        \\
        \\Workspace Commands:
        \\  link <path> [as <name>]       Link codebase to workspace
        \\  unlink <name>                 Remove codebase from workspace
        \\  sync [name|--all]             Sync codebase with source changes
        \\  status                        Show workspace information
        \\
        \\Query Commands:
        \\  find <type> <name> [in <workspace>]      Find entities by name
        \\  show <relation> <target> [in <workspace>] Show relationships
        \\  trace <direction> <target> [--depth N]    Trace call chains
        \\
        \\System Commands:
        \\  version                       Show version information
        \\  help [topic]                  Show help message
        \\
        \\Global Options:
        \\  --help, -h                    Show this help message
        \\  --version, -v                 Show version information
        \\  --json                        Output in JSON format
        \\
        \\Examples:
        \\  kausal link .                            # Link current directory
        \\  kausal link /path/to/code as myproject   # Link with custom name
        \\  kausal sync myproject                    # Sync specific codebase
        \\  kausal status --json                     # JSON workspace status
        \\  kausal find function "init" in kausaldb  # Find functions named "init"
        \\  kausal show callers "main" in myproject  # Show what calls main()
        \\  kausal trace callees "main" --depth 3    # Trace call chain 3 levels deep
        \\
    );
}

fn show_command_help(topic: []const u8) void {
    if (std.mem.eql(u8, topic, "link")) {
        output.write_stdout(
            \\Usage: kausal link <path> [as <name>] [--json]
            \\
            \\Link a codebase directory to your KausalDB workspace for indexing and queries.
            \\
            \\Arguments:
            \\  <path>        Directory path to link (can be relative or absolute)
            \\  as <name>     Optional custom name for the codebase
            \\
            \\Options:
            \\  --json        Output results in JSON format
            \\
            \\Examples:
            \\  kausal link ./my-project
            \\  kausal link /path/to/project as myproject
            \\  kausal link . as current --json
            \\
        );
    } else if (std.mem.eql(u8, topic, "find")) {
        output.write_stdout(
            \\Usage: kausal find <type> <name> [in <workspace>] [--json]
            \\
            \\Find code entities by type and name across linked codebases.
            \\
            \\Arguments:
            \\  <type>        Entity type: function, struct, test, method, const, var, type
            \\  <name>        Name to search for
            \\  in <workspace> Optional workspace to search in
            \\
            \\Options:
            \\  --json        Output results in JSON format
            \\
            \\Examples:
            \\  kausal find function main
            \\  kausal find struct User in myproject
            \\  kausal find test --json
            \\
        );
    } else {
        output.print_stdout(std.heap.page_allocator, "No help available for topic: {s}\n", .{topic});
        output.write_stdout("Available topics: link, find, show, trace, sync, status\n");
    }
}

// === Unit Tests ===

test "command parsing validation" {
    // Test that relation types validate correctly
    try std.testing.expect(commands.validate_relation_type("callers"));
    try std.testing.expect(commands.validate_relation_type("callees"));
    try std.testing.expect(commands.validate_relation_type("references"));
    try std.testing.expect(!commands.validate_relation_type("invalid"));

    // Test that trace directions validate correctly
    try std.testing.expect(commands.validate_direction("callers"));
    try std.testing.expect(commands.validate_direction("callees"));
    try std.testing.expect(commands.validate_direction("references"));
    try std.testing.expect(commands.validate_direction("both"));
    try std.testing.expect(!commands.validate_direction("invalid"));
}

test "execution context initialization" {
    const allocator = std.testing.allocator;

    // Create temporary directory for test
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_data_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(test_data_dir);

    var context = try ExecutionContext.init(allocator, test_data_dir);
    defer context.deinit();

    try std.testing.expect(context.storage_engine == null);
    try std.testing.expect(context.query_engine == null);
    try std.testing.expect(context.workspace_manager == null);

    // Test lazy initialization
    try context.ensure_storage_initialized();
    try std.testing.expect(context.storage_engine != null);

    try context.ensure_query_initialized();
    try std.testing.expect(context.query_engine != null);

    try context.ensure_workspace_initialized();
    try std.testing.expect(context.workspace_manager != null);
}

test "extract entity name from block content" {
    const test_block = ContextBlock{
        .id = try types.BlockId.from_hex("11111111111111111111111111111111"),
        .sequence = 0, // Storage engine will assign the actual global sequence
        .source_uri = "test://example.zig#my_function",
        .metadata_json = "{\"name\": \"my_function\", \"type\": \"function\"}",
        .content = "fn my_function() {}",
    };

    const extracted = extract_entity_name(test_block);
    try std.testing.expectEqualStrings("my_function", extracted);

    // Test fallback to source URI
    const uri_fallback_block = ContextBlock{
        .id = try types.BlockId.from_hex("22222222222222222222222222222222"),
        .sequence = 0, // Storage engine will assign the actual global sequence
        .source_uri = "test://example.zig#fallback_name",
        .metadata_json = "{}",
        .content = "some content",
    };

    const uri_extracted = extract_entity_name(uri_fallback_block);
    try std.testing.expectEqualStrings("fallback_name", uri_extracted);
}
