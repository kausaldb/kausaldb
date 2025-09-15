//! Test utilities for KausalDB testing framework.
//!
//! Provides reusable test data generation, validation helpers, and common
//! testing patterns. Centralizes test data creation to ensure consistency
//! across different test suites and enable systematic property testing.
//!
//! Design rationale: Separating test utilities from production code maintains
//! clear boundaries while enabling comprehensive testing of all components.

const std = @import("std");
const testing = std.testing;

const types = @import("../core/types.zig");
const assert_mod = @import("../core/assert.zig");

const log = std.log.scoped(.test_utils);

const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const GraphEdge = types.GraphEdge;
const EdgeType = types.EdgeType;

const assert_fmt = assert_mod.assert_fmt;
const fatal_assert = assert_mod.fatal_assert;

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
            "{{\"test_id\":{d},\"type\":\"test_block\",\"seed\":{d}}}",
            .{ id_seed, id_seed },
        );

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "test://block/{d}",
            .{id_seed},
        );

        return ContextBlock{
            .id = create_deterministic_block_id(id_seed),
            .version = 1,
            .source_uri = uri,
            .metadata_json = metadata,
            .content = content,
        };
    }

    /// Create test edge with deterministic relationship
    pub fn create_test_edge(self: *TestDataGenerator, source_seed: u32, target_seed: u32, edge_type: EdgeType) GraphEdge {
        _ = self; // Suppress unused warning
        return GraphEdge{
            .source_id = create_deterministic_block_id(source_seed),
            .target_id = create_deterministic_block_id(target_seed),
            .edge_type = edge_type,
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

    /// Create graph structure for testing traversal
    pub fn create_test_graph(self: *TestDataGenerator, node_count: u32, edge_count: u32) !TestGraph {
        const blocks = try self.allocator.alloc(ContextBlock, node_count);
        const edges = try self.allocator.alloc(GraphEdge, edge_count);

        // Create nodes
        for (blocks, 0..) |*block, i| {
            block.* = try self.create_test_block(@as(u32, @intCast(i + 1)));
        }

        // Create edges with random connections
        const random = self.prng.random();
        for (edges) |*edge| {
            const source_idx = random.intRangeAtMost(u32, 0, node_count - 1);
            var target_idx = random.intRangeAtMost(u32, 0, node_count - 1);

            // Avoid self-loops
            while (target_idx == source_idx and node_count > 1) {
                target_idx = random.intRangeAtMost(u32, 0, node_count - 1);
            }

            edge.* = GraphEdge{
                .source_id = blocks[source_idx].id,
                .target_id = blocks[target_idx].id,
                .edge_type = pick_random_edge_type(&random),
            };
        }

        return TestGraph{
            .blocks = blocks,
            .edges = edges,
        };
    }

    /// Generate realistic content for test blocks
    pub fn generate_realistic_content(self: *TestDataGenerator, content_type: ContentType) ![]const u8 {
        const random = self.prng.random();

        return switch (content_type) {
            .zig_function => try std.fmt.allocPrint(
                self.allocator,
                "pub fn test_function_{d}() void {{\n    // Test function implementation\n    const value = {};\n    assert(value > 0);\n}}",
                .{ random.int(u32), random.int(u16) },
            ),
            .rust_struct => try std.fmt.allocPrint(
                self.allocator,
                "pub struct TestStruct{d} {{\n    field_a: u32,\n    field_b: String,\n    field_c: Vec<i32>,\n}}",
                .{random.int(u32)},
            ),
            .python_class => try std.fmt.allocPrint(
                self.allocator,
                "class TestClass{d}:\n    def __init__(self, value):\n        self.value = value\n    \n    def method(self):\n        return self.value * {}",
                .{ random.int(u32), random.int(u8) + 1 },
            ),
            .plain_text => try std.fmt.allocPrint(
                self.allocator,
                "This is test content block {d} with random data {}. It contains multiple lines\nand represents typical documentation or comment content.",
                .{ random.int(u32), random.int(u64) },
            ),
        };
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

    pub fn cleanup_test_graph(self: *TestDataGenerator, graph: TestGraph) void {
        self.cleanup_test_data(graph.blocks);
        self.allocator.free(graph.edges);
    }
};

/// Test graph structure for graph testing
pub const TestGraph = struct {
    blocks: []ContextBlock,
    edges: []GraphEdge,
};

/// Content types for realistic test data generation
pub const ContentType = enum {
    zig_function,
    rust_struct,
    python_class,
    plain_text,
};

/// Create deterministic block ID from seed for reproducible tests
pub fn create_deterministic_block_id(seed: u32) BlockId {
    // Simple deterministic ID generation using seed directly
    return BlockId.from_u64(@as(u64, seed) * 0x1234567890ABCDEF + 0xFEDCBA0987654321);
}

/// Validate test block has expected structure
pub fn validate_test_block_structure(block: *const ContextBlock) void {
    fatal_assert(block.content.len > 0, "Test block must have content", .{});
    fatal_assert(block.metadata_json.len > 0, "Test block must have metadata", .{});
    fatal_assert(block.source_uri.len > 0, "Test block must have source URI", .{});
    fatal_assert(block.version > 0, "Test block must have positive version", .{});
    fatal_assert(!block.id.eql(BlockId.zero()), "Test block must have non-zero ID", .{});
}

/// Validate test edge has expected structure
pub fn validate_test_edge_structure(edge: *const GraphEdge) void {
    fatal_assert(!edge.source_id.eql(BlockId.zero()), "Test edge must have non-zero source ID", .{});
    fatal_assert(!edge.target_id.eql(BlockId.zero()), "Test edge must have non-zero target ID", .{});
    fatal_assert(!edge.source_id.eql(edge.target_id), "Test edge cannot be self-loop", .{});
}

/// Compare two blocks for equality in tests
pub fn blocks_equal(a: *const ContextBlock, b: *const ContextBlock) bool {
    return a.id.eql(b.id) and
        a.version == b.version and
        std.mem.eql(u8, a.source_uri, b.source_uri) and
        std.mem.eql(u8, a.metadata_json, b.metadata_json) and
        std.mem.eql(u8, a.content, b.content);
}

/// Compare two edges for equality in tests
pub fn edges_equal(a: *const GraphEdge, b: *const GraphEdge) bool {
    return a.source_id.eql(b.source_id) and
        a.target_id.eql(b.target_id) and
        a.edge_type == b.edge_type;
}

/// Calculate simple content hash for test verification
pub fn calculate_content_hash(content: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0x123456789ABCDEF0);
    hasher.update(content);
    return hasher.final();
}

/// Measure operation duration for performance testing
pub fn measure_operation_duration(comptime operation: anytype, args: anytype) !u64 {
    const start = std.time.nanoTimestamp();
    try @call(.auto, operation, args);
    const end = std.time.nanoTimestamp();
    return @as(u64, @intCast(end - start));
}

/// Pick random edge type for graph generation
fn pick_random_edge_type(random: *std.Random) EdgeType {
    const edge_types = [_]EdgeType{ .imports, .calls, .defines, .references };
    const index = random.intRangeAtMost(usize, 0, edge_types.len - 1);
    return edge_types[index];
}

/// Test assertion helpers
pub const TestAssertions = struct {
    /// Assert operation completes within time bound
    pub fn assert_operation_fast(duration_ns: u64, max_duration_ns: u64, operation_name: []const u8) void {
        if (duration_ns > max_duration_ns) {
            fatal_assert(false, "{s} took {d}ns, expected <{d}ns", .{ operation_name, duration_ns, max_duration_ns });
        }
    }

    /// Assert memory usage is within bounds
    pub fn assert_memory_bounded(current_bytes: u64, max_bytes: u64, context: []const u8) void {
        if (current_bytes > max_bytes) {
            fatal_assert(false, "{s} memory usage {d} bytes exceeds limit {d} bytes", .{ context, current_bytes, max_bytes });
        }
    }

    /// Assert block count is reasonable
    pub fn assert_block_count_reasonable(count: u32, max_count: u32, context: []const u8) void {
        if (count > max_count) {
            fatal_assert(false, "{s} block count {d} exceeds reasonable limit {d}", .{ context, count, max_count });
        }
    }
};

// Test configuration constants
pub const TestConstants = struct {
    pub const DEFAULT_TEST_TIMEOUT_NS: u64 = 30 * std.time.ns_per_s; // 30 seconds
    pub const FAST_OPERATION_THRESHOLD_NS: u64 = 1000; // 1µs
    pub const SLOW_OPERATION_THRESHOLD_NS: u64 = 100_000; // 100µs
    pub const MAX_TEST_MEMORY_BYTES: u64 = 100 * 1024 * 1024; // 100MB
    pub const MAX_TEST_BLOCK_COUNT: u32 = 10_000;
    pub const DEFAULT_BATCH_SIZE: u32 = 100;
};
