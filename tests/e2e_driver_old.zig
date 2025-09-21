//! E2E Test Driver for KausalDB
//!
//! Coordinates server lifecycle for the entire test suite to enable shared
//! server testing without hanging or state contamination issues.

const std = @import("std");

const TEST_PORT = 3838;
const TEST_DATA_DIR = ".test-e2e-data";
const SERVER_STARTUP_TIMEOUT_MS = 10000;
const SERVER_SHUTDOWN_TIMEOUT_MS = 5000;

// Global state for signal handling and cleanup
var global_server_process: ?*ServerProcess = null;
var global_allocator: std.mem.Allocator = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    global_allocator = allocator;

    // Install signal handlers for graceful cleanup on interruption
    install_signal_handlers();

    // Parse command line arguments - expect first arg to be filter if provided
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Extract filter from first argument if provided
    const filter_arg = if (args.len > 1) args[1] else null;

    std.debug.print("Starting E2E test driver...\n", .{});

    cleanup_previous_run();

    var server_process = try start_server_process(allocator);
    global_server_process = &server_process;

    // Ensure cleanup happens even on abnormal exit
    const cleanup_result = cleanup: {
        defer {
            cleanup_server_process(&server_process, allocator);
            global_server_process = null;
        }

        try wait_for_server_ready();
        std.debug.print("Server ready. Running E2E tests...\n\n", .{});

        const test_exit_code = run_test_suite(allocator, filter_arg) catch |err| {
            std.debug.print("Test suite failed with error: {}\n", .{err});
            break :cleanup @as(u8, 1);
        };

        std.debug.print("\nE2E Test Suite Complete\n", .{});
        break :cleanup test_exit_code;
    };

    std.process.exit(cleanup_result);
}

fn install_signal_handlers() void {
    // Install signal handler for SIGINT (Ctrl+C) and SIGTERM
    const handler = struct {
        fn signal_handler(sig: c_int) callconv(.c) void {
            std.debug.print("\n\n=== CAUGHT SIGNAL {} - CLEANING UP ===\n", .{sig});

            if (global_server_process) |server| {
                std.debug.print("Emergency cleanup of server process...\n", .{});
                cleanup_server_process(server, global_allocator);
            }

            // Final cleanup
            std.debug.print("Final emergency cleanup...\n", .{});
            kill_existing_server();
            cleanup_test_data_dir();
            cleanup_temporary_workspaces();

            std.debug.print("=== EMERGENCY CLEANUP COMPLETE - EXITING ===\n", .{});
            std.process.exit(130); // Standard exit code for SIGINT
        }
    }.signal_handler;

    // Install signal handlers (ignore errors if platform doesn't support)
    const SIG = std.posix.SIG;
    const empty_sigset = std.mem.zeroes(std.posix.sigset_t);

    _ = std.posix.sigaction(SIG.INT, &std.posix.Sigaction{
        .handler = .{ .handler = handler },
        .mask = empty_sigset,
        .flags = 0,
    }, null);

    _ = std.posix.sigaction(SIG.TERM, &std.posix.Sigaction{
        .handler = .{ .handler = handler },
        .mask = empty_sigset,
        .flags = 0,
    }, null);
}

fn cleanup_previous_run() void {
    std.debug.print("=== INITIALIZING CLEAN STATE FOR E2E TESTS ===\n", .{});

    // Step 1: Kill any existing servers to ensure clean process state
    kill_existing_server();

    // Step 2: Clean up ALL database output - test data, WAL, SST, logs, etc.
    cleanup_all_database_output();

    // Step 3: Clean up ALL e2e output - temp workspaces, cache, artifacts
    cleanup_all_e2e_output();

    // Step 4: Clean up any build artifacts that might affect tests
    cleanup_test_build_artifacts();

    // Step 5: Wait for file system operations to complete
    std.Thread.sleep(500 * std.time.ns_per_ms);

    std.debug.print("=== CLEAN STATE INITIALIZATION COMPLETE ===\n", .{});
}

fn cleanup_test_data_dir() void {
    std.debug.print("Removing test data directory: {s}\n", .{TEST_DATA_DIR});

    // Try multiple times with increasing force
    var attempts: u8 = 0;
    while (attempts < 3) : (attempts += 1) {
        if (attempts > 0) {
            std.debug.print("Cleanup attempt {} for {s}...\n", .{ attempts + 1, TEST_DATA_DIR });
            std.Thread.sleep(200 * std.time.ns_per_ms);
        }

        // First check if directory exists
        std.fs.cwd().access(TEST_DATA_DIR, .{}) catch {
            std.debug.print("Test data directory {s} does not exist, skipping\n", .{TEST_DATA_DIR});
            return;
        };

        // Try to delete the directory
        std.fs.cwd().deleteTree(TEST_DATA_DIR) catch |err| switch (err) {
            error.AccessDenied => {
                std.debug.print("Warning: Access denied removing {s}, trying to change permissions...\n", .{TEST_DATA_DIR});
                // Try to make everything writable first
                change_dir_permissions(TEST_DATA_DIR) catch {};
                continue;
            },
            else => {
                std.debug.print("Warning: Could not remove test data ({}), attempt {}\n", .{ err, attempts + 1 });
                if (attempts == 2) {
                    std.debug.print("Final cleanup attempt failed, but continuing with tests...\n", .{});
                }
                continue;
            },
        };

        // Success - verify it's actually gone
        std.fs.cwd().access(TEST_DATA_DIR, .{}) catch {
            std.debug.print("Successfully removed test data directory\n", .{});
            return;
        };
    }
}

fn change_dir_permissions(dir_path: []const u8) !void {
    // Try to make directory and contents writable using chmod
    var process = std.process.Child.init(&[_][]const u8{ "chmod", "-R", "755", dir_path }, std.heap.page_allocator);
    process.stdout_behavior = .Ignore;
    process.stderr_behavior = .Ignore;
    _ = process.spawnAndWait() catch {};
}

fn cleanup_temporary_workspaces() void {
    std.debug.print("Cleaning up temporary test workspaces...\n", .{});

    // Clean up /tmp/kausaldb_e2e_* directories that might be left from previous runs
    var tmp_dir = std.fs.openDirAbsolute("/tmp", .{ .iterate = true }) catch {
        std.debug.print("Could not access /tmp directory\n", .{});
        return;
    };
    defer tmp_dir.close();

    var iterator = tmp_dir.iterate();
    var cleaned_count: u32 = 0;

    while (iterator.next()) |entry_opt| {
        const entry = entry_opt orelse break;
        if (entry.kind == .directory and std.mem.startsWith(u8, entry.name, "kausaldb_e2e_")) {
            std.debug.print("Removing old test workspace: /tmp/{s}\n", .{entry.name});

            const full_path = std.fmt.allocPrint(std.heap.page_allocator, "/tmp/{s}", .{entry.name}) catch continue;
            defer std.heap.page_allocator.free(full_path);

            std.fs.deleteTreeAbsolute(full_path) catch |err| {
                std.debug.print("Warning: Could not remove {s}: {}\n", .{ full_path, err });
            };
            cleaned_count += 1;

            // Prevent infinite loop if there are too many directories
            if (cleaned_count > 50) {
                std.debug.print("Cleaned 50+ workspaces, stopping to prevent infinite loop\n", .{});
                break;
            }
        }
    } else |err| {
        std.debug.print("Note: Error iterating /tmp directory: {}\n", .{err});
    }

    if (cleaned_count > 0) {
        std.debug.print("Cleaned up {} temporary workspaces\n", .{cleaned_count});
    }
}

fn cleanup_all_database_output() void {
    std.debug.print("Cleaning ALL database output for deterministic state...\n", .{});

    // Primary test data directory
    cleanup_single_path(TEST_DATA_DIR);

    // Other possible database output locations
    const db_paths = [_][]const u8{
        ".kausaldb-data", // Default data directory
        "data", // Alternative data directory
        "wal", // WAL directory
        "sst", // SST directory
        "kausal.db", // Database files
        "kausal.log", // Log files
    };

    for (db_paths) |path| {
        cleanup_single_path(path);
    }
}

fn cleanup_all_e2e_output() void {
    std.debug.print("Cleaning ALL e2e test output...\n", .{});

    // Clean up temporary workspaces (existing function)
    cleanup_temporary_workspaces();

    // Clean up other e2e artifacts
    const e2e_paths = [_][]const u8{
        "test-output",
        "e2e-output",
        ".tmp",
        "tmp",
        ".test-cache",
    };

    for (e2e_paths) |path| {
        cleanup_single_path(path);
    }
}

fn cleanup_test_build_artifacts() void {
    std.debug.print("Cleaning test build artifacts...\n", .{});

    // Clean up any test-specific build artifacts that might affect state
    const build_paths = [_][]const u8{
        "test-artifacts",
        ".e2e-cache",
        ".test-tmp",
    };

    for (build_paths) |path| {
        cleanup_single_path(path);
    }
}

fn cleanup_single_path(path: []const u8) void {
    // Try multiple times with increasing force
    var attempts: u8 = 0;
    while (attempts < 3) : (attempts += 1) {
        if (attempts > 0) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }

        // Check if path exists
        std.fs.cwd().access(path, .{}) catch {
            // Path doesn't exist, that's fine
            return;
        };

        // Try to delete it (could be file or directory)
        std.fs.cwd().deleteFile(path) catch |file_err| {
            std.fs.cwd().deleteTree(path) catch |dir_err| switch (dir_err) {
                error.AccessDenied => {
                    if (attempts == 0) {
                        std.debug.print("Fixing permissions for {s}...\n", .{path});
                        change_dir_permissions(path) catch {};
                        continue;
                    }
                },
                else => {
                    if (attempts == 2) {
                        std.debug.print("Note: Could not remove {s} (file: {}, dir: {})\n", .{ path, file_err, dir_err });
                    }
                    continue;
                },
            };
        };

        // Success - verify it's gone
        std.fs.cwd().access(path, .{}) catch {
            std.debug.print("Removed: {s}\n", .{path});
            return;
        };
    }
}

fn kill_existing_server() void {
    std.debug.print("Killing any existing kausal processes...\n", .{});

    // Multiple approaches to ensure all kausal processes are terminated
    const kill_commands = [_][]const []const u8{
        &[_][]const u8{ "pkill", "-f", "kausal" },
        &[_][]const u8{ "pkill", "-f", "kausal-server" },
        &[_][]const u8{ "pkill", "-9", "-f", "kausal" }, // Force kill as backup
        &[_][]const u8{ "killall", "kausal" },
        &[_][]const u8{ "killall", "kausal-server" },
    };

    for (kill_commands) |cmd| {
        var process = std.process.Child.init(cmd, std.heap.page_allocator);
        process.stdout_behavior = .Ignore;
        process.stderr_behavior = .Ignore;
        _ = process.spawnAndWait() catch {};
    }

    // Check for processes using our test port and kill them
    kill_processes_on_port(TEST_PORT);

    // Give processes time to die
    std.Thread.sleep(1500 * std.time.ns_per_ms);

    std.debug.print("Process cleanup completed\n", .{});
}

fn kill_processes_on_port(port: u16) void {
    std.debug.print("Killing processes using port {}...\n", .{port});

    const port_str = std.fmt.allocPrint(std.heap.page_allocator, "{}", .{port}) catch return;
    defer std.heap.page_allocator.free(port_str);

    // Use lsof to find processes using the port, then kill them
    const lsof_cmd = [_][]const u8{ "lsof", "-t", "-i", port_str };
    var lsof_process = std.process.Child.init(&lsof_cmd, std.heap.page_allocator);
    lsof_process.stdout_behavior = .Pipe;
    lsof_process.stderr_behavior = .Ignore;

    if (lsof_process.spawn()) |_| {
        defer _ = lsof_process.wait() catch {};

        if (lsof_process.stdout) |stdout| {
            const output = stdout.readToEndAlloc(std.heap.page_allocator, 4096) catch return;
            defer std.heap.page_allocator.free(output);

            // Parse PIDs and kill each one
            var lines = std.mem.splitSequence(u8, output, "\n");
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r\n");
                if (trimmed.len == 0) continue;

                const pid = std.fmt.parseInt(i32, trimmed, 10) catch continue;
                std.debug.print("Killing process {} using port {}\n", .{ pid, port });

                // Send SIGTERM first, then SIGKILL if needed
                std.posix.kill(pid, std.posix.SIG.TERM) catch {};
                std.Thread.sleep(100 * std.time.ns_per_ms);
                std.posix.kill(pid, std.posix.SIG.KILL) catch {};
            }
        }
    } else |_| {
        // lsof might not be available, fallback to netstat approach
        const netstat_cmd = [_][]const u8{ "netstat", "-tlnp" };
        var netstat_process = std.process.Child.init(&netstat_cmd, std.heap.page_allocator);
        netstat_process.stdout_behavior = .Ignore; // Too complex to parse, just continue
        netstat_process.stderr_behavior = .Ignore;
        _ = netstat_process.spawnAndWait() catch {};
    }
}

fn start_server_process(allocator: std.mem.Allocator) !ServerProcess {
    std.debug.print("Starting KausalDB server on port {}...\n", .{TEST_PORT});

    try std.fs.cwd().makeDir(TEST_DATA_DIR);

    const port_str = try std.fmt.allocPrint(allocator, "{}", .{TEST_PORT});
    defer allocator.free(port_str);

    const server_args = [_][]const u8{
        "zig-out/bin/kausal-server",
        "start",
        "--foreground",
        "--port",
        port_str,
        "--data-dir",
        TEST_DATA_DIR,
    };

    var process = std.process.Child.init(&server_args, allocator);
    process.stdout_behavior = .Pipe;
    process.stderr_behavior = .Pipe;

    try process.spawn();
    std.debug.print("Server process started (PID: {})\n", .{process.id});

    // Create log file paths
    const stdout_log_path = try std.fmt.allocPrint(allocator, "{s}/server_stdout.log", .{TEST_DATA_DIR});
    const stderr_log_path = try std.fmt.allocPrint(allocator, "{s}/server_stderr.log", .{TEST_DATA_DIR});

    var server_process = ServerProcess{
        .process = process,
        .allocator = allocator,
        .output_thread = undefined,
        .stdout_log_path = stdout_log_path,
        .stderr_log_path = stderr_log_path,
    };

    server_process.output_thread = try std.Thread.spawn(.{}, consume_server_output, .{&server_process});
    return server_process;
}

const ServerProcess = struct {
    process: std.process.Child,
    allocator: std.mem.Allocator,
    output_thread: std.Thread,
    stdout_log_path: []const u8,
    stderr_log_path: []const u8,

    fn shutdown_gracefully(self: *ServerProcess) bool {
        // Send SIGTERM for graceful shutdown
        std.posix.kill(self.process.id, std.posix.SIG.TERM) catch |err| {
            std.debug.print("Could not send SIGTERM to process {}: {}\n", .{ self.process.id, err });
            return false;
        };

        std.debug.print("Sent SIGTERM to server process {}\n", .{self.process.id});

        // Give it a moment to shutdown gracefully
        std.Thread.sleep(2000 * std.time.ns_per_ms);

        // Check if it's dead
        if (std.posix.kill(self.process.id, 0)) |_| {
            // Process still alive
            return false;
        } else |_| {
            // Process is dead
            return true;
        }
    }

    fn force_kill(self: *ServerProcess) void {
        std.debug.print("Force killing server process {}...\n", .{self.process.id});

        // Send SIGKILL
        std.posix.kill(self.process.id, std.posix.SIG.KILL) catch |err| {
            std.debug.print("Could not kill process {}: {}\n", .{ self.process.id, err });
            return;
        };

        std.debug.print("Sent SIGKILL to server process {}\n", .{self.process.id});

        // Wait for kill to take effect
        std.Thread.sleep(1000 * std.time.ns_per_ms);
    }

    fn wait_for_exit(self: *ServerProcess) void {
        std.debug.print("Waiting for server process {} to exit...\n", .{self.process.id});

        _ = self.process.wait() catch |err| {
            std.debug.print("Warning: Error waiting for server exit: {}\n", .{err});
        };

        std.debug.print("Waiting for output thread to finish...\n", .{});
        self.output_thread.join();
        std.debug.print("Server process cleanup complete\n", .{});
    }
};

// Server output consumption prevents pipe buffer deadlock by reading
// stdout/stderr continuously in background thread
fn consume_server_output(server_process: *ServerProcess) void {
    var stdout_thread: ?std.Thread = null;
    var stderr_thread: ?std.Thread = null;

    if (server_process.process.stdout) |stdout| {
        stdout_thread = std.Thread.spawn(.{}, drain_pipe_to_file, .{ stdout, server_process.stdout_log_path }) catch null;
    }

    if (server_process.process.stderr) |stderr| {
        stderr_thread = std.Thread.spawn(.{}, drain_pipe_to_file, .{ stderr, server_process.stderr_log_path }) catch null;
    }

    if (stdout_thread) |thread| thread.join();
    if (stderr_thread) |thread| thread.join();
}

fn drain_pipe_to_file(pipe: std.fs.File, log_path: []const u8) void {
    var buffer: [4096]u8 = undefined;
    const start_time = std.time.milliTimestamp();
    const timeout_ms = 15000; // 15 second timeout to prevent hanging

    // Open log file for writing
    const log_file = std.fs.cwd().createFile(log_path, .{}) catch return;
    defer log_file.close();

    while (std.time.milliTimestamp() - start_time < timeout_ms) {
        const bytes_read = pipe.read(&buffer) catch break;
        if (bytes_read == 0) break;

        // Write to log file
        log_file.writeAll(buffer[0..bytes_read]) catch break;
    }
}

fn wait_for_server_ready() !void {
    std.debug.print("Waiting for server to accept connections...\n", .{});

    const start_time = std.time.milliTimestamp();

    while (std.time.milliTimestamp() - start_time < SERVER_STARTUP_TIMEOUT_MS) {
        const address = std.net.Address.parseIp("127.0.0.1", TEST_PORT) catch {
            return error.InvalidAddress;
        };

        if (std.net.tcpConnectToAddress(address)) |stream| {
            defer stream.close();
            std.debug.print("Server accepting connections on port {}\n", .{TEST_PORT});
            return;
        } else |_| {
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }

    return error.ServerStartupTimeout;
}

fn run_test_suite(allocator: std.mem.Allocator, filter_arg: ?[]const u8) !u8 {
    const port_env = try std.fmt.allocPrint(allocator, "{}", .{TEST_PORT});
    defer allocator.free(port_env);

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    try env_map.put("KAUSAL_E2E_TEST_PORT", port_env);

    // Build argument list with optional filter
    var filter_flag: ?[]const u8 = null;
    var test_args: []const []const u8 = undefined;

    if (filter_arg) |filter| {
        filter_flag = try std.fmt.allocPrint(allocator, "-Dfilter={s}", .{filter});
        test_args = &[_][]const u8{
            "./zig/zig",
            "build",
            "test-e2e-internal",
            filter_flag.?,
        };
    } else {
        test_args = &[_][]const u8{
            "./zig/zig",
            "build",
            "test-e2e-internal",
        };
    }

    var process = std.process.Child.init(test_args, allocator);
    process.stdout_behavior = .Inherit;
    process.stderr_behavior = .Inherit;
    process.env_map = &env_map;
    process.cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch ".";
    defer if (!std.mem.eql(u8, process.cwd.?, ".")) allocator.free(process.cwd.?);

    const result = try process.spawnAndWait();

    // Clean up filter flag allocation if it was created
    if (filter_flag) |flag| {
        allocator.free(flag);
    }

    return switch (result) {
        .Exited => |code| @intCast(code),
        else => 1,
    };
}

fn cleanup_server_process(server: *ServerProcess, allocator: std.mem.Allocator) void {
    std.debug.print("\n=== SHUTTING DOWN SERVER (PID: {}) ===\n", .{server.process.id});

    // Attempt graceful shutdown first
    if (!server.shutdown_gracefully()) {
        // Graceful shutdown failed or not implemented, force kill
        server.force_kill();
    }

    // Wait for process to exit and output threads to finish
    server.wait_for_exit();

    // Print server logs for debugging (truncated to avoid overwhelming output)
    print_server_logs(allocator, server);

    // Clean up log file paths
    allocator.free(server.stdout_log_path);
    allocator.free(server.stderr_log_path);

    // Final cleanup: ensure no stray processes
    std.debug.print("Final cleanup: killing any remaining kausal processes\n", .{});
    kill_existing_server();

    // Clean up ALL database and e2e output to ensure next run has clean state
    std.debug.print("Ensuring clean state after server shutdown...\n", .{});
    cleanup_all_database_output();
    cleanup_all_e2e_output();

    std.debug.print("=== SERVER CLEANUP COMPLETE ===\n", .{});
}

fn print_server_logs(allocator: std.mem.Allocator, server: *ServerProcess) void {
    const max_log_size = 64 * 1024; // 64KB max log output to avoid overwhelming the console

    std.debug.print("\n=== SERVER STDOUT LOG (last {}KB) ===\n", .{max_log_size / 1024});
    if (std.fs.cwd().readFileAlloc(allocator, server.stdout_log_path, max_log_size)) |stdout_content| {
        defer allocator.free(stdout_content);
        // Show only the last part if it's too long
        const content = if (stdout_content.len > max_log_size / 2)
            stdout_content[stdout_content.len - max_log_size / 2 ..]
        else
            stdout_content;

        if (content.len > 0) {
            std.debug.print("{s}\n", .{content});
        } else {
            std.debug.print("(empty)\n", .{});
        }
    } else |err| {
        std.debug.print("Could not read stdout log: {}\n", .{err});
    }

    std.debug.print("\n=== SERVER STDERR LOG (last {}KB) ===\n", .{max_log_size / 1024});
    if (std.fs.cwd().readFileAlloc(allocator, server.stderr_log_path, max_log_size)) |stderr_content| {
        defer allocator.free(stderr_content);
        // Show only the last part if it's too long
        const content = if (stderr_content.len > max_log_size / 2)
            stderr_content[stderr_content.len - max_log_size / 2 ..]
        else
            stderr_content;

        if (content.len > 0) {
            std.debug.print("{s}\n", .{content});
        } else {
            std.debug.print("(empty)\n", .{});
        }
    } else |err| {
        std.debug.print("Could not read stderr log: {}\n", .{err});
    }
}
