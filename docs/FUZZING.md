# Fuzzing Infrastructure

Production-grade fuzzing for KausalDB, designed to find bugs before users do.

## Philosophy

KausalDB's fuzzing follows TigerBeetle's approach: deterministic, reproducible, and comprehensive. Every crash can be replayed with a seed, every property can be verified against a model, and every code path can be exercised systematically.

## Architecture

### Three-Layer Approach

1. **Parse Fuzzing**: Find crashes in deserialization and input parsing
2. **Logic Fuzzing**: Find invariant violations through operation sequences
3. **Property Testing**: Verify system properties against reference models

### Key Components

```
src/fuzz/
├── main.zig           # Framework with coverage tracking and crash minimization
├── storage.zig        # Storage engine parse/logic fuzzing
├── query.zig          # Query engine parse/logic fuzzing
├── logic.zig          # Property-based testing (durability, consistency, linearizability)
├── network_protocol.zig # Protocol parsing fuzzing
├── graph_traversal.zig  # Graph algorithm fuzzing
├── ingestion.zig      # Code parsing pipeline fuzzing
└── cli_parser_fuzz.zig # CLI argument parsing fuzzing
```

## Fuzzing Targets

### Parse Fuzzing (Finding Crashes)

Tests deserialization robustness against malformed inputs:

- **storage_parse**: SSTable headers, WAL entries, block serialization
- **network_parse**: Protocol messages, framing, checksums
- **cli_parse**: Command-line argument parsing

### Logic Fuzzing (Finding Bugs)

Tests operational correctness with valid operations:

- **storage_logic**: Block/edge operations, flushes, compaction
- **query_logic**: Traversals, filters, semantic queries
- **graph_logic**: Cycle detection, path finding, connectivity

### Property Testing (Finding Violations)

Verifies system-wide invariants:

- **durability**: Data survives crashes and restarts
- **consistency**: Model and system state match
- **linearizability**: Operations appear atomic

## Running the Fuzzer

### Quick Fuzzing (CI/Development)

```bash
# Run all fuzzers with 1000 iterations
./zig/zig build fuzz-quick

# Run specific target
./zig/zig build fuzz -- storage_parse --iterations 10000

# Verbose output with coverage tracking
./zig/zig build fuzz -- all --verbose --iterations 100000
```

### Production Fuzzing

```bash
# Long-running fuzzing with corpus management
./scripts/production_fuzz.sh

# Parallel fuzzing across cores
parallel -j8 './zig/zig build fuzz -- {} --seed $RANDOM' ::: storage_parse network_parse query_logic
```

### Reproducing Crashes

Every crash includes a seed for exact reproduction:

```bash
# Reproduce specific crash
./zig/zig build fuzz -- storage_parse --seed 0xDEADBEEF --iterations 1

# Minimize crash input
./zig/zig build fuzz -- storage_parse --seed 0xDEADBEEF --minimize
```

## Coverage-Guided Fuzzing

The fuzzer tracks code coverage to guide input generation:

```zig
const CoverageTracker = struct {
    edges_seen: std.AutoHashMap(u64, void),
    new_coverage: bool = false,

    fn record_edge(self: *CoverageTracker, from: usize, to: usize) !void {
        const edge = (@as(u64, @intCast(from)) << 32) | @as(u64, @intCast(to));
        const result = try self.edges_seen.getOrPut(edge);
        self.new_coverage = !result.found_existing;
    }
};
```

Inputs that discover new code paths are prioritized for mutation.

## Input Generation Strategies

### Structured Fuzzing

```zig
pub fn generate_input(self: *Fuzzer, size_hint: usize) ![]u8 {
    const strategy = self.prng.random().uintLessThan(u8, 100);

    if (strategy < 10) {
        // 10%: Completely random bytes
        self.prng.random().bytes(input);
    } else if (strategy < 30) {
        // 20%: ASCII-heavy for text parsing
        // Generate printable characters with occasional control codes
    } else if (strategy < 50) {
        // 20%: Binary structure patterns
        // Length prefixes, checksums, magic numbers
    } else {
        // 50%: Mutation from corpus
        self.mutate_input(input);
    }
}
```

### Mutation Operations

- **Bit flips**: Single/multi-bit corruption
- **Arithmetic**: Add/subtract small values
- **Interesting values**: 0, 1, -1, MAX, MIN
- **Chunk operations**: Copy, swap, delete
- **Dictionary tokens**: Known protocol keywords

## Property-Based Testing

### Model-Based Testing

Compare system behavior against simplified reference implementation:

```zig
// Apply operation to both system and model
apply_to_storage(&storage, &operation);
apply_to_model(&model, &operation);

// Verify properties hold
try PropertyChecker.check_data_consistency(&model, &storage);
try PropertyChecker.check_bidirectional_consistency(&model, &storage);
try PropertyChecker.check_no_data_loss(&model, &storage);
```

### Linearizability Testing

Verify operations appear atomic:

```zig
// Track operation history with overlapping times
var history = std.ArrayList(struct {
    op: Operation,
    start_time: i64,
    end_time: i64,
    result: ?anyerror,
}).init(allocator);

// Execute operations with logical timestamps
// Verify linearizable ordering exists
```

## Crash Corpus Management

### Corpus Structure

```
fuzz-corpus/
├── crash_parse_error_0xABCD_1000.bin
├── crash_logic_error_0x1234_5000.bin
└── crash_assertion_failure_0xDEAD_10000.bin
```

Each crash file contains:
- Metadata header (type, error, iteration)
- Minimized input that triggers the crash
- Stack trace hash for deduplication

### Crash Minimization

Automatically reduce crash inputs to minimal reproducers:

```zig
fn minimize_crash(input: []const u8, expected_err: anyerror) ![]u8 {
    var minimized = input;
    var chunk_size = input.len / 2;

    while (chunk_size > 0) : (chunk_size /= 2) {
        // Try removing chunks
        // Keep minimal input that still crashes
    }
}
```

## Adding New Fuzz Targets

### Template for Parse Fuzzing

```zig
fn fuzz_new_parser(allocator: std.mem.Allocator, input: []const u8) !void {
    // Parse input
    const parsed = Parser.parse(input) catch |err| switch (err) {
        // Expected errors for malformed input
        error.InvalidFormat,
        error.ChecksumMismatch,
        => return,
        else => return err, // Unexpected error = bug
    };

    // Verify parsed result is valid
    try validate_parsed_structure(parsed);
}
```

### Template for Logic Fuzzing

```zig
fn test_new_property(storage: *StorageEngine, model: *ModelState) !void {
    // Generate operations
    const op = generate_operation();

    // Apply to both
    apply_to_storage(storage, op);
    apply_to_model(model, op);

    // Verify property
    if (!check_property(storage, model)) {
        return error.PropertyViolation;
    }
}
```

## Performance Considerations

### Memory Management

- Arena allocators reset every 100 iterations
- Peak memory tracked for regression detection
- Ownership tracking prevents use-after-free

### Execution Speed

Target metrics:
- Parse fuzzing: >100,000 exec/sec
- Logic fuzzing: >10,000 exec/sec
- Property testing: >1,000 exec/sec

### Parallelization

Run multiple fuzzer instances with different seeds:

```bash
# CPU-bound fuzzing
for i in {0..7}; do
    ./zig/zig build fuzz -- all --seed $i &
done
```

## Integration with CI

### Pre-commit Fuzzing

Quick smoke test before commits:

```bash
# .githooks/pre-push
./zig/zig build fuzz-quick || {
    echo "Fuzzing found crashes. Fix before pushing."
    exit 1
}
```

### Nightly Fuzzing

Extended fuzzing runs in CI:

```yaml
# .github/workflows/nightly.yml
- name: Extended Fuzzing
  run: |
    ./zig/zig build fuzz -- all --iterations 1000000
    ./scripts/check_coverage.sh
```

## Debugging Crashes

### With GDB

```bash
# Generate crash
./zig/zig build fuzz -- storage_parse --seed 0xBAD

# Debug with GDB
gdb ./zig-out/bin/fuzz
(gdb) run storage_parse --seed 0xBAD --iterations 1
(gdb) bt  # Backtrace at crash
```

### With AddressSanitizer

```bash
# Build with ASAN
./zig/zig build -fsanitize=address

# Run fuzzer
./zig-out/bin/fuzz storage_parse
```

### With Valgrind

```bash
# Memory error detection
valgrind --leak-check=full ./zig-out/bin/fuzz logic --iterations 100
```

## Best Practices

### DO

- **Deterministic seeds**: Always use seeds for reproducibility
- **Model checking**: Compare against simple reference implementations
- **Property focus**: Test invariants, not just crashes
- **Fast iteration**: Optimize for executions per second
- **Corpus maintenance**: Save interesting inputs for regression

### DON'T

- **Random assertions**: Every assertion should test a real invariant
- **Slow operations**: Avoid I/O in hot paths
- **Memory leaks**: Use arena allocators or proper cleanup
- **Infinite loops**: Set bounds on all iterations
- **Silent failures**: Log enough context to debug crashes

## Future Enhancements

### Coverage-Guided Evolution

- AFL++ integration for advanced mutation strategies
- LibFuzzer compatibility for existing corpora
- Differential fuzzing against other databases

### Distributed Fuzzing

- ClusterFuzz integration for large-scale campaigns
- Automatic crash triage and deduplication
- Performance regression detection

### Smart Fuzzing

- Grammar-based generation for complex queries
- Symbolic execution for constraint solving
- Machine learning for input prioritization

## References

- [TigerBeetle Fuzzing](https://tigerbeetle.com/blog/2023-07-11-we-put-a-distributed-database-in-the-browser)
- [FoundationDB Simulation](https://www.youtube.com/watch?v=fFSPwJFXVlw)
- [LibAFL Book](https://aflplus.plus/)
- [Property-Based Testing](https://hypothesis.works/)
