//! CLI/Server performance benchmark for KausalDB client-server architecture.
//!
//! Measures round-trip latency and throughput for various CLI commands through
//! the full client-server stack. Validates that the thin client architecture
//! achieves the target <10ms command latency for user-facing operations.

const std = @import("std");
const builtin = @import("builtin");

const assert_mod = @import("../core/assert.zig");
const concurrency = @import("../core/concurrency.zig");
const error_context = @import("../core/error_context.zig");
const memory = @import("../core/memory.zig");
const vfs = @import("../core/vfs.zig");
const production_vfs = @import("../core/production_vfs.zig");
const storage = @import("../storage/engine.zig");
const query_engine = @import("../query/engine.zig");
const workspace_manager = @import("../workspace/manager.zig");
const client_mod = @import("../cli/client.zig");
const protocol = @import("../cli/protocol.zig");
const server_handler = @import("../server/cli_protocol.zig");
const connection_manager = @import("../server/connection_manager.zig");
const types = @import("../core/types.zig");

const assert_fmt = assert_mod.assert_fmt;
const fatal_assert = assert_mod.fatal_assert;
const ArenaCoordinator = memory.ArenaCoordinator;
const StorageEngine = storage.StorageEngine;
const QueryEngine = query_engine.QueryEngine;
const WorkspaceManager = workspace_manager.WorkspaceManager;
const Client = client_mod.Client;
const ClientConfig = client_mod.ClientConfig;
const HandlerContext = server_handler.HandlerContext;
const ConnectionManager = connection_manager.ConnectionManager;
const ConnectionManagerConfig = connection_manager.ConnectionManagerConfig;

const log = std.log.scoped(.cli_server_bench);

/// Target latencies for CLI operations (microseconds)
const TARGET_LATENCY_US = struct {
    const find_command = 8_000; // 8ms for find operations
    const show_command = 10_000; // 10ms for relationship queries
    const trace_command = 15_000; // 15ms for graph traversal
    const status_command = 2_000; // 2ms for status queries
    const ping_command = 1_000; // 1ms for ping operations
};

/// Statistical sampling parameters
const BENCHMARK_CONFIG = struct {
    const warmup_iterations = 100;
    const measurement_iterations = 1000;
    const outlier_threshold_percent = 5;
    const target_confidence = 0.95;
};

/// Comprehensive benchmark suite for CLI/server architecture
pub const CLIServerBenchmark = struct {
    allocator: std.mem.Allocator,
    arena_coordinator: *ArenaCoordinator,

    // Server components (long-lived)
    storage_engine: *StorageEngine,
    query_engine: *QueryEngine,
    workspace_manager: *WorkspaceManager,
    connection_manager: *ConnectionManager,
    handler_context: *HandlerContext,

    // Client component (connects to server)
    client: *Client,

    // Test data tracking
    test_workspace_dir: []const u8,
    server_port: u16,

    const Self = @This();

    /// Initialize benchmark harness (cold init, no I/O)
    pub fn init(allocator: std.mem.Allocator, test_name: []const u8) !Self {
        concurrency.assert_main_thread();

        const arena_coordinator = try allocator.create(ArenaCoordinator);
        arena_coordinator.* = ArenaCoordinator.init(allocator);

        // Create unique test workspace to prevent interference
        const test_workspace_dir = try std.fmt.allocPrint(allocator, "/tmp/kausaldb_cli_bench_{s}_{}", .{ test_name, std.time.nanoTimestamp() });

        return Self{
            .allocator = allocator,
            .arena_coordinator = arena_coordinator,
            .storage_engine = undefined,
            .query_engine = undefined,
            .workspace_manager = undefined,
            .connection_manager = undefined,
            .handler_context = undefined,
            .client = undefined,
            .test_workspace_dir = test_workspace_dir,
            .server_port = 0, // Will be assigned during startup
        };
    }

    /// Start server components (hot startup, performs I/O)
    pub fn startup(self: *Self) !void {
        concurrency.assert_main_thread();

        // Create test workspace directory
        std.fs.cwd().makeDir(self.test_workspace_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Initialize storage with production VFS for realistic I/O patterns
        const vfs_impl = production_vfs.ProductionVFS.init();
        const storage_config = StorageEngine.Config{
            .data_dir = self.test_workspace_dir,
            .wal_segment_size = 64 * 1024 * 1024, // 64MB segments
            .memtable_size_limit = 16 * 1024 * 1024, // 16MB memtable
            .compaction_threshold = 4,
        };

        self.storage_engine = try self.allocator.create(StorageEngine);
        self.storage_engine.* = try StorageEngine.init(self.allocator, self.arena_coordinator, vfs.VFS{ .production = vfs_impl }, storage_config);
        try self.storage_engine.startup();

        // Initialize query engine
        self.query_engine = try self.allocator.create(QueryEngine);
        self.query_engine.* = QueryEngine.init(self.allocator, self.storage_engine);

        // Initialize workspace manager
        self.workspace_manager = try self.allocator.create(WorkspaceManager);
        self.workspace_manager.* = WorkspaceManager.init(self.allocator, self.storage_engine, self.test_workspace_dir);

        // Populate test data for realistic benchmarks
        try self.populate_test_data();

        // Start server components
        self.server_port = try self.find_available_port();

        const handler_config = HandlerContext.Config{
            .max_request_size = 1024 * 1024, // 1MB max request
            .timeout_ms = 30_000, // 30s timeout
        };

        self.handler_context = try self.allocator.create(HandlerContext);
        self.handler_context.* = HandlerContext.init(self.allocator, self.storage_engine, self.query_engine, self.workspace_manager, handler_config);

        const connection_config = ConnectionManagerConfig{
            .host = "127.0.0.1",
            .port = self.server_port,
            .max_connections = 100,
            .connection_timeout_sec = 30,
        };

        self.connection_manager = try self.allocator.create(ConnectionManager);
        self.connection_manager.* = ConnectionManager.init(self.allocator, connection_config, self.handler_context);
        try self.connection_manager.startup();

        // Initialize client
        self.client = try self.allocator.create(Client);
        self.client.* = Client.init(self.allocator, ClientConfig{
            .host = "127.0.0.1",
            .port = self.server_port,
            .timeout_ms = 10_000, // 10s timeout
            .max_retries = 1, // No retries in benchmarks for consistent timing
        });
        try self.client.connect();

        log.info("CLI/Server benchmark initialized on port {}", .{self.server_port});
    }

    /// Stop server components (graceful shutdown)
    pub fn shutdown(self: *Self) void {
        if (self.client) |*c| c.deinit();
        if (self.connection_manager) |*cm| cm.shutdown();
        if (self.handler_context) |*hc| hc.deinit();
        if (self.workspace_manager) |*wm| wm.deinit();
        if (self.query_engine) |*qe| qe.deinit();
        if (self.storage_engine) |*se| {
            se.shutdown();
            se.deinit();
        }

        // Clean up test workspace
        std.fs.cwd().deleteTree(self.test_workspace_dir) catch |err| {
            log.warn("Failed to cleanup test workspace {s}: {}", .{ self.test_workspace_dir, err });
        };
    }

    /// Full cleanup (memory deallocation)
    pub fn deinit(self: *Self) void {
        self.shutdown();

        self.allocator.free(self.test_workspace_dir);

        if (self.arena_coordinator) |ac| {
            ac.deinit();
            self.allocator.destroy(ac);
        }
    }

    /// Benchmark find command round-trip latency
    pub fn benchmark_find_command(self: *Self) !BenchmarkResult {
        const query_patterns = [_][]const u8{
            "main",
            "init",
            "execute",
            "StorageEngine",
            "parse_command",
        };

        var sampler = StatisticalSampler.init(self.allocator);
        defer sampler.deinit();

        // Warmup phase eliminates cold-start effects
        for (0..BENCHMARK_CONFIG.warmup_iterations) |_| {
            const query = query_patterns[@mod(std.crypto.random.int(usize), query_patterns.len)];
            _ = try self.client.find_blocks(query, 10);
        }

        // Measurement phase
        for (0..BENCHMARK_CONFIG.measurement_iterations) |i| {
            const query = query_patterns[@mod(i, query_patterns.len)];

            const start_time = std.time.nanoTimestamp();
            _ = try self.client.find_blocks(query, 10);
            const elapsed_ns = std.time.nanoTimestamp() - start_time;

            try sampler.add_sample(@intCast(elapsed_ns / 1000)); // Convert to microseconds
        }

        return BenchmarkResult{
            .operation = "find_command",
            .target_latency_us = TARGET_LATENCY_US.find_command,
            .statistics = try sampler.compute_statistics(),
        };
    }

    /// Benchmark show command (relationship queries)
    pub fn benchmark_show_command(self: *Self) !BenchmarkResult {
        const target_functions = [_][]const u8{
            "main",
            "init",
            "startup",
            "execute_command",
            "parse_args",
        };

        var sampler = StatisticalSampler.init(self.allocator);
        defer sampler.deinit();

        // Warmup
        for (0..BENCHMARK_CONFIG.warmup_iterations) |_| {
            const target = target_functions[@mod(std.crypto.random.int(usize), target_functions.len)];
            _ = try self.client.show_callers(target, 3);
        }

        // Measurement
        for (0..BENCHMARK_CONFIG.measurement_iterations) |i| {
            const target = target_functions[@mod(i, target_functions.len)];

            const start_time = std.time.nanoTimestamp();
            _ = try self.client.show_callers(target, 3);
            const elapsed_ns = std.time.nanoTimestamp() - start_time;

            try sampler.add_sample(@intCast(elapsed_ns / 1000));
        }

        return BenchmarkResult{
            .operation = "show_command",
            .target_latency_us = TARGET_LATENCY_US.show_command,
            .statistics = try sampler.compute_statistics(),
        };
    }

    /// Benchmark trace command (graph traversal)
    pub fn benchmark_trace_command(self: *Self) !BenchmarkResult {
        const trace_pairs = [_][2][]const u8{
            [_][]const u8{ "main", "init" },
            [_][]const u8{ "startup", "run" },
            [_][]const u8{ "parse", "execute" },
            [_][]const u8{ "connect", "disconnect" },
        };

        var sampler = StatisticalSampler.init(self.allocator);
        defer sampler.deinit();

        // Warmup
        for (0..BENCHMARK_CONFIG.warmup_iterations) |_| {
            const pair = trace_pairs[@mod(std.crypto.random.int(usize), trace_pairs.len)];
            _ = try self.client.trace_paths(pair[0], pair[1], 5);
        }

        // Measurement
        for (0..BENCHMARK_CONFIG.measurement_iterations) |i| {
            const pair = trace_pairs[@mod(i, trace_pairs.len)];

            const start_time = std.time.nanoTimestamp();
            _ = try self.client.trace_paths(pair[0], pair[1], 5);
            const elapsed_ns = std.time.nanoTimestamp() - start_time;

            try sampler.add_sample(@intCast(elapsed_ns / 1000));
        }

        return BenchmarkResult{
            .operation = "trace_command",
            .target_latency_us = TARGET_LATENCY_US.trace_command,
            .statistics = try sampler.compute_statistics(),
        };
    }

    /// Benchmark status command (lightweight operation)
    pub fn benchmark_status_command(self: *Self) !BenchmarkResult {
        var sampler = StatisticalSampler.init(self.allocator);
        defer sampler.deinit();

        // Warmup
        for (0..BENCHMARK_CONFIG.warmup_iterations) |_| {
            _ = try self.client.query_status();
        }

        // Measurement
        for (0..BENCHMARK_CONFIG.measurement_iterations) |_| {
            const start_time = std.time.nanoTimestamp();
            _ = try self.client.query_status();
            const elapsed_ns = std.time.nanoTimestamp() - start_time;

            try sampler.add_sample(@intCast(elapsed_ns / 1000));
        }

        return BenchmarkResult{
            .operation = "status_command",
            .target_latency_us = TARGET_LATENCY_US.status_command,
            .statistics = try sampler.compute_statistics(),
        };
    }

    /// Benchmark ping command (minimal overhead)
    pub fn benchmark_ping_command(self: *Self) !BenchmarkResult {
        var sampler = StatisticalSampler.init(self.allocator);
        defer sampler.deinit();

        // Warmup
        for (0..BENCHMARK_CONFIG.warmup_iterations) |_| {
            try self.client.ping();
        }

        // Measurement
        for (0..BENCHMARK_CONFIG.measurement_iterations) |_| {
            const start_time = std.time.nanoTimestamp();
            try self.client.ping();
            const elapsed_ns = std.time.nanoTimestamp() - start_time;

            try sampler.add_sample(@intCast(elapsed_ns / 1000));
        }

        return BenchmarkResult{
            .operation = "ping_command",
            .target_latency_us = TARGET_LATENCY_US.ping_command,
            .statistics = try sampler.compute_statistics(),
        };
    }

    /// Run complete benchmark suite
    pub fn run_full_benchmark(self: *Self) !void {
        const stdout = std.io.getStdOut().writer();

        try stdout.writeAll("KausalDB CLI/Server Performance Benchmark\n");
        try stdout.writeAll("=========================================\n\n");

        const benchmarks = [_]struct {
            name: []const u8,
            func: fn (*Self) anyerror!BenchmarkResult,
        }{
            .{ .name = "Ping Command", .func = benchmark_ping_command },
            .{ .name = "Status Command", .func = benchmark_status_command },
            .{ .name = "Find Command", .func = benchmark_find_command },
            .{ .name = "Show Command", .func = benchmark_show_command },
            .{ .name = "Trace Command", .func = benchmark_trace_command },
        };

        for (benchmarks) |bench| {
            try stdout.print("Running {s}...\n", .{bench.name});
            const result = try bench.func(self);
            try result.print_report(stdout);
            try stdout.writeAll("\n");
        }
    }

    // === PRIVATE IMPLEMENTATION ===

    /// Populate database with realistic test data for benchmarking
    fn populate_test_data(self: *Self) !void {
        // Create sample blocks representing a typical codebase structure
        const test_blocks = [_]struct {
            uri: []const u8,
            content: []const u8,
            metadata: []const u8,
        }{
            .{ .uri = "src/main.zig", .content = "pub fn main() !void { try run(); }", .metadata = "{\"type\":\"function\"}" },
            .{ .uri = "src/init.zig", .content = "pub fn init(allocator: Allocator) !App { return App{}; }", .metadata = "{\"type\":\"function\"}" },
            .{ .uri = "src/storage.zig", .content = "pub const StorageEngine = struct { pub fn startup() !void {} };", .metadata = "{\"type\":\"struct\"}" },
            .{ .uri = "src/parser.zig", .content = "pub fn parse_command(args: [][]u8) !Command { return Command{}; }", .metadata = "{\"type\":\"function\"}" },
            .{ .uri = "src/execute.zig", .content = "pub fn execute_command(cmd: Command) !void { try cmd.run(); }", .metadata = "{\"type\":\"function\"}" },
        };

        for (test_blocks) |block_info| {
            const block = types.ContextBlock{
                .id = types.BlockId.generate(),
                .source_uri = block_info.uri,
                .content = block_info.content,
                .metadata_json = block_info.metadata,
                .version = 1,
            };

            try self.storage_engine.put_block(block);
        }

        // Create edges representing call relationships
        const test_edges = [_]struct {
            source: []const u8,
            target: []const u8,
            edge_type: types.EdgeType,
        }{
            .{ .source = "src/main.zig", .target = "src/init.zig", .edge_type = .calls },
            .{ .source = "src/main.zig", .target = "src/execute.zig", .edge_type = .calls },
            .{ .source = "src/execute.zig", .target = "src/parser.zig", .edge_type = .calls },
            .{ .source = "src/execute.zig", .target = "src/storage.zig", .edge_type = .calls },
        };

        for (test_edges) |edge_info| {
            // In a real implementation, we'd resolve URIs to BlockIds
            // For benchmarking, we'll create synthetic edges
            const edge = types.GraphEdge{
                .source_id = types.BlockId.generate(),
                .target_id = types.BlockId.generate(),
                .edge_type = edge_info.edge_type,
            };

            try self.storage_engine.put_edge(edge);
        }

        // Flush changes to ensure consistent benchmark baseline
        try self.storage_engine.flush_memtable();
    }

    /// Find an available TCP port for the test server
    fn find_available_port(self: *Self) !u16 {
        _ = self;
        // Simple port allocation - in production, use more sophisticated logic
        const base_port = 8000 + @mod(std.crypto.random.int(u16), 1000);
        return base_port;
    }
};

/// Statistical measurement results
const BenchmarkResult = struct {
    operation: []const u8,
    target_latency_us: u64,
    statistics: StatisticalSampler.Statistics,

    /// Print detailed benchmark report
    pub fn print_report(self: BenchmarkResult, writer: anytype) !void {
        try writer.print("{s} Performance:\n", .{self.operation});
        try writer.print("  Target:     {d:>8} μs\n", .{self.target_latency_us});
        try writer.print("  Median:     {d:>8} μs\n", .{self.statistics.median_us});
        try writer.print("  Mean:       {d:>8} μs\n", .{self.statistics.mean_us});
        try writer.print("  P95:        {d:>8} μs\n", .{self.statistics.p95_us});
        try writer.print("  P99:        {d:>8} μs\n", .{self.statistics.p99_us});
        try writer.print("  Min:        {d:>8} μs\n", .{self.statistics.min_us});
        try writer.print("  Max:        {d:>8} μs\n", .{self.statistics.max_us});

        const target_met = self.statistics.p95_us <= self.target_latency_us;
        const status = if (target_met) "✅ PASS" else "❌ FAIL";
        try writer.print("  Status:     {s}\n", .{status});
    }
};

/// Statistical sampling and analysis
const StatisticalSampler = struct {
    allocator: std.mem.Allocator,
    samples: std.ArrayList(u64),

    const Statistics = struct {
        sample_count: usize,
        median_us: u64,
        mean_us: u64,
        p95_us: u64,
        p99_us: u64,
        min_us: u64,
        max_us: u64,
        stddev_us: u64,
    };

    pub fn init(allocator: std.mem.Allocator) StatisticalSampler {
        return StatisticalSampler{
            .allocator = allocator,
            .samples = std.ArrayList(u64).init(allocator),
        };
    }

    pub fn deinit(self: *StatisticalSampler) void {
        self.samples.deinit();
    }

    pub fn add_sample(self: *StatisticalSampler, latency_us: u64) !void {
        try self.samples.append(latency_us);
    }

    pub fn compute_statistics(self: *StatisticalSampler) !Statistics {
        fatal_assert(self.samples.items.len > 0, "Cannot compute statistics on empty sample set", .{});

        // Sort samples for percentile calculations
        std.mem.sort(u64, self.samples.items, {}, comptime std.sort.asc(u64));

        const samples = self.samples.items;
        const count = samples.len;

        // Basic statistics
        const min_us = samples[0];
        const max_us = samples[count - 1];
        const median_us = samples[count / 2];

        // Percentiles
        const p95_index = @min(count - 1, (95 * count) / 100);
        const p99_index = @min(count - 1, (99 * count) / 100);
        const p95_us = samples[p95_index];
        const p99_us = samples[p99_index];

        // Mean and standard deviation
        var sum: u64 = 0;
        for (samples) |sample| {
            sum += sample;
        }
        const mean_us = sum / count;

        var variance_sum: u64 = 0;
        for (samples) |sample| {
            const diff = if (sample > mean_us) sample - mean_us else mean_us - sample;
            variance_sum += diff * diff;
        }
        const variance = variance_sum / count;
        const stddev_us: u64 = @intFromFloat(@sqrt(@as(f64, @floatFromInt(variance))));

        return Statistics{
            .sample_count = count,
            .median_us = median_us,
            .mean_us = mean_us,
            .p95_us = p95_us,
            .p99_us = p99_us,
            .min_us = min_us,
            .max_us = max_us,
            .stddev_us = stddev_us,
        };
    }
};

// === BENCHMARK ENTRY POINTS ===

/// Run CLI/Server latency benchmark
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var benchmark = try CLIServerBenchmark.init(allocator, "latency");
    defer benchmark.deinit();

    try benchmark.startup();
    defer benchmark.shutdown();

    try benchmark.run_full_benchmark();
}
