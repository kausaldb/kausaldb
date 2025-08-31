//! Test file discovery and validation utilities
//!
//! Provides auto-discovery of test files and validation that all test files
//! are properly imported in test registry files. Supports snap updates to
//! automatically add missing test imports.

const std = @import("std");
const builtin = @import("builtin");

const MiB = 1024 * 1024;
const MAX_FILE_SIZE = 32 * 1024; // 32KB limit for test discovery scanning

pub const TestDiscoveryResult = struct {
    missing_imports: std.array_list.Managed([]const u8),
    found_test_files: std.array_list.Managed([]const u8),
    has_warnings: bool,

    pub fn deinit(self: *TestDiscoveryResult) void {
        for (self.missing_imports.items) |item| {
            self.missing_imports.allocator.free(item);
        }
        self.missing_imports.deinit();

        for (self.found_test_files.items) |item| {
            self.found_test_files.allocator.free(item);
        }
        self.found_test_files.deinit();
    }
};

/// Discovers test files in a directory and validates they are imported
/// in the registry file
pub fn discover_and_validate_tests(
    allocator: std.mem.Allocator,
    search_dir_path: []const u8,
    registry_file_path: []const u8,
    import_prefix: []const u8,
) !TestDiscoveryResult {
    var missing_imports = std.array_list.Managed([]const u8).init(allocator);
    var found_test_files = std.array_list.Managed([]const u8).init(allocator);
    var has_warnings = false;

    // Read the registry file to check existing imports
    const current_file = std.fs.cwd().openFile(registry_file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Registry file not found: {s}\n", .{registry_file_path});
            has_warnings = true;
            return TestDiscoveryResult{
                .missing_imports = missing_imports,
                .found_test_files = found_test_files,
                .has_warnings = has_warnings,
            };
        },
        else => return err,
    };
    defer current_file.close();

    const file_stat = try current_file.stat();
    if (file_stat.size > 2 * MiB) {
        std.debug.print("Registry file too large ({} bytes) for validation\n", .{file_stat.size});
        has_warnings = true;
        return TestDiscoveryResult{
            .missing_imports = missing_imports,
            .found_test_files = found_test_files,
            .has_warnings = has_warnings,
        };
    }

    const current_contents = try current_file.readToEndAlloc(allocator, @intCast(file_stat.size));
    defer allocator.free(current_contents);

    // Open the search directory - handle different base directories
    var search_dir: std.fs.Dir = undefined;
    var needs_close = false;

    if (std.mem.eql(u8, search_dir_path, ".")) {
        // Special case: searching src directory itself
        search_dir = std.fs.cwd().openDir("src", .{
            .access_sub_paths = true,
            .iterate = true,
        }) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("Source directory not found\n", .{});
                has_warnings = true;
                return TestDiscoveryResult{
                    .missing_imports = missing_imports,
                    .found_test_files = found_test_files,
                    .has_warnings = has_warnings,
                };
            },
            else => return err,
        };
        needs_close = true;
    } else if (std.mem.eql(u8, search_dir_path, "e2e")) {
        // Special case: e2e tests are in tests/e2e/, not src/e2e/
        search_dir = std.fs.cwd().openDir("tests/e2e", .{
            .access_sub_paths = true,
            .iterate = true,
        }) catch |err| switch (err) {
            error.FileNotFound => {
                // E2E directory doesn't exist - that's OK
                return TestDiscoveryResult{
                    .missing_imports = missing_imports,
                    .found_test_files = found_test_files,
                    .has_warnings = has_warnings,
                };
            },
            else => return err,
        };
        needs_close = true;
    } else {
        // Search in subdirectory (tests/, etc.)
        const full_path = try std.fmt.allocPrint(allocator, "src/{s}", .{search_dir_path});
        defer allocator.free(full_path);

        search_dir = std.fs.cwd().openDir(full_path, .{
            .access_sub_paths = true,
            .iterate = true,
        }) catch |err| switch (err) {
            error.FileNotFound => {
                // Search directory doesn't exist - that's OK for optional directories
                return TestDiscoveryResult{
                    .missing_imports = missing_imports,
                    .found_test_files = found_test_files,
                    .has_warnings = has_warnings,
                };
            },
            else => return err,
        };
        needs_close = true;
    }

    if (needs_close) {
        defer search_dir.close();
    }

    // Walk through all .zig files in search directory recursively
    try walk_directory(allocator, search_dir, "", current_contents, import_prefix, &found_test_files, &missing_imports, &has_warnings);

    return TestDiscoveryResult{
        .missing_imports = missing_imports,
        .found_test_files = found_test_files,
        .has_warnings = has_warnings,
    };
}

/// Recursively walk directory to find test files
fn walk_directory(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    current_path: []const u8,
    registry_contents: []const u8,
    import_prefix: []const u8,
    found_test_files: *std.array_list.Managed([]const u8),
    missing_imports: *std.array_list.Managed([]const u8),
    has_warnings: *bool,
) !void {
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        const entry_path = if (current_path.len == 0)
            try std.fmt.allocPrint(allocator, "{s}", .{entry.name})
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ current_path, entry.name });
        defer allocator.free(entry_path);

        switch (entry.kind) {
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;

                // Skip test framework helper files
                if (std.mem.eql(u8, entry.name, "harness.zig")) continue;
                if (std.mem.eql(u8, entry.name, "mock_vfs_helper.zig")) continue;
                if (std.mem.eql(u8, entry.name, "test_helpers.zig")) continue;

                // Check file size to prevent memory issues
                const entry_stat = dir.statFile(entry_path) catch continue;
                if (entry_stat.size > MAX_FILE_SIZE) continue;

                // Read file content to check for tests
                const file_content = dir.readFileAlloc(allocator, entry_path, @intCast(entry_stat.size)) catch continue;
                defer allocator.free(file_content);

                // Check if file contains test blocks
                if (has_test_blocks(file_content)) {
                    // Build the expected import path
                    const normalized_path = try allocator.dupe(u8, entry_path);
                    defer allocator.free(normalized_path);

                    // Windows path normalization
                    if (builtin.os.tag == .windows) {
                        std.mem.replaceScalar(u8, normalized_path, '\\', '/');
                    }

                    const expected_import = if (import_prefix.len > 0)
                        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ import_prefix, normalized_path })
                    else
                        try allocator.dupe(u8, normalized_path);
                    defer allocator.free(expected_import);

                    // Store found test file
                    try found_test_files.append(try allocator.dupe(u8, expected_import));

                    // Check if this import exists in registry file
                    if (std.mem.indexOf(u8, registry_contents, expected_import) == null) {
                        try missing_imports.append(try allocator.dupe(u8, expected_import));
                        has_warnings.* = true;
                    }
                }
            },
            .directory => {
                // Recursively walk subdirectories
                var subdir = dir.openDir(entry_path, .{ .access_sub_paths = true, .iterate = true }) catch continue;
                defer subdir.close();

                try walk_directory(allocator, subdir, entry_path, registry_contents, import_prefix, found_test_files, missing_imports, has_warnings);
            },
            else => {},
        }
    }
}

/// Check if file content contains test blocks
fn has_test_blocks(content: []const u8) bool {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "test ")) {
            // Make sure it's not a comment
            if (!std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " \t"), "//")) {
                return true;
            }
        }
    }
    return false;
}

/// Generate snap update content for missing imports
pub fn generate_snap_update(
    allocator: std.mem.Allocator,
    registry_file_path: []const u8,
    missing_imports: []const []const u8,
) ![]const u8 {
    if (missing_imports.len == 0) {
        return try allocator.dupe(u8, "");
    }

    // Read current file
    const current_file = std.fs.cwd().openFile(registry_file_path, .{}) catch {
        return try allocator.dupe(u8, "");
    };
    defer current_file.close();

    const current_contents = try current_file.readToEndAlloc(allocator, 2 * MiB);
    defer allocator.free(current_contents);

    // Find the comptime block or import section
    var updated_content = std.array_list.Managed(u8).init(allocator);
    defer updated_content.deinit();

    try updated_content.appendSlice(current_contents);

    // Find insertion point (end of existing imports in comptime block)
    if (std.mem.indexOf(u8, current_contents, "comptime {")) |comptime_start| {
        if (std.mem.indexOf(u8, current_contents[comptime_start..], "}")) |comptime_end_rel| {
            const comptime_end = comptime_start + comptime_end_rel;

            // Generate import statements
            var imports_buf = std.array_list.Managed(u8).init(allocator);
            defer imports_buf.deinit();

            try imports_buf.appendSlice("\n    // Auto-discovered test files:\n");
            for (missing_imports) |import_path| {
                try imports_buf.writer().print("    _ = @import(\"{s}\");\n", .{import_path});
            }

            // Insert before the closing brace
            const result = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
                current_contents[0..comptime_end],
                imports_buf.items,
                current_contents[comptime_end..],
            });

            return result;
        }
    }

    // If no comptime block found, just return original content
    return try allocator.dupe(u8, current_contents);
}
