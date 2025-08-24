//! Structured command parsing for KausalDB CLI.
//!
//! Implements type-safe command parsing with clear validation and execution flow.
//! Commands are parsed into structured types that eliminate runtime string
//! comparisons and enable compile-time validation of command arguments.
//!
//! Design rationale: Replace ad-hoc string matching with structured parsing
//! to reduce bugs and improve maintainability as command surface grows.

const std = @import("std");

const assert_mod = @import("../core/assert.zig");
const workspace_manager = @import("../workspace/manager.zig");

const assert = assert_mod.assert;
const fatal_assert = assert_mod.fatal_assert;
const WorkspaceManager = workspace_manager.WorkspaceManager;

pub const CommandError = error{
    UnknownCommand,
    InvalidArguments,
    MissingRequiredArgument,
    TooManyArguments,
} || std.mem.Allocator.Error;

/// Top-level command categories
pub const Command = union(enum) {
    version: VersionCommand,
    help: HelpCommand,
    server: ServerCommand,
    demo: DemoCommand,
    workspace: WorkspaceCommand,
    find: FindCommand,
    show: ShowCommand,
    trace: TraceCommand,

    /// Legacy commands for backward compatibility
    status: StatusCommand,
    list_blocks: ListBlocksCommand,
    query: QueryCommand,
    analyze: AnalyzeCommand,
};

/// Version information display
pub const VersionCommand = struct {};

/// Help text display
pub const HelpCommand = struct {
    command_topic: ?[]const u8 = null,
};

/// Server startup with configuration
pub const ServerCommand = struct {
    port: ?u16 = null,
    data_dir: ?[]const u8 = null,
    config_file: ?[]const u8 = null,
};

/// Demo execution
pub const DemoCommand = struct {};

/// Workspace management commands
pub const WorkspaceCommand = union(enum) {
    link: LinkCommand,
    unlink: UnlinkCommand,
    status: WorkspaceStatusCommand,
    sync: SyncCommand,
};

/// Link codebase to workspace
pub const LinkCommand = struct {
    path: []const u8,
    name: ?[]const u8 = null,
};

/// Remove codebase from workspace
pub const UnlinkCommand = struct {
    name: []const u8,
};

/// Show workspace status and linked codebases
pub const WorkspaceStatusCommand = struct {};

/// Sync codebase with source changes
pub const SyncCommand = struct {
    name: ?[]const u8 = null, // null means sync all
};

/// Find entities by name and type (future implementation)
pub const FindCommand = struct {
    entity_type: []const u8,
    name: []const u8,
    workspace: ?[]const u8 = null,
};

/// Show relationships and references (future implementation)
pub const ShowCommand = struct {
    relation_type: []const u8,
    target: []const u8,
    workspace: ?[]const u8 = null,
};

/// Trace multi-hop relationships (future implementation)
pub const TraceCommand = struct {
    direction: []const u8,
    target: []const u8,
    depth: ?u32 = null,
    workspace: ?[]const u8 = null,
};

/// Legacy status command
pub const StatusCommand = struct {
    data_dir: ?[]const u8 = null,
};

/// Legacy list-blocks command
pub const ListBlocksCommand = struct {
    limit: ?u32 = null,
};

/// Legacy query command
pub const QueryCommand = struct {
    block_id: ?[]const u8 = null,
    content_pattern: ?[]const u8 = null,
};

/// Legacy analyze command
pub const AnalyzeCommand = struct {};

/// Command parsing result with structured data
pub const ParseResult = struct {
    command: Command,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ParseResult) void {
        // Commands don't currently allocate, but this enables future cleanup
        _ = self;
    }
};

/// Parse command line arguments into structured command types.
/// Returns error for invalid commands or malformed arguments.
pub fn parse_command(allocator: std.mem.Allocator, args: []const []const u8) !ParseResult {
    if (args.len < 2) {
        return ParseResult{
            .command = Command{ .help = HelpCommand{} },
            .allocator = allocator,
        };
    }

    const command_name = args[1];
    const command_args = args[2..];

    const command = if (std.mem.eql(u8, command_name, "version"))
        Command{ .version = VersionCommand{} }
    else if (std.mem.eql(u8, command_name, "help"))
        Command{ .help = try parse_help_command(command_args) }
    else if (std.mem.eql(u8, command_name, "server"))
        Command{ .server = try parse_server_command(command_args) }
    else if (std.mem.eql(u8, command_name, "demo"))
        Command{ .demo = try parse_demo_command(command_args) }
    else if (std.mem.eql(u8, command_name, "link"))
        Command{ .workspace = WorkspaceCommand{ .link = try parse_link_command(command_args) } }
    else if (std.mem.eql(u8, command_name, "unlink"))
        Command{ .workspace = WorkspaceCommand{ .unlink = try parse_unlink_command(command_args) } }
    else if (std.mem.eql(u8, command_name, "sync"))
        Command{ .workspace = WorkspaceCommand{ .sync = try parse_sync_command(command_args) } }
    else if (std.mem.eql(u8, command_name, "workspace"))
        Command{ .workspace = try parse_workspace_command(command_args) }
    else if (std.mem.eql(u8, command_name, "find"))
        Command{ .find = try parse_find_command(command_args) }
    else if (std.mem.eql(u8, command_name, "show"))
        Command{ .show = try parse_show_command(command_args) }
    else if (std.mem.eql(u8, command_name, "trace"))
        Command{ .trace = try parse_trace_command(command_args) }
    else if (std.mem.eql(u8, command_name, "status"))
        Command{ .status = try parse_status_command(command_args) }
    else if (std.mem.eql(u8, command_name, "list-blocks"))
        Command{ .list_blocks = try parse_list_blocks_command(command_args) }
    else if (std.mem.eql(u8, command_name, "query"))
        Command{ .query = try parse_query_command(command_args) }
    else if (std.mem.eql(u8, command_name, "analyze"))
        Command{ .analyze = try parse_analyze_command(command_args) }
    else
        return CommandError.UnknownCommand;

    return ParseResult{
        .command = command,
        .allocator = allocator,
    };
}

fn parse_help_command(args: []const []const u8) !HelpCommand {
    if (args.len > 1) return CommandError.TooManyArguments;

    return HelpCommand{
        .command_topic = if (args.len == 1) args[0] else null,
    };
}

fn parse_server_command(args: []const []const u8) !ServerCommand {
    var server_cmd = ServerCommand{};
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port")) {
            i += 1;
            if (i >= args.len) return CommandError.MissingRequiredArgument;
            server_cmd.port = std.fmt.parseInt(u16, args[i], 10) catch return CommandError.InvalidArguments;
        } else if (std.mem.eql(u8, args[i], "--data-dir")) {
            i += 1;
            if (i >= args.len) return CommandError.MissingRequiredArgument;
            server_cmd.data_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "--config")) {
            i += 1;
            if (i >= args.len) return CommandError.MissingRequiredArgument;
            server_cmd.config_file = args[i];
        } else {
            return CommandError.InvalidArguments;
        }
    }

    return server_cmd;
}

fn parse_demo_command(args: []const []const u8) !DemoCommand {
    if (args.len > 0) return CommandError.TooManyArguments;
    return DemoCommand{};
}

fn parse_link_command(args: []const []const u8) !LinkCommand {
    if (args.len == 0) return CommandError.MissingRequiredArgument;
    if (args.len > 3) return CommandError.TooManyArguments;

    var link_cmd = LinkCommand{
        .path = args[0],
    };

    // Handle "path as name" syntax
    if (args.len == 3 and std.mem.eql(u8, args[1], "as")) {
        link_cmd.name = args[2];
    } else if (args.len == 2) {
        return CommandError.InvalidArguments;
    }

    return link_cmd;
}

fn parse_unlink_command(args: []const []const u8) !UnlinkCommand {
    if (args.len != 1) return CommandError.MissingRequiredArgument;

    return UnlinkCommand{
        .name = args[0],
    };
}

fn parse_sync_command(args: []const []const u8) !SyncCommand {
    if (args.len > 1) return CommandError.TooManyArguments;

    return SyncCommand{
        .name = if (args.len == 1) args[0] else null,
    };
}

fn parse_workspace_command(args: []const []const u8) !WorkspaceCommand {
    if (args.len == 0) {
        return WorkspaceCommand{ .status = WorkspaceStatusCommand{} };
    }

    const subcommand = args[0];
    const subcommand_args = args[1..];

    if (std.mem.eql(u8, subcommand, "link")) {
        return WorkspaceCommand{ .link = try parse_link_command(subcommand_args) };
    } else if (std.mem.eql(u8, subcommand, "unlink")) {
        return WorkspaceCommand{ .unlink = try parse_unlink_command(subcommand_args) };
    } else if (std.mem.eql(u8, subcommand, "status")) {
        if (subcommand_args.len > 0) return CommandError.TooManyArguments;
        return WorkspaceCommand{ .status = WorkspaceStatusCommand{} };
    } else if (std.mem.eql(u8, subcommand, "sync")) {
        return WorkspaceCommand{ .sync = try parse_sync_command(subcommand_args) };
    } else {
        return CommandError.UnknownCommand;
    }
}

fn parse_find_command(args: []const []const u8) !FindCommand {
    // Future implementation - placeholder for now
    if (args.len < 2) return CommandError.MissingRequiredArgument;

    return FindCommand{
        .entity_type = args[0],
        .name = args[1],
        .workspace = if (args.len > 2) args[2] else null,
    };
}

fn parse_show_command(args: []const []const u8) !ShowCommand {
    // Future implementation - placeholder for now
    if (args.len < 2) return CommandError.MissingRequiredArgument;

    return ShowCommand{
        .relation_type = args[0],
        .target = args[1],
        .workspace = if (args.len > 2) args[2] else null,
    };
}

fn parse_trace_command(args: []const []const u8) !TraceCommand {
    // Future implementation - placeholder for now
    if (args.len < 2) return CommandError.MissingRequiredArgument;

    var trace_cmd = TraceCommand{
        .direction = args[0],
        .target = args[1],
    };

    // Parse optional depth argument
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--depth")) {
            i += 1;
            if (i >= args.len) return CommandError.MissingRequiredArgument;
            trace_cmd.depth = std.fmt.parseInt(u32, args[i], 10) catch return CommandError.InvalidArguments;
        }
    }

    return trace_cmd;
}

fn parse_status_command(args: []const []const u8) !StatusCommand {
    var status_cmd = StatusCommand{};
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--data-dir")) {
            i += 1;
            if (i >= args.len) return CommandError.MissingRequiredArgument;
            status_cmd.data_dir = args[i];
        } else {
            return CommandError.InvalidArguments;
        }
    }

    return status_cmd;
}

fn parse_list_blocks_command(args: []const []const u8) !ListBlocksCommand {
    var list_cmd = ListBlocksCommand{};
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--limit")) {
            i += 1;
            if (i >= args.len) return CommandError.MissingRequiredArgument;
            list_cmd.limit = std.fmt.parseInt(u32, args[i], 10) catch return CommandError.InvalidArguments;
        } else {
            return CommandError.InvalidArguments;
        }
    }

    return list_cmd;
}

fn parse_query_command(args: []const []const u8) !QueryCommand {
    var query_cmd = QueryCommand{};
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--id")) {
            i += 1;
            if (i >= args.len) return CommandError.MissingRequiredArgument;
            query_cmd.block_id = args[i];
        } else if (std.mem.eql(u8, args[i], "--content")) {
            i += 1;
            if (i >= args.len) return CommandError.MissingRequiredArgument;
            query_cmd.content_pattern = args[i];
        } else {
            return CommandError.InvalidArguments;
        }
    }

    return query_cmd;
}

fn parse_analyze_command(args: []const []const u8) !AnalyzeCommand {
    if (args.len > 0) return CommandError.TooManyArguments;
    return AnalyzeCommand{};
}
