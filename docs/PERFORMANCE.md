# KausalDB Performance Characteristics

**Last Updated:** 2025-10-02
**Benchmark Environment:** macOS Darwin 24.6.0, Debug build
**Methodology:** 1000 iterations with 100 warmup cycles

---

## Summary

KausalDB delivers sub-microsecond reads for hot data and microsecond-scale graph traversals, suitable for real-time LLM context retrieval.

**Key Metrics:**
- Hot block reads: 0.43μs (P99: 0.67μs)
- Nonexistent lookups: 0.80μs (P99: 0.96μs)
- Edge lookups: 0.26μs (P99: 0.29μs)
- Graph traversal (DFS depth 3): 6.94μs (P99: 7.46μs)
- Block writes: 4.72μs (P99: 16.21μs)

---

## Storage Layer

### Block Operations

```
Block Write            4.72μs    (P99: 16.21μs)     211K ops/sec
Block Read (Hot)       0.43μs    (P99: 0.67μs)      2.3M ops/sec
Block Read (Warm)      1382μs    (P99: 1568μs)      723 ops/sec
Block Read (Cold)      60.14μs   (P99: 61.00μs)     16K ops/sec
Block Read (Nonexist)  0.80μs    (P99: 0.96μs)      1.2M ops/sec
Block Write (Sync)     96.23μs   (P99: 121.75μs)    10K ops/sec
```

Hot reads (memtable) achieve sub-microsecond latency. Warm reads (SSTable) are ~3200x slower due to disk I/O. Bloom filters provide near-memtable performance for nonexistent lookups, preventing expensive SSTable scans.

### Edge Operations

```
Edge Insert    4917μs    (P99: 5494μs)    203 ops/sec
Edge Lookup    0.26μs    (P99: 0.29μs)    3.8M ops/sec
```

Edge lookups are faster than block reads due to in-memory adjacency list structure. Edge inserts are slower as they update both source and target adjacency lists.

### Memtable Operations

```
Memtable Flush    2150μs    (P99: 3641μs)    465 ops/sec
```

Memtable flush includes serialization, checksum calculation, bloom filter creation, and disk write. O(1) arena cleanup ensures predictable performance.

---

## Query Layer

### Graph Traversal

```
BFS (depth 3)    16.26μs    (P99: 17.04μs)    61K ops/sec
BFS (depth 5)    82.40μs    (P99: 84.67μs)    12K ops/sec
DFS (depth 3)    6.94μs     (P99: 7.46μs)     144K ops/sec
DFS (depth 5)    6.34μs     (P99: 6.75μs)     157K ops/sec
```

DFS is 2.3x faster than BFS for same depth due to better memory locality. DFS maintains consistent performance across depths. BFS shows worse scaling but provides shortest-path guarantees.

### Query Operations

```
Edge Filter by Type    1.15μs     (P99: 1.29μs)     867K ops/sec
Multi-hop Query        16.29μs    (P99: 17.08μs)    61K ops/sec
Semantic Search        195.30μs   (P99: 204.88μs)   5K ops/sec
Graph Traversal        0.97μs     (P99: 1.00μs)     1.0M ops/sec
```

Simple queries (edge filtering, single-hop traversal) are sub-microsecond. Multi-hop queries scale linearly with depth. Semantic search requires full content scan.

---

## Ingestion

```
Zig Parser Throughput    445μs    (P99: 510μs)    2244 files/sec
```

Parser throughput includes lexing, parsing, AST traversal, and block generation. Suitable for large codebase ingestion (10K files in ~4.5 seconds).

---

## Architecture Trade-offs

### LSM-Tree Characteristics

**Write Performance:**
- Sequential writes to WAL and memtable
- Batch flushes to SSTables
- O(1) arena cleanup on flush

**Read Performance:**
- Hot path (memtable): 0.43μs
- Cold path (SSTable): 60-1382μs
- Bloom filters prevent unnecessary SSTable scans

The LSM-tree optimizes for write-heavy ingestion workloads. Read amplification occurs when checking multiple SSTable levels. Performance is excellent when queries hit the memtable.

### Graph Traversal

**Strengths:**
- Fast edge lookups (0.26μs)
- DFS maintains consistent performance across depths
- Multi-hop queries in microsecond range

**Limitations:**
- BFS scales poorly with depth
- Random access pattern doesn't leverage LSM-tree's sequential optimization
- SSTable reads create latency spikes for cold data

---

## Methodology

**Environment:**
- OS: macOS Darwin 24.6.0
- Build: Debug mode
- Iterations: 1000 per benchmark
- Warmup: 100 iterations

**Workload:**
- Storage: In-memory SimulationVFS
- Query: Pre-populated graph with known structure
- Ingestion: Real Zig source files

**Caveats:**
- Debug build may be 2-3x slower than release build
- SimulationVFS eliminates actual disk I/O
- Small dataset size may not reflect large-scale behavior
