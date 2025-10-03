# KausalDB Performance Characteristics

**Last Updated:** 2025-10-03
**Benchmark Environment:** macOS Darwin 24.6.0, ReleaseFast build
**Methodology:** 1000 iterations with 100 warmup cycles

---

## Summary

KausalDB delivers nanosecond-scale reads for hot data and sub-microsecond graph traversals, suitable for real-time LLM context retrieval.

**Key Metrics (ReleaseFast):**

- Hot block reads: 0.05μs (50ns) - P99: 0.13μs
- Nonexistent lookups: 0.04μs (40ns) - P99: 0.08μs
- Edge lookups: 0.03μs (30ns) - P99: 0.04μs
- Graph traversal (DFS depth 3): 0.70μs - P99: 0.79μs
- Block writes: 0.73μs - P99: 2.42μs

**Performance vs Debug Build:**

- Block reads: **8.6x faster** (0.43μs → 0.05μs)
- DFS traversal: **9.9x faster** (6.94μs → 0.70μs)
- Block writes: **6.5x faster** (4.72μs → 0.73μs)

---

## Storage Layer

### Block Operations

```
Block Write            0.73μs    (P99: 2.42μs)      1.37M ops/sec
Block Read (Hot)       0.05μs    (P99: 0.13μs)      21.7M ops/sec
Block Read (Warm)      434.08μs  (P99: 491.92μs)    2.3K ops/sec
Block Read (Cold)      15.49μs   (P99: 17.08μs)     64.6K ops/sec
Block Read (Nonexist)  0.04μs    (P99: 0.08μs)      22.7M ops/sec
Block Write (Sync)     41.77μs   (P99: 71.08μs)     23.9K ops/sec
```

Hot reads (memtable) achieve **50ns latency** - 21.7M operations per second. Warm reads (SSTable) are ~8680x slower due to simulated disk I/O. Bloom filters provide near-memtable performance for nonexistent lookups, preventing expensive SSTable scans.

### Edge Operations

```
Edge Insert    1501.51μs  (P99: 1617.96μs)  666 ops/sec
Edge Lookup    0.03μs     (P99: 0.04μs)     37M ops/sec
```

Edge lookups achieve **30ns latency** - faster than block reads due to in-memory adjacency list structure. Edge inserts are slower as they update both source and target adjacency lists plus WAL durability.

### Memtable Operations

```
Memtable Flush    472.81μs   (P99: 782.88μs)   2.1K ops/sec
```

Memtable flush includes serialization, checksum calculation, bloom filter creation, and disk write. O(1) arena cleanup ensures predictable performance.

---

## Query Layer

### Graph Traversal

```
BFS (depth 3)    1.65μs     (P99: 1.79μs)     606K ops/sec
BFS (depth 5)    8.50μs     (P99: 9.17μs)     117K ops/sec
DFS (depth 3)    0.70μs     (P99: 0.75μs)     1.4M ops/sec
DFS (depth 5)    0.62μs     (P99: 0.67μs)     1.6M ops/sec
```

DFS is 2.4x faster than BFS for same depth due to better memory locality. DFS maintains sub-microsecond performance across depths. BFS shows worse scaling but provides shortest-path guarantees.

### Query Operations

```
Edge Filter by Type    0.17μs     (P99: 0.21μs)     5.8M ops/sec
Multi-hop Query        1.63μs     (P99: 1.75μs)     613K ops/sec
Semantic Search        19.83μs    (P99: 21.21μs)    50K ops/sec
Graph Traversal        0.10μs     (P99: 0.12μs)     10M ops/sec
```

Simple queries (edge filtering, single-hop traversal) are sub-microsecond. Multi-hop queries scale linearly with depth. Semantic search requires full content scan.

---

## Ingestion

```
Zig Parser Throughput    33.21μs    (P99: 37.83μs)    30K files/sec
```

Parser throughput includes lexing, parsing, AST traversal, and block generation. Suitable for large codebase ingestion (10K files in ~333ms).

---

## Architecture Trade-offs

### LSM-Tree Characteristics

**Write Performance:**

- Sequential writes to WAL and memtable
- Batch flushes to SSTables
- O(1) arena cleanup on flush

**Read Performance:**

- Hot path (memtable): 0.05μs
- Cold path (SSTable): 15-434μs
- Bloom filters prevent unnecessary SSTable scans

The LSM-tree optimizes for write-heavy ingestion workloads. Read amplification occurs when checking multiple SSTable levels. Performance is excellent when queries hit the memtable.

### Graph Traversal

**Strengths:**

- Fast edge lookups (0.03μs)
- DFS maintains sub-microsecond performance across depths
- Multi-hop queries in microsecond range

**Limitations:**

- BFS scales poorly with depth
- Random access pattern doesn't leverage LSM-tree's sequential optimization
- SSTable reads create latency spikes for cold data

---

## Methodology

**Environment:**

- OS: macOS Darwin 24.6.0
- Build: ReleaseFast mode
- Iterations: 1000 per benchmark
- Warmup: 100 iterations

**Workload:**

- Storage: In-memory SimulationVFS
- Query: Pre-populated graph with known structure
- Ingestion: Real Zig source files
- SimulationVFS eliminates actual disk I/O
- Small dataset size may not reflect large-scale behavior
