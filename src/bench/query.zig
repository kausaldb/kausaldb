//! Query engine benchmarks for KausalDB.
//!
//! Measures performance of graph traversal algorithms, edge filtering,
//! and complex multi-hop queries against realistic graph structures.
//! Uses SimulationVFS to eliminate I/O variability and focus on
//! algorithmic performance characteristics.

const std = @import("std");

const internal = @import("internal");

const harness = @import("harness.zig");

const BenchmarkHarness = harness.BenchmarkHarness;
const Timer = std.time.Timer;

/// Main entry point called by the benchmark runner.
pub fn run_benchmarks(bench_harness: *BenchmarkHarness) !void {
    // 1. SETUP: Initialize isolated environment
    var sim_vfs = try internal.SimulationVFS.init(bench_harness.allocator);
    defer sim_vfs.deinit();

    var storage = try internal.StorageEngine.init_default(bench_harness.allocator, sim_vfs.vfs(), "bench_query");
    defer storage.deinit();
    try storage.startup();
    defer storage.shutdown() catch {};

    var query_engine = internal.QueryEngine.init(bench_harness.allocator, &storage);
    defer query_engine.deinit();
    query_engine.startup();
    defer query_engine.shutdown();

    // Seed realistic graph data with cycles and branching
    try seed_complex_graph_data(&storage);

    // 2. RUN BENCHMARKS
    try bench_traversal_bfs_depth3(bench_harness, &query_engine);
    try bench_traversal_bfs_depth5(bench_harness, &query_engine);
    try bench_traversal_dfs_depth3(bench_harness, &query_engine);
    try bench_traversal_dfs_depth5(bench_harness, &query_engine);
    try bench_edge_filter_by_type(bench_harness, &query_engine);
    try bench_multi_hop_query(bench_harness, &query_engine);
    try bench_semantic_search(bench_harness, &query_engine);
}

/// Benchmark BFS traversal at depth 3
fn bench_traversal_bfs_depth3(bench_harness: *BenchmarkHarness, query_engine: *internal.QueryEngine) !void {
    const iterations = @min(100, bench_harness.config.iterations); // Graph ops are expensive
    const warmup = @min(20, bench_harness.config.warmup_iterations);

    // 3. COLLECT SAMPLES
    var samples = std.ArrayList(u64){};
    defer samples.deinit(bench_harness.allocator);

    // 4. WARMUP
    for (0..warmup) |_| {
        _ = perform_bfs_traversal(query_engine, 3) catch continue;
    }

    // 5. MEASUREMENT
    var timer = try Timer.start();
    for (0..iterations) |_| {
        timer.reset();
        _ = try perform_bfs_traversal(query_engine, 3);
        try samples.append(bench_harness.allocator, timer.read());
    }

    // 6. CALCULATE AND REPORT
    const result = harness.calculate_benchmark_result("query/traversal_bfs_depth3", samples.items);
    try bench_harness.add_result(result);
}

/// Benchmark BFS traversal at depth 5
fn bench_traversal_bfs_depth5(bench_harness: *BenchmarkHarness, query_engine: *internal.QueryEngine) !void {
    const iterations = @min(50, bench_harness.config.iterations); // Deeper traversal is more expensive
    const warmup = @min(10, bench_harness.config.warmup_iterations);

    var samples = std.ArrayList(u64){};
    defer samples.deinit(bench_harness.allocator);

    for (0..warmup) |_| {
        _ = perform_bfs_traversal(query_engine, 5) catch continue;
    }

    var timer = try Timer.start();
    for (0..iterations) |_| {
        timer.reset();
        _ = try perform_bfs_traversal(query_engine, 5);
        try samples.append(bench_harness.allocator, timer.read());
    }

    const result = harness.calculate_benchmark_result("query/traversal_bfs_depth5", samples.items);
    try bench_harness.add_result(result);
}

/// Benchmark DFS traversal at depth 3
fn bench_traversal_dfs_depth3(bench_harness: *BenchmarkHarness, query_engine: *internal.QueryEngine) !void {
    const iterations = @min(100, bench_harness.config.iterations);
    const warmup = @min(20, bench_harness.config.warmup_iterations);

    var samples = std.ArrayList(u64){};
    defer samples.deinit(bench_harness.allocator);

    for (0..warmup) |_| {
        _ = perform_dfs_traversal(query_engine, 3) catch continue;
    }

    var timer = try Timer.start();
    for (0..iterations) |_| {
        timer.reset();
        _ = try perform_dfs_traversal(query_engine, 3);
        try samples.append(bench_harness.allocator, timer.read());
    }

    const result = harness.calculate_benchmark_result("query/traversal_dfs_depth3", samples.items);
    try bench_harness.add_result(result);
}

/// Benchmark DFS traversal at depth 5
fn bench_traversal_dfs_depth5(bench_harness: *BenchmarkHarness, query_engine: *internal.QueryEngine) !void {
    const iterations = @min(50, bench_harness.config.iterations);
    const warmup = @min(10, bench_harness.config.warmup_iterations);

    var samples = std.ArrayList(u64){};
    defer samples.deinit(bench_harness.allocator);

    for (0..warmup) |_| {
        _ = perform_dfs_traversal(query_engine, 5) catch continue;
    }

    var timer = try Timer.start();
    for (0..iterations) |_| {
        timer.reset();
        _ = try perform_dfs_traversal(query_engine, 5);
        try samples.append(bench_harness.allocator, timer.read());
    }

    const result = harness.calculate_benchmark_result("query/traversal_dfs_depth5", samples.items);
    try bench_harness.add_result(result);
}

/// Benchmark edge filtering by type
fn bench_edge_filter_by_type(bench_harness: *BenchmarkHarness, query_engine: *internal.QueryEngine) !void {
    const iterations = bench_harness.config.iterations;
    const warmup = bench_harness.config.warmup_iterations;

    var samples = std.ArrayList(u64){};
    defer samples.deinit(bench_harness.allocator);

    for (0..warmup) |_| {
        _ = perform_edge_filter(query_engine) catch continue;
    }

    var timer = try Timer.start();
    for (0..iterations) |_| {
        timer.reset();
        _ = try perform_edge_filter(query_engine);
        try samples.append(bench_harness.allocator, timer.read());
    }

    const result = harness.calculate_benchmark_result("query/edge_filter_by_type", samples.items);
    try bench_harness.add_result(result);
}

/// Benchmark multi-hop queries
fn bench_multi_hop_query(bench_harness: *BenchmarkHarness, query_engine: *internal.QueryEngine) !void {
    const iterations = @min(100, bench_harness.config.iterations);
    const warmup = @min(20, bench_harness.config.warmup_iterations);

    var samples = std.ArrayList(u64){};
    defer samples.deinit(bench_harness.allocator);

    for (0..warmup) |_| {
        _ = perform_multi_hop_query(query_engine) catch continue;
    }

    var timer = try Timer.start();
    for (0..iterations) |_| {
        timer.reset();
        _ = try perform_multi_hop_query(query_engine);
        try samples.append(bench_harness.allocator, timer.read());
    }

    const result = harness.calculate_benchmark_result("query/multi_hop_query", samples.items);
    try bench_harness.add_result(result);
}

/// Benchmark semantic search
fn bench_semantic_search(bench_harness: *BenchmarkHarness, query_engine: *internal.QueryEngine) !void {
    const iterations = bench_harness.config.iterations;
    const warmup = bench_harness.config.warmup_iterations;

    var samples = std.ArrayList(u64){};
    defer samples.deinit(bench_harness.allocator);

    for (0..warmup) |_| {
        _ = perform_semantic_search(query_engine) catch continue;
    }

    var timer = try Timer.start();
    for (0..iterations) |_| {
        timer.reset();
        _ = try perform_semantic_search(query_engine);
        try samples.append(bench_harness.allocator, timer.read());
    }

    const result = harness.calculate_benchmark_result("query/semantic_search", samples.items);
    try bench_harness.add_result(result);
}

/// Perform BFS traversal to specified depth
fn perform_bfs_traversal(query_engine: *internal.QueryEngine, max_depth: u32) !void {
    const root_id = internal.BlockId.from_u64(1);

    const query = internal.TraversalQuery{
        .start_block_id = root_id,
        .direction = .outgoing,
        .max_depth = max_depth,
        .max_results = 1000,
        .algorithm = .breadth_first,
        .edge_filter = .all_types,
    };

    // Discard result - cache will be cleared after benchmark to free memory
    _ = try query_engine.execute_traversal(query);
}

/// Perform DFS traversal to specified depth
fn perform_dfs_traversal(query_engine: *internal.QueryEngine, max_depth: u32) !void {
    const root_id = internal.BlockId.from_u64(1);

    const query = internal.TraversalQuery{
        .start_block_id = root_id,
        .direction = .outgoing,
        .max_depth = max_depth,
        .max_results = 1000,
        .algorithm = .depth_first,
        .edge_filter = .all_types,
    };

    // Discard result - cache will be cleared after benchmark to free memory
    _ = try query_engine.execute_traversal(query);
}

/// Perform edge filtering by type
fn perform_edge_filter(query_engine: *internal.QueryEngine) !void {
    const root_id = internal.BlockId.from_u64(1);

    // Filter for only "calls" edges
    const edge_types = [_]internal.EdgeType{.calls};
    const filter = internal.EdgeTypeFilter{
        .include_types = &edge_types,
    };

    const query = internal.TraversalQuery{
        .start_block_id = root_id,
        .direction = .outgoing,
        .max_depth = 2,
        .max_results = 1000,
        .algorithm = .breadth_first,
        .edge_filter = filter,
    };

    // Discard result - caching is disabled so no memory leak
    _ = try query_engine.execute_traversal(query);
}

/// Perform multi-hop query
fn perform_multi_hop_query(query_engine: *internal.QueryEngine) !void {
    const root_id = internal.BlockId.from_u64(1);

    const query = internal.TraversalQuery{
        .start_block_id = root_id,
        .direction = .outgoing,
        .max_depth = 3,
        .max_results = 1000,
        .algorithm = .breadth_first,
        .edge_filter = .all_types,
    };

    // Discard result - caching is disabled so no memory leak
    _ = try query_engine.execute_traversal(query);
}

/// Perform semantic search
fn perform_semantic_search(query_engine: *internal.QueryEngine) !void {
    const query = internal.SemanticQuery{
        .query_text = "function benchmark test",
        .max_results = 10,
    };

    const results = try query_engine.execute_semantic_query(query);
    defer results.deinit();
}

/// Seed complex graph data with realistic branching, cycles, and multiple edge types
///
/// Creates a graph structure that mirrors real codebases:
/// - Central hub nodes with many connections
/// - Branching call chains of varying depth
/// - Bidirectional relationships between modules
/// - Multiple edge types (calls, imports, defines, references)
fn seed_complex_graph_data(storage: *internal.StorageEngine) !void {
    const num_nodes = 25;

    // Create diverse block types representing different code constructs
    for (1..num_nodes + 1) |i| {
        const content = switch (i % 4) {
            0 => "pub fn benchmark_function() !u32 { return 42; }",
            1 => "pub const Config = struct { value: u32, enabled: bool };",
            2 => "//! Module for testing graph traversal performance",
            else => "pub const BENCHMARK_CONSTANT: u32 = 1000;",
        };

        // Use static strings to avoid memory leaks in benchmarks
        const source_uri = switch (i % 4) {
            0 => "bench://graph/function.zig",
            1 => "bench://graph/struct.zig",
            2 => "bench://graph/module.zig",
            else => "bench://graph/constant.zig",
        };

        const metadata_json = switch (i % 5) {
            0 => "{\"type\": \"benchmark\", \"complexity\": 0}",
            1 => "{\"type\": \"benchmark\", \"complexity\": 1}",
            2 => "{\"type\": \"benchmark\", \"complexity\": 2}",
            3 => "{\"type\": \"benchmark\", \"complexity\": 3}",
            else => "{\"type\": \"benchmark\", \"complexity\": 4}",
        };

        const block = internal.ContextBlock{
            .id = internal.BlockId.from_u64(i),
            .sequence = 0,
            .source_uri = source_uri,
            .metadata_json = metadata_json,
            .content = content,
        };
        try storage.put_block(block);
    }

    // Create hub structure: nodes 1-5 are central hubs with many connections
    for (1..6) |hub| {
        for (6..num_nodes + 1) |target| {
            if ((target - hub) % 3 == 0) {
                const edge = internal.GraphEdge{
                    .source_id = internal.BlockId.from_u64(hub),
                    .target_id = internal.BlockId.from_u64(target),
                    .edge_type = if (hub % 2 == 0) .calls else .imports,
                };
                try storage.put_edge(edge);
            }
        }
    }

    // Create branching chains from hub nodes
    for (6..num_nodes - 2) |i| {
        // Chain: each node connects to 1-3 subsequent nodes
        const branch_factor = (i % 3) + 1;
        for (1..branch_factor + 1) |j| {
            if (i + j <= num_nodes) {
                const edge_type = switch (j) {
                    1 => internal.EdgeType.calls,
                    2 => internal.EdgeType.references,
                    else => internal.EdgeType.defined_in,
                };

                const edge = internal.GraphEdge{
                    .source_id = internal.BlockId.from_u64(i),
                    .target_id = internal.BlockId.from_u64(i + j),
                    .edge_type = edge_type,
                };
                try storage.put_edge(edge);
            }
        }
    }

    // Create cycles for more realistic traversal patterns
    // Cycle 1: 8 -> 12 -> 16 -> 8
    const cycle_edges = [_]struct { source: u64, target: u64, edge_type: internal.EdgeType }{
        .{ .source = 8, .target = 12, .edge_type = .calls },
        .{ .source = 12, .target = 16, .edge_type = .references },
        .{ .source = 16, .target = 8, .edge_type = .imports },

        // Cycle 2: 10 -> 15 -> 20 -> 10
        .{ .source = 10, .target = 15, .edge_type = .defined_in },
        .{ .source = 15, .target = 20, .edge_type = .calls },
        .{ .source = 20, .target = 10, .edge_type = .references },
    };

    for (cycle_edges) |edge_spec| {
        const edge = internal.GraphEdge{
            .source_id = internal.BlockId.from_u64(edge_spec.source),
            .target_id = internal.BlockId.from_u64(edge_spec.target),
            .edge_type = edge_spec.edge_type,
        };
        try storage.put_edge(edge);
    }
}
