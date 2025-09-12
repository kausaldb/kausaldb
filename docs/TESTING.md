# Testing

KausalDB uses deterministic simulation and property-based testing to catch bugs that traditional unit tests miss. Every test failure can be reproduced exactly using a seed.

## Test Architecture

### Three-Tier Structure

**Unit Tests** (in source files):

- Test individual functions in isolation
- No I/O operations, pure computation
- Run in <1 second total
- Located alongside implementation code

**Integration Tests** (`src/tests/`):

- Test interactions between modules
- Use standardized test harnesses
- Access to internal APIs
- Deterministic via SimulationVFS

**End-to-End Tests** (`tests/`):

- Test binary interface only
- Subprocess execution with real CLI
- Real-world usage scenarios

## Test Harnesses

All integration tests use standardized harnesses from `src/tests/harness.
zig`:

### StorageHarness

For testing storage operations with simulation:

```zig
test "storage operations" {
    var harness = try StorageHarness.init(allocator, "test_db");
    defer harness.deinit();

    try harness.startup();
    defer harness.shutdown();

    const block = try TestData.create_test_block(allocator, 1);
    try harness.write_and_verify_block(&block);
}
```

### QueryHarness

For testing query operations with storage backend:

```zig
test "graph traversal" {
    var harness = try QueryHarness.init(allocator, "test_db");
    defer harness.deinit();

    try harness.startup();
    // Query testing with full storage stack
}
```

### ProductionHarness

For performance testing with real filesystem:

```zig
var harness = try ProductionHarness.init(allocator, "perf_test");
// Real I/O for accurate performance measurements
```

## Deterministic Simulation

### Virtual File System

All I/O goes through VFS abstraction enabling deterministic testing:

```zig
pub const VFS = union(enum) {
    real: ProductionVFS,       // Production
    simulation: SimulationVFS, // Testing
};
```

SimulationVFS provides:

- In-memory filesystem
- Deterministic failure injection
- 100x faster test execution
- Perfect reproducibility

### Property-Based Testing

Located in `src/sim/deterministic_test.zig`, tests system properties rather than specific examples:

```zig
// WorkloadGenerator creates deterministic operation sequences
var generator = WorkloadGenerator.init(allocator, seed, operation_mix);

// PropertyChecker validates system invariants
try PropertyChecker.check_no_data_loss(&model, &system);
try PropertyChecker.check_graph_consistency(&model);
```

**Operation Types Tested**:

- `put_block` - Block storage operations
- `find_block` - Block retrieval operations
- `put_edge` - Graph edge creation
- `find_edges` - Graph traversal
- `delete_block` - Block removal

### Fault Injection

Realistic failure scenarios via `SimulationVFS`:

- I/O errors at specific operation counts
- Partial writes (simulating power loss)
- File corruption with checksum validation
- Disk full scenarios
- Process crashes during operations

## Deterministic Reproduction

Every test uses seeded random generation:

```zig
test "crash recovery" {
    const seed = std.testing.random_seed;
    var sim = try SimulationRunner.init(allocator, seed);

    // On failure, outputs:
    // Test failed with seed: 0xDEADBEEF
    // Reproduce: ./zig/zig build test -Dseed=0xDEADBEEF
}
```

Build system supports seed parameter:

```bash
# Reproduce exact failure
./zig/zig build test -Dseed=0xDEADBEEF

# Run with specific seed
./zig/zig build test -Dseed=0x12345
```

## Memory Safety Testing

### Arena Validation

Tests verify arena memory patterns work correctly:

```zig
test "arena cleanup" {
    var arena = ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Operations that allocate memory
    var storage = try StorageEngine.init(arena.allocator(), vfs, "test");

    // Verify no leaks after cleanup
    storage.deinit();
}
```

### Memory Guard (Debug Builds)

Debug builds include comprehensive memory protection:

- Canary values detect buffer overflows
- Poison patterns catch use-after-free
- Allocation tracking finds leaks
- Zero overhead in release builds

## Running Tests

### Local Development

```bash
# Fast unit tests (~5 seconds)
./zig/zig build test

# Integration tests with simulation
./zig/zig build test-integration

# Full test suite including stress tests
./zig/zig build test-all

# Specific component
./zig/zig build test --test-filter="storage"

# With deterministic seed
./zig/zig build test -Dseed=0x12345
```

````

### Memory Safety Validation

```bash
# Enable safety allocator
./zig/zig build test -Denable-memory-guard=true

# AddressSanitizer (deep analysis)
./zig/zig build test -fsanitize-address

# Valgrind (Linux only)
valgrind --leak-check=full ./zig-out/bin/test
````

### CI Integration

GitHub Actions runs multiple configurations:

- Unit and integration tests
- Cross-platform validation (Linux, macOS, Windows)
- Multiple deterministic seeds
- Memory safety validation
- Performance regression detection

## Test Organization

```
src/tests/
├── harness.zig                   # Test utilities and harnesses
├── simulation/                   # Deterministic simulation tests
│   ├── crash_recovery_test.zig   # WAL recovery validation
│   ├── property_test.zig         # Property-based testing
│   └── workload_test.zig         # Mixed operation patterns
├── storage/                      # Storage engine tests
│   ├── memtable_test.zig         # In-memory operations
│   ├── wal_test.zig              # Write-ahead log durability
│   └── compaction_test.zig       # LSM compaction behavior
├── query/                        # Query engine tests
│   ├── traversal_test.zig        # Graph traversal algorithms
│   └── filtering_test.zig        # Query filtering
└── fault_injection/              # Failure scenario testing
    ├── io_errors_test.zig        # Disk failure simulation
    └── corruption_test.zig       # Data corruption handling
```

## Performance Testing

### Statistical Benchmarking

Located in `src/dev/benchmark/`, uses statistical sampling:

```zig
var sampler = StatisticalSampler.init();
// Multiple iterations with warmup
// P95, P99 percentile calculations
// Regression detection vs thresholds
```

### Benchmark Categories

- **Storage**: Block operations, WAL performance, compaction
- **Query**: Traversal algorithms, filtering, caching
- **Parsing**: Code ingestion from different languages
- **Memory**: Arena allocation patterns, cleanup performance

## Debugging Failed Tests

### Deterministic Reproduction

```bash
# Get seed from failed test output
./zig/zig build test -Dseed=0xFAILED_SEED

# Run with verbose output
./zig/zig build test --verbose

# Debug single test
./zig/zig build test --test-filter="exact_test_name"
```

### Memory Debugging

Tiered approach for memory issues:

1. **Quick**: Safety allocator in debug builds
2. **Deep**: AddressSanitizer for detailed analysis
3. **Interactive**: LLDB for complex issues

## What We Test

### Core Properties

- **Durability**: Acknowledged writes survive crashes
- **Consistency**: Graph relationships remain valid after operations
- **Isolation**: Concurrent operations don't interfere
- **Recoverability**: WAL replay restores exact pre-crash state

### Graph-Specific Properties

- **Edge Validity**: All edges reference existing blocks
- **Traversal Consistency**: Same query returns same results
- **Bidirectional Index**: Forward/reverse edge lookups are consistent

### Performance Properties

- Block writes: <100µs (95th percentile)
- Block reads: <1µs (hot data from memory)
- Graph traversal: <100µs (3-hop cached)
- Memory per operation: <2KB including all overhead

## What We Don't Test

- **Byzantine failures**: Single-node system, not distributed consensus
- **Network partitions**: No distributed components
- **SQL compliance**: Graph-native API only
- **Infinite edge cases**: Bounded by practical usage scenarios

## Philosophy

Test properties, not examples. Use deterministic simulation to systematically explore the state space. Every bug found in testing is one that won't corrupt production data.

The goal isn't 100% code coverage - it's confidence that the system behaves correctly under any realistic conditions.
