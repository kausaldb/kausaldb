//! CLI parser fuzzing for input validation bugs.
//!
//! Tests CLI command parser robustness against malformed input, long strings,
//! unicode characters, and edge cases.

const std = @import("std");

const internal = @import("internal");
const main = @import("main.zig");

const parser = internal.cli_parser;
const parse_command = parser.parse_command;
const ParseError = parser.ParseError;

const log = std.log.scoped(.cli_parser_fuzz);

pub fn run_fuzzing(fuzzer: *main.Fuzzer) !void {
    std.debug.print("Fuzzing CLI parser...\n", .{});

    // Use arena for the entire fuzzing run to eliminate leaks
    var arena = std.heap.ArenaAllocator.init(fuzzer.allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    for (0..fuzzer.config.iterations) |i| {
        const input = try arena_alloc.alloc(u8, fuzzer.prng.random().intRangeAtMost(usize, 1, 4096));
        fuzzer.prng.random().bytes(input);

        // Select fuzzing strategy based on iteration
        const strategy = i % 8;
        switch (strategy) {
            0 => fuzz_malformed_arguments(arena_alloc, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            1 => fuzz_long_arguments(arena_alloc, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            2 => fuzz_unicode_input(arena_alloc, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            3 => fuzz_control_characters(arena_alloc, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            4 => fuzz_empty_and_null_args(arena_alloc, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            5 => fuzz_extremely_long_commands(arena_alloc, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            6 => fuzz_mixed_valid_invalid(arena_alloc, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            7 => fuzz_boundary_conditions(arena_alloc, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            else => {},
        }

        // Reset arena after each iteration to prevent memory accumulation
        _ = arena.reset(.retain_capacity);

        fuzzer.record_iteration();

        if (i % 1000 == 0 and i > 0) {
            std.debug.print("CLI parser fuzz: {} iterations\n", .{i});
        }
    }
}

fn fuzz_malformed_arguments(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 2) return;

    // Generate random argument count and malformed arguments
    const arg_count = (input[0] % 10) + 1; // 1-10 arguments
    const args = try allocator.alloc([]const u8, arg_count);

    for (args, 0..) |*arg, i| {
        const start_idx = (i * input.len / args.len);
        const end_idx = @min(((i + 1) * input.len / args.len), input.len);

        if (start_idx >= end_idx) {
            arg.* = try allocator.dupe(u8, "");
        } else {
            const slice = input[start_idx..end_idx];
            arg.* = try allocator.dupe(u8, slice);
        }
    }

    // This should never crash, only return errors
    _ = parse_command(args) catch return;
}

fn fuzz_long_arguments(allocator: std.mem.Allocator, input: []const u8) !void {
    // Create arguments with excessive length
    const base_args = [_][]const u8{ "kausal", "find", "function" };
    var args = try allocator.alloc([]const u8, base_args.len + 1);

    // Copy base args
    for (base_args, 0..) |base_arg, i| {
        args[i] = try allocator.dupe(u8, base_arg);
    }

    // Create an extremely long argument
    var long_arg = std.array_list.Managed(u8).init(allocator);
    defer long_arg.deinit();

    const repeat_count = @min(input.len * 1000, 100000); // Cap at 100KB
    for (0..repeat_count) |i| {
        try long_arg.append(input[i % input.len]);
    }

    args[base_args.len] = try allocator.dupe(u8, long_arg.items);

    _ = parse_command(args) catch return;
}

fn fuzz_unicode_input(allocator: std.mem.Allocator, input: []const u8) !void {
    // Mix valid commands with unicode characters
    const unicode_chars = "🦀🔥💻🚀αβγδε测试中文العربية";

    var args = try allocator.alloc([]const u8, 4);

    args[0] = try allocator.dupe(u8, "kausal");
    args[1] = try allocator.dupe(u8, "find");

    // Mix input with unicode
    var mixed = std.array_list.Managed(u8).init(allocator);
    defer mixed.deinit();

    for (input, 0..) |byte, i| {
        try mixed.append(byte);
        if (i % 5 == 0 and unicode_chars.len > 0) {
            const unicode_idx = byte % unicode_chars.len;
            try mixed.append(unicode_chars[unicode_idx]);
        }
    }

    args[2] = try allocator.dupe(u8, mixed.items);
    args[3] = try allocator.dupe(u8, unicode_chars);

    _ = parse_command(args) catch return;
}

fn fuzz_control_characters(allocator: std.mem.Allocator, input: []const u8) !void {
    var args = try allocator.alloc([]const u8, 3);

    args[0] = try allocator.dupe(u8, "kausal");
    args[1] = try allocator.dupe(u8, "status");

    // Create argument with control characters
    var controlled = std.array_list.Managed(u8).init(allocator);
    defer controlled.deinit();

    for (input) |byte| {
        // Mix input with various control characters
        try controlled.append(byte);
        if (byte % 10 == 0) {
            try controlled.append(0x00); // NULL
        } else if (byte % 7 == 0) {
            try controlled.append(0x1B); // ESC
        } else if (byte % 5 == 0) {
            try controlled.append(0x07); // BEL
        }
    }

    args[2] = try allocator.dupe(u8, controlled.items);

    _ = parse_command(args) catch return;
}

fn fuzz_empty_and_null_args(allocator: std.mem.Allocator, input: []const u8) !void {
    _ = input;
    _ = allocator;

    // Test various empty/null argument patterns
    const test_cases = [_][]const []const u8{
        &[_][]const u8{}, // No arguments at all
        &[_][]const u8{""}, // Single empty argument
        &[_][]const u8{ "kausal", "" }, // Empty command
        &[_][]const u8{ "", "find", "function" }, // Empty program name
        &[_][]const u8{ "kausal", "find", "", "test" }, // Empty middle argument
        &[_][]const u8{ "kausal", "find", "function", "" }, // Empty final argument
    };

    for (test_cases) |args| {
        _ = parse_command(args) catch continue;
    }
}

fn fuzz_extremely_long_commands(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len == 0) return;

    // Create massively long command with many arguments
    const max_args = @min(input.len, 100); // Cap at 100 args to prevent OOM
    const args = try allocator.alloc([]const u8, max_args);

    for (args, 0..) |*arg, i| {
        // Create progressively longer arguments
        const arg_len = @min((i + 1) * input.len / max_args, 10000);
        const long_arg = try allocator.alloc(u8, arg_len);

        for (long_arg, 0..) |*char, j| {
            char.* = input[j % input.len];
        }

        arg.* = try allocator.dupe(u8, long_arg);
    }

    _ = parse_command(args) catch return;
}

fn fuzz_mixed_valid_invalid(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 4) return;

    // Mix valid command structures with invalid arguments
    const valid_commands = [_][]const u8{ "link", "find", "show", "trace", "status", "sync" };
    const valid_entities = [_][]const u8{ "function", "struct", "file", "module" };

    var args = try allocator.alloc([]const u8, 6);

    args[0] = try allocator.dupe(u8, "kausal");

    // Pick a valid command
    const cmd_idx = input[0] % valid_commands.len;
    args[1] = try allocator.dupe(u8, valid_commands[cmd_idx]);

    // Mix valid entity with garbage
    const entity_idx = input[1] % valid_entities.len;
    args[2] = try allocator.dupe(u8, valid_entities[entity_idx]);

    // Add progressively more garbage
    for (args[3..], 0..) |*arg, i| {
        const start = 2 + i;
        const end = @min(start + (input.len / 4), input.len);
        if (start >= input.len) {
            arg.* = try allocator.dupe(u8, "");
        } else {
            arg.* = try allocator.dupe(u8, input[start..end]);
        }
    }

    _ = parse_command(args) catch return;
}

fn fuzz_boundary_conditions(allocator: std.mem.Allocator, input: []const u8) !void {
    // Test boundary conditions that might cause issues
    const boundary_tests = [_][]const []const u8{
        // Single character arguments
        &[_][]const u8{ "k", "f", "t", "x" },
        // Maximum reasonable argument count
        &[_][]const u8{ "kausal", "find", "function", "test", "in", "workspace", "with", "extra", "args", "here" },
        // Mixed empty and single chars
        &[_][]const u8{ "kausal", "", "f", "", "x" },
    };

    for (boundary_tests) |args| {
        _ = parse_command(args) catch continue;
    }

    // Test with input-derived boundary cases
    if (input.len > 0) {
        const single_char_args = try allocator.alloc([]const u8, @min(input.len, 20));

        for (single_char_args, 0..) |*arg, i| {
            const char_slice = input[i .. i + 1];
            arg.* = try allocator.dupe(u8, char_slice);
        }

        _ = parse_command(single_char_args) catch return;
    }
}
