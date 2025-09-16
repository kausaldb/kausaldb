//! Storage engine benchmarks - comprehensive performance testing
//!
//! Measures core storage operations with microsecond precision:
//! - Block write/read latency
//! - WAL append throughput
//! - Memtable flush performance
//! - SSTable operations
//! - Compaction efficiency
//! - Graph edge operations

const std = @import("std");
const main = @import("main.zig");

const internal = @import("internal");

const BenchmarkHarness = main.BenchmarkHarness;
const StorageEngine = internal.StorageEngine;
const SimulationVFS = internal.SimulationVFS;
const ContextBlock = internal.ContextBlock;
const GraphEdge = internal.GraphEdge;
const BlockId = internal.BlockId;
const EdgeType = internal.EdgeType;
const Config = internal.Config;
const BlockOwnership = internal.ownership.BlockOwnership;

/// Run all storage benchmarks using the shared harness
pub fn run_benchmarks(harness: *BenchmarkHarness) !void {
    std.debug.print("Running storage benchmarks...\n", .{});

    var arena = std.heap.ArenaAllocator.init(harness.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Setup deterministic storage environment with SimulationVFS
    var sim_vfs = try SimulationVFS.init(alloc);
    defer sim_vfs.deinit();
    const vfs = sim_vfs.vfs();

    // Create storage configuration optimized for benchmarking
    const config = Config{
        .memtable_max_size = 16 * 1024 * 1024, // 16MB for reasonable benchmark data
    };

    var storage = try StorageEngine.init(alloc, vfs, "bench_storage", config);
    defer storage.deinit();
    try storage.startup(); // CRITICAL: Must startup before operations
    defer storage.shutdown() catch {};

    // Core storage benchmarks
    try bench_block_write(harness, &storage, alloc);
    try bench_block_read_hot(harness, &storage, alloc);
    try bench_block_read_cold(harness, &storage, alloc);
    try bench_wal_append(harness, &storage, alloc);
    try bench_memtable_flush(harness, &storage, alloc);
    try bench_edge_insert(harness, &storage, alloc);
    try bench_edge_lookup(harness, &storage, alloc);
    try bench_graph_traversal(harness, &storage, alloc);
}

/// Benchmark block write operations
fn bench_block_write(
    harness: *BenchmarkHarness,
    storage: *StorageEngine,
    allocator: std.mem.Allocator,
) !void {
    const iterations = harness.config.iterations;

    // Generate test blocks
    var blocks = try std.ArrayList(ContextBlock).initCapacity(allocator, iterations);
    defer blocks.deinit(allocator);

    for (0..iterations) |i| {
        const block = generate_test_block(allocator, i);
        try blocks.append(allocator, block);
    }

    // Warmup phase
    for (0..harness.config.warmup_iterations) |i| {
        const idx = i % blocks.items.len;
        try storage.put_block(blocks.items[idx]);
    }

    // Measurement phase
    var samples = std.array_list.Managed(u64).init(allocator);
    try samples.ensureTotalCapacity(iterations);
    defer samples.deinit();

    var timer = try std.time.Timer.start();
    for (blocks.items) |block| {
        const start = timer.read();
        try storage.put_block(block);
        const elapsed = timer.read() - start;
        try samples.append(elapsed);
    }

    const result = calculate_benchmark_result("storage_block_write", samples.items);
    try harness.add_result(result);
}

/// Benchmark hot block reads from memtable
fn bench_block_read_hot(
    harness: *BenchmarkHarness,
    storage: *StorageEngine,
    allocator: std.mem.Allocator,
) !void {
    const iterations = harness.config.iterations;

    // Insert blocks into memtable
    var block_ids = try std.ArrayList(BlockId).initCapacity(allocator, iterations);
    defer block_ids.deinit(allocator);

    for (0..iterations) |i| {
        const block = generate_test_block(allocator, i);
        try block_ids.append(allocator, block.id);
        try storage.put_block(block);
    }

    // Warmup phase
    for (0..harness.config.warmup_iterations) |i| {
        const idx = i % block_ids.items.len;
        _ = try storage.find_block(block_ids.items[idx], BlockOwnership.simulation_test);
    }

    // Measurement phase
    var samples = try std.ArrayList(u64).initCapacity(allocator, iterations);
    defer samples.deinit(allocator);

    var timer = try std.time.Timer.start();
    for (block_ids.items) |id| {
        const start = timer.read();
        _ = try storage.find_block(id, BlockOwnership.simulation_test);
        const elapsed = timer.read() - start;
        try samples.append(allocator, elapsed);
    }

    const result = calculate_benchmark_result("storage_block_read_hot", samples.items);
    try harness.add_result(result);
}

/// Benchmark cold block reads from SSTable
fn bench_block_read_cold(
    harness: *BenchmarkHarness,
    storage: *StorageEngine,
    allocator: std.mem.Allocator,
) !void {
    const iterations = @min(100, harness.config.iterations); // Limit for SSTable operations

    // Fill and flush memtable to create SSTable
    var block_ids = try std.ArrayList(BlockId).initCapacity(allocator, iterations);
    defer block_ids.deinit(allocator);

    for (0..1000) |i| { // Fill memtable
        const block = generate_test_block(allocator, i);
        if (i < iterations) {
            try block_ids.append(allocator, block.id);
        }
        try storage.put_block(block);
    }

    // Force flush to SSTable
    try storage.flush_memtable_to_sstable();

    // Measurement phase - reads should now come from SSTable
    var samples = try std.ArrayList(u64).initCapacity(allocator, iterations);
    defer samples.deinit(allocator);

    var timer = try std.time.Timer.start();
    for (block_ids.items) |id| {
        const start = timer.read();
        _ = try storage.find_block(id, BlockOwnership.simulation_test);
        const elapsed = timer.read() - start;
        try samples.append(allocator, elapsed);
    }

    const result = calculate_benchmark_result("storage_block_read_cold", samples.items);
    try harness.add_result(result);
}

/// Benchmark WAL append operations
fn bench_wal_append(
    harness: *BenchmarkHarness,
    storage: *StorageEngine,
    allocator: std.mem.Allocator,
) !void {
    const iterations = harness.config.iterations;

    // Generate blocks for WAL operations
    var blocks = try std.ArrayList(ContextBlock).initCapacity(allocator, iterations);
    defer blocks.deinit(allocator);

    for (0..iterations) |i| {
        const block = generate_test_block(allocator, i);
        try blocks.append(allocator, block);
    }

    // Measurement phase - WAL append happens internally in put_block
    var samples = try std.ArrayList(u64).initCapacity(allocator, iterations);
    defer samples.deinit(allocator);

    var timer = try std.time.Timer.start();
    for (blocks.items) |block| {
        const start = timer.read();
        try storage.put_block(block);
        const elapsed = timer.read() - start;
        try samples.append(allocator, elapsed);
    }

    const result = calculate_benchmark_result("storage_wal_append", samples.items);
    try harness.add_result(result);
}

/// Benchmark memtable flush operations
fn bench_memtable_flush(
    harness: *BenchmarkHarness,
    storage: *StorageEngine,
    allocator: std.mem.Allocator,
) !void {
    const flush_iterations = @min(10, harness.config.iterations / 100); // Limit flush count

    var samples = try std.ArrayList(u64).initCapacity(allocator, flush_iterations);
    defer samples.deinit(allocator);

    var timer = try std.time.Timer.start();

    for (0..flush_iterations) |_| {
        // Fill memtable with blocks
        for (0..100) |i| {
            const block = generate_test_block(allocator, i);
            try storage.put_block(block);
        }

        // Measure flush time
        const start = timer.read();
        try storage.flush_memtable_to_sstable();
        const elapsed = timer.read() - start;
        try samples.append(allocator, elapsed);
    }

    const result = calculate_benchmark_result("storage_memtable_flush", samples.items);
    try harness.add_result(result);
}

/// Benchmark edge insertion operations
fn bench_edge_insert(
    harness: *BenchmarkHarness,
    storage: *StorageEngine,
    allocator: std.mem.Allocator,
) !void {
    const iterations = harness.config.iterations;

    // First create blocks that edges will reference (referential integrity requirement)
    var block_ids = try std.ArrayList(BlockId).initCapacity(allocator, iterations * 2);
    defer block_ids.deinit(allocator);

    for (0..iterations * 2) |i| {
        const block = generate_test_block(allocator, i);
        try block_ids.append(allocator, block.id);
        try storage.put_block(block);
    }

    // Generate test edges using existing block IDs
    var edges = try std.ArrayList(GraphEdge).initCapacity(allocator, iterations);
    defer edges.deinit(allocator);

    for (0..iterations) |i| {
        const source_idx = i * 2;
        const target_idx = i * 2 + 1;
        const edge = GraphEdge{
            .source_id = block_ids.items[source_idx],
            .target_id = block_ids.items[target_idx],
            .edge_type = EdgeType.calls,
        };
        try edges.append(allocator, edge);
    }

    // Warmup phase
    for (0..harness.config.warmup_iterations) |i| {
        const idx = i % edges.items.len;
        try storage.put_edge(edges.items[idx]);
    }

    // Measurement phase
    var samples = try std.ArrayList(u64).initCapacity(allocator, iterations);
    defer samples.deinit(allocator);

    var timer = try std.time.Timer.start();
    for (edges.items) |edge| {
        const start = timer.read();
        try storage.put_edge(edge);
        const elapsed = timer.read() - start;
        try samples.append(allocator, elapsed);
    }

    const result = calculate_benchmark_result("storage_edge_insert", samples.items);
    try harness.add_result(result);
}

/// Benchmark edge lookup operations
fn bench_edge_lookup(
    harness: *BenchmarkHarness,
    storage: *StorageEngine,
    allocator: std.mem.Allocator,
) !void {
    const iterations = harness.config.iterations;

    // First create blocks that edges will reference (referential integrity requirement)
    var block_ids = try std.ArrayList(BlockId).initCapacity(allocator, iterations * 2);
    defer block_ids.deinit(allocator);

    for (0..iterations * 2) |i| {
        const block = generate_test_block(allocator, i);
        try block_ids.append(allocator, block.id);
        try storage.put_block(block);
    }

    // Insert edges for lookup
    var source_ids = try std.ArrayList(BlockId).initCapacity(allocator, iterations);
    defer source_ids.deinit(allocator);

    for (0..iterations) |i| {
        const source_idx = i * 2;
        const target_idx = i * 2 + 1;
        const edge = GraphEdge{
            .source_id = block_ids.items[source_idx],
            .target_id = block_ids.items[target_idx],
            .edge_type = EdgeType.calls,
        };
        try source_ids.append(allocator, edge.source_id);
        try storage.put_edge(edge);
    }

    // Measurement phase
    var samples = try std.ArrayList(u64).initCapacity(allocator, iterations);
    defer samples.deinit(allocator);

    var timer = try std.time.Timer.start();
    for (source_ids.items) |source_id| {
        const start = timer.read();
        _ = storage.find_outgoing_edges(source_id);
        const elapsed = timer.read() - start;
        try samples.append(allocator, elapsed);
    }

    const result = calculate_benchmark_result("storage_edge_lookup", samples.items);
    try harness.add_result(result);
}

/// Benchmark graph traversal operations
fn bench_graph_traversal(
    harness: *BenchmarkHarness,
    storage: *StorageEngine,
    allocator: std.mem.Allocator,
) !void {
    const iterations = @min(100, harness.config.iterations); // Limit for graph operations

    // Build a simple graph structure
    const nodes_per_level = 10;
    const depth = 3;

    // Create nodes
    var root_id: ?BlockId = null;
    var prev_level_ids = try std.ArrayList(BlockId).initCapacity(harness.allocator, nodes_per_level);
    defer prev_level_ids.deinit(harness.allocator);

    for (0..depth) |level| {
        var current_level_ids = try std.ArrayList(BlockId).initCapacity(harness.allocator, nodes_per_level);
        defer current_level_ids.deinit(harness.allocator);

        for (0..nodes_per_level) |node| {
            // Create actual block to satisfy referential integrity
            const block_index = level * nodes_per_level + node;
            const block = generate_test_block(allocator, block_index);
            const block_id = block.id;
            try storage.put_block(block);

            try current_level_ids.append(harness.allocator, block_id);

            if (level == 0 and node == 0) {
                root_id = block_id;
            }

            // Connect to previous level
            if (level > 0) {
                for (prev_level_ids.items) |prev_id| {
                    const edge = GraphEdge{
                        .source_id = prev_id,
                        .target_id = block_id,
                        .edge_type = EdgeType.calls,
                    };
                    try storage.put_edge(edge);
                }
            }
        }

        // Swap levels
        prev_level_ids.clearRetainingCapacity();
        try prev_level_ids.appendSlice(harness.allocator, current_level_ids.items);
    }

    // Measurement phase - traverse from root
    var samples = try std.ArrayList(u64).initCapacity(harness.allocator, iterations);
    defer samples.deinit(allocator);

    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        const start = timer.read();
        _ = storage.find_outgoing_edges(root_id.?);
        const elapsed = timer.read() - start;
        try samples.append(allocator, elapsed);
    }

    const result = calculate_benchmark_result("storage_graph_traversal", samples.items);
    try harness.add_result(result);
}

/// Generate a test block with deterministic content
fn generate_test_block(allocator: std.mem.Allocator, index: usize) ContextBlock {
    const content = std.fmt.allocPrint(
        allocator,
        "fn test_{}() {{ return {}; }}",
        .{ index, index },
    ) catch "fn test() { return; }";

    return ContextBlock{
        .id = BlockId.generate(),
        .version = 1,
        .source_uri = "bench://test",
        .metadata_json = "{}",
        .content = content,
    };
}

// Note: generate_test_edge function removed - edges must reference existing blocks
// to maintain referential integrity. Edge creation is now inline with block creation.

/// Calculate benchmark statistics from samples
fn calculate_benchmark_result(name: []const u8, samples: []const u64) main.BenchmarkResult {
    const mean = calculate_mean(samples);
    const median = calculate_median(samples);
    const min = std.mem.min(u64, samples);
    const max = std.mem.max(u64, samples);
    const std_dev = calculate_std_dev(samples, mean);

    return main.BenchmarkResult{
        .name = name,
        .iterations = @intCast(samples.len),
        .mean_ns = mean,
        .median_ns = median,
        .min_ns = min,
        .max_ns = max,
        .std_dev_ns = std_dev,
        .ops_per_second = if (mean > 0) 1_000_000_000.0 / @as(f64, @floatFromInt(mean)) else 0,
    };
}

fn calculate_mean(samples: []const u64) u64 {
    if (samples.len == 0) return 0;
    var sum: u64 = 0;
    for (samples) |sample| {
        sum += sample;
    }
    return sum / samples.len;
}

fn calculate_median(samples: []const u64) u64 {
    if (samples.len == 0) return 0;
    // Note: This modifies the array, should copy first in production
    const sorted = @constCast(samples);
    std.mem.sort(u64, sorted, {}, std.sort.asc(u64));
    return sorted[sorted.len / 2];
}

fn calculate_std_dev(samples: []const u64, mean: u64) u64 {
    if (samples.len <= 1) return 0;
    var variance: u64 = 0;
    for (samples) |sample| {
        const diff = if (sample > mean) sample - mean else mean - sample;
        variance += diff * diff;
    }
    variance = variance / samples.len;
    return std.math.sqrt(variance);
}
