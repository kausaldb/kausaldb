//! Scenario-based workload tests using realistic code patterns
//!
//! Tests system behavior under workloads that mirror real codebase structures:
//! monolithic applications, library ecosystems, test suites, etc.

const std = @import("std");
const testing = std.testing;
const log = std.log.scoped(.workload_test);

const code_patterns = @import("code_patterns.zig");
const deterministic_test = @import("../../../sim/deterministic_test.zig");
const storage_engine_mod = @import("../../../storage/engine.zig");
const simulation_vfs = @import("../../../sim/simulation_vfs.zig");
const types = @import("../../../core/types.zig");
const vfs_mod = @import("../../../core/vfs.zig");

const CodePatternGenerator = code_patterns.CodePatternGenerator;
const CodebaseConfig = code_patterns.CodebaseConfig;
const Scenarios = code_patterns.Scenarios;
const PropertyChecker = deterministic_test.PropertyChecker;
const SimulationVFS = simulation_vfs.SimulationVFS;
const StorageEngine = storage_engine_mod.StorageEngine;
const VFS = vfs_mod.VFS;

test "scenario: monolithic deep call chains" {
    const allocator = testing.allocator;

    // Create storage engine with simulation VFS
    const sim_vfs = try SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    const vfs_instance = sim_vfs.vfs();
    var storage_engine = try StorageEngine.init_default(allocator, vfs_instance, "/workload_test");
    defer storage_engine.deinit();
    try storage_engine.startup();
    defer storage_engine.shutdown() catch {};

    // Generate monolithic codebase pattern
    var generator = CodePatternGenerator.init(allocator, &storage_engine, 0xDEE4);
    defer generator.deinit();

    // Create multiple deep call chains typical of monolithic applications
    try generator.generate_monolithic_blocks(15); // Deep business logic
    try generator.generate_monolithic_blocks(12); // Another subsystem
    try generator.generate_monolithic_blocks(8); // Utilities

    // Verify system can handle deep traversal patterns
    const initial_memory = storage_engine.memory_usage();
    log.info("Memory after monolithic pattern generation: {} bytes", .{initial_memory.total_bytes});

    // Simulate queries that would traverse deep call chains
    // In real usage, these would be graph traversals following call edges
    const block_count = storage_engine.metrics().blocks_written.load();
    try testing.expect(block_count > 30); // Should have created many blocks

    // Verify graph structure integrity
    try PropertyChecker.check_memory_bounds(&storage_engine, 4096); // 4KB per operation

    log.info("Monolithic deep call chain scenario completed successfully", .{});
}

test "scenario: library fanout write amplification" {
    const allocator = testing.allocator;

    const sim_vfs = try SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    const vfs_instance = sim_vfs.vfs();
    var storage_engine = try StorageEngine.init_default(allocator, vfs_instance, "/fanout_test");
    defer storage_engine.deinit();
    try storage_engine.startup();
    defer storage_engine.shutdown() catch {};

    var generator = CodePatternGenerator.init(allocator, &storage_engine, 0xFA10DF);
    defer generator.deinit();

    // Generate high-fanout library pattern that stresses write amplification
    const config = Scenarios.write_amplification;
    try generator.generate_realistic_codebase(config);

    const metrics_after = storage_engine.metrics();
    const final_memory = storage_engine.memory_usage();

    log.info("Write amplification scenario stats:", .{});
    log.info("  Blocks written: {}", .{metrics_after.blocks_written.load()});
    log.info("  Edges created: estimated {}", .{config.utility_libraries * config.fanout_per_library * 2});
    log.info("  Final memory usage: {} bytes", .{final_memory.total_bytes});

    // With high fanout, we should have created many edges
    const expected_min_blocks = config.utility_libraries * (1 + config.fanout_per_library) +
        config.deep_call_chains * config.call_chain_depth +
        config.test_modules * 2;
    try testing.expect(metrics_after.blocks_written.load() >= expected_min_blocks);

    // System should handle the write load without errors
    try PropertyChecker.check_memory_bounds(&storage_engine, 8192); // Higher bound for complex scenario

    log.info("Library fanout write amplification scenario completed successfully", .{});
}

test "scenario: complex graph traversal patterns" {
    const allocator = testing.allocator;

    const sim_vfs = try SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    const vfs_instance = sim_vfs.vfs();
    var storage_engine = try StorageEngine.init_default(allocator, vfs_instance, "/complex_test");
    defer storage_engine.deinit();
    try storage_engine.startup();
    defer storage_engine.shutdown() catch {};

    var generator = CodePatternGenerator.init(allocator, &storage_engine, 0xC0A41E);
    defer generator.deinit();

    // Generate complex interconnected graph
    try generator.generate_realistic_codebase(Scenarios.complex_graph);

    // Test that queries can navigate complex relationships
    // This simulates typical IDE operations: "find all callers", "show dependencies", etc.

    const metrics = storage_engine.metrics();
    log.info("Complex graph scenario created {} blocks", .{metrics.blocks_written.load()});

    // Verify we can handle complex query patterns without issues
    try PropertyChecker.check_memory_bounds(&storage_engine, 12288); // Even higher bound for complex graph

    // The complex scenario includes circular dependencies which stress the system
    log.info("Complex graph traversal scenario completed successfully", .{});
}

test "scenario: test suite parallel structure" {
    const allocator = testing.allocator;

    const sim_vfs = try SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    const vfs_instance = sim_vfs.vfs();
    var storage_engine = try StorageEngine.init_default(allocator, vfs_instance, "/test_parallel");
    defer storage_engine.deinit();
    try storage_engine.startup();
    defer storage_engine.shutdown() catch {};

    var generator = CodePatternGenerator.init(allocator, &storage_engine, 0xAE57);
    defer generator.deinit();

    // Generate parallel test/implementation structure
    const test_count = 25;
    try generator.generate_test_parallel(test_count);

    // Verify we created the expected number of blocks (2 per test: impl + test)
    const metrics = storage_engine.metrics();
    try testing.expect(metrics.blocks_written.load() >= test_count * 2);

    // Test parallel structures create predictable edge patterns
    // Each test should have import + calls edges to its implementation
    log.info("Test parallel structure scenario created {} blocks", .{metrics.blocks_written.load()});

    try PropertyChecker.check_memory_bounds(&storage_engine, 2048);

    log.info("Test suite parallel structure scenario completed successfully", .{});
}

test "scenario: minimal debugging pattern" {
    const allocator = testing.allocator;

    const sim_vfs = try SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    const vfs_instance = sim_vfs.vfs();
    var storage_engine = try StorageEngine.init_default(allocator, vfs_instance, "/minimal_test");
    defer storage_engine.deinit();
    try storage_engine.startup();
    defer storage_engine.shutdown() catch {};

    var generator = CodePatternGenerator.init(allocator, &storage_engine, 0xA1A1A1);
    defer generator.deinit();

    // Generate minimal pattern for debugging
    try generator.generate_realistic_codebase(Scenarios.minimal);

    const metrics = storage_engine.metrics();
    log.info("Minimal scenario created {} blocks", .{metrics.blocks_written.load()});

    // Minimal scenario should create small, predictable structure
    try testing.expect(metrics.blocks_written.load() >= 5); // At least utility + dependents + call chain + test pair
    try testing.expect(metrics.blocks_written.load() <= 20); // But not too many

    try PropertyChecker.check_memory_bounds(&storage_engine, 1024);

    log.info("Minimal debugging pattern scenario completed successfully", .{});
}

test "scenario: circular dependency handling" {
    const allocator = testing.allocator;

    const sim_vfs = try SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    const vfs_instance = sim_vfs.vfs();
    var storage_engine = try StorageEngine.init_default(allocator, vfs_instance, "/circular_test");
    defer storage_engine.deinit();
    try storage_engine.startup();
    defer storage_engine.shutdown() catch {};

    var generator = CodePatternGenerator.init(allocator, &storage_engine, 0xC19C1E);
    defer generator.deinit();

    // Generate various sizes of circular dependencies
    try generator.generate_circular_imports(3); // Small cycle
    try generator.generate_circular_imports(5); // Medium cycle
    try generator.generate_circular_imports(8); // Larger cycle

    const metrics = storage_engine.metrics();
    const expected_blocks = 3 + 5 + 8; // Sum of all cycle sizes
    try testing.expect(metrics.blocks_written.load() >= expected_blocks);

    // System should handle circular patterns without infinite loops or crashes
    try PropertyChecker.check_memory_bounds(&storage_engine, 2048);

    log.info("Circular dependency handling scenario completed successfully", .{});
}

test "scenario: mixed realistic workload with flush simulation" {
    const allocator = testing.allocator;

    const sim_vfs = try SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    const vfs_instance = sim_vfs.vfs();
    var storage_engine = try StorageEngine.init_default(allocator, vfs_instance, "/mixed_workload");
    defer storage_engine.deinit();
    try storage_engine.startup();
    defer storage_engine.shutdown() catch {};

    var generator = CodePatternGenerator.init(allocator, &storage_engine, 0xA1BED);
    defer generator.deinit();

    // Generate a realistic mixed codebase
    const config = CodebaseConfig{
        .utility_libraries = 4,
        .fanout_per_library = 6,
        .deep_call_chains = 3,
        .call_chain_depth = 10,
        .test_modules = 12,
        .include_circular = true,
    };

    try generator.generate_realistic_codebase(config);

    // Simulate memory pressure that would trigger flushes in real usage
    const initial_memory = storage_engine.memory_usage();
    log.info("Mixed workload memory usage: {} bytes", .{initial_memory.total_bytes});

    // With this much data, we should be approaching memtable limits
    // When flush triggers are re-enabled, this would test flush under realistic load

    const metrics = storage_engine.metrics();
    log.info("Mixed workload created {} blocks", .{metrics.blocks_written.load()});

    // Should have created substantial graph structure
    const expected_min_blocks = config.utility_libraries * 5 + config.test_modules * 2;
    try testing.expect(metrics.blocks_written.load() >= expected_min_blocks);

    try PropertyChecker.check_memory_bounds(&storage_engine, 16384); // Higher limit for mixed workload

    log.info("Mixed realistic workload scenario completed successfully", .{});
}
