//! Main CLI coordinator for KausalDB v2.
//!
//! Orchestrates command parsing, client communication, and output rendering.
//! Implements thin client architecture for <10ms command latency.

const std = @import("std");

const client_mod = @import("client.zig");
const parser = @import("parser.zig");
const protocol = @import("protocol.zig");
const renderer = @import("renderer.zig");

const Client = client_mod.Client;
const ClientConfig = client_mod.ClientConfig;
const Command = parser.Command;
const RenderContext = renderer.RenderContext;

const log = std.log.scoped(.cli);

/// Result type for executed commands
pub const CommandResult = union(enum) {
    find: protocol.FindResponse,
    show: protocol.ShowResponse,
    trace: protocol.TraceResponse,
    operation: protocol.OperationResponse,
    status: protocol.StatusResponse,
    ping: void,
};

/// CLI coordinator managing command execution lifecycle
pub const CLI = struct {
    allocator: std.mem.Allocator,
    config: CLIConfig,
    client: ?Client,
    render_ctx: RenderContext,

    /// CLI configuration
    pub const CLIConfig = struct {
        server_host: []const u8 = "127.0.0.1",
        server_port: u16 = 3838,
        timeout_ms: u32 = 5000,
        output_format: parser.OutputFormat = .text,
    };

    /// Initialize CLI coordinator (cold init, no I/O)
    pub fn init(allocator: std.mem.Allocator, config: CLIConfig) CLI {
        const stdout = std.io.getStdOut().writer();
        const render_ctx = RenderContext.init(allocator, stdout, config.output_format);

        return CLI{
            .allocator = allocator,
            .config = config,
            .client = null,
            .render_ctx = render_ctx,
        };
    }

    /// Deinitialize CLI and clean up resources
    pub fn deinit(self: *CLI) void {
        if (self.client) |*c| {
            c.deinit();
        }
    }

    /// Execute a parsed command
    pub fn execute_command(self: *CLI, command: Command) !void {
        switch (command) {
            .help => |cmd| try self.execute_help(cmd),
            .version => try self.execute_version(),
            .server => |cmd| try self.execute_server(cmd),
            .status => |cmd| try self.execute_status(cmd),
            .find => |cmd| try self.execute_find(cmd),
            .show => |cmd| try self.execute_show(cmd),
            .trace => |cmd| try self.execute_trace(cmd),
            .link => |cmd| try self.execute_link(cmd),
            .unlink => |cmd| try self.execute_unlink(cmd),
            .sync => |cmd| try self.execute_sync(cmd),
        }
    }

    // === Local Commands (No Server Required) ===

    fn execute_help(self: *CLI, cmd: parser.HelpCommand) !void {
        try renderer.render_help(self.render_ctx, cmd.topic);
    }

    fn execute_version(self: *CLI) !void {
        try renderer.render_version(self.render_ctx, "v0.1.0");
    }

    fn execute_server(self: *CLI, cmd: parser.ServerCommand) !void {
        switch (cmd.mode) {
            .status => {
                const client_config = ClientConfig{
                    .host = cmd.host,
                    .port = cmd.port,
                    .timeout_ms = 1000,
                };

                const is_running = Client.is_server_running(self.allocator, client_config);

                if (is_running) {
                    try renderer.render_operation_result(
                        self.render_ctx,
                        protocol.OperationResponse.init(true, "Server is running"),
                    );
                } else {
                    try renderer.render_operation_result(
                        self.render_ctx,
                        protocol.OperationResponse.init(false, "Server is not running"),
                    );
                }
            },
            .start => {
                // Server start is handled by separate server binary or process
                try renderer.render_error(self.render_ctx, "Use 'kausaldb-server' to start the server");
            },
            .stop, .restart => {
                try renderer.render_error(self.render_ctx, "Server management not yet implemented");
            },
        }
    }

    fn ensure_connected(self: *CLI) !void {
        if (self.client != null) return;

        var c = Client.init(self.allocator, ClientConfig{
            .host = self.config.server_host,
            .port = self.config.server_port,
            .timeout_ms = self.config.timeout_ms,
        });

        c.connect() catch |err| {
            switch (err) {
                client_mod.ClientError.ServerNotRunning => {
                    try renderer.render_error(
                        self.render_ctx,
                        "Server not running. Start it with: kausal server start",
                    );
                },
                else => {
                    try renderer.render_error(
                        self.render_ctx,
                        try std.fmt.allocPrint(self.allocator, "Connection failed: {}", .{err}),
                    );
                },
            }
            return err;
        };

        self.client = c;
    }

    fn execute_status(self: *CLI, cmd: parser.StatusCommand) !void {
        // Update render context format if specified
        if (cmd.format != self.config.output_format) {
            self.render_ctx.format = cmd.format;
        }

        try self.ensure_connected();
        const status = try self.client.?.query_status();
        try renderer.render_status(self.render_ctx, status, cmd.verbose);
    }

    fn execute_find(self: *CLI, cmd: parser.FindCommand) !void {
        if (cmd.format != self.config.output_format) {
            self.render_ctx.format = cmd.format;
        }

        try self.ensure_connected();
        const response = try self.client.?.find_blocks(cmd.query, cmd.max_results);
        try renderer.render_find_results(self.render_ctx, response, cmd.show_metadata);
    }

    fn execute_show(self: *CLI, cmd: parser.ShowCommand) !void {
        if (cmd.format != self.config.output_format) {
            self.render_ctx.format = cmd.format;
        }

        try self.ensure_connected();

        const response = switch (cmd.direction) {
            .callers => try self.client.?.show_callers(cmd.target, cmd.max_depth),
            .callees => try self.client.?.show_callees(cmd.target, cmd.max_depth),
            .imports, .exports => {
                try renderer.render_error(self.render_ctx, "Import/export queries not yet implemented");
                return;
            },
        };

        const direction_str = switch (cmd.direction) {
            .callers => "callers",
            .callees => "callees",
            .imports => "imports",
            .exports => "exports",
        };

        try renderer.render_show_results(self.render_ctx, response, direction_str);
    }

    fn execute_trace(self: *CLI, cmd: parser.TraceCommand) !void {
        if (cmd.format != self.config.output_format) {
            self.render_ctx.format = cmd.format;
        }

        try self.ensure_connected();
        const response = try self.client.?.trace_paths(cmd.source, cmd.target, cmd.max_depth);

        // TODO: Implement graph visualization. For now, just show a simple result
        if (response.path_count > 0) {
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "Found {d} path(s) from '{s}' to '{s}'",
                .{ response.path_count, cmd.source, cmd.target },
            );
            defer self.allocator.free(msg);

            try renderer.render_operation_result(
                self.render_ctx,
                protocol.OperationResponse.init(true, msg),
            );
        } else {
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "No path found from '{s}' to '{s}'",
                .{ cmd.source, cmd.target },
            );
            defer self.allocator.free(msg);

            try renderer.render_operation_result(
                self.render_ctx,
                protocol.OperationResponse.init(false, msg),
            );
        }
    }

    fn execute_link(self: *CLI, cmd: parser.LinkCommand) !void {
        if (cmd.format != self.config.output_format) {
            self.render_ctx.format = cmd.format;
        }

        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const resolved_path = std.fs.cwd().realpath(cmd.path, &path_buffer) catch |err| {
            const msg = try std.fmt.allocPrint(self.allocator, "Path '{s}' does not exist", .{cmd.path});
            defer self.allocator.free(msg);
            try renderer.render_error(self.render_ctx, msg);
            return err;
        };

        try self.ensure_connected();
        const response = try self.client.?.link_codebase(resolved_path, cmd.name);
        try renderer.render_operation_result(self.render_ctx, response);
    }

    fn execute_unlink(self: *CLI, cmd: parser.UnlinkCommand) !void {
        if (cmd.format != self.config.output_format) {
            self.render_ctx.format = cmd.format;
        }

        try self.ensure_connected();
        const response = try self.client.?.unlink_codebase(cmd.name);
        try renderer.render_operation_result(self.render_ctx, response);
    }

    fn execute_sync(self: *CLI, cmd: parser.SyncCommand) !void {
        if (cmd.format != self.config.output_format) {
            self.render_ctx.format = cmd.format;
        }

        const workspace_name = cmd.name orelse "default";

        try self.ensure_connected();
        const response = try self.client.?.sync_workspace(workspace_name, cmd.force);
        try renderer.render_operation_result(self.render_ctx, response);
    }
};

/// Main entry point for CLI v2
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len >= 2) {
        const first_arg = args[1];
        if (std.mem.eql(u8, first_arg, "--help") or std.mem.eql(u8, first_arg, "-h")) {
            const help_args = [_][]const u8{ args[0], "help" };
            const command = try parser.parse_command(&help_args);

            var cli = CLI.init(allocator, .{});
            defer cli.deinit();
            try cli.execute_command(command);
            return;
        }

        if (std.mem.eql(u8, first_arg, "--version") or std.mem.eql(u8, first_arg, "-v")) {
            const version_args = [_][]const u8{ args[0], "version" };
            const command = try parser.parse_command(&version_args);

            var cli = CLI.init(allocator, .{});
            defer cli.deinit();
            try cli.execute_command(command);
            return;
        }
    }

    const command = parser.parse_command(args) catch |err| {
        const stderr = std.io.getStdErr().writer();
        switch (err) {
            parser.ParseError.UnknownCommand => {
                if (args.len >= 2) {
                    try stderr.print("Unknown command: {s}\n", .{args[1]});
                }
                try stderr.writeAll("Run 'kausal help' for usage information\n");
            },
            parser.ParseError.MissingArgument => {
                try stderr.writeAll("Missing required argument\n");
                try stderr.writeAll("Run 'kausal help' for usage information\n");
            },
            parser.ParseError.InvalidArgument => {
                try stderr.writeAll("Invalid argument\n");
                try stderr.writeAll("Run 'kausal help' for usage information\n");
            },
            else => {
                try stderr.print("Error: {}\n", .{err});
            },
        }
        std.process.exit(1);
    };

    // Execute command
    var cli = CLI.init(allocator, .{});
    defer cli.deinit();

    cli.execute_command(command) catch |err| {
        const stderr = std.io.getStdErr().writer();

        switch (err) {
            client_mod.ClientError.ServerNotRunning => {
                std.process.exit(1);
            },
            else => {
                try stderr.print("Error: {}\n", .{err});
                std.process.exit(1);
            },
        }
    };
}
