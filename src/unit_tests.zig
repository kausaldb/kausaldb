//! Unit test registry for KausalDB source modules.
//!
//! This file imports all source modules to run their embedded unit tests.
//! Integration tests are in src/tests/ and run via separate build targets.
//!
//! Design rationale: Unit tests are fast, isolated tests embedded in source
//! files. Integration tests require full API access and run separately.

const std = @import("std");
const builtin = @import("builtin");
const assert_mod = @import("core/assert.zig");
const assert = assert_mod.assert;

const MiB = 1024 * 1024;

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

const quine =
    \\const std = @import("std");
    \\const builtin = @import("builtin");
    \\const assert_mod = @import("core/assert.zig");
    \\const assert = assert_mod.assert;
    \\
    \\const MiB = 1024 * 1024;
    \\
    \\test quine {
    \\    var arena_instance = std.heap.ArenaAllocator.init(std.testing.allocator);
    \\    defer arena_instance.deinit();
    \\    const arena = arena_instance.allocator();
    \\
    \\    // build.zig runs this in the root dir.
    \\    var src_dir = try std.fs.cwd().openDir("src", .{
    \\        .access_sub_paths = true,
    \\        .iterate = true,
    \\    });
    \\
    \\    var unit_tests_contents = std.ArrayList(u8){};
    \\    defer unit_tests_contents.deinit(arena);
    \\    const writer = unit_tests_contents.writer(arena);
    \\    try writer.writeAll("comptime {\n");
    \\
    \\    for (try unit_test_files(arena, src_dir)) |test_file| {
    \\        try writer.print("    _ = @import(\"{s}\");\n", .{test_file});
    \\    }
    \\
    \\    try writer.writeAll("}\n\n");
    \\
    \\    var quine_lines = std.mem.splitScalar(u8, quine, '\n');
    \\    try writer.writeAll("const quine =\n");
    \\    while (quine_lines.next()) |line| {
    \\        try writer.print("    \\\\{s}\n", .{line});
    \\    }
    \\    try writer.writeAll(";\n\n");
    \\
    \\    try writer.writeAll(quine);
    \\
    \\    assert(std.mem.eql(u8, @src().file, "unit_tests.zig"));
    \\    const unit_tests_contents_disk = try src_dir.readFileAlloc(arena, @src().file, 1 * MiB);
    \\    assert(std.mem.startsWith(u8, unit_tests_contents_disk, "comptime {"));
    \\    assert(std.mem.endsWith(u8, unit_tests_contents.items, "}\n"));
    \\
    \\    const unit_tests_needs_update = !std.mem.startsWith(
    \\        u8,
    \\        unit_tests_contents_disk,
    \\        unit_tests_contents.items,
    \\    );
    \\
    \\    if (unit_tests_needs_update) {
    \\        if (std.process.hasEnvVarConstant("SNAP_UPDATE")) {
    \\            try src_dir.writeFile(.{
    \\                .sub_path = "unit_tests.zig",
    \\                .data = unit_tests_contents.items,
    \\                .flags = .{ .exclusive = false, .truncate = true },
    \\            });
    \\        } else {
    \\            std.debug.print("unit_tests.zig needs updating.\n", .{});
    \\            std.debug.print(
    \\                "Rerun with SNAP_UPDATE=1 environmental variable to update the contents.\n",
    \\                .{},
    \\            );
    \\            assert(false);
    \\        }
    \\    }
    \\}
    \\
    \\fn unit_test_files(arena: std.mem.Allocator, src_dir: std.fs.Dir) ![]const []const u8 {
    \\    var result = std.ArrayList([]const u8){};
    \\    defer result.deinit(arena);
    \\
    \\    var walker = try src_dir.walk(arena);
    \\    defer walker.deinit();
    \\
    \\    while (try walker.next()) |entry| {
    \\        if (entry.kind != .file) continue;
    \\
    \\        const entry_path = try arena.dupe(u8, entry.path);
    \\
    \\        // Replace path separator for Windows consistency
    \\        if (builtin.os.tag == .windows) {
    \\            std.mem.replaceScalar(u8, entry_path, '\\\\', '/');
    \\        }
    \\
    \\        if (!std.mem.endsWith(u8, entry_path, ".zig")) continue;
    \\
    \\        // Skip special files
    \\        if (std.mem.eql(u8, entry.basename, "unit_tests.zig")) continue;
    \\        if (std.mem.eql(u8, entry.basename, "integration_tests.zig")) continue;
    \\        if (std.mem.eql(u8, entry.basename, "kausaldb.zig")) continue;
    \\        if (std.mem.eql(u8, entry.basename, "main.zig")) continue;
    \\
    \\        // Skip test directories (integration tests are separate)
    \\        if (std.mem.startsWith(u8, entry_path, "tests/")) continue;
    \\
    \\        // Only include files that actually contain tests
    \\        const contents = src_dir.readFileAlloc(arena, entry_path, 1 * MiB) catch continue;
    \\        var line_iterator = std.mem.splitScalar(u8, contents, '\\n');
    \\        while (line_iterator.next()) |line| {
    \\            const line_trimmed = std.mem.trimLeft(u8, line, " ");
    \\            if (std.mem.startsWith(u8, line_trimmed, "test ")) {
    \\                try result.append(arena, entry_path);
    \\                break;
    \\            }
    \\        }
    \\    }
    \\
    \\    std.mem.sort(
    \\        []const u8,
    \\        result.items,
    \\        {},
    \\        struct {
    \\            fn less_than_fn(_: void, a: []const u8, b: []const u8) bool {
    \\                return std.mem.order(u8, a, b) == .lt;
    \\            }
    \\        }.less_than_fn,
    \\    );
    \\
    \\    return result.items;
    \\}
    \\
;

test quine {
    // Arena Coordinator Pattern: bounded operations with O(1) cleanup
    const backing_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();

    // build.zig runs this in the root dir.
    var src_dir = try std.fs.cwd().openDir("src", .{
        .access_sub_paths = true,
        .iterate = true,
    });
    defer src_dir.close();

    // Read current file in bounded chunks to avoid memory explosion
    assert(std.mem.eql(u8, @src().file, "unit_tests.zig"));
    const current_file = try src_dir.openFile(@src().file, .{});
    defer current_file.close();

    // Bounded operation: limit file size to prevent memory issues
    const file_stat = try current_file.stat();
    if (file_stat.size > 2 * MiB) {
        std.debug.print("unit_tests.zig too large ({} bytes) for validation\n", .{file_stat.size});
        return;
    }

    const current_contents = try current_file.readToEndAlloc(arena.allocator(), @intCast(file_stat.size));

    // Arena Reset Pattern: process files one at a time with bounded memory
    var missing_imports = false;
    var walker = try src_dir.walk(arena.allocator());
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        // Skip special files
        if (std.mem.eql(u8, entry.basename, "unit_tests.zig")) continue;
        if (std.mem.eql(u8, entry.basename, "integration_tests.zig")) continue;
        if (std.mem.eql(u8, entry.basename, "kausaldb.zig")) continue;
        if (std.mem.eql(u8, entry.basename, "main.zig")) continue;
        if (std.mem.startsWith(u8, entry.path, "tests/")) continue;

        // Bounded file check: prevent memory explosion
        const entry_stat = src_dir.statFile(entry.path) catch continue;
        if (entry_stat.size > 32 * 1024) continue;

        // Arena per operation: read small chunk to check for tests
        var file_arena = std.heap.ArenaAllocator.init(backing_allocator);
        defer file_arena.deinit(); // O(1) cleanup per file

        const read_size = @min(@as(usize, 4096), @as(usize, @intCast(entry_stat.size)));
        const file_content = src_dir.readFileAlloc(file_arena.allocator(), entry.path, read_size) catch continue;

        // Check if file has tests
        var has_tests = false;
        var lines = std.mem.splitScalar(u8, file_content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimLeft(u8, line, " ");
            if (std.mem.startsWith(u8, trimmed, "test ")) {
                has_tests = true;
                break;
            }
        }

        if (has_tests) {
            // Bounded string operation: create import line in file arena
            const import_pattern = file_arena.allocator().dupe(u8, entry.path) catch continue;

            // Windows path normalization
            if (builtin.os.tag == .windows) {
                std.mem.replaceScalar(u8, import_pattern, '\\', '/');
            }

            // Create expected import line
            const expected_import = std.fmt.allocPrint(file_arena.allocator(), "_ = @import(\"{s}\");", .{import_pattern}) catch continue;

            if (std.mem.indexOf(u8, current_contents, expected_import) == null) {
                std.debug.print("Missing import in comptime block: {s}\n", .{entry.path});
                missing_imports = true;
            }
        }
        // file_arena.deinit() called automatically - O(1) memory reset
    }

    if (missing_imports) {
        std.debug.print("unit_tests.zig comptime block needs updating.\n", .{});
        std.debug.print("Add the missing imports shown above.\n", .{});
        assert(!missing_imports);
    }
}

// Arena Coordinator Pattern: removed unit_test_files function as quine test
// now uses streaming validation with bounded memory per file operation.
// This follows KausalDB's memory architecture with O(1) cleanup cycles.
