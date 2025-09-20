const std = @import("std");
const testing = std.testing;
const process = std.process;
const fs = std.fs;

test "qualified names end-to-end functionality" {
    const allocator = testing.allocator;

    // Create a temporary directory for our comprehensive test repository
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Get absolute path for the temporary directory
    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Test configuration - use unique workspace name per test run
    const random_suffix = std.crypto.random.int(u32);
    const workspace_name = try std.fmt.allocPrint(allocator, "qualified_names_test_repo_{x}", .{random_suffix});
    defer allocator.free(workspace_name);

    const TestConfig = struct {
        const kausal_cmd = "./zig-out/bin/kausaldb";
    };

    // Create a comprehensive test repository structure
    const TestRepository = struct {
        const files = [_]struct { name: []const u8, content: []const u8 }{
            // Core storage module
            .{
                .name = "storage/engine.zig",
                .content =
                \\const std = @import("std");
                \\
                \\pub const StorageEngine = struct {
                \\    allocator: std.mem.Allocator,
                \\    data: []u8,
                \\
                \\    pub fn init(allocator: std.mem.Allocator) !StorageEngine {
                \\        return StorageEngine{
                \\            .allocator = allocator,
                \\            .data = try allocator.alloc(u8, 1024),
                \\        };
                \\    }
                \\
                \\    pub fn deinit(self: *StorageEngine) void {
                \\        self.allocator.free(self.data);
                \\    }
                \\
                \\    pub fn put_block(self: *StorageEngine, id: u64, data: []const u8) !void {
                \\        _ = self; _ = id; _ = data;
                \\    }
                \\
                \\    pub fn get_block(self: *StorageEngine, id: u64) ?[]const u8 {
                \\        _ = self; _ = id; return null;
                \\    }
                \\
                \\    pub fn flush(self: *StorageEngine) !void {
                \\        _ = self;
                \\    }
                \\
                \\    fn internal_cleanup(self: *StorageEngine) void {
                \\        _ = self;
                \\    }
                \\};
                \\
                \\pub const BlockManager = struct {
                \\    blocks: std.HashMap(u64, []const u8),
                \\
                \\    pub fn init(allocator: std.mem.Allocator) BlockManager {
                \\        return BlockManager{
                \\            .blocks = std.HashMap(u64, []const u8).init(allocator),
                \\        };
                \\    }
                \\
                \\    pub fn put_block(self: *BlockManager, id: u64, data: []const u8) !void {
                \\        try self.blocks.put(id, data);
                \\    }
                \\
                \\    pub fn get_block(self: *BlockManager, id: u64) ?[]const u8 {
                \\        return self.blocks.get(id);
                \\    }
                \\
                \\    pub fn clear(self: *BlockManager) void {
                \\        self.blocks.clearAndFree();
                \\    }
                \\};
                \\
                \\pub fn standalone_storage_function() void {}
                \\pub fn create_default_engine(allocator: std.mem.Allocator) !StorageEngine {
                \\    return StorageEngine.init(allocator);
                \\}
                ,
            },

            // Query processing module
            .{
                .name = "query/processor.zig",
                .content =
                \\const std = @import("std");
                \\const storage = @import("../storage/engine.zig");
                \\
                \\pub const QueryEngine = struct {
                \\    storage: *storage.StorageEngine,
                \\    cache: std.HashMap([]const u8, []const u8),
                \\
                \\    pub fn init(allocator: std.mem.Allocator, storage_engine: *storage.StorageEngine) QueryEngine {
                \\        return QueryEngine{
                \\            .storage = storage_engine,
                \\            .cache = std.HashMap([]const u8, []const u8).init(allocator),
                \\        };
                \\    }
                \\
                \\    pub fn deinit(self: *QueryEngine) void {
                \\        self.cache.deinit();
                \\    }
                \\
                \\    pub fn execute_query(self: *QueryEngine, query: []const u8) ![]const u8 {
                \\        _ = self; _ = query; return "result";
                \\    }
                \\
                \\    pub fn clear_cache(self: *QueryEngine) void {
                \\        self.cache.clearAndFree();
                \\    }
                \\
                \\    pub fn get_stats(self: *QueryEngine) QueryStats {
                \\        return QueryStats{ .queries_executed = 0, .cache_hits = 0 };
                \\    }
                \\
                \\    fn validate_query(query: []const u8) bool {
                \\        return query.len > 0;
                \\    }
                \\};
                \\
                \\pub const QueryStats = struct {
                \\    queries_executed: u64,
                \\    cache_hits: u64,
                \\
                \\    pub fn init() QueryStats {
                \\        return QueryStats{ .queries_executed = 0, .cache_hits = 0 };
                \\    }
                \\
                \\    pub fn reset(self: *QueryStats) void {
                \\        self.queries_executed = 0;
                \\        self.cache_hits = 0;
                \\    }
                \\
                \\    pub fn format(self: QueryStats, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
                \\        _ = fmt; _ = options;
                \\        try writer.print("QueryStats{{executed: {}, hits: {}}}", .{ self.queries_executed, self.cache_hits });
                \\    }
                \\};
                \\
                \\pub fn parse_query(input: []const u8) []const u8 {
                \\    return input;
                \\}
                \\
                \\pub fn optimize_query(query: []const u8) []const u8 {
                \\    return query;
                \\}
                ,
            },

            // Network communication module
            .{
                .name = "network/client.zig",
                .content =
                \\const std = @import("std");
                \\
                \\pub const NetworkClient = struct {
                \\    address: []const u8,
                \\    port: u16,
                \\    connected: bool,
                \\
                \\    pub fn init(address: []const u8, port: u16) NetworkClient {
                \\        return NetworkClient{
                \\            .address = address,
                \\            .port = port,
                \\            .connected = false,
                \\        };
                \\    }
                \\
                \\    pub fn connect(self: *NetworkClient) !void {
                \\        _ = self;
                \\    }
                \\
                \\    pub fn disconnect(self: *NetworkClient) void {
                \\        self.connected = false;
                \\    }
                \\
                \\    pub fn send_data(self: *NetworkClient, data: []const u8) !void {
                \\        _ = self; _ = data;
                \\    }
                \\
                \\    pub fn receive_data(self: *NetworkClient, buffer: []u8) !usize {
                \\        _ = self; _ = buffer; return 0;
                \\    }
                \\};
                \\
                \\pub const Server = struct {
                \\    port: u16,
                \\    running: bool,
                \\
                \\    pub fn init(port: u16) Server {
                \\        return Server{ .port = port, .running = false };
                \\    }
                \\
                \\    pub fn start(self: *Server) !void {
                \\        self.running = true;
                \\    }
                \\
                \\    pub fn stop(self: *Server) void {
                \\        self.running = false;
                \\    }
                \\
                \\    pub fn handle_request(self: *Server, request: []const u8) []const u8 {
                \\        _ = self; _ = request; return "response";
                \\    }
                \\};
                \\
                \\pub fn create_client(address: []const u8, port: u16) NetworkClient {
                \\    return NetworkClient.init(address, port);
                \\}
                \\
                \\pub fn validate_address(address: []const u8) bool {
                \\    return address.len > 0;
                \\}
                ,
            },

            // Utilities and configuration
            .{
                .name = "utils/config.zig",
                .content =
                \\const std = @import("std");
                \\
                \\pub const Config = struct {
                \\    database_path: []const u8,
                \\    max_connections: u32,
                \\    timeout_ms: u64,
                \\
                \\    pub fn init(database_path: []const u8) Config {
                \\        return Config{
                \\            .database_path = database_path,
                \\            .max_connections = 100,
                \\            .timeout_ms = 5000,
                \\        };
                \\    }
                \\
                \\    pub fn validate(self: *const Config) bool {
                \\        return self.database_path.len > 0 and self.max_connections > 0;
                \\    }
                \\
                \\    pub fn update_timeout(self: *Config, new_timeout: u64) void {
                \\        self.timeout_ms = new_timeout;
                \\    }
                \\
                \\    pub fn load_from_file(allocator: std.mem.Allocator, path: []const u8) !Config {
                \\        _ = allocator; _ = path;
                \\        return Config.init("/default/path");
                \\    }
                \\};
                \\
                \\pub const Logger = struct {
                \\    level: LogLevel,
                \\    output_file: ?[]const u8,
                \\
                \\    pub fn init(level: LogLevel) Logger {
                \\        return Logger{ .level = level, .output_file = null };
                \\    }
                \\
                \\    pub fn log(self: *Logger, level: LogLevel, message: []const u8) void {
                \\        _ = self; _ = level; _ = message;
                \\    }
                \\
                \\    pub fn set_output_file(self: *Logger, path: []const u8) void {
                \\        self.output_file = path;
                \\    }
                \\
                \\    pub fn close(self: *Logger) void {
                \\        _ = self;
                \\    }
                \\};
                \\
                \\pub const LogLevel = enum {
                \\    debug,
                \\    info,
                \\    warn,
                \\    error,
                \\};
                \\
                \\pub fn parse_config_file(content: []const u8) !Config {
                \\    _ = content;
                \\    return Config.init("/parsed/path");
                \\}
                \\
                \\pub fn get_default_config() Config {
                \\    return Config.init("/default");
                \\}
                ,
            },

            // Top-level application file
            .{
                .name = "main.zig",
                .content =
                \\const std = @import("std");
                \\const storage = @import("storage/engine.zig");
                \\const query = @import("query/processor.zig");
                \\const network = @import("network/client.zig");
                \\const utils = @import("utils/config.zig");
                \\
                \\pub const Application = struct {
                \\    allocator: std.mem.Allocator,
                \\    storage_engine: storage.StorageEngine,
                \\    query_engine: query.QueryEngine,
                \\    config: utils.Config,
                \\
                \\    pub fn init(allocator: std.mem.Allocator, config: utils.Config) !Application {
                \\        var storage_engine = try storage.StorageEngine.init(allocator);
                \\        const query_engine = query.QueryEngine.init(allocator, &storage_engine);
                \\
                \\        return Application{
                \\            .allocator = allocator,
                \\            .storage_engine = storage_engine,
                \\            .query_engine = query_engine,
                \\            .config = config,
                \\        };
                \\    }
                \\
                \\    pub fn deinit(self: *Application) void {
                \\        self.query_engine.deinit();
                \\        self.storage_engine.deinit();
                \\    }
                \\
                \\    pub fn start(self: *Application) !void {
                \\        _ = self;
                \\    }
                \\
                \\    pub fn stop(self: *Application) void {
                \\        _ = self;
                \\    }
                \\
                \\    pub fn process_request(self: *Application, request: []const u8) ![]const u8 {
                \\        return try self.query_engine.execute_query(request);
                \\    }
                \\};
                \\
                \\pub fn main() !void {
                \\    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
                \\    defer _ = gpa.deinit();
                \\    const allocator = gpa.allocator();
                \\
                \\    const config = utils.Config.init("/app/data");
                \\    var app = try Application.init(allocator, config);
                \\    defer app.deinit();
                \\
                \\    try app.start();
                \\}
                \\
                \\pub fn create_app(allocator: std.mem.Allocator) !Application {
                \\    const config = utils.get_default_config();
                \\    return Application.init(allocator, config);
                \\}
                \\
                \\pub fn version() []const u8 {
                \\    return "1.0.0";
                \\}
                ,
            },
        };

        // Core test cases - minimal but comprehensive
        const TestCases = struct {
            const qualified_function = "StorageEngine.init";
            const ambiguous_function = "init";
            const standalone_function = "main";
            const nonexistent_function = "NonExistent.method";
        };
    };

    // Setup test repository structure
    {
        // Create directory structure
        try tmp_dir.dir.makeDir("storage");
        try tmp_dir.dir.makeDir("query");
        try tmp_dir.dir.makeDir("network");
        try tmp_dir.dir.makeDir("utils");

        // Write all test files
        for (TestRepository.files) |file| {
            try tmp_dir.dir.writeFile(.{ .sub_path = file.name, .data = file.content });
        }

        // Initialize as git repository so git ls-files will work
        const git_init_result = try process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "git", "init" },
            .cwd = tmp_path,
        });
        defer allocator.free(git_init_result.stdout);
        defer allocator.free(git_init_result.stderr);

        const git_add_result = try process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "git", "add", "." },
            .cwd = tmp_path,
        });
        defer allocator.free(git_add_result.stdout);
        defer allocator.free(git_add_result.stderr);
    }

    // Helper for running searches with comprehensive error reporting
    const SearchHelper = struct {
        const SearchResult = struct {
            stdout: []u8,
            stderr: []u8,
            exit_code: u8,
            allocator: std.mem.Allocator,

            fn deinit(self: *SearchResult) void {
                self.allocator.free(self.stdout);
                self.allocator.free(self.stderr);
            }

            fn expectSuccess(self: SearchResult) !void {
                if (self.exit_code != 0) {
                    std.debug.print("Command failed with exit code {}, stderr: {s}\n", .{ self.exit_code, self.stderr });
                    return error.CommandFailed;
                }
            }

            fn expectFound(self: SearchResult, search_term: []const u8) !void {
                try self.expectSuccess();
                if (std.mem.indexOf(u8, self.stdout, search_term) == null) {
                    std.debug.print("Search term '{s}' not found in output: {s}\n", .{ search_term, self.stdout });
                    return error.SearchTermNotFound;
                }
                if (std.mem.indexOf(u8, self.stdout, "Found") == null) {
                    std.debug.print("No 'Found' indicator in output: {s}\n", .{self.stdout});
                    return error.NoFoundIndicator;
                }
            }

            fn expectNotFound(self: SearchResult, search_term: []const u8) !void {
                try self.expectSuccess();
                if (std.mem.indexOf(u8, self.stdout, "No function named") == null) {
                    std.debug.print("Expected 'No function named' but got: {s}\n", .{self.stdout});
                    return error.ExpectedNotFound;
                }
                if (std.mem.indexOf(u8, self.stdout, search_term) == null) {
                    std.debug.print("Search term '{s}' not mentioned in not-found message: {s}\n", .{ search_term, self.stdout });
                    return error.SearchTermNotMentioned;
                }
            }

            fn expectSpecific(self: SearchResult, search_term: []const u8, expected_file: []const u8) !void {
                try self.expectFound(search_term);

                // Check that the source file matches the expected file
                if (std.mem.indexOf(u8, self.stdout, "Source: ")) |source_start| {
                    const source_prefix = "Source: ";
                    const source_value_start = source_start + source_prefix.len;
                    const source_line_end = std.mem.indexOf(u8, self.stdout[source_value_start..], "\n") orelse (self.stdout.len - source_value_start);
                    const source_file = self.stdout[source_value_start .. source_value_start + source_line_end];

                    if (!std.mem.eql(u8, source_file, expected_file)) {
                        std.debug.print("Expected source file '{s}' but found '{s}'\n", .{ expected_file, source_file });
                        return error.UnexpectedSourceFile;
                    }
                } else {
                    std.debug.print("No 'Source:' line found in output: {s}\n", .{self.stdout});
                    return error.NoSourceLineFound;
                }
            }

            fn expectDoesNotContain(self: SearchResult, unwanted_term: []const u8) !void {
                if (std.mem.indexOf(u8, self.stdout, unwanted_term) != null) {
                    std.debug.print("Unexpectedly found '{s}' in output: {s}\n", .{ unwanted_term, self.stdout });
                    return error.UnexpectedTermFound;
                }
            }

            fn expectContains(self: SearchResult, expected_term: []const u8) !void {
                if (std.mem.indexOf(u8, self.stdout, expected_term) == null) {
                    std.debug.print("Expected term '{s}' not found in output: {s}\n", .{ expected_term, self.stdout });
                    return error.ExpectedTermNotFound;
                }
            }
        };

        fn runSearch(search_allocator: std.mem.Allocator, function_name: []const u8, workspace: []const u8) !SearchResult {
            const result = try process.Child.run(.{
                .allocator = search_allocator,
                .argv = &[_][]const u8{ TestConfig.kausal_cmd, "find", "function", function_name, "in", workspace },
            });

            return SearchResult{
                .stdout = result.stdout,
                .stderr = result.stderr,
                .exit_code = result.term.Exited,
                .allocator = search_allocator,
            };
        }
    };

    // Setup workspace
    {
        const link_result = try process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ TestConfig.kausal_cmd, "link", tmp_path, "as", workspace_name },
        });
        defer allocator.free(link_result.stdout);
        defer allocator.free(link_result.stderr);
        if (link_result.term.Exited != 0) {
            std.debug.print("Link failed with exit code {}, stderr: {s}\n", .{ link_result.term.Exited, link_result.stderr });
            return error.LinkFailed;
        }

        const sync_result = try process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ TestConfig.kausal_cmd, "sync", workspace_name },
        });
        defer allocator.free(sync_result.stdout);
        defer allocator.free(sync_result.stderr);
        if (sync_result.term.Exited != 0) {
            std.debug.print("Sync failed with exit code {}, stderr: {s}\n", .{ sync_result.term.Exited, sync_result.stderr });
            return error.SyncFailed;
        }
    }

    // Test 1: Basic qualified name searches
    {
        const search_term = SearchTerms.storage_init;
        const result = try process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ kausal_cmd, "find", "function", search_term, "in", workspace_name },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            std.debug.print("StorageEngine.init search failed: {s}\n", .{result.stderr});
            return error.SearchFailed;
        }

        // Should find StorageEngine.init
        try testing.expect(std.mem.indexOf(u8, result.stdout, "StorageEngine.init") != null);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "StorageEngine") != null);
    }

    // Test 2: Ambiguous functions should find multiple results
    for (TestRepository.ExpectedResults.ambiguous_functions) |ambiguous_name| {
        var result = try SearchHelper.runSearch(allocator, ambiguous_name, workspace_name);
        defer result.deinit();

        try result.expectFound(ambiguous_name);

        // Should find multiple different structs for ambiguous names like "init"
        const line_count = std.mem.count(u8, result.stdout, "\n");
        try testing.expect(line_count > 3); // Multiple results expected
    }

    // Test 3: Standalone functions should work
    for (TestRepository.ExpectedResults.standalone_functions) |standalone_name| {
        var result = try SearchHelper.runSearch(allocator, standalone_name, workspace_name);
        defer result.deinit();

        try result.expectFound(standalone_name);
    }

    // Test 4: Non-existent qualified names should return not found
    for (TestRepository.ExpectedResults.nonexistent_functions) |nonexistent_name| {
        var result = try SearchHelper.runSearch(allocator, nonexistent_name, workspace_name);
        defer result.deinit();

        try result.expectNotFound(nonexistent_name);
    }

    // Test 5: Verify specificity - qualified search returns correct file
    {
        var result = try SearchHelper.runSearch(allocator, TestRepository.TestCases.qualified_function, workspace_name);
        defer result.deinit();
        try result.expectFound(TestRepository.TestCases.qualified_function);
        try result.expectSpecific(TestRepository.TestCases.qualified_function, "storage/engine.zig");
    }

    // Test 2: Ambiguous functions find multiple results
    {
        var result = try SearchHelper.runSearch(allocator, TestRepository.TestCases.ambiguous_function, workspace_name);
        defer result.deinit();
        try result.expectFound(TestRepository.TestCases.ambiguous_function);

        // Should find multiple results for ambiguous names
        const line_count = std.mem.count(u8, result.stdout, "\n");
        try testing.expect(line_count > 5); // Multiple results expected
    }

    // Test 3: Standalone functions work
    {
        var result = try SearchHelper.runSearch(allocator, TestRepository.TestCases.standalone_function, workspace_name);
        defer result.deinit();
        try result.expectFound(TestRepository.TestCases.standalone_function);
    }

    // Test 4: Non-existent qualified names return not found
    {
        var result = try SearchHelper.runSearch(allocator, TestRepository.TestCases.nonexistent_function, workspace_name);
        defer result.deinit();
        try result.expectNotFound(TestRepository.TestCases.nonexistent_function);
    }

    // Cleanup
    {
        const unlink_result = try process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ TestConfig.kausal_cmd, "unlink", workspace_name },
        });
        defer allocator.free(unlink_result.stdout);
        defer allocator.free(unlink_result.stderr);
        // Don't fail test if cleanup fails
    }
}
