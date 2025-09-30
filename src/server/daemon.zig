//! Process management for KausalDB server daemon.
//!
//! Handles daemonization, PID file operations, and process lifecycle.
//! Follows Unix daemon conventions with proper signal handling.

const std = @import("std");
const builtin = @import("builtin");
const concurrency = @import("../core/concurrency.zig");
const stdx = @import("../core/stdx.zig");

const log = std.log.scoped(.daemon);

/// Process startup status
pub const StartupStatus = enum {
    can_start, // No PID file exists, ready to start
    already_running, // Process is running, cannot start
    stale_pid_file, // PID file exists but process is dead
};

/// Write process ID to PID file
pub fn write_pid_file(pid_dir: []const u8, process_name: []const u8, port: u16, pid: std.posix.pid_t) !void {
    // Use stack buffers to avoid allocator issues after fork
    var pid_file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const pid_file_path = try std.fmt.bufPrint(&pid_file_path_buf, "{s}/{s}-{}.pid", .{ pid_dir, process_name, port });

    const file = try std.fs.cwd().createFile(pid_file_path, .{});
    defer file.close();

    var pid_str_buf: [32]u8 = undefined;
    const pid_str = try std.fmt.bufPrint(&pid_str_buf, "{}\n", .{pid});

    try file.writeAll(pid_str);
    log.info("Process PID {} written to {s}", .{ pid, pid_file_path });
}

/// Read process ID from PID file
pub fn read_pid_file(allocator: std.mem.Allocator, pid_dir: []const u8, process_name: []const u8, port: u16) !?std.posix.pid_t {
    const pid_file_path = try std.fmt.allocPrint(allocator, "{s}/{s}-{}.pid", .{ pid_dir, process_name, port });
    defer allocator.free(pid_file_path);

    const file = std.fs.cwd().openFile(pid_file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const max_pid_len = 32;
    var buffer: [max_pid_len]u8 = undefined;
    const bytes_read = try file.readAll(&buffer);

    if (bytes_read == 0) return null;

    const pid_str = std.mem.trim(u8, buffer[0..bytes_read], " \n\r\t");
    return std.fmt.parseInt(std.posix.pid_t, pid_str, 10) catch null;
}

/// Remove PID file from filesystem
pub fn remove_pid_file(allocator: std.mem.Allocator, pid_dir: []const u8, process_name: []const u8, port: u16) void {
    const pid_file_path = std.fmt.allocPrint(allocator, "{s}/{s}-{}.pid", .{ pid_dir, process_name, port }) catch return;
    defer allocator.free(pid_file_path);

    std.fs.cwd().deleteFile(pid_file_path) catch |err| {
        log.warn("Failed to remove PID file {s}: {}", .{ pid_file_path, err });
    };
}

/// Check if process with given PID is currently running
pub fn is_process_running(pid: std.posix.pid_t) bool {
    std.posix.kill(pid, 0) catch return false;
    return true;
}

/// Check daemon startup status without side effects
pub fn check_startup_status(allocator: std.mem.Allocator, pid_dir: []const u8, process_name: []const u8, port: u16) !StartupStatus {
    const pid = try read_pid_file(allocator, pid_dir, process_name, port);

    if (pid == null) {
        return StartupStatus.can_start;
    }

    if (is_process_running(pid.?)) {
        return StartupStatus.already_running;
    }

    return StartupStatus.stale_pid_file;
}

/// Stop daemon process with graceful shutdown
pub fn stop_process(allocator: std.mem.Allocator, pid_dir: []const u8, process_name: []const u8, port: u16, timeout_sec: u32) !void {
    const pid = try read_pid_file(allocator, pid_dir, process_name, port);

    if (pid == null) {
        log.info("No PID file found for port {}. Process may not be running.", .{port});
        return;
    }

    const server_pid = pid.?;

    if (!is_process_running(server_pid)) {
        log.info("Process {} not running. Cleaning up stale PID file.", .{server_pid});
        remove_pid_file(allocator, pid_dir, process_name, port);
        return;
    }

    log.info("Stopping {s} process (PID: {}) on port {}...", .{ process_name, server_pid, port });

    // Send SIGTERM for graceful shutdown
    try std.posix.kill(server_pid, std.posix.SIG.TERM);

    // Wait for graceful shutdown
    var attempts: u32 = 0;
    const max_attempts = timeout_sec * 10; // 100ms intervals

    while (attempts < max_attempts) {
        if (!is_process_running(server_pid)) {
            log.info("Process stopped gracefully", .{});
            remove_pid_file(allocator, pid_dir, process_name, port);
            return;
        }

        std.Thread.sleep(100 * std.time.ns_per_ms);
        attempts += 1;
    }

    // Force kill if graceful shutdown failed
    log.warn("Graceful shutdown failed, force killing process {}", .{server_pid});
    std.posix.kill(server_pid, std.posix.SIG.KILL) catch {};
    remove_pid_file(allocator, pid_dir, process_name, port);
}

/// Daemonize current process following Unix daemon conventions
pub fn daemonize(log_file_path: []const u8) !void {
    switch (builtin.os.tag) {
        .windows => {
            log.warn("Daemonization not supported on Windows, running in foreground", .{});
            return;
        },
        else => {},
    }

    // Fork to create background process
    const pid = try std.posix.fork();

    // Parent process exits immediately
    if (pid > 0) std.process.exit(0);

    // Child process continues as daemon
    concurrency.reset_main_thread();

    // Create new session to detach from terminal
    const sid = std.c.setsid();
    if (sid < 0) {
        const errno = std.c._errno().*;
        return std.posix.unexpectedErrno(@enumFromInt(errno));
    }

    // Redirect standard file descriptors to detach from terminal
    std.posix.close(std.posix.STDIN_FILENO);
    std.posix.close(std.posix.STDOUT_FILENO);
    std.posix.close(std.posix.STDERR_FILENO);

    // Redirect stdin to /dev/null
    _ = std.posix.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0) catch {};

    // Redirect stdout and stderr to log file
    const log_fd = std.posix.open(log_file_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644) catch blk: {
        break :blk std.posix.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch return;
    };

    _ = std.posix.dup2(log_fd, std.posix.STDOUT_FILENO) catch {};
    _ = std.posix.dup2(log_fd, std.posix.STDERR_FILENO) catch {};

    if (log_fd > std.posix.STDERR_FILENO) {
        std.posix.close(log_fd);
    }

    log.info("Process successfully daemonized", .{});
}
