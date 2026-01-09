//===- EcoToLLVMFunc.cpp - Function lowering patterns ---------------------===//
//
// This file implements lowering patterns for kernel function declarations.
// Kernel functions (marked with is_kernel=true) are converted to LLVM
// external function declarations.
//
//===----------------------------------------------------------------------===//

#include "EcoToLLVMInternal.h"
#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../EcoTypes.h"

#include "mlir/Dialect/Func/IR/FuncOps.h"

using namespace mlir;
using namespace eco;
using namespace eco::detail;

namespace {

//===----------------------------------------------------------------------===//
// Kernel func.func -> llvm.func external declaration
//===----------------------------------------------------------------------===//

struct KernelFuncOpLowering : public OpConversionPattern<func::FuncOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(func::FuncOp funcOp, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        // Only handle kernel functions (marked with is_kernel attribute)
        if (!funcOp->hasAttr("is_kernel"))
            return failure();  // Let the standard func-to-llvm pattern handle it

        auto loc = funcOp.getLoc();
        auto *ctx = rewriter.getContext();

        // Convert function type
        auto funcType = funcOp.getFunctionType();
        SmallVector<Type> argTypes;
        for (Type t : funcType.getInputs()) {
            // !eco.value becomes i64
            if (isa<ValueType>(t))
                argTypes.push_back(IntegerType::get(ctx, 64));
            else
                argTypes.push_back(t);
        }

        SmallVector<Type> resultTypes;
        for (Type t : funcType.getResults()) {
            // !eco.value becomes i64
            if (isa<ValueType>(t))
                resultTypes.push_back(IntegerType::get(ctx, 64));
            else
                resultTypes.push_back(t);
        }

        Type llvmResultType;
        if (resultTypes.empty()) {
            llvmResultType = LLVM::LLVMVoidType::get(ctx);
        } else if (resultTypes.size() == 1) {
            llvmResultType = resultTypes[0];
        } else {
            llvmResultType = LLVM::LLVMStructType::getLiteral(ctx, resultTypes);
        }

        auto llvmFuncType = LLVM::LLVMFunctionType::get(llvmResultType, argTypes);

        // Create an external LLVM function (no body)
        auto llvmFunc = rewriter.create<LLVM::LLVMFuncOp>(
            loc, funcOp.getName(), llvmFuncType);

        // Set external linkage so JIT can resolve the symbol
        llvmFunc.setLinkage(LLVM::Linkage::External);

        // Erase the original func.func
        rewriter.eraseOp(funcOp);
        return success();
    }
};

} // namespace

//===----------------------------------------------------------------------===//
// Pattern Population
//===----------------------------------------------------------------------===//

void eco::detail::populateEcoFuncPatterns(
    EcoTypeConverter &typeConverter,
    RewritePatternSet &patterns) {

    auto *ctx = patterns.getContext();
    // Add with higher benefit to ensure it runs before standard func-to-llvm patterns
    patterns.add<KernelFuncOpLowering>(typeConverter, ctx, /*benefit=*/10);
}
