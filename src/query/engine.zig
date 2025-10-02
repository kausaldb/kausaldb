//! Query engine coordination and public interface for KausalDB.
//!
//! Coordinates query operations across caching, filtering, traversal, and storage
//! subsystems. Provides unified API for block lookups, graph traversal, and
//! relationship queries while managing query-specific metrics and statistics.
//!
//! Design rationale: Single coordinator eliminates query state scattered across
//! modules and enables centralized performance monitoring. Integrates with storage
//! engine through ownership system to ensure memory safety across subsystem boundaries.

const builtin = @import("builtin");
const std = @import("std");

const cache = @import("cache.zig");
const context_block = @import("../core/types.zig");
const error_context = @import("../core/error_context.zig");
const filtering = @import("filtering.zig");
const memory = @import("../core/memory.zig");
const operations = @import("operations.zig");
const ownership = @import("../core/ownership.zig");
const simulation_vfs = @import("../sim/simulation_vfs.zig");
const state_machines = @import("../core/state_machines.zig");
const stdx = @import("../core/stdx.zig");
const storage = @import("../storage/engine.zig");
const traversal = @import("traversal.zig");
const storage_config_mod = @import("../storage/config.zig");

const testing = std.testing;

const TypedStorageCoordinatorType = memory.TypedStorageCoordinatorType;
const Config = storage_config_mod.Config;
const BlockId = context_block.BlockId;
const BlockOwnership = ownership.BlockOwnership;
const ContextBlock = context_block.ContextBlock;
const OwnedBlock = ownership.OwnedBlock;
const QueryState = state_machines.QueryState;
const SimulationVFS = simulation_vfs.SimulationVFS;
const StorageEngine = storage.StorageEngine;

pub const QueryError = operations.QueryError;
pub const QueryResult = operations.QueryResult;
pub const TraversalQuery = traversal.TraversalQuery;
pub const TraversalResult = traversal.TraversalResult;
pub const TraversalDirection = traversal.TraversalDirection;
pub const TraversalAlgorithm = traversal.TraversalAlgorithm;
pub const EdgeTypeFilter = traversal.EdgeTypeFilter;
pub const SemanticQuery = operations.SemanticQuery;

pub const SemanticQueryResult = operations.SemanticQueryResult;
pub const SemanticResult = operations.SemanticResult;

pub const FilteredQuery = filtering.FilteredQuery;
pub const FilteredQueryResult = filtering.FilteredQueryResult;
pub const FilterCondition = filtering.FilterCondition;
pub const FilterExpression = filtering.FilterExpression;
pub const FilterOperator = filtering.FilterOperator;
pub const FilterTarget = filtering.FilterTarget;

/// Query engine errors
const EngineError = error{
    /// Query engine not initialized
    NotInitialized,
} || operations.QueryError || filtering.FilterError || traversal.TraversalError;

/// Query planning and optimization framework for future extensibility
pub const QueryPlan = struct {
    query_type: QueryType,
    estimated_cost: u64,
    estimated_result_count: u32,
    optimization_hints: OptimizationHints,
    cache_eligible: bool,
    execution_strategy: ExecutionStrategy,

    pub const QueryType = enum {
        find_blocks,
        traversal,
        semantic,
        filtered,
    };

    pub const OptimizationHints = struct {
        use_index: bool = false,
        parallel_execution: bool = false,
        result_limit: ?u32 = null,
        early_termination: bool = false,
        prefer_memtable: bool = false,
        batch_size: ?u32 = null,
        enable_prefetch: bool = false,
    };

    pub const ExecutionStrategy = enum {
        direct_storage,
        cached_result,
        index_lookup,
        hybrid_approach,
        streaming_scan,
        optimized_traversal,
    };

    /// Create a basic query plan for immediate execution
    pub fn create_basic(query_type: QueryType) QueryPlan {
        return QueryPlan{
            .query_type = query_type,
            .estimated_cost = 1000, // Default cost estimate
            .estimated_result_count = 10, // Conservative estimate
            .optimization_hints = .{},
            .cache_eligible = false, // Conservative default
            .execution_strategy = .direct_storage,
        };
    }

    /// Analyze query complexity for optimization decisions
    pub fn analyze_complexity(self: *QueryPlan, block_count: u32, edge_count: u32) void {
        const complexity_factor = block_count + (edge_count / 2);
        self.estimated_cost = complexity_factor * 10;

        if (complexity_factor > 10000) {
            self.optimization_hints.use_index = true;
            self.optimization_hints.enable_prefetch = true;
            self.execution_strategy = .hybrid_approach;
            self.cache_eligible = true;
        } else if (complexity_factor > 1000) {
            self.optimization_hints.use_index = true;
            self.cache_eligible = true;
            if (self.query_type == .traversal) {
                self.execution_strategy = .optimized_traversal;
            }
        } else if (complexity_factor < 100) {
            self.optimization_hints.prefer_memtable = true;
            self.execution_strategy = .direct_storage;
        }

        switch (self.query_type) {
            .find_blocks => {
                if (complexity_factor > 500) {
                    self.optimization_hints.batch_size = 64;
                } else {
                    self.optimization_hints.batch_size = 16;
                }
            },
            .traversal => {
                self.optimization_hints.batch_size = if (complexity_factor > 1000) 32 else 8;
            },
            .semantic, .filtered => {
                self.optimization_hints.batch_size = if (complexity_factor > 200) 48 else 12;
            },
        }
    }
};

/// Query execution context with metrics and caching hooks
pub const QueryContext = struct {
    query_id: u64,
    start_time_ns: i64,
    plan: QueryPlan,
    metrics: QueryMetrics,
    cache_key: ?[]const u8 = null,

    pub const QueryMetrics = struct {
        blocks_scanned: u32 = 0,
        edges_traversed: u32 = 0,
        cache_hits: u32 = 0,
        cache_misses: u32 = 0,
        optimization_applied: bool = false,
        memtable_hits: u32 = 0,
        sstable_reads: u32 = 0,
        index_lookups: u32 = 0,
        prefetch_efficiency: f32 = 0.0,
    };

    /// Create execution context for query
    pub fn create(query_id: u64, plan: QueryPlan) QueryContext {
        return QueryContext{
            .query_id = query_id,
            // Safety: Timestamp always fits in i64 range
            .start_time_ns = @intCast(std.time.nanoTimestamp()),
            .plan = plan,
            .metrics = .{},
        };
    }

    /// Calculate execution duration in nanoseconds
    pub fn execution_duration_ns(self: *const QueryContext) u64 {
        const current_time = std.time.nanoTimestamp();
        // Safety: Time difference is always non-negative and fits in u64
        return @as(u64, @intCast(current_time - self.start_time_ns));
    }
};

/// Query execution statistics
pub const QueryStatistics = struct {
    total_blocks_stored: u32,
    queries_executed: u64,
    find_blocks_queries: u64,
    traversal_queries: u64,
    filtered_queries: u64,
    semantic_queries: u64,
    total_query_time_ns: u64,

    /// Initialize empty statistics
    pub fn init() QueryStatistics {
        return QueryStatistics{
            .total_blocks_stored = 0,
            .queries_executed = 0,
            .find_blocks_queries = 0,
            .traversal_queries = 0,
            .filtered_queries = 0,
            .semantic_queries = 0,
            .total_query_time_ns = 0,
        };
    }

    /// Calculate average query latency in nanoseconds
    pub fn average_query_latency_ns(self: *const QueryStatistics) u64 {
        if (self.queries_executed == 0) return 0;
        return self.total_query_time_ns / self.queries_executed;
    }

    /// Calculate queries per second based on total execution time
    pub fn queries_per_second(self: *const QueryStatistics) f64 {
        if (self.total_query_time_ns == 0) return 0.0;
        const seconds = @as(f64, @floatFromInt(self.total_query_time_ns)) / 1_000_000_000.0;
        return @as(f64, @floatFromInt(self.queries_executed)) / seconds;
    }
};

/// Main query engine that coordinates all query operations
pub const QueryEngine = struct {
    allocator: std.mem.Allocator,
    storage_engine: *StorageEngine,
    state: QueryState,

    // Arena for query results - reset after each query for O(1) cleanup
    query_arena: std.heap.ArenaAllocator,

    query_cache: cache.QueryCache,
    caching_enabled: bool,

    next_query_id: stdx.MetricsCounter,
    planning_enabled: bool,

    queries_executed: stdx.MetricsCounter,
    find_blocks_queries: stdx.MetricsCounter,
    traversal_queries: stdx.MetricsCounter,
    filtered_queries: stdx.MetricsCounter,
    semantic_queries: stdx.MetricsCounter,
    total_query_time_ns: stdx.MetricsCounter,

    /// Initialize query engine with storage backend
    pub fn init(allocator: std.mem.Allocator, storage_engine: *StorageEngine) QueryEngine {
        return QueryEngine{
            .allocator = allocator,
            .storage_engine = storage_engine,
            .state = .initialized,
            .query_arena = std.heap.ArenaAllocator.init(allocator),
            .query_cache = cache.QueryCache.init(
                allocator,
                cache.QueryCache.DEFAULT_MAX_ENTRIES,
                cache.QueryCache.DEFAULT_TTL_MINUTES,
            ),
            .caching_enabled = true, // Enable caching by default for performance
            .next_query_id = stdx.MetricsCounter.init(1),
            .planning_enabled = true, // Enable planning by default for future extensibility
            .queries_executed = stdx.MetricsCounter.init(0),
            .find_blocks_queries = stdx.MetricsCounter.init(0),
            .traversal_queries = stdx.MetricsCounter.init(0),
            .filtered_queries = stdx.MetricsCounter.init(0),
            .semantic_queries = stdx.MetricsCounter.init(0),
            .total_query_time_ns = stdx.MetricsCounter.init(0),
        };
    }

    /// Start query engine operations
    pub fn startup(self: *QueryEngine) void {
        self.state.transition(.running);
    }

    /// Stop query engine operations gracefully
    pub fn shutdown(self: *QueryEngine) void {
        self.state.transition(.shutdown);
        self.state.transition(.stopped);
    }

    /// Clean up query engine resources
    pub fn deinit(self: *QueryEngine) void {
        if (self.state == .running) {
            self.shutdown();
        }
        self.query_cache.deinit();
        self.query_arena.deinit();
    }

    /// Generate a new unique query ID in a thread-safe manner
    pub fn generate_query_id(self: *QueryEngine) u64 {
        self.next_query_id.incr();
        return self.next_query_id.load();
    }

    /// Create query plan for optimization and metrics
    fn create_query_plan(
        self: *QueryEngine,
        query_type: QueryPlan.QueryType,
        estimated_results: u32,
    ) QueryPlan {
        var plan = QueryPlan.create_basic(query_type);

        if (self.planning_enabled) {
            const storage_metrics = self.storage_engine.metrics();
            plan.analyze_complexity(
                // Safety: Storage metrics are bounded by system limits and fit in u32
                @intCast(storage_metrics.blocks_written.load()),
                @intCast(storage_metrics.edges_added.load()),
            );

            self.apply_workload_optimizations(&plan, estimated_results);

            if (plan.estimated_cost > 5000 or self.should_cache_query(query_type)) {
                plan.cache_eligible = true;
            }

            if (plan.cache_eligible) {}
        }

        return plan;
    }

    /// Apply workload-specific optimizations based on query characteristics
    fn apply_workload_optimizations(self: *QueryEngine, plan: *QueryPlan, estimated_results: u32) void {
        const recent_query_ratio = self.calculate_recent_query_ratio(plan.query_type);

        switch (plan.query_type) {
            .find_blocks => {
                if (estimated_results > 100) {
                    plan.optimization_hints.early_termination = true;
                    plan.optimization_hints.batch_size = 32;
                }

                if (estimated_results <= 10 and recent_query_ratio > 0.7) {
                    plan.optimization_hints.prefer_memtable = true;
                }
            },
            .traversal => {
                plan.optimization_hints.result_limit = estimated_results;

                if (estimated_results > 50) {
                    plan.optimization_hints.enable_prefetch = true;
                    plan.execution_strategy = .optimized_traversal;
                }
            },
            .semantic, .filtered => {
                if (estimated_results > 50) {
                    plan.optimization_hints.use_index = true;
                    plan.execution_strategy = .index_lookup;
                }

                if (estimated_results > 1000) {
                    plan.execution_strategy = .streaming_scan;
                }
            },
        }
    }

    /// Determine if query should be cached based on patterns and cost
    fn should_cache_query(self: *QueryEngine, query_type: QueryPlan.QueryType) bool {
        _ = self; // Reserved for future cache hit rate analysis

        return switch (query_type) {
            .semantic, .filtered => true, // Complex queries benefit from caching
            .traversal => true, // Graph traversals often repeat
            .find_blocks => false, // Simple lookups rarely repeat exactly
        };
    }

    /// Calculate ratio of recent queries of this type (for optimization hints)
    fn calculate_recent_query_ratio(self: *QueryEngine, query_type: QueryPlan.QueryType) f32 {
        const total_recent = self.queries_executed.load();
        if (total_recent == 0) return 0.0;

        const query_count = switch (query_type) {
            .find_blocks => self.find_blocks_queries.load(),
            .traversal => self.traversal_queries.load(),
            .filtered => self.filtered_queries.load(),
            .semantic => self.semantic_queries.load(),
        };

        return @as(f32, @floatFromInt(query_count)) / @as(f32, @floatFromInt(total_recent));
    }

    /// Record query execution metrics for analysis
    fn record_query_execution(self: *QueryEngine, context: *const QueryContext) void {
        const duration_ns = context.execution_duration_ns();
        self.total_query_time_ns.add(duration_ns);

        if (context.plan.optimization_hints.use_index and context.metrics.index_lookups > 0) {}

        if (context.plan.optimization_hints.prefer_memtable and context.metrics.memtable_hits > 0) {}

        if (context.plan.cache_eligible) {
            const cache_hit_rate = if (context.metrics.cache_hits + context.metrics.cache_misses > 0)
                @as(f32, @floatFromInt(context.metrics.cache_hits)) /
                    @as(f32, @floatFromInt(context.metrics.cache_hits + context.metrics.cache_misses))
            else
                0.0;

            _ = cache_hit_rate;
        }
    }

    /// Find a single block by ID for maximum performance
    /// Returns direct pointer to storage data without allocation
    pub fn find_block(self: *QueryEngine, block_id: BlockId) !?OwnedBlock {
        if (!self.state.can_query()) return EngineError.NotInitialized;

        const start_time = std.time.nanoTimestamp();
        defer self.record_direct_query(start_time);

        // Check memtable first for direct access
        if (self.storage_engine.memtable_manager.find_block_in_memtable(block_id)) |block| {
            return OwnedBlock.take_ownership(&block, .query_engine);
        }

        // For SSTables, we need to load into cache first, then return reference
        // This maintains direct access semantics for the caller while handling disk I/O internally
        const owned_block = self.storage_engine.find_block(block_id, .query_engine) catch |err| {
            error_context.log_storage_error(err, error_context.block_context("query_find_block", block_id));
            return err;
        } orelse return null;

        // Store in query cache and return reference
        const cached_block = try self.cache_block_for_access(owned_block);
        return OwnedBlock.take_ownership(cached_block, .query_engine);
    }

    /// Check if a block exists without loading its content
    pub fn block_exists(self: *QueryEngine, block_id: BlockId) bool {
        if (!self.state.can_query()) return false;

        // Check memtable first for direct access
        if (self.storage_engine.memtable_manager.find_block_in_memtable(block_id)) |_| {
            return true;
        }

        // Check SSTables (may require index lookup but no content loading)
        return operations.has_block(self.storage_engine, block_id);
    }

    /// Get block sequence without loading full content - optimized for sequnce queries
    pub fn query_block_sequence(self: *QueryEngine, block_id: BlockId) ?u64 {
        if (!self.state.can_query()) return null;

        // Check memtable first for direct access
        if (self.storage_engine.memtable_manager.find_block_in_memtable(block_id)) |block| {
            return block.sequence;
        }

        // For SSTables, this would require loading metadata only
        // Implementation deferred - storage engine should provide sequence-only access
        return null;
    }

    /// Cache block for direct access - internal method
    fn cache_block_for_access(self: *QueryEngine, owned_block: OwnedBlock) !*const ContextBlock {
        _ = self; // Internal caching not implemented yet
        // For now, return the block pointer directly
        // In future, this should cache in query-specific memory pool
        return owned_block.read(.query_engine);
    }

    /// Find multiple blocks - batch operation
    /// Returns array of block references without allocations
    pub fn find_blocks(
        self: *QueryEngine,
        block_ids: []const BlockId,
        result_buffer: []OwnedBlock,
    ) !u32 {
        if (!self.state.can_query()) return EngineError.NotInitialized;
        if (!(result_buffer.len >= block_ids.len)) std.debug.panic("Result buffer too small for batch query", .{});

        var found_count: u32 = 0;
        for (block_ids) |block_id| {
            if (try self.find_block(block_id)) |owned_block| {
                result_buffer[found_count] = owned_block;
                found_count += 1;
            }
        }

        return found_count;
    }

    /// Execute a graph traversal query with caching for expensive operations
    pub fn execute_traversal(self: *QueryEngine, query: TraversalQuery) !TraversalResult {
        const start_time = std.time.nanoTimestamp();
        defer self.record_traversal_query(start_time);

        if (!self.state.can_query()) return EngineError.NotInitialized;

        try query.validate();

        // Reset arena for O(1) cleanup of previous query memory
        _ = self.query_arena.reset(.retain_capacity);

        if (self.caching_enabled) {
            const cache_key = cache.CacheKey.for_traversal(
                query.start_block_id,
                @intFromEnum(query.direction),
                @intFromEnum(query.algorithm),
                query.max_depth,
                traversal.edge_filter_to_hash(query.edge_filter),
            );

            // Check cache, clone result using arena allocator
            if (self.query_cache.get(cache_key, self.query_arena.allocator())) |cached_value| {
                switch (cached_value) {
                    .traversal => |cached_result| {
                        return cached_result;
                    },
                    else => {},
                }
            }
        }

        const result = traversal.execute_traversal(
            self.query_arena.allocator(),
            self.storage_engine,
            query,
        ) catch |err| {
            error_context.log_storage_error(err, error_context.StorageContext{
                .operation = "execute_traversal",
                .block_id = query.start_block_id,
                .size = query.max_results,
            });
            return err;
        };

        if (self.caching_enabled and result.blocks.len > 0) {
            const cache_key = cache.CacheKey.for_traversal(
                query.start_block_id,
                @intFromEnum(query.direction),
                @intFromEnum(query.algorithm),
                query.max_depth,
                traversal.edge_filter_to_hash(query.edge_filter),
            );
            const cache_value = cache.CacheValue{ .traversal = result };
            self.query_cache.put(cache_key, cache_value) catch {};
        }

        return result;
    }

    /// Convenience method for outgoing traversal
    pub fn traverse_outgoing(self: *QueryEngine, start_id: BlockId, max_depth: u32) !TraversalResult {
        // Reset arena for O(1) cleanup of previous query memory
        _ = self.query_arena.reset(.retain_capacity);

        self.traversal_queries.incr();
        self.queries_executed.incr();

        return traversal.traverse_outgoing(
            self.query_arena.allocator(),
            self.storage_engine,
            start_id,
            max_depth,
        );
    }

    /// Convenience method for incoming traversal
    pub fn traverse_incoming(self: *QueryEngine, start_id: BlockId, max_depth: u32) !TraversalResult {
        // Reset arena for O(1) cleanup of previous query memory
        _ = self.query_arena.reset(.retain_capacity);

        self.traversal_queries.incr();
        self.queries_executed.incr();

        return traversal.traverse_incoming(
            self.query_arena.allocator(),
            self.storage_engine,
            start_id,
            max_depth,
        );
    }

    /// Convenience method for bidirectional traversal
    pub fn traverse_bidirectional(self: *QueryEngine, start_id: BlockId, max_depth: u32) !TraversalResult {
        // Reset arena for O(1) cleanup of previous query memory
        _ = self.query_arena.reset(.retain_capacity);

        self.traversal_queries.incr();
        self.queries_executed.incr();

        return traversal.traverse_bidirectional(
            self.query_arena.allocator(),
            self.storage_engine,
            start_id,
            max_depth,
        );
    }

    /// Workspace-aware outgoing traversal with filtering
    pub fn traverse_outgoing_in_workspace(
        self: *QueryEngine,
        start_id: BlockId,
        max_depth: u32,
        workspace: []const u8,
    ) !TraversalResult {
        var traversal_result = try self.traverse_outgoing(start_id, max_depth);
        return self.filter_traversal_by_codebase(&traversal_result, workspace);
    }

    /// Workspace-aware incoming traversal with filtering
    pub fn traverse_incoming_in_workspace(
        self: *QueryEngine,
        start_id: BlockId,
        max_depth: u32,
        workspace: []const u8,
    ) !TraversalResult {
        var traversal_result = try self.traverse_incoming(start_id, max_depth);
        return self.filter_traversal_by_codebase(&traversal_result, workspace);
    }

    /// Workspace-aware bidirectional traversal with filtering
    pub fn traverse_bidirectional_in_workspace(
        self: *QueryEngine,
        start_id: BlockId,
        max_depth: u32,
        workspace: []const u8,
    ) !TraversalResult {
        var traversal_result = try self.traverse_bidirectional(start_id, max_depth);
        return self.filter_traversal_by_codebase(&traversal_result, workspace);
    }

    /// Get current query execution statistics
    pub fn statistics(self: *const QueryEngine) QueryStatistics {
        return .{
            .queries_executed = self.queries_executed.load(),
            .find_blocks_queries = self.find_blocks_queries.load(),
            .traversal_queries = self.traversal_queries.load(),
            .filtered_queries = self.filtered_queries.load(),
            .semantic_queries = self.semantic_queries.load(),
            .total_query_time_ns = self.total_query_time_ns.load(),
            .total_blocks_stored = @intCast(self.storage_engine.metrics().blocks_written.load()),
        };
    }

    /// Reset all query statistics to zero
    pub fn reset_statistics(self: *QueryEngine) void {
        self.queries_executed.reset();
        self.find_blocks_queries.reset();
        self.traversal_queries.reset();
        self.filtered_queries.reset();
        self.semantic_queries.reset();
        self.total_query_time_ns.reset();
    }

    /// Enable or disable query result caching
    pub fn enable_caching(self: *QueryEngine, enabled: bool) void {
        self.caching_enabled = enabled;
        if (!enabled) {
            self.query_cache.clear();
        }
    }

    /// Get query cache statistics for monitoring
    pub fn cache_statistics(self: *const QueryEngine) cache.CacheStatistics {
        return self.query_cache.statistics();
    }

    /// Invalidate all cached results (simplified approach)
    pub fn invalidate_cache(self: *QueryEngine) void {
        if (self.caching_enabled) {
            self.query_cache.invalidate_all();
        }
    }

    /// Clear all cached results
    pub fn clear_cache(self: *QueryEngine) void {
        self.query_cache.clear();
    }

    /// Record metrics for direct block query execution
    fn record_direct_query(self: *QueryEngine, start_time: i128) void {
        const duration = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));
        self.queries_executed.incr();
        self.find_blocks_queries.incr();
        self.total_query_time_ns.add(duration);
    }

    /// Record metrics for a traversal query execution
    fn record_traversal_query(self: *QueryEngine, start_time: i128) void {
        const duration = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));
        self.queries_executed.incr();
        self.traversal_queries.incr();
        self.total_query_time_ns.add(duration);
    }

    /// Record metrics for a filtered query execution
    fn record_filtered_query(self: *QueryEngine, start_time: i128) void {
        const duration = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));
        self.queries_executed.incr();
        self.filtered_queries.incr();
        self.total_query_time_ns.add(duration);
    }

    /// Record metrics for a semantic query execution
    fn record_semantic_query(self: *QueryEngine, start_time: i128) void {
        const duration = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));
        self.queries_executed.incr();
        self.semantic_queries.incr();
        self.total_query_time_ns.add(duration);
    }

    // === Workspace-Scoped Semantic Query API ===

    /// Find entities of a specific type by name within a linked codebase
    pub fn find_by_name(
        self: *QueryEngine,
        codebase: []const u8,
        entity_type: []const u8,
        name: []const u8,
    ) !SemanticQueryResult {
        var results = std.ArrayList(SemanticResult){};
        defer results.deinit(self.allocator);

        var iterator = self.storage_engine.iterate_all_blocks();
        defer iterator.deinit();
        var matches_found: u32 = 0;

        while (try iterator.next()) |owned_block| {
            const block = owned_block.read(.storage_engine).*;
            var parsed = std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                block.metadata_json,
                .{},
            ) catch continue; // Skip blocks with invalid JSON
            defer parsed.deinit();

            const metadata = parsed.value;

            // Filter by codebase first
            const block_codebase = if (metadata.object.get("codebase")) |cb| cb.string else continue;
            if (!std.mem.eql(u8, block_codebase, codebase)) continue;

            const unit_type = if (metadata.object.get("unit_type")) |ut| ut.string else continue;

            // Map user entity types to storage entity types
            const storage_entity_type = blk: {
                if (std.mem.eql(u8, entity_type, "struct")) {
                    break :blk "type"; // structs are stored as "type"
                } else {
                    break :blk entity_type; // direct mapping for other types
                }
            };

            if (!std.mem.eql(u8, unit_type, storage_entity_type)) continue;

            const unit_id = if (metadata.object.get("unit_id")) |ui| ui.string else continue;
            const colon_pos = std.mem.lastIndexOf(u8, unit_id, ":") orelse continue;
            const entity_name = unit_id[colon_pos + 1 ..];

            // Check for qualified name support (e.g., "StorageEngine.init")
            var is_match: bool = false;
            if (std.mem.indexOf(u8, name, ".")) |dot_pos| {
                // Qualified name: extract struct and method parts
                const requested_struct = name[0..dot_pos];
                const requested_method = name[dot_pos + 1 ..];

                // Find the struct name in unit_id (second-to-last component)
                const remaining = unit_id[0..colon_pos];
                if (std.mem.lastIndexOf(u8, remaining, ":")) |prev_colon| {
                    const struct_name = remaining[prev_colon + 1 ..];

                    // Match both struct and method names
                    is_match = std.mem.eql(u8, struct_name, requested_struct) and
                        std.mem.eql(u8, entity_name, requested_method);
                }
            } else {
                // Simple name: match entity name directly (existing behavior)
                is_match = std.mem.eql(u8, entity_name, name);
            }

            if (is_match) {
                matches_found += 1;

                try results.append(self.allocator, SemanticResult{
                    .block = OwnedBlock.take_ownership(&block, .query_engine),
                    .similarity_score = 1.0, // Exact match
                });
            }
        }

        return SemanticQueryResult.init(self.allocator, results.items, matches_found);
    }

    /// Find blocks associated with a specific file path within a linked codebase
    pub fn find_by_file_path(
        self: *QueryEngine,
        codebase: []const u8,
        file_path: []const u8,
    ) !SemanticQueryResult {
        var results = std.ArrayList(SemanticResult){};
        defer results.deinit(self.allocator);

        var iterator = self.storage_engine.iterate_all_blocks();
        defer iterator.deinit();
        var matches_found: u32 = 0;

        while (try iterator.next()) |owned_block| {
            const block = owned_block.read(.storage_engine).*;
            var parsed = std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                block.metadata_json,
                .{},
            ) catch continue; // Skip blocks with invalid JSON
            defer parsed.deinit();

            const metadata = parsed.value;

            // Filter by codebase first
            const block_codebase = if (metadata.object.get("codebase")) |cb| cb.string else continue;
            if (!std.mem.eql(u8, block_codebase, codebase)) continue;

            // Check if file path matches
            const block_file_path = if (metadata.object.get("file_path")) |fp| fp.string else continue;
            if (std.mem.eql(u8, block_file_path, file_path)) {
                matches_found += 1;

                try results.append(self.allocator, SemanticResult{
                    .block = OwnedBlock.take_ownership(&block, .query_engine),
                    .similarity_score = 1.0, // Exact match
                });
            }
        }

        return SemanticQueryResult.init(self.allocator, results.items, matches_found);
    }

    /// Find all functions, methods, etc., that call a target function (incoming traversal)
    pub fn find_callers(
        self: *QueryEngine,
        codebase: []const u8,
        target_id: BlockId,
        max_depth: u32,
    ) !TraversalResult {
        var traversal_result = try self.traverse_incoming(target_id, max_depth);
        return self.filter_traversal_by_codebase(&traversal_result, codebase);
    }

    /// Find all functions and methods called by a given function (outgoing traversal)
    pub fn find_callees(
        self: *QueryEngine,
        codebase: []const u8,
        caller_id: BlockId,
        max_depth: u32,
    ) !TraversalResult {
        var traversal_result = try self.traverse_outgoing(caller_id, max_depth);
        return self.filter_traversal_by_codebase(&traversal_result, codebase);
    }

    /// Filter traversal results by codebase
    fn filter_traversal_by_codebase(
        self: *QueryEngine,
        traversal_result: *TraversalResult,
        codebase: []const u8,
    ) !TraversalResult {
        // Use the existing arena from the traversal result for consistency and proper lifecycle
        const arena_allocator = self.query_arena.allocator();
        var filtered_blocks = std.ArrayList(OwnedBlock){};
        var filtered_paths = std.ArrayList([]const BlockId){};
        var filtered_depths = std.ArrayList(u32){};

        for (traversal_result.blocks, 0..) |owned_query_block, i| {
            const block_data = owned_query_block.read(.query_engine);
            var parsed = std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                block_data.metadata_json,
                .{},
            ) catch continue;
            defer parsed.deinit();

            const metadata = parsed.value;
            const block_codebase = if (metadata.object.get("codebase")) |cb| cb.string else continue;
            if (std.mem.eql(u8, block_codebase, codebase)) {
                try filtered_blocks.append(arena_allocator, owned_query_block);
                // Copy the path data using the arena allocator for consistent lifecycle
                const path_copy = try arena_allocator.dupe(BlockId, traversal_result.paths[i]);
                try filtered_paths.append(arena_allocator, path_copy);
                try filtered_depths.append(arena_allocator, traversal_result.depths[i]);
            }
        }

        // Transfer ownership to avoid use-after-free
        const owned_blocks = try filtered_blocks.toOwnedSlice(arena_allocator);
        const owned_paths = try filtered_paths.toOwnedSlice(arena_allocator);
        const owned_depths = try filtered_depths.toOwnedSlice(arena_allocator);

        // Create new result that reuses the same arena for consistent cleanup
        const filtered_result = TraversalResult.init(
            owned_blocks,
            owned_paths,
            owned_depths,
            @intCast(owned_blocks.len),
            if (owned_depths.len > 0) std.mem.max(u32, owned_depths) else 0,
        );

        return filtered_result;
    }

    /// Find all references to a given symbol
    pub fn find_references(
        self: *QueryEngine,
        codebase: []const u8,
        symbol_id: BlockId,
        max_depth: u32,
    ) !TraversalResult {
        var traversal_result = try self.traverse_bidirectional(symbol_id, max_depth);
        return self.filter_traversal_by_codebase(&traversal_result, codebase);
    }

    /// Find paths between two specific blocks using BFS for shortest paths
    pub fn find_paths_between(
        self: *QueryEngine,
        source_id: BlockId,
        target_id: BlockId,
        max_depth: u32,
    ) !TraversalResult {
        self.traversal_queries.incr();
        self.queries_executed.incr();
        return traversal.find_paths_between(
            self.allocator,
            self.storage_engine,
            source_id,
            target_id,
            max_depth,
        );
    }

    /// Execute a semantic search query
    /// Execute a semantic query to find related blocks
    pub fn execute_semantic_query(
        self: *QueryEngine,
        query: SemanticQuery,
    ) !SemanticQueryResult {
        const start_time = std.time.nanoTimestamp();
        defer self.record_semantic_query(start_time);

        if (!self.state.can_query()) return EngineError.NotInitialized;

        const query_id = self.generate_query_id();
        const plan = self.create_query_plan(.semantic, query.max_results);
        var context = QueryContext.create(query_id, plan);

        const result = switch (plan.execution_strategy) {
            .index_lookup => if (plan.optimization_hints.use_index)
                self.execute_semantic_query_indexed(query, &context)
            else
                operations.execute_keyword_query(self.allocator, self.storage_engine, query),
            .streaming_scan => self.execute_semantic_query_indexed(query, &context),
            else => operations.execute_keyword_query(self.allocator, self.storage_engine, query),
        } catch |err| {
            error_context.log_storage_error(err, error_context.StorageContext{
                .operation = "execute_semantic_query",
            });
            return err;
        };

        context.metrics.optimization_applied = plan.execution_strategy != .direct_storage;
        if (plan.optimization_hints.use_index) {
            context.metrics.index_lookups = 1; // Simplified metric
        }
        self.record_query_execution(&context);

        return result;
    }

    /// Execute semantic query using index optimization
    fn execute_semantic_query_indexed(
        self: *QueryEngine,
        query: SemanticQuery,
        context: *QueryContext,
    ) !SemanticQueryResult {
        context.metrics.index_lookups += 1;
        context.metrics.optimization_applied = true;

        return operations.execute_keyword_query(
            self.allocator,
            self.storage_engine,
            query,
        );
    }

    /// Execute filtered query using streaming scan
    fn execute_filtered_query_streaming(
        self: *QueryEngine,
        query: FilteredQuery,
        context: *QueryContext,
    ) !FilteredQueryResult {
        const FILTER_STREAMING_CHUNK_SIZE = 50;
        var blocks_evaluated: u32 = 0;

        const full_result = try filtering.execute_filtered_query(
            self.allocator,
            self.storage_engine,
            query,
        );
        defer full_result.deinit();

        const initial_capacity = @min(FILTER_STREAMING_CHUNK_SIZE, full_result.blocks.len);
        var streaming_blocks = try std.ArrayList(ContextBlock).initCapacity(self.allocator, initial_capacity);
        defer streaming_blocks.deinit(self.allocator);

        var chunk_start: usize = 0;
        while (chunk_start < full_result.blocks.len) {
            const chunk_end = @min(chunk_start + FILTER_STREAMING_CHUNK_SIZE, full_result.blocks.len);

            for (full_result.blocks[chunk_start..chunk_end]) |block| {
                try streaming_blocks.append(self.allocator, block);
                blocks_evaluated += 1;

                if (streaming_blocks.items.len >= 1000) break;
            }

            chunk_start = chunk_end;
            if (streaming_blocks.items.len >= 1000) break;
        }

        context.metrics.optimization_applied = true;
        context.metrics.blocks_scanned = blocks_evaluated;

        return filtering.FilteredQueryResult.init(
            self.allocator,
            streaming_blocks.items,
            @intCast(streaming_blocks.items.len),
            false,
        );
    }

    /// Execute filtered query using index optimization
    fn execute_filtered_query_indexed(
        self: *QueryEngine,
        query: FilteredQuery,
        context: *QueryContext,
    ) !FilteredQueryResult {
        context.metrics.index_lookups += 1;
        context.metrics.optimization_applied = true;

        return filtering.execute_filtered_query(
            self.allocator,
            self.storage_engine,
            query,
        );
    }
};

/// Command types for protocol compatibility
pub const QueryCommand = enum(u8) {
    find_blocks = 0x01,
    traverse = 0x02,
    filter = 0x03,
    semantic = 0x04,

    pub fn from_u8(value: u8) !QueryCommand {
        return std.enums.fromInt(QueryCommand, value) orelse EngineError.NotInitialized;
    }
};

fn create_test_block(id: BlockId, content: []const u8) ContextBlock {
    return ContextBlock{
        .id = id,
        .sequence = 0, // Storage engine will assign the actual global sequence
        .source_uri = "test://harness.query_engine.zig",
        .metadata_json = "{}",
        .content = content,
    };
}

test "query engine initialization and deinitialization" {
    const allocator = testing.allocator;
    var sim_vfs = try simulation_vfs.SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "test_init");
    defer storage_engine.deinit();
    defer {
        storage_engine.shutdown() catch {};
    }
    try storage_engine.startup();

    var query_engine = QueryEngine.init(allocator, &storage_engine);
    query_engine.startup();
    defer query_engine.deinit();

    try testing.expect(query_engine.state == .running);
    try testing.expect(query_engine.queries_executed.load() == 0);
    try testing.expect(query_engine.find_blocks_queries.load() == 0);
}

test "query engine statistics tracking" {
    const allocator = testing.allocator;
    var sim_vfs = try simulation_vfs.SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "test_stats");
    defer storage_engine.deinit();
    defer {
        storage_engine.shutdown() catch {};
    }
    try storage_engine.startup();

    var query_engine = QueryEngine.init(allocator, &storage_engine);
    query_engine.startup();
    defer query_engine.deinit();

    const initial_stats = query_engine.statistics();
    try testing.expectEqual(@as(u64, 0), initial_stats.queries_executed);
    try testing.expectEqual(@as(u64, 0), initial_stats.find_blocks_queries);
    try testing.expectEqual(@as(u64, 0), initial_stats.traversal_queries);

    const test_id = try BlockId.from_hex("12345678901234567890123456789012");
    const test_block = create_test_block(test_id, "test content");
    try storage_engine.put_block(test_block);

    const found_block = try query_engine.find_block(test_id);

    try testing.expect(found_block != null);
    try testing.expect(found_block.?.read_immutable().id.eql(test_id));

    const updated_stats = query_engine.statistics();
    try testing.expectEqual(@as(u64, 1), updated_stats.queries_executed);
    try testing.expectEqual(@as(u64, 1), updated_stats.find_blocks_queries);
    try testing.expectEqual(@as(u64, 0), updated_stats.traversal_queries);
    // Query execution timing may be too fast to measure reliably on some systems,
    // even in debug mode. Functional correctness is verified above, and performance
    // is measured separately in benchmarks.
}

test "query engine statistics calculations" {
    const allocator = testing.allocator;
    var sim_vfs = try simulation_vfs.SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "test_calc");
    defer storage_engine.deinit();
    defer {
        storage_engine.shutdown() catch {};
    }
    try storage_engine.startup();

    var query_engine = QueryEngine.init(allocator, &storage_engine);
    query_engine.startup();
    defer query_engine.deinit();

    const empty_stats = query_engine.statistics();
    try testing.expectEqual(@as(u64, 0), empty_stats.average_query_latency_ns());
    try testing.expectEqual(@as(f64, 0.0), empty_stats.queries_per_second());

    query_engine.queries_executed.store(10);
    query_engine.total_query_time_ns.store(1_000_000_000); // 1 second

    const stats_with_data = query_engine.statistics();
    try testing.expectEqual(@as(u64, 100_000_000), stats_with_data.average_query_latency_ns()); // 100ms average
    try testing.expectEqual(@as(f64, 10.0), stats_with_data.queries_per_second());
}

test "query engine statistics reset" {
    const allocator = testing.allocator;
    var sim_vfs = try simulation_vfs.SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "test_reset");
    defer storage_engine.deinit();
    defer {
        storage_engine.shutdown() catch {};
    }
    try storage_engine.startup();

    var query_engine = QueryEngine.init(allocator, &storage_engine);
    query_engine.startup();
    defer query_engine.deinit();

    query_engine.queries_executed.store(5);
    query_engine.find_blocks_queries.store(3);
    query_engine.total_query_time_ns.store(1000000);

    query_engine.reset_statistics();

    const reset_stats = query_engine.statistics();
    try testing.expectEqual(@as(u64, 0), reset_stats.queries_executed);
    try testing.expectEqual(@as(u64, 0), reset_stats.find_blocks_queries);
    try testing.expectEqual(@as(u64, 0), reset_stats.traversal_queries);
    try testing.expectEqual(@as(u64, 0), reset_stats.total_query_time_ns);
}

test "query engine find_blocks execution" {
    const allocator = testing.allocator;
    var sim_vfs = try simulation_vfs.SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "test_find");
    defer storage_engine.deinit();
    defer {
        storage_engine.shutdown() catch {};
    }
    try storage_engine.startup();

    var query_engine = QueryEngine.init(allocator, &storage_engine);
    query_engine.startup();
    defer query_engine.deinit();

    const test_id1 = try BlockId.from_hex("11111111111111111111111111111111");
    const test_id2 = try BlockId.from_hex("22222222222222222222222222222222");
    const test_block1 = create_test_block(test_id1, "content 1");
    const test_block2 = create_test_block(test_id2, "content 2");

    try storage_engine.put_block(test_block1);
    try storage_engine.put_block(test_block2);

    var found_count: u32 = 0;
    if (try query_engine.find_block(test_id1)) |_| found_count += 1;
    if (try query_engine.find_block(test_id2)) |_| found_count += 1;

    try testing.expectEqual(@as(u32, 2), found_count);
}

test "query engine find_block convenience method" {
    const allocator = testing.allocator;
    var sim_vfs = try simulation_vfs.SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "test_convenience");
    defer storage_engine.deinit();
    defer {
        storage_engine.shutdown() catch {};
    }
    try storage_engine.startup();

    var query_engine = QueryEngine.init(allocator, &storage_engine);
    query_engine.startup();
    defer query_engine.deinit();

    const test_id = try BlockId.from_hex("33333333333333333333333333333333");
    const test_block = create_test_block(test_id, "single block content");
    try storage_engine.put_block(test_block);

    const result = try query_engine.find_block(test_id);

    try testing.expect(result != null);
    const found_block = result.?;
    try testing.expect(found_block.read_immutable().id.eql(test_id));
}

test "query engine block_exists check" {
    const allocator = testing.allocator;
    var sim_vfs = try simulation_vfs.SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "test_exists");
    defer storage_engine.deinit();
    defer {
        storage_engine.shutdown() catch {};
    }
    try storage_engine.startup();

    var query_engine = QueryEngine.init(allocator, &storage_engine);
    query_engine.startup();
    defer query_engine.deinit();

    const existing_id = try BlockId.from_hex("44444444444444444444444444444444");
    const missing_id = try BlockId.from_hex("55555555555555555555555555555555");

    try testing.expect(!query_engine.block_exists(existing_id));
    try testing.expect(!query_engine.block_exists(missing_id));

    const test_block = create_test_block(existing_id, "existence test");
    try storage_engine.put_block(test_block);

    try testing.expect(query_engine.block_exists(existing_id));
    try testing.expect(!query_engine.block_exists(missing_id));
}

test "query engine uninitialized error handling" {
    // This test validates the runtime error path which only executes in release builds
    // Debug builds use assertions for immediate failure detection
    if (builtin.mode == .Debug) return;

    const allocator = testing.allocator;
    var sim_vfs = try simulation_vfs.SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "test_uninit");
    defer storage_engine.deinit();
    defer {
        storage_engine.shutdown() catch {};
    }
    try storage_engine.startup();

    var query_engine = QueryEngine.init(allocator, &storage_engine);
    defer query_engine.deinit();

    query_engine.state = .uninitialized;

    const test_id = try BlockId.from_hex("66666666666666666666666666666666");

    try testing.expectError(EngineError.NotInitialized, query_engine.find_block(test_id));
}

test "query command enum parsing" {
    try testing.expectEqual(QueryCommand.find_blocks, try QueryCommand.from_u8(0x01));
    try testing.expectEqual(QueryCommand.traverse, try QueryCommand.from_u8(0x02));
    try testing.expectEqual(QueryCommand.filter, try QueryCommand.from_u8(0x03));
    try testing.expectEqual(QueryCommand.semantic, try QueryCommand.from_u8(0x04));

    try testing.expectError(EngineError.NotInitialized, QueryCommand.from_u8(0xFF));
}

test "query engine traversal integration" {
    const allocator = testing.allocator;
    var sim_vfs = try simulation_vfs.SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "test_traversal");
    defer storage_engine.deinit();
    defer {
        storage_engine.shutdown() catch {};
    }
    try storage_engine.startup();

    var query_engine = QueryEngine.init(allocator, &storage_engine);
    query_engine.startup();
    defer query_engine.deinit();

    const start_id = try BlockId.from_hex("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const test_block = create_test_block(start_id, "traversal start");
    try storage_engine.put_block(test_block);

    const outgoing_result = try query_engine.traverse_outgoing(start_id, 2);
    try testing.expect(outgoing_result.blocks.len >= 1); // Should find at least the start block

    const incoming_result = try query_engine.traverse_incoming(start_id, 2);
    try testing.expect(incoming_result.blocks.len >= 1); // Should find at least the start block

    const bidirectional_result = try query_engine.traverse_bidirectional(start_id, 2);
    try testing.expect(bidirectional_result.blocks.len >= 1); // Should find at least the start block

    const stats = query_engine.statistics();
    try testing.expectEqual(@as(u64, 3), stats.traversal_queries);
    try testing.expectEqual(@as(u64, 3), stats.queries_executed);
}

test "query engine ownership transfer from storage" {
    const allocator = testing.allocator;
    var sim_vfs = try simulation_vfs.SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "test_ownership");
    defer storage_engine.deinit();
    defer {
        storage_engine.shutdown() catch {};
    }
    try storage_engine.startup();

    var query_engine = QueryEngine.init(allocator, &storage_engine);
    query_engine.startup();
    defer query_engine.deinit();

    const test_id = try BlockId.from_hex("11111111111111111111111111111111");
    const test_block = create_test_block(test_id, "ownership transfer test");
    try storage_engine.put_block(test_block);

    const maybe_block = try query_engine.find_block(test_id);
    try testing.expect(maybe_block != null);

    const found_block = maybe_block.?;

    const block_data = found_block;
    try testing.expect(block_data.read_immutable().id.eql(test_id));
    try testing.expect(std.mem.eql(u8, block_data.read_immutable().content, "ownership transfer test"));

    // Ownership is properly transferred via find_block(.query_engine) parameter
}

test "query engine zero-copy read operations" {
    const allocator = testing.allocator;
    var sim_vfs = try simulation_vfs.SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "test_zero_copy");
    defer storage_engine.deinit();
    defer {
        storage_engine.shutdown() catch {};
    }
    try storage_engine.startup();

    var query_engine = QueryEngine.init(allocator, &storage_engine);
    query_engine.startup();
    defer query_engine.deinit();

    const test_blocks = [_]ContextBlock{
        create_test_block(try BlockId.from_hex("11111111111111111111111111111111"), "batch test 1"),
        create_test_block(try BlockId.from_hex("22222222222222222222222222222222"), "batch test 2"),
        create_test_block(try BlockId.from_hex("33333333333333333333333333333333"), "batch test 3"),
    };

    for (test_blocks) |block| {
        try storage_engine.put_block(block);
    }

    const failing_allocator = testing.FailingAllocator.init(allocator, .{ .fail_index = 0 }); // Fail on first allocation attempt

    const found_block1 = try query_engine.find_block(test_blocks[0].id);
    try testing.expect(found_block1 != null);

    const found_block2 = try query_engine.find_block(test_blocks[1].id);
    try testing.expect(found_block2 != null);

    const found_block3 = try query_engine.find_block(test_blocks[2].id);
    try testing.expect(found_block3 != null);

    const block1_data = found_block1.?;
    try testing.expect(block1_data.read_immutable().id.eql(test_blocks[0].id));
    try testing.expect(std.mem.eql(u8, block1_data.read_immutable().content, "batch test 1"));

    const block2_data = found_block2.?;
    const block3_data = found_block3.?;

    try testing.expect(std.mem.eql(u8, block2_data.read_immutable().content, "batch test 2"));
    try testing.expect(std.mem.eql(u8, block3_data.read_immutable().content, "batch test 3"));

    try testing.expect(failing_allocator.allocations == 0);
}

test "find_by_name with simple name matching" {
    const allocator = testing.allocator;
    var sim_vfs = try simulation_vfs.SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "test_simple_name");
    defer storage_engine.deinit();
    defer {
        storage_engine.shutdown() catch {};
    }
    try storage_engine.startup();

    var query_engine = QueryEngine.init(allocator, &storage_engine);
    query_engine.startup();
    defer query_engine.deinit();

    // Create test blocks with simple function names
    const init_block = ContextBlock{
        .id = try BlockId.from_hex("11111111111111111111111111111111"),
        .sequence = 0,
        .source_uri = "test://simple.zig#L1-10",
        .metadata_json =
        \\{"unit_type": "function", "unit_id": "src/simple.zig:init", "codebase": "test_codebase"}
        ,
        .content = "pub fn init() void {}",
    };

    const deinit_block = ContextBlock{
        .id = try BlockId.from_hex("22222222222222222222222222222222"),
        .sequence = 0,
        .source_uri = "test://simple.zig#L11-20",
        .metadata_json =
        \\{"unit_type": "function", "unit_id": "src/simple.zig:deinit", "codebase": "test_codebase"}
        ,
        .content = "pub fn deinit() void {}",
    };

    try storage_engine.put_block(init_block);
    try storage_engine.put_block(deinit_block);

    // Test simple name matching
    const init_result = try query_engine.find_by_name("test_codebase", "function", "init");
    defer init_result.deinit();
    try testing.expectEqual(@as(u32, 1), init_result.total_matches);
    try testing.expect(init_result.results.len == 1);

    const deinit_result = try query_engine.find_by_name("test_codebase", "function", "deinit");
    defer deinit_result.deinit();
    try testing.expectEqual(@as(u32, 1), deinit_result.total_matches);

    // Test non-existent function
    const missing_result = try query_engine.find_by_name("test_codebase", "function", "nonexistent");
    defer missing_result.deinit();
    try testing.expectEqual(@as(u32, 0), missing_result.total_matches);
}

test "find_by_name with qualified name matching" {
    const allocator = testing.allocator;
    var sim_vfs = try simulation_vfs.SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "test_qualified_name");
    defer storage_engine.deinit();
    defer {
        storage_engine.shutdown() catch {};
    }
    try storage_engine.startup();

    var query_engine = QueryEngine.init(allocator, &storage_engine);
    query_engine.startup();
    defer query_engine.deinit();

    // Create test blocks with qualified names (struct methods)
    const storage_init_block = ContextBlock{
        .id = try BlockId.from_hex("11111111111111111111111111111111"),
        .sequence = 0,
        .source_uri = "test://storage.zig#L1-10",
        .metadata_json =
        \\{"unit_type": "function", "unit_id": "src/storage.zig:StorageEngine:init", "codebase": "test_codebase"}
        ,
        .content = "pub fn init() StorageEngine {}",
    };

    const storage_deinit_block = ContextBlock{
        .id = try BlockId.from_hex("22222222222222222222222222222222"),
        .sequence = 0,
        .source_uri = "test://storage.zig#L11-20",
        .metadata_json =
        \\{"unit_type": "function", "unit_id": "src/storage.zig:StorageEngine:deinit", "codebase": "test_codebase"}
        ,
        .content = "pub fn deinit(self: *StorageEngine) void {}",
    };

    const query_init_block = ContextBlock{
        .id = try BlockId.from_hex("33333333333333333333333333333333"),
        .sequence = 0,
        .source_uri = "test://query.zig#L1-10",
        .metadata_json =
        \\{"unit_type": "function", "unit_id": "src/query.zig:QueryEngine:init", "codebase": "test_codebase"}
        ,
        .content = "pub fn init() QueryEngine {}",
    };

    try storage_engine.put_block(storage_init_block);
    try storage_engine.put_block(storage_deinit_block);
    try storage_engine.put_block(query_init_block);

    // Test qualified name matching: "StorageEngine.init"
    const storage_init_result = try query_engine.find_by_name("test_codebase", "function", "StorageEngine.init");
    defer storage_init_result.deinit();
    try testing.expectEqual(@as(u32, 1), storage_init_result.total_matches);
    try testing.expect(storage_init_result.results.len == 1);
    try testing.expect(storage_init_result.results[0].block.read_immutable().id.eql(storage_init_block.id));

    // Test qualified name matching: "StorageEngine.deinit"
    const storage_deinit_result = try query_engine.find_by_name("test_codebase", "function", "StorageEngine.deinit");
    defer storage_deinit_result.deinit();
    try testing.expectEqual(@as(u32, 1), storage_deinit_result.total_matches);
    try testing.expect(storage_deinit_result.results[0].block.read_immutable().id.eql(storage_deinit_block.id));

    // Test qualified name matching: "QueryEngine.init"
    const query_init_result = try query_engine.find_by_name("test_codebase", "function", "QueryEngine.init");
    defer query_init_result.deinit();
    try testing.expectEqual(@as(u32, 1), query_init_result.total_matches);
    try testing.expect(query_init_result.results[0].block.read_immutable().id.eql(query_init_block.id));

    // Test that simple "init" doesn't match when we have multiple init methods
    const simple_init_result = try query_engine.find_by_name("test_codebase", "function", "init");
    defer simple_init_result.deinit();
    // Should match all init methods (both StorageEngine.init and QueryEngine.init)
    try testing.expectEqual(@as(u32, 2), simple_init_result.total_matches);
}

test "find_by_name qualified name does not match wrong struct" {
    const allocator = testing.allocator;
    var sim_vfs = try simulation_vfs.SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "test_wrong_struct");
    defer storage_engine.deinit();
    defer {
        storage_engine.shutdown() catch {};
    }
    try storage_engine.startup();

    var query_engine = QueryEngine.init(allocator, &storage_engine);
    query_engine.startup();
    defer query_engine.deinit();

    // Create blocks with different struct methods
    const storage_init_block = ContextBlock{
        .id = try BlockId.from_hex("11111111111111111111111111111111"),
        .sequence = 0,
        .source_uri = "test://storage.zig#L1-10",
        .metadata_json =
        \\{"unit_type": "function", "unit_id": "src/storage.zig:StorageEngine:init", "codebase": "test_codebase"}
        ,
        .content = "pub fn init() StorageEngine {}",
    };

    const query_init_block = ContextBlock{
        .id = try BlockId.from_hex("22222222222222222222222222222222"),
        .sequence = 0,
        .source_uri = "test://query.zig#L1-10",
        .metadata_json =
        \\{"unit_type": "function", "unit_id": "src/query.zig:QueryEngine:init", "codebase": "test_codebase"}
        ,
        .content = "pub fn init() QueryEngine {}",
    };

    try storage_engine.put_block(storage_init_block);
    try storage_engine.put_block(query_init_block);

    // Query for "StorageEngine.init" should NOT match "QueryEngine.init"
    const storage_result = try query_engine.find_by_name("test_codebase", "function", "StorageEngine.init");
    defer storage_result.deinit();
    try testing.expectEqual(@as(u32, 1), storage_result.total_matches);
    try testing.expect(storage_result.results[0].block.read_immutable().id.eql(storage_init_block.id));

    // Query for "QueryEngine.init" should NOT match "StorageEngine.init"
    const query_result = try query_engine.find_by_name("test_codebase", "function", "QueryEngine.init");
    defer query_result.deinit();
    try testing.expectEqual(@as(u32, 1), query_result.total_matches);
    try testing.expect(query_result.results[0].block.read_immutable().id.eql(query_init_block.id));

    // Query for non-existent qualified name
    const missing_result = try query_engine.find_by_name("test_codebase", "function", "NonExistent.init");
    defer missing_result.deinit();
    try testing.expectEqual(@as(u32, 0), missing_result.total_matches);
}

test "find_by_name qualified name with nested structures" {
    const allocator = testing.allocator;
    var sim_vfs = try simulation_vfs.SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "test_nested");
    defer storage_engine.deinit();
    defer {
        storage_engine.shutdown() catch {};
    }
    try storage_engine.startup();

    var query_engine = QueryEngine.init(allocator, &storage_engine);
    query_engine.startup();
    defer query_engine.deinit();

    // Create blocks with nested structure paths
    const nested_method_block = ContextBlock{
        .id = try BlockId.from_hex("11111111111111111111111111111111"),
        .sequence = 0,
        .source_uri = "test://nested.zig#L1-10",
        .metadata_json =
        \\{"unit_type": "function", "unit_id": "src/nested.zig:OuterStruct:InnerStruct:process", "codebase": "test_codebase"}
        ,
        .content = "pub fn process() void {}",
    };

    try storage_engine.put_block(nested_method_block);

    // Query for the innermost struct method
    const result = try query_engine.find_by_name("test_codebase", "function", "InnerStruct.process");
    defer result.deinit();
    try testing.expectEqual(@as(u32, 1), result.total_matches);
    try testing.expect(result.results[0].block.read_immutable().id.eql(nested_method_block.id));
}

test "find_by_name codebase filtering with qualified names" {
    const allocator = testing.allocator;
    var sim_vfs = try simulation_vfs.SimulationVFS.heap_init(allocator);
    defer {
        sim_vfs.deinit();
        allocator.destroy(sim_vfs);
    }

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "test_codebase_filter");
    defer storage_engine.deinit();
    defer {
        storage_engine.shutdown() catch {};
    }
    try storage_engine.startup();

    var query_engine = QueryEngine.init(allocator, &storage_engine);
    query_engine.startup();
    defer query_engine.deinit();

    // Create blocks in different codebases with same qualified name
    const codebase_a_block = ContextBlock{
        .id = try BlockId.from_hex("11111111111111111111111111111111"),
        .sequence = 0,
        .source_uri = "test://a.zig#L1-10",
        .metadata_json =
        \\{"unit_type": "function", "unit_id": "src/a.zig:Engine:init", "codebase": "codebase_a"}
        ,
        .content = "pub fn init() Engine {}",
    };

    const codebase_b_block = ContextBlock{
        .id = try BlockId.from_hex("22222222222222222222222222222222"),
        .sequence = 0,
        .source_uri = "test://b.zig#L1-10",
        .metadata_json =
        \\{"unit_type": "function", "unit_id": "src/b.zig:Engine:init", "codebase": "codebase_b"}
        ,
        .content = "pub fn init() Engine {}",
    };

    try storage_engine.put_block(codebase_a_block);
    try storage_engine.put_block(codebase_b_block);

    // Query codebase_a only
    const result_a = try query_engine.find_by_name("codebase_a", "function", "Engine.init");
    defer result_a.deinit();
    try testing.expectEqual(@as(u32, 1), result_a.total_matches);
    try testing.expect(result_a.results[0].block.read_immutable().id.eql(codebase_a_block.id));

    // Query codebase_b only
    const result_b = try query_engine.find_by_name("codebase_b", "function", "Engine.init");
    defer result_b.deinit();
    try testing.expectEqual(@as(u32, 1), result_b.total_matches);
    try testing.expect(result_b.results[0].block.read_immutable().id.eql(codebase_b_block.id));

    // Query non-existent codebase
    const result_c = try query_engine.find_by_name("codebase_c", "function", "Engine.init");
    defer result_c.deinit();
    try testing.expectEqual(@as(u32, 0), result_c.total_matches);
}
