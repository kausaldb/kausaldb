//! Internal API for development tools.
//!
//! Provides access to KausalDB internals for benchmarks, fuzz testing,
//! and other development tools. This module breaks encapsulation
//! intentionally to enable thorough testing and performance analysis.
//!
//! WARNING: This API is unstable and for internal use only.
//! External applications should use the public API in kausaldb.zig.

const std = @import("std");

// Core types and utilities
pub const types = @import("core/types.zig");
pub const BlockId = types.BlockId;
pub const ContextBlock = types.ContextBlock;
pub const GraphEdge = types.GraphEdge;
pub const EdgeType = types.EdgeType;

// Storage engine and configuration
pub const storage_config = @import("storage/config.zig");
pub const Config = storage_config.Config;
pub const storage = @import("storage/engine.zig");
pub const StorageEngine = storage.StorageEngine;

// Query engine
pub const query_engine = @import("query/engine.zig");
pub const QueryEngine = query_engine.QueryEngine;

// Workspace manager
pub const workspace_manager = @import("workspace/manager.zig");
pub const WorkspaceManager = workspace_manager.WorkspaceManager;

// Core utilities
pub const concurrency = @import("core/concurrency.zig");
pub const ownership = @import("core/ownership.zig");
pub const OwnedBlock = ownership.OwnedBlock;

// VFS abstraction
pub const vfs = @import("core/vfs.zig");
pub const VFS = vfs.VFS;
pub const production_vfs = @import("core/production_vfs.zig");
pub const ProductionVFS = production_vfs.ProductionVFS;

// Core utilities and error handling
pub const assert_mod = @import("core/assert.zig");
pub const memory = @import("core/memory.zig");
pub const error_context = @import("core/error_context.zig");
pub const arena_mod = @import("core/arena.zig");
pub const bounded_mod = @import("core/bounded.zig");
pub const file_handle = @import("core/file_handle.zig");
pub const pools = @import("core/pools.zig");
pub const signals = @import("core/signals.zig");
pub const state_machines = @import("core/state_machines.zig");

// Storage subsystem modules
pub const sstable = @import("storage/sstable.zig");
pub const block_index = @import("storage/block_index.zig");

// WAL (Write-Ahead Log) subsystem
pub const wal = @import("storage/wal.zig");

// CLI v2 protocol and client
pub const cli_v2_protocol = @import("cli/protocol.zig");
pub const cli_v2_parser = @import("cli/parser.zig");
pub const cli_v2_client = @import("cli/client.zig");

// Simulation testing infrastructure
pub const simulation_vfs = @import("sim/simulation_vfs.zig");
pub const simulation = @import("sim/simulation.zig");
pub const harness = @import("testing/harness.zig");
pub const SimulationVFS = simulation_vfs.SimulationVFS;
pub const WorkloadGenerator = harness.WorkloadGenerator;
pub const WorkloadConfig = harness.WorkloadConfig;
pub const OperationMix = harness.OperationMix;
pub const Operation = harness.Operation;
pub const ModelState = harness.ModelState;
pub const PropertyChecker = harness.PropertyChecker;

// Ingestion pipeline
pub const ingestion = struct {
    pub const ingest_directory = @import("ingestion/ingest_directory.zig");
    pub const ingest_file = @import("ingestion/ingest_file.zig");
    pub const pipeline_types = @import("ingestion/pipeline_types.zig");
    pub const zig = struct {
        pub const parser = @import("ingestion/zig/parser.zig");
    };
};

// Standard library conveniences
pub const Allocator = std.mem.Allocator;
pub const testing = std.testing;

/// Initialize a storage engine for testing/benchmarking
pub fn init_test_storage(allocator: Allocator, vfs_instance: VFS) !StorageEngine {
    const config = Config{
        .max_block_cache_bytes = 64 * 1024 * 1024, // 64MB
        .memtable_flush_threshold_bytes = 16 * 1024 * 1024, // 16MB
        .wal_segment_size_bytes = 64 * 1024 * 1024, // 64MB
        .compaction_trigger_ratio = 4,
        .max_compaction_lag_ms = 5000,
        .enable_fsync = false, // Disable for testing performance
    };

    return StorageEngine.init(allocator, vfs_instance, "test_data", config);
}
