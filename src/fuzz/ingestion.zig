//! Ingestion pipeline fuzzing for code parsing and directory ingestion bugs.
//!
//! Tests ingestion robustness against malformed source code, invalid file structures,
//! corrupt metadata, and edge cases in the parsing pipeline.

const std = @import("std");

const internal = @import("internal");
const main = @import("main.zig");

const SimulationVFS = internal.SimulationVFS;
const ArenaCoordinator = internal.memory.ArenaCoordinator;
const ContextBlock = internal.ContextBlock;
const IngestionConfig = internal.ingestion.ingest_directory.IngestionConfig;
const ZigParser = internal.ingestion.zig.parser.ZigParser;
const ZigParserConfig = internal.ingestion.zig.parser.ZigParserConfig;
const SourceContent = internal.ingestion.pipeline_types.SourceContent;

pub fn run_fuzzing(fuzzer: *main.Fuzzer) !void {
    std.debug.print("Fuzzing ingestion pipeline...\n", .{});

    for (0..fuzzer.config.iterations) |i| {
        const input = try fuzzer.generate_input(1024);

        const strategy = i % 8;
        switch (strategy) {
            0 => fuzz_zig_parser(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            1 => fuzz_file_ingestion(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            2 => fuzz_directory_ingestion(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            3 => fuzz_malformed_zig_code(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            4 => fuzz_extreme_file_structures(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            5 => fuzz_unicode_and_encoding(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            6 => fuzz_large_files(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            7 => fuzz_edge_case_syntax(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            else => unreachable,
        }

        fuzzer.record_iteration();
    }
}

/// Test Zig parser with malformed and edge-case code
fn fuzz_zig_parser(allocator: std.mem.Allocator, input: []const u8) !void {
    // Test various parser configurations
    const configs = [_]ZigParserConfig{
        .{ .include_function_bodies = true, .include_private = true },
        .{ .include_function_bodies = false, .include_private = false },
        .{ .max_nesting_depth = 1 }, // Extreme low depth
        .{ .max_nesting_depth = 1000 }, // Extreme high depth
    };

    for (configs) |config| {
        var parser = ZigParser.init(allocator, config);

        // Test with raw fuzz input as Zig code
        const source_content = SourceContent{
            .data = input,
            .content_type = "text/plain",
            .source_uri = "/fuzz/test.zig",
            .metadata = std.StringHashMap([]const u8).init(allocator),
            .timestamp_ns = @intCast(std.time.nanoTimestamp()),
        };

        // Parser should not crash, even with invalid input
        _ = parser.parse(allocator, source_content) catch {};
    }
}

/// Test file ingestion with corrupt and malformed files
fn fuzz_file_ingestion(allocator: std.mem.Allocator, input: []const u8) !void {
    var sim_vfs = try SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = ArenaCoordinator.init(&arena);

    // Create fuzzed file content
    const file_path = "/fuzz/test.zig";
    var file = try sim_vfs.vfs().create(file_path);
    defer file.close();
    _ = try file.write(input);

    _ = input.len; // Just to avoid unused variable if we don't use it elsewhere

    // Create FileContent structure
    const file_content = internal.ingestion.ingest_file.FileContent{
        .data = input,
        .path = file_path,
        .content_type = "text/zig",
        .metadata = std.StringHashMap([]const u8).init(allocator),
        .timestamp_ns = @intCast(std.time.nanoTimestamp()),
    };

    // Create ParseConfig
    const parse_config = internal.ingestion.ingest_file.ParseConfig{
        .include_function_bodies = true,
        .include_private = true,
        .include_tests = true,
        .max_function_body_size = 8192,
        .create_import_blocks = true,
    };

    // Test file ingestion - should handle corrupt files gracefully
    _ = internal.ingestion.ingest_file.parse_file_to_blocks(
        allocator,
        file_content,
        "fuzz_codebase",
        parse_config,
    ) catch {};
}

/// Test directory ingestion with complex file structures
fn fuzz_directory_ingestion(allocator: std.mem.Allocator, input: []const u8) !void {
    var sim_vfs = try SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var arena_coordinator = ArenaCoordinator.init(&arena);

    // Create fuzzed directory structure
    const base_dir = "/fuzz_project";
    try sim_vfs.vfs().mkdir(base_dir);

    // Create multiple files with fuzzed content
    var file_count: usize = 0;
    var offset: usize = 0;
    while (offset < input.len and file_count < 20) {
        const chunk_size = @min(input.len - offset, 1000);
        if (chunk_size == 0) break;

        const filename = try std.fmt.allocPrint(allocator, "{s}/fuzz_{d}.zig", .{ base_dir, file_count });
        defer allocator.free(filename);

        var file = try sim_vfs.vfs().create(filename);
        defer file.close();
        _ = try file.write(input[offset .. offset + chunk_size]);

        offset += chunk_size + 1;
        file_count += 1;
    }

    // Create subdirectories with more files
    if (input.len > 500) {
        const subdir = try std.fmt.allocPrint(allocator, "{s}/submodule", .{base_dir});
        defer allocator.free(subdir);

        try sim_vfs.vfs().mkdir(subdir);

        const subfile = try std.fmt.allocPrint(allocator, "{s}/sub.zig", .{subdir});
        defer allocator.free(subfile);

        const sub_content = if (input.len > 1000) input[500..1000] else input[500..];
        var sub_file = try sim_vfs.vfs().create(subfile);
        defer sub_file.close();
        _ = try sub_file.write(sub_content);
    }

    var include_patterns_1 = [_][]const u8{ ".zig", ".md" };
    var exclude_patterns_1 = [_][]const u8{};
    const config = IngestionConfig{
        .include_patterns = include_patterns_1[0..],
        .exclude_patterns = exclude_patterns_1[0..],
        .max_file_size = 10000,
        .include_function_bodies = true,
        .include_private = true,
    };

    // Test directory ingestion
    var vfs_instance = sim_vfs.vfs();
    _ = internal.ingestion.ingest_directory.ingest_directory_to_blocks(
        &arena_coordinator,
        allocator,
        &vfs_instance,
        base_dir,
        "fuzz_codebase",
        config,
    ) catch {};
}

/// Test with specifically malformed Zig code constructs
fn fuzz_malformed_zig_code(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate malformed Zig code by mixing fuzz input with Zig syntax
    const malformed_templates = [_][]const u8{
        "fn {s}() {s} {{ {s} }}", // Malformed function
        "const {s} = {s};", // Malformed constant
        "pub struct {s} {{ {s}: {s} }};", // Malformed struct
        "import \"{s}\"; {s}", // Malformed import
        "// {s}\nconst x = {s}; {s}", // Mixed content
        "test \"{s}\" {{ {s} }}", // Malformed test
        "comptime {{ {s} }} {s}", // Malformed comptime
        "extern fn {s}({s}) {s};", // Malformed extern
    };

    var parser = ZigParser.init(allocator, .{});

    for (malformed_templates) |_| {
        // Fill template with fuzz data
        var chunks = std.mem.splitScalar(u8, input, 0);
        var chunk_array = [_][]const u8{ "", "", "" };
        var i: usize = 0;
        while (chunks.next()) |chunk| {
            if (i >= chunk_array.len) break;
            chunk_array[i] = chunk;
            i += 1;
        }

        // Create simple malformed code by mixing template with chunks
        const malformed_code = std.fmt.allocPrint(
            allocator,
            "fn test() void {{ {s} }} {s} struct {{ {s} }}",
            .{ chunk_array[0], chunk_array[1], chunk_array[2] },
        ) catch continue;
        defer allocator.free(malformed_code);

        const source_content = SourceContent{
            .data = malformed_code,
            .source_uri = "/fuzz/malformed.zig",
            .codebase_name = "malformed_test",
        };

        _ = parser.parse_to_semantic_units(source_content) catch {};
    }
}

/// Test with extreme file structures and edge cases
fn fuzz_extreme_file_structures(allocator: std.mem.Allocator, input: []const u8) !void {
    var sim_vfs = try SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = ArenaCoordinator.init(&arena);

    // Test extreme cases
    const test_cases = [_]struct { path: []const u8, content: []const u8 }{
        // Empty file
        .{ .path = "/empty.zig", .content = "" },

        // File with only whitespace
        .{ .path = "/whitespace.zig", .content = "   \n\t\r\n   " },

        // Single character files
        .{ .path = "/single.zig", .content = "x" },

        // Files with extreme nesting (if input is long enough)
        .{ .path = "/nested.zig", .content = if (input.len > 10) "{{{{{{{{{{" else "{" },

        // Binary data masquerading as Zig
        .{ .path = "/binary.zig", .content = input },
    };

    for (test_cases) |test_case| {
        var test_file = try sim_vfs.vfs().create(test_case.path);
        defer test_file.close();
        _ = try test_file.write(test_case.content);

        const file_content = internal.ingestion.ingest_file.FileContent{
            .data = test_case.content,
            .path = test_case.path,
            .content_type = "text/zig",
            .metadata = std.StringHashMap([]const u8).init(allocator),
            .timestamp_ns = @intCast(std.time.nanoTimestamp()),
        };

        const parse_config = internal.ingestion.ingest_file.ParseConfig{};

        _ = internal.ingestion.ingest_file.parse_file_to_blocks(
            allocator,
            file_content,
            "extreme_test",
            parse_config,
        ) catch {};
    }
}

/// Test with Unicode, encoding issues, and special characters
fn fuzz_unicode_and_encoding(allocator: std.mem.Allocator, input: []const u8) !void {
    var parser = ZigParser.init(allocator, .{});

    // Test various Unicode and encoding scenarios
    const unicode_tests = [_][]const u8{
        "const ñame = 42;", // Non-ASCII identifier
        "// Коммент на русском\nconst x = 1;", // Non-Latin comments
        "const emoji_🚀 = \"test\";", // Emoji in code
        "const 测试 = \"中文\";", // CJK characters
        "\xEF\xBB\xBF const bom_test = 1;", // BOM prefix
    };

    for (unicode_tests) |unicode_code| {
        const source_content = SourceContent{
            .content = unicode_code,
            .source_uri = "/fuzz/unicode.zig",
            .codebase_name = "unicode_test",
        };

        _ = parser.parse_to_semantic_units(source_content) catch {};
    }

    // Test with fuzz input interpreted as potentially invalid UTF-8
    const source_content = SourceContent{
        .content = input, // May not be valid UTF-8
        .source_uri = "/fuzz/encoding.zig",
        .codebase_name = "encoding_test",
    };

    _ = parser.parse_to_semantic_units(source_content) catch {};
}

/// Test with very large files that may cause memory issues
fn fuzz_large_files(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 100) return; // Need substantial input

    var sim_vfs = try SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = ArenaCoordinator.init(&arena);

    // Create large file by repeating input
    const large_content = try allocator.alloc(u8, input.len * 100); // 100x repetition
    defer allocator.free(large_content);

    for (0..100) |i| {
        const offset = i * input.len;
        @memcpy(large_content[offset .. offset + input.len], input);
    }

    var large_file = try sim_vfs.vfs().create("/large.zig");
    defer large_file.close();
    _ = try large_file.write(large_content);

    // Test ingestion of large file
    const large_file_content = internal.ingestion.ingest_file.FileContent{
        .data = large_content,
        .path = "/large.zig",
        .content_type = "text/zig",
        .metadata = std.StringHashMap([]const u8).init(allocator),
        .timestamp_ns = @intCast(std.time.nanoTimestamp()),
    };

    const large_parse_config = internal.ingestion.ingest_file.ParseConfig{};

    _ = internal.ingestion.ingest_file.parse_file_to_blocks(
        allocator,
        large_file_content,
        "large_test",
        large_parse_config,
    ) catch {};
}

/// Test edge cases in Zig syntax parsing
fn fuzz_edge_case_syntax(allocator: std.mem.Allocator, input: []const u8) !void {
    var parser = ZigParser.init(allocator, .{ .max_nesting_depth = 10 });

    // Generate edge case Zig syntax by combining input with problematic patterns
    const edge_patterns = [_][]const u8{
        // Unterminated constructs
        "fn incomplete(",
        "if (condition {",
        "struct Incomplete {",
        "const x = \"unterminated string",

        // Deeply nested structures
        "{{{{{{{{{{",
        "}}}}}}}}}",
        "((((((((((",
        "))))))))))",

        // Comment edge cases
        "//",
        "/*",
        "*/",
        "/* unclosed comment",
        "// comment with \x00 null",

        // String edge cases
        "\"\"\"\"\"\"",
        "\\\\\\\\\\\\",
        "\x00\x01\x02\x03",
    };

    for (edge_patterns) |pattern| {
        // Combine pattern with fuzz input
        const combined = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ pattern, input });
        defer allocator.free(combined);

        const source_content = SourceContent{
            .content = combined,
            .source_uri = "/fuzz/edge_case.zig",
            .codebase_name = "edge_case_test",
        };

        _ = parser.parse_to_semantic_units(source_content) catch {};
    }

    // Test input directly as potential edge case
    const source_content = SourceContent{
        .content = input,
        .source_uri = "/fuzz/direct_edge.zig",
        .codebase_name = "direct_edge_test",
    };

    _ = parser.parse_to_semantic_units(source_content) catch {};
}
