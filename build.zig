const std = @import("std");
const builtin = @import("builtin");

const zig_version = std.SemanticVersion{
    .major = 0,
    .minor = 15,
    .patch = 1,
};

comptime {
    const version_matches = zig_version.major == builtin.zig_version.major and
        zig_version.minor == builtin.zig_version.minor and
        zig_version.patch == builtin.zig_version.patch;

    if (!version_matches) {
        @compileError(std.fmt.comptimePrint(
            "KausalDB requires exact Zig version {}, found {}. Run: ./scripts/install_zig.sh",
            .{ zig_version, builtin.zig_version },
        ));
    }
}

const BuildOptions = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: *std.Build.Step.Options,
};

const TestOptions = struct {
    seed: ?u64,
    filter: ?[]const u8,
    iterations: u32,
};

const DevOptions = struct {
    fuzz_iterations: u32,
    fuzz_corpus: []const u8,
    bench_iterations: u32,
    bench_warmup: u32,
    bench_baseline: ?[]const u8,
};

pub fn build(b: *std.Build) void {
    const target = resolve_target(b);
    const optimize = b.standardOptimizeOption(.{});

    // Deterministic seeds enable reproducible test failures across CI runs.
    const test_seed_str = b.option([]const u8, "seed", "Test seed (hex or decimal)");
    const test_seed: ?u64 = if (test_seed_str) |str| blk: {
        if (std.mem.startsWith(u8, str, "0x") or std.mem.startsWith(u8, str, "0X")) {
            break :blk std.fmt.parseInt(u64, str[2..], 16) catch
                std.debug.panic("Invalid hex seed format. Use: 0xDEADBEEF", .{});
        } else {
            break :blk std.fmt.parseInt(u64, str, 10) catch
                std.debug.panic("Invalid decimal seed format. Use: 123456", .{});
        }
    } else null;

    const test_options = TestOptions{
        .seed = test_seed,
        .filter = b.option([]const u8, "filter", "Filter tests by name"),
        .iterations = b.option(u32, "test-iterations", "Number of test iterations") orelse 1,
    };

    const dev_options = DevOptions{
        .fuzz_iterations = b.option(u32, "fuzz-iterations", "Fuzzing iterations") orelse 10000,
        .fuzz_corpus = b.option([]const u8, "fuzz-corpus", "Fuzzing corpus directory") orelse "fuzz-corpus",
        .bench_iterations = b.option(u32, "bench-iterations", "Benchmark iterations") orelse 1000,
        .bench_warmup = b.option(u32, "bench-warmup", "Benchmark warmup iterations") orelse 100,
        .bench_baseline = b.option([]const u8, "bench-baseline", "Baseline results for comparison"),
    };

    const options = b.addOptions();
    options.addOption(std.builtin.OptimizeMode, "optimize", optimize);
    options.addOption(?u64, "test_seed", test_options.seed);
    options.addOption(?[]const u8, "test_filter", test_options.filter);
    options.addOption(u32, "test_iterations", test_options.iterations);
    options.addOption(u32, "bench_iterations", dev_options.bench_iterations);
    options.addOption(u32, "bench_warmup", dev_options.bench_warmup);
    options.addOption(?[]const u8, "bench_baseline", dev_options.bench_baseline);
    options.addOption(u32, "fuzz_iterations", dev_options.fuzz_iterations);
    options.addOption([]const u8, "fuzz_corpus", dev_options.fuzz_corpus);

    const build_options = BuildOptions{
        .b = b,
        .target = target,
        .optimize = optimize,
        .options = options,
    };

    // Core build targets - the essential functionality
    build_executable(build_options);
    build_tests(build_options, test_options);
    build_dev_tools(build_options, dev_options);
    build_ci_targets(build_options);
}

fn resolve_target(b: *std.Build) std.Build.ResolvedTarget {
    var target = b.standardTargetOptions(.{});

    // Enable CPU features for consistent performance across builds
    if (target.result.cpu.arch == .x86_64) {
        // SSE4.2 for string operations
        target.result.cpu.features.addFeature(@intFromEnum(std.Target.x86.Feature.sse4_2));
        // POPCNT for bit manipulation
        target.result.cpu.features.addFeature(@intFromEnum(std.Target.x86.Feature.popcnt));
        // CRC32 for checksums
        target.result.cpu.features.addFeature(@intFromEnum(std.Target.x86.Feature.crc32));
        // AVX2 for SIMD operations if available
        const no_avx2 = b.option(bool, "no-avx2", "Disable AVX2") orelse false;
        if (!no_avx2) {
            target.result.cpu.features.addFeature(@intFromEnum(std.Target.x86.Feature.avx2));
        }
    } else if (target.result.cpu.arch == .aarch64) {
        // Enable NEON and crypto extensions for ARM64
        target.result.cpu.features.addFeature(@intFromEnum(std.Target.aarch64.Feature.neon));
        target.result.cpu.features.addFeature(@intFromEnum(std.Target.aarch64.Feature.crypto));
    }

    return target;
}

fn build_executable(build_options: BuildOptions) void {
    const exe = build_options.b.addExecutable(.{
        .name = "kausaldb",
        .root_module = build_options.b.createModule(.{
            .root_source_file = build_options.b.path("src/main.zig"),
            .target = build_options.target,
            .optimize = build_options.optimize,
        }),
    });

    exe.root_module.addImport("build_options", build_options.options.createModule());
    add_internal_module(exe.root_module, build_options);

    build_options.b.installArtifact(exe);

    const run_cmd = build_options.b.addRunArtifact(exe);
    run_cmd.step.dependOn(build_options.b.getInstallStep());
    if (build_options.b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = build_options.b.step("run", "Run the KausalDB server");
    run_step.dependOn(&run_cmd.step);
}

fn build_tests(build_options: BuildOptions, test_options: TestOptions) void {
    const unit_tests = build_test_artifact(build_options, "src/unit_tests.zig", "unit-tests");
    const unit_run = build_test_runner(build_options, unit_tests, test_options);
    const unit_step = build_options.b.step("test-unit", "Run unit tests");
    unit_step.dependOn(&unit_run.step);

    const integration_tests = build_test_artifact(build_options, "src/integration_tests.zig", "integration-tests");
    const integration_run = build_test_runner(build_options, integration_tests, test_options);
    const integration_step = build_options.b.step("test-integration", "Run integration tests");
    integration_step.dependOn(&integration_run.step);

    const e2e_tests = build_test_artifact(build_options, "tests/e2e_tests.zig", "e2e-tests");
    const e2e_run = build_test_runner(build_options, e2e_tests, test_options);
    const e2e_step = build_options.b.step("test-e2e", "Run end-to-end tests");
    e2e_step.dependOn(&e2e_run.step);

    const test_fast = build_options.b.step("test", "Run fast test suite (unit + integration)");
    test_fast.dependOn(&unit_run.step);
    test_fast.dependOn(&integration_run.step);

    const test_all = build_options.b.step("test-all", "Run complete test suite");
    test_all.dependOn(&unit_run.step);
    test_all.dependOn(&integration_run.step);
    test_all.dependOn(&e2e_run.step);
}

fn build_dev_tools(build_options: BuildOptions, options: DevOptions) void {
    build_benchmarks(build_options, options);
    build_fuzzer(build_options, options);
    build_tidy(build_options);
    build_git_hooks(build_options);
}

fn build_benchmarks(build_options: BuildOptions, _: DevOptions) void {
    const bench_exe = build_options.b.addExecutable(.{
        .name = "bench",
        .root_module = build_options.b.createModule(.{
            .root_source_file = build_options.b.path("src/bench/main.zig"),
            .target = build_options.target,
            .optimize = .ReleaseFast,
        }),
    });

    bench_exe.root_module.addImport("build_options", build_options.options.createModule());
    add_internal_module(bench_exe.root_module, build_options);

    const bench_run = build_options.b.addRunArtifact(bench_exe);

    // Allow component selection via command line args
    if (build_options.b.args) |args| {
        bench_run.addArgs(args);
    }

    const bench_step = build_options.b.step("bench", "Run performance benchmarks");
    bench_step.dependOn(&bench_run.step);
}

fn build_fuzzer(build_options: BuildOptions, dev_options: DevOptions) void {
    const fuzz_exe = build_options.b.addExecutable(.{
        .name = "fuzz",
        .root_module = build_options.b.createModule(.{
            .root_source_file = build_options.b.path("src/fuzz/main.zig"),
            .target = build_options.target,
            .optimize = .ReleaseFast,
        }),
    });

    // Use ReleaseFast for speed but enables sanitizers
    fuzz_exe.root_module.sanitize_c = .full;

    fuzz_exe.root_module.addImport("build_options", build_options.options.createModule());
    add_internal_module(fuzz_exe.root_module, build_options);

    const fuzz_run = build_options.b.addRunArtifact(fuzz_exe);

    // Allow target selection via command line args
    if (build_options.b.args) |args| {
        fuzz_run.addArgs(args);
    }

    const fuzz_step = build_options.b.step("fuzz", "Run fuzz testing");
    fuzz_step.dependOn(&fuzz_run.step);

    // Create a separate build options for fuzz-quick with 1000 iterations
    const quick_options = build_options.b.addOptions();
    quick_options.addOption(u32, "fuzz_iterations", 1000);
    quick_options.addOption([]const u8, "fuzz_corpus", dev_options.fuzz_corpus);

    const quick_exe = build_options.b.addExecutable(.{
        .name = "fuzz-quick",
        .root_module = build_options.b.createModule(.{
            .root_source_file = build_options.b.path("src/fuzz/main.zig"),
            .target = build_options.target,
            .optimize = .ReleaseFast,
        }),
    });

    quick_exe.root_module.sanitize_c = .full;
    quick_exe.root_module.addImport("build_options", quick_options.createModule());
    add_internal_module(quick_exe.root_module, build_options);

    const quick_run = build_options.b.addRunArtifact(quick_exe);
    if (build_options.b.args) |args| {
        quick_run.addArgs(args);
    }

    const fuzz_quick_step = build_options.b.step("fuzz-quick", "Run quick fuzz test (1000 iterations)");
    fuzz_quick_step.dependOn(&quick_run.step);
}

fn build_tidy(build_options: BuildOptions) void {
    const fmt_paths = [_][]const u8{ "src", "tests", "build.zig" };

    const fmt_step = build_options.b.step("fmt", "Format all source code");
    const fmt_run = build_options.b.addFmt(.{
        .paths = &fmt_paths,
        .check = false,
    });
    fmt_step.dependOn(&fmt_run.step);

    const fmt_check_step = build_options.b.step("fmt-check", "Check code formatting");
    const fmt_check = build_options.b.addFmt(.{
        .paths = &fmt_paths,
        .check = true,
    });
    fmt_check_step.dependOn(&fmt_check.step);

    const tidy_exe = build_options.b.addExecutable(.{
        .name = "tidy",
        .root_module = build_options.b.createModule(.{
            .root_source_file = build_options.b.path("src/dev/tidy.zig"),
            .target = build_options.target,
            .optimize = build_options.optimize,
        }),
    });

    tidy_exe.root_module.addImport("build_options", build_options.options.createModule());
    add_internal_module(tidy_exe.root_module, build_options);

    const tidy_run = build_options.b.addRunArtifact(tidy_exe);
    const tidy_step = build_options.b.step("tidy", "Check naming conventions and style rules");
    tidy_step.dependOn(&tidy_run.step);
}

fn build_git_hooks(build_options: BuildOptions) void {
    const hooks_exe = build_options.b.addExecutable(.{
        .name = "hooks",
        .root_module = build_options.b.createModule(.{
            .root_source_file = build_options.b.path("src/dev/hooks.zig"),
            .target = build_options.target,
            .optimize = build_options.optimize,
        }),
    });

    hooks_exe.root_module.addImport("build_options", build_options.options.createModule());
    add_internal_module(hooks_exe.root_module, build_options);

    const hooks_install = build_options.b.addRunArtifact(hooks_exe);
    hooks_install.addArg("install");
    const hooks_install_step = build_options.b.step("hooks-install", "Install git hooks");
    hooks_install_step.dependOn(&hooks_install.step);
}

fn build_ci_targets(build_options: BuildOptions) void {
    const lint_step = build_options.b.step("lint", "Run all linters and style checks");

    const fmt_check = build_options.b.addFmt(.{
        .paths = &[_][]const u8{ "src", "tests", "build.zig" },
        .check = true,
    });
    lint_step.dependOn(&fmt_check.step);

    const tidy_exe = build_options.b.addExecutable(.{
        .name = "lint-tidy",
        .root_module = build_options.b.createModule(.{
            .root_source_file = build_options.b.path("src/dev/tidy.zig"),
            .target = build_options.target,
            .optimize = build_options.optimize,
        }),
    });
    tidy_exe.root_module.addImport("build_options", build_options.options.createModule());
    add_internal_module(tidy_exe.root_module, build_options);

    const tidy_run = build_options.b.addRunArtifact(tidy_exe);
    lint_step.dependOn(&tidy_run.step);
}

fn add_internal_module(module: *std.Build.Module, build_options: BuildOptions) void {
    const internal_module = build_options.b.createModule(.{
        .root_source_file = build_options.b.path("src/internal.zig"),
        .target = build_options.target,
        .optimize = build_options.optimize,
    });
    internal_module.addImport("build_options", build_options.options.createModule());
    module.addImport("internal", internal_module);
}

fn build_test_artifact(build_options: BuildOptions, source_path: []const u8, name: []const u8) *std.Build.Step.Compile {
    const test_exe = build_options.b.addTest(.{
        .name = name,
        .root_module = build_options.b.createModule(.{
            .root_source_file = build_options.b.path(source_path),
            .target = build_options.target,
            .optimize = build_options.optimize,
        }),
    });

    test_exe.root_module.addImport("build_options", build_options.options.createModule());
    add_internal_module(test_exe.root_module, build_options);

    return test_exe;
}

fn build_test_runner(
    build_options: BuildOptions,
    test_exe: *std.Build.Step.Compile,
    test_options: TestOptions,
) *std.Build.Step.Run {
    const run = build_options.b.addRunArtifact(test_exe);
    if (test_options.filter) |filter| {
        run.addArg("--test-filter");
        run.addArg(filter);
    }
    return run;
}
