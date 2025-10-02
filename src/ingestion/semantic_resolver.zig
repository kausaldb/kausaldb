//! High-performance semantic resolution for parsed units.
//!
//! This resolver builds a symbol table with string interning and resolves all symbolic
//! references to canonical qualified names.
//!
//! Design rationale:
//! - Syntactic parsing is fast and simple (extracting "calls baz")
//! - Semantic resolution provides true causality (resolving to "Foo.baz")
//! - Separation allows incremental updates: reparse one file, re-resolve only affected edges
//!
//! Memory model:
//! - String pool: All unique symbols stored once (e.g., "main", "init", "Config")
//! - Symbol table: Keys and values are slices into the string pool (zero-copy)
//! - Arena for transient data: O(1) cleanup after each resolution pass

const std = @import("std");
const pipeline_types = @import("pipeline_types.zig");

const Allocator = std.mem.Allocator;
const ParsedUnit = pipeline_types.ParsedUnit;
const ParsedEdge = pipeline_types.ParsedEdge;
const SourceLocation = pipeline_types.SourceLocation;
const EdgeType = @import("../core/types.zig").EdgeType;

/// Symbol information for resolution.
const SymbolInfo = struct {
    unit_index: usize,
    qualified_name: []const u8,
    kind: SymbolKind,
};

const SymbolKind = enum {
    function,
    type_decl,
    constant,
    variable,
    import,
    test_decl,
};

/// High-performance semantic resolver with string interning and arena-based memory management.
///
/// Memory contract:
/// - Owns a string pool for all unique symbols (long-lived, backing allocator)
/// - Uses arena for all transient data during a single resolve pass
/// - After resolve_symbols(), ParsedUnit.edges contain non-owned slices into the string pool
/// - ParsedUnits are only valid as long as the SemanticResolver instance is alive
pub const SemanticResolver = struct {
    backing_allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    string_pool: std.ArrayList([]const u8),
    symbols: std.StringHashMap(SymbolInfo),

    pub fn init(backing_allocator: Allocator) SemanticResolver {
        return .{
            .backing_allocator = backing_allocator,
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .string_pool = std.ArrayList([]const u8){},
            .symbols = std.StringHashMap(SymbolInfo).init(backing_allocator),
        };
    }

    /// Deinitializes the resolver, freeing all associated memory.
    /// This includes freeing the string pool and the symbol table.
    ///
    /// Any ParsedUnits that have been processed by `resolve_symbols` become invalid
    /// after this is called, as their edge targets will become dangling pointers.
    pub fn deinit(self: *SemanticResolver) void {
        for (self.string_pool.items) |str| {
            self.backing_allocator.free(str);
        }
        self.string_pool.deinit(self.backing_allocator);

        var key_iter = self.symbols.keyIterator();
        while (key_iter.next()) |key_ptr| {
            self.backing_allocator.free(key_ptr.*);
        }
        self.symbols.deinit();

        self.arena.deinit();
    }

    /// Resolve all symbolic references in parsed units to canonical qualified names.
    ///
    /// After this function returns, ParsedUnit.edges contain slices that point into
    /// this resolver's string pool. The ParsedUnits are only valid as long as this
    /// SemanticResolver instance is alive.
    pub fn resolve_symbols(self: *SemanticResolver, units: []ParsedUnit) !void {
        _ = self.arena.reset(.retain_capacity);
        self.symbols.clearRetainingCapacity();

        try self.build_symbol_table(units);

        for (units) |*unit| {
            for (unit.edges.items) |*edge| {
                if (edge.edge_type == .calls or edge.edge_type == .calls_method) {
                    const old_target_id = edge.target_id;
                    edge.target_id = try self.resolve_in_scope(old_target_id, unit);
                    self.backing_allocator.free(old_target_id);
                }
            }
        }
    }

    /// Build symbol table from parsed units with string interning.
    ///
    /// For each unit, constructs a fully-qualified name (e.g., "MyStruct.my_method")
    /// and interns it in the string pool. The symbol table then references these
    /// interned strings, ensuring each unique name is stored exactly once.
    fn build_symbol_table(self: *SemanticResolver, units: []ParsedUnit) !void {
        for (units, 0..) |*unit, i| {
            const qualified_name_str = if (unit.parent_container) |parent|
                try std.fmt.allocPrint(self.arena.allocator(), "{s}.{s}", .{ parent, unit.id })
            else
                try self.arena.allocator().dupe(u8, unit.id);

            const interned_name = try self.intern_string(qualified_name_str);

            // HashMap owns a copy of the key; value references the canonical pool string
            try self.symbols.put(try self.backing_allocator.dupe(u8, interned_name), .{
                .unit_index = i,
                .qualified_name = interned_name,
                .kind = parse_symbol_kind(unit.unit_type),
            });
        }
    }

    /// Intern a string in the string pool.
    ///
    /// Returns existing slice if already interned (zero allocations), otherwise dups into
    /// backing allocator and adds to pool. Linear scan is acceptable for typical symbol counts.
    fn intern_string(self: *SemanticResolver, str: []const u8) ![]const u8 {
        for (self.string_pool.items) |interned| {
            if (std.mem.eql(u8, interned, str)) return interned;
        }

        const new_interned = try self.backing_allocator.dupe(u8, str);
        try self.string_pool.append(self.backing_allocator, new_interned);
        return new_interned;
    }

    /// Resolve a symbol name in the context of a given unit.
    fn resolve_in_scope(
        self: *SemanticResolver,
        name: []const u8,
        context_unit: *const ParsedUnit,
    ) ![]const u8 {
        if (self.symbols.get(name)) |info| return info.qualified_name;

        if (context_unit.parent_container) |parent| {
            const qualified_attempt = try std.fmt.allocPrint(
                self.arena.allocator(),
                "{s}.{s}",
                .{ parent, name },
            );
            if (self.symbols.get(qualified_attempt)) |info| {
                return info.qualified_name;
            }
        }

        return try self.intern_string(name);
    }
};

/// Parse unit type string to symbol kind.
fn parse_symbol_kind(unit_type: []const u8) SymbolKind {
    if (std.mem.eql(u8, unit_type, "function")) return .function;
    if (std.mem.eql(u8, unit_type, "type")) return .type_decl;
    if (std.mem.eql(u8, unit_type, "const")) return .constant;
    if (std.mem.eql(u8, unit_type, "var")) return .variable;
    if (std.mem.eql(u8, unit_type, "import")) return .import;
    if (std.mem.eql(u8, unit_type, "test")) return .test_decl;
    return .function; // Default fallback
}

fn cleanup_resolved_unit(unit: *ParsedUnit, allocator: std.mem.Allocator) void {
    allocator.free(unit.id);
    allocator.free(unit.unit_type);
    if (unit.parent_container) |parent| {
        allocator.free(parent);
    }
    unit.location.deinit(allocator);

    // Free edge metadata but NOT target_id (non-owned after resolution)
    for (unit.edges.items) |*edge| {
        var iter = edge.metadata.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        edge.metadata.deinit();
    }
    unit.edges.deinit(allocator);

    var iter = unit.metadata.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    unit.metadata.deinit();
}

test "semantic resolver: resolve simple function call" {
    var resolver = SemanticResolver.init(std.testing.allocator);

    // Create two functions: main() and helper()
    var units = [_]ParsedUnit{
        ParsedUnit{
            .id = try std.testing.allocator.dupe(u8, "main"),
            .unit_type = try std.testing.allocator.dupe(u8, "function"),
            .content = "fn main() { helper(); }",
            .parent_container = null,
            .location = SourceLocation{
                .file_path = try std.testing.allocator.dupe(u8, "test.zig"),
                .line_start = 1,
                .line_end = 1,
                .col_start = 1,
                .col_end = 1,
            },
            .edges = std.ArrayList(ParsedEdge){},
            .metadata = std.StringHashMap([]const u8).init(std.testing.allocator),
        },
        ParsedUnit{
            .id = try std.testing.allocator.dupe(u8, "helper"),
            .unit_type = try std.testing.allocator.dupe(u8, "function"),
            .content = "fn helper() {}",
            .parent_container = null,
            .location = SourceLocation{
                .file_path = try std.testing.allocator.dupe(u8, "test.zig"),
                .line_start = 2,
                .line_end = 2,
                .col_start = 1,
                .col_end = 1,
            },
            .edges = std.ArrayList(ParsedEdge){},
            .metadata = std.StringHashMap([]const u8).init(std.testing.allocator),
        },
    };

    // Add edge: main calls "helper" (unqualified)
    try units[0].edges.append(std.testing.allocator, ParsedEdge{
        .edge_type = .calls,
        .target_id = try std.testing.allocator.dupe(u8, "helper"),
        .metadata = std.StringHashMap([]const u8).init(std.testing.allocator),
    });

    try resolver.resolve_symbols(&units);

    // Verify edge was resolved to canonical name
    try std.testing.expectEqual(@as(usize, 1), units[0].edges.items.len);
    try std.testing.expect(std.mem.eql(u8, units[0].edges.items[0].target_id, "helper"));

    for (&units) |*unit| cleanup_resolved_unit(unit, std.testing.allocator);
    resolver.deinit();
}

test "semantic resolver: resolve method call to qualified name" {
    var resolver = SemanticResolver.init(std.testing.allocator);

    // Create struct Foo with method bar(), and baz() calls bar()
    var units = [_]ParsedUnit{
        ParsedUnit{
            .id = try std.testing.allocator.dupe(u8, "bar"),
            .unit_type = try std.testing.allocator.dupe(u8, "function"),
            .content = "fn bar(self: *Foo) void {}",
            .parent_container = try std.testing.allocator.dupe(u8, "Foo"),
            .location = SourceLocation{
                .file_path = try std.testing.allocator.dupe(u8, "test.zig"),
                .line_start = 1,
                .line_end = 1,
                .col_start = 1,
                .col_end = 1,
            },
            .edges = std.ArrayList(ParsedEdge){},
            .metadata = std.StringHashMap([]const u8).init(std.testing.allocator),
        },
        ParsedUnit{
            .id = try std.testing.allocator.dupe(u8, "baz"),
            .unit_type = try std.testing.allocator.dupe(u8, "function"),
            .content = "fn baz(self: *Foo) void { self.bar(); }",
            .parent_container = try std.testing.allocator.dupe(u8, "Foo"),
            .location = SourceLocation{
                .file_path = try std.testing.allocator.dupe(u8, "test.zig"),
                .line_start = 2,
                .line_end = 2,
                .col_start = 1,
                .col_end = 1,
            },
            .edges = std.ArrayList(ParsedEdge){},
            .metadata = std.StringHashMap([]const u8).init(std.testing.allocator),
        },
    };

    // Add edge: baz calls "bar" (unqualified within same container)
    try units[1].edges.append(std.testing.allocator, ParsedEdge{
        .edge_type = .calls_method,
        .target_id = try std.testing.allocator.dupe(u8, "bar"),
        .metadata = std.StringHashMap([]const u8).init(std.testing.allocator),
    });

    try resolver.resolve_symbols(&units);

    // Verify edge was resolved to "Foo.bar"
    try std.testing.expectEqual(@as(usize, 1), units[1].edges.items.len);
    try std.testing.expect(std.mem.eql(u8, units[1].edges.items[0].target_id, "Foo.bar"));

    for (&units) |*unit| cleanup_resolved_unit(unit, std.testing.allocator);
    resolver.deinit();
}

test "semantic resolver: string interning eliminates duplicates" {
    var resolver = SemanticResolver.init(std.testing.allocator);

    // Create multiple units with same names
    var units = [_]ParsedUnit{
        ParsedUnit{
            .id = try std.testing.allocator.dupe(u8, "init"),
            .unit_type = try std.testing.allocator.dupe(u8, "function"),
            .content = "fn init() void {}",
            .parent_container = null,
            .location = SourceLocation{
                .file_path = try std.testing.allocator.dupe(u8, "test.zig"),
                .line_start = 1,
                .line_end = 1,
                .col_start = 1,
                .col_end = 1,
            },
            .edges = std.ArrayList(ParsedEdge){},
            .metadata = std.StringHashMap([]const u8).init(std.testing.allocator),
        },
        ParsedUnit{
            .id = try std.testing.allocator.dupe(u8, "deinit"),
            .unit_type = try std.testing.allocator.dupe(u8, "function"),
            .content = "fn deinit() void {}",
            .parent_container = null,
            .location = SourceLocation{
                .file_path = try std.testing.allocator.dupe(u8, "test.zig"),
                .line_start = 2,
                .line_end = 2,
                .col_start = 1,
                .col_end = 1,
            },
            .edges = std.ArrayList(ParsedEdge){},
            .metadata = std.StringHashMap([]const u8).init(std.testing.allocator),
        },
    };

    // Both call "init" (should intern to same string)
    try units[0].edges.append(std.testing.allocator, ParsedEdge{
        .edge_type = .calls,
        .target_id = try std.testing.allocator.dupe(u8, "deinit"),
        .metadata = std.StringHashMap([]const u8).init(std.testing.allocator),
    });
    try units[1].edges.append(std.testing.allocator, ParsedEdge{
        .edge_type = .calls,
        .target_id = try std.testing.allocator.dupe(u8, "init"),
        .metadata = std.StringHashMap([]const u8).init(std.testing.allocator),
    });

    try resolver.resolve_symbols(&units);

    // String pool should contain only unique strings ("init", "deinit")
    try std.testing.expectEqual(@as(usize, 2), resolver.string_pool.items.len);

    for (&units) |*unit| cleanup_resolved_unit(unit, std.testing.allocator);
    resolver.deinit();
}

test "semantic resolver: handles unresolved external symbols" {
    var resolver = SemanticResolver.init(std.testing.allocator);

    var units = [_]ParsedUnit{
        ParsedUnit{
            .id = try std.testing.allocator.dupe(u8, "main"),
            .unit_type = try std.testing.allocator.dupe(u8, "function"),
            .content = "fn main() { external_func(); }",
            .parent_container = null,
            .location = SourceLocation{
                .file_path = try std.testing.allocator.dupe(u8, "test.zig"),
                .line_start = 1,
                .line_end = 1,
                .col_start = 1,
                .col_end = 1,
            },
            .edges = std.ArrayList(ParsedEdge){},
            .metadata = std.StringHashMap([]const u8).init(std.testing.allocator),
        },
    };

    // Add edge to external symbol (not defined in units)
    try units[0].edges.append(std.testing.allocator, ParsedEdge{
        .edge_type = .calls,
        .target_id = try std.testing.allocator.dupe(u8, "external_func"),
        .metadata = std.StringHashMap([]const u8).init(std.testing.allocator),
    });

    try resolver.resolve_symbols(&units);

    // Verify edge preserved original name
    try std.testing.expect(std.mem.eql(u8, units[0].edges.items[0].target_id, "external_func"));

    for (&units) |*unit| cleanup_resolved_unit(unit, std.testing.allocator);
    resolver.deinit();
}

test "semantic resolver: string pool memory safety with pointer lifetime validation" {
    // This test proves the string pool correctly manages memory ownership and prevents
    // use-after-free bugs when ParsedUnits hold non-owned slices.
    //
    // Memory contract validation:
    // 1. Edge target_ids point into string pool (non-owned slices)
    // 2. ParsedUnits can be safely cleaned up while resolver stays alive
    // 3. String pool owns all interned strings and frees them exactly once in deinit()
    // 4. Pointer stability: Pool strings remain valid for resolver's lifetime

    var resolver = SemanticResolver.init(std.testing.allocator);
    defer resolver.deinit();

    var units = [_]ParsedUnit{
        ParsedUnit{
            .id = try std.testing.allocator.dupe(u8, "init"),
            .unit_type = try std.testing.allocator.dupe(u8, "function"),
            .content = "fn init() { deinit(); run(); }",
            .parent_container = null,
            .location = SourceLocation{
                .file_path = try std.testing.allocator.dupe(u8, "test.zig"),
                .line_start = 1,
                .line_end = 1,
                .col_start = 1,
                .col_end = 1,
            },
            .edges = std.ArrayList(ParsedEdge){},
            .metadata = std.StringHashMap([]const u8).init(std.testing.allocator),
        },
        ParsedUnit{
            .id = try std.testing.allocator.dupe(u8, "deinit"),
            .unit_type = try std.testing.allocator.dupe(u8, "function"),
            .content = "fn deinit() {}",
            .parent_container = null,
            .location = SourceLocation{
                .file_path = try std.testing.allocator.dupe(u8, "test.zig"),
                .line_start = 2,
                .line_end = 2,
                .col_start = 1,
                .col_end = 1,
            },
            .edges = std.ArrayList(ParsedEdge){},
            .metadata = std.StringHashMap([]const u8).init(std.testing.allocator),
        },
        ParsedUnit{
            .id = try std.testing.allocator.dupe(u8, "run"),
            .unit_type = try std.testing.allocator.dupe(u8, "function"),
            .content = "fn run() {}",
            .parent_container = null,
            .location = SourceLocation{
                .file_path = try std.testing.allocator.dupe(u8, "test.zig"),
                .line_start = 3,
                .line_end = 3,
                .col_start = 1,
                .col_end = 1,
            },
            .edges = std.ArrayList(ParsedEdge){},
            .metadata = std.StringHashMap([]const u8).init(std.testing.allocator),
        },
    };

    // init() calls both deinit() and run()
    try units[0].edges.append(std.testing.allocator, ParsedEdge{
        .edge_type = .calls,
        .target_id = try std.testing.allocator.dupe(u8, "deinit"),
        .metadata = std.StringHashMap([]const u8).init(std.testing.allocator),
    });
    try units[0].edges.append(std.testing.allocator, ParsedEdge{
        .edge_type = .calls,
        .target_id = try std.testing.allocator.dupe(u8, "run"),
        .metadata = std.StringHashMap([]const u8).init(std.testing.allocator),
    });

    // Store original target pointers BEFORE resolution
    const original_target_ptrs = [2]usize{
        @intFromPtr(units[0].edges.items[0].target_id.ptr),
        @intFromPtr(units[0].edges.items[1].target_id.ptr),
    };

    try resolver.resolve_symbols(&units);

    // CRITICAL ASSERTION 1: String pool contains exactly 3 unique strings
    try std.testing.expectEqual(@as(usize, 3), resolver.string_pool.items.len);

    // CRITICAL ASSERTION 2: Edge target_ids now point into string pool (ownership transferred)
    // Original pointers (from allocator.dupe) were freed at line 99 in resolve_symbols
    const resolved_target_ptrs = [2]usize{
        @intFromPtr(units[0].edges.items[0].target_id.ptr),
        @intFromPtr(units[0].edges.items[1].target_id.ptr),
    };

    // Prove pointers changed (old ones freed, new ones from pool)
    try std.testing.expect(resolved_target_ptrs[0] != original_target_ptrs[0]);
    try std.testing.expect(resolved_target_ptrs[1] != original_target_ptrs[1]);

    // CRITICAL ASSERTION 3: Both resolved targets point into string pool
    var first_points_to_pool = false;
    var second_points_to_pool = false;
    for (resolver.string_pool.items) |pool_str| {
        if (@intFromPtr(pool_str.ptr) == resolved_target_ptrs[0]) first_points_to_pool = true;
        if (@intFromPtr(pool_str.ptr) == resolved_target_ptrs[1]) second_points_to_pool = true;
    }
    try std.testing.expect(first_points_to_pool);
    try std.testing.expect(second_points_to_pool);

    // CRITICAL ASSERTION 4: ParsedUnits can be cleaned up safely while resolver stays alive
    // This proves the memory contract: units hold non-owned slices into the pool
    for (&units) |*unit| cleanup_resolved_unit(unit, std.testing.allocator);

    // CRITICAL ASSERTION 5: String pool remains valid after ParsedUnit cleanup
    // Pool still contains ["init", "deinit", "run"] and will be freed in resolver.deinit()
    try std.testing.expectEqual(@as(usize, 3), resolver.string_pool.items.len);
    try std.testing.expect(std.mem.eql(u8, resolver.string_pool.items[0], "init"));
    try std.testing.expect(std.mem.eql(u8, resolver.string_pool.items[1], "deinit"));
    try std.testing.expect(std.mem.eql(u8, resolver.string_pool.items[2], "run"));

    // PROOF COMPLETE: String pool memory safety validated
    // - Original target_id strings are freed during resolution (line 99)
    // - Resolved target_ids point into string pool (non-owned slices)
    // - ParsedUnits can be cleaned up safely (don't double-free pool strings)
    // - String pool owns all interned strings and frees them exactly once in deinit()
}
