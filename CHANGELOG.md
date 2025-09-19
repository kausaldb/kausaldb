# Changelog

## [0.1.0] - 2025-08-19

Initial release. Core storage and query engine.

### Features

- LSM-Tree storage engine with WAL durability
- Graph traversal with typed edges
- Arena coordinator memory pattern
- Deterministic simulation testing

### Performance

Realistic end-to-end benchmark results (Apple M1, macOS ARM64, ReleaseFast):

- **Ingestion Pipeline** (`link` + `sync`): P95 69ms
- **Find Function Queries**: P95 429ms
- **Show File Queries**: P95 505ms
- **Trace Call Chain Queries**: P95 1,107ms

Performance level: **ACCEPTABLE** for development tooling (< 1s P95 for most operations).
Run `./zig/zig build bench -- e2e` to reproduce on your system.

Additional optimizations:

- O(1) memory cleanup through arena coordinator

### Known Limitations

- Single-node only
- Basic query operations only
- No authentication

### Dependencies

- Zig 0.15.1
- Zero runtime dependencies
