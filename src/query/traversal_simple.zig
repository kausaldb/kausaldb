//! Simplified graph traversal for KausalDB knowledge graph.
//!
//! Focused on the core v0.1.0 use case: finding direct callers/callees and
//! tracing simple dependency chains using bounded breadth-first search.
//!
//! Philosophy: One algorithm, well-implemented, covers 95% of user needs.
//! Complex algorithms (A*, SCC, topological sort) can be added later if needed.

const std = @import("std");

const context_block = @import("../core/types.zig");
const ownership = @import("../core/ownership.zig");
const storage = @import("../storage/engine.zig");
const assert_mod = @import("../core/assert.zig");

const assert = assert_mod.assert;
const testing = std.testing;

const BlockId = context_block.BlockId;
const ContextBlock = context_block.ContextBlock;
const EdgeType = context_block.EdgeType;
const GraphEdge = context_block.GraphEdge;
const OwnedBlock = ownership.OwnedBlock;
const StorageEngine = storage.StorageEngine;

/// Simple traversal query - only the essential parameters
pub const TraversalQuery = struct {
    /// Starting point for traversal
    start_block_id: BlockId,
    /// Edge types to follow (e.g., CALLS, IMPORTS)
    edge_types: []const EdgeType,
    /// Maximum depth to traverse (prevents infinite loops)
    max_depth: u32 = 10,
    /// Maximum results to return (prevents memory exhaustion)
    max_results: u32 = 1000,
    /// Direction to traverse (forward = following edges, backward = reverse edges)
    direction: TraversalDirection = .forward,

    pub const TraversalDirection = enum {
        forward, // Follow edges from source to target
        backward, // Follow edges from target to source (find callers)
    };
};

/// Simple traversal result containing found blocks and basic statistics
pub const TraversalResult = struct {
    /// Blocks found during traversal in breadth-first order
    blocks: []const OwnedBlock,
    /// Simple statistics about the traversal
    stats: TraversalStats,
    /// Arena allocator used for this result - caller must manage lifetime
    arena_allocator: std.mem.Allocator,

    pub const TraversalStats = struct {
        blocks_visited: u32,
        max_depth_reached: u32,
        edges_followed: u32,
        traversal_time_ns: u64,
    };

    /// Free all memory associated with this result
    pub fn deinit(self: TraversalResult) void {
        // Blocks are owned by the arena and will be freed when arena is reset
        // Stats are value types, no cleanup needed
        _ = self;
    }
};

/// Breadth-first search traversal engine
pub const TraversalEngine = struct {
    storage_engine: *StorageEngine,
    allocator: std.mem.Allocator,

    pub fn init(storage_engine: *StorageEngine, allocator: std.mem.Allocator) TraversalEngine {
        return TraversalEngine{
            .storage_engine = storage_engine,
            .allocator = allocator,
        };
    }

    /// Execute breadth-first traversal from the specified starting point
    pub fn execute_traversal(
        self: *TraversalEngine,
        query: TraversalQuery,
        result_arena: std.mem.Allocator,
    ) !TraversalResult {
        const start_time = std.time.nanoTimestamp();

        // Initialize BFS data structures
        var visited = std.AutoHashMap(BlockId, void).init(self.allocator);
        defer visited.deinit();

        var queue = std.array_list.Managed(QueueItem).init(self.allocator);
        defer queue.deinit();

        var result_blocks = std.array_list.Managed(OwnedBlock).init(result_arena);

        // Statistics tracking
        var stats = TraversalResult.TraversalStats{
            .blocks_visited = 0,
            .max_depth_reached = 0,
            .edges_followed = 0,
            .traversal_time_ns = 0,
        };

        // Start with the initial block
        const start_item = QueueItem{ .block_id = query.start_block_id, .depth = 0 };
        try queue.append(start_item);
        try visited.put(query.start_block_id, {});

        // BFS main loop
        while (queue.items.len > 0 and result_blocks.items.len < query.max_results) {
            const current_item = queue.orderedRemove(0); // Remove from front (BFS)

            // Check depth limit
            if (current_item.depth > query.max_depth) {
                continue;
            }

            stats.max_depth_reached = @max(stats.max_depth_reached, current_item.depth);
            stats.blocks_visited += 1;

            // Find the current block in storage
            if (try self.storage_engine.find_block_for_query_engine(current_item.block_id)) |owned_block| {
                try result_blocks.append(owned_block);

                // Find edges from this block and add neighbors to queue
                if (current_item.depth < query.max_depth) {
                    const neighbors_added = try self.add_neighbors_to_queue(
                        &queue,
                        &visited,
                        current_item.block_id,
                        current_item.depth + 1,
                        query.edge_types,
                        query.direction,
                    );
                    stats.edges_followed += neighbors_added;
                }
            }
        }

        const end_time = std.time.nanoTimestamp();
        stats.traversal_time_ns = if (end_time >= start_time)
            @as(u64, @intCast(end_time - start_time))
        else
            0;

        return TraversalResult{
            .blocks = result_blocks.items,
            .stats = stats,
            .arena_allocator = result_arena,
        };
    }

    /// Add neighboring blocks to the BFS queue
    fn add_neighbors_to_queue(
        self: *TraversalEngine,
        queue: *std.array_list.Managed(QueueItem),
        visited: *std.AutoHashMap(BlockId, void),
        current_block_id: BlockId,
        next_depth: u32,
        edge_types: []const EdgeType,
        direction: TraversalQuery.TraversalDirection,
    ) !u32 {
        var neighbors_added: u32 = 0;

        // Get edges for the current block
        const edges = try self.storage_engine.get_edges_for_block(current_block_id);
        defer {
            for (edges) |edge| {
                // Free each edge if they're allocated
                _ = edge;
            }
            self.allocator.free(edges);
        }

        // Process each edge
        for (edges) |edge| {
            // Check if this edge type is in our filter
            var should_follow = false;
            for (edge_types) |allowed_type| {
                if (edge.edge_type == allowed_type) {
                    should_follow = true;
                    break;
                }
            }

            if (!should_follow) continue;

            // Determine the target block based on direction
            const target_block_id = switch (direction) {
                .forward => edge.target_id, // Follow edge normally
                .backward => edge.source_id, // Follow edge in reverse
            };

            // Skip if already visited
            if (visited.contains(target_block_id)) {
                continue;
            }

            // Add to queue and mark as visited
            const queue_item = QueueItem{ .block_id = target_block_id, .depth = next_depth };
            try queue.append(queue_item);
            try visited.put(target_block_id, {});
            neighbors_added += 1;
        }

        return neighbors_added;
    }
};

/// Simple queue item for BFS traversal
const QueueItem = struct {
    block_id: BlockId,
    depth: u32,
};

// Tests
test "TraversalEngine basic BFS functionality" {
    // This would normally use a real storage engine
    // For now, just test that the structures compile and can be initialized

    const query = TraversalQuery{
        .start_block_id = BlockId.generate(),
        .edge_types = &[_]EdgeType{.calls},
        .max_depth = 5,
        .max_results = 100,
        .direction = .forward,
    };

    // Verify query structure
    try testing.expectEqual(@as(u32, 5), query.max_depth);
    try testing.expectEqual(@as(u32, 100), query.max_results);
    try testing.expectEqual(TraversalQuery.TraversalDirection.forward, query.direction);
}

test "QueueItem creation" {
    const block_id = BlockId.generate();
    const item = QueueItem{ .block_id = block_id, .depth = 3 };

    try testing.expect(item.block_id.eql(block_id));
    try testing.expectEqual(@as(u32, 3), item.depth);
}
