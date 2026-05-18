//===- EcoPipeline.cpp - Shared Eco lowering pipeline ---------------------===//
//
// Implementation of the shared pipeline construction API used by both ecoc
// and EcoRunner.
//
//===----------------------------------------------------------------------===//

#include "EcoPipeline.h"
#include "Passes.h"

#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlow.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/Func/Extensions/AllExtensions.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/Dialect/LLVMIR/Transforms/InlinerInterfaceImpl.h"
#include "mlir/Dialect/SCF/IR/SCF.h"

#include "mlir/Conversion/ArithToLLVM/ArithToLLVM.h"
#include "mlir/Conversion/ControlFlowToLLVM/ControlFlowToLLVM.h"
#include "mlir/Conversion/ReconcileUnrealizedCasts/ReconcileUnrealizedCasts.h"
#include "mlir/Conversion/SCFToControlFlow/SCFToControlFlow.h"

#include "mlir/Pass/PassManager.h"
#include "mlir/Transforms/Passes.h"

#include "EcoDialect.h"
#include "BF/BFDialect.h"

using namespace mlir;

namespace eco {

void registerRequiredDialects(DialectRegistry &registry) {
    func::registerAllExtensions(registry);
    LLVM::registerInlinerInterface(registry);
}

void loadRequiredDialects(MLIRContext &context) {
    context.getOrLoadDialect<eco::EcoDialect>();
    context.getOrLoadDialect<bf::BFDialect>();
    context.getOrLoadDialect<func::FuncDialect>();
    context.getOrLoadDialect<cf::ControlFlowDialect>();
    context.getOrLoadDialect<arith::ArithDialect>();
    context.getOrLoadDialect<scf::SCFDialect>();
    context.getOrLoadDialect<LLVM::LLVMDialect>();
}

void buildEcoToEcoPipeline(PassManager &pm, const EcoPipelineOptions &opts) {
    // Stage 1: Eco -> Eco transformations.
    // TODO: Add construct lowering pass.
    // pm.addPass(eco::createConstructLoweringPass());
    pm.addPass(eco::createRCEliminationPass());

#ifdef ECO_LOWERING_VALIDATION
    // Verify closure capture integrity (CGEN_CLOSURE_003):
    // papCreate consistency + no cross-function SSA refs in lambda bodies.
    // Must run early, before PAP simplification may rewrite closure ops.
    pm.addPass(eco::createCheckEcoClosureCapturesPass());
#endif

    // PAP simplification: fuse closures, convert saturated PAPs to direct calls
    pm.addPass(eco::createEcoPAPSimplifyPass());

    // Phase 1 escape analysis + unboxed-aggregate specialise. OFF by
    // default; only added when -enable-unboxed-agg is set so existing
    // pipelines retain identical IR. Both passes are per-function and
    // run in lockstep: analysis tags Tuple2/3ConstructOp results that
    // never escape, specialise rewrites them to eco.make.tuple2/3.
    // Must run before EcoGCPrepare so the construct ops haven't yet
    // accumulated GC root operands.
    if (opts.enableUnboxedAgg) {
        // Phase 3 cross-function specialisation runs FIRST: it looks at
        // each func.func's logical-types attributes and clones eligible
        // candidates as @f$unboxed workers, replacing the original body
        // with a from_heap/to_heap wrapper. The per-func passes below
        // then clean up both the worker body and the wrapper body.
        pm.addPass(eco::createEcoUnboxedAggCrossSpecPass());
        pm.addNestedPass<func::FuncOp>(eco::createEcoEscapeAnalysisPass());
        pm.addNestedPass<func::FuncOp>(eco::createEcoUnboxedAggSpecializePass());

        // Phase 3.1 #3: flatten aggregate-typed boundaries so the LLVM
        // dialect's func signatures stay scalar-only. After this pass
        // no eco.tuple2/3/record/custom appears at any function
        // boundary — RS4GC's FCA-unimplemented assertion is avoided
        // structurally (REP_AGG_001 amendment).
        pm.addPass(eco::createEcoFlattenAggBoundaryPass());
    }

    // Generate external declarations for undefined functions (kernel functions, etc.)
    pm.addPass(eco::createUndefinedFunctionPass());
}

void buildEcoToLLVMPipeline(PassManager &pm, const EcoPipelineOptions &opts) {
    // Stage 1: Eco -> Eco transformations.
    buildEcoToEcoPipeline(pm, opts);

    // Stage 2: Eco -> Standard MLIR (func/cf/arith).
    pm.addPass(eco::createJoinpointNormalizationPass());
    pm.addPass(eco::createEcoControlFlowToSCFPass());
    pm.addNestedPass<func::FuncOp>(createCanonicalizerPass());

    // Stage 2.5: GC preparation (root sets, allocation grouping, safepoint rewrite).
    pm.addPass(eco::createEcoGCPreparePass());
#ifdef ECO_LOWERING_VALIDATION
    pm.addNestedPass<func::FuncOp>(eco::createEcoGCLivenessAuditPass());
#endif

    // Stage 3: Eco -> LLVM Dialect.
    pm.addPass(eco::createBFToLLVMPass());
    pm.addPass(eco::createEcoToLLVMPass());
#ifdef ECO_LOWERING_VALIDATION
    // Insert stale-HPointer barriers in front of direct boxed-slot stores
    // emitted by EcoToLLVM (currently only eco.array.set). Must run after
    // EcoToLLVM (which attaches the eco.boxed_slot marker) and before any
    // pass that might re-canonicalise or drop unknown attributes on
    // LLVM::StoreOp; running it immediately after the lowering keeps the
    // window minimal.
    pm.addPass(eco::createEcoBoxedStoreVerifyPass());
#endif
    pm.addPass(createSCFToControlFlowPass());
    pm.addPass(createConvertControlFlowToLLVMPass());
    pm.addPass(createArithToLLVMConversionPass());
    pm.addPass(createReconcileUnrealizedCastsPass());
}

} // namespace eco
