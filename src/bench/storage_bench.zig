//! Storage engine benchmarks for KausalDB.
//!
//! Measures performance of core storage operations including:
//! - Block write/read latency
//! - WAL append throughput
//! - Memtable flush performance
//! - SSTable scan speed
//! - Compaction throughput
//! - Graph edge index operations

const std = @import("std");
const builtin = @import("builtin");
const internal = @import("internal");

const Timer = std.time.Timer;
const Allocator = std.mem.Allocator;

// Core types
const BlockId = internal.BlockId;
const ContextBlock = internal.ContextBlock;
const GraphEdge = internal.GraphEdge;
const EdgeType = internal.EdgeType;
const StorageEngine = internal.StorageEngine;
const Config = internal.Config;
const SimulationVFS = internal.SimulationVFS;
const VFS = internal.vfs.VFS;
const SSTable = internal.sstable.SSTable;
const WAL = internal.wal.WAL;

// Benchmark utilities
const BenchmarkResult = @import("../bench/main.zig").BenchmarkResult;
const StatisticalSampler = @import("../bench/main.zig").StatisticalSampler;

const log = std.log.scoped(.storage_bench);

/// Storage benchmark suite.
pub const StorageBenchmarks = struct {
    allocator: Allocator,
    iterations: u32,
    warmup_iterations: u32,
    results: std.ArrayList(BenchmarkResult),

    pub fn init(allocator: Allocator, iterations: u32, warmup_iterations: u32) StorageBenchmarks {
        return .{
            .allocator = allocator,
            .iterations = iterations,
            .warmup_iterations = warmup_iterations,
            .results = std.ArrayList(BenchmarkResult).init(allocator),
        };
    }

    pub fn deinit(self: *StorageBenchmarks) void {
        self.results.deinit();
    }

    /// Run all storage benchmarks.
    pub fn run_all(self: *StorageBenchmarks) !void {
        log.info("Running storage benchmarks ({} iterations, {} warmup)", .{ self.iterations, self.warmup_iterations });

        try self.bench_block_write();
        try self.bench_block_read_hot();
        try self.bench_block_read_cold();
        try self.bench_block_delete();
        try self.bench_edge_insert();
        try self.bench_edge_lookup();
        try self.bench_wal_append();
        try self.bench_wal_recovery();
        try self.bench_memtable_flush();
        try self.bench_sstable_build();
        try self.bench_sstable_scan();
        try self.bench_compaction();
    }

    /// Benchmark block write performance.
    fn bench_block_write(self: *StorageBenchmarks) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        // Setup storage engine with SimulationVFS for deterministic benchmarking
        var sim_vfs = try SimulationVFS.init(alloc, 0x12345678);
        defer sim_vfs.deinit();

        var engine = try StorageEngine.init(alloc, sim_vfs.vfs(), "bench_storage");
        defer engine.deinit();
        try engine.startup();
        defer engine.shutdown() catch {};

        // Generate test blocks
        const blocks = try alloc.alloc(ContextBlock, self.iterations);
        for (blocks, 0..) |*block, i| {
            block.* = try generate_test_block(alloc, i);
        }

        var sampler = StatisticalSampler.init();
        var timer = try Timer.start();

        // Warmup
        for (0..self.warmup_iterations) |i| {
            const idx = i % blocks.len;
            try engine.put_block(blocks[idx]);
        }

        // Measurement
        for (blocks) |block| {
            const start = timer.read();
            try engine.put_block(block);
            const elapsed = timer.read() - start;
            try sampler.add_sample(elapsed);
        }

        const stats = sampler.calculate_stats();
        try self.results.append(.{
            .name = "storage/block_write",
            .iterations = self.iterations,
            .mean_ns = stats.mean,
            .median_ns = stats.median,
            .min_ns = stats.min,
            .max_ns = stats.max,
            .std_dev_ns = stats.std_dev,
            .ops_per_second = 1_000_000_000.0 / @as(f64, @floatFromInt(stats.mean)),
        });
    }

    /// Benchmark hot block read (from memtable).
    fn bench_block_read_hot(self: *StorageBenchmarks) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var sim_vfs = try SimulationVFS.init(alloc, 0x12345678);
        defer sim_vfs.deinit();

        var engine = try StorageEngine.init(alloc, sim_vfs.vfs(), "bench_storage");
        defer engine.deinit();
        try engine.startup();
        defer engine.shutdown() catch {};

        // Insert blocks into memtable
        const block_count = @min(1000, self.iterations);
        const block_ids = try alloc.alloc(BlockId, block_count);
        for (block_ids, 0..) |*id, i| {
            const block = try generate_test_block(alloc, i);
            id.* = block.id;
            try engine.put_block(block);
        }

        var sampler = StatisticalSampler.init();
        var timer = try Timer.start();

        // Warmup
        for (0..self.warmup_iterations) |i| {
            const idx = i % block_ids.len;
            _ = try engine.find_block(block_ids[idx]);
        }

        // Measurement
        for (0..self.iterations) |i| {
            const idx = i % block_ids.len;
            const start = timer.read();
            _ = try engine.find_block(block_ids[idx]);
            const elapsed = timer.read() - start;
            try sampler.add_sample(elapsed);
        }

        const stats = sampler.calculate_stats();
        try self.results.append(.{
            .name = "storage/block_read_hot",
            .iterations = self.iterations,
            .mean_ns = stats.mean,
            .median_ns = stats.median,
            .min_ns = stats.min,
            .max_ns = stats.max,
            .std_dev_ns = stats.std_dev,
            .ops_per_second = 1_000_000_000.0 / @as(f64, @floatFromInt(stats.mean)),
        });
    }

    /// Benchmark cold block read (from SSTable).
    fn bench_block_read_cold(self: *StorageBenchmarks) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var sim_vfs = try SimulationVFS.init(alloc, 0x12345678);
        defer sim_vfs.deinit();

        var engine = try StorageEngine.init(alloc, sim_vfs.vfs(), "bench_storage");
        defer engine.deinit();
        try engine.startup();
        defer engine.shutdown() catch {};

        // Insert blocks and flush to SSTable
        const block_count = @min(1000, self.iterations);
        const block_ids = try alloc.alloc(BlockId, block_count);
        for (block_ids, 0..) |*id, i| {
            const block = try generate_test_block(alloc, i);
            id.* = block.id;
            try engine.put_block(block);
        }

        // Force flush to SSTable
        try engine.coordinate_memtable_flush();

        var sampler = StatisticalSampler.init();
        var timer = try Timer.start();

        // Warmup
        for (0..self.warmup_iterations) |i| {
            const idx = i % block_ids.len;
            _ = try engine.find_block(block_ids[idx]);
        }

        // Measurement
        for (0..self.iterations) |i| {
            const idx = i % block_ids.len;
            const start = timer.read();
            _ = try engine.find_block(block_ids[idx]);
            const elapsed = timer.read() - start;
            try sampler.add_sample(elapsed);
        }

        const stats = sampler.calculate_stats();
        try self.results.append(.{
            .name = "storage/block_read_cold",
            .iterations = self.iterations,
            .mean_ns = stats.mean,
            .median_ns = stats.median,
            .min_ns = stats.min,
            .max_ns = stats.max,
            .std_dev_ns = stats.std_dev,
            .ops_per_second = 1_000_000_000.0 / @as(f64, @floatFromInt(stats.mean)),
        });
    }

    /// Benchmark block deletion.
    fn bench_block_delete(self: *StorageBenchmarks) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var sim_vfs = try SimulationVFS.init(alloc, 0x12345678);
        defer sim_vfs.deinit();

        var sampler = StatisticalSampler.init();
        var timer = try Timer.start();

        // Measure delete operations
        for (0..self.iterations) |i| {
            // Recreate engine for each iteration to ensure consistent state
            var engine = try StorageEngine.init(alloc, sim_vfs.vfs(), "bench_storage");
            defer engine.deinit();
            try engine.startup();
            defer engine.shutdown() catch {};

            // Insert a block
            const block = try generate_test_block(alloc, i);
            try engine.put_block(block);

            // Measure deletion
            const start = timer.read();
            try engine.delete_block(block.id);
            const elapsed = timer.read() - start;

            if (i >= self.warmup_iterations) {
                try sampler.add_sample(elapsed);
            }
        }

        const stats = sampler.calculate_stats();
        try self.results.append(.{
            .name = "storage/block_delete",
            .iterations = self.iterations - self.warmup_iterations,
            .mean_ns = stats.mean,
            .median_ns = stats.median,
            .min_ns = stats.min,
            .max_ns = stats.max,
            .std_dev_ns = stats.std_dev,
            .ops_per_second = 1_000_000_000.0 / @as(f64, @floatFromInt(stats.mean)),
        });
    }

    /// Benchmark edge insertion.
    fn bench_edge_insert(self: *StorageBenchmarks) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var sim_vfs = try SimulationVFS.init(alloc, 0x12345678);
        defer sim_vfs.deinit();

        var engine = try StorageEngine.init(alloc, sim_vfs.vfs(), "bench_storage");
        defer engine.deinit();
        try engine.startup();
        defer engine.shutdown() catch {};

        // Generate test edges
        const edges = try alloc.alloc(GraphEdge, self.iterations);
        for (edges, 0..) |*edge, i| {
            edge.* = try generate_test_edge(i);
        }

        var sampler = StatisticalSampler.init();
        var timer = try Timer.start();

        // Warmup
        for (0..self.warmup_iterations) |i| {
            const idx = i % edges.len;
            try engine.put_edge(edges[idx]);
        }

        // Measurement
        for (edges) |edge| {
            const start = timer.read();
            try engine.put_edge(edge);
            const elapsed = timer.read() - start;
            try sampler.add_sample(elapsed);
        }

        const stats = sampler.calculate_stats();
        try self.results.append(.{
            .name = "storage/edge_insert",
            .iterations = self.iterations,
            .mean_ns = stats.mean,
            .median_ns = stats.median,
            .min_ns = stats.min,
            .max_ns = stats.max,
            .std_dev_ns = stats.std_dev,
            .ops_per_second = 1_000_000_000.0 / @as(f64, @floatFromInt(stats.mean)),
        });
    }

    /// Benchmark edge lookup.
    fn bench_edge_lookup(self: *StorageBenchmarks) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var sim_vfs = try SimulationVFS.init(alloc, 0x12345678);
        defer sim_vfs.deinit();

        var engine = try StorageEngine.init(alloc, sim_vfs.vfs(), "bench_storage");
        defer engine.deinit();
        try engine.startup();
        defer engine.shutdown() catch {};

        // Insert edges
        const edge_count = @min(1000, self.iterations);
        const source_ids = try alloc.alloc(BlockId, edge_count);
        for (source_ids, 0..) |*id, i| {
            const edge = try generate_test_edge(i);
            id.* = edge.source_id;
            try engine.put_edge(edge);
        }

        var sampler = StatisticalSampler.init();
        var timer = try Timer.start();

        // Warmup
        for (0..self.warmup_iterations) |i| {
            const idx = i % source_ids.len;
            _ = try engine.find_outgoing_edges(source_ids[idx]);
        }

        // Measurement
        for (0..self.iterations) |i| {
            const idx = i % source_ids.len;
            const start = timer.read();
            _ = try engine.find_outgoing_edges(source_ids[idx]);
            const elapsed = timer.read() - start;
            try sampler.add_sample(elapsed);
        }

        const stats = sampler.calculate_stats();
        try self.results.append(.{
            .name = "storage/edge_lookup",
            .iterations = self.iterations,
            .mean_ns = stats.mean,
            .median_ns = stats.median,
            .min_ns = stats.min,
            .max_ns = stats.max,
            .std_dev_ns = stats.std_dev,
            .ops_per_second = 1_000_000_000.0 / @as(f64, @floatFromInt(stats.mean)),
        });
    }

    /// Benchmark WAL append operations.
    fn bench_wal_append(self: *StorageBenchmarks) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var sim_vfs = try SimulationVFS.init(alloc, 0x12345678);
        defer sim_vfs.deinit();

        var wal = try WAL.init(alloc, sim_vfs.vfs(), "bench_wal");
        defer wal.deinit();
        try wal.startup();
        defer wal.shutdown() catch {};

        // Generate test entries
        const blocks = try alloc.alloc(ContextBlock, self.iterations);
        for (blocks, 0..) |*block, i| {
            block.* = try generate_test_block(alloc, i);
        }

        var sampler = StatisticalSampler.init();
        var timer = try Timer.start();

        // Warmup
        for (0..self.warmup_iterations) |i| {
            const idx = i % blocks.len;
            try wal.append_put_block(blocks[idx]);
        }

        // Measurement
        for (blocks) |block| {
            const start = timer.read();
            try wal.append_put_block(block);
            const elapsed = timer.read() - start;
            try sampler.add_sample(elapsed);
        }

        const stats = sampler.calculate_stats();
        try self.results.append(.{
            .name = "storage/wal_append",
            .iterations = self.iterations,
            .mean_ns = stats.mean,
            .median_ns = stats.median,
            .min_ns = stats.min,
            .max_ns = stats.max,
            .std_dev_ns = stats.std_dev,
            .ops_per_second = 1_000_000_000.0 / @as(f64, @floatFromInt(stats.mean)),
        });
    }

    /// Benchmark WAL recovery speed.
    fn bench_wal_recovery(self: *StorageBenchmarks) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var sim_vfs = try SimulationVFS.init(alloc, 0x12345678);
        defer sim_vfs.deinit();

        // Prepare WAL with entries
        const entry_count = @min(10000, self.iterations * 10);
        {
            var wal = try WAL.init(alloc, sim_vfs.vfs(), "bench_wal");
            defer wal.deinit();
            try wal.startup();

            for (0..entry_count) |i| {
                const block = try generate_test_block(alloc, i);

                try wal.append_put_block(block);
            }

            try wal.shutdown();
        }

        var sampler = StatisticalSampler.init();
        var timer = try Timer.start();

        // Measure recovery time
        for (0..self.iterations) |i| {
            if (i >= self.warmup_iterations) {
                const start = timer.read();

                var wal = try WAL.init(alloc, sim_vfs.vfs(), "bench_wal");
                defer wal.deinit();
                try wal.startup(); // This triggers recovery
                try wal.shutdown();

                const elapsed = timer.read() - start;
                try sampler.add_sample(elapsed);
            } else {
                // Warmup without measurement
                var wal = try WAL.init(alloc, sim_vfs.vfs(), "bench_wal");
                defer wal.deinit();
                try wal.startup();
                try wal.shutdown();
            }
        }

        const stats = sampler.calculate_stats();
        const entries_per_second = @as(f64, @floatFromInt(entry_count)) /
            (@as(f64, @floatFromInt(stats.mean)) / 1_000_000_000.0);

        try self.results.append(.{
            .name = "storage/wal_recovery",
            .iterations = self.iterations - self.warmup_iterations,
            .mean_ns = stats.mean,
            .median_ns = stats.median,
            .min_ns = stats.min,
            .max_ns = stats.max,
            .std_dev_ns = stats.std_dev,
            .ops_per_second = entries_per_second,
        });
    }

    /// Benchmark memtable flush performance.
    fn bench_memtable_flush(self: *StorageBenchmarks) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var sim_vfs = try SimulationVFS.init(alloc, 0x12345678);
        defer sim_vfs.deinit();

        const blocks_per_flush = 10000;
        var sampler = StatisticalSampler.init();
        var timer = try Timer.start();

        for (0..self.iterations) |iter| {
            var engine = try StorageEngine.init(alloc, sim_vfs.vfs(), "bench_storage");
            defer engine.deinit();
            try engine.startup();
            defer engine.shutdown() catch {};

            // Fill memtable
            for (0..blocks_per_flush) |i| {
                const block = try generate_test_block(alloc, iter * blocks_per_flush + i);
                try engine.put_block(block);
            }

            // Measure flush time
            if (iter >= self.warmup_iterations) {
                const start = timer.read();
                try engine.coordinate_memtable_flush();
                const elapsed = timer.read() - start;
                try sampler.add_sample(elapsed);
            } else {
                try engine.coordinate_memtable_flush();
            }
        }

        const stats = sampler.calculate_stats();
        try self.results.append(.{
            .name = "storage/memtable_flush",
            .iterations = self.iterations - self.warmup_iterations,
            .mean_ns = stats.mean,
            .median_ns = stats.median,
            .min_ns = stats.min,
            .max_ns = stats.max,
            .std_dev_ns = stats.std_dev,
            .ops_per_second = 1_000_000_000.0 / @as(f64, @floatFromInt(stats.mean)),
        });
    }

    /// Benchmark SSTable build performance.
    fn bench_sstable_build(self: *StorageBenchmarks) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var sim_vfs = try SimulationVFS.init(alloc, 0x12345678);
        defer sim_vfs.deinit();

        const blocks_per_sstable = 1000;
        const blocks = try alloc.alloc(ContextBlock, blocks_per_sstable);
        for (blocks, 0..) |*block, i| {
            block.* = try generate_test_block(alloc, i);
        }

        var sampler = StatisticalSampler.init();
        var timer = try Timer.start();

        for (0..self.iterations) |iter| {
            const path = try std.fmt.allocPrint(alloc, "bench_sstable_{}", .{iter});
            defer alloc.free(path);

            if (iter >= self.warmup_iterations) {
                const start = timer.read();

                var builder = try SSTable.Builder.init(alloc, sim_vfs.vfs(), path);
                defer builder.deinit();
                for (blocks) |block| {
                    try builder.add_block(block);
                }
                _ = try builder.finalize();

                const elapsed = timer.read() - start;
                try sampler.add_sample(elapsed);
            } else {
                var builder = try SSTable.Builder.init(alloc, sim_vfs.vfs(), path);
                defer builder.deinit();
                for (blocks) |block| {
                    try builder.add_block(block);
                }
                _ = try builder.finalize();
            }
        }

        const stats = sampler.calculate_stats();
        const blocks_per_second = @as(f64, @floatFromInt(blocks_per_sstable)) /
            (@as(f64, @floatFromInt(stats.mean)) / 1_000_000_000.0);

        try self.results.append(.{
            .name = "storage/sstable_build",
            .iterations = self.iterations - self.warmup_iterations,
            .mean_ns = stats.mean,
            .median_ns = stats.median,
            .min_ns = stats.min,
            .max_ns = stats.max,
            .std_dev_ns = stats.std_dev,
            .ops_per_second = blocks_per_second,
        });
    }

    /// Benchmark SSTable scan performance.
    fn bench_sstable_scan(self: *StorageBenchmarks) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var sim_vfs = try SimulationVFS.init(alloc, 0x12345678);
        defer sim_vfs.deinit();

        // Build SSTable with test data
        const blocks_count = 10000;
        const sstable_path = "bench_sstable_scan";
        {
            var builder = try SSTable.Builder.init(alloc, sim_vfs.vfs(), sstable_path);
            defer builder.deinit();
            for (0..blocks_count) |i| {
                const block = try generate_test_block(alloc, i);
                try builder.add_block(block);
            }
            _ = try builder.finalize();
        }

        var sampler = StatisticalSampler.init();
        var timer = try Timer.start();

        for (0..self.iterations) |iter| {
            var sstable = try SSTable.open(alloc, sim_vfs.vfs(), sstable_path);
            defer sstable.close();

            if (iter >= self.warmup_iterations) {
                const start = timer.read();

                var iter_blocks = try sstable.iterator();
                var count: u32 = 0;
                while (try iter_blocks.next()) |_| {
                    count += 1;
                }

                const elapsed = timer.read() - start;
                try sampler.add_sample(elapsed);
            } else {
                var iter_blocks = try sstable.iterator();
                while (try iter_blocks.next()) |_| {}
            }
        }

        const stats = sampler.calculate_stats();
        const blocks_per_second = @as(f64, @floatFromInt(blocks_count)) /
            (@as(f64, @floatFromInt(stats.mean)) / 1_000_000_000.0);

        try self.results.append(.{
            .name = "storage/sstable_scan",
            .iterations = self.iterations - self.warmup_iterations,
            .mean_ns = stats.mean,
            .median_ns = stats.median,
            .min_ns = stats.min,
            .max_ns = stats.max,
            .std_dev_ns = stats.std_dev,
            .ops_per_second = blocks_per_second,
        });
    }

    /// Benchmark compaction throughput.
    fn bench_compaction(self: *StorageBenchmarks) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var sim_vfs = try SimulationVFS.init(alloc, 0x12345678);
        defer sim_vfs.deinit();

        var sampler = StatisticalSampler.init();
        var timer = try Timer.start();

        for (0..self.iterations) |iter| {
            var engine = try StorageEngine.init(alloc, sim_vfs.vfs(), "bench_compaction");
            defer engine.deinit();
            try engine.startup();
            defer engine.shutdown() catch {};

            // Create multiple SSTables by flushing
            const flushes = 4;
            const blocks_per_flush = 1000;
            for (0..flushes) |flush_idx| {
                for (0..blocks_per_flush) |block_idx| {
                    const block = try generate_test_block(alloc, flush_idx * blocks_per_flush + block_idx);
                    try engine.put_block(block);
                }
                try engine.coordinate_memtable_flush();
            }

            // Measure compaction time
            if (iter >= self.warmup_iterations) {
                const start = timer.read();
                try engine.try_compact();
                const elapsed = timer.read() - start;
                try sampler.add_sample(elapsed);
            } else {
                try engine.try_compact();
            }
        }

        const stats = sampler.calculate_stats();
        try self.results.append(.{
            .name = "storage/compaction",
            .iterations = self.iterations - self.warmup_iterations,
            .mean_ns = stats.mean,
            .median_ns = stats.median,
            .min_ns = stats.min,
            .max_ns = stats.max,
            .std_dev_ns = stats.std_dev,
            .ops_per_second = 1_000_000_000.0 / @as(f64, @floatFromInt(stats.mean)),
        });
    }

    pub fn print_results(self: *StorageBenchmarks) void {
        std.debug.print("\nStorage Benchmark Results:\n", .{});
        std.debug.print("=" ** 80 ++ "\n", .{});

        for (self.results.items) |result| {
            result.print(false);
        }
    }
};

// Test data generation helpers
fn generate_test_block(allocator: Allocator, index: usize) !ContextBlock {
    const id = try BlockId.from_hex("00000000000000000000000000000000");
    const source_uri = try std.fmt.allocPrint(allocator, "test://file_{}.zig", .{index});
    const metadata = try std.fmt.allocPrint(allocator, "{{\"index\":{}}}", .{index});
    const content = try std.fmt.allocPrint(allocator, "fn test_{}() void {{}}", .{index});

    return ContextBlock{
        .id = id,
        .version = 1,
        .source_uri = source_uri,
        .metadata_json = metadata,
        .content = content,
    };
}

fn generate_test_edge(index: usize) !GraphEdge {
    const source_id = try BlockId.from_hex("00000000000000000000000000000000");
    const target_id = try BlockId.from_hex("11111111111111111111111111111111");

    return GraphEdge{
        .source_id = source_id,
        .target_id = target_id,
        .edge_type = EdgeType.calls,
        .weight = @as(f32, @floatFromInt(index % 100)) / 100.0,
    };
}
