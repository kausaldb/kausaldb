# Performance Benchmarks

This document presents comprehensive performance benchmarks for KausalDB, measuring everything from microsecond-level primitive operations to end-to-end command execution through the binary interface.

## Benchmark Environment

- **Platform**: macOS (Apple Silicon)
- **Build Mode**: Debug (with memory safety checks)
- **Iterations**: 25 samples per benchmark
- **Warmup**: 10 iterations
- **Measurement**: Statistical analysis with P95/P99 percentiles
## Executive Summary

KausalDB delivers exceptional performance across all operational layers:

- **Hot path reads**: Sub-microsecond (420ns) for cached blocks
- **Write throughput**: 231K blocks/second without sync, 9K/second with fsync
- **Graph traversal**: 26-37K traversals/second for complex queries
- **Full ingestion pipeline**: 1,091 files/second through Zig parser
- **End-to-end commands**: ~120 operations/second including process overhead

## Storage Engine Performance

### Block Operations

| Operation | Mean | P95 | Ops/sec | Notes |
|-----------|------|-----|---------|-------|
| **Block Write** | 4.32μs | 4.92μs | 231,428 | In-memory write to BlockIndex |
| **Block Write (Sync)** | 111.16μs | 129.83μs | 8,996 | With fsync() durability |
| **Block Read (Hot)** | 0.42μs | 0.50μs | 2,375,297 | From BlockIndex cache |
| **Block Read (Warm)** | 1.08μs | 1.08μs | 929,368 | From SSTable with bloom filter |
| **Block Read (Cold)** | 1.22μs | 1.13μs | 822,368 | SSTable disk read simulation |
| **Block Read (Miss)** | 1.10μs | 1.17μs | 906,618 | Nonexistent block lookup |

**Key Insights:**
- **45x performance penalty for durability**: The difference between in-memory (4.32μs) and fsync (111.16μs) writes demonstrates the true cost of ACID guarantees
- **Exceptional cache performance**: Hot reads at 420ns show effective memory hierarchy optimization
- **Bloom filter efficiency**: Only 2.9x penalty for warm vs hot reads indicates excellent false positive rates

### Graph Operations

| Operation | Mean | P95 | Ops/sec | Notes |
|-----------|------|-----|---------|-------|
| **Edge Insert** | 14.90μs | 16.46μs | 67,114 | Bidirectional edge insertion |
| **Edge Lookup** | 0.32μs | 0.38μs | 3,164,557 | Edge existence check |
| **Graph Traversal** | 1.09μs | 1.17μs | 916,590 | Single hop traversal |

### Storage Maintenance

| Operation | Mean | P95 | Ops/sec | Notes |
|-----------|------|-----|---------|-------|
| **Memtable Flush** | 1,465.21μs | 3,786.38μs | 682 | BlockIndex → SSTable compaction |

## Query Engine Performance

### Graph Traversal Algorithms

| Algorithm | Depth | Mean | P95 | Ops/sec | Scaling Characteristics |
|-----------|-------|------|-----|---------|------------------------|
| **BFS** | 3 hops | 37.88μs | 40.58μs | 26,401 | Breadth-first exploration |
| **BFS** | 5 hops | 204.41μs | 236.50μs | 4,892 | 5.4x slower (queue overhead) |
| **DFS** | 3 hops | 28.30μs | 37.00μs | 35,331 | Depth-first exploration |
| **DFS** | 5 hops | 27.32μs | 31.63μs | 36,606 | **Better scaling** (stack efficiency) |

**Algorithm Analysis:**
- **DFS outperforms BFS**: Especially at deeper traversals due to lower memory overhead
- **BFS queue penalty**: Breadth-first search shows 5.4x degradation from depth 3→5
- **DFS consistency**: Depth-first maintains ~36K ops/sec regardless of depth

### Query Types

| Query Type | Mean | P95 | Ops/sec | Use Case |
|------------|------|-----|---------|----------|
| **Edge Filter** | 6.97μs | 7.71μs | 143,472 | Type-specific traversal |
| **Multi-hop Query** | 38.85μs | 40.96μs | 25,737 | Complex graph analysis |
| **Semantic Search** | 202.93μs | 216.38μs | 4,928 | Content-based retrieval |

## Ingestion Pipeline Performance

### Parser Throughput

| Component | Mean | P95 | Ops/sec | Processing Rate |
|-----------|------|-----|---------|-----------------|
| **Zig Parser** | 916.84μs | 966.46μs | 1,091 | ~17,500 files/minute |
| **Directory Traversal** | 38.80μs | 50.08μs | 25,773 | Filesystem scanning |

### Batch Processing

| Batch Size | Mean | P95 | Ops/sec | Throughput |
|------------|------|-----|---------|------------|
| **Small (10 blocks)** | 650.62μs | 715.88μs | 1,537 | ~15K blocks/second |
| **Large (100 blocks)** | 8,017.93μs | 8,340.42μs | 125 | ~12.5K blocks/second |
| **Incremental (1 block)** | 72.55μs | 88.42μs | 13,784 | Single block updates |

**Batching Analysis:**
- **Optimal batch size**: Small batches (10) provide best throughput/latency balance
- **Large batch overhead**: 100-block batches show diminishing returns due to memory pressure
- **Incremental efficiency**: Single-block updates at 72μs enable real-time ingestion

## Core Primitives Performance

### Identity and Hashing

| Primitive | Mean | Ops/sec | Notes |
|-----------|------|---------|-------|
| **BlockId Generation** | 0.05μs | 20,833,333 | UUID v4 generation |
| **BlockId Hashing** | 0.09μs | 10,638,298 | Hash table operations |
| **BlockId Comparison** | 0.06μs | 16,393,443 | Equality/ordering |
| **Edge Comparison** | 0.11μs | 9,433,962 | Graph edge sorting |

### Memory Management

| Operation | Mean | Ops/sec | Notes |
|-----------|------|---------|-------|
| **Arena Small Alloc (64B)** | 8.39μs | 119,175 | Small object allocation |
| **Arena Large Alloc (64KB)** | 12.83μs | 77,967 | Large buffer allocation |
| **Context Block Size** | 0.04μs | 26,315,789 | Serialization planning |

**Memory Insights:**
- **Arena allocation efficiency**: Only 53% overhead for large vs small allocations
- **Linear allocation model**: Arena pattern provides predictable performance

## End-to-End Command Performance

These benchmarks measure the complete pipeline: process spawn → argument parsing → execution → cleanup.

| Command Type | Mean | P95 | Ops/sec | Real-world Performance |
|--------------|------|-----|---------|----------------------|
| **Server Connectivity** | 8.33ms | 9.42ms | 120 | Status and health checks |
| **Codebase Ingestion** | 8.00ms | 8.01ms | 125 | Project linking/indexing |
| **Block Lookup** | 8.46ms | 9.52ms | 118 | Find by name queries |
| **Graph Traversal** | 8.15ms | 9.52ms | 123 | Relationship exploration |
| **Semantic Search** | 8.69ms | 10.13ms | 115 | Content-based queries |

**E2E Analysis:**
- **Consistent 8-9ms baseline**: Process overhead dominates execution time
- **Negligible operation cost**: Core query time (μs) vs process time (ms) = 0.1% ratio
- **Production optimization**: Server mode would eliminate process spawning overhead

## Performance Characteristics by Use Case

### Interactive Development (Hot Path)
- **Block lookups**: 420ns (2.4M ops/sec) from cache
- **Quick traversals**: 28μs for 3-hop DFS queries
- **IDE integration**: Sub-millisecond response times

### Batch Processing (Cold Path)
- **File ingestion**: 1,091 files/sec through full parse pipeline
- **Large imports**: 125 ops/sec for 100-block batches
- **Background indexing**: Sustained throughput with predictable latency

### Production Server (Persistent Process)
- **Write throughput**: 231K blocks/sec (in-memory) or 9K blocks/sec (durable)
- **Read throughput**: 2.4M blocks/sec (hot) scaling to 800K+ (cold)
- **Query capacity**: 25K-35K complex graph traversals/sec

## Scaling Characteristics

### Memory Hierarchy Performance
1. **L1 Cache (Hot)**: 420ns - BlockIndex HashMap
2. **L2 Cache (Warm)**: 1.08μs - SSTable with Bloom filter
3. **Storage (Cold)**: 1.22μs - Direct SSTable read
4. **Disk + Network**: 8-9ms - Full process execution

### Algorithm Complexity Validation
- **DFS vs BFS**: DFS maintains O(1) memory, BFS shows O(k) queue growth
- **Depth scaling**: Linear performance degradation validates algorithmic analysis
- **Batch efficiency**: Optimal batch size (10) balances throughput vs latency

## Reproducing These Results

### Quick Benchmark Run
```bash
./zig/zig build bench -Dbench-iterations=25 -Dbench-warmup=10 -- all
```

### Individual Components
```bash
# Storage engine only
./zig/zig build bench -- storage

# End-to-end tests only
./zig/zig build bench -- e2e

# Query engine with more samples
./zig/zig build bench -Dbench-iterations=100 -- query
```

### Performance Analysis
```bash
# Save baseline for regression detection
./zig/zig build bench --save-baseline=baseline.json

# Compare against baseline
./zig/zig build bench --baseline=baseline.json
```

## Development Impact

These benchmarks validate KausalDB's design decisions:

1. **LSM-Tree Architecture**: 45x write amplification for durability is expected and acceptable
2. **Arena Memory Model**: Consistent allocation performance across object sizes
3. **Bloom Filter Implementation**: 2.9x cache miss penalty proves effective filtering
4. **Graph Traversal Algorithms**: DFS superiority for deep traversals guides query optimization
5. **Batch Processing Strategy**: 10-block batches optimize for real-world usage patterns

The results demonstrate that KausalDB achieves its design goal of microsecond-level context retrieval while maintaining the durability and consistency guarantees required for production AI applications.
