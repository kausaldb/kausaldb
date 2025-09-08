//! Git-based test file discovery for cross-platform reliability
//!
//! Uses `git ls-files` to avoid filesystem iteration issues on macOS
//! and provides simple, reliable test discovery across all platforms.

const std = @import("std");
const builtin = @import("builtin");

/// Find all unit test files (src/*.zig with test blocks, excluding src/tests/)
pub fn find_unit_test_files(allocator: std.mem.Allocator) ![][]const u8 {
    // Find all .zig files in src/ with test blocks, excluding src/tests/
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "sh",
            "-c",
            "git ls-files 'src/*.zig' 'src/**/*.zig' | grep -v '^src/tests/' | grep -v '^src/unit_tests.zig' | grep -v '^src/integration_tests.zig' | xargs grep -l '^test ' 2>/dev/null || true",
        },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        return &[_][]const u8{};
    }

    return parse_unit_test_file_list(allocator, result.stdout);
}

/// Find all integration test files (src/tests/*.zig)
pub fn find_integration_test_files(allocator: std.mem.Allocator) ![][]const u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "ls-files", "src/tests/*.zig", "src/tests/**/*.zig" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        return &[_][]const u8{};
    }

    return parse_integration_test_file_list(allocator, result.stdout);
}

/// Find all E2E test files (tests/e2e/*.zig)
pub fn find_e2e_test_files(allocator: std.mem.Allocator) ![][]const u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "ls-files", "tests/e2e/*.zig", "tests/e2e/**/*.zig" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        return &[_][]const u8{};
    }

    return parse_e2e_test_file_list(allocator, result.stdout);
}

/// Parse unit test files: src/foo/bar.zig -> foo/bar.zig
fn parse_unit_test_file_list(allocator: std.mem.Allocator, output: []const u8) ![][]const u8 {
    var files = std.array_list.Managed([]const u8).init(allocator);
    defer files.deinit();

    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, output, " \t\n"), '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        if (std.mem.endsWith(u8, trimmed, ".zig") and std.mem.startsWith(u8, trimmed, "src/")) {
            // Remove "src/" prefix, keep .zig extension for imports
            const import_path = try allocator.dupe(u8, trimmed[4..]);
            try files.append(import_path);
        }
    }

    std.mem.sort([]const u8, files.items, {}, struct {
        fn less_than(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.less_than);

    return try files.toOwnedSlice();
}

/// Parse integration test files: src/tests/foo/bar.zig -> tests/foo/bar.zig
fn parse_integration_test_file_list(allocator: std.mem.Allocator, output: []const u8) ![][]const u8 {
    var files = std.array_list.Managed([]const u8).init(allocator);
    defer files.deinit();

    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, output, " \t\n"), '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        if (std.mem.endsWith(u8, trimmed, ".zig") and std.mem.startsWith(u8, trimmed, "src/")) {
            // Remove "src/" prefix, keep .zig extension: src/tests/foo.zig -> tests/foo.zig
            const import_path = try allocator.dupe(u8, trimmed[4..]); // Remove "src/" prefix only
            try files.append(import_path);
        }
    }

    std.mem.sort([]const u8, files.items, {}, struct {
        fn less_than(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.less_than);

    return try files.toOwnedSlice();
}

/// Parse e2e test files: tests/e2e/foo/bar.zig -> e2e/foo/bar.zig
fn parse_e2e_test_file_list(allocator: std.mem.Allocator, output: []const u8) ![][]const u8 {
    var files = std.array_list.Managed([]const u8).init(allocator);
    defer files.deinit();

    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, output, " \t\n"), '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        if (std.mem.endsWith(u8, trimmed, ".zig") and std.mem.startsWith(u8, trimmed, "tests/e2e/")) {
            // Remove "tests/" prefix, keep rest: tests/e2e/foo.zig -> e2e/foo.zig
            const without_ext = trimmed[6 .. trimmed.len - 4]; // Remove "tests/" and ".zig"
            const import_path = try allocator.dupe(u8, without_ext);
            try files.append(import_path);
        }
    }

    std.mem.sort([]const u8, files.items, {}, struct {
        fn less_than(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.less_than);

    return try files.toOwnedSlice();
}

/// Generate import block for test registry files
pub fn generate_import_block(allocator: std.mem.Allocator, files: [][]const u8) ![]const u8 {
    var imports = std.array_list.Managed(u8).init(allocator);
    defer imports.deinit();

    for (files) |file_path| {
        try imports.writer().print("    _ = @import(\"{s}\");\n", .{file_path});
    }

    return try imports.toOwnedSlice();
}

/// Check if actual imports match expected imports in registry file
pub fn validate_imports(allocator: std.mem.Allocator, registry_path: []const u8, expected_files: [][]const u8) !bool {
    return validate_imports_with_exclusions(allocator, registry_path, expected_files, &[_][]const u8{});
}

/// Check imports with exclusion list for files covered by other mechanisms
pub fn validate_imports_with_exclusions(
    allocator: std.mem.Allocator,
    registry_path: []const u8,
    expected_files: [][]const u8,
    excluded_files: []const []const u8,
) !bool {
    const file = std.fs.cwd().openFile(registry_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var missing_count: usize = 0;

    // Check each expected file is imported or excluded
    for (expected_files) |expected| {
        // Check if this file is in the exclusion list
        var is_excluded = false;
        for (excluded_files) |excluded| {
            if (std.mem.eql(u8, expected, excluded)) {
                is_excluded = true;
                break;
            }
        }

        if (is_excluded) continue;

        const import_line = try std.fmt.allocPrint(allocator, "@import(\"{s}\")", .{expected});
        defer allocator.free(import_line);

        if (std.mem.indexOf(u8, content, import_line) == null) {
            std.debug.print("Missing import: {s}\n", .{expected});
            missing_count += 1;
        }
    }

    return missing_count == 0;
}

test "git test discovery basic functionality" {
    const allocator = std.testing.allocator;

    // Test that we can run git commands (may be empty but shouldn't fail)
    const unit_files = find_unit_test_files(allocator) catch |err| {
        if (err == error.FileNotFound) {
            // Git not available - validate that we can at least handle this gracefully
            std.debug.print("Git not available, validating graceful handling\n", .{});

            // Test should still validate error handling paths work correctly
            const empty_files: [][]const u8 = &.{};
            const validation_result = validate_imports_with_exclusions(allocator, "test", empty_files, &.{}) catch |validation_err| {
                // This should succeed even without Git
                return validation_err;
            };
            try std.testing.expect(validation_result); // Empty validation should pass
            return;
        }
        return err;
    };
    defer {
        for (unit_files) |file| {
            allocator.free(file);
        }
        allocator.free(unit_files);
    }

    // Should not crash and return some result
    std.debug.print("Found {} unit test files\n", .{unit_files.len});
}
