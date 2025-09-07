//! CLI module coordination interface.
//!
//! Provides clean interface between command parsing and execution
//! for the KausalDB command-line interface. Legacy CLI system has been
//! removed in favor of the natural language interface.

const std = @import("std");

const natural_commands = @import("natural_commands.zig");
const natural_executor = @import("natural_executor.zig");

// Re-export natural CLI types and functions
pub const Command = natural_commands.NaturalCommand;
pub const CommandError = natural_commands.NaturalCommandError;
pub const ParseResult = natural_commands.NaturalParseResult;
pub const ExecutionContext = natural_executor.NaturalExecutionContext;
pub const ExecutorError = natural_executor.NaturalExecutorError;

// Re-export natural CLI functions
pub const parse_command = natural_commands.parse_natural_command;
pub const execute_command = natural_executor.execute_natural_command;
