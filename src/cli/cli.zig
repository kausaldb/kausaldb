//! Main CLI coordinator for KausalDB
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

/// CLI coordinator managing command execution lifecycle
pub const CLI = struct {
    allocator: std.mem.Allocator,
    config: CLIConfig,
    client: ?Client,
    render_ctx: RenderContext,
    stdout_buffer: [4096]u8,

    /// CLI configuration
    pub const CLIConfig = struct {
        server_host: []const u8 = "127.0.0.1",
        server_port: u16 = 3838,
        timeout_ms: u32 = 5000,
        output_format: parser.OutputFormat = .text,
    };

    /// Initialize CLI coordinator (cold init, no I/O)
    pub fn init(allocator: std.mem.Allocator, config: CLIConfig) CLI {
        var cli = CLI{
            .allocator = allocator,
            .config = config,
            .client = null,
            .render_ctx = undefined,
            .stdout_buffer = undefined,
        };

        const stdout_file = std.fs.File{ .handle = 1 };
        const stdout = stdout_file.writer(cli.stdout_buffer[0..]);
        cli.render_ctx = RenderContext.init(allocator, stdout, config.output_format);

        return cli;
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
            .ping => try self.execute_ping(),
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
        try renderer.render_help(&self.render_ctx, cmd.topic);
        try self.render_ctx.flush();
    }

    fn execute_version(self: *CLI) !void {
        try renderer.render_version(&self.render_ctx, "v0.1.0");
        try self.render_ctx.flush();
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
                        &self.render_ctx,
                        protocol.OperationResponse.init(true, "Server is running"),
                    );
                    try self.render_ctx.flush();
                } else {
                    try renderer.render_operation_result(
                        &self.render_ctx,
                        protocol.OperationResponse.init(false, "Server is not running"),
                    );
                    try self.render_ctx.flush();
                }
            },
            .start => {
                // Server start is handled by separate server binary or process
                try renderer.render_error(&self.render_ctx, "Use 'kausal-server' to start the server");
                try self.render_ctx.flush();
            },
            .stop, .restart => {
                try renderer.render_error(&self.render_ctx, "Server management not yet implemented");
                try self.render_ctx.flush();
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
                        &self.render_ctx,
                        "Server not running. Start it with: kausal server start",
                    );
                },
                else => {
                    try renderer.render_error(
                        &self.render_ctx,
                        try std.fmt.allocPrint(self.allocator, "Connection failed: {}", .{err}),
                    );
                },
            }
            return err;
        };

        self.client = c;
    }

    fn execute_ping(self: *CLI) !void {
        try self.ensure_connected();
        try self.client.?.ping();
        try renderer.render_operation_result(
            &self.render_ctx,
            protocol.OperationResponse.init(true, "Server is responding"),
        );
        try self.render_ctx.flush();
    }

    fn execute_status(self: *CLI, cmd: parser.StatusCommand) !void {
        // Update render context format if specified
        if (cmd.format != self.config.output_format) {
            self.render_ctx.format = cmd.format;
        }

        try self.ensure_connected();
        const status = try self.client.?.query_status();
        try renderer.render_status(&self.render_ctx, status, cmd.verbose);
        try self.render_ctx.flush();
    }

    fn execute_find(self: *CLI, cmd: parser.FindCommand) !void {
        if (cmd.format != self.config.output_format) {
            self.render_ctx.format = cmd.format;
        }

        try self.ensure_connected();

        // Convert EntityType to string for server
        const type_str = switch (cmd.type) {
            .function => "function",
            .struct_type => "struct",
            .variable => "variable",
            .constant => "constant",
        };

        // Construct query with type and workspace info for server to parse
        const query = if (cmd.workspace) |workspace| blk: {
            if (type_str.len > 0) {
                break :blk try std.fmt.allocPrint(self.allocator, "workspace:{s} type:{s} name:{s}", .{ workspace, type_str, cmd.name });
            } else {
                break :blk try std.fmt.allocPrint(self.allocator, "workspace:{s} name:{s}", .{ workspace, cmd.name });
            }
        } else blk: {
            if (type_str.len > 0) {
                break :blk try std.fmt.allocPrint(self.allocator, "type:{s} name:{s}", .{ type_str, cmd.name });
            } else {
                break :blk try std.fmt.allocPrint(self.allocator, "name:{s}", .{cmd.name});
            }
        };
        defer self.allocator.free(query);

        const response = try self.client.?.find_blocks(query, cmd.max_results);
        try renderer.render_find_results(&self.render_ctx, response, cmd.show_metadata);
        try self.render_ctx.flush();
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
                try renderer.render_error(&self.render_ctx, "Import/export queries not yet implemented");
                return;
            },
        };

        const direction_str = switch (cmd.direction) {
            .callers => "callers",
            .callees => "callees",
            .imports => "imports",
            .exports => "exports",
        };

        try renderer.render_show_results(&self.render_ctx, response, direction_str);
        try self.render_ctx.flush();
    }

    fn execute_trace(self: *CLI, cmd: parser.TraceCommand) !void {
        if (cmd.format != self.config.output_format) {
            self.render_ctx.format = cmd.format;
        }

        try self.ensure_connected();
        const response = try self.client.?.trace_paths(cmd.target, cmd.target, cmd.max_depth);

        // TODO: Implement graph visualization. For now, just show a simple result
        if (response.path_count > 0) {
            const direction_str = if (cmd.direction == .callers) "callers of" else "callees of";
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "Found {d} path(s) for {s} '{s}'",
                .{ response.path_count, direction_str, cmd.target },
            );
            defer self.allocator.free(msg);

            try renderer.render_operation_result(
                &self.render_ctx,
                protocol.OperationResponse.init(true, msg),
            );
        } else {
            const direction_str = if (cmd.direction == .callers) "callers of" else "callees of";
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "No paths found for {s} '{s}'",
                .{ direction_str, cmd.target },
            );
            defer self.allocator.free(msg);

            try renderer.render_operation_result(
                &self.render_ctx,
                protocol.OperationResponse.init(false, msg),
            );
        }
        try self.render_ctx.flush();
    }

    fn execute_link(self: *CLI, cmd: parser.LinkCommand) !void {
        if (cmd.format != self.config.output_format) {
            self.render_ctx.format = cmd.format;
        }

        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const resolved_path = std.fs.cwd().realpath(cmd.path, &path_buffer) catch |err| {
            const msg = try std.fmt.allocPrint(self.allocator, "Path '{s}' does not exist", .{cmd.path});
            defer self.allocator.free(msg);
            try renderer.render_error(&self.render_ctx, msg);
            return err;
        };

        // Derive name from path if not provided
        const name = cmd.name orelse blk: {
            const basename = std.fs.path.basename(resolved_path);
            break :blk basename;
        };

        try self.ensure_connected();
        const response = try self.client.?.link_codebase(resolved_path, name);
        try renderer.render_operation_result(&self.render_ctx, response);
        try self.render_ctx.flush();
    }

    fn execute_unlink(self: *CLI, cmd: parser.UnlinkCommand) !void {
        if (cmd.format != self.config.output_format) {
            self.render_ctx.format = cmd.format;
        }

        try self.ensure_connected();
        const response = try self.client.?.unlink_codebase(cmd.name);
        try renderer.render_operation_result(&self.render_ctx, response);
        try self.render_ctx.flush();
    }

    fn execute_sync(self: *CLI, cmd: parser.SyncCommand) !void {
        if (cmd.format != self.config.output_format) {
            self.render_ctx.format = cmd.format;
        }

        try self.ensure_connected();

        if (cmd.all) {
            // Sync all linked codebases - not yet implemented on server side
            // For now, pass special marker that server can recognize
            const response = try self.client.?.sync_workspace("--all", cmd.force);
            try renderer.render_operation_result(&self.render_ctx, response);
        } else {
            const workspace_name = cmd.name orelse "default";
            const response = try self.client.?.sync_workspace(workspace_name, cmd.force);
            try renderer.render_operation_result(&self.render_ctx, response);
        }

        try self.render_ctx.flush();
    }
};

/// Main entry point for CLI
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

    const parse_result = parser.parse_command_with_globals(args) catch |err| {
        var stderr_buffer: [4096]u8 = undefined;
        const stderr_file = std.fs.File{ .handle = 2 };
        var stderr = stderr_file.writer(stderr_buffer[0..]);
        switch (err) {
            parser.ParseError.UnknownCommand => {
                if (args.len >= 2) {
                    try (&stderr.interface).print("Unknown command: {s}\n", .{args[1]});
                }
                try stderr.interface.writeAll("Run 'kausal help' for usage information\n");
                try stderr.interface.flush();
            },
            parser.ParseError.MissingArgument => {
                try stderr.interface.writeAll("Missing required argument\n");
                try stderr.interface.writeAll("Run 'kausal help' for usage information\n");
                try stderr.interface.flush();
            },
            parser.ParseError.InvalidArgument => {
                try stderr.interface.writeAll("Invalid argument\n");
                try stderr.interface.writeAll("Run 'kausal help' for usage information\n");
                try stderr.interface.flush();
            },
            else => {
                try (&stderr.interface).print("Error: {}\n", .{err});
                try stderr.interface.flush();
            },
        }
        std.process.exit(1);
    };

    // Create CLI config with global options
    var cli_config = CLI.CLIConfig{};
    if (parse_result.global_options.port) |port| {
        cli_config.server_port = port;
    }
    if (parse_result.global_options.host) |host| {
        cli_config.server_host = host;
    }

    // Execute command
    var cli = CLI.init(allocator, cli_config);
    defer cli.deinit();

    cli.execute_command(parse_result.command) catch |err| {
        var stderr_buffer2: [4096]u8 = undefined;
        const stderr_file2 = std.fs.File{ .handle = 2 };
        var stderr = stderr_file2.writer(stderr_buffer2[0..]);

        switch (err) {
            client_mod.ClientError.ServerNotRunning => {
                std.process.exit(1);
            },
            else => {
                try (&stderr.interface).print("Error: {}\n", .{err});
                try stderr.interface.flush();
                std.process.exit(1);
            },
        }
    };
}
