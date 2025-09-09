const std = @import("std");

const BuildOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_filter: ?[]const u8,
    enable_asan: bool,
    enable_ubsan: bool,
    log_level: std.log.Level,

    fn init(b: *std.Build) BuildOptions {
        return BuildOptions{
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),
            .test_filter = b.option([]const u8, "test-filter", "Filter tests by name pattern"),
            .enable_asan = b.option(bool, "enable-asan", "Enable AddressSanitizer") orelse false,
            .enable_ubsan = b.option(bool, "enable-ubsan", "Enable UndefinedBehaviorSanitizer") orelse false,
            .log_level = b.option(std.log.Level, "log-level", "Set log level") orelse .warn,
        };
    }
};

fn create_build_options(b: *std.Build, options: BuildOptions) *std.Build.Step.Options {
    const build_options = b.addOptions();
    build_options.addOption(bool, "debug_tests", options.optimize == .Debug);
    build_options.addOption(bool, "sanitizers_active", options.enable_asan or options.enable_ubsan);
    build_options.addOption(std.log.Level, "log_level", options.log_level);
    return build_options;
}

fn create_test_executable(b: *std.Build, test_file: []const u8, options: BuildOptions) *std.Build.Step.Compile {
    const test_exe = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(test_file),
            .target = options.target,
            .optimize = options.optimize,
        }),
    });

    // Add sanitizer support if enabled
    if (options.enable_asan or options.enable_ubsan) {
        test_exe.root_module.sanitize_c = .full;
    }

    test_exe.root_module.addImport("build_options", create_build_options(b, options).createModule());
    return test_exe;
}

fn create_tool_executable(b: *std.Build, name: []const u8, source_file: []const u8, options: BuildOptions, optimize_mode: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source_file),
            .target = options.target,
            .optimize = optimize_mode,
        }),
    });
    exe.root_module.addImport("build_options", create_build_options(b, options).createModule());
    return exe;
}

fn add_test_step(b: *std.Build, step_name: []const u8, description: []const u8, test_exe: *std.Build.Step.Compile, options: BuildOptions) *std.Build.Step {
    const step = b.step(step_name, description);
    const run_test = b.addRunArtifact(test_exe);
    run_test.has_side_effects = true;

    if (options.test_filter) |filter| {
        run_test.addArgs(&.{ "--test-filter", filter });
    }

    if (b.args) |args| run_test.addArgs(args);
    step.dependOn(&run_test.step);
    return step;
}

pub fn build(b: *std.Build) void {
    const options = BuildOptions.init(b);

    const kausaldb_module = b.createModule(.{
        .root_source_file = b.path("src/kausaldb.zig"),
        .target = options.target,
        .optimize = options.optimize,
    });
    kausaldb_module.addImport("build_options", create_build_options(b, options).createModule());

    const internal_module = b.createModule(.{
        .root_source_file = b.path("src/internal.zig"),
        .target = options.target,
        .optimize = options.optimize,
    });
    internal_module.addImport("build_options", create_build_options(b, options).createModule());

    const exe = b.addExecutable(.{
        .name = "kausaldb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = options.target,
            .optimize = .ReleaseSafe,
        }),
    });
    exe.root_module.addImport("kausaldb", kausaldb_module);
    exe.root_module.addImport("build_options", create_build_options(b, options).createModule());
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run kausaldb server");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = create_test_executable(b, "src/unit_tests.zig", options);
    const test_step = add_test_step(b, "test", "Run unit tests", unit_tests, options);

    const integration_tests = create_test_executable(b, "src/integration_tests.zig", options);
    const integration_step = add_test_step(b, "test-integration", "Run integration tests", integration_tests, options);

    const e2e_tests = create_test_executable(b, "tests/e2e_tests.zig", options);
    const e2e_step = add_test_step(b, "test-e2e", "Run end-to-end tests", e2e_tests, options);
    e2e_step.dependOn(&exe.step);

    const test_fast_step = b.step("test-fast", "Run fast tests (unit + integration)");
    test_fast_step.dependOn(test_step);
    test_fast_step.dependOn(integration_step);

    const test_all_step = b.step("test-all", "Run all tests");
    test_all_step.dependOn(test_fast_step);
    test_all_step.dependOn(e2e_step);

    const unit_only_step = b.step("test-unit-only", "Run only unit tests (fast)");
    unit_only_step.dependOn(test_step);

    const integration_only_step = b.step("test-integration-only", "Run only integration tests");
    integration_only_step.dependOn(integration_step);

    const benchmark_exe = create_tool_executable(b, "benchmark", "src/dev/benchmark.zig", options, .ReleaseFast);
    benchmark_exe.root_module.addImport("internal", internal_module);
    b.installArtifact(benchmark_exe);

    const benchmark_cmd = b.addRunArtifact(benchmark_exe);
    if (b.args) |args| benchmark_cmd.addArgs(args);
    const benchmark_step = b.step("benchmark", "Run performance benchmarks");
    benchmark_step.dependOn(&benchmark_cmd.step);

    const tidy_exe = create_tool_executable(b, "tidy", "src/dev/tidy.zig", options, options.optimize);
    b.installArtifact(tidy_exe);

    const tidy_cmd = b.addRunArtifact(tidy_exe);
    if (b.args) |args| tidy_cmd.addArgs(args);
    const tidy_step = b.step("tidy", "Run code quality checks");
    tidy_step.dependOn(&tidy_cmd.step);

    const fuzz_exe = create_tool_executable(b, "fuzz", "src/dev/fuzz/main.zig", options, options.optimize);
    fuzz_exe.root_module.addImport("internal", internal_module);
    b.installArtifact(fuzz_exe);

    const fuzz_cmd = b.addRunArtifact(fuzz_exe);
    if (b.args) |args| fuzz_cmd.addArgs(args);
    const fuzz_step = b.step("fuzz", "Run fuzz testing");
    fuzz_step.dependOn(&fuzz_cmd.step);

    const commit_msg_validator_exe = create_tool_executable(
        b,
        "commit-msg-validator",
        "src/dev/commit_msg_validator.zig",
        options,
        options.optimize,
    );
    b.installArtifact(commit_msg_validator_exe);

    const commit_msg_validator_step = b.step("commit-msg-validator", "Build commit message validator");
    commit_msg_validator_step.dependOn(&b.addInstallArtifact(commit_msg_validator_exe, .{}).step);

    const fmt_check = b.addFmt(.{
        .paths = &.{ "src", "tests", "build.zig" },
        .check = true,
    });
    const fmt_step = b.step("fmt", "Check code formatting");
    fmt_step.dependOn(&fmt_check.step);

    const fmt_fix = b.addFmt(.{
        .paths = &.{ "src", "tests", "build.zig" },
        .check = false,
    });
    const fmt_fix_step = b.step("fmt-fix", "Fix code formatting");
    fmt_fix_step.dependOn(&fmt_fix.step);

    const ci_smoke_step = b.step("ci-smoke", "Quick smoke tests for rapid feedback");
    ci_smoke_step.dependOn(fmt_step);
    ci_smoke_step.dependOn(tidy_step);
    ci_smoke_step.dependOn(test_step);

    const ci_perf_step = b.step("ci-perf", "Performance regression validation");
    const ci_perf_cmd = b.addRunArtifact(benchmark_exe);
    ci_perf_cmd.addArg("all"); // Run all benchmarks for CI validation
    ci_perf_step.dependOn(&ci_perf_cmd.step);

    const ci_full_step = b.step("ci-full", "Complete CI pipeline");
    ci_full_step.dependOn(ci_smoke_step);
    ci_full_step.dependOn(ci_perf_step);
    ci_full_step.dependOn(test_all_step);

    const ci_stress_step = b.step("ci-stress", "Stress testing with extended scenarios");
    const stress_test_exe = create_tool_executable(
        b,
        "ci-stress",
        "src/dev/ci/stress_runner.zig",
        options,
        options.optimize,
    );
    const run_stress_test = b.addRunArtifact(stress_test_exe);
    if (b.args) |args| run_stress_test.addArgs(args);
    ci_stress_step.dependOn(&run_stress_test.step);

    const ci_security_step = b.step("ci-security", "Security analysis and memory safety checks");
    ci_security_step.dependOn(tidy_step);
    const security_scan_exe = create_tool_executable(
        b,
        "ci-security",
        "src/dev/ci/security_scanner.zig",
        options,
        options.optimize,
    );
    const run_security_scan = b.addRunArtifact(security_scan_exe);
    if (b.args) |args| run_security_scan.addArgs(args);
    ci_security_step.dependOn(&run_security_scan.step);

    const ci_matrix_step = b.step("ci-matrix", "Cross-platform matrix testing");
    ci_matrix_step.dependOn(fmt_step);
    ci_matrix_step.dependOn(tidy_step);
    ci_matrix_step.dependOn(test_all_step);

    const ci_setup_step = b.step("ci-setup", "Development environment setup");
    const setup_exe = create_tool_executable(
        b,
        "ci-setup",
        "src/dev/ci/setup_runner.zig",
        options,
        options.optimize,
    );
    const run_setup = b.addRunArtifact(setup_exe);
    if (b.args) |args| run_setup.addArgs(args);
    ci_setup_step.dependOn(&run_setup.step);

    const hooks_install_step = b.step("hooks-install", "Install git hooks");
    const hooks_install_cmd = b.addSystemCommand(
        &.{ "sh", "-c", "mkdir -p .git/hooks && cp .githooks/* .git/hooks/ && chmod +x .git/hooks/* && echo 'Git hooks installed'" },
    );
    hooks_install_step.dependOn(&hooks_install_cmd.step);

    const hooks_uninstall_step = b.step("hooks-uninstall", "Remove git hooks");
    const hooks_uninstall_cmd = b.addSystemCommand(
        &.{ "sh", "-c", "rm -f .git/hooks/pre-commit .git/hooks/commit-msg .git/hooks/pre-push && echo 'Git hooks removed'" },
    );
    hooks_uninstall_step.dependOn(&hooks_uninstall_cmd.step);
}
