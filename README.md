# kausaldb

[![CI Status](https://github.com/kausaldb/kausaldb/actions/workflows/ci.yml/badge.svg)](https://github.com/kausaldb/kausaldb/actions)
[![LICENSE](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

> Code is a graph. Query it. Fast.

Your codebase is a network of dependencies, not a flat directory of text files. Traditional tools like `grep` and semantic search find text, not causality. KausalDB models your code as a directed graph, enabling queries that understand software structure. It's purpose-built for high-quality context retrieval for LLMs and developers.

## Quick Start

```bash
# Setup
./scripts/install_zig.sh

# Build and run tests
./zig/zig build test
```

## The Query

KausalDB discovers and stores the causal relationships within your code. Instead of searching for text, you can query the code's structure.

```bash
# Link your codebase first
kausaldb link /path/to/codebase as myproject

# Find a specific function
kausaldb find function "authenticate_user" in myproject

# What calls this function?
kausaldb show callers "authenticate_user" in myproject

# Trace deep call chains with microsecond-level performance
kausaldb trace callees "StorageEngine.put_block" --depth 3

[+] MemtableManager.put_block_durable
[+] BlockIndex.put_block
[+] WALEntry.create_put_block
[+] GraphEdgeIndex.put_edge
└── ArenaAllocator.alloc
    └── HashMap.put
...and 47 other callees in 0.06µs
```

Pattern-based parsing extracts semantic structure from source code, storing relationships (`imports`, `calls`, `defines`, `references`) for fast graph traversal.

## Design

Built from scratch in Zig with **zero-cost abstractions**, no hidden allocations, O(1) memory cleanup and no data races by design.

**LSM-tree storage** optimized for write-heavy ingestion:
- Write-Ahead Log for durability
- In-memory indexes for fast reads
- Size-tiered compaction

**Single-threaded core** eliminates data races by design. All I/O through a Virtual File System abstraction enables deterministic testing.

## Philosophy

**Correctness over performance**. Property-based testing with deterministic simulation finds edge cases traditional unit tests miss.

**Simplicity over features**. Arena memory management, explicit control flow, and zero-cost abstractions keep the design clean and maintainable.

**Every test failure is reproducible**:
```bash
# Same seed, same destruction, same recovery. Zero flakes.
./zig/zig build test -Dseed=0xDEADBEEF
```

---

See [`docs/`](docs/) for detailed design, development guide, and testing philosophy.
