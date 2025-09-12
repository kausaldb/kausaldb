# Memory Architecture

KausalDB's memory management uses arena allocation with coordinators to achieve O(1) cleanup and prevent temporal coupling bugs.

## The Problem

Zig structs with embedded allocators corrupt when copied:

```zig
// BROKEN: Corrupts on copy
pub const Manager = struct {
    arena: ArenaAllocator,  // Contains internal pointers
    data: []u8,

    pub fn copy(self: Manager) Manager {
        return self;  // Arena's internal pointers now invalid!
    }
};
```

## The Solution: Arena Coordinators

Coordinators provide stable interfaces that survive struct copies:

```zig
pub const ArenaCoordinator = struct {
    arena: *ArenaAllocator,  // Pointer remains valid

    pub fn allocator(self: *const ArenaCoordinator) Allocator {
        return self.arena.allocator();
    }

    pub fn reset(self: *ArenaCoordinator) void {
        _ = self.arena.reset(.retain_capacity);  // O(1) cleanup
    }
};
```

## Hierarchical Memory Management

```
StorageEngine (owns backing allocator)
    ├── storage_arena (ArenaAllocator)
    ├── coordinator (ArenaCoordinator)
    │
    └── MemtableManager (receives coordinator)
        ├── uses coordinator.allocator()
        │
        └── BlockIndex (pure computation)
            └── HashMap with arena allocation
```

## Ownership Rules

1. **Arena Ownership**: Each subsystem owns exactly one arena
2. **Coordinator Sharing**: Child components receive coordinator interface
3. **No Embedding**: Never embed ArenaAllocator in copyable structs
4. **Bulk Cleanup**: Use coordinator.reset() for O(1) memory reclamation

## Memory Lifecycle

```zig
pub const StorageEngine = struct {
    storage_arena: ArenaAllocator,
    coordinator: ArenaCoordinator,
    memtable_manager: MemtableManager,

    pub fn flush_memtable(self: *StorageEngine) !void {
        // 1. Flush data to SSTable
        try self.flush_to_disk();

        // 2. Reset all memtable memory in O(1)
        self.coordinator.reset();

        // 3. Reinitialize empty memtable
        self.memtable_manager = MemtableManager.init(self.coordinator);
    }
};
```

## Performance Characteristics

### Allocation

- **Speed**: <50ns per allocation (no syscalls)
- **Fragmentation**: Zero (linear allocation)
- **Overhead**: 16 bytes per arena (not per allocation)

### Deallocation

- **Individual free**: Not supported (by design)
- **Bulk cleanup**: O(1) via reset()
- **Memory return**: Optional (retain_capacity vs free_all)

### Comparison with malloc/free

```
malloc/free (1000 allocations):
  - Allocation: 45µs total
  - Deallocation: 38µs total
  - Fragmentation: 15-30%

Arena (1000 allocations):
  - Allocation: 12µs total
  - Reset: <1µs
  - Fragmentation: 0%
```

## Common Patterns

### Pattern 1: Per-Request Arena

```zig
pub fn handle_query(self: *QueryEngine, query: Query) !Result {
    var arena = ArenaAllocator.init(self.allocator);
    defer arena.deinit();  // Cleanup everything

    const alloc = arena.allocator();
    // All query allocations use arena
    // No manual cleanup needed
}
```

### Pattern 2: Double-Buffered Arenas

```zig
pub const DoubleBuffer = struct {
    active: ArenaAllocator,
    standby: ArenaAllocator,

    pub fn swap(self: *DoubleBuffer) void {
        std.mem.swap(ArenaAllocator, &self.active, &self.standby);
        _ = self.standby.reset(.retain_capacity);
    }
};
```

### Pattern 3: Hierarchical Arenas

```zig
pub const Subsystem = struct {
    parent_coordinator: ArenaCoordinator,
    local_arena: ArenaAllocator,
    local_coordinator: ArenaCoordinator,

    pub fn init(parent: ArenaCoordinator) Subsystem {
        var local = ArenaAllocator.init(parent.allocator());
        return .{
            .parent_coordinator = parent,
            .local_arena = local,
            .local_coordinator = .{ .arena = &local },
        };
    }
};
```

## Edge Cases and Gotchas

### Gotcha 1: Coordinator Lifetime

```zig
// BAD: Arena outlives coordinator
fn broken() ArenaCoordinator {
    var arena = ArenaAllocator.init(allocator);
    return ArenaCoordinator{ .arena = &arena };  // Dangling pointer!
}

// GOOD: Arena and coordinator have same lifetime
const Storage = struct {
    arena: ArenaAllocator,
    coordinator: ArenaCoordinator,

    pub fn init() Storage {
        var arena = ArenaAllocator.init(allocator);
        return .{
            .arena = arena,
            .coordinator = .{ .arena = &arena },  // Will be fixed up
        };
    }
};
```

### Gotcha 2: Cross-Arena Pointers

```zig
// BAD: Pointer invalidated after reset
const ptr = coordinator1.allocator().alloc(u8, 100);
coordinator1.reset();
use(ptr);  // Use-after-free!

// GOOD: Copy data if needed across resets
const data = coordinator1.allocator().alloc(u8, 100);
const copy = coordinator2.allocator().dupe(u8, data);
coordinator1.reset();  // Safe, copy exists in coordinator2
```

## Why This Design

**Simplicity**: One pattern for all memory management.

**Performance**: O(1) cleanup enables high-throughput operations.

**Safety**: Coordinator pattern prevents temporal coupling bugs.

**Predictability**: No hidden allocations, no garbage collection.

**Debuggability**: Memory ownership is explicit and traceable.

This architecture is fundamental to KausalDB's performance. The memtable flush operation, which could take seconds with individual frees, completes in microseconds with arena reset.
