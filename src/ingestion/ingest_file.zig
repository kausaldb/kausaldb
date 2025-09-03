//! Direct File-to-Blocks Parser
//!
//! Eliminates the ParsedUnit abstraction by parsing files directly into ContextBlocks.
//! Follows KausalDB's "Simplicity is the prerequisite for reliability" principle
//! by providing a single, explicit function that handles file parsing without
//! intermediate representations or complex chunking strategies.
//!
//! Design Principles:
//! - Direct transformation: FileContent -> ContextBlocks (no intermediate steps)
//! - Single responsibility: One function handles complete file processing
//! - Explicit control flow: No hidden abstractions or pipeline magic
//! - Arena-based memory management for bounded allocations

const std = @import("std");
const assert_mod = @import("../core/assert.zig");
const assert = assert_mod.assert;
const types = @import("../core/types.zig");

const Allocator = std.mem.Allocator;
const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const EdgeType = types.EdgeType;

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
    /// Whether to include function bodies or just signatures
    include_function_bodies: bool = true,
    /// Whether to extract private (non-pub) definitions
    include_private: bool = true,
    /// Whether to extract test blocks
    include_tests: bool = true,
    /// Maximum function body size to parse (bytes)
    max_function_body_size: u32 = 8192,
    /// Whether to create separate blocks for imports
    create_import_blocks: bool = true,
};

/// Parse a file directly into ContextBlocks, eliminating intermediate abstractions
pub fn parse_file_to_blocks(
    allocator: Allocator,
    file_content: FileContent,
    codebase_name: []const u8,
    config: ParseConfig,
) ![]ContextBlock {
    // Route to appropriate parser based on content type
    if (std.mem.eql(u8, file_content.content_type, "text/zig")) {
        return parse_zig_file_to_blocks(allocator, file_content, codebase_name, config);
    } else if (std.mem.startsWith(u8, file_content.content_type, "text/")) {
        return parse_text_file_to_blocks(allocator, file_content, codebase_name, config);
    } else {
        // Unsupported content type - return empty slice
        return allocator.alloc(ContextBlock, 0);
    }
}

/// Parse Zig source file directly into ContextBlocks
fn parse_zig_file_to_blocks( // tidy:ignore-length
    allocator: Allocator,
    file_content: FileContent,
    codebase_name: []const u8,
    config: ParseConfig,
) ![]ContextBlock {
    var blocks = std.array_list.Managed(ContextBlock).init(allocator);
    defer blocks.deinit(); // Only on error - success path transfers ownership

    // Parse the file line by line to extract semantic units
    var lines = std.mem.splitSequence(u8, file_content.data, "\n");
    var line_num: u32 = 1;
    var current_function: ?FunctionInfo = null;
    var brace_depth: i32 = 0;

    while (lines.next()) |line| {
        defer line_num += 1;

        const trimmed_line = std.mem.trim(u8, line, " \t");
        if (trimmed_line.len == 0) continue; // Skip empty lines

        // Track brace depth for function body extraction
        brace_depth = brace_depth + @as(i32, @intCast(count_char(trimmed_line, '{'))) - @as(i32, @intCast(count_char(trimmed_line, '}')));

        // Handle imports
        if (config.create_import_blocks and std.mem.startsWith(u8, trimmed_line, "const ") and
            std.mem.indexOf(u8, trimmed_line, "@import(") != null)
        {
            const import_block = try create_import_block(allocator, file_content.path, codebase_name, trimmed_line, line_num);
            try blocks.append(import_block);
            continue;
        }

        // Handle function declarations
        if (is_function_declaration(trimmed_line)) {
            // Finish previous function if any
            if (current_function) |func_info| {
                const func_block = try create_function_block(allocator, file_content.path, codebase_name, func_info, line_num - 1);
                try blocks.append(func_block);
            }

            // Start new function
            current_function = try parse_function_declaration(allocator, trimmed_line, line_num);
        } else if (current_function != null) {
            // Accumulate function body
            if (config.include_function_bodies and
                current_function.?.body_lines.items.len * 80 < config.max_function_body_size)
            { // Rough size estimate
                try current_function.?.body_lines.append(try allocator.dupe(u8, trimmed_line));
            }

            // End function when braces balance and we're back to top level
            if (brace_depth <= 0 and trimmed_line.len > 0 and trimmed_line[trimmed_line.len - 1] == '}') {
                const func_block = try create_function_block(allocator, file_content.path, codebase_name, current_function.?, line_num);
                try blocks.append(func_block);

                // Function ownership transfers to blocks list, preventing memory leaks
                current_function.?.deinit();
                current_function = null;
            }
        }

        // Handle test blocks
        if (config.include_tests and std.mem.startsWith(u8, trimmed_line, "test ")) {
            const test_block = try create_test_block(allocator, file_content.path, codebase_name, trimmed_line, line_num);
            try blocks.append(test_block);
        }

        // Handle struct/const declarations
        if (std.mem.startsWith(u8, trimmed_line, "pub const ") or
            std.mem.startsWith(u8, trimmed_line, "const "))
        {
            if (std.mem.indexOf(u8, trimmed_line, " = struct {") != null or
                std.mem.indexOf(u8, trimmed_line, " = enum {") != null or
                std.mem.indexOf(u8, trimmed_line, " = union {") != null)
            {
                const struct_block = try create_struct_block(allocator, file_content.path, codebase_name, trimmed_line, line_num);
                try blocks.append(struct_block);
            }
        }
    }

    // Handle final function if file ended mid-function
    if (current_function) |*func_info| {
        const func_block = try create_function_block(allocator, file_content.path, codebase_name, func_info.*, line_num);
        try blocks.append(func_block);
        func_info.deinit();
    }

    return blocks.toOwnedSlice();
}

/// Parse non-Zig text files into a single documentation block
fn parse_text_file_to_blocks(
    allocator: Allocator,
    file_content: FileContent,
    codebase_name: []const u8,
    config: ParseConfig,
) ![]ContextBlock {
    _ = config; // Not used for text files yet

    var blocks = std.array_list.Managed(ContextBlock).init(allocator);

    // Create a single documentation block for the entire file
    const block_id = BlockId.generate();
    const source_uri = try std.fmt.allocPrint(allocator, "file://{s}#L1-{d}", .{ file_content.path, count_lines(file_content.data) });
    const metadata_json = try create_text_metadata_json(allocator, file_content, codebase_name);
    const content = try allocator.dupe(u8, file_content.data);

    const block = ContextBlock{
        .id = block_id,
        .version = 1,
        .source_uri = source_uri,
        .metadata_json = metadata_json,
        .content = content,
    };

    try blocks.append(block);
    return blocks.toOwnedSlice();
}

/// Information about a function being parsed
const FunctionInfo = struct {
    name: []const u8,
    signature: []const u8,
    start_line: u32,
    is_public: bool,
    is_test: bool,
    body_lines: std.array_list.Managed([]const u8),
    allocator: Allocator,

    pub fn deinit(self: *FunctionInfo) void {
        self.allocator.free(self.name);
        self.allocator.free(self.signature);
        for (self.body_lines.items) |line| {
            self.allocator.free(line);
        }
        self.body_lines.deinit();
    }
};

/// Check if a line contains a function declaration
fn is_function_declaration(line: []const u8) bool {
    return (std.mem.startsWith(u8, line, "pub fn ") or
        std.mem.startsWith(u8, line, "fn ") or
        std.mem.startsWith(u8, line, "export fn ") or
        std.mem.startsWith(u8, line, "inline fn ")) and
        std.mem.indexOf(u8, line, "(") != null;
}

/// Parse function declaration into FunctionInfo
fn parse_function_declaration(allocator: Allocator, line: []const u8, line_num: u32) !FunctionInfo {
    const is_public = std.mem.startsWith(u8, line, "pub ");

    // Extract function name
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
        .body_lines = std.array_list.Managed([]const u8).init(allocator),
        .allocator = allocator,
    };
}

/// Create a ContextBlock for a function
fn create_function_block(
    allocator: Allocator,
    file_path: []const u8,
    codebase_name: []const u8,
    func_info: FunctionInfo,
    end_line: u32,
) !ContextBlock {
    const block_id = BlockId.generate();
    const source_uri = try std.fmt.allocPrint(allocator, "file://{s}#L{d}-{d}", .{ file_path, func_info.start_line, end_line });

    // JSON metadata enables downstream query engine to filter and classify blocks
    // without re-parsing source code, trading storage space for query performance
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

    // Build content
    var content = std.array_list.Managed(u8).init(allocator);
    defer content.deinit();

    try content.appendSlice(func_info.signature);

    if (func_info.body_lines.items.len > 0) {
        for (func_info.body_lines.items) |body_line| {
            try content.append('\n');
            try content.appendSlice(body_line);
        }
    }

    return ContextBlock{
        .id = block_id,
        .version = 1,
        .source_uri = source_uri,
        .metadata_json = metadata_json,
        .content = try content.toOwnedSlice(),
    };
}

/// Create a ContextBlock for an import
fn create_import_block(
    allocator: Allocator,
    file_path: []const u8,
    codebase_name: []const u8,
    line: []const u8,
    line_num: u32,
) !ContextBlock {
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

    return ContextBlock{
        .id = block_id,
        .version = 1,
        .source_uri = source_uri,
        .metadata_json = metadata_json,
        .content = try allocator.dupe(u8, line),
    };
}

/// Create a ContextBlock for a test
fn create_test_block(
    allocator: Allocator,
    file_path: []const u8,
    codebase_name: []const u8,
    line: []const u8,
    line_num: u32,
) !ContextBlock {
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

    return ContextBlock{
        .id = block_id,
        .version = 1,
        .source_uri = source_uri,
        .metadata_json = metadata_json,
        .content = try allocator.dupe(u8, line),
    };
}

/// Create a ContextBlock for a struct/const declaration
fn create_struct_block(
    allocator: Allocator,
    file_path: []const u8,
    codebase_name: []const u8,
    line: []const u8,
    line_num: u32,
) !ContextBlock {
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

    return ContextBlock{
        .id = block_id,
        .version = 1,
        .source_uri = source_uri,
        .metadata_json = metadata_json,
        .content = try allocator.dupe(u8, line),
    };
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

/// Count occurrences of a character in a string
fn count_char(str: []const u8, char: u8) u32 {
    var count: u32 = 0;
    for (str) |c| {
        if (c == char) count += 1;
    }
    return count;
}

/// Count lines in text content
fn count_lines(content: []const u8) u32 {
    return @intCast(std.mem.count(u8, content, "\n") + 1);
}
