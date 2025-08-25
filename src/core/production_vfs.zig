//! Production VFS implementation using real OS filesystem operations.
//!
//! Design rationale: Maps VFS interface directly to platform filesystem calls
//! with minimal overhead. Error translation provides consistent error semantics
//! across platforms while preserving underlying error information for debugging.
//!
//! Directory iteration allocates entry metadata in caller-provided arena,
//! eliminating manual cleanup and enabling O(1) bulk deallocation when the
//! arena is reset. This prevents memory leaks from incomplete iteration.

const builtin = @import("builtin");
const std = @import("std");

const assert_mod = @import("assert.zig");
const vfs = @import("vfs.zig");

const assert = assert_mod.assert;
const testing = std.testing;

const DirectoryEntry = vfs.DirectoryEntry;
const DirectoryIterator = vfs.DirectoryIterator;
const VFS = vfs.VFS;
const VFSError = vfs.VFSError;
const VFile = vfs.VFile;
const VFileError = vfs.VFileError;

/// Maximum path length for defensive validation across platforms
const MAX_PATH_LENGTH = 4096;

/// Production file magic number for corruption detection in debug builds
const PRODUCTION_FILE_MAGIC: u64 = 0xDEADBEEF_CAFEBABE;

/// Maximum reasonable file size to prevent memory exhaustion attacks
const MAX_REASONABLE_FILE_SIZE: u64 = 1024 * 1024 * 1024; // 1GB

// Cross-platform compatibility and security validation
comptime {
    assert(MAX_PATH_LENGTH > 0);
    assert(MAX_PATH_LENGTH <= 8192);
    assert(MAX_REASONABLE_FILE_SIZE > 0);
    assert(MAX_REASONABLE_FILE_SIZE < std.math.maxInt(u64) / 2);
    assert(PRODUCTION_FILE_MAGIC != 0);
    assert(PRODUCTION_FILE_MAGIC != std.math.maxInt(u64));
}

/// Platform-specific error set for filesystem sync operations
const PlatformSyncError = error{
    SystemResources,
    AccessDenied,
    IoError,
};

/// Platform-specific global filesystem sync implementation.
/// Forces all buffered filesystem data to physical storage across the entire system.
/// Critical for ensuring WAL durability in combination with individual file syncs.
fn platform_global_sync() PlatformSyncError!void {
    switch (builtin.os.tag) {
        .linux => {
            // Linux: sync() forces write of all modified in-core data to disk
            // POSIX.1-2001 standard requires sync() to schedule writes but may return before completion
            // Modern Linux sync() waits for completion, providing strong durability guarantee
            _ = std.c.sync();
        },
        .macos => {
            // macOS: sync() schedules all filesystem buffers to be written to disk
            // Darwin implementation waits for completion, ensuring durability
            _ = std.c.sync();
        },
        .windows => {
            // Windows: No direct equivalent to POSIX sync()
            // FlushFileBuffers() works per-handle, sync() affects entire system
            // _flushall() flushes C runtime buffers but not OS buffers
            // For production Windows deployment, consider volume-specific sync

            // Best effort: flush C runtime buffers
            // Note: This does not provide the same durability guarantee as POSIX sync()
            _ = std.c._flushall();
        },
        else => {
            // Unsupported platforms: return error rather than silent no-op
            // This ensures callers are aware that durability guarantee is not provided
            return PlatformSyncError.IoError;
        },
    }
}

/// Production VFS implementation using real OS filesystem operations
pub const ProductionVFS = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(backing_allocator: std.mem.Allocator) ProductionVFS {
        return ProductionVFS{ .arena = std.heap.ArenaAllocator.init(backing_allocator) };
    }

    pub fn deinit(self: *ProductionVFS) void {
        self.arena.deinit();
    }

    /// Get VFS interface for this implementation
    pub fn vfs(self: *ProductionVFS) VFS {
        return VFS{
            .ptr = self,
            .vtable = &vtable_impl,
        };
    }

    const vtable_impl = VFS.VTable{
        .open = open,
        .create = create,
        .remove = remove,
        .exists = exists,
        .mkdir = mkdir,
        .mkdir_all = mkdir_all,
        .rmdir = rmdir,
        .iterate_directory = iterate_directory,
        .rename = rename,
        .stat = stat,
        .sync = sync,
        .deinit = vfs_deinit,
    };

    fn open(ptr: *anyopaque, path: []const u8, mode: VFS.OpenMode) VFSError!VFile {
        const self: *ProductionVFS = @ptrCast(@alignCast(ptr));
        assert(path.len > 0 and path.len < MAX_PATH_LENGTH);
        _ = self; // ProductionVFS no longer needs arena for VFile

        const is_absolute = std.fs.path.isAbsolute(path);
        const file = switch (mode) {
            .read => if (is_absolute)
                std.fs.openFileAbsolute(path, .{ .mode = .read_only })
            else
                std.fs.cwd().openFile(path, .{ .mode = .read_only }),
            .write => if (is_absolute)
                std.fs.openFileAbsolute(path, .{ .mode = .write_only })
            else
                std.fs.cwd().openFile(path, .{ .mode = .write_only }),
            .read_write => if (is_absolute)
                std.fs.openFileAbsolute(path, .{ .mode = .read_write })
            else
                std.fs.cwd().openFile(path, .{ .mode = .read_write }),
        };

        const opened_file = file catch |err| {
            return switch (err) {
                error.FileNotFound => VFSError.FileNotFound,
                error.AccessDenied => VFSError.AccessDenied,
                error.IsDir => VFSError.IsDirectory,
                error.SystemResources, error.ProcessFdQuotaExceeded => VFSError.OutOfMemory,
                else => VFSError.IoError,
            };
        };

        return VFile{
            .impl = .{ .production = .{
                .file = opened_file,
                .closed = false,
            } },
        };
    }

    fn create(ptr: *anyopaque, path: []const u8) VFSError!VFile {
        const self: *ProductionVFS = @ptrCast(@alignCast(ptr));
        assert(path.len > 0 and path.len < MAX_PATH_LENGTH);
        _ = self; // ProductionVFS no longer needs arena for VFile

        const is_absolute = std.fs.path.isAbsolute(path);
        
        // Create parent directories for relative paths
        if (!is_absolute) {
            if (std.fs.path.dirname(path)) |parent_dir| {
                std.fs.cwd().makePath(parent_dir) catch |err| switch (err) {
                    error.PathAlreadyExists => {}, // Directory exists, that's fine
                    error.AccessDenied => return VFSError.AccessDenied,
                    else => return VFSError.IoError,
                };
            }
        }

        const file = if (is_absolute)
            std.fs.createFileAbsolute(path, .{ .read = true, .exclusive = true })
        else
            std.fs.cwd().createFile(path, .{ .read = true, .exclusive = true });

        const created_file = file catch |err| {
            return switch (err) {
                error.PathAlreadyExists => VFSError.FileExists,
                error.AccessDenied => VFSError.AccessDenied,
                error.FileNotFound => VFSError.FileNotFound,
                error.SystemResources, error.ProcessFdQuotaExceeded => VFSError.OutOfMemory,
                else => VFSError.IoError,
            };
        };

        return VFile{
            .impl = .{ .production = .{
                .file = created_file,
                .closed = false,
            } },
        };
    }

    fn remove(ptr: *anyopaque, path: []const u8) VFSError!void {
        _ = ptr;
        assert(path.len > 0 and path.len < MAX_PATH_LENGTH);

        std.fs.deleteFileAbsolute(path) catch |err| {
            return switch (err) {
                error.FileNotFound => VFSError.FileNotFound,
                error.AccessDenied => VFSError.AccessDenied,
                error.FileBusy => VFSError.AccessDenied,
                else => VFSError.IoError,
            };
        };
    }

    fn exists(ptr: *anyopaque, path: []const u8) bool {
        _ = ptr;
        assert(path.len > 0 and path.len < MAX_PATH_LENGTH);

        const is_absolute = std.fs.path.isAbsolute(path);
        if (is_absolute) {
            std.fs.accessAbsolute(path, .{}) catch return false;
        } else {
            std.fs.cwd().access(path, .{}) catch return false;
        }
        return true;
    }

    fn mkdir(ptr: *anyopaque, path: []const u8) VFSError!void {
        _ = ptr;
        assert(path.len > 0 and path.len < MAX_PATH_LENGTH);

        const is_absolute = std.fs.path.isAbsolute(path);
        if (is_absolute) {
            std.fs.makeDirAbsolute(path) catch |err| {
                return switch (err) {
                    error.PathAlreadyExists => VFSError.FileExists,
                    error.AccessDenied => VFSError.AccessDenied,
                    error.FileNotFound => VFSError.FileNotFound,
                    else => VFSError.IoError,
                };
            };
        } else {
            std.fs.cwd().makeDir(path) catch |err| {
                return switch (err) {
                    error.PathAlreadyExists => VFSError.FileExists,
                    error.AccessDenied => VFSError.AccessDenied,
                    error.FileNotFound => VFSError.FileNotFound,
                    else => VFSError.IoError,
                };
            };
        }
    }

    fn mkdir_all(ptr: *anyopaque, path: []const u8) VFSError!void {
        _ = ptr;
        assert(path.len > 0 and path.len < MAX_PATH_LENGTH);

        const is_absolute = std.fs.path.isAbsolute(path);
        if (is_absolute) {
            std.fs.makeDirAbsolute(path) catch |err| {
                return switch (err) {
                    error.PathAlreadyExists => VFSError.FileExists,
                    error.AccessDenied => VFSError.AccessDenied,
                    error.FileNotFound => VFSError.FileNotFound,
                    else => VFSError.IoError,
                };
            };
        } else {
            std.fs.cwd().makePath(path) catch |err| {
                return switch (err) {
                    error.PathAlreadyExists => return, // Success - directory exists
                    error.AccessDenied => VFSError.AccessDenied,
                    else => VFSError.IoError,
                };
            };
        }
    }

    fn rmdir(ptr: *anyopaque, path: []const u8) VFSError!void {
        _ = ptr;
        assert(path.len > 0 and path.len < MAX_PATH_LENGTH);

        std.fs.deleteDirAbsolute(path) catch |err| {
            return switch (err) {
                error.FileNotFound => VFSError.FileNotFound,
                error.AccessDenied => VFSError.AccessDenied,
                error.DirNotEmpty => VFSError.DirectoryNotEmpty,
                else => VFSError.IoError,
            };
        };
    }

    /// Iterate directory entries using caller-provided arena allocator.
    /// All entry names and metadata are allocated in the provided arena,
    /// enabling O(1) cleanup when the arena is reset or destroyed.
    fn iterate_directory(ptr: *anyopaque, path: []const u8, allocator: std.mem.Allocator) VFSError!DirectoryIterator {
        _ = ptr;
        assert(path.len > 0 and path.len < MAX_PATH_LENGTH);

        const is_absolute = std.fs.path.isAbsolute(path);
        var dir = if (is_absolute)
            std.fs.openDirAbsolute(path, .{ .iterate = true }) catch |err| {
                return switch (err) {
                    error.FileNotFound => VFSError.FileNotFound,
                    error.AccessDenied => VFSError.AccessDenied,
                    error.NotDir => VFSError.NotDirectory,
                    else => VFSError.IoError,
                };
            }
        else
            std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
                return switch (err) {
                    error.FileNotFound => VFSError.FileNotFound,
                    error.AccessDenied => VFSError.AccessDenied,
                    error.NotDir => VFSError.NotDirectory,
                    else => VFSError.IoError,
                };
            };
        defer dir.close();

        var entries = std.array_list.Managed(DirectoryEntry).init(allocator);
        errdefer entries.deinit();

        var fs_iterator = dir.iterate();
        while (fs_iterator.next() catch |err| {
            return switch (err) {
                error.AccessDenied => VFSError.AccessDenied,
                error.SystemResources => VFSError.OutOfMemory,
                else => VFSError.IoError,
            };
        }) |entry| {
            // Skip current and parent directory entries for consistency
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) {
                continue;
            }

            const name_copy = try allocator.dupe(u8, entry.name);
            const kind = DirectoryEntry.Kind.from_file_type(entry.kind);

            try entries.append(DirectoryEntry{
                .name = name_copy,
                .kind = kind,
            });
        }

        return DirectoryIterator{
            .entries = try entries.toOwnedSlice(),
            .index = 0,
        };
    }

    fn rename(ptr: *anyopaque, old_path: []const u8, new_path: []const u8) VFSError!void {
        _ = ptr;
        assert(old_path.len > 0 and old_path.len < MAX_PATH_LENGTH);
        assert(new_path.len > 0 and new_path.len < MAX_PATH_LENGTH);

        std.fs.renameAbsolute(old_path, new_path) catch |err| {
            return switch (err) {
                error.FileNotFound => VFSError.FileNotFound,
                error.AccessDenied => VFSError.AccessDenied,
                error.PathAlreadyExists => VFSError.FileExists,
                else => VFSError.IoError,
            };
        };
    }

    fn stat(ptr: *anyopaque, path: []const u8) VFSError!VFS.FileStat {
        _ = ptr;
        assert(path.len > 0 and path.len < MAX_PATH_LENGTH);

        const file_stat = std.fs.cwd().statFile(path) catch |err| {
            return switch (err) {
                error.FileNotFound => VFSError.FileNotFound,
                error.AccessDenied => VFSError.AccessDenied,
                else => VFSError.IoError,
            };
        };

        return VFS.FileStat{
            .size = file_stat.size,
            .created_time = @intCast(file_stat.ctime),
            .modified_time = @intCast(file_stat.mtime),
            .is_directory = file_stat.kind == .directory,
        };
    }

    /// Global filesystem sync forces all buffered data to storage across the entire system.
    /// Platform-specific implementation ensures durability guarantees for critical operations.
    /// Essential for WAL durability when combined with individual file flushes.
    fn sync(ptr: *anyopaque) VFSError!void {
        _ = ptr;

        const platform_result = platform_global_sync();
        platform_result catch |err| switch (err) {
            error.SystemResources => return VFSError.OutOfMemory,
            error.AccessDenied => return VFSError.AccessDenied,
            else => return VFSError.IoError,
        };
    }

    fn vfs_deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        _ = allocator;

        // Clean up arena allocator - this handles all VFile instances automatically
        const self: *ProductionVFS = @ptrCast(@alignCast(ptr));
        self.arena.deinit();
    }
};

// ProductionFile struct removed - VFile is now a value type

test "ProductionVFS basic file operations" {
    const allocator = testing.allocator;

    var prod_vfs = ProductionVFS.init(allocator);
    defer prod_vfs.deinit();
    const vfs_interface = prod_vfs.vfs();

    const test_path = "/tmp/kausaldb_test_file";
    const test_data = "Hello, KausalDB!";

    {
        var write_file = try vfs_interface.create(test_path);
        defer write_file.close();

        const bytes_written = try write_file.write(test_data);
        try testing.expectEqual(test_data.len, bytes_written);
        try write_file.flush();
    }

    {
        var read_file = try vfs_interface.open(test_path, .read);
        defer {
            read_file.close();
            vfs_interface.remove(test_path) catch {};
        }

        var read_buffer: [256]u8 = undefined;
        const bytes_read = try read_file.read(&read_buffer);
        try testing.expectEqual(test_data.len, bytes_read);
        try testing.expectEqualStrings(test_data, read_buffer[0..bytes_read]);
    }
}

test "ProductionVFS directory operations" {
    const allocator = testing.allocator;

    var prod_vfs = ProductionVFS.init(allocator);
    defer prod_vfs.deinit();
    const vfs_interface = prod_vfs.vfs();

    const test_dir = "/tmp/kausaldb_test_dir";
    try vfs_interface.mkdir(test_dir);
    defer vfs_interface.rmdir(test_dir) catch {};

    // Test directory existence
    try testing.expect(vfs_interface.exists(test_dir));

    // Test directory iteration with arena allocator
    var iter_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer iter_arena.deinit();
    const iter_allocator = iter_arena.allocator();

    var iterator = try vfs_interface.iterate_directory(test_dir, iter_allocator);

    // Empty directory should have no entries
    try testing.expectEqual(@as(usize, 0), iterator.remaining());
    try testing.expect(iterator.next() == null);
}

test "ProductionVFS global filesystem sync" {
    const allocator = testing.allocator;

    var prod_vfs = ProductionVFS.init(allocator);
    defer prod_vfs.deinit();
    const vfs_interface = prod_vfs.vfs();

    const test_path = "/tmp/kausaldb_sync_test_file";
    const test_data = "Sync test data";

    {
        var test_file = try vfs_interface.create(test_path);
        defer test_file.close();

        _ = try test_file.write(test_data);
        try test_file.flush();
    }

    try vfs_interface.sync();

    // Verify file still exists and readable after sync
    {
        var verify_file = try vfs_interface.open(test_path, .read);
        defer {
            verify_file.close();
            vfs_interface.remove(test_path) catch {};
        }

        var read_buffer: [256]u8 = undefined;
        const bytes_read = try verify_file.read(&read_buffer);
        try testing.expectEqual(test_data.len, bytes_read);
        try testing.expectEqualStrings(test_data, read_buffer[0..bytes_read]);
    }
}

test "platform_global_sync coverage" {
    const result = platform_global_sync();
    switch (builtin.os.tag) {
        .linux, .macos, .windows => {
            // Should complete without error on supported platforms (Linux, macOS)
            // On Windows, provides best-effort flush behavior
            // Unsupported platforms return IoError

            try result;
        },
        else => {
            // Unsupported platforms should return IoError
            try testing.expectError(PlatformSyncError.IoError, result);
        },
    }
}
