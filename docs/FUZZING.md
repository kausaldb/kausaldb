# FUZZING

The testing philosophy is built on finding bugs before they become problems. The fuzzing framework is a critical part of this strategy. It combines coverage-guided fuzzing with deterministic simulation engine to systematically discover parsing errors, logic bugs, and correctness violations.

## Philosophy

The goal of the fuzzing framework is to ensure system stability and correctness under unpredictable conditions. We follow two main principles:

1.  **Deterministic Reproduction:** Every crash is reproducible. The fuzzer uses a deterministic, seeded pseudo-random number generator. A failure can be reproduced exactly by reusing the seed from the crash report.
2.  **Structured Fuzzing:** We don't just throw random bytes at the system. The fuzzer targets specific components with structured inputs to test different layers of the system, from low-level data parsing to high-level logical invariants.

## How It Works

The core of the framework is the **Fuzzer engine** (`src/fuzz/main.zig`). It generates sequences of operations based on a seed and applies them to a specific **Target**.

*   **Targets:** A target is a specific component or property being tested. We have targets for parsing (`storage_parse`), logic (`storage_logic`), and system-wide properties (`durability`).
*   **Input Generation:** The fuzzer generates semi-structured, deterministic inputs based on the seed.
*   **Crash Handling:** When a crash (a panic or an unhandled error) occurs, the fuzzer automatically:
    1.  **Categorizes** the error (e.g., parse error, assertion failure).
    2.  **Deduplicates** the crash based on a stack hash to avoid redundant reports.
    3.  **Saves** the exact input that caused the crash to the `fuzz-corpus/` directory, along with the seed needed for reproduction.

## How to Run the Fuzzer

The build system provides two main targets for fuzzing.

### 1. Quick Fuzzing (for CI and Pre-Commit)

This runs a short, fast fuzzing session across all targets. It is designed to catch low-hanging fruit without slowing down the development workflow.

```bash
# Run a quick fuzzing session
./zig/zig build fuzz-quick
```

### 2. Extended Fuzzing (for Deep Bug Hunts)

This target allows you to run a longer, more intensive fuzzing session on a specific target.

```bash
# Basic syntax
./zig/zig build fuzz [target] [options]
```

**Common Targets:**

*   `storage_parse`: Tests deserialization of on-disk formats (SSTables, WAL entries).
*   `storage_logic`: Tests sequences of storage operations for logical errors.
*   `query_logic`: Tests the query engine for correctness bugs.
*   `durability`: A property-based test that verifies data survives simulated crashes.
*   `all`: Runs all fuzzing targets sequentially.

**Example Commands:**

```bash
# Run 100,000 iterations on the storage logic target
./zig/zig build fuzz storage_logic --iterations 100000

# Run a verbose session on all targets with a specific seed
./zig/zig build fuzz all --seed 0xDEADBEEF --verbose
```

## Reproducing a Crash

When a fuzzing session finds a crash, it will save a file to the `fuzz-corpus/crashes/` directory. The file will contain the input data and metadata, including the seed.

To reproduce the crash, run the fuzzer with the same target and seed, but with only one iteration:

```bash
# Reproduce a crash from a saved report
./zig/zig build fuzz [target] --seed [seed_from_crash_report] --iterations 1
```

This will run the exact operation sequence that caused the failure, allowing you to attach a debugger and analyze the root cause.
