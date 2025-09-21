//! Unit tests for KausalDB CLI v2 components.
//!
//! Pure unit tests with no I/O operations, focusing on parser logic,
//! protocol serialization, and command structure validation.

const std = @import("std");
const testing = std.testing;

const parser = @import("parser.zig");
const protocol = @import("protocol.zig");
const types = @import("../core/types.zig");

const BlockId = types.BlockId;

// === Parser Tests ===

test "parse_command returns help for no arguments" {
    const args = [_][]const u8{"kausal"};
    const cmd = try parser.parse_command(&args);
    try testing.expect(cmd == .help);
    try testing.expect(cmd.help.topic == null);
}

test "parse_command recognizes help command with topic" {
    const args = [_][]const u8{ "kausal", "help", "find" };
    const cmd = try parser.parse_command(&args);
    try testing.expect(cmd == .help);
    try testing.expectEqualStrings("find", cmd.help.topic.?);
}

test "parse_command recognizes version command" {
    const args = [_][]const u8{ "kausal", "version" };
    const cmd = try parser.parse_command(&args);
    try testing.expect(cmd == .version);
}

test "parse_command rejects extra arguments for version" {
    const args = [_][]const u8{ "kausal", "version", "extra" };
    const result = parser.parse_command(&args);
    try testing.expectError(parser.ParseError.TooManyArguments, result);
}

test "parse_command recognizes server command with defaults" {
    const args = [_][]const u8{ "kausal", "server" };
    const cmd = try parser.parse_command(&args);
    try testing.expect(cmd == .server);
    try testing.expect(cmd.server.mode == .start);
    try testing.expectEqualStrings("127.0.0.1", cmd.server.host);
    try testing.expectEqual(@as(u16, 3838), cmd.server.port);
}

test "parse_command recognizes server command with mode" {
    const args = [_][]const u8{ "kausal", "server", "stop" };
    const cmd = try parser.parse_command(&args);
    try testing.expect(cmd == .server);
    try testing.expect(cmd.server.mode == .stop);
}

test "parse_command recognizes server command with options" {
    const args = [_][]const u8{ "kausal", "server", "start", "--host", "0.0.0.0", "--port", "8080" };
    const cmd = try parser.parse_command(&args);
    try testing.expect(cmd == .server);
    try testing.expect(cmd.server.mode == .start);
    try testing.expectEqualStrings("0.0.0.0", cmd.server.host);
    try testing.expectEqual(@as(u16, 8080), cmd.server.port);
}

test "parse_command recognizes status command" {
    const args = [_][]const u8{ "kausal", "status" };
    const cmd = try parser.parse_command(&args);
    try testing.expect(cmd == .status);
    try testing.expect(cmd.status.format == .text);
    try testing.expect(cmd.status.verbose == false);
}

test "parse_command recognizes status command with verbose flag" {
    const args = [_][]const u8{ "kausal", "status", "--verbose" };
    const cmd = try parser.parse_command(&args);
    try testing.expect(cmd == .status);
    try testing.expect(cmd.status.verbose == true);
}

test "parse_command recognizes find command" {
    const args = [_][]const u8{ "kausal", "find", "parse_command" };
    const cmd = try parser.parse_command(&args);
    try testing.expect(cmd == .find);
    try testing.expectEqualStrings("parse_command", cmd.find.query);
    try testing.expectEqual(@as(u16, 10), cmd.find.max_results);
}

test "parse_command recognizes find command with options" {
    const args = [_][]const u8{ "kausal", "find", "test", "--max-results", "5", "--format", "json" };
    const cmd = try parser.parse_command(&args);
    try testing.expect(cmd == .find);
    try testing.expectEqualStrings("test", cmd.find.query);
    try testing.expectEqual(@as(u16, 5), cmd.find.max_results);
    try testing.expect(cmd.find.format == .json);
}

test "parse_command rejects find without query" {
    const args = [_][]const u8{ "kausal", "find" };
    const result = parser.parse_command(&args);
    try testing.expectError(parser.ParseError.MissingArgument, result);
}

test "parse_command recognizes show callers command" {
    const args = [_][]const u8{ "kausal", "show", "callers", "main" };
    const cmd = try parser.parse_command(&args);
    try testing.expect(cmd == .show);
    try testing.expect(cmd.show.direction == .callers);
    try testing.expectEqualStrings("main", cmd.show.target);
    try testing.expectEqual(@as(u16, 3), cmd.show.max_depth);
}

test "parse_command recognizes show callees with depth" {
    const args = [_][]const u8{ "kausal", "show", "callees", "init", "--max-depth", "5" };
    const cmd = try parser.parse_command(&args);
    try testing.expect(cmd == .show);
    try testing.expect(cmd.show.direction == .callees);
    try testing.expectEqualStrings("init", cmd.show.target);
    try testing.expectEqual(@as(u16, 5), cmd.show.max_depth);
}

test "parse_command recognizes trace command" {
    const args = [_][]const u8{ "kausal", "trace", "main", "exit" };
    const cmd = try parser.parse_command(&args);
    try testing.expect(cmd == .trace);
    try testing.expectEqualStrings("main", cmd.trace.source);
    try testing.expectEqualStrings("exit", cmd.trace.target);
    try testing.expectEqual(@as(u16, 10), cmd.trace.max_depth);
    try testing.expect(cmd.trace.all_paths == false);
}

test "parse_command recognizes trace with all paths" {
    const args = [_][]const u8{ "kausal", "trace", "start", "end", "--all-paths" };
    const cmd = try parser.parse_command(&args);
    try testing.expect(cmd == .trace);
    try testing.expect(cmd.trace.all_paths == true);
}

test "parse_command recognizes link command" {
    const args = [_][]const u8{ "kausal", "link", "/path/to/repo", "myproject" };
    const cmd = try parser.parse_command(&args);
    try testing.expect(cmd == .link);
    try testing.expectEqualStrings("/path/to/repo", cmd.link.path);
    try testing.expectEqualStrings("myproject", cmd.link.name);
}

test "parse_command recognizes unlink command" {
    const args = [_][]const u8{ "kausal", "unlink", "myproject" };
    const cmd = try parser.parse_command(&args);
    try testing.expect(cmd == .unlink);
    try testing.expectEqualStrings("myproject", cmd.unlink.name);
}

test "parse_command recognizes sync command with defaults" {
    const args = [_][]const u8{ "kausal", "sync" };
    const cmd = try parser.parse_command(&args);
    try testing.expect(cmd == .sync);
    try testing.expect(cmd.sync.name == null);
    try testing.expect(cmd.sync.force == false);
}

test "parse_command recognizes sync command with workspace" {
    const args = [_][]const u8{ "kausal", "sync", "myworkspace", "--force" };
    const cmd = try parser.parse_command(&args);
    try testing.expect(cmd == .sync);
    try testing.expectEqualStrings("myworkspace", cmd.sync.name.?);
    try testing.expect(cmd.sync.force == true);
}

test "parse_command rejects unknown command" {
    const args = [_][]const u8{ "kausal", "unknown" };
    const result = parser.parse_command(&args);
    try testing.expectError(parser.ParseError.UnknownCommand, result);
}

test "parse_command rejects invalid output format" {
    const args = [_][]const u8{ "kausal", "find", "test", "--format", "xml" };
    const result = parser.parse_command(&args);
    try testing.expectError(parser.ParseError.InvalidFormat, result);
}

test "parse_command rejects invalid number" {
    const args = [_][]const u8{ "kausal", "find", "test", "--max-results", "abc" };
    const result = parser.parse_command(&args);
    try testing.expectError(parser.ParseError.InvalidNumber, result);
}

// === Protocol Tests ===

test "MessageHeader has correct size and alignment" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(protocol.MessageHeader));
    try testing.expectEqual(@as(usize, 8), @alignOf(protocol.MessageHeader));
}

test "MessageHeader validates magic and version" {
    var header = protocol.MessageHeader{
        .magic = 0x12345678,
        .version = 999,
        .message_type = .ping_request,
        .payload_size = 0,
    };

    const result = header.validate();
    try testing.expectError(error.InvalidMagic, result);

    header.magic = 0x4B41554C;
    const result2 = header.validate();
    try testing.expectError(error.VersionMismatch, result2);

    header.version = protocol.PROTOCOL_VERSION;
    try header.validate();
}

test "FindRequest initializes correctly" {
    const query = "test_function";
    const req = protocol.FindRequest.init(query, 20);

    try testing.expectEqualStrings(query, req.query_text());
    try testing.expectEqual(@as(u16, 20), req.max_results);
    try testing.expect(req.include_metadata == true);
}

test "FindRequest handles max length query" {
    const query = "a" ** protocol.MAX_QUERY_LENGTH;
    const req = protocol.FindRequest.init(query, 10);

    try testing.expectEqual(@as(u16, protocol.MAX_QUERY_LENGTH), req.query_len);
    try testing.expectEqualStrings(query, req.query_text());
}

test "ShowRequest initializes correctly" {
    const target = "StorageEngine.init";
    const req = protocol.ShowRequest.init(target, 5);

    try testing.expectEqualStrings(target, req.target_text());
    try testing.expectEqual(@as(u16, 5), req.max_depth);
    try testing.expectEqual(@as(u32, 1000), req.max_results);
}

test "TraceRequest initializes correctly" {
    const source = "main";
    const target = "exit";
    const req = protocol.TraceRequest.init(source, target, 7);

    try testing.expectEqualStrings(source, req.source_text());
    try testing.expectEqualStrings(target, req.target_text());
    try testing.expectEqual(@as(u16, 7), req.max_depth);
    try testing.expect(req.include_all_paths == false);
}

test "LinkRequest initializes correctly" {
    const path = "/home/user/project";
    const name = "myproject";
    const req = protocol.LinkRequest.init(path, name);

    try testing.expectEqualStrings(path, req.path_text());
    try testing.expectEqualStrings(name, req.name_text());
}

test "OperationResponse initializes correctly" {
    const message = "Operation completed successfully";
    const resp = protocol.OperationResponse.init(true, message);

    try testing.expect(resp.success == true);
    try testing.expectEqualStrings(message, resp.message_text());
}

test "ErrorResponse initializes correctly" {
    const message = "Invalid query syntax";
    const resp = protocol.ErrorResponse.init(42, message);

    try testing.expectEqual(@as(u32, 42), resp.error_code);
    try testing.expectEqualStrings(message, resp.message_text());
}

test "BlockInfo converts from ContextBlock" {
    const block = types.ContextBlock{
        .id = BlockId.from_u64(1),
        .sequence = 1,
        .source_uri = "src/main.zig",
        .metadata_json = "{}",
        .content = "pub fn main() !void { }",
    };

    const info = protocol.BlockInfo.from_block(block);

    try testing.expectEqual(block.id, info.id);
    try testing.expectEqualStrings(block.source_uri, info.uri[0..info.uri_len]);
    try testing.expectEqualStrings(block.content, info.content_preview[0..info.content_preview_len]);
    try testing.expectEqual(@as(u16, 2), info.metadata_size);
}

test "FindResponse manages block collection" {
    var resp = protocol.FindResponse.init();
    try testing.expectEqual(@as(u32, 0), resp.block_count);

    const block1 = types.ContextBlock{
        .id = BlockId.from_u64(1),
        .sequence = 1,
        .source_uri = "file1.zig",
        .metadata_json = "{}",
        .content = "content1",
    };

    const block2 = types.ContextBlock{
        .id = BlockId.from_u64(2),
        .sequence = 2,
        .source_uri = "file2.zig",
        .metadata_json = "{}",
        .content = "content2",
    };

    resp.add_block(block1);
    resp.add_block(block2);

    try testing.expectEqual(@as(u32, 2), resp.block_count);

    const blocks = resp.blocks_slice();
    try testing.expectEqual(@as(usize, 2), blocks.len);
    try testing.expectEqual(block1.id, blocks[0].id);
    try testing.expectEqual(block2.id, blocks[1].id);
}

test "ShowResponse manages blocks and edges" {
    var resp = protocol.ShowResponse.init();
    try testing.expectEqual(@as(u32, 0), resp.block_count);
    try testing.expectEqual(@as(u32, 0), resp.edge_count);

    const block = types.ContextBlock{
        .id = BlockId.from_u64(1),
        .sequence = 1,
        .source_uri = "file.zig",
        .metadata_json = "{}",
        .content = "content",
    };

    const edge = types.GraphEdge{
        .source_id = BlockId.from_u64(100),
        .target_id = BlockId.from_u64(200),
        .edge_type = .calls,
    };

    resp.add_block(block);
    resp.add_edge(edge);

    try testing.expectEqual(@as(u32, 1), resp.block_count);
    try testing.expectEqual(@as(u32, 1), resp.edge_count);
    try testing.expectEqual(edge.source_id, resp.edges[0].source_id);
}

test "TracePath initializes empty" {
    const path = protocol.TracePath.init();
    try testing.expectEqual(@as(u16, 0), path.node_count);
    try testing.expectEqual(@as(u16, 0), path.total_distance);
}

test "TraceResponse initializes empty" {
    const resp = protocol.TraceResponse
        .init();
    try testing.expectEqual(@as(u16, 0), resp.path_count);
}
