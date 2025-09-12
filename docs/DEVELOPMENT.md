# Development

Practical guide for KausalDB development. No fluff, just what you need to know.

## Quick Start

```bash
# Setup
./scripts/install_zig.sh     # Get exact Zig version
./scripts/setup_hooks.sh     # Install git hooks

# Build and test
./zig/zig build test         # Fast unit tests (~5 seconds)
./zig/zig build run          # Start server

# Full validation before commit
./zig/zig build ci-smoke     # Format, tidy, tests
```

## Project Structure

```
kausaldb/
├── src/
│   ├── core/              # Foundation: types, VFS, memory, concurrency
│   ├── storage/           # LSM engine: WAL, memtable, SSTables, compaction
│   ├── query/             # Query engine: traversal, filtering, planning
│   ├── ingestion/         # File parsing: Zig, Rust, Python, TypeScript
│   ├── sim/               # Deterministic simulation framework
│   ├── server/            # HTTP API and request handling
│   ├── tests/             # Integration tests with internal API access
│   ├── dev/               # Development tools: benchmark, fuzz, debug
│   ├── kausaldb.zig       # Public API
│   ├── internal.zig       # Internal API for dev tools
│   └── main.zig           # CLI entry point
├── tests/                 # E2E tests (binary interface only)
├── docs/                  # You are here
└── build.zig              # Build configuration
```

## Build System

Everything goes through `build.zig`. No Makefiles, no shell scripts for building.

### Common Targets

```bash
# Testing
./zig/zig build test                          # Unit tests only
./zig/zig build test-integration              # Integration tests
./zig/zig build test-all                      # Everything including stress
./zig/zig build test --test-filter="storage"  # Specific component
./zig/zig build test -Dseed=0xDEADBEEF       # Deterministic reproduction

# Development
./zig/zig build run                           # Run server
./zig/zig build run -- --help                 # Pass arguments
./zig/zig build benchmark                     # Performance tests
./zig/zig build fuzz                         # Fuzz testing
./zig/zig build debug                        # Debug utilities

# CI/Quality
./zig/zig build ci-smoke                     # Quick validation
./zig/zig build ci-full                      # Complete validation
./zig/zig build ci-stress                    # Stress testing
./zig/zig build fmt-check                    # Format verification
./zig/zig build tidy                         # Naming conventions
```

### Build Options

```bash
# Optimization
-Doptimize=Debug          # Default, fast compilation
-Doptimize=ReleaseSafe    # Production with safety
-Doptimize=ReleaseFast    # Maximum performance
-Doptimize=ReleaseSmall   # Minimum binary size

# Safety
-fsanitize-address        # AddressSanitizer
-Denable-memory-guard     # Custom memory validation
-Denable-tracy            # Tracy profiler integration

# Testing
-Dseed=0x12345           # Deterministic test seed
-Dtest-filter="pattern"   # Run specific tests
```

## Testing Workflow

### Three-Tier Testing

1. **Unit tests** (in source files): No I/O, pure functions
2. **Integration tests** (`src/tests/`): Module interactions, harness-based
3. **E2E tests** (`tests/`): Binary interface, subprocess execution

### Test Harnesses

All integration tests use standardized harnesses:

```zig
test "storage operations" {
    var harness = try StorageHarness.init(allocator, "test_db");
    defer harness.deinit();

    try harness.startup();
    defer harness.shutdown();

    // Your test here
    const block = try harness.generate_block(42);
    try harness.write_and_verify_block(&block);
}
```

Available harnesses:

- `StorageHarness`: Storage with SimulationVFS
- `QueryHarness`: Query engine with storage
- `SimulationHarness`: Failure injection
- `BenchmarkHarness`: Performance measurement

### Deterministic Reproduction

Every test failure can be reproduced:

```bash
# Test output on failure:
# Test failed with seed: 0x7B3AF291
# Reproduce with: ./zig/zig build test -Dseed=0x7B3AF291

./zig/zig build test -Dseed=0x7B3AF291  # Exact reproduction
```

## Code Style

### Naming Conventions

**Functions**: Verb-first, action-oriented

```zig
pub fn find_block(id: BlockId) !?ContextBlock     // GOOD
pub fn get_block(id: BlockId) !?ContextBlock      // BAD: no get/set
```

**Error Handling**: Prefix indicates fallibility

```zig
pub fn try_parse_header() !Header    // Error union
pub fn maybe_find_block() ?Block     // Optional
```

**Lifecycle**: Standard names only

```zig
pub fn init()      // Cold: memory only
pub fn startup()   // Hot: I/O operations
pub fn shutdown()  // Graceful termination
pub fn deinit()    // Memory cleanup
```

### Import Organization

Manually formatted, no automation:

```zig
// 1. Standard library
const std = @import("std");

// 2. Internal modules (alphabetical)
const assert_mod = @import("../core/assert.zig");
const memory = @import("../core/memory.zig");
const vfs = @import("../core/vfs.zig");

// 3. Re-declarations
const assert = assert_mod.assert;
const fatal_assert = assert_mod.fatal_assert;

// 4. Types
const ArenaAllocator = std.heap.ArenaAllocator;
const BlockId = types.BlockId;
```

### Comments

Explain **why**, not **what**:

```zig
// BAD: Increment counter
counter += 1;

// GOOD: WAL requires sequential IDs for recovery validation
counter += 1;
```

### Memory Patterns

Arena coordinator pattern:

```zig
pub const Engine = struct {
    arena: ArenaAllocator,
    coordinator: ArenaCoordinator,  // Survives copies

    pub fn flush(self: *Engine) !void {
        // Work...
        self.coordinator.reset();  // O(1) cleanup
    }
};
```

## Development Tools

### Benchmarking

```bash
# Run all benchmarks
./zig/zig build benchmark

# Specific operation
./zig-out/bin/benchmark storage
./zig-out/bin/benchmark query
./zig-out/bin/benchmark compaction

# JSON output for CI
./zig-out/bin/benchmark all --json
```

Performance targets:

- Block write: <100µs
- Block read: <1µs
- Graph traversal: <100µs
- Memory/op: <2KB

### Fuzzing

```bash
# Quick fuzz (5 minutes)
./scripts/quick_fuzz.sh

# Production fuzz (overnight)
./scripts/production_fuzz.sh

# Specific component
./zig-out/bin/fuzz storage --iterations=10000
```

### Debugging

#### Memory Issues

Tiered approach:

1. **Quick**: Safety allocator

```zig
var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
```

2. **Deep**: AddressSanitizer

```bash
./zig/zig build test -fsanitize-address
```

3. **Interactive**: LLDB

```bash
lldb ./zig-out/bin/test
(lldb) break set -n fatal_assert
(lldb) run
```

#### Test Failures

```bash
# Get detailed output
./zig/zig build test --verbose

# Run single test
./zig/zig build test --test-filter="exact_test_name"

# Debug build with symbols
./zig/zig build -Doptimize=Debug
lldb ./zig-out/bin/test
```

## Git Workflow

### Pre-commit Hooks

Automatically runs on commit:

1. `zig fmt` - Code formatting
2. `build tidy` - Naming conventions
3. `build test` - Unit tests
4. Commit message validation

### Commit Messages

```
type(scope): brief summary

Optional context paragraph.

- Specific change 1
- Specific change 2

Impact: Result statement.
```

Types: `feat`, `fix`, `refactor`, `test`, `docs`, `perf`, `chore`

Example:

```
feat(storage): implement size-tiered compaction

Replace level-based compaction with size-tiered strategy for
better write amplification under heavy ingestion workloads.

- Add TieredCompactionManager with size-based triggers
- Remove LevelCompactionStrategy and related code
- Update SSTableManager to track size tiers
- Add compaction metrics for tier tracking

Impact: 30% reduction in write amplification.
```

## CI Pipeline

### Local CI Simulation

```bash
# Run what CI runs
./zig/zig build ci-smoke    # Quick checks (2 min)
./zig/zig build ci-full     # Everything (10 min)
```

### GitHub Actions

```yaml
# .github/workflows/ci.yml
- ci-smoke: Format, tidy, unit tests
- ci-matrix: Cross-platform compilation
- ci-stress: Extended stress testing
- ci-perf: Performance regression detection
```

## Performance Profiling

### CPU Profiling

```bash
# With Tracy (if built with -Denable-tracy)
./zig/zig build -Denable-tracy
./zig-out/bin/kausaldb --profile

# With perf (Linux)
perf record ./zig-out/bin/benchmark storage
perf report
```

### Memory Profiling

```bash
# Built-in metrics
./zig-out/bin/kausaldb --memory-stats

# Valgrind (Linux)
valgrind --leak-check=full ./zig-out/bin/test
```

## Troubleshooting

### Common Issues

**Import errors in tests**:

```
error: import of file outside module path
```

Solution: Move test to `src/tests/` for internal API access.

**Memory corruption**:

```bash
# Enable all safety checks
./zig/zig build test -Denable-memory-guard -fsanitize-address
```

**Performance regression**:

```bash
# Compare before/after
./zig/zig build benchmark > before.txt
# ... make changes ...
./zig/zig build benchmark > after.txt
diff before.txt after.txt
```

**Deterministic test failure**:

```bash
# Use the seed from CI
./zig/zig build test -Dseed=0xFAILED_SEED
```

## Release Process

### Pre-release Checklist

- [ ] `./zig/zig build ci-full` passes
- [ ] No memory leaks: `./zig/zig build test -fsanitize-address`
- [ ] Performance targets met: `./zig/zig build benchmark`
- [ ] Fuzz testing clean: `./scripts/quick_fuzz.sh`
- [ ] Documentation current
- [ ] CHANGELOG updated

### Build Release

```bash
# Build optimized binaries
./zig/zig build -Doptimize=ReleaseSafe     # With safety checks
./zig/zig build -Doptimize=ReleaseFast     # Maximum performance

# Verify
./zig-out/bin/kausaldb --version
./scripts/validate_release.sh
```

## Contributing

### Code Review Checklist

- [ ] Follows naming conventions (verb-first functions)
- [ ] Comments explain why, not what
- [ ] Tests use harnesses where applicable
- [ ] Error handling is explicit
- [ ] Memory management uses arena pattern
- [ ] Performance impact considered
- [ ] Documentation updated if needed

### Adding Features

1. Write property-based test first
2. Implement with simplest approach
3. Measure performance impact
4. Add integration test with harness
5. Update relevant documentation

### Performance Guidelines

Before optimizing:

1. Benchmark current state
2. Profile to find bottleneck
3. Implement improvement
4. Measure again
5. Document trade-offs

## Philosophy

**Explicit over implicit**: Every allocation, every state change visible.

**Simple over clever**: Boring code that works > clever code that might work.

**Test properties, not examples**: Find bugs through systematic exploration.

**Fail fast and loud**: `fatal_assert` on invariant violations.

**Arena everywhere**: O(1) cleanup, no fragmentation, predictable performance.

Remember: We're building a database. Correctness matters more than features. Performance matters more than flexibility. Simplicity matters more than elegance.
