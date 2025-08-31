//! Test registry updater - automatically adds missing test imports
//!
//! This utility performs "snap updates" to test registry files by discovering
//! test files and automatically adding missing imports to the appropriate
//! registry files (unit_tests.zig, integration_tests.zig, e2e_tests.zig).

const std = @import("std");
const test_discovery = @import("test_discovery.zig");
const print = std.debug.print;

const TestType = enum {
    unit,
    integration,
    e2e,

    const Config = struct {
        search_dir: []const u8,
        registry_file: []const u8,
        import_prefix: []const u8,
    };

    fn config_for_type(self: TestType) Config {
        return switch (self) {
            .unit => Config{
                .search_dir = ".",
                .registry_file = "src/unit_tests.zig",
                .import_prefix = "",
            },
            .integration => Config{
                .search_dir = "tests",
                .registry_file = "src/integration_tests.zig",
                .import_prefix = "tests",
            },
            .e2e => Config{
                .search_dir = "e2e",
                .registry_file = "tests/e2e_tests.zig",
                .import_prefix = "e2e",
            },
        };
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        print("Usage: {s} <test-type>\n", .{args[0]});
        print("  test-type: unit, integration, or e2e\n");
        std.process.exit(1);
    }

    const test_type = std.meta.stringToEnum(TestType, args[1]) orelse {
        print("Invalid test type: {s}\n", .{args[1]});
        print("Valid options: unit, integration, e2e\n");
        std.process.exit(1);
    };

    const config = test_type.config_for_type();

    print("╔══════════════════════════════════════════════════════════════════╗\n");
    print("║                  KausalDB Test Registry Updater                 ║\n");
    print("║                  Snap Update for {s:<10} Tests                  ║\n", .{@tagName(test_type)});
    print("╚══════════════════════════════════════════════════════════════════╝\n\n");

    print("Discovering {s} tests in {s}/...\n", .{ @tagName(test_type), config.search_dir });

    // Discover tests
    var result = test_discovery.discover_and_validate_tests(
        allocator,
        config.search_dir,
        config.registry_file,
        config.import_prefix,
    ) catch |err| {
        print("❌ Test discovery failed: {}\n", .{err});
        std.process.exit(1);
    };
    defer result.deinit();

    print("Found {} test files total\n", .{result.found_test_files.items.len});

    if (result.missing_imports.items.len == 0) {
        print("[OK] All {s} test files are already imported - no updates needed!\n", .{@tagName(test_type)});
        return;
    }

    print("\n[MISSING] Missing imports found: {}\n", .{result.missing_imports.items.len});
    for (result.missing_imports.items) |import_path| {
        print("  + {s}\n", .{import_path});
    }

    print("\n[UPDATE] Updating {s}...\n", .{config.registry_file});

    // Filter missing imports based on test type
    var filtered_missing = std.ArrayList([]const u8).init(allocator);
    defer filtered_missing.deinit();

    for (result.missing_imports.items) |import_path| {
        switch (test_type) {
            .unit => {
                // Skip files in tests/, e2e/, or other non-src directories
                if (std.mem.startsWith(u8, import_path, "tests/")) continue;
                if (std.mem.startsWith(u8, import_path, "e2e/")) continue;
            },
            .integration => {
                // Include only files in tests/ directory
                if (!std.mem.startsWith(u8, import_path, "tests/")) continue;
            },
            .e2e => {
                // Include only files in e2e/ directory
                if (!std.mem.startsWith(u8, import_path, "e2e/")) continue;
            },
        }
        try filtered_missing.append(import_path);
    }

    if (filtered_missing.items.len == 0) {
        print("✅ No relevant imports to add after filtering\n");
        return;
    }

    // Generate updated content
    const updated_content = test_discovery.generate_snap_update(
        allocator,
        config.registry_file,
        filtered_missing.items,
    ) catch |err| {
        print("❌ Failed to generate update: {}\n", .{err});
        std.process.exit(1);
    };
    defer allocator.free(updated_content);

    if (updated_content.len == 0) {
        print("❌ Failed to generate updated content\n");
        std.process.exit(1);
    }

    // Write updated file
    const file = std.fs.cwd().createFile(config.registry_file, .{}) catch |err| {
        print("❌ Failed to create file {s}: {}\n", .{ config.registry_file, err });
        std.process.exit(1);
    };
    defer file.close();

    file.writeAll(updated_content) catch |err| {
        print("[ERROR] Failed to write file {s}: {}\n", .{ config.registry_file, err });
        std.process.exit(1);
    };

    print("[SUCCESS] Successfully updated {s}\n", .{config.registry_file});
    print("[INFO] Added {} new test imports\n", .{filtered_missing.items.len});

    print("\n[TEST] Run tests to verify:\n");
    switch (test_type) {
        .unit => print("  ./zig/zig build test\n"),
        .integration => print("  ./zig/zig build test-integration\n"),
        .e2e => print("  ./zig/zig build test-e2e\n"),
    }

    print("\n[COMPLETE] Snap update complete!\n");
}
