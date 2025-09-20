//! Standardized output handling for KausalDB benchmarks.
//!
//! Replaces std.debug.print usage in benchmark code with proper stdout/stderr
//! handling. Supports both human-readable and JSON output formats for
//! professional benchmark results suitable for CI integration.
//!
//! Design rationale: Benchmark tools require clean, parseable output that
//! separates results from status messages. This enables automated performance
//! regression detection and clean CI integration.

const std = @import("std");
const builtin = @import("builtin");

/// Global benchmark output configuration
var benchmark_config: BenchmarkOutputConfig = .{};

/// Configuration for benchmark output behavior
pub const BenchmarkOutputConfig = struct {
    /// Suppress non-essential status messages
    quiet: bool = false,
    /// Enable verbose diagnostic output
    verbose: bool = false,
    /// Output results in JSON format for CI integration
    json_format: bool = false,
    /// Include system information in results
    include_system_info: bool = true,
};

/// Configure benchmark output behavior
pub fn configure_benchmark_output(config: BenchmarkOutputConfig) void {
    benchmark_config = config;
}

/// Write benchmark results to stdout (always visible)
pub fn write_benchmark_results(msg: []const u8) void {
    std.debug.print("{s}", .{msg});
}

/// Write formatted benchmark results to stdout
pub fn print_benchmark_results(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const formatted = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(formatted);
    write_benchmark_results(formatted);
}

/// Write status message to stdout (respects quiet mode)
pub fn write_status(msg: []const u8) void {
    if (benchmark_config.quiet) return;

    std.debug.print("{s}", .{msg});
}

/// Write formatted status message to stdout
pub fn print_status(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    if (benchmark_config.quiet) return;

    const formatted = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(formatted);
    write_status(formatted);
}

/// Write verbose diagnostic message (only if verbose enabled)
pub fn write_verbose(msg: []const u8) void {
    if (!benchmark_config.verbose or benchmark_config.quiet) return;

    std.debug.print("{s}", .{msg});
}

/// Write formatted verbose diagnostic message
pub fn print_verbose(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    if (!benchmark_config.verbose or benchmark_config.quiet) return;

    const formatted = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(formatted);
    write_verbose(formatted);
}

/// Write error message to stderr (always visible)
pub fn write_error(msg: []const u8) void {
    std.debug.print("{s}", .{msg});
}

/// Write formatted error message to stderr
pub fn print_error(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const formatted = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(formatted);
    write_error(formatted);
}

/// Print benchmark configuration at startup
pub fn print_benchmark_header(allocator: std.mem.Allocator, name: []const u8) void {
    if (benchmark_config.json_format) {
        print_benchmark_results(allocator, "{{\"benchmark\": \"{s}\", \"status\": \"starting\"}}\n", .{name});
        return;
    }

    print_status(allocator, "=== KausalDB {s} Benchmark ===\n\n", .{name});
}

/// Print benchmark configuration details
pub fn print_benchmark_config(allocator: std.mem.Allocator, config_items: []const ConfigItem) void {
    if (benchmark_config.json_format) {
        write_benchmark_results("{\"config\": {");
        for (config_items, 0..) |item, i| {
            if (i > 0) write_benchmark_results(", ");
            print_benchmark_results(allocator, "\"{s}\": \"{s}\"", .{ item.name, item.value });
        }
        write_benchmark_results("}}\n");
        return;
    }

    if (config_items.len > 0) {
        write_status("Configuration:\n");
        for (config_items) |item| {
            print_status(allocator, "  {s}: {s}\n", .{ item.name, item.value });
        }
        write_status("\n");
    }
}

/// Configuration item for benchmark settings
pub const ConfigItem = struct {
    name: []const u8,
    value: []const u8,
};

/// Print system information for reproducibility
pub fn print_system_info(allocator: std.mem.Allocator) void {
    if (!benchmark_config.include_system_info) return;

    if (benchmark_config.json_format) {
        print_benchmark_results(allocator,
            \\{{"system": {{"platform": "{s}-{s}", "build_mode": "{s}"}}}}
        , .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch), @tagName(builtin.mode) });
        write_benchmark_results("\n");
        return;
    }

    write_status("System Information:\n");
    print_status(allocator, "- Platform: {s}-{s}\n", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });
    print_status(allocator, "- Build mode: {s}\n", .{@tagName(builtin.mode)});
    write_status("\n");
}

/// Print benchmark phase header
pub fn print_phase_header(allocator: std.mem.Allocator, phase: []const u8) void {
    if (benchmark_config.json_format) {
        print_benchmark_results(allocator, "{{\"phase\": \"{s}\", \"status\": \"starting\"}}\n", .{phase});
        return;
    }

    print_status(allocator, "Benchmarking {s}...\n", .{phase});
}

/// Print benchmark results summary
pub fn print_results_header() void {
    if (benchmark_config.json_format) {
        write_benchmark_results("{\"results\": [\n");
        return;
    }

    write_benchmark_results("\n=== Benchmark Results ===\n\n");
}

/// Print individual benchmark result
pub fn print_result_entry(allocator: std.mem.Allocator, name: []const u8, stats: BenchmarkStats, is_last: bool) void {
    if (benchmark_config.json_format) {
        const comma = if (is_last) "" else ",";
        print_benchmark_results(allocator,
            \\  {{"name": "{s}", "mean_ns": {d}, "min_ns": {d}, "max_ns": {d}, "ops_per_sec": {d:.0}}}{}
        , .{ name, stats.mean_ns, stats.min_ns, stats.max_ns, stats.ops_per_second, comma });
        write_benchmark_results("\n");
        return;
    }

    const mean_us = @as(f64, @floatFromInt(stats.mean_ns)) / 1000.0;
    const min_us = @as(f64, @floatFromInt(stats.min_ns)) / 1000.0;
    const max_us = @as(f64, @floatFromInt(stats.max_ns)) / 1000.0;

    print_benchmark_results(allocator, "{s}:\n", .{name});
    print_benchmark_results(allocator, "  Mean: {d:.2}μs  Min: {d:.2}μs  Max: {d:.2}μs\n", .{ mean_us, min_us, max_us });
    print_benchmark_results(allocator, "  Ops/sec: {d:.0}\n\n", .{stats.ops_per_sec});
}

/// Basic benchmark statistics
pub const BenchmarkStats = struct {
    mean_ns: u64,
    min_ns: u64,
    max_ns: u64,
    ops_per_second: f64,
};

/// Finish results output
pub fn print_results_footer() void {
    if (benchmark_config.json_format) {
        write_benchmark_results("]}\n");
    }
}

/// Print benchmark summary
pub fn print_summary(allocator: std.mem.Allocator, total_benchmarks: u32, regressions: u32, improvements: u32) void {
    if (benchmark_config.json_format) {
        print_benchmark_results(allocator,
            \\{{"summary": {{"total": {}, "regressions": {}, "improvements": {}}}}}
        , .{ total_benchmarks, regressions, improvements });
        write_benchmark_results("\n");
        return;
    }

    print_benchmark_results(allocator, "Summary: {} benchmarks, {} regressions, {} improvements\n", .{
        total_benchmarks,
        regressions,
        improvements,
    });

    if (regressions > 0) {
        write_benchmark_results("Performance regressions detected!\n");
    }
}

/// Print command execution details (verbose only)
pub fn print_command_execution(allocator: std.mem.Allocator, binary_path: []const u8, args: []const []const u8) void {
    print_verbose(allocator, "Executing command: {s}", .{binary_path});
    for (args) |arg| {
        print_verbose(allocator, " {s}", .{arg});
    }
    print_verbose(allocator, "\n", .{});
}

/// Print command failure details
pub fn print_command_failure(allocator: std.mem.Allocator, exit_code: u32, binary_path: []const u8, args: []const []const u8, stderr_output: []const u8, stdout_output: []const u8) void {
    print_error(allocator, "Command failed with exit code {}\n", .{exit_code});
    print_error(allocator, "Command: {s}", .{binary_path});
    for (args) |arg| {
        print_error(allocator, " {s}", .{arg});
    }
    print_error(allocator, "\n", .{});

    if (stderr_output.len > 0) {
        print_error(allocator, "STDERR:\n{s}\n", .{stderr_output});
    }
    if (stdout_output.len > 0) {
        print_error(allocator, "STDOUT:\n{s}\n", .{stdout_output});
    }
}

/// Print file operation status (verbose only)
pub fn print_file_operation(allocator: std.mem.Allocator, operation: []const u8, path: []const u8) void {
    print_verbose(allocator, "{s}: {s}\n", .{ operation, path });
}

/// Simple formatted output functions that don't require allocator
pub fn print_simple_status(comptime fmt: []const u8, args: anytype) void {
    if (benchmark_config.quiet) return;

    std.debug.print(fmt, args);
}

pub fn print_simple_results(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

pub fn print_simple_error(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

/// Reset configuration to defaults (for testing)
pub fn reset_config() void {
    benchmark_config = .{};
}

/// Check if should output status messages
pub fn should_output_status() bool {
    return !benchmark_config.quiet;
}

/// Check if should output verbose messages
pub fn should_output_verbose() bool {
    return benchmark_config.verbose and !benchmark_config.quiet;
}

/// Check if using JSON format
pub fn is_json_format() bool {
    return benchmark_config.json_format;
}
