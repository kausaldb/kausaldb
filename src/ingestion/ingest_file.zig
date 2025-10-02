//! File-to-blocks ingestion with AST-based Zig parsing.

const std = @import("std");

const types = @import("../core/types.zig");
const ownership = @import("../core/ownership.zig");
const zig_parser = @import("parsers/zig_parser.zig");
const pipeline_types = @import("pipeline_types.zig");

const Allocator = std.mem.Allocator;
const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const IngestionBlock = ownership.ComptimeOwnedBlockType(.temporary);

/// File content with metadata for parsing.
/// The data field is null-terminated to support Zig's AST parser requirements.
/// Memory is managed by the ArenaCoordinator in ingest_directory for zero-copy optimization.
pub const FileContent = struct {
    data: [:0]const u8, // Null-terminated for Ast.parse compatibility
    path: []const u8,
    content_type: []const u8,
    metadata: std.StringHashMap([]const u8),
    timestamp_ns: u64,
};

/// Configuration for parsing behavior.
pub const ParseConfig = struct {
    include_function_bodies: bool = true,
    include_private: bool = true,
    include_tests: bool = true,
    max_function_body_size: u32 = 8192,
    create_import_blocks: bool = true,
};

/// Parse file content into ContextBlocks based on content type.
/// Dispatches to AST-based parser for Zig files, plain text for others.
/// Returns caller-owned array of blocks allocated from provided allocator.
pub fn parse_file_to_blocks(
    allocator: Allocator,
    file_content: FileContent,
    codebase_name: []const u8,
    config: ParseConfig,
) ![]ContextBlock {
    const owned_blocks = if (std.mem.eql(u8, file_content.content_type, "text/zig"))
        try parse_zig_file(allocator, file_content, codebase_name)
    else if (std.mem.startsWith(u8, file_content.content_type, "text/"))
        try parse_text_file(allocator, file_content, codebase_name, config)
    else
        return allocator.alloc(ContextBlock, 0);

    defer allocator.free(owned_blocks);

    var blocks = try allocator.alloc(ContextBlock, owned_blocks.len);
    for (owned_blocks, 0..) |owned, i| {
        blocks[i] = owned.block;
    }
    return blocks;
}

fn parse_zig_file(
    allocator: Allocator,
    file_content: FileContent,
    codebase_name: []const u8,
) ![]IngestionBlock {
    // Pass data directly with no allocation, coordinator's arena owns memory.
    const parsed_units = try zig_parser.parse(allocator, file_content.data, file_content.path);
    defer {
        for (parsed_units) |*unit| {
            var mutable_unit = unit.*;
            mutable_unit.deinit(allocator);
        }
        allocator.free(parsed_units);
    }

    var blocks = std.ArrayList(IngestionBlock){};
    errdefer blocks.deinit(allocator);

    for (parsed_units) |*unit| {
        try blocks.append(allocator, try translate_unit_to_block(allocator, unit, codebase_name));
    }

    return blocks.toOwnedSlice(allocator);
}

fn translate_unit_to_block(
    allocator: Allocator,
    unit: *pipeline_types.ParsedUnit,
    codebase_name: []const u8,
) !IngestionBlock {
    const source_uri = try std.fmt.allocPrint(
        allocator,
        "file://{s}#L{d}-{d}",
        .{ unit.location.file_path, unit.location.line_start, unit.location.line_end },
    );

    const metadata_json = try std.fmt.allocPrint(
        allocator,
        \\{{
        \\  "unit_type": "{s}",
        \\  "unit_id": "{s}:{s}",
        \\  "codebase": "{s}"
        \\}}
    ,
        .{ unit.unit_type, unit.location.file_path, unit.id, codebase_name },
    );

    // We can safely transfer content to the `ContextBlock` without allocation.
    const content = unit.content;
    unit.content = ""; // Null out to prevent double-free

    return IngestionBlock.take_ownership(ContextBlock{
        .id = BlockId.generate(),
        .sequence = 0,
        .source_uri = source_uri,
        .metadata_json = metadata_json,
        .content = content,
    });
}

fn parse_text_file(
    allocator: Allocator,
    file_content: FileContent,
    codebase_name: []const u8,
    config: ParseConfig,
) ![]IngestionBlock {
    _ = config;

    const line_count = std.mem.count(u8, file_content.data, "\n") + 1;

    const source_uri = try std.fmt.allocPrint(
        allocator,
        "file://{s}#L1-{d}",
        .{ file_content.path, line_count },
    );

    const metadata_json = try std.fmt.allocPrint(
        allocator,
        \\{{
        \\  "unit_type": "document",
        \\  "unit_id": "{s}:document",
        \\  "codebase": "{s}",
        \\  "content_type": "{s}"
        \\}}
    ,
        .{ file_content.path, codebase_name, file_content.content_type },
    );

    var blocks = std.ArrayList(IngestionBlock){};
    try blocks.append(allocator, IngestionBlock.take_ownership(ContextBlock{
        .id = BlockId.generate(),
        .sequence = 0,
        .source_uri = source_uri,
        .metadata_json = metadata_json,
        .content = try allocator.dupe(u8, file_content.data),
    }));

    return blocks.toOwnedSlice(allocator);
}
