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
    // All simulation tests are enabled - deterministic property-based testing
    _ = @import("tests/simulation/property_test.zig");
    _ = @import("tests/simulation/flush.zig");
    _ = @import("tests/simulation/simple_flush_test.zig");
    _ = @import("tests/simulation/corruption_recovery.zig");
    _ = @import("tests/simulation/metrics.zig");
    _ = @import("tests/simulation/network.zig");
    _ = @import("tests/simulation/ownership_hardening.zig");
    _ = @import("tests/simulation/liveness.zig");

    // Simulation scenario tests
    _ = @import("tests/simulation/scenarios/workload_test.zig");
    _ = @import("tests/simulation/scenarios/scenario_test.zig");
    _ = @import("tests/simulation/scenarios/crash_recovery_test.zig");

    // Temporarily disabled - requires extended SimulationRunner methods
    // _ = @import("tests/scenarios/comprehensive_storage_scenarios.zig");
    // _ = @import("tests/scenarios/query_scenarios.zig");
    // _ = @import("tests/scenarios/ingestion_scenarios.zig");
    // _ = @import("tests/scenarios/unified_runner.zig");
    // _ = @import("tests/scenarios/storage_scenarios.zig");
    // _ = @import("tests/properties/storage_properties.zig");
    // _ = @import("tests/regression/issue_reproductions.zig");

    // Core tests - component integration testing
    _ = @import("tests/core/production_vfs.zig");

    // Storage tests - cross-component integration testing
    _ = @import("tests/storage/engine_integration.zig");

    // Server tests - external interface testing
    _ = @import("tests/server/protocol.zig");
    _ = @import("tests/server/server_coordinator.zig");
    _ = @import("tests/server/server_lifecycle.zig");

    // CLI tests - command execution and natural language processing

    // Ingestion tests - complex edge cases not covered by simulation
    _ = @import("tests/ingestion/cross_file_resolution.zig");
    _ = @import("tests/ingestion/ingestion.zig");
    _ = @import("tests/ingestion/zig_parser_integration.zig");

    // Defensive tests - specific assertion and safety mechanisms
    _ = @import("tests/defensive/assertion_validation.zig");
    _ = @import("tests/defensive/corruption_injection.zig");
    _ = @import("tests/defensive/fatal_assertion_validation.zig");
    _ = @import("tests/defensive/performance_impact.zig");

    // Memory tests - allocation patterns and corruption prevention
    _ = @import("tests/memory/corruption_prevention.zig");
    _ = @import("tests/memory/profiling_validation.zig");

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

    // Safety tests - memory and ownership validation
    _ = @import("tests/safety/ownership_safety.zig");
    _ = @import("tests/safety/fatal_safety_violations.zig");
    _ = @import("tests/safety/memory_corruption.zig");

    // Performance tests - benchmarking and memory profiling
    _ = @import("tests/performance/streaming_memory_benchmark.zig");
    _ = @import("tests/performance/large_block_benchmark.zig");
}
