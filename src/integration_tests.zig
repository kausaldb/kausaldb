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
    // Debug tests for harness issues
    _ = @import("tests/isolate_delete_bug.zig");

    // Scenarios
    _ = @import("tests/scenarios/storage.zig");
    _ = @import("tests/scenarios/component.zig");
    _ = @import("tests/scenarios/query.zig");
    _ = @import("tests/scenarios/ingestion.zig");
    _ = @import("tests/scenarios/vfs_fault.zig");

    _ = @import("tests/deletion_compaction_test.zig");
    _ = @import("tests/edge_test.zig");

    // Regression tests (keeps bugs fixed)
    _ = @import("tests/regression/regression.zig");
}
