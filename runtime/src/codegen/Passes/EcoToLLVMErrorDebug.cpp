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
// eco.safepoint -> no-op (erase)
//===----------------------------------------------------------------------===//

struct SafepointOpLowering : public OpConversionPattern<SafepointOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(SafepointOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        // Safepoints are not needed for tracing GC; erase them
        rewriter.eraseOp(op);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.dbg -> call eco_dbg_print variants
//===----------------------------------------------------------------------===//

struct DbgOpLowering : public OpConversionPattern<DbgOp> {
    EcoRuntime runtime;

    DbgOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                  EcoRuntime runtime)
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

                // Store the value
                auto zero = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, 0);
                auto gep = rewriter.create<LLVM::GEPOp>(loc, ptrTy, arrayTy, alloca,
                                                        ValueRange{zero, zero});
                rewriter.create<LLVM::StoreOp>(loc, arg, gep);

                // Call eco_dbg_print
                rewriter.create<LLVM::CallOp>(loc, func, ValueRange{alloca, one});
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
    EcoRuntime runtime;

    CrashOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                    EcoRuntime runtime)
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
    EcoRuntime runtime;

    ExpectOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                     EcoRuntime runtime)
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
    EcoRuntime runtime) {

    auto *ctx = patterns.getContext();
    patterns.add<SafepointOpLowering>(typeConverter, ctx);
    patterns.add<DbgOpLowering>(typeConverter, ctx, runtime);
    patterns.add<CrashOpLowering>(typeConverter, ctx, runtime);
    patterns.add<ExpectOpLowering>(typeConverter, ctx, runtime);
}
