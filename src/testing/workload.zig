//! Workload generation for deterministic simulation testing.
//!
//! Provides deterministic, seeded generation of realistic operation sequences
//! for property-based testing. Operations represent actual API calls that
//! users would make, not internal storage operations.
//!
//! Design rationale: Realistic workloads expose bugs that artificial test
//! patterns miss. Deterministic generation enables exact reproduction of
//! failures using seeds.

const std = @import("std");
const testing = std.testing;

const types = @import("../core/types.zig");

const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const EdgeType = types.EdgeType;
const GraphEdge = types.GraphEdge;

/// Operation types that can be performed on the system
/// These represent actual API operations, not internal storage operations
pub const OperationType = enum {
    put_block,
    update_block,
    find_block,
    delete_block,
    put_edge,
    find_edges,
};

/// Configuration for operation mix in workload generation
/// Represents realistic API usage patterns, not internal storage operations
pub const OperationMix = struct {
    put_block_weight: u32 = 35, // Primary write operations
    update_block_weight: u32 = 10, // Block sequence updates
    find_block_weight: u32 = 35, // Primary read operations
    delete_block_weight: u32 = 5, // Occasional deletions
    put_edge_weight: u32 = 10, // Graph relationship creation
    find_edges_weight: u32 = 5, // Graph traversal queries

    /// Calculate total weight for probability distribution
    pub fn total_weight(self: OperationMix) u32 {
        return self.put_block_weight +
            self.update_block_weight +
            self.find_block_weight +
            self.delete_block_weight +
            self.put_edge_weight +
            self.find_edges_weight;
    }
};

/// Single operation in the workload
pub const Operation = struct {
    op_type: OperationType,
    block_id: ?BlockId = null,
    block: ?ContextBlock = null,
    edge: ?GraphEdge = null,
    model_sequence: u64,
};

/// Deterministic workload generator for realistic operation patterns
pub const WorkloadGenerator = struct {
    allocator: std.mem.Allocator,
    prng: std.Random.DefaultPrng,
    operation_mix: OperationMix,
    operation_count: u64,
    workload_sequence: u64,
    block_counter: u32,
    edge_counter: u32,
    config: WorkloadConfig,
    created_blocks: std.array_list.Managed(BlockId),

    const Self = @This();

    // Import WorkloadConfig from harness
    const WorkloadConfig = @import("harness.zig").WorkloadConfig;

    /// Initialize workload generator with deterministic seed
    pub fn init(allocator: std.mem.Allocator, seed: u64, mix: OperationMix, config: WorkloadConfig) Self {
        return Self{
            .allocator = allocator,
            .prng = std.Random.DefaultPrng.init(seed),
            .operation_mix = mix,
            .operation_count = 0,
            .workload_sequence = 0,
            .block_counter = 0,
            .edge_counter = 0,
            .config = config,
            .created_blocks = std.array_list.Managed(BlockId).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.created_blocks.deinit();
    }

    /// Update workload configuration after initialization
    pub fn update_config(self: *Self, new_config: WorkloadConfig) void {
        self.config = new_config;
    }

    /// Generate next operation in deterministic sequence
    /// For edge operations, existing_blocks should contain valid block IDs to ensure referential integrity
    pub fn generate_operation(self: *Self) !Operation {
        const random = self.prng.random();
        const total = self.operation_mix.total_weight();
        const choice = random.uintLessThan(u32, total);

        var cumulative: u32 = 0;
        const op_type: OperationType = blk: {
            cumulative += self.operation_mix.put_block_weight;
            if (choice < cumulative) break :blk .put_block;

            cumulative += self.operation_mix.update_block_weight;
            if (choice < cumulative) break :blk .update_block;

            cumulative += self.operation_mix.find_block_weight;
            if (choice < cumulative) break :blk .find_block;

            cumulative += self.operation_mix.delete_block_weight;
            if (choice < cumulative) break :blk .delete_block;

            cumulative += self.operation_mix.put_edge_weight;
            if (choice < cumulative) break :blk .put_edge;

            break :blk .find_edges;
        };

        // Increment workload sequence before generating to get unique sequence numbers
        self.workload_sequence += 1;

        const operation = switch (op_type) {
            .put_block => try self.generate_put_block(),
            .update_block => try self.generate_update_block(),
            .find_block => try self.generate_find_block(),
            .delete_block => try self.generate_delete_block(),
            .put_edge => try self.generate_put_edge(),
            .find_edges => try self.generate_find_edges(),
        };

        return operation;
    }

    /// Generate put_block operation with realistic test data
    fn generate_put_block(self: *Self) !Operation {
        self.block_counter += 1;
        const block = try self.create_test_block(self.block_counter);

        // Track this block so we can create edges to it later
        try self.created_blocks.append(block.id);

        return Operation{
            .op_type = .put_block,
            .block = block,
            .model_sequence = self.workload_sequence,
        };
    }

    /// Generate update_block operation for existing block with higher sequence
    fn generate_update_block(self: *Self) !Operation {
        const random = self.prng.random();

        // If no blocks exist yet, create a new block instead
        if (self.created_blocks.items.len == 0) {
            return self.generate_put_block();
        }

        // Choose an existing block to update
        const block_index = random.uintLessThan(usize, self.created_blocks.items.len);
        const existing_block_id = self.created_blocks.items[block_index];

        // Create updated sequence with higher sequence number
        const block = try self.create_updated_block(existing_block_id);

        return Operation{
            .op_type = .update_block,
            .block = block,
            .model_sequence = self.workload_sequence,
        };
    }

    /// Generate find_block operation for existing or random block
    fn generate_find_block(self: *Self) !Operation {
        const random = self.prng.random();
        const block_id = if (self.block_counter > 0 and random.boolean())
            self.deterministic_block_id(random.uintLessThan(u32, self.block_counter) + 1)
        else
            self.random_block_id();

        return Operation{
            .op_type = .find_block,
            .block_id = block_id,
            .model_sequence = self.workload_sequence,
        };
    }

    /// Generate delete_block operation for existing block
    fn generate_delete_block(self: *Self) !Operation {
        const random = self.prng.random();
        const block_id = if (self.block_counter > 0)
            self.deterministic_block_id(random.uintLessThan(u32, self.block_counter) + 1)
        else
            self.random_block_id();

        return Operation{
            .op_type = .delete_block,
            .block_id = block_id,
            .model_sequence = self.workload_sequence,
        };
    }

    /// Generate put_edge operation between blocks
    fn generate_put_edge(self: *Self) !Operation {
        // If we don't have enough blocks yet, create a block instead
        if (self.created_blocks.items.len < 2) {
            return self.generate_put_block();
        }

        const random = self.prng.random();

        // Select source and target from created blocks
        const source_idx = random.uintLessThan(usize, self.created_blocks.items.len);
        var target_idx = random.uintLessThan(usize, self.created_blocks.items.len);

        // Ensure source != target
        while (target_idx == source_idx and self.created_blocks.items.len > 1) {
            target_idx = random.uintLessThan(usize, self.created_blocks.items.len);
        }

        const source_id = self.created_blocks.items[source_idx];
        const target_id = self.created_blocks.items[target_idx];

        const edge_types = [_]EdgeType{ .calls, .imports, .defined_in, .references };
        const edge_type = edge_types[random.uintLessThan(usize, edge_types.len)];

        const edge = GraphEdge{
            .source_id = source_id,
            .target_id = target_id,
            .edge_type = edge_type,
        };

        self.edge_counter += 1;

        return Operation{
            .op_type = .put_edge,
            .edge = edge,
            .model_sequence = self.workload_sequence,
        };
    }

    /// Generate find_edges operation for graph traversal
    fn generate_find_edges(self: *Self) !Operation {
        const random = self.prng.random();
        const block_id = if (self.block_counter > 0 and random.boolean())
            self.deterministic_block_id(random.uintLessThan(u32, self.block_counter) + 1)
        else
            self.random_block_id();

        return Operation{
            .op_type = .find_edges,
            .block_id = block_id,
            .model_sequence = self.workload_sequence,
        };
    }

    /// Create test block with realistic content
    fn create_test_block(self: *Self, block_number: u32) !ContextBlock {
        const random = self.prng.random();

        // Generate deterministic but varied content
        const content_templates = [_][]const u8{
            "pub fn test_function_{d}() void {{\n    // Test implementation\n}}",
            "const TestStruct_{d} = struct {{\n    value: u32,\n}};",
            "// Test comment block {d}\n// This is documentation",
            "import std.testing;\ntest \"test_{d}\" {{\n    // Test body\n}}",
        };

        const template_index = random.uintLessThan(usize, content_templates.len);
        var content = switch (template_index) {
            0 => try std.fmt.allocPrint(self.allocator, "pub fn test_function_{d}() void {{\n    // Test implementation\n}}", .{block_number}),
            1 => try std.fmt.allocPrint(self.allocator, "const TestStruct_{d} = struct {{\n    value: u32,\n}};", .{block_number}),
            2 => try std.fmt.allocPrint(self.allocator, "// Test comment block {d}\n// This is documentation", .{block_number}),
            3 => try std.fmt.allocPrint(self.allocator, "import std.testing;\ntest \"test_{d}\" {{\n    // Test body\n}}", .{block_number}),
            else => try std.fmt.allocPrint(self.allocator, "pub fn test_function_{d}() void {{\n    // Test implementation\n}}", .{block_number}),
        };

        // Add unicode content if configured
        if (self.config.generate_unicode_metadata and random.float(f32) < 0.3) {
            const original_content = content;
            content = try std.fmt.allocPrint(self.allocator, "{s}\n// Unicode: 测试内容 🚀", .{original_content});
            self.allocator.free(original_content);
        }

        // Generate metadata based on configuration
        var metadata: []const u8 = undefined;
        if (self.config.generate_rich_metadata) {
            metadata = try std.fmt.allocPrint(self.allocator, "{{\"function\": \"test_{d}\", \"line_count\": {d}, \"complexity\": {d}, \"language\": \"zig\"}}", .{ block_number, random.uintLessThan(u32, 50) + 1, random.uintLessThan(u32, 10) + 1 });
        } else {
            metadata = try std.fmt.allocPrint(self.allocator, "{{\"function\": \"test_{d}\"}}", .{block_number});
        }

        return ContextBlock{
            .id = self.deterministic_block_id(block_number),
            .source_uri = try std.fmt.allocPrint(self.allocator, "/test/file_{d}.zig", .{block_number}),
            .content = content,
            .metadata_json = metadata,
            .sequence = 0, // Storage engine will assign the actual global sequence
        };
    }

    /// Create updated sequence of existing block with higher sequence number
    fn create_updated_block(self: *Self, existing_block_id: BlockId) !ContextBlock {
        const random = self.prng.random();

        // Generate new sequence number (increment from base sequence)
        const new_sequence = random.uintAtMost(u64, 10) + 2; // Sequence 2-12

        const source_uri = try std.fmt.allocPrint(
            self.allocator,
            "/test/updated_file_v{d}.zig",
            .{new_sequence},
        );

        // Create updated content
        const content = try std.fmt.allocPrint(
            self.allocator,
            \\// Updated sequence {d}
            \\pub fn updated_function() void {{
            \\    // Updated implementation
            \\    const updated_value = {d};
            \\}}
        ,
            .{ new_sequence, random.uintLessThan(u32, 1000) },
        );

        // Create updated metadata
        const metadata = try std.fmt.allocPrint(
            self.allocator,
            \\{{"type": "function", "sequence": {d}, "updated": true}}
        ,
            .{new_sequence},
        );

        return ContextBlock{
            .id = existing_block_id, // Same ID as existing block
            .source_uri = source_uri,
            .content = content,
            .metadata_json = metadata,
            .sequence = new_sequence, // Higher sequence number
        };
    }

    /// Generate deterministic block ID from counter
    fn deterministic_block_id(self: *Self, counter: u32) BlockId {
        _ = self;
        var bytes: [16]u8 = undefined;
        std.mem.writeInt(u32, bytes[0..4], counter, .little);
        std.mem.writeInt(u32, bytes[4..8], 0xDEADBEEF, .little);
        std.mem.writeInt(u32, bytes[8..12], 0xCAFEBABE, .little);
        std.mem.writeInt(u32, bytes[12..16], counter ^ 0xFFFFFFFF, .little);
        return BlockId.from_bytes(bytes);
    }

    /// Generate random block ID for testing non-existent blocks
    fn random_block_id(self: *Self) BlockId {
        const random = self.prng.random();
        var bytes: [16]u8 = undefined;
        random.bytes(&bytes);
        return BlockId.from_bytes(bytes);
    }

    /// Clean up operation-allocated resources
    pub fn cleanup_operation(self: *Self, operation: *const Operation) void {
        if (operation.block) |block| {
            self.allocator.free(block.source_uri);
            self.allocator.free(block.content);
            self.allocator.free(block.metadata_json);
        }
    }

    /// Confirm operation success and increment counter
    /// Only called by SimulationRunner when storage operation succeeds
    pub fn confirm_operation_success(self: *Self) void {
        self.operation_count += 1;
    }
};

test "workload generator creates deterministic operations" {
    const allocator = testing.allocator;

    const mix = OperationMix{
        .put_block_weight = 50,
        .find_block_weight = 50,
    };

    const config = @import("harness.zig").WorkloadConfig{};
    var generator = WorkloadGenerator.init(allocator, 0x12345, mix, config);
    defer generator.deinit();

    // Generate operations
    var op1 = try generator.generate_operation();
    defer generator.cleanup_operation(&op1);
    var op2 = try generator.generate_operation();
    defer generator.cleanup_operation(&op2);

    // Should generate valid operations
    try testing.expect(op1.model_sequence < op2.model_sequence);
}

test "operation mix calculates correct total weight" {
    const mix = OperationMix{
        .put_block_weight = 10,
        .update_block_weight = 5,
        .find_block_weight = 15,
        .delete_block_weight = 5,
        .put_edge_weight = 3,
        .find_edges_weight = 7,
    };

    try testing.expectEqual(@as(u32, 45), mix.total_weight());
}

test "deterministic block ID generation" {
    const allocator = testing.allocator;
    const mix = OperationMix{};
    const config = @import("harness.zig").WorkloadConfig{};
    var generator = WorkloadGenerator.init(allocator, 0x12345, mix, config);

    // Same counter should produce same ID
    const id1 = generator.deterministic_block_id(42);
    const id2 = generator.deterministic_block_id(42);
    try testing.expect(id1.eql(id2));

    // Different counters should produce different IDs
    const id3 = generator.deterministic_block_id(43);
    try testing.expect(!id1.eql(id3));
}
