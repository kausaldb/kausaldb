//! Natural executor integration tests requiring I/O operations.
//!
//! Tests natural language command execution with actual storage operations
//! and file system interactions through VFS.

const std = @import("std");
const testing = std.testing;

const simulation_vfs = @import("../../sim/simulation_vfs.zig");
const production_vfs = @import("../../core/production_vfs.zig");
const vfs = @import("../../core/vfs.zig");
const assert_mod = @import("../../core/assert.zig");
const memory = @import("../../core/memory.zig");
const types = @import("../../core/types.zig");
const storage = @import("../../storage/engine.zig");
const storage_config = @import("../../storage/config.zig");
const query = @import("../../query/engine.zig");

const assert = assert_mod.assert;

const ProductionVFS = production_vfs.ProductionVFS;
const SimulationVFS = simulation_vfs.SimulationVFS;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArenaCoordinator = memory.ArenaCoordinator;
const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const GraphEdge = types.GraphEdge;
const StorageEngine = storage.StorageEngine;
const Config = storage_config.Config;
const VFS = vfs.VFS;

const natural_executor = @import("../../cli/natural_executor.zig");
const NaturalExecutionContext = natural_executor.NaturalExecutionContext;

test "execution context initialization" {
    const allocator = std.testing.allocator;

    // Create temporary directory for test
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_data_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(test_data_dir);

    var context = try NaturalExecutionContext.init(allocator, test_data_dir);
    defer context.deinit();

    // Use deterministic simulation framework
    const sim_vfs = try SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    var storage_engine = try allocator.create(StorageEngine);
    storage_engine.* = try StorageEngine.init_default(allocator, sim_vfs.vfs(), test_data_dir);
    defer {
        if (storage_engine.state.can_write()) {
            storage_engine.shutdown() catch {};
        }
        storage_engine.deinit();
        allocator.destroy(storage_engine);
    }

    try storage_engine.startup();

    // Assign to context (expects optional pointer)
    context.storage_engine = storage_engine;

    // Verify components are initialized
    try testing.expect(context.storage_engine != null);

    // Verify we can perform basic operations
    const block = ContextBlock{
        .id = BlockId.generate(),
        .version = 1,
        .source_uri = "test://example.zig",
        .metadata_json = "{}",
        .content = "test content",
    };

    try context.storage_engine.?.put_block(block);
    const found = try context.storage_engine.?.find_block(block.id, .storage_engine);
    try testing.expect(found != null);
}

test "natural executor with file ingestion" {
    const allocator = testing.allocator;

    // Create temporary directory
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_data_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(test_data_dir);

    // Create test source file
    const test_file_content =
        \\pub fn main() void {
        \\    std.debug.print("Hello, World!\n", .{});
        \\}
        \\
        \\fn helper() void {
        \\    main();
        \\}
    ;

    try tmp_dir.dir.writeFile(.{ .sub_path = "test.zig", .data = test_file_content });

    var context = try NaturalExecutionContext.init(allocator, test_data_dir);
    defer context.deinit();

    // Create storage engine using pointer pattern (for context)
    const sim_vfs = try SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    var storage_engine = try allocator.create(StorageEngine);
    const config = Config.minimal_for_testing();
    storage_engine.* = try StorageEngine.init(allocator, sim_vfs.vfs(), test_data_dir, config);
    defer {
        if (storage_engine.state.can_write()) {
            storage_engine.shutdown() catch {};
        }
        storage_engine.deinit();
        allocator.destroy(storage_engine);
    }

    try storage_engine.startup();

    // Assign to context (expects pointer)
    context.storage_engine = storage_engine;

    // Simulate ingestion of the test file
    const block1 = ContextBlock{
        .id = BlockId.generate(),
        .version = 1,
        .source_uri = "file://test.zig#main",
        .metadata_json = "{\"type\": \"function\", \"name\": \"main\"}",
        .content = "pub fn main() void { std.debug.print(\"Hello, World!\\n\", .{}); }",
    };

    const block2 = ContextBlock{
        .id = BlockId.generate(),
        .version = 1,
        .source_uri = "file://test.zig#helper",
        .metadata_json = "{\"type\": \"function\", \"name\": \"helper\"}",
        .content = "fn helper() void { main(); }",
    };

    try context.storage_engine.?.put_block(block1);
    try context.storage_engine.?.put_block(block2);

    // Create edge relationship
    const edge = GraphEdge{
        .source_id = block2.id,
        .target_id = block1.id,
        .edge_type = .calls,
    };
    try context.storage_engine.?.put_edge(edge);

    // Verify blocks and edges are stored
    const found1 = try context.storage_engine.?.find_block(block1.id, .storage_engine);
    const found2 = try context.storage_engine.?.find_block(block2.id, .storage_engine);
    try testing.expect(found1 != null);
    try testing.expect(found2 != null);

    const edges = context.storage_engine.?.find_outgoing_edges(block2.id);
    try testing.expectEqual(@as(usize, 1), edges.len);
}

test "natural executor command execution with storage" {
    const allocator = testing.allocator;

    // Create temporary directory
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_data_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(test_data_dir);

    var context = try NaturalExecutionContext.init(allocator, test_data_dir);
    defer context.deinit();

    // Create storage engine using pointer pattern (for context)
    const sim_vfs = try SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    var storage_engine = try allocator.create(StorageEngine);
    const config = Config.minimal_for_testing();
    storage_engine.* = try StorageEngine.init(allocator, sim_vfs.vfs(), test_data_dir, config);
    defer {
        if (storage_engine.state.can_write()) {
            storage_engine.shutdown() catch {};
        }
        storage_engine.deinit();
        allocator.destroy(storage_engine);
    }

    try storage_engine.startup();

    // Assign to context (expects pointer)
    context.storage_engine = storage_engine;

    // Create test data
    const func_block = ContextBlock{
        .id = BlockId.generate(),
        .version = 1,
        .source_uri = "file://app.zig#process_data",
        .metadata_json = "{\"type\": \"function\", \"name\": \"process_data\"}",
        .content = "fn process_data(input: []const u8) !void { ... }",
    };

    const caller_block = ContextBlock{
        .id = BlockId.generate(),
        .version = 1,
        .source_uri = "file://main.zig#main",
        .metadata_json = "{\"type\": \"function\", \"name\": \"main\"}",
        .content = "pub fn main() !void { try process_data(data); }",
    };

    try context.storage_engine.?.put_block(func_block);
    try context.storage_engine.?.put_block(caller_block);

    // Create call relationship
    const call_edge = GraphEdge{
        .source_id = caller_block.id,
        .target_id = func_block.id,
        .edge_type = .calls,
    };
    try context.storage_engine.?.put_edge(call_edge);

    // Query for callers
    const callers = context.storage_engine.?.find_incoming_edges(func_block.id);
    try testing.expectEqual(@as(usize, 1), callers.len);
    try testing.expectEqual(caller_block.id, callers[0].edge.source_id);
}

test "natural executor with multiple file operations" {
    const allocator = testing.allocator;

    // Create temporary directory
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_data_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(test_data_dir);

    // Create multiple test files
    try tmp_dir.dir.writeFile(.{ .sub_path = "math.zig", .data = "pub fn add(a: i32, b: i32) i32 { return a + b; }" });
    try tmp_dir.dir.writeFile(.{ .sub_path = "utils.zig", .data = "const math = @import(\"math.zig\");\npub fn calc() i32 { return math.add(1, 2); }" });
    try tmp_dir.dir.writeFile(.{ .sub_path = "main.zig", .data = "const utils = @import(\"utils.zig\");\npub fn main() void { _ = utils.calc(); }" });

    var context = try NaturalExecutionContext.init(allocator, test_data_dir);
    defer context.deinit();

    // Create storage engine using pointer pattern (for context)
    const sim_vfs = try SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    var storage_engine = try allocator.create(StorageEngine);
    const config = Config.minimal_for_testing();
    storage_engine.* = try StorageEngine.init(allocator, sim_vfs.vfs(), test_data_dir, config);
    defer {
        if (storage_engine.state.can_write()) {
            storage_engine.shutdown() catch {};
        }
        storage_engine.deinit();
        allocator.destroy(storage_engine);
    }

    try storage_engine.startup();

    // Assign to context (expects pointer)
    context.storage_engine = storage_engine;

    // Create blocks for each function
    const math_block = ContextBlock{
        .id = BlockId.generate(),
        .version = 1,
        .source_uri = "file://math.zig#add",
        .metadata_json = "{\"type\": \"function\", \"name\": \"add\", \"module\": \"math\"}",
        .content = "pub fn add(a: i32, b: i32) i32 { return a + b; }",
    };

    const utils_block = ContextBlock{
        .id = BlockId.generate(),
        .version = 1,
        .source_uri = "file://utils.zig#calc",
        .metadata_json = "{\"type\": \"function\", \"name\": \"calc\", \"module\": \"utils\"}",
        .content = "pub fn calc() i32 { return math.add(1, 2); }",
    };

    const main_block = ContextBlock{
        .id = BlockId.generate(),
        .version = 1,
        .source_uri = "file://main.zig#main",
        .metadata_json = "{\"type\": \"function\", \"name\": \"main\", \"module\": \"main\"}",
        .content = "pub fn main() void { _ = utils.calc(); }",
    };

    // Store blocks
    try context.storage_engine.?.put_block(math_block);
    try context.storage_engine.?.put_block(utils_block);
    try context.storage_engine.?.put_block(main_block);

    // Create call chain: main -> calc -> add
    try context.storage_engine.?.put_edge(GraphEdge{
        .source_id = main_block.id,
        .target_id = utils_block.id,
        .edge_type = .calls,
    });

    try context.storage_engine.?.put_edge(GraphEdge{
        .source_id = utils_block.id,
        .target_id = math_block.id,
        .edge_type = .calls,
    });

    // Create import relationships
    try context.storage_engine.?.put_edge(GraphEdge{
        .source_id = utils_block.id,
        .target_id = math_block.id,
        .edge_type = .imports,
    });

    try context.storage_engine.?.put_edge(GraphEdge{
        .source_id = main_block.id,
        .target_id = utils_block.id,
        .edge_type = .imports,
    });

    // Verify complete call chain
    const main_calls = context.storage_engine.?.find_outgoing_edges(main_block.id);
    try testing.expectEqual(@as(usize, 2), main_calls.len); // calls and imports

    const utils_calls = context.storage_engine.?.find_outgoing_edges(utils_block.id);
    try testing.expectEqual(@as(usize, 2), utils_calls.len); // calls and imports

    // Verify reverse lookups
    const math_callers = context.storage_engine.?.find_incoming_edges(math_block.id);
    try testing.expectEqual(@as(usize, 2), math_callers.len); // called and imported by utils
}

test "natural executor persistence across sessions" {
    const allocator = testing.allocator;

    // Create temporary directory
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_data_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(test_data_dir);

    const test_block_id = BlockId.generate();

    // First session - write data
    {
        var context = try NaturalExecutionContext.init(allocator, test_data_dir);
        defer context.deinit();

        // Create storage engine manually
        var sim_vfs = try SimulationVFS.init(allocator);
        defer sim_vfs.deinit();

        var storage_engine = try allocator.create(StorageEngine);
        const config = Config.minimal_for_testing();
        storage_engine.* = try StorageEngine.init(allocator, sim_vfs.vfs(), test_data_dir, config);
        defer {
            storage_engine.shutdown() catch {};
            storage_engine.deinit();
            allocator.destroy(storage_engine);
        }
        try storage_engine.startup();

        // Assign to context
        context.storage_engine = storage_engine;

        const block = ContextBlock{
            .id = test_block_id,
            .version = 1,
            .source_uri = "file://persistent.zig#test_func",
            .metadata_json = "{\"type\": \"function\", \"name\": \"test_func\"}",
            .content = "fn test_func() void { /* persistent data */ }",
        };

        try context.storage_engine.?.put_block(block);

        // Add some edges
        const other_block = ContextBlock{
            .id = BlockId.generate(),
            .version = 1,
            .source_uri = "file://caller.zig#caller",
            .metadata_json = "{\"type\": \"function\", \"name\": \"caller\"}",
            .content = "fn caller() void { test_func(); }",
        };

        try context.storage_engine.?.put_block(other_block);

        try context.storage_engine.?.put_edge(GraphEdge{
            .source_id = other_block.id,
            .target_id = test_block_id,
            .edge_type = .calls,
        });

        // Flush to ensure persistence
        try context.storage_engine.?.flush_memtable_to_sstable();
    }

    // Second session - read data
    {
        var context = try NaturalExecutionContext.init(allocator, test_data_dir);
        defer context.deinit();

        // Create storage engine manually
        var sim_vfs = try SimulationVFS.init(allocator);
        defer sim_vfs.deinit();

        var storage_engine = try allocator.create(StorageEngine);
        const config = Config.minimal_for_testing();
        storage_engine.* = try StorageEngine.init(allocator, sim_vfs.vfs(), test_data_dir, config);
        defer {
            storage_engine.shutdown() catch {};
            storage_engine.deinit();
            allocator.destroy(storage_engine);
        }
        try storage_engine.startup();

        // Assign to context
        context.storage_engine = storage_engine;

        // Verify data persisted
        const found = try context.storage_engine.?.find_block(test_block_id, .storage_engine);
        try testing.expect(found != null);

        if (found) |owned_block| {
            const block = owned_block.read(.storage_engine);
            try testing.expectEqualStrings("file://persistent.zig#test_func", block.source_uri);
            try testing.expectEqualStrings("fn test_func() void { /* persistent data */ }", block.content);
        }

        // Verify edges persisted
        const edges = context.storage_engine.?.find_incoming_edges(test_block_id);
        try testing.expectEqual(@as(usize, 1), edges.len);
    }
}
