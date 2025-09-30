# STYLE

This guide outlines the projects code style and conventions. These boundaries make it easier to write simple code.

## 1. Formatting

**Rule:** Always use `zig fmt`.

All code is formatted with the standard Zig code formatter. The pre-commit hook will run this automatically.

```bash
./zig/zig build fmt
```

## 2. Naming Conventions

*   **Functions are Verbs:** Function names must describe the action they perform.

    ```zig
    // GOOD: Clear and action-oriented
    fn find_block(id: BlockId) !?ContextBlock;
    fn flush_memtable(self: *Memtable) !void;

    // BAD: Vague or noun-based
    fn block_finder(id: BlockId) !?ContextBlock;
    fn memtable_flush(self: *Memtable) !void;
    ```

*   **No `get_` / `set_` Prefixes:** For simple field access, use direct member access. Reserve functions for actions with side effects or complex logic.

*   **Prefixes for Optionals and Errors:**
    *   `try_*`: Use for functions that return an error union (e.g., `try_parse_header`).
    *   `maybe_*`: Use for functions that return an optional (e.g., `maybe_find_cached_block`).

## 3. Comments

**Rule:** Explain the **why**, not the **what**.

Code should be self-documenting. Comments are for providing context that the code cannot, such as design rationale, trade-offs, or non-obvious constraints.

```zig
// BAD:
// Find all blocks with name
try find_blocks_by_name("inject");

// GOOD:
// For the expected number of SSTables (<16), the cache locality
// and make linear scan faster than binary search.
for (self.sstables.items) |sstable| {
    // ...
}
```

## 4. Error Handling

*   **Use Error Unions:** All fallible operations must return an error union (`!void`, `![]u8`, etc.).
*   **No Panics in Production Code:** Panics are reserved for unrecoverable state corruption or logic errors found during testing. Use `fatal_assert` for these cases.
*   **Structured Error Context:** When returning an error from a complex operation, wrap it with a context struct from `src/core/error_context.zig` to provide rich debugging information.

## 5. Memory Management

**Rule:** Use the **Arena Coordinator Pattern** for all major subsystems.

To prevent memory corruption from struct copies, we do not embed `std.heap.ArenaAllocator` directly in structs. Instead, we use a coordinator pattern:

1.  The `ArenaAllocator` is allocated on the heap.
2.  An `ArenaCoordinator` struct holds a stable pointer to this heap-allocated arena.
3.  Subsystems are given a pointer to the `ArenaCoordinator`.

This ensures that all memory operations go through a stable interface, even if parent structs are copied.

See `src/core/memory.zig` for the implementation.

## 6. Assertions

*   **Debug-Only Invariants:**
    ```zig
    // Validating internal logic during development.
    // Zero cost in release builds.
    std.debug.assert(index < array.len); // Invariant: Index must be in bounds
    ```

*   **Fatal Errors:**
    ```zig

    // This is a unrecoverable failure. Could be a data corruption or critical invariant.
    if (header.magic != MAGIC) {
        std.debug.panic("SSTable header corrupted: invalid magic number", .{});
    }
    ```

*   **Compile-Time Invariants:**
    ```zig
    comptime {
        if (@sizeOf(BlockHeader) != 64) {
            // Validate invariants during compile time
            @compileError("BlockHeader must be 64 bytes");
        }
    }
    ```

