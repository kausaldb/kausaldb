//! Fuzzing framework for KausalDB storage and query engines.
//!
//! Combines coverage-guided fuzzing, property-based testing, and deterministic
//! simulation to find bugs in parsing, logic, and state management.
//!
//! Every crash is reproducible using seeds for deterministic debugging.
//! Includes input minimization and crash categorization.

const builtin = @import("builtin");
const std = @import("std");

const build_options = @import("build_options");

const Allocator = std.mem.Allocator;

pub const std_options: std.Options = .{
    .log_level = @enumFromInt(@intFromEnum(build_options.log_level)),
};

/// Fuzzing target categories
const Target = enum {
    // Parse fuzzing - find crashes in deserialization
    storage_parse,
    network_parse,
    cli_parse,

    // Logic fuzzing - find invariant violations
    storage_logic,
    query_logic,
    graph_logic,

    // Property testing - verify system properties
    durability,
    consistency,
    linearizability,

    // Combined testing
    all_parse,
    all_logic,
    all_properties,
    all,

    fn parse_from_string(str: []const u8) ?Target {
        return std.meta.stringToEnum(Target, str);
    }
};

/// Fuzzing configuration
const FuzzConfig = struct {
    iterations: u32 = 10_000,
    timeout_ms: u32 = 100, // Per-operation timeout
    corpus_dir: []const u8 = "fuzz-corpus",
    seed: u64,
    verbose: bool = false,
    save_crashes: bool = true,
    minimize_crashes: bool = true,
    max_input_size: usize = 64 * 1024,
    track_coverage: bool = true,
    coverage_dir: []const u8 = "fuzz-coverage",
};

/// Fuzzing statistics
const FuzzStats = struct {
    iterations_executed: u64 = 0,
    total_crashes: u64 = 0,
    unique_crashes: u64 = 0,
    coverage_edges: u64 = 0,
    peak_memory_bytes: u64 = 0,
    executions_per_second: f64 = 0,
    total_time_ms: u64 = 0,
    parse_crashes: u64 = 0,
    logic_crashes: u64 = 0,
    assertion_failures: u64 = 0,
    memory_errors: u64 = 0,
    timeout_crashes: u64 = 0,

    fn print(self: FuzzStats) void {
        std.debug.print("\nFuzzing Report \n", .{});
        std.debug.print("Total iterations: {}\n", .{self.iterations_executed});
        std.debug.print("Execution rate: {d:.1} ops/sec\n", .{self.executions_per_second});
        std.debug.print("Coverage edges: {}\n", .{self.coverage_edges});
        std.debug.print("Peak memory: {} MB\n", .{self.peak_memory_bytes / (1024 * 1024)});
        std.debug.print("\n", .{});

        std.debug.print("Crashes Found \n", .{});
        std.debug.print("Total crashes: {}\n", .{self.total_crashes});
        std.debug.print("Unique crashes: {}\n", .{self.unique_crashes});
        if (self.total_crashes > 0) {
            std.debug.print("  Parse errors: {}\n", .{self.parse_crashes});
            std.debug.print("  Logic errors: {}\n", .{self.logic_crashes});
            std.debug.print("  Assertions: {}\n", .{self.assertion_failures});
            std.debug.print("  Memory errors: {}\n", .{self.memory_errors});
            std.debug.print("  Timeouts: {}\n", .{self.timeout_crashes});
        }
        std.debug.print("\n", .{});

        const status = if (self.unique_crashes > 0) "BUGS FOUND" else "No crashes";
        std.debug.print("Status: {s}\n", .{status});

        if (self.unique_crashes > 0) {
            std.debug.print("Check corpus directory for reproducible test cases\n", .{});
        }
    }
};

/// Crash information for corpus management
const CrashInfo = struct {
    input: []const u8,
    error_type: CrashType,
    error_name: []const u8,
    stack_hash: u64, // For deduplication
    iteration: u64,
    minimized: bool = false,

    const CrashType = enum {
        parse_error,
        logic_error,
        assertion_failure,
        memory_error,
        timeout,
        unknown,
    };

    fn categorize_error(err: anyerror) CrashType {
        const name = @errorName(err);

        // Categorize based on error name patterns
        if (std.mem.indexOf(u8, name, "Parse") != null or
            std.mem.indexOf(u8, name, "Invalid") != null or
            std.mem.indexOf(u8, name, "Corrupt") != null)
        {
            return .parse_error;
        } else if (std.mem.indexOf(u8, name, "Assert") != null or
            std.mem.indexOf(u8, name, "Panic") != null)
        {
            return .assertion_failure;
        } else if (std.mem.indexOf(u8, name, "OutOfMemory") != null or
            std.mem.indexOf(u8, name, "Overflow") != null)
        {
            return .memory_error;
        } else if (std.mem.indexOf(u8, name, "Invariant") != null or
            std.mem.indexOf(u8, name, "Consistency") != null)
        {
            return .logic_error;
        }

        return .unknown;
    }

    fn save_to_disk(self: CrashInfo, allocator: Allocator, corpus_dir: []const u8) !void {
        try std.fs.cwd().makePath(corpus_dir);

        // Create descriptive filename
        const filename = try std.fmt.allocPrint(
            allocator,
            "{s}/crash_{s}_{x}_{}.bin",
            .{ corpus_dir, @tagName(self.error_type), self.stack_hash, self.iteration },
        );
        defer allocator.free(filename);

        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();

        // Write crash metadata as header
        const header = try std.fmt.allocPrint(allocator, "# KausalDB Crash\n" ++
            "# Type: {s}\n" ++
            "# Error: {s}\n" ++
            "# Iteration: {}\n" ++
            "# Hash: 0x{x}\n" ++
            "# Size: {} bytes\n" ++
            "# ---\n", .{ @tagName(self.error_type), self.error_name, self.iteration, self.stack_hash, self.input.len });
        defer allocator.free(header);
        try file.writeAll(header);
        try file.writeAll(self.input);

        std.debug.print("[CRASH SAVED] {s}\n", .{filename});
    }
};

/// Coverage tracking
const CoverageTracker = struct {
    edges_seen: std.AutoHashMap(u64, void),
    new_coverage: bool = false,

    fn init(allocator: Allocator) CoverageTracker {
        return .{
            .edges_seen = std.AutoHashMap(u64, void).init(allocator),
        };
    }

    fn deinit(self: *CoverageTracker) void {
        self.edges_seen.deinit();
    }

    fn record_edge(self: *CoverageTracker, from: usize, to: usize) !void {
        const edge = (@as(u64, @intCast(from)) << 32) | @as(u64, @intCast(to));
        const result = try self.edges_seen.getOrPut(edge);
        self.new_coverage = !result.found_existing;
    }

    fn edge_count(self: *const CoverageTracker) u64 {
        return self.edges_seen.count();
    }
};

/// Main fuzzer engine
pub const Fuzzer = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    config: FuzzConfig,
    stats: FuzzStats,
    crashes: std.ArrayList(CrashInfo),
    prng: std.Random.DefaultPrng,
    timer: std.time.Timer,
    coverage: CoverageTracker,
    seen_crashes: std.AutoHashMap(u64, void),

    pub fn init(allocator: Allocator, config: FuzzConfig) !Fuzzer {
        const prng = std.Random.DefaultPrng.init(config.seed);

        return Fuzzer{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .config = config,
            .stats = .{},
            .crashes = std.ArrayList(CrashInfo){},
            .prng = prng,
            .timer = try std.time.Timer.start(),
            .coverage = CoverageTracker.init(allocator),
            .seen_crashes = std.AutoHashMap(u64, void).init(allocator),
        };
    }

    pub fn deinit(self: *Fuzzer) void {
        for (self.crashes.items) |crash| {
            if (self.config.save_crashes) {
                crash.save_to_disk(self.allocator, self.config.corpus_dir) catch |err| {
                    std.debug.print("Failed to save crash: {}\n", .{err});
                };
            }
            self.allocator.free(crash.input);
            self.allocator.free(crash.error_name);
        }

        self.crashes.deinit(self.allocator);
        self.coverage.deinit();
        self.seen_crashes.deinit();
        self.arena.deinit();
    }

    /// Generate structured input for fuzzing
    pub fn generate_input(self: *Fuzzer, size_hint: usize) ![]u8 {
        const size = self.prng.random().uintAtMost(usize, @min(size_hint, self.config.max_input_size));

        const input = try self.arena.allocator().alloc(u8, size);

        const strategy = self.prng.random().uintLessThan(u8, 100);
        if (strategy < 10) {
            self.prng.random().bytes(input);
        } else if (strategy < 30) {
            for (input) |*byte| {
                if (self.prng.random().uintLessThan(u8, 100) < 80) {
                    byte.* = 32 + self.prng.random().uintLessThan(u8, 95);
                } else {
                    byte.* = self.prng.random().int(u8);
                }
            }
        } else if (strategy < 50) {
            var i: usize = 0;
            while (i < input.len) : (i += 1) {
                if (i % 4 == 0 and i + 4 <= input.len) {
                    const len = self.prng.random().int(u32);
                    std.mem.writeInt(u32, input[i..][0..4], len, .little);
                    i += 3;
                } else {
                    input[i] = self.prng.random().int(u8);
                }
            }
        } else {
            self.mutate_input(input);
        }

        return input;
    }

    fn mutate_input(self: *Fuzzer, input: []u8) void {
        const mutations = self.prng.random().uintLessThan(u8, 10) + 1;

        for (0..mutations) |_| {
            if (input.len == 0) break;

            const mutation_type = self.prng.random().uintLessThan(u8, 5);
            const pos = self.prng.random().uintLessThan(usize, input.len);

            switch (mutation_type) {
                0 => {
                    input[pos] ^= @as(u8, 1) << @intCast(self.prng.random().uintLessThan(u4, 8));
                },
                1 => {
                    input[pos] = self.prng.random().int(u8);
                },
                2 => {
                    const interesting = [_]u8{ 0, 1, 255, 127, 128 };
                    input[pos] = interesting[self.prng.random().uintLessThan(usize, interesting.len)];
                },
                3 => {
                    const delta = self.prng.random().intRangeAtMost(i8, -10, 10);
                    input[pos] = @truncate(@as(u16, @bitCast(@as(i16, input[pos]) + delta)));
                },
                4 => {
                    if (input.len > 16) {
                        const src = self.prng.random().uintLessThan(usize, input.len - 8);
                        const dst = self.prng.random().uintLessThan(usize, input.len - 8);
                        if (dst + 8 <= src or src + 8 <= dst) {
                            @memcpy(input[dst..][0..8], input[src..][0..8]);
                        }
                    }
                },
                else => {},
            }
        }
    }

    /// Check if error is expected fuzzing behavior, not a bug
    fn is_expected_error(err: anyerror) bool {
        return switch (err) {
            // File system errors are expected when fuzzing with random paths
            error.FileNotFound,
            error.PathNotFound,
            error.AccessDenied,
            error.NotDir,
            error.IsDir,
            // Parse errors are expected when fuzzing with random input
            error.InvalidUtf8,
            error.UnexpectedEndOfFile,
            error.InvalidFormat,
            error.InvalidData,
            // Resource errors are expected under fuzzing stress
            error.OutOfMemory,
            => true,
            else => false,
        };
    }

    /// Handle a crash with deduplication and categorization
    pub fn handle_crash(self: *Fuzzer, input: []const u8, err: anyerror) !void {
        // Filter out expected errors - these are normal fuzzing results, not bugs
        if (is_expected_error(err)) return;

        const stack_hash = self.hash_stack_trace();

        // Deduplicate crashes
        const result = try self.seen_crashes.getOrPut(stack_hash);
        if (!result.found_existing) {
            self.stats.unique_crashes += 1;

            // Minimize crash if configured
            const minimized_input = if (self.config.minimize_crashes)
                try self.minimize_crash(input, err)
            else
                try self.allocator.dupe(u8, input);

            const crash = CrashInfo{
                .input = minimized_input,
                .error_type = CrashInfo.categorize_error(err),
                .error_name = try self.allocator.dupe(u8, @errorName(err)),
                .stack_hash = stack_hash,
                .iteration = self.stats.iterations_executed,
                .minimized = self.config.minimize_crashes,
            };

            try self.crashes.append(self.allocator, crash);

            // Update category stats
            switch (crash.error_type) {
                .parse_error => self.stats.parse_crashes += 1,
                .logic_error => self.stats.logic_crashes += 1,
                .assertion_failure => self.stats.assertion_failures += 1,
                .memory_error => self.stats.memory_errors += 1,
                .timeout => self.stats.timeout_crashes += 1,
                .unknown => {},
            }

            if (self.config.verbose) {
                std.debug.print("[NEW CRASH] {s} at iteration {} (hash: 0x{x})\n", .{
                    @errorName(err),
                    self.stats.iterations_executed,
                    stack_hash,
                });
            }
        }

        self.stats.total_crashes += 1;
    }

    fn hash_stack_trace(self: *Fuzzer) u64 {
        // Simple hash based on current random state and iteration
        // In production, would capture actual stack trace
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&self.stats.iterations_executed));
        hasher.update(std.mem.asBytes(&self.prng.s));
        return hasher.final();
    }

    fn minimize_crash(self: *Fuzzer, input: []const u8, _: anyerror) ![]u8 {
        // Simple minimization: try removing chunks
        var minimized = try self.allocator.dupe(u8, input);
        defer self.allocator.free(minimized);

        var chunk_size = input.len / 2;
        while (chunk_size > 0) : (chunk_size /= 2) {
            var offset: usize = 0;
            while (offset + chunk_size <= minimized.len) {
                // Try removing this chunk
                const new_input = try self.allocator.alloc(u8, minimized.len - chunk_size);
                @memcpy(new_input[0..offset], minimized[0..offset]);
                @memcpy(new_input[offset..], minimized[offset + chunk_size ..]);

                // Test if it still crashes
                // Note: This would need actual target testing
                // Placeholder for actual target testing

                self.allocator.free(new_input);
                offset += chunk_size;
            }
        }

        return self.allocator.dupe(u8, minimized);
    }

    pub fn record_iteration(self: *Fuzzer) void {
        self.stats.iterations_executed += 1;

        // Update coverage stats
        if (self.config.track_coverage) {
            self.stats.coverage_edges = self.coverage.edge_count();
        }

        // Update performance stats periodically
        if (self.stats.iterations_executed % 1000 == 0) {
            const elapsed_ms = self.timer.read() / std.time.ns_per_ms;
            self.stats.total_time_ms = elapsed_ms;

            if (elapsed_ms > 0) {
                self.stats.executions_per_second = @as(f64, @floatFromInt(self.stats.iterations_executed * 1000)) /
                    @as(f64, @floatFromInt(elapsed_ms));
            }

            // Update peak memory
            if (builtin.os.tag == .linux) {
                // Would read from /proc/self/status
            }

            if (self.config.verbose and self.stats.iterations_executed % 10000 == 0) {
                std.debug.print("[{}] {d:.1} exec/sec | {} edges | {} crashes\n", .{
                    self.stats.iterations_executed,
                    self.stats.executions_per_second,
                    self.stats.coverage_edges,
                    self.stats.unique_crashes,
                });
            }
        }

        // Reset arena periodically to prevent memory growth
        if (self.stats.iterations_executed % 100 == 0) {
            _ = self.arena.reset(.retain_capacity);
        }
    }

    pub fn should_continue(self: *const Fuzzer) bool {
        return self.stats.iterations_executed < self.config.iterations;
    }
};

/// Parse command line arguments
fn parse_config(args: []const []const u8) !struct { target: Target, config: FuzzConfig } {
    var config = FuzzConfig{
        .iterations = build_options.fuzz_iterations,
        .corpus_dir = build_options.fuzz_corpus,
        .seed = @as(u64, @intCast(std.time.timestamp())),
        .verbose = false,
        .save_crashes = true,
    };

    var target: Target = .all;

    var i: usize = 1; // Skip program name
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--iterations") or std.mem.eql(u8, arg, "-i")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            config.iterations = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            config.timeout_ms = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--corpus")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            config.corpus_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--seed")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            config.seed = try std.fmt.parseInt(u64, args[i], 0);
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            config.verbose = true;
        } else if (std.mem.eql(u8, arg, "--no-save")) {
            config.save_crashes = false;
        } else if (std.mem.eql(u8, arg, "--no-minimize")) {
            config.minimize_crashes = false;
        } else if (std.mem.eql(u8, arg, "--no-coverage")) {
            config.track_coverage = false;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            print_usage();
            std.process.exit(0);
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (Target.parse_from_string(arg)) |t| {
                target = t;
            } else {
                std.debug.print("Unknown target: {s}\n", .{arg});
                return error.InvalidTarget;
            }
        }
    }

    return .{ .target = target, .config = config };
}

fn print_usage() void {
    std.debug.print(
        \\KausalDB Fuzzing Framework
        \\
        \\Usage: fuzz [target] [options]
        \\
        \\Targets:
        \\  storage_parse      Fuzz storage deserialization
        \\  network_parse      Fuzz network protocol parsing
        \\  cli_parse          Fuzz CLI argument parsing
        \\  storage_logic      Fuzz storage engine logic
        \\  query_logic        Fuzz query engine operations
        \\  graph_logic        Fuzz graph traversal algorithms
        \\  durability         Test durability properties
        \\  consistency        Test consistency properties
        \\  linearizability    Test linearizability properties
        \\  all_parse          Run all parse fuzzers
        \\  all_logic          Run all logic fuzzers
        \\  all_properties     Run all property tests
        \\  all                Run everything (default)
        \\
        \\Options:
        \\  -i, --iterations N    Number of iterations (default: 10000)
        \\  --timeout N           Timeout per operation in ms (default: 100)
        \\  --corpus DIR          Corpus directory (default: fuzz-corpus)
        \\  --seed N              Random seed for reproducibility
        \\  -v, --verbose         Enable verbose output
        \\  --no-save            Don't save crashes to corpus
        \\  --no-minimize        Don't minimize crash inputs
        \\  --no-coverage        Disable coverage tracking
        \\  -h, --help           Show this help
        \\
        \\Examples:
        \\  fuzz storage_parse --iterations 100000 --verbose
        \\  fuzz all --seed 0xDEADBEEF --corpus crashes
        \\  fuzz durability --timeout 1000
        \\
        \\To reproduce a crash:
        \\  fuzz [target] --seed [seed_from_crash] --iterations 1
        \\
    , .{});
}

/// Dispatch to appropriate fuzzing modules
fn run_target(fuzzer: *Fuzzer, target: Target) !void {
    switch (target) {
        .storage_parse => {
            const storage = @import("storage.zig");
            try storage.run_parse_fuzzing(fuzzer);
        },
        .network_parse => {
            const network = @import("network_protocol.zig");
            try network.run_fuzzing(fuzzer);
        },
        .cli_parse => {
            const cli = @import("cli_parser_fuzz.zig");
            try cli.run_fuzzing(fuzzer);
        },
        .storage_logic => {
            const storage = @import("storage.zig");
            try storage.run_logic_fuzzing(fuzzer);
        },
        .query_logic => {
            const query = @import("query.zig");
            try query.run_logic_fuzzing(fuzzer);
        },
        .graph_logic => {
            const graph = @import("graph_traversal.zig");
            try graph.run_logic_fuzzing(fuzzer);
        },
        .durability => {
            const props = @import("logic.zig");
            try props.run_durability_testing(fuzzer);
        },
        .consistency => {
            const props = @import("logic.zig");
            try props.run_consistency_testing(fuzzer);
        },
        .linearizability => {
            const props = @import("logic.zig");
            try props.run_linearizability_testing(fuzzer);
        },
        .all_parse => {
            std.debug.print("Parse Fuzzing \n", .{});
            try run_target(fuzzer, .storage_parse);
            try run_target(fuzzer, .network_parse);
            try run_target(fuzzer, .cli_parse);
        },
        .all_logic => {
            std.debug.print("Logic Fuzzing \n", .{});
            try run_target(fuzzer, .storage_logic);
            try run_target(fuzzer, .query_logic);
            try run_target(fuzzer, .graph_logic);
        },
        .all_properties => {
            std.debug.print("Property Testing \n", .{});
            try run_target(fuzzer, .durability);
            try run_target(fuzzer, .consistency);
            try run_target(fuzzer, .linearizability);
        },
        .all => {
            try run_target(fuzzer, .all_parse);
            try run_target(fuzzer, .all_logic);
            try run_target(fuzzer, .all_properties);
        },
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
        .retain_metadata = true,
    }){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Memory leak detected in fuzzer!\n", .{});
        }
    }
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const parsed = parse_config(args) catch |err| {
        std.debug.print("Error parsing arguments: {}\n", .{err});
        print_usage();
        return err;
    };

    std.debug.print(
        \\Target: {s}
        \\Iterations: {}
        \\Seed: 0x{X:0>16}
        \\Corpus: {s}
        \\
    , .{
        @tagName(parsed.target),
        parsed.config.iterations,
        parsed.config.seed,
        parsed.config.corpus_dir,
    });

    var fuzzer = try Fuzzer.init(allocator, parsed.config);
    defer fuzzer.deinit();

    const start_time = std.time.milliTimestamp();

    try run_target(&fuzzer, parsed.target);

    const end_time = std.time.milliTimestamp();
    fuzzer.stats.total_time_ms = @intCast(end_time - start_time);

    if (fuzzer.stats.total_time_ms > 0) {
        fuzzer.stats.executions_per_second =
            @as(f64, @floatFromInt(fuzzer.stats.iterations_executed * 1000)) /
            @as(f64, @floatFromInt(fuzzer.stats.total_time_ms));
    }

    fuzzer.stats.print();
}
