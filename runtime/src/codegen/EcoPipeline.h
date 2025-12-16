//===- EcoPipeline.h - Shared Eco lowering pipeline -----------------------===//
//
// This file declares the shared pipeline construction API used by both ecoc
// (the CLI compiler) and EcoRunner (the test execution library).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_PIPELINE_H
#define ECO_PIPELINE_H

namespace mlir {
class PassManager;
class MLIRContext;
class DialectRegistry;
} // namespace mlir

namespace eco {

//===----------------------------------------------------------------------===//
// Pipeline Construction
//===----------------------------------------------------------------------===//

/// Registers all required dialects for Eco compilation.
/// Call this before creating an MLIRContext.
void registerRequiredDialects(mlir::DialectRegistry &registry);

/// Loads all required dialects into the context.
/// Call this after creating an MLIRContext.
void loadRequiredDialects(mlir::MLIRContext &context);

/// Builds the Stage 1 pipeline: Eco -> Eco transformations.
/// This includes:
///   - RC elimination (removes reference counting placeholders)
///   - Undefined function stub generation
void buildEcoToEcoPipeline(mlir::PassManager &pm);

/// Builds the full Eco -> LLVM lowering pipeline.
/// This includes:
///   - Stage 1: Eco -> Eco transformations
///   - Stage 2: Eco -> Standard MLIR (SCF, CF)
///   - Stage 3: Eco/Standard -> LLVM dialect
void buildEcoToLLVMPipeline(mlir::PassManager &pm);

} // namespace eco

#endif // ECO_PIPELINE_H
