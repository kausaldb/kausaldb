# CLI v2 Migration Plan

## Executive Summary

The current CLI architecture has fundamental performance and maintainability issues that make it unsuitable for a production v0.1.0 release. CLI v2 implements a client-server architecture that eliminates startup overhead while improving code quality and testability.

## Current State Problems

### Performance Issues

- **169ms** average command latency due to database initialization on every command
- **442ms** trace command latency from repeated storage engine startup
- Cold start penalty makes CLI unusable for interactive workflows

### Architecture Issues

- Monolithic `executor.zig` mixing parsing, execution, and output formatting
- Impossible to test commands in isolation
- Heavy I/O operations in CLI process for every command
- Memory overhead from loading entire storage engine for simple queries

### Code Quality Issues

- Tangled responsibilities across modules
- Difficult to extend with new commands
- No separation between local and remote operations
- Error handling mixed with business logic

## CLI v2 Architecture

### Client-Server Model

```
┌─────────────┐    ┌──────────────┐    ┌─────────────────┐
│ kausal CLI  │───▶│ TCP Protocol │───▶│ kausaldb-server │
│ (client)    │    │ (port 3838)  │    │ (persistent)    │
└─────────────┘    └──────────────┘    └─────────────────┘
     <10ms              Wire                Hot data
   Pure parsing      Protocol           in memory
```

### Key Components

- **Parser** (`parser.zig`) - Pure argument parsing, zero I/O
- **Client** (`client.zig`) - Lightweight RPC communication
- **Protocol** (`protocol.zig`) - Binary wire format for zero-copy serialization
- **Renderer** (`renderer.zig`) - Clean output formatting for all formats
- **CLI Coordinator** (`cli.zig`) - Orchestrates command lifecycle

### Performance Targets

- **<10ms** command latency for queries (16x improvement)
- **<300ms** trace operations (1.5x improvement)
- Zero startup overhead after initial server start

## Migration Strategy

### Phase 1: Implementation Completion

**Duration: 3 days**

1. **Complete Protocol Implementation**
   - Verify all message types serialize correctly
   - Add missing request/response handlers
   - Validate struct padding and alignment

2. **Server Integration**
   - Extend existing `src/server/handler.zig` with CLI protocol handlers
   - Add CLI-specific message routing
   - Implement graceful error handling for malformed requests

3. **Fix Integration Test Issues**
   - Resolve MockServer compilation errors in `cli_v2_integration.zig`
   - Add missing dependencies to build system
   - Verify protocol message sizes match expectations

### Phase 2: Build System Integration

**Duration: 1 day**

1. **Add CLI v2 to Build Targets**

   ```bash
   ./zig/zig build kausal-client    # New thin client binary
   ./zig/zig build kausal-server    # Server with CLI protocol
   ```

2. **Update Development Workflow**
   - Modify `./scripts/` to use new binaries
   - Update CI pipeline to test both client and server
   - Add performance benchmarks for command latency

### Phase 3: Testing and Validation

**Duration: 2 days**

1. **Comprehensive Test Coverage**
   - Unit tests: All parser combinations, protocol serialization
   - Integration tests: Client-server communication with mock data
   - E2E tests: Full command execution through subprocess

2. **Performance Validation**
   - Measure actual command latencies vs targets
   - Test server stability under concurrent client connections
   - Validate memory usage in long-running scenarios

3. **Error Scenario Testing**
   - Server not running (graceful degradation)
   - Network failures (timeout handling)
   - Malformed protocol messages (error recovery)

### Phase 4: Documentation and Migration

**Duration: 1 day**

1. **Update User Documentation**
   - README.md with new server/client model
   - Command reference with new options
   - Troubleshooting guide for common issues

2. **Prepare Migration Scripts**
   - Detect old CLI usage patterns
   - Automatic server startup for development
   - Compatibility shims if needed

## Implementation Status

### Completed

- Protocol definition with binary serialization
- Client implementation with connection management
- Parser with comprehensive command support
- Renderer with text/JSON/CSV output formats
- CLI coordinator with clean separation of concerns
- Unit tests for parser and protocol
- Integration tests with mock server

### In Progress

- Server-side protocol handlers
- Build system integration
- E2E test framework updates

### Remaining

- Performance benchmarking infrastructure
- Server lifecycle management (start/stop/restart)
- Client connection pooling for high-frequency usage
- Protocol versioning for future compatibility

## Risk Analysis

### High Risk

- **Server reliability**: Single point of failure for all CLI operations
- **Protocol evolution**: Binary format harder to debug than JSON
- **Development complexity**: Two-process debugging vs single binary

### Medium Risk

- **User experience**: Extra step to start server
- **Resource usage**: Persistent server vs ephemeral CLI
- **Deployment complexity**: Two binaries instead of one

### Low Risk

- **Performance regression**: Client overhead is minimal
- **Compatibility**: Parser maintains same command syntax
- **Testing burden**: Better separation improves testability

## Mitigation Strategies

1. **Server Reliability**
   - Implement robust error handling and recovery
   - Add health checks and automatic restart
   - Graceful degradation when server unavailable

2. **Protocol Evolution**
   - Version negotiation in protocol header
   - Comprehensive serialization tests
   - Binary debugging tools and utilities

3. **Development Experience**
   - Unified `kausal` command that auto-starts server
   - Development mode with embedded server option
   - Rich error messages for common failure modes

## Success Criteria

### Performance

- [ ] `kausal find` completes in <10ms (measured via `hyperfine`)
- [ ] `kausal trace` completes in <300ms with complex graphs
- [ ] Server handles 100+ concurrent connections without degradation

### Quality

- [ ] All existing CLI functionality preserved
- [ ] Zero test regressions in existing e2e suite
- [ ] New command parsing passes fuzzing tests

### User Experience

- [ ] Commands work identically to current CLI
- [ ] Clear error messages when server unavailable
- [ ] Comprehensive help and documentation

## Timeline

**Total Duration: 7 days**

```
Day 1-3: Complete implementation and fix integration issues
Day 4:   Build system integration and CI updates
Day 5-6: Testing, performance validation, error scenarios
Day 7:   Documentation, migration prep, final validation
```

## Rollback Plan

If critical issues emerge during migration:

1. **Immediate**: Revert `src/main.zig` to use old CLI architecture
2. **Build system**: Remove CLI v2 targets, restore original binary
3. **Tests**: Disable failing CLI v2 tests, re-enable old CLI tests
4. **Performance**: Document specific issues for future resolution

The old CLI implementation remains intact and can be restored within 1 hour.

## Next Steps

1. **Fix MockServer compilation errors** in integration tests
2. **Add CLI protocol handlers** to existing server infrastructure
3. **Integrate with build system** to produce both binaries
4. **Run comprehensive test suite** including performance benchmarks
5. **Update documentation** with new server/client workflow

This migration transforms the CLI from a liability into a competitive advantage, providing the sub-10ms responsiveness users expect from professional developer tools.
