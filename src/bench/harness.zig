//! KausalDB Performance Benchmark Harness.
//!
//! This module provides the core framework for creating, running, and reporting
//! on benchmarks. It includes the main BenchmarkHarness, result and statistics
//! data structures, and helper utilities. All benchmark modules should use this
//! harness to ensure consistent and reliable performance measurement.

const std = @import("std");
const builtin = @import("builtin");
const output = @import("output.zig");

const Allocator = std.mem.Allocator;
const Timer = std.time.Timer;

/// Benchmark configuration, parsed from CLI args
pub const BenchConfig = struct {
    iterations: u32 = 1000,
    warmup_iterations: u32 = 100,
    baseline_file: ?[]const u8 = null,
    output_baseline_file: ?[]const u8 = null,
    output_format: OutputFormat = .human,
    verbose: bool = false,

    const OutputFormat = enum { human, json };
};

/// Individual benchmark result
pub const BenchmarkResult = struct {
    name: []const u8,
    iterations: u32,
    mean_ns: u64,
    median_ns: u64,
    min_ns: u64,
    max_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    std_dev_ns: u64,
    ops_per_second: f64,
    baseline_mean_ns: ?u64 = null,
    regression_percent: ?f32 = null,

    fn format_time_us(ns: u64) f64 {
        return @as(f64, @floatFromInt(ns)) / 1000.0;
    }

    fn print(self: BenchmarkResult, verbose: bool, allocator: std.mem.Allocator) void {
        const mean_us = format_time_us(self.mean_ns);
        const min_us = format_time_us(self.min_ns);
        const max_us = format_time_us(self.max_ns);
        const p95_us = format_time_us(self.p95_ns);
        const p99_us = format_time_us(self.p99_ns);

        output.print_benchmark_results(allocator, "  {s}:\n", .{self.name});
        output.print_benchmark_results(allocator, "    Mean: {d:.2}μs  Min: {d:.2}μs  Max: {d:.2}μs\n", .{ mean_us, min_us, max_us });
        output.print_benchmark_results(allocator, "    P95: {d:.2}μs  P99: {d:.2}μs\n", .{ p95_us, p99_us });
        output.print_benchmark_results(allocator, "    Ops/sec: {d:.0}\n", .{self.ops_per_second});

        if (self.regression_percent) |regression| {
            if (regression > 0) {
                output.print_benchmark_results(allocator, "    REGRESSION: {d:.1}% slower\n", .{regression});
            } else {
                output.print_benchmark_results(allocator, "    IMPROVEMENT: {d:.1}% faster\n", .{-regression});
            }
        }

        if (verbose) {
            const median_us = format_time_us(self.median_ns);
            const std_dev_us = format_time_us(self.std_dev_ns);
            output.print_benchmark_results(allocator, "    Median: {d:.2}μs  StdDev: {d:.2}μs\n", .{ median_us, std_dev_us });
        }

        output.write_benchmark_results("\n");
    }
};

/// Statistical sampling and analysis tool
pub const StatisticalSampler = struct {
    allocator: Allocator,
    samples: std.array_list.Managed(u64),

    const Statistics = struct {
        sample_count: u32,
        median_ns: u64,
        mean_ns: u64,
        p95_ns: u64,
        p99_ns: u64,
        min_ns: u64,
        max_ns: u64,
        stddev_ns: u64,
    };

    pub fn init(allocator: Allocator) StatisticalSampler {
        return StatisticalSampler{
            .allocator = allocator,
            .samples = std.array_list.Managed(u64).init(allocator),
        };
    }

    pub fn deinit(self: *StatisticalSampler) void {
        self.samples.deinit();
    }

    pub fn add_sample(self: *StatisticalSampler, sample_ns: u64) !void {
        try self.samples.append(sample_ns);
    }

    pub fn calculate_stats(self: *StatisticalSampler) Statistics {
        if (self.samples.items.len == 0) {
            return Statistics{
                .sample_count = 0,
                .median_ns = 0,
                .mean_ns = 0,
                .p95_ns = 0,
                .p99_ns = 0,
                .min_ns = 0,
                .max_ns = 0,
                .stddev_ns = 0,
            };
        }

        const samples = self.samples.items;

        // Sort samples for percentile calculation
        const sorted_samples = self.allocator.alloc(u64, samples.len) catch unreachable;
        defer self.allocator.free(sorted_samples);

        @memcpy(sorted_samples, samples);
        std.mem.sort(u64, sorted_samples, {}, comptime std.sort.asc(u64));

        const mean = calculate_mean(samples);

        return Statistics{
            .sample_count = @intCast(samples.len),
            .median_ns = calculate_median(sorted_samples),
            .mean_ns = mean,
            .p95_ns = calculate_percentile(sorted_samples, 95),
            .p99_ns = calculate_percentile(sorted_samples, 99),
            .min_ns = sorted_samples[0],
            .max_ns = sorted_samples[sorted_samples.len - 1],
            .stddev_ns = calculate_std_dev(samples, mean),
        };
    }
};

/// Shared benchmark harness for component modules
pub const BenchmarkHarness = struct {
    allocator: Allocator,
    config: BenchConfig,
    baseline: ?std.StringHashMap(BenchmarkResult),
    results: std.array_list.Managed(BenchmarkResult),

    pub fn init(allocator: Allocator, config: BenchConfig) !BenchmarkHarness {
        var harness = BenchmarkHarness{
            .allocator = allocator,
            .config = config,
            .baseline = null,
            .results = std.array_list.Managed(BenchmarkResult).init(allocator),
        };

        // Load baseline if specified
        if (config.baseline_file) |path| {
            harness.baseline = load_baseline(allocator, path) catch |err| switch (err) {
                error.FileNotFound => blk: {
                    output.print_status(allocator, "Baseline file not found: {s}\n", .{path});
                    break :blk null;
                },
                else => blk: {
                    output.print_status(allocator, "Warning: Failed to load baseline file {s}: {}\n", .{ path, err });
                    output.write_status("Continuing without baseline comparison...\n");
                    break :blk null;
                },
            };
        }

        return harness;
    }

    pub fn deinit(self: *BenchmarkHarness) void {
        self.results.deinit();
        if (self.baseline) |*baseline| {
            var iterator = baseline.iterator();
            while (iterator.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            baseline.deinit();
        }
    }

    /// Simple interface for component modules to add results
    pub fn add_result(self: *BenchmarkHarness, result: BenchmarkResult) !void {
        var final_result = result;

        // Apply baseline comparison if available
        if (self.baseline) |baseline| {
            if (baseline.get(result.name)) |baseline_result| {
                final_result.baseline_mean_ns = baseline_result.mean_ns;
                final_result.regression_percent = calculate_regression(baseline_result.mean_ns, result.mean_ns);
            }
        }

        try self.results.append(final_result);
    }

    /// Print all results
    pub fn print_results(self: *BenchmarkHarness) void {
        output.print_results_header();

        for (self.results.items) |result| {
            result.print(self.config.verbose, self.allocator);
        }

        // Summary statistics
        var total_regressions: u32 = 0;
        var total_improvements: u32 = 0;

        for (self.results.items) |result| {
            if (result.regression_percent) |regression| {
                if (regression > 0) {
                    total_regressions += 1;
                } else {
                    total_improvements += 1;
                }
            }
        }

        output.print_summary(self.allocator, @intCast(self.results.items.len), total_regressions, total_improvements);
    }

    /// Save baseline results if requested
    pub fn save_results_as_baseline(self: *BenchmarkHarness) !void {
        if (self.config.output_baseline_file) |path| {
            try save_baseline(self.allocator, path, self.results.items);
            output.print_status(self.allocator, "Baseline saved to: {s}\n", .{path});
        }
    }
};

// --- Helper Functions ---

/// Calculate performance regression percentage
fn calculate_regression(baseline_ns: u64, current_ns: u64) f32 {
    if (baseline_ns == 0) return 0;
    const baseline_f = @as(f64, @floatFromInt(baseline_ns));
    const current_f = @as(f64, @floatFromInt(current_ns));
    return @as(f32, @floatCast(((current_f - baseline_f) / baseline_f) * 100.0));
}

/// Load baseline results from JSON file
fn load_baseline(allocator: Allocator, path: []const u8) !std.StringHashMap(BenchmarkResult) {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 16 * 1024 * 1024);
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice([]BenchmarkResult, allocator, content, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var baseline = std.StringHashMap(BenchmarkResult).init(allocator);
    for (parsed.value) |result| {
        const owned_name = try allocator.dupe(u8, result.name);
        try baseline.put(owned_name, result);
    }

    return baseline;
}

/// Save baseline results to JSON file
fn save_baseline(allocator: Allocator, path: []const u8, results: []const BenchmarkResult) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    const json_content = try std.json.Stringify.valueAlloc(allocator, results, .{});
    defer allocator.free(json_content);
    try file.writeAll(json_content);
}

/// Calculate benchmark statistics from samples
pub fn calculate_benchmark_result(name: []const u8, samples: []const u64) BenchmarkResult {
    if (samples.len == 0) {
        return BenchmarkResult{
            .name = name,
            .iterations = 0,
            .mean_ns = 0,
            .median_ns = 0,
            .min_ns = 0,
            .max_ns = 0,
            .p95_ns = 0,
            .p99_ns = 0,
            .std_dev_ns = 0,
            .ops_per_second = 0,
        };
    }

    const mean = calculate_mean(samples);
    const median = calculate_median_from_unsorted(samples);
    const min = std.mem.min(u64, samples);
    const max = std.mem.max(u64, samples);
    const p95 = calculate_percentile_from_unsorted(samples, 95);
    const p99 = calculate_percentile_from_unsorted(samples, 99);
    const std_dev = calculate_std_dev(samples, mean);

    return BenchmarkResult{
        .name = name,
        .iterations = @intCast(samples.len),
        .mean_ns = mean,
        .median_ns = median,
        .min_ns = min,
        .max_ns = max,
        .p95_ns = p95,
        .p99_ns = p99,
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

fn calculate_median(sorted_samples: []const u64) u64 {
    if (sorted_samples.len == 0) return 0;
    return sorted_samples[sorted_samples.len / 2];
}

fn calculate_median_from_unsorted(samples: []const u64) u64 {
    if (samples.len == 0) return 0;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const sorted = allocator.alloc(u64, samples.len) catch return 0;

    @memcpy(sorted, samples);
    std.mem.sort(u64, sorted, {}, comptime std.sort.asc(u64));
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

fn calculate_percentile(sorted_samples: []const u64, percentile: u8) u64 {
    if (sorted_samples.len == 0) return 0;
    const index = (percentile * (sorted_samples.len - 1)) / 100;
    return sorted_samples[index];
}

fn calculate_percentile_from_unsorted(samples: []const u64, percentile: u8) u64 {
    if (samples.len == 0) return 0;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const sorted = allocator.alloc(u64, samples.len) catch return 0;

    @memcpy(sorted, samples);
    std.mem.sort(u64, sorted, {}, comptime std.sort.asc(u64));
    const index = (percentile * (sorted.len - 1)) / 100;
    return sorted[index];
}
