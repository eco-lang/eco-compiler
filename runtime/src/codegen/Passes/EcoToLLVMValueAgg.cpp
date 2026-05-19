//===- EcoToLLVMValueAgg.cpp - Value-aggregate lowering patterns ----------===//
//
// Phase 0 escape-analysis plumbing. This file implements LLVM lowering for
// the value-level aggregate ops added in Ops.td:
//
//   - eco.make.tuple2 / tuple3            (Pure; insertvalue chains)
//   - eco.make.record / custom            (Pure; insertvalue chains)
//   - eco.make.cons                       (Pure; insertvalue chain)
//   - eco.make.closure_env                (Pure; insertvalue chain)
//
//   - eco.to_heap                         (data-aggregate -> !eco.value)
//                                         dispatches per aggregate kind to
//                                         the existing eco_alloc_* runtime
//                                         helpers, mirroring the heap layout
//                                         produced by eco.construct.* ops.
//
//   - eco.make.closure                    (!eco.closure_env + function/arity
//                                         -> !eco.value)
//                                         the only `make.*` that allocates
//                                         and returns !eco.value (Q-A-b).
//
// In addition, a small parallel ProjectClosureOp pattern with higher
// benefit handles operands of type !eco.closure_env (lowered to
// LLVMStructType). For !eco.value operands it returns failure() so the
// existing heap-side pattern in EcoToLLVMClosures.cpp takes over.
// The heavy closure dispatch file is intentionally untouched in Phase 0.
//
//===----------------------------------------------------------------------===//

#include "EcoToLLVMInternal.h"
#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../EcoTypes.h"

using namespace mlir;
using namespace eco;
using namespace eco::detail;

namespace {

//===----------------------------------------------------------------------===//
// Helpers
//===----------------------------------------------------------------------===//

/// Build an LLVM struct value by chaining undef + insertvalue per field.
static Value buildStruct(ConversionPatternRewriter &rewriter, Location loc,
                         Type structTy, ValueRange elements) {
    Value agg = rewriter.create<LLVM::UndefOp>(loc, structTy);
    for (auto [i, e] : llvm::enumerate(elements)) {
        agg = rewriter.create<LLVM::InsertValueOp>(
            loc, agg, e, ArrayRef<int64_t>{static_cast<int64_t>(i)});
    }
    return agg;
}

/// Widen an SSA field value to i64 for runtime Unboxable slots, mirroring
/// EcoToLLVMHeap.cpp::widenFieldToI64. This file does not include that
/// translation unit so we provide an inline copy.
static Value widenFieldToI64Local(Value val, Location loc,
                                  ConversionPatternRewriter &rewriter) {
    auto i64Ty = IntegerType::get(rewriter.getContext(), 64);
    Type ty = val.getType();
    if (isHPtrLLVMType(ty))
        return heapStoreValueToI64(rewriter, loc, val);
    if (auto intTy = dyn_cast<IntegerType>(ty)) {
        if (intTy.getWidth() < 64)
            return rewriter.create<LLVM::ZExtOp>(loc, i64Ty, val);
    } else if (ty.isF64()) {
        return rewriter.create<LLVM::BitcastOp>(loc, i64Ty, val);
    }
    return val;
}

/// Compute the 2-bit per-slot kind bitmap for a sequence of element types.
/// Matches the encoding used by eco.construct.* heap ops: 00 = boxed
/// HPointer, 01 = Int (i64), 10 = Float (f64), 11 = Char (i16).
static int64_t kindBitmapFor(ArrayRef<Type> elements) {
    int64_t bits = 0;
    for (auto [i, t] : llvm::enumerate(elements)) {
        int64_t kind = 0;
        if (t.isInteger(64)) kind = 1;
        else if (t.isF64())  kind = 2;
        else if (t.isInteger(16)) kind = 3;
        bits |= (kind & 0x3LL) << (2LL * static_cast<int64_t>(i));
    }
    return bits;
}

/// Extract field i from a converted aggregate struct as an LLVM Value.
static Value extractField(ConversionPatternRewriter &rewriter, Location loc,
                          Value agg, int64_t index, Type fieldTy) {
    return rewriter.create<LLVM::ExtractValueOp>(
        loc, fieldTy, agg, ArrayRef<int64_t>{index});
}

//===----------------------------------------------------------------------===//
// eco.make.tuple2 -> insertvalue chain
//===----------------------------------------------------------------------===//

struct Tuple2MakeOpLowering : public OpConversionPattern<Tuple2MakeOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(Tuple2MakeOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        Type structTy = getTypeConverter()->convertType(op.getResult().getType());
        if (!structTy) return failure();
        Value result = buildStruct(rewriter, op.getLoc(), structTy,
                                   {adaptor.getA(), adaptor.getB()});
        rewriter.replaceOp(op, result);
        return success();
    }
};

struct Tuple3MakeOpLowering : public OpConversionPattern<Tuple3MakeOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(Tuple3MakeOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        Type structTy = getTypeConverter()->convertType(op.getResult().getType());
        if (!structTy) return failure();
        Value result = buildStruct(rewriter, op.getLoc(), structTy,
                                   {adaptor.getA(), adaptor.getB(), adaptor.getC()});
        rewriter.replaceOp(op, result);
        return success();
    }
};

struct RecordMakeOpLowering : public OpConversionPattern<RecordMakeOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(RecordMakeOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        Type structTy = getTypeConverter()->convertType(op.getResult().getType());
        if (!structTy) return failure();
        Value result = buildStruct(rewriter, op.getLoc(), structTy,
                                   adaptor.getFields());
        rewriter.replaceOp(op, result);
        return success();
    }
};

struct CustomMakeOpLowering : public OpConversionPattern<CustomMakeOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(CustomMakeOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        Type structTy = getTypeConverter()->convertType(op.getResult().getType());
        if (!structTy) return failure();
        Value result = buildStruct(rewriter, op.getLoc(), structTy,
                                   adaptor.getFields());
        rewriter.replaceOp(op, result);
        return success();
    }
};

struct ConsMakeOpLowering : public OpConversionPattern<ConsMakeOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ConsMakeOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        Type structTy = getTypeConverter()->convertType(op.getResult().getType());
        if (!structTy) return failure();
        Value result = buildStruct(rewriter, op.getLoc(), structTy,
                                   {adaptor.getHead(), adaptor.getTail()});
        rewriter.replaceOp(op, result);
        return success();
    }
};

struct ClosureEnvMakeOpLowering : public OpConversionPattern<ClosureEnvMakeOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ClosureEnvMakeOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        Type structTy = getTypeConverter()->convertType(op.getResult().getType());
        if (!structTy) return failure();
        Value result = buildStruct(rewriter, op.getLoc(), structTy,
                                   adaptor.getCaptures());
        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.to_heap -> dispatch per aggregate kind to existing eco_alloc_*.
//
// Layout produced here is identical to what the corresponding heap
// `eco.construct.*` op (Tuple2/3/Record/Custom) or `eco.construct.list`
// op produces, so downstream readers see no difference.
//===----------------------------------------------------------------------===//

struct ToHeapOpLowering : public OpConversionPattern<ToHeapOp> {
    const EcoRuntime &runtime;

    ToHeapOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                     const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(ToHeapOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i64Ty = IntegerType::get(ctx, 64);

        Type srcTy = op.getValue().getType();
        Value agg = adaptor.getValue();
        ValueRange liveRoots = adaptor.getLiveRoots();

        // -------- Tuple2 ---------------------------------------------------
        if (auto tup2 = dyn_cast<eco::Tuple2Type>(srcTy)) {
            Type elts[2] = { tup2.getFirst(), tup2.getSecond() };
            Type llvmElts[2] = {
                getTypeConverter()->convertType(elts[0]),
                getTypeConverter()->convertType(elts[1])
            };
            Value a = extractField(rewriter, loc, agg, 0, llvmElts[0]);
            Value b = extractField(rewriter, loc, agg, 1, llvmElts[1]);
            a = widenFieldToI64Local(a, loc, rewriter);
            b = widenFieldToI64Local(b, loc, rewriter);
            int64_t mask = op.getUnboxedBitmap();
            if (mask == 0) mask = kindBitmapFor(elts);
            auto unboxedVal = rewriter.create<LLVM::ConstantOp>(
                loc, i32Ty, static_cast<int32_t>(mask));
            Value result = emitAllocWithSafepoint(
                op, rewriter, runtime,
                runtime.getOrCreateAllocTuple2(rewriter),
                ValueRange{a, b, unboxedVal},
                liveRoots);
            rewriter.replaceOp(op, result);
            return success();
        }

        // -------- Tuple3 ---------------------------------------------------
        if (auto tup3 = dyn_cast<eco::Tuple3Type>(srcTy)) {
            Type elts[3] = { tup3.getFirst(), tup3.getSecond(), tup3.getThird() };
            Type llvmElts[3] = {
                getTypeConverter()->convertType(elts[0]),
                getTypeConverter()->convertType(elts[1]),
                getTypeConverter()->convertType(elts[2])
            };
            Value a = extractField(rewriter, loc, agg, 0, llvmElts[0]);
            Value b = extractField(rewriter, loc, agg, 1, llvmElts[1]);
            Value c = extractField(rewriter, loc, agg, 2, llvmElts[2]);
            a = widenFieldToI64Local(a, loc, rewriter);
            b = widenFieldToI64Local(b, loc, rewriter);
            c = widenFieldToI64Local(c, loc, rewriter);
            int64_t mask = op.getUnboxedBitmap();
            if (mask == 0) mask = kindBitmapFor(elts);
            auto unboxedVal = rewriter.create<LLVM::ConstantOp>(
                loc, i32Ty, static_cast<int32_t>(mask));
            Value result = emitAllocWithSafepoint(
                op, rewriter, runtime,
                runtime.getOrCreateAllocTuple3(rewriter),
                ValueRange{a, b, c, unboxedVal},
                liveRoots);
            rewriter.replaceOp(op, result);
            return success();
        }

        // -------- Record ---------------------------------------------------
        if (auto rec = dyn_cast<eco::RecordType>(srcTy)) {
            ArrayRef<Type> fields = rec.getFields();
            int64_t fieldCount = static_cast<int64_t>(fields.size());
            int64_t mask = op.getUnboxedBitmap();
            if (mask == 0) mask = kindBitmapFor(fields);

            auto fieldCountVal = rewriter.create<LLVM::ConstantOp>(
                loc, i32Ty, static_cast<int32_t>(fieldCount));
            auto unboxedBitmapVal = rewriter.create<LLVM::ConstantOp>(
                loc, i64Ty, mask);

            Value objHPtr = emitAllocWithSafepoint(
                op, rewriter, runtime,
                runtime.getOrCreateAllocRecord(rewriter),
                ValueRange{fieldCountVal, unboxedBitmapVal},
                liveRoots);

            auto storeFunc    = runtime.getOrCreateStoreRecordField(rewriter);
            auto storeI64Func = runtime.getOrCreateStoreRecordFieldI64(rewriter);
            auto storeF64Func = runtime.getOrCreateStoreRecordFieldF64(rewriter);

            for (int64_t i = 0; i < fieldCount; ++i) {
                Type llvmElt = getTypeConverter()->convertType(fields[i]);
                Value fieldVal = extractField(rewriter, loc, agg, i, llvmElt);
                Type origTy = fields[i];
                auto idx = rewriter.create<LLVM::ConstantOp>(
                    loc, i32Ty, static_cast<int32_t>(i));
                if (origTy.isF64()) {
                    rewriter.create<LLVM::CallOp>(loc, storeF64Func,
                        ValueRange{objHPtr, idx, fieldVal});
                } else if (origTy.isInteger(64)) {
                    rewriter.create<LLVM::CallOp>(loc, storeI64Func,
                        ValueRange{objHPtr, idx, fieldVal});
                } else if (origTy.isInteger(1) || origTy.isInteger(16)) {
                    Value widened = widenFieldToI64Local(fieldVal, loc, rewriter);
                    rewriter.create<LLVM::CallOp>(loc, storeI64Func,
                        ValueRange{objHPtr, idx, widened});
                } else {
                    rewriter.create<LLVM::CallOp>(loc, storeFunc,
                        ValueRange{objHPtr, idx, fieldVal});
                }
            }
            rewriter.replaceOp(op, objHPtr);
            return success();
        }

        // -------- Custom ---------------------------------------------------
        if (auto cus = dyn_cast<eco::CustomType>(srcTy)) {
            ArrayRef<Type> fields = cus.getFields();
            int64_t fieldCount = static_cast<int64_t>(fields.size());
            int64_t mask = op.getUnboxedBitmap();
            if (mask == 0) mask = kindBitmapFor(fields);

            auto tagVal = rewriter.create<LLVM::ConstantOp>(
                loc, i32Ty, static_cast<int32_t>(op.getTag()));
            auto sizeVal = rewriter.create<LLVM::ConstantOp>(
                loc, i32Ty, static_cast<int32_t>(fieldCount));
            auto scalarBytes = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, 0);

            Value objHPtr = emitAllocWithSafepoint(
                op, rewriter, runtime,
                runtime.getOrCreateAllocCustom(rewriter),
                ValueRange{tagVal, sizeVal, scalarBytes},
                liveRoots);

            auto storeFunc    = runtime.getOrCreateStoreField(rewriter);
            auto storeI64Func = runtime.getOrCreateStoreFieldI64(rewriter);
            auto storeF64Func = runtime.getOrCreateStoreFieldF64(rewriter);
            auto setUnboxed   = runtime.getOrCreateSetUnboxed(rewriter);

            for (int64_t i = 0; i < fieldCount; ++i) {
                Type llvmElt = getTypeConverter()->convertType(fields[i]);
                Value fieldVal = extractField(rewriter, loc, agg, i, llvmElt);
                Type origTy = fields[i];
                auto idx = rewriter.create<LLVM::ConstantOp>(
                    loc, i32Ty, static_cast<int32_t>(i));
                if (origTy.isF64()) {
                    rewriter.create<LLVM::CallOp>(loc, storeF64Func,
                        ValueRange{objHPtr, idx, fieldVal});
                } else if (origTy.isInteger(64)) {
                    rewriter.create<LLVM::CallOp>(loc, storeI64Func,
                        ValueRange{objHPtr, idx, fieldVal});
                } else if (origTy.isInteger(1) || origTy.isInteger(16)) {
                    Value widened = widenFieldToI64Local(fieldVal, loc, rewriter);
                    rewriter.create<LLVM::CallOp>(loc, storeI64Func,
                        ValueRange{objHPtr, idx, widened});
                } else {
                    rewriter.create<LLVM::CallOp>(loc, storeFunc,
                        ValueRange{objHPtr, idx, fieldVal});
                }
            }
            if (mask != 0) {
                auto bitmapVal = rewriter.create<LLVM::ConstantOp>(
                    loc, i64Ty, mask);
                rewriter.create<LLVM::CallOp>(loc, setUnboxed,
                    ValueRange{objHPtr, bitmapVal});
            }
            rewriter.replaceOp(op, objHPtr);
            return success();
        }

        // -------- Cons -----------------------------------------------------
        if (auto cons = dyn_cast<eco::ConsType>(srcTy)) {
            Type llvmHead = getTypeConverter()->convertType(cons.getHead());
            Type llvmTail = getTypeConverter()->convertType(cons.getTail());
            Value head = extractField(rewriter, loc, agg, 0, llvmHead);
            Value tail = extractField(rewriter, loc, agg, 1, llvmTail);

            // Prefer op's head_kind attr over a type-derived kind.
            uint32_t kind = static_cast<uint32_t>(op.getHeadKind()) & 0x3;
            if (kind == 0 && op.getHeadUnboxed()) {
                Type ht = cons.getHead();
                if (ht.isInteger(64)) kind = 1;
                else if (ht.isF64())  kind = 2;
                else if (ht.isInteger(16)) kind = 3;
            }
            // If neither attr nor type implies unboxed, leave kind=0 (boxed).
            if (kind == 0 && !isa<eco::ValueType>(cons.getHead())) {
                Type ht = cons.getHead();
                if (ht.isInteger(64)) kind = 1;
                else if (ht.isF64())  kind = 2;
                else if (ht.isInteger(16)) kind = 3;
            }

            // eco_alloc_cons expects head as i64; widen.
            head = widenFieldToI64Local(head, loc, rewriter);
            auto kindVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
                static_cast<int32_t>(kind));

            Value result = emitAllocWithSafepoint(
                op, rewriter, runtime,
                runtime.getOrCreateAllocCons(rewriter),
                ValueRange{head, tail, kindVal},
                liveRoots);
            rewriter.replaceOp(op, result);
            return success();
        }

        return rewriter.notifyMatchFailure(op,
            "eco.to_heap: unsupported aggregate kind (closure_env was rejected by verifier; "
            "every other aggregate is handled above)");
    }
};

//===----------------------------------------------------------------------===//
// eco.from_heap -> resolve HPtr + per-field load + insertvalue chain.
//
// Mirror of eco.to_heap. Reads from the heap layout produced by
// eco.construct.* / eco.to_heap and packs into the value-aggregate
// struct expected by eco.make.* consumers (and by SROA-friendly
// downstream code).
//===----------------------------------------------------------------------===//

struct FromHeapOpLowering : public OpConversionPattern<FromHeapOp> {
    const EcoRuntime &runtime;

    FromHeapOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                       const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    /// Load one field at `offsetBytes` from the resolved heap pointer
    /// `ptr`. `slotBaseTy` selects how the slot is interpreted: if the
    /// destination element type is HPointer-shaped, load i64 then convert;
    /// otherwise load directly at the destination width (i64 / f64 / i16
    /// reinterpreted from the i64-wide slot).
    Value loadFieldAt(ConversionPatternRewriter &rewriter, Location loc,
                      Value ptr, int64_t offsetBytes, Type elemTy) const {
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i8Ty = IntegerType::get(ctx, 8);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, offsetBytes);
        auto fieldPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr,
                                                     ValueRange{offset});
        if (isHPtrLLVMType(elemTy)) {
            Value loaded = rewriter.create<LLVM::LoadOp>(loc, i64Ty, fieldPtr);
            return heapLoadI64ToValue(rewriter, loc, loaded);
        }
        // Heap stores the field in a 64-bit slot; load i64, then narrow /
        // bitcast to the SSA element type.
        Value slot = rewriter.create<LLVM::LoadOp>(loc, i64Ty, fieldPtr);
        if (elemTy.isInteger(64)) return slot;
        if (elemTy.isF64())
            return rewriter.create<LLVM::BitcastOp>(loc, elemTy, slot);
        if (auto intTy = dyn_cast<IntegerType>(elemTy)) {
            if (intTy.getWidth() < 64)
                return rewriter.create<LLVM::TruncOp>(loc, elemTy, slot);
        }
        // Fallback: direct load at the requested type. This path covers
        // unforeseen primitive widths; existing dialect element types are
        // restricted to the cases above.
        return rewriter.create<LLVM::LoadOp>(loc, elemTy, fieldPtr);
    }

    LogicalResult
    matchAndRewrite(FromHeapOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type resTy = op.getResult().getType();
        Type structTy = getTypeConverter()->convertType(resTy);
        if (!structTy) return failure();

        // Resolve HPointer to a raw pointer, then GEP per field.
        auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
        auto resolveCall = rewriter.create<LLVM::CallOp>(
            loc, resolveFunc, ValueRange{adaptor.getValue()});
        Value ptr = resolveCall.getResult();

        SmallVector<Value, 8> fields;

        if (auto tup2 = dyn_cast<eco::Tuple2Type>(resTy)) {
            Type a = getTypeConverter()->convertType(tup2.getFirst());
            Type b = getTypeConverter()->convertType(tup2.getSecond());
            fields.push_back(loadFieldAt(rewriter, loc, ptr,
                layout::Tuple2FirstOffset + 0 * layout::PtrSize, a));
            fields.push_back(loadFieldAt(rewriter, loc, ptr,
                layout::Tuple2FirstOffset + 1 * layout::PtrSize, b));
        } else if (auto tup3 = dyn_cast<eco::Tuple3Type>(resTy)) {
            Type a = getTypeConverter()->convertType(tup3.getFirst());
            Type b = getTypeConverter()->convertType(tup3.getSecond());
            Type c = getTypeConverter()->convertType(tup3.getThird());
            fields.push_back(loadFieldAt(rewriter, loc, ptr,
                layout::Tuple3FirstOffset + 0 * layout::PtrSize, a));
            fields.push_back(loadFieldAt(rewriter, loc, ptr,
                layout::Tuple3FirstOffset + 1 * layout::PtrSize, b));
            fields.push_back(loadFieldAt(rewriter, loc, ptr,
                layout::Tuple3FirstOffset + 2 * layout::PtrSize, c));
        } else if (auto rec = dyn_cast<eco::RecordType>(resTy)) {
            ArrayRef<Type> elts = rec.getFields();
            for (int64_t i = 0; i < static_cast<int64_t>(elts.size()); ++i) {
                Type llvmElt = getTypeConverter()->convertType(elts[i]);
                fields.push_back(loadFieldAt(rewriter, loc, ptr,
                    layout::RecordFieldsOffset + i * layout::PtrSize, llvmElt));
            }
        } else if (auto cus = dyn_cast<eco::CustomType>(resTy)) {
            ArrayRef<Type> elts = cus.getFields();
            for (int64_t i = 0; i < static_cast<int64_t>(elts.size()); ++i) {
                Type llvmElt = getTypeConverter()->convertType(elts[i]);
                fields.push_back(loadFieldAt(rewriter, loc, ptr,
                    layout::CustomFieldsOffset + i * layout::PtrSize, llvmElt));
            }
        } else if (auto cons = dyn_cast<eco::ConsType>(resTy)) {
            Type llvmHead = getTypeConverter()->convertType(cons.getHead());
            Type llvmTail = getTypeConverter()->convertType(cons.getTail());
            fields.push_back(loadFieldAt(rewriter, loc, ptr,
                layout::ConsHeadOffset, llvmHead));
            fields.push_back(loadFieldAt(rewriter, loc, ptr,
                layout::ConsTailOffset, llvmTail));
        } else {
            return rewriter.notifyMatchFailure(op,
                "eco.from_heap: unsupported aggregate kind (closure_env "
                "was rejected by verifier)");
        }

        Value result = buildStruct(rewriter, loc, structTy, fields);
        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.make.closure -> eco_alloc_closure + capture stores.
//
// Mirrors AllocateClosureOp + papCreate's capture-store sequence (without
// going through getOrCreateWrapper). The function symbol must already use
// the closure's expected calling convention.
//===----------------------------------------------------------------------===//

struct MakeClosureOpLowering : public OpConversionPattern<MakeClosureOp> {
    const EcoRuntime &runtime;

    MakeClosureOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                          const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(MakeClosureOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i8Ty = IntegerType::get(ctx, 8);
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i64Ty = IntegerType::get(ctx, 64);
        auto f64Ty = Float64Type::get(ctx);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        auto envTy = cast<eco::ClosureEnvType>(op.getEnv().getType());
        ArrayRef<Type> captures = envTy.getCaptures();
        int64_t numCaptured = static_cast<int64_t>(captures.size());
        int64_t arity = op.getArity();
        int64_t unboxedBitmap = kindBitmapFor(captures);

        Value envAgg = adaptor.getEnv();

        // Resolve the function symbol and allocate a closure of size `arity`.
        Value funcPtr = rewriter.create<LLVM::AddressOfOp>(loc, ptrTy, op.getFunction());
        auto arityConst = rewriter.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(arity));
        Value closureHPtr = emitAllocWithSafepoint(
            op, rewriter, runtime,
            runtime.getOrCreateAllocClosure(rewriter),
            ValueRange{funcPtr, arityConst},
            adaptor.getLiveRoots());

        // Resolve to raw pointer for in-place stores.
        auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
        auto resolveCall = rewriter.create<LLVM::CallOp>(
            loc, resolveFunc, ValueRange{closureHPtr});
        Value closurePtr = resolveCall.getResult();

        // Store the packed header field at offset 8:
        //   n_values:6 | max_values:6 | unboxed:52
        // mirroring papCreate's encoding.
        uint64_t packed = static_cast<uint64_t>(numCaptured)
                        | (static_cast<uint64_t>(arity) << 6)
                        | (static_cast<uint64_t>(unboxedBitmap) << 12);
        auto packedConst = rewriter.create<LLVM::ConstantOp>(
            loc, i64Ty, rewriter.getI64IntegerAttr(static_cast<int64_t>(packed)));
        auto offset8 = rewriter.create<LLVM::ConstantOp>(
            loc, i64Ty, rewriter.getI64IntegerAttr(layout::ClosurePackedOffset));
        auto packedPtr = rewriter.create<LLVM::GEPOp>(
            loc, ptrTy, i8Ty, closurePtr, ValueRange{offset8});
        rewriter.create<LLVM::StoreOp>(loc, packedConst, packedPtr);

        // Store captures into values[].
        for (int64_t i = 0; i < numCaptured; ++i) {
            Type llvmElt = getTypeConverter()->convertType(captures[i]);
            Value cap = extractField(rewriter, loc, envAgg, i, llvmElt);

            // Convert to i64 for the closure values[] slot.
            if (auto intTy = dyn_cast<IntegerType>(cap.getType());
                intTy && intTy.getWidth() < 64) {
                cap = rewriter.create<LLVM::ZExtOp>(loc, i64Ty, cap);
            } else if (cap.getType() == f64Ty) {
                cap = rewriter.create<LLVM::BitcastOp>(loc, i64Ty, cap);
            } else if (isa<LLVM::LLVMPointerType>(cap.getType())) {
                cap = closureStoreValueToI64(rewriter, loc, cap);
            }

            int64_t off = layout::ClosureValuesOffset + i * layout::PtrSize;
            auto offConst = rewriter.create<LLVM::ConstantOp>(
                loc, i64Ty, rewriter.getI64IntegerAttr(off));
            auto slotPtr = rewriter.create<LLVM::GEPOp>(
                loc, ptrTy, i8Ty, closurePtr, ValueRange{offConst});
            rewriter.create<LLVM::StoreOp>(loc, cap, slotPtr);
        }

        rewriter.replaceOp(op, closureHPtr);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Parallel project.closure pattern for !eco.closure_env operands.
//
// Higher benefit than the heap-side ProjectClosureOpLowering in
// EcoToLLVMClosures.cpp so it gets tried first; returns failure() for
// non-struct operands so the heap-side pattern then takes over.
//===----------------------------------------------------------------------===//

struct ProjectClosureFromEnvLowering
    : public OpConversionPattern<ProjectClosureOp> {

    ProjectClosureFromEnvLowering(EcoTypeConverter &typeConverter,
                                  MLIRContext *ctx)
        : OpConversionPattern<ProjectClosureOp>(typeConverter, ctx,
                                                /*benefit=*/2) {}

    LogicalResult
    matchAndRewrite(ProjectClosureOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        Value env = adaptor.getClosure();
        if (!isa<LLVM::LLVMStructType>(env.getType()))
            return failure(); // heap-closure path handles ptr addrspace(1)

        // The verifier already bounds-checked the index and matched the
        // result type against the env slot type, so we just emit
        // extractvalue.
        Type resultLLVMTy = getTypeConverter()->convertType(op.getResult().getType());
        if (!resultLLVMTy)
            return failure();
        Value result = rewriter.create<LLVM::ExtractValueOp>(
            op.getLoc(), resultLLVMTy, env,
            ArrayRef<int64_t>{static_cast<int64_t>(op.getIndex())});
        rewriter.replaceOp(op, result);
        return success();
    }
};

} // namespace

//===----------------------------------------------------------------------===//
// Pattern Population
//===----------------------------------------------------------------------===//

void eco::detail::populateEcoValueAggPatterns(
    EcoTypeConverter &typeConverter,
    RewritePatternSet &patterns,
    const EcoRuntime &runtime) {

    auto *ctx = patterns.getContext();
    patterns.add<Tuple2MakeOpLowering>(typeConverter, ctx);
    patterns.add<Tuple3MakeOpLowering>(typeConverter, ctx);
    patterns.add<RecordMakeOpLowering>(typeConverter, ctx);
    patterns.add<CustomMakeOpLowering>(typeConverter, ctx);
    patterns.add<ConsMakeOpLowering>(typeConverter, ctx);
    patterns.add<ClosureEnvMakeOpLowering>(typeConverter, ctx);
    patterns.add<ToHeapOpLowering>(typeConverter, ctx, runtime);
    patterns.add<FromHeapOpLowering>(typeConverter, ctx, runtime);
    patterns.add<MakeClosureOpLowering>(typeConverter, ctx, runtime);
    patterns.add<ProjectClosureFromEnvLowering>(typeConverter, ctx);
}
