//===- EcoToLLVMErrorDebug.cpp - Error and debug lowering patterns --------===//
//
// This file implements lowering patterns for ECO error handling and debug
// operations: safepoint, dbg, crash, and expect.
//
//===----------------------------------------------------------------------===//

#include "EcoToLLVMInternal.h"
#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../EcoTypes.h"

#include "mlir/Dialect/ControlFlow/IR/ControlFlowOps.h"

using namespace mlir;
using namespace eco;
using namespace eco::detail;

namespace {

//===----------------------------------------------------------------------===//
// eco.safepoint -> gc.statepoint + gc.relocate
//
// Lowers safepoint ops to LLVM statepoint intrinsics for GC root tracking.
// Each live eco.value operand (i64 HPointer) is:
//   1. Cast to ptr addrspace(1) (GC-managed pointer)
//   2. Passed in a "gc-live" operand bundle on the statepoint call
//   3. Relocated via gc.relocate
//   4. Cast back to i64
//   5. All downstream uses of the original value are replaced
//===----------------------------------------------------------------------===//

/// Get or create the __eco_safepoint_poll function declaration.
/// This is the statepoint target: StatepointConversion wraps this call
/// in gc.statepoint with the gc-live bundle from the preceding marker.
static LLVM::LLVMFuncOp getOrCreateSafepointPoll(
    const EcoRuntime &runtime, OpBuilder &builder) {
    auto name = "__eco_safepoint_poll";
    if (auto func = runtime.lookupSymbol<LLVM::LLVMFuncOp>(name))
        return func;

    auto *ctx = builder.getContext();
    auto voidTy = LLVM::LLVMVoidType::get(ctx);
    auto funcTy = LLVM::LLVMFunctionType::get(voidTy, {}, /*isVarArg=*/false);

    OpBuilder::InsertionGuard guard(builder);
    builder.setInsertionPointToStart(runtime.module.getBody());
    auto func = builder.create<LLVM::LLVMFuncOp>(
        runtime.module.getLoc(), name, funcTy);
    runtime.cacheSymbol(func);
    return func;
}

struct SafepointOpLowering : public OpConversionPattern<SafepointOp> {
    const EcoRuntime &runtime;

    SafepointOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                        const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(SafepointOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto liveValues = adaptor.getLiveRoots(); // Already converted to i64

        if (liveValues.empty()) {
            rewriter.eraseOp(op);
            return success();
        }

        auto gcPtrTy = LLVM::LLVMPointerType::get(ctx, /*addressSpace=*/1);

        // Live values are now ptr<1> from the type converter.
        // Pass directly; convert any remaining i64 for backwards compat.
        SmallVector<Value, 4> gcPtrs;
        for (auto val : liveValues) {
            if (isHPtrLLVMType(val.getType())) {
                gcPtrs.push_back(val);
            } else {
                auto ptr = rewriter.create<LLVM::IntToPtrOp>(loc, gcPtrTy, val);
                gcPtrs.push_back(ptr);
            }
        }

        // Emit call to __eco_safepoint_marker with GC root pointers.
        // StatepointConversion pass converts this to gc.statepoint after
        // MLIR→LLVM IR translation.
        runtime.getOrCreateSafepointMarker(rewriter);

        auto voidTy = LLVM::LLVMVoidType::get(ctx);
        auto markerFuncTy = LLVM::LLVMFunctionType::get(
            voidTy, {}, /*isVarArg=*/true);

        rewriter.create<LLVM::CallOp>(
            loc, markerFuncTy,
            FlatSymbolRefAttr::get(ctx, "__eco_safepoint_marker"),
            gcPtrs);

        // Emit call to __eco_safepoint_poll immediately after the marker.
        // This is the statepoint target: StatepointConversion wraps this
        // call in gc.statepoint with the gc-live bundle.
        getOrCreateSafepointPoll(runtime, rewriter);

        auto pollFuncTy = LLVM::LLVMFunctionType::get(
            voidTy, {}, /*isVarArg=*/false);

        rewriter.create<LLVM::CallOp>(
            loc, pollFuncTy,
            FlatSymbolRefAttr::get(ctx, "__eco_safepoint_poll"),
            ValueRange{});

        rewriter.eraseOp(op);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.dbg -> call eco_dbg_print variants
//===----------------------------------------------------------------------===//

struct DbgOpLowering : public OpConversionPattern<DbgOp> {
    const EcoRuntime &runtime;

    DbgOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                  const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(DbgOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();

        auto ptrTy = LLVM::LLVMPointerType::get(ctx);
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i64Ty = IntegerType::get(ctx, 64);

        auto origArgs = op.getArgs();
        auto args = adaptor.getArgs();

        // Check if we have type IDs for typed printing
        auto argTypeIds = op.getArgTypeIds();
        if (argTypeIds && argTypeIds->size() == args.size() && !args.empty()) {
            // Use eco_dbg_print_typed for typed output
            auto func = runtime.getOrCreateDbgPrintTyped(rewriter);
            uint32_t numArgs = args.size();

            // Allocate arrays for values and type_ids
            auto valArrayTy = LLVM::LLVMArrayType::get(i64Ty, numArgs);
            auto typeArrayTy = LLVM::LLVMArrayType::get(i32Ty, numArgs);
            auto one = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, 1);
            auto valuesAlloca = rewriter.create<LLVM::AllocaOp>(loc, ptrTy, valArrayTy, one);
            auto typesAlloca = rewriter.create<LLVM::AllocaOp>(loc, ptrTy, typeArrayTy, one);

            // Fill the arrays
            for (size_t i = 0; i < numArgs; i++) {
                Value arg = args[i];
                int64_t typeId = (*argTypeIds)[i];

                // All eco.dbg operands are !eco.value, which converts to ptr<1>
                // via EcoTypeConverter. Convert to i64 for the debug array.
                Value valAsI64 = valueToI64(rewriter, loc, arg);

                // Store value
                auto idx = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, (int64_t)i);
                auto zero = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, 0);
                auto valGep = rewriter.create<LLVM::GEPOp>(loc, ptrTy, valArrayTy, valuesAlloca,
                                                          ValueRange{zero, idx});
                rewriter.create<LLVM::StoreOp>(loc, valAsI64, valGep);

                // Store type_id
                auto typeIdCst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, (int64_t)typeId);
                auto typeGep = rewriter.create<LLVM::GEPOp>(loc, ptrTy, typeArrayTy, typesAlloca,
                                                           ValueRange{zero, idx});
                rewriter.create<LLVM::StoreOp>(loc, typeIdCst, typeGep);
            }

            // Call eco_dbg_print_typed
            auto numArgsCst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, (int64_t)numArgs);
            rewriter.create<LLVM::CallOp>(loc, func, ValueRange{valuesAlloca, typesAlloca, numArgsCst});
        } else {
            // Fall back to existing behavior without type info
            for (size_t i = 0; i < args.size(); i++) {
                Type origType = origArgs[i].getType();
                Value arg = args[i];

                if (origType.isInteger(64)) {
                    // Unboxed i64 -> eco_dbg_print_int
                    auto func = runtime.getOrCreateDbgPrintInt(rewriter);
                    rewriter.create<LLVM::CallOp>(loc, func, ValueRange{arg});
                } else if (origType.isF64()) {
                    // Unboxed f64 -> eco_dbg_print_float
                    auto func = runtime.getOrCreateDbgPrintFloat(rewriter);
                    rewriter.create<LLVM::CallOp>(loc, func, ValueRange{arg});
                } else if (origType.isInteger(16)) {
                    // Unboxed i16 (char) -> eco_dbg_print_char
                    auto func = runtime.getOrCreateDbgPrintChar(rewriter);
                    rewriter.create<LLVM::CallOp>(loc, func, ValueRange{arg});
                } else {
                    // Boxed value (!eco.value) -> eco_dbg_print with array
                    auto func = runtime.getOrCreateDbgPrint(rewriter);

                    // Allocate single-element array on stack
                    auto arrayTy = LLVM::LLVMArrayType::get(i64Ty, 1);
                    auto one = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, 1);
                    auto alloca = rewriter.create<LLVM::AllocaOp>(loc, ptrTy, arrayTy, one);

                    // Store the value as i64
                    auto zero = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, 0);
                    auto gep = rewriter.create<LLVM::GEPOp>(loc, ptrTy, arrayTy, alloca,
                                                            ValueRange{zero, zero});
                    Value argI64 = valueToI64(rewriter, loc, arg);
                    rewriter.create<LLVM::StoreOp>(loc, argI64, gep);

                    // Call eco_dbg_print
                    rewriter.create<LLVM::CallOp>(loc, func, ValueRange{alloca, one});
                }
            }
        }

        rewriter.eraseOp(op);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.crash -> call eco_crash + unreachable
//===----------------------------------------------------------------------===//

struct CrashOpLowering : public OpConversionPattern<CrashOp> {
    const EcoRuntime &runtime;

    CrashOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                    const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(CrashOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();

        auto func = runtime.getOrCreateCrash(rewriter);

        // Message is already i64 (HPointer format), pass directly
        Value msg = adaptor.getMessage();

        // Call eco_crash (which is [[noreturn]])
        rewriter.create<LLVM::CallOp>(loc, func, ValueRange{msg});

        // Add unreachable since eco_crash never returns
        rewriter.create<LLVM::UnreachableOp>(loc);

        rewriter.eraseOp(op);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.expect -> conditional crash with passthrough
//===----------------------------------------------------------------------===//

struct ExpectOpLowering : public OpConversionPattern<ExpectOp> {
    const EcoRuntime &runtime;

    ExpectOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                     const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(ExpectOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();

        auto func = runtime.getOrCreateCrash(rewriter);

        // Get parent block
        Block *currentBlock = op->getBlock();

        // Split the block at this operation
        Block *continueBlock = rewriter.splitBlock(currentBlock, op->getIterator());
        Block *crashBlock = rewriter.createBlock(continueBlock);

        // In crash block: call eco_crash and unreachable
        rewriter.setInsertionPointToStart(crashBlock);
        Value msg = adaptor.getMessage();
        rewriter.create<LLVM::CallOp>(loc, func, ValueRange{msg});
        rewriter.create<LLVM::UnreachableOp>(loc);

        // In current block: conditional branch
        rewriter.setInsertionPointToEnd(currentBlock);
        rewriter.create<cf::CondBranchOp>(loc, adaptor.getCondition(),
                                          continueBlock, crashBlock);

        // Replace uses of the expect result with the passthrough value
        rewriter.setInsertionPointToStart(continueBlock);
        rewriter.replaceOp(op, adaptor.getPassthrough());

        return success();
    }
};

} // namespace

//===----------------------------------------------------------------------===//
// Pattern Population
//===----------------------------------------------------------------------===//

void eco::detail::populateEcoErrorDebugPatterns(
    EcoTypeConverter &typeConverter,
    RewritePatternSet &patterns,
    const EcoRuntime &runtime) {

    auto *ctx = patterns.getContext();
    patterns.add<SafepointOpLowering>(typeConverter, ctx, runtime);
    patterns.add<DbgOpLowering>(typeConverter, ctx, runtime);
    patterns.add<CrashOpLowering>(typeConverter, ctx, runtime);
    patterns.add<ExpectOpLowering>(typeConverter, ctx, runtime);
}
