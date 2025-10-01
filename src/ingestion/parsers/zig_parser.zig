//! AST-based Zig parser for complete syntactic extraction.
//!
//! Uses std.zig.Ast for correctness. Extracts ALL declarations recursively.
//! Memory allocated from caller's arena for O(1) cleanup.

const std = @import("std");
const Ast = std.zig.Ast;

const error_context = @import("../../core/error_context.zig");
const pipeline_types = @import("../pipeline_types.zig");

const Allocator = std.mem.Allocator;
const IngestionError = pipeline_types.IngestionError;
const ParsedUnit = pipeline_types.ParsedUnit;
const ParsedEdge = pipeline_types.ParsedEdge;
const SourceLocation = pipeline_types.SourceLocation;
const EdgeType = @import("../../core/types.zig").EdgeType;

/// Parse Zig source code into semantic units using std.zig.Ast.
/// Uses official Zig compiler AST for 100% syntax correctness.
/// Memory allocated from caller's allocator for explicit ownership.
/// Returns array of ParsedUnits; caller must call deinit() on each unit and free array.
pub fn parse(
    allocator: Allocator,
    source: [:0]const u8,
    file_path: []const u8,
) IngestionError![]ParsedUnit {
    var ast = Ast.parse(allocator, source, .zig) catch |err| {
        error_context.log_ingestion_error(err, error_context.parsing_context(
            "ast_parse",
            file_path,
            "text/zig",
            null,
            "generation",
        ));
        return IngestionError.ParsingFailed;
    };
    defer ast.deinit(allocator);

    if (ast.errors.len > 0) {
        error_context.log_ingestion_error(IngestionError.ParsingFailed, error_context.parsing_context(
            "ast_validate",
            file_path,
            "text/zig",
            null,
            "validation",
        ));
        return IngestionError.ParsingFailed;
    }

    var walker = Walker{
        .allocator = allocator,
        .ast = &ast,
        .source = source,
        .file_path = file_path,
        .units = std.ArrayList(ParsedUnit){},
        .current_container = null,
        .current_function = null,
    };
    errdefer {
        for (walker.units.items) |*unit| unit.*.deinit(allocator);
        walker.units.deinit(allocator);
    }

    try walker.walk_root();

    return walker.units.toOwnedSlice(allocator);
}

/// AST walker state for recursive traversal.
const Walker = struct {
    allocator: Allocator,
    ast: *const Ast,
    source: []const u8,
    file_path: []const u8,
    units: std.ArrayList(ParsedUnit),
    current_container: ?[]const u8,
    current_function: ?usize, // Index into units array

    fn walk_root(self: *Walker) IngestionError!void {
        for (self.ast.rootDecls()) |node_idx| {
            try self.walk(node_idx);
        }
    }

    /// Unified recursive traversal function. This follows a strict pre-order
    /// traversal: it processes the current node first (which may update context),
    /// then recursively visits all children, and finally restores the parent's
    /// context upon returning. This guarantees complete traversal and correct
    /// context propagation.
    fn walk(self: *Walker, node: Ast.Node.Index) IngestionError!void {
        // --- Phase 1: Save Parent Context ---
        const saved_function = self.current_function;
        const saved_container = self.current_container;

        // --- Phase 2: Process the Current Node ---
        // This may create ParsedUnit/ParsedEdge and update context for children
        try self.process_node(node);

        // --- Phase 3: Recursively Walk ALL Children ---
        // Generic traversal that visits every child node
        try self.walk_children(node);

        // --- Phase 4: Restore Parent Context ---
        self.current_function = saved_function;
        self.current_container = saved_container;
    }

    fn process_node(self: *Walker, node: Ast.Node.Index) IngestionError!void {
        const tag = self.ast.nodes.items(.tag)[@intFromEnum(node)];

        switch (tag) {
            // Function declarations
            .fn_decl => try self.process_fn_decl(node),

            // Variable declarations - always process, regardless of scope
            .global_var_decl,
            .simple_var_decl,
            .aligned_var_decl,
            .local_var_decl,
            => try self.process_var_decl(node),

            // Container declarations
            .container_decl,
            .container_decl_trailing,
            .container_decl_two,
            .container_decl_two_trailing,
            .container_decl_arg,
            .container_decl_arg_trailing,
            => try self.process_container_decl(node),

            // Test declarations
            .test_decl => try self.process_test_decl(node),

            // Call expressions for edge extraction
            .call, .call_comma, .call_one, .call_one_comma => try self.extract_calls(node),

            else => {},
        }
    }

    /// Walk ALL children of a node. This is the generic, complete traversal.
    /// Uses AST helpers to safely extract children for every node type.
    fn walk_children(self: *Walker, node: Ast.Node.Index) IngestionError!void {
        const tag = self.ast.nodes.items(.tag)[@intFromEnum(node)];
        const data = self.ast.nodeData(node);

        // Use Ast helpers for safe child extraction
        switch (tag) {
            // Blocks
            .block, .block_semicolon, .block_two, .block_two_semicolon => {
                var buffer: [2]Ast.Node.Index = undefined;
                const statements = self.ast.blockStatements(&buffer, node) orelse return;
                for (statements) |stmt| try self.walk(stmt);
            },

            // Containers
            .container_decl,
            .container_decl_trailing,
            .container_decl_arg,
            .container_decl_arg_trailing,
            => {
                const container_decl = switch (tag) {
                    .container_decl,
                    .container_decl_trailing,
                    => self.ast.containerDecl(node),
                    .container_decl_arg,
                    .container_decl_arg_trailing,
                    => self.ast.containerDeclArg(node),
                    else => unreachable,
                };
                for (container_decl.ast.members) |member| try self.walk(member);
            },
            .container_decl_two,
            .container_decl_two_trailing,
            => {
                var buffer: [2]Ast.Node.Index = undefined;
                const container_decl = self.ast.containerDeclTwo(&buffer, node);
                for (container_decl.ast.members) |member| try self.walk(member);
            },
            .tagged_union,
            .tagged_union_trailing,
            .tagged_union_two,
            .tagged_union_two_trailing,
            .tagged_union_enum_tag,
            .tagged_union_enum_tag_trailing,
            => {
                var buffer: [2]Ast.Node.Index = undefined;
                if (self.ast.fullContainerDecl(&buffer, node)) |container| {
                    for (container.ast.members) |member| try self.walk(member);
                }
            },

            // Functions - walk proto and body
            .fn_decl => {
                if (@intFromEnum(data.node_and_node[0]) != 0) try self.walk(data.node_and_node[0]);
                if (@intFromEnum(data.node_and_node[1]) != 0) try self.walk(data.node_and_node[1]);
            },

            // Variable declarations - walk initializer
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                if (self.ast.fullVarDecl(node)) |var_decl| {
                    if (var_decl.ast.init_node.unwrap()) |init| try self.walk(init);
                }
            },

            // Calls - walk callee and all arguments
            .call, .call_comma, .call_one, .call_one_comma => {
                var buffer: [1]Ast.Node.Index = undefined;
                if (self.ast.fullCall(&buffer, node)) |call| {
                    try self.walk(call.ast.fn_expr);
                    for (call.ast.params) |param| try self.walk(param);
                }
            },

            // Field access - walk LHS
            .field_access => {
                if (@intFromEnum(data.node_and_token[0]) != 0) try self.walk(data.node_and_token[0]);
            },

            // Binary operations - walk both operands
            .add,
            .sub,
            .mul,
            .div,
            .mod,
            .array_mult,
            .equal_equal,
            .bang_equal,
            .less_than,
            .greater_than,
            .less_or_equal,
            .greater_or_equal,
            .bool_and,
            .bool_or,
            .bit_and,
            .bit_or,
            .bit_xor,
            .shl,
            .shr,
            .assign,
            .assign_add,
            .assign_sub,
            .assign_mul,
            .assign_div,
            .assign_mod,
            .assign_bit_and,
            .assign_bit_or,
            .assign_bit_xor,
            .assign_shl,
            .assign_shr,
            .array_access,
            .slice,
            .slice_sentinel,
            .@"catch",
            .@"orelse",
            => {
                if (@intFromEnum(data.node_and_node[0]) != 0) try self.walk(data.node_and_node[0]);
                if (@intFromEnum(data.node_and_node[1]) != 0) try self.walk(data.node_and_node[1]);
            },

            // If/While/For - walk all branches
            .if_simple, .@"if" => {
                if (self.ast.fullIf(node)) |if_node| {
                    try self.walk(if_node.ast.cond_expr);
                    try self.walk(if_node.ast.then_expr);
                    if (if_node.ast.else_expr.unwrap()) |e| try self.walk(e);
                }
            },
            .while_simple, .while_cont, .@"while" => {
                if (self.ast.fullWhile(node)) |while_node| {
                    try self.walk(while_node.ast.cond_expr);
                    try self.walk(while_node.ast.then_expr);
                    if (while_node.ast.else_expr.unwrap()) |e| try self.walk(e);
                }
            },
            .for_simple, .@"for" => {
                if (self.ast.fullFor(node)) |for_node| {
                    for (for_node.ast.inputs) |input| try self.walk(input);
                    try self.walk(for_node.ast.then_expr);
                    if (for_node.ast.else_expr.unwrap()) |e| try self.walk(e);
                }
            },

            // Array/struct initialization - walk all elements
            .array_init,
            .array_init_comma,
            .array_init_one,
            .array_init_one_comma,
            .array_init_dot,
            .array_init_dot_comma,
            .array_init_dot_two,
            .array_init_dot_two_comma,
            => {
                var buffer: [2]Ast.Node.Index = undefined;
                if (self.ast.fullArrayInit(&buffer, node)) |array_init| {
                    if (array_init.ast.type_expr.unwrap()) |type_expr| try self.walk(type_expr);
                    for (array_init.ast.elements) |elem| try self.walk(elem);
                }
            },
            .struct_init,
            .struct_init_comma,
            .struct_init_one,
            .struct_init_one_comma,
            .struct_init_dot,
            .struct_init_dot_comma,
            .struct_init_dot_two,
            .struct_init_dot_two_comma,
            => {
                var buffer: [2]Ast.Node.Index = undefined;
                if (self.ast.fullStructInit(&buffer, node)) |struct_init| {
                    if (struct_init.ast.type_expr.unwrap()) |type_expr| try self.walk(type_expr);
                    for (struct_init.ast.fields) |field| try self.walk(field);
                }
            },

            else => {
                // Expression nodes we don't handle won't affect causality graph.
            },
        }
    }

    fn process_fn_decl(self: *Walker, node: Ast.Node.Index) IngestionError!void {
        // For fn_decl, use fullFnProto which recursively handles the proto child
        var buffer: [1]Ast.Node.Index = undefined;
        const fn_proto = self.ast.fullFnProto(&buffer, node) orelse return;
        const name_token = fn_proto.name_token orelse return;
        const fn_name = self.ast.tokenSlice(name_token);

        const unit = try self.create_function_unit(node, fn_name);
        try self.units.append(self.allocator, unit);

        // Set current function index for edge extraction in children
        // walk() will restore it after processing children
        self.current_function = self.units.items.len - 1;
    }

    fn process_fn_proto(self: *Walker, node: Ast.Node.Index) IngestionError!void {
        var buffer: [1]Ast.Node.Index = undefined;
        const fn_proto = self.ast.fullFnProto(&buffer, node) orelse return;
        const name_token = fn_proto.name_token orelse return;
        const fn_name = self.ast.tokenSlice(name_token);

        const unit = try self.create_function_unit(node, fn_name);
        try self.units.append(self.allocator, unit);
    }

    fn create_function_unit(self: *Walker, node: Ast.Node.Index, name: []const u8) IngestionError!ParsedUnit {
        const content = self.ast.getNodeSource(node);
        const token = self.ast.firstToken(node);
        const loc = self.ast.tokenLocation(0, token);

        var edges = std.ArrayList(ParsedEdge){};

        // Add method_of edge if inside a container
        if (self.current_container) |container_name| {
            const edge = ParsedEdge{
                .edge_type = .method_of,
                .target_id = try self.allocator.dupe(u8, container_name),
                .metadata = std.StringHashMap([]const u8).init(self.allocator),
            };
            try edges.append(self.allocator, edge);
        }

        // Build qualified name: "Container.function" or just "function"
        const qualified_id = if (self.current_container) |container|
            try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ container, name })
        else
            try self.allocator.dupe(u8, name);

        return ParsedUnit{
            .id = qualified_id,
            .unit_type = try self.allocator.dupe(u8, "function"),
            .content = content, // Zero-copy slice into source
            .location = SourceLocation{
                .file_path = try self.allocator.dupe(u8, self.file_path),
                .line_start = @intCast(loc.line + 1),
                .line_end = @intCast(loc.line + 1),
                .col_start = @intCast(loc.column + 1),
                .col_end = @intCast(loc.column + 1),
            },
            .edges = edges,
            .metadata = std.StringHashMap([]const u8).init(self.allocator),
        };
    }

    fn extract_calls(self: *Walker, node: Ast.Node.Index) IngestionError!void {
        const tag = self.ast.nodes.items(.tag)[@intFromEnum(node)];

        const is_call = switch (tag) {
            .call, .call_comma, .call_one, .call_one_comma => true,
            else => false,
        };

        if (!is_call) return;

        // Use fullCall to get structured call information
        var buffer: [1]Ast.Node.Index = undefined;
        const call_full = self.ast.fullCall(&buffer, node) orelse return;

        const callee_node = call_full.ast.fn_expr;
        const callee_tag = self.ast.nodes.items(.tag)[@intFromEnum(callee_node)];

        var target_name: ?[]const u8 = null;
        var is_method = false;

        switch (callee_tag) {
            .identifier => {
                // Simple function call: foo()
                const name_token = self.ast.nodes.items(.main_token)[@intFromEnum(callee_node)];
                target_name = self.ast.tokenSlice(name_token);
            },
            .field_access => {
                // Method call: obj.method()
                // For field_access, data is node_and_token where token is the field name
                const data = self.ast.nodeData(callee_node);
                const field_token = data.node_and_token[1];
                target_name = self.ast.tokenSlice(field_token);
                is_method = true;
            },
            else => {},
        }

        if (target_name) |name| {
            if (self.current_function) |func_idx| {
                // Create metadata with context for better resolution
                var metadata = std.StringHashMap([]const u8).init(self.allocator);

                // Add calling container context if available
                if (self.current_container) |container| {
                    try metadata.put(
                        try self.allocator.dupe(u8, "caller_container"),
                        try self.allocator.dupe(u8, container),
                    );
                }

                const edge = ParsedEdge{
                    .edge_type = if (is_method) .calls_method else .calls,
                    .target_id = try self.allocator.dupe(u8, name),
                    .metadata = metadata,
                };
                try self.units.items[func_idx].edges.append(self.allocator, edge);
            }
        }
    }

    fn process_var_decl(self: *Walker, node: Ast.Node.Index) IngestionError!void {
        const var_decl = self.ast.fullVarDecl(node) orelse return;
        const name_token = var_decl.ast.mut_token + 1;
        const name = self.ast.tokenSlice(name_token);

        // Check initializer - handle @import specially
        const init_node = var_decl.ast.init_node;
        if (@intFromEnum(init_node) != 0) {
            const init_idx = @intFromEnum(@as(Ast.Node.Index, @enumFromInt(@intFromEnum(init_node))));
            const init_tag = self.ast.nodes.items(.tag)[init_idx];

            // Special handling for @import
            if (init_tag == .builtin_call_two or init_tag == .builtin_call_two_comma or
                init_tag == .builtin_call or init_tag == .builtin_call_comma)
            {
                const builtin_token = self.ast.nodes.items(.main_token)[init_idx];
                const builtin_name = self.ast.tokenSlice(builtin_token);
                if (std.mem.eql(u8, builtin_name, "@import")) {
                    try self.process_import(node, name);
                    return;
                }
            }

            // Check if this is a container type definition
            if (self.is_node_a_container(init_node)) {
                // Create a "type" ParsedUnit
                const content = self.ast.getNodeSource(node);
                const token = self.ast.firstToken(node);
                const loc = self.ast.tokenLocation(0, token);

                const unit = ParsedUnit{
                    .id = try self.allocator.dupe(u8, name),
                    .unit_type = try self.allocator.dupe(u8, "type"),
                    .content = content, // Zero-copy slice into source
                    .location = SourceLocation{
                        .file_path = try self.allocator.dupe(u8, self.file_path),
                        .line_start = @intCast(loc.line + 1),
                        .line_end = @intCast(loc.line + 1),
                        .col_start = @intCast(loc.column + 1),
                        .col_end = @intCast(loc.column + 1),
                    },
                    .edges = std.ArrayList(ParsedEdge){},
                    .metadata = std.StringHashMap([]const u8).init(self.allocator),
                };

                try self.units.append(self.allocator, unit);

                // Set context for children that will be visited by walk()
                // Do NOT recurse here, this is handled by walk()
                self.current_container = name;
                return;
            }
        }

        // Regular variable declaration - create unit regardless of scope
        // Filtering by scope should happen at a higher level, not in the parser
        const content = self.ast.getNodeSource(node);
        const token = self.ast.firstToken(node);
        const loc = self.ast.tokenLocation(0, token);

        const mut_token = self.ast.tokenSlice(var_decl.ast.mut_token);
        const is_const = std.mem.eql(u8, mut_token, "const");

        const unit = ParsedUnit{
            .id = try self.allocator.dupe(u8, name),
            .unit_type = try self.allocator.dupe(u8, if (is_const) "const" else "var"),
            .content = content, // Zero-copy slice into source
            .location = SourceLocation{
                .file_path = try self.allocator.dupe(u8, self.file_path),
                .line_start = @intCast(loc.line + 1),
                .line_end = @intCast(loc.line + 1),
                .col_start = @intCast(loc.column + 1),
                .col_end = @intCast(loc.column + 1),
            },
            .edges = std.ArrayList(ParsedEdge){},
            .metadata = std.StringHashMap([]const u8).init(self.allocator),
        };

        try self.units.append(self.allocator, unit);
    }

    /// Check if a node represents a container type definition.
    /// Returns true for struct/enum/union declarations.
    fn is_node_a_container(self: *Walker, node_opt: Ast.Node.OptionalIndex) bool {
        const init_node = node_opt.unwrap() orelse return false;
        const init_idx = @intFromEnum(init_node);
        const init_tag = self.ast.nodes.items(.tag)[init_idx];

        // Case 1: Direct container declaration
        switch (init_tag) {
            .container_decl,
            .container_decl_trailing,
            .container_decl_two,
            .container_decl_two_trailing,
            .container_decl_arg,
            .container_decl_arg_trailing,
            .tagged_union,
            .tagged_union_trailing,
            .tagged_union_two,
            .tagged_union_two_trailing,
            .tagged_union_enum_tag,
            .tagged_union_enum_tag_trailing,
            => return true,
            else => {},
        }

        // Case 2: Call to a type-creating builtin like union(enum)
        // This handles declarations like `const MyUnion = union(enum) { ... }`,
        // where the initializer is a `.call` node to a builtin, not a `.container_decl`.
        if (init_tag == .call or init_tag == .call_one or
            init_tag == .call_comma or init_tag == .call_one_comma)
        {
            var buffer: [1]Ast.Node.Index = undefined;
            if (self.ast.fullCall(&buffer, init_node)) |call| {
                const callee_tag = self.ast.nodes.items(.tag)[@intFromEnum(call.ast.fn_expr)];
                if (callee_tag == .identifier) {
                    const callee_token = self.ast.nodes.items(.main_token)[@intFromEnum(call.ast.fn_expr)];
                    const callee_name = self.ast.tokenSlice(callee_token);
                    if (std.mem.eql(u8, callee_name, "union") or
                        std.mem.eql(u8, callee_name, "struct") or
                        std.mem.eql(u8, callee_name, "enum"))
                    {
                        return true;
                    }
                }
            }
        }

        return false;
    }

    fn process_import(self: *Walker, node: Ast.Node.Index, name: []const u8) IngestionError!void {
        const content = self.ast.getNodeSource(node);
        const token = self.ast.firstToken(node);
        const loc = self.ast.tokenLocation(0, token);

        const unit = ParsedUnit{
            .id = try self.allocator.dupe(u8, name),
            .unit_type = try self.allocator.dupe(u8, "import"),
            .content = content, // Zero-copy slice into source
            .location = SourceLocation{
                .file_path = try self.allocator.dupe(u8, self.file_path),
                .line_start = @intCast(loc.line + 1),
                .line_end = @intCast(loc.line + 1),
                .col_start = @intCast(loc.column + 1),
                .col_end = @intCast(loc.column + 1),
            },
            .edges = std.ArrayList(ParsedEdge){},
            .metadata = std.StringHashMap([]const u8).init(self.allocator),
        };

        try self.units.append(self.allocator, unit);
    }

    fn process_container_decl(self: *Walker, node: Ast.Node.Index) IngestionError!void {
        // Find container name by looking backwards from container token
        var container_name: ?[]const u8 = null;
        const main_token = self.ast.nodes.items(.main_token)[@intFromEnum(node)];

        // Look for "const Name = " pattern before struct/enum/union keyword
        if (main_token >= 2) {
            const prev_token = main_token - 1; // Should be '='
            const prev_prev_token = main_token - 2; // Should be identifier
            const prev_tag = self.ast.tokens.items(.tag)[prev_token];
            const prev_prev_tag = self.ast.tokens.items(.tag)[prev_prev_token];

            if (prev_tag == .equal and prev_prev_tag == .identifier) {
                container_name = self.ast.tokenSlice(prev_prev_token);
            }
        }

        // Create unit for the container itself
        if (container_name) |name| {
            const content = self.ast.getNodeSource(node);
            const token = self.ast.firstToken(node);
            const loc = self.ast.tokenLocation(0, token);

            const unit = ParsedUnit{
                .id = try self.allocator.dupe(u8, name),
                .unit_type = try self.allocator.dupe(u8, "type"),
                .content = content, // Zero-copy slice into source
                .location = SourceLocation{
                    .file_path = try self.allocator.dupe(u8, self.file_path),
                    .line_start = @intCast(loc.line + 1),
                    .line_end = @intCast(loc.line + 1),
                    .col_start = @intCast(loc.column + 1),
                    .col_end = @intCast(loc.column + 1),
                },
                .edges = std.ArrayList(ParsedEdge){},
                .metadata = std.StringHashMap([]const u8).init(self.allocator),
            };

            try self.units.append(self.allocator, unit);
        }

        // Set container context for child nodes
        // walk() will restore it after processing children
        self.current_container = container_name;
    }

    fn process_test_decl(self: *Walker, node: Ast.Node.Index) IngestionError!void {
        const content = self.ast.getNodeSource(node);
        const token = self.ast.firstToken(node);
        const loc = self.ast.tokenLocation(0, token);

        const unique_test_id = try std.fmt.allocPrint(self.allocator, "test_{d}", .{loc.line});

        const unit = ParsedUnit{
            .id = unique_test_id,
            .unit_type = try self.allocator.dupe(u8, "test"),
            .content = content, // Zero-copy slice into source
            .location = SourceLocation{
                .file_path = try self.allocator.dupe(u8, self.file_path),
                .line_start = @intCast(loc.line + 1),
                .line_end = @intCast(loc.line + 1),
                .col_start = @intCast(loc.column + 1),
                .col_end = @intCast(loc.column + 1),
            },
            .edges = std.ArrayList(ParsedEdge){},
            .metadata = std.StringHashMap([]const u8).init(self.allocator),
        };

        try self.units.append(self.allocator, unit);
    }
};

const testing = std.testing;

fn cleanup_units(allocator: Allocator, units: []ParsedUnit) void {
    for (units) |*unit| {
        var mutable_unit = unit.*;
        mutable_unit.deinit(allocator);
    }
    allocator.free(units);
}

test "parse top-level function" {
    const src =
        \\pub fn main() void {
        \\    return;
        \\}
    ;
    const src_z = try testing.allocator.dupeZ(u8, src);
    defer testing.allocator.free(src_z);

    const units = try parse(testing.allocator, src_z, "test.zig");
    defer cleanup_units(testing.allocator, units);

    try testing.expectEqual(@as(usize, 1), units.len);
    try testing.expectEqualStrings("main", units[0].id);
    try testing.expectEqualStrings("function", units[0].unit_type);
}

test "parse method inside struct" {
    const src =
        \\pub const Config = struct {
        \\    timeout: u32,
        \\
        \\    pub fn init() Config {
        \\        return .{ .timeout = 100 };
        \\    }
        \\
        \\    pub fn validate(self: *const Config) bool {
        \\        return self.timeout > 0;
        \\    }
        \\};
    ;
    const src_z = try testing.allocator.dupeZ(u8, src);
    defer testing.allocator.free(src_z);

    const units = try parse(testing.allocator, src_z, "test.zig");
    defer cleanup_units(testing.allocator, units);

    // Should find: Config struct + init method + validate method
    try testing.expect(units.len >= 3);

    var found_config = false;
    var found_init = false;
    var found_validate = false;

    for (units) |unit| {
        if (std.mem.eql(u8, unit.unit_type, "type") and
            std.mem.indexOf(u8, unit.id, "Config") != null)
        {
            found_config = true;
        }
        if (std.mem.eql(u8, unit.unit_type, "function") and
            std.mem.indexOf(u8, unit.id, "init") != null)
        {
            found_init = true;
            // Should have method_of edge to Config
            const has_method_edge = for (unit.edges.items) |edge| {
                if (edge.edge_type == .method_of) break true;
            } else false;
            try testing.expect(has_method_edge);
        }
        if (std.mem.eql(u8, unit.unit_type, "function") and
            std.mem.indexOf(u8, unit.id, "validate") != null)
        {
            found_validate = true;
        }
    }

    try testing.expect(found_config);
    try testing.expect(found_init);
    try testing.expect(found_validate);
}

test "parse nested function" {
    const src =
        \\fn outer() void {
        \\    const Inner = struct {
        \\        fn method() void {}
        \\    };
        \\    Inner.method();
        \\}
    ;
    const src_z = try testing.allocator.dupeZ(u8, src);
    defer testing.allocator.free(src_z);

    const units = try parse(testing.allocator, src_z, "test.zig");
    defer cleanup_units(testing.allocator, units);

    // Should find: outer + Inner + method
    try testing.expect(units.len >= 3);

    var found_outer = false;
    var found_inner = false;
    var found_method = false;

    for (units) |unit| {
        if (std.mem.indexOf(u8, unit.id, "outer") != null) found_outer = true;
        if (std.mem.indexOf(u8, unit.id, "Inner") != null) found_inner = true;
        if (std.mem.indexOf(u8, unit.id, "method") != null) found_method = true;
    }

    try testing.expect(found_outer);
    try testing.expect(found_inner);
    try testing.expect(found_method);
}

test "extract function call edges" {
    const src =
        \\fn caller() void {
        \\    callee();
        \\}
        \\
        \\fn callee() void {}
    ;
    const src_z = try testing.allocator.dupeZ(u8, src);
    defer testing.allocator.free(src_z);

    const units = try parse(testing.allocator, src_z, "test.zig");
    defer cleanup_units(testing.allocator, units);

    // Find the caller function
    const caller_unit = for (units) |unit| {
        if (std.mem.indexOf(u8, unit.id, "caller") != null) break unit;
    } else {
        try testing.expect(false); // Caller not found
        return;
    };

    // Caller should have a "calls" edge to "callee"
    const has_call_edge = for (caller_unit.edges.items) |edge| {
        if (edge.edge_type == .calls and
            std.mem.indexOf(u8, edge.target_id, "callee") != null)
        {
            break true;
        }
    } else false;

    try testing.expect(has_call_edge);
}

test "extract method call edges" {
    const src =
        \\pub const Foo = struct {
        \\    pub fn bar(self: *Foo) void {
        \\        self.baz();
        \\    }
        \\
        \\    fn baz(self: *Foo) void {}
        \\};
    ;
    const src_z = try testing.allocator.dupeZ(u8, src);
    defer testing.allocator.free(src_z);

    const units = try parse(testing.allocator, src_z, "test.zig");
    defer cleanup_units(testing.allocator, units);

    // Find the bar method
    const bar_unit = for (units) |unit| {
        if (std.mem.indexOf(u8, unit.id, "bar") != null) break unit;
    } else {
        try testing.expect(false);
        return;
    };

    // bar should have a "calls_method" edge to "baz"
    const has_method_call = for (bar_unit.edges.items) |edge| {
        if ((edge.edge_type == .calls_method or edge.edge_type == .calls) and
            std.mem.indexOf(u8, edge.target_id, "baz") != null)
        {
            break true;
        }
    } else false;

    try testing.expect(has_method_call);
}

test "extract @import" {
    const src =
        \\const std = @import("std");
        \\const types = @import("../core/types.zig");
    ;
    const src_z = try testing.allocator.dupeZ(u8, src);
    defer testing.allocator.free(src_z);

    const units = try parse(testing.allocator, src_z, "test.zig");
    defer cleanup_units(testing.allocator, units);

    // Should find import declarations
    var found_std_import = false;
    var found_types_import = false;

    for (units) |unit| {
        if (std.mem.eql(u8, unit.unit_type, "import")) {
            if (std.mem.indexOf(u8, unit.content, "std") != null) found_std_import = true;
            if (std.mem.indexOf(u8, unit.content, "types.zig") != null) found_types_import = true;
        }
    }

    try testing.expect(found_std_import);
    try testing.expect(found_types_import);
}

test "parse variable declarations" {
    const src =
        \\pub const VERSION: u32 = 1;
        \\var global_counter: usize = 0;
    ;
    const src_z = try testing.allocator.dupeZ(u8, src);
    defer testing.allocator.free(src_z);

    const units = try parse(testing.allocator, src_z, "test.zig");
    defer cleanup_units(testing.allocator, units);

    var found_version = false;
    var found_counter = false;

    for (units) |unit| {
        if (std.mem.eql(u8, unit.unit_type, "const") and
            std.mem.indexOf(u8, unit.id, "VERSION") != null)
        {
            found_version = true;
        }
        if (std.mem.eql(u8, unit.unit_type, "var") and
            std.mem.indexOf(u8, unit.id, "global_counter") != null)
        {
            found_counter = true;
        }
    }

    try testing.expect(found_version);
    try testing.expect(found_counter);
}

test "parse enum and union" {
    const src =
        \\pub const Color = enum {
        \\    red,
        \\    green,
        \\    blue,
        \\};
        \\
        \\pub const Value = union(enum) {
        \\    int: i32,
        \\    float: f64,
        \\};
    ;
    const src_z = try testing.allocator.dupeZ(u8, src);
    defer testing.allocator.free(src_z);

    const units = try parse(testing.allocator, src_z, "test.zig");
    defer cleanup_units(testing.allocator, units);

    var found_color = false;
    var found_value = false;

    for (units) |unit| {
        if (std.mem.eql(u8, unit.unit_type, "type")) {
            if (std.mem.indexOf(u8, unit.id, "Color") != null) found_color = true;
            if (std.mem.indexOf(u8, unit.id, "Value") != null) found_value = true;
        }
    }

    try testing.expect(found_color);
    try testing.expect(found_value);
}

test "parse local const struct declaration" {
    const src =
        \\fn my_func() void {
        \\    const LocalStruct = struct {
        \\        value: i32,
        \\    };
        \\    _ = LocalStruct{ .value = 1 };
        \\}
    ;
    const src_z = try testing.allocator.dupeZ(u8, src);
    defer testing.allocator.free(src_z);

    const units = try parse(testing.allocator, src_z, "test.zig");
    defer cleanup_units(testing.allocator, units);

    // Should find both the function `my_func` and the type `LocalStruct`
    var found_func = false;
    var found_struct = false;
    for (units) |unit| {
        if (std.mem.eql(u8, unit.id, "my_func")) found_func = true;
        if (std.mem.eql(u8, unit.id, "LocalStruct")) found_struct = true;
    }
    try testing.expect(found_func);
    try testing.expect(found_struct);
}

test "handle syntax errors gracefully" {
    const src = "pub fn broken( void {";
    const src_z = try testing.allocator.dupeZ(u8, src);
    defer testing.allocator.free(src_z);

    try testing.expectError(IngestionError.ParsingFailed, parse(testing.allocator, src_z, "test.zig"));
}

test "handle braces in strings" {
    const src =
        \\fn test_strings() void {
        \\    const s = "{ not a block }";
        \\    const t = "another } brace";
        \\}
    ;
    const src_z = try testing.allocator.dupeZ(u8, src);
    defer testing.allocator.free(src_z);

    const units = try parse(testing.allocator, src_z, "test.zig");
    defer cleanup_units(testing.allocator, units);

    // Should find: 1 function + 2 local const declarations
    try testing.expectEqual(@as(usize, 3), units.len);

    // Find the function unit and verify it contains the strings
    var found_function = false;
    for (units) |unit| {
        if (std.mem.eql(u8, unit.unit_type, "function")) {
            found_function = true;
            try testing.expect(std.mem.indexOf(u8, unit.content, "not a block") != null);
        }
    }
    try testing.expect(found_function);
}

test "parse empty file" {
    const src_z = try testing.allocator.dupeZ(u8, "");
    defer testing.allocator.free(src_z);

    const units = try parse(testing.allocator, src_z, "test.zig");
    defer testing.allocator.free(units);

    try testing.expectEqual(@as(usize, 0), units.len);
}
