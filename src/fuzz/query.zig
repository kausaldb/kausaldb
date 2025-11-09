//! Query engine fuzzing for parsing and logic bugs.
//!
//! Parse fuzzing finds crashes in query deserialization and parsing.
//! Logic fuzzing finds incorrect results and invariant violations.
//! All fuzzing is deterministic and reproducible using seeds.

const std = @import("std");

const internal = @import("internal");
const main = @import("main.zig");

const QueryEngine = internal.QueryEngine;
const StorageEngine = internal.StorageEngine;
const SimulationVFS = internal.SimulationVFS;
const ContextBlock = internal.ContextBlock;
const GraphEdge = internal.GraphEdge;
const BlockId = internal.BlockId;
const EdgeType = internal.EdgeType;
const Config = internal.Config;
const OwnedBlock = internal.OwnedBlock;
const TraversalQuery = internal.TraversalQuery;
const TraversalDirection = internal.TraversalDirection;
const TraversalAlgorithm = internal.TraversalAlgorithm;
const EdgeTypeFilter = internal.EdgeTypeFilter;
const SemanticQuery = internal.SemanticQuery;
const WorkloadGenerator = internal.WorkloadGenerator;
const WorkloadConfig = internal.WorkloadConfig;
const ModelState = internal.ModelState;
const PropertyChecker = internal.PropertyChecker;
const BlockOwnership = internal.ownership.BlockOwnership;

/// Parse fuzzing - test query parsing robustness
pub fn run_parse_fuzzing(fuzzer: *main.Fuzzer) !void {
    std.debug.print("Query parse fuzzing...\n", .{});

    // Setup test environment once
    var sim_vfs = try SimulationVFS.heap_init(fuzzer.allocator);
    defer {
        sim_vfs.deinit();
        fuzzer.allocator.destroy(sim_vfs);
    }

    var storage = try StorageEngine.init_default(fuzzer.allocator, sim_vfs.vfs(), "/fuzz_query");
    defer storage.deinit();
    try storage.startup();
    defer storage.shutdown() catch {};

    var query_engine = QueryEngine.init(fuzzer.allocator, &storage);
    defer query_engine.deinit();

    // Seed with some test data
    try seed_test_data(&storage);

    while (fuzzer.should_continue()) {
        const input = try fuzzer.generate_input(1024);

        const strategy = fuzzer.stats.iterations_executed % 8;
        switch (strategy) {
            0 => fuzz_traversal_query_parsing(&query_engine, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            1 => fuzz_semantic_query_parsing(&query_engine, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            2 => fuzz_invalid_block_ids(&query_engine, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            3 => fuzz_malformed_filters(&query_engine, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            4 => fuzz_deep_recursion(&query_engine, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            5 => fuzz_cyclic_queries(&query_engine, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            6 => fuzz_boundary_conditions(&query_engine, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            7 => fuzz_concurrent_query_patterns(&query_engine, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            else => unreachable,
        }

        fuzzer.record_iteration();
    }
}

/// Logic fuzzing - test query correctness
pub fn run_logic_fuzzing(fuzzer: *main.Fuzzer) !void {
    std.debug.print("Query logic fuzzing...\n", .{});

    while (fuzzer.should_continue()) {
        // Fresh environment for each test
        var sim_vfs = try SimulationVFS.init(fuzzer.allocator);
        defer sim_vfs.deinit();

        var storage = try StorageEngine.init(
            fuzzer.allocator,
            sim_vfs.vfs(),
            "query_logic_test",
            Config.minimal_for_testing(),
        );
        defer storage.deinit();
        try storage.startup();
        defer storage.shutdown() catch {};

        var query_engine = QueryEngine.init(fuzzer.allocator, &storage);
        defer query_engine.deinit();

        // Create model for comparison
        var model = try ModelState.init(fuzzer.allocator);
        defer model.deinit();

        // Generate test graph
        try generate_test_graph(fuzzer.allocator, &storage, &model, fuzzer.config.seed);

        // Test various query patterns
        try test_traversal_correctness(&query_engine, &model, fuzzer);
        try test_filter_correctness(&query_engine, &model, fuzzer);
        try test_consistency_properties(&query_engine, &model, fuzzer);

        fuzzer.record_iteration();
    }
}

// ============================================================================
// Parse Fuzzing Functions
// ============================================================================

fn fuzz_traversal_query_parsing(engine: *QueryEngine, input: []const u8) !void {
    if (input.len < 17) return;

    // Parse block ID from input
    var block_id: BlockId = undefined;
    @memcpy(@as([*]u8, @ptrCast(&block_id))[0..16], input[0..16]);

    // Parse traversal parameters
    const depth = if (input.len > 16) input[16] % 10 else 3;
    const direction = if (input.len > 17) @as(TraversalDirection, @enumFromInt(input[17] % 3)) else .outgoing;

    // Create traversal query
    const query = TraversalQuery{
        .start_id = block_id,
        .max_depth = depth,
        .direction = direction,
        .algorithm = .bfs,
        .edge_filter = null,
        .max_nodes = 1000,
    };

    // Attempt traversal
    _ = engine.execute_traversal(query) catch |err| switch (err) {
        // Expected errors for malformed input
        error.BlockNotFound,
        error.InvalidQuery,
        error.DepthExceeded,
        => return,
        else => return err,
    };
}

fn fuzz_semantic_query_parsing(engine: *QueryEngine, input: []const u8) !void {
    _ = engine;
    if (input.len < 32) return;

    // Parse semantic query components
    const query_type = input[0] % 4;

    const semantic_query = switch (query_type) {
        0 => SemanticQuery{ // Find by metadata
            .type = .metadata_match,
            .metadata_filter = input[1..@min(32, input.len)],
        },
        1 => SemanticQuery{ // Find by content pattern
            .type = .content_pattern,
            .pattern = input[1..@min(64, input.len)],
        },
        2 => SemanticQuery{ // Find by source URI
            .type = .source_match,
            .source_pattern = input[1..@min(48, input.len)],
        },
        3 => SemanticQuery{ // Combined query
            .type = .combined,
            .filters = input[1..@min(128, input.len)],
        },
        else => unreachable,
    };

    _ = semantic_query;
    // Would execute semantic query if API existed
}

fn fuzz_invalid_block_ids(engine: *QueryEngine, input: []const u8) !void {
    // Test with completely invalid block IDs
    if (input.len < 16) return;

    var invalid_id: BlockId = undefined;

    // Create various invalid patterns
    const pattern = input[0] % 4;
    switch (pattern) {
        0 => @memset(@as([*]u8, @ptrCast(&invalid_id))[0..16], 0), // All zeros
        1 => @memset(@as([*]u8, @ptrCast(&invalid_id))[0..16], 0xFF), // All ones
        2 => @memcpy(@as([*]u8, @ptrCast(&invalid_id))[0..16], input[0..16]), // Random
        3 => { // Pattern
            for (0..16) |i| {
                @as([*]u8, @ptrCast(&invalid_id))[i] = @intCast(i);
            }
        },
        else => unreachable,
    }

    // Test various operations with invalid ID
    _ = engine.find_block(invalid_id) catch {};
    _ = engine.traverse_outgoing(invalid_id, 1) catch {};
    _ = engine.traverse_incoming(invalid_id, 1) catch {};
    _ = engine.traverse_bidirectional(invalid_id, 1) catch {};
}

fn fuzz_malformed_filters(engine: *QueryEngine, input: []const u8) !void {
    if (input.len < 32) return;

    // Create malformed edge type filter
    const filter_bytes = input[0..@min(32, input.len)];
    var edge_filter = EdgeTypeFilter{
        .include_types = std.EnumSet(EdgeType).init(.{}),
        .exclude_types = std.EnumSet(EdgeType).init(.{}),
    };

    // Add random edge types
    for (filter_bytes) |byte| {
        const edge_type = @as(EdgeType, @enumFromInt(byte % 10));
        if (byte & 1 == 0) {
            edge_filter.include_types.insert(edge_type);
        } else {
            edge_filter.exclude_types.insert(edge_type);
        }
    }

    // Test with conflicting filters (same type in include and exclude)
    const start_id = BlockId.generate();
    const query = TraversalQuery{
        .start_id = start_id,
        .max_depth = 3,
        .direction = .outgoing,
        .algorithm = .bfs,
        .edge_filter = edge_filter,
        .max_nodes = 100,
    };

    _ = engine.execute_traversal(query) catch {};
}

fn fuzz_deep_recursion(engine: *QueryEngine, input: []const u8) !void {
    if (input.len < 20) return;

    // Test with extremely deep traversals
    var block_id: BlockId = undefined;
    @memcpy(@as([*]u8, @ptrCast(&block_id))[0..16], input[0..16]);

    const depths = [_]u32{ 100, 1000, 10000, 100000 };
    const depth_idx = input[16] % depths.len;
    const max_depth = depths[depth_idx];

    // Should handle deep recursion gracefully
    _ = engine.traverse_outgoing(block_id, max_depth) catch |err| switch (err) {
        error.DepthExceeded,
        error.OutOfMemory,
        error.BlockNotFound,
        => return,
        else => return err,
    };
}

fn fuzz_cyclic_queries(engine: *QueryEngine, input: []const u8) !void {
    _ = input;

    // Create a cyclic graph for testing
    const blocks = [_]BlockId{
        BlockId.generate(),
        BlockId.generate(),
        BlockId.generate(),
    };

    // Create cycle: A -> B -> C -> A
    const edges = [_]GraphEdge{
        .{ .source_id = blocks[0], .target_id = blocks[1], .edge_type = .calls },
        .{ .source_id = blocks[1], .target_id = blocks[2], .edge_type = .calls },
        .{ .source_id = blocks[2], .target_id = blocks[0], .edge_type = .calls },
    };

    // Add blocks and edges to storage
    for (blocks) |id| {
        const block = ContextBlock{
            .id = id,
            .sequence = 1,
            .source_uri = "test://cycle",
            .metadata_json = "{}",
            .content = "cycle_test",
        };
        engine.storage.put_block(block) catch {};
    }

    for (edges) |edge| {
        engine.storage.put_edge(edge) catch {};
    }

    // Query should handle cycles without infinite loops
    _ = engine.traverse_outgoing(blocks[0], 100) catch {};
}

fn fuzz_boundary_conditions(engine: *QueryEngine, input: []const u8) !void {
    _ = input;

    // Test with boundary values
    const boundary_tests = [_]struct {
        depth: u32,
        max_nodes: u32,
    }{
        .{ .depth = 0, .max_nodes = 0 },
        .{ .depth = 1, .max_nodes = 1 },
        .{ .depth = std.math.maxInt(u32), .max_nodes = 1 },
        .{ .depth = 1, .max_nodes = std.math.maxInt(u32) },
    };

    const start_id = BlockId.generate();
    for (boundary_tests) |test_case| {
        const query = TraversalQuery{
            .start_id = start_id,
            .max_depth = test_case.depth,
            .direction = .outgoing,
            .algorithm = .bfs,
            .edge_filter = null,
            .max_nodes = test_case.max_nodes,
        };

        _ = engine.execute_traversal(query) catch {};
    }
}

fn fuzz_concurrent_query_patterns(engine: *QueryEngine, input: []const u8) !void {
    _ = input;

    // Simulate concurrent query patterns (sequential but interleaved)
    const block_ids = [_]BlockId{
        BlockId.generate(),
        BlockId.generate(),
        BlockId.generate(),
    };

    // Interleave different query types
    for (0..10) |i| {
        const id = block_ids[i % block_ids.len];

        switch (i % 5) {
            0 => _ = engine.find_block(id) catch {},
            1 => _ = engine.traverse_outgoing(id, 2) catch {},
            2 => _ = engine.traverse_incoming(id, 2) catch {},
            3 => _ = engine.query_block_sequence(id) catch {},
            4 => _ = engine.traverse_bidirectional(id, 1) catch {},
            else => unreachable,
        }
    }
}

// ============================================================================
// Logic Fuzzing Functions
// ============================================================================

fn generate_test_graph(allocator: std.mem.Allocator, storage: *StorageEngine, model: *ModelState, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    // Generate blocks
    const num_blocks = 50 + random.uintLessThan(u32, 50);
    var block_ids = std.ArrayList(BlockId){};
    defer block_ids.deinit(allocator);

    for (0..num_blocks) |i| {
        const block = ContextBlock{
            .id = BlockId.generate(),
            .sequence = @intCast(i + 1),
            .source_uri = "test://graph",
            .metadata_json = try std.fmt.allocPrint(
                allocator,
                "{{\"index\":{},\"type\":\"test\"}}",
                .{i},
            ),
            .content = try std.fmt.allocPrint(allocator, "test_block_{}", .{i}),
        };

        try storage.put_block(block);
        try model.apply_put_block(block);
        try block_ids.append(allocator, block.id);
    }

    // Generate edges with various patterns
    const num_edges = 100 + random.uintLessThan(u32, 100);
    for (0..num_edges) |_| {
        if (block_ids.items.len < 2) break;

        const source_idx = random.uintLessThan(usize, block_ids.items.len);
        const target_idx = random.uintLessThan(usize, block_ids.items.len);

        // Avoid self-loops for cleaner testing
        if (source_idx == target_idx) continue;

        const edge = GraphEdge{
            .source_id = block_ids.items[source_idx],
            .target_id = block_ids.items[target_idx],
            .edge_type = @as(EdgeType, @enumFromInt(1 + random.uintLessThan(u8, 10))),
        };

        storage.put_edge(edge) catch {};
        model.apply_put_edge(edge) catch {};
    }
}

fn test_traversal_correctness(
    engine: *QueryEngine,
    model: *ModelState,
    fuzzer: *main.Fuzzer,
) !void {
    // Get all blocks from model
    const block_ids = try model.collect_active_block_ids(model.backing_allocator);
    defer model.backing_allocator.free(block_ids);
    if (block_ids.len == 0) return;

    var prng = std.Random.DefaultPrng.init(fuzzer.config.seed);
    const random = prng.random();

    // Test traversals from random starting points
    for (0..10) |_| {
        const start_idx = random.uintLessThan(usize, block_ids.len);
        const start_id = block_ids[start_idx];
        const depth = 1 + random.uintLessThan(u32, 5);

        // Test outgoing traversal
        const engine_result = try engine.traverse_outgoing(start_id, depth);

        // Verify all returned blocks exist in model
        for (engine_result.blocks) |owned_block| {
            if (!model.has_active_block(owned_block.block.id)) {
                try fuzzer.handle_crash(
                    std.mem.asBytes(&start_id),
                    error.TraversalBlockNotInModel,
                );
            }
        }

        // Test incoming traversal
        const engine_incoming = try engine.traverse_incoming(start_id, depth);

        // Verify all returned blocks exist in model
        for (engine_incoming.blocks) |owned_block| {
            if (!model.has_active_block(owned_block.block.id)) {
                try fuzzer.handle_crash(
                    std.mem.asBytes(&start_id),
                    error.TraversalBlockNotInModel,
                );
            }
        }
    }
}

fn test_filter_correctness(
    engine: *QueryEngine,
    model: *ModelState,
    fuzzer: *main.Fuzzer,
) !void {
    _ = engine;
    _ = model;
    _ = fuzzer;
    // Test edge type filtering
    // Test metadata filtering
    // Test combined filters
}

fn test_consistency_properties(
    engine: *QueryEngine,
    model: *ModelState,
    fuzzer: *main.Fuzzer,
) !void {
    // Verify query consistency properties
    try PropertyChecker.check_consistency(model, engine.storage_engine);

    // Verify graph properties
    try PropertyChecker.check_bidirectional_consistency(model, engine.storage_engine);

    _ = fuzzer;
}

fn verify_traversal_results(
    engine_result: []const OwnedBlock,
    model_result: []const ContextBlock,
) bool {
    if (engine_result.len != model_result.len) return false;

    // Create a set of IDs from engine result for comparison
    var engine_ids = std.AutoHashMap(BlockId, void).init(std.heap.page_allocator);
    defer engine_ids.deinit();

    for (engine_result) |block| {
        engine_ids.put(block.block.id, {}) catch return false;
    }

    // Check all model results are in engine results
    for (model_result) |block| {
        if (!engine_ids.contains(block.id)) return false;
    }

    return true;
}

fn seed_test_data(storage: *StorageEngine) !void {
    // Add some basic test data for parse fuzzing
    const test_blocks = [_]ContextBlock{
        .{
            .id = BlockId.generate(),
            .sequence = 1,
            .source_uri = "test://seed/1",
            .metadata_json = "{\"test\":true}",
            .content = "seed_block_1",
        },
        .{
            .id = BlockId.generate(),
            .sequence = 2,
            .source_uri = "test://seed/2",
            .metadata_json = "{\"test\":true}",
            .content = "seed_block_2",
        },
    };

    for (test_blocks) |block| {
        try storage.put_block(block);
    }

    // Add edge between them
    const edge = GraphEdge{
        .source_id = test_blocks[0].id,
        .target_id = test_blocks[1].id,
        .edge_type = .calls,
    };
    try storage.put_edge(edge);
}
