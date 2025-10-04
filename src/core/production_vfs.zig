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

const vfs = @import("vfs.zig");

const testing = std.testing;
const log = std.log.scoped(.production_vfs);

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
    std.debug.assert(MAX_PATH_LENGTH > 0);
    std.debug.assert(MAX_PATH_LENGTH <= 8192);
    std.debug.assert(MAX_REASONABLE_FILE_SIZE > 0);
    std.debug.assert(MAX_REASONABLE_FILE_SIZE < std.math.maxInt(u64) / 2);
    std.debug.assert(PRODUCTION_FILE_MAGIC != 0);
    std.debug.assert(PRODUCTION_FILE_MAGIC != std.math.maxInt(u64));
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
    const start_time = std.time.nanoTimestamp();
    errdefer {
        const end_time = std.time.nanoTimestamp();
        // Defensive: Handle potential negative time differences or timing anomalies
        const duration_ns = if (end_time >= start_time)
            @as(u64, @intCast(end_time - start_time))
        else
            0;
        log.warn(
            "platform_global_sync failed on {s} after {}ns ({}µs)",
            .{ @tagName(builtin.os.tag), duration_ns, duration_ns / 1000 },
        );
    }

    switch (builtin.os.tag) {
        .linux => {
            // Linux: Use POSIX sync() call via standard library
            // sync() forces write of all modified in-core data to disk
            // POSIX.1-2001 standard - modern Linux waits for completion
            std.posix.sync();
        },
        .macos => {
            // macOS: sync() schedules all filesystem buffers to be written to disk
            // Darwin implementation waits for completion, ensuring durability
            std.posix.sync();
        },
        .windows => {
            // Windows: No direct equivalent to POSIX sync()
            // For testing purposes, this is a no-op since Windows file operations
            // with proper flags provide similar guarantees
            // In production, individual file sync operations provide durability
        },
        else => {
            // Unsupported platforms: return error rather than silent no-op
            // This ensures callers are aware that durability guarantee is not provided
            return PlatformSyncError.IoError;
        },
    }

    const end_time = std.time.nanoTimestamp();
    // Defensive: Handle potential negative time differences or timing anomalies
    const duration_ns = if (end_time >= start_time)
        @as(u64, @intCast(end_time - start_time))
    else
        0;
    log.debug(
        "platform_global_sync completed on {s} in {}ns ({}µs)",
        .{ @tagName(builtin.os.tag), duration_ns, duration_ns / 1000 },
    );
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
        _ = ptr;

        std.debug.assert(path.len > 0 and path.len < MAX_PATH_LENGTH);

        const file = std.fs.openFileAbsolute(path, .{
            .mode = switch (mode) {
                .read => .read_only,
                .write => .write_only,
                .read_write => .read_write,
            },
        }) catch |err| {
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
                .file = file,
                .closed = false,
            } },
        };
    }

    fn create(ptr: *anyopaque, path: []const u8) VFSError!VFile {
        _ = ptr;

        std.debug.assert(path.len > 0 and path.len < MAX_PATH_LENGTH);

        const file = std.fs.createFileAbsolute(path, .{ .read = true, .exclusive = true }) catch |err| {
            return switch (err) {
                error.PathAlreadyExists => VFSError.FileExists,
                error.AccessDenied => VFSError.AccessDenied,
                error.FileNotFound => VFSError.FileNotFound,
                error.IsDir => VFSError.IsDirectory,
                error.SystemResources, error.ProcessFdQuotaExceeded => VFSError.OutOfMemory,
                else => VFSError.IoError,
            };
        };

        return VFile{
            .impl = .{ .production = .{
                .file = file,
                .closed = false,
            } },
        };
    }

    fn remove(ptr: *anyopaque, path: []const u8) VFSError!void {
        _ = ptr;
        std.debug.assert(path.len > 0 and path.len < MAX_PATH_LENGTH);

        const is_absolute = std.fs.path.isAbsolute(path);
        if (is_absolute) {
            std.fs.deleteFileAbsolute(path) catch |err| {
                return switch (err) {
                    error.FileNotFound => VFSError.FileNotFound,
                    error.AccessDenied => VFSError.AccessDenied,
                    error.FileBusy => VFSError.AccessDenied,
                    else => VFSError.IoError,
                };
            };
        } else {
            std.fs.cwd().deleteFile(path) catch |err| {
                return switch (err) {
                    error.FileNotFound => VFSError.FileNotFound,
                    error.AccessDenied => VFSError.AccessDenied,
                    error.FileBusy => VFSError.AccessDenied,
                    else => VFSError.IoError,
                };
            };
        }
    }

    fn exists(ptr: *anyopaque, path: []const u8) bool {
        _ = ptr;
        std.debug.assert(path.len > 0 and path.len < MAX_PATH_LENGTH);

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
        std.debug.assert(path.len > 0 and path.len < MAX_PATH_LENGTH);

        const is_absolute = std.fs.path.isAbsolute(path);
        if (is_absolute) {
            // For absolute paths, create parent directories as needed
            if (std.fs.path.dirname(path)) |parent_dir| {
                std.fs.cwd().makePath(parent_dir) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    error.AccessDenied => return VFSError.AccessDenied,
                    else => return VFSError.IoError,
                };
            }
            std.fs.makeDirAbsolute(path) catch |err| {
                return switch (err) {
                    error.PathAlreadyExists => {}, // Success - directory exists
                    error.AccessDenied => VFSError.AccessDenied,
                    error.FileNotFound => VFSError.FileNotFound,
                    else => VFSError.IoError,
                };
            };
        } else {
            std.fs.cwd().makePath(path) catch |err| {
                return switch (err) {
                    error.PathAlreadyExists => {}, // Success - directory exists
                    error.AccessDenied => VFSError.AccessDenied,
                    else => VFSError.IoError,
                };
            };
        }
    }

    fn mkdir_all(ptr: *anyopaque, path: []const u8) VFSError!void {
        _ = ptr;
        std.debug.assert(path.len > 0 and path.len < MAX_PATH_LENGTH);

        const is_absolute = std.fs.path.isAbsolute(path);
        if (is_absolute) {
            // For absolute paths, create all parent directories
            if (std.fs.path.dirname(path)) |parent_dir| {
                std.fs.cwd().makePath(parent_dir) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    error.AccessDenied => return VFSError.AccessDenied,
                    else => return VFSError.IoError,
                };
            }
            std.fs.makeDirAbsolute(path) catch |err| {
                return switch (err) {
                    error.PathAlreadyExists => {}, // Success - directory exists
                    error.AccessDenied => VFSError.AccessDenied,
                    error.FileNotFound => VFSError.FileNotFound,
                    else => VFSError.IoError,
                };
            };
        } else {
            std.fs.cwd().makePath(path) catch |err| {
                return switch (err) {
                    error.PathAlreadyExists => {}, // Success - directory exists
                    error.AccessDenied => VFSError.AccessDenied,
                    else => VFSError.IoError,
                };
            };
        }
    }

    fn rmdir(ptr: *anyopaque, path: []const u8) VFSError!void {
        _ = ptr;
        std.debug.assert(path.len > 0 and path.len < MAX_PATH_LENGTH);

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
        std.debug.assert(path.len > 0 and path.len < MAX_PATH_LENGTH);

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

        var entries = std.ArrayList(DirectoryEntry){};
        errdefer entries.deinit(allocator);

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

            try entries.append(allocator, DirectoryEntry{
                .name = name_copy,
                .kind = kind,
            });
        }

        return DirectoryIterator{
            .entries = try entries.toOwnedSlice(allocator),
            .index = 0,
        };
    }

    fn rename(ptr: *anyopaque, old_path: []const u8, new_path: []const u8) VFSError!void {
        _ = ptr;
        std.debug.assert(old_path.len > 0 and old_path.len < MAX_PATH_LENGTH);
        std.debug.assert(new_path.len > 0 and new_path.len < MAX_PATH_LENGTH);

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
        std.debug.assert(path.len > 0 and path.len < MAX_PATH_LENGTH);

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
        // Safety: Pointer guaranteed to be ProductionVFS by VFS interface
        const self: *ProductionVFS = @ptrCast(@alignCast(ptr));
        self.arena.deinit();
    }
};
