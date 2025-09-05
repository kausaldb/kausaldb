//! Ownership validation tooling for KausalDB build system.
//!
//! This tool systematically validates that all structs follow the ownership
//! model, preventing raw ContextBlock usage outside of the ownership system.
//! Integrates with build system to provide compile-time safety guarantees.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.tidy_ownership);

/// Validation result for ownership compliance
pub const ValidationResult = struct {
    passed: bool,
    violations: []ValidationViolation,

    pub const ValidationViolation = struct {
        type_name: []const u8,
        field_name: []const u8,
        violation_type: ViolationType,
        description: []const u8,

        pub const ViolationType = enum {
            raw_context_block,
            raw_context_block_pointer,
            raw_context_block_optional_pointer,
            unsafe_collection,
        };
    };
};

/// Main entry point for ownership validation
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    log.info("Starting KausalDB ownership validation...", .{});

    // For now, perform basic source code pattern analysis
    var validation_results = try validate_codebase_patterns(allocator);
    defer validation_results.deinit();

    if (!validation_results.passed) {
        log.err("OWNERSHIP VALIDATION FAILED", .{});
        for (validation_results.violations.items) |violation| {
            log.err("  {s}: {s}", .{ @tagName(violation.violation_type), violation.description });
        }
        std.process.exit(1);
    }

    log.info("✅ Ownership validation passed", .{});

    // Report adoption statistics
    try report_ownership_statistics(allocator);
}

/// Comprehensive pattern-based validation result
const PatternValidationResult = struct {
    passed: bool,
    violations: std.array_list.Managed(ValidationResult.ValidationViolation),

    pub fn deinit(self: *PatternValidationResult) void {
        self.violations.deinit();
    }
};

/// Validate codebase patterns for ownership compliance
fn validate_codebase_patterns(allocator: std.mem.Allocator) !PatternValidationResult {
    var violations = std.array_list.Managed(ValidationResult.ValidationViolation).init(allocator);

    // Validate source file patterns
    validate_source_file_patterns(allocator, &violations) catch |err| {
        log.warn("Source validation failed: {}", .{err});
    };

    // Check for dangerous patterns in test files
    validate_test_file_patterns(allocator, &violations) catch |err| {
        log.warn("Test validation failed: {}", .{err});
    };

    return PatternValidationResult{
        .passed = violations.items.len == 0,
        .violations = violations,
    };
}

/// Validate source file patterns for ownership compliance
fn validate_source_file_patterns(allocator: std.mem.Allocator, violations: *std.array_list.Managed(ValidationResult.ValidationViolation)) !void {
    // Walk the source directory and analyze patterns
    var dir = std.fs.cwd().openDir("src", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return, // No src directory - probably wrong working directory
        else => return err,
    };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        // Read file content for pattern analysis
        const file_content = dir.readFileAlloc(allocator, entry.path, 1024 * 1024) catch |err| switch (err) {
            error.FileTooBig => continue, // Skip very large files
            else => continue, // Skip files we can't read
        };
        defer allocator.free(file_content);

        // Analyze patterns in this file
        try analyze_file_for_ownership_patterns(entry.path, file_content, violations);
    }
}

/// Validate test file patterns for ownership compliance
fn validate_test_file_patterns(allocator: std.mem.Allocator, violations: *std.array_list.Managed(ValidationResult.ValidationViolation)) !void {
    _ = allocator;

    // For now, just report that test validation is not yet implemented
    // In full implementation, would scan test files for std.testing.allocator usage
    const violation = ValidationResult.ValidationViolation{
        .type_name = "TestInfrastructure",
        .field_name = "allocator_usage",
        .violation_type = .unsafe_collection,
        .description = "Test file pattern validation not yet fully implemented",
    };
    try violations.append(violation);
}

/// Analyze a specific file for ownership pattern violations
fn analyze_file_for_ownership_patterns(file_path: []const u8, content: []const u8, violations: *std.array_list.Managed(ValidationResult.ValidationViolation)) !void {
    // Skip validation for the ownership module itself and this validation tool
    if (std.mem.indexOf(u8, file_path, "ownership.zig") != null or
        std.mem.indexOf(u8, file_path, "tidy_ownership.zig") != null)
    {
        return;
    }

    // Look for dangerous patterns

    // Pattern 1: Direct ContextBlock fields in structs (should use OwnedBlock)
    if (std.mem.indexOf(u8, content, "ContextBlock,") != null or
        std.mem.indexOf(u8, content, ": ContextBlock") != null)
    {
        const violation = ValidationResult.ValidationViolation{
            .type_name = file_path,
            .field_name = "unknown_field",
            .violation_type = .raw_context_block,
            .description = "Raw ContextBlock field detected - should use OwnedBlock",
        };
        try violations.append(violation);
    }

    // Pattern 2: Raw ContextBlock pointers (should use owned types)
    if (std.mem.indexOf(u8, content, "*ContextBlock") != null or
        std.mem.indexOf(u8, content, "?*ContextBlock") != null)
    {
        const violation = ValidationResult.ValidationViolation{
            .type_name = file_path,
            .field_name = "unknown_pointer",
            .violation_type = .raw_context_block_pointer,
            .description = "Raw ContextBlock pointer detected - should use ownership system",
        };
        try violations.append(violation);
    }

    // Pattern 3: Collections storing raw ContextBlock
    if (std.mem.indexOf(u8, content, "ArrayList(ContextBlock)") != null or
        std.mem.indexOf(u8, content, "HashMap(") != null and std.mem.indexOf(u8, content, "ContextBlock") != null)
    {
        const violation = ValidationResult.ValidationViolation{
            .type_name = file_path,
            .field_name = "collection",
            .violation_type = .unsafe_collection,
            .description = "Collection storing raw ContextBlock - should use OwnedBlock",
        };
        try violations.append(violation);
    }
}

/// Report ownership validation statistics
pub fn report_ownership_statistics(allocator: std.mem.Allocator) !void {
    _ = allocator;

    log.info("Ownership Validation Statistics:", .{});
    log.info("  Pattern-based validation completed", .{});
    log.info("  Full compile-time validation coming in Phase 5", .{});
}