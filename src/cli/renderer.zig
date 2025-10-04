//! Output renderer for CLI.
//!
//! Transforms command results into human-readable or machine-parsable formats.
//! Provides consistent, professional output across all CLI commands.

const std = @import("std");

const protocol = @import("protocol.zig");
const parser = @import("parser.zig");
const types = @import("../core/types.zig");

const BlockId = types.BlockId;
const OutputFormat = parser.OutputFormat;

const log = std.log.scoped(.renderer);

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
            try self.write(text);
        }
    }

    pub fn write(self: *RenderContext, bytes: []const u8) !void {
        try self.writer.interface.writeAll(bytes);
    }

    pub fn flush(self: *RenderContext) !void {
        try self.writer.interface.flush();
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
        try ctx.write("{\"error\":\"Help only available in text format\"}\n");
        return;
    }

    try ctx.write_colored(RenderContext.Color.bold, "KausalDB - Graph Database for AI Context\n\n");

    try ctx.write_colored(RenderContext.Color.yellow, "Usage:\n");
    try ctx.write("  kausal <command> [arguments]\n\n");

    try ctx.write_colored(RenderContext.Color.yellow, "Core Commands:\n");
    try ctx.write("  help [topic]           Show help for a command\n");
    try ctx.write("  version                Show version information\n");
    try ctx.write("  server [mode]          Manage the KausalDB server\n");
    try ctx.write("  status                 Show database status\n");
    try ctx.write("  ping                   Check server connectivity\n\n");

    try ctx.write_colored(RenderContext.Color.yellow, "Query Commands:\n");
    try ctx.write("  find --type <type> --name <name>         Find entities (supports qualified names: Struct.method)\n");
    try ctx.write("  show --relation <dir> --target <name>    Show relationships (callers/callees/imports/exports)\n");
    try ctx.write("  trace --direction <dir> --target <name>  Trace paths from target\n\n");

    try ctx.write_colored(RenderContext.Color.yellow, "Workspace Commands:\n");
    try ctx.write("  link --path <path> --name <name>  Link a codebase to workspace\n");
    try ctx.write("  unlink --name <name>              Remove a codebase from workspace\n");
    try ctx.write("  sync [<name>]                     Sync workspace with filesystem\n\n");

    try ctx.write_colored(RenderContext.Color.dim, "Run 'kausal help <command>' for detailed information\n");
}

fn render_command_help(ctx: *RenderContext, command: []const u8) !void {
    if (ctx.format != .text) {
        try ctx.write("{\"error\":\"Help only available in text format\"}\n");
        return;
    }

    if (std.mem.eql(u8, command, "find")) {
        try ctx.write_colored(RenderContext.Color.bold, "kausal find - Find entities by type and name\n\n");
        try ctx.write("Usage: kausal find --type <type> --name <name> [options]\n\n");
        try ctx.write("Entity Types:\n");
        try ctx.write("  function           Find functions\n");
        try ctx.write("  struct             Find struct types\n");
        try ctx.write("  constant           Find constants\n");
        try ctx.write("  variable           Find variables\n\n");
        try ctx.write("Name Syntax:\n");
        try ctx.write("  Simple names:      parse_command, init, deinit\n");
        try ctx.write("  Qualified names:   StorageEngine.init, QueryEngine.deinit\n");
        try ctx.write("                     Use 'StructName.method_name' to disambiguate methods\n\n");
        try ctx.write("Options:\n");
        try ctx.write("  --workspace <name> Search in specific workspace\n");
        try ctx.write("  --format <fmt>     Output format: text, json (default: text)\n");
        try ctx.write("  --max-results <n>  Maximum results to return (default: 10)\n");
        try ctx.write("  --show-metadata    Include block metadata in output\n\n");
        try ctx.write("Examples:\n");
        try ctx.write("  kausal find --type function --name parse_command\n");
        try ctx.write("  kausal find --type function --name StorageEngine.init\n");
        try ctx.write("  kausal find --type struct --name StorageEngine --workspace myproject\n");
    } else if (std.mem.eql(u8, command, "server")) {
        try ctx.write_colored(RenderContext.Color.bold, "kausal server - Manage the KausalDB server\n\n");
        try ctx.write("Usage: kausal server [mode] [options]\n\n");
        try ctx.write("Modes:\n");
        try ctx.write("  start     Start the server (default)\n");
        try ctx.write("  stop      Stop the running server\n");
        try ctx.write("  restart   Restart the server\n");
        try ctx.write("  status    Check server status\n\n");
        try ctx.write("Options:\n");
        try ctx.write("  --host <addr>      Bind address (default: 127.0.0.1)\n");
        try ctx.write("  --port <port>      Port number (default: 3838)\n");
        try ctx.write("  --data-dir <path>  Data directory (default: .kausal-data)\n");
        try ctx.write("  --foreground       Run in foreground mode\n");
    } else if (std.mem.eql(u8, command, "show")) {
        try ctx.write_colored(RenderContext.Color.bold, "kausal show - Show relationships for an entity\n\n");
        try ctx.write("Usage: kausal show --relation <direction> --target <target> [options]\n\n");
        try ctx.write("Directions:\n");
        try ctx.write("  callers            Show what calls this entity\n");
        try ctx.write("  callees            Show what this entity calls\n");
        try ctx.write("  imports            Show what this entity imports\n");
        try ctx.write("  exports            Show what this entity exports\n\n");
        try ctx.write("Options:\n");
        try ctx.write("  --workspace <name> Search in specific workspace\n");
        try ctx.write("  --format <fmt>     Output format: text, json (default: text)\n");
        try ctx.write("  --max-depth <n>    Maximum traversal depth (default: 3)\n\n");
        try ctx.write("Examples:\n");
        try ctx.write("  kausal show --relation callers --target authenticate_user\n");
        try ctx.write("  kausal show --relation callees --target StorageEngine.init --max-depth 2\n");
    } else if (std.mem.eql(u8, command, "trace")) {
        try ctx.write_colored(RenderContext.Color.bold, "kausal trace - Trace execution paths from an entity\n\n");
        try ctx.write("Usage: kausal trace --direction <direction> --target <target> [options]\n\n");
        try ctx.write("Directions:\n");
        try ctx.write("  callers            Trace caller chains\n");
        try ctx.write("  callees            Trace callee chains\n\n");
        try ctx.write("Options:\n");
        try ctx.write("  --workspace <name> Search in specific workspace\n");
        try ctx.write("  --format <fmt>     Output format: text, json (default: text)\n");
        try ctx.write("  --max-depth <n>    Maximum traversal depth (default: 10)\n");
        try ctx.write("  --all-paths        Show all paths, not just shortest\n\n");
        try ctx.write("Examples:\n");
        try ctx.write("  kausal trace --direction callees --target main --max-depth 5\n");
        try ctx.write("  kausal trace --direction callers --target error_handler --all-paths\n");
    } else if (std.mem.eql(u8, command, "link")) {
        try ctx.write_colored(RenderContext.Color.bold, "kausal link - Link a codebase to workspace\n\n");
        try ctx.write("Usage: kausal link --path <path> [--name <name>] [options]\n\n");
        try ctx.write("Required Arguments:\n");
        try ctx.write("  --path <path>      Path to codebase directory\n\n");
        try ctx.write("Options:\n");
        try ctx.write("  --name <name>      Workspace name (defaults to directory name)\n");
        try ctx.write("  --format <fmt>     Output format: text, json (default: text)\n\n");
        try ctx.write("Examples:\n");
        try ctx.write("  kausal link --path /path/to/project\n");
        try ctx.write("  kausal link --path /path/to/project --name myproject\n");
    } else if (std.mem.eql(u8, command, "sync")) {
        try ctx.write_colored(RenderContext.Color.bold, "kausal sync - Sync workspace with filesystem\n\n");
        try ctx.write("Usage: kausal sync [<name>] [options]\n\n");
        try ctx.write("Arguments:\n");
        try ctx.write("  <name>             Workspace name (optional, syncs all if omitted)\n\n");
        try ctx.write("Options:\n");
        try ctx.write("  --force            Force resync even if no changes detected\n");
        try ctx.write("  --all              Sync all workspaces (same as omitting name)\n");
        try ctx.write("  --format <fmt>     Output format: text, json (default: text)\n\n");
        try ctx.write("Examples:\n");
        try ctx.write("  kausal sync\n");
        try ctx.write("  kausal sync myproject\n");
        try ctx.write("  kausal sync --force --all\n");
    } else if (std.mem.eql(u8, command, "unlink")) {
        try ctx.write_colored(RenderContext.Color.bold, "kausal unlink - Remove a codebase from workspace\n\n");
        try ctx.write("Usage: kausal unlink --name <name> [options]\n\n");
        try ctx.write("Required Arguments:\n");
        try ctx.write("  --name <name>      Name of workspace to remove\n\n");
        try ctx.write("Options:\n");
        try ctx.write("  --format <fmt>     Output format: text, json (default: text)\n\n");
        try ctx.write("Examples:\n");
        try ctx.write("  kausal unlink --name myproject\n");
        try ctx.write("  kausal unlink --name backend --format json\n");
    } else {
        try ctx.writer.interface.print("No help available for command: {s}\n", .{command});
    }
}

pub fn render_status(ctx: *RenderContext, status: protocol.StatusResponse, verbose: bool) !void {
    switch (ctx.format) {
        .text => try render_status_text(ctx, &status, verbose),
        .json => try render_status_json(ctx, &status),
        .csv => try render_status_csv(ctx, &status),
    }
}

fn render_status_text(ctx: *RenderContext, status: *const protocol.StatusResponse, verbose: bool) !void {
    const uptime_str = try protocol.format_uptime(ctx.allocator, status.uptime_seconds);
    defer ctx.allocator.free(uptime_str);

    const total_storage_str = try protocol.format_bytes(ctx.allocator, status.total_disk_usage);
    defer ctx.allocator.free(total_storage_str);

    const current_time = std.time.timestamp();

    // Header with primary information
    try ctx.write_colored(RenderContext.Color.bold, "KausalDB Status\n");
    try ctx.write("├─ Server: ");
    try ctx.write_colored(RenderContext.Color.green, "Running");
    try ctx.writer.interface.print(" (uptime: {s})\n", .{uptime_str});

    const workspaces = status.workspaces_slice();
    try ctx.writer.interface.print("├─ Workspaces: {d} linked\n", .{workspaces.len});
    try ctx.writer.interface.print("└─ Storage: {s} used\n", .{total_storage_str});

    if (workspaces.len > 0) {
        try ctx.write("\n");
        try ctx.write_colored(RenderContext.Color.blue, "Workspaces:\n");

        for (workspaces) |*workspace| {
            const name = workspace.name_text();
            const name_copy = try ctx.allocator.dupe(u8, name);
            defer ctx.allocator.free(name_copy);

            log.debug(
                "Client: Received workspace name='{s}' sync_status={}",
                .{ name_copy, @intFromEnum(workspace.sync_status) },
            );

            const storage_str = try workspace.format_storage_size(ctx.allocator);
            defer ctx.allocator.free(storage_str);

            const last_sync_str = try workspace.format_last_sync(ctx.allocator, current_time);
            defer ctx.allocator.free(last_sync_str);

            const icon = workspace.status_icon();
            const status_text = workspace.status_text();

            const icon_copy = try ctx.allocator.dupe(u8, icon);
            defer ctx.allocator.free(icon_copy);

            const status_copy = try ctx.allocator.dupe(u8, status_text);
            defer ctx.allocator.free(status_copy);

            const raw_value = @intFromEnum(workspace.sync_status);
            const icon_color = if (raw_value > 3) RenderContext.Color.red else switch (workspace.sync_status) {
                .synced => RenderContext.Color.green,
                .needs_sync, .never_synced => RenderContext.Color.yellow,
                .sync_error => RenderContext.Color.red,
            };

            try ctx.write("  ");
            try ctx.write_colored(icon_color, icon_copy);

            // Use a separate format string buffer to avoid aliasing
            const workspace_line = try std.fmt.allocPrint(
                ctx.allocator,
                " {s:<15} {s} {s:<8} ({s})\n",
                .{ name_copy, status_copy, last_sync_str, storage_str },
            );
            defer ctx.allocator.free(workspace_line);
            try ctx.write(workspace_line);
        }
    } else {
        try ctx.write("\n");
        try ctx.write_colored(
            RenderContext.Color.dim,
            "No workspaces linked. Use 'kausal link' to add codebases.\n",
        );
    }

    if (verbose) {
        try ctx.write("\n");
        try ctx.write_colored(RenderContext.Color.dim, "Developer Info:\n");
        try ctx.writer.interface.print(
            "├─ Performance: {d} blocks, {d} edges indexed\n",
            .{ status.block_count, status.edge_count },
        );

        const memtable_str = try protocol.format_bytes(ctx.allocator, status.memtable_size);
        defer ctx.allocator.free(memtable_str);

        try ctx.writer.interface.print(
            "├─ Storage: {d} SSTables, {s} memtable\n",
            .{ status.sstable_count, memtable_str },
        );
        try ctx.writer.interface.print("└─ Uptime: {d} seconds\n", .{status.uptime_seconds});

        if (workspaces.len > 0) {
            try ctx.write("\n");
            try ctx.write_colored(RenderContext.Color.dim, "Workspace Details:\n");
            for (workspaces) |*workspace| {
                const name = workspace.name_text();
                const path = workspace.path_text();
                const storage_str = try workspace.format_storage_size(ctx.allocator);
                defer ctx.allocator.free(storage_str);

                try ctx.writer.interface.print(
                    "  {s:<15} {s} ({d} blocks, {d} edges)\n",
                    .{ name, storage_str, workspace.block_count, workspace.edge_count },
                );

                const display_path = if (path.len > 60) path[path.len - 60 ..] else path;
                try ctx.writer.interface.print("                  Path: {s}\n", .{display_path});
            }
        }
    }
}

fn render_status_json(ctx: *RenderContext, status: *const protocol.StatusResponse) !void {
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

fn render_status_csv(ctx: *RenderContext, status: *const protocol.StatusResponse) !void {
    try ctx.write("metric,value\n");
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
            .text => try ctx.write("No results found.\n"),
            .json => try ctx.write("{\"results\":[]}\n"),
            .csv => try ctx.write("id,uri,preview\n"),
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
        const index_str = try std.fmt.allocPrint(ctx.allocator, "[{d}] ", .{i + 1});
        defer ctx.allocator.free(index_str);
        try ctx.write_colored(
            RenderContext.Color.cyan,
            index_str,
        );

        // Create defensive copy to prevent memory aliasing
        const uri = block.uri[0..block.uri_len];
        const uri_copy = try ctx.allocator.dupe(u8, uri);
        defer ctx.allocator.free(uri_copy);
        try ctx.write_colored(RenderContext.Color.blue, uri_copy);
        try ctx.write("\n");

        try ctx.writer.interface.print("    ID: {}\n", .{block.to_block_id()});

        if (block.content_preview_len > 0) {
            try ctx.write("    Preview: ");
            // Create defensive copy to prevent memory aliasing
            const preview = block.content_preview[0..@min(block.content_preview_len, 80)];
            const preview_copy = try ctx.allocator.dupe(u8, preview);
            defer ctx.allocator.free(preview_copy);
            try ctx.write(preview_copy);
            if (block.content_preview_len > 80) {
                try ctx.write("...");
            }
            try ctx.write("\n");
        }

        if (show_metadata and block.metadata_size > 0) {
            try ctx.writer.interface.print("    Metadata: {d} bytes\n", .{block.metadata_size});
        }

        if (i < blocks.len - 1) {
            try ctx.write("\n");
        }
    }
}

fn render_find_results_json(ctx: *RenderContext, blocks: []const protocol.BlockInfo) !void {
    try ctx.write("{\"results\":[\n");

    for (blocks, 0..) |*block, i| {
        const id_hex = try block.to_block_id().to_hex(ctx.allocator);
        defer ctx.allocator.free(id_hex);

        try ctx.write("  {\"id\":");
        const id_json = try std.json.Stringify.valueAlloc(ctx.allocator, id_hex, .{});
        defer ctx.allocator.free(id_json);
        try ctx.write(id_json);

        try ctx.write(",\"uri\":");
        // Create defensive copy to prevent memory aliasing
        const uri_text = block.uri[0..block.uri_len];
        const uri_copy = try ctx.allocator.dupe(u8, uri_text);
        defer ctx.allocator.free(uri_copy);
        const uri_json = try std.json.Stringify.valueAlloc(ctx.allocator, uri_copy, .{});
        defer ctx.allocator.free(uri_json);
        try ctx.write(uri_json);

        try ctx.write(",\"preview\":");

        // Create defensive copy and safely handle potentially corrupted preview data
        const preview_data = block.content_preview[0..block.content_preview_len];
        const preview_copy = try ctx.allocator.dupe(u8, preview_data);
        defer ctx.allocator.free(preview_copy);

        const preview_json = if (std.unicode.utf8ValidateSlice(preview_copy))
            try std.json.Stringify.valueAlloc(ctx.allocator, preview_copy, .{})
        else
            try std.json.Stringify.valueAlloc(ctx.allocator, preview_copy, .{});
        defer ctx.allocator.free(preview_json);
        try ctx.write(preview_json);

        try ctx.write(",\"metadata_size\":");
        try ctx.writer.interface.print("{d}", .{block.metadata_size});
        try ctx.write("}");

        if (i < blocks.len - 1) {
            try ctx.write(",");
        }
        try ctx.write("\n");
    }

    try ctx.write("]}\n");
}

fn render_find_results_csv(ctx: *RenderContext, blocks: []const protocol.BlockInfo) !void {
    try ctx.write("id,uri,preview,metadata_size\n");

    for (blocks) |block| {
        try ctx.writer.interface.print("{},\"{s}\",\"{s}\",{d}\n", .{
            block.to_block_id(),
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
            .csv => try ctx.write("id,uri,relationship\n"),
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
        try ctx.write(indent);

        if (std.mem.eql(u8, direction, "callers")) {
            try ctx.write_colored(RenderContext.Color.yellow, "← ");
        } else {
            try ctx.write_colored(RenderContext.Color.yellow, "→ ");
        }

        // Prevent memory aliasing with copy
        const uri = block.uri[0..block.uri_len];
        const uri_copy = try ctx.allocator.dupe(u8, uri);
        defer ctx.allocator.free(uri_copy);
        try ctx.write_colored(RenderContext.Color.blue, uri_copy);
        try ctx.write("\n");

        if (i < blocks.len - 1) {
            try ctx.write("\n");
        }
    }
}

fn render_show_results_json(ctx: *RenderContext, blocks: []const protocol.BlockInfo, direction: []const u8) !void {
    // Prevent memory aliasing with copy
    const direction_copy = try ctx.allocator.dupe(u8, direction);
    defer ctx.allocator.free(direction_copy);
    const direction_json = try std.json.Stringify.valueAlloc(ctx.allocator, direction_copy, .{});
    defer ctx.allocator.free(direction_json);

    try ctx.writer.interface.print("{{\"direction\":{s},\"results\":[\n", .{direction_json});

    for (blocks, 0..) |block, i| {
        const id_hex = try block.to_block_id().to_hex(ctx.allocator);
        defer ctx.allocator.free(id_hex);
        const id_json = try std.json.Stringify.valueAlloc(ctx.allocator, id_hex, .{});
        defer ctx.allocator.free(id_json);

        // Prevent memory aliasing with copy
        const uri_text = block.uri[0..block.uri_len];
        const uri_copy = try ctx.allocator.dupe(u8, uri_text);
        defer ctx.allocator.free(uri_copy);
        const uri_json = try std.json.Stringify.valueAlloc(ctx.allocator, uri_copy, .{});
        defer ctx.allocator.free(uri_json);

        try ctx.writer.interface.print("  {{\"id\":{s},\"uri\":{s}}}", .{ id_json, uri_json });

        if (i < blocks.len - 1) {
            try ctx.write(",");
        }
        try ctx.write("\n");
    }

    try ctx.write("]}\n");
}

fn render_show_results_csv(ctx: *RenderContext, blocks: []const protocol.BlockInfo, direction: []const u8) !void {
    try ctx.write("id,uri,direction\n");

    for (blocks) |block| {
        try ctx.writer.interface.print("{},\"{s}\",\"{s}\"\n", .{
            block.to_block_id(),
            block.uri[0..block.uri_len],
            direction,
        });
    }
}
