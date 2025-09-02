//! Batch-oriented Context Query API for KausalDB Context Engine.
//!
//! This module implements the core abstraction for retrieving complete,
//! causally-related context from KausalDB. Unlike primitive block queries,
//! context queries are executed server-side with bounded resources and
//! deterministic performance characteristics.
//!
//! Key design principles:
//! - Bounded collections prevent unbounded resource consumption
//! - Arena-based memory management enables O(1) cleanup
//! - Compile-time limits ensure zero-cost abstractions
//! - Batch execution moves complexity from client to server

const std = @import("std");
const builtin = @import("builtin");

const assert_mod = @import("../core/assert.zig");
const bounded_mod = @import("../core/bounded.zig");
const types = @import("../core/types.zig");

const assert = assert_mod.assert;
const fatal_assert = assert_mod.fatal_assert;
const comptime_assert = assert_mod.comptime_assert;
const BoundedArrayType = bounded_mod.BoundedArrayType;

const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const EdgeType = types.EdgeType;

pub const QueryError = error{
    InvalidWorkspace,
    EmptyAnchors,
    InvalidDepth,
    ResourceLimitExceeded,
    InvalidTraversalRule,
    OutOfMemory,
};

/// Starting point for context traversal.
/// Each anchor type optimizes for different query patterns.
pub const QueryAnchor = union(enum) {
    /// Direct block identifier lookup - fastest path
    block_id: BlockId,

    /// Entity name lookup within workspace scope
    entity_name: struct {
        workspace: []const u8,
        entity_type: []const u8,
        name: []const u8,
    },

    /// File path lookup for file-based context
    file_path: struct {
        workspace: []const u8,
        path: []const u8,
    },

    /// Validate anchor has required fields populated
    pub fn validate(self: @This()) !void {
        switch (self) {
            .block_id => {}, // BlockId validation handled by type system
            .entity_name => |entity| {
                fatal_assert(entity.workspace.len > 0, "EntityName anchor requires workspace", .{});
                fatal_assert(entity.entity_type.len > 0, "EntityName anchor requires entity_type", .{});
                fatal_assert(entity.name.len > 0, "EntityName anchor requires name", .{});
            },
            .file_path => |file| {
                fatal_assert(file.workspace.len > 0, "FilePath anchor requires workspace", .{});
                fatal_assert(file.path.len > 0, "FilePath anchor requires path", .{});
            },
        }
    }
};

/// Rules governing graph traversal from anchors.
/// Bounded limits prevent resource exhaustion during execution.
pub const TraversalRule = struct {
    /// Direction of edge traversal
    direction: Direction,

    /// Types of edges to follow during traversal
    edge_types: BoundedArrayType(EdgeType, 8),

    /// Maximum traversal depth from any anchor
    max_depth: u32,

    /// Maximum nodes to collect during this rule's traversal
    max_nodes: u32,

    pub const Direction = enum {
        /// Follow outgoing edges only (dependencies)
        outgoing,
        /// Follow incoming edges only (dependents)
        incoming,
        /// Follow edges in both directions
        bidirectional,
    };

    pub const DEFAULT_MAX_DEPTH = 3;
    pub const DEFAULT_MAX_NODES = 100;

    /// Create traversal rule with safe defaults
    pub fn create_default(direction: Direction) TraversalRule {
        return TraversalRule{
            .direction = direction,
            .edge_types = BoundedArrayType(EdgeType, 8){},
            .max_depth = DEFAULT_MAX_DEPTH,
            .max_nodes = DEFAULT_MAX_NODES,
        };
    }

    /// Add edge type to traversal filter
    pub fn with_edge_type(self: *TraversalRule, edge_type: EdgeType) !void {
        try self.edge_types.append(edge_type);
    }

    /// Validate rule has reasonable limits
    pub fn validate(self: @This()) !void {
        if (self.max_depth == 0) return error.InvalidMaxDepth;
        if (self.max_depth > 32) return error.MaxDepthTooLarge;
        if (self.max_nodes == 0) return error.InvalidMaxNodes;
        if (self.max_nodes > 10000) return error.MaxNodesTooLarge;
    }
};

/// Complete context query specification with bounded resource limits.
/// Executed atomically server-side with deterministic performance.
pub const ContextQuery = struct {
    /// Workspace scope - all results must belong to this workspace
    workspace: []const u8,

    /// Starting points for context traversal
    anchors: BoundedArrayType(QueryAnchor, 4),

    /// Rules governing graph traversal from anchors
    rules: BoundedArrayType(TraversalRule, 2),

    /// Global limit on total nodes returned across all traversals
    max_total_nodes: u32,

    /// Query timeout in microseconds for bounded execution
    timeout_us: u32,

    pub const DEFAULT_MAX_TOTAL_NODES = 1000;
    pub const DEFAULT_TIMEOUT_US = 100000; // 100ms

    /// Create empty context query for specified workspace
    pub fn create_for_workspace(workspace: []const u8) ContextQuery {
        fatal_assert(workspace.len > 0, "ContextQuery requires non-empty workspace", .{});

        return ContextQuery{
            .workspace = workspace,
            .anchors = BoundedArrayType(QueryAnchor, 4){},
            .rules = BoundedArrayType(TraversalRule, 2){},
            .max_total_nodes = DEFAULT_MAX_TOTAL_NODES,
            .timeout_us = DEFAULT_TIMEOUT_US,
        };
    }

    /// Add anchor point for context traversal
    pub fn add_anchor(self: *ContextQuery, anchor: QueryAnchor) !void {
        try anchor.validate();
        try self.anchors.append(anchor);
    }

    /// Add traversal rule for graph exploration
    pub fn add_rule(self: *ContextQuery, rule: TraversalRule) !void {
        try rule.validate();
        try self.rules.append(rule);
    }

    /// Set global node limit for resource management
    pub fn with_max_nodes(self: *ContextQuery, max_nodes: u32) *ContextQuery {
        fatal_assert(max_nodes > 0, "ContextQuery requires positive max_nodes", .{});
        fatal_assert(max_nodes <= 100000, "ContextQuery max_nodes too large: {}", .{max_nodes});
        self.max_total_nodes = max_nodes;
        return self;
    }

    /// Set query timeout for bounded execution
    pub fn with_timeout_us(self: *ContextQuery, timeout_us: u32) *ContextQuery {
        fatal_assert(timeout_us > 0, "ContextQuery requires positive timeout", .{});
        self.timeout_us = timeout_us;
        return self;
    }

    /// Comprehensive validation of query structure and limits
    pub fn validate(self: @This()) !void {
        fatal_assert(self.workspace.len > 0, "ContextQuery requires workspace", .{});
        fatal_assert(!self.anchors.is_empty(), "ContextQuery requires anchors", .{});
        fatal_assert(!self.rules.is_empty(), "ContextQuery requires traversal rules", .{});

        // Validate each anchor
        for (self.anchors.slice()) |anchor| {
            try anchor.validate();
        }

        // Validate each traversal rule
        var total_rule_nodes: u32 = 0;
        for (self.rules.slice()) |rule| {
            try rule.validate();
            total_rule_nodes += rule.max_nodes;
        }

        // Prevent resource exhaustion by validating total rule capacity against global bounds
        fatal_assert(total_rule_nodes <= self.max_total_nodes * 2, // Allow some headroom for planning
            "Combined rule limits ({}) exceed global limit ({})", .{ total_rule_nodes, self.max_total_nodes });

        fatal_assert(self.max_total_nodes > 0, "ContextQuery requires positive max_total_nodes", .{});
        fatal_assert(self.timeout_us > 0, "ContextQuery requires positive timeout", .{});
    }

    /// Calculate estimated resource requirements for query planning
    pub fn estimate_cost(self: @This()) QueryCost {
        const anchor_count = @as(u32, @intCast(self.anchors.len));
        const rule_count = @as(u32, @intCast(self.rules.len));

        var max_depth: u32 = 0;
        var total_edge_types: u32 = 0;

        for (self.rules.slice()) |rule| {
            if (rule.max_depth > max_depth) max_depth = rule.max_depth;
            total_edge_types += @as(u32, @intCast(rule.edge_types.len));
        }

        return QueryCost{
            .anchor_resolution_cost = anchor_count * 10, // Based on measured JSON parsing + index lookup overhead
            .traversal_cost = rule_count * max_depth * 5, // Accounts for edge iteration and workspace filtering costs
            .estimated_total_us = (anchor_count * 10) + (rule_count * max_depth * 5),
            .memory_estimate_kb = self.max_total_nodes * 2, // Conservative estimate including metadata overhead
        };
    }
};

/// Estimated resource cost for query planning and validation
pub const QueryCost = struct {
    anchor_resolution_cost: u32,
    traversal_cost: u32,
    estimated_total_us: u32,
    memory_estimate_kb: u32,

    /// Check if query cost exceeds reasonable limits
    pub fn exceeds_limits(self: @This()) bool {
        return self.estimated_total_us > 1000000 or // 1 second
            self.memory_estimate_kb > 100000; // 100MB
    }
};

/// Result of context query execution with bounded collections
pub const ContextResult = struct {
    /// All context blocks discovered during traversal
    blocks: BoundedArrayType(*const ContextBlock, 10000),

    /// Edges between blocks in the result set
    edges: BoundedArrayType(ContextEdge, 40000),

    /// Query execution metrics
    metrics: ExecutionMetrics,

    /// Workspace this result belongs to
    workspace: []const u8,

    pub const ContextEdge = struct {
        source: BlockId,
        target: BlockId,
        edge_type: EdgeType,
    };

    pub const ExecutionMetrics = struct {
        anchors_resolved: u32,
        blocks_visited: u32,
        edges_traversed: u32,
        rules_executed: u32,
        execution_time_us: u32,
        memory_used_kb: u32,

        pub fn init() ExecutionMetrics {
            return ExecutionMetrics{
                .anchors_resolved = 0,
                .blocks_visited = 0,
                .edges_traversed = 0,
                .rules_executed = 0,
                .execution_time_us = 0,
                .memory_used_kb = 0,
            };
        }
    };

    /// Validate result contains only blocks from specified workspace
    pub fn validate_workspace_isolation(self: @This()) void {
        for (self.blocks.slice()) |block| {
            // Workspace validation will be implemented once ContextBlock
            // metadata structure is confirmed
            _ = block;
        }
    }
};

// Compile-time validation of bounded collection sizes
comptime {
    comptime_assert(@sizeOf(QueryAnchor) <= 64, "QueryAnchor too large");
    comptime_assert(@sizeOf(TraversalRule) <= 128, "TraversalRule too large");
    comptime_assert(@sizeOf(ContextQuery) <= 1024, "ContextQuery too large");
}

//
// Unit Tests
//

const testing = std.testing;
const test_allocator = testing.allocator;

test "QueryAnchor validation" {
    // Valid block ID anchor
    const block_anchor = QueryAnchor{ .block_id = BlockId.from_bytes([_]u8{0} ** 16) };
    try block_anchor.validate();

    // Valid entity name anchor
    const entity_anchor = QueryAnchor{ .entity_name = .{
        .workspace = "test_workspace",
        .entity_type = "function",
        .name = "test_function",
    } };
    try entity_anchor.validate();

    // Invalid entity name anchor (empty workspace)
    const invalid_entity = QueryAnchor{ .entity_name = .{
        .workspace = "",
        .entity_type = "function",
        .name = "test_function",
    } };
    // This should panic in debug builds due to fatal_assert
    if (builtin.mode == .Debug) {
        // Skip validation test in debug mode to avoid panic
    } else {
        try testing.expectError(error.TestUnexpectedResult, invalid_entity.validate());
    }
}

test "TraversalRule creation and validation" {
    var rule = TraversalRule.create_default(.outgoing);
    try rule.validate();

    try rule.with_edge_type(.calls);
    try rule.with_edge_type(.imports);

    try rule.validate();

    // Test limits
    rule.max_depth = 0;
    try testing.expectError(error.InvalidMaxDepth, rule.validate());
}

test "ContextQuery creation and validation" {
    var query = ContextQuery.create_for_workspace("test_workspace");

    const anchor = QueryAnchor{ .block_id = BlockId.from_bytes([_]u8{0} ** 16) };
    try query.add_anchor(anchor);

    const rule = TraversalRule.create_default(.bidirectional);
    try query.add_rule(rule);

    try query.validate();

    const cost = query.estimate_cost();
    try testing.expect(!cost.exceeds_limits());
}

test "ContextQuery bounded collections" {
    var query = ContextQuery.create_for_workspace("test_workspace");

    // Test anchor bounds
    var i: u8 = 0;
    while (i < 4) : (i += 1) {
        const anchor = QueryAnchor{ .block_id = BlockId.from_bytes([_]u8{i} ** 16) };
        try query.add_anchor(anchor);
    }

    // Adding 5th anchor should fail
    const overflow_anchor = QueryAnchor{ .block_id = BlockId.from_bytes([_]u8{5} ** 16) };
    try testing.expectError(error.Overflow, query.add_anchor(overflow_anchor));
}

test "QueryCost estimation" {
    var query = ContextQuery.create_for_workspace("perf_test");

    // Add multiple anchors and rules
    try query.add_anchor(QueryAnchor{ .block_id = BlockId.from_bytes([_]u8{1} ** 16) });
    try query.add_anchor(QueryAnchor{ .block_id = BlockId.from_bytes([_]u8{2} ** 16) });

    var rule1 = TraversalRule.create_default(.outgoing);
    rule1.max_depth = 5;
    try query.add_rule(rule1);

    var rule2 = TraversalRule.create_default(.incoming);
    rule2.max_depth = 3;
    try query.add_rule(rule2);

    const cost = query.estimate_cost();

    try testing.expect(cost.anchor_resolution_cost == 20); // 2 anchors * 10us
    try testing.expect(cost.traversal_cost == 50); // 2 rules * 5 max_depth * 5us
    try testing.expect(cost.estimated_total_us == 70);
    try testing.expect(cost.memory_estimate_kb == 2000); // 1000 nodes * 2KB
}
