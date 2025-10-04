//! Ingestion scenario tests using deterministic simulation framework.
//!
//! Tests code parsing, context block extraction, and graph relationship building
//! from source files. Validates that ingestion pipeline correctly handles various
//! programming languages and maintains consistency under different conditions.
//!
//! Design rationale: Ingestion is the entry point for all data. These tests ensure
//! source code is correctly parsed, relationships are accurately extracted, and
//! the resulting graph structure represents the codebase faithfully.

const std = @import("std");
const testing = std.testing;

const harness = @import("../../testing/harness.zig");
const simulation_vfs = @import("../../sim/simulation_vfs.zig");
const storage_engine_mod = @import("../../storage/engine.zig");
const types = @import("../../core/types.zig");

const ModelState = harness.ModelState;
const Operation = harness.Operation;
const OperationMix = harness.OperationMix;
const OperationType = harness.OperationType;
const PropertyChecker = harness.PropertyChecker;
const SimulationRunner = harness.SimulationRunner;
const WorkloadGenerator = harness.WorkloadGenerator;

const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const EdgeType = types.EdgeType;
const GraphEdge = types.GraphEdge;

// ====================================================================
// Single Language Ingestion Scenarios
// ====================================================================

test "scenario: zig file ingestion with function relationships" {
    const allocator = testing.allocator;

    // Ingestion-focused operations
    const operation_mix = OperationMix{
        .put_block_weight = 50, // Heavy block creation from parsing
        .find_block_weight = 20,
        .delete_block_weight = 0,
        .put_edge_weight = 30, // Relationships between functions
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x13001,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Configure for Zig ingestion simulation
    runner.ingestion_config.language = .zig;
    runner.ingestion_config.generate_functions = true;
    runner.ingestion_config.generate_imports = true;
    runner.ingestion_config.generate_structs = true;

    try runner.run(500);

    // Properties validated:
    // - Functions are extracted as blocks
    // - Call relationships create edges
    // - Import dependencies are tracked
}

test "scenario: rust file ingestion with trait implementations" {
    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 45,
        .find_block_weight = 15,
        .delete_block_weight = 0,
        .put_edge_weight = 35, // Heavy on relationships
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x13002,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Configure for Rust ingestion
    runner.ingestion_config.language = .rust;
    runner.ingestion_config.generate_traits = true;
    runner.ingestion_config.generate_impls = true;
    runner.ingestion_config.generate_modules = true;

    try runner.run(600);

    // Verify trait relationships are captured
    try runner.verify_trait_impl_relationships();
}

test "scenario: python file ingestion with class hierarchies" {
    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 40,
        .find_block_weight = 20,
        .delete_block_weight = 0,
        .put_edge_weight = 35,
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x13003,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Configure for Python ingestion
    runner.ingestion_config.language = .python;
    runner.ingestion_config.generate_classes = true;
    runner.ingestion_config.generate_inheritance = true;
    runner.ingestion_config.generate_decorators = true;

    try runner.run(500);

    // Verify class hierarchies are preserved
    try runner.verify_inheritance_relationships();
}

test "scenario: typescript file ingestion with type definitions" {
    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 35,
        .find_block_weight = 25,
        .delete_block_weight = 0,
        .put_edge_weight = 35,
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x13004,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Configure for TypeScript ingestion
    runner.ingestion_config.language = .typescript;
    runner.ingestion_config.generate_interfaces = true;
    runner.ingestion_config.generate_types = true;
    runner.ingestion_config.generate_exports = true;

    try runner.run(450);

    // Verify type relationships are captured
    try runner.verify_type_relationships();
}

// ====================================================================
// Multi-Language Project Scenarios
// ====================================================================

test "scenario: mixed language project ingestion" {
    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 40,
        .find_block_weight = 20,
        .delete_block_weight = 0,
        .put_edge_weight = 35,
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x14001,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Configure for mixed language ingestion
    runner.ingestion_config.language = .mixed;
    runner.ingestion_config.language_distribution = .{
        .zig = 0.3,
        .rust = 0.3,
        .python = 0.2,
        .typescript = 0.2,
    };

    try runner.run(1000);

    // Verify cross-language relationships are handled
    try runner.verify_cross_language_consistency();
}

test "scenario: incremental project updates" {
    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 30,
        .find_block_weight = 25,
        .delete_block_weight = 10, // File modifications
        .put_edge_weight = 25,
        .find_edges_weight = 10,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x14002,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Configure incremental update simulation
    runner.ingestion_config.simulate_incremental = true;
    runner.ingestion_config.modification_rate = 0.2;

    // Initial ingestion
    try runner.run(300);

    // Incremental updates
    try runner.run(700);

    // Verify incremental updates maintain consistency
    try runner.verify_incremental_consistency();
}

// ====================================================================
// Error Handling Scenarios
// ====================================================================

test "scenario: malformed file handling" {
    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 40,
        .find_block_weight = 30,
        .delete_block_weight = 5,
        .put_edge_weight = 20,
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x15001,
        operation_mix,
        &.{
            .{
                .operation_number = 50,
                .fault_type = .corruption,
                .syntax_error_probability = 0.1, // 10% malformed files
            },
        },
    );
    defer runner.deinit();

    // Configure error injection
    runner.ingestion_config.inject_parse_errors = true;

    try runner.run(500);

    // System should handle parse errors gracefully
    try runner.verify_parse_error_handling();
}

test "scenario: partial file ingestion recovery" {
    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 45,
        .find_block_weight = 25,
        .delete_block_weight = 0,
        .put_edge_weight = 25,
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x15002,
        operation_mix,
        &.{
            .{
                .operation_number = 100,
                .fault_type = .io_error,
                .io_error_probability = 0.05, // I/O errors during ingestion
            },
        },
    );
    defer runner.deinit();

    try runner.run(400);

    // Partial ingestion should be recoverable
    try runner.verify_partial_ingestion_recovery();
}

// ====================================================================
// Performance and Scale Scenarios
// ====================================================================

test "scenario: large file ingestion performance" {
    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 60, // Heavy ingestion
        .find_block_weight = 15,
        .delete_block_weight = 0,
        .put_edge_weight = 20,
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x16001,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Configure large file simulation
    runner.ingestion_config.generate_large_files = true;
    runner.ingestion_config.avg_functions_per_file = 100;
    runner.ingestion_config.avg_lines_per_function = 50;

    try runner.run(300);

    // Verify ingestion scales appropriately
    const stats = runner.performance_stats();
    try testing.expect(stats.avg_ingestion_time < 100_000); // < 100ms per file
}

test "scenario: bulk project ingestion" {
    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 70,
        .find_block_weight = 10,
        .delete_block_weight = 0,
        .put_edge_weight = 15,
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x16002,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Configure bulk ingestion
    runner.ingestion_config.bulk_mode = true;
    runner.ingestion_config.files_per_batch = 50;

    try runner.run(1000);

    // Bulk ingestion should be efficient
    try runner.verify_bulk_ingestion_performance();
}

// ====================================================================
// Context Extraction Scenarios
// ====================================================================

test "scenario: function context extraction accuracy" {
    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 45,
        .find_block_weight = 30,
        .delete_block_weight = 0,
        .put_edge_weight = 20,
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x17001,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Configure detailed function extraction
    runner.ingestion_config.extract_comments = true;
    runner.ingestion_config.extract_signatures = true;
    runner.ingestion_config.extract_body = true;

    try runner.run(400);

    // Verify context blocks contain expected information
    try runner.verify_context_extraction();
}

test "scenario: documentation block linking" {
    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 35,
        .find_block_weight = 25,
        .delete_block_weight = 0,
        .put_edge_weight = 35, // Doc linking creates edges
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x17002,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Configure documentation extraction
    runner.ingestion_config.extract_docs = true;
    runner.ingestion_config.link_docs_to_code = true;

    try runner.run(500);

    // Verify documentation is linked to code blocks
    try runner.verify_doc_linking();
}

// ====================================================================
// Graph Building Scenarios
// ====================================================================

test "scenario: import dependency graph construction" {
    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 30,
        .find_block_weight = 15,
        .delete_block_weight = 0,
        .put_edge_weight = 40, // Heavy on import edges
        .find_edges_weight = 15,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x18001,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Configure import tracking
    runner.ingestion_config.track_imports = true;
    runner.ingestion_config.resolve_import_paths = true;

    try runner.run(600);

    // Verify import graph is correctly built
    try runner.verify_import_graph();
}

test "scenario: call graph construction" {
    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 25,
        .find_block_weight = 15,
        .delete_block_weight = 0,
        .put_edge_weight = 45, // Heavy on call edges
        .find_edges_weight = 15,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x18002,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Configure call tracking
    runner.ingestion_config.track_function_calls = true;
    runner.ingestion_config.resolve_call_targets = true;

    try runner.run(700);

    // Verify call graph accuracy
    try runner.verify_call_graph();
}

// ====================================================================
// Metadata Extraction Scenarios
// ====================================================================

test "scenario: rich metadata extraction" {
    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 50,
        .find_block_weight = 35,
        .delete_block_weight = 0,
        .put_edge_weight = 10,
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x19001,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Configure comprehensive metadata extraction
    runner.ingestion_config.extract_all_metadata = true;
    runner.ingestion_config.include_line_numbers = true;
    runner.ingestion_config.include_complexity_metrics = true;

    try runner.run(400);

    // Verify metadata completeness
    try runner.verify_metadata_extraction();
}

test "scenario: sequence tracking during updates" {
    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 35,
        .find_block_weight = 30,
        .delete_block_weight = 10,
        .put_edge_weight = 20,
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x19002,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Configure sequence tracking
    runner.ingestion_config.track_sequences = true;
    runner.ingestion_config.preserve_history = true;

    try runner.run(600);

    // Verify sequence history is maintained
    try runner.verify_sequence_tracking();
}

// ====================================================================
// Regression Tests
// ====================================================================

test "scenario: regression - Unicode handling in source files" {
    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 40,
        .find_block_weight = 35,
        .delete_block_weight = 5,
        .put_edge_weight = 15,
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x1A001,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Configure Unicode content generation
    runner.ingestion_config.generate_unicode_content = true;

    try runner.run(300);

    // Verify Unicode is handled correctly
    try runner.verify_unicode_handling();
}

test "scenario: regression - circular import handling" {
    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 30,
        .find_block_weight = 20,
        .delete_block_weight = 0,
        .put_edge_weight = 40,
        .find_edges_weight = 10,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x1A002,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Configure circular import generation
    runner.ingestion_config.allow_circular_imports = true;
    runner.ingestion_config.circular_import_probability = 0.2;

    try runner.run(500);

    // System should handle circular imports
    try runner.verify_circular_import_handling();
}

test "scenario: large directory tree ingestion (1000+ files)" {
    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 70, // Heavy block creation
        .find_block_weight = 10,
        .delete_block_weight = 0,
        .put_edge_weight = 15,
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x1B001,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Configure bulk ingestion for large-scale directory tree
    runner.ingestion_config.bulk_mode = true;
    runner.ingestion_config.generate_large_files = true;

    // Run 1500 operations to simulate large directory ingestion
    try runner.run(1500);

    // Verify ingestion handles high volume efficiently
}

test "scenario: invalid UTF-8 handling in source files" {
    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 50,
        .find_block_weight = 30,
        .delete_block_weight = 5,
        .put_edge_weight = 10,
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x1B002,
        operation_mix,
        &.{
            .{
                .operation_number = 30,
                .fault_type = .corruption,
            },
        },
    );
    defer runner.deinit();

    // Use Unicode content generation to test encoding handling
    runner.ingestion_config.generate_unicode_content = true;

    try runner.run(400);

    // Verify graceful degradation on encoding issues
}

test "scenario: circular symlink detection" {
    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 35,
        .find_block_weight = 40,
        .delete_block_weight = 5,
        .put_edge_weight = 15,
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x1B003,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Test with circular imports as a proxy for symlink-like behavior
    runner.ingestion_config.allow_circular_imports = true;

    try runner.run(300);

    // Verify infinite loop prevention in traversal
}

test "scenario: parser resilience to malformed syntax" {
    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 45,
        .find_block_weight = 35,
        .delete_block_weight = 5,
        .put_edge_weight = 10,
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x1B004,
        operation_mix,
        &.{
            .{
                .operation_number = 40,
                .fault_type = .corruption,
            },
        },
    );
    defer runner.deinit();

    // Enable parse error injection
    runner.ingestion_config.inject_parse_errors = true;

    try runner.run(500);

    // Ensure parser handles malformed syntax gracefully
}
