//! ProductionVFS integration tests.
//!
//! Tests the ProductionVFS implementation with real filesystem operations.
//! These tests perform actual I/O operations and are run as part of the
//! integration test suite to validate filesystem abstraction behavior.

const std = @import("std");
const testing = std.testing;

const production_vfs = @import("../../core/production_vfs.zig");
const vfs = @import("../../core/vfs.zig");

const ProductionVFS = production_vfs.ProductionVFS;
const VFS = vfs.VFS;

test "ProductionVFS basic file operations" {
    const allocator = testing.allocator;

    var prod_vfs = ProductionVFS.init(allocator);
    defer prod_vfs.deinit();
    const vfs_interface = prod_vfs.vfs();

    // Use unique file path to avoid conflicts between concurrent test runs
    const timestamp = std.time.nanoTimestamp();
    const test_path = try std.fmt.allocPrint(allocator, "/tmp/kausaldb_test_file_{}", .{timestamp});
    defer allocator.free(test_path);
    const test_data = "Hello, KausalDB!";

    {
        var write_file = try vfs_interface.create(test_path);
        defer write_file.close();

        const bytes_written = try write_file.write(test_data);
        try testing.expectEqual(test_data.len, bytes_written);
        try write_file.flush();
    }

    {
        var read_file = try vfs_interface.open(test_path, .read);
        defer {
            read_file.close();
            vfs_interface.remove(test_path) catch {};
        }

        var read_buffer: [256]u8 = undefined;
        const bytes_read = try read_file.read(&read_buffer);
        try testing.expectEqual(test_data.len, bytes_read);
        try testing.expectEqualStrings(test_data, read_buffer[0..bytes_read]);
    }
}

test "ProductionVFS directory operations" {
    const allocator = testing.allocator;

    var prod_vfs = ProductionVFS.init(allocator);
    defer prod_vfs.deinit();
    const vfs_interface = prod_vfs.vfs();

    // Use unique directory path to avoid conflicts
    const timestamp = std.time.nanoTimestamp();
    const test_dir = try std.fmt.allocPrint(allocator, "/tmp/kausaldb_test_dir_{}", .{timestamp});
    defer allocator.free(test_dir);

    // Create directory
    try vfs_interface.mkdir(test_dir);
    defer vfs_interface.rmdir(test_dir) catch {};

    // Verify directory exists by trying to create a file in it
    const test_file_path = try std.fmt.allocPrint(allocator, "{s}/test_file.txt", .{test_dir});
    defer allocator.free(test_file_path);

    {
        var test_file = try vfs_interface.create(test_file_path);
        defer test_file.close();

        const test_content = "Directory test content";
        const bytes_written = try test_file.write(test_content);
        try testing.expectEqual(test_content.len, bytes_written);
    }

    // Cleanup the file
    try vfs_interface.remove(test_file_path);
}

test "ProductionVFS global filesystem sync" {
    const allocator = testing.allocator;

    var prod_vfs = ProductionVFS.init(allocator);
    defer prod_vfs.deinit();
    const vfs_interface = prod_vfs.vfs();

    // Create a test file to ensure there's something to sync
    const timestamp = std.time.nanoTimestamp();
    const test_path = try std.fmt.allocPrint(allocator, "/tmp/kausaldb_sync_test_{}", .{timestamp});
    defer allocator.free(test_path);
    const test_data = "Sync test data";

    {
        var write_file = try vfs_interface.create(test_path);
        defer write_file.close();

        _ = try write_file.write(test_data);
        try write_file.flush();
    }

    // Test global sync - should not fail
    try vfs_interface.sync();

    // Cleanup
    vfs_interface.remove(test_path) catch {};
}

test "platform_global_sync coverage" {
    // Test platform-specific global sync behavior
    // This ensures the platform-specific implementations are exercised

    const allocator = testing.allocator;
    var prod_vfs = ProductionVFS.init(allocator);
    defer prod_vfs.deinit();

    // Test platform-specific global sync behavior through VFS interface
    // This ensures the platform-specific implementations are exercised
    const vfs_interface = prod_vfs.vfs();
    vfs_interface.sync() catch |err| {
        // Some platforms might not support global sync or it might fail
        // in test environments - we just want to ensure it doesn't crash
        switch (err) {
            error.AccessDenied, error.OutOfMemory => {
                // These are acceptable failures in test environments
                return;
            },
            else => return err,
        }
    };
}

test "ProductionVFS error handling" {
    const allocator = testing.allocator;

    var prod_vfs = ProductionVFS.init(allocator);
    defer prod_vfs.deinit();
    const vfs_interface = prod_vfs.vfs();

    // Test opening non-existent file
    const non_existent_path = "/tmp/kausaldb_does_not_exist_12345";
    try testing.expectError(error.FileNotFound, vfs_interface.open(non_existent_path, .read));

    // Test removing non-existent file
    try testing.expectError(error.FileNotFound, vfs_interface.remove(non_existent_path));

    // Test creating directory with invalid path (permission issues)
    const invalid_path = "/root/kausaldb_invalid_test";
    vfs_interface.mkdir(invalid_path) catch |err| {
        // Should fail with permission or similar error
        try testing.expect(err == error.AccessDenied or err == error.FileNotFound);
    };
}

test "ProductionVFS file permissions and metadata" {
    const allocator = testing.allocator;

    var prod_vfs = ProductionVFS.init(allocator);
    defer prod_vfs.deinit();
    const vfs_interface = prod_vfs.vfs();

    const timestamp = std.time.nanoTimestamp();
    const test_path = try std.fmt.allocPrint(allocator, "/tmp/kausaldb_perm_test_{}", .{timestamp});
    defer allocator.free(test_path);
    const test_data = "Permission test data";

    // Create and write file
    {
        var write_file = try vfs_interface.create(test_path);
        defer write_file.close();

        _ = try write_file.write(test_data);
        try write_file.flush();
    }

    // Verify file exists and has expected size
    const file_info = std.fs.cwd().statFile(test_path) catch |err| {
        // Cleanup before propagating error
        vfs_interface.remove(test_path) catch {};
        return err;
    };

    try testing.expectEqual(@as(u64, test_data.len), file_info.size);

    // Cleanup
    try vfs_interface.remove(test_path);
}
