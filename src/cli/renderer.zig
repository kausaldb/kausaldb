//! Output renderer for KausalDB CLI v2.
//!
//! Transforms command results into human-readable or machine-parsable formats.
//! Provides consistent, professional output across all CLI commands.

const std = @import("std");

const protocol = @import("protocol.zig");
const parser = @import("parser.zig");
const types = @import("../core/types.zig");

const BlockId = types.BlockId;
const OutputFormat = parser.OutputFormat;

/// Render context for output operations
pub const RenderContext = struct {
    allocator: std.mem.Allocator,
    writer: std.fs.File.Writer,
    format: OutputFormat,
    use_color: bool,

    /// ANSI color codes for terminal output
    const Color = struct {
        const reset = "\x1b[0m";
        const bold = "\x1b[1m";
        const dim = "\x1b[2m";
        const green = "\x1b[32m";
        const yellow = "\x1b[33m";
        const blue = "\x1b[34m";
        const magenta = "\x1b[35m";
        const cyan = "\x1b[36m";
        const red = "\x1b[31m";
    };

    pub fn init(allocator: std.mem.Allocator, writer: std.fs.File.Writer, format: OutputFormat) RenderContext {
        return RenderContext{
            .allocator = allocator,
            .writer = writer,
            .format = format,
            .use_color = false and format == .text, // TTY detection needs proper implementation
        };
    }

    fn write_colored(self: *RenderContext, color: []const u8, text: []const u8) !void {
        if (self.use_color) {
            try (&self.writer.interface).print("{s}{s}{s}", .{ color, text, Color.reset });
        } else {
            try self.writer.interface.writeAll(text);
        }
    }
};

pub fn render_version(ctx: *RenderContext, version: []const u8) !void {
    switch (ctx.format) {
        .text => {
            try ctx.writer.interface.print("KausalDB {s}\n", .{version});
        },
        .json => {
            try ctx.writer.interface.print("{{\"version\":\"{s}\"}}\n", .{version});
        },
        .csv => {
            try ctx.writer.interface.print("version\n{s}\n", .{version});
        },
    }
}

pub fn render_help(ctx: *RenderContext, topic: ?[]const u8) !void {
    if (topic) |t| {
        try render_command_help(ctx, t);
    } else {
        try render_general_help(ctx);
    }
}

fn render_general_help(ctx: *RenderContext) !void {
    if (ctx.format != .text) {
        try ctx.writer.interface.writeAll("{\"error\":\"Help only available in text format\"}\n");
        return;
    }

    try ctx.write_colored(RenderContext.Color.bold, "KausalDB - Graph Database for AI Context\n\n");

    try ctx.write_colored(RenderContext.Color.yellow, "Usage:\n");
    try ctx.writer.interface.writeAll("  kausal <command> [arguments]\n\n");

    try ctx.write_colored(RenderContext.Color.yellow, "Core Commands:\n");
    try ctx.writer.interface.writeAll("  help [topic]           Show help for a command\n");
    try ctx.writer.interface.writeAll("  version                Show version information\n");
    try ctx.writer.interface.writeAll("  server [mode]          Manage the KausalDB server\n");
    try ctx.writer.interface.writeAll("  status                 Show database status\n\n");

    try ctx.write_colored(RenderContext.Color.yellow, "Query Commands:\n");
    try ctx.writer.interface.writeAll("  find <query>           Find blocks matching a query\n");
    try ctx.writer.interface.writeAll("  show <dir> <target>    Show relationships (callers/callees)\n");
    try ctx.writer.interface.writeAll("  trace <src> <dst>      Trace paths between blocks\n\n");

    try ctx.write_colored(RenderContext.Color.yellow, "Workspace Commands:\n");
    try ctx.writer.interface.writeAll("  link <path> <name>     Link a codebase to workspace\n");
    try ctx.writer.interface.writeAll("  unlink <name>          Remove a codebase from workspace\n");
    try ctx.writer.interface.writeAll("  sync [name]            Sync workspace with filesystem\n\n");

    try ctx.write_colored(RenderContext.Color.dim, "Run 'kausal help <command>' for detailed information\n");
}

fn render_command_help(ctx: *RenderContext, command: []const u8) !void {
    if (ctx.format != .text) {
        try ctx.writer.interface.writeAll("{\"error\":\"Help only available in text format\"}\n");
        return;
    }

    if (std.mem.eql(u8, command, "find")) {
        try ctx.write_colored(RenderContext.Color.bold, "kausal find - Find blocks matching a query\n\n");
        try ctx.writer.interface.writeAll("Usage: kausal find <query> [options]\n\n");
        try ctx.writer.interface.writeAll("Options:\n");
        try ctx.writer.interface.writeAll("  --format <fmt>     Output format: text, json, csv (default: text)\n");
        try ctx.writer.interface.writeAll("  --max-results <n>  Maximum results to return (default: 10)\n");
        try ctx.writer.interface.writeAll("  --show-metadata    Include block metadata in output\n\n");
        try ctx.writer.interface.writeAll("Examples:\n");
        try ctx.writer.interface.writeAll("  kausal find parse_command\n");
        try ctx.writer.interface.writeAll("  kausal find \"StorageEngine.init\" --max-results 5\n");
    } else if (std.mem.eql(u8, command, "server")) {
        try ctx.write_colored(RenderContext.Color.bold, "kausal server - Manage the KausalDB server\n\n");
        try ctx.writer.interface.writeAll("Usage: kausal server [mode] [options]\n\n");
        try ctx.writer.interface.writeAll("Modes:\n");
        try ctx.writer.interface.writeAll("  start     Start the server (default)\n");
        try ctx.writer.interface.writeAll("  stop      Stop the running server\n");
        try ctx.writer.interface.writeAll("  restart   Restart the server\n");
        try ctx.writer.interface.writeAll("  status    Check server status\n\n");
        try ctx.writer.interface.writeAll("Options:\n");
        try ctx.writer.interface.writeAll("  --host <addr>      Bind address (default: 127.0.0.1)\n");
        try ctx.writer.interface.writeAll("  --port <port>      Port number (default: 3838)\n");
        try ctx.writer.interface.writeAll("  --data-dir <path>  Data directory (default: .kausal-data)\n");
    } else {
        try ctx.writer.interface.print("No help available for command: {s}\n", .{command});
    }
}

pub fn render_status(ctx: *RenderContext, status: protocol.StatusResponse, verbose: bool) !void {
    switch (ctx.format) {
        .text => try render_status_text(ctx, status, verbose),
        .json => try render_status_json(ctx, status),
        .csv => try render_status_csv(ctx, status),
    }
}

fn render_status_text(ctx: *RenderContext, status: protocol.StatusResponse, verbose: bool) !void {
    try ctx.write_colored(RenderContext.Color.bold, "KausalDB Status\n");
    try ctx.writer.interface.writeAll("─────────────────────────────\n");

    try ctx.writer.interface.print("Blocks:       {d:>10}\n", .{status.block_count});
    try ctx.writer.interface.print("Edges:        {d:>10}\n", .{status.edge_count});
    try ctx.writer.interface.print("SSTables:     {d:>10}\n", .{status.sstable_count});

    if (verbose) {
        try ctx.writer.interface.writeAll("\n");
        try ctx.write_colored(RenderContext.Color.yellow, "Memory:\n");
        try ctx.writer.interface.print("  Memtable:   {d:>10} bytes\n", .{status.memtable_size});

        try ctx.writer.interface.writeAll("\n");
        try ctx.write_colored(RenderContext.Color.yellow, "Storage:\n");
        try ctx.writer.interface.print("  Disk Usage: {d:>10} bytes\n", .{status.total_disk_usage});

        try ctx.writer.interface.writeAll("\n");
        try ctx.write_colored(RenderContext.Color.yellow, "Server:\n");
        const hours = status.uptime_seconds / 3600;
        const minutes = (status.uptime_seconds % 3600) / 60;
        const seconds = status.uptime_seconds % 60;
        try ctx.writer.interface.print("  Uptime:     {d:0>2}:{d:0>2}:{d:0>2}\n", .{ hours, minutes, seconds });
    }
}

fn render_status_json(ctx: *RenderContext, status: protocol.StatusResponse) !void {
    try ctx.writer.interface.print(
        \\{{
        \\  "block_count": {d},
        \\  "edge_count": {d},
        \\  "sstable_count": {d},
        \\  "memtable_size": {d},
        \\  "total_disk_usage": {d},
        \\  "uptime_seconds": {d}
        \\}}
        \\
    , .{
        status.block_count,
        status.edge_count,
        status.sstable_count,
        status.memtable_size,
        status.total_disk_usage,
        status.uptime_seconds,
    });
}

fn render_status_csv(ctx: *RenderContext, status: protocol.StatusResponse) !void {
    try ctx.writer.interface.writeAll("metric,value\n");
    try ctx.writer.interface.print("block_count,{d}\n", .{status.block_count});
    try ctx.writer.interface.print("edge_count,{d}\n", .{status.edge_count});
    try ctx.writer.interface.print("sstable_count,{d}\n", .{status.sstable_count});
    try ctx.writer.interface.print("memtable_size,{d}\n", .{status.memtable_size});
    try ctx.writer.interface.print("total_disk_usage,{d}\n", .{status.total_disk_usage});
    try ctx.writer.interface.print("uptime_seconds,{d}\n", .{status.uptime_seconds});
}

pub fn render_find_results(ctx: *RenderContext, response: protocol.FindResponse, show_metadata: bool) !void {
    const blocks = response.blocks_slice();

    if (blocks.len == 0) {
        switch (ctx.format) {
            .text => try ctx.writer.interface.writeAll("No results found.\n"),
            .json => try ctx.writer.interface.writeAll("{\"results\":[]}\n"),
            .csv => try ctx.writer.interface.writeAll("id,uri,preview\n"),
        }
        return;
    }

    switch (ctx.format) {
        .text => try render_find_results_text(ctx, blocks, show_metadata),
        .json => try render_find_results_json(ctx, blocks),
        .csv => try render_find_results_csv(ctx, blocks),
    }
}

fn render_find_results_text(ctx: *RenderContext, blocks: []const protocol.BlockInfo, show_metadata: bool) !void {
    try ctx.writer.interface.print("Found {d} result{s}:\n\n", .{ blocks.len, if (blocks.len == 1) "" else "s" });

    for (blocks, 0..) |block, i| {
        // Result number
        try ctx.write_colored(
            RenderContext.Color.cyan,
            try std.fmt.allocPrint(ctx.allocator, "[{d}] ", .{i + 1}),
        );

        // URI
        const uri = block.uri[0..block.uri_len];
        try ctx.write_colored(RenderContext.Color.blue, uri);
        try ctx.writer.interface.writeAll("\n");

        // Block ID
        try ctx.writer.interface.print("    ID: {}\n", .{block.id});

        // Content preview
        if (block.content_preview_len > 0) {
            try ctx.writer.interface.writeAll("    Preview: ");
            const preview = block.content_preview[0..@min(block.content_preview_len, 80)];
            try ctx.writer.interface.writeAll(preview);
            if (block.content_preview_len > 80) {
                try ctx.writer.interface.writeAll("...");
            }
            try ctx.writer.interface.writeAll("\n");
        }

        if (show_metadata and block.metadata_size > 0) {
            try ctx.writer.interface.print("    Metadata: {d} bytes\n", .{block.metadata_size});
        }

        if (i < blocks.len - 1) {
            try ctx.writer.interface.writeAll("\n");
        }
    }
}

fn render_find_results_json(ctx: *RenderContext, blocks: []const protocol.BlockInfo) !void {
    try ctx.writer.interface.writeAll("{\"results\":[\n");

    for (blocks, 0..) |block, i| {
        try ctx.writer.interface.writeAll("  {");
        try ctx.writer.interface.print("\"id\":\"{}\",", .{block.id});
        try ctx.writer.interface.print("\"uri\":\"{s}\",", .{block.uri[0..block.uri_len]});
        try ctx.writer.interface.print("\"preview\":\"{s}\",", .{block.content_preview[0..block.content_preview_len]});
        try ctx.writer.interface.print("\"metadata_size\":{d}", .{block.metadata_size});
        try ctx.writer.interface.writeAll("}");

        if (i < blocks.len - 1) {
            try ctx.writer.interface.writeAll(",");
        }
        try ctx.writer.interface.writeAll("\n");
    }

    try ctx.writer.interface.writeAll("]}\n");
}

fn render_find_results_csv(ctx: *RenderContext, blocks: []const protocol.BlockInfo) !void {
    try ctx.writer.interface.writeAll("id,uri,preview,metadata_size\n");

    for (blocks) |block| {
        try ctx.writer.interface.print("{},\"{s}\",\"{s}\",{d}\n", .{
            block.id,
            block.uri[0..block.uri_len],
            block.content_preview[0..block.content_preview_len],
            block.metadata_size,
        });
    }
}

pub fn render_error(ctx: *RenderContext, message: []const u8) !void {
    switch (ctx.format) {
        .text => {
            try ctx.write_colored(RenderContext.Color.red, "Error: ");
            try ctx.writer.interface.print("{s}\n", .{message});
        },
        .json => {
            try ctx.writer.interface.print("{{\"error\":\"{s}\"}}\n", .{message});
        },
        .csv => {
            try ctx.writer.interface.print("error\n\"{s}\"\n", .{message});
        },
    }
}

pub fn render_operation_result(ctx: *RenderContext, response: protocol.OperationResponse) !void {
    const message = response.message_text();

    switch (ctx.format) {
        .text => {
            if (response.success) {
                try ctx.write_colored(RenderContext.Color.green, "✓ ");
                try ctx.writer.interface.print("{s}\n", .{message});
            } else {
                try ctx.write_colored(RenderContext.Color.red, "✗ ");
                try ctx.writer.interface.print("{s}\n", .{message});
            }
        },
        .json => {
            try ctx.writer.interface.print("{{\"success\":{},\"message\":\"{s}\"}}\n", .{ response.success, message });
        },
        .csv => {
            try ctx.writer.interface.print("success,message\n{},\"{s}\"\n", .{ response.success, message });
        },
    }
}

pub fn render_show_results(ctx: *RenderContext, response: protocol.ShowResponse, direction: []const u8) !void {
    const blocks = response.blocks[0..response.block_count];

    if (blocks.len == 0) {
        switch (ctx.format) {
            .text => try ctx.writer.interface.print("No {s} found.\n", .{direction}),
            .json => try ctx.writer.interface.print("{{\"direction\":\"{s}\",\"results\":[]}}\n", .{direction}),
            .csv => try ctx.writer.interface.writeAll("id,uri,relationship\n"),
        }
        return;
    }

    switch (ctx.format) {
        .text => try render_show_results_text(ctx, blocks, direction),
        .json => try render_show_results_json(ctx, blocks, direction),
        .csv => try render_show_results_csv(ctx, blocks, direction),
    }
}

fn render_show_results_text(ctx: *RenderContext, blocks: []const protocol.BlockInfo, direction: []const u8) !void {
    try ctx.writer.interface.print("Found {d} {s}:\n\n", .{ blocks.len, direction });

    for (blocks, 0..) |block, i| {
        const indent = "  ";
        try ctx.writer.interface.writeAll(indent);

        // Arrow indicating direction
        if (std.mem.eql(u8, direction, "callers")) {
            try ctx.write_colored(RenderContext.Color.yellow, "← ");
        } else {
            try ctx.write_colored(RenderContext.Color.yellow, "→ ");
        }

        // URI
        const uri = block.uri[0..block.uri_len];
        try ctx.write_colored(RenderContext.Color.blue, uri);
        try ctx.writer.interface.writeAll("\n");

        if (i < blocks.len - 1) {
            try ctx.writer.interface.writeAll("\n");
        }
    }
}

fn render_show_results_json(ctx: *RenderContext, blocks: []const protocol.BlockInfo, direction: []const u8) !void {
    try ctx.writer.interface.print("{{\"direction\":\"{s}\",\"results\":[\n", .{direction});

    for (blocks, 0..) |block, i| {
        try ctx.writer.interface.print("  {{\"id\":\"{}\",\"uri\":\"{s}\"}}", .{
            block.id,
            block.uri[0..block.uri_len],
        });

        if (i < blocks.len - 1) {
            try ctx.writer.interface.writeAll(",");
        }
        try ctx.writer.interface.writeAll("\n");
    }

    try ctx.writer.interface.writeAll("]}\n");
}

fn render_show_results_csv(ctx: *RenderContext, blocks: []const protocol.BlockInfo, direction: []const u8) !void {
    try ctx.writer.interface.writeAll("id,uri,direction\n");

    for (blocks) |block| {
        try ctx.writer.interface.print("{},\"{s}\",\"{s}\"\n", .{
            block.id,
            block.uri[0..block.uri_len],
            direction,
        });
    }
}
