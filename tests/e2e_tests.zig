//! End-to-end test registry for binary interface tests.
//!
//! This file imports all e2e test modules to run binary interface
//! validation through subprocess execution.

const std = @import("std");

comptime {
    _ = @import("e2e/harness.zig");
    _ = @import("e2e/core_cli.zig");
    _ = @import("e2e/workspace.zig");
    _ = @import("e2e/query.zig");
    _ = @import("e2e/errors.zig");
    _ = @import("e2e/shell.zig");
    _ = @import("e2e/storage.zig");
    _ = @import("e2e/harness.zig");
}

const MiB = 1 << 20;

test "e2e test registry is up to date" {
    const allocator = std.testing.allocator;

    const this_file = try std.fs.cwd().readFileAlloc(allocator, "tests/e2e_tests.zig", 1 * MiB);
    defer allocator.free(this_file);

    var test_dir = try std.fs.cwd().openDir("tests/e2e", .{ .iterate = true });
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

        const import_line = try std.fmt.allocPrint(allocator, "_ = @import(\"e2e/{s}\");", .{entry.path});
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
        std.debug.print("\nMissing test imports in tests/e2e_tests.zig:\n", .{});
        for (missing.items) |path| {
            std.debug.print("    _ = @import(\"e2e/{s}\");\n", .{path});
        }
        return error.TestRegistryIncomplete;
    }
}
