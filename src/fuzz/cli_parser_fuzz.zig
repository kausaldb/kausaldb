//! CLI parser fuzzing - systematic input validation testing
//!
//! Tests CLI command parser robustness against malformed input, long strings,
//! unicode characters, and edge cases. Ensures parser fails gracefully with
//! proper error returns rather than crashes.

const std = @import("std");
const main = @import("main.zig");
const internal = @import("internal");

const NaturalCommandError = internal.NaturalCommandError;
const parse_natural_command = internal.parse_natural_command;

const log = std.log.scoped(.cli_parser_fuzz);

pub fn run_fuzzing(fuzzer: *main.Fuzzer) !void {
    std.debug.print("Fuzzing CLI parser...\n", .{});

    for (0..fuzzer.config.iterations) |i| {
        const input = try fuzzer.generate_input();
        defer fuzzer.allocator.free(input);

        // Select fuzzing strategy based on iteration
        const strategy = i % 8;
        switch (strategy) {
            0 => fuzz_malformed_arguments(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            1 => fuzz_long_arguments(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            2 => fuzz_unicode_input(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            3 => fuzz_control_characters(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            4 => fuzz_empty_and_null_args(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            5 => fuzz_extremely_long_commands(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            6 => fuzz_mixed_valid_invalid(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            7 => fuzz_boundary_conditions(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            else => {},
        }

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
    const args = try allocator.alloc([:0]const u8, arg_count);
    defer allocator.free(args);

    for (args, 0..) |*arg, i| {
        const start_idx = (i * input.len / args.len);
        const end_idx = @min(((i + 1) * input.len / args.len), input.len);

        if (start_idx >= end_idx) {
            arg.* = try allocator.dupeZ(u8, "");
        } else {
            const slice = input[start_idx..end_idx];
            arg.* = try allocator.dupeZ(u8, slice);
        }
    }
    defer {
        for (args) |arg| {
            allocator.free(arg);
        }
    }

    // This should never crash, only return errors
    var result = parse_natural_command(allocator, args) catch |err| switch (err) {
        // These are expected errors, not crashes
        NaturalCommandError.UnknownCommand, NaturalCommandError.InvalidSyntax, NaturalCommandError.MissingRequiredArgument, NaturalCommandError.TooManyArguments, NaturalCommandError.InvalidWorkspaceName, NaturalCommandError.InvalidEntityType, NaturalCommandError.InvalidRelationType, NaturalCommandError.InvalidDirection, error.OutOfMemory => return,
        else => return err, // This would be a crash we want to catch
    };
    result.deinit();
}

fn fuzz_long_arguments(allocator: std.mem.Allocator, input: []const u8) !void {
    // Create arguments with excessive length
    const base_args = [_][:0]const u8{ "kausal", "find", "function" };
    var args = try allocator.alloc([:0]const u8, base_args.len + 1);
    defer allocator.free(args);

    // Copy base args
    for (base_args, 0..) |base_arg, i| {
        args[i] = try allocator.dupeZ(u8, base_arg);
    }
    defer {
        for (args[0..base_args.len]) |arg| {
            allocator.free(arg);
        }
    }

    // Create an extremely long argument
    var long_arg = std.array_list.Managed(u8).init(allocator);
    defer long_arg.deinit();

    const repeat_count = @min(input.len * 1000, 100000); // Cap at 100KB
    for (0..repeat_count) |i| {
        try long_arg.append(input[i % input.len]);
    }

    args[base_args.len] = try allocator.dupeZ(u8, long_arg.items);
    defer allocator.free(args[base_args.len]);

    var result = parse_natural_command(allocator, args) catch |err| switch (err) {
        NaturalCommandError.UnknownCommand, NaturalCommandError.InvalidSyntax, NaturalCommandError.MissingRequiredArgument, NaturalCommandError.TooManyArguments, NaturalCommandError.InvalidWorkspaceName, NaturalCommandError.InvalidEntityType, NaturalCommandError.InvalidRelationType, NaturalCommandError.InvalidDirection, error.OutOfMemory => return,
        else => return err,
    };
    result.deinit();
}

fn fuzz_unicode_input(allocator: std.mem.Allocator, input: []const u8) !void {
    // Mix valid commands with unicode characters
    const unicode_chars = "🦀🔥💻🚀αβγδε测试中文العربية";

    var args = try allocator.alloc([:0]const u8, 4);
    defer allocator.free(args);

    args[0] = try allocator.dupeZ(u8, "kausal");
    args[1] = try allocator.dupeZ(u8, "find");

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

    args[2] = try allocator.dupeZ(u8, mixed.items);
    args[3] = try allocator.dupeZ(u8, unicode_chars);

    defer {
        for (args) |arg| {
            allocator.free(arg);
        }
    }

    var result = parse_natural_command(allocator, args) catch |err| switch (err) {
        NaturalCommandError.UnknownCommand, NaturalCommandError.InvalidSyntax, NaturalCommandError.MissingRequiredArgument, NaturalCommandError.TooManyArguments, NaturalCommandError.InvalidWorkspaceName, NaturalCommandError.InvalidEntityType, NaturalCommandError.InvalidRelationType, NaturalCommandError.InvalidDirection, error.OutOfMemory => return,
        else => return err,
    };
    result.deinit();
}

fn fuzz_control_characters(allocator: std.mem.Allocator, input: []const u8) !void {
    var args = try allocator.alloc([:0]const u8, 3);
    defer allocator.free(args);

    args[0] = try allocator.dupeZ(u8, "kausal");
    args[1] = try allocator.dupeZ(u8, "status");

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

    args[2] = try allocator.dupeZ(u8, controlled.items);
    defer {
        for (args) |arg| {
            allocator.free(arg);
        }
    }

    var result = parse_natural_command(allocator, args) catch |err| switch (err) {
        NaturalCommandError.UnknownCommand, NaturalCommandError.InvalidSyntax, NaturalCommandError.MissingRequiredArgument, NaturalCommandError.TooManyArguments, NaturalCommandError.InvalidWorkspaceName, NaturalCommandError.InvalidEntityType, NaturalCommandError.InvalidRelationType, NaturalCommandError.InvalidDirection, error.OutOfMemory => return,
        else => return err,
    };
    result.deinit();
}

fn fuzz_empty_and_null_args(allocator: std.mem.Allocator, input: []const u8) !void {
    _ = input;

    // Test various empty/null argument patterns
    const test_cases = [_][]const [:0]const u8{
        &[_][:0]const u8{}, // No arguments at all
        &[_][:0]const u8{""}, // Single empty argument
        &[_][:0]const u8{ "kausal", "" }, // Empty command
        &[_][:0]const u8{ "", "find", "function" }, // Empty program name
        &[_][:0]const u8{ "kausal", "find", "", "test" }, // Empty middle argument
        &[_][:0]const u8{ "kausal", "find", "function", "" }, // Empty final argument
    };

    for (test_cases) |args| {
        var result = parse_natural_command(allocator, args) catch |err| switch (err) {
            NaturalCommandError.UnknownCommand, NaturalCommandError.InvalidSyntax, NaturalCommandError.MissingRequiredArgument, NaturalCommandError.TooManyArguments, NaturalCommandError.InvalidWorkspaceName, NaturalCommandError.InvalidEntityType, NaturalCommandError.InvalidRelationType, NaturalCommandError.InvalidDirection, error.OutOfMemory => continue,
            else => return err,
        };
        result.deinit();
    }
}

fn fuzz_extremely_long_commands(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len == 0) return;

    // Create massively long command with many arguments
    const max_args = @min(input.len, 100); // Cap at 100 args to prevent OOM
    const args = try allocator.alloc([:0]const u8, max_args);
    defer allocator.free(args);

    for (args, 0..) |*arg, i| {
        // Create progressively longer arguments
        const arg_len = @min((i + 1) * input.len / max_args, 10000);
        const long_arg = try allocator.alloc(u8, arg_len);

        for (long_arg, 0..) |*char, j| {
            char.* = input[j % input.len];
        }

        arg.* = try allocator.dupeZ(u8, long_arg);
        allocator.free(long_arg);
    }
    defer {
        for (args) |arg| {
            allocator.free(arg);
        }
    }

    var result = parse_natural_command(allocator, args) catch |err| switch (err) {
        NaturalCommandError.UnknownCommand, NaturalCommandError.InvalidSyntax, NaturalCommandError.MissingRequiredArgument, NaturalCommandError.TooManyArguments, NaturalCommandError.InvalidWorkspaceName, NaturalCommandError.InvalidEntityType, NaturalCommandError.InvalidRelationType, NaturalCommandError.InvalidDirection, error.OutOfMemory => return,
        else => return err,
    };
    result.deinit();
}

fn fuzz_mixed_valid_invalid(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 4) return;

    // Mix valid command structures with invalid arguments
    const valid_commands = [_][]const u8{ "link", "find", "show", "trace", "status", "sync" };
    const valid_entities = [_][]const u8{ "function", "struct", "file", "module" };

    var args = try allocator.alloc([:0]const u8, 6);
    defer allocator.free(args);

    args[0] = try allocator.dupeZ(u8, "kausal");

    // Pick a valid command
    const cmd_idx = input[0] % valid_commands.len;
    args[1] = try allocator.dupeZ(u8, valid_commands[cmd_idx]);

    // Mix valid entity with garbage
    const entity_idx = input[1] % valid_entities.len;
    args[2] = try allocator.dupeZ(u8, valid_entities[entity_idx]);

    // Add progressively more garbage
    for (args[3..], 0..) |*arg, i| {
        const start = 2 + i;
        const end = @min(start + (input.len / 4), input.len);
        if (start >= input.len) {
            arg.* = try allocator.dupeZ(u8, "");
        } else {
            arg.* = try allocator.dupeZ(u8, input[start..end]);
        }
    }
    defer {
        for (args) |arg| {
            allocator.free(arg);
        }
    }

    var result = parse_natural_command(allocator, args) catch |err| switch (err) {
        NaturalCommandError.UnknownCommand, NaturalCommandError.InvalidSyntax, NaturalCommandError.MissingRequiredArgument, NaturalCommandError.TooManyArguments, NaturalCommandError.InvalidWorkspaceName, NaturalCommandError.InvalidEntityType, NaturalCommandError.InvalidRelationType, NaturalCommandError.InvalidDirection, error.OutOfMemory => return,
        else => return err,
    };
    result.deinit();
}

fn fuzz_boundary_conditions(allocator: std.mem.Allocator, input: []const u8) !void {
    // Test boundary conditions that might cause issues
    const boundary_tests = [_][]const [:0]const u8{
        // Single character arguments
        &[_][:0]const u8{ "k", "f", "t", "x" },
        // Maximum reasonable argument count
        &[_][:0]const u8{ "kausal", "find", "function", "test", "in", "workspace", "with", "extra", "args", "here" },
        // Mixed empty and single chars
        &[_][:0]const u8{ "kausal", "", "f", "", "x" },
    };

    for (boundary_tests) |args| {
        var result = parse_natural_command(allocator, args) catch |err| switch (err) {
            NaturalCommandError.UnknownCommand, NaturalCommandError.InvalidSyntax, NaturalCommandError.MissingRequiredArgument, NaturalCommandError.TooManyArguments, NaturalCommandError.InvalidWorkspaceName, NaturalCommandError.InvalidEntityType, NaturalCommandError.InvalidRelationType, NaturalCommandError.InvalidDirection, error.OutOfMemory => continue,
            else => return err,
        };
        result.deinit();
    }

    // Test with input-derived boundary cases
    if (input.len > 0) {
        const single_char_args = try allocator.alloc([:0]const u8, @min(input.len, 20));
        defer allocator.free(single_char_args);

        for (single_char_args, 0..) |*arg, i| {
            const char_slice = input[i .. i + 1];
            arg.* = try allocator.dupeZ(u8, char_slice);
        }
        defer {
            for (single_char_args) |arg| {
                allocator.free(arg);
            }
        }

        var result = parse_natural_command(allocator, single_char_args) catch |err| switch (err) {
            NaturalCommandError.UnknownCommand, NaturalCommandError.InvalidSyntax, NaturalCommandError.MissingRequiredArgument, NaturalCommandError.TooManyArguments, NaturalCommandError.InvalidWorkspaceName, NaturalCommandError.InvalidEntityType, NaturalCommandError.InvalidRelationType, NaturalCommandError.InvalidDirection, error.OutOfMemory => return,
            else => return err,
        };
        result.deinit();
    }
}
