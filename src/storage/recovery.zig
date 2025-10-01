//! WAL recovery coordination and validation for storage engine.
//!
//! Provides utilities for coordinating WAL recovery operations across
//! storage subsystems. Handles recovery callbacks, state validation,
//! and error recovery scenarios to ensure consistent system state
//! after crashes or restarts. Works with the WAL module to replay
//! operations and reconstruct storage engine state.

const std = @import("std");

const block_index = @import("block_index.zig");
const concurrency = @import("../core/concurrency.zig");
const context_block = @import("../core/types.zig");
const graph_edge_index = @import("graph_edge_index.zig");
const memory = @import("../core/memory.zig");
const tombstone = @import("tombstone.zig");
const ownership = @import("../core/ownership.zig");
const simulation_vfs = @import("../sim/simulation_vfs.zig");
const wal = @import("wal.zig");

const log = std.log.scoped(.storage_recovery);
const testing = std.testing;

const ArenaCoordinator = memory.ArenaCoordinator;
const BlockId = context_block.BlockId;
const BlockIndex = block_index.BlockIndex;
const ContextBlock = context_block.ContextBlock;
const GraphEdge = context_block.GraphEdge;
const GraphEdgeIndex = graph_edge_index.GraphEdgeIndex;
const SimulationVFS = simulation_vfs.SimulationVFS;
const TombstoneRecord = tombstone.TombstoneRecord;
const WALEntry = wal.WALEntry;

/// Recovery statistics for monitoring and debugging.
pub const RecoveryStats = struct {
    blocks_recovered: u32,
    edges_recovered: u32,
    tombstones_recovered: u32,
    recovery_time_ns: u64,
    corrupted_entries_skipped: u32,
    total_entries_processed: u32,

    pub fn init() RecoveryStats {
        return RecoveryStats{
            .blocks_recovered = 0,
            .edges_recovered = 0,
            .tombstones_recovered = 0,
            .recovery_time_ns = 0,
            .corrupted_entries_skipped = 0,
            .total_entries_processed = 0,
        };
    }

    /// Calculate recovery throughput in entries per second.
    pub fn entries_per_second(self: RecoveryStats) f64 {
        if (self.recovery_time_ns == 0) return 0.0;
        const time_seconds = @as(f64, @floatFromInt(self.recovery_time_ns)) / 1_000_000_000.0;
        return @as(f64, @floatFromInt(self.total_entries_processed)) / time_seconds;
    }

    /// Get corruption rate as percentage of total entries.
    pub fn corruption_rate(self: RecoveryStats) f64 {
        if (self.total_entries_processed == 0) return 0.0;
        return (@as(f64, @floatFromInt(self.corrupted_entries_skipped)) / @as(f64, @floatFromInt(self.total_entries_processed))) * 100.0;
    }
};

/// Recovery errors specific to storage engine state reconstruction.
pub const RecoveryError = error{
    /// Recovery context is null or invalid
    InvalidRecoveryContext,
    /// Block index corruption detected during recovery
    BlockIndexCorruption,
    /// Graph index corruption detected during recovery
    GraphIndexCorruption,
    /// Inconsistent state detected after recovery
    InconsistentRecoveryState,
} || wal.WALError;

/// Recovery context passed to WAL recovery callbacks.
/// Contains references to storage subsystems that need state reconstruction
/// and tracks recovery progress for monitoring and validation.
pub const RecoveryContext = struct {
    block_index: *BlockIndex,
    graph_index: *GraphEdgeIndex,
    stats: RecoveryStats,
    start_time: i128,

    /// Initialize recovery context with storage subsystems.
    /// Records start time for performance measurement.
    pub fn init(block_idx: *BlockIndex, graph_idx: *GraphEdgeIndex) RecoveryContext {
        return RecoveryContext{
            .block_index = block_idx,
            .graph_index = graph_idx,
            .stats = RecoveryStats.init(),
            .start_time = std.time.nanoTimestamp(),
        };
    }

    /// Finalize recovery statistics with total elapsed time.
    pub fn finalize(self: *RecoveryContext) void {
        const end_time = std.time.nanoTimestamp();
        // Safety: Recovery time difference is always positive and within u64 range
        self.stats.recovery_time_ns = @intCast(end_time - self.start_time);
    }

    /// Validate storage state consistency after recovery.
    /// Performs basic sanity checks to detect corruption or inconsistencies
    /// that could lead to incorrect behavior during normal operations.
    pub fn validate_recovery_state(self: *const RecoveryContext) RecoveryError!void {
        // Verify block index is in valid state
        if (@as(u32, @intCast(self.block_index.blocks.count())) > 0) {
            // Memory usage should be positive if blocks exist
            if (self.block_index.memory_used == 0) {
                return RecoveryError.BlockIndexCorruption;
            }
        }

        // Verify graph index consistency
        const edge_count = self.graph_index.edge_count();
        const source_count = @as(u32, @intCast(self.graph_index.outgoing_edges.count()));
        const target_count = @as(u32, @intCast(self.graph_index.incoming_edges.count()));

        // Edge count should be consistent with index structure
        if (edge_count > 0 and source_count == 0) {
            return RecoveryError.GraphIndexCorruption;
        }

        if (source_count > edge_count or target_count > edge_count) {
            log.warn("GraphIndex validation failed: edge_count={}, source_count={}, target_count={}", .{ edge_count, source_count, target_count });
            return RecoveryError.GraphIndexCorruption;
        }
    }
};

/// Standard WAL recovery callback for storage engine state reconstruction.
/// Applies WAL entries to rebuild block index and graph index state.
/// Tracks statistics and handles error conditions gracefully to maximize
/// data recovery even with partial corruption.
pub fn apply_wal_entry_to_storage(entry: WALEntry, context: *anyopaque) wal.WALError!void {
    // Safety: Context is guaranteed to be *RecoveryContext by the recovery system
    const recovery_ctx: *RecoveryContext = @ptrCast(@alignCast(context));

    recovery_ctx.stats.total_entries_processed += 1;

    switch (entry.entry_type) {
        .put_block => {
            const owned_block = entry.extract_block(recovery_ctx.block_index.arena_coordinator.allocator()) catch |err| {
                log.warn("Failed to extract block from WAL entry: {any}", .{err});
                recovery_ctx.stats.corrupted_entries_skipped += 1;
                return;
            };
            const block = owned_block.read(.storage_engine);
            recovery_ctx.block_index.put_block(block.*) catch |err| {
                // Log corruption but continue recovery to maximize data salvage
                log.warn("Failed to recover block {any}: {any}", .{ block.id, err });
                recovery_ctx.stats.corrupted_entries_skipped += 1;
                return;
            };
            recovery_ctx.stats.blocks_recovered += 1;
        },
        .tombstone_block => {
            const tombstone_record = TombstoneRecord.deserialize(entry.payload) catch |err| {
                log.warn("Failed to extract tombstone from WAL entry: {any}", .{err});
                recovery_ctx.stats.corrupted_entries_skipped += 1;
                return;
            };
            recovery_ctx.block_index.put_tombstone(tombstone_record) catch |err| {
                log.warn("Failed to recover tombstone for block {any}: {any}", .{ tombstone_record.block_id, err });
                recovery_ctx.stats.corrupted_entries_skipped += 1;
                return;
            };
            recovery_ctx.graph_index.remove_block_edges(tombstone_record.block_id);
            recovery_ctx.stats.tombstones_recovered += 1;
        },
        .put_edge => {
            const edge = entry.extract_edge() catch |err| {
                log.warn("Failed to extract edge from WAL entry: {any}", .{err});
                recovery_ctx.stats.corrupted_entries_skipped += 1;
                return;
            };
            recovery_ctx.graph_index.put_edge(edge) catch |err| {
                // Log corruption but continue recovery
                log.warn("Failed to recover edge {any} -> {any}: {any}", .{ edge.source_id, edge.target_id, err });
                recovery_ctx.stats.corrupted_entries_skipped += 1;
                return;
            };
            recovery_ctx.stats.edges_recovered += 1;
        },
    }
}

/// Perform complete storage recovery from WAL with validation.
/// High-level interface that coordinates WAL recovery, state validation,
/// and error handling. Returns detailed statistics for monitoring.
pub fn recover_storage_from_wal(
    wal_instance: *wal.WAL,
    block_idx: *BlockIndex,
    graph_idx: *GraphEdgeIndex,
) !RecoveryStats {
    concurrency.assert_main_thread();

    var recovery_context = RecoveryContext.init(block_idx, graph_idx);

    // Clear existing state to ensure clean recovery
    block_idx.clear();
    graph_idx.clear();

    // Perform WAL recovery with our callback
    try wal_instance.recover_entries(apply_wal_entry_to_storage, &recovery_context);

    // Finalize timing and validate result
    recovery_context.finalize();
    try recovery_context.validate_recovery_state();

    log.info("Recovery completed: {} blocks, {} edges, {} corrupted entries in {}ms", .{
        recovery_context.stats.blocks_recovered,
        recovery_context.stats.edges_recovered,
        recovery_context.stats.corrupted_entries_skipped,
        recovery_context.stats.recovery_time_ns / 1_000_000,
    });

    return recovery_context.stats;
}

/// Create a minimal recovery test setup for unit testing.
/// Provides pre-configured storage subsystems suitable for recovery testing
/// without requiring full storage engine initialization.
const TestRecoverySetup = struct {
    arena: std.heap.ArenaAllocator,
    coordinator: ArenaCoordinator,
    block_index: BlockIndex,
    graph_index: GraphEdgeIndex,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *@This()) void {
        self.block_index.deinit();
        self.graph_index.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

pub fn create_test_recovery_setup(allocator: std.mem.Allocator) !*TestRecoverySetup {
    var setup_ptr = try allocator.create(TestRecoverySetup);
    setup_ptr.allocator = allocator;
    setup_ptr.arena = std.heap.ArenaAllocator.init(allocator);
    setup_ptr.coordinator = ArenaCoordinator.init(&setup_ptr.arena);
    setup_ptr.block_index = BlockIndex.init(&setup_ptr.coordinator, allocator);
    setup_ptr.graph_index = GraphEdgeIndex.init(allocator);

    return setup_ptr;
}
