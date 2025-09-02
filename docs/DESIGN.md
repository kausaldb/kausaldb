# Design

## Philosophy

KausalDB is opinionated. It's not general-purpose. Every decision optimizes for one thing: modeling code as a queryable graph for AI reasoning.

**Simplicity is the prerequisite for reliability.** We build simple systems that work correctly under hostile conditions.

## Core Principles

**Zero-Cost Abstractions**
Safety has zero runtime overhead in release builds. With 0.08µs block reads, every cycle matters.

**No Hidden Mechanics**
All control flow, memory allocation, and component lifecycles are explicit. You can trace every operation.

**Single Static Binary**
Zero dependencies. Deployment is `scp` and `./kausaldb`.

**Deterministic Testing**
We run production code against simulated disk corruption, network partitions, and power loss. Byte-for-byte reproducible.

## Architecture

### Single-Threaded Core

No data races by design. Async I/O handles concurrency. State transitions are trivial to reason about.

### Memory Safety Architecture

**Arena Coordinator Pattern**: Stable interfaces survive arena operations.

```zig
pub const StorageEngine = struct {
    storage_arena: ArenaAllocator,
    coordinator: ArenaCoordinator,  // Stable interface survives arena ops

    pub fn flush_memtable(self: *StorageEngine) !void {
        // ... flush to disk ...
        self.coordinator.reset();  // All memtable memory gone in O(1)
    }
};
```

**Memory Guard System**: Debug builds include comprehensive protection:

- Canary values detect buffer overflows
- Poison patterns catch use-after-free
- Allocation tracking finds leaks
- Zero overhead in release builds

**Validation Layer**: Systematic corruption detection:

- Block validation with CRC64 checksums
- WAL entry integrity checks
- SSTable header validation
- Graph edge consistency verification

### Three-Tier Test Architecture

**Unit Tests** (in source files):

- Test individual functions
- No I/O or external dependencies
- Sub-second execution

**Integration Tests** (`src/tests/`):

- Test module interactions
- Full API access via testing harness
- Deterministic simulation support

**E2E Tests** (`tests/`):

- Binary interface only
- Subprocess execution
- Real-world scenarios

### LSM-Tree Storage

Write-optimized architecture:

- Append-only WAL for durability
- In-memory memtable for recent writes
- Immutable SSTables on disk
- Background compaction without blocking writes

### Virtual File System

All I/O through VFS abstraction. Production uses real filesystem. Tests use deterministic simulation at memory speed.

### Defensive Programming

**Assertion Levels**:

- `assert()`: Debug-only checks
- `fatal_assert()`: Always-active safety checks
- `comptime_assert()`: Compile-time validation

**Invariant Enforcement**:

- Pre-condition validation at API boundaries
- Post-condition verification on critical paths
- State machine invariant checking

### Context Engine

**Batch-Oriented Query Processing**: Moves complexity from client to server. Instead of multiple round-trip queries, clients submit complete context requests executed atomically with bounded resources.

**Three-Phase Execution**:

1. **Anchor Resolution**: Convert query anchors (block IDs, entity names, file paths) to concrete block references with workspace validation
2. **Graph Traversal**: Execute bounded traversal rules to build context graph within resource limits
3. **Result Packaging**: Assemble final context with workspace isolation guarantees

**Bounded Resource Pools**: Compile-time limits prevent unbounded memory growth:

```zig
pub const ContextQuery = struct {
    anchors: BoundedArrayType(QueryAnchor, 4),     // Max 4 starting points
    rules: BoundedArrayType(TraversalRule, 2),     // Max 2 traversal rules
    max_total_nodes: u32 = 1000,                   // Global node limit
};
```

**Arena-per-Query Pattern**: Each context query gets isolated arena memory with O(1) cleanup:

```zig
pub fn execute_context_query(self: *ContextEngine, query: ContextQuery) !ContextResult {
    self.coordinator.reset();                       // O(1) cleanup from previous query
    self.query_arena = ArenaAllocator.init(self.allocator);

    // Build bounded context graph...
    defer self.query_arena.deinit();               // O(1) cleanup guarantee
}
```

**Workspace Isolation**: All context operations strictly enforce workspace boundaries to prevent cross-contamination between projects or codebases.

**Multi-Anchor Support**:

- **Block ID**: Direct block lookup (fastest path)
- **Entity Name**: Semantic search within workspace scope
- **File Path**: File-based context resolution with metadata matching

- Pre/post condition validation
- State machine verification
- Bounds checking on all operations

## Data Model

**ContextBlock**: Atomic unit of code knowledge. 128-bit ID, source URI, JSON metadata.

**GraphEdge**: Typed relationship between blocks (`calls`, `imports`, `defines`).

This captures causal relationships, not just text similarity.

## Performance Targets

- Block writes: <100µs (measured 68µs)
- Block reads: <1µs (measured 23ns)
- Graph traversal: <100µs for 3 hops (measured 130ns)
- Memory growth: <2KB per write (measured 1.6KB)
- Recovery: <1s per GB

These are production-achievable targets. Current implementation meets or exceeds all thresholds.

## Development Infrastructure

**Unified Developer Tool** (`tools/dev.zig`):

- Cross-platform development commands
- Test filtering and safety options
- Local CI pipeline simulation
- Performance benchmarking
- Code quality checks

**Test Harness Framework**:

- `TestHarness`: Base functionality
- `StorageHarness`: Storage with VFS
- `QueryHarness`: Query with storage
- `SimulationHarness`: Failure injection
- `BenchmarkHarness`: Performance measurement

**Build System**:

- Simple three-tier test organization
- Flexible filtering with `--filter` flag
- Automatic test discovery
- Memory safety validation

## Why Zig

No hidden control flow. No hidden allocations. Compile-time metaprogramming. The language philosophy aligns with ours: explicit over magical.

## v0.1.0 Readiness

**Robustness**:

- Memory guard catches corruption
- Validation layer detects invariant violations
- Deterministic tests cover failure scenarios
- Arena pattern prevents leaks

**Developer Experience**:

- Unified tooling via `tools/dev.zig`
- Comprehensive test harnesses
- Clear three-tier test architecture
- Detailed development documentation

**Production Quality**:

- Performance targets exceeded
- Memory safety validated
- Crash recovery tested
- CI/CD pipeline automated
