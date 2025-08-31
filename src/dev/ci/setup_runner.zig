//! Cross-platform development environment setup
//!
//! Replaces shell-based setup scripts with pure Zig implementation
//! for Windows, macOS, and Linux compatibility.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const print = std.debug.print;

const SetupConfig = struct {
    install_zig: bool = true,
    setup_hooks: bool = true,
    verify_install: bool = true,
    force_reinstall: bool = false,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    print("╔══════════════════════════════════════════════════════════════════╗\n", .{});
    print("║                 KausalDB Development Setup                      ║\n", .{});
    print("║              Cross-Platform Environment Setup                   ║\n", .{});
    print("╚══════════════════════════════════════════════════════════════════╝\n\n", .{});

    var config = SetupConfig{};

    // Parse command line arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--no-zig")) {
            config.install_zig = false;
        } else if (std.mem.eql(u8, args[i], "--no-hooks")) {
            config.setup_hooks = false;
        } else if (std.mem.eql(u8, args[i], "--no-verify")) {
            config.verify_install = false;
        } else if (std.mem.eql(u8, args[i], "--force")) {
            config.force_reinstall = true;
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            print_usage();
            return;
        }
    }

    print("Platform: {s} {s}\n", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });
    print("Setup configuration:\n", .{});
    print("  Install Zig: {}\n", .{config.install_zig});
    print("  Setup Git hooks: {}\n", .{config.setup_hooks});
    print("  Verify installation: {}\n", .{config.verify_install});
    print("  Force reinstall: {}\n\n", .{config.force_reinstall});

    var setup_success = true;

    // Step 1: Install or verify Zig toolchain
    if (config.install_zig) {
        print("STEP 1: Zig Toolchain Setup\n", .{});
        print("────────────────────────────\n", .{});

        if (try setup_zig_toolchain(allocator, config.force_reinstall)) {
            print("[+] Zig toolchain setup completed\n\n", .{});
        } else {
            print("[-] Zig toolchain setup failed\n\n", .{});
            setup_success = false;
        }
    }

    if (config.setup_hooks and setup_success) {
        print("STEP 2: Git Hooks Setup\n", .{});
        print("────────────────────────\n", .{});

        if (try setup_git_hooks(allocator)) {
            print("[+] Git hooks setup completed\n\n", .{});
        } else {
            print("[-] Git hooks setup failed\n\n", .{});
            setup_success = false;
        }
    }

    // Step 3: Verify installation
    if (config.verify_install and setup_success) {
        print("STEP 3: Installation Verification\n", .{});
        print("──────────────────────────────────\n", .{});

        if (try verify_installation(allocator)) {
            print("[+] Installation verification passed\n\n", .{});
        } else {
            print("[-] Installation verification failed\n\n", .{});
            setup_success = false;
        }
    }

    // Final result
    if (setup_success) {
        print("[+] KausalDB development environment setup complete!\n", .{});
        print("You can now run: ./zig/zig build ci-smoke\n", .{});
    } else {
        print("[-] Setup failed - please check the errors above\n", .{});
        std.process.exit(1);
    }
}

fn setup_zig_toolchain(allocator: std.mem.Allocator, force_reinstall: bool) !bool {
    // Check if Zig is already installed
    if (!force_reinstall) {
        print("  Checking existing Zig installation...\n", .{});
        if (try check_zig_installation()) {
            print("  Zig already installed and working\n", .{});
            return true;
        }
    }

    print("  Installing Zig toolchain...\n", .{});

    // Create zig directory if it doesn't exist
    std.fs.cwd().makeDir("zig") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return false,
    };

    // Platform-specific installation
    switch (builtin.os.tag) {
        .linux => return try install_zig_linux(allocator),
        .macos => return try install_zig_macos(allocator),
        .windows => return try install_zig_windows(allocator),
        else => {
            print("  Platform {} not supported for automatic Zig installation\n", .{builtin.os.tag});
            return false;
        },
    }
}

fn install_zig_linux(allocator: std.mem.Allocator) !bool {
    _ = allocator;
    print("  Installing Zig for Linux...\n", .{});

    // For now, provide instructions rather than downloading
    print("  Please run: curl -Lo zig.tar.xz https://ziglang.org/builds/zig-linux-x86_64-0.13.0.tar.xz\n", .{});
    print("  Then: tar -xf zig.tar.xz && mv zig-linux-x86_64-0.13.0 zig\n", .{});
    print("  [Automatic download not yet implemented]\n", .{});

    return false; // Not implemented yet
}

fn install_zig_macos(allocator: std.mem.Allocator) !bool {
    print("  Installing Zig for macOS...\n", .{});

    // Check if Homebrew is available
    var child = std.process.Child.init(&.{ "which", "brew" }, allocator);
    if (child.spawnAndWait()) |term| {
        if (term == .Exited and term.Exited == 0) {
            print("  Using Homebrew to install Zig...\n", .{});
            var brew_child = std.process.Child.init(&.{ "brew", "install", "zig" }, allocator);
            if (brew_child.spawnAndWait()) |brew_term| {
                if (brew_term == .Exited and brew_term.Exited == 0) {
                    print("  Zig installed via Homebrew\n", .{});
                    return true;
                }
            } else |_| {}
        }
    } else |_| {}

    print("  Please install Zig manually from https://ziglang.org/download/\n", .{});
    return false;
}

fn install_zig_windows(allocator: std.mem.Allocator) !bool {
    _ = allocator;
    print("  Installing Zig for Windows...\n", .{});
    print("  Please download Zig from https://ziglang.org/download/\n", .{});
    print("  [Automatic download not yet implemented]\n", .{});

    return false; // Not implemented yet
}

fn check_zig_installation() !bool {
    var child = std.process.Child.init(&.{ "./zig/zig", "version" }, std.heap.page_allocator);
    const term = child.spawnAndWait() catch return false;

    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn setup_git_hooks(allocator: std.mem.Allocator) !bool {
    print("  Setting up Git hooks...\n", .{});

    // Check if we're in a Git repository
    var git_dir = std.fs.cwd().openDir(".git", .{}) catch |err| {
        if (err == error.FileNotFound) {
            print("  Not a Git repository - skipping Git hooks setup\n", .{});
            return true;
        }
        return false;
    };
    git_dir.close();

    // Create .githooks directory if it doesn't exist
    std.fs.cwd().makeDir(".githooks") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return false,
    };

    // Setup pre-commit hook
    if (try create_pre_commit_hook(allocator)) {
        print("  Pre-commit hook created\n", .{});
    } else {
        print("  Failed to create pre-commit hook\n", .{});
        return false;
    }

    // Setup commit-msg hook
    if (try create_commit_msg_hook(allocator)) {
        print("  Commit-msg hook created\n", .{});
    } else {
        print("  Failed to create commit-msg hook\n", .{});
        return false;
    }

    // Configure Git to use .githooks directory
    var git_config = std.process.Child.init(&.{ "git", "config", "core.hooksPath", ".githooks" }, allocator);
    const config_term = git_config.spawnAndWait() catch return false;

    return switch (config_term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn create_pre_commit_hook(allocator: std.mem.Allocator) !bool {
    _ = allocator;

    const hook_content = switch (builtin.os.tag) {
        .windows =>
        \\@echo off
        \\echo Running pre-commit checks...
        \\.\zig\zig.exe build ci-smoke
        \\if %ERRORLEVEL% neq 0 exit /b 1
        \\echo Pre-commit checks passed
        ,
        else =>
        \\#!/bin/bash
        \\set -e
        \\echo "Running pre-commit checks..."
        \\./zig/zig build ci-smoke
        \\echo "Pre-commit checks passed"
        ,
    };

    const filename = if (builtin.os.tag == .windows) "pre-commit.bat" else "pre-commit";

    var file = std.fs.cwd().createFile(".githooks/" ++ filename, .{}) catch return false;
    defer file.close();

    file.writeAll(hook_content) catch return false;

    // Make executable on Unix systems
    if (builtin.os.tag != .windows) {
        var chmod = std.process.Child.init(&.{ "chmod", "+x", ".githooks/pre-commit" }, std.heap.page_allocator);
        _ = chmod.spawnAndWait() catch {};
    }

    return true;
}

fn create_commit_msg_hook(allocator: std.mem.Allocator) !bool {
    _ = allocator;

    const hook_content = switch (builtin.os.tag) {
        .windows =>
        \\@echo off
        \\.\zig\zig.exe build commit-msg-validator -- %1
        ,
        else =>
        \\#!/bin/bash
        \\./zig/zig build commit-msg-validator -- "$1"
        ,
    };

    const filename = if (builtin.os.tag == .windows) "commit-msg.bat" else "commit-msg";

    var file = std.fs.cwd().createFile(".githooks/" ++ filename, .{}) catch return false;
    defer file.close();

    file.writeAll(hook_content) catch return false;

    // Make executable on Unix systems
    if (builtin.os.tag != .windows) {
        var chmod = std.process.Child.init(&.{ "chmod", "+x", ".githooks/commit-msg" }, std.heap.page_allocator);
        _ = chmod.spawnAndWait() catch {};
    }

    return true;
}

fn verify_installation(allocator: std.mem.Allocator) !bool {
    print("  Verifying Zig installation...\n", .{});

    // Test Zig compilation
    var zig_test = std.process.Child.init(&.{ "./zig/zig", "build", "--help" }, allocator);
    const zig_term = zig_test.spawnAndWait() catch {
        print("  [-] Zig build system not working\n", .{});
        return false;
    };

    if (zig_term != .Exited or zig_term.Exited != 0) {
        print("  [-] Zig build system not working\n", .{});
        return false;
    }
    print("  [+] Zig build system working\n", .{});

    print("  Testing basic project build...\n", .{});
    var build_test = std.process.Child.init(&.{ "./zig/zig", "build", "fmt" }, allocator);
    const build_term = build_test.spawnAndWait() catch {
        print("  [-] Basic build test failed\n", .{});
        return false;
    };

    if (build_term != .Exited or build_term.Exited != 0) {
        print("  [-] Basic build test failed\n", .{});
        return false;
    }
    print("  [+] Basic build test passed\n", .{});

    return true;
}

fn print_usage() void {
    print("Usage: ci-setup [OPTIONS]\n\n", .{});
    print("Cross-platform development environment setup for KausalDB\n\n", .{});
    print("OPTIONS:\n", .{});
    print("  --no-zig         Skip Zig toolchain installation\n", .{});
    print("  --no-hooks       Skip Git hooks setup\n", .{});
    print("  --no-verify      Skip installation verification\n", .{});
    print("  --force          Force reinstallation of components\n", .{});
    print("  --help, -h       Show this help message\n", .{});
}
