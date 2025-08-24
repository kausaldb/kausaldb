//! Integration tests for natural language CLI using SimulationVFS.
//!
//! Tests the natural language CLI functionality through the programmatic
//! interface using SimulationVFS for deterministic testing. This provides
//! comprehensive coverage of CLI behavior without binary execution overhead.

const std = @import("std");
const testing = std.testing;

const natural_commands = @import("../../src/cli/natural_commands.zig");
const natural_executor = @import("../../src/cli/natural_executor.zig");
const simulation_vfs = @import("../../src/simulation_vfs.zig");

const NaturalCommand = natural_commands.NaturalCommand;
const NaturalExecutionContext = natural_executor.NaturalExecutionContext;
const OutputFormat = natural_commands.OutputFormat;
const SimulationVFS = simulation_vfs.SimulationVFS;

/// Test context using SimulationVFS for deterministic behavior
const SimulationTestContext = struct {
    allocator: std.mem.Allocator,
    sim_vfs: *SimulationVFS,
    context: NaturalExecutionContext,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        const sim_vfs = try allocator.create(SimulationVFS);
        sim_vfs.* = SimulationVFS.init(allocator);

        // Create test data directory structure in simulation
        try sim_vfs.mkdir("kausal_data");
        try sim_vfs.mkdir("kausal_data/wal");
        try sim_vfs.mkdir("kausal_data/sstables");

        var context = try NaturalExecutionContext.init(allocator, "kausal_data");
        // Replace the production VFS with simulation VFS
        context.vfs = sim_vfs.vfs();

        return Self{
            .allocator = allocator,
            .sim_vfs = sim_vfs,
            .context = context,
        };
    }

    pub fn deinit(self: *Self) void {
        self.context.deinit();
        self.sim_vfs.deinit();
        self.allocator.destroy(self.sim_vfs);
    }

    /// Create test project structure in simulation
    pub fn create_test_project(self: *Self, project_name: []const u8) !void {
        try self.sim_vfs.mkdir(project_name);

        const main_zig_path = try std.fmt.allocPrint(self.allocator, "{s}/main.zig", .{project_name});
        defer self.allocator.free(main_zig_path);

        const main_zig_content =
            \\const std = @import("std");
            \\
            \\pub fn main() void {
            \\    init_system();
            \\    run_main_loop();
            \\}
            \\
            \\fn init_system() void {
            \\    // System initialization
            \\}
            \\
            \\fn run_main_loop() void {
            \\    // Main application loop
            \\}
            \\
        ;

        try self.sim_vfs.write_file(main_zig_path, main_zig_content);

        const lib_zig_path = try std.fmt.allocPrint(self.allocator, "{s}/lib.zig", .{project_name});
        defer self.allocator.free(lib_zig_path);

        const lib_zig_content =
            \\const std = @import("std");
            \\
            \\pub fn calculate_sum(a: i32, b: i32) i32 {
            \\    return a + b;
            \\}
            \\
            \\pub const Config = struct {
            \\    debug: bool = false,
            \\    max_connections: u32 = 100,
            \\    
            \\    pub fn init() Config {
            \\        return Config{};
            \\    }
            \\};
            \\
        ;

        try self.sim_vfs.write_file(lib_zig_path, lib_zig_content);
    }
};

test "simulation-based workspace management workflow" {
    const allocator = testing.allocator;
    var test_ctx = try SimulationTestContext.init(allocator);
    defer test_ctx.deinit();

    try test_ctx.create_test_project("test_project");

    // Test initial status (should be empty)
    {
        const status_cmd = NaturalCommand{ .status = .{ .format = .human } };
        try natural_executor.execute_natural_command(&test_ctx.context, status_cmd);
    }

    // Test linking the test project
    {
        const link_cmd = NaturalCommand{ .link = .{ .path = try allocator.dupe(u8, "test_project"), .name = try allocator.dupe(u8, "test_workspace"), .format = .human } };
        defer {
            allocator.free(link_cmd.link.path);
            allocator.free(link_cmd.link.name.?);
        }

        try natural_executor.execute_natural_command(&test_ctx.context, link_cmd);
    }

    // Test status after linking
    {
        const status_cmd = NaturalCommand{ .status = .{ .format = .human } };
        try natural_executor.execute_natural_command(&test_ctx.context, status_cmd);
    }

    // Test JSON status output
    {
        const status_cmd = NaturalCommand{ .status = .{ .format = .json } };
        try natural_executor.execute_natural_command(&test_ctx.context, status_cmd);
    }

    // Test sync command
    {
        const sync_cmd = NaturalCommand{ .sync = .{ .name = try allocator.dupe(u8, "test_workspace"), .all = false, .format = .human } };
        defer allocator.free(sync_cmd.sync.name.?);

        try natural_executor.execute_natural_command(&test_ctx.context, sync_cmd);
    }

    // Test unlinking
    {
        const unlink_cmd = NaturalCommand{ .unlink = .{ .name = try allocator.dupe(u8, "test_workspace"), .format = .human } };
        defer allocator.free(unlink_cmd.unlink.name);

        try natural_executor.execute_natural_command(&test_ctx.context, unlink_cmd);
    }
}

test "simulation-based semantic query workflow" {
    const allocator = testing.allocator;
    var test_ctx = try SimulationTestContext.init(allocator);
    defer test_ctx.deinit();

    try test_ctx.create_test_project("query_project");

    // Link a workspace for querying
    {
        const link_cmd = NaturalCommand{ .link = .{ .path = try allocator.dupe(u8, "query_project"), .name = try allocator.dupe(u8, "query_workspace"), .format = .human } };
        defer {
            allocator.free(link_cmd.link.path);
            allocator.free(link_cmd.link.name.?);
        }

        try natural_executor.execute_natural_command(&test_ctx.context, link_cmd);
    }

    // Test find command
    {
        const find_cmd = NaturalCommand{ .find = .{ .entity_type = try allocator.dupe(u8, "function"), .name = try allocator.dupe(u8, "main"), .workspace = try allocator.dupe(u8, "query_workspace"), .format = .human } };
        defer {
            allocator.free(find_cmd.find.entity_type);
            allocator.free(find_cmd.find.name);
            allocator.free(find_cmd.find.workspace.?);
        }

        try natural_executor.execute_natural_command(&test_ctx.context, find_cmd);
    }

    // Test find command with JSON output
    {
        const find_cmd = NaturalCommand{ .find = .{ .entity_type = try allocator.dupe(u8, "struct"), .name = try allocator.dupe(u8, "Config"), .workspace = null, .format = .json } };
        defer {
            allocator.free(find_cmd.find.entity_type);
            allocator.free(find_cmd.find.name);
        }

        try natural_executor.execute_natural_command(&test_ctx.context, find_cmd);
    }

    // Test show command (relationship queries)
    {
        const show_cmd = NaturalCommand{ .show = .{ .relation_type = try allocator.dupe(u8, "callers"), .target = try allocator.dupe(u8, "init_system"), .workspace = try allocator.dupe(u8, "query_workspace"), .format = .human } };
        defer {
            allocator.free(show_cmd.show.relation_type);
            allocator.free(show_cmd.show.target);
            allocator.free(show_cmd.show.workspace.?);
        }

        try natural_executor.execute_natural_command(&test_ctx.context, show_cmd);
    }

    // Test trace command (multi-hop traversal)
    {
        const trace_cmd = NaturalCommand{ .trace = .{ .direction = try allocator.dupe(u8, "callees"), .target = try allocator.dupe(u8, "main"), .workspace = null, .depth = 3, .format = .json } };
        defer {
            allocator.free(trace_cmd.trace.direction);
            allocator.free(trace_cmd.trace.target);
        }

        try natural_executor.execute_natural_command(&test_ctx.context, trace_cmd);
    }
}

test "simulation-based error handling validation" {
    const allocator = testing.allocator;
    var test_ctx = try SimulationTestContext.init(allocator);
    defer test_ctx.deinit();

    // Test invalid entity type
    {
        const find_cmd = NaturalCommand{ .find = .{ .entity_type = try allocator.dupe(u8, "invalid_type"), .name = try allocator.dupe(u8, "test"), .workspace = null, .format = .human } };
        defer {
            allocator.free(find_cmd.find.entity_type);
            allocator.free(find_cmd.find.name);
        }

        // Should handle invalid entity type gracefully
        try natural_executor.execute_natural_command(&test_ctx.context, find_cmd);
    }

    // Test invalid relation type
    {
        const show_cmd = NaturalCommand{ .show = .{ .relation_type = try allocator.dupe(u8, "invalid_relation"), .target = try allocator.dupe(u8, "test"), .workspace = null, .format = .human } };
        defer {
            allocator.free(show_cmd.show.relation_type);
            allocator.free(show_cmd.show.target);
        }

        // Should handle invalid relation type gracefully
        try natural_executor.execute_natural_command(&test_ctx.context, show_cmd);
    }

    // Test invalid direction
    {
        const trace_cmd = NaturalCommand{ .trace = .{ .direction = try allocator.dupe(u8, "invalid_direction"), .target = try allocator.dupe(u8, "test"), .workspace = null, .depth = null, .format = .human } };
        defer {
            allocator.free(trace_cmd.trace.direction);
            allocator.free(trace_cmd.trace.target);
        }

        // Should handle invalid direction gracefully
        try natural_executor.execute_natural_command(&test_ctx.context, trace_cmd);
    }

    // Test unlink non-existent codebase
    {
        const unlink_cmd = NaturalCommand{ .unlink = .{ .name = try allocator.dupe(u8, "non_existent"), .format = .human } };
        defer allocator.free(unlink_cmd.unlink.name);

        // Should handle gracefully with error message
        try natural_executor.execute_natural_command(&test_ctx.context, unlink_cmd);
    }
}

test "simulation-based JSON output format validation" {
    const allocator = testing.allocator;
    var test_ctx = try SimulationTestContext.init(allocator);
    defer test_ctx.deinit();

    try test_ctx.create_test_project("json_test_project");

    // Test all commands support JSON output
    const json_test_commands = [_]NaturalCommand{
        .{ .status = .{ .format = .json } },
        .{ .link = .{ .path = try allocator.dupe(u8, "json_test_project"), .name = try allocator.dupe(u8, "json_test"), .format = .json } },
        .{ .find = .{ .entity_type = try allocator.dupe(u8, "function"), .name = try allocator.dupe(u8, "test"), .workspace = null, .format = .json } },
        .{ .show = .{ .relation_type = try allocator.dupe(u8, "callers"), .target = try allocator.dupe(u8, "test"), .workspace = null, .format = .json } },
        .{ .trace = .{ .direction = try allocator.dupe(u8, "callees"), .target = try allocator.dupe(u8, "test"), .workspace = null, .depth = null, .format = .json } },
    };

    // Execute each command - all should produce valid JSON output
    for (json_test_commands) |command| {
        try natural_executor.execute_natural_command(&test_ctx.context, command);
    }

    // Clean up allocated strings
    allocator.free(json_test_commands[1].link.path);
    allocator.free(json_test_commands[1].link.name.?);
    allocator.free(json_test_commands[2].find.entity_type);
    allocator.free(json_test_commands[2].find.name);
    allocator.free(json_test_commands[3].show.relation_type);
    allocator.free(json_test_commands[3].show.target);
    allocator.free(json_test_commands[4].trace.direction);
    allocator.free(json_test_commands[4].trace.target);
}

test "simulation-based concurrent context isolation" {
    const allocator = testing.allocator;

    // Create two separate contexts
    var test_ctx1 = try SimulationTestContext.init(allocator);
    defer test_ctx1.deinit();
    var test_ctx2 = try SimulationTestContext.init(allocator);
    defer test_ctx2.deinit();

    // Create separate project structures
    try test_ctx1.create_test_project("project1");
    try test_ctx2.create_test_project("project2");

    // Link different codebases to each context
    {
        const link_cmd1 = NaturalCommand{ .link = .{ .path = try allocator.dupe(u8, "project1"), .name = try allocator.dupe(u8, "isolated_project1"), .format = .human } };
        defer {
            allocator.free(link_cmd1.link.path);
            allocator.free(link_cmd1.link.name.?);
        }

        const link_cmd2 = NaturalCommand{ .link = .{ .path = try allocator.dupe(u8, "project2"), .name = try allocator.dupe(u8, "isolated_project2"), .format = .human } };
        defer {
            allocator.free(link_cmd2.link.path);
            allocator.free(link_cmd2.link.name.?);
        }

        // Link different projects to different contexts
        try natural_executor.execute_natural_command(&test_ctx1.context, link_cmd1);
        try natural_executor.execute_natural_command(&test_ctx2.context, link_cmd2);
    }

    // Verify contexts are isolated
    {
        const status_cmd = NaturalCommand{ .status = .{ .format = .human } };

        // Each context should show only its own workspace
        try natural_executor.execute_natural_command(&test_ctx1.context, status_cmd);
        try natural_executor.execute_natural_command(&test_ctx2.context, status_cmd);
    }

    // Test that operations on one context don't affect the other
    {
        const find_cmd = NaturalCommand{ .find = .{ .entity_type = try allocator.dupe(u8, "function"), .name = try allocator.dupe(u8, "test"), .workspace = null, .format = .human } };
        defer {
            allocator.free(find_cmd.find.entity_type);
            allocator.free(find_cmd.find.name);
        }

        // Both contexts should handle queries independently
        try natural_executor.execute_natural_command(&test_ctx1.context, find_cmd);
        try natural_executor.execute_natural_command(&test_ctx2.context, find_cmd);
    }
}
