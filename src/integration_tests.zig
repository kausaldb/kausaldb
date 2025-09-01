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
    _ = @import("tests/cli/command_interface.zig");
    _ = @import("tests/debug/arraylist_corruption.zig");
    _ = @import("tests/defensive/assertion_validation.zig");
    _ = @import("tests/defensive/corruption_injection.zig");
    _ = @import("tests/defensive/fatal_assertion_demo.zig");
    _ = @import("tests/defensive/fatal_assertion_validation.zig");
    _ = @import("tests/defensive/performance_impact.zig");
    _ = @import("tests/fault_injection/compaction_crashes.zig");
    _ = @import("tests/fault_injection/deserialization_faults.zig");
    _ = @import("tests/fault_injection/ingestion_faults.zig");
    _ = @import("tests/fault_injection/network_faults.zig");
    _ = @import("tests/fault_injection/query_faults.zig");
    _ = @import("tests/fault_injection/server_faults.zig");
    _ = @import("tests/fault_injection/storage_faults.zig");
    _ = @import("tests/fault_injection/traversal_faults.zig");
    _ = @import("tests/fault_injection/wal_cleanup_faults.zig");
    _ = @import("tests/fault_injection/wal_durability_faults.zig");
    _ = @import("tests/golden_masters_test.zig");
    _ = @import("tests/harness.zig");
    _ = @import("tests/ingestion/cross_file_resolution_test.zig");
    _ = @import("tests/ingestion/ingestion.zig");
    _ = @import("tests/ingestion/zig_parser_integration.zig");
    _ = @import("tests/memory/corruption_prevention_test.zig");
    _ = @import("tests/memory/profiling_validation.zig");
    _ = @import("tests/misc/lifecycle.zig");
    _ = @import("tests/performance/large_block_benchmark.zig");
    _ = @import("tests/performance/streaming_memory_benchmark.zig");
    _ = @import("tests/query/advanced_algorithms_edge_cases.zig");
    _ = @import("tests/query/advanced_traversal.zig");
    _ = @import("tests/query/complex_workloads.zig");

    _ = @import("tests/query/streaming_optimizations.zig");
    _ = @import("tests/recovery/wal.zig");
    _ = @import("tests/workspace/filtering_test.zig");
    _ = @import("tests/workspace/ingestion_deduplication_test.zig");
    _ = @import("tests/recovery/wal_corruption.zig");
    _ = @import("tests/recovery/wal_corruption_fatal.zig");
    _ = @import("tests/recovery/wal_entry_stream_recovery.zig");
    _ = @import("tests/recovery/wal_memory_safety.zig");
    _ = @import("tests/recovery/wal_segment_corruption.zig");
    _ = @import("tests/recovery/wal_segmentation.zig");
    _ = @import("tests/recovery/wal_streaming_recovery.zig");
    _ = @import("tests/safety/fatal_safety_violations.zig");
    _ = @import("tests/safety/memory_corruption.zig");
    _ = @import("tests/safety/ownership_safety.zig");
    _ = @import("tests/scenarios_test.zig");
    _ = @import("tests/server/protocol.zig");
    _ = @import("tests/server/server_coordinator.zig");
    _ = @import("tests/server/server_lifecycle.zig");
    _ = @import("tests/simulation/liveness.zig");
    _ = @import("tests/simulation/network.zig");
    _ = @import("tests/simulation/ownership_hardening.zig");
    _ = @import("tests/storage/bloom_filter_validation.zig");
    _ = @import("tests/storage/defensive_integration.zig");
    _ = @import("tests/storage/enhanced_compaction_strategies.zig");
    _ = @import("tests/storage/memtable_simple_operations.zig");
    _ = @import("tests/storage/mock_vfs_helper.zig");
    _ = @import("tests/storage/property_tests.zig");
    _ = @import("tests/storage/tiered_compaction_validation.zig");
    _ = @import("tests/storage/wal_entry_stream.zig");
    _ = @import("tests/storage/wal_streaming_writes.zig");
    _ = @import("tests/stress/allocator_torture.zig");
    _ = @import("tests/stress/arena_safety.zig");
    _ = @import("tests/stress/memory_fault_injection.zig");
    _ = @import("tests/stress/memory_pressure.zig");
    _ = @import("tests/stress/storage_load.zig");
    _ = @import("tests/vfs/vfs_integration.zig");
}

test "integration test discovery - informational scan for new test files" {
    const git_discovery = @import("dev/git_test_discovery.zig");

    const expected_files = git_discovery.find_integration_test_files(std.testing.allocator) catch |err| {
        std.debug.print("Git discovery failed ({}), skipping scan\n", .{err});
        return;
    };
    defer {
        for (expected_files) |file| {
            std.testing.allocator.free(file);
        }
        std.testing.allocator.free(expected_files);
    }

    const is_valid = git_discovery.validate_imports(std.testing.allocator, "src/integration_tests.zig", expected_files) catch |err| {
        std.debug.print("Import validation failed ({}), skipping\n", .{err});
        return;
    };

    if (!is_valid) {
        std.debug.print("\n[INFO] New integration test files detected (may need manual review):\n", .{});
        for (expected_files) |file| {
            std.debug.print("  Candidate: {s}\n", .{file});
        }
        std.debug.print("Review files for compilation errors before adding to integration_tests.zig\n", .{});
    } else {
        std.debug.print("Integration test discovery: {d} files validated\n", .{expected_files.len});
    }
}
