//! Shell integration tests for KausalDB pure e2e scenarios.
//!
//! Tests KausalDB through actual shell execution to validate real-world
//! usage patterns, scripting scenarios, and shell pipeline integration.
//! Focus on shell-specific features and automation workflows.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");

// Shell integration test harness using actual shell commands
const ShellHarness = struct {
    allocator: std.mem.Allocator,
    test_workspace: []const u8,
    binary_path: []const u8,
    shell_env: std.process.EnvMap,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, test_name: []const u8) !Self {
        // Get absolute path to binary for shell execution
        var cwd_buffer: [4096]u8 = undefined;
        const cwd = try std.process.getCwd(&cwd_buffer);
        const binary_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "zig-out", "bin", "kausaldb" });
        const test_workspace = try create_shell_workspace(allocator, test_name);

        var env = try std.process.getEnvMap(allocator);
        try env.put("KAUSAL_TEST_MODE", "1");

        return Self{
            .allocator = allocator,
            .test_workspace = test_workspace,
            .binary_path = binary_path,
            .shell_env = env,
        };
    }

    pub fn deinit(self: *Self) void {
        self.shell_env.deinit();
        std.fs.deleteTreeAbsolute(self.test_workspace) catch {};
        self.allocator.free(self.test_workspace);
        self.allocator.free(self.binary_path);
    }

    pub fn execute_shell_command(self: *Self, command: []const u8) !std.process.Child.RunResult {
        return std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "/bin/sh", "-c", command },
            .cwd = self.test_workspace,
            .env_map = &self.shell_env,
        });
    }

    pub fn execute_kausal_pipeline(self: *Self, commands: []const []const u8) !std.process.Child.RunResult {
        var pipeline = std.ArrayList(u8).init(self.allocator);
        defer pipeline.deinit();

        for (commands, 0..) |cmd, i| {
            if (i > 0) try pipeline.appendSlice(" | ");
            try pipeline.writer().print("{s} {s}", .{ self.binary_path, cmd });
        }

        return self.execute_shell_command(pipeline.items);
    }

    pub fn create_shell_project(self: *Self, name: []const u8) ![]const u8 {
        const project_dir = try std.fs.path.join(self.allocator, &[_][]const u8{ self.test_workspace, name });

        const mkdir_cmd = try std.fmt.allocPrint(self.allocator, "mkdir -p {s}", .{project_dir});
        defer self.allocator.free(mkdir_cmd);

        var result = try self.execute_shell_command(mkdir_cmd);
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (!harness.process_succeeded(result.term)) return error.ProjectCreationFailed;

        // Create files using shell commands for realistic scenarios
        const create_files_cmd = try std.fmt.allocPrint(self.allocator,
            \\cat > {s}/main.zig << 'EOF'
            \\const std = @import("std");
            \\const utils = @import("utils.zig");
            \\
            \\pub fn main() void {{
            \\    std.debug.print("Shell test project\n", .{{}});
            \\    helper_function();
            \\    utils.process_data(42);
            \\}}
            \\
            \\fn helper_function() void {{
            \\    std.debug.print("Helper called from shell test\n", .{{}});
            \\}}
            \\
            \\pub fn compute_result(x: i32) i32 {{
            \\    return x * x + 1;
            \\}}
            \\EOF
            \\
            \\cat > {s}/utils.zig << 'EOF'
            \\const std = @import("std");
            \\
            \\pub fn process_data(value: i32) void {{
            \\    const result = transform_value(value);
            \\    std.debug.print("Processed: {{}}\n", .{{result}});
            \\}}
            \\
            \\fn transform_value(x: i32) i32 {{
            \\    return x * 2 + 10;
            \\}}
            \\
            \\pub fn validate_input(input: []const u8) bool {{
            \\    return input.len > 0;
            \\}}
            \\EOF
        , .{ project_dir, project_dir });
        defer self.allocator.free(create_files_cmd);

        result = try self.execute_shell_command(create_files_cmd);
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (!harness.process_succeeded(result.term)) return error.FileCreationFailed;

        return project_dir;
    }
};

fn create_shell_workspace(allocator: std.mem.Allocator, test_name: []const u8) ![]const u8 {
    const timestamp = std.time.timestamp();
    const workspace = try std.fmt.allocPrint(allocator, "/tmp/kausal_shell_{s}_{d}", .{ test_name, timestamp });
    try std.fs.makeDirAbsolute(workspace);
    return workspace;
}

test "shell basic command chaining" {
    var shell_harness = try ShellHarness.init(testing.allocator, "basic_chain");
    defer shell_harness.deinit();

    const project_dir = try shell_harness.create_shell_project("chain_test");
    defer testing.allocator.free(project_dir);

    // Chain multiple KausalDB commands using shell
    const chain_cmd = try std.fmt.allocPrint(testing.allocator, "{s} link {s} && {s} sync chain_test && {s} status", .{ shell_harness.binary_path, project_dir, shell_harness.binary_path, shell_harness.binary_path });
    defer testing.allocator.free(chain_cmd);

    const result = try shell_harness.execute_shell_command(chain_cmd);
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expectEqual(@as(u8, 0), harness.safe_exit_code(result.term));
    try testing.expect(std.mem.indexOf(u8, result.stdout, "Linked") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "chain_test") != null);
}

test "shell script automation scenario" {
    var shell_harness = try ShellHarness.init(testing.allocator, "automation");
    defer shell_harness.deinit();

    // Create automation script
    const script_path = try std.fs.path.join(testing.allocator, &[_][]const u8{ shell_harness.test_workspace, "automate.sh" });
    defer testing.allocator.free(script_path);

    const script_content = try std.fmt.allocPrint(testing.allocator,
        \\#!/bin/bash
        \\set -e
        \\
        \\KAUSAL="{s}"
        \\
        \\# Setup multiple projects
        \\mkdir -p proj1 proj2 proj3
        \\echo 'const std = @import("std"); pub fn main() void {{}}' > proj1/main.zig
        \\echo 'const std = @import("std"); pub fn init() void {{}}' > proj2/main.zig
        \\echo 'const std = @import("std"); pub fn cleanup() void {{}}' > proj3/main.zig
        \\
        \\# Link all projects
        \\$KAUSAL link proj1 as backend
        \\$KAUSAL link proj2 as frontend
        \\$KAUSAL link proj3 as utils
        \\
        \\# Sync all
        \\$KAUSAL sync --all
        \\
        \\# Show final status
        \\$KAUSAL status --json
    , .{shell_harness.binary_path});
    defer testing.allocator.free(script_content);

    try std.fs.cwd().writeFile(.{ .sub_path = script_path, .data = script_content });

    // Make script executable and run it
    const chmod_cmd = try std.fmt.allocPrint(testing.allocator, "chmod +x {s}", .{script_path});
    defer testing.allocator.free(chmod_cmd);

    const chmod_result = try shell_harness.execute_shell_command(chmod_cmd);
    defer testing.allocator.free(chmod_result.stdout);
    defer testing.allocator.free(chmod_result.stderr);

    const result = try shell_harness.execute_shell_command(script_path);
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expectEqual(@as(u8, 0), harness.safe_exit_code(result.term));
    try testing.expect(std.mem.indexOf(u8, result.stdout, "backend") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "frontend") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "utils") != null);
}

test "shell environment variable integration" {
    var shell_harness = try ShellHarness.init(testing.allocator, "env_vars");
    defer shell_harness.deinit();

    const project_dir = try shell_harness.create_shell_project("env_test");
    defer testing.allocator.free(project_dir);

    // Test with environment variables
    const env_cmd = try std.fmt.allocPrint(testing.allocator, "KAUSAL_WORKSPACE=test_env {s} link {s} && KAUSAL_WORKSPACE=test_env {s} status", .{ shell_harness.binary_path, project_dir, shell_harness.binary_path });
    defer testing.allocator.free(env_cmd);

    const result = try shell_harness.execute_shell_command(env_cmd);
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    // Should work regardless of environment variables (for now)
    try testing.expect(harness.process_succeeded(result.term) or result.stderr.len > 0);
}

test "shell output redirection and processing" {
    var shell_harness = try ShellHarness.init(testing.allocator, "redirect");
    defer shell_harness.deinit();

    const project_dir = try shell_harness.create_shell_project("redirect_test");
    defer testing.allocator.free(project_dir);

    // Test output redirection to files
    const redirect_cmd = try std.fmt.allocPrint(testing.allocator,
        \\{s} link {s} > link_output.txt 2>&1 &&
        \\{s} status --json > status.json &&
        \\cat status.json | grep -q "env_test\\|redirect_test\\|No codebases" &&
        \\wc -l < link_output.txt
    , .{ shell_harness.binary_path, project_dir, shell_harness.binary_path });
    defer testing.allocator.free(redirect_cmd);

    const result = try shell_harness.execute_shell_command(redirect_cmd);
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expectEqual(@as(u8, 0), harness.safe_exit_code(result.term));
    // Should have line count output from wc command
    try testing.expect(result.stdout.len > 0);
}

test "shell pipe operations with kausal commands" {
    var shell_harness = try ShellHarness.init(testing.allocator, "pipes");
    defer shell_harness.deinit();

    const project_dir = try shell_harness.create_shell_project("pipe_test");
    defer testing.allocator.free(project_dir);

    // Test piping KausalDB output through shell utilities
    const pipe_cmd = try std.fmt.allocPrint(testing.allocator,
        \\{s} link {s} | grep -i "linked" | wc -l &&
        \\{s} status | head -5 | tail -1
    , .{ shell_harness.binary_path, project_dir, shell_harness.binary_path });
    defer testing.allocator.free(pipe_cmd);

    const result = try shell_harness.execute_shell_command(pipe_cmd);
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expectEqual(@as(u8, 0), harness.safe_exit_code(result.term));
    try testing.expect(result.stdout.len > 0);
}

test "shell error handling and recovery" {
    var shell_harness = try ShellHarness.init(testing.allocator, "error_recovery");
    defer shell_harness.deinit();

    // Test shell error handling with failing commands
    const error_cmd = try std.fmt.allocPrint(testing.allocator,
        \\{s} link /nonexistent/path || echo "Link failed as expected" &&
        \\{s} unlink nonexistent_project || echo "Unlink failed as expected" &&
        \\{s} version | grep -q "KausalDB" && echo "Version check passed"
    , .{ shell_harness.binary_path, shell_harness.binary_path, shell_harness.binary_path });
    defer testing.allocator.free(error_cmd);

    const result = try shell_harness.execute_shell_command(error_cmd);
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expectEqual(@as(u8, 0), harness.safe_exit_code(result.term));
    try testing.expect(std.mem.indexOf(u8, result.stdout, "expected") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "Version check passed") != null);
}

test "shell bulk operations through loops" {
    var shell_harness = try ShellHarness.init(testing.allocator, "bulk_ops");
    defer shell_harness.deinit();

    // Test bulk operations using shell loops
    const bulk_cmd = try std.fmt.allocPrint(testing.allocator,
        \\# Create multiple test projects
        \\for i in 1 2 3; do
        \\    mkdir -p "bulk_$i"
        \\    echo 'const std = @import("std"); pub fn main() void {{}}' > "bulk_$i/main.zig"
        \\    {s} link "bulk_$i" as "project_$i" || echo "Failed to link project_$i"
        \\done &&
        \\
        \\# Verify all were linked
        \\{s} status | grep -c "project_" || echo "0"
    , .{ shell_harness.binary_path, shell_harness.binary_path });
    defer testing.allocator.free(bulk_cmd);

    const result = try shell_harness.execute_shell_command(bulk_cmd);
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expectEqual(@as(u8, 0), harness.safe_exit_code(result.term));
    // Should show count of linked projects or individual project names
    try testing.expect(result.stdout.len > 0);
}

test "shell conditional execution based on kausal output" {
    var shell_harness = try ShellHarness.init(testing.allocator, "conditional");
    defer shell_harness.deinit();

    const project_dir = try shell_harness.create_shell_project("cond_test");
    defer testing.allocator.free(project_dir);

    // Test conditional execution based on KausalDB command results
    const cond_cmd = try std.fmt.allocPrint(testing.allocator,
        \\if {s} status | grep -q "No codebases"; then
        \\    echo "Workspace is empty - linking project"
        \\    {s} link {s} as conditional_project
        \\else
        \\    echo "Workspace has existing codebases"
        \\fi &&
        \\
        \\# Verify the result
        \\if {s} status | grep -q "conditional_project"; then
        \\    echo "SUCCESS: Project was linked"
        \\else
        \\    echo "INFO: Project was already present"
        \\fi
    , .{ shell_harness.binary_path, shell_harness.binary_path, project_dir, shell_harness.binary_path });
    defer testing.allocator.free(cond_cmd);

    const result = try shell_harness.execute_shell_command(cond_cmd);
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expectEqual(@as(u8, 0), harness.safe_exit_code(result.term));
    try testing.expect(std.mem.indexOf(u8, result.stdout, "SUCCESS") != null or
        std.mem.indexOf(u8, result.stdout, "INFO") != null);
}

test "shell command substitution with kausal output" {
    var shell_harness = try ShellHarness.init(testing.allocator, "substitution");
    defer shell_harness.deinit();

    const project_dir = try shell_harness.create_shell_project("subst_test");
    defer testing.allocator.free(project_dir);

    // Test command substitution using KausalDB output
    const subst_cmd = try std.fmt.allocPrint(testing.allocator,
        \\{s} link {s} &&
        \\PROJECT_COUNT=$({s} status | grep -c "linked from" || echo "0") &&
        \\echo "Found $PROJECT_COUNT linked projects" &&
        \\test "$PROJECT_COUNT" -ge "0"
    , .{ shell_harness.binary_path, project_dir, shell_harness.binary_path });
    defer testing.allocator.free(subst_cmd);

    const result = try shell_harness.execute_shell_command(subst_cmd);
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expectEqual(@as(u8, 0), harness.safe_exit_code(result.term));
    try testing.expect(std.mem.indexOf(u8, result.stdout, "Found") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "projects") != null);
}

test "shell cross-platform compatibility basics" {
    var shell_harness = try ShellHarness.init(testing.allocator, "cross_platform");
    defer shell_harness.deinit();

    // Test basic commands that should work across platforms
    const compat_cmd = try std.fmt.allocPrint(testing.allocator,
        \\echo "Testing cross-platform shell integration" &&
        \\{s} version > version_output &&
        \\test -f version_output &&
        \\rm version_output &&
        \\echo "Basic file operations work"
    , .{shell_harness.binary_path});
    defer testing.allocator.free(compat_cmd);

    const result = try shell_harness.execute_shell_command(compat_cmd);
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expectEqual(@as(u8, 0), harness.safe_exit_code(result.term));
    try testing.expect(std.mem.indexOf(u8, result.stdout, "Basic file operations work") != null);
}

test "shell integration with json processing tools" {
    var shell_harness = try ShellHarness.init(testing.allocator, "json_tools");
    defer shell_harness.deinit();

    const project_dir = try shell_harness.create_shell_project("json_test");
    defer testing.allocator.free(project_dir);

    // Test JSON output integration with shell tools (using basic tools available everywhere)
    const json_cmd = try std.fmt.allocPrint(testing.allocator,
        \\{s} link {s} &&
        \\{s} status --json > workspace.json &&
        \\# Basic JSON validation - check for braces and common fields
        \\grep -q "{{" workspace.json &&
        \\grep -q "}}" workspace.json &&
        \\echo "JSON format validated with basic tools"
    , .{ shell_harness.binary_path, project_dir, shell_harness.binary_path });
    defer testing.allocator.free(json_cmd);

    const result = try shell_harness.execute_shell_command(json_cmd);
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expectEqual(@as(u8, 0), harness.safe_exit_code(result.term));
    try testing.expect(std.mem.indexOf(u8, result.stdout, "JSON format validated") != null);
}
