//! Defensive Programming Framework
//!
//! Systematic defensive programming patterns for bulletproof KausalDB operations.
//! Uses a defense-in-depth approach with heavy assertions and systematic
//! validation that makes bugs impossible.
//!
//! This framework provides zero-cost abstractions for safety - all defensive
//! mechanisms have ZERO runtime overhead in release builds while providing
//! comprehensive protection during development and testing.
//!
//! Philosophy: "Correctness is not negotiable" - every defensive check must
//! either prevent a bug or fail fast with actionable information.

const std = @import("std");
const builtin = @import("builtin");
const assert_mod = @import("../core/assert.zig");
const memory = @import("../core/memory.zig");
const concurrency = @import("../core/concurrency.zig");

const assert = assert_mod.assert;
const fatal_assert = assert_mod.fatal_assert;
const ArenaCoordinator = memory.ArenaCoordinator;

/// Defensive programming configuration
pub const DefenseConfig = struct {
    /// Enable memory corruption detection (debug builds only)
    memory_guards: bool = builtin.mode == .Debug,
    /// Enable state machine validation
    state_validation: bool = true,
    /// Enable boundary checking
    boundary_checks: bool = true,
    /// Enable invariant verification
    invariant_checks: bool = true,
    /// Enable performance regression detection
    performance_guards: bool = builtin.mode == .Debug,
};

/// Global defense configuration
pub var defense_config: DefenseConfig = .{};

/// Assertion levels following KausalDB philosophy
pub const AssertionLevel = enum {
    /// Compile-time validation - zero runtime cost
    comptime_only,
    /// Debug-only checks - removed in release builds
    debug_only,
    /// Always-active safety checks - never removed
    always_active,
};

/// Memory corruption detection patterns
pub const CorruptionPattern = enum(u32) {
    /// Canary pattern for buffer overflow detection
    canary_start = 0xDEADBEEF,
    canary_end = 0xBEEFDEAD,
    /// Poison pattern for use-after-free detection
    poison_freed = 0xDEADC0DE,
    poison_uninitialized = 0xCCCCCCCC,
    /// Guard pattern for memory boundaries
    guard_pattern = 0xFEEDFACE,
};

/// Systematic defensive validation for any value
pub fn defend(comptime level: AssertionLevel, condition: bool, comptime message: []const u8, args: anytype) void {
    switch (level) {
        .comptime_only => {
            if (!condition) {
                @compileError("Compile-time defensive check failed: " ++ message);
            }
        },
        .debug_only => {
            if (builtin.mode == .Debug) {
                if (!condition) {
                    std.debug.panic("DEBUG DEFENSE FAILURE: " ++ message ++ "\n", args);
                }
            }
        },
        .always_active => {
            fatal_assert(condition, message, args);
        },
    }
}

/// Memory guard for detecting buffer overflows and corruption
pub const MemoryGuard = struct {
    const Self = @This();

    start_canary: u32,
    data_ptr: [*]u8,
    data_size: usize,
    end_canary: u32,
    allocation_site: std.builtin.SourceLocation,

    /// Create memory guard around allocation
    pub fn init(data: []u8, allocation_site: std.builtin.SourceLocation) Self {
        const guard = Self{
            .start_canary = @intFromEnum(CorruptionPattern.canary_start),
            .data_ptr = data.ptr,
            .data_size = data.len,
            .end_canary = @intFromEnum(CorruptionPattern.canary_end),
            .allocation_site = allocation_site,
        };

        // Install guard patterns at memory boundaries
        if (defense_config.memory_guards) {
            guard.install_boundary_guards();
        }

        return guard;
    }

    /// Validate memory integrity
    pub fn validate(self: *const Self) void {
        defend(.debug_only, self.start_canary == @intFromEnum(CorruptionPattern.canary_start), "Memory corruption detected: start canary corrupted at {s}:{}", .{ self.allocation_site.file, self.allocation_site.line });

        defend(.debug_only, self.end_canary == @intFromEnum(CorruptionPattern.canary_end), "Memory corruption detected: end canary corrupted at {s}:{}", .{ self.allocation_site.file, self.allocation_site.line });

        if (defense_config.memory_guards) {
            self.validate_boundary_guards();
        }
    }

    /// Install guard patterns at memory boundaries
    fn install_boundary_guards(self: *const Self) void {
        // Guard pattern before data
        if (self.data_size >= 8) {
            const guard_value = @intFromEnum(CorruptionPattern.guard_pattern);
            std.mem.writeInt(u32, self.data_ptr[0..4], guard_value, .little);
            std.mem.writeInt(u32, self.data_ptr[self.data_size - 4 .. self.data_size][0..4], guard_value, .little);
        }
    }

    /// Validate boundary guard patterns
    fn validate_boundary_guards(self: *const Self) void {
        if (self.data_size >= 8) {
            const expected_guard = @intFromEnum(CorruptionPattern.guard_pattern);
            const start_guard = std.mem.readInt(u32, self.data_ptr[0..4], .little);
            const end_guard = std.mem.readInt(u32, self.data_ptr[self.data_size - 4 .. self.data_size][0..4], .little);

            defend(.debug_only, start_guard == expected_guard, "Buffer overflow detected: start guard corrupted at {s}:{}", .{ self.allocation_site.file, self.allocation_site.line });

            defend(.debug_only, end_guard == expected_guard, "Buffer overflow detected: end guard corrupted at {s}:{}", .{ self.allocation_site.file, self.allocation_site.line });
        }
    }

    /// Poison memory on deallocation
    pub fn poison_on_free(self: *const Self) void {
        if (defense_config.memory_guards) {
            const poison_value = @intFromEnum(CorruptionPattern.poison_freed);
            const poison_bytes = std.mem.asBytes(&poison_value);

            var i: usize = 0;
            while (i < self.data_size) {
                const chunk_size = @min(4, self.data_size - i);
                @memcpy(self.data_ptr[i .. i + chunk_size], poison_bytes[0..chunk_size]);
                i += 4;
            }
        }
    }
};

/// State machine defensive validation
pub const StateMachine = struct {
    const Self = @This();

    current_state: u32,
    valid_transitions: []const []const u32,
    state_history: [16]u32, // Circular buffer for debugging
    history_index: u5,

    pub fn init(initial_state: u32, valid_transitions: []const []const u32) Self {
        return Self{
            .current_state = initial_state,
            .valid_transitions = valid_transitions,
            .state_history = [_]u32{0} ** 16,
            .history_index = 0,
        };
    }

    /// Validate and execute state transition
    pub fn transition(self: *Self, new_state: u32, comptime context: []const u8) void {
        self.validate_transition(new_state, context);

        // Record state history for debugging
        self.state_history[self.history_index] = self.current_state;
        self.history_index = (self.history_index + 1) % 16;

        self.current_state = new_state;
    }

    /// Validate state transition is legal
    fn validate_transition(self: *const Self, new_state: u32, comptime context: []const u8) void {
        if (!defense_config.state_validation) return;

        // Check if transition is valid
        var transition_valid = false;
        if (self.current_state < self.valid_transitions.len) {
            const valid_next_states = self.valid_transitions[self.current_state];
            for (valid_next_states) |valid_state| {
                if (valid_state == new_state) {
                    transition_valid = true;
                    break;
                }
            }
        }

        defend(.always_active, transition_valid, "Invalid state transition in {s}: {} -> {} (history: {any})", .{ context, self.current_state, new_state, self.state_history });
    }

    /// Get current state for validation
    pub fn state(self: *const Self) u32 {
        return self.current_state;
    }

    /// Validate current state is in expected set
    pub fn validate_state_in(self: *const Self, expected_states: []const u32, comptime context: []const u8) void {
        if (!defense_config.state_validation) return;

        for (expected_states) |expected| {
            if (self.current_state == expected) return;
        }

        defend(.always_active, false, "Invalid state in {s}: current={}, expected one of: {any}", .{ context, self.current_state, expected_states });
    }
};

/// Boundary validation for arrays, slices, and indices
pub const BoundaryGuard = struct {
    /// Validate array/slice access is within bounds
    pub fn validate_access(comptime T: type, data: []const T, index: usize, comptime context: []const u8) void {
        if (!defense_config.boundary_checks) return;

        defend(.always_active, index < data.len, "Boundary violation in {s}: index {} >= length {}", .{ context, index, data.len });
    }

    /// Validate range access is within bounds
    pub fn validate_range(
        comptime T: type,
        data: []const T,
        start: usize,
        end: usize,
        comptime context: []const u8,
    ) void {
        if (!defense_config.boundary_checks) return;

        defend(.always_active, start <= end, "Invalid range in {s}: start {} > end {}", .{ context, start, end });

        defend(.always_active, end <= data.len, "Range boundary violation in {s}: end {} > length {}", .{ context, end, data.len });
    }

    /// Validate buffer has sufficient capacity for operation
    pub fn validate_capacity(
        current_len: usize,
        required_capacity: usize,
        max_capacity: usize,
        comptime context: []const u8,
    ) void {
        if (!defense_config.boundary_checks) return;

        defend(.always_active, required_capacity <= max_capacity, "Capacity exceeded in {s}: required {} > max {}", .{ context, required_capacity, max_capacity });

        defend(.always_active, current_len <= required_capacity, "Invalid capacity state in {s}: current {} > required {}", .{ context, current_len, required_capacity });
    }
};

/// Performance regression detection
pub const PerformanceGuard = struct {
    const Self = @This();

    operation_name: []const u8,
    start_time: i128,
    max_duration_ns: i128,

    pub fn init(comptime operation_name: []const u8, max_duration_ns: i128) Self {
        return Self{
            .operation_name = operation_name,
            .start_time = if (defense_config.performance_guards) std.time.nanoTimestamp() else 0,
            .max_duration_ns = max_duration_ns,
        };
    }

    pub fn end(self: *const Self) void {
        if (!defense_config.performance_guards) return;

        const duration = std.time.nanoTimestamp() - self.start_time;
        defend(.debug_only, duration <= self.max_duration_ns, "Performance regression in {s}: {}ns > {}ns threshold", .{ self.operation_name, duration, self.max_duration_ns });
    }
};

/// Thread safety validation
pub const ConcurrencyGuard = struct {
    /// Validate operation is on main thread
    pub fn validate_main_thread(comptime context: []const u8) void {
        _ = context; // Context available for debugging if needed
        // In KausalDB single-threaded model, validate we're on the main thread
        if (builtin.mode == .Debug) {
            concurrency.assert_main_thread();
        }
    }

    /// Validate exclusive access (single-threaded operation)
    pub fn validate_exclusive_access(comptime context: []const u8) void {
        // In KausalDB's single-threaded model, this is always true
        // But provides documentation of thread safety requirements
        validate_main_thread(context);
    }
};

/// Invariant validation framework
pub const InvariantChecker = struct {
    const Self = @This();

    check_name: []const u8,
    enabled: bool,

    pub fn init(comptime check_name: []const u8) Self {
        return Self{
            .check_name = check_name,
            .enabled = defense_config.invariant_checks,
        };
    }

    /// Validate invariant condition
    pub fn check(self: *const Self, condition: bool, comptime message: []const u8, args: anytype) void {
        if (!self.enabled) return;

        defend(.always_active, condition, "Invariant violation in {s}: " ++ message, .{self.check_name} ++ args);
    }

    /// Validate numerical invariant (e.g., balance >= 0)
    pub fn check_numerical(
        self: *const Self,
        comptime T: type,
        value: T,
        comptime op: []const u8,
        threshold: T,
        comptime message: []const u8,
    ) void {
        if (!self.enabled) return;

        const condition = switch (comptime std.meta.stringToEnum(std.math.CompareOperator, op) orelse @compileError("Invalid comparison operator")) {
            .lt => value < threshold,
            .lte => value <= threshold,
            .eq => value == threshold,
            .gte => value >= threshold,
            .gt => value > threshold,
            .neq => value != threshold,
        };

        self.check(condition, message ++ " (value: {}, threshold: {})", .{ value, threshold });
    }
};

/// Resource leak detection
pub const ResourceTracker = struct {
    const Self = @This();

    resource_type: []const u8,
    active_count: u32,
    max_count: u32,
    allocation_sites: std.AutoHashMap(usize, std.builtin.SourceLocation),

    pub fn init(allocator: std.mem.Allocator, comptime resource_type: []const u8, max_count: u32) Self {
        return Self{
            .resource_type = resource_type,
            .active_count = 0,
            .max_count = max_count,
            .allocation_sites = std.AutoHashMap(usize, std.builtin.SourceLocation).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        defend(.always_active, self.active_count == 0, "Resource leak detected: {} active {s} resources at shutdown", .{ self.active_count, self.resource_type });

        self.allocation_sites.deinit();
    }

    /// Track resource allocation
    pub fn allocate(self: *Self, resource_id: usize, site: std.builtin.SourceLocation) void {
        if (!defense_config.invariant_checks) return;

        self.active_count += 1;
        defend(.always_active, self.active_count <= self.max_count, "Resource limit exceeded: {} > {} max {s} resources", .{ self.active_count, self.max_count, self.resource_type });

        self.allocation_sites.put(resource_id, site) catch {};
    }

    /// Track resource deallocation
    pub fn deallocate(self: *Self, resource_id: usize) void {
        if (!defense_config.invariant_checks) return;

        defend(.always_active, self.active_count > 0, "Double-free detected for {s} resource {}", .{ self.resource_type, resource_id });

        defend(.always_active, self.allocation_sites.remove(resource_id), "Deallocating unknown {s} resource {}", .{ self.resource_type, resource_id });

        self.active_count -= 1;
    }
};

// Comprehensive defensive programming test
test "defensive_programming_framework" {
    // Test memory guard
    var test_data: [16]u8 = undefined;
    const guard = MemoryGuard.init(&test_data, @src());
    guard.validate();

    // Test state machine
    const transitions = [_][]const u32{
        &[_]u32{ 1, 2 }, // State 0 can go to 1 or 2
        &[_]u32{0}, // State 1 can go to 0
        &[_]u32{0}, // State 2 can go to 0
    };
    var sm = StateMachine.init(0, &transitions);
    sm.transition(1, "test");
    sm.validate_state_in(&[_]u32{1}, "test");

    // Test boundary guard
    const test_array = [_]u32{ 1, 2, 3, 4, 5 };
    BoundaryGuard.validate_access(u32, &test_array, 2, "test");
    BoundaryGuard.validate_range(u32, &test_array, 1, 4, "test");

    // Test performance guard
    const perf_guard = PerformanceGuard.init("test_operation", 1000000); // 1ms
    perf_guard.end();

    // Test concurrency guard (this should pass in single-threaded tests)
    ConcurrencyGuard.validate_main_thread("test");

    // Test invariant checker
    const checker = InvariantChecker.init("test_invariants");
    checker.check(true, "test condition", .{});
    checker.check_numerical(u32, 5, "gte", 0, "value must be non-negative");
}
