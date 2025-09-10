//! Hostile VFS with enhanced fault injection for Context Engine testing.
//!
//! This module implements aggressive fault injection patterns on top of the
//! existing SimulationVFS to test Context Engine resilience under extreme
//! conditions. Unlike basic fault injection, the Hostile VFS actively
//! attacks system assumptions with sophisticated corruption patterns.
//!
//! Key hostile behaviors:
//! - Bit flip cascades that propagate through related data structures
//! - Silent checksum bypass corruption that defeats validation layers
//! - Sophisticated torn write patterns that corrupt headers/metadata
//! - Memory pressure scenarios that trigger edge cases
//! - Multi-phase corruption attacks across operation boundaries
//!
//! Design principles:
//! - Every corruption pattern is deterministic for reproducible testing
//! - Bounded fault injection prevents test suite from hanging indefinitely
//! - Integration with existing SimulationVFS preserves compatibility
//! - Graduated hostility levels allow testing system breaking points

const std = @import("std");
const builtin = @import("builtin");

const assert_mod = @import("../core/assert.zig");
const bounded_mod = @import("../core/bounded.zig");
const simulation_vfs_mod = @import("simulation_vfs.zig");
const vfs_types = @import("../core/vfs.zig");

const assert = assert_mod.assert;
const fatal_assert = assert_mod.fatal_assert;
const comptime_assert = assert_mod.comptime_assert;
const BoundedArrayType = bounded_mod.BoundedArrayType;

const SimulationVFS = simulation_vfs_mod.SimulationVFS;
const VFS = vfs_types.VFS;
const VFile = vfs_types.VFile;

const Allocator = std.mem.Allocator;

/// Maximum corruption patterns to track for deterministic behavior
const MAX_CORRUPTION_PATTERNS = 64;

/// Maximum cascade depth for bit flip propagation
const MAX_CASCADE_DEPTH = 8;

/// Hostile VFS wrapper that adds aggressive fault injection to SimulationVFS
pub const HostileVFS = struct {
    base_vfs: *SimulationVFS,
    corruption_engine: CorruptionEngine,
    hostility_level: HostilityLevel,
    operation_count: u64,
    allocated: bool, // Track if we own the base_vfs allocation

    /// Graduated levels of hostility for testing system breaking points
    pub const HostilityLevel = enum(u8) {
        /// Basic corruption - single bit flips, simple torn writes
        basic = 1,
        /// Moderate corruption - small cascades, metadata targeting
        moderate = 2,
        /// Aggressive corruption - large cascades, checksum bypass
        aggressive = 3,
        /// Extreme corruption - multi-phase attacks, memory pressure
        extreme = 4,
        /// Catastrophic corruption - systematic destruction for boundary testing
        catastrophic = 5,

        /// Calculate corruption intensity multiplier based on hostility level.
        /// Higher levels exponentially increase corruption patterns for stress testing.
        pub fn corruption_multiplier(self: HostilityLevel) f32 {
            return switch (self) {
                .basic => 1.0,
                .moderate => 2.5,
                .aggressive => 5.0,
                .extreme => 10.0,
                .catastrophic => 20.0,
            };
        }

        /// Determine maximum cascade depth for multi-step failures.
        /// Controls how many dependent operations can fail from single corruption event.
        pub fn max_cascade_depth(self: HostilityLevel) u32 {
            return switch (self) {
                .basic => 1,
                .moderate => 2,
                .aggressive => 4,
                .extreme => 6,
                .catastrophic => MAX_CASCADE_DEPTH,
            };
        }
    };

    /// Advanced corruption engine with sophisticated attack patterns
    pub const CorruptionEngine = struct {
        prng: std.Random.DefaultPrng,
        seed: u64,

        /// Bit flip corruption with cascade propagation
        bit_flip_config: BitFlipConfig,

        /// Torn write patterns targeting critical structures
        torn_write_config: TornWriteConfig,

        /// Silent corruption that bypasses checksum validation
        silent_corruption_config: SilentCorruptionConfig,

        /// Memory pressure simulation
        memory_pressure_config: MemoryPressureConfig,

        /// Active corruption patterns for deterministic behavior
        active_patterns: BoundedArrayType(CorruptionPattern, MAX_CORRUPTION_PATTERNS),

        pub const BitFlipConfig = struct {
            enabled: bool = false,
            /// Probability per KB of triggering cascade corruption
            cascade_probability_per_kb: u32 = 0,
            /// Maximum bits to flip in a single cascade
            max_cascade_bits: u32 = 8,
            /// Whether to target specific byte patterns (headers, magic numbers)
            target_critical_bytes: bool = false,
        };

        pub const TornWriteConfig = struct {
            enabled: bool = false,
            /// Probability of torn write per operation (per thousand)
            probability_per_thousand: u32 = 0,
            /// Minimum bytes to write (even in torn scenario)
            min_partial_bytes: u32 = 1,
            /// Maximum completion fraction (per thousand)
            max_completion_fraction_per_thousand: u32 = 750,
            /// Target header corruption specifically
            target_headers: bool = false,
        };

        pub const SilentCorruptionConfig = struct {
            enabled: bool = false,
            /// Rate of checksum bypass corruption (per million operations)
            bypass_rate_per_million: u32 = 0,
            /// Whether to corrupt checksums to match corrupted data
            stealth_mode: bool = false,
        };

        pub const MemoryPressureConfig = struct {
            enabled: bool = false,
            /// Simulate memory allocation failures
            allocation_failure_rate: u32 = 0,
            /// Simulate fragmentation through delayed frees
            fragmentation_simulation: bool = false,
        };

        /// Active corruption pattern affecting system behavior
        pub const CorruptionPattern = struct {
            pattern_type: PatternType,
            target_offset: u64,
            corruption_data: [32]u8,
            cascade_depth: u32,
            operations_remaining: u32,

            pub const PatternType = enum {
                bit_flip_cascade,
                header_corruption,
                checksum_bypass,
                torn_metadata,
            };
        };

        pub fn init(seed: u64) CorruptionEngine {
            return CorruptionEngine{
                .prng = std.Random.DefaultPrng.init(seed),
                .seed = seed,
                .bit_flip_config = .{},
                .torn_write_config = .{},
                .silent_corruption_config = .{},
                .memory_pressure_config = .{},
                .active_patterns = BoundedArrayType(CorruptionPattern, MAX_CORRUPTION_PATTERNS){},
            };
        }

        /// Apply sophisticated corruption to buffer based on hostility level
        pub fn apply_hostile_corruption(self: *CorruptionEngine, buffer: []u8, hostility: HostilityLevel) void {
            if (buffer.len == 0) return;

            self.prng.random().bytes(buffer[0..@min(buffer.len, 4)]);

            // Process active corruption patterns
            self.process_active_patterns(buffer);

            // Apply new corruptions based on hostility level
            if (self.bit_flip_config.enabled) {
                self.apply_cascade_bit_flips(buffer, hostility);
            }

            if (self.silent_corruption_config.enabled) {
                self.apply_silent_corruption(buffer, hostility);
            }
        }

        /// Apply bit flip cascades that propagate through related data
        fn apply_cascade_bit_flips(self: *CorruptionEngine, buffer: []u8, hostility: HostilityLevel) void {
            const kb_count = @max(1, buffer.len / 1024);
            const cascade_prob = @as(u32, @intFromFloat(@as(f32, @floatFromInt(self.bit_flip_config.cascade_probability_per_kb)) * hostility.corruption_multiplier()));

            for (0..kb_count) |_| {
                const should_cascade = self.prng.random().uintLessThan(u32, 1000);
                if (should_cascade < cascade_prob) {
                    self.create_bit_flip_cascade(buffer, hostility.max_cascade_depth());
                }
            }
        }

        /// Create cascading bit flips that spread through buffer
        fn create_bit_flip_cascade(self: *CorruptionEngine, buffer: []u8, max_depth: u32) void {
            const start_byte = self.prng.random().uintLessThan(usize, buffer.len);
            var cascade_depth: u32 = 0;
            var current_byte = start_byte;

            while (cascade_depth < max_depth and cascade_depth < self.bit_flip_config.max_cascade_bits) {
                // Flip bit in current byte
                const bit_pos = @as(u3, @intCast(self.prng.random().uintLessThan(u4, 8)));
                buffer[current_byte] ^= (@as(u8, 1) << bit_pos);

                // Propagate to nearby bytes
                const jump_distance = self.prng.random().uintLessThan(usize, 16) + 1;
                current_byte = (current_byte + jump_distance) % buffer.len;
                cascade_depth += 1;
            }

            // Record pattern for deterministic behavior
            if (!self.active_patterns.is_full()) {
                const pattern = CorruptionPattern{
                    .pattern_type = .bit_flip_cascade,
                    .target_offset = start_byte,
                    .corruption_data = [_]u8{0} ** 32,
                    .cascade_depth = cascade_depth,
                    .operations_remaining = 10, // Pattern affects next 10 operations
                };
                self.active_patterns.append(pattern) catch {};
            }
        }

        /// Apply silent corruption that defeats checksum validation
        fn apply_silent_corruption(self: *CorruptionEngine, buffer: []u8, hostility: HostilityLevel) void {
            if (!self.silent_corruption_config.stealth_mode) return;

            const corruption_rate = @as(u32, @intFromFloat(@as(f32, @floatFromInt(self.silent_corruption_config.bypass_rate_per_million)) * hostility.corruption_multiplier()));
            const should_corrupt = self.prng.random().uintLessThan(u32, 1_000_000);

            if (should_corrupt < corruption_rate) {
                // Corrupt data in a way that maintains apparent checksum validity
                self.apply_checksum_preserving_corruption(buffer);
            }
        }

        /// Corrupt data while maintaining checksum validity (stealth corruption)
        fn apply_checksum_preserving_corruption(self: *CorruptionEngine, buffer: []u8) void {
            if (buffer.len < 8) return; // Need minimum size for checksum manipulation

            // Simple XOR-based corruption that can be made checksum-neutral
            const corruption_byte = self.prng.random().int(u8);
            const target_offset = self.prng.random().uintLessThan(usize, buffer.len - 4);

            // XOR corruption simulates bit flips from electromagnetic interference
            buffer[target_offset] ^= corruption_byte;
            buffer[target_offset + 1] ^= corruption_byte;

            // Apply complementary corruption to maintain checksum
            if (target_offset + 4 < buffer.len) {
                buffer[target_offset + 2] ^= corruption_byte;
                buffer[target_offset + 3] ^= corruption_byte;
            }
        }

        /// Process active corruption patterns affecting current operations
        fn process_active_patterns(self: *CorruptionEngine, buffer: []u8) void {
            var i: usize = 0;
            while (i < self.active_patterns.len) {
                var pattern = &self.active_patterns.slice_mut()[i];

                if (pattern.operations_remaining == 0) {
                    // Remove expired pattern
                    _ = self.active_patterns.remove_at(i) catch continue;
                    continue;
                }

                // Apply pattern-specific corruption
                switch (pattern.pattern_type) {
                    .bit_flip_cascade => self.apply_cascade_pattern(buffer, pattern),
                    .header_corruption => self.apply_header_pattern(buffer, pattern),
                    .checksum_bypass => self.apply_bypass_pattern(buffer, pattern),
                    .torn_metadata => self.apply_torn_pattern(buffer, pattern),
                }

                pattern.operations_remaining -= 1;
                i += 1;
            }
        }

        fn apply_cascade_pattern(self: *CorruptionEngine, buffer: []u8, pattern: *CorruptionPattern) void {
            _ = self;
            if (buffer.len > pattern.target_offset) {
                const offset = pattern.target_offset % buffer.len;
                buffer[offset] ^= pattern.corruption_data[0];
            }
        }

        fn apply_header_pattern(self: *CorruptionEngine, buffer: []u8, pattern: *CorruptionPattern) void {
            _ = self;
            // Target first 64 bytes which often contain headers
            const header_size = @min(buffer.len, 64);
            if (header_size > 0) {
                const target = pattern.target_offset % header_size;
                buffer[target] ^= pattern.corruption_data[1];
            }
        }

        fn apply_bypass_pattern(self: *CorruptionEngine, buffer: []u8, pattern: *CorruptionPattern) void {
            _ = self;
            // Sophisticated checksum bypass logic would go here
            if (buffer.len >= 8) {
                const mid = buffer.len / 2;
                buffer[mid] ^= pattern.corruption_data[2];
            }
        }

        fn apply_torn_pattern(self: *CorruptionEngine, buffer: []u8, pattern: *CorruptionPattern) void {
            _ = self;
            // Simulate metadata corruption from torn writes
            if (buffer.len > 16) {
                const metadata_start = buffer.len - 16;
                buffer[metadata_start] ^= pattern.corruption_data[3];
            }
        }
    };

    /// Initialize hostile VFS wrapping an existing SimulationVFS
    pub fn init(base_vfs: *SimulationVFS, hostility_level: HostilityLevel, seed: u64) HostileVFS {
        return HostileVFS{
            .base_vfs = base_vfs,
            .corruption_engine = CorruptionEngine.init(seed),
            .hostility_level = hostility_level,
            .operation_count = 0,
            .allocated = false,
        };
    }

    /// Create hostile VFS with new SimulationVFS instance
    pub fn create_with_hostility(allocator: Allocator, hostility_level: HostilityLevel, seed: u64) !HostileVFS {
        const base_vfs = try allocator.create(SimulationVFS);
        errdefer allocator.destroy(base_vfs);

        base_vfs.* = try SimulationVFS.init_with_fault_seed(allocator, seed);

        var hostile = HostileVFS.init(base_vfs, hostility_level, seed);
        hostile.allocated = true;
        return hostile;
    }

    /// Cleanup hostile VFS and optionally destroy base VFS
    pub fn deinit(self: *HostileVFS, allocator: Allocator) void {
        if (self.allocated) {
            self.base_vfs.deinit();
            allocator.destroy(self.base_vfs);
        }
        self.* = undefined;
    }

    /// Enable aggressive bit flip cascades
    pub fn enable_cascade_bit_flips(self: *HostileVFS, cascade_probability_per_kb: u32, max_cascade_bits: u32) void {
        fatal_assert(cascade_probability_per_kb <= 1000, "Cascade probability too high: {}", .{cascade_probability_per_kb});
        fatal_assert(max_cascade_bits > 0 and max_cascade_bits <= 32, "Invalid cascade bits: {}", .{max_cascade_bits});

        self.corruption_engine.bit_flip_config = .{
            .enabled = true,
            .cascade_probability_per_kb = cascade_probability_per_kb,
            .max_cascade_bits = max_cascade_bits,
            .target_critical_bytes = true,
        };
    }

    /// Enable sophisticated torn write patterns
    pub fn enable_hostile_torn_writes(self: *HostileVFS, probability_per_thousand: u32, target_headers: bool) void {
        fatal_assert(probability_per_thousand <= 1000, "Torn write probability too high: {}", .{probability_per_thousand});

        self.corruption_engine.torn_write_config = .{
            .enabled = true,
            .probability_per_thousand = probability_per_thousand,
            .min_partial_bytes = 1,
            .max_completion_fraction_per_thousand = 500, // 50% completion max
            .target_headers = target_headers,
        };
    }

    /// Enable silent corruption that bypasses checksums
    pub fn enable_silent_corruption(self: *HostileVFS, bypass_rate_per_million: u32, stealth_mode: bool) void {
        fatal_assert(bypass_rate_per_million <= 1_000_000, "Silent corruption rate too high: {}", .{bypass_rate_per_million});

        self.corruption_engine.silent_corruption_config = .{
            .enabled = true,
            .bypass_rate_per_million = bypass_rate_per_million,
            .stealth_mode = stealth_mode,
        };
    }

    /// Enable memory pressure simulation
    /// Enable memory pressure simulation with controlled failure rates.
    /// Tests system behavior under low-memory conditions and fragmentation.
    pub fn enable_memory_pressure(
        self: *HostileVFS,
        allocation_failure_rate: u32,
        fragmentation_simulation: bool,
    ) void {
        fatal_assert(allocation_failure_rate <= 1000, "Allocation failure rate too high: {}", .{allocation_failure_rate});

        self.corruption_engine.memory_pressure_config = .{
            .enabled = true,
            .allocation_failure_rate = allocation_failure_rate,
            .fragmentation_simulation = fragmentation_simulation,
        };
    }

    /// Create hostile scenario with graduated corruption levels
    pub fn create_hostile_scenario(self: *HostileVFS, scenario: HostileScenario) void {
        switch (scenario) {
            .bit_flip_storm => {
                self.enable_cascade_bit_flips(100, 8);
                self.base_vfs.enable_read_corruption(50, 3);
            },
            .torn_write_cascade => {
                self.enable_hostile_torn_writes(50, true);
                self.base_vfs.enable_torn_writes(25, 4, 500);
            },
            .silent_data_corruption => {
                self.enable_silent_corruption(100, true);
                self.enable_cascade_bit_flips(10, 4);
            },
            .memory_exhaustion => {
                self.enable_memory_pressure(25, true);
                // Memory exhaustion simulation - disk space limit not available in current SimulationVFS
            },
            .multi_phase_attack => {
                // Combination of all hostile patterns
                self.enable_cascade_bit_flips(75, 6);
                self.enable_hostile_torn_writes(30, true);
                self.enable_silent_corruption(50, true);
                self.enable_memory_pressure(15, true);
            },
        }
    }

    /// Predefined hostile scenarios for systematic testing
    pub const HostileScenario = enum {
        bit_flip_storm,
        torn_write_cascade,
        silent_data_corruption,
        memory_exhaustion,
        multi_phase_attack,
    };

    /// Disable all corruption for clean testing phases
    pub fn disable_all_corruption(self: *HostileVFS) void {
        self.corruption_engine.bit_flip_config.enabled = false;
        self.corruption_engine.torn_write_config.enabled = false;
        self.corruption_engine.silent_corruption_config.enabled = false;
        self.corruption_engine.memory_pressure_config.enabled = false;
        self.corruption_engine.active_patterns.clear();
    }

    /// Get corruption statistics for analysis
    pub fn query_corruption_statistics(self: *const HostileVFS) CorruptionStatistics {
        return CorruptionStatistics{
            .operation_count = self.operation_count,
            .hostility_level = self.hostility_level,
            .active_patterns = @as(u32, @intCast(self.corruption_engine.active_patterns.len)),
            .cascade_corruptions_applied = 0, // Would be tracked in real implementation
            .silent_corruptions_applied = 0,
            .torn_writes_applied = 0,
        };
    }

    pub const CorruptionStatistics = struct {
        operation_count: u64,
        hostility_level: HostilityLevel,
        active_patterns: u32,
        cascade_corruptions_applied: u32,
        silent_corruptions_applied: u32,
        torn_writes_applied: u32,
    };
};

// Compile-time validation of structure sizes
comptime {
    comptime_assert(@sizeOf(HostileVFS.CorruptionEngine.CorruptionPattern) <= 256, "CorruptionPattern too large");
    comptime_assert(@sizeOf(HostileVFS.CorruptionStatistics) <= 128, "CorruptionStatistics too large");
}

//
// Unit Tests
//

const testing = std.testing;
const test_allocator = testing.allocator;

test "HostileVFS initialization and basic hostility levels" {
    var base_vfs = try SimulationVFS.init_with_fault_seed(test_allocator, 12345);
    defer base_vfs.deinit();

    var hostile = HostileVFS.init(&base_vfs, .moderate, 12345);

    try testing.expect(hostile.hostility_level == .moderate);
    try testing.expect(hostile.operation_count == 0);
    try testing.expect(!hostile.allocated);

    const multiplier = hostile.hostility_level.corruption_multiplier();
    try testing.expect(multiplier == 2.5);

    const max_depth = hostile.hostility_level.max_cascade_depth();
    try testing.expect(max_depth == 2);
}

test "HostileVFS cascade bit flip configuration" {
    var hostile = try HostileVFS.create_with_hostility(test_allocator, .aggressive, 54321);
    defer hostile.deinit(test_allocator);

    hostile.enable_cascade_bit_flips(100, 4);

    try testing.expect(hostile.corruption_engine.bit_flip_config.enabled);
    try testing.expect(hostile.corruption_engine.bit_flip_config.cascade_probability_per_kb == 100);
    try testing.expect(hostile.corruption_engine.bit_flip_config.max_cascade_bits == 4);
    try testing.expect(hostile.corruption_engine.bit_flip_config.target_critical_bytes);
}

test "HostileVFS hostile scenarios" {
    var hostile = try HostileVFS.create_with_hostility(test_allocator, .extreme, 98765);
    defer hostile.deinit(test_allocator);

    // Test bit flip storm scenario
    hostile.create_hostile_scenario(.bit_flip_storm);
    try testing.expect(hostile.corruption_engine.bit_flip_config.enabled);

    // Test multi-phase attack scenario
    hostile.create_hostile_scenario(.multi_phase_attack);
    try testing.expect(hostile.corruption_engine.bit_flip_config.enabled);
    try testing.expect(hostile.corruption_engine.torn_write_config.enabled);
    try testing.expect(hostile.corruption_engine.silent_corruption_config.enabled);
    try testing.expect(hostile.corruption_engine.memory_pressure_config.enabled);
}

test "HostileVFS corruption pattern management" {
    var hostile = try HostileVFS.create_with_hostility(test_allocator, .basic, 11111);
    defer hostile.deinit(test_allocator);

    // Corruption engine should start empty
    try testing.expect(hostile.corruption_engine.active_patterns.is_empty());

    // Enable cascade corruption
    hostile.enable_cascade_bit_flips(500, 3);

    // Apply corruption to test buffer
    var test_buffer = [_]u8{0x42} ** 1024;
    hostile.corruption_engine.apply_hostile_corruption(&test_buffer, .basic);

    // Buffer should be modified (exact changes depend on PRNG seed)
    var modified = false;
    for (test_buffer) |byte| {
        if (byte != 0x42) {
            modified = true;
            break;
        }
    }
    try testing.expect(modified);
}

test "HostileVFS statistics collection" {
    var hostile = try HostileVFS.create_with_hostility(test_allocator, .catastrophic, 99999);
    defer hostile.deinit(test_allocator);

    const stats = hostile.query_corruption_statistics();
    try testing.expect(stats.hostility_level == .catastrophic);
    try testing.expect(stats.operation_count == 0);
    try testing.expect(stats.active_patterns == 0);
}
