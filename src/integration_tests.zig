//! Integration test registry for KausalDB test modules.
//!
//! These tests require full API access and use standardized test harnesses.
//! Uses TestRunner for sophisticated test discovery and performance monitoring.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const assert_mod = @import("core/assert.zig");
const assert = assert_mod.assert;
const MiB = 1024 * 1024;

pub const std_options = .{
    .log_level = build_options.log_level,
};

comptime {
    // Simulation tests - deterministic property-based testing framework
    _ = @import("tests/simulation/corruption_recovery.zig");
    _ = @import("tests/simulation/flush_test.zig");
    _ = @import("tests/simulation/liveness.zig");
    _ = @import("tests/simulation/metrics.zig");
    _ = @import("tests/simulation/network.zig");
    _ = @import("tests/simulation/ownership_hardening.zig");
    _ = @import("tests/simulation/property_test.zig");
    _ = @import("tests/simulation/simple_flush_test.zig");

    // Simulation scenario tests
    _ = @import("tests/simulation/scenarios/crash_recovery_test.zig");
    _ = @import("tests/simulation/scenarios/scenario_test.zig");
    _ = @import("tests/simulation/scenarios/workload_test.zig");

    // MIGRATION: Kept essential tests not covered by simulation framework

    // CLI and Server tests - external interface testing
    _ = @import("tests/cli/command_interface.zig");
    _ = @import("tests/server/protocol.zig");
    _ = @import("tests/server/server_coordinator.zig");
    _ = @import("tests/server/server_lifecycle.zig");

    // Ingestion tests - complex edge cases not covered by simulation
    _ = @import("tests/ingestion/cross_file_resolution_test.zig");
    _ = @import("tests/ingestion/ingestion.zig");
    _ = @import("tests/ingestion/zig_parser_integration.zig");

    // Defensive tests - assertion and safety mechanisms
    _ = @import("tests/defensive/assertion_validation.zig");
    _ = @import("tests/defensive/corruption_injection.zig");
    _ = @import("tests/defensive/fatal_assertion_validation.zig");
    _ = @import("tests/defensive/performance_impact.zig");

    // Memory tests - allocation patterns and corruption prevention
    _ = @import("tests/memory/corruption_prevention_test.zig");
    _ = @import("tests/memory/profiling_validation.zig");

    // Performance tests - benchmarking and regression detection
    _ = @import("tests/performance/large_block_benchmark.zig");
    _ = @import("tests/performance/streaming_memory_benchmark.zig");

    // Safety tests - defensive programming validation
    _ = @import("tests/safety/fatal_safety_violations.zig");
    _ = @import("tests/safety/memory_corruption.zig");
    _ = @import("tests/safety/ownership_safety.zig");

    // Query tests - complex algorithm edge cases
    _ = @import("tests/query/algorithms_edge_cases.zig");
    _ = @import("tests/query/streaming_optimizations.zig");
    _ = @import("tests/query/traversal_advanced.zig");
    _ = @import("tests/query/traversal_termination.zig");

    // Recovery tests - specific WAL corruption edge cases
    _ = @import("tests/recovery/wal_core_recovery.zig");
    _ = @import("tests/recovery/wal_corruption_scenarios.zig");
    _ = @import("tests/recovery/wal_streaming_advanced.zig");

    // Storage tests - complex compaction edge cases
    _ = @import("tests/storage/tiered_compaction_validation.zig");
    _ = @import("tests/storage/enhanced_compaction_strategies.zig");

    // VFS integration tests
    _ = @import("tests/vfs/vfs_integration.zig");

    // MIGRATION COMPLETED: Moved redundant tests to old_tests/
    // Deleted categories (now in old_tests/):
    // - fault_injection/* -> simulation framework fault injection
    // - debug/* -> simulation framework validation
    // - scenarios/* -> simulation/scenarios/ with code generators
    // - stress/* -> simulation workload generation
    // - storage/* (except edge cases) -> simulation property tests
    //
    // Kept all essential tests per COVERAGE_ANALYSIS.md:
    // - Complex edge cases not covered by simulation
    // - External interfaces (CLI, server, ingestion)
    // - Core defensive and memory management patterns
    // - Advanced algorithms and platform-specific behavior
}
