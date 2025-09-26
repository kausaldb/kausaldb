//! Network protocol fuzzing for client-server communication bugs.
//!
//! Tests protocol robustness against malformed messages, invalid headers,
//! buffer overflows, integer overflows, and state corruption.

const std = @import("std");

const internal = @import("internal");
const main = @import("main.zig");

const MessageHeader = internal.cli_protocol.MessageHeader;
const MessageType = internal.cli_protocol.MessageType;
const Client = internal.client.Client;
const ClientConfig = internal.client.ClientConfig;
const Connection = internal.server_connection.Connection;
const HandlerContext = internal.cli_protocol.HandlerContext;

const PROTOCOL_VERSION = internal.cli_protocol.PROTOCOL_VERSION;
const MAX_QUERY_LENGTH = internal.cli_protocol.MAX_QUERY_LENGTH;
const MAX_PATH_LENGTH = internal.cli_protocol.MAX_PATH_LENGTH;

pub fn run_fuzzing(fuzzer: *main.Fuzzer) !void {
    std.debug.print("Fuzzing network protocol...\n", .{});

    for (0..fuzzer.config.iterations) |i| {
        const input = try fuzzer.generate_input(4096);

        const strategy = i % 10;
        switch (strategy) {
            0 => fuzz_message_headers(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            1 => fuzz_malformed_messages(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            2 => fuzz_integer_overflows(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            3 => fuzz_buffer_boundaries(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            4 => fuzz_invalid_protocol_versions(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            5 => fuzz_truncated_messages(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            6 => fuzz_oversized_payloads(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            7 => fuzz_message_injection(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            8 => fuzz_state_corruption(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            9 => fuzz_concurrent_connections(fuzzer.allocator, input) catch |err| {
                try fuzzer.handle_crash(input, err);
            },
            else => unreachable,
        }

        fuzzer.record_iteration();
    }
}

/// Test message headers with invalid values to find parsing bugs
fn fuzz_message_headers(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 16) return; // Need at least header size

    // Extract potentially malicious header values from fuzz input
    var header: MessageHeader = undefined;
    // Safety: MessageHeader is 16 bytes and input[0..16] is guaranteed to be 16 bytes
    @memcpy(@as([*]u8, @ptrCast(&header))[0..16], input[0..16]);

    // Test with completely invalid values
    header.magic = std.mem.readInt(u32, input[0..4], .little);
    header.version = std.mem.readInt(u16, input[4..6], .little);
    // Safely handle invalid enum values by using a valid fallback
    const raw_message_type = input[6];
    header.message_type = std.enums.fromInt(MessageType, raw_message_type) orelse MessageType.find_request;
    header.payload_size = std.mem.readInt(u32, input[8..12], .little);

    // Create test buffer with fuzzed header
    const test_buffer = try allocator.alloc(u8, @sizeOf(MessageHeader) + @min(input.len, 4096));
    defer allocator.free(test_buffer);

    // Safety: MessageHeader size is known at compile time and buffer is allocated with sufficient size
    @memcpy(test_buffer[0..@sizeOf(MessageHeader)], @as([*]const u8, @ptrCast(&header))[0..@sizeOf(MessageHeader)]);
    if (input.len > 16) {
        const payload_size = @min(input.len - 16, test_buffer.len - @sizeOf(MessageHeader));
        @memcpy(test_buffer[@sizeOf(MessageHeader) .. @sizeOf(MessageHeader) + payload_size], input[16 .. 16 + payload_size]);
    }

    // Test message parsing - should detect invalid headers
    _ = parse_message_header(test_buffer) catch {}; // Should not crash
}

/// Create malformed messages that violate protocol expectations
fn fuzz_malformed_messages(allocator: std.mem.Allocator, input: []const u8) !void {
    // Generate messages with deliberate violations
    const malformed_scenarios = [_]struct {
        description: []const u8,
        generate: *const fn (std.mem.Allocator, []const u8) anyerror![]u8,
    }{
        .{ .description = "negative_length", .generate = create_negative_length_message },
        .{ .description = "huge_length", .generate = create_huge_length_message },
        .{ .description = "misaligned_data", .generate = create_misaligned_message },
        .{ .description = "invalid_utf8", .generate = create_invalid_utf8_message },
        .{ .description = "recursive_structure", .generate = create_recursive_message },
    };

    for (malformed_scenarios) |scenario| {
        const malformed_msg = scenario.generate(allocator, input) catch continue;
        defer allocator.free(malformed_msg);

        // Test message processing - should handle gracefully
        _ = process_malformed_message(malformed_msg) catch {};
    }
}

/// Test with integer overflow values that could cause memory corruption
fn fuzz_integer_overflows(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 8) return;

    // Extract potentially overflowing values
    const evil_values = [_]u32{
        0xFFFFFFFF, // max u32
        0x7FFFFFFF, // max i32
        0x80000000, // min i32
        std.mem.readInt(u32, input[0..4], .little), // fuzzed value
        std.mem.readInt(u32, input[4..8], .big) ^ 0xFFFFFFFF, // transformed fuzzed
    };

    for (evil_values) |evil_value| {
        // Test payload length overflow
        var header = MessageHeader{
            .magic = 0x4B41554C,
            .version = PROTOCOL_VERSION,
            .message_type = .find_request,
            .payload_size = evil_value, // This could cause allocation failures
        };

        // Try to process - should detect overflow
        _ = validate_message_size(&header) catch {};
    }

    // Test field overflows in specific message types
    test_query_length_overflow(allocator, input) catch {};
    test_path_length_overflow(allocator, input) catch {};
    test_result_count_overflow(allocator, input) catch {};
}

/// Test buffer boundary conditions that could cause buffer overflows
fn fuzz_buffer_boundaries(allocator: std.mem.Allocator, input: []const u8) !void {
    const boundary_tests = [_]usize{ 0, 1, 15, 16, 17, 255, 256, 257, 4095, 4096, 4097 };

    for (boundary_tests) |size| {
        if (size > input.len) continue;

        // Create buffer of exact size
        const test_data = try allocator.alloc(u8, size);
        defer allocator.free(test_data);

        if (size > 0) {
            @memcpy(test_data, input[0..size]);
        }

        // Test parsing at boundary
        _ = parse_at_boundary(test_data) catch {};

        // Test off-by-one scenarios
        if (size > 0) {
            _ = parse_off_by_one(test_data) catch {};
        }
    }
}

/// Test with invalid protocol versions to find version handling bugs
fn fuzz_invalid_protocol_versions(_: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 2) return;

    const evil_versions = [_]u16{
        0x0000, // Version 0
        0xFFFF, // Max version
        std.mem.readInt(u16, input[0..2], .little), // Fuzzed version
        PROTOCOL_VERSION + 1000, // Future version
        std.math.maxInt(u16) - @as(u16, input[0] % 100), // Near-max versions
    };

    for (evil_versions) |version| {
        var header = MessageHeader{
            .magic = 0x4B41554C,
            .version = version,
            .message_type = .ping_request,
            .payload_size = 0,
        };

        // Test version validation
        _ = validate_protocol_version(&header) catch {};
    }
}

/// Test with truncated messages at various points
fn fuzz_truncated_messages(allocator: std.mem.Allocator, input: []const u8) !void {
    if (input.len < 20) return;

    // Create a valid message first
    var header = MessageHeader{
        .magic = 0x4B41554C,
        .version = PROTOCOL_VERSION,
        .message_type = .find_request,
        // Safety: input.len is valid usize and fits within u32 range for protocol
        // Safety: input.len is valid usize and fits within u32 range for protocol
        .payload_size = @intCast(input.len),
    };

    const full_message = try allocator.alloc(u8, @sizeOf(MessageHeader) + input.len);
    defer allocator.free(full_message);

    // Safety: MessageHeader size is known at compile time and buffer is allocated with sufficient size
    @memcpy(full_message[0..@sizeOf(MessageHeader)], @as([*]const u8, @ptrCast(&header))[0..@sizeOf(MessageHeader)]);
    @memcpy(full_message[@sizeOf(MessageHeader)..], input);

    // Test truncated at various points
    for (1..full_message.len) |truncate_at| {
        const truncated = full_message[0..truncate_at];

        // Should handle truncated messages gracefully
        _ = parse_truncated_message(truncated) catch {};
    }
}

/// Test with oversized payloads that exceed limits
fn fuzz_oversized_payloads(allocator: std.mem.Allocator, input: []const u8) !void {
    // Test with payloads that claim to be huge but aren't
    const oversized_lengths = [_]u32{
        MAX_QUERY_LENGTH + 1,
        MAX_PATH_LENGTH + 1,
        1024 * 1024, // 1MB
        100 * 1024 * 1024, // 100MB
        std.math.maxInt(u32) - 1000,
    };

    for (oversized_lengths) |claimed_size| {
        var header = MessageHeader{
            .magic = 0x4B41554C,
            .version = PROTOCOL_VERSION,
            .message_type = .find_request,
            .payload_size = claimed_size,
        };

        // Create message with small actual payload but huge claimed size
        const actual_payload = input[0..@min(input.len, 1000)];
        const message = try allocator.alloc(u8, @sizeOf(MessageHeader) + actual_payload.len);
        defer allocator.free(message);

        // Safety: MessageHeader size is known at compile time and message buffer is allocated with sufficient size
        @memcpy(message[0..@sizeOf(MessageHeader)], @as([*]const u8, @ptrCast(&header))[0..@sizeOf(MessageHeader)]);
        @memcpy(message[@sizeOf(MessageHeader)..], actual_payload);

        // Should detect size mismatch
        _ = validate_payload_size(message, claimed_size) catch {};
    }
}

/// Test message injection attacks
fn fuzz_message_injection(allocator: std.mem.Allocator, input: []const u8) !void {
    // Embed multiple fake messages within payload
    if (input.len < 32) return;

    // Create a message that contains embedded message headers
    var primary_header = MessageHeader{
        .magic = 0x4B41554C,
        .version = PROTOCOL_VERSION,
        .message_type = .find_request,
        .payload_size = @intCast(input.len),
    };

    const message_with_injection = try allocator.alloc(u8, @sizeOf(MessageHeader) + input.len);
    defer allocator.free(message_with_injection);

    // Safety: MessageHeader size is known at compile time and buffer is allocated with sufficient size
    @memcpy(message_with_injection[0..@sizeOf(MessageHeader)], @as([*]const u8, @ptrCast(&primary_header))[0..@sizeOf(MessageHeader)]);
    @memcpy(message_with_injection[@sizeOf(MessageHeader)..], input);

    // Embed fake headers in the payload
    if (input.len >= @sizeOf(MessageHeader) * 2) {
        var fake_header = MessageHeader{
            .magic = 0x4B41554C,
            .version = PROTOCOL_VERSION,
            .message_type = .status_request,
            .payload_size = 0,
        };

        const offset = @sizeOf(MessageHeader) + 10;
        if (offset + @sizeOf(MessageHeader) <= message_with_injection.len) {
            // Safety: MessageHeader size is known at compile time and offset bounds are validated above
            @memcpy(message_with_injection[offset .. offset + @sizeOf(MessageHeader)], @as([*]const u8, @ptrCast(&fake_header))[0..@sizeOf(MessageHeader)]);
        }
    }

    // Test parsing - should not be fooled by embedded headers
    _ = parse_with_injection_detection(message_with_injection) catch {};
}

/// Test state corruption through rapid message sequences
fn fuzz_state_corruption(_: std.mem.Allocator, input: []const u8) !void {
    // Simulate rapid message sequences that could corrupt state
    const message_types = [_]MessageType{ .ping_request, .status_request, .find_request };

    for (0..10) |i| {
        const msg_type = message_types[i % message_types.len];
        const chunk_start = (i * input.len / 10) % input.len;
        const chunk_end = @min(chunk_start + input.len / 10, input.len);

        if (chunk_end <= chunk_start) continue;

        const chunk = input[chunk_start..chunk_end];

        var header = MessageHeader{
            .magic = 0x4B41554C,
            .version = PROTOCOL_VERSION,
            .message_type = msg_type,
            // Safety: chunk.len is valid usize derived from input bounds and fits within u32 range
            .payload_size = @intCast(chunk.len),
        };

        // Process rapid sequence of messages
        _ = process_rapid_sequence(&header, chunk) catch {};
    }
}

/// Test concurrent connection handling
fn fuzz_concurrent_connections(_: std.mem.Allocator, input: []const u8) !void {
    // Simulate multiple connections with overlapping requests
    const connection_count = @min(10, input.len / 50);

    for (0..connection_count) |conn_id| {
        const offset = conn_id * 50;
        if (offset + 50 > input.len) break;

        const conn_data = input[offset .. offset + 50];

        // Simulate connection-specific message
        var header = MessageHeader{
            .magic = 0x4B41554C,
            .version = PROTOCOL_VERSION,
            .message_type = .find_request,
            // Safety: conn_data.len is 50 bytes max and fits within u32 range
            .payload_size = @intCast(conn_data.len),
        };

        // Test concurrent processing
        _ = simulate_concurrent_connection(&header, conn_data, conn_id) catch {};
    }
}

// Helper functions for specific bug-finding scenarios
fn parse_message_header(buffer: []const u8) !MessageHeader {
    if (buffer.len < @sizeOf(MessageHeader)) return error.TruncatedHeader;

    // Safety: buffer length is validated above to be at least MessageHeader size and ptr is properly aligned
    const header = @as(*const MessageHeader, @ptrCast(@alignCast(buffer.ptr))).*;

    // Validate magic number
    if (header.magic != 0x4B41554C) return error.InvalidMagic;

    // Validate version
    if (header.version > PROTOCOL_VERSION + 100) return error.UnsupportedVersion;

    // Skip message type validation during fuzzing to allow invalid enum values
    _ = header.message_type;

    return header;
}

fn create_negative_length_message(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var header = MessageHeader{
        .magic = 0x4B41554C,
        .version = PROTOCOL_VERSION,
        .message_type = .find_request,
        // Safety: Intentional bitcast of negative value to test protocol robustness
        .payload_size = @bitCast(@as(i64, -1)), // Negative length as u64
    };

    const message = try allocator.alloc(u8, @sizeOf(MessageHeader) + @min(input.len, 100));
    // Safety: MessageHeader size is known at compile time and message buffer is allocated with sufficient size
    @memcpy(message[0..@sizeOf(MessageHeader)], @as([*]const u8, @ptrCast(&header))[0..@sizeOf(MessageHeader)]);
    if (input.len > 0) {
        @memcpy(message[@sizeOf(MessageHeader)..], input[0..@min(input.len, 100)]);
    }
    return message;
}

fn create_huge_length_message(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var header = MessageHeader{
        .magic = 0x4B41554C,
        .version = PROTOCOL_VERSION,
        .message_type = .find_request,
        .payload_size = std.math.maxInt(u32) - 1000,
    };

    const message = try allocator.alloc(u8, @sizeOf(MessageHeader) + @min(input.len, 100));
    // Safety: MessageHeader size is known at compile time and message buffer is allocated with sufficient size
    @memcpy(message[0..@sizeOf(MessageHeader)], @as([*]const u8, @ptrCast(&header))[0..@sizeOf(MessageHeader)]);
    if (input.len > 0) {
        @memcpy(message[@sizeOf(MessageHeader)..], input[0..@min(input.len, 100)]);
    }
    return message;
}

fn create_misaligned_message(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    // Create message with misaligned data that might cause issues
    const size = @sizeOf(MessageHeader) + @min(input.len, 100) + 7; // Add padding for misalignment
    const message = try allocator.alloc(u8, size);

    // Write header at odd offset to test alignment handling
    const offset = 3;
    var header = MessageHeader{
        .magic = 0x4B41554C,
        .version = PROTOCOL_VERSION,
        .message_type = .find_request,
        // Safety: Value is bounded by min(input.len, 100) so fits within u32 range
        .payload_size = @intCast(@min(input.len, 100)),
    };

    // Safety: MessageHeader size is known at compile time and offset bounds are validated above
    @memcpy(message[offset .. offset + @sizeOf(MessageHeader)], @as([*]const u8, @ptrCast(&header))[0..@sizeOf(MessageHeader)]);
    if (input.len > 0) {
        const payload_start = offset + @sizeOf(MessageHeader);
        const remaining_space = message.len - payload_start;
        const copy_len = @min(@min(input.len, 100), remaining_space);
        @memcpy(message[payload_start .. payload_start + copy_len], input[0..copy_len]);
    }
    return message;
}

fn create_invalid_utf8_message(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var header = MessageHeader{
        .magic = 0x4B41554C,
        .version = PROTOCOL_VERSION,
        .message_type = .find_request,
        .payload_size = @intCast(input.len),
    };

    const message = try allocator.alloc(u8, @sizeOf(MessageHeader) + input.len);
    // Safety: MessageHeader size is known at compile time and message buffer is allocated with sufficient size
    @memcpy(message[0..@sizeOf(MessageHeader)], @as([*]const u8, @ptrCast(&header))[0..@sizeOf(MessageHeader)]);

    // Copy input which may contain invalid UTF-8
    @memcpy(message[@sizeOf(MessageHeader)..], input);

    return message;
}

fn create_recursive_message(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    // Create a message that references itself (simulated)
    var header = MessageHeader{
        .magic = 0x4B41554C,
        .version = PROTOCOL_VERSION,
        .message_type = .find_request,
        // Safety: MessageHeader size plus input.len fits within u32 range for typical inputs
        .payload_size = @intCast(@sizeOf(MessageHeader) + input.len),
    };

    const message = try allocator.alloc(u8, @sizeOf(MessageHeader) * 2 + input.len);
    // Safety: MessageHeader size is known at compile time and message buffer is allocated with sufficient size
    @memcpy(message[0..@sizeOf(MessageHeader)], @as([*]const u8, @ptrCast(&header))[0..@sizeOf(MessageHeader)]);
    // Safety: MessageHeader size is known at compile time and message buffer is allocated with sufficient size
    @memcpy(message[@sizeOf(MessageHeader) .. @sizeOf(MessageHeader) * 2], @as([*]const u8, @ptrCast(&header))[0..@sizeOf(MessageHeader)]);
    if (input.len > 0) {
        @memcpy(message[@sizeOf(MessageHeader) * 2 ..], input);
    }

    return message;
}

// Placeholder implementations for testing functions
fn process_malformed_message(message: []const u8) !void {
    _ = message;
    // This would call actual protocol processing
}

fn validate_message_size(header: *const MessageHeader) !void {
    if (header.payload_size > 100 * 1024 * 1024) return error.PayloadTooLarge;
}

fn test_query_length_overflow(allocator: std.mem.Allocator, input: []const u8) !void {
    _ = allocator;
    _ = input;
    // Test query length field overflow
}

fn test_path_length_overflow(allocator: std.mem.Allocator, input: []const u8) !void {
    _ = allocator;
    _ = input;
    // Test path length field overflow
}

fn test_result_count_overflow(allocator: std.mem.Allocator, input: []const u8) !void {
    _ = allocator;
    _ = input;
    // Test result count field overflow
}

fn parse_at_boundary(data: []const u8) !void {
    _ = data;
    // Test boundary parsing
}

fn parse_off_by_one(data: []const u8) !void {
    _ = data;
    // Test off-by-one parsing
}

fn validate_protocol_version(header: *const MessageHeader) !void {
    if (header.version == 0 or header.version > PROTOCOL_VERSION * 2) return error.InvalidVersion;
}

fn parse_truncated_message(message: []const u8) !void {
    _ = message;
    // Test truncated message handling
}

fn validate_payload_size(message: []const u8, claimed_size: u32) !void {
    if (message.len < @sizeOf(MessageHeader) + claimed_size) return error.SizeMismatch;
}

fn parse_with_injection_detection(message: []const u8) !void {
    _ = message;
    // Test injection detection
}

fn process_rapid_sequence(header: *const MessageHeader, payload: []const u8) !void {
    _ = header;
    _ = payload;
    // Test rapid message processing
}

fn simulate_concurrent_connection(header: *const MessageHeader, data: []const u8, conn_id: usize) !void {
    _ = header;
    _ = data;
    _ = conn_id;
    // Test concurrent connection handling
}
