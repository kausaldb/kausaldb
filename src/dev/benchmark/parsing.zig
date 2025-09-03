//! File parsing performance benchmarks for KausalDB
//!
//! Tests simple file parsing performance on various code sizes.
//! Focuses on the actual parsing functionality we ship, not over-engineered abstractions.

const std = @import("std");

const coordinator = @import("../benchmark.zig");
const internal = @import("internal");
const parse_file_to_blocks = internal.parse_file_to_blocks;

const BenchmarkResult = coordinator.BenchmarkResult;

// Performance thresholds for simple parsing
const SMALL_FILE_PARSE_THRESHOLD_NS = 100_000; // 100μs for small files
const MEDIUM_FILE_PARSE_THRESHOLD_NS = 500_000; // 500μs for medium files
const LARGE_FILE_PARSE_THRESHOLD_NS = 2_000_000; // 2ms for large files

const SAMPLES = 10;
const WARMUP = 3;

/// Run all parsing benchmarks
pub fn run_all(allocator: std.mem.Allocator) !std.array_list.Managed(BenchmarkResult) {
    var results = std.array_list.Managed(BenchmarkResult).init(allocator);

    try results.append(try run_small_file_parsing(allocator));
    try results.append(try run_medium_file_parsing(allocator));
    try results.append(try run_large_file_parsing(allocator));

    return results;
}

/// Benchmark parsing small Zig files
pub fn run_small_file_parsing(allocator: std.mem.Allocator) !BenchmarkResult {
    const source =
        \\const std = @import("std");
        \\
        \\pub fn add(a: i32, b: i32) i32 {
        \\    return a + b;
        \\}
        \\
        \\test "add function" {
        \\    try std.testing.expect(add(2, 3) == 5);
        \\}
    ;

    return run_parsing_benchmark(
        allocator,
        source,
        "small_file_parsing",
        SMALL_FILE_PARSE_THRESHOLD_NS,
    );
}

/// Benchmark parsing medium Zig files
pub fn run_medium_file_parsing(allocator: std.mem.Allocator) !BenchmarkResult {
    var source = std.array_list.Managed(u8).init(allocator);
    defer source.deinit();

    try source.appendSlice("const std = @import(\"std\");\n\n");

    // Generate multiple structs and functions
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        try source.writer().print(
            \\pub const Struct{d} = struct {{
            \\    value: i32,
            \\
            \\    pub fn init(val: i32) Struct{d} {{
            \\        return .{{ .value = val }};
            \\    }}
            \\
            \\    pub fn read_value(self: Struct{d}) i32 {{
            \\        return self.value;
            \\    }}
            \\}};
            \\
            \\pub fn function_{d}() i32 {{
            \\    return {d};
            \\}}
            \\
            \\
        , .{ i, i, i, i, i });
    }

    return run_parsing_benchmark(
        allocator,
        source.items,
        "medium_file_parsing",
        MEDIUM_FILE_PARSE_THRESHOLD_NS,
    );
}

/// Benchmark parsing large Zig files
pub fn run_large_file_parsing(allocator: std.mem.Allocator) !BenchmarkResult {
    var source = std.array_list.Managed(u8).init(allocator);
    defer source.deinit();

    try source.appendSlice("const std = @import(\"std\");\n\n");

    // Generate many functions and structs
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        try source.writer().print(
            \\pub const DataType{d} = struct {{
            \\    id: u32,
            \\    name: []const u8,
            \\    data: []u8,
            \\
            \\    pub fn init(allocator: std.mem.Allocator, id: u32, name: []const u8) !DataType{d} {{
            \\        return .{{
            \\            .id = id,
            \\            .name = name,
            \\            .data = try allocator.alloc(u8, 1024),
            \\        }};
            \\    }}
            \\
            \\    pub fn process(self: *DataType{d}) void {{
            \\        for (self.data) |*byte| {{
            \\            byte.* = @intCast(self.id);
            \\        }}
            \\    }}
            \\
            \\    pub fn validate(self: DataType{d}) bool {{
            \\        return self.data.len > 0 and self.name.len > 0;
            \\    }}
            \\}};
            \\
            \\pub fn create_processor_{d}(allocator: std.mem.Allocator) !DataType{d} {{
            \\    return DataType{d}.init(allocator, {d}, "processor");
            \\}}
            \\
            \\test "data type {d}" {{
            \\    var processor = try create_processor_{d}(std.testing.allocator);
            \\    try std.testing.expect(processor.validate());
            \\}}
            \\
            \\
        , .{ i, i, i, i, i, i, i, i, i, i });
    }

    return run_parsing_benchmark(
        allocator,
        source.items,
        "large_file_parsing",
        LARGE_FILE_PARSE_THRESHOLD_NS,
    );
}

/// Core benchmark runner for file parsing
fn run_parsing_benchmark(
    allocator: std.mem.Allocator,
    source_code: []const u8,
    operation_name: []const u8,
    threshold_ns: u64,
) !BenchmarkResult {
    const config = parse_file_to_blocks.ParseConfig{
        .include_function_bodies = true,
        .include_private = true,
        .include_tests = true,
        .max_function_body_size = 8192,
    };

    var metadata = std.StringHashMap([]const u8).init(allocator);
    defer metadata.deinit();

    const file_content = parse_file_to_blocks.FileContent{
        .data = source_code,
        .path = "benchmark_test.zig",
        .content_type = "text/zig",
        .metadata = metadata,
        .timestamp_ns = @intCast(std.time.nanoTimestamp()),
    };

    // Warmup
    std.debug.print("[WARMUP] Running {d} warmup samples for {s}...\n", .{ WARMUP, operation_name });
    var i: u32 = 0;
    while (i < WARMUP) : (i += 1) {
        const blocks = try parse_file_to_blocks.parse_file_to_blocks(
            allocator,
            file_content,
            "benchmark",
            config,
        );
        allocator.free(blocks);
    }

    // Measurement
    std.debug.print("[MEASURE] Collecting {d} samples for {s}...\n", .{ SAMPLES, operation_name });
    var measurements = std.array_list.Managed(u64).init(allocator);
    defer measurements.deinit();

    var total_time_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;

    i = 0;
    while (i < SAMPLES) : (i += 1) {
        const start_time = std.time.nanoTimestamp();

        const blocks = try parse_file_to_blocks.parse_file_to_blocks(
            allocator,
            file_content,
            "benchmark",
            config,
        );

        const end_time = std.time.nanoTimestamp();
        const elapsed_ns = @as(u64, @intCast(end_time - start_time));

        allocator.free(blocks);

        try measurements.append(elapsed_ns);
        total_time_ns += elapsed_ns;
        min_ns = @min(min_ns, elapsed_ns);
        max_ns = @max(max_ns, elapsed_ns);
    }

    // Calculate statistics
    std.mem.sort(u64, measurements.items, {}, std.sort.asc(u64));
    const mean_ns = total_time_ns / SAMPLES;
    const median_ns = measurements.items[measurements.items.len / 2];

    // Calculate percentiles
    const p95_idx = (95 * measurements.items.len) / 100;
    const p99_idx = (99 * measurements.items.len) / 100;
    const p95_ns = measurements.items[@min(p95_idx, measurements.items.len - 1)];
    const p99_ns = measurements.items[@min(p99_idx, measurements.items.len - 1)];

    // Simple standard deviation
    var variance_sum: u64 = 0;
    for (measurements.items) |measurement| {
        const diff = if (measurement > mean_ns) measurement - mean_ns else mean_ns - measurement;
        variance_sum += diff * diff;
    }
    const stddev_ns = @as(u64, @intFromFloat(@sqrt(@as(f64, @floatFromInt(variance_sum / SAMPLES)))));

    const passed_threshold = mean_ns <= threshold_ns;
    const throughput_ops_per_sec = 1_000_000_000.0 / @as(f64, @floatFromInt(mean_ns));

    std.debug.print("[RESULT] {s}: {d}ns avg (min: {d}ns, max: {d}ns) - {s}\n", .{
        operation_name,
        mean_ns,
        min_ns,
        max_ns,
        if (passed_threshold) "PASS" else "FAIL",
    });

    return BenchmarkResult{
        .operation_name = operation_name,
        .iterations = SAMPLES,
        .total_time_ns = total_time_ns,
        .min_ns = min_ns,
        .max_ns = max_ns,
        .mean_ns = mean_ns,
        .median_ns = median_ns,
        .p95_ns = p95_ns,
        .p99_ns = p99_ns,
        .stddev_ns = stddev_ns,
        .throughput_ops_per_sec = throughput_ops_per_sec,
        .passed_threshold = passed_threshold,
        .threshold_ns = threshold_ns,
        .peak_memory_bytes = 0,
        .memory_growth_bytes = 0,
        .memory_efficient = true,
        .memory_kb = 0,
    };
}
