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
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const log_level = parse_log_level(b.option([]const u8, "log-level", "Log level") orelse "info");
    const filter = b.option([]const u8, "filter", "Test filter pattern");

    // FIXME: Debug mode by default to avoid hanging issues in optimized builds
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .Debug });

    const options = b.addOptions();
    options.addOption(std.log.Level, "log_level", log_level);

    const context = BuildContext{
        .b = b,
        .target = target,
        .optimize = optimize,
        .log_level = log_level,
        .options = options,
        .filter = filter,
    };

    build_kausal_binaries(context);
    build_test_suites(context);
    build_dev_tool(context);
    build_lint(context);
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

    // Default run target points to `kausal` (CLI)
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

    const e2e_tests = create_test_executable(context, .{
        .name = "e2e-tests",
        .root_source = "tests/e2e_tests.zig",
        .description = "End-to-end tests",
    });

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

fn build_dev_tool(context: BuildContext) void {
    const wait_for_server = create_executable(context, .{
        .name = "wait-for-server",
        .root_source = "src/dev/wait_for_server.zig",
        .binary_type = .dev_tool,
    });
    context.b.installArtifact(wait_for_server);
}

fn build_lint(context: BuildContext) void {
    const fmt_step = context.b.step("fmt", "Format source code");
    fmt_step.dependOn(&context.b.addFmt(.{ .paths = &.{ "src", "tests", "build.zig" } }).step);

    const fmt_check = context.b.step("fmt-check", "Check source code formatting");
    fmt_check.dependOn(&context.b.addFmt(.{ .paths = &.{ "src", "tests", "build.zig" }, .check = true }).step);

    const tidy = create_tidy_checker(context);
    const tidy_step = context.b.step("tidy", "Run code quality checks");
    tidy_step.dependOn(&tidy.step);
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
    return exe;
}

const TestConfig = struct {
    name: []const u8,
    root_source: []const u8,
    description: []const u8,
};

fn create_test_executable(context: BuildContext, config: TestConfig) *std.Build.Step.Compile {
    const test_exe = context.b.addTest(.{
        .name = config.name,
        .root_module = context.b.createModule(.{
            .root_source_file = context.b.path(config.root_source),
            .target = context.target,
            .optimize = context.optimize,
            .single_threaded = true,
        }),
    });

    test_exe.root_module.addImport("build_options", context.options.createModule());

    if (context.filter) |filter| {
        test_exe.filters = &.{filter};
    }

    return test_exe;
}

fn create_test_runner(context: BuildContext, test_exe: *std.Build.Step.Compile) *std.Build.Step.Run {
    const run_test = context.b.addRunArtifact(test_exe);
    run_test.setEnvironmentVariable("KAUSAL_LOG_LEVEL", "info");

    if (context.filter) |filter| {
        run_test.addArg("--filter");
        run_test.addArg(filter);
    }

    return run_test;
}

fn create_e2e_runner(context: BuildContext, e2e_tests: *std.Build.Step.Compile) *std.Build.Step {
    const E2E_PORT = 3839;
    const E2E_DATA_DIR = ".kausaldb_data/e2e";
    const E2E_TIMEOUT_MS = 10000;

    const wait_for_server = create_executable(context, .{
        .name = "wait-for-server",
        .root_source = "src/dev/wait_for_server.zig",
        .binary_type = .dev_tool,
    });

    context.b.installArtifact(wait_for_server);
    context.b.installArtifact(e2e_tests);

    // Step 1: Clean previous E2E data
    const clean_step = context.b.addRemoveDirTree(context.b.path(E2E_DATA_DIR));

    // Step 2: Stop any lingering server (ignore failures)
    const stop_lingering = context.b.addSystemCommand(&.{ "sh", "-c", "zig-out/bin/kausal-server stop --port " ++ std.fmt.comptimePrint("{}", .{E2E_PORT}) ++ " || true" });
    stop_lingering.step.dependOn(&clean_step.step);

    // Step 3: Start server in foreground mode with background execution
    const start_server = context.b.addSystemCommand(&.{ "sh", "-c", "zig-out/bin/kausal-server start --foreground --port " ++
        std.fmt.comptimePrint("{}", .{E2E_PORT}) ++
        " --data-dir " ++ E2E_DATA_DIR ++
        " --log-level info" ++
        " > /tmp/kausal-e2e-server.log 2>&1 &" });
    start_server.step.dependOn(&stop_lingering.step);

    // Step 4: Wait for server readiness
    const wait_server = context.b.addRunArtifact(wait_for_server);
    wait_server.addArgs(&.{ "--timeout", std.fmt.comptimePrint("{}", .{E2E_TIMEOUT_MS}), std.fmt.comptimePrint("{}", .{E2E_PORT}) });
    wait_server.step.dependOn(&start_server.step);

    // Step 5: Run E2E tests
    const run_tests = context.b.addRunArtifact(e2e_tests);
    run_tests.setEnvironmentVariable("KAUSAL_E2E_TEST_PORT", std.fmt.comptimePrint("{}", .{E2E_PORT}));
    run_tests.setEnvironmentVariable("KAUSAL_LOG_LEVEL", "info");

    if (context.filter) |filter| {
        run_tests.addArg("--filter");
        run_tests.addArg(filter);
    }
    run_tests.step.dependOn(&wait_server.step);

    // Step 6: Cleanup server (always runs)
    const stop_server = context.b.addSystemCommand(&.{ "sh", "-c", "pkill -f 'kausal-server.*--port " ++ std.fmt.comptimePrint("{}", .{E2E_PORT}) ++ "' || true" });
    stop_server.step.dependOn(&run_tests.step);

    const orchestration_step = context.b.step("e2e-runner", "E2E test runner");
    orchestration_step.dependOn(context.b.getInstallStep());
    orchestration_step.dependOn(&stop_server.step);

    return orchestration_step;
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

    return tidy_exe;
}

fn parse_log_level(level_str: []const u8) std.log.Level {
    const level_map = std.StaticStringMap(std.log.Level).initComptime(.{
        .{ "err", .err },
        .{ "warn", .warn },
        .{ "info", .info },
        .{ "debug", .debug },
    });

    return level_map.get(level_str) orelse .info;
}
