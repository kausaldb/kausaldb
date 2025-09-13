//! KausalDB Fuzzing Framework
//!
//! Clean component dispatcher for systematic robustness testing.
//! Delegates all fuzzing implementation to component modules while
//! providing shared infrastructure for crash detection and reporting.

const std = @import("std");
const builtin = @import("builtin");
const internal = @import("internal");
const build_options = @import("build_options");

const Allocator = std.mem.Allocator;

/// Target selection for component fuzzing
const Target = enum {
    storage,
    logic,
    query,
    ingestion,
    all,

    fn from_string(str: []const u8) ?Target {
        return std.meta.stringToEnum(Target, str);
    }
};

/// Fuzzing configuration
const FuzzConfig = struct {
    iterations: u32 = 10000,
    timeout_ms: u32 = 1000,
    corpus_dir: []const u8 = "fuzz-corpus",
    seed: u64,
    verbose: bool = false,
    save_crashes: bool = true,
};

/// Fuzzing statistics for reporting
const FuzzStats = struct {
    iterations: u64 = 0,
    crashes: u64 = 0,
    unique_crashes: u64 = 0,
    executions_per_second: f64 = 0,
    total_time_ms: u64 = 0,

    fn print(self: FuzzStats) void {
        std.debug.print("=== Fuzzing Summary ===\n", .{});
        std.debug.print("Iterations: {}\n", .{self.iterations});
        std.debug.print("Crashes: {}\n", .{self.crashes});
        std.debug.print("Unique crashes: {}\n", .{self.unique_crashes});
        std.debug.print("Exec/sec: {d:.1}\n", .{self.executions_per_second});
        std.debug.print("Total time: {}ms\n", .{self.total_time_ms});

        if (self.crashes > 0) {
            std.debug.print("Crashes found - check corpus for details\n", .{});
        } else {
            std.debug.print("No crashes detected\n", .{});
        }
    }
};

/// Crash entry for corpus management
const CrashEntry = struct {
    input: []const u8,
    error_type: []const u8,
    iteration: u64,

    fn save_to_disk(self: CrashEntry, allocator: Allocator, corpus_dir: []const u8) !void {
        // Ensure corpus directory exists
        std.fs.cwd().makePath(corpus_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Generate crash filename
        const crash_path = try std.fmt.allocPrint(
            allocator,
            "{s}/crash_{}_{x}.bin",
            .{ corpus_dir, self.iteration, std.hash.Wyhash.hash(0, self.input) },
        );
        defer allocator.free(crash_path);

        // Save crash input
        const file = try std.fs.cwd().createFile(crash_path, .{});
        defer file.close();
        try file.writeAll(self.input);

        std.debug.print("Crash saved: {s}\n", .{crash_path});
    }
};

/// Shared fuzzer infrastructure for component modules
pub const Fuzzer = struct {
    allocator: Allocator,
    config: FuzzConfig,
    stats: FuzzStats,
    crashes: std.array_list.Managed(CrashEntry),
    random: std.Random,
    timer: std.time.Timer,

    pub fn init(allocator: Allocator, config: FuzzConfig) !Fuzzer {
        var prng = std.Random.DefaultPrng.init(config.seed);

        return Fuzzer{
            .allocator = allocator,
            .config = config,
            .stats = .{},
            .crashes = std.array_list.Managed(CrashEntry).init(allocator),
            .random = prng.random(),
            .timer = try std.time.Timer.start(),
        };
    }

    pub fn deinit(self: *Fuzzer) void {
        // Clean up crash entries
        for (self.crashes.items) |crash| {
            self.allocator.free(crash.input);
            self.allocator.free(crash.error_type);
        }
        self.crashes.deinit();
    }

    /// Generate random input for fuzzing
    pub fn generate_input(self: *Fuzzer) ![]u8 {
        const size = self.random.intRangeAtMost(usize, 1, 4096);
        const input = try self.allocator.alloc(u8, size);
        self.random.bytes(input);
        return input;
    }

    /// Handle a crash during fuzzing
    pub fn handle_crash(self: *Fuzzer, input: []const u8, err: anyerror) !void {
        self.stats.crashes += 1;

        const error_name = @errorName(err);

        // Check if this is a unique crash type
        var is_unique = true;
        for (self.crashes.items) |existing_crash| {
            if (std.mem.eql(u8, existing_crash.error_type, error_name)) {
                is_unique = false;
                break;
            }
        }

        if (is_unique) {
            self.stats.unique_crashes += 1;
        }

        // Save crash entry
        const crash = CrashEntry{
            .input = try self.allocator.dupe(u8, input),
            .error_type = try self.allocator.dupe(u8, error_name),
            .iteration = self.stats.iterations,
        };

        try self.crashes.append(crash);

        if (self.config.save_crashes) {
            crash.save_to_disk(self.allocator, self.config.corpus_dir) catch |save_err| {
                std.debug.print("Failed to save crash: {}\n", .{save_err});
            };
        }

        if (self.config.verbose) {
            std.debug.print("Crash #{}: {s} (iteration {})\n", .{
                self.stats.crashes,
                error_name,
                self.stats.iterations,
            });
        }
    }

    /// Update iteration statistics
    pub fn record_iteration(self: *Fuzzer) void {
        self.stats.iterations += 1;

        // Update exec/sec every 1000 iterations
        if (self.stats.iterations % 1000 == 0) {
            const elapsed_ms = self.timer.read() / std.time.ns_per_ms;
            self.stats.total_time_ms = elapsed_ms;
            if (elapsed_ms > 0) {
                self.stats.executions_per_second = @as(f64, @floatFromInt(self.stats.iterations * 1000)) / @as(f64, @floatFromInt(elapsed_ms));
            }

            if (self.config.verbose) {
                std.debug.print("Iteration {}: {d:.1} exec/sec, {} crashes\n", .{
                    self.stats.iterations,
                    self.stats.executions_per_second,
                    self.stats.crashes,
                });
            }
        }
    }
};

/// Parse target from command line arguments
fn parse_target_arg(args: []const []const u8) Target {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) continue;
        if (Target.from_string(arg)) |target| {
            return target;
        }
    }
    return .all;
}

/// Print usage information
fn print_usage() void {
    std.debug.print("KausalDB Fuzzing Framework\n\n", .{});
    std.debug.print("Usage: fuzz [target] [options]\n\n", .{});
    std.debug.print("Targets:\n", .{});
    std.debug.print("  storage     Fuzz storage engine operations (deserialization)\n", .{});
    std.debug.print("  logic       Fuzz system logic with valid operations\n", .{});
    std.debug.print("  query       Fuzz query engine (future)\n", .{});
    std.debug.print("  ingestion   Fuzz code ingestion (future)\n", .{});
    std.debug.print("  all         Fuzz all components (default)\n\n", .{});
    std.debug.print("Options:\n", .{});
    std.debug.print("  --iterations N   Number of fuzzing iterations (default: 10000)\n", .{});
    std.debug.print("  --timeout N      Timeout per test in milliseconds (default: 1000)\n", .{});
    std.debug.print("  --corpus DIR     Directory for crash corpus (default: fuzz-corpus)\n", .{});
    std.debug.print("  --seed N         Deterministic seed (default: time-based)\n", .{});
    std.debug.print("  --verbose        Enable verbose output\n", .{});
    std.debug.print("  --no-save        Don't save crash inputs to corpus\n", .{});
    std.debug.print("  --help           Show this help\n\n", .{});
    std.debug.print("Examples:\n", .{});
    std.debug.print("  fuzz storage --iterations 50000 --verbose\n", .{});
    std.debug.print("  fuzz all --seed 0xDEADBEEF --corpus my-crashes\n", .{});
}

/// Main fuzzing entry point
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Handle help flag
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            print_usage();
            return;
        }
    }

    const target = parse_target_arg(args);
    const config = FuzzConfig{
        .iterations = build_options.fuzz_iterations,
        .corpus_dir = build_options.fuzz_corpus,
        .seed = @as(u64, @intCast(std.time.timestamp())) ^ 0xDEADBEEF,
        .save_crashes = true,
    };

    std.debug.print("KausalDB Fuzzing Framework\n", .{});
    std.debug.print("Target: {s}\n", .{@tagName(target)});
    std.debug.print("Iterations: {}\n", .{config.iterations});
    std.debug.print("Seed: 0x{X}\n", .{config.seed});
    std.debug.print("Corpus: {s}\n\n", .{config.corpus_dir});

    var fuzzer = try Fuzzer.init(allocator, config);
    defer fuzzer.deinit();

    const start_time = std.time.milliTimestamp();

    switch (target) {
        .storage => {
            const storage_fuzz = @import("storage.zig");
            try storage_fuzz.run_fuzzing(&fuzzer);
        },
        .logic => {
            const logic_fuzz = @import("logic.zig");
            try logic_fuzz.run_fuzzing(&fuzzer);
        },
        .query => {
            std.debug.print("Query fuzzing not yet implemented\n", .{});
            return;
        },
        .ingestion => {
            std.debug.print("Ingestion fuzzing not yet implemented\n", .{});
            return;
        },
        .all => {
            std.debug.print("Running storage fuzzing...\n", .{});
            const storage_fuzz = @import("storage.zig");
            try storage_fuzz.run_fuzzing(&fuzzer);

            std.debug.print("\nRunning logic fuzzing...\n", .{});
            const logic_fuzz = @import("logic.zig");
            try logic_fuzz.run_fuzzing(&fuzzer);

            // Add other components as they're implemented
            std.debug.print("\nOther components not yet implemented\n", .{});
        },
    }

    const end_time = std.time.milliTimestamp();
    fuzzer.stats.total_time_ms = @intCast(end_time - start_time);

    if (fuzzer.stats.total_time_ms > 0) {
        fuzzer.stats.executions_per_second = @as(f64, @floatFromInt(fuzzer.stats.iterations * 1000)) / @as(f64, @floatFromInt(fuzzer.stats.total_time_ms));
    }

    fuzzer.stats.print();

    if (fuzzer.stats.crashes > 0) {
        std.process.exit(1);
    }
}
