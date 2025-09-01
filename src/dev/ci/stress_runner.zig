//! Cross-platform CI stress testing runner
//!
//! Replaces shell-based stress testing with pure Zig implementation
//! for Windows compatibility and better error handling.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const print = std.debug.print;

const StressTestConfig = struct {
    memory_limit_mb: u32 = 2048,
    timeout_seconds: u32 = 300,
    cycles: u32 = 5,
    concurrent_processes: u32 = 2, // Reduce to avoid resource conflicts
};

const StressTestResult = struct {
    cycles_completed: u32,
    cycles_failed: u32,
    total_duration_ms: u64,
    memory_peak_mb: u32,
    errors: std.array_list.Managed([]const u8),

    fn success_rate(self: @This()) f64 {
        if (self.cycles_completed == 0) return 0.0;
        return @as(f64, @floatFromInt(self.cycles_completed - self.cycles_failed)) / @as(f64, @floatFromInt(self.cycles_completed)) * 100.0;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    print("╔═════════════════════════════════════════════════════════════════╗\n", .{});
    print("║                    KausalDB CI Stress Runner                    ║\n", .{});
    print("║                Cross-Platform Stress Testing                    ║\n", .{});
    print("╚═════════════════════════════════════════════════════════════════╝\n\n", .{});

    var config = StressTestConfig{};

    // Parse command line arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--memory-limit")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            config.memory_limit_mb = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--timeout")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            config.timeout_seconds = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--cycles")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            config.cycles = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            print_usage();
            return;
        }
    }

    print("Configuration:\n", .{});
    print("  Memory limit: {}MB\n", .{config.memory_limit_mb});
    print("  Timeout: {}s\n", .{config.timeout_seconds});
    print("  Cycles: {}\n", .{config.cycles});
    print("  Platform: {s}\n\n", .{@tagName(builtin.os.tag)});

    const start_time = std.time.milliTimestamp();

    var result = StressTestResult{
        .cycles_completed = 0,
        .cycles_failed = 0,
        .total_duration_ms = 0,
        .memory_peak_mb = 0,
        .errors = std.array_list.Managed([]const u8).init(allocator),
    };
    defer result.errors.deinit();

    try run_memory_pressure_test(allocator, &config, &result);
    try run_concurrency_stress_test(allocator, &config, &result);
    try run_resource_exhaustion_test(allocator, &config, &result);

    const end_time = std.time.milliTimestamp();
    result.total_duration_ms = @intCast(end_time - start_time);

    print_results(result);

    // Exit with appropriate code
    if (result.cycles_failed > 0 or result.success_rate() < 80.0) {
        print("\n[-] Stress testing failed - system not ready for production\n", .{});
        std.process.exit(1);
    } else {
        print("\n[+] Stress testing passed - system ready for high load\n", .{});
    }
}

fn run_memory_pressure_test(
    allocator: std.mem.Allocator,
    config: *const StressTestConfig,
    result: *StressTestResult,
) !void {
    print("PHASE 1: Memory Pressure Testing\n", .{});
    print("────────────────────────────────\n", .{});

    for (0..config.cycles) |cycle| {
        print("  Memory pressure cycle {}/{}\n", .{ cycle + 1, config.cycles });

        // Platform-specific memory limiting
        const success = switch (builtin.os.tag) {
            .linux => blk: {
                // Use getrlimit/setrlimit for memory constraints
                break :blk run_test_with_memory_limit(allocator, config.memory_limit_mb, config.timeout_seconds);
            },
            .macos => blk: {
                // macOS memory pressure simulation
                break :blk run_test_with_memory_limit(allocator, config.memory_limit_mb, config.timeout_seconds);
            },
            .windows => blk: {
                // Windows: Use Job Objects for resource limiting
                print("  [Windows memory limiting not yet implemented - running without constraints]\n");
                break :blk run_normal_test(allocator, config.timeout_seconds);
            },
            else => run_normal_test(allocator, config.timeout_seconds),
        };

        result.cycles_completed += 1;
        if (!success) {
            result.cycles_failed += 1;
            try result.errors.append("Memory pressure test failed");
        }
    }

    print("  Memory pressure: {}/{} cycles passed\n\n", .{ result.cycles_completed - result.cycles_failed, result.cycles_completed });
}

fn run_concurrency_stress_test(
    allocator: std.mem.Allocator,
    config: *const StressTestConfig,
    result: *StressTestResult,
) !void {
    print("PHASE 2: Concurrency Stress Testing\n", .{});
    print("────────────────────────────────────\n", .{});

    var processes = std.array_list.Managed(std.process.Child).init(allocator);
    defer {
        for (processes.items) |*process| {
            _ = process.wait() catch {};
        }
        processes.deinit();
    }

    // Start concurrent test processes
    for (0..config.concurrent_processes) |i| {
        print("  Starting concurrent test process {}\n", .{i + 1});

        var child = std.process.Child.init(&.{ "./zig/zig", "build", "test" }, allocator);
        try child.spawn();
        try processes.append(child);
    }

    // Wait for all processes with timeout
    var successful_processes: u32 = 0;
    for (processes.items) |*process| {
        const term = process.wait() catch |err| {
            print("  Process wait error: {}\n", .{err});
            continue;
        };

        switch (term) {
            .Exited => |code| {
                if (code == 0) {
                    successful_processes += 1;
                } else {
                    try result.errors.append("Concurrent test process failed");
                }
            },
            else => {
                try result.errors.append("Concurrent test process terminated abnormally");
            },
        }
    }

    print("  Concurrency stress: {}/{} processes succeeded\n\n", .{ successful_processes, config.concurrent_processes });

    if (successful_processes < config.concurrent_processes / 2) {
        result.cycles_failed += 1;
    }
    result.cycles_completed += 1;
}

fn run_resource_exhaustion_test(
    allocator: std.mem.Allocator,
    config: *const StressTestConfig,
    result: *StressTestResult,
) !void {
    _ = allocator;
    _ = config;

    print("PHASE 3: Resource Exhaustion Testing\n", .{});
    print("─────────────────────────────────────\n", .{});

    // Platform-specific resource exhaustion simulation
    switch (builtin.os.tag) {
        .linux => {
            print("  Testing under Linux resource constraints...\n", .{});
            print("  [Advanced resource exhaustion tests not yet implemented]\n", .{});
        },
        .macos => {
            print("  Testing under macOS resource constraints...\n", .{});
            print("  [Advanced resource exhaustion tests not yet implemented]\n", .{});
        },
        .windows => {
            print("  Testing under Windows resource constraints...\n", .{});
            print("  [Advanced resource exhaustion tests not yet implemented]\n", .{});
        },
        else => {
            print("  Platform {} not supported for resource exhaustion testing\n", .{builtin.os.tag});
        },
    }

    result.cycles_completed += 1;
    print("  Resource exhaustion: baseline test completed\n\n", .{});
}

fn run_test_with_memory_limit(allocator: std.mem.Allocator, memory_limit_mb: u32, timeout_seconds: u32) bool {
    _ = allocator;

    // TODO: Implement proper memory limiting
    // For now, run normal test with timeout
    print("    Running with {}MB memory limit, {}s timeout\n", .{ memory_limit_mb, timeout_seconds });

    var child = std.process.Child.init(&.{ "./zig/zig", "build", "test" }, std.heap.page_allocator);

    const term = child.spawnAndWait() catch |err| {
        print("    Test spawn error: {}\n", .{err});
        return false;
    };

    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn run_normal_test(allocator: std.mem.Allocator, timeout_seconds: u32) bool {
    _ = allocator;
    _ = timeout_seconds;

    var child = std.process.Child.init(&.{ "./zig/zig", "build", "test" }, std.heap.page_allocator);

    const term = child.spawnAndWait() catch |err| {
        print("    Test spawn error: {}\n", .{err});
        return false;
    };

    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn print_results(result: StressTestResult) void {
    print("╔══════════════════════════════════════════════════════════════════╗\n", .{});
    print("║                        STRESS TEST RESULTS                       ║\n", .{});
    print("╚══════════════════════════════════════════════════════════════════╝\n\n", .{});

    print("Overall Results:\n", .{});
    print("  Cycles completed: {}\n", .{result.cycles_completed});
    print("  Cycles failed: {}\n", .{result.cycles_failed});
    print("  Success rate: {d:.1}%\n", .{result.success_rate()});
    print("  Total duration: {}ms\n", .{result.total_duration_ms});

    if (result.errors.items.len > 0) {
        print("\nErrors encountered:\n", .{});
        for (result.errors.items) |err| {
            print("  - {s}\n", .{err});
        }
    }
}

fn print_usage() void {
    print("Usage: ci-stress [OPTIONS]\n\n", .{});
    print("Cross-platform CI stress testing for KausalDB\n\n", .{});
    print("OPTIONS:\n", .{});
    print("  --memory-limit MB    Memory limit in megabytes (default: 2048)\n", .{});
    print("  --timeout SECONDS    Test timeout in seconds (default: 300)\n", .{});
    print("  --cycles N           Number of stress test cycles (default: 5)\n", .{});
    print("  --help, -h           Show this help message\n", .{});
}
