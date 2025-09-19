//! KausalDB Performance Benchmarks
//!
//! Clean component dispatcher for systematic performance testing.
//! Delegates all benchmark implementation to component modules while
//! providing shared harness, statistical analysis, and reporting.

const std = @import("std");
const builtin = @import("builtin");
const internal = @import("internal");
const e2e_bench = @import("e2e_workload_bench.zig");

const Timer = std.time.Timer;
const Allocator = std.mem.Allocator;

/// Component selection for targeted benchmarking
const Component = enum {
    storage,
    query,
    ingestion,
    core,
    e2e,
    all,

    fn from_string(str: []const u8) ?Component {
        return std.meta.stringToEnum(Component, str);
    }
};

/// Benchmark configuration
const BenchConfig = struct {
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
    std_dev_ns: u64,
    ops_per_second: f64,
    baseline_mean_ns: ?u64 = null,
    regression_percent: ?f32 = null,

    fn format_time_us(ns: u64) f64 {
        return @as(f64, @floatFromInt(ns)) / 1000.0;
    }

    fn print(self: BenchmarkResult, verbose: bool) void {
        const mean_us = format_time_us(self.mean_ns);
        const min_us = format_time_us(self.min_ns);
        const max_us = format_time_us(self.max_ns);

        std.debug.print("  {s}:\n", .{self.name});
        std.debug.print("    Mean: {d:.2}μs  Min: {d:.2}μs  Max: {d:.2}μs\n", .{ mean_us, min_us, max_us });
        std.debug.print("    Ops/sec: {d:.0}\n", .{self.ops_per_second});

        if (self.regression_percent) |regression| {
            if (regression > 0) {
                std.debug.print("    REGRESSION: {d:.1}% slower\n", .{regression});
            } else {
                std.debug.print("    IMPROVEMENT: {d:.1}% faster\n", .{-regression});
            }
        }

        if (verbose) {
            const median_us = format_time_us(self.median_ns);
            const std_dev_us = format_time_us(self.std_dev_ns);
            std.debug.print("    Median: {d:.2}μs  StdDev: {d:.2}μs\n", .{ median_us, std_dev_us });
        }

        std.debug.print("\n", .{});
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
                    std.debug.print("Baseline file not found: {s}", .{path});
                    break :blk null;
                },
                else => return err,
            };
        }

        return harness;
    }

    pub fn deinit(self: *BenchmarkHarness) void {
        self.results.deinit();
        if (self.baseline) |*baseline| {
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
    fn print_results(self: *BenchmarkHarness) void {
        std.debug.print("\n=== Benchmark Results ===\n\n", .{});

        for (self.results.items) |result| {
            result.print(self.config.verbose);
        }

        // Summary statistics
        var total_regressions: u32 = 0;
        var total_improvements: u32 = 0;

        for (self.results.items) |result| {
            if (result.regression_percent) |regression| {
                if (regression > 5.0) { // >5% regression threshold
                    total_regressions += 1;
                } else if (regression < -5.0) { // >5% improvement
                    total_improvements += 1;
                }
            }
        }

        std.debug.print("Summary: {} benchmarks, {} regressions, {} improvements\n", .{
            self.results.items.len,
            total_regressions,
            total_improvements,
        });

        if (total_regressions > 0) {
            std.debug.print("Performance regressions detected!\n", .{});
        }
    }

    /// Save baseline results if requested
    fn save_results_as_baseline(self: *BenchmarkHarness) !void {
        if (self.config.output_baseline_file) |path| {
            try save_baseline(self.allocator, path, self.results.items);
            std.debug.print("Baseline saved to: {s}\n", .{path});
        }
    }
};

/// Parse component from command line arguments
fn parse_component_arg(args: [][:0]u8) Component {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) continue;
        if (Component.from_string(arg)) |component| {
            return component;
        }
    }
    return .all;
}

/// Parse configuration from command line arguments
fn parse_config(args: [][:0]u8) BenchConfig {
    var config = BenchConfig{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--iterations") and i + 1 < args.len) {
            config.iterations = std.fmt.parseInt(u32, args[i + 1], 10) catch config.iterations;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--warmup") and i + 1 < args.len) {
            config.warmup_iterations = std.fmt.parseInt(u32, args[i + 1], 10) catch config.warmup_iterations;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--baseline") and i + 1 < args.len) {
            config.baseline_file = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--save-baseline") and i + 1 < args.len) {
            config.output_baseline_file = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--json")) {
            config.output_format = .json;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            config.verbose = true;
        }
    }

    return config;
}

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

    const json_string = try std.json.Stringify.valueAlloc(allocator, results, .{ .whitespace = .indent_2 });
    defer allocator.free(json_string);
    try file.writeAll(json_string);
}

/// Main entry point
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const config = parse_config(args);
    const component = parse_component_arg(args);

    var harness = try BenchmarkHarness.init(allocator, config);
    defer harness.deinit();

    std.debug.print("KausalDB Performance Benchmarks\n", .{});
    std.debug.print("Component: {s}\n", .{@tagName(component)});
    std.debug.print("Iterations: {}, Warmup: {}\n\n", .{ config.iterations, config.warmup_iterations });

    // Component dispatch
    switch (component) {
        .storage => {
            const storage = @import("storage.zig");
            try storage.run_benchmarks(&harness);
        },
        .e2e => {
            std.debug.print("Running realistic end-to-end workload benchmark...\n", .{});
            try e2e_bench.run_e2e_benchmark(allocator);
            return; // E2E benchmark handles its own output
        },
        .query, .ingestion, .core => {
            std.debug.print("Component not implemented yet\n", .{});
        },
        .all => {
            std.debug.print("Running realistic end-to-end workload benchmark...\n", .{});
            try e2e_bench.run_e2e_benchmark(allocator);
            return; // E2E benchmark handles its own output
        },
    }

    // Results and reporting
    harness.print_results();
    try harness.save_results_as_baseline();

    // Exit with error code if significant regressions found
    var has_major_regression = false;
    for (harness.results.items) |result| {
        if (result.regression_percent) |regression| {
            if (regression > 10.0) { // >10% regression is major
                has_major_regression = true;
                break;
            }
        }
    }

    if (has_major_regression) {
        std.process.exit(1);
    }
}
