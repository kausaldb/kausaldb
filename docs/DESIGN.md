# Design

KausalDB is a graph database designed for AI context retrieval from codebases. Every design decision prioritizes correct graph relationships and fast traversal over general-purpose database features.

## Core Data Model

### ContextBlock

The atomic unit of knowledge - a versioned piece of code or documentation with:

- 128-bit unique ID
- Source URI (file path or URL)
- JSON metadata (language, function name, etc.)
- Content (the actual code or text)
- Version number

### GraphEdge

Typed, directional relationships between blocks:

- Source and target BlockIds
- EdgeType enum
  (`imports`, `calls`, `defines`, `references`)
- No additional metadata (kept simple)

This captures semantic relationships in code, not just text similarity.

## Storage Architecture

### LSM-Tree Implementation

**Components**:

- **WAL** (Write-Ahead Log): Append-only, segmented, CRC-64 checksums
- **BlockIndex**: In-memory HashMap for fast block lookups
- **GraphEdgeIndex**: Bidirectional edge storage for traversal
- **SSTables**: Immutable sorte
  d files with bloom filters
- **TieredCompactionManager**: Size-based compaction strategy

**Write Path**:

```
Client → WAL append → BlockIndex + GraphEdgeIndex → Response
                ↓
              fsync() for durability
```

**Read Path**:

```
BlockIndex (hot) → SSTable bloom filter → SSTable lookup → Disk
```

The LSM-tree design optimizes for write throughput since AI analysis generates massive amounts of context data.

### Memory Management: Arena Coordinators

Solves Zig-specific problem where embedded ArenaAllocators corrupt on struct copy:

```zig
pub const StorageEngine = struct {
    storage_arena: *ArenaAllocator,        // Heap allocated
    arena_coordinator: *ArenaCoordinator,  // Stable interface

    pub fn flush_memtable(self: *StorageEngine) !void {
        // ... flush data to SSTable ...
        self.arena_coordinator.reset();  // O(1) cleanup
    }
};
```

**Benefits**:

- O(1) bulk memory cleanup
- No memory fragmentation
- Eliminates temporal coupling bugs
- 20-30% performance improvement over malloc/free

## Query Engine

### Query Types

**Direct Lookup**: Find block by ID through BlockIndex → SSTables

**Graph Traversal**: Follow edges with configurable:

- Depth limits (prevent infinite loops)
- Direction (outgoing/incoming/both)
- Edge type filters
- Resource bounds (max nodes)

**Filtered Queries**: Apply predicates during traversal to minimize data movement

### Traversal Implementation

Uses BFS with bounded collections to prevent unbounded memory growth:

```zig
var visited = BoundedHashSet(BlockId, MAX_NODES);
var queue = BoundedQueue(BlockId, MAX_NODES);
```

All resource limits are compile-time constants.

## Concurrency Model

**Single-threaded core** with async I/O. No mutexes, no data races, no subtle timing bugs.

Every storage operation includes `concurrency.assert_main_thread()` to catch violations in debug builds.

**Why single-threaded?** Graph traversal is CPU-bound, not I/O-bound. Parallel traversal would add synchronization overhead for marginal benefit.

## Virtual File System

All I/O goes through VFS abstraction:

```zig
pub const VFS = union(enum) {
    real: ProductionVFS,       // Production filesystem
    simulation: SimulationVFS, // Deterministic testing
};
```

This enables:

- Deterministic failure injection with seeds
- 100x faster tests (all in memory)
- Systematic exploration of failure scenarios
- Byte-for-byte reproducible failures

## Testing Philosophy

### Three-Tier Architecture

1. **Unit tests** (in source files): Pure functions, no I/O, <1 second total
2. **Integration tests** (`src/tests/`): Module interactions via test harnesses
3. **E2E tests** (`tests/`): Binary interface, subprocess execution

### Test Harnesses

Standardized setup patterns:

- **StorageHarness**: Storage engine with SimulationVFS
- **QueryHarness**: Query engine with storage backend
- **ProductionHarness**: Real filesystem for performance testing

### Deterministic Simulation

Property-based testing with deterministic workload generation:

```zig
// Every test failure is reproducible
var generator = WorkloadGenerator.init(allocator, 0xDEADBEEF);
// Test failed with seed 0xDEADBEEF
// Reproduce: ./zig/zig build test -Dseed=0xDEADBEEF
```

**Properties tested**:

- Data durability under crashes
- Graph consistency under concurrent operations
- Linearizability of operations
- Memory safety with arena patterns

## Ingestion Pipeline

Parses source code to extract ContextBlocks and GraphEdges:

**Supported languages**: Zig, Rust, Python, TypeScript (via tree-sitter)

**Pipeline stages**:

1. **Parse**: Extract AST from source files
2. **Context**: Identify logical units (functions, structs, imports)
3. **Resolve**: Build relationships between units
4. **Index**: Store blocks and edges in storage engine

## Performance Characteristics

### Measured Performance

- Block writes: 68µs (P95) with fsync enabled
- Block reads (hot): 23ns from BlockIndex
- Graph traversal: 1.2µs (P95) for 3-hop cached
- Memory per write: 1.6KB including all overhead

### Design Trade-offs

**Optimized for**:

- Write throughput (LSM-tree)
- Graph traversal speed (bidirectional indexes)
- Memory predictability (arena allocation)
- Deterministic testing (VFS abstraction)

**Not optimized for**:

- Random updates (requires full rewrite)
- Large scans (no columnar storage)
- Complex transactions (single-node only)
- SQL workloads (graph-native API)

## API Structure

**Public API** (`kausaldb.zig`):

- Core types: ContextBlock, BlockId, GraphEdge
- Storage: StorageEngine, Config
- Query: QueryEngine, TraversalQuery
- Server: HTTP handler

**Internal API** (`internal.zig`):

- Development tools: benchmarks, fuzz testing
- Testing utilities: harnesses, simulation
- Advanced debugging features

## Development Tools

- **Benchmarks**: Statistical performance measurement
- **Fuzz testing**: Random input validation
- **Simulation**: Deterministic failure injection
- **Debug utilities**: Memory tracking, assertion checking

## Why These Choices

**LSM-tree over B-tree**: Write-heavy workload from AI analysis

**Single-threaded**: Eliminates entire class of concurrency bugs

**Arena allocation**: Predictable performance, O(1) cleanup

**Zig language**: No hidden handling, compile-time safety

**Property testing**: Finds edge cases humans miss, reproducible with seeds

## Current Status

**Implemented**:

- Complete LSM storage engine
- Graph indexing and traversal
- Deterministic simulation framework
- Code ingestion for 4 languages
- HTTP API server
- Comprehensive test suite

**In Progress**:

- Performance optimization
- Extended language support
- Query optimization

The system is designed for correctness first, performance second, features third. Every component is thoroughly tested through deterministic simulation.
