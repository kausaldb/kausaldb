//! Simulation Testing Framework for KausalDB.
//!
//! Provides deterministic, property-based testing through controlled workload
//! generation and state tracking. Tests own their storage instances for clear
//! lifecycle management - the framework just helps generate operations and
//! verify properties.
//!
//! Design principle: Keep it simple. Tests should be obvious, not clever.

const std = @import("std");
const builtin = @import("builtin");

// Core imports
const assert_mod = @import("../core/assert.zig");
const types = @import("../core/types.zig");
const vfs = @import("../core/vfs.zig");

// Storage imports
const storage_engine = @import("../storage/engine.zig");

// Re-declarations
const assert = assert_mod.assert;
const fatal_assert = assert_mod.fatal_assert;
const log = std.log.scoped(.simple_runner);

// Type aliases
const Allocator = std.mem.Allocator;
const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const GraphEdge = types.GraphEdge;
const EdgeType = types.EdgeType;
const StorageEngine = storage_engine.StorageEngine;
const SimulationVFS = vfs.SimulationVFS;
const VFS = vfs.VFS;

/// Simple operation for applying to storage.
pub const Operation = struct {
    op_type: OperationType,
    block: ?ContextBlock = null,
    edge: ?GraphEdge = null,
    block_id: ?BlockId = null,
};

pub const OperationType = enum {
    put_block,
    find_block,
    delete_block,
    put_edge,
    find_edges,
};

/// Configuration for flush behavior during testing.
pub const FlushConfig = struct {
    operation_threshold: u64 = 1000,
    memory_threshold: u64 = 16 * 1024 * 1024, // 16MB default
    enable_memory_trigger: bool = true,
    enable_operation_trigger: bool = true,
};

/// Predefined code graph scenarios for testing different patterns.
pub const CodeGraphScenario = enum {
    monolithic_deep, // Deep call chains in monolithic codebases
    library_fanout, // Utility libraries used by many files
    circular_imports, // Circular dependency patterns
    test_parallel, // Parallel test/implementation structure

    /// Get human-readable description of scenario.
    pub fn description(self: CodeGraphScenario) []const u8 {
        return switch (self) {
            .monolithic_deep => "Monolithic codebase with deep call chains",
            .library_fanout => "Library with high fan-out dependencies",
            .circular_imports => "Circular import patterns",
            .test_parallel => "Parallel test and implementation structure",
        };
    }

    /// Get recommended operation mix for this scenario.
    pub fn operation_mix(self: CodeGraphScenario) OperationMix {
        return switch (self) {
            .monolithic_deep => .{
                .put_block_weight = 30,
                .find_block_weight = 40,
                .delete_block_weight = 5,
                .put_edge_weight = 20,
                .find_edges_weight = 5,
            },
            .library_fanout => .{
                .put_block_weight = 20,
                .find_block_weight = 30,
                .delete_block_weight = 5,
                .put_edge_weight = 30,
                .find_edges_weight = 15,
            },
            .circular_imports => .{
                .put_block_weight = 25,
                .find_block_weight = 25,
                .delete_block_weight = 5,
                .put_edge_weight = 35,
                .find_edges_weight = 10,
            },
            .test_parallel => .{
                .put_block_weight = 40,
                .find_block_weight = 35,
                .delete_block_weight = 10,
                .put_edge_weight = 10,
                .find_edges_weight = 5,
            },
        };
    }
};

/// Configuration for operation mix in workload generation.
pub const OperationMix = struct {
    put_block_weight: u32 = 40,
    find_block_weight: u32 = 40,
    delete_block_weight: u32 = 5,
    put_edge_weight: u32 = 10,
    find_edges_weight: u32 = 5,
};

/// Lightweight model for tracking expected state.
pub const TestModel = struct {
    allocator: Allocator,
    blocks: std.AutoHashMap(BlockId, ContextBlock),
    edges: std.ArrayList(GraphEdge),
    operation_count: u64,

    pub fn init(allocator: Allocator) TestModel {
        return .{
            .allocator = allocator,
            .blocks = std.AutoHashMap(BlockId, ContextBlock).init(allocator),
            .edges = std.ArrayList(GraphEdge).init(allocator),
            .operation_count = 0,
        };
    }

    pub fn deinit(self: *TestModel) void {
        self.blocks.deinit();
        self.edges.deinit();
    }

    /// Track a successful operation in the model.
    pub fn track_operation(self: *TestModel, op: Operation) !void {
        self.operation_count += 1;

        switch (op.op_type) {
            .put_block => if (op.block) |block| {
                try self.blocks.put(block.id, block);
            },
            .delete_block => if (op.block_id) |id| {
                _ = self.blocks.remove(id);
            },
            .put_edge => if (op.edge) |edge| {
                try self.edges.append(edge);
            },
            else => {},
        }
    }

    /// Count active (non-deleted) blocks.
    pub fn count_active_blocks(self: *const TestModel) usize {
        return self.blocks.count();
    }

    /// Verify model state matches storage state.
    pub fn verify_against_storage(self: *const TestModel, engine: *StorageEngine) !void {
        // Skip verification if engine is not in readable state
        if (!engine.state.can_read()) {
            return;
        }

        // Check all model blocks exist in storage
        var iterator = self.blocks.iterator();
        while (iterator.next()) |entry| {
            const model_block = entry.value_ptr.*;
            const found = try engine.find_block(model_block.id, .query_engine);

            if (found == null) {
                log.err("Block {} exists in model but not in storage", .{model_block.id});
                return error.DataLossDetected;
            }
        }
    }
};

/// Simple deterministic operation generator.
pub const OperationGenerator = struct {
    allocator: Allocator,
    rng: std.Random.DefaultPrng,
    next_block_id: u64,

    pub fn init(allocator: Allocator, seed: u64) OperationGenerator {
        return .{
            .allocator = allocator,
            .rng = std.Random.DefaultPrng.init(seed),
            .next_block_id = 1,
        };
    }

    /// Generate a simple test block.
    pub fn generate_block(self: *OperationGenerator) !ContextBlock {
        const id = self.next_block_id;
        self.next_block_id += 1;

        var id_bytes: [16]u8 = undefined;
        std.mem.writeInt(u64, id_bytes[0..8], id, .little);
        std.mem.writeInt(u64, id_bytes[8..16], 0, .little);

        const content = try std.fmt.allocPrint(self.allocator, "Test block content {}", .{id});

        return ContextBlock{
            .id = BlockId.from_bytes(id_bytes),
            .uri = try std.fmt.allocPrint(self.allocator, "/test/block_{}.txt", .{id}),
            .content = content,
            .metadata = "{}",
            .version = 1,
        };
    }

    /// Generate a simple test edge.
    pub fn generate_edge(self: *OperationGenerator, source_id: BlockId, target_id: BlockId) GraphEdge {
        const edge_types = [_]EdgeType{ .imports, .calls, .defines, .references };
        const random = self.rng.random();
        const edge_type = edge_types[random.uintLessThan(usize, edge_types.len)];

        return GraphEdge{
            .source_id = source_id,
            .target_id = target_id,
            .edge_type = edge_type,
        };
    }

    /// Generate a random operation based on operation mix.
    pub fn generate_operation_with_mix(self: *OperationGenerator, mix: OperationMix) !Operation {
        const total = mix.put_block_weight + mix.find_block_weight + mix.delete_block_weight +
            mix.put_edge_weight + mix.find_edges_weight;
        const roll = self.rng.random().uintLessThan(u32, total);

        if (roll < mix.put_block_weight) {
            const block = try self.generate_block();
            return Operation{
                .op_type = .put_block,
                .block = block,
            };
        } else if (roll < mix.put_block_weight + mix.find_block_weight) {
            const id = self.rng.random().uintLessThan(u64, @max(1, self.next_block_id));
            var id_bytes: [16]u8 = undefined;
            std.mem.writeInt(u64, id_bytes[0..8], id, .little);
            std.mem.writeInt(u64, id_bytes[8..16], 0, .little);

            return Operation{
                .op_type = .find_block,
                .block_id = BlockId.from_bytes(id_bytes),
            };
        } else if (roll < mix.put_block_weight + mix.find_block_weight + mix.delete_block_weight) {
            const id = self.rng.random().uintLessThan(u64, @max(1, self.next_block_id));
            var id_bytes: [16]u8 = undefined;
            std.mem.writeInt(u64, id_bytes[0..8], id, .little);
            std.mem.writeInt(u64, id_bytes[8..16], 0, .little);

            return Operation{
                .op_type = .delete_block,
                .block_id = BlockId.from_bytes(id_bytes),
            };
        } else if (roll < mix.put_block_weight + mix.find_block_weight + mix.delete_block_weight + mix.put_edge_weight) {
            // Generate edge between potentially existing blocks
            if (self.next_block_id > 2) {
                const source_id = self.rng.random().uintLessThan(u64, self.next_block_id - 1) + 1;
                const target_id = self.rng.random().uintLessThan(u64, self.next_block_id - 1) + 1;

                if (source_id != target_id) {
                    var source_bytes: [16]u8 = undefined;
                    var target_bytes: [16]u8 = undefined;
                    std.mem.writeInt(u64, source_bytes[0..8], source_id, .little);
                    std.mem.writeInt(u64, source_bytes[8..16], 0, .little);
                    std.mem.writeInt(u64, target_bytes[0..8], target_id, .little);
                    std.mem.writeInt(u64, target_bytes[8..16], 0, .little);

                    const edge = self.generate_edge(BlockId.from_bytes(source_bytes), BlockId.from_bytes(target_bytes));

                    return Operation{
                        .op_type = .put_edge,
                        .edge = edge,
                    };
                }
            }
            // Fall through to find_edges if we can't create a valid edge
        }

        // Default to find_edges
        const id = self.rng.random().uintLessThan(u64, @max(1, self.next_block_id));
        var id_bytes: [16]u8 = undefined;
        std.mem.writeInt(u64, id_bytes[0..8], id, .little);
        std.mem.writeInt(u64, id_bytes[8..16], 0, .little);

        return Operation{
            .op_type = .find_edges,
            .block_id = BlockId.from_bytes(id_bytes),
        };
    }

    /// Generate a random operation based on simple weights (legacy interface).
    pub fn generate_operation(
        self: *OperationGenerator,
        put_weight: u8,
        find_weight: u8,
        delete_weight: u8,
    ) !Operation {
        const mix = OperationMix{
            .put_block_weight = put_weight,
            .find_block_weight = find_weight,
            .delete_block_weight = delete_weight,
            .put_edge_weight = 0,
            .find_edges_weight = 0,
        };
        return self.generate_operation_with_mix(mix);
    }
};

/// Apply an operation to storage and return success status.
pub fn apply_operation_to_storage(engine: *StorageEngine, op: Operation) !bool {
    switch (op.op_type) {
        .put_block => if (op.block) |block| {
            engine.put_block(block) catch |err| switch (err) {
                error.WriteStalled, error.WriteBlocked => return false,
                else => return err,
            };
            return true;
        },
        .find_block => if (op.block_id) |id| {
            _ = try engine.find_block(id, .query_engine);
            return true;
        },
        .delete_block => if (op.block_id) |id| {
            engine.delete_block(id) catch |err| switch (err) {
                error.BlockNotFound => return false,
                else => return err,
            };
            return true;
        },
        .put_edge => if (op.edge) |edge| {
            engine.put_edge(edge) catch |err| switch (err) {
                error.WriteStalled, error.WriteBlocked => return false,
                else => return err,
            };
            return true;
        },
        .find_edges => if (op.block_id) |id| {
            _ = try engine.find_edges_from(id, .query_engine);
            return true;
        },
    }
    return false;
}

/// Simple property checks without complex dependencies.
pub const PropertyChecks = struct {
    /// Verify no data loss between model and storage.
    pub fn check_no_data_loss(model: *const TestModel, engine: *StorageEngine) !void {
        // Skip if engine is not readable
        if (!engine.state.can_read()) {
            log.warn("Skipping data loss check - engine not readable (state={})", .{engine.state});
            return;
        }

        var missing_count: usize = 0;
        var iterator = model.blocks.iterator();

        while (iterator.next()) |entry| {
            const model_block = entry.value_ptr.*;
            const found = engine.find_block(model_block.id, .query_engine) catch |err| {
                log.err("Error finding block {}: {}", .{ model_block.id, err });
                return err;
            };

            if (found == null) {
                log.err("Data loss: Block {} missing from storage", .{model_block.id});
                missing_count += 1;
            }
        }

        if (missing_count > 0) {
            log.err("Total blocks missing: {}/{}", .{ missing_count, model.blocks.count() });
            return error.DataLossDetected;
        }
    }

    /// Check memory usage is within bounds.
    pub fn check_memory_bounds(engine: *StorageEngine, max_per_op: u64) !void {
        const usage = engine.memory_usage();
        const operations = engine.metrics.writes_completed + engine.metrics.reads_completed;

        if (operations == 0) return;

        const per_op = usage.total_bytes / operations;
        if (per_op > max_per_op) {
            log.err("Memory per operation {} exceeds limit {}", .{ per_op, max_per_op });
            return error.MemoryBoundsExceeded;
        }
    }
};

/// Simple test scenario runner that doesn't control storage lifecycle.
pub fn run_test_scenario(
    engine: *StorageEngine,
    model: *TestModel,
    generator: *OperationGenerator,
    operation_count: u64,
) !void {
    // Engine lifecycle is controlled by the test, not by this runner
    assert(engine.state.can_write());

    for (0..operation_count) |_| {
        const op = try generator.generate_operation(70, 20, 10);

        const success = try apply_operation_to_storage(engine, op);
        if (success) {
            try model.track_operation(op);
        }

        // Periodic verification
        if (model.operation_count % 100 == 0) {
            try PropertyChecks.check_no_data_loss(model, engine);
        }
    }

    // Final verification
    try model.verify_against_storage(engine);
}

/// Run test scenario with specific operation mix.
pub fn run_scenario_with_mix(
    engine: *StorageEngine,
    model: *TestModel,
    generator: *OperationGenerator,
    mix: OperationMix,
    operation_count: u64,
) !void {
    assert(engine.state.can_write());

    for (0..operation_count) |_| {
        const op = try generator.generate_operation_with_mix(mix);

        const success = try apply_operation_to_storage(engine, op);
        if (success) {
            try model.track_operation(op);
        }

        // Periodic verification
        if (model.operation_count % 100 == 0) {
            try PropertyChecks.check_no_data_loss(model, engine);
        }
    }

    // Final verification
    try model.verify_against_storage(engine);
}

/// Create a test storage engine with simulation VFS.
pub fn create_test_storage(allocator: Allocator, seed: u64, path: []const u8) !struct {
    vfs: *SimulationVFS,
    engine: *StorageEngine,
} {
    const sim_vfs = try allocator.create(SimulationVFS);
    sim_vfs.* = try SimulationVFS.init(allocator, seed);

    const engine = try allocator.create(StorageEngine);
    engine.* = try StorageEngine.init_default(allocator, sim_vfs.vfs(), path);

    return .{ .vfs = sim_vfs, .engine = engine };
}

/// Clean up test storage resources.
pub fn cleanup_test_storage(
    allocator: Allocator,
    sim_vfs: *SimulationVFS,
    engine: *StorageEngine,
) void {
    if (engine.state.can_write()) {
        engine.shutdown() catch {};
    }
    engine.deinit();
    allocator.destroy(engine);
    sim_vfs.deinit();
    allocator.destroy(sim_vfs);
}
