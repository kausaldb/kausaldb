//! Minimal Pipeline Types for Backward Compatibility
//!
//! Provides essential types that legacy components (ZigParser, benchmarks, fuzz tests)
//! still depend on while the codebase transitions to the simplified FileIterator approach.
//! These types maintain API compatibility without the complex pipeline implementation.
//!
//! Design Rationale:
//! - Enables gradual migration from pipeline abstractions to direct processing
//! - Maintains existing test and benchmark functionality during transition
//! - Smaller surface area than full pipeline.zig - only essential types

const std = @import("std");
const types = @import("../core/types.zig");
const error_context = @import("../core/error_context.zig");

const ContextBlock = types.ContextBlock;
const EdgeType = types.EdgeType;

/// Error types for ingestion operations
pub const IngestionError = error{
    ParsingFailed,
    ChunkingFailed,
    SourceNotFound,
    UnsupportedContentType,
    InvalidConfiguration,
    MaxDepthExceeded,
} || std.mem.Allocator.Error;

/// Source location information for parsed units
pub const SourceLocation = struct {
    /// File path where this unit was found
    file_path: []const u8,
    /// Starting line number (1-based)
    line_start: u32,
    /// Ending line number (1-based)
    line_end: u32,
    /// Starting column (1-based)
    col_start: u32,
    /// Ending column (1-based)
    col_end: u32,

    pub fn deinit(self: *SourceLocation, allocator: std.mem.Allocator) void {
        allocator.free(self.file_path);
    }
};

/// Edge relationship between parsed units
pub const ParsedEdge = struct {
    /// Type of relationship (imports, calls, etc.)
    edge_type: EdgeType,
    /// Target unit identifier
    target_id: []const u8,
    /// Additional edge metadata
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

/// Semantic unit extracted from source content
pub const ParsedUnit = struct {
    /// Unique identifier for this unit within the source
    id: []const u8,
    /// Type of semantic unit (e.g., "function", "struct", "comment", "section")
    unit_type: []const u8,
    /// The actual content
    content: []const u8,
    /// Source location information
    location: SourceLocation,
    /// Relationships to other units
    edges: std.array_list.Managed(ParsedEdge),
    /// Additional unit metadata
    metadata: std.StringHashMap([]const u8),

    pub fn deinit(self: *ParsedUnit, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.unit_type);
        allocator.free(self.content);

        self.location.deinit(allocator);

        for (self.edges.items) |*edge| {
            edge.deinit(allocator);
        }
        self.edges.deinit();

        var iter = self.metadata.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.metadata.deinit();
    }
};

/// Source content with metadata
pub const SourceContent = struct {
    /// Raw content data
    data: []const u8,
    /// Content type (MIME type)
    content_type: []const u8,
    /// Source URI or file path
    source_uri: []const u8,
    /// Source metadata
    metadata: std.StringHashMap([]const u8),
    /// Content timestamp (nanoseconds since epoch)
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

/// Parser interface for legacy compatibility
pub const Parser = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Parse content into semantic units
        parse: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, content: SourceContent) IngestionError![]ParsedUnit,
        /// Check if this parser supports the given content type
        supports: *const fn (ptr: *anyopaque, content_type: []const u8) bool,
        /// Get human-readable description of this parser
        describe: *const fn (ptr: *anyopaque) []const u8,
        /// Clean up parser resources
        deinit: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
    };

    /// Parse source content into semantic units
    pub fn parse(self: Parser, allocator: std.mem.Allocator, content: SourceContent) IngestionError![]ParsedUnit {
        return self.vtable.parse(self.ptr, allocator, content);
    }

    /// Check if parser supports content type
    pub fn supports(self: Parser, content_type: []const u8) bool {
        return self.vtable.supports(self.ptr, content_type);
    }

    /// Get parser description
    pub fn describe(self: Parser) []const u8 {
        return self.vtable.describe(self.ptr);
    }

    /// Clean up parser resources
    pub fn deinit(self: Parser, allocator: std.mem.Allocator) void {
        return self.vtable.deinit(self.ptr, allocator);
    }
};

/// Helper function to create SourceContent from file data
pub fn create_source_content(
    allocator: std.mem.Allocator,
    data: []const u8,
    content_type: []const u8,
    source_uri: []const u8,
) !SourceContent {
    return SourceContent{
        .data = try allocator.dupe(u8, data),
        .content_type = try allocator.dupe(u8, content_type),
        .source_uri = try allocator.dupe(u8, source_uri),
        .metadata = std.StringHashMap([]const u8).init(allocator),
        .timestamp_ns = std.time.nanoTimestamp(),
    };
}
