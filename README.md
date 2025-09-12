# kausaldb

[![CI Status](https://github.com/kausaldb/kausaldb/actions/workflows/ci.yml/badge.svg)](https://github.com/kausaldb/kausaldb/actions)
[![LICENSE](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

> Code is a graph. Query it.

Model your codebase as a directed graph of dependencies and relationships. Built for LLMs or human that need to understand software structure, not just grep through text.

## Quick Start

```bash
# Setup
./scripts/install_zig.sh
./scripts/setup_hooks.sh

# Build and run
./zig/zig build test
./zig/zig build run
```

## What it does

Your codebase isn't a flat directory of text files. It's a network of dependencies with causal relationships. Grep and semantic search find text. KausalDB finds causality.

```bash
# Link your codebase first
kausaldb link /path/to/codebase as myproject

# Find a specific function
kausaldb find function "authenticate_user" in myproject

# What calls this function?
kausaldb show callers "authenticate_user" in myproject

# Trace deep call chains
kausaldb trace callees "main" --depth 5
```

Pattern-based parsing extracts semantic structure from source code.

Stores relationships (`imports`, `calls`, `defines`, `references`) for fast graph traversal.

## Design

**LSM-tree storage** optimized for write-heavy ingestion:
- Write-Ahead Log for durability
- In-memory indexes for fast reads
- Size-tiered compaction

**Single-threaded core** eliminates data races by design. All I/O through Virtual File System abstraction enabling deterministic testing.

**Performance**: 68µs writes, 23ns reads, 1.2µs graph traversal

## Philosophy

**Correctness over performance**. Property-based testing with deterministic simulation finds edge cases traditional unit tests miss.

**Simplicity over features**. Arena memory management, explicit control flow, zero-cost abstractions.

**Every test failure reproducible**:
```bash
./zig/zig build test -Dseed=0xDEADBEEF
```

---

See [`docs/`](docs/) for detailed design, development guide, and testing philosophy.
