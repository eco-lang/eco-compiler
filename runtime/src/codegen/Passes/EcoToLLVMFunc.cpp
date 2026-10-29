//===- EcoToLLVMFunc.cpp - Function lowering patterns ---------------------===//
//
// The two `func.func` shapes that the standard function conversion would lower
// wrongly, and the shadow root frames declared in `EcoToLLVMInternal.h`.
//
// A kernel function is one the compiler marks `is_kernel`: a declaration of a
// function implemented in C++, which must become an external `llvm.func`
// declaration with `!eco.value` passed as `ptr addrspace(1)`. A non-kernel
// function with two or more results is an sret worker: instead of returning an
// LLVM struct, it takes a leading pointer to a caller-provided slot and returns
// `void`. An LLVM struct return could hold `ptr addrspace(1)` values, which
// RS4GC cannot relocate (REP_AGG_001). Both patterns are added with benefit 10
// so that they are tried before the standard function conversion.
//
//===----------------------------------------------------------------------===//

#include "EcoToLLVMInternal.h"
#include "../EcoDialect.h"
#include "../EcoOps.h"

#include "mlir/Dialect/Func/IR/FuncOps.h"

using namespace mlir;
using namespace eco;
using namespace eco::detail;

namespace {

//===----------------------------------------------------------------------===//
// Kernel func.func -> llvm.func external declaration
//===----------------------------------------------------------------------===//

/**
 * A conversion of a kernel `func.func` into an external `llvm.func`
 * declaration of the same name.
 *
 * `!eco.value` parameters and results become `ptr addrspace(1)`; every other
 * type is kept as it is, without the type converter. No result gives `void`,
 * one gives that type, and several give a literal LLVM struct. The declaration
 * is marked gc-leaf when the function carries `eco.gc_leaf` and
 * `kernelGcLeafEnabled()` is true. If `runtime`'s symbol cache already has an
 * `llvm.func` of the same name, the `func.func` is erased instead, and that
 * function is marked gc-leaf under the same condition; its type is not
 * compared. A new declaration is added to the cache.
 */
struct KernelFuncOpLowering : public OpConversionPattern<func::FuncOp> {
    // The declaration cache that duplicates are looked up in and new
    // declarations added to. It must outlive the pattern.
    const EcoRuntime &runtime;

    // Creates the pattern with `benefit`, keeping a reference to `runtime`.
    KernelFuncOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                         const EcoRuntime &runtime, PatternBenefit benefit)
        : OpConversionPattern(typeConverter, ctx, benefit), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(func::FuncOp funcOp, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        if (!funcOp->hasAttr("is_kernel"))
            return failure();

        // The cache lookup avoids a scan of the module for every declaration.
        if (auto existing =
                runtime.lookupSymbol<LLVM::LLVMFuncOp>(funcOp.getName())) {
            // The stub being erased is what carries `eco.gc_leaf`, so the
            // surviving declaration is marked first.
            if (kernelGcLeafEnabled() && funcOp->hasAttr("eco.gc_leaf"))
                attachGcLeafPassthrough(rewriter, existing);
            rewriter.eraseOp(funcOp);
            return success();
        }

        auto loc = funcOp.getLoc();
        auto *ctx = rewriter.getContext();

        auto funcType = funcOp.getFunctionType();
        auto hptrTy = getHPtrLLVMType(*ctx);
        SmallVector<Type> argTypes;
        for (Type t : funcType.getInputs()) {
            if (isa<ValueType>(t))
                argTypes.push_back(hptrTy);
            else
                argTypes.push_back(t);
        }

        SmallVector<Type> resultTypes;
        for (Type t : funcType.getResults()) {
            if (isa<ValueType>(t))
                resultTypes.push_back(hptrTy);
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

        auto llvmFunc = rewriter.create<LLVM::LLVMFuncOp>(
            loc, funcOp.getName(), llvmFuncType);

        llvmFunc.setLinkage(LLVM::Linkage::External);

        if (kernelGcLeafEnabled() && funcOp->hasAttr("eco.gc_leaf"))
            attachGcLeafPassthrough(rewriter, llvmFunc);

        // Cached so that a later declaration of the same name is erased by
        // the lookup above.
        runtime.cacheSymbol(llvmFunc);

        rewriter.eraseOp(funcOp);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// sret workers: multi-result func.func -> (slot ptr, args...) -> void
//===----------------------------------------------------------------------===//

/**
 * A conversion of a non-kernel `func.func` with two or more results into an
 * `llvm.func` that returns `void` and takes, ahead of its converted
 * parameters, a pointer in address space 0 to the slot its results go to.
 *
 * The body is moved into the new function and its block argument types are
 * converted, the slot becoming a new leading entry-block argument. The
 * results are not written here: the lowerings of `eco.return` and `eco.call`
 * store them into the slot and load them back. Linkage is External for a
 * public function and Internal otherwise. Every attribute except the symbol
 * name, the function type and `sym_visibility` is copied unchanged. The
 * pattern fails if a parameter type does not convert.
 */
struct SretFuncOpLowering : public OpConversionPattern<func::FuncOp> {
    // Creates the pattern with `benefit`.
    SretFuncOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                       PatternBenefit benefit)
        : OpConversionPattern(typeConverter, ctx, benefit) {}

    LogicalResult
    matchAndRewrite(func::FuncOp funcOp, OpAdaptor,
                    ConversionPatternRewriter &rewriter) const override {
        if (funcOp->hasAttr("is_kernel") ||
            funcOp.getFunctionType().getNumResults() < 2)
            return failure();

        auto loc = funcOp.getLoc();
        auto *ctx = rewriter.getContext();
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        auto funcType = funcOp.getFunctionType();
        SmallVector<Type> argTypes{ptrTy};
        TypeConverter::SignatureConversion sig(funcType.getNumInputs());
        sig.addInputs(ptrTy); // The slot: a new argument, mapped from no old one.
        for (auto [i, t] : llvm::enumerate(funcType.getInputs())) {
            Type ct = getTypeConverter()->convertType(t);
            if (!ct)
                return failure();
            argTypes.push_back(ct);
            sig.addInputs(i, ct);
        }

        auto llvmFuncType =
            LLVM::LLVMFunctionType::get(LLVM::LLVMVoidType::get(ctx), argTypes);
        auto llvmFunc =
            rewriter.create<LLVM::LLVMFuncOp>(loc, funcOp.getName(), llvmFuncType);
        llvmFunc.setLinkage(funcOp.isPublic() ? LLVM::Linkage::External
                                              : LLVM::Linkage::Internal);

        for (NamedAttribute attr : funcOp->getAttrs()) {
            StringRef n = attr.getName();
            if (n == funcOp.getSymNameAttrName() ||
                n == funcOp.getFunctionTypeAttrName() ||
                n == "sym_visibility")
                continue;
            llvmFunc->setAttr(n, attr.getValue());
        }

        rewriter.inlineRegionBefore(funcOp.getBody(), llvmFunc.getBody(),
                                    llvmFunc.end());
        if (failed(rewriter.convertRegionTypes(&llvmFunc.getBody(),
                                               *getTypeConverter(), &sig)))
            return failure();

        rewriter.eraseOp(funcOp);
        return success();
    }
};

} // namespace

//===----------------------------------------------------------------------===//
// Shadow Root Frame Implementation
//===----------------------------------------------------------------------===//

ShadowRootFrame eco::detail::installShadowRootPrologue(
    LLVM::LLVMFuncOp func,
    OpBuilder &builder,
    const EcoRuntime &runtime) {

    ShadowRootFrame frame;
    frame.savedPoint = nullptr;
    frame.basePtr = nullptr;

    Block &entryBlock = func.getBody().front();
    SmallVector<BlockArgument> gcArgs;
    for (auto arg : entryBlock.getArguments()) {
        if (isHPtrLLVMType(arg.getType()))
            gcArgs.push_back(arg);
    }

    if (gcArgs.empty())
        return frame;

    int64_t N = static_cast<int64_t>(gcArgs.size());

    auto loc = func.getLoc();
    auto *ctx = builder.getContext();
    auto i8Ty = IntegerType::get(ctx, 8);
    auto i64Ty = IntegerType::get(ctx, 64);
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);

    builder.setInsertionPointToStart(&entryBlock);

    auto countConst = builder.create<LLVM::ConstantOp>(loc, i64Ty, N);
    frame.basePtr = builder.create<LLVM::AllocaOp>(loc, ptrTy, i64Ty, countConst);

    auto zeroVal = builder.create<LLVM::ConstantOp>(loc, i8Ty, 0);
    auto bytesLen = builder.create<LLVM::ConstantOp>(loc, i64Ty, N * 8);
    builder.create<LLVM::MemsetOp>(loc, frame.basePtr, zeroVal, bytesLen,
                                   /*isVolatile=*/false);

    // The root-range restore point, taken before the pushes below.
    auto rangePointFunc = runtime.getOrCreateGcStackRangePoint(builder);
    frame.savedPoint =
        builder.create<LLVM::CallOp>(loc, rangePointFunc, ValueRange{})
            .getResult();

    for (int64_t i = 0; i < N; ++i) {
        auto idx = builder.create<LLVM::ConstantOp>(loc, i64Ty, i);
        auto slot = builder.create<LLVM::GEPOp>(loc, ptrTy, i64Ty,
                                                 frame.basePtr, ValueRange{idx});
        auto hp = builder.create<LLVM::PtrToIntOp>(loc, i64Ty, gcArgs[i]);
        builder.create<LLVM::StoreOp>(loc, hp, slot);
        frame.slotForArg[gcArgs[i]] = slot;
    }

    // Every slot holds an HPointer.
    SmallVector<bool> allBoxed(static_cast<size_t>(N), true);
    emitChunkedRootPush(builder, loc, runtime, frame.basePtr, allBoxed);

    return frame;
}

Value eco::detail::loadValueFromShadowSlot(
    const ShadowRootFrame &frame,
    BlockArgument arg,
    OpBuilder &builder,
    Location loc) {

    auto it = frame.slotForArg.find(arg);
    assert(it != frame.slotForArg.end() && "arg not in shadow root frame");
    Value slot = it->second;

    auto i64Ty = IntegerType::get(builder.getContext(), 64);
    auto hptrTy = LLVM::LLVMPointerType::get(builder.getContext(), /*addressSpace=*/1);

    Value hp = builder.create<LLVM::LoadOp>(loc, i64Ty, slot);
    Value v = builder.create<LLVM::IntToPtrOp>(loc, hptrTy, hp);
    return v;
}

void eco::detail::rewriteUsesViaShadowSlot(
    const ShadowRootFrame &frame,
    BlockArgument arg,
    OpBuilder &builder) {

    // Collected first: setting a use invalidates the use iterator.
    SmallVector<OpOperand*> uses;
    for (auto &use : arg.getUses())
        uses.push_back(&use);

    for (auto *use : uses) {
        Operation *user = use->getOwner();
        // This branch does nothing: a store of `arg` itself is rewritten
        // like any other use.
        if (auto storeOp = dyn_cast<LLVM::StoreOp>(user)) {
            if (storeOp.getValue() == arg) {
            }
        }
        // Meant to keep the prologue's `ptrtoint`, but any single-use
        // `ptrtoint` feeding a store matches; the store's address is not checked.
        if (auto ptiOp = dyn_cast<LLVM::PtrToIntOp>(user)) {
            if (ptiOp.getResult().hasOneUse()) {
                auto &singleUse = *ptiOp.getResult().getUses().begin();
                if (isa<LLVM::StoreOp>(singleUse.getOwner()))
                    continue;
            }
        }

        builder.setInsertionPoint(user);
        Value reloaded = loadValueFromShadowSlot(frame, arg, builder, user->getLoc());
        use->set(reloaded);
    }
}

void eco::detail::emitShadowRootEpilogues(
    const ShadowRootFrame &frame,
    LLVM::LLVMFuncOp func,
    OpBuilder &builder,
    const EcoRuntime &runtime) {

    auto restoreFunc = runtime.getOrCreateGcRestoreStackRangePoint(builder);

    func.walk([&](LLVM::ReturnOp retOp) {
        builder.setInsertionPoint(retOp);
        builder.create<LLVM::CallOp>(retOp.getLoc(), restoreFunc,
                                     ValueRange{frame.savedPoint});
    });
}

//===----------------------------------------------------------------------===//
// Pattern Population
//===----------------------------------------------------------------------===//

void eco::detail::populateEcoFuncPatterns(
    EcoTypeConverter &typeConverter,
    RewritePatternSet &patterns,
    const EcoRuntime &runtime) {

    auto *ctx = patterns.getContext();
    patterns.add<KernelFuncOpLowering>(typeConverter, ctx, runtime, /*benefit=*/10);
    patterns.add<SretFuncOpLowering>(typeConverter, ctx, /*benefit=*/10);
}
