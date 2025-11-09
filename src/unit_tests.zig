//! Unit test registry for fast, isolated module tests.
//!
//! This file imports source modules to run their embedded unit tests.
//! Tests are deterministic, single-threaded, and validate individual components.

const std = @import("std");

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
    _ = @import("dev/hooks.zig");
    _ = @import("dev/tidy.zig");
    _ = @import("ingestion/ingest_file.zig");
    _ = @import("ingestion/ingest_directory.zig");
    _ = @import("ingestion/parsers/zig_parser.zig");
    _ = @import("ingestion/semantic_resolver.zig");
    _ = @import("kausaldb.zig");
    _ = @import("query/cache.zig");
    _ = @import("query/context_query.zig");
    _ = @import("query/context/engine.zig");
    _ = @import("query/engine.zig");
    _ = @import("query/filtering.zig");
    _ = @import("query/traversal.zig");
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
    _ = @import("storage/sstable_index_cache.zig");
    _ = @import("storage/sstable_manager.zig");
    _ = @import("storage/tiered_compaction.zig");
    _ = @import("storage/tombstone.zig");
    _ = @import("storage/validation.zig");
    _ = @import("storage/wal.zig");
    _ = @import("storage/wal/core.zig");
    _ = @import("storage/wal/corruption_tracker.zig");
    _ = @import("storage/wal/entry.zig");
    _ = @import("storage/wal/recovery.zig");
    _ = @import("storage/wal/stream.zig");
    _ = @import("storage/wal/types.zig");
    _ = @import("testing/block_lifecycle_tracker.zig");
    _ = @import("testing/harness.zig");
    _ = @import("testing/model.zig");
    _ = @import("testing/performance_assertions.zig");
    _ = @import("testing/properties.zig");
    _ = @import("testing/workload.zig");
    _ = @import("workspace/manager.zig");
}

const MiB = 1 << 20;

test "unit test registry is up to date" {
    const allocator = std.testing.allocator;

    const this_file = try std.fs.cwd().readFileAlloc(allocator, "src/unit_tests.zig", 1 * MiB);
    defer allocator.free(this_file);

    var test_dir = try std.fs.cwd().openDir("src", .{ .iterate = true });
    defer test_dir.close();

    var walker = try test_dir.walk(allocator);
    defer walker.deinit();

    var missing = std.ArrayList([]const u8){};
    defer {
        for (missing.items) |item| allocator.free(item);
        missing.deinit(allocator);
    }

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        if (std.mem.eql(u8, entry.path, "unit_tests.zig")) continue;
        if (std.mem.eql(u8, entry.path, "integration_tests.zig")) continue;
        if (std.mem.startsWith(u8, entry.path, "tests/")) continue;

        const content = try test_dir.readFileAlloc(allocator, entry.path, 1 * MiB);
        defer allocator.free(content);

        var has_test = false;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimLeft(u8, line, " ");
            if (std.mem.startsWith(u8, trimmed, "test ")) {
                has_test = true;
                break;
            }
        }

        if (!has_test) continue;

        const import_line = try std.fmt.allocPrint(allocator, "_ = @import(\"{s}\");", .{entry.path});
        defer allocator.free(import_line);

        var found = false;
        var file_lines = std.mem.splitScalar(u8, this_file, '\n');
        while (file_lines.next()) |file_line| {
            const trimmed_line = std.mem.trimLeft(u8, file_line, " \t");
            if (std.mem.indexOf(u8, trimmed_line, import_line)) |_| {
                if (!std.mem.startsWith(u8, trimmed_line, "//")) {
                    found = true;
                    break;
                }
            }
        }

        if (!found) {
            try missing.append(allocator, try allocator.dupe(u8, entry.path));
        }
    }

    if (missing.items.len > 0) {
        std.debug.print("\nMissing test imports in src/unit_tests.zig:\n", .{});
        for (missing.items) |path| {
            std.debug.print("    _ = @import(\"{s}\");\n", .{path});
        }
        return error.TestRegistryIncomplete;
    }
}
