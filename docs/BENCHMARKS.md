# KausalDB Performance Benchmarks

Performance measurements from the actual implementation running on M1 MacBook Pro with ReleaseSafe build mode.

## Current Performance (September 2025)

### Storage Engine Operations

| Operation             | Mean Time | Min Time | Max Time | Iterations | Notes                    |
| --------------------- | --------- | -------- | -------- | ---------- | ------------------------ |
| Block Write           | 0.88μs    | 0.46μs   | 42.58μs  | 1,000      | Write to memtable + WAL  |
| Block Read (memtable) | 0.05μs    | 0.00μs   | 0.21μs   | 1,000      | Memory access            |
| Block Read (SSTable)  | 0.02μs    | 0.00μs   | 0.17μs   | 50         | Bloom filter + disk read |
| Memtable Flush        | 752.78μs  | 90.54μs  | 5.96ms   | 10         | Background operation     |
| Edge Insert           | 1.26μs    | 0.92μs   | 4.50μs   | 1,000      | Validation + WAL + index |
| Edge Lookup           | 0.04μs    | 0.00μs   | 0.13μs   | 1,000      | Graph index access       |
| Graph Traversal       | 0.10μs    | 0.04μs   | 0.17μs   | 1,000      | Single hop with bounds   |

### What Each Benchmark Measures

**Block Write**

- Creates test block in memory
- Calls `storage.put_block()` which writes to memtable and WAL
- Measures time from function entry to return

**Block Read (memtable)**

- Pre-populates storage with test blocks (stored in memtable)
- Calls `storage.find_block()` which searches memtable
- Measures memory-based lookup time

**Block Read (SSTable)**

- Pre-populates storage, forces flush to create SSTable on disk
- SSTable creation immediately loads bloom filter into memory
- Calls `storage.find_block()` which:
  1. Checks cached bloom filter (memory access)
  2. If bloom filter says "exists", reads from disk
  3. If bloom filter says "doesn't exist", returns immediately
- Measures bloom-filter-assisted lookup time

**Edge Insert**

- Validates source and target blocks exist (uses block lookups above)
- Writes edge to WAL for durability
- Updates in-memory graph index
- Measures complete operation including validation

**Graph Traversal**

- Single-step traversal with edge type filtering
- Uses bounded pre-allocated data structures (no allocation)
- Measures traversal logic excluding result processing

## Architecture Impact on Performance

### Bloom Filter Caching

SSTable reads benefit from pre-loaded bloom filters:

- Bloom filters loaded during SSTable discovery (startup)
- Cached in memory for entire server lifetime
- False positive rate: ~1% (configurable)
- Cache never evicted (remains until restart)

This means SSTable reads in production are always bloom-filter-assisted.

### Memory Management

- Block Index (memtable): Arena-allocated, O(1) cleanup on flush
- WAL: Append-only, background segment rotation
- SSTable Manager: Bloom filters cached, indices loaded on demand

### Single-threaded Architecture

All measurements reflect single-threaded execution:

- No lock contention overhead
- No cache coherency costs
- Deterministic performance characteristics

## Performance Targets vs Achieved

| Operation        | Target | Achieved    | Status |
| ---------------- | ------ | ----------- | ------ |
| Block Write      | <2.0μs | 0.88μs      | Met    |
| Block Read       | <0.1μs | 0.02-0.05μs | Met    |
| Edge Operations  | <2.0μs | 1.26μs      | Met    |
| Memory per Write | <2KB   | ~1KB        | Met    |

## Test Environment

- Platform: Apple M1 Pro (ARM64)
- OS: macOS 14.6
- Compiler: Zig 0.13.0 (exact version controlled)
- Build: ReleaseSafe (optimizations + safety checks)
- Storage: SSD with fsync enabled
- Configuration: Production defaults

## Methodology

### Statistical Approach

Each benchmark runs with:

- Warmup iterations: 100 (excluded from results)
- Measurement iterations: 50-1,000 (depending on operation cost)
- Timer: High-resolution monotonic clock
- Results: Mean, min, max reported (no percentiles due to small sample sizes)

### Setup Isolation

- Fresh StorageEngine instance per benchmark run
- Deterministic test data (seeded random generation)
- Setup costs excluded from measurements
- Background operations (compaction) disabled during measurement

### Limitations

- Synthetic workload (uniform block sizes, predictable access patterns)
- Single-threaded only (no concurrency stress testing)
- Limited dataset size (fits in available memory)
- No durability stress testing (power failure scenarios)

## Known Measurement Issues

### SSTable Read Performance Anomaly

SSTable reads (0.02μs) appear faster than memtable reads (0.05μs), which violates physical constraints since disk access cannot be faster than memory access.

Potential causes:

1. Measurement noise at nanosecond resolution
2. Bloom filter cache effects (false negatives skip disk I/O entirely)
3. Different code paths with varying overhead
4. Timer resolution limitations

This requires investigation before the benchmark can be considered reliable for SSTable performance analysis.

## Running Benchmarks

```bash
# All benchmarks (release mode)
./zig/zig build bench --release=safe

# Debug mode (slower, more detailed)
./zig/zig build bench

# Specific component only
./zig/zig build bench -- --component storage
```

## Historical Context

Previous measurements showed significantly slower performance before recent optimizations:

- Block reads were measured in milliseconds (2.8ms for cold reads)
- Edge operations took >7ms
- Performance was unusable for production workloads

Current measurements show dramatic improvement but require validation to ensure benchmark accuracy.

## Future Work

### Benchmark Improvements Needed

1. Separate true cold reads (no bloom filter cache) from warm reads
2. Add cache miss rate measurements
3. Implement proper percentile calculations (P50, P95, P99)
4. Add concurrent workload testing
5. Add memory pressure testing
6. Add durability/crash recovery benchmarks

### Performance Analysis

- Profile SSTable read path to understand performance characteristics
- Measure actual disk I/O vs bloom filter cache hit rates
- Validate timer resolution and measurement accuracy
- Add CPU profiling during benchmark runs

## Regression Detection

Automated performance regression detection is not yet implemented. Manual comparison against previous runs is required to detect performance degradation.
