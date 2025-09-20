//! Structured CLI output module for KausalDB.
//!
//! Provides consistent, professional terminal output with clear visual hierarchy,
//! structured formatting, and appropriate use of color for enhanced readability.
//! Separates human-readable output from JSON output for clean machine parsing.
//!
//! Design principles:
//! - Clarity above all: output should be instantly understandable
//! - Structure and hierarchy: use indentation and symbols to guide the eye
//! - Action-oriented: make the next step obvious (copy-pasteable BlockIds)
//! - Consistency: similar look and feel across all commands
//! - Clean separation: beautiful human output, raw JSON for machines

const std = @import("std");
const builtin = @import("builtin");

/// Global output configuration
var output_config: OutputConfig = .{};

/// Configuration for output behavior
pub const OutputConfig = struct {
    /// Suppress all non-error output
    quiet: bool = false,
    /// Enable verbose status messages
    verbose: bool = false,
    /// Force JSON output format where supported
    json_mode: bool = false,
    /// Enable color output
    color: bool = true,
};

/// ANSI color codes for terminal output
const Colors = struct {
    const GREEN = "\x1b[32m";
    const RED = "\x1b[31m";
    const YELLOW = "\x1b[33m";
    const BLUE = "\x1b[34m";
    const CYAN = "\x1b[36m";
    const GRAY = "\x1b[90m";
    const BOLD = "\x1b[1m";
    const RESET = "\x1b[0m";
};

/// Unicode symbols for structured output
const Symbols = struct {
    const SUCCESS = "✓";
    const ERROR = "✗";
    const TREE_BRANCH = "├──";
    const TREE_LAST = "└──";
    const TREE_VERTICAL = "│";
    const TREE_SPACE = "   ";
};

/// Set global output configuration
pub fn configure_output(config: OutputConfig) void {
    output_config = config;
}

/// Reset configuration to defaults (for testing)
pub fn reset_config() void {
    output_config = .{};
}

// === Core Output Functions ===

/// Write raw string to stdout
fn write_stdout_raw(msg: []const u8) void {
    if (output_config.quiet) return;
    
    const stdout = std.fs.File{ .handle = 1 };
    _ = stdout.writeAll(msg) catch {};
}

/// Write raw string to stderr
fn write_stderr_raw(msg: []const u8) void {
    const stderr = std.fs.File{ .handle = 2 };
    _ = stderr.writeAll(msg) catch {};
}

/// Format and write to stdout
fn write_stdout_fmt(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    if (output_config.quiet) return;
    
    const formatted = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(formatted);
    write_stdout_raw(formatted);
}

/// Format and write to stderr
fn write_stderr_fmt(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const formatted = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(formatted);
    write_stderr_raw(formatted);
}

/// Apply color formatting if colors are enabled
fn with_color(allocator: std.mem.Allocator, color: []const u8, text: []const u8) []const u8 {
    if (!output_config.color) return text;
    
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ color, text, Colors.RESET }) catch text;
}

// === High-Level Output Functions ===

/// Print success message with green checkmark
pub fn print_success(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const symbol = with_color(allocator, Colors.GREEN, Symbols.SUCCESS);
    defer if (output_config.color) allocator.free(symbol);
    
    write_stdout_fmt(allocator, "{s} ", .{symbol});
    write_stdout_fmt(allocator, fmt, args);
    write_stdout_raw("\n");
}

/// Print error message with red X
pub fn print_error(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const symbol = with_color(allocator, Colors.RED, Symbols.ERROR);
    defer if (output_config.color) allocator.free(symbol);
    
    write_stderr_fmt(allocator, "{s} Error: ", .{symbol});
    write_stderr_fmt(allocator, fmt, args);
    write_stderr_raw("\n");
}

/// Print warning message with yellow text
pub fn print_warning(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const text = with_color(allocator, Colors.YELLOW, "Warning:");
    defer if (output_config.color) allocator.free(text);
    
    write_stderr_fmt(allocator, "{s} ", .{text});
    write_stderr_fmt(allocator, fmt, args);
    write_stderr_raw("\n");
}

/// Print section header in bold
pub fn print_header(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const formatted = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(formatted);
    
    const styled = with_color(allocator, Colors.BOLD, formatted);
    defer if (output_config.color) allocator.free(styled);
    
    write_stdout_fmt(allocator, "{s}\n", .{styled});
}

/// Print workspace section header
pub fn print_workspace_header() void {
    const styled = with_color(std.heap.page_allocator, Colors.BOLD, "WORKSPACE");
    defer if (output_config.color) std.heap.page_allocator.free(styled);
    
    write_stdout_fmt(std.heap.page_allocator, "{s}\n\n", .{styled});
}

/// Print result card for find/show commands
pub fn print_result_card(allocator: std.mem.Allocator, index: usize, name: []const u8, block_id: []const u8, source: []const u8, preview: ?[]const u8) void {
    // Card number and name
    write_stdout_fmt(allocator, "{}. {s}\n", .{ index, name });
    
    // BlockId in cyan for visibility
    const id_label = with_color(allocator, Colors.CYAN, "ID:");
    defer if (output_config.color) allocator.free(id_label);
    write_stdout_fmt(allocator, "   {s}     {s}\n", .{ id_label, block_id });
    
    // Source in gray
    const source_label = with_color(allocator, Colors.GRAY, "Source:");
    defer if (output_config.color) allocator.free(source_label);
    write_stdout_fmt(allocator, "   {s} {s}\n", .{ source_label, source });
    
    // Preview if available
    if (preview) |p| {
        const preview_label = with_color(allocator, Colors.GRAY, "Preview:");
        defer if (output_config.color) allocator.free(preview_label);
        write_stdout_fmt(allocator, "   {s} {s}\n", .{ preview_label, p });
    }
    
    write_stdout_raw("\n");
}

/// Print workspace status line
pub fn print_workspace_status(allocator: std.mem.Allocator, name: []const u8, path: []const u8, blocks: u64, edges: u64, last_sync: []const u8) void {
    const checkmark = with_color(allocator, Colors.GREEN, Symbols.SUCCESS);
    defer if (output_config.color) allocator.free(checkmark);
    
    write_stdout_fmt(allocator, "- {s} {s} (linked from {s})\n", .{ checkmark, name, path });
    write_stdout_fmt(allocator, "    Blocks: {} | Edges: {} | Last synced: {s}\n\n", .{ blocks, edges, last_sync });
}

/// Print empty workspace message
pub fn print_empty_workspace(allocator: std.mem.Allocator) void {
    write_stdout_raw("No codebases linked.\n\n");
    
    const tip_label = with_color(allocator, Colors.BLUE, "Tip:");
    defer if (output_config.color) allocator.free(tip_label);
    
    write_stdout_fmt(allocator, "{s} Link your first codebase by running:\n", .{tip_label});
    write_stdout_raw("kausaldb link . as my-project\n");
}

/// Print tree node for trace output
pub fn print_tree_node(allocator: std.mem.Allocator, depth: u32, is_last: bool, block_id: []const u8, name: []const u8, source: []const u8) void {
    // Build indentation string
    var indent = std.ArrayList(u8).init(allocator);
    defer indent.deinit();
    
    var d: u32 = 0;
    while (d < depth) : (d += 1) {
        if (d == depth - 1) {
            indent.appendSlice(if (is_last) Symbols.TREE_LAST else Symbols.TREE_BRANCH) catch return;
        } else {
            indent.appendSlice(Symbols.TREE_VERTICAL) catch return;
            indent.appendSlice(Symbols.TREE_SPACE) catch return;
        }
    }
    
    // Print the tree node with shortened BlockId
    const formatted_id = format_block_id(allocator, block_id) catch block_id;
    defer if (formatted_id.ptr != block_id.ptr) allocator.free(formatted_id);
    
    write_stdout_fmt(allocator, "{s} (depth: {}) {s}: {s}\n", .{ indent.items, depth, formatted_id, name });
    
    // Add source info with proper indentation
    var source_indent = std.ArrayList(u8).init(allocator);
    defer source_indent.deinit();
    
    d = 0;
    while (d < depth) : (d += 1) {
        if (d == depth - 1) {
            source_indent.appendSlice("    ") catch return;
        } else {
            source_indent.appendSlice(Symbols.TREE_VERTICAL) catch return;
            source_indent.appendSlice(Symbols.TREE_SPACE) catch return;
        }
    }
    
    const source_label = with_color(allocator, Colors.GRAY, "Source:");
    defer if (output_config.color) allocator.free(source_label);
    
    write_stdout_fmt(allocator, "{s}{s} {s}\n", .{ source_indent.items, source_label, source });
}

/// Print disambiguation error
pub fn print_disambiguation_error(allocator: std.mem.Allocator, target: []const u8, entity_type: []const u8, count: usize) void {
    print_error(allocator, "Ambiguous target '{s}'. Found {} matches.", .{ target, count });
    write_stdout_raw("\n");
    
    const command = std.fmt.allocPrint(allocator, "kausaldb find {s} \"{s}\"", .{ entity_type, target }) catch return;
    defer allocator.free(command);
    
    write_stdout_fmt(allocator, "Please use '{s}' to see all matches, then use a specific BlockId for your command.\n", .{command});
}

/// Print "not found" message
pub fn print_not_found(allocator: std.mem.Allocator, entity_type: []const u8, target: []const u8, workspace: ?[]const u8) void {
    write_stdout_fmt(allocator, "No {s} named '{s}' found", .{ entity_type, target });
    if (workspace) |ws| {
        write_stdout_fmt(allocator, " in workspace '{s}'", .{ws});
    }
    write_stdout_raw(".\n");
}

/// Print "no results" message for traversals
pub fn print_no_traversal_results(allocator: std.mem.Allocator, relation: []const u8, target: []const u8, workspace: ?[]const u8) void {
    write_stdout_fmt(allocator, "No {s} found for '{s}'", .{ relation, target });
    if (workspace) |ws| {
        write_stdout_fmt(allocator, " in workspace '{s}'", .{ws});
    }
    write_stdout_raw(".\n");
}

/// Print help text
pub fn print_help(text: []const u8) void {
    if (output_config.json_mode) {
        write_stdout_raw("{\"help\": \"use --help for usage information\"}\n");
    } else {
        write_stdout_raw(text);
    }
}

/// Print version information
pub fn print_version(version: []const u8) void {
    if (output_config.json_mode) {
        const formatted = std.fmt.allocPrint(std.heap.page_allocator, "{{\"version\": \"{s}\"}}\n", .{version}) catch return;
        defer std.heap.page_allocator.free(formatted);
        write_stdout_raw(formatted);
    } else {
        const app_name = with_color(std.heap.page_allocator, Colors.BOLD, "KausalDB");
        defer if (output_config.color) std.heap.page_allocator.free(app_name);
        
        write_stdout_fmt(std.heap.page_allocator, "{s} {s}\n", .{ app_name, version });
    }
}

// === JSON Output Functions ===

/// Write JSON to stdout (raw string)
pub fn print_json_stdout_raw(json_string: []const u8) void {
    if (output_config.quiet) return;
    write_stdout_raw(json_string);
}

/// Write formatted JSON to stdout (with allocator and formatting)
pub fn print_json_stdout(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const formatted = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(formatted);
    print_json_stdout_raw(formatted);
}

/// Print error as JSON
pub fn print_json_error(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const error_msg = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(error_msg);
    
    // Escape quotes in error message for JSON
    const escaped_msg = escape_json_string(allocator, error_msg) catch return;
    defer allocator.free(escaped_msg);
    
    const json_error = std.fmt.allocPrint(allocator, "{{\"error\": \"{s}\"}}\n", .{escaped_msg}) catch return;
    defer allocator.free(json_error);
    
    write_stdout_raw(json_error);
}

/// Format JSON for structured output
pub fn print_json_formatted(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const formatted = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(formatted);
    write_stdout_raw(formatted);
}

/// Escape string for JSON output
fn escape_json_string(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();
    
    for (input) |char| {
        switch (char) {
            '"' => try result.appendSlice("\\\""),
            '\\' => try result.appendSlice("\\\\"),
            '\n' => try result.appendSlice("\\n"),
            '\r' => try result.appendSlice("\\r"),
            '\t' => try result.appendSlice("\\t"),
            else => try result.append(char),
        }
    }
    
    return result.toOwnedSlice();
}

// === Utility Functions ===

/// Check if we should produce output
pub fn should_output() bool {
    return !output_config.quiet;
}

/// Check if we should produce verbose output
pub fn should_output_verbose() bool {
    return output_config.verbose and !output_config.quiet;
}

// === Clean API Functions ===

/// Write raw string to stdout
pub fn write_stdout(msg: []const u8) void {
    write_stdout_raw(msg);
}

/// Write raw string to stderr
pub fn write_stderr(msg: []const u8) void {
    write_stderr_raw(msg);
}

/// Print formatted string to stdout
pub fn print_stdout(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    write_stdout_fmt(allocator, fmt, args);
}

/// Print formatted string to stderr
pub fn print_stderr(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    write_stderr_fmt(allocator, fmt, args);
}

/// Format BlockId for display (shortened but copy-pasteable)
pub fn format_block_id(allocator: std.mem.Allocator, full_hex: []const u8) ![]const u8 {
    // Show first 8 chars prominently, full ID available
    if (full_hex.len >= 8) {
        const short_hex = full_hex[0..8];
        return try std.fmt.allocPrint(allocator, "{s}", .{short_hex});
    } else {
        return try allocator.dupe(u8, full_hex);
    }
}

/// Format BlockId for compact copy-paste (first 8 + last 8)
pub fn format_block_id_compact(allocator: std.mem.Allocator, full_hex: []const u8) ![]const u8 {
    if (full_hex.len >= 16) {
        const prefix = full_hex[0..8];
        const suffix = full_hex[24..32];
        return try std.fmt.allocPrint(allocator, "{s}...{s}", .{ prefix, suffix });
    } else {
        return try allocator.dupe(u8, full_hex);
    }
}

/// Format time duration for human display
pub fn format_time_ago(timestamp: i64) []const u8 {
    const now = std.time.timestamp();
    const minutes_ago = @as(u64, @intCast(now - timestamp)) / 60;
    
    if (minutes_ago == 0) {
        return "Just now";
    } else if (minutes_ago == 1) {
        return "1 minute ago";
    } else if (minutes_ago < 60) {
        // This would need dynamic allocation in real usage
        return "A few minutes ago";
    } else {
        return "Some time ago";
    }
}

/// Truncate text to specified length with ellipsis
pub fn truncate_text(allocator: std.mem.Allocator, text: []const u8, max_length: usize) ![]const u8 {
    if (text.len <= max_length) {
        return try allocator.dupe(u8, text);
    }
    
    return try std.fmt.allocPrint(allocator, "{s}...", .{text[0..max_length]});
}