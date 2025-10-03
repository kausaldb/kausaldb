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

const bloom_filter = @import("bloom_filter.zig");
const config_mod = @import("config.zig");
const context_block = @import("../core/types.zig");
const error_context = @import("../core/error_context.zig");
const memory = @import("../core/memory.zig");
const ownership = @import("../core/ownership.zig");
const tombstone = @import("tombstone.zig");
const vfs = @import("../core/vfs.zig");

// Import BlockIdContext for HashMap
const block_index_mod = @import("block_index.zig");
const BlockIdContext = block_index_mod.BlockIndex.BlockIdContext;

const log = std.log.scoped(.sstable);
const testing = std.testing;

const ArenaCoordinator = memory.ArenaCoordinator;
const BlockId = context_block.BlockId;
const BloomFilter = bloom_filter.BloomFilter;
const ContextBlock = context_block.ContextBlock;
const EdgeType = context_block.EdgeType;
const GraphEdge = context_block.GraphEdge;
const OwnedBlock = ownership.OwnedBlock;
const ParsedBlock = context_block.ParsedBlock;

const TombstoneRecord = tombstone.TombstoneRecord;
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
    index: std.ArrayList(IndexEntry),
    tombstone_count: u32,
    tombstone_index: std.ArrayList(TombstoneRecord),
    edge_count: u32,
    edge_index: std.ArrayList(EdgeIndexEntry),
    bloom_filter: ?BloomFilter,

    const MAGIC = [4]u8{ 'S', 'S', 'T', 'B' }; // "SSTB" for SSTable Blocks
    const VERSION = 1;
    const HEADER_SIZE = 64; // Cache-aligned header size for performance
    const FOOTER_SIZE = 8; // Checksum

    /// Index entry pointing to a block within the SSTable
    pub const IndexEntry = struct {
        block_id: BlockId,
        offset: u64,
        size: u32,

        const SERIALIZED_SIZE = 16 + 8 + 4; // BlockId + offset + size

        /// Serialize index entry to binary format for on-disk storage
        ///
        /// Writes the block ID, offset, and size to the buffer in little-endian format.
        /// Buffer must have at least SERIALIZED_SIZE bytes available.
        pub fn serialize(self: IndexEntry, buffer: []u8) !void {
            std.debug.assert(buffer.len >= SERIALIZED_SIZE);

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
            std.debug.assert(buffer.len >= SERIALIZED_SIZE);
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

    /// Edge index entry pointing to an edge within the SSTable
    const EdgeIndexEntry = struct {
        source_id: BlockId,
        target_id: BlockId,
        edge_type: EdgeType,
        offset: u16,

        const SERIALIZED_SIZE = 16 + 16 + 2 + 2; // source_id + target_id + edge_type + offset

        /// Serialize edge index entry to binary format for on-disk storage
        pub fn serialize(self: EdgeIndexEntry, buffer: []u8) !void {
            std.debug.assert(buffer.len >= SERIALIZED_SIZE);

            var offset: usize = 0;

            @memcpy(buffer[offset .. offset + 16], &self.source_id.bytes);
            offset += 16;

            @memcpy(buffer[offset .. offset + 16], &self.target_id.bytes);
            offset += 16;

            std.mem.writeInt(u16, buffer[offset..][0..2], @intFromEnum(self.edge_type), .little);
            offset += 2;

            std.mem.writeInt(u16, buffer[offset..][0..2], self.offset, .little);
        }

        /// Deserialize edge index entry from binary format stored on disk
        pub fn deserialize(buffer: []const u8) !EdgeIndexEntry {
            std.debug.assert(buffer.len >= SERIALIZED_SIZE);
            if (buffer.len < SERIALIZED_SIZE) return error.BufferTooSmall;

            var offset: usize = 0;

            var source_bytes: [16]u8 = undefined;
            @memcpy(&source_bytes, buffer[offset .. offset + 16]);
            const source_id = BlockId.from_bytes(source_bytes);
            offset += 16;

            var target_bytes: [16]u8 = undefined;
            @memcpy(&target_bytes, buffer[offset .. offset + 16]);
            const target_id = BlockId.from_bytes(target_bytes);
            offset += 16;

            const edge_type_raw = std.mem.readInt(u16, buffer[offset..][0..2], .little);

            if (edge_type_raw < 1 or edge_type_raw > 10) {
                log.warn("Corrupted edge data: invalid EdgeType value {} (valid range: 1-10)", .{edge_type_raw});
                return error.ChecksumMismatch;
            }

            const edge_type: EdgeType = @enumFromInt(edge_type_raw);
            offset += 2;

            const edge_offset = std.mem.readInt(u16, buffer[offset..][0..2], .little);

            return EdgeIndexEntry{
                .source_id = source_id,
                .target_id = target_id,
                .edge_type = edge_type,
                .offset = edge_offset,
            };
        }
    };

    /// File header structure (64-byte aligned)
    const Header = extern struct {
        magic: [4]u8, // 4 bytes: "SSTB"
        format_version: u16, // 2 bytes: Major.minor versioning
        flags: u16, // 2 bytes: Feature flags
        index_offset: u64, // 8 bytes: Offset to index section
        created_timestamp: u64, // 8 bytes: Unix timestamp
        bloom_filter_offset: u64, // 8 bytes: Offset to bloom filter
        tombstone_offset: u64, // 8 bytes: Offset to tombstone section
        edge_offset: u64, // 8 bytes: Offset to edge section
        block_count: u32, // 4 bytes: Number of blocks
        file_checksum: u32, // 4 bytes: CRC32 of entire file
        bloom_filter_size: u32, // 4 bytes: Size of serialized bloom filter
        tombstone_count: u16, // 2 bytes: Number of tombstones (max 65K per SSTable)
        edge_count: u16, // 2 bytes: Number of edges (max 65K per SSTable)

        comptime {
            if (!(@sizeOf(Header) == 64)) @compileError("SSTable Header must be exactly 64 bytes for cache-aligned performance");
            if (!(HEADER_SIZE == @sizeOf(Header))) @compileError("HEADER_SIZE constant must match actual Header struct size");
            if (!(4 + @sizeOf(u16) + @sizeOf(u16) + @sizeOf(u64) + @sizeOf(u64) +
                @sizeOf(u64) + @sizeOf(u64) + @sizeOf(u64) + @sizeOf(u32) + @sizeOf(u32) +
                @sizeOf(u32) + @sizeOf(u16) + @sizeOf(u16) == 64)) @compileError(
                "SSTable Header field sizes must sum to exactly 64 bytes",
            );
        }

        /// Serialize SSTable header to binary format for on-disk storage
        ///
        /// Writes all header fields including magic number, version, counts, and offsets
        /// to the buffer in little-endian format. Essential for SSTable file format integrity.
        pub fn serialize(self: Header, buffer: []u8) !void {
            std.debug.assert(buffer.len >= HEADER_SIZE);

            var offset: usize = 0;

            @memcpy(buffer[offset .. offset + 4], &self.magic);
            offset += 4;

            std.mem.writeInt(u16, buffer[offset..][0..2], self.format_version, .little);
            offset += 2;

            std.mem.writeInt(u16, buffer[offset..][0..2], self.flags, .little);
            offset += 2;

            std.mem.writeInt(u64, buffer[offset..][0..8], self.index_offset, .little);
            offset += 8;

            std.mem.writeInt(u64, buffer[offset..][0..8], self.created_timestamp, .little);
            offset += 8;

            std.mem.writeInt(u64, buffer[offset..][0..8], self.bloom_filter_offset, .little);
            offset += 8;

            std.mem.writeInt(u64, buffer[offset..][0..8], self.tombstone_offset, .little);
            offset += 8;

            std.mem.writeInt(u64, buffer[offset..][0..8], self.edge_offset, .little);
            offset += 8;

            std.mem.writeInt(u32, buffer[offset..][0..4], self.block_count, .little);
            offset += 4;

            std.mem.writeInt(u32, buffer[offset..][0..4], self.file_checksum, .little);
            offset += 4;

            std.mem.writeInt(u32, buffer[offset..][0..4], self.bloom_filter_size, .little);
            offset += 4;

            std.mem.writeInt(u16, buffer[offset..][0..2], self.tombstone_count, .little);
            offset += 2;

            std.mem.writeInt(u16, buffer[offset..][0..2], self.edge_count, .little);
        }

        /// Deserialize SSTable header from binary format during file loading
        ///
        /// Reads and validates the complete header structure from storage buffer.
        /// Critical for ensuring data integrity when opening existing SSTables.
        pub fn deserialize(buffer: []const u8) !Header {
            std.debug.assert(buffer.len >= HEADER_SIZE);
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

            const created_timestamp = std.mem.readInt(u64, buffer[offset..][0..8], .little);
            offset += 8;

            const bloom_filter_offset = std.mem.readInt(u64, buffer[offset..][0..8], .little);
            offset += 8;

            const tombstone_offset = std.mem.readInt(u64, buffer[offset..][0..8], .little);
            offset += 8;

            const edge_offset = std.mem.readInt(u64, buffer[offset..][0..8], .little);
            offset += 8;

            const block_count = std.mem.readInt(u32, buffer[offset..][0..4], .little);
            offset += 4;

            const file_checksum = std.mem.readInt(u32, buffer[offset..][0..4], .little);
            offset += 4;

            const bloom_filter_size = std.mem.readInt(u32, buffer[offset..][0..4], .little);
            offset += 4;

            const tombstone_count = std.mem.readInt(u16, buffer[offset..][0..2], .little);
            offset += 2;

            const edge_count = std.mem.readInt(u16, buffer[offset..][0..2], .little);

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
                .tombstone_count = tombstone_count,
                .tombstone_offset = tombstone_offset,
                .edge_count = edge_count,
                .edge_offset = edge_offset,
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
        std.debug.assert(file_path.len > 0);
        std.debug.assert(file_path.len < 4096);
        // Safety: Converting pointer to integer for null pointer validation
        std.debug.assert(@intFromPtr(file_path.ptr) != 0);

        return SSTable{
            .arena_coordinator = coordinator,
            .backing_allocator = backing,
            .filesystem = filesystem,
            .file_path = file_path,
            .block_count = 0,
            .index = std.ArrayList(IndexEntry){},
            .tombstone_count = 0,
            .tombstone_index = std.ArrayList(TombstoneRecord){},
            .edge_count = 0,
            .edge_index = std.ArrayList(EdgeIndexEntry){},
            .bloom_filter = null,
        };
    }

    /// Clean up all allocated resources including the file path and index.
    /// Safe to call multiple times - subsequent calls are no-ops.
    pub fn deinit(self: *SSTable) void {
        self.index.deinit(self.backing_allocator);
        self.tombstone_index.deinit(self.backing_allocator);
        self.edge_index.deinit(self.backing_allocator);
    }

    /// Write blocks, tombstones, and edges to SSTable file in sorted order
    pub fn write_blocks(self: *SSTable, blocks: anytype, tombstones: []const TombstoneRecord, edges: []const GraphEdge) !void {
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
            @compileError(
                "write_blocks() called with unsupported type '" ++ @typeName(BlocksType) ++
                    "'. Accepts []const ContextBlock, []ContextBlock, []const OwnedBlock, or []OwnedBlock only",
            );
        }
        // Handle empty case - create empty SSTable with just tombstones if needed
        if (blocks.len == 0 and tombstones.len == 0) return;
        std.debug.assert(blocks.len <= 1000000);

        self.index.clearAndFree(self.backing_allocator);
        // Safety: Converting pointer to integer for null pointer validation
        std.debug.assert(@intFromPtr(blocks.ptr) != 0);

        for (blocks) |block_value| {
            const block_data = switch (BlocksType) {
                []const ContextBlock => block_value,
                []ContextBlock => block_value,
                []const ownership.ComptimeOwnedBlockType(.sstable_manager) => block_value.read(.sstable_manager),
                []ownership.ComptimeOwnedBlockType(.sstable_manager) => block_value.read(.sstable_manager),
                []const OwnedBlock => block_value.read(.sstable_manager),
                []OwnedBlock => block_value.read(.sstable_manager),
                else => unreachable,
            };

            std.debug.assert(block_data.content.len > 0);
            std.debug.assert(block_data.source_uri.len > 0);
            std.debug.assert(block_data.content.len < 100 * 1024 * 1024);
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

        // Copy tombstones and sort them
        const sorted_tombstones = try self.arena_coordinator.allocator().alloc(TombstoneRecord, tombstones.len);
        defer self.arena_coordinator.allocator().free(sorted_tombstones);
        @memcpy(sorted_tombstones, tombstones);

        std.mem.sort(TombstoneRecord, sorted_tombstones, {}, TombstoneRecord.less_than);

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

            const written = try (&block).serialize(buffer);
            std.debug.assert(written == block_size);

            _ = try file.write(buffer);

            try self.index.append(self.backing_allocator, IndexEntry{
                .block_id = block.id,
                .offset = current_offset,
                // Safety: Block size is bounded by SSTable format limits and fits in u32
                .size = @intCast(block_size),
            });

            current_offset += block_size;
        }

        // Store tombstone offset before writing tombstones
        const tombstone_offset = current_offset;

        // Write tombstones
        for (sorted_tombstones) |tombstone_record| {
            var tombstone_buffer: [tombstone.TOMBSTONE_SIZE]u8 = undefined;
            _ = try tombstone_record.serialize(&tombstone_buffer);
            _ = try file.write(&tombstone_buffer);
            current_offset += tombstone.TOMBSTONE_SIZE;

            try self.tombstone_index.append(self.backing_allocator, tombstone_record);
        }

        // Copy edges and sort them for deterministic storage order
        const sorted_edges = try self.arena_coordinator.allocator().alloc(GraphEdge, edges.len);
        defer self.arena_coordinator.allocator().free(sorted_edges);
        @memcpy(sorted_edges, edges);

        std.mem.sort(GraphEdge, sorted_edges, {}, GraphEdge.less_than);

        // Store edge offset before writing edges
        const edge_offset = current_offset;

        // Write edges
        for (sorted_edges) |edge| {
            var edge_buffer: [EdgeIndexEntry.SERIALIZED_SIZE]u8 = undefined;
            const edge_entry = EdgeIndexEntry{
                .source_id = edge.source_id,
                .target_id = edge.target_id,
                .edge_type = edge.edge_type,
                .offset = 0, // Offset within edge section (relative to edge_offset)
            };
            try edge_entry.serialize(&edge_buffer);
            _ = try file.write(&edge_buffer);
            current_offset += EdgeIndexEntry.SERIALIZED_SIZE;

            try self.edge_index.append(self.backing_allocator, edge_entry);
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

        // Verify that current_offset matches what read_index will calculate
        const expected_offset = bloom_filter_offset + bloom_filter_size;
        if (current_offset != expected_offset) {
            @panic("Checksum offset mismatch in write");
        }

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
            .created_timestamp = @intCast(std.time.timestamp()),
            .bloom_filter_offset = bloom_filter_offset,
            .tombstone_offset = if (sorted_tombstones.len > 0) tombstone_offset else 0,
            .edge_offset = if (sorted_edges.len > 0) edge_offset else 0,
            .block_count = @intCast(context_blocks.len),
            .file_checksum = file_checksum,
            .bloom_filter_size = bloom_filter_size,
            .tombstone_count = @intCast(sorted_tombstones.len),
            .edge_count = @intCast(sorted_edges.len),
        };

        try header.serialize(&header_buffer);
        _ = try file.write(&header_buffer);

        try file.flush();

        // Safety: Block count bounded by storage format limits and fits in u32
        self.block_count = @intCast(context_blocks.len);
        self.tombstone_count = @intCast(sorted_tombstones.len);
        self.edge_count = @intCast(sorted_edges.len);

        // Transfer ownership
        self.bloom_filter = new_bloom;
    }

    /// Load tombstones from SSTable file into memory index
    pub fn load_tombstones(self: *SSTable) !void {
        if (self.tombstone_count == 0) return; // No tombstones to load

        var file = try self.filesystem.open(self.file_path);
        defer file.close();

        // Read header to get tombstone offset
        var header_buffer: [HEADER_SIZE]u8 = undefined;
        const bytes_read = try file.read(&header_buffer);
        if (bytes_read != HEADER_SIZE) return error.CorruptedEntry;

        const header = try Header.deserialize(&header_buffer);
        if (header.tombstone_count == 0) return;

        // Seek to tombstone section
        _ = try file.seek(header.tombstone_offset, .start);

        // Read all tombstones
        for (0..header.tombstone_count) |_| {
            var tombstone_buffer: [tombstone.TOMBSTONE_SIZE]u8 = undefined;
            const tombstone_bytes_read = try file.read(&tombstone_buffer);
            if (tombstone_bytes_read != tombstone.TOMBSTONE_SIZE) {
                return error.CorruptedEntry;
            }

            const tombstone_record = try TombstoneRecord.deserialize(&tombstone_buffer);
            try self.tombstone_index.append(self.backing_allocator, tombstone_record);
        }

        self.tombstone_count = header.tombstone_count;
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
        self.tombstone_count = header.tombstone_count;
        self.edge_count = header.edge_count;

        if (header.file_checksum != 0) {
            // Always calculate checksum to end of bloom filter since we always write one
            const content_end = header.bloom_filter_offset + header.bloom_filter_size;

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

        try self.index.ensureTotalCapacity(self.backing_allocator, header.block_count);
        for (0..header.block_count) |_| {
            var entry_buffer: [IndexEntry.SERIALIZED_SIZE]u8 = undefined;
            _ = try file.read(&entry_buffer);

            const entry = try IndexEntry.deserialize(&entry_buffer);
            try self.index.append(self.backing_allocator, entry);
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

        // Load tombstones if present
        if (header.tombstone_count > 0) {
            // Safety: Tombstone offset validated during header parsing
            _ = try file.seek(@intCast(header.tombstone_offset), .start);

            self.tombstone_index.clearRetainingCapacity();
            try self.tombstone_index.ensureTotalCapacity(self.backing_allocator, header.tombstone_count);

            for (0..header.tombstone_count) |_| {
                var tombstone_buffer: [tombstone.TOMBSTONE_SIZE]u8 = undefined;
                _ = try file.read(&tombstone_buffer);

                const tombstone_record = try TombstoneRecord.deserialize(&tombstone_buffer);
                try self.tombstone_index.append(self.backing_allocator, tombstone_record);
            }
        }

        // Load edges if present
        if (header.edge_count > 0) {
            // Safety: Edge offset validated during header parsing
            _ = try file.seek(header.edge_offset, .start);

            self.edge_index.clearRetainingCapacity();
            try self.edge_index.ensureTotalCapacity(self.backing_allocator, header.edge_count);

            for (0..header.edge_count) |_| {
                var edge_buffer: [EdgeIndexEntry.SERIALIZED_SIZE]u8 = undefined;
                _ = try file.read(&edge_buffer);

                const edge_entry = try EdgeIndexEntry.deserialize(&edge_buffer);
                try self.edge_index.append(self.backing_allocator, edge_entry);
            }
        }
    }

    /// Find and return a block by its ID from this SSTable
    ///
    /// Uses the bloom filter for fast negative lookups, then performs binary search
    /// on the index. Returns null if the block is not found in this SSTable.
    pub fn find_block(self: *SSTable, block_id: BlockId) !?ContextBlock {
        // Check tombstones first - tombstoned blocks should not be returned
        // However, we need to compare sequences to handle MVCC correctly:
        // Only tombstones with higher sequences than the block should hide it
        var tombstone_sequence: ?u64 = null;
        for (self.tombstone_index.items) |tombstone_record| {
            if (tombstone_record.block_id.eql(block_id)) {
                tombstone_sequence = tombstone_record.sequence;
                break;
            }
        }

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

        if (tombstone_sequence) |tomb_seq| {
            if (tomb_seq > block_data.sequence) {
                return null; // Tombstone hides this block version
            }
        }

        return block_data;
    }

    /// Find block and return zero-copy view without heap allocations.
    /// Uses ParsedBlock to provide read-only access to block data without memory copies.
    /// Eliminates redundant allocations during read path for performance-critical operations.
    pub fn find_block_view(self: *SSTable, block_id: BlockId) !?ParsedBlock {
        // Skip per-operation index validation to prevent read path performance regression
        // Index ordering validation on every find_block call causes significant overhead

        // Check tombstones first - tombstoned blocks should not be returned
        // However, we need to compare sequences to handle MVCC correctly:
        // Only tombstones with higher sequences than the block should hide it
        var tombstone_sequence: ?u64 = null;
        for (self.tombstone_index.items) |tombstone_record| {
            if (tombstone_record.block_id.eql(block_id)) {
                tombstone_sequence = tombstone_record.sequence;
                break;
            }
        }

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

        const parsed_block = try ParsedBlock.parse(buffer);

        // Apply MVCC tombstone filtering after parsing block to access sequence
        if (tombstone_sequence) |tomb_seq| {
            if (tomb_seq > parsed_block.sequence()) {
                return null; // Tombstone hides this block version
            }
        }

        return parsed_block;
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
            if (!(order == .lt)) std.debug.panic(
                "SSTable index not properly sorted: {any} >= {any} at positions",
                .{ current.block_id, next.block_id },
            );
        }
    }

    /// Find all outgoing edges from a source block in this SSTable.
    /// Returns edges as GraphEdge array that must be freed by caller.
    pub fn find_outgoing_edges(self: *const SSTable, source_id: BlockId, allocator: std.mem.Allocator) ![]GraphEdge {
        var edges = std.ArrayList(GraphEdge){};
        defer edges.deinit(allocator);

        for (self.edge_index.items) |edge_entry| {
            if (edge_entry.source_id.eql(source_id)) {
                const edge = GraphEdge{
                    .source_id = edge_entry.source_id,
                    .target_id = edge_entry.target_id,
                    .edge_type = edge_entry.edge_type,
                };
                try edges.append(allocator, edge);
            }
        }

        return edges.toOwnedSlice(allocator);
    }

    /// Find all incoming edges to a target block in this SSTable.
    /// Returns edges as GraphEdge array that must be freed by caller.
    pub fn find_incoming_edges(self: *const SSTable, target_id: BlockId, allocator: std.mem.Allocator) ![]GraphEdge {
        var edges = std.ArrayList(GraphEdge){};
        defer edges.deinit(allocator);

        for (self.edge_index.items) |edge_entry| {
            if (edge_entry.target_id.eql(target_id)) {
                const edge = GraphEdge{
                    .source_id = edge_entry.source_id,
                    .target_id = edge_entry.target_id,
                    .edge_type = edge_entry.edge_type,
                };
                try edges.append(allocator, edge);
            }
        }

        return edges.toOwnedSlice(allocator);
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
        std.debug.assert(@intFromPtr(sstable) != 0);
        std.debug.assert(sstable.index.items.len > 0);

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
        std.debug.assert(@intFromPtr(self.sstable) != 0);
        std.debug.assert(self.current_index <= self.sstable.index.items.len);

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
        std.debug.assert(input_paths.len > 1);

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
            const path_copy = try self.arena_coordinator.allocator().dupe(u8, path);

            const table = try self.backing_allocator.create(SSTable);
            table.* = SSTable.init(self.arena_coordinator, self.arena_coordinator.allocator(), self.filesystem, path_copy);

            // If read_index fails, clean up this table and return error
            table.read_index() catch |err| {
                table.deinit(); // This will free path_copy
                self.backing_allocator.destroy(table);
                return err;
            };

            input_tables[i] = table;
            tables_initialized += 1;
        }

        const output_path_copy = try self.arena_coordinator.allocator().dupe(u8, output_path);
        var output_table = SSTable.init(self.arena_coordinator, self.arena_coordinator.allocator(), self.filesystem, output_path_copy);
        defer output_table.deinit();

        var blocks_capacity: u32 = 0;
        var tombstones_capacity: usize = 0;
        var edges_capacity: usize = 0;
        for (input_tables) |table| {
            blocks_capacity += table.block_count;
            tombstones_capacity += table.tombstone_index.items.len;
            edges_capacity += table.edge_index.items.len;
        }

        var all_blocks = try std.ArrayList(ContextBlock).initCapacity(self.backing_allocator, blocks_capacity);
        defer all_blocks.deinit(self.backing_allocator);

        var all_tombstones = try std.ArrayList(TombstoneRecord).initCapacity(self.backing_allocator, tombstones_capacity);
        defer all_tombstones.deinit(self.backing_allocator);

        var all_edges = try std.ArrayList(GraphEdge).initCapacity(self.backing_allocator, edges_capacity);
        defer all_edges.deinit(self.backing_allocator);

        for (input_tables) |table| {
            // Skip empty SSTables to avoid iterator assertion failure
            // Empty SSTables can exist due to test artifacts or edge cases
            if (table.index.items.len == 0) continue;

            var iter = table.iterator();
            defer iter.deinit();

            while (try iter.next()) |block| {
                try all_blocks.append(self.backing_allocator, block);
            }

            // Collect tombstones from this table
            for (table.tombstone_index.items) |tombstone_record| {
                try all_tombstones.append(self.backing_allocator, tombstone_record);
            }

            // Collect edges from this table
            for (table.edge_index.items) |edge_entry| {
                const edge = GraphEdge{
                    .source_id = edge_entry.source_id,
                    .target_id = edge_entry.target_id,
                    .edge_type = edge_entry.edge_type,
                };
                try all_edges.append(self.backing_allocator, edge);
            }
        }

        // Apply MVCC filtering between blocks and tombstones
        var mvcc_filtered = try self.apply_mvcc_filtering(all_blocks.items, all_tombstones.items);
        defer mvcc_filtered.blocks.deinit(self.backing_allocator);
        defer mvcc_filtered.tombstones.deinit(self.backing_allocator);

        const unique_blocks = try self.dedup_blocks(mvcc_filtered.blocks.items);
        const unique_tombstones = try self.dedup_and_gc_tombstones(mvcc_filtered.tombstones.items);
        const filtered_edges = try self.filter_edges_by_blocks(all_edges.items, unique_blocks);
        const unique_edges = try self.dedup_edges(filtered_edges);
        defer self.backing_allocator.free(filtered_edges);

        defer self.backing_allocator.free(unique_blocks);
        defer self.backing_allocator.free(unique_tombstones);
        defer self.backing_allocator.free(unique_edges);
        // Arena coordinator handles cleanup of cloned block strings automatically

        try output_table.write_blocks(unique_blocks, unique_tombstones, unique_edges);

        for (input_paths) |path| {
            self.filesystem.remove(path) catch |err| {
                log.warn("Failed to remove input SSTable {s}: {any}", .{ path, err });
            };
        }
    }

    /// Remove duplicate blocks, keeping the one with highest sequence
    fn dedup_blocks(self: *Compactor, blocks: []ContextBlock) ![]ContextBlock {
        // Safety: Converting pointer to integer for null pointer validation
        std.debug.assert(@intFromPtr(blocks.ptr) != 0 or blocks.len == 0);
        if (blocks.len == 0) return try self.backing_allocator.alloc(ContextBlock, 0);

        const sorted = try self.backing_allocator.dupe(ContextBlock, blocks);
        std.mem.sort(ContextBlock, sorted, {}, struct {
            fn less_than(context: void, a: ContextBlock, b: ContextBlock) bool {
                _ = context;
                const a_data = a;
                const b_data = b;
                const order = std.mem.order(u8, &a_data.id.bytes, &b_data.id.bytes);
                if (order == .eq) {
                    return a_data.sequence > b_data.sequence;
                }
                return order == .lt;
            }
        }.less_than);

        var unique = try std.ArrayList(ContextBlock).initCapacity(self.backing_allocator, sorted.len);
        defer unique.deinit(self.backing_allocator);

        var prev_id: ?BlockId = null;
        for (sorted) |block| {
            const block_data = block;
            if (prev_id == null or !block_data.id.eql(prev_id.?)) {
                const cloned = ContextBlock{
                    .id = block_data.id,
                    .sequence = block_data.sequence,
                    .source_uri = try self.arena_coordinator.allocator().dupe(u8, block_data.source_uri),
                    .metadata_json = try self.arena_coordinator.allocator().dupe(u8, block_data.metadata_json),
                    .content = try self.arena_coordinator.allocator().dupe(u8, block_data.content),
                };
                try unique.append(self.backing_allocator, cloned);
                prev_id = block_data.id;
            }
        }

        self.backing_allocator.free(sorted);
        return unique.toOwnedSlice(self.backing_allocator);
    }

    /// Remove duplicate tombstones, keeping the one with highest deletion sequence,
    /// and garbage collect old tombstones based on age
    fn dedup_and_gc_tombstones(self: *Compactor, tombstones: []TombstoneRecord) ![]TombstoneRecord {
        if (tombstones.len == 0) return try self.backing_allocator.alloc(TombstoneRecord, 0);

        const sorted = try self.backing_allocator.dupe(TombstoneRecord, tombstones);
        std.mem.sort(TombstoneRecord, sorted, {}, struct {
            fn less_than(context: void, a: TombstoneRecord, b: TombstoneRecord) bool {
                _ = context;
                const order = std.mem.order(u8, &a.block_id.bytes, &b.block_id.bytes);
                if (order == .eq) {
                    return a.sequence > b.sequence;
                }
                return order == .lt;
            }
        }.less_than);

        var unique = try std.ArrayList(TombstoneRecord).initCapacity(self.backing_allocator, sorted.len);
        defer unique.deinit(self.backing_allocator);

        // Get current timestamp for garbage collection
        const current_timestamp = @as(u64, @intCast(std.time.microTimestamp()));
        const gc_grace_seconds = config_mod.DEFAULT_TOMBSTONE_GC_GRACE_SECONDS;

        var prev_id: ?BlockId = null;
        for (sorted) |tombstone_record| {
            // Skip duplicates (keep only highest sequence per block_id)
            if (prev_id != null and tombstone_record.block_id.eql(prev_id.?)) {
                continue;
            }

            // Skip tombstones that can be garbage collected
            if (tombstone_record.can_garbage_collect(current_timestamp, gc_grace_seconds)) {
                continue;
            }

            try unique.append(self.backing_allocator, tombstone_record);
            prev_id = tombstone_record.block_id;
        }

        self.backing_allocator.free(sorted);
        return unique.toOwnedSlice(self.backing_allocator);
    }

    /// MVCC filtering result for compaction
    const MVCCFilterResult = struct {
        blocks: std.ArrayList(ContextBlock),
        tombstones: std.ArrayList(TombstoneRecord),
    };

    /// Apply MVCC semantics during compaction: for each block ID, keep either
    /// the live blocks OR the tombstones based on highest sequence number
    fn apply_mvcc_filtering(self: *Compactor, blocks: []ContextBlock, tombstones: []TombstoneRecord) !MVCCFilterResult {
        // Build a map of highest sequence for each block ID
        var highest_sequences = std.HashMap(BlockId, struct { sequence: u64, is_tombstone: bool }, BlockIdContext, std.hash_map.default_max_load_percentage).init(self.backing_allocator);
        defer highest_sequences.deinit();

        // Check all blocks
        for (blocks) |block| {
            const existing = highest_sequences.get(block.id);
            if (existing == null or block.sequence > existing.?.sequence) {
                try highest_sequences.put(block.id, .{ .sequence = block.sequence, .is_tombstone = false });
            }
        }

        // Check all tombstones
        for (tombstones) |tombstone_record| {
            const existing = highest_sequences.get(tombstone_record.block_id);
            if (existing == null or tombstone_record.sequence > existing.?.sequence) {
                try highest_sequences.put(tombstone_record.block_id, .{ .sequence = tombstone_record.sequence, .is_tombstone = true });
            }
        }

        // Filter blocks and tombstones based on MVCC winners
        var filtered_blocks = try std.ArrayList(ContextBlock).initCapacity(self.backing_allocator, blocks.len);
        var filtered_tombstones = try std.ArrayList(TombstoneRecord).initCapacity(self.backing_allocator, tombstones.len);

        for (blocks) |block| {
            const winner = highest_sequences.get(block.id).?;
            // Keep block only if THIS specific block is the winner
            if (!winner.is_tombstone and block.sequence == winner.sequence) {
                try filtered_blocks.append(self.backing_allocator, block);
            }
        }

        for (tombstones) |tombstone_record| {
            const winner = highest_sequences.get(tombstone_record.block_id).?;
            // Keep tombstone only if THIS specific tombstone is the winner
            if (winner.is_tombstone and tombstone_record.sequence == winner.sequence) {
                try filtered_tombstones.append(self.backing_allocator, tombstone_record);
            }
        }

        return MVCCFilterResult{
            .blocks = filtered_blocks,
            .tombstones = filtered_tombstones,
        };
    }

    /// Filter edges to only include those where both endpoints exist in the given blocks
    fn filter_edges_by_blocks(self: *Compactor, edges: []GraphEdge, blocks: []ContextBlock) ![]GraphEdge {
        // Build a set of available block IDs
        var block_ids = std.HashMap(BlockId, void, BlockIdContext, std.hash_map.default_max_load_percentage).init(self.backing_allocator);
        defer block_ids.deinit();

        for (blocks) |block| {
            try block_ids.put(block.id, {});
        }

        var filtered_edges = try std.ArrayList(GraphEdge).initCapacity(self.backing_allocator, edges.len);
        defer filtered_edges.deinit(self.backing_allocator);

        var kept_count: usize = 0;
        var filtered_count: usize = 0;

        for (edges) |edge| {
            // Only keep edges where both source and target blocks exist
            if (block_ids.contains(edge.source_id) and block_ids.contains(edge.target_id)) {
                try filtered_edges.append(self.backing_allocator, edge);
                kept_count += 1;
            } else {
                filtered_count += 1;
            }
        }

        return filtered_edges.toOwnedSlice(self.backing_allocator);
    }

    /// Deduplicate edges during compaction.
    /// Sorts edges and removes duplicates to maintain consistent state.
    fn dedup_edges(self: *Compactor, edges: []GraphEdge) ![]GraphEdge {
        if (edges.len == 0) return try self.backing_allocator.alloc(GraphEdge, 0);

        const sorted = try self.backing_allocator.dupe(GraphEdge, edges);
        defer self.backing_allocator.free(sorted);

        std.mem.sort(GraphEdge, sorted, {}, GraphEdge.less_than);

        var unique = try std.ArrayList(GraphEdge).initCapacity(self.backing_allocator, sorted.len);
        defer unique.deinit(self.backing_allocator);

        var prev_edge: ?GraphEdge = null;
        for (sorted) |edge| {
            // Skip exact duplicates
            if (prev_edge != null and
                edge.source_id.eql(prev_edge.?.source_id) and
                edge.target_id.eql(prev_edge.?.target_id) and
                edge.edge_type == prev_edge.?.edge_type)
            {
                continue;
            }

            try unique.append(self.backing_allocator, edge);
            prev_edge = edge;
        }

        return unique.toOwnedSlice(self.backing_allocator);
    }
};
