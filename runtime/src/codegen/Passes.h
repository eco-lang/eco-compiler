//===- Passes.h - Eco dialect lowering passes -----------------------------===//
//
// This file declares the passes for lowering the Eco dialect to LLVM.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_PASSES_H
#define ECO_PASSES_H

#include <memory>

namespace mlir {
class Pass;
class RewritePatternSet;
class TypeConverter;
class MLIRContext;
} // namespace mlir

namespace eco {

//===----------------------------------------------------------------------===//
// Pass Declarations
//===----------------------------------------------------------------------===//

// ========== Stage 1: Eco -> Eco transformations ==========

// Lowers eco.construct to eco.allocate_ctor + field stores.
std::unique_ptr<mlir::Pass> createConstructLoweringPass();

// Removes/errors on reference counting placeholder ops (incref, decref, etc).
// These are not used in tracing GC mode.
std::unique_ptr<mlir::Pass> createRCEliminationPass();

// Validates that all functions referenced by eco.call are defined or declared.
// Enforces invariant CGEN_011: no undefined function symbols may escape codegen.
// Fails the build if any undefined functions are found.
std::unique_ptr<mlir::Pass> createUndefinedFunctionPass();

// Validates closure capture integrity (CGEN_CLOSURE_003):
// 1. eco.papCreate num_captured and operand types match target function signature.
// 2. Lambda func.func bodies (matching *_lambda_*) have no cross-function SSA refs.
std::unique_ptr<mlir::Pass> createCheckEcoClosureCapturesPass();

// Optimizes partial application patterns:
// - Converts saturated papCreate+papExtend to direct calls (P1)
// - Fuses papExtend chains (P2)
// - Enables DCE of unused closures (P3)
std::unique_ptr<mlir::Pass> createEcoPAPSimplifyPass();

// ========== Phase 1: Escape analysis for value-level aggregates ==========

// Per-function escape analysis for small-aggregate construct ops.
// Walks each Tuple2ConstructOp / Tuple3ConstructOp result and classifies
// its uses; tags every classified op with an `eco.escape` string
// attribute ("non_escaping" or "escapes") for the specialise pass to
// consume. Off by default — only added to the pipeline when
// EcoPipelineOptions::enableUnboxedAgg is true.
std::unique_ptr<mlir::Pass> createEcoEscapeAnalysisPass();

// Specialisation pass that consumes EcoEscapeAnalysisPass's classification
// and rewrites non-escaping Tuple2/Tuple3ConstructOp results to the
// corresponding eco.make.tuple2 / eco.make.tuple3 value-aggregate ops
// (Phase 0 plumbing). Existing project ops accept either operand form
// after Phase 0.4, so direct projection users need no change. Off by
// default — only added to the pipeline alongside the analysis pass.
std::unique_ptr<mlir::Pass> createEcoUnboxedAggSpecializePass();

// Phase 3: Module-level cross-function specialization. For each func.func
// whose `eco.logical_param_types` / `eco.logical_result_types`
// attributes mark a small aggregate (tuple2/tuple3/record), clones the
// function as `@f$unboxed` with aggregate-typed parameters/results and
// replaces the original `@f` body with a thin wrapper using
// `eco.from_heap` / `eco.to_heap`. Off by default — only added to the
// pipeline when EcoPipelineOptions::enableUnboxedAgg is true.
std::unique_ptr<mlir::Pass> createEcoUnboxedAggCrossSpecPass();

// Phase 3.1: Pre-lowering boundary flattening. Rewrites worker funcs
// whose signatures carry aggregate-typed params/results into scalar-
// only function_types: each aggregate param becomes N scalar params
// (with an `eco.make.*` op at entry to repack), each aggregate result
// becomes N scalar results (with `eco.project.*` ops at every return
// to decompose). Every call site of a flattened worker is rewritten
// symmetrically. After this pass, no aggregate type appears at any
// func.func boundary — RS4GC never sees struct-typed gc pointers at
// call boundaries (REP_AGG_001 amendment). Lifts the all-primitive-
// elements restriction from EcoUnboxedAggCrossSpec.
std::unique_ptr<mlir::Pass> createEcoFlattenAggBoundaryPass();

// ========== Stage 2: Eco -> Standard MLIR (func/cf/arith) ==========

// Analyzes and classifies joinpoints for SCF lowering eligibility.
// Marks looping, single-exit joinpoints with normalized continuations as SCF-candidates.
std::unique_ptr<mlir::Pass> createJoinpointNormalizationPass();

// Lowers eligible eco.case and eco.joinpoint ops to SCF dialect (scf.if, scf.while).
// Non-eligible ops are left for createControlFlowLoweringPass.
std::unique_ptr<mlir::Pass> createEcoControlFlowToSCFPass();

// Lowers eco control flow ops (case, joinpoint, jump, return) to cf dialect.
std::unique_ptr<mlir::Pass> createControlFlowLoweringPass();

// ========== Stage 2.5: GC Preparation (before LLVM lowering) ==========

// Phase 1 of widen-construct-make-call-aggregates. Walks construct.*,
// make.*, and eco.call ops and inserts `eco.to_heap` in front of every
// operand whose type would land at a boxed sink (always for
// construct.*/eco.call; only when the inner aggregate contains a GC
// pointer for make.*). Must run before EcoGCPrepare so the new
// allocations get GC roots computed and can be grouped with adjacent
// allocs.
std::unique_ptr<mlir::Pass> createEcoBoxAggregateOperandsPass();

// Computes GC root sets for all GCRootCarrier ops (allocations, calls,
// safepoints, PAP ops, construct ops) via SSA liveness analysis.
// Groups adjacent allocations. Must run after all Eco->Eco transformations
// and control flow lowering, before EcoToLLVM.
std::unique_ptr<mlir::Pass> createEcoGCPreparePass();

// Audits GC root sets attached by EcoGCPrepare against SSA liveness of
// !eco.value values. Emits diagnostics and fails the pipeline if any
// GCRootCarrier op is missing a root that is semantically live across it.
// No-op in non-debug builds (gated on ECO_GC_DEBUG).
std::unique_ptr<mlir::Pass> createEcoGCLivenessAuditPass();

// ========== Stage 3: Eco -> LLVM Dialect ==========

// Lowers eco heap operations (allocate_*, project, box, unbox) to LLVM.
std::unique_ptr<mlir::Pass> createHeapOpsToLLVMPass();

// Lowers eco.constant to LLVM constants.
std::unique_ptr<mlir::Pass> createConstantToLLVMPass();

// Lowers eco.call and closure operations to LLVM.
std::unique_ptr<mlir::Pass> createCallLoweringPass();

// Lowers eco.string_literal to LLVM global constants (UTF-8 -> UTF-16).
std::unique_ptr<mlir::Pass> createStringLiteralLoweringPass();

// Combined pass that runs all eco-to-LLVM lowering.
std::unique_ptr<mlir::Pass> createEcoToLLVMPass();

// Inserts eco_validate_nursery_hptr_bits calls in front of LLVM StoreOps
// tagged with `eco.boxed_slot` (currently only the direct heap store emitted
// by eco.array.set lowering). Localises the *write* of a stale nursery
// HPointer from compiled Elm — the path the runtime-helper write hooks
// cannot see. Gated by ECO_LOWERING_VALIDATION (no-op otherwise).
std::unique_ptr<mlir::Pass> createEcoBoxedStoreVerifyPass();

// ========== BF (ByteFusion) Dialect Lowering ==========

// Lowers BF dialect operations to LLVM dialect.
// This includes bf.cursor -> {i8*, i8*} struct conversion and
// lowering of bf.write.*, bf.alloc, bf.cursor.init etc.
std::unique_ptr<mlir::Pass> createBFToLLVMPass();

//===----------------------------------------------------------------------===//
// Pattern Population
//===----------------------------------------------------------------------===//

// Populates patterns for lowering eco heap ops to LLVM.
void populateEcoHeapOpsToLLVMPatterns(mlir::TypeConverter &typeConverter,
                                       mlir::RewritePatternSet &patterns);

// Populates patterns for lowering eco control flow to cf dialect.
void populateEcoControlFlowToStandardPatterns(mlir::RewritePatternSet &patterns);

// Populates patterns for lowering eco calls to LLVM.
void populateEcoCallToLLVMPatterns(mlir::TypeConverter &typeConverter,
                                    mlir::RewritePatternSet &patterns);

//===----------------------------------------------------------------------===//
// Type Converter
//===----------------------------------------------------------------------===//

// Creates the type converter for eco types to LLVM types.
// Converts eco.value -> i64 (tagged pointer representation).
std::unique_ptr<mlir::TypeConverter> createEcoToLLVMTypeConverter(mlir::MLIRContext *ctx);

//===----------------------------------------------------------------------===//
// Pass Registration
//===----------------------------------------------------------------------===//

// Registers all eco passes with the pass manager.
void registerEcoPasses();

} // namespace eco

#endif // ECO_PASSES_H
