//! Direct directory ingestion following KausalDB Arena Coordinator Pattern
//!
//! Simple, explicit file processing without complex abstractions.
//! Uses backing allocator for stable structures and arena coordinator for transient data.
//!
//! Design principles:
//! - No vtable abstractions - direct function calls
//! - Arena Coordinator pattern for memory management
//! - Explicit control flow - every operation is obvious
//! - Single responsibility - just ingest directory to blocks

const std = @import("std");
const assert_mod = @import("../core/assert.zig");
const context_block = @import("../core/types.zig");
const memory = @import("../core/memory.zig");
const parse_file_to_blocks = @import("parse_file_to_blocks.zig");
const vfs = @import("../core/vfs.zig");

const assert = assert_mod.assert;
const ArenaCoordinator = memory.ArenaCoordinator;
const ContextBlock = context_block.ContextBlock;
const FileContent = parse_file_to_blocks.FileContent;
const VFS = vfs.VFS;

/// Ingestion statistics for reporting
pub const IngestionStats = struct {
    files_processed: u32,
    blocks_generated: u32,
    errors_encountered: u32,
};

/// Configuration for directory ingestion
pub const IngestionConfig = struct {
    include_patterns: []const []const u8 = &[_][]const u8{"**/*.zig"},
    exclude_patterns: []const []const u8 = &[_][]const u8{},
    max_file_size: u64 = 1024 * 1024, // 1MB
    include_function_bodies: bool = true,
    include_private: bool = true,
    include_tests: bool = false,
};

/// Ingest directory directly to blocks using Arena Coordinator pattern
///
/// coordinator: Arena coordinator for transient data (file content, parsed blocks)
/// backing: Backing allocator for stable structures (file lists, paths)
/// file_system: VFS interface for file operations
/// directory_path: Absolute path to directory to ingest
/// config: Configuration for file filtering and parsing
///
/// Returns: Statistics about ingestion process
/// Memory: All block content allocated in arena via coordinator
pub fn ingest_directory_to_blocks(
    coordinator: *const ArenaCoordinator,
    backing: std.mem.Allocator,
    file_system: *VFS,
    directory_path: []const u8,
    config: IngestionConfig,
) !struct { blocks: []ContextBlock, stats: IngestionStats } {
    assert(directory_path.len > 0);

    // Fail fast with clear error rather than confusing iteration failures later
    if (!file_system.exists(directory_path)) {
        return error.DirectoryNotFound;
    }

    // Collect matching files using backing allocator for stable storage
    var file_paths = std.array_list.Managed([]const u8).init(backing);
    defer {
        for (file_paths.items) |path| {
            backing.free(path);
        }
        file_paths.deinit();
    }

    try collect_git_tracked_files(
        backing,
        file_system,
        directory_path,
        config.include_patterns,
        config.exclude_patterns,
        &file_paths,
    );

    // Process files to blocks using arena for transient data
    var all_blocks = std.array_list.Managed(ContextBlock).init(coordinator.allocator());
    var stats = IngestionStats{ .files_processed = 0, .blocks_generated = 0, .errors_encountered = 0 };

    for (file_paths.items) |file_path| {
        stats.files_processed += 1;

        // Read file content
        const stat = file_system.stat(file_path) catch {
            stats.errors_encountered += 1;
            continue;
        };

        if (stat.size > config.max_file_size) {
            stats.errors_encountered += 1;
            continue;
        }

        const file_content = file_system.read_file_alloc(
            coordinator.allocator(),
            file_path,
            stat.size,
        ) catch {
            stats.errors_encountered += 1;
            continue;
        };

        // Calculate relative path for block metadata
        const relative_path = if (std.mem.startsWith(u8, file_path, directory_path)) blk: {
            const relative = file_path[directory_path.len..];
            const clean_relative = if (relative.len > 0 and (relative[0] == '/' or relative[0] == '\\'))
                relative[1..]
            else
                relative;
            break :blk try coordinator.allocator().dupe(u8, clean_relative);
        } else try coordinator.allocator().dupe(u8, file_path);

        // Parse Zig file directly to blocks
        if (std.mem.endsWith(u8, relative_path, ".zig")) {
            const parse_config = parse_file_to_blocks.ParseConfig{
                .include_function_bodies = config.include_function_bodies,
                .include_private = config.include_private,
                .include_tests = config.include_tests,
                .max_function_body_size = 8192,
            };

            const file_content_struct = FileContent{
                .data = file_content,
                .path = relative_path,
                .content_type = "text/zig",
                .metadata = std.StringHashMap([]const u8).init(coordinator.allocator()),
                .timestamp_ns = @intCast(std.time.nanoTimestamp()),
            };

            const file_blocks = parse_file_to_blocks.parse_file_to_blocks(
                coordinator.allocator(),
                file_content_struct,
                parse_config,
            ) catch {
                stats.errors_encountered += 1;
                continue;
            };

            try all_blocks.appendSlice(file_blocks);
            stats.blocks_generated += @intCast(file_blocks.len);
        }
    }

    return .{
        .blocks = try all_blocks.toOwnedSlice(),
        .stats = stats,
    };
}

/// Collect git-tracked files respecting .gitignore patterns
/// Falls back to directory traversal for simulation VFS or non-git repos
fn collect_git_tracked_files(
    backing: std.mem.Allocator,
    file_system: *VFS,
    directory_path: []const u8,
    include_patterns: []const []const u8,
    exclude_patterns: []const []const u8,
    file_list: *std.array_list.Managed([]const u8),
) !void {
    const initial_count = file_list.items.len;

    // Always try git ls-files first to respect .gitignore
    collect_git_ls_files(backing, directory_path, include_patterns, exclude_patterns, file_list) catch {
        // Git command failed - not a problem, fall back to manual collection
    };

    // Fall back to manual traversal if no files found
    if (file_list.items.len == initial_count) {
        // Use basic exclude patterns for fallback when git is not available
        const fallback_exclude_patterns = &[_][]const u8{ "zig-cache/**", "zig-out/**", ".git/**", "zig/**" };
        try collect_matching_files(
            backing,
            file_system,
            directory_path,
            directory_path,
            include_patterns,
            fallback_exclude_patterns,
            file_list,
        );
    }
}

/// Use git ls-files to collect tracked files (respects .gitignore automatically)
fn collect_git_ls_files(
    backing: std.mem.Allocator,
    directory_path: []const u8,
    include_patterns: []const []const u8,
    exclude_patterns: []const []const u8,
    file_list: *std.array_list.Managed([]const u8),
) !void {
    // Execute git ls-files to get all tracked files
    const result = std.process.Child.run(.{
        .allocator = backing,
        .argv = &[_][]const u8{ "git", "ls-files" },
        .cwd = directory_path,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            // Git not available, fall back to manual collection
            // This is acceptable for non-git repositories
            return;
        },
        else => return err,
    };
    defer backing.free(result.stdout);
    defer backing.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        // Not a git repository or git command failed
        // This is acceptable - fall back to manual collection would happen at caller
        return;
    }

    // Parse git ls-files output (one file per line)
    var lines = std.mem.splitSequence(u8, result.stdout, "\n");
    while (lines.next()) |line| {
        const trimmed_line = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed_line.len == 0) continue;

        // Filter by include patterns and exclude patterns (extra safety layer)
        if (matches_patterns(trimmed_line, include_patterns) and
            !matches_patterns(trimmed_line, exclude_patterns))
        {
            // Convert relative path to absolute path
            const absolute_path = try std.fs.path.join(backing, &[_][]const u8{ directory_path, trimmed_line });
            try file_list.append(absolute_path);
        }
    }
}

/// Recursively collect matching files using simple explicit patterns
fn collect_matching_files(
    backing: std.mem.Allocator,
    file_system: *VFS,
    current_path: []const u8,
    base_path: []const u8,
    include_patterns: []const []const u8,
    exclude_patterns: []const []const u8,
    file_list: *std.array_list.Managed([]const u8),
) !void {
    var dir = file_system.iterate_directory(current_path, backing) catch {
        return; // Skip unreadable directories
    };
    defer dir.deinit(backing);

    while (dir.next()) |entry| {
        const entry_path = try std.fs.path.join(backing, &[_][]const u8{ current_path, entry.name });
        defer backing.free(entry_path);

        // Calculate relative path for pattern matching
        const relative_path = if (std.mem.startsWith(u8, entry_path, base_path)) blk: {
            const relative = entry_path[base_path.len..];
            break :blk if (relative.len > 0 and (relative[0] == '/' or relative[0] == '\\'))
                relative[1..]
            else
                relative;
        } else entry.name;

        switch (entry.kind) {
            .file => {
                // Simple pattern matching - for now just check .zig extension
                if (matches_patterns(relative_path, include_patterns) and
                    !matches_patterns(relative_path, exclude_patterns))
                {
                    try file_list.append(try backing.dupe(u8, entry_path));
                }
            },
            .directory => {
                // Skip excluded directories
                if (!matches_patterns(relative_path, exclude_patterns)) {
                    try collect_matching_files(
                        backing,
                        file_system,
                        entry_path,
                        base_path,
                        include_patterns,
                        exclude_patterns,
                        file_list,
                    );
                }
            },
            else => {}, // Skip other types
        }
    }
}

/// Simple pattern matching - checks if path matches any pattern
fn matches_patterns(path: []const u8, patterns: []const []const u8) bool {
    for (patterns) |pattern| {
        if (simple_glob_match(pattern, path)) {
            return true;
        }
    }
    return false;
}

/// Simple glob matching for basic patterns like "*.zig" and "dir/**"
fn simple_glob_match(pattern: []const u8, path: []const u8) bool {
    // Handle "**/*.zig" pattern
    if (std.mem.startsWith(u8, pattern, "**/*") and pattern.len > 4) {
        const suffix = pattern[4..];
        return std.mem.endsWith(u8, path, suffix);
    }

    // Handle "*.zig" pattern
    if (std.mem.startsWith(u8, pattern, "*") and pattern.len > 1) {
        const suffix = pattern[1..];
        return std.mem.endsWith(u8, path, suffix);
    }

    // Handle "dir/**" pattern
    if (std.mem.endsWith(u8, pattern, "/**")) {
        const prefix = pattern[0 .. pattern.len - 3];
        return std.mem.startsWith(u8, path, prefix);
    }

    // Exact match
    return std.mem.eql(u8, pattern, path);
}

//
// ================================ Unit Tests ================================
//

const testing = std.testing;
const test_harness_mod = @import("../tests/harness.zig");
const TestHarness = test_harness_mod.TestHarness;

test "simple glob matching" {
    try testing.expect(simple_glob_match("*.zig", "main.zig"));
    try testing.expect(simple_glob_match("**/*.zig", "src/main.zig"));
    try testing.expect(simple_glob_match("**/*.zig", "src/lib/utils.zig"));
    try testing.expect(simple_glob_match("zig-cache/**", "zig-cache/file.tmp"));

    try testing.expect(!simple_glob_match("*.zig", "main.c"));
    try testing.expect(!simple_glob_match("**/*.zig", "main.c"));
    try testing.expect(!simple_glob_match("zig-cache/**", "src/main.zig"));
}

test "git ls-files integration" {
    var test_harness = try TestHarness.init(testing.allocator, "git_ls_files_test");
    defer test_harness.deinit();

    // Create test directory structure with some ignored files
    try test_harness.file_system.create_directory("git_test");
    try test_harness.file_system.create_directory("git_test/src");
    try test_harness.file_system.create_directory("git_test/zig-cache");

    // Create files that should be included
    try test_harness.file_system.write_file("git_test/src/main.zig", "pub fn main() !void {}");
    try test_harness.file_system.write_file("git_test/build.zig", "pub fn build() void {}");

    // Create files that should be excluded (cache files)
    try test_harness.file_system.write_file("git_test/zig-cache/cached.zig", "// cache file");

    // Test with simulation VFS (should use fallback pattern matching)
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var file_paths = std.array_list.Managed([]const u8).init(testing.allocator);
    defer {
        for (file_paths.items) |path| {
            testing.allocator.free(path);
        }
        file_paths.deinit();
    }

    const include_patterns = &[_][]const u8{"**/*.zig"};
    const exclude_patterns = &[_][]const u8{ "zig-cache/**", "zig-out/**", "zig/**" };

    try collect_git_tracked_files(
        testing.allocator,
        test_harness.file_system,
        "git_test",
        include_patterns,
        exclude_patterns,
        &file_paths,
    );

    // Should find main.zig but not cached.zig
    try testing.expect(file_paths.items.len >= 1);

    var found_main = false;
    var found_cache = false;
    for (file_paths.items) |path| {
        if (std.mem.endsWith(u8, path, "main.zig")) found_main = true;
        if (std.mem.endsWith(u8, path, "cached.zig")) found_cache = true;
    }

    try testing.expect(found_main);
    try testing.expect(!found_cache); // Cache files should be excluded
}

test "ingest directory basic functionality" {
    var test_harness = try TestHarness.init(testing.allocator, "ingest_directory_test");
    defer test_harness.deinit();

    // Create test directory structure
    try test_harness.file_system.create_directory("test_project");
    try test_harness.file_system.create_directory("test_project/src");

    // Create test files
    try test_harness.file_system.write_file("test_project/src/main.zig",
        \\pub fn main() !void {
        \\    std.log.info("Hello, world!");
        \\}
    );

    try test_harness.file_system.write_file("test_project/src/lib.zig",
        \\pub fn add(a: i32, b: i32) i32 {
        \\    return a + b;
        \\}
        \\
        \\pub fn multiply(a: i32, b: i32) i32 {
        \\    return a * b;
        \\}
    );

    // Test ingestion
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const coordinator = ArenaCoordinator.init(&arena);

    const config = IngestionConfig{};
    const result = try ingest_directory_to_blocks(
        &coordinator,
        testing.allocator,
        test_harness.file_system,
        "test_project",
        config,
    );

    // Verify results
    try testing.expect(result.stats.files_processed >= 2);
    try testing.expect(result.stats.blocks_generated >= 3); // main, add, multiply functions
    try testing.expectEqual(@as(u32, 0), result.stats.errors_encountered);

    // Verify blocks contain expected functions
    var found_main = false;
    var found_add = false;
    var found_multiply = false;

    for (result.blocks) |block| {
        if (std.mem.indexOf(u8, block.content, "main()") != null) found_main = true;
        if (std.mem.indexOf(u8, block.content, "add(a: i32, b: i32)") != null) found_add = true;
        if (std.mem.indexOf(u8, block.content, "multiply(a: i32, b: i32)") != null) found_multiply = true;
    }

    try testing.expect(found_main);
    try testing.expect(found_add);
    try testing.expect(found_multiply);
}
