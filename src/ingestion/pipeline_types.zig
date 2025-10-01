//! Ingestion types for parsing source code into ContextBlocks.

const std = @import("std");
const types = @import("../core/types.zig");
const error_context = @import("../core/error_context.zig");

const ContextBlock = types.ContextBlock;
const EdgeType = types.EdgeType;

/// Errors that can occur during ingestion operations.
pub const IngestionError = error{
    ParsingFailed,
    ChunkingFailed,
    SourceNotFound,
    UnsupportedContentType,
    InvalidConfiguration,
    MaxDepthExceeded,
    FileTooLarge,
} || std.mem.Allocator.Error;

/// Source code location information for a parsed unit.
pub const SourceLocation = struct {
    file_path: []const u8,
    line_start: u32,
    line_end: u32,
    col_start: u32,
    col_end: u32,

    pub fn deinit(self: *SourceLocation, allocator: std.mem.Allocator) void {
        allocator.free(self.file_path);
    }
};

/// Relationship edge between parsed units.
pub const ParsedEdge = struct {
    edge_type: EdgeType,
    target_id: []const u8,
    metadata: std.StringHashMap([]const u8),

    pub fn deinit(self: *ParsedEdge, allocator: std.mem.Allocator) void {
        allocator.free(self.target_id);

        var iter = self.metadata.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.metadata.deinit();
    }
};

/// Semantic unit extracted from source code (function, type, etc).
///
/// Zero-copy design: `content` is a slice view into the source buffer.
/// The source buffer must remain valid for the lifetime of this ParsedUnit.
pub const ParsedUnit = struct {
    id: []const u8, // Owned: short identifier
    unit_type: []const u8, // Owned: short type name

    // CRITICAL: This is a non-owned, zero-copy slice into a long-lived buffer
    // managed by the top-level ingestion coordinator (e.g., in ingest_directory.zig).
    // Its ownership is transferred to the final ContextBlock, it is NOT freed here.
    content: []const u8,

    location: SourceLocation,
    edges: std.ArrayList(ParsedEdge),
    metadata: std.StringHashMap([]const u8),

    pub fn deinit(self: *ParsedUnit, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.unit_type);
        // NOTE: `content` is a non-owned slice and is NOT freed here.

        self.location.deinit(allocator);

        for (self.edges.items) |*edge| {
            edge.deinit(allocator);
        }
        self.edges.deinit(allocator);

        var iter = self.metadata.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.metadata.deinit();
    }
};

/// Source content with metadata (used by legacy fuzz tests).
pub const SourceContent = struct {
    data: []const u8,
    content_type: []const u8,
    source_uri: []const u8,
    metadata: std.StringHashMap([]const u8),
    timestamp_ns: i64,

    pub fn deinit(self: *SourceContent, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        allocator.free(self.content_type);
        allocator.free(self.source_uri);

        var iter = self.metadata.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.metadata.deinit();
    }
};
