//! Block lifecycle tracking for debugging model-storage desynchronization.
//!
//! Provides forensic analysis capabilities to trace blocks through their
//! complete lifecycle from model creation through WAL persistence, memtable
//! storage, SSTable flush, and compaction. Critical for debugging data loss
//! scenarios where acknowledged blocks disappear from storage.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.block_lifecycle_tracker);
const types = @import("../core/types.zig");
const BlockId = types.BlockId;

pub const LifecyclePhase = enum {
    model_add, // Block added to model state
    wal_write, // Block written to WAL
    memtable_add, // Block added to memtable
    sstable_flush, // Block flushed to SSTable
    compaction, // Block processed during compaction
    verification, // Block existence verification
};

pub const PhaseData = union(LifecyclePhase) {
    model_add: struct {
        sequence_number: u64,
        content_hash: u64,
        version: u32,
    },
    wal_write: struct {
        entry_sequence: u64,
        bytes_written: u64,
        expected_bytes: u64,
    },
    memtable_add: struct {
        arena_usage: u64,
        block_count: u32,
    },
    sstable_flush: struct {
        sstable_id: u32,
        blocks_flushed: u32,
    },
    compaction: struct {
        level: u8,
        input_sstables: u32,
        output_sstables: u32,
    },
    verification: struct {
        found: bool,
        content_matches: bool,
    },
};

pub const LifecycleEvent = struct {
    timestamp: u64,
    phase: LifecyclePhase,
    success: bool,
    data: PhaseData,
    error_message: ?[]const u8,

    pub fn init(phase: LifecyclePhase, success: bool, data: PhaseData, error_msg: ?[]const u8) LifecycleEvent {
        return LifecycleEvent{
            .timestamp = @as(u64, @intCast(std.time.nanoTimestamp())),
            .phase = phase,
            .success = success,
            .data = data,
            .error_message = error_msg,
        };
    }
};

pub const BlockLifecycle = struct {
    block_id: BlockId,
    events: std.array_list.Managed(LifecycleEvent),
    event_count: u32,
    first_seen: u64,
    last_seen: u64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, block_id: BlockId) BlockLifecycle {
        const now = @as(u64, @intCast(std.time.nanoTimestamp()));
        return BlockLifecycle{
            .block_id = block_id,
            .events = std.array_list.Managed(LifecycleEvent){ .items = &[_]LifecycleEvent{}, .capacity = 0, .allocator = allocator },
            .event_count = 0,
            .first_seen = now,
            .last_seen = now,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BlockLifecycle) void {
        self.events.deinit();
    }

    pub fn add_event(self: *BlockLifecycle, event: LifecycleEvent) !void {
        try self.events.append(event);
        self.event_count += 1;
        self.last_seen = event.timestamp;
    }

    pub fn generate_forensic_summary(self: *const BlockLifecycle, writer: anytype) !void {
        try writer.print("Block Lifecycle Analysis for {any}\n", .{self.block_id});
        try writer.print("Events: {} | First seen: {} | Last seen: {}\n", .{ self.event_count, self.first_seen, self.last_seen });

        for (self.events.items, 0..) |event, i| {
            try writer.print("  [{}] {s} @ {} success={}", .{ i, @tagName(event.phase), event.timestamp, event.success });

            switch (event.data) {
                .model_add => |data| {
                    try writer.print(" seq={} hash=0x{x} ver={}", .{ data.sequence_number, data.content_hash, data.version });
                },
                .wal_write => |data| {
                    try writer.print(" seq={} bytes={}/{}", .{ data.entry_sequence, data.bytes_written, data.expected_bytes });
                },
                .verification => |data| {
                    try writer.print(" found={} content_matches={}", .{ data.found, data.content_matches });
                },
                else => {},
            }

            if (event.error_message) |msg| {
                try writer.print(" error: {s}", .{msg});
            }
            try writer.print("\n", .{});
        }

        // Identify potential issue patterns
        var model_success = false;
        var wal_success = false;
        var verification_success = false;

        for (self.events.items) |event| {
            switch (event.phase) {
                .model_add => {
                    if (event.success) model_success = true;
                },
                .wal_write => {
                    if (event.success) wal_success = true;
                },
                .verification => {
                    if (event.success) verification_success = true;
                },
                else => {},
            }
        }

        try writer.print("Pattern Analysis: model={} wal={} verification={}\n", .{ model_success, wal_success, verification_success });

        if (model_success and wal_success and !verification_success) {
            try writer.print("CRITICAL: Block acknowledged but lost after storage - data loss detected!\n", .{});
        }
    }
};

pub const BlockLifecycleTracker = struct {
    blocks: std.HashMap(BlockId, BlockLifecycle, BlockIdContext, 80),
    allocator: std.mem.Allocator,
    enabled: bool,

    const BlockIdContext = struct {
        pub fn hash(self: @This(), block_id: BlockId) u64 {
            _ = self;
            return std.mem.readInt(u64, block_id.bytes[0..8], .little);
        }

        pub fn eql(self: @This(), a: BlockId, b: BlockId) bool {
            _ = self;
            return std.mem.eql(u8, &a.bytes, &b.bytes);
        }
    };

    pub fn init(allocator: std.mem.Allocator) BlockLifecycleTracker {
        return BlockLifecycleTracker{
            .blocks = std.HashMap(BlockId, BlockLifecycle, BlockIdContext, 80).init(allocator),
            .allocator = allocator,
            .enabled = builtin.mode == .Debug,
        };
    }

    pub fn deinit(self: *BlockLifecycleTracker) void {
        var iterator = self.blocks.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.blocks.deinit();
    }

    pub fn record_block_event(
        self: *BlockLifecycleTracker,
        block_id: BlockId,
        phase: LifecyclePhase,
        success: bool,
        data: PhaseData,
        error_message: ?[]const u8,
    ) void {
        if (!self.enabled) return;

        const event = LifecycleEvent.init(phase, success, data, error_message);

        if (self.blocks.getPtr(block_id)) |lifecycle| {
            lifecycle.add_event(event) catch return; // Ignore allocation failures in tracking
        } else {
            var new_lifecycle = BlockLifecycle.init(self.allocator, block_id);
            new_lifecycle.add_event(event) catch return;
            self.blocks.put(block_id, new_lifecycle) catch return;
        }
    }

    pub fn find_block_lifecycle(self: *const BlockLifecycleTracker, block_id: BlockId) ?*const BlockLifecycle {
        return self.blocks.getPtr(block_id);
    }

    pub fn focus_on_block(self: *BlockLifecycleTracker, block_id: BlockId) void {
        // Enable detailed tracking for specific block
        _ = block_id;
        _ = self;
        log.info("Focusing lifecycle analysis on target block", .{});
    }

    pub fn analyze_data_loss_patterns(self: *const BlockLifecycleTracker) void {
        if (!self.enabled) return;

        var data_loss_count: u32 = 0;
        var total_blocks: u32 = 0;

        var iterator = self.blocks.iterator();
        while (iterator.next()) |entry| {
            const lifecycle = entry.value_ptr;
            total_blocks += 1;

            var model_success = false;
            var wal_success = false;
            var verification_success = false;

            for (lifecycle.events.items) |event| {
                switch (event.phase) {
                    .model_add => {
                        if (event.success) model_success = true;
                    },
                    .wal_write => {
                        if (event.success) wal_success = true;
                    },
                    .verification => {
                        if (event.success) verification_success = true;
                    },
                    else => {},
                }
            }

            if (model_success and wal_success and !verification_success) {
                data_loss_count += 1;
            }
        }

        if (data_loss_count > 0) {
            log.warn("DATA LOSS ANALYSIS: {}/{} blocks show acknowledged-but-lost pattern", .{ data_loss_count, total_blocks });
        }
    }
};

const testing = std.testing;

test "basic tracking" {
    const allocator = testing.allocator;
    var tracker = BlockLifecycleTracker.init(allocator);
    defer tracker.deinit();

    const test_block = BlockId{ .bytes = [_]u8{1} ++ [_]u8{0} ** 15 };
    tracker.record_block_event(test_block, .model_add, true, .{ .model_add = .{
        .sequence_number = 42,
        .content_hash = 0x1234,
        .version = 1,
    } }, null);

    const lifecycle = tracker.find_block_lifecycle(test_block);
    try testing.expect(lifecycle != null);
    try testing.expect(lifecycle.?.event_count == 1);
}

test "forensic summary generation" {
    const allocator = testing.allocator;
    var tracker = BlockLifecycleTracker.init(allocator);
    defer tracker.deinit();

    const test_block = BlockId{ .bytes = [_]u8{2} ++ [_]u8{0} ** 15 };

    // Simulate data loss pattern: model + wal success, verification failure
    tracker.record_block_event(test_block, .model_add, true, .{ .model_add = .{
        .sequence_number = 100,
        .content_hash = 0xABCD,
        .version = 1,
    } }, null);

    tracker.record_block_event(test_block, .wal_write, true, .{ .wal_write = .{
        .entry_sequence = 50,
        .bytes_written = 1024,
        .expected_bytes = 1024,
    } }, null);

    tracker.record_block_event(test_block, .verification, false, .{ .verification = .{
        .found = false,
        .content_matches = false,
    } }, "Block missing from storage");

    const lifecycle = tracker.find_block_lifecycle(test_block).?;

    var buffer: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try lifecycle.generate_forensic_summary(stream.writer());

    const summary = buffer[0..stream.pos];
    try testing.expect(std.mem.containsAtLeast(u8, summary, 1, "CRITICAL: Block acknowledged but lost"));
}
