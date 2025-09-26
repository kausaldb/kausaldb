//! Network benchmarks for KausalDB.
//! Measures performance of network-related operations.

const std = @import("std");

const internal = @import("internal");

const harness = @import("harness.zig");

const BenchmarkHarness = harness.BenchmarkHarness;
const Timer = std.time.Timer;

/// Main entry point called by the benchmark runner.
pub fn run_benchmarks(bench_harness: *BenchmarkHarness) !void {
    // Simplified network benchmarks for now
    try bench_connection_overhead_simulation(bench_harness);
    try bench_message_serialization_cpu_cost(bench_harness);
    try bench_concurrent_overhead_simulation(bench_harness);
}

/// Benchmark connection overhead CPU simulation
fn bench_connection_overhead_simulation(bench_harness: *BenchmarkHarness) !void {
    const iterations = bench_harness.config.iterations;
    const warmup = bench_harness.config.warmup_iterations;

    var samples = std.array_list.Managed(u64).init(bench_harness.allocator);
    defer samples.deinit();

    // Warmup
    for (0..warmup) |_| {
        _ = simulate_connection();
    }

    // Measurement
    var timer = try Timer.start();
    for (0..iterations) |_| {
        timer.reset();
        _ = simulate_connection();
        try samples.append(timer.read());
    }

    const result = harness.calculate_benchmark_result("network/connection_overhead_simulation", samples.items);
    try bench_harness.add_result(result);
}

/// Benchmark message serialization CPU cost
fn bench_message_serialization_cpu_cost(bench_harness: *BenchmarkHarness) !void {
    const iterations = bench_harness.config.iterations;
    const warmup = bench_harness.config.warmup_iterations;

    var samples = std.array_list.Managed(u64).init(bench_harness.allocator);
    defer samples.deinit();

    // Warmup
    for (0..warmup) |_| {
        const serialized = simulate_message_serialization(bench_harness.allocator) catch continue;
        bench_harness.allocator.free(serialized);
    }

    // Measurement
    var timer = try Timer.start();
    for (0..iterations) |_| {
        timer.reset();
        const serialized = simulate_message_serialization(bench_harness.allocator) catch continue;
        bench_harness.allocator.free(serialized);
        try samples.append(timer.read());
    }

    const result = harness.calculate_benchmark_result("network/message_serialization_cpu_cost", samples.items);
    try bench_harness.add_result(result);
}

/// Benchmark concurrent connection overhead simulation
fn bench_concurrent_overhead_simulation(bench_harness: *BenchmarkHarness) !void {
    const iterations = @min(100, bench_harness.config.iterations); // Concurrent ops are expensive
    const warmup = @min(20, bench_harness.config.warmup_iterations);

    var samples = std.array_list.Managed(u64).init(bench_harness.allocator);
    defer samples.deinit();

    // Warmup
    for (0..warmup) |_| {
        _ = simulate_concurrent_connections();
    }

    // Measurement
    var timer = try Timer.start();
    for (0..iterations) |_| {
        timer.reset();
        _ = simulate_concurrent_connections();
        try samples.append(timer.read());
    }

    const result = harness.calculate_benchmark_result("network/concurrent_overhead_simulation", samples.items);
    try bench_harness.add_result(result);
}

/// Simulate a network connection (lightweight for testing)
fn simulate_connection() u32 {
    // Simple simulation - just some CPU work to represent connection overhead
    var sum: u32 = 0;
    for (0..1000) |i| {
        sum += @intCast(i);
    }
    return sum;
}

/// Simulate message serialization
fn simulate_message_serialization(allocator: std.mem.Allocator) ![]u8 {
    // Simulate JSON serialization of a typical message
    const message = .{
        .command = "find",
        .parameters = .{
            .query = "test_function",
            .max_results = 100,
        },
        .timestamp = std.time.nanoTimestamp(),
    };

    // Simplified serialization without JSON dependency - return full buffer for easier memory management
    const result = try allocator.alloc(u8, 200);
    const len = try std.fmt.bufPrint(result, "{{\"command\":\"{s}\",\"query\":\"{s}\",\"timestamp\":{}}}", .{ message.command, message.parameters.query, message.timestamp });
    _ = len; // Use full buffer to avoid memory management issues
    return result;
}

/// Simulate concurrent connections
fn simulate_concurrent_connections() u32 {
    // Simulate handling multiple connections
    var total: u32 = 0;
    for (0..10) |_| { // Simulate 10 concurrent connections
        total += simulate_connection();
    }
    return total;
}
