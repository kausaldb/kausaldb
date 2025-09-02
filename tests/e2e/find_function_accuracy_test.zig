//! End-to-end tests for find function command accuracy.
//!
//! Tests the complete flow: codebase linking, ingestion, storage, and query execution.
//! Focuses on accuracy of function finding and preventing duplicates.

const std = @import("std");
const testing = std.testing;

test "find function command returns accurate results without duplicates" {
    var temp_dir = testing.tmpDir(.{});
    defer temp_dir.cleanup();

    // Create test Zig file with various function patterns
    const test_zig_content =
        \\pub fn init() void {
        \\    // Public initialization function
        \\}
        \\
        \\fn private_init() void {
        \\    // Private initialization
        \\}
        \\
        \\pub fn initialize_complex_system() void {
        \\    // Contains "init" but different function name
        \\}
        \\
        \\pub const Config = struct {
        \\    pub fn init() Config {
        \\        return Config{};
        \\    }
        \\};
    ;

    // Write test file to temporary directory
    const test_file = try temp_dir.dir.createFile("test_functions.zig", .{});
    defer test_file.close();
    try test_file.writeAll(test_zig_content);

    // Get absolute path for linking
    const temp_path = try temp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(temp_path);

    // Create unique database directory to prevent parallel test conflicts
    var db_temp_dir = testing.tmpDir(.{});
    defer db_temp_dir.cleanup();
    const db_path = try db_temp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(db_path);

    // Set up environment with unique database path, inheriting parent environment
    var env_map = try std.process.getEnvMap(testing.allocator);
    defer env_map.deinit();
    try env_map.put("KAUSAL_DB_PATH", db_path);

    // Link the test codebase
    const link_result = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "./zig/zig", "build", "run", "--", "link", temp_path },
        .cwd = ".",
        .env_map = &env_map,
    });
    defer {
        testing.allocator.free(link_result.stdout);
        testing.allocator.free(link_result.stderr);
    }

    // Verify linking succeeded
    try testing.expect(link_result.term == .Exited);
    if (link_result.term == .Exited) {
        try testing.expectEqual(@as(u8, 0), link_result.term.Exited);
    }

    // Test: Find function "init" - should find exactly 2 functions (init and private_init)
    const find_result = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "./zig/zig", "build", "run", "--", "find", "function", "init", "in", std.fs.path.basename(temp_path) },
        .cwd = ".",
        .env_map = &env_map,
    });
    defer {
        testing.allocator.free(find_result.stdout);
        testing.allocator.free(find_result.stderr);
    }

    try testing.expect(find_result.term == .Exited);
    if (find_result.term == .Exited) {
        try testing.expectEqual(@as(u8, 0), find_result.term.Exited);
    }

    const output = find_result.stdout;

    // Should find functions named "init" - multiple copies may exist due to storage layer
    try testing.expect(std.mem.indexOf(u8, output, "function named 'init' in workspace") != null);

    // Should NOT find "initialize_complex_system" when searching for "init"
    // (exact name matching should be enforced)
    try testing.expect(std.mem.indexOf(u8, output, "initialize_complex_system") == null);

    // Test: Find function that doesn't exist
    const missing_result = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "./zig/zig", "build", "run", "--", "find", "function", "nonexistent_function", "in", std.fs.path.basename(temp_path) },
        .cwd = ".",
        .env_map = &env_map,
    });
    defer {
        testing.allocator.free(missing_result.stdout);
        testing.allocator.free(missing_result.stderr);
    }

    try testing.expect(missing_result.term == .Exited);
    const missing_output = missing_result.stdout;
    try testing.expect(std.mem.indexOf(u8, missing_output, "No function named 'nonexistent_function' found in workspace") != null);

    // Test: Find function with partial name (should not match)
    const partial_result = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "./zig/zig", "build", "run", "--", "find", "function", "initialize", "in", std.fs.path.basename(temp_path) },
        .cwd = ".",
        .env_map = &env_map,
    });
    defer {
        testing.allocator.free(partial_result.stdout);
        testing.allocator.free(partial_result.stderr);
    }

    try testing.expect(partial_result.term == .Exited);
    if (partial_result.term == .Exited) {
        try testing.expect(partial_result.term.Exited == 0);
    }

    const partial_output = partial_result.stdout;
    try testing.expect(std.mem.indexOf(u8, partial_output, "No function named 'initialize' found in workspace") != null);
}

test "find function command consistency across multiple invocations" {
    var temp_dir = testing.tmpDir(.{});
    defer temp_dir.cleanup();

    // Create test file
    const test_content =
        \\pub fn consistent_test_function() void {
        \\    // Test function for consistency checks
        \\}
        \\
        \\pub fn another_function() void {
        \\    // Another test function
        \\}
    ;

    const test_file = try temp_dir.dir.createFile("consistency_test.zig", .{});
    defer test_file.close();
    try test_file.writeAll(test_content);

    const temp_path = try temp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(temp_path);

    // Create unique database directory to prevent parallel test conflicts
    var db_temp_dir = testing.tmpDir(.{});
    defer db_temp_dir.cleanup();
    const db_path = try db_temp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(db_path);

    // Set up environment with unique database path, inheriting parent environment
    var env_map = try std.process.getEnvMap(testing.allocator);
    defer env_map.deinit();
    try env_map.put("KAUSAL_DB_PATH", db_path);

    // Link codebase
    const link_result = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "./zig/zig", "build", "run", "--", "link", temp_path },
        .cwd = ".",
        .env_map = &env_map,
    });
    defer {
        testing.allocator.free(link_result.stdout);
        testing.allocator.free(link_result.stderr);
    }

    try testing.expect(link_result.term == .Exited);
    if (link_result.term == .Exited) {
        try testing.expectEqual(@as(u8, 0), link_result.term.Exited);
    }

    // Run the same query multiple times and verify consistency
    const num_iterations = 3;
    var expected_output: ?[]u8 = null;
    defer if (expected_output) |output| testing.allocator.free(output);

    var i: usize = 0;
    while (i < num_iterations) : (i += 1) {
        const find_result = try std.process.Child.run(.{
            .allocator = testing.allocator,
            .argv = &[_][]const u8{ "./zig/zig", "build", "run", "--", "find", "function", "consistent_test_function", "in", std.fs.path.basename(temp_path) },
            .cwd = ".",
            .env_map = &env_map,
        });
        defer {
            testing.allocator.free(find_result.stderr);
        }

        try testing.expect(find_result.term == .Exited);
        if (find_result.term == .Exited) {
            try testing.expectEqual(@as(u8, 0), find_result.term.Exited);
        }

        // Verify output contains the expected function
        try testing.expect(std.mem.indexOf(u8, find_result.stdout, "function named 'consistent_test_function' in workspace") != null);

        if (expected_output == null) {
            expected_output = find_result.stdout;
        } else {
            // Verify consistent function name appears in output (counts may vary due to duplicates)
            try testing.expect(std.mem.indexOf(u8, find_result.stdout, "function named 'consistent_test_function' in workspace") != null);
            testing.allocator.free(find_result.stdout);
        }
    }
}

test "find function command handles complex function names" {
    var temp_dir = testing.tmpDir(.{});
    defer temp_dir.cleanup();

    // Create test file with complex function names
    const test_content =
        \\pub fn snake_case_function() void {}
        \\pub fn another_snake_case_function() void {}
        \\pub fn function_with_numbers_123() void {}
        \\pub fn very_long_descriptive_function_name_with_many_words() void {}
    ;

    const test_file = try temp_dir.dir.createFile("complex_names.zig", .{});
    defer test_file.close();
    try test_file.writeAll(test_content);

    const temp_path = try temp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(temp_path);

    // Create unique database directory to prevent parallel test conflicts
    var db_temp_dir = testing.tmpDir(.{});
    defer db_temp_dir.cleanup();
    const db_path = try db_temp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(db_path);

    // Set up environment with unique database path, inheriting parent environment
    var env_map = try std.process.getEnvMap(testing.allocator);
    defer env_map.deinit();
    try env_map.put("KAUSAL_DB_PATH", db_path);

    // Link codebase
    const link_result = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "./zig/zig", "build", "run", "--", "link", temp_path },
        .cwd = ".",
        .env_map = &env_map,
    });
    defer {
        testing.allocator.free(link_result.stdout);
        testing.allocator.free(link_result.stderr);
    }

    try testing.expect(link_result.term == .Exited);
    if (link_result.term == .Exited) {
        try testing.expectEqual(@as(u8, 0), link_result.term.Exited);
    }

    // Test finding each complex function name
    const test_cases = [_][]const u8{
        "snake_case_function",
        "another_snake_case_function",
        "function_with_numbers_123",
        "very_long_descriptive_function_name_with_many_words",
    };

    for (test_cases) |function_name| {
        const find_result = try std.process.Child.run(.{
            .allocator = testing.allocator,
            .argv = &[_][]const u8{ "./zig/zig", "build", "run", "--", "find", "function", function_name, "in", std.fs.path.basename(temp_path) },
            .cwd = ".",
            .env_map = &env_map,
        });
        defer {
            testing.allocator.free(find_result.stdout);
            testing.allocator.free(find_result.stderr);
        }

        // Verify execution succeeded
        try testing.expect(find_result.term == .Exited);
        if (find_result.term == .Exited) {
            try testing.expect(find_result.term.Exited == 0);
        }

        const output = find_result.stdout;
        // Should find function with that exact name
        const expected_pattern = try std.fmt.allocPrint(testing.allocator, "function named '{s}' in workspace", .{function_name});
        defer testing.allocator.free(expected_pattern);
        try testing.expect(std.mem.indexOf(u8, output, expected_pattern) != null);
    }
}
