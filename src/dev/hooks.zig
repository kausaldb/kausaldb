//! Git hooks management for KausalDB development workflow.
//!
//! Provides installation and removal of git hooks directly from Zig code,
//! eliminating external shell script dependencies and ensuring consistent
//! hook behavior across development environments.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

/// Git hooks supported by KausalDB
const Hook = enum {
    pre_commit,
    pre_push,

    fn filename(self: Hook) []const u8 {
        return switch (self) {
            .pre_commit => "pre-commit",
            .pre_push => "pre-push",
        };
    }

    fn script_content(self: Hook) []const u8 {
        return switch (self) {
            .pre_commit =>
            \\#!/bin/bash
            \\set -e
            \\
            \\echo "Running pre-commit checks..."
            \\
            \\# Check code formatting
            \\echo "Checking code formatting..."
            \\./zig/zig build fmt-check
            \\
            \\# Check naming conventions and style rules
            \\echo "Checking style rules..."
            \\./zig/zig build tidy
            \\
            \\# Verify all binaries compile
            \\echo "Verifying binary compilation..."
            \\./zig/zig build
            \\
            \\# Run tests
            \\echo "Running tests..."
            \\./zig/zig build test
            \\
            \\echo "Pre-commit checks passed"
            \\
            ,
            .pre_push =>
            \\#!/bin/bash
            \\set -e
            \\
            \\echo "Running pre-push validation..."
            \\
            \\# Quick bypass for emergency pushes
            \\if [ "${SKIP_PREPUSH:-0}" = "1" ]; then
            \\    echo "Pre-push checks bypassed with SKIP_PREPUSH=1"
            \\    exit 0
            \\fi
            \\
            \\# Run tests before pushing
            \\echo "Running tests..."
            \\./zig/zig build test
            \\
            \\echo "Pre-push validation passed"
            \\
            ,
        };
    }
};

const HookError = error{
    NotGitRepository,
    HookInstallFailed,
    HookRemovalFailed,
    PermissionError,
} || std.fs.File.OpenError || std.fs.File.WriteError || std.fs.Dir.OpenError;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try print_usage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "install")) {
        try install_hooks(allocator);
        std.debug.print("Git hooks installed successfully\n", .{});
    } else if (std.mem.eql(u8, command, "remove")) {
        try remove_hooks(allocator);
        std.debug.print("Git hooks removed successfully\n", .{});
    } else if (std.mem.eql(u8, command, "status")) {
        try show_hook_status(allocator);
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        try print_usage();
        std.process.exit(1);
    }
}

fn print_usage() !void {
    std.debug.print("Usage: hooks <command>\n", .{});
    std.debug.print("Commands:\n", .{});
    std.debug.print("  install - Install all git hooks\n", .{});
    std.debug.print("  remove  - Remove all git hooks\n", .{});
    std.debug.print("  status  - Show current hook status\n", .{});
}

fn install_hooks(allocator: Allocator) !void {
    _ = allocator;
    try ensure_git_repository();

    var hooks_dir = try std.fs.cwd().makeOpenPath(".git/hooks", .{});
    defer hooks_dir.close();

    const hooks = [_]Hook{ .pre_commit, .pre_push };

    for (hooks) |hook| {
        try install_hook(hooks_dir, hook);
        std.debug.print("Installed {s} hook\n", .{hook.filename()});
    }
}

fn remove_hooks(allocator: Allocator) !void {
    _ = allocator;
    try ensure_git_repository();

    var hooks_dir = std.fs.cwd().openDir(".git/hooks", .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("No git hooks directory found\n", .{});
            return;
        },
        else => return err,
    };
    defer hooks_dir.close();

    const hooks = [_]Hook{ .pre_commit, .pre_push };

    for (hooks) |hook| {
        hooks_dir.deleteFile(hook.filename()) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("Hook {s} was not installed\n", .{hook.filename()});
            },
            else => return err,
        };
        std.debug.print("Removed {s} hook\n", .{hook.filename()});
    }
}

fn show_hook_status(allocator: Allocator) !void {
    _ = allocator;
    try ensure_git_repository();

    var hooks_dir = std.fs.cwd().openDir(".git/hooks", .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Git hooks directory not found\n", .{});
            return;
        },
        else => return err,
    };
    defer hooks_dir.close();

    std.debug.print("Git Hook Status:\n", .{});
    const hooks = [_]Hook{ .pre_commit, .pre_push };

    for (hooks) |hook| {
        const status = if (hook_exists(hooks_dir, hook)) "INSTALLED" else "missing";
        std.debug.print("{s:12} - {s}\n", .{ hook.filename(), status });
    }
}

fn install_hook(hooks_dir: std.fs.Dir, hook: Hook) !void {
    const file = try hooks_dir.createFile(hook.filename(), .{ .truncate = true });
    defer file.close();

    try file.writeAll(hook.script_content());

    // Make the hook executable on Unix systems
    if (builtin.os.tag != .windows) {
        try file.chmod(0o755);
    }
}

fn hook_exists(hooks_dir: std.fs.Dir, hook: Hook) bool {
    const file = hooks_dir.openFile(hook.filename(), .{}) catch return false;
    file.close();
    return true;
}

fn ensure_git_repository() !void {
    var git_dir = std.fs.cwd().openDir(".git", .{}) catch |err| switch (err) {
        error.FileNotFound => return HookError.NotGitRepository,
        else => return err,
    };
    git_dir.close();
}

test "hook filename mapping" {
    const testing = std.testing;

    try testing.expectEqualStrings("pre-commit", Hook.pre_commit.filename());
    try testing.expectEqualStrings("pre-push", Hook.pre_push.filename());
}

test "hook script content not empty" {
    const testing = std.testing;

    try testing.expect(Hook.pre_commit.script_content().len > 0);
    try testing.expect(Hook.pre_push.script_content().len > 0);
}
