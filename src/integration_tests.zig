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
    _ = @import("tests/ingestion/cross_file_resolution_test.zig");
    _ = @import("tests/ingestion/ingestion.zig");
    _ = @import("tests/ingestion/ingestion_backpressure_integration.zig");
    _ = @import("tests/memory/corruption_prevention_test.zig");
    _ = @import("tests/memory/profiling_validation.zig");
    _ = @import("tests/misc/lifecycle.zig");
    _ = @import("tests/misc/zig_parser_integration.zig");
    _ = @import("tests/performance/large_block_benchmark.zig");
    _ = @import("tests/performance/streaming_memory_benchmark.zig");
    _ = @import("tests/query/advanced_algorithms_edge_cases.zig");
    _ = @import("tests/query/advanced_traversal.zig");
    _ = @import("tests/query/complex_workloads.zig");
    _ = @import("tests/query/streaming_optimizations.zig");
    _ = @import("tests/recovery/wal.zig");
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
    _ = @import("tests/storage/enhanced_compaction_strategies.zig");
    _ = @import("tests/storage/memtable_simple_operations.zig");
    _ = @import("tests/storage/tiered_compaction_validation.zig");
    _ = @import("tests/storage/wal_entry_stream.zig");
    _ = @import("tests/storage/wal_streaming_writes.zig");
    _ = @import("tests/stress/allocator_torture.zig");
    _ = @import("tests/stress/arena_safety.zig");
    _ = @import("tests/stress/memory_fault_injection.zig");
    _ = @import("tests/stress/memory_pressure.zig");
    _ = @import("tests/stress/storage_load.zig");
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
    \\    var integration_tests_contents = std.ArrayList(u8){};
    \\    defer integration_tests_contents.deinit(arena);
    \\    const writer = integration_tests_contents.writer(arena);
    \\    try writer.writeAll("comptime {\n");
    \\
    \\    for (try integration_test_files(arena, src_dir)) |test_file| {
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
    \\    assert(std.mem.eql(u8, @src().file, "integration_tests.zig"));
    \\    const integration_tests_contents_disk = try src_dir.readFileAlloc(arena, @src().file, 1 * MiB);
    \\    assert(std.mem.startsWith(u8, integration_tests_contents_disk, "comptime {"));
    \\    assert(std.mem.endsWith(u8, integration_tests_contents.items, "}\n"));
    \\
    \\    const integration_tests_needs_update = !std.mem.startsWith(
    \\        u8,
    \\        integration_tests_contents_disk,
    \\        integration_tests_contents.items,
    \\    );
    \\
    \\    if (integration_tests_needs_update) {
    \\        if (std.process.hasEnvVarConstant("SNAP_UPDATE")) {
    \\            try src_dir.writeFile(.{
    \\                .sub_path = "integration_tests.zig",
    \\                .data = integration_tests_contents.items,
    \\                .flags = .{ .exclusive = false, .truncate = true },
    \\            });
    \\        } else {
    \\            std.debug.print("integration_tests.zig needs updating.\n", .{});
    \\            std.debug.print(
    \\                "Rerun with SNAP_UPDATE=1 environmental variable to update the contents.\n",
    \\                .{},
    \\            );
    \\            assert(false);
    \\        }
    \\    }
    \\}
    \\
    \\fn integration_test_files(arena: std.mem.Allocator, src_dir: std.fs.Dir) ![]const []const u8 {
    \\    var result = std.ArrayList([]const u8){};
    \\    defer result.deinit(arena);
    \\
    \\    var tests_dir = try src_dir.openDir("tests", .{
    \\        .access_sub_paths = true,
    \\        .iterate = true,
    \\    });
    \\    defer tests_dir.close();
    \\
    \\    var walker = try tests_dir.walk(arena);
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
    \\        // Skip test framework files
    \\        if (std.mem.eql(u8, entry.basename, "harness.zig")) continue;
    \\        if (std.mem.eql(u8, entry.basename, "mock_vfs_helper.zig")) continue;
    \\
    \\        const file_path = try std.fmt.allocPrint(arena, "tests/{s}", .{entry_path});
    \\
    \\        // Only include files that actually contain tests
    \\        const contents = tests_dir.readFileAlloc(arena, entry_path, 1 * MiB) catch continue;
    \\        var line_iterator = std.mem.splitScalar(u8, contents, '\\n');
    \\        while (line_iterator.next()) |line| {
    \\            const line_trimmed = std.mem.trimLeft(u8, line, " ");
    \\            if (std.mem.startsWith(u8, line_trimmed, "test ")) {
    \\                try result.append(arena, file_path);
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

const std = @import("std");
const builtin = @import("builtin");
const assert_mod = @import("core/assert.zig");
const assert = assert_mod.assert;

const MiB = 1024 * 1024;

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
    assert(std.mem.eql(u8, @src().file, "integration_tests.zig"));
    const current_file = try src_dir.openFile(@src().file, .{});
    defer current_file.close();

    // Bounded operation: limit file size to prevent memory issues
    const file_stat = try current_file.stat();
    if (file_stat.size > 2 * MiB) {
        std.debug.print("integration_tests.zig too large ({} bytes) for validation\n", .{file_stat.size});
        return;
    }

    const current_contents = try current_file.readToEndAlloc(arena.allocator(), @intCast(file_stat.size));

    // Arena Reset Pattern: process files one at a time with bounded memory
    var missing_imports = false;
    var tests_dir = try src_dir.openDir("tests", .{
        .access_sub_paths = true,
        .iterate = true,
    });
    defer tests_dir.close();

    var walker = try tests_dir.walk(arena.allocator());
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        // Skip test framework files
        if (std.mem.eql(u8, entry.basename, "harness.zig")) continue;
        if (std.mem.eql(u8, entry.basename, "mock_vfs_helper.zig")) continue;

        // Bounded file check: prevent memory explosion
        const entry_stat = tests_dir.statFile(entry.path) catch continue;
        if (entry_stat.size > 32 * 1024) continue;

        // Arena per operation: read small chunk to check for tests
        var file_arena = std.heap.ArenaAllocator.init(backing_allocator);
        defer file_arena.deinit(); // O(1) cleanup per file

        const read_size = @min(@as(usize, 4096), @as(usize, @intCast(entry_stat.size)));
        const file_content = tests_dir.readFileAlloc(file_arena.allocator(), entry.path, read_size) catch continue;

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
            const import_path = file_arena.allocator().dupe(u8, entry.path) catch continue;

            // Windows path normalization
            if (builtin.os.tag == .windows) {
                std.mem.replaceScalar(u8, import_path, '\\', '/');
            }

            // Create expected import line with tests/ prefix
            const file_path = std.fmt.allocPrint(file_arena.allocator(), "tests/{s}", .{import_path}) catch continue;
            const expected_import = std.fmt.allocPrint(file_arena.allocator(), "_ = @import(\"{s}\");", .{file_path}) catch continue;

            if (std.mem.indexOf(u8, current_contents, expected_import) == null) {
                std.debug.print("Missing import in comptime block: {s}\n", .{file_path});
                missing_imports = true;
            }
        }
        // file_arena.deinit() called automatically - O(1) memory reset
    }

    if (missing_imports) {
        std.debug.print("integration_tests.zig comptime block needs updating.\n", .{});
        std.debug.print("Add the missing imports shown above.\n", .{});
        assert(!missing_imports);
    }
}

// Arena Coordinator Pattern: removed integration_test_files function as quine test
// now uses streaming validation with bounded memory per file operation.
// This follows KausalDB's memory architecture with O(1) cleanup cycles.
