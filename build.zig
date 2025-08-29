const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add test filter option
    const test_filter = b.option([]const u8, "test-filter", "Filter tests by name pattern");

    // Build options for conditional compilation
    const build_options = b.addOptions();
    build_options.addOption(bool, "debug_tests", optimize == .Debug);
    build_options.addOption(bool, "sanitizers_active", false);

    // Core kausaldb module
    const kausaldb_module = b.createModule(.{
        .root_source_file = b.path("src/kausaldb.zig"),
        .target = target,
        .optimize = optimize,
    });
    kausaldb_module.addImport("build_options", build_options.createModule());

    // Internal API module for dev tools
    const internal_module = b.createModule(.{
        .root_source_file = b.path("src/internal.zig"),
        .target = target,
        .optimize = optimize,
    });
    internal_module.addImport("build_options", build_options.createModule());

    // === MAIN EXECUTABLE ===
    const exe = b.addExecutable(.{
        .name = "kausaldb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.linkLibC();
    exe.root_module.addImport("kausaldb", kausaldb_module);
    exe.root_module.addImport("build_options", build_options.createModule());
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run kausaldb server");
    run_step.dependOn(&run_cmd.step);

    // === TESTS ===

    // Unit tests - all tests embedded in source files
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unit_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addImport("build_options", build_options.createModule());
    unit_tests.linkLibC();

    // Create test step that handles both filtered and unfiltered cases
    const test_step = b.step("test", "Run unit tests (use --test-filter=\"name\" to filter)");

    if (test_filter) |filter| {
        // Use direct zig test command when filter is provided
        const zig_test_cmd = b.addSystemCommand(&.{
            b.graph.zig_exe,
            "test",
            "src/unit_tests.zig",
            "--test-filter",
            filter,
        });

        // Add optimization flag
        const opt_flag = b.fmt("-Doptimize={s}", .{@tagName(optimize)});
        zig_test_cmd.addArg(opt_flag);

        // Set working directory and link libc
        zig_test_cmd.setCwd(.{ .cwd_relative = "." });
        zig_test_cmd.addArg("-lc");

        test_step.dependOn(&zig_test_cmd.step);
    } else {
        // Use compiled executable for normal test runs
        const run_unit_tests = b.addRunArtifact(unit_tests);
        if (b.args) |args| run_unit_tests.addArgs(args);
        test_step.dependOn(&run_unit_tests.step);
    }

    // Integration tests - using registry for automatic discovery
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/integration_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    integration_tests.root_module.addImport("build_options", build_options.createModule());
    integration_tests.linkLibC();

    // Create integration test step that handles both filtered and unfiltered cases
    const integration_step = b.step("test-integration", "Run integration tests (use --test-filter=\"name\" to filter)");

    if (test_filter) |filter| {
        // Use direct zig test command when filter is provided
        const zig_integration_cmd = b.addSystemCommand(&.{
            b.graph.zig_exe,
            "test",
            "src/integration_tests.zig",
            "--test-filter",
            filter,
        });

        // Add optimization flag
        const opt_flag = b.fmt("-Doptimize={s}", .{@tagName(optimize)});
        zig_integration_cmd.addArg(opt_flag);

        // Set working directory and link libc
        zig_integration_cmd.setCwd(.{ .cwd_relative = "." });
        zig_integration_cmd.addArg("-lc");

        integration_step.dependOn(&zig_integration_cmd.step);
    } else {
        // Use compiled executable for normal integration test runs
        const run_integration_tests = b.addRunArtifact(integration_tests);
        run_integration_tests.has_side_effects = true;
        if (b.args) |args| run_integration_tests.addArgs(args);
        integration_step.dependOn(&run_integration_tests.step);
    }

    // E2E tests - binary interface testing
    const e2e_step = b.step("test-e2e", "Run end-to-end tests");
    const e2e_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/e2e_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    e2e_test.root_module.addImport("build_options", build_options.createModule());
    e2e_test.linkLibC();

    const run_e2e_test = b.addRunArtifact(e2e_test);
    run_e2e_test.step.dependOn(&exe.step); // E2E tests need the binary
    run_e2e_test.has_side_effects = true;
    if (b.args) |args| run_e2e_test.addArgs(args);

    e2e_step.dependOn(&run_e2e_test.step);

    // Aggregate test commands
    const test_fast_step = b.step("test-fast", "Run fast tests (unit + integration, use --test-filter=\"name\" to filter)");
    test_fast_step.dependOn(test_step);
    test_fast_step.dependOn(integration_step);

    const test_all_step = b.step("test-all", "Run all tests (use --test-filter=\"name\" to filter unit/integration)");
    test_all_step.dependOn(test_fast_step);
    test_all_step.dependOn(e2e_step);

    // === TOOLS ===

    // Benchmark executable
    const benchmark_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dev/benchmark.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    benchmark_exe.linkLibC();
    benchmark_exe.root_module.addImport("build_options", build_options.createModule());
    benchmark_exe.root_module.addImport("internal", internal_module);
    b.installArtifact(benchmark_exe);

    const benchmark_cmd = b.addRunArtifact(benchmark_exe);
    if (b.args) |args| benchmark_cmd.addArgs(args);

    const benchmark_step = b.step("benchmark", "Run performance benchmarks");
    benchmark_step.dependOn(&benchmark_cmd.step);

    // Tidy executable
    const tidy_exe = b.addExecutable(.{
        .name = "tidy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dev/tidy/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tidy_exe.root_module.addImport("build_options", build_options.createModule());
    tidy_exe.root_module.addImport("internal", internal_module);
    b.installArtifact(tidy_exe);

    const tidy_cmd = b.addRunArtifact(tidy_exe);
    if (b.args) |args| tidy_cmd.addArgs(args);

    const tidy_step = b.step("tidy", "Run code quality checks");
    tidy_step.dependOn(&tidy_cmd.step);

    // Fuzz executable
    const fuzz_exe = b.addExecutable(.{
        .name = "fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dev/fuzz/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    fuzz_exe.root_module.addImport("build_options", build_options.createModule());
    fuzz_exe.root_module.addImport("internal", internal_module);
    b.installArtifact(fuzz_exe);

    const fuzz_cmd = b.addRunArtifact(fuzz_exe);
    if (b.args) |args| fuzz_cmd.addArgs(args);

    const fuzz_step = b.step("fuzz", "Run fuzz testing");
    fuzz_step.dependOn(&fuzz_cmd.step);

    // Commit message validator executable
    const commit_msg_validator_exe = b.addExecutable(.{
        .name = "commit-msg-validator",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dev/commit_msg_validator.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    commit_msg_validator_exe.root_module.addImport("build_options", build_options.createModule());
    b.installArtifact(commit_msg_validator_exe);

    const commit_msg_validator_step = b.step("commit-msg-validator", "Build commit message validator");
    commit_msg_validator_step.dependOn(&b.addInstallArtifact(commit_msg_validator_exe, .{}).step);

    // === INDIVIDUAL TEST TARGETS ===

    // Quick access to run just unit tests (no integration tests)
    const unit_only_step = b.step("test-unit-only", "Run only unit tests (fast)");
    unit_only_step.dependOn(test_step);

    // Quick access to run just integration tests
    const integration_only_step = b.step("test-integration-only", "Run only integration tests");
    integration_only_step.dependOn(integration_step);

    // === CODE QUALITY ===

    // Format check
    const fmt_check = b.addFmt(.{
        .paths = &.{ "src", "tests", "build.zig" },
        .check = true,
    });
    const fmt_step = b.step("fmt", "Check code formatting");
    fmt_step.dependOn(&fmt_check.step);

    // Format fix
    const fmt_fix = b.addFmt(.{
        .paths = &.{ "src", "tests", "build.zig" },
        .check = false,
    });
    const fmt_fix_step = b.step("fmt-fix", "Fix code formatting");
    fmt_fix_step.dependOn(&fmt_fix.step);

    // CI pipeline - the absolute truth
    const ci_step = b.step("ci", "Run complete CI pipeline");
    ci_step.dependOn(fmt_step);
    ci_step.dependOn(tidy_step);
    ci_step.dependOn(test_fast_step);
    ci_step.dependOn(e2e_step);
}
