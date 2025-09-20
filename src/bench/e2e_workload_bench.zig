//! Realistic mixed-workload benchmark for KausalDB performance validation.
//!
//! This benchmark replaces misleading microbenchmarks with realistic end-to-end
//! performance measurement of actual KausalDB usage patterns. It measures the
//! complete pipeline: ingestion, storage, and query performance under mixed workloads.
//!
//! Benchmark workflow:
//! 1. Create a realistic test project with interconnected code
//! 2. Link and sync the project (full ingestion pipeline)
//! 3. Execute mixed queries representing real usage patterns
//! 4. Measure and report P50, P95, P99 latencies with statistical confidence

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const testing = std.testing;

const LatencySampler = struct {
    samples: std.array_list.Managed(u64),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        var samples = std.array_list.Managed(u64).init(allocator);
        samples.ensureTotalCapacity(1024) catch {}; // Pre-allocate for performance
        return Self{
            .samples = samples,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.samples.deinit();
    }

    pub fn add_sample(self: *Self, latency_ns: u64) !void {
        try self.samples.append(latency_ns);
    }

    pub fn calculate_percentiles(self: *Self) PercentileStats {
        if (self.samples.items.len == 0) {
            return PercentileStats{};
        }

        std.mem.sort(u64, self.samples.items, {}, std.sort.asc(u64));

        const len = self.samples.items.len;
        const p50_idx = len / 2;
        const p95_idx = (len * 95) / 100;
        const p99_idx = (len * 99) / 100;

        return PercentileStats{
            .samples = len,
            .p50_ns = self.samples.items[p50_idx],
            .p95_ns = self.samples.items[p95_idx],
            .p99_ns = self.samples.items[p99_idx],
            .min_ns = self.samples.items[0],
            .max_ns = self.samples.items[len - 1],
        };
    }
};

const PercentileStats = struct {
    samples: usize = 0,
    p50_ns: u64 = 0,
    p95_ns: u64 = 0,
    p99_ns: u64 = 0,
    min_ns: u64 = 0,
    max_ns: u64 = 0,

    pub fn format(self: PercentileStats, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        if (self.samples == 0) {
            return writer.print("No samples", .{});
        }
        const p50_ms = @as(f64, @floatFromInt(self.p50_ns)) / 1_000_000.0;
        const p95_ms = @as(f64, @floatFromInt(self.p95_ns)) / 1_000_000.0;
        const p99_ms = @as(f64, @floatFromInt(self.p99_ns)) / 1_000_000.0;
        return writer.print("P50: {:.2}ms, P95: {:.2}ms, P99: {:.2}ms ({} samples)", .{ p50_ms, p95_ms, p99_ms, self.samples });
    }
};

/// Mixed-workload benchmark configuration
const BenchmarkConfig = struct {
    /// Number of query operations per command type
    operations_per_type: u32 = 100,
    /// Size of test codebase (number of files)
    codebase_size: u32 = 50,
    /// Functions per file for realistic complexity
    functions_per_file: u32 = 8,
    /// Enable verbose output for debugging
    verbose: bool = false,
};

/// E2E workload benchmark - measures realistic KausalDB performance
const E2EWorkloadBench = struct {
    allocator: std.mem.Allocator,
    config: BenchmarkConfig,
    temp_dir: std.testing.TmpDir,
    binary_path: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: BenchmarkConfig) !Self {
        const relative_binary_path = try std.fs.path.join(allocator, &[_][]const u8{ "zig-out", "bin", "kausaldb" });
        defer allocator.free(relative_binary_path);
        const binary_path = try std.fs.cwd().realpathAlloc(allocator, relative_binary_path);

        // Verify binary exists and is executable
        std.fs.cwd().access(binary_path, .{}) catch |err| {
            std.debug.print("ERROR: KausalDB binary not found at {s}\n", .{binary_path});
            std.debug.print("Error details: {}\n", .{err});
            std.debug.print("Current working directory: {s}\n", .{std.fs.cwd().realpathAlloc(allocator, ".") catch "unknown"});

            // List contents of zig-out/bin if it exists
            if (std.fs.cwd().openDir("zig-out/bin", .{})) |bin_dir| {
                var bin_dir_copy = bin_dir;
                std.debug.print("Contents of zig-out/bin:\n", .{});
                var iterator = bin_dir_copy.iterate();
                while (iterator.next() catch null) |entry| {
                    std.debug.print("  - {s} ({s})\n", .{ entry.name, @tagName(entry.kind) });
                }
                bin_dir_copy.close();
            } else |_| {
                std.debug.print("zig-out/bin directory does not exist\n", .{});
            }

            std.debug.print("Run './zig/zig build' first to build the binary\n", .{});
            return error.BinaryNotFound;
        };

        // Test binary execution
        const version_result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ binary_path, "--version" },
            .max_output_bytes = 1024,
        }) catch |err| {
            std.debug.print("ERROR: Failed to execute binary at {s}: {}\n", .{ binary_path, err });
            return error.BinaryNotExecutable;
        };
        allocator.free(version_result.stdout);
        allocator.free(version_result.stderr);

        if (version_result.term != .Exited or version_result.term.Exited != 0) {
            std.debug.print("ERROR: Binary failed version check with exit code: {}\n", .{version_result.term});
            return error.BinaryNotWorking;
        }

        const temp_dir = std.testing.tmpDir(.{});

        return Self{
            .allocator = allocator,
            .config = config,
            .temp_dir = temp_dir,
            .binary_path = binary_path,
        };
    }

    pub fn deinit(self: *Self) void {
        self.temp_dir.cleanup();
        self.allocator.free(self.binary_path);
    }

    /// Create realistic test project with interconnected dependencies
    fn create_test_project(self: *Self) ![]const u8 {
        const project_name = "kausal_bench_project";
        const project_path = try self.temp_dir.dir.realpathAlloc(self.allocator, ".");

        // Create project subdirectory
        try self.temp_dir.dir.makeDir(project_name);
        const full_project_path = try std.fs.path.join(self.allocator, &[_][]const u8{ project_path, project_name });

        if (self.config.verbose) {
            std.debug.print("Creating test project at: {s}\n", .{full_project_path});
        }

        // Generate interconnected source files with realistic patterns
        var file_idx: u32 = 0;
        while (file_idx < self.config.codebase_size) : (file_idx += 1) {
            const filename = try std.fmt.allocPrint(self.allocator, "{s}/module_{d}.zig", .{ project_name, file_idx });
            defer self.allocator.free(filename);

            const file = try self.temp_dir.dir.createFile(filename, .{});
            defer file.close();

            try self.write_realistic_module(file, file_idx);
        }

        // Create main.zig that imports and uses several modules
        const main_filename = try std.fmt.allocPrint(self.allocator, "{s}/main.zig", .{project_name});
        defer self.allocator.free(main_filename);

        const main_file = try self.temp_dir.dir.createFile(main_filename, .{});
        defer main_file.close();

        try self.write_main_module(main_file);

        self.allocator.free(project_path);
        return full_project_path;
    }

    fn write_realistic_module(self: *Self, file: std.fs.File, module_idx: u32) !void {
        // Standard imports to create realistic dependency patterns
        try file.writeAll("const std = @import(\"std\");\n");

        // Cross-module imports to create graph edges
        if (module_idx > 0) {
            const import_idx = module_idx / 2; // Import every other module
            const import_line = try std.fmt.allocPrint(self.allocator, "const module_{d} = @import(\"module_{d}.zig\");\n", .{ import_idx, import_idx });
            defer self.allocator.free(import_line);
            try file.writeAll(import_line);
        }
        try file.writeAll("\n");

        // Generate functions with realistic call patterns
        var func_idx: u32 = 0;
        while (func_idx < self.config.functions_per_file) : (func_idx += 1) {
            const func_header = try std.fmt.allocPrint(self.allocator, "pub fn process_data_{d}(input: []const u8) ![]const u8 {{\n", .{func_idx});
            defer self.allocator.free(func_header);
            try file.writeAll(func_header);

            try file.writeAll("    var result = try std.heap.page_allocator.alloc(u8, input.len + 20);\n");
            try file.writeAll("    _ = try std.fmt.bufPrint(result, \"processed: {s}\", .{input});\n");

            // Add cross-module calls to create realistic graph edges
            if (module_idx > 0 and func_idx % 2 == 0) {
                const call_func = func_idx / 2;
                const call_line = try std.fmt.allocPrint(self.allocator, "    _ = try module_{d}.process_data_{d}(input);\n", .{ module_idx / 2, call_func });
                defer self.allocator.free(call_line);
                try file.writeAll(call_line);
            }

            try file.writeAll("    return result;\n");
            try file.writeAll("}\n\n");
        }

        // Add some structs and constants to increase parsing complexity
        const module_const = try std.fmt.allocPrint(self.allocator, "pub const MODULE_ID = {};\n", .{module_idx});
        defer self.allocator.free(module_const);
        try file.writeAll(module_const);

        try file.writeAll("pub const Config = struct {\n");
        try file.writeAll("    enabled: bool = true,\n");
        try file.writeAll("    max_size: u32 = 1024,\n");
        try file.writeAll("    timeout_ms: u64 = 5000,\n");
        try file.writeAll("};\n");
    }

    fn write_main_module(self: *Self, file: std.fs.File) !void {
        try file.writeAll("const std = @import(\"std\");\n");

        // Import several modules to create entry points
        const import_count = @min(5, self.config.codebase_size);
        var i: u32 = 0;
        while (i < import_count) : (i += 1) {
            const import_line = try std.fmt.allocPrint(self.allocator, "const module_{d} = @import(\"module_{d}.zig\");\n", .{ i, i });
            defer self.allocator.free(import_line);
            try file.writeAll(import_line);
        }

        try file.writeAll("\npub fn main() !void {\n");
        try file.writeAll("    const allocator = std.heap.page_allocator;\n");
        try file.writeAll("    _ = allocator;\n");

        // Create function calls that will show up in traces
        i = 0;
        while (i < import_count) : (i += 1) {
            const call_line = try std.fmt.allocPrint(self.allocator, "    _ = try module_{d}.process_data_0(\"test\");\n", .{i});
            defer self.allocator.free(call_line);
            try file.writeAll(call_line);
        }

        try file.writeAll("}\n");
    }

    /// Execute KausalDB command and measure latency
    fn execute_timed_command(self: *Self, args: []const []const u8, sampler: *LatencySampler) !void {
        var argv_list = std.array_list.Managed([]const u8).init(self.allocator);
        defer argv_list.deinit();
        try argv_list.ensureTotalCapacity(args.len + 1);

        try argv_list.append(self.binary_path);
        try argv_list.appendSlice(args);

        const start_time = std.time.nanoTimestamp();

        if (self.config.verbose) {
            std.debug.print("Executing command: {s}", .{self.binary_path});
            for (args) |arg| {
                std.debug.print(" {s}", .{arg});
            }
            std.debug.print("\n", .{});
        }

        const cwd_path = try self.temp_dir.dir.realpathAlloc(self.allocator, ".");
        defer self.allocator.free(cwd_path);

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = argv_list.items,
            .cwd = cwd_path,
            .max_output_bytes = 4 * 1024 * 1024, // 4MB
        }) catch |err| {
            std.debug.print("ERROR: Failed to execute command: {}\n", .{err});
            std.debug.print("Binary path: {s}\n", .{self.binary_path});
            std.debug.print("Working directory: {s}\n", .{cwd_path});
            std.debug.print("Arguments: ", .{});
            for (argv_list.items) |arg| {
                std.debug.print("'{s}' ", .{arg});
            }
            std.debug.print("\n", .{});
            return err;
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        const end_time = std.time.nanoTimestamp();
        const latency_ns = @as(u64, @intCast(end_time - start_time));

        try sampler.add_sample(latency_ns);

        // Verify command succeeded
        const exit_code: u8 = switch (result.term) {
            .Exited => |code| @intCast(code),
            else => 255,
        };

        if (exit_code != 0) {
            std.debug.print("Command failed with exit code {}\n", .{exit_code});
            std.debug.print("Command: {s}", .{self.binary_path});
            for (args) |arg| {
                std.debug.print(" {s}", .{arg});
            }
            std.debug.print("\n", .{});

            if (result.stderr.len > 0) {
                std.debug.print("STDERR:\n{s}\n", .{result.stderr});
            }
            if (result.stdout.len > 0) {
                std.debug.print("STDOUT:\n{s}\n", .{result.stdout});
            }

            return error.CommandFailed;
        }

        if (self.config.verbose and result.stdout.len > 0) {
            std.debug.print("Command output: {s}\n", .{result.stdout});
        }
    }

    /// Run the complete mixed-workload benchmark
    pub fn run_benchmark(self: *Self) !BenchmarkResults {
        std.debug.print("Starting E2E benchmark with configuration:\n", .{});
        std.debug.print("  Operations per type: {}\n", .{self.config.operations_per_type});
        std.debug.print("  Codebase size: {} files\n", .{self.config.codebase_size});
        std.debug.print("  Functions per file: {}\n", .{self.config.functions_per_file});
        std.debug.print("  Binary path: {s}\n", .{self.binary_path});
        std.debug.print("  Verbose: {}\n", .{self.config.verbose});
        std.debug.print("Creating test project with {d} files, {d} functions per file...\n", .{ self.config.codebase_size, self.config.functions_per_file });

        const project_path = try self.create_test_project();
        defer self.allocator.free(project_path);

        var ingestion_sampler = LatencySampler.init(self.allocator);
        defer ingestion_sampler.deinit();

        var find_sampler = LatencySampler.init(self.allocator);
        defer find_sampler.deinit();

        var show_sampler = LatencySampler.init(self.allocator);
        defer show_sampler.deinit();

        var trace_sampler = LatencySampler.init(self.allocator);
        defer trace_sampler.deinit();

        // Phase 1: Ingestion benchmark (link + sync)
        std.debug.print("Benchmarking ingestion pipeline...\n", .{});

        try self.execute_timed_command(&[_][]const u8{ "link", project_path }, &ingestion_sampler);
        try self.execute_timed_command(&[_][]const u8{"sync"}, &ingestion_sampler);

        // Phase 2: Mixed query benchmark
        std.debug.print("Benchmarking mixed query workload ({d} operations per type)...\n", .{self.config.operations_per_type});

        // Realistic find operations
        var op_idx: u32 = 0;
        while (op_idx < self.config.operations_per_type) : (op_idx += 1) {
            const func_name = try std.fmt.allocPrint(self.allocator, "process_data_{d}", .{op_idx % self.config.functions_per_file});
            defer self.allocator.free(func_name);

            try self.execute_timed_command(&[_][]const u8{ "find", "function", func_name }, &find_sampler);
        }

        // Show queries (what calls/uses functions)
        op_idx = 0;
        while (op_idx < self.config.operations_per_type) : (op_idx += 1) {
            const file_name = try std.fmt.allocPrint(self.allocator, "module_{d}.zig", .{op_idx % self.config.codebase_size});
            defer self.allocator.free(file_name);

            try self.execute_timed_command(&[_][]const u8{ "show", "file", file_name }, &show_sampler);
        }

        // Trace queries (follow call chains)
        op_idx = 0;
        while (op_idx < self.config.operations_per_type) : (op_idx += 1) {
            const func_name = try std.fmt.allocPrint(self.allocator, "process_data_{d}", .{op_idx % 3}); // Focus on heavily used functions
            defer self.allocator.free(func_name);

            try self.execute_timed_command(&[_][]const u8{ "trace", "callees", func_name, "--depth", "3" }, &trace_sampler);
        }

        return BenchmarkResults{
            .ingestion = ingestion_sampler.calculate_percentiles(),
            .find_queries = find_sampler.calculate_percentiles(),
            .show_queries = show_sampler.calculate_percentiles(),
            .trace_queries = trace_sampler.calculate_percentiles(),
        };
    }
};

const BenchmarkResults = struct {
    ingestion: PercentileStats,
    find_queries: PercentileStats,
    show_queries: PercentileStats,
    trace_queries: PercentileStats,

    pub fn print_results(self: BenchmarkResults) void {
        std.debug.print("\n=== KausalDB E2E Mixed-Workload Benchmark Results ===\n\n", .{});
        std.debug.print("Ingestion (link + sync): {any}\n", .{self.ingestion});
        std.debug.print("Find function queries:   {any}\n", .{self.find_queries});
        std.debug.print("Show file queries:       {any}\n", .{self.show_queries});
        std.debug.print("Trace call queries:      {any}\n", .{self.trace_queries});
        std.debug.print("\n", .{});

        // Performance interpretation
        if (self.find_queries.p95_ns > 0) {
            const p95_ms = @as(f64, @floatFromInt(self.find_queries.p95_ns)) / 1_000_000.0;
            std.debug.print("Performance Summary:\n", .{});
            std.debug.print("- P95 find query latency: {d:.2} ms\n", .{p95_ms});

            if (p95_ms < 50.0) {
                std.debug.print("- Performance level: EXCELLENT (< 50ms P95)\n", .{});
            } else if (p95_ms < 200.0) {
                std.debug.print("- Performance level: GOOD (< 200ms P95)\n", .{});
            } else if (p95_ms < 1000.0) {
                std.debug.print("- Performance level: ACCEPTABLE (< 1s P95)\n", .{});
            } else {
                std.debug.print("- Performance level: NEEDS OPTIMIZATION (>= 1s P95)\n", .{});
            }
        }

        // Include system information for reproducibility
        std.debug.print("\nSystem Information:\n", .{});
        std.debug.print("- Platform: {s}-{s}\n", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });
        std.debug.print("- Build mode: {s}\n", .{@tagName(builtin.mode)});
    }
};

// Export main benchmark function for build system integration
pub fn run_e2e_benchmark(allocator: std.mem.Allocator) !void {
    // Scale operations based on benchmark iterations to respect CI constraints
    const operations_per_type = @min(50, @max(5, build_options.bench_iterations / 20));

    const config = BenchmarkConfig{
        .operations_per_type = operations_per_type,
        .codebase_size = 25, // Medium-sized project
        .functions_per_file = 6, // Realistic complexity
        .verbose = false,
    };

    var benchmark = try E2EWorkloadBench.init(allocator, config);
    defer benchmark.deinit();

    const results = try benchmark.run_benchmark();
    results.print_results();
}

// Export harness-integrated benchmark function for regression detection
pub fn run_e2e_benchmark_with_harness(harness: anytype) !void {
    // Scale operations based on benchmark iterations to respect CI constraints
    const operations_per_type = @min(50, @max(5, build_options.bench_iterations / 20));

    const config = BenchmarkConfig{
        .operations_per_type = operations_per_type,
        .codebase_size = 25, // Medium-sized project
        .functions_per_file = 6, // Realistic complexity
        .verbose = false,
    };

    var benchmark = try E2EWorkloadBench.init(harness.allocator, config);
    defer benchmark.deinit();

    const results = try benchmark.run_benchmark();

    // Convert e2e results to harness format for regression detection
    const main = @import("main.zig");
    const BenchmarkResult = main.BenchmarkResult;

    // Add ingestion benchmark result
    try harness.add_result(BenchmarkResult{
        .name = "e2e_ingestion",
        .iterations = @intCast(results.ingestion.samples),
        .mean_ns = results.ingestion.p50_ns, // Use median as mean for robust comparison
        .median_ns = results.ingestion.p50_ns,
        .min_ns = results.ingestion.min_ns,
        .max_ns = results.ingestion.max_ns,
        .std_dev_ns = 0, // Not calculated in e2e benchmark
        .ops_per_second = if (results.ingestion.p50_ns > 0) 1_000_000_000.0 / @as(f64, @floatFromInt(results.ingestion.p50_ns)) else 0,
    });

    // Add query benchmark results
    try harness.add_result(BenchmarkResult{
        .name = "e2e_find_queries",
        .iterations = @intCast(results.find_queries.samples),
        .mean_ns = results.find_queries.p50_ns,
        .median_ns = results.find_queries.p50_ns,
        .min_ns = results.find_queries.min_ns,
        .max_ns = results.find_queries.max_ns,
        .std_dev_ns = 0,
        .ops_per_second = if (results.find_queries.p50_ns > 0) 1_000_000_000.0 / @as(f64, @floatFromInt(results.find_queries.p50_ns)) else 0,
    });

    try harness.add_result(BenchmarkResult{
        .name = "e2e_show_queries",
        .iterations = @intCast(results.show_queries.samples),
        .mean_ns = results.show_queries.p50_ns,
        .median_ns = results.show_queries.p50_ns,
        .min_ns = results.show_queries.min_ns,
        .max_ns = results.show_queries.max_ns,
        .std_dev_ns = 0,
        .ops_per_second = if (results.show_queries.p50_ns > 0) 1_000_000_000.0 / @as(f64, @floatFromInt(results.show_queries.p50_ns)) else 0,
    });

    try harness.add_result(BenchmarkResult{
        .name = "e2e_trace_queries",
        .iterations = @intCast(results.trace_queries.samples),
        .mean_ns = results.trace_queries.p50_ns,
        .median_ns = results.trace_queries.p50_ns,
        .min_ns = results.trace_queries.min_ns,
        .max_ns = results.trace_queries.max_ns,
        .std_dev_ns = 0,
        .ops_per_second = if (results.trace_queries.p50_ns > 0) 1_000_000_000.0 / @as(f64, @floatFromInt(results.trace_queries.p50_ns)) else 0,
    });

    // Still print the detailed e2e results for context
    results.print_results();
}

test "e2e benchmark framework validation" {
    // Validate that benchmark framework compiles and basic functionality works
    const config = BenchmarkConfig{
        .operations_per_type = 1,
        .codebase_size = 2,
        .functions_per_file = 2,
        .verbose = true,
    };

    // Test sampler functionality
    var sampler = LatencySampler.init(testing.allocator);
    defer sampler.deinit();

    try sampler.add_sample(1000000); // 1ms
    try sampler.add_sample(2000000); // 2ms

    const stats = sampler.calculate_percentiles();
    try testing.expect(stats.p50_ns == 1000000); // Median should be 1ms

    // Don't run full benchmark in tests - that would require the binary
    // and would be too slow for unit tests
    _ = config; // Avoid unused variable warning
}
