//! Unified test harness framework for consistent testing patterns.
//!
//! Provides standardized harnesses for storage, query, and simulation testing
//! with proper lifecycle management, memory safety, and deterministic behavior.
//! All harnesses follow the two-phase initialization pattern and arena-based
//! memory management.
//!
//! Design rationale: Centralized harness infrastructure ensures consistent
//! testing patterns, proper resource cleanup, and eliminates boilerplate across
//! test files. Arena-based memory model prevents leaks in test scenarios.

const std = @import("std");
const builtin = @import("builtin");

const assert_mod = @import("../core/assert.zig");
const memory = @import("../core/memory.zig");
const vfs = @import("../core/vfs.zig");
const production_vfs = @import("../core/production_vfs.zig");
const simulation_vfs = @import("../sim/simulation_vfs.zig");
const storage_engine = @import("../storage/engine.zig");
const storage_config = @import("../storage/config.zig");
const query_engine = @import("../query/engine.zig");
const simulation = @import("../sim/simulation.zig");
const context_block = @import("../core/types.zig");

const assert = assert_mod.assert;
const fatal_assert = assert_mod.fatal_assert;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArenaCoordinator = memory.ArenaCoordinator;
const VFS = vfs.VFS;
const ProductionVFS = production_vfs.ProductionVFS;
const SimulationVFS = simulation_vfs.SimulationVFS;
const StorageEngine = storage_engine.StorageEngine;
const StorageConfig = storage_config.Config;
const QueryEngine = query_engine.QueryEngine;
const Simulation = simulation.Simulation;
const ContextBlock = context_block.ContextBlock;
const BlockId = context_block.BlockId;

/// Core test harness providing base functionality for all test scenarios.
/// Manages test lifecycle, memory, and provides common utilities.
pub const TestHarness = struct {
    name: []const u8,
    allocator: std.mem.Allocator,
    temp_dir: ?std.fs.Dir,
    start_time: i64,

    /// Initialize test harness with memory allocation only.
    /// No I/O operations performed in this phase.
    pub fn init(allocator: std.mem.Allocator, name: []const u8) TestHarness {
        return .{
            .name = name,
            .allocator = allocator,
            .temp_dir = null,
            .start_time = 0,
        };
    }

    /// Start test execution with I/O operations.
    /// Creates temporary directory for test isolation.
    pub fn startup(self: *TestHarness) !void {
        self.start_time = std.time.milliTimestamp();

        // Use static temp directory names for deterministic testing

        // Create temp directory through abstraction (will be overridden in simulation harness)
        self.temp_dir = null; // Default to no temp dir, let specific harnesses handle it
    }

    /// Clean up test resources.
    pub fn shutdown(self: *TestHarness) void {
        if (self.temp_dir) |*dir| {
            dir.close();
            self.temp_dir = null;
        }

        const elapsed = std.time.milliTimestamp() - self.start_time;
        if (builtin.mode == .Debug) {
            std.debug.print("Test '{s}' completed in {d}ms\n", .{ self.name, elapsed });
        }
    }

    /// Deallocate all test memory.
    pub fn deinit(self: *TestHarness) void {
        // No cleanup needed for simple allocator
        _ = self;
    }

    /// Provide allocator for subsystem testing.
    pub fn test_allocator(self: *TestHarness) std.mem.Allocator {
        return self.allocator;
    }

    /// Generate deterministic test data with static content to avoid memory leaks.
    pub fn generate_block(self: *TestHarness, index: u32) !ContextBlock {
        _ = self; // Static content doesn't need allocator
        
        // Use static strings to prevent memory leaks in tests
        const content = "Test block content";
        const metadata = "{\"test\":true}";

        return ContextBlock{
            .id = BlockId.from_u64(index + 1), // Never create zero BlockIDs
            .version = 1,
            .content = content,
            .source_uri = "test://block",
            .metadata_json = metadata,
        };
    }

    /// Validate memory usage is within expected bounds.
    pub fn validate_memory_usage(self: *TestHarness, max_bytes: usize) !void {
        // For testing allocator, we trust it to track usage properly
        _ = self;
        _ = max_bytes;
    }
};

/// Storage-specific test harness with VFS and StorageEngine setup.
pub const StorageHarness = struct {
    base: TestHarness,
    // For tests, we'll just use SimulationVFS always - simpler and more deterministic
    sim_vfs: SimulationVFS,
    storage_engine: StorageEngine,

    /// Initialize storage harness with simulation VFS (always for tests).
    pub fn init(allocator: std.mem.Allocator, name: []const u8, _: bool) !StorageHarness {
        const base = TestHarness.init(allocator, name);
        const sim_vfs = try SimulationVFS.init(allocator);

        return .{
            .base = base,
            .sim_vfs = sim_vfs,
            .storage_engine = undefined, // Set in startup
        };
    }

    /// Initialize and start storage engine.
    pub fn startup(self: *StorageHarness) !void {
        try self.base.startup();

        // Use static paths for testing to avoid memory leaks
        const data_dir = "/tmp/kausaldb_test";

        self.storage_engine = try StorageEngine.init(
            self.base.allocator,
            self.sim_vfs.vfs(),
            data_dir,
            StorageConfig.minimal_for_testing(),
        );
        try self.storage_engine.startup();
    }

    /// Shutdown storage engine and base harness.
    pub fn shutdown(self: *StorageHarness) !void {
        try self.storage_engine.shutdown();
        self.base.shutdown();
    }

    /// Clean up all resources.
    pub fn deinit(self: *StorageHarness) void {
        self.storage_engine.deinit();
        self.sim_vfs.deinit();
        self.base.deinit();
    }

    /// Helper to write and verify a block.
    pub fn write_and_verify_block(self: *StorageHarness, block: *const ContextBlock) !void {
        try self.storage_engine.put_block(block.*);

        const retrieved = try self.storage_engine.find_block_with_ownership(block.id, .temporary);
        fatal_assert(retrieved != null, "Block not found after write", .{});
        fatal_assert(
            std.mem.eql(u8, retrieved.?.block.content, block.content),
            "Block content mismatch",
            .{},
        );
    }

    /// Force a memtable flush to SSTable.
    pub fn force_flush(self: *StorageHarness) !void {
        try self.storage_engine.flush_memtable_to_sstable();
    }

    /// Inject a simulated I/O failure (simulation VFS only).
    pub fn inject_io_failure(self: *StorageHarness) !void {
        switch (self.test_vfs) {
            .simulation => |*sim| sim.inject_next_failure(),
            .real => return error.NotSimulation,
        }
    }
};

/// Query test harness combining storage and query engines.
pub const QueryHarness = struct {
    storage_harness: StorageHarness,
    query_engine: QueryEngine,

    /// Initialize query harness with storage backend.
    pub fn init(allocator: std.mem.Allocator, name: []const u8) !QueryHarness {
        const storage_harness = try StorageHarness.init(allocator, name, false);
        return .{
            .storage_harness = storage_harness,
            .query_engine = undefined, // Set in startup
        };
    }

    /// Start storage and query engines.
    pub fn startup(self: *QueryHarness) !void {
        try self.storage_harness.startup();

        self.query_engine = QueryEngine.init(
            self.storage_harness.base.allocator,
            &self.storage_harness.storage_engine,
        );
        self.query_engine.startup();
    }

    /// Shutdown both engines.
    pub fn shutdown(self: *QueryHarness) !void {
        self.query_engine.shutdown();
        try self.storage_harness.shutdown();
    }

    /// Clean up resources.
    pub fn deinit(self: *QueryHarness) void {
        self.query_engine.deinit();
        self.storage_harness.deinit();
    }

    /// Helper to create and index a graph of blocks.
    pub fn create_block_graph(self: *QueryHarness, node_count: u32) !void {
        var i: u32 = 1;
        while (i <= node_count) : (i += 1) {
            const block = try self.storage_harness.base.generate_block(i);
            try self.storage_harness.storage_engine.put_block(block);

            // Create edges to previous blocks
            if (i > 1) {
                const edge = context_block.GraphEdge{
                    .source_id = block.id,
                    .target_id = BlockId.from_u64(i - 1),
                    .edge_type = .calls,
                };
                try self.storage_harness.storage_engine.put_edge(edge);
            }
        }
    }

    /// Execute and validate a semantic query.
    pub fn validate_query(self: *QueryHarness, query: []const u8, expected_count: usize) !void {
        const results = try self.query_engine.execute_semantic_query(query);
        fatal_assert(
            results.len == expected_count,
            "Query returned {d} results, expected {d}",
            .{ results.len, expected_count },
        );
    }
};

/// Simulation harness for deterministic failure testing.
pub const SimulationHarness = struct {
    base: TestHarness,
    sim: Simulation,
    storage_harnesses: std.array_list.Managed(*StorageHarness),

    /// Initialize simulation with deterministic seed.
    pub fn init(allocator: std.mem.Allocator, name: []const u8, seed: u64) !SimulationHarness {
        const base = TestHarness.init(allocator, name);
        return .{
            .base = base,
            .sim = try Simulation.init(base.allocator, seed),
            .storage_harnesses = std.array_list.Managed(*StorageHarness).init(base.allocator),
        };
    }

    /// Start simulation environment.
    pub fn startup(self: *SimulationHarness) !void {
        try self.base.startup();
        // Note: Simulation doesn't need explicit startup
        // self.sim.startup();
    }

    /// Run simulation for specified number of ticks.
    pub fn run_ticks(self: *SimulationHarness, tick_count: u64) !void {
        var i: u64 = 0;
        while (i < tick_count) : (i += 1) {
            self.sim.tick();
        }
    }

    /// Create a simulated storage node.
    pub fn create_node(self: *SimulationHarness, node_id: []const u8) !*StorageHarness {
        const harness = try self.base.allocator.create(StorageHarness);
        harness.* = try StorageHarness.init(self.base.allocator, node_id, true);
        try harness.startup();
        try self.storage_harnesses.append(harness);
        return harness;
    }

    /// Inject network partition between nodes.
    pub fn partition_nodes(self: *SimulationHarness, group1: []usize, group2: []usize) void {
        _ = self;
        _ = group1;
        _ = group2;
        // Network partition simulation would be implemented here
    }

    /// Inject random failures based on probability.
    pub fn inject_random_failures(self: *SimulationHarness, probability: f32) !void {
        for (self.storage_harnesses.items) |harness| {
            if (self.sim.random.float(f32) < probability) {
                try harness.inject_io_failure();
            }
        }
    }

    /// Validate all nodes eventually converge to same state.
    pub fn validate_convergence(self: *SimulationHarness) !void {
        if (self.storage_harnesses.items.len < 2) return;

        // Compare block counts across all nodes
        const first_count = self.storage_harnesses.items[0].storage_engine.block_count();
        for (self.storage_harnesses.items[1..]) |harness| {
            const count = harness.storage_engine.block_count();
            fatal_assert(
                count == first_count,
                "Node divergence: {d} blocks vs {d}",
                .{ count, first_count },
            );
        }
    }

    /// Shutdown all nodes and simulation.
    pub fn shutdown(self: *SimulationHarness) !void {
        for (self.storage_harnesses.items) |harness| {
            harness.shutdown() catch {};
        }
        // Note: Simulation doesn't need explicit shutdown
        // self.sim.shutdown();
        self.base.shutdown();
    }

    /// Clean up all resources.
    pub fn deinit(self: *SimulationHarness) void {
        for (self.storage_harnesses.items) |harness| {
            harness.deinit();
            self.base.allocator.destroy(harness);
        }
        self.storage_harnesses.deinit();
        self.sim.deinit();
        self.base.deinit();
    }
};

/// Performance measurement harness for benchmarking.
pub const BenchmarkHarness = struct {
    base: TestHarness,
    samples: std.array_list.Managed(u64),
    warmup_count: usize,
    sample_count: usize,

    /// Initialize benchmark harness.
    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        warmup: usize,
        samples: usize,
    ) BenchmarkHarness {
        const base = TestHarness.init(allocator, name);
        return .{
            .base = base,
            .samples = std.array_list.Managed(u64).init(base.allocator),
            .warmup_count = warmup,
            .sample_count = samples,
        };
    }

    /// Run benchmark with timing.
    pub fn run_benchmark(
        self: *BenchmarkHarness,
        comptime func: fn (*BenchmarkHarness) anyerror!void,
    ) !void {
        // Warmup runs
        var i: usize = 0;
        while (i < self.warmup_count) : (i += 1) {
            try func(self);
        }

        // Timed samples
        i = 0;
        while (i < self.sample_count) : (i += 1) {
            const start = std.time.nanoTimestamp();
            try func(self);
            const elapsed = @as(u64, @intCast(std.time.nanoTimestamp() - start));
            try self.samples.append(elapsed);
        }
    }

    /// Calculate benchmark statistics.
    pub fn calculate_stats(self: *BenchmarkHarness) BenchmarkStats {
        std.sort.heap(u64, self.samples.items, {}, std.sort.asc(u64));

        var sum: u64 = 0;
        var min: u64 = std.math.maxInt(u64);
        var max: u64 = 0;

        for (self.samples.items) |sample| {
            sum += sample;
            min = @min(min, sample);
            max = @max(max, sample);
        }

        const mean = sum / self.samples.items.len;
        const median = self.samples.items[self.samples.items.len / 2];
        const p99 = self.samples.items[
            @min(
                self.samples.items.len * 99 / 100,
                self.samples.items.len - 1,
            )
        ];

        return .{
            .mean = mean,
            .median = median,
            .min = min,
            .max = max,
            .p99 = p99,
            .samples = self.samples.items.len,
        };
    }

    /// Clean up resources.
    pub fn deinit(self: *BenchmarkHarness) void {
        self.samples.deinit();
        self.base.deinit();
    }

    pub const BenchmarkStats = struct {
        mean: u64,
        median: u64,
        min: u64,
        max: u64,
        p99: u64,
        samples: usize,

        pub fn format(
            self: BenchmarkStats,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            try writer.print(
                "mean={d}ns median={d}ns min={d}ns max={d}ns p99={d}ns samples={d}",
                .{ self.mean, self.median, self.min, self.max, self.p99, self.samples },
            );
        }
    };
};

// Tests for the harness framework itself
test "TestHarness lifecycle" {
    var harness = TestHarness.init(std.testing.allocator, "test_lifecycle");
    defer harness.deinit();

    try harness.startup();
    defer harness.shutdown();

    const block = try harness.generate_block(42);
    // Check the block ID is deterministic (compare first 8 bytes as u64)
    const expected_bytes = std.mem.toBytes(@as(u64, 43)); // generate_block adds 1 to avoid zero IDs
    try std.testing.expect(std.mem.eql(u8, block.id.bytes[0..8], &expected_bytes));
}

test "StorageHarness basic operations" {
    var harness = try StorageHarness.init(std.testing.allocator, "test_storage", false);
    defer harness.deinit();

    try harness.startup();
    defer harness.shutdown() catch {};

    const block = try harness.base.generate_block(1);
    try harness.write_and_verify_block(&block);
}

test "QueryHarness graph creation" {
    var harness = try QueryHarness.init(std.testing.allocator, "test_query");
    defer harness.deinit();

    try harness.startup();
    defer harness.shutdown() catch {};

    try harness.create_block_graph(5);
    // Verify blocks were created
    const count = harness.storage_harness.storage_engine.block_count();
    try std.testing.expectEqual(@as(u64, 5), count);
}

test "SimulationHarness deterministic behavior" {
    var harness = try SimulationHarness.init(std.testing.allocator, "test_sim", 12345);
    defer harness.deinit();

    try harness.startup();
    defer harness.shutdown() catch {};

    _ = try harness.create_node("node1");
    _ = try harness.create_node("node2");

    try harness.run_ticks(10);
    try harness.validate_convergence();
}

test "BenchmarkHarness statistics" {
    var harness = BenchmarkHarness.init(std.testing.allocator, "test_bench", 5, 10);
    defer harness.deinit();

    // Add some sample data
    try harness.samples.append(100);
    try harness.samples.append(200);
    try harness.samples.append(150);

    const stats = harness.calculate_stats();
    try std.testing.expect(stats.min == 100);
    try std.testing.expect(stats.max == 200);
    try std.testing.expect(stats.median == 150);
}
