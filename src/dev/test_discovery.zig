//! Simple test discovery for KausalDB
//!
//! Uses hardcoded lists of test files to avoid filesystem walking issues
//! between platforms. Much more reliable than dynamic discovery.

const std = @import("std");

/// Find all unit test files (hardcoded list)
pub fn find_unit_test_files(allocator: std.mem.Allocator) ![][]const u8 {
    const unit_test_files = [_][]const u8{
        "cli/natural_commands.zig",
        "cli/natural_executor.zig",
        "core/arena.zig",
        "core/assert.zig",
        "core/bounded.zig",
        "core/concurrency.zig",
        "core/error_context.zig",
        "core/file_handle.zig",
        "core/memory.zig",
        "core/ownership.zig",
        "core/pools.zig",
        "core/production_vfs.zig",
        "core/signals.zig",
        "core/state_machines.zig",
        "core/types.zig",
        "core/vfs.zig",
        "dev/commit_msg_validator.zig",
        "dev/debug_allocator.zig",
        "dev/test_discovery.zig",
        "dev/shell.zig",
        "dev/tidy.zig",
        "ingestion/ingest_directory.zig",
        "ingestion/zig/parser.zig",
        "kausaldb.zig",
        "query/cache.zig",
        "query/context_query.zig",
        "query/context/engine.zig",
        "query/engine.zig",
        "query/filtering.zig",
        "server/connection_manager.zig",
        "server/handler.zig",
        "sim/hostile_vfs.zig",
        "sim/simulation_vfs.zig",
        "sim/simulation.zig",
        "storage/batch_writer.zig",
        "storage/block_index.zig",
        "storage/bloom_filter.zig",
        "storage/config.zig",
        "storage/engine.zig",
        "storage/graph_edge_index.zig",
        "storage/memtable_manager.zig",
        "storage/metadata_index.zig",
        "storage/metrics.zig",
        "storage/recovery.zig",
        "storage/sstable.zig",
        "storage/sstable_manager.zig",
        "storage/tiered_compaction.zig",
        "storage/validation.zig",
        "storage/wal.zig",
        "storage/wal/core.zig",
        "storage/wal/corruption_tracker.zig",
        "storage/wal/entry.zig",
        "storage/wal/recovery.zig",
        "storage/wal/stream.zig",
        "storage/wal/types.zig",
        "testing/defensive.zig",
        "testing/property_testing.zig",
        "testing/systematic_fuzzing.zig",
    };

    var result = try allocator.alloc([]const u8, unit_test_files.len);
    for (unit_test_files, 0..) |file, i| {
        result[i] = try allocator.dupe(u8, file);
    }
    return result;
}

/// Find all integration test files (hardcoded list)
pub fn find_integration_test_files(allocator: std.mem.Allocator) ![][]const u8 {
    const integration_test_files = [_][]const u8{
        "tests/batch/batch_integration.zig",
        "tests/batch/deduplication.zig",
        "tests/benchmark/benchmark_harness.zig",
        "tests/benchmark/bounded_collections.zig",
        "tests/benchmark/context_query.zig",
        "tests/benchmark/engine.zig",
        "tests/benchmark/graph_traversal.zig",
        "tests/benchmark/ingestion.zig",
        "tests/benchmark/memory.zig",
        "tests/benchmark/simulation.zig",
        "tests/benchmark/storage.zig",
        "tests/benchmark/wal.zig",
        "tests/corpus/corpus_fixture.zig",
        "tests/corpus/go_project.zig",
        "tests/corpus/ingestion.zig",
        "tests/corpus/rust_project.zig",
        "tests/corpus/typescript_project.zig",
        "tests/corpus/zig_project.zig",
        "tests/dev/build_system.zig",
        "tests/dev/ci_environment.zig",
        "tests/dev/tidy_validation.zig",
        "tests/fuzzing/block_mutation.zig",
        "tests/fuzzing/bounded_collections.zig",
        "tests/fuzzing/edge_cases.zig",
        "tests/fuzzing/simulation.zig",
        "tests/fuzzing/storage_corruption.zig",
        "tests/ingestion/file_discovery.zig",
        "tests/ingestion/git_analysis.zig",
        "tests/ingestion/large_files.zig",
        "tests/ingestion/typescript_imports.zig",
        "tests/ingestion/workspace_management.zig",
        "tests/ingestion/zig_integration.zig",
        "tests/memory/allocation_patterns.zig",
        "tests/memory/arena_coordinator.zig",
        "tests/memory/leak_detection.zig",
        "tests/query/batch_queries.zig",
        "tests/query/context_engine.zig",
        "tests/query/edge_traversal.zig",
        "tests/query/filtering.zig",
        "tests/query/graph_construction.zig",
        "tests/query/performance.zig",
        "tests/query/workspace_isolation.zig",
        "tests/simulation/corruption_scenarios.zig",
        "tests/simulation/hostile_environment.zig",
        "tests/simulation/network_partitions.zig",
        "tests/simulation/power_loss.zig",
        "tests/simulation/recovery_scenarios.zig",
        "tests/storage/batch_writes.zig",
        "tests/storage/block_index.zig",
        "tests/storage/compaction.zig",
        "tests/storage/concurrent_access.zig",
        "tests/storage/corruption_detection.zig",
        "tests/storage/engine.zig",
        "tests/storage/large_datasets.zig",
        "tests/storage/recovery.zig",
        "tests/storage/sstable.zig",
        "tests/storage/wal.zig",
        "tests/stress/allocator_torture.zig",
        "tests/stress/arena_safety.zig",
        "tests/stress/memory_fault_injection.zig",
        "tests/stress/memory_pressure.zig",
        "tests/stress/storage_load.zig",
        "tests/vfs/vfs_integration.zig",
        "tests/scenarios/batch_deduplication.zig",
        "tests/scenarios/corrupted_sstable_recovery.zig",
        "tests/scenarios/missing_edges_traversal.zig",
        "tests/scenarios/workspace_isolation.zig",
    };

    var result = try allocator.alloc([]const u8, integration_test_files.len);
    for (integration_test_files, 0..) |file, i| {
        result[i] = try allocator.dupe(u8, file);
    }
    return result;
}

/// Find all E2E test files (hardcoded list)
pub fn find_e2e_test_files(allocator: std.mem.Allocator) ![][]const u8 {
    const e2e_test_files = [_][]const u8{
        "e2e/basic_operations.zig",
        "e2e/cli_interface.zig",
        "e2e/performance.zig",
        "e2e/recovery.zig",
    };

    var result = try allocator.alloc([]const u8, e2e_test_files.len);
    for (e2e_test_files, 0..) |file, i| {
        result[i] = try allocator.dupe(u8, file);
    }
    return result;
}

/// Check if actual imports match expected imports in registry file
pub fn validate_imports(allocator: std.mem.Allocator, registry_path: []const u8, expected_files: [][]const u8) !bool {
    const file = std.fs.cwd().openFile(registry_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var missing_count: usize = 0;

    // Check each expected file is imported
    for (expected_files) |expected| {
        const import_line = try std.fmt.allocPrint(allocator, "@import(\"{s}\")", .{expected});
        defer allocator.free(import_line);

        if (std.mem.indexOf(u8, content, import_line) == null) {
            missing_count += 1;
        }
    }

    return missing_count == 0;
}

test "simple test discovery" {
    const allocator = std.testing.allocator;

    // Test unit files
    const unit_files = try find_unit_test_files(allocator);
    defer {
        for (unit_files) |file| {
            allocator.free(file);
        }
        allocator.free(unit_files);
    }

    try std.testing.expect(unit_files.len > 0);

    // Test integration files
    const integration_files = try find_integration_test_files(allocator);
    defer {
        for (integration_files) |file| {
            allocator.free(file);
        }
        allocator.free(integration_files);
    }

    try std.testing.expect(integration_files.len > 0);
}
