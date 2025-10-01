//! Ingestion pipeline benchmarks for KausalDB.
//! Measures performance of parsing, directory traversal, and batch ingestion.

const std = @import("std");

const internal = @import("internal");

const harness = @import("harness.zig");

const zig_parser = internal.ingestion.zig_parser;

const BenchmarkHarness = harness.BenchmarkHarness;
const Timer = std.time.Timer;

/// Main entry point called by the benchmark runner.
pub fn run_benchmarks(bench_harness: *BenchmarkHarness) !void {
    // 1. SETUP: Initialize isolated environment
    var sim_vfs = try internal.SimulationVFS.init(bench_harness.allocator);
    defer sim_vfs.deinit();

    var storage = try internal.StorageEngine.init_default(bench_harness.allocator, sim_vfs.vfs(), "bench_ingestion");
    defer storage.deinit();
    try storage.startup();
    defer storage.shutdown() catch {};

    // Create test files for parsing benchmarks
    try create_test_files(&sim_vfs, bench_harness.allocator);

    // 2. RUN BENCHMARKS
    try bench_zig_parser_throughput(bench_harness, bench_harness.allocator);
    try bench_directory_traversal(bench_harness, &sim_vfs, bench_harness.allocator);
    try bench_batch_ingestion_small(bench_harness, &storage);
    try bench_batch_ingestion_large(bench_harness, &storage);
    try bench_incremental_ingestion(bench_harness, &storage);
}

/// Benchmark Zig parser throughput
fn bench_zig_parser_throughput(bench_harness: *BenchmarkHarness, allocator: std.mem.Allocator) !void {
    const iterations = bench_harness.config.iterations;
    const warmup = bench_harness.config.warmup_iterations;

    // Create sample Zig source code
    const sample_code =
        \\const std = @import("std");
        \\
        \\pub fn main() !void {
        \\    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        \\    defer _ = gpa.deinit();
        \\    const allocator = gpa.allocator();
        \\
        \\    const args = try std.process.argsAlloc(allocator);
        \\    defer std.process.argsFree(allocator, args);
        \\
        \\    for (args[1..]) |arg| {
        \\        std.debug.print("Arg: {s}\n", .{arg});
        \\    }
        \\}
        \\
        \\fn helper_function(value: u32) u32 {
        \\    return value * 2;
        \\}
        \\
        \\test "basic test" {
        \\    try std.testing.expectEqual(@as(u32, 4), helper_function(2));
        \\}
    ;

    // 3. COLLECT SAMPLES
    var samples = std.ArrayList(u64){};
    defer samples.deinit(allocator);

    // 4. WARMUP
    for (0..warmup) |_| {
        _ = perform_zig_parse(sample_code, allocator) catch continue;
    }

    // 5. MEASUREMENT
    var timer = try Timer.start();
    for (0..iterations) |_| {
        timer.reset();
        _ = try perform_zig_parse(sample_code, allocator);
        try samples.append(allocator, timer.read());
    }

    // 6. CALCULATE AND REPORT
    const result = harness.calculate_benchmark_result("ingestion/zig_parser_throughput", samples.items);
    try bench_harness.add_result(result);
}

/// Benchmark directory tree traversal
fn bench_directory_traversal(bench_harness: *BenchmarkHarness, vfs: *internal.SimulationVFS, allocator: std.mem.Allocator) !void {
    const iterations = @min(100, bench_harness.config.iterations); // Directory ops can be expensive
    const warmup = @min(20, bench_harness.config.warmup_iterations);

    var samples = std.ArrayList(u64){};
    defer samples.deinit(allocator);

    for (0..warmup) |_| {
        _ = perform_directory_traversal(vfs, allocator) catch continue;
    }

    var timer = try Timer.start();
    for (0..iterations) |_| {
        timer.reset();
        _ = try perform_directory_traversal(vfs, allocator);
        try samples.append(allocator, timer.read());
    }

    const result = harness.calculate_benchmark_result("ingestion/directory_traversal", samples.items);
    try bench_harness.add_result(result);
}

/// Benchmark small batch ingestion (10 files)
fn bench_batch_ingestion_small(bench_harness: *BenchmarkHarness, storage: *internal.StorageEngine) !void {
    const iterations = bench_harness.config.iterations;
    const warmup = bench_harness.config.warmup_iterations;
    const batch_size = 10;

    var samples = std.ArrayList(u64){};
    defer samples.deinit(bench_harness.allocator);

    for (0..warmup) |i| {
        _ = perform_batch_ingestion(storage, batch_size, i * 1000) catch continue;
    }

    var timer = try Timer.start();
    for (0..iterations) |i| {
        timer.reset();
        _ = try perform_batch_ingestion(storage, batch_size, (warmup + i) * 1000);
        try samples.append(bench_harness.allocator, timer.read());
    }

    const result = harness.calculate_benchmark_result("ingestion/batch_small", samples.items);
    try bench_harness.add_result(result);
}

/// Benchmark large batch ingestion (100 files)
fn bench_batch_ingestion_large(bench_harness: *BenchmarkHarness, storage: *internal.StorageEngine) !void {
    const iterations = @min(50, bench_harness.config.iterations); // Large batches are expensive
    const warmup = @min(10, bench_harness.config.warmup_iterations);
    const batch_size = 100;

    var samples = std.ArrayList(u64){};
    defer samples.deinit(bench_harness.allocator);

    for (0..warmup) |i| {
        _ = perform_batch_ingestion(storage, batch_size, i * 10000) catch continue;
    }

    var timer = try Timer.start();
    for (0..iterations) |i| {
        timer.reset();
        _ = try perform_batch_ingestion(storage, batch_size, (warmup + i) * 10000);
        try samples.append(bench_harness.allocator, timer.read());
    }

    const result = harness.calculate_benchmark_result("ingestion/batch_large", samples.items);
    try bench_harness.add_result(result);
}

/// Benchmark incremental ingestion (one file at a time)
fn bench_incremental_ingestion(bench_harness: *BenchmarkHarness, storage: *internal.StorageEngine) !void {
    const iterations = bench_harness.config.iterations;
    const warmup = bench_harness.config.warmup_iterations;

    var samples = std.ArrayList(u64){};
    defer samples.deinit(bench_harness.allocator);

    for (0..warmup) |i| {
        _ = perform_single_file_ingestion(storage, i) catch continue;
    }

    var timer = try Timer.start();
    for (0..iterations) |i| {
        timer.reset();
        _ = try perform_single_file_ingestion(storage, warmup + i);
        try samples.append(bench_harness.allocator, timer.read());
    }

    const result = harness.calculate_benchmark_result("ingestion/incremental", samples.items);
    try bench_harness.add_result(result);
}

/// Parse Zig source code
fn perform_zig_parse(source: []const u8, allocator: std.mem.Allocator) !void {
    const source_z = try allocator.dupeZ(u8, source);
    defer allocator.free(source_z);

    const units = try zig_parser.parse(allocator, source_z, "bench://test.zig");
    defer {
        for (units) |*unit| {
            var mutable_unit = unit.*;
            mutable_unit.deinit(allocator);
        }
        allocator.free(units);
    }
}

/// Traverse directory structure
fn perform_directory_traversal(vfs: *internal.SimulationVFS, allocator: std.mem.Allocator) !void {
    const vfs_interface = vfs.vfs();

    // Simple directory traversal using VFS operations
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var count: usize = 0;
    if (vfs_interface.exists("test_project")) {
        var iterator = try vfs_interface.iterate_directory("test_project", arena_allocator);
        while (iterator.next()) |entry| {
            count += 1;
            // Recursively check subdirectories
            if (entry.kind == .directory) {
                const subdir_path = try std.fmt.allocPrint(arena_allocator, "test_project/{s}", .{entry.name});
                var sub_iterator = vfs_interface.iterate_directory(subdir_path, arena_allocator) catch continue;
                while (sub_iterator.next()) |sub_entry| {
                    _ = sub_entry;
                    count += 1;
                }
            }
        }
    }
}

/// Perform batch ingestion
fn perform_batch_ingestion(storage: *internal.StorageEngine, batch_size: usize, offset: usize) !void {
    for (0..batch_size) |i| {
        const block = internal.ContextBlock{
            .id = internal.BlockId.from_u64(offset + i),
            .sequence = 0,
            .source_uri = "bench://batch/file.zig",
            .metadata_json = "{}",
            .content = "fn batch_function() { return 42; }",
        };
        try storage.put_block(block);
    }
}

/// Perform single file ingestion
fn perform_single_file_ingestion(storage: *internal.StorageEngine, index: usize) !void {
    const block = internal.ContextBlock{
        .id = internal.BlockId.from_u64(index + 500000),
        .sequence = 0,
        .source_uri = "bench://incremental/file.zig",
        .metadata_json = "{}",
        .content = "fn incremental_function() { return 42; }",
    };
    try storage.put_block(block);
}

/// Create test files in the VFS for benchmarking
fn create_test_files(vfs: *internal.SimulationVFS, _: std.mem.Allocator) !void {
    const vfs_interface = vfs.vfs();

    // Create a project structure
    try vfs_interface.mkdir("test_project");
    try vfs_interface.mkdir("test_project/src");
    try vfs_interface.mkdir("test_project/src/core");
    try vfs_interface.mkdir("test_project/tests");

    // Create Zig files
    const files = [_]struct { path: []const u8, content: []const u8 }{
        .{ .path = "test_project/src/main.zig", .content =
        \\const std = @import("std");
        \\pub fn main() !void {
        \\    std.debug.print("Hello, world!\n", .{});
        \\}
        },
        .{ .path = "test_project/src/core/types.zig", .content =
        \\pub const MyType = struct {
        \\    value: u32,
        \\    pub fn init(v: u32) MyType {
        \\        return .{ .value = v };
        \\    }
        \\};
        },
        .{ .path = "test_project/tests/test.zig", .content =
        \\const std = @import("std");
        \\test "basic test" {
        \\    try std.testing.expectEqual(@as(u32, 42), 42);
        \\}
        },
    };

    for (files) |file| {
        var vfile = try vfs_interface.create(file.path);
        defer vfile.close();
        _ = try vfile.write(file.content);
    }

    // Create some non-Zig files to test filtering
    const other_files = [_][]const u8{
        "test_project/README.md",
        "test_project/build.zig.zon",
        "test_project/.gitignore",
    };

    for (other_files) |path| {
        var vfile = try vfs_interface.create(path);
        defer vfile.close();
        _ = try vfile.write("test content");
    }
}
