# Contributing

Quick start guide for KausalDB contributors.

## Setup

```bash
# Clone and setup
git clone https://github.com/kausaldb/kausaldb
cd kausaldb

# Install toolchain and git hooks
./scripts/install_zig.sh
./scripts/setup_hooks.sh
```

## Development Workflow

### Fast Iteration

```bash
./zig/zig build test           # Unit tests (~5 seconds)
./zig/zig build ci-smoke       # Format, tidy, tests (~30 seconds)
```

### Before Submitting

```bash
./zig/zig build ci-full        # Full validation (~5 minutes)
```

Pre-commit hooks automatically run formatting, tidy checks, and fast tests.

## Code Standards

### Naming

**Functions are verbs**:

```zig
pub fn find_block(id: BlockId) !?ContextBlock     // GOOD
pub fn block_finder(id: BlockId) !?ContextBlock   // BAD
```

**Special prefixes**:

- `try_*` for error unions: `try_parse_header()`
- `maybe_*` for optionals: `maybe_find_cached()`

### Memory

Use arena coordinator pattern:

```zig
// Coordinator survives struct copies
pub const Engine = struct {
    arena: *ArenaAllocator,
    coordinator: *ArenaCoordinator,
};
```

### Comments

Explain **why**, not what:

```zig
// BAD: Increment counter
counter += 1;

// GOOD: WAL requires sequential entry numbers for recovery
counter += 1;
```

### Testing

Use harnesses, not manual setup:

```zig
// Standard pattern
var harness = try StorageHarness.init(allocator, "test_db");
defer harness.deinit();
```

Manual setup only with justification:

```zig
// Manual setup required because: Recovery testing needs two separate
// StorageEngine instances sharing the same VFS
```

## Testing Requirements

All changes must include:

- [ ] Unit tests (if adding new functions)
- [ ] Integration tests (if changing module interactions)
- [ ] Deterministic reproduction (tests must be reproducible with seeds)

## Debugging

Memory issues use tiered approach:

1. **Quick**: `./zig/zig build test -Denable-memory-guard=true`
2. **Deep**: `./zig/zig build test -fsanitize-address`
3. **Interactive**: `lldb ./zig-out/bin/test`

## Commit Guidelines

Format:

```
type(scope): brief summary

Optional: Context and rationale.

- Specific change 1
- Specific change 2

Optional: Impact, result achieved.
```

**Types**: `feat`, `fix`, `refactor`, `test`, `docs`, `perf`, `chore`

**Example**:

```
feat(storage): implement arena coordinator pattern

Prevents struct copying corruption in Zig by using heap-allocated
arenas with stable coordinator interfaces.

- Add ArenaCoordinator with pointer-based interface
- Replace embedded ArenaAllocator with coordinator pattern
- Update StorageEngine to use coordinator for O(1) cleanup

Impact: Eliminates segmentation faults from arena corruption.
```

## Pull Requests

**Before submitting**:

- [ ] `./zig/zig build ci-full` passes
- [ ] Performance targets still met
- [ ] Documentation updated (if changing APIs)
- [ ] Tests added for new functionality

**Review focuses on**:

- Correctness and safety
- Performance impact
- Code clarity and maintainability
- Test coverage
- Alignment with architectural principles

## Getting Help

- **Setup issues**: Check [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)
- **Architecture questions**: Read [docs/DESIGN.md](docs/DESIGN.md)
- **Testing patterns**: See [docs/TESTING.md](docs/TESTING.md)
- **Code style**: Review [docs/STYLE.md](docs/STYLE.md)

## Philosophy

KausalDB prioritizes:

1. **Correctness over features**
2. **Explicit over magical**
3. **Simple over clever**
4. **Deterministic testing over mocking**

Every line of code should be obviously correct or comprehensively tested.
