//! Benchmark coordinator for KausalDB performance testing.
//!
//! Dispatches to specialized benchmark modules based on command arguments.
//! Dev tools use the external kausaldb API for convenience.

const std = @import("std");
const internal = @import("internal");

const compaction_benchmarks = @import("benchmark/compaction.zig");
const parsing_benchmarks = @import("benchmark/parsing.zig");
const query_benchmarks = @import("benchmark/query.zig");
const storage_benchmarks = @import("benchmark/storage.zig");

// Re-export internal modules for benchmark files to use
// Dev tools use internal API for better access to implementation details
pub const types = internal.types;
pub const storage = internal.storage;
pub const query_engine = internal.query_engine;
pub const query_operations = internal.query_operations;
pub const production_vfs = internal.production_vfs;
pub const ownership = internal.ownership;
pub const pipeline = internal.pipeline;
pub const zig_parser = internal.zig_parser;
pub const assert = internal.assert;

// Development utilities from internal API
pub const QueryHarness = internal.QueryHarness;
pub const StatisticalSampler = internal.performance_assertions.StatisticalSampler;
pub const WarmupUtils = internal.performance_assertions.WarmupUtils;

pub const BenchmarkResult = struct {
    operation_name: []const u8,
    iterations: u64,
    total_time_ns: u64,
    min_ns: u64,
    max_ns: u64,
    mean_ns: u64,
    median_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    stddev_ns: u64,
    throughput_ops_per_sec: f64,
    passed_threshold: bool,
    threshold_ns: u64,
    peak_memory_bytes: u64,
    memory_growth_bytes: u64,
    memory_efficient: bool,
    memory_kb: u64,

    pub fn format(
        self: BenchmarkResult,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s}: {} iterations, mean {d:.2}µs, p95 {d:.2}µs, memory {}KB", .{ self.operation_name, self.iterations, @as(f64, @floatFromInt(self.mean_ns)) / 1000.0, @as(f64, @floatFromInt(self.p95_ns)) / 1000.0, self.memory_kb });
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try print_usage();
        return;
    }

    const benchmark_type = args[1];

    if (std.mem.eql(u8, benchmark_type, "storage")) {
        _ = try storage_benchmarks.run_all(allocator);
    } else if (std.mem.eql(u8, benchmark_type, "query")) {
        _ = try query_benchmarks.run_all(allocator);
    } else if (std.mem.eql(u8, benchmark_type, "parsing")) {
        _ = try parsing_benchmarks.run_all(allocator);
    } else if (std.mem.eql(u8, benchmark_type, "compaction")) {
        _ = try compaction_benchmarks.run_all(allocator);
    } else if (std.mem.eql(u8, benchmark_type, "all")) {
        _ = try storage_benchmarks.run_all(allocator);
        _ = try query_benchmarks.run_all(allocator);
        _ = try parsing_benchmarks.run_all(allocator);
        _ = try compaction_benchmarks.run_all(allocator);
    } else {
        std.debug.print("Unknown benchmark type: {s}\n\n", .{benchmark_type});
        try print_usage();
    }
}

fn print_usage() !void {
    std.debug.print(
        \\Usage: benchmark <type>
        \\
        \\Types:
        \\  storage     - Storage engine benchmarks
        \\  query       - Query engine benchmarks  
        \\  parsing     - Parsing performance benchmarks
        \\  compaction  - Compaction benchmarks
        \\  all         - Run all benchmarks
        \\
    , .{});
}
