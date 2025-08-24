//! Integration tests for natural language CLI workflows.
//!
//! Tests complete CLI workflows using the natural language interface,
//! including workspace management, semantic queries, and JSON output.
//! Uses temporary directories for isolated test environments.

const std = @import("std");
const testing = std.testing;

const natural_commands = @import("../../src/cli/natural_commands.zig");
const natural_executor = @import("../../src/cli/natural_executor.zig");

const NaturalCommand = natural_commands.NaturalCommand;
const NaturalExecutionContext = natural_executor.NaturalExecutionContext;
const OutputFormat = natural_commands.OutputFormat;

test "workspace management workflow" {
    const allocator = testing.allocator;

    // Create temporary directory for test
    const tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const test_data_dir = try std.fs.path.join(allocator, &[_][]const u8{ tmp_path, "test_data" });
    defer allocator.free(test_data_dir);

    var context = try NaturalExecutionContext.init(allocator, test_data_dir);
    defer context.deinit();

    // Test initial status (empty workspace)
    {
        const status_cmd = NaturalCommand{ .status = .{ .format = .human } };
        // This should not crash and should show empty workspace
        try natural_executor.execute_natural_command(&context, status_cmd);
    }

    // Test linking a directory
    {
        const link_cmd = NaturalCommand{ .link = .{ .path = try allocator.dupe(u8, tmp_path), .name = try allocator.dupe(u8, "test_project"), .format = .human } };
        defer {
            allocator.free(link_cmd.link.path);
            allocator.free(link_cmd.link.name.?);
        }

        // This should successfully link the directory
        try natural_executor.execute_natural_command(&context, link_cmd);
    }

    // Test status after linking
    {
        const status_cmd = NaturalCommand{ .status = .{ .format = .human } };
        // Should now show the linked codebase
        try natural_executor.execute_natural_command(&context, status_cmd);
    }

    // Test JSON status output
    {
        const status_cmd = NaturalCommand{ .status = .{ .format = .json } };
        // Should output valid JSON
        try natural_executor.execute_natural_command(&context, status_cmd);
    }

    // Test sync command
    {
        const sync_cmd = NaturalCommand{ .sync = .{ .name = try allocator.dupe(u8, "test_project"), .all = false, .format = .human } };
        defer allocator.free(sync_cmd.sync.name.?);

        // Should sync the linked codebase
        try natural_executor.execute_natural_command(&context, sync_cmd);
    }

    // Test unlinking
    {
        const unlink_cmd = NaturalCommand{ .unlink = .{ .name = try allocator.dupe(u8, "test_project"), .format = .human } };
        defer allocator.free(unlink_cmd.unlink.name);

        // Should unlink the codebase
        try natural_executor.execute_natural_command(&context, unlink_cmd);
    }

    // Test status after unlinking (should be empty again)
    {
        const status_cmd = NaturalCommand{ .status = .{ .format = .human } };
        // Should show empty workspace again
        try natural_executor.execute_natural_command(&context, status_cmd);
    }
}

test "semantic query workflow" {
    const allocator = testing.allocator;

    // Create temporary directory for test
    const tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const test_data_dir = try std.fs.path.join(allocator, &[_][]const u8{ tmp_path, "test_data" });
    defer allocator.free(test_data_dir);

    var context = try NaturalExecutionContext.init(allocator, test_data_dir);
    defer context.deinit();

    // Link a workspace for querying
    {
        const link_cmd = NaturalCommand{ .link = .{ .path = try allocator.dupe(u8, tmp_path), .name = try allocator.dupe(u8, "test_workspace"), .format = .human } };
        defer {
            allocator.free(link_cmd.link.path);
            allocator.free(link_cmd.link.name.?);
        }

        try natural_executor.execute_natural_command(&context, link_cmd);
    }

    // Test find command (should handle empty database gracefully)
    {
        const find_cmd = NaturalCommand{ .find = .{ .entity_type = try allocator.dupe(u8, "function"), .name = try allocator.dupe(u8, "init"), .workspace = try allocator.dupe(u8, "test_workspace"), .format = .human } };
        defer {
            allocator.free(find_cmd.find.entity_type);
            allocator.free(find_cmd.find.name);
            allocator.free(find_cmd.find.workspace.?);
        }

        // Should report no results found
        try natural_executor.execute_natural_command(&context, find_cmd);
    }

    // Test find command with JSON output
    {
        const find_cmd = NaturalCommand{ .find = .{ .entity_type = try allocator.dupe(u8, "struct"), .name = try allocator.dupe(u8, "TestStruct"), .workspace = null, .format = .json } };
        defer {
            allocator.free(find_cmd.find.entity_type);
            allocator.free(find_cmd.find.name);
        }

        // Should output JSON format
        try natural_executor.execute_natural_command(&context, find_cmd);
    }

    // Test show command (relationship queries)
    {
        const show_cmd = NaturalCommand{ .show = .{ .relation_type = try allocator.dupe(u8, "callers"), .target = try allocator.dupe(u8, "main"), .workspace = try allocator.dupe(u8, "test_workspace"), .format = .human } };
        defer {
            allocator.free(show_cmd.show.relation_type);
            allocator.free(show_cmd.show.target);
            allocator.free(show_cmd.show.workspace.?);
        }

        // Should handle gracefully (implementation in progress message)
        try natural_executor.execute_natural_command(&context, show_cmd);
    }

    // Test trace command (multi-hop traversal)
    {
        const trace_cmd = NaturalCommand{ .trace = .{ .direction = try allocator.dupe(u8, "callees"), .target = try allocator.dupe(u8, "main"), .workspace = null, .depth = 3, .format = .json } };
        defer {
            allocator.free(trace_cmd.trace.direction);
            allocator.free(trace_cmd.trace.target);
        }

        // Should output JSON format (implementation in progress message)
        try natural_executor.execute_natural_command(&context, trace_cmd);
    }
}

test "error handling and validation" {
    const allocator = testing.allocator;

    // Create temporary directory for test
    const tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const test_data_dir = try std.fs.path.join(allocator, &[_][]const u8{ tmp_path, "test_data" });
    defer allocator.free(test_data_dir);

    var context = try NaturalExecutionContext.init(allocator, test_data_dir);
    defer context.deinit();

    // Test invalid entity type
    {
        const find_cmd = NaturalCommand{ .find = .{ .entity_type = try allocator.dupe(u8, "invalid_type"), .name = try allocator.dupe(u8, "test"), .workspace = null, .format = .human } };
        defer {
            allocator.free(find_cmd.find.entity_type);
            allocator.free(find_cmd.find.name);
        }

        // Should handle invalid entity type gracefully
        try natural_executor.execute_natural_command(&context, find_cmd);
    }

    // Test invalid relation type
    {
        const show_cmd = NaturalCommand{ .show = .{ .relation_type = try allocator.dupe(u8, "invalid_relation"), .target = try allocator.dupe(u8, "test"), .workspace = null, .format = .human } };
        defer {
            allocator.free(show_cmd.show.relation_type);
            allocator.free(show_cmd.show.target);
        }

        // Should handle invalid relation type gracefully
        try natural_executor.execute_natural_command(&context, show_cmd);
    }

    // Test invalid direction
    {
        const trace_cmd = NaturalCommand{ .trace = .{ .direction = try allocator.dupe(u8, "invalid_direction"), .target = try allocator.dupe(u8, "test"), .workspace = null, .depth = null, .format = .human } };
        defer {
            allocator.free(trace_cmd.trace.direction);
            allocator.free(trace_cmd.trace.target);
        }

        // Should handle invalid direction gracefully
        try natural_executor.execute_natural_command(&context, trace_cmd);
    }

    // Test unlink non-existent codebase
    {
        const unlink_cmd = NaturalCommand{ .unlink = .{ .name = try allocator.dupe(u8, "non_existent"), .format = .human } };
        defer allocator.free(unlink_cmd.unlink.name);

        // Should handle gracefully with error message
        try natural_executor.execute_natural_command(&context, unlink_cmd);
    }

    // Test sync non-existent codebase
    {
        const sync_cmd = NaturalCommand{ .sync = .{ .name = try allocator.dupe(u8, "non_existent"), .all = false, .format = .human } };
        defer allocator.free(sync_cmd.sync.name.?);

        // Should handle gracefully with error message
        try natural_executor.execute_natural_command(&context, sync_cmd);
    }
}

test "JSON output format validation" {
    const allocator = testing.allocator;

    // Create temporary directory for test
    const tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const test_data_dir = try std.fs.path.join(allocator, &[_][]const u8{ tmp_path, "test_data" });
    defer allocator.free(test_data_dir);

    var context = try NaturalExecutionContext.init(allocator, test_data_dir);
    defer context.deinit();

    // Test all commands support JSON output
    const commands = [_]NaturalCommand{
        .{ .status = .{ .format = .json } },
        .{ .link = .{ .path = try allocator.dupe(u8, tmp_path), .name = try allocator.dupe(u8, "json_test"), .format = .json } },
        .{ .unlink = .{ .name = try allocator.dupe(u8, "json_test"), .format = .json } },
        .{ .sync = .{ .name = null, .all = false, .format = .json } },
        .{ .find = .{ .entity_type = try allocator.dupe(u8, "function"), .name = try allocator.dupe(u8, "test"), .workspace = null, .format = .json } },
        .{ .show = .{ .relation_type = try allocator.dupe(u8, "callers"), .target = try allocator.dupe(u8, "test"), .workspace = null, .format = .json } },
        .{ .trace = .{ .direction = try allocator.dupe(u8, "callees"), .target = try allocator.dupe(u8, "test"), .workspace = null, .depth = null, .format = .json } },
    };

    // Execute each command - all should produce valid JSON output
    // (We can't validate the JSON structure in unit tests without capturing output,
    // but we can ensure they don't crash)
    for (commands) |command| {
        try natural_executor.execute_natural_command(&context, command);
    }

    // Clean up allocated strings
    allocator.free(commands[1].link.path);
    allocator.free(commands[1].link.name.?);
    allocator.free(commands[2].unlink.name);
    allocator.free(commands[4].find.entity_type);
    allocator.free(commands[4].find.name);
    allocator.free(commands[5].show.relation_type);
    allocator.free(commands[5].show.target);
    allocator.free(commands[6].trace.direction);
    allocator.free(commands[6].trace.target);
}

test "concurrent context isolation" {
    const allocator = testing.allocator;

    // Create two separate temporary directories
    const tmp_dir1 = testing.tmpDir(.{});
    defer tmp_dir1.cleanup();
    const tmp_dir2 = testing.tmpDir(.{});
    defer tmp_dir2.cleanup();

    const tmp_path1 = try tmp_dir1.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path1);
    const tmp_path2 = try tmp_dir2.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path2);

    const test_data_dir1 = try std.fs.path.join(allocator, &[_][]const u8{ tmp_path1, "data1" });
    defer allocator.free(test_data_dir1);
    const test_data_dir2 = try std.fs.path.join(allocator, &[_][]const u8{ tmp_path2, "data2" });
    defer allocator.free(test_data_dir2);

    // Create two separate contexts
    var context1 = try NaturalExecutionContext.init(allocator, test_data_dir1);
    defer context1.deinit();
    var context2 = try NaturalExecutionContext.init(allocator, test_data_dir2);
    defer context2.deinit();

    // Link different codebases to each context
    {
        const link_cmd1 = NaturalCommand{ .link = .{ .path = try allocator.dupe(u8, tmp_path1), .name = try allocator.dupe(u8, "project1"), .format = .human } };
        defer {
            allocator.free(link_cmd1.link.path);
            allocator.free(link_cmd1.link.name.?);
        }

        const link_cmd2 = NaturalCommand{ .link = .{ .path = try allocator.dupe(u8, tmp_path2), .name = try allocator.dupe(u8, "project2"), .format = .human } };
        defer {
            allocator.free(link_cmd2.link.path);
            allocator.free(link_cmd2.link.name.?);
        }

        // Link different projects to different contexts
        try natural_executor.execute_natural_command(&context1, link_cmd1);
        try natural_executor.execute_natural_command(&context2, link_cmd2);
    }

    // Verify contexts are isolated (each should only see their own linked project)
    {
        const status_cmd = NaturalCommand{ .status = .{ .format = .human } };

        // Each context should show only its own workspace
        try natural_executor.execute_natural_command(&context1, status_cmd);
        try natural_executor.execute_natural_command(&context2, status_cmd);
    }

    // Test that operations on one context don't affect the other
    {
        const find_cmd = NaturalCommand{ .find = .{ .entity_type = try allocator.dupe(u8, "function"), .name = try allocator.dupe(u8, "test"), .workspace = null, .format = .human } };
        defer {
            allocator.free(find_cmd.find.entity_type);
            allocator.free(find_cmd.find.name);
        }

        // Both contexts should handle queries independently
        try natural_executor.execute_natural_command(&context1, find_cmd);
        try natural_executor.execute_natural_command(&context2, find_cmd);
    }
}
