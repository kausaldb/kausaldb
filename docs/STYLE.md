# Code Style

Disciplined code patterns for KausalDB. These conventions are derived from the actual codebase and enforce architectural principles.

## Naming Conventions

### Functions: Verb-First Actions

```zig
// GOOD: Action-first, clear intent
pub fn find_block(id: BlockId) !?ContextBlock
pub fn coordinate_memtable_flush(self: *StorageEngine) !void
pub fn validate_memory_hierarchy(self: *const StorageEngine) void

// BAD: Noun-first or unclear intent
pub fn block_finder(id: BlockId) !?ContextBlock
pub fn memory_hierarchy_validator(self: *const StorageEngine) void
```

### Lifecycle Methods: Standard Names Only

```zig
pub fn init()           // COLD: Memory allocation only, no I/O
pub fn startup()        // HOT: I/O operations, resource acquisition
pub fn shutdown()       // Graceful termination with cleanup
pub fn deinit()         // Memory deallocation
```

**Forbidden legacy names**: `initialize()`, `start()`, `stop()`, `cleanup()`

### Uncertainty Prefixes

**Error unions**: Use `try_` prefix for operations that might fail

```zig
pub fn try_parse_header(data: []const u8) !Header
pub fn try_connect_to_server(address: []const u8) !Connection
```

**Optionals**: Use `maybe_` prefix for operations that might return null

```zig
pub fn maybe_find_cached_block(id: BlockId) ?ContextBlock
pub fn maybe_get_next_event() ?Event
```

### No Get/Set Prefixes

Prefer direct field access for simple data retrieval. Functions should perform **actions**, not just return values.

We're not coding in Java here.

```zig
// BAD: Verbose prefixes
pub fn get_block_count() u32
pub fn set_memory_limit(limit: u64) void

// GOOD: Direct field access
const count = block.count;
engine.memory_limit = 1024;
```

## Import Organization

Manually organized imports with consistent grouping. **No automated formatting** - maintained through code review.

### Standard Import Pattern

```zig
// 1. Standard library
const builtin = @import("builtin");
const std = @import("std");

// 2. Internal modules (alphabetically sorted)
const assert_mod = @import("../core/assert.zig");
const concurrency = @import("../core/concurrency.zig");
const error_context = @import("../core/error_context.zig");
const memory = @import("../core/memory.zig");
const vfs = @import("../core/vfs.zig");

// 3. Re-declarations (common items)
const assert_fmt = assert_mod.assert_fmt;
const fatal_assert = assert_mod.fatal_assert;
const testing = std.testing;

// 4. Type aliases
const ArenaCoordinator = memory.ArenaCoordinator;
const BlockId = context_block.BlockId;
const ContextBlock = context_block.ContextBlock;
```

### Import Rules

- **Blank lines separate groups**
- **Use descriptive module names**: `assert_mod` not `assert` for modules
- **Two-phase import pattern**: Import module, then extract types/functions
- **Alphabetical within groups**
- **No direct field access from imports**

## Comments: Why, Not What

Code should be self-documenting. Comments explain reasoning, trade-offs, and non-obvious constraints.

### Required Comments

```zig
// GOOD: Explains design rationale
// Arena coordinator prevents struct copying corruption in Zig.
// Direct ArenaAllocator embedding would corrupt internal pointers.
storage_arena: *ArenaAllocator,
coordinator: *ArenaCoordinator,

// GOOD: Documents performance trade-offs
// Linear scan outperforms binary search for small SSTable count (<16).
// Cache locality and reduced branching overhead provide better performance.
for (self.sstables.items) |sstable| { ... }

// GOOD: Explains domain constraints
// WAL requires sequential entry numbers for proper recovery ordering.
// Batch incrementing would break crash recovery guarantees.
entry_sequence += 1;
```

### Forbidden Comments

```zig
// BAD: Restates obvious code
counter += 1; // Increment counter

// BAD: Commented-out code
// old_function_call();

// BAD: Development artifacts (must be removed before commit)
// TODO: optimize this later
// FIXME: handle edge case
// HACK: temporary workaround
```

### File Documentation

Use `//!` for module documentation:

```zig
//! Storage engine coordination and main public API.
//!
//! Implements the main StorageEngine struct that coordinates between all
//! storage subsystems: BlockIndex (memtable), GraphEdgeIndex, WAL, SSTables,
//! and compaction.
//!
//! Key responsibilities:
//! - Coordinate writes through WAL -> BlockIndex -> SSTable flush pipeline
//! - Orchestrate reads from BlockIndex -> SSTables with proper precedence
//! - Manage background compaction to maintain read performance
```

## Memory Management: Arena Coordinator Pattern

### Pattern Implementation

```zig
pub const StorageEngine = struct {
    // Heap-allocated arena prevents copying corruption
    storage_arena: *std.heap.ArenaAllocator,
    arena_coordinator: *ArenaCoordinator,  // Stable interface

    pub fn coordinate_memtable_flush(self: *StorageEngine) !void {
        // ... flush operations ...
        self.arena_coordinator.reset();  // O(1) cleanup
    }
};
```

### Memory Rules

1. **Coordinators own exactly one arena**
2. **Submodules receive coordinator interfaces, not direct arena access**
3. **Never embed ArenaAllocator in copyable structs**
4. **Use coordinator.reset() for O(1) bulk cleanup**

## Error Handling

### Explicit Error Handling

```zig
// BAD: Hiding errors
const file = try vfs.open(path) orelse unreachable;

// GOOD: Explicit error context
const file = vfs.open(path) catch |err| {
    error_context.log_storage_error(err, error_context.StorageContext{
        .operation = "open_wal_file",
        .file_path = path,
    });
    return StorageError.FileOpenFailed;
};
```

### Assertion Levels

```zig
assert_fmt(condition, "Debug-only validation: {}", .{details});     // Debug builds only
fatal_assert(condition, "Critical invariant violation", .{});       // Always active
```

### Error Context Pattern

```zig
// Wrap errors with contextual information
operation() catch |err| {
    error_context.log_storage_error(err, error_context.StorageContext{
        .operation = "specific_operation",
        .block_id = block.id,
        .file_path = file_path,
    });
    return err;
};
```

## State Management

### State Machine Pattern

```zig
pub const StorageState = enum {
    initialized,
    running,
    flushing,
    compacting,
    stopping,
    stopped,

    pub fn transition(self: *StorageState, new_state: StorageState) void {
        // Validate legal transitions
        // Log state changes in debug builds
    }
};
```

### Concurrency Assertions

```zig
pub fn put_block(self: *StorageEngine, block: ContextBlock) !void {
    concurrency.assert_main_thread();  // Single-threaded design
    // Implementation...
}
```

## Testing Patterns

### Harness Usage

```zig
// GOOD: Use standardized harnesses
test "storage operations" {
    var harness = try StorageHarness.init(allocator, "test_db");
    defer harness.deinit();

    try harness.startup();
    defer harness.shutdown();

    // Test implementation
}

// Only skip harness with explicit justification:
// Manual setup required because: Testing recovery needs two separate
// StorageEngine instances sharing the same VFS to validate WAL recovery
```

### Test Naming

```zig
// GOOD: Describes scenario and expected outcome
test "coordinate_memtable_flush resets arena memory to zero"
test "WAL recovery restores exact pre-crash state"
test "graph edge index maintains bidirectional consistency"

// BAD: Vague or implementation-focused
test "test_storage_stuff"
test "memtable_works"
```

## File Organization

### Directory Structure

```
src/
├── core/           # Foundation: types, VFS, memory, concurrency
├── storage/        # LSM engine: WAL, memtable, SSTables, compaction
├── query/          # Graph traversal, filtering, optimization
├── sim/            # Deterministic simulation framework
├── tests/          # Integration tests with internal API access
└── dev/            # Development tools: benchmarks, fuzz, debug
```

### Module Dependencies

- **Core modules**: No dependencies on higher-level modules
- **Storage modules**: Depend only on core modules
- **Query modules**: Depend on storage and core modules
- **Test modules**: Can depend on any internal module

## Performance Guidelines

### Measurement First

```zig
// Measure performance with statistical sampling
var sampler = StatisticalSampler.init();
for (0..iterations) |_| {
    const start = std.time.nanoTimestamp();
    try operation();
    const elapsed = std.time.nanoTimestamp() - start;
    try sampler.add_sample(elapsed);
}
try sampler.validate_percentile(95, threshold_ns);
```

### Hot Path Optimization

```zig
// Critical paths include performance hints
pub fn find_block(self: *const StorageEngine, id: BlockId) !ContextBlock {
    concurrency.assert_main_thread();  // Debug-only overhead

    // Hot path: check memtable first
    if (self.memtable_manager.find_block(id)) |block| {
        return block;
    }

    // Cold path: search SSTables
    return self.sstable_manager.find_block(id);
}
```

## Code Organization Rules

### Error Types

```zig
pub const StorageError = error{
    BlockNotFound,
    ChecksumMismatch,
    CorruptedHeader,
    WriteStalled,
    WriteBlocked,
} || WALError || VFSError;
```

### Public API Structure

- **kausaldb.zig**: External API for applications
- **internal.zig**: Internal API for development tools
- Module-specific exports only in module files

## Enforcement

### Pre-commit Hooks

Automatically check:

- `zig fmt` formatting compliance
- Naming convention validation via `zig build tidy`
- Fast unit test execution
- Commit message format validation

### Code Review Requirements

- [ ] Follows verb-first function naming
- [ ] Comments explain "why" not "what"
- [ ] Uses appropriate test harness
- [ ] Error handling is explicit with context
- [ ] Memory management follows arena coordinator pattern
- [ ] Import organization follows standard pattern
- [ ] No TODO/FIXME comments in production code

### Build System Integration

```bash
# Check style compliance
./zig/zig build fmt-check    # Verify formatting
./zig/zig build tidy         # Check naming conventions

# Fix style issues
./zig/zig build fmt-fix      # Auto-fix formatting
```

## Philosophy

**Explicit over implicit**: Every allocation, state change, and error path should be visible in the code.

**Consistent over clever**: Use established patterns even if a "clever" approach might be shorter.

**Readable over compact**: Code is read far more often than it's written. Optimize for comprehension.

**Safe over fast**: Use assertions and error context to catch bugs early. Performance optimizations come after correctness.

These style rules exist to prevent classes of bugs and make the codebase maintainable by multiple developers. Deviations require explicit justification in code review.
