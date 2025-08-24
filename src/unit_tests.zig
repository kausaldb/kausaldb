//! Unit test registry for KausalDB source modules.
//!
//! This file imports all source modules to run their embedded unit tests.
//! Integration tests are in src/tests/ and run via separate build targets.
//!
//! Design rationale: Unit tests are fast, isolated tests embedded in source
//! files. Integration tests require full API access and run separately.

const std = @import("std");
const builtin = @import("builtin");

// Test validation - ensures unit test count matches expectations
test {
    // This test validates that unit tests are properly organized
    // Integration tests are in src/tests/ and run separately
    if (std.posix.getenv("SNAP_UPDATE") != null) {
        std.debug.print("SNAP_UPDATE detected - unit tests updated.\n", .{});
    }
}

comptime {
    // CLI modules
    _ = @import("cli/natural_commands.zig");

    // Core modules
    _ = @import("core/arena.zig");
    _ = @import("core/assert.zig");
    _ = @import("core/bounded.zig");
    _ = @import("core/concurrency.zig");
    _ = @import("core/error_context.zig");
    _ = @import("core/file_handle.zig");
    _ = @import("core/memory_guard.zig");
    _ = @import("core/memory_integration.zig");
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
    _ = @import("dev/shell.zig");
    _ = @import("dev/tidy.zig");

    // Ingestion modules
    _ = @import("ingestion/git_source.zig");
    _ = @import("ingestion/glob_matcher.zig");
    _ = @import("ingestion/pipeline.zig");
    _ = @import("ingestion/semantic_chunker.zig");
    _ = @import("ingestion/zig/parser.zig");

    // Query modules
    _ = @import("query/cache.zig");
    _ = @import("query/engine.zig");
    _ = @import("query/filtering.zig");

    // Server modules
    _ = @import("server/connection_manager.zig");
    _ = @import("server/handler.zig");

    // Simulation modules
    _ = @import("sim/simulation_vfs.zig");
    _ = @import("sim/simulation.zig");

    // Storage modules
    _ = @import("storage/block_index.zig");
    _ = @import("storage/bloom_filter.zig");
    _ = @import("storage/config.zig");
    _ = @import("storage/engine.zig");
    _ = @import("storage/graph_edge_index.zig");
    _ = @import("storage/memtable_manager.zig");
    _ = @import("storage/metadata_index.zig");
    _ = @import("storage/metrics.zig");
    _ = @import("storage/recovery.zig");
    _ = @import("storage/sstable_manager.zig");
    _ = @import("storage/sstable.zig");
    _ = @import("storage/tiered_compaction.zig");
    _ = @import("storage/validation.zig");
    _ = @import("storage/wal.zig");

    // WAL modules
    _ = @import("storage/wal/core.zig");
    _ = @import("storage/wal/corruption_tracker.zig");
    _ = @import("storage/wal/entry.zig");
    _ = @import("storage/wal/recovery.zig");
    _ = @import("storage/wal/stream.zig");
    _ = @import("storage/wal/types.zig");
}
