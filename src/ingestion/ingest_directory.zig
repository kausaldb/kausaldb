const std = @import("std");
const assert_mod = @import("../core/assert.zig");
const context_block = @import("../core/types.zig");
const memory = @import("../core/memory.zig");
const parse_file_to_blocks = @import("ingest_file.zig");
const vfs = @import("../core/vfs.zig");
const ownership = @import("../core/ownership.zig");

const assert = assert_mod.assert;
const ArenaCoordinator = memory.ArenaCoordinator;
const ContextBlock = context_block.ContextBlock;
const IngestionBlock = ownership.comptime_owned_block_type(.ingestion_pipeline);
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
    assert(directory_path.len > 0);

    if (!file_system.exists(directory_path)) {
        return error.DirectoryNotFound;
    }

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

    var all_blocks = std.array_list.Managed(IngestionBlock).init(coordinator.allocator());
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

            // Get owned ingestion blocks
            const file_blocks = try parse_file_to_blocks.parse_file_to_blocks_owned(
                coordinator.allocator(),
                file_content_struct,
                codebase_name,
                parse_config,
            );

            try all_blocks.appendSlice(file_blocks);
            stats.blocks_generated += @intCast(file_blocks.len);
        }
    }

    // Convert to []ContextBlock at API boundary
    const owned_blocks = try all_blocks.toOwnedSlice();
    var blocks = try coordinator.allocator().alloc(ContextBlock, owned_blocks.len);
    for (owned_blocks, 0..) |owned, i| {
        blocks[i] = owned.extract();
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
    out_paths: *std.array_list.Managed([]const u8),
) !void {
    // Suppress unused parameter errors for now
    _ = allocator;
    _ = file_system;
    _ = directory_path;
    _ = include_patterns;
    _ = exclude_patterns;
    _ = out_paths;
    @compileError("collect_git_tracked_files not implemented in this refactor sweep. Implement as needed, ensuring no ContextBlock usage internally.");
}

// Additional helpers (collect_git_ls_files, collect_matching_files, etc.) would also avoid ContextBlock internally.
