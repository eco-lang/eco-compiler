//===- EcoToLLVMGlobals.cpp - Global variable lowering patterns -----------===//
//
// This file implements lowering patterns for ECO global variable operations:
// global, load_global, store_global, and the global root initialization function.
//
//===----------------------------------------------------------------------===//

#include "EcoToLLVMInternal.h"
#include "../EcoDialect.h"
#include "../EcoOps.h"

using namespace mlir;
using namespace eco;
using namespace eco::detail;

namespace {

//===----------------------------------------------------------------------===//
// eco.global -> LLVM global variable declaration
//===----------------------------------------------------------------------===//

struct GlobalOpLowering : public OpConversionPattern<GlobalOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(GlobalOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);

        // eco.value becomes i64 (tagged pointer)
        // Create an LLVM global initialized to 0 (null)
        auto zeroAttr = rewriter.getI64IntegerAttr(0);

        rewriter.replaceOpWithNewOp<LLVM::GlobalOp>(
            op,
            i64Ty,
            /*isConstant=*/false,
            LLVM::Linkage::Internal,
            op.getSymName(),
            zeroAttr);

        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.load_global -> LLVM load from global address
//===----------------------------------------------------------------------===//

struct LoadGlobalOpLowering : public OpConversionPattern<LoadGlobalOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(LoadGlobalOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        // Get address of global
        auto globalAddr = rewriter.create<LLVM::AddressOfOp>(
            loc, ptrTy, op.getGlobal());

        // Load the value (i64 tagged pointer)
        auto loadedValue = rewriter.create<LLVM::LoadOp>(loc, i64Ty, globalAddr);

        rewriter.replaceOp(op, loadedValue.getResult());
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.store_global -> LLVM store to global address
//===----------------------------------------------------------------------===//

struct StoreGlobalOpLowering : public OpConversionPattern<StoreGlobalOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(StoreGlobalOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        // Get address of global
        auto globalAddr = rewriter.create<LLVM::AddressOfOp>(
            loc, ptrTy, op.getGlobal());

        // Store the value (already converted to i64)
        rewriter.create<LLVM::StoreOp>(loc, adaptor.getValue(), globalAddr);

        rewriter.eraseOp(op);
        return success();
    }
};

} // namespace

//===----------------------------------------------------------------------===//
// Pattern Population
//===----------------------------------------------------------------------===//

void eco::detail::populateEcoGlobalPatterns(
    EcoTypeConverter &typeConverter,
    RewritePatternSet &patterns) {

    auto *ctx = patterns.getContext();
    patterns.add<GlobalOpLowering>(typeConverter, ctx);
    patterns.add<LoadGlobalOpLowering>(typeConverter, ctx);
    patterns.add<StoreGlobalOpLowering>(typeConverter, ctx);
}

//===----------------------------------------------------------------------===//
// Global Root Initialization Function
//===----------------------------------------------------------------------===//

void eco::detail::createGlobalRootInitFunction(
    ModuleOp module,
    EcoRuntime &runtime) {

    // Collect all internal LLVM globals (these came from eco.global)
    SmallVector<LLVM::GlobalOp> ecoGlobals;
    module.walk([&](LLVM::GlobalOp globalOp) {
        // eco.global creates internal linkage globals with i64 type
        if (globalOp.getLinkage() == LLVM::Linkage::Internal &&
            globalOp.getGlobalType().isInteger(64)) {
            ecoGlobals.push_back(globalOp);
        }
    });

    // Skip if there's nothing to initialize
    if (ecoGlobals.empty())
        return;

    auto *ctx = runtime.ctx;
    auto loc = module.getLoc();
    OpBuilder builder(ctx);
    builder.setInsertionPointToEnd(module.getBody());

    auto ptrTy = LLVM::LLVMPointerType::get(ctx);
    auto voidTy = LLVM::LLVMVoidType::get(ctx);

    // Get or create the eco_gc_add_root function declaration
    auto addRootFunc = runtime.getOrCreateGcAddRoot(builder);

    // Create the __eco_init_globals function
    // Use External linkage so the JIT can look it up by name
    auto initFuncType = LLVM::LLVMFunctionType::get(voidTy, {});
    auto initFunc = builder.create<LLVM::LLVMFuncOp>(
        loc, "__eco_init_globals", initFuncType);
    initFunc.setLinkage(LLVM::Linkage::External);

    // Create the function body
    Block *entryBlock = initFunc.addEntryBlock(builder);
    builder.setInsertionPointToStart(entryBlock);

    // Call eco_gc_add_root for each global
    for (auto globalOp : ecoGlobals) {
        auto globalAddr = builder.create<LLVM::AddressOfOp>(
            loc, ptrTy, globalOp.getSymName());
        builder.create<LLVM::CallOp>(loc, addRootFunc, ValueRange{globalAddr});
    }

    builder.create<LLVM::ReturnOp>(loc, ValueRange{});
}
