# CONTRIBUTING

This guide provides everything you need to get started.

## 1. Setup

Get the repository and install the required Zig toolchain with a single script.

```bash
# Clone and enter the repository
git clone https://github.com/kausaldb/kausaldb
cd kausaldb

# Install the correct Zig version into ./zig/
./scripts/install_zig.sh
```
The project uses pre-commit hooks to automate formatting and testing.

## 2. Development Workflow

The development cycle is designed to be fast and reliable.

1.  **Format your code:**
    ```bash
    ./zig/zig build fmt
    ```

2.  **Run the fast test suite:** This is your primary command for quick validation.
    ```bash
    ./zig/zig build test
    ```
3.  **Run code quality checks:** Before committing, ensure your code aligns with project conventions.
    ```bash
    ./zig/zig build tidy
    ```
4.  **Run the complete test suite:** Before submitting a pull request, run the full validation suite.
    ```bash
    ./zig/zig build test-all
    ```

## Guiding Principles

To maintain simplicity and correctness, we follow a few guiding principles:

*   **Correctness over Features:** Stability and data integrity are non-negotiable.
*   **Simplicity over Complexity:** If a simpler path exists, it is the correct one.
*   **Deterministic Testing over Mocking:** Every test failure must be reproducible. We use a simulation framework to test real code under hostile conditions, not mocks.

## Code Standards

We rely on `zig fmt` for formatting. Our main code standards are simple:

*   **Functions are Verbs:** Name functions to describe the action they perform.
    ```zig
    // GOOD
    fn find_block(id: BlockId) !?ContextBlock;

    // BAD
    fn block_finder(id: BlockId) !?ContextBlock;
    ```
*   **Comments Explain *Why*, Not *What*:** Code should explain itself. Comments should provide context that the code cannot.
    ```zig
    // BAD:
    // Increment the counter
    counter += 1;

    // GOOD:
    // WAL requires sequential entry numbers for recovery
    counter += 1;
    ```

## Submitting Changes

1.  **Commit Messages:** Please follow the [Conventional Commits](https://www.conventionalcommits.org/) format.

    ```
    type(scope): brief summary
    ```
    **Example:** `feat(storage): add checksum validation to sstable headers`

2.  **Pull Requests:** Before submitting a pull request, please ensure:
    *   The full test suite passes (`./zig/zig build test-all`).
    *   New functionality is covered by new tests.
    *   The changes align with our guiding principles.

## Further Reading

For a deeper understanding of our architecture, testing philosophy, and code style, please see the documents in the **[`docs/`](docs/)** directory.
