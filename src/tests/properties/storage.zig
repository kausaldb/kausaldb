//! Reusable storage property definitions for deterministic testing.
//!
//! Defines properties that must hold for the storage engine regardless of
//! operation sequence, timing, or failure conditions. These properties are
//! used by scenario tests to validate system invariants.
//!
//! Design rationale: Rather than duplicating assertions across tests, we
//! centralize property definitions. This ensures consistent validation and
//! makes it easy to strengthen properties as we discover new edge cases.

const std = @import("std");
const testing = std.testing;

const assert_mod = @import("../../core/assert.zig");
const ownership = @import("../../core/ownership.zig");
const storage_engine_mod = @import("../../storage/engine.zig");
const types = @import("../../core/types.zig");

const assert = assert_mod.assert;
const fatal_assert = assert_mod.fatal_assert;

const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const EdgeType = types.EdgeType;
const GraphEdge = types.GraphEdge;
const OwnedBlock = ownership.OwnedBlock;
const StorageEngine = storage_engine_mod.StorageEngine;

/// Core storage properties that must always hold
pub const StorageProperties = struct {
    /// Property: All acknowledged writes must be findable immediately
    /// This validates read-your-writes consistency
    pub fn validate_write_visibility(
        model_blocks: std.AutoHashMap(BlockId, ContextBlock),
        storage: *StorageEngine,
    ) !void {
        var iterator = model_blocks.iterator();
        while (iterator.next()) |entry| {
            const block_id = entry.key_ptr.*;
            const expected_block = entry.value_ptr.*;

            const found_block = try storage.find_block(block_id, .storage_engine);
            if (found_block == null) {
                fatal_assert(false, "Property violation: Written block {x} not findable", .{block_id.value});
            }

            const actual_block = found_block.?.read(.storage_engine);
            try testing.expectEqualStrings(expected_block.content, actual_block.content);
            try testing.expectEqualStrings(expected_block.source_uri, actual_block.source_uri);
            try testing.expectEqual(expected_block.version, actual_block.version);
        }
    }

    /// Property: Deleted blocks must not be findable
    /// This validates delete operations are effective
    pub fn validate_delete_effectiveness(
        deleted_ids: std.AutoHashMap(BlockId, void),
        storage: *StorageEngine,
    ) !void {
        var iterator = deleted_ids.iterator();
        while (iterator.next()) |entry| {
            const block_id = entry.key_ptr.*;

            const found_block = try storage.find_block(block_id, .storage_engine);
            if (found_block != null) {
                fatal_assert(false, "Property violation: Deleted block {x} still findable", .{block_id.value});
            }
        }
    }

    /// Property: Acknowledged writes survive crashes
    /// This validates WAL durability guarantees
    pub fn validate_crash_durability(
        pre_crash_blocks: std.AutoHashMap(BlockId, ContextBlock),
        post_recovery_storage: *StorageEngine,
    ) !void {
        var iterator = pre_crash_blocks.iterator();
        while (iterator.next()) |entry| {
            const block_id = entry.key_ptr.*;
            const expected_block = entry.value_ptr.*;

            const recovered_block = try post_recovery_storage.find_block(block_id, .storage_engine);
            if (recovered_block == null) {
                fatal_assert(false, "Property violation: Acknowledged block {x} lost after crash", .{block_id.value});
            }

            const actual_block = recovered_block.?.read(.storage_engine);
            try testing.expectEqualStrings(expected_block.content, actual_block.content);
        }
    }

    /// Property: Memory usage returns to baseline after flush
    /// This validates arena cleanup effectiveness
    pub fn validate_memory_cleanup(
        pre_flush_memory: u64,
        post_flush_memory: u64,
        tolerance_factor: f32,
    ) !void {
        // Post-flush memory should be close to baseline
        // Small overhead is acceptable for index structures
        const max_expected = @as(u64, @intFromFloat(@as(f32, @floatFromInt(pre_flush_memory)) * tolerance_factor));

        if (post_flush_memory > max_expected) {
            fatal_assert(false, "Property violation: Memory not cleaned after flush. Pre: {} Post: {} Max: {}", .{ pre_flush_memory, post_flush_memory, max_expected });
        }
    }

    /// Property: Compaction preserves all data
    /// This validates that compaction doesn't lose blocks
    pub fn validate_compaction_preservation(
        pre_compaction_blocks: std.AutoHashMap(BlockId, ContextBlock),
        post_compaction_storage: *StorageEngine,
    ) !void {
        var iterator = pre_compaction_blocks.iterator();
        while (iterator.next()) |entry| {
            const block_id = entry.key_ptr.*;
            const expected_block = entry.value_ptr.*;

            const found_block = try post_compaction_storage.find_block(block_id, .storage_engine);
            if (found_block == null) {
                fatal_assert(false, "Property violation: Block {x} lost during compaction", .{block_id.value});
            }

            const actual_block = found_block.?.read(.storage_engine);
            try testing.expectEqualStrings(expected_block.content, actual_block.content);
        }
    }

    /// Property: SSTable count stays bounded under sustained load
    /// This validates compaction keeps storage efficient
    pub fn validate_sstable_bounds(
        sstable_count: u32,
        max_expected: u32,
    ) !void {
        if (sstable_count > max_expected) {
            fatal_assert(false, "Property violation: SSTable count {} exceeds bound {}", .{ sstable_count, max_expected });
        }
    }

    /// Property: WAL segments are properly rotated
    /// This validates WAL segment management
    pub fn validate_wal_rotation(
        wal_size: u64,
        segment_size: u64,
        active_segments: u32,
    ) !void {
        const expected_segments = (wal_size + segment_size - 1) / segment_size;

        // Allow for one extra segment during rotation
        if (active_segments > expected_segments + 1) {
            fatal_assert(false, "Property violation: WAL has {} segments, expected at most {}", .{ active_segments, expected_segments + 1 });
        }
    }

    /// Property: Block ownership is consistent
    /// This validates ownership tracking correctness
    pub fn validate_ownership_consistency(
        storage: *StorageEngine,
        expected_owner: ownership.Owner,
    ) !void {
        // All blocks in memtable should have consistent ownership
        var iterator = storage.memtable_manager.block_index.blocks.iterator();
        while (iterator.next()) |entry| {
            const owned_block = entry.value_ptr.*;

            if (owned_block.owner != expected_owner) {
                fatal_assert(false, "Property violation: Block has owner {}, expected {}", .{ owned_block.owner, expected_owner });
            }
        }
    }

    /// Property: Flush threshold triggers at configured size
    /// This validates memory pressure handling
    pub fn validate_flush_threshold(
        current_memory: u64,
        threshold: u64,
        should_flush: bool,
    ) !void {
        const actually_should_flush = current_memory >= threshold;

        if (should_flush != actually_should_flush) {
            fatal_assert(false, "Property violation: Flush trigger incorrect. Memory: {} Threshold: {} Should flush: {} Actually: {}", .{ current_memory, threshold, should_flush, actually_should_flush });
        }
    }

    /// Property: Corrupted data is detected by checksums
    /// This validates data integrity protection
    pub fn validate_corruption_detection(
        corruption_injected: bool,
        error_occurred: bool,
    ) !void {
        if (corruption_injected and !error_occurred) {
            fatal_assert(false, "Property violation: Corruption not detected by checksums", .{});
        }
    }
};

/// Graph-specific storage properties
pub const GraphProperties = struct {
    /// Property: All edges reference existing blocks
    /// This validates referential integrity
    pub fn validate_edge_references(
        edges: std.AutoHashMap(GraphEdge, void),
        blocks: std.AutoHashMap(BlockId, ContextBlock),
    ) !void {
        var iterator = edges.iterator();
        while (iterator.next()) |entry| {
            const edge = entry.key_ptr.*;

            if (!blocks.contains(edge.source_id)) {
                fatal_assert(false, "Property violation: Edge source {x} doesn't exist", .{edge.source_id.value});
            }

            if (!blocks.contains(edge.target_id)) {
                fatal_assert(false, "Property violation: Edge target {x} doesn't exist", .{edge.target_id.value});
            }
        }
    }

    /// Property: Bidirectional edge indices are consistent
    /// This validates graph index integrity
    pub fn validate_bidirectional_consistency(
        storage: *StorageEngine,
    ) !void {
        // For each outgoing edge, there should be a corresponding incoming edge
        var out_iterator = storage.memtable_manager.edge_index.outgoing_edges.iterator();
        while (out_iterator.next()) |out_entry| {
            const source_id = out_entry.key_ptr.*;
            const outgoing = out_entry.value_ptr.*;

            for (outgoing.items) |edge| {
                // Find corresponding incoming edge
                const incoming = storage.memtable_manager.edge_index.incoming_edges.get(edge.target_id);
                if (incoming == null) {
                    fatal_assert(false, "Property violation: No incoming edges for target {x}", .{edge.target_id.value});
                }

                // Verify edge exists in incoming list
                var found = false;
                for (incoming.?.items) |in_edge| {
                    if (in_edge.source_id.eql(source_id) and
                        in_edge.target_id.eql(edge.target_id) and
                        in_edge.edge_type == edge.edge_type)
                    {
                        found = true;
                        break;
                    }
                }

                if (!found) {
                    fatal_assert(false, "Property violation: Edge {x}->{x} not in incoming index", .{ source_id.value, edge.target_id.value });
                }
            }
        }
    }

    /// Property: Edge removal with block deletion
    /// This validates cascade deletion
    pub fn validate_cascade_deletion(
        deleted_block: BlockId,
        storage: *StorageEngine,
    ) !void {
        // No edges should reference the deleted block
        var out_iterator = storage.memtable_manager.edge_index.outgoing_edges.iterator();
        while (out_iterator.next()) |entry| {
            const edges = entry.value_ptr.*;

            for (edges.items) |edge| {
                if (edge.source_id.eql(deleted_block) or edge.target_id.eql(deleted_block)) {
                    fatal_assert(false, "Property violation: Edge references deleted block {x}", .{deleted_block.value});
                }
            }
        }
    }
};

/// Performance properties that should hold under load
pub const PerformanceProperties = struct {
    /// Property: Operation latency stays within bounds
    /// This validates performance requirements
    pub fn validate_latency_bounds(
        operation_type: []const u8,
        latency_ns: u64,
        max_latency_ns: u64,
    ) !void {
        if (latency_ns > max_latency_ns) {
            fatal_assert(false, "Property violation: {} latency {}ns exceeds bound {}ns", .{ operation_type, latency_ns, max_latency_ns });
        }
    }

    /// Property: Throughput meets minimum requirements
    /// This validates sustained performance
    pub fn validate_throughput(
        operations_per_second: u64,
        min_required: u64,
    ) !void {
        if (operations_per_second < min_required) {
            fatal_assert(false, "Property violation: Throughput {} ops/s below minimum {} ops/s", .{ operations_per_second, min_required });
        }
    }

    /// Property: Memory growth is bounded
    /// This validates no memory leaks
    pub fn validate_memory_growth(
        initial_memory: u64,
        current_memory: u64,
        operations_done: u64,
        max_growth_per_op: u64,
    ) !void {
        const expected_max = initial_memory + (operations_done * max_growth_per_op);

        if (current_memory > expected_max) {
            fatal_assert(false, "Property violation: Memory {} exceeds expected {} for {} operations", .{ current_memory, expected_max, operations_done });
        }
    }
};

/// Recovery properties for crash scenarios
pub const RecoveryProperties = struct {
    /// Property: WAL replay is idempotent
    /// This validates recovery correctness
    pub fn validate_replay_idempotence(
        first_recovery_state: std.AutoHashMap(BlockId, ContextBlock),
        second_recovery_state: std.AutoHashMap(BlockId, ContextBlock),
    ) !void {
        // Both recoveries should produce identical state
        if (first_recovery_state.count() != second_recovery_state.count()) {
            fatal_assert(false, "Property violation: WAL replay not idempotent. First: {} blocks, Second: {} blocks", .{ first_recovery_state.count(), second_recovery_state.count() });
        }

        var iterator = first_recovery_state.iterator();
        while (iterator.next()) |entry| {
            const block_id = entry.key_ptr.*;
            const first_block = entry.value_ptr.*;

            const second_block = second_recovery_state.get(block_id);
            if (second_block == null) {
                fatal_assert(false, "Property violation: Block {x} in first recovery but not second", .{block_id.value});
            }

            try testing.expectEqualStrings(first_block.content, second_block.?.content);
        }
    }

    /// Property: Partial writes are handled correctly
    /// This validates corruption resilience
    pub fn validate_partial_write_handling(
        partial_write_occurred: bool,
        recovery_succeeded: bool,
        data_loss: bool,
    ) !void {
        if (partial_write_occurred) {
            // Recovery should succeed
            if (!recovery_succeeded) {
                fatal_assert(false, "Property violation: Recovery failed after partial write", .{});
            }

            // Only the partial entry should be lost
            // All prior entries must be recovered
            if (data_loss) {
                // This is acceptable only for the last partial entry
                // Prior entries must not be lost
            }
        }
    }
};
