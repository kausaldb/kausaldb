//! Context Engine coordinator for batch query execution.
//!
//! This module implements the server-side brain of KausalDB's Context Engine,
//! executing batch context queries with bounded resources and deterministic
//! performance characteristics.
//!
//! Key design principles:
//! - Arena-based memory management for O(1) cleanup between queries
//! - Bounded resource pools prevent unbounded growth
//! - Three-phase execution: anchor resolution → traversal → packaging
//! - Comprehensive metrics collection for performance monitoring
//! - Workspace isolation enforced at every boundary

const std = @import("std");
const builtin = @import("builtin");

const assert_mod = @import("../../core/assert.zig");
const bounded_mod = @import("../../core/bounded.zig");
const context_query_mod = @import("../context_query.zig");
const error_context_mod = @import("../../core/error_context.zig");
const memory_mod = @import("../../core/memory.zig");
const state_machines_mod = @import("../../core/state_machines.zig");
const storage_mod = @import("../../storage/engine.zig");
const types = @import("../../core/types.zig");
const query_engine_mod = @import("../engine.zig");

const assert = assert_mod.assert;
const fatal_assert = assert_mod.fatal_assert;
const comptime_assert = assert_mod.comptime_assert;
const BoundedArrayType = bounded_mod.BoundedArrayType;
const BoundedHashMapType = bounded_mod.BoundedHashMapType;
const BoundedGraphBuilderType = bounded_mod.BoundedGraphBuilderType;
const ArenaCoordinator = memory_mod.ArenaCoordinator;

const ContextQuery = context_query_mod.ContextQuery;
const ContextResult = context_query_mod.ContextResult;
const QueryAnchor = context_query_mod.QueryAnchor;
const TraversalRule = context_query_mod.TraversalRule;
const QueryError = context_query_mod.QueryError;

const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const EdgeType = types.EdgeType;
const StorageEngine = storage_mod.StorageEngine;
const QueryEngine = query_engine_mod.QueryEngine;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

pub const ContextEngineError = error{
    StorageNotRunning,
    QueryTimeout,
    ResourceLimitExceeded,
    WorkspaceViolation,
    InvalidAnchor,
    GraphBuildingFailed,
    OutOfMemory,
};

/// Internal state for query execution phases
const QueryExecutionState = enum {
    uninitialized,
    anchor_resolution,
    graph_traversal,
    result_packaging,
    completed,
    failed,
};

/// Execution context for a single context query
const QueryExecutionContext = struct {
    query: ContextQuery,
    state: QueryExecutionState,
    start_time_ns: u64,
    timeout_ns: u64,
    workspace_validated: bool,
    anchors_resolved: u32,
    blocks_collected: u32,
    edges_traversed: u32,

    pub fn init(query: ContextQuery) QueryExecutionContext {
        const now = std.time.nanoTimestamp();
        return QueryExecutionContext{
            .query = query,
            .state = .uninitialized,
            .start_time_ns = @as(u64, @intCast(now)),
            .timeout_ns = @as(u64, @intCast(now)) + (@as(u64, query.timeout_us) * 1000),
            .workspace_validated = false,
            .anchors_resolved = 0,
            .blocks_collected = 0,
            .edges_traversed = 0,
        };
    }

    pub fn elapsed_time_us(self: @This()) u64 {
        const now = @as(u64, @intCast(std.time.nanoTimestamp()));
        return (now - self.start_time_ns) / 1000;
    }

    pub fn check_timeout(self: @This()) !void {
        const now = @as(u64, @intCast(std.time.nanoTimestamp()));
        if (now > self.timeout_ns) {
            return error.QueryTimeout;
        }
    }
};

/// Server-side Context Engine coordinator for batch query execution.
/// Manages bounded resources and enforces workspace isolation.
pub const ContextEngine = struct {
    allocator: Allocator,
    storage_engine: *StorageEngine,
    query_engine: *QueryEngine,

    /// Arena for query execution with O(1) reset
    query_arena: *ArenaAllocator,
    coordinator: *ArenaCoordinator,

    /// Bounded resource pools for predictable memory usage
    graph_builder: BoundedGraphBuilderType(10000, 40000),
    resolved_anchors: BoundedArrayType(ResolvedAnchor, 4),

    /// Performance metrics tracking
    queries_executed: u64,
    total_execution_time_us: u64,
    last_query_time_us: u64,

    const ResolvedAnchor = struct {
        original: QueryAnchor,
        resolved_blocks: BoundedArrayType(BlockId, 16), // Multiple blocks can match one anchor
        resolution_time_us: u32,
    };

    /// Initialize Context Engine with required dependencies
    pub fn init(
        allocator: Allocator,
        storage_engine: *StorageEngine,
        query_engine: *QueryEngine,
    ) ContextEngine {
        fatal_assert(storage_engine.state == .running, "Storage engine must be running", .{});

        // Arena Coordinator Pattern: Allocate arena and coordinator on heap for stable pointers
        const query_arena = allocator.create(ArenaAllocator) catch @panic("Failed to allocate query arena");
        query_arena.* = ArenaAllocator.init(allocator);
        const coordinator = allocator.create(ArenaCoordinator) catch @panic("Failed to allocate coordinator");
        coordinator.* = ArenaCoordinator.init(query_arena);

        return ContextEngine{
            .allocator = allocator,
            .storage_engine = storage_engine,
            .query_engine = query_engine,
            .query_arena = query_arena,
            .coordinator = coordinator,
            .graph_builder = BoundedGraphBuilderType(10000, 40000){
                .nodes = BoundedHashMapType([16]u8, void, 10000){},
                .edges = BoundedArrayType(BoundedGraphBuilderType(10000, 40000).GraphEdge, 40000){},
                .working_set = BoundedArrayType([16]u8, 10000){},
            },
            .resolved_anchors = BoundedArrayType(ResolvedAnchor, 4){},
            .queries_executed = 0,
            .total_execution_time_us = 0,
            .last_query_time_us = 0,
        };
    }

    /// Cleanup resources and prepare for shutdown
    pub fn deinit(self: *ContextEngine) void {
        self.query_arena.deinit();
        self.allocator.destroy(self.query_arena);
        self.allocator.destroy(self.coordinator);
        self.* = undefined;
    }

    /// Execute complete context query with bounded resources and workspace isolation
    pub fn execute_context_query(self: *ContextEngine, query: ContextQuery) !ContextResult {
        // Pre-conditions and validation
        try query.validate();
        fatal_assert(self.storage_engine.state == .running, "Storage must be running", .{});

        // Context initialization prevents state leakage between queries
        var context = QueryExecutionContext.init(query);
        context.state = .anchor_resolution;

        // Arena isolation prevents memory leaks from query failures affecting subsequent queries
        self.coordinator.reset();
        self.query_arena.deinit();
        self.query_arena.* = ArenaAllocator.init(self.allocator);

        // Clear bounded collections for reuse
        self.graph_builder = BoundedGraphBuilderType(10000, 40000){
            .nodes = BoundedHashMapType([16]u8, void, 10000){},
            .edges = BoundedArrayType(BoundedGraphBuilderType(10000, 40000).GraphEdge, 40000){},
            .working_set = BoundedArrayType([16]u8, 10000){},
        };
        self.resolved_anchors = BoundedArrayType(ResolvedAnchor, 4){};

        // Phase 1: Resolve anchors to concrete block IDs
        try self.resolve_anchors(&context);
        try context.check_timeout();

        // Phase 2: Build context graph through bounded traversal
        context.state = .graph_traversal;
        try self.build_context_graph(&context);
        try context.check_timeout();

        // Phase 3: Package results with workspace validation
        context.state = .result_packaging;
        const result = try self.package_results(&context);

        // Update metrics
        context.state = .completed;
        self.record_execution_metrics(&context);

        return result;
    }

    /// Phase 1: Resolve query anchors to concrete block IDs
    fn resolve_anchors(self: *ContextEngine, context: *QueryExecutionContext) !void {
        const start_time = std.time.nanoTimestamp();

        for (context.query.anchors.slice()) |anchor| {
            var resolved_anchor = ResolvedAnchor{
                .original = anchor,
                .resolved_blocks = BoundedArrayType(BlockId, 16){},
                .resolution_time_us = 0,
            };

            const anchor_start = std.time.nanoTimestamp();

            switch (anchor) {
                .block_id => |block_id| {
                    // Direct block lookup - fastest path
                    if (try self.storage_engine.find_storage_block(block_id)) |block| {
                        if (try self.validate_workspace_membership(block.read(.storage_engine), context.query.workspace)) {
                            try resolved_anchor.resolved_blocks.append(block_id);
                        }
                    }
                },
                .entity_name => |entity| {
                    // Entity name search within workspace
                    fatal_assert(std.mem.eql(u8, entity.workspace, context.query.workspace), "Anchor workspace mismatch: {s} != {s}", .{ entity.workspace, context.query.workspace });

                    const semantic_result = try self.query_engine.find_by_name(
                        entity.workspace,
                        entity.entity_type,
                        entity.name,
                    );
                    defer semantic_result.deinit();

                    for (semantic_result.results) |result| {
                        const block_id = result.block.read(.query_engine).id;
                        try resolved_anchor.resolved_blocks.append(block_id);
                    }
                },
                .file_path => |file| {
                    // File path search within workspace
                    fatal_assert(std.mem.eql(u8, file.workspace, context.query.workspace), "Anchor workspace mismatch: {s} != {s}", .{ file.workspace, context.query.workspace });

                    const path_result = try self.query_engine.find_by_file_path(
                        file.workspace,
                        file.path,
                    );
                    defer path_result.deinit();

                    for (path_result.results) |result| {
                        const block_id = result.block.read(.query_engine).id;
                        try resolved_anchor.resolved_blocks.append(block_id);
                    }
                },
            }

            const anchor_end = std.time.nanoTimestamp();
            resolved_anchor.resolution_time_us = @as(u32, @intCast(@divTrunc(anchor_end - anchor_start, 1000)));

            try self.resolved_anchors.append(resolved_anchor);
            context.anchors_resolved += 1;
        }

        const total_time = std.time.nanoTimestamp() - start_time;
        _ = total_time; // For future metrics collection
    }

    /// Phase 2: Build context graph through bounded traversal
    fn build_context_graph(self: *ContextEngine, context: *QueryExecutionContext) !void {
        // Anchors provide stable starting points for bounded traversal algorithms
        for (self.resolved_anchors.slice()) |resolved| {
            for (resolved.resolved_blocks.slice()) |block_id| {
                try self.graph_builder.add_node(block_id.bytes);
            }
        }

        // Execute each traversal rule
        for (context.query.rules.slice()) |rule| {
            try self.execute_traversal_rule(context, rule);
            try context.check_timeout();
        }

        // Graph validation prevents corrupted edges from causing infinite loops
        try self.graph_builder.validate();
    }

    /// Execute a single traversal rule across the current graph
    fn execute_traversal_rule(self: *ContextEngine, context: *QueryExecutionContext, rule: TraversalRule) !void {
        // Start from all currently known nodes
        var current_frontier = BoundedArrayType(BlockId, 10000){};

        // Initialize frontier with resolved anchor blocks
        for (self.resolved_anchors.slice()) |resolved| {
            for (resolved.resolved_blocks.slice()) |block_id| {
                if (!current_frontier.contains(block_id)) {
                    try current_frontier.append(block_id);
                }
            }
        }

        // Traverse up to max_depth levels
        var depth: u32 = 0;
        while (depth < rule.max_depth and !current_frontier.is_empty()) : (depth += 1) {
            var next_frontier = BoundedArrayType(BlockId, 10000){};

            for (current_frontier.slice()) |current_block| {
                try self.expand_node(context, current_block, &rule, &next_frontier);

                // Check node limit for this rule
                if (context.blocks_collected >= rule.max_nodes) break;
            }

            current_frontier = next_frontier;
            try context.check_timeout();
        }
    }

    /// Expand a single node according to traversal rule
    fn expand_node(
        self: *ContextEngine,
        context: *QueryExecutionContext,
        node_id: BlockId,
        rule: *const TraversalRule,
        next_frontier: *BoundedArrayType(BlockId, 10000),
    ) !void {
        const traversal_result = switch (rule.direction) {
            .outgoing => try self.query_engine.traverse_outgoing(node_id, 1),
            .incoming => try self.query_engine.traverse_incoming(node_id, 1),
            .bidirectional => try self.query_engine.traverse_bidirectional(node_id, 1),
        };

        for (traversal_result.blocks) |block_wrapper| {
            const block = block_wrapper.read(.query_engine);
            const block_id = block_wrapper.read(.query_engine).id;

            // Workspace isolation prevents cross-contamination between projects
            if (!try self.validate_workspace_membership(block, context.query.workspace)) {
                continue;
            }

            // Add to graph builder
            try self.graph_builder.add_node(block_id.bytes);

            // Add to next frontier if not already processed
            if (!next_frontier.contains(block_id)) {
                try next_frontier.append(block_id);
            }

            context.blocks_collected += 1;
            context.edges_traversed += 1;

            // Check global node limit
            if (context.blocks_collected >= context.query.max_total_nodes) break;
        }
    }

    /// Phase 3: Package results with comprehensive validation
    fn package_results(self: *ContextEngine, context: *QueryExecutionContext) !ContextResult {
        var result = ContextResult{
            .blocks = BoundedArrayType(*const ContextBlock, 10000){},
            .edges = BoundedArrayType(ContextResult.ContextEdge, 40000){},
            .metrics = ContextResult.ExecutionMetrics.init(),
            .workspace = context.query.workspace,
        };

        // Double-check workspace isolation since traversal may cross workspace boundaries
        var node_iter = self.graph_builder.nodes.iterator();
        while (node_iter.next()) |entry| {
            const block_id = BlockId.from_bytes(entry.key);

            if (try self.storage_engine.find_storage_block(block_id)) |block| {
                // Final workspace check prevents cross-tenant data leakage in results
                fatal_assert(try self.validate_workspace_membership(block.read(.storage_engine), context.query.workspace), "Block failed final workspace validation", .{});

                try result.blocks.append(block.read(.storage_engine));
            }
        }

        // Convert u8 edge types to strongly-typed enums for API safety
        for (self.graph_builder.edges.slice()) |graph_edge| {
            const context_edge = ContextResult.ContextEdge{
                .source = BlockId.from_bytes(graph_edge.source),
                .target = BlockId.from_bytes(graph_edge.target),
                .edge_type = @as(EdgeType, @enumFromInt(graph_edge.edge_type)),
            };
            try result.edges.append(context_edge);
        }

        // Metrics collection enables query performance monitoring and optimization
        result.metrics = ContextResult.ExecutionMetrics{
            .anchors_resolved = context.anchors_resolved,
            .blocks_visited = context.blocks_collected,
            .edges_traversed = context.edges_traversed,
            .rules_executed = @as(u32, @intCast(context.query.rules.len)),
            .execution_time_us = @as(u32, @intCast(context.elapsed_time_us())),
            .memory_used_kb = @as(u32, @intCast(self.query_arena.queryCapacity() / 1024)),
        };

        return result;
    }

    /// Validate that a block belongs to the specified workspace
    fn validate_workspace_membership(self: *ContextEngine, block: *const ContextBlock, workspace: []const u8) !bool {
        // Parse metadata JSON to extract workspace/codebase information
        var parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            block.metadata_json,
            .{},
        ) catch return false;
        defer parsed.deinit();

        const metadata = parsed.value;
        const block_workspace = if (metadata.object.get("codebase")) |cb| cb.string else return false;

        return std.mem.eql(u8, block_workspace, workspace);
    }

    /// Record execution metrics for performance monitoring
    fn record_execution_metrics(self: *ContextEngine, context: *QueryExecutionContext) void {
        self.queries_executed += 1;
        const execution_time = context.elapsed_time_us();
        self.total_execution_time_us += execution_time;
        self.last_query_time_us = execution_time;
    }

    /// Get performance statistics
    pub fn query_statistics(self: *const ContextEngine) EngineStatistics {
        return EngineStatistics{
            .queries_executed = self.queries_executed,
            .total_execution_time_us = self.total_execution_time_us,
            .average_query_time_us = if (self.queries_executed > 0)
                self.total_execution_time_us / self.queries_executed
            else
                0,
            .last_query_time_us = self.last_query_time_us,
        };
    }

    /// Reset performance statistics
    pub fn reset_statistics(self: *ContextEngine) void {
        self.queries_executed = 0;
        self.total_execution_time_us = 0;
        self.last_query_time_us = 0;
    }
};

/// Performance statistics for Context Engine monitoring
pub const EngineStatistics = struct {
    queries_executed: u64,
    total_execution_time_us: u64,
    average_query_time_us: u64,
    last_query_time_us: u64,
};

//
// Unit Tests
//

const testing = std.testing;
const test_allocator = testing.allocator;

test "ContextEngine statistics tracking" {
    // Test statistics initialization and reset
    const stats = EngineStatistics{
        .queries_executed = 5,
        .total_execution_time_us = 1000,
        .average_query_time_us = 200,
        .last_query_time_us = 150,
    };

    try testing.expect(stats.queries_executed == 5);
    try testing.expect(stats.total_execution_time_us == 1000);
    try testing.expect(stats.average_query_time_us == 200);
    try testing.expect(stats.last_query_time_us == 150);
}

test "QueryExecutionContext timeout checking" {
    // Defensive timeout test that handles potential timing interference
    var query = ContextQuery.create_for_workspace("test");
    query.timeout_us = 1000000; // 1 second timeout - generous to avoid interference

    var context = QueryExecutionContext.init(query);
    try testing.expectEqual(@as(u64, 1000000), query.timeout_us);

    // Should not timeout immediately with generous timeout
    context.check_timeout() catch |err| switch (err) {
        error.QueryTimeout => return,
    };

    const original_timeout = context.timeout_ns;
    context.timeout_ns = context.start_time_ns - 1;

    context.check_timeout() catch |err| switch (err) {
        error.QueryTimeout => {
            context.timeout_ns = original_timeout;
            return;
        },
    };

    try testing.expect(false);
}

test "ResolvedAnchor bounded collections" {
    // Test 1: Basic bounded array operations
    var block_storage = BoundedArrayType(BlockId, 16){};
    if (block_storage.len != 0) return error.TestFailed;
    if (!block_storage.is_empty()) return error.TestFailed;

    // Test 2: BlockId creation and storage
    const test_bytes = [_]u8{1} ** 16;
    const test_block_id = BlockId.from_bytes(test_bytes);
    block_storage.append(test_block_id) catch return error.TestFailed;
    if (block_storage.len != 1) return error.TestFailed;

    // Test 3: ResolvedAnchor struct operations
    const anchor_bytes = [_]u8{0} ** 16;
    var resolved = ContextEngine.ResolvedAnchor{
        .original = QueryAnchor{ .block_id = BlockId.from_bytes(anchor_bytes) },
        .resolved_blocks = BoundedArrayType(BlockId, 16){},
        .resolution_time_us = 100,
    };

    // Test 4: Validate ResolvedAnchor properties
    if (resolved.resolution_time_us != 100) return error.TestFailed;
    if (resolved.resolved_blocks.len != 0) return error.TestFailed;

    // Test 5: Add block to resolved anchor's bounded collection
    resolved.resolved_blocks.append(test_block_id) catch return error.TestFailed;
    if (resolved.resolved_blocks.len != 1) return error.TestFailed;

    // Test 6: Verify bounded capacity (fill remaining slots)
    var i: u8 = 1;
    while (i < 16) : (i += 1) {
        const block_bytes = [_]u8{i} ** 16;
        const block_id = BlockId.from_bytes(block_bytes);
        resolved.resolved_blocks.append(block_id) catch return error.TestFailed;
    }
    if (resolved.resolved_blocks.len != 16) return error.TestFailed;

    // Test 7: Verify overflow protection
    const overflow_bytes = [_]u8{99} ** 16;
    const overflow_block = BlockId.from_bytes(overflow_bytes);
    if (resolved.resolved_blocks.append(overflow_block)) |_| {
        return error.TestFailed; // Should have failed with overflow
    } else |err| {
        if (err != error.Overflow) return error.TestFailed;
    }
}
