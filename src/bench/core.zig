//! Core component micro-benchmarks for KausalDB.
//! Measures performance of fundamental operations like hashing, bloom filters, and memory allocation.

const std = @import("std");

const internal = @import("internal");

const harness = @import("harness.zig");

const BenchmarkHarness = harness.BenchmarkHarness;
const Timer = std.time.Timer;

/// Main entry point called by the benchmark runner.
pub fn run_benchmarks(bench_harness: *BenchmarkHarness) !void {
    // 1. SETUP: Initialize test environment
    // Core benchmarks don't need storage, just memory

    // 2. RUN BENCHMARKS
    try bench_block_id_generation(bench_harness);
    try bench_block_id_hashing(bench_harness);
    try bench_block_id_comparison(bench_harness);
    try bench_arena_allocation_small(bench_harness);
    try bench_arena_allocation_large(bench_harness);
    try bench_context_block_clone(bench_harness);
    try bench_edge_comparison(bench_harness);
}

/// Benchmark BlockId generation
fn bench_block_id_generation(bench_harness: *BenchmarkHarness) !void {
    const iterations = bench_harness.config.iterations;
    const warmup = bench_harness.config.warmup_iterations;

    // 3. COLLECT SAMPLES
    var samples = std.array_list.Managed(u64).init(bench_harness.allocator);
    defer samples.deinit();

    // 4. WARMUP
    for (0..warmup) |_| {
        _ = internal.BlockId.generate();
    }

    // 5. MEASUREMENT
    var timer = try Timer.start();
    for (0..iterations) |_| {
        timer.reset();
        _ = internal.BlockId.generate();
        try samples.append(timer.read());
    }

    // 6. CALCULATE AND REPORT
    const result = harness.calculate_benchmark_result("core/block_id_generation", samples.items);
    try bench_harness.add_result(result);
}

/// Benchmark BlockId hashing
fn bench_block_id_hashing(bench_harness: *BenchmarkHarness) !void {
    const iterations = bench_harness.config.iterations;
    const warmup = bench_harness.config.warmup_iterations;

    // Pre-generate IDs to isolate hashing cost
    var block_ids = std.array_list.Managed(internal.BlockId).init(bench_harness.allocator);
    defer block_ids.deinit();
    try block_ids.ensureTotalCapacity(iterations);

    for (0..iterations) |i| {
        try block_ids.append(internal.BlockId.from_u64(i));
    }

    var samples = std.array_list.Managed(u64).init(bench_harness.allocator);
    defer samples.deinit();

    // Warmup
    for (0..warmup) |i| {
        const idx = i % block_ids.items.len;
        _ = block_ids.items[idx].hash();
    }

    // Measurement
    var timer = try Timer.start();
    for (block_ids.items) |id| {
        timer.reset();
        _ = id.hash();
        try samples.append(timer.read());
    }

    const result = harness.calculate_benchmark_result("core/block_id_hashing", samples.items);
    try bench_harness.add_result(result);
}

/// Benchmark BlockId comparison
fn bench_block_id_comparison(bench_harness: *BenchmarkHarness) !void {
    const iterations = bench_harness.config.iterations;
    const warmup = bench_harness.config.warmup_iterations;

    // Create pairs of IDs to compare
    var id_pairs = std.array_list.Managed(struct { a: internal.BlockId, b: internal.BlockId }).init(bench_harness.allocator);
    defer id_pairs.deinit();
    try id_pairs.ensureTotalCapacity(iterations);

    for (0..iterations) |i| {
        try id_pairs.append(.{
            .a = internal.BlockId.from_u64(i),
            .b = internal.BlockId.from_u64(if (i % 2 == 0) i else i + 1),
        });
    }

    var samples = std.array_list.Managed(u64).init(bench_harness.allocator);
    defer samples.deinit();

    // Warmup
    for (0..warmup) |i| {
        const idx = i % id_pairs.items.len;
        _ = id_pairs.items[idx].a.eql(id_pairs.items[idx].b);
    }

    // Measurement
    var timer = try Timer.start();
    for (id_pairs.items) |pair| {
        timer.reset();
        _ = pair.a.eql(pair.b);
        try samples.append(timer.read());
    }

    const result = harness.calculate_benchmark_result("core/block_id_comparison", samples.items);
    try bench_harness.add_result(result);
}

/// Benchmark ArenaCoordinator small allocations
fn bench_arena_allocation_small(bench_harness: *BenchmarkHarness) !void {
    const iterations = bench_harness.config.iterations;
    const warmup = bench_harness.config.warmup_iterations;
    const alloc_size = 64; // Small allocation

    var samples = std.array_list.Managed(u64).init(bench_harness.allocator);
    defer samples.deinit();

    // Each iteration gets a fresh arena to measure allocation cost
    for (0..warmup + iterations) |i| {
        var arena_allocator = std.heap.ArenaAllocator.init(bench_harness.allocator);
        defer arena_allocator.deinit();
        var arena_coordinator = internal.memory.ArenaCoordinator.init(&arena_allocator);

        const arena_alloc = arena_coordinator.allocator();

        if (i < warmup) {
            // Warmup - not measured
            _ = try arena_alloc.alloc(u8, alloc_size);
        } else {
            // Measurement
            var timer = try Timer.start();
            _ = try arena_alloc.alloc(u8, alloc_size);
            try samples.append(timer.read());
        }
    }

    const result = harness.calculate_benchmark_result("core/arena_allocation_small", samples.items);
    try bench_harness.add_result(result);
}

/// Benchmark ArenaCoordinator large allocations
fn bench_arena_allocation_large(bench_harness: *BenchmarkHarness) !void {
    const iterations = bench_harness.config.iterations;
    const warmup = bench_harness.config.warmup_iterations;
    const alloc_size = 64 * 1024; // 64KB large allocation

    var samples = std.array_list.Managed(u64).init(bench_harness.allocator);
    defer samples.deinit();

    // Each iteration gets a fresh arena
    for (0..warmup + iterations) |i| {
        var arena_allocator = std.heap.ArenaAllocator.init(bench_harness.allocator);
        defer arena_allocator.deinit();
        var arena_coordinator = internal.memory.ArenaCoordinator.init(&arena_allocator);

        const arena_alloc = arena_coordinator.allocator();

        if (i < warmup) {
            // Warmup - not measured
            _ = try arena_alloc.alloc(u8, alloc_size);
        } else {
            // Measurement
            var timer = try Timer.start();
            _ = try arena_alloc.alloc(u8, alloc_size);
            try samples.append(timer.read());
        }
    }

    const result = harness.calculate_benchmark_result("core/arena_allocation_large", samples.items);
    try bench_harness.add_result(result);
}

/// Benchmark ContextBlock cloning
fn bench_context_block_clone(bench_harness: *BenchmarkHarness) !void {
    const iterations = bench_harness.config.iterations;
    const warmup = bench_harness.config.warmup_iterations;

    // Create source blocks to clone
    var source_blocks = std.array_list.Managed(internal.ContextBlock).init(bench_harness.allocator);
    defer source_blocks.deinit();
    try source_blocks.ensureTotalCapacity(iterations);

    for (0..iterations) |i| {
        try source_blocks.append(.{
            .id = internal.BlockId.from_u64(i),
            .sequence = @intCast(i),
            .source_uri = "bench://core/test.zig",
            .metadata_json = "{\"test\": true}",
            .content = "fn test_function() { return 42; }",
        });
    }

    var samples = std.array_list.Managed(u64).init(bench_harness.allocator);
    defer samples.deinit();

    // Warmup
    for (0..warmup) |i| {
        const idx = i % source_blocks.items.len;
        const size = source_blocks.items[idx].serialized_size();
        std.mem.doNotOptimizeAway(&size);
    }

    // Measurement
    var timer = try Timer.start();
    for (source_blocks.items) |block| {
        timer.reset();
        const size = block.serialized_size();
        std.mem.doNotOptimizeAway(&size);
        try samples.append(timer.read());
    }

    const result = harness.calculate_benchmark_result("core/context_block_size", samples.items);
    try bench_harness.add_result(result);
}

/// Benchmark GraphEdge comparison
fn bench_edge_comparison(bench_harness: *BenchmarkHarness) !void {
    const iterations = bench_harness.config.iterations;
    const warmup = bench_harness.config.warmup_iterations;

    // Create edge pairs to compare
    var edge_pairs = std.array_list.Managed(struct { a: internal.GraphEdge, b: internal.GraphEdge }).init(bench_harness.allocator);
    defer edge_pairs.deinit();
    try edge_pairs.ensureTotalCapacity(iterations);

    for (0..iterations) |i| {
        const same = i % 2 == 0;
        try edge_pairs.append(.{
            .a = .{
                .source_id = internal.BlockId.from_u64(i),
                .target_id = internal.BlockId.from_u64(i + 1),
                .edge_type = .calls,
            },
            .b = .{
                .source_id = internal.BlockId.from_u64(if (same) i else i + 2),
                .target_id = internal.BlockId.from_u64(if (same) i + 1 else i + 3),
                .edge_type = .calls,
            },
        });
    }

    var samples = std.array_list.Managed(u64).init(bench_harness.allocator);
    defer samples.deinit();

    // Warmup
    for (0..warmup) |i| {
        const idx = i % edge_pairs.items.len;
        const is_less = internal.GraphEdge.less_than({}, edge_pairs.items[idx].a, edge_pairs.items[idx].b);
        std.mem.doNotOptimizeAway(&is_less);
    }

    // Measurement
    var timer = try Timer.start();
    for (edge_pairs.items) |pair| {
        timer.reset();
        const is_less = internal.GraphEdge.less_than({}, pair.a, pair.b);
        std.mem.doNotOptimizeAway(&is_less);
        try samples.append(timer.read());
    }

    const result = harness.calculate_benchmark_result("core/edge_comparison", samples.items);
    try bench_harness.add_result(result);
}
