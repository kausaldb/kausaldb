//! Standard library extensions with defensive programming checks.
//!
//! Provides safer alternatives to std library functions and thread-safe primitives
//! with explicit buffer validation and consistent error handling patterns.

const std = @import("std");

const assert_mod = @import("assert.zig");

const assert = assert_mod.assert;

/// DateTime in UTC, intended primarily for logging.
///
/// NB: this is a pure function of a timestamp. To convert timestamp to UTC, no knowledge of
/// timezones or leap seconds is necessary.
pub const DateTimeUTC = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    millisecond: u16,

    pub fn now() DateTimeUTC {
        const timestamp_ms = std.time.milliTimestamp();
        assert(timestamp_ms > 0);
        return DateTimeUTC.from_timestamp_ms(@intCast(timestamp_ms));
    }

    pub fn from_timestamp_s(timestamp_s: u64) DateTimeUTC {
        return DateTimeUTC.from_timestamp_ms(timestamp_s * std.time.ms_per_s);
    }

    pub fn from_timestamp_ms(timestamp_ms: u64) DateTimeUTC {
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @divTrunc(timestamp_ms, 1000) };
        const year_day = epoch_seconds.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const time = epoch_seconds.getDaySeconds();

        return DateTimeUTC{
            .year = year_day.year,
            .month = month_day.month.numeric(),
            .day = month_day.day_index + 1,
            .hour = time.getHoursIntoDay(),
            .minute = time.getMinutesIntoHour(),
            .second = time.getSecondsIntoMinute(),
            .millisecond = @intCast(@mod(timestamp_ms, 1000)),
        };
    }

    pub fn format(
        datetime: DateTimeUTC,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
            datetime.year,
            datetime.month,
            datetime.day,
            datetime.hour,
            datetime.minute,
            datetime.second,
            datetime.millisecond,
        });
    }
};

/// An alternative to the default logFn from `std.log`, which prepends a UTC timestamp.
pub fn log_with_timestamp(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_text = comptime message_level.asText();
    const scope_prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    const date_time = DateTimeUTC.now();

    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderrWriter(&buffer);
    defer std.debug.unlockStderrWriter();

    nosuspend {
        date_time.format("", .{}, stderr) catch return;
        stderr.print(" " ++ level_text ++ scope_prefix ++ format ++ "\n", args) catch return;
    }
}

/// Thread-safe metrics counter for tracking various statistics.
///
/// This provides atomic operations for incrementing, getting, and resetting
/// a counter value in a thread-safe manner.
pub const MetricsCounter = struct {
    value: std.atomic.Value(u64) = .{ .raw = 0 },

    /// Initialize a new counter with an initial value.
    pub fn init(initial_value: u64) MetricsCounter {
        return .{ .value = .{ .raw = initial_value } };
    }

    /// Atomically increment the counter by the specified amount.
    pub fn add(self: *MetricsCounter, amount: u64) void {
        _ = self.value.fetchAdd(amount, .monotonic);
    }

    /// Atomically increment the counter by 1.
    pub fn incr(self: *MetricsCounter) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    /// Atomic read with monotonic ordering for thread-safe access.
    pub fn load(self: *const MetricsCounter) u64 {
        return self.value.load(.monotonic);
    }

    /// Atomic replace with monotonic ordering for thread-safe updates.
    pub fn store(self: *MetricsCounter, new_value: u64) void {
        _ = self.value.swap(new_value, .monotonic);
    }

    /// Atomic reset to zero for clean metric initialization.
    pub fn reset(self: *MetricsCounter) void {
        _ = self.value.swap(0, .monotonic);
    }
};

/// Simple value container - no protection needed in single-threaded KausalDB.
/// This type exists for API consistency where thread-safety was once considered.
pub fn ProtectedType(comptime T: type) type {
    return struct {
        value: T,

        const Self = @This();

        /// Initialize a new value.
        pub fn init(value: T) Self {
            return .{ .value = value };
        }

        /// Access the value directly with a callback for API consistency.
        pub fn with(
            self: *Self,
            comptime F: type,
            context: anytype,
            func: F,
        ) @typeInfo(@TypeOf(func)).@"fn".return_type.? {
            const func_info = @typeInfo(@TypeOf(func)).@"fn";
            const Context = @TypeOf(context);
            if (func_info.params.len == 1) {
                return @call(.auto, func, .{&self.value});
            } else if (Context == void) {
                return @call(.auto, func, .{ &self.value, {} });
            } else {
                return @call(.auto, func, .{ &self.value, context });
            }
        }
    };
}

/// Copy memory from source to destination with left-to-right ordering
///
/// Use this instead of std.mem.copyForwards for explicit directional semantics.
/// Left-to-right copy is safe for overlapping buffers where destination starts
/// before source, preventing corruption during the copy operation.
pub fn copy_left(comptime T: type, dest: []T, source: []const T) void {
    assert(dest.len >= source.len);
    // Safety: Converting pointers to integers to detect overlapping memory regions
    assert(@intFromPtr(dest.ptr) != @intFromPtr(source.ptr) or dest.len == 0);
    std.mem.copyForwards(T, dest, source);
}

/// Copy memory with overlapping source and destination buffers
///
/// Use this for buffer compaction where source and destination overlap.
/// Specifically handles the case where destination starts before source,
/// which is safe with left-to-right copying semantics.
/// Copy memory from source to destination with right-to-left ordering
///
/// Use this instead of std.mem.copyBackwards for explicit directional semantics.
/// Right-to-left copy is safe for overlapping buffers where destination starts
/// after source, preventing corruption during the copy operation.
pub fn copy_right(comptime T: type, dest: []T, source: []const T) void {
    assert(dest.len >= source.len);
    // Safety: Converting pointers to integers to detect overlapping memory regions
    assert(@intFromPtr(dest.ptr) != @intFromPtr(source.ptr) or dest.len == 0);

    std.mem.copyBackwards(T, dest, source);
}

/// Copy memory between non-overlapping buffers
///
/// Use this instead of std.mem.copy for explicit non-overlap semantics.
/// This function asserts that buffers do not overlap, preventing subtle
/// corruption bugs that can occur with overlapping copies.
/// Safe wrapper around std.StaticBitSet with consistent naming conventions
///
/// Use this instead of std.StaticBitSet for consistent snake_case method names
/// and defensive programming checks. Provides the same functionality with
/// improved API consistency across the codebase.
pub fn BitSetType(comptime size: comptime_int) type {
    return struct {
        inner: std.StaticBitSet(size),

        const Self = @This();

        pub fn init_empty() Self {
            return Self{ .inner = std.StaticBitSet(size).initEmpty() };
        }

        pub fn init_full() Self {
            return Self{ .inner = std.StaticBitSet(size).initFull() };
        }

        pub fn set(self: *Self, index: usize) void {
            assert(index < size);
            self.inner.set(index);
        }

        pub fn unset(self: *Self, index: usize) void {
            assert(index < size);
            self.inner.unset(index);
        }

        pub fn is_set(self: Self, index: usize) bool {
            assert(index < size);
            return self.inner.isSet(index);
        }

        pub fn toggle(self: *Self, index: usize) void {
            assert(index < size);
            self.inner.toggle(index);
        }

        pub fn count(self: Self) usize {
            return self.inner.count();
        }

        pub fn capacity(self: Self) usize {
            return self.inner.capacity();
        }
    };
}
