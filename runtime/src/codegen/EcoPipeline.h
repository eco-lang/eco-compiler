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

/// Forward-compatible options struct. New flags are added here and
/// default OFF so existing callers don't need to change.
struct EcoPipelineOptions {};

/// Builds the Stage 1 pipeline: Eco -> Eco transformations.
/// This includes:
///   - RC elimination (removes reference counting placeholders)
///   - Undefined function stub generation
void buildEcoToEcoPipeline(mlir::PassManager &pm,
                           const EcoPipelineOptions &opts = {});

/// Builds the Eco -> Eco + Stage 2 + M4-slot pipeline, stopping immediately
/// before GC preparation. This includes:
///   - Stage 1: Eco -> Eco transformations
///   - Stage 2: Eco -> Standard MLIR (SCF, CF)
///   - the M4 slot: EcoFoldProject + CSE
///
/// This is the last point at which Eco-level `construct`/`project` ops still
/// exist AND the M4 folders have already run, which makes it the only
/// observation window for fold-project's effect on them. Exposed for
/// `ecoc --emit=mlir-opt` and for FileCheck tests that assert M4-slot
/// behaviour; `buildEcoToLLVMPipeline` calls it, so the pass order the real
/// compilation uses is unchanged.
void buildEcoToOptPipeline(mlir::PassManager &pm,
                           const EcoPipelineOptions &opts = {});

/// Builds the full Eco -> LLVM lowering pipeline.
/// This includes:
///   - Stages 1-2 + M4 slot (via buildEcoToOptPipeline)
///   - Stage 2.5: GC preparation
///   - Stage 3: Eco/Standard -> LLVM dialect
void buildEcoToLLVMPipeline(mlir::PassManager &pm,
                            const EcoPipelineOptions &opts = {});

} // namespace eco

#endif // ECO_PIPELINE_H
