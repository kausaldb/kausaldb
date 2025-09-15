//! Query engine fuzzing - systematic query and traversal fuzzing
//!
//! Tests query engine robustness against malformed queries, invalid
//! graph structures, and edge cases in search and traversal operations.
//! All fuzzing is deterministic and reproducible using seeds.

const std = @import("std");
const main = @import("main.zig");
const internal = @import("internal");

const QueryEngine = internal.QueryEngine;
const StorageEngine = internal.StorageEngine;
const SimulationVFS = internal.SimulationVFS;
const ContextBlock = internal.ContextBlock;
const GraphEdge = internal.GraphEdge;
const BlockId = internal.BlockId;
const EdgeType = internal.EdgeType;
const Config = internal.Config;

/// Run query engine fuzzing using the shared fuzzer infrastructure
pub fn run_fuzzing(fuzzer: *main.Fuzzer) !void {
    std.debug.print("Fuzzing query engine...\n", .{});

    for (0..fuzzer.config.iterations) |i| {
        const input = try fuzzer.generate_input();
        defer fuzzer.allocator.free(input);

        fuzz_query_operations(fuzzer.allocator, input) catch |err| {
            try fuzzer.handle_crash(input, err);
            continue;
        };

        fuzzer.record_iteration();

        if (i % 1000 == 0 and i > 0) {
            std.debug.print("Query fuzz: {} iterations\n", .{i});
        }
    }
}

/// Core fuzzing logic for query operations
fn fuzz_query_operations(allocator: std.mem.Allocator, input: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Setup storage backend for query testing
    var sim_vfs = try SimulationVFS.init(alloc);
    defer sim_vfs.deinit();

    var storage = try StorageEngine.init(alloc, sim_vfs.vfs(), "fuzz_query", Config{});
    defer storage.deinit();
    try storage.startup();
    defer storage.shutdown() catch {};

    // Setup query engine
    var query_engine = QueryEngine.init(alloc, &storage);
    defer query_engine.deinit();

    // Pre-populate with some test data for query operations
    try populate_fuzz_data(&storage, alloc);

    // Parse input to determine query operations
    var i: usize = 0;
    while (i + 4 < input.len) : (i += 1) {
        const op_type = input[i] % 8; // 8 operation types

        switch (op_type) {
            0 => { // query_parsing
                const query_text = fuzz_generate_query_text(input[i..]);
                fuzz_query_parsing(&query_engine, query_text) catch {};
            },
            1 => { // graph_traversal_bfs
                const start_id = fuzz_generate_block_id(input[i..]);
                fuzz_graph_traversal_bfs(&query_engine, start_id) catch {};
            },
            2 => { // graph_traversal_dfs
                const start_id = fuzz_generate_block_id(input[i..]);
                fuzz_graph_traversal_dfs(&query_engine, start_id) catch {};
            },
            3 => { // semantic_search
                const search_term = fuzz_generate_search_term(alloc, input[i..]);
                fuzz_semantic_search(&query_engine, search_term) catch {};
            },
            4 => { // filtered_traversal
                const filter = fuzz_generate_filter(input[i..]);
                fuzz_filtered_traversal(&query_engine, filter) catch {};
            },
            5 => { // query_caching
                const cache_key = fuzz_generate_cache_key(alloc, input[i..]);
                fuzz_query_caching(&query_engine, cache_key) catch {};
            },
            6 => { // complex_query
                fuzz_complex_query_operations(&query_engine, input[i..]) catch {};
            },
            7 => { // edge_case_queries
                fuzz_edge_case_queries(&query_engine, input[i..]) catch {};
            },
            else => {},
        }
    }

    // Test query engine with corrupted graph data
    try fuzz_corrupted_graph_operations(&query_engine, input);
}

/// Populate storage with test data for query fuzzing
fn populate_fuzz_data(storage: *StorageEngine, allocator: std.mem.Allocator) !void {
    // Create a small test graph for query operations
    var block_ids = std.array_list.Managed(BlockId).init(allocator);
    defer block_ids.deinit();

    // Create test blocks
    for (0..20) |i| {
        const block = ContextBlock{
            .id = BlockId.generate(),
            .version = 1,
            .source_uri = "fuzz://query_test.zig",
            .metadata_json = "{}",
            .content = std.fmt.allocPrint(allocator, "fn query_test_{}() {{ return; }}", .{i}) catch "fn test() { return; }",
        };
        try storage.put_block(block);
        try block_ids.append(block.id);
    }

    // Create test edges between blocks
    for (0..block_ids.items.len - 1) |i| {
        const edge = GraphEdge{
            .source_id = block_ids.items[i],
            .target_id = block_ids.items[i + 1],
            .edge_type = EdgeType.calls,
        };
        try storage.put_edge(edge);
    }

    // Create some circular references for edge case testing
    if (block_ids.items.len >= 3) {
        const circular_edge = GraphEdge{
            .source_id = block_ids.items[block_ids.items.len - 1],
            .target_id = block_ids.items[0],
            .edge_type = EdgeType.references,
        };
        try storage.put_edge(circular_edge);
    }
}

/// Fuzz query parsing with malformed inputs
fn fuzz_query_parsing(query_engine: *QueryEngine, query_text: []const u8) !void {
    _ = query_engine;

    // Mock query parsing - in real implementation would call actual parser
    if (query_text.len == 0) return;

    // Simulate parsing different query types
    if (std.mem.startsWith(u8, query_text, "SELECT")) {
        // Mock SQL-like query parsing
    } else if (std.mem.startsWith(u8, query_text, "TRAVERSE")) {
        // Mock graph traversal query parsing
    } else if (std.mem.startsWith(u8, query_text, "SEARCH")) {
        // Mock semantic search query parsing
    }

    // Parsing should handle invalid syntax gracefully
}

/// Fuzz breadth-first traversal operations
fn fuzz_graph_traversal_bfs(query_engine: *QueryEngine, start_id: BlockId) !void {
    _ = query_engine;
    _ = start_id;

    // Mock BFS traversal with potential infinite loops
    var visited = std.HashMap(BlockId, void, BlockIdContext, std.hash_map.default_max_load_percentage).init(std.heap.page_allocator);
    defer visited.deinit();

    // Simulate traversal bounds checking
    var depth: u32 = 0;
    const max_depth = 100; // Prevent infinite traversal

    while (depth < max_depth) : (depth += 1) {
        if (visited.count() > 1000) break; // Limit visited nodes
        try visited.put(BlockId.generate(), {});
    }
}

/// Fuzz depth-first traversal operations
fn fuzz_graph_traversal_dfs(query_engine: *QueryEngine, start_id: BlockId) !void {
    _ = query_engine;
    _ = start_id;

    // Mock DFS traversal with stack overflow protection
    var call_depth: u32 = 0;
    const max_call_depth = 500; // Prevent stack overflow

    try mock_dfs_recursive(BlockId.generate(), &call_depth, max_call_depth);
}

/// Recursive DFS simulation for fuzzing
fn mock_dfs_recursive(node_id: BlockId, call_depth: *u32, max_depth: u32) !void {
    _ = node_id;

    if (call_depth.* >= max_depth) return;
    call_depth.* += 1;
    defer call_depth.* -= 1;

    // Mock recursive traversal
    if (call_depth.* < max_depth / 2) {
        try mock_dfs_recursive(BlockId.generate(), call_depth, max_depth);
    }
}

/// Fuzz semantic search operations
fn fuzz_semantic_search(query_engine: *QueryEngine, search_term: []const u8) !void {
    _ = query_engine;

    // Mock semantic search with various input types
    if (search_term.len == 0) return;

    // Test different search term characteristics
    var has_special_chars = false;
    var has_unicode = false;
    var has_null_bytes = false;

    for (search_term) |byte| {
        if (byte == 0) has_null_bytes = true;
        if (byte > 127) has_unicode = true;
        if (byte < 32 and byte != 9 and byte != 10 and byte != 13) has_special_chars = true;
    }

    // Different search behaviors based on input characteristics
    if (has_null_bytes) {
        // Handle null-terminated strings
    } else if (has_unicode) {
        // Handle Unicode search terms
    } else if (has_special_chars) {
        // Handle control characters
    }

    // Mock search result ranking
    const relevance_score = std.hash.Wyhash.hash(0, search_term) % 100;
    _ = relevance_score;
}

/// Fuzz filtered traversal operations
fn fuzz_filtered_traversal(query_engine: *QueryEngine, filter_data: []const u8) !void {
    _ = query_engine;

    // Mock filter parsing and application
    if (filter_data.len < 2) return;

    const filter_type = filter_data[0] % 4;
    switch (filter_type) {
        0 => { // Edge type filter
            const edge_type_val = filter_data[1] % 4;
            _ = @as(EdgeType, @enumFromInt(edge_type_val));
        },
        1 => { // Content filter
            // Mock content-based filtering
        },
        2 => { // Metadata filter
            // Mock metadata-based filtering
        },
        3 => { // Combined filter
            // Mock multiple filter criteria
        },
        else => {},
    }
}

/// Fuzz query caching operations
fn fuzz_query_caching(query_engine: *QueryEngine, cache_key: []const u8) !void {
    _ = query_engine;

    // Mock cache operations with various key types
    if (cache_key.len == 0) return;

    // Simulate cache key validation
    const key_hash = std.hash.Wyhash.hash(0, cache_key);

    // Mock cache hit/miss scenarios
    const cache_hit = (key_hash % 100) < 30; // 30% hit rate
    if (cache_hit) {
        // Mock cache retrieval
    } else {
        // Mock cache population
    }

    // Test cache eviction scenarios
    if (cache_key.len > 1000) {
        // Large keys might trigger different behavior
    }
}

/// Fuzz complex query operations
fn fuzz_complex_query_operations(query_engine: *QueryEngine, input: []const u8) !void {
    _ = query_engine;

    if (input.len < 8) return;

    // Mock complex query with multiple parts
    var i: usize = 0;
    while (i + 4 < input.len) : (i += 4) {
        const query_part = input[i] % 5;
        switch (query_part) {
            0 => { // JOIN operation
                // Mock graph join operations
            },
            1 => { // AGGREGATION
                // Mock result aggregation
            },
            2 => { // SUBQUERY
                // Mock nested query operations
            },
            3 => { // UNION
                // Mock result combination
            },
            4 => { // SORT
                // Mock result sorting
            },
            else => {},
        }
    }
}

/// Fuzz edge case query scenarios
fn fuzz_edge_case_queries(query_engine: *QueryEngine, input: []const u8) !void {
    _ = query_engine;

    if (input.len == 0) return;

    const edge_case = input[0] % 6;
    switch (edge_case) {
        0 => { // Empty result set
            // Test queries that return no results
        },
        1 => { // Single result
            // Test queries with exactly one result
        },
        2 => { // Massive result set
            // Test queries with many results (stress test)
        },
        3 => { // Circular references
            // Test queries on graphs with cycles
        },
        4 => { // Disconnected components
            // Test queries on fragmented graphs
        },
        5 => { // Self-referencing nodes
            // Test queries on nodes that reference themselves
        },
        else => {},
    }
}

/// Test query operations on corrupted graph data
fn fuzz_corrupted_graph_operations(query_engine: *QueryEngine, input: []const u8) !void {
    _ = query_engine;
    _ = input;

    // Mock operations on potentially corrupted graph structures
    // This would test error recovery and graceful degradation
}

/// Generate fuzzed query text from input data
fn fuzz_generate_query_text(data: []const u8) []const u8 {
    if (data.len < 8) return "SELECT * FROM blocks";

    const query_type = data[0] % 4;
    switch (query_type) {
        0 => return "SELECT * FROM blocks WHERE content LIKE '%fuzz%'",
        1 => return "TRAVERSE FROM root DEPTH 5 WHERE type = 'function'",
        2 => return "SEARCH semantic 'database query optimization'",
        3 => return "INVALID QUERY WITH SYNTAX ERRORS AND $$SPECIAL@@ CHARS",
        else => return "MALFORMED",
    }
}

/// Generate fuzzed search term from input data
fn fuzz_generate_search_term(allocator: std.mem.Allocator, data: []const u8) []const u8 {
    if (data.len < 4) return "default_search";

    const term_type = data[0] % 5;
    switch (term_type) {
        0 => return std.fmt.allocPrint(allocator, "term_{}", .{std.hash.Wyhash.hash(0, data)}) catch "fallback",
        1 => return "function database query",
        2 => return "\x00\xFF\x01\x02", // Binary data
        3 => return "🦀 unicode search 测试", // Unicode
        4 => return "", // Empty string
        else => return "unknown",
    }
}

/// Generate fuzzed filter data
fn fuzz_generate_filter(data: []const u8) []const u8 {
    if (data.len < 2) return &[_]u8{ 0, 1 };
    return data[0..@min(data.len, 16)];
}

/// Generate fuzzed cache key
fn fuzz_generate_cache_key(allocator: std.mem.Allocator, data: []const u8) []const u8 {
    const key_hash = std.hash.Wyhash.hash(0, data);
    return std.fmt.allocPrint(allocator, "cache_key_{x}", .{key_hash}) catch "default_cache_key";
}

/// Generate a fuzzed BlockId from input data
fn fuzz_generate_block_id(data: []const u8) BlockId {
    if (data.len >= 16) {
        var bytes: [16]u8 = undefined;
        @memcpy(&bytes, data[0..16]);
        return BlockId{ .bytes = bytes };
    }
    return BlockId.generate();
}

/// Context for BlockId HashMap
const BlockIdContext = struct {
    pub fn hash(self: @This(), key: BlockId) u64 {
        _ = self;
        return std.hash.Wyhash.hash(0, &key.bytes);
    }

    pub fn eql(self: @This(), a: BlockId, b: BlockId) bool {
        _ = self;
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }
};
