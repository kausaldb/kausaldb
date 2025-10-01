const std = @import("std");

const context_block = @import("../core/types.zig");
const memory = @import("../core/memory.zig");
const parse_file_to_blocks = @import("ingest_file.zig");
const vfs = @import("../core/vfs.zig");
const ownership = @import("../core/ownership.zig");

const ArenaCoordinator = memory.ArenaCoordinator;
const ContextBlock = context_block.ContextBlock;
const IngestionBlock = ownership.ComptimeOwnedBlockType(.temporary);
const FileContent = parse_file_to_blocks.FileContent;
const VFS = vfs.VFS;

pub const IngestionStats = struct {
    files_processed: usize,
    blocks_generated: usize,
    errors_encountered: usize,
};

pub const IngestionConfig = struct {
    include_patterns: [][]const u8,
    exclude_patterns: [][]const u8,
    max_file_size: usize,
    include_function_bodies: bool = true,
    include_private: bool = true,
    include_tests: bool = true,
};

/// Ingest a directory, returning only ContextBlock at the API boundary.
/// All internal helpers and collections use IngestionBlock for ownership safety.
pub fn ingest_directory_to_blocks(
    coordinator: *const ArenaCoordinator,
    backing: std.mem.Allocator,
    file_system: *VFS,
    directory_path: []const u8,
    codebase_name: []const u8,
    config: IngestionConfig,
) !struct { blocks: []ContextBlock, stats: IngestionStats } {
    std.debug.assert(directory_path.len > 0);

    if (!file_system.exists(directory_path)) {
        return error.DirectoryNotFound;
    }

    var file_paths = std.ArrayList([]const u8){};
    defer {
        for (file_paths.items) |path| {
            backing.free(path);
        }
        file_paths.deinit(backing);
    }

    try collect_git_tracked_files(
        backing,
        file_system,
        directory_path,
        config.include_patterns,
        config.exclude_patterns,
        &file_paths,
    );

    var all_blocks = std.ArrayList(IngestionBlock){};
    var stats = IngestionStats{ .files_processed = 0, .blocks_generated = 0, .errors_encountered = 0 };

    for (file_paths.items) |file_path| {
        stats.files_processed += 1;

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

        const relative_path = if (std.mem.startsWith(u8, file_path, directory_path)) blk: {
            const relative = file_path[directory_path.len..];
            const clean_relative = if (relative.len > 0 and (relative[0] == '/' or relative[0] == '\\'))
                relative[1..]
            else
                relative;
            break :blk try coordinator.allocator().dupe(u8, clean_relative);
        } else try coordinator.allocator().dupe(u8, file_path);

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

            // Get context blocks and convert to owned ingestion blocks
            const file_blocks = try parse_file_to_blocks.parse_file_to_blocks(
                coordinator.allocator(),
                file_content_struct,
                codebase_name,
                parse_config,
            );

            // Convert each ContextBlock to IngestionBlock for ownership tracking
            for (file_blocks) |block| {
                const ingestion_block = IngestionBlock.take_ownership(block);
                try all_blocks.append(coordinator.allocator(), ingestion_block);
            }
            stats.blocks_generated += @intCast(file_blocks.len);
        }
    }

    // Convert to []ContextBlock at API boundary
    const owned_blocks = try all_blocks.toOwnedSlice(coordinator.allocator());
    var blocks = try coordinator.allocator().alloc(ContextBlock, owned_blocks.len);
    for (owned_blocks, 0..) |owned, i| {
        blocks[i] = owned.block;
    }
    return .{
        .blocks = blocks,
        .stats = stats,
    };
}

/// Collect files tracked by git, matching include/exclude patterns.
fn collect_git_tracked_files(
    allocator: std.mem.Allocator,
    file_system: *VFS,
    directory_path: []const u8,
    include_patterns: [][]const u8,
    exclude_patterns: [][]const u8,
    out_paths: *std.ArrayList([]const u8),
) !void {
    const git_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "ls-files" },
        .cwd = directory_path,
        .max_output_bytes = 1024 * 1024, // 1MB max
    }) catch |err| switch (err) {
        error.FileNotFound => return collect_filesystem_files(allocator, file_system, directory_path, include_patterns, exclude_patterns, out_paths),
        else => return err,
    };
    defer allocator.free(git_result.stdout);
    defer allocator.free(git_result.stderr);

    switch (git_result.term) {
        .Exited => |code| if (code != 0) {
            return collect_filesystem_files(allocator, file_system, directory_path, include_patterns, exclude_patterns, out_paths);
        },
        else => return collect_filesystem_files(allocator, file_system, directory_path, include_patterns, exclude_patterns, out_paths),
    }

    var git_files_found = false;

    var lines = std.mem.splitScalar(u8, git_result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed_line = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed_line.len == 0) continue;

        git_files_found = true;

        var matches_include = include_patterns.len == 0;
        for (include_patterns) |pattern| {
            if (std.mem.indexOf(u8, trimmed_line, pattern) != null) {
                matches_include = true;
                break;
            } else if (std.mem.startsWith(u8, pattern, "**/*")) {
                const extension = pattern[4..];
                if (std.mem.endsWith(u8, trimmed_line, extension)) {
                    matches_include = true;
                    break;
                }
            }
        }

        var matches_exclude = false;
        for (exclude_patterns) |pattern| {
            if (std.mem.indexOf(u8, trimmed_line, pattern) != null) {
                matches_exclude = true;
                break;
            }
        }

        if (matches_include and !matches_exclude) {
            const absolute_path = try std.fs.path.join(allocator, &[_][]const u8{ directory_path, trimmed_line });
            try out_paths.append(allocator, absolute_path);
        }
    }

    // If Git found no files, fall back to filesystem traversal
    if (!git_files_found) {
        return collect_filesystem_files(allocator, file_system, directory_path, include_patterns, exclude_patterns, out_paths);
    }
}

fn collect_filesystem_files(
    allocator: std.mem.Allocator,
    file_system: *VFS,
    directory_path: []const u8,
    include_patterns: [][]const u8,
    exclude_patterns: [][]const u8,
    out_paths: *std.ArrayList([]const u8),
) !void {
    var iterator = try file_system.iterate_directory(directory_path, allocator);
    defer iterator.deinit(allocator);

    while (iterator.next()) |entry| {
        if (entry.kind != .file) continue;

        const file_path = try std.fs.path.join(allocator, &[_][]const u8{ directory_path, entry.name });
        defer allocator.free(file_path);

        const should_include = blk: {
            if (include_patterns.len == 0) {
                break :blk std.mem.endsWith(u8, entry.name, ".zig") or
                    std.mem.endsWith(u8, entry.name, ".c") or
                    std.mem.endsWith(u8, entry.name, ".cpp") or
                    std.mem.endsWith(u8, entry.name, ".h") or
                    std.mem.endsWith(u8, entry.name, ".hpp") or
                    std.mem.endsWith(u8, entry.name, ".rs") or
                    std.mem.endsWith(u8, entry.name, ".go") or
                    std.mem.endsWith(u8, entry.name, ".py") or
                    std.mem.endsWith(u8, entry.name, ".js") or
                    std.mem.endsWith(u8, entry.name, ".ts");
            }

            for (include_patterns) |pattern| {
                if (std.mem.indexOf(u8, entry.name, pattern) != null) {
                    break :blk true;
                } else if (std.mem.startsWith(u8, pattern, "**/*")) {
                    const extension = pattern[4..];
                    if (std.mem.endsWith(u8, entry.name, extension)) {
                        break :blk true;
                    }
                }
            }
            break :blk false;
        };

        if (!should_include) continue;

        const should_exclude = blk: {
            for (exclude_patterns) |pattern| {
                if (std.mem.indexOf(u8, entry.name, pattern) != null) {
                    break :blk true;
                }
            }
            break :blk false;
        };

        if (should_exclude) continue;

        const absolute_path = try allocator.dupe(u8, file_path);
        try out_paths.append(allocator, absolute_path);
    }
}

// Additional helpers (collect_git_ls_files, collect_matching_files, etc.) would also avoid ContextBlock internally.
