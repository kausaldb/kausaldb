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
const server = @import("../server/handler.zig");
const signals = @import("../core/signals.zig");
const storage = @import("../storage/engine.zig");
const workspace_manager = @import("../workspace/manager.zig");
const vfs = @import("../core/vfs.zig");

const assert = assert_mod.assert;
const fatal_assert = assert_mod.fatal_assert;
const ArenaCoordinator = memory.ArenaCoordinator;
const Command = commands.Command;
const CommandError = commands.CommandError;
const types = @import("../core/types.zig");
const ContextBlock = types.ContextBlock;
const ParseResult = commands.ParseResult;
const ProductionVFS = production_vfs.ProductionVFS;
const QueryEngine = query_engine.QueryEngine;
const StorageEngine = storage.StorageEngine;
const WorkspaceManager = workspace_manager.WorkspaceManager;
const VFS = vfs.VFS;

/// Simple stdout/stderr helpers using context allocator
fn write_stdout(text: []const u8) void {
    const stdout = std.fs.File{ .handle = 1 };
    stdout.writeAll(text) catch {};
}

fn print_stdout(allocator: std.mem.Allocator, comptime format: []const u8, args: anytype) void {
    const stdout = std.fs.File{ .handle = 1 };
    const msg = std.fmt.allocPrint(allocator, format, args) catch return;
    defer allocator.free(msg);
    stdout.writeAll(msg) catch {};
}

fn print_stderr(comptime format: []const u8, args: anytype) void {
    std.debug.print(format, args);
}

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
    write_stdout("KausalDB v0.1.0\n");
}

fn execute_help_command(help_cmd: commands.HelpCommand) !void {
    if (help_cmd.command_topic) |topic| {
        var buffer: [256]u8 = undefined;
        const topic_msg = std.fmt.bufPrint(&buffer, "Help for topic: {s}\n", .{topic}) catch "Help for topic: (name too long)\n";
        write_stdout(topic_msg);
        write_stdout("(Topic-specific help not yet implemented)\n\n");
    }

    write_stdout(
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
    const port = server_cmd.port orelse 8080;
    const config_data_dir = server_cmd.data_dir orelse context.data_dir;

    // Resolve data directory path
    const server_data_dir = if (std.fs.path.isAbsolute(config_data_dir))
        try context.allocator.dupe(u8, config_data_dir)
    else
        try std.fs.path.join(context.allocator, &[_][]const u8{ context.data_dir, config_data_dir });
    defer context.allocator.free(server_data_dir);

    // Setup signal handlers for graceful shutdown
    signals.setup_signal_handlers();

    write_stdout("KausalDB server starting...\n");
    print_stdout(context.allocator, "Port: {}\n", .{port});
    print_stdout(context.allocator, "Data directory: {s}\n", .{server_data_dir});

    // Ensure data directory exists
    context.vfs.mkdir_all(server_data_dir) catch |err| switch (err) {
        vfs.VFSError.FileExists => {}, // Directory already exists
        else => {
            print_stderr("Failed to create data directory '{s}': {}\n", .{ server_data_dir, err });
            return err;
        },
    };

    // Initialize and startup storage engine
    try context.ensure_storage_initialized();
    try context.ensure_query_initialized();

    print_stdout(context.allocator, "Storage engine initialized and recovered from WAL.\n", .{});
    print_stdout(context.allocator, "Query engine initialized.\n", .{});

    const server_config = server.ServerConfig{
        .port = port,
        .host = "127.0.0.1",
        .enable_logging = true,
    };

    var kausal_server = server.Server.init(context.allocator, server_config, context.storage_engine.?, context.query_engine.?);
    defer kausal_server.deinit();

    print_stdout(context.allocator, "Starting KausalDB TCP server on {s}:{d}...\n", .{ server_config.host, server_config.port });
    print_stdout(context.allocator, "Press Ctrl+C to shutdown gracefully\n", .{});

    try kausal_server.startup();

    // Server has exited gracefully
    write_stdout("KausalDB server shutdown complete\n");
}

fn execute_demo_command(context: *ExecutionContext) !void {
    try context.ensure_storage_initialized();
    try context.ensure_query_initialized();

    write_stdout("=== KausalDB Storage and Query Demo ===\n\n");

    const stats = context.query_engine.?.statistics();
    write_stdout("Storage engine initialized\n");
    print_stdout(context.allocator, "Total blocks stored: {}\n", .{stats.total_blocks_stored});
    print_stdout(context.allocator, "Queries executed: {}\n", .{stats.queries_executed});
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
            print_stderr("Error: Path '{s}' does not exist\n", .{link_cmd.path});
            return;
        },
        else => return err,
    };

    workspace.link_codebase(abs_path, link_cmd.name) catch |err| switch (err) {
        workspace_manager.WorkspaceError.CodebaseAlreadyLinked => {
            const name = link_cmd.name orelse std.fs.path.basename(abs_path);
            print_stderr("Error: Codebase '{s}' is already linked to workspace\n", .{name});
            return;
        },
        workspace_manager.WorkspaceError.InvalidCodebasePath => {
            print_stderr("Error: Invalid codebase path '{s}'\n", .{abs_path});
            return;
        },
        workspace_manager.WorkspaceError.InvalidCodebaseName => {
            print_stderr("Error: Invalid codebase name\n", .{});
            return;
        },
        else => return err,
    };

    const linked_name = link_cmd.name orelse std.fs.path.basename(abs_path);
    print_stdout(context.allocator, "✓ Linked codebase '{s}' from {s}\n", .{ linked_name, abs_path });
}

fn execute_unlink_command(context: *ExecutionContext, unlink_cmd: commands.UnlinkCommand) !void {
    const workspace = context.workspace_manager.?;

    workspace.unlink_codebase(unlink_cmd.name) catch |err| switch (err) {
        workspace_manager.WorkspaceError.CodebaseNotFound => {
            print_stderr("Error: Codebase '{s}' is not linked to workspace\n", .{unlink_cmd.name});
            return;
        },
        else => return err,
    };

    print_stdout(context.allocator, "✓ Unlinked codebase '{s}' from workspace\n", .{unlink_cmd.name});
}

fn execute_workspace_status_command(context: *ExecutionContext) !void {
    const workspace = context.workspace_manager.?;

    const codebases = try workspace.list_linked_codebases(context.allocator);
    defer context.allocator.free(codebases);

    if (codebases.len == 0) {
        write_stdout("No codebases linked to workspace.\n");
        write_stdout("Use 'kausaldb link <path>' to link a codebase.\n");
        return;
    }

    write_stdout("WORKSPACE STATUS\n");
    write_stdout("================\n\n");

    for (codebases) |codebase| {
        print_stdout(context.allocator, "• {s}\n", .{codebase.name});
        print_stdout(context.allocator, "  Path: {s}\n", .{codebase.path});
        print_stdout(context.allocator, "  Linked: {} ago\n", .{std.time.timestamp() - codebase.linked_timestamp});
        print_stdout(context.allocator, "  Last sync: {} ago\n", .{std.time.timestamp() - codebase.last_sync_timestamp});
        print_stdout(context.allocator, "  Blocks: {} | Edges: {}\n\n", .{ codebase.block_count, codebase.edge_count });
    }
}

fn execute_sync_command(context: *ExecutionContext, sync_cmd: commands.SyncCommand) !void {
    const workspace = context.workspace_manager.?;

    if (sync_cmd.name) |name| {
        // Sync specific codebase
        workspace.sync_codebase(name) catch |err| switch (err) {
            workspace_manager.WorkspaceError.CodebaseNotFound => {
                print_stderr("Error: Codebase '{s}' is not linked to workspace\n", .{name});
                return;
            },
            else => return err,
        };

        print_stdout(context.allocator, "✓ Synced codebase '{s}'\n", .{name});
    } else {
        // Sync all codebases
        const codebases = try workspace.list_linked_codebases(context.allocator);
        defer context.allocator.free(codebases);

        for (codebases) |codebase| {
            try workspace.sync_codebase(codebase.name);
            print_stdout(context.allocator, "✓ Synced codebase '{s}'\n", .{codebase.name});
        }

        if (codebases.len == 0) {
            write_stdout("No codebases to sync.\n");
        }
    }
}

fn execute_find_command(context: *ExecutionContext, find_cmd: commands.FindCommand) !void {
    try context.ensure_query_initialized();
    const query_eng = context.query_engine.?;

    // Create semantic query to find entities by type and name
    const search_text = if (std.mem.eql(u8, find_cmd.entity_type, "function"))
        try std.fmt.allocPrint(context.allocator, "function {s}", .{find_cmd.name})
    else if (std.mem.eql(u8, find_cmd.entity_type, "struct"))
        try std.fmt.allocPrint(context.allocator, "struct {s}", .{find_cmd.name})
    else if (std.mem.eql(u8, find_cmd.entity_type, "test"))
        try std.fmt.allocPrint(context.allocator, "test {s}", .{find_cmd.name})
    else if (std.mem.eql(u8, find_cmd.entity_type, "method"))
        try std.fmt.allocPrint(context.allocator, "method {s}", .{find_cmd.name})
    else
        try std.fmt.allocPrint(context.allocator, "{s} {s}", .{ find_cmd.entity_type, find_cmd.name });
    defer context.allocator.free(search_text);

    const semantic_query = query_engine.SemanticQuery.init(search_text);

    print_stdout(context.allocator, "Searching for {s} '{s}'", .{ find_cmd.entity_type, find_cmd.name });
    if (find_cmd.workspace) |ws| {
        print_stdout(context.allocator, " in workspace '{s}'", .{ws});
    }
    write_stdout("...\n\n");

    const search_result = query_eng.execute_semantic_query(semantic_query) catch |err| switch (err) {
        query_engine.QueryError.SemanticSearchUnavailable => {
            write_stdout("Semantic search is not available yet.\n");
            print_stdout(context.allocator, "To find {s} '{s}', you can:\n", .{ find_cmd.entity_type, find_cmd.name });
            write_stdout("1. Use 'kausaldb link .' to link your codebase\n");
            write_stdout("2. Use 'kausaldb sync' to index the content\n");
            write_stdout("3. Try the find command again\n\n");
            write_stdout("For now, you can use legacy commands like 'kausaldb query --content <pattern>'\n");
            return;
        },
        else => return err,
    };
    defer search_result.deinit();

    if (search_result.total_matches == 0) {
        print_stdout(context.allocator, "No {s} named '{s}' found.\n", .{ find_cmd.entity_type, find_cmd.name });
        return;
    }

    print_stdout(context.allocator, "Found {} matches:\n\n", .{search_result.total_matches});

    for (search_result.results, 0..) |result, i| {
        const block = result.block.block;
        print_stdout(context.allocator, "{}. {s} (similarity: {d:.3})\n", .{ i + 1, extract_entity_name(block), result.similarity_score });
        print_stdout(context.allocator, "   Source: {s}\n", .{block.source_uri});
        if (block.metadata_json.len > 0) {
            print_stdout(context.allocator, "   Metadata: {s}\n", .{block.metadata_json});
        }

        // Show a snippet of the content
        const content_preview = if (block.content.len > 200)
            try std.fmt.allocPrint(context.allocator, "{s}...", .{block.content[0..200]})
        else
            try context.allocator.dupe(u8, block.content);
        defer context.allocator.free(content_preview);

        print_stdout(context.allocator, "   Content: {s}\n\n", .{content_preview});
    }
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

fn execute_show_command(context: *ExecutionContext, show_cmd: commands.ShowCommand) !void {
    try context.ensure_query_initialized();
    const query_eng = context.query_engine.?;

    print_stdout(context.allocator, "Searching for {s} of '{s}'", .{ show_cmd.relation_type, show_cmd.target });
    if (show_cmd.workspace) |ws| {
        print_stdout(context.allocator, " in workspace '{s}'", .{ws});
    }
    write_stdout("...\n\n");

    // First find the target entity using semantic search
    const target_query_text = try std.fmt.allocPrint(context.allocator, "{s}", .{show_cmd.target});
    defer context.allocator.free(target_query_text);

    const semantic_query = query_engine.SemanticQuery.init(target_query_text);

    const target_result = query_eng.execute_semantic_query(semantic_query) catch |err| switch (err) {
        query_engine.QueryError.SemanticSearchUnavailable => {
            write_stdout("Semantic search is not available yet.\n");
            write_stdout("To analyze relationships, you need to:\n");
            write_stdout("1. Use 'kausaldb link .' to link your codebase\n");
            write_stdout("2. Use 'kausaldb sync' to index the content\n");
            write_stdout("3. Try the show command again\n");
            return;
        },
        else => return err,
    };
    defer target_result.deinit();

    if (target_result.total_matches == 0) {
        print_stdout(context.allocator, "Could not find target '{s}' in the database.\n", .{show_cmd.target});
        write_stdout("Make sure the code has been linked and synced to the workspace.\n");
        return;
    }

    // Use the first (best) match as the target
    const target_block = target_result.results[0].block.block;
    print_stdout(context.allocator, "Found target: {s} ({s})\n\n", .{ extract_entity_name(target_block), target_block.source_uri });

    // Perform relationship traversal based on the requested type
    const traversal_result = if (std.mem.eql(u8, show_cmd.relation_type, "callers"))
        query_eng.traverse_incoming(target_block.id, 1) catch |err| {
            print_stderr("Error traversing relationships: {}\n", .{err});
            return;
        }
    else if (std.mem.eql(u8, show_cmd.relation_type, "callees"))
        query_eng.traverse_outgoing(target_block.id, 1) catch |err| {
            print_stderr("Error traversing relationships: {}\n", .{err});
            return;
        }
    else if (std.mem.eql(u8, show_cmd.relation_type, "references"))
        query_eng.traverse_bidirectional(target_block.id, 1) catch |err| {
            print_stderr("Error traversing relationships: {}\n", .{err});
            return;
        }
    else {
        print_stderr("Unknown relation type: {s}\n", .{show_cmd.relation_type});
        write_stdout("Supported relation types: callers, callees, references\n");
        return;
    };
    defer traversal_result.deinit();

    if (traversal_result.paths.len == 0) {
        print_stdout(context.allocator, "No {s} found for '{s}'.\n", .{ show_cmd.relation_type, show_cmd.target });
        return;
    }

    print_stdout(context.allocator, "Found {} {s}:\n\n", .{ traversal_result.paths.len, show_cmd.relation_type });

    for (traversal_result.paths, 0..) |path, i| {
        if (path.len <= 1) continue; // Skip empty paths

        print_stdout(context.allocator, "{}. ", .{i + 1});

        // Relation type determines path direction for graph traversal result display
        const related_block_id = if (std.mem.eql(u8, show_cmd.relation_type, "callers"))
            path[0] // First block in path (caller)
        else if (std.mem.eql(u8, show_cmd.relation_type, "callees"))
            path[path.len - 1] // Last block in path (callee)
        else if (path.len > 1) path[1] else path[0]; // For references, related block

        // Find the corresponding block from the results
        var found_block: ?ContextBlock = null;
        for (traversal_result.blocks) |result_block| {
            if (result_block.read(.query_engine).id.eql(related_block_id)) {
                found_block = result_block.read(.query_engine).*;
                break;
            }
        }

        if (found_block) |related_block| {
            // Show the relationship direction
            if (std.mem.eql(u8, show_cmd.relation_type, "callers")) {
                print_stdout(context.allocator, "{s} -> {s}\n", .{ extract_entity_name(related_block), extract_entity_name(target_block) });
            } else if (std.mem.eql(u8, show_cmd.relation_type, "callees")) {
                print_stdout(context.allocator, "{s} -> {s}\n", .{ extract_entity_name(target_block), extract_entity_name(related_block) });
            } else {
                print_stdout(context.allocator, "{s} <-> {s}\n", .{ extract_entity_name(target_block), extract_entity_name(related_block) });
            }
            print_stdout(context.allocator, "   Source: {s}\n", .{related_block.source_uri});

            if (related_block.metadata_json.len > 0) {
                print_stdout(context.allocator, "   Metadata: {s}\n", .{related_block.metadata_json});
            }
        } else {
            print_stdout(context.allocator, "{s} -> BlockID {any}\n", .{ extract_entity_name(target_block), related_block_id });
        }

        write_stdout("\n");
    }
}

fn execute_trace_command(context: *ExecutionContext, trace_cmd: commands.TraceCommand) !void {
    try context.ensure_query_initialized();
    const query_eng = context.query_engine.?;

    const depth = trace_cmd.depth orelse 3; // Default depth of 3

    print_stdout(context.allocator, "Tracing {s} from '{s}' (depth: {})", .{ trace_cmd.direction, trace_cmd.target, depth });
    if (trace_cmd.workspace) |ws| {
        print_stdout(context.allocator, " in workspace '{s}'", .{ws});
    }
    write_stdout("...\n\n");

    // First find the target entity using semantic search
    const target_query_text = try std.fmt.allocPrint(context.allocator, "{s}", .{trace_cmd.target});
    defer context.allocator.free(target_query_text);

    const semantic_query = query_engine.SemanticQuery.init(target_query_text);

    const target_result = query_eng.execute_semantic_query(semantic_query) catch |err| switch (err) {
        query_engine.QueryError.SemanticSearchUnavailable => {
            write_stdout("Semantic search is not available yet.\n");
            write_stdout("To trace call chains, you need to:\n");
            write_stdout("1. Use 'kausaldb link .' to link your codebase\n");
            write_stdout("2. Use 'kausaldb sync' to index the content\n");
            write_stdout("3. Try the trace command again\n");
            return;
        },
        else => return err,
    };
    defer target_result.deinit();

    if (target_result.total_matches == 0) {
        print_stdout(context.allocator, "Could not find target '{s}' in the database.\n", .{trace_cmd.target});
        write_stdout("Make sure the code has been linked and synced to the workspace.\n");
        return;
    }

    // Use the first (best) match as the target
    const target_block = target_result.results[0].block.block;
    print_stdout(context.allocator, "Starting from: {s} ({s})\n\n", .{ extract_entity_name(target_block), target_block.source_uri });

    // Perform multi-hop traversal based on the requested direction
    const traversal_result = if (std.mem.eql(u8, trace_cmd.direction, "callers"))
        query_eng.traverse_incoming(target_block.id, depth) catch |err| {
            print_stderr("Error traversing call chain: {}\n", .{err});
            return;
        }
    else if (std.mem.eql(u8, trace_cmd.direction, "callees"))
        query_eng.traverse_outgoing(target_block.id, depth) catch |err| {
            print_stderr("Error traversing call chain: {}\n", .{err});
            return;
        }
    else if (std.mem.eql(u8, trace_cmd.direction, "both") or std.mem.eql(u8, trace_cmd.direction, "references"))
        query_eng.traverse_bidirectional(target_block.id, depth) catch |err| {
            print_stderr("Error traversing call chain: {}\n", .{err});
            return;
        }
    else {
        print_stderr("Unknown direction: {s}\n", .{trace_cmd.direction});
        write_stdout("Supported directions: callers, callees, both, references\n");
        return;
    };
    defer traversal_result.deinit();

    if (traversal_result.paths.len == 0) {
        print_stdout(context.allocator, "No {s} chain found for '{s}' within {} hops.\n", .{ trace_cmd.direction, trace_cmd.target, depth });
        return;
    }

    print_stdout(context.allocator, "Found {} call chain(s):\n\n", .{traversal_result.paths.len});

    for (traversal_result.paths, 0..) |path, path_idx| {
        if (path.len <= 1) continue; // Skip empty paths

        print_stdout(context.allocator, "Path {}: ", .{path_idx + 1});

        // Show the full path (BlockIds)
        for (path, 0..) |block_id, block_idx| {
            if (block_idx > 0) {
                write_stdout(" -> ");
            }
            print_stdout(context.allocator, "{any}", .{block_id});
        }
        write_stdout("\n");

        // Show detailed information about each step by looking up the blocks
        for (path, 0..) |block_id, block_idx| {
            const indent = if (block_idx == 0) "  ├─ " else "  ├─ ";

            // Find the corresponding block from the results
            var found_block: ?ContextBlock = null;
            for (traversal_result.blocks) |result_block| {
                if (result_block.read(.query_engine).id.eql(block_id)) {
                    found_block = result_block.read(.query_engine).*;
                    break;
                }
            }

            if (found_block) |block| {
                print_stdout(context.allocator, "{s}Step {}: {s}\n", .{ indent, block_idx + 1, extract_entity_name(block) });
                print_stdout(context.allocator, "     Source: {s}\n", .{block.source_uri});

                if (block.metadata_json.len > 0) {
                    print_stdout(context.allocator, "     Metadata: {s}\n", .{block.metadata_json});
                }
            } else {
                print_stdout(context.allocator, "{s}Step {}: BlockID {any}\n", .{ indent, block_idx + 1, block_id });
            }
        }

        print_stdout(context.allocator, "\nPath length: {} hops\n\n", .{path.len - 1});
    }

    // Summary information
    print_stdout(context.allocator, "Summary: Found {} unique call chains with depths from 1 to {} hops.\n", .{ traversal_result.paths.len, depth });
}

// Legacy command implementations for backward compatibility
fn execute_legacy_status_command(context: *ExecutionContext, status_cmd: commands.StatusCommand) !void {
    const data_dir = status_cmd.data_dir orelse context.data_dir;

    try context.ensure_storage_initialized();

    write_stdout("=== KausalDB Status ===\n");
    print_stdout(context.allocator, "Data directory: {s}\n", .{data_dir});
    write_stdout("(Legacy status command - consider using 'workspace' instead)\n");
}

fn execute_legacy_list_blocks_command(context: *ExecutionContext, list_cmd: commands.ListBlocksCommand) !void {
    try context.ensure_query_initialized();

    const limit = list_cmd.limit orelse 10;
    print_stdout(context.allocator, "=== Block Listing (limit: {}) ===\n", .{limit});
    write_stdout("(Legacy list-blocks command - implementation pending)\n");
}

fn execute_legacy_query_command(context: *ExecutionContext, query_cmd: commands.QueryCommand) !void {
    try context.ensure_query_initialized();

    if (query_cmd.block_id) |id| {
        print_stdout(context.allocator, "Query by ID: {s}\n", .{id});
    }

    if (query_cmd.content_pattern) |pattern| {
        print_stdout(context.allocator, "Query by content pattern: {s}\n", .{pattern});
    }

    write_stdout("(Legacy query command - implementation pending)\n");
}

fn execute_legacy_analyze_command(context: *ExecutionContext) !void {
    try context.ensure_workspace_initialized();

    write_stdout("=== Legacy Analysis Command ===\n");
    write_stdout("This command has been replaced by workspace management.\n");
    write_stdout("Try: kausaldb link . && kausaldb workspace\n");
}
