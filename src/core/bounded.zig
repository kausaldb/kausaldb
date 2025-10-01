//! Compile-time bounded collections for type-safe resource limits.
//!
//! Design rationale: Provides collections with compile-time maximum sizes to prevent
//! runtime buffer overflows and unbounded memory growth. All bounds are validated
//! at compile time where possible, with runtime checks only for dynamic indices.
//!
//! The bounded collections integrate with the TypedArena system and provide zero-cost
//! abstractions in release builds while maintaining comprehensive validation in debug builds.

const builtin = @import("builtin");
const std = @import("std");

const stdx = @import("stdx.zig");

/// Fixed-size array with compile-time maximum enforcement.
/// Prevents buffer overflows and provides O(1) append operations
/// up to the compile-time maximum size.
///
/// # Type Parameters
/// - `T`: Element type
/// - `max_size`: Compile-time maximum number of elements
///
/// # Design Principles
/// - Compile-time bounds prevent overflow
/// - Zero heap allocations (stack-allocated array)
/// - O(1) append, get, and clear operations
/// - Debug-mode validation for all operations
pub fn BoundedArrayType(
    comptime T: type,
    comptime max_size: usize,
) type {
    if (max_size == 0) {
        @compileError("bounded_array_type max_size must be greater than 0");
    }
    if (max_size > 1048576) {
        @compileError("bounded_array_type max_size too large: " ++ std.fmt.comptimePrint("{}", .{max_size}) ++ " (max: 1048576)");
    }

    return struct {
        const BoundedArray = @This();
        items: [max_size]T = undefined,
        len: usize = 0,

        const MAX_SIZE = max_size;

        /// Append element to the array.
        /// Returns error.Overflow if array is full.
        pub fn append(self: *BoundedArray, item: T) !void {
            if (self.len >= MAX_SIZE) {
                return error.Overflow;
            }

            if (builtin.mode == .Debug) {
                std.debug.assert(self.len < MAX_SIZE);
            }

            self.items[self.len] = item;
            self.len += 1;
        }

        /// Get element at index, returns null if index out of bounds.
        pub fn get(self: *const BoundedArray, index: usize) ?T {
            if (index >= self.len) {
                return null;
            }
            return self.items[index];
        }

        /// Query mutable reference to element at index.
        /// Returns null if index out of bounds.
        pub fn query_mut(self: *BoundedArray, index: usize) ?*T {
            if (index >= self.len) {
                return null;
            }
            return &self.items[index];
        }

        /// Get element at index with bounds checking.
        /// Panics if index out of bounds.
        pub fn at(self: *const BoundedArray, index: usize) T {
            if (!(index < self.len)) std.debug.panic("bounded_array_type index out of bounds: {} >= {}", .{ index, self.len });
            return self.items[index];
        }

        /// Remove and return the last element.
        /// Returns null if array is empty.
        pub fn pop(self: *BoundedArray) ?T {
            if (self.len == 0) {
                return null;
            }
            self.len -= 1;
            return self.items[self.len];
        }

        /// Remove element at index, shifting remaining elements left.
        /// Returns error.IndexOutOfBounds if index >= len.
        pub fn remove_at(self: *BoundedArray, index: usize) !T {
            if (index >= self.len) {
                return error.IndexOutOfBounds;
            }

            const item = self.items[index];

            if (index < self.len - 1) {
                stdx.copy_left(T, self.items[index .. self.len - 1], self.items[index + 1 .. self.len]);
            }

            self.len -= 1;
            return item;
        }

        /// Clear all elements, setting length to 0.
        /// Does not modify the underlying array data.
        pub fn clear(self: *BoundedArray) void {
            self.len = 0;
        }

        /// Get slice view of valid elements.
        /// The slice is valid until the next mutation operation.
        pub fn slice(self: *const BoundedArray) []const T {
            return self.items[0..self.len];
        }

        /// Get mutable slice view of valid elements.
        /// The slice is valid until the next mutation operation.
        pub fn slice_mut(self: *BoundedArray) []T {
            return self.items[0..self.len];
        }

        /// Check if array is empty.
        pub fn is_empty(self: *const BoundedArray) bool {
            return self.len == 0;
        }

        /// Check if array is full.
        pub fn is_full(self: *const BoundedArray) bool {
            return self.len == MAX_SIZE;
        }

        /// Get compile-time maximum size.
        pub fn max_length() usize {
            return MAX_SIZE;
        }

        /// Get remaining capacity.
        pub fn remaining_capacity(self: *const BoundedArray) usize {
            return MAX_SIZE - self.len;
        }

        /// Try to reserve capacity for n additional elements.
        /// Returns error.Overflow if not enough space.
        pub fn try_reserve(self: *const BoundedArray, additional: usize) !void {
            if (self.len + additional > MAX_SIZE) {
                return error.Overflow;
            }
        }

        /// Find first index of item, returns null if not found.
        pub fn find_index(self: *const BoundedArray, item: T) ?usize {
            for (self.items[0..self.len], 0..) |existing, i| {
                if (std.meta.eql(existing, item)) {
                    return i;
                }
            }
            return null;
        }

        /// Check if array contains item.
        pub fn contains(self: *const BoundedArray, item: T) bool {
            return self.find_index(item) != null;
        }

        /// Copy all elements from another bounded_array_type.
        /// Returns error.Overflow if source array is too large.
        pub fn copy_from(self: *BoundedArray, other: *const BoundedArray) !void {
            if (other.len > MAX_SIZE) {
                return error.Overflow;
            }

            self.len = other.len;
            stdx.copy_left(T, self.items[0..self.len], other.items[0..other.len]);
        }

        /// Extend array with elements from slice.
        /// Returns error.Overflow if not enough space.
        pub fn extend_from_slice(self: *BoundedArray, items: []const T) !void {
            if (self.len + items.len > MAX_SIZE) {
                return error.Overflow;
            }

            stdx.copy_left(T, self.items[self.len .. self.len + items.len], items);
            self.len += items.len;
        }

        /// Iterator for iterating over elements.
        pub const Iterator = struct {
            array: *const BoundedArray,
            index: usize = 0,

            pub fn next(self: *Iterator) ?T {
                if (self.index >= self.array.len) {
                    return null;
                }
                defer self.index += 1;
                return self.array.items[self.index];
            }

            pub fn reset(self: *Iterator) void {
                self.index = 0;
            }
        };

        /// Get iterator for read-only iteration.
        pub fn iterator(self: *const BoundedArray) Iterator {
            return Iterator{ .array = self };
        }
    };
}

/// Fixed-size hash map with compile-time bounds.
/// Uses linear probing for collision resolution with compile-time maximum capacity.
pub fn BoundedHashMapType(comptime K: type, comptime V: type, comptime max_size: usize) type {
    if (max_size == 0) {
        @compileError("bounded_hash_map_type max_size must be greater than 0");
    }
    if (max_size > 32768) {
        @compileError("bounded_hash_map_type max_size too large: " ++ std.fmt.comptimePrint("{}", .{max_size}) ++ " (max: 32768)");
    }

    // Hash table load factor of 66% balances memory efficiency with probe distance
    // Power-of-2 sizing enables fast modulo via bitwise AND for hash distribution
    const table_size = std.math.ceilPowerOfTwoAssert(usize, max_size + max_size / 2);

    return struct {
        const BoundedHashMap = @This();
        entries: [table_size]Entry = [_]Entry{Entry.empty} ** table_size,
        len: usize = 0,

        const MAX_SIZE = max_size;
        const TABLE_SIZE = table_size;

        const Entry = union(enum) {
            empty: void,
            occupied: struct { key: K, value: V },
            deleted: void,
        };

        /// Insert key-value pair.
        /// Returns error.Overflow if map is full.
        pub fn put(self: *BoundedHashMap, key: K, value: V) !void {
            if (self.len >= MAX_SIZE) {
                return error.Overflow;
            }

            const hash = self.hash_key(key);
            var index = hash % TABLE_SIZE;

            // Linear probing
            while (true) {
                switch (self.entries[index]) {
                    .empty, .deleted => {
                        self.entries[index] = Entry{ .occupied = .{ .key = key, .value = value } };
                        self.len += 1;
                        return;
                    },
                    .occupied => |*occupied| {
                        if (std.meta.eql(occupied.key, key)) {
                            occupied.value = value;
                            return;
                        }
                        index = (index + 1) % TABLE_SIZE;
                    },
                }
            }
        }

        /// Get value for key, returns null if not found.
        pub fn get(self: *const BoundedHashMap, key: K) ?V {
            const hash = self.hash_key(key);
            var index = hash % TABLE_SIZE;

            // Linear probing
            var probes: usize = 0;
            while (probes < TABLE_SIZE) {
                switch (self.entries[index]) {
                    .empty => return null,
                    .deleted => {},
                    .occupied => |occupied| {
                        if (std.meta.eql(occupied.key, key)) {
                            return occupied.value;
                        }
                    },
                }
                index = (index + 1) % TABLE_SIZE;
                probes += 1;
            }
            return null;
        }

        /// Get pointer to value for key, returns null if not found.
        /// Allows in-place modification of values.
        pub fn find_ptr(self: *BoundedHashMap, key: K) ?*V {
            const hash = self.hash_key(key);
            var index = hash % TABLE_SIZE;

            // Linear probing
            var probes: usize = 0;
            while (probes < TABLE_SIZE) {
                switch (self.entries[index]) {
                    .empty => return null,
                    .deleted => {},
                    .occupied => |*occupied| {
                        if (std.meta.eql(occupied.key, key)) {
                            return &occupied.value;
                        }
                    },
                }
                index = (index + 1) % TABLE_SIZE;
                probes += 1;
            }
            return null;
        }

        /// Remove key from map.
        /// Returns true if key was found and removed.
        pub fn remove(self: *BoundedHashMap, key: K) bool {
            const hash = self.hash_key(key);
            var index = hash % TABLE_SIZE;

            // Linear probing
            var probes: usize = 0;
            while (probes < TABLE_SIZE) {
                switch (self.entries[index]) {
                    .empty => return false,
                    .deleted => {},
                    .occupied => |occupied| {
                        if (std.meta.eql(occupied.key, key)) {
                            self.entries[index] = Entry.deleted;
                            self.len -= 1;
                            return true;
                        }
                    },
                }
                index = (index + 1) % TABLE_SIZE;
                probes += 1;
            }
            return false;
        }

        /// Clear all entries.
        pub fn clear(self: *BoundedHashMap) void {
            self.entries = [_]Entry{Entry.empty} ** TABLE_SIZE;
            self.len = 0;
        }

        /// Check if map is empty.
        pub fn is_empty(self: *const BoundedHashMap) bool {
            return self.len == 0;
        }

        /// Result type for find_or_put operation
        pub const GetOrPutResult = struct {
            found_existing: bool,
            value_ptr: *V,
        };

        /// Get or put key-value pair.
        /// Returns GetOrPutResult with found_existing flag and value pointer.
        /// Returns error.Overflow if map is full and key doesn't exist.
        pub fn find_or_put(self: *BoundedHashMap, key: K) !GetOrPutResult {
            const hash = self.hash_key(key);
            var index = hash % TABLE_SIZE;

            // Linear probing - first pass: look for existing key
            var probes: usize = 0;
            while (probes < TABLE_SIZE) {
                switch (self.entries[index]) {
                    .empty => break,
                    .deleted => {},
                    .occupied => |*occupied| {
                        if (std.meta.eql(occupied.key, key)) {
                            return GetOrPutResult{
                                .found_existing = true,
                                .value_ptr = &occupied.value,
                            };
                        }
                    },
                }
                index = (index + 1) % TABLE_SIZE;
                probes += 1;
            }

            // Key not found, need to insert
            if (self.len >= MAX_SIZE) {
                return error.Overflow;
            }

            // Find first empty or deleted slot
            index = hash % TABLE_SIZE;
            probes = 0;
            while (probes < TABLE_SIZE) {
                switch (self.entries[index]) {
                    .empty, .deleted => {
                        self.entries[index] = Entry{ .occupied = .{ .key = key, .value = undefined } };
                        self.len += 1;
                        return GetOrPutResult{
                            .found_existing = false,
                            .value_ptr = &self.entries[index].occupied.value,
                        };
                    },
                    .occupied => {
                        index = (index + 1) % TABLE_SIZE;
                        probes += 1;
                    },
                }
            }

            // This should never happen if table size is correct
            return error.Overflow;
        }

        /// Check if map is full.
        pub fn is_full(self: *const BoundedHashMap) bool {
            return self.len >= MAX_SIZE;
        }

        /// Query current load factor as ratio of items to capacity.
        /// Used for performance monitoring and resize decisions.
        pub fn query_load_factor(self: *const BoundedHashMap) f32 {
            return @as(f32, @floatFromInt(self.len)) / @as(f32, @floatFromInt(TABLE_SIZE));
        }

        /// Generate hash value for key using auto hash function.
        /// Used internally for bucket selection in hash table.
        fn hash_key(self: *const BoundedHashMap, key: K) u64 {
            _ = self;
            return std.hash_map.getAutoHashFn(K, void)({}, key);
        }

        /// Iterator for key-value pairs.
        pub const Iterator = struct {
            map: *const BoundedHashMap,
            index: usize = 0,

            pub const IteratorEntry = struct { key: K, value: V };

            /// Advance iterator to next key-value pair.
            /// Returns null when iteration is complete.
            pub fn next(self: *Iterator) ?IteratorEntry {
                while (self.index < TABLE_SIZE) {
                    defer self.index += 1;
                    switch (self.map.entries[self.index]) {
                        .occupied => |occupied| {
                            return IteratorEntry{ .key = occupied.key, .value = occupied.value };
                        },
                        else => continue,
                    }
                }
                return null;
            }
        };

        /// Get iterator over all key-value pairs.
        pub fn iterator(self: *const BoundedHashMap) Iterator {
            return Iterator{ .map = self };
        }
    };
}

/// Fixed-size queue with compile-time bounds.
/// FIFO queue with O(1) enqueue and dequeue operations.
pub fn BoundedQueueType(comptime T: type, comptime max_size: usize) type {
    if (max_size == 0) {
        @compileError("bounded_queue_type max_size must be greater than 0");
    }
    if (max_size > 65536) {
        @compileError("bounded_queue_type max_size too large: " ++ std.fmt.comptimePrint("{}", .{max_size}) ++ " (max: 65536)");
    }

    return struct {
        const BoundedQueue = @This();
        items: [max_size]T = undefined,
        head: usize = 0,
        tail: usize = 0,
        len: usize = 0,

        const MAX_SIZE = max_size;

        /// Add element to back of queue.
        /// Returns error.Overflow if queue is full.
        pub fn enqueue(self: *BoundedQueue, item: T) !void {
            if (self.len >= MAX_SIZE) {
                return error.Overflow;
            }

            self.items[self.tail] = item;
            self.tail = (self.tail + 1) % MAX_SIZE;
            self.len += 1;
        }

        /// Remove and return element from front of queue.
        /// Returns null if queue is empty.
        pub fn dequeue(self: *BoundedQueue) ?T {
            if (self.len == 0) {
                return null;
            }

            const item = self.items[self.head];
            self.head = (self.head + 1) % MAX_SIZE;
            self.len -= 1;
            return item;
        }

        /// Peek at front element without removing it.
        /// Returns null if queue is empty.
        pub fn peek(self: *const BoundedQueue) ?T {
            if (self.len == 0) {
                return null;
            }
            return self.items[self.head];
        }

        /// Peek at back element without removing it.
        /// Returns null if queue is empty.
        pub fn peek_back(self: *const BoundedQueue) ?T {
            if (self.len == 0) {
                return null;
            }
            const back_index = if (self.tail == 0) MAX_SIZE - 1 else self.tail - 1;
            return self.items[back_index];
        }

        /// Clear all elements.
        pub fn clear(self: *BoundedQueue) void {
            self.head = 0;
            self.tail = 0;
            self.len = 0;
        }

        /// Check if queue is empty.
        pub fn is_empty(self: *const BoundedQueue) bool {
            return self.len == 0;
        }

        /// Check if queue is full.
        pub fn is_full(self: *const BoundedQueue) bool {
            return self.len == MAX_SIZE;
        }

        /// Get remaining capacity.
        pub fn remaining_capacity(self: *const @This()) usize {
            return MAX_SIZE - self.len;
        }
    };
}

/// Bounded graph builder for Context Engine graph construction.
/// Enforces compile-time limits on nodes and edges to prevent resource exhaustion.
///
/// # Type Parameters
/// - `max_nodes`: Maximum number of nodes in the graph
/// - `max_edges`: Maximum number of edges in the graph
///
/// # Design Principles
/// - Compile-time bounds prevent unbounded graph growth
/// - Arena-compatible for O(1) cleanup
/// - Deduplication prevents duplicate nodes/edges
pub fn BoundedGraphBuilderType(comptime max_nodes: usize, comptime max_edges: usize) type {
    validate_bounded_usage(usize, max_nodes, "BoundedGraphBuilder nodes");
    validate_bounded_usage(usize, max_edges, "BoundedGraphBuilder edges");

    return struct {
        const Self = @This();

        /// Set of unique node IDs in the graph
        nodes: BoundedHashMapType([16]u8, void, max_nodes),

        /// List of edges between nodes
        edges: BoundedArrayType(GraphEdge, max_edges),

        /// Temporary working set for traversal algorithms
        working_set: BoundedArrayType([16]u8, max_nodes),

        pub const MAX_NODES = max_nodes;
        pub const MAX_EDGES = max_edges;

        pub const GraphEdge = struct {
            source: [16]u8,
            target: [16]u8,
            edge_type: u8, // Will be EdgeType when available
        };

        pub const GraphStats = struct {
            node_count: u32,
            edge_count: u32,
            max_node_utilization_percent: u32,
            max_edge_utilization_percent: u32,
        };

        /// Initialize empty graph builder
        pub fn init() Self {
            return Self{
                .nodes = BoundedHashMapType([16]u8, void, max_nodes){},
                .edges = BoundedArrayType(GraphEdge, max_edges){},
                .working_set = BoundedArrayType([16]u8, max_nodes){},
            };
        }

        /// Add node to graph with deduplication
        pub fn add_node(self: *Self, node_id: [16]u8) !void {
            // Deduplication handled by HashMap - put returns existing entry if present
            try self.nodes.put(node_id, {});
        }

        /// Add edge to graph with validation
        pub fn add_edge(self: *Self, source: [16]u8, target: [16]u8, edge_type: u8) !void {
            // Ensure both nodes exist in graph
            if (self.nodes.get(source) == null) return error.SourceNodeNotFound;
            if (self.nodes.get(target) == null) return error.TargetNodeNotFound;

            // Check for duplicate edges
            for (self.edges.slice()) |existing| {
                if (std.mem.eql(u8, &existing.source, &source) and
                    std.mem.eql(u8, &existing.target, &target) and
                    existing.edge_type == edge_type)
                {
                    return; // Duplicate edge, skip
                }
            }

            const edge = GraphEdge{
                .source = source,
                .target = target,
                .edge_type = edge_type,
            };
            try self.edges.append(edge);
        }

        /// Find neighbors of a node (outgoing edges)
        pub fn find_neighbors(self: *const Self, node_id: [16]u8) !BoundedArrayType([16]u8, max_nodes) {
            var neighbors = BoundedArrayType([16]u8, max_nodes){};

            for (self.edges.slice()) |edge| {
                if (std.mem.eql(u8, &edge.source, &node_id)) {
                    // Avoid duplicates
                    if (!neighbors.contains(edge.target)) {
                        try neighbors.append(edge.target);
                    }
                }
            }

            return neighbors;
        }

        /// Find incoming edges to a node
        pub fn find_incoming(self: *const Self, node_id: [16]u8) !BoundedArrayType([16]u8, max_nodes) {
            var incoming = BoundedArrayType([16]u8, max_nodes){};

            for (self.edges.slice()) |edge| {
                if (std.mem.eql(u8, &edge.target, &node_id)) {
                    if (!incoming.contains(edge.source)) {
                        try incoming.append(edge.source);
                    }
                }
            }

            return incoming;
        }

        /// Check if node exists in graph
        pub fn has_node(self: *const Self, node_id: [16]u8) bool {
            return self.nodes.get(node_id) != null;
        }

        /// Clear all nodes and edges for reuse
        pub fn clear(self: *Self) void {
            self.nodes.clear();
            self.edges.clear();
            self.working_set.clear();
        }

        /// Query graph statistics for resource monitoring
        pub fn query_stats(self: *const Self) GraphStats {
            // Safety: Graph sizes bounded by BoundedHashMap limits and fit in u32
            const node_count = @as(u32, @intCast(self.nodes.length()));
            const edge_count = @as(u32, @intCast(self.edges.length()));

            return GraphStats{
                .node_count = node_count,
                .edge_count = edge_count,
                .max_node_utilization_percent = (node_count * 100) / MAX_NODES,
                .max_edge_utilization_percent = (edge_count * 100) / MAX_EDGES,
            };
        }

        /// Validate graph integrity
        pub fn validate(self: *const Self) !void {
            // Ensure all edges reference existing nodes
            for (self.edges.slice()) |edge| {
                if (!(self.has_node(edge.source))) std.debug.panic("Edge references non-existent source node", .{});
                if (!(self.has_node(edge.target))) std.debug.panic("Edge references non-existent target node", .{});
            }
        }
    };
}

/// Convenience type aliases for common bounded collection patterns
/// Arena coordinator pattern for stable interfaces across arena operations
pub const ArenaCoordinator = struct {
    /// Reset all managed arenas in O(1) operation
    pub fn reset(self: *@This()) void {
        // Implementation will coordinate with arena system
        _ = self;
    }
};

/// Compile-time validation for bounded collection usage.
/// Ensures collections are properly sized for their use case.
pub fn validate_bounded_usage(comptime T: type, comptime max_size: usize, comptime usage_context: []const u8) void {
    // Validate reasonable size limits
    if (max_size > 65536) {
        @compileError("Bounded collection too large in " ++ usage_context ++ ": " ++ std.fmt.comptimePrint("{}", .{max_size}) ++ " (consider using dynamic allocation)");
    }

    // Validate type size is reasonable
    const item_size = @sizeOf(T);
    const total_size = item_size * max_size;
    if (total_size > 1024 * 1024) { // 1MB stack allocation limit
        @compileError("Bounded collection memory usage too large in " ++ usage_context ++ ": " ++ std.fmt.comptimePrint("{} bytes", .{total_size}) ++ " (consider reducing max_size or using heap allocation)");
    }
}

// Compile-time validation
comptime {
    // Validate that our bounded collections work with basic types
    const TestArray = BoundedArrayType(u32, 10);
    const TestQueue = BoundedQueueType(u8, 20);
    const TestMap = BoundedHashMapType(u32, []const u8, 16);

    if (!(@sizeOf(TestArray) > 0)) @compileError("bounded_array_type must have non-zero size");
    if (!(@sizeOf(TestQueue) > 0)) @compileError("bounded_queue_type must have non-zero size");
    if (!(@sizeOf(TestMap) > 0)) @compileError("bounded_hash_map_type must have non-zero size");
}

// Tests

test "bounded_array_type basic operations" {
    var array = BoundedArrayType(u32, 5){};

    try array.append(1);
    try array.append(2);
    try array.append(3);

    try std.testing.expect(array.len == 3);
    try std.testing.expect(!array.is_empty());
    try std.testing.expect(!array.is_full());

    try std.testing.expect(array.get(0) == 1);
    try std.testing.expect(array.get(1) == 2);
    try std.testing.expect(array.get(2) == 3);
    try std.testing.expect(array.get(3) == null);

    try std.testing.expect(array.at(0) == 1);
    try std.testing.expect(array.at(2) == 3);
}

test "bounded_array_type overflow behavior" {
    var array = BoundedArrayType(u8, 3){};

    try array.append(1);
    try array.append(2);
    try array.append(3);

    try std.testing.expect(array.is_full());

    try std.testing.expectError(error.Overflow, array.append(4));
}

test "bounded_array_type slice operations" {
    var array = BoundedArrayType(u32, 10){};

    try array.append(10);
    try array.append(20);
    try array.append(30);

    const slice = array.slice();
    try std.testing.expect(slice.len == 3);
    try std.testing.expect(slice[0] == 10);
    try std.testing.expect(slice[1] == 20);
    try std.testing.expect(slice[2] == 30);

    const mut_slice = array.slice_mut();
    mut_slice[1] = 25;
    try std.testing.expect(array.at(1) == 25);
}

test "bounded_array_type remove operations" {
    var array = BoundedArrayType(u32, 5){};

    try array.append(1);
    try array.append(2);
    try array.append(3);
    try array.append(4);

    const removed = try array.remove_at(1);
    try std.testing.expect(removed == 2);
    try std.testing.expect(array.len == 3);
    try std.testing.expect(array.at(0) == 1);
    try std.testing.expect(array.at(1) == 3); // Shifted left
    try std.testing.expect(array.at(2) == 4);

    const popped = array.pop();
    try std.testing.expect(popped == 4);
    try std.testing.expect(array.len == 2);
}

test "bounded_array_type search operations" {
    var array = BoundedArrayType([]const u8, 5){};

    try array.append("hello");
    try array.append("world");
    try array.append("test");

    try std.testing.expect(array.find_index("world") == 1);
    try std.testing.expect(array.find_index("missing") == null);
    try std.testing.expect(array.contains("test"));
    try std.testing.expect(!array.contains("missing"));
}

test "bounded_queue_type basic operations" {
    var queue = BoundedQueueType(u32, 4){};

    try queue.enqueue(1);
    try queue.enqueue(2);
    try queue.enqueue(3);

    try std.testing.expect(queue.len == 3);
    try std.testing.expect(!queue.is_empty());
    try std.testing.expect(!queue.is_full());

    try std.testing.expect(queue.peek() == 1);
    try std.testing.expect(queue.peek_back() == 3);

    try std.testing.expect(queue.dequeue() == 1);
    try std.testing.expect(queue.dequeue() == 2);
    try std.testing.expect(queue.len == 1);

    try std.testing.expect(queue.peek() == 3);
}

test "bounded_queue_type wrap-around" {
    var queue = BoundedQueueType(u8, 3){};

    try queue.enqueue(1);
    try queue.enqueue(2);
    try queue.enqueue(3);

    try std.testing.expect(queue.dequeue() == 1);
    try queue.enqueue(4);

    try std.testing.expect(queue.dequeue() == 2);
    try std.testing.expect(queue.dequeue() == 3);
    try std.testing.expect(queue.dequeue() == 4);
    try std.testing.expect(queue.is_empty());
}

test "bounded_hash_map_type basic operations" {
    var map = BoundedHashMapType(u32, []const u8, 8){};

    try map.put(1, "one");
    try map.put(2, "two");
    try map.put(3, "three");

    try std.testing.expect(map.len == 3);

    try std.testing.expectEqualStrings("one", map.get(1).?);
    try std.testing.expectEqualStrings("two", map.get(2).?);
    try std.testing.expectEqualStrings("three", map.get(3).?);
    try std.testing.expect(map.get(999) == null);

    try map.put(2, "TWO");
    try std.testing.expectEqualStrings("TWO", map.get(2).?);
    try std.testing.expect(map.len == 3); // Should not increase
}

test "bounded_hash_map_type remove operations" {
    var map = BoundedHashMapType(u32, u32, 8){};

    try map.put(1, 10);
    try map.put(2, 20);
    try map.put(3, 30);

    try std.testing.expect(map.remove(2));
    try std.testing.expect(map.len == 2);
    try std.testing.expect(map.get(2) == null);
    try std.testing.expect(map.get(1) == 10); // Others remain

    try std.testing.expect(!map.remove(999));
    try std.testing.expect(map.len == 2);
}

test "bounded_hash_map_type iterator" {
    var map = BoundedHashMapType(u8, u8, 8){};

    try map.put(1, 10);
    try map.put(2, 20);
    try map.put(3, 30);

    var iter = map.iterator();
    var count: usize = 0;
    var sum: u8 = 0;

    while (iter.next()) |entry| {
        count += 1;
        sum += entry.value;
    }

    try std.testing.expect(count == 3);
    try std.testing.expect(sum == 60); // 10 + 20 + 30
}

test "compile-time validation catches oversized collections" {
    // These would fail at compile time if uncommented:
    // const TooLarge = bounded_array_type(u8, 100000); // Too large
    // const ZeroSize = bounded_array_type(u8, 0); // Zero size not allowed

    const Reasonable = BoundedArrayType(u8, 100);
    try std.testing.expect(Reasonable.max_length() == 100);
}

test "bounded_array_type extend and copy operations" {
    var array = BoundedArrayType(u32, 10){};

    const data = [_]u32{ 1, 2, 3 };
    try array.extend_from_slice(&data);
    try std.testing.expect(array.len == 3);
    try std.testing.expect(array.at(0) == 1);
    try std.testing.expect(array.at(2) == 3);

    var other = BoundedArrayType(u32, 10){};
    try other.copy_from(&array);
    try std.testing.expect(other.len == 3);
    try std.testing.expect(other.at(1) == 2);

    const big_data = [_]u32{ 4, 5, 6, 7, 8, 9, 10, 11 }; // 8 more items, total would be 11
    try std.testing.expectError(error.Overflow, array.extend_from_slice(&big_data));
}

test "bounded_array_type iterator functionality" {
    var array = BoundedArrayType(u32, 5){};

    try array.append(10);
    try array.append(20);
    try array.append(30);

    var iter = array.iterator();
    try std.testing.expect(iter.next() == 10);
    try std.testing.expect(iter.next() == 20);
    try std.testing.expect(iter.next() == 30);
    try std.testing.expect(iter.next() == null);

    iter.reset();
    try std.testing.expect(iter.next() == 10);
}
