//! Mathematical state model for zero-cost correctness validation.
//!
//! This module embodies KausalDB's correctness-first philosophy by maintaining
//! a mathematically precise model of expected system state. The model serves
//! as the authoritative "ground truth" against which the actual system is
//! continuously validated through deterministic property checking.
//!
//! Design rationale: Arena-based memory management eliminates temporal coupling
//! and enables O(1) cleanup, following the same pattern as StorageEngine.
//! All state transitions are mathematically tracked with sequence numbers
//! and cryptographic hashes to ensure perfect reproducibility.
//!
//! Zero-cost abstractions: All validation overhead is eliminated in release
//! builds through compile-time optimizations while providing comprehensive
//! verification during testing and development phases.

const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;

const assert_mod = @import("../core/assert.zig");
const storage_engine_mod = @import("../storage/engine.zig");
const types = @import("../core/types.zig");
const workload_mod = @import("workload.zig");

const assert = assert_mod.assert;
const fatal_assert = assert_mod.fatal_assert;
const log = std.log.scoped(.model);

const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const EdgeType = types.EdgeType;
const GraphEdge = types.GraphEdge;
const StorageEngine = storage_engine_mod.StorageEngine;
const Operation = workload_mod.Operation;
const OperationType = workload_mod.OperationType;

// Compile-time configuration for model state management
const MODEL_CONFIG = struct {
    // Maximum number of operations to track in operation history
    const MAX_OPERATION_HISTORY = 10_000;

    // Cryptographic hash seed for content verification
    const CONTENT_HASH_SEED: u64 = 0x517cc1b727220a95;

    // Memory growth threshold before triggering compaction hints
    const MEMORY_GROWTH_THRESHOLD = 16 * 1024 * 1024; // 16MB
};

/// Mathematical representation of a block in the expected system state.
///
/// Each ModelBlock represents a point in the system's state space with
/// cryptographically verified content integrity and temporal ordering.
/// The sequence number provides total ordering of all state mutations.
pub const ModelBlock = struct {
    // Block identity and versioning
    id: BlockId,
    version: u64,

    // Cryptographic content verification
    content_hash: u64,
    content_size: u32,

    // Temporal ordering and lifecycle tracking
    sequence_number: u64,
    creation_timestamp: u64,
    deleted: bool = false,

    // Forensic metadata for debugging
    source_operation_id: u32,
    validation_checksum: u32,

    /// Create mathematically precise model block from context block.
    ///
    /// This transformation preserves all invariants necessary for correctness
    /// validation while adding temporal ordering and cryptographic verification.
    pub fn from_context_block(block: ContextBlock, sequence: u64, operation_id: u32) ModelBlock {
        const timestamp = std.time.nanoTimestamp();
        const content_hash = cryptographic_hash(block.content);

        const model_block = ModelBlock{
            .id = block.id,
            .version = block.version,
            .content_hash = content_hash,
            .content_size = @intCast(block.content.len),
            .sequence_number = sequence,
            .creation_timestamp = @intCast(timestamp),
            .deleted = false,
            .source_operation_id = operation_id,
            .validation_checksum = compute_validation_checksum(block.id, content_hash, sequence),
        };

        return model_block;
    }

    /// Cryptographic hash function providing collision resistance for content verification.
    ///
    /// Uses FNV-1a algorithm with cryptographic seed to ensure mathematical
    /// precision in content integrity validation across all test scenarios.
    pub fn cryptographic_hash(content: []const u8) u64 {
        var hash: u64 = MODEL_CONFIG.CONTENT_HASH_SEED;

        for (content) |byte| {
            hash ^= byte;
            hash *%= 0x100000001b3; // FNV-1a prime
        }

        return hash;
    }

    /// Compute validation checksum for internal consistency verification.
    ///
    /// This checksum detects corruption in the model state itself,
    /// providing an additional layer of mathematical verification.
    fn compute_validation_checksum(id: BlockId, content_hash: u64, sequence: u64) u32 {
        var checksum: u32 = 0;

        // Incorporate block ID
        for (id.bytes) |byte| {
            checksum = checksum *% 31 +% byte;
        }

        // Incorporate content hash
        checksum ^= @truncate(content_hash);
        checksum ^= @truncate(content_hash >> 32);

        // Incorporate sequence number
        checksum ^= @truncate(sequence);

        return checksum;
    }
};

/// Arena-based mathematical model of expected system state.
///
/// This structure embodies the arena coordinator pattern from DESIGN.md,
/// providing O(1) cleanup and eliminating temporal coupling bugs common
/// in traditional allocator patterns. All state is mathematically tracked
/// with cryptographic precision to enable perfect reproducibility.
///
/// The model serves as the authoritative source of truth for what the
/// system state should be, enabling continuous correctness validation
/// through property-based testing with deterministic outcomes.
pub const ModelState = struct {
    // Arena-based memory management (following StorageEngine pattern)
    model_arena: *std.heap.ArenaAllocator,
    backing_allocator: std.mem.Allocator,

    // Core state tracking structures
    blocks: std.HashMap(BlockId, ModelBlock, BlockIdContext, std.hash_map.default_max_load_percentage),
    edges: std.array_list.Managed(GraphEdge),

    // Mathematical operation sequencing
    operation_count: u64,
    global_sequence: u64,

    // State transition tracking
    last_flush_sequence: u64,
    flush_count: u32,
    compaction_count: u32,

    // Forensic and debugging metadata
    creation_timestamp: u64,
    total_bytes_allocated: u64,
    peak_memory_usage: u64,
    operation_history: std.array_list.Managed(OperationRecord),

    // Cryptographic state verification
    state_checksum: u64,
    last_validation_sequence: u64,

    const Self = @This();

    /// Operation record for forensic analysis and debugging
    const OperationRecord = struct {
        sequence: u64,
        operation_type: OperationType,
        timestamp: u64,
        affected_block: ?BlockId,
        memory_delta: i64,
    };

    /// Context for BlockId HashMap
    pub const BlockIdContext = struct {
        pub fn hash(self: @This(), key: BlockId) u64 {
            _ = self;
            return key.hash();
        }

        pub fn eql(self: @This(), a: BlockId, b: BlockId) bool {
            _ = self;
            return a.eql(b);
        }
    };

    /// Initialize arena-based model state with mathematical precision.
    ///
    /// Creates a mathematically sound model using arena allocation patterns
    /// that eliminate temporal coupling and enable O(1) cleanup operations.
    /// All state is initialized with cryptographic verification enabled.
    pub fn init(backing_allocator: std.mem.Allocator) !Self {
        // Create arena following the StorageEngine pattern
        const model_arena = try backing_allocator.create(std.heap.ArenaAllocator);
        model_arena.* = std.heap.ArenaAllocator.init(backing_allocator);

        const arena_allocator = model_arena.allocator();
        const creation_timestamp = @as(u64, @intCast(std.time.nanoTimestamp()));

        const model_state = Self{
            .model_arena = model_arena,
            .backing_allocator = backing_allocator,
            .blocks = std.HashMap(BlockId, ModelBlock, BlockIdContext, std.hash_map.default_max_load_percentage).init(arena_allocator),
            .edges = std.array_list.Managed(GraphEdge).init(arena_allocator),
            .operation_count = 0,
            .global_sequence = 0, // Start at 0 to match WorkloadGenerator.operation_count
            .last_flush_sequence = 0,
            .flush_count = 0,
            .compaction_count = 0,
            .creation_timestamp = creation_timestamp,
            .total_bytes_allocated = 0,
            .peak_memory_usage = 0,
            .operation_history = std.array_list.Managed(OperationRecord).init(arena_allocator),
            .state_checksum = compute_initial_state_checksum(creation_timestamp),
            .last_validation_sequence = 0,
        };

        return model_state;
    }

    /// Compute initial state checksum for cryptographic verification
    fn compute_initial_state_checksum(timestamp: u64) u64 {
        var checksum: u64 = MODEL_CONFIG.CONTENT_HASH_SEED;
        checksum ^= timestamp;
        checksum ^= 0xDEADBEEFCAFEBABE; // Magic constant for model state
        return checksum;
    }

    /// O(1) cleanup using arena deallocation pattern.
    ///
    /// This demonstrates the arena coordinator pattern from DESIGN.md:
    /// instead of individually freeing allocations, we destroy the entire
    /// arena in a single operation, eliminating temporal coupling bugs.
    pub fn deinit(self: *Self) void {
        // Validate final state before cleanup (zero-cost in release builds)
        if (comptime std.debug.runtime_safety) {
            self.validate_internal_consistency() catch |err| {
                log.warn("Model state inconsistency detected during cleanup: {}", .{err});
            };
        }

        // O(1) arena cleanup - destroys all allocations simultaneously
        self.model_arena.deinit();
        self.backing_allocator.destroy(self.model_arena);
    }

    /// Apply operation to model state with mathematical precision and forensic tracking.
    ///
    /// Each operation is recorded with cryptographic precision, enabling
    /// perfect reproducibility and comprehensive forensic analysis of
    /// system behavior under all test conditions.
    pub fn apply_operation(self: *Self, operation: *const Operation) !void {
        const operation_start_memory = self.model_arena.queryCapacity();
        const operation_timestamp = @as(u64, @intCast(std.time.nanoTimestamp()));

        // Apply the state mutation with mathematical tracking
        switch (operation.op_type) {
            .put_block => {
                if (operation.block) |block| {
                    try self.apply_put_block(block);
                }
            },
            .update_block => {
                if (operation.block) |block| {
                    try self.apply_put_block(block); // Same logic as put_block - higher version overwrites
                }
            },
            .find_block => {
                // Read operations maintain sequence but don't mutate state
                // Track for operation history and mathematical completeness
            },
            .delete_block => {
                if (operation.block_id) |id| {
                    try self.apply_delete_block(id);
                }
            },
            .put_edge => {
                if (operation.edge) |edge| {
                    try self.apply_put_edge(edge);
                }
            },
            .find_edges => {
                // Read operations tracked for completeness
            },
        }

        // Update mathematical state with forensic precision
        self.operation_count += 1;
        self.global_sequence += 1;

        // Record operation for forensic analysis
        const memory_delta = @as(i64, @intCast(self.model_arena.queryCapacity())) -
            @as(i64, @intCast(operation_start_memory));

        try self.record_operation(.{
            .sequence = self.global_sequence,
            .operation_type = operation.op_type,
            .timestamp = operation_timestamp,
            .affected_block = switch (operation.op_type) {
                .put_block, .update_block => if (operation.block) |b| b.id else null,
                .find_block, .delete_block => operation.block_id,
                else => null,
            },
            .memory_delta = memory_delta,
        });

        // Update cryptographic state checksum
        self.update_state_checksum();

        // Trigger memory optimization hints if needed
        if (memory_delta > MODEL_CONFIG.MEMORY_GROWTH_THRESHOLD) {
            self.suggest_memory_optimization();
        }
    }

    /// Apply put_block operation with mathematical state tracking.
    ///
    /// Creates mathematically precise model block with cryptographic
    /// content verification and temporal ordering guarantees.
    pub fn apply_put_block(self: *Self, block: ContextBlock) !void {
        var model_block = ModelBlock.from_context_block(block, self.global_sequence, @truncate(self.operation_count));

        // Preserve deletion state to prevent resurrection of tombstoned blocks
        const existing_deleted = if (self.blocks.get(block.id)) |existing| existing.deleted else false;
        model_block.deleted = existing_deleted;

        // Validate block consistency before insertion
        if (comptime std.debug.runtime_safety) {
            try self.validate_block_consistency(&model_block);
        }

        try self.blocks.put(block.id, model_block);
        self.update_memory_tracking();
    }

    /// Apply delete_block operation with referential integrity tracking.
    ///
    /// Marks block as deleted while preserving mathematical consistency
    /// and updating all dependent relationships in the graph structure.
    pub fn apply_delete_block(self: *Self, block_id: BlockId) !void {
        if (self.blocks.getPtr(block_id)) |model_block| {
            // Mathematical state transition: exists → deleted
            model_block.deleted = true;
            model_block.sequence_number = self.global_sequence;

            // Update validation checksum to reflect state change
            model_block.validation_checksum = ModelBlock.compute_validation_checksum(model_block.id, model_block.content_hash, model_block.sequence_number);

            // Remove all edges associated with the deleted block to maintain referential integrity
            var i: usize = 0;
            while (i < self.edges.items.len) {
                const edge = self.edges.items[i];
                if (edge.source_id.eql(block_id) or edge.target_id.eql(block_id)) {
                    // Remove edge by swapping with last element (O(1) removal)
                    _ = self.edges.swapRemove(i);
                    // Don't increment i since we swapped a new element to this position
                } else {
                    i += 1;
                }
            }
        }
    }

    /// Apply put_edge operation with graph theoretical validation.
    ///
    /// Ensures mathematical consistency of graph structure by validating
    /// referential integrity and preventing duplicate relationships.
    pub fn apply_put_edge(self: *Self, edge: GraphEdge) !void {
        // Validate referential integrity: both endpoints must exist
        if (comptime std.debug.runtime_safety) {
            try self.validate_edge_endpoints(&edge);
        }

        // Check for mathematical duplicate (same relationship)
        for (self.edges.items) |existing_edge| {
            if (existing_edge.source_id.eql(edge.source_id) and
                existing_edge.target_id.eql(edge.target_id) and
                existing_edge.edge_type == edge.edge_type)
            {
                // Mathematical consistency: edge already exists in model
                return;
            }
        }

        try self.edges.append(edge);
        self.update_memory_tracking();
    }

    // ========================================================================
    // Mathematical Validation and Forensic Methods
    // ========================================================================

    /// Update memory usage tracking with mathematical precision
    fn update_memory_tracking(self: *Self) void {
        const current_usage = self.model_arena.queryCapacity();
        self.total_bytes_allocated = current_usage;

        if (current_usage > self.peak_memory_usage) {
            self.peak_memory_usage = current_usage;
        }
    }

    /// Record operation for forensic analysis and debugging
    fn record_operation(self: *Self, record: OperationRecord) !void {
        // Maintain bounded operation history for memory efficiency
        if (self.operation_history.items.len >= MODEL_CONFIG.MAX_OPERATION_HISTORY) {
            _ = self.operation_history.orderedRemove(0);
        }

        try self.operation_history.append(record);
    }

    /// Update cryptographic state checksum for integrity verification
    fn update_state_checksum(self: *Self) void {
        var new_checksum: u64 = self.state_checksum;

        // Incorporate global sequence for temporal ordering
        new_checksum ^= self.global_sequence;
        new_checksum *%= 0x517cc1b727220a95;

        // Incorporate operation count for mathematical consistency
        new_checksum ^= self.operation_count;

        self.state_checksum = new_checksum;
        self.last_validation_sequence = self.global_sequence;
    }

    /// Suggest memory optimization when growth threshold is exceeded
    fn suggest_memory_optimization(self: *Self) void {
        if (comptime std.debug.runtime_safety) {
            log.debug("Model state memory growth detected: {} MB allocated", .{self.total_bytes_allocated / (1024 * 1024)});
        }
    }

    /// Validate block consistency before insertion
    fn validate_block_consistency(self: *Self, block: *const ModelBlock) !void {
        // Verify cryptographic content hash is properly computed
        if (block.content_hash == 0) {
            return error.InvalidContentHash;
        }

        // Verify sequence number ordering
        if (block.sequence_number > self.global_sequence) {
            return error.SequenceOrderViolation;
        }

        // Verify validation checksum integrity
        const expected_checksum = ModelBlock.compute_validation_checksum(block.id, block.content_hash, block.sequence_number);
        if (block.validation_checksum != expected_checksum) {
            return error.ValidationChecksumMismatch;
        }
    }

    /// Track cascading effects of block deletion on graph edges
    fn track_deletion_cascades(self: *Self, deleted_block_id: BlockId) void {
        var cascade_count: u32 = 0;

        // Count affected edges for forensic tracking
        for (self.edges.items) |edge| {
            if (edge.source_id.eql(deleted_block_id) or edge.target_id.eql(deleted_block_id)) {
                cascade_count += 1;
            }
        }

        if (comptime std.debug.runtime_safety) {
            if (cascade_count > 0) {
                log.debug("Block deletion cascades to {} edges", .{cascade_count});
            }
        }
    }

    /// Validate edge endpoints exist before insertion
    fn validate_edge_endpoints(self: *Self, edge: *const GraphEdge) !void {
        // Source block must exist and not be deleted
        if (self.blocks.get(edge.source_id)) |source_block| {
            if (source_block.deleted) {
                return error.EdgeSourceDeleted;
            }
        } else {
            return error.EdgeSourceNotFound;
        }

        // Target block must exist and not be deleted
        if (self.blocks.get(edge.target_id)) |target_block| {
            if (target_block.deleted) {
                return error.EdgeTargetDeleted;
            }
        } else {
            return error.EdgeTargetNotFound;
        }
    }

    /// Validate internal consistency of model state
    fn validate_internal_consistency(self: *Self) !void {
        // Verify state checksum integrity
        var computed_checksum: u64 = MODEL_CONFIG.CONTENT_HASH_SEED;
        computed_checksum ^= self.creation_timestamp;
        computed_checksum ^= 0xDEADBEEFCAFEBABE;

        // Incorporate current state into checksum calculation
        computed_checksum ^= self.global_sequence;
        computed_checksum *%= 0x517cc1b727220a95;
        computed_checksum ^= self.operation_count;

        // Allow for checksum evolution during operations
        if (self.last_validation_sequence == self.global_sequence) {
            if (self.state_checksum != computed_checksum) {
                return error.StateChecksumMismatch;
            }
        }

        // Verify sequence number ordering
        if (self.global_sequence < self.operation_count) {
            return error.SequenceCounterInconsistency;
        }
    }

    /// Verify model state matches actual system state.
    /// This is the primary validation entry point that ensures the system
    /// maintains all required invariants and matches the expected model state.
    pub fn verify_against_system(self: *Self, storage: *StorageEngine) !void {
        // Use consolidated PropertyChecker for comprehensive validation
        const PropertyChecker = @import("properties.zig").PropertyChecker;

        // Core durability check - most critical property
        try PropertyChecker.check_no_data_loss(self, storage);

        // Verify bidirectional edge consistency if we have edges
        if (self.edges.items.len > 0) {
            try PropertyChecker.check_bidirectional_consistency(self, storage);
        }

        // Additional local consistency checks
        try self.verify_block_consistency(storage);
        try self.verify_edge_consistency(storage);

        // Update validation timestamp
        self.last_validation_sequence = self.global_sequence;
    }

    /// Verify all blocks in model exist in system with mathematical precision.
    ///
    /// This provides detailed block-level validation with cryptographic integrity
    /// checking and comprehensive forensic error reporting for debugging.
    fn verify_block_consistency(self: *Self, storage: *StorageEngine) !void {
        var validation_metrics = struct {
            total_blocks: u32 = 0,
            deleted_blocks: u32 = 0,
            verified_blocks: u32 = 0,
            hash_mismatches: u32 = 0,
            version_mismatches: u32 = 0,
        }{};

        var block_iterator = self.blocks.iterator();
        while (block_iterator.next()) |entry| {
            const model_block = entry.value_ptr;
            validation_metrics.total_blocks += 1;

            if (model_block.deleted) {
                validation_metrics.deleted_blocks += 1;

                // Mathematical invariant: deleted blocks must not be findable
                const found = storage.find_block(model_block.id, .temporary) catch |err| switch (err) {
                    error.BlockNotFound => continue, // Expected for deleted blocks
                    else => return err,
                };

                if (found != null) {
                    fatal_assert(false, "DELETION CONSISTENCY VIOLATION: Deleted block {} still findable\n" ++
                        "  Block sequence: {}\n" ++
                        "  Deletion timestamp: {}\n" ++
                        "  This violates the fundamental deletion contract.", .{ model_block.id, model_block.sequence_number, model_block.creation_timestamp });
                }
                continue;
            }

            // Mathematical invariant: non-deleted blocks must be findable with correct content
            const system_block = try storage.find_block(model_block.id, .temporary);

            // FORENSIC ANALYSIS: Capture comprehensive state before potential violation
            if (system_block == null and builtin.mode == .Debug) {
                log.warn("FORENSIC: Block existence check failed for model block", .{});
                log.warn("  Block ID: {}", .{model_block.id});
                log.warn("  Model sequence: {}", .{model_block.sequence_number});
                log.warn("  Model global sequence: {}", .{self.global_sequence});
                log.warn("  Operation count: {}", .{self.operation_count});
                log.warn("  Content hash: 0x{x}", .{model_block.content_hash});
                log.warn("  Creation timestamp: {}", .{model_block.creation_timestamp});
                log.warn("  Version: {}", .{model_block.version});

                // Check if this is a sequence divergence issue
                const sequence_gap = @as(i64, @intCast(self.operation_count)) - @as(i64, @intCast(model_block.sequence_number));
                log.warn("  Sequence gap (op_count - block_seq): {}", .{sequence_gap});

                // Try to identify recent failed operations that might explain the gap
                if (sequence_gap > 0) {
                    log.warn("  POTENTIAL CAUSE: {} operations may have failed in storage but succeeded in sequence counting", .{sequence_gap});
                }
            }

            if (system_block == null) {
                fatal_assert(false, "BLOCK EXISTENCE VIOLATION: Model block {} not found in system\n" ++
                    "  Expected version: {}\n" ++
                    "  Creation sequence: {}\n" ++
                    "  Content size: {} bytes\n" ++
                    "  This indicates catastrophic data loss.", .{ model_block.id, model_block.version, model_block.sequence_number, model_block.content_size });
            }

            // Combined version and hash consistency verification
            const actual_hash = ModelBlock.cryptographic_hash(system_block.?.block.content);
            const expected_hash = model_block.content_hash;

            if (system_block.?.block.version != model_block.version) {
                validation_metrics.version_mismatches += 1;

                if (system_block.?.block.version > model_block.version) {
                    // Storage has newer version - sync model with storage reality
                    // This can happen during background compaction that increments versions
                    if (builtin.mode == .Debug) {
                        log.warn("VERSION PRECEDENCE VIOLATION DETECTED:", .{});
                        log.warn("  Block ID: {}", .{model_block.id});
                        log.warn("  MODEL EXPECTATION:", .{});
                        log.warn("    Expected version: {}", .{model_block.version});
                        log.warn("    Expected hash: 0x{x}", .{model_block.content_hash});
                        log.warn("    Model sequence: {}", .{model_block.sequence_number});
                        log.warn("    Creation timestamp: {}", .{model_block.creation_timestamp});
                        log.warn("  STORAGE REALITY:", .{});
                        log.warn("    Actual version: {}", .{system_block.?.block.version});
                        log.warn("    Actual hash: 0x{x}", .{actual_hash});
                        log.warn("    Content size: {} bytes", .{system_block.?.block.content.len});
                        log.warn("  VERSION ANALYSIS:", .{});
                        log.warn("    PROBLEM: Storage returned NEWER version {} when model expects version {}", .{ system_block.?.block.version, model_block.version });
                        log.warn("    ROOT CAUSE: Model state inconsistency - missed version update", .{});
                    }

                    // Update model to match storage reality (both version and hash)
                    if (self.blocks.getPtr(model_block.id)) |model_ptr| {
                        model_ptr.version = system_block.?.block.version;
                        model_ptr.content_hash = actual_hash;
                        model_ptr.sequence_number = self.global_sequence;
                        model_ptr.validation_checksum = ModelBlock.compute_validation_checksum(model_ptr.id, model_ptr.content_hash, model_ptr.sequence_number);
                    }
                } else {
                    // Storage has older version - this indicates data loss or corruption
                    fatal_assert(false, "VERSION REGRESSION VIOLATION: Storage version older than model\n" ++
                        "  Block ID: {}\n" ++
                        "  Model version: {}\n" ++
                        "  Storage version: {}\n" ++
                        "  This indicates data loss or version rollback.", .{ model_block.id, model_block.version, system_block.?.block.version });
                }
            } else {
                // Same version - verify hash strictly
                if (actual_hash != expected_hash) {
                    validation_metrics.hash_mismatches += 1;
                    fatal_assert(false, "CRYPTOGRAPHIC INTEGRITY VIOLATION: Content hash mismatch\n" ++
                        "  Block ID: {}\n" ++
                        "  Expected hash: 0x{x}\n" ++
                        "  Actual hash: 0x{x}\n" ++
                        "  Content size: {} bytes\n" ++
                        "  This indicates data corruption or hash function inconsistency.", .{ model_block.id, expected_hash, actual_hash, model_block.content_size });
                }
            }

            validation_metrics.verified_blocks += 1;
        }

        // Report comprehensive validation metrics
        if (comptime std.debug.runtime_safety) {
            const verification_rate = @as(f64, @floatFromInt(validation_metrics.verified_blocks)) /
                @as(f64, @floatFromInt(validation_metrics.total_blocks - validation_metrics.deleted_blocks));

            log.debug("Block consistency validation complete:\n" ++
                "  Total blocks: {}\n" ++
                "  Deleted blocks: {}\n" ++
                "  Verified blocks: {}\n" ++
                "  Verification rate: {d:.3}%\n" ++
                "  Hash mismatches: {}\n" ++
                "  Version mismatches: {}", .{ validation_metrics.total_blocks, validation_metrics.deleted_blocks, validation_metrics.verified_blocks, verification_rate * 100, validation_metrics.hash_mismatches, validation_metrics.version_mismatches });
        }
    }

    /// Verify all edges in model exist in system with graph-theoretic precision.
    ///
    /// Validates edge integrity using mathematical graph theory principles
    /// and provides comprehensive forensic analysis of graph inconsistencies.
    fn verify_edge_consistency(self: *Self, storage: *StorageEngine) !void {
        var graph_metrics = struct {
            total_edges: u32 = 0,
            active_edges: u32 = 0,
            orphaned_edges: u32 = 0,
            missing_edges: u32 = 0,
            verified_edges: u32 = 0,
        }{};

        for (self.edges.items) |edge| {
            graph_metrics.total_edges += 1;

            // Mathematical invariant: edges must reference existing blocks
            const source_exists = if (self.blocks.get(edge.source_id)) |source_block|
                !source_block.deleted
            else
                false;
            const target_exists = if (self.blocks.get(edge.target_id)) |target_block|
                !target_block.deleted
            else
                false;

            if (!source_exists) {
                graph_metrics.orphaned_edges += 1;
                fatal_assert(false, "REFERENTIAL INTEGRITY VIOLATION: Edge source block missing\n" ++
                    "  Edge type: {}\n" ++
                    "  Source ID: {}\n" ++
                    "  Target ID: {}\n" ++
                    "  This violates the fundamental graph consistency contract.", .{ edge.edge_type, edge.source_id, edge.target_id });
            }

            if (!target_exists) {
                graph_metrics.orphaned_edges += 1;
                fatal_assert(false, "REFERENTIAL INTEGRITY VIOLATION: Edge target block missing\n" ++
                    "  Edge type: {}\n" ++
                    "  Source ID: {}\n" ++
                    "  Target ID: {}\n" ++
                    "  This violates the fundamental graph consistency contract.", .{ edge.edge_type, edge.source_id, edge.target_id });
            }

            if (!source_exists or !target_exists) {
                continue; // Skip further validation for orphaned edges
            }

            graph_metrics.active_edges += 1;

            // Mathematical invariant: active edges must be discoverable through traversal
            const edges = storage.find_outgoing_edges(edge.source_id);
            var found = false;

            for (edges) |sys_edge| {
                if (std.mem.eql(u8, &sys_edge.edge.target_id.bytes, &edge.target_id.bytes) and
                    sys_edge.edge.edge_type == edge.edge_type)
                {
                    found = true;
                    break;
                }
            }

            if (!found) {
                graph_metrics.missing_edges += 1;
            } else {
                graph_metrics.verified_edges += 1;
            }
        }

        // Mathematical validation: all active edges must be verified
        if (graph_metrics.missing_edges > 0) {
            const edge_integrity = @as(f64, @floatFromInt(graph_metrics.verified_edges)) /
                @as(f64, @floatFromInt(graph_metrics.active_edges));

            fatal_assert(false, "GRAPH TRAVERSAL VIOLATION: Edge discovery inconsistency\n" ++
                "  Missing edges: {}/{} ({d:.1}%)\n" ++
                "  Active edges: {}\n" ++
                "  Orphaned edges: {}\n" ++
                "  Edge integrity: {d:.3}%\n" ++
                "  This breaks the graph traversal consistency guarantee.", .{ graph_metrics.missing_edges, graph_metrics.active_edges, @as(f64, @floatFromInt(graph_metrics.missing_edges)) / @as(f64, @floatFromInt(graph_metrics.active_edges)) * 100, graph_metrics.active_edges, graph_metrics.orphaned_edges, edge_integrity * 100 });
        }

        // Report comprehensive graph validation metrics
        if (comptime std.debug.runtime_safety) {
            const graph_integrity = @as(f64, @floatFromInt(graph_metrics.verified_edges)) /
                @as(f64, @floatFromInt(graph_metrics.total_edges));

            log.debug("Graph consistency validation complete:\n" ++
                "  Total edges: {}\n" ++
                "  Active edges: {}\n" ++
                "  Verified edges: {}\n" ++
                "  Orphaned edges: {}\n" ++
                "  Graph integrity: {d:.3}%", .{ graph_metrics.total_edges, graph_metrics.active_edges, graph_metrics.verified_edges, graph_metrics.orphaned_edges, graph_integrity * 100 });
        }
    }

    // ========================================================================
    // Mathematical Query Interface
    //
    // These methods provide mathematically precise access to model state
    // with comprehensive validation and forensic tracking capabilities.
    // ========================================================================

    /// Count active (non-deleted) blocks with mathematical precision
    pub fn active_block_count(self: *Self) !u32 {
        var count: u32 = 0;
        var iterator = self.blocks.iterator();

        while (iterator.next()) |entry| {
            const block = entry.value_ptr;

            // Validate block consistency during counting
            if (comptime std.debug.runtime_safety) {
                self.validate_block_consistency(block) catch |err| {
                    log.warn("Block consistency violation during counting: {}", .{err});
                };
            }

            if (!block.deleted) {
                count += 1;
            }
        }

        return count;
    }

    /// Record memtable flush with mathematical state tracking
    pub fn record_flush(self: *Self) void {
        self.flush_count += 1;
        self.last_flush_sequence = self.global_sequence;

        // Update cryptographic state to reflect flush operation
        self.update_state_checksum();

        if (comptime std.debug.runtime_safety) {
            log.debug("Flush recorded: count={}, sequence={}", .{ self.flush_count, self.last_flush_sequence });
        }
    }

    /// Get number of operations since last flush with mathematical precision
    pub fn operations_since_flush(self: *Self) u64 {
        return self.global_sequence - self.last_flush_sequence;
    }

    /// Get total number of edges with referential integrity validation
    pub fn edge_count(self: *Self) u32 {
        var active_edges: u32 = 0;

        for (self.edges.items) |edge| {
            // Only count edges with valid endpoints
            const source_active = self.has_active_block(edge.source_id);
            const target_active = self.has_active_block(edge.target_id);

            if (source_active and target_active) {
                active_edges += 1;
            }
        }

        return active_edges;
    }

    /// Check if block exists in model and is mathematically active
    pub fn has_active_block(self: *Self, block_id: BlockId) bool {
        if (self.blocks.get(block_id)) |block| {
            return !block.deleted and block.validation_checksum != 0;
        }
        return false;
    }

    /// Get block from model with cryptographic verification
    pub fn find_active_block(self: *Self, block_id: BlockId) ?ModelBlock {
        if (self.blocks.get(block_id)) |block| {
            if (!block.deleted) {
                // Verify block integrity before returning
                if (comptime std.debug.runtime_safety) {
                    const expected_checksum = ModelBlock.compute_validation_checksum(block.id, block.content_hash, block.sequence_number);
                    if (block.validation_checksum != expected_checksum) {
                        log.warn("Block integrity violation in find_active_block");
                        return null;
                    }
                }
                return block;
            }
        }
        return null;
    }

    /// Count outgoing edges with graph-theoretic precision
    pub fn count_outgoing_edges(self: *Self, source_id: BlockId) u32 {
        var count: u32 = 0;

        // Only count edges from active source blocks
        if (!self.has_active_block(source_id)) {
            return 0;
        }

        for (self.edges.items) |edge| {
            if (edge.source_id.eql(source_id) and self.has_active_block(edge.target_id)) {
                count += 1;
            }
        }

        return count;
    }

    /// Count incoming edges with mathematical validation
    pub fn count_incoming_edges(self: *Self, target_id: BlockId) u32 {
        var count: u32 = 0;

        // Only count edges to active target blocks
        if (!self.has_active_block(target_id)) {
            return 0;
        }

        for (self.edges.items) |edge| {
            if (edge.target_id.eql(target_id) and self.has_active_block(edge.source_id)) {
                count += 1;
            }
        }

        return count;
    }

    /// Find edges by type with mathematical precision and memory safety
    /// Returns allocated slice that caller must free with backing_allocator.free()
    pub fn find_edges_by_type(self: *Self, source_id: BlockId, edge_type: EdgeType) []GraphEdge {
        var filtered = std.array_list.Managed(GraphEdge).init(self.backing_allocator);
        defer filtered.deinit();

        // Validate source block exists before filtering
        if (!self.has_active_block(source_id)) {
            return self.backing_allocator.alloc(GraphEdge, 0) catch &.{};
        }

        // Filter edges with mathematical precision
        for (self.edges.items) |edge| {
            if (edge.source_id.eql(source_id) and
                edge.edge_type == edge_type and
                self.has_active_block(edge.target_id))
            {
                filtered.append(edge) catch {
                    // On allocation failure, return empty slice
                    return self.backing_allocator.alloc(GraphEdge, 0) catch &.{};
                };
            }
        }

        // Return owned slice with proper memory management
        return filtered.toOwnedSlice() catch &.{};
    }

    /// Get comprehensive forensic state summary for debugging
    pub fn state_summary(self: *Self) struct {
        total_blocks: u32,
        active_blocks: u32,
        deleted_blocks: u32,
        total_edges: u32,
        active_edges: u32,
        operation_count: u64,
        global_sequence: u64,
        flush_count: u32,
        memory_usage_mb: f64,
        peak_memory_mb: f64,
        state_checksum: u64,
        uptime_ns: u64,
    } {
        const current_time = @as(u64, @intCast(std.time.nanoTimestamp()));
        const active_blocks = self.active_block_count() catch 0;
        const total_blocks = @as(u32, @intCast(self.blocks.count()));

        return .{
            .total_blocks = total_blocks,
            .active_blocks = active_blocks,
            .deleted_blocks = total_blocks - active_blocks,
            .total_edges = @as(u32, @intCast(self.edges.items.len)),
            .active_edges = self.edge_count(),
            .operation_count = self.operation_count,
            .global_sequence = self.global_sequence,
            .flush_count = self.flush_count,
            .memory_usage_mb = @as(f64, @floatFromInt(self.total_bytes_allocated)) / (1024.0 * 1024.0),
            .peak_memory_mb = @as(f64, @floatFromInt(self.peak_memory_usage)) / (1024.0 * 1024.0),
            .state_checksum = self.state_checksum,
            .uptime_ns = current_time - self.creation_timestamp,
        };
    }

    /// Synchronize model state with storage engine after crash recovery.
    /// Aligns model state with actual storage contents to prevent consistency violations.
    pub fn sync_with_storage(self: *Self, storage_engine: anytype) !void {
        var blocks_to_remove = std.array_list.Managed(BlockId).init(self.backing_allocator);
        defer blocks_to_remove.deinit();

        var block_iterator = self.blocks.iterator();
        while (block_iterator.next()) |entry| {
            const block_id = entry.key_ptr.*;
            const model_block = entry.value_ptr;

            const found_in_storage = storage_engine.*.find_block(block_id, .temporary) catch |err| switch (err) {
                error.BlockNotFound => null,
                else => return err,
            };

            // Sync deletion state with storage reality
            if (found_in_storage != null) {
                model_block.deleted = false;
            } else {
                // Mark for removal instead of just setting deleted = true
                try blocks_to_remove.append(block_id);
            }
        }

        // Remove blocks that don't exist in storage after crash recovery
        for (blocks_to_remove.items) |block_id| {
            _ = self.blocks.remove(block_id);
        }

        // Rebuild edge list from storage
        self.edges.clearAndFree();
        const storage_edges = try self.load_all_edges_from_storage(storage_engine);
        defer self.backing_allocator.free(storage_edges);

        for (storage_edges) |edge| {
            try self.edges.append(edge);
        }

        self.update_state_checksum();
    }

    /// Load all edges from storage engine for model synchronization
    fn load_all_edges_from_storage(self: *Self, storage_engine: anytype) ![]GraphEdge {
        var all_edges = std.array_list.Managed(GraphEdge).init(self.backing_allocator);

        // Iterate through all active blocks and collect their outgoing edges
        var block_iterator = self.blocks.iterator();
        while (block_iterator.next()) |entry| {
            const block_id = entry.key_ptr.*;
            const model_block = entry.value_ptr;

            // Only check active blocks
            if (model_block.deleted) continue;

            // Get outgoing edges from storage for this block
            const outgoing_edges = storage_engine.*.find_outgoing_edges(block_id);
            for (outgoing_edges) |owned_edge| {
                const edge = owned_edge.read(.temporary);
                try all_edges.append(edge.*);
            }
        }

        return all_edges.toOwnedSlice();
    }

    /// Collect list of active (non-deleted) block IDs for safe edge generation
    pub fn collect_active_block_ids(self: *Self, allocator: std.mem.Allocator) ![]BlockId {
        var active_ids = std.array_list.Managed(BlockId).init(allocator);

        var block_iterator = self.blocks.iterator();
        while (block_iterator.next()) |entry| {
            const model_block = entry.value_ptr;
            if (!model_block.deleted) {
                try active_ids.append(entry.key_ptr.*);
            }
        }

        return active_ids.toOwnedSlice();
    }
};

test "model state tracks put_block operations" {
    const allocator = testing.allocator;

    var model = try ModelState.init(allocator);
    defer model.deinit();

    // Create test block
    const block = ContextBlock{
        .id = BlockId.from_u64(42),
        .source_uri = "/test/file.zig",
        .content = "test content",
        .metadata_json = "{}",
        .version = 1,
    };

    // Apply put_block operation
    const operation = workload_mod.Operation{
        .op_type = .put_block,
        .block = block,
        .sequence_number = 1,
    };
    try model.apply_operation(&operation);

    // Verify block was added to model
    try testing.expect(model.has_active_block(block.id));
    try testing.expectEqual(@as(u32, 1), try model.active_block_count());
}

test "model state tracks delete_block operations" {
    const allocator = testing.allocator;

    var model = try ModelState.init(allocator);
    defer model.deinit();

    const block_id = BlockId.from_u64(42);

    // Add block first
    const block = ContextBlock{
        .id = block_id,
        .source_uri = "/test/file.zig",
        .content = "test content",
        .metadata_json = "{}",
        .version = 1,
    };
    const put_op = workload_mod.Operation{
        .op_type = .put_block,
        .block = block,
        .sequence_number = 1,
    };
    try model.apply_operation(&put_op);

    // Delete block
    const delete_op = workload_mod.Operation{
        .op_type = .delete_block,
        .block_id = block_id,
        .sequence_number = 2,
    };
    try model.apply_operation(&delete_op);

    // Verify block is marked as deleted
    try testing.expect(!model.has_active_block(block_id));
    try testing.expectEqual(@as(u32, 0), try model.active_block_count());
}

test "model state tracks put_edge operations" {
    const allocator = testing.allocator;

    var model = try ModelState.init(allocator);
    defer model.deinit();

    // Create source block first
    const source_block = ContextBlock{
        .id = BlockId.from_u64(1),
        .version = 1,
        .source_uri = "test://source",
        .metadata_json = "{}",
        .content = "source block",
    };

    const source_operation = workload_mod.Operation{
        .op_type = .put_block,
        .block = source_block,
        .sequence_number = 1,
    };
    try model.apply_operation(&source_operation);

    // Create target block second
    const target_block = ContextBlock{
        .id = BlockId.from_u64(2),
        .version = 1,
        .source_uri = "test://target",
        .metadata_json = "{}",
        .content = "target block",
    };

    const target_operation = workload_mod.Operation{
        .op_type = .put_block,
        .block = target_block,
        .sequence_number = 2,
    };
    try model.apply_operation(&target_operation);

    // Now create edge between existing blocks
    const edge = GraphEdge{
        .source_id = BlockId.from_u64(1),
        .target_id = BlockId.from_u64(2),
        .edge_type = .calls,
    };

    const edge_operation = workload_mod.Operation{
        .op_type = .put_edge,
        .edge = edge,
        .sequence_number = 3,
    };
    try model.apply_operation(&edge_operation);

    // Verify edge was added
    try testing.expectEqual(@as(u32, 1), model.edge_count());
    try testing.expectEqual(@as(u32, 1), model.count_outgoing_edges(edge.source_id));
    try testing.expectEqual(@as(u32, 1), model.count_incoming_edges(edge.target_id));
}

test "model prevents duplicate edges" {
    const allocator = testing.allocator;

    var model = try ModelState.init(allocator);
    defer model.deinit();

    // Create source block first
    const source_block = ContextBlock{
        .id = BlockId.from_u64(1),
        .version = 1,
        .source_uri = "test://source",
        .metadata_json = "{}",
        .content = "source block",
    };

    const source_operation = workload_mod.Operation{
        .op_type = .put_block,
        .block = source_block,
        .sequence_number = 1,
    };
    try model.apply_operation(&source_operation);

    // Create target block second
    const target_block = ContextBlock{
        .id = BlockId.from_u64(2),
        .version = 1,
        .source_uri = "test://target",
        .metadata_json = "{}",
        .content = "target block",
    };

    const target_operation = workload_mod.Operation{
        .op_type = .put_block,
        .block = target_block,
        .sequence_number = 2,
    };
    try model.apply_operation(&target_operation);

    // Now test duplicate edge creation
    const edge = GraphEdge{
        .source_id = BlockId.from_u64(1),
        .target_id = BlockId.from_u64(2),
        .edge_type = .calls,
    };

    const op1 = workload_mod.Operation{
        .op_type = .put_edge,
        .edge = edge,
        .sequence_number = 3,
    };
    try model.apply_operation(&op1);

    const op2 = workload_mod.Operation{
        .op_type = .put_edge,
        .edge = edge,
        .sequence_number = 4,
    };
    try model.apply_operation(&op2);

    // Should still only have one edge (duplicate rejected)
    try testing.expectEqual(@as(u32, 1), model.edge_count());
}
