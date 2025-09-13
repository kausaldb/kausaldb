//! Corruption recovery simulation tests.
//!
//! Consolidated deterministic tests for corruption detection and recovery.
//! Tests WAL corruption, SSTable corruption, and checksum validation.

const std = @import("std");
const testing = std.testing;

const harness = @import("../harness.zig");
const SimulationHarness = harness.SimulationHarness;
const Fault = harness.Fault;
const Workload = harness.Workload;

const types = @import("../../core/types.zig");
const ContextBlock = types.ContextBlock;
const BlockId = types.BlockId;

// === WAL Corruption Recovery ===

test "WAL recovery skips corrupted entries" {
    var sim = try SimulationHarness.init(testing.allocator, 0x1A1001);
    defer sim.deinit();

    try sim.init_storage();

    // Write known good entries
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        const block = ContextBlock{
            .id = BlockId.init(i),
            .content = "valid block",
            .metadata = .{},
        };
        try sim.storage.put_block(&block);
    }

    // Corrupt specific WAL entries
    try sim.inject_fault(.{ .corrupt_block = .{ .offset = 256, .pattern = 0xFF } });
    try sim.inject_fault(.{ .corrupt_block = .{ .offset = 512, .pattern = 0x00 } });
    try sim.inject_fault(.{ .corrupt_block = .{ .offset = 768, .pattern = 0xDE } });

    // Simulate crash
    try sim.inject_fault(.{ .crash = .{ .clean = false, .at_operation = sim.operation_count } });

    // Recovery should skip corrupted entries and recover valid ones
    sim.recover_storage() catch |err| {
        // Some corruption errors are expected during recovery
        try testing.expect(err == error.CorruptedEntry or
            err == error.ChecksumMismatch or
            err == error.CorruptedData);
    };

    // Verify some blocks were recovered
    sim.verify_partial_recovery() catch |err| {
        // Partial recovery is acceptable
        try testing.expect(err == error.PartialRecovery);
    };
}

test "WAL torn write recovery" {
    var sim = try SimulationHarness.init(testing.allocator, 0x7042);
    defer sim.deinit();

    try sim.init_storage();

    // Write blocks
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        const block = ContextBlock{
            .id = BlockId.init(i),
            .content = "test block",
            .metadata = .{},
        };
        try sim.storage.put_block(&block);
    }

    // Simulate torn write (partial write at end of WAL)
    const wal_size = try sim.get_wal_size();
    try sim.inject_fault(.{
        .torn_write = .{
            .offset = wal_size - 50, // Last entry partially written
            .bytes_written = 25,
        },
    });

    // Crash and recover
    try sim.inject_fault(.{ .crash = .{ .clean = false, .at_operation = sim.operation_count } });

    // Recovery should handle torn write gracefully
    try sim.recover_storage();

    // Verify blocks before torn write are recovered
    var recovered: u32 = 0;
    i = 0;
    while (i < 20) : (i += 1) {
        if (sim.storage.get_block(BlockId.init(i))) |_| {
            recovered += 1;
        } else |_| {
            // Block after torn write may not be recovered
        }
    }

    try testing.expect(recovered >= 15); // Most blocks should be recovered
}

test "WAL checksum validation" {
    var sim = try SimulationHarness.init(testing.allocator, 0xC4EC4);
    defer sim.deinit();

    try sim.init_storage();

    // Write blocks with checksums
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        const block = ContextBlock{
            .id = BlockId.init(i),
            .content = "checksummed block",
            .metadata = .{},
        };
        try sim.storage.put_block(&block);
    }

    // Corrupt checksum fields specifically
    try sim.inject_fault(.{ .corrupt_checksum = .{ .entry_index = 1 } });
    try sim.inject_fault(.{ .corrupt_checksum = .{ .entry_index = 3 } });

    // Recovery should detect and skip entries with bad checksums
    try sim.inject_fault(.{ .crash = .{ .clean = false, .at_operation = sim.operation_count } });
    sim.recover_storage() catch |err| {
        try testing.expect(err == error.ChecksumMismatch);
    };

    // Verify uncorrupted entries are recovered
    try testing.expect(sim.storage.get_block(BlockId.init(0)) != null);
    try testing.expect(sim.storage.get_block(BlockId.init(2)) != null);
    try testing.expect(sim.storage.get_block(BlockId.init(4)) != null);
}

// === SSTable Corruption Recovery ===

test "SSTable header corruption detection" {
    var sim = try SimulationHarness.init(testing.allocator, 0x554EAD);
    defer sim.deinit();

    try sim.init_storage();

    // Fill memtable and flush to create SSTable
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        const block = ContextBlock{
            .id = BlockId.init(i),
            .content = "sstable block",
            .metadata = .{},
        };
        try sim.storage.put_block(&block);
    }
    try sim.storage.flush_memtable();

    // Corrupt SSTable header
    const sstable_path = try sim.get_sstable_path(0);
    try sim.inject_fault(.{
        .corrupt_file = .{
            .path = sstable_path,
            .offset = 0, // Header starts at offset 0
            .pattern = 0xBA,
        },
    });

    // Restart storage
    try sim.inject_fault(.{ .crash = .{ .clean = true, .at_operation = sim.operation_count } });

    // Recovery should detect corrupted SSTable
    sim.recover_storage() catch |err| {
        try testing.expect(err == error.CorruptedHeader or
            err == error.InvalidMagic);
    };

    // Storage should still be functional (skip corrupted SSTable)
    const new_block = ContextBlock{
        .id = BlockId.init(9999),
        .content = "new block after corruption",
        .metadata = .{},
    };
    try sim.storage.put_block(&new_block);
}

test "SSTable block corruption isolation" {
    var sim = try SimulationHarness.init(testing.allocator, 0x55B10C);
    defer sim.deinit();

    try sim.init_storage();

    // Create multiple SSTables
    var sstable: u32 = 0;
    while (sstable < 3) : (sstable += 1) {
        var i: u32 = 0;
        while (i < 500) : (i += 1) {
            const block = ContextBlock{
                .id = BlockId.init(sstable * 1000 + i),
                .content = "sstable content",
                .metadata = .{},
            };
            try sim.storage.put_block(&block);
        }
        try sim.storage.flush_memtable();
    }

    // Corrupt one block in middle SSTable
    const sstable_path = try sim.get_sstable_path(1);
    try sim.inject_fault(.{
        .corrupt_file = .{
            .path = sstable_path,
            .offset = 1024, // Somewhere in the data section
            .pattern = 0xDD,
        },
    });

    // Read operations should detect corruption
    const corrupted_id = BlockId.init(1250); // Block in corrupted SSTable
    const result = sim.storage.get_block(corrupted_id);
    try testing.expect(result == error.ChecksumMismatch or
        result == error.CorruptedData);

    // Other SSTables should still be readable
    try testing.expect(sim.storage.get_block(BlockId.init(250)) != null); // First SSTable
    try testing.expect(sim.storage.get_block(BlockId.init(2250)) != null); // Third SSTable
}

// === Multi-Fault Recovery ===

test "recovery with multiple corruption types" {
    var sim = try SimulationHarness.init(testing.allocator, 0x30171);
    defer sim.deinit();

    try sim.init_storage();

    // Write diverse data
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const block = ContextBlock{
            .id = BlockId.init(i),
            .content = "test data",
            .metadata = .{},
        };
        try sim.storage.put_block(&block);

        // Flush periodically to create SSTables
        if (i % 30 == 29) {
            try sim.storage.flush_memtable();
        }
    }

    // Inject multiple corruption types
    try sim.inject_fault(.{ .corrupt_block = .{ .offset = 128, .pattern = 0xFF } }); // WAL corruption
    try sim.inject_fault(.{ .corrupt_checksum = .{ .entry_index = 5 } }); // Checksum corruption
    try sim.inject_fault(.{ .torn_write = .{ .offset = 2048, .bytes_written = 30 } }); // Torn write

    // Crash
    try sim.inject_fault(.{ .crash = .{ .clean = false, .at_operation = sim.operation_count } });

    // Recovery should handle multiple corruption types
    sim.recover_storage() catch |err| {
        // Expected to encounter corruption
        try testing.expect(err == error.CorruptedData or
            err == error.PartialRecovery);
    };

    // Some data should be recovered
    var recovered_count: u32 = 0;
    i = 0;
    while (i < 100) : (i += 1) {
        if (sim.storage.get_block(BlockId.init(i))) |_| {
            recovered_count += 1;
        } else |_| {}
    }

    try testing.expect(recovered_count > 50); // At least half should be recovered
}

test "corruption detection during compaction" {
    var sim = try SimulationHarness.init(testing.allocator, 0xC03BAC7);
    defer sim.deinit();

    try sim.init_storage();

    // Create SSTables
    var batch: u32 = 0;
    while (batch < 4) : (batch += 1) {
        var i: u32 = 0;
        while (i < 250) : (i += 1) {
            const block = ContextBlock{
                .id = BlockId.init(batch * 1000 + i),
                .content = "compaction test",
                .metadata = .{},
            };
            try sim.storage.put_block(&block);
        }
        try sim.storage.flush_memtable();
    }

    // Corrupt one SSTable
    const sstable_path = try sim.get_sstable_path(2);
    try sim.inject_fault(.{ .corrupt_file = .{ .path = sstable_path, .offset = 512, .pattern = 0xAB } });

    // Trigger compaction
    sim.storage.compact() catch |err| {
        // Compaction should detect corruption
        try testing.expect(err == error.CorruptedData or
            err == error.ChecksumMismatch);
    };

    // Verify uncorrupted data is still accessible
    try testing.expect(sim.storage.get_block(BlockId.init(100)) != null);
    try testing.expect(sim.storage.get_block(BlockId.init(1100)) != null);
    try testing.expect(sim.storage.get_block(BlockId.init(3100)) != null);
}

// === Systematic Corruption Patterns ===

test "systematic bit flip recovery" {
    var sim = try SimulationHarness.init(testing.allocator, 0xB17F11B);
    defer sim.deinit();

    try sim.init_storage();

    // Write known pattern
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        const block = ContextBlock{
            .id = BlockId.init(i),
            .content = "bit flip test",
            .metadata = .{},
        };
        try sim.storage.put_block(&block);
    }

    // Inject systematic bit flips
    var offset: u64 = 100;
    while (offset < 1000) : (offset += 100) {
        try sim.inject_fault(.{ .bit_flip = .{ .offset = offset, .bit_index = @as(u3, offset % 8) } });
    }

    // Crash and recover
    try sim.inject_fault(.{ .crash = .{ .clean = false, .at_operation = sim.operation_count } });

    sim.recover_storage() catch |err| {
        try testing.expect(err == error.CorruptedData);
    };

    // Verify error detection and partial recovery
    try sim.verify_corruption_detection();
}

test "progressive corruption degradation" {
    var sim = try SimulationHarness.init(testing.allocator, 0xDE62ADE);
    defer sim.deinit();

    try sim.init_storage();

    // Monitor corruption impact over time
    var corruption_level: u32 = 0;
    while (corruption_level < 10) : (corruption_level += 1) {
        // Write fresh data
        var i: u32 = 0;
        while (i < 10) : (i += 1) {
            const block = ContextBlock{
                .id = BlockId.init(corruption_level * 100 + i),
                .content = "degradation test",
                .metadata = .{},
            };
            try sim.storage.put_block(&block);
        }

        // Inject increasing corruption
        var c: u32 = 0;
        while (c <= corruption_level) : (c += 1) {
            try sim.inject_fault(.{ .corrupt_block = .{ .offset = c * 50, .pattern = @as(u8, c) } });
        }

        // Test read reliability
        var read_errors: u32 = 0;
        i = 0;
        while (i < corruption_level * 100) : (i += 1) {
            sim.storage.get_block(BlockId.init(i)) catch {
                read_errors += 1;
            };
        }

        // Verify degradation is bounded
        const error_rate = @as(f32, read_errors) / @as(f32, i);
        try testing.expect(error_rate < 0.5); // Less than 50% error rate
    }
}
