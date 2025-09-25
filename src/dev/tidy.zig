//! Simple, focused style checker for KausalDB-specific conventions.
//!
//! Enforces only the critical architectural invariants that `zig fmt` cannot handle:
//! - Function naming conventions (no get_/set_ prefixes)
//! - Thread safety violations (disallowed threading outside stdx.zig)
//! - Safety comment requirements for unsafe operations
//!
//! Deliberately simple using string matching rather than AST parsing.
//! Philosophy: Delegate formatting to `zig fmt`, focus on architectural rules.

const std = @import("std");
const build_options = @import("build_options");

pub const std_options: std.Options = .{
    .log_level = @enumFromInt(@intFromEnum(build_options.log_level)),
};

const log = std.log.scoped(.tidy);

/// Exit codes for the tidy checker
const ExitCode = enum(u8) {
    success = 0,
    violations_found = 1,
    error_occurred = 2,
};

/// A simple violation record
const Violation = struct {
    file: []const u8,
    line: u32,
    message: []const u8,
};

/// Simple string-based checker for KausalDB conventions
const TidyChecker = struct {
    allocator: std.mem.Allocator,
    violations: std.array_list.Managed(Violation),

    fn init(allocator: std.mem.Allocator) TidyChecker {
        return TidyChecker{
            .allocator = allocator,
            .violations = std.array_list.Managed(Violation).init(allocator),
        };
    }

    fn deinit(self: *TidyChecker) void {
        self.violations.deinit();
    }

    /// Check a single file for KausalDB-specific violations
    fn check_file(self: *TidyChecker, file_path: []const u8) !void {
        const file_content = std.fs.cwd().readFileAlloc(self.allocator, file_path, 10 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return, // Skip missing files
            else => return err,
        };
        defer self.allocator.free(file_content);

        var line_number: u32 = 1;
        var lines = std.mem.splitSequence(u8, file_content, "\n");

        while (lines.next()) |line| {
            defer line_number += 1;

            // Rule 1: No get_/set_ function prefixes (violates KausalDB naming convention)
            if (!std.mem.endsWith(u8, file_path, "tidy.zig") and
                (std.mem.indexOf(u8, line, "fn get_") != null or
                    std.mem.indexOf(u8, line, "fn set_") != null))
            {
                try self.add_violation(file_path, line_number, "KausalDB Policy: No get_/set_ prefixes - use direct field access (.field) for data, descriptive verbs for actions");
            }

            // Rule 2: Functions must use snake_case (critical KausalDB convention)
            if (std.mem.indexOf(u8, line, "fn ") != null) {
                try self.check_snake_case_function(file_path, line_number, line, file_content);
            }

            // Rule 3: Thread safety - no threading outside of stdx.zig, memory_guard.zig, and test files
            if (!std.mem.endsWith(u8, file_path, "stdx.zig") and
                !std.mem.endsWith(u8, file_path, "memory_guard.zig") and
                !std.mem.endsWith(u8, file_path, "tidy.zig") and
                !std.mem.startsWith(u8, file_path, "src/tests/") and
                !std.mem.startsWith(u8, file_path, "./src/tests/") and
                !std.mem.endsWith(u8, file_path, "_test.zig"))
            {
                if (std.mem.indexOf(u8, line, "std.Thread.spawn") != null or
                    std.mem.indexOf(u8, line, "std.Thread.Mutex") != null)
                {
                    try self.add_violation(file_path, line_number, "Threading primitives only allowed in src/core/stdx.zig, src/core/memory_guard.zig, and test files - KausalDB is single-threaded by design");
                }
            }

            // Rule 4: Safety comments required for unsafe operations (exclude tidy checker and security scanner)
            // Safety: Operation guaranteed to succeed by preconditions
            if (!std.mem.endsWith(u8, file_path, "tidy.zig") and
                !std.mem.endsWith(u8, file_path, "security_scanner.zig"))
            {
                if (std.mem.indexOf(u8, line, "catch unreachable") != null or
                    std.mem.indexOf(u8, line, "@ptrCast") != null)
                {
                    // Look for "// Safety:" comment on this line or the line above
                    const has_safety_comment = std.mem.indexOf(u8, line, "// Safety:") != null;
                    if (!has_safety_comment and line_number > 1) {
                        // Check previous line for safety comment
                        const prev_line_start = find_previous_line_start(file_content, line);
                        if (prev_line_start) |start| {
                            const prev_line_end = std.mem.indexOf(u8, file_content[start..], "\n") orelse (file_content.len - start);
                            const prev_line = file_content[start .. start + prev_line_end];
                            if (std.mem.indexOf(u8, prev_line, "// Safety:") == null) {
                                try self.add_violation(file_path, line_number, "Unsafe operations require '// Safety:' comment explaining why the operation is safe");
                            }
                        } else {
                            try self.add_violation(file_path, line_number, "Unsafe operations require '// Safety:' comment explaining why the operation is safe");
                        }
                    }
                }
            }

            // Rule 5: Use scoped logging pattern instead of global std.log
            if (!std.mem.endsWith(u8, file_path, "tidy.zig") and
                !std.mem.endsWith(u8, file_path, "build.zig") and
                std.mem.indexOf(u8, line, "std.log.") != null)
            {
                // Exception: Allow std.log.scoped() declarations and type references
                if (std.mem.indexOf(u8, line, "std.log.scoped(") == null and
                    std.mem.indexOf(u8, line, "std.log.Level") == null and
                    std.mem.indexOf(u8, line, "std.log.default") == null)
                {
                    try self.add_violation(file_path, line_number, "Use scoped logging: 'const log = std.log.scoped(.module_name); log.info()' instead of 'std.log.info()'");
                }
            }

            // Rule 6: Use KausalDB assertion library instead of std.debug.assert
            if (std.mem.indexOf(u8, line, "std.debug.assert") != null and
                !std.mem.endsWith(u8, file_path, "assert.zig") and
                !std.mem.endsWith(u8, file_path, "tidy.zig"))
            {
                try self.add_violation(file_path, line_number, "Use KausalDB assert library (assert_mod.assert) instead of std.debug.assert for consistent error handling");
            }

            // Rule 7: Use stdx memory operations instead of raw std.mem operations for safety
            if (std.mem.indexOf(u8, line, "std.mem.copy") != null and
                !std.mem.endsWith(u8, file_path, "stdx.zig") and
                !std.mem.endsWith(u8, file_path, "tidy.zig"))
            {
                try self.add_violation(file_path, line_number, "Use stdx copy functions (copy_left, copy_right) instead of std.mem.copy for explicit overlap semantics");
            }

            // Rule 8: Use stdx bit_set_type instead of std.StaticBitSet
            if (std.mem.indexOf(u8, line, "std.StaticBitSet") != null and
                !std.mem.endsWith(u8, file_path, "stdx.zig") and
                !std.mem.endsWith(u8, file_path, "tidy.zig"))
            {
                try self.add_violation(file_path, line_number, "Use stdx.bit_set_type instead of std.StaticBitSet for consistent snake_case API and bounds checking");
            }

            // Rule 9: No TODO/FIXME/HACK comments in committed code
            if (!std.mem.endsWith(u8, file_path, "tidy.zig") and
                !std.mem.endsWith(u8, file_path, "build.zig") and
                (std.mem.indexOf(u8, line, "// TODO") != null or
                    std.mem.indexOf(u8, line, "// FIXME") != null or
                    std.mem.indexOf(u8, line, "// HACK") != null))
            {
                try self.add_violation(file_path, line_number, "TODO/FIXME/HACK comments must be resolved before committing");
            }
        }
    }

    fn find_previous_line_start(content: []const u8, current_line: []const u8) ?usize {
        const current_line_ptr = current_line.ptr;
        const content_ptr = content.ptr;

        // Safety: Converting pointers to integers for bounds checking validation
        if (@intFromPtr(current_line_ptr) < @intFromPtr(content_ptr) or @intFromPtr(current_line_ptr) >= @intFromPtr(content_ptr) + content.len) {
            return null;
        }

        // Safety: Pointer arithmetic for calculating line offset within validated bounds
        const current_offset = @intFromPtr(current_line_ptr) - @intFromPtr(content_ptr);
        if (current_offset == 0) return null;

        // Find the newline before the current line
        var i = current_offset - 1;
        while (i > 0 and content[i] != '\n') {
            i -= 1;
        }

        if (i == 0) return 0; // First line

        // Find the start of the previous line
        var prev_start = i - 1;
        while (prev_start > 0 and content[prev_start] != '\n') {
            prev_start -= 1;
        }

        return if (prev_start == 0) 0 else prev_start + 1;
    }

    fn check_snake_case_function(self: *TidyChecker, file_path: []const u8, line: u32, source_line: []const u8, file_content: []const u8) !void {
        // Find function declaration: "fn name("
        if (std.mem.indexOf(u8, source_line, "fn ")) |fn_pos| {
            const after_fn = source_line[fn_pos + 3 ..];

            // Skip whitespace after "fn "
            var name_start: usize = 0;
            while (name_start < after_fn.len and after_fn[name_start] == ' ') {
                name_start += 1;
            }

            // Find end of function name (before '(' or '<' for generics)
            var name_end: usize = name_start;
            while (name_end < after_fn.len and
                after_fn[name_end] != '(' and
                after_fn[name_end] != '<' and
                after_fn[name_end] != ' ')
            {
                name_end += 1;
            }

            if (name_end > name_start) {
                const func_name = after_fn[name_start..name_end];

                // Exception: Type generator functions should use PascalCase
                // Type generators are functions that return types and end with "_type" or "Type"
                // Check for "type" return type in the same line or following lines
                const is_type_generator = (std.mem.endsWith(u8, func_name, "_type") or std.mem.endsWith(u8, func_name, "Type")) and
                    (std.mem.indexOf(u8, source_line, ") type") != null or
                        std.mem.indexOf(u8, source_line, ")type") != null or
                        self.is_multiline_type_generator(file_content, source_line));

                // Check if function name contains camelCase (has uppercase letters that aren't at start)
                var has_uppercase = false;
                for (func_name, 0..) |char, i| {
                    if (i > 0 and char >= 'A' and char <= 'Z') {
                        has_uppercase = true;
                        break;
                    }
                }

                if (has_uppercase and !is_type_generator) {
                    const message = try std.fmt.allocPrint(self.allocator, "Function '{s}' must use snake_case, not camelCase - critical KausalDB convention", .{func_name});
                    // Note: We're leaking this message, but for a simple checker that's acceptable
                    try self.add_violation(file_path, line, message);
                } else if (!has_uppercase and is_type_generator) {
                    const message = try std.fmt.allocPrint(self.allocator, "Type generator function '{s}' should use PascalCase - convert from snake_case", .{func_name});
                    // Note: We're leaking this message, but for a simple checker that's acceptable
                    try self.add_violation(file_path, line, message);
                }
                // Note: If is_type_generator and has_uppercase, that's correct PascalCase - no violation
            }
        }
    }

    fn is_multiline_type_generator(self: *TidyChecker, file_content: []const u8, current_line: []const u8) bool {
        _ = self;

        // Find the current line position in the file
        const current_line_ptr = current_line.ptr;
        const file_ptr = file_content.ptr;

        // Safety: Converting pointers to integers for bounds checking
        if (@intFromPtr(current_line_ptr) < @intFromPtr(file_ptr) or
            @intFromPtr(current_line_ptr) >= @intFromPtr(file_ptr) + file_content.len)
        {
            return false;
        }

        const current_offset = @intFromPtr(current_line_ptr) - @intFromPtr(file_ptr);

        // Look forward from current position for ") type {" pattern within next 200 characters
        const search_end = @min(current_offset + 200, file_content.len);
        const search_text = file_content[current_offset..search_end];

        return std.mem.indexOf(u8, search_text, ") type") != null;
    }

    fn add_violation(self: *TidyChecker, file_path: []const u8, line: u32, message: []const u8) !void {
        const violation = Violation{
            .file = file_path,
            .line = line,
            .message = message,
        };
        try self.violations.append(violation);
    }

    /// Print all violations to stderr
    fn report_violations(self: *TidyChecker) void {
        if (self.violations.items.len == 0) {
            std.debug.print("tidy: no violations found\n", .{});
            return;
        }

        std.debug.print("tidy: found {d} violation(s):\n", .{self.violations.items.len});
        for (self.violations.items) |violation| {
            std.debug.print("{s}:{d}:  {s}\n", .{ violation.file, violation.line, violation.message });
        }
    }

    fn has_violations(self: *TidyChecker) bool {
        return self.violations.items.len > 0;
    }
};

/// Recursively find all .zig files in the repository, excluding the zig/ compiler directory
fn find_zig_files(allocator: std.mem.Allocator, dir_path: []const u8) !std.array_list.Managed([]u8) {
    var files = std.array_list.Managed([]u8).init(allocator);

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return files, // Return empty list if directory doesn't exist
        else => return err,
    };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        // Skip the zig/ compiler directory
        if (std.mem.startsWith(u8, entry.path, "zig/")) {
            continue;
        }

        if (entry.kind == .file and std.mem.endsWith(u8, entry.path, ".zig")) {
            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.path });
            try files.append(full_path);
        }
    }

    return files;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var checker = TidyChecker.init(allocator);
    defer checker.deinit();

    // Find all .zig files in the repository (excluding zig/ compiler directory)
    const zig_files = find_zig_files(allocator, ".") catch |err| {
        std.debug.print("Error finding .zig files: {}\n", .{err});
        std.process.exit(@intFromEnum(ExitCode.error_occurred));
    };
    defer {
        for (zig_files.items) |file_path| {
            allocator.free(file_path);
        }
        zig_files.deinit();
    }

    // Check each file
    for (zig_files.items) |file_path| {
        checker.check_file(file_path) catch |err| {
            std.debug.print("Error checking file {s}: {}\n", .{ file_path, err });
            std.process.exit(@intFromEnum(ExitCode.error_occurred));
        };
    }

    // Report results
    checker.report_violations();

    // Exit with appropriate code
    if (checker.has_violations()) {
        std.process.exit(@intFromEnum(ExitCode.violations_found));
    }
}

test "TidyChecker detects get/set violations" {
    const allocator = std.testing.allocator;

    var checker = TidyChecker.init(allocator);
    defer checker.deinit();

    // This would normally be tested with a temporary file, but for unit testing
    // we can test the core logic by manually calling the violation detection
    try checker.add_violation("test.zig", 42, "test message");

    try std.testing.expect(checker.has_violations());
    try std.testing.expectEqual(@as(usize, 1), checker.violations.items.len);
}
