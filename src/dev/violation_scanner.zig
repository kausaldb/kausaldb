//! Detailed violation scanner to identify specific files and locations
//! for systematic ownership violation fixes.

const std = @import("std");

const log = std.log.scoped(.violation_scanner);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    log.info("Scanning for specific ownership violations...", .{});

    try scan_for_violations(allocator);
}

fn scan_for_violations(allocator: std.mem.Allocator) !void {
    var dir = std.fs.cwd().openDir("src", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var storage_violations: u32 = 0;
    var query_violations: u32 = 0;
    var test_violations: u32 = 0;
    var other_violations: u32 = 0;

    while (try walker.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        if (std.mem.indexOf(u8, entry.path, "ownership.zig") != null or
            std.mem.indexOf(u8, entry.path, "tidy_ownership.zig") != null or
            std.mem.indexOf(u8, entry.path, "violation_scanner.zig") != null)
        {
            continue;
        }

        const file_content = dir.readFileAlloc(allocator, entry.path, 1024 * 1024) catch |err| switch (err) {
            error.FileTooBig => continue,
            else => continue,
        };
        defer allocator.free(file_content);

        var violations_in_file: u32 = 0;

        // Check for raw ContextBlock usage
        if (std.mem.indexOf(u8, file_content, "ContextBlock,") != null or
            std.mem.indexOf(u8, file_content, ": ContextBlock") != null)
        {
            violations_in_file += 1;
        }

        // Check for raw pointer usage
        if (std.mem.indexOf(u8, file_content, "*ContextBlock") != null or
            std.mem.indexOf(u8, file_content, "?*ContextBlock") != null)
        {
            violations_in_file += 1;
        }

        // Check for unsafe collections
        if (std.mem.indexOf(u8, file_content, "ArrayList(ContextBlock)") != null or
            (std.mem.indexOf(u8, file_content, "HashMap(") != null and
                std.mem.indexOf(u8, file_content, "ContextBlock") != null))
        {
            violations_in_file += 1;
        }

        if (violations_in_file > 0) {
            log.info("VIOLATIONS in {s}: {}", .{ entry.path, violations_in_file });

            // Categorize violations
            if (std.mem.indexOf(u8, entry.path, "storage/") != null) {
                storage_violations += violations_in_file;
            } else if (std.mem.indexOf(u8, entry.path, "query/") != null) {
                query_violations += violations_in_file;
            } else if (std.mem.indexOf(u8, entry.path, "tests/") != null or
                std.mem.indexOf(u8, entry.path, "test") != null)
            {
                test_violations += violations_in_file;
            } else {
                other_violations += violations_in_file;
            }
        }
    }

    log.info("=== VIOLATION SUMMARY ===", .{});
    log.info("Storage subsystem: {} violations", .{storage_violations});
    log.info("Query subsystem: {} violations", .{query_violations});
    log.info("Test infrastructure: {} violations", .{test_violations});
    log.info("Other modules: {} violations", .{other_violations});
    log.info("TOTAL: {} violations", .{storage_violations + query_violations + test_violations + other_violations});
}
