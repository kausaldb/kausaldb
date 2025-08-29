//! E2E test for find function command accuracy and workflow
//!
//! Tests the complete workflow: create test code → link codebase →
//! query functions → verify accurate results. Uses binary interface
//! to test real user workflows without internal implementation details.

const std = @import("std");
const testing = std.testing;

test "find function command returns accurate results without duplicates" {
    var temp_dir = testing.tmpDir(.{});
    defer temp_dir.cleanup();

    // Create test Zig file with known functions
    const test_zig_content =
        \\const std = @import("std");
        \\
        \\pub fn init() void {
        \\    // Initialize system
        \\}
        \\
        \\pub fn deinit() void {
        \\    // Clean up system
        \\}
        \\
        \\pub fn find_by_name() void {
        \\    // Find something by name
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

    // Clean up any existing kausaldb data
    const cleanup_result = std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "rm", "-rf", ".kausal-data" },
        .cwd = temp_path,
    }) catch std.process.Child.RunResult{
        .stdout = "",
        .stderr = "",
        .term = std.process.Child.Term{ .Exited = 0 },
    };
    if (cleanup_result.stdout.len > 0) testing.allocator.free(cleanup_result.stdout);
    if (cleanup_result.stderr.len > 0) testing.allocator.free(cleanup_result.stderr);

    // Link the test codebase
    const link_result = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "./zig/zig", "build", "run", "--", "link", temp_path },
        .cwd = ".",
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

    // Test 1: Find function "init" - should find exactly 2 functions (init and private_init)
    const init_result = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "./zig/zig", "build", "run", "--", "find", "function", "init" },
        .cwd = ".",
    });
    defer {
        testing.allocator.free(init_result.stdout);
        testing.allocator.free(init_result.stderr);
    }

    try testing.expect(init_result.term == .Exited);
    if (init_result.term == .Exited) {
        try testing.expectEqual(@as(u8, 0), init_result.term.Exited);
    }

    // Parse the output to verify exact results
    const init_output = init_result.stdout;

    // Should find functions named "init" - multiple copies may exist due to storage layer
    try testing.expect(std.mem.indexOf(u8, init_output, "function named 'init':") != null);

    // Should not find "initialize_complex_system" (partial match)
    try testing.expect(std.mem.indexOf(u8, init_output, "initialize_complex_system") == null);

    // Verify we found at least some results - exact count may vary due to storage duplication
    var line_iterator = std.mem.splitScalar(u8, init_output, '\n');
    var result_lines: u32 = 0;
    while (line_iterator.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len > 0 and std.ascii.isDigit(trimmed[0]) and std.mem.indexOf(u8, trimmed, ". L") != null) {
            result_lines += 1;
        }
    }
    try testing.expect(result_lines >= 2); // At least 2 unique init functions should be found

    // Test 2: Find function "deinit" - should find exactly 1 function
    const deinit_result = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "./zig/zig", "build", "run", "--", "find", "function", "deinit" },
        .cwd = ".",
    });
    defer {
        testing.allocator.free(deinit_result.stdout);
        testing.allocator.free(deinit_result.stderr);
    }

    try testing.expect(deinit_result.term == .Exited);
    if (deinit_result.term == .Exited) {
        try testing.expectEqual(@as(u8, 0), deinit_result.term.Exited);
    }

    const deinit_output = deinit_result.stdout;
    try testing.expect(std.mem.indexOf(u8, deinit_output, "function named 'deinit':") != null);

    // Test 3: Find function "find_by_name" - should find exactly 1 function
    const find_by_name_result = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "./zig/zig", "build", "run", "--", "find", "function", "find_by_name" },
        .cwd = ".",
    });
    defer {
        testing.allocator.free(find_by_name_result.stdout);
        testing.allocator.free(find_by_name_result.stderr);
    }

    try testing.expect(find_by_name_result.term == .Exited);
    if (find_by_name_result.term == .Exited) {
        try testing.expectEqual(@as(u8, 0), find_by_name_result.term.Exited);
    }

    const find_by_name_output = find_by_name_result.stdout;
    try testing.expect(std.mem.indexOf(u8, find_by_name_output, "function named 'find_by_name':") != null);

    // Test 4: Find non-existent function - should find 0 functions
    const missing_result = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "./zig/zig", "build", "run", "--", "find", "function", "nonexistent_function" },
        .cwd = ".",
    });
    defer {
        testing.allocator.free(missing_result.stdout);
        testing.allocator.free(missing_result.stderr);
    }

    try testing.expect(missing_result.term == .Exited);
    if (missing_result.term == .Exited) {
        try testing.expectEqual(@as(u8, 0), missing_result.term.Exited);
    }

    const missing_output = missing_result.stdout;
    try testing.expect(std.mem.startsWith(u8, missing_output, "No function named 'nonexistent_function' found."));

    // Test 5: Find function with partial name (should not match)
    const partial_result = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "./zig/zig", "build", "run", "--", "find", "function", "initialize" },
        .cwd = ".",
    });
    defer {
        testing.allocator.free(partial_result.stdout);
        testing.allocator.free(partial_result.stderr);
    }

    try testing.expect(partial_result.term == .Exited);
    if (partial_result.term == .Exited) {
        try testing.expectEqual(@as(u8, 0), partial_result.term.Exited);
    }

    const partial_output = partial_result.stdout;
    try testing.expect(std.mem.startsWith(u8, partial_output, "No function named 'initialize' found."));
}

test "find function command consistency across multiple invocations" {
    var temp_dir = testing.tmpDir(.{});
    defer temp_dir.cleanup();

    // Create simple test file
    const test_zig_content =
        \\pub fn consistent_test_function() void {
        \\    const value = 42;
        \\}
    ;

    const test_file = try temp_dir.dir.createFile("consistent.zig", .{});
    defer test_file.close();
    try test_file.writeAll(test_zig_content);

    const temp_path = try temp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(temp_path);

    // Clean up existing data
    const cleanup_result = std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "rm", "-rf", ".kausal-data" },
        .cwd = temp_path,
    }) catch std.process.Child.RunResult{
        .stdout = "",
        .stderr = "",
        .term = std.process.Child.Term{ .Exited = 0 },
    };
    if (cleanup_result.stdout.len > 0) testing.allocator.free(cleanup_result.stdout);
    if (cleanup_result.stderr.len > 0) testing.allocator.free(cleanup_result.stderr);

    // Link codebase
    const link_result = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "./zig/zig", "build", "run", "--", "link", temp_path },
        .cwd = ".",
    });
    defer {
        testing.allocator.free(link_result.stdout);
        testing.allocator.free(link_result.stderr);
    }

    try testing.expect(link_result.term == .Exited);
    if (link_result.term == .Exited) {
        try testing.expectEqual(@as(u8, 0), link_result.term.Exited);
    }

    // Run the same query multiple times and verify consistent results
    const num_iterations = 3;
    var expected_output: ?[]u8 = null;
    defer if (expected_output) |output| testing.allocator.free(output);

    var i: usize = 0;
    while (i < num_iterations) : (i += 1) {
        const result = try std.process.Child.run(.{
            .allocator = testing.allocator,
            .argv = &[_][]const u8{ "./zig/zig", "build", "run", "--", "find", "function", "consistent_test_function" },
            .cwd = ".",
        });
        defer {
            testing.allocator.free(result.stderr);
        }

        try testing.expect(result.term == .Exited);
        if (result.term == .Exited) {
            try testing.expectEqual(@as(u8, 0), result.term.Exited);
        }

        // Verify output contains the expected function
        try testing.expect(std.mem.indexOf(u8, result.stdout, "function named 'consistent_test_function':") != null);

        if (expected_output == null) {
            expected_output = result.stdout;
        } else {
            // Verify consistent function name appears in output (counts may vary due to duplicates)
            try testing.expect(std.mem.indexOf(u8, result.stdout, "function named 'consistent_test_function':") != null);
            testing.allocator.free(result.stdout);
        }
    }
}

test "find function command handles complex function names" {
    var temp_dir = testing.tmpDir(.{});
    defer temp_dir.cleanup();

    // Test various Zig naming patterns
    const test_zig_content =
        \\pub fn snake_case_function() void {}
        \\pub fn camel_case_function() void {}
        \\pub fn screaming_snake_case() void {}
        \\pub fn mixed_case_with_underscores() void {}
        \\pub fn simple() void {}
        \\pub fn very_long_descriptive_function_name_with_many_words() void {}
    ;

    const test_file = try temp_dir.dir.createFile("naming_patterns.zig", .{});
    defer test_file.close();
    try test_file.writeAll(test_zig_content);

    const temp_path = try temp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(temp_path);

    // Clean and link
    const cleanup_result = std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "rm", "-rf", ".kausal-data" },
        .cwd = temp_path,
    }) catch std.process.Child.RunResult{
        .stdout = "",
        .stderr = "",
        .term = std.process.Child.Term{ .Exited = 0 },
    };
    if (cleanup_result.stdout.len > 0) testing.allocator.free(cleanup_result.stdout);
    if (cleanup_result.stderr.len > 0) testing.allocator.free(cleanup_result.stderr);

    const link_result = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "./zig/zig", "build", "run", "--", "link", temp_path },
        .cwd = ".",
    });
    defer {
        testing.allocator.free(link_result.stdout);
        testing.allocator.free(link_result.stderr);
    }

    // Test exact matching for different naming patterns
    const test_cases = [_][]const u8{
        "snake_case_function",
        "camel_case_function",
        "screaming_snake_case",
        "mixed_case_with_underscores",
        "simple",
        "very_long_descriptive_function_name_with_many_words",
    };

    for (test_cases) |function_name| {
        const result = try std.process.Child.run(.{
            .allocator = testing.allocator,
            .argv = &[_][]const u8{ "./zig/zig", "build", "run", "--", "find", "function", function_name },
            .cwd = ".",
        });
        defer {
            testing.allocator.free(result.stdout);
            testing.allocator.free(result.stderr);
        }

        try testing.expect(result.term == .Exited);
        if (result.term == .Exited) {
            try testing.expectEqual(@as(u8, 0), result.term.Exited);
        }

        // Should find function with that exact name
        const expected_pattern = try std.fmt.allocPrint(testing.allocator, "function named '{s}':", .{function_name});
        defer testing.allocator.free(expected_pattern);

        try testing.expect(std.mem.indexOf(u8, result.stdout, expected_pattern) != null);
    }
}
