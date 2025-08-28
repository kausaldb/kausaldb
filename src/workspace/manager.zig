//! Workspace management for linked codebases.
//!
//! Manages collections of linked codebases that form a queryable workspace.
//! Stores workspace metadata using the existing StorageEngine and coordinates
//! codebase ingestion through established pipeline patterns.
//!
//! Design rationale: Workspace-centric rather than database-centric approach.
//! Users link codebases into their workspace like linking libraries, enabling
//! cross-codebase queries and analysis.

const std = @import("std");

const assert_mod = @import("../core/assert.zig");
const context_block = @import("../core/types.zig");
const error_context = @import("../core/error_context.zig");
const directory_source = @import("../ingestion/directory_source.zig");
const git_source = @import("../ingestion/git_source.zig");
const memory = @import("../core/memory.zig");
const ingestion_pipeline = @import("../ingestion/pipeline.zig");
const semantic_chunker = @import("../ingestion/semantic_chunker.zig");
const storage = @import("../storage/engine.zig");
const vfs = @import("../core/vfs.zig");
const zig_parser = @import("../ingestion/zig_parser.zig");

const assert = assert_mod.assert;
const fatal_assert = assert_mod.fatal_assert;

const ArenaCoordinator = memory.ArenaCoordinator;
const BlockId = context_block.BlockId;
const ContextBlock = context_block.ContextBlock;
const DirectorySource = directory_source.DirectorySource;
const DirectorySourceConfig = directory_source.DirectorySourceConfig;
const GitSource = git_source.GitSource;
const GitSourceConfig = git_source.GitSourceConfig;
const IngestionPipeline = ingestion_pipeline.IngestionPipeline;
const PipelineConfig = ingestion_pipeline.PipelineConfig;
const SemanticChunker = semantic_chunker.SemanticChunker;
const SemanticChunkerConfig = semantic_chunker.SemanticChunkerConfig;
const StorageEngine = storage.StorageEngine;
const VFS = vfs.VFS;
const ZigParser = zig_parser.ZigParser;
const ZigParserConfig = zig_parser.ZigParserConfig;

pub const WorkspaceError = error{
    CodebaseAlreadyLinked,
    CodebaseNotFound,
    InvalidCodebasePath,
    InvalidCodebaseName,
    WorkspaceNotInitialized,
} || storage.StorageError || std.mem.Allocator.Error;

/// Information about a linked codebase in the workspace
pub const CodebaseInfo = struct {
    name: []const u8,
    path: []const u8,
    linked_timestamp: i64,
    last_sync_timestamp: i64,
    block_count: u32,
    edge_count: u32,
};

/// Workspace configuration stored as metadata
const WorkspaceConfig = struct {
    version: u32,
    linked_codebases: std.ArrayList(CodebaseInfo),

    const WORKSPACE_CONFIG_VERSION: u32 = 1;
    const WORKSPACE_METADATA_ID_PREFIX = "workspace_config_";
};

/// Manages workspace of linked codebases with metadata persistence.
/// Uses existing StorageEngine for metadata storage and coordinates
/// with ingestion pipeline for codebase processing.
pub const WorkspaceManager = struct {
    storage_engine: *StorageEngine,
    workspace_arena: *std.heap.ArenaAllocator,
    coordinator: *ArenaCoordinator,
    linked_codebases: std.StringHashMap(CodebaseInfo),
    initialized: bool,
    backing_allocator: std.mem.Allocator,

    /// Initialize workspace manager with backing storage.
    /// Storage engine must be initialized before workspace manager.
    pub fn init(allocator: std.mem.Allocator, storage_engine: *StorageEngine) !WorkspaceManager {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);

        const arena_coordinator = try allocator.create(ArenaCoordinator);
        arena_coordinator.* = ArenaCoordinator.init(arena);

        return WorkspaceManager{
            .storage_engine = storage_engine,
            .workspace_arena = arena,
            .coordinator = arena_coordinator,
            .linked_codebases = std.StringHashMap(CodebaseInfo).init(allocator),
            .initialized = false,
            .backing_allocator = allocator,
        };
    }

    /// Phase 2 initialization: Load workspace metadata from storage.
    /// Must be called after StorageEngine startup.
    pub fn startup(self: *WorkspaceManager) !void {
        assert(!self.initialized);

        try self.load_workspace_metadata();
        self.initialized = true;
    }

    /// Graceful shutdown of workspace manager.
    pub fn shutdown(self: *WorkspaceManager) void {
        if (!self.initialized) return;

        // Workspace metadata is already persisted on each operation
        self.initialized = false;
    }

    /// Clean up all workspace resources.
    pub fn deinit(self: *WorkspaceManager) void {
        self.linked_codebases.deinit();
        self.workspace_arena.deinit();
        self.backing_allocator.destroy(self.coordinator);
        self.backing_allocator.destroy(self.workspace_arena);
    }

    /// Link a codebase to the workspace for querying.
    /// Path must be absolute and point to existing directory.
    /// Name defaults to directory basename if not provided.
    pub fn link_codebase(self: *WorkspaceManager, path: []const u8, name: ?[]const u8) !void {
        assert(self.initialized);
        fatal_assert(path.len > 0, "Codebase path cannot be empty", .{});

        // Validate path exists and is accessible
        _ = self.storage_engine.vfs.stat(path) catch |err| switch (err) {
            vfs.VFSError.FileNotFound => return WorkspaceError.InvalidCodebasePath,
            else => return err,
        };

        // Generate name from path if not provided
        const codebase_name = name orelse std.fs.path.basename(path);

        // Validate name is not empty and contains no invalid characters
        if (codebase_name.len == 0 or
            std.mem.indexOfAny(u8, codebase_name, "/\\:*?\"<>|") != null)
        {
            return WorkspaceError.InvalidCodebaseName;
        }

        // Check if codebase is already linked
        if (self.linked_codebases.contains(codebase_name)) {
            return WorkspaceError.CodebaseAlreadyLinked;
        }

        // Create codebase info entry
        const current_time = std.time.timestamp();
        const codebase_info = CodebaseInfo{
            .name = try self.coordinator.allocator().dupe(u8, codebase_name),
            .path = try self.coordinator.allocator().dupe(u8, path),
            .linked_timestamp = current_time,
            .last_sync_timestamp = current_time,
            .block_count = 0,
            .edge_count = 0,
        };

        // Store in memory and persist to storage
        try self.linked_codebases.put(codebase_info.name, codebase_info);
        try self.persist_workspace_metadata();

        // Trigger initial ingestion of the linked codebase
        self.ingest_codebase(codebase_info.name, codebase_info.path) catch |err| {
            // Log the error but don't fail the link operation
            // The user can manually sync later if needed
            error_context.log_ingestion_error(err, error_context.IngestionContext{
                .operation = "initial_ingestion",
                .repository_path = codebase_info.path,
                .content_type = "codebase",
            });
        };
    }

    /// Remove a codebase from the workspace.
    /// This removes metadata but preserves stored blocks for now.
    /// Future versions may implement full cleanup.
    pub fn unlink_codebase(self: *WorkspaceManager, name: []const u8) !void {
        assert(self.initialized);
        fatal_assert(name.len > 0, "Codebase name cannot be empty", .{});

        if (!self.linked_codebases.contains(name)) {
            return WorkspaceError.CodebaseNotFound;
        }

        // Remove from memory and persist changes
        const removed = self.linked_codebases.remove(name);
        assert(removed);

        try self.persist_workspace_metadata();
    }

    /// List all linked codebases with their information.
    /// Caller owns the returned slice and must free it.
    pub fn list_linked_codebases(self: *WorkspaceManager, allocator: std.mem.Allocator) ![]CodebaseInfo {
        assert(self.initialized);

        var result = try allocator.alloc(CodebaseInfo, self.linked_codebases.count());
        var iterator = self.linked_codebases.iterator();
        var index: usize = 0;

        while (iterator.next()) |entry| {
            result[index] = entry.value_ptr.*;
            index += 1;
        }

        return result;
    }

    /// Check if a codebase is linked to the workspace.
    pub fn is_codebase_linked(self: *WorkspaceManager, name: []const u8) bool {
        assert(self.initialized);
        return self.linked_codebases.contains(name);
    }

    /// Get information about a specific linked codebase.
    pub fn find_codebase_info(self: *WorkspaceManager, name: []const u8) ?CodebaseInfo {
        assert(self.initialized);
        return self.linked_codebases.get(name);
    }

    /// Sync a codebase with its source directory.
    /// Updates last_sync_timestamp and refreshes statistics.
    pub fn sync_codebase(self: *WorkspaceManager, name: []const u8) !void {
        assert(self.initialized);

        var codebase_entry = self.linked_codebases.getEntry(name) orelse {
            return WorkspaceError.CodebaseNotFound;
        };

        // Track sync completion for incremental change detection
        codebase_entry.value_ptr.last_sync_timestamp = std.time.timestamp();

        // Atomic persistence ensures workspace state survives crashes
        try self.persist_workspace_metadata();

        // Trigger re-ingestion of the codebase
        try self.ingest_codebase(name, codebase_entry.value_ptr.path);

        // Update block and edge counts after successful ingestion
        // For now, we'll leave the counts as-is since updating them requires
        // querying the storage engine which would be expensive
        // TODO: Implement efficient block/edge counting
    }

    /// Load workspace metadata from storage engine.
    /// Creates empty workspace if no metadata exists.
    fn load_workspace_metadata(self: *WorkspaceManager) !void {
        const metadata_id = try self.generate_workspace_metadata_id();

        const metadata_block = self.storage_engine.find_block_with_ownership(metadata_id, .query_engine) catch |err| switch (err) {
            storage.StorageError.BlockNotFound => {
                // First time initialization - empty workspace
                return;
            },
            else => return err,
        };

        if (metadata_block) |block| {
            try self.deserialize_workspace_config(block.block.content);

            // Clean up the cloned OwnedBlock to prevent memory leaks
            self.backing_allocator.free(block.block.source_uri);
            self.backing_allocator.free(block.block.metadata_json);
            self.backing_allocator.free(block.block.content);
        }
    }

    /// Persist current workspace state to storage engine.
    fn persist_workspace_metadata(self: *WorkspaceManager) !void {
        const metadata_content = try self.serialize_workspace_config();
        defer self.coordinator.allocator().free(metadata_content);

        const metadata_id = try self.generate_workspace_metadata_id();
        const metadata_block = ContextBlock{
            .id = metadata_id,
            .version = 1,
            .source_uri = try self.coordinator.allocator().dupe(u8, "workspace://metadata"),
            .metadata_json = try self.coordinator.allocator().dupe(u8, "{\"type\":\"workspace_config\"}"),
            .content = metadata_content,
        };

        try self.storage_engine.put_block(metadata_block);

        // Clean up allocated strings
        self.coordinator.allocator().free(metadata_block.source_uri);
        self.coordinator.allocator().free(metadata_block.metadata_json);
    }

    /// Generate consistent block ID for workspace metadata storage.
    fn generate_workspace_metadata_id(self: *WorkspaceManager) !BlockId {
        _ = self;
        // Use deterministic ID for workspace metadata
        return try BlockId.from_hex("11111111111111111111111111111111");
    }

    /// Serialize workspace configuration to JSON for storage.
    fn serialize_workspace_config(self: *WorkspaceManager) ![]u8 {
        var json_buffer = std.array_list.Managed(u8).init(self.coordinator.allocator());
        defer json_buffer.deinit();

        try json_buffer.appendSlice("{\"version\":");
        try json_buffer.writer().print("{}", .{WorkspaceConfig.WORKSPACE_CONFIG_VERSION});
        try json_buffer.appendSlice(",\"codebases\":[");

        var iterator = self.linked_codebases.iterator();
        var first = true;
        while (iterator.next()) |entry| {
            if (!first) try json_buffer.appendSlice(",");
            first = false;

            const info = entry.value_ptr.*;
            try json_buffer.writer().print("{{\"name\":\"{s}\",\"path\":\"{s}\",\"linked_timestamp\":{},\"last_sync_timestamp\":{},\"block_count\":{},\"edge_count\":{}}}", .{ info.name, info.path, info.linked_timestamp, info.last_sync_timestamp, info.block_count, info.edge_count });
        }

        try json_buffer.appendSlice("]}");
        return json_buffer.toOwnedSlice();
    }

    /// Deserialize workspace configuration from JSON storage.
    fn deserialize_workspace_config(self: *WorkspaceManager, content: []const u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.coordinator.allocator(), content, .{}) catch |err| {
            fatal_assert(false, "Failed to parse workspace configuration JSON", .{});
            return err;
        };
        defer parsed.deinit();

        const root = parsed.value.object;

        // Parse version (validate compatibility)
        const version = @as(u32, @intCast(root.get("version").?.integer));
        if (version != WorkspaceConfig.WORKSPACE_CONFIG_VERSION) {
            fatal_assert(false, "Unsupported workspace config version", .{});
        }

        const codebases_array = &root.get("codebases").?.array;

        for (codebases_array.items) |codebase_json| {
            const codebase_obj = codebase_json.object;

            const codebase_info = CodebaseInfo{
                .name = try self.coordinator.allocator().dupe(u8, codebase_obj.get("name").?.string),
                .path = try self.coordinator.allocator().dupe(u8, codebase_obj.get("path").?.string),
                .linked_timestamp = codebase_obj.get("linked_timestamp").?.integer,
                .last_sync_timestamp = codebase_obj.get("last_sync_timestamp").?.integer,
                .block_count = @as(u32, @intCast(codebase_obj.get("block_count").?.integer)),
                .edge_count = @as(u32, @intCast(codebase_obj.get("edge_count").?.integer)),
            };

            try self.linked_codebases.put(codebase_info.name, codebase_info);
        }
    }

    /// Ingest a codebase using the ingestion pipeline
    fn ingest_codebase(self: *WorkspaceManager, codebase_name: []const u8, codebase_path: []const u8) !void {
        // Create a temporary allocator for the ingestion process
        var arena_allocator = std.heap.ArenaAllocator.init(self.backing_allocator);
        defer arena_allocator.deinit();
        const temp_allocator = arena_allocator.allocator();

        // Configure Directory source for local filesystem scanning
        const source_config = try DirectorySourceConfig.init(temp_allocator, codebase_path);
        // Note: Don't call source_config.deinit() since we're using an arena allocator

        var dir_src = DirectorySource.init(temp_allocator, source_config);
        // Arena allocator pattern: all component memory freed together at arena cleanup

        // Configure Zig parser
        const parser_config = ZigParserConfig{};
        var zig_psr = ZigParser.init(temp_allocator, parser_config);
        // Parser is stateless with no internal allocations to release

        const chunker_config = SemanticChunkerConfig{};
        var sem_chunker = SemanticChunker.init(temp_allocator, chunker_config);
        // Arena-based cleanup eliminates individual component deinitialization

        // Configure and create ingestion pipeline
        var pipeline_config = PipelineConfig.init(temp_allocator);
        // Arena pattern ensures O(1) cleanup of all pipeline configuration memory

        // Add some metadata to identify the source
        try pipeline_config.global_metadata.put("workspace_name", try temp_allocator.dupe(u8, codebase_name));
        try pipeline_config.global_metadata.put("codebase_path", try temp_allocator.dupe(u8, codebase_path));

        var pipeline = try IngestionPipeline.init(temp_allocator, &self.storage_engine.vfs, pipeline_config);
        defer pipeline.deinit();

        try pipeline.register_source(dir_src.source());
        try pipeline.register_parser(zig_psr.parser());
        try pipeline.register_chunker(sem_chunker.chunker());

        // Execute ingestion with backpressure control
        // This directly stores blocks to the storage engine without accumulating them in memory
        try pipeline.execute_with_backpressure(self.storage_engine);

        // Log statistics for visibility
        const stats = pipeline.stats();
        std.log.info("Ingested codebase '{s}': {} sources processed, {} blocks generated", .{
            codebase_name,
            stats.sources_processed,
            stats.blocks_generated,
        });
    }
};
