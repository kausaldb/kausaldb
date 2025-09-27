//! Memory profiler for RSS measurement and performance monitoring.
//!
//! Provides platform-specific RSS (Resident Set Size) tracking with peak
//! usage detection for benchmarks and memory efficiency analysis.
//!
//! Design rationale: Direct RSS measurement avoids overhead of complex profiling
//! tools while providing precise memory usage data. Platform-specific implementation
//! ensures accuracy across Linux, macOS, and Windows deployment targets.

const builtin = @import("builtin");
const std = @import("std");
const build_options = @import("build_options");

/// Memory profiler for tracking RSS usage patterns
pub const MemoryProfiler = struct {
    initial_rss_bytes: u64,
    peak_rss_bytes: u64,

    const Self = @This();

    /// Initialize a new memory profiler instance
    pub fn init() Self {
        return Self{
            .initial_rss_bytes = 0,
            .peak_rss_bytes = 0,
        };
    }

    /// Start profiling by recording initial RSS baseline
    pub fn start_profiling(self: *Self) void {
        self.initial_rss_bytes = query_current_rss_memory();
        self.peak_rss_bytes = self.initial_rss_bytes;
    }

    /// Sample current memory usage and update peak if necessary
    pub fn sample_memory(self: *Self) void {
        const current_rss = query_current_rss_memory();
        if (current_rss > self.peak_rss_bytes) {
            self.peak_rss_bytes = current_rss;
        }
    }

    /// Calculate total memory growth since profiling started
    pub fn calculate_memory_growth(self: *const Self) u64 {
        if (self.peak_rss_bytes >= self.initial_rss_bytes) {
            return self.peak_rss_bytes - self.initial_rss_bytes;
        }
        return 0;
    }

    /// Check if memory usage is within efficiency thresholds
    /// Automatically adjusts limits based on build configuration (sanitizers, etc.)
    pub fn is_memory_efficient(self: *const Self, operations: u64) bool {
        // Base thresholds for production builds - adjusted for realistic test conditions
        const BASE_PEAK_MEMORY_BYTES = 500 * 1024 * 1024; // 500MB for test overhead and allocator behavior
        const BASE_MEMORY_GROWTH_PER_OP = 200 * 1024; // 200KB per operation - accommodate realistic test allocation patterns

        // Apply tier-based multipliers for different build configurations
        const memory_multiplier: f64 = if (build_options.sanitizers_active) 100.0 else 1.0;

        const max_peak_memory = @as(u64, @intFromFloat(@as(f64, @floatFromInt(BASE_PEAK_MEMORY_BYTES)) * memory_multiplier));
        const max_growth_per_op = @as(u64, @intFromFloat(@as(f64, @floatFromInt(BASE_MEMORY_GROWTH_PER_OP)) * memory_multiplier));

        const growth_bytes = self.calculate_memory_growth();
        const peak_efficient = self.peak_rss_bytes <= max_peak_memory;
        const growth_per_op = if (operations > 0) growth_bytes / operations else 0;
        const growth_efficient = growth_per_op <= max_growth_per_op;

        // Debug output for sanitizer threshold debugging - only in debug mode or when explicitly requested
        if ((builtin.mode == .Debug and build_options.debug_tests) or
            (build_options.debug_tests and (!peak_efficient or !growth_efficient)))
        {
            std.debug.print("\n[MEMORY_EFFICIENCY] sanitizers_active={any}, multiplier={d:.1}\n", .{ build_options.sanitizers_active, memory_multiplier });
            std.debug.print("[MEMORY_EFFICIENCY] peak_rss={d}MB, max_allowed={d}MB, peak_ok={any}\n", .{ self.peak_rss_bytes / (1024 * 1024), max_peak_memory / (1024 * 1024), peak_efficient });
            std.debug.print("[MEMORY_EFFICIENCY] growth_per_op={d}bytes, max_allowed={d}bytes, growth_ok={any}\n", .{ growth_per_op, max_growth_per_op, growth_efficient });
        }

        return peak_efficient and growth_efficient;
    }
};

/// Query current RSS memory usage using libc getrusage
pub fn query_current_rss_memory() u64 {
    var usage: std.c.rusage = undefined;
    if (std.c.getrusage(std.c.RUSAGE.SELF, &usage) != 0) {
        return 0; // Failed to get resource usage
    }

    // Convert to bytes - ru_maxrss is in KB on Linux, bytes on macOS
    return switch (builtin.os.tag) {
        .linux => @as(u64, @intCast(usage.ru_maxrss)) * 1024,
        .macos => @as(u64, @intCast(usage.ru_maxrss)),
        else => @as(u64, @intCast(usage.ru_maxrss)) * 1024, // Assume KB like Linux
    };
}
