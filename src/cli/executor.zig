//! Command execution engine for KausalDB CLI.
//!
//! Coordinates command execution across workspace management, storage engine,
//! and query systems. Provides unified output formatting and error handling
//! for all CLI operations.
//!
//! Design rationale: Single execution coordinator eliminates scattered command
//! logic and enables consistent error handling and output formatting across
//! all CLI operations.

const std = @import("std");

const assert_mod = @import("../core/assert.zig");
const commands = @import("commands.zig");
const error_context = @import("../core/error_context.zig");
const memory = @import("../core/memory.zig");
const production_vfs = @import("../core/production_vfs.zig");
const query_engine = @import("../query/engine.zig");
const storage = @import("../storage/engine.zig");
const workspace_manager = @import("../workspace/manager.zig");
const vfs = @import("../core/vfs.zig");

const assert = assert_mod.assert;
const fatal_assert = assert_mod.fatal_assert;
const ArenaCoordinator = memory.ArenaCoordinator;
const Command = commands.Command;
const CommandError = commands.CommandError;
const ParseResult = commands.ParseResult;
const ProductionVFS = production_vfs.ProductionVFS;
const QueryEngine = query_engine.QueryEngine;
const StorageEngine = storage.StorageEngine;
const WorkspaceManager = workspace_manager.WorkspaceManager;
const VFS = vfs.VFS;

pub const ExecutorError = error{
    StorageNotInitialized,
    WorkspaceNotInitialized,
    OutputFormatError,
} || CommandError || storage.StorageError || workspace_manager.WorkspaceError || std.mem.Allocator.Error;

/// Output formatting options for CLI commands
pub const OutputFormat = enum {
    human,
    json,
};

/// Command execution context with shared resources
pub const ExecutionContext = struct {
    allocator: std.mem.Allocator,
    storage_engine: ?*StorageEngine,
    workspace_manager: ?*WorkspaceManager,
    query_engine: ?*QueryEngine,
    output_format: OutputFormat,
    data_dir: []const u8,
    vfs: VFS,

    /// Initialize execution context with default data directory
    pub fn init(allocator: std.mem.Allocator, data_dir: []const u8) !ExecutionContext {
        // Use production filesystem for all CLI operations
        var prod_vfs = ProductionVFS.init(allocator);

        // Convert relative path to absolute path for VFS operations
        const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
        defer allocator.free(cwd);
        const abs_data_dir = if (std.fs.path.isAbsolute(data_dir))
            try allocator.dupe(u8, data_dir)
        else
            try std.fs.path.join(allocator, &[_][]const u8{ cwd, data_dir });

        return ExecutionContext{
            .allocator = allocator,
            .storage_engine = null,
            .workspace_manager = null,
            .query_engine = null,
            .output_format = OutputFormat.human,
            .data_dir = abs_data_dir,
            .vfs = prod_vfs.vfs(),
        };
    }

    /// Initialize storage engine if not already initialized
    fn ensure_storage_initialized(self: *ExecutionContext) !void {
        if (self.storage_engine != null) return;

        // Create data directory if it doesn't exist
        self.vfs.mkdir_all(self.data_dir) catch |err| switch (err) {
            vfs.VFSError.FileExists => {}, // Directory already exists
            else => return err,
        };

        // Initialize and startup storage engine
        var engine = try self.allocator.create(StorageEngine);
        engine.* = try StorageEngine.init_default(self.allocator, self.vfs, self.data_dir);
        try engine.startup();
        self.storage_engine = engine;
    }

    /// Initialize workspace manager if not already initialized
    fn ensure_workspace_initialized(self: *ExecutionContext) !void {
        if (self.workspace_manager != null) return;

        try self.ensure_storage_initialized();

        var manager = try self.allocator.create(WorkspaceManager);
        manager.* = try WorkspaceManager.init(self.allocator, self.storage_engine.?);
        try manager.startup();
        self.workspace_manager = manager;
    }

    /// Initialize query engine if not already initialized
    fn ensure_query_initialized(self: *ExecutionContext) !void {
        if (self.query_engine != null) return;

        try self.ensure_storage_initialized();

        var engine = try self.allocator.create(QueryEngine);
        engine.* = QueryEngine.init(self.allocator, self.storage_engine.?);
        engine.startup();
        self.query_engine = engine;
    }

    /// Clean up execution context resources
    pub fn deinit(self: *ExecutionContext) void {
        if (self.query_engine) |qe| {
            qe.shutdown();
            qe.deinit();
            self.allocator.destroy(qe);
        }

        if (self.workspace_manager) |wm| {
            wm.shutdown();
            wm.deinit();
            self.allocator.destroy(wm);
        }

        if (self.storage_engine) |se| {
            se.shutdown() catch {};
            se.deinit();
            self.allocator.destroy(se);
        }

        // Free the allocated absolute data_dir path
        self.allocator.free(self.data_dir);
    }
};

/// Execute parsed command with proper resource coordination
pub fn execute_command(context: *ExecutionContext, parse_result: ParseResult) !void {
    switch (parse_result.command) {
        .version => try execute_version_command(),
        .help => |help_cmd| try execute_help_command(help_cmd),
        .server => |server_cmd| try execute_server_command(context, server_cmd),
        .demo => try execute_demo_command(context),
        .workspace => |workspace_cmd| try execute_workspace_command(context, workspace_cmd),
        .find => |find_cmd| try execute_find_command(context, find_cmd),
        .show => |show_cmd| try execute_show_command(context, show_cmd),
        .trace => |trace_cmd| try execute_trace_command(context, trace_cmd),
        .status => |status_cmd| try execute_legacy_status_command(context, status_cmd),
        .list_blocks => |list_cmd| try execute_legacy_list_blocks_command(context, list_cmd),
        .query => |query_cmd| try execute_legacy_query_command(context, query_cmd),
        .analyze => try execute_legacy_analyze_command(context),
    }
}

fn execute_version_command() !void {
    const stdout = std.fs.File{ .handle = 1 };
    try stdout.writeAll("KausalDB v0.1.0\n");
}

fn execute_help_command(help_cmd: commands.HelpCommand) !void {
    const stdout = std.fs.File{ .handle = 1 };

    if (help_cmd.command_topic) |topic| {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        const topic_msg = try std.fmt.allocPrint(allocator, "Help for topic: {s}\n", .{topic});
        defer allocator.free(topic_msg);
        try stdout.writeAll(topic_msg);
        try stdout.writeAll("(Topic-specific help not yet implemented)\n\n");
    }

    try stdout.writeAll(
        \\KausalDB - Code-native graph database
        \\
        \\Usage:
        \\  kausaldb <command> [options]
        \\
        \\Workspace Commands:
        \\  link <path> [as <name>]  Link codebase to workspace
        \\  unlink <name>            Remove codebase from workspace
        \\  sync [name]              Sync codebase with source changes
        \\  workspace [status]       Show workspace information
        \\
        \\Query Commands: (Future)
        \\  find <type> <name>       Find entities by name
        \\  show <relation> <target> Show relationships
        \\  trace <direction> <target> [--depth N] Trace call chains
        \\
        \\System Commands:
        \\  version                  Show version information
        \\  help [topic]             Show help message
        \\  server [options]         Start database server
        \\  demo                     Run demonstration
        \\
        \\Legacy Commands:
        \\  status [--data-dir]      Database status
        \\  list-blocks [--limit]    List stored blocks
        \\  query [--id|--content]   Query by ID or content
        \\  analyze                  Legacy analysis
        \\
        \\Examples:
        \\  kausaldb link .                   # Link current directory
        \\  kausaldb link /path/to/code as myproject
        \\  kausaldb sync myproject
        \\  kausaldb workspace                # Show linked codebases
        \\
    );
}

fn execute_server_command(context: *ExecutionContext, server_cmd: commands.ServerCommand) !void {
    _ = context;
    const stdout = std.fs.File{ .handle = 1 };
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Server implementation would go here
    const port = server_cmd.port orelse 8080;
    const data_dir = server_cmd.data_dir orelse "kausal_data";

    try stdout.writeAll("KausalDB server starting...\n");

    const port_msg = try std.fmt.allocPrint(allocator, "Port: {}\n", .{port});
    defer allocator.free(port_msg);
    try stdout.writeAll(port_msg);

    const dir_msg = try std.fmt.allocPrint(allocator, "Data directory: {s}\n", .{data_dir});
    defer allocator.free(dir_msg);
    try stdout.writeAll(dir_msg);

    try stdout.writeAll("(Server implementation not yet complete)\n");
}

fn execute_demo_command(context: *ExecutionContext) !void {
    try context.ensure_storage_initialized();
    try context.ensure_query_initialized();

    const stdout = std.fs.File{ .handle = 1 };
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try stdout.writeAll("=== KausalDB Storage and Query Demo ===\n\n");

    const stats = context.query_engine.?.statistics();
    try stdout.writeAll("Storage engine initialized\n");

    const blocks_msg = try std.fmt.allocPrint(allocator, "Total blocks stored: {}\n", .{stats.total_blocks_stored});
    defer allocator.free(blocks_msg);
    try stdout.writeAll(blocks_msg);

    const queries_msg = try std.fmt.allocPrint(allocator, "Queries executed: {}\n", .{stats.queries_executed});
    defer allocator.free(queries_msg);
    try stdout.writeAll(queries_msg);
}

fn execute_workspace_command(context: *ExecutionContext, workspace_cmd: commands.WorkspaceCommand) !void {
    try context.ensure_workspace_initialized();

    switch (workspace_cmd) {
        .link => |link_cmd| try execute_link_command(context, link_cmd),
        .unlink => |unlink_cmd| try execute_unlink_command(context, unlink_cmd),
        .status => try execute_workspace_status_command(context),
        .sync => |sync_cmd| try execute_sync_command(context, sync_cmd),
    }
}

fn execute_link_command(context: *ExecutionContext, link_cmd: commands.LinkCommand) !void {
    const workspace = context.workspace_manager.?;

    // Resolve path to absolute path for consistent storage
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = std.fs.cwd().realpath(link_cmd.path, &path_buffer) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Error: Path '{s}' does not exist\n", .{link_cmd.path});
            return;
        },
        else => return err,
    };

    workspace.link_codebase(abs_path, link_cmd.name) catch |err| switch (err) {
        workspace_manager.WorkspaceError.CodebaseAlreadyLinked => {
            const name = link_cmd.name orelse std.fs.path.basename(abs_path);
            std.debug.print("Error: Codebase '{s}' is already linked to workspace\n", .{name});
            return;
        },
        workspace_manager.WorkspaceError.InvalidCodebasePath => {
            std.debug.print("Error: Invalid codebase path '{s}'\n", .{abs_path});
            return;
        },
        workspace_manager.WorkspaceError.InvalidCodebaseName => {
            std.debug.print("Error: Invalid codebase name\n", .{});
            return;
        },
        else => return err,
    };

    const linked_name = link_cmd.name orelse std.fs.path.basename(abs_path);
    const stdout = std.fs.File{ .handle = 1 };
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const success_msg = try std.fmt.allocPrint(allocator, "✓ Linked codebase '{s}' from {s}\n", .{ linked_name, abs_path });
    defer allocator.free(success_msg);
    try stdout.writeAll(success_msg);
}

fn execute_unlink_command(context: *ExecutionContext, unlink_cmd: commands.UnlinkCommand) !void {
    const workspace = context.workspace_manager.?;

    workspace.unlink_codebase(unlink_cmd.name) catch |err| switch (err) {
        workspace_manager.WorkspaceError.CodebaseNotFound => {
            std.debug.print("Error: Codebase '{s}' is not linked to workspace\n", .{unlink_cmd.name});
            return;
        },
        else => return err,
    };

    const stdout = std.fs.File{ .handle = 1 };
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const success_msg = try std.fmt.allocPrint(allocator, "✓ Unlinked codebase '{s}' from workspace\n", .{unlink_cmd.name});
    defer allocator.free(success_msg);
    try stdout.writeAll(success_msg);
}

fn execute_workspace_status_command(context: *ExecutionContext) !void {
    const workspace = context.workspace_manager.?;

    const codebases = try workspace.list_linked_codebases(context.allocator);
    defer context.allocator.free(codebases);

    const stdout = std.fs.File{ .handle = 1 };
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    if (codebases.len == 0) {
        try stdout.writeAll("No codebases linked to workspace.\n");
        try stdout.writeAll("Use 'kausaldb link <path>' to link a codebase.\n");
        return;
    }

    try stdout.writeAll("WORKSPACE STATUS\n");
    try stdout.writeAll("================\n\n");

    for (codebases) |codebase| {
        const name_msg = try std.fmt.allocPrint(allocator, "• {s}\n", .{codebase.name});
        defer allocator.free(name_msg);
        try stdout.writeAll(name_msg);

        const path_msg = try std.fmt.allocPrint(allocator, "  Path: {s}\n", .{codebase.path});
        defer allocator.free(path_msg);
        try stdout.writeAll(path_msg);

        const linked_msg = try std.fmt.allocPrint(allocator, "  Linked: {} ago\n", .{std.time.timestamp() - codebase.linked_timestamp});
        defer allocator.free(linked_msg);
        try stdout.writeAll(linked_msg);

        const sync_msg = try std.fmt.allocPrint(allocator, "  Last sync: {} ago\n", .{std.time.timestamp() - codebase.last_sync_timestamp});
        defer allocator.free(sync_msg);
        try stdout.writeAll(sync_msg);

        const stats_msg = try std.fmt.allocPrint(allocator, "  Blocks: {} | Edges: {}\n\n", .{ codebase.block_count, codebase.edge_count });
        defer allocator.free(stats_msg);
        try stdout.writeAll(stats_msg);
    }
}

fn execute_sync_command(context: *ExecutionContext, sync_cmd: commands.SyncCommand) !void {
    const workspace = context.workspace_manager.?;

    if (sync_cmd.name) |name| {
        // Sync specific codebase
        workspace.sync_codebase(name) catch |err| switch (err) {
            workspace_manager.WorkspaceError.CodebaseNotFound => {
                std.debug.print("Error: Codebase '{s}' is not linked to workspace\n", .{name});
                return;
            },
            else => return err,
        };

        const stdout = std.fs.File{ .handle = 1 };
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        const success_msg = try std.fmt.allocPrint(allocator, "✓ Synced codebase '{s}'\n", .{name});
        defer allocator.free(success_msg);
        try stdout.writeAll(success_msg);
    } else {
        // Sync all codebases
        const codebases = try workspace.list_linked_codebases(context.allocator);
        defer context.allocator.free(codebases);

        const stdout = std.fs.File{ .handle = 1 };
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        for (codebases) |codebase| {
            try workspace.sync_codebase(codebase.name);
            const success_msg = try std.fmt.allocPrint(allocator, "✓ Synced codebase '{s}'\n", .{codebase.name});
            defer allocator.free(success_msg);
            try stdout.writeAll(success_msg);
        }

        if (codebases.len == 0) {
            try stdout.writeAll("No codebases to sync.\n");
        }
    }
}

fn execute_find_command(context: *ExecutionContext, find_cmd: commands.FindCommand) !void {
    _ = context;
    const stdout = std.fs.File{ .handle = 1 };
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const find_msg = try std.fmt.allocPrint(allocator, "Find command: {s} {s} (workspace: {?s})\n", .{ find_cmd.entity_type, find_cmd.name, find_cmd.workspace });
    defer allocator.free(find_msg);
    try stdout.writeAll(find_msg);
    try stdout.writeAll("(Find command implementation coming in next phase)\n");
}

fn execute_show_command(context: *ExecutionContext, show_cmd: commands.ShowCommand) !void {
    _ = context;
    const stdout = std.fs.File{ .handle = 1 };
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const show_msg = try std.fmt.allocPrint(allocator, "Show command: {s} {s} (workspace: {?s})\n", .{ show_cmd.relation_type, show_cmd.target, show_cmd.workspace });
    defer allocator.free(show_msg);
    try stdout.writeAll(show_msg);
    try stdout.writeAll("(Show command implementation coming in next phase)\n");
}

fn execute_trace_command(context: *ExecutionContext, trace_cmd: commands.TraceCommand) !void {
    _ = context;
    const stdout = std.fs.File{ .handle = 1 };
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const trace_msg = try std.fmt.allocPrint(allocator, "Trace command: {s} {s} (depth: {?}, workspace: {?s})\n", .{ trace_cmd.direction, trace_cmd.target, trace_cmd.depth, trace_cmd.workspace });
    defer allocator.free(trace_msg);
    try stdout.writeAll(trace_msg);
    try stdout.writeAll("(Trace command implementation coming in next phase)\n");
}

// Legacy command implementations for backward compatibility
fn execute_legacy_status_command(context: *ExecutionContext, status_cmd: commands.StatusCommand) !void {
    const data_dir = status_cmd.data_dir orelse context.data_dir;

    try context.ensure_storage_initialized();

    const stdout = std.fs.File{ .handle = 1 };
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try stdout.writeAll("=== KausalDB Status ===\n");

    const dir_msg = try std.fmt.allocPrint(allocator, "Data directory: {s}\n", .{data_dir});
    defer allocator.free(dir_msg);
    try stdout.writeAll(dir_msg);

    try stdout.writeAll("(Legacy status command - consider using 'workspace' instead)\n");
}

fn execute_legacy_list_blocks_command(context: *ExecutionContext, list_cmd: commands.ListBlocksCommand) !void {
    try context.ensure_query_initialized();

    const stdout = std.fs.File{ .handle = 1 };
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const limit = list_cmd.limit orelse 10;
    const limit_msg = try std.fmt.allocPrint(allocator, "=== Block Listing (limit: {}) ===\n", .{limit});
    defer allocator.free(limit_msg);
    try stdout.writeAll(limit_msg);
    try stdout.writeAll("(Legacy list-blocks command - implementation pending)\n");
}

fn execute_legacy_query_command(context: *ExecutionContext, query_cmd: commands.QueryCommand) !void {
    try context.ensure_query_initialized();

    const stdout = std.fs.File{ .handle = 1 };
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    if (query_cmd.block_id) |id| {
        const id_msg = try std.fmt.allocPrint(allocator, "Query by ID: {s}\n", .{id});
        defer allocator.free(id_msg);
        try stdout.writeAll(id_msg);
    }

    if (query_cmd.content_pattern) |pattern| {
        const pattern_msg = try std.fmt.allocPrint(allocator, "Query by content pattern: {s}\n", .{pattern});
        defer allocator.free(pattern_msg);
        try stdout.writeAll(pattern_msg);
    }

    try stdout.writeAll("(Legacy query command - implementation pending)\n");
}

fn execute_legacy_analyze_command(context: *ExecutionContext) !void {
    try context.ensure_workspace_initialized();

    const stdout = std.fs.File{ .handle = 1 };

    try stdout.writeAll("=== Legacy Analysis Command ===\n");
    try stdout.writeAll("This command has been replaced by workspace management.\n");
    try stdout.writeAll("Try: kausaldb link . && kausaldb workspace\n");
}
