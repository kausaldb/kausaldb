//! In-memory write buffer management for blocks and graph edges.
//!
//! Coordinates BlockIndex and GraphEdgeIndex with WAL durability guarantees.
//! Provides unified interface for memtable operations including WAL-first writes,
//! flush coordination, and arena-based memory management.
//!
//! Design rationale: Single memtable coordinator prevents state inconsistencies
//! between block and edge indexes. WAL ownership ensures all mutations are
//! durable before in-memory updates. Arena-per-subsystem enables O(1) bulk
//! cleanup during memtable flushes to SSTable.

const builtin = @import("builtin");
const std = @import("std");

const log = std.log.scoped(.memtable_manager);

const concurrency = @import("../core/concurrency.zig");
const context_block = @import("../core/types.zig");
const error_context = @import("../core/error_context.zig");
const graph_edge_index = @import("graph_edge_index.zig");
const memory = @import("../core/memory.zig");
const ownership = @import("../core/ownership.zig");
const vfs = @import("../core/vfs.zig");
const tombstone = @import("tombstone.zig");
const wal = @import("wal.zig");

const ArenaCoordinator = memory.ArenaCoordinator;
const BlockId = context_block.BlockId;
const BlockOwnership = ownership.BlockOwnership;
const ContextBlock = context_block.ContextBlock;
const EdgeType = context_block.EdgeType;
const GraphEdge = context_block.GraphEdge;
const GraphEdgeIndex = graph_edge_index.GraphEdgeIndex;
const OwnedBlock = ownership.OwnedBlock;
const OwnedGraphEdge = graph_edge_index.OwnedGraphEdge;
const TombstoneRecord = tombstone.TombstoneRecord;
const VFS = vfs.VFS;
const WAL = wal.WAL;
const WALEntry = wal.WALEntry;

pub const BlockIterator = struct {
    block_index: *const BlockIndex,
    hash_map_iterator: std.HashMap(
        BlockId,
        OwnedBlock,
        BlockIndex.BlockIdContext,
        std.hash_map.default_max_load_percentage,
    ).Iterator,

    /// Returns next owned block or null when iteration completes.
    pub fn next(self: *BlockIterator) ?*const OwnedBlock {
        if (self.hash_map_iterator.next()) |entry| {
            return entry.value_ptr;
        }
        return null;
    }
};

/// Manages the complete in-memory write buffer (memtable) state.
/// Uses Arena Coordinator Pattern: receives stable coordinator interface
/// and passes it to child components (BlockIndex, GraphEdgeIndex).
/// Coordinator interface remains valid across arena operations, eliminating temporal coupling.
/// **Owns WAL for durability**: All mutations go WAL-first before memtable update.
pub const MemtableManager = struct {
    /// Arena coordinator pointer for stable allocation access (remains valid across arena resets)
    /// CRITICAL: Must be pointer to prevent coordinator struct copying corruption
    arena_coordinator: *const ArenaCoordinator,
    /// Backing allocator for stable data structures (HashMap, ArrayList)
    backing_allocator: std.mem.Allocator,
    vfs: VFS,
    data_dir: []const u8,
    block_index: BlockIndex,
    wal: WAL,
    memtable_max_size: u64,

    /// Phase 1: Create the memtable manager without I/O operations.
    /// Uses Arena Coordinator Pattern: receives stable coordinator interface
    /// and passes it to child components. Coordinator remains valid across operations.
    /// Creates WAL instance but does not perform I/O until startup() is called.
    /// CRITICAL: ArenaCoordinator must be passed by pointer to prevent struct copying corruption.
    pub fn init(
        coordinator: *const ArenaCoordinator,
        backing: std.mem.Allocator,
        filesystem: VFS,
        data_dir: []const u8,
        memtable_max_size: u64,
    ) !MemtableManager {
        const owned_data_dir = try backing.dupe(u8, data_dir);

        const wal_dir = try std.fmt.allocPrint(backing, "{s}/wal", .{owned_data_dir});
        defer backing.free(wal_dir);

        return MemtableManager{
            .arena_coordinator = coordinator,
            .backing_allocator = backing,
            .vfs = filesystem,
            .data_dir = owned_data_dir,
            .block_index = BlockIndex.init(coordinator, backing),
            .wal = try WAL.init(backing, filesystem, wal_dir),
            .memtable_max_size = memtable_max_size,
        };
    }

    /// Phase 2: Perform I/O operations to start up WAL for durability.
    /// Creates WAL directory structure and prepares for write operations.
    /// Must be called after init() and before any write operations.
    pub fn startup(self: *MemtableManager) !void {
        concurrency.assert_main_thread();

        try self.wal.startup();
    }

    /// Clean up all memtable resources including arena-allocated memory.
    /// Must be called to prevent memory leaks. Coordinates cleanup of
    /// both block and edge indexes atomically plus WAL cleanup.
    pub fn deinit(self: *MemtableManager) void {
        concurrency.assert_main_thread();

        if (@intFromPtr(self) == 0)
            std.debug.panic(
                "MemtableManager self pointer is null - memory corruption detected",
                .{},
            );
        if (@intFromPtr(&self.wal) == 0)
            std.debug.panic(
                "MemtableManager WAL pointer corrupted - memory safety violation detected",
                .{},
            );
        if (@intFromPtr(&self.block_index) == 0)
            std.debug.panic(
                "MemtableManager block_index pointer corrupted - memory safety violation detected",
                .{},
            ); // Note: graph_index is now owned by StorageEngine, not MemtableManager

        self.wal.deinit();
        self.block_index.deinit();

        self.backing_allocator.free(self.data_dir);
    }

    /// Add a block to the in-memory memtable with full durability guarantees.
    /// WAL-first design ensures durability before in-memory state update.
    /// This is the primary method for durable block storage operations.
    pub fn put_block_durable(self: *MemtableManager, block: ContextBlock) !void {
        concurrency.assert_main_thread();

        var non_zero_bytes: u32 = 0;
        for (block.id.bytes) |byte| {
            if (byte != 0) non_zero_bytes += 1;
        }
        std.debug.assert(non_zero_bytes > 0);
        std.debug.assert(block.source_uri.len > 0);
        std.debug.assert(block.content.len > 0);

        // CRITICAL: WAL write must complete before memtable update for durability guarantees
        const wal_succeeded = blk: {
            // Streaming writes eliminate WALEntry buffer allocation for multi-MB blocks
            if (block.content.len >= 512 * 1024) {
                self.wal.write_block_streaming(block) catch |err| {
                    // WAL write failure due to resource constraints (e.g. disk full) is recoverable.
                    // Log the error and propagate it to the client rather than crashing the system.
                    error_context.log_storage_error(err, error_context.StorageContext{
                        .operation = "wal_write_block_streaming",
                        .block_id = block.id,
                    });
                    return err;
                };
            } else {
                const wal_entry = try WALEntry.create_put_block(self.backing_allocator, block);
                defer wal_entry.deinit(self.backing_allocator);
                self.wal.write_entry(wal_entry) catch |err| {
                    // WAL write failure due to resource constraints (e.g. disk full) is recoverable.
                    // Log the error and propagate it to the client rather than crashing the system.
                    error_context.log_storage_error(err, error_context.StorageContext{
                        .operation = "wal_write_entry",
                        .block_id = block.id,
                    });
                    return err;
                };
            }
            break :blk true;
        };

        // WAL operation succeeded, safe to proceed to memtable update
        std.debug.assert(wal_succeeded);

        // Skip per-operation validation to prevent performance regression
        // Validation is expensive (allocator testing + memory calculation)
        // and should only run during tests, not benchmarks or normal operation

        try self.block_index.put_block(block);
    }

    /// Add a block to the in-memory memtable without WAL durability.
    /// Used for WAL recovery operations where durability is already guaranteed.
    /// For regular operations, use put_block_durable() instead.
    pub fn put_block(self: *MemtableManager, block: ContextBlock) !void {
        concurrency.assert_main_thread();

        try self.block_index.put_block(block);
    }

    /// Add tombstone record with full durability guarantees.
    /// WAL-first design ensures tombstone operation is recorded before state update.
    pub fn put_tombstone_durable(self: *MemtableManager, tombstone_record: TombstoneRecord, graph_index: *GraphEdgeIndex) !void {
        concurrency.assert_main_thread();

        var non_zero_bytes: u32 = 0;
        for (tombstone_record.block_id.bytes) |byte| {
            if (byte != 0) non_zero_bytes += 1;
        }
        std.debug.assert(non_zero_bytes > 0);
        std.debug.assert(tombstone_record.sequence > 0);

        const wal_entry = try WALEntry.create_tombstone_block(self.backing_allocator, tombstone_record);
        defer wal_entry.deinit(self.backing_allocator);
        self.wal.write_entry(wal_entry) catch |err| {
            error_context.log_storage_error(err, error_context.StorageContext{
                .operation = "wal_write_tombstone_entry",
                .block_id = tombstone_record.block_id,
            });
            return err;
        };

        try self.block_index.put_tombstone(tombstone_record);
        graph_index.remove_block_edges(tombstone_record.block_id);
    }

    /// Add tombstone record without WAL durability.
    /// Used for WAL recovery operations where durability is already guaranteed.
    pub fn put_tombstone(self: *MemtableManager, tombstone_record: TombstoneRecord, graph_index: *GraphEdgeIndex) !void {
        concurrency.assert_main_thread();

        try self.block_index.put_tombstone(tombstone_record);
        graph_index.remove_block_edges(tombstone_record.block_id);
    }

    /// Add tombstone record without edge cleanup (for WAL recovery).
    /// Used during WAL recovery where edge cleanup will be handled separately.
    fn put_tombstone_wal_recovery(self: *MemtableManager, tombstone_record: TombstoneRecord) !void {
        concurrency.assert_main_thread();

        try self.block_index.put_tombstone(tombstone_record);
        // Note: Edge cleanup not performed during WAL recovery - edges recovered separately
    }

    /// Add a graph edge with full durability guarantees.
    /// Write edge to WAL only for durability. Used when StorageEngine manages the graph index directly.
    /// This method only handles WAL persistence, not in-memory index updates.
    pub fn put_edge_wal_only(self: *MemtableManager, edge: GraphEdge) !void {
        concurrency.assert_main_thread();

        const wal_entry = try WALEntry.create_put_edge(self.backing_allocator, edge);
        defer wal_entry.deinit(self.backing_allocator);
        try self.wal.write_entry(wal_entry);
    }

    /// Legacy method: DEPRECATED - graph_index is now owned by StorageEngine.
    /// Use put_edge_wal_only + StorageEngine.graph_index.put_edge instead.
    pub fn put_edge_durable(self: *MemtableManager, edge: GraphEdge) !void {
        _ = self;
        _ = edge;
        @panic("put_edge_durable is deprecated: use StorageEngine.put_edge instead");
    }

    /// Add a graph edge to the in-memory edge index without WAL durability.
    /// Maintains bidirectional indexes for efficient traversal in both directions.
    /// Used for WAL recovery operations where durability is already guaranteed.
    /// For regular operations, use put_edge_durable() instead.
    pub fn put_edge(self: *MemtableManager, edge: GraphEdge) !void {
        concurrency.assert_main_thread();

        try self.graph_index.put_edge(edge);
    }

    /// Find a block in the in-memory memtable by ID.
    /// Returns the block if found, null otherwise.
    /// Used by the storage engine for LSM-tree read path (memtable first).
    pub fn find_block_in_memtable(self: *const MemtableManager, id: BlockId) ?ContextBlock {
        return self.block_index.find_block(id);
    }

    /// Check if a block is tombstoned (marked for deletion).
    /// Used by StorageEngine to prevent resurrection from SSTables.
    pub fn is_block_tombstoned(self: *const MemtableManager, id: BlockId) bool {
        return self.block_index.tombstones.contains(id);
    }

    /// Find a block in memtable and clone it with specified ownership.
    /// Creates a new OwnedBlock that can be safely transferred between subsystems.
    /// Used by StorageEngine to provide ownership-aware block access.
    pub fn find_block_with_ownership(
        self: *const MemtableManager,
        id: BlockId,
        block_ownership: BlockOwnership,
    ) !?OwnedBlock {
        if (self.block_index.find_block(id)) |block_data| {
            const temp_owned = OwnedBlock.take_ownership(block_data, .memtable_manager);
            return try temp_owned.clone_with_ownership(self.backing_allocator, block_ownership, null);
        }
        return null;
    }

    /// Write an owned block to storage with full durability guarantees.
    /// Extracts ContextBlock from ownership wrapper for WAL and memtable storage.
    /// Used by StorageEngine when accepting ownership-aware block operations.
    pub fn put_block_durable_owned(self: *MemtableManager, owned_block: OwnedBlock) !void {
        concurrency.assert_main_thread();

        const block = owned_block.read(.memtable_manager);

        //WAL-before-memtable ordering assertions
        // Durability ordering: WAL MUST be persistent before memtable update
        const wal_entries_before = self.wal.stats.entries_written;

        // Streaming writes eliminate WALEntry buffer allocation for multi-MB blocks
        if (block.content.len >= 512 * 1024) {
            try self.wal.write_block_streaming(block.*);
        } else {
            const wal_entry = try WALEntry.create_put_block(self.backing_allocator, block.*);
            defer wal_entry.deinit(self.backing_allocator);
            try self.wal.write_entry(wal_entry);
        }

        // Verify WAL write completed before memtable update
        // This ordering is CRITICAL for durability guarantees
        const wal_entries_after = self.wal.stats.entries_written;
        std.debug.assert(wal_entries_after > wal_entries_before); // Only update memtable AFTER WAL persistence is confirmed
        try self.block_index.put_block(block.*);

        // Skip per-operation validation to prevent performance regression
        // validation is expensive and should only run during specific tests
    }

    /// Encapsulates flush decision within memtable ownership boundary.
    /// Prevents StorageEngine from needing knowledge of internal memory thresholds,
    /// maintaining clear separation between coordination and state management.
    pub fn should_flush(self: *const MemtableManager) bool {
        return self.block_index.memory_used >= self.memtable_max_size;
    }

    /// Atomically clear all in-memory data with O(1) arena reset.
    /// Used after successful memtable flush to SSTable. Now only clears
    /// block index since graph index is owned by StorageEngine and persists across flushes.
    pub fn clear(self: *MemtableManager) void {
        concurrency.assert_main_thread();

        self.block_index.clear();
        // Note: graph_index is now owned by StorageEngine and should NOT be cleared during flush

        // Skip per-operation validation to prevent performance regression
        // Clear operation validation causes significant debug build overhead
        // Validation should be called explicitly when needed
    }

    /// Create an iterator over all blocks for SSTable flush operations.
    /// Provides deterministic iteration order for consistent SSTable creation.
    /// Iterator remains valid until the next mutation operation.
    pub fn iterator(self: *const MemtableManager) BlockIterator {
        return BlockIterator{
            .block_index = &self.block_index,
            .hash_map_iterator = self.block_index.blocks.iterator(),
        };
    }

    /// Get raw HashMap iterator for backward compatibility with storage engine.
    /// Used by StorageEngine.iterate_all_blocks for mixed memtable+SSTable iteration.
    pub fn raw_iterator(
        self: *const MemtableManager,
    ) std.HashMap(
        BlockId,
        OwnedBlock,
        BlockIndex.BlockIdContext,
        std.hash_map.default_max_load_percentage,
    ).Iterator {
        return self.block_index.blocks.iterator();
    }

    /// DEPRECATED: Use StorageEngine.find_outgoing_edges instead.
    pub fn find_outgoing_edges(self: *const MemtableManager, source_id: BlockId) []const OwnedGraphEdge {
        _ = self;
        _ = source_id;
        return &[_]OwnedGraphEdge{}; // Empty slice for deprecated method
    }

    /// DEPRECATED: Use StorageEngine.find_incoming_edges instead.
    pub fn find_incoming_edges(self: *const MemtableManager, target_id: BlockId) []const OwnedGraphEdge {
        _ = self;
        _ = target_id;
        return &[_]OwnedGraphEdge{}; // Empty slice for deprecated method
    }

    /// Recover memtable state from WAL files.
    /// Replays all committed operations to reconstruct consistent state.
    /// Uses WAL module's streaming recovery for memory efficiency.
    pub fn recover_from_wal(self: *MemtableManager) !void {
        concurrency.assert_main_thread();

        const RecoveryContext = struct {
            memtable: *MemtableManager,
        };

        const recovery_callback = struct {
            fn apply(entry: WALEntry, context: *anyopaque) wal.WALError!void {
                // Safety: Pointer cast with alignment validation
                const ctx: *RecoveryContext = @ptrCast(@alignCast(context));
                ctx.memtable.apply_wal_entry(entry) catch |err| switch (err) {
                    error.OutOfMemory => return wal.WALError.OutOfMemory,
                    else => return wal.WALError.CallbackFailed,
                };
            }
        }.apply;

        var recovery_context = RecoveryContext{ .memtable = self };

        self.wal.recover_entries(recovery_callback, &recovery_context) catch |err| switch (err) {
            wal.WALError.FileNotFound => {
                return;
            },
            else => return err,
        };
    }

    /// Ensure all WAL operations are durably persisted to disk.
    /// Forces synchronization of any pending write operations.
    pub fn flush_wal(self: *MemtableManager) !void {
        concurrency.assert_main_thread();

        if (self.wal.active_file) |*file| {
            file.flush() catch return error.IoError;
        }
    }

    /// Validate WAL-before-memtable ordering invariant is maintained.
    /// Ensures WAL durability ordering is preserved - WAL entries must be persistent
    /// before corresponding memtable state exists. Critical for LSM-tree durability guarantees.
    fn validate_wal_memtable_ordering_invariant(self: *const MemtableManager) void {
        std.debug.assert(builtin.mode == .Debug);

        const memtable_blocks = @as(u32, @intCast(self.block_index.blocks.count()));
        const wal_entries = self.wal.statistics().entries_written;

        // In normal operation, WAL should have at least as many entries as memtable blocks
        // (WAL may have more due to edges, deletes, or unflushed entries)
        std.debug.assert(wal_entries >= memtable_blocks);
        if (self.wal.active_file != null) {
            std.debug.assert(self.wal.statistics().entries_written > 0 or memtable_blocks == 0);
        }
    }

    /// Invariant validation for MemtableManager. Validates arena coordinator stability,
    /// memory accounting consistency and component state coherence.
    /// Critical for detecting programming errors.
    pub fn validate_invariants(self: *const MemtableManager) void {
        if (builtin.mode == .Debug) {
            self.validate_arena_coordinator_stability();
            self.validate_memory_accounting_consistency();
            self.validate_component_state_coherence();
            self.validate_wal_memtable_ordering_invariant();
        }
    }

    /// Validate arena coordinator stability across all subsystems.
    /// Ensures arena coordinators remain functional after struct operations.
    fn validate_arena_coordinator_stability(self: *const MemtableManager) void {
        std.debug.assert(builtin.mode == .Debug);

        self.block_index.validate_invariants();

        std.debug.assert(@intFromPtr(&self.graph_index) != 0);

        const test_alloc = self.backing_allocator.alloc(u8, 1) catch {
            std.debug.panic("MemtableManager backing allocator non-functional - corruption detected", .{});
            return;
        };
        defer self.backing_allocator.free(test_alloc);
    }

    /// Validate memory accounting consistency across subsystems.
    /// Ensures tracked memory usage matches actual subsystem usage.
    fn validate_memory_accounting_consistency(self: *const MemtableManager) void {
        std.debug.assert(builtin.mode == .Debug);

        const block_index_memory = self.block_index.memory_used;
        const total_memory = self.block_index.memory_used;

        std.debug.assert(total_memory == block_index_memory);
        const current_block_count = @as(u32, @intCast(self.block_index.blocks.count()));
        if (current_block_count > 0) {
            const avg_block_size = total_memory / current_block_count;
            std.debug.assert(avg_block_size > 0 and avg_block_size < 100 * 1024 * 1024);
        }
    }

    /// Validate coherence between different MemtableManager components.
    /// Ensures WAL, BlockIndex, and GraphEdgeIndex are in consistent states.
    fn validate_component_state_coherence(self: *const MemtableManager) void {
        std.debug.assert(builtin.mode == .Debug);

        if (@intFromPtr(&self.block_index) == 0)
            std.debug.panic("BlockIndex pointer corruption in MemtableManager", .{});
        if (@intFromPtr(&self.graph_index) == 0)
            std.debug.panic("GraphEdgeIndex pointer corruption in MemtableManager", .{});
        if (@intFromPtr(&self.wal) == 0)
            std.debug.panic("WAL pointer corruption in MemtableManager", .{});

        // Configuration corruption could lead to OOM or pathological performance degradation
        std.debug.assert(self.memtable_max_size > 0 and self.memtable_max_size <= 10 * 1024 * 1024 * 1024);
        const current_usage = self.block_index.memory_used;
        std.debug.assert(current_usage <= self.memtable_max_size * 2);
    }

    /// Clean up old WAL segments after successful memtable flush.
    /// Delegates to WAL module for actual cleanup operations.
    pub fn cleanup_old_wal_segments(self: *MemtableManager) !void {
        concurrency.assert_main_thread();

        try self.wal.cleanup_old_segments();
    }

    /// Orchestrates atomic transition from write-optimized to read-optimized storage.
    /// Maintains LSM-tree performance characteristics with proper ownership transfer.
    /// Creates OwnedBlock collection for SSTableManager with validated ownership.
    pub fn flush_to_sstable(self: *MemtableManager, sstable_manager: anytype, graph_index: *const GraphEdgeIndex) !void {
        concurrency.assert_main_thread();

        const initial_block_count = self.block_index.blocks.count();
        const initial_tombstone_count = self.block_index.tombstones.count();

        if (initial_block_count == 0 and initial_tombstone_count == 0) return;

        std.debug.assert(initial_block_count > 0 or initial_tombstone_count > 0);

        var owned_blocks = std.ArrayList(OwnedBlock){};
        defer owned_blocks.deinit(self.backing_allocator);

        var block_iterator = self.iterator();
        while (block_iterator.next()) |owned_block_ptr| {
            try owned_blocks.append(self.backing_allocator, owned_block_ptr.*);
        }

        std.debug.assert(owned_blocks.items.len == initial_block_count);

        const tombstones = try self.block_index.collect_tombstones(self.backing_allocator);
        defer self.backing_allocator.free(tombstones);

        std.debug.assert(tombstones.len == initial_tombstone_count);

        var edges: []const GraphEdge = undefined;
        var collection_attempts: u32 = 0;
        while (collection_attempts < 3) : (collection_attempts += 1) {
            const edge_count_before = graph_index.edge_count();
            edges = try graph_index.collect_edges(self.backing_allocator);

            if (edges.len == edge_count_before) {
                break;
            } else {
                log.warn(
                    "Edge collection attempt {} failed: expected {} edges, collected {}",
                    .{ collection_attempts + 1, edge_count_before, edges.len },
                );
                self.backing_allocator.free(edges);
                if (collection_attempts < 2) {
                    // Busy wait instead of sleep to avoid thread scheduling overhead
                    var i: u32 = 0;
                    while (i < 1000) : (i += 1) {
                        std.mem.doNotOptimizeAway(i);
                    }
                }
            }
        }
        defer self.backing_allocator.free(edges);

        const final_edge_count = graph_index.edge_count();
        std.debug.assert(edges.len == final_edge_count);
        std.debug.assert(edges.len < std.math.maxInt(u32));
        std.debug.assert(tombstones.len < std.math.maxInt(u32));

        const max_items_per_sstable = std.math.maxInt(u16);

        if (tombstones.len > max_items_per_sstable or edges.len > max_items_per_sstable) {
            const first_tombstones = tombstones[0..@min(tombstones.len, max_items_per_sstable)];
            const first_edges = edges[0..@min(edges.len, max_items_per_sstable)];
            try sstable_manager.create_new_sstable_from_memtable(owned_blocks.items, first_tombstones, first_edges);

            var tombstone_offset = first_tombstones.len;
            var edge_offset = first_edges.len;

            while (tombstone_offset < tombstones.len or edge_offset < edges.len) {
                const remaining_tombstones = tombstones.len - tombstone_offset;
                const remaining_edges = edges.len - edge_offset;

                const tombstone_slice = if (remaining_tombstones > 0)
                    tombstones[tombstone_offset .. tombstone_offset + @min(remaining_tombstones, max_items_per_sstable)]
                else
                    &[_]tombstone.TombstoneRecord{};

                const edge_slice = if (remaining_edges > 0)
                    edges[edge_offset .. edge_offset + @min(remaining_edges, max_items_per_sstable)]
                else
                    &[_]context_block.GraphEdge{};

                try sstable_manager.create_new_sstable_from_memtable(&[_]OwnedBlock{}, tombstone_slice, edge_slice);

                tombstone_offset += tombstone_slice.len;
                edge_offset += edge_slice.len;
            }
        } else {
            try sstable_manager.create_new_sstable_from_memtable(owned_blocks.items, tombstones, edges);
        }

        self.clear();

        try self.cleanup_old_wal_segments();
    }

    /// Apply a WAL entry during recovery to rebuild memtable state.
    /// Uses non-durable methods since WAL durability is already guaranteed.
    fn apply_wal_entry(self: *MemtableManager, entry: WALEntry) !void {
        switch (entry.entry_type) {
            .put_block => {
                var temp_arena = std.heap.ArenaAllocator.init(self.backing_allocator);
                defer temp_arena.deinit();
                const temp_allocator = temp_arena.allocator();

                const owned_block = try entry.extract_block(temp_allocator);
                try self.put_block(owned_block.read(.storage_engine).*);
            },
            .tombstone_block => {
                const tombstone_record = try TombstoneRecord.deserialize(entry.payload);
                try self.put_tombstone_wal_recovery(tombstone_record);
            },

            .put_edge => {
                // Edge recovery is intentionally skipped during WAL replay. The StorageEngine
                // now owns the graph_index and will rebuild edges from SSTable data during
                // startup recovery, maintaining consistency with the current architecture.
                _ = try entry.extract_edge();
            },
        }
    }
};

const testing = std.testing;

// Test helper: Mock StorageEngine for unit tests

const simulation_vfs = @import("../sim/simulation_vfs.zig");
const SimulationVFS = simulation_vfs.SimulationVFS;

const block_index_mod = @import("block_index.zig");
const sstable_manager_mod = @import("sstable_manager.zig");

const BlockIndex = block_index_mod.BlockIndex;
const SSTableManager = sstable_manager_mod.SSTableManager;

fn create_test_block(id: BlockId, content: []const u8) ContextBlock {
    return ContextBlock{
        .id = id,
        .sequence = 0, // Storage engine will assign the actual global sequence
        .source_uri = "test://source.zig",
        .metadata_json = "{}",
        .content = content,
    };
}

fn create_test_edge(source: BlockId, target: BlockId, edge_type: EdgeType) GraphEdge {
    return GraphEdge{
        .source_id = source,
        .target_id = target,
        .edge_type = edge_type,
    };
}

test "MemtableManager basic lifecycle" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const coordinator = ArenaCoordinator.init(&arena);
    var manager = try MemtableManager.init(&coordinator, allocator, sim_vfs.vfs(), "/test/data", 1024 * 1024);
    defer manager.deinit();

    try testing.expectEqual(@as(u32, 0), @as(u32, @intCast(manager.block_index.blocks.count())));
    // Note: graph_index is now owned by StorageEngine, not MemtableManager
    // try testing.expectEqual(@as(u32, 0), manager.graph_index.edge_count());
    try testing.expectEqual(@as(u64, 0), manager.block_index.memory_used);
}

test "MemtableManager with WAL operations" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const coordinator = ArenaCoordinator.init(&arena);
    var manager = try MemtableManager.init(&coordinator, allocator, sim_vfs.vfs(), "/test/data", 1024 * 1024);
    defer manager.deinit();

    try manager.startup();

    const block_id = try BlockId.from_hex("00000000000000000000000000000001");
    const test_block = create_test_block(block_id, "test content");

    try manager.put_block_durable(test_block);
    try testing.expectEqual(@as(u32, 1), @as(u32, @intCast(manager.block_index.blocks.count())));

    const found_block = manager.find_block_in_memtable(block_id);
    try testing.expect(found_block != null);
    try testing.expectEqualStrings("test content", found_block.?.content);
}

test "MemtableManager multiple blocks" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const coordinator = ArenaCoordinator.init(&arena);
    var manager = try MemtableManager.init(&coordinator, allocator, sim_vfs.vfs(), "/test/data", 1024 * 1024);
    defer manager.deinit();

    try manager.startup();

    const block1_id = try BlockId.from_hex("00000000000000000000000000000001");
    const block2_id = try BlockId.from_hex("00000000000000000000000000000002");
    const block1 = create_test_block(block1_id, "content 1");
    const block2 = create_test_block(block2_id, "content 2");

    try manager.put_block_durable(block1);
    try manager.put_block_durable(block2);

    try testing.expectEqual(@as(u32, 2), @as(u32, @intCast(manager.block_index.blocks.count())));
    try testing.expect(manager.find_block_in_memtable(block1_id) != null);
    try testing.expect(manager.find_block_in_memtable(block2_id) != null);
}

test "MemtableManager edge operations" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const coordinator = ArenaCoordinator.init(&arena);
    var manager = try MemtableManager.init(&coordinator, allocator, sim_vfs.vfs(), "/test/data", 1024 * 1024);
    defer manager.deinit();

    try manager.startup();

    const source_id = try BlockId.from_hex("00000000000000000000000000000001");

    // Note: Edge operations now handled by StorageEngine, not MemtableManager
    // This test should be moved to StorageEngine tests

    const outgoing = manager.find_outgoing_edges(source_id);
    try testing.expectEqual(@as(usize, 0), outgoing.len); // Empty since edges now handled by StorageEngine
}

test "MemtableManager clear operation" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const coordinator = ArenaCoordinator.init(&arena);
    var manager = try MemtableManager.init(&coordinator, allocator, sim_vfs.vfs(), "/test/data", 1024 * 1024);
    defer manager.deinit();

    try manager.startup();

    const block_id = try BlockId.from_hex("00000000000000000000000000000001");
    const test_block = create_test_block(block_id, "clear test");
    try manager.put_block_durable(test_block);

    try testing.expectEqual(@as(u32, 1), @as(u32, @intCast(manager.block_index.blocks.count())));

    manager.clear();

    try testing.expectEqual(@as(u32, 0), @as(u32, @intCast(manager.block_index.blocks.count())));
    try testing.expectEqual(@as(u64, 0), manager.block_index.memory_used);
}
