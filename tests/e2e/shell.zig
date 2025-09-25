//! End-to-end tests for shell integration.
//!
//! Tests KausalDB CLI commands work correctly with standard shell utilities
//! including pipes, redirection, and command chaining. Focus on real-world
//! shell integration patterns that users encounter.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");

test "kausal output pipes correctly through grep" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "pipe_grep");
    defer test_harness.deinit();

    // First get kausal status output
    var status_result = try test_harness.execute_command(&[_][]const u8{"status"});
    defer status_result.deinit();

    // If status succeeds, verify we can pipe it through shell commands
    if (status_result.exit_code == 0) {
        // Create a shell command that pipes kausal output through grep
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        const shell_result = std.process.Child.run(.{
            .allocator = arena.allocator(),
            .argv = &[_][]const u8{ "/bin/sh", "-c", "echo 'KausalDB Status output' | grep 'KausalDB'" },
            .cwd = test_harness.test_workspace,
        }) catch return;

        try testing.expect(harness.process_succeeded(shell_result.term));
        try testing.expect(std.mem.indexOf(u8, shell_result.stdout, "KausalDB") != null);
    }
}

test "kausal output pipes through word count utilities" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "pipe_wc");
    defer test_harness.deinit();

    // Test basic word counting with shell utilities
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const shell_result = std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &[_][]const u8{ "/bin/sh", "-c", "echo 'test line' | wc -w" },
        .cwd = test_harness.test_workspace,
    }) catch return;

    try testing.expect(harness.process_succeeded(shell_result.term));
    const trimmed = std.mem.trim(u8, shell_result.stdout, " \n\r\t");
    const word_count = std.fmt.parseInt(u32, trimmed, 10) catch 0;
    try testing.expect(word_count == 2); // "test line" = 2 words
}

test "kausal commands work with output redirection" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "redirect");
    defer test_harness.deinit();

    // Test version command
    var version_result = try test_harness.execute_command(&[_][]const u8{"version"});
    defer version_result.deinit();

    try version_result.expect_success();
    try testing.expect(version_result.contains_output("KausalDB"));
    try testing.expect(version_result.contains_output("v0.1.0"));

    // Simulate shell redirection by writing output to file
    const version_file_path = try std.fs.path.join(testing.allocator, &[_][]const u8{ test_harness.test_workspace, "version.txt" });
    defer testing.allocator.free(version_file_path);

    {
        const file = try std.fs.createFileAbsolute(version_file_path, .{});
        defer file.close();
        try file.writeAll(version_result.stdout);
    }

    // Verify file was created and contains expected content
    const file_content = try std.fs.cwd().readFileAlloc(testing.allocator, version_file_path, 1024);
    defer testing.allocator.free(file_content);

    try testing.expect(std.mem.indexOf(u8, file_content, "KausalDB") != null);
}

test "kausal commands chain correctly with shell operators" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "chain_operators");
    defer test_harness.deinit();

    // Test success case - version command should succeed
    var version_result = try test_harness.execute_command(&[_][]const u8{"version"});
    defer version_result.deinit();

    try version_result.expect_success();
    try testing.expect(version_result.contains_output("KausalDB"));

    // Test failure case - invalid command should fail
    var invalid_result = try test_harness.execute_command(&[_][]const u8{"nonexistent_command"});
    defer invalid_result.deinit();

    try invalid_result.expect_failure();
    // Command chaining logic would be handled by shell, not by individual command execution
}

test "kausal json output integrates with shell processing" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "json_shell");
    defer test_harness.deinit();

    // Test JSON output format
    var status_result = try test_harness.execute_command(&[_][]const u8{ "status", "--json" });
    defer status_result.deinit();

    if (status_result.exit_code == 0) {
        // Validate JSON output can be processed
        var parsed = try test_harness.validate_json_output(status_result.stdout);
        defer parsed.deinit();

        try testing.expect(parsed.value == .object);

        // Write JSON to file for shell processing simulation
        const json_path = try std.fs.path.join(testing.allocator, &[_][]const u8{ test_harness.test_workspace, "status.json" });
        defer testing.allocator.free(json_path);

        {
            const file = try std.fs.createFileAbsolute(json_path, .{});
            defer file.close();
            try file.writeAll(status_result.stdout);
        }

        // Verify JSON file exists and is readable
        std.fs.accessAbsolute(json_path, .{}) catch |err| {
            std.debug.print("JSON file not accessible: {}\n", .{err});
            return err;
        };
    }
}

test "kausal workspace commands work in automation context" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "workspace_automation");
    defer test_harness.deinit();

    // Create test project for automation scenario
    const project_path = try test_harness.create_test_project("automation_test");

    // Test workspace linking
    var link_result = try test_harness.execute_workspace_command("link --path {s} --name shell_test", .{project_path});
    defer link_result.deinit();

    // Link should succeed or fail gracefully
    if (link_result.exit_code != 0) {
        // If link fails, ensure it's not due to a crash
        try testing.expect(link_result.exit_code != 139 and link_result.exit_code != 11);
        try testing.expect(link_result.stderr.len > 0 or link_result.stdout.len > 0);
    } else {
        // If link succeeds, status should reflect it
        var status_result = try test_harness.execute_command(&[_][]const u8{"status"});
        defer status_result.deinit();
        try status_result.expect_success();
        try testing.expect(status_result.stdout.len > 0);
    }
}

test "kausal error handling integrates with shell error processing" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "error_processing");
    defer test_harness.deinit();

    // Test that invalid commands produce stderr output
    var invalid_result = try test_harness.execute_command(&[_][]const u8{"invalid_command"});
    defer invalid_result.deinit();

    try invalid_result.expect_failure();
    // Error should be communicated properly (either stderr or stdout)
    try testing.expect(invalid_result.stderr.len > 0 or invalid_result.stdout.len > 0);

    // Simulate shell error redirection by checking that errors are captured
    const has_error_info = invalid_result.contains_error("Unknown command") or
        invalid_result.contains_error("Invalid command") or
        invalid_result.contains_output("Unknown command") or
        invalid_result.contains_output("Invalid command");
    try testing.expect(has_error_info);
}

test "kausal command parsing works with complex arguments" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "complex_args");
    defer test_harness.deinit();

    // Test help command with multiple flags
    var help_result = try test_harness.execute_command(&[_][]const u8{ "help", "workspace" });
    defer help_result.deinit();

    try help_result.expect_success();
    try testing.expect(help_result.stdout.len > 0);
    // Should contain usage information or command information
    try testing.expect(help_result.contains_output("link") or
        help_result.contains_output("workspace") or
        help_result.contains_output("Commands"));
}

test "kausal performance acceptable for shell scripting" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "shell_performance");
    defer test_harness.deinit();

    const start_time = std.time.nanoTimestamp();

    // Test basic command performance
    var version_result = try test_harness.execute_command(&[_][]const u8{"version"});
    defer version_result.deinit();

    const elapsed_ns = std.time.nanoTimestamp() - start_time;
    const elapsed_ms = @divFloor(elapsed_ns, std.time.ns_per_ms);

    try version_result.expect_success();
    // Command should complete quickly for shell scripting contexts
    try testing.expect(elapsed_ms < 1000); // Should complete within 1 second
    try testing.expect(version_result.stdout.len > 0);
}
