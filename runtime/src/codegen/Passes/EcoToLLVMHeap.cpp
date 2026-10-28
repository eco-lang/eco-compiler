//===- EcoToLLVMHeap.cpp - Heap operation lowering patterns ---------------===//
//
// Compiled Elm code builds and reads heap objects itself, without calling the runtime for each field. This file
// turns the eco operations that box, allocate, construct and project heap values into LLVM-dialect code that
// does so, and lowers the array operations and a few string and list operations, most of them to runtime
// calls. `populateEcoHeapPatterns` adds the patterns; `lowerAllocGroups` runs on its own, before the pattern
// conversion.
//
// Every heap slot is one 64-bit word. Only Int (i64), Float (f64) and Char (i32) are stored unboxed; a Bool is
// always a boxed `!eco.value`, the True or False embedded constant. In tuples, records and customs each slot's
// kind is taken from the type its operand had before conversion; a cons cell's head kind comes from the op's
// verified `head_kind` attribute. The object records the kinds so that the collector knows which slots hold
// pointers.
//
// An object is allocated in one of three ways.
//
// 1. Inline. When `inlineAllocEnabled()`, an object of fixed size up to 4096 bytes is allocated with the
//    `__eco_alloc_inline` marker (`emitInlineAllocWithHeader`), given a constant header word, and then has
//    every slot stored directly. The backend expands the marker before RS4GC.
// 2. A runtime call. Otherwise an `eco_alloc_*` function allocates the object. It is not gc-leaf, so RS4GC
//    makes the call a statepoint. The fields are then stored directly or through gc-leaf store functions.
// 3. A group. EcoGCPrepare marks a run of adjacent fixed-size allocations with `eco.gc_group_size`, and
//    `lowerAllocGroups` gives the run one allocation of its total size: the gc-leaf
//    `eco_gc_alloc_region_fast`, which returns null when it cannot, and otherwise the statepointed
//    `eco_gc_alloc_region_slow`. Each member is initialised in place by a gc-leaf `eco_init_*_at` call.
//
// A collection may copy an object and leave a forwarding word in its place, so a field is read through the
// forwarding check: the pointer goes through the `__eco_resolve_fwd` marker, which stays in
// `ptr addrspace(1)` so that RS4GC still tracks it, and the backend expands the marker to an inline test of
// the header. Every slot is 8-byte aligned (HEAP_028), so slot loads are `align 8`. A projection whose operand
// is a value-level aggregate, an LLVM struct rather than a heap object, is an `extractvalue`.
//
//===----------------------------------------------------------------------===//

#include "EcoToLLVMInternal.h"
#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../../allocator/Heap.hpp"

#include "mlir/Dialect/ControlFlow/IR/ControlFlowOps.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"

using namespace mlir;
using namespace eco;
using namespace eco::detail;

// The layout constants this file compiles into code must equal the runtime's in Heap.hpp. Each is checked
// here at compile time, except the bit positions of the header fields: bit-field packing is
// implementation-defined, so the test `testHeaderWordComposition` checks those at run time.
static_assert(eco::detail::value_enc::TagForward == Elm::Tag_Forward,
              "value_enc::TagForward out of sync with Elm::Tag_Forward");
static_assert(eco::detail::value_enc::TagBits == TAG_BITS,
              "value_enc::TagBits out of sync with TAG_BITS");
// The inline get_tag lowering tells these two tags apart.
static_assert(eco::detail::value_enc::TagCons == Elm::Tag_Cons,
              "value_enc::TagCons out of sync with Elm::Tag_Cons");
static_assert(eco::detail::value_enc::TagCustom == Elm::Tag_Custom,
              "value_enc::TagCustom out of sync with Elm::Tag_Custom");
// The null-cons constant lowering and the inline get_tag lowering build and decode null-cons words
// (HEAP_044) from these.
static_assert(eco::detail::value_enc::NullConsShift == NULL_CONS_SHIFT,
              "value_enc::NullConsShift out of sync with NULL_CONS_SHIFT");
static_assert(eco::detail::value_enc::NullConsMax == NULL_CONS_MAX,
              "value_enc::NullConsMax out of sync with NULL_CONS_MAX");
static_assert(eco::detail::value_enc::NullCons == Elm::Const_NullCons,
              "value_enc::NullCons out of sync with Elm::Const_NullCons");
// The record and custom kind-word layout, and the largest record and custom, which must be smaller than
// 32 KiB, EcoGCPrepare's `GroupLargeObjectThreshold`.
static_assert(eco::detail::layout::CustomHdrSlots == Elm::CUSTOM_HDR_SLOTS);
static_assert(eco::detail::layout::RecordHdrSlots == Elm::RECORD_HDR_SLOTS);
static_assert(eco::detail::layout::SlotsPerExtWord == Elm::SLOTS_PER_EXT_WORD);
static_assert(eco::detail::layout::recordByteSize(Elm::RECORD_MAX_FIELDS) < 32 * 1024,
              "wide records must stay below GroupLargeObjectThreshold (young, no barrier needed)");
static_assert(eco::detail::layout::customByteSize(Elm::CUSTOM_MAX_FIELDS) < 32 * 1024,
              "wide customs must stay below GroupLargeObjectThreshold (young, no barrier needed)");
// The inline allocations compose header words from these tags.
static_assert(eco::detail::value_enc::TagInt == Elm::Tag_Int,
              "value_enc::TagInt out of sync with Elm::Tag_Int");
static_assert(eco::detail::value_enc::TagFloat == Elm::Tag_Float,
              "value_enc::TagFloat out of sync with Elm::Tag_Float");
static_assert(eco::detail::value_enc::TagChar == Elm::Tag_Char,
              "value_enc::TagChar out of sync with Elm::Tag_Char");
static_assert(eco::detail::value_enc::TagTuple2 == Elm::Tag_Tuple2,
              "value_enc::TagTuple2 out of sync with Elm::Tag_Tuple2");
static_assert(eco::detail::value_enc::TagTuple3 == Elm::Tag_Tuple3,
              "value_enc::TagTuple3 out of sync with Elm::Tag_Tuple3");
static_assert(eco::detail::value_enc::TagRecord == Elm::Tag_Record,
              "value_enc::TagRecord out of sync with Elm::Tag_Record");
static_assert(eco::detail::value_enc::TagClosure == Elm::Tag_Closure,
              "value_enc::TagClosure out of sync with Elm::Tag_Closure");
// The object sizes the inline allocations use.
static_assert(eco::detail::layout::Tuple2Size == sizeof(Elm::Tuple2) &&
              eco::detail::layout::Tuple3Size == sizeof(Elm::Tuple3) &&
              eco::detail::layout::ConsSize == sizeof(Elm::Cons) &&
              eco::detail::layout::BoxedPrimSize == sizeof(Elm::ElmInt) &&
              eco::detail::layout::BoxedPrimSize == sizeof(Elm::ElmFloat) &&
              eco::detail::layout::BoxedPrimSize == sizeof(Elm::ElmChar) &&
              eco::detail::layout::RecordBaseSize == sizeof(Elm::Record) &&
              eco::detail::layout::CustomBaseSize == sizeof(Elm::Custom) &&
              eco::detail::layout::ClosureBaseSize == sizeof(Elm::Closure),
              "inline-alloc layout:: sizes drifted from Heap.hpp");

namespace {

// Defined further down; ListConstructOpLowering uses it.
static Value widenFieldToI64(Value val, Location loc,
                             ConversionPatternRewriter &rewriter);

//===----------------------------------------------------------------------===//
// Inline heap reads, through the forwarding check
//===----------------------------------------------------------------------===//

/// Returns the address of the object `hptr` names, after following a forwarding word, as the result of the
/// `__eco_resolve_fwd` marker. `hptr` must name a heap object, not an embedded constant. This is the same as
/// `inlineResolvedBase`.
static Value emitResolvedBase(Value hptr, Location loc,
                              ConversionPatternRewriter &rewriter,
                              const EcoRuntime &runtime) {
    auto marker = runtime.getOrCreateResolveFwdMarker(rewriter);
    return rewriter.create<LLVM::CallOp>(loc, marker, ValueRange{hptr})
        .getResult();
}

/// Returns a `ptr addrspace(1)` to byte `byteOffset` of the object `hptr` names, after the forwarding check.
static Value emitInlineFieldPtr(Value hptr, Value byteOffset, Location loc,
                                ConversionPatternRewriter &rewriter,
                                const EcoRuntime &runtime) {
    auto *ctx = rewriter.getContext();
    auto i8Ty = IntegerType::get(ctx, 8);
    auto hptrTy = getHPtrLLVMType(*ctx);
    Value base = emitResolvedBase(hptr, loc, rewriter, runtime);
    return rewriter.create<LLVM::GEPOp>(loc, hptrTy, i8Ty, base,
                                        ValueRange{byteOffset});
}

/// Returns the boxed slot at byte `offsetBytes` of the object `hptr` names, read through the forwarding check,
/// as a `ptr addrspace(1)`. The loaded word becomes a pointer through `heapLoadI64ToValue`.
static Value emitInlineBoxedLoad(Value hptr, int64_t offsetBytes, Location loc,
                                 ConversionPatternRewriter &rewriter,
                                 const EcoRuntime &runtime) {
    auto *ctx = rewriter.getContext();
    auto i64Ty = IntegerType::get(ctx, 64);
    auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, offsetBytes);
    Value fieldPtr = emitInlineFieldPtr(hptr, offset, loc, rewriter, runtime);
    Value loaded = rewriter.create<LLVM::LoadOp>(loc, i64Ty, fieldPtr,
                                                 layout::Alignment);
    return heapLoadI64ToValue(rewriter, loc, loaded);
}

/// Returns the unboxed slot at byte `offsetBytes` of the object `hptr` names, read through the forwarding check
/// as a `primTy`, which is i64, f64 or i32.
static Value emitInlinePrimLoad(Value hptr, int64_t offsetBytes, Type primTy,
                                Location loc,
                                ConversionPatternRewriter &rewriter,
                                const EcoRuntime &runtime) {
    auto *ctx = rewriter.getContext();
    auto i64Ty = IntegerType::get(ctx, 64);
    auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, offsetBytes);
    Value fieldPtr = emitInlineFieldPtr(hptr, offset, loc, rewriter, runtime);
    return rewriter.create<LLVM::LoadOp>(loc, primTy, fieldPtr,
                                         layout::Alignment);
}

//===----------------------------------------------------------------------===//
// Allocation sizes for groups
//===----------------------------------------------------------------------===//

/// Returns the size in bytes, a multiple of 8, of the object `op` allocates, or 0 for an op whose size is not
/// known here, including a box of a Bool. It must agree byte for byte with `getFixedAllocSizeForGrouping` in
/// EcoGCPrepare.cpp, which sizes the same groups; the two are separate copies.
static int64_t computeAllocSize(Operation *op) {
    constexpr int64_t HeaderSize = 8; // Bytes in an object header.

    if (auto allocStr = dyn_cast<eco::AllocateStringOp>(op)) {
        int64_t size = HeaderSize + allocStr.getLength() * 2;
        return (size + 7) & ~7;
    }
    if (isa<eco::ListConstructOp>(op)) return 24;
    if (isa<eco::Tuple2ConstructOp>(op)) return 24;
    if (isa<eco::Tuple3ConstructOp>(op)) return 32;
    // Includes the extension kind words (HEAP_019).
    if (auto recOp = dyn_cast<eco::RecordConstructOp>(op))
        return static_cast<int64_t>(layout::recordByteSize(recOp.getFieldCount()));
    if (auto customOp = dyn_cast<eco::CustomConstructOp>(op))
        return static_cast<int64_t>(layout::customByteSize(customOp.getSize()));
    if (auto boxOp = dyn_cast<eco::BoxOp>(op)) {
        Type inputType = boxOp.getValue().getType();
        if (inputType.isInteger(64) || inputType.isF64() || eco::isEcoCharType(inputType))
            return 16;
        return 0;
    }
    return 0;
}

//===----------------------------------------------------------------------===//
// eco.box
//===----------------------------------------------------------------------===//

/// The pattern that lowers `eco.box`, which turns an Int (i64), Float (f64), Char (i32) or Bool (i1) into an
/// `!eco.value`.
///
/// An Int, Float or Char becomes a 16-byte object of tag Int, Float or Char that holds the value in the word
/// after its header. When `inlineAllocEnabled()` the object is allocated inline (HEAP_034) and a Char is stored
/// zero-extended to the whole word; otherwise `eco_alloc_int`, `eco_alloc_float` or `eco_alloc_char` makes it.
/// A Bool allocates nothing: it becomes the True or False embedded constant (CGEN_019). Any other operand type
/// fails with an error.
struct BoxOpLowering : public OpConversionPattern<BoxOp> {
    const EcoRuntime &runtime; ///< Declares the runtime functions and markers; must outlive the pattern.

    /// Creates the pattern, which keeps a reference to `runtime`.
    BoxOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                  const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(BoxOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);

        Value input = adaptor.getValue();
        Type inputType = input.getType();
        Value result;

        if (inlineAllocEnabled() &&
            (inputType.isInteger(64) || inputType.isF64() ||
             eco::isEcoCharType(inputType))) {
            uint64_t tag = inputType.isInteger(64) ? value_enc::TagInt
                         : inputType.isF64()       ? value_enc::TagFloat
                                                   : value_enc::TagChar;
            uint64_t header =
                value_enc::composeHeader(tag, 0, layout::BoxedPrimSize);
            Value obj = emitInlineAllocWithHeader(
                rewriter, loc, runtime, layout::BoxedPrimSize, header);
            emitFreshFieldStore(rewriter, loc, obj, layout::HeaderSize,
                                input, inputType);
            rewriter.replaceOp(op, obj);
            return success();
        }

        if (inputType.isInteger(64)) {
            result = emitAllocWithSafepoint(
                op, rewriter, runtime,
                runtime.getOrCreateAllocInt(rewriter),
                ValueRange{input});
        } else if (inputType.isF64()) {
            result = emitAllocWithSafepoint(
                op, rewriter, runtime,
                runtime.getOrCreateAllocFloat(rewriter),
                ValueRange{input});
        } else if (eco::isEcoCharType(inputType)) {
            result = emitAllocWithSafepoint(
                op, rewriter, runtime,
                runtime.getOrCreateAllocChar(rewriter),
                ValueRange{input});
        } else if (inputType.isInteger(1)) {
            auto hptrTy = getHPtrLLVMType(*ctx);
            Value trueI64 = rewriter.create<LLVM::ConstantOp>(
                loc, i64Ty, value_enc::encodeConstant(value_enc::True));
            Value trueCst = rewriter.create<LLVM::IntToPtrOp>(loc, hptrTy, trueI64);
            Value falseI64 = rewriter.create<LLVM::ConstantOp>(
                loc, i64Ty, value_enc::encodeConstant(value_enc::False));
            Value falseCst = rewriter.create<LLVM::IntToPtrOp>(loc, hptrTy, falseI64);
            result = rewriter.create<LLVM::SelectOp>(loc, input, trueCst, falseCst);
        } else {
            return op.emitError("unsupported type for boxing: ") << inputType;
        }

        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.unbox
//===----------------------------------------------------------------------===//

/// The pattern that lowers `eco.unbox`, which reads the Int, Float, Char or Bool out of an `!eco.value`.
///
/// For a Bool result the operand is compared with the True constant, so any other word gives false. For any
/// other result the operand must name a boxed object of that kind, and the value is loaded from the word after
/// its header, through the forwarding check.
struct UnboxOpLowering : public OpConversionPattern<UnboxOp> {
    const EcoRuntime &runtime; ///< Declares the runtime functions and markers; must outlive the pattern.

    /// Creates the pattern, which keeps a reference to `runtime`.
    UnboxOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                    const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(UnboxOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i1Ty = IntegerType::get(ctx, 1);

        Value input = adaptor.getValue();
        Type resultType = getTypeConverter()->convertType(op.getResult().getType());

        if (resultType == i1Ty) {
            auto hptrTy = getHPtrLLVMType(*ctx);
            Value trueI64 = rewriter.create<LLVM::ConstantOp>(
                loc, i64Ty, value_enc::encodeConstant(value_enc::True));
            Value trueConst = rewriter.create<LLVM::IntToPtrOp>(loc, hptrTy, trueI64);
            Value result = rewriter.create<LLVM::ICmpOp>(
                loc, LLVM::ICmpPredicate::eq, input, trueConst);
            rewriter.replaceOp(op, result);
            return success();
        }

        Value result = emitInlinePrimLoad(input, layout::HeaderSize,
                                          resultType, loc, rewriter, runtime);
        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.allocate
//===----------------------------------------------------------------------===//

/// The pattern that lowers `eco.allocate` to a call of `eco_allocate` with the op's size and the Custom tag.
struct AllocateOpLowering : public OpConversionPattern<AllocateOp> {
    const EcoRuntime &runtime; ///< Declares the runtime functions and markers; must outlive the pattern.

    /// Creates the pattern, which keeps a reference to `runtime`.
    AllocateOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                       const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(AllocateOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);

        auto size = adaptor.getSize();
        auto tag = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, 7);  // Tag_Custom

        Value result = emitAllocWithSafepoint(
            op, rewriter, runtime,
            runtime.getOrCreateAllocate(rewriter),
            ValueRange{size, tag});
        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.allocate_string
//===----------------------------------------------------------------------===//

/// The pattern that lowers `eco.allocate_string` to a call of `eco_alloc_string` with the op's length,
/// passed as an i32.
struct AllocateStringOpLowering : public OpConversionPattern<AllocateStringOp> {
    const EcoRuntime &runtime; ///< Declares the runtime functions and markers; must outlive the pattern.

    /// Creates the pattern, which keeps a reference to `runtime`.
    AllocateStringOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                             const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(AllocateStringOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);

        auto length = rewriter.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(op.getLength()));

        Value result = emitAllocWithSafepoint(
            op, rewriter, runtime,
            runtime.getOrCreateAllocString(rewriter),
            ValueRange{length});
        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.construct.list
//===----------------------------------------------------------------------===//

/// The pattern that lowers `eco.construct.list`, which makes a cons cell from a head and a tail.
///
/// The op's `head_kind` (0 boxed, 1 Int, 2 Float, 3 Char) goes into the cell's header, so that the collector
/// knows whether the head slot holds a pointer. When `inlineAllocEnabled()` the cell is allocated inline and
/// both slots are stored directly. Otherwise `eco_alloc_cons_uninit` allocates it with the head kind already
/// set, and the head and tail are stored by the `eco_store_cons_head*` and `eco_store_cons_tail` calls.
struct ListConstructOpLowering : public OpConversionPattern<ListConstructOp> {
    const EcoRuntime &runtime; ///< Declares the runtime functions and markers; must outlive the pattern.

    /// Creates the pattern, which keeps a reference to `runtime`.
    ListConstructOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                            const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(ListConstructOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);

        Value headLLVM = adaptor.getHead();
        Value tailVal  = adaptor.getTail();
        uint32_t headKind = static_cast<uint32_t>(op.getHeadKind()) & 0x3;

        // ListConstructOp::verify ties head_kind to the head's type, so storing by type stores what the kind
        // says. Nothing can collect before both stores, so the cell is not zeroed.
        if (inlineAllocEnabled()) {
            uint64_t header = value_enc::composeHeader(
                value_enc::TagCons, headKind, layout::ConsSize);
            Value consHPtr = emitInlineAllocWithHeader(
                rewriter, loc, runtime, layout::ConsSize, header);
            emitFreshFieldStore(rewriter, loc, consHPtr,
                layout::ConsHeadOffset, headLLVM, op.getHead().getType());
            emitFreshFieldStore(rewriter, loc, consHPtr,
                layout::ConsTailOffset, tailVal, op.getTail().getType());
            rewriter.replaceOp(op, consHPtr);
            return success();
        }

        auto headKindVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, headKind);

        // eco_alloc_cons_uninit sets head_kind and zeroes both slots, so the cell is valid for a collection
        // before the stores below.
        Value consHPtr = emitAllocWithSafepoint(
            op, rewriter, runtime,
            runtime.getOrCreateAllocConsUninit(rewriter),
            ValueRange{headKindVal});

        if (headKind == 0) {
            rewriter.create<LLVM::CallOp>(loc,
                runtime.getOrCreateStoreConsHead(rewriter),
                ValueRange{consHPtr, headLLVM});
        } else if (headKind == 2) {
            rewriter.create<LLVM::CallOp>(loc,
                runtime.getOrCreateStoreConsHeadF64(rewriter),
                ValueRange{consHPtr, headLLVM});
        } else {
            // kind == 1 (Int/i64) or 3 (Char/i32).
            Value widened = widenFieldToI64(headLLVM, loc, rewriter);
            rewriter.create<LLVM::CallOp>(loc,
                runtime.getOrCreateStoreConsHeadI64(rewriter),
                ValueRange{consHPtr, widened});
        }
        // The tail is always boxed.
        rewriter.create<LLVM::CallOp>(loc,
            runtime.getOrCreateStoreConsTail(rewriter),
            ValueRange{consHPtr, tailVal});
        rewriter.replaceOp(op, consHPtr);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.project.list_head
//===----------------------------------------------------------------------===//

/// The pattern that lowers `eco.project.list_head`, which reads the head of a non-empty list.
///
/// A value-level cons (an LLVM struct) gives its first element. An Int, Float or Char result is read by
/// `eco_cons_head_i64`, `eco_cons_head_f64` or `eco_cons_head_char`, which accept a head stored boxed or
/// unboxed. A boxed result is the `__eco_list_head_inline` marker in a module with `eco.list_chunks`, where the
/// node may be a chunk view, and otherwise an inline load of the head slot.
struct ListHeadOpLowering : public OpConversionPattern<ListHeadOp> {
    const EcoRuntime &runtime; ///< Declares the runtime functions and markers; must outlive the pattern.

    /// Creates the pattern, which keeps a reference to `runtime`.
    ListHeadOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                       const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(ListHeadOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Value input = adaptor.getList();

        Type origResultType = op.getResult().getType();

        if (isa<LLVM::LLVMStructType>(input.getType())) {
            Type resultType = getTypeConverter()->convertType(origResultType);
            Value result = rewriter.create<LLVM::ExtractValueOp>(
                loc, resultType, input, ArrayRef<int64_t>{0});
            rewriter.replaceOp(op, result);
            return success();
        }

        if (origResultType.isInteger(64)) {
            auto helperFunc = runtime.getOrCreateConsHeadI64(rewriter);
            auto call = rewriter.create<LLVM::CallOp>(loc, helperFunc, ValueRange{input});
            rewriter.replaceOp(op, call.getResult());
            return success();
        }
        if (origResultType.isF64()) {
            auto helperFunc = runtime.getOrCreateConsHeadF64(rewriter);
            auto call = rewriter.create<LLVM::CallOp>(loc, helperFunc, ValueRange{input});
            rewriter.replaceOp(op, call.getResult());
            return success();
        }
        if (eco::isEcoCharType(origResultType)) {
            auto helperFunc = runtime.getOrCreateConsHeadChar(rewriter);
            auto call = rewriter.create<LLVM::CallOp>(loc, helperFunc, ValueRange{input});
            rewriter.replaceOp(op, call.getResult());
            return success();
        }

        // The backend expands the marker into an inline load for a cons cell and a helper call for a chunk view.
        if (runtime.listChunks) {
            auto markerFunc = runtime.getOrCreateListHeadInlineMarker(rewriter);
            auto call = rewriter.create<LLVM::CallOp>(loc, markerFunc,
                                                      ValueRange{input});
            rewriter.replaceOp(op, call.getResult());
            return success();
        }

        rewriter.replaceOp(op, emitInlineBoxedLoad(input, layout::ConsHeadOffset,
                                                   loc, rewriter, runtime));
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.project.list_tail
//===----------------------------------------------------------------------===//

/// The pattern that lowers `eco.project.list_tail`, which reads the tail of a non-empty list.
///
/// A value-level cons gives its second element. In a module with `eco.list_chunks` the result is the
/// `__eco_list_tail_inline` marker, since the tail of a chunk view may be a new view that has to be allocated.
/// Otherwise it is an inline load of the tail slot.
struct ListTailOpLowering : public OpConversionPattern<ListTailOp> {
    const EcoRuntime &runtime; ///< Declares the runtime functions and markers; must outlive the pattern.

    /// Creates the pattern, which keeps a reference to `runtime`.
    ListTailOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                       const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(ListTailOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Value input = adaptor.getList();

        if (isa<LLVM::LLVMStructType>(input.getType())) {
            Type resultType = getTypeConverter()->convertType(op.getResult().getType());
            Value result = rewriter.create<LLVM::ExtractValueOp>(
                loc, resultType, input, ArrayRef<int64_t>{1});
            rewriter.replaceOp(op, result);
            return success();
        }

        // The backend expands the marker into an inline load for a cons cell and, for a chunk view, a call that
        // may allocate.
        if (runtime.listChunks) {
            auto markerFunc = runtime.getOrCreateListTailInlineMarker(rewriter);
            auto call = rewriter.create<LLVM::CallOp>(loc, markerFunc,
                                                      ValueRange{input});
            rewriter.replaceOp(op, call.getResult());
            return success();
        }

        rewriter.replaceOp(op, emitInlineBoxedLoad(input, layout::ConsTailOffset,
                                                   loc, rewriter, runtime));
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Field widening
//===----------------------------------------------------------------------===//

/// Returns `val` as the 64-bit word a heap slot holds: a `ptr addrspace(1)` through `heapStoreValueToI64`, a
/// narrower integer zero-extended, an f64 bitcast, and anything else, an i64 included, unchanged.
///
/// The word of a boxed value is not tracked by the collector, so the caller must use it at once, in a store or
/// as an argument to a gc-leaf call. EcoToLLVMValueAgg.cpp has its own copy of this function; the two must
/// change together.
static Value widenFieldToI64(Value val, Location loc,
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

//===----------------------------------------------------------------------===//
// eco.construct.tuple2
//===----------------------------------------------------------------------===//

/// The pattern that lowers `eco.construct.tuple2`.
///
/// The op's `unboxed_bitmap`, two bits of slot kind per field, is copied into the header. When
/// `inlineAllocEnabled()` the tuple is allocated inline and both fields are stored directly. Otherwise
/// `eco_alloc_tuple2_uninit` allocates it, and the fields are stored directly when `inlineDerefExtEnabled()`,
/// or else by the `eco_store_tuple_field*` calls. Each field's word is chosen by the type its operand had
/// before conversion.
struct Tuple2ConstructOpLowering : public OpConversionPattern<Tuple2ConstructOp> {
    const EcoRuntime &runtime; ///< Declares the runtime functions and markers; must outlive the pattern.

    /// Creates the pattern, which keeps a reference to `runtime`.
    Tuple2ConstructOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                              const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(Tuple2ConstructOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);

        // Boxed operands stay `ptr addrspace(1)` across the allocation call, so RS4GC relocates them.
        Value aLLVM = adaptor.getA();
        Value bLLVM = adaptor.getB();
        Type aOrig = op.getA().getType();
        Type bOrig = op.getB().getType();

        int64_t unboxedMask = op.getUnboxedBitmap();

        // A tuple's header size field holds its byte size.
        if (inlineAllocEnabled()) {
            uint64_t header = value_enc::composeHeader(
                value_enc::TagTuple2,
                static_cast<uint64_t>(unboxedMask) & 0xF,
                layout::Tuple2Size);
            Value tuple = emitInlineAllocWithHeader(
                rewriter, loc, runtime, layout::Tuple2Size, header);
            emitFreshFieldStore(rewriter, loc, tuple,
                layout::Tuple2FirstOffset, aLLVM, aOrig);
            emitFreshFieldStore(rewriter, loc, tuple,
                layout::Tuple2FirstOffset + layout::PtrSize, bLLVM, bOrig);
            rewriter.replaceOp(op, tuple);
            return success();
        }

        auto unboxedVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
            static_cast<int32_t>(unboxedMask));

        Value tuple = emitAllocWithSafepoint(
            op, rewriter, runtime,
            runtime.getOrCreateAllocTuple2Uninit(rewriter),
            ValueRange{unboxedVal});

        auto storeFieldBoxed = runtime.getOrCreateStoreTupleField(rewriter);
        auto storeFieldI64   = runtime.getOrCreateStoreTupleFieldI64(rewriter);
        auto storeFieldF64   = runtime.getOrCreateStoreTupleFieldF64(rewriter);

        auto storeOne = [&](unsigned idx, Value v, Type origTy) {
            // A fresh tuple may be written directly (HEAP_031).
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
                Value widened = widenFieldToI64(v, loc, rewriter);
                rewriter.create<LLVM::CallOp>(loc, storeFieldI64,
                    ValueRange{tuple, idxVal, widened});
            } else {
                    rewriter.create<LLVM::CallOp>(loc, storeFieldBoxed,
                    ValueRange{tuple, idxVal, v});
            }
        };
        storeOne(0, aLLVM, aOrig);
        storeOne(1, bLLVM, bOrig);
        rewriter.replaceOp(op, tuple);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.construct.tuple3
//===----------------------------------------------------------------------===//

/// The pattern that lowers `eco.construct.tuple3`, as `Tuple2ConstructOpLowering` does for two fields.
struct Tuple3ConstructOpLowering : public OpConversionPattern<Tuple3ConstructOp> {
    const EcoRuntime &runtime; ///< Declares the runtime functions and markers; must outlive the pattern.

    /// Creates the pattern, which keeps a reference to `runtime`.
    Tuple3ConstructOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                              const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(Tuple3ConstructOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);

        Value aLLVM = adaptor.getA();
        Value bLLVM = adaptor.getB();
        Value cLLVM = adaptor.getC();
        Type aOrig = op.getA().getType();
        Type bOrig = op.getB().getType();
        Type cOrig = op.getC().getType();

        int64_t unboxedMask = op.getUnboxedBitmap();

        if (inlineAllocEnabled()) {
            uint64_t header = value_enc::composeHeader(
                value_enc::TagTuple3,
                static_cast<uint64_t>(unboxedMask) & 0x3F,
                layout::Tuple3Size);
            Value tuple = emitInlineAllocWithHeader(
                rewriter, loc, runtime, layout::Tuple3Size, header);
            emitFreshFieldStore(rewriter, loc, tuple,
                layout::Tuple3FirstOffset, aLLVM, aOrig);
            emitFreshFieldStore(rewriter, loc, tuple,
                layout::Tuple3FirstOffset + layout::PtrSize, bLLVM, bOrig);
            emitFreshFieldStore(rewriter, loc, tuple,
                layout::Tuple3FirstOffset + 2 * layout::PtrSize, cLLVM, cOrig);
            rewriter.replaceOp(op, tuple);
            return success();
        }

        auto unboxedVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
            static_cast<int32_t>(unboxedMask));

        Value tuple = emitAllocWithSafepoint(
            op, rewriter, runtime,
            runtime.getOrCreateAllocTuple3Uninit(rewriter),
            ValueRange{unboxedVal});

        auto storeFieldBoxed = runtime.getOrCreateStoreTupleField(rewriter);
        auto storeFieldI64   = runtime.getOrCreateStoreTupleFieldI64(rewriter);
        auto storeFieldF64   = runtime.getOrCreateStoreTupleFieldF64(rewriter);

        auto storeOne = [&](unsigned idx, Value v, Type origTy) {
            // A fresh tuple may be written directly (HEAP_031).
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
                Value widened = widenFieldToI64(v, loc, rewriter);
                rewriter.create<LLVM::CallOp>(loc, storeFieldI64,
                    ValueRange{tuple, idxVal, widened});
            } else {
                rewriter.create<LLVM::CallOp>(loc, storeFieldBoxed,
                    ValueRange{tuple, idxVal, v});
            }
        };
        storeOne(0, aLLVM, aOrig);
        storeOne(1, bLLVM, bOrig);
        storeOne(2, cLLVM, cOrig);
        rewriter.replaceOp(op, tuple);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.project.tuple2
//===----------------------------------------------------------------------===//

/// The pattern that lowers `eco.project.tuple2`, which reads field 0 or 1 of a tuple.
///
/// A value-level aggregate (an LLVM struct) gives its element. Otherwise the slot is loaded through the
/// forwarding check, as an `!eco.value` or as an i64, f64 or i32; any other result type, Bool included,
/// fails with an error.
struct Tuple2ProjectOpLowering : public OpConversionPattern<Tuple2ProjectOp> {
    const EcoRuntime &runtime; ///< Declares the runtime functions and markers; must outlive the pattern.

    /// Creates the pattern, which keeps a reference to `runtime`.
    Tuple2ProjectOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                            const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(Tuple2ProjectOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Value input = adaptor.getTuple();
        int64_t field = op.getField();
        Type resultType = getTypeConverter()->convertType(op.getResult().getType());

        if (isa<LLVM::LLVMStructType>(input.getType())) {
            Value result = rewriter.create<LLVM::ExtractValueOp>(
                loc, resultType, input, ArrayRef<int64_t>{field});
            rewriter.replaceOp(op, result);
            return success();
        }

        int64_t offsetBytes = layout::Tuple2FirstOffset + field * layout::PtrSize;

        if (!isHPtrLLVMType(resultType) && !resultType.isInteger(64) &&
            !resultType.isF64() && !eco::isEcoCharType(resultType))
            return op.emitOpError(
                "unsupported primitive type for eco.project.tuple2 — "
                "Bool must go through !eco.value + eco.unbox");

        Value result = isHPtrLLVMType(resultType)
            ? emitInlineBoxedLoad(input, offsetBytes, loc, rewriter, runtime)
            : emitInlinePrimLoad(input, offsetBytes, resultType, loc,
                                 rewriter, runtime);
        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.project.tuple3
//===----------------------------------------------------------------------===//

/// The pattern that lowers `eco.project.tuple3`, which reads field 0, 1 or 2 of a tuple.
///
/// A value-level aggregate (an LLVM struct) gives its element. Otherwise the slot is loaded through the
/// forwarding check, as an `!eco.value` or as an i64, f64 or i32; any other result type, Bool included,
/// fails with an error.
struct Tuple3ProjectOpLowering : public OpConversionPattern<Tuple3ProjectOp> {
    const EcoRuntime &runtime; ///< Declares the runtime functions and markers; must outlive the pattern.

    /// Creates the pattern, which keeps a reference to `runtime`.
    Tuple3ProjectOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                            const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(Tuple3ProjectOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Value input = adaptor.getTuple();
        int64_t field = op.getField();
        Type resultType = getTypeConverter()->convertType(op.getResult().getType());

        if (isa<LLVM::LLVMStructType>(input.getType())) {
            Value result = rewriter.create<LLVM::ExtractValueOp>(
                loc, resultType, input, ArrayRef<int64_t>{field});
            rewriter.replaceOp(op, result);
            return success();
        }

        int64_t offsetBytes = layout::Tuple3FirstOffset + field * layout::PtrSize;

        if (!isHPtrLLVMType(resultType) && !resultType.isInteger(64) &&
            !resultType.isF64() && !eco::isEcoCharType(resultType))
            return op.emitOpError(
                "unsupported primitive type for eco.project.tuple3 — "
                "Bool must go through !eco.value + eco.unbox");

        Value result = isHPtrLLVMType(resultType)
            ? emitInlineBoxedLoad(input, offsetBytes, loc, rewriter, runtime)
            : emitInlinePrimLoad(input, offsetBytes, resultType, loc,
                                 rewriter, runtime);
        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.construct.record
//===----------------------------------------------------------------------===//

/// The pattern that lowers `eco.construct.record`.
///
/// Each slot's kind comes from the type its operand had before conversion; the op's kind attributes are only
/// checked by the verifier. The first `layout::RecordHdrSlots` kinds are packed into the word after the header,
/// and the rest into extension kind words after the last field (HEAP_019). When `inlineAllocEnabled()`, a
/// record of at most 4096 bytes is allocated inline, and its kind word, fields and extension words are stored
/// directly. Otherwise `eco_alloc_record` allocates it with the packed kinds, and the fields and extension
/// words are stored directly when `inlineDerefExtEnabled()`, or else by the `eco_store_record_field*` calls.
struct RecordConstructOpLowering : public OpConversionPattern<RecordConstructOp> {
    const EcoRuntime &runtime; ///< Declares the runtime functions and markers; must outlive the pattern.

    /// Creates the pattern, which keeps a reference to `runtime`.
    RecordConstructOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                              const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(RecordConstructOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i64Ty = IntegerType::get(ctx, 64);

        auto storeFunc = runtime.getOrCreateStoreRecordField(rewriter);
        auto storeI64Func = runtime.getOrCreateStoreRecordFieldI64(rewriter);
        auto storeF64Func = runtime.getOrCreateStoreRecordFieldF64(rewriter);

        int64_t fieldCount = op.getFieldCount();
        PackedKinds pk = packKinds(
            slotKindsOfTypes(op.getFields().getTypes()),
            layout::RecordHdrSlots);
        const uint64_t K = pk.ext.size();
        int64_t unboxedBitmap = static_cast<int64_t>(pk.hdrBits);

        auto fields = adaptor.getFields();

        // The header's size field holds the field count, and its unboxed field the number of extension words.
        // 4096 bytes is the largest object the inline expansion accepts.
        uint64_t recByteSize = layout::recordByteSize(static_cast<uint64_t>(fieldCount));
        if (inlineAllocEnabled() && recByteSize <= 4096) {
            uint64_t header = value_enc::composeHeader(
                value_enc::TagRecord, K, static_cast<uint64_t>(fieldCount));
            Value objHPtr = emitInlineAllocWithHeader(
                rewriter, loc, runtime, recByteSize, header);
            emitInlineAllocMetaWord(rewriter, loc, objHPtr,
                                    static_cast<uint64_t>(unboxedBitmap));
            auto origFieldsInl = op.getFields();
            for (int64_t i = 0; i < fieldCount; i++) {
                emitFreshFieldStore(rewriter, loc, objHPtr,
                    layout::RecordFieldsOffset + i * layout::PtrSize,
                    fields[i], origFieldsInl[i].getType());
            }
            emitExtKindWordStores(rewriter, loc, objHPtr, layout::RecordFieldsOffset,
                                  static_cast<uint64_t>(fieldCount), pk.ext);
            rewriter.replaceOp(op, objHPtr);
            return success();
        }

        auto fieldCountVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
            static_cast<int32_t>(fieldCount));
        auto unboxedBitmapVal = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, unboxedBitmap);

        Value objHPtr = emitAllocWithSafepoint(
            op, rewriter, runtime,
            runtime.getOrCreateAllocRecord(rewriter),
            ValueRange{fieldCountVal, unboxedBitmapVal});

        auto origFields = op.getFields();
        for (int64_t i = 0; i < fieldCount; i++) {
            Type origType = origFields[i].getType();
            Value fieldVal = fields[i];
            // A fresh record may be written directly (HEAP_031).
            if (inlineDerefExtEnabled()) {
                emitFreshFieldStore(rewriter, loc, objHPtr,
                    layout::RecordFieldsOffset + i * layout::PtrSize, fieldVal, origType);
                continue;
            }
            auto idx = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(i));

            if (origType.isF64()) {
                rewriter.create<LLVM::CallOp>(loc, storeF64Func,
                    ValueRange{objHPtr, idx, fieldVal});
            } else if (origType.isInteger(64)) {
                rewriter.create<LLVM::CallOp>(loc, storeI64Func,
                    ValueRange{objHPtr, idx, fieldVal});
            } else if (origType.isInteger(1) || eco::isEcoCharType(origType)) {
                Value widened = widenFieldToI64(fieldVal, loc, rewriter);
                rewriter.create<LLVM::CallOp>(loc, storeI64Func,
                    ValueRange{objHPtr, idx, widened});
            } else {
                // A boxed field is passed as `ptr addrspace(1)`.
                rewriter.create<LLVM::CallOp>(loc, storeFunc,
                    ValueRange{objHPtr, idx, fieldVal});
            }
        }
        emitExtKindWordStoresCall(rewriter, loc, objHPtr, layout::RecordFieldsOffset,
                                  static_cast<uint64_t>(fieldCount), pk.ext, storeI64Func);

        rewriter.replaceOp(op, objHPtr);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.project.record
//===----------------------------------------------------------------------===//

/// The pattern that lowers `eco.project.record`, which reads a field of a record by index.
///
/// A value-level aggregate (an LLVM struct) gives its element. Otherwise the slot is loaded through the
/// forwarding check, as an `!eco.value` or as an i64, f64 or i32; any other result type, Bool included,
/// fails with an error.
struct RecordProjectOpLowering : public OpConversionPattern<RecordProjectOp> {
    const EcoRuntime &runtime; ///< Declares the runtime functions and markers; must outlive the pattern.

    /// Creates the pattern, which keeps a reference to `runtime`.
    RecordProjectOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                            const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(RecordProjectOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Value input = adaptor.getRecord();
        int64_t index = op.getFieldIndex();
        Type resultType = getTypeConverter()->convertType(op.getResult().getType());

        if (isa<LLVM::LLVMStructType>(input.getType())) {
            Value result = rewriter.create<LLVM::ExtractValueOp>(
                loc, resultType, input, ArrayRef<int64_t>{index});
            rewriter.replaceOp(op, result);
            return success();
        }

        int64_t offsetBytes = layout::RecordFieldsOffset + index * layout::PtrSize;

        if (!isHPtrLLVMType(resultType) && !resultType.isInteger(64) &&
            !resultType.isF64() && !eco::isEcoCharType(resultType))
            return op.emitOpError(
                "unsupported primitive type for eco.project.record — "
                "Bool must go through !eco.value + eco.unbox");

        Value result = isHPtrLLVMType(resultType)
            ? emitInlineBoxedLoad(input, offsetBytes, loc, rewriter, runtime)
            : emitInlinePrimLoad(input, offsetBytes, resultType, loc,
                                 rewriter, runtime);
        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.construct.custom
//===----------------------------------------------------------------------===//

/// The pattern that lowers `eco.construct.custom`, which makes a value of a custom type from a constructor tag
/// and its fields.
///
/// Kinds are found and packed as for a record, with `layout::CustomHdrSlots` kinds in the header word. When
/// `inlineAllocEnabled()`, a value of at most 4096 bytes is allocated inline, and the word after its header
/// holds the constructor tag in its low 16 bits and the packed kinds above them. Otherwise `eco_alloc_custom`
/// allocates it from the tag and field count, the fields and extension words are stored as for a record, and
/// `eco_set_unboxed` then writes the packed kinds if any of them is not boxed.
struct CustomConstructOpLowering : public OpConversionPattern<CustomConstructOp> {
    const EcoRuntime &runtime; ///< Declares the runtime functions and markers; must outlive the pattern.

    /// Creates the pattern, which keeps a reference to `runtime`.
    CustomConstructOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                              const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(CustomConstructOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i64Ty = IntegerType::get(ctx, 64);

        auto storeFunc = runtime.getOrCreateStoreField(rewriter);
        auto storeI64Func = runtime.getOrCreateStoreFieldI64(rewriter);
        auto storeF64Func = runtime.getOrCreateStoreFieldF64(rewriter);
        auto setUnboxedFunc = runtime.getOrCreateSetUnboxed(rewriter);

        int64_t opSize = op.getSize();
        PackedKinds pk = packKinds(
            slotKindsOfTypes(op.getFields().getTypes()),
            layout::CustomHdrSlots);
        const uint64_t K = pk.ext.size();

        // As for a record; the meta word also carries the constructor tag.
        uint64_t cusByteSize = layout::customByteSize(static_cast<uint64_t>(opSize));
        if (inlineAllocEnabled() && cusByteSize <= 4096) {
            uint64_t bitmap = pk.hdrBits;
            assert((bitmap >> 48) == 0 && "Custom unboxed bitmap overflow (>48 bits)");
            uint64_t header = value_enc::composeHeader(
                value_enc::TagCustom, K, static_cast<uint64_t>(opSize));
            uint64_t meta = (static_cast<uint64_t>(op.getTag()) & 0xFFFF)
                          | (bitmap << 16);
            Value objHPtr = emitInlineAllocWithHeader(
                rewriter, loc, runtime, cusByteSize, header);
            emitInlineAllocMetaWord(rewriter, loc, objHPtr, meta);
            auto fieldsInl = adaptor.getFields();
            auto origFieldsInl = op.getFields();
            for (int64_t i = 0; i < opSize; i++) {
                emitFreshFieldStore(rewriter, loc, objHPtr,
                    layout::CustomFieldsOffset + i * layout::PtrSize,
                    fieldsInl[i], origFieldsInl[i].getType());
            }
            emitExtKindWordStores(rewriter, loc, objHPtr, layout::CustomFieldsOffset,
                                  static_cast<uint64_t>(opSize), pk.ext);
            rewriter.replaceOp(op, objHPtr);
            return success();
        }

        auto tag = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(op.getTag()));
        auto size = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(opSize));

        auto fields = adaptor.getFields();

        Value objHPtr = emitAllocWithSafepoint(
            op, rewriter, runtime,
            runtime.getOrCreateAllocCustom(rewriter),
            ValueRange{tag, size});

        auto origFields = op.getFields();
        for (int64_t i = 0; i < opSize; i++) {
            Type origType = origFields[i].getType();
            Value fieldVal = fields[i];
            // A fresh custom may be written directly (HEAP_031).
            if (inlineDerefExtEnabled()) {
                emitFreshFieldStore(rewriter, loc, objHPtr,
                    layout::CustomFieldsOffset + i * layout::PtrSize, fieldVal, origType);
                continue;
            }
            auto idx = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(i));

            if (origType.isF64()) {
                rewriter.create<LLVM::CallOp>(loc, storeF64Func,
                    ValueRange{objHPtr, idx, fieldVal});
            } else if (origType.isInteger(64)) {
                rewriter.create<LLVM::CallOp>(loc, storeI64Func,
                    ValueRange{objHPtr, idx, fieldVal});
            } else if (origType.isInteger(1) || eco::isEcoCharType(origType)) {
                Value widened = widenFieldToI64(fieldVal, loc, rewriter);
                rewriter.create<LLVM::CallOp>(loc, storeI64Func,
                    ValueRange{objHPtr, idx, widened});
            } else {
                // A boxed field is passed as `ptr addrspace(1)`.
                rewriter.create<LLVM::CallOp>(loc, storeFunc,
                    ValueRange{objHPtr, idx, fieldVal});
            }
        }

        emitExtKindWordStoresCall(rewriter, loc, objHPtr, layout::CustomFieldsOffset,
                                  static_cast<uint64_t>(opSize), pk.ext, storeI64Func);

        int64_t bitmap = static_cast<int64_t>(pk.hdrBits);
        if (bitmap != 0) {
            auto bitmapVal = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, bitmap);
            rewriter.create<LLVM::CallOp>(loc, setUnboxedFunc,
                ValueRange{objHPtr, bitmapVal});
        }

        rewriter.replaceOp(op, objHPtr);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.project.custom
//===----------------------------------------------------------------------===//

/// The pattern that lowers `eco.project.custom`, which reads a field of a custom value by index.
///
/// A value-level aggregate (an LLVM struct) gives its element. Otherwise the slot is loaded through the
/// forwarding check, as an `!eco.value` or as an i64, f64 or i32; any other result type, Bool included,
/// fails with an error.
struct CustomProjectOpLowering : public OpConversionPattern<CustomProjectOp> {
    const EcoRuntime &runtime; ///< Declares the runtime functions and markers; must outlive the pattern.

    /// Creates the pattern, which keeps a reference to `runtime`.
    CustomProjectOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                            const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(CustomProjectOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Value input = adaptor.getContainer();
        int64_t index = op.getFieldIndex();
        Type resultType = getTypeConverter()->convertType(op.getResult().getType());

        if (isa<LLVM::LLVMStructType>(input.getType())) {
            Value result = rewriter.create<LLVM::ExtractValueOp>(
                loc, resultType, input, ArrayRef<int64_t>{index});
            rewriter.replaceOp(op, result);
            return success();
        }

        int64_t offsetBytes = layout::CustomFieldsOffset + index * layout::PtrSize;

        if (!isHPtrLLVMType(resultType) && !resultType.isInteger(64) &&
            !resultType.isF64() && !eco::isEcoCharType(resultType))
            return op.emitOpError(
                "unsupported primitive type for eco.project.custom — "
                "Bool must go through !eco.value + eco.unbox");

        Value result = isHPtrLLVMType(resultType)
            ? emitInlineBoxedLoad(input, offsetBytes, loc, rewriter, runtime)
            : emitInlinePrimLoad(input, offsetBytes, resultType, loc,
                                 rewriter, runtime);
        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.array.length
//===----------------------------------------------------------------------===//

/// The pattern that lowers `eco.array.length`: the array's 32-bit length, read through the forwarding check
/// and zero-extended to an Int.
struct ArrayLengthOpLowering : public OpConversionPattern<ArrayLengthOp> {
    const EcoRuntime &runtime; ///< Declares the runtime functions and markers; must outlive the pattern.

    /// Creates the pattern, which keeps a reference to `runtime`.
    ArrayLengthOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                          const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(ArrayLengthOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i32Ty = IntegerType::get(ctx, 32);

        Value input = adaptor.getArray();

        auto offset = rewriter.create<LLVM::ConstantOp>(
            loc, i64Ty, static_cast<int64_t>(layout::ArrayLengthOffset));
        Value fieldPtr = emitInlineFieldPtr(input, offset, loc, rewriter, runtime);

        Value len32 = rewriter.create<LLVM::LoadOp>(loc, i32Ty, fieldPtr, 4);

        Value len64 = rewriter.create<LLVM::ZExtOp>(loc, i64Ty, len32);

        rewriter.replaceOp(op, len64);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.string.append / eco.list.append
//===----------------------------------------------------------------------===//

/// The pattern that lowers `eco.string.append` to a call of `eco_string_append`.
struct StringAppendOpLowering : public OpConversionPattern<StringAppendOp> {
    const EcoRuntime &runtime; ///< Declares the runtime functions and markers; must outlive the pattern.

    /// Creates the pattern, which keeps a reference to `runtime`.
    StringAppendOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                           const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(StringAppendOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto fn = runtime.getOrCreateStringAppend(rewriter);
        rewriter.replaceOpWithNewOp<LLVM::CallOp>(
            op, fn, ValueRange{adaptor.getLhs(), adaptor.getRhs()});
        return success();
    }
};

/// The pattern that lowers `eco.list.append` to a call of `eco_list_append`.
struct ListAppendOpLowering : public OpConversionPattern<ListAppendOp> {
    const EcoRuntime &runtime; ///< Declares the runtime functions and markers; must outlive the pattern.

    /// Creates the pattern, which keeps a reference to `runtime`.
    ListAppendOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                         const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(ListAppendOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto fn = runtime.getOrCreateListAppend(rewriter);
        rewriter.replaceOpWithNewOp<LLVM::CallOp>(
            op, fn, ValueRange{adaptor.getLhs(), adaptor.getRhs()});
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.string.length
//===----------------------------------------------------------------------===//

/// The pattern that lowers `eco.string.length` to the `__eco_string_len_inline` marker when
/// `stringLenInlineEnabled()`, and otherwise to a call of `Elm_Kernel_String_length`.
struct StringLengthOpLowering : public OpConversionPattern<StringLengthOp> {
    const EcoRuntime &runtime; ///< Declares the runtime functions and markers; must outlive the pattern.

    /// Creates the pattern, which keeps a reference to `runtime`.
    StringLengthOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                           const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(StringLengthOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto fn = stringLenInlineEnabled()
                      ? runtime.getOrCreateStringLenInlineMarker(rewriter)
                      : runtime.getOrCreateStringLength(rewriter);
        rewriter.replaceOpWithNewOp<LLVM::CallOp>(op, fn,
                                                  ValueRange{adaptor.getStr()});
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.array.get
//===----------------------------------------------------------------------===//

/// The pattern that lowers `eco.array.get`, which reads element `index` of an array.
///
/// The element is the slot `index` words past the start of the elements, read through the forwarding check as
/// an `!eco.value` or an i64, f64 or i32; any other element type fails with an error. `index` is not checked
/// against the length.
struct ArrayGetOpLowering : public OpConversionPattern<ArrayGetOp> {
    const EcoRuntime &runtime; ///< Declares the runtime functions and markers; must outlive the pattern.

    /// Creates the pattern, which keeps a reference to `runtime`.
    ArrayGetOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                       const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(ArrayGetOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);

        Value arrayVal = adaptor.getArray();
        Value indexVal = adaptor.getIndex();

        Type origResultType = op.getResult().getType();

        if (!isa<eco::ValueType>(origResultType) &&
            !origResultType.isInteger(64) && !origResultType.isF64() &&
            !eco::isEcoCharType(origResultType))
            return op.emitOpError("unsupported element type for eco.array.get");

        // Array elements are a uniform kind; both boxed and primitive reads are
        // a simple slot load.
        auto baseOffset = rewriter.create<LLVM::ConstantOp>(
            loc, i64Ty, static_cast<int64_t>(layout::ArrayElementsOffset));
        auto elemSize = rewriter.create<LLVM::ConstantOp>(
            loc, i64Ty, static_cast<int64_t>(layout::PtrSize));
        auto indexOffset = rewriter.create<LLVM::MulOp>(loc, i64Ty, indexVal, elemSize);
        auto totalOffset = rewriter.create<LLVM::AddOp>(loc, i64Ty, baseOffset, indexOffset);
        Value elemPtr = emitInlineFieldPtr(arrayVal, totalOffset, loc, rewriter, runtime);
        if (isa<eco::ValueType>(origResultType)) {
            Value raw = rewriter.create<LLVM::LoadOp>(loc, i64Ty, elemPtr,
                                                      layout::Alignment);
            rewriter.replaceOp(op, heapLoadI64ToValue(rewriter, loc, raw));
        } else {
            Type resultType = getTypeConverter()->convertType(origResultType);
            Value v = rewriter.create<LLVM::LoadOp>(loc, resultType, elemPtr,
                                                    layout::Alignment);
            rewriter.replaceOp(op, v);
        }
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.array.set
//===----------------------------------------------------------------------===//

/// The pattern that lowers `eco.array.set`, which returns a copy of an array with element `index` replaced.
///
/// `eco_clone_array` makes the copy. `eco_array_set_fix_kind` then sets the copy's element kind to that of the
/// new value, since a copy whose kind says boxed, such as one made from an empty array, would otherwise have
/// an Int element traced as a pointer. The element is stored directly into the copy, without the forwarding
/// check. `index` is not checked against the length.
struct ArraySetOpLowering : public OpConversionPattern<ArraySetOp> {
    const EcoRuntime &runtime; ///< Declares the runtime functions and markers; must outlive the pattern.

    /// Creates the pattern, which keeps a reference to `runtime`.
    ArraySetOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                       const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(ArraySetOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i8Ty = IntegerType::get(ctx, 8);

        Value arrayVal = adaptor.getArray();
        Value indexVal = adaptor.getIndex();
        Value valueVal = adaptor.getValue();

        auto cloneFunc = runtime.getOrCreateCloneArray(rewriter);
        auto cloneCall = rewriter.create<LLVM::CallOp>(loc, cloneFunc, ValueRange{arrayVal});
        Value newArrayHPtr = cloneCall.getResult();

        Type setValueType = op.getValue().getType();
        uint32_t intendedKind = 0;
        if (isa<eco::ValueType>(setValueType))      intendedKind = 0;
        else if (setValueType.isInteger(64))         intendedKind = 1;
        else if (setValueType.isF64())               intendedKind = 2;
        else if (eco::isEcoCharType(setValueType))         intendedKind = 3;
        auto kindConst = rewriter.create<LLVM::ConstantOp>(
            loc, IntegerType::get(ctx, 32),
            static_cast<int64_t>(intendedKind));
        auto fixKindFn = runtime.getOrCreateArraySetFixKind(rewriter);
        rewriter.create<LLVM::CallOp>(
            loc, fixKindFn, ValueRange{newArrayHPtr, kindConst});

        auto baseOffset = rewriter.create<LLVM::ConstantOp>(
            loc, i64Ty, static_cast<int64_t>(layout::ArrayElementsOffset));
        auto elemSize = rewriter.create<LLVM::ConstantOp>(
            loc, i64Ty, static_cast<int64_t>(layout::PtrSize));
        auto indexOffset = rewriter.create<LLVM::MulOp>(loc, i64Ty, indexVal, elemSize);
        auto totalOffset = rewriter.create<LLVM::AddOp>(loc, i64Ty, baseOffset, indexOffset);
        // The copy was made by the clone call above, so the pointer is used without the forwarding check.
        auto hptrTy = getHPtrLLVMType(*ctx);
        Value elemPtr = rewriter.create<LLVM::GEPOp>(loc, hptrTy, i8Ty, newArrayHPtr,
                                                     ValueRange{totalOffset});

        Type origValueType = op.getValue().getType();
        Value raw;
        if (isa<eco::ValueType>(origValueType)) {
            raw = heapStoreValueToI64(rewriter, loc, valueVal);
        } else if (origValueType.isInteger(64)) {
            raw = valueVal;
        } else if (origValueType.isF64()) {
            raw = rewriter.create<LLVM::BitcastOp>(loc, i64Ty, valueVal);
        } else if (eco::isEcoCharType(origValueType)) {
            raw = rewriter.create<LLVM::ZExtOp>(loc, i64Ty, valueVal);
        } else {
            return op.emitError("unsupported value type for eco.array.set");
        }

        // A boxed store is tagged `eco.boxed_slot`, which EcoBoxedStoreVerify reads.
        auto storeOp = rewriter.create<LLVM::StoreOp>(loc, raw, elemPtr,
                                                      layout::Alignment);
        if (isa<eco::ValueType>(origValueType))
            storeOp->setAttr("eco.boxed_slot", rewriter.getUnitAttr());

        rewriter.replaceOp(op, newArrayHPtr);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.array.empty / singleton / push / slice / append_n
//===----------------------------------------------------------------------===//

/// The pattern that lowers `eco.array.empty` to a call of `elm_array_empty`.
struct ArrayEmptyOpLowering : public OpConversionPattern<ArrayEmptyOp> {
    const EcoRuntime &runtime; ///< Declares the runtime functions and markers; must outlive the pattern.
    /// Creates the pattern, which keeps a reference to `runtime`.
    ArrayEmptyOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                         const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(ArrayEmptyOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto fn = runtime.getOrCreateArrayEmpty(rewriter);
        auto call = rewriter.create<LLVM::CallOp>(op.getLoc(), fn, ValueRange{});
        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

/// The pattern that lowers `eco.array.singleton` to a call of `elm_array_singleton_int`, `_float`, `_char` or
/// `_box`, chosen by the element's type before conversion. Any other type fails with an error.
struct ArraySingletonOpLowering : public OpConversionPattern<ArraySingletonOp> {
    const EcoRuntime &runtime; ///< Declares the runtime functions and markers; must outlive the pattern.
    /// Creates the pattern, which keeps a reference to `runtime`.
    ArraySingletonOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                             const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(ArraySingletonOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        Type origValueType = op.getValue().getType();
        Value v = adaptor.getValue();
        LLVM::LLVMFuncOp fn;
        if (origValueType.isInteger(64)) {
            fn = runtime.getOrCreateArraySingletonInt(rewriter);
        } else if (origValueType.isF64()) {
            fn = runtime.getOrCreateArraySingletonFloat(rewriter);
        } else if (eco::isEcoCharType(origValueType)) {
            fn = runtime.getOrCreateArraySingletonChar(rewriter);
        } else if (isa<eco::ValueType>(origValueType)) {
            fn = runtime.getOrCreateArraySingletonBox(rewriter);
        } else {
            return op.emitError("unsupported element type for eco.array.singleton");
        }
        auto call = rewriter.create<LLVM::CallOp>(op.getLoc(), fn, ValueRange{v});
        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

/// The pattern that lowers `eco.array.push` to a call of `elm_array_push_int`, `_float`, `_char` or `_box`,
/// chosen by the element's type before conversion. Any other type fails with an error.
struct ArrayPushOpLowering : public OpConversionPattern<ArrayPushOp> {
    const EcoRuntime &runtime; ///< Declares the runtime functions and markers; must outlive the pattern.
    /// Creates the pattern, which keeps a reference to `runtime`.
    ArrayPushOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                        const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(ArrayPushOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        Type origValueType = op.getValue().getType();
        Value v = adaptor.getValue();
        Value arr = adaptor.getArray();
        LLVM::LLVMFuncOp fn;
        if (origValueType.isInteger(64)) {
            fn = runtime.getOrCreateArrayPushInt(rewriter);
        } else if (origValueType.isF64()) {
            fn = runtime.getOrCreateArrayPushFloat(rewriter);
        } else if (eco::isEcoCharType(origValueType)) {
            fn = runtime.getOrCreateArrayPushChar(rewriter);
        } else if (isa<eco::ValueType>(origValueType)) {
            fn = runtime.getOrCreateArrayPushBox(rewriter);
        } else {
            return op.emitError("unsupported element type for eco.array.push");
        }
        auto call = rewriter.create<LLVM::CallOp>(op.getLoc(), fn,
                                                   ValueRange{v, arr});
        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

/// The pattern that lowers `eco.array.slice` to a call of `elm_array_slice`.
struct ArraySliceOpLowering : public OpConversionPattern<ArraySliceOp> {
    const EcoRuntime &runtime; ///< Declares the runtime functions and markers; must outlive the pattern.
    /// Creates the pattern, which keeps a reference to `runtime`.
    ArraySliceOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                         const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(ArraySliceOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto fn = runtime.getOrCreateArraySlice(rewriter);
        auto call = rewriter.create<LLVM::CallOp>(
            op.getLoc(), fn,
            ValueRange{adaptor.getStart(), adaptor.getEnd(), adaptor.getArray()});
        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

/// The pattern that lowers `eco.array.append_n` to a call of `elm_array_append_n`.
struct ArrayAppendNOpLowering : public OpConversionPattern<ArrayAppendNOp> {
    const EcoRuntime &runtime; ///< Declares the runtime functions and markers; must outlive the pattern.
    /// Creates the pattern, which keeps a reference to `runtime`.
    ArrayAppendNOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                           const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(ArrayAppendNOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto fn = runtime.getOrCreateArrayAppendN(rewriter);
        auto call = rewriter.create<LLVM::CallOp>(
            op.getLoc(), fn,
            ValueRange{adaptor.getN(), adaptor.getDest(), adaptor.getSource()});
        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.string.from_int / from_float
//===----------------------------------------------------------------------===//

/// The pattern that lowers `eco.string.from_int` to a call of `elm_string_from_int`.
struct StringFromIntOpLowering : public OpConversionPattern<StringFromIntOp> {
    const EcoRuntime &runtime; ///< Declares the runtime functions and markers; must outlive the pattern.
    /// Creates the pattern, which keeps a reference to `runtime`.
    StringFromIntOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                            const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(StringFromIntOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto fn = runtime.getOrCreateStringFromInt(rewriter);
        auto call = rewriter.create<LLVM::CallOp>(op.getLoc(), fn,
                                                   ValueRange{adaptor.getValue()});
        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

/// The pattern that lowers `eco.string.from_float` to a call of `elm_string_from_double`.
struct StringFromFloatOpLowering : public OpConversionPattern<StringFromFloatOp> {
    const EcoRuntime &runtime; ///< Declares the runtime functions and markers; must outlive the pattern.
    /// Creates the pattern, which keeps a reference to `runtime`.
    StringFromFloatOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                              const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(StringFromFloatOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto fn = runtime.getOrCreateStringFromDouble(rewriter);
        auto call = rewriter.create<LLVM::CallOp>(op.getLoc(), fn,
                                                   ValueRange{adaptor.getValue()});
        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

} // namespace

//===----------------------------------------------------------------------===//
// Allocation group lowering
//===----------------------------------------------------------------------===//

/// Returns `v` as an i64 slot word: unchanged if it is an i64, through `slotValueToI64` if it is a
/// `ptr addrspace(1)` or an unrealized cast of one, and otherwise as a new unrealized cast to i64.
static Value castToI64(OpBuilder &builder, Location loc, Value v) {
    if (v.getType().isInteger(64))
        return v;
    if (isHPtrLLVMType(v.getType())) {
        return slotValueToI64(builder, loc, v);
    }
    if (auto castOp = v.getDefiningOp<UnrealizedConversionCastOp>()) {
        if (castOp.getNumOperands() == 1 &&
            isHPtrLLVMType(castOp.getOperand(0).getType())) {
            return slotValueToI64(builder, loc, castOp.getOperand(0));
        }
    }
    auto i64Ty = IntegerType::get(builder.getContext(), 64);
    return builder.create<UnrealizedConversionCastOp>(loc, i64Ty, v)
        .getResult(0);
}

/// Returns `v` as a `ptr addrspace(1)`: unchanged if it is one, decoded by `slotI64ToValue` if it is an i64 slot
/// word, the operand of an unrealized cast from a `ptr addrspace(1)`, and otherwise a new unrealized cast.
static Value castToHPtr(OpBuilder &builder, Location loc, Value v) {
    if (isHPtrLLVMType(v.getType()))
        return v;
    auto hptrTy = LLVM::LLVMPointerType::get(builder.getContext(), /*addressSpace=*/1);
    if (v.getType().isInteger(64))
        return slotI64ToValue(builder, loc, v);
    if (auto castOp = v.getDefiningOp<UnrealizedConversionCastOp>()) {
        if (castOp.getNumOperands() == 1 &&
            isHPtrLLVMType(castOp.getOperand(0).getType()))
            return castOp.getOperand(0);
    }
    return builder.create<UnrealizedConversionCastOp>(loc, hptrTy, v)
        .getResult(0);
}

/// Returns `v` as the 64-bit word an `eco_init_*_at` call takes for a field: an i64 unchanged, a
/// `ptr addrspace(1)` or `!eco.value` through `slotValueToI64`, a narrower integer zero-extended, an f64
/// bitcast, and anything else through `castToI64`.
static Value widenToI64ForInit(OpBuilder &builder, Location loc, Value v) {
    auto i64Ty = IntegerType::get(builder.getContext(), 64);
    Type ty = v.getType();
    if (ty.isInteger(64)) return v;
    if (isHPtrLLVMType(ty))
        return slotValueToI64(builder, loc, v);
    if (isa<eco::ValueType>(ty)) {
        // Go through ptr<1> first, then to i64. This avoids creating
        // eco.value→i64 unrealized casts that become unresolvable when
        // the eco.value is later replaced by a ptr<1> materialization.
        Value hptr = castToHPtr(builder, loc, v);
        return slotValueToI64(builder, loc, hptr);
    }
    if (auto intTy = dyn_cast<IntegerType>(ty)) {
        if (intTy.getWidth() < 64)
            return builder.create<LLVM::ZExtOp>(loc, i64Ty, v);
    }
    if (ty.isF64())
        return builder.create<LLVM::BitcastOp>(loc, i64Ty, v);
    return castToI64(builder, loc, v);
}

/// Initialises the group member `op` at `objPtr`, a raw pointer into the group's region, with the matching
/// gc-leaf `eco_init_*_at` call, and returns the object's `ptr addrspace(1)`.
///
/// A record's or custom's fields are not stored here but by `emitFieldStoresForOp`, in the merge block, so that
/// they are emitted once rather than on both paths. `op` must be a box of an Int, Float or Char, an
/// `eco.allocate_string`, or a cons, tuple, record or custom construction; anything else reaches
/// `llvm_unreachable`.
static Value emitInitAtPtr(
    OpBuilder &builder, Location loc,
    Operation *op, Value objPtr,
    const EcoRuntime &runtime) {

    auto *ctx = builder.getContext();
    auto i32Ty = IntegerType::get(ctx, 32);
    auto i64Ty = IntegerType::get(ctx, 64);

    if (auto boxOp = dyn_cast<BoxOp>(op)) {
        Type inputType = boxOp.getValue().getType();
        Value input = boxOp.getValue();
        if (inputType.isInteger(64)) {
            return builder.create<LLVM::CallOp>(
                loc, runtime.getOrCreateInitIntAt(builder),
                ValueRange{objPtr, input}).getResult();
        }
        if (inputType.isF64()) {
            return builder.create<LLVM::CallOp>(
                loc, runtime.getOrCreateInitFloatAt(builder),
                ValueRange{objPtr, input}).getResult();
        }
        if (eco::isEcoCharType(inputType)) {
            // Char is already the i32 code point eco_init_char_at takes.
            return builder.create<LLVM::CallOp>(
                loc, runtime.getOrCreateInitCharAt(builder),
                ValueRange{objPtr, input}).getResult();
        }
        llvm_unreachable("unsupported BoxOp input type in group");
    }

    if (auto allocStr = dyn_cast<AllocateStringOp>(op)) {
        auto length = builder.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(allocStr.getLength()));
        return builder.create<LLVM::CallOp>(
            loc, runtime.getOrCreateInitStringAt(builder),
            ValueRange{objPtr, length}).getResult();
    }

    if (auto listOp = dyn_cast<ListConstructOp>(op)) {
        Value head = widenToI64ForInit(builder, loc, listOp.getHead());
        Value tail = castToHPtr(builder, loc, listOp.getTail());
        uint32_t headKind = static_cast<uint32_t>(listOp.getHeadKind()) & 0x3;
        auto headUnboxedVal = builder.create<LLVM::ConstantOp>(loc, i32Ty, headKind);
        return builder.create<LLVM::CallOp>(
            loc, runtime.getOrCreateInitConsAt(builder),
            ValueRange{objPtr, head, tail, headUnboxedVal}).getResult();
    }

    if (auto tuple2Op = dyn_cast<Tuple2ConstructOp>(op)) {
        Value a = widenToI64ForInit(builder, loc, tuple2Op.getA());
        Value b = widenToI64ForInit(builder, loc, tuple2Op.getB());
        auto unboxed = builder.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(tuple2Op.getUnboxedBitmap()));
        return builder.create<LLVM::CallOp>(
            loc, runtime.getOrCreateInitTuple2At(builder),
            ValueRange{objPtr, a, b, unboxed}).getResult();
    }

    if (auto tuple3Op = dyn_cast<Tuple3ConstructOp>(op)) {
        Value a = widenToI64ForInit(builder, loc, tuple3Op.getA());
        Value b = widenToI64ForInit(builder, loc, tuple3Op.getB());
        Value c = widenToI64ForInit(builder, loc, tuple3Op.getC());
        auto unboxed = builder.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(tuple3Op.getUnboxedBitmap()));
        return builder.create<LLVM::CallOp>(
            loc, runtime.getOrCreateInitTuple3At(builder),
            ValueRange{objPtr, a, b, c, unboxed}).getResult();
    }

    if (auto recOp = dyn_cast<RecordConstructOp>(op)) {
        auto fieldCount = builder.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(recOp.getFieldCount()));
        // Kinds from the operand types. eco_init_record_at zeroes the object, extension words included.
        const uint64_t hdrBits = packKinds(
            slotKindsOfTypes(recOp.getFields().take_front(recOp.getFieldCount()).getTypes()),
            layout::RecordHdrSlots).hdrBits;
        auto unboxedBitmap = builder.create<LLVM::ConstantOp>(
            loc, i64Ty, static_cast<int64_t>(hdrBits));
        return builder.create<LLVM::CallOp>(
            loc, runtime.getOrCreateInitRecordAt(builder),
            ValueRange{objPtr, fieldCount, unboxedBitmap}).getResult();
    }

    if (auto customOp = dyn_cast<CustomConstructOp>(op)) {
        auto tag = builder.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(customOp.getTag()));
        auto size = builder.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(customOp.getSize()));
        return builder.create<LLVM::CallOp>(
            loc, runtime.getOrCreateInitCustomAt(builder),
            ValueRange{objPtr, tag, size}).getResult();
    }

    llvm_unreachable("unsupported op kind in emitInitAtPtr");
}

/// Stores each non-zero extension kind word `ext[j]` of the record or custom `hptr`, which has `n` fields, in
/// slot `n + j` by calling the gc-leaf `storeI64Func`. The zero words are left as the `eco_init_*_at` call,
/// which zeroes the object, wrote them.
static void storeNonZeroExtWords(OpBuilder &builder, Location loc, Value hptr,
                                 int64_t n, llvm::ArrayRef<uint64_t> ext,
                                 LLVM::LLVMFuncOp storeI64Func) {
    auto i32Ty = builder.getI32Type();
    auto i64Ty = builder.getI64Type();
    for (size_t j = 0; j < ext.size(); ++j) {
        if (ext[j] == 0) continue;
        auto idx = builder.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(n + j));
        auto w = builder.create<LLVM::ConstantOp>(loc, i64Ty, static_cast<int64_t>(ext[j]));
        builder.create<LLVM::CallOp>(loc, storeI64Func, ValueRange{hptr, idx, w});
    }
}

/// Stores the fields of the record or custom group member `op` into its object `hptr`, then its non-zero
/// extension kind words and, for a custom, its packed kinds through `eco_set_unboxed` when any is not boxed.
/// Does nothing for any other op.
///
/// `memberResultMap` maps each member's original result to its merge-block `ptr addrspace(1)`; it is consulted
/// defensively, since no field can be another member's result.
static void emitFieldStoresForOp(
    OpBuilder &builder, Location loc,
    Operation *op, Value hptr,
    const llvm::DenseMap<Value, Value> &memberResultMap,
    const EcoRuntime &runtime) {

    auto *ctx = builder.getContext();
    auto i32Ty = IntegerType::get(ctx, 32);
    auto i64Ty = IntegerType::get(ctx, 64);

    if (auto recOp = dyn_cast<RecordConstructOp>(op)) {
        auto storeFunc = runtime.getOrCreateStoreRecordField(builder);
        auto storeI64Func = runtime.getOrCreateStoreRecordFieldI64(builder);
        auto storeF64Func = runtime.getOrCreateStoreRecordFieldF64(builder);
        int64_t fieldCount = recOp.getFieldCount();
        auto fields = recOp.getFields();

        for (int64_t i = 0; i < fieldCount; i++) {
            auto idx = builder.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(i));
            Value fieldVal = fields[i];
            Type origType = fieldVal.getType();

            auto it = memberResultMap.find(fieldVal);
            if (it != memberResultMap.end()) {
                builder.create<LLVM::CallOp>(loc, storeFunc,
                    ValueRange{hptr, idx, it->second});
                continue;
            }

            if (origType.isF64()) {
                builder.create<LLVM::CallOp>(loc, storeF64Func,
                    ValueRange{hptr, idx, fieldVal});
            } else if (origType.isInteger(1) || eco::isEcoCharType(origType)) {
                auto extended = builder.create<LLVM::ZExtOp>(loc, i64Ty, fieldVal);
                builder.create<LLVM::CallOp>(loc, storeI64Func,
                    ValueRange{hptr, idx, extended});
            } else if (origType.isInteger(64)) {
                builder.create<LLVM::CallOp>(loc, storeI64Func,
                    ValueRange{hptr, idx, fieldVal});
            } else {
                Value valHPtr = castToHPtr(builder, loc, fieldVal);
                builder.create<LLVM::CallOp>(loc, storeFunc,
                    ValueRange{hptr, idx, valHPtr});
            }
        }
        storeNonZeroExtWords(builder, loc, hptr, fieldCount,
            packKinds(slotKindsOfTypes(fields.take_front(fieldCount).getTypes()),
                      layout::RecordHdrSlots).ext,
            storeI64Func);
        return;
    }

    if (auto customOp = dyn_cast<CustomConstructOp>(op)) {
        auto storeFunc = runtime.getOrCreateStoreField(builder);
        auto storeI64Func = runtime.getOrCreateStoreFieldI64(builder);
        auto storeF64Func = runtime.getOrCreateStoreFieldF64(builder);
        auto setUnboxedFunc = runtime.getOrCreateSetUnboxed(builder);
        int64_t opSize = customOp.getSize();
        auto fields = customOp.getFields();

        for (int64_t i = 0; i < opSize; i++) {
            auto idx = builder.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(i));
            Value fieldVal = fields[i];
            Type origType = fieldVal.getType();

            auto it = memberResultMap.find(fieldVal);
            if (it != memberResultMap.end()) {
                builder.create<LLVM::CallOp>(loc, storeFunc,
                    ValueRange{hptr, idx, it->second});
                continue;
            }

            if (origType.isF64()) {
                builder.create<LLVM::CallOp>(loc, storeF64Func,
                    ValueRange{hptr, idx, fieldVal});
            } else if (origType.isInteger(1) || eco::isEcoCharType(origType)) {
                auto extended = builder.create<LLVM::ZExtOp>(loc, i64Ty, fieldVal);
                builder.create<LLVM::CallOp>(loc, storeI64Func,
                    ValueRange{hptr, idx, extended});
            } else if (origType.isInteger(64)) {
                builder.create<LLVM::CallOp>(loc, storeI64Func,
                    ValueRange{hptr, idx, fieldVal});
            } else {
                Value valHPtr = castToHPtr(builder, loc, fieldVal);
                builder.create<LLVM::CallOp>(loc, storeFunc,
                    ValueRange{hptr, idx, valHPtr});
            }
        }

        PackedKinds pk = packKinds(slotKindsOfTypes(fields.take_front(opSize).getTypes()),
                                   layout::CustomHdrSlots);
        storeNonZeroExtWords(builder, loc, hptr, opSize, pk.ext, storeI64Func);
        int64_t bitmap = static_cast<int64_t>(pk.hdrBits);
        if (bitmap != 0) {
            auto bitmapVal = builder.create<LLVM::ConstantOp>(loc, i64Ty, bitmap);
            builder.create<LLVM::CallOp>(loc, setUnboxedFunc,
                ValueRange{hptr, bitmapVal});
        }
        return;
    }
}

/// Replaces the allocation group `group`, a leader followed by its members in order, with one allocation of
/// their total size and the initialisation of each member in it.
///
/// The block is split before the leader. Its first half calls the gc-leaf `eco_gc_alloc_region_fast`; a null
/// result branches to a block that calls the statepointed `eco_gc_alloc_region_slow`, and any other to a block
/// that uses the fast region. Both initialise every member at its offset and pass the members' pointers to a
/// merge block, which holds the operations that followed the leader. There the record and custom fields are
/// stored, each member's uses are replaced by its pointer cast to `!eco.value`, and the members are erased.
///
/// No member may use another member's result, since the members are initialised before the merge block that
/// defines those results; EcoGCPrepare closes a group at such a use.
static void lowerOneAllocGroup(
    SmallVectorImpl<Operation*> &group,
    const EcoRuntime &runtime) {

    Operation *leader = group.front();
    auto loc = leader->getLoc();
    auto *ctx = leader->getContext();
    auto i64Ty = IntegerType::get(ctx, 64);
    auto i8Ty = IntegerType::get(ctx, 8);
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);
    size_t groupSize = group.size();

    int64_t totalBytes = 0;
    SmallVector<int64_t, 8> offsets;
    for (auto *op : group) {
        offsets.push_back(totalBytes);
        totalBytes += computeAllocSize(op);
    }

    // --- CFG surgery ---
    Block *origBlock = leader->getBlock();
    Region *parentRegion = origBlock->getParent();

    // Split just before the leader. Everything from leader onward goes to afterBlock.
    Block *afterBlock = origBlock->splitBlock(leader);

    // Create fast, slow, merge blocks in the same region.
    Block *fastBlock = new Block();
    Block *slowBlock = new Block();
    Block *mergeBlock = new Block();
    parentRegion->getBlocks().insertAfter(Region::iterator(origBlock), fastBlock);
    parentRegion->getBlocks().insertAfter(Region::iterator(fastBlock), slowBlock);
    parentRegion->getBlocks().insertAfter(Region::iterator(slowBlock), mergeBlock);

    auto hptrTy = LLVM::LLVMPointerType::get(ctx, /*addressSpace=*/1);
    for (size_t i = 0; i < groupSize; i++)
        mergeBlock->addArgument(hptrTy, loc);

    mergeBlock->getOperations().splice(
        mergeBlock->end(), afterBlock->getOperations());
    afterBlock->erase();

    OpBuilder builder(ctx);

    builder.setInsertionPointToEnd(origBlock);

    auto totalBytesVal = builder.create<LLVM::ConstantOp>(loc, i64Ty, totalBytes);
    auto baseFastCall = builder.create<LLVM::CallOp>(
        loc, runtime.getOrCreateAllocRegionFast(builder),
        ValueRange{totalBytesVal});
    Value baseFastPtr = baseFastCall.getResult();

    auto nullPtr = builder.create<LLVM::ZeroOp>(loc, ptrTy);
    auto isNull = builder.create<LLVM::ICmpOp>(
        loc, LLVM::ICmpPredicate::eq, baseFastPtr, nullPtr);

    builder.create<cf::CondBranchOp>(
        loc, isNull, slowBlock, ValueRange{},
        fastBlock, ValueRange{});

    builder.setInsertionPointToEnd(fastBlock);
    SmallVector<Value, 8> fastHPtrs;
    for (size_t i = 0; i < groupSize; i++) {
        Value offsetVal = builder.create<LLVM::ConstantOp>(loc, i64Ty, offsets[i]);
        Value objPtr = builder.create<LLVM::GEPOp>(
            loc, ptrTy, i8Ty, baseFastPtr, ValueRange{offsetVal});
        Value hptr = emitInitAtPtr(builder, loc, group[i], objPtr, runtime);
        fastHPtrs.push_back(hptr);
    }
    builder.create<cf::BranchOp>(loc, mergeBlock, fastHPtrs);

    builder.setInsertionPointToEnd(slowBlock);

    // RS4GC makes the slow alloc call a statepoint because the callee is not gc-leaf.

    auto totalBytesValSlow = builder.create<LLVM::ConstantOp>(loc, i64Ty, totalBytes);
    auto baseSlowCall = builder.create<LLVM::CallOp>(
        loc, runtime.getOrCreateAllocRegionSlow(builder),
        ValueRange{totalBytesValSlow});
    Value baseSlowPtr = baseSlowCall.getResult();

    SmallVector<Value, 8> slowHPtrs;
    for (size_t i = 0; i < groupSize; i++) {
        Value offsetVal = builder.create<LLVM::ConstantOp>(loc, i64Ty, offsets[i]);
        Value objPtr = builder.create<LLVM::GEPOp>(
            loc, ptrTy, i8Ty, baseSlowPtr, ValueRange{offsetVal});
        Value hptr = emitInitAtPtr(builder, loc, group[i], objPtr, runtime);
        slowHPtrs.push_back(hptr);
    }
    builder.create<cf::BranchOp>(loc, mergeBlock, slowHPtrs);

    builder.setInsertionPointToStart(mergeBlock);

    llvm::DenseMap<Value, Value> memberResultMap;
    auto ecoValueTy = eco::ValueType::get(ctx);
    SmallVector<Value, 8> ecoResults;

    for (size_t i = 0; i < groupSize; i++) {
        Value mergeArg = mergeBlock->getArgument(i);
        memberResultMap[group[i]->getResult(0)] = mergeArg;

        Value ecoVal = builder.create<UnrealizedConversionCastOp>(
            loc, ecoValueTy, mergeArg).getResult(0);
        ecoResults.push_back(ecoVal);
    }

    for (size_t i = 0; i < groupSize; i++) {
        Value hptr = mergeBlock->getArgument(i);
        emitFieldStoresForOp(builder, loc, group[i], hptr,
                             memberResultMap, runtime);
    }

    for (size_t i = 0; i < groupSize; i++)
        group[i]->getResult(0).replaceAllUsesWith(ecoResults[i]);

    // Erase all group ops (now in mergeBlock after the splice).
    for (auto it = group.rbegin(); it != group.rend(); ++it)
        (*it)->erase();
}

// Only operations directly in a function's top-level blocks are searched.
void eco::detail::lowerAllocGroups(ModuleOp module, const EcoRuntime &runtime) {
    // Collect every group first: lowering one splits blocks.
    SmallVector<SmallVector<Operation*, 4>> allGroups;

    for (auto funcOp : module.getOps<func::FuncOp>()) {
        if (funcOp.isExternal()) continue;

        for (auto &region : funcOp->getRegions()) {
            for (auto &block : region) {
                for (auto &op : block) {
                    auto groupSizeAttr = op.getAttrOfType<IntegerAttr>("eco.gc_group_size");
                    if (!groupSizeAttr || op.hasAttr("eco.gc_group_member"))
                        continue;
                    int64_t groupSize = groupSizeAttr.getInt();
                    if (groupSize <= 1) continue;

                    SmallVector<Operation*, 4> group;
                    group.push_back(&op);
                    Operation *next = op.getNextNode();
                    for (int64_t i = 1; i < groupSize && next; i++) {
                        assert(next->hasAttr("eco.gc_group_member") &&
                               "expected group member after leader");
                        group.push_back(next);
                        next = next->getNextNode();
                    }
                    assert(static_cast<int64_t>(group.size()) == groupSize &&
                           "group size mismatch");
                    allGroups.push_back(std::move(group));
                }
            }
        }
    }

    for (auto &group : allGroups) {
        lowerOneAllocGroup(group, runtime);
    }
}

//===----------------------------------------------------------------------===//
// GC pointers in value-level aggregate types
//===----------------------------------------------------------------------===//

bool eco::detail::containsGCPointer(Type t) {
    // Leaf GC-pointer type — converts to ptr addrspace(1) post-conversion.
    if (isa<eco::ValueType>(t))
        return true;
    // Recurse into aggregate element types.
    if (auto tup2 = dyn_cast<eco::Tuple2Type>(t))
        return containsGCPointer(tup2.getFirst()) ||
               containsGCPointer(tup2.getSecond());
    if (auto tup3 = dyn_cast<eco::Tuple3Type>(t))
        return containsGCPointer(tup3.getFirst()) ||
               containsGCPointer(tup3.getSecond()) ||
               containsGCPointer(tup3.getThird());
    if (auto rec = dyn_cast<eco::RecordType>(t)) {
        for (Type f : rec.getFields())
            if (containsGCPointer(f)) return true;
        return false;
    }
    if (auto cus = dyn_cast<eco::CustomType>(t)) {
        for (Type f : cus.getFields())
            if (containsGCPointer(f)) return true;
        return false;
    }
    if (auto cons = dyn_cast<eco::ConsType>(t))
        return containsGCPointer(cons.getHead()) ||
               containsGCPointer(cons.getTail());
    return false;
}

//===----------------------------------------------------------------------===//
// Pattern Population
//===----------------------------------------------------------------------===//

void eco::detail::populateEcoHeapPatterns(
    EcoTypeConverter &typeConverter,
    RewritePatternSet &patterns,
    const EcoRuntime &runtime) {

    auto *ctx = patterns.getContext();
    patterns.add<BoxOpLowering>(typeConverter, ctx, runtime);
    patterns.add<UnboxOpLowering>(typeConverter, ctx, runtime);
    patterns.add<AllocateOpLowering>(typeConverter, ctx, runtime);
    patterns.add<AllocateStringOpLowering>(typeConverter, ctx, runtime);
    patterns.add<ListConstructOpLowering>(typeConverter, ctx, runtime);
    patterns.add<ListHeadOpLowering>(typeConverter, ctx, runtime);
    patterns.add<ListTailOpLowering>(typeConverter, ctx, runtime);
    patterns.add<Tuple2ConstructOpLowering>(typeConverter, ctx, runtime);
    patterns.add<Tuple3ConstructOpLowering>(typeConverter, ctx, runtime);
    patterns.add<Tuple2ProjectOpLowering>(typeConverter, ctx, runtime);
    patterns.add<Tuple3ProjectOpLowering>(typeConverter, ctx, runtime);
    patterns.add<RecordConstructOpLowering>(typeConverter, ctx, runtime);
    patterns.add<RecordProjectOpLowering>(typeConverter, ctx, runtime);
    patterns.add<CustomConstructOpLowering>(typeConverter, ctx, runtime);
    patterns.add<CustomProjectOpLowering>(typeConverter, ctx, runtime);
    patterns.add<ArrayLengthOpLowering>(typeConverter, ctx, runtime);
    patterns.add<ArrayGetOpLowering>(typeConverter, ctx, runtime);
    patterns.add<ArraySetOpLowering>(typeConverter, ctx, runtime);
    patterns.add<ArrayEmptyOpLowering>(typeConverter, ctx, runtime);
    patterns.add<ArraySingletonOpLowering>(typeConverter, ctx, runtime);
    patterns.add<ArrayPushOpLowering>(typeConverter, ctx, runtime);
    patterns.add<ArraySliceOpLowering>(typeConverter, ctx, runtime);
    patterns.add<ArrayAppendNOpLowering>(typeConverter, ctx, runtime);
    patterns.add<StringFromIntOpLowering>(typeConverter, ctx, runtime);
    patterns.add<StringFromFloatOpLowering>(typeConverter, ctx, runtime);
    patterns.add<StringAppendOpLowering>(typeConverter, ctx, runtime);
    patterns.add<ListAppendOpLowering>(typeConverter, ctx, runtime);
    patterns.add<StringLengthOpLowering>(typeConverter, ctx, runtime);
}
