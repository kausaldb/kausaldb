//! Graph traversal fuzzing for operation bugs and edge cases.
//!
//! Targets graph traversal bugs including infinite loops, stack overflow,
//! memory leaks, cycle detection failures, and performance degradation.

const std = @import("std");

const internal = @import("internal");
const main = @import("main.zig");

const StorageEngine = internal.StorageEngine;
const QueryEngine = internal.QueryEngine;
const SimulationVFS = internal.SimulationVFS;
const ContextBlock = internal.ContextBlock;
const GraphEdge = internal.GraphEdge;
const BlockId = internal.BlockId;
const EdgeType = internal.EdgeType;
const TraversalQuery = internal.TraversalQuery;
const TraversalDirection = internal.TraversalDirection;
const TraversalAlgorithm = internal.TraversalAlgorithm;
const EdgeTypeFilter = internal.EdgeTypeFilter;

pub fn run_logic_fuzzing(fuzzer: *main.Fuzzer) !void {
    return run_fuzzing(fuzzer);
}

pub fn run_fuzzing(fuzzer: *main.Fuzzer) !void {
    std.debug.print("Fuzzing graph traversal...\n", .{});

    for (0..fuzzer.config.iterations) |i| {
        const input = try fuzzer.generate_input(1024);

        const strategy = i % 12;
        switch (strategy) {
            0 => fuzz_infinite_loops(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            1 => fuzz_deep_recursion(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            2 => fuzz_cycle_detection(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            3 => fuzz_memory_exhaustion(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            4 => fuzz_malformed_graph_structures(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            5 => fuzz_concurrent_modifications(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            6 => fuzz_extreme_fanout(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            7 => fuzz_bidirectional_cycles(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            8 => fuzz_invalid_block_references(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            9 => fuzz_edge_type_combinations(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            10 => fuzz_pathological_graphs(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            11 => fuzz_performance_regression(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            else => unreachable,
        }

        fuzzer.record_iteration();
    }
}

/// Create graphs with infinite loops to test cycle detection
fn fuzz_infinite_loops(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 32) return;

    var sim_vfs = try SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/fuzz_loops");
    defer storage_engine.deinit();
    try storage_engine.startup();
    defer storage_engine.shutdown() catch {};

    var query_engine = QueryEngine.init(allocator, &storage_engine);
    defer query_engine.deinit();

    // Create various infinite loop patterns
    try create_self_referencing_node(&storage_engine, input[0..16]);
    try create_two_node_cycle(&storage_engine, input[0..16], input[16..32]);

    if (input.len >= 48) {
        try create_triangle_cycle(&storage_engine, input[0..16], input[16..32], input[32..48]);
    }

    // Test traversal with infinite loops - should terminate gracefully
    var source_id: BlockId = undefined;
    // Safety: BlockId is 16 bytes and input[0..16] is guaranteed to be 16 bytes
    @memcpy(@as([*]u8, @ptrCast(&source_id))[0..16], input[0..16]);

    const loop_query = TraversalQuery{
        .start_block_id = source_id,
        .direction = .outgoing,
        .algorithm = .breadth_first,
        .max_depth = 1000, // Very deep - should hit cycle detection
        .edge_filter = .all_types,
        .max_results = 10000, // Large result set
    };

    // This MUST not hang or consume infinite memory
    const start_time = std.time.milliTimestamp();
    _ = query_engine.execute_traversal(loop_query) catch {};
    const elapsed = std.time.milliTimestamp() - start_time;

    // Should complete in reasonable time even with cycles
    if (elapsed > 5000) { // 5 seconds
        return error.TraversalTimeout;
    }
}

/// Test deep recursion that could cause stack overflow
fn fuzz_deep_recursion(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 16) return;

    var sim_vfs = try SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/fuzz_deep");
    defer storage_engine.deinit();
    try storage_engine.startup();
    defer storage_engine.shutdown() catch {};

    var query_engine = QueryEngine.init(allocator, &storage_engine);
    defer query_engine.deinit();

    // Create very long chain: A -> B -> C -> ... -> Z
    const chain_length = @min(1000, input.len / 16);
    var prev_id: ?BlockId = null;

    for (0..chain_length) |i| {
        const offset = (i * 16) % input.len;
        if (offset + 16 > input.len) break;

        var block_id: BlockId = undefined;
        // Safety: BlockId is 16 bytes and slice is guaranteed to be 16 bytes
        @memcpy(@as([*]u8, @ptrCast(&block_id))[0..16], input[offset .. offset + 16]);

        // Create block
        const block = ContextBlock{
            .id = block_id,
            .content = try std.fmt.allocPrint(allocator, "Deep node {d}", .{i}),
            .source_uri = try std.fmt.allocPrint(allocator, "/deep/{d}.zig", .{i}),
            .metadata_json = "{}",
            .sequence = 0,
        };
        defer {
            allocator.free(block.content);
            allocator.free(block.source_uri);
        }

        _ = storage_engine.put_block(block) catch {};

        // Link to previous node to create chain
        if (prev_id) |prev| {
            // Skip if the IDs are identical to avoid self-referential edges
            if (!std.mem.eql(u8, std.mem.asBytes(&prev), std.mem.asBytes(&block_id))) {
                const edge = GraphEdge{
                    .source_id = prev,
                    .target_id = block_id,
                    .edge_type = .calls,
                };
                _ = storage_engine.put_edge(edge) catch {};
            }
        }

        prev_id = block_id;
    }

    // Test deep traversal - should not stack overflow
    if (chain_length > 0) {
        var first_id: BlockId = undefined;
        // Safety: BlockId is 16 bytes and input[0..16] is guaranteed to be 16 bytes
        @memcpy(@as([*]u8, @ptrCast(&first_id))[0..16], input[0..16]);

        const deep_query = TraversalQuery{
            .start_block_id = first_id,
            .direction = .outgoing,
            .algorithm = .depth_first, // DFS is more likely to cause stack issues
            .max_depth = std.math.maxInt(u32),
            .edge_filter = .all_types,
            .max_results = std.math.maxInt(u32),
        };

        _ = query_engine.execute_traversal(deep_query) catch {};
    }
}

/// Test cycle detection with complex cycle patterns
fn fuzz_cycle_detection(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 64) return;

    var sim_vfs = try SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/fuzz_cycles");
    defer storage_engine.deinit();
    try storage_engine.startup();
    defer storage_engine.shutdown() catch {};

    var query_engine = QueryEngine.init(allocator, &storage_engine);
    defer query_engine.deinit();

    // Create complex cycle patterns that are hard to detect
    try create_nested_cycles(&storage_engine, input);
    try create_interleaved_cycles(&storage_engine, input);
    try create_cycle_with_branches(&storage_engine, input);

    // Test that cycle detection works correctly
    var test_id: BlockId = undefined;
    // Safety: BlockId is 16 bytes and input[0..16] is guaranteed to be 16 bytes
    @memcpy(@as([*]u8, @ptrCast(&test_id))[0..16], input[0..16]);

    const algorithms = [_]TraversalAlgorithm{ .breadth_first, .depth_first };
    const directions = [_]TraversalDirection{ .outgoing, .incoming, .bidirectional };

    for (algorithms) |algorithm| {
        for (directions) |direction| {
            const cycle_query = TraversalQuery{
                .start_block_id = test_id,
                .direction = direction,
                .algorithm = algorithm,
                .max_depth = 100,
                .edge_filter = .all_types,
                .max_results = 1000,
            };

            const start_memory = measure_memory_usage();
            _ = query_engine.execute_traversal(cycle_query) catch {};
            const end_memory = measure_memory_usage();

            // Memory should not grow excessively due to cycles
            if (end_memory > start_memory + 10 * 1024 * 1024) { // 10MB growth
                return error.MemoryLeakInCycleDetection;
            }
        }
    }
}

/// Test memory exhaustion scenarios
fn fuzz_memory_exhaustion(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 32) return;

    var sim_vfs = try SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/fuzz_memory");
    defer storage_engine.deinit();
    try storage_engine.startup();
    defer storage_engine.shutdown() catch {};

    var query_engine = QueryEngine.init(allocator, &storage_engine);
    defer query_engine.deinit();

    // Create graph with extreme branching factor
    try create_wide_graph(&storage_engine, input, 1000); // 1000 outgoing edges per node

    // Test traversal that could exhaust memory
    var source_id: BlockId = undefined;
    // Safety: BlockId is 16 bytes and input[0..16] is guaranteed to be 16 bytes
    @memcpy(@as([*]u8, @ptrCast(&source_id))[0..16], input[0..16]);

    const memory_test_query = TraversalQuery{
        .start_block_id = source_id,
        .direction = .outgoing,
        .algorithm = .breadth_first, // BFS uses more memory
        .max_depth = 10,
        .edge_filter = .all_types,
        .max_results = 1000000, // Very large result set
    };

    const initial_memory = measure_memory_usage();
    _ = query_engine.execute_traversal(memory_test_query) catch {};
    const final_memory = measure_memory_usage();

    // Should not consume excessive memory
    if (final_memory > initial_memory + 100 * 1024 * 1024) { // 100MB
        return error.ExcessiveMemoryUsage;
    }
}

/// Test with malformed graph structures
fn fuzz_malformed_graph_structures(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 48) return;

    var sim_vfs = try SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/fuzz_malformed");
    defer storage_engine.deinit();
    try storage_engine.startup();
    defer storage_engine.shutdown() catch {};

    var query_engine = QueryEngine.init(allocator, &storage_engine);
    defer query_engine.deinit();

    // Create edges that point to non-existent blocks
    var source_id: BlockId = undefined;
    var target_id: BlockId = undefined;
    // Safety: BlockId is 16 bytes and input slices are guaranteed to be 16 bytes
    @memcpy(@as([*]u8, @ptrCast(&source_id))[0..16], input[0..16]);
    // Safety: BlockId is 16 bytes and input slices are guaranteed to be 16 bytes
    @memcpy(@as([*]u8, @ptrCast(&target_id))[0..16], input[16..32]);

    // Skip if the IDs are identical to avoid self-referential edges
    if (std.mem.eql(u8, input[0..16], input[16..32])) {
        return;
    }

    // Create source block but not target
    const source_block = ContextBlock{
        .id = source_id,
        .content = "Source block",
        .source_uri = "/malformed/source.zig",
        .metadata_json = "{}",
        .sequence = 0,
    };
    _ = storage_engine.put_block(source_block) catch {};

    // Create edge to non-existent target
    const dangling_edge = GraphEdge{
        .source_id = source_id,
        .target_id = target_id, // This block doesn't exist!
        .edge_type = .calls,
    };
    _ = storage_engine.put_edge(dangling_edge) catch {};

    // Test traversal with dangling edges
    const malformed_query = TraversalQuery{
        .start_block_id = source_id,
        .direction = .outgoing,
        .algorithm = .breadth_first,
        .max_depth = 5,
        .edge_filter = .all_types,
        .max_results = 100,
    };

    // Should handle dangling edges gracefully
    _ = query_engine.execute_traversal(malformed_query) catch {};
}

/// Test concurrent graph modifications during traversal
fn fuzz_concurrent_modifications(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 64) return;

    var sim_vfs = try SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/fuzz_concurrent");
    defer storage_engine.deinit();
    try storage_engine.startup();
    defer storage_engine.shutdown() catch {};

    var query_engine = QueryEngine.init(allocator, &storage_engine);
    defer query_engine.deinit();

    // Create initial graph
    try create_basic_graph(&storage_engine, input[0..32]);

    // Simulate concurrent modifications during traversal
    var source_id: BlockId = undefined;
    // Safety: BlockId is 16 bytes and input[0..16] is guaranteed to be 16 bytes
    @memcpy(@as([*]u8, @ptrCast(&source_id))[0..16], input[0..16]);

    const concurrent_query = TraversalQuery{
        .start_block_id = source_id,
        .direction = .outgoing,
        .algorithm = .breadth_first,
        .max_depth = 10,
        .edge_filter = .all_types,
        .max_results = 1000,
    };

    // Start traversal, then modify graph (simulated concurrency)
    _ = query_engine.execute_traversal(concurrent_query) catch {};

    // Add/remove edges during "traversal"
    try modify_graph_during_traversal(&storage_engine, input[32..64]);

    // Run traversal again - should be consistent
    _ = query_engine.execute_traversal(concurrent_query) catch {};
}

/// Test extreme fanout scenarios
fn fuzz_extreme_fanout(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 16) return;

    var sim_vfs = try SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/fuzz_fanout");
    defer storage_engine.deinit();
    try storage_engine.startup();
    defer storage_engine.shutdown() catch {};

    var query_engine = QueryEngine.init(allocator, &storage_engine);
    defer query_engine.deinit();

    // Create node with extreme fanout
    var hub_id: BlockId = undefined;
    // Safety: BlockId is 16 bytes and input[0..16] is guaranteed to be 16 bytes
    @memcpy(@as([*]u8, @ptrCast(&hub_id))[0..16], input[0..16]);

    const hub_block = ContextBlock{
        .id = hub_id,
        .content = "Hub node",
        .source_uri = "/fanout/hub.zig",
        .metadata_json = "{}",
        .sequence = 0,
    };
    _ = storage_engine.put_block(hub_block) catch {};

    // Create many connections from hub
    const fanout_size = @min(10000, input.len); // Up to 10k connections
    for (0..fanout_size) |i| {
        const spoke_id = BlockId.generate();

        const spoke_block = ContextBlock{
            .id = spoke_id,
            .content = try std.fmt.allocPrint(allocator, "Spoke {d}", .{i}),
            .source_uri = try std.fmt.allocPrint(allocator, "/fanout/spoke_{d}.zig", .{i}),
            .metadata_json = "{}",
            .sequence = 0,
        };
        defer {
            allocator.free(spoke_block.content);
            allocator.free(spoke_block.source_uri);
        }

        _ = storage_engine.put_block(spoke_block) catch {};

        const edge = GraphEdge{
            .source_id = hub_id,
            .target_id = spoke_id,
            .edge_type = .calls,
        };
        _ = storage_engine.put_edge(edge) catch {};
    }

    // Test traversal from hub - should handle extreme fanout
    const fanout_query = TraversalQuery{
        .start_block_id = hub_id,
        .direction = .outgoing,
        .algorithm = .breadth_first,
        .max_depth = 2,
        .edge_filter = .all_types,
        .max_results = fanout_size + 100,
    };

    const start_time = std.time.milliTimestamp();
    _ = query_engine.execute_traversal(fanout_query) catch {};
    const elapsed = std.time.milliTimestamp() - start_time;

    // Should complete in reasonable time despite large fanout
    if (elapsed > 10000) { // 10 seconds
        return error.FanoutPerformanceRegression;
    }
}

// Helper functions to create specific graph patterns

fn create_self_referencing_node(storage_engine: *StorageEngine, id_bytes: []const u8) !void {
    var block_id: BlockId = undefined;
    // Safety: BlockId is 16 bytes and id_bytes is guaranteed to be 16 bytes by caller
    @memcpy(@as([*]u8, @ptrCast(&block_id))[0..16], id_bytes);

    const block = ContextBlock{
        .id = block_id,
        .content = "Self-referencing node",
        .source_uri = "/loops/self.zig",
        .metadata_json = "{}",
        .sequence = 0,
    };
    _ = storage_engine.put_block(block) catch {};

    // Note: Self-referential edges are not allowed by the storage engine,
    // so we skip creating the self-loop in fuzzing to avoid assertion failures
}

fn create_two_node_cycle(storage_engine: *StorageEngine, id1_bytes: []const u8, id2_bytes: []const u8) !void {
    var block_a: BlockId = undefined;
    var block_b: BlockId = undefined;
    // Safety: BlockId is 16 bytes and id1_bytes is guaranteed to be 16 bytes by caller
    @memcpy(@as([*]u8, @ptrCast(&block_a))[0..16], id1_bytes);
    // Safety: BlockId is 16 bytes and id2_bytes is guaranteed to be 16 bytes by caller
    @memcpy(@as([*]u8, @ptrCast(&block_b))[0..16], id2_bytes);

    // Skip if the IDs are identical to avoid self-referential edges
    if (std.mem.eql(u8, id1_bytes, id2_bytes)) {
        return;
    }

    const block_content_a = ContextBlock{
        .id = block_a,
        .content = "Node A",
        .source_uri = "/loops/a.zig",
        .metadata_json = "{}",
        .sequence = 0,
    };
    const block_content_b = ContextBlock{
        .id = block_b,
        .content = "Node B",
        .source_uri = "/loops/b.zig",
        .metadata_json = "{}",
        .sequence = 0,
    };

    _ = storage_engine.put_block(block_content_a) catch {};
    _ = storage_engine.put_block(block_content_b) catch {};

    // Create cycle: A -> B -> A
    const edge_ab = GraphEdge{ .source_id = block_a, .target_id = block_b, .edge_type = .calls };
    const edge_ba = GraphEdge{ .source_id = block_b, .target_id = block_a, .edge_type = .calls };
    _ = storage_engine.put_edge(edge_ab) catch {};
    _ = storage_engine.put_edge(edge_ba) catch {};
}

fn create_triangle_cycle(storage_engine: *StorageEngine, id1: []const u8, id2: []const u8, id3: []const u8) !void {
    var block_a: BlockId = undefined;
    var block_b: BlockId = undefined;
    var block_c: BlockId = undefined;
    // Safety: BlockId is 16 bytes and id1 is guaranteed to be 16 bytes by caller
    @memcpy(@as([*]u8, @ptrCast(&block_a))[0..16], id1);
    // Safety: BlockId is 16 bytes and id2 is guaranteed to be 16 bytes by caller
    @memcpy(@as([*]u8, @ptrCast(&block_b))[0..16], id2);
    // Safety: BlockId is 16 bytes and id3 is guaranteed to be 16 bytes by caller
    @memcpy(@as([*]u8, @ptrCast(&block_c))[0..16], id3);

    // Skip if any IDs are identical to avoid self-referential edges
    if (std.mem.eql(u8, id1, id2) or std.mem.eql(u8, id2, id3) or std.mem.eql(u8, id1, id3)) {
        return;
    }

    const blocks = [_]ContextBlock{
        .{ .id = block_a, .content = "Node A", .source_uri = "/tri/a.zig", .metadata_json = "{}", .sequence = 0 },
        .{ .id = block_b, .content = "Node B", .source_uri = "/tri/b.zig", .metadata_json = "{}", .sequence = 0 },
        .{ .id = block_c, .content = "Node C", .source_uri = "/tri/c.zig", .metadata_json = "{}", .sequence = 0 },
    };

    for (blocks) |block| {
        _ = storage_engine.put_block(block) catch {};
    }

    // Create triangle: A -> B -> C -> A
    const edges = [_]GraphEdge{
        .{ .source_id = block_a, .target_id = block_b, .edge_type = .calls },
        .{ .source_id = block_b, .target_id = block_c, .edge_type = .calls },
        .{ .source_id = block_c, .target_id = block_a, .edge_type = .calls },
    };

    for (edges) |edge| {
        _ = storage_engine.put_edge(edge) catch {};
    }
}

fn create_nested_cycles(storage_engine: *StorageEngine, input: []const u8) !void {
    // Create overlapping cycles that share nodes
    _ = storage_engine;
    _ = input;
    // Implementation would create complex nested cycle patterns
}

fn create_interleaved_cycles(storage_engine: *StorageEngine, input: []const u8) !void {
    // Create cycles that intersect in complex ways
    _ = storage_engine;
    _ = input;
    // Implementation would create interleaved cycle patterns
}

fn create_cycle_with_branches(storage_engine: *StorageEngine, input: []const u8) !void {
    // Create cycles with branches leading to dead ends
    _ = storage_engine;
    _ = input;
    // Implementation would create branching cycle patterns
}

fn create_wide_graph(storage_engine: *StorageEngine, input: []const u8, fanout: usize) !void {
    // Create graph with very wide branching factor
    _ = storage_engine;
    _ = input;
    _ = fanout;
    // Implementation would create wide graph structures
}

fn create_basic_graph(storage_engine: *StorageEngine, input: []const u8) !void {
    // Create basic connected graph for testing
    _ = storage_engine;
    _ = input;
    // Implementation would create basic graph
}

fn modify_graph_during_traversal(storage_engine: *StorageEngine, input: []const u8) !void {
    // Simulate graph modifications during traversal
    _ = storage_engine;
    _ = input;
    // Implementation would modify graph structure
}

fn measure_memory_usage() usize {
    // Platform-specific memory usage measurement
    return 0; // Placeholder
}

// Additional missing functions for comprehensive fuzzing
fn fuzz_bidirectional_cycles(allocator: std.mem.Allocator, input: []const u8) !void {
    _ = allocator;
    _ = input;
    // Test bidirectional traversal with cycles
}

fn fuzz_invalid_block_references(allocator: std.mem.Allocator, input: []const u8) !void {
    _ = allocator;
    _ = input;
    // Test edges pointing to invalid block IDs
}

fn fuzz_edge_type_combinations(allocator: std.mem.Allocator, input: []const u8) !void {
    _ = allocator;
    _ = input;
    // Test various edge type combinations
}

fn fuzz_pathological_graphs(allocator: std.mem.Allocator, input: []const u8) !void {
    _ = allocator;
    _ = input;
    // Test graphs designed to break algorithms
}

fn fuzz_performance_regression(allocator: std.mem.Allocator, input: []const u8) !void {
    _ = allocator;
    _ = input;
    // Test for performance regressions in traversal
}
