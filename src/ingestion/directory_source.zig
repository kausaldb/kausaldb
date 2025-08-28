//! Directory Source Connector
//!
//! Implements the Source interface for local directories. This connector can
//! fetch content from local filesystem directories, providing file content along
//! with filesystem metadata like file paths and timestamps.
//!
//! Design Notes:
//! - Uses VFS abstraction for simulation testing compatibility
//! - Focuses on simplicity and filesystem scanning efficiency
//! - Arena-based memory management for lifecycle safety
//! - Single-threaded execution model

const std = @import("std");

const assert_mod = @import("../core/assert.zig");
const concurrency = @import("../core/concurrency.zig");
const error_context = @import("../core/error_context.zig");
const glob_matcher = @import("glob_matcher.zig");
const ingestion = @import("pipeline.zig");
const vfs = @import("../core/vfs.zig");

const testing = std.testing;

const IngestionError = ingestion.IngestionError;
const Source = ingestion.Source;
const SourceContent = ingestion.SourceContent;
const SourceIterator = ingestion.SourceIterator;
const VFS = vfs.VFS;

/// Configuration for directory source
pub const DirectorySourceConfig = struct {
    /// Path to the directory (local path)
    directory_path: []const u8,
    /// File patterns to include (e.g., "*.zig", "*.md")
    include_patterns: []const []const u8,
    /// File patterns to exclude (e.g., "*.bin", ".git/*")
    exclude_patterns: []const []const u8,
    /// Maximum file size to process (bytes)
    max_file_size: u64 = 10 * 1024 * 1024, // 10MB default
    /// Whether to follow symbolic links
    follow_symlinks: bool = false,

    pub fn init(allocator: std.mem.Allocator, directory_path: []const u8) !DirectorySourceConfig {
        var include_patterns = std.array_list.Managed([]const u8).init(allocator);
        try include_patterns.append(try allocator.dupe(u8, "**/*.zig"));
        try include_patterns.append(try allocator.dupe(u8, "**/*.md"));
        try include_patterns.append(try allocator.dupe(u8, "**/*.txt"));
        try include_patterns.append(try allocator.dupe(u8, "**/*.json"));
        try include_patterns.append(try allocator.dupe(u8, "**/*.toml"));
        try include_patterns.append(try allocator.dupe(u8, "**/*.yaml"));
        try include_patterns.append(try allocator.dupe(u8, "**/*.yml"));

        var exclude_patterns = std.array_list.Managed([]const u8).init(allocator);
        try exclude_patterns.append(try allocator.dupe(u8, ".git/*"));
        try exclude_patterns.append(try allocator.dupe(u8, "*.bin"));
        try exclude_patterns.append(try allocator.dupe(u8, "*.exe"));
        try exclude_patterns.append(try allocator.dupe(u8, "*.so"));
        try exclude_patterns.append(try allocator.dupe(u8, "*.dylib"));
        try exclude_patterns.append(try allocator.dupe(u8, "*.dll"));
        try exclude_patterns.append(try allocator.dupe(u8, "zig-cache/*"));
        try exclude_patterns.append(try allocator.dupe(u8, "zig-out/*"));

        return DirectorySourceConfig{
            .directory_path = try allocator.dupe(u8, directory_path),
            .include_patterns = try include_patterns.toOwnedSlice(),
            .exclude_patterns = try exclude_patterns.toOwnedSlice(),
        };
    }

    pub fn deinit(self: *DirectorySourceConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.directory_path);
        for (self.include_patterns) |pattern| {
            allocator.free(pattern);
        }
        allocator.free(self.include_patterns);
        for (self.exclude_patterns) |pattern| {
            allocator.free(pattern);
        }
        allocator.free(self.exclude_patterns);
    }
};

/// Directory metadata
pub const DirectoryMetadata = struct {
    /// Directory root path (allocated since it can be long)
    directory_root: []const u8,
    /// When the directory was last scanned
    scan_timestamp_ns: u64,

    pub fn deinit(self: *DirectoryMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.directory_root);
    }
};

/// File information from directory
pub const DirectoryFileInfo = struct {
    /// Relative path from repository root
    relative_path: []const u8,
    /// File content
    content: []const u8,
    /// File size in bytes
    size: u64,
    /// Last modified timestamp
    modified_time_ns: u64,
    /// Content type based on file extension
    content_type: []const u8,

    pub fn deinit(self: *DirectoryFileInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.relative_path);
        allocator.free(self.content);
        allocator.free(self.content_type);
    }
};

/// Iterator over files from a directory
pub const DirectorySourceIterator = struct {
    /// Reference to parent DirectorySource for metadata
    directory_source: *DirectorySource,
    /// Pre-discovered list of matching files
    files: []DirectoryFileInfo,
    /// Current index in the files array
    current_index: usize,
    /// Base allocator for cleanup
    allocator: std.mem.Allocator,

    pub fn init(
        directory_source: *DirectorySource,
        files: []DirectoryFileInfo,
        allocator: std.mem.Allocator,
    ) DirectorySourceIterator {
        return DirectorySourceIterator{
            .directory_source = directory_source,
            .files = files,
            .current_index = 0,
            .allocator = allocator,
        };
    }

    /// Get the next SourceContent item, or null if finished
    pub fn next(self: *DirectorySourceIterator, allocator: std.mem.Allocator) IngestionError!?SourceContent {
        if (self.current_index >= self.files.len) {
            return null; // Iterator exhausted
        }

        const file = &self.files[self.current_index];
        self.current_index += 1;

        var metadata_map = std.StringHashMap([]const u8).init(allocator);
        try metadata_map.put("directory_path", try allocator.dupe(u8, self.directory_source.config.directory_path));
        try metadata_map.put("file_path", try allocator.dupe(u8, file.relative_path));
        try metadata_map.put("file_size", try std.fmt.allocPrint(allocator, "{d}", .{file.size}));

        return SourceContent{
            .data = try allocator.dupe(u8, file.content),
            .content_type = try allocator.dupe(u8, file.content_type),
            .metadata = metadata_map,
            .timestamp_ns = file.modified_time_ns,
        };
    }

    pub fn deinit(self: *DirectorySourceIterator, allocator: std.mem.Allocator) void {
        _ = allocator; // Iterator doesn't own the allocator, files are owned by GitSource
        for (self.files) |*file| {
            file.deinit(self.allocator);
        }
        self.allocator.free(self.files);
    }

    fn next_impl(ptr: *anyopaque, allocator: std.mem.Allocator) IngestionError!?SourceContent {
        const self = @as(*DirectorySourceIterator, @ptrCast(@alignCast(ptr)));
        return self.next(allocator);
    }

    fn deinit_impl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self = @as(*DirectorySourceIterator, @ptrCast(@alignCast(ptr)));
        self.deinit(allocator);
        allocator.destroy(self); // Free the iterator instance itself
    }

    pub fn as_source_iterator(self: *DirectorySourceIterator) SourceIterator {
        return SourceIterator{
            .ptr = self,
            .vtable = &.{
                .next = next_impl,
                .deinit = deinit_impl,
            },
        };
    }
};

/// Directory source implementation
pub const DirectorySource = struct {
    /// Source configuration
    config: DirectorySourceConfig,
    /// Directory metadata
    metadata: ?DirectoryMetadata = null,
    /// Allocator for runtime allocations
    allocator: std.mem.Allocator,

    /// Initialize Directory source with configuration
    pub fn init(allocator: std.mem.Allocator, config: DirectorySourceConfig) DirectorySource {
        return DirectorySource{
            .config = config,
            .allocator = allocator,
        };
    }

    /// Clean up Directory source resources
    pub fn deinit(self: *DirectorySource, allocator: std.mem.Allocator) void {
        if (self.metadata) |*metadata| {
            metadata.deinit(allocator);
        }
        self.config.deinit(allocator);
    }

    /// Create Source interface wrapper
    pub fn source(self: *DirectorySource) Source {
        return Source{
            .ptr = self,
            .vtable = &.{
                .fetch = fetch_impl,
                .describe = describe_impl,
                .deinit = deinit_impl,
            },
        };
    }

    /// Fetch content from the directory
    fn fetch_iterator(
        self: *DirectorySource,
        allocator: std.mem.Allocator,
        file_system: *VFS,
    ) IngestionError!SourceIterator {
        concurrency.assert_main_thread();

        const dir_stat = file_system.stat(self.config.directory_path) catch |err| {
            error_context.log_ingestion_error(err, error_context.repository_context(
                "stat_directory",
                self.config.directory_path,
            ));
            return IngestionError.SourceFetchFailed;
        };
        if (!dir_stat.is_directory) {
            error_context.log_ingestion_error(IngestionError.SourceFetchFailed, error_context.repository_context(
                "validate_directory",
                self.config.directory_path,
            ));
            return IngestionError.SourceFetchFailed;
        }

        try self.scan_directory_metadata(self.allocator);

        const files = try self.find_matching_files(allocator, file_system);

        // Note: We still do the file discovery up front, but yield files one by one
        // discover file paths. Future optimization could make discovery lazy too.
        var iterator = try allocator.create(DirectorySourceIterator);
        iterator.* = DirectorySourceIterator.init(self, files, allocator);

        return iterator.as_source_iterator();
    }

    /// Scan directory for metadata
    fn scan_directory_metadata(self: *DirectorySource, allocator: std.mem.Allocator) !void {
        const metadata = DirectoryMetadata{
            .directory_root = try allocator.dupe(u8, self.config.directory_path),
            .scan_timestamp_ns = @intCast(std.time.nanoTimestamp()),
        };
        self.metadata = metadata;
    }

    /// Find all files matching the configured patterns
    fn find_matching_files(
        self: *DirectorySource,
        allocator: std.mem.Allocator,
        file_system: *VFS,
    ) ![]DirectoryFileInfo {
        var files = std.array_list.Managed(DirectoryFileInfo).init(allocator);
        try self.scan_directory_recursive(allocator, file_system, self.config.directory_path, "", &files);

        const file_slice = try files.toOwnedSlice();
        std.sort.block(DirectoryFileInfo, file_slice, {}, struct {
            fn less_than(context: void, a: DirectoryFileInfo, b: DirectoryFileInfo) bool {
                _ = context;
                return std.mem.lessThan(u8, a.relative_path, b.relative_path);
            }
        }.less_than);

        return file_slice;
    }

    /// Recursively scan directory for matching files
    fn scan_directory_recursive(
        self: *DirectorySource,
        allocator: std.mem.Allocator,
        file_system: *VFS,
        base_path: []const u8,
        relative_path: []const u8,
        files: *std.array_list.Managed(DirectoryFileInfo),
    ) !void {
        const full_path = if (relative_path.len == 0)
            try allocator.dupe(u8, base_path)
        else
            try std.fs.path.join(allocator, &.{ base_path, relative_path });
        defer allocator.free(full_path);

        var dir_iterator = file_system.iterate_directory(full_path, allocator) catch {
            return;
        };
        defer dir_iterator.deinit(allocator);

        while (dir_iterator.next()) |entry| {
            const entry_name = entry.name;
            const entry_relative = if (relative_path.len == 0)
                try allocator.dupe(u8, entry_name)
            else
                try std.fs.path.join(allocator, &.{ relative_path, entry_name });
            defer allocator.free(entry_relative);

            if (self.is_excluded(entry_relative)) {
                continue;
            }

            switch (entry.kind) {
                .directory => {
                    try self.scan_directory_recursive(allocator, file_system, base_path, entry_relative, files);
                },
                .file => {
                    if (self.is_included(entry_relative)) {
                        const file_info = self.load_file_info(allocator, file_system, base_path, entry_relative) catch |err| {
                            error_context.log_ingestion_error(err, error_context.ingestion_file_context(
                                "load_file_info",
                                self.config.directory_path,
                                entry_relative,
                                null,
                            ));
                            continue;
                        };
                        try files.append(file_info);
                    }
                },
                else => {}, // Skip other types (symlinks, etc.)
            }
        }
    }

    /// Check if file path matches include patterns using robust glob matching
    fn is_included(self: *DirectorySource, file_path: []const u8) bool {
        for (self.config.include_patterns) |pattern| {
            if (glob_matcher.matches_pattern(pattern, file_path)) {
                return true;
            }
        }
        return false;
    }

    /// Check if file path matches exclude patterns using robust glob matching
    fn is_excluded(self: *DirectorySource, file_path: []const u8) bool {
        for (self.config.exclude_patterns) |pattern| {
            if (glob_matcher.matches_pattern(pattern, file_path)) {
                return true;
            }
        }
        return false;
    }

    /// Load file information and content
    fn load_file_info(
        self: *DirectorySource,
        allocator: std.mem.Allocator,
        file_system: *VFS,
        base_path: []const u8,
        relative_path: []const u8,
    ) !DirectoryFileInfo {
        const full_path = try std.fs.path.join(allocator, &.{ base_path, relative_path });
        defer allocator.free(full_path);

        const stat = try file_system.stat(full_path);
        if (stat.size > self.config.max_file_size) {
            error_context.log_ingestion_error(IngestionError.SourceFetchFailed, error_context.file_size_context(
                "validate_file_size",
                full_path,
                stat.size,
                self.config.max_file_size,
            ));
            return IngestionError.SourceFetchFailed;
        }

        const content = try file_system.read_file_alloc(allocator, full_path, @intCast(stat.size));
        const content_type = detect_content_type(relative_path);

        return DirectoryFileInfo{
            .relative_path = try allocator.dupe(u8, relative_path),
            .content = content,
            .size = stat.size,
            .modified_time_ns = @intCast(stat.modified_time),
            .content_type = try allocator.dupe(u8, content_type),
        };
    }

    fn fetch_impl(ptr: *anyopaque, allocator: std.mem.Allocator, file_system: *VFS) IngestionError!SourceIterator {
        const self: *DirectorySource = @ptrCast(@alignCast(ptr));
        return self.fetch_iterator(allocator, file_system);
    }

    fn describe_impl(ptr: *anyopaque) []const u8 {
        const self: *DirectorySource = @ptrCast(@alignCast(ptr));
        return self.config.directory_path;
    }

    fn deinit_impl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *DirectorySource = @ptrCast(@alignCast(ptr));
        self.deinit(allocator);
    }
};

/// Detect content type from file extension
fn detect_content_type(file_path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, file_path, ".zig")) return "text/zig";
    if (std.mem.endsWith(u8, file_path, ".md")) return "text/markdown";
    if (std.mem.endsWith(u8, file_path, ".txt")) return "text/plain";
    if (std.mem.endsWith(u8, file_path, ".json")) return "application/json";
    if (std.mem.endsWith(u8, file_path, ".toml")) return "application/toml";
    if (std.mem.endsWith(u8, file_path, ".yaml") or std.mem.endsWith(u8, file_path, ".yml")) return "application/yaml";
    if (std.mem.endsWith(u8, file_path, ".c") or std.mem.endsWith(u8, file_path, ".h")) return "text/c";
    if (std.mem.endsWith(u8, file_path, ".cpp") or std.mem.endsWith(u8, file_path, ".hpp")) return "text/cpp";
    if (std.mem.endsWith(u8, file_path, ".rs")) return "text/rust";
    if (std.mem.endsWith(u8, file_path, ".py")) return "text/python";
    if (std.mem.endsWith(u8, file_path, ".js")) return "text/javascript";
    if (std.mem.endsWith(u8, file_path, ".ts")) return "text/typescript";
    return "text/plain";
}

test "directory source creation and cleanup" {
    const allocator = testing.allocator;

    const config = try DirectorySourceConfig.init(allocator, "/test/dir");

    var dir_source = DirectorySource.init(allocator, config);
    defer dir_source.deinit(allocator);

    const source = dir_source.source();
    try testing.expectEqualStrings("/test/dir", source.describe());
}

test "pattern matching" {
    try testing.expect(glob_matcher.matches_pattern("file.zig", "file.zig"));
    try testing.expect(!glob_matcher.matches_pattern("other.zig", "file.zig"));

    try testing.expect(!glob_matcher.matches_pattern("*.zig", "src/main.zig"));
    try testing.expect(!glob_matcher.matches_pattern("*.zig", "src/main.rs"));

    try testing.expect(glob_matcher.matches_pattern(".git/*", ".git/config"));
    try testing.expect(!glob_matcher.matches_pattern(".git/*", "src/.git"));

    try testing.expect(glob_matcher.matches_pattern("src/**/*.zig", "src/parser/lexer.zig"));
    try testing.expect(glob_matcher.matches_pattern("test[0-9].zig", "test1.zig"));
    try testing.expect(!glob_matcher.matches_pattern("src/**/*.zig", "tests/main.zig"));
}

test "content type detection" {
    try testing.expectEqualStrings("text/zig", detect_content_type("main.zig"));
    try testing.expectEqualStrings("text/markdown", detect_content_type("README.md"));
    try testing.expectEqualStrings("application/json", detect_content_type("package.json"));
    try testing.expectEqualStrings("text/plain", detect_content_type("unknown.ext"));
}
