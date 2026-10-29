//===- EcoToLLVMErrorDebug.cpp - Error and debug lowering patterns --------===//
//
// Debug printing and crashes in compiled code must become calls into the
// runtime. This file holds the patterns, part of the eco-to-LLVM dialect
// conversion, that do it for three eco operations:
//
// - `eco.dbg` prints its operands, through `eco_dbg_print_typed` when the op
//   carries one type id per operand (`arg_type_ids`), and otherwise through
//   one `eco_dbg_print*` call per operand chosen by the operand's type.
// - `eco.crash` calls `eco_crash` with its message and ends the block with
//   `llvm.unreachable`.
// - `eco.expect` splits its block: when its condition is false, control goes
//   to a new block that crashes as `eco.crash` does; otherwise it continues
//   with the passthrough value as the op's result.
//
// Every runtime function called here is declared gc-leaf by `EcoRuntime`, so
// RewriteStatepointsForGC makes none of these calls a statepoint, and nothing
// here emits a safepoint marker. That is what lets the `eco.dbg` lowering
// store a heap pointer into a stack array as a bare `ptrtoint` word: no
// collection can move the object before the call has read it.
//
// Because `eco.expect` adds blocks, an op that contains one must allow
// more than one block in its region.
//
//===----------------------------------------------------------------------===//

#include "EcoToLLVMInternal.h"
#include "../EcoDialect.h"
#include "../EcoOps.h"

#include "mlir/Dialect/ControlFlow/IR/ControlFlowOps.h"

using namespace mlir;
using namespace eco;
using namespace eco::detail;

namespace {

//===----------------------------------------------------------------------===//
// eco.dbg -> call eco_dbg_print variants
//===----------------------------------------------------------------------===//

/**
 * The pattern that lowers `eco.dbg` to calls that print its operands.
 *
 * When `arg_type_ids` has one entry per operand and there is at least one
 * operand, it emits a single `eco_dbg_print_typed(values, type_ids, count)`
 * call over two stack arrays: each i64 or ptr(1) operand as an i64 word
 * (other types are stored unconverted), and each type id truncated to i32.
 * Otherwise it emits one call per operand: an i64 operand goes to
 * `eco_dbg_print_int`, an f64 to `eco_dbg_print_float`, an i32 (a Char) to
 * `eco_dbg_print_char`, and any other type to `eco_dbg_print` as a
 * one-element i64 array. The type tested is the operand's type before
 * conversion. An `eco.dbg` with no operands lowers to nothing.
 */
struct DbgOpLowering : public OpConversionPattern<DbgOp> {
    // The runtime declarations the call targets come from. It must outlive
    // the pattern.
    const EcoRuntime &runtime;

    // Creates the pattern; `runtime` is kept by reference.
    DbgOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                  const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    // Replaces `op` with the print calls described on the type. Always
    // succeeds.
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

        auto argTypeIds = op.getArgTypeIds();
        if (argTypeIds && argTypeIds->size() == args.size() && !args.empty()) {
            auto func = runtime.getOrCreateDbgPrintTyped(rewriter);
            uint32_t numArgs = args.size();

            auto valArrayTy = LLVM::LLVMArrayType::get(i64Ty, numArgs);
            auto typeArrayTy = LLVM::LLVMArrayType::get(i32Ty, numArgs);
            auto one = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, 1);
            auto valuesAlloca = rewriter.create<LLVM::AllocaOp>(loc, ptrTy, valArrayTy, one);
            auto typesAlloca = rewriter.create<LLVM::AllocaOp>(loc, ptrTy, typeArrayTy, one);

            for (size_t i = 0; i < numArgs; i++) {
                Value arg = args[i];
                int64_t typeId = (*argTypeIds)[i];

                // `valueToI64` turns a ptr(1) into an i64 and passes an i64
                // through. Nothing checks that an operand is one of those: an
                // operand of another type is stored as it is, into an i64
                // slot.
                Value valAsI64 = valueToI64(rewriter, loc, arg);

                auto idx = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, (int64_t)i);
                auto zero = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, 0);
                auto valGep = rewriter.create<LLVM::GEPOp>(loc, ptrTy, valArrayTy, valuesAlloca,
                                                          ValueRange{zero, idx});
                rewriter.create<LLVM::StoreOp>(loc, valAsI64, valGep);

                auto typeIdCst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, (int64_t)typeId);
                auto typeGep = rewriter.create<LLVM::GEPOp>(loc, ptrTy, typeArrayTy, typesAlloca,
                                                           ValueRange{zero, idx});
                rewriter.create<LLVM::StoreOp>(loc, typeIdCst, typeGep);
            }

            auto numArgsCst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, (int64_t)numArgs);
            rewriter.create<LLVM::CallOp>(loc, func, ValueRange{valuesAlloca, typesAlloca, numArgsCst});
        } else {
            for (size_t i = 0; i < args.size(); i++) {
                Type origType = origArgs[i].getType();
                Value arg = args[i];

                if (origType.isInteger(64)) {
                    auto func = runtime.getOrCreateDbgPrintInt(rewriter);
                    rewriter.create<LLVM::CallOp>(loc, func, ValueRange{arg});
                } else if (origType.isF64()) {
                    auto func = runtime.getOrCreateDbgPrintFloat(rewriter);
                    rewriter.create<LLVM::CallOp>(loc, func, ValueRange{arg});
                } else if (eco::isEcoCharType(origType)) {
                    auto func = runtime.getOrCreateDbgPrintChar(rewriter);
                    rewriter.create<LLVM::CallOp>(loc, func, ValueRange{arg});
                } else {
                    auto func = runtime.getOrCreateDbgPrint(rewriter);

                    auto arrayTy = LLVM::LLVMArrayType::get(i64Ty, 1);
                    auto one = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, 1);
                    auto alloca = rewriter.create<LLVM::AllocaOp>(loc, ptrTy, arrayTy, one);

                    auto zero = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, 0);
                    auto gep = rewriter.create<LLVM::GEPOp>(loc, ptrTy, arrayTy, alloca,
                                                            ValueRange{zero, zero});
                    Value argI64 = valueToI64(rewriter, loc, arg);
                    rewriter.create<LLVM::StoreOp>(loc, argI64, gep);

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

/**
 * The pattern that lowers `eco.crash` to a call to `eco_crash` with the
 * message, followed by `llvm.unreachable`.
 */
struct CrashOpLowering : public OpConversionPattern<CrashOp> {
    // The runtime declarations `eco_crash` comes from. It must outlive the
    // pattern.
    const EcoRuntime &runtime;

    // Creates the pattern; `runtime` is kept by reference.
    CrashOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                    const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    // Replaces `op` with the call and the `llvm.unreachable`. Always
    // succeeds.
    LogicalResult
    matchAndRewrite(CrashOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();

        auto func = runtime.getOrCreateCrash(rewriter);

        // The converted message is a ptr(1), which is the type `eco_crash`
        // is declared to take.
        Value msg = adaptor.getMessage();

        rewriter.create<LLVM::CallOp>(loc, func, ValueRange{msg});

        // `eco.crash` is a terminator, so the block needs one in its place.
        rewriter.create<LLVM::UnreachableOp>(loc);

        rewriter.eraseOp(op);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.expect -> conditional crash with passthrough
//===----------------------------------------------------------------------===//

/**
 * The pattern that lowers `eco.expect` to a conditional branch to a crash.
 *
 * The op's block is split at the op. The first half ends in a branch on the
 * condition: true goes on to the second half, false to a new block that
 * calls `eco_crash` with the message and ends in `llvm.unreachable`. The
 * op's result is replaced by the passthrough value.
 */
struct ExpectOpLowering : public OpConversionPattern<ExpectOp> {
    // The runtime declarations `eco_crash` comes from. It must outlive the
    // pattern.
    const EcoRuntime &runtime;

    // Creates the pattern; `runtime` is kept by reference.
    ExpectOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                     const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    // Replaces `op` with the branch and crash block described on the type.
    // Always succeeds.
    LogicalResult
    matchAndRewrite(ExpectOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();

        auto func = runtime.getOrCreateCrash(rewriter);

        Block *currentBlock = op->getBlock();

        Block *continueBlock = rewriter.splitBlock(currentBlock, op->getIterator());
        Block *crashBlock = rewriter.createBlock(continueBlock);

        rewriter.setInsertionPointToStart(crashBlock);
        Value msg = adaptor.getMessage();
        rewriter.create<LLVM::CallOp>(loc, func, ValueRange{msg});
        rewriter.create<LLVM::UnreachableOp>(loc);

        rewriter.setInsertionPointToEnd(currentBlock);
        rewriter.create<cf::CondBranchOp>(loc, adaptor.getCondition(),
                                          continueBlock, crashBlock);

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
    patterns.add<DbgOpLowering>(typeConverter, ctx, runtime);
    patterns.add<CrashOpLowering>(typeConverter, ctx, runtime);
    patterns.add<ExpectOpLowering>(typeConverter, ctx, runtime);
}
