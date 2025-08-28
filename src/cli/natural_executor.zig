//! Natural language command executor for KausalDB.
//!
//! Executes parsed natural language commands using workspace management
//! and semantic query APIs. Provides JSON output support and structured
//! error handling with helpful user guidance.
//!
//! Design rationale: Separates command parsing from execution to enable
//! testing of command logic independently from argument parsing.

const std = @import("std");

const assert_mod = @import("../core/assert.zig");
const error_context = @import("../core/error_context.zig");
const memory = @import("../core/memory.zig");
const natural_commands = @import("natural_commands.zig");
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
const NaturalCommand = natural_commands.NaturalCommand;
const OutputFormat = natural_commands.OutputFormat;
const ProductionVFS = production_vfs.ProductionVFS;
const QueryEngine = query_engine.QueryEngine;
const StorageEngine = storage.StorageEngine;
const VFS = vfs.VFS;
const WorkspaceManager = workspace_manager.WorkspaceManager;

/// Execution context for natural language commands
pub const NaturalExecutionContext = struct {
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    vfs: VFS,
    coordinator: *ArenaCoordinator,

    // Optional subsystems - initialized on demand
    storage_engine: ?*StorageEngine,
    query_engine: ?*QueryEngine,
    workspace_manager: ?*WorkspaceManager,

    pub fn init(allocator: std.mem.Allocator, data_dir: []const u8) !NaturalExecutionContext {
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

        return NaturalExecutionContext{
            .allocator = allocator,
            .data_dir = absolute_data_dir,
            .vfs = prod_vfs.vfs(),
            .coordinator = coordinator,
            .storage_engine = null,
            .query_engine = null,
            .workspace_manager = null,
        };
    }

    pub fn deinit(self: *NaturalExecutionContext) void {
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
        const prod_vfs: *ProductionVFS = @ptrCast(@alignCast(self.vfs.ptr));
        self.allocator.destroy(prod_vfs);

        self.coordinator.arena.deinit();
        self.allocator.destroy(self.coordinator.arena);
        self.allocator.destroy(self.coordinator);

        // Free the allocated data directory path
        self.allocator.free(self.data_dir);
    }

    fn ensure_storage_initialized(self: *NaturalExecutionContext) !void {
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

    fn ensure_query_initialized(self: *NaturalExecutionContext) !void {
        try self.ensure_storage_initialized();
        if (self.query_engine != null) return;

        const engine = try self.allocator.create(QueryEngine);
        engine.* = QueryEngine.init(self.allocator, self.storage_engine.?);
        engine.startup();
        self.query_engine = engine;
    }

    fn ensure_workspace_initialized(self: *NaturalExecutionContext) !void {
        try self.ensure_storage_initialized();
        if (self.workspace_manager != null) return;

        const manager = try self.allocator.create(WorkspaceManager);
        manager.* = try WorkspaceManager.init(self.allocator, self.storage_engine.?);
        try manager.startup();
        self.workspace_manager = manager;
    }
};

/// Execute a natural language command
pub fn execute_natural_command(
    context: *NaturalExecutionContext,
    command: NaturalCommand,
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
    }
}

// === Command Implementations ===

fn execute_version_command() void {
    write_stdout("KausalDB v0.1.0\n");
}

fn execute_help_command(cmd: NaturalCommand.HelpCommand) void {
    if (cmd.topic) |topic| {
        show_command_help(topic);
    } else {
        show_general_help();
    }
}

fn execute_link_command(context: *NaturalExecutionContext, cmd: NaturalCommand.LinkCommand) !void {
    try context.ensure_workspace_initialized();
    const workspace = context.workspace_manager.?;

    // Resolve path to absolute path for consistent storage
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const resolved_path = std.fs.cwd().realpath(cmd.path, &path_buffer) catch |err| switch (err) {
        error.FileNotFound => {
            if (cmd.format == .json) {
                print_json_stdout(context.allocator,
                    \\{{"error": "Path '{s}' does not exist"}}
                , .{cmd.path});
            } else {
                print_stderr("Error: Path '{s}' does not exist\n", .{cmd.path});
            }
            return;
        },
        else => return err,
    };

    workspace.link_codebase(resolved_path, cmd.name) catch |err| switch (err) {
        workspace_manager.WorkspaceError.CodebaseAlreadyLinked => {
            if (cmd.format == .json) {
                print_json_stdout(context.allocator,
                    \\{{"error": "Codebase is already linked. Use 'kausaldb unlink {s}' first if you want to re-link it."}}
                , .{std.fs.path.basename(resolved_path)});
            } else {
                print_stderr("Error: Codebase is already linked\n", .{});
                print_stderr("Use 'kausaldb unlink {s}' first if you want to re-link it.\n", .{std.fs.path.basename(resolved_path)});
            }
            return;
        },
        workspace_manager.WorkspaceError.InvalidCodebasePath => {
            if (cmd.format == .json) {
                print_json_stdout(context.allocator,
                    \\{{"error": "Invalid codebase path '{s}'"}}
                , .{resolved_path});
            } else {
                print_stderr("Error: Invalid codebase path '{s}'\n", .{resolved_path});
            }
            return;
        },
        storage.StorageError.WriteBlocked => {
            // WriteBlocked should not occur in single-threaded CLI usage.
            // This indicates a storage engine configuration or compaction issue.
            // TODO: Re-enable fatal_assert after fixing compaction logic
            if (cmd.format == .json) {
                print_json_stdout(context.allocator,
                    \\{{"error": "Storage compaction issue - WriteBlocked in single-threaded context"}}
                , .{});
            } else {
                print_stderr("Error: Storage engine misconfiguration - WriteBlocked in single-threaded context\n", .{});
                print_stderr("This indicates a compaction logic issue that needs fixing.\n", .{});
            }
            return;
        },
        else => {
            if (cmd.format == .json) {
                print_json_stdout(context.allocator,
                    \\{{"error": "Failed to link codebase. Storage error occurred."}}
                , .{});
            } else {
                print_stderr("Error: Failed to link codebase '{s}'\n", .{resolved_path});
                print_stderr("This may be due to a storage issue. Please try again.\n", .{});
            }
            return;
        },
    };

    const actual_name = cmd.name orelse std.fs.path.basename(resolved_path);

    if (cmd.format == .json) {
        print_json_stdout(context.allocator,
            \\{{"status": "linked", "name": "{s}", "path": "{s}"}}
        , .{ actual_name, resolved_path });
    } else {
        print_stdout(context.allocator, "Linked codebase '{s}' from {s}\n", .{ actual_name, resolved_path });
        write_stdout("Indexing in progress...\n");
    }
}

fn execute_unlink_command(context: *NaturalExecutionContext, cmd: NaturalCommand.UnlinkCommand) !void {
    try context.ensure_workspace_initialized();
    const workspace = context.workspace_manager.?;

    workspace.unlink_codebase(cmd.name) catch |err| switch (err) {
        workspace_manager.WorkspaceError.CodebaseNotFound => {
            if (cmd.format == .json) {
                print_json_stdout(context.allocator,
                    \\{{"error": "Codebase '{s}' not found"}}
                , .{cmd.name});
            } else {
                print_stderr("Error: Codebase '{s}' not found\n", .{cmd.name});
                write_stdout("Use 'kausaldb workspace' to see linked codebases\n");
            }
            return;
        },
        storage.StorageError.WriteBlocked => {
            // WriteBlocked should not occur in single-threaded CLI usage.
            // This indicates a storage engine configuration or compaction issue.
            // TODO: Re-enable fatal_assert after fixing compaction logic
            if (cmd.format == .json) {
                print_json_stdout(context.allocator,
                    \\{{"error": "Storage compaction issue - WriteBlocked in single-threaded context"}}
                , .{});
            } else {
                print_stderr("Error: Storage engine misconfiguration - WriteBlocked in single-threaded context\n", .{});
                print_stderr("This indicates a compaction logic issue that needs fixing.\n", .{});
            }
            return;
        },
        else => {
            if (cmd.format == .json) {
                print_json_stdout(context.allocator,
                    \\{{"error": "Failed to unlink codebase '{s}'. Storage error occurred."}}
                , .{cmd.name});
            } else {
                print_stderr("Error: Failed to unlink codebase '{s}'\n", .{cmd.name});
                print_stderr("This may be due to storage being busy. Please try again.\n", .{});
            }
            return;
        },
    };

    if (cmd.format == .json) {
        print_json_stdout(context.allocator,
            \\{{"status": "unlinked", "name": "{s}"}}
        , .{cmd.name});
    } else {
        print_stdout(context.allocator, "Unlinked codebase '{s}'\n", .{cmd.name});
    }
}

fn execute_sync_command(context: *NaturalExecutionContext, cmd: NaturalCommand.SyncCommand) !void {
    try context.ensure_workspace_initialized();
    const workspace = context.workspace_manager.?;

    if (cmd.all) {
        // Sync all codebases
        const codebases = try workspace.list_linked_codebases(context.allocator);
        defer context.allocator.free(codebases);

        if (cmd.format == .json) {
            write_stdout("[\n");
            for (codebases, 0..) |codebase_info, i| {
                try workspace.sync_codebase(codebase_info.name);
                print_json_stdout(context.allocator,
                    \\  {{"status": "synced", "name": "{s}"}}
                , .{codebase_info.name});
                if (i < codebases.len - 1) write_stdout(",");
                write_stdout("\n");
            }
            write_stdout("]\n");
        } else {
            print_stdout(context.allocator, "Syncing {} codebases...\n", .{codebases.len});
            for (codebases) |codebase_info| {
                try workspace.sync_codebase(codebase_info.name);
                print_stdout(context.allocator, "✓ Synced '{s}'\n", .{codebase_info.name});
            }
        }
    } else if (cmd.name) |name| {
        // Sync specific codebase
        workspace.sync_codebase(name) catch |err| switch (err) {
            workspace_manager.WorkspaceError.CodebaseNotFound => {
                if (cmd.format == .json) {
                    print_json_stdout(context.allocator,
                        \\{{"error": "Codebase '{s}' not found"}}
                    , .{name});
                } else {
                    print_stderr("Error: Codebase '{s}' not found\n", .{name});
                }
                return;
            },
            else => return err,
        };

        if (cmd.format == .json) {
            print_json_stdout(context.allocator,
                \\{{"status": "synced", "name": "{s}"}}
            , .{name});
        } else {
            print_stdout(context.allocator, "Synced codebase '{s}'\n", .{name});
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
                print_json_stdout(context.allocator,
                    \\{{"status": "synced", "name": "{s}"}}
                , .{name});
            } else {
                print_stdout(context.allocator, "Synced codebase '{s}'\n", .{name});
            }
        } else {
            if (cmd.format == .json) {
                write_stdout("{\"error\": \"No linked codebase found for current directory\"}\n");
            } else {
                write_stdout("No linked codebase found for current directory\n");
                write_stdout("Use 'kausal link .' to link this directory\n");
            }
        }
    }
}

fn execute_status_command(context: *NaturalExecutionContext, cmd: NaturalCommand.StatusCommand) !void {
    try context.ensure_workspace_initialized();
    const workspace = context.workspace_manager.?;

    const codebases = try workspace.list_linked_codebases(context.allocator);
    defer context.allocator.free(codebases);

    if (cmd.format == .json) {
        write_stdout("{\n");
        write_stdout("  \"workspace\": [\n");
        for (codebases, 0..) |codebase_info, i| {
            print_json_stdout(context.allocator,
                \\    {{"name": "{s}", "path": "{s}", "blocks": {}, "edges": {}}}
            , .{ codebase_info.name, codebase_info.path, codebase_info.block_count, codebase_info.edge_count });
            if (i < codebases.len - 1) write_stdout(",");
            write_stdout("\n");
        }
        write_stdout("  ]\n}\n");
    } else {
        write_stdout("WORKSPACE\n");
        if (codebases.len == 0) {
            write_stdout("No codebases linked\n\n");
            write_stdout("Use 'kausal link <path>' to link a codebase\n");
        } else {
            for (codebases) |codebase_info| {
                print_stdout(context.allocator, "- {s} (linked from {s})\n", .{ codebase_info.name, codebase_info.path });
                const minutes_ago = @as(u64, @intCast(std.time.timestamp() - codebase_info.last_sync_timestamp)) / 60;
                if (minutes_ago == 0) {
                    write_stdout("  Last synced: Just now\n");
                } else {
                    print_stdout(context.allocator, "  Last synced: {} minutes ago\n", .{minutes_ago});
                }
                print_stdout(context.allocator, "  Blocks: {} | Edges: {}\n\n", .{ codebase_info.block_count, codebase_info.edge_count });
            }
        }
    }
}

fn execute_find_command(context: *NaturalExecutionContext, cmd: NaturalCommand.FindCommand) !void {
    try context.ensure_query_initialized();
    const query_eng = context.query_engine.?;

    // Entity type validation prevents unsupported queries from reaching storage
    if (!natural_commands.validate_entity_type(cmd.entity_type)) {
        if (cmd.format == .json) {
            print_json_stdout(context.allocator,
                \\{{"error": "Invalid entity type '{s}'"}}
            , .{cmd.entity_type});
        } else {
            print_stderr("Error: Invalid entity type '{s}'\n", .{cmd.entity_type});
            write_stdout("Valid types: function, struct, test, method, const, var, type\n");
        }
        return;
    }

    const workspace = cmd.workspace orelse "default";

    const search_result = query_eng.find_by_name(workspace, cmd.entity_type, cmd.name) catch |err| switch (err) {
        query_engine.QueryError.SemanticSearchUnavailable => {
            if (cmd.format == .json) {
                write_stdout("{\"error\": \"Semantic search not available\"}\n");
            } else {
                write_stdout("Semantic search is not available yet.\n");
                write_stdout("Make sure codebases are linked and synced.\n");
            }
            return;
        },
        else => return err,
    };
    defer search_result.deinit();

    if (cmd.format == .json) {
        write_stdout("{\n");
        print_stdout(context.allocator, "  \"query\": {{\"type\": \"{s}\", \"name\": \"{s}\", \"workspace\": \"{s}\"}},\n", .{ cmd.entity_type, cmd.name, workspace });
        print_stdout(context.allocator, "  \"total_matches\": {},\n", .{search_result.total_matches});
        write_stdout("  \"results\": [\n");
        for (search_result.results, 0..) |result, i| {
            const block = result.block.block;
            print_json_stdout(context.allocator,
                \\    {{"name": "{s}", "source": "{s}", "similarity": {d:.3}}}
            , .{ extract_entity_name(block), block.source_uri, result.similarity_score });
            if (i < search_result.results.len - 1) write_stdout(",");
            write_stdout("\n");
        }
        write_stdout("  ]\n}\n");
    } else {
        if (search_result.total_matches == 0) {
            print_stdout(context.allocator, "No {s} named '{s}' found", .{ cmd.entity_type, cmd.name });
            if (cmd.workspace) |ws| {
                print_stdout(context.allocator, " in workspace '{s}'", .{ws});
            }
            write_stdout(".\n");
        } else {
            print_stdout(context.allocator, "Found {} {s} named '{s}'", .{ search_result.total_matches, cmd.entity_type, cmd.name });
            if (cmd.workspace) |ws| {
                print_stdout(context.allocator, " in workspace '{s}'", .{ws});
            }
            write_stdout(":\n\n");

            for (search_result.results, 0..) |result, i| {
                const block = result.block.block;
                print_stdout(context.allocator, "{}. {s} (similarity: {d:.3})\n", .{ i + 1, extract_entity_name(block), result.similarity_score });
                print_stdout(context.allocator, "   Source: {s}\n", .{block.source_uri});

                if (block.content.len > 0) {
                    const preview = if (block.content.len > 100)
                        try std.fmt.allocPrint(context.allocator, "{s}...", .{block.content[0..100]})
                    else
                        try context.allocator.dupe(u8, block.content);
                    defer context.allocator.free(preview);

                    print_stdout(context.allocator, "   Preview: {s}\n", .{preview});
                }
                write_stdout("\n");
            }
        }
    }
}

fn execute_show_command(context: *NaturalExecutionContext, cmd: NaturalCommand.ShowCommand) !void {
    try context.ensure_query_initialized();
    _ = context.query_engine.?;

    // Relation validation ensures only supported graph traversal patterns
    if (!natural_commands.validate_relation_type(cmd.relation_type)) {
        if (cmd.format == .json) {
            print_json_stdout(context.allocator,
                \\{{"error": "Invalid relation type '{s}'"}}
            , .{cmd.relation_type});
        } else {
            print_stderr("Error: Invalid relation type '{s}'\n", .{cmd.relation_type});
            write_stdout("Valid relations: callers, callees, references\n");
        }
        return;
    }

    // For now, return helpful message since this requires target resolution
    if (cmd.format == .json) {
        print_json_stdout(context.allocator,
            \\{{"message": "Show {s} of '{s}' - implementation in progress"}}
        , .{ cmd.relation_type, cmd.target });
    } else {
        print_stdout(context.allocator, "Showing {s} of '{s}' - implementation in progress\n", .{ cmd.relation_type, cmd.target });
        write_stdout("This requires first finding the target entity, then traversing relationships.\n");
    }
}

fn execute_trace_command(context: *NaturalExecutionContext, cmd: NaturalCommand.TraceCommand) !void {
    try context.ensure_query_initialized();
    _ = context.query_engine.?;

    // Direction validation prevents invalid multi-hop traversal requests
    if (!natural_commands.validate_direction(cmd.direction)) {
        if (cmd.format == .json) {
            print_json_stdout(context.allocator,
                \\{{"error": "Invalid direction '{s}'"}}
            , .{cmd.direction});
        } else {
            print_stderr("Error: Invalid direction '{s}'\n", .{cmd.direction});
            write_stdout("Valid directions: callers, callees, both, references\n");
        }
        return;
    }

    const depth = cmd.depth orelse 3;

    // For now, return helpful message since this requires target resolution
    if (cmd.format == .json) {
        print_json_stdout(context.allocator,
            \\{{"message": "Trace {s} from '{s}' depth {} - implementation in progress"}}
        , .{ cmd.direction, cmd.target, depth });
    } else {
        print_stdout(context.allocator, "Tracing {s} from '{s}' (depth: {}) - implementation in progress\n", .{ cmd.direction, cmd.target, depth });
        write_stdout("This requires first finding the target entity, then performing graph traversal.\n");
    }
}

// === Helper Functions ===

fn write_stdout(text: []const u8) void {
    const stdout = std.fs.File{ .handle = 1 };
    _ = stdout.writeAll(text) catch {};
}

fn print_stdout(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(text);
    write_stdout(text);
}

fn print_stderr(comptime fmt: []const u8, args: anytype) void {
    const stderr = std.fs.File{ .handle = 2 };
    const text = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch return;
    defer std.heap.page_allocator.free(text);
    _ = stderr.writeAll(text) catch {};
}

fn print_json_stdout(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(text);
    write_stdout(text);
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
    write_stdout(
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
        \\Options:
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
        write_stdout(
            \\Usage: kausal link <path> [as <name>] [--json]
            \\
            \\Link a codebase directory to your KausalDB workspace for indexing and queries.
            \\
            \\Arguments:
            \\  <path>        Directory path to link (can be relative or absolute)
            \\  as <name>     Optional custom name for the codebase
            \\
            \\Options:
            \\  --json        Output result in JSON format
            \\
            \\Examples:
            \\  kausal link .                     # Link current directory
            \\  kausal link ../other-project      # Link relative path
            \\  kausal link /abs/path as backend  # Link with custom name
            \\
        );
    } else if (std.mem.eql(u8, topic, "find")) {
        write_stdout(
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
            \\  kausal find function "init"              # Find all functions named "init"
            \\  kausal find struct "ContextBlock"        # Find struct definitions
            \\  kausal find test "parsing" in myproject  # Find tests in specific workspace
            \\
        );
    } else {
        print_stdout(std.heap.page_allocator, "No help available for topic: {s}\n", .{topic});
        write_stdout("Available topics: link, find, show, trace, sync, status\n");
    }
}
