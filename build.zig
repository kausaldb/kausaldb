const std = @import("std");
const builtin = @import("builtin");

const REQUIRED_ZIG_VERSION = std.SemanticVersion{ .major = 0, .minor = 15, .patch = 1 };

comptime {
    const correct_zig_version = REQUIRED_ZIG_VERSION.order(builtin.zig_version) == .eq;
    if (!correct_zig_version) {
        @compileError(std.fmt.comptimePrint(
            "KausalDB requires exact Zig version {}, found {}. Run: ./scripts/install_zig.sh",
            .{ REQUIRED_ZIG_VERSION, builtin.zig_version },
        ));
    }
}

const BinaryType = enum {
    kausal,
    testing,
    dev_tool,
};

const BuildContext = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    log_level: std.log.Level,
    options: *std.Build.Step.Options,
    filter: ?[]const u8,
    fuzz_iterations: u32,
};

fn parse_log_level(level_str: []const u8) std.log.Level {
    const level_map = std.StaticStringMap(std.log.Level).initComptime(.{
        .{ "err", .err },
        .{ "warn", .warn },
        .{ "info", .info },
        .{ "debug", .debug },
    });

    return level_map.get(level_str) orelse .info;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Log level defaults to 'info' for optimal production performance
    // Debug logs can significantly impact hot path performance (microsecond-level operations)
    // Override with -Dlog-level=debug for development debugging
    const log_level = parse_log_level(b.option([]const u8, "log-level", "Log level") orelse "info");
    const filter = b.option([]const u8, "filter", "Test filter pattern");

    // CI compatibility options
    const seed_str = b.option([]const u8, "seed", "Random seed for testing") orelse "0xDEADBEEF";
    const seed = if (std.mem.startsWith(u8, seed_str, "0x"))
        std.fmt.parseInt(u64, seed_str[2..], 16) catch 0xDEADBEEF
    else
        std.fmt.parseInt(u64, seed_str, 10) catch 0xDEADBEEF;
    const test_iterations = b.option(u32, "test-iterations", "Number of test iterations") orelse 1;

    // ReleaseSafe provides optimal performance while maintaining safety checks
    // Essential for KausalDB's microsecond-level performance requirements
    // Override with -Doptimize=Debug for development debugging and detailed stack traces
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // Build options for benchmarks and fuzzing
    const bench_iterations = b.option(u32, "bench-iterations", "Number of benchmark iterations") orelse 1000;
    const bench_warmup = b.option(u32, "bench-warmup", "Number of warmup iterations") orelse 100;
    const bench_baseline = b.option([]const u8, "bench-baseline", "Baseline file for regression detection");
    const fuzz_iterations = b.option(u32, "fuzz-iterations", "Number of fuzzing iterations") orelse 10000;
    const fuzz_corpus = b.option([]const u8, "fuzz-corpus", "Fuzz corpus directory") orelse "fuzz-corpus";

    const options = b.addOptions();
    options.addOption(std.log.Level, "log_level", log_level);
    options.addOption(u32, "bench_iterations", bench_iterations);
    options.addOption(u32, "bench_warmup", bench_warmup);
    options.addOption(?[]const u8, "bench_baseline", bench_baseline);
    options.addOption(u32, "fuzz_iterations", fuzz_iterations);
    options.addOption([]const u8, "fuzz_corpus", fuzz_corpus);
    options.addOption(u64, "seed", seed);
    options.addOption(u32, "test_iterations", test_iterations);

    const context = BuildContext{
        .b = b,
        .target = target,
        .optimize = optimize,
        .log_level = log_level,
        .options = options,
        .filter = filter,
        .fuzz_iterations = fuzz_iterations,
    };

    build_kausal_binaries(context);
    build_test_suites(context);
    build_lint(context);
    build_performance_tools(context);
}

fn build_kausal_binaries(context: BuildContext) void {
    const kausal_cli = create_executable(context, .{
        .name = "kausal",
        .root_source = "src/main.zig",
        .binary_type = .kausal,
    });

    const kausal_server = create_executable(context, .{
        .name = "kausal-server",
        .root_source = "src/server_main.zig",
        .binary_type = .kausal,
    });

    context.b.installArtifact(kausal_cli);
    context.b.installArtifact(kausal_server);

    const run_cli = context.b.addRunArtifact(kausal_cli);
    run_cli.step.dependOn(context.b.getInstallStep());
    if (context.b.args) |args| {
        run_cli.addArgs(args);
    }

    const run_step = context.b.step("run", "Run KausalDB CLI");
    run_step.dependOn(&run_cli.step);
}

fn build_test_suites(context: BuildContext) void {
    const unit_tests = create_test_executable(context, .{
        .name = "test",
        .root_source = "src/unit_tests.zig",
        .description = "Run unit tests",
    });

    const integration_tests = create_test_executable(context, .{
        .name = "integration-tests",
        .root_source = "src/integration_tests.zig",
        .description = "Run integration tests",
    });

    // E2E tests expect the server port as the first command-line argument
    const e2e_tests = create_test_executable(context, .{
        .name = "e2e-tests",
        .root_source = "tests/e2e_tests.zig",
        .description = "End-to-end tests",
    });

    const test_unit = context.b.step("test-unit", "Run unit tests");
    test_unit.dependOn(&create_test_runner(context, unit_tests).step);

    const test_integration = context.b.step("test-integration", "Run integration tests");
    test_integration.dependOn(&create_test_runner(context, integration_tests).step);

    const test_fast = context.b.step("test", "Run fast test suite (unit + integration)");
    test_fast.dependOn(&create_test_runner(context, unit_tests).step);
    test_fast.dependOn(&create_test_runner(context, integration_tests).step);

    const e2e_step = create_e2e_runner(context, e2e_tests);
    const test_e2e = context.b.step("test-e2e", "Run end-to-end tests with server lifecycle");
    test_e2e.dependOn(e2e_step);

    const test_all = context.b.step("test-all", "Run complete test suite");
    test_all.dependOn(test_fast);
    test_all.dependOn(test_e2e);
}

fn build_lint(context: BuildContext) void {
    const fmt_step = context.b.step("fmt", "Format source code");
    fmt_step.dependOn(&context.b.addFmt(.{ .paths = &.{ "src", "tests", "build.zig" } }).step);

    const fmt_check = context.b.step("fmt-check", "Check source code formatting");
    fmt_check.dependOn(&context.b.addFmt(.{ .paths = &.{ "src", "tests", "build.zig" }, .check = true }).step);

    const tidy = create_tidy_checker(context);
    const run_tidy = context.b.addRunArtifact(tidy);
    const tidy_step = context.b.step("tidy", "Run code quality checks");
    tidy_step.dependOn(&run_tidy.step);
}

fn build_performance_tools(context: BuildContext) void {
    // Benchmarks always use ReleaseFast for maximum performance measurement
    // Override context.optimize to ensure accurate performance data
    var bench_context = context;
    bench_context.optimize = .ReleaseFast;

    const benchmark_exe = create_executable(bench_context, .{
        .name = "benchmark",
        .root_source = "src/bench/main.zig",
        .binary_type = .dev_tool,
    });
    context.b.installArtifact(benchmark_exe);

    const fuzz_exe = create_executable(context, .{
        .name = "fuzz",
        .root_source = "src/fuzz/main.zig",
        .binary_type = .dev_tool,
    });
    context.b.installArtifact(fuzz_exe);

    const run_bench = context.b.addRunArtifact(benchmark_exe);
    if (context.b.args) |args| {
        run_bench.addArgs(args);
    }

    const bench_step = context.b.step("bench", "Run performance benchmarks");
    bench_step.dependOn(&run_bench.step);

    const run_fuzz = context.b.addRunArtifact(fuzz_exe);
    if (context.b.args) |args| {
        run_fuzz.addArgs(args);
    }

    const fuzz_step = context.b.step("fuzz", "Run extensive fuzzing tests");
    fuzz_step.dependOn(&run_fuzz.step);
    const run_fuzz_quick = context.b.addRunArtifact(fuzz_exe);
    run_fuzz_quick.addArg("--iterations");
    run_fuzz_quick.addArg("1000");
    run_fuzz_quick.addArg("--timeout");
    run_fuzz_quick.addArg("100");
    if (context.b.args) |args| {
        run_fuzz_quick.addArgs(args);
    }

    const fuzz_quick_step = context.b.step("fuzz-quick", "Run quick fuzzing tests for CI");
    fuzz_quick_step.dependOn(&run_fuzz_quick.step);

    // Parallel fuzzing support - cross-platform
    const fuzz_parallel_step = context.b.step("fuzz-parallel", "Run parallel fuzzing campaign");
    const cores = context.b.option(u32, "fuzz-cores", "Number of parallel fuzzers") orelse 4;

    var i: u32 = 0;
    while (i < cores) : (i += 1) {
        const run_fuzz_instance = context.b.addRunArtifact(fuzz_exe);
        run_fuzz_instance.addArg("--iterations");
        const iterations_str = context.b.fmt("{d}", .{context.fuzz_iterations});
        run_fuzz_instance.addArg(iterations_str);
        fuzz_parallel_step.dependOn(&run_fuzz_instance.step);
    }
}

const ExecutableConfig = struct {
    name: []const u8,
    root_source: []const u8,
    binary_type: BinaryType,
};

fn create_executable(context: BuildContext, config: ExecutableConfig) *std.Build.Step.Compile {
    const exe = context.b.addExecutable(.{
        .name = config.name,
        .root_module = context.b.createModule(.{
            .root_source_file = context.b.path(config.root_source),
            .target = context.target,
            .optimize = context.optimize,
            .single_threaded = true, // KausalDB is single-threaded by design
        }),
    });

    exe.root_module.addImport("build_options", context.options.createModule());

    // Add internal module for dev tools (benchmarks, fuzzing)
    if (config.binary_type == .dev_tool) {
        const internal_module = context.b.createModule(.{
            .root_source_file = context.b.path("src/internal.zig"),
        });
        exe.root_module.addImport("internal", internal_module);
    }

    // Server executables need libc for system calls like setsid()
    if (config.binary_type == .kausal) {
        exe.linkLibC();
    }

    return exe;
}

const TestConfig = struct {
    name: []const u8,
    root_source: []const u8,
    description: []const u8,
};

fn create_test_executable(context: BuildContext, config: TestConfig) *std.Build.Step.Compile {
    // Allow threading for integration tests to support client-server testing
    const allow_threading = std.mem.eql(u8, config.name, "integration-tests");

    const test_exe = context.b.addTest(.{
        .name = config.name,
        .root_module = context.b.createModule(.{
            .root_source_file = context.b.path(config.root_source),
            .target = context.target,
            .optimize = context.optimize,
            .single_threaded = !allow_threading,
        }),
    });

    test_exe.root_module.addImport("build_options", context.options.createModule());

    if (context.filter) |filter| {
        const filter_slice = context.b.allocator.dupe([]const u8, &.{filter}) catch &.{};
        test_exe.filters = filter_slice;
    }

    return test_exe;
}

fn create_test_runner(context: BuildContext, test_exe: *std.Build.Step.Compile) *std.Build.Step.Run {
    const run_test = context.b.addRunArtifact(test_exe);
    return run_test;
}

const E2E_PORT: u16 = 3839;
const E2E_DATA_DIR = ".kausaldb_data/e2e";
const E2E_PID_FILE = ".kausaldb_data/e2e/server.pid";
const E2E_TIMEOUT_MS: u32 = 10000;
const E2E_STDOUT_PATH = 10000;

const E2EServerStep = struct {
    step: std.Build.Step,
    b: *std.Build,
    allocator: std.mem.Allocator,
    server_exe: *std.Build.Step.Compile,

    const Self = @This();

    pub fn create(b: *std.Build, server_exe: *std.Build.Step.Compile) *Self {
        const self = b.allocator.create(Self) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "start-e2e-server",
                .owner = b,
                .makeFn = make,
            }),
            .b = b,
            .allocator = b.allocator,
            .server_exe = server_exe,
        };

        self.step.dependOn(&server_exe.step);
        self.step.dependOn(b.getInstallStep());

        return self;
    }

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
        const self: *Self = @fieldParentPtr("step", step);

        // Kill any existing processes on the port first
        self.kill_port_processes(E2E_PORT) catch {};

        // Clean test environment and stray log files
        std.fs.cwd().deleteTree(E2E_DATA_DIR) catch {};
        std.fs.cwd().deleteFile(E2E_PID_FILE) catch {};
        try std.fs.cwd().makePath(E2E_DATA_DIR);

        // Wait a bit to ensure port is free
        std.Thread.sleep(200 * std.time.ns_per_ms);

        // Start server in background
        const server_path = self.server_exe.getEmittedBin().getPath(self.b);
        const port_str = try std.fmt.allocPrint(self.allocator, "{}", .{E2E_PORT});
        defer self.allocator.free(port_str);

        var server_process = std.process.Child.init(&.{
            server_path,
            "start",
            "--foreground",
            "--port",
            port_str,
            "--data-dir",
            E2E_DATA_DIR,
            "--log-level",
            "warn",
        }, self.allocator);

        server_process.stdout_behavior = .Ignore;
        server_process.stderr_behavior = .Ignore;
        server_process.stdin_behavior = .Close;

        try server_process.spawn();

        // Write PID to file for cleanup
        const pid_file = try std.fs.cwd().createFile(E2E_PID_FILE, .{});
        defer pid_file.close();
        const pid_str = try std.fmt.allocPrint(self.allocator, "{}\n", .{server_process.id});
        defer self.allocator.free(pid_str);
        try pid_file.writeAll(pid_str);

        // Wait for server readiness
        try self.wait_for_server();
    }

    fn kill_port_processes(self: *Self, port: u16) !void {
        const port_str = try std.fmt.allocPrint(self.allocator, "{d}", .{port});
        defer self.allocator.free(port_str);

        const lsof_arg = try std.fmt.allocPrint(self.allocator, ":{s}", .{port_str});
        defer self.allocator.free(lsof_arg);

        const lsof_result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "lsof", "-t", "-i", lsof_arg },
        }) catch return;
        defer {
            self.allocator.free(lsof_result.stdout);
            self.allocator.free(lsof_result.stderr);
        }

        if (lsof_result.stdout.len > 0) {
            var pid_iter = std.mem.tokenizeAny(u8, lsof_result.stdout, " \n\r\t");
            while (pid_iter.next()) |pid_str_raw| {
                const pid = std.fmt.parseInt(std.posix.pid_t, pid_str_raw, 10) catch continue;
                std.posix.kill(pid, std.posix.SIG.KILL) catch {};
            }
        }
    }

    fn wait_for_server(self: *Self) !void {
        _ = self;
        const start_time = std.time.milliTimestamp();
        var retry_delay_ms: u64 = 50;

        while (std.time.milliTimestamp() - start_time < E2E_TIMEOUT_MS) {
            if (try_connect(E2E_PORT)) return;

            std.Thread.sleep(retry_delay_ms * std.time.ns_per_ms);
            retry_delay_ms = @min(retry_delay_ms * 2, 500);
        }

        return error.ServerTimeout;
    }

    fn try_connect(port: u16) bool {
        const address = std.net.Address.parseIp("127.0.0.1", port) catch return false;
        const socket = std.net.tcpConnectToAddress(address) catch return false;
        socket.close();
        return true;
    }
};

const E2ECleanupStep = struct {
    step: std.Build.Step,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn create(b: *std.Build) *Self {
        const self = b.allocator.create(Self) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "cleanup-e2e-server",
                .owner = b,
                .makeFn = make,
            }),
            .allocator = b.allocator,
        };
        return self;
    }

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
        const self: *Self = @fieldParentPtr("step", step);

        // Kill any process using the E2E port first
        self.kill_port_processes(E2E_PORT) catch {};

        // Kill server using PID file
        const pid_file = std.fs.cwd().openFile(E2E_PID_FILE, .{}) catch return;
        defer pid_file.close();

        const pid_str = try pid_file.readToEndAlloc(self.allocator, 32);
        defer self.allocator.free(pid_str);

        const pid = std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, pid_str, " \n\r\t"), 10) catch return;

        // Try graceful shutdown first, then force kill
        std.posix.kill(pid, std.posix.SIG.TERM) catch {};
        std.Thread.sleep(500 * std.time.ns_per_ms); // Give it time to shutdown
        std.posix.kill(pid, std.posix.SIG.KILL) catch {};

        std.fs.cwd().deleteFile(E2E_PID_FILE) catch {};
    }

    fn kill_port_processes(self: *Self, port: u16) !void {
        // Kill any processes using the port (macOS/Linux)
        const port_str = try std.fmt.allocPrint(self.allocator, "{d}", .{port});
        defer self.allocator.free(port_str);

        const lsof_arg = try std.fmt.allocPrint(self.allocator, ":{s}", .{port_str});
        defer self.allocator.free(lsof_arg);

        // Try lsof approach for finding port users
        const lsof_result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "lsof", "-t", "-i", lsof_arg },
        }) catch return;
        defer {
            self.allocator.free(lsof_result.stdout);
            self.allocator.free(lsof_result.stderr);
        }

        if (lsof_result.stdout.len > 0) {
            var pid_iter = std.mem.tokenizeAny(u8, lsof_result.stdout, " \n\r\t");
            while (pid_iter.next()) |pid_str_raw| {
                const pid = std.fmt.parseInt(std.posix.pid_t, pid_str_raw, 10) catch continue;
                std.posix.kill(pid, std.posix.SIG.KILL) catch {};
            }
        }
    }
};

fn create_e2e_runner(context: BuildContext, e2e_tests: *std.Build.Step.Compile) *std.Build.Step {
    const kausal_server = create_executable(context, .{
        .name = "kausal-server",
        .root_source = "src/server_main.zig",
        .binary_type = .kausal,
    });

    // Install artifacts
    context.b.installArtifact(kausal_server);
    context.b.installArtifact(e2e_tests);

    // Create server startup step
    const server_step = E2EServerStep.create(context.b, kausal_server);

    // Create native test runner that depends on server
    const test_runner = create_test_runner(context, e2e_tests);
    test_runner.step.dependOn(&server_step.step);

    // Set environment variable so tests know which port to use
    test_runner.setEnvironmentVariable("KAUSAL_E2E_TEST_PORT", "3839");

    // Create cleanup step that runs after tests
    const cleanup_step = E2ECleanupStep.create(context.b);
    cleanup_step.step.dependOn(&test_runner.step);

    return &cleanup_step.step;
}

fn create_tidy_checker(context: BuildContext) *std.Build.Step.Compile {
    const tidy_exe = context.b.addExecutable(.{
        .name = "tidy",
        .root_module = context.b.createModule(.{
            .root_source_file = context.b.path("src/dev/tidy.zig"),
            .target = context.target,
            .optimize = context.optimize,
            .single_threaded = true,
        }),
    });

    tidy_exe.root_module.addImport("build_options", context.options.createModule());

    return tidy_exe;
}
