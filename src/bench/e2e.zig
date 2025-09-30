//! End-to-end benchmarks for KausalDB.
//!
//! Measures realistic workload performance by executing the actual KausalDB
//! binary against generated test codebases. Unlike unit benchmarks that
//! isolate individual components, these tests measure the full pipeline
//! from command parsing through storage engine to final response.

const std = @import("std");
const builtin = @import("builtin");

const harness = @import("harness.zig");
const output = @import("output.zig");

const BenchmarkHarness = harness.BenchmarkHarness;
const StatisticalSampler = harness.StatisticalSampler;
const Timer = std.time.Timer;

/// Configuration for end-to-end benchmark scenarios
const E2EBenchmarkConfig = struct {
    operations_per_type: u32 = 50,
    codebase_size: u32 = 25,
    functions_per_file: u32 = 4,
    ingestion_samples: u32 = 5,
    verbose: bool = false,
};

/// Simple E2E test harness for benchmark execution
const E2ETestHarness = struct {
    allocator: std.mem.Allocator,
    binary_path: []const u8,
    temp_dir: []const u8,
    cleanup_paths: std.array_list.Managed([]const u8),

    pub fn init(allocator: std.mem.Allocator, test_name: []const u8) !E2ETestHarness {
        const temp_dir = try std.fmt.allocPrint(allocator, "/tmp/kausaldb_e2e_bench_{s}_{d}", .{ test_name, std.time.milliTimestamp() });

        // Create temp directory
        std.fs.cwd().makePath(temp_dir) catch |err| {
            allocator.free(temp_dir);
            return err;
        };

        return E2ETestHarness{
            .allocator = allocator,
            .binary_path = "./zig-out/bin/kausaldb",
            .temp_dir = temp_dir,
            .cleanup_paths = std.array_list.Managed([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *E2ETestHarness) void {
        // Clean up all tracked paths
        for (self.cleanup_paths.items) |path| {
            std.fs.cwd().deleteTree(path) catch {};
            self.allocator.free(path);
        }
        self.cleanup_paths.deinit();

        // Clean up temp directory
        std.fs.cwd().deleteTree(self.temp_dir) catch {};
        self.allocator.free(self.temp_dir);
    }

    pub fn execute_command(self: *E2ETestHarness, args: []const []const u8) !CommandResult {
        var argv = std.array_list.Managed([]const u8).init(self.allocator);
        defer argv.deinit();

        try argv.append(self.binary_path);
        for (args) |arg| {
            try argv.append(arg);
        }

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = argv.items,
            .cwd = self.temp_dir,
        }) catch |err| {
            return CommandResult{
                .exit_code = 1,
                .stdout = try self.allocator.dupe(u8, ""),
                .stderr = try std.fmt.allocPrint(self.allocator, "Command execution failed: {}", .{err}),
                .allocator = self.allocator,
            };
        };

        return CommandResult{
            .exit_code = @intCast(result.term.Exited),
            .stdout = result.stdout,
            .stderr = result.stderr,
            .allocator = self.allocator,
        };
    }

    pub fn create_test_project(self: *E2ETestHarness, project_name: []const u8, config: E2EBenchmarkConfig) ![]const u8 {
        const project_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.temp_dir, project_name });
        try self.cleanup_paths.append(project_path);

        // Create project structure
        try std.fs.cwd().makePath(project_path);
        const src_path = try std.fmt.allocPrint(self.allocator, "{s}/src", .{project_path});
        defer self.allocator.free(src_path);
        try std.fs.cwd().makePath(src_path);

        // Generate realistic Zig modules
        for (0..config.codebase_size) |module_i| {
            const module_path = try std.fmt.allocPrint(self.allocator, "{s}/module_{d}.zig", .{ src_path, module_i });
            defer self.allocator.free(module_path);

            const file = try std.fs.cwd().createFile(module_path, .{});
            defer file.close();

            // Write module header
            try file.writeAll("//! Benchmark test module\n\nconst std = @import(\"std\");\n\n");

            // Generate functions
            for (0..config.functions_per_file) |func_i| {
                var func_buffer: [1024]u8 = undefined;
                const func_content = try std.fmt.bufPrint(func_buffer[0..],
                    \\pub fn benchmark_function_{d}_{d}(allocator: std.mem.Allocator, input: u32) !u32 {{
                    \\    const buffer = try allocator.alloc(u8, input + {d});
                    \\    defer allocator.free(buffer);
                    \\    var sum: u32 = 0;
                    \\    for (buffer, 0..) |*byte, i| {{
                    \\        byte.* = @intCast((i + {d}) % 256);
                    \\        sum += byte.*;
                    \\    }}
                    \\    return sum + {d};
                    \\}}
                    \\
                    \\
                , .{ module_i, func_i, func_i * 10, module_i + func_i, func_i * 100 });
                try file.writeAll(func_content);
            }

            // Add struct definitions
            var struct_buffer: [512]u8 = undefined;
            const struct_content = try std.fmt.bufPrint(struct_buffer[0..],
                \\pub const BenchmarkConfig_{d} = struct {{
                \\    iterations: u32,
                \\    warmup: u32,
                \\    enabled: bool,
                \\
                \\    pub fn init(iterations: u32) BenchmarkConfig_{d} {{
                \\        return .{{ .iterations = iterations, .warmup = iterations / 10, .enabled = true }};
                \\    }}
                \\}};
                \\
            , .{ module_i, module_i });
            try file.writeAll(struct_content);
        }

        // Create main.zig with imports
        const main_path = try std.fmt.allocPrint(self.allocator, "{s}/main.zig", .{src_path});
        defer self.allocator.free(main_path);

        const main_file = try std.fs.cwd().createFile(main_path, .{});
        defer main_file.close();

        try main_file.writeAll("//! Main module for benchmark test project\n\nconst std = @import(\"std\");\n\n");

        // Add imports to create graph edges
        for (0..@min(3, config.codebase_size)) |i| {
            var import_buffer: [256]u8 = undefined;
            const import_line = try std.fmt.bufPrint(import_buffer[0..], "const module_{d} = @import(\"module_{d}.zig\");\n", .{ i, i });
            try main_file.writeAll(import_line);
        }

        try main_file.writeAll("\npub fn main() !void {\n    std.debug.print(\"Benchmark test project\\n\", .{});\n}\n");

        return project_path;
    }
};

const CommandResult = struct {
    exit_code: u32,
    stdout: []const u8,
    stderr: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CommandResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }

    pub fn expect_success(self: CommandResult) !void {
        if (self.exit_code != 0) {
            std.debug.print("Command failed with exit code {d}\n", .{self.exit_code});
            std.debug.print("STDOUT: {s}\n", .{self.stdout});
            std.debug.print("STDERR: {s}\n", .{self.stderr});
            return error.CommandFailed;
        }
    }
};

/// Main entry point called by the benchmark runner.
pub fn run_benchmarks(bench_harness: *BenchmarkHarness) !void {
    const config = E2EBenchmarkConfig{
        .operations_per_type = @min(25, bench_harness.config.iterations),
        .codebase_size = 15,
        .functions_per_file = 3,
        .ingestion_samples = @max(3, @min(8, bench_harness.config.iterations / 10)),
        .verbose = bench_harness.config.verbose,
    };

    // 1. SETUP: Initialize test environment
    var e2e_harness = try E2ETestHarness.init(bench_harness.allocator, "benchmark_e2e");
    defer e2e_harness.deinit();

    // Create comprehensive test project
    const project_path = try e2e_harness.create_test_project("comprehensive_benchmark", config);
    _ = project_path;

    // 2. RUN BENCHMARKS
    try bench_server_connectivity(bench_harness, &e2e_harness, config);
    try bench_codebase_ingestion(bench_harness, &e2e_harness, config);
    try bench_block_lookup_queries(bench_harness, &e2e_harness, config);
    try bench_graph_traversal_queries(bench_harness, &e2e_harness, config);
    try bench_semantic_search_queries(bench_harness, &e2e_harness, config);
}

/// Test server connectivity and basic command parsing
fn bench_server_connectivity(bench_harness: *BenchmarkHarness, e2e_harness: *E2ETestHarness, config: E2EBenchmarkConfig) !void {
    const iterations = config.operations_per_type;
    const warmup = @min(5, bench_harness.config.warmup_iterations);

    var sampler = StatisticalSampler.init(bench_harness.allocator);
    defer sampler.deinit();

    // Warmup with status commands
    for (0..warmup) |_| {
        var result = e2e_harness.execute_command(&[_][]const u8{"status"}) catch continue;
        result.deinit();
    }

    // Measurement
    var timer = try Timer.start();
    for (0..iterations) |_| {
        timer.reset();
        var result = try e2e_harness.execute_command(&[_][]const u8{"status"});
        const elapsed = timer.read();
        result.deinit();
        try sampler.add_sample(elapsed);
    }

    const stats = sampler.calculate_stats();
    const result = harness.BenchmarkResult{
        .name = "e2e/server_connectivity",
        .iterations = stats.sample_count,
        .mean_ns = stats.mean_ns,
        .median_ns = stats.median_ns,
        .min_ns = stats.min_ns,
        .max_ns = stats.max_ns,
        .p95_ns = stats.p95_ns,
        .p99_ns = stats.p99_ns,
        .std_dev_ns = stats.stddev_ns,
        .ops_per_second = if (stats.mean_ns > 0) 1_000_000_000.0 / @as(f64, @floatFromInt(stats.mean_ns)) else 0,
    };
    try bench_harness.add_result(result);
}

/// Test full codebase ingestion pipeline performance
fn bench_codebase_ingestion(bench_harness: *BenchmarkHarness, e2e_harness: *E2ETestHarness, config: E2EBenchmarkConfig) !void {
    const iterations = config.ingestion_samples;
    const warmup = @min(2, iterations);

    var sampler = StatisticalSampler.init(bench_harness.allocator);
    defer sampler.deinit();

    // Create multiple test projects for repeated ingestion
    var test_projects = std.array_list.Managed([]const u8).init(bench_harness.allocator);
    defer test_projects.deinit();

    // Create projects for warmup + measurement
    for (0..warmup + iterations) |i| {
        const project_name = try std.fmt.allocPrint(bench_harness.allocator, "ingestion_test_{d}", .{i});
        defer bench_harness.allocator.free(project_name);

        const project_path = try e2e_harness.create_test_project(project_name, config);
        try test_projects.append(try bench_harness.allocator.dupe(u8, project_path));
    }

    // Warmup runs
    for (0..warmup) |i| {
        var result = e2e_harness.execute_command(&[_][]const u8{ "link", "--path", test_projects.items[i] }) catch continue;
        result.deinit();
    }

    // Measurement runs
    var timer = try Timer.start();
    for (warmup..test_projects.items.len) |i| {
        timer.reset();
        var result = try e2e_harness.execute_command(&[_][]const u8{ "link", "--path", test_projects.items[i] });
        const elapsed = timer.read();
        result.deinit();
        try sampler.add_sample(elapsed);
    }

    // Cleanup project paths
    for (test_projects.items) |path| {
        bench_harness.allocator.free(path);
    }

    const stats = sampler.calculate_stats();
    const bench_result = harness.BenchmarkResult{
        .name = "e2e/codebase_ingestion",
        .iterations = stats.sample_count,
        .mean_ns = stats.mean_ns,
        .median_ns = stats.median_ns,
        .min_ns = stats.min_ns,
        .max_ns = stats.max_ns,
        .p95_ns = stats.p95_ns,
        .p99_ns = stats.p99_ns,
        .std_dev_ns = stats.stddev_ns,
        .ops_per_second = if (stats.mean_ns > 0) 1_000_000_000.0 / @as(f64, @floatFromInt(stats.mean_ns)) else 0,
    };
    try bench_harness.add_result(bench_result);
}

/// Test block lookup by name or content queries
fn bench_block_lookup_queries(bench_harness: *BenchmarkHarness, e2e_harness: *E2ETestHarness, config: E2EBenchmarkConfig) !void {
    const iterations = config.operations_per_type;
    const warmup = @min(8, bench_harness.config.warmup_iterations);

    var sampler = StatisticalSampler.init(bench_harness.allocator);
    defer sampler.deinit();

    // Generate realistic function names to search for
    var function_names = std.array_list.Managed([]const u8).init(bench_harness.allocator);
    defer {
        for (function_names.items) |name| {
            bench_harness.allocator.free(name);
        }
        function_names.deinit();
    }

    for (0..config.codebase_size) |module_i| {
        for (0..config.functions_per_file) |func_i| {
            const name = try std.fmt.allocPrint(bench_harness.allocator, "benchmark_function_{d}_{d}", .{ module_i, func_i });
            try function_names.append(name);
        }
    }

    // Warmup
    for (0..warmup) |i| {
        const name = function_names.items[i % function_names.items.len];
        var result = e2e_harness.execute_command(&[_][]const u8{ "find", "--name", name }) catch continue;
        result.deinit();
    }

    // Measurement
    var timer = try Timer.start();
    for (0..iterations) |i| {
        const name = function_names.items[i % function_names.items.len];
        timer.reset();
        var result = try e2e_harness.execute_command(&[_][]const u8{ "find", "--name", name });
        const elapsed = timer.read();
        result.deinit();
        try sampler.add_sample(elapsed);
    }

    const stats = sampler.calculate_stats();
    const bench_result = harness.BenchmarkResult{
        .name = "e2e/block_lookup_queries",
        .iterations = stats.sample_count,
        .mean_ns = stats.mean_ns,
        .median_ns = stats.median_ns,
        .min_ns = stats.min_ns,
        .max_ns = stats.max_ns,
        .p95_ns = stats.p95_ns,
        .p99_ns = stats.p99_ns,
        .std_dev_ns = stats.stddev_ns,
        .ops_per_second = if (stats.mean_ns > 0) 1_000_000_000.0 / @as(f64, @floatFromInt(stats.mean_ns)) else 0,
    };
    try bench_harness.add_result(bench_result);
}

/// Test graph traversal performance with realistic query patterns
fn bench_graph_traversal_queries(bench_harness: *BenchmarkHarness, e2e_harness: *E2ETestHarness, config: E2EBenchmarkConfig) !void {
    const iterations = @min(20, config.operations_per_type);
    const warmup = @min(4, bench_harness.config.warmup_iterations);

    var sampler = StatisticalSampler.init(bench_harness.allocator);
    defer sampler.deinit();

    // Warmup
    for (0..warmup) |_| {
        var result = e2e_harness.execute_command(&[_][]const u8{ "traverse", "--start", "benchmark_function_0_0", "--depth", "3" }) catch continue;
        result.deinit();
    }

    // Measurement
    var timer = try Timer.start();
    for (0..iterations) |i| {
        // Vary starting points for realistic traversal patterns
        const start_func = try std.fmt.allocPrint(bench_harness.allocator, "benchmark_function_{d}_0", .{i % @min(5, config.codebase_size)});
        defer bench_harness.allocator.free(start_func);

        timer.reset();
        var result = try e2e_harness.execute_command(&[_][]const u8{ "traverse", "--start", start_func, "--depth", "3" });
        const elapsed = timer.read();
        result.deinit();
        try sampler.add_sample(elapsed);
    }

    const stats = sampler.calculate_stats();
    const bench_result = harness.BenchmarkResult{
        .name = "e2e/graph_traversal_queries",
        .iterations = stats.sample_count,
        .mean_ns = stats.mean_ns,
        .median_ns = stats.median_ns,
        .min_ns = stats.min_ns,
        .max_ns = stats.max_ns,
        .p95_ns = stats.p95_ns,
        .p99_ns = stats.p99_ns,
        .std_dev_ns = stats.stddev_ns,
        .ops_per_second = if (stats.mean_ns > 0) 1_000_000_000.0 / @as(f64, @floatFromInt(stats.mean_ns)) else 0,
    };
    try bench_harness.add_result(bench_result);
}

/// Test semantic search functionality
fn bench_semantic_search_queries(bench_harness: *BenchmarkHarness, e2e_harness: *E2ETestHarness, config: E2EBenchmarkConfig) !void {
    const iterations = config.operations_per_type;
    const warmup = @min(8, bench_harness.config.warmup_iterations);

    var sampler = StatisticalSampler.init(bench_harness.allocator);
    defer sampler.deinit();

    const search_queries = [_][]const u8{
        "function implementation",
        "error handling",
        "struct definition",
        "memory allocation",
        "benchmark test",
    };

    // Warmup
    for (0..warmup) |i| {
        const query = search_queries[i % search_queries.len];
        var result = e2e_harness.execute_command(&[_][]const u8{ "search", "--query", query }) catch continue;
        result.deinit();
    }

    // Measurement
    var timer = try Timer.start();
    for (0..iterations) |i| {
        const query = search_queries[i % search_queries.len];
        timer.reset();
        var result = try e2e_harness.execute_command(&[_][]const u8{ "search", "--query", query });
        const elapsed = timer.read();
        result.deinit();
        try sampler.add_sample(elapsed);
    }

    const stats = sampler.calculate_stats();
    const bench_result = harness.BenchmarkResult{
        .name = "e2e/semantic_search_queries",
        .iterations = stats.sample_count,
        .mean_ns = stats.mean_ns,
        .median_ns = stats.median_ns,
        .min_ns = stats.min_ns,
        .max_ns = stats.max_ns,
        .p95_ns = stats.p95_ns,
        .p99_ns = stats.p99_ns,
        .std_dev_ns = stats.stddev_ns,
        .ops_per_second = if (stats.mean_ns > 0) 1_000_000_000.0 / @as(f64, @floatFromInt(stats.mean_ns)) else 0,
    };
    try bench_harness.add_result(bench_result);
}
