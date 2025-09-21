//! Command-line argument parser for KausalDB CLI v2.
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
    query: []const u8,
    format: OutputFormat = .text,
    max_results: u16 = 10,
    show_metadata: bool = false,
};

/// Show command structure
pub const ShowCommand = struct {
    direction: Direction,
    target: []const u8,
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
    source: []const u8,
    target: []const u8,
    format: OutputFormat = .text,
    max_depth: u16 = 10,
    all_paths: bool = false,
};

/// Link command structure
pub const LinkCommand = struct {
    path: []const u8,
    name: []const u8,
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
    format: OutputFormat = .text,
};

/// Parse command-line arguments into structured commands
pub fn parse_command(args: []const []const u8) ParseError!Command {
    if (args.len < 2) {
        return Command{ .help = HelpCommand{} };
    }

    const command_str = args[1];
    const remaining_args = args[2..];

    // Parse based on command name
    if (std.mem.eql(u8, command_str, "help")) {
        return Command{ .help = try parse_help(remaining_args) };
    } else if (std.mem.eql(u8, command_str, "version")) {
        return Command{ .version = try parse_version(remaining_args) };
    } else if (std.mem.eql(u8, command_str, "server")) {
        return Command{ .server = try parse_server(remaining_args) };
    } else if (std.mem.eql(u8, command_str, "status")) {
        return Command{ .status = try parse_status(remaining_args) };
    } else if (std.mem.eql(u8, command_str, "ping")) {
        return Command{ .ping = try parse_ping(remaining_args) };
    } else if (std.mem.eql(u8, command_str, "find")) {
        return Command{ .find = try parse_find(remaining_args) };
    } else if (std.mem.eql(u8, command_str, "show")) {
        return Command{ .show = try parse_show(remaining_args) };
    } else if (std.mem.eql(u8, command_str, "trace")) {
        return Command{ .trace = try parse_trace(remaining_args) };
    } else if (std.mem.eql(u8, command_str, "link")) {
        return Command{ .link = try parse_link(remaining_args) };
    } else if (std.mem.eql(u8, command_str, "unlink")) {
        return Command{ .unlink = try parse_unlink(remaining_args) };
    } else if (std.mem.eql(u8, command_str, "sync")) {
        return Command{ .sync = try parse_sync(remaining_args) };
    } else {
        return ParseError.UnknownCommand;
    }
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
    if (args.len == 0) return ParseError.MissingArgument;

    var cmd = FindCommand{
        .query = args[0],
    };
    var i: usize = 1;

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.format = try parse_output_format(args[i]);
        } else if (std.mem.eql(u8, arg, "--max-results")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.max_results = std.fmt.parseInt(u16, args[i], 10) catch return ParseError.InvalidNumber;
        } else if (std.mem.eql(u8, arg, "--show-metadata")) {
            cmd.show_metadata = true;
        } else {
            return ParseError.InvalidArgument;
        }
    }

    return cmd;
}

fn parse_show(args: []const []const u8) ParseError!ShowCommand {
    if (args.len < 2) return ParseError.MissingArgument;

    const direction_str = args[0];
    const direction: ShowCommand.Direction = if (std.mem.eql(u8, direction_str, "callers"))
        .callers
    else if (std.mem.eql(u8, direction_str, "callees"))
        .callees
    else if (std.mem.eql(u8, direction_str, "imports"))
        .imports
    else if (std.mem.eql(u8, direction_str, "exports"))
        .exports
    else
        return ParseError.InvalidArgument;

    var cmd = ShowCommand{
        .direction = direction,
        .target = args[1],
    };
    var i: usize = 2;

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.format = try parse_output_format(args[i]);
        } else if (std.mem.eql(u8, arg, "--max-depth")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.max_depth = std.fmt.parseInt(u16, args[i], 10) catch return ParseError.InvalidNumber;
        } else {
            return ParseError.InvalidArgument;
        }
    }

    return cmd;
}

fn parse_trace(args: []const []const u8) ParseError!TraceCommand {
    if (args.len < 2) return ParseError.MissingArgument;

    var cmd = TraceCommand{
        .source = args[0],
        .target = args[1],
    };
    var i: usize = 2;

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.format = try parse_output_format(args[i]);
        } else if (std.mem.eql(u8, arg, "--max-depth")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.max_depth = std.fmt.parseInt(u16, args[i], 10) catch return ParseError.InvalidNumber;
        } else if (std.mem.eql(u8, arg, "--all-paths")) {
            cmd.all_paths = true;
        } else {
            return ParseError.InvalidArgument;
        }
    }

    return cmd;
}

fn parse_link(args: []const []const u8) ParseError!LinkCommand {
    if (args.len < 2) return ParseError.MissingArgument;

    var cmd = LinkCommand{
        .path = args[0],
        .name = args[1],
    };
    var i: usize = 2;

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.format = try parse_output_format(args[i]);
        } else {
            return ParseError.InvalidArgument;
        }
    }

    return cmd;
}

fn parse_unlink(args: []const []const u8) ParseError!UnlinkCommand {
    if (args.len == 0) return ParseError.MissingArgument;

    var cmd = UnlinkCommand{
        .name = args[0],
    };
    var i: usize = 1;

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            cmd.format = try parse_output_format(args[i]);
        } else {
            return ParseError.InvalidArgument;
        }
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
