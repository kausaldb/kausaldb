//! Integration test registry for KausalDB test modules.
//!
//! These tests require full API access and use standardized test harnesses.
//! Uses TestRunner for sophisticated test discovery and performance monitoring.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const std_options = .{
    .log_level = build_options.log_level,
};

comptime {
    // Scenarios
    _ = @import("tests/scenarios/storage.zig");
    _ = @import("tests/scenarios/component.zig");
    _ = @import("tests/scenarios/query.zig");
    _ = @import("tests/scenarios/ingestion.zig");
    _ = @import("tests/scenarios/vfs_fault.zig");
    _ = @import("tests/scenarios/storage_correctness.zig");
    _ = @import("tests/scenarios/graph_traversal.zig");
    _ = @import("tests/scenarios/deletion_compaction.zig");
    _ = @import("tests/scenarios/edge_persistence.zig");
    _ = @import("tests/scenarios/tombstone_sequencing.zig");

    // Regression tests (keeps bugs fixed)
    _ = @import("tests/regression/regression.zig");
}
