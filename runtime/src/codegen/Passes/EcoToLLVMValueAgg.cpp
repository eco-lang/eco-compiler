//===- EcoToLLVMValueAgg.cpp - Value-aggregate lowering patterns ----------===//
//
// Lowers value aggregates, the tuples, records, custom values, cons cells and
// closure environments that live in SSA registers instead of on the heap, to
// the LLVM dialect.
//
// A value aggregate has an eco aggregate type (`!eco.tuple2`, a record, custom,
// cons or `!eco.closure_env` type), which the type converter turns into an LLVM
// struct. Building one (`eco.make.*`) is a chain of `insertvalue`s and reading
// a closure environment slot (`eco.project.closure` on an environment) is one
// `extractvalue`; neither touches the heap.
//
// Three operations move values between SSA and the heap, and they are most of
// this file:
//
// - `eco.to_heap` allocates the heap object with the same layout the matching
//   `eco.construct.*` lowering produces, and stores the fields into it.
// - `eco.from_heap` loads each field of a heap object and builds the struct.
// - `eco.make.closure` allocates a Closure whose captures come from a closure
//   environment.
//
// Two facts shape these. First, an allocation may collect and move every
// nursery object, so `eco.to_heap` extracts every field from the struct before
// the allocation. Second, slot kinds (2 bits per field: 0 boxed, 1 Int, 2 Float,
// 3 Char; see `slotKindOf`) are derived from the SSA element types, not read
// from an attribute, except that a cons cell's head kind comes first from the
// op's `head_kind`.
//
// Each allocation has two forms. When `inlineAllocEnabled()` holds (and, for a
// record, custom or closure, the object is at most 4096 bytes), the object is
// bump-allocated inline with its header as a constant. Otherwise an
// `eco_alloc_*` function is called.
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
// Helpers
//===----------------------------------------------------------------------===//

// Builds a value of the LLVM struct type `structTy` whose field i is
// `elements[i]`.
static Value buildStruct(ConversionPatternRewriter &rewriter, Location loc,
                         Type structTy, ValueRange elements) {
    Value agg = rewriter.create<LLVM::UndefOp>(loc, structTy);
    for (auto [i, e] : llvm::enumerate(elements)) {
        agg = rewriter.create<LLVM::InsertValueOp>(
            loc, agg, e, ArrayRef<int64_t>{static_cast<int64_t>(i)});
    }
    return agg;
}

// Returns `val` as the i64 word a store function takes: a boxed value through
// `heapStoreValueToI64`, a narrower integer zero-extended, an f64 bitcast, and
// anything else unchanged.
//
// `widenFieldToI64` in EcoToLLVMHeap.cpp is a separate copy of this function;
// the two must change together.
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

// Returns the slot kinds of `elements`, as `slotKindOf` gives them, packed 2
// bits each into one word with the first in the lowest bits.
//
// Used for tuples, whose kinds fit one word; at most 32 elements are allowed,
// which is asserted. Records and customs use `packKinds` instead.
static int64_t kindBitmapFor(ArrayRef<Type> elements) {
    assert(elements.size() <= 32 && "kindBitmapFor: more kinds than one word");
    SmallVector<uint8_t> kinds;
    for (Type t : elements)
        kinds.push_back(slotKindOf(t));
    return static_cast<int64_t>(kindsWord(kinds, 0, elements.size()));
}

// Returns field `index` of the struct value `agg`, of LLVM type `fieldTy`.
static Value extractField(ConversionPatternRewriter &rewriter, Location loc,
                          Value agg, int64_t index, Type fieldTy) {
    return rewriter.create<LLVM::ExtractValueOp>(
        loc, fieldTy, agg, ArrayRef<int64_t>{index});
}

//===----------------------------------------------------------------------===//
// eco.make.* -> insertvalue chain
//===----------------------------------------------------------------------===//

/**
 * The lowering of `eco.make.tuple2` to a struct built from its operands, in order.
 */
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

/**
 * The lowering of `eco.make.tuple3` to a struct built from its operands, in order.
 */
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

/**
 * The lowering of `eco.make.record` to a struct built from its operands, in order.
 */
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

/**
 * The lowering of `eco.make.custom` to a struct built from its operands, in order.
 */
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

/**
 * The lowering of `eco.make.cons` to a struct built from its operands, in order.
 */
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

/**
 * The lowering of `eco.make.closure_env` to a struct built from its operands, in order.
 */
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
// eco.to_heap
//===----------------------------------------------------------------------===//

/**
 * The lowering of `eco.to_heap`, which allocates the heap object for a tuple,
 * record, custom or cons aggregate and stores its fields.
 *
 * The object has the layout the corresponding `eco.construct.*` lowering in
 * EcoToLLVMHeap.cpp writes. A closure environment operand is not handled and
 * the match fails.
 */
struct ToHeapOpLowering : public OpConversionPattern<ToHeapOp> {
    const EcoRuntime &runtime; // Must outlive the pattern.

    // Creates the pattern, which keeps a reference to `runtime`.
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

        // -------- Tuple2 ---------------------------------------------------
        if (auto tup2 = dyn_cast<eco::Tuple2Type>(srcTy)) {
            Type elts[2] = { tup2.getFirst(), tup2.getSecond() };
            Type llvmElts[2] = {
                getTypeConverter()->convertType(elts[0]),
                getTypeConverter()->convertType(elts[1])
            };
            // Extracted before the allocation, so that a boxed field is a
            // scalar ptr addrspace(1) that RS4GC relocates across it.
            Value a = extractField(rewriter, loc, agg, 0, llvmElts[0]);
            Value b = extractField(rewriter, loc, agg, 1, llvmElts[1]);

            int64_t mask = kindBitmapFor(elts);

            // No zero-initialisation: nothing can collect before the stores
            // (HEAP_034).
            if (inlineAllocEnabled()) {
                uint64_t header = value_enc::composeHeader(
                    value_enc::TagTuple2,
                    static_cast<uint64_t>(mask) & 0xF, layout::Tuple2Size);
                Value tuple = emitInlineAllocWithHeader(
                    rewriter, loc, runtime, layout::Tuple2Size, header);
                emitFreshFieldStore(rewriter, loc, tuple,
                    layout::Tuple2FirstOffset, a, elts[0]);
                emitFreshFieldStore(rewriter, loc, tuple,
                    layout::Tuple2FirstOffset + layout::PtrSize, b, elts[1]);
                rewriter.replaceOp(op, tuple);
                return success();
            }

            auto unboxedVal = rewriter.create<LLVM::ConstantOp>(
                loc, i32Ty, static_cast<int32_t>(mask));

            // The kinds are passed to the allocation itself, so the header
            // is right from the start.
            Value tuple = emitAllocWithSafepoint(
                op, rewriter, runtime,
                runtime.getOrCreateAllocTuple2Uninit(rewriter),
                ValueRange{unboxedVal});

            auto storeFieldBoxed = runtime.getOrCreateStoreTupleField(rewriter);
            auto storeFieldI64   = runtime.getOrCreateStoreTupleFieldI64(rewriter);
            auto storeFieldF64   = runtime.getOrCreateStoreTupleFieldF64(rewriter);

            auto storeOne = [&](unsigned idx, Value v, Type origTy) {
                // The tuple is fresh, so it is stored to directly (HEAP_031).
                if (inlineDerefExtEnabled()) {
                    emitFreshFieldStore(rewriter, loc, tuple,
                        layout::HeaderSize + int64_t(idx) * layout::PtrSize, v, origTy);
                    return;
                }
                auto idxVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
                    static_cast<int32_t>(idx));
                if (origTy.isF64()) {
                    rewriter.create<LLVM::CallOp>(loc, storeFieldF64,
                        ValueRange{tuple, idxVal, v});
                } else if (origTy.isInteger(64)) {
                    rewriter.create<LLVM::CallOp>(loc, storeFieldI64,
                        ValueRange{tuple, idxVal, v});
                } else if (origTy.isInteger(1) || eco::isEcoCharType(origTy)) {
                    Value widened = widenFieldToI64Local(v, loc, rewriter);
                    rewriter.create<LLVM::CallOp>(loc, storeFieldI64,
                        ValueRange{tuple, idxVal, widened});
                } else {
                    rewriter.create<LLVM::CallOp>(loc, storeFieldBoxed,
                        ValueRange{tuple, idxVal, v});
                }
            };
            storeOne(0, a, elts[0]);
            storeOne(1, b, elts[1]);
            rewriter.replaceOp(op, tuple);
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

            int64_t mask = kindBitmapFor(elts);

            if (inlineAllocEnabled()) {
                uint64_t header = value_enc::composeHeader(
                    value_enc::TagTuple3,
                    static_cast<uint64_t>(mask) & 0x3F, layout::Tuple3Size);
                Value tuple = emitInlineAllocWithHeader(
                    rewriter, loc, runtime, layout::Tuple3Size, header);
                emitFreshFieldStore(rewriter, loc, tuple,
                    layout::Tuple3FirstOffset, a, elts[0]);
                emitFreshFieldStore(rewriter, loc, tuple,
                    layout::Tuple3FirstOffset + layout::PtrSize, b, elts[1]);
                emitFreshFieldStore(rewriter, loc, tuple,
                    layout::Tuple3FirstOffset + 2 * layout::PtrSize, c, elts[2]);
                rewriter.replaceOp(op, tuple);
                return success();
            }

            auto unboxedVal = rewriter.create<LLVM::ConstantOp>(
                loc, i32Ty, static_cast<int32_t>(mask));

            Value tuple = emitAllocWithSafepoint(
                op, rewriter, runtime,
                runtime.getOrCreateAllocTuple3Uninit(rewriter),
                ValueRange{unboxedVal});

            auto storeFieldBoxed = runtime.getOrCreateStoreTupleField(rewriter);
            auto storeFieldI64   = runtime.getOrCreateStoreTupleFieldI64(rewriter);
            auto storeFieldF64   = runtime.getOrCreateStoreTupleFieldF64(rewriter);

            auto storeOne = [&](unsigned idx, Value v, Type origTy) {
                // The tuple is fresh, so it is stored to directly (HEAP_031).
                if (inlineDerefExtEnabled()) {
                    emitFreshFieldStore(rewriter, loc, tuple,
                        layout::HeaderSize + int64_t(idx) * layout::PtrSize, v, origTy);
                    return;
                }
                auto idxVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
                    static_cast<int32_t>(idx));
                if (origTy.isF64()) {
                    rewriter.create<LLVM::CallOp>(loc, storeFieldF64,
                        ValueRange{tuple, idxVal, v});
                } else if (origTy.isInteger(64)) {
                    rewriter.create<LLVM::CallOp>(loc, storeFieldI64,
                        ValueRange{tuple, idxVal, v});
                } else if (origTy.isInteger(1) || eco::isEcoCharType(origTy)) {
                    Value widened = widenFieldToI64Local(v, loc, rewriter);
                    rewriter.create<LLVM::CallOp>(loc, storeFieldI64,
                        ValueRange{tuple, idxVal, widened});
                } else {
                    rewriter.create<LLVM::CallOp>(loc, storeFieldBoxed,
                        ValueRange{tuple, idxVal, v});
                }
            };
            storeOne(0, a, elts[0]);
            storeOne(1, b, elts[1]);
            storeOne(2, c, elts[2]);
            rewriter.replaceOp(op, tuple);
            return success();
        }

        // -------- Record ---------------------------------------------------
        if (auto rec = dyn_cast<eco::RecordType>(srcTy)) {
            ArrayRef<Type> fields = rec.getFields();
            int64_t fieldCount = static_cast<int64_t>(fields.size());
            // Kinds of fields past the 32 in the header go in K extension
            // kind words after the last field (HEAP_019).
            PackedKinds pk = packKinds(slotKindsOfTypes(fields), layout::RecordHdrSlots);
            const uint64_t K = pk.ext.size();
            const int64_t mask = static_cast<int64_t>(pk.hdrBits);

            // Extracted before the allocation, so that only scalars are live
            // across it.
            SmallVector<Value, 8> extracted;
            extracted.reserve(fieldCount);
            for (int64_t i = 0; i < fieldCount; ++i) {
                Type llvmElt = getTypeConverter()->convertType(fields[i]);
                extracted.push_back(extractField(rewriter, loc, agg, i, llvmElt));
            }

            uint64_t recByteSize = layout::recordByteSize(static_cast<uint64_t>(fieldCount));
            if (inlineAllocEnabled() && recByteSize <= 4096) {
                uint64_t header = value_enc::composeHeader(
                    value_enc::TagRecord, K, static_cast<uint64_t>(fieldCount));
                Value objHPtr = emitInlineAllocWithHeader(
                    rewriter, loc, runtime, recByteSize, header);
                emitInlineAllocMetaWord(rewriter, loc, objHPtr,
                                        static_cast<uint64_t>(mask));
                for (int64_t i = 0; i < fieldCount; ++i) {
                    emitFreshFieldStore(rewriter, loc, objHPtr,
                        layout::RecordFieldsOffset + i * layout::PtrSize,
                        extracted[i], fields[i]);
                }
                emitExtKindWordStores(rewriter, loc, objHPtr, layout::RecordFieldsOffset,
                                      static_cast<uint64_t>(fieldCount), pk.ext);
                rewriter.replaceOp(op, objHPtr);
                return success();
            }

            auto fieldCountVal = rewriter.create<LLVM::ConstantOp>(
                loc, i32Ty, static_cast<int32_t>(fieldCount));
            auto unboxedBitmapVal = rewriter.create<LLVM::ConstantOp>(
                loc, i64Ty, mask);

            Value objHPtr = emitAllocWithSafepoint(
                op, rewriter, runtime,
                runtime.getOrCreateAllocRecord(rewriter),
                ValueRange{fieldCountVal, unboxedBitmapVal});

            auto storeFunc    = runtime.getOrCreateStoreRecordField(rewriter);
            auto storeI64Func = runtime.getOrCreateStoreRecordFieldI64(rewriter);
            auto storeF64Func = runtime.getOrCreateStoreRecordFieldF64(rewriter);

            for (int64_t i = 0; i < fieldCount; ++i) {
                Type origTy = fields[i];
                Value fieldVal = extracted[i];
                // The record is fresh, so it is stored to directly (HEAP_031).
                if (inlineDerefExtEnabled()) {
                    emitFreshFieldStore(rewriter, loc, objHPtr,
                        layout::RecordFieldsOffset + i * layout::PtrSize, fieldVal, origTy);
                    continue;
                }
                auto idx = rewriter.create<LLVM::ConstantOp>(
                    loc, i32Ty, static_cast<int32_t>(i));
                if (origTy.isF64()) {
                    rewriter.create<LLVM::CallOp>(loc, storeF64Func,
                        ValueRange{objHPtr, idx, fieldVal});
                } else if (origTy.isInteger(64)) {
                    rewriter.create<LLVM::CallOp>(loc, storeI64Func,
                        ValueRange{objHPtr, idx, fieldVal});
                } else if (origTy.isInteger(1) || eco::isEcoCharType(origTy)) {
                    Value widened = widenFieldToI64Local(fieldVal, loc, rewriter);
                    rewriter.create<LLVM::CallOp>(loc, storeI64Func,
                        ValueRange{objHPtr, idx, widened});
                } else {
                    rewriter.create<LLVM::CallOp>(loc, storeFunc,
                        ValueRange{objHPtr, idx, fieldVal});
                }
            }
            emitExtKindWordStoresCall(rewriter, loc, objHPtr, layout::RecordFieldsOffset,
                                      static_cast<uint64_t>(fieldCount), pk.ext, storeI64Func);
            rewriter.replaceOp(op, objHPtr);
            return success();
        }

        // -------- Custom ---------------------------------------------------
        if (auto cus = dyn_cast<eco::CustomType>(srcTy)) {
            ArrayRef<Type> fields = cus.getFields();
            int64_t fieldCount = static_cast<int64_t>(fields.size());
            // Kinds of fields past the 24 in the header go in extension kind
            // words, as for a record.
            PackedKinds pk = packKinds(slotKindsOfTypes(fields), layout::CustomHdrSlots);
            const uint64_t K = pk.ext.size();
            const int64_t mask = static_cast<int64_t>(pk.hdrBits);

            // Extracted before the allocation, as for a record.
            SmallVector<Value, 8> extracted;
            extracted.reserve(fieldCount);
            for (int64_t i = 0; i < fieldCount; ++i) {
                Type llvmElt = getTypeConverter()->convertType(fields[i]);
                extracted.push_back(extractField(rewriter, loc, agg, i, llvmElt));
            }

            // The constructor tag and the kinds share one word (tag in bits
            // 0-15, kinds above); on the inline path this replaces the
            // eco_set_unboxed call.
            uint64_t cusByteSize = layout::customByteSize(static_cast<uint64_t>(fieldCount));
            if (inlineAllocEnabled() && cusByteSize <= 4096) {
                uint64_t bitmap = static_cast<uint64_t>(mask);
                assert((bitmap >> 48) == 0 &&
                       "Custom unboxed bitmap overflow (>48 bits)");
                uint64_t header = value_enc::composeHeader(
                    value_enc::TagCustom, K, static_cast<uint64_t>(fieldCount));
                uint64_t meta = (static_cast<uint64_t>(op.getTag()) & 0xFFFF)
                              | (bitmap << 16);
                Value objHPtr = emitInlineAllocWithHeader(
                    rewriter, loc, runtime, cusByteSize, header);
                emitInlineAllocMetaWord(rewriter, loc, objHPtr, meta);
                for (int64_t i = 0; i < fieldCount; ++i) {
                    emitFreshFieldStore(rewriter, loc, objHPtr,
                        layout::CustomFieldsOffset + i * layout::PtrSize,
                        extracted[i], fields[i]);
                }
                emitExtKindWordStores(rewriter, loc, objHPtr, layout::CustomFieldsOffset,
                                      static_cast<uint64_t>(fieldCount), pk.ext);
                rewriter.replaceOp(op, objHPtr);
                return success();
            }

            auto tagVal = rewriter.create<LLVM::ConstantOp>(
                loc, i32Ty, static_cast<int32_t>(op.getTag()));
            auto sizeVal = rewriter.create<LLVM::ConstantOp>(
                loc, i32Ty, static_cast<int32_t>(fieldCount));

            Value objHPtr = emitAllocWithSafepoint(
                op, rewriter, runtime,
                runtime.getOrCreateAllocCustom(rewriter),
                ValueRange{tagVal, sizeVal});

            auto storeFunc    = runtime.getOrCreateStoreField(rewriter);
            auto storeI64Func = runtime.getOrCreateStoreFieldI64(rewriter);
            auto storeF64Func = runtime.getOrCreateStoreFieldF64(rewriter);
            auto setUnboxed   = runtime.getOrCreateSetUnboxed(rewriter);

            for (int64_t i = 0; i < fieldCount; ++i) {
                Type origTy = fields[i];
                Value fieldVal = extracted[i];
                // The object is fresh, so it is stored to directly (HEAP_031).
                if (inlineDerefExtEnabled()) {
                    emitFreshFieldStore(rewriter, loc, objHPtr,
                        layout::CustomFieldsOffset + i * layout::PtrSize, fieldVal, origTy);
                    continue;
                }
                auto idx = rewriter.create<LLVM::ConstantOp>(
                    loc, i32Ty, static_cast<int32_t>(i));
                if (origTy.isF64()) {
                    rewriter.create<LLVM::CallOp>(loc, storeF64Func,
                        ValueRange{objHPtr, idx, fieldVal});
                } else if (origTy.isInteger(64)) {
                    rewriter.create<LLVM::CallOp>(loc, storeI64Func,
                        ValueRange{objHPtr, idx, fieldVal});
                } else if (origTy.isInteger(1) || eco::isEcoCharType(origTy)) {
                    Value widened = widenFieldToI64Local(fieldVal, loc, rewriter);
                    rewriter.create<LLVM::CallOp>(loc, storeI64Func,
                        ValueRange{objHPtr, idx, widened});
                } else {
                    rewriter.create<LLVM::CallOp>(loc, storeFunc,
                        ValueRange{objHPtr, idx, fieldVal});
                }
            }
            emitExtKindWordStoresCall(rewriter, loc, objHPtr, layout::CustomFieldsOffset,
                                      static_cast<uint64_t>(fieldCount), pk.ext, storeI64Func);
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
            // Extracted before the allocation, as for a tuple.
            Value head = extractField(rewriter, loc, agg, 0, llvmHead);
            Value tail = extractField(rewriter, loc, agg, 1, llvmTail);

            // The head kind is the op's head_kind; when that is boxed, it is
            // derived from the head type instead.
            uint32_t kind = static_cast<uint32_t>(op.getHeadKind()) & 0x3;
            if (kind == 0 && op.getHeadUnboxed()) {
                Type ht = cons.getHead();
                if (ht.isInteger(64)) kind = 1;
                else if (ht.isF64())  kind = 2;
                else if (eco::isEcoCharType(ht)) kind = 3;
            }
            if (kind == 0 && !isa<eco::ValueType>(cons.getHead())) {
                Type ht = cons.getHead();
                if (ht.isInteger(64)) kind = 1;
                else if (ht.isF64())  kind = 2;
                else if (eco::isEcoCharType(ht)) kind = 3;
            }
            // emitFreshFieldStore chooses the word from the head type, not
            // from `kind`; the two agree unless head_kind names an unboxed
            // kind for a head type that is not that kind.
            if (inlineAllocEnabled()) {
                uint64_t header = value_enc::composeHeader(
                    value_enc::TagCons, kind, layout::ConsSize);
                Value consHPtr = emitInlineAllocWithHeader(
                    rewriter, loc, runtime, layout::ConsSize, header);
                emitFreshFieldStore(rewriter, loc, consHPtr,
                    layout::ConsHeadOffset, head, cons.getHead());
                emitFreshFieldStore(rewriter, loc, consHPtr,
                    layout::ConsTailOffset, tail, cons.getTail());
                rewriter.replaceOp(op, consHPtr);
                return success();
            }

            auto kindVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
                static_cast<int32_t>(kind));

            // The head kind is passed to the allocation itself, so the header
            // is right from the start.
            Value consHPtr = emitAllocWithSafepoint(
                op, rewriter, runtime,
                runtime.getOrCreateAllocConsUninit(rewriter),
                ValueRange{kindVal});

            if (kind == 0) {
                rewriter.create<LLVM::CallOp>(loc,
                    runtime.getOrCreateStoreConsHead(rewriter),
                    ValueRange{consHPtr, head});
            } else if (kind == 2) {
                rewriter.create<LLVM::CallOp>(loc,
                    runtime.getOrCreateStoreConsHeadF64(rewriter),
                    ValueRange{consHPtr, head});
            } else {
                // Int or Char.
                Value widened = widenFieldToI64Local(head, loc, rewriter);
                rewriter.create<LLVM::CallOp>(loc,
                    runtime.getOrCreateStoreConsHeadI64(rewriter),
                    ValueRange{consHPtr, widened});
            }
            rewriter.create<LLVM::CallOp>(loc,
                runtime.getOrCreateStoreConsTail(rewriter),
                ValueRange{consHPtr, tail});
            rewriter.replaceOp(op, consHPtr);
            return success();
        }

        return rewriter.notifyMatchFailure(op,
            "eco.to_heap: unsupported aggregate kind (closure_env was rejected by verifier; "
            "every other aggregate is handled above)");
    }
};

//===----------------------------------------------------------------------===//
// eco.from_heap
//===----------------------------------------------------------------------===//

/**
 * The lowering of `eco.from_heap`, which reads every field of a heap tuple,
 * record, custom or cons object into the struct of its value aggregate type.
 *
 * The object is read with the layout `eco.to_heap` writes. A closure
 * environment result is not handled and the match fails.
 */
struct FromHeapOpLowering : public OpConversionPattern<FromHeapOp> {
    const EcoRuntime &runtime; // Must outlive the pattern.

    // Creates the pattern, which keeps a reference to `runtime`.
    FromHeapOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                       const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    // Returns the field at `offsetBytes` in the object at `ptr`, as a value of
    // the LLVM type `elemTy`.
    //
    // `ptr` is either a `ptr addrspace(1)` or an address-space-0 pointer, and
    // the field address is in the same space. The 64-bit slot is loaded as i64,
    // then turned into a boxed value, bitcast to f64 or truncated to a narrower
    // integer; any other `elemTy` is loaded directly at that type.
    Value loadFieldAt(ConversionPatternRewriter &rewriter, Location loc,
                      Value ptr, int64_t offsetBytes, Type elemTy) const {
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i8Ty = IntegerType::get(ctx, 8);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, offsetBytes);
        Type gepTy = isHPtrLLVMType(ptr.getType())
                         ? static_cast<Type>(getHPtrLLVMType(*ctx))
                         : static_cast<Type>(ptrTy);
        auto fieldPtr = rewriter.create<LLVM::GEPOp>(loc, gepTy, i8Ty, ptr,
                                                     ValueRange{offset});
        if (isHPtrLLVMType(elemTy)) {
            Value loaded = rewriter.create<LLVM::LoadOp>(loc, i64Ty, fieldPtr);
            return heapLoadI64ToValue(rewriter, loc, loaded);
        }
        Value slot = rewriter.create<LLVM::LoadOp>(loc, i64Ty, fieldPtr);
        if (elemTy.isInteger(64)) return slot;
        if (elemTy.isF64())
            return rewriter.create<LLVM::BitcastOp>(loc, elemTy, slot);
        if (auto intTy = dyn_cast<IntegerType>(elemTy)) {
            if (intTy.getWidth() < 64)
                return rewriter.create<LLVM::TruncOp>(loc, elemTy, slot);
        }
        return rewriter.create<LLVM::LoadOp>(loc, elemTy, fieldPtr);
    }

    LogicalResult
    matchAndRewrite(FromHeapOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type resTy = op.getResult().getType();
        Type structTy = getTypeConverter()->convertType(resTy);
        if (!structTy) return failure();

        // The operand must be a heap object, not an embedded constant: both
        // forms of resolution treat it as an address.
        Value ptr;
        if (inlineDerefExtEnabled()) {
            ptr = inlineResolvedBase(rewriter, loc, adaptor.getValue(), runtime);
        } else {
            auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
            auto resolveCall = rewriter.create<LLVM::CallOp>(
                loc, resolveFunc, ValueRange{adaptor.getValue()});
            ptr = resolveCall.getResult();
        }

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
// eco.make.closure
//===----------------------------------------------------------------------===//

/**
 * The lowering of `eco.make.closure`, which allocates a Closure of the op's
 * arity for the op's function and stores the captures of a closure
 * environment into it.
 *
 * The evaluator slot holds the descriptor emitted for the bare function (see
 * `emitEvalDescAddrForFuncSymbol`), so the function must already take the
 * closure calling convention; no wrapper is made. The parameter kinds in the
 * packed word are the capture kinds, with the remaining parameters up to the
 * arity boxed; kinds past the 20 that fit the packed word go in extension
 * kind words after the arity slots. The result kind is the op's optional
 * `_result_kind` attribute, boxed when absent.
 */
struct MakeClosureOpLowering : public OpConversionPattern<MakeClosureOp> {
    const EcoRuntime &runtime; // Must outlive the pattern.

    // Creates the pattern, which keeps a reference to `runtime`.
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

        Value envAgg = adaptor.getEnv();

        Value funcPtr = eco::detail::emitEvalDescAddrForFuncSymbol(
            rewriter, loc, runtime, op.getFunction());

        SmallVector<uint8_t> capKinds;
        for (Type t : captures)
            capKinds.push_back(slotKindOf(t));
        capKinds.resize(static_cast<size_t>(arity), 0);
        PackedKinds pk = packKinds(capKinds, layout::ClosureHdrSlots);
        const int64_t numExt = static_cast<int64_t>(pk.ext.size());

        Value closureHPtr;
        uint64_t cloByteSize = layout::ClosureBaseSize +
            static_cast<uint64_t>(arity + numExt) * layout::PtrSize;
        if (inlineAllocEnabled() && cloByteSize <= 4096) {
            // Only the evaluator is stored here; the packed word at offset 8
            // is stored below, on both paths.
            uint64_t header = value_enc::composeHeader(
                value_enc::TagClosure, 0, static_cast<uint64_t>(arity + numExt));
            closureHPtr = emitInlineAllocWithHeader(
                rewriter, loc, runtime, cloByteSize, header);
            auto evOff = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
                static_cast<int64_t>(layout::ClosureEvaluatorOffset));
            auto evSlot = rewriter.create<LLVM::GEPOp>(
                loc, getHPtrLLVMType(*ctx), i8Ty, closureHPtr,
                ValueRange{evOff});
            rewriter.create<LLVM::StoreOp>(loc, funcPtr, evSlot,
                                           /*alignment=*/8);
        } else {
            auto arityConst = rewriter.create<LLVM::ConstantOp>(
                loc, i32Ty, static_cast<int32_t>(arity));
            closureHPtr = emitAllocWithSafepoint(
                op, rewriter, runtime,
                runtime.getOrCreateAllocClosure(rewriter),
                ValueRange{funcPtr, arityConst});
        }

        // Nothing between the allocation and the stores below can collect,
        // so the closure is fresh and is stored to directly (HEAP_031).
        Value closurePtr;
        Type storeGepTy;
        if (inlineDerefExtEnabled()) {
            closurePtr = closureHPtr;
            storeGepTy = getHPtrLLVMType(*ctx);
        } else {
            auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
            auto resolveCall = rewriter.create<LLVM::CallOp>(
                loc, resolveFunc, ValueRange{closureHPtr});
            closurePtr = resolveCall.getResult();
            storeGepTy = ptrTy;
        }

        // The packed word overwrites the one the out-of-line allocation
        // wrote (HEAP_078).
        uint8_t resultKind = 0;
        if (auto a = op->getAttrOfType<IntegerAttr>("_result_kind"))
            resultKind = static_cast<uint8_t>(a.getInt() & 3);
        uint64_t packed = packClosureWord(
            static_cast<uint32_t>(numCaptured), static_cast<uint32_t>(arity),
            resultKind, pk.hdrBits);
        auto packedConst = rewriter.create<LLVM::ConstantOp>(
            loc, i64Ty, rewriter.getI64IntegerAttr(static_cast<int64_t>(packed)));
        auto offset8 = rewriter.create<LLVM::ConstantOp>(
            loc, i64Ty, rewriter.getI64IntegerAttr(layout::ClosurePackedOffset));
        auto packedPtr = rewriter.create<LLVM::GEPOp>(
            loc, storeGepTy, i8Ty, closurePtr, ValueRange{offset8});
        rewriter.create<LLVM::StoreOp>(loc, packedConst, packedPtr);

        for (int64_t i = 0; i < numCaptured; ++i) {
            Type llvmElt = getTypeConverter()->convertType(captures[i]);
            Value cap = extractField(rewriter, loc, envAgg, i, llvmElt);

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
                loc, storeGepTy, i8Ty, closurePtr, ValueRange{offConst});
            rewriter.create<LLVM::StoreOp>(loc, cap, slotPtr);
        }

        // Extension kind words, zero words included (HEAP_077).
        for (int64_t j = 0; j < numExt; ++j) {
            int64_t off = layout::ClosureValuesOffset + (arity + j) * layout::PtrSize;
            auto offConst = rewriter.create<LLVM::ConstantOp>(
                loc, i64Ty, rewriter.getI64IntegerAttr(off));
            auto slotPtr = rewriter.create<LLVM::GEPOp>(
                loc, storeGepTy, i8Ty, closurePtr, ValueRange{offConst});
            auto w = rewriter.create<LLVM::ConstantOp>(
                loc, i64Ty, rewriter.getI64IntegerAttr(static_cast<int64_t>(pk.ext[j])));
            rewriter.create<LLVM::StoreOp>(loc, w, slotPtr);
        }

        rewriter.replaceOp(op, closureHPtr);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.project.closure on a closure environment
//===----------------------------------------------------------------------===//

/**
 * The lowering of `eco.project.closure` whose operand is a closure
 * environment, to an `extractvalue`.
 *
 * It has benefit 2, so it is tried before the heap-closure lowering in
 * EcoToLLVMClosures.cpp, and its match fails for an operand that did not
 * convert to a struct, which leaves the op to that lowering.
 */
struct ProjectClosureFromEnvLowering
    : public OpConversionPattern<ProjectClosureOp> {

    // Creates the pattern.
    ProjectClosureFromEnvLowering(EcoTypeConverter &typeConverter,
                                  MLIRContext *ctx)
        : OpConversionPattern<ProjectClosureOp>(typeConverter, ctx,
                                                /*benefit=*/2) {}

    LogicalResult
    matchAndRewrite(ProjectClosureOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        Value env = adaptor.getClosure();
        if (!isa<LLVM::LLVMStructType>(env.getType()))
            return failure();

        // The verifier has checked the index and the result type.
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
