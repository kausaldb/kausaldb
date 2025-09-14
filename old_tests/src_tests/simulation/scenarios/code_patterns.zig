//! Code pattern generators for realistic graph structures in simulation testing
//!
//! Generates blocks and edges that represent actual code relationships:
//! deep call chains, library dependencies, circular imports, etc.
//! Used to test system behavior under realistic workloads.

const std = @import("std");
const log = std.log.scoped(.code_patterns);

const storage_engine_mod = @import("../../../storage/engine.zig");
const types = @import("../../../core/types.zig");

const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const EdgeType = types.EdgeType;
const GraphEdge = types.GraphEdge;
const StorageEngine = storage_engine_mod.StorageEngine;

/// Generates realistic code graph structures for simulation testing
pub const CodePatternGenerator = struct {
    allocator: std.mem.Allocator,
    storage_engine: *StorageEngine,
    seed: u64,
    block_counter: u32,
    allocated_strings: std.array_list.Managed([]u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, storage_engine: *StorageEngine, seed: u64) Self {
        return Self{
            .allocator = allocator,
            .storage_engine = storage_engine,
            .seed = seed,
            .block_counter = 1,
            .allocated_strings = std.array_list.Managed([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.allocated_strings.items) |string| {
            self.allocator.free(string);
        }
        self.allocated_strings.deinit();
    }

    /// Helper to allocate and track strings for automatic cleanup
    fn alloc_string(self: *Self, comptime fmt: []const u8, args: anytype) ![]u8 {
        const string = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.allocated_strings.append(string);
        return string;
    }

    /// Generate deep call chain typical of monolithic codebases
    /// Creates main -> level_1 -> level_2 -> ... -> level_depth call chain
    pub fn generate_monolithic_blocks(self: *Self, depth: u32) !void {
        var prng = std.Random.DefaultPrng.init(self.seed + self.block_counter);
        const random = prng.random();

        log.info("Generating monolithic call chain with depth {}", .{depth});

        // Block 0: main entry point
        const main_id = self.next_block_id();
        const main_block = ContextBlock{
            .id = main_id,
            .version = 1,
            .source_uri = "main.zig",
            .metadata_json = "{\"function\":\"main\",\"type\":\"entry_point\"}",
            .content = "pub fn main() !void { try call_level_1(); }",
        };
        try self.storage_engine.put_block(main_block);

        var previous_id = main_id;

        // Generate deep call chain
        for (1..depth + 1) |i| {
            const level_id = self.next_block_id();
            const next_level = if (i == depth) 0 else i + 1; // Last level calls nothing

            const content = if (i == depth)
                try self.alloc_string("fn call_level_{}() void {{ /* leaf function */ }}", .{i})
            else
                try self.alloc_string("fn call_level_{}() void {{ call_level_{}(); }}", .{ i, next_level });

            const level_block = ContextBlock{
                .id = level_id,
                .version = 1,
                .source_uri = try self.alloc_string("level_{}.zig", .{i}),
                .metadata_json = try self.alloc_string("{{\"function\":\"call_level_{}\",\"depth\":{}}}", .{ i, i }),
                .content = content,
            };
            try self.storage_engine.put_block(level_block);

            // Create call edge from previous level
            const call_edge = GraphEdge{
                .source_id = previous_id,
                .target_id = level_id,
                .edge_type = .calls,
            };
            try self.storage_engine.put_edge(call_edge);

            previous_id = level_id;

            // Add some randomness to make patterns more realistic
            if (random.boolean() and i > 1) {
                // Occasionally add a utility function call
                const util_id = self.next_block_id();
                const util_block = ContextBlock{
                    .id = util_id,
                    .version = 1,
                    .source_uri = try self.alloc_string("util_{}.zig", .{i}),
                    .metadata_json = "{\"type\":\"utility\"}",
                    .content = "pub fn utility() void { /* helper function */ }",
                };
                try self.storage_engine.put_block(util_block);

                const util_edge = GraphEdge{
                    .source_id = level_id,
                    .target_id = util_id,
                    .edge_type = .calls,
                };
                try self.storage_engine.put_edge(util_edge);
            }
        }

        log.info("Generated {} blocks in monolithic pattern", .{depth + 1});
    }

    /// Generate library fanout pattern where many modules depend on central utility
    /// Typical of popular library usage in codebases
    pub fn generate_library_fanout(self: *Self, center_id: u32, fanout: u32) !void {
        log.info("Generating library fanout: center={}, fanout={}", .{ center_id, fanout });

        // Central utility module that many others depend on
        const center_block_id = BlockId{ .bytes = int_to_block_id_bytes(center_id) };
        const center_block = ContextBlock{
            .id = center_block_id,
            .version = 1,
            .source_uri = "utility.zig",
            .metadata_json = "{\"type\":\"library\",\"popularity\":\"high\"}",
            .content = "pub fn utility_function() void {} pub const CONSTANT = 42;",
        };
        try self.storage_engine.put_block(center_block);

        // Generate dependents that import the central utility
        for (0..fanout) |i| {
            const dependent_id = center_id + 1 + @as(u32, @intCast(i));
            const dependent_block_id = BlockId{ .bytes = int_to_block_id_bytes(dependent_id) };

            const content = try self.alloc_string("const util = @import(\"utility.zig\"); pub fn feature_{}() void {{ util.utility_function(); }}", .{i});

            const dependent_block = ContextBlock{
                .id = dependent_block_id,
                .version = 1,
                .source_uri = try self.alloc_string("feature_{}.zig", .{i}),
                .metadata_json = try self.alloc_string("{{\"feature\":{}}}", .{i}),
                .content = content,
            };
            try self.storage_engine.put_block(dependent_block);

            // Create import edge from dependent to center
            const import_edge = GraphEdge{
                .source_id = dependent_block_id,
                .target_id = center_block_id,
                .edge_type = .imports,
            };
            try self.storage_engine.put_edge(import_edge);

            // Some dependents also call functions from the utility
            if (i % 2 == 0) {
                const call_edge = GraphEdge{
                    .source_id = dependent_block_id,
                    .target_id = center_block_id,
                    .edge_type = .calls,
                };
                try self.storage_engine.put_edge(call_edge);
            }
        }

        log.info("Generated library fanout with {} dependents", .{fanout});
    }

    /// Generate circular import pattern that can cause issues
    pub fn generate_circular_imports(self: *Self, cycle_size: u32) !void {
        log.info("Generating circular import cycle of size {}", .{cycle_size});

        var block_ids = try self.allocator.alloc(BlockId, cycle_size);
        defer self.allocator.free(block_ids);

        // Create all blocks first
        for (0..cycle_size) |i| {
            const block_id = self.next_block_id();
            block_ids[i] = block_id;

            const content = try self.alloc_string("// Part {} of circular dependency\npub fn function_{}() void {{ /* implementation */ }}", .{ i, i });

            const block = ContextBlock{
                .id = block_id,
                .version = 1,
                .source_uri = try self.alloc_string("cycle_{}.zig", .{i}),
                .metadata_json = try self.alloc_string("{{\"cycle_position\":{}}}", .{i}),
                .content = content,
            };
            try self.storage_engine.put_block(block);
        }

        // Create circular import edges
        for (0..cycle_size) |i| {
            const next_i = (i + 1) % cycle_size;
            const import_edge = GraphEdge{
                .source_id = block_ids[i],
                .target_id = block_ids[next_i],
                .edge_type = .imports,
            };
            try self.storage_engine.put_edge(import_edge);
        }

        log.info("Generated circular import cycle with {} modules", .{cycle_size});
    }

    /// Generate test parallel pattern where test files mirror implementation structure
    pub fn generate_test_parallel(self: *Self, impl_count: u32) !void {
        log.info("Generating parallel test structure for {} implementations", .{impl_count});

        for (0..impl_count) |i| {
            // Implementation block
            const impl_id = self.next_block_id();
            const impl_content = try self.alloc_string("pub fn implementation_{}() u32 {{ return {}; }}", .{ i, i * 10 });

            const impl_block = ContextBlock{
                .id = impl_id,
                .version = 1,
                .source_uri = try self.alloc_string("impl_{}.zig", .{i}),
                .metadata_json = try self.alloc_string("{{\"type\":\"implementation\",\"index\":{}}}", .{i}),
                .content = impl_content,
            };
            try self.storage_engine.put_block(impl_block);

            // Corresponding test block
            const test_id = self.next_block_id();
            const test_content = try self.alloc_string("const impl = @import(\"impl_{}.zig\");\ntest \"test_{}\" {{ try testing.expectEqual({}, impl.implementation_{}()); }}", .{ i, i, i * 10, i });

            const test_block = ContextBlock{
                .id = test_id,
                .version = 1,
                .source_uri = try self.alloc_string("test_{}.zig", .{i}),
                .metadata_json = try self.alloc_string("{{\"type\":\"test\",\"tests_impl\":{}}}", .{i}),
                .content = test_content,
            };
            try self.storage_engine.put_block(test_block);

            // Test imports and references implementation
            const import_edge = GraphEdge{
                .source_id = test_id,
                .target_id = impl_id,
                .edge_type = .imports,
            };
            try self.storage_engine.put_edge(import_edge);

            const calls_edge = GraphEdge{
                .source_id = test_id,
                .target_id = impl_id,
                .edge_type = .calls,
            };
            try self.storage_engine.put_edge(calls_edge);
        }

        log.info("Generated parallel test structure with {} pairs", .{impl_count});
    }

    /// Generate realistic mixed codebase with multiple patterns
    pub fn generate_realistic_codebase(self: *Self, config: CodebaseConfig) !void {
        log.info("Generating realistic codebase with config: {}", .{config});

        // Core utility libraries (high fanout)
        for (0..config.utility_libraries) |i| {
            const center_id = self.block_counter + @as(u32, @intCast(i * 100));
            try self.generate_library_fanout(center_id, config.fanout_per_library);
        }

        // Deep call chains in business logic
        for (0..config.deep_call_chains) |_| {
            try self.generate_monolithic_blocks(config.call_chain_depth);
        }

        // Test parallel structure
        try self.generate_test_parallel(config.test_modules);

        // Add some circular dependencies (realistic but problematic)
        if (config.include_circular) {
            try self.generate_circular_imports(3);
            try self.generate_circular_imports(4);
        }

        log.info("Realistic codebase generation completed", .{});
    }

    /// Get next unique block ID
    fn next_block_id(self: *Self) BlockId {
        defer self.block_counter += 1;
        return BlockId{ .bytes = int_to_block_id_bytes(self.block_counter) };
    }
};

/// Configuration for realistic codebase generation
pub const CodebaseConfig = struct {
    utility_libraries: u32 = 3, // Number of high-fanout utilities
    fanout_per_library: u32 = 8, // Dependents per utility
    deep_call_chains: u32 = 2, // Number of deep call chains
    call_chain_depth: u32 = 12, // Depth of each call chain
    test_modules: u32 = 10, // Number of test/impl pairs
    include_circular: bool = true, // Include problematic patterns
};

/// Convert u32 to BlockId bytes (simple implementation)
fn int_to_block_id_bytes(value: u32) [16]u8 {
    var bytes = [_]u8{0} ** 16;
    std.mem.writeInt(u32, bytes[0..4], value, .little);
    return bytes;
}

/// Scenario configurations for specific testing needs
pub const Scenarios = struct {
    /// Heavy write amplification scenario - many small libraries with fanout
    pub const write_amplification = CodebaseConfig{
        .utility_libraries = 8,
        .fanout_per_library = 15,
        .deep_call_chains = 1,
        .call_chain_depth = 5,
        .test_modules = 5,
        .include_circular = false,
    };

    /// Deep traversal scenario - emphasis on call chain depth
    pub const deep_traversal = CodebaseConfig{
        .utility_libraries = 1,
        .fanout_per_library = 3,
        .deep_call_chains = 5,
        .call_chain_depth = 20,
        .test_modules = 2,
        .include_circular = false,
    };

    /// Complex graph scenario - many interconnections
    pub const complex_graph = CodebaseConfig{
        .utility_libraries = 5,
        .fanout_per_library = 10,
        .deep_call_chains = 3,
        .call_chain_depth = 8,
        .test_modules = 15,
        .include_circular = true,
    };

    /// Minimal scenario for debugging
    pub const minimal = CodebaseConfig{
        .utility_libraries = 1,
        .fanout_per_library = 2,
        .deep_call_chains = 1,
        .call_chain_depth = 3,
        .test_modules = 1,
        .include_circular = false,
    };
};
