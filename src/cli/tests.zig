//! Unit tests for CLI.
//!
//! Pure unit tests with no I/O operations, focusing on parser logic,
//! protocol serialization, command structure validation, and status rendering.

const std = @import("std");
const testing = std.testing;

const parser = @import("parser.zig");
const protocol = @import("protocol.zig");
const renderer = @import("renderer.zig");
const types = @import("../core/types.zig");

const BlockId = types.BlockId;

// === Minimal Struct Validation Tests ===

test "WorkspaceInfo basic operations without corruption" {
    // Test each sync status individually to isolate corruption
    const test_cases = [_]struct {
        name: []const u8,
        status: protocol.WorkspaceSyncStatus,
        expected_icon: []const u8,
        expected_text: []const u8,
    }{
        .{ .name = "synced-test", .status = .synced, .expected_icon = "✓", .expected_text = "synced" },
        .{ .name = "needs-sync-test", .status = .needs_sync, .expected_icon = "⚠", .expected_text = "sync needed" },
        .{ .name = "sync-error-test", .status = .sync_error, .expected_icon = "✗", .expected_text = "sync failed" },
        .{ .name = "never-synced-test", .status = .never_synced, .expected_icon = "⚠", .expected_text = "never synced" },
    };

    for (test_cases) |case| {
        // Create workspace info
        const workspace = protocol.WorkspaceInfo.init_with_status(
            case.name,
            "/test/path",
            100,
            200,
            1640995200,
            case.status,
            1024 * 1024,
        );

        // Verify enum value is preserved correctly
        try testing.expectEqual(case.status, workspace.sync_status);

        // Test methods with pointer (no copying)
        const workspace_ptr = &workspace;

        try testing.expectEqualStrings(case.name, workspace_ptr.name_text());
        try testing.expectEqualStrings("/test/path", workspace_ptr.path_text());
        try testing.expectEqualStrings(case.expected_icon, workspace_ptr.status_icon());
        try testing.expectEqualStrings(case.expected_text, workspace_ptr.status_text());

        // Test storage formatting doesn't crash
        const storage_str = try workspace_ptr.format_storage_size(testing.allocator);
        defer testing.allocator.free(storage_str);
        try testing.expect(storage_str.len > 0);

        // Test time formatting doesn't crash
        const time_str = try workspace_ptr.format_last_sync(testing.allocator, 1640995200);
        defer testing.allocator.free(time_str);
        try testing.expect(time_str.len > 0);
    }
}

test "cli status output exact snapshot" {
    // Get current time and calculate recent timestamps
    const current_time: i64 = std.time.timestamp();

    // Create status response with exact values to match expected output
    var status = protocol.StatusResponse.init();
    status.block_count = 0; // Not shown in basic status
    status.edge_count = 0; // Not shown in basic status
    status.sstable_count = 0; // Not shown in basic status
    status.memtable_size = 0; // Not shown in basic status
    status.total_disk_usage = 888143872; // Exactly 847 MB
    status.uptime_seconds = 8100; // Exactly 2h 15m

    // Create workspaces with timestamps very close to current time
    // Use small offsets to get predictable "ago" text
    const workspace1 = protocol.WorkspaceInfo.init_with_status(
        "web-ui",
        "/projects/web-ui",
        340, // block count
        150, // edge count
        current_time - 2, // 2 seconds ago
        .synced,
        356515840, // Exactly 340 MB
    );

    const workspace2 = protocol.WorkspaceInfo.init_with_status(
        "backend",
        "/projects/backend",
        502, // block count
        800, // edge count
        current_time - 5, // 5 seconds ago
        .synced,
        526385152, // Exactly 502 MB
    );

    const workspace3 = protocol.WorkspaceInfo.init_with_status(
        "docs",
        "/projects/docs",
        5, // block count
        10, // edge count
        current_time - 10, // 10 seconds ago
        .needs_sync,
        5242880, // Exactly 5 MB
    );

    status.add_workspace(&workspace1);
    status.add_workspace(&workspace2);
    status.add_workspace(&workspace3);

    // Create temporary file to capture output
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const temp_file = try tmp_dir.dir.createFile("output.txt", .{ .read = true });
    defer temp_file.close();

    var file_buffer: [4096]u8 = undefined;
    var render_ctx = renderer.RenderContext.init(testing.allocator, temp_file.writer(file_buffer[0..]), .text);

    // Expected output - exact match for the desired CLI appearance
    const expected_output =
        \\KausalDB Status
        \\├─ Server: Running (uptime: 2h 15m)
        \\├─ Workspaces: 3 linked
        \\└─ Storage: 847.0 MB used
        \\
        \\Workspaces:
        \\  ✓ web-ui          synced 2s ago   (340.0 MB)
        \\  ✓ backend         synced 5s ago   (502.0 MB)
        \\  ⚠ docs            sync needed 10s ago  (5.0 MB)
        \\
    ;

    errdefer std.debug.print("=== EXPECTED OUTPUT ===\n", .{});
    errdefer std.debug.print("{s}", .{expected_output});

    // Render the status to temp file
    try renderer.render_status(&render_ctx, status, false);
    try render_ctx.flush();

    // Read back the captured output
    try temp_file.seekTo(0);
    const file_size = try temp_file.getEndPos();
    const actual_output = try testing.allocator.alloc(u8, file_size);
    defer testing.allocator.free(actual_output);
    _ = try temp_file.readAll(actual_output);

    errdefer std.debug.print("=== ACTUAL OUTPUT ===\n", .{});
    errdefer std.debug.print("{s}", .{actual_output});

    // Compare with expected output
    try testing.expectEqualStrings(expected_output, actual_output);
}

// === Format Utility Tests ===

test "format_bytes produces human-readable output" {
    const test_cases = [_]struct {
        bytes: u64,
        expected: []const u8,
    }{
        .{ .bytes = 0, .expected = "0 B" },
        .{ .bytes = 1024, .expected = "1.0 KB" },
        .{ .bytes = 1048576, .expected = "1.0 MB" },
        .{ .bytes = 1073741824, .expected = "1.0 GB" },
    };

    for (test_cases) |case| {
        const result = try protocol.format_bytes(testing.allocator, case.bytes);
        defer testing.allocator.free(result);
        try testing.expectEqualStrings(case.expected, result);
    }
}

test "format_uptime produces human-readable output" {
    const test_cases = [_]struct {
        seconds: u64,
        expected_contains: []const u8,
    }{
        .{ .seconds = 65, .expected_contains = "1m" },
        .{ .seconds = 3665, .expected_contains = "1h" },
        .{ .seconds = 7200, .expected_contains = "2h" },
    };

    for (test_cases) |case| {
        const result = try protocol.format_uptime(testing.allocator, case.seconds);
        defer testing.allocator.free(result);
        try testing.expect(std.mem.indexOf(u8, result, case.expected_contains) != null);
    }
}

// === Protocol Tests ===

test "MessageHeader validates correctly" {
    var header = protocol.MessageHeader{
        .magic = 0x4B41554C, // Correct magic
        .version = protocol.PROTOCOL_VERSION,
        .message_type = .ping_request,
        .payload_size = 0,
    };

    try header.validate(); // Should not error
}

test "WorkspaceInfo handles empty names gracefully" {
    const workspace = protocol.WorkspaceInfo.init_with_status(
        "", // Empty name
        "",
        0,
        0,
        0,
        .never_synced,
        0,
    );

    const name = workspace.name_text();
    try testing.expectEqualStrings("", name);
}

test "StatusResponse manages workspace count correctly" {
    var status = protocol.StatusResponse.init();
    try testing.expectEqual(@as(u32, 0), status.workspace_count);

    // Add maximum workspaces
    var i: u32 = 0;
    while (i < protocol.MAX_WORKSPACES_PER_STATUS) : (i += 1) {
        const workspace = protocol.WorkspaceInfo.init_with_status(
            "test",
            "/path",
            10,
            20,
            1640995200,
            .synced,
            1024,
        );
        status.add_workspace(&workspace);
    }

    try testing.expectEqual(protocol.MAX_WORKSPACES_PER_STATUS, status.workspace_count);

    // Adding one more should not crash or increase count
    const extra_workspace = protocol.WorkspaceInfo.init_with_status(
        "extra",
        "/extra",
        5,
        10,
        1640995200,
        .synced,
        512,
    );
    status.add_workspace(&extra_workspace);

    try testing.expectEqual(protocol.MAX_WORKSPACES_PER_STATUS, status.workspace_count);
}
