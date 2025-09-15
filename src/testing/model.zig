//! Model state tracking for deterministic simulation testing.
//!
//! Maintains an in-memory model of expected system state that can be compared
//! against actual system state to verify correctness. Used for property-based
//! testing to ensure operations maintain system invariants.
//!
//! Design rationale: Separate model from actual system allows verification
//! of system behavior without depending on system implementation details.
//! Model represents the "ground truth" of what the system should contain.

const std = @import("std");
const testing = std.testing;

const assert_mod = @import("../core/assert.zig");
const storage_engine_mod = @import("../storage/engine.zig");
const types = @import("../core/types.zig");
const workload_mod = @import("workload.zig");

const assert = assert_mod.assert;
const fatal_assert = assert_mod.fatal_assert;

const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const EdgeType = types.EdgeType;
const GraphEdge = types.GraphEdge;
const StorageEngine = storage_engine_mod.StorageEngine;
const Operation = workload_mod.Operation;
const OperationType = workload_mod.OperationType;

/// Model representation of a block for state tracking
pub const ModelBlock = struct {
    id: BlockId,
    version: u64,
    content_hash: u64, // Simple hash for content verification
    sequence_number: u64, // When this block was created/modified
    deleted: bool = false,

    /// Create model block from actual context block
    pub fn from_context_block(block: ContextBlock, sequence: u64) ModelBlock {
        return .{
            .id = block.id,
            .version = block.version,
            .content_hash = simple_hash(block.content),
            .sequence_number = sequence,
            .deleted = false,
        };
    }

    /// Simple hash function for content verification
    fn simple_hash(content: []const u8) u64 {
        var hash: u64 = 0;
        for (content) |byte| {
            hash = hash *% 31 +% byte;
        }
        return hash;
    }
};

/// Model state for tracking expected system state during simulation
pub const ModelState = struct {
    allocator: std.mem.Allocator,
    blocks: std.HashMap(BlockId, ModelBlock, BlockIdContext, std.hash_map.default_max_load_percentage),
    edges: std.array_list.Managed(GraphEdge),
    operation_count: u64,
    last_flush_op: u64,
    flush_count: u32,

    const Self = @This();

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

    /// Initialize model state
    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
            .blocks = std.HashMap(BlockId, ModelBlock, BlockIdContext, std.hash_map.default_max_load_percentage).init(allocator),
            .edges = std.array_list.Managed(GraphEdge).init(allocator),
            .operation_count = 0,
            .last_flush_op = 0,
            .flush_count = 0,
        };
    }

    /// Clean up all resources
    pub fn deinit(self: *Self) void {
        self.blocks.deinit();
        self.edges.deinit();
    }

    /// Apply operation to model state for tracking
    pub fn apply_operation(self: *Self, operation: *const Operation) !void {
        switch (operation.op_type) {
            .put_block => {
                if (operation.block) |block| {
                    try self.apply_put_block(block);
                }
            },
            .find_block => {
                // Read operations don't change model state
                // but we track them for operation counting
            },
            .delete_block => {
                if (operation.block_id) |id| {
                    self.apply_delete_block(id);
                }
            },
            .put_edge => {
                if (operation.edge) |edge| {
                    try self.apply_put_edge(edge);
                }
            },
            .find_edges => {
                // Read operations don't change model state
            },
        }

        self.operation_count += 1;
    }

    /// Apply put_block operation to model
    fn apply_put_block(self: *Self, block: ContextBlock) !void {
        const model_block = ModelBlock.from_context_block(block, self.operation_count);
        try self.blocks.put(block.id, model_block);
    }

    /// Apply delete_block operation to model
    fn apply_delete_block(self: *Self, block_id: BlockId) void {
        if (self.blocks.getPtr(block_id)) |model_block| {
            model_block.deleted = true;
            model_block.sequence_number = self.operation_count;
        }
    }

    /// Apply put_edge operation to model
    fn apply_put_edge(self: *Self, edge: GraphEdge) !void {
        // Check for duplicate edges
        for (self.edges.items) |existing_edge| {
            if (existing_edge.source_id.eql(edge.source_id) and
                existing_edge.target_id.eql(edge.target_id) and
                existing_edge.edge_type == edge.edge_type)
            {
                // Edge already exists, don't add duplicate
                return;
            }
        }

        try self.edges.append(edge);
    }

    /// Verify model state matches actual system state
    pub fn verify_against_system(self: *Self, storage: *StorageEngine) !void {
        try self.verify_block_consistency(storage);
        try self.verify_edge_consistency(storage);
    }

    /// Verify all blocks in model exist in system with correct content
    fn verify_block_consistency(self: *Self, storage: *StorageEngine) !void {
        var block_iterator = self.blocks.iterator();
        while (block_iterator.next()) |entry| {
            const model_block = entry.value_ptr;

            // Skip deleted blocks
            if (model_block.deleted) {
                // Verify deleted blocks are not findable
                const found = storage.find_block(model_block.id, .temporary) catch |err| switch (err) {
                    error.BlockNotFound => continue, // Expected for deleted blocks
                    else => return err,
                };

                if (found != null) {
                    fatal_assert(false, "Deleted block still findable in system", .{});
                }
                continue;
            }

            // Verify non-deleted blocks are findable
            const system_block = try storage.find_block(model_block.id, .temporary);
            if (system_block == null) {
                fatal_assert(false, "Model block not found in system", .{});
            }

            // Verify content matches
            const actual_hash = ModelBlock.simple_hash(system_block.?.block.content);
            if (actual_hash != model_block.content_hash) {
                fatal_assert(false, "Block content hash mismatch between model and system", .{});
            }

            // Verify version matches
            if (system_block.?.block.version != model_block.version) {
                fatal_assert(false, "Block version mismatch between model and system", .{});
            }
        }
    }

    /// Verify all edges in model exist in system
    fn verify_edge_consistency(self: *Self, storage: *StorageEngine) !void {
        var missing_edges: usize = 0;
        for (self.edges.items) |edge| {
            // Verify both source and target blocks exist (unless deleted)
            if (self.blocks.get(edge.source_id)) |source_block| {
                if (source_block.deleted) continue;
            }
            if (self.blocks.get(edge.target_id)) |target_block| {
                if (target_block.deleted) continue;
            }

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
                missing_edges += 1;
            }
        }

        if (missing_edges > 0) {
            return error.ModelSystemEdgeMismatch;
        }
    }

    /// Count active (non-deleted) blocks in model
    pub fn active_block_count(self: *Self) !u32 {
        var count: u32 = 0;
        var iterator = self.blocks.iterator();
        while (iterator.next()) |entry| {
            if (!entry.value_ptr.deleted) {
                count += 1;
            }
        }
        return count;
    }

    /// Record memtable flush operation
    pub fn record_flush(self: *Self) void {
        self.flush_count += 1;
        self.last_flush_op = self.operation_count;
    }

    /// Get number of operations since last flush
    pub fn operations_since_flush(self: *Self) u32 {
        return @intCast(self.operation_count - self.last_flush_op);
    }

    /// Get total number of edges in model
    pub fn edge_count(self: *Self) u32 {
        return @intCast(self.edges.items.len);
    }

    /// Check if block exists in model and is not deleted
    pub fn has_active_block(self: *Self, block_id: BlockId) bool {
        if (self.blocks.get(block_id)) |block| {
            return !block.deleted;
        }
        return false;
    }

    /// Get block from model if it exists and is active
    pub fn find_active_block(self: *Self, block_id: BlockId) ?ModelBlock {
        if (self.blocks.get(block_id)) |block| {
            if (!block.deleted) {
                return block;
            }
        }
        return null;
    }

    /// Count edges with specific source block
    pub fn count_outgoing_edges(self: *Self, source_id: BlockId) u32 {
        var count: u32 = 0;
        for (self.edges.items) |edge| {
            if (edge.source_id.eql(source_id)) {
                count += 1;
            }
        }
        return count;
    }

    /// Count edges with specific target block
    pub fn count_incoming_edges(self: *Self, target_id: BlockId) u32 {
        var count: u32 = 0;
        for (self.edges.items) |edge| {
            if (edge.target_id.eql(target_id)) {
                count += 1;
            }
        }
        return count;
    }

    /// Find edges from specific source with given type
    /// Note: Returns allocated slice that caller must free
    pub fn find_edges_by_type(self: *Self, source_id: BlockId, edge_type: EdgeType) []GraphEdge {
        var filtered = std.ArrayList(GraphEdge).init(self.allocator);
        defer filtered.deinit();

        // Filter edges matching both source_id and edge_type
        for (self.edges.items) |edge| {
            if (edge.source_id.eql(source_id) and edge.edge_type == edge_type) {
                filtered.append(edge) catch {
                    // On allocation failure, return empty slice
                    return &.{};
                };
            }
        }

        // Return owned slice - caller must free with allocator.free()
        return filtered.toOwnedSlice() catch &.{};
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

    const edge = GraphEdge{
        .source_id = BlockId.from_u64(1),
        .target_id = BlockId.from_u64(2),
        .edge_type = .calls,
    };

    const operation = workload_mod.Operation{
        .op_type = .put_edge,
        .edge = edge,
        .sequence_number = 1,
    };
    try model.apply_operation(&operation);

    // Verify edge was added
    try testing.expectEqual(@as(u32, 1), model.edge_count());
    try testing.expectEqual(@as(u32, 1), model.count_outgoing_edges(edge.source_id));
    try testing.expectEqual(@as(u32, 1), model.count_incoming_edges(edge.target_id));
}

test "model prevents duplicate edges" {
    const allocator = testing.allocator;

    var model = try ModelState.init(allocator);
    defer model.deinit();

    const edge = GraphEdge{
        .source_id = BlockId.from_u64(1),
        .target_id = BlockId.from_u64(2),
        .edge_type = .calls,
    };

    // Add same edge twice
    const op1 = workload_mod.Operation{
        .op_type = .put_edge,
        .edge = edge,
        .sequence_number = 1,
    };
    const op2 = workload_mod.Operation{
        .op_type = .put_edge,
        .edge = edge,
        .sequence_number = 2,
    };

    try model.apply_operation(&op1);
    try model.apply_operation(&op2);

    // Should only have one edge
    try testing.expectEqual(@as(u32, 1), model.edge_count());
}
