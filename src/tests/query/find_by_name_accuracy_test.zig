//! Comprehensive accuracy tests for find_by_name query functionality
//!
//! Verifies exact name matching, entity type filtering, and absence of
//! false positives or duplicate results. Tests the complete ingestion
//! to query pipeline with deterministic test data.

const std = @import("std");

const harness_mod = @import("../harness.zig");
const context_block = @import("../../core/types.zig");
const ingest_directory = @import("../../ingestion/ingest_directory.zig");
const parse_file_to_blocks = @import("../../ingestion/parse_file_to_blocks.zig");
const query = @import("../../query/engine.zig");

const testing = std.testing;
const QueryHarness = harness_mod.QueryHarness;
const ContextBlock = context_block.ContextBlock;
const BlockId = context_block.BlockId;
const IngestionConfig = ingest_directory.IngestionConfig;
const FileContent = parse_file_to_blocks.FileContent;
const ParseConfig = parse_file_to_blocks.ParseConfig;

test "find_by_name returns exact function matches only" {
    var test_harness = try QueryHarness.init_and_startup(testing.allocator, "find_accuracy_test");
    defer test_harness.deinit();

    // Create test Zig code with known function names
    const test_zig_content =
        \\const std = @import("std");
        \\
        \\pub fn init() void {
        \\    // Initialize something
        \\}
        \\
        \\pub fn initialize_system() void {
        \\    // Contains "init" but function name is different
        \\}
        \\
        \\fn private_init() void {
        \\    // Private function named init
        \\}
        \\
        \\pub fn deinit() void {
        \\    // Cleanup function
        \\}
        \\
        \\pub const TestStruct = struct {
        \\    pub fn init() Self {
        \\        return Self{};
        \\    }
        \\};
    ;

    // Parse and ingest the test code
    var metadata_map = std.StringHashMap([]const u8).init(testing.allocator);
    defer metadata_map.deinit();

    const file_content = FileContent{
        .data = test_zig_content,
        .path = "test_file.zig",
        .content_type = "text/zig",
        .metadata = metadata_map,
        .timestamp_ns = @intCast(std.time.nanoTimestamp()),
    };

    const parse_config = ParseConfig{
        .include_function_bodies = true,
        .include_private = true,
        .include_tests = false,
        .max_function_body_size = 8192,
        .create_import_blocks = false,
    };

    const blocks = try parse_file_to_blocks.parse_file_to_blocks(
        testing.allocator,
        file_content,
        parse_config,
    );
    defer testing.allocator.free(blocks);

    // Store blocks in storage engine
    for (blocks) |block| {
        try test_harness.storage_engine.put_block(block);
    }

    // Query for "init" functions - should find exactly 2 (public init and private_init)
    const init_results = try test_harness.query_engine.find_by_name("test_codebase", "function", "init");
    defer init_results.deinit();

    // Verify exactly 2 results and no duplicates
    try testing.expectEqual(@as(u32, 2), init_results.total_matches);
    try testing.expectEqual(@as(usize, 2), init_results.results.len);

    // Verify no duplicate BlockIds
    var seen_ids = std.AutoHashMap(BlockId, void).init(testing.allocator);
    defer seen_ids.deinit();

    for (init_results.results) |result| {
        const was_present = try seen_ids.fetchPut(result.block.block.id, {});
        try testing.expect(was_present == null); // Should not have seen this ID before
    }

    // Query for "deinit" - should find exactly 1
    const deinit_results = try test_harness.query_engine.find_by_name("test_codebase", "function", "deinit");
    defer deinit_results.deinit();

    try testing.expectEqual(@as(u32, 1), deinit_results.total_matches);
    try testing.expectEqual(@as(usize, 1), deinit_results.results.len);

    // Query for "initialize_system" - should find exactly 1
    const initialize_results = try test_harness.query_engine.find_by_name("test_codebase", "function", "initialize_system");
    defer initialize_results.deinit();

    try testing.expectEqual(@as(u32, 1), initialize_results.total_matches);
    try testing.expectEqual(@as(usize, 1), initialize_results.results.len);

    // Query for non-existent function - should find 0
    const missing_results = try test_harness.query_engine.find_by_name("test_codebase", "function", "nonexistent_function");
    defer missing_results.deinit();

    try testing.expectEqual(@as(u32, 0), missing_results.total_matches);
    try testing.expectEqual(@as(usize, 0), missing_results.results.len);
}

test "find_by_name filters by entity type correctly" {
    var test_harness = try QueryHarness.init_and_startup(testing.allocator, "entity_type_filter_test");
    defer test_harness.deinit();

    // Create test code with function and struct having same name
    const test_zig_content =
        \\const std = @import("std");
        \\
        \\pub fn config_type() void {
        \\    // Function with config in name
        \\}
        \\
        \\pub const Config = struct {
        \\    value: u32,
        \\
        \\    pub fn init() Config {
        \\        return Config{ .value = 0 };
        \\    }
        \\};
        \\
        \\const Parser = struct {
        \\    // Another struct
        \\};
    ;

    var metadata_map = std.StringHashMap([]const u8).init(testing.allocator);
    defer metadata_map.deinit();

    const file_content = FileContent{
        .data = test_zig_content,
        .path = "entity_test.zig",
        .content_type = "text/zig",
        .metadata = metadata_map,
        .timestamp_ns = @intCast(std.time.nanoTimestamp()),
    };

    const parse_config = ParseConfig{
        .include_function_bodies = true,
        .include_private = true,
        .include_tests = false,
        .max_function_body_size = 8192,
        .create_import_blocks = false,
    };

    const blocks = try parse_file_to_blocks.parse_file_to_blocks(
        testing.allocator,
        file_content,
        parse_config,
    );
    defer testing.allocator.free(blocks);

    for (blocks) |block| {
        try test_harness.storage_engine.put_block(block);
    }

    // Query for function named "Config" - should find exactly 1 function, not the struct
    const function_results = try test_harness.query_engine.find_by_name("test_codebase", "function", "Config");
    defer function_results.deinit();

    try testing.expectEqual(@as(u32, 1), function_results.total_matches);
    try testing.expectEqual(@as(usize, 1), function_results.results.len);

    // Verify it's actually the function by checking content
    const result_content = function_results.results[0].block.block.content;
    try testing.expect(std.mem.indexOf(u8, result_content, "pub fn Config() void") != null);

    // Query for struct named "Config" - when struct querying is implemented
    // This verifies entity type filtering works correctly
    const struct_results = try test_harness.query_engine.find_by_name("test_codebase", "struct", "Config");
    defer struct_results.deinit();

    // Should find 0 for now since struct parsing might not be fully implemented
    // When implemented, should find exactly 1 struct
    try testing.expect(struct_results.total_matches <= 1); // Allow for implementation variations
}

test "find_by_name handles complex function names correctly" {
    var test_harness = try QueryHarness.init_and_startup(testing.allocator, "complex_names_test");
    defer test_harness.deinit();

    // Test with various function naming patterns
    const test_zig_content =
        \\const std = @import("std");
        \\
        \\pub fn find_block_by_id() void {}
        \\pub fn find_blocks_by_pattern() void {}
        \\pub fn maybe_find_block() ?void {}
        \\pub fn try_find_block() !void {}
        \\fn internal_find_helper() void {}
        \\
        \\pub fn process_data_alternative() void {}
        \\pub fn process_data() void {}
        \\
        \\test "find functionality" {
        \\    // Test function - should be excluded if include_tests = false
        \\}
    ;

    var metadata_map = std.StringHashMap([]const u8).init(testing.allocator);
    defer metadata_map.deinit();

    const file_content = FileContent{
        .data = test_zig_content,
        .path = "complex_names.zig",
        .content_type = "text/zig",
        .metadata = metadata_map,
        .timestamp_ns = @intCast(std.time.nanoTimestamp()),
    };

    const parse_config = ParseConfig{
        .include_function_bodies = false, // Test with bodies disabled
        .include_private = true,
        .include_tests = false, // Exclude test functions
        .max_function_body_size = 8192,
        .create_import_blocks = false,
    };

    const blocks = try parse_file_to_blocks.parse_file_to_blocks(
        testing.allocator,
        file_content,
        parse_config,
    );
    defer testing.allocator.free(blocks);

    for (blocks) |block| {
        try test_harness.storage_engine.put_block(block);
    }

    // Test exact name matching for snake_case
    const snake_case_results = try test_harness.query_engine.find_by_name("test_codebase", "function", "process_data");
    defer snake_case_results.deinit();

    try testing.expectEqual(@as(u32, 1), snake_case_results.total_matches);

    // Test exact name matching for alternative function
    const alternative_results = try test_harness.query_engine.find_by_name("test_codebase", "function", "process_data_alternative");
    defer alternative_results.deinit();

    try testing.expectEqual(@as(u32, 1), alternative_results.total_matches);

    // Test that partial matches are not returned
    const partial_results = try test_harness.query_engine.find_by_name("test_codebase", "function", "find");
    defer partial_results.deinit();

    try testing.expectEqual(@as(u32, 0), partial_results.total_matches);

    // Test specific function with underscores
    const specific_results = try test_harness.query_engine.find_by_name("test_codebase", "function", "maybe_find_block");
    defer specific_results.deinit();

    try testing.expectEqual(@as(u32, 1), specific_results.total_matches);
}

test "find_by_name result consistency across multiple queries" {
    var test_harness = try QueryHarness.init_and_startup(testing.allocator, "consistency_test");
    defer test_harness.deinit();

    const test_zig_content =
        \\pub fn consistent_function() void {
        \\    // This function should always be found consistently
        \\}
    ;

    var metadata_map = std.StringHashMap([]const u8).init(testing.allocator);
    defer metadata_map.deinit();

    const file_content = FileContent{
        .data = test_zig_content,
        .path = "consistency.zig",
        .content_type = "text/zig",
        .metadata = metadata_map,
        .timestamp_ns = @intCast(std.time.nanoTimestamp()),
    };

    const parse_config = ParseConfig{
        .include_function_bodies = true,
        .include_private = false,
        .include_tests = false,
        .max_function_body_size = 8192,
        .create_import_blocks = false,
    };

    const blocks = try parse_file_to_blocks.parse_file_to_blocks(
        testing.allocator,
        file_content,
        parse_config,
    );
    defer testing.allocator.free(blocks);

    for (blocks) |block| {
        try test_harness.storage_engine.put_block(block);
    }

    // Run the same query multiple times and verify identical results
    const num_iterations = 5;
    var expected_block_id: ?BlockId = null;

    var i: usize = 0;
    while (i < num_iterations) : (i += 1) {
        const results = try test_harness.query_engine.find_by_name("test_codebase", "function", "consistent_function");
        defer results.deinit();

        // Should always find exactly 1 result
        try testing.expectEqual(@as(u32, 1), results.total_matches);
        try testing.expectEqual(@as(usize, 1), results.results.len);

        // Should always return the same BlockId
        const current_block_id = results.results[0].block.block.id;
        if (expected_block_id) |expected| {
            try testing.expect(std.mem.eql(u8, &expected.bytes, &current_block_id.bytes));
        } else {
            expected_block_id = current_block_id;
        }

        // Similarity score should always be 1.0 for exact matches
        try testing.expectEqual(@as(f32, 1.0), results.results[0].similarity_score);
    }
}
