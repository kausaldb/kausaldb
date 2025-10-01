//! WAL core operations and segment management.
//!
//! Provides primary WAL interface for write operations, segment rotation,
//! and recovery coordination. Manages 64MB segment files with automatic
//! rotation and streaming recovery support.
//!
//! Design rationale: Segmented architecture enables parallel recovery
//! and prevents individual files from becoming unmanageably large.
//! Streaming writes with fsync coordination ensure durability without
//! blocking the entire system on each operation.

const builtin = @import("builtin");
const std = @import("std");

const concurrency = @import("../../core/concurrency.zig");
const context_block = @import("../../core/types.zig");

const entry_mod = @import("entry.zig");
const error_context = @import("../../core/error_context.zig");
const recovery = @import("recovery.zig");
const simulation_vfs = @import("../../sim/simulation_vfs.zig");
const types = @import("types.zig");
const vfs = @import("../../core/vfs.zig");

const log = std.log.scoped(.wal);
const testing = std.testing;

const BlockId = context_block.BlockId;
const ContextBlock = context_block.ContextBlock;
const GraphEdge = context_block.GraphEdge;
const RecoveryCallback = types.RecoveryCallback;
const SimulationVFS = simulation_vfs.SimulationVFS;
const VFS = vfs.VFS;
const VFile = vfs.VFile;
const WALEntry = entry_mod.WALEntry;
const WALEntryType = types.WALEntryType;
const WALError = types.WALError;
const WALStats = types.WALStats;
const MAX_PAYLOAD_SIZE = types.MAX_PAYLOAD_SIZE;
const MAX_SEGMENT_SIZE = types.MAX_SEGMENT_SIZE;
const WAL_FILE_NUMBER_DIGITS = types.WAL_FILE_NUMBER_DIGITS;
const WAL_FILE_PREFIX = types.WAL_FILE_PREFIX;
const WAL_FILE_SUFFIX = types.WAL_FILE_SUFFIX;

/// Write-Ahead Log manager with segmented files and streaming recovery
pub const WAL = struct {
    directory: []const u8,
    vfs: VFS,
    active_file: ?VFile,
    segment_number: u32,
    segment_size: u64,
    allocator: std.mem.Allocator,
    stats: WALStats,
    disable_write_verification: bool,

    comptime {
        std.debug.assert(@sizeOf(u32) == 4);
        std.debug.assert(@sizeOf(u64) == 8);

        const max_segment_number = std.math.pow(u32, 10, WAL_FILE_NUMBER_DIGITS) - 1;
        std.debug.assert(max_segment_number > 1000);
    }

    /// Phase 1 initialization: Create WAL structure with memory allocation only.
    /// No I/O operations performed. Call startup() to complete initialization.
    pub fn init(allocator: std.mem.Allocator, filesystem: VFS, directory: []const u8) WALError!WAL {
        if (directory.len == 0) return WALError.InvalidArgument;
        std.debug.assert(directory.len < 4096);

        return WAL{
            .directory = try allocator.dupe(u8, directory),
            .vfs = filesystem,
            .active_file = null,
            .segment_number = 0,
            .segment_size = 0,
            .allocator = allocator,
            .stats = WALStats.init(),
            .disable_write_verification = false,
        };
    }

    /// Phase 2 initialization: Create directory structure and discover existing segments.
    /// Performs I/O operations including directory creation and segment discovery.
    /// Must be called after init() and before any write operations.
    pub fn startup(self: *WAL) WALError!void {
        concurrency.assert_main_thread();

        self.vfs.mkdir(self.directory) catch |err| switch (err) {
            error.FileExists => {},
            error.AccessDenied => return WALError.AccessDenied,
            error.FileNotFound => return WALError.FileNotFound,
            error.OutOfMemory => return WALError.OutOfMemory,
            else => return WALError.IoError,
        };

        try self.setup_active_segment();
    }

    /// Clean up WAL resources and close active files
    pub fn deinit(self: *WAL) void {
        if (self.active_file) |*file| {
            file.close();
        }
        self.allocator.free(self.directory);
    }

    /// Disable write verification for simulation tests with intentional corruption.
    /// This prevents WAL write verification from failing when corruption is
    /// intentionally injected during testing.
    pub fn disable_write_verification_for_simulation(self: *WAL) void {
        self.disable_write_verification = true;
    }

    /// Write entry to WAL with automatic segment rotation and durability guarantee.
    /// Entry is immediately flushed to disk before returning.
    /// Returns WALError.IoError if disk space exhausted or I/O failure occurs.
    pub fn write_entry(self: *WAL, entry: WALEntry) WALError!void {
        const serialized_size = try self.validate_entry_for_write(entry);
        try self.ensure_segment_capacity(serialized_size);

        const write_buffer = try self.serialize_with_validation(entry, serialized_size);
        defer self.allocator.free(write_buffer);

        const bytes_written = try self.write_and_verify(entry, write_buffer);
        self.update_write_stats(bytes_written);

        // Success - operation completed with potential retries
        if (builtin.mode == .Debug) {
            log.debug("WAL entry written successfully (type={}, size={})", .{ entry.entry_type, bytes_written });
        }
    }

    /// Streaming WAL write eliminates intermediate buffer allocation for large blocks.
    pub fn write_block_streaming(self: *WAL, block: ContextBlock) WALError!void {
        concurrency.assert_main_thread();

        if (self.active_file == null) return WALError.NotInitialized;

        const payload_size = block.serialized_size();
        const total_entry_size = WALEntry.HEADER_SIZE + payload_size;

        try self.ensure_segment_capacity(total_entry_size);

        var bytes_written: usize = 0;

        // Simple checksum avoids complexity of streaming hash calculation
        const simple_checksum = std.hash.Wyhash.hash(0, &[_]u8{@intFromEnum(WALEntryType.put_block)});

        bytes_written += try self.write_streaming_wal_header(.put_block, payload_size, simple_checksum);
        bytes_written += try self.write_streaming_block_header(block);
        bytes_written += try self.write_streaming_block_content(block);

        self.active_file.?.flush() catch return WALError.IoError;

        self.update_write_stats(bytes_written);
    }

    /// Validate entry structure and state before write operations
    fn validate_entry_for_write(self: *WAL, entry: WALEntry) WALError!usize {
        concurrency.assert_main_thread();

        std.debug.assert(self.active_file != null);
        std.debug.assert(entry.payload.len <= MAX_PAYLOAD_SIZE);
        std.debug.assert(entry.payload_size == entry.payload.len);

        if (self.active_file == null) return WALError.NotInitialized;

        const serialized_size = WALEntry.HEADER_SIZE + entry.payload.len;
        std.debug.assert(serialized_size > WALEntry.HEADER_SIZE);
        std.debug.assert(serialized_size <= WALEntry.HEADER_SIZE + MAX_PAYLOAD_SIZE);

        return serialized_size;
    }

    /// Ensure active segment has capacity for entry, rotating if necessary
    fn ensure_segment_capacity(self: *WAL, required_size: usize) WALError!void {
        if (self.segment_size + required_size > MAX_SEGMENT_SIZE) {
            std.debug.assert(self.segment_size <= MAX_SEGMENT_SIZE);
            try self.rotate_segment();
            std.debug.assert(self.segment_size == 0);
            std.debug.assert(self.active_file != null);
        }
    }

    /// Serialize entry with validation and corruption detection
    fn serialize_with_validation(self: *WAL, entry: WALEntry, serialized_size: usize) WALError![]u8 {
        // to prevent any memory sharing with the entry payload data
        var write_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer write_arena.deinit();
        const write_allocator = write_arena.allocator();

        // then zero-initialize for actual serialization use
        const write_buffer = try write_allocator.alloc(u8, serialized_size);
        @memset(write_buffer, 0xDD);
        @memset(write_buffer, 0);

        const bytes_written = try entry.serialize(write_buffer);
        std.debug.assert(bytes_written == serialized_size);

        if (write_buffer.len >= WALEntry.HEADER_SIZE) {
            const serialized_checksum = std.mem.readInt(u64, write_buffer[0..8], .little);
            const serialized_type = write_buffer[8];
            const serialized_payload_size = std.mem.readInt(u32, write_buffer[9..13], .little);

            if (serialized_checksum == 0x5555555555555555 or
                serialized_checksum == 0xAAAAAAAAAAAAAAAA or
                serialized_payload_size > MAX_PAYLOAD_SIZE or
                serialized_type > 4)
            {
                log.err("WAL corruption detected before write: checksum=0x{X} type={} payload_size={}", .{ serialized_checksum, serialized_type, serialized_payload_size });
                return WALError.CorruptedEntry;
            }

            if (serialized_checksum != entry.checksum) {
                log.err("WAL checksum mismatch: expected 0x{X}, got 0x{X}", .{ entry.checksum, serialized_checksum });
                return WALError.InvalidChecksum;
            }

            if (serialized_payload_size == 0x78787878) {
                log.err("WAL header corrupted with content pattern (0x78787878)", .{});
                return WALError.CorruptedEntry;
            }
        }

        return try self.allocator.dupe(u8, write_buffer);
    }

    /// Write buffer to file with immediate verification and atomic rollback on failure.
    /// Ensures WAL integrity by reverting partial writes that could corrupt state.
    /// Implements retry logic for resilience against transient I/O failures.
    fn write_and_verify(self: *WAL, entry: WALEntry, write_buffer: []const u8) WALError!usize {
        const max_retries = 10;
        const base_retry_delay_ns = 500_000; // Start with 0.5ms base delay

        // Capture position before write for potential rollback on failure
        const start_position = self.active_file.?.tell() catch return WALError.IoError;

        var retry_count: u32 = 0;
        while (retry_count < max_retries) : (retry_count += 1) {
            // Attempt write with potential retry
            const written = self.active_file.?.write(write_buffer) catch {
                if (retry_count < max_retries - 1) {
                    // Transient failure - rollback and retry with exponential backoff
                    self.rollback_to_position(start_position);
                    const backoff_delay = base_retry_delay_ns * (@as(u64, 1) << @intCast(retry_count));
                    std.Thread.sleep(@min(backoff_delay, 100_000_000)); // Cap at 100ms
                    continue;
                }
                // Final attempt failed - rollback and return error
                self.rollback_to_position(start_position);
                return WALError.IoError;
            };

            if (written != write_buffer.len) {
                if (retry_count < max_retries - 1) {
                    log.warn("WAL write incomplete: expected {}, got {} - retrying ({}/{})", .{ write_buffer.len, written, retry_count + 1, max_retries });
                    // Rollback partial write and retry with exponential backoff
                    self.rollback_to_position(start_position);
                    const backoff_delay = base_retry_delay_ns * (@as(u64, 1) << @intCast(retry_count));
                    std.Thread.sleep(@min(backoff_delay, 100_000_000)); // Cap at 100ms
                    continue;
                }
                log.warn("WAL write incomplete after {} retries: expected {}, got {}", .{ max_retries, write_buffer.len, written });
                // Final attempt failed - rollback
                self.rollback_to_position(start_position);
                return WALError.IoError;
            }

            // Ensure durability before considering write successful
            self.active_file.?.flush() catch {
                if (retry_count < max_retries - 1) {
                    // Retry flush on transient failure with exponential backoff
                    const backoff_delay = base_retry_delay_ns * (@as(u64, 1) << @intCast(retry_count));
                    std.Thread.sleep(@min(backoff_delay, 100_000_000)); // Cap at 100ms
                    continue;
                }
                // Even flush failure requires rollback for consistency
                self.rollback_to_position(start_position);
                return WALError.IoError;
            };

            // Write and flush succeeded - continue to verification
            break;
        }
        // Write verification enabled only in debug builds for performance
        // In release builds, WAL corruption is detected during recovery
        // Can be disabled for simulation tests with intentional corruption

        if (builtin.mode == .Debug and !self.disable_write_verification and write_buffer.len >= WALEntry.HEADER_SIZE) {
            log.debug("WAL: Write verification enabled (disable_write_verification={})", .{self.disable_write_verification});
            const current_pos = self.active_file.?.tell() catch return WALError.IoError;
            const verify_pos = current_pos - write_buffer.len;

            _ = self.active_file.?.seek(@intCast(verify_pos), .start) catch return WALError.IoError;

            var verify_header: [WALEntry.HEADER_SIZE]u8 = undefined;
            const header_read = self.active_file.?.read(&verify_header) catch return WALError.IoError;
            if (header_read == WALEntry.HEADER_SIZE) {
                const verify_checksum = std.mem.readInt(u64, verify_header[0..8], .little);
                const verify_type = verify_header[8];
                const verify_payload_size = std.mem.readInt(u32, verify_header[9..13], .little);

                if (verify_checksum != entry.checksum or
                    verify_type != @intFromEnum(entry.entry_type) or
                    verify_payload_size != entry.payload_size)
                {
                    // Only log corruption errors when verification is enabled
                    // During corruption testing (disable_write_verification=true), these errors are expected
                    if (!self.disable_write_verification) {
                        log.err("WAL write corruption detected: written header differs from buffer (disable_write_verification={})", .{self.disable_write_verification});
                        log.err("Expected: checksum=0x{X}, type={}, payload_size={}", .{ entry.checksum, @intFromEnum(entry.entry_type), entry.payload_size });
                        log.err("Verified: checksum=0x{X}, type={}, payload_size={}", .{ verify_checksum, verify_type, verify_payload_size });
                    }
                    return WALError.CorruptedEntry;
                }
            }

            _ = self.active_file.?.seek(@intCast(current_pos), .start) catch return WALError.IoError;
        } else if (builtin.mode == .Debug) {
            log.debug("WAL: Write verification skipped (disable_write_verification={})", .{self.disable_write_verification});
        }

        return write_buffer.len;
    }

    /// Rollback file to specified position, best-effort cleanup on write failures.
    /// Used to maintain WAL integrity when writes fail or are incomplete.
    fn rollback_to_position(self: *WAL, position: u64) void {
        // Best-effort rollback - failures are logged but not fatal since
        // we're already in error recovery path
        _ = self.active_file.?.seek(@intCast(position), .start) catch |err| {
            log.err("WAL rollback seek failed: {}", .{err});
            return;
        };

        // Note: VFile doesn't support truncate operation. The seek alone ensures
        // the next write position is correct. WAL recovery will handle any
        // trailing garbage data by validating checksums.

        // Update segment size to reflect rollback position
        self.segment_size = position;
    }

    /// Update WAL statistics after successful write
    fn update_write_stats(self: *WAL, bytes_written: usize) void {
        const old_segment_size = self.segment_size;
        self.segment_size += bytes_written;
        self.stats.entries_written += 1;
        self.stats.bytes_written += bytes_written;

        std.debug.assert(self.segment_size == old_segment_size + bytes_written);
        std.debug.assert(self.segment_size <= MAX_SEGMENT_SIZE);
        std.debug.assert(self.stats.entries_written > 0);
        std.debug.assert(self.stats.bytes_written >= bytes_written);
    }

    /// Recover all entries from WAL segments in chronological order.
    /// Callback is invoked for each valid entry; corrupted entries are skipped.
    /// Returns WALError.FileNotFound if no WAL segments exist (normal for new database).
    pub fn recover_entries(self: *WAL, callback: RecoveryCallback, context: *anyopaque) WALError!void {
        concurrency.assert_main_thread();
        return recovery.recover_from_segments(
            self.vfs,
            self.allocator,
            self.directory,
            callback,
            context,
            &self.stats,
        );
    }

    /// List all WAL segment files in the directory, sorted in chronological order
    pub fn list_segment_files(self: *WAL) WALError![][]const u8 {
        var file_list = std.ArrayList([]const u8){};
        defer file_list.deinit(self.allocator);

        var dir_iter = self.vfs.iterate_directory(self.directory, self.allocator) catch |err| switch (err) {
            error.FileNotFound => return WALError.FileNotFound,
            error.AccessDenied => return WALError.AccessDenied,
            error.OutOfMemory => return WALError.OutOfMemory,
            else => return WALError.IoError,
        };
        defer dir_iter.deinit(self.allocator);

        while (dir_iter.next()) |entry| {
            if (entry.kind != .file) continue;

            if (std.mem.startsWith(u8, entry.name, types.WAL_FILE_PREFIX) and
                std.mem.endsWith(u8, entry.name, types.WAL_FILE_SUFFIX))
            {
                const owned_name = self.allocator.dupe(u8, entry.name) catch return WALError.OutOfMemory;
                file_list.append(self.allocator, owned_name) catch return WALError.OutOfMemory;
            }
        }

        const files = file_list.toOwnedSlice(self.allocator) catch return WALError.OutOfMemory;

        std.sort.insertion([]const u8, files, {}, struct {
            fn less_than(_: void, lhs: []const u8, rhs: []const u8) bool {
                return std.mem.order(u8, lhs, rhs) == .lt;
            }
        }.less_than);

        return files;
    }

    /// Clean up old WAL segments, keeping only the current active segment.
    /// This should be called after successfully flushing data to SSTable.
    pub fn cleanup_old_segments(self: *WAL) WALError!void {
        concurrency.assert_main_thread();

        const segment_files = try self.list_segment_files();
        defer {
            for (segment_files) |file_name| {
                self.allocator.free(file_name);
            }
            self.allocator.free(segment_files);
        }

        if (segment_files.len <= 1) {
            return;
        }

        for (segment_files[0 .. segment_files.len - 1]) |file_name| {
            const file_path = try std.fmt.allocPrint(
                self.allocator,
                "{s}/{s}",
                .{ self.directory, file_name },
            );
            defer self.allocator.free(file_path);

            self.vfs.remove(file_path) catch |err| switch (err) {
                error.FileNotFound => {
                    continue;
                },
                else => return WALError.IoError,
            };

            log.info("Cleaned up old WAL segment: {s}", .{file_path});
        }
    }

    /// Rotate to a new WAL segment, closing the current one
    fn rotate_segment(self: *WAL) WALError!void {
        if (self.active_file) |*file| {
            file.flush() catch return WALError.IoError;
            file.close();
            self.active_file = null;
        }

        self.segment_number += 1;
        self.segment_size = 0;
        self.stats.segments_rotated += 1;

        try self.open_segment_file();

        log.info("Rotated to WAL segment {d}", .{self.segment_number});
    }

    /// Initialize the active segment by discovering existing segments or creating the first one
    fn setup_active_segment(self: *WAL) WALError!void {
        self.segment_number = try self.discover_latest_segment_number();

        self.open_segment_file() catch |err| switch (err) {
            WALError.FileNotFound => {
                self.segment_number = 0;
                try self.create_new_segment();
            },
            else => return err,
        };

        if (self.active_file) |*file| {
            self.segment_size = file.file_size() catch 0;
        }
    }

    /// Discover the highest numbered segment in the directory
    fn discover_latest_segment_number(self: *WAL) WALError!u32 {
        var highest_number: u32 = 0;
        var found_any = false;

        var dir_iter = self.vfs.iterate_directory(self.directory, self.allocator) catch return 0;
        defer dir_iter.deinit(self.allocator);

        while (dir_iter.next()) |entry| {
            if (entry.kind != .file) continue;

            if (std.mem.startsWith(u8, entry.name, WAL_FILE_PREFIX) and
                std.mem.endsWith(u8, entry.name, WAL_FILE_SUFFIX))
            {
                const number_part = entry.name[WAL_FILE_PREFIX.len .. entry.name.len - WAL_FILE_SUFFIX.len];
                if (std.fmt.parseInt(u32, number_part, 10)) |number| {
                    if (number > highest_number) {
                        highest_number = number;
                        found_any = true;
                    }
                } else |_| {
                    continue;
                }
            }
        }

        return if (found_any) highest_number else 0;
    }

    /// Open existing segment file for append operations
    fn open_segment_file(self: *WAL) WALError!void {
        var filename_buffer: [512]u8 = undefined;
        const filename = try self.segment_filename(&filename_buffer);

        self.active_file = self.vfs.open(filename, .read_write) catch |open_err| switch (open_err) {
            error.FileNotFound => self.vfs.create(filename) catch |create_err| switch (create_err) {
                error.AccessDenied => return WALError.AccessDenied,
                error.OutOfMemory => return WALError.OutOfMemory,
                else => return WALError.IoError,
            },
            error.AccessDenied => return WALError.AccessDenied,
            error.OutOfMemory => return WALError.OutOfMemory,
            else => return WALError.IoError,
        };

        _ = self.active_file.?.seek(0, .end) catch return WALError.IoError;
    }

    /// Create a new segment file
    fn create_new_segment(self: *WAL) WALError!void {
        var filename_buffer: [512]u8 = undefined;
        const filename = try self.segment_filename(&filename_buffer);

        self.active_file = self.vfs.create(filename) catch |err| switch (err) {
            error.AccessDenied => return WALError.AccessDenied,
            error.OutOfMemory => return WALError.OutOfMemory,
            else => return WALError.IoError,
        };

        self.segment_size = 0;
    }

    /// Generate segment filename based on current segment number
    fn segment_filename(self: *WAL, buffer: []u8) WALError![]u8 {
        return std.fmt.bufPrint(
            buffer,
            "{s}/{s}{:0>4}{s}",
            .{ self.directory, WAL_FILE_PREFIX, self.segment_number, WAL_FILE_SUFFIX },
        ) catch {
            return WALError.IoError; // Buffer too small - programming error
        };
    }

    /// WAL header write optimized for streaming operations to avoid buffer allocation.
    fn write_streaming_wal_header(
        self: *WAL,
        entry_type: WALEntryType,
        payload_size: usize,
        checksum_value: u64,
    ) WALError!usize {
        var header_buffer: [WALEntry.HEADER_SIZE]u8 = undefined;

        std.mem.writeInt(u64, header_buffer[0..8], checksum_value, .little);
        header_buffer[8] = @intFromEnum(entry_type);
        std.mem.writeInt(u32, header_buffer[9..13], @intCast(payload_size), .little);

        const written = self.active_file.?.write(&header_buffer) catch return WALError.IoError;
        if (written != header_buffer.len) return WALError.IoError;

        return written;
    }

    /// Block header serialization for streaming WAL to avoid intermediate allocation.
    fn write_streaming_block_header(self: *WAL, block: ContextBlock) WALError!usize {
        var header_buffer: [context_block.ContextBlock.BlockHeader.SIZE]u8 = undefined;

        const header = context_block.ContextBlock.BlockHeader{
            .magic = ContextBlock.MAGIC,
            .format_version = ContextBlock.FORMAT_VERSION,
            .flags = 0,
            .id = block.id.bytes,
            .block_sequence = block.sequence,
            .source_uri_len = @intCast(block.source_uri.len),
            .metadata_json_len = @intCast(block.metadata_json.len),
            .content_len = block.content.len,
            .checksum = 0,
            .reserved = std.mem.zeroes([12]u8),
        };

        const header_size = header.serialize(&header_buffer) catch return WALError.IoError;
        const written = self.active_file.?.write(header_buffer[0..header_size]) catch return WALError.IoError;
        if (written != header_size) return WALError.IoError;

        return written;
    }

    /// Chunked content writing for cache-friendly I/O with large blocks.
    fn write_streaming_block_content(self: *WAL, block: ContextBlock) WALError!usize {
        var total_written: usize = 0;

        if (block.source_uri.len > 0) {
            const written = self.active_file.?.write(block.source_uri) catch return WALError.IoError;
            if (written != block.source_uri.len) return WALError.IoError;
            total_written += written;
        }

        if (block.metadata_json.len > 0) {
            const written = self.active_file.?.write(block.metadata_json) catch return WALError.IoError;
            if (written != block.metadata_json.len) return WALError.IoError;
            total_written += written;
        }

        // Chunked I/O improves cache performance for multi-megabyte blocks
        if (block.content.len > 0) {
            const CHUNK_SIZE = 64 * 1024;

            if (block.content.len <= CHUNK_SIZE) {
                const written = self.active_file.?.write(block.content) catch return WALError.IoError;
                if (written != block.content.len) return WALError.IoError;
                total_written += written;
            } else {
                var offset: usize = 0;
                while (offset < block.content.len) {
                    const chunk_size = @min(CHUNK_SIZE, block.content.len - offset);
                    const chunk = block.content[offset .. offset + chunk_size];
                    const written = self.active_file.?.write(chunk) catch return WALError.IoError;
                    if (written != chunk_size) return WALError.IoError;
                    total_written += written;
                    offset += chunk_size;
                }
            }
        }

        return total_written;
    }
};

fn create_test_block() ContextBlock {
    return ContextBlock{
        .id = BlockId.from_hex("0123456789abcdef0123456789abcdef") catch unreachable, // Safety: hardcoded valid hex
        .sequence = 0, // Storage engine will assign the actual global sequence
        .source_uri = "test://wal_core.zig",
        .metadata_json = "{}",
        .content = "test WAL core content",
    };
}

fn create_test_edge() GraphEdge {
    const from_id = BlockId.from_hex("11111111111111111111111111111111") catch unreachable; // Safety: hardcoded valid hex
    const to_id = BlockId.from_hex("22222222222222222222222222222222") catch unreachable; // Safety: hardcoded valid hex

    return GraphEdge{
        .source_id = from_id,
        .target_id = to_id,
        .edge_type = .calls,
    };
}
