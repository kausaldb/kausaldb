//! Command-line argument parser for CLI.
//!
//! Transforms raw command-line arguments into structured command types.
//! Zero allocations for parsing, all validation happens during parsing.

const std = @import("std");

const testing = std.testing;

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

/// Check if a string matches any in a list of alternatives
inline fn matches(str: []const u8, alternatives: []const []const u8) bool {
    for (alternatives) |alt| {
        if (std.mem.eql(u8, str, alt)) return true;
    }
    return false;
}

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
            break;
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

    // Command dispatch: maps command strings to their parser functions
    const command = blk: {
        if (matches(command_str, &.{ "help", "--help", "-h" })) {
            break :blk Command{ .help = try parse_help(remaining_args) };
        }
        if (matches(command_str, &.{ "version", "--version", "-v" })) {
            break :blk Command{ .version = try parse_version(remaining_args) };
        }
        if (matches(command_str, &.{"server"})) {
            break :blk Command{ .server = try parse_server(remaining_args) };
        }
        if (matches(command_str, &.{"status"})) {
            break :blk Command{ .status = try parse_status(remaining_args) };
        }
        if (matches(command_str, &.{"ping"})) {
            break :blk Command{ .ping = try parse_ping(remaining_args) };
        }
        if (matches(command_str, &.{"find"})) {
            break :blk Command{ .find = try parse_find(remaining_args) };
        }
        if (matches(command_str, &.{"show"})) {
            break :blk Command{ .show = try parse_show(remaining_args) };
        }
        if (matches(command_str, &.{"trace"})) {
            break :blk Command{ .trace = try parse_trace(remaining_args) };
        }
        if (matches(command_str, &.{"link"})) {
            break :blk Command{ .link = try parse_link(remaining_args) };
        }
        if (matches(command_str, &.{"unlink"})) {
            break :blk Command{ .unlink = try parse_unlink(remaining_args) };
        }
        if (matches(command_str, &.{"sync"})) {
            break :blk Command{ .sync = try parse_sync(remaining_args) };
        }
        return ParseError.UnknownCommand;
    };

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
    _ = args;
    return PingCommand{};
}

fn parse_find(args: []const []const u8) ParseError!FindCommand {
    var cmd = FindCommand{
        .name = "",
    };
    var i: usize = 0;

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

    if (cmd.name.len == 0) {
        return ParseError.MissingArgument;
    }

    return cmd;
}

fn parse_show(args: []const []const u8) ParseError!ShowCommand {
    var cmd = ShowCommand{
        .direction = undefined,
        .target = "",
    };
    var i: usize = 0;
    var direction_set = false;
    var target_set = false;

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

    if (!direction_set or !target_set) {
        return ParseError.MissingArgument;
    }

    return cmd;
}

fn parse_trace(args: []const []const u8) ParseError!TraceCommand {
    var cmd = TraceCommand{
        .direction = undefined,
        .target = "",
    };
    var i: usize = 0;
    var direction_set = false;
    var target_set = false;

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

    if (!direction_set or !target_set) {
        return ParseError.MissingArgument;
    }

    return cmd;
}

fn parse_link(args: []const []const u8) ParseError!LinkCommand {
    var cmd = LinkCommand{
        .path = "",
    };
    var i: usize = 0;
    var path_set = false;

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

    if (!path_set) {
        return ParseError.MissingArgument;
    }

    return cmd;
}

fn parse_unlink(args: []const []const u8) ParseError!UnlinkCommand {
    var cmd = UnlinkCommand{
        .name = "",
    };
    var i: usize = 0;
    var name_set = false;

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

    if (!name_set) {
        return ParseError.MissingArgument;
    }

    return cmd;
}

fn parse_sync(args: []const []const u8) ParseError!SyncCommand {
    var cmd = SyncCommand{};
    var i: usize = 0;

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

test "parse_output_format handles all valid formats" {
    try testing.expectEqual(OutputFormat.text, try parse_output_format("text"));
    try testing.expectEqual(OutputFormat.json, try parse_output_format("json"));
    try testing.expectEqual(OutputFormat.csv, try parse_output_format("csv"));
}

test "parse_output_format rejects invalid formats" {
    try testing.expectError(ParseError.InvalidFormat, parse_output_format("xml"));
    try testing.expectError(ParseError.InvalidFormat, parse_output_format("yaml"));
    try testing.expectError(ParseError.InvalidFormat, parse_output_format(""));
    try testing.expectError(ParseError.InvalidFormat, parse_output_format("TEXT"));
}

test "parse_entity_type handles all valid types" {
    try testing.expectEqual(FindCommand.EntityType.function, try parse_entity_type("function"));
    try testing.expectEqual(FindCommand.EntityType.struct_type, try parse_entity_type("struct"));
    try testing.expectEqual(FindCommand.EntityType.constant, try parse_entity_type("constant"));
    try testing.expectEqual(FindCommand.EntityType.variable, try parse_entity_type("variable"));
}

test "parse_entity_type rejects invalid types" {
    try testing.expectError(ParseError.InvalidArgument, parse_entity_type("class"));
    try testing.expectError(ParseError.InvalidArgument, parse_entity_type("method"));
    try testing.expectError(ParseError.InvalidArgument, parse_entity_type(""));
    try testing.expectError(ParseError.InvalidArgument, parse_entity_type("FUNCTION"));
}

test "parse_command_with_globals handles empty args" {
    const result = try parse_command_with_globals(&[_][]const u8{"kausal"});
    try testing.expect(std.meta.activeTag(result.command) == .help);
}

test "parse_command_with_globals handles global port option" {
    const args = [_][]const u8{ "kausal", "--port", "8080", "help" };
    const result = try parse_command_with_globals(&args);
    try testing.expectEqual(@as(u16, 8080), result.global_options.port.?);
    try testing.expect(std.meta.activeTag(result.command) == .help);
}

test "parse_command_with_globals handles global host option" {
    const args = [_][]const u8{ "kausal", "--host", "192.168.1.100", "version" };
    const result = try parse_command_with_globals(&args);
    try testing.expectEqualStrings("192.168.1.100", result.global_options.host.?);
    try testing.expect(std.meta.activeTag(result.command) == .version);
}

test "parse_find command with all options" {
    const args = [_][]const u8{ "kausal", "find", "--type", "function", "--name", "test_fn", "--workspace", "backend", "--format", "json", "--max-results", "50" };
    const result = try parse_command_with_globals(&args);

    try testing.expect(std.meta.activeTag(result.command) == .find);
    const find_cmd = result.command.find;
    try testing.expectEqual(FindCommand.EntityType.function, find_cmd.type);
    try testing.expectEqualStrings("test_fn", find_cmd.name);
    try testing.expectEqualStrings("backend", find_cmd.workspace.?);
    try testing.expectEqual(OutputFormat.json, find_cmd.format);
    try testing.expectEqual(@as(u16, 50), find_cmd.max_results);
}

test "parse_find command missing required name" {
    const args = [_][]const u8{ "kausal", "find", "--type", "function" };
    try testing.expectError(ParseError.MissingArgument, parse_command_with_globals(&args));
}

test "parse_find command with invalid type" {
    const args = [_][]const u8{ "kausal", "find", "--type", "invalid", "--name", "test" };
    try testing.expectError(ParseError.InvalidArgument, parse_command_with_globals(&args));
}

test "parse_show command with all options" {
    const args = [_][]const u8{ "kausal", "show", "--relation", "callers", "--target", "main", "--format", "text", "--max-depth", "5" };
    const result = try parse_command_with_globals(&args);

    try testing.expect(std.meta.activeTag(result.command) == .show);
    const show_cmd = result.command.show;
    try testing.expectEqual(ShowCommand.Direction.callers, show_cmd.direction);
    try testing.expectEqualStrings("main", show_cmd.target);
    try testing.expectEqual(OutputFormat.text, show_cmd.format);
    try testing.expectEqual(@as(u16, 5), show_cmd.max_depth);
}

test "parse_show command missing required arguments" {
    const args = [_][]const u8{ "kausal", "show", "--relation", "callers" };
    try testing.expectError(ParseError.MissingArgument, parse_command_with_globals(&args));
}

test "parse_trace command with valid direction" {
    const args = [_][]const u8{ "kausal", "trace", "--direction", "callees", "--target", "process_data" };
    const result = try parse_command_with_globals(&args);

    try testing.expect(std.meta.activeTag(result.command) == .trace);
    const trace_cmd = result.command.trace;
    try testing.expectEqual(TraceCommand.Direction.callees, trace_cmd.direction);
    try testing.expectEqualStrings("process_data", trace_cmd.target);
}

test "parse_link command with path" {
    const args = [_][]const u8{ "kausal", "link", "--path", "/home/user/project", "--name", "my-project" };
    const result = try parse_command_with_globals(&args);

    try testing.expect(std.meta.activeTag(result.command) == .link);
    const link_cmd = result.command.link;
    try testing.expectEqualStrings("/home/user/project", link_cmd.path);
    try testing.expectEqualStrings("my-project", link_cmd.name.?);
}

test "parse_unlink command with name" {
    const args = [_][]const u8{ "kausal", "unlink", "--name", "old-project" };
    const result = try parse_command_with_globals(&args);

    try testing.expect(std.meta.activeTag(result.command) == .unlink);
    const unlink_cmd = result.command.unlink;
    try testing.expectEqualStrings("old-project", unlink_cmd.name);
}

test "parse_sync command with workspace name" {
    const args = [_][]const u8{ "kausal", "sync", "backend", "--force" };
    const result = try parse_command_with_globals(&args);

    try testing.expect(std.meta.activeTag(result.command) == .sync);
    const sync_cmd = result.command.sync;
    try testing.expectEqualStrings("backend", sync_cmd.name.?);
    try testing.expectEqual(true, sync_cmd.force);
}

test "parse_sync command with all flag" {
    const args = [_][]const u8{ "kausal", "sync", "--all" };
    const result = try parse_command_with_globals(&args);

    try testing.expect(std.meta.activeTag(result.command) == .sync);
    const sync_cmd = result.command.sync;
    try testing.expectEqual(true, sync_cmd.all);
}

test "parse_server command with different modes" {
    const start_args = [_][]const u8{ "kausal", "server", "start", "--host", "localhost", "--port", "9000" };
    const start_result = try parse_command_with_globals(&start_args);
    try testing.expect(std.meta.activeTag(start_result.command) == .server);
    try testing.expectEqual(ServerCommand.ServerMode.start, start_result.command.server.mode);
    try testing.expectEqualStrings("localhost", start_result.command.server.host);
    try testing.expectEqual(@as(u16, 9000), start_result.command.server.port);

    const stop_args = [_][]const u8{ "kausal", "server", "stop" };
    const stop_result = try parse_command_with_globals(&stop_args);
    try testing.expectEqual(ServerCommand.ServerMode.stop, stop_result.command.server.mode);
}

test "parse_status command with verbose flag" {
    const args = [_][]const u8{ "kausal", "status", "--verbose", "--format", "json" };
    const result = try parse_command_with_globals(&args);

    try testing.expect(std.meta.activeTag(result.command) == .status);
    const status_cmd = result.command.status;
    try testing.expectEqual(true, status_cmd.verbose);
    try testing.expectEqual(OutputFormat.json, status_cmd.format);
}

test "parse_ping command accepts no arguments" {
    const args = [_][]const u8{ "kausal", "ping" };
    const result = try parse_command_with_globals(&args);
    try testing.expect(std.meta.activeTag(result.command) == .ping);
}

test "parse_help command with topic" {
    const args = [_][]const u8{ "kausal", "help", "find" };
    const result = try parse_command_with_globals(&args);

    try testing.expect(std.meta.activeTag(result.command) == .help);
    const help_cmd = result.command.help;
    try testing.expectEqualStrings("find", help_cmd.topic.?);
}

test "parse_version command accepts no arguments" {
    const args = [_][]const u8{ "kausal", "version" };
    const result = try parse_command_with_globals(&args);
    try testing.expect(std.meta.activeTag(result.command) == .version);
}

test "unknown command returns error" {
    const args = [_][]const u8{ "kausal", "unknown_command" };
    try testing.expectError(ParseError.UnknownCommand, parse_command_with_globals(&args));
}

test "missing argument for flag returns error" {
    const args = [_][]const u8{ "kausal", "find", "--name" };
    try testing.expectError(ParseError.MissingArgument, parse_command_with_globals(&args));
}

test "invalid format returns error" {
    const args = [_][]const u8{ "kausal", "status", "--format", "xml" };
    try testing.expectError(ParseError.InvalidFormat, parse_command_with_globals(&args));
}

test "too many arguments for version returns error" {
    const args = [_][]const u8{ "kausal", "version", "extra" };
    try testing.expectError(ParseError.TooManyArguments, parse_command_with_globals(&args));
}

test "number parsing for max-results" {
    const args = [_][]const u8{ "kausal", "find", "--name", "test", "--max-results", "100" };
    const result = try parse_command_with_globals(&args);
    try testing.expectEqual(@as(u16, 100), result.command.find.max_results);
}

test "invalid number for max-results returns error" {
    const args = [_][]const u8{ "kausal", "find", "--name", "test", "--max-results", "not_a_number" };
    try testing.expectError(ParseError.InvalidNumber, parse_command_with_globals(&args));
}
