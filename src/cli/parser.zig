//! Ccommand-line argument parser for CLI.
//!
//! Transforms raw command-line arguments into structured command types.
//! Zero allocations for parsing, all validation happens at parse time.

const std = @import("std");

const types = @import("../core/types.zig");

/// Output format for command results
pub const OutputFormat = enum {
    text,
    json,
    csv,
};

/// Parse error types
pub const ParseError = error{
    UnknownCommand,
    MissingArgument,
    InvalidArgument,
    TooManyArguments,
    InvalidFormat,
    InvalidNumber,
    PathTooLong,
    QueryTooLong,
};

/// Global options that apply to all commands
pub const GlobalOptions = struct {
    port: ?u16 = null,
    host: ?[]const u8 = null,
};

/// Top-level command enumeration
pub const Command = union(enum) {
    // Core commands
    help: HelpCommand,
    version: VersionCommand,
    server: ServerCommand,
    status: StatusCommand,
    ping: PingCommand,

    // Query commands
    find: FindCommand,
    show: ShowCommand,
    trace: TraceCommand,

    // Workspace commands
    link: LinkCommand,
    unlink: UnlinkCommand,
    sync: SyncCommand,
};

/// Help command structure
pub const HelpCommand = struct {
    topic: ?[]const u8 = null,
};

/// Version command structure
pub const VersionCommand = struct {};

/// Ping command structure
pub const PingCommand = struct {};

/// Server command structure
pub const ServerCommand = struct {
    mode: ServerMode = .start,
    host: []const u8 = "127.0.0.1",
    port: u16 = 3838,
    data_dir: []const u8 = ".kausal-data",

    pub const ServerMode = enum {
        start,
        stop,
        restart,
        status,
    };
};

/// Status command structure
pub const StatusCommand = struct {
    format: OutputFormat = .text,
    verbose: bool = false,
};

/// Find command structure
pub const FindCommand = struct {
    type: EntityType = .function,
    name: []const u8,
    workspace: ?[]const u8 = null,
    format: OutputFormat = .text,
    max_results: u16 = 10,
    show_metadata: bool = false,

    pub const EntityType = enum {
        function,
        struct_type,
        constant,
        variable,
    };
};

/// Show command structure
pub const ShowCommand = struct {
    direction: Direction,
    target: []const u8,
    workspace: ?[]const u8 = null,
    format: OutputFormat = .text,
    max_depth: u16 = 3,

    pub const Direction = enum {
        callers,
        callees,
        imports,
        exports,
    };
};

/// Trace command structure
pub const TraceCommand = struct {
    direction: Direction,
    target: []const u8,
    workspace: ?[]const u8 = null,
    format: OutputFormat = .text,
    max_depth: u16 = 10,
    all_paths: bool = false,

    pub const Direction = enum {
        callers,
        callees,
    };
};

/// Link command structure
pub const LinkCommand = struct {
    path: []const u8,
    name: ?[]const u8 = null,
    format: OutputFormat = .text,
};

/// Unlink command structure
pub const UnlinkCommand = struct {
    name: []const u8,
    format: OutputFormat = .text,
};

/// Sync command structure
pub const SyncCommand = struct {
    name: ?[]const u8 = null,
    force: bool = false,
    all: bool = false,
    format: OutputFormat = .text,
};

/// Parse result containing command and global options
pub const ParseResult = struct {
    command: Command,
    global_options: GlobalOptions,
};

/// Parse command-line arguments into structured commands
pub fn parse_command(args: []const []const u8) ParseError!Command {
    const result = try parse_command_with_globals(args);
    return result.command;
}

/// Parse command-line arguments with global options
pub fn parse_command_with_globals(args: []const []const u8) ParseError!ParseResult {
    if (args.len < 2) {
        return ParseResult{
            .command = Command{ .help = HelpCommand{} },
            .global_options = GlobalOptions{},
        };
    }

    var global_options = GlobalOptions{};
    var command_start: usize = 1;

    // Parse global options before command
    while (command_start < args.len and std.mem.startsWith(u8, args[command_start], "--")) {
        const arg = args[command_start];
        if (std.mem.eql(u8, arg, "--port")) {
            command_start += 1;
            if (command_start >= args.len) return ParseError.MissingArgument;
            global_options.port = std.fmt.parseInt(u16, args[command_start], 10) catch return ParseError.InvalidNumber;
            command_start += 1;
        } else if (std.mem.eql(u8, arg, "--host")) {
            command_start += 1;
            if (command_start >= args.len) return ParseError.MissingArgument;
            global_options.host = args[command_start];
            command_start += 1;
        } else {
            break; // Not a global option, must be start of command
        }
    }

    if (command_start >= args.len) {
        return ParseResult{
            .command = Command{ .help = HelpCommand{} },
            .global_options = global_options,
        };
    }

    const command_str = args[command_start];
    const remaining_args = args[command_start + 1 ..];

    // Parse based on command name
    const command = if (std.mem.eql(u8, command_str, "help"))
        Command{ .help = try parse_help(remaining_args) }
    else if (std.mem.eql(u8, command_str, "version"))
        Command{ .version = try parse_version(remaining_args) }
    else if (std.mem.eql(u8, command_str, "server"))
        Command{ .server = try parse_server(remaining_args) }
    else if (std.mem.eql(u8, command_str, "status"))
        Command{ .status = try parse_status(remaining_args) }
    else if (std.mem.eql(u8, command_str, "ping"))
        Command{ .ping = try parse_ping(remaining_args) }
    else if (std.mem.eql(u8, command_str, "find"))
        Command{ .find = try parse_find(remaining_args) }
    else if (std.mem.eql(u8, command_str, "show"))
        Command{ .show = try parse_show(remaining_args) }
    else if (std.mem.eql(u8, command_str, "trace"))
        Command{ .trace = try parse_trace(remaining_args) }
    else if (std.mem.eql(u8, command_str, "link"))
        Command{ .link = try parse_link(remaining_args) }
    else if (std.mem.eql(u8, command_str, "unlink"))
        Command{ .unlink = try parse_unlink(remaining_args) }
    else if (std.mem.eql(u8, command_str, "sync"))
        Command{ .sync = try parse_sync(remaining_args) }
    else
        return ParseError.UnknownCommand;

    return ParseResult{
        .command = command,
        .global_options = global_options,
    };
}

fn parse_help(args: []const []const u8) ParseError!HelpCommand {
    if (args.len > 1) return ParseError.TooManyArguments;

    return HelpCommand{
        .topic = if (args.len == 1) args[0] else null,
    };
}

fn parse_version(args: []const []const u8) ParseError!VersionCommand {
    if (args.len > 0) return ParseError.TooManyArguments;
    return VersionCommand{};
}

fn parse_server(args: []const []const u8) ParseError!ServerCommand {
    var cmd = ServerCommand{};
    var i: usize = 0;

    if (i < args.len and !std.mem.startsWith(u8, args[i], "--")) {
        const mode_str = args[i];
        if (std.mem.eql(u8, mode_str, "start")) {
            cmd.mode = .start;
        } else if (std.mem.eql(u8, mode_str, "stop")) {
            cmd.mode = .stop;
        } else if (std.mem.eql(u8, mode_str, "restart")) {
            cmd.mode = .restart;
        } else if (std.mem.eql(u8, mode_str, "status")) {
            cmd.mode = .status;
        } else {
            return ParseError.InvalidArgument;
        }
        i += 1;
    }

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.host = args[i];
        } else if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.port = std.fmt.parseInt(u16, args[i], 10) catch return ParseError.InvalidNumber;
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.data_dir = args[i];
        } else {
            return ParseError.InvalidArgument;
        }
    }

    return cmd;
}

fn parse_status(args: []const []const u8) ParseError!StatusCommand {
    var cmd = StatusCommand{};
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.format = try parse_output_format(args[i]);
        } else if (std.mem.eql(u8, arg, "--json")) {
            cmd.format = .json;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            cmd.verbose = true;
        } else {
            return ParseError.InvalidArgument;
        }
    }

    return cmd;
}

fn parse_ping(args: []const []const u8) ParseError!PingCommand {
    _ = args; // Ping command doesn't need any arguments
    return PingCommand{};
}

fn parse_find(args: []const []const u8) ParseError!FindCommand {
    var cmd = FindCommand{
        .name = "", // Will be set
    };
    var i: usize = 0;

    // Parse flags
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--type")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.type = parse_entity_type(args[i]) catch return ParseError.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--name")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.name = args[i];
        } else if (std.mem.eql(u8, arg, "--workspace")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.workspace = args[i];
        } else if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.format = try parse_output_format(args[i]);
        } else if (std.mem.eql(u8, arg, "--max-results")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.max_results = std.fmt.parseInt(u16, args[i], 10) catch return ParseError.InvalidNumber;
        } else if (std.mem.eql(u8, arg, "--show-metadata")) {
            cmd.show_metadata = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            cmd.format = .json;
        } else {
            return ParseError.InvalidArgument;
        }
    }

    // Validate required arguments
    if (cmd.name.len == 0) {
        return ParseError.MissingArgument;
    }

    return cmd;
}

fn parse_show(args: []const []const u8) ParseError!ShowCommand {
    var cmd = ShowCommand{
        .direction = undefined, // Will be set
        .target = "", // Will be set
    };
    var i: usize = 0;
    var direction_set = false;
    var target_set = false;

    // Parse flags
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--relation")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.direction = parse_show_direction(args[i]) catch return ParseError.InvalidArgument;
            direction_set = true;
        } else if (std.mem.eql(u8, arg, "--target")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.target = args[i];
            target_set = true;
        } else if (std.mem.eql(u8, arg, "--workspace")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.workspace = args[i];
        } else if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.format = try parse_output_format(args[i]);
        } else if (std.mem.eql(u8, arg, "--max-depth")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.max_depth = std.fmt.parseInt(u16, args[i], 10) catch return ParseError.InvalidNumber;
        } else if (std.mem.eql(u8, arg, "--json")) {
            cmd.format = .json;
        } else {
            return ParseError.InvalidArgument;
        }
    }

    // Validate required arguments
    if (!direction_set or !target_set) {
        return ParseError.MissingArgument;
    }

    return cmd;
}

fn parse_trace(args: []const []const u8) ParseError!TraceCommand {
    var cmd = TraceCommand{
        .direction = undefined, // Will be set
        .target = "", // Will be set
    };
    var i: usize = 0;
    var direction_set = false;
    var target_set = false;

    // Parse flags
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--direction")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.direction = parse_trace_direction(args[i]) catch return ParseError.InvalidArgument;
            direction_set = true;
        } else if (std.mem.eql(u8, arg, "--target") or std.mem.eql(u8, arg, "--from")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.target = args[i];
            target_set = true;
        } else if (std.mem.eql(u8, arg, "--workspace")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.workspace = args[i];
        } else if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.format = try parse_output_format(args[i]);
        } else if (std.mem.eql(u8, arg, "--max-depth") or std.mem.eql(u8, arg, "--depth")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.max_depth = std.fmt.parseInt(u16, args[i], 10) catch return ParseError.InvalidNumber;
        } else if (std.mem.eql(u8, arg, "--all-paths")) {
            cmd.all_paths = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            cmd.format = .json;
        } else {
            return ParseError.InvalidArgument;
        }
    }

    // Validate required arguments
    if (!direction_set or !target_set) {
        return ParseError.MissingArgument;
    }

    return cmd;
}

fn parse_link(args: []const []const u8) ParseError!LinkCommand {
    var cmd = LinkCommand{
        .path = "", // Will be set
    };
    var i: usize = 0;
    var path_set = false;

    // Parse flags
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--path")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.path = args[i];
            path_set = true;
        } else if (std.mem.eql(u8, arg, "--name")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.name = args[i];
        } else if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.format = try parse_output_format(args[i]);
        } else {
            return ParseError.InvalidArgument;
        }
    }

    // Validate required arguments
    if (!path_set) {
        return ParseError.MissingArgument;
    }

    return cmd;
}

fn parse_unlink(args: []const []const u8) ParseError!UnlinkCommand {
    var cmd = UnlinkCommand{
        .name = "", // Will be set
    };
    var i: usize = 0;
    var name_set = false;

    // Parse flags
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--name")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.name = args[i];
            name_set = true;
        } else if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.format = try parse_output_format(args[i]);
        } else {
            return ParseError.InvalidArgument;
        }
    }

    // Validate required arguments
    if (!name_set) {
        return ParseError.MissingArgument;
    }

    return cmd;
}

fn parse_sync(args: []const []const u8) ParseError!SyncCommand {
    var cmd = SyncCommand{};
    var i: usize = 0;

    // Optional workspace name
    if (i < args.len and !std.mem.startsWith(u8, args[i], "--")) {
        cmd.name = args[i];
        i += 1;
    }

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--force")) {
            cmd.force = true;
        } else if (std.mem.eql(u8, arg, "--all")) {
            cmd.all = true;
        } else if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.format = try parse_output_format(args[i]);
        } else {
            return ParseError.InvalidArgument;
        }
    }

    return cmd;
}

fn parse_output_format(str: []const u8) ParseError!OutputFormat {
    if (std.mem.eql(u8, str, "text")) {
        return .text;
    } else if (std.mem.eql(u8, str, "json")) {
        return .json;
    } else if (std.mem.eql(u8, str, "csv")) {
        return .csv;
    } else {
        return ParseError.InvalidFormat;
    }
}

fn parse_entity_type(str: []const u8) ParseError!FindCommand.EntityType {
    if (std.mem.eql(u8, str, "function")) {
        return .function;
    } else if (std.mem.eql(u8, str, "struct")) {
        return .struct_type;
    } else if (std.mem.eql(u8, str, "constant")) {
        return .constant;
    } else if (std.mem.eql(u8, str, "variable")) {
        return .variable;
    } else {
        return ParseError.InvalidArgument;
    }
}

fn parse_show_direction(str: []const u8) ParseError!ShowCommand.Direction {
    if (std.mem.eql(u8, str, "callers")) {
        return .callers;
    } else if (std.mem.eql(u8, str, "callees")) {
        return .callees;
    } else if (std.mem.eql(u8, str, "imports")) {
        return .imports;
    } else if (std.mem.eql(u8, str, "exports")) {
        return .exports;
    } else {
        return ParseError.InvalidArgument;
    }
}

fn parse_trace_direction(str: []const u8) ParseError!TraceCommand.Direction {
    if (std.mem.eql(u8, str, "callers")) {
        return .callers;
    } else if (std.mem.eql(u8, str, "callees")) {
        return .callees;
    } else {
        return ParseError.InvalidArgument;
    }
}
