//! Direct File-to-Blocks Parser (Ownership-Compliant)
//!
//! All internal helpers, structs, and collections use IngestionBlock (ownership wrapper).
//! Only the final API boundary converts to ContextBlock for external use.

const std = @import("std");

const types = @import("../core/types.zig");
const ownership = @import("../core/ownership.zig");

const Allocator = std.mem.Allocator;
const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const EdgeType = types.EdgeType;
const IngestionBlock = ownership.ComptimeOwnedBlockType(.temporary);

/// Simple file content structure for direct parsing
/// Compatible with ingest_directory.zig FileContent
pub const FileContent = struct {
    data: []const u8,
    path: []const u8,
    content_type: []const u8,
    metadata: std.StringHashMap([]const u8),
    timestamp_ns: u64,
};

/// Configuration for direct parsing behavior
pub const ParseConfig = struct {
    include_function_bodies: bool = true,
    include_private: bool = true,
    include_tests: bool = true,
    max_function_body_size: u32 = 8192,
    create_import_blocks: bool = true,
};

/// Parse a file directly into ContextBlocks (API boundary)
pub fn parse_file_to_blocks(
    allocator: Allocator,
    file_content: FileContent,
    codebase_name: []const u8,
    config: ParseConfig,
) ![]ContextBlock {
    var owned_blocks: []IngestionBlock = undefined;
    if (std.mem.eql(u8, file_content.content_type, "text/zig")) {
        owned_blocks = try parse_zig_file_to_blocks(allocator, file_content, codebase_name, config);
    } else if (std.mem.startsWith(u8, file_content.content_type, "text/")) {
        owned_blocks = try parse_text_file_to_blocks(allocator, file_content, codebase_name, config);
    } else {
        // Unsupported content type - return empty slice
        return allocator.alloc(ContextBlock, 0);
    }
    // Convert to ContextBlock at API boundary
    var blocks = try allocator.alloc(ContextBlock, owned_blocks.len);
    defer allocator.free(owned_blocks);
    for (owned_blocks, 0..) |owned, i| {
        blocks[i] = owned.block;
    }
    return blocks;
}

/// Parse Zig source file directly into IngestionBlocks
fn parse_zig_file_to_blocks(
    allocator: Allocator,
    file_content: FileContent,
    codebase_name: []const u8,
    config: ParseConfig,
) ![]IngestionBlock {
    var blocks = std.ArrayList(IngestionBlock){};
    defer blocks.deinit(allocator); // Only on error

    var lines = std.mem.splitSequence(u8, file_content.data, "\n");
    var line_num: u32 = 1;
    var current_function: ?FunctionInfo = null;
    var brace_depth: i32 = 0;

    while (lines.next()) |line| {
        defer line_num += 1;

        const trimmed_line = std.mem.trim(u8, line, " \t");
        if (trimmed_line.len == 0) continue;

        brace_depth = brace_depth + @as(i32, @intCast(count_char(trimmed_line, '{'))) - @as(i32, @intCast(count_char(trimmed_line, '}')));

        // Imports
        if (config.create_import_blocks and std.mem.startsWith(u8, trimmed_line, "const ") and
            std.mem.indexOf(u8, trimmed_line, "@import(") != null)
        {
            const import_block = try create_import_block(allocator, file_content.path, codebase_name, trimmed_line, line_num);
            try blocks.append(allocator, import_block);
            continue;
        }

        // Function declarations
        if (is_function_declaration(trimmed_line)) {
            if (current_function) |*func_info| {
                const func_block = try create_function_block(allocator, file_content.path, codebase_name, func_info.*, line_num - 1);
                try blocks.append(allocator, func_block);
                func_info.deinit();
            }
            current_function = try parse_function_declaration(allocator, trimmed_line, line_num);
            errdefer if (current_function) |*func| func.deinit();

            // Check if this is a single-line function (ends on same line)
            if (brace_depth <= 0 and trimmed_line.len > 0 and trimmed_line[trimmed_line.len - 1] == '}') {
                const func_block = try create_function_block(allocator, file_content.path, codebase_name, current_function.?, line_num);
                try blocks.append(allocator, func_block);
                current_function.?.deinit();
                current_function = null;
            }
        } else if (current_function != null) {
            if (config.include_function_bodies and
                current_function.?.body_lines.items.len * 80 < config.max_function_body_size)
            {
                try current_function.?.body_lines.append(allocator, try allocator.dupe(u8, trimmed_line));
            }
            if (brace_depth <= 0 and trimmed_line.len > 0 and trimmed_line[trimmed_line.len - 1] == '}') {
                const func_block = try create_function_block(allocator, file_content.path, codebase_name, current_function.?, line_num);
                try blocks.append(allocator, func_block);
                current_function.?.deinit();
                current_function = null;
            }
        }

        // Test blocks
        if (config.include_tests and std.mem.startsWith(u8, trimmed_line, "test ")) {
            const test_block = try create_test_block(allocator, file_content.path, codebase_name, trimmed_line, line_num);
            try blocks.append(allocator, test_block);
        }

        // Struct/const declarations
        if (std.mem.startsWith(u8, trimmed_line, "pub const ") or
            std.mem.startsWith(u8, trimmed_line, "const "))
        {
            if (std.mem.indexOf(u8, trimmed_line, " = struct {") != null or
                std.mem.indexOf(u8, trimmed_line, " = enum {") != null or
                std.mem.indexOf(u8, trimmed_line, " = union {") != null)
            {
                const struct_block = try create_struct_block(allocator, file_content.path, codebase_name, trimmed_line, line_num);
                try blocks.append(allocator, struct_block);
            }
        }
    }

    // Final function if file ended mid-function
    if (current_function) |*func_info| {
        const func_block = try create_function_block(allocator, file_content.path, codebase_name, func_info.*, line_num);
        try blocks.append(allocator, func_block);
        func_info.deinit();
    }

    return blocks.toOwnedSlice(allocator);
}

/// Parse non-Zig text files into a single documentation IngestionBlock
fn parse_text_file_to_blocks(
    allocator: Allocator,
    file_content: FileContent,
    codebase_name: []const u8,
    config: ParseConfig,
) ![]IngestionBlock {
    _ = config;

    var blocks = std.ArrayList(IngestionBlock){};

    const block_id = BlockId.generate();
    const source_uri = try std.fmt.allocPrint(allocator, "file://{s}#L1-{d}", .{ file_content.path, count_lines(file_content.data) });
    const metadata_json = try create_text_metadata_json(allocator, file_content, codebase_name);
    const content = try allocator.dupe(u8, file_content.data);

    const block = IngestionBlock.take_ownership(ContextBlock{
        .id = block_id,
        .sequence = 0, // Storage engine will assign the actual global sequence
        .source_uri = source_uri,
        .metadata_json = metadata_json,
        .content = content,
    });

    try blocks.append(allocator, block);
    return blocks.toOwnedSlice(allocator);
}

/// Information about a function being parsed (internal, not a ContextBlock)
const FunctionInfo = struct {
    name: []const u8,
    signature: []const u8,
    start_line: u32,
    is_public: bool,
    is_test: bool,
    body_lines: std.ArrayList([]const u8),
    allocator: Allocator,

    pub fn deinit(self: *FunctionInfo) void {
        self.allocator.free(self.name);
        self.allocator.free(self.signature);
        for (self.body_lines.items) |line| {
            self.allocator.free(line);
        }
        self.body_lines.deinit(self.allocator);
    }
};

fn is_function_declaration(line: []const u8) bool {
    return (std.mem.startsWith(u8, line, "pub fn ") or
        std.mem.startsWith(u8, line, "fn ") or
        std.mem.startsWith(u8, line, "export fn ") or
        std.mem.startsWith(u8, line, "inline fn ")) and
        std.mem.indexOf(u8, line, "(") != null;
}

fn parse_function_declaration(allocator: Allocator, line: []const u8, line_num: u32) !FunctionInfo {
    const is_public = std.mem.startsWith(u8, line, "pub ");

    const fn_start = std.mem.indexOf(u8, line, "fn ") orelse return error.InvalidFunction;
    const name_start = fn_start + 3;
    const name_end = std.mem.indexOfAny(u8, line[name_start..], " (") orelse return error.InvalidFunction;
    const name = try allocator.dupe(u8, line[name_start .. name_start + name_end]);

    return FunctionInfo{
        .name = name,
        .signature = try allocator.dupe(u8, line),
        .start_line = line_num,
        .is_public = is_public,
        .is_test = false,
        .body_lines = std.ArrayList([]const u8){},
        .allocator = allocator,
    };
}

/// Create an IngestionBlock for a function
fn create_function_block(
    allocator: Allocator,
    file_path: []const u8,
    codebase_name: []const u8,
    func_info: FunctionInfo,
    end_line: u32,
) !IngestionBlock {
    const block_id = BlockId.generate();
    const source_uri = try std.fmt.allocPrint(allocator, "file://{s}#L{d}-{d}", .{ file_path, func_info.start_line, end_line });

    const metadata_json = try std.fmt.allocPrint(allocator, "{{" ++
        "\"unit_type\":\"function\"," ++
        "\"unit_id\":\"{s}:{s}\"," ++
        "\"codebase\":\"{s}\"," ++
        "\"location\":{{" ++
        "\"file_path\":\"{s}\"," ++
        "\"line_start\":{d}," ++
        "\"line_end\":{d}," ++
        "\"col_start\":1," ++
        "\"col_end\":80" ++
        "}}," ++
        "\"original_metadata\":{{" ++
        "\"visibility\":\"{s}\"" ++
        "}}" ++
        "}}", .{ file_path, func_info.name, codebase_name, file_path, func_info.start_line, end_line, if (func_info.is_public) "public" else "private" });

    var content = std.ArrayList(u8){};
    defer content.deinit(allocator);

    try content.appendSlice(allocator, func_info.signature);

    if (func_info.body_lines.items.len > 0) {
        for (func_info.body_lines.items) |body_line| {
            try content.append(allocator, '\n');
            try content.appendSlice(allocator, body_line);
        }
    }

    return IngestionBlock.take_ownership(ContextBlock{
        .id = block_id,
        .sequence = 0, // Storage engine will assign the actual global sequence
        .source_uri = source_uri,
        .metadata_json = metadata_json,
        .content = try content.toOwnedSlice(allocator),
    });
}

/// Create an IngestionBlock for an import
fn create_import_block(
    allocator: Allocator,
    file_path: []const u8,
    codebase_name: []const u8,
    line: []const u8,
    line_num: u32,
) !IngestionBlock {
    const block_id = BlockId.generate();
    const source_uri = try std.fmt.allocPrint(allocator, "file://{s}#L{d}-{d}", .{ file_path, line_num, line_num });

    const metadata_json = try std.fmt.allocPrint(allocator, "{{" ++
        "\"unit_type\":\"import\"," ++
        "\"unit_id\":\"{s}:import_{d}\"," ++
        "\"codebase\":\"{s}\"," ++
        "\"location\":{{" ++
        "\"file_path\":\"{s}\"," ++
        "\"line_start\":{d}," ++
        "\"line_end\":{d}," ++
        "\"col_start\":1," ++
        "\"col_end\":80" ++
        "}}" ++
        "}}", .{ file_path, line_num, codebase_name, file_path, line_num, line_num });

    return IngestionBlock.take_ownership(ContextBlock{
        .id = block_id,
        .sequence = 0, // Storage engine will assign the actual global sequence
        .source_uri = source_uri,
        .metadata_json = metadata_json,
        .content = try allocator.dupe(u8, line),
    });
}

/// Create an IngestionBlock for a test
fn create_test_block(
    allocator: Allocator,
    file_path: []const u8,
    codebase_name: []const u8,
    line: []const u8,
    line_num: u32,
) !IngestionBlock {
    const block_id = BlockId.generate();
    const source_uri = try std.fmt.allocPrint(allocator, "file://{s}#L{d}-{d}", .{ file_path, line_num, line_num });

    const metadata_json = try std.fmt.allocPrint(allocator, "{{" ++
        "\"unit_type\":\"test\"," ++
        "\"unit_id\":\"{s}:test_{d}\"," ++
        "\"codebase\":\"{s}\"," ++
        "\"location\":{{" ++
        "\"file_path\":\"{s}\"," ++
        "\"line_start\":{d}," ++
        "\"line_end\":{d}," ++
        "\"col_start\":1," ++
        "\"col_end\":80" ++
        "}}" ++
        "}}", .{ file_path, line_num, codebase_name, file_path, line_num, line_num });

    return IngestionBlock.take_ownership(ContextBlock{
        .id = block_id,
        .sequence = 0, // Storage engine will assign the actual global sequence
        .source_uri = source_uri,
        .metadata_json = metadata_json,
        .content = try allocator.dupe(u8, line),
    });
}

/// Create an IngestionBlock for a struct/const declaration
fn create_struct_block(
    allocator: Allocator,
    file_path: []const u8,
    codebase_name: []const u8,
    line: []const u8,
    line_num: u32,
) !IngestionBlock {
    const block_id = BlockId.generate();
    const source_uri = try std.fmt.allocPrint(allocator, "file://{s}#L{d}-{d}", .{ file_path, line_num, line_num });

    const metadata_json = try std.fmt.allocPrint(allocator, "{{" ++
        "\"unit_type\":\"struct\"," ++
        "\"unit_id\":\"{s}:struct_{d}\"," ++
        "\"codebase\":\"{s}\"," ++
        "\"location\":{{" ++
        "\"file_path\":\"{s}\"," ++
        "\"line_start\":{d}," ++
        "\"line_end\":{d}," ++
        "\"col_start\":1," ++
        "\"col_end\":80" ++
        "}}" ++
        "}}", .{ file_path, line_num, codebase_name, file_path, line_num, line_num });

    return IngestionBlock.take_ownership(ContextBlock{
        .id = block_id,
        .sequence = 0, // Storage engine will assign the actual global sequence
        .source_uri = source_uri,
        .metadata_json = metadata_json,
        .content = try allocator.dupe(u8, line),
    });
}

/// Create metadata JSON for text files
fn create_text_metadata_json(
    allocator: Allocator,
    file_content: FileContent,
    codebase_name: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{" ++
        "\"unit_type\":\"document\"," ++
        "\"unit_id\":\"{s}:document\"," ++
        "\"codebase\":\"{s}\"," ++
        "\"location\":{{" ++
        "\"file_path\":\"{s}\"," ++
        "\"line_start\":1," ++
        "\"line_end\":{d}," ++
        "\"col_start\":1," ++
        "\"col_end\":80" ++
        "}}," ++
        "\"content_type\":\"{s}\"" ++
        "}}", .{ file_content.path, codebase_name, file_content.path, count_lines(file_content.data), file_content.content_type });
}

fn count_char(str: []const u8, char: u8) u32 {
    var count: u32 = 0;
    for (str) |c| {
        if (c == char) count += 1;
    }
    return count;
}

fn count_lines(content: []const u8) u32 {
    return @intCast(std.mem.count(u8, content, "\n") + 1);
}
