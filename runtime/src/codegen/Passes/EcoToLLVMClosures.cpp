//===- EcoToLLVMClosures.cpp - Closure operation lowering patterns --------===//
//
// This file implements lowering patterns for ECO closure operations:
// allocate_closure, papCreate, papExtend, and indirect calls.
//
//===----------------------------------------------------------------------===//

#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../EcoTypes.h"
#include "EcoToLLVMInternal.h"

#include "../../allocator/Heap.hpp"

#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/SCF/IR/SCF.h"

#include <cstdlib>   // ::getenv for the E0.4 dispatch-site counter gate

using namespace mlir;
using namespace eco;
using namespace eco::detail;

namespace {

// Forward declarations for helpers defined later in this TU but referenced
// by the closure-construction lowerings (PapCreate / PapCreateGroup).
static uint8_t mlirTypeToParamKind(Type ty);
static uint64_t deriveAllParamKindsBitmap(const EcoRuntime &runtime,
                                          StringRef funcSymbol, int64_t arity);
static bool wrapperWillBeTypedNewargs(const EcoRuntime &runtime,
                                       StringRef funcSymbol);

/// Extract GC live roots from adapted operands for append-pattern ops.
/// Returns the adapted operands split into {real operands, live roots}.
static std::pair<ValueRange, ValueRange> splitAdaptedRoots(
    Operation *origOp, ValueRange adaptedOperands) {
    auto attr = origOp->getAttrOfType<IntegerAttr>("eco.gc_roots_count");
    unsigned rootCount = attr ? attr.getValue().getZExtValue() : 0;
    if (rootCount == 0)
        return {adaptedOperands, ValueRange{}};
    unsigned realCount = adaptedOperands.size() - rootCount;
    return {adaptedOperands.take_front(realCount),
            adaptedOperands.drop_front(realCount)};
}

//===----------------------------------------------------------------------===//
// GC root range helpers for args-array call sites
//===----------------------------------------------------------------------===//

/// Zero-initializes an alloca'd args array and registers it as a GC root range.
/// Returns the saved range depth for later restoration.
static Value emitPushArgsRootRange(
    ConversionPatternRewriter &rewriter, Location loc,
    const EcoRuntime &runtime,
    Value argsArray, int64_t numSlots, uint64_t hpointerMask) {
    auto *ctx = rewriter.getContext();
    auto i8Ty = IntegerType::get(ctx, 8);
    auto i64Ty = IntegerType::get(ctx, 64);

    // Zero-initialize the array so uninitialized slots are safe for GC.
    auto zeroVal = rewriter.create<LLVM::ConstantOp>(loc, i8Ty, 0);
    auto bytesLen = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, numSlots * 8);
    rewriter.create<LLVM::MemsetOp>(loc, argsArray, zeroVal, bytesLen, /*isVolatile=*/false);

    // Save current range stack depth.
    auto rangePointFunc = runtime.getOrCreateGcStackRangePoint(rewriter);
    auto saved = rewriter.create<LLVM::CallOp>(loc, rangePointFunc, ValueRange{});

    // Register the array as a root range.
    auto pushFunc = runtime.getOrCreateGcPushStackRange(rewriter);
    auto countConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, numSlots);
    auto maskConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
        rewriter.getI64IntegerAttr(static_cast<int64_t>(hpointerMask)));
    rewriter.create<LLVM::CallOp>(loc, pushFunc,
        ValueRange{argsArray, countConst, maskConst});

    return saved.getResult();
}

/// Restores the GC root range stack after a runtime call.
static void emitRestoreArgsRootRange(
    ConversionPatternRewriter &rewriter, Location loc,
    const EcoRuntime &runtime,
    Value savedRangeDepth) {
    auto restoreFunc = runtime.getOrCreateGcRestoreStackRangePoint(rewriter);
    rewriter.create<LLVM::CallOp>(loc, restoreFunc, ValueRange{savedRangeDepth});
}

//===----------------------------------------------------------------------===//
// eco.project.closure -> load capture from closure values array
//===----------------------------------------------------------------------===//

struct ProjectClosureOpLowering : public OpConversionPattern<ProjectClosureOp> {
    const EcoRuntime &runtime;

    ProjectClosureOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx, const EcoRuntime &runtime) :
        OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult matchAndRewrite(ProjectClosureOp op, OpAdaptor adaptor,
                                  ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i8Ty = IntegerType::get(ctx, 8);
        auto i64Ty = IntegerType::get(ctx, 64);
        auto f64Ty = Float64Type::get(ctx);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        int64_t index = op.getIndex();
        bool isUnboxed = op.getIsUnboxed();

        Value closureI64 = adaptor.getClosure();

        // Resolve closure HPointer to raw pointer
        auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
        auto resolveCall = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{closureI64});
        Value closurePtr = resolveCall.getResult();

        // Compute offset: values[index] is at offset ClosureValuesOffset + index * 8
        int64_t valueOffset = layout::ClosureValuesOffset + index * layout::PtrSize;
        auto offsetConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, rewriter.getI64IntegerAttr(valueOffset));
        auto valuePtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, closurePtr, ValueRange{offsetConst});

        // Load the value as i64
        Value loadedValue = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valuePtr);

        // Convert to result type
        Type resultType = getTypeConverter()->convertType(op.getResult().getType());
        Value result = loadedValue;

        if (isUnboxed) {
            // Unboxed value - convert based on target type
            if (resultType == f64Ty) {
                result = rewriter.create<LLVM::BitcastOp>(loc, f64Ty, loadedValue);
            } else if (isa<LLVM::LLVMPointerType>(resultType)) {
                result = rewriter.create<LLVM::IntToPtrOp>(loc, resultType, loadedValue);
            } else if (auto intTy = dyn_cast<IntegerType>(resultType); intTy && intTy.getWidth() < 64) {
                result = rewriter.create<LLVM::TruncOp>(loc, resultType, loadedValue);
            }
            // else: i64, no conversion needed
        } else {
            // Boxed value (!eco.value) - load i64 from closure slot then convert to ptr<1>
            if (isHPtrLLVMType(resultType))
                result = closureLoadI64ToValue(rewriter, loc, loadedValue);
        }

        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.allocate_closure -> call eco_alloc_closure
//===----------------------------------------------------------------------===//

struct AllocateClosureOpLowering : public OpConversionPattern<AllocateClosureOp> {
    const EcoRuntime &runtime;

    AllocateClosureOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx, const EcoRuntime &runtime) :
        OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult matchAndRewrite(AllocateClosureOp op, OpAdaptor adaptor,
                                  ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        auto funcSymbol = op.getFunction();
        Value funcPtr = rewriter.create<LLVM::AddressOfOp>(loc, ptrTy, funcSymbol);
        auto arityConst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(op.getArity()));

        Value result = emitAllocWithSafepoint(
            op, rewriter, runtime,
            runtime.getOrCreateAllocClosure(rewriter),
            ValueRange{funcPtr, arityConst},
            adaptor.getLiveRoots());
        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.papCreate -> alloc_closure + store n_values + store captured values
//===----------------------------------------------------------------------===//

/// Check if a function already uses the args-array calling convention.
/// Returns true if the function signature is: (ptr) -> i64 or (ptr) -> ptr
static bool usesArgsArrayConvention(LLVM::LLVMFuncOp func) {
    auto funcType = func.getFunctionType();
    // Must have exactly one parameter
    if (funcType.getNumParams() != 1) {
        return false;
    }
    // Parameter must be a pointer
    if (!isa<LLVM::LLVMPointerType>(funcType.getParamType(0))) {
        return false;
    }
    // Return type must be i64 or ptr
    auto retType = funcType.getReturnType();
    if (auto intTy = dyn_cast<IntegerType>(retType)) {
        return intTy.getWidth() == 64;
    }
    return isa<LLVM::LLVMPointerType>(retType);
}

/// Generate or get a wrapper function that adapts from the runtime's calling
/// convention (void** args) to the target function's direct argument convention.
/// If the target already uses the args-array convention, return it directly.
///
/// For typed lambdas, this wrapper:
/// 1. Loads each arg as i64 from the void** array
/// 2. Bitcasts to the target type (i64->f64 for floats, i64->ptr for pointers)
/// 3. Calls the typed target function
/// 4. Bitcasts the result back to i64/ptr for the runtime
/// Build (or fetch from cache) an evaluator wrapper of signature
/// `<RetT> (*)(ptr)` that adapts the runtime's args-array calling
/// convention to the target function's typed signature.
///
/// Two arg-side conventions are supported:
///   - typedNewargs=false (legacy): every slot in the args array is an
///     HPointer-encoded i64. Primitive params are extracted by resolving
///     the HPointer and loading the boxed value at offset 8.
///   - typedNewargs=true (Phase E): primitive slots carry the raw value
///     directly (i64 / f64 bits / i16 zero-extended); HPointer slots are
///     unchanged. Per-slot kind comes from `closure->unboxed[i]`; the
///     evaluator extracts each slot accordingly.
///
/// `resultKind` (ParamKind: 0=Boxed, 1=Int, 2=Float, 3=Char) controls
/// the wrapper's return ABI:
///   - PK_Boxed → returns ptr (HPtr); primitive inner-call results are
///     boxed via `eco_alloc_*` on the way out.
///   - PK_Int   → returns i64 directly (no boxing).
///   - PK_Float → returns f64 directly (no boxing).
///   - PK_Char  → returns i16 directly (no boxing).
///
/// Phase D: K!=0 wrappers are now safe. Every closure-invocation entry
/// point reads the closure's actual `result_kind` from its header (set
/// by `eco_alloc_closure_k` to match the wrapper's compiled return ABI)
/// and dispatches the function-pointer cast accordingly. C++ kernel
/// callers that pre-Phase-C invoked `eco_apply_closure` with an
/// all-boxed legacy layout still work: the layout's `result_kind` byte
/// is now derived from the closure header inside the legacy entry, so
/// the runtime helper picks the correct cast even when the caller is
/// unaware of K.
// Takes OpBuilder& (not PatternRewriter&) so the Phase-2 serial pre-pass can
// call it with a plain OpBuilder. It only CREATEs ops (no replaceOp/eraseOp);
// pattern callers pass their ConversionPatternRewriter which IS-A OpBuilder&.
static LLVM::LLVMFuncOp getOrCreateWrapper(OpBuilder &rewriter, ModuleOp module, StringRef funcName,
                                           int64_t arity, Location loc, const TypeConverter *typeConverter,
                                           const EcoRuntime &runtime,
                                           bool typedNewargs = false,
                                           uint8_t resultKind = 0) {
    auto *ctx = rewriter.getContext();
    auto i64Ty = IntegerType::get(ctx, 64);
    auto f64Ty = Float64Type::get(ctx);
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);
    auto i16Ty = IntegerType::get(ctx, 16);

    // Check if wrapper already exists (check first — fast path).
    // Cache key includes resultKind so K=0 and K=primitive wrappers for the
    // same target are distinct symbols.
    llvm::SmallString<64> wrapperName;
    const char *kindSuffix = "";
    switch (resultKind) {
        case 1: kindSuffix = "_ri"; break;  // PK_Int
        case 2: kindSuffix = "_rf"; break;  // PK_Float
        case 3: kindSuffix = "_rc"; break;  // PK_Char
        default: kindSuffix = ""; break;     // PK_Boxed (no suffix to keep symbol stability)
    }
    if (typedNewargs) {
        ("__closure_wrapper_typed_" + funcName + kindSuffix).toVector(wrapperName);
    } else {
        ("__closure_wrapper_" + funcName + kindSuffix).toVector(wrapperName);
    }

    if (auto existingWrapper = runtime.lookupSymbol<LLVM::LLVMFuncOp>(StringRef(wrapperName))) {
        return existingWrapper;
    }

    // Check if target function already uses args-array convention.
    // The args-array convention assumes boxed HPointer slots — i.e. it is
    // already a hand-written legacy wrapper. There is no typed signature
    // to derive a typed wrapper from, so we reuse it as-is regardless of
    // the typedNewargs flag. The caller is responsible for tagging slots
    // as PK_Boxed in `closure->unboxed[i]` for closures whose evaluator
    // resolves to an args-array-convention function.
    // A genuine args-array-convention target is a hand-written llvm.func that
    // was NEVER a func::FuncOp, so it is absent from the pre-scanned
    // origFuncTypes. Under the Stage0/Stage2 conversion split EVERY eco
    // function is already an llvm.func shell here, and a converted eco
    // signature can superficially resemble the args-array shape — so only
    // treat NOT-pre-scanned funcs as args-array, else the typed wrapper for a
    // normal function gets suppressed (missing __closure_wrapper_typed_* ->
    // dangling closure evaluator -> runtime SIGSEGV).
    if (!runtime.origFuncTypes.contains(funcName)) {
        if (auto existingFunc = runtime.lookupSymbol<LLVM::LLVMFuncOp>(funcName)) {
            if (usesArgsArrayConvention(existingFunc)) {
                return existingFunc;
            }
        }
    }

    // Look up target function to get its actual signature.
    // We keep BOTH original (pre-conversion) types and converted types.
    // Original types let us distinguish !eco.value (HPointer pass-through)
    // from Int (i64 → needs unbox from HPointer) in the wrapper.
    SmallVector<Type> targetParamTypes;
    SmallVector<Type> origParamTypes;   // Pre-conversion MLIR types
    Type targetResultType = i64Ty;      // Default to i64
    Type origResultType;                // Pre-conversion result type (null = unknown)

    // Try pre-scanned original types first, then func::FuncOp, then LLVM::LLVMFuncOp.
    auto origIt = runtime.origFuncTypes.find(funcName);
    if (origIt != runtime.origFuncTypes.end()) {
        auto funcType = origIt->second;
        for (auto paramType : funcType.getInputs()) {
            origParamTypes.push_back(paramType);
            Type convertedType = typeConverter ? typeConverter->convertType(paramType) : paramType;
            targetParamTypes.push_back(convertedType ? convertedType : paramType);
        }
        if (funcType.getNumResults() > 0) {
            origResultType = funcType.getResult(0);
            Type convertedResult = typeConverter ? typeConverter->convertType(funcType.getResult(0)) : funcType.getResult(0);
            targetResultType = convertedResult ? convertedResult : funcType.getResult(0);
        }
        // Ensure the target function exists as an LLVM symbol (it may only be
        // in the pre-scan map from a papCreate reference with no func::FuncOp).
        if (!runtime.lookupSymbol(funcName)) {
            OpBuilder::InsertionGuard declGuard(rewriter);
            rewriter.setInsertionPointToStart(module.getBody());
            auto externFuncType = LLVM::LLVMFunctionType::get(targetResultType, targetParamTypes, false);
            auto externFunc = rewriter.create<LLVM::LLVMFuncOp>(loc, funcName, externFuncType);
            externFunc.setLinkage(LLVM::Linkage::External);
            runtime.cacheSymbol(externFunc);
        }
    } else if (auto funcFunc = runtime.lookupSymbol<func::FuncOp>(funcName)) {
        auto funcType = funcFunc.getFunctionType();
        for (auto paramType : funcType.getInputs()) {
            origParamTypes.push_back(paramType);
            Type convertedType = typeConverter ? typeConverter->convertType(paramType) : paramType;
            targetParamTypes.push_back(convertedType ? convertedType : paramType);
        }
        if (funcType.getNumResults() > 0) {
            origResultType = funcType.getResult(0);
            Type convertedResult = typeConverter ? typeConverter->convertType(funcType.getResult(0)) : funcType.getResult(0);
            targetResultType = convertedResult ? convertedResult : funcType.getResult(0);
        }
    } else if (auto llvmFunc = runtime.lookupSymbol<LLVM::LLVMFuncOp>(funcName)) {
        auto funcType = llvmFunc.getFunctionType();
        for (unsigned i = 0; i < funcType.getNumParams(); ++i) {
            targetParamTypes.push_back(funcType.getParamType(i));
            // No original types available for LLVM funcs; leave origParamTypes empty
        }
        targetResultType = funcType.getReturnType();
    } else {
        // Target function not found.
        // CGEN_057: Kernel functions must have func.func is_kernel declarations
        // emitted by the compiler. A missing declaration is a compiler bug.
        if (funcName.starts_with("Elm_Kernel_")) {
            llvm::report_fatal_error(
                "getOrCreateWrapper: missing original function types for kernel '" +
                funcName + "'; compiler must emit func.func is_kernel declaration");
        }
        // For non-kernel functions (e.g. hand-crafted test MLIR), fall back to
        // all-i64 signature. These should be caught by usesArgsArrayConvention()
        // above, but this is a safety net.
        for (int64_t i = 0; i < arity; ++i) {
            targetParamTypes.push_back(i64Ty);
        }
        OpBuilder::InsertionGuard declGuard(rewriter);
        rewriter.setInsertionPointToStart(module.getBody());
        auto targetFuncType = LLVM::LLVMFunctionType::get(targetResultType, targetParamTypes, false);
        auto externFunc = rewriter.create<LLVM::LLVMFuncOp>(loc, funcName, targetFuncType);
        externFunc.setLinkage(LLVM::Linkage::External);
        runtime.cacheSymbol(externFunc);
    }

    // Create wrapper function type. Return type matches `resultKind` so
    // primitive-result closures expose their natural C ABI to the runtime
    // dispatcher.
    Type wrapperReturnType;
    switch (resultKind) {
        case 1: wrapperReturnType = i64Ty; break;
        case 2: wrapperReturnType = f64Ty; break;
        case 3: wrapperReturnType = i16Ty; break;
        default: wrapperReturnType = ptrTy; break;
    }
    auto wrapperType = LLVM::LLVMFunctionType::get(wrapperReturnType, {ptrTy}, false);

    // Insert wrapper at module level
    OpBuilder::InsertionGuard guard(rewriter);
    rewriter.setInsertionPointToStart(module.getBody());

    auto wrapperFunc = rewriter.create<LLVM::LLVMFuncOp>(loc, StringRef(wrapperName), wrapperType);
    wrapperFunc.setLinkage(LLVM::Linkage::Internal);
    runtime.cacheSymbol(wrapperFunc);

    Block *entryBlock = wrapperFunc.addEntryBlock(rewriter);
    rewriter.setInsertionPointToStart(entryBlock);

    Value argsArray = entryBlock->getArgument(0);
    auto i8Ty = IntegerType::get(ctx, 8);

    // Load arguments from args array and convert to the target function's types.
    //
    // Convention: ALL args in the void** array are HPointer-encoded i64.
    // The wrapper uses original (pre-conversion) types to determine how to unbox:
    //   - !eco.value → pass through (i64 HPointer, inner function expects i64)
    //   - Int (i64)  → unbox: resolve HPointer → read i64 value at offset 8
    //   - Float (f64) → unbox: resolve HPointer → read i64 at offset 8 → bitcast to f64
    //   - Char (i16)  → unbox: resolve HPointer → read i64 at offset 8 → trunc to i16
    //   - ptr         → inttoptr (for raw pointer args)
    // When original types are unavailable, fall back to converted-type heuristics.
    auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
    bool hasOrigTypes = !origParamTypes.empty();

    SmallVector<Value, 8> liveRoots;
    SmallVector<Value> callArgs;
    // Single constant reused for all gc-live allocas below.
    auto oneConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
        rewriter.getI64IntegerAttr(1));
    for (int64_t i = 0; i < arity; ++i) {
        auto idxConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, i);
        auto argPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i64Ty, argsArray, ValueRange{idxConst});
        Value argI64 = rewriter.create<LLVM::LoadOp>(loc, i64Ty, argPtr);

        // Force each gc-live value through a wrapper-local stack alloca so it
        // has a distinct SSA identity from the call argument. This prevents
        // the register allocator from keeping gc-live roots in argument
        // registers (which would produce 0 GC-live stack locations in the
        // stackmap, causing stale pointers after GC relocation).
        auto rootAlloca = rewriter.create<LLVM::AllocaOp>(
            loc, ptrTy, i64Ty, oneConst);
        rewriter.create<LLVM::StoreOp>(loc, argI64, rootAlloca);
        auto gcLiveVal = rewriter.create<LLVM::LoadOp>(loc, i64Ty, rootAlloca);
        liveRoots.push_back(gcLiveVal);

        Type targetType = (i < (int64_t)targetParamTypes.size()) ? targetParamTypes[i] : i64Ty;
        Type origType = (hasOrigTypes && i < (int64_t)origParamTypes.size())
                            ? origParamTypes[i] : Type();

        Value convertedArg = argI64;

        if (origType && isa<eco::ValueType>(origType)) {
            // !eco.value param: arg is HPointer i64 from wrapper args array.
            // Identical between the legacy and typed conventions — boxed
            // slots are HPointer-encoded in both.
            convertedArg = wrapperLoadArgSlotToValue(rewriter, loc, argI64, getHPtrLLVMType(*ctx));
        } else if (typedNewargs && origType && origType.isInteger(64)) {
            // Typed Int slot: the wrapper args slot already carries the raw
            // i64 value (no HPointer indirection).
            convertedArg = argI64;
        } else if (typedNewargs && origType && origType.isF64()) {
            // Typed Float slot: slot bits are the f64 already; bitcast directly.
            convertedArg = rewriter.create<LLVM::BitcastOp>(loc, f64Ty, argI64);
        } else if (typedNewargs && origType && isa<IntegerType>(origType) &&
                   cast<IntegerType>(origType).getWidth() < 64) {
            // Typed Char slot: slot bits are zero-extended into the i64; trunc back.
            convertedArg = rewriter.create<LLVM::TruncOp>(loc, origType, argI64);
        } else if (typedNewargs && !origType) {
            // Typed convention with unknown orig type: fall back to type-based
            // direct interpretation (raw bits, no HPointer resolve).
            if (auto intTy = dyn_cast<IntegerType>(targetType); intTy && intTy.getWidth() < 64) {
                convertedArg = rewriter.create<LLVM::TruncOp>(loc, targetType, argI64);
            } else if (targetType == f64Ty) {
                convertedArg = rewriter.create<LLVM::BitcastOp>(loc, f64Ty, argI64);
            } else if (isa<LLVM::LLVMPointerType>(targetType)) {
                convertedArg = wrapperLoadArgSlotToValue(rewriter, loc, argI64, targetType);
            }
            // i64 target → pass through.
        } else if (origType && origType.isInteger(64)) {
            // Legacy Int param: arg is HPointer to ElmInt → resolve and read value at offset 8
            Value hptr = wrapperLoadArgSlotToValue(rewriter, loc, argI64, getHPtrLLVMType(*ctx));
            auto resolved = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{hptr});
            auto off8 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::HeaderSize);
            auto valPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty,
                                                        resolved.getResult(), ValueRange{off8});
            convertedArg = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valPtr);
        } else if (origType && origType.isF64()) {
            // Legacy Float param: arg is HPointer to ElmFloat → resolve, read i64 at offset 8, bitcast
            Value hptr = wrapperLoadArgSlotToValue(rewriter, loc, argI64, getHPtrLLVMType(*ctx));
            auto resolved = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{hptr});
            auto off8 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::HeaderSize);
            auto valPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty,
                                                        resolved.getResult(), ValueRange{off8});
            Value loadedI64 = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valPtr);
            convertedArg = rewriter.create<LLVM::BitcastOp>(loc, f64Ty, loadedI64);
        } else if (auto intTy = dyn_cast<IntegerType>(targetType); intTy && intTy.getWidth() < 64) {
            // Legacy Char (i16/i32): arg is HPointer to ElmChar → resolve and read value at offset 8
            Value hptr = wrapperLoadArgSlotToValue(rewriter, loc, argI64, getHPtrLLVMType(*ctx));
            auto resolved = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{hptr});
            auto off8 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::HeaderSize);
            auto valPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty,
                                                        resolved.getResult(), ValueRange{off8});
            Value fullVal = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valPtr);
            convertedArg = rewriter.create<LLVM::TruncOp>(loc, targetType, fullVal);
        } else if (targetType == f64Ty && !origType) {
            // Legacy fallback: no orig types, target is f64 → unbox from HPointer
            Value hptr = wrapperLoadArgSlotToValue(rewriter, loc, argI64, getHPtrLLVMType(*ctx));
            auto resolved = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{hptr});
            auto off8 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::HeaderSize);
            auto valPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty,
                                                        resolved.getResult(), ValueRange{off8});
            Value loadedI64 = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valPtr);
            convertedArg = rewriter.create<LLVM::BitcastOp>(loc, f64Ty, loadedI64);
        } else if (isa<LLVM::LLVMPointerType>(targetType)) {
            convertedArg = wrapperLoadArgSlotToValue(rewriter, loc, argI64, targetType);
        }
        // else: i64 with no orig type or orig is eco.value — pass through as-is
        callArgs.push_back(convertedArg);
    }

    // Emit safepoint marker before the target call so StatepointConversion
    // wraps it in gc.statepoint, keeping loaded HPointers visible to GC.
    emitWrapperSafepointMarker(rewriter, runtime, loc, liveRoots);

    // Call the target function
    auto targetFuncType = LLVM::LLVMFunctionType::get(targetResultType, targetParamTypes, false);
    auto funcSymbolRef = FlatSymbolRefAttr::get(ctx, funcName);
    auto call = rewriter.create<LLVM::CallOp>(loc, targetFuncType, funcSymbolRef, callArgs);

    // Convert result to the wrapper's declared return type.
    //
    // For PK_Boxed (resultKind=0, the legacy path): the wrapper returns
    // a `ptr` HPointer. Primitive inner-call results are boxed via
    // `eco_alloc_*`; !eco.value results are passed through.
    //
    // For PK_Int/Float/Char (resultKind!=0, the typed-result path): the
    // wrapper returns the primitive directly without boxing. The inner
    // function's result type must already match (the frontend ensures
    // this by emitting `_result_kind` = mlirTypeToParamKind(MonoResult)).
    Value resultValue = call.getResult();
    Value resultPtr;

    if (resultKind != 0) {
        // Primitive-return path: pass the inner result through unmodified
        // (after any width adjustment between target and wrapper return ABI).
        if (resultKind == 1) {
            // PK_Int → i64. Inner already returns i64 for Int-typed results.
            assert(targetResultType == i64Ty &&
                   "PK_Int wrapper requires i64 target return type");
            resultPtr = resultValue;
        } else if (resultKind == 2) {
            // PK_Float → f64. Inner returns f64 for Float-typed results.
            assert(targetResultType == f64Ty &&
                   "PK_Float wrapper requires f64 target return type");
            resultPtr = resultValue;
        } else if (resultKind == 3) {
            // PK_Char → i16. Inner returns i16 (or smaller); narrow if needed.
            if (auto intTy = dyn_cast<IntegerType>(targetResultType)) {
                if (intTy.getWidth() == 16) {
                    resultPtr = resultValue;
                } else if (intTy.getWidth() < 16) {
                    resultPtr = rewriter.create<LLVM::ZExtOp>(loc, i16Ty, resultValue);
                } else {
                    resultPtr = rewriter.create<LLVM::TruncOp>(loc, i16Ty, resultValue);
                }
            } else {
                assert(false && "PK_Char wrapper requires integer target return type");
                __builtin_unreachable();
            }
        }
    } else if (origResultType && isa<eco::ValueType>(origResultType)) {
        // !eco.value result: inner function returns ptr<1> → convert to ptr AS0
        resultPtr = wrapperReturnValueToPtr0(rewriter, loc, resultValue, ptrTy);
    } else if (origResultType && origResultType.isInteger(64)) {
        // Int result: inner function returns raw i64 → box via eco_alloc_int
        emitWrapperSafepointMarker(rewriter, runtime, loc, liveRoots);
        auto allocIntFunc = runtime.getOrCreateAllocInt(rewriter);
        auto boxCall = rewriter.create<LLVM::CallOp>(loc, allocIntFunc, ValueRange{resultValue});
        resultPtr = wrapperReturnValueToPtr0(rewriter, loc, boxCall.getResult(), ptrTy);
    } else if (origResultType && origResultType.isF64()) {
        emitWrapperSafepointMarker(rewriter, runtime, loc, liveRoots);
        auto allocFloatFunc = runtime.getOrCreateAllocFloat(rewriter);
        auto boxCall = rewriter.create<LLVM::CallOp>(loc, allocFloatFunc, ValueRange{resultValue});
        resultPtr = wrapperReturnValueToPtr0(rewriter, loc, boxCall.getResult(), ptrTy);
    } else if (origResultType && isa<IntegerType>(origResultType) &&
               cast<IntegerType>(origResultType).getWidth() < 64) {
        emitWrapperSafepointMarker(rewriter, runtime, loc, liveRoots);
        auto allocCharFunc = runtime.getOrCreateAllocChar(rewriter);
        auto boxCall = rewriter.create<LLVM::CallOp>(loc, allocCharFunc, ValueRange{resultValue});
        resultPtr = wrapperReturnValueToPtr0(rewriter, loc, boxCall.getResult(), ptrTy);
    } else if (isa<LLVM::LLVMPointerType>(targetResultType)) {
        // ptr or ptr<1> result: convert to ptr AS0
        if (isHPtrLLVMType(targetResultType)) {
            resultPtr = wrapperReturnValueToPtr0(rewriter, loc, resultValue, ptrTy);
        } else {
            resultPtr = resultValue;
        }
    } else if (targetResultType == f64Ty && !origResultType) {
        emitWrapperSafepointMarker(rewriter, runtime, loc, liveRoots);
        auto allocFloatFunc = runtime.getOrCreateAllocFloat(rewriter);
        auto boxCall = rewriter.create<LLVM::CallOp>(loc, allocFloatFunc, ValueRange{resultValue});
        resultPtr = wrapperReturnValueToPtr0(rewriter, loc, boxCall.getResult(), ptrTy);
    } else if (auto intTy = dyn_cast<IntegerType>(targetResultType); intTy && !origResultType) {
        if (intTy.getWidth() < 64) {
            emitWrapperSafepointMarker(rewriter, runtime, loc, liveRoots);
            auto allocCharFunc = runtime.getOrCreateAllocChar(rewriter);
            auto boxCall = rewriter.create<LLVM::CallOp>(loc, allocCharFunc, ValueRange{resultValue});
            resultPtr = wrapperReturnValueToPtr0(rewriter, loc, boxCall.getResult(), ptrTy);
        } else {
            // i64 with no orig type → assume HPointer, pass through
            resultPtr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, ValueRange{resultValue});
        }
    } else {
        resultPtr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, ValueRange{resultValue});
    }

    rewriter.create<LLVM::ReturnOp>(loc, ValueRange{resultPtr});

    return wrapperFunc;
}

struct PapCreateOpLowering : public OpConversionPattern<PapCreateOp> {
    const EcoRuntime &runtime;

    PapCreateOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx, const EcoRuntime &runtime) :
        OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult matchAndRewrite(PapCreateOp op, OpAdaptor adaptor,
                                  ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i8Ty = IntegerType::get(ctx, 8);
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i64Ty = IntegerType::get(ctx, 64);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        // Split adapted operands into real captured values + GC roots.
        auto [realOperands, liveRoots] = splitAdaptedRoots(op, adaptor.getOperands());

        int64_t arity = op.getArity();
        int64_t numCaptured = op.getNumCaptured();
        auto captured = realOperands;  // All real operands are captures

        // Emit safepoint marker before allocation
        emitSafepointMarker(op, rewriter, runtime, liveRoots);

        auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);

        // Get wrapper function that adapts calling convention
        // For closures with captures, prefer the fast clone (_fast_evaluator) for the wrapper
        // since it takes captures + params as direct arguments (compatible with args-array).
        // The generic clone ($clo) takes (Closure*, params...) which is used for typed closure dispatch.
        auto module = op->getParentOfType<ModuleOp>();
        StringRef funcSymbol;
        if (auto fastEval = op->getAttrOfType<SymbolRefAttr>("_fast_evaluator")) {
            // Has fast clone - use it for the wrapper (typed closure calling)
            funcSymbol = fastEval.getRootReference();
        } else {
            // No fast clone - use the function attribute directly (zero-capture or legacy)
            funcSymbol = op.getFunction();
        }
        // Phase E: every papCreate closure uses the typed-newargs wrapper.
        // The wrapper reads each slot directly per the target's parameter
        // type — no HPointer→primitive resolve. Caller paths that build
        // the args buffer (JIT and the migrated kernel-cpp callers) must
        // use REP_ABI_001's typed convention: raw primitives for Int/
        // Float/Char, HPointers for everything else. Per-slot kind comes
        // from `closure->unboxed[i]`.
        //
        // `_result_kind` (set by the frontend from the Mono result type)
        // selects the wrapper's return ABI: PK_Boxed → ptr (status quo);
        // PK_Int/Float/Char → primitive return. Wrappers with primitive
        // return ABI are only safe to invoke via `eco_apply_closure_eval`,
        // which dispatches the cast based on the layout's `result_kind`.
        // Phase D: pass the op's `_result_kind` through to both the
        // wrapper (controls its real C-ABI return type) and the closure
        // header (read by every dispatch path). Wrapper and header K
        // must agree; the frontend computes both from the same Mono
        // result type so they do.
        uint8_t closureResultKind = static_cast<uint8_t>(op.get_resultKind());
        auto wrapperFunc = getOrCreateWrapper(rewriter, module, funcSymbol, arity, loc,
                                              getTypeConverter(), runtime,
                                              /*typedNewargs=*/true,
                                              closureResultKind);
        Value funcPtr = rewriter.create<LLVM::AddressOfOp>(loc, ptrTy, wrapperFunc.getSymName());

        // H4.2 (HEAP_033): a zero-capture, non-self-capturing closure is
        // immutable after construction (capture writes only happen for
        // num_captured > 0; eco_pap_extend copies) — intern one permanent
        // singleton per wrapper instead of allocating per execution. The
        // packed header word (same Phase-C layout as the store below) is a
        // compile-time constant per site and a pure function of the wrapper
        // symbol, so cache hits always agree with it.
        if (numCaptured == 0 && !op->hasAttr("self_capture_indices")) {
            bool isTyped0 = wrapperWillBeTypedNewargs(runtime, funcSymbol);
            uint64_t bitmap0 =
                isTyped0 ? deriveAllParamKindsBitmap(runtime, funcSymbol, arity)
                         : op.getUnboxedBitmap();
            uint64_t packed0 =
                  ((static_cast<uint64_t>(arity) & 0x3F) << 6)
                | ((static_cast<uint64_t>(closureResultKind) & 0x3) << 12)
                | ((bitmap0 & ((1ULL << 50) - 1)) << 14);
            auto internFunc = runtime.getOrCreateInternClosure0(rewriter);
            auto arityConst32 = rewriter.create<LLVM::ConstantOp>(
                loc, i32Ty, static_cast<int32_t>(arity));
            auto packedConst0 = rewriter.create<LLVM::ConstantOp>(
                loc, i64Ty, rewriter.getI64IntegerAttr(packed0));
            auto internCall = rewriter.create<LLVM::CallOp>(
                loc, internFunc, ValueRange{funcPtr, arityConst32, packedConst0});
            rewriter.replaceOp(op, internCall.getResult());
            return success();
        }

        // Allocate closure with max_values = arity, n_values = 0,
        // result_kind matching the wrapper's return ABI. The runtime stores
        // result_kind on the closure header so every dispatch path can cast
        // `closure->evaluator` correctly.
        auto allocFuncK = runtime.getOrCreateAllocClosureK(rewriter);
        auto arityConst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(arity));
        auto resultKindConst = rewriter.create<LLVM::ConstantOp>(loc, i8Ty,
            rewriter.getI8IntegerAttr(static_cast<int8_t>(closureResultKind)));
        auto allocCall = rewriter.create<LLVM::CallOp>(loc, allocFuncK,
            ValueRange{funcPtr, arityConst, resultKindConst});
        Value closureHPtr = allocCall.getResult();

        // Convert HPointer to raw pointer for memory operations
        auto resolveCall = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{closureHPtr});
        Value closurePtr = resolveCall.getResult();

        // Closure bitmap covers ALL params (captures + remaining newargs)
        // so the runtime can read slot N's kind from `closure->unboxed`
        // alone — no separate layout descriptor is needed at apply sites.
        // The captures portion must agree with op.getUnboxedBitmap() (the
        // verifier already ties op.unboxed_bitmap to capture SSA types and
        // CLONE_RELATION_001 ties capture types to the target's first
        // num_captured params).
        bool isTyped = wrapperWillBeTypedNewargs(runtime, funcSymbol);
        uint64_t unboxedBitmap =
            isTyped ? deriveAllParamKindsBitmap(runtime, funcSymbol, arity)
                    : op.getUnboxedBitmap();
        auto f64Ty = Float64Type::get(ctx);

        // Phase C bit-pack layout (matching runtime/src/allocator/Heap.hpp):
        //   bits  0..5   n_values     (6 bits)
        //   bits  6..11  max_values   (6 bits)
        //   bits 12..13  result_kind  (2 bits, ParamKind)
        //   bits 14..63  unboxed      (50 bits, 25 typed-capture slots)
        //
        // Storing the packed field at offset 8 in one i64 write avoids the
        // GC barrier window that bit-by-bit writes would create. Match the
        // runtime layout *exactly*; any mismatch silently corrupts header
        // metadata.
        // Phase D: closureResultKind matches the wrapper's compiled
        // return ABI (both sourced from the op's `_result_kind`). The
        // packed bit-pattern below overwrites whatever
        // `eco_alloc_closure_k` initialised at the same offset.
        uint64_t packedValue =
              (static_cast<uint64_t>(numCaptured) & 0x3F)
            | ((static_cast<uint64_t>(arity) & 0x3F) << 6)
            | ((static_cast<uint64_t>(closureResultKind) & 0x3) << 12)
            | ((unboxedBitmap & ((1ULL << 50) - 1)) << 14);

        auto packedConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, rewriter.getI64IntegerAttr(packedValue));

        // Store packed field at offset 8
        auto offset8 =
            rewriter.create<LLVM::ConstantOp>(loc, i64Ty, rewriter.getI64IntegerAttr(layout::ClosurePackedOffset));
        auto packedPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, closurePtr, ValueRange{offset8});
        rewriter.create<LLVM::StoreOp>(loc, packedConst, packedPtr);

        // Store captured values starting at offset 24.
        // Unboxed values (Int, Float) are stored as raw i64 bits.
        // The unboxed_bitmap records which slots are raw for GC tracing.
        for (size_t i = 0; i < captured.size(); ++i) {
            int64_t valueOffset = layout::ClosureValuesOffset + i * layout::PtrSize;
            auto offsetConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, rewriter.getI64IntegerAttr(valueOffset));
            auto valuePtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, closurePtr, ValueRange{offsetConst});

            Value capturedValue = captured[i];
            if (auto intTy = dyn_cast<IntegerType>(capturedValue.getType());
                intTy && intTy.getWidth() < 64) {
                // Widen narrow int (Char i16) to i64 for storage
                capturedValue = rewriter.create<LLVM::ZExtOp>(loc, i64Ty, capturedValue);
            } else if (capturedValue.getType() == f64Ty) {
                // Bitcast f64 to i64 for storage
                capturedValue = rewriter.create<LLVM::BitcastOp>(loc, i64Ty, capturedValue);
            } else if (isa<LLVM::LLVMPointerType>(capturedValue.getType())) {
                // ptr<1> or ptr → i64 for closure values[] storage
                capturedValue = closureStoreValueToI64(rewriter, loc, capturedValue);
            }
            // i64 (both Int and !eco.value) stored directly
            rewriter.create<LLVM::StoreOp>(loc, capturedValue, valuePtr);
        }

        // Handle self-capturing closures: if self_capture_indices is present,
        // store the closure's own HPointer at the specified capture slots.
        // This implements recursive closure backpatching.
        // Note: self_capture_indices is emitted as array<i64: ...> (DenseI64ArrayAttr).
        if (auto selfCaptureAttr = op->getAttrOfType<DenseI64ArrayAttr>("self_capture_indices")) {
            // Convert closure HPointer (ptr<1>) to i64 for closure values[] storage
            Value closureI64 = closureStoreValueToI64(rewriter, loc, closureHPtr);
            for (int64_t selfIdx : selfCaptureAttr.asArrayRef()) {
                int64_t valueOffset = layout::ClosureValuesOffset + selfIdx * layout::PtrSize;
                auto offsetConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
                    rewriter.getI64IntegerAttr(valueOffset));
                auto valuePtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, closurePtr,
                    ValueRange{offsetConst});
                rewriter.create<LLVM::StoreOp>(loc, closureI64, valuePtr);
            }
        }

        rewriter.replaceOp(op, closureHPtr);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.papCreateGroup -> one eco_alloc_closure_group_slow call
//===----------------------------------------------------------------------===//

struct PapCreateGroupOpLowering : public OpConversionPattern<PapCreateGroupOp> {
    const EcoRuntime &runtime;

    PapCreateGroupOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                             const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult matchAndRewrite(PapCreateGroupOp op, OpAdaptor adaptor,
                                  ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i8Ty = IntegerType::get(ctx, 8);
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i64Ty = IntegerType::get(ctx, 64);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        auto functions = op.getFunctions();
        auto fastEvaluators = op.getFastEvaluators();
        auto arities = op.getArities();
        auto numCapturedArr = op.getNumCaptured();
        auto unboxedBitmaps = op.getUnboxedBitmaps();
        auto captureCounts = op.getCaptureCounts();
        auto crossEdges = op.getCrossEdges();

        const unsigned numSiblings = functions.size();

        // Partition adapted operands into captures (= sum of capture_counts)
        // followed by GC roots.
        auto [realOperands, liveRoots] =
            splitAdaptedRoots(op, adaptor.getOperands());

        // Resolve wrapper-function pointer for each sibling. Group members
        // always have captures so we use the fast_evaluator ($cap) form.
        // Phase E: typed-newargs wrappers; the typed flag and full-params
        // kinds bitmap are written by eco_alloc_closure_group_slow.
        auto module = op->getParentOfType<ModuleOp>();
        SmallVector<Value> wrapperPtrs;
        wrapperPtrs.reserve(numSiblings);
        // Per-sibling _result_kinds attribute is optional; absent ≡ all
        // siblings PK_Boxed. Each entry must be a ParamKind in [0, 3].
        // Phase D: the per-sibling K is passed both to the wrapper
        // (controls its return ABI) and into the resultKinds[] array
        // below (stored on each sibling's closure header).
        auto resultKindsAttr = op.get_resultKindsAttr();
        for (unsigned i = 0; i < numSiblings; ++i) {
            StringRef funcSymbol =
                cast<FlatSymbolRefAttr>(fastEvaluators[i]).getValue();
            int64_t arity = cast<IntegerAttr>(arities[i]).getInt();
            uint8_t siblingResultKind = 0;
            if (resultKindsAttr) {
                auto entries = resultKindsAttr.getValue();
                if (i < entries.size()) {
                    siblingResultKind = static_cast<uint8_t>(
                        cast<IntegerAttr>(entries[i]).getInt());
                }
            }
            auto wrapperFunc = getOrCreateWrapper(
                rewriter, module, funcSymbol, arity, loc,
                getTypeConverter(), runtime,
                /*typedNewargs=*/true,
                siblingResultKind);
            Value funcPtr = rewriter.create<LLVM::AddressOfOp>(
                loc, ptrTy, wrapperFunc.getSymName());
            wrapperPtrs.push_back(funcPtr);
        }

        // Allocate stack arrays to pass to the runtime.
        auto numSiblingsConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
            rewriter.getI64IntegerAttr(numSiblings));
        auto numSiblingsPlus1Const = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
            rewriter.getI64IntegerAttr(numSiblings + 1));

        Value evaluatorsArr = rewriter.create<LLVM::AllocaOp>(
            loc, ptrTy, ptrTy, numSiblingsConst);
        Value aritiesArr = rewriter.create<LLVM::AllocaOp>(
            loc, ptrTy, i32Ty, numSiblingsConst);
        Value numCapturedArrAlloca = rewriter.create<LLVM::AllocaOp>(
            loc, ptrTy, i32Ty, numSiblingsConst);
        Value unboxedBitmapsArr = rewriter.create<LLVM::AllocaOp>(
            loc, ptrTy, i64Ty, numSiblingsConst);
        Value resultKindsArr = rewriter.create<LLVM::AllocaOp>(
            loc, ptrTy, i8Ty, numSiblingsConst);
        Value captureOffsetsArr = rewriter.create<LLVM::AllocaOp>(
            loc, ptrTy, i32Ty, numSiblingsPlus1Const);
        Value outClosuresArr = rewriter.create<LLVM::AllocaOp>(
            loc, ptrTy, i64Ty, numSiblingsConst);

        // Store per-sibling static metadata.
        uint32_t runningOffset = 0;
        for (unsigned i = 0; i < numSiblings; ++i) {
            uint32_t arity = static_cast<uint32_t>(
                cast<IntegerAttr>(arities[i]).getInt());
            uint32_t nc = static_cast<uint32_t>(
                cast<IntegerAttr>(numCapturedArr[i]).getInt());
            // All-params bitmap derived from the target's typed signature
            // (Phase E). Subsumes the captures-only attribute on the op,
            // which is still verified for SSA-type consistency at MLIR
            // level but not used here.
            StringRef funcSymbol =
                cast<FlatSymbolRefAttr>(fastEvaluators[i]).getValue();
            uint64_t bitmap = deriveAllParamKindsBitmap(runtime, funcSymbol,
                                                        static_cast<int64_t>(arity));
            uint32_t cc = static_cast<uint32_t>(
                cast<IntegerAttr>(captureCounts[i]).getInt());

            auto idxConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
                rewriter.getI64IntegerAttr(i));

            // evaluators[i] = wrapperPtrs[i]
            auto evPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, ptrTy,
                evaluatorsArr, ValueRange{idxConst});
            rewriter.create<LLVM::StoreOp>(loc, wrapperPtrs[i], evPtr);

            // arities[i] = arity
            auto arConst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
                rewriter.getI32IntegerAttr(static_cast<int32_t>(arity)));
            auto arPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i32Ty,
                aritiesArr, ValueRange{idxConst});
            rewriter.create<LLVM::StoreOp>(loc, arConst, arPtr);

            // numCaptured[i] = nc
            auto ncConst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
                rewriter.getI32IntegerAttr(static_cast<int32_t>(nc)));
            auto ncPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i32Ty,
                numCapturedArrAlloca, ValueRange{idxConst});
            rewriter.create<LLVM::StoreOp>(loc, ncConst, ncPtr);

            // unboxedBitmaps[i] = bitmap
            auto bmConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
                rewriter.getI64IntegerAttr(static_cast<int64_t>(bitmap)));
            auto bmPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i64Ty,
                unboxedBitmapsArr, ValueRange{idxConst});
            rewriter.create<LLVM::StoreOp>(loc, bmConst, bmPtr);

            // resultKinds[i] — sibling i's evaluator return kind, stored
            // on the closure header so dispatch paths (legacy
            // eco_apply_closure, eco_apply_closure_eval, etc.) cast
            // `closure->evaluator` to the correct primitive-return
            // signature. Read from the same `_result_kinds` ArrayAttr
            // that drove the wrapper-resolution loop above.
            uint8_t siblingResultKindForHeader = 0;
            if (resultKindsAttr) {
                auto entries = resultKindsAttr.getValue();
                if (i < entries.size()) {
                    siblingResultKindForHeader = static_cast<uint8_t>(
                        cast<IntegerAttr>(entries[i]).getInt());
                }
            }
            auto rkConst = rewriter.create<LLVM::ConstantOp>(loc, i8Ty,
                rewriter.getI8IntegerAttr(static_cast<int8_t>(siblingResultKindForHeader)));
            auto rkPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty,
                resultKindsArr, ValueRange{idxConst});
            rewriter.create<LLVM::StoreOp>(loc, rkConst, rkPtr);

            // captureOffsets[i] = runningOffset
            auto offConst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
                rewriter.getI32IntegerAttr(static_cast<int32_t>(runningOffset)));
            auto offPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i32Ty,
                captureOffsetsArr, ValueRange{idxConst});
            rewriter.create<LLVM::StoreOp>(loc, offConst, offPtr);
            runningOffset += cc;
        }
        // captureOffsets[N] = totalCaptures
        {
            auto idxConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
                rewriter.getI64IntegerAttr(numSiblings));
            auto offConst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
                rewriter.getI32IntegerAttr(static_cast<int32_t>(runningOffset)));
            auto offPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i32Ty,
                captureOffsetsArr, ValueRange{idxConst});
            rewriter.create<LLVM::StoreOp>(loc, offConst, offPtr);
        }

        const uint32_t totalCaptures = runningOffset;
        auto totalCapturesConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
            rewriter.getI64IntegerAttr(totalCaptures == 0 ? 1 : totalCaptures));
        Value capturesArr = rewriter.create<LLVM::AllocaOp>(
            loc, ptrTy, i64Ty, totalCapturesConst);

        // Compute the HPointer mask for the FLAT captures array. Bit k is
        // set iff captures[k] is a boxed HPointer slot in its sibling's
        // closure (kind 00 in the per-sibling unboxed bitmap, 2 bits/slot).
        // This is the mask we must hand to eco_gc_push_stack_range so a
        // major GC firing inside eco_alloc_closure_group_slow scans the
        // captures correctly: without it, RS4GC sees the i64 stores into
        // the array but stops tracking the source ptr addrspace(1) values
        // once they go through ptrtoint, and the captures the runtime
        // copies into the new closures are stale (post-GC) addresses —
        // see Stage 7 unsafeIndex crash report.
        uint64_t hpointerMask = 0;
        {
            uint32_t flatOffset = 0;
            for (unsigned i = 0; i < numSiblings; ++i) {
                uint64_t bitmap = static_cast<uint64_t>(
                    cast<IntegerAttr>(unboxedBitmaps[i]).getInt());
                uint32_t cc = static_cast<uint32_t>(
                    cast<IntegerAttr>(captureCounts[i]).getInt());
                for (uint32_t k = 0; k < cc; ++k) {
                    if (flatOffset + k >= 64) break;
                    uint64_t kind = (bitmap >> (2 * k)) & 0x3;
                    if (kind == 0) {
                        hpointerMask |= (1ULL << (flatOffset + k));
                    }
                }
                flatOffset += cc;
            }
        }

        // Zero the captures array, save the GC range stack point, and push
        // the array as a GC root range BEFORE storing any values into it.
        // (totalCaptures must fit in 64 slots — the runtime asserts this.)
        Value savedRangeDepth;
        const bool needRootRange = totalCaptures > 0;
        if (needRootRange) {
            auto zeroI8 = rewriter.create<LLVM::ConstantOp>(loc, i8Ty, 0);
            auto bytesLen = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
                rewriter.getI64IntegerAttr(totalCaptures * 8));
            rewriter.create<LLVM::MemsetOp>(loc, capturesArr, zeroI8,
                bytesLen, /*isVolatile=*/false);
            auto rangePointFunc = runtime.getOrCreateGcStackRangePoint(rewriter);
            savedRangeDepth = rewriter.create<LLVM::CallOp>(
                loc, rangePointFunc, ValueRange{}).getResult();
            auto pushFunc = runtime.getOrCreateGcPushStackRange(rewriter);
            auto countConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
                rewriter.getI64IntegerAttr(totalCaptures));
            auto maskConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
                rewriter.getI64IntegerAttr(static_cast<int64_t>(hpointerMask)));
            rewriter.create<LLVM::CallOp>(loc, pushFunc,
                ValueRange{capturesArr, countConst, maskConst});
        }

        // Convert each capture to i64 and store in captures[].
        // realOperands is ordered [sibling0_caps..., sibling1_caps..., ...].
        for (uint32_t k = 0; k < totalCaptures; ++k) {
            Value capValue = realOperands[k];
            if (auto intTy = dyn_cast<IntegerType>(capValue.getType());
                intTy && intTy.getWidth() < 64) {
                capValue = rewriter.create<LLVM::ZExtOp>(loc, i64Ty, capValue);
            } else if (capValue.getType() == Float64Type::get(ctx)) {
                capValue = rewriter.create<LLVM::BitcastOp>(loc, i64Ty, capValue);
            } else if (isa<LLVM::LLVMPointerType>(capValue.getType())) {
                capValue = closureStoreValueToI64(rewriter, loc, capValue);
            }
            auto idxConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
                rewriter.getI64IntegerAttr(k));
            auto capPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i64Ty,
                capturesArr, ValueRange{idxConst});
            rewriter.create<LLVM::StoreOp>(loc, capValue, capPtr);
        }

        // cross_edges[] flat i64 triples.
        const uint64_t numCrossEdges = crossEdges.size() / 3;
        auto crossSizeConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
            rewriter.getI64IntegerAttr(crossEdges.empty() ? 1 : crossEdges.size()));
        Value crossEdgesArr = rewriter.create<LLVM::AllocaOp>(
            loc, ptrTy, i64Ty, crossSizeConst);
        for (size_t k = 0; k < crossEdges.size(); ++k) {
            int64_t v = cast<IntegerAttr>(crossEdges[k]).getInt();
            auto vConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
                rewriter.getI64IntegerAttr(v));
            auto idxConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
                rewriter.getI64IntegerAttr(k));
            auto slotPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i64Ty,
                crossEdgesArr, ValueRange{idxConst});
            rewriter.create<LLVM::StoreOp>(loc, vConst, slotPtr);
        }

        auto numCrossConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
            rewriter.getI64IntegerAttr(static_cast<int64_t>(numCrossEdges)));

        emitSafepointMarker(op, rewriter, runtime, liveRoots);

        auto groupFunc = runtime.getOrCreateAllocClosureGroupSlow(rewriter);
        rewriter.create<LLVM::CallOp>(loc, groupFunc, ValueRange{
            numSiblingsConst,
            evaluatorsArr,
            aritiesArr,
            numCapturedArrAlloca,
            unboxedBitmapsArr,
            resultKindsArr,
            captureOffsetsArr,
            capturesArr,
            crossEdgesArr,
            numCrossConst,
            outClosuresArr
        });

        // Restore the range point so the captures array no longer counts as
        // a GC root once the new closures hold their own copies.
        if (needRootRange) {
            auto restoreFunc = runtime.getOrCreateGcRestoreStackRangePoint(rewriter);
            rewriter.create<LLVM::CallOp>(loc, restoreFunc,
                ValueRange{savedRangeDepth});
        }

        // Load result HPointers from outClosures[] and deliver them as the
        // op's results. Each load yields an i64 which we turn into ptr<1>
        // (the closure Eco_Value SSA type).
        auto hptrPtrTy = getHPtrLLVMType(*ctx);
        SmallVector<Value> results;
        results.reserve(numSiblings);
        for (unsigned i = 0; i < numSiblings; ++i) {
            auto idxConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
                rewriter.getI64IntegerAttr(i));
            auto slotPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i64Ty,
                outClosuresArr, ValueRange{idxConst});
            Value loadedI64 = rewriter.create<LLVM::LoadOp>(loc, i64Ty, slotPtr);
            Value asHPtr = rewriter.create<LLVM::IntToPtrOp>(
                loc, hptrPtrTy, ValueRange{loadedI64});
            results.push_back(asHPtr);
        }

        rewriter.replaceOp(op, results);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Typed closure call helpers (Phase 5 - Typed Closure Calling)
//===----------------------------------------------------------------------===//

/// Emit a typed closure call when capture ABI is known at compile time.
/// Loads captures from closure, calls fast clone directly with typed args.
/// This is used when _dispatch_mode="fast".
static Value emitFastClosureCall(ConversionPatternRewriter &rewriter, Location loc, const EcoRuntime &runtime,
                                 Value closureI64, ValueRange newArgs, SymbolRefAttr fastEvaluator,
                                 ArrayAttr captureAbiTypes, Type resultType,
                                 Operation *safeOp = nullptr, ValueRange liveRoots = {}) {
    auto *ctx = rewriter.getContext();
    auto i8Ty = IntegerType::get(ctx, 8);
    auto i64Ty = IntegerType::get(ctx, 64);
    auto f64Ty = Float64Type::get(ctx);
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);

    // Resolve closure HPointer to raw pointer
    auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
    auto resolveCall = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{closureI64});
    Value closurePtr = resolveCall.getResult();

    // E0.4 (LSS dispatch-value plan): count this stamped fast-dispatch execution
    // under ECO_DISPATCH_STATS. Emitted ONLY when ECO_LSS_DISPATCH_SITE_COUNTERS is
    // set at lowering time (census builds); inert otherwise. Keyed on the LIVE
    // closure->evaluator so the `fast` row joins the same fp as the `sat`/`gen`
    // rows for this closure. The E2E binary cache is mtime/config-blind, so this
    // env is census-workflow-only, never under the harness.
    static const bool lssDispatchSiteCounters =
        (::getenv("ECO_LSS_DISPATCH_SITE_COUNTERS") != nullptr);
    if (lssDispatchSiteCounters) {
        auto evalOffset = rewriter.create<LLVM::ConstantOp>(
            loc, i64Ty, rewriter.getI64IntegerAttr(layout::ClosureEvaluatorOffset));
        auto evalPtrPtr = rewriter.create<LLVM::GEPOp>(
            loc, ptrTy, i8Ty, closurePtr, ValueRange{evalOffset});
        Value evaluatorFp = rewriter.create<LLVM::LoadOp>(loc, ptrTy, evalPtrPtr);
        auto statsFunc = runtime.getOrCreateDispatchStatsFast(rewriter);
        rewriter.create<LLVM::CallOp>(loc, statsFunc, ValueRange{evaluatorFp});
    }

    // Build argument list: captures from closure + newArgs
    SmallVector<Value> callArgs;
    SmallVector<Type> paramTypes;

    // Load captures from closure values array based on captureAbiTypes
    for (size_t i = 0; i < captureAbiTypes.size(); ++i) {
        int64_t valueOffset = layout::ClosureValuesOffset + i * layout::PtrSize;
        auto offsetConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, rewriter.getI64IntegerAttr(valueOffset));
        auto valuePtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, closurePtr, ValueRange{offsetConst});
        Value loadedValue = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valuePtr);

        // Convert loaded i64 to the capture's actual type
        // captureAbiTypes contains TypeAttr elements
        auto typeAttr = mlir::dyn_cast<TypeAttr>(captureAbiTypes[i]);
        Type captureType = typeAttr ? typeAttr.getValue() : i64Ty;
        Value captureVal = loadedValue;

        if (captureType.isF64()) {
            captureVal = rewriter.create<LLVM::BitcastOp>(loc, f64Ty, loadedValue);
            paramTypes.push_back(f64Ty);
        } else if (isa<LLVM::LLVMPointerType>(captureType)) {
            captureVal = rewriter.create<LLVM::IntToPtrOp>(loc, captureType, loadedValue);
            paramTypes.push_back(captureType);
        } else {
            // i64 or other integer types
            paramTypes.push_back(i64Ty);
        }
        callArgs.push_back(captureVal);
    }

    // Add new arguments
    for (Value arg : newArgs) {
        callArgs.push_back(arg);
        paramTypes.push_back(arg.getType());
    }

    // Get address of fast clone function. Deliberately the AddressOf+indirect
    // form: the SITE-derived funcType can differ from the callee's converted
    // signature (erased/boxed i64<->ptr classes), and a direct MLIR call is
    // translation-asserted against the callee's real type. The E1.2/E1.3 fold
    // in the backend (`runCapInlinePrepass`, EcoBackend.cpp) rebuilds these
    // sites as well-typed DIRECT calls at LLVM-IR level — where the real
    // callee signature is visible — with bit-identical coercions, so the
    // pre-RS4GC AlwaysInliner can then inline them.
    auto flatSymbol = FlatSymbolRefAttr::get(ctx, fastEvaluator.getRootReference());
    Value funcPtr = rewriter.create<LLVM::AddressOfOp>(loc, ptrTy, flatSymbol);

    // Build function type and indirect call (funcPtr first, then args)
    Type llvmResultType = resultType;
    auto funcType = LLVM::LLVMFunctionType::get(llvmResultType, paramTypes, /*isVarArg=*/false);
    SmallVector<Value> callOperands;
    callOperands.push_back(funcPtr);
    callOperands.append(callArgs.begin(), callArgs.end());
    if (safeOp)
        emitSafepointMarker(safeOp, rewriter, runtime, liveRoots);
    auto callOp = rewriter.create<LLVM::CallOp>(loc, funcType, callOperands);

    return callOp.getResult();
}

/// Emit a closure call via the generic clone.
/// Calls the generic clone stored in closure.evaluator with (Closure*, args...).
/// This is used when _dispatch_mode="closure".
static Value emitClosureCall(ConversionPatternRewriter &rewriter, Location loc, const EcoRuntime &runtime,
                             Value closureI64, ValueRange newArgs, Type resultType,
                             Operation *safeOp = nullptr, ValueRange liveRoots = {}) {
    auto *ctx = rewriter.getContext();
    auto i8Ty = IntegerType::get(ctx, 8);
    auto i64Ty = IntegerType::get(ctx, 64);
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);

    // Resolve closure HPointer to raw pointer
    auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
    auto resolveCall = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{closureI64});
    Value closurePtr = resolveCall.getResult();

    // Load evaluator pointer (generic clone) at offset 16
    auto offset16 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::ClosureEvaluatorOffset);
    auto evalPtrPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, closurePtr, ValueRange{offset16});
    Value evaluator = rewriter.create<LLVM::LoadOp>(loc, ptrTy, evalPtrPtr);

    // Build argument list: closurePtr + newArgs
    SmallVector<Value> callArgs;
    SmallVector<Type> paramTypes;

    // First arg is the closure pointer (not HPointer)
    callArgs.push_back(closurePtr);
    paramTypes.push_back(ptrTy);

    // Add new arguments
    for (Value arg : newArgs) {
        callArgs.push_back(arg);
        paramTypes.push_back(arg.getType());
    }

    // Build function type and indirect call
    Type llvmResultType = resultType;
    auto funcType = LLVM::LLVMFunctionType::get(llvmResultType, paramTypes, /*isVarArg=*/false);

    SmallVector<Value> callOperands;
    callOperands.push_back(evaluator);
    callOperands.append(callArgs.begin(), callArgs.end());
    if (safeOp)
        emitSafepointMarker(safeOp, rewriter, runtime, liveRoots);
    auto callOp = rewriter.create<LLVM::CallOp>(loc, funcType, callOperands);

    return callOp.getResult();
}

/// Emit a closure call when dispatch mode is unknown.
/// Logs a diagnostic and falls back to generic closure call via emitInlineClosureCall.
/// This is used when _dispatch_mode="unknown".
static Value emitUnknownClosureCall(ConversionPatternRewriter &rewriter, Location loc, const EcoRuntime &runtime,
                                    Value closureI64, ValueRange newArgs, Type resultType,
                                    ArrayRef<Type> origNewArgTypes = {},
                                    Type origResultType = {},
                                    Operation *safeOp = nullptr, ValueRange liveRoots = {});  // Forward declaration

/// Dispatch a closure call based on the _dispatch_mode attribute.
/// Returns Value() and emits error if dispatch mode is invalid or missing required attributes.
static Value emitDispatchedClosureCall(ConversionPatternRewriter &rewriter, Location loc, const EcoRuntime &runtime,
                                       Operation *op, Value closureI64, ValueRange newArgs, Type resultType,
                                       ArrayRef<Type> origNewArgTypes = {},
                                       Type origResultType = {},
                                       ValueRange liveRoots = {}) {
    auto dispatchMode = op->getAttrOfType<StringAttr>("_dispatch_mode");

    // Missing _dispatch_mode on a closure call = pipeline bug
    if (!dispatchMode) {
        op->emitError("closure call missing _dispatch_mode attribute");
        return Value();
    }

    StringRef mode = dispatchMode.getValue();

    if (mode == "fast") {
        auto fastEval = op->getAttrOfType<SymbolRefAttr>("_fast_evaluator");
        auto captureAbi = op->getAttrOfType<ArrayAttr>("_capture_abi");
        if (!fastEval || !captureAbi) {
            op->emitError("_dispatch_mode='fast' requires _fast_evaluator and _capture_abi attributes");
            return Value();
        }
        return emitFastClosureCall(rewriter, loc, runtime, closureI64, newArgs, fastEval, captureAbi, resultType,
                                   op, liveRoots);
    }

    if (mode == "closure") {
        return emitClosureCall(rewriter, loc, runtime, closureI64, newArgs, resultType,
                               op, liveRoots);
    }

    if (mode == "unknown") {
        return emitUnknownClosureCall(rewriter, loc, runtime, closureI64, newArgs, resultType,
                                      origNewArgTypes, origResultType,
                                      op, liveRoots);
    }

    op->emitError("unrecognized _dispatch_mode: ") << mode;
    return Value();
}

//===----------------------------------------------------------------------===//
// Layout global emission for type-aware buildEvaluatorArgs
//===----------------------------------------------------------------------===//

/// Map an MLIR type to a ParamKind value for the EvalParamLayout.
/// i64 -> PK_Int(1), f64 -> PK_Float(2), i16 -> PK_Char(3), else -> PK_Boxed(0)
static uint8_t mlirTypeToParamKind(Type ty) {
    if (ty.isInteger(64)) return 1;  // PK_Int
    if (ty.isF64()) return 2;        // PK_Float
    if (ty.isInteger(16)) return 3;  // PK_Char
    return 0;                        // PK_Boxed
}

/// Derive the 2-bit-per-slot kinds bitmap covering every parameter of the
/// target function (captures + remaining newargs). Used by PapCreate to
/// publish a complete kinds bitmap on the closure header so the runtime can
/// interpret slot N's kind without a separate layout descriptor.
///
/// Slot i's kind comes from the i-th parameter of the target function via
/// mlirTypeToParamKind. The lookup chain mirrors getOrCreateWrapper's so
/// the bitmap and the wrapper see the same parameter signature: any
/// divergence makes the wrapper unbox raw primitives from slots whose
/// closure->unboxed bitmap says PK_Boxed, and spliceArgsForSaturatedCall
/// then mis-routes args. If no source resolves the symbol we abort hard
/// rather than silently default to all-PK_Boxed.
static uint64_t deriveAllParamKindsBitmap(const EcoRuntime &runtime,
                                          StringRef funcSymbol, int64_t arity) {
    SmallVector<Type, 8> paramTypes;
    if (auto it = runtime.origFuncTypes.find(funcSymbol);
        it != runtime.origFuncTypes.end()) {
        for (Type t : it->second.getInputs())
            paramTypes.push_back(t);
    } else if (auto funcFunc =
                   runtime.lookupSymbol<func::FuncOp>(funcSymbol)) {
        for (Type t : funcFunc.getFunctionType().getInputs())
            paramTypes.push_back(t);
    } else if (auto llvmFunc =
                   runtime.lookupSymbol<LLVM::LLVMFuncOp>(funcSymbol)) {
        auto fnType = llvmFunc.getFunctionType();
        // Post-conversion LLVM types still answer mlirTypeToParamKind
        // correctly: ptr addrspace(1) → PK_Boxed, i64 → PK_Int, f64 →
        // PK_Float, i16 → PK_Char.
        for (unsigned i = 0; i < fnType.getNumParams(); ++i)
            paramTypes.push_back(fnType.getParamType(i));
    } else {
        llvm::report_fatal_error(
            "deriveAllParamKindsBitmap: no signature available for '" +
            funcSymbol +
            "'; closure bitmap would silently default to PK_Boxed and "
            "diverge from the wrapper's typed-newargs decoding");
    }

    uint64_t bitmap = 0;
    int64_t lim = arity;
    if (lim > (int64_t)paramTypes.size()) lim = (int64_t)paramTypes.size();
    for (int64_t i = 0; i < lim; ++i) {
        uint64_t kind = mlirTypeToParamKind(paramTypes[i]) & 0x3ULL;
        bitmap |= kind << (2 * i);
    }
    return bitmap;
}

/// Predict whether `getOrCreateWrapper(.., typedNewargs=true)` will produce
/// a real typed wrapper, or short-circuit to an existing args-array-style
/// function. The latter happens for hand-written test fixtures whose
/// target already has signature `(ptr) -> {ptr,i64}`; those carry the
/// legacy boxed convention and must record their slots as PK_Boxed in
/// `closure->unboxed[i]`.
static bool wrapperWillBeTypedNewargs(const EcoRuntime &runtime,
                                       StringRef funcSymbol) {
    // See getOrCreateWrapper: a normal eco function (present in origFuncTypes)
    // is an llvm.func shell after signature conversion whose shape can look
    // args-array; only a NOT-pre-scanned hand-written llvm.func is genuinely
    // args-array convention. Keying on origFuncTypes makes this robust to the
    // func.func->llvm.func conversion timing (which the Stage0/Stage2 split
    // changes: all targets are shells by the time this predicts).
    if (!runtime.origFuncTypes.contains(funcSymbol)) {
        if (auto existingFunc = runtime.lookupSymbol<LLVM::LLVMFuncOp>(funcSymbol)) {
            if (usesArgsArrayConvention(existingFunc)) return false;
        }
    }
    return true;
}

/// Emit (or reuse) an LLVM global constant for an EvalParamLayout with the
/// given kind sequence. Layout is `{ i8 num_params, i8 result_kind, [N x i8] kinds }`,
/// matching `EvalParamLayout` in `Heap.hpp`. Deduplicates by encoding the
/// kinds and result kind into the global's name.
///
/// `resultKind` is the closure evaluator's real C-ABI return kind
/// (ParamKind: 0=Boxed, 1=Int, 2=Float, 3=Char). Existing callers that
/// don't yet plumb a Mono result type pass 0 (PK_Boxed), preserving
/// today's "wrappers always return HPtr" behaviour.
// OpBuilder-based global creator (callable from the Phase-2 serial pre-pass).
// Creates the __eco_eval_layout_* global if absent; no-op if it already exists.
static void ensureEvalLayoutGlobal(OpBuilder &builder, Location loc,
                                   const EcoRuntime &runtime,
                                   ArrayRef<uint8_t> kinds, uint8_t resultKind) {
    auto *ctx = builder.getContext();
    ModuleOp module = runtime.module;
    auto i8Ty = IntegerType::get(ctx, 8);
    uint32_t n = kinds.size();
    llvm::SmallString<48> nameBuf;
    {
        llvm::raw_svector_ostream os(nameBuf);
        os << "__eco_eval_layout_r" << unsigned(resultKind) << "_";
        for (uint8_t k : kinds) os << unsigned(k) << "_";
        os << n;
    }
    StringRef name = nameBuf;
    // Eval-layouts are the ONE artifact class whose exact demand cannot be
    // pre-derived, so they are created on demand here even during parallel
    // Stage 2. They are referenced ONLY by name via AddressOfOp (never looked
    // up in symCache), so they live in a dedicated dedup set guarded by their
    // own mutex — leaving the hot symCache LOCK-FREE. insert().second is false
    // if already created (this worker earlier or another); the lock is held
    // through creation so the module.getBody() insertion is serialized across
    // workers. Content-keyed, ~dozens exist, taken per closure-apply site.
    auto key = mlir::StringAttr::get(ctx, name);
    std::lock_guard<std::mutex> lk(runtime.evalLayoutMutex);
    if (!runtime.evalLayoutNames.insert(key).second)
        return;  // already created
    auto arrayTy = LLVM::LLVMArrayType::get(i8Ty, n);
    auto structTy = LLVM::LLVMStructType::getLiteral(ctx, {i8Ty, i8Ty, arrayTy});
    OpBuilder::InsertionGuard guard(builder);
    builder.setInsertionPointToStart(module.getBody());
    auto globalOp = builder.create<LLVM::GlobalOp>(
        loc, structTy, /*isConstant=*/true, LLVM::Linkage::Private, name, Attribute{});
    Block *initBlock = builder.createBlock(&globalOp.getInitializerRegion());
    builder.setInsertionPointToStart(initBlock);
    Value structVal = builder.create<LLVM::UndefOp>(loc, structTy);
    auto numParamsConst = builder.create<LLVM::ConstantOp>(loc, i8Ty, static_cast<int64_t>(n));
    structVal = builder.create<LLVM::InsertValueOp>(loc, structTy, structVal, numParamsConst,
                                                    ArrayRef<int64_t>{0});
    auto resultKindConst = builder.create<LLVM::ConstantOp>(loc, i8Ty, static_cast<int64_t>(resultKind));
    structVal = builder.create<LLVM::InsertValueOp>(loc, structTy, structVal, resultKindConst,
                                                    ArrayRef<int64_t>{1});
    Value arrayVal = builder.create<LLVM::UndefOp>(loc, arrayTy);
    for (uint32_t i = 0; i < n; ++i) {
        auto kindConst = builder.create<LLVM::ConstantOp>(loc, i8Ty, static_cast<int64_t>(kinds[i]));
        arrayVal = builder.create<LLVM::InsertValueOp>(loc, arrayTy, arrayVal, kindConst,
                                                       ArrayRef<int64_t>{static_cast<int64_t>(i)});
    }
    structVal = builder.create<LLVM::InsertValueOp>(loc, structTy, structVal, arrayVal,
                                                    ArrayRef<int64_t>{2});
    builder.create<LLVM::ReturnOp>(loc, structVal);
}

// Thin per-use wrapper: ensure the global exists (hits cache in Stage 2 since
// pre-materialized), then take its address in the current function.
static Value getOrCreateEvalLayout(ConversionPatternRewriter &rewriter, Location loc,
                                   const EcoRuntime &runtime, ArrayRef<uint8_t> kinds,
                                   uint8_t resultKind = 0) {
    auto *ctx = rewriter.getContext();
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);
    ensureEvalLayoutGlobal(rewriter, loc, runtime, kinds, resultKind);
    llvm::SmallString<48> nameBuf;
    {
        llvm::raw_svector_ostream os(nameBuf);
        os << "__eco_eval_layout_r" << unsigned(resultKind) << "_";
        for (uint8_t k : kinds) os << unsigned(k) << "_";
        os << unsigned(kinds.size());
    }
    return rewriter.create<LLVM::AddressOfOp>(loc, ptrTy, StringRef(nameBuf));
}

//===----------------------------------------------------------------------===//
// emitClosureEvalCall — typed-result generic apply
//===----------------------------------------------------------------------===//

/// Emit an LLVM call to `eco_apply_closure_eval` with a typed result slot.
/// Used by `lowerGenericApply` and `lowerSegmentationUnknown` to honour
/// primitive results from closures whose evaluator returns a primitive
/// (per the layout's `result_kind`).
///
/// The helper:
///   1. Allocates a result slot of `resultLLVMType` at the function entry
///      block (so the alloca outlives any GC safepoints).
///   2. Calls `eco_apply_closure_eval(closureHPtr, typed_args, num_args,
///      layout, &result_slot, desired_kind)`.
///   3. Loads the result slot at `resultLLVMType` and returns the loaded value.
///
/// `desiredKind` (ParamKind: 0=Boxed, 1=Int, 2=Float, 3=Char) selects the
/// caller's desired result kind. The layout's `result_kind` encodes the
/// closure evaluator's actual return kind; the runtime helper bridges the
/// two by boxing or extracting as needed.
static Value emitClosureEvalCall(ConversionPatternRewriter &rewriter,
                                 Location loc,
                                 const EcoRuntime &runtime,
                                 Operation *safeOp,
                                 Value closureHPtr,
                                 Value typedArgsArray,
                                 Value numArgsI32,
                                 Value layoutPtr,
                                 Type resultLLVMType,
                                 uint8_t desiredKind) {
    auto *ctx = rewriter.getContext();
    auto i64Ty = IntegerType::get(ctx, 64);
    auto i8Ty = IntegerType::get(ctx, 8);
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);

    // Allocate the result slot at the function entry block so its lifetime
    // covers any subsequent safepoints (GC moves can update slot contents
    // for boxed results, but the slot itself must remain valid).
    Value resultSlot;
    {
        OpBuilder::InsertionGuard guard(rewriter);
        auto parentFunc = safeOp ? safeOp->getParentOfType<LLVM::LLVMFuncOp>() : nullptr;
        if (parentFunc) rewriter.setInsertionPointToStart(&parentFunc.getBody().front());
        auto oneConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 1);
        resultSlot = rewriter.create<LLVM::AllocaOp>(loc, ptrTy, resultLLVMType, oneConst);
    }

    // Zero-init the slot so a partially-completed apply (e.g. one that
    // throws) leaves a defined value.
    {
        Value zero;
        if (resultLLVMType == i64Ty || resultLLVMType.isInteger(64)) {
            zero = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 0);
        } else if (resultLLVMType.isF64()) {
            auto zeroI = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 0);
            zero = rewriter.create<LLVM::BitcastOp>(loc, resultLLVMType, zeroI);
        } else if (auto intTy = dyn_cast<IntegerType>(resultLLVMType)) {
            zero = rewriter.create<LLVM::ConstantOp>(loc, intTy, 0);
        } else if (isa<LLVM::LLVMPointerType>(resultLLVMType)) {
            // Pointer-typed slot (e.g. ptr addrspace(1) for !eco.value):
            // store null via inttoptr.
            auto zeroI = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 0);
            zero = rewriter.create<LLVM::IntToPtrOp>(loc, resultLLVMType, ValueRange{zeroI});
        }
        if (zero) rewriter.create<LLVM::StoreOp>(loc, zero, resultSlot);
    }

    auto desiredKindConst = rewriter.create<LLVM::ConstantOp>(loc, i8Ty,
        static_cast<int64_t>(desiredKind));

    auto evalFunc = runtime.getOrCreateApplyClosureEval(rewriter);
    rewriter.create<LLVM::CallOp>(loc, evalFunc,
        ValueRange{closureHPtr, typedArgsArray, numArgsI32, layoutPtr,
                   resultSlot, desiredKindConst});

    Value result = rewriter.create<LLVM::LoadOp>(loc, resultLLVMType, resultSlot);
    return result;
}

//===----------------------------------------------------------------------===//
// Shared helper: inline closure call (legacy path)
//===----------------------------------------------------------------------===//

/// Emit inline LLVM ops to call a closure's evaluator with combined
/// (captured + new) arguments. Used by both papExtend-saturated and
/// indirect eco.call.
///
/// closureI64:      the closure HPointer as i64
/// newArgs:         the new arguments to append (already type-converted)
/// resultType:      the expected LLVM result type (i64, f64, or ptr)
/// origNewArgTypes: pre-conversion types for new args (to distinguish Int from !eco.value)
/// origResultType:  pre-conversion result type (to distinguish Int from !eco.value)
/// layoutPtr:       optional layout pointer for type-aware re-boxing (nullptr = legacy)
///
/// Phase E: this function feeds the closure's typed wrapper, which reads
/// each slot per its compile-time function-type slot kind (REP_ABI_001).
/// New args are stored as raw 64-bit slots — primitive args go in raw,
/// HPointer args go in as HPointer bits — without any eco_alloc_*
/// re-boxing on the args side.
///
/// The result side still re-boxes primitive returns into HPointers (the
/// wrapper does this on return), so the post-call unbox path is unchanged.
static Value emitInlineClosureCall(ConversionPatternRewriter &rewriter, Location loc, const EcoRuntime &runtime,
                                   Value closureI64, ValueRange newArgs, Type resultType,
                                   ArrayRef<Type> origNewArgTypes = {},
                                   Type origResultType = {},
                                   Operation *safeOp = nullptr, ValueRange liveRoots = {},
                                   Value layoutPtr = {}) {
    auto *ctx = rewriter.getContext();
    auto i8Ty = IntegerType::get(ctx, 8);
    auto i64Ty = IntegerType::get(ctx, 64);
    auto i32Ty = IntegerType::get(ctx, 32);
    auto f64Ty = Float64Type::get(ctx);
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);

    int64_t numNewArgs = newArgs.size();
    bool hasOrigNewArgTypes = !origNewArgTypes.empty();

    // Allocate array for new args only — hoisted to entry block.
    Value newArgsArray;
    {
        OpBuilder::InsertionGuard allocaGuard(rewriter);
        auto parentFunc = safeOp->getParentOfType<LLVM::LLVMFuncOp>();
        if (parentFunc) rewriter.setInsertionPointToStart(&parentFunc.getBody().front());
        auto numNewArgsConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, numNewArgs);
        newArgsArray = rewriter.create<LLVM::AllocaOp>(loc, ptrTy, i64Ty, numNewArgsConst);
    }

    // GC root mask for the args buffer: only HPointer-typed slots scan as
    // pointers, primitive slots are skipped. Compute statically from
    // origNewArgTypes (the SSA types pre-conversion) so the mask reflects
    // the typed convention rather than the old all-boxed assumption.
    uint64_t hptrMask = 0;
    for (size_t j = 0; j < newArgs.size() && j < 64; ++j) {
        Type t = (hasOrigNewArgTypes && j < origNewArgTypes.size())
                     ? origNewArgTypes[j] : newArgs[j].getType();
        bool isBoxed = false;
        if (isa<eco::ValueType>(t)) {
            isBoxed = true;
        } else if (isa<LLVM::LLVMPointerType>(t)) {
            isBoxed = true;
        }
        if (isBoxed) hptrMask |= (uint64_t{1} << j);
    }
    Value savedRange = emitPushArgsRootRange(rewriter, loc, runtime, newArgsArray, numNewArgs, hptrMask);

    // Store each arg as a raw 64-bit slot. Primitive Int/Char slots are
    // zero-extended to i64; Float slots are bitcast through i64; HPointer
    // slots are stored via closureStoreValueToI64.
    for (size_t j = 0; j < newArgs.size(); ++j) {
        auto jConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, static_cast<int64_t>(j));
        auto argDstPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i64Ty, newArgsArray, ValueRange{jConst});
        Value arg = newArgs[j];

        if (auto intTy = dyn_cast<IntegerType>(arg.getType()); intTy && intTy.getWidth() < 64) {
            arg = rewriter.create<LLVM::ZExtOp>(loc, i64Ty, arg);
        } else if (arg.getType() == f64Ty) {
            arg = rewriter.create<LLVM::BitcastOp>(loc, i64Ty, arg);
        } else if (isa<LLVM::LLVMPointerType>(arg.getType())) {
            arg = closureStoreValueToI64(rewriter, loc, arg);
        }
        // i64 (Int) is stored directly.
        rewriter.create<LLVM::StoreOp>(loc, arg, argDstPtr);
    }

    // === Build the per-slot ParamKind layout for new_args ===
    // The runtime needs this to know the kind of each typed arg slot so it
    // can un-box (caller passed PK_Boxed; closure expects a primitive) or
    // box (rare opposite) at the splice. Build from origNewArgTypes (or
    // fall back to the SSA types when those aren't available).
    auto numNewArgsI32 = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int64_t>(numNewArgs));

    Value layoutArg;
    if (layoutPtr) {
        layoutArg = layoutPtr;
    } else if (numNewArgs > 0) {
        SmallVector<uint8_t> kinds;
        kinds.reserve(numNewArgs);
        for (size_t j = 0; j < newArgs.size(); ++j) {
            Type t = (hasOrigNewArgTypes && j < origNewArgTypes.size())
                         ? origNewArgTypes[j] : newArgs[j].getType();
            kinds.push_back(mlirTypeToParamKind(t));
        }
        // Phase D: layout's `result_kind` byte mirrors the closure
        // evaluator's compiled return ABI (sourced from the call op's
        // `_result_kind` attribute). The runtime helper reads K from the
        // closure header authoritatively, but it debug-asserts the
        // layout's K matches — populating it correctly here keeps that
        // assertion happy and documents the call-site's expectation.
        uint8_t inlineResultKind = 0;
        if (safeOp) {
            if (auto attr = safeOp->getAttrOfType<IntegerAttr>("_result_kind"))
                inlineResultKind = static_cast<uint8_t>(attr.getInt());
        }
        auto module = safeOp ? safeOp->getParentOfType<ModuleOp>() : ModuleOp{};
        if (module) {
            layoutArg = getOrCreateEvalLayout(rewriter, loc, runtime, kinds,
                                              inlineResultKind);
        } else {
            layoutArg = rewriter.create<LLVM::ZeroOp>(loc, ptrTy).getResult();
        }
    } else {
        layoutArg = rewriter.create<LLVM::ZeroOp>(loc, ptrTy).getResult();
    }

    // === Pick the typed-result entry point when the call's result type is
    // primitive (i64/f64/i16). The boxed-result eco_closure_call_saturated
    // hardcodes desired_kind=0 in its K!=0 path → it boxes every Int/Float/
    // Char return with eco_alloc_int/float/char and the JIT immediately
    // unboxes via resolve+load. Routing through eco_closure_call_saturated_
    // eval lets the wrapper write the primitive straight into the result
    // slot (no allocation, no resolve, no load-at-offset-8). ===
    auto i16Ty = IntegerType::get(ctx, 16);
    uint8_t desiredKind = 0;
    Type slotTy = ptrTy;
    if (origResultType) {
        if (origResultType.isInteger(64))      { desiredKind = 1; slotTy = i64Ty; }
        else if (origResultType.isF64())        { desiredKind = 2; slotTy = f64Ty; }
        else if (auto it = dyn_cast<IntegerType>(origResultType);
                 it && it.getWidth() < 64)       { desiredKind = 3; slotTy = i16Ty; }
        // !eco.value or other → desiredKind stays 0.
    } else {
        // No origResultType: fall back to the converted resultType. Treat
        // raw i64 as Int (matches the legacy heuristic a few lines below
        // that boxed an HPtr-returning Int via resolve+load).
        if (resultType.isInteger(64))           { desiredKind = 1; slotTy = i64Ty; }
        else if (resultType.isF64())             { desiredKind = 2; slotTy = f64Ty; }
        else if (auto it = dyn_cast<IntegerType>(resultType);
                 it && it.getWidth() < 64)        { desiredKind = 3; slotTy = i16Ty; }
    }

    if (desiredKind != 0) {
        // Allocate a primitive-typed result slot at function entry so its
        // lifetime spans any safepoint.
        Value resultSlot;
        {
            OpBuilder::InsertionGuard guard(rewriter);
            auto parentFunc = safeOp ? safeOp->getParentOfType<LLVM::LLVMFuncOp>() : nullptr;
            if (parentFunc) rewriter.setInsertionPointToStart(&parentFunc.getBody().front());
            auto oneConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 1);
            resultSlot = rewriter.create<LLVM::AllocaOp>(loc, ptrTy, slotTy, oneConst);
        }
        // Zero-init so a partially-completed apply leaves a defined value.
        Value zero;
        if (desiredKind == 1) {
            zero = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 0);
        } else if (desiredKind == 2) {
            auto zeroI = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 0);
            zero = rewriter.create<LLVM::BitcastOp>(loc, f64Ty, zeroI);
        } else {
            zero = rewriter.create<LLVM::ConstantOp>(loc, i16Ty, 0);
        }
        rewriter.create<LLVM::StoreOp>(loc, zero, resultSlot);

        auto desiredKindConst = rewriter.create<LLVM::ConstantOp>(loc, i8Ty,
            static_cast<int64_t>(desiredKind));
        auto evalFunc = runtime.getOrCreateClosureCallSaturatedEval(rewriter);
        if (safeOp)
            emitSafepointMarker(safeOp, rewriter, runtime, liveRoots);
        rewriter.create<LLVM::CallOp>(loc, evalFunc,
            ValueRange{closureI64, newArgsArray, numNewArgsI32, layoutArg,
                       resultSlot, desiredKindConst});

        emitRestoreArgsRootRange(rewriter, loc, runtime, savedRange);

        Value result = rewriter.create<LLVM::LoadOp>(loc, slotTy, resultSlot);
        // Adapt to caller's expected resultType if it differs in width
        // (e.g. resultType is the converted Char/i32 form). The slotTy ==
        // resultType case is the common one.
        if (slotTy != resultType) {
            if (auto ity = dyn_cast<IntegerType>(resultType);
                ity && ity.getWidth() < 16 && desiredKind == 3) {
                result = rewriter.create<LLVM::TruncOp>(loc, resultType, result);
            }
        }
        return result;
    }

    // === Boxed-result path: closure → HPtr → caller ===
    auto closureCallFunc = runtime.getOrCreateClosureCallSaturated(rewriter);
    if (safeOp)
        emitSafepointMarker(safeOp, rewriter, runtime, liveRoots);
    auto runtimeCall = rewriter.create<LLVM::CallOp>(
        loc, closureCallFunc, ValueRange{closureI64, newArgsArray, numNewArgsI32, layoutArg});
    Value resultI64 = runtimeCall.getResult();

    emitRestoreArgsRootRange(rewriter, loc, runtime, savedRange);

    // For the boxed path, origResultType is !eco.value (or unknown +
    // resultType is a pointer): pass the HPointer through.
    if (origResultType && isa<eco::ValueType>(origResultType)) {
        return resultI64;
    }
    if (isHPtrLLVMType(resultType)) {
        return resultI64;
    }
    // Default: pass through.
    return resultI64;
}

/// Implementation of emitUnknownClosureCall.
/// Emits a warning diagnostic and falls back to the legacy inline closure call.
static Value emitUnknownClosureCall(ConversionPatternRewriter &rewriter, Location loc, const EcoRuntime &runtime,
                                    Value closureI64, ValueRange newArgs, Type resultType,
                                    ArrayRef<Type> origNewArgTypes,
                                    Type origResultType,
                                    Operation *safeOp, ValueRange liveRoots) {
    emitWarning(loc) << "closure call with _dispatch_mode='unknown' - "
                     << "closure kind metadata was not propagated; "
                     << "using generic dispatch";
    // Fall back to legacy inline closure call (args-array convention)
    return emitInlineClosureCall(rewriter, loc, runtime, closureI64, newArgs, resultType,
                                 origNewArgTypes, origResultType, safeOp, liveRoots);
}

//===----------------------------------------------------------------------===//
// eco.papExtend -> extend closure or call if saturated
//===----------------------------------------------------------------------===//

struct PapExtendOpLowering : public OpConversionPattern<PapExtendOp> {
    const EcoRuntime &runtime;

    PapExtendOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx, const EcoRuntime &runtime) :
        OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    /// Segmentation-unknown lowering: known ABI types but unknown staging.
    /// Builds a single typed `i64*` args buffer (no LLVM-side boxing) plus an
    /// `EvalParamLayout` describing each slot's primitive kind, then calls
    /// `eco_apply_segmentation_unknown`, which reads the closure header at
    /// runtime to dispatch:
    ///   - Under-saturated: derives bitmap from layout, calls `eco_pap_extend`.
    ///   - Saturated/over: forwards to `eco_apply_closure_typed`, which
    ///     centralises any required primitive re-boxing.
    LogicalResult lowerSegmentationUnknown(PapExtendOp op, OpAdaptor adaptor,
                                           ConversionPatternRewriter &rewriter,
                                           Location loc, Value closureI64,
                                           ValueRange newargs,
                                           ValueRange liveRoots) const {
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i64Ty = IntegerType::get(ctx, 64);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);
        int64_t numNewArgs = newargs.size();

        // Pre-conversion MLIR types drive both ParamKind selection and the
        // GC root mask (HPointer slots are kind 0).
        SmallVector<Type> origNewArgTypes;
        auto origNewargs = op.getNewargs();
        for (size_t i = 0; i < static_cast<size_t>(numNewArgs); ++i) {
            origNewArgTypes.push_back(origNewargs[i].getType());
        }

        // === 1. Alloca + zero-init typed args array — hoisted to entry block ===
        Value typedArgsArray;
        {
            OpBuilder::InsertionGuard allocaGuard(rewriter);
            auto parentFunc = op->getParentOfType<LLVM::LLVMFuncOp>();
            if (parentFunc) rewriter.setInsertionPointToStart(&parentFunc.getBody().front());
            auto numArgsI64 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, numNewArgs);
            typedArgsArray = rewriter.create<LLVM::AllocaOp>(loc, ptrTy, i64Ty, numArgsI64);
        }
        if (numNewArgs > 0) {
            auto i8Ty = IntegerType::get(ctx, 8);
            auto zeroVal = rewriter.create<LLVM::ConstantOp>(loc, i8Ty, 0);
            auto bytesLen = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, numNewArgs * 8);
            rewriter.create<LLVM::MemsetOp>(loc, typedArgsArray, zeroVal, bytesLen, /*isVolatile=*/false);
        }

        // === 2. Compute per-slot kinds + HPointer-only GC mask ===
        SmallVector<uint8_t> kinds;
        kinds.reserve(numNewArgs);
        uint64_t hptrMask = 0;
        for (size_t i = 0; i < origNewArgTypes.size(); ++i) {
            uint8_t k = mlirTypeToParamKind(origNewArgTypes[i]);
            kinds.push_back(k);
            if (k == 0) hptrMask |= (uint64_t{1} << i);
        }

        // === 3. Populate typed args (no boxing, no safepoints) ===
        for (size_t i = 0; i < newargs.size(); ++i) {
            auto idxConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, static_cast<int64_t>(i));
            auto slotPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i64Ty, typedArgsArray, ValueRange{idxConst});
            Value arg = newargs[i];
            if (arg.getType() != i64Ty && isa<LLVM::LLVMPointerType>(arg.getType())) {
                arg = argsSlotStoreValueToI64(rewriter, loc, arg);
            } else if (auto intTy = dyn_cast<IntegerType>(arg.getType())) {
                if (intTy.getWidth() < 64) {
                    arg = rewriter.create<LLVM::ZExtOp>(loc, i64Ty, arg);
                }
            } else if (arg.getType().isF64()) {
                arg = rewriter.create<LLVM::BitcastOp>(loc, i64Ty, arg);
            }
            rewriter.create<LLVM::StoreOp>(loc, arg, slotPtr);
        }

        // === 4. Root typed array (HPointer slots only) ===
        Value typedSavedDepth;
        if (numNewArgs > 0) {
            auto rangePointFunc = runtime.getOrCreateGcStackRangePoint(rewriter);
            typedSavedDepth = rewriter.create<LLVM::CallOp>(loc, rangePointFunc, ValueRange{}).getResult();
            auto pushFunc = runtime.getOrCreateGcPushStackRange(rewriter);
            auto countConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, numNewArgs);
            auto maskConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
                rewriter.getI64IntegerAttr(static_cast<int64_t>(hptrMask)));
            rewriter.create<LLVM::CallOp>(loc, pushFunc,
                ValueRange{typedArgsArray, countConst, maskConst});
        }

        // === 5. Build (or reuse) the EvalParamLayout global ===
        // Phase D: layout's `result_kind` mirrors the closure evaluator's
        // compiled return ABI (sourced from the op's `_result_kind`).
        // The runtime helper reads K from the closure header
        // authoritatively but debug-asserts agreement.
        uint8_t layoutResultKind = static_cast<uint8_t>(op.get_resultKind());
        Value layoutPtr = getOrCreateEvalLayout(rewriter, loc, runtime, kinds,
                                                layoutResultKind);

        // === 6. Call runtime dispatcher via the typed-result eval helper ===
        // `eco_apply_closure_eval` reads the closure header for saturation
        // dispatch (matching what `eco_apply_segmentation_unknown` did)
        // and additionally delivers a typed result per `desired_kind`.
        Type origResultType = op.getResult().getType();
        Type loweredResultType = getTypeConverter()->convertType(origResultType);
        uint8_t desiredKind = mlirTypeToParamKind(loweredResultType);

        auto numNewArgsI32 = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(numNewArgs));
        emitSafepointMarker(op, rewriter, runtime, liveRoots);
        Value result = emitClosureEvalCall(rewriter, loc, runtime, op,
                                           closureI64, typedArgsArray,
                                           numNewArgsI32, layoutPtr,
                                           loweredResultType, desiredKind);

        // === 7. Restore GC root range ===
        if (numNewArgs > 0) {
            emitRestoreArgsRootRange(rewriter, loc, runtime, typedSavedDepth);
        }

        rewriter.replaceOp(op, result);
        return success();
    }

    /// Generic apply lowering: remaining_arity is absent, so saturation is
    /// determined at runtime. We build an args array (boxing unboxed values as
    /// HPointers) and call eco_apply_closure, which handles under/exact/over-
    /// saturated cases by reading the closure header.
    LogicalResult lowerGenericApply(PapExtendOp op, OpAdaptor adaptor,
                                    ConversionPatternRewriter &rewriter,
                                    Location loc, Value closureI64,
                                    ValueRange newargs,
                                    ValueRange liveRoots) const {
        // Phase D: build a typed `i64*` args buffer (no LLVM-side boxing) and
        // pass it to `eco_apply_closure_typed` along with an EvalParamLayout
        // describing each slot's primitive kind. The runtime helper re-boxes
        // primitives into HPointers (centralising what used to be inline
        // LLVM boxing) before forwarding to `eco_apply_closure`. Allocation
        // count is unchanged — the boxing locus has just moved from the
        // JIT'd IR to the runtime, where a future per-evaluator capability
        // bit can elide it for evaluators that accept typed newargs.
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i64Ty = IntegerType::get(ctx, 64);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);
        int64_t numNewArgs = newargs.size();

        // Collect original (pre-conversion) MLIR types for kind decisions.
        SmallVector<Type> origNewArgTypes;
        auto origNewargs = op.getNewargs();
        for (size_t i = 0; i < newargs.size(); ++i)
            origNewArgTypes.push_back(origNewargs[i].getType());

        // Allocate typed args buffer at function entry.
        Value typedArgsArray;
        {
            OpBuilder::InsertionGuard allocaGuard(rewriter);
            auto parentFunc = op->getParentOfType<LLVM::LLVMFuncOp>();
            if (parentFunc) rewriter.setInsertionPointToStart(&parentFunc.getBody().front());
            auto numArgsI64 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, numNewArgs);
            typedArgsArray = rewriter.create<LLVM::AllocaOp>(loc, ptrTy, i64Ty, numArgsI64);
        }

        // Zero-init so the GC scan that follows is safe.
        if (numNewArgs > 0) {
            auto i8Ty = IntegerType::get(ctx, 8);
            auto zeroVal = rewriter.create<LLVM::ConstantOp>(loc, i8Ty, 0);
            auto bytesLen = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, numNewArgs * 8);
            rewriter.create<LLVM::MemsetOp>(loc, typedArgsArray, zeroVal, bytesLen, /*isVolatile=*/false);
        }

        // Compute the per-slot kind sequence for the layout global, and the
        // GC mask (1-bit per slot, set iff slot is HPointer) for rooting.
        SmallVector<uint8_t> kinds;
        kinds.reserve(numNewArgs);
        uint64_t hptrMask = 0;
        for (size_t i = 0; i < origNewArgTypes.size(); ++i) {
            uint8_t k = mlirTypeToParamKind(origNewArgTypes[i]);
            kinds.push_back(k);
            if (k == 0) hptrMask |= (uint64_t{1} << i);
        }

        // Populate slots with typed values directly (no boxing here).
        for (size_t i = 0; i < newargs.size(); ++i) {
            auto idxConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, static_cast<int64_t>(i));
            auto slotPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i64Ty, typedArgsArray, ValueRange{idxConst});
            Value arg = newargs[i];
            if (arg.getType() != i64Ty && isa<LLVM::LLVMPointerType>(arg.getType())) {
                arg = argsSlotStoreValueToI64(rewriter, loc, arg);
            } else if (auto intTy = dyn_cast<IntegerType>(arg.getType())) {
                if (intTy.getWidth() < 64) {
                    arg = rewriter.create<LLVM::ZExtOp>(loc, i64Ty, arg);
                }
            } else if (arg.getType().isF64()) {
                arg = rewriter.create<LLVM::BitcastOp>(loc, i64Ty, arg);
            }
            rewriter.create<LLVM::StoreOp>(loc, arg, slotPtr);
        }

        // Push the buffer as a GC root range covering only the HPointer slots.
        // Primitive slots are zero-initialised and not traced.
        Value savedDepth;
        if (numNewArgs > 0) {
            auto rangePointFunc = runtime.getOrCreateGcStackRangePoint(rewriter);
            savedDepth = rewriter.create<LLVM::CallOp>(loc, rangePointFunc, ValueRange{}).getResult();
            auto pushFunc = runtime.getOrCreateGcPushStackRange(rewriter);
            auto countConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, numNewArgs);
            auto maskConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
                rewriter.getI64IntegerAttr(static_cast<int64_t>(hptrMask)));
            rewriter.create<LLVM::CallOp>(loc, pushFunc,
                ValueRange{typedArgsArray, countConst, maskConst});
        }

        // Build (or reuse) an EvalParamLayout global describing the new args.
        // Phase D: layout's `result_kind` mirrors the closure evaluator's
        // compiled return ABI (sourced from the op's `_result_kind`).
        uint8_t layoutResultKind = static_cast<uint8_t>(op.get_resultKind());
        Value layoutPtr = getOrCreateEvalLayout(rewriter, loc, runtime, kinds,
                                                layoutResultKind);

        // Compute desired_kind from the op's MLIR result type and route
        // through `eco_apply_closure_eval`, which delivers a typed result.
        // For boxed result types the helper allocates an Elm{Int,Float,Char}
        // when the closure evaluator returned a primitive (or passes the
        // HPtr through unchanged when it returned boxed).
        Type origResultType = op.getResult().getType();
        Type loweredResultType = getTypeConverter()->convertType(origResultType);
        uint8_t desiredKind = mlirTypeToParamKind(loweredResultType);

        emitSafepointMarker(op, rewriter, runtime, liveRoots);
        auto numNewArgsConst = rewriter.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(numNewArgs));
        Value result = emitClosureEvalCall(rewriter, loc, runtime, op,
                                           closureI64, typedArgsArray,
                                           numNewArgsConst, layoutPtr,
                                           loweredResultType, desiredKind);

        if (numNewArgs > 0) {
            emitRestoreArgsRootRange(rewriter, loc, runtime, savedDepth);
        }

        rewriter.replaceOp(op, result);
        return success();
    }

    LogicalResult matchAndRewrite(PapExtendOp op, OpAdaptor adaptor,
                                  ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i64Ty = IntegerType::get(ctx, 64);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        // Split adapted operands into real operands + GC roots.
        // Layout: [closure, newargs..., roots...]
        auto [realOperands, liveRoots] = splitAdaptedRoots(op, adaptor.getOperands());
        Value closureI64 = realOperands[0];
        auto newargs = realOperands.drop_front(1);
        int64_t numNewArgs = newargs.size();

        auto remainingArityAttr = op.getRemainingArityAttr();

        // NOTE: safepoint marker is emitted by each sub-path right before
        // the final GC-triggering call, NOT here at the top. This ensures
        // findTargetCall in StatepointConversion latches onto the correct
        // target, not an intermediate boxing or setup call.

        // Generic mode: remaining_arity absent — runtime saturation check.
        // Delegate to eco_apply_closure which handles under/exact/over-saturated.
        if (!remainingArityAttr) {
            // Check _call_kind to distinguish generic_apply from segmentation_unknown
            auto callKindAttr = op->getAttrOfType<StringAttr>("_call_kind");
            if (callKindAttr && callKindAttr.getValue() == "segmentation_unknown") {
                return lowerSegmentationUnknown(op, adaptor, rewriter, loc, closureI64, newargs, liveRoots);
            }
            return lowerGenericApply(op, adaptor, rewriter, loc, closureI64, newargs, liveRoots);
        }

        // Typed mode: remaining_arity present — compile-time saturation check.
        int64_t remainingArity = remainingArityAttr.getInt();
        bool isSaturated = (numNewArgs == remainingArity);

        if (isSaturated) {
            // Saturated call: use typed closure call if attributes present
            Type convertedResultTy = getTypeConverter()->convertType(op.getResult().getType());
            Value result;

            // Extract original types for inline/unknown closure call paths.
            // Only take real newargs, not appended GC roots.
            SmallVector<Type> origNewArgTypes;
            auto origNewargs = op.getNewargs();
            for (size_t i = 0; i < static_cast<size_t>(numNewArgs); ++i) {
                origNewArgTypes.push_back(origNewargs[i].getType());
            }
            Type origResultType = op.getResult().getType();

            // Check for typed closure calling attributes
            auto fastEval = op->getAttrOfType<SymbolRefAttr>("_fast_evaluator");
            auto captureAbi = op->getAttrOfType<ArrayAttr>("_capture_abi");
            auto closureKind = op->getAttr("_closure_kind");

            if (fastEval && captureAbi) {
                // Fast path: known homogeneous closure, call fast clone directly
                result = emitFastClosureCall(rewriter, loc, runtime, closureI64, newargs, fastEval, captureAbi, convertedResultTy,
                                             op, liveRoots);
            } else if (closureKind) {
                // Has closure kind but not fast path -> heterogeneous, use closure call
                result = emitClosureCall(rewriter, loc, runtime, closureI64, newargs, convertedResultTy,
                                         op, liveRoots);
            } else {
                // No typed closure info -> use legacy inline closure call.
                // If _capture_abi is present (without _fast_evaluator), compute a
                // layout for type-aware re-boxing of captured values.
                Value layoutPtr;
                if (captureAbi) {
                    SmallVector<uint8_t> kinds;
                    // Capture kinds from _capture_abi
                    for (auto attr : captureAbi) {
                        auto typeAttr = mlir::dyn_cast<TypeAttr>(attr);
                        kinds.push_back(typeAttr ? mlirTypeToParamKind(typeAttr.getValue()) : 0);
                    }
                    // New args are all PK_Boxed in phase 1
                    for (int64_t i = 0; i < numNewArgs; ++i)
                        kinds.push_back(0); // PK_Boxed
                    layoutPtr = getOrCreateEvalLayout(rewriter, loc, runtime, kinds);
                }
                result = emitInlineClosureCall(rewriter, loc, runtime, closureI64, newargs, convertedResultTy,
                                               origNewArgTypes, origResultType, op, liveRoots, layoutPtr);
            }
            rewriter.replaceOp(op, result);
        } else {
            // Partial application: use runtime helper to create extended closure
            auto helperFunc = runtime.getOrCreatePapExtend(rewriter);

            // Build args array on stack — hoisted to entry block
            Value argsArray;
            {
                OpBuilder::InsertionGuard allocaGuard(rewriter);
                auto parentFunc = op->getParentOfType<LLVM::LLVMFuncOp>();
                if (parentFunc) rewriter.setInsertionPointToStart(&parentFunc.getBody().front());
                auto numArgsConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, rewriter.getI64IntegerAttr(numNewArgs));
                argsArray = rewriter.create<LLVM::AllocaOp>(loc, ptrTy, i64Ty, numArgsConst);
            }

            // Zero-init the array for GC safety (will register range after loop).
            {
                auto i8Ty = IntegerType::get(ctx, 8);
                auto zeroVal = rewriter.create<LLVM::ConstantOp>(loc, i8Ty, 0);
                auto bytesLen = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, numNewArgs * 8);
                rewriter.create<LLVM::MemsetOp>(loc, argsArray, zeroVal, bytesLen, /*isVolatile=*/false);
            }

            // Save range point before population loop.
            auto rangePointFunc = runtime.getOrCreateGcStackRangePoint(rewriter);
            Value savedRange = rewriter.create<LLVM::CallOp>(loc, rangePointFunc, ValueRange{}).getResult();

            // Get bitmap from attribute (source-of-truth) - may be modified below
            uint64_t newargsBitmap = op.getNewargsUnboxedBitmap();

            for (size_t i = 0; i < newargs.size(); ++i) {
                auto idxConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, rewriter.getI64IntegerAttr(i));
                auto slotPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i64Ty, argsArray, ValueRange{idxConst});
                Value arg = newargs[i];
                if (arg.getType() != i64Ty && isa<LLVM::LLVMPointerType>(arg.getType())) {
                    arg = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, arg);
                } else if (auto intTy = dyn_cast<IntegerType>(arg.getType())) {
                    if (intTy.getWidth() < 64) {
                        // Char (i16): zero-extend to i64 and keep unboxed, same as Int/Float.
                        arg = rewriter.create<LLVM::ZExtOp>(loc, i64Ty, arg);
                    }
                }
                rewriter.create<LLVM::StoreOp>(loc, arg, slotPtr);
            }

            // Under 2-bit-per-slot encoding, HPointer slots are those with kind 0.
            uint64_t hptrMask = 0;
            for (unsigned i = 0; i < numNewArgs; ++i) {
                if (((newargsBitmap >> (2 * i)) & 0x3ULL) == 0) {
                    hptrMask |= (1ULL << i);
                }
            }
            {
                auto pushFunc = runtime.getOrCreateGcPushStackRange(rewriter);
                auto countConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, numNewArgs);
                auto maskConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
                    rewriter.getI64IntegerAttr(static_cast<int64_t>(hptrMask)));
                rewriter.create<LLVM::CallOp>(loc, pushFunc,
                    ValueRange{argsArray, countConst, maskConst});
            }

            auto numNewArgsConst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(numNewArgs));
            auto bitmapConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, rewriter.getI64IntegerAttr(newargsBitmap));
            emitSafepointMarker(op, rewriter, runtime, liveRoots);
            auto call = rewriter.create<LLVM::CallOp>(
                loc, helperFunc, ValueRange{closureI64, argsArray, numNewArgsConst, bitmapConst});

            // Restore GC root range stack.
            emitRestoreArgsRootRange(rewriter, loc, runtime, savedRange);

            rewriter.replaceOp(op, call.getResult());
        }

        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.call -> llvm.call or indirect call through closure
//===----------------------------------------------------------------------===//

struct CallOpLowering : public OpConversionPattern<CallOp> {
    const EcoRuntime &runtime;

    CallOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx, const EcoRuntime &runtime) :
        OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult matchAndRewrite(CallOp op, OpAdaptor adaptor, ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();

        // Split adapted operands into real operands + GC roots
        auto [realOperands, liveRoots] = splitAdaptedRoots(op, adaptor.getOperands());

        // Convert result types
        SmallVector<Type> resultTypes;
        for (Type t: op.getResultTypes()) {
            resultTypes.push_back(getTypeConverter()->convertType(t));
        }

        // musttail calls skip safepoint markers
        bool isMusttail = op.getMusttail() && *op.getMusttail();

        auto callee = op.getCallee();
        if (callee) {
            // Direct call to a known function
            if (!isMusttail)
                emitSafepointMarker(op, rewriter, runtime, liveRoots);
            auto callOp = rewriter.create<func::CallOp>(loc, *callee, resultTypes, realOperands);
            rewriter.replaceOp(op, callOp.getResults());
        } else {
            // Indirect call through closure
            if (!op.getRemainingArity()) {
                return op.emitError("indirect calls require remaining_arity attribute");
            }

            int64_t remainingArity = op.getRemainingArity().value();
            Value closureI64 = realOperands[0];
            auto newArgs = realOperands.drop_front(1);

            if (static_cast<int64_t>(newArgs.size()) != remainingArity) {
                return op.emitError("remaining_arity must equal number of new arguments");
            }

            Type convertedResultTy = resultTypes[0];
            Value result;

            // Extract original types for inline/unknown closure call paths.
            // Use only the real (non-root) original operands.
            unsigned origRootCount = op.getGCRoots().size();
            SmallVector<Type> origNewArgTypes;
            auto origOperands = op.getOperands();
            unsigned origRealCount = origOperands.size() - origRootCount;
            for (size_t i = 1; i < origRealCount; ++i) {
                origNewArgTypes.push_back(origOperands[i].getType());
            }
            Type origResultType = op.getResultTypes()[0];

            // Safepoint marker is emitted inside each helper, right before
            // the final GC-triggering call (not here, to avoid latching onto
            // intermediate resolveHPtr/boxing calls).
            ValueRange callRoots = isMusttail ? ValueRange{} : liveRoots;

            // Check for typed closure calling attributes.
            auto dispatchMode = op->getAttrOfType<StringAttr>("_dispatch_mode");
            if (dispatchMode) {
                result = emitDispatchedClosureCall(rewriter, loc, runtime, op, closureI64, newArgs, convertedResultTy,
                                                   origNewArgTypes, origResultType, callRoots);
                if (!result) {
                    return failure();
                }
            } else {
                result = emitInlineClosureCall(rewriter, loc, runtime, closureI64, newArgs, convertedResultTy,
                                               origNewArgTypes, origResultType, op, callRoots);
            }
            rewriter.replaceOp(op, result);
        }

        return success();
    }
};

// Phase-2 pre-materialization helper: create the eval-layout globals a closure
// apply site demands (the exact layout, the resultKind==0 variant several
// dispatch paths use, and the capture-prefixed layout of the saturated-inline
// captureAbi path). Over-approximation is safe: unused private globals are
// dropped by globalDCE.
static void preMaterializeApplyLayouts(OpBuilder &builder,
                                       const EcoRuntime &runtime, Operation *op,
                                       ValueRange origNewargs, uint8_t resultKind,
                                       ArrayAttr captureAbi) {
    Location loc = op->getLoc();
    SmallVector<uint8_t> kinds;
    kinds.reserve(origNewargs.size());
    for (Value v : origNewargs) kinds.push_back(mlirTypeToParamKind(v.getType()));
    ensureEvalLayoutGlobal(builder, loc, runtime, kinds, resultKind);
    if (resultKind != 0)
        ensureEvalLayoutGlobal(builder, loc, runtime, kinds, /*resultKind=*/0);
    if (captureAbi) {
        SmallVector<uint8_t> ck;
        for (Attribute a : captureAbi) {
            auto ta = dyn_cast<TypeAttr>(a);
            ck.push_back(ta ? mlirTypeToParamKind(ta.getValue()) : 0);
        }
        for (size_t i = 0; i < kinds.size(); ++i) ck.push_back(0);
        ensureEvalLayoutGlobal(builder, loc, runtime, ck, /*resultKind=*/0);
    }
}

} // namespace

//===----------------------------------------------------------------------===//
// Pattern Population
//===----------------------------------------------------------------------===//

void eco::detail::populateEcoClosurePatterns(EcoTypeConverter &typeConverter, RewritePatternSet &patterns,
                                             const EcoRuntime &runtime) {

    auto *ctx = patterns.getContext();
    patterns.add<ProjectClosureOpLowering>(typeConverter, ctx, runtime);
    patterns.add<AllocateClosureOpLowering>(typeConverter, ctx, runtime);
    patterns.add<PapCreateOpLowering>(typeConverter, ctx, runtime);
    patterns.add<PapCreateGroupOpLowering>(typeConverter, ctx, runtime);
    patterns.add<PapExtendOpLowering>(typeConverter, ctx, runtime);
    patterns.add<CallOpLowering>(typeConverter, ctx, runtime);
}

// Phase-2 pre-materialization: create every closure wrapper + eval-layout global
// a body pattern demands, by walking the pap/apply ops (whose operands still
// carry their ORIGINAL eco types at this pre-Stage-2 point) and calling the SAME
// creators the patterns call. After this, Stage 2 getOrCreateWrapper/eval-layout
// calls all HIT the cache (read-only symbol table).
void eco::detail::preMaterializeClosureArtifacts(
    OpBuilder &builder, const EcoRuntime &runtime,
    const TypeConverter *typeConverter,
    llvm::ArrayRef<LLVM::LLVMFuncOp> funcs) {
    ModuleOp module = runtime.module;
    for (LLVM::LLVMFuncOp func : funcs) {
        func.walk([&](Operation *op) {
            if (auto pc = dyn_cast<PapCreateOp>(op)) {
                StringRef funcSymbol;
                if (auto fe = pc->getAttrOfType<SymbolRefAttr>("_fast_evaluator"))
                    funcSymbol = fe.getRootReference();
                else
                    funcSymbol = pc.getFunction();
                getOrCreateWrapper(builder, module, funcSymbol, pc.getArity(),
                                   pc.getLoc(), typeConverter, runtime,
                                   /*typedNewargs=*/true,
                                   static_cast<uint8_t>(pc.get_resultKind()));
            } else if (auto pg = dyn_cast<PapCreateGroupOp>(op)) {
                auto fes = pg.getFastEvaluators();
                auto arities = pg.getArities();
                auto rks = pg.get_resultKindsAttr();
                for (unsigned i = 0; i < fes.size(); ++i) {
                    StringRef funcSymbol =
                        cast<FlatSymbolRefAttr>(fes[i]).getValue();
                    int64_t arity = cast<IntegerAttr>(arities[i]).getInt();
                    uint8_t rk = 0;
                    if (rks && i < rks.getValue().size())
                        rk = static_cast<uint8_t>(
                            cast<IntegerAttr>(rks.getValue()[i]).getInt());
                    getOrCreateWrapper(builder, module, funcSymbol, arity,
                                       pg.getLoc(), typeConverter, runtime,
                                       /*typedNewargs=*/true, rk);
                }
            } else if (auto pe = dyn_cast<PapExtendOp>(op)) {
                preMaterializeApplyLayouts(
                    builder, runtime, op, pe.getNewargs(),
                    static_cast<uint8_t>(pe.get_resultKind()),
                    pe->getAttrOfType<ArrayAttr>("_capture_abi"));
            } else if (auto call = dyn_cast<CallOp>(op)) {
                if (call.getCallee()) return;  // direct call: no closure layout
                unsigned rootCount = call.getGCRoots().size();
                auto operands = call.getOperands();
                unsigned realCount = operands.size() - rootCount;
                SmallVector<Value> newargs;
                for (unsigned i = 1; i < realCount; ++i)
                    newargs.push_back(operands[i]);
                uint8_t rk = 0;
                if (auto a = call->getAttrOfType<IntegerAttr>("_result_kind"))
                    rk = static_cast<uint8_t>(a.getInt());
                preMaterializeApplyLayouts(builder, runtime, op,
                                           ValueRange(newargs), rk,
                                           /*captureAbi=*/nullptr);
            }
        });
    }
}
