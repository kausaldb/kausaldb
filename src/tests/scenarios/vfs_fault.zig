//! VFS fault injection scenario tests.
//!
//! These tests validate that the SimulationVFS correctly handles disk space
//! limitations when fault injection is explicitly enabled, while allowing
//! unlimited writes for normal correctness testing.

const std = @import("std");
const testing = std.testing;

// Internal modules
const simulation_vfs = @import("../../sim/simulation_vfs.zig");
const vfs = @import("../../core/vfs.zig");

// Type aliases
const SimulationVFS = simulation_vfs.SimulationVFS;
const VFS = vfs.VFS;
const VFile = vfs.VFile;
const VFileError = vfs.VFileError;

test "vfs_default_mode_allows_unlimited_writes" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    const vfs_interface = sim_vfs.vfs();

    var file = try vfs_interface.create("unlimited_test.dat");
    defer {
        file.close();
        vfs_interface.remove("unlimited_test.dat") catch {};
    }

    // Write 200MB of data - should succeed with default unlimited space
    const chunk_size = 1024 * 1024; // 1MB
    const chunk_data = try allocator.alloc(u8, chunk_size);
    defer allocator.free(chunk_data);
    @memset(chunk_data, 'U');

    // This would exceed the old 100MB limit, but should work fine now
    for (0..200) |_| {
        const written = try file.write(chunk_data);
        try testing.expectEqual(chunk_size, written);
    }

    const final_size = try file.seek(0, .end);
    try testing.expectEqual(200 * chunk_size, final_size);
}

test "vfs_fault_testing_mode_enforces_realistic_limits" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    // Enable fault testing mode - this should impose 100MB limit
    sim_vfs.enable_fault_testing_mode();

    const vfs_interface = sim_vfs.vfs();

    var file = try vfs_interface.create("fault_test.dat");
    defer {
        file.close();
        vfs_interface.remove("fault_test.dat") catch {};
    }

    const chunk_size = 1024 * 1024; // 1MB
    const chunk_data = try allocator.alloc(u8, chunk_size);
    defer allocator.free(chunk_data);
    @memset(chunk_data, 'F');

    var writes_succeeded: u32 = 0;

    // Try to write 150MB - should fail before completion due to 100MB limit
    for (0..150) |_| {
        const result = file.write(chunk_data);
        if (result) |written| {
            try testing.expectEqual(chunk_size, written);
            writes_succeeded += 1;
        } else |err| switch (err) {
            error.NoSpaceLeft => break, // Expected - fault mode working
            else => return err,
        }
    }

    // Should have failed at or before 100MB (100 writes)
    try testing.expect(writes_succeeded <= 100);
}

test "vfs_configure_disk_space_limit_precise_control" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    // Set precise 10MB limit
    sim_vfs.configure_disk_space_limit(10 * 1024 * 1024);

    const vfs_interface = sim_vfs.vfs();

    var file = try vfs_interface.create("precise_test.dat");
    defer {
        file.close();
        vfs_interface.remove("precise_test.dat") catch {};
    }

    const data_5mb = try allocator.alloc(u8, 5 * 1024 * 1024);
    defer allocator.free(data_5mb);
    @memset(data_5mb, 'P');

    // First 5MB should succeed
    const written1 = try file.write(data_5mb);
    try testing.expectEqual(5 * 1024 * 1024, written1);

    // Second 5MB should succeed (exactly at 10MB limit)
    const written2 = try file.write(data_5mb);
    try testing.expectEqual(5 * 1024 * 1024, written2);

    // Third 5MB should fail - exceeds limit
    const result = file.write(data_5mb);
    try testing.expectError(VFileError.NoSpaceLeft, result);
}
