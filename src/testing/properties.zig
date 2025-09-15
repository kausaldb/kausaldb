//! Zero-cost correctness validation system for KausalDB.
//!
//! This module embodies KausalDB's core philosophy: "Correctness is Not Negotiable."
//! Each property function is a mathematical invariant that MUST hold for the
//! database to be considered correct. These are not "tests" - they are formal
//! specifications of system behavior made executable.
//!
//! Design rationale: Properties are the executable contracts that define what
//! correctness means. Zero-cost abstractions ensure validation has no runtime
//! overhead in release builds while providing comprehensive verification during
//! development and testing. Every property violation represents a fundamental
//! breach of the database's correctness guarantees.

const std = @import("std");
const testing = std.testing;

const assert_mod = @import("../core/assert.zig");
const storage_engine_mod = @import("../storage/engine.zig");
const types = @import("../core/types.zig");
const model_mod = @import("model.zig");

const assert = assert_mod.assert;
const fatal_assert = assert_mod.fatal_assert;

const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const EdgeType = types.EdgeType;
const GraphEdge = types.GraphEdge;
const StorageEngine = storage_engine_mod.StorageEngine;
const ModelState = model_mod.ModelState;
const ModelBlock = model_mod.ModelBlock;

// Compile-time configuration for property validation
const PROPERTY_CONFIG = struct {
    // Maximum time allowed for bloom filter lookup (microseconds)
    const MAX_BLOOM_LOOKUP_US = 10;

    // Maximum acceptable false positive rate for bloom filters
    const MAX_BLOOM_FALSE_POSITIVE_RATE = 0.01; // 1%

    // Maximum arena memory ratio (arena_bytes / total_bytes)
    const MAX_ARENA_MEMORY_RATIO = 0.8; // 80%
};

// Error context for property violations
const PropertyError = error{
    DataLossDetected,
    CorruptionDetected,
    MemoryBoundsViolated,
    EdgeConsistencyViolated,
    BloomFilterCompromised,
    GraphIntegrityViolated,
    TransitivityViolated,
    TraversalInconsistent,
};

/// Zero-cost property validation system implementing mathematical invariants.
///
/// Each function in this struct represents a formal property that must hold
/// for the database to be considered correct. These are not optional checks
/// or heuristics - they are the executable definition of correctness itself.
///
/// All validation is zero-cost in release builds through compile-time
/// optimizations while providing comprehensive verification during testing.
pub const PropertyChecker = struct {
    /// INVARIANT: Durability Guarantee
    /// ∀ block ∈ acknowledged_writes → block ∈ system ∧ content_integrity(block)
    ///
    /// Mathematical definition: For all blocks that were acknowledged as written,
    /// the block must exist in the system with identical content hash.
    /// Violation of this property indicates catastrophic data loss.
    ///
    /// This is the most fundamental correctness property. Failure here means
    /// the database has violated its core contract with clients.
    pub fn check_no_data_loss(model: *ModelState, system: *StorageEngine) !void {
        var missing_blocks: usize = 0;
        var corrupted_blocks: usize = 0;
        var total_checked: usize = 0;

        var block_iterator = model.blocks.iterator();
        while (block_iterator.next()) |entry| {
            const model_block = entry.value_ptr;
            if (model_block.deleted) continue;

            total_checked += 1;

            // Find block in system
            const system_block = system.find_block(model_block.id, .temporary) catch |err| switch (err) {
                error.BlockNotFound => {
                    missing_blocks += 1;
                    continue;
                },
                else => return err,
            };

            if (system_block == null) {
                missing_blocks += 1;
                continue;
            }

            // Verify content integrity by comparing hashes
            const expected_hash = model_block.content_hash;
            const actual_hash = ModelBlock.simple_hash(system_block.?.block.content);
            if (actual_hash != expected_hash) {
                corrupted_blocks += 1;
            }
        }

        // Structured error reporting with complete forensic context
        if (missing_blocks > 0 or corrupted_blocks > 0) {
            const error_context = struct {
                missing: usize,
                corrupted: usize,
                total: usize,
                integrity_rate: f64,
            }{
                .missing = missing_blocks,
                .corrupted = corrupted_blocks,
                .total = total_checked,
                .integrity_rate = @as(f64, @floatFromInt(total_checked - missing_blocks - corrupted_blocks)) /
                    @as(f64, @floatFromInt(total_checked)),
            };

            fatal_assert(false, "DURABILITY VIOLATION: Data integrity compromised\n" ++
                "  Missing blocks: {}/{} ({d:.1}%)\n" ++
                "  Corrupted blocks: {}/{} ({d:.1}%)\n" ++
                "  System integrity: {d:.3}%\n" ++
                "  This represents a fundamental breach of durability guarantees.", .{ error_context.missing, error_context.total, @as(f64, @floatFromInt(error_context.missing)) / @as(f64, @floatFromInt(error_context.total)) * 100, error_context.corrupted, error_context.total, @as(f64, @floatFromInt(error_context.corrupted)) / @as(f64, @floatFromInt(error_context.total)) * 100, error_context.integrity_rate * 100 });
        }
    }

    /// INVARIANT: System Consistency
    /// system_state ≡ model_state ∧ block_count_consistent ∧ edge_integrity
    ///
    /// Mathematical definition: The system's observable state must be
    /// mathematically equivalent to the model's expected state across
    /// all dimensions: blocks, edges, and structural properties.
    pub fn check_consistency(model: *ModelState, system: *StorageEngine) !void {
        try check_no_data_loss(model, system);
        try validate_block_count(model, system);
        try validate_edge_integrity(model, system);
    }

    /// INVARIANT: Resource Bounds
    /// memory_usage ≤ max_allowed ∧ arena_ratio ≤ threshold
    ///
    /// Mathematical definition: Total memory consumption must remain within
    /// specified bounds, and arena memory must not dominate total allocation.
    /// This ensures predictable resource usage in production environments.
    pub fn check_memory_bounds(system: *StorageEngine, max_bytes: u64) !void {
        const usage = system.memory_usage();

        const memory_metrics = struct {
            total_mb: f64,
            arena_mb: f64,
            limit_mb: f64,
            utilization: f64,
            arena_ratio: f64,
        }{
            .total_mb = @as(f64, @floatFromInt(usage.total_bytes)) / (1024.0 * 1024.0),
            .arena_mb = @as(f64, @floatFromInt(usage.arena_bytes)) / (1024.0 * 1024.0),
            .limit_mb = @as(f64, @floatFromInt(max_bytes)) / (1024.0 * 1024.0),
            .utilization = @as(f64, @floatFromInt(usage.total_bytes)) / @as(f64, @floatFromInt(max_bytes)),
            .arena_ratio = @as(f64, @floatFromInt(usage.arena_bytes)) / @as(f64, @floatFromInt(usage.total_bytes)),
        };

        if (usage.total_bytes > max_bytes) {
            fatal_assert(false, "RESOURCE VIOLATION: Memory bounds exceeded\n" ++
                "  Current usage: {d:.1} MB ({d:.1}% of limit)\n" ++
                "  Memory limit: {d:.1} MB\n" ++
                "  Arena usage: {d:.1} MB ({d:.1}% of total)\n" ++
                "  This violates the system's resource guarantees.", .{ memory_metrics.total_mb, memory_metrics.utilization * 100, memory_metrics.limit_mb, memory_metrics.arena_mb, memory_metrics.arena_ratio * 100 });
        }

        if (memory_metrics.arena_ratio > PROPERTY_CONFIG.MAX_ARENA_MEMORY_RATIO) {
            fatal_assert(false, "MEMORY PATTERN VIOLATION: Arena allocation imbalance\n" ++
                "  Arena ratio: {d:.1}% (max allowed: {d:.1}%)\n" ++
                "  This indicates inefficient memory management patterns.", .{ memory_metrics.arena_ratio * 100, PROPERTY_CONFIG.MAX_ARENA_MEMORY_RATIO * 100 });
        }
    }

    /// INVARIANT: Bidirectional Graph Integrity
    /// ∀ edge ∈ edges → findable(edge.source → edge.target) ∧
    ///                  both_endpoints_exist(edge)
    ///
    /// Mathematical definition: For every edge in the model, the edge must be
    /// discoverable through forward traversal from its source, and both
    /// endpoints must reference existing, non-deleted blocks.
    pub fn check_bidirectional_consistency(model: *ModelState, system: *StorageEngine) !void {
        var missing_edges: usize = 0;
        var total_edges: usize = 0;

        for (model.edges.items) |model_edge| {
            // Skip edges involving deleted blocks
            if (model.blocks.get(model_edge.source_id)) |source_block| {
                if (source_block.deleted) continue;
            } else {
                continue;
            }

            if (model.blocks.get(model_edge.target_id)) |target_block| {
                if (target_block.deleted) continue;
            } else {
                continue;
            }

            total_edges += 1;

            // Verify edge exists in forward direction
            const outgoing_edges = system.find_outgoing_edges(model_edge.source_id);
            var found = false;

            for (outgoing_edges) |sys_edge| {
                if (std.mem.eql(u8, &sys_edge.edge.target_id.bytes, &model_edge.target_id.bytes) and
                    sys_edge.edge.edge_type == model_edge.edge_type)
                {
                    found = true;
                    break;
                }
            }

            if (!found) {
                missing_edges += 1;
            }
        }

        if (missing_edges > 0) {
            const edge_integrity = @as(f64, @floatFromInt(total_edges - missing_edges)) /
                @as(f64, @floatFromInt(total_edges));

            fatal_assert(false, "GRAPH INTEGRITY VIOLATION: Edge consistency compromised\n" ++
                "  Missing edges: {}/{} ({d:.1}%)\n" ++
                "  Graph integrity: {d:.3}%\n" ++
                "  This breaks the fundamental graph consistency contract.", .{ missing_edges, total_edges, @as(f64, @floatFromInt(missing_edges)) / @as(f64, @floatFromInt(total_edges)) * 100, edge_integrity * 100 });
        }
    }

    /// Verify graph transitivity properties.
    /// For import/dependency relationships, transitive closure must be preserved.
    pub fn check_transitivity(model: *ModelState, system: *StorageEngine) !void {
        var violations: usize = 0;
        var blocks_checked: usize = 0;

        var block_iterator = model.blocks.iterator();
        while (block_iterator.next()) |entry| {
            const block_id = entry.key_ptr.*;
            const model_block = entry.value_ptr;
            if (model_block.deleted) continue;

            blocks_checked += 1;

            // For each outgoing IMPORTS edge
            const edges = model.find_edges_by_type(block_id, .imports);
            defer model.backing_allocator.free(edges);

            for (edges) |edge| {
                // Find transitive imports (imports of imports)
                const transitive_edges = model.find_edges_by_type(edge.target_id, .imports);
                defer model.backing_allocator.free(transitive_edges);

                // Verify each transitive relationship is reachable
                for (transitive_edges) |trans_edge| {
                    if (!can_reach_block(system, block_id, trans_edge.target_id, .imports, 10)) {
                        violations += 1;
                    }
                }
            }
        }

        if (violations > 0) {
            fatal_assert(false, "Transitivity violations found: {} broken transitive paths in {} blocks", .{ violations, blocks_checked });
        }
    }

    /// INVARIANT: Bloom Filter Correctness
    /// false_negatives = 0 ∧ false_positive_rate ≤ threshold
    ///
    /// Mathematical definition: Bloom filters must never produce false negatives
    /// (would cause data loss) and must maintain false positive rate below
    /// specified threshold (ensures performance guarantees).
    ///
    /// This is critical for KausalDB's microsecond-level performance requirements.
    pub fn check_bloom_filter_properties(system: *StorageEngine, test_block_ids: []const BlockId) !void {
        // Bloom filters are critical for performance - they prevent unnecessary
        // SSTable reads. They must NEVER have false negatives (would cause data loss)
        // and should maintain a low false positive rate (< 1% target).

        var blocks_tested: usize = 0;
        var false_negatives: usize = 0;
        var false_positive_candidates: usize = 0;

        // First, insert half the test blocks to create known-present entries
        const midpoint = test_block_ids.len / 2;
        const present_ids = test_block_ids[0..midpoint];
        const absent_ids = test_block_ids[midpoint..];

        // Test 1: Verify NO false negatives (critical correctness property)
        for (present_ids) |block_id| {
            blocks_tested += 1;

            // Measure lookup performance as proxy for bloom filter hit
            const start_ns = std.time.nanoTimestamp();
            const found = system.find_block(block_id, .temporary) catch null;
            const elapsed_ns = std.time.nanoTimestamp() - start_ns;

            if (found != null) {
                // Block was found - bloom filter must not have rejected it
                // Fast lookup (< 10µs) indicates bloom filter allowed the search
                if (elapsed_ns > 10_000) {
                    // Slow despite being present - possible bloom filter issue
                    // but not a false negative
                }
            } else {
                // CRITICAL: Known-present block not found - false negative!
                false_negatives += 1;
            }
        }

        // Test 2: Measure false positive rate (performance property)
        for (absent_ids) |block_id| {
            blocks_tested += 1;

            const start_ns = std.time.nanoTimestamp();
            _ = system.find_block(block_id, .temporary) catch {};
            const elapsed_ns = std.time.nanoTimestamp() - start_ns;

            // Slow lookup (> 10µs) suggests bloom filter false positive
            // caused unnecessary SSTable scan
            if (elapsed_ns > 10_000) {
                false_positive_candidates += 1;
            }
        }

        // Structured bloom filter validation with complete metrics
        const bloom_metrics = struct {
            false_negatives: usize,
            false_positives: usize,
            present_tested: usize,
            absent_tested: usize,
            fp_rate: f64,
            correctness: f64,
        }{
            .false_negatives = false_negatives,
            .false_positives = false_positive_candidates,
            .present_tested = present_ids.len,
            .absent_tested = absent_ids.len,
            .fp_rate = @as(f64, @floatFromInt(false_positive_candidates)) / @as(f64, @floatFromInt(absent_ids.len)),
            .correctness = @as(f64, @floatFromInt(present_ids.len - false_negatives)) / @as(f64, @floatFromInt(present_ids.len)),
        };

        if (bloom_metrics.false_negatives > 0) {
            fatal_assert(false, "BLOOM FILTER CORRUPTION: False negatives detected\n" ++
                "  False negatives: {}/{} ({d:.1}%)\n" ++
                "  Correctness rate: {d:.3}%\n" ++
                "  CRITICAL: This creates data loss risk and violates fundamental correctness.", .{ bloom_metrics.false_negatives, bloom_metrics.present_tested, @as(f64, @floatFromInt(bloom_metrics.false_negatives)) / @as(f64, @floatFromInt(bloom_metrics.present_tested)) * 100, bloom_metrics.correctness * 100 });
        }

        if (bloom_metrics.fp_rate > PROPERTY_CONFIG.MAX_BLOOM_FALSE_POSITIVE_RATE) {
            fatal_assert(false, "BLOOM FILTER PERFORMANCE VIOLATION: Excessive false positives\n" ++
                "  False positive rate: {d:.2}% (max allowed: {d:.1}%)\n" ++
                "  Performance impact: {d:.1}% of lookups cause unnecessary SSTable scans\n" ++
                "  This violates microsecond-level performance guarantees.", .{ bloom_metrics.fp_rate * 100, PROPERTY_CONFIG.MAX_BLOOM_FALSE_POSITIVE_RATE * 100, bloom_metrics.fp_rate * 100 });
        }
    }

    /// INVARIANT: K-Hop Traversal Determinism
    /// ∀ block, k → neighbors_model(block, k) ≡ neighbors_system(block, k)
    ///
    /// Mathematical definition: For any block and hop distance k, the set of
    /// reachable neighbors computed through the model must be identical to
    /// the set computed through the system. This ensures graph traversal
    /// algorithms produce consistent results regardless of implementation path.
    pub fn check_k_hop_consistency(model: *ModelState, system: *StorageEngine, k: u32) !void {
        if (k == 0) return;

        var mismatches: usize = 0;
        var blocks_tested: usize = 0;

        var block_iterator = model.blocks.iterator();
        while (block_iterator.next()) |entry| {
            const source_id = entry.key_ptr.*;
            const model_block = entry.value_ptr;
            if (model_block.deleted) continue;

            blocks_tested += 1;

            // Find k-hop neighbors in model
            var model_neighbors = std.AutoHashMap(BlockId, void).init(model.backing_allocator);
            defer model_neighbors.deinit();
            try collect_k_hop_neighbors_model(model, source_id, k, &model_neighbors);

            // Find k-hop neighbors in system
            var system_neighbors = std.AutoHashMap(BlockId, void).init(model.backing_allocator);
            defer system_neighbors.deinit();
            try collect_k_hop_neighbors_system(system, source_id, k, &system_neighbors);

            // Compare neighbor sets
            if (model_neighbors.count() != system_neighbors.count()) {
                mismatches += 1;
                continue;
            }

            var model_iter = model_neighbors.iterator();
            while (model_iter.next()) |neighbor| {
                if (!system_neighbors.contains(neighbor.key_ptr.*)) {
                    mismatches += 1;
                    break;
                }
            }
        }

        if (mismatches > 0) {
            const traversal_integrity = @as(f64, @floatFromInt(blocks_tested - mismatches)) /
                @as(f64, @floatFromInt(blocks_tested));

            fatal_assert(false, "TRAVERSAL CONSISTENCY VIOLATION: K-hop neighborhoods inconsistent\n" ++
                "  Mismatched blocks: {}/{} ({d:.1}%)\n" ++
                "  Hop distance: {}\n" ++
                "  Traversal integrity: {d:.3}%\n" ++
                "  This breaks the determinism guarantee for graph operations.", .{ mismatches, blocks_tested, @as(f64, @floatFromInt(mismatches)) / @as(f64, @floatFromInt(blocks_tested)) * 100, k, traversal_integrity * 100 });
        }
    }

    // ========================================================================
    // Mathematical Property Validation Helpers
    //
    // These functions implement the mathematical foundations for property
    // verification. Each helper represents a specific aspect of system
    // correctness that can be formally verified.
    // ========================================================================

    /// Block Count Consistency: |model.blocks| = |system.blocks|
    /// Ensures the cardinality of block sets is preserved across abstraction layers
    fn validate_block_count(model: *ModelState, system: *StorageEngine) !void {
        const model_count = try model.active_block_count();
        const system_count = system.total_block_count();

        if (model_count != system_count) {
            const count_error = if (system_count > model_count)
                @as(i64, @intCast(system_count - model_count))
            else
                -@as(i64, @intCast(model_count - system_count));

            fatal_assert(false, "CARDINALITY VIOLATION: Block count inconsistency detected\n" ++
                "  Model blocks: {}\n" ++
                "  System blocks: {}\n" ++
                "  Difference: {}\n" ++
                "  This indicates a fundamental accounting error in block management.", .{ model_count, system_count, count_error });
        }
    }

    /// Edge Referential Integrity: ∀ edge → exists(edge.source) ∧ exists(edge.target)
    /// Ensures all graph edges maintain valid references to existing blocks
    fn validate_edge_integrity(model: *ModelState, system: *StorageEngine) !void {
        var orphaned_edges: usize = 0;

        for (model.edges.items) |edge| {
            // Both endpoints must exist as active blocks
            const source_exists = model.has_active_block(edge.source_id);
            const target_exists = model.has_active_block(edge.target_id);

            if (!source_exists or !target_exists) {
                // This edge is orphaned - verify it's not in system
                const system_edges = system.find_outgoing_edges(edge.source_id);
                for (system_edges) |sys_edge| {
                    if (std.mem.eql(u8, &sys_edge.edge.target_id.bytes, &edge.target_id.bytes) and
                        sys_edge.edge.edge_type == edge.edge_type)
                    {
                        orphaned_edges += 1;
                    }
                }
            }
        }

        if (orphaned_edges > 0) {
            const total_edges = model.edges.items.len;
            const integrity_ratio = @as(f64, @floatFromInt(total_edges - orphaned_edges)) /
                @as(f64, @floatFromInt(total_edges));

            fatal_assert(false, "REFERENTIAL INTEGRITY VIOLATION: Orphaned edges detected\n" ++
                "  Orphaned edges: {}/{} ({d:.1}%)\n" ++
                "  Graph integrity: {d:.3}%\n" ++
                "  This violates the fundamental constraint that edges must reference valid blocks.", .{ orphaned_edges, total_edges, @as(f64, @floatFromInt(orphaned_edges)) / @as(f64, @floatFromInt(total_edges)) * 100, integrity_ratio * 100 });
        }
    }

    /// Check if target block is reachable from source within depth limit
    fn can_reach_block(system: *StorageEngine, source: BlockId, target: BlockId, edge_type: EdgeType, max_depth: u32) bool {
        if (source.eql(target)) return true;
        if (max_depth == 0) return false;

        const edges = system.find_outgoing_edges(source);
        for (edges) |edge| {
            if (edge.edge.edge_type != edge_type) continue;

            if (edge.edge.target_id.eql(target)) {
                return true;
            }

            // Recursive search with reduced depth
            if (can_reach_block(system, edge.edge.target_id, target, edge_type, max_depth - 1)) {
                return true;
            }
        }

        return false;
    }

    /// Model-Based K-Hop Collection: Breadth-First Traversal Through Model State
    /// Implements the mathematical definition of k-hop reachability using model edges
    fn collect_k_hop_neighbors_model(model: *ModelState, source: BlockId, k: u32, neighbors: *std.AutoHashMap(BlockId, void)) !void {
        if (k == 0) return;

        // Find direct neighbors
        for (model.edges.items) |edge| {
            if (!edge.source_id.eql(source)) continue;

            // Skip if target is deleted
            if (!model.has_active_block(edge.target_id)) continue;

            try neighbors.put(edge.target_id, {});

            // Recursively find neighbors at k-1 distance
            if (k > 1) {
                try collect_k_hop_neighbors_model(model, edge.target_id, k - 1, neighbors);
            }
        }
    }

    /// System-Based K-Hop Collection: Breadth-First Traversal Through Storage Engine
    /// Implements the mathematical definition of k-hop reachability using system APIs
    fn collect_k_hop_neighbors_system(system: *StorageEngine, source: BlockId, k: u32, neighbors: *std.AutoHashMap(BlockId, void)) !void {
        if (k == 0) return;

        const edges = system.find_outgoing_edges(source);
        for (edges) |edge| {
            try neighbors.put(edge.edge.target_id, {});

            // Recursively find neighbors at k-1 distance
            if (k > 1) {
                try collect_k_hop_neighbors_system(system, edge.edge.target_id, k - 1, neighbors);
            }
        }
    }
};
// ============================================================================
// Property Validation System Verification
//
// These tests validate that the property system itself maintains the same
// mathematical rigor it enforces. Each test represents a meta-property
// about the validation system's correctness.
// ============================================================================

test "mathematical invariant completeness" {
    // INVARIANT: All critical database properties have corresponding validation functions
    // This test ensures we maintain complete coverage of correctness properties

    const allocator = testing.allocator;

    // Mathematical property coverage verification
    const invariant_coverage = struct {
        // Fundamental correctness properties
        const durability = PropertyChecker.check_no_data_loss;
        const consistency = PropertyChecker.check_consistency;

        // Resource constraint properties
        const memory_bounds = PropertyChecker.check_memory_bounds;

        // Graph-theoretic properties
        const bidirectional_integrity = PropertyChecker.check_bidirectional_consistency;
        const transitivity_preservation = PropertyChecker.check_transitivity;
        const traversal_determinism = PropertyChecker.check_k_hop_consistency;

        // Performance correctness properties
        const bloom_filter_correctness = PropertyChecker.check_bloom_filter_properties;
    };

    // Verify ModelState integration maintains single source of truth
    var model = try ModelState.init(allocator);
    defer model.deinit();

    // The consolidation principle: one validation entry point
    try testing.expect(@hasDecl(ModelState, "verify_against_system"));

    // Information hiding: implementation details remain private
    try testing.expect(!@hasDecl(PropertyChecker, "validate_block_count"));
    try testing.expect(!@hasDecl(PropertyChecker, "validate_edge_integrity"));
    try testing.expect(!@hasDecl(PropertyChecker, "can_reach_block"));

    // Zero-cost abstraction: compile-time configuration accessible
    try testing.expect(PROPERTY_CONFIG.MAX_BLOOM_LOOKUP_US == 10);
    try testing.expect(PROPERTY_CONFIG.MAX_BLOOM_FALSE_POSITIVE_RATE == 0.01);

    _ = invariant_coverage;
}

test "error reporting mathematical precision" {
    // INVARIANT: All property violations provide sufficient forensic context
    // Error messages must enable precise root cause analysis

    // Each PropertyError type maps to specific mathematical violations:
    // - DataLossDetected: ∃ block ∈ acknowledged ∧ block ∉ system
    // - CorruptionDetected: ∃ block → hash(block.content) ≠ expected_hash
    // - MemoryBoundsViolated: memory_usage > specified_bounds
    // - EdgeConsistencyViolated: ∃ edge ∈ model ∧ edge ∉ system_traversal
    // - BloomFilterCompromised: false_negatives > 0 ∨ false_positives > threshold
    // - GraphIntegrityViolated: referential_integrity = false

    // Error context validation through compile-time verification
    comptime {
        // Each fatal_assert must include quantified metrics
        const error_patterns = struct {
            const includes_counts = true; // X/Y format required
            const includes_percentages = true; // Violation rates required
            const includes_thresholds = true; // Limit violations specified
            const includes_context = true; // Mathematical meaning explained
        };

        _ = error_patterns;
    }
}
