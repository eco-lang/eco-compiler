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

// Optimizes partial application patterns:
// - Converts saturated papCreate+papExtend to direct calls (P1)
// - Fuses papExtend chains (P2)
// - Enables DCE of unused closures (P3)
std::unique_ptr<mlir::Pass> createEcoPAPSimplifyPass();

// ========== Stage 2: Eco -> Standard MLIR (func/cf/arith) ==========

// Analyzes and classifies joinpoints for SCF lowering eligibility.
// Marks looping, single-exit joinpoints with normalized continuations as SCF-candidates.
std::unique_ptr<mlir::Pass> createJoinpointNormalizationPass();

// Lowers eligible eco.case and eco.joinpoint ops to SCF dialect (scf.if, scf.while).
// Non-eligible ops are left for createControlFlowLoweringPass.
std::unique_ptr<mlir::Pass> createEcoControlFlowToSCFPass();

// Lowers eco control flow ops (case, joinpoint, jump, return) to cf dialect.
std::unique_ptr<mlir::Pass> createControlFlowLoweringPass();

// ========== Stage 3: Eco -> LLVM Dialect ==========

// Lowers eco heap operations (allocate_*, project, box, unbox) to LLVM.
std::unique_ptr<mlir::Pass> createHeapOpsToLLVMPass();

// Lowers eco.constant to LLVM constants.
std::unique_ptr<mlir::Pass> createConstantToLLVMPass();

// Lowers eco.call and closure operations to LLVM.
std::unique_ptr<mlir::Pass> createCallLoweringPass();

// Lowers eco.safepoint (currently no-op).
std::unique_ptr<mlir::Pass> createSafepointLoweringPass();

// Lowers eco.string_literal to LLVM global constants (UTF-8 -> UTF-16).
std::unique_ptr<mlir::Pass> createStringLiteralLoweringPass();

// Combined pass that runs all eco-to-LLVM lowering.
std::unique_ptr<mlir::Pass> createEcoToLLVMPass();

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
