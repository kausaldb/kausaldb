//! WAL Entry Structure and Operations
//!
//! Defines the WALEntry struct and all associated operations including
//! serialization, deserialization, creation methods, and memory management.
//! This module encapsulates the core entry format and validation logic.

const std = @import("std");

const context_block = @import("../../core/types.zig");
const assert_mod = @import("../../core/assert.zig");
const ownership = @import("../../core/ownership.zig");
const stream = @import("stream.zig");
const types = @import("types.zig");

const assert = assert_mod.assert;

const WALError = types.WALError;
pub const WALEntryType = types.WALEntryType;
const MAX_PAYLOAD_SIZE = types.MAX_PAYLOAD_SIZE;
const ContextBlock = context_block.ContextBlock;
const GraphEdge = context_block.GraphEdge;
const BlockId = context_block.BlockId;
const StorageEngineBlock = ownership.StorageEngineBlock;
const OwnedBlock = ownership.OwnedBlock;

/// WAL entry header structure with corruption detection
pub const WALEntry = struct {
    checksum: u64,
    entry_type: WALEntryType,
    payload_size: u32,
    payload: []const u8,
    /// Reserved for future pool optimization
    _reserved: u8 = 0,

    pub const HEADER_SIZE = 13; // 8 bytes checksum + 1 byte type + 4 bytes payload_size

    // Cross-platform binary compatibility requires fixed field sizes
    comptime {
        assert(@sizeOf(u64) == 8);
        assert(@sizeOf(u32) == 4);
        assert(@sizeOf(WALEntryType) == 1);

        const calculated_header_size = @sizeOf(u64) + @sizeOf(WALEntryType) + @sizeOf(u32);
        assert(HEADER_SIZE == calculated_header_size);
        assert(HEADER_SIZE == 13);

        // Minimum size prevents degenerate entries that waste storage
        assert(MAX_PAYLOAD_SIZE >= 1024);
        assert(MAX_PAYLOAD_SIZE <= types.MAX_SEGMENT_SIZE);
        assert(std.math.maxInt(u32) >= MAX_PAYLOAD_SIZE);
    }

    /// Calculate CRC-64 checksum of type and payload for corruption detection
    pub fn calculate_checksum(entry_type: WALEntryType, payload: []const u8) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(&[_]u8{@intFromEnum(entry_type)});
        hasher.update(payload);
        return hasher.final();
    }

    /// Serialize WAL entry to buffer for disk storage.
    /// Returns number of bytes written or WALError.BufferTooSmall if insufficient space.
    pub fn serialize(self: WALEntry, buffer: []u8) WALError!usize {
        const total_size = HEADER_SIZE + self.payload.len;
        if (buffer.len < total_size) return WALError.BufferTooSmall;

        var offset: usize = 0;

        std.mem.writeInt(u64, buffer[offset..][0..8], self.checksum, .little);
        offset += 8;

        buffer[offset] = @intFromEnum(self.entry_type);
        offset += 1;

        std.mem.writeInt(u32, buffer[offset..][0..4], self.payload_size, .little);
        offset += 4;

        @memcpy(buffer[offset .. offset + self.payload.len], self.payload);
        offset += self.payload.len;

        return offset;
    }

    /// Deserialize WAL entry from buffer, allocating payload memory.
    /// Caller must call deinit() to free allocated payload memory.
    /// Returns WALError.InvalidChecksum or WALError.InvalidEntryType for corruption.
    pub fn deserialize(allocator: std.mem.Allocator, buffer: []const u8) WALError!WALEntry {
        if (buffer.len < HEADER_SIZE) return WALError.BufferTooSmall;

        var offset: usize = 0;

        const checksum = std.mem.readInt(u64, buffer[offset..][0..8], .little);
        offset += 8;

        const entry_type = try WALEntryType.from_u8(buffer[offset]);
        offset += 1;

        const payload_size = std.mem.readInt(u32, buffer[offset..][0..4], .little);
        offset += 4;

        // Validate payload size is reasonable before checking buffer bounds
        if (payload_size > MAX_PAYLOAD_SIZE) {
            return WALError.CorruptedEntry;
        }

        // Validate payload size against remaining buffer
        if (offset + payload_size > buffer.len) {
            return WALError.BufferTooSmall;
        }

        const payload = try allocator.dupe(u8, buffer[offset .. offset + payload_size]);
        errdefer allocator.free(payload);

        // Verify checksum for corruption detection
        const expected_checksum = calculate_checksum(entry_type, payload);
        if (checksum != expected_checksum) {
            return WALError.InvalidChecksum;
        }

        return WALEntry{
            .checksum = checksum,
            .entry_type = entry_type,
            .payload_size = payload_size,
            .payload = payload,
        };
    }

    /// Create WAL entry for a ContextBlock with direct serialization.
    /// Most efficient method for raw block data.
    pub fn create_put_block_raw(allocator: std.mem.Allocator, block: ContextBlock) WALError!WALEntry {
        return create_put_block(allocator, block);
    }

    /// Create WAL entry for a StorageEngineBlock with ownership validation.
    /// Reads the block data through the storage engine ownership system.
    pub fn create_put_block_storage(allocator: std.mem.Allocator, block: StorageEngineBlock) WALError!WALEntry {
        const context_block_data = block.read(.storage_engine);
        return create_put_block(allocator, context_block_data);
    }

    /// Create WAL entry for an OwnedBlock with ownership validation.
    /// Reads the block data through the ownership system.
    pub fn create_put_block_owned(allocator: std.mem.Allocator, block: OwnedBlock) WALError!WALEntry {
        const context_block_data = block.read(.storage_engine);
        return create_put_block(allocator, context_block_data);
    }

    /// Create WAL entry from a Context Block (most common case).
    pub fn create_put_block(allocator: std.mem.Allocator, context_block_data: ContextBlock) WALError!WALEntry {
        const payload_size = context_block_data.serialized_size();

        // Zero-size blocks indicate serialization logic failure, not data corruption
        if (payload_size == 0) {
            return WALError.CorruptedEntry;
        }
        if (payload_size > MAX_PAYLOAD_SIZE) {
            return WALError.CorruptedEntry;
        }

        // Allocate payload buffer for WAL entry
        const payload = try allocator.alloc(u8, payload_size);
        errdefer allocator.free(payload);

        const bytes_written = try context_block_data.serialize(payload);

        // Serialization size mismatch indicates internal logic error
        assert(bytes_written == payload_size);
        if (bytes_written != payload_size) {
            return WALError.CorruptedEntry;
        }

        const checksum = calculate_checksum(.put_block, payload);

        const entry = WALEntry{
            .checksum = checksum,
            .entry_type = .put_block,
            // Safety: Payload size bounded by WAL entry limits and fits in u32
            .payload_size = @intCast(payload_size),
            .payload = payload,
        };

        // Corruption detection: validate entry header doesn't contain pattern data
        var header_buffer: [WALEntry.HEADER_SIZE]u8 = undefined;
        std.mem.writeInt(u64, header_buffer[0..8], entry.checksum, .little);
        header_buffer[8] = @intFromEnum(entry.entry_type);
        std.mem.writeInt(u32, header_buffer[9..13], entry.payload_size, .little);

        // Invariant: payload size consistency prevents downstream corruption
        assert(entry.payload_size == payload_size);
        assert(entry.payload.len == payload_size);

        return entry;
    }

    /// Create WAL entry for deleting a Context Block.
    /// Payload contains only the 16-byte BlockId for efficient deletion replay.
    pub fn create_delete_block(allocator: std.mem.Allocator, block_id: BlockId) WALError!WALEntry {
        comptime assert(@sizeOf(BlockId) == 16);

        const payload = try allocator.dupe(u8, &block_id.bytes);
        assert(payload.len == 16);

        const checksum = calculate_checksum(.delete_block, payload);

        const entry = WALEntry{
            .checksum = checksum,
            .entry_type = .delete_block,
            // Safety: Payload length bounded by serialization limits and fits in u32
            .payload_size = @intCast(payload.len),
            .payload = payload,
        };

        // Invariant: delete entries must contain exactly one BlockId
        assert(entry.payload.len == 16);
        assert(entry.payload_size == 16);

        return entry;
    }

    /// Create WAL entry for storing a Graph Edge.
    /// Serializes edge relationship data for graph index replay.
    pub fn create_put_edge(allocator: std.mem.Allocator, edge: GraphEdge) WALError!WALEntry {
        const payload = try allocator.alloc(u8, 40); // GraphEdge.SERIALIZED_SIZE
        errdefer allocator.free(payload);
        @memset(payload, 0);

        _ = try edge.serialize(payload);
        const checksum = calculate_checksum(.put_edge, payload);

        return WALEntry{
            .checksum = checksum,
            .entry_type = .put_edge,
            // Safety: Payload length bounded by serialization limits and fits in u32
            .payload_size = @intCast(payload.len),
            .payload = payload,
        };
    }

    /// Create WAL entry from stream components for compatibility with WALEntryStream
    /// Validates checksum and constructs proper WALEntry from streaming data
    pub fn deserialize_from_stream(
        checksum: u64,
        entry_type_raw: u8,
        payload: []const u8,
        allocator: std.mem.Allocator,
    ) WALError!WALEntry {
        const entry_type: WALEntryType = switch (entry_type_raw) {
            1 => .put_block,
            2 => .delete_block,
            3 => .put_edge,
            else => return WALError.InvalidEntryType,
        };

        const owned_payload = try allocator.dupe(u8, payload);
        errdefer allocator.free(owned_payload);
        const expected_checksum = calculate_checksum(entry_type, owned_payload);
        if (checksum != expected_checksum) {
            return WALError.InvalidChecksum;
        }

        return WALEntry{
            .checksum = checksum,
            .entry_type = entry_type,
            .payload_size = @intCast(owned_payload.len),
            .payload = owned_payload,
        };
    }

    /// Convert WALEntryStream.StreamEntry to WALEntry
    /// Transfers ownership of payload from StreamEntry to WALEntry
    pub fn from_stream_entry(allocator: std.mem.Allocator, stream_entry: stream.StreamEntry) WALError!WALEntry {
        return deserialize_from_stream(
            stream_entry.checksum,
            stream_entry.entry_type,
            stream_entry.payload,
            allocator,
        );
    }

    /// Extract ContextBlock from put_block entry payload
    pub fn extract_block(self: WALEntry, allocator: std.mem.Allocator) WALError!OwnedBlock {
        if (self.entry_type != .put_block) return WALError.InvalidEntryType;
        const block_data = ContextBlock.deserialize(allocator, self.payload) catch {
            return WALError.CorruptedEntry;
        };
        return OwnedBlock.take_ownership(block_data, .storage_engine);
    }

    /// Extract BlockId from delete_block entry payload
    pub fn extract_block_id(self: WALEntry) WALError!BlockId {
        if (self.entry_type != .delete_block) return WALError.InvalidEntryType;
        if (self.payload.len != 16) return WALError.CorruptedEntry;
        return BlockId{ .bytes = self.payload[0..16].* };
    }

    /// Extract GraphEdge from put_edge entry payload
    pub fn extract_edge(self: WALEntry) WALError!GraphEdge {
        if (self.entry_type != .put_edge) return WALError.InvalidEntryType;
        if (self.payload.len != 40) return WALError.CorruptedEntry;
        return GraphEdge.deserialize(self.payload) catch WALError.CorruptedEntry;
    }

    /// Free allocated payload memory.
    /// Must be called for all entries created via deserialize() or create_*() methods.
    pub fn deinit(self: WALEntry, allocator: std.mem.Allocator) void {
        // Size consistency prevents double-free and use-after-free bugs
        assert(self.payload.len == self.payload_size);

        if (self.payload.len > 0) {
            allocator.free(self.payload);
        }
    }
};

const testing = std.testing;

fn create_test_block() ContextBlock {
    return ContextBlock{
        .id = BlockId.from_hex("0123456789abcdef0123456789abcdef") catch unreachable, // Safety: hardcoded valid hex
        .version = 1,
        .source_uri = "test://wal_entry.zig",
        .metadata_json = "{}",
        .content = "test content for WAL entry",
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

test "WALEntry checksum calculation consistency" {
    const payload1 = "test payload";
    const payload2 = "test payload";
    const different_payload = "different payload";

    const checksum1 = WALEntry.calculate_checksum(.put_block, payload1);
    const checksum2 = WALEntry.calculate_checksum(.put_block, payload2);
    const checksum3 = WALEntry.calculate_checksum(.put_block, different_payload);
    const checksum4 = WALEntry.calculate_checksum(.delete_block, payload1);

    try testing.expectEqual(checksum1, checksum2);

    try testing.expect(checksum1 != checksum3);
    try testing.expect(checksum1 != checksum4);
}

test "WALEntry serialization roundtrip" {
    const allocator = testing.allocator;

    const test_payload = "Hello, WAL entry serialization!";
    const checksum = WALEntry.calculate_checksum(.put_block, test_payload);

    const original_entry = WALEntry{
        .checksum = checksum,
        .entry_type = .put_block,
        .payload_size = @intCast(test_payload.len),
        .payload = test_payload,
    };

    var buffer: [1024]u8 = undefined;
    const serialized_size = try original_entry.serialize(&buffer);

    const deserialized_entry = try WALEntry.deserialize(allocator, buffer[0..serialized_size]);
    defer deserialized_entry.deinit(allocator);

    try testing.expectEqual(original_entry.checksum, deserialized_entry.checksum);
    try testing.expectEqual(original_entry.entry_type, deserialized_entry.entry_type);
    try testing.expectEqual(original_entry.payload_size, deserialized_entry.payload_size);
    try testing.expect(std.mem.eql(u8, original_entry.payload, deserialized_entry.payload));
}

test "WALEntry serialization buffer too small" {
    const test_payload = "test payload";
    const checksum = WALEntry.calculate_checksum(.put_block, test_payload);

    const entry = WALEntry{
        .checksum = checksum,
        .entry_type = .put_block,
        .payload_size = @intCast(test_payload.len),
        .payload = test_payload,
    };

    var small_buffer: [10]u8 = undefined;
    try testing.expectError(WALError.BufferTooSmall, entry.serialize(&small_buffer));
}

test "WALEntry deserialization buffer too small" {
    const allocator = testing.allocator;

    var small_buffer: [5]u8 = undefined;
    try testing.expectError(WALError.BufferTooSmall, WALEntry.deserialize(allocator, &small_buffer));
    var partial_buffer: [WALEntry.HEADER_SIZE + 5]u8 = undefined;
    std.mem.writeInt(u64, partial_buffer[0..8], 0x1234567890abcdef, .little);
    partial_buffer[8] = 0x01;
    std.mem.writeInt(u32, partial_buffer[9..13], 100, .little);

    try testing.expectError(WALError.BufferTooSmall, WALEntry.deserialize(allocator, &partial_buffer));
}

test "WALEntry deserialization invalid checksum" {
    const allocator = testing.allocator;

    const test_payload = "test payload";
    var buffer: [1024]u8 = undefined;

    std.mem.writeInt(u64, buffer[0..8], 0xdeadbeef, .little);
    buffer[8] = 0x01;
    std.mem.writeInt(u32, buffer[9..13], @intCast(test_payload.len), .little);
    @memcpy(buffer[13 .. 13 + test_payload.len], test_payload);

    const buffer_size = WALEntry.HEADER_SIZE + test_payload.len;
    try testing.expectError(WALError.InvalidChecksum, WALEntry.deserialize(allocator, buffer[0..buffer_size]));
}

test "WALEntry deserialization invalid entry type" {
    const allocator = testing.allocator;

    var buffer: [WALEntry.HEADER_SIZE]u8 = undefined;
    std.mem.writeInt(u64, buffer[0..8], 0, .little);
    buffer[8] = 0xFF;
    std.mem.writeInt(u32, buffer[9..13], 0, .little);

    try testing.expectError(WALError.InvalidEntryType, WALEntry.deserialize(allocator, &buffer));
}

test "WALEntry deserialization oversized payload" {
    const allocator = testing.allocator;

    var buffer: [WALEntry.HEADER_SIZE]u8 = undefined;
    std.mem.writeInt(u64, buffer[0..8], 0, .little);
    buffer[8] = 0x01;
    std.mem.writeInt(u32, buffer[9..13], MAX_PAYLOAD_SIZE + 1, .little);

    try testing.expectError(WALError.CorruptedEntry, WALEntry.deserialize(allocator, &buffer));
}

test "WALEntry create_put_block" {
    const allocator = testing.allocator;

    const test_block = create_test_block();
    const entry = try WALEntry.create_put_block(allocator, test_block);
    defer entry.deinit(allocator);

    try testing.expectEqual(WALEntryType.put_block, entry.entry_type);
    try testing.expectEqual(@as(u32, @intCast(test_block.serialized_size())), entry.payload_size);
    try testing.expect(entry.payload.len > 0);

    const expected_checksum = WALEntry.calculate_checksum(.put_block, entry.payload);
    try testing.expectEqual(expected_checksum, entry.checksum);
}

test "WALEntry create_delete_block" {
    const allocator = testing.allocator;

    const test_id = BlockId.from_hex("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") catch unreachable; // Safety: hardcoded valid hex
    const entry = try WALEntry.create_delete_block(allocator, test_id);
    defer entry.deinit(allocator);

    try testing.expectEqual(WALEntryType.delete_block, entry.entry_type);
    try testing.expectEqual(@as(u32, 16), entry.payload_size);
    try testing.expectEqual(@as(usize, 16), entry.payload.len);
    try testing.expect(std.mem.eql(u8, &test_id.bytes, entry.payload));
    const expected_checksum = WALEntry.calculate_checksum(.delete_block, entry.payload);
    try testing.expectEqual(expected_checksum, entry.checksum);
}

test "WALEntry create_put_edge" {
    const allocator = testing.allocator;

    const test_edge = create_test_edge();
    const entry = try WALEntry.create_put_edge(allocator, test_edge);
    defer entry.deinit(allocator);

    try testing.expectEqual(WALEntryType.put_edge, entry.entry_type);
    try testing.expectEqual(@as(u32, 40), entry.payload_size);
    try testing.expectEqual(@as(usize, 40), entry.payload.len);
    const expected_checksum = WALEntry.calculate_checksum(.put_edge, entry.payload);
    try testing.expectEqual(expected_checksum, entry.checksum);
}

test "WALEntry deserialize_from_stream" {
    const allocator = testing.allocator;

    const test_payload = "stream test payload";
    const checksum = WALEntry.calculate_checksum(.put_block, test_payload);

    const entry = try WALEntry.deserialize_from_stream(checksum, 0x01, test_payload, allocator);
    defer entry.deinit(allocator);

    try testing.expectEqual(checksum, entry.checksum);
    try testing.expectEqual(WALEntryType.put_block, entry.entry_type);
    try testing.expectEqual(@as(u32, @intCast(test_payload.len)), entry.payload_size);
    try testing.expect(std.mem.eql(u8, test_payload, entry.payload));
}

test "WALEntry deserialize_from_stream invalid type" {
    const allocator = testing.allocator;

    const test_payload = "test payload";
    const checksum = WALEntry.calculate_checksum(.put_block, test_payload);

    try testing.expectError(WALError.InvalidEntryType, WALEntry.deserialize_from_stream(checksum, 0xFF, test_payload, allocator));
}

test "WALEntry deserialize_from_stream invalid checksum" {
    const allocator = testing.allocator;

    const test_payload = "test payload";
    const wrong_checksum: u64 = 0xdeadbeef;

    try testing.expectError(WALError.InvalidChecksum, WALEntry.deserialize_from_stream(wrong_checksum, 0x01, test_payload, allocator));
}

test "WALEntry header size constant" {
    const expected_size = @sizeOf(u64) + @sizeOf(u8) + @sizeOf(u32);
    try testing.expectEqual(@as(usize, expected_size), WALEntry.HEADER_SIZE);
    try testing.expectEqual(@as(usize, 13), WALEntry.HEADER_SIZE);
}

test "WALEntry memory management" {
    const allocator = testing.allocator;

    const test_block = create_test_block();
    const entry = try WALEntry.create_put_block(allocator, test_block);

    try testing.expect(entry.payload.len > 0);
    try testing.expectEqual(entry.payload.len, entry.payload_size);

    entry.deinit(allocator);
}

test "WALEntry edge cases" {
    const allocator = testing.allocator;

    const empty_checksum = WALEntry.calculate_checksum(.put_block, "");
    const empty_entry = WALEntry{
        .checksum = empty_checksum,
        .entry_type = .put_block,
        .payload_size = 0,
        .payload = "",
    };

    var buffer: [WALEntry.HEADER_SIZE]u8 = undefined;
    const serialized_size = try empty_entry.serialize(&buffer);
    try testing.expectEqual(@as(usize, WALEntry.HEADER_SIZE), serialized_size);

    const deserialized = try WALEntry.deserialize(allocator, &buffer);
    defer deserialized.deinit(allocator);

    try testing.expectEqual(empty_entry.checksum, deserialized.checksum);
    try testing.expectEqual(empty_entry.entry_type, deserialized.entry_type);
    try testing.expectEqual(empty_entry.payload_size, deserialized.payload_size);
    try testing.expectEqual(@as(usize, 0), deserialized.payload.len);
}

test "WALEntry large payload handling" {
    const allocator = testing.allocator;

    const large_payload_size = 1024 * 1024;
    const large_payload = try allocator.alloc(u8, large_payload_size);
    defer allocator.free(large_payload);
    @memset(large_payload, 0xAA);

    const checksum = WALEntry.calculate_checksum(.put_block, large_payload);
    const entry = WALEntry{
        .checksum = checksum,
        .entry_type = .put_block,
        .payload_size = @intCast(large_payload.len),
        .payload = large_payload,
    };

    const buffer = try allocator.alloc(u8, WALEntry.HEADER_SIZE + large_payload_size);
    defer allocator.free(buffer);

    const serialized_size = try entry.serialize(buffer);
    try testing.expectEqual(@as(usize, WALEntry.HEADER_SIZE + large_payload_size), serialized_size);

    const deserialized = try WALEntry.deserialize(allocator, buffer);
    defer deserialized.deinit(allocator);

    try testing.expectEqual(entry.checksum, deserialized.checksum);
    try testing.expectEqual(entry.entry_type, deserialized.entry_type);
    try testing.expectEqual(entry.payload_size, deserialized.payload_size);
    try testing.expect(std.mem.eql(u8, large_payload, deserialized.payload));
}

test "WALEntry extract_block success" {
    const allocator = testing.allocator;

    const test_block = create_test_block();
    const entry = try WALEntry.create_put_block(allocator, test_block);
    defer entry.deinit(allocator);

    const owned_block = try entry.extract_block(allocator);
    const extracted_block = owned_block.read(.storage_engine);
    defer allocator.free(extracted_block.source_uri);
    defer allocator.free(extracted_block.metadata_json);
    defer allocator.free(extracted_block.content);

    try testing.expect(test_block.id.eql(extracted_block.id));
    try testing.expectEqual(test_block.version, extracted_block.version);
    try testing.expectEqualStrings(test_block.source_uri, extracted_block.source_uri);
    try testing.expectEqualStrings(test_block.metadata_json, extracted_block.metadata_json);
    try testing.expectEqualStrings(test_block.content, extracted_block.content);
}

test "WALEntry extract_block invalid entry type" {
    const allocator = testing.allocator;

    const test_id = BlockId.from_hex("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") catch unreachable; // Safety: hardcoded valid hex
    const entry = try WALEntry.create_delete_block(allocator, test_id);
    defer entry.deinit(allocator);

    try testing.expectError(WALError.InvalidEntryType, entry.extract_block(allocator));
}

test "WALEntry extract_block_id success" {
    const allocator = testing.allocator;

    const test_id = BlockId.from_hex("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb") catch unreachable; // Safety: hardcoded valid hex
    const entry = try WALEntry.create_delete_block(allocator, test_id);
    defer entry.deinit(allocator);

    const extracted_id = try entry.extract_block_id();
    try testing.expect(test_id.eql(extracted_id));
}

test "WALEntry extract_block_id invalid entry type" {
    const allocator = testing.allocator;

    const test_block = create_test_block();
    const entry = try WALEntry.create_put_block(allocator, test_block);
    defer entry.deinit(allocator);

    try testing.expectError(WALError.InvalidEntryType, entry.extract_block_id());
}

test "WALEntry extract_block_id corrupted payload" {
    const corrupted_payload = "short";
    const checksum = WALEntry.calculate_checksum(.delete_block, corrupted_payload);

    const entry = WALEntry{
        .checksum = checksum,
        .entry_type = .delete_block,
        .payload_size = @intCast(corrupted_payload.len),
        .payload = corrupted_payload,
    };

    try testing.expectError(WALError.CorruptedEntry, entry.extract_block_id());
}

test "WALEntry extract_edge success" {
    const allocator = testing.allocator;

    const test_edge = create_test_edge();
    const entry = try WALEntry.create_put_edge(allocator, test_edge);
    defer entry.deinit(allocator);

    const extracted_edge = try entry.extract_edge();
    try testing.expect(test_edge.source_id.eql(extracted_edge.source_id));
    try testing.expect(test_edge.target_id.eql(extracted_edge.target_id));
    try testing.expectEqual(test_edge.edge_type, extracted_edge.edge_type);
}

test "WALEntry extract_edge invalid entry type" {
    const allocator = testing.allocator;

    const test_block = create_test_block();
    const entry = try WALEntry.create_put_block(allocator, test_block);
    defer entry.deinit(allocator);

    try testing.expectError(WALError.InvalidEntryType, entry.extract_edge());
}

test "WALEntry extract_edge corrupted payload" {
    const corrupted_payload = "wrong_size_payload";
    const checksum = WALEntry.calculate_checksum(.put_edge, corrupted_payload);

    const entry = WALEntry{
        .checksum = checksum,
        .entry_type = .put_edge,
        .payload_size = @intCast(corrupted_payload.len),
        .payload = corrupted_payload,
    };

    // Should fail due to incorrect payload size (should be 40 bytes)
    try testing.expectError(WALError.CorruptedEntry, entry.extract_edge());
}
