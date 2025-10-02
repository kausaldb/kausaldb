# DESIGN

The goal is to create a simple, reliable, and fast graph database. This document provides a high-level overview of the architectural decisions that support this philosophy.

## Core Architectural Pillars

The design of `kausaldb` rests on four pillars:

1.  **LSM-Tree Storage Engine:** For fast, write-heavy ingestion.
2.  **Single-Threaded Core:** To eliminate data races by design.
3.  **Virtual File System (VFS):** To enable deterministic, simulation-first testing.
4.  **Arena-Based Memory Management:** For `O(1)` cleanup and memory safety.

---

### 1. LSM-Tree Storage Engine

Log-Structured Merge-Tree (LSM-Tree) offers good performance for write-heavy operations like codebase ingestion. Read performance might become a problem.

Our implementation consists of:

*   **Write-Ahead Log (WAL):** Ensures durability. All writes are first appended to the WAL before being acknowledged. See `src/storage/wal.zig`.
*   **Memtable (`BlockIndex`):** An in-memory index that stores the most recent writes for fast lookups. See `src/storage/block_index.zig`.
*   **SSTables (Sorted String Tables):** When the memtable fills, its contents are flushed to immutable, sorted files on disk. See `src/storage/sstable.zig`.
*   **Size-Tiered Compaction:** A background process merges SSTables to reduce read amplification and reclaim space from deleted or updated entries. See `src/storage/tiered_compaction.zig`.

#### Core Correctness Guarantees

The storage engine provides the following guarantees, proven by explicit tests in `src/tests/scenarios/explicit_correctness.zig`:

*   **Tombstone Permanence:** Deleted blocks cannot be resurrected after flushing to SSTables. Tombstones with higher sequence numbers correctly shadow blocks in older SSTables, ensuring deletions are permanent even before compaction physically removes the data.
*   **MVCC Semantics:** Tombstones correctly shadow blocks based on sequence ordering: `tombstone(seq=N)` shadows `block(seq=M)` if and only if `N > M`. This implements proper Multi-Version Concurrency Control.
*   **LSM Read Precedence:** The memtable strictly takes precedence over SSTables in reads. Higher sequence numbers always win, and tombstones in memory correctly shadow all older data on disk.

---

### 2. Single-Threaded Core

The core database engine is single-threaded. This is a deliberate design choice that provides several key benefits:

*   **No Data Races:** It completely eliminates an entire class of complex concurrency bugs.
*   **Simplicity:** State management is dramatically simpler without locks, mutexes, or atomic operations in the hot path.
*   **Performance:** It avoids the overhead of synchronization primitives and context switching.

Concurrency is handled at the network layer using an event loop, which dispatches requests to the single-threaded core. All core logic is enforced to run on the main thread via `assert_main_thread()` in debug builds. See `src/core/concurrency.zig`.

---

### 3. Virtual File System (VFS)

Every I/O operation in KausalDB goes through a Virtual File System (VFS) abstraction. This is the cornerstone of our testing philosophy.

*   **ProductionVFS:** In a release build, this VFS implementation maps directly to the operating system's file APIs. See `src/core/production_vfs.zig`.
*   **SimulationVFS:** During testing, we use an in-memory VFS that simulates a real filesystem. See `src/sim/simulation_vfs.zig`.

This abstraction allows us to run the *exact same production code* in a deterministic, controlled simulation. We can inject faults like disk I/O errors, torn writes, and data corruption to test the system's resilience under hostile conditions without relying on mocks.

---

### 4. Arena-Based Memory Management

KausalDB uses arena allocators for managing the memory of short-lived, high-volume objects, such as query results and memtable contents. This provides two major advantages:

1.  **`O(1)` Cleanup:** When a memtable is flushed or a query completes, all associated memory is freed in a single, constant-time operation by resetting the arena.
2.  **Memory Safety:** We use an **Arena Coordinator Pattern** to prevent a common class of use-after-free bugs in Zig that arise from copying structs containing arena allocators. The coordinator provides a stable interface to a heap-allocated arena, ensuring that memory operations remain valid even if parent structs are copied. See `src/core/memory.zig`.
