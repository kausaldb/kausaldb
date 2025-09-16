//! Storage engine coordination and main public API.
//!
//! Implements the main StorageEngine struct that coordinates between all
//! storage subsystems: BlockIndex (memtable), GraphEdgeIndex, WAL, SSTables,
//! and compaction. Provides the unified public interface for all storage
//! operations while maintaining the LSM-tree architecture principles.
//!
//! Key responsibilities:
//! - Coordinate writes through WAL -> BlockIndex -> SSTable flush pipeline
//! - Orchestrate reads from BlockIndex -> SSTables with proper precedence
//! - Manage background compaction to maintain read performance
//! - Enforce arena-per-subsystem memory management patterns
//! - Provide metrics and error handling

const builtin = @import("builtin");
const std = @import("std");

const assert_mod = @import("../core/assert.zig");
const block_index_mod = @import("block_index.zig");
const concurrency = @import("../core/concurrency.zig");
const config_mod = @import("config.zig");
const context_block = @import("../core/types.zig");
const error_context = @import("../core/error_context.zig");
const graph_edge_index = @import("graph_edge_index.zig");
const memory = @import("../core/memory.zig");
const memtable_manager_mod = @import("memtable_manager.zig");
const metrics_mod = @import("metrics.zig");
const ownership = @import("../core/ownership.zig");
const pools = @import("../core/pools.zig");
const simulation_vfs = @import("../sim/simulation_vfs.zig");
const sstable = @import("sstable.zig");
const sstable_manager_mod = @import("sstable_manager.zig");
const state_machines = @import("../core/state_machines.zig");
const tiered_compaction = @import("tiered_compaction.zig");
const vfs = @import("../core/vfs.zig");
const wal = @import("wal.zig");

const assert_fmt = assert_mod.assert_fmt;
const fatal_assert = assert_mod.fatal_assert;
const testing = std.testing;

const BlockHashMap = std.HashMap(BlockId, OwnedBlock, block_index_mod.BlockIndex.BlockIdContext, std.hash_map.default_max_load_percentage);
const BlockHashMapIterator = BlockHashMap.Iterator;
const ArenaCoordinator = memory.ArenaCoordinator;
const BlockId = context_block.BlockId;
const BlockOwnership = ownership.BlockOwnership;
const ComptimeOwnedBlock = ownership.ComptimeOwnedBlock;
const ContextBlock = context_block.ContextBlock;

const GraphEdge = context_block.GraphEdge;
const ParsedBlock = context_block.ParsedBlock;
const OwnedBlock = ownership.OwnedBlock;
const OwnedGraphEdge = graph_edge_index.OwnedGraphEdge;
const SimulationVFS = simulation_vfs.SimulationVFS;
const StorageState = state_machines.StorageState;
const VFS = vfs.VFS;

pub const Config = config_mod.Config;
pub const StorageMetrics = metrics_mod.StorageMetrics;
pub const MemtableManager = memtable_manager_mod.MemtableManager;
pub const SSTableManager = sstable_manager_mod.SSTableManager;

pub const SSTable = sstable.SSTable;
pub const Compactor = sstable.Compactor;
pub const TieredCompactionManager = tiered_compaction.TieredCompactionManager;
pub const WAL = wal.WAL;
pub const WALEntry = wal.WALEntry;
pub const WALEntryType = wal.WALEntryType;
pub const WALError = wal.WALError;

/// Storage engine errors.
pub const StorageError = error{
    /// Block not found in storage
    BlockNotFound,
    /// Storage already initialized
    AlreadyInitialized,
    /// Storage not initialized
    NotInitialized,
    /// Storage engine has been deinitialized
    StorageEngineDeinitialized,
    /// Writes stalled due to compaction backpressure
    WriteStalled,
    /// Writes blocked due to excessive L0 pressure
    WriteBlocked,
} || config_mod.ConfigError || wal.WALError || vfs.VFSError || vfs.VFileError;

/// Command to flush memtable to SSTable with coordinated subsystem management.
/// Encapsulates the complete flush-to-compaction sequence with proper state transitions.
/// Decouples StorageEngine from direct orchestration of subsystem interactions.
const FlushMemtableCommand = struct {
    storage_engine: *StorageEngine,

    /// Execute complete memtable flush sequence including optional compaction.
    /// Handles state transitions, subsystem coordination, and error recovery.
    fn execute(self: FlushMemtableCommand) !void {
        concurrency.assert_main_thread();

        // Transition to flushing state during operation
        self.storage_engine.state.transition(.flushing);
        defer {
            // Only transition back to running if we're not already there
            if (self.storage_engine.state != .running) {
                self.storage_engine.state.transition(.running);
            }
        }

        self.storage_engine.memtable_manager.flush_to_sstable(&self.storage_engine.sstable_manager) catch |err| {
            error_context.log_storage_error(err, error_context.StorageContext{ .operation = "flush_to_sstable" });
            return err;
        };

        // Reset storage arena to reclaim memory from flushed memtable
        self.storage_engine.reset_storage_memory();

        // Execute compaction if needed using command pattern
        const compaction_command = CompactionCommand{ .storage_engine = self.storage_engine };
        try compaction_command.execute();

        self.storage_engine.storage_metrics.sstable_writes.incr();
    }
};

/// Command to execute SSTable compaction with proper state transitions.
/// Encapsulates compaction logic with state machine coordination.
/// Decouples compaction callers from direct SSTableManager interaction.
const CompactionCommand = struct {
    storage_engine: *StorageEngine,

    /// Execute compaction if needed with proper state transitions.
    /// Handles state machine transitions and error context logging.
    fn execute(self: CompactionCommand) !void {
        concurrency.assert_main_thread();

        if (!self.storage_engine.sstable_manager.should_compact()) {
            return; // No compaction needed
        }

        // Ensure we're in running state before transitioning to compacting
        if (self.storage_engine.state != .running) {
            self.storage_engine.state.transition(.running);
        }
        self.storage_engine.state.transition(.compacting);
        defer {
            // Only transition back to running if we're not already there
            if (self.storage_engine.state != .running) {
                self.storage_engine.state.transition(.running);
            }
        }

        self.storage_engine.sstable_manager.execute_compaction() catch |err| {
            error_context.log_storage_error(err, error_context.StorageContext{ .operation = "compaction_command" });
            return err;
        };

        self.storage_engine.storage_metrics.compactions.incr();
    }
};

/// Main storage engine coordinating all storage subsystems with state machine validation.
/// Implements LSM-tree architecture with WAL durability, in-memory
/// memtable management, immutable SSTables, and background compaction.
/// Follows state-oriented decomposition with MemtableManager for in-memory
/// state (including WAL ownership) and SSTableManager for on-disk state.
/// Uses StorageState enum to prevent invalid operations and ensure correct lifecycle.
pub const StorageEngine = struct {
    backing_allocator: std.mem.Allocator,
    vfs: VFS,
    data_dir: []const u8,
    config: Config,
    memtable_manager: MemtableManager,
    sstable_manager: SSTableManager,
    state: StorageState,
    storage_metrics: StorageMetrics,
    /// Heap-allocated arena for ALL storage subsystem memory allocation.
    /// Arena Coordinator Pattern: Arena is allocated on heap with stable pointer,
    /// eliminating corruption from struct copying while maintaining O(1) cleanup.
    storage_arena: *std.heap.ArenaAllocator,
    arena_coordinator: *ArenaCoordinator,

    /// Fixed-size object pools for frequently allocated/deallocated objects.
    /// Eliminates allocation overhead and fragmentation for SSTable and iterator objects.
    // TEMP: Comment out sstable_pool to test if object pools are causing SIGILL
    // sstable_pool: pools.ObjectPoolType(SSTable),
    // TEMP: Comment out iterator_pool to bypass SIGILL crash in object pool initialization
    // iterator_pool: pools.ObjectPoolType(StorageEngine.BlockIterator),

    /// Initialize storage engine with default configuration.
    /// Uses Arena Coordinator Pattern to eliminate arena corruption from struct copying.
    /// Arena coordinator provides stable interface that remains valid across operations.
    pub fn init_default(
        allocator: std.mem.Allocator,
        filesystem: VFS,
        data_dir: []const u8,
    ) !StorageEngine {
        return init(allocator, filesystem, data_dir, Config{});
    }

    /// Phase 1 initialization: Create storage engine with Arena Coordinator Pattern.
    /// Creates stable arena coordinator interface that eliminates arena corruption.
    /// Coordinator remains valid even when struct is copied, fixing segmentation faults.
    pub fn init(
        allocator: std.mem.Allocator,
        filesystem: VFS,
        data_dir: []const u8,
        storage_config: Config,
    ) !StorageEngine {
        assert_mod.assert_not_empty(data_dir, "Storage data_dir cannot be empty", .{});
        // Safety: Converting pointer to integer for null pointer validation
        assert_mod.assert_fmt(@intFromPtr(data_dir.ptr) != 0, "Storage data_dir has null pointer", .{});

        storage_config.validate() catch |err| {
            error_context.log_storage_error(err, error_context.StorageContext{ .operation = "config_validation" });
            return err;
        };

        const owned_data_dir = allocator.dupe(u8, data_dir) catch |err| {
            error_context.log_storage_error(err, error_context.file_context("allocate_data_dir", data_dir));
            return err;
        };

        // Arena Coordinator Pattern: Allocate arena on heap for stable pointer
        const storage_arena = try allocator.create(std.heap.ArenaAllocator);
        storage_arena.* = std.heap.ArenaAllocator.init(allocator);

        const arena_coordinator = try allocator.create(ArenaCoordinator);
        arena_coordinator.* = ArenaCoordinator.init(storage_arena);

        // Pool sizes chosen based on typical usage patterns:
        // - SSTable pool: 16 objects (handles concurrent reads + compaction)
        // - Iterator pool: 32 objects (query parallelism + background operations)
        // TEMP: Skip sstable_pool initialization to test if object pools are causing SIGILL
        // const sstable_pool = pools.ObjectPoolType(SSTable).init(allocator, 16) catch |err| {
        //     storage_arena.deinit();
        //     allocator.destroy(storage_arena);
        //     allocator.destroy(arena_coordinator);

        //     allocator.free(owned_data_dir);
        //     error_context.log_storage_error(err, error_context.StorageContext{ .operation = "sstable_pool_init" });
        //     return err;
        // };

        // TEMP: Skip iterator_pool initialization to bypass SIGILL crash
        // const iterator_pool = pools.ObjectPoolType(StorageEngine.BlockIterator).init(allocator, 32) catch |err| {
        //     storage_arena.deinit();
        //     allocator.destroy(storage_arena);
        //     allocator.destroy(arena_coordinator);

        //     allocator.free(owned_data_dir);
        //     error_context.log_storage_error(err, error_context.StorageContext{ .operation = "iterator_pool_init" });
        //     return err;
        // };

        var engine = StorageEngine{
            .backing_allocator = allocator,
            .vfs = filesystem,
            .data_dir = owned_data_dir,
            .config = storage_config,
            .memtable_manager = undefined, // Initialize after arena coordinator is stable
            .sstable_manager = undefined, // Coordinator must be in final location first
            .state = .initialized,
            .storage_metrics = StorageMetrics.init(),
            .storage_arena = storage_arena,
            .arena_coordinator = arena_coordinator,

            // TEMP: Skip sstable_pool field
            // .sstable_pool = sstable_pool,
            // TEMP: Skip iterator_pool field initialization
            // .iterator_pool = iterator_pool,
        };

        // CRITICAL: Pass ArenaCoordinator by pointer to prevent struct copying corruption
        engine.memtable_manager = MemtableManager.init(engine.arena_coordinator, allocator, filesystem, owned_data_dir, storage_config.memtable_max_size) catch |err| {
            storage_arena.deinit();
            allocator.destroy(storage_arena);
            allocator.destroy(arena_coordinator);

            allocator.free(owned_data_dir);
            error_context.log_storage_error(err, error_context.file_context("memtable_manager_init", owned_data_dir));
            return err;
        };
        engine.sstable_manager = SSTableManager.init(engine.arena_coordinator, allocator, filesystem, owned_data_dir);

        engine.validate_memory_hierarchy();

        return engine;
    }

    /// Validate Arena Coordinator Pattern integrity.
    /// Ensures coordinator interface properly references storage arena.
    /// Zero runtime overhead in release builds through comptime evaluation.
    pub fn validate_memory_hierarchy(self: *const StorageEngine) void {
        if (comptime builtin.mode == .Debug) {
            // Validate coordinator pattern integrity
            self.arena_coordinator.validate_coordinator();

            // Ensure coordinator points to our heap-allocated storage arena
            // Safety: Converting pointers to integers for arena reference validation
            fatal_assert(@intFromPtr(self.arena_coordinator.arena) == @intFromPtr(self.storage_arena), "ArenaCoordinator does not reference StorageEngine arena - coordinator corruption", .{});

            // Note: Direct arena reference validation would require more complex
            // pointer tracking. Current approach validates structure at init time.
        }
    }

    /// Gracefully shutdown the storage engine with pending operation flush.
    pub fn shutdown(self: *StorageEngine) !void {
        concurrency.assert_main_thread();

        if (self.state == .stopped) return;

        // Only attempt flush operations if engine is in a running state
        if (self.state.can_write()) {
            if (self.memtable_manager.block_index.blocks.count() > 0) {
                try self.coordinate_memtable_flush();
            }

            try self.flush_wal();
        }

        if (self.state == .initialized) {
            // From initialized, can only go directly to stopped
            self.state.transition(.stopped);
        } else if (self.state != .stopping and self.state != .stopped) {
            // From running/compacting/flushing, go through stopping first
            self.state.transition(.stopping);
            self.state.transition(.stopped);
        } else if (self.state == .stopping) {
            self.state.transition(.stopped);
        }
    }

    /// Reset all storage memory in O(1) time through coordinator pattern.
    /// Clears ALL storage subsystem memory (blocks, edges, paths, etc.) in constant time.
    /// Coordinator interface remains stable after reset, eliminating temporal coupling.
    pub fn reset_storage_memory(self: *StorageEngine) void {
        concurrency.assert_main_thread();

        // Clear submodule structures before arena reset
        self.memtable_manager.block_index.clear();
        self.memtable_manager.graph_index.clear();

        // O(1) reset through coordinator - interface remains valid after operation
        self.arena_coordinator.reset();

        self.validate_memory_hierarchy();
    }

    /// Clean up all storage engine resources after shutdown.
    /// Must be called to prevent memory leaks and ensure proper cleanup.
    pub fn deinit(self: *StorageEngine) void {
        concurrency.assert_main_thread();
        // Safety: Converting pointer to integer for memory corruption detection
        fatal_assert(@intFromPtr(self) != 0, "StorageEngine self pointer is null - memory corruption detected", .{});

        // Prevent double-free by checking if data_dir is already freed
        if (self.data_dir.len == 0) {
            return; // Already deinitialized
        }

        if (self.state != .stopped) {
            self.shutdown() catch |err| {
                // Log error but continue cleanup to prevent resource leaks
                error_context.log_storage_error(err, error_context.StorageContext{ .operation = "shutdown_during_deinit" });
            };
        }

        // Hierarchical cleanup: Deinit submodules first, then pools, then coordinator arena
        self.memtable_manager.deinit();
        self.sstable_manager.deinit();

        // TEMP: Skip object pool cleanup since pools are commented out
        // Clean up object pools - must be done after submodules that might use pooled objects
        // Note: Pools are const so we need temporary mutable copies for deinit
        // {
        //     var mut_sstable_pool = self.sstable_pool;
        //     // TEMP: Skip iterator_pool cleanup
        //     // var mut_iterator_pool = self.iterator_pool;
        //     mut_sstable_pool.deinit();
        //     // mut_iterator_pool.deinit();
        // }

        // StorageEngine owns and cleans up the heap-allocated storage arena
        // This frees ALL storage memory in O(1) time
        self.storage_arena.deinit();
        self.backing_allocator.destroy(self.storage_arena);
        // Clean up heap-allocated coordinator
        self.backing_allocator.destroy(self.arena_coordinator);

        self.backing_allocator.free(self.data_dir);
        // Mark as deinitialized to prevent double-free
        self.data_dir = "";
    }

    /// Coordinate memtable flush operation without containing business logic.
    /// Pure delegation to subsystems for flush orchestration.
    fn coordinate_memtable_flush(self: *StorageEngine) !void {
        // Safety: Converting pointer to integer for subsystem corruption detection
        assert_mod.assert_fmt(@intFromPtr(&self.sstable_manager) != 0, "SSTableManager corrupted before flush", .{});

        const command = FlushMemtableCommand{ .storage_engine = self };
        command.execute() catch |err| {
            error_context.log_storage_error(err, error_context.StorageContext{ .operation = "coordinate_memtable_flush" });
            return err;
        };
    }

    /// Flush current memtable to SSTable using command pattern.
    /// Delegates to FlushMemtableCommand for decoupled subsystem coordination.
    fn flush_memtable(self: *StorageEngine) !void {
        const command = FlushMemtableCommand{ .storage_engine = self };
        try command.execute();
    }

    /// Public wrapper for memtable flush - backward compatibility.
    /// Delegates to command pattern for coordinated subsystem management.
    pub fn flush_memtable_to_sstable(self: *StorageEngine) !void {
        const command = FlushMemtableCommand{ .storage_engine = self };
        command.execute() catch |err| {
            error_context.log_storage_error(err, error_context.StorageContext{ .operation = "flush_memtable_to_sstable" });
            return err;
        };
    }

    /// Track write operation metrics without business logic.
    /// Pure metrics recording delegation to storage metrics subsystem.
    fn track_write_metrics(self: *StorageEngine, start_time: i128, content_len: usize) void {
        const end_time = std.time.nanoTimestamp();

        // System clock can go backwards due to NTP adjustments or high-frequency operations.
        // In such cases, record a minimal duration (1ns) to maintain metric consistency.
        // Safety: Time difference is always non-negative and fits in u64 range
        const write_duration: u64 = if (end_time >= start_time)
            @as(u64, @intCast(end_time - start_time))
        else
            1; // Minimum measurable duration when time goes backwards

        const blocks_before = self.storage_metrics.blocks_written.load();
        self.storage_metrics.blocks_written.incr();

        self.storage_metrics.total_write_time_ns.add(write_duration);
        self.storage_metrics.total_bytes_written.add(content_len);

        assert_mod.assert_fmt(self.storage_metrics.blocks_written.load() == blocks_before + 1, "Blocks written counter update failed", .{});
    }

    /// Create directory structure and discover existing data files.
    /// Called internally by startup() to prepare filesystem state.
    fn create_storage_directories(self: *StorageEngine) !void {
        concurrency.assert_main_thread();
        fatal_assert(@intFromPtr(self) != 0, "StorageEngine self pointer is null - memory corruption detected", .{});

        if (self.data_dir.len == 0) {
            return error.StorageEngineDeinitialized;
        }

        if (self.state != .initialized) {
            fatal_assert(false, "create_storage_directories called in invalid state: {}", .{self.state});
        }

        if (!self.vfs.exists(self.data_dir)) {
            self.vfs.mkdir(self.data_dir) catch |err| switch (err) {
                error.FileExists => {}, // Directory already exists, continue
                else => {
                    error_context.log_storage_error(err, error_context.file_context("create_data_directory", self.data_dir));
                    return err;
                },
            };
        }

        // State remains .initialized until startup() transitions to .running
    }

    /// Transition from initialized to running state with I/O operations.
    pub fn startup(self: *StorageEngine) !void {
        // Handle restart case: transition from stopped back to initialized
        if (self.state == .stopped) {
            self.state.transition(.initialized);
        }

        self.create_storage_directories() catch |err| {
            error_context.log_storage_error(err, error_context.file_context("create_storage_directories", self.data_dir));
            return err;
        };
        self.memtable_manager.startup() catch |err| {
            error_context.log_storage_error(err, error_context.file_context("memtable_manager_startup", self.data_dir));
            return err;
        };
        self.sstable_manager.startup() catch |err| {
            error_context.log_storage_error(err, error_context.file_context("sstable_manager_startup", self.data_dir));
            return err;
        };
        self.memtable_manager.recover_from_wal() catch |err| {
            error_context.log_storage_error(err, error_context.file_context("wal_recovery", self.data_dir));
            return err;
        };

        self.state.transition(.running);
    }

    /// Write an OwnedBlock to storage with full durability guarantees.
    /// Preferred method that uses zero-cost ownership for safety without performance overhead.
    pub fn put_block_owned(self: *StorageEngine, owned_block: OwnedBlock) !void {
        concurrency.assert_main_thread();

        fatal_assert(@intFromPtr(self) != 0, "StorageEngine self pointer is null - memory corruption detected", .{});

        if (self.data_dir.len == 0) {
            return error.StorageEngineDeinitialized;
        }

        const block_data = owned_block.read(.temporary);

        assert_mod.assert_fmt(block_data.content.len > 0, "Block content cannot be empty", .{});
        assert_mod.assert_fmt(block_data.source_uri.len > 0, "Block source_uri cannot be empty", .{});
        assert_mod.assert_fmt(block_data.content.len < 100 * 1024 * 1024, "Block content too large: {} bytes", .{block_data.content.len});
        assert_mod.assert_fmt(block_data.source_uri.len < 2048, "Block source_uri too long: {} bytes", .{block_data.source_uri.len});
        assert_mod.assert_fmt(block_data.metadata_json.len < 1024 * 1024, "Block metadata_json too large: {} bytes", .{block_data.metadata_json.len});
        assert_mod.assert_fmt(block_data.version > 0, "Block version must be positive: {}", .{block_data.version});

        if (!self.state.can_write()) {
            return if (self.state == .uninitialized or self.state == .initialized) StorageError.NotInitialized else StorageError.StorageEngineDeinitialized;
        }

        const start_time = std.time.nanoTimestamp();
        assert_mod.assert_fmt(start_time > 0, "Invalid timestamp: {}", .{start_time});

        block_data.validate(self.backing_allocator) catch |err| {
            error_context.log_storage_error(err, error_context.block_context("block_validation", block_data.id));
            return err;
        };

        // Check compaction throttling - prevent runaway L0 growth
        if (self.sstable_manager.compaction_manager.should_block_writes()) {
            // Try to trigger compaction before blocking in single-threaded CLI context
            self.sstable_manager.check_and_run_compaction() catch |err| {
                error_context.log_storage_error(err, error_context.block_context("emergency_compaction", block_data.id));
                // If compaction fails, still block writes to prevent L0 explosion
                return error.WriteBlocked;
            };

            // Check again after compaction - if still blocked, fail
            if (self.sstable_manager.compaction_manager.should_block_writes()) {
                return error.WriteBlocked;
            }
        }
        if (self.sstable_manager.compaction_manager.should_stall_writes()) {
            // Record stall metrics for monitoring and backpressure feedback loop
            self.sstable_manager.compaction_manager.update_throttle_state();
            return error.WriteStalled;
        }

        fatal_assert(@intFromPtr(&self.memtable_manager) != 0, "MemtableManager pointer corrupted - memory safety violation detected", .{});

        // Transfer ownership from storage engine to memtable manager
        var mutable_owned_block = owned_block;
        const transferred_block = mutable_owned_block.transfer(.memtable_manager, undefined);

        self.memtable_manager.put_block_durable_owned(transferred_block) catch |err| {
            error_context.log_storage_error(err, error_context.block_context("put_block_durable_owned", block_data.id));
            return err;
        };

        if (self.memtable_manager.should_flush()) {
            self.coordinate_memtable_flush() catch |err| {
                error_context.log_storage_error(err, error_context.block_context("coordinate_memtable_flush", block_data.id));
                return err;
            };

            // Only trigger compaction if actually needed to prevent L0 accumulation
            // This avoids performance regression from unnecessary compaction
            if (self.sstable_manager.should_compact()) {
                self.sstable_manager.check_and_run_compaction() catch |err| {
                    error_context.log_storage_error(err, error_context.block_context("check_and_run_compaction", block_data.id));
                    return err;
                };
            }
        }

        // Update throttle state after successful write
        self.sstable_manager.compaction_manager.update_throttle_state();

        self.track_write_metrics(start_time, block_data.content.len);

        // Skip per-operation validation to prevent performance regression
        // StorageEngine validation is extremely expensive (validates all subsystems)
        // and causes 60-70% performance degradation on storage write hot paths
        // Validation should be called explicitly when needed, not on every write
    }

    /// Write a block to storage - primary public API.
    /// Accepts ContextBlock from external callers and manages internal ownership transfer.
    pub fn put_block(self: *StorageEngine, block: ContextBlock) !void {
        // Convert to owned block for internal storage subsystem coordination
        const owned_block = OwnedBlock.take_ownership(block, .storage_engine);
        return self.put_block_owned(owned_block);
    }

    // REMOVED: put_block_temporary() - Use put_block() with OwnedBlock.
    // For legacy callers, create OwnedBlock.take_ownership(block, .temporary)
    // before calling put_block().

    /// Find a Context Block by ID with ownership-aware semantics.
    /// Returns OwnedBlock that can be safely transferred between subsystems.
    /// Preferred method for query engine and other ownership-aware consumers.
    pub fn find_block_with_ownership(
        self: *StorageEngine,
        block_id: BlockId,
        block_ownership: BlockOwnership,
    ) !?OwnedBlock {
        concurrency.assert_main_thread();
        fatal_assert(@intFromPtr(self) != 0, "StorageEngine self pointer is null - memory corruption detected", .{});

        if (self.data_dir.len == 0) {
            return error.StorageEngineDeinitialized;
        }

        var non_zero_bytes: u32 = 0;
        for (block_id.bytes) |byte| {
            if (byte != 0) non_zero_bytes += 1;
        }
        assert_mod.assert_fmt(non_zero_bytes > 0, "Block ID cannot be all zeros", .{});

        if (!self.state.can_read()) {
            return if (self.state == .uninitialized or self.state == .initialized) StorageError.NotInitialized else StorageError.StorageEngineDeinitialized;
        }

        const start_time = std.time.nanoTimestamp();

        // Memtable-first strategy: recent writes are in-memory for O(1) access,
        // avoiding disk I/O for hot data and maintaining read-after-write consistency
        if (try self.memtable_manager.find_block_with_ownership(block_id, block_ownership)) |owned_block| {
            const end_time = std.time.nanoTimestamp();
            const read_duration: u64 = if (end_time >= start_time)
                @as(u64, @intCast(end_time - start_time))
            else
                1; // Minimum measurable duration when time goes backwards

            self.storage_metrics.blocks_read.incr();
            self.storage_metrics.total_read_time_ns.add(read_duration);
            self.storage_metrics.total_bytes_read.add(owned_block.block.content.len);
            return owned_block;
        }

        // SSTable fallback with zero-copy optimization: eliminates redundant allocations
        // by using ParsedBlock view until ownership transfer is required
        const parsed_block_result = self.sstable_manager.find_block_view_in_sstables(block_id) catch |err| {
            error_context.log_storage_error(err, error_context.block_context("find_block_view_in_sstables", block_id));
            return err;
        };

        if (parsed_block_result) |parsed_block| {
            // Convert to owned block only at the final moment for ownership transfer
            const owned_context_block = try parsed_block.to_owned(self.arena_coordinator.allocator());
            const owned_block = OwnedBlock.take_ownership(owned_context_block, block_ownership);

            const end_time = std.time.nanoTimestamp();
            const read_duration: u64 = if (end_time >= start_time)
                @as(u64, @intCast(end_time - start_time))
            else
                1; // Minimum measurable duration when time goes backwards

            self.storage_metrics.blocks_read.incr();
            self.storage_metrics.sstable_reads.incr();
            self.storage_metrics.total_read_time_ns.add(read_duration);
            self.storage_metrics.total_bytes_read.add(parsed_block.content().len);

            return owned_block;
        }

        return null;
    }

    /// Zero-cost block lookup for hot paths with compile-time ownership.
    /// Eliminates all runtime overhead while maintaining type safety.
    /// Use this for performance-critical operations where ownership is known at compile time.
    pub fn find_block(
        self: *StorageEngine,
        block_id: BlockId,
        comptime owner: BlockOwnership,
    ) !?OwnedBlock {
        concurrency.assert_main_thread();
        // Hot path optimizations: minimal validation, direct access
        if (comptime builtin.mode == .Debug) {
            fatal_assert(@intFromPtr(self) != 0, "StorageEngine corrupted", .{});
            assert_mod.assert_fmt(!block_id.eql(BlockId.from_bytes([_]u8{0} ** 16)), "Invalid block ID: cannot be all zeros", .{});
        }

        if (!self.state.can_read()) {
            return if (self.state == .uninitialized or self.state == .initialized) StorageError.NotInitialized else StorageError.StorageEngineDeinitialized;
        }

        // Fast path: check memtable first (most recent data)
        if (self.memtable_manager.find_block_in_memtable(block_id)) |block| {
            return OwnedBlock.take_ownership(block, owner);
        }

        // Slower path: check SSTables with zero-copy optimization
        if (try self.sstable_manager.find_block_view_in_sstables(block_id)) |parsed_block| {
            // Convert to owned block only when ownership transfer is required
            const owned_context_block = try parsed_block.to_owned(self.arena_coordinator.allocator());
            return OwnedBlock.take_ownership(owned_context_block, owner);
        }

        return null;
    }

    /// Zero-cost storage engine block lookup - fastest possible read path.
    /// Compile-time ownership guarantees with zero runtime overhead.
    pub fn find_storage_block(
        self: *StorageEngine,
        block_id: BlockId,
    ) !?OwnedBlock {
        if (comptime builtin.mode == .Debug) {
            fatal_assert(@intFromPtr(self) != 0, "StorageEngine corrupted", .{});
        }

        if (self.memtable_manager.find_block_in_memtable(block_id)) |block_ptr| {
            return OwnedBlock.take_ownership(block_ptr.*, .storage_engine);
        }

        if (try self.sstable_manager.find_block_view_in_sstables(block_id)) |parsed_block| {
            const owned_context_block = try parsed_block.to_owned(self.arena_coordinator.allocator());
            return OwnedBlock.take_ownership(owned_context_block, .storage_engine);
        }

        return null;
    }

    /// Zero-cost query engine block lookup for cross-subsystem access.
    /// Enables fast block transfer to query engine with compile-time safety.
    /// Find a Context Block by ID with zero-cost ownership for query operations
    pub fn find_query_block(self: *StorageEngine, block_id: BlockId) !?OwnedBlock {
        if (comptime builtin.mode == .Debug) {
            fatal_assert(@intFromPtr(self) != 0, "StorageEngine corrupted", .{});
        }

        if (self.memtable_manager.find_block_in_memtable(block_id)) |block| {
            return OwnedBlock.take_ownership(block, .query_engine);
        }

        const parsed_block_result = try self.sstable_manager.find_block_view_in_sstables(block_id);

        if (parsed_block_result) |parsed_block| {
            const owned_context_block = try parsed_block.to_owned(self.arena_coordinator.allocator());
            return OwnedBlock.take_ownership(owned_context_block, .query_engine);
        }

        return null;
    }

    /// Delete a Context Block by ID with tombstone semantics.
    pub fn delete_block(self: *StorageEngine, block_id: BlockId) !void {
        concurrency.assert_main_thread();
        if (!self.state.can_write()) {
            return if (self.state == .uninitialized or self.state == .initialized) StorageError.NotInitialized else StorageError.StorageEngineDeinitialized;
        }

        self.memtable_manager.delete_block_durable(block_id) catch |err| {
            error_context.log_storage_error(err, error_context.block_context("delete_block_durable", block_id));
            return err;
        };

        self.storage_metrics.blocks_deleted.incr();
    }

    /// Add a graph edge with durability guarantees.
    pub fn put_edge(self: *StorageEngine, edge: GraphEdge) !void {
        concurrency.assert_main_thread();

        fatal_assert(@intFromPtr(self) != 0, "StorageEngine self pointer is null - memory corruption detected", .{});

        if (self.data_dir.len == 0) {
            return error.StorageEngineDeinitialized;
        }

        var source_non_zero: u32 = 0;
        var target_non_zero: u32 = 0;
        for (edge.source_id.bytes) |byte| {
            if (byte != 0) source_non_zero += 1;
        }
        for (edge.target_id.bytes) |byte| {
            if (byte != 0) target_non_zero += 1;
        }
        assert_mod.assert_fmt(source_non_zero > 0, "Edge source_id cannot be all zeros", .{});
        assert_mod.assert_fmt(target_non_zero > 0, "Edge target_id cannot be all zeros", .{});
        assert_mod.assert_fmt(!std.mem.eql(u8, &edge.source_id.bytes, &edge.target_id.bytes), "Edge cannot be self-referential", .{});

        if (!self.state.can_write()) {
            return if (self.state == .uninitialized or self.state == .initialized) StorageError.NotInitialized else StorageError.StorageEngineDeinitialized;
        }

        const start_time = std.time.nanoTimestamp();
        assert_mod.assert_fmt(start_time > 0, "Invalid timestamp: {}", .{start_time});

        fatal_assert(@intFromPtr(&self.memtable_manager) != 0, "MemtableManager pointer corrupted - memory safety violation detected", .{});

        self.memtable_manager.put_edge_durable(edge) catch |err| {
            error_context.log_storage_error(err, error_context.block_context("put_edge_durable", edge.source_id));
            return err;
        };

        const edges_before = self.storage_metrics.edges_added.load();
        self.storage_metrics.edges_added.incr();

        fatal_assert(self.storage_metrics.edges_added.load() == edges_before + 1, "Edges added counter update failed - metrics corruption detected", .{});
    }

    /// Force synchronization of all WAL operations to durable storage.
    pub fn flush_wal(self: *StorageEngine) !void {
        concurrency.assert_main_thread();
        if (!self.state.can_write()) {
            return if (self.state == .uninitialized or self.state == .initialized) StorageError.NotInitialized else StorageError.StorageEngineDeinitialized;
        }

        self.memtable_manager.flush_wal() catch |err| {
            error_context.log_storage_error(err, error_context.StorageContext{ .operation = "flush_wal" });
            return err;
        };
    }

    /// Disable WAL write verification for simulation tests with intentional corruption.
    /// This prevents WAL write verification from failing when corruption is
    /// intentionally injected during testing.
    pub fn disable_wal_verification_for_simulation(self: *StorageEngine) void {
        concurrency.assert_main_thread();
        self.memtable_manager.wal.disable_write_verification_for_simulation();
    }

    /// Get current memory usage information for testing and monitoring.
    /// Returns basic memory statistics useful for tests and debugging.
    pub fn memory_usage(self: *const StorageEngine) MemoryUsage {
        return MemoryUsage{
            .total_bytes = self.memtable_manager.block_index.memory_used,
            .block_count = @as(u32, @intCast(self.memtable_manager.block_index.blocks.count())),
            .edge_count = self.memtable_manager.graph_index.edge_count(),
        };
    }

    /// Memory usage information structure for testing and monitoring
    pub const MemoryUsage = struct {
        total_bytes: u64,
        block_count: u32,
        edge_count: u32,
    };

    /// Find all outgoing edges from a source block.
    /// Searches both memtable and SSTables following LSM-tree read path.
    /// Returns edges with memtable_manager ownership for consistency.
    pub fn find_outgoing_edges(self: *const StorageEngine, source_id: BlockId) []const OwnedGraphEdge {
        fatal_assert(@intFromPtr(self) != 0, "StorageEngine self pointer is null - memory corruption detected", .{});

        if (self.data_dir.len == 0) {
            return &[_]OwnedGraphEdge{}; // Return empty slice if deinitialized
        }

        var non_zero_bytes: u32 = 0;
        for (source_id.bytes) |byte| {
            if (byte != 0) non_zero_bytes += 1;
        }
        assert_mod.assert_fmt(non_zero_bytes > 0, "Source block ID cannot be all zeros", .{});

        fatal_assert(@intFromPtr(&self.memtable_manager) != 0, "MemtableManager pointer corrupted - memory safety violation detected", .{});

        // First check memtable (recent writes have precedence)
        const memtable_edges = self.memtable_manager.find_outgoing_edges(source_id);

        if (memtable_edges.len > 0) {
            fatal_assert(@intFromPtr(memtable_edges.ptr) != 0, "MemtableManager returned null edges pointer with non-zero length - heap corruption detected", .{});
            fatal_assert(std.mem.eql(u8, &memtable_edges[0].edge.source_id.bytes, &source_id.bytes), "First edge has wrong source_id - index corruption detected", .{});
            return memtable_edges;
        }

        // Check SSTables if not found in memtable
        // NOTE: SSTable edge querying not yet implemented - edges currently memtable-only
        // This maintains current behavior until full LSM-tree edge support is added

        return &[_]OwnedGraphEdge{};
    }

    /// Find all incoming edges to a target block.
    /// Delegates to memtable manager for reverse graph traversal operations.
    pub fn find_incoming_edges(self: *const StorageEngine, target_id: BlockId) []const OwnedGraphEdge {
        fatal_assert(@intFromPtr(self) != 0, "StorageEngine self pointer is null - memory corruption detected", .{});

        if (self.data_dir.len == 0) {
            return &[_]OwnedGraphEdge{}; // Return empty slice if deinitialized
        }

        var non_zero_bytes: u32 = 0;
        for (target_id.bytes) |byte| {
            if (byte != 0) non_zero_bytes += 1;
        }
        assert_mod.assert_fmt(non_zero_bytes > 0, "Target block ID cannot be all zeros", .{});

        fatal_assert(@intFromPtr(&self.memtable_manager) != 0, "MemtableManager pointer corrupted - memory safety violation detected", .{});

        const edges = self.memtable_manager.find_incoming_edges(target_id);

        if (edges.len > 0) {
            fatal_assert(@intFromPtr(edges.ptr) != 0, "MemtableManager returned null edges pointer with non-zero length - heap corruption detected", .{});
            fatal_assert(std.mem.eql(u8, &edges[0].edge.target_id.bytes, &target_id.bytes), "First edge has wrong target_id - index corruption detected", .{});
        }

        return edges;
    }

    /// Get performance metrics for monitoring and debugging.
    pub fn metrics(self: *const StorageEngine) *const StorageMetrics {
        return &self.storage_metrics;
    }

    /// Calculate current memory pressure level for backpressure control.
    /// Updates metrics with current memtable and compaction state before calculation.
    /// Used by ingestion pipeline to adapt batch sizes based on storage load.
    pub fn memory_pressure(
        self: *StorageEngine,
        config: StorageMetrics.MemoryPressureConfig,
    ) StorageMetrics.MemoryPressure {
        const memtable_bytes = self.memtable_manager.block_index.memory_used;
        self.storage_metrics.memtable_memory_bytes.store(memtable_bytes);

        const queue_size = @as(u64, @intCast(self.sstable_manager.sstable_paths.items.len));
        self.storage_metrics.compaction_queue_size.store(queue_size);

        return self.storage_metrics.calculate_memory_pressure(config);
    }

    /// Block iterator for scanning all blocks in storage (memtable only).
    /// Complete storage iterator that traverses both memtable and SSTables.
    /// Follows coordinator pattern - delegates to subsystems for actual iteration.
    pub const BlockIterator = struct {
        memtable_iterator: BlockHashMapIterator,
        sstable_manager: *SSTableManager,
        backing_allocator: std.mem.Allocator,
        iteration_arena: std.heap.ArenaAllocator,
        current_sstable_index: u32,
        current_sstable_iterator: ?sstable.SSTableIterator,
        current_sstable: ?*SSTable,
        seen_blocks: std.AutoHashMap(BlockId, void),

        /// Iterate through memtable first, then all SSTables in order.
        /// Returns OwnedBlock with storage_engine ownership for safe cross-subsystem usage.
        pub fn next(self: *BlockIterator) !?OwnedBlock {
            // First, exhaust memtable
            if (self.memtable_iterator.next()) |entry| {
                const owned_block = entry.value_ptr.*;
                // Clone with storage_engine ownership using iteration arena for automatic cleanup
                const cloned_block = try owned_block.clone_with_ownership(self.iteration_arena.allocator(), .storage_engine, null);
                // Track block to prevent duplicates from SSTables (skip dedup on OOM)
                self.seen_blocks.put(cloned_block.read(.storage_engine).id, {}) catch {};
                return cloned_block;
            }

            // Then iterate through SSTables
            while (self.current_sstable_index < @as(u32, @intCast(self.sstable_manager.sstable_paths.items.len))) {
                // Lazy SSTable opening: avoids file handles for SSTables we might skip
                // due to early termination or empty tables
                if (self.current_sstable_iterator == null) {
                    // Prevent cascade failures from corrupted arena state during SSTable allocation
                    self.sstable_manager.arena_coordinator.validate_coordinator();

                    const sstable_path = self.sstable_manager.find_path_by_index(self.current_sstable_index) orelse {
                        self.current_sstable_index += 1;
                        continue;
                    };

                    const path_copy = self.backing_allocator.dupe(u8, sstable_path) catch {
                        self.current_sstable_index += 1;
                        continue;
                    };

                    // Early corruption detection: validate before allocation to prevent
                    // cascading failures from invalid arena state
                    self.sstable_manager.arena_coordinator.validate_coordinator();

                    // Heap-allocate SSTable to ensure stable memory addresses
                    var new_sstable = try self.backing_allocator.create(SSTable);
                    new_sstable.* = SSTable.init(self.sstable_manager.arena_coordinator, self.backing_allocator, self.sstable_manager.vfs, path_copy);
                    new_sstable.read_index() catch {
                        self.backing_allocator.destroy(new_sstable);
                        self.backing_allocator.free(path_copy);
                        self.current_sstable_index += 1;
                        continue;
                    };

                    self.current_sstable = new_sstable;
                    self.current_sstable_iterator = new_sstable.iterator();
                }

                // Ensure iterator's memory operations use valid arena state,
                // critical for preventing use-after-free in deserialization
                self.sstable_manager.arena_coordinator.validate_coordinator();

                if (try self.current_sstable_iterator.?.next()) |sstable_block| {
                    // Create owned block with storage_engine ownership for iterator return
                    const storage_block = OwnedBlock.take_ownership(sstable_block, .storage_engine);

                    // Skip if we've already seen this block (deduplication)
                    const gop = self.seen_blocks.getOrPut(sstable_block.id) catch {
                        // If dedup tracking OOM, just return the block anyway
                        return storage_block;
                    };
                    if (!gop.found_existing) {
                        return storage_block;
                    }
                    // Continue to next block if duplicate
                    continue;
                } else {
                    if (self.current_sstable_iterator) |*iter| {
                        iter.deinit();
                    }
                    if (self.current_sstable) |table| {
                        table.deinit();
                        self.backing_allocator.destroy(table);
                    }
                    self.current_sstable_iterator = null;
                    self.current_sstable = null;
                    self.current_sstable_index += 1;
                }
            }

            return null;
        }

        pub fn deinit(self: *BlockIterator) void {
            if (self.current_sstable_iterator) |*iter| {
                iter.deinit();
            }
            if (self.current_sstable) |table| {
                table.deinit();
                self.backing_allocator.destroy(table);
            }
            self.seen_blocks.deinit();
            self.iteration_arena.deinit();
        }
    };

    /// Create iterator to scan ALL blocks in both memtable and SSTables.
    /// Pure coordinator pattern - delegates to subsystems for actual iteration.
    pub fn iterate_all_blocks(self: *StorageEngine) BlockIterator {
        return BlockIterator{
            .memtable_iterator = self.memtable_manager.raw_iterator(),
            .sstable_manager = &self.sstable_manager,
            .backing_allocator = self.backing_allocator,
            .iteration_arena = std.heap.ArenaAllocator.init(self.backing_allocator),
            .current_sstable_index = 0,
            .current_sstable_iterator = null,
            .current_sstable = null,
            .seen_blocks = std.AutoHashMap(BlockId, void).init(self.backing_allocator),
        };
    }

    /// P0.5, P0.6, P0.7: Comprehensive invariant validation for StorageEngine.
    /// Validates WAL ordering, arena coordinator stability, memory accounting consistency,
    /// and subsystem state coherence. Critical for detecting programming errors.
    pub fn validate_invariants(self: *const StorageEngine) void {
        if (builtin.mode == .Debug) {
            self.validate_storage_state_invariants();
            self.validate_subsystem_coherence();
            self.validate_arena_memory_consistency();

            self.memtable_manager.validate_invariants();
            self.sstable_manager.validate_invariants();
        }
    }

    /// Validate StorageEngine state machine and critical pointers.
    fn validate_storage_state_invariants(self: *const StorageEngine) void {
        assert_fmt(builtin.mode == .Debug, "Storage state validation should only run in debug builds", .{});

        fatal_assert(@intFromPtr(self) != 0, "StorageEngine self pointer is null - memory corruption detected", .{});
        fatal_assert(@intFromPtr(&self.memtable_manager) != 0, "MemtableManager pointer corruption in StorageEngine", .{});
        fatal_assert(@intFromPtr(&self.sstable_manager) != 0, "SSTableManager pointer corruption in StorageEngine", .{});

        assert_fmt(self.state != .uninitialized or self.data_dir.len == 0, "Uninitialized state but data_dir is set: '{s}'", .{self.data_dir});
        assert_fmt(self.state == .uninitialized or self.data_dir.len > 0, "Initialized state but data_dir is empty", .{});

        if (self.data_dir.len > 0) {
            assert_fmt(self.data_dir.len < 4096, "Data directory path too long: {} bytes", .{self.data_dir.len});
            assert_fmt(@intFromPtr(self.data_dir.ptr) != 0, "Data directory pointer is null with length {}", .{self.data_dir.len});
        }
    }

    /// Validate coherence between StorageEngine subsystems.
    fn validate_subsystem_coherence(self: *const StorageEngine) void {
        assert_fmt(builtin.mode == .Debug, "Subsystem coherence validation should only run in debug builds", .{});

        const memtable_memory = self.memtable_manager.block_index.memory_used;
        const memtable_block_count = @as(u32, @intCast(self.memtable_manager.block_index.blocks.count()));

        if (memtable_block_count > 0) {
            const avg_block_size = memtable_memory / memtable_block_count;
            assert_fmt(avg_block_size > 0 and avg_block_size < 500 * 1024 * 1024, "Average block size {} indicates memory corruption", .{avg_block_size});
        }

        const memtable_blocks = memtable_block_count;
        const sstable_blocks = self.sstable_manager.total_block_count();
        assert_fmt(memtable_blocks < 1000000 and sstable_blocks < 10000000, "Block counts indicate potential corruption: memtable={} sstable={}", .{ memtable_blocks, sstable_blocks });
    }

    /// P0.6 & P0.7: Validate arena coordinator stability and memory consistency.
    fn validate_arena_memory_consistency(self: *const StorageEngine) void {
        assert_fmt(builtin.mode == .Debug, "Arena memory validation should only run in debug builds", .{});

        fatal_assert(@intFromPtr(&self.storage_arena) != 0, "Storage arena pointer corruption", .{});

        // Arena validation requires mutable access, but this method is const
        // Skip allocation test in const validation - arena corruption would be caught elsewhere
        // The pointer validation above is sufficient for detecting major corruption

        const test_backing_alloc = self.backing_allocator.alloc(u8, 1) catch {
            fatal_assert(false, "StorageEngine backing allocator non-functional - corruption detected", .{});
            return;
        };
        defer self.backing_allocator.free(test_backing_alloc);
    }
};

/// Type-safe storage coordinator for subsystem interactions.
/// Replaces *anyopaque patterns with compile-time validated interfaces.
/// Provides minimal, type-safe access to storage engine capabilities for subsystems.
pub const TypedStorageCoordinator = struct {
    storage_engine: *StorageEngine,

    /// Initialize coordinator with storage engine reference.
    /// Storage engine must outlive all coordinators.
    pub fn init(storage_engine: *StorageEngine) TypedStorageCoordinator {
        return TypedStorageCoordinator{ .storage_engine = storage_engine };
    }

    /// Get storage arena allocator for subsystem operations.
    /// Memory allocated from this arena is freed on next memtable flush.
    pub fn storage_allocator(self: TypedStorageCoordinator) std.mem.Allocator {
        return self.storage_engine.storage_arena.allocator();
    }

    /// Get query cache allocator for temporary query data.
    /// Memory allocated from this arena is freed when query cache is cleared.
    /// Validate storage engine is ready for read operations.
    /// Zero-cost in release builds through comptime evaluation.
    pub fn validate_read_state(self: TypedStorageCoordinator) bool {
        if (comptime builtin.mode == .Debug) {
            return self.storage_engine.state.can_read();
        }
        return true;
    }

    /// Validate storage engine is ready for write operations.
    /// Zero-cost in release builds through comptime evaluation.
    pub fn validate_write_state(self: TypedStorageCoordinator) bool {
        if (comptime builtin.mode == .Debug) {
            return self.storage_engine.state.can_write();
        }
        return true;
    }

    /// Get read-only access to storage metrics.
    /// Provides safe interface for subsystems to query storage state.
    pub fn query_metrics(self: TypedStorageCoordinator) *const StorageMetrics {
        return self.storage_engine.query_metrics();
    }

    /// Check for compaction opportunities and execute if beneficial.
    /// Pure coordinator that delegates decision and execution to SSTableManager.
    fn check_and_run_compaction(self: TypedStorageCoordinator) !void {
        const compaction_command = CompactionCommand{ .storage_engine = self.storage_engine };
        try compaction_command.execute();
    }

    /// Get file size for SSTable registration with compaction manager.
    fn read_file_size(self: *StorageEngine, path: []const u8) !u64 {
        var file = self.vfs.open(path, .read) catch |err| {
            error_context.log_storage_error(err, error_context.file_context("read_file_size_open", path));
            return err;
        };

        defer file.close();
        return file.file_size() catch |err| {
            error_context.log_storage_error(err, error_context.file_context("read_file_size_stat", path));
            return err;
        };
    }
};
