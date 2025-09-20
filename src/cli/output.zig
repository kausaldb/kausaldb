//! Standardized output handling for KausalDB CLI.
//!
//! Provides consistent stdout/stderr interfaces to replace inconsistent
//! std.debug.print usage throughout the codebase. Supports both human-readable
//! and JSON output formats with proper verbosity control.
//!
//! Design rationale: Centralized output handling enables consistent formatting,
//! proper stream separation, and controlled verbosity without scattered
//! debug print statements polluting production output.

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
    /// Enable color output (future enhancement)
    color: bool = true,
};

/// Set global output configuration
pub fn configure_output(config: OutputConfig) void {
    output_config = config;
}

/// Write raw string to stdout
pub fn write_stdout(msg: []const u8) void {
    if (output_config.quiet) return;

    const stdout = std.fs.File{ .handle = 1 };
    _ = stdout.writeAll(msg) catch {};
}

/// Write raw string to stderr
pub fn write_stderr(msg: []const u8) void {
    const stderr = std.fs.File{ .handle = 2 };
    _ = stderr.writeAll(msg) catch {};
}

/// Write formatted string to stdout
pub fn print_stdout(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    if (output_config.quiet) return;

    const formatted = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(formatted);

    write_stdout(formatted);
}

/// Write formatted string to stderr
pub fn print_stderr(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const formatted = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(formatted);

    write_stderr(formatted);
}

/// Write verbose status message to stdout (only if verbose enabled)
pub fn print_verbose(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    if (!output_config.verbose or output_config.quiet) return;

    print_stdout(allocator, fmt, args);
}

/// Write JSON to stdout with proper formatting
pub fn print_json_stdout(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    if (output_config.quiet) return;

    const formatted = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(formatted);

    write_stdout(formatted);
}

/// Write error in consistent format
pub fn print_error(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    if (output_config.json_mode) {
        print_json_error(allocator, fmt, args);
    } else {
        print_stderr(allocator, "Error: " ++ fmt, args);
    }
}

/// Write error as JSON to stdout
pub fn print_json_error(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const error_msg = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(error_msg);

    // Escape quotes in error message for JSON
    const escaped_msg = escape_json_string(allocator, error_msg) catch return;
    defer allocator.free(escaped_msg);

    const json_error = std.fmt.allocPrint(allocator,
        \\{{"error": "{s}"}}
    , .{escaped_msg}) catch return;
    defer allocator.free(json_error);

    write_stdout(json_error);
    write_stdout("\n");
}

/// Write success status with dual format support
pub fn print_status(allocator: std.mem.Allocator, status: []const u8, details: anytype) void {
    if (output_config.json_mode) {
        print_json_status(allocator, status, details);
    } else {
        print_stdout(allocator, "✓ {s}\n", .{status});
    }
}

/// Write status as JSON
fn print_json_status(allocator: std.mem.Allocator, status: []const u8, details: anytype) void {
    const DetailsType = @TypeOf(details);

    if (DetailsType == void) {
        print_json_stdout(allocator,
            \\{{"status": "{s}"}}
        , .{status});
    } else {
        // This would need expansion for complex detail types
        print_json_stdout(allocator,
            \\{{"status": "{s}", "details": "{any}"}}
        , .{ status, details });
    }
    write_stdout("\n");
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

/// Print command help/usage information
pub fn print_help(help_text: []const u8) void {
    if (output_config.json_mode) {
        // JSON mode probably shouldn't show help, but if needed:
        write_stdout("{\"help\": \"use --help for usage information\"}\n");
    } else {
        write_stdout(help_text);
    }
}

/// Print version information
pub fn print_version(version: []const u8) void {
    if (output_config.json_mode) {
        const formatted = std.fmt.allocPrint(std.heap.page_allocator, "{{\"version\": \"{s}\"}}\n", .{version}) catch return;
        defer std.heap.page_allocator.free(formatted);
        write_stdout(formatted);
    } else {
        write_stdout("KausalDB ");
        write_stdout(version);
        write_stdout("\n");
    }
}

/// Utility to check if we should produce output
pub fn should_output() bool {
    return !output_config.quiet;
}

/// Utility to check if we should produce verbose output
pub fn should_output_verbose() bool {
    return output_config.verbose and !output_config.quiet;
}

/// For testing - reset configuration to defaults
pub fn reset_config() void {
    output_config = .{};
}

// Simple formatted output functions that don't require allocator
pub fn print_simple_stdout(comptime fmt: []const u8, args: anytype) void {
    if (output_config.quiet) return;

    const formatted = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch return;
    defer std.heap.page_allocator.free(formatted);
    write_stdout(formatted);
}

pub fn print_simple_stderr(comptime fmt: []const u8, args: anytype) void {
    const formatted = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch return;
    defer std.heap.page_allocator.free(formatted);
    write_stderr(formatted);
}
