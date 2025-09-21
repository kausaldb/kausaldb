//! Wait for server utility for E2E test orchestration.
//!
//! This utility polls a server port until it becomes available or times out.
//! Used in the build system to ensure server is ready before running tests.

const std = @import("std");

const DEFAULT_TIMEOUT_MS = 10000; // 10 seconds
const DEFAULT_POLL_INTERVAL_MS = 200; // 200ms between attempts

const ExitCode = enum(u8) {
    success = 0,
    timeout = 1,
    invalid_args = 2,

    fn exit(self: ExitCode) noreturn {
        std.process.exit(@intFromEnum(self));
    }
};

fn print_help() void {
    const help_text =
        \\wait-for-server - Wait for server to become ready
        \\
        \\USAGE:
        \\    wait-for-server [OPTIONS] <PORT>
        \\
        \\OPTIONS:
        \\    --timeout <MS>      Timeout in milliseconds (default: 10000)
        \\    --interval <MS>     Poll interval in milliseconds (default: 200)
        \\    --host <HOST>       Host to connect to (default: 127.0.0.1)
        \\    --help, -h          Show this help message
        \\
        \\EXAMPLES:
        \\    wait-for-server 3839                    Wait for server on port 3839
        \\    wait-for-server --timeout 5000 3839     Wait up to 5 seconds
        \\    wait-for-server --host localhost 8080   Wait for localhost:8080
        \\
    ;

    std.debug.print("{s}", .{help_text});
}

const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16,
    timeout_ms: u32 = DEFAULT_TIMEOUT_MS,
    poll_interval_ms: u32 = DEFAULT_POLL_INTERVAL_MS,
};

fn parse_args(allocator: std.mem.Allocator) !Config {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Error: Missing port argument\n", .{});
        return error.InvalidArgs;
    }

    var config = Config{ .port = 0 };
    var port_specified = false;

    var i: usize = 1;
    while (i < args.len) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            print_help();
            ExitCode.success.exit();
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --timeout requires a value\n", .{});
                return error.InvalidArgs;
            }
            config.timeout_ms = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("Error: Invalid timeout value: {s}\n", .{args[i]});
                return error.InvalidArgs;
            };
        } else if (std.mem.eql(u8, arg, "--interval")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --interval requires a value\n", .{});
                return error.InvalidArgs;
            }
            config.poll_interval_ms = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("Error: Invalid interval value: {s}\n", .{args[i]});
                return error.InvalidArgs;
            };
        } else if (std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --host requires a value\n", .{});
                return error.InvalidArgs;
            }
            config.host = args[i];
        } else if (!port_specified) {
            // First non-flag argument is the port
            config.port = std.fmt.parseInt(u16, arg, 10) catch {
                std.debug.print("Error: Invalid port number: {s}\n", .{arg});
                return error.InvalidArgs;
            };
            port_specified = true;
        } else {
            std.debug.print("Error: Unknown argument: {s}\n", .{arg});
            return error.InvalidArgs;
        }

        i += 1;
    }

    if (!port_specified) {
        std.debug.print("Error: Port argument is required\n", .{});
        return error.InvalidArgs;
    }

    return config;
}

fn try_connect(host: []const u8, port: u16) bool {
    const address = std.net.Address.parseIp(host, port) catch return false;

    const socket = std.net.tcpConnectToAddress(address) catch return false;
    socket.close();

    return true;
}

fn wait_for_server(config: Config) !ExitCode {
    const start_time = std.time.milliTimestamp();
    const timeout_time = start_time + config.timeout_ms;

    std.debug.print("Waiting for server at {s}:{} (timeout: {}ms, interval: {}ms)\n", .{ config.host, config.port, config.timeout_ms, config.poll_interval_ms });

    var attempts: u32 = 0;
    while (std.time.milliTimestamp() < timeout_time) {
        attempts += 1;

        if (try_connect(config.host, config.port)) {
            const elapsed = std.time.milliTimestamp() - start_time;
            std.debug.print("Server ready at {s}:{} (took {}ms, {} attempts)\n", .{ config.host, config.port, elapsed, attempts });
            return ExitCode.success;
        }

        // Sleep for the specified interval
        std.Thread.sleep(config.poll_interval_ms * std.time.ns_per_ms);
    }

    const elapsed = std.time.milliTimestamp() - start_time;
    std.debug.print("Timeout waiting for server at {s}:{} ({}ms elapsed, {} attempts)\n", .{ config.host, config.port, elapsed, attempts });

    return ExitCode.timeout;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = parse_args(allocator) catch {
        print_help();
        ExitCode.invalid_args.exit();
    };

    const exit_code = wait_for_server(config) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        return ExitCode.invalid_args.exit();
    };

    exit_code.exit();
}
