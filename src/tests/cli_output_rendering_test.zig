//! CLI integration tests with I/O operations.
//!
//! Tests full rendering pipeline with actual file operations and output capture.
//! These tests have side effects and validate end-to-end CLI behavior.

const std = @import("std");
const testing = std.testing;

const protocol = @import("../cli/protocol.zig");
const renderer = @import("../cli/renderer.zig");

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

    errdefer std.debug.print("EXPECTED OUTPUT: \n", .{});
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

    errdefer std.debug.print("ACTUAL OUTPUT: \n", .{});
    errdefer std.debug.print("{s}", .{actual_output});

    // Compare with expected output
    try testing.expectEqualStrings(expected_output, actual_output);
}
