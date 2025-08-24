//! Unit tests for natural language CLI command parsing.
//!
//! Tests the command parsing, validation, and error handling of the new
//! natural language interface. Ensures all command syntaxes work correctly
//! and provide appropriate error messages for invalid usage.

const std = @import("std");
const testing = std.testing;

const natural_commands = @import("../../src/cli/natural_commands.zig");

const NaturalCommand = natural_commands.NaturalCommand;
const NaturalCommandError = natural_commands.NaturalCommandError;
const OutputFormat = natural_commands.OutputFormat;

test "parse help command" {
    const allocator = testing.allocator;

    // Test basic help
    {
        const args = [_][:0]const u8{ "kausal", "help" };
        var result = try natural_commands.parse_natural_command(allocator, &args);
        defer result.deinit();

        switch (result.command) {
            .help => |cmd| {
                try testing.expect(cmd.topic == null);
            },
            else => try testing.expect(false),
        }
    }

    // Test help with topic
    {
        const args = [_][:0]const u8{ "kausal", "help", "link" };
        var result = try natural_commands.parse_natural_command(allocator, &args);
        defer result.deinit();

        switch (result.command) {
            .help => |cmd| {
                try testing.expectEqualStrings("link", cmd.topic.?);
            },
            else => try testing.expect(false),
        }
    }
}

test "parse version command" {
    const allocator = testing.allocator;

    const args = [_][:0]const u8{ "kausal", "version" };
    var result = try natural_commands.parse_natural_command(allocator, &args);
    defer result.deinit();

    switch (result.command) {
        .version => {},
        else => try testing.expect(false),
    }
}

test "parse link command" {
    const allocator = testing.allocator;

    // Test basic link
    {
        const args = [_][:0]const u8{ "kausal", "link", "." };
        var result = try natural_commands.parse_natural_command(allocator, &args);
        defer result.deinit();

        switch (result.command) {
            .link => |cmd| {
                try testing.expectEqualStrings(".", cmd.path);
                try testing.expect(cmd.name == null);
                try testing.expectEqual(OutputFormat.human, cmd.format);
            },
            else => try testing.expect(false),
        }
    }

    // Test link with name
    {
        const args = [_][:0]const u8{ "kausal", "link", "/path/to/code", "as", "myproject" };
        var result = try natural_commands.parse_natural_command(allocator, &args);
        defer result.deinit();

        switch (result.command) {
            .link => |cmd| {
                try testing.expectEqualStrings("/path/to/code", cmd.path);
                try testing.expectEqualStrings("myproject", cmd.name.?);
                try testing.expectEqual(OutputFormat.human, cmd.format);
            },
            else => try testing.expect(false),
        }
    }

    // Test link with JSON output
    {
        const args = [_][:0]const u8{ "kausal", "link", ".", "--json" };
        var result = try natural_commands.parse_natural_command(allocator, &args);
        defer result.deinit();

        switch (result.command) {
            .link => |cmd| {
                try testing.expectEqualStrings(".", cmd.path);
                try testing.expect(cmd.name == null);
                try testing.expectEqual(OutputFormat.json, cmd.format);
            },
            else => try testing.expect(false),
        }
    }

    // Test link missing path
    {
        const args = [_][:0]const u8{ "kausal", "link" };
        const result = natural_commands.parse_natural_command(allocator, &args);
        try testing.expectError(NaturalCommandError.MissingRequiredArgument, result);
    }
}

test "parse unlink command" {
    const allocator = testing.allocator;

    // Test basic unlink
    {
        const args = [_][:0]const u8{ "kausal", "unlink", "myproject" };
        var result = try natural_commands.parse_natural_command(allocator, &args);
        defer result.deinit();

        switch (result.command) {
            .unlink => |cmd| {
                try testing.expectEqualStrings("myproject", cmd.name);
                try testing.expectEqual(OutputFormat.human, cmd.format);
            },
            else => try testing.expect(false),
        }
    }

    // Test unlink missing name
    {
        const args = [_][:0]const u8{ "kausal", "unlink" };
        const result = natural_commands.parse_natural_command(allocator, &args);
        try testing.expectError(NaturalCommandError.MissingRequiredArgument, result);
    }
}

test "parse sync command" {
    const allocator = testing.allocator;

    // Test sync all
    {
        const args = [_][:0]const u8{ "kausal", "sync", "--all" };
        var result = try natural_commands.parse_natural_command(allocator, &args);
        defer result.deinit();

        switch (result.command) {
            .sync => |cmd| {
                try testing.expect(cmd.name == null);
                try testing.expect(cmd.all == true);
                try testing.expectEqual(OutputFormat.human, cmd.format);
            },
            else => try testing.expect(false),
        }
    }

    // Test sync specific
    {
        const args = [_][:0]const u8{ "kausal", "sync", "myproject" };
        var result = try natural_commands.parse_natural_command(allocator, &args);
        defer result.deinit();

        switch (result.command) {
            .sync => |cmd| {
                try testing.expectEqualStrings("myproject", cmd.name.?);
                try testing.expect(cmd.all == false);
                try testing.expectEqual(OutputFormat.human, cmd.format);
            },
            else => try testing.expect(false),
        }
    }

    // Test sync no args (current directory)
    {
        const args = [_][:0]const u8{ "kausal", "sync" };
        var result = try natural_commands.parse_natural_command(allocator, &args);
        defer result.deinit();

        switch (result.command) {
            .sync => |cmd| {
                try testing.expect(cmd.name == null);
                try testing.expect(cmd.all == false);
                try testing.expectEqual(OutputFormat.human, cmd.format);
            },
            else => try testing.expect(false),
        }
    }
}

test "parse status command" {
    const allocator = testing.allocator;

    // Test basic status
    {
        const args = [_][:0]const u8{ "kausal", "status" };
        var result = try natural_commands.parse_natural_command(allocator, &args);
        defer result.deinit();

        switch (result.command) {
            .status => |cmd| {
                try testing.expectEqual(OutputFormat.human, cmd.format);
            },
            else => try testing.expect(false),
        }
    }

    // Test status with JSON
    {
        const args = [_][:0]const u8{ "kausal", "status", "--json" };
        var result = try natural_commands.parse_natural_command(allocator, &args);
        defer result.deinit();

        switch (result.command) {
            .status => |cmd| {
                try testing.expectEqual(OutputFormat.json, cmd.format);
            },
            else => try testing.expect(false),
        }
    }
}

test "parse find command" {
    const allocator = testing.allocator;

    // Test basic find
    {
        const args = [_][:0]const u8{ "kausal", "find", "function", "init" };
        var result = try natural_commands.parse_natural_command(allocator, &args);
        defer result.deinit();

        switch (result.command) {
            .find => |cmd| {
                try testing.expectEqualStrings("function", cmd.entity_type);
                try testing.expectEqualStrings("init", cmd.name);
                try testing.expect(cmd.workspace == null);
                try testing.expectEqual(OutputFormat.human, cmd.format);
            },
            else => try testing.expect(false),
        }
    }

    // Test find with workspace
    {
        const args = [_][:0]const u8{ "kausal", "find", "struct", "ContextBlock", "in", "kausaldb" };
        var result = try natural_commands.parse_natural_command(allocator, &args);
        defer result.deinit();

        switch (result.command) {
            .find => |cmd| {
                try testing.expectEqualStrings("struct", cmd.entity_type);
                try testing.expectEqualStrings("ContextBlock", cmd.name);
                try testing.expectEqualStrings("kausaldb", cmd.workspace.?);
                try testing.expectEqual(OutputFormat.human, cmd.format);
            },
            else => try testing.expect(false),
        }
    }

    // Test find with JSON output
    {
        const args = [_][:0]const u8{ "kausal", "find", "test", "parsing", "--json" };
        var result = try natural_commands.parse_natural_command(allocator, &args);
        defer result.deinit();

        switch (result.command) {
            .find => |cmd| {
                try testing.expectEqualStrings("test", cmd.entity_type);
                try testing.expectEqualStrings("parsing", cmd.name);
                try testing.expect(cmd.workspace == null);
                try testing.expectEqual(OutputFormat.json, cmd.format);
            },
            else => try testing.expect(false),
        }
    }

    // Test find missing args
    {
        const args = [_][:0]const u8{ "kausal", "find", "function" };
        const result = natural_commands.parse_natural_command(allocator, &args);
        try testing.expectError(NaturalCommandError.MissingRequiredArgument, result);
    }
}

test "parse show command" {
    const allocator = testing.allocator;

    // Test basic show
    {
        const args = [_][:0]const u8{ "kausal", "show", "callers", "main" };
        var result = try natural_commands.parse_natural_command(allocator, &args);
        defer result.deinit();

        switch (result.command) {
            .show => |cmd| {
                try testing.expectEqualStrings("callers", cmd.relation_type);
                try testing.expectEqualStrings("main", cmd.target);
                try testing.expect(cmd.workspace == null);
                try testing.expectEqual(OutputFormat.human, cmd.format);
            },
            else => try testing.expect(false),
        }
    }

    // Test show with workspace
    {
        const args = [_][:0]const u8{ "kausal", "show", "callees", "StorageEngine.put_block", "in", "myproject" };
        var result = try natural_commands.parse_natural_command(allocator, &args);
        defer result.deinit();

        switch (result.command) {
            .show => |cmd| {
                try testing.expectEqualStrings("callees", cmd.relation_type);
                try testing.expectEqualStrings("StorageEngine.put_block", cmd.target);
                try testing.expectEqualStrings("myproject", cmd.workspace.?);
                try testing.expectEqual(OutputFormat.human, cmd.format);
            },
            else => try testing.expect(false),
        }
    }
}

test "parse trace command" {
    const allocator = testing.allocator;

    // Test basic trace
    {
        const args = [_][:0]const u8{ "kausal", "trace", "callers", "main" };
        var result = try natural_commands.parse_natural_command(allocator, &args);
        defer result.deinit();

        switch (result.command) {
            .trace => |cmd| {
                try testing.expectEqualStrings("callers", cmd.direction);
                try testing.expectEqualStrings("main", cmd.target);
                try testing.expect(cmd.workspace == null);
                try testing.expect(cmd.depth == null);
                try testing.expectEqual(OutputFormat.human, cmd.format);
            },
            else => try testing.expect(false),
        }
    }

    // Test trace with depth
    {
        const args = [_][:0]const u8{ "kausal", "trace", "callees", "main", "--depth", "5" };
        var result = try natural_commands.parse_natural_command(allocator, &args);
        defer result.deinit();

        switch (result.command) {
            .trace => |cmd| {
                try testing.expectEqualStrings("callees", cmd.direction);
                try testing.expectEqualStrings("main", cmd.target);
                try testing.expect(cmd.workspace == null);
                try testing.expectEqual(@as(u32, 5), cmd.depth.?);
                try testing.expectEqual(OutputFormat.human, cmd.format);
            },
            else => try testing.expect(false),
        }
    }

    // Test trace with workspace and JSON
    {
        const args = [_][:0]const u8{ "kausal", "trace", "both", "init", "in", "kausaldb", "--depth", "3", "--json" };
        var result = try natural_commands.parse_natural_command(allocator, &args);
        defer result.deinit();

        switch (result.command) {
            .trace => |cmd| {
                try testing.expectEqualStrings("both", cmd.direction);
                try testing.expectEqualStrings("init", cmd.target);
                try testing.expectEqualStrings("kausaldb", cmd.workspace.?);
                try testing.expectEqual(@as(u32, 3), cmd.depth.?);
                try testing.expectEqual(OutputFormat.json, cmd.format);
            },
            else => try testing.expect(false),
        }
    }

    // Test invalid depth
    {
        const args = [_][:0]const u8{ "kausal", "trace", "callers", "main", "--depth", "invalid" };
        const result = natural_commands.parse_natural_command(allocator, &args);
        try testing.expectError(NaturalCommandError.InvalidSyntax, result);
    }
}

test "validate entity types" {
    try testing.expect(natural_commands.validate_entity_type("function"));
    try testing.expect(natural_commands.validate_entity_type("struct"));
    try testing.expect(natural_commands.validate_entity_type("test"));
    try testing.expect(natural_commands.validate_entity_type("method"));
    try testing.expect(natural_commands.validate_entity_type("const"));
    try testing.expect(natural_commands.validate_entity_type("var"));
    try testing.expect(natural_commands.validate_entity_type("type"));

    try testing.expect(!natural_commands.validate_entity_type("invalid"));
    try testing.expect(!natural_commands.validate_entity_type(""));
    try testing.expect(!natural_commands.validate_entity_type("class")); // Not a Zig concept
}

test "validate relation types" {
    try testing.expect(natural_commands.validate_relation_type("callers"));
    try testing.expect(natural_commands.validate_relation_type("callees"));
    try testing.expect(natural_commands.validate_relation_type("references"));

    try testing.expect(!natural_commands.validate_relation_type("invalid"));
    try testing.expect(!natural_commands.validate_relation_type(""));
    try testing.expect(!natural_commands.validate_relation_type("inheritance")); // Not supported
}

test "validate directions" {
    try testing.expect(natural_commands.validate_direction("callers"));
    try testing.expect(natural_commands.validate_direction("callees"));
    try testing.expect(natural_commands.validate_direction("both"));
    try testing.expect(natural_commands.validate_direction("references"));

    try testing.expect(!natural_commands.validate_direction("invalid"));
    try testing.expect(!natural_commands.validate_direction(""));
    try testing.expect(!natural_commands.validate_direction("up")); // Not supported
}

test "output format from string" {
    try testing.expectEqual(OutputFormat.human, OutputFormat.from_string("human").?);
    try testing.expectEqual(OutputFormat.json, OutputFormat.from_string("json").?);
    try testing.expect(OutputFormat.from_string("xml") == null);
    try testing.expect(OutputFormat.from_string("") == null);
}

test "unknown command error" {
    const allocator = testing.allocator;

    const args = [_][:0]const u8{ "kausal", "invalid_command" };
    const result = natural_commands.parse_natural_command(allocator, &args);
    try testing.expectError(NaturalCommandError.UnknownCommand, result);
}

test "command cleanup and memory management" {
    const allocator = testing.allocator;

    // Test that all allocated memory is properly freed
    {
        const args = [_][:0]const u8{ "kausal", "find", "function", "test_function", "in", "test_workspace", "--json" };
        var result = try natural_commands.parse_natural_command(allocator, &args);

        // Verify the command was parsed correctly
        switch (result.command) {
            .find => |cmd| {
                try testing.expectEqualStrings("function", cmd.entity_type);
                try testing.expectEqualStrings("test_function", cmd.name);
                try testing.expectEqualStrings("test_workspace", cmd.workspace.?);
                try testing.expectEqual(OutputFormat.json, cmd.format);
            },
            else => try testing.expect(false),
        }

        // This should free all allocated strings
        result.deinit();
    }

    // Test multiple command parsing and cleanup
    {
        const test_cases = [_][2][:0]const u8{
            .{ "kausal", "help" },
            .{ "kausal", "version" },
            .{ "kausal", "status" },
        };

        for (test_cases) |args| {
            var result = try natural_commands.parse_natural_command(allocator, &args);
            result.deinit(); // Should not leak memory
        }
    }
}
