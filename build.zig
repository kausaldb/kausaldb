const std = @import("std");

const TestType = enum {
    unit,
    integration,
    e2e,

    fn description(self: TestType) []const u8 {
        return switch (self) {
            .unit => "unit tests from source modules",
            .integration => "integration tests with full API access",
            .e2e => "end-to-end binary interface tests",
        };
    }
};

fn component_needs_libc(name: []const u8) bool {
    const libc_components = [_][]const u8{
        "unit",
        "server_lifecycle",
        "integration_lifecycle",
        "integration_server_coordinator",
        "performance",
        "benchmark",
    };

    for (libc_components) |component| {
        if (std.mem.eql(u8, name, component)) return true;
    }
    return false;
}

const BuildModules = struct {
    kausaldb: *std.Build.Module,
    kausaldb_test: *std.Build.Module,
    build_options: *std.Build.Module,
    enable_thread_sanitizer: bool,
    enable_ubsan: bool,
    debug_tests: bool,
};

fn create_build_modules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) BuildModules {
    const enable_statistics = b.option(bool, "enable-stats", "Enable runtime statistics collection") orelse false;
    const enable_detailed_logging = b.option(bool, "enable-detailed-logs", "Enable detailed debug logging") orelse false;
    const enable_fault_injection = b.option(bool, "enable-fault-injection", "Enable fault injection testing") orelse false;
    const enable_thread_sanitizer = b.option(bool, "enable-thread-sanitizer", "Enable Thread Sanitizer") orelse false;
    const enable_ubsan = b.option(bool, "enable-ubsan", "Enable Undefined Behavior Sanitizer") orelse false;
    const enable_memory_guard = b.option(bool, "enable-memory-guard", "Enable memory guard for corruption detection") orelse false;
    const debug_tests = b.option(bool, "debug", "Enable debug test output (verbose logging and demo content)") orelse false;

    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_statistics", enable_statistics);
    build_options.addOption(bool, "enable_detailed_logging", enable_detailed_logging);
    build_options.addOption(bool, "enable_fault_injection", enable_fault_injection);
    build_options.addOption(bool, "enable_memory_guard", enable_memory_guard);

    const kausaldb_module = b.createModule(.{
        .root_source_file = b.path("src/kausaldb.zig"),
        .target = target,
        .optimize = optimize,
    });
    kausaldb_module.addImport("build_options", build_options.createModule());

    const kausaldb_test_module = b.createModule(.{
        .root_source_file = b.path("src/testing_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    kausaldb_test_module.addImport("build_options", build_options.createModule());

    return .{
        .kausaldb = kausaldb_module,
        .kausaldb_test = kausaldb_test_module,
        .build_options = build_options.createModule(),
        .enable_thread_sanitizer = enable_thread_sanitizer,
        .enable_ubsan = enable_ubsan,
        .debug_tests = debug_tests,
    };
}

const TestFile = struct {
    path: []const u8,
    name: []const u8,
    test_type: TestType,
};

fn discover_integration_tests(allocator: std.mem.Allocator) !std.ArrayList(TestFile) {
    var discovered_tests = std.ArrayList(TestFile){};

    // Discover integration tests in src/tests/
    var src_tests_dir = std.fs.cwd().openDir("src/tests", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return discovered_tests,
        else => return err,
    };
    defer src_tests_dir.close();

    var walker = try src_tests_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        if (std.mem.eql(u8, entry.basename, "harness.zig")) continue; // Skip harness framework

        const full_path = try std.fmt.allocPrint(allocator, "src/tests/{s}", .{entry.path});
        const test_name = try generate_test_name(allocator, entry.path);

        try discovered_tests.append(allocator, .{
            .path = full_path,
            .name = test_name,
            .test_type = .integration,
        });
    }

    return discovered_tests;
}

fn discover_e2e_tests(allocator: std.mem.Allocator) !std.ArrayList(TestFile) {
    var discovered_tests = std.ArrayList(TestFile){};

    // Discover E2E tests in tests/
    var tests_dir = std.fs.cwd().openDir("tests", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return discovered_tests,
        else => return err,
    };
    defer tests_dir.close();

    var walker = try tests_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;

        const full_path = try std.fmt.allocPrint(allocator, "tests/{s}", .{entry.path});
        const test_name = try generate_test_name(allocator, entry.path);

        try discovered_tests.append(allocator, .{
            .path = full_path,
            .name = test_name,
            .test_type = .e2e,
        });
    }

    return discovered_tests;
}

fn generate_test_name(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var name_buf: [256]u8 = undefined;
    var name_len: usize = 0;

    var path_parts = std.mem.splitSequence(u8, path, "/");
    var is_first = true;
    while (path_parts.next()) |part| {
        if (std.mem.endsWith(u8, part, ".zig")) {
            const basename = part[0 .. part.len - 4];
            if (!is_first) {
                name_buf[name_len] = '_';
                name_len += 1;
            }
            @memcpy(name_buf[name_len .. name_len + basename.len], basename);
            name_len += basename.len;
        } else {
            if (!is_first) {
                name_buf[name_len] = '_';
                name_len += 1;
            }
            @memcpy(name_buf[name_len .. name_len + part.len], part);
            name_len += part.len;
        }
        is_first = false;
    }

    return allocator.dupe(u8, name_buf[0..name_len]);
}

fn create_test_executable(
    b: *std.Build,
    test_file: TestFile,
    modules: BuildModules,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const test_exe = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(test_file.path),
            .target = target,
            .optimize = optimize,
        }),
    });

    if (component_needs_libc(test_file.name)) {
        test_exe.linkLibC();
    }

    // Apply sanitizer flags
    if (modules.enable_thread_sanitizer) {
        test_exe.root_module.sanitize_thread = true;
    }
    if (modules.enable_ubsan) {
        test_exe.root_module.sanitize_c = .full;
    }

    // Choose appropriate module based on test type
    const kausaldb_module = switch (test_file.test_type) {
        .unit => modules.kausaldb,
        .integration => modules.kausaldb_test, // Full API access
        .e2e => modules.kausaldb, // Public API only
    };

    test_exe.root_module.addImport("kausaldb", kausaldb_module);
    test_exe.root_module.addImport("build_options", modules.build_options);

    // Create test-specific build options
    const test_options = b.addOptions();
    test_options.addOption(bool, "debug_tests", modules.debug_tests);

    // Set appropriate log level for test type
    const log_level: std.log.Level = if (modules.debug_tests) .debug else switch (test_file.test_type) {
        .unit => .warn,
        .integration => .warn,
        .e2e => .err, // E2E tests should be quieter
    };
    test_options.addOption(std.log.Level, "test_log_level", log_level);
    test_exe.root_module.addImport("test_build_options", test_options.createModule());

    return test_exe;
}

const TestSuite = struct {
    unit: std.ArrayList(*std.Build.Step.Run),
    integration: std.ArrayList(*std.Build.Step.Run),
    e2e: std.ArrayList(*std.Build.Step.Run),

    fn init(allocator: std.mem.Allocator) TestSuite {
        _ = allocator;
        return TestSuite{
            .unit = std.ArrayList(*std.Build.Step.Run){},
            .integration = std.ArrayList(*std.Build.Step.Run){},
            .e2e = std.ArrayList(*std.Build.Step.Run){},
        };
    }

    fn get_tests(self: *TestSuite, test_type: TestType) *std.ArrayList(*std.Build.Step.Run) {
        return switch (test_type) {
            .unit => &self.unit,
            .integration => &self.integration,
            .e2e => &self.e2e,
        };
    }
};

fn create_test_suite(
    b: *std.Build,
    modules: BuildModules,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    allocator: std.mem.Allocator,
) !TestSuite {
    var suite = TestSuite.init(allocator);

    // Add unit test runner (built-in source tests)
    const unit_test_exe = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unit_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_test_exe.linkLibC();

    if (modules.enable_thread_sanitizer) {
        unit_test_exe.root_module.sanitize_thread = true;
    }
    if (modules.enable_ubsan) {
        unit_test_exe.root_module.sanitize_c = .full;
    }

    unit_test_exe.root_module.addImport("build_options", modules.build_options);
    // unit_test_exe.root_module.addImport("kausaldb", modules.kausaldb); // Disabled to avoid module conflicts

    const unit_run = b.addRunArtifact(unit_test_exe);
    unit_run.has_side_effects = true;
    try suite.unit.append(allocator, unit_run);

    // Add integration tests
    var integration_tests = try discover_integration_tests(allocator);
    defer integration_tests.deinit(allocator);

    for (integration_tests.items) |test_file| {
        const test_exe = create_test_executable(b, test_file, modules, target, optimize);
        const test_run = b.addRunArtifact(test_exe);
        test_run.has_side_effects = true;
        try suite.integration.append(allocator, test_run);
    }

    // Add E2E tests
    var e2e_tests = try discover_e2e_tests(allocator);
    defer e2e_tests.deinit(allocator);

    for (e2e_tests.items) |test_file| {
        const test_exe = create_test_executable(b, test_file, modules, target, optimize);
        const test_run = b.addRunArtifact(test_exe);
        test_run.has_side_effects = true;
        try suite.e2e.append(allocator, test_run);
    }

    return suite;
}

fn create_workflow_steps(b: *std.Build, suite: TestSuite) void {
    // Primary test commands
    const test_step = b.step("test", "Run unit tests");
    for (suite.unit.items) |test_run| {
        test_step.dependOn(&test_run.step);
    }

    const test_integration_step = b.step("test-integration", "Run integration tests");
    for (suite.integration.items) |test_run| {
        test_integration_step.dependOn(&test_run.step);
    }

    const test_e2e_step = b.step("test-e2e", "Run end-to-end tests");
    for (suite.e2e.items) |test_run| {
        test_e2e_step.dependOn(&test_run.step);
    }

    // Aggregate workflows
    const test_fast_step = b.step("test-fast", "Run core tests (unit + integration)");
    test_fast_step.dependOn(test_step);
    test_fast_step.dependOn(test_integration_step);

    const test_all_step = b.step("test-all", "Run all tests");
    test_all_step.dependOn(test_fast_step);
    test_all_step.dependOn(test_e2e_step);

    // Code quality steps
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

    // CI step
    const ci_step = b.step("ci", "Run all CI checks");
    ci_step.dependOn(test_fast_step);
    ci_step.dependOn(fmt_step);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const modules = create_build_modules(b, target, optimize);

    // Main executable
    const exe = b.addExecutable(.{
        .name = "kausaldb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.linkLibC();
    exe.root_module.addImport("kausaldb", modules.kausaldb);
    exe.root_module.addImport("build_options", modules.build_options);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Create test suite
    const suite = create_test_suite(b, modules, target, optimize, arena_allocator) catch |err| {
        std.debug.print("Failed to create test suite: {}\n", .{err});
        return;
    };

    // Create workflow steps
    create_workflow_steps(b, suite);

    // Benchmark executable
    const benchmark_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmark.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    benchmark_exe.linkLibC();
    benchmark_exe.root_module.addImport("kausaldb", modules.kausaldb);
    benchmark_exe.root_module.addImport("build_options", modules.build_options);
    b.installArtifact(benchmark_exe);

    const benchmark_cmd = b.addRunArtifact(benchmark_exe);
    if (b.args) |args| {
        benchmark_cmd.addArgs(args);
    }
    const benchmark_step = b.step("benchmark", "Run performance benchmarks");
    benchmark_step.dependOn(&benchmark_cmd.step);
}
