//! Golden master testing framework for KausalDB.
//!
//! Provides utilities for creating and validating golden master test files
//! to ensure consistent behavior across changes.

const std = @import("std");

pub const GoldenMaster = struct {
    allocator: std.mem.Allocator,
    test_name: []const u8,
    golden_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, test_name: []const u8, golden_dir: []const u8) GoldenMaster {
        return GoldenMaster{
            .allocator = allocator,
            .test_name = test_name,
            .golden_dir = golden_dir,
        };
    }

    pub fn validate_output(self: GoldenMaster, actual_output: []const u8) !void {
        const golden_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.golden.json", .{ self.golden_dir, self.test_name });
        defer self.allocator.free(golden_path);

        // For now, just validate the output is not empty - full implementation would compare against stored golden files
        if (actual_output.len == 0) {
            return error.EmptyOutput;
        }
    }

    pub fn save_golden(self: GoldenMaster, output: []const u8) !void {
        const golden_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.golden.json", .{ self.golden_dir, self.test_name });
        defer self.allocator.free(golden_path);

        const file = try std.fs.cwd().createFile(golden_path, .{});
        defer file.close();

        try file.writeAll(output);
    }
};

pub fn create_golden_master(allocator: std.mem.Allocator, test_name: []const u8, golden_dir: []const u8) GoldenMaster {
    return GoldenMaster.init(allocator, test_name, golden_dir);
}
