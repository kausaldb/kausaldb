# Tombstone Implementation Plan for KausalDB

## Problem Statement

KausalDB currently has a fundamental architectural issue with deletions: blocks deleted from the memtable are resurrected during compaction because SSTables have no persistent deletion state. This violates durability guarantees and causes test failures.

**Current Behavior:**
1. Block deleted from MemTable → ✓
2. Deletion recorded in WAL → ✓
3. Old SSTables still contain block → ✗
4. Compaction resurrects deleted block → ✗

**Root Cause:** Direct removal model (immediate deletion) doesn't persist deletion state through storage layers.

## Solution: Production-Grade Tombstone System

Implement deletion markers (tombstones) that persist through all storage layers until safe garbage collection, following proven LSM-tree patterns from RocksDB/Cassandra while maintaining KausalDB's simplicity.

## Design Principles

1. **Zero-Cost Abstractions:** Tombstone checks only in hot paths, compile-time optimization
2. **Explicit Over Implicit:** Clear tombstone lifecycle and shadowing rules
3. **Arena Memory Pattern:** Tombstones follow existing arena coordinator pattern
4. **Property Testable:** Mathematical invariants for correctness validation

## Implementation Phases

### Phase 1: Core Tombstone Infrastructure (Week 1)

#### 1.1 Tombstone Record Type (`src/storage/tombstone.zig`)

```zig
pub const TombstoneRecord = struct {
    block_id: BlockId,
    deletion_sequence: u64,      // Monotonic, shadows lower sequences
    deletion_timestamp: u64,     // Microseconds for GC policies
    generation: u32 = 0,         // Future: distributed consistency

    pub fn shadows_block(self: TombstoneRecord, block: ContextBlock) bool {
        return self.block_id.equals(block.id) and
               self.deletion_sequence > block.version;
    }

    pub fn can_garbage_collect(self: TombstoneRecord, current_us: u64, gc_grace_us: u64) bool {
        return current_us > self.deletion_timestamp + gc_grace_us;
    }
};
```

#### 1.2 BlockIndex Tombstone Support

```zig
// In src/storage/block_index.zig
pub const BlockIndex = struct {
    blocks: std.HashMap(BlockId, OwnedBlock, ...),
    tombstones: std.HashMap(BlockId, TombstoneRecord, ...),  // NEW
    arena_coordinator: *const ArenaCoordinator,
    // ... existing fields

    pub fn put_tombstone(self: *BlockIndex, tombstone: TombstoneRecord) !void {
        // Remove from blocks if exists
        if (self.blocks.contains(tombstone.block_id)) {
            self.remove_block(tombstone.block_id);
        }
        try self.tombstones.put(tombstone.block_id, tombstone);
    }

    pub fn find_block(self: *const BlockIndex, block_id: BlockId) ?ContextBlock {
        // Check tombstone first - critical for correctness
        if (self.tombstones.contains(block_id)) {
            return null;  // Block is deleted
        }
        if (self.blocks.getPtr(block_id)) |owned_block_ptr| {
            return owned_block_ptr.read(.temporary).*;
        }
        return null;
    }
};
```

#### 1.3 WAL Tombstone Entries

```zig
// In src/storage/wal.zig
pub const EntryType = enum(u8) {
    put_context_block = 1,
    put_graph_edge = 2,
    delete_context_block = 3,     // Existing
    tombstone_context_block = 4,  // NEW: Explicit tombstone
    // ...
};

pub fn append_tombstone(self: *WAL, tombstone: TombstoneRecord) !void {
    const entry = Entry{
        .header = EntryHeader{
            .entry_type = .tombstone_context_block,
            .payload_size = @sizeOf(TombstoneRecord),
            // ...
        },
        .payload = try serialize_tombstone(tombstone),
    };
    try self.append_entry(entry);
}
```

### Phase 2: SSTable Tombstone Integration (Week 1)

#### 2.1 SSTable Format Extension

```zig
// In src/storage/sstable.zig
pub const SSTable = struct {
    // ... existing fields
    tombstone_index: std.ArrayList(TombstoneRecord),  // NEW
    tombstone_count: u32,                             // NEW

    pub fn write_with_tombstones(
        self: *SSTable,
        blocks: []const ContextBlock,
        tombstones: []const TombstoneRecord,  // NEW
    ) !void {
        // Write header with tombstone count
        // Write blocks as before
        // Write tombstone index at end
        // Update offsets
    }

    pub fn load_tombstones(self: *SSTable) !void {
        // Read tombstone index from file
        // Populate tombstone_index array
    }
};
```

#### 2.2 SSTable Reader Tombstone Filtering

```zig
pub fn find_block(self: *const SSTable, block_id: BlockId) !?ContextBlock {
    // Check tombstones first
    for (self.tombstone_index.items) |tombstone| {
        if (tombstone.block_id.equals(block_id)) {
            return null;  // Block is tombstoned
        }
    }

    // Existing bloom filter and binary search logic
    // ...
}
```

### Phase 3: Compaction Tombstone Handling (Week 2)

#### 3.1 Compactor Tombstone Application

```zig
// In src/storage/compaction/tiered_compaction.zig
pub fn merge_sstables_with_tombstones(
    self: *TieredCompactionManager,
    input_sstables: []const *SSTable,
    output_path: []const u8,
) !void {
    // Collect all tombstones from input SSTables
    var tombstone_set = TombstoneSet.init(self.allocator);
    defer tombstone_set.deinit();

    for (input_sstables) |sstable| {
        for (sstable.tombstone_index.items) |tombstone| {
            try tombstone_set.add_tombstone(tombstone);
        }
    }

    // Merge blocks, filtering those shadowed by tombstones
    var surviving_blocks = std.ArrayList(ContextBlock).init(self.allocator);
    defer surviving_blocks.deinit();

    for (input_sstables) |sstable| {
        var iter = try sstable.iterator();
        while (try iter.next()) |block| {
            // Critical: Check if block is shadowed by any tombstone
            if (!tombstone_set.shadows_block(block)) {
                try surviving_blocks.append(block);
            }
        }
    }

    // Garbage collect old tombstones
    const current_timestamp = std.time.microTimestamp();
    const gc_grace_seconds = 7 * 24 * 3600;  // 7 days default
    _ = try tombstone_set.garbage_collect(current_timestamp, gc_grace_seconds);

    // Write compacted SSTable with surviving blocks and active tombstones
    var output_sstable = try SSTable.create(output_path);
    try output_sstable.write_with_tombstones(
        surviving_blocks.items,
        tombstone_set.tombstones.items,
    );
}
```

#### 3.2 Deletion Sequence Management

```zig
// In src/storage/engine.zig
pub const StorageEngine = struct {
    // ... existing fields
    deletion_sequence: std.atomic.Value(u64),  // NEW: Monotonic counter

    pub fn delete_block(self: *StorageEngine, block_id: BlockId) !void {
        concurrency.assert_main_thread();

        const sequence = self.deletion_sequence.fetchAdd(1, .monotonic);
        const tombstone = TombstoneRecord{
            .block_id = block_id,
            .deletion_sequence = sequence,
            .deletion_timestamp = std.time.microTimestamp(),
            .generation = 0,
        };

        // Write to WAL first (durability)
        try self.wal.append_tombstone(tombstone);

        // Apply to memtable
        try self.memtable_manager.put_tombstone(tombstone);

        // Cascade to edges
        self.graph_edge_index.remove_all_edges_for_block(block_id);
    }
};
```

### Phase 4: Recovery and Migration (Week 2)

#### 4.1 WAL Recovery with Tombstones

```zig
// In src/storage/recovery.zig
pub fn recover_from_wal(self: *Recovery, wal_path: []const u8) !void {
    var reader = try WAL.Reader.init(wal_path);
    defer reader.deinit();

    while (try reader.next_entry()) |entry| {
        switch (entry.header.entry_type) {
            .tombstone_context_block => {
                const tombstone = try deserialize_tombstone(entry.payload);
                try self.memtable.put_tombstone(tombstone);
            },
            .delete_context_block => {
                // Legacy: Convert to tombstone for compatibility
                const block_id = try deserialize_block_id(entry.payload);
                const tombstone = TombstoneRecord{
                    .block_id = block_id,
                    .deletion_sequence = entry.header.sequence,
                    .deletion_timestamp = entry.header.timestamp,
                    .generation = 0,
                };
                try self.memtable.put_tombstone(tombstone);
            },
            // ... other entry types
        }
    }
}
```

#### 4.2 Configuration

```zig
// In src/core/config.zig
pub const TombstoneConfig = struct {
    /// Seconds before tombstones can be garbage collected
    gc_grace_seconds: u64 = 7 * 24 * 3600,  // 7 days default

    /// Enable tombstone compression in SSTables
    compress_tombstones: bool = true,

    /// Maximum tombstones before forcing compaction
    max_tombstones_before_compaction: u32 = 10000,
};
```

## Testing Strategy

### Property Tests

```zig
// In src/testing/properties.zig
pub fn check_no_resurrection(model: *ModelState, storage: *StorageEngine) !void {
    // Property: Deleted blocks never reappear
    var iter = model.deleted_blocks.iterator();
    while (iter.next()) |entry| {
        const block_id = entry.key_ptr.*;
        const found = try storage.find_block(block_id);
        fatal_assert(found == null,
            "RESURRECTION VIOLATION: Deleted block {} found in storage", .{block_id});
    }
}

pub fn check_tombstone_shadowing(storage: *StorageEngine) !void {
    // Property: Tombstones correctly shadow older versions
    // ... implementation
}
```

### Integration Tests

```zig
test "deletion persists through compaction" {
    var harness = try StorageHarness.init(allocator, "test_db");
    defer harness.deinit();

    // Write blocks
    const block1 = try create_test_block("block1");
    const block2 = try create_test_block("block2");
    try harness.storage.put_block(block1);
    try harness.storage.put_block(block2);

    // Flush to SSTable
    try harness.storage.coordinate_memtable_flush();

    // Delete block1
    try harness.storage.delete_block(block1.id);

    // Trigger compaction
    try harness.trigger_compaction();

    // Verify block1 remains deleted
    const found = try harness.storage.find_block(block1.id);
    try testing.expect(found == null);

    // Verify block2 still exists
    const block2_found = try harness.storage.find_block(block2.id);
    try testing.expect(block2_found != null);
}
```

### Simulation Tests

```zig
// In tests/simulation_deletion.zig
test "simulation: heavy deletion workload" {
    const operation_mix = OperationMix{
        .put_block_weight = 40,
        .delete_block_weight = 40,  // Heavy deletions
        .find_block_weight = 20,
    };

    var runner = try SimulationRunner.init(allocator, 0xDELETE1, operation_mix, &.{});
    defer runner.deinit();

    try runner.run(10000);

    // Property validation
    try PropertyChecker.check_no_resurrection(&runner.model, runner.storage_engine);
    try PropertyChecker.check_consistency(&runner.model, runner.storage_engine);
}
```

## Performance Considerations

### Memory Overhead

- Tombstone record: 64 bytes (aligned)
- HashMap entry: ~32 bytes
- Total per deletion: ~96 bytes until GC

### CPU Impact

- Extra HashMap lookup on reads: ~20ns
- Tombstone shadowing check: ~5ns
- Compaction filtering: O(n*m) where n=blocks, m=tombstones
  - Optimize with sorted tombstone index for O(n*log(m))

### Optimization Opportunities

1. **Bloom filter for tombstones**: Skip tombstone checks when definitely not deleted
2. **Tombstone compression**: Store ranges for sequential deletions
3. **Tiered GC**: Different grace periods for different data ages

## Migration Path

### Step 1: Deploy with Backward Compatibility
- Support both `delete_context_block` and `tombstone_context_block` WAL entries
- Convert legacy deletions to tombstones during recovery

### Step 2: Monitor and Tune
- Track tombstone accumulation metrics
- Adjust GC grace period based on workload
- Monitor compaction performance

### Step 3: Remove Legacy Support
- After all WALs migrated, remove `delete_context_block` support
- Simplify recovery path

## Success Metrics

1. **Correctness**: Zero resurrection violations in 1M operation simulations
2. **Performance**: <5% read latency increase with tombstones
3. **Memory**: <10MB tombstone overhead under normal workload
4. **Reliability**: All integration tests passing with deletion scenarios

## Timeline

- **Week 1**: Core infrastructure + SSTable integration
- **Week 2**: Compaction handling + recovery
- **Week 3**: Testing + performance tuning
- **Week 4**: Production validation + documentation

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Performance regression | High | Benchmark before/after, optimize hot paths |
| Memory growth from tombstones | Medium | Aggressive GC, monitoring |
| Compaction complexity | Medium | Extensive testing, property validation |
| WAL format change | Low | Backward compatibility layer |

## References

- RocksDB DeleteRange: https://github.com/facebook/rocksdb/wiki/DeleteRange
- Cassandra Tombstones: https://docs.datastax.com/en/cassandra/3.0/cassandra/dml/dmlAboutDeletes.html
- LevelDB Compaction: https://github.com/google/leveldb/blob/main/doc/impl.md
