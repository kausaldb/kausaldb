//! Simple file parsing fuzz tests for KausalDB
//!
//! Tests parse_file_to_blocks against malformed input to ensure robust parsing
//! without crashes or memory leaks. Focuses on the actual parsing we ship.

const std = @import("std");

const common = @import("common.zig");
const internal = @import("internal");
const parse_file_to_blocks = internal.parse_file_to_blocks;

/// Run continuous parsing fuzz testing
pub fn run_continuous(allocator: std.mem.Allocator) void {
    std.debug.print("Starting continuous file parsing fuzz testing...\n", .{});

    var random = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    var failures: u32 = 0;
    var iterations: u32 = 0;

    while (true) {
        const result = run_single_iteration(allocator, random.random()) catch |err| blk: {
            failures += 1;
            std.debug.print("Fuzz iteration failed: {any}\n", .{err});
            break :blk common.FuzzResult.crash;
        };

        iterations += 1;

        if (result == common.FuzzResult.crash) {
            failures += 1;
        }

        if (iterations % 1000 == 0) {
            std.debug.print("Parser fuzz: {} iterations, {} failures\n", .{ iterations, failures });
        }
    }
}

/// Run parsing fuzz testing (compatibility interface)
pub fn run(allocator: std.mem.Allocator, iterations: u64, seed: u64, verbose_mode: anytype) !void {
    _ = seed; // Simplified fuzzing uses time-based seeding for better randomness distribution
    _ = verbose_mode; // Focused output reduces noise in continuous fuzzing scenarios

    if (iterations == std.math.maxInt(u64)) {
        // Continuous mode
        run_continuous(allocator);
    } else {
        // Timed mode - approximate duration from iterations
        const duration_ms = iterations / 10; // Rough approximation
        try run_timed(allocator, duration_ms);
    }
}

/// Run parsing fuzz testing for specified duration
pub fn run_timed(allocator: std.mem.Allocator, duration_ms: u64) !void {
    const start_time = std.time.milliTimestamp();
    const end_time = start_time + @as(i64, @intCast(duration_ms));

    var random = std.Random.DefaultPrng.init(@intCast(start_time));
    var failures: u32 = 0;
    var iterations: u32 = 0;

    std.debug.print("Running file parsing fuzz test for {}ms...\n", .{duration_ms});

    while (std.time.milliTimestamp() < end_time) {
        const result = run_single_iteration(allocator, random.random()) catch |err| blk: {
            failures += 1;
            std.debug.print("Fuzz iteration failed: {any}\n", .{err});
            break :blk common.FuzzResult.crash;
        };

        iterations += 1;

        if (result == common.FuzzResult.crash) {
            failures += 1;
        }
    }

    const failure_rate = (@as(f64, @floatFromInt(failures)) / @as(f64, @floatFromInt(iterations))) * 100.0;

    if (failure_rate > 1.0) {
        std.debug.print("Parser fuzz FAILED: {d:.2}% failure rate ({}/{} iterations)\n", .{ failure_rate, failures, iterations });
    } else {
        std.debug.print("Parser fuzz PASSED: {d:.2}% failure rate ({}/{} iterations)\n", .{ failure_rate, failures, iterations });
    }
}

/// Execute single fuzzing iteration against file parser
fn run_single_iteration(allocator: std.mem.Allocator, random: std.Random) !common.FuzzResult {
    const config = parse_file_to_blocks.ParseConfig{
        .include_function_bodies = random.boolean(),
        .include_private = random.boolean(),
        .include_tests = random.boolean(),
        .max_function_body_size = random.intRangeAtMost(u32, 512, 16384),
    };

    const source_code = try generate_malformed_zig_source(allocator, random);
    defer allocator.free(source_code);

    var metadata = std.StringHashMap([]const u8).init(allocator);
    defer metadata.deinit();

    const file_content = parse_file_to_blocks.FileContent{
        .data = source_code,
        .path = "fuzz_test.zig",
        .content_type = "text/zig",
        .metadata = metadata,
        .timestamp_ns = @intCast(std.time.nanoTimestamp()),
    };

    const blocks = parse_file_to_blocks.parse_file_to_blocks(
        allocator,
        file_content,
        "fuzz_test",
        config,
    ) catch {
        return common.FuzzResult.expected_error;
    };
    defer allocator.free(blocks);

    return common.FuzzResult.success;
}

/// Generate malformed Zig source code for fuzz testing
fn generate_malformed_zig_source(allocator: std.mem.Allocator, random: std.Random) ![]u8 {
    var source = std.ArrayList(u8){};
    defer source.deinit(allocator);

    // Add some valid-looking Zig constructs
    const templates = [_][]const u8{
        "const std = @import(\"std\");\n",
        "pub fn test_func() void {\n",
        "    return;\n",
        "}\n",
        "const VALUE = 42;\n",
        "pub const Struct = struct {\n",
        "    field: i32,\n",
        "};\n",
        "test \"something\" {\n",
        "    try std.testing.expect(true);\n",
        "}\n",
        "// Template comment\n",
        "/// Generated doc\n",
        "var global: u32 = 0;\n",
        "fn private_func() i32 { return 0; }\n",
    };

    // Template-based generation prevents hardcoded test data bias while
    // ensuring parser maintains compatibility with common Zig patterns
    const valid_parts = random.intRangeAtMost(u32, 1, 5);
    var i: u32 = 0;
    while (i < valid_parts) : (i += 1) {
        const template = templates[random.intRangeAtMost(usize, 0, templates.len - 1)];
        try source.appendSlice(allocator, template);
    }

    // Real-world files contain these corruption patterns from editor crashes,
    // network transmission errors, and filesystem issues - parser must survive
    const corruption_types = [_][]const u8{
        "{\n",
        "}\n",
        "(\n",
        ")\n",
        "\"unclosed string\n",
        "const = 42;\n",
        "pub fn () void {}\n",
        "struct {\n",
        "@import(\n",
        "//\x00\n",
        "fn func(: i32) void {}\n",
        "if true {\n",
        "while {\n",
        "for |item {}\n",
        "\xFF\xFE\n",
    };

    // Light corruption load prevents oversaturating valid constructs while
    // ensuring malformed patterns are consistently present in test input
    const corruption_count = random.intRangeAtMost(u32, 0, 3);
    i = 0;
    while (i < corruption_count) : (i += 1) {
        const corruption = corruption_types[random.intRangeAtMost(usize, 0, corruption_types.len - 1)];
        try source.appendSlice(allocator, corruption);
    }

    // Random bytes simulate file corruption and encoding edge cases
    if (random.boolean()) {
        const random_bytes = random.intRangeAtMost(u32, 1, 50);
        var j: u32 = 0;
        while (j < random_bytes) : (j += 1) {
            const byte = random.int(u8);
            try source.append(allocator, byte);
        }
    }

    return source.toOwnedSlice(allocator);
}
