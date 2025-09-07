//! Unit test registry for KausalDB source modules.
//!
//! This file imports all source modules to run their embedded unit tests.
//! Integration tests are in src/tests/ and run via separate build targets.
//!
//! Design rationale: Unit tests are fast, isolated tests embedded in source
//! files. Integration tests require full API access and run separately.

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
    // CLI modules
    _ = @import("cli/natural_commands.zig");
    _ = @import("cli/natural_executor.zig");

    // Core modules
    _ = @import("core/arena.zig");
    _ = @import("core/assert.zig");
    _ = @import("core/bounded.zig");
    _ = @import("core/concurrency.zig");
    _ = @import("core/error_context.zig");
    _ = @import("core/file_handle.zig");
    _ = @import("core/memory.zig");
    _ = @import("core/ownership.zig");
    _ = @import("core/pools.zig");
    _ = @import("core/production_vfs.zig");
    _ = @import("core/signals.zig");
    _ = @import("core/state_machines.zig");
    _ = @import("core/types.zig");
    _ = @import("core/vfs.zig");

    // Dev modules
    _ = @import("dev/commit_msg_validator.zig");
    _ = @import("dev/debug_allocator.zig");
    // _ = @import("dev/fuzz/common.zig"); // Excluded to avoid module conflicts - fuzz tests run separately
    _ = @import("dev/git_test_discovery.zig");
    _ = @import("dev/shell.zig");
    _ = @import("dev/tidy.zig");

    // Ingestion modules
    _ = @import("ingestion/ingest_directory.zig");
    _ = @import("ingestion/zig/parser.zig");

    // Main module
    _ = @import("kausaldb.zig");

    // Query modules
    _ = @import("query/cache.zig");
    _ = @import("query/context_query.zig");
    _ = @import("query/context/engine.zig");
    _ = @import("query/engine.zig");
    _ = @import("query/filtering.zig");

    // Server modules
    _ = @import("server/connection_manager.zig");
    _ = @import("server/handler.zig");

    // Simulation modules
    _ = @import("sim/hostile_vfs.zig");
    _ = @import("sim/simulation_vfs.zig");
    _ = @import("sim/simulation.zig");

    // Storage modules
    _ = @import("storage/batch_writer.zig");
    _ = @import("storage/block_index.zig");
    _ = @import("storage/bloom_filter.zig");
    _ = @import("storage/config.zig");
    _ = @import("storage/engine.zig");
    _ = @import("storage/graph_edge_index.zig");
    _ = @import("storage/memtable_manager.zig");
    _ = @import("storage/metadata_index.zig");
    _ = @import("storage/metrics.zig");
    _ = @import("storage/recovery.zig");
    _ = @import("storage/sstable.zig");
    _ = @import("storage/sstable_manager.zig");
    _ = @import("storage/tiered_compaction.zig");
    _ = @import("storage/validation.zig");
    _ = @import("storage/wal.zig");

    // Storage WAL modules
    _ = @import("storage/wal/core.zig");
    _ = @import("storage/wal/corruption_tracker.zig");
    _ = @import("storage/wal/entry.zig");
    _ = @import("storage/wal/recovery.zig");
    _ = @import("storage/wal/stream.zig");
    _ = @import("storage/wal/types.zig");

    // Testing modules
    _ = @import("testing/defensive.zig");
    _ = @import("testing/property_testing.zig");
    _ = @import("testing/systematic_fuzzing.zig");
}

test "unit test discovery - informational scan for new test files" {
    const git_discovery = @import("dev/git_test_discovery.zig");

    const expected_files = git_discovery.find_unit_test_files(std.testing.allocator) catch |err| {
        std.debug.print("Git discovery failed ({}), skipping scan\n", .{err});
        return;
    };
    defer {
        for (expected_files) |file| {
            std.testing.allocator.free(file);
        }
        std.testing.allocator.free(expected_files);
    }

    // Files that are intentionally excluded due to compilation issues or alternative coverage
    const excluded_files = &[_][]const u8{
        // Scenario files with import path issues, covered by integration scenarios_test.zig
        "tests/scenarios/batch_deduplication.zig",
        "tests/scenarios/corrupted_sstable_recovery.zig",
        "tests/scenarios/missing_edges_traversal.zig",
        "tests/scenarios/torn_wal_recovery.zig",
        "tests/scenarios/workspace_isolation.zig",
        // Fuzz modules excluded to avoid conflicts - run separately
        "dev/fuzz/common.zig",
    };

    const is_valid = git_discovery.validate_imports_with_exclusions(std.testing.allocator, "src/unit_tests.zig", expected_files, excluded_files) catch |err| {
        std.debug.print("Import validation failed ({}), skipping\n", .{err});
        return;
    };

    if (!is_valid) {
        std.debug.print("\n[INFO] New test files detected (may need manual review):\n", .{});
        for (expected_files) |file| {
            std.debug.print("  Candidate: {s}\n", .{file});
        }
        std.debug.print("Review files for compilation errors before adding to unit_tests.zig\n", .{});
    } else {
        std.debug.print("Unit test discovery: {d} files validated\n", .{expected_files.len});
    }
}
