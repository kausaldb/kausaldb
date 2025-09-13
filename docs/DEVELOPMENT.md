# Development Guide

Practical guide for KausalDB development focused on production-grade tooling and workflows.

## Quick Start

```bash
# Install exact Zig version
./scripts/install_zig.sh

# Run fast test suite
./zig/zig build test

# Run benchmarks
./zig/zig build bench

# Run fuzzing
./zig/zig build fuzz-quick

# Build and run the server
./zig/zig build run
```

## Build System

KausalDB uses a comprehensive Zig build system designed for deterministic, production-grade development:

- **Deterministic**: All builds and tests are reproducible using seeds
- **Comprehensive**: Full coverage of unit, integration, simulation, and fuzz testing
- **Performance-focused**: Benchmarks target microsecond-level precision
- **Production-grade**: Security scanning, memory safety, and regression detection

### Core Executable

```bash
# Build the main KausalDB server
./zig/zig build

# Build and run the server
./zig/zig build run

# Build with specific optimization
./zig/zig build -Doptimize=ReleaseSafe
./zig/zig build -Doptimize=ReleaseFast
./zig/zig build -Doptimize=ReleaseSmall
./zig/zig build -Doptimize=Debug
```

### Test Suites

```bash
# Fast test suite (unit + integration) - for development
./zig/zig build test

# Complete test suite - for CI validation
./zig/zig build test-all

# Individual test suites
./zig/zig build test-unit          # Unit tests only
./zig/zig build test-integration   # Integration tests only
./zig/zig build test-e2e          # End-to-end tests only
```

### Test Configuration

```bash
# Run with deterministic seed (reproducible failures)
./zig/zig build test -Dseed=0xDEADBEEF

# Filter tests by name
./zig/zig build test -Dfilter="storage"

# Run multiple iterations for flaky test detection
./zig/zig build test -Dtest-iterations=10

# Set test timeout (milliseconds)
./zig/zig build test -Dtest-timeout=60000

# Enable verbose logging
./zig/zig build test -Dlog=debug
```


### Benchmarking

```bash
# Run all benchmarks
./zig/zig build bench

# Configure benchmark parameters
./zig/zig build bench \
    -Dbench-iterations=10000 \
    -Dbench-warmup=1000

# Compare against baseline for regression detection
./zig/zig build bench -Dbench-baseline=baseline.json
```

Performance targets enforced by benchmarks:

- **Block reads**: Must complete in < 0.06µs
- **Block writes**: Must complete in < 1µs
- **Query parsing**: Must complete in < 10µs
- **SSTable scans**: Must maintain > 100MB/s throughput

### Fuzzing

```bash
# Run 1000 iterations for quick validation
./zig/zig build fuzz-quick

# Run full fuzzing campaign
./zig/zig build fuzz \
    -Dfuzz-iterations=100000 \
    -Dfuzz-timeout=5000 \
    -Dfuzz-corpus=fuzz-corpus
```

### Development Tools

```bash
# Format all code in-place
./zig/zig build fmt

# Check formatting without modifying
./zig/zig build fmt-check

# Run style and naming convention checks
./zig/zig build tidy

# Run all linters
./zig/zig build lint
```

### Git Hooks

Git hooks are pre-configured and active in this repository:
- Code formatting checks (`zig fmt`)
- Style and naming convention validation (`zig build tidy`) 
- Fast unit test execution (`zig build test`)

These hooks run automatically on commit and push operations.


### Build Options Reference

#### Global Options

| Option       | Type   | Default | Description                        |
| ------------ | ------ | ------- | ---------------------------------- |
| `-Dtarget`   | string | native  | Target triple (e.g., x86_64-linux) |
| `-Doptimize` | enum   | Debug   | Optimization mode                  |
| `-Dlog`      | enum   | warn    | Log level (err/warn/info/debug)    |

#### Test Options

| Option              | Type   | Default | Description               |
| ------------------- | ------ | ------- | ------------------------- |
| `-Dseed`            | u64    | random  | Test seed for determinism |
| `-Dfilter`          | string | null    | Filter tests by name      |
| `-Dtest-iterations` | u32    | 1       | Number of test iterations |
| `-Dtest-timeout`    | u32    | 30000   | Test timeout in ms        |
| `-Dcoverage`        | bool   | false   | Enable coverage reporting |

#### Benchmark Options

| Option               | Type   | Default | Description                  |
| -------------------- | ------ | ------- | ---------------------------- |
| `-Dbench-iterations` | u32    | 1000    | Benchmark iterations         |
| `-Dbench-warmup`     | u32    | 100     | Warmup iterations            |
| `-Dbench-baseline`   | string | null    | Baseline file for comparison |

#### Fuzzing Options

| Option              | Type   | Default     | Description            |
| ------------------- | ------ | ----------- | ---------------------- |
| `-Dfuzz-iterations` | u32    | 10000       | Fuzzing iterations     |
| `-Dfuzz-timeout`    | u32    | 1000        | Timeout per test in ms |
| `-Dfuzz-corpus`     | string | fuzz-corpus | Corpus directory       |

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
│   ├── bench/             # Benchmark executables
│   ├── fuzz/              # Fuzzing executables
│   ├── kausaldb.zig       # Public API
│   ├── internal.zig       # Internal API for dev tools
│   └── main.zig           # CLI entry point
├── tests/                 # E2E tests (binary interface only)
├── docs/                  # Documentation
└── build.zig              # Build configuration
```

## Debugging Workflow

### Memory Corruption

When encountering memory corruption, follow this tiered approach:

#### Tier 1: General Purpose Allocator

```zig
// In the failing test, replace:
const allocator = std.testing.allocator;

// With:
var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
defer _ = gpa.deinit();
const allocator = gpa.allocator();
```

#### Tier 2: Valgrind (Linux)

```bash
valgrind --tool=memcheck --leak-check=full \
    --track-origins=yes --verbose \
    ./zig/zig build test
```


## Reproducing CI Failures

When CI fails, reproduce locally using the exact same configuration:

```bash
# Check the CI logs for the exact command, e.g.:
# "Testing on ubuntu-latest with seed: 0xDEADBEEF"

# Reproduce locally:
./zig/zig build test -Dseed=0xDEADBEEF

# For fuzzing crashes:
./zig/zig build fuzz --corpus fuzz-corpus/crashes/crash_12345.bin
```

## Common Development Workflows

./zig/zig build test-all # Everything including stress
./zig/zig build test --test-filter="storage" # Specific component
./zig/zig build test -Dseed=0xDEADBEEF # Deterministic reproduction

# Development

./zig/zig build run # Run server
./zig/zig build run -- --help # Pass arguments
./zig/zig build test # Core development workflow
./zig/zig build fuzz # Fuzz testing

# CI/Quality

./zig/zig build fmt-check # Format verification
./zig/zig build tidy # Naming conventions

````

### Build Options

```bash
# Optimization
-Doptimize=Debug          # Default, fast compilation
-Doptimize=ReleaseSafe    # Production with safety
-Doptimize=ReleaseFast    # Maximum performance
-Doptimize=ReleaseSmall   # Minimum binary size


# Testing
-Dseed=0x12345           # Deterministic test seed
-Dtest-filter="pattern"   # Run specific tests
````

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
# Run performance benchmarks
./zig/zig build bench
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

2. **Deep**: Valgrind (Linux)

```bash
valgrind --tool=memcheck --leak-check=full ./zig/zig build test
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



## Performance Profiling

### CPU Profiling

```bash
# With Tracy (if built with -Denable-tracy)
./zig/zig build -Denable-tracy
./zig-out/bin/kausaldb --profile

# With perf (Linux)
perf record ./zig-out/bin/kausaldb --benchmark
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
# Enable safety allocator for debugging
./zig/zig build test  # Use GeneralPurposeAllocator in test code
```

**Performance regression**:

```bash
# Compare before/after
./zig/zig build bench > before.txt
# ... make changes ...
./zig/zig build bench > after.txt
diff before.txt after.txt
```

**Deterministic test failure**:

```bash
# Use the seed from CI
./zig/zig build test -Dseed=0xFAILED_SEED
```

## Release Process

### Pre-release Checklist

- [ ] `./zig/zig build test-all` passes
- [ ] No memory leaks: `valgrind ./zig/zig build test`
- [ ] Performance targets met: `./zig/zig build bench`
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
