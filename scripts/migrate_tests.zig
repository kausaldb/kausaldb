//! Test migration script to reorganize test structure for better maintainability.
//!
//! Migrates tests to follow the three-tier hierarchy:
//! - Unit tests: In source files (no change)
//! - Integration tests: Move to src/tests/ with full API access
//! - E2E tests: Keep in tests/ using only binary interface
//!
//! Usage: zig run scripts/migrate_tests.zig

const std = @import("std");
const fs = std.fs;
const print = std.debug.print;

const TestCategory = enum {
    unit,
    integration,
    e2e,

    fn from_path(path: []const u8) TestCategory {
        // E2E tests stay in tests/e2e/
        if (std.mem.indexOf(u8, path, "tests/e2e/") != null) {
            return .e2e;
        }

        // Binary interface tests stay in tests/
        if (std.mem.indexOf(u8, path, "command_interface") != null or
            std.mem.indexOf(u8, path, "binary_") != null) {
            return .e2e;
        }

        // Everything else moves to src/tests/
        return .integration;
    }
};

const MigrationPlan = struct {
    source: []const u8,
    destination: []const u8,
    category: TestCategory,
    needs_import_fix: bool,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== KausalDB Test Migration Tool ===\n\n", .{});

    // Analyze current test structure
    print("Analyzing test structure...\n", .{});
    const plans = try analyze_tests(allocator);
    defer allocator.free(plans);

    // Show migration plan
    print("\nMigration Plan:\n", .{});
    print("-" ** 60 ++ "\n", .{});

    var integration_count: usize = 0;
    var e2e_count: usize = 0;

    for (plans) |plan| {
        switch (plan.category) {
            .integration => {
                print("  [MOVE] {s}\n", .{plan.source});
                print("      -> {s}\n", .{plan.destination});
                if (plan.needs_import_fix) {
                    print("      (needs import fixes)\n", .{});
                }
                integration_count += 1;
            },
            .e2e => {
                print("  [KEEP] {s} (E2E test)\n", .{plan.source});
                e2e_count += 1;
            },
            .unit => unreachable,
        }
    }

    print("-" ** 60 ++ "\n", .{});
    print("Summary: {} integration tests to move, {} E2E tests to keep\n\n", .{ integration_count, e2e_count });

    // Ask for confirmation
    print("Proceed with migration? [y/N]: ", .{});
    const stdin = std.io.getStdIn().reader();
    var buf: [10]u8 = undefined;
    if (try stdin.readUntilDelimiterOrEof(&buf, '\n')) |input| {
        if (input.len > 0 and (input[0] == 'y' or input[0] == 'Y')) {
            try execute_migration(allocator, plans);
            print("\n✓ Migration complete!\n", .{});
            print("\nNext steps:\n", .{});
            print("1. Update build.zig to use new test discovery\n", .{});
            print("2. Run 'zig build test' to verify unit tests\n", .{});
            print("3. Run 'zig build test-integration' for integration tests\n", .{});
            print("4. Run 'zig build test-e2e' for E2E tests\n", .{});
        } else {
            print("Migration cancelled.\n", .{});
        }
    }
}

fn analyze_tests(allocator: std.mem.Allocator) ![]MigrationPlan {
    var plans = std.ArrayList(MigrationPlan).init(allocator);
    defer plans.deinit();

    // Open tests directory
    var tests_dir = try fs.cwd().openIterableDir("tests", .{});
    defer tests_dir.close();

    var walker = try tests_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        const full_path = try std.fmt.allocPrint(allocator, "tests/{s}", .{entry.path});
        defer allocator.free(full_path);

        const category = TestCategory.from_path(full_path);

        const plan = switch (category) {
            .integration => blk: {
                // Determine destination path in src/tests/
                const dest_subdir = determine_test_subdirectory(entry.path);
                const dest_path = try std.fmt.allocPrint(
                    allocator,
                    "src/tests/{s}/{s}",
                    .{ dest_subdir, std.fs.path.basename(entry.path) }
                );

                break :blk MigrationPlan{
                    .source = try allocator.dupe(u8, full_path),
                    .destination = dest_path,
                    .category = .integration,
                    .needs_import_fix = try check_needs_import_fix(allocator, full_path),
                };
            },
            .e2e => MigrationPlan{
                .source = try allocator.dupe(u8, full_path),
                .destination = try allocator.dupe(u8, full_path),
                .category = .e2e,
                .needs_import_fix = false,
            },
            .unit => unreachable,
        };

        try plans.append(plan);
    }

    return plans.toOwnedSlice();
}

fn determine_test_subdirectory(path: []const u8) []const u8 {
    // Map test files to appropriate subdirectories
    if (std.mem.indexOf(u8, path, "storage") != null) return "storage";
    if (std.mem.indexOf(u8, path, "query") != null) return "query";
    if (std.mem.indexOf(u8, path, "ingestion") != null) return "ingestion";
    if (std.mem.indexOf(u8, path, "simulation") != null) return "simulation";
    if (std.mem.indexOf(u8, path, "performance") != null) return "performance";
    if (std.mem.indexOf(u8, path, "cli") != null) return "cli";
    if (std.mem.indexOf(u8, path, "server") != null) return "server";
    if (std.mem.indexOf(u8, path, "recovery") != null) return "recovery";
    if (std.mem.indexOf(u8, path, "safety") != null) return "safety";
    return "misc";
}

fn check_needs_import_fix(allocator: std.mem.Allocator, path: []const u8) !bool {
    const file = try fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    // Check for problematic import patterns
    return std.mem.indexOf(u8, content, "@import(\"../../src/") != null or
           std.mem.indexOf(u8, content, "@import(\"../src/") != null;
}

fn execute_migration(allocator: std.mem.Allocator, plans: []const MigrationPlan) !void {
    // Create src/tests directory structure
    try ensure_directory("src/tests");
    try ensure_directory("src/tests/storage");
    try ensure_directory("src/tests/query");
    try ensure_directory("src/tests/ingestion");
    try ensure_directory("src/tests/simulation");
    try ensure_directory("src/tests/performance");
    try ensure_directory("src/tests/cli");
    try ensure_directory("src/tests/server");
    try ensure_directory("src/tests/recovery");
    try ensure_directory("src/tests/safety");
    try ensure_directory("src/tests/misc");

    for (plans) |plan| {
        switch (plan.category) {
            .integration => {
                print("  Moving {s}...\n", .{std.fs.path.basename(plan.source)});

                // Read source file
                const source_file = try fs.cwd().openFile(plan.source, .{});
                defer source_file.close();

                var content = try source_file.readToEndAlloc(allocator, 10 * 1024 * 1024);
                defer allocator.free(content);

                // Fix imports if needed
                if (plan.needs_import_fix) {
                    content = try fix_imports(allocator, content);
                    defer allocator.free(content);
                }

                // Write to destination
                const dest_file = try fs.cwd().createFile(plan.destination, .{});
                defer dest_file.close();
                try dest_file.writeAll(content);

                // Delete source file
                try fs.cwd().deleteFile(plan.source);
            },
            .e2e => {
                // E2E tests stay where they are
                if (plan.needs_import_fix) {
                    print("  Fixing imports in {s}...\n", .{std.fs.path.basename(plan.source)});

                    const file = try fs.cwd().openFile(plan.source, .{ .mode = .read_write });
                    defer file.close();

                    var content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
                    defer allocator.free(content);

                    content = try fix_e2e_imports(allocator, content);
                    defer allocator.free(content);

                    try file.seekTo(0);
                    try file.setEndPos(content.len);
                    try file.writeAll(content);
                }
            },
            .unit => unreachable,
        }
    }
}

fn fix_imports(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    var lines = std.mem.tokenize(u8, content, "\n");
    while (lines.next()) |line| {
        var fixed_line = line;

        // Fix relative imports to src modules
        if (std.mem.indexOf(u8, line, "@import(\"../../src/") != null) {
            fixed_line = try std.mem.replaceOwned(u8, allocator, line, "../../src/", "../../");
        } else if (std.mem.indexOf(u8, line, "@import(\"../src/") != null) {
            fixed_line = try std.mem.replaceOwned(u8, allocator, line, "../src/", "../");
        }

        // Replace kausaldb import with direct module imports
        if (std.mem.indexOf(u8, line, "@import(\"kausaldb\")") != null) {
            fixed_line = "const kausaldb = @import(\"../testing_api.zig\");";
        }

        try result.appendSlice(fixed_line);
        try result.append('\n');
    }

    return result.toOwnedSlice();
}

fn fix_e2e_imports(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    var lines = std.mem.tokenize(u8, content, "\n");
    while (lines.next()) |line| {
        // E2E tests should not import internal modules
        if (std.mem.indexOf(u8, line, "@import(\"kausaldb\")") != null or
            std.mem.indexOf(u8, line, "@import(\"../src/") != null or
            std.mem.indexOf(u8, line, "@import(\"../../src/") != null) {
            // Comment out internal imports
            try result.appendSlice("// ");
            try result.appendSlice(line);
            try result.appendSlice(" // TODO: E2E test should use binary interface only");
        } else {
            try result.appendSlice(line);
        }
        try result.append('\n');
    }

    return result.toOwnedSlice();
}

fn ensure_directory(path: []const u8) !void {
    fs.cwd().makeDir(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}
