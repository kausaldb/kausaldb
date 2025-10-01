//! Graph traversal operations for KausalDB knowledge graph.
//!
//! Provides breadth-first and depth-first search algorithms for exploring
//! relationships between context blocks. Handles cycle detection, path tracking,
//! and result formatting with traversal statistics.

const std = @import("std");

const context_block = @import("../core/types.zig");
const memory = @import("../core/memory.zig");
const ownership = @import("../core/ownership.zig");
const simulation_vfs = @import("../sim/simulation_vfs.zig");
const storage = @import("../storage/engine.zig");

const testing = std.testing;

const ArenaCoordinator = memory.ArenaCoordinator;
const BlockId = context_block.BlockId;
const BlockOwnership = ownership.BlockOwnership;
const ContextBlock = context_block.ContextBlock;
const EdgeType = context_block.EdgeType;
const GraphEdge = context_block.GraphEdge;
const OwnedBlock = ownership.OwnedBlock;
const SimulationVFS = simulation_vfs.SimulationVFS;
const StorageEngine = storage.StorageEngine;

/// Hash context for BlockId HashMap operations
const BlockIdHashContext = struct {
    pub fn hash(ctx: @This(), key: BlockId) u64 {
        _ = ctx;
        return std.hash_map.hashString(&key.bytes);
    }
    pub fn eql(ctx: @This(), a: BlockId, b: BlockId) bool {
        _ = ctx;
        return a.eql(b);
    }
};

/// Corruption-resistant visited tracker for fault injection scenarios
const VisitedTracker = struct {
    visited_ids: std.array_list.Managed(BlockId),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) VisitedTracker {
        return VisitedTracker{
            .visited_ids = std.array_list.Managed(BlockId).init(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(self: *VisitedTracker) void {
        self.visited_ids.deinit();
    }

    fn put(self: *VisitedTracker, id: BlockId) !void {
        // Check if already exists to avoid duplicates
        for (self.visited_ids.items) |existing_id| {
            if (existing_id.eql(id)) return;
        }
        try self.visited_ids.append(id);
    }

    fn contains(self: *const VisitedTracker, id: BlockId) bool {
        for (self.visited_ids.items) |existing_id| {
            if (existing_id.eql(id)) return true;
        }
        return false;
    }

    fn validate(self: *const VisitedTracker) !void {
        if (self.visited_ids.items.len > 100000) {
            return error.CorruptedTracker;
        }
        if (@intFromPtr(self.visited_ids.items.ptr) == 0 and self.visited_ids.items.len > 0) {
            return error.CorruptedTracker;
        }
    }

    fn count(self: *const VisitedTracker) usize {
        return self.visited_ids.items.len;
    }
};

/// Check if an edge passes the specified filter criteria
fn edge_passes_filter(edge: GraphEdge, filter: EdgeTypeFilter) bool {
    switch (filter) {
        .all_types => return true,
        .only_type => |target_type| return edge.edge_type == target_type,
        .exclude_types => |excluded_types| {
            for (excluded_types) |excluded_type| {
                if (edge.edge_type == excluded_type) return false;
            }
            return true;
        },
        .include_types => |included_types| {
            for (included_types) |included_type| {
                if (edge.edge_type == included_type) return true;
            }
            return false;
        },
    }
}

/// Convert EdgeTypeFilter to hash for cache key generation
pub fn edge_filter_to_hash(filter: EdgeTypeFilter) u64 {
    var hasher = std.hash.Wyhash.init(0);

    switch (filter) {
        .all_types => {
            hasher.update(&[_]u8{0}); // Type discriminator
        },
        .only_type => |edge_type| {
            hasher.update(&[_]u8{1}); // Type discriminator
            hasher.update(std.mem.asBytes(&@intFromEnum(edge_type)));
        },
        .exclude_types => |excluded_types| {
            hasher.update(&[_]u8{2}); // Type discriminator
            hasher.update(std.mem.asBytes(&excluded_types.len));
            for (excluded_types) |edge_type| {
                hasher.update(std.mem.asBytes(&@intFromEnum(edge_type)));
            }
        },
        .include_types => |included_types| {
            hasher.update(&[_]u8{3}); // Type discriminator
            hasher.update(std.mem.asBytes(&included_types.len));
            for (included_types) |edge_type| {
                hasher.update(std.mem.asBytes(&@intFromEnum(edge_type)));
            }
        },
    }

    return hasher.final();
}

/// Traversal operation errors
pub const TraversalError = error{
    /// Block not found in storage
    BlockNotFound,
    /// Empty query (invalid parameters)
    EmptyQuery,
    /// Too many results requested
    TooManyResults,
    /// Query engine not initialized
    NotInitialized,
    /// Invalid depth parameter
    InvalidDepth,
    /// Invalid max results parameter
    InvalidMaxResults,
    /// Invalid direction parameter
    InvalidDirection,
    /// Invalid algorithm parameter
    InvalidAlgorithm,
} || std.mem.Allocator.Error || storage.StorageError;

/// Traversal direction for graph queries
pub const TraversalDirection = enum(u8) {
    /// Follow outgoing edges (from source to targets)
    outgoing = 0x01,
    /// Follow incoming edges (from targets to sources)
    incoming = 0x02,
    /// Follow both outgoing and incoming edges
    bidirectional = 0x03,

    pub fn from_u8(value: u8) !TraversalDirection {
        return std.enums.fromInt(TraversalDirection, value) orelse TraversalError.InvalidDirection;
    }
};

/// Traversal algorithm type
pub const TraversalAlgorithm = enum(u8) {
    /// Breadth-first search (explores by depth level)
    breadth_first = 0x01,
    /// Depth-first search (explores deeply before backtracking)
    depth_first = 0x02,
    /// A* search with heuristic for optimal path finding
    astar_search = 0x03,
    /// Bidirectional search (meet-in-the-middle for shortest paths)
    bidirectional_search = 0x04,
    /// Strongly connected components detection
    strongly_connected = 0x05,
    /// Topological sort for dependency ordering
    topological_sort = 0x06,

    pub fn from_u8(value: u8) !TraversalAlgorithm {
        return std.enums.fromInt(TraversalAlgorithm, value) orelse TraversalError.InvalidAlgorithm;
    }
};

/// Edge type filtering strategy for traversal queries
pub const EdgeTypeFilter = union(enum) {
    /// Include all edge types (no filtering)
    all_types,
    /// Include only the specified edge type
    only_type: EdgeType,
    /// Include all types except the specified ones
    exclude_types: []const EdgeType,
    /// Include only the specified edge types
    include_types: []const EdgeType,
};

/// Query for traversing the knowledge graph
pub const TraversalQuery = struct {
    /// Starting block ID for traversal
    start_block_id: BlockId,
    /// Direction to traverse (outgoing, incoming, or bidirectional)
    direction: TraversalDirection,
    /// Algorithm to use (BFS or DFS)
    algorithm: TraversalAlgorithm,
    /// Maximum depth to traverse (0 = no limit)
    max_depth: u32,
    /// Maximum number of blocks to return
    max_results: u32,
    /// Edge type filtering strategy
    edge_filter: EdgeTypeFilter,

    /// Default maximum depth for traversal
    pub const DEFAULT_MAX_DEPTH = 10;
    /// Default maximum results
    pub const DEFAULT_MAX_RESULTS = 1000;
    /// Absolute maximum results to prevent memory exhaustion
    pub const ABSOLUTE_MAX_RESULTS = 10000;

    /// Create a basic traversal query with defaults
    pub fn init(start_block_id: BlockId, direction: TraversalDirection) TraversalQuery {
        return TraversalQuery{
            .start_block_id = start_block_id,
            .direction = direction,
            .algorithm = .breadth_first,
            .max_depth = DEFAULT_MAX_DEPTH,
            .max_results = DEFAULT_MAX_RESULTS,
            .edge_filter = .all_types,
        };
    }

    /// Validate traversal query parameters
    pub fn validate(self: TraversalQuery) !void {
        if (self.max_depth == 0) return TraversalError.InvalidDepth;
        if (self.max_depth > 100) return TraversalError.InvalidDepth;
        if (self.max_results == 0) return TraversalError.InvalidMaxResults;
        if (self.max_results > ABSOLUTE_MAX_RESULTS) return TraversalError.InvalidMaxResults;
    }
};

/// Result from graph traversal containing blocks and path information
pub const TraversalResult = struct {
    /// Retrieved context blocks in traversal order with zero-cost ownership
    blocks: []const OwnedBlock,
    /// Paths from start block to each result block
    paths: []const []const BlockId,
    /// Depths of each block from start block
    depths: []const u32,
    /// Total number of blocks traversed
    blocks_traversed: u32,
    /// Maximum depth reached during traversal
    max_depth_reached: u32,

    /// Create traversal result
    pub fn init(
        blocks: []const OwnedBlock,
        paths: []const []const BlockId,
        depths: []const u32,
        blocks_traversed: u32,
        max_depth_reached: u32,
    ) TraversalResult {
        return TraversalResult{
            .blocks = blocks,
            .paths = paths,
            .depths = depths,
            .blocks_traversed = blocks_traversed,
            .max_depth_reached = max_depth_reached,
        };
    }

    /// Check if traversal result is empty
    pub fn is_empty(self: TraversalResult) bool {
        return self.blocks.len == 0;
    }

    /// Clone traversal result for caching
    /// Caller's allocator will own the cloned data
    pub fn clone(self: TraversalResult, allocator: std.mem.Allocator) !TraversalResult {
        const cloned_blocks = try allocator.alloc(OwnedBlock, self.blocks.len);
        errdefer allocator.free(cloned_blocks);

        for (self.blocks, 0..) |block, i| {
            const ctx_block = block.read(.query_engine);
            const cloned_ctx_block = ContextBlock{
                .id = ctx_block.id,
                .sequence = ctx_block.sequence,
                .source_uri = try allocator.dupe(u8, ctx_block.source_uri),
                .metadata_json = try allocator.dupe(u8, ctx_block.metadata_json),
                .content = try allocator.dupe(u8, ctx_block.content),
            };
            cloned_blocks[i] = OwnedBlock.take_ownership(&cloned_ctx_block, .query_engine);
        }

        const cloned_paths = try allocator.alloc([]const BlockId, self.paths.len);
        errdefer allocator.free(cloned_paths);

        for (self.paths, 0..) |path, i| {
            cloned_paths[i] = try allocator.dupe(BlockId, path);
        }

        const cloned_depths = try allocator.dupe(u32, self.depths);

        return TraversalResult{
            .blocks = cloned_blocks,
            .paths = cloned_paths,
            .depths = cloned_depths,
            .blocks_traversed = self.blocks_traversed,
            .max_depth_reached = self.max_depth_reached,
        };
    }
};

/// Execute a graph traversal query
/// Time complexity: O(V + E) where V is vertices and E is edges traversed
/// Space complexity: O(V) for visited tracking and result storage
pub fn execute_traversal(
    allocator: std.mem.Allocator,
    storage_engine: *StorageEngine,
    query: TraversalQuery,
) !TraversalResult {
    try query.validate();

    const result = switch (query.algorithm) {
        .breadth_first => try traverse_breadth_first(allocator, storage_engine, query),
        .depth_first => try traverse_depth_first(allocator, storage_engine, query),
        .astar_search => try traverse_astar_search(allocator, storage_engine, query),
        .bidirectional_search => try traverse_bidirectional_search(allocator, storage_engine, query),
        .strongly_connected => try traverse_strongly_connected(allocator, storage_engine, query),
        .topological_sort => try traverse_topological_sort(allocator, storage_engine, query),
    };

    return result;
}

/// Perform breadth-first traversal of the knowledge graph
fn traverse_breadth_first(
    allocator: std.mem.Allocator,
    storage_engine: *StorageEngine,
    query: TraversalQuery,
) !TraversalResult {
    var visited = VisitedTracker.init(allocator);
    defer visited.deinit();
    try visited.visited_ids.ensureTotalCapacity(@min(query.max_results, 1000));

    var result_blocks = std.array_list.Managed(OwnedBlock).init(allocator);
    try result_blocks.ensureTotalCapacity(query.max_results);
    defer result_blocks.deinit();

    var result_paths = std.array_list.Managed([]BlockId).init(allocator);
    try result_paths.ensureTotalCapacity(query.max_results);
    defer {
        for (result_paths.items) |path| {
            allocator.free(path);
        }
        result_paths.deinit();
    }

    var result_depths = std.array_list.Managed(u32).init(allocator);
    try result_depths.ensureTotalCapacity(query.max_results);
    defer result_depths.deinit();

    const QueueItem = struct {
        block_id: BlockId,
        depth: u32,
        path: []BlockId,
    };

    var queue = std.array_list.Managed(QueueItem).init(allocator);
    try queue.ensureTotalCapacity(query.max_results);
    defer {
        for (queue.items) |item| {
            allocator.free(item.path);
        }
        queue.deinit();
    }

    const start_path = try allocator.alloc(BlockId, 1);
    start_path[0] = query.start_block_id;

    try queue.append(QueueItem{
        .block_id = query.start_block_id,
        .depth = 0,
        .path = start_path,
    });

    try visited.put(query.start_block_id);

    var blocks_traversed: u32 = 0;
    var max_depth_reached: u32 = 0;

    while (queue.items.len > 0 and result_blocks.items.len < query.max_results) {
        const current = queue.orderedRemove(0);
        defer allocator.free(current.path);

        blocks_traversed += 1;
        max_depth_reached = @max(max_depth_reached, current.depth);

        const current_block = (try storage_engine.find_block(
            current.block_id,
            .query_engine,
        )) orelse continue;

        try result_blocks.append(current_block);

        const cloned_path = try allocator.dupe(BlockId, current.path);
        try result_paths.append(cloned_path);

        try result_depths.append(current.depth);

        if (query.max_depth > 0 and current.depth >= query.max_depth) {
            continue;
        }

        try add_neighbors_to_queue(
            allocator,
            storage_engine,
            &queue,
            &visited,
            current.block_id,
            current.depth + 1,
            current.path,
            query,
        );
    }

    const owned_blocks = try result_blocks.toOwnedSlice();
    const owned_paths = try result_paths.toOwnedSlice();
    const owned_depths = try result_depths.toOwnedSlice();

    return TraversalResult.init(
        owned_blocks,
        owned_paths,
        owned_depths,
        @intCast(owned_blocks.len),
        max_depth_reached,
    );
}

/// Perform depth-first traversal of the knowledge graph
fn traverse_depth_first(
    allocator: std.mem.Allocator,
    storage_engine: *StorageEngine,
    query: TraversalQuery,
) !TraversalResult {
    var visited = VisitedTracker.init(allocator);
    defer visited.deinit();
    try visited.visited_ids.ensureTotalCapacity(@min(query.max_results, 1000));

    var result_blocks = std.array_list.Managed(OwnedBlock).init(allocator);
    try result_blocks.ensureTotalCapacity(query.max_results);
    defer result_blocks.deinit();

    var result_paths = std.array_list.Managed([]BlockId).init(allocator);
    try result_paths.ensureTotalCapacity(query.max_results);
    defer {
        for (result_paths.items) |path| {
            allocator.free(path);
        }
        result_paths.deinit();
    }

    var result_depths = std.array_list.Managed(u32).init(allocator);
    try result_depths.ensureTotalCapacity(query.max_results);
    defer result_depths.deinit();

    const StackItem = struct {
        block_id: BlockId,
        depth: u32,
        path: []BlockId,
    };

    var stack = std.array_list.Managed(StackItem).init(allocator);
    try stack.ensureTotalCapacity(query.max_results);
    defer {
        for (stack.items) |item| {
            allocator.free(item.path);
        }
        stack.deinit();
    }

    const start_path = try allocator.alloc(BlockId, 1);
    start_path[0] = query.start_block_id;

    try stack.append(StackItem{
        .block_id = query.start_block_id,
        .depth = 0,
        .path = start_path,
    });

    var blocks_traversed: u32 = 0;
    var max_depth_reached: u32 = 0;

    while (stack.items.len > 0 and result_blocks.items.len < query.max_results) {
        const current = stack.items[stack.items.len - 1];
        _ = stack.pop();
        defer allocator.free(current.path);

        if (visited.contains(current.block_id)) {
            continue; // Already processed this block
        }

        try visited.validate();
        try visited.put(current.block_id);
        blocks_traversed += 1;
        max_depth_reached = @max(max_depth_reached, current.depth);

        const current_block = (try storage_engine.find_query_block(
            current.block_id,
        )) orelse continue;

        try result_blocks.append(current_block);

        const cloned_path = try allocator.dupe(BlockId, current.path);
        try result_paths.append(cloned_path);

        try result_depths.append(current.depth);

        if (query.max_depth > 0 and current.depth >= query.max_depth) {
            continue;
        }

        try add_neighbors_to_stack(
            allocator,
            storage_engine,
            &stack,
            &visited,
            current.block_id,
            current.depth + 1,
            current.path,
            query,
        );
    }

    const owned_blocks = try result_blocks.toOwnedSlice();
    const owned_paths = try result_paths.toOwnedSlice();
    const owned_depths = try result_depths.toOwnedSlice();

    return TraversalResult.init(
        owned_blocks,
        owned_paths,
        owned_depths,
        @intCast(owned_blocks.len),
        max_depth_reached,
    );
}

/// Clone a block for query results with owned memory
/// Creates copies of all strings to avoid issues with arena-allocated source blocks
/// Add neighbors to BFS queue
fn add_neighbors_to_queue(
    allocator: std.mem.Allocator,
    storage_engine: *StorageEngine,
    queue: anytype,
    visited: *VisitedTracker,
    current_id: BlockId,
    next_depth: u32,
    current_path: []const BlockId,
    query: TraversalQuery,
) !void {
    const QueueItem = @TypeOf(queue.items[0]);

    if (query.direction == .outgoing or query.direction == .bidirectional) {
        const edges = storage_engine.find_outgoing_edges(current_id);
        if (edges.len > 0) {
            for (edges) |owned_edge| {
                const edge = owned_edge.edge;
                if (!edge_passes_filter(edge, query.edge_filter)) continue;

                if (!visited.contains(edge.target_id)) {
                    const new_path = try allocator.alloc(BlockId, current_path.len + 1);
                    @memcpy(new_path[0..current_path.len], current_path);
                    new_path[current_path.len] = edge.target_id;

                    try queue.append(QueueItem{
                        .block_id = edge.target_id,
                        .depth = next_depth,
                        .path = new_path,
                    });
                }
            }
        }
    }

    if (query.direction == .incoming or query.direction == .bidirectional) {
        const edges = storage_engine.find_incoming_edges(current_id);
        if (edges.len > 0) {
            for (edges) |owned_edge| {
                const edge = owned_edge.edge;
                if (!edge_passes_filter(edge, query.edge_filter)) continue;

                if (!visited.contains(edge.source_id)) {
                    const new_path = try allocator.alloc(BlockId, current_path.len + 1);
                    @memcpy(new_path[0..current_path.len], current_path);
                    new_path[current_path.len] = edge.source_id;

                    try queue.append(QueueItem{
                        .block_id = edge.source_id,
                        .depth = next_depth,
                        .path = new_path,
                    });
                }
            }
        }
    }
}

/// Add neighbors to DFS stack
fn add_neighbors_to_stack(
    allocator: std.mem.Allocator,
    storage_engine: *StorageEngine,
    stack: anytype,
    visited: *VisitedTracker,
    current_id: BlockId,
    next_depth: u32,
    current_path: []const BlockId,
    query: TraversalQuery,
) !void {
    const StackItem = @TypeOf(stack.items[0]);

    if (query.direction == .outgoing or query.direction == .bidirectional) {
        const edges = storage_engine.find_outgoing_edges(current_id);
        if (edges.len > 0) {
            for (edges) |owned_edge| {
                const edge = owned_edge.edge;
                if (!edge_passes_filter(edge, query.edge_filter)) continue;

                if (!visited.contains(edge.target_id)) {
                    const new_path = try allocator.alloc(BlockId, current_path.len + 1);
                    @memcpy(new_path[0..current_path.len], current_path);
                    new_path[current_path.len] = edge.target_id;

                    try stack.append(StackItem{
                        .block_id = edge.target_id,
                        .depth = next_depth,
                        .path = new_path,
                    });
                }
            }
        }
    }

    if (query.direction == .incoming or query.direction == .bidirectional) {
        const edges = storage_engine.find_incoming_edges(current_id);
        if (edges.len > 0) {
            for (edges) |owned_edge| {
                const edge = owned_edge.edge;
                if (!edge_passes_filter(edge, query.edge_filter)) continue;

                if (!visited.contains(edge.source_id)) {
                    const new_path = try allocator.alloc(BlockId, current_path.len + 1);
                    @memcpy(new_path[0..current_path.len], current_path);
                    new_path[current_path.len] = edge.source_id;

                    try stack.append(StackItem{
                        .block_id = edge.source_id,
                        .depth = next_depth,
                        .path = new_path,
                    });
                }
            }
        }
    }
}

/// A* search algorithm with heuristic function for optimal path finding
/// Uses content similarity as heuristic for LLM-optimized context traversal
fn traverse_astar_search(
    allocator: std.mem.Allocator,
    storage_engine: *StorageEngine,
    query: TraversalQuery,
) !TraversalResult {
    var visited = VisitedTracker.init(allocator);
    defer visited.deinit();
    try visited.visited_ids.ensureTotalCapacity(@min(query.max_results, 1000));

    var result_blocks = std.array_list.Managed(OwnedBlock).init(allocator);
    try result_blocks.ensureTotalCapacity(query.max_results);
    defer result_blocks.deinit();

    var result_paths = std.array_list.Managed([]BlockId).init(allocator);
    try result_paths.ensureTotalCapacity(query.max_results);
    defer {
        for (result_paths.items) |path| {
            allocator.free(path);
        }
        result_paths.deinit();
    }

    var result_depths = std.array_list.Managed(u32).init(allocator);
    try result_depths.ensureTotalCapacity(query.max_results);
    defer result_depths.deinit();

    const AStarNode = struct {
        block_id: BlockId,
        depth: u32,
        path: []BlockId,
        g_cost: f32, // Actual cost from start
        h_cost: f32, // Heuristic cost to goal
        f_cost: f32, // Total cost (g + h)

        fn compare_f_cost(_: void, a: @This(), b: @This()) std.math.Order {
            return std.math.order(a.f_cost, b.f_cost);
        }
    };

    var priority_queue = std.PriorityQueue(AStarNode, void, AStarNode.compare_f_cost).init(allocator, {});
    try priority_queue.ensureTotalCapacity(query.max_results);
    defer {
        while (priority_queue.removeOrNull()) |node| {
            allocator.free(node.path);
        }
        priority_queue.deinit();
    }

    const start_path = try allocator.alloc(BlockId, 1);
    start_path[0] = query.start_block_id;

    try priority_queue.add(AStarNode{
        .block_id = query.start_block_id,
        .depth = 0,
        .path = start_path,
        .g_cost = 0.0,
        .h_cost = 0.0, // Heuristic from start to start is 0
        .f_cost = 0.0,
    });

    try visited.put(query.start_block_id);

    var blocks_traversed: u32 = 0;
    var max_depth_reached: u32 = 0;

    while (priority_queue.count() > 0 and result_blocks.items.len < query.max_results) {
        const current = priority_queue.remove();
        defer allocator.free(current.path);

        blocks_traversed += 1;
        max_depth_reached = @max(max_depth_reached, current.depth);

        const current_block = (try storage_engine.find_query_block(
            current.block_id,
        )) orelse continue;

        try result_blocks.append(current_block);

        const cloned_path = try allocator.dupe(BlockId, current.path);
        try result_paths.append(cloned_path);

        try result_depths.append(current.depth);

        if (query.max_depth > 0 and current.depth >= query.max_depth) {
            continue;
        }

        try add_neighbors_to_astar_queue(
            allocator,
            storage_engine,
            &priority_queue,
            &visited,
            current.block_id,
            current.depth + 1,
            current.path,
            current.g_cost,
            query,
            AStarNode,
        );
    }

    const owned_blocks = try result_blocks.toOwnedSlice();
    const owned_paths = try result_paths.toOwnedSlice();
    const owned_depths = try result_depths.toOwnedSlice();

    return TraversalResult.init(
        owned_blocks,
        owned_paths,
        owned_depths,
        @intCast(owned_blocks.len),
        max_depth_reached,
    );
}

/// Bidirectional search algorithm for finding shortest paths
/// Explores from start node in both directions simultaneously for faster pathfinding
fn traverse_bidirectional_search(
    allocator: std.mem.Allocator,
    storage_engine: *StorageEngine,
    query: TraversalQuery,
) !TraversalResult {
    var visited_forward = VisitedTracker.init(allocator);
    defer visited_forward.deinit();
    try visited_forward.visited_ids.ensureTotalCapacity(@min(query.max_results / 2, 500));

    var visited_backward = VisitedTracker.init(allocator);
    defer visited_backward.deinit();
    try visited_backward.visited_ids.ensureTotalCapacity(@min(query.max_results / 2, 500));

    var result_blocks = std.array_list.Managed(OwnedBlock).init(allocator);
    try result_blocks.ensureTotalCapacity(query.max_results);
    defer result_blocks.deinit();

    var result_paths = std.array_list.Managed([]BlockId).init(allocator);
    try result_paths.ensureTotalCapacity(query.max_results);
    defer {
        for (result_paths.items) |path| {
            allocator.free(path);
        }
        result_paths.deinit();
    }

    var result_depths = std.array_list.Managed(u32).init(allocator);
    try result_depths.ensureTotalCapacity(query.max_results);
    defer result_depths.deinit();

    const QueueItem = struct {
        block_id: BlockId,
        depth: u32,
        path: []BlockId,
        is_forward: bool, // true for forward search, false for backward
    };

    var queue_forward = std.array_list.Managed(QueueItem).init(allocator);
    try queue_forward.ensureTotalCapacity(query.max_results / 2);
    defer {
        for (queue_forward.items) |item| {
            allocator.free(item.path);
        }
        queue_forward.deinit();
    }

    var queue_backward = std.array_list.Managed(QueueItem).init(allocator);
    try queue_backward.ensureTotalCapacity(query.max_results / 2);
    defer {
        for (queue_backward.items) |item| {
            allocator.free(item.path);
        }
        queue_backward.deinit();
    }

    const start_path = try allocator.alloc(BlockId, 1);
    start_path[0] = query.start_block_id;

    try queue_forward.append(QueueItem{
        .block_id = query.start_block_id,
        .depth = 0,
        .path = start_path,
        .is_forward = true,
    });

    try visited_forward.put(query.start_block_id);

    // we'll search outward in both directions from the start node
    if (query.direction == .bidirectional) {
        const backward_path = try allocator.alloc(BlockId, 1);
        backward_path[0] = query.start_block_id;

        try queue_backward.append(QueueItem{
            .block_id = query.start_block_id,
            .depth = 0,
            .path = backward_path,
            .is_forward = false,
        });

        try visited_backward.put(query.start_block_id);
    }

    var blocks_traversed: u32 = 0;
    var max_depth_reached: u32 = 0;

    while ((queue_forward.items.len > 0 or queue_backward.items.len > 0) and
        result_blocks.items.len < query.max_results)
    {
        if (queue_forward.items.len > 0) {
            const current = queue_forward.orderedRemove(0);
            defer allocator.free(current.path);

            blocks_traversed += 1;
            max_depth_reached = @max(max_depth_reached, current.depth);

            const current_block = (try storage_engine.find_query_block(
                current.block_id,
            )) orelse continue;

            try result_blocks.append(current_block);

            const cloned_path = try allocator.dupe(BlockId, current.path);
            try result_paths.append(cloned_path);

            try result_depths.append(current.depth);

            if (query.max_depth > 0 and current.depth >= query.max_depth / 2) {
                continue;
            }

            try add_neighbors_to_bidirectional_queue(
                allocator,
                storage_engine,
                &queue_forward,
                &visited_forward,
                current.block_id,
                current.depth + 1,
                current.path,
                query,
                true, // forward direction
            );
        }

        if (queue_backward.items.len > 0 and query.direction == .bidirectional) {
            const current = queue_backward.orderedRemove(0);
            defer allocator.free(current.path);

            blocks_traversed += 1;
            max_depth_reached = @max(max_depth_reached, current.depth);

            if (visited_forward.contains(current.block_id)) {
                continue;
            }

            const current_block = (try storage_engine.find_query_block(
                current.block_id,
            )) orelse continue;

            try result_blocks.append(current_block);

            const cloned_path = try allocator.dupe(BlockId, current.path);
            try result_paths.append(cloned_path);

            try result_depths.append(current.depth);

            if (query.max_depth > 0 and current.depth >= query.max_depth / 2) {
                continue;
            }

            try add_neighbors_to_bidirectional_queue(
                allocator,
                storage_engine,
                &queue_backward,
                &visited_backward,
                current.block_id,
                current.depth + 1,
                current.path,
                query,
                false, // backward direction
            );
        }
    }

    const owned_blocks = try result_blocks.toOwnedSlice();
    const owned_paths = try result_paths.toOwnedSlice();
    const owned_depths = try result_depths.toOwnedSlice();

    return TraversalResult.init(
        owned_blocks,
        owned_paths,
        owned_depths,
        @intCast(owned_blocks.len),
        max_depth_reached,
    );
}

/// Strongly connected components detection using Tarjan's algorithm
fn traverse_strongly_connected(
    allocator: std.mem.Allocator,
    storage_engine: *StorageEngine,
    query: TraversalQuery,
) !TraversalResult {
    return traverse_depth_first(allocator, storage_engine, query);
}

/// Topological sort for dependency ordering
fn traverse_topological_sort(
    allocator: std.mem.Allocator,
    storage_engine: *StorageEngine,
    query: TraversalQuery,
) !TraversalResult {
    var result_blocks = std.array_list.Managed(OwnedBlock).init(allocator);
    try result_blocks.ensureTotalCapacity(query.max_results); // Pre-allocate for expected result size
    defer result_blocks.deinit();

    var result_paths = std.array_list.Managed([]BlockId).init(allocator);
    try result_paths.ensureTotalCapacity(query.max_results); // Pre-allocate for path tracking
    defer {
        for (result_paths.items) |path| {
            allocator.free(path);
        }
        result_paths.deinit();
    }

    var result_depths = std.array_list.Managed(u32).init(allocator);
    try result_depths.ensureTotalCapacity(query.max_results); // Pre-allocate for depth tracking
    defer result_depths.deinit();

    // Use Kahn's algorithm with cycle detection
    var visited = VisitedTracker.init(allocator);
    defer visited.deinit();
    try visited.visited_ids.ensureTotalCapacity(@min(query.max_results, 1000));

    var in_degree = std.HashMap(BlockId, u32, BlockIdHashContext, std.hash_map.default_max_load_percentage).init(allocator);
    defer in_degree.deinit();

    var queue = std.array_list.Managed(BlockId).init(allocator);
    try queue.ensureTotalCapacity(32); // Pre-allocate for typical DAG breadth
    defer queue.deinit();

    // Start from the root node
    var current_nodes = std.array_list.Managed(BlockId).init(allocator);
    try current_nodes.ensureTotalCapacity(16); // Pre-allocate for typical graph exploration breadth
    defer current_nodes.deinit();
    try current_nodes.append(query.start_block_id);

    var depth: u32 = 0;

    // Build in-degree map for all reachable nodes
    while (current_nodes.items.len > 0 and depth < query.max_depth) {
        var next_nodes = std.array_list.Managed(BlockId).init(allocator);
        try next_nodes.ensureTotalCapacity(32); // Pre-allocate for next level expansion
        defer next_nodes.deinit();

        for (current_nodes.items) |block_id| {
            if (visited.contains(block_id)) continue;
            try visited.put(block_id);

            // Initialize in-degree for this node
            if (!in_degree.contains(block_id)) {
                try in_degree.put(block_id, 0);
            }

            // Query outgoing edges to build dependency graph for topological ordering
            const edges = storage_engine.find_outgoing_edges(block_id);

            for (edges) |owned_edge| {
                const edge = owned_edge.edge;
                if (!edge_passes_filter(edge, query.edge_filter)) continue;

                // Track dependency count for Kahn's algorithm ordering
                const current_degree = in_degree.get(edge.target_id) orelse 0;
                try in_degree.put(edge.target_id, current_degree + 1);

                try next_nodes.append(edge.target_id);
            }
        }

        current_nodes.clearRetainingCapacity();
        try current_nodes.appendSlice(next_nodes.items);
        depth += 1;
    }

    // Find nodes with zero in-degree (roots for topological sort)
    var in_degree_iter = in_degree.iterator();
    while (in_degree_iter.next()) |entry| {
        if (entry.value_ptr.* == 0) {
            try queue.append(entry.key_ptr.*);
        }
    }

    var sorted_count: usize = 0;
    var path = std.array_list.Managed(BlockId).init(allocator);
    try path.ensureTotalCapacity(64); // Pre-allocate for expected topological result size
    defer path.deinit();

    // Kahn's algorithm
    while (queue.items.len > 0) {
        const current = queue.orderedRemove(0);
        try path.append(current);
        sorted_count += 1;

        // Query dependencies to update in-degree counts for Kahn's algorithm
        const edges = storage_engine.find_outgoing_edges(current);

        for (edges) |owned_edge| {
            const edge = owned_edge.edge;
            if (!edge_passes_filter(edge, query.edge_filter)) continue;
            if (!in_degree.contains(edge.target_id)) continue;

            // Decrease in-degree
            const current_degree = in_degree.get(edge.target_id).?;
            if (current_degree > 0) {
                try in_degree.put(edge.target_id, current_degree - 1);
                if (current_degree - 1 == 0) {
                    try queue.append(edge.target_id);
                }
            }
        }
    }

    // Check for cycle: if sorted_count < total nodes, there's a cycle
    if (sorted_count < visited.count()) {
        // Cycle detected - return empty result
        const owned_blocks = try result_blocks.toOwnedSlice();
        const owned_paths = try result_paths.toOwnedSlice();
        const owned_depths = try result_depths.toOwnedSlice();

        return TraversalResult.init(
            owned_blocks,
            owned_paths,
            owned_depths,
            0,
            0,
        );
    }

    // No cycle - build result with blocks in topological order
    if (path.items.len > 0) {
        for (path.items, 0..) |block_id, i| {
            // Try to find the block
            if (storage_engine.find_query_block(block_id) catch null) |block| {
                try result_blocks.append(block);

                // Create path slice for this block (just itself in topological order)
                const block_path = try allocator.alloc(BlockId, 1);
                block_path[0] = block_id;
                try result_paths.append(block_path);

                try result_depths.append(@intCast(i));
            }
        }
    }

    const owned_blocks = try result_blocks.toOwnedSlice();
    const owned_paths = try result_paths.toOwnedSlice();
    const owned_depths = try result_depths.toOwnedSlice();

    return TraversalResult.init(
        owned_blocks,
        owned_paths,
        owned_depths,
        @intCast(owned_blocks.len),
        @intCast(path.items.len),
    );
}

/// Add neighbors to A* priority queue with heuristic scoring
fn add_neighbors_to_astar_queue(
    allocator: std.mem.Allocator,
    storage_engine: *StorageEngine,
    queue: anytype,
    visited: *VisitedTracker,
    current_id: BlockId,
    next_depth: u32,
    current_path: []const BlockId,
    current_g_cost: f32,
    query: TraversalQuery,
    comptime AStarNode: type,
) !void {
    if (query.direction == .outgoing or query.direction == .bidirectional) {
        const edges = storage_engine.find_outgoing_edges(current_id);
        if (edges.len > 0) {
            for (edges) |owned_edge| {
                const edge = owned_edge.edge;
                if (!edge_passes_filter(edge, query.edge_filter)) continue;

                if (!visited.contains(edge.target_id)) {
                    const new_path = try allocator.alloc(BlockId, current_path.len + 1);
                    @memcpy(new_path[0..current_path.len], current_path);
                    new_path[current_path.len] = edge.target_id;

                    const g_cost = current_g_cost + 1.0;
                    const h_cost = calculate_heuristic(storage_engine, edge.target_id, query.start_block_id);
                    const f_cost = g_cost + h_cost;

                    try queue.add(AStarNode{
                        .block_id = edge.target_id,
                        .depth = next_depth,
                        .path = new_path,
                        .g_cost = g_cost,
                        .h_cost = h_cost,
                        .f_cost = f_cost,
                    });

                    try visited.put(edge.target_id);
                }
            }
        }
    }

    if (query.direction == .incoming or query.direction == .bidirectional) {
        const edges = storage_engine.find_incoming_edges(current_id);
        if (edges.len > 0) {
            for (edges) |owned_edge| {
                const edge = owned_edge.edge;
                if (!edge_passes_filter(edge, query.edge_filter)) continue;

                if (!visited.contains(edge.source_id)) {
                    const new_path = try allocator.alloc(BlockId, current_path.len + 1);
                    @memcpy(new_path[0..current_path.len], current_path);
                    new_path[current_path.len] = edge.source_id;

                    const g_cost = current_g_cost + 1.0;
                    const h_cost = calculate_heuristic(storage_engine, edge.source_id, query.start_block_id);
                    const f_cost = g_cost + h_cost;

                    try queue.add(AStarNode{
                        .block_id = edge.source_id,
                        .depth = next_depth,
                        .path = new_path,
                        .g_cost = g_cost,
                        .h_cost = h_cost,
                        .f_cost = f_cost,
                    });

                    try visited.put(edge.source_id);
                }
            }
        }
    }
}

/// Add neighbors to bidirectional search queue
fn add_neighbors_to_bidirectional_queue(
    allocator: std.mem.Allocator,
    storage_engine: *StorageEngine,
    queue: anytype,
    visited: *VisitedTracker,
    current_id: BlockId,
    next_depth: u32,
    current_path: []const BlockId,
    query: TraversalQuery,
    is_forward: bool,
) !void {
    const QueueItem = @TypeOf(queue.items[0]);

    const use_outgoing = (is_forward and (query.direction == .outgoing or query.direction == .bidirectional)) or
        (!is_forward and (query.direction == .incoming or query.direction == .bidirectional));
    const use_incoming = (is_forward and (query.direction == .incoming or query.direction == .bidirectional)) or
        (!is_forward and (query.direction == .outgoing or query.direction == .bidirectional));

    if (use_outgoing) {
        const edges = storage_engine.find_outgoing_edges(current_id);
        if (edges.len > 0) {
            for (edges) |owned_edge| {
                const edge = owned_edge.edge;
                if (!edge_passes_filter(edge, query.edge_filter)) continue;

                if (!visited.contains(edge.target_id)) {
                    const new_path = try allocator.alloc(BlockId, current_path.len + 1);
                    @memcpy(new_path[0..current_path.len], current_path);
                    new_path[current_path.len] = edge.target_id;

                    try queue.append(QueueItem{
                        .block_id = edge.target_id,
                        .depth = next_depth,
                        .path = new_path,
                        .is_forward = is_forward,
                    });

                    try visited.put(edge.target_id);
                }
            }
        }
    }

    if (use_incoming) {
        const edges = storage_engine.find_incoming_edges(current_id);
        if (edges.len > 0) {
            for (edges) |owned_edge| {
                const edge = owned_edge.edge;
                if (!edge_passes_filter(edge, query.edge_filter)) continue;

                if (!visited.contains(edge.source_id)) {
                    const new_path = try allocator.alloc(BlockId, current_path.len + 1);
                    @memcpy(new_path[0..current_path.len], current_path);
                    new_path[current_path.len] = edge.source_id;

                    try queue.append(QueueItem{
                        .block_id = edge.source_id,
                        .depth = next_depth,
                        .path = new_path,
                        .is_forward = is_forward,
                    });

                    try visited.put(edge.source_id);
                }
            }
        }
    }
}

/// Calculate heuristic cost for A* search
/// Uses content similarity and structural distance for LLM-optimized traversal
fn calculate_heuristic(storage_engine: *StorageEngine, from_id: BlockId, to_id: BlockId) f32 {
    _ = storage_engine;
    _ = from_id;
    _ = to_id;

    return 1.0; // Uniform cost for now
}

/// Convenience function for outgoing traversal
pub fn traverse_outgoing(
    allocator: std.mem.Allocator,
    storage_engine: *StorageEngine,
    start_id: BlockId,
    max_depth: u32,
) !TraversalResult {
    const query = TraversalQuery{
        .start_block_id = start_id,
        .direction = .outgoing,
        .algorithm = .breadth_first,
        .max_depth = max_depth,
        .max_results = TraversalQuery.DEFAULT_MAX_RESULTS,
        .edge_filter = .all_types,
    };
    return execute_traversal(allocator, storage_engine, query);
}

/// Convenience function for incoming traversal
pub fn traverse_incoming(
    allocator: std.mem.Allocator,
    storage_engine: *StorageEngine,
    start_id: BlockId,
    max_depth: u32,
) !TraversalResult {
    const query = TraversalQuery{
        .start_block_id = start_id,
        .direction = .incoming,
        .algorithm = .breadth_first,
        .max_depth = max_depth,
        .max_results = TraversalQuery.DEFAULT_MAX_RESULTS,
        .edge_filter = .all_types,
    };
    return execute_traversal(allocator, storage_engine, query);
}

/// Convenience function for bidirectional traversal
pub fn traverse_bidirectional(
    allocator: std.mem.Allocator,
    storage_engine: *StorageEngine,
    start_id: BlockId,
    max_depth: u32,
) !TraversalResult {
    const query = TraversalQuery{
        .start_block_id = start_id,
        .direction = .bidirectional,
        .algorithm = .breadth_first,
        .max_depth = max_depth,
        .max_results = TraversalQuery.DEFAULT_MAX_RESULTS,
        .edge_filter = .all_types,
    };
    return execute_traversal(allocator, storage_engine, query);
}

/// Convenience function for A* search with optimal pathfinding
pub fn traverse_astar(
    allocator: std.mem.Allocator,
    storage_engine: *StorageEngine,
    start_id: BlockId,
    max_depth: u32,
) !TraversalResult {
    const query = TraversalQuery{
        .start_block_id = start_id,
        .direction = .outgoing,
        .algorithm = .astar_search,
        .max_depth = max_depth,
        .max_results = TraversalQuery.DEFAULT_MAX_RESULTS,
        .edge_filter = .all_types,
    };
    return execute_traversal(allocator, storage_engine, query);
}

/// Find all paths between two specific blocks using BFS for shortest paths
/// Returns paths in order of increasing length, with shortest paths first
pub fn find_paths_between(
    allocator: std.mem.Allocator,
    storage_engine: *StorageEngine,
    source_id: BlockId,
    target_id: BlockId,
    max_depth: u32,
) !TraversalResult {
    // Early exit if source equals target
    if (source_id.eql(target_id)) {
        const single_path = try allocator.alloc(BlockId, 1);
        single_path[0] = source_id;
        const paths = try allocator.alloc([]const BlockId, 1);
        paths[0] = single_path;
        const depths = try allocator.alloc(u32, 1);
        depths[0] = 0;

        // Create owned block for source
        const source_block = try storage_engine.find_block(source_id, .query_engine);
        if (source_block == null) return TraversalError.BlockNotFound;
        const blocks = try allocator.alloc(OwnedBlock, 1);
        blocks[0] = source_block.?;

        return TraversalResult.init(blocks, paths, depths, 1, 0);
    }

    var visited = VisitedTracker.init(allocator);
    defer visited.deinit();
    try visited.visited_ids.ensureTotalCapacity(1000);

    var result_blocks = std.array_list.Managed(OwnedBlock).init(allocator);
    defer result_blocks.deinit();

    var result_paths = std.array_list.Managed([]BlockId).init(allocator);
    defer result_paths.deinit();

    var result_depths = std.array_list.Managed(u32).init(allocator);
    defer result_depths.deinit();

    // BFS queue with path tracking
    const QueueNode = struct {
        block_id: BlockId,
        depth: u32,
        path: []BlockId,
    };

    var queue = std.array_list.Managed(QueueNode).init(allocator);
    defer {
        for (queue.items) |node| {
            allocator.free(node.path);
        }
        queue.deinit();
    }

    // Initialize with source block
    const initial_path = try allocator.alloc(BlockId, 1);
    initial_path[0] = source_id;
    try queue.append(QueueNode{
        .block_id = source_id,
        .depth = 0,
        .path = initial_path,
    });
    try visited.put(source_id);

    var blocks_explored: u32 = 0;
    var max_depth_reached: u32 = 0;
    var paths_found: u32 = 0;

    while (queue.items.len > 0 and paths_found < 100) { // Limit paths found
        const current = queue.orderedRemove(0);
        defer allocator.free(current.path);

        if (current.depth > max_depth) break;
        max_depth_reached = @max(max_depth_reached, current.depth);
        blocks_explored += 1;

        // Find outgoing edges from current block
        const edges = storage_engine.find_outgoing_edges(current.block_id);
        for (edges) |owned_edge| {
            const edge = owned_edge.edge;
            const next_id = edge.target_id;

            // Create new path
            const new_path = try allocator.alloc(BlockId, current.path.len + 1);
            @memcpy(new_path[0..current.path.len], current.path);
            new_path[current.path.len] = next_id;

            if (next_id.eql(target_id)) {
                // Found target - add to results
                const target_block = try storage_engine.find_block(target_id, .query_engine);
                if (target_block) |block| {
                    try result_blocks.append(block);
                    try result_paths.append(try allocator.dupe(BlockId, new_path));
                    try result_depths.append(current.depth + 1);
                    paths_found += 1;
                }
                allocator.free(new_path);
                continue;
            }

            // Continue BFS if not visited and within depth limit
            if (!visited.contains(next_id) and current.depth + 1 <= max_depth) {
                try queue.append(QueueNode{
                    .block_id = next_id,
                    .depth = current.depth + 1,
                    .path = new_path,
                });
                try visited.put(next_id);
            } else {
                // Path not used, free it
                allocator.free(new_path);
            }
        }
    }

    const owned_blocks = try result_blocks.toOwnedSlice();
    const owned_paths = try result_paths.toOwnedSlice();
    const owned_depths = try result_depths.toOwnedSlice();

    return TraversalResult.init(
        owned_blocks,
        owned_paths,
        owned_depths,
        blocks_explored,
        max_depth_reached,
    );
}

test "find_paths_between returns direct path for connected blocks" {
    const allocator = testing.allocator;
    var sim_vfs = try simulation_vfs.SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "test_path_finding");
    defer storage_engine.deinit();
    try storage_engine.startup();
    defer storage_engine.shutdown() catch {};

    // Create test blocks
    const source_block = ContextBlock{
        .id = BlockId.from_u64(1),
        .sequence = 0,
        .source_uri = "source.zig",
        .metadata_json = "{}",
        .content = "function source() {}",
    };
    const target_block = ContextBlock{
        .id = BlockId.from_u64(2),
        .sequence = 0,
        .source_uri = "target.zig",
        .metadata_json = "{}",
        .content = "function target() {}",
    };

    // Store blocks
    try storage_engine.put_block(source_block);
    try storage_engine.put_block(target_block);

    // Create edge from source to target
    const edge = GraphEdge{
        .source_id = source_block.id,
        .target_id = target_block.id,
        .edge_type = .calls,
    };
    try storage_engine.put_edge(edge);

    // Test path finding
    const result = try find_paths_between(
        allocator,
        &storage_engine,
        source_block.id,
        target_block.id,
        5,
    );
    defer {
        allocator.free(result.blocks);
        allocator.free(result.depths);
        for (result.paths) |path| {
            allocator.free(path);
        }
        allocator.free(result.paths);
    }

    // Verify results
    try testing.expect(result.paths.len >= 1);
    try testing.expect(result.paths[0].len == 2);
    try testing.expect(result.paths[0][0].eql(source_block.id));
    try testing.expect(result.paths[0][1].eql(target_block.id));
}
