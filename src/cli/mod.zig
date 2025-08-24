//! CLI module coordination interface.
//!
//! Provides clean interface between command parsing and execution
//! for the KausalDB command-line interface.

const std = @import("std");

const commands = @import("commands.zig");
const executor = @import("executor.zig");

// Re-export core types
pub const Command = commands.Command;
pub const CommandError = commands.CommandError;
pub const ParseResult = commands.ParseResult;
pub const ExecutionContext = executor.ExecutionContext;
pub const ExecutorError = executor.ExecutorError;

// Re-export core functions
pub const parse_command = commands.parse_command;
pub const execute_command = executor.execute_command;
