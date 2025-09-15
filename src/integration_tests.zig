//! Integration test registry for KausalDB test modules.
//!
//! These tests require full API access and use standardized test harnesses.
//! Uses TestRunner for sophisticated test discovery and performance monitoring.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const assert_mod = @import("core/assert.zig");
const assert = assert_mod.assert;
const MiB = 1024 * 1024;

pub const std_options = .{
    .log_level = build_options.log_level,
};

comptime {
    _ = @import("tests/scenarios/storage.zig");
    _ = @import("tests/scenarios/component.zig");
    _ = @import("tests/scenarios/query.zig");
    _ = @import("tests/scenarios/ingestion.zig");
    _ = @import("tests/properties/storage.zig");
    _ = @import("tests/properties/universal.zig");
    _ = @import("tests/regression/regression.zig");
}
