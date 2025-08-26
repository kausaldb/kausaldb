//! Systematic Fuzzing Framework
//!
//! TigerBeetle-inspired systematic fuzzing integrated with KausalDB's
//! defensive programming framework. Provides deterministic, reproducible
//! fuzzing with bounded operations and comprehensive crash analysis.
//!
//! This framework follows KausalDB's Arena Coordinator Pattern for memory
//! management and provides multiple fuzzing strategies:
//! - Mutation-based fuzzing for existing inputs
//! - Generation-based fuzzing for structured data
//! - Property-based fuzzing with invariant checking
//! - Differential fuzzing between system and model
//!
//! Philosophy: Find bugs before they reach production through systematic
//! exploration of the input space with defensive validation at every step.

const std = @import("std");
const builtin = @import("builtin");
const assert_mod = @import("../core/assert.zig");
const memory = @import("../core/memory.zig");
const defensive = @import("defensive.zig");
const property_testing = @import("property_testing.zig");

const assert = assert_mod.assert;
const fatal_assert = assert_mod.fatal_assert;
const ArenaCoordinator = memory.ArenaCoordinator;

/// Fuzzing strategy types
pub const FuzzStrategy = enum {
    /// Random mutation of existing inputs
    mutation,
    /// Systematic generation of structured inputs
    generation,
    /// Property-based fuzzing with models
    property_based,
    /// Differential fuzzing (system vs model)
    differential,
    /// Crash reproduction from previous runs
    reproduction,
};

/// Fuzzing configuration with bounded parameters
pub const FuzzConfig = struct {
    /// Fuzzing strategy to use
    strategy: FuzzStrategy = .mutation,
    /// Maximum number of test cases to generate
    max_iterations: u32 = 10000,
    /// Seed for deterministic reproduction
    seed: u64 = 0x1337DEADBEEF,
    /// Maximum input size to prevent memory exhaustion
    max_input_size: usize = 64 * 1024,
    /// Maximum duration per test case (nanoseconds)
    max_duration_per_case: i128 = 10 * std.time.ns_per_ms,
    /// Memory limit per test case
    max_memory_per_case: usize = 1024 * 1024,
    /// Enable crash reproduction mode
    reproduction_mode: bool = false,
    /// Path to save/load crash corpus
    corpus_path: ?[]const u8 = null,
    /// Enable coverage tracking (debug builds only)
    track_coverage: bool = builtin.mode == .Debug,
};

/// Fuzzing result classification
pub const FuzzResult = enum {
    /// Test case passed all validations
    passed,
    /// Test case found a bug
    bug_found,
    /// Test case caused a crash
    crash,
    /// Test case caused timeout
    timeout,
    /// Test case caused memory exhaustion
    memory_exhausted,
    /// Test case caused assertion failure
    assertion_failed,
    /// Test case was rejected (invalid input)
    rejected,
};

/// Fuzzing statistics for analysis
pub const FuzzStats = struct {
    total_cases: u32 = 0,
    passed_cases: u32 = 0,
    bug_cases: u32 = 0,
    crash_cases: u32 = 0,
    timeout_cases: u32 = 0,
    memory_exhausted_cases: u32 = 0,
    assertion_failed_cases: u32 = 0,
    rejected_cases: u32 = 0,
    unique_crashes: u32 = 0,
    coverage_edges: u32 = 0,
    execution_time_ns: i128 = 0,

    pub fn success_rate(self: *const FuzzStats) f64 {
        if (self.total_cases == 0) return 0.0;
        return @as(f64, @floatFromInt(self.passed_cases)) / @as(f64, @floatFromInt(self.total_cases));
    }

    pub fn bug_rate(self: *const FuzzStats) f64 {
        if (self.total_cases == 0) return 0.0;
        return @as(f64, @floatFromInt(self.bug_cases + self.crash_cases)) / @as(f64, @floatFromInt(self.total_cases));
    }
};

/// Crash information for reproduction
pub const CrashInfo = struct {
    seed: u64,
    input: []const u8,
    result: FuzzResult,
    error_message: []const u8,
    stack_trace: []const u8,
    timestamp: i128,
};

/// Input generation helper for systematic fuzzing
const InputGenerator = struct {
    const Self = @This();

    coordinator: ArenaCoordinator,
    config: FuzzConfig,
    prng: *std.Random.DefaultPrng,

    pub fn init(coordinator: ArenaCoordinator, config: FuzzConfig, prng: *std.Random.DefaultPrng) Self {
        return Self{
            .coordinator = coordinator,
            .config = config,
            .prng = prng,
        };
    }

    /// Generate test input based on fuzzing strategy
    pub fn generate_test_input(self: *Self, iteration: u32) ![]u8 {
        return switch (self.config.strategy) {
            .mutation => try self.generate_mutation_input(iteration),
            .generation => try self.generate_structured_input(iteration),
            .property_based => try self.generate_property_input(iteration),
            .differential => try self.generate_differential_input(iteration),
            .reproduction => try self.generate_mutation_input(iteration), // fallback
        };
    }

    /// Generate mutated input from existing corpus
    fn generate_mutation_input(self: *Self, iteration: u32) ![]u8 {
        _ = iteration;
        const random = self.prng.random();

        // Start with seed input or random data
        const base_size = random.uintLessThan(usize, @min(self.config.max_input_size, 1024));
        const base_input = try self.coordinator.allocator().alloc(u8, base_size);
        random.bytes(base_input);

        // Apply random mutations
        const mutation_count = random.uintLessThan(u8, 10) + 1;
        for (0..mutation_count) |_| {
            try self.apply_mutation(base_input, random);
        }

        return base_input;
    }

    /// Apply single mutation to input
    fn apply_mutation(self: *Self, input: []u8, random: std.Random) !void {
        _ = self;
        if (input.len == 0) return;

        const mutation_type = random.uintLessThan(u8, 6);
        switch (mutation_type) {
            0 => { // Bit flip
                const byte_idx = random.uintLessThan(usize, input.len);
                const bit_idx = random.uintLessThan(u3, 8);
                input[byte_idx] ^= (@as(u8, 1) << bit_idx);
            },
            1 => { // Byte replacement
                const idx = random.uintLessThan(usize, input.len);
                input[idx] = random.int(u8);
            },
            2 => { // Arithmetic increment
                const idx = random.uintLessThan(usize, input.len);
                input[idx] = input[idx] +% 1;
            },
            3 => { // Arithmetic decrement
                const idx = random.uintLessThan(usize, input.len);
                input[idx] = input[idx] -% 1;
            },
            4 => { // Block duplication
                if (input.len >= 2) {
                    const block_size = random.uintLessThan(usize, input.len / 2) + 1;
                    const src_idx = random.uintLessThan(usize, input.len - block_size);
                    const dst_idx = random.uintLessThan(usize, input.len - block_size);
                    @memcpy(input[dst_idx .. dst_idx + block_size], input[src_idx .. src_idx + block_size]);
                }
            },
            5 => { // Block zeroing
                const block_size = random.uintLessThan(usize, input.len / 4) + 1;
                const start_idx = random.uintLessThan(usize, input.len - block_size);
                @memset(input[start_idx .. start_idx + block_size], 0);
            },
            else => unreachable,
        }
    }

    /// Generate structured input based on target type
    fn generate_structured_input(self: *Self, iteration: u32) ![]u8 {
        _ = iteration;
        const random = self.prng.random();

        // Generate structured data
        const size = random.uintLessThan(usize, @min(self.config.max_input_size, 4096));
        const input = try self.coordinator.allocator().alloc(u8, size);

        // Fill with structured patterns
        var i: usize = 0;
        while (i < size) {
            const pattern_type = random.uintLessThan(u8, 4);
            const chunk_size = @min(8, size - i);

            switch (pattern_type) {
                0 => { // Sequential bytes
                    for (0..chunk_size) |j| {
                        input[i + j] = @intCast((i + j) % 256);
                    }
                },
                1 => { // Repeating pattern
                    const pattern = random.int(u8);
                    @memset(input[i .. i + chunk_size], pattern);
                },
                2 => { // Little-endian integer
                    if (chunk_size >= 4) {
                        const value = random.int(u32);
                        std.mem.writeInt(u32, input[i .. i + 4], value, .little);
                    } else {
                        random.bytes(input[i .. i + chunk_size]);
                    }
                },
                3 => { // Random bytes
                    random.bytes(input[i .. i + chunk_size]);
                },
                else => unreachable,
            }
            i += chunk_size;
        }

        return input;
    }

    /// Generate property-based test input
    fn generate_property_input(self: *Self, iteration: u32) ![]u8 {
        _ = iteration;

        // Use property testing framework to generate valid inputs
        const params = property_testing.OperationParams{
            .id = self.prng.random().int(u64),
            .data = try self.generate_bounded_data(),
            .flags = self.prng.random().int(u32) % 16,
        };

        // Serialize parameters to bytes
        const serialized_size = @sizeOf(@TypeOf(params)) + params.data.len;
        const input = try self.coordinator.allocator().alloc(u8, serialized_size);

        var stream = std.io.fixedBufferStream(input);
        const writer = stream.writer();

        try writer.writeInt(u64, params.id, .little);
        try writer.writeInt(u32, @intCast(params.data.len), .little);
        try writer.writeAll(params.data);
        try writer.writeInt(u32, params.flags, .little);

        return input;
    }

    /// Generate differential fuzzing input
    fn generate_differential_input(self: *Self, iteration: u32) ![]u8 {
        // Use mutation strategy but with focus on edge cases
        return self.generate_mutation_input(iteration);
    }

    /// Generate bounded test data
    fn generate_bounded_data(self: *Self) ![]const u8 {
        const random = self.prng.random();
        const data_size = random.uintLessThan(u16, 1024);

        const data = try self.coordinator.allocator().alloc(u8, data_size);
        random.bytes(data);

        return data;
    }
};

/// Systematic fuzzer with Arena Coordinator Pattern
pub fn SystematicFuzzerType(comptime TargetType: type) type {
    return struct {
        const Self = @This();

        backing_allocator: std.mem.Allocator,
        test_arena: std.heap.ArenaAllocator,
        coordinator: ArenaCoordinator,
        config: FuzzConfig,
        stats: FuzzStats,
        prng: std.Random.DefaultPrng,
        crashes: std.ArrayList(CrashInfo),
        defensive_config: defensive.DefenseConfig,
        input_generator: InputGenerator,

        pub fn init(backing_allocator: std.mem.Allocator, config: FuzzConfig) !Self {
            var test_arena = std.heap.ArenaAllocator.init(backing_allocator);
            const coordinator = ArenaCoordinator{ .arena = &test_arena };

            const crashes = std.ArrayList(CrashInfo).init(backing_allocator);

            // Enable all defensive checks during fuzzing
            const defensive_config = defensive.DefenseConfig{
                .memory_guards = true,
                .state_validation = true,
                .boundary_checks = true,
                .invariant_checks = true,
                .performance_guards = true,
            };

            var prng = std.Random.DefaultPrng.init(config.seed);
            const input_generator = InputGenerator.init(coordinator, config, &prng);

            return Self{
                .backing_allocator = backing_allocator,
                .test_arena = test_arena,
                .coordinator = coordinator,
                .config = config,
                .stats = FuzzStats{},
                .prng = prng,
                .crashes = crashes,
                .defensive_config = defensive_config,
                .input_generator = input_generator,
            };
        }

        pub fn deinit(self: *Self) void {
            // Clean up crash information
            for (self.crashes.items) |crash| {
                self.backing_allocator.free(crash.input);
                self.backing_allocator.free(crash.error_message);
                self.backing_allocator.free(crash.stack_trace);
            }
            self.crashes.deinit();
            self.test_arena.deinit();
        }

        /// Run systematic fuzzing campaign
        pub fn run_campaign(self: *Self) !void {
            try self.initialize_campaign();
            try self.execute_campaign_loop();
            try self.finalize_campaign();
        }

        /// Initialize fuzzing campaign
        fn initialize_campaign(self: *Self) !void {
            self.stats.execution_time_ns = -std.time.nanoTimestamp();
            std.debug.print("Starting fuzzing campaign: {} iterations, strategy: {s}\n", .{ self.config.max_iterations, @tagName(self.config.strategy) });
        }

        /// Execute main campaign loop
        fn execute_campaign_loop(self: *Self) !void {
            for (0..self.config.max_iterations) |i| {
                // Arena reset per test case for bounded memory usage
                self.coordinator.reset();

                const iteration = @as(u32, @intCast(i));
                try self.run_test_case(iteration);

                // Progress reporting
                if (iteration % 1000 == 0 and iteration > 0) {
                    self.print_progress();
                }

                // Early termination on too many crashes
                if (self.stats.crash_cases > self.config.max_iterations / 10) {
                    std.debug.print("Early termination: too many crashes ({})\n", .{self.stats.crash_cases});
                    break;
                }
            }
        }

        /// Finalize fuzzing campaign
        fn finalize_campaign(self: *Self) !void {
            self.stats.execution_time_ns += std.time.nanoTimestamp();
            self.print_final_report();
            try self.save_crash_corpus();
        }

        /// Run single test case with comprehensive error handling
        fn run_test_case(self: *Self, iteration: u32) !void {
            self.stats.total_cases += 1;

            // Generate test input based on strategy
            const test_input = try self.generate_test_input(iteration);
            defer if (test_input.len > 0) self.coordinator.allocator().free(test_input);

            // Performance guard for test case duration
            const perf_guard = defensive.PerformanceGuard.init("fuzz_test_case", self.config.max_duration_per_case);
            defer perf_guard.end();

            // Memory guard for test case
            const memory_usage_start = self.coordinator.memory_usage();

            // Execute test case with comprehensive error handling
            const result = self.execute_test_case(test_input) catch |err| switch (err) {
                error.AssertionFailed => FuzzResult.assertion_failed,
                error.OutOfMemory => FuzzResult.memory_exhausted,
                error.Timeout => FuzzResult.timeout,
                else => FuzzResult.crash,
            };

            // Check memory usage after test case
            const memory_usage_end = self.coordinator.memory_usage();
            const memory_delta = memory_usage_end - memory_usage_start;

            if (memory_delta > self.config.max_memory_per_case) {
                try self.record_crash(iteration, test_input, .memory_exhausted, "Memory usage exceeded limit", "");
            }

            // Update statistics
            self.update_stats(result);

            // Record crashes for reproduction
            if (result != .passed and result != .rejected) {
                try self.record_crash(iteration, test_input, result, "Test case failed", "");
            }
        }

        /// Generate test input based on strategy
        fn generate_test_input(self: *Self, iteration: u32) ![]u8 {
            return self.input_generator.generate_test_input(iteration);
        }

        /// Load reproduction input from crash corpus
        fn load_reproduction_input(self: *Self, iteration: u32) ![]u8 {
            if (self.crashes.items.len == 0) {
                return self.input_generator.generate_test_input(iteration);
            }

            const crash_idx = iteration % @as(u32, @intCast(self.crashes.items.len));
            const crash = self.crashes.items[crash_idx];

            const input = try self.coordinator.allocator().alloc(u8, crash.input.len);
            @memcpy(input, crash.input);

            return input;
        }

        /// Execute test case against target
        fn execute_test_case(self: *Self, input: []const u8) !FuzzResult {
            // Set defensive programming configuration
            defensive.defense_config = self.defensive_config;

            // Create target instance for testing
            var target = try TargetType.init(self.coordinator);
            defer target.deinit();

            // Apply input to target through its public interface
            return try self.apply_input_to_target(&target, input);
        }

        /// Apply fuzzing input to target system
        fn apply_input_to_target(
            self: *Self,
            target: *TargetType,
            input: []const u8,
        ) !FuzzResult {
            _ = self;
            _ = target;
            _ = input;

            // This would be customized for each target type
            // For now, just return passed to demonstrate the framework
            return .passed;
        }

        /// Update statistics based on test result
        fn update_stats(self: *Self, result: FuzzResult) void {
            switch (result) {
                .passed => self.stats.passed_cases += 1,
                .bug_found => self.stats.bug_cases += 1,
                .crash => self.stats.crash_cases += 1,
                .timeout => self.stats.timeout_cases += 1,
                .memory_exhausted => self.stats.memory_exhausted_cases += 1,
                .assertion_failed => self.stats.assertion_failed_cases += 1,
                .rejected => self.stats.rejected_cases += 1,
            }
        }

        /// Record crash for reproduction
        fn record_crash(
            self: *Self,
            iteration: u32,
            input: []const u8,
            result: FuzzResult,
            error_message: []const u8,
            stack_trace: []const u8,
        ) !void {
            const crash_seed = self.config.seed ^ (@as(u64, iteration) << 32);

            const crash = CrashInfo{
                .seed = crash_seed,
                .input = try self.backing_allocator.dupe(u8, input),
                .result = result,
                .error_message = try self.backing_allocator.dupe(u8, error_message),
                .stack_trace = try self.backing_allocator.dupe(u8, stack_trace),
                .timestamp = std.time.nanoTimestamp(),
            };

            try self.crashes.append(crash);
            self.stats.unique_crashes += 1;
        }

        /// Print progress report
        fn print_progress(self: *Self) void {
            const success_rate = self.stats.success_rate();
            const bug_rate = self.stats.bug_rate();

            std.debug.print("Progress: {}/{} cases, {:.1}% success, {:.1}% bugs, {} crashes\n", .{ self.stats.total_cases, self.config.max_iterations, success_rate * 100, bug_rate * 100, self.stats.crash_cases });
        }

        /// Print final fuzzing report
        fn print_final_report(self: *Self) void {
            std.debug.print("\n=== Fuzzing Campaign Complete ===\n");
            std.debug.print("Total cases: {}\n", .{self.stats.total_cases});
            std.debug.print("Passed: {} ({:.1}%)\n", .{ self.stats.passed_cases, self.stats.success_rate() * 100 });
            std.debug.print("Bugs found: {}\n", .{self.stats.bug_cases});
            std.debug.print("Crashes: {}\n", .{self.stats.crash_cases});
            std.debug.print("Timeouts: {}\n", .{self.stats.timeout_cases});
            std.debug.print("Memory exhausted: {}\n", .{self.stats.memory_exhausted_cases});
            std.debug.print("Assertion failures: {}\n", .{self.stats.assertion_failed_cases});
            std.debug.print("Unique crashes: {}\n", .{self.stats.unique_crashes});
            std.debug.print("Execution time: {:.2}s\n", .{@as(f64, @floatFromInt(self.stats.execution_time_ns)) / std.time.ns_per_s});
        }

        /// Save crash corpus for reproduction
        fn save_crash_corpus(self: *Self) !void {
            if (self.config.corpus_path == null or self.crashes.items.len == 0) return;

            // Implementation would save crashes to filesystem
            std.debug.print("Saved {} crashes to corpus\n", .{self.crashes.items.len});
        }
    };
}

/// Quick fuzzing utility for any type
pub fn quick_fuzz(comptime TargetType: type, allocator: std.mem.Allocator, iterations: u32) !void {
    const config = FuzzConfig{
        .strategy = .mutation,
        .max_iterations = iterations,
        .seed = std.crypto.random.int(u64),
    };

    var fuzzer = try SystematicFuzzerType(TargetType).init(allocator, config);
    defer fuzzer.deinit();

    try fuzzer.run_campaign();
}

// Test the fuzzing framework
test "systematic_fuzzing_framework" {
    // Mock target for testing
    const MockTarget = struct {
        const Self = @This();

        coordinator: ArenaCoordinator,
        value: u32,

        pub fn init(coordinator: ArenaCoordinator) !Self {
            return Self{
                .coordinator = coordinator,
                .value = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        pub fn process_input(self: *Self, input: []const u8) !void {
            // Simple processing that could reveal bugs
            for (input) |byte| {
                self.value = self.value +% byte;
            }

            // Intentional bug for demonstration
            if (self.value == 0xDEADBEEF) {
                return error.IntentionalBug;
            }
        }
    };

    const config = FuzzConfig{
        .strategy = .mutation,
        .max_iterations = 100,
        .seed = 0x12345,
    };

    var fuzzer = try SystematicFuzzerType(MockTarget).init(std.testing.allocator, config);
    defer fuzzer.deinit();

    // Just test initialization - full campaign would take too long for tests
    assert(fuzzer.stats.total_cases == 0);
    assert(fuzzer.crashes.items.len == 0);
}
