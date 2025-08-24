//! Natural language CLI command parsing for KausalDB.
//!
//! Supports action-verb commands with natural language syntax:
//! - kausal link . as myproject
//! - kausal find function "init" in kausaldb
//! - kausal show callers "main" in myproject
//! - kausal trace callees "StorageEngine.put_block" --depth 5
//!
//! Design rationale: Natural language parsing enables intuitive developer
//! experience while maintaining type safety and explicit error handling.

const std = @import("std");

const assert_mod = @import("../core/assert.zig");
const error_context = @import("../core/error_context.zig");

const assert = assert_mod.assert;

/// Natural language command parsing errors
pub const NaturalCommandError = error{
    UnknownCommand,
    InvalidSyntax,
    MissingRequiredArgument,
    TooManyArguments,
    InvalidWorkspaceName,
    InvalidEntityType,
    InvalidRelationType,
    InvalidDirection,
} || std.mem.Allocator.Error;

/// Output format options for commands
pub const OutputFormat = enum {
    human,
    json,

    pub fn from_string(str: []const u8) ?OutputFormat {
        if (std.mem.eql(u8, str, "human")) return .human;
        if (std.mem.eql(u8, str, "json")) return .json;
        return null;
    }
};

/// Natural language commands supported by the CLI
pub const NaturalCommand = union(enum) {
    // Workspace management
    link: LinkCommand,
    unlink: UnlinkCommand,
    sync: SyncCommand,
    status: StatusCommand,

    // Semantic queries
    find: FindCommand,
    show: ShowCommand,
    trace: TraceCommand,

    // System commands
    help: HelpCommand,
    version,

    pub const LinkCommand = struct {
        path: []const u8,
        name: ?[]const u8 = null,
        format: OutputFormat = .human,
    };

    pub const UnlinkCommand = struct {
        name: []const u8,
        format: OutputFormat = .human,
    };

    pub const SyncCommand = struct {
        name: ?[]const u8 = null, // null = sync current directory
        all: bool = false,
        format: OutputFormat = .human,
    };

    pub const StatusCommand = struct {
        format: OutputFormat = .human,
    };

    pub const FindCommand = struct {
        entity_type: []const u8, // "function", "struct", "test", etc.
        name: []const u8,
        workspace: ?[]const u8 = null,
        format: OutputFormat = .human,
    };

    pub const ShowCommand = struct {
        relation_type: []const u8, // "callers", "callees", "references"
        target: []const u8,
        workspace: ?[]const u8 = null,
        format: OutputFormat = .human,
    };

    pub const TraceCommand = struct {
        direction: []const u8, // "callers", "callees", "both"
        target: []const u8,
        workspace: ?[]const u8 = null,
        depth: ?u32 = null,
        format: OutputFormat = .human,
    };

    pub const HelpCommand = struct {
        topic: ?[]const u8 = null,
    };
};

/// Result of parsing command line arguments
pub const ParseResult = struct {
    command: NaturalCommand,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ParseResult) void {
        // Commands contain string slices that may need freeing
        switch (self.command) {
            .link => |cmd| {
                self.allocator.free(cmd.path);
                if (cmd.name) |name| self.allocator.free(name);
            },
            .unlink => |cmd| self.allocator.free(cmd.name),
            .sync => |cmd| if (cmd.name) |name| self.allocator.free(name),
            .find => |cmd| {
                self.allocator.free(cmd.entity_type);
                self.allocator.free(cmd.name);
                if (cmd.workspace) |ws| self.allocator.free(ws);
            },
            .show => |cmd| {
                self.allocator.free(cmd.relation_type);
                self.allocator.free(cmd.target);
                if (cmd.workspace) |ws| self.allocator.free(ws);
            },
            .trace => |cmd| {
                self.allocator.free(cmd.direction);
                self.allocator.free(cmd.target);
                if (cmd.workspace) |ws| self.allocator.free(ws);
            },
            .help => |cmd| if (cmd.topic) |topic| self.allocator.free(topic),
            else => {}, // No cleanup needed for other commands
        }
    }
};

/// Parse command line arguments into natural language commands
pub fn parse_natural_command(allocator: std.mem.Allocator, args: []const [:0]const u8) NaturalCommandError!ParseResult {
    if (args.len < 2) {
        return ParseResult{ .command = .{ .help = .{} }, .allocator = allocator };
    }

    const command_name = args[1];

    if (std.mem.eql(u8, command_name, "help")) {
        const topic = if (args.len > 2)
            try allocator.dupe(u8, args[2])
        else
            null;
        return ParseResult{
            .command = .{ .help = .{ .topic = topic } },
            .allocator = allocator,
        };
    }

    if (std.mem.eql(u8, command_name, "version")) {
        return ParseResult{
            .command = .version,
            .allocator = allocator,
        };
    }

    if (std.mem.eql(u8, command_name, "link")) {
        return parse_link_command(allocator, args[2..]);
    }

    if (std.mem.eql(u8, command_name, "unlink")) {
        return parse_unlink_command(allocator, args[2..]);
    }

    if (std.mem.eql(u8, command_name, "sync")) {
        return parse_sync_command(allocator, args[2..]);
    }

    if (std.mem.eql(u8, command_name, "status")) {
        return parse_status_command(allocator, args[2..]);
    }

    if (std.mem.eql(u8, command_name, "find")) {
        return parse_find_command(allocator, args[2..]);
    }

    if (std.mem.eql(u8, command_name, "show")) {
        return parse_show_command(allocator, args[2..]);
    }

    if (std.mem.eql(u8, command_name, "trace")) {
        return parse_trace_command(allocator, args[2..]);
    }

    return NaturalCommandError.UnknownCommand;
}

// === Individual Command Parsers ===

fn parse_link_command(allocator: std.mem.Allocator, args: []const [:0]const u8) NaturalCommandError!ParseResult {
    if (args.len == 0) return NaturalCommandError.MissingRequiredArgument;

    const path = try allocator.dupe(u8, args[0]);
    var name: ?[]const u8 = null;
    var format: OutputFormat = .human;

    var i: usize = 1;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "as") and i + 1 < args.len) {
            name = try allocator.dupe(u8, args[i + 1]);
            i += 2;
        } else if (std.mem.eql(u8, args[i], "--json")) {
            format = .json;
            i += 1;
        } else {
            return NaturalCommandError.InvalidSyntax;
        }
    }

    return ParseResult{
        .command = .{ .link = .{ .path = path, .name = name, .format = format } },
        .allocator = allocator,
    };
}

fn parse_unlink_command(allocator: std.mem.Allocator, args: []const [:0]const u8) NaturalCommandError!ParseResult {
    if (args.len == 0) return NaturalCommandError.MissingRequiredArgument;

    const name = try allocator.dupe(u8, args[0]);
    var format: OutputFormat = .human;

    var i: usize = 1;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "--json")) {
            format = .json;
            i += 1;
        } else {
            return NaturalCommandError.InvalidSyntax;
        }
    }

    return ParseResult{
        .command = .{ .unlink = .{ .name = name, .format = format } },
        .allocator = allocator,
    };
}

fn parse_sync_command(allocator: std.mem.Allocator, args: []const [:0]const u8) NaturalCommandError!ParseResult {
    var name: ?[]const u8 = null;
    var all = false;
    var format: OutputFormat = .human;

    var i: usize = 0;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "--all")) {
            all = true;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--json")) {
            format = .json;
            i += 1;
        } else if (name == null) {
            name = try allocator.dupe(u8, args[i]);
            i += 1;
        } else {
            return NaturalCommandError.InvalidSyntax;
        }
    }

    return ParseResult{
        .command = .{ .sync = .{ .name = name, .all = all, .format = format } },
        .allocator = allocator,
    };
}

fn parse_status_command(allocator: std.mem.Allocator, args: []const [:0]const u8) NaturalCommandError!ParseResult {
    var format: OutputFormat = .human;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            format = .json;
        } else {
            return NaturalCommandError.InvalidSyntax;
        }
    }

    return ParseResult{
        .command = .{ .status = .{ .format = format } },
        .allocator = allocator,
    };
}

fn parse_find_command(allocator: std.mem.Allocator, args: []const [:0]const u8) NaturalCommandError!ParseResult {
    // Expected: find <type> <name> [in <workspace>] [--json]
    if (args.len < 2) return NaturalCommandError.MissingRequiredArgument;

    const entity_type = try allocator.dupe(u8, args[0]);
    const name = try allocator.dupe(u8, args[1]);
    var workspace: ?[]const u8 = null;
    var format: OutputFormat = .human;

    var i: usize = 2;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "in") and i + 1 < args.len) {
            workspace = try allocator.dupe(u8, args[i + 1]);
            i += 2;
        } else if (std.mem.eql(u8, args[i], "--json")) {
            format = .json;
            i += 1;
        } else {
            return NaturalCommandError.InvalidSyntax;
        }
    }

    return ParseResult{
        .command = .{ .find = .{ .entity_type = entity_type, .name = name, .workspace = workspace, .format = format } },
        .allocator = allocator,
    };
}

fn parse_show_command(allocator: std.mem.Allocator, args: []const [:0]const u8) NaturalCommandError!ParseResult {
    // Expected: show <relation> <target> [in <workspace>] [--json]
    if (args.len < 2) return NaturalCommandError.MissingRequiredArgument;

    const relation_type = try allocator.dupe(u8, args[0]);
    const target = try allocator.dupe(u8, args[1]);
    var workspace: ?[]const u8 = null;
    var format: OutputFormat = .human;

    var i: usize = 2;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "in") and i + 1 < args.len) {
            workspace = try allocator.dupe(u8, args[i + 1]);
            i += 2;
        } else if (std.mem.eql(u8, args[i], "--json")) {
            format = .json;
            i += 1;
        } else {
            return NaturalCommandError.InvalidSyntax;
        }
    }

    return ParseResult{
        .command = .{ .show = .{ .relation_type = relation_type, .target = target, .workspace = workspace, .format = format } },
        .allocator = allocator,
    };
}

fn parse_trace_command(allocator: std.mem.Allocator, args: []const [:0]const u8) NaturalCommandError!ParseResult {
    // Expected: trace <direction> <target> [in <workspace>] [--depth N] [--json]
    if (args.len < 2) return NaturalCommandError.MissingRequiredArgument;

    const direction = try allocator.dupe(u8, args[0]);
    const target = try allocator.dupe(u8, args[1]);
    var workspace: ?[]const u8 = null;
    var depth: ?u32 = null;
    var format: OutputFormat = .human;

    var i: usize = 2;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "in") and i + 1 < args.len) {
            workspace = try allocator.dupe(u8, args[i + 1]);
            i += 2;
        } else if (std.mem.eql(u8, args[i], "--depth") and i + 1 < args.len) {
            depth = std.fmt.parseInt(u32, args[i + 1], 10) catch {
                return NaturalCommandError.InvalidSyntax;
            };
            i += 2;
        } else if (std.mem.eql(u8, args[i], "--json")) {
            format = .json;
            i += 1;
        } else {
            return NaturalCommandError.InvalidSyntax;
        }
    }

    return ParseResult{
        .command = .{ .trace = .{ .direction = direction, .target = target, .workspace = workspace, .depth = depth, .format = format } },
        .allocator = allocator,
    };
}

// === Validation Functions ===

/// Validates that the given entity type is supported by KausalDB.
/// Entity types correspond to Zig language constructs that can be indexed.
/// Returns true if the type is valid, false otherwise.
pub fn validate_entity_type(entity_type: []const u8) bool {
    const valid_types = &[_][]const u8{ "function", "struct", "test", "method", "const", "var", "type" };

    for (valid_types) |valid_type| {
        if (std.mem.eql(u8, entity_type, valid_type)) return true;
    }
    return false;
}

/// Validates that the given relation type is supported for graph traversal.
/// Relation types define how code entities are connected in the knowledge graph.
/// Returns true if the type is valid, false otherwise.
pub fn validate_relation_type(relation_type: []const u8) bool {
    const valid_relations = &[_][]const u8{ "callers", "callees", "references" };

    for (valid_relations) |valid_relation| {
        if (std.mem.eql(u8, relation_type, valid_relation)) return true;
    }
    return false;
}

/// Validates that the given direction is supported for trace operations.
/// Directions determine traversal path in multi-hop graph operations.
/// Returns true if the direction is valid, false otherwise.
pub fn validate_direction(direction: []const u8) bool {
    const valid_directions = &[_][]const u8{ "callers", "callees", "both", "references" };

    for (valid_directions) |valid_direction| {
        if (std.mem.eql(u8, direction, valid_direction)) return true;
    }
    return false;
}

test "parse link command" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test basic link
    {
        const args = [_][:0]const u8{ "kausal", "link", "." };
        var result = try parse_natural_command(allocator, &args);
        defer result.deinit();

        const link_cmd = result.command.link;
        try testing.expectEqualStrings(".", link_cmd.path);
        try testing.expect(link_cmd.name == null);
        try testing.expectEqual(OutputFormat.human, link_cmd.format);
    }

    // Test link with name
    {
        const args = [_][:0]const u8{ "kausal", "link", "/path/to/code", "as", "myproject" };
        var result = try parse_natural_command(allocator, &args);
        defer result.deinit();

        const link_cmd = result.command.link;
        try testing.expectEqualStrings("/path/to/code", link_cmd.path);
        try testing.expectEqualStrings("myproject", link_cmd.name.?);
    }
}

test "parse find command" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test basic find
    {
        const args = [_][:0]const u8{ "kausal", "find", "function", "init" };
        var result = try parse_natural_command(allocator, &args);
        defer result.deinit();

        const find_cmd = result.command.find;
        try testing.expectEqualStrings("function", find_cmd.entity_type);
        try testing.expectEqualStrings("init", find_cmd.name);
        try testing.expect(find_cmd.workspace == null);
    }

    // Test find with workspace
    {
        const args = [_][:0]const u8{ "kausal", "find", "function", "init", "in", "kausaldb" };
        var result = try parse_natural_command(allocator, &args);
        defer result.deinit();

        const find_cmd = result.command.find;
        try testing.expectEqualStrings("function", find_cmd.entity_type);
        try testing.expectEqualStrings("init", find_cmd.name);
        try testing.expectEqualStrings("kausaldb", find_cmd.workspace.?);
    }
}

test "validate entity types" {
    const testing = std.testing;

    try testing.expect(validate_entity_type("function"));
    try testing.expect(validate_entity_type("struct"));
    try testing.expect(validate_entity_type("test"));
    try testing.expect(!validate_entity_type("invalid"));
}
