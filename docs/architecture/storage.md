# Storage Architecture

KausalDB's storage engine implements an LSM-tree optimized for write-heavy workloads with graph relationships.

## LSM-Tree Design

### Components

```
┌──────────────────────────────────────────────┐
│                Write Path                    │
│                                              │
│  Client → WAL → BlockIndex → GraphEdgeIndex  │
│            ↓                                 │
│         fsync()                              │
└──────────────────────────────────────────────┘
                    ↓ (flush threshold)
┌──────────────────────────────────────────────┐
│               SSTable (L0)                   │
│  Immutable, sorted, bloom filter, checksums  │
└──────────────────────────────────────────────┘
                    ↓ (compaction)
┌──────────────────────────────────────────────┐
│            Tiered SSTables (L1+)             │
│         Size-based compaction strategy       │
└──────────────────────────────────────────────┘
```

### Write Path

1. **WAL Append**: Every write goes to WAL first (durability)
2. **Memtable Insert**: BlockIndex (HashMap) for fast lookups
3. **Edge Index Update**: Bidirectional edge tracking
4. **Response**: After WAL fsync completes

### Read Path

1. **BlockIndex**: Check in-memory blocks first (hot data)
2. **SSTable Bloom Filters**: Skip SSTables without block
3. **SSTable Binary Search**: Find block in sorted index
4. **Disk Read**: Fetch block from SSTable

## Write-Ahead Log (WAL)

### Segment Management

```zig
pub const WALSegment = struct {
    const SEGMENT_SIZE = 64 * 1024 * 1024;  // 64MB
    const HEADER_SIZE = 64;                 // Aligned

    magic: [4]u8 = "WALG",
    version: u32 = 1,
    sequence_start: u64,
    entry_count: u32,
    checksum: u64,  // CRC-64 of entries
};
```

### Entry Format

```
┌────────────────┬──────────────┬─────────────┬──────────────┐
│ Checksum (8B)  │ Type (4B)    │ Size (4B)   │ Payload      │
├────────────────┼──────────────┼─────────────┼──────────────┤
│ CRC-64         │ PUT_BLOCK    │ Payload len │ Block bytes  │
│                │ DELETE_BLOCK │             │              │
│                │ PUT_EDGE     │             │ Edge bytes   │
└────────────────┴──────────────┴─────────────┴──────────────┘
```

### Recovery Process

```zig
pub fn recover(self: *WAL) !void {
    // 1. Find all segments
    const segments = try self.find_segments();

    // 2. Validate checksums
    for (segments) |segment| {
        if (!self.validate_segment(segment)) {
            self.corruption_tracker.record_failure();
            continue;
        }
    }

    // 3. Replay valid entries
    for (segments) |segment| {
        try self.replay_segment(segment);
    }
}
```

## BlockIndex (Memtable)

### Structure

```zig
pub const BlockIndex = struct {
    blocks: HashMap(BlockId, OwnedBlock),
    coordinator: ArenaCoordinator,
    memory_usage: u64,

    const FLUSH_THRESHOLD = 16 * 1024 * 1024;  // 16MB
};
```

### Memory Management

- Arena allocation for all block data
- O(1) cleanup on flush via coordinator.reset()
- Ownership tracking via BlockOwnership enum

### Concurrency

Single-threaded with assertion checks:

```zig
pub fn put_block(self: *BlockIndex, block: ContextBlock) !void {
    concurrency.assert_main_thread();
    // Implementation
}
```

## SSTable Format

### File Layout

```
┌───────────────────────────────────┐
│          Header (64 bytes)        │
├───────────────────────────────────┤
│                                   │
│            Block Data             │
│          (sorted by ID)           │
│                                   │
├───────────────────────────────────┤
│                                   │
│            Block Index            │
│      (BlockId → offset, size)     │
│                                   │
├───────────────────────────────────┤
│           Bloom Filter            │
├───────────────────────────────────┤
│         Footer (32 bytes)         │
└───────────────────────────────────┘
```

### Header Structure

```zig
pub const SSTableHeader = struct {
    magic: [4]u8 = "SSTB",
    version: u32 = 1,
    block_count: u32,
    min_block_id: BlockId,
    max_block_id: BlockId,
    index_offset: u64,
    bloom_filter_offset: u64,
    checksum: u64,
};
```

### Bloom Filter

- Size: ~10 bits per block
- False positive rate: 0.1%
- Hash functions: 7 (optimal for size)

## Graph Edge Index

### Bidirectional Index

```zig
pub const GraphEdgeIndex = struct {
    outgoing_edges: HashMap(BlockId, ArrayList(GraphEdge)),
    incoming_edges: HashMap(BlockId, ArrayList(GraphEdge)),
    edge_count: u64,
};
```

### Operations

```zig
// O(1) edge insertion
pub fn put_edge(self: *GraphEdgeIndex, edge: GraphEdge) !void {
    try self.outgoing_edges[edge.source_id].append(edge);
    try self.incoming_edges[edge.target_id].append(edge);
}

// O(1) edge lookup
pub fn find_outgoing_edges(self: *GraphEdgeIndex, source: BlockId) []GraphEdge {
    return self.outgoing_edges.get(source) orelse &.{};
}
```

## Compaction Strategy

### Size-Tiered Compaction

```zig
pub const TieredCompactionManager = struct {
    tiers: [MAX_TIERS]Tier,

    const Tier = struct {
        level: u8,
        sstables: ArrayList(*SSTable),
        total_size: u64,

        const TIER_SIZE_RATIO = 4;  // Each tier 4x larger
    };

    pub fn should_compact(self: *TieredCompactionManager, tier: u8) bool {
        const t = &self.tiers[tier];
        return t.sstables.items.len >= 4;  // Merge 4 SSTables
    }
};
```

### Compaction Process

1. **Trigger**: 4+ SSTables in same tier
2. **Merge**: Create iterator over all SSTables
3. **Write**: New SSTable in next tier
4. **Cleanup**: Delete input SSTables

## Corruption Detection

### CorruptionTracker

```zig
pub const CorruptionTracker = struct {
    consecutive_failures: u32,
    total_failures: u64,

    const CORRUPTION_THRESHOLD = 4;

    pub fn record_failure(self: *CorruptionTracker) void {
        self.consecutive_failures += 1;
        self.total_failures += 1;

        if (self.consecutive_failures >= CORRUPTION_THRESHOLD) {
            fatal_assert(false, "Systematic corruption detected", .{});
        }
    }
};
```

### Validation Points

- WAL entry checksums (CRC-64)
- SSTable header validation
- Block checksum verification
- Index bounds checking

## Performance Tuning

### Write Optimization

- **WAL Batching**: Group writes before fsync
- **Arena Allocation**: No per-allocation overhead
- **Lazy Deletion**: Mark deleted, clean during compaction

### Read Optimization

- **Bloom Filters**: Skip 99.9% of unnecessary reads
- **Block Cache**: LRU cache for hot blocks
- **Parallel Search**: Check multiple SSTables concurrently (future)

### Memory Bounds

```zig
const Config = struct {
    memtable_size: u64 = 16 * 1024 * 1024,     // 16MB
    block_cache_size: u64 = 64 * 1024 * 1024,  // 64MB
    wal_buffer_size: u64 = 4 * 1024 * 1024,    // 4MB
    max_open_files: u32 = 1000,
};
```

## Metrics

```zig
pub const StorageMetrics = struct {
    writes_completed: u64,
    reads_completed: u64,
    bytes_written: u64,
    bytes_read: u64,
    flushes_completed: u64,
    compactions_completed: u64,
    wal_syncs: u64,
    cache_hits: u64,
    cache_misses: u64,
    bloom_filter_useful: u64,
};
```

## Trade-offs

### What We Optimize For

- **Write throughput**: LSM-tree, WAL batching
- **Graph traversal**: Bidirectional edge index
- **Memory predictability**: Arena allocation
- **Recovery speed**: Sequential WAL replay

### What We Don't Optimize For

- **Random updates**: Require full rewrite
- **Space efficiency**: Write amplification from compaction
- **Read latency variance**: Compaction can cause spikes
- **Large values**: No special handling for blobs

This architecture delivers 68µs writes and 23ns reads (hot data) while maintaining full durability and crash consistency.
