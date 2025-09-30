# TESTING

The testing philosophy is built on a single, non-negotiable principle: **every test failure must be reproducible**. We achieve this through a "simulation-first" approach that allows us to test the real production code under deterministic, hostile conditions.

The test suite is structured to provide fast feedback during development and comprehensive validation in CI.

1.  **Unit Tests (`./zig/zig build test`):**
    *   **Location:** Embedded directly within the source files they test (e.g., `src/core/types.zig`).
    *   **Purpose:** Fast, isolated checks for individual functions and data structures. They run in seconds and should be executed frequently.

2.  **Scenario & Integration Tests (`./zig/zig build test-all`):**
    *   **Location:** `src/tests/scenarios/`
    *   **Purpose:** These are property-based tests that run the entire storage engine within a deterministic simulation framework. They verify that the system's high-level properties (like durability) hold true across thousands of operations and failure scenarios.

3.  **End-to-End (E2E) Tests (`./zig/zig build test-e2e`):**
    *   **Location:** `tests/`
    *   **Purpose:** These tests validate the final compiled binary, including the CLI interface and client-server communication. They are the slowest and run as part of the full test suite.

## Deterministic Simulation Testing

The core of the testing strategy is the **Virtual File System (VFS)** and the **SimulationRunner**.

*   **Virtual File System (VFS):** All I/O is performed through the VFS abstraction. In tests, we use `SimulationVFS`, an in-memory filesystem that gives us complete control over I/O behavior.
*   **Fault Injection:** The `SimulationVFS` can be configured to simulate I/O errors, disk corruption, and torn writes at specific, deterministic points during a test run.
*   **SimulationRunner:** This test harness (`src/testing/harness.zig`) orchestrates the tests. It generates a deterministic sequence of operations (writes, reads, deletes) based on a seed and applies them to both the real storage engine and a simple, correct `ModelState`.

## Property-Based Testing

Instead of testing for specific outcomes, we test for **properties** that must always be true. The primary property checker is in `src/testing/properties.zig`.

The most important property is **durability:** *all data acknowledged as written must be retrievable with its content intact, even after simulated crashes.*

During a test run, the `SimulationRunner` continuously compares the state of the real `StorageEngine` against the `ModelState`. Any divergence between the two indicates a correctness bug.

## How to Write a Test

1.  **Unit Tests:** For new functions or data structures, add a `test "..." { ... }` block directly in the source file. Use `std.testing` to make assertions.
2.  **Scenario Tests:** For new features or bug fixes that affect the storage engine, add a new test to a file in `src/tests/scenarios/`.
    *   Use the `SimulationRunner` to define a workload (`OperationMix`).
    *   Provide a deterministic seed.
    *   Configure fault injection if testing failure recovery.
    *   Run a sequence of operations.
    *   Call `runner.verify_consistency()` to validate the system against the model.

**Example Scenario Test:**
```zig
test "scenario: data survives a crash" {
    var runner = try SimulationRunner.init(
        allocator,
        0xDEADBEEF, // Deterministic seed
        operation_mix,
        &.{}, // No fault injection
    );
    defer runner.deinit();

    // Run 100 operations to build up state
    try runner.run(100);

    // Simulate a hard crash and recovery
    try runner.simulate_crash_recovery();

    // Verify all data was recovered correctly
    try runner.verify_consistency();
}
```
