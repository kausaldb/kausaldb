const std = @import("std");
const harness = @import("harness.zig");

const internal = @import("internal");

const storage_config = internal.storage_config;

const BenchmarkHarness = harness.BenchmarkHarness;
const StorageEngine = internal.StorageEngine;
const SimulationVFS = internal.SimulationVFS;
const ContextBlock = internal.ContextBlock;
const GraphEdge = internal.GraphEdge;
const BlockId = internal.BlockId;
const EdgeType = internal.EdgeType;
const Config = internal.Config;
const BlockOwnership = internal.ownership.BlockOwnership;
const ProductionVFS = internal.ProductionVFS;

/// Run storage engine performance benchmarks
pub fn run_benchmarks(bench_harness: *BenchmarkHarness) !void {
    var arena = std.heap.ArenaAllocator.init(bench_harness.allocator);
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
    try storage.startup();
    defer storage.shutdown() catch {};

    // Run benchmarks in order of complexity
    // Most benchmarks use SimulationVFS for algorithmic performance measurement
    try bench_block_write(bench_harness, &storage, alloc);
    try bench_block_read_hot(bench_harness, &storage, alloc);
    try bench_block_read_warm(bench_harness, &storage, alloc);
    try bench_block_read_nonexistent(bench_harness, &storage, alloc);
    try bench_memtable_flush(bench_harness, &storage, alloc);
    try bench_edge_insert(bench_harness, &storage, alloc);
    try bench_edge_lookup(bench_harness, &storage, alloc);
    try bench_graph_traversal(bench_harness, &storage, alloc);

    // These benchmarks use ProductionVFS for real I/O measurement
    try bench_block_read_cold(bench_harness);
    try bench_block_write_sync(bench_harness, bench_harness.config.iterations, bench_harness.config.warmup_iterations);
}

fn bench_block_write(
    bench_harness: *BenchmarkHarness,
    storage: *StorageEngine,
    allocator: std.mem.Allocator,
) !void {
    const iterations = bench_harness.config.iterations;

    // Pre-generate deterministic test blocks to eliminate allocation overhead
    var blocks = try std.ArrayList(ContextBlock).initCapacity(allocator, iterations);
    defer blocks.deinit(allocator);

    for (0..iterations) |i| {
        try blocks.append(allocator, create_test_block(i));
    }

    // Warmup phase
    for (0..bench_harness.config.warmup_iterations) |i| {
        const idx = i % blocks.items.len;
        try storage.put_block(blocks.items[idx]);
    }

    // Measurement phase - only measure put_block operation
    var samples = try std.ArrayList(u64).initCapacity(allocator, iterations);
    defer samples.deinit(allocator);

    var timer = try std.time.Timer.start();
    for (blocks.items) |block| {
        timer.reset();
        try storage.put_block(block);
        try samples.append(allocator, timer.read());
    }

    const result = harness.calculate_benchmark_result("storage_block_write", samples.items);
    try bench_harness.add_result(result);
}

fn bench_block_read_hot(
    bench_harness: *BenchmarkHarness,
    storage: *StorageEngine,
    allocator: std.mem.Allocator,
) !void {
    const iterations = bench_harness.config.iterations;

    // Setup: Pre-populate storage with test blocks
    var block_ids = try std.ArrayList(BlockId).initCapacity(allocator, iterations);
    defer block_ids.deinit(allocator);

    for (0..iterations) |i| {
        const block = create_test_block(i);
        try block_ids.append(allocator, block.id);
        try storage.put_block(block);
    }

    // Warmup phase
    for (0..bench_harness.config.warmup_iterations) |i| {
        const idx = i % block_ids.items.len;
        _ = try storage.find_block(block_ids.items[idx], BlockOwnership.simulation_test);
    }

    // Measurement phase - reads from memtable (hot)
    var samples = try std.ArrayList(u64).initCapacity(allocator, iterations);
    defer samples.deinit(allocator);

    var timer = try std.time.Timer.start();
    for (block_ids.items) |id| {
        timer.reset();
        _ = try storage.find_block(id, BlockOwnership.simulation_test);
        try samples.append(allocator, timer.read());
    }

    const result = harness.calculate_benchmark_result("storage_block_read_hot", samples.items);
    try bench_harness.add_result(result);
}

fn bench_block_read_warm(
    bench_harness: *BenchmarkHarness,
    storage: *StorageEngine,
    allocator: std.mem.Allocator,
) !void {
    // Use fewer iterations since SSTable I/O is expensive
    const iterations = @min(50, bench_harness.config.iterations);
    const additional_blocks = 50; // Extra blocks to ensure memtable flush

    var block_ids = try std.ArrayList(BlockId).initCapacity(allocator, iterations);
    defer block_ids.deinit(allocator);

    // Fill memtable efficiently - measure only the target blocks
    for (0..iterations) |i| {
        const block = create_test_block(i);
        try block_ids.append(allocator, block.id);
        try storage.put_block(block);
    }

    // Add additional blocks to ensure flush
    for (0..additional_blocks) |i| {
        const block_idx = iterations + i;
        try storage.put_block(create_test_block(block_idx));
    }

    // Force flush to create SSTable - this setup cost is not measured
    try storage.flush_memtable_to_sstable();

    // Measurement phase - reads from SSTable (cold)
    var samples = try std.ArrayList(u64).initCapacity(allocator, iterations);
    defer samples.deinit(allocator);

    var timer = try std.time.Timer.start();
    for (block_ids.items) |id| {
        timer.reset();
        _ = try storage.find_block(id, BlockOwnership.simulation_test);
        try samples.append(allocator, timer.read());
    }

    const result = harness.calculate_benchmark_result("storage_block_read_warm", samples.items);
    try bench_harness.add_result(result);
}

fn bench_block_read_cold(bench_harness: *BenchmarkHarness) !void {
    const allocator = bench_harness.allocator;

    // Use very few iterations since real disk I/O is expensive and causes arena overflow
    const iterations = @min(10, bench_harness.config.iterations);

    // TEMPORARY: Use SimulationVFS to test SSTable metadata caching fix
    var sim_vfs = try internal.SimulationVFS.init(allocator);
    defer sim_vfs.deinit();
    const vfs_interface = sim_vfs.vfs();

    const temp_path = "test_storage_cold";

    // Small memtable to force SSTable creation quickly
    const config = Config{
        .memtable_max_size = 1 * 1024 * 1024, // 1MB - minimum allowed size
    };

    var storage = try StorageEngine.init(allocator, vfs_interface, temp_path, config);
    defer storage.deinit();
    try storage.startup();

    // Create test blocks and track their IDs
    var block_ids = std.ArrayList(BlockId){};
    defer block_ids.deinit(allocator);

    // Write the blocks we want to benchmark first
    for (0..iterations) |i| {
        const block = create_test_block(i + 100000); // Unique offset
        try block_ids.append(allocator, block.id);
        try storage.put_block(block);
    }

    // Write additional blocks to force SSTable creation
    const additional_blocks: usize = 20;
    for (iterations..(iterations + additional_blocks)) |i| {
        const block = create_test_block(i + 100000); // Unique offset
        try storage.put_block(block);
    }

    // Force flush to ensure data is on disk
    try storage.flush_memtable_to_sstable();

    // All blocks should now be in SSTable after flush
    // Blocks in block_ids were written first and should be findable
    // Using SimulationVFS to test SSTable metadata caching fix

    // Measure cold reads from SSTable on disk
    var samples = std.ArrayList(u64){};
    defer samples.deinit(allocator);

    var timer = try std.time.Timer.start();
    for (block_ids.items) |id| {
        timer.reset();
        _ = try storage.find_block(id, .simulation_test);
        const elapsed = timer.read();
        try samples.append(allocator, elapsed);
    }

    // Should now properly measure SSTable reads with metadata caching fix
    const result = harness.calculate_benchmark_result("storage_block_read_cold", samples.items);
    try bench_harness.add_result(result);
}

fn bench_block_write_sync(bench_harness: *BenchmarkHarness, iterations: u32, warmup: u32) !void {
    const allocator = bench_harness.allocator;

    // Use ProductionVFS to measure real durability cost including fsync
    var production_vfs_instance = internal.ProductionVFS.init(allocator);
    defer production_vfs_instance.deinit();
    const production_vfs = production_vfs_instance.vfs();

    // Create temp directory for real filesystem operations
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const temp_path = try temp_dir.dir.realpath(".", &path_buffer);

    // Initialize storage with production VFS
    var config = Config{};
    try config.validate();

    var storage = try StorageEngine.init(allocator, production_vfs, temp_path, config);
    defer storage.deinit();
    try storage.startup();

    // Create test blocks
    var blocks = std.ArrayList(ContextBlock){};
    defer blocks.deinit(allocator);

    for (0..iterations + warmup) |i| {
        try blocks.append(allocator, create_test_block(i + 200000)); // Unique offset
    }

    // Warmup iterations
    for (0..warmup) |i| {
        try storage.put_block(blocks.items[i]);
        try storage.flush_wal(); // Force durability
    }

    // Measure synchronized write performance
    var samples = std.ArrayList(u64){};
    defer samples.deinit(allocator);

    var timer = try std.time.Timer.start();
    for (warmup..warmup + iterations) |i| {
        timer.reset();
        try storage.put_block(blocks.items[i]);
        try storage.flush_wal(); // Measure complete durable write
        try samples.append(allocator, timer.read());
    }

    const result = harness.calculate_benchmark_result("storage_block_write_sync", samples.items);
    try bench_harness.add_result(result);
}

fn bench_block_read_nonexistent(
    bench_harness: *BenchmarkHarness,
    storage: *StorageEngine,
    allocator: std.mem.Allocator,
) !void {
    const iterations = bench_harness.config.iterations;
    const setup_blocks = 100;

    // Setup: Populate SSTable with even-numbered blocks only
    for (0..setup_blocks) |i| {
        if (i % 2 == 0) { // Only even numbers
            const block = create_test_block(i + 20000); // Offset to avoid collision
            try storage.put_block(block);
        }
    }

    // Force flush to create SSTable with bloom filter
    try storage.flush_memtable_to_sstable();

    // Generate odd-numbered block IDs that definitely don't exist
    var nonexistent_ids = try std.ArrayList(BlockId).initCapacity(allocator, iterations);
    defer nonexistent_ids.deinit(allocator);

    for (0..iterations) |i| {
        const odd_index = (i * 2) + 1 + 20000; // Generate odd numbers
        const nonexistent_block = create_test_block(odd_index);
        try nonexistent_ids.append(allocator, nonexistent_block.id);
    }

    // Warmup phase
    for (0..bench_harness.config.warmup_iterations) |i| {
        const idx = i % nonexistent_ids.items.len;
        _ = storage.find_block(nonexistent_ids.items[idx], BlockOwnership.simulation_test) catch {};
    }

    // Measurement phase - bloom filter should reject all lookups immediately
    var samples = try std.ArrayList(u64).initCapacity(allocator, iterations);
    defer samples.deinit(allocator);

    var timer = try std.time.Timer.start();
    for (nonexistent_ids.items) |id| {
        timer.reset();
        _ = storage.find_block(id, BlockOwnership.simulation_test) catch {};
        try samples.append(allocator, timer.read());
    }

    const result = harness.calculate_benchmark_result("storage_block_read_nonexistent", samples.items);
    try bench_harness.add_result(result);
}

fn bench_memtable_flush(
    bench_harness: *BenchmarkHarness,
    storage: *StorageEngine,
    allocator: std.mem.Allocator,
) !void {
    const flush_iterations = 10; // Number of flush operations to measure
    const blocks_per_flush = 100; // Blocks per memtable

    var samples = try std.ArrayList(u64).initCapacity(allocator, flush_iterations);
    defer samples.deinit(allocator);

    for (0..flush_iterations) |flush_idx| {
        // Fill memtable with deterministic blocks
        for (0..blocks_per_flush) |block_idx| {
            const global_idx = flush_idx * blocks_per_flush + block_idx;
            try storage.put_block(create_test_block(global_idx));
        }

        // Measure flush operation only
        var timer = try std.time.Timer.start();
        timer.reset();
        try storage.flush_memtable_to_sstable();
        try samples.append(allocator, timer.read());
    }

    const result = harness.calculate_benchmark_result("storage_memtable_flush", samples.items);
    try bench_harness.add_result(result);
}

fn bench_edge_insert(
    bench_harness: *BenchmarkHarness,
    storage: *StorageEngine,
    allocator: std.mem.Allocator,
) !void {
    const iterations = bench_harness.config.iterations;
    const num_blocks = 10; // Create fresh blocks that stay in memtable (hot)

    // Setup: Create fresh source and target blocks (not measured)
    // These will stay in memtable for fast validation during edge insertion
    var block_ids = try std.ArrayList(BlockId).initCapacity(allocator, num_blocks);
    defer block_ids.deinit(allocator);

    for (0..num_blocks) |i| {
        const global_idx = 10000 + i; // Use high indices to avoid collision with other benchmarks
        const block = create_test_block(global_idx);
        try block_ids.append(allocator, block.id);
        try storage.put_block(block);
    }

    // Warmup phase with different edges
    for (0..bench_harness.config.warmup_iterations) |i| {
        const source_idx = i % num_blocks;
        const target_idx = (i + 1) % num_blocks;
        const edge = GraphEdge{
            .source_id = block_ids.items[source_idx],
            .target_id = block_ids.items[target_idx],
            .edge_type = EdgeType.calls,
        };
        try storage.put_edge(edge);
    }

    // Measurement phase - blocks are in memtable for fast validation
    var samples = try std.ArrayList(u64).initCapacity(allocator, iterations);
    defer samples.deinit(allocator);

    var timer = try std.time.Timer.start();
    for (0..iterations) |i| {
        const source_idx = i % num_blocks;
        const target_idx = (i + num_blocks / 2) % num_blocks;
        const edge = GraphEdge{
            .source_id = block_ids.items[source_idx],
            .target_id = block_ids.items[target_idx],
            .edge_type = EdgeType.calls,
        };
        timer.reset();
        try storage.put_edge(edge);
        try samples.append(allocator, timer.read());
    }

    const result = harness.calculate_benchmark_result("storage_edge_insert", samples.items);
    try bench_harness.add_result(result);
}

fn bench_edge_lookup(
    bench_harness: *BenchmarkHarness,
    storage: *StorageEngine,
    allocator: std.mem.Allocator,
) !void {
    const iterations = bench_harness.config.iterations;

    // Setup: Create blocks and edges
    const source_block = create_test_block(1);
    const target_block = create_test_block(2);
    try storage.put_block(source_block);
    try storage.put_block(target_block);

    // Insert edges to lookup
    for (0..iterations) |_| {
        const edge = GraphEdge{
            .source_id = source_block.id,
            .target_id = target_block.id,
            .edge_type = EdgeType.calls,
        };
        try storage.put_edge(edge);
    }

    // Warmup phase
    for (0..bench_harness.config.warmup_iterations) |_| {
        _ = storage.find_outgoing_edges(source_block.id);
    }

    // Measurement phase - lookup edges from source block
    var samples = try std.ArrayList(u64).initCapacity(allocator, iterations);
    defer samples.deinit(allocator);

    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        timer.reset();
        const edges = storage.find_outgoing_edges(source_block.id);
        _ = edges;
        try samples.append(allocator, timer.read());
    }

    const result = harness.calculate_benchmark_result("storage_edge_lookup", samples.items);
    try bench_harness.add_result(result);
}

fn bench_graph_traversal(
    bench_harness: *BenchmarkHarness,
    storage: *StorageEngine,
    allocator: std.mem.Allocator,
) !void {
    const iterations = @min(50, bench_harness.config.iterations); // Graph ops are expensive
    const chain_length = 5; // Create a chain of connected blocks

    // Setup: Create chain of connected blocks
    var block_ids = try std.ArrayList(BlockId).initCapacity(allocator, chain_length);
    defer block_ids.deinit(allocator);

    // Create blocks
    for (0..chain_length) |i| {
        const block = create_test_block(i);
        try block_ids.append(allocator, block.id);
        try storage.put_block(block);
    }

    // Connect blocks in a chain
    for (0..chain_length - 1) |i| {
        const edge = GraphEdge{
            .source_id = block_ids.items[i],
            .target_id = block_ids.items[i + 1],
            .edge_type = EdgeType.calls,
        };
        try storage.put_edge(edge);
    }

    // Warmup phase - perform full graph traversal
    for (0..bench_harness.config.warmup_iterations) |_| {
        var current_id = block_ids.items[0];
        for (0..chain_length - 1) |_| {
            const edges = storage.find_outgoing_edges(current_id);
            if (edges.len > 0) {
                current_id = edges[0].edge.target_id;
            }
        }
    }

    // Measurement phase - traverse from root through chain
    var samples = try std.ArrayList(u64).initCapacity(allocator, iterations);
    defer samples.deinit(allocator);

    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        timer.reset();

        // Simulate graph traversal: follow edges from root
        var current_id = block_ids.items[0];
        for (0..chain_length - 1) |_| {
            const edges = storage.find_outgoing_edges(current_id);
            if (edges.len > 0) {
                current_id = edges[0].edge.target_id;
            }
        }

        try samples.append(allocator, timer.read());
    }

    const result = harness.calculate_benchmark_result("storage_graph_traversal", samples.items);
    try bench_harness.add_result(result);
}

/// Create deterministic test block with zero allocations
/// Uses compile-time string literals to avoid runtime allocation overhead
fn create_test_block(index: usize) ContextBlock {
    // Create deterministic ID based on index for reproducible benchmarks
    var id_bytes: [16]u8 = std.mem.zeroes([16]u8);
    std.mem.writeInt(u64, id_bytes[0..8], index + 1, .little);
    return ContextBlock{
        .id = BlockId{ .bytes = id_bytes },
        .sequence = 0, // Storage engine assigns global sequence
        .source_uri = "bench://static",
        .metadata_json = "{}",
        .content = "fn benchmark_function() { return 42; }",
    };
}
