//===- EcoPAPSimplify.cpp - PAP optimization pass -------------------------===//
//
// This pass optimizes partial application patterns in the ECO dialect:
// - Converts saturated papCreate+papExtend to direct calls (P1)
// - Fuses papExtend chains (P2)
// - Enables DCE of unused closures (P3 - via canonical DCE)
//
//===----------------------------------------------------------------------===//

#include "mlir/Pass/Pass.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/PatternMatch.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/Transforms/GreedyPatternRewriteDriver.h"

#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../Passes.h"

using namespace mlir;
using namespace eco;

namespace {

//===----------------------------------------------------------------------===//
// Pattern P1: Saturated papCreate + papExtend -> direct eco.call
//===----------------------------------------------------------------------===//
//
// Match:
//   %c = eco.papCreate @f(%captured...) { arity = A, num_captured = C }
//   %r = eco.papExtend %c(%newArgs...) { remaining_arity = K }
// Where K == newArgs.size() (saturated) AND %c has single use
//
// Rewrite to:
//   %r = eco.call @f(%captured..., %newArgs...)
//
/// Check if a function uses the args-array calling convention.
/// Returns true if the function signature is: (ptr) -> i64 or (ptr) -> ptr
/// These functions are meant to be called through the closure evaluator, not directly.
static bool usesArgsArrayConvention(Operation *funcOp) {
    if (auto llvmFunc = dyn_cast<LLVM::LLVMFuncOp>(funcOp)) {
        auto funcType = llvmFunc.getFunctionType();
        // Must have exactly one parameter
        if (funcType.getNumParams() != 1)
            return false;
        // Parameter must be a pointer
        if (!isa<LLVM::LLVMPointerType>(funcType.getParamType(0)))
            return false;
        // Return type must be i64 or ptr
        auto retType = funcType.getReturnType();
        if (auto intTy = dyn_cast<IntegerType>(retType))
            return intTy.getWidth() == 64;
        return isa<LLVM::LLVMPointerType>(retType);
    }
    return false;
}

struct SaturatedPapToCallPattern : public OpRewritePattern<PapExtendOp> {
    using OpRewritePattern::OpRewritePattern;

    LogicalResult matchAndRewrite(PapExtendOp extendOp,
                                  PatternRewriter &rewriter) const override {
        // Check saturation: remaining_arity == newargs.size()
        int64_t remainingArity = extendOp.getRemainingArity();
        auto newargs = extendOp.getNewargs();
        if (static_cast<int64_t>(newargs.size()) != remainingArity)
            return failure();  // Not saturated

        // Find defining papCreate
        auto createOp = extendOp.getClosure().getDefiningOp<PapCreateOp>();
        if (!createOp)
            return failure();  // Closure not from papCreate

        // Check single use - safe to inline
        if (!extendOp.getClosure().hasOneUse())
            return failure();  // Closure used elsewhere

        // Look up the target function to verify it has a compatible signature.
        // Skip transformation if the function uses the args-array calling convention
        // (i.e., llvm.func with (ptr) -> i64), as those are meant for closure calls.
        auto module = extendOp->getParentOfType<ModuleOp>();
        StringRef funcName = createOp.getFunction();
        auto targetFunc = module.lookupSymbol(funcName);
        if (!targetFunc)
            return failure();  // Function not found - let later passes handle it

        // Skip if target uses args-array convention (not compatible with direct calls)
        if (usesArgsArrayConvention(targetFunc))
            return failure();

        // Build combined operand list: captured + newargs
        SmallVector<Value> allOperands;
        allOperands.append(createOp.getCaptured().begin(),
                          createOp.getCaptured().end());
        allOperands.append(newargs.begin(), newargs.end());

        // Get the result type from the papExtend (preserving exact type)
        Type resultType = extendOp.getResult().getType();

        // Create direct call with the callee from papCreate
        // CallOp build signature: (results, operands, callee, musttail, remaining_arity)
        auto callOp = rewriter.create<CallOp>(
            extendOp.getLoc(),
            TypeRange{resultType},              // Result types
            allOperands,                        // Operands
            createOp.getFunctionAttr(),         // callee (FlatSymbolRefAttr)
            nullptr,                            // musttail (not a tail call)
            nullptr);                           // remaining_arity (not indirect)

        rewriter.replaceOp(extendOp, callOp.getResults());
        // papCreate will be DCE'd since it now has no uses
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Pattern P2: papExtend chain fusion
//===----------------------------------------------------------------------===//
//
// Match:
//   %c1 = eco.papExtend %c0(%a...) { remaining_arity = K1 } (NOT saturated)
//   %c2 = eco.papExtend %c1(%b...) { remaining_arity = K2 }
// Where %c1 has single use
//
// Rewrite to:
//   %c2 = eco.papExtend %c0(%a..., %b...) { remaining_arity = K1 }
//
struct FusePapExtendChainPattern : public OpRewritePattern<PapExtendOp> {
    using OpRewritePattern::OpRewritePattern;

    LogicalResult matchAndRewrite(PapExtendOp extendOp,
                                  PatternRewriter &rewriter) const override {
        // Find defining papExtend (chain case)
        auto prevExtend = extendOp.getClosure().getDefiningOp<PapExtendOp>();
        if (!prevExtend)
            return failure();  // Not a chain

        // Check single use of intermediate closure
        if (!extendOp.getClosure().hasOneUse())
            return failure();

        // Check prev extend is NOT saturated (otherwise it would have been
        // converted to a call, or if it's saturated, P1 should handle it)
        int64_t prevRemaining = prevExtend.getRemainingArity();
        if (static_cast<int64_t>(prevExtend.getNewargs().size()) == prevRemaining)
            return failure();

        // Build fused newargs: prev.newargs + this.newargs
        SmallVector<Value> fusedNewargs;
        fusedNewargs.append(prevExtend.getNewargs().begin(),
                           prevExtend.getNewargs().end());
        fusedNewargs.append(extendOp.getNewargs().begin(),
                           extendOp.getNewargs().end());

        // Compute bitmap from SSA types (source-of-truth approach)
        // Bit i is set if newarg[i] is NOT !eco.value (i.e., is unboxed primitive)
        uint64_t fusedBitmap = 0;
        for (size_t i = 0; i < fusedNewargs.size(); ++i) {
            if (!isa<ValueType>(fusedNewargs[i].getType())) {
                fusedBitmap |= (1ULL << i);
            }
        }

        // Get result type from current extendOp
        Type resultType = extendOp.getResult().getType();

        // Create fused papExtend with remaining_arity from first extend
        // PapExtendOp build signature: (result, closure, newargs, remaining_arity, newargs_unboxed_bitmap)
        auto fusedOp = rewriter.create<PapExtendOp>(
            extendOp.getLoc(),
            resultType,                         // Result type
            prevExtend.getClosure(),            // Original closure (skip intermediate)
            fusedNewargs,                       // Fused newargs
            prevExtend.getRemainingArity(),     // Use K1 (arity before first apply)
            fusedBitmap);                       // Computed bitmap

        rewriter.replaceOp(extendOp, fusedOp.getResult());
        // prevExtend will be DCE'd since it now has no uses
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Pass definition
//===----------------------------------------------------------------------===//

struct EcoPAPSimplifyPass
    : public PassWrapper<EcoPAPSimplifyPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoPAPSimplifyPass)

    StringRef getArgument() const override { return "eco-pap-simplify"; }

    StringRef getDescription() const override {
        return "Optimize PAP patterns: saturated->call, chain fusion";
    }

    void runOnOperation() override {
        ModuleOp module = getOperation();
        MLIRContext *ctx = &getContext();

        RewritePatternSet patterns(ctx);
        patterns.add<SaturatedPapToCallPattern>(ctx);
        patterns.add<FusePapExtendChainPattern>(ctx);

        if (failed(applyPatternsGreedily(module, std::move(patterns))))
            signalPassFailure();
    }
};

} // namespace

std::unique_ptr<Pass> eco::createEcoPAPSimplifyPass() {
    return std::make_unique<EcoPAPSimplifyPass>();
}
