/// Main entry point for `kausal` CLI.
const kausal_cli = @import("cli/cli.zig");

pub fn main() !void {
    try kausal_cli.run();
}
