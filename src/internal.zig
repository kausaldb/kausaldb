//! Internal API for KausalDB development tools.
//!
//! Provides access to internal components for development tooling including
//! benchmarks, fuzzing, tidy checks, and other dev utilities. This module
//! allows standalone dev executables to access internal implementation
//! without going through the public API.
//!
//! This is separate from the public API and should only be used by internal
//! development tools in src/dev/.

const std = @import("std");

// Core modules
pub const assert = @import("core/assert.zig");
pub const concurrency = @import("core/concurrency.zig");
pub const error_context = @import("core/error_context.zig");
pub const stdx = @import("core/stdx.zig");
pub const memory = @import("core/memory.zig");

// Core type safety modules
pub const arena = @import("core/arena.zig");
pub const ownership = @import("core/ownership.zig");
pub const state_machines = @import("core/state_machines.zig");
pub const file_handle = @import("core/file_handle.zig");
pub const bounded = @import("core/bounded.zig");

// VFS modules
const core_vfs_mod = @import("core/vfs.zig");
pub const vfs = @import("core/vfs.zig");
pub const production_vfs = @import("core/production_vfs.zig");

pub const VFS = core_vfs_mod.VFS;
pub const VFile = core_vfs_mod.VFile;

pub const types = @import("core/types.zig");
pub const ContextBlock = types.ContextBlock;
pub const BlockId = types.BlockId;
pub const GraphEdge = types.GraphEdge;
pub const EdgeType = types.EdgeType;

pub const storage_config = @import("storage/config.zig");
pub const Config = storage_config.Config;
pub const storage = @import("storage/engine.zig");
pub const StorageEngine = storage.StorageEngine;

pub const query_engine = @import("query/engine.zig");
pub const QueryEngine = query_engine.QueryEngine;
pub const QueryResult = query_engine.QueryResult;
pub const TraversalDirection = query_engine.TraversalDirection;
pub const TraversalResult = query_engine.TraversalResult;
pub const TraversalQuery = query_engine.TraversalQuery;
pub const TraversalAlgorithm = query_engine.TraversalAlgorithm;
pub const FilterCondition = query_engine.FilterCondition;
pub const FilterExpression = query_engine.FilterExpression;
pub const FilteredQuery = query_engine.FilteredQuery;

// Simulation and testing infrastructure
pub const simulation = @import("sim/simulation.zig");
pub const simulation_vfs = @import("sim/simulation_vfs.zig");
pub const Simulation = simulation.Simulation;
pub const SimulationVFS = simulation_vfs.SimulationVFS;

// Storage subsystem modules
pub const sstable = @import("storage/sstable.zig");
pub const tiered_compaction = @import("storage/tiered_compaction.zig");

// WAL modules
const wal_core_mod = @import("storage/wal/core.zig");
const wal_entry_mod = @import("storage/wal/entry.zig");
const wal_types_mod = @import("storage/wal/types.zig");

pub const wal = struct {
    pub const WAL = wal_core_mod.WAL;
    pub const WALEntry = wal_entry_mod.WALEntry;
    pub const WALError = wal_types_mod.WALError;
    pub const WALEntryType = wal_types_mod.WALEntryType;
    pub const corruption_tracker = @import("storage/wal/corruption_tracker.zig");
    pub const entry = @import("storage/wal/entry.zig");
    pub const recovery = @import("storage/wal/recovery.zig");
    pub const types = @import("storage/wal/types.zig");
    pub const stream = @import("storage/wal/stream.zig");
};

// Query modules
pub const query_operations = @import("query/operations.zig");
pub const query_traversal = @import("query/traversal.zig");
pub const query_filtering = @import("query/filtering.zig");

// Parsers and pipeline
pub const zig_parser = @import("ingestion/zig_parser.zig");
pub const ZigParser = zig_parser.ZigParser;
pub const ZigParserConfig = zig_parser.ZigParserConfig;

// Pipeline types for backward compatibility
pub const pipeline_types = @import("ingestion/pipeline_types.zig");

// File parsing (replaces pipeline abstractions)
pub const parse_file_to_blocks = @import("ingestion/parse_file_to_blocks.zig");
pub const FileContent = parse_file_to_blocks.FileContent;
// Backward compatibility alias for legacy fuzz/benchmark code
pub const SourceContent = FileContent;

// Server components
pub const connection_manager = @import("server/connection_manager.zig");

pub const test_harness = @import("tests/harness.zig");
pub const TestHarness = test_harness.TestHarness;
pub const StorageHarness = test_harness.StorageHarness;
pub const QueryHarness = test_harness.QueryHarness;
pub const SimulationHarness = test_harness.SimulationHarness;
pub const BenchmarkHarness = test_harness.BenchmarkHarness;
pub const ProductionHarness = test_harness.ProductionHarness;

// Testing framework
pub const performance_assertions = @import("testing/performance_assertions.zig");
pub const PerformanceAssertion = performance_assertions.PerformanceAssertion;
pub const PerformanceThresholds = performance_assertions.PerformanceThresholds;
pub const PerformanceTier = performance_assertions.PerformanceTier;

// Dev tooling
pub const debug_allocator = @import("dev/debug_allocator.zig");
pub const profiler = @import("dev/profiler.zig");

// Standard library convenience
pub const Allocator = std.mem.Allocator;
