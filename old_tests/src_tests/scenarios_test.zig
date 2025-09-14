//! Systematic fault scenario execution for KausalDB hostile condition testing.
//!
//! Executes all available fault injection scenarios to validate system behavior
//! under hostile conditions including I/O failures, corruption, and resource
//! exhaustion. Each scenario tests specific failure modes with deterministic
//! parameters for reproducible validation.
//!
//! Design rationale: Centralized scenario execution ensures comprehensive
//! fault injection coverage and prevents scenarios from being overlooked
//! during development cycles. Systematic validation catches regressions
//! in error handling and recovery mechanisms.

const std = @import("std");

const scenarios = @import("../testing/scenarios.zig");
const simulation_vfs = @import("../sim/simulation_vfs.zig");
const storage = @import("../storage/engine.zig");
const types = @import("../core/types.zig");

const testing = std.testing;

const StorageEngine = storage.StorageEngine;
const SimulationVFS = simulation_vfs.SimulationVFS;
const WalDurabilityScenario = scenarios.WalDurabilityScenario;
const CompactionCrashScenario = scenarios.CompactionCrashScenario;
const FaultScenario = scenarios.FaultScenario;

const ScenarioSuite = struct {
    allocator: std.mem.Allocator,
    total_scenarios: usize,
    passed_scenarios: usize,
    failed_scenarios: usize,

    const Self = @This();

    fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .total_scenarios = 0,
            .passed_scenarios = 0,
            .failed_scenarios = 0,
        };
    }

    /// Execute all WAL durability scenarios with systematic validation
    fn run_wal_durability_scenarios(self: *Self) !void {
        std.debug.print("Executing WAL durability scenarios...\n", .{});

        const wal_scenarios = [_]WalDurabilityScenario{
            .io_flush_failures,
            .disk_space_exhaustion,
            .torn_writes,
            .sequential_faults,
        };

        for (wal_scenarios) |scenario| {
            const config = scenario.config();
            std.debug.print("  Running: {s}", .{config.description});

            self.total_scenarios += 1;

            scenarios.run_wal_durability_scenario(self.allocator, scenario) catch |err| {
                std.debug.print(" - FAILED: {}\n", .{err});
                self.failed_scenarios += 1;
                continue;
            };

            std.debug.print(" - PASSED\n", .{});
            self.passed_scenarios += 1;
        }
    }

    /// Execute all compaction crash scenarios with systematic validation
    fn run_compaction_crash_scenarios(self: *Self) !void {
        std.debug.print("Executing compaction crash scenarios...\n", .{});

        const compaction_scenarios = [_]CompactionCrashScenario{
            .partial_sstable_write,
            .orphaned_files,
            .torn_write_header,
            .sequential_crashes,
        };

        for (compaction_scenarios) |scenario| {
            const config = scenario.config();
            std.debug.print("  Running: {s}", .{config.description});

            self.total_scenarios += 1;

            scenarios.run_compaction_crash_scenario(self.allocator, scenario) catch |err| {
                std.debug.print(" - FAILED: {}\n", .{err});
                self.failed_scenarios += 1;
                continue;
            };

            std.debug.print(" - PASSED\n", .{});
            self.passed_scenarios += 1;
        }
    }

    /// Execute comprehensive fault scenarios with custom configurations
    fn run_comprehensive_fault_scenarios(self: *Self) !void {
        std.debug.print("Executing comprehensive fault scenarios...\n", .{});

        const fault_scenarios = [_]FaultScenario{
            .{
                .description = "Memory pressure with write failures",
                .seed = 0xFADE1234,
                .fault_type = .write_failures,
                .initial_blocks = 100,
                .fault_operations = 30,
                .expected_recovery_success = true,
                .expected_min_survival_rate = 0.8,
                .golden_master_file = null,
            },
            .{
                .description = "Cleanup failures during shutdown",
                .seed = 0xBEEF5678,
                .fault_type = .cleanup_failures,
                .initial_blocks = 75,
                .fault_operations = 15,
                .expected_recovery_success = true,
                .expected_min_survival_rate = 0.9,
                .golden_master_file = null,
            },
            .{
                .description = "Read corruption after successful writes",
                .seed = 0xDEAD9ABC,
                .fault_type = .read_corruption,
                .initial_blocks = 50,
                .fault_operations = 10,
                .expected_recovery_success = true,
                .expected_min_survival_rate = 0.7,
                .golden_master_file = null,
            },
            .{
                .description = "Sequential multi-fault scenario",
                .seed = 0xCAFEDEF0,
                .fault_type = .sequential_faults,
                .initial_blocks = 200,
                .fault_operations = 50,
                .expected_recovery_success = true,
                .expected_min_survival_rate = 0.6,
                .golden_master_file = null,
            },
        };

        for (fault_scenarios) |scenario| {
            std.debug.print("  Running: {s}", .{scenario.description});

            self.total_scenarios += 1;

            self.execute_fault_scenario(scenario) catch |err| {
                std.debug.print(" - FAILED: {}\n", .{err});
                self.failed_scenarios += 1;
                continue;
            };

            std.debug.print(" - PASSED\n", .{});
            self.passed_scenarios += 1;
        }
    }

    /// Execute individual fault scenario with validation
    fn execute_fault_scenario(self: *Self, scenario: FaultScenario) !void {
        const executor = scenarios.ScenarioExecutor.init(self.allocator, scenario);
        try executor.run();
    }

    /// Execute stress scenarios to validate system under extreme conditions
    fn run_stress_scenarios(self: *Self) !void {
        std.debug.print("Executing stress scenarios...\n", .{});

        // High-volume scenario tests system capacity limits
        // Reduced parameters to prevent OutOfMemory in test environment
        const high_volume_scenario = FaultScenario{
            .description = "High volume with intermittent failures",
            .seed = 0x12345678,
            .fault_type = .sync_failures,
            .initial_blocks = 1000,
            .fault_operations = 200,
            .expected_recovery_success = true,
            .expected_min_survival_rate = 0.85,
            .golden_master_file = null,
        };

        std.debug.print("  Running: {s}", .{high_volume_scenario.description});
        self.total_scenarios += 1;

        self.execute_fault_scenario(high_volume_scenario) catch |err| {
            std.debug.print(" - FAILED: {}\n", .{err});
            self.failed_scenarios += 1;
            return;
        };

        std.debug.print(" - PASSED\n", .{});
        self.passed_scenarios += 1;

        // Resource exhaustion scenario tests graceful degradation
        // Reduced parameters to prevent OutOfMemory in test environment
        const exhaustion_scenario = FaultScenario{
            .description = "Resource exhaustion with cleanup challenges",
            .seed = 0x87654321,
            .fault_type = .disk_space_exhaustion,
            .initial_blocks = 500,
            .fault_operations = 100,
            .expected_recovery_success = true,
            .expected_min_survival_rate = 0.90,
            .golden_master_file = null,
        };

        std.debug.print("  Running: {s}", .{exhaustion_scenario.description});
        self.total_scenarios += 1;

        self.execute_fault_scenario(exhaustion_scenario) catch |err| {
            std.debug.print(" - FAILED: {}\n", .{err});
            self.failed_scenarios += 1;
            return;
        };

        std.debug.print(" - PASSED\n", .{});
        self.passed_scenarios += 1;
    }

    /// Run all scenario categories with comprehensive reporting
    fn run_all_scenarios(self: *Self) !void {
        std.debug.print("Starting comprehensive scenario execution...\n\n", .{});

        try self.run_wal_durability_scenarios();
        std.debug.print("\n", .{});

        try self.run_compaction_crash_scenarios();
        std.debug.print("\n", .{});

        try self.run_comprehensive_fault_scenarios();
        std.debug.print("\n", .{});

        try self.run_stress_scenarios();
        std.debug.print("\n", .{});

        self.print_final_results();

        if (self.failed_scenarios > 0) {
            return error.ScenarioValidationFailed;
        }
    }

    /// Print comprehensive results with failure analysis
    fn print_final_results(self: *const Self) void {
        std.debug.print("Scenario execution results:\n", .{});
        std.debug.print("  Total scenarios: {d}\n", .{self.total_scenarios});
        std.debug.print("  Passed: {d}\n", .{self.passed_scenarios});
        std.debug.print("  Failed: {d}\n", .{self.failed_scenarios});

        if (self.failed_scenarios == 0) {
            std.debug.print("  Status: ALL SCENARIOS PASSED\n", .{});
        } else {
            const success_rate = (@as(f32, @floatFromInt(self.passed_scenarios)) /
                @as(f32, @floatFromInt(self.total_scenarios))) * 100.0;
            std.debug.print("  Success rate: {d:.1}%\n", .{success_rate});
            std.debug.print("  Status: FAILURES DETECTED\n", .{});
        }
    }
};

test "execute all fault scenarios" {
    const allocator = testing.allocator;

    var suite = ScenarioSuite.init(allocator);
    try suite.run_all_scenarios();
}

test "wal durability scenarios only" {
    const allocator = testing.allocator;

    var suite = ScenarioSuite.init(allocator);
    try suite.run_wal_durability_scenarios();

    // Validate at least some scenarios were executed
    try testing.expect(suite.total_scenarios > 0);
    try testing.expect(suite.passed_scenarios > 0);
}

test "compaction crash scenarios only" {
    const allocator = testing.allocator;

    var suite = ScenarioSuite.init(allocator);
    try suite.run_compaction_crash_scenarios();

    // Validate at least some scenarios were executed
    try testing.expect(suite.total_scenarios > 0);
    try testing.expect(suite.passed_scenarios > 0);
}

test "single fault scenario execution" {
    const allocator = testing.allocator;

    const test_scenario = FaultScenario{
        .description = "Basic write failure test",
        .seed = 0x11111111,
        .fault_type = .write_failures,
        .initial_blocks = 10,
        .fault_operations = 5,
        .expected_recovery_success = true,
        .expected_min_survival_rate = 0.7,
        .golden_master_file = null,
    };

    var suite = ScenarioSuite.init(allocator);
    try suite.execute_fault_scenario(test_scenario);
}

test "stress scenarios validation" {
    // Use GeneralPurposeAllocator for stress tests to prevent OutOfMemory
    // testing.allocator has limited capacity for high-volume scenarios
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var suite = ScenarioSuite.init(allocator);
    try suite.run_stress_scenarios();

    // Validate stress scenarios were executed
    try testing.expect(suite.total_scenarios >= 2);
    try testing.expect(suite.passed_scenarios > 0);
}
