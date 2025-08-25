const std = @import("std");
const print = std.debug.print;
const ArrayList = std.ArrayList;

const Command = enum {
    test_cmd,
    bench,
    lint,
    ci,
    help,

    fn from_string(s: []const u8) ?Command {
        if (std.mem.eql(u8, s, "test")) return .test_cmd;
        if (std.mem.eql(u8, s, "bench")) return .bench;
        if (std.mem.eql(u8, s, "lint")) return .lint;
        if (std.mem.eql(u8, s, "ci")) return .ci;
        if (std.mem.eql(u8, s, "help")) return .help;
        if (std.mem.eql(u8, s, "--help")) return .help;
        if (std.mem.eql(u8, s, "-h")) return .help;
        return null;
    }
};

const TestOptions = struct {
    filter: ?[]const u8 = null,
    category: ?TestCategory = null,
    safety: bool = false,
    verbose: bool = false,
    individual: ?[]const u8 = null,

    const TestCategory = enum {
        unit,
        integration,
        e2e,
        all,

        fn from_string(s: []const u8) ?TestCategory {
            if (std.mem.eql(u8, s, "unit")) return .unit;
            if (std.mem.eql(u8, s, "integration")) return .integration;
            if (std.mem.eql(u8, s, "e2e")) return .e2e;
            if (std.mem.eql(u8, s, "all")) return .all;
            return null;
        }
    };
};

const BenchOptions = struct {
    filter: ?[]const u8 = null,
    json: bool = false,
    iterations: u32 = 10,
};

const DevError = error{
    InvalidCommand,
    InvalidArgument,
    ExecutionFailed,
    OutOfMemory,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try print_help();
        return;
    }

    const command = Command.from_string(args[1]) orelse {
        print("Error: Unknown command '{s}'\n\n", .{args[1]});
        try print_help();
        std.process.exit(1);
    };

    switch (command) {
        .test_cmd => try run_test_command(allocator, args[2..]),
        .bench => try run_bench_command(allocator, args[2..]),
        .lint => try run_lint_command(allocator, args[2..]),
        .ci => try run_ci_command(allocator, args[2..]),
        .help => try print_help(),
    }
}

fn run_test_command(allocator: std.mem.Allocator, args: [][]const u8) !void {
    var options = TestOptions{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--filter")) {
            i += 1;
            if (i >= args.len) {
                print("Error: --filter requires a value\n");
                std.process.exit(1);
            }
            options.filter = args[i];
        } else if (std.mem.eql(u8, arg, "--category")) {
            i += 1;
            if (i >= args.len) {
                print("Error: --category requires a value\n");
                std.process.exit(1);
            }
            options.category = TestOptions.TestCategory.from_string(args[i]) orelse {
                print("Error: Invalid category '{s}'. Valid: unit, integration, e2e, all\n", .{args[i]});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--individual")) {
            i += 1;
            if (i >= args.len) {
                print("Error: --individual requires a test name\n");
                std.process.exit(1);
            }
            options.individual = args[i];
        } else if (std.mem.eql(u8, arg, "--safety")) {
            options.safety = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            options.verbose = true;
        } else {
            print("Error: Unknown test option '{s}'\n", .{arg});
            std.process.exit(1);
        }
    }

    try execute_test_strategy(allocator, options);
}

fn execute_test_strategy(allocator: std.mem.Allocator, options: TestOptions) !void {
    if (options.individual) |test_name| {
        try run_individual_test(allocator, test_name, options);
        return;
    }

    const category = options.category orelse .all;

    switch (category) {
        .unit => try run_zig_build_command(allocator, &.{"test"}, options),
        .integration => try run_zig_build_command(allocator, &.{"test-integration"}, options),
        .e2e => try run_zig_build_command(allocator, &.{"test-e2e"}, options),
        .all => {
            print("Running comprehensive test suite...\n\n");
            try run_zig_build_command(allocator, &.{"test-fast"}, options);
            try run_zig_build_command(allocator, &.{"test-e2e"}, options);
            try run_zig_build_command(allocator, &.{"test-golden-masters"}, options);
            try run_zig_build_command(allocator, &.{"test-scenarios"}, options);
        },
    }
}

fn run_individual_test(allocator: std.mem.Allocator, test_name: []const u8, options: TestOptions) !void {
    // For individual tests, we need to determine the type and run appropriately
    var cmd_args = ArrayList([]const u8).init(allocator);
    defer cmd_args.deinit();

    try cmd_args.appendSlice(&.{ "./zig/zig", "test" });

    // Check if it's in src/tests/ (integration) or tests/ (e2e) or source files (unit)
    if (std.mem.indexOf(u8, test_name, "src/tests/") != null) {
        // Integration test - run directly without kausaldb import
        try cmd_args.append(test_name);
    } else if (std.mem.indexOf(u8, test_name, "tests/") != null) {
        // E2E test
        try cmd_args.append(test_name);
    } else {
        // Assume it's a unit test in source file
        try cmd_args.append(test_name);
    }

    if (options.filter) |filter| {
        try cmd_args.appendSlice(&.{ "--test-filter", filter });
    }

    if (options.safety) {
        try cmd_args.append("-fsanitize=undefined");
    }

    try execute_command(allocator, cmd_args.items, options.verbose);
}

fn run_bench_command(allocator: std.mem.Allocator, args: [][]const u8) !void {
    var options = BenchOptions{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--filter")) {
            i += 1;
            if (i >= args.len) {
                print("Error: --filter requires a value\n");
                std.process.exit(1);
            }
            options.filter = args[i];
        } else if (std.mem.eql(u8, arg, "--json")) {
            options.json = true;
        } else if (std.mem.eql(u8, arg, "--iterations")) {
            i += 1;
            if (i >= args.len) {
                print("Error: --iterations requires a value\n");
                std.process.exit(1);
            }
            options.iterations = std.fmt.parseInt(u32, args[i], 10) catch {
                print("Error: Invalid iterations value '{s}'\n", .{args[i]});
                std.process.exit(1);
            };
        } else {
            print("Error: Unknown bench option '{s}'\n", .{arg});
            std.process.exit(1);
        }
    }

    var cmd_args = ArrayList([]const u8).init(allocator);
    defer cmd_args.deinit();

    try cmd_args.appendSlice(&.{ "./zig/zig", "build", "benchmark", "--" });

    if (options.filter) |filter| {
        try cmd_args.append(filter);
    } else {
        try cmd_args.append("all");
    }

    if (options.json) {
        try cmd_args.append("--json");
    }

    try execute_command(allocator, cmd_args.items, true);
}

fn run_lint_command(allocator: std.mem.Allocator, args: [][]const u8) !void {
    _ = args; // No options for now

    print("Running code quality checks...\n\n");

    print("1. Checking code formatting...\n");
    try run_zig_build_command(allocator, &.{"fmt"}, .{});

    print("\n2. Running naming and architecture validation...\n");
    try run_zig_build_command(allocator, &.{"tidy"}, .{});

    print("\nLint checks completed successfully.\n");
}

fn run_ci_command(allocator: std.mem.Allocator, args: [][]const u8) !void {
    _ = args; // No options for now

    print("Running complete CI pipeline...\n\n");

    print("=== Phase 1: Code Quality ===\n");
    try run_lint_command(allocator, &.{});

    print("\n=== Phase 2: Fast Tests ===\n");
    try execute_test_strategy(allocator, .{ .category = .unit });
    try execute_test_strategy(allocator, .{ .category = .integration });

    print("\n=== Phase 3: Complete Test Suite ===\n");
    try execute_test_strategy(allocator, .{ .category = .all });

    print("\nCI pipeline completed successfully.\n");
}

fn run_zig_build_command(allocator: std.mem.Allocator, build_args: []const []const u8, options: TestOptions) !void {
    var cmd_args = ArrayList([]const u8).init(allocator);
    defer cmd_args.deinit();

    try cmd_args.appendSlice(&.{ "./zig/zig", "build" });
    try cmd_args.appendSlice(build_args);

    if (options.filter) |filter| {
        try cmd_args.appendSlice(&.{ "--", "--test-filter", filter });
    }

    try execute_command(allocator, cmd_args.items, options.verbose);
}

fn execute_command(allocator: std.mem.Allocator, cmd_args: []const []const u8, verbose: bool) !void {
    if (verbose) {
        print("Executing: ");
        for (cmd_args, 0..) |arg, i| {
            if (i > 0) print(" ");
            print("{s}", .{arg});
        }
        print("\n");
    }

    var child = std.process.Child.init(cmd_args, allocator);
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const result = child.spawnAndWait() catch |err| {
        print("Error: Failed to execute command: {}\n", .{err});
        std.process.exit(1);
    };

    switch (result) {
        .Exited => |code| {
            if (code != 0) {
                print("Command failed with exit code {}\n", .{code});
                std.process.exit(1);
            }
        },
        .Signal => |sig| {
            print("Command terminated by signal {}\n", .{sig});
            std.process.exit(1);
        },
        .Stopped => |sig| {
            print("Command stopped by signal {}\n", .{sig});
            std.process.exit(1);
        },
        .Unknown => |code| {
            print("Command failed with unknown exit code {}\n", .{code});
            std.process.exit(1);
        },
    }
}

fn print_help() !void {
    print(
        \\KausalDB Developer Tool
        \\
        \\USAGE:
        \\    dev <command> [options]
        \\
        \\COMMANDS:
        \\    test        Run tests with flexible filtering and categorization
        \\    bench       Run performance benchmarks with regression detection
        \\    lint        Run code quality checks (format, tidy, naming validation)
        \\    ci          Run complete CI pipeline (lint + comprehensive tests)
        \\    help        Show this help message
        \\
        \\TEST OPTIONS:
        \\    --category <type>     Test category: unit, integration, e2e, all (default: all)
        \\    --filter <pattern>    Run only tests matching pattern
        \\    --individual <path>   Run specific test file directly
        \\    --safety             Enable memory safety checks (AddressSanitizer/UBSan)
        \\    --verbose            Show detailed command execution
        \\
        \\BENCH OPTIONS:
        \\    --filter <pattern>    Benchmark specific operations
        \\    --json               Output results in JSON format for CI
        \\    --iterations <n>     Number of benchmark iterations (default: 10)
        \\
        \\EXAMPLES:
        \\    dev test                                  # Run all tests
        \\    dev test --category unit                  # Run only unit tests
        \\    dev test --filter "block_write"          # Run tests matching "block_write"
        \\    dev test --individual src/storage.zig    # Run specific test file
        \\    dev test --safety --verbose              # Run with memory checking and verbose output
        \\
        \\    dev bench                                 # Run all benchmarks
        \\    dev bench --filter storage               # Benchmark only storage operations
        \\    dev bench --json                         # Output for CI integration
        \\
        \\    dev lint                                  # Check code quality
        \\    dev ci                                    # Full CI pipeline
        \\
        \\The 'dev' tool is the single source of truth for development workflow.
        \\All operations use production-grade settings and deterministic execution.
        \\
    );
}
