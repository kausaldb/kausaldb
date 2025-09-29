//! Server coordinator for KausalDB database engines.
//!
//! Follows KausalDB coordinator pattern: owns and coordinates database engines
//! while providing stable interface for network layer. Implements proper
//! two-phase initialization and arena-per-subsystem memory management.
//!
//! Design rationale: Clear separation between database concerns and network
//! concerns enables better testability and follows single responsibility principle.

const std = @import("std");

const assert_mod = @import("../core/assert.zig");
const concurrency = @import("../core/concurrency.zig");
const error_context = @import("../core/error_context.zig");
const memory = @import("../core/memory.zig");
const production_vfs = @import("../core/production_vfs.zig");
const query_engine = @import("../query/engine.zig");
const storage = @import("../storage/engine.zig");
const workspace_manager = @import("../workspace/manager.zig");
const config_mod = @import("config.zig");

const assert = assert_mod.assert;
const fatal_assert = assert_mod.fatal_assert;
const log = std.log.scoped(.server_coordinator);

const ArenaCoordinator = memory.ArenaCoordinator;
const QueryEngine = query_engine.QueryEngine;
const ServerConfig = config_mod.ServerConfig;
const StorageEngine = storage.StorageEngine;
const WorkspaceManager = workspace_manager.WorkspaceManager;

/// Server statistics aggregated from all database engines
pub const ServerStats = struct {
    /// Total blocks stored across all engines
    total_blocks: u64 = 0,
    /// Total edges stored across all engines
    total_edges: u64 = 0,
    /// Number of SSTables on disk
    sstable_count: u32 = 0,
    /// Current memtable size in bytes
    memtable_size: u64 = 0,
    /// Total disk usage in bytes
    total_disk_usage: u64 = 0,

    /// Format statistics in human-readable text format
    pub fn format_human_readable(self: ServerStats, writer: anytype) !void {
        try writer.print("Database Statistics:\n", .{});
        try writer.print("  Blocks: {} total\n", .{self.total_blocks});
        try writer.print("  Edges: {} total\n", .{self.total_edges});
        try writer.print("  Storage: {} SSTables, {} memtable bytes\n", .{ self.sstable_count, self.memtable_size });
        try writer.print("  Disk usage: {} bytes\n", .{self.total_disk_usage});
    }
};

/// Database engine coordinator implementing KausalDB coordinator pattern.
/// Owns and manages all database engines with proper lifecycle and memory management.
pub const ServerCoordinator = struct {
    /// Base allocator for coordinator infrastructure
    allocator: std.mem.Allocator,
    /// Server configuration
    config: ServerConfig,
    /// Absolute path to data directory (allocated if different from config.data_dir)
    data_dir: []const u8,
    /// Whether data_dir was allocated and needs to be freed
    data_dir_owned: bool,

    // Arena coordinators for subsystem memory management
    storage_arena: ?*ArenaCoordinator = null,
    query_arena: ?*ArenaCoordinator = null,
    workspace_arena: ?*ArenaCoordinator = null,

    // Database engine components (owned by this coordinator)
    storage_engine: ?*StorageEngine = null,
    query_engine: ?*QueryEngine = null,
    workspace_manager: ?*WorkspaceManager = null,

    /// Phase 1 initialization: Memory allocation only, no I/O operations.
    /// Follows KausalDB two-phase initialization pattern.
    pub fn init(allocator: std.mem.Allocator, server_config: ServerConfig) ServerCoordinator {
        return ServerCoordinator{
            .allocator = allocator,
            .config = server_config,
            .data_dir = server_config.data_dir,
            .data_dir_owned = false,
            .storage_arena = null,
            .query_arena = null,
            .workspace_arena = null,
            .storage_engine = null,
            .query_engine = null,
            .workspace_manager = null,
        };
    }

    /// Phase 2 initialization: Create engines, allocate resources, perform I/O.
    /// Must be called before any database operations.
    pub fn startup(self: *ServerCoordinator) !void {
        concurrency.assert_main_thread();

        log.info("Starting database engines in data directory: {s}", .{self.data_dir});

        try self.create_arena_coordinators();
        try self.create_data_directory();
        try self.create_database_engines();

        log.info("Database engines started successfully", .{});
    }

    /// Create arena coordinators for subsystem memory management
    /// Create arena coordinators for subsystem memory management
    fn create_arena_coordinators(self: *ServerCoordinator) !void {
        // Arena coordinators prevent struct copying corruption during engine initialization
        self.storage_arena = try create_arena_coordinator(self.allocator);
        self.query_arena = try create_arena_coordinator(self.allocator);
        self.workspace_arena = try create_arena_coordinator(self.allocator);
    }

    /// Create single arena coordinator with proper lifecycle management
    fn create_arena_coordinator(allocator: std.mem.Allocator) !*ArenaCoordinator {
        const arena_allocator = try allocator.create(std.heap.ArenaAllocator);
        arena_allocator.* = std.heap.ArenaAllocator.init(allocator);
        const coordinator = try allocator.create(ArenaCoordinator);
        coordinator.* = ArenaCoordinator.init(arena_allocator);
        return coordinator;
    }

    /// Create data directory if it doesn't exist
    fn create_data_directory(self: *ServerCoordinator) !void {
        std.fs.cwd().makePath(self.data_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    /// Create and initialize all database engines
    fn create_database_engines(self: *ServerCoordinator) !void {
        // Resolve absolute path for data directory
        const abs_data_dir = if (std.fs.path.isAbsolute(self.data_dir))
            try self.allocator.dupe(u8, self.data_dir)
        else
            try std.fs.cwd().realpathAlloc(self.allocator, self.data_dir);

        // Update data_dir and mark as owned so we can free it later
        self.data_dir = abs_data_dir;
        self.data_dir_owned = true;

        // Initialize storage engine with production VFS
        const storage_config = storage.Config{};
        var production_vfs_instance = production_vfs.ProductionVFS.init(self.allocator);
        const filesystem = production_vfs_instance.vfs();

        self.storage_engine = try self.allocator.create(StorageEngine);
        self.storage_engine.?.* = try StorageEngine.init(
            self.allocator,
            filesystem,
            self.data_dir, // Use the absolute path
            storage_config,
        );
        try self.storage_engine.?.startup();
        log.debug("Storage engine initialized", .{});

        self.query_engine = try self.allocator.create(QueryEngine);
        self.query_engine.?.* = QueryEngine.init(
            self.allocator,
            self.storage_engine.?,
        );
        self.query_engine.?.startup();
        log.debug("Query engine initialized", .{});

        self.workspace_manager = try self.allocator.create(WorkspaceManager);
        self.workspace_manager.?.* = try WorkspaceManager.init(
            self.allocator,
            self.storage_engine.?,
        );
        try self.workspace_manager.?.startup();

        log.debug("Workspace manager initialized", .{});
    }

    /// Gracefully stop all database engines
    pub fn shutdown(self: *ServerCoordinator) void {
        log.info("Shutting down database engines", .{});

        if (self.workspace_manager) |wm| {
            wm.shutdown();
        }

        if (self.query_engine) |qe| {
            qe.shutdown();
        }

        if (self.storage_engine) |se| {
            se.shutdown() catch |err| {
                log.err("Storage engine shutdown failed: {}", .{err});
            };
        }

        log.info("Database engines shut down", .{});
    }

    /// Clean up all coordinator resources including engines and arenas
    pub fn deinit(self: *ServerCoordinator) void {
        self.shutdown();

        // Free data directory path if we allocated it
        if (self.data_dir_owned) {
            self.allocator.free(self.data_dir);
        }

        if (self.workspace_manager) |wm| {
            wm.deinit();
            self.allocator.destroy(wm);
        }

        if (self.query_engine) |qe| {
            qe.deinit();
            self.allocator.destroy(qe);
        }

        if (self.storage_engine) |se| {
            se.deinit();
            self.allocator.destroy(se);
        }

        if (self.workspace_arena) |arena| {
            arena.arena.deinit();
            self.allocator.destroy(arena.arena);
            self.allocator.destroy(arena);
        }

        if (self.query_arena) |arena| {
            arena.arena.deinit();
            self.allocator.destroy(arena.arena);
            self.allocator.destroy(arena);
        }

        if (self.storage_arena) |arena| {
            arena.arena.deinit();
            self.allocator.destroy(arena.arena);
            self.allocator.destroy(arena);
        }
    }

    /// Query aggregated statistics from all database engines
    pub fn query_statistics(self: *const ServerCoordinator) ServerStats {
        var stats = ServerStats{};

        if (self.storage_engine) |se| {
            const storage_stats = se.query_statistics();
            stats.total_blocks = storage_stats.total_blocks;
            stats.total_edges = storage_stats.total_edges;
            stats.sstable_count = @intCast(storage_stats.sstable_count);
            stats.memtable_size = storage_stats.memtable_bytes;
            stats.total_disk_usage = storage_stats.total_disk_bytes;
        }

        return stats;
    }

    /// Get storage engine reference for network handlers
    pub fn storage_engine_ref(self: *const ServerCoordinator) *StorageEngine {
        if (self.storage_engine) |se| {
            return se;
        }
        fatal_assert(false, "Storage engine not initialized", .{});
        unreachable;
    }

    /// Get query engine reference for network handlers
    pub fn query_engine_ref(self: *const ServerCoordinator) *QueryEngine {
        if (self.query_engine) |qe| {
            return qe;
        }
        fatal_assert(false, "Query engine not initialized", .{});
        unreachable;
    }

    /// Get workspace manager reference for network handlers
    pub fn workspace_manager_ref(self: *const ServerCoordinator) *WorkspaceManager {
        if (self.workspace_manager) |wm| {
            return wm;
        }
        fatal_assert(false, "Workspace manager not initialized", .{});
        unreachable;
    }
};

const testing = std.testing;

test "ServerCoordinator follows two-phase initialization" {
    const test_config = ServerConfig{
        .data_dir = "test_coordinator_data",
        .port = 0, // Use ephemeral port for testing
    };

    // Phase 1: init() should not perform I/O
    var coordinator = ServerCoordinator.init(testing.allocator, test_config);
    defer coordinator.deinit();

    // Verify initial state - no engines created
    try testing.expect(coordinator.storage_engine == null);
    try testing.expect(coordinator.query_engine == null);
    try testing.expect(coordinator.workspace_manager == null);
    try testing.expect(coordinator.storage_arena == null);

    // Phase 2: startup() performs resource allocation (skip for unit test)
    // Integration tests will verify full startup functionality
}

test "ServerCoordinator statistics are initially zero" {
    const test_config = ServerConfig{
        .data_dir = "test_stats_data",
    };

    var coordinator = ServerCoordinator.init(testing.allocator, test_config);
    defer coordinator.deinit();

    const stats = coordinator.query_statistics();
    try testing.expectEqual(@as(u64, 0), stats.total_blocks);
    try testing.expectEqual(@as(u64, 0), stats.total_edges);
    try testing.expectEqual(@as(u32, 0), stats.sstable_count);
    try testing.expectEqual(@as(u64, 0), stats.memtable_size);
    try testing.expectEqual(@as(u64, 0), stats.total_disk_usage);
}

test "ServerStats format_human_readable produces readable output" {
    const stats = ServerStats{
        .total_blocks = 1000,
        .total_edges = 2500,
        .sstable_count = 5,
        .memtable_size = 1024 * 1024,
        .total_disk_usage = 10 * 1024 * 1024,
    };

    var buffer: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try stats.format_human_readable(fbs.writer());

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "1000") != null);
    try testing.expect(std.mem.indexOf(u8, output, "2500") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Blocks:") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Edges:") != null);
}
