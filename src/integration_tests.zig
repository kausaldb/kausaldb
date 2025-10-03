//! Integration test registry for multi-component interaction tests.
//!
//! This file imports tests that exercise full API workflows and component integration.
//! Tests use deterministic simulation framework to verify correctness and invariants.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const std_options = .{
    .log_level = build_options.log_level,
};

comptime {
    // Scenarios
    _ = @import("tests/scenarios/storage.zig");
    _ = @import("tests/scenarios/component.zig");
    _ = @import("tests/scenarios/query.zig");
    _ = @import("tests/scenarios/ingestion.zig");
    _ = @import("tests/scenarios/vfs_fault.zig");
    _ = @import("tests/scenarios/storage_correctness.zig");
    _ = @import("tests/scenarios/graph_traversal.zig");
    _ = @import("tests/scenarios/deletion_compaction.zig");
    _ = @import("tests/scenarios/edge_persistence.zig");
    _ = @import("tests/scenarios/tombstone_sequencing.zig");
    _ = @import("tests/scenarios/cli_integration.zig");
    _ = @import("tests/scenarios/explicit_correctness.zig");

    // Regression tests (keeps bugs fixed)
    _ = @import("tests/regression/regression.zig");

    // Other tests
    _ = @import("tests/cli_output_rendering_test.zig");
}

const MiB = 1 << 20;

test "integration test registry is up to date" {
    const allocator = std.testing.allocator;

    const this_file = try std.fs.cwd().readFileAlloc(allocator, "src/integration_tests.zig", 1 * MiB);
    defer allocator.free(this_file);

    var test_dir = try std.fs.cwd().openDir("src/tests", .{ .iterate = true });
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

        const import_line = try std.fmt.allocPrint(allocator, "_ = @import(\"tests/{s}\");", .{entry.path});
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
        std.debug.print("\nMissing test imports in src/integration_tests.zig:\n", .{});
        for (missing.items) |path| {
            std.debug.print("    _ = @import(\"tests/{s}\");\n", .{path});
        }
        return error.TestRegistryIncomplete;
    }
}
