//! Server configuration management for KausalDB.
//!
//! Centralizes all server configuration with type-safe validation and defaults.
//! Follows KausalDB philosophy of explicit configuration over magic values.

const std = @import("std");
const stdx = @import("../core/stdx.zig");

/// Check if a string matches any in a list of alternatives
inline fn matches(str: []const u8, alternatives: []const []const u8) bool {
    for (alternatives) |alt| {
        if (std.mem.eql(u8, str, alt)) return true;
    }
    return false;
}

/// Server configuration for both daemon and network operations
pub const ServerConfig = struct {
    /// Network binding configuration
    host: []const u8 = "127.0.0.1",
    port: u16 = 3838,

    /// Database configuration
    data_dir: []const u8 = ".kausaldb_data",

    /// Connection management configuration
    max_connections: u32 = 100,
    connection_timeout_sec: u32 = 300,
    max_request_size: u32 = 64 * 1024, // 64KB
    max_response_size: u32 = 16 * 1024 * 1024, // 16MB

    /// Daemon configuration
    daemonize: bool = true,
    log_level: std.log.Level = .info,

    /// Operational configuration
    /// Platform-appropriate defaults should be computed
    enable_logging: bool = false,
    log_dir: ?[]const u8 = null,
    pid_dir: ?[]const u8 = null,

    // Production logging configuration
    log_rotation_size_mb: u32 = 100,
    log_retention_days: u32 = 30,
    structured_logging: bool = false, // JSON format
    enable_hot_path_logging: bool = false,

    // Performance tuning
    stats_update_interval_sec: u32 = 10, // Statistics update frequency

    /// Validate configuration for consistency and safety
    pub fn validate(self: ServerConfig) !void {
        if (self.port == 0) return error.InvalidPort;
        if (self.max_connections == 0) return error.InvalidMaxConnections;
        if (self.connection_timeout_sec == 0) return error.InvalidTimeout;
        if (self.max_request_size == 0) return error.InvalidRequestSize;
        if (self.max_response_size == 0) return error.InvalidResponseSize;
        if (self.data_dir.len == 0) return error.InvalidDataDir;
    }

    /// Convert to connection-level configuration for NetworkServer
    pub fn to_connection_config(self: ServerConfig) ConnectionConfig {
        return ConnectionConfig{
            .max_request_size = self.max_request_size,
            .max_response_size = self.max_response_size,
            .enable_logging = self.enable_logging,
        };
    }

    /// Convert to connection manager configuration
    pub fn to_connection_manager_config(self: ServerConfig) ConnectionManagerConfig {
        return ConnectionManagerConfig{
            .max_connections = self.max_connections,
            .connection_timeout_sec = self.connection_timeout_sec,
            .poll_timeout_ms = 1000, // Standard poll timeout
        };
    }

    /// Resolve log directory path using platform-appropriate defaults
    /// Caller owns returned memory and must free it
    pub fn resolve_log_dir(self: ServerConfig, allocator: std.mem.Allocator) ![]u8 {
        if (self.log_dir) |dir| {
            return allocator.dupe(u8, dir);
        }
        return stdx.resolve_user_data_dir(allocator, "kausaldb");
    }

    /// Resolve PID directory path using platform-appropriate defaults
    /// Caller owns returned memory and must free it
    pub fn resolve_pid_dir(self: ServerConfig, allocator: std.mem.Allocator) ![]u8 {
        if (self.pid_dir) |dir| {
            return allocator.dupe(u8, dir);
        }
        return stdx.resolve_user_runtime_dir(allocator, "kausaldb");
    }
};

/// Connection-specific configuration passed to individual connections
pub const ConnectionConfig = struct {
    max_request_size: u32,
    max_response_size: u32,
    enable_logging: bool,
};

/// Connection manager configuration for I/O operations
pub const ConnectionManagerConfig = struct {
    max_connections: u32,
    connection_timeout_sec: u32,
    poll_timeout_ms: i32,
};

/// Parse command-line arguments into ServerConfig
pub fn parse_server_args(_: std.mem.Allocator, args: []const []const u8) !ServerConfig {
    var config = ServerConfig{};

    // Skip first argument if it's a known command
    var i: usize = if (args.len > 0 and is_server_command(args[0])) 1 else 0;

    while (i < args.len) {
        const arg = args[i];

        if (matches(arg, &.{"--host"})) {
            config.host = try consume_flag_value(args, &i, "--host");
        } else if (matches(arg, &.{ "--port", "-p" })) {
            const port_str = try consume_flag_value(args, &i, "--port");
            config.port = std.fmt.parseInt(u16, port_str, 10) catch {
                std.debug.print("Error: Invalid port number: {s}\n", .{port_str});
                return error.InvalidArgs;
            };
        } else if (matches(arg, &.{"--data-dir"})) {
            config.data_dir = try consume_flag_value(args, &i, "--data-dir");
        } else if (matches(arg, &.{"--max-connections"})) {
            const conn_str = try consume_flag_value(args, &i, "--max-connections");
            config.max_connections = std.fmt.parseInt(u32, conn_str, 10) catch {
                std.debug.print("Error: Invalid max connections: {s}\n", .{conn_str});
                return error.InvalidArgs;
            };
        } else if (matches(arg, &.{ "--foreground", "--no-daemonize" })) {
            config.daemonize = false;
        } else if (matches(arg, &.{"--log-level"})) {
            const level_str = try consume_flag_value(args, &i, "--log-level");
            config.log_level = std.meta.stringToEnum(std.log.Level, level_str) orelse {
                std.debug.print("Error: Invalid log level: {s}\n", .{level_str});
                return error.InvalidArgs;
            };
        } else if (matches(arg, &.{"--enable-logging"})) {
            config.enable_logging = true;
        } else if (matches(arg, &.{"--enable-hot-path-logging"})) {
            config.enable_hot_path_logging = true;
        } else if (matches(arg, &.{"--structured-logging"})) {
            config.structured_logging = true;
        } else if (matches(arg, &.{"--log-dir"})) {
            config.log_dir = try consume_flag_value(args, &i, "--log-dir");
        } else if (matches(arg, &.{"--pid-dir"})) {
            config.pid_dir = try consume_flag_value(args, &i, "--pid-dir");
        } else {
            std.debug.print("Error: Unknown argument: {s}\n", .{arg});
            return error.InvalidArgs;
        }

        i += 1;
    }

    try config.validate();
    return config;
}

fn is_server_command(arg: []const u8) bool {
    const server_commands = [_][]const u8{
        "start",
        "stop",
        "status",
        "restart",
        "help",
        "version",
    };
    for (server_commands) |cmd| {
        if (std.mem.eql(u8, arg, cmd)) return true;
    }
    return false;
}

fn consume_flag_value(args: []const []const u8, i: *usize, flag_name: []const u8) ![]const u8 {
    i.* += 1;
    if (i.* >= args.len) {
        std.debug.print("Error: {s} requires a value\n", .{flag_name});
        return error.InvalidArgs;
    }
    return args[i.*];
}

// === Tests ===

const testing = std.testing;

test "ServerConfig default values are valid" {
    const config = ServerConfig{};
    try config.validate();

    try testing.expectEqualStrings("127.0.0.1", config.host);
    try testing.expectEqual(@as(u16, 3838), config.port);
    try testing.expectEqual(@as(u32, 100), config.max_connections);
    try testing.expect(config.daemonize);
}

test "ServerConfig validation catches invalid values" {
    var config = ServerConfig{};

    // Invalid port
    config.port = 0;
    try testing.expectError(error.InvalidPort, config.validate());

    // Reset and test max_connections
    config = ServerConfig{};
    config.max_connections = 0;
    try testing.expectError(error.InvalidMaxConnections, config.validate());

    // Reset and test timeout
    config = ServerConfig{};
    config.connection_timeout_sec = 0;
    try testing.expectError(error.InvalidTimeout, config.validate());
}

test "parse_server_args handles basic flags" {
    const args = [_][]const u8{ "--port", "8080", "--host", "0.0.0.0" };
    const config = try parse_server_args(testing.allocator, &args);

    try testing.expectEqual(@as(u16, 8080), config.port);
    try testing.expectEqualStrings("0.0.0.0", config.host);
}

test "parse_server_args skips server commands" {
    const args = [_][]const u8{ "start", "--port", "9000" };
    const config = try parse_server_args(testing.allocator, &args);

    try testing.expectEqual(@as(u16, 9000), config.port);
}

test "parse_server_args handles foreground flag" {
    const args = [_][]const u8{"--foreground"};
    const config = try parse_server_args(testing.allocator, &args);

    try testing.expect(!config.daemonize);
}

test "config conversion functions work correctly" {
    const server_config = ServerConfig{
        .max_request_size = 128 * 1024,
        .max_response_size = 32 * 1024 * 1024,
        .enable_logging = true,
        .max_connections = 50,
        .connection_timeout_sec = 120,
    };

    const conn_config = server_config.to_connection_config();
    try testing.expectEqual(server_config.max_request_size, conn_config.max_request_size);
    try testing.expectEqual(server_config.max_response_size, conn_config.max_response_size);
    try testing.expectEqual(server_config.enable_logging, conn_config.enable_logging);

    const mgr_config = server_config.to_connection_manager_config();
    try testing.expectEqual(server_config.max_connections, mgr_config.max_connections);
    try testing.expectEqual(server_config.connection_timeout_sec, mgr_config.connection_timeout_sec);
}
