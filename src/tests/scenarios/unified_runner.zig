//! Unified test runner for scenario-based deterministic testing.
//!
//! Provides a single interface for running all scenario tests with property
//! validation, fault injection, and deterministic reproduction. This runner
//! bridges the gap between specific scenarios and general property exploration.
//!
//! Design rationale: Rather than having scattered test runners, we centralize
//! execution logic here. This ensures consistent test execution, reporting,
//! and makes it easy to add new scenarios or properties without duplicating
//! infrastructure code.

const std = @import("std");
const testing = std.testing;

const assert_mod = @import("../../core/assert.zig");
const deterministic_test = @import("../../sim/deterministic_test.zig");
const simulation_vfs = @import("../../sim/simulation_vfs.zig");
const storage_engine_mod = @import("../../storage/engine.zig");
const storage_properties = @import("../properties/storage_properties.zig");
const types = @import("../../core/types.zig");

const assert = assert_mod.assert;
const fatal_assert = assert_mod.fatal_assert;

const ModelState = deterministic_test.ModelState;
const Operation = deterministic_test.Operation;
const OperationMix = deterministic_test.OperationMix;
const OperationType = deterministic_test.OperationType;
const PropertyChecker = deterministic_test.PropertyChecker;
const SimulationRunner = deterministic_test.SimulationRunner;
const WorkloadGenerator = deterministic_test.WorkloadGenerator;

const GraphProperties = storage_properties.GraphProperties;
const PerformanceProperties = storage_properties.PerformanceProperties;
const RecoveryProperties = storage_properties.RecoveryProperties;
const StorageProperties = storage_properties.StorageProperties;

const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const EdgeType = types.EdgeType;
const GraphEdge = types.GraphEdge;

const log = std.log.scoped(.unified_runner);

/// Scenario category for organization and filtering
pub const ScenarioCategory = enum {
    storage,
    query,
    ingestion,
    recovery,
    performance,
    regression,
};

/// Individual scenario definition
pub const Scenario = struct {
    name: []const u8,
    category: ScenarioCategory,
    seed: u64,
    operation_mix: OperationMix,
    operation_count: u32,
    fault_config: FaultConfig,
    validation_properties: []const Property,
    description: []const u8,
};

/// Fault injection configuration
pub const FaultConfig = struct {
    io_error_probability: f32 = 0.0,
    corruption_probability: f32 = 0.0,
    partial_write_probability: f32 = 0.0,
    syntax_error_probability: f32 = 0.0,
    crash_interval: ?u32 = null,
    memory_pressure: bool = false,
};

/// Property to validate during/after scenario execution
pub const Property = enum {
    write_visibility,
    delete_effectiveness,
    crash_durability,
    memory_cleanup,
    compaction_preservation,
    edge_references,
    bidirectional_consistency,
    cascade_deletion,
    latency_bounds,
    throughput,
    memory_growth,
    replay_idempotence,
};

/// Execution metrics for reporting
pub const ExecutionMetrics = struct {
    scenario_name: []const u8,
    operations_executed: u64,
    properties_validated: u32,
    faults_injected: u32,
    duration_ns: u64,
    memory_peak: u64,
    errors_handled: u32,

    pub fn format(self: ExecutionMetrics, writer: anytype) !void {
        try writer.print(
            \\Scenario: {s}
            \\  Operations: {}
            \\  Properties validated: {}
            \\  Faults injected: {}
            \\  Duration: {d:.2}ms
            \\  Peak memory: {d:.2}MB
            \\  Errors handled: {}
        , .{
            self.scenario_name,
            self.operations_executed,
            self.properties_validated,
            self.faults_injected,
            @as(f64, @floatFromInt(self.duration_ns)) / 1_000_000.0,
            @as(f64, @floatFromInt(self.memory_peak)) / (1024.0 * 1024.0),
            self.errors_handled,
        });
    }
};

/// Main unified test runner
pub const UnifiedRunner = struct {
    allocator: std.mem.Allocator,
    scenarios: std.ArrayList(Scenario),
    results: std.ArrayList(ExecutionMetrics),
    verbose: bool,

    const Self = @This();

    /// Initialize the unified runner
    pub fn init(allocator: std.mem.Allocator, verbose: bool) Self {
        return Self{
            .allocator = allocator,
            .scenarios = std.ArrayList(Scenario).init(allocator),
            .results = std.ArrayList(ExecutionMetrics).init(allocator),
            .verbose = verbose,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        self.scenarios.deinit();
        self.results.deinit();
    }

    /// Register a scenario for execution
    pub fn register_scenario(self: *Self, scenario: Scenario) !void {
        try self.scenarios.append(scenario);

        if (self.verbose) {
            log.info("Registered scenario: {s} ({s})", .{ scenario.name, @tagName(scenario.category) });
        }
    }

    /// Run all registered scenarios
    pub fn run_all(self: *Self) !void {
        log.info("Running {} scenarios", .{self.scenarios.items.len});

        for (self.scenarios.items) |scenario| {
            try self.run_scenario(scenario);
        }

        try self.report_results();
    }

    /// Run scenarios matching a category
    pub fn run_category(self: *Self, category: ScenarioCategory) !void {
        var count: u32 = 0;

        for (self.scenarios.items) |scenario| {
            if (scenario.category == category) {
                try self.run_scenario(scenario);
                count += 1;
            }
        }

        log.info("Ran {} scenarios in category {s}", .{ count, @tagName(category) });
        try self.report_results();
    }

    /// Run a single scenario with property validation
    pub fn run_scenario(self: *Self, scenario: Scenario) !void {
        if (self.verbose) {
            log.info("Starting scenario: {s}", .{scenario.name});
            log.info("  {s}", .{scenario.description});
        }

        const start_time = std.time.nanoTimestamp();
        var metrics = ExecutionMetrics{
            .scenario_name = scenario.name,
            .operations_executed = 0,
            .properties_validated = 0,
            .faults_injected = 0,
            .duration_ns = 0,
            .memory_peak = 0,
            .errors_handled = 0,
        };

        // Create simulation runner with scenario configuration
        var runner = try SimulationRunner.init(
            self.allocator,
            scenario.seed,
            scenario.operation_mix,
            &.{
                .io_error_probability = scenario.fault_config.io_error_probability,
                .corruption_probability = scenario.fault_config.corruption_probability,
                .partial_write_probability = scenario.fault_config.partial_write_probability,
            },
        );
        defer runner.deinit();

        // Configure additional settings based on scenario
        if (scenario.fault_config.memory_pressure) {
            runner.flush_config.memory_threshold = 256 * 1024; // Small threshold
            runner.flush_config.enable_memory_trigger = true;
        }

        // Execute operations with potential crash intervals
        if (scenario.fault_config.crash_interval) |interval| {
            var operations_done: u32 = 0;
            while (operations_done < scenario.operation_count) {
                const batch_size = @min(interval, scenario.operation_count - operations_done);

                try runner.run(batch_size);
                operations_done += batch_size;
                metrics.operations_executed += batch_size;

                // Simulate crash and recovery if not at end
                if (operations_done < scenario.operation_count) {
                    try runner.simulate_crash_recovery();
                    metrics.faults_injected += 1;
                }
            }
        } else {
            // Run all operations without crashes
            try runner.run(scenario.operation_count);
            metrics.operations_executed = scenario.operation_count;
        }

        // Track fault injections
        metrics.faults_injected += runner.faults_injected();
        metrics.errors_handled = runner.errors_handled();

        // Validate properties
        for (scenario.validation_properties) |property| {
            try self.validate_property(&runner, property);
            metrics.properties_validated += 1;
        }

        // Calculate final metrics
        const end_time = std.time.nanoTimestamp();
        metrics.duration_ns = @intCast(end_time - start_time);
        metrics.memory_peak = runner.peak_memory();

        // Store results
        try self.results.append(metrics);

        if (self.verbose) {
            log.info("Completed scenario: {s} in {d:.2}ms", .{
                scenario.name,
                @as(f64, @floatFromInt(metrics.duration_ns)) / 1_000_000.0,
            });
        }
    }

    /// Validate a specific property
    fn validate_property(self: *Self, runner: *SimulationRunner, property: Property) !void {
        _ = self;

        switch (property) {
            .write_visibility => {
                try StorageProperties.validate_write_visibility(
                    runner.model.blocks,
                    runner.storage_engine,
                );
            },
            .delete_effectiveness => {
                try StorageProperties.validate_delete_effectiveness(
                    runner.model.deleted_blocks,
                    runner.storage_engine,
                );
            },
            .crash_durability => {
                // Validated during crash recovery simulation
                try runner.verify_consistency();
            },
            .memory_cleanup => {
                const pre_memory = runner.memory_stats().arena_bytes;
                try runner.force_flush();
                const post_memory = runner.memory_stats().arena_bytes;

                try StorageProperties.validate_memory_cleanup(
                    pre_memory,
                    post_memory,
                    1.2, // 20% tolerance
                );
            },
            .compaction_preservation => {
                // Save state before compaction
                var pre_blocks = try runner.model.blocks.clone();
                defer pre_blocks.deinit();

                try runner.force_compaction();

                try StorageProperties.validate_compaction_preservation(
                    pre_blocks,
                    runner.storage_engine,
                );
            },
            .edge_references => {
                try GraphProperties.validate_edge_references(
                    runner.model.edges,
                    runner.model.blocks,
                );
            },
            .bidirectional_consistency => {
                try GraphProperties.validate_bidirectional_consistency(
                    runner.storage_engine,
                );
            },
            .cascade_deletion => {
                // Property validated during delete operations
                try runner.verify_edge_consistency();
            },
            .latency_bounds => {
                const stats = runner.performance_stats();
                try PerformanceProperties.validate_latency_bounds(
                    "block_write",
                    stats.avg_write_latency,
                    100_000, // 100µs bound
                );
            },
            .throughput => {
                const stats = runner.performance_stats();
                try PerformanceProperties.validate_throughput(
                    stats.operations_per_second,
                    10_000, // 10K ops/s minimum
                );
            },
            .memory_growth => {
                const initial = runner.initial_memory();
                const current = runner.current_memory();
                const ops = runner.operations_executed();

                try PerformanceProperties.validate_memory_growth(
                    initial,
                    current,
                    ops,
                    2048, // 2KB per op maximum
                );
            },
            .replay_idempotence => {
                // Validate WAL replay idempotence
                try runner.verify_replay_idempotence();
            },
        }
    }

    /// Generate summary report of all scenario results
    fn report_results(self: *Self) !void {
        if (self.results.items.len == 0) {
            return;
        }

        log.info("=" ** 60, .{});
        log.info("Test Execution Summary", .{});
        log.info("=" ** 60, .{});

        var total_operations: u64 = 0;
        var total_duration: u64 = 0;
        var total_properties: u32 = 0;
        var total_faults: u32 = 0;

        for (self.results.items) |metrics| {
            if (self.verbose) {
                try metrics.format(std.io.getStdErr().writer());
                log.info("", .{});
            }

            total_operations += metrics.operations_executed;
            total_duration += metrics.duration_ns;
            total_properties += metrics.properties_validated;
            total_faults += metrics.faults_injected;
        }

        log.info("Total scenarios: {}", .{self.results.items.len});
        log.info("Total operations: {}", .{total_operations});
        log.info("Total properties validated: {}", .{total_properties});
        log.info("Total faults injected: {}", .{total_faults});
        log.info("Total duration: {d:.2}s", .{
            @as(f64, @floatFromInt(total_duration)) / 1_000_000_000.0,
        });
        log.info("=" ** 60, .{});
    }
};

/// Create and register all standard scenarios
pub fn register_standard_scenarios(runner: *UnifiedRunner) !void {
    // Storage scenarios
    try runner.register_scenario(.{
        .name = "basic_storage_operations",
        .category = .storage,
        .seed = 0x1001,
        .operation_mix = .{
            .put_block_weight = 40,
            .find_block_weight = 40,
            .delete_block_weight = 20,
            .put_edge_weight = 0,
            .find_edges_weight = 0,
        },
        .operation_count = 100,
        .fault_config = .{},
        .validation_properties = &.{ .write_visibility, .delete_effectiveness },
        .description = "Basic put-find-delete operations",
    });

    try runner.register_scenario(.{
        .name = "memtable_flush_cycles",
        .category = .storage,
        .seed = 0x2001,
        .operation_mix = .{
            .put_block_weight = 70,
            .find_block_weight = 30,
            .delete_block_weight = 0,
            .put_edge_weight = 0,
            .find_edges_weight = 0,
        },
        .operation_count = 300,
        .fault_config = .{ .memory_pressure = true },
        .validation_properties = &.{ .memory_cleanup, .write_visibility },
        .description = "Memory pressure and flush cycles",
    });

    // Recovery scenarios
    try runner.register_scenario(.{
        .name = "crash_recovery_durability",
        .category = .recovery,
        .seed = 0x3001,
        .operation_mix = .{
            .put_block_weight = 50,
            .find_block_weight = 35,
            .delete_block_weight = 5,
            .put_edge_weight = 10,
            .find_edges_weight = 0,
        },
        .operation_count = 300,
        .fault_config = .{ .crash_interval = 50 },
        .validation_properties = &.{ .crash_durability, .replay_idempotence },
        .description = "Crash recovery with durability validation",
    });

    // Performance scenarios
    try runner.register_scenario(.{
        .name = "sustained_throughput",
        .category = .performance,
        .seed = 0x4001,
        .operation_mix = .{
            .put_block_weight = 35,
            .find_block_weight = 40,
            .delete_block_weight = 5,
            .put_edge_weight = 15,
            .find_edges_weight = 5,
        },
        .operation_count = 10000,
        .fault_config = .{},
        .validation_properties = &.{ .throughput, .latency_bounds, .memory_growth },
        .description = "Sustained workload performance validation",
    });

    // Add more scenarios as needed...
}

/// Run standard test suite
pub fn run_standard_suite(allocator: std.mem.Allocator, verbose: bool) !void {
    var runner = UnifiedRunner.init(allocator, verbose);
    defer runner.deinit();

    try register_standard_scenarios(&runner);
    try runner.run_all();
}
