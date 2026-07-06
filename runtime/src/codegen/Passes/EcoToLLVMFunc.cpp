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
    const EcoRuntime &runtime;

    KernelFuncOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                         const EcoRuntime &runtime, PatternBenefit benefit)
        : OpConversionPattern(typeConverter, ctx, benefit), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(func::FuncOp funcOp, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        // Only handle kernel functions (marked with is_kernel attribute)
        if (!funcOp->hasAttr("is_kernel"))
            return failure();  // Let the standard func-to-llvm pattern handle it

        // If an LLVM func with this name already exists (e.g., created by
        // string case lowering's getOrCreateUtilsEqual), just erase the stub.
        // Route through EcoRuntime's O(1) symbol cache instead of
        // ModuleOp::lookupSymbol's O(N) module scan per kernel decl.
        if (runtime.lookupSymbol<LLVM::LLVMFuncOp>(funcOp.getName())) {
            rewriter.eraseOp(funcOp);
            return success();
        }

        auto loc = funcOp.getLoc();
        auto *ctx = rewriter.getContext();

        // Convert function type
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

        // Create an external LLVM function (no body)
        auto llvmFunc = rewriter.create<LLVM::LLVMFuncOp>(
            loc, funcOp.getName(), llvmFuncType);

        // Set external linkage so JIT can resolve the symbol
        llvmFunc.setLinkage(LLVM::Linkage::External);

        // Register in the symbol cache so a later duplicate kernel decl with
        // the same name is deduped via the O(1) lookup above.
        runtime.cacheSymbol(llvmFunc);

        // Erase the original func.func
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

    // Collect all entry-block args of type ptr addrspace(1).
    Block &entryBlock = func.getBody().front();
    SmallVector<BlockArgument> gcArgs;
    for (auto arg : entryBlock.getArguments()) {
        if (isHPtrLLVMType(arg.getType()))
            gcArgs.push_back(arg);
    }

    if (gcArgs.empty())
        return frame;

    int64_t N = static_cast<int64_t>(gcArgs.size());
    assert(N <= 64 && "shadow root frame supports at most 64 slots");

    auto loc = func.getLoc();
    auto *ctx = builder.getContext();
    auto i8Ty = IntegerType::get(ctx, 8);
    auto i64Ty = IntegerType::get(ctx, 64);
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);

    // Insert at the start of the entry block.
    builder.setInsertionPointToStart(&entryBlock);

    // Alloca [N x i64]
    auto countConst = builder.create<LLVM::ConstantOp>(loc, i64Ty, N);
    frame.basePtr = builder.create<LLVM::AllocaOp>(loc, ptrTy, i64Ty, countConst);

    // Memset to zero (unregistered slots must be safe for GC).
    auto zeroVal = builder.create<LLVM::ConstantOp>(loc, i8Ty, 0);
    auto bytesLen = builder.create<LLVM::ConstantOp>(loc, i64Ty, N * 8);
    builder.create<LLVM::MemsetOp>(loc, frame.basePtr, zeroVal, bytesLen,
                                   /*isVolatile=*/false);

    // Save current range stack depth.
    auto rangePointFunc = runtime.getOrCreateGcStackRangePoint(builder);
    frame.savedPoint =
        builder.create<LLVM::CallOp>(loc, rangePointFunc, ValueRange{})
            .getResult();

    // Store each GC arg into its slot.
    for (int64_t i = 0; i < N; ++i) {
        auto idx = builder.create<LLVM::ConstantOp>(loc, i64Ty, i);
        auto slot = builder.create<LLVM::GEPOp>(loc, ptrTy, i64Ty,
                                                 frame.basePtr, ValueRange{idx});
        auto hp = builder.create<LLVM::PtrToIntOp>(loc, i64Ty, gcArgs[i]);
        builder.create<LLVM::StoreOp>(loc, hp, slot);
        frame.slotForArg[gcArgs[i]] = slot;
    }

    // Register the range: eco_gc_push_stack_range(basePtr, N, mask)
    uint64_t mask = (N >= 64) ? ~0ULL : ((1ULL << N) - 1);
    auto pushFunc = runtime.getOrCreateGcPushStackRange(builder);
    auto nConst = builder.create<LLVM::ConstantOp>(loc, i64Ty, N);
    auto maskConst = builder.create<LLVM::ConstantOp>(
        loc, i64Ty, static_cast<int64_t>(mask));
    builder.create<LLVM::CallOp>(loc, pushFunc,
                                 ValueRange{frame.basePtr, nConst, maskConst});

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

    // Collect uses before mutating (rewriting invalidates use-iterators).
    SmallVector<OpOperand*> uses;
    for (auto &use : arg.getUses())
        uses.push_back(&use);

    for (auto *use : uses) {
        Operation *user = use->getOwner();
        // Skip the store into the shadow slot itself (part of the prologue).
        if (auto storeOp = dyn_cast<LLVM::StoreOp>(user)) {
            // If this store's value operand is the arg and destination is one
            // of the shadow slots, skip it.
            if (storeOp.getValue() == arg) {
                // Check: is the address one of our shadow slots?
                // The PtrToIntOp that feeds the store is also a user of arg;
                // skip that too below. But for the store, we need to check
                // the addr. Since we can't easily check, skip all stores of
                // the raw arg value (the prologue stores ptrtoint(arg), not arg
                // directly, so this won't match prologue stores).
            }
        }
        // Skip the PtrToIntOp in the prologue that converts arg for storage.
        if (auto ptiOp = dyn_cast<LLVM::PtrToIntOp>(user)) {
            // If this ptrtoint feeds a store into one of our slots, skip it.
            // Heuristic: if the ptrtoint result has exactly one use and that
            // use is a StoreOp, it's a prologue store — skip.
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
    // Add with higher benefit to ensure it runs before standard func-to-llvm patterns
    patterns.add<KernelFuncOpLowering>(typeConverter, ctx, runtime, /*benefit=*/10);
}
