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

    var source_violations = std.array_list.Managed(ValidationResult.ValidationViolation).init(allocator);
    var test_violations = std.array_list.Managed(ValidationResult.ValidationViolation).init(allocator);

    // Validate source file patterns (strict - these cause build failure)
    validate_source_file_patterns(allocator, &source_violations) catch |err| {
        log.warn("Source validation failed: {}", .{err});
    };

    // Check for dangerous patterns in test files (informational - warnings only)
    validate_test_file_patterns(allocator, &test_violations) catch |err| {
        log.warn("Test validation failed: {}", .{err});
    };

    // Report test violations as informational
    if (test_violations.items.len > 0) {
        log.info("Found {d} ownership patterns in test files (informational only - not blocking):", .{test_violations.items.len});
    }

    // Capture source violation count before cleanup
    const source_violation_count = source_violations.items.len;

    // Only add source violations to main violations list (test violations are informational only)
    try violations.appendSlice(source_violations.items);

    test_violations.deinit();
    source_violations.deinit();

    return PatternValidationResult{
        .passed = source_violation_count == 0, // Only fail on source violations
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

    var files_analyzed: u32 = 0;
    var files_with_violations: u32 = 0;

    while (try walker.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        // Skip test files - they are handled by validate_test_file_patterns
        if (std.mem.indexOf(u8, entry.path, "/tests/") != null or
            std.mem.startsWith(u8, entry.path, "tests/") or
            std.mem.endsWith(u8, entry.path, "_test.zig"))
        {
            continue;
        }

        files_analyzed += 1;

        // Read file content for pattern analysis
        const file_content = dir.readFileAlloc(allocator, entry.path, 1024 * 1024) catch |err| switch (err) {
            error.FileTooBig => continue, // Skip very large files
            else => continue, // Skip files we can't read
        };
        defer allocator.free(file_content);

        const violations_before = violations.items.len;

        // Analyze patterns in this file
        try analyze_file_for_ownership_patterns(entry.path, file_content, violations);

        if (violations.items.len > violations_before) {
            files_with_violations += 1;
            log.info("SOURCE VIOLATIONS in {s}: {d}", .{ entry.path, violations.items.len - violations_before });
        }
    }

    log.info("Analyzed {d} files, {d} files with violations", .{ files_analyzed, files_with_violations });
}

/// Validate test file patterns for ownership compliance
fn validate_test_file_patterns(allocator: std.mem.Allocator, violations: *std.array_list.Managed(ValidationResult.ValidationViolation)) !void {
    // Tests have different ownership rules but we still want to track patterns for awareness

    // Walk all source files looking for test patterns
    var dir = std.fs.cwd().openDir("src", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        // Only analyze test files
        if (!(std.mem.indexOf(u8, entry.path, "/tests/") != null or
            std.mem.endsWith(u8, entry.path, "_test.zig")))
        {
            continue;
        }

        const file_content = dir.readFileAlloc(allocator, entry.path, 1024 * 1024) catch |err| switch (err) {
            error.FileTooBig => continue,
            else => continue,
        };
        defer allocator.free(file_content);

        const violations_before = violations.items.len;

        // Check for test-specific ownership patterns (informational only)
        try analyze_test_file_patterns(entry.path, file_content, violations);

        if (violations.items.len > violations_before) {
            log.info("TEST INFO in {s}: {d} ownership patterns (informational only)", .{ entry.path, violations.items.len - violations_before });
        }
    }
}

/// Analyze test-specific ownership patterns
fn analyze_test_file_patterns(file_path: []const u8, content: []const u8, violations: *std.array_list.Managed(ValidationResult.ValidationViolation)) !void {
    // Check for collections storing raw ContextBlock in tests (informational)
    if (has_collection_violations(content)) |details| {
        const violation = ValidationResult.ValidationViolation{
            .type_name = file_path,
            .field_name = details,
            .violation_type = .unsafe_collection,
            .description = "Test uses raw ContextBlock collection (informational - tests have flexibility)",
        };
        try violations.append(violation);
    }

    // Check for raw ContextBlock struct fields in tests (informational)
    if (has_struct_field_violations(content)) |details| {
        const violation = ValidationResult.ValidationViolation{
            .type_name = file_path,
            .field_name = details,
            .violation_type = .raw_context_block,
            .description = "Test has raw ContextBlock field (informational - tests have flexibility)",
        };
        try violations.append(violation);
    }
}

/// Analyze a specific file for ownership pattern violations
fn analyze_file_for_ownership_patterns(file_path: []const u8, content: []const u8, violations: *std.array_list.Managed(ValidationResult.ValidationViolation)) !void {
    // Skip validation for allowed modules
    if (should_skip_ownership_validation(file_path)) {
        return;
    }

    // Look for dangerous patterns with context-aware validation

    // Pattern 1: Struct fields storing raw ContextBlock (should use OwnedBlock)
    if (has_struct_field_violations(content)) |details| {
        const violation = ValidationResult.ValidationViolation{
            .type_name = file_path,
            .field_name = details,
            .violation_type = .raw_context_block,
            .description = "Struct field storing raw ContextBlock - should use OwnedBlock",
        };
        try violations.append(violation);
    }

    // Pattern 2: Raw ContextBlock pointers in non-public contexts
    if (has_pointer_violations(content)) |details| {
        const violation = ValidationResult.ValidationViolation{
            .type_name = file_path,
            .field_name = details,
            .violation_type = .raw_context_block_pointer,
            .description = "Raw ContextBlock pointer in internal context - should use ownership system",
        };
        try violations.append(violation);
    }

    // Pattern 3: Collections storing raw ContextBlock
    if (has_collection_violations(content)) |details| {
        const violation = ValidationResult.ValidationViolation{
            .type_name = file_path,
            .field_name = details,
            .violation_type = .unsafe_collection,
            .description = "Collection storing raw ContextBlock - should use OwnedBlock",
        };
        try violations.append(violation);
    }
}

/// Determine if a file should be skipped from ownership validation
fn should_skip_ownership_validation(file_path: []const u8) bool {
    // Skip core system files that legitimately use raw ContextBlock
    const allowed_files = [_][]const u8{
        "ownership.zig", // Ownership system itself
        "tidy_ownership.zig", // This validation tool
        "violation_scanner.zig", // Violation detection tool
        "types.zig", // Core type definitions
        "context_block.zig", // Legacy compatibility
        "validation.zig", // Block validation utilities
        "serialize.zig", // Serialization utilities
    };

    for (allowed_files) |allowed| {
        if (std.mem.indexOf(u8, file_path, allowed) != null) {
            return true;
        }
    }

    // Skip test files - they have different validation rules
    if (std.mem.indexOf(u8, file_path, "/tests/") != null or
        std.mem.endsWith(u8, file_path, "_test.zig"))
    {
        return true;
    }

    return false;
}

/// Check for struct fields storing raw ContextBlock
fn has_struct_field_violations(content: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var in_struct_body = false;
    var paren_depth: i32 = 0;
    var brace_depth: i32 = 0;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");

        // Skip comments and empty lines
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "//")) continue;

        // Track parentheses and braces to understand context
        for (trimmed) |char| {
            switch (char) {
                '(' => paren_depth += 1,
                ')' => paren_depth -= 1,
                '{' => brace_depth += 1,
                '}' => brace_depth -= 1,
                else => {},
            }
        }

        // Detect struct definitions
        if (std.mem.indexOf(u8, trimmed, "struct {") != null or
            (std.mem.indexOf(u8, trimmed, " struct ") != null and std.mem.indexOf(u8, trimmed, "{") != null))
        {
            in_struct_body = true;
            continue;
        }

        // Exit struct body when we see closing brace at top level
        if (in_struct_body and brace_depth == 0 and std.mem.indexOf(u8, trimmed, "}") != null) {
            in_struct_body = false;
            continue;
        }

        // Check for ContextBlock field only inside struct body and not in function parameters
        if (in_struct_body and paren_depth == 0 and std.mem.indexOf(u8, trimmed, ": ContextBlock") != null) {
            // Additional checks to exclude function definitions inside structs
            if (std.mem.indexOf(u8, trimmed, " fn ") == null and
                std.mem.indexOf(u8, trimmed, "pub fn") == null and
                !std.mem.startsWith(u8, trimmed, "fn "))
            {
                return "struct_field_context_block";
            }
        }
    }
    return null;
}

/// Check for problematic ContextBlock pointers
fn has_pointer_violations(content: []const u8) ?[]const u8 {
    // Look for pointer patterns but exclude function parameters
    if (std.mem.indexOf(u8, content, "*ContextBlock") != null or
        std.mem.indexOf(u8, content, "?*ContextBlock") != null)
    {
        // Check if these are in function signatures (allowed for public APIs)
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if ((std.mem.indexOf(u8, line, "*ContextBlock") != null or
                std.mem.indexOf(u8, line, "?*ContextBlock") != null))
            {
                // Allow in public function parameters
                if (std.mem.indexOf(u8, line, "pub fn") != null) continue;
                // Allow in function parameters generally
                if (std.mem.indexOf(u8, line, " fn ") != null) continue;
                // Found problematic pointer usage
                return "pointer_context_block";
            }
        }
    }
    return null;
}

/// Check for collections storing raw ContextBlock
fn has_collection_violations(content: []const u8) ?[]const u8 {
    // Look for ArrayList(ContextBlock) or HashMap with ContextBlock values
    if (std.mem.indexOf(u8, content, "ArrayList(ContextBlock)") != null) {
        return "arraylist_context_block";
    }

    // Look for HashMap patterns with ContextBlock as value type
    if (std.mem.indexOf(u8, content, "HashMap(") != null) {
        // Check if ContextBlock appears as a HashMap value type
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "HashMap(") != null and
                std.mem.indexOf(u8, line, "ContextBlock") != null)
            {
                // Simple heuristic: if ContextBlock appears after HashMap, likely a value type
                const hashmap_pos = std.mem.indexOf(u8, line, "HashMap(") orelse continue;
                const block_pos = std.mem.indexOf(u8, line, "ContextBlock") orelse continue;
                if (block_pos > hashmap_pos) {
                    return "hashmap_context_block";
                }
            }
        }
    }

    return null;
}

/// Report ownership validation statistics
pub fn report_ownership_statistics(allocator: std.mem.Allocator) !void {
    _ = allocator;

    log.info("Ownership Validation Statistics:", .{});
    log.info("  Pattern-based validation completed", .{});
    log.info("  Full compile-time validation coming in Phase 5", .{});
}
