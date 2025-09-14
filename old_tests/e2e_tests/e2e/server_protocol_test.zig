//! E2E tests for KausalDB server protocol validation.
//!
//! Tests the complete server functionality including TCP networking,
//! binary protocol handling, and connection management. This is the
//! only test that validates the server mode works end-to-end.

const std = @import("std");
const testing = std.testing;
const net = std.net;

test "server ping/pong protocol E2E test" {
    // SKIP: Server mode not yet implemented in CLI
    // TODO: Enable this test when server command is added to main.zig
    return error.SkipZigTest;
}

test "server handles multiple concurrent connections" {
    // SKIP: Server mode not yet implemented in CLI
    // TODO: Enable this test when server command is added to main.zig
    return error.SkipZigTest;
}

test "server gracefully handles malformed messages" {
    // SKIP: Server mode not yet implemented in CLI
    // TODO: Enable this test when server command is added to main.zig
    return error.SkipZigTest;
}

/// Extract port number from server startup output
fn extract_port_from_output(output: []const u8) ?u16 {
    // Look for pattern like "Server listening on port 1234"
    var lines = std.mem.splitSequence(u8, output, "\n");
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "port")) |port_index| {
            // Find the number after "port"
            var i = port_index + 4;
            while (i < line.len and !std.ascii.isDigit(line[i])) i += 1;

            if (i < line.len) {
                var j = i;
                while (j < line.len and std.ascii.isDigit(line[j])) j += 1;

                if (j > i) {
                    const port_str = line[i..j];
                    return std.fmt.parseInt(u16, port_str, 10) catch null;
                }
            }
        }
    }
    return null;
}

/// Create binary header for ping message
fn create_ping_message_header() [8]u8 {
    var header: [8]u8 = undefined;

    // Assuming message format: [msg_type: u32 LE][payload_length: u32 LE]
    // msg_type = 1 for ping (this is protocol-specific)
    std.mem.writeInt(u32, header[0..4], 1, .little);
    // payload_length = 0 for ping
    std.mem.writeInt(u32, header[4..8], 0, .little);

    return header;
}

/// Decode message header from binary data
fn decode_message_header(data: [8]u8) struct { msg_type: u32, payload_length: u32 } {
    const msg_type = std.mem.readInt(u32, data[0..4], .little);
    const payload_length = std.mem.readInt(u32, data[4..8], .little);

    return .{
        .msg_type = msg_type,
        .payload_length = payload_length,
    };
}
