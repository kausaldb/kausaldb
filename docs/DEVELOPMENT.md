# Development Guide

Comprehensive guide for KausalDB development, testing, and contribution.

## Quick Start

```bash
# Install toolchain and setup
./zig/zig build ci-setup

# Run tests
./zig/zig build test                     # Fast unit tests
./zig/zig build test-integration         # Integration tests
./zig/zig build ci-full                  # Full CI pipeline locally

# Development workflow
./zig/zig build run                      # Run server
./zig/zig build ci-smoke                 # Code quality checks
./zig/zig build benchmark               # Performance benchmarks
```

## Development Workflow

### Unified Developer Tool

All development tasks are managed through build targets:

```bash
# Testing
./zig/zig build test                             # Fast unit tests
./zig/zig build test --test-filter="storage"     # Test specific component
./zig/zig build test -fsanitize-address          # Enable safety checks
./zig/zig build ci-stress                        # Stress testing

# Code Quality
./zig/zig build ci-smoke                         # Format + tidy + fast tests
./zig/zig build fmt-fix                          # Auto-fix formatting

# Performance
./zig/zig build benchmark                        # Run benchmarks
./zig/zig build fuzz                             # Fuzz testing
./zig/zig build ci-perf                          # Performance validation

# CI Validation
./zig/zig build ci-full                          # Complete CI pipeline locally
```

### Git Workflow

Pre-commit hooks automatically:
- Format code with `zig fmt`
- Run tidy checks for naming conventions
- Execute fast unit tests
- Validate commit message format

## Test Architecture

### Three-Tier Testing Hierarchy

1. **Unit Tests** (in source files)
   - Test individual functions
   - No I/O or external dependencies
   - Run in <1 second total

2. **Integration Tests** (`src/tests/`)
   - Test module interactions
   - Use test harnesses for consistency

3. **E2E Tests** (`tests/`)
   - Binary interface only
   - Subprocess execution
   - Real-world scenarios

### Test Harness Framework

All integration tests use standardized harnesses:

```zig
const harness = @import("harness.zig");

test "storage operations" {
    var test_harness = harness.StorageHarness.init(allocator, "test_name", false);
    defer test_harness.deinit();

    try test_harness.startup();
    defer test_harness.shutdown();

    // Test implementation using harness utilities
    const block = try test_harness.base.generate_block(42);
    try test_harness.write_and_verify_block(&block);
}
```

Available harnesses:
- `TestHarness`: Base functionality, memory management
- `StorageHarness`: Storage engine with VFS
- `QueryHarness`: Query engine with storage
- `SimulationHarness`: Deterministic failure injection
- `BenchmarkHarness`: Performance measurement

### Memory Safety

Debug builds include comprehensive memory protection:

```zig
const memory_guard = @import("core/memory_guard.zig");

test "memory safety" {
    var guard = memory_guard.create_test_allocator(allocator);
    defer guard.deinit();  // Reports any leaks

    const alloc = guard.allocator();
    // All allocations tracked with canary values
    // Buffer overflows detected immediately
    // Use-after-free caught with poison patterns
}
```

## Code Style

### Naming Conventions

**Functions**: Verb-first, action-oriented
```zig
pub fn find_block(id: BlockId) !?ContextBlock     // GOOD
pub fn get_block(id: BlockId) !?ContextBlock      // BAD: no get prefix
```

**Error Handling**: Prefix indicates fallibility
```zig
pub fn try_parse_header() !Header        // Error union
pub fn maybe_find_block() ?Block        // Optional
```

**Lifecycle**: Standard names only
```zig
pub fn init()      // Cold: memory only
pub fn startup()   // Hot: I/O operations
pub fn shutdown()  // Graceful termination
pub fn deinit()    // Memory cleanup
```

### Comments

Comments explain **why**, not **what**:

```zig
// BAD: Increment counter
counter += 1;

// GOOD: WAL requires sequential entry numbers for recovery validation
counter += 1;
```

### Arena Memory Pattern

Coordinators provide stable interfaces:

```zig
pub const Engine = struct {
    arena: ArenaAllocator,
    coordinator: ArenaCoordinator,  // Survives arena ops

    pub fn flush(self: *Engine) !void {
        // ... flush to disk ...
        self.coordinator.reset();  // O(1) cleanup
    }
};
```

## Performance Guidelines

### Measurement First

Before optimizing:
1. Benchmark current performance
2. Identify bottleneck with profiling
3. Implement improvement
4. Measure again to verify

```bash
# Benchmark specific operation
zig run tools/dev.zig -- bench block-write

# Profile with tracy (if enabled)
zig build -Denable-tracy=true
./zig-out/bin/kausaldb --profile
```

### Performance Targets

All operations must meet these thresholds:

| Operation | Target | Current | Margin |
|-----------|--------|---------|--------|
| Block Write | <100µs | 68µs | 32% |
| Block Read | <1µs | 23ns | 43x |
| Graph Traversal | <100µs | 130ns | 769x |
| Memory/Write | <2KB | 1.6KB | 20% |

## Debugging

### Memory Corruption

Use tiered debugging approach:

1. **Quick Check**: Enable safety allocator
```zig
var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
```

2. **Deep Analysis**: AddressSanitizer
```bash
zig build test -fsanitize-address
```

3. **Interactive**: LLDB
```bash
lldb ./zig-out/bin/test
(lldb) break set -n assert_fmt
(lldb) run
```

### Deterministic Reproduction

All failures must be reproducible:

```zig
test "deterministic failure" {
    var sim = Simulation.init(allocator, 0x12345);  // Fixed seed
    sim.inject_io_failure_at(500);                  // Precise failure
    // Test handles failure correctly
}
```

## Project Structure

```
kausaldb/
├── src/                    # Source code
│   ├── core/              # Core utilities (assert, memory, vfs)
│   ├── storage/           # Storage engine components
│   ├── query/             # Query engine
│   ├── dev/               # Development tools (CI, benchmarks, etc.)
│   ├── tests/             # Integration tests with API access
│   └── main.zig           # Entry point
├── tests/                  # E2E tests (binary interface only)
├── docs/                   # Documentation
└── build.zig              # Build configuration with CI targets
```

## Contributing

### Before Submitting

1. **Run full validation**:
```bash
./zig/zig build ci-full
```

2. **Update documentation** if changing APIs

3. **Add tests** for new functionality:
   - Unit test in source file
   - Integration test in `src/tests/`
   - E2E test if user-facing

4. **Benchmark** performance-critical changes

### Commit Messages

Follow conventional format:
```
type(scope): brief summary

Optional context paragraph.

- Specific change 1
- Specific change 2

Impact: Result statement.
```

Types: `feat`, `fix`, `refactor`, `test`, `docs`, `perf`, `chore`

### Review Checklist

- [ ] Follows naming conventions
- [ ] Comments explain why, not what
- [ ] Tests cover edge cases
- [ ] No memory leaks (debug build passes)
- [ ] Performance targets met
- [ ] Documentation updated

## Troubleshooting

### Common Issues

**Import errors in tests**:
```
ERROR: import of file outside module path
```
Solution: Move test to `src/tests/` for internal API access.

**Memory corruption**:
```bash
# Enable memory guard
zig build test -Denable-memory-guard=true
```

**Performance regression**:
```bash
# Compare benchmarks
./zig/zig build benchmark > before.txt
# ... make changes ...
./zig/zig build benchmark > after.txt
diff before.txt after.txt
```

### Getting Help

1. Check existing tests for patterns
2. Review harness implementations
3. Read architecture docs in `docs/architecture/`
4. Ask in discussions with minimal reproduction

## Release Process

### Pre-release Checklist

- [ ] All tests pass: `./zig/zig build ci-full`
- [ ] No memory leaks: `./zig/zig build test -fsanitize-address`
- [ ] Performance targets met: `./zig/zig build ci-perf`
- [ ] Documentation current
- [ ] CHANGELOG updated
- [ ] Version bumped in `build.zig`

### Release Commands

```bash
# Tag release
git tag -a v0.1.0 -m "Release v0.1.0"

# Build release binaries
zig build -Doptimize=ReleaseFast
zig build -Doptimize=ReleaseSmall

# Run release validation
./scripts/validate_release.sh
```

## Philosophy

**Simplicity is the prerequisite for reliability.** Every line of code should be:
- Obviously correct
- Necessary for functionality
- Testable in isolation
- Maintainable by others

**Zero-cost abstractions.** Safety mechanisms must have zero runtime overhead in release builds. We target microsecond operations.

**Explicit over magic.** All control flow, memory allocation, and state transitions must be immediately obvious. No hidden behavior.

---

*Last updated: Preparing for v0.1.0 release*
