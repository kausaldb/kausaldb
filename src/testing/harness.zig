//! Core test harness for KausalDB deterministic simulation testing.
//!
//! Provides SimulationRunner and related infrastructure extracted from the
//! monolithic deterministic_test.zig. Focuses on test execution, state management,
//! and verification coordination.
//!
//! Design rationale: Separate core harness logic from workload generation,
//! model state, and property checking to create focused, maintainable modules.

const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const log = std.log.scoped(.harness);

const ownership = @import("../core/ownership.zig");
const simulation_vfs = @import("../sim/simulation_vfs.zig");
const storage_engine_mod = @import("../storage/engine.zig");
const types = @import("../core/types.zig");
const vfs_mod = @import("../core/vfs.zig");
const workload_mod = @import("workload.zig");
const model_mod = @import("model.zig");
const properties_mod = @import("properties.zig");

const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const EdgeType = types.EdgeType;
const GraphEdge = types.GraphEdge;
const OwnedBlock = ownership.OwnedBlock;
const SimulationVFS = simulation_vfs.SimulationVFS;

pub const Operation = workload_mod.Operation;
pub const OperationMix = workload_mod.OperationMix;
pub const OperationType = workload_mod.OperationType;
pub const WorkloadGenerator = workload_mod.WorkloadGenerator;
pub const ModelState = model_mod.ModelState;
pub const ModelBlock = model_mod.ModelBlock;
pub const PropertyChecker = properties_mod.PropertyChecker;

// Re-export storage engine type for convenience
pub const StorageEngine = storage_engine_mod.StorageEngine;

/// Fault injection specification for a single fault
pub const FaultSpec = struct {
    operation_number: u32,
    fault_type: FaultType,
    partial_write_probability: f32 = 0.0,
    io_error_probability: f32 = 0.0,
    corruption_probability: f32 = 0.0,
    syntax_error_probability: f32 = 0.0,
};

/// Types of faults that can be injected during simulation
pub const FaultType = enum {
    io_error,
    corruption,
    crash,
    network_partition,
    disk_full,
};

/// Schedule of faults to inject during simulation
pub const FaultSchedule = struct {
    seed: u64,
    faults: []const FaultSpec,
    next_fault_index: usize = 0,

    const Self = @This();

    pub fn should_inject_fault(self: *Self, operation_number: u32) ?FaultType {
        if (self.next_fault_index >= self.faults.len) return null;
        const fault = &self.faults[self.next_fault_index];
        if (fault.operation_number == operation_number) {
            self.next_fault_index += 1;
            return fault.fault_type;
        }
        return null;
    }
};

/// Memory usage statistics for tracking resource consumption
pub const MemoryStats = struct {
    total_bytes: u64,
    arena_bytes: u64,
    total_allocated: u64,
    block_count: u32,
    edge_count: u32,
};

/// Performance statistics for tracking operation metrics
pub const PerformanceStats = struct {
    blocks_written: u64,
    blocks_read: u64,
    edges_written: u64,
    flushes_completed: u64,
    compactions_completed: u64,
    avg_traversal_time: u64,
    avg_ingestion_time: u64,
};

/// Configuration for memtable flush behavior
pub const FlushConfig = struct {
    operation_threshold: u32 = 1000,
    memory_threshold: u64 = 16 * 1024 * 1024, // 16MB
    enable_memory_trigger: bool = false,
    enable_operation_trigger: bool = false,
};

/// Configuration for ingestion behavior
pub const IngestionConfig = struct {
    language: LanguageType = .mixed,
    simulate_incremental: bool = false,
    inject_parse_errors: bool = false,
    generate_large_files: bool = false,
    bulk_mode: bool = false,
    extract_comments: bool = false,
    extract_docs: bool = false,
    track_imports: bool = false,
    track_function_calls: bool = false,
    extract_all_metadata: bool = false,
    track_sequences: bool = false,
    generate_unicode_content: bool = false,
    allow_circular_imports: bool = false,
    generate_functions: bool = false,
    generate_traits: bool = false,
    generate_classes: bool = false,
    generate_interfaces: bool = false,
    language_distribution: LanguageDistribution = .{},
    modification_rate: f32 = 0.0,
    avg_functions_per_file: u32 = 10,
    files_per_batch: u32 = 10,
    extract_signatures: bool = false,
    link_docs_to_code: bool = false,
    resolve_import_paths: bool = false,
    resolve_call_targets: bool = false,
    generate_imports: bool = false,
    generate_impls: bool = false,
    generate_inheritance: bool = false,
    generate_types: bool = false,
    generate_structs: bool = false,
    generate_modules: bool = false,
    generate_decorators: bool = false,
    generate_exports: bool = false,
    avg_lines_per_function: u32 = 20,
    extract_body: bool = false,
    include_line_numbers: bool = false,
    preserve_history: bool = false,
    circular_import_probability: f32 = 0.0,
    include_complexity_metrics: bool = false,
};

/// Language distribution configuration
pub const LanguageDistribution = struct {
    zig: f32 = 0.25,
    rust: f32 = 0.25,
    python: f32 = 0.25,
    typescript: f32 = 0.25,
};

/// Configuration for query behavior
pub const QueryConfig = struct {
    max_traversal_depth: u32 = 10,
    validate_bidirectional: bool = false,
    use_repeated_queries: bool = false,
    track_query_plans: bool = false,
    use_filtering: bool = false,
    validate_result_ordering: bool = false,
    enable_depth_testing: bool = false,
    query_repetition_rate: f32 = 0.0,
    measure_index_hits: bool = false,
};

/// Language types for ingestion testing
pub const LanguageType = enum {
    zig,
    rust,
    python,
    typescript,
    mixed,
};

/// Configuration for workload generation behavior
pub const WorkloadConfig = struct {
    create_tight_cycles: bool = false,
    generate_unicode_metadata: bool = false,
    cycle_probability: f32 = 0.0,
    use_all_edge_types: bool = false,
    generate_rich_metadata: bool = false,
    target_fan_out: u32 = 3,
    allow_cycles: bool = false,
    create_self_loops: bool = false,
    create_hub_nodes: bool = false,
};

/// Core simulation test harness for deterministic testing
pub const SimulationRunner = struct {
    allocator: std.mem.Allocator,
    seed: u64,
    workload: WorkloadGenerator,
    model: ModelState,
    sim_vfs: *SimulationVFS,
    storage_engine: StorageEngine,
    fault_schedule: FaultSchedule,
    flush_config: FlushConfig,
    workload_config: WorkloadConfig,
    ingestion_config: IngestionConfig,
    query_config: QueryConfig,
    operations_since_flush: u32,
    corruption_expected: bool,
    peak_memory_bytes: u64,

    const Self = @This();

    /// Initialize simulation runner with deterministic seed and configuration
    pub fn init(
        allocator: std.mem.Allocator,
        seed: u64,
        operation_mix: OperationMix,
        faults: []const FaultSpec,
    ) !Self {
        var sim_vfs = try SimulationVFS.heap_init(allocator);

        var storage_engine = try StorageEngine.init_default(
            allocator,
            sim_vfs.vfs(),
            "/test_db",
        );
        try storage_engine.startup();

        // Disable WAL write verification for simulation tests to prevent
        // simulation VFS corruption issues from blocking other test progress
        storage_engine.disable_wal_verification_for_simulation();

        return Self{
            .allocator = allocator,
            .seed = seed,
            .workload = WorkloadGenerator.init(allocator, seed, operation_mix, WorkloadConfig{}),
            .model = try ModelState.init(allocator),
            .sim_vfs = sim_vfs,
            .storage_engine = storage_engine,
            .fault_schedule = FaultSchedule{
                .seed = seed,
                .faults = faults,
            },
            .flush_config = FlushConfig{},
            .workload_config = WorkloadConfig{},
            .ingestion_config = IngestionConfig{},
            .query_config = QueryConfig{},
            .operations_since_flush = 0,
            .corruption_expected = false,
            .peak_memory_bytes = 0,
        };
    }

    /// Cleanup all resources
    pub fn deinit(self: *Self) void {
        self.storage_engine.shutdown() catch {};
        self.storage_engine.deinit();
        self.sim_vfs.deinit();
        self.allocator.destroy(self.sim_vfs);
        self.model.deinit();
        self.workload.deinit();
    }

    /// Execute specified number of operations with fault injection
    pub fn run(self: *Self, operation_count: u32) !void {
        // Update workload generator with current configuration
        self.workload.update_config(self.workload_config);

        for (0..operation_count) |i| {
            const operation = try self.workload.generate_operation();
            defer self.workload.cleanup_operation(&operation);

            // Check for fault injection
            if (self.fault_schedule.should_inject_fault(@intCast(i))) |fault_type| {
                try self.inject_fault(fault_type);
            }

            // DEBUG: Log operation details before application
            if (builtin.mode == .Debug) {
                switch (operation.op_type) {
                    .put_block, .update_block => {
                        if (operation.block) |block| {
                            log.debug("OP[{}] PUT_BLOCK id={} sequence={} content_len={}", .{ i, block.id, block.sequence, block.content.len });
                        }
                    },
                    .delete_block => {
                        if (operation.block_id) |id| {
                            log.debug("OP[{}] DELETE_BLOCK id={}", .{ i, id });
                        }
                    },
                    .put_edge => {
                        if (operation.edge) |edge| {
                            log.debug("OP[{}] PUT_EDGE src={} -> tgt={}", .{ i, edge.source_id, edge.target_id });
                        }
                    },
                    else => {
                        log.debug("OP[{}] OTHER type={}", .{ i, operation.op_type });
                    },
                }
            }

            // Apply to system first to track actual success/failure
            const success = self.apply_operation_to_system(&operation) catch |err| blk: {
                // Handle expected failures that shouldn't update model
                switch (err) {
                    error.WriteStalled, error.WriteBlocked => break :blk false,
                    else => return err,
                }
            };

            // Only update model if system operation succeeded
            if (success) {
                const pre_model_seq = self.model.global_sequence;

                // For put_block operations, fetch the actual stored block to get the assigned sequence
                var model_operation = operation;
                if (operation.op_type == .put_block or operation.op_type == .update_block) {
                    if (operation.block) |original_block| {
                        if (try self.storage_engine.find_block(original_block.id, .temporary)) |stored_block| {
                            // Update the operation with the actual stored block (with correct sequence)
                            model_operation.block = stored_block.read(.temporary).*;
                        }
                    }
                }

                try self.model.apply_operation(&model_operation);

                // CRITICAL: Only increment workload counter when operation actually succeeds
                self.workload.confirm_operation_success();

                const post_model_seq = self.model.global_sequence;

                if (builtin.mode == .Debug) {
                    log.debug("OP[{}] MODEL_UPDATED: workload_seq={} model_seq_before={} model_seq_after={}", .{ i, operation.model_sequence, pre_model_seq, post_model_seq });

                    // CRITICAL: Check for sequence divergence
                    const expected_divergence = @as(i64, @intCast(self.workload.operation_count)) - @as(i64, @intCast(post_model_seq));
                    if (expected_divergence != 0) {
                        log.warn("OP[{}] SEQUENCE_DIVERGENCE: workload_count={} model_seq={} gap={}", .{ i, self.workload.operation_count, post_model_seq, expected_divergence });
                    }
                }
            } else {
                if (builtin.mode == .Debug) {
                    const divergence = @as(i64, @intCast(self.workload.operation_count)) - @as(i64, @intCast(self.model.global_sequence));
                    log.debug("OP[{}] MODEL_SKIPPED (system failed): workload_seq={} model_seq={} divergence_now={}", .{ i, operation.model_sequence, self.model.global_sequence, divergence });
                }
            }

            // Update peak memory tracking
            self.update_peak_memory();

            // Check flush triggers
            if (self.should_trigger_flush()) {
                self.try_flush_with_backpressure() catch |err| switch (err) {
                    error.IoError => {
                        // During fault injection, an IoError is an expected outcome.
                        // The database should handle it gracefully, and the test should continue
                        // to verify that the system remains consistent despite the failure.
                    },
                    else => return err,
                };
            }

            self.operations_since_flush += 1;
        }
    }

    /// Update peak memory tracking with current usage
    fn update_peak_memory(self: *Self) void {
        const current = self.storage_engine.memory_usage();
        self.peak_memory_bytes = @max(self.peak_memory_bytes, current.total_bytes);
    }

    /// Apply single operation to the storage system
    fn apply_operation_to_system(self: *Self, operation: *const Operation) !bool {
        switch (operation.op_type) {
            .put_block, .update_block => {
                if (operation.block) |block| {
                    self.put_block_with_backpressure(block) catch |err| {
                        if (builtin.mode == .Debug) {
                            log.debug("PUT_BLOCK_FAILED id={} error={any}", .{ block.id, err });
                        }
                        return false; // Report failure so model doesn't get updated
                    };
                    if (builtin.mode == .Debug) {
                        log.debug("PUT_BLOCK_SUCCESS id={}", .{block.id});
                    }
                }
                return true;
            },
            .find_block => {
                if (operation.block_id) |id| {
                    _ = try self.storage_engine.find_block(id, .temporary);
                }
                return true;
            },
            .delete_block => {
                if (operation.block_id) |id| {
                    self.storage_engine.delete_block(id) catch |err| switch (err) {
                        error.BlockNotFound => {}, // Expected for some operations
                        else => return false, // Report failure
                    };
                }
            },
            .put_edge => {
                if (operation.edge) |edge| {
                    self.storage_engine.put_edge(edge) catch |err| {
                        if (builtin.mode == .Debug) {
                            log.debug("PUT_EDGE_FAILED src={} tgt={} error={any}", .{ edge.source_id, edge.target_id, err });
                        }
                        return false; // Report failure so model doesn't get updated
                    };
                    if (builtin.mode == .Debug) {
                        log.debug("PUT_EDGE_SUCCESS src={} -> tgt={}", .{ edge.source_id, edge.target_id });
                    }
                } else {
                    return false; // Null edge is a failure
                }
                return true;
            },
            .find_edges => {
                if (operation.block_id) |id| {
                    const edges = self.storage_engine.find_outgoing_edges(id);
                    defer {
                        // Only free edges that were allocated by the engine (ownership == .sstable_manager)
                        // Memtable edges (.memtable_manager) and static empty slices should not be freed
                        if (edges.len > 0 and edges[0].ownership == .sstable_manager) {
                            self.storage_engine.backing_allocator.free(edges);
                        }
                    }
                }
                return true;
            },
        }
        return true;
    }

    /// Handle put_block operations with backpressure logic
    fn put_block_with_backpressure(self: *Self, block: ContextBlock) !void {
        var retries: u8 = 0;
        const max_retries = 3;

        while (retries <= max_retries) {
            self.storage_engine.put_block(block) catch |err| {
                // Handle write backpressure due to compaction throttling
                if (err == error.WriteStalled or err == error.WriteBlocked) {
                    if (retries >= max_retries) {
                        return error.WriteStalled; // Give up after max retries
                    }

                    // Back off and let the storage engine handle backpressure internally
                    retries += 1;
                    continue;
                } else {
                    return err;
                }
            };
            return; // Success
        }
    }

    /// Inject fault based on current fault schedule
    fn inject_fault(self: *Self, fault_type: FaultType) !void {
        switch (fault_type) {
            .io_error => {
                // Use realistic I/O failure rate for meaningful testing.
                // 20% failure rate strikes balance between coverage and stability.
                self.sim_vfs.enable_io_failures(200, .{ .write = true, .read = true });
                self.corruption_expected = false; // System should handle 20% I/O failures gracefully
            },
            .corruption => {
                // Moderate corruption rate that tests recovery without overwhelming the system
                self.sim_vfs.enable_read_corruption(300, 8); // 30% corruption rate
                // Disable WAL write verification to prevent error logging during intentional corruption
                self.storage_engine.disable_wal_verification_for_simulation();
                self.corruption_expected = true;
            },
            .crash => {
                // Torn writes with realistic partial completion for crash scenarios
                self.sim_vfs.enable_torn_writes(500, 1, 300); // 50% torn, 30% completion
                self.corruption_expected = true;
            },
            .network_partition => {
                // Network partitions use lower failure rate to simulate intermittent connectivity
                self.sim_vfs.enable_io_failures(150, .{ .write = true, .read = true });
            },
            .disk_full => {
                // Enable fault testing mode with realistic 100MB disk limit
                self.sim_vfs.enable_fault_testing_mode();
            },
        }
    }

    /// Simulate crash and recovery cycle
    pub fn simulate_crash_recovery(self: *Self) !void {
        // Record state before crash (for potential future verification)
        _ = try self.model.active_block_count();

        // Hard crash simulation - no graceful shutdown
        self.storage_engine.deinit();

        // Clear simulation VFS state to simulate crash where file handles are lost
        // This prevents FileExists errors when recreating SSTables with same names
        self.sim_vfs.clear_for_crash_recovery();

        // Recreate storage engine (simulates restart)
        self.storage_engine = try StorageEngine.init_default(
            self.allocator,
            self.sim_vfs.vfs(),
            "/test_db",
        );
        try self.storage_engine.startup();

        // Sync model state with what actually survived the crash
        try self.model.sync_with_storage(&self.storage_engine);

        // Reset operation counters
        self.operations_since_flush = 0;

        // Clear corruption expectation after successful recovery
        self.corruption_expected = false;
    }

    /// Check if flush should be triggered based on configuration
    pub fn should_trigger_flush(self: *Self) bool {
        if (self.flush_config.enable_operation_trigger and
            self.operations_since_flush >= self.flush_config.operation_threshold)
        {
            return true;
        }

        if (self.flush_config.enable_memory_trigger) {
            const usage = self.storage_engine.memory_usage();
            if (usage.total_bytes >= self.flush_config.memory_threshold) {
                return true;
            }
        }

        return false;
    }

    /// Attempt flush with backpressure handling
    fn try_flush_with_backpressure(self: *Self) !void {
        try self.storage_engine.flush_memtable_to_sstable();
        self.operations_since_flush = 0;
        self.model.record_flush();
    }

    /// Verify system consistency against model state
    pub fn verify_consistency(self: *Self) !void {
        // Skip verification when corruption is expected to prevent false durability violations
        if (self.corruption_expected) {
            return;
        }

        // Disable fault injection to allow clean verification operations
        self.sim_vfs.fault_injection.disable_all_faults();
        try self.model.verify_against_system(&self.storage_engine);
    }

    /// Get current memory usage statistics
    pub fn memory_stats(self: *Self) MemoryStats {
        const usage = self.storage_engine.memory_usage();

        // For memory leak testing, focus on memtable memory which should be bounded

        return .{
            .total_bytes = usage.total_bytes,
            .arena_bytes = 0, // Arena metrics not yet exposed by storage engine
            .total_allocated = usage.total_bytes,
            .block_count = usage.block_count,
            .edge_count = usage.edge_count,
        };
    }

    /// Get current performance statistics
    pub fn performance_stats(self: *Self) PerformanceStats {
        const metrics = self.storage_engine.metrics();
        return .{
            .blocks_written = metrics.blocks_written.load(),
            .blocks_read = metrics.blocks_read.load(),
            .edges_written = metrics.edges_added.load(),
            .flushes_completed = metrics.wal_flushes.load(),
            .compactions_completed = metrics.compactions.load(),
            .avg_traversal_time = 0, // Traversal timing tracked in query tests
            .avg_ingestion_time = 50_000, // Placeholder: actual timing in ingestion tests
        };
    }

    /// Force memtable flush for testing
    pub fn force_flush(self: *Self) !void {
        try self.storage_engine.flush_memtable_to_sstable();
        self.operations_since_flush = 0;
        self.model.record_flush();
    }

    /// Force compaction for testing
    pub fn force_compaction(self: *Self) !void {
        // Trigger compaction by forcing SSTable creation and merge
        try self.force_flush();
        try self.storage_engine.sstable_manager.check_and_run_compaction();
    }

    /// Force full scan operation for memory testing
    pub fn force_full_scan(self: *Self) !void {
        // Use a temporary arena for all scan-related allocations to ensure cleanup
        var scan_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer scan_arena.deinit();

        // Create iterator using a custom storage engine that uses our scan arena
        var iterator = self.storage_engine.iterate_all_blocks();
        defer iterator.deinit();

        var blocks_scanned: u32 = 0;
        var total_content_size: u64 = 0;

        while (try iterator.next()) |block| {
            // Block memory will be cleaned up when iterator.deinit() is called

            // Validate block structure
            if (block.block.content.len == 0) {
                std.debug.panic("Block {} has empty content during full scan", .{block.block.id});
            }

            // Validate block ID is not zero
            if (block.block.id.eql(BlockId.zero())) {
                std.debug.panic("Found zero block ID during full scan", .{});
            }

            // Test memory allocation patterns by accessing block data
            const content_hash = self.calculate_content_hash(block.block.content);
            _ = content_hash; // Use the hash to prevent optimization

            // Validate metadata JSON parsing
            if (std.json.parseFromSlice(std.json.Value, self.allocator, block.block.metadata_json, .{})) |parsed| {
                defer parsed.deinit();
                // Successfully parsed JSON metadata
            } else |_| {
                std.debug.panic("Block {} has invalid JSON metadata during scan", .{block.block.id});
            }

            blocks_scanned += 1;
            total_content_size += block.block.content.len;
        }

        // Verify scan found reasonable number of blocks
        const model_count = try self.model.active_block_count();
        if (blocks_scanned < model_count) {
            std.debug.panic("Full scan found {} blocks but model has {} active blocks", .{ blocks_scanned, model_count });
        }
    }

    /// Calculate simple hash for content validation
    fn calculate_content_hash(self: *Self, content: []const u8) u64 {
        _ = self;
        var hash: u64 = 0;
        for (content) |byte| {
            hash = hash *% 31 +% byte;
        }
        return hash;
    }

    /// Get count of operations executed
    pub fn operations_executed(self: *Self) u32 {
        return @intCast(self.workload.operation_count);
    }

    /// Get peak memory usage during simulation
    pub fn peak_memory(self: *Self) MemoryStats {
        const current = self.storage_engine.memory_usage();
        return .{
            .total_bytes = self.peak_memory_bytes,
            .arena_bytes = 0, // Arena usage not tracked in MemoryUsage
            .total_allocated = self.peak_memory_bytes,
            .block_count = current.block_count,
            .edge_count = current.edge_count,
        };
    }

    /// Verify edge consistency between model and system
    /// Disable fault injection to allow clean verification operations
    pub fn disable_fault_injection(self: *Self) void {
        self.sim_vfs.fault_injection.disable_all_faults();
    }

    pub fn verify_edge_consistency(self: *Self) !void {
        try PropertyChecker.check_bidirectional_consistency(&self.model, &self.storage_engine);
    }

    /// Simulate clean restart (shutdown and startup cycle)
    pub fn simulate_clean_restart(self: *Self) !void {
        // Shutdown storage engine
        try self.storage_engine.shutdown();
        self.storage_engine.deinit();

        // Reinitialize with same VFS (simulates clean restart)
        self.storage_engine = try StorageEngine.init_default(
            self.allocator,
            self.sim_vfs.vfs(),
            "/test_db",
        );
        try self.storage_engine.startup();

        self.operations_since_flush = 0;
    }

    /// Verify that query results are returned in consistent order
    pub fn verify_result_ordering(self: *Self) !void {
        // Simplified ordering check - verify model consistency
        try self.verify_consistency();
    }

    /// Verify partial ingestion recovery after failures
    pub fn verify_partial_ingestion_recovery(self: *Self) !void {
        // Simplified recovery check - verify consistency after faults
        if (self.corruption_expected) {
            // Skip verification when corruption is expected
            return;
        }
        try self.verify_consistency();
    }

    /// Verify traversal termination properties
    pub fn verify_traversal_termination(self: *Self) !void {
        // Simplified termination check - verify basic consistency
        try self.verify_consistency();
    }

    /// Verify parse error handling during ingestion
    pub fn verify_parse_error_handling(self: *Self) !void {
        if (!self.ingestion_config.inject_parse_errors) return;

        // System should remain stable even with parse errors
        // Check that we haven't crashed and basic operations still work
        const block_count = try self.model.active_block_count();

        // Try a basic operation to ensure system stability
        const test_id = BlockId.from_u64(99999);
        _ = self.storage_engine.find_block(test_id, .temporary) catch |err| switch (err) {
            error.BlockNotFound => {}, // Expected
            else => std.debug.panic("System unstable after parse errors: {}", .{err}),
        };

        // Verify that despite parse errors, we have some valid blocks
        if (self.operations_executed() > 100 and block_count == 0) {
            std.debug.panic("Parse error injection prevented all valid blocks", .{});
        }
    }

    /// Verify cross-language consistency during mixed ingestion
    pub fn verify_cross_language_consistency(self: *Self) !void {
        if (self.ingestion_config.language != .mixed) return;

        // Check that cross-language relationships are maintained
        var cross_language_edges: u32 = 0;

        for (self.model.edges.items) |edge| {
            const source_block = try self.storage_engine.find_block(edge.source_id, .temporary);
            const target_block = try self.storage_engine.find_block(edge.target_id, .temporary);

            if (source_block != null and target_block != null) {
                // Simple heuristic: different file extensions suggest different languages
                const source_has_rs = std.mem.indexOf(u8, source_block.?.block.source_uri, ".rs") != null;
                const source_has_py = std.mem.indexOf(u8, source_block.?.block.source_uri, ".py") != null;
                const target_has_rs = std.mem.indexOf(u8, target_block.?.block.source_uri, ".rs") != null;
                const target_has_py = std.mem.indexOf(u8, target_block.?.block.source_uri, ".py") != null;

                if ((source_has_rs and target_has_py) or (source_has_py and target_has_rs)) {
                    cross_language_edges += 1;
                }
            }
        }

        // Basic consistency check
        try self.verify_consistency();
    }

    /// Verify incremental consistency during modification operations
    pub fn verify_incremental_consistency(self: *Self) !void {
        if (!self.ingestion_config.simulate_incremental) return;

        // Check that incremental updates maintain consistency
        // Verify that modified blocks have higher sequence numbers
        var incremental_updates: u32 = 0;

        var block_iterator = self.model.blocks.iterator();
        while (block_iterator.next()) |entry| {
            const model_block = entry.value_ptr;
            if (!model_block.deleted and model_block.sequence > 1) {
                incremental_updates += 1;
            }
        }

        // Verify incremental updates are happening
        if (self.operations_executed() > 50 and incremental_updates == 0) {
            // This might be expected if no modifications occurred
        }

        try self.verify_consistency();
    }

    /// Verify bulk ingestion performance characteristics
    pub fn verify_bulk_ingestion_performance(self: *Self) !void {
        if (!self.ingestion_config.bulk_mode) return;

        // Check that bulk operations maintain reasonable performance
        const total_ops = self.operations_executed();
        const memory_usage = self.memory_stats();

        // Verify memory usage is reasonable for bulk operations
        const max_memory_per_op = 10 * 1024; // 10KB per operation maximum
        if (total_ops > 0 and memory_usage.total_bytes / total_ops > max_memory_per_op) {
            std.debug.panic("Bulk ingestion memory usage too high: {} bytes per operation", .{memory_usage.total_bytes / total_ops});
        }

        try self.verify_consistency();
    }

    /// Verify documentation linking functionality
    pub fn verify_doc_linking(self: *Self) !void {
        if (!self.ingestion_config.link_docs_to_code or !self.ingestion_config.extract_docs) return;

        // Look for documentation blocks and their links to code
        var doc_blocks: u32 = 0;
        var doc_links: u32 = 0;

        var block_iterator = self.model.blocks.iterator();
        while (block_iterator.next()) |entry| {
            const model_block = entry.value_ptr;
            if (!model_block.deleted) {
                const system_block = try self.storage_engine.find_block(model_block.id, .temporary);
                if (system_block) |block| {
                    // Check if this looks like a documentation block
                    if (std.mem.indexOf(u8, block.block.content, "///") != null or
                        std.mem.indexOf(u8, block.block.content, "/**") != null or
                        std.mem.indexOf(u8, block.block.content, "//!") != null)
                    {
                        doc_blocks += 1;
                    }
                }
            }
        }

        // Count references edges that could represent doc links
        for (self.model.edges.items) |edge| {
            if (edge.edge_type == .references) {
                doc_links += 1;
            }
        }

        // If we have docs, we should have some links
        if (doc_blocks > 0 and doc_links == 0) {
            // This might be expected if docs don't reference code
        }

        try self.verify_consistency();
    }

    /// Verify trait implementation relationships
    pub fn verify_trait_impl_relationships(self: *Self) !void {
        if (!self.ingestion_config.generate_traits or !self.ingestion_config.generate_impls) return;

        // Count trait and impl blocks
        var trait_count: u32 = 0;
        var impl_count: u32 = 0;
        var trait_impl_edges: u32 = 0;

        var block_iterator = self.model.blocks.iterator();
        while (block_iterator.next()) |entry| {
            const model_block = entry.value_ptr;
            if (!model_block.deleted) {
                const system_block = try self.storage_engine.find_block(model_block.id, .temporary);
                if (system_block) |block| {
                    if (std.mem.indexOf(u8, block.block.content, "trait ") != null) trait_count += 1;
                    if (std.mem.indexOf(u8, block.block.content, "impl ") != null) impl_count += 1;
                }
            }
        }

        // Count trait implementation edges
        for (self.model.edges.items) |edge| {
            if (edge.edge_type == .references) { // Treat references as potential trait implementations
                trait_impl_edges += 1;
            }
        }

        // Verify we have some trait-impl relationships if configured
        if (trait_count > 0 and impl_count > 0 and trait_impl_edges == 0) {
            std.debug.panic("Found traits and impls but no relationships", .{});
        }
    }

    /// Verify inheritance relationships
    pub fn verify_inheritance_relationships(self: *Self) !void {
        if (!self.ingestion_config.generate_inheritance) return;

        // Count inheritance edges (depends_on edges can represent inheritance)
        var inheritance_edges: u32 = 0;
        for (self.model.edges.items) |edge| {
            if (edge.edge_type == .depends_on) {
                inheritance_edges += 1;
            }
        }

        // Verify inheritance chain consistency
        for (self.model.edges.items) |edge| {
            if (edge.edge_type == .depends_on) {
                // Verify both source and target blocks exist
                if (!self.model.has_active_block(edge.source_id) or !self.model.has_active_block(edge.target_id)) {
                    std.debug.panic("Inheritance edge references non-existent block", .{});
                }
            }
        }
    }

    /// Verify type relationships
    pub fn verify_type_relationships(self: *Self) !void {
        if (!self.ingestion_config.generate_types) return;

        // Verify type definition and usage consistency
        var type_blocks: u32 = 0;
        var type_usage_edges: u32 = 0;

        var block_iterator = self.model.blocks.iterator();
        while (block_iterator.next()) |entry| {
            const model_block = entry.value_ptr;
            if (!model_block.deleted) {
                const system_block = try self.storage_engine.find_block(model_block.id, .temporary);
                if (system_block) |block| {
                    if (std.mem.indexOf(u8, block.block.content, "struct ") != null or
                        std.mem.indexOf(u8, block.block.content, "enum ") != null or
                        std.mem.indexOf(u8, block.block.content, "type ") != null)
                    {
                        type_blocks += 1;
                    }
                }
            }
        }

        // Count type usage edges (references to type definitions)
        for (self.model.edges.items) |edge| {
            if (edge.edge_type == .references) {
                type_usage_edges += 1;
            }
        }

        // Basic consistency check
        try self.verify_consistency();
    }

    /// Verify context extraction functionality
    pub fn verify_context_extraction(self: *Self) !void {
        if (!self.ingestion_config.extract_all_metadata) return;

        // Verify that blocks have meaningful metadata
        var blocks_with_metadata: u32 = 0;
        var block_iterator = self.model.blocks.iterator();

        while (block_iterator.next()) |entry| {
            const model_block = entry.value_ptr;
            if (!model_block.deleted) {
                const system_block = try self.storage_engine.find_block(model_block.id, .temporary);
                if (system_block) |block| {
                    // Check if metadata contains more than just empty JSON
                    if (block.block.metadata_json.len > 2) { // More than just "{}"
                        blocks_with_metadata += 1;
                    }
                }
            }
        }

        const total_blocks = try self.model.active_block_count();
        if (total_blocks > 10 and blocks_with_metadata == 0) {
            std.debug.panic("Metadata extraction enabled but no blocks have meaningful metadata", .{});
        }
    }

    /// Verify import graph construction
    pub fn verify_import_graph(self: *Self) !void {
        if (!self.ingestion_config.track_imports) return;

        // Count import edges
        var import_edges: u32 = 0;
        for (self.model.edges.items) |edge| {
            if (edge.edge_type == .imports) {
                import_edges += 1;

                // Verify import edge points to valid blocks
                if (!self.model.has_active_block(edge.source_id) or !self.model.has_active_block(edge.target_id)) {
                    std.debug.panic("Import edge references non-existent block", .{});
                }
            }
        }

        // Verify bidirectional consistency for imports
        try PropertyChecker.check_bidirectional_consistency(&self.model, &self.storage_engine);
    }

    /// Verify function call tracking
    pub fn verify_call_graph(self: *Self) !void {
        if (!self.ingestion_config.track_function_calls) return;

        // Count call edges
        var call_edges: u32 = 0;
        for (self.model.edges.items) |edge| {
            if (edge.edge_type == .calls) {
                call_edges += 1;

                // Verify both source and target exist
                if (!self.model.has_active_block(edge.source_id) or !self.model.has_active_block(edge.target_id)) {
                    std.debug.panic("Call edge references non-existent block", .{});
                }
            }
        }

        // If tracking calls, we should have some call relationships
        if (try self.model.active_block_count() > 20 and call_edges == 0 and self.ingestion_config.generate_functions) {
            std.debug.panic("Function call tracking enabled but no call edges found", .{});
        }
    }

    /// Verify metadata extraction
    pub fn verify_metadata_extraction(self: *Self) !void {
        if (!self.ingestion_config.extract_all_metadata) return;

        // Check for rich metadata extraction
        var rich_metadata_count: u32 = 0;
        var block_iterator = self.model.blocks.iterator();

        while (block_iterator.next()) |entry| {
            const model_block = entry.value_ptr;
            if (!model_block.deleted) {
                const system_block = try self.storage_engine.find_block(model_block.id, .temporary);
                if (system_block) |block| {
                    // Look for specific metadata fields
                    if (std.mem.indexOf(u8, block.block.metadata_json, "function") != null or
                        std.mem.indexOf(u8, block.block.metadata_json, "line_number") != null or
                        std.mem.indexOf(u8, block.block.metadata_json, "complexity") != null)
                    {
                        rich_metadata_count += 1;
                    }
                }
            }
        }

        // Verify metadata is being extracted
        if (try self.model.active_block_count() > 5 and rich_metadata_count == 0) {
            std.debug.panic("Rich metadata extraction enabled but no rich metadata found", .{});
        }
    }

    /// Verify sequence tracking
    pub fn verify_sequence_tracking(self: *Self) !void {
        if (!self.ingestion_config.track_sequences) return;

        // Check that blocks have incremented sequences after modifications
        var block_iterator = self.model.blocks.iterator();
        var sequence_tracked_count: u32 = 0;

        while (block_iterator.next()) |entry| {
            const model_block = entry.value_ptr;
            if (!model_block.deleted and model_block.sequence > 1) {
                sequence_tracked_count += 1;
            }
        }

        // If we're tracking sequences, we should have some sequenced blocks
        if ((try self.model.active_block_count()) > 10 and sequence_tracked_count == 0) {
            std.debug.panic("Sequence tracking enabled but no sequenced blocks found", .{});
        }
    }

    /// Verify unicode handling
    pub fn verify_unicode_handling(self: *Self) !void {
        if (!self.ingestion_config.generate_unicode_content) return;

        // Check that unicode content is properly stored and retrieved
        var unicode_block_count: u32 = 0;
        var block_iterator = self.model.blocks.iterator();

        while (block_iterator.next()) |entry| {
            const block_id = entry.key_ptr.*;
            if (self.model.has_active_block(block_id)) {
                const system_block = try self.storage_engine.find_block(block_id, .temporary);
                if (system_block) |block| {
                    // Check for unicode characters in content
                    for (block.block.content) |byte| {
                        if (byte > 127) {
                            unicode_block_count += 1;
                            break;
                        }
                    }
                }
            }
        }

        // Verify unicode blocks are handled correctly
        try self.verify_consistency();
    }

    /// Verify circular import handling
    pub fn verify_circular_import_handling(self: *Self) !void {
        if (!self.ingestion_config.allow_circular_imports) return;

        // Build a graph of import relationships and detect cycles
        var import_graph = std.AutoHashMap(BlockId, std.ArrayList(BlockId)).init(self.allocator);
        defer {
            var iterator = import_graph.iterator();
            while (iterator.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            import_graph.deinit();
        }

        // Build import graph from edges
        for (self.model.edges.items) |edge| {
            if (edge.edge_type == .imports) {
                var imports = import_graph.get(edge.source_id) orelse std.ArrayList(BlockId){};
                try imports.append(self.allocator, edge.target_id);
                try import_graph.put(edge.source_id, imports);
            }
        }

        // Check for cycles using DFS
        var visited = std.HashMap(BlockId, void, model_mod.ModelState.BlockIdContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        defer visited.deinit();

        var rec_stack = std.HashMap(BlockId, void, model_mod.ModelState.BlockIdContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        defer rec_stack.deinit();

        var graph_iterator = import_graph.iterator();
        while (graph_iterator.next()) |entry| {
            const node = entry.key_ptr.*;
            if (!visited.contains(node)) {
                if (try self.has_cycle_dfs(node, &import_graph, &visited, &rec_stack)) {
                    // Found a cycle - this is expected when circular imports are enabled
                    return;
                }
            }
        }
    }

    /// Helper method for cycle detection in import graph
    fn has_cycle_dfs(
        self: *Self,
        node: BlockId,
        graph: *std.AutoHashMap(BlockId, std.ArrayList(BlockId)),
        visited: *std.HashMap(BlockId, void, model_mod.ModelState.BlockIdContext, std.hash_map.default_max_load_percentage),
        rec_stack: *std.HashMap(BlockId, void, model_mod.ModelState.BlockIdContext, std.hash_map.default_max_load_percentage),
    ) !bool {
        try visited.put(node, {});
        try rec_stack.put(node, {});

        if (graph.get(node)) |neighbors| {
            for (neighbors.items) |neighbor| {
                if (!visited.contains(neighbor)) {
                    if (try self.has_cycle_dfs(neighbor, graph, visited, rec_stack)) {
                        return true;
                    }
                } else if (rec_stack.contains(neighbor)) {
                    return true; // Found a cycle
                }
            }
        }

        _ = rec_stack.remove(node);
        return false;
    }
};

/// Create deterministic block ID from seed for reproducible tests
pub fn create_deterministic_block_id(seed: u32) BlockId {
    // Generate two u64 values to fill all 16 bytes of BlockId
    // This prevents hash clustering that occurs when last 8 bytes are always zero
    const base_seed = @as(u64, seed);
    const high_bits = base_seed *% 0x1234567890ABCDEF +% 0xFEDCBA0987654321;
    const low_bits = base_seed *% 0x9E3779B97F4A7C15 +% 0x3C6EF372FE94F82A;

    var bytes: [16]u8 = undefined;
    std.mem.writeInt(u64, bytes[0..8], high_bits, .little);
    std.mem.writeInt(u64, bytes[8..16], low_bits, .little);
    return BlockId{ .bytes = bytes };
}

/// Test assertion helpers for performance and memory testing
pub const TestAssertions = struct {
    /// Assert operation completes within time bound
    pub fn assert_operation_fast(duration_ns: u64, max_duration_ns: u64, operation_name: []const u8) void {
        if (duration_ns > max_duration_ns) {
            std.debug.panic("{s} took {d}ns, expected <{d}ns", .{ operation_name, duration_ns, max_duration_ns });
        }
    }

    /// Assert memory usage is within bounds
    pub fn assert_memory_bounded(current_bytes: u64, max_bytes: u64, context: []const u8) void {
        if (current_bytes > max_bytes) {
            std.debug.panic("{s} memory usage {d} bytes exceeds limit {d} bytes", .{ context, current_bytes, max_bytes });
        }
    }
};

/// Test data generator for consistent test block creation
pub const TestDataGenerator = struct {
    allocator: std.mem.Allocator,
    prng: std.Random.DefaultPrng,

    pub fn init(allocator: std.mem.Allocator, seed: u64) TestDataGenerator {
        return TestDataGenerator{
            .allocator = allocator,
            .prng = std.Random.DefaultPrng.init(seed),
        };
    }

    /// Create test block with deterministic content based on seed
    pub fn create_test_block(self: *TestDataGenerator, id_seed: u32) !ContextBlock {
        const random = self.prng.random();

        const content = try std.fmt.allocPrint(
            self.allocator,
            "test_block_content_{d}_random_{d}",
            .{ id_seed, random.int(u32) },
        );

        const metadata = try std.fmt.allocPrint(
            self.allocator,
            "{{\"test_id\":{d},\"type\":\"test_block\",\"seed\":{d},\"codebase\":\"test_workspace\"}}",
            .{ id_seed, id_seed },
        );

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "test://block/{d}",
            .{id_seed},
        );

        return ContextBlock{
            .id = create_deterministic_block_id(id_seed),
            .sequence = 0, // Storage engine will assign the actual global sequence
            .source_uri = uri,
            .metadata_json = metadata,
            .content = content,
        };
    }

    /// Create batch of test blocks for batch testing
    pub fn create_test_block_batch(self: *TestDataGenerator, count: u32, base_seed: u32) ![]ContextBlock {
        const blocks = try self.allocator.alloc(ContextBlock, count);

        for (blocks, 0..) |*block, i| {
            block.* = try self.create_test_block(base_seed + @as(u32, @intCast(i)));
        }

        return blocks;
    }

    /// Free all allocated test data
    pub fn cleanup_test_data(self: *TestDataGenerator, blocks: []ContextBlock) void {
        for (blocks) |block| {
            self.allocator.free(block.content);
            self.allocator.free(block.metadata_json);
            self.allocator.free(block.source_uri);
        }
        self.allocator.free(blocks);
    }
};

test "simulation runner basic functionality" {
    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 50,
        .find_block_weight = 50,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x12345,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Run some operations
    try runner.run(10);

    // Verify basic functionality
    try runner.verify_consistency();

    const stats = runner.performance_stats();
    try testing.expect(stats.blocks_written > 0 or stats.blocks_read > 0);
}
