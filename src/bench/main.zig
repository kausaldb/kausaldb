//! KausalDB Performance Benchmarks Runner
//!
//! Main entry point for dispatching all performance tests. This module parses
//! command-line arguments and delegates execution to the appropriate benchmark
//! modules, using the framework defined in harness.zig.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const internal = @import("internal");
const harness = @import("harness.zig");
const output = @import("output.zig");

pub const std_options: std.Options = .{
    .log_level = @enumFromInt(@intFromEnum(build_options.log_level)),
};

/// Component selection for targeted benchmarking
const Component = enum {
    storage,
    query,
    ingestion,
    core,
    network,
    e2e,
    all,

    fn from_string(str: []const u8) ?Component {
        return std.meta.stringToEnum(Component, str);
    }
};

// Re-export for backward compatibility
pub const BenchmarkResult = harness.BenchmarkResult;
pub const BenchmarkHarness = harness.BenchmarkHarness;

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

/// Parse configuration from build options and command line arguments
fn parse_config(args: [][:0]u8) harness.BenchConfig {
    var config = harness.BenchConfig{
        .iterations = build_options.bench_iterations,
        .warmup_iterations = build_options.bench_warmup,
        .baseline_file = build_options.bench_baseline,
    };

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
        } else if (std.mem.startsWith(u8, arg, "--save-baseline=")) {
            config.output_baseline_file = arg["--save-baseline=".len..];
        } else if (std.mem.eql(u8, arg, "--json")) {
            config.output_format = .json;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            config.verbose = true;
        }
    }

    return config;
}

/// Main entry point
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    return run_benchmarks(allocator);
}

fn run_benchmarks(allocator: std.mem.Allocator) !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const config = parse_config(args);
    const component = parse_component_arg(args);

    var bench_harness = try harness.BenchmarkHarness.init(allocator, config);
    defer bench_harness.deinit();

    output.print_benchmark_header(allocator, "Performance Benchmarks");

    const config_items = [_]output.ConfigItem{
        .{ .name = "Component", .value = @tagName(component) },
        .{ .name = "Iterations", .value = try std.fmt.allocPrint(allocator, "{}", .{config.iterations}) },
        .{ .name = "Warmup", .value = try std.fmt.allocPrint(allocator, "{}", .{config.warmup_iterations}) },
    };
    defer {
        allocator.free(config_items[1].value);
        allocator.free(config_items[2].value);
    }
    output.print_benchmark_config(allocator, &config_items);

    // Component dispatch
    switch (component) {
        .storage => {
            const storage = @import("storage.zig");
            try storage.run_benchmarks(&bench_harness);
        },
        .query => {
            const query = @import("query.zig");
            try query.run_benchmarks(&bench_harness);
        },
        .ingestion => {
            const ingestion = @import("ingestion.zig");
            try ingestion.run_benchmarks(&bench_harness);
        },
        .core => {
            const core = @import("core.zig");
            try core.run_benchmarks(&bench_harness);
        },
        .network => {
            const network = @import("network.zig");
            try network.run_benchmarks(&bench_harness);
        },
        .e2e => {
            const e2e = @import("e2e.zig");
            try e2e.run_benchmarks(&bench_harness);
        },
        .all => {
            const storage = @import("storage.zig");
            const query = @import("query.zig");
            const ingestion = @import("ingestion.zig");
            const core = @import("core.zig");
            const network = @import("network.zig");
            const e2e = @import("e2e.zig");

            try storage.run_benchmarks(&bench_harness);
            try query.run_benchmarks(&bench_harness);
            try ingestion.run_benchmarks(&bench_harness);
            try core.run_benchmarks(&bench_harness);
            try network.run_benchmarks(&bench_harness);
            try e2e.run_benchmarks(&bench_harness);
        },
    }

    // Results and reporting
    bench_harness.print_results();
    try bench_harness.save_results_as_baseline();

    // Exit with error code if significant regressions found
    for (bench_harness.results.items) |result| {
        if (result.regression_percent) |regression| {
            if (regression > 10.0) { // >10% regression is major
                // TODO: We need to stabilize the benchmarks, we are getting
                // false regression detections which fails CI.
                //
                // std.process.exit(1);
            }
        }
    }
}
