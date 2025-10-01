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

pub const std_options = .{
    .log_level = build_options.log_level,
};

comptime {
    _ = @import("core/arena.zig");

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
    _ = @import("cli/client.zig");
    _ = @import("cli/parser.zig");
    _ = @import("cli/protocol.zig");
    _ = @import("dev/debug_allocator.zig");
    _ = @import("dev/tidy.zig");
    _ = @import("ingestion/ingest_directory.zig");
    _ = @import("ingestion/zig/parser.zig");
    _ = @import("kausaldb.zig");
    _ = @import("query/cache.zig");
    _ = @import("query/context_query.zig");
    _ = @import("query/context/engine.zig");
    _ = @import("query/engine.zig");
    _ = @import("query/filtering.zig");
    _ = @import("server/cli_protocol.zig");
    _ = @import("server/config.zig");
    _ = @import("server/connection.zig");
    _ = @import("server/connection_manager.zig");
    _ = @import("server/coordinator.zig");
    _ = @import("server/daemon.zig");
    _ = @import("server/network_server.zig");
    _ = @import("sim/simulation_vfs.zig");
    _ = @import("sim/simulation.zig");
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
    _ = @import("storage/wal/core.zig");
    _ = @import("storage/wal/corruption_tracker.zig");
    _ = @import("storage/wal/entry.zig");
    _ = @import("storage/wal/recovery.zig");
    _ = @import("storage/wal/stream.zig");
    _ = @import("storage/wal/types.zig");
}
