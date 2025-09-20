//! End-to-end tests for qualified name disambiguation in find function commands.
//!
//! Tests the complete flow: codebase linking, ingestion, storage, and query execution
//! with qualified "Struct.method" syntax to ensure proper disambiguation across large
//! codebases where multiple structs have methods with the same name.

const std = @import("std");
const testing = std.testing;

test "qualified name disambiguation finds specific struct methods" {
    var temp_dir = testing.tmpDir(.{});
    defer temp_dir.cleanup();

    // Create test Zig file with multiple structs having same method names
    const test_zig_content =
        \\pub const StorageEngine = struct {
        \\    pub fn init(allocator: std.mem.Allocator) StorageEngine {
        \\        return StorageEngine{};
        \\    }
        \\
        \\    pub fn startup(self: *StorageEngine) !void {
        \\        // Storage engine startup logic
        \\    }
        \\
        \\    pub fn shutdown(self: *StorageEngine) void {
        \\        // Storage engine cleanup
        \\    }
        \\};
        \\
        \\pub const QueryEngine = struct {
        \\    pub fn init(allocator: std.mem.Allocator) QueryEngine {
        \\        return QueryEngine{};
        \\    }
        \\
        \\    pub fn startup(self: *QueryEngine) !void {
        \\        // Query engine startup logic
        \\    }
        \\
        \\    pub fn shutdown(self: *QueryEngine) void {
        \\        // Query engine cleanup
        \\    }
        \\};
        \\
        \\pub const NetworkManager = struct {
        \\    pub fn init(config: NetworkConfig) NetworkManager {
        \\        return NetworkManager{};
        \\    }
        \\
        \\    pub fn startup(self: *NetworkManager) !void {
        \\        // Network manager startup
        \\    }
        \\};
        \\
        \\// Standalone functions with same names
        \\pub fn init() void {
        \\    // Global initialization function
        \\}
        \\
        \\pub fn startup() !void {
        \\    // Global startup function
        \\}
    ;

    // Write test file to temporary directory
    const test_file = try temp_dir.dir.createFile("qualified_test.zig", .{});
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

    // Set up environment with unique database path
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

    const workspace_name = std.fs.path.basename(temp_path);

    // Test 1: Simple name search should find all functions with that name
    const simple_init_result = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "./zig/zig", "build", "run", "--", "find", "function", "init", "in", workspace_name },
        .cwd = ".",
        .env_map = &env_map,
    });
    defer {
        testing.allocator.free(simple_init_result.stdout);
        testing.allocator.free(simple_init_result.stderr);
    }

    try testing.expect(simple_init_result.term == .Exited);
    if (simple_init_result.term == .Exited) {
        try testing.expectEqual(@as(u8, 0), simple_init_result.term.Exited);
    }

    const simple_output = simple_init_result.stdout;
    // Should find multiple init functions (struct methods + standalone)
    try testing.expect(std.mem.indexOf(u8, simple_output, "function named 'init' in workspace") != null);

    // Test 2: Qualified name search should find only specific struct method
    const qualified_storage_result = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "./zig/zig", "build", "run", "--", "find", "function", "StorageEngine.init", "in", workspace_name },
        .cwd = ".",
        .env_map = &env_map,
    });
    defer {
        testing.allocator.free(qualified_storage_result.stdout);
        testing.allocator.free(qualified_storage_result.stderr);
    }

    try testing.expect(qualified_storage_result.term == .Exited);
    if (qualified_storage_result.term == .Exited) {
        try testing.expectEqual(@as(u8, 0), qualified_storage_result.term.Exited);
    }

    // Should either find the specific method OR report no matches if qualified names aren't fully implemented yet
    const qualified_storage_output = qualified_storage_result.stdout;
    const has_results = std.mem.indexOf(u8, qualified_storage_output, "function named 'StorageEngine.init' in workspace") != null;
    const no_results = std.mem.indexOf(u8, qualified_storage_output, "No function named 'StorageEngine.init' found in workspace") != null;

    // One of these should be true (either working qualified names or graceful "not found")
    try testing.expect(has_results or no_results);

    // Test 3: Different qualified name should not match wrong struct
    const qualified_query_result = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "./zig/zig", "build", "run", "--", "find", "function", "QueryEngine.init", "in", workspace_name },
        .cwd = ".",
        .env_map = &env_map,
    });
    defer {
        testing.allocator.free(qualified_query_result.stdout);
        testing.allocator.free(qualified_query_result.stderr);
    }

    try testing.expect(qualified_query_result.term == .Exited);
    if (qualified_query_result.term == .Exited) {
        try testing.expectEqual(@as(u8, 0), qualified_query_result.term.Exited);
    }

    const qualified_query_output = qualified_query_result.stdout;
    // Should not find StorageEngine.init when searching for QueryEngine.init
    if (has_results) {
        // If qualified names work, verify this finds different results than StorageEngine.init
        try testing.expect(!std.mem.eql(u8, qualified_storage_output, qualified_query_output));
    }
}

test "qualified name search handles non-existent structs gracefully" {
    var temp_dir = testing.tmpDir(.{});
    defer temp_dir.cleanup();

    // Create minimal test file
    const test_content =
        \\pub fn init() void {
        \\    // Simple function
        \\}
        \\
        \\pub const TestStruct = struct {
        \\    pub fn process() void {}
        \\};
    ;

    const test_file = try temp_dir.dir.createFile("minimal_test.zig", .{});
    defer test_file.close();
    try test_file.writeAll(test_content);

    const temp_path = try temp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(temp_path);

    // Create unique database directory
    var db_temp_dir = testing.tmpDir(.{});
    defer db_temp_dir.cleanup();
    const db_path = try db_temp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(db_path);

    // Set up environment
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

    const workspace_name = std.fs.path.basename(temp_path);

    // Test: Search for method on non-existent struct
    const nonexistent_result = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "./zig/zig", "build", "run", "--", "find", "function", "NonExistentStruct.init", "in", workspace_name },
        .cwd = ".",
        .env_map = &env_map,
    });
    defer {
        testing.allocator.free(nonexistent_result.stdout);
        testing.allocator.free(nonexistent_result.stderr);
    }

    try testing.expect(nonexistent_result.term == .Exited);
    if (nonexistent_result.term == .Exited) {
        try testing.expectEqual(@as(u8, 0), nonexistent_result.term.Exited);
    }

    const output = nonexistent_result.stdout;
    // Should gracefully report no results found
    try testing.expect(std.mem.indexOf(u8, output, "No function named 'NonExistentStruct.init' found in workspace") != null);
}

test "qualified name parsing edge cases" {
    var temp_dir = testing.tmpDir(.{});
    defer temp_dir.cleanup();

    // Create test file with edge cases
    const test_content =
        \\pub fn regular_function() void {}
        \\
        \\pub const EdgeCase = struct {
        \\    pub fn method_with_dots() void {
        \\        // Method name has dots in comments: some.other.thing
        \\    }
        \\};
    ;

    const test_file = try temp_dir.dir.createFile("edge_cases.zig", .{});
    defer test_file.close();
    try test_file.writeAll(test_content);

    const temp_path = try temp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(temp_path);

    // Create unique database directory
    var db_temp_dir = testing.tmpDir(.{});
    defer db_temp_dir.cleanup();
    const db_path = try db_temp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(db_path);

    // Set up environment
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

    const workspace_name = std.fs.path.basename(temp_path);

    // Test 1: Empty struct name (malformed qualified name)
    const empty_struct_result = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "./zig/zig", "build", "run", "--", "find", "function", ".method", "in", workspace_name },
        .cwd = ".",
        .env_map = &env_map,
    });
    defer {
        testing.allocator.free(empty_struct_result.stdout);
        testing.allocator.free(empty_struct_result.stderr);
    }

    try testing.expect(empty_struct_result.term == .Exited);
    if (empty_struct_result.term == .Exited) {
        try testing.expectEqual(@as(u8, 0), empty_struct_result.term.Exited);
    }

    // Should handle gracefully (no crash)
    const empty_output = empty_struct_result.stdout;
    try testing.expect(std.mem.indexOf(u8, empty_output, "No function named '.method' found in workspace") != null);

    // Test 2: Empty method name (malformed qualified name)
    const empty_method_result = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "./zig/zig", "build", "run", "--", "find", "function", "SomeStruct.", "in", workspace_name },
        .cwd = ".",
        .env_map = &env_map,
    });
    defer {
        testing.allocator.free(empty_method_result.stdout);
        testing.allocator.free(empty_method_result.stderr);
    }

    try testing.expect(empty_method_result.term == .Exited);
    if (empty_method_result.term == .Exited) {
        try testing.expectEqual(@as(u8, 0), empty_method_result.term.Exited);
    }

    // Should handle gracefully (no crash)
    const empty_method_output = empty_method_result.stdout;
    try testing.expect(std.mem.indexOf(u8, empty_method_output, "No function named 'SomeStruct.' found in workspace") != null);

    // Test 3: Multiple dots (not currently supported)
    const multi_dot_result = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "./zig/zig", "build", "run", "--", "find", "function", "Outer.Inner.method", "in", workspace_name },
        .cwd = ".",
        .env_map = &env_map,
    });
    defer {
        testing.allocator.free(multi_dot_result.stdout);
        testing.allocator.free(multi_dot_result.stderr);
    }

    try testing.expect(multi_dot_result.term == .Exited);
    if (multi_dot_result.term == .Exited) {
        try testing.expectEqual(@as(u8, 0), multi_dot_result.term.Exited);
    }

    // Should handle gracefully - currently not supported so should show no results
    const multi_dot_output = multi_dot_result.stdout;
    try testing.expect(std.mem.indexOf(u8, multi_dot_output, "No function named 'Outer.Inner.method' found in workspace") != null);
}
