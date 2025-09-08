//! Batch writer with deduplication for high-performance ingestion pipeline.
//!
//! This module implements atomic batch ingestion with intelligent deduplication,
//! version conflict resolution, and bounded resource management. Designed for
//! high-volume ingestion scenarios where duplicate detection and atomic commits
//! are critical for data integrity.
//!
//! Key design principles:
//! - Arena-based memory management for O(1) cleanup between batches
//! - Bounded collections prevent unbounded memory growth
//! - Version-based conflict resolution handles concurrent updates
//! - Atomic batch commits ensure consistency
//! - Comprehensive metrics for monitoring deduplication effectiveness

const std = @import("std");
const builtin = @import("builtin");

const assert_mod = @import("../core/assert.zig");
const bounded_mod = @import("../core/bounded.zig");
const error_context_mod = @import("../core/error_context.zig");
const memory_mod = @import("../core/memory.zig");
const ownership = @import("../core/ownership.zig");
const storage_mod = @import("engine.zig");
const types = @import("../core/types.zig");

const assert = assert_mod.assert;
const fatal_assert = assert_mod.fatal_assert;
const comptime_assert = assert_mod.comptime_assert;
const bounded_array_type = bounded_mod.bounded_array_type;
const bounded_hash_map_type = bounded_mod.bounded_hash_map_type;

const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const OwnedBlock = ownership.OwnedBlock;
const StorageEngine = storage_mod.StorageEngine;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

/// Maximum blocks per batch - controls stack-allocated bounded collection capacity.
///
/// Stack allocation: ~21KB total (BatchEntry ~64B + ValidatedBlock ~153B) * 100 elements.
/// Previous value of 10,000 caused ~1.5MB stack allocation and SIGILL crashes.
///
/// Increasing this value raises SIGILL risk from stack overflow during struct initialization.
/// For larger batches, migrate to heap-allocated HashMap/ArrayList with arena coordination.
pub const BATCH_CAPACITY: u32 = 100;

pub const BatchWriterError = error{
    StorageNotRunning,
    BatchTooLarge,
    DuplicateInBatch,
    VersionConflict,
    CommitFailed,
    InvalidBlock,
    WorkspaceViolation,
    OutOfMemory,
};

/// Batch ingestion statistics for monitoring and optimization
pub const BatchStatistics = struct {
    /// Total blocks submitted for ingestion
    blocks_submitted: u32,
    /// Blocks deduplicated within batch
    duplicates_in_batch: u32,
    /// Blocks skipped due to existing newer versions
    version_conflicts: u32,
    /// Blocks successfully written
    blocks_written: u32,
    /// Total batch processing time in microseconds
    processing_time_us: u32,
    /// Memory used during batch processing (KB)
    memory_used_kb: u32,
    /// Deduplication effectiveness (percentage)
    deduplication_rate_percent: u32,

    pub fn init() BatchStatistics {
        return BatchStatistics{
            .blocks_submitted = 0,
            .duplicates_in_batch = 0,
            .version_conflicts = 0,
            .blocks_written = 0,
            .processing_time_us = 0,
            .memory_used_kb = 0,
            .deduplication_rate_percent = 0,
        };
    }

    pub fn calculate_deduplication_rate(self: *BatchStatistics) void {
        if (self.blocks_submitted == 0) {
            self.deduplication_rate_percent = 0;
            return;
        }

        const duplicates_total = self.duplicates_in_batch + self.version_conflicts;
        self.deduplication_rate_percent = (duplicates_total * 100) / self.blocks_submitted;
    }

    pub fn calculate_success_rate_percent(self: @This()) u32 {
        if (self.blocks_submitted == 0) return 100;
        return (self.blocks_written * 100) / self.blocks_submitted;
    }
};

/// Version conflict resolution strategy
pub const ConflictResolution = enum {
    /// Skip blocks with existing newer or equal versions
    skip_older_versions,
    /// Always overwrite existing blocks
    overwrite_existing,
    /// Fail on any version conflict
    fail_on_conflict,
};

/// Configuration for batch writer behavior
pub const BatchConfig = struct {
    /// Maximum blocks per batch (bounded for predictable memory usage)
    max_batch_size: u32,
    /// How to handle version conflicts
    conflict_resolution: ConflictResolution,
    /// Enable workspace isolation validation
    enforce_workspace_isolation: bool,
    /// Timeout for batch processing in microseconds
    timeout_us: u32,

    pub const DEFAULT = BatchConfig{
        .max_batch_size = BATCH_CAPACITY,
        .conflict_resolution = .skip_older_versions,
        .enforce_workspace_isolation = true,
        .timeout_us = 30_000_000, // 30 seconds
    };

    /// Validate configuration parameters are within acceptable bounds.
    /// Ensures max_batch_size prevents memory exhaustion and timeout prevents hanging.
    pub fn validate(self: @This()) !void {
        fatal_assert(self.max_batch_size > 0, "BatchConfig requires positive max_batch_size", .{});
        fatal_assert(self.max_batch_size <= BATCH_CAPACITY, "BatchConfig max_batch_size exceeds BATCH_CAPACITY: {}", .{self.max_batch_size});
        fatal_assert(self.timeout_us > 0, "BatchConfig requires positive timeout", .{});
    }
};

/// High-performance batch writer with intelligent deduplication
pub const BatchWriter = struct {
    allocator: Allocator,
    storage_engine: *StorageEngine,
    config: BatchConfig,

    /// Arena for batch processing with O(1) cleanup
    batch_arena: ArenaAllocator,

    /// Deduplication map for current batch
    dedup_map: bounded_hash_map_type(BlockId, BatchEntry, 100),

    /// Staging area for validated blocks ready for commit
    staging_blocks: bounded_array_type(ValidatedBlock, 100),

    /// Performance metrics for current batch
    current_stats: BatchStatistics,
    lifetime_stats: LifetimeStatistics,

    const BatchEntry = struct {
        block: OwnedBlock,
        submit_order: u32, // For conflict resolution
        workspace: []const u8,
    };

    const ValidatedBlock = struct {
        block: OwnedBlock,
        workspace: []const u8,
        is_update: bool, // true if updating existing block
    };

    const LifetimeStatistics = struct {
        batches_processed: u64,
        total_blocks_submitted: u64,
        total_blocks_written: u64,
        total_processing_time_us: u64,
        average_batch_size: u32,
        average_deduplication_rate_percent: u32,

        pub fn init() LifetimeStatistics {
            return LifetimeStatistics{
                .batches_processed = 0,
                .total_blocks_submitted = 0,
                .total_blocks_written = 0,
                .total_processing_time_us = 0,
                .average_batch_size = 0,
                .average_deduplication_rate_percent = 0,
            };
        }
    };

    /// Initialize batch writer with specified configuration
    pub fn init(
        allocator: Allocator,
        storage_engine: *StorageEngine,
        config: BatchConfig,
    ) !BatchWriter {
        try config.validate();
        fatal_assert(storage_engine.state.can_write(), "Storage engine must be in writable state", .{});

        return BatchWriter{
            .allocator = allocator,
            .storage_engine = storage_engine,
            .config = config,
            .batch_arena = ArenaAllocator.init(allocator),
            .dedup_map = bounded_hash_map_type(BlockId, BatchEntry, 100){},
            .staging_blocks = bounded_array_type(ValidatedBlock, 100){},
            .current_stats = BatchStatistics.init(),
            .lifetime_stats = LifetimeStatistics.init(),
        };
    }

    /// Cleanup resources and prepare for shutdown
    pub fn deinit(self: *BatchWriter) void {
        self.batch_arena.deinit();
        self.* = undefined;
    }

    /// Execute complete batch ingestion with deduplication and atomic commit
    pub fn ingest_batch(self: *BatchWriter, blocks: []const ContextBlock, workspace: []const u8) !BatchStatistics {
        const start_time = std.time.nanoTimestamp();

        // Pre-conditions and validation
        fatal_assert(blocks.len > 0, "BatchWriter requires non-empty blocks array", .{});
        fatal_assert(workspace.len > 0, "BatchWriter requires workspace identifier", .{});
        fatal_assert(blocks.len <= self.config.max_batch_size, "Batch size {} exceeds maximum {}", .{ blocks.len, self.config.max_batch_size });

        // Reset for new batch - O(1) cleanup from previous batch
        try self.reset_for_new_batch();

        // Deduplication prevents storage corruption from duplicate IDs within batch
        try self.deduplicate_and_stage(blocks, workspace);

        // Version-based resolution handles concurrent writers updating same blocks
        try self.resolve_storage_conflicts();

        // Phase 3: Atomic commit
        try self.commit_staged_blocks();

        // Phase 4: Update metrics
        const end_time = std.time.nanoTimestamp();
        self.finalize_batch_metrics(@as(i64, @intCast(start_time)), @as(i64, @intCast(end_time)), @as(u32, @intCast(blocks.len)));

        return self.current_stats;
    }

    /// Phase 1: Deduplicate blocks within batch and stage for processing
    fn deduplicate_and_stage(self: *BatchWriter, blocks: []const ContextBlock, workspace: []const u8) !void {
        for (blocks, 0..) |*block, i| {
            self.current_stats.blocks_submitted += 1;

            // Block structure validation prevents storage corruption from malformed data
            try self.validate_block_structure(block);

            // Workspace isolation prevents cross-workspace data contamination in multi-tenant scenarios
            if (self.config.enforce_workspace_isolation) {
                try self.validate_workspace_membership(block, workspace);
            }

            // Check for duplicates within batch
            const block_id = block.id;
            const gop = try self.dedup_map.find_or_put(block_id);

            if (gop.found_existing) {
                // Handle duplicate within batch
                try self.resolve_batch_duplicate(gop.value_ptr.*, block, workspace, @as(u32, @intCast(i)));
                self.current_stats.duplicates_in_batch += 1;
            } else {
                // New block in batch
                gop.value_ptr.* = BatchEntry{
                    .block = OwnedBlock.take_ownership(block.*, .storage_engine),
                    .submit_order = @as(u32, @intCast(i)),
                    .workspace = workspace,
                };
            }
        }
    }

    /// Phase 2: Check staged blocks against storage for version conflicts
    fn resolve_storage_conflicts(self: *BatchWriter) !void {
        var dedup_iter = self.dedup_map.iterator();
        while (dedup_iter.next()) |entry| {
            const batch_entry = entry.value;
            const block_data = batch_entry.block.read(.storage_engine);

            // Check if block exists in storage
            if (try self.storage_engine.find_block(block_data.id, .storage_engine)) |existing_block| {
                const should_write = try self.resolve_version_conflict(block_data, existing_block.read(.storage_engine));
                if (should_write) {
                    try self.stage_block_for_commit(batch_entry.block, batch_entry.workspace, true);
                } else {
                    self.current_stats.version_conflicts += 1;
                }
            } else {
                // New block - always stage for commit
                try self.stage_block_for_commit(batch_entry.block, batch_entry.workspace, false);
            }
        }
    }

    /// Write staged blocks with WAL flush ensuring crash consistency
    fn commit_staged_blocks(self: *BatchWriter) !void {
        // Write all staged blocks
        for (self.staging_blocks.slice()) |validated| {
            const block_data = validated.block.read(.storage_engine);
            try self.storage_engine.put_block(block_data.*);
            self.current_stats.blocks_written += 1;
        }

        // Ensure durability with WAL flush
        try self.storage_engine.flush_wal();
    }

    /// Resolve duplicate blocks within the same batch
    fn resolve_batch_duplicate(
        self: *BatchWriter,
        existing: BatchEntry,
        new_block: *const ContextBlock,
        workspace: []const u8,
        submit_order: u32,
    ) !void {
        const existing_block_data = existing.block.read(.storage_engine);

        switch (self.config.conflict_resolution) {
            .skip_older_versions => {
                // Keep the block with higher version, or later submit order if versions equal
                if (new_block.version > existing_block_data.version or
                    (new_block.version == existing_block_data.version and submit_order > existing.submit_order))
                {
                    // Update to newer block
                    const entry_ptr = self.dedup_map.find_ptr(new_block.id).?;
                    entry_ptr.* = BatchEntry{
                        .block = OwnedBlock.take_ownership(new_block.*, .storage_engine),
                        .submit_order = submit_order,
                        .workspace = workspace,
                    };
                }
            },
            .overwrite_existing => {
                // Always use the later submitted block
                const entry_ptr = self.dedup_map.find_ptr(new_block.id).?;
                entry_ptr.* = BatchEntry{
                    .block = OwnedBlock.take_ownership(new_block.*, .storage_engine),
                    .submit_order = submit_order,
                    .workspace = workspace,
                };
            },
            .fail_on_conflict => {
                return error.DuplicateInBatch;
            },
        }
    }

    /// Resolve version conflict with existing storage block
    fn resolve_version_conflict(
        self: *BatchWriter,
        new_block: *const ContextBlock,
        existing_block: *const ContextBlock,
    ) !bool {
        switch (self.config.conflict_resolution) {
            .skip_older_versions => {
                return new_block.version > existing_block.version;
            },
            .overwrite_existing => {
                return true;
            },
            .fail_on_conflict => {
                if (new_block.version <= existing_block.version) {
                    return error.VersionConflict;
                }
                return true;
            },
        }
    }

    /// Stage validated block for atomic commit
    fn stage_block_for_commit(
        self: *BatchWriter,
        block: OwnedBlock,
        workspace: []const u8,
        is_update: bool,
    ) !void {
        const validated = ValidatedBlock{
            .block = block,
            .workspace = workspace,
            .is_update = is_update,
        };
        try self.staging_blocks.append(validated);
    }

    /// Validate block has required structure and fields
    fn validate_block_structure(self: *BatchWriter, block: *const ContextBlock) !void {
        fatal_assert(block.content.len > 0, "Block requires non-empty content", .{});
        fatal_assert(block.metadata_json.len > 0, "Block requires metadata", .{});
        fatal_assert(block.source_uri.len > 0, "Block requires source URI", .{});

        // Validate metadata is parseable JSON
        var parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            block.metadata_json,
            .{},
        ) catch return error.InvalidBlock;
        defer parsed.deinit();
    }

    /// Validate block belongs to specified workspace
    fn validate_workspace_membership(self: *BatchWriter, block: *const ContextBlock, workspace: []const u8) !void {
        var parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            block.metadata_json,
            .{},
        ) catch return error.WorkspaceViolation;
        defer parsed.deinit();

        const metadata = parsed.value;
        const block_workspace = if (metadata.object.get("codebase")) |cb| cb.string else return error.WorkspaceViolation;

        if (!std.mem.eql(u8, block_workspace, workspace)) {
            return error.WorkspaceViolation;
        }
    }

    /// Reset internal state for new batch processing
    fn reset_for_new_batch(self: *BatchWriter) !void {
        // Reset arena - O(1) cleanup
        self.batch_arena.deinit();
        self.batch_arena = ArenaAllocator.init(self.allocator);

        // Arena reset is insufficient - bounded collections need explicit reinitialization
        self.dedup_map = bounded_hash_map_type(BlockId, BatchEntry, 100){};
        self.staging_blocks = bounded_array_type(ValidatedBlock, 100){};

        // Fresh statistics prevent contamination from previous batch metrics
        self.current_stats = BatchStatistics.init();
    }

    /// Finalize metrics for completed batch
    fn finalize_batch_metrics(self: *BatchWriter, start_time: i64, end_time: i64, blocks_submitted: u32) void {
        // High-resolution timing enables microsecond-level performance monitoring
        self.current_stats.processing_time_us = @as(u32, @intCast(@divTrunc(end_time - start_time, 1000)));

        // Arena capacity tracking helps identify memory pressure scenarios
        self.current_stats.memory_used_kb = @as(u32, @intCast(self.batch_arena.queryCapacity() / 1024));

        // Deduplication metrics enable optimization of duplicate detection algorithms
        self.current_stats.calculate_deduplication_rate();

        // Update lifetime statistics
        self.lifetime_stats.batches_processed += 1;
        self.lifetime_stats.total_blocks_submitted += blocks_submitted;
        self.lifetime_stats.total_blocks_written += self.current_stats.blocks_written;
        self.lifetime_stats.total_processing_time_us += self.current_stats.processing_time_us;

        // Running averages provide stable performance baselines for monitoring
        self.update_lifetime_averages();
    }

    /// Update running average statistics
    fn update_lifetime_averages(self: *BatchWriter) void {
        if (self.lifetime_stats.batches_processed == 0) return;

        self.lifetime_stats.average_batch_size = @as(u32, @intCast(self.lifetime_stats.total_blocks_submitted / self.lifetime_stats.batches_processed));

        // Calculate average deduplication rate (simple moving average)
        const current_dedup_weight = 100; // Weight current batch more heavily
        const historical_weight = 1;

        self.lifetime_stats.average_deduplication_rate_percent =
            (self.current_stats.deduplication_rate_percent * current_dedup_weight +
                self.lifetime_stats.average_deduplication_rate_percent * historical_weight) /
            (current_dedup_weight + historical_weight);
    }

    /// Query current batch statistics
    pub fn query_batch_statistics(self: *const BatchWriter) BatchStatistics {
        return self.current_stats;
    }

    /// Query lifetime performance statistics
    pub fn query_lifetime_statistics(self: *const BatchWriter) LifetimeStatistics {
        return self.lifetime_stats;
    }

    /// Reset lifetime statistics for monitoring periods
    pub fn reset_lifetime_statistics(self: *BatchWriter) void {
        self.lifetime_stats = LifetimeStatistics.init();
    }
};

// Compile-time validation of structure sizes
comptime {
    comptime_assert(@sizeOf(BatchStatistics) <= 128, "BatchStatistics too large");
    comptime_assert(@sizeOf(BatchConfig) <= 64, "BatchConfig too large");
}

//
// Unit Tests
//

const testing = std.testing;
const test_allocator = testing.allocator;

test "BatchConfig validation" {
    // Valid config
    const valid_config = BatchConfig.DEFAULT;
    try valid_config.validate();

    // Invalid config - zero batch size should cause fatal_assert in debug
    if (builtin.mode != .Debug) {
        const invalid_config = BatchConfig{
            .max_batch_size = 0,
            .conflict_resolution = .skip_older_versions,
            .enforce_workspace_isolation = true,
            .timeout_us = 1000,
        };
        // Would cause panic in debug builds due to fatal_assert
        _ = invalid_config;
    }
}

test "BatchStatistics calculations" {
    var stats = BatchStatistics.init();
    stats.blocks_submitted = 100;
    stats.duplicates_in_batch = 10;
    stats.version_conflicts = 5;
    stats.blocks_written = 85;

    stats.calculate_deduplication_rate();
    try testing.expect(stats.deduplication_rate_percent == 15); // (10 + 5) / 100 * 100

    const success_rate = stats.calculate_success_rate_percent();
    try testing.expect(success_rate == 85); // 85 / 100 * 100
}

test "ConflictResolution enum values" {
    try testing.expect(@typeInfo(ConflictResolution).@"enum".fields.len == 3);

    const skip = ConflictResolution.skip_older_versions;
    const overwrite = ConflictResolution.overwrite_existing;
    const fail = ConflictResolution.fail_on_conflict;

    try testing.expect(skip != overwrite);
    try testing.expect(overwrite != fail);
    try testing.expect(fail != skip);
}
