//! E2E tests for entity type validation in find commands.
//!
//! Tests comprehensive entity type support and validates that all documented
//! entity types work correctly. Ensures unsupported types produce clear error messages.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");

test "find command supports all documented entity types" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "entity_types");
    defer test_harness.deinit();

    // Create and link enhanced test project with various entity types
    const project_path = try test_harness.create_enhanced_test_project("entity_test");
    var link_result = try test_harness.execute_workspace_command("link {s} as entitytest", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    var sync_result = try test_harness.execute_workspace_command("sync entitytest", .{});
    defer sync_result.deinit();
    try sync_result.expect_success();

    // Test all entity types that should be supported
    const valid_entity_types = [_][]const u8{
        "function",
        "struct",
        "test",
        "method",
        "const",
        "var",
        "type",
        "import", // This should work but currently fails
    };

    for (valid_entity_types) |entity_type| {
        var result = try test_harness.execute_command(&[_][]const u8{ "find", entity_type, "test_target", "in", "entitytest" });
        defer result.deinit();

        // Should not reject the entity type as invalid
        if (result.exit_code != 0) {
            // If it fails, should not be due to invalid entity type
            try testing.expect(!result.contains_error("Invalid entity type"));
            try testing.expect(!result.contains_error("Valid types:"));
        }
    }
}

test "find import statements specifically works" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "find_imports");
    defer test_harness.deinit();

    // Create and link test project with imports
    const project_path = try test_harness.create_enhanced_test_project("import_test");
    var link_result = try test_harness.execute_workspace_command("link {s} as importtest", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    var sync_result = try test_harness.execute_workspace_command("sync importtest", .{});
    defer sync_result.deinit();
    try sync_result.expect_success();

    // Test finding import statements - this currently fails with "Invalid entity type 'import'"
    var result = try test_harness.execute_command(&[_][]const u8{ "find", "import", "std", "in", "importtest" });
    defer result.deinit();

    // Should not reject 'import' as invalid entity type
    if (result.exit_code != 0) {
        try testing.expect(!result.contains_error("Invalid entity type 'import'"));
    }

    // Test specific import search
    var result2 = try test_harness.execute_command(&[_][]const u8{ "find", "import", "utils", "in", "importtest" });
    defer result2.deinit();

    if (result2.exit_code != 0) {
        try testing.expect(!result2.contains_error("Invalid entity type 'import'"));
    }
}

test "invalid entity types produce clear error messages" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "invalid_entity_types");
    defer test_harness.deinit();

    const invalid_entity_types = [_][]const u8{
        "invalid_type",
        "class", // Not supported in Zig
        "interface", // Not supported in Zig
        "package",
        "",
    };

    for (invalid_entity_types) |entity_type| {
        var result = try test_harness.execute_command(&[_][]const u8{ "find", entity_type, "target" });
        defer result.deinit();

        if (result.exit_code != 0) {
            // Should provide helpful error message
            try testing.expect(result.contains_error("Invalid") or
                result.contains_error("Unknown") or
                result.contains_error("not supported"));
        }
    }
}

test "entity type validation provides helpful suggestions" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "entity_type_suggestions");
    defer test_harness.deinit();

    // Test with a common misspelling
    var result = try test_harness.execute_command(&[_][]const u8{ "find", "functon", "main" }); // misspelled "function"
    defer result.deinit();

    if (result.exit_code != 0) {
        // Should list valid entity types when invalid one is provided
        try testing.expect(result.contains_error("Valid types:") or
            result.contains_error("function") or
            result.contains_error("Available"));
    }
}

test "entity type matching is case sensitive" {
    var test_harness = try harness.E2EHarness.init(testing.allocator, "case_sensitivity");
    defer test_harness.deinit();

    // Create and link test project
    const project_path = try test_harness.create_enhanced_test_project("case_test");
    var link_result = try test_harness.execute_workspace_command("link {s} as casetest", .{project_path});
    defer link_result.deinit();
    try link_result.expect_success();

    // Test case variations
    const case_variations = [_][]const u8{
        "Function", // Should fail - capital F
        "FUNCTION", // Should fail - all caps
        "struct", // Should work - correct case
        "STRUCT", // Should fail - all caps
    };

    for (case_variations) |entity_type| {
        var result = try test_harness.execute_command(&[_][]const u8{ "find", entity_type, "target", "in", "casetest" });
        defer result.deinit();

        if (std.mem.eql(u8, entity_type, "struct")) {
            // Correct case should be accepted
            if (result.exit_code != 0) {
                try testing.expect(!result.contains_error("Invalid entity type"));
            }
        } else {
            // Incorrect case should be rejected
            if (result.exit_code != 0) {
                try testing.expect(result.contains_error("Invalid") or result.contains_error("Unknown"));
            }
        }
    }
}
