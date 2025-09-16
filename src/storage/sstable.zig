//! SSTable (Sorted String Table) implementation for KausalDB LSM-Tree.
//!
//! ## On-Disk Format Philosophy
//!
//! The SSTable on-disk format is designed with three principles in mind:
//!
//! 1.  **Performance:** The file header is 64-byte aligned. This ensures that it fits
//!     cleanly within a typical CPU cache line, improving read performance.
//!
//! 2.  **Robustness:** All data structures are protected by checksums. This allows the
//!     engine to detect silent disk corruption (bit rot) and fail gracefully rather
//!     than propagating corrupted data.
//!
//! 3.  **Forward/Backward Compatibility:** The header includes a `format_version`. This
//!     allows future versions of KausalDB to read older SSTables and perform safe
//!     upgrades. The `reserved` fields provide space for new features without
//!     breaking the format for older clients.

const builtin = @import("builtin");
const std = @import("std");

const assert_mod = @import("../core/assert.zig");
const bloom_filter = @import("bloom_filter.zig");
const context_block = @import("../core/types.zig");
const memory = @import("../core/memory.zig");
const ownership = @import("../core/ownership.zig");
const simulation_vfs = @import("../sim/simulation_vfs.zig");
const vfs = @import("../core/vfs.zig");

const comptime_assert = assert_mod.comptime_assert;
const log = std.log.scoped(.sstable);
const testing = std.testing;

const ArenaCoordinator = memory.ArenaCoordinator;
const BlockId = context_block.BlockId;
const BloomFilter = bloom_filter.BloomFilter;
const ContextBlock = context_block.ContextBlock;
const GraphEdge = context_block.GraphEdge;
const OwnedBlock = ownership.OwnedBlock;
const ParsedBlock = context_block.ParsedBlock;
const SimulationVFS = simulation_vfs.SimulationVFS;
const VFS = vfs.VFS;
const VFile = vfs.VFile;

/// SSTable file format:
/// | Magic (4) | Version (4) | Index Offset (8) | Block Count (4) | Reserved (12) |
/// | Block Data ... |
/// | Index Entries ... |
/// | Footer Checksum (8) |
pub const SSTable = struct {
    /// Arena coordinator pointer for stable allocation access (remains valid across arena resets)
    /// CRITICAL: Must be pointer to prevent coordinator struct copying corruption
    arena_coordinator: *const ArenaCoordinator,
    /// Stable backing allocator for path strings and data structures
    backing_allocator: std.mem.Allocator,
    filesystem: VFS,
    file_path: []const u8,
    block_count: u32,
    index: std.array_list.Managed(IndexEntry),
    bloom_filter: ?BloomFilter,

    const MAGIC = [4]u8{ 'S', 'S', 'T', 'B' }; // "SSTB" for SSTable Blocks
    const VERSION = 1;
    const HEADER_SIZE = 64; // Cache-aligned header size for performance
    const FOOTER_SIZE = 8; // Checksum

    /// Index entry pointing to a block within the SSTable
    const IndexEntry = struct {
        block_id: BlockId,
        offset: u64,
        size: u32,

        const SERIALIZED_SIZE = 16 + 8 + 4; // BlockId + offset + size

        /// Serialize index entry to binary format for on-disk storage
        ///
        /// Writes the block ID, offset, and size to the buffer in little-endian format.
        /// Buffer must have at least SERIALIZED_SIZE bytes available.
        pub fn serialize(self: IndexEntry, buffer: []u8) !void {
            assert_mod.assert(buffer.len >= SERIALIZED_SIZE);

            var offset: usize = 0;

            @memcpy(buffer[offset .. offset + 16], &self.block_id.bytes);
            offset += 16;

            std.mem.writeInt(u64, buffer[offset..][0..8], self.offset, .little);
            offset += 8;

            std.mem.writeInt(u32, buffer[offset..][0..4], self.size, .little);
        }

        /// Deserialize index entry from binary format stored on disk
        ///
        /// Reads the block ID, offset, and size from little-endian format.
        /// Buffer must contain at least SERIALIZED_SIZE bytes of valid data.
        pub fn deserialize(buffer: []const u8) !IndexEntry {
            assert_mod.assert(buffer.len >= SERIALIZED_SIZE);
            if (buffer.len < SERIALIZED_SIZE) return error.BufferTooSmall;

            var offset: usize = 0;

            var id_bytes: [16]u8 = undefined;
            @memcpy(&id_bytes, buffer[offset .. offset + 16]);
            const block_id = BlockId.from_bytes(id_bytes);
            offset += 16;

            const block_offset = std.mem.readInt(u64, buffer[offset..][0..8], .little);
            offset += 8;

            const size = std.mem.readInt(u32, buffer[offset..][0..4], .little);

            return IndexEntry{
                .block_id = block_id,
                .offset = block_offset,
                .size = size,
            };
        }
    };

    /// File header structure (64-byte aligned)
    const Header = struct {
        magic: [4]u8, // 4 bytes: "SSTB"
        format_version: u16, // 2 bytes: Major.minor versioning
        flags: u16, // 2 bytes: Feature flags
        index_offset: u64, // 8 bytes: Offset to index section
        block_count: u32, // 4 bytes: Number of blocks
        file_checksum: u32, // 4 bytes: CRC32 of entire file
        created_timestamp: u64, // 8 bytes: Unix timestamp
        bloom_filter_offset: u64, // 8 bytes: Offset to bloom filter
        bloom_filter_size: u32, // 4 bytes: Size of serialized bloom filter
        reserved: [20]u8, // 20 bytes: Reserved for future use

        comptime {
            comptime_assert(@sizeOf(Header) == 64, "SSTable Header must be exactly 64 bytes for cache-aligned performance");
            comptime_assert(HEADER_SIZE == @sizeOf(Header), "HEADER_SIZE constant must match actual Header struct size");
            comptime_assert(4 + @sizeOf(u16) + @sizeOf(u16) + @sizeOf(u64) + @sizeOf(u32) +
                @sizeOf(u32) + @sizeOf(u64) + @sizeOf(u64) + @sizeOf(u32) + 20 == 64, "SSTable Header field sizes must sum to exactly 64 bytes");
        }

        /// Serialize SSTable header to binary format for on-disk storage
        ///
        /// Writes all header fields including magic number, version, counts, and offsets
        /// to the buffer in little-endian format. Essential for SSTable file format integrity.
        pub fn serialize(self: Header, buffer: []u8) !void {
            assert_mod.assert(buffer.len >= HEADER_SIZE);

            var offset: usize = 0;

            @memcpy(buffer[offset .. offset + 4], &self.magic);
            offset += 4;

            std.mem.writeInt(u16, buffer[offset..][0..2], self.format_version, .little);
            offset += 2;

            std.mem.writeInt(u16, buffer[offset..][0..2], self.flags, .little);
            offset += 2;

            std.mem.writeInt(u64, buffer[offset..][0..8], self.index_offset, .little);
            offset += 8;

            std.mem.writeInt(u32, buffer[offset..][0..4], self.block_count, .little);
            offset += 4;

            std.mem.writeInt(u32, buffer[offset..][0..4], self.file_checksum, .little);
            offset += 4;

            std.mem.writeInt(u64, buffer[offset..][0..8], self.created_timestamp, .little);
            offset += 8;

            std.mem.writeInt(u64, buffer[offset..][0..8], self.bloom_filter_offset, .little);
            offset += 8;

            std.mem.writeInt(u32, buffer[offset..][0..4], self.bloom_filter_size, .little);
            offset += 4;

            @memset(buffer[offset .. offset + 20], 0);
        }

        /// Deserialize SSTable header from binary format during file loading
        ///
        /// Reads and validates the complete header structure from storage buffer.
        /// Critical for ensuring data integrity when opening existing SSTables.
        pub fn deserialize(buffer: []const u8) !Header {
            assert_mod.assert(buffer.len >= HEADER_SIZE);
            if (buffer.len < HEADER_SIZE) return error.BufferTooSmall;

            var offset: usize = 0;

            const magic = buffer[offset .. offset + 4];
            if (!std.mem.eql(u8, magic, &MAGIC)) return error.InvalidMagic;
            offset += 4;

            const format_version = std.mem.readInt(u16, buffer[offset..][0..2], .little);
            if (format_version > VERSION) return error.UnsupportedVersion;
            offset += 2;

            const flags = std.mem.readInt(u16, buffer[offset..][0..2], .little);
            offset += 2;

            const index_offset = std.mem.readInt(u64, buffer[offset..][0..8], .little);
            offset += 8;

            const block_count = std.mem.readInt(u32, buffer[offset..][0..4], .little);
            offset += 4;

            const file_checksum = std.mem.readInt(u32, buffer[offset..][0..4], .little);
            offset += 4;

            const created_timestamp = std.mem.readInt(u64, buffer[offset..][0..8], .little);
            offset += 8;

            const bloom_filter_offset = std.mem.readInt(u64, buffer[offset..][0..8], .little);
            offset += 8;

            const bloom_filter_size = std.mem.readInt(u32, buffer[offset..][0..4], .little);
            offset += 4;

            const reserved = buffer[offset .. offset + 20];
            for (reserved) |byte| {
                if (byte != 0) return error.InvalidReservedBytes;
            }

            return Header{
                .magic = MAGIC,
                .format_version = format_version,
                .flags = flags,
                .index_offset = index_offset,
                .block_count = block_count,
                .file_checksum = file_checksum,
                .created_timestamp = created_timestamp,
                .bloom_filter_offset = bloom_filter_offset,
                .bloom_filter_size = bloom_filter_size,
                .reserved = [_]u8{0} ** 20,
            };
        }
    };

    /// Initialize a new SSTable with arena coordinator, backing allocator, filesystem, and file path.
    /// Uses Arena Coordinator Pattern for content allocation and backing allocator for structures.
    /// CRITICAL: ArenaCoordinator must be passed by pointer to prevent struct copying corruption.
    pub fn init(
        coordinator: *const ArenaCoordinator,
        backing: std.mem.Allocator,
        filesystem: VFS,
        file_path: []const u8,
    ) SSTable {
        assert_mod.assert_not_empty(file_path, "SSTable file_path cannot be empty", .{});
        assert_mod.assert_fmt(file_path.len < 4096, "SSTable file_path too long: {} bytes", .{file_path.len});
        // Safety: Converting pointer to integer for null pointer validation
        assert_mod.assert_fmt(@intFromPtr(file_path.ptr) != 0, "SSTable file_path has null pointer", .{});

        return SSTable{
            .arena_coordinator = coordinator,
            .backing_allocator = backing,
            .filesystem = filesystem,
            .file_path = file_path,
            .block_count = 0,
            .index = std.array_list.Managed(IndexEntry).init(backing),
            .bloom_filter = null,
        };
    }

    /// Clean up all allocated resources including the file path and index.
    /// Safe to call multiple times - subsequent calls are no-ops.
    pub fn deinit(self: *SSTable) void {
        self.backing_allocator.free(self.file_path);
        self.index.deinit();
    }

    /// Write blocks to SSTable file in sorted order
    pub fn write_blocks(self: *SSTable, blocks: anytype) !void {
        const BlocksType = @TypeOf(blocks);
        const supported_block_write = switch (BlocksType) {
            []const ContextBlock => true,
            []ContextBlock => true,
            []const ownership.ComptimeOwnedBlockType(.sstable_manager) => true,
            []ownership.ComptimeOwnedBlockType(.sstable_manager) => true,
            []const OwnedBlock => true,
            []OwnedBlock => true,
            else => false,
        };

        if (!supported_block_write) {
            @compileError("write_blocks() called with unsupported type '" ++ @typeName(BlocksType) ++ "'. Accepts []const ContextBlock, []ContextBlock, []const OwnedBlock, or []OwnedBlock only");
        }
        assert_mod.assert_not_empty(blocks, "Cannot write empty blocks array", .{});
        assert_mod.assert_fmt(blocks.len <= 1000000, "Too many blocks for single SSTable: {}", .{blocks.len});

        self.index.clearAndFree();
        // Safety: Converting pointer to integer for null pointer validation
        assert_mod.assert_fmt(@intFromPtr(blocks.ptr) != 0, "Blocks array has null pointer", .{});

        for (blocks, 0..) |block_value, i| {
            const block_data = switch (BlocksType) {
                []const ContextBlock => block_value,
                []ContextBlock => block_value,
                []const ownership.ComptimeOwnedBlockType(.sstable_manager) => block_value.read(.sstable_manager),
                []ownership.ComptimeOwnedBlockType(.sstable_manager) => block_value.read(.sstable_manager),
                []const OwnedBlock => block_value.read(.sstable_manager),
                []OwnedBlock => block_value.read(.sstable_manager),
                else => unreachable,
            };

            assert_mod.assert_fmt(block_data.content.len > 0, "Block {} has empty content", .{i});
            assert_mod.assert_fmt(block_data.source_uri.len > 0, "Block {} has empty source_uri", .{i});
            assert_mod.assert_fmt(block_data.content.len < 100 * 1024 * 1024, "Block {} content too large: {} bytes", .{ i, block_data.content.len });
        }

        // Convert all blocks to ContextBlock for sorting (zero-cost for ContextBlock arrays)
        const context_blocks = try self.backing_allocator.alloc(ContextBlock, blocks.len);
        defer self.backing_allocator.free(context_blocks);

        for (blocks, 0..) |block_value, index| {
            context_blocks[index] = switch (BlocksType) {
                []const ContextBlock => block_value,
                []ContextBlock => block_value,
                []const ownership.ComptimeOwnedBlockType(.sstable_manager) => block_value.read(.sstable_manager).*,
                []ownership.ComptimeOwnedBlockType(.sstable_manager) => block_value.read(.sstable_manager).*,
                []const OwnedBlock => block_value.read(.sstable_manager).*,
                []OwnedBlock => block_value.read(.sstable_manager).*,
                else => unreachable,
            };
        }

        std.mem.sort(ContextBlock, context_blocks, {}, struct {
            fn less_than(context: void, a: ContextBlock, b: ContextBlock) bool {
                _ = context;
                return std.mem.order(u8, &a.id.bytes, &b.id.bytes) == .lt;
            }
        }.less_than);

        var file = try self.filesystem.create(self.file_path);
        defer file.close();

        var header_buffer: [HEADER_SIZE]u8 = undefined;
        @memset(&header_buffer, 0);
        _ = try file.write(&header_buffer);

        var current_offset: u64 = HEADER_SIZE;

        const bloom_params = if (context_blocks.len < 1000)
            BloomFilter.Params.small
        else if (context_blocks.len < 10000)
            BloomFilter.Params.medium
        else
            BloomFilter.Params.large;

        var new_bloom = try BloomFilter.init(self.arena_coordinator.allocator(), bloom_params);
        for (context_blocks) |block| {
            new_bloom.add(block.id);
        }

        for (context_blocks) |block| {
            const block_size = block.serialized_size();
            const buffer = try self.backing_allocator.alloc(u8, block_size);
            defer self.backing_allocator.free(buffer);

            const written = try block.serialize(buffer);
            assert_mod.assert_equal(written, block_size, "Block serialization size mismatch: {} != {}", .{ written, block_size });

            _ = try file.write(buffer);

            try self.index.append(IndexEntry{
                .block_id = block.id,
                .offset = current_offset,
                // Safety: Block size is bounded by SSTable format limits and fits in u32
                .size = @intCast(block_size),
            });

            current_offset += block_size;
        }

        const index_offset = current_offset;
        for (self.index.items) |entry| {
            var entry_buffer: [IndexEntry.SERIALIZED_SIZE]u8 = undefined;
            try entry.serialize(&entry_buffer);
            _ = try file.write(&entry_buffer);
            current_offset += IndexEntry.SERIALIZED_SIZE;
        }

        const bloom_filter_offset = current_offset;
        const bloom_filter_size = new_bloom.serialized_size();
        const bloom_buffer = try self.backing_allocator.alloc(u8, bloom_filter_size);
        defer self.backing_allocator.free(bloom_buffer);

        try new_bloom.serialize(bloom_buffer);
        _ = try file.write(bloom_buffer);
        current_offset += bloom_filter_size;

        const file_checksum = try self.calculate_file_checksum(&file, current_offset);

        const file_size = try file.file_size();
        const content_size = file_size - FOOTER_SIZE;

        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&content_size));
        const footer_checksum = hasher.final();

        var footer_buffer: [FOOTER_SIZE]u8 = undefined;
        std.mem.writeInt(u64, &footer_buffer, footer_checksum, .little);
        _ = try file.write(&footer_buffer);

        _ = try file.seek(0, .start);
        const header = Header{
            .magic = MAGIC,
            .format_version = VERSION,
            .flags = 0,
            .index_offset = index_offset,
            // Safety: Block count bounded by storage limits, timestamp always fits in u32 range
            .block_count = @intCast(context_blocks.len),
            .file_checksum = file_checksum,
            .created_timestamp = @intCast(std.time.timestamp()),
            .bloom_filter_offset = bloom_filter_offset,
            .bloom_filter_size = bloom_filter_size,
            .reserved = [_]u8{0} ** 20,
        };

        try header.serialize(&header_buffer);
        _ = try file.write(&header_buffer);

        try file.flush();
        // Safety: Block count bounded by storage format limits and fits in u32
        self.block_count = @intCast(context_blocks.len);

        // SUCCESS: All fallible operations completed. Now transfer ownership.

        self.bloom_filter = new_bloom;
    }

    /// Calculate CRC32 checksum over file content (excluding header checksum field and footer)
    fn calculate_file_checksum(self: *SSTable, file: *VFile, content_end_offset: u64) !u32 {
        _ = self;
        var crc = std.hash.Crc32.init();

        _ = try file.seek(HEADER_SIZE, .start);
        const content_size = content_end_offset - HEADER_SIZE;

        var buffer: [4096]u8 = undefined;
        var remaining = content_size;

        while (remaining > 0) {
            const chunk_size = @min(remaining, buffer.len);
            const bytes_read = try file.read(buffer[0..chunk_size]);
            if (bytes_read == 0) break;

            crc.update(buffer[0..bytes_read]);
            remaining -= bytes_read;
        }

        return crc.final();
    }

    /// Read SSTable and load index
    pub fn read_index(self: *SSTable) !void {
        var file = try self.filesystem.open(self.file_path, .read);
        defer file.close();

        self.index.clearRetainingCapacity();

        var header_buffer: [HEADER_SIZE]u8 = undefined;
        _ = try file.read(&header_buffer);

        const header = try Header.deserialize(&header_buffer);
        self.block_count = header.block_count;

        if (header.file_checksum != 0) {
            const content_end = if (header.bloom_filter_size > 0)
                header.bloom_filter_offset + header.bloom_filter_size
            else
                header.index_offset + (header.block_count * IndexEntry.SERIALIZED_SIZE);

            const calculated_checksum = try self.calculate_file_checksum(
                &file,
                content_end,
            );
            if (calculated_checksum != header.file_checksum) {
                return error.ChecksumMismatch;
            }
        }

        // Safety: Index offset is validated during header parsing and fits in seek position
        _ = try file.seek(@intCast(header.index_offset), .start);

        try self.index.ensureTotalCapacity(header.block_count);
        for (0..header.block_count) |_| {
            var entry_buffer: [IndexEntry.SERIALIZED_SIZE]u8 = undefined;
            _ = try file.read(&entry_buffer);

            const entry = try IndexEntry.deserialize(&entry_buffer);
            try self.index.append(entry);
        }

        // Skip per-operation index validation to prevent performance regression
        // Index ordering validation is expensive (iterates through all entries)
        // and should only run during specific tests or startup validation

        if (header.bloom_filter_size > 0) {
            // Safety: Bloom filter offset validated during header parsing
            _ = try file.seek(@intCast(header.bloom_filter_offset), .start);

            const bloom_buffer = try self.backing_allocator.alloc(u8, header.bloom_filter_size);
            defer self.backing_allocator.free(bloom_buffer);

            _ = try file.read(bloom_buffer);

            self.bloom_filter = try BloomFilter.deserialize(self.arena_coordinator.allocator(), bloom_buffer);
        }
    }

    /// Find and return a block by its ID from this SSTable
    ///
    /// Uses the bloom filter for fast negative lookups, then performs binary search
    /// on the index. Returns null if the block is not found in this SSTable.
    pub fn find_block(self: *SSTable, block_id: BlockId) !?ContextBlock {
        // Skip per-operation index validation to prevent read path performance regression
        // Index ordering validation on every find_block call causes significant overhead

        if (self.bloom_filter) |*filter| {
            if (!filter.might_contain(block_id)) {
                return null;
            }
        }

        var left: usize = 0;
        var right: usize = self.index.items.len;
        var entry: ?IndexEntry = null;

        while (left < right) {
            const mid = left + (right - left) / 2;
            const mid_entry = self.index.items[mid];

            const order = std.mem.order(u8, &mid_entry.block_id.bytes, &block_id.bytes);
            switch (order) {
                .lt => left = mid + 1,
                .gt => right = mid,
                .eq => {
                    entry = mid_entry;
                    break;
                },
            }
        }

        const found_entry = entry orelse {
            return null;
        };

        var file = try self.filesystem.open(self.file_path, .read);
        defer file.close();

        // Safety: Entry offset comes from validated SSTable index
        _ = try file.seek(@intCast(found_entry.offset), .start);

        const buffer = try self.arena_coordinator.alloc(u8, found_entry.size);

        _ = try file.read(buffer);

        const block_data = try ContextBlock.deserialize(self.arena_coordinator.allocator(), buffer);
        return block_data;
    }

    /// Find block and return zero-copy view without heap allocations.
    /// Uses ParsedBlock to provide read-only access to block data without memory copies.
    /// Eliminates redundant allocations during read path for performance-critical operations.
    pub fn find_block_view(self: *SSTable, block_id: BlockId) !?ParsedBlock {
        // Skip per-operation index validation to prevent read path performance regression
        // Index ordering validation on every find_block call causes significant overhead

        if (self.bloom_filter) |*filter| {
            if (!filter.might_contain(block_id)) {
                return null;
            }
        }

        var left: usize = 0;
        var right: usize = self.index.items.len;
        var entry: ?IndexEntry = null;

        while (left < right) {
            const mid = left + (right - left) / 2;
            const mid_entry = self.index.items[mid];

            const order = std.mem.order(u8, &mid_entry.block_id.bytes, &block_id.bytes);
            switch (order) {
                .lt => left = mid + 1,
                .gt => right = mid,
                .eq => {
                    entry = mid_entry;
                    break;
                },
            }
        }

        const found_entry = entry orelse {
            return null;
        };

        var file = try self.filesystem.open(self.file_path, .read);
        defer file.close();

        // Safety: Entry offset comes from validated SSTable index
        _ = try file.seek(@intCast(found_entry.offset), .start);

        const buffer = try self.arena_coordinator.alloc(u8, found_entry.size);

        _ = try file.read(buffer);

        return try ParsedBlock.parse(buffer);
    }

    /// Get iterator for all blocks in sorted order
    pub fn iterator(self: *SSTable) SSTableIterator {
        return SSTableIterator.init(self);
    }

    /// Validate that index entries are properly sorted by BlockId.
    /// Critical for binary search correctness in find_block().
    /// Called in debug builds to catch ordering corruption.
    fn validate_index_ordering(self: *const SSTable) void {
        if (self.index.items.len <= 1) return;

        for (self.index.items[0 .. self.index.items.len - 1], self.index.items[1..]) |current, next| {
            const order = std.mem.order(u8, &current.block_id.bytes, &next.block_id.bytes);
            assert_mod.fatal_assert(order == .lt, "SSTable index not properly sorted: {any} >= {any} at positions", .{ current.block_id, next.block_id });
        }
    }
};

/// Iterator for reading all blocks from an SSTable in sorted order
pub const SSTableIterator = struct {
    sstable: *SSTable,
    current_index: usize,
    file: ?vfs.VFile,

    /// Initialize a new iterator for the given SSTable.
    /// The SSTable must have a loaded index with at least one entry.
    pub fn init(sstable: *SSTable) SSTableIterator {
        // Safety: Converting pointer to integer for null pointer validation
        assert_mod.assert_fmt(@intFromPtr(sstable) != 0, "SSTable pointer cannot be null", .{});
        assert_mod.assert_fmt(sstable.index.items.len > 0, "Cannot iterate over SSTable with empty index", .{});

        return SSTableIterator{
            .sstable = sstable,
            .current_index = 0,
            .file = null,
        };
    }

    pub fn deinit(self: *SSTableIterator) void {
        if (self.file) |*file| {
            file.close();
        }
    }

    /// Get next block from iterator, opening file if needed
    pub fn next(self: *SSTableIterator) !?ContextBlock {
        // Safety: Converting pointer to integer for corruption detection
        assert_mod.assert_fmt(@intFromPtr(self.sstable) != 0, "Iterator sstable pointer corrupted", .{});
        assert_mod.assert_index_valid(self.current_index, self.sstable.index.items.len + 1, "Iterator index out of bounds: {} >= {}", .{ self.current_index, self.sstable.index.items.len + 1 });

        if (self.current_index >= self.sstable.index.items.len) {
            return null;
        }

        if (self.file == null) {
            self.file = try self.sstable.filesystem.open(self.sstable.file_path, .read);
        }

        const entry = self.sstable.index.items[self.current_index];
        self.current_index += 1;

        // Safety: Entry offset validated by SSTable index structure
        _ = try self.file.?.seek(@intCast(entry.offset), .start);

        const buffer = try self.sstable.arena_coordinator.alloc(u8, entry.size);

        _ = try self.file.?.read(buffer);

        const block_data = try ContextBlock.deserialize(self.sstable.arena_coordinator.allocator(), buffer);
        return block_data;
    }
};

/// SSTable compaction manager
pub const Compactor = struct {
    /// Arena coordinator pointer for stable allocation access (remains valid across arena resets)
    /// CRITICAL: Must be pointer to prevent coordinator struct copying corruption
    arena_coordinator: *const ArenaCoordinator,
    /// Stable backing allocator for temporary structures
    backing_allocator: std.mem.Allocator,
    filesystem: VFS,
    data_dir: []const u8,

    pub fn init(
        coordinator: *const ArenaCoordinator,
        backing: std.mem.Allocator,
        filesystem: VFS,
        data_dir: []const u8,
    ) Compactor {
        return Compactor{
            .arena_coordinator = coordinator,
            .backing_allocator = backing,
            .filesystem = filesystem,
            .data_dir = data_dir,
        };
    }

    /// Compact multiple SSTables into a single larger SSTable
    pub fn compact_sstables(
        self: *Compactor,
        input_paths: []const []const u8,
        output_path: []const u8,
    ) !void {
        assert_mod.assert(input_paths.len > 1);

        var input_tables = try self.backing_allocator.alloc(*SSTable, input_paths.len);
        var tables_initialized: usize = 0;
        defer {
            // Only clean up successfully initialized tables
            for (input_tables[0..tables_initialized]) |table| {
                table.deinit();
                self.backing_allocator.destroy(table);
            }
            self.backing_allocator.free(input_tables);
        }

        for (input_paths, 0..) |path, i| {
            const path_copy = try self.backing_allocator.dupe(u8, path);

            const table = try self.backing_allocator.create(SSTable);
            table.* = SSTable.init(self.arena_coordinator, self.backing_allocator, self.filesystem, path_copy);

            // If read_index fails, clean up this table and return error
            table.read_index() catch |err| {
                table.deinit(); // This will free path_copy
                self.backing_allocator.destroy(table);
                return err;
            };

            input_tables[i] = table;
            tables_initialized += 1;
        }

        const output_path_copy = try self.backing_allocator.dupe(u8, output_path);
        var output_table = SSTable.init(self.arena_coordinator, self.backing_allocator, self.filesystem, output_path_copy);
        defer output_table.deinit();

        var all_blocks = std.array_list.Managed(ContextBlock).init(self.backing_allocator);
        defer all_blocks.deinit();

        var total_capacity: u32 = 0;
        for (input_tables) |table| {
            total_capacity += table.block_count;
        }
        try all_blocks.ensureTotalCapacity(total_capacity);

        for (input_tables) |table| {
            var iter = table.iterator();
            defer iter.deinit();

            while (try iter.next()) |block| {
                try all_blocks.append(block);
            }
        }

        const unique_blocks = try self.dedup_blocks(all_blocks.items);

        defer self.backing_allocator.free(unique_blocks);
        // Arena coordinator handles cleanup of cloned block strings automatically

        try output_table.write_blocks(unique_blocks);

        for (input_paths) |path| {
            self.filesystem.remove(path) catch |err| {
                log.warn("Failed to remove input SSTable {s}: {any}", .{ path, err });
            };
        }
    }

    /// Remove duplicate blocks, keeping the one with highest version
    fn dedup_blocks(self: *Compactor, blocks: []ContextBlock) ![]ContextBlock {
        // Safety: Converting pointer to integer for null pointer validation
        assert_mod.assert_fmt(@intFromPtr(blocks.ptr) != 0 or blocks.len == 0, "Blocks array has null pointer with non-zero length", .{});

        if (blocks.len == 0) return try self.backing_allocator.alloc(ContextBlock, 0);

        const sorted = try self.backing_allocator.dupe(ContextBlock, blocks);
        std.mem.sort(ContextBlock, sorted, {}, struct {
            fn less_than(context: void, a: ContextBlock, b: ContextBlock) bool {
                _ = context;
                const a_data = a;
                const b_data = b;
                const order = std.mem.order(u8, &a_data.id.bytes, &b_data.id.bytes);
                if (order == .eq) {
                    return a_data.version > b_data.version;
                }
                return order == .lt;
            }
        }.less_than);

        var unique = std.array_list.Managed(ContextBlock).init(self.backing_allocator);
        defer unique.deinit();

        try unique.ensureTotalCapacity(sorted.len);

        var prev_id: ?BlockId = null;
        for (sorted) |block| {
            const block_data = block;
            if (prev_id == null or !block_data.id.eql(prev_id.?)) {
                const cloned = ContextBlock{
                    .id = block_data.id,
                    .version = block_data.version,
                    .source_uri = try self.arena_coordinator.allocator().dupe(u8, block_data.source_uri),
                    .metadata_json = try self.arena_coordinator.allocator().dupe(u8, block_data.metadata_json),
                    .content = try self.arena_coordinator.allocator().dupe(u8, block_data.content),
                };
                try unique.append(cloned);
                prev_id = block_data.id;
            }
        }

        self.backing_allocator.free(sorted);
        return try unique.toOwnedSlice();
    }
};
