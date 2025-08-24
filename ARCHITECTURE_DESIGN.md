# KausalDB Architecture Design v0.1.0

**Vision**: Production-grade database with microsecond latency, zero crashes, and deterministic behavior under hostile conditions.

**Philosophy**: Simplicity is the prerequisite for reliability. Every abstraction must have zero runtime cost. Explicitness over magic.

## Executive Summary

KausalDB requires architectural reform to achieve 0.1.0 production readiness. Current issues include memory leaks, WAL corruption patterns, and test architecture pollution. This document defines the optimal architecture to eliminate these issues while maintaining microsecond performance targets.

## Core Architecture Principles

### 1. Memory Safety Through Architectural Constraints

**Problem**: Dynamic data conflicts with static memory models, causing corruption despite arena patterns.

**Solution**: Three-tier memory hierarchy with ownership validation.

```zig
// Tier 1: Static Arena Coordinators (never move)
pub const StorageEngine = struct {
    backing_allocator: Allocator,
    storage_arena: ArenaAllocator,
    coordinator: *ArenaCoordinator,  // Stable pointer, never copied

    pub fn init(backing: Allocator) !StorageEngine {
        var arena = ArenaAllocator.init(backing);
        var coordinator = try backing.create(ArenaCoordinator);
        coordinator.* = ArenaCoordinator{ .arena = &arena };
        return .{
            .backing_allocator = backing,
            .storage_arena = arena,
            .coordinator = coordinator,
        };
    }
};

// Tier 2: Coordinator Interfaces (copyable, reference stable coordinator)
pub const MemtableManager = struct {
    coordinator: *ArenaCoordinator,  // Reference to stable coordinator

    pub fn init(coordinator: *ArenaCoordinator) MemtableManager {
        return .{ .coordinator = coordinator };
    }
};

// Tier 3: Pure Computation (no memory management)
pub const BlockIndex = struct {
    blocks: std.HashMap(BlockId, ContextBlock, BlockHashContext, std.hash_map.default_max_load_percentage),

    // No allocator, no memory management - pure computation
    pub fn find_block(self: *const BlockIndex, id: BlockId) ?ContextBlock {
        return self.blocks.get(id);
    }
};
```

**Enforcement Rules**:
1. Only Tier 1 owns ArenaAllocators
2. Tier 2 receives coordinator pointers (never copy)
3. Tier 3 performs pure computation
4. All memory operations go through coordinators
5. Debug builds validate ownership chains

### 2. Defensive Programming Framework

**Current Issue**: Memory corruption occurs despite defensive measures.

**Solution**: Systematic defense in depth with compile-time elimination.

```zig
// src/core/defensive.zig
pub const Defense = struct {
    // Level 1: Compile-time validation (zero cost)
    pub fn comptime_assert(comptime condition: bool, comptime message: []const u8) void {
        if (!condition) @compileError(message);
    }

    // Level 2: Debug-only runtime checks
    pub fn debug_assert(condition: bool, message: []const u8, args: anytype) void {
        if (builtin.mode == .Debug) {
            if (!condition) {
                log.err(message, args);
                @panic("Debug assertion failed");
            }
        }
    }

    // Level 3: Always-active safety checks
    pub fn fatal_assert(condition: bool, message: []const u8, args: anytype) void {
        if (!condition) {
            log.err("FATAL: " ++ message, args);
            @panic("Safety violation detected");
        }
    }

    // Level 4: Memory guard integration
    pub fn validate_pointer(ptr: anytype, context: []const u8) void {
        if (builtin.mode == .Debug) {
            memory_guard.validate_allocation(ptr, context);
        }
    }
};

// Usage pattern enforces correct defense level
pub fn find_block_with_ownership(self: *StorageEngine, id: BlockId, ownership: BlockOwnership) !?OwnedContextBlock {
    Defense.comptime_assert(@TypeOf(id) == BlockId, "Invalid block ID type");
    Defense.debug_assert(id != 0, "Block ID cannot be zero: {}", .{id});
    Defense.fatal_assert(self.coordinator != null, "Coordinator cannot be null", .{});

    // ... implementation
}
```

### 3. Test Architecture: Three-Tier Isolation

**Current Issue**: Test pollution makes individual test runs impossible.

**Solution**: Clean separation with proper module boundaries.

```
kausaldb/
├── src/                           # Production code
│   ├── tests/                     # Internal integration tests (API access)
│   │   ├── harness.zig           # Shared test infrastructure
│   │   ├── storage/              # Storage subsystem tests
│   │   ├── query/                # Query subsystem tests
│   │   └── simulation/           # Fault injection tests
│   └── unit_tests.zig            # Unit test registry
├── tests/                         # External E2E tests (binary only)
│   ├── cli/                      # CLI interface tests
│   ├── server/                   # Server protocol tests
│   └── regression/               # Performance regression tests
└── tools/                         # Development tools
    ├── dev.zig                   # Unified developer workflow
    ├── test_runner.zig           # Custom test execution
    └── ci.zig                    # CI pipeline simulation
```

**Test Harness Standard**:

```zig
// src/tests/harness.zig - Single source of truth for all test infrastructure
pub const TestHarness = struct {
    allocator: Allocator,
    name: []const u8,
    arena: ArenaAllocator,
    memory_guard: ?MemoryGuard,

    pub fn init(allocator: Allocator, name: []const u8, enable_memory_guard: bool) !TestHarness {
        var arena = ArenaAllocator.init(allocator);
        var guard: ?MemoryGuard = null;

        if (enable_memory_guard and builtin.mode == .Debug) {
            guard = try MemoryGuard.init(allocator);
        }

        return TestHarness{
            .allocator = if (guard) |g| g.allocator() else allocator,
            .name = name,
            .arena = arena,
            .memory_guard = guard,
        };
    }

    pub fn deinit(self: *TestHarness) void {
        self.arena.deinit();
        if (self.memory_guard) |*guard| {
            guard.deinit(); // Reports leaks automatically
        }
    }

    pub fn generate_block(self: *TestHarness, id: u32) !ContextBlock {
        // Centralized test data generation
        const content = try std.fmt.allocPrint(self.allocator, "test content {}", .{id});
        return ContextBlock{
            .id = BlockId.from_u128(@intCast(id)),
            .source_uri = "test://block",
            .content = content,
            .metadata_json = "{}",
        };
    }
};
```

### 4. Build System: Developer-Centric Design

**Current Issue**: Complex build system makes development workflows difficult.

**Solution**: Unified tool with smart defaults and flexible filtering.

```zig
// tools/dev.zig - Single entry point for all development tasks
const Command = union(enum) {
    test: TestOptions,
    check: CheckOptions,
    bench: BenchmarkOptions,
    ci: CIOptions,

    const TestOptions = struct {
        filter: ?[]const u8 = null,
        safety: bool = false,
        iterations: u32 = 1,
        verbose: bool = false,
    };
};

pub fn main() !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const command = try parseCommand(args);

    switch (command) {
        .test => |opts| try runTests(opts),
        .check => |opts| try runChecks(opts),
        .bench => |opts| try runBenchmarks(opts),
        .ci => |opts| try runCI(opts),
    }
}

fn runTests(opts: TestOptions) !void {
    // Smart test discovery and execution
    var builder = TestBuilder.init(allocator);
    defer builder.deinit();

    // Add unit tests (always fast)
    try builder.add_unit_tests();

    // Add integration tests based on filter
    if (opts.filter) |filter| {
        try builder.add_integration_tests_matching(filter);
    } else {
        try builder.add_integration_tests();
    }

    // Configure safety options
    if (opts.safety) {
        try builder.enable_memory_guard();
    }

    // Execute with proper isolation
    const results = try builder.execute_with_isolation();
    try report_results(results);
}
```

**Usage Examples**:
```bash
# Fast development workflow
./zig/zig run tools/dev.zig -- test                    # Unit + fast integration
./zig/zig run tools/dev.zig -- test --filter storage   # Storage tests only
./zig/zig run tools/dev.zig -- test --safety           # Enable memory guard

# Code quality
./zig/zig run tools/dev.zig -- check                   # Format + tidy + compile
./zig/zig run tools/dev.zig -- check --fix             # Auto-fix violations

# Performance validation
./zig/zig run tools/dev.zig -- bench                   # All benchmarks
./zig/zig run tools/dev.zig -- bench block-write       # Specific benchmark

# CI simulation
./zig/zig run tools/dev.zig -- ci                      # Full CI pipeline locally
```

### 5. Memory Corruption Elimination

**Root Cause Analysis**: Current leaks occur in ownership cloning operations.

**Solution**: Ownership validation with automatic cleanup tracking.

```zig
// src/core/ownership.zig - Reformed ownership system
pub const OwnedContextBlock = struct {
    block: ContextBlock,
    ownership: BlockOwnership,
    allocator: Allocator,
    cleanup_tracker: ?*CleanupTracker,

    pub fn clone_with_ownership(
        self: *const OwnedContextBlock,
        target_allocator: Allocator,
        target_ownership: BlockOwnership,
        tracker: ?*CleanupTracker
    ) !OwnedContextBlock {
        // Track allocation before performing it
        if (tracker) |t| {
            try t.track_pending_allocation("clone_with_ownership");
        }

        const cloned_source_uri = try target_allocator.dupe(u8, self.block.source_uri);
        const cloned_metadata = try target_allocator.dupe(u8, self.block.metadata_json);
        const cloned_content = try target_allocator.dupe(u8, self.block.content);

        const result = OwnedContextBlock{
            .block = ContextBlock{
                .id = self.block.id,
                .source_uri = cloned_source_uri,
                .metadata_json = cloned_metadata,
                .content = cloned_content,
            },
            .ownership = target_ownership,
            .allocator = target_allocator,
            .cleanup_tracker = tracker,
        };

        // Register successful allocation
        if (tracker) |t| {
            try t.register_allocation(&result);
        }

        return result;
    }

    pub fn deinit(self: *OwnedContextBlock) void {
        // Unregister before cleanup
        if (self.cleanup_tracker) |tracker| {
            tracker.unregister_allocation(self);
        }

        self.allocator.free(self.block.source_uri);
        self.allocator.free(self.block.metadata_json);
        self.allocator.free(self.block.content);
        self.* = undefined; // Poison for use-after-free detection
    }
};

// Automatic cleanup tracking
pub const CleanupTracker = struct {
    allocations: std.ArrayList(*OwnedContextBlock),
    allocator: Allocator,

    pub fn cleanup_all(self: *CleanupTracker) void {
        for (self.allocations.items) |allocation| {
            allocation.deinit();
        }
        self.allocations.clearAndFree();
    }
};
```

### 6. Performance Architecture

**Target**: Maintain microsecond performance while adding safety.

**Strategy**: Zero-cost abstractions with debug-time validation.

```zig
// src/core/performance.zig
pub const PerformanceConstraints = struct {
    // Compile-time performance validation
    pub fn validate_hot_path(comptime function_name: []const u8) void {
        // Ensure no dynamic allocation in hot paths
        comptime {
            if (std.mem.indexOf(u8, function_name, "alloc") != null) {
                @compileError("Hot path " ++ function_name ++ " cannot allocate");
            }
        }
    }

    // Runtime performance monitoring (debug only)
    pub fn measure_operation(comptime name: []const u8, operation: anytype) @TypeOf(operation()) {
        if (builtin.mode == .Debug) {
            const start = std.time.nanoTimestamp();
            const result = operation();
            const end = std.time.nanoTimestamp();

            const duration_ns = @as(u64, @intCast(end - start));
            if (duration_ns > performance_thresholds.get(name)) {
                log.warn("Performance violation: {} took {}ns (threshold: {}ns)",
                    .{ name, duration_ns, performance_thresholds.get(name) });
            }

            return result;
        } else {
            return operation();
        }
    }
};

// Usage in hot paths
pub fn find_block_with_ownership(self: *StorageEngine, id: BlockId, ownership: BlockOwnership) !?OwnedContextBlock {
    PerformanceConstraints.validate_hot_path("find_block_with_ownership");

    return PerformanceConstraints.measure_operation("block_read", struct {
        fn op() !?OwnedContextBlock {
            // Implementation...
        }
    }.op);
}
```

## Implementation Roadmap

### Phase 1: Memory Architecture (1-2 days)

1. **Implement three-tier memory hierarchy**
   - Fix coordinator pointer stability
   - Add ownership validation
   - Implement cleanup tracking

2. **Eliminate current memory leaks**
   - Fix ownership cloning operations
   - Add automatic cleanup in test harness
   - Validate with memory guard system

3. **Commit**: `fix(memory): implement three-tier memory hierarchy with leak elimination`

### Phase 2: Test Architecture (1-2 days)

1. **Complete test migration**
   - Finish moving integration tests to src/tests/
   - Fix all import path issues
   - Update build system for clean separation

2. **Implement unified test harness**
   - Standard harness for all integration tests
   - Memory guard integration
   - Automatic cleanup tracking

3. **Commit**: `refactor(test): complete three-tier test architecture migration`

### Phase 3: Build System (1 day)

1. **Implement unified developer tool**
   - tools/dev.zig with smart test filtering
   - Cross-platform support
   - Local CI simulation

2. **Remove shell script dependencies**
   - Migrate all scripts to Zig
   - Simplify developer onboarding

3. **Commit**: `feat(tools): implement unified developer workflow system`

### Phase 4: Defensive Programming (1 day)

1. **Implement defense framework**
   - Four-tier assertion system
   - Compile-time validation
   - Memory guard integration

2. **Add systematic validation**
   - All public APIs get defensive checks
   - WAL corruption detection improvements
   - Edge case fuzzing integration

3. **Commit**: `feat(defense): implement systematic defensive programming framework`

### Phase 5: Performance Validation (1 day)

1. **Validate performance targets**
   - Benchmark all critical paths
   - Ensure zero-cost abstractions
   - Performance regression detection

2. **Production readiness**
   - Full CI pipeline validation
   - Memory safety validation
   - Documentation updates

3. **Commit**: `feat(perf): validate production performance targets for v0.1.0`

## Success Criteria

### Technical Metrics
- **Zero memory leaks** in all test scenarios
- **Zero WAL corruption** warnings in clean test runs
- **100% test pass rate** with memory guard enabled
- **Performance targets met**: <100µs writes, <1µs reads
- **Clean tidy output**: Zero architecture violations

### Developer Experience
- **Single command development**: `./zig/zig run tools/dev.zig -- test`
- **Individual test execution**: `--filter` works for any test
- **Fast feedback loops**: Unit tests complete in <5 seconds
- **Clear error messages**: All failures provide actionable context

### Production Readiness
- **Deterministic behavior** under fault injection
- **Graceful degradation** with backpressure
- **Observable performance** through structured logging
- **Zero external dependencies** for single binary deployment

## Risk Mitigation

### Memory Safety Risks
- **Validation**: Every memory operation goes through defensive checks
- **Testing**: Memory guard enabled in all integration tests
- **Monitoring**: Automatic leak detection in CI pipeline

### Performance Regression Risks
- **Measurement**: Benchmark every change to critical paths
- **Automation**: Performance tests in CI with clear thresholds
- **Fallback**: Debug-only safety checks ensure zero runtime overhead

### Architecture Complexity Risks
- **Simplicity**: Each abstraction must justify its existence
- **Documentation**: Every pattern documented with examples
- **Enforcement**: Tidy checker validates architectural constraints

This architecture provides the foundation for a production-grade v0.1.0 release while maintaining the project's core philosophy of simplicity, performance, and reliability.
