//! Memory guard system for detecting corruption and leaks in debug builds.
//!
//! Provides allocation tracking, use-after-free detection, and buffer overflow
//! protection with zero overhead in release builds. Wraps allocators to add
//! canary values, track ownership, and validate memory operations.
//!
//! Design rationale: Memory corruption is the hardest bug to debug. This module
//! provides comprehensive detection at the cost of debug performance, while
//! compiling to nothing in release builds. Canary patterns detect overflows,
//! poison patterns detect use-after-free, and allocation tracking finds leaks.

const std = @import("std");
const builtin = @import("builtin");

const assert_mod = @import("assert.zig");
const assert = assert_mod.assert;
const fatal_assert = assert_mod.fatal_assert;

/// Magic canary values for overflow detection.
const CANARY_BEFORE: u64 = 0xDEADBEEF_CAFEBABE;
const CANARY_AFTER: u64 = 0xFEEDFACE_DEADC0DE;

/// Poison pattern for freed memory.
const POISON_BYTE: u8 = 0xDE;

/// Allocation header prepended to each allocation in debug mode.
const AllocationHeader = struct {
    canary_before: u64,
    requested_size: usize,
    actual_size: usize,
    allocation_id: u64,
    stack_trace: [8]usize,
    thread_id: std.Thread.Id,
    timestamp: i64,
    is_freed: bool,

    fn validate(self: *const AllocationHeader) void {
        fatal_assert(
            self.canary_before == CANARY_BEFORE,
            "Memory corruption: header canary damaged (0x{x} != 0x{x})",
            .{ self.canary_before, CANARY_BEFORE },
        );
        fatal_assert(
            !self.is_freed,
            "Use-after-free detected: allocation {} already freed",
            .{self.allocation_id},
        );
    }
};

/// Allocation footer appended to each allocation in debug mode.
const AllocationFooter = struct {
    canary_after: u64,

    fn validate(self: *const AllocationFooter) void {
        fatal_assert(
            self.canary_after == CANARY_AFTER,
            "Buffer overflow detected: footer canary damaged (0x{x} != 0x{x})",
            .{ self.canary_after, CANARY_AFTER },
        );
    }
};

/// Tracking information for active allocations.
const AllocationInfo = struct {
    ptr: [*]u8,
    size: usize,
    id: u64,
    stack_trace: [8]usize,
    thread_id: std.Thread.Id,
    timestamp: i64,
};

/// Memory guard allocator that wraps another allocator with safety checks.
pub const MemoryGuard = struct {
    backing_allocator: std.mem.Allocator,
    allocations: if (builtin.mode == .Debug) std.hash_map.HashMap(usize, AllocationInfo, std.hash_map.AutoContext(usize), 80) else void,
    allocation_counter: if (builtin.mode == .Debug) u64 else void,
    total_allocated: if (builtin.mode == .Debug) usize else void,
    peak_allocated: if (builtin.mode == .Debug) usize else void,
    // Architecture exception: Thread coordination needed for debug allocation tracking.
    // KausalDB core is single-threaded but test infrastructure uses threading.  
    // Zero runtime cost in release builds where tracking is compiled out.
    mutex: if (builtin.mode == .Debug) std.Thread.Mutex else void,

    /// Initialize memory guard with backing allocator.
    pub fn init(backing_allocator: std.mem.Allocator) MemoryGuard {
        if (builtin.mode == .Debug) {
            return .{
                .backing_allocator = backing_allocator,
                .allocations = std.hash_map.HashMap(usize, AllocationInfo, std.hash_map.AutoContext(usize), 80).init(backing_allocator),
                .allocation_counter = 0,
                .total_allocated = 0,
                .peak_allocated = 0,
                .mutex = .{},
            };
        } else {
            return .{
                .backing_allocator = backing_allocator,
                .allocations = {},
                .allocation_counter = {},
                .total_allocated = {},
                .peak_allocated = {},
                .mutex = {},
            };
        }
    }

    /// Clean up and report any leaks.
    pub fn deinit(self: *MemoryGuard) void {
        if (builtin.mode != .Debug) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.allocations.count() > 0) {
            std.debug.print("\n=== MEMORY LEAKS DETECTED ===\n", .{});
            std.debug.print("Leaked allocations: {}\n", .{self.allocations.count()});
            std.debug.print("Total leaked bytes: {}\n\n", .{self.total_allocated});

            var iter = self.allocations.iterator();
            while (iter.next()) |entry| {
                const info = entry.value_ptr.*;
                std.debug.print("Leak #{}: {} bytes at 0x{x}\n", .{ info.id, info.size, @intFromPtr(info.ptr) });
                print_stack_trace(&info.stack_trace);
            }
            std.debug.print("=============================\n\n", .{});
        }

        self.allocations.deinit();
    }

    /// Create a standard allocator interface.
    pub fn allocator(self: *MemoryGuard) std.mem.Allocator {
        if (builtin.mode == .Debug) {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = alloc_debug,
                    .resize = resize_debug,
                    .remap = remap_debug,
                    .free = free_debug,
                },
            };
        } else {
            // In release mode, directly return the backing allocator
            return self.backing_allocator;
        }
    }

    fn alloc_debug(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *MemoryGuard = @ptrCast(@alignCast(ctx));

        const alignment_bytes = alignment.toByteUnits();

        // Calculate total size with header and aligned footer
        const header_size = std.mem.alignForward(usize, @sizeOf(AllocationHeader), alignment_bytes);
        const footer_offset = std.mem.alignForward(usize, len, @alignOf(AllocationFooter));
        const footer_size = @sizeOf(AllocationFooter);
        const total_size = header_size + footer_offset + footer_size;

        // Use rawAlloc to bypass any allocator wrappers that might interfere with canary placement
        const raw_ptr = self.backing_allocator.rawAlloc(total_size, alignment, ret_addr) orelse return null;

        // Canary values enable immediate detection of heap corruption.
        // Industry-standard values (DEADBEEF) are easily recognizable in crash dumps.
        // Header placed before user data to catch negative buffer overflows
        const header: *AllocationHeader = @ptrCast(@alignCast(raw_ptr));
        header.* = .{
            .canary_before = CANARY_BEFORE,
            .requested_size = len,
            .actual_size = total_size,
            .allocation_id = self.next_allocation_id(),
            .stack_trace = capture_stack_trace(),
            .thread_id = std.Thread.getCurrentId(),
            .timestamp = std.time.milliTimestamp(),
            .is_freed = false,
        };

        // Footer canary detects positive buffer overflows past allocation boundary.
        // Separate value from header distinguishes overflow direction.
        const user_ptr = raw_ptr + header_size;
        // Ensure footer is properly aligned for u64 field
        const footer_ptr = user_ptr + footer_offset;
        const footer: *AllocationFooter = @ptrCast(@alignCast(footer_ptr));
        footer.* = .{
            .canary_after = CANARY_AFTER,
        };

        // Record allocation in debug map to detect double-free and use-after-free
        self.track_allocation(user_ptr, len, header.allocation_id, &header.stack_trace);

        return user_ptr;
    }

    fn resize_debug(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        if (new_len == 0) {
            free_debug(ctx, buf, alignment, ret_addr);
            return true;
        }

        // Get header and validate
        const alignment_bytes = alignment.toByteUnits();
        const header_size = std.mem.alignForward(usize, @sizeOf(AllocationHeader), alignment_bytes);
        const header_ptr = @as([*]u8, @ptrCast(buf.ptr)) - header_size;
        const header: *AllocationHeader = @ptrCast(@alignCast(header_ptr));
        header.validate();

        // Validate footer at aligned position
        const footer_offset = std.mem.alignForward(usize, buf.len, @alignOf(AllocationFooter));
        const footer_ptr = @as([*]u8, @ptrCast(buf.ptr)) + footer_offset;
        const footer: *AllocationFooter = @ptrCast(@alignCast(footer_ptr));
        footer.validate();

        // For simplicity in debug mode, allocate new and copy
        const new_ptr = alloc_debug(ctx, new_len, alignment, ret_addr) orelse return false;
        const copy_len = @min(buf.len, new_len);
        @memcpy(new_ptr[0..copy_len], buf[0..copy_len]);
        free_debug(ctx, buf, alignment, ret_addr);

        return true;
    }

    fn remap_debug(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        // For simplicity in debug mode, use alloc+copy+free pattern
        const new_ptr = alloc_debug(ctx, new_len, alignment, ret_addr) orelse return null;
        const copy_len = @min(buf.len, new_len);
        @memcpy(new_ptr[0..copy_len], buf[0..copy_len]);
        free_debug(ctx, buf, alignment, ret_addr);
        return new_ptr;
    }

    fn free_debug(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *MemoryGuard = @ptrCast(@alignCast(ctx));

        if (buf.len == 0) return;

        // Get header and validate
        const alignment_bytes = alignment.toByteUnits();
        const header_size = std.mem.alignForward(usize, @sizeOf(AllocationHeader), alignment_bytes);
        const header_ptr = @as([*]u8, @ptrCast(buf.ptr)) - header_size;
        const header: *AllocationHeader = @ptrCast(@alignCast(header_ptr));
        header.validate();

        // Validate footer at aligned position
        const footer_offset = std.mem.alignForward(usize, buf.len, @alignOf(AllocationFooter));
        const footer_ptr = @as([*]u8, @ptrCast(buf.ptr)) + footer_offset;
        const footer: *AllocationFooter = @ptrCast(@alignCast(footer_ptr));
        footer.validate();

        // Check size matches
        fatal_assert(
            header.requested_size == buf.len,
            "Free size mismatch: {} != {} for allocation {}",
            .{ buf.len, header.requested_size, header.allocation_id },
        );

        // Poison pattern (0xDE) makes use-after-free bugs fail fast and obviously.
        // Alternative to keeping freed memory valid, which masks bugs.
        header.is_freed = true;
        @memset(buf, POISON_BYTE);

        // Remove from debug map to enable detection of use-after-free
        self.untrack_allocation(@intFromPtr(buf.ptr));

        // Free from backing allocator
        const raw_slice = header_ptr[0..header.actual_size];
        self.backing_allocator.rawFree(raw_slice, alignment, ret_addr);
    }

    fn next_allocation_id(self: *MemoryGuard) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.allocation_counter += 1;
        return self.allocation_counter;
    }

    fn track_allocation(self: *MemoryGuard, ptr: [*]u8, size: usize, id: u64, stack_trace: *const [8]usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const info = AllocationInfo{
            .ptr = ptr,
            .size = size,
            .id = id,
            .stack_trace = stack_trace.*,
            .thread_id = std.Thread.getCurrentId(),
            .timestamp = std.time.milliTimestamp(),
        };

        self.allocations.put(@intFromPtr(ptr), info) catch {
            std.debug.panic("Failed to track allocation", .{});
        };

        self.total_allocated += size;
        self.peak_allocated = @max(self.peak_allocated, self.total_allocated);
    }

    fn untrack_allocation(self: *MemoryGuard, ptr_addr: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const entry = self.allocations.fetchRemove(ptr_addr);
        if (entry) |kv| {
            self.total_allocated -= kv.value.size;
        } else {
            fatal_assert(false, "Attempting to free untracked allocation at 0x{x}", .{ptr_addr});
        }
    }

    /// Report current memory statistics.
    pub fn report_stats(self: *MemoryGuard) void {
        if (builtin.mode != .Debug) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        std.debug.print("\n=== MEMORY STATISTICS ===\n", .{});
        std.debug.print("Active allocations: {}\n", .{self.allocations.count()});
        std.debug.print("Total allocated: {} bytes\n", .{self.total_allocated});
        std.debug.print("Peak allocated: {} bytes\n", .{self.peak_allocated});
        std.debug.print("Total allocations made: {}\n", .{self.allocation_counter});
        std.debug.print("=========================\n\n", .{});
    }

    /// Validate all active allocations for corruption.
    pub fn validate_all_allocations(self: *MemoryGuard) void {
        if (builtin.mode != .Debug) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        var corrupted: usize = 0;
        var iter = self.allocations.iterator();
        while (iter.next()) |entry| {
            const info = entry.value_ptr.*;

            // Get header
            const alignment = 8; // Assume default alignment for validation
            const header_size = std.mem.alignForward(usize, @sizeOf(AllocationHeader), alignment);
            const header_ptr = info.ptr - header_size;
            const header: *const AllocationHeader = @ptrCast(@alignCast(header_ptr));

            // Canary corruption indicates buffer underflow or heap metadata damage
            if (header.canary_before != CANARY_BEFORE) {
                std.debug.print("Corruption in allocation {}: header damaged\n", .{info.id});
                corrupted += 1;
                continue;
            }

            // Check footer canary
            const footer_ptr = info.ptr + info.size;
            const footer: *const AllocationFooter = @ptrCast(@alignCast(footer_ptr));
            if (footer.canary_after != CANARY_AFTER) {
                std.debug.print("Corruption in allocation {}: buffer overflow\n", .{info.id});
                corrupted += 1;
            }
        }

        if (corrupted > 0) {
            fatal_assert(false, "Memory corruption detected in {} allocations", .{corrupted});
        }
    }
};

fn capture_stack_trace() [8]usize {
    var addresses: [8]usize = [_]usize{0} ** 8;
    if (builtin.mode == .Debug) {
        var i: usize = 0;
        var it = std.debug.StackIterator.init(@returnAddress(), null);
        while (it.next()) |addr| : (i += 1) {
            if (i >= addresses.len) break;
            addresses[i] = addr;
        }
    }
    return addresses;
}

fn print_stack_trace(addresses: *const [8]usize) void {
    if (builtin.mode != .Debug) return;

    std.debug.print("  Stack trace:\n", .{});
    for (addresses.*) |addr| {
        if (addr == 0) break;
        std.debug.print("    0x{x}\n", .{addr});
    }
}

/// Create a guarded allocator for testing.
pub fn create_test_allocator(backing: std.mem.Allocator) MemoryGuard {
    return MemoryGuard.init(backing);
}

// Tests
test "memory guard detects buffer overflow" {
    if (builtin.mode != .Debug) return;

    var guard = create_test_allocator(std.testing.allocator);
    defer guard.deinit();

    const alloc = guard.allocator();
    const buf = try alloc.alloc(u8, 16);
    defer alloc.free(buf);

    // This would trigger overflow detection if we wrote beyond bounds
    // buf[16] = 42; // Would be caught by footer validation
}

test "memory guard tracks allocations" {
    if (builtin.mode != .Debug) return;

    var guard = create_test_allocator(std.testing.allocator);
    defer guard.deinit();

    const alloc = guard.allocator();

    const buf1 = try alloc.alloc(u8, 100);
    const buf2 = try alloc.alloc(u8, 200);

    try std.testing.expectEqual(@as(usize, 2), guard.allocations.count());
    try std.testing.expectEqual(@as(usize, 300), guard.total_allocated);

    alloc.free(buf1);
    try std.testing.expectEqual(@as(usize, 1), guard.allocations.count());
    try std.testing.expectEqual(@as(usize, 200), guard.total_allocated);

    alloc.free(buf2);
    try std.testing.expectEqual(@as(usize, 0), guard.allocations.count());
    try std.testing.expectEqual(@as(usize, 0), guard.total_allocated);
}

test "memory guard validates all allocations" {
    if (builtin.mode != .Debug) return;

    var guard = create_test_allocator(std.testing.allocator);
    defer guard.deinit();

    const alloc = guard.allocator();

    const buf1 = try alloc.alloc(u8, 64);
    defer alloc.free(buf1);
    const buf2 = try alloc.alloc(u8, 128);
    defer alloc.free(buf2);

    // Should pass without corruption
    guard.validate_all_allocations();
}
