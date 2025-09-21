//! KausalDB main entry point - delegates to CLI v2 implementation.

const cli = @import("cli/cli.zig");

pub fn main() !void {
    try cli.main();
}
