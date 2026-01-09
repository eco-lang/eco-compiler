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
#include "mlir/Conversion/SCFToControlFlow/SCFToControlFlow.h"

#include "mlir/Pass/PassManager.h"
#include "mlir/Transforms/Passes.h"

#include "EcoDialect.h"

using namespace mlir;

namespace eco {

void registerRequiredDialects(DialectRegistry &registry) {
    func::registerAllExtensions(registry);
    LLVM::registerInlinerInterface(registry);
}

void loadRequiredDialects(MLIRContext &context) {
    context.getOrLoadDialect<eco::EcoDialect>();
    context.getOrLoadDialect<func::FuncDialect>();
    context.getOrLoadDialect<cf::ControlFlowDialect>();
    context.getOrLoadDialect<arith::ArithDialect>();
    context.getOrLoadDialect<scf::SCFDialect>();
    context.getOrLoadDialect<LLVM::LLVMDialect>();
}

void buildEcoToEcoPipeline(PassManager &pm) {
    // Stage 1: Eco -> Eco transformations.
    // TODO: Add construct lowering pass.
    // pm.addPass(eco::createConstructLoweringPass());
    pm.addPass(eco::createRCEliminationPass());

    // Generate external declarations for undefined functions (kernel functions, etc.)
    pm.addPass(eco::createUndefinedFunctionPass());
}

void buildEcoToLLVMPipeline(PassManager &pm) {
    // Stage 1: Eco -> Eco transformations.
    buildEcoToEcoPipeline(pm);

    // Stage 2: Eco -> Standard MLIR (func/cf/arith).

    // Classify joinpoints for SCF lowering eligibility.
    pm.addPass(eco::createJoinpointNormalizationPass());

    // Lower eligible eco.case/joinpoint to SCF dialect.
    // Non-eligible ops are left for the CF path in EcoToLLVM.
    pm.addPass(eco::createEcoControlFlowToSCFPass());

    pm.addNestedPass<func::FuncOp>(createCanonicalizerPass());

    // Convert SCF to CF before EcoToLLVM.
    // This creates cf.br/cf.cond_br with !eco.value types, which
    // EcoToLLVM will then convert to LLVM types.
    pm.addPass(createSCFToControlFlowPass());

    // Stage 3: Eco -> LLVM Dialect.
    // This also handles remaining eco control flow ops (case/joinpoint/jump)
    // that weren't lowered to SCF. Also includes func-to-llvm conversion.
    pm.addPass(eco::createEcoToLLVMPass());

    // Standard MLIR dialect conversions to LLVM.
    // Note: func-to-llvm is now part of EcoToLLVM to ensure functions are
    // converted before eco.papCreate tries to reference them.
    pm.addPass(createConvertControlFlowToLLVMPass());
    pm.addPass(createArithToLLVMConversionPass());
}

} // namespace eco
