//===- EcoToLLVMClosures.cpp - Closure operation lowering patterns --------===//
//
// An Elm function value is a heap Closure: an evaluator together with the
// arguments applied to it so far. This file lowers the eco operations that
// build, read, extend and call closures (`eco.allocate_closure`,
// `eco.papCreate`, `eco.papCreateGroup`, `eco.project.closure`,
// `eco.papExtend` and `eco.call` through a closure) to the LLVM dialect, and
// creates the static functions and data that closures point at.
//
// A Closure has a packed word at +8 (`n_values`, `max_values`, `result_kind`
// and the slot kinds of parameters 0 to 19, see `packClosureWord`), an
// `evaluator` at +16, and value slots from +24. The kinds of later parameters
// are in extension kind words, the last words of the object. A slot kind says
// how a slot holds its value: boxed (an HPointer), or a raw Int, Float or Char,
// numbered 0 to 3 in that order. The kinds that `eco.papCreate` and
// `eco.papCreateGroup` record cover all `max_values` parameters, not only the
// ones applied, and are usually taken from the target function's signature
// (see `closureKindsFor` for the args-array exception).
//
// `evaluator` holds the address of an evaluator descriptor (`EvaluatorDesc` in
// Heap.hpp), a constant global `__eco_evaldesc_<generic entry>`, never a code
// address. For `eco.allocate_closure` and `eco.make_closure` the descriptor's
// `generic` entry is the named function itself, which is called with the
// argument array as it is, as it is for an args-array target that is not in
// `origFuncTypes`. Otherwise it is a closure wrapper, an internal
// function `__closure_wrapper_typed_<target>` (suffixed `_ri`, `_rf` or `_rc`
// when the result kind is Int, Float or Char). A wrapper takes a pointer to an
// array of 64-bit argument slots in which a primitive is stored raw and
// anything else as an HPointer (the typed-newargs convention), converts each
// slot to the target's parameter type, and calls the target. It returns an
// HPointer for a boxed result kind and the primitive itself otherwise. The
// descriptor's `sat[N]` entries are saturated-call entries
// (`__closure_sat_<target>_n<N>`): each takes the closure base and the last N
// arguments directly, loads the other arguments from the closure, and calls the
// target. One is made only for an (N, argument kinds, result kind) signature
// that some call site in the module presents (`SatSiteSig`).
//
// A call through a closure takes one of these shapes:
// - A saturated `eco.papExtend` with `_fast_evaluator` and `_capture_abi` loads
//   the captures itself and calls the named function (`emitFastClosureCall`).
// - Any other call stores its new arguments into a stack array, registers the
//   boxed slots as a GC root range, describes the slot kinds with an eval
//   layout global (`EvalParamLayout` in Heap.hpp), and calls the runtime:
//   `eco_apply_closure_eval`, `eco_closure_call_saturated(_eval)` or
//   `eco_pap_extend_l`.
// - Where a site is eligible (`emitSatBegin`), a `__eco_sat_begin` marker is
//   emitted before that array sequence, and on most paths a `__eco_sat_end`
//   after it; the backend may expand a bracketed sequence into a guarded
//   direct call to `sat[N]`, keeping the array sequence as the fallback.
//
// The patterns run on parallel Stage-2 workers, which must not create
// symbols. Every wrapper, saturated-call entry, descriptor and eval layout they
// refer to is made beforehand by `preMaterializeClosureArtifacts`, in the
// serial pre-pass, through the same functions that build the names the
// patterns look up; the patterns assert that the descriptors and layouts
// exist. Much of the file is that symbol-making machinery. (`eco.make_closure`
// itself is lowered in EcoToLLVMValueAgg.cpp.)
//
//===----------------------------------------------------------------------===//

#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "EcoToLLVMInternal.h"

#include "../../allocator/Heap.hpp"

#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/SCF/IR/SCF.h"

#include "llvm/ADT/DenseSet.h"
#include <atomic>
#include <cstdlib>   // ::getenv for the environment switches below
#include <string>

using namespace mlir;
using namespace eco;
using namespace eco::detail;

namespace {

// Forward declarations of helpers defined further down and used by the
// closure-construction patterns. Each is commented at its definition.
static uint8_t mlirTypeToParamKind(Type ty);
static SmallVector<uint8_t> deriveAllParamKinds(const EcoRuntime &runtime,
                                                StringRef funcSymbol,
                                                int64_t arity);
static SmallVector<uint8_t> closureKindsFor(const EcoRuntime &runtime,
                                            StringRef funcSymbol, int64_t arity,
                                            bool isTyped, TypeRange captureTypes);
static void emitClosureExtStores(ConversionPatternRewriter &rewriter, Location loc,
                                 Value closurePtr, Type gepTy, int64_t valueSlots,
                                 ArrayRef<uint64_t> ext);
static Value emitEvalDescAddr(OpBuilder &b, Location loc,
                              const EcoRuntime &runtime,
                              LLVM::LLVMFuncOp wrapper);
static bool satFastEnabled();
static Value emitEvalDescAddrForFunc(OpBuilder &b, Location loc,
                                     const EcoRuntime &runtime,
                                     StringRef funcSymbol);
static void getOrCreateEvalDescForFunc(OpBuilder &builder, ModuleOp module,
                                       const EcoRuntime &runtime,
                                       StringRef funcSymbol, int64_t arity,
                                       uint64_t kindsBitmap, uint8_t resultKind,
                                       Location loc,
                                       llvm::SmallVectorImpl<char> &outName);
static bool wrapperWillBeTypedNewargs(const EcoRuntime &runtime,
                                       StringRef funcSymbol);

//===----------------------------------------------------------------------===//
// GC root range helpers for args-array call sites
//===----------------------------------------------------------------------===//

// Emits code that zeroes the `numSlots` 64-bit slots of `argsArray` and
// registers slot i as a GC root when `boxed[i]` is true, and returns the
// root-range point saved before the registration. Pass that point to
// `emitRestoreArgsRootRange` once the array is no longer needed.
//
// `boxed` must have `numSlots` entries; this is asserted.
static Value emitPushArgsRootRange(
    ConversionPatternRewriter &rewriter, Location loc,
    const EcoRuntime &runtime,
    Value argsArray, int64_t numSlots, ArrayRef<bool> boxed) {
    auto *ctx = rewriter.getContext();
    auto i8Ty = IntegerType::get(ctx, 8);
    auto i64Ty = IntegerType::get(ctx, 64);

    // Zeroed first: a collection may scan the boxed slots before they are
    // filled.
    auto zeroVal = rewriter.create<LLVM::ConstantOp>(loc, i8Ty, 0);
    auto bytesLen = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, numSlots * 8);
    rewriter.create<LLVM::MemsetOp>(loc, argsArray, zeroVal, bytesLen, /*isVolatile=*/false);

    auto rangePointFunc = runtime.getOrCreateGcStackRangePoint(rewriter);
    auto saved = rewriter.create<LLVM::CallOp>(loc, rangePointFunc, ValueRange{});

    assert(static_cast<int64_t>(boxed.size()) == numSlots);
    emitChunkedRootPush(rewriter, loc, runtime, argsArray, boxed);

    return saved.getResult();
}

// Emits a call that restores the GC root-range stack to `savedRangeDepth`, a
// point returned by `eco_gc_stack_range_point`, unregistering every range
// pushed since.
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

/**
 * The lowering of `eco.project.closure`, which reads value slot `index` of a
 * closure.
 *
 * A boxed slot read as `ptr addrspace(1)` is loaded at that type. An unboxed
 * slot is loaded as i64 and bitcast to f64, truncated to a narrower integer,
 * or converted with `inttoptr` to the result type. A boxed slot whose result
 * type is not `ptr addrspace(1)` is returned as the raw i64.
 */
struct ProjectClosureOpLowering : public OpConversionPattern<ProjectClosureOp> {
    const EcoRuntime &runtime; // Must outlive the pattern.

    // Creates the pattern, which keeps a reference to `runtime`.
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

        // A closure is always a heap object, never an embedded constant, so
        // `inlineResolvedBase` needs no constant check in front of it. Its
        // `ptr addrspace(1)` base keeps the slot pointer derived from it
        // visible to the collector.
        Value closurePtr;
        Type slotGepTy;
        if (inlineDerefExtEnabled()) {
            closurePtr = inlineResolvedBase(rewriter, loc, closureI64, runtime);
            slotGepTy = getHPtrLLVMType(*ctx);
        } else {
            auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
            auto resolveCall = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{closureI64});
            closurePtr = resolveCall.getResult();
            slotGepTy = ptrTy;
        }

        int64_t valueOffset = layout::ClosureValuesOffset + index * layout::PtrSize;
        auto offsetConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, rewriter.getI64IntegerAttr(valueOffset));
        auto valuePtr = rewriter.create<LLVM::GEPOp>(loc, slotGepTy, i8Ty, closurePtr, ValueRange{offsetConst});

        Type resultType = getTypeConverter()->convertType(op.getResult().getType());

        // Loaded at `ptr addrspace(1)`, not as i64 plus `inttoptr`: once an
        // inliner folds such an `inttoptr` against a `ptrtoint` in the
        // inlined body, the value is a plain i64 that RS4GC does not track, and
        // it goes stale across a collection.
        if (!isUnboxed && isHPtrLLVMType(resultType)) {
            Value result = rewriter.create<LLVM::LoadOp>(loc, resultType, valuePtr);
            rewriter.replaceOp(op, result);
            return success();
        }

        Value loadedValue = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valuePtr);
        Value result = loadedValue;

        if (isUnboxed) {
            if (resultType == f64Ty) {
                result = rewriter.create<LLVM::BitcastOp>(loc, f64Ty, loadedValue);
            } else if (isa<LLVM::LLVMPointerType>(resultType)) {
                result = rewriter.create<LLVM::IntToPtrOp>(loc, resultType, loadedValue);
            } else if (auto intTy = dyn_cast<IntegerType>(resultType); intTy && intTy.getWidth() < 64) {
                result = rewriter.create<LLVM::TruncOp>(loc, resultType, loadedValue);
            }
        }

        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.allocate_closure -> call eco_alloc_closure
//===----------------------------------------------------------------------===//

/**
 * The lowering of `eco.allocate_closure` to a call to `eco_alloc_closure`
 * with the descriptor of the bare function symbol (not of a wrapper) and the
 * arity. The call may collect.
 */
struct AllocateClosureOpLowering : public OpConversionPattern<AllocateClosureOp> {
    const EcoRuntime &runtime; // Must outlive the pattern.

    // Creates the pattern, which keeps a reference to `runtime`.
    AllocateClosureOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx, const EcoRuntime &runtime) :
        OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult matchAndRewrite(AllocateClosureOp op, OpAdaptor adaptor,
                                  ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        auto funcSymbol = op.getFunction();
        // A descriptor address, not the function's: the runtime reads
        // `evaluator` as an `EvaluatorDesc*`.
        Value funcPtr = emitEvalDescAddrForFunc(rewriter, loc, runtime, funcSymbol);
        auto arityConst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(op.getArity()));

        Value result = emitAllocWithSafepoint(
            op, rewriter, runtime,
            runtime.getOrCreateAllocClosure(rewriter),
            ValueRange{funcPtr, arityConst});
        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Closure wrappers, and eco.papCreate
//===----------------------------------------------------------------------===//

// Returns whether `func` has the shape of a function that already takes an
// argument array: one pointer parameter, returning i64 or a pointer.
//
// The shape alone does not decide it, because a converted eco function can
// have it too. Callers apply it only to functions absent from
// `runtime.origFuncTypes`.
static bool usesArgsArrayConvention(LLVM::LLVMFuncOp func) {
    auto funcType = func.getFunctionType();
    if (funcType.getNumParams() != 1) {
        return false;
    }
    if (!isa<LLVM::LLVMPointerType>(funcType.getParamType(0))) {
        return false;
    }
    auto retType = funcType.getReturnType();
    if (auto intTy = dyn_cast<IntegerType>(retType)) {
        return intTy.getWidth() == 64;
    }
    return isa<LLVM::LLVMPointerType>(retType);
}

// Returns the closure wrapper for the function `funcName` of `arity`
// parameters and result kind `resultKind`, creating it if it does not exist,
// and writes its name to `outName` when that is not null.
//
// The wrapper is an internal function of type `R (ptr)` that reads `arity`
// 64-bit slots from the array its argument points to, converts slot i to the
// type of the target's parameter i, and calls the target. Slot conventions:
// - With `typedNewargs`, an Int, Float or Char slot holds the raw value (Char
//   zero-extended) and any other slot an HPointer.
// - Without it, every slot holds an HPointer, and an Int, Float or Char is
//   read from offset 8 of the boxed object. Nothing in this file asks for
//   this convention.
//
// `resultKind` (0 boxed, 1 Int, 2 Float, 3 Char) sets `R`. For a boxed
// result `R` is `ptr` and a primitive returned by the target is boxed with
// `eco_alloc_int`, `eco_alloc_float` or `eco_alloc_char`. Otherwise `R` is
// i64, f64 or i32, and the target's own return type must already be that
// type (asserted for Int and Float; a Char result is widened or narrowed to
// i32). The name is `__closure_wrapper_typed_<funcName>` (without `_typed_`
// when `typedNewargs` is false), with `_ri`, `_rf` or `_rc` appended for a
// primitive result kind.
//
// The target's parameter types come from `runtime.origFuncTypes`, then from a
// `func.func`, then from an `llvm.func`. When the target appears only in
// `origFuncTypes`, an external declaration of it is created. A function with
// no known signature is fatal if its name starts with `Elm_Kernel_`, and is
// otherwise declared external with `arity` i64 parameters. A function absent
// from `origFuncTypes` that already takes an argument array
// (`usesArgsArrayConvention`) is returned as its own wrapper.
//
// When `runtime.topLog` is set the wrapper is logged to be built later
// (`emitTopLevel`) and a null function is returned, as it is for a wrapper
// already logged but not yet built; `outName` is set in both cases. The
// function only creates operations, so it takes a plain `OpBuilder` and can
// run in the pre-pass as well as from a pattern.
static LLVM::LLVMFuncOp getOrCreateWrapper(OpBuilder &rewriter, ModuleOp module, StringRef funcName,
                                           int64_t arity, Location loc, const TypeConverter *typeConverter,
                                           const EcoRuntime &runtime,
                                           bool typedNewargs = false,
                                           uint8_t resultKind = 0,
                                           std::string *outName = nullptr) {
    auto *ctx = rewriter.getContext();
    auto i64Ty = IntegerType::get(ctx, 64);
    auto f64Ty = Float64Type::get(ctx);
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);
    auto charTy = eco::getEcoCharType(ctx);

    // The result kind is part of the name, so wrappers of one target with
    // different result kinds are distinct symbols.
    llvm::SmallString<64> wrapperName;
    const char *kindSuffix = "";
    switch (resultKind) {
        case 1: kindSuffix = "_ri"; break;  // PK_Int
        case 2: kindSuffix = "_rf"; break;  // PK_Float
        case 3: kindSuffix = "_rc"; break;  // PK_Char
        default: kindSuffix = ""; break;     // PK_Boxed
    }
    if (typedNewargs) {
        ("__closure_wrapper_typed_" + funcName + kindSuffix).toVector(wrapperName);
    } else {
        ("__closure_wrapper_" + funcName + kindSuffix).toVector(wrapperName);
    }

    // In the pre-pass a wrapper may be logged but not built yet; its name is
    // all the pre-pass needs.
    if (runtime.isPending(wrapperName)) {
        if (outName)
            *outName = std::string(wrapperName);
        return {};
    }
    if (auto existingWrapper = runtime.lookupSymbol<LLVM::LLVMFuncOp>(StringRef(wrapperName))) {
        if (outName)
            *outName = std::string(wrapperName);
        return existingWrapper;
    }

    // A target that already takes an argument array is its own wrapper, used
    // as it is whatever `typedNewargs` says; it has no typed signature to
    // build a typed wrapper from, and its slots are boxed
    // (`wrapperWillBeTypedNewargs` tells callers so). Such a target is an
    // `llvm.func` that was never a `func.func`, so it is absent from
    // `origFuncTypes`. Every eco function is an `llvm.func` by now and may
    // have the same shape, so the shape is tested only outside
    // `origFuncTypes`; otherwise its typed wrapper would never be made.
    if (!runtime.origFuncTypes.contains(funcName)) {
        if (auto existingFunc = runtime.lookupSymbol<LLVM::LLVMFuncOp>(funcName)) {
            if (usesArgsArrayConvention(existingFunc)) {
                if (outName)
                    *outName = funcName.str();
                return existingFunc;
            }
        }
    }

    // Both the original eco types and the converted types are kept: only the
    // original types tell a `!eco.value` parameter from an Int one.
    SmallVector<Type> targetParamTypes;
    SmallVector<Type> origParamTypes;   // Empty when unknown.
    Type targetResultType = i64Ty;
    Type origResultType;                // Null when unknown.

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
        // The target may be known only from `origFuncTypes`, with no symbol
        // in the module. The declaration is made now, not logged, because
        // later lookups must find it.
        if (!runtime.lookupSymbol(funcName)) {
            OpBuilder declBuilder(ctx);
            auto externFuncType = LLVM::LLVMFunctionType::get(targetResultType, targetParamTypes, false);
            auto externFunc = declBuilder.create<LLVM::LLVMFuncOp>(loc, funcName, externFuncType);
            externFunc.setLinkage(LLVM::Linkage::External);
            placeTopLevel(runtime, externFunc);
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
        }
        targetResultType = funcType.getReturnType();
    } else {
        // CGEN_057: the compiler declares every kernel function it uses as a
        // `func.func`, so a kernel function with no signature is a compiler
        // bug.
        if (funcName.starts_with("Elm_Kernel_")) {
            llvm::report_fatal_error(
                "getOrCreateWrapper: missing original function types for kernel '" +
                funcName + "'; compiler must emit func.func is_kernel declaration");
        }
        for (int64_t i = 0; i < arity; ++i) {
            targetParamTypes.push_back(i64Ty);
        }
        OpBuilder declBuilder(ctx);
        auto targetFuncType = LLVM::LLVMFunctionType::get(targetResultType, targetParamTypes, false);
        auto externFunc = declBuilder.create<LLVM::LLVMFuncOp>(loc, funcName, targetFuncType);
        externFunc.setLinkage(LLVM::Linkage::External);
        placeTopLevel(runtime, externFunc);
    }

    Type wrapperReturnType;
    switch (resultKind) {
        case 1: wrapperReturnType = i64Ty; break;
        case 2: wrapperReturnType = f64Ty; break;
        case 3: wrapperReturnType = charTy; break;
        default: wrapperReturnType = ptrTy; break;
    }
    auto wrapperType = LLVM::LLVMFunctionType::get(wrapperReturnType, {ptrTy}, false);

    // Everything above runs on the calling thread. The wrapper is built
    // detached, body included, reading only the symbol cache, so that in the
    // pre-pass it can be logged and built later on another thread.
    std::string funcNameStr = funcName.str();
    std::string wrapperNameStr(wrapperName);
    auto buildBody = [=, &runtime](OpBuilder &rewriter,
                                   LLVM::LLVMFuncOp wrapperFunc) mutable {
        StringRef funcName(funcNameStr);

        Block *entryBlock = wrapperFunc.addEntryBlock(rewriter);
        rewriter.setInsertionPointToStart(entryBlock);

        Value argsArray = entryBlock->getArgument(0);
        auto i8Ty = IntegerType::get(ctx, 8);

        // Each slot is converted by its parameter's original eco type where
        // that is known, and by the converted type otherwise. The arms
        // guarded by `typedNewargs` read raw primitives; the later arms read
        // a primitive from a boxed object, or a pointer through the slot
        // barrier.
        auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
        bool hasOrigTypes = !origParamTypes.empty();
        const bool wrapDerefExt = inlineDerefExtEnabled();
        auto hptrTyW = getHPtrLLVMType(*ctx);
        auto resolveScalarBase = [&](Value hptr) -> std::pair<Value, Type> {
            if (wrapDerefExt)
                return {inlineResolvedBase(rewriter, loc, hptr, runtime),
                        static_cast<Type>(hptrTyW)};
            auto rc = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{hptr});
            return {rc.getResult(), static_cast<Type>(ptrTy)};
        };

        SmallVector<Value> callArgs;
        for (int64_t i = 0; i < arity; ++i) {
            auto idxConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, i);
            auto argPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i64Ty, argsArray, ValueRange{idxConst});
            Value argI64 = rewriter.create<LLVM::LoadOp>(loc, i64Ty, argPtr);

            Type targetType = (i < (int64_t)targetParamTypes.size()) ? targetParamTypes[i] : i64Ty;
            Type origType = (hasOrigTypes && i < (int64_t)origParamTypes.size())
                                ? origParamTypes[i] : Type();

            Value convertedArg = argI64;

            if (origType && isa<eco::ValueType>(origType)) {
                // An HPointer in both conventions. Loaded at
                // `ptr addrspace(1)` so RS4GC tracks it even after the target
                // is inlined here (see ProjectClosureOpLowering).
                convertedArg = rewriter.create<LLVM::LoadOp>(loc, getHPtrLLVMType(*ctx), argPtr);
            } else if (typedNewargs && origType && origType.isInteger(64)) {
                convertedArg = argI64;
            } else if (typedNewargs && origType && origType.isF64()) {
                convertedArg = rewriter.create<LLVM::BitcastOp>(loc, f64Ty, argI64);
            } else if (typedNewargs && origType && isa<IntegerType>(origType) &&
                       cast<IntegerType>(origType).getWidth() < 64) {
                convertedArg = rewriter.create<LLVM::TruncOp>(loc, origType, argI64);
            } else if (typedNewargs && !origType) {
                // No eco type: the converted type decides, and the slot is
                // read as raw bits.
                if (auto intTy = dyn_cast<IntegerType>(targetType); intTy && intTy.getWidth() < 64) {
                    convertedArg = rewriter.create<LLVM::TruncOp>(loc, targetType, argI64);
                } else if (targetType == f64Ty) {
                    convertedArg = rewriter.create<LLVM::BitcastOp>(loc, f64Ty, argI64);
                } else if (isa<LLVM::LLVMPointerType>(targetType)) {
                    convertedArg = rewriter.create<LLVM::LoadOp>(loc, targetType, argPtr);
                }
            } else if (origType && origType.isInteger(64)) {
                // The slot holds a boxed Int; its value is at offset 8.
                Value hptr = wrapperLoadArgSlotToValue(rewriter, loc, argI64, getHPtrLLVMType(*ctx));
                auto [rbase, rGepTy] = resolveScalarBase(hptr);
                auto off8 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::HeaderSize);
                auto valPtr = rewriter.create<LLVM::GEPOp>(loc, rGepTy, i8Ty,
                                                            rbase, ValueRange{off8});
                convertedArg = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valPtr);
            } else if (origType && origType.isF64()) {
                Value hptr = wrapperLoadArgSlotToValue(rewriter, loc, argI64, getHPtrLLVMType(*ctx));
                auto [rbase, rGepTy] = resolveScalarBase(hptr);
                auto off8 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::HeaderSize);
                auto valPtr = rewriter.create<LLVM::GEPOp>(loc, rGepTy, i8Ty,
                                                            rbase, ValueRange{off8});
                Value loadedI64 = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valPtr);
                convertedArg = rewriter.create<LLVM::BitcastOp>(loc, f64Ty, loadedI64);
            } else if (auto intTy = dyn_cast<IntegerType>(targetType); intTy && intTy.getWidth() < 64) {
                Value hptr = wrapperLoadArgSlotToValue(rewriter, loc, argI64, getHPtrLLVMType(*ctx));
                auto [rbase, rGepTy] = resolveScalarBase(hptr);
                auto off8 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::HeaderSize);
                auto valPtr = rewriter.create<LLVM::GEPOp>(loc, rGepTy, i8Ty,
                                                            rbase, ValueRange{off8});
                Value fullVal = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valPtr);
                convertedArg = rewriter.create<LLVM::TruncOp>(loc, targetType, fullVal);
            } else if (targetType == f64Ty && !origType) {
                Value hptr = wrapperLoadArgSlotToValue(rewriter, loc, argI64, getHPtrLLVMType(*ctx));
                auto [rbase, rGepTy] = resolveScalarBase(hptr);
                auto off8 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::HeaderSize);
                auto valPtr = rewriter.create<LLVM::GEPOp>(loc, rGepTy, i8Ty,
                                                            rbase, ValueRange{off8});
                Value loadedI64 = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valPtr);
                convertedArg = rewriter.create<LLVM::BitcastOp>(loc, f64Ty, loadedI64);
            } else if (isa<LLVM::LLVMPointerType>(targetType)) {
                convertedArg = wrapperLoadArgSlotToValue(rewriter, loc, argI64, targetType);
            }
            // Any other slot is passed on as the i64 it holds.
            callArgs.push_back(convertedArg);
        }

        auto targetFuncType = LLVM::LLVMFunctionType::get(targetResultType, targetParamTypes, false);
        auto funcSymbolRef = FlatSymbolRefAttr::get(ctx, funcName);
        auto call = rewriter.create<LLVM::CallOp>(loc, targetFuncType, funcSymbolRef, callArgs);

        Value resultValue = call.getResult();
        Value resultPtr;

        if (resultKind != 0) {
            if (resultKind == 1) {
                assert(targetResultType == i64Ty &&
                       "PK_Int wrapper requires i64 target return type");
                resultPtr = resultValue;
            } else if (resultKind == 2) {
                assert(targetResultType == f64Ty &&
                       "PK_Float wrapper requires f64 target return type");
                resultPtr = resultValue;
            } else if (resultKind == 3) {
                if (auto intTy = dyn_cast<IntegerType>(targetResultType)) {
                    if (intTy.getWidth() == eco::kEcoCharBits) {
                        resultPtr = resultValue;
                    } else if (intTy.getWidth() < eco::kEcoCharBits) {
                        resultPtr = rewriter.create<LLVM::ZExtOp>(loc, charTy, resultValue);
                    } else {
                        resultPtr = rewriter.create<LLVM::TruncOp>(loc, charTy, resultValue);
                    }
                } else {
                    assert(false && "PK_Char wrapper requires integer target return type");
                    __builtin_unreachable();
                }
            }
        } else if (origResultType && isa<eco::ValueType>(origResultType)) {
            resultPtr = wrapperReturnValueToPtr0(rewriter, loc, resultValue, ptrTy);
        } else if (origResultType && origResultType.isInteger(64)) {
            auto allocIntFunc = runtime.getOrCreateAllocInt(rewriter);
            auto boxCall = rewriter.create<LLVM::CallOp>(loc, allocIntFunc, ValueRange{resultValue});
            resultPtr = wrapperReturnValueToPtr0(rewriter, loc, boxCall.getResult(), ptrTy);
        } else if (origResultType && origResultType.isF64()) {
            auto allocFloatFunc = runtime.getOrCreateAllocFloat(rewriter);
            auto boxCall = rewriter.create<LLVM::CallOp>(loc, allocFloatFunc, ValueRange{resultValue});
            resultPtr = wrapperReturnValueToPtr0(rewriter, loc, boxCall.getResult(), ptrTy);
        } else if (origResultType && isa<IntegerType>(origResultType) &&
                   cast<IntegerType>(origResultType).getWidth() < 64) {
            auto allocCharFunc = runtime.getOrCreateAllocChar(rewriter);
            auto boxCall = rewriter.create<LLVM::CallOp>(loc, allocCharFunc, ValueRange{resultValue});
            resultPtr = wrapperReturnValueToPtr0(rewriter, loc, boxCall.getResult(), ptrTy);
        } else if (isa<LLVM::LLVMPointerType>(targetResultType)) {
            if (isHPtrLLVMType(targetResultType)) {
                resultPtr = wrapperReturnValueToPtr0(rewriter, loc, resultValue, ptrTy);
            } else {
                resultPtr = resultValue;
            }
        } else if (targetResultType == f64Ty && !origResultType) {
            auto allocFloatFunc = runtime.getOrCreateAllocFloat(rewriter);
            auto boxCall = rewriter.create<LLVM::CallOp>(loc, allocFloatFunc, ValueRange{resultValue});
            resultPtr = wrapperReturnValueToPtr0(rewriter, loc, boxCall.getResult(), ptrTy);
        } else if (auto intTy = dyn_cast<IntegerType>(targetResultType); intTy && !origResultType) {
            if (intTy.getWidth() < 64) {
                auto allocCharFunc = runtime.getOrCreateAllocChar(rewriter);
                auto boxCall = rewriter.create<LLVM::CallOp>(loc, allocCharFunc, ValueRange{resultValue});
                resultPtr = wrapperReturnValueToPtr0(rewriter, loc, boxCall.getResult(), ptrTy);
            } else {
                // An i64 of unknown eco type is taken to be an HPointer.
                resultPtr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, ValueRange{resultValue});
            }
        } else {
            resultPtr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, ValueRange{resultValue});
        }

        rewriter.create<LLVM::ReturnOp>(loc, ValueRange{resultPtr});
    };
    if (outName)
        *outName = wrapperNameStr;
    return emitTopLevel<LLVM::LLVMFuncOp>(
        runtime, wrapperNameStr, /*cache=*/true,
        [=, buildBody = std::move(buildBody)]() mutable -> Operation * {
            OpBuilder b(ctx);
            auto wrapperFunc = b.create<LLVM::LLVMFuncOp>(
                loc, StringRef(wrapperNameStr), wrapperType);
            wrapperFunc.setLinkage(LLVM::Linkage::Internal);
            buildBody(b, wrapperFunc);
            return wrapperFunc;
        });
}

/**
 * The lowering of `eco.papCreate`, which makes a closure over `function` with
 * stage arity `arity` and `num_captured` arguments applied.
 *
 * The evaluator is the descriptor of `function`'s closure wrapper (see
 * `getOrCreateWrapper`) with the op's `_result_kind`, and the closure's kinds
 * cover all `arity` parameters (`closureKindsFor`). A closure with no captures, no
 * `self_capture_indices` and an arity of at most 20 is interned by
 * `eco_intern_closure0`, which keeps one object per descriptor and returns it
 * each time. Any other closure is allocated, inline when that is enabled and
 * the object is at most 4096 bytes, otherwise by `eco_alloc_closure_k`. Its packed word, captures, extension kind words and
 * any self-references (`self_capture_indices`, slots that hold the closure
 * itself) are then stored straight through the new pointer.
 */
struct PapCreateOpLowering : public OpConversionPattern<PapCreateOp> {
    const EcoRuntime &runtime; // Must outlive the pattern.

    // Creates the pattern, which keeps a reference to `runtime`.
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

        int64_t arity = op.getArity();
        int64_t numCaptured = op.getNumCaptured();
        auto captured = adaptor.getOperands();  // All operands are captures

        auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);

        // `function` takes the captures and then the remaining parameters as
        // direct arguments. Anything that calls the wrapper through an
        // argument array must store the arguments in the typed convention
        // (REP_ABI_001).
        auto module = op->getParentOfType<ModuleOp>();
        StringRef funcSymbol = op.getFunction();
        // One `_result_kind` sets both the wrapper's return type and the
        // closure's `result_kind`, which callers read to know how to call
        // the evaluator; the two must agree.
        uint8_t closureResultKind = static_cast<uint8_t>(op.get_resultKind());
        auto wrapperFunc = getOrCreateWrapper(rewriter, module, funcSymbol, arity, loc,
                                              getTypeConverter(), runtime,
                                              /*typedNewargs=*/true,
                                              closureResultKind);
        // There is one descriptor per wrapper, so the descriptor address
        // identifies the wrapper as well as the wrapper address would.
        Value funcPtr = emitEvalDescAddr(rewriter, loc, runtime, wrapperFunc);

        // HEAP_033: a closure with nothing captured is never written after
        // construction (`eco_pap_extend_l` copies), so one shared object per
        // wrapper can stand for all of them. Its packed word depends only on
        // the wrapper, so every site interning the same wrapper passes the
        // same word.
        bool isTyped = wrapperWillBeTypedNewargs(runtime, funcSymbol);
        auto realCapturedOrig =
            op.getCaptured().take_front(static_cast<size_t>(numCaptured));
        SmallVector<uint8_t> allKinds = closureKindsFor(
            runtime, funcSymbol, arity, isTyped, realCapturedOrig.getTypes());
        PackedKinds pk = packKinds(allKinds, layout::ClosureHdrSlots);
        // Interned only when every kind fits in the packed word (arity <= 20),
        // as the interning call takes no extension kind words.
        if (numCaptured == 0 && !op->hasAttr("self_capture_indices") &&
            arity <= static_cast<int64_t>(layout::ClosureHdrSlots)) {
            uint64_t packed0 = packClosureWord(
                0, static_cast<uint32_t>(arity), closureResultKind, pk.hdrBits);
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

        // `arity` value slots, then K extension kind words; the header's size
        // field counts both.
        const int64_t numExt = static_cast<int64_t>(pk.ext.size());
        assert(numExt == layout::extWordsFor(static_cast<unsigned>(arity),
                                             layout::ClosureHdrSlots));
        Value closureHPtr;
        uint64_t cloByteSize = layout::ClosureBaseSize +
            static_cast<uint64_t>(arity + numExt) * layout::PtrSize;
        if (inlineAllocEnabled() && cloByteSize <= 4096) {
            // HEAP_034. Only the header and the evaluator are written here;
            // the packed word is stored below on both paths, and on the call
            // path it replaces the one `eco_alloc_closure_k` wrote. The
            // closure statistics kept inside `eco_alloc_closure_k` do not
            // count this allocation.
            uint64_t header = value_enc::composeHeader(
                value_enc::TagClosure, 0, static_cast<uint64_t>(arity + numExt));
            closureHPtr = emitInlineAllocWithHeader(
                rewriter, loc, runtime, cloByteSize, header);
            // The evaluator is the address of static data, not a heap
            // pointer, so it is stored plainly, with no slot barrier.
            auto evOff = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
                static_cast<int64_t>(layout::ClosureEvaluatorOffset));
            auto evSlot = rewriter.create<LLVM::GEPOp>(
                loc, getHPtrLLVMType(*ctx), i8Ty, closureHPtr,
                ValueRange{evOff});
            rewriter.create<LLVM::StoreOp>(loc, funcPtr, evSlot,
                                           /*alignment=*/8);
        } else {
            auto allocFuncK = runtime.getOrCreateAllocClosureK(rewriter);
            auto arityConst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(arity));
            auto resultKindConst = rewriter.create<LLVM::ConstantOp>(loc, i8Ty,
                rewriter.getI8IntegerAttr(static_cast<int8_t>(closureResultKind)));
            auto allocCall = rewriter.create<LLVM::CallOp>(loc, allocFuncK,
                ValueRange{funcPtr, arityConst, resultKindConst});
            closureHPtr = allocCall.getResult();
        }

        // No safepoint lies between the allocation and the stores below,
        // which are plain stores and gc-leaf barrier calls, so the object
        // cannot have moved and is stored to through the allocation result
        // without a resolve (HEAP_031).
        Value closurePtr;
        Type papGepTy;
        if (inlineDerefExtEnabled()) {
            closurePtr = closureHPtr;
            papGepTy = getHPtrLLVMType(*ctx);
        } else {
            auto resolveCall = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{closureHPtr});
            closurePtr = resolveCall.getResult();
            papGepTy = ptrTy;
        }

        auto f64Ty = Float64Type::get(ctx);

        // The whole packed word (HEAP_078) is one constant, written in one
        // store.
        uint64_t packedValue = packClosureWord(
            static_cast<uint32_t>(numCaptured), static_cast<uint32_t>(arity),
            closureResultKind, pk.hdrBits);

        auto packedConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, rewriter.getI64IntegerAttr(packedValue));

        auto offset8 =
            rewriter.create<LLVM::ConstantOp>(loc, i64Ty, rewriter.getI64IntegerAttr(layout::ClosurePackedOffset));
        auto packedPtr = rewriter.create<LLVM::GEPOp>(loc, papGepTy, i8Ty, closurePtr, ValueRange{offset8});
        rewriter.create<LLVM::StoreOp>(loc, packedConst, packedPtr);

        // A Char is zero-extended, a Float stored as its bits, an Int as it
        // is, and a pointer through `closureStoreValueToI64`. The slot kinds
        // in the packed word tell the collector which slots are raw.
        for (size_t i = 0; i < captured.size(); ++i) {
            int64_t valueOffset = layout::ClosureValuesOffset + i * layout::PtrSize;
            auto offsetConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, rewriter.getI64IntegerAttr(valueOffset));
            auto valuePtr = rewriter.create<LLVM::GEPOp>(loc, papGepTy, i8Ty, closurePtr, ValueRange{offsetConst});

            Value capturedValue = captured[i];
            if (auto intTy = dyn_cast<IntegerType>(capturedValue.getType());
                intTy && intTy.getWidth() < 64) {
                capturedValue = rewriter.create<LLVM::ZExtOp>(loc, i64Ty, capturedValue);
            } else if (capturedValue.getType() == f64Ty) {
                capturedValue = rewriter.create<LLVM::BitcastOp>(loc, i64Ty, capturedValue);
            } else if (isa<LLVM::LLVMPointerType>(capturedValue.getType())) {
                capturedValue = closureStoreValueToI64(rewriter, loc, capturedValue);
            }
            rewriter.create<LLVM::StoreOp>(loc, capturedValue, valuePtr);
        }

        emitClosureExtStores(rewriter, loc, closurePtr, papGepTy, arity, pk.ext);

        // A recursive closure refers to itself: each slot listed in
        // `self_capture_indices` gets the closure's own pointer.
        if (auto selfCaptureAttr = op->getAttrOfType<DenseI64ArrayAttr>("self_capture_indices")) {
            Value closureI64 = closureStoreValueToI64(rewriter, loc, closureHPtr);
            for (int64_t selfIdx : selfCaptureAttr.asArrayRef()) {
                int64_t valueOffset = layout::ClosureValuesOffset + selfIdx * layout::PtrSize;
                auto offsetConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
                    rewriter.getI64IntegerAttr(valueOffset));
                auto valuePtr = rewriter.create<LLVM::GEPOp>(loc, papGepTy, i8Ty, closurePtr,
                    ValueRange{offsetConst});
                rewriter.create<LLVM::StoreOp>(loc, closureI64, valuePtr);
            }
        }

        rewriter.replaceOp(op, closureHPtr);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.papCreateGroup -> one eco_alloc_closure_group_l call
//===----------------------------------------------------------------------===//

/**
 * The lowering of `eco.papCreateGroup`, which makes several closures at once,
 * to one call to `eco_alloc_closure_group_l`.
 *
 * Each sibling's evaluator is the descriptor of the typed-newargs wrapper of
 * its `fast_evaluators` entry, and its kinds come from that function's
 * signature (`deriveAllParamKinds`), padded with boxed to its arity. The
 * per-sibling data, the captures in one flat array, and `cross_edges` (flat
 * i64 triples, passed on as they are) go to the runtime in stack arrays. The
 * runtime writes every closure, including the kinds, and returns the closures
 * in a stack array that becomes the op's results.
 */
struct PapCreateGroupOpLowering : public OpConversionPattern<PapCreateGroupOp> {
    const EcoRuntime &runtime; // Must outlive the pattern.

    // Creates the pattern, which keeps a reference to `runtime`.
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
        auto captureCounts = op.getCaptureCounts();
        auto crossEdges = op.getCrossEdges();

        const unsigned numSiblings = functions.size();

        // The operands are the captures of every sibling, in sibling order.
        auto captureOperands = adaptor.getOperands();

        auto module = op->getParentOfType<ModuleOp>();
        SmallVector<Value> wrapperPtrs;
        wrapperPtrs.reserve(numSiblings);
        // `_result_kinds` is optional; a missing attribute or entry means
        // boxed. One entry sets both the sibling's wrapper return type and
        // its closure's `result_kind`.
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
            Value funcPtr = emitEvalDescAddr(rewriter, loc, runtime, wrapperFunc);
            wrapperPtrs.push_back(funcPtr);
        }

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
        Value hdrKindsArr = rewriter.create<LLVM::AllocaOp>(
            loc, ptrTy, i64Ty, numSiblingsConst);
        Value extOffsetsArr = rewriter.create<LLVM::AllocaOp>(
            loc, ptrTy, i32Ty, numSiblingsPlus1Const);
        Value resultKindsArr = rewriter.create<LLVM::AllocaOp>(
            loc, ptrTy, i8Ty, numSiblingsConst);
        Value captureOffsetsArr = rewriter.create<LLVM::AllocaOp>(
            loc, ptrTy, i32Ty, numSiblingsPlus1Const);
        Value outClosuresArr = rewriter.create<LLVM::AllocaOp>(
            loc, ptrTy, i64Ty, numSiblingsConst);

        // The op's own `slot_kinds`, which covers only the captures, is not
        // read here. Each sibling's extension words go into one flat array;
        // `extOffsets[i]` is where sibling i's begin, and `extOffsets[N]` the
        // total.
        SmallVector<PackedKinds> siblingKinds;
        SmallVector<uint64_t> allExt;
        SmallVector<uint32_t> extOffsets;
        for (unsigned i = 0; i < numSiblings; ++i) {
            StringRef funcSymbol =
                cast<FlatSymbolRefAttr>(fastEvaluators[i]).getValue();
            int64_t arity = cast<IntegerAttr>(arities[i]).getInt();
            SmallVector<uint8_t> kinds = deriveAllParamKinds(runtime, funcSymbol, arity);
            kinds.resize(static_cast<size_t>(arity), 0);
            siblingKinds.push_back(packKinds(kinds, layout::ClosureHdrSlots));
            extOffsets.push_back(static_cast<uint32_t>(allExt.size()));
            allExt.append(siblingKinds.back().ext.begin(), siblingKinds.back().ext.end());
        }
        extOffsets.push_back(static_cast<uint32_t>(allExt.size()));
        auto extCountConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
            rewriter.getI64IntegerAttr(allExt.empty() ? 1 : allExt.size()));
        Value extKindsArr = rewriter.create<LLVM::AllocaOp>(
            loc, ptrTy, i64Ty, extCountConst);
        for (size_t j = 0; j < allExt.size(); ++j) {
            auto idxConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
                rewriter.getI64IntegerAttr(static_cast<int64_t>(j)));
            auto wConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
                rewriter.getI64IntegerAttr(static_cast<int64_t>(allExt[j])));
            auto wPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i64Ty,
                extKindsArr, ValueRange{idxConst});
            rewriter.create<LLVM::StoreOp>(loc, wConst, wPtr);
        }
        for (unsigned i = 0; i <= numSiblings; ++i) {
            auto idxConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
                rewriter.getI64IntegerAttr(i));
            auto oConst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
                rewriter.getI32IntegerAttr(static_cast<int32_t>(extOffsets[i])));
            auto oPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i32Ty,
                extOffsetsArr, ValueRange{idxConst});
            rewriter.create<LLVM::StoreOp>(loc, oConst, oPtr);
        }

        // `captureOffsets[i]` is where sibling i's captures begin in the flat
        // captures array, and `captureOffsets[N]` the total.
        uint32_t runningOffset = 0;
        for (unsigned i = 0; i < numSiblings; ++i) {
            uint32_t arity = static_cast<uint32_t>(
                cast<IntegerAttr>(arities[i]).getInt());
            uint32_t nc = static_cast<uint32_t>(
                cast<IntegerAttr>(numCapturedArr[i]).getInt());
            uint64_t hdrBits = siblingKinds[i].hdrBits;
            uint32_t cc = static_cast<uint32_t>(
                cast<IntegerAttr>(captureCounts[i]).getInt());

            auto idxConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
                rewriter.getI64IntegerAttr(i));

            auto evPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, ptrTy,
                evaluatorsArr, ValueRange{idxConst});
            rewriter.create<LLVM::StoreOp>(loc, wrapperPtrs[i], evPtr);

            auto arConst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
                rewriter.getI32IntegerAttr(static_cast<int32_t>(arity)));
            auto arPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i32Ty,
                aritiesArr, ValueRange{idxConst});
            rewriter.create<LLVM::StoreOp>(loc, arConst, arPtr);

            auto ncConst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
                rewriter.getI32IntegerAttr(static_cast<int32_t>(nc)));
            auto ncPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i32Ty,
                numCapturedArrAlloca, ValueRange{idxConst});
            rewriter.create<LLVM::StoreOp>(loc, ncConst, ncPtr);

            // The kinds of parameters 0 to 19, unshifted.
            auto bmConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
                rewriter.getI64IntegerAttr(static_cast<int64_t>(hdrBits)));
            auto bmPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i64Ty,
                hdrKindsArr, ValueRange{idxConst});
            rewriter.create<LLVM::StoreOp>(loc, bmConst, bmPtr);

            // Read from the same `_result_kinds` entry as the wrapper above.
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

            auto offConst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
                rewriter.getI32IntegerAttr(static_cast<int32_t>(runningOffset)));
            auto offPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i32Ty,
                captureOffsetsArr, ValueRange{idxConst});
            rewriter.create<LLVM::StoreOp>(loc, offConst, offPtr);
            runningOffset += cc;
        }
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

        // The boxed captures in the flat array are registered as GC roots.
        // `eco_alloc_closure_group_l` may collect, and RS4GC does not track a
        // pointer once it is stored as an i64, so without the registration a
        // moved capture would be copied into the new closures at its old
        // address. Slot k is boxed when its capture operand's slot kind is 0.
        SmallVector<bool> boxedCaptures(totalCaptures, false);
        for (uint32_t k = 0; k < totalCaptures; ++k)
            boxedCaptures[k] = slotKindOf(op->getOperand(k).getType()) == 0;

        // Zeroed and registered before any capture is stored into it.
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
            emitChunkedRootPush(rewriter, loc, runtime, capturesArr, boxedCaptures);
        }

        for (uint32_t k = 0; k < totalCaptures; ++k) {
            Value capValue = captureOperands[k];
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

        auto groupFunc = runtime.getOrCreateAllocClosureGroupL(rewriter);
        rewriter.create<LLVM::CallOp>(loc, groupFunc, ValueRange{
            numSiblingsConst,
            evaluatorsArr,
            aritiesArr,
            numCapturedArrAlloca,
            hdrKindsArr,
            extKindsArr,
            extOffsetsArr,
            resultKindsArr,
            captureOffsetsArr,
            capturesArr,
            crossEdgesArr,
            numCrossConst,
            outClosuresArr
        });

        if (needRootRange) {
            auto restoreFunc = runtime.getOrCreateGcRestoreStackRangePoint(rewriter);
            rewriter.create<LLVM::CallOp>(loc, restoreFunc,
                ValueRange{savedRangeDepth});
        }

        SmallVector<Value> results;
        results.reserve(numSiblings);
        for (unsigned i = 0; i < numSiblings; ++i) {
            auto idxConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
                rewriter.getI64IntegerAttr(i));
            auto slotPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i64Ty,
                outClosuresArr, ValueRange{idxConst});
            Value loadedI64 = rewriter.create<LLVM::LoadOp>(loc, i64Ty, slotPtr);
            // REP_LLVM_002: decoded through the slot barrier, not a bare
            // `inttoptr`.
            Value asHPtr = argsSlotLoadI64ToValue(rewriter, loc, loadedI64);
            results.push_back(asHPtr);
        }

        rewriter.replaceOp(op, results);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Direct call when the captures' types are known
//===----------------------------------------------------------------------===//

// Emits a call of `fastEvaluator` with the closure's captures followed by
// `newArgs`, and returns its result, of type `resultType`.
//
// Capture i is loaded from value slot i at the type `captureAbiTypes[i]`
// gives (i64 when the entry is not a type): a pointer type is loaded as that
// pointer, f64 as its bits, anything else as i64. The call is indirect,
// through the function's address, with a type built from these arguments,
// because that type may differ from the callee's converted signature, which
// a direct call would have to match. The backend's `runCapInlinePrepass` may
// inline a call whose type matches the callee's; any other stays indirect.
//
// When `ECO_LSS_DISPATCH_SITE_COUNTERS` is set (read once per process), a
// call to `eco_dispatch_stats_fast` with the closure's evaluator is emitted
// first.
static Value emitFastClosureCall(ConversionPatternRewriter &rewriter, Location loc, const EcoRuntime &runtime,
                                 Value closureI64, ValueRange newArgs, SymbolRefAttr fastEvaluator,
                                 ArrayAttr captureAbiTypes, Type resultType) {
    auto *ctx = rewriter.getContext();
    auto i8Ty = IntegerType::get(ctx, 8);
    auto i64Ty = IntegerType::get(ctx, 64);
    auto f64Ty = Float64Type::get(ctx);
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);

    // A closure is never an embedded constant (see ProjectClosureOpLowering).
    Value closurePtr;
    Type fcGepTy;
    if (inlineDerefExtEnabled()) {
        closurePtr = inlineResolvedBase(rewriter, loc, closureI64, runtime);
        fcGepTy = getHPtrLLVMType(*ctx);
    } else {
        auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
        auto resolveCall = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{closureI64});
        closurePtr = resolveCall.getResult();
        fcGepTy = ptrTy;
    }

    // Keyed on the closure's own evaluator, read at run time.
    static const bool lssDispatchSiteCounters =
        (::getenv("ECO_LSS_DISPATCH_SITE_COUNTERS") != nullptr);
    if (lssDispatchSiteCounters) {
        auto evalOffset = rewriter.create<LLVM::ConstantOp>(
            loc, i64Ty, rewriter.getI64IntegerAttr(layout::ClosureEvaluatorOffset));
        auto evalPtrPtr = rewriter.create<LLVM::GEPOp>(
            loc, fcGepTy, i8Ty, closurePtr, ValueRange{evalOffset});
        Value evaluatorFp = rewriter.create<LLVM::LoadOp>(loc, ptrTy, evalPtrPtr);
        auto statsFunc = runtime.getOrCreateDispatchStatsFast(rewriter);
        rewriter.create<LLVM::CallOp>(loc, statsFunc, ValueRange{evaluatorFp});
    }

    SmallVector<Value> callArgs;
    SmallVector<Type> paramTypes;

    for (size_t i = 0; i < captureAbiTypes.size(); ++i) {
        int64_t valueOffset = layout::ClosureValuesOffset + i * layout::PtrSize;
        auto offsetConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, rewriter.getI64IntegerAttr(valueOffset));
        auto valuePtr = rewriter.create<LLVM::GEPOp>(loc, fcGepTy, i8Ty, closurePtr, ValueRange{offsetConst});

        auto typeAttr = mlir::dyn_cast<TypeAttr>(captureAbiTypes[i]);
        Type captureType = typeAttr ? typeAttr.getValue() : i64Ty;

        // Pointers are loaded at their pointer type so RS4GC tracks them
        // (see ProjectClosureOpLowering).
        Value captureVal;
        if (isa<LLVM::LLVMPointerType>(captureType)) {
            captureVal = rewriter.create<LLVM::LoadOp>(loc, captureType, valuePtr);
            paramTypes.push_back(captureType);
        } else if (captureType.isF64()) {
            Value loadedValue = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valuePtr);
            captureVal = rewriter.create<LLVM::BitcastOp>(loc, f64Ty, loadedValue);
            paramTypes.push_back(f64Ty);
        } else {
            captureVal = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valuePtr);
            paramTypes.push_back(i64Ty);
        }
        callArgs.push_back(captureVal);
    }

    for (Value arg : newArgs) {
        callArgs.push_back(arg);
        paramTypes.push_back(arg.getType());
    }

    auto flatSymbol = FlatSymbolRefAttr::get(ctx, fastEvaluator.getRootReference());
    Value funcPtr = rewriter.create<LLVM::AddressOfOp>(loc, ptrTy, flatSymbol);

    Type llvmResultType = resultType;
    auto funcType = LLVM::LLVMFunctionType::get(llvmResultType, paramTypes, /*isVarArg=*/false);
    SmallVector<Value> callOperands;
    callOperands.push_back(funcPtr);
    callOperands.append(callArgs.begin(), callArgs.end());
    auto callOp = rewriter.create<LLVM::CallOp>(loc, funcType, callOperands);

    return callOp.getResult();
}

//===----------------------------------------------------------------------===//
// Slot kinds
//===----------------------------------------------------------------------===//

// Returns the slot kind (ParamKind) of a value of type `ty`: 1 (Int) for i64,
// 2 (Float) for f64, 3 (Char) for i32, and 0 (boxed) for anything else,
// including other integer widths.
static uint8_t mlirTypeToParamKind(Type ty) {
    if (ty.isInteger(64)) return 1;  // PK_Int
    if (ty.isF64()) return 2;        // PK_Float
    if (eco::isEcoCharType(ty)) return 3;  // PK_Char
    return 0;                        // PK_Boxed
}

// Returns the slot kind of each of the first `arity` parameters of
// `funcSymbol` (fewer when the function has fewer parameters), by
// `mlirTypeToParamKind`.
//
// The signature is looked up in the same order as `getOrCreateWrapper` does
// (`origFuncTypes`, `func.func`, `llvm.func`), so that the kinds a closure
// records agree with how its wrapper reads the slots. A function with no
// signature is a fatal error, rather than a silent all-boxed answer that the
// wrapper would contradict.
static SmallVector<uint8_t> deriveAllParamKinds(const EcoRuntime &runtime,
                                                StringRef funcSymbol,
                                                int64_t arity) {
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
        // Converted types give the same kinds: a pointer is boxed.
        for (unsigned i = 0; i < fnType.getNumParams(); ++i)
            paramTypes.push_back(fnType.getParamType(i));
    } else {
        llvm::report_fatal_error(
            "deriveAllParamKinds: no signature available for '" +
            funcSymbol +
            "'; closure bitmap would silently default to PK_Boxed and "
            "diverge from the wrapper's typed-newargs decoding");
    }

    SmallVector<uint8_t> kinds;
    int64_t lim = arity;
    if (lim > (int64_t)paramTypes.size()) lim = (int64_t)paramTypes.size();
    for (int64_t i = 0; i < lim; ++i)
        kinds.push_back(mlirTypeToParamKind(paramTypes[i]) & 0x3);
    return kinds;
}

// Returns the `arity` slot kinds a closure over `funcSymbol` records (HEAP_078,
// CGEN_049). When `isTyped` (the wrapper reads typed slots), they are the
// target's parameter kinds; otherwise they are the kinds of `captureTypes` by
// `slotKindOf`. Either list is padded with boxed to `arity`.
static SmallVector<uint8_t> closureKindsFor(const EcoRuntime &runtime,
                                            StringRef funcSymbol, int64_t arity,
                                            bool isTyped, TypeRange captureTypes) {
    SmallVector<uint8_t> kinds;
    if (isTyped) {
        kinds = deriveAllParamKinds(runtime, funcSymbol, arity);
    } else {
        for (Type t : captureTypes) kinds.push_back(slotKindOf(t));
    }
    kinds.resize(static_cast<size_t>(arity), 0);
    return kinds;
}

// Emits stores of the extension kind words `ext`, zero words included
// (HEAP_077), into the closure at `closurePtr`, starting at value slot
// `valueSlots`, so that they are its last words. `gepTy` is the type of the
// slot addresses computed from `closurePtr`.
static void emitClosureExtStores(ConversionPatternRewriter &rewriter, Location loc,
                                 Value closurePtr, Type gepTy, int64_t valueSlots,
                                 ArrayRef<uint64_t> ext) {
    auto *ctx = rewriter.getContext();
    auto i8Ty = IntegerType::get(ctx, 8);
    auto i64Ty = IntegerType::get(ctx, 64);
    for (size_t j = 0; j < ext.size(); ++j) {
        int64_t off = layout::ClosureValuesOffset +
                      (valueSlots + static_cast<int64_t>(j)) * layout::PtrSize;
        auto offC = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, rewriter.getI64IntegerAttr(off));
        auto ptr = rewriter.create<LLVM::GEPOp>(loc, gepTy, i8Ty, closurePtr, ValueRange{offC});
        auto w = rewriter.create<LLVM::ConstantOp>(
            loc, i64Ty, rewriter.getI64IntegerAttr(static_cast<int64_t>(ext[j])));
        rewriter.create<LLVM::StoreOp>(loc, w, ptr);
    }
}

//===----------------------------------------------------------------------===//
// Evaluator descriptors and saturated-call entries
//===----------------------------------------------------------------------===//

/**
 * The signature a call site presents to a saturated-call entry: the number
 * of new arguments `n`, their slot kinds `kc` (2 bits each, argument 0 in the
 * lowest bits), and the result kind `rc`.
 *
 * The backend guards a call of `sat[n]` on a closure with stage arity P by
 * checking, in the closure's packed word, that P minus `n_values` is `n`,
 * that P is at most `SAT_MAX_ARITY`, that the result kind is `rc` and that
 * the kinds of the last `n` parameters are `kc`, and then that the entry is
 * not null. So `sat[n]` of a target can only be reached from a site whose
 * `kc` equals the target's kinds for its last `n` parameters and whose `rc`
 * equals its result kind, and an entry is needed only for such a signature.
 * If the set of recorded signatures and the sites disagree, a missing entry is
 * null and its guard fails, so the site takes the array path; a spare entry is
 * unused.
 */
struct SatSiteSig {
    unsigned n;
    uint64_t kc;
    uint8_t rc;
    // Returns whether all three fields are equal.
    bool operator==(const SatSiteSig &o) const {
        return n == o.n && kc == o.kc && rc == o.rc;
    }
};
// Every distinct signature the module's closure call sites present, without
// duplicates. Filled by `preMaterializeClosureArtifacts`, which clears it
// first, and only read afterwards, including by parallel Stage-2 workers.
static llvm::SmallVector<SatSiteSig, 16> g_satSigs;
// For each target named by an `eco.papCreate` or `eco.papCreateGroup` (by its
// `fast_evaluators` entry), the smallest number of captures any of them
// gives it. A closure's `n_values` starts there and `eco.papExtend` only
// adds to it, so no call can reach `sat[N]` for an N above the stage arity
// minus this. Filled and read only by the pre-pass.
static llvm::StringMap<unsigned> g_minCaptured;

// Returns whether `g_satSigs` holds the signature (`n`, `kc`, `rc`). The
// search is linear.
static bool satSigPresent(unsigned n, uint64_t kc, uint8_t rc) {
    for (const SatSiteSig &s : g_satSigs)
        if (s.n == n && s.kc == kc && s.rc == rc)
            return true;
    return false;
}

// Counts of the (descriptor, N) pairs `getOrCreateEvalDesc` considered for a
// saturated-call entry: all of them, those it made, and those it rejected,
// because N is above the reachable bound, because no site has the
// signature, or because the target's shape is unsupported. Updated with
// relaxed atomics, and printed only by `ecoDumpPapHistogram`.
namespace satFilter {
static std::atomic<uint64_t> considered{0}, byArity{0}, bySignature{0},
    byShape{0}, generated{0};
}

// Returns whether saturated-call entries and their call-site markers are
// made. True unless `ECO_SAT_FAST` is exactly `0`; read once and kept for
// the life of the process.
static bool satFastEnabled() {
    static const bool on = [] {
        const char *e = ::getenv("ECO_SAT_FAST");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return on;
}

// Counters of what this file emitted, kept when `ECO_PAP_HISTO` is set and
// printed by `ecoDumpPapHistogram`. They change nothing that is emitted.
// Only `descN`, `satEntriesN` and `satDiamondN` are incremented anywhere;
// the other counters and the per-arity rows stay zero.
namespace papHisto {
static std::atomic<uint64_t> fastN{0}, inlineN{0}, segunknownN{0}, genericN{0},
    papextendN{0}, satDiamondN{0}, satEntriesN{0}, descN{0};
static std::atomic<uint64_t> arityInline[9] = {};
static std::atomic<uint64_t> arityUnknown[9] = {};
static std::atomic<uint64_t> arityGeneric[9] = {};
// Returns whether `ECO_PAP_HISTO` is set, to any value; read once and kept
// for the life of the process.
static bool enabled() {
    static const bool on = (::getenv("ECO_PAP_HISTO") != nullptr);
    return on;
}
// Adds one to `bucket[n]`, with every `n` from 8 up counted in `bucket[8]`,
// when the counters are enabled. Nothing calls it.
static void bump(std::atomic<uint64_t> *bucket, unsigned n) {
    if (!enabled()) return;
    bucket[n <= 8 ? n : 8].fetch_add(1, std::memory_order_relaxed);
}
}  // namespace papHisto

// Prints the `papHisto` and `satFilter` counters and the recorded call-site
// signatures to standard error, when `ECO_PAP_HISTO` is set. This function
// has external linkage, but no file in the runtime declares or calls it.
void ecoDumpPapHistogram() {
    if (!papHisto::enabled()) return;
    llvm::errs() << "[pap-histo] fast=" << papHisto::fastN
                 << " inline=" << papHisto::inlineN
                 << " segunknown=" << papHisto::segunknownN
                 << " generic=" << papHisto::genericN
                 << " papextend=" << papHisto::papextendN
                 << " | descs=" << papHisto::descN
                 << " satEntries=" << papHisto::satEntriesN
                 << " satDiamonds=" << papHisto::satDiamondN << "\n";
    auto row = [](const char *name, std::atomic<uint64_t> *a) {
        llvm::errs() << "[pap-histo] " << name << " by numNewArgs:";
        for (unsigned i = 0; i <= 8; ++i)
            llvm::errs() << " " << (i == 8 ? "8+" : std::to_string(i)) << "="
                         << a[i];
        llvm::errs() << "\n";
    };
    row("inline", papHisto::arityInline);
    row("segunknown", papHisto::arityUnknown);
    row("generic", papHisto::arityGeneric);
    llvm::errs() << "[sat-filter] considered=" << satFilter::considered
                 << " generated=" << satFilter::generated
                 << " rejected: arity=" << satFilter::byArity
                 << " signature=" << satFilter::bySignature
                 << " shape=" << satFilter::byShape << "\n";
    llvm::errs() << "[pap-histo] satSigs(n,kc,rc) =";
    for (const SatSiteSig &s : g_satSigs)
        llvm::errs() << " (" << s.n << "," << s.kc << "," << (unsigned)s.rc << ")";
    llvm::errs() << "\n";
}

// Appends to `out` the name of the evaluator descriptor whose generic entry is
// `wrapperName`: `__eco_evaldesc_<wrapperName>`.
static void evalDescName(StringRef wrapperName, llvm::SmallVectorImpl<char> &out) {
    ("__eco_evaldesc_" + wrapperName).toVector(out);
}

// Appends to `out` the name of the saturated-call entry of `targetName` for
// `n` new arguments: `__closure_sat_<targetName>_n<n>`, with `_ri`, `_rf` or
// `_rc` appended for a `resultKind` of Int, Float or Char.
static void satEntryName(StringRef targetName, unsigned n, uint8_t resultKind,
                         llvm::SmallVectorImpl<char> &out) {
    const char *k = "";
    switch (resultKind) {
        case 1: k = "_ri"; break;
        case 2: k = "_rf"; break;
        case 3: k = "_rc"; break;
        default: k = ""; break;
    }
    ("__closure_sat_" + targetName + "_n" + llvm::Twine(n) + k).toVector(out);
}

// Returns the LLVM type a converted function uses for a value of slot kind
// `kind` (REP_ABI_001): i64, f64 or i32 for Int, Float or Char, and
// `ptr addrspace(1)` for anything else.
static Type paramKindToLLVMType(MLIRContext *ctx, uint8_t kind) {
    switch (kind) {
        case 1: return IntegerType::get(ctx, 64);
        case 2: return Float64Type::get(ctx);
        case 3: return eco::getEcoCharType(ctx);
        default: return LLVM::LLVMPointerType::get(ctx, 1);
    }
}

// Makes the saturated-call entry of `targetSymbol` for `n` new arguments
// (unless the symbol cache already holds one of its name), writes its name to
// `outName`, and returns whether the entry exists.
//
// The entry is an internal function taking a resolved closure base (`ptr`)
// and the target's last `n` parameters. It loads the first C = `stageArity` -
// `n` arguments from the closure's value slots at the target's parameter
// types and calls the target with all of them. A call site knows its own `n`
// but not C, so it cannot call the target directly; the entry's type depends
// only on the new arguments and the result.
//
// No entry is made, and false is returned, when the target is not a defined
// non-variadic function with exactly `stageArity` parameters, when `n` is 0
// or above `stageArity`, when `stageArity` is above 16, when the target does
// not return the type `paramKindToLLVMType(resultKind)`, or when one of the
// first C parameters is not a pointer, f64, i32 or i64. `kindsBitmap` is not
// used to build the entry. With `runtime.topLog` set, the entry's body is
// logged to be built later; the entry is not added to the symbol cache.
static bool getOrCreateSatEntry(OpBuilder &builder, ModuleOp module,
                                const EcoRuntime &runtime, StringRef targetSymbol,
                                unsigned n, int64_t stageArity,
                                uint64_t kindsBitmap, uint8_t resultKind,
                                Location loc,
                                llvm::SmallVectorImpl<char> &outName) {
    auto *ctx = builder.getContext();
    satEntryName(targetSymbol, n, resultKind, outName);
    StringRef name(outName.data(), outName.size());
    if (runtime.lookupSymbol<LLVM::LLVMFuncOp>(name))
        return true;

    auto target = runtime.lookupSymbol<LLVM::LLVMFuncOp>(targetSymbol);
    if (!target || target.isExternal())
        return false;
    auto targetTy = target.getFunctionType();
    if (targetTy.isVarArg())
        return false;
    if (static_cast<int64_t>(targetTy.getNumParams()) != stageArity)
        return false;
    if (n == 0 || static_cast<int64_t>(n) > stageArity)
        return false;
    // The entry returns what the target returns, with no boxing as the
    // wrapper may do, and the site merges it with the array path's result
    // of type `paramKindToLLVMType(resultKind)`; the two must match.
    if (targetTy.getReturnType() != paramKindToLLVMType(ctx, resultKind))
        return false;

    const int64_t captureCount = stageArity - static_cast<int64_t>(n);
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);
    auto i8Ty = IntegerType::get(ctx, 8);
    auto i64Ty = IntegerType::get(ctx, 64);
    auto f64Ty = Float64Type::get(ctx);

    // The limit is meant to keep entries clear of a SelectionDAG assertion on
    // wide `gc.statepoint` signatures with struct returns. It also keeps the
    // 2-bit kind shifts below within one word.
    if (stageArity > 16)
        return false;

    SmallVector<Type> satParams;
    satParams.push_back(ptrTy);  // The resolved closure base.
    for (int64_t i = captureCount; i < stageArity; ++i)
        satParams.push_back(targetTy.getParamType(i));

    Type retTy = targetTy.getReturnType();
    auto satTy = LLVM::LLVMFunctionType::get(retTy, satParams, /*isVarArg=*/false);

    // Checked here, before anything is made, because the body may be built
    // later on another thread, where it cannot back out.
    for (int64_t i = 0; i < captureCount; ++i) {
        Type want = targetTy.getParamType(i);
        if (!isa<LLVM::LLVMPointerType>(want) && !want.isF64() &&
            !eco::isEcoCharType(want) && !want.isInteger(64))
            return false;
    }

    std::string nameStr = name.str();
    auto buildBody = [=](OpBuilder &builder, LLVM::LLVMFuncOp fn) mutable {
        Block *entry = fn.addEntryBlock(builder);
        builder.setInsertionPointToStart(entry);

        SmallVector<Value> callArgs;
        Value self = entry->getArgument(0);
        for (int64_t i = 0; i < captureCount; ++i) {
            int64_t off = layout::ClosureValuesOffset + i * layout::PtrSize;
            auto offConst = builder.create<LLVM::ConstantOp>(
                loc, i64Ty, builder.getI64IntegerAttr(off));
            auto slot = builder.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, self,
                                                    ValueRange{offConst});
            assert(stageArity <= 16 && "sat entry: kinds shift past one word");
            uint8_t k = static_cast<uint8_t>((kindsBitmap >> (2 * i)) & 0x3);
            Type want = targetTy.getParamType(i);
            Value v;
            if (isa<LLVM::LLVMPointerType>(want)) {
                // Loaded at the pointer type so RS4GC tracks it.
                v = builder.create<LLVM::LoadOp>(loc, want, slot);
            } else if (want.isF64()) {
                Value raw = builder.create<LLVM::LoadOp>(loc, i64Ty, slot);
                v = builder.create<LLVM::BitcastOp>(loc, f64Ty, raw);
            } else if (eco::isEcoCharType(want)) {
                Value raw = builder.create<LLVM::LoadOp>(loc, i64Ty, slot);
                v = builder.create<LLVM::TruncOp>(loc, eco::getEcoCharType(ctx), raw);
            } else if (want.isInteger(64)) {
                v = builder.create<LLVM::LoadOp>(loc, i64Ty, slot);
            }
            // The declared kind `k` is not compared with the parameter type;
            // the slot is read by the parameter type alone.
            (void)k;
            callArgs.push_back(v);
        }
        for (unsigned i = 1; i < entry->getNumArguments(); ++i)
            callArgs.push_back(entry->getArgument(i));

        auto call = builder.create<LLVM::CallOp>(loc, target, callArgs);
        if (isa<LLVM::LLVMVoidType>(retTy))
            builder.create<LLVM::ReturnOp>(loc, ValueRange{});
        else
            builder.create<LLVM::ReturnOp>(loc, call.getResult());

    };
    // Not cached: nothing looks an entry up by name except the check above.
    emitTopLevel<LLVM::LLVMFuncOp>(
        runtime, nameStr, /*cache=*/false,
        [=, buildBody = std::move(buildBody)]() mutable -> Operation * {
            OpBuilder b(ctx);
            auto fn = b.create<LLVM::LLVMFuncOp>(loc, StringRef(nameStr), satTy,
                                                 LLVM::Linkage::Internal);
            buildBody(b, fn);
            return fn;
        });
    if (papHisto::enabled())
        papHisto::satEntriesN.fetch_add(1, std::memory_order_relaxed);
    return true;
}

// Makes, unless it exists or is pending, the evaluator descriptor whose
// generic entry is `wrapperSym`, and writes its name to `outName`.
//
// The descriptor is a constant internal global matching `EvaluatorDesc`:
// `generic` = `wrapperSym`, `kinds` = `kindsBitmap`, `result_kind`, and
// `stage_arity` = `stageArity`. It has `stageArity` + 1 `sat` entries when
// `stageArity` is at most `SAT_MAX_ARITY`, and none otherwise. `sat[N]` is
// the saturated-call entry of `targetSymbol` for N when entries are enabled
// (`satFastEnabled`), `targetSymbol` is not empty, `stageArity` is at most
// 16, N is not above the reachable bound (`g_minCaptured`), some call site
// presents the matching signature (`SatSiteSig`), and the entry can be made
// (`getOrCreateSatEntry`); every other `sat[N]` is null.
//
// It creates module-level symbols, so it must be called only from the
// serial pre-pass, after `g_satSigs` and `g_minCaptured` are filled.
static void getOrCreateEvalDesc(OpBuilder &builder, ModuleOp module,
                                const EcoRuntime &runtime,
                                StringRef wrapperSym, StringRef targetSymbol,
                                int64_t stageArity, uint64_t kindsBitmap,
                                uint8_t resultKind, Location loc,
                                llvm::SmallVectorImpl<char> &outName) {
    auto *ctx = builder.getContext();
    evalDescName(wrapperSym, outName);
    StringRef name(outName.data(), outName.size());
    // The symbol cache, not `module.lookupSymbol`, which scans the module
    // and would make the pre-pass quadratic in the number of functions.
    if (runtime.lookupSymbol<LLVM::GlobalOp>(name) || runtime.isPending(name))
        return;

    auto ptrTy = LLVM::LLVMPointerType::get(ctx);
    auto i8Ty = IntegerType::get(ctx, 8);
    auto u16Ty = getU16StorageType(ctx);  // u16 header field, not Char
    auto i32Ty = IntegerType::get(ctx, 32);
    auto i64Ty = IntegerType::get(ctx, 64);

    // With stageArity + 1 entries, `sat[N]` is in bounds for every N the
    // backend's guard admits. Above `SAT_MAX_ARITY` the guard never reads
    // `sat`, so the descriptor has none.
    const unsigned satCount =
        stageArity <= static_cast<int64_t>(layout::SatMaxArity)
            ? static_cast<unsigned>(stageArity) + 1 : 0;
    SmallVector<StringRef> satSyms(satCount);
    SmallVector<llvm::SmallString<64>> satNameStorage(satCount);
    // `getOrCreateSatEntry` refuses a stage arity above 16; testing it first
    // also keeps the kind shifts below within one word.
    if (satFastEnabled() && !targetSymbol.empty() && satCount > 0 &&
        stageArity <= 16) {
        // A target no `eco.papCreate` names has a bound of the full arity.
        unsigned minC0 = 0;
        if (auto it = g_minCaptured.find(targetSymbol); it != g_minCaptured.end())
            minC0 = it->second;
        const unsigned maxReachableN =
            static_cast<unsigned>(stageArity) > minC0
                ? static_cast<unsigned>(stageArity) - minC0
                : 0;

        for (unsigned n = 1; n < satCount; ++n) {
            satFilter::considered.fetch_add(1, std::memory_order_relaxed);
            if (n > maxReachableN) {
                satFilter::byArity.fetch_add(1, std::memory_order_relaxed);
                continue;
            }
            // Never true here, given the test above.
            if (stageArity > 16) {
                satFilter::byShape.fetch_add(1, std::memory_order_relaxed);
                continue;
            }
            // The kinds of the target's last n parameters (see SatSiteSig).
            const unsigned shift = 2u * (static_cast<unsigned>(stageArity) - n);
            const uint64_t mask =
                n >= 32 ? ~uint64_t{0} : ((uint64_t{1} << (2 * n)) - 1);
            const uint64_t requiredKc = (kindsBitmap >> shift) & mask;
            if (!satSigPresent(n, requiredKc, resultKind)) {
                satFilter::bySignature.fetch_add(1, std::memory_order_relaxed);
                continue;
            }
            if (getOrCreateSatEntry(builder, module, runtime, targetSymbol, n,
                                    stageArity, kindsBitmap, resultKind, loc,
                                    satNameStorage[n])) {
                satSyms[n] = StringRef(satNameStorage[n].data(),
                                       satNameStorage[n].size());
                satFilter::generated.fetch_add(1, std::memory_order_relaxed);
            } else {
                satFilter::byShape.fetch_add(1, std::memory_order_relaxed);
            }
        }
    }

    auto satArrTy = LLVM::LLVMArrayType::get(ptrTy, satCount);
    auto descTy = LLVM::LLVMStructType::getLiteral(
        ctx, {ptrTy, i64Ty, i8Ty, i8Ty, u16Ty, i32Ty, satArrTy});

    std::string nameStr = name.str();

    // The initializer may be built later on another thread, so it captures
    // copies.
    SmallVector<std::string> satNames;
    for (StringRef sym : satSyms)
        satNames.push_back(sym.str());
    std::string wrapperSymStr = wrapperSym.str();
    auto buildBody = [=](OpBuilder &builder, LLVM::GlobalOp global) mutable {
        Block *blk = builder.createBlock(&global.getInitializerRegion());
        builder.setInsertionPointToStart(blk);
        Value agg = builder.create<LLVM::UndefOp>(loc, descTy);
        Value genericPtr =
            builder.create<LLVM::AddressOfOp>(loc, ptrTy, wrapperSymStr);
        agg = builder.create<LLVM::InsertValueOp>(loc, agg, genericPtr,
                                                  ArrayRef<int64_t>{0});
        auto put = [&](int64_t idx, Type ty, int64_t v) {
            Value c = builder.create<LLVM::ConstantOp>(loc, ty,
                                                       builder.getIntegerAttr(ty, v));
            agg = builder.create<LLVM::InsertValueOp>(loc, agg, c,
                                                      ArrayRef<int64_t>{idx});
        };
        put(1, i64Ty, static_cast<int64_t>(kindsBitmap));
        put(2, i8Ty, 0);                                       // _pad_sa
        put(3, i8Ty, static_cast<int64_t>(resultKind & 0x3));
        put(4, u16Ty, static_cast<int64_t>(stageArity));       // stage_arity:u16 @+18
        put(5, i32Ty, 0);
        Value nullPtr = builder.create<LLVM::ZeroOp>(loc, ptrTy);
        for (unsigned i = 0; i < satCount; ++i) {
            Value slotVal = nullPtr;
            if (!satNames[i].empty())
                slotVal = builder.create<LLVM::AddressOfOp>(loc, ptrTy, satNames[i]);
            agg = builder.create<LLVM::InsertValueOp>(
                loc, agg, slotVal, ArrayRef<int64_t>{6, static_cast<int64_t>(i)});
        }
        builder.create<LLVM::ReturnOp>(loc, agg);
    };
    emitTopLevel<LLVM::GlobalOp>(
        runtime, nameStr, /*cache=*/true,
        [=, buildBody = std::move(buildBody)]() mutable -> Operation * {
            OpBuilder b(ctx);
            auto global = b.create<LLVM::GlobalOp>(
                loc, descTy, /*isConstant=*/true, LLVM::Linkage::Internal,
                StringRef(nameStr), /*value=*/Attribute());
            buildBody(b, global);
            return global;
        });

    if (papHisto::enabled())
        papHisto::descN.fetch_add(1, std::memory_order_relaxed);
}

// Returns the context of `b`.
static inline MLIRContext *ctx0(OpBuilder &b) { return b.getContext(); }

// Emits a `__eco_sat_begin` marker for a call of the closure `closureHPtr`
// with `newArgs`, to be placed before the call's argument-array sequence, and
// returns its token, or a null value when the site is not eligible. The
// sequence is closed with `emitSatEnd`. The backend's `expandSatMarkers` may
// turn the bracket into a guarded direct call of `sat[N]` (see `SatSiteSig`)
// with the bracketed sequence as the fallback.
//
// `kinds` are the slot kinds of the N new arguments as the site knows them
// statically, and `resultKind` and `resultType` the result's. The site is
// eligible when entries are enabled, N is 1 to 8, `kinds` has N entries, the
// result type is `paramKindToLLVMType(resultKind)`, each new argument already
// has the type `paramKindToLLVMType` gives its kind, the pre-pass recorded
// the signature, and inline dereferencing is enabled. The marker takes the
// resolved closure base, N, the packed kinds, the result kind, the offset of
// `sat[N]` in a descriptor, and the new arguments.
static Value emitSatBegin(ConversionPatternRewriter &rewriter, Location loc,
                          const EcoRuntime &runtime, Value closureHPtr,
                          ValueRange newArgs, ArrayRef<uint8_t> kinds,
                          uint8_t resultKind, Type resultType) {
    if (!satFastEnabled())
        return Value();
    const size_t n = newArgs.size();
    if (n == 0 || n > 8 || kinds.size() != n)
        return Value();
    if (!resultType || isa<LLVM::LLVMVoidType>(resultType))
        return Value();
    // The direct call's result and the fallback's are merged, so the types
    // must be equal.
    if (resultType != paramKindToLLVMType(ctx0(rewriter), resultKind))
        return Value();


    auto *ctx = rewriter.getContext();
    auto i64Ty = IntegerType::get(ctx, 64);

    uint64_t kc = 0;
    for (size_t i = 0; i < n; ++i) {
        Type want = paramKindToLLVMType(ctx, kinds[i]);
        if (newArgs[i].getType() != want)
            return Value();
        kc |= (static_cast<uint64_t>(kinds[i]) & 0x3) << (2 * i);
    }
    // No entry exists for a signature the pre-pass did not record, so a
    // marker would only add a guard that always fails. The pre-pass computes
    // the same signature from the same site, so a miss means the two
    // disagree; the first 25 are reported when `ECO_PAP_HISTO` is set.
    if (!satSigPresent(static_cast<unsigned>(n), kc, resultKind & 0x3)) {
        if (papHisto::enabled()) {
            static std::atomic<unsigned> shown{0};
            if (shown.fetch_add(1, std::memory_order_relaxed) < 25)
                llvm::errs() << "[sat-miss] site sig (n=" << n << ",kc=" << kc
                             << ",rc=" << unsigned(resultKind & 3)
                             << ") not recorded by the pre-pass\n";
        }
        return Value();
    }

    // A closure is never an embedded constant (see ProjectClosureOpLowering).
    if (!inlineDerefExtEnabled())
        return Value();
    Value closurePtr = inlineResolvedBase(rewriter, loc, closureHPtr, runtime);

    auto konst = [&](int64_t v) {
        return rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
                                                 rewriter.getI64IntegerAttr(v))
            .getResult();
    };
    SmallVector<Value> ops;
    ops.push_back(closurePtr);
    ops.push_back(konst(static_cast<int64_t>(n)));
    ops.push_back(konst(static_cast<int64_t>(kc)));
    ops.push_back(konst(static_cast<int64_t>(resultKind & 0x3)));
    ops.push_back(konst(static_cast<int64_t>(layout::EvaluatorDescSatOffset +
                                             8 * n)));
    ops.append(newArgs.begin(), newArgs.end());

    auto marker = runtime.getOrCreateSatBeginMarker(rewriter);
    auto call = rewriter.create<LLVM::CallOp>(loc, marker, ops);
    if (papHisto::enabled())
        papHisto::satDiamondN.fetch_add(1, std::memory_order_relaxed);
    return call.getResult();
}

// Emits the `__eco_sat_end` marker that closes the bracket opened by the
// `emitSatBegin` that returned `tok`, or nothing when `tok` is null.
// `slowResult` is the result of the bracketed sequence; when the backend
// expands the bracket, the later uses of `slowResult` take the merged result
// instead.
static void emitSatEnd(ConversionPatternRewriter &rewriter, Location loc,
                       const EcoRuntime &runtime, Value tok, Value slowResult) {
    if (!tok)
        return;
    auto marker = runtime.getOrCreateSatEndMarker(rewriter);
    rewriter.create<LLVM::CallOp>(loc, marker, ValueRange{tok, slowResult});
}

// Makes, unless it exists or is pending, the evaluator descriptor whose
// generic entry is the function `funcSymbol` itself, and writes its name,
// `__eco_evaldesc_<funcSymbol>`, to `outName`.
//
// This is the descriptor for `eco.allocate_closure` and `eco.make_closure`,
// which name a function that is called through an argument array as it is,
// with no wrapper. It is laid out as `getOrCreateEvalDesc` lays out its
// descriptors, with the same number of `sat` entries, all null. It must be
// called only from the serial pre-pass.
static void getOrCreateEvalDescForFunc(OpBuilder &builder, ModuleOp module,
                                       const EcoRuntime &runtime,
                                       StringRef funcSymbol, int64_t arity,
                                       uint64_t kindsBitmap, uint8_t resultKind,
                                       Location loc,
                                       llvm::SmallVectorImpl<char> &outName) {
    auto *ctx = builder.getContext();
    evalDescName(funcSymbol, outName);
    StringRef name(outName.data(), outName.size());
    if (runtime.lookupSymbol<LLVM::GlobalOp>(name) || runtime.isPending(name))
        return;

    auto ptrTy = LLVM::LLVMPointerType::get(ctx);
    auto i8Ty = IntegerType::get(ctx, 8);
    auto u16Ty = getU16StorageType(ctx);  // u16 header field, not Char
    auto i32Ty = IntegerType::get(ctx, 32);
    auto i64Ty = IntegerType::get(ctx, 64);
    const unsigned satCount =
        arity <= static_cast<int64_t>(layout::SatMaxArity)
            ? static_cast<unsigned>(arity) + 1 : 0;
    auto satArrTy = LLVM::LLVMArrayType::get(ptrTy, satCount);
    auto descTy = LLVM::LLVMStructType::getLiteral(
        ctx, {ptrTy, i64Ty, i8Ty, i8Ty, u16Ty, i32Ty, satArrTy});

    std::string nameStr = name.str();
    std::string funcSymbolStr = funcSymbol.str();
    auto buildBody = [=](OpBuilder &builder, LLVM::GlobalOp global) mutable {
        Block *blk = builder.createBlock(&global.getInitializerRegion());
        builder.setInsertionPointToStart(blk);
        Value agg = builder.create<LLVM::UndefOp>(loc, descTy);
        Value genericPtr = builder.create<LLVM::AddressOfOp>(loc, ptrTy, funcSymbolStr);
        agg = builder.create<LLVM::InsertValueOp>(loc, agg, genericPtr,
                                                  ArrayRef<int64_t>{0});
        auto put = [&](int64_t idx, Type ty, int64_t v) {
            Value c = builder.create<LLVM::ConstantOp>(loc, ty,
                                                       builder.getIntegerAttr(ty, v));
            agg = builder.create<LLVM::InsertValueOp>(loc, agg, c,
                                                      ArrayRef<int64_t>{idx});
        };
        put(1, i64Ty, static_cast<int64_t>(kindsBitmap));
        put(2, i8Ty, 0);                                       // _pad_sa
        put(3, i8Ty, static_cast<int64_t>(resultKind & 0x3));
        put(4, u16Ty, static_cast<int64_t>(arity));            // stage_arity:u16 @+18
        put(5, i32Ty, 0);
        Value nullPtr = builder.create<LLVM::ZeroOp>(loc, ptrTy);
        for (unsigned i = 0; i < satCount; ++i)
            agg = builder.create<LLVM::InsertValueOp>(
                loc, agg, nullPtr, ArrayRef<int64_t>{6, static_cast<int64_t>(i)});
        builder.create<LLVM::ReturnOp>(loc, agg);
    };
    emitTopLevel<LLVM::GlobalOp>(
        runtime, nameStr, /*cache=*/true,
        [=, buildBody = std::move(buildBody)]() mutable -> Operation * {
            OpBuilder b(ctx);
            auto global = b.create<LLVM::GlobalOp>(
                loc, descTy, /*isConstant=*/true, LLVM::Linkage::Internal,
                StringRef(nameStr), /*value=*/Attribute());
            buildBody(b, global);
            return global;
        });
    if (papHisto::enabled())
        papHisto::descN.fetch_add(1, std::memory_order_relaxed);
}

// Emits and returns the address of the descriptor made by
// `getOrCreateEvalDescForFunc` for `funcSymbol`, which must already be in the
// symbol cache; this is asserted.
static Value emitEvalDescAddrForFunc(OpBuilder &b, Location loc,
                                     const EcoRuntime &runtime,
                                     StringRef funcSymbol) {
    auto ptrTy = LLVM::LLVMPointerType::get(b.getContext());
    llvm::SmallString<96> nameBuf;
    evalDescName(funcSymbol, nameBuf);
    // The symbol cache, not `module.lookupSymbol`: asserts are on except in
    // release builds, and this runs for every closure site on the parallel
    // workers, where a module scan would be slow.
    assert(runtime.lookupSymbol<LLVM::GlobalOp>(StringRef(nameBuf)) &&
           "bare-function EvaluatorDesc not pre-materialized");
    return b.create<LLVM::AddressOfOp>(loc, ptrTy, StringRef(nameBuf));
}

// Emits and returns the address of the evaluator descriptor of `wrapper`,
// which is what a closure's `evaluator` holds. The descriptor must already
// be in the symbol cache; this is asserted. `wrapper` must not be null.
static Value emitEvalDescAddr(OpBuilder &b, Location loc,
                              const EcoRuntime &runtime,
                              LLVM::LLVMFuncOp wrapper) {
    auto ptrTy = LLVM::LLVMPointerType::get(b.getContext());
    llvm::SmallString<96> nameBuf;
    evalDescName(wrapper.getSymName(), nameBuf);
    assert(runtime.lookupSymbol<LLVM::GlobalOp>(StringRef(nameBuf)) &&
           "EvaluatorDesc not pre-materialized: preMaterializeClosureArtifacts "
           "missed a wrapper, and the closure would hold a dangling evaluator");
    return b.create<LLVM::AddressOfOp>(loc, ptrTy, StringRef(nameBuf));
}

// Returns whether `getOrCreateWrapper` with `typedNewargs` makes a typed
// wrapper for `funcSymbol`, rather than returning the function itself because
// it already takes an argument array. The latter is true of a function absent
// from `origFuncTypes` whose shape `usesArgsArrayConvention` accepts; its
// slots are boxed, and a closure over it must record them so.
static bool wrapperWillBeTypedNewargs(const EcoRuntime &runtime,
                                       StringRef funcSymbol) {
    // The same test as in getOrCreateWrapper.
    if (!runtime.origFuncTypes.contains(funcSymbol)) {
        if (auto existingFunc = runtime.lookupSymbol<LLVM::LLVMFuncOp>(funcSymbol)) {
            if (usesArgsArrayConvention(existingFunc)) return false;
        }
    }
    return true;
}

// Appends to `out` the name of the eval layout for `kinds` and `resultKind`:
// `__eco_eval_layout_r<resultKind>_<k0>_..._<n>` for n <= 64 kinds, and
// `__eco_eval_layout_r<resultKind>_h<hash>_<n>` above, where the hash is the
// 64-bit FNV-1a of the kinds in hexadecimal. Two kind lists of more than 64
// entries with the same length and hash get the same name.
static void evalLayoutName(ArrayRef<uint8_t> kinds, uint8_t resultKind,
                           llvm::SmallVectorImpl<char> &out) {
    llvm::raw_svector_ostream os(out);
    os << "__eco_eval_layout_r" << unsigned(resultKind) << "_";
    if (kinds.size() <= 64) {
        for (uint8_t k : kinds) os << unsigned(k) << "_";
    } else {
        uint64_t h = 0xcbf29ce484222325ULL;   // FNV-1a 64
        for (uint8_t k : kinds) { h ^= k; h *= 0x100000001b3ULL; }
        os << "h";
        os.write_hex(h);
        os << "_";
    }
    os << unsigned(kinds.size());
}

// Makes, unless one of its name was already made, the eval layout for `kinds`
// and `resultKind`: a private constant global matching `EvalParamLayout`
// (`{ i16 num_params, i8 result_kind, i8 pad, [n x i8] kinds }`), named by
// `evalLayoutName`. The name is recorded in `runtime.evalLayoutNames`.
//
// It must be called only before `runtime` is frozen, which is asserted:
// nothing guards `evalLayoutNames` against the parallel workers.
static void ensureEvalLayoutGlobal(OpBuilder &builder, Location loc,
                                   const EcoRuntime &runtime,
                                   ArrayRef<uint8_t> kinds, uint8_t resultKind) {
    auto *ctx = builder.getContext();
    ModuleOp module = runtime.module;
    auto i8Ty = IntegerType::get(ctx, 8);
    auto u16Ty = getU16StorageType(ctx);  // u16 header field, not Char
    uint32_t n = kinds.size();
    llvm::SmallString<48> nameBuf;
    evalLayoutName(kinds, resultKind, nameBuf);
    StringRef name = nameBuf;
    assert(!runtime.frozen &&
           "ensureEvalLayoutGlobal after freeze(): an eval-layout demand the "
           "serial pre-pass did not predict; creating it here would race the "
           "parallel Stage-2 workers");
    if (!runtime.evalLayoutNames.insert(name).second)
        return;
    auto arrayTy = LLVM::LLVMArrayType::get(i8Ty, n);
    auto structTy = LLVM::LLVMStructType::getLiteral(ctx, {u16Ty, i8Ty, i8Ty, arrayTy});
    std::string nameStr = name.str();
    SmallVector<uint8_t> kindsCopy(kinds.begin(), kinds.end());
    auto buildBody = [=](OpBuilder &builder, LLVM::GlobalOp globalOp) mutable {
        Block *initBlock = builder.createBlock(&globalOp.getInitializerRegion());
        builder.setInsertionPointToStart(initBlock);
        Value structVal = builder.create<LLVM::UndefOp>(loc, structTy);
        auto numParamsConst = builder.create<LLVM::ConstantOp>(loc, u16Ty, static_cast<int64_t>(n));
        structVal = builder.create<LLVM::InsertValueOp>(loc, structTy, structVal, numParamsConst,
                                                        ArrayRef<int64_t>{0});
        auto resultKindConst = builder.create<LLVM::ConstantOp>(loc, i8Ty, static_cast<int64_t>(resultKind));
        structVal = builder.create<LLVM::InsertValueOp>(loc, structTy, structVal, resultKindConst,
                                                        ArrayRef<int64_t>{1});
        auto padConst = builder.create<LLVM::ConstantOp>(loc, i8Ty, 0);
        structVal = builder.create<LLVM::InsertValueOp>(loc, structTy, structVal, padConst,
                                                        ArrayRef<int64_t>{2});
        Value arrayVal = builder.create<LLVM::UndefOp>(loc, arrayTy);
        for (uint32_t i = 0; i < n; ++i) {
            auto kindConst = builder.create<LLVM::ConstantOp>(loc, i8Ty, static_cast<int64_t>(kindsCopy[i]));
            arrayVal = builder.create<LLVM::InsertValueOp>(loc, arrayTy, arrayVal, kindConst,
                                                           ArrayRef<int64_t>{static_cast<int64_t>(i)});
        }
        structVal = builder.create<LLVM::InsertValueOp>(loc, structTy, structVal, arrayVal,
                                                        ArrayRef<int64_t>{3});
        builder.create<LLVM::ReturnOp>(loc, structVal);
    };
    // Not cached: layouts are deduped by evalLayoutNames, never looked up.
    emitTopLevel<LLVM::GlobalOp>(
        runtime, nameStr, /*cache=*/false,
        [=, buildBody = std::move(buildBody)]() mutable -> Operation * {
            OpBuilder b(ctx);
            auto globalOp = b.create<LLVM::GlobalOp>(
                loc, structTy, /*isConstant=*/true, LLVM::Linkage::Private,
                StringRef(nameStr), Attribute{});
            buildBody(b, globalOp);
            return globalOp;
        });
}

// Emits and returns the address of the eval layout for `kinds` and
// `resultKind`. Despite the name, it makes nothing: the layout must already
// have been made by `ensureEvalLayoutGlobal`, which is asserted.
static Value getOrCreateEvalLayout(ConversionPatternRewriter &rewriter, Location loc,
                                   const EcoRuntime &runtime, ArrayRef<uint8_t> kinds,
                                   uint8_t resultKind = 0) {
    auto *ctx = rewriter.getContext();
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);
    llvm::SmallString<48> nameBuf;
    evalLayoutName(kinds, resultKind, nameBuf);
    // Without assertions a missing layout is still caught, later, by the
    // verifier, which rejects an `llvm.mlir.addressof` of an unknown symbol.
    assert(runtime.evalLayoutNames.contains(StringRef(nameBuf)) &&
           "eval-layout not pre-materialized (plan §13.1)");
    return rewriter.create<LLVM::AddressOfOp>(loc, ptrTy, StringRef(nameBuf));
}

//===----------------------------------------------------------------------===//
// Calls through the runtime
//===----------------------------------------------------------------------===//

// Emits a call of `eco_apply_closure_eval` that applies the closure
// `closureHPtr` to the `numArgsI32` typed slots at `typedArgsArray`, described
// by the eval layout `layoutPtr`, and returns the result, of type
// `resultLLVMType`.
//
// The runtime writes the result into a stack slot in the form `desiredKind`
// asks for (0 boxed, 1 Int, 2 Float, 3 Char), boxing or unboxing what the
// evaluator returned as needed; the slot is then loaded. The slot is
// allocated in the entry block of the function containing `safeOp` (at the
// current point when `safeOp` is null or not inside an `llvm.func`), and is
// zeroed before the call.
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

    // In the entry block, so that a call inside a loop does not grow the
    // stack on every iteration.
    Value resultSlot;
    {
        OpBuilder::InsertionGuard guard(rewriter);
        auto parentFunc = safeOp ? safeOp->getParentOfType<LLVM::LLVMFuncOp>() : nullptr;
        if (parentFunc) rewriter.setInsertionPointToStart(&parentFunc.getBody().front());
        auto oneConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 1);
        resultSlot = rewriter.create<LLVM::AllocaOp>(loc, ptrTy, resultLLVMType, oneConst);
    }

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
// Emits a call that applies the closure `closureI64`, known to be saturated by
// `newArgs`, to `newArgs`, and returns the result as `resultType`.
//
// The new arguments go into a stack array in the typed convention (a
// primitive raw, a pointer through `closureStoreValueToI64`) with the boxed
// slots registered as GC roots for the call. Their kinds come from
// `origNewArgTypes`, the arguments' eco types, where given, and from their
// converted types otherwise. The eval layout passed is `layoutPtr` if given;
// otherwise the layout of those kinds with the result kind of `safeOp`'s
// `_result_kind` (boxed if absent), or a null pointer when there are no new
// arguments.
//
// When the result is an Int, Float or Char (by `origResultType`, or by
// `resultType` if that is null), `eco_closure_call_saturated_eval` writes it
// unboxed into a stack slot. Otherwise `eco_closure_call_saturated` returns
// it. Both forms are bracketed by saturated-call markers (`emitSatBegin` /
// `emitSatEnd`) when the new arguments' eco types are known.
//
// `safeOp` is the operation being lowered. It must not be null, and the
// stack arrays are allocated in the entry block of its `llvm.func`.
static Value emitInlineClosureCall(ConversionPatternRewriter &rewriter, Location loc, const EcoRuntime &runtime,
                                   Value closureI64, ValueRange newArgs, Type resultType,
                                   ArrayRef<Type> origNewArgTypes = {},
                                   Type origResultType = {},
                                   Operation *safeOp = nullptr,
                                   Value layoutPtr = {}) {
    auto *ctx = rewriter.getContext();
    auto i8Ty = IntegerType::get(ctx, 8);
    auto i64Ty = IntegerType::get(ctx, 64);
    auto i32Ty = IntegerType::get(ctx, 32);
    auto f64Ty = Float64Type::get(ctx);
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);

    int64_t numNewArgs = newArgs.size();
    bool hasOrigNewArgTypes = !origNewArgTypes.empty();

    // Everything from here to the end marker, including the root-range
    // calls, is what a direct call of a saturated-call entry would avoid.
    Value satTok;
    {
        SmallVector<uint8_t> satKinds;
        bool satOk = hasOrigNewArgTypes &&
                     origNewArgTypes.size() == newArgs.size();
        if (satOk)
            for (Type t : origNewArgTypes)
                satKinds.push_back(mlirTypeToParamKind(t));
        if (satOk)
            satTok = emitSatBegin(rewriter, loc, runtime, closureI64, newArgs,
                                  satKinds, mlirTypeToParamKind(resultType),
                                  resultType);
    }

    Value newArgsArray;
    {
        OpBuilder::InsertionGuard allocaGuard(rewriter);
        auto parentFunc = safeOp->getParentOfType<LLVM::LLVMFuncOp>();
        if (parentFunc) rewriter.setInsertionPointToStart(&parentFunc.getBody().front());
        auto numNewArgsConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, numNewArgs);
        newArgsArray = rewriter.create<LLVM::AllocaOp>(loc, ptrTy, i64Ty, numNewArgsConst);
    }

    SmallVector<bool> boxedSlots(newArgs.size(), false);
    for (size_t j = 0; j < newArgs.size(); ++j) {
        Type t = (hasOrigNewArgTypes && j < origNewArgTypes.size())
                     ? origNewArgTypes[j] : newArgs[j].getType();
        boxedSlots[j] = isa<eco::ValueType>(t) || isa<LLVM::LLVMPointerType>(t);
    }
    Value savedRange = emitPushArgsRootRange(rewriter, loc, runtime, newArgsArray, numNewArgs, boxedSlots);

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
        rewriter.create<LLVM::StoreOp>(loc, arg, argDstPtr);
    }

    // The layout lets the runtime convert a slot whose kind differs from the
    // kind the closure records for that parameter.
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
        // The runtime takes the result kind from the closure, and the
        // layout's should agree with it.
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

    // A primitive result goes through the `_eval` entry, which delivers it
    // unboxed, rather than being boxed by the runtime and unboxed again here.
    auto charTy = eco::getEcoCharType(ctx);
    uint8_t desiredKind = 0;
    Type slotTy = ptrTy;
    if (origResultType) {
        if (origResultType.isInteger(64))      { desiredKind = 1; slotTy = i64Ty; }
        else if (origResultType.isF64())        { desiredKind = 2; slotTy = f64Ty; }
        else if (auto it = dyn_cast<IntegerType>(origResultType);
                 it && it.getWidth() < 64)       { desiredKind = 3; slotTy = charTy; }
    } else {
        if (resultType.isInteger(64))           { desiredKind = 1; slotTy = i64Ty; }
        else if (resultType.isF64())             { desiredKind = 2; slotTy = f64Ty; }
        else if (auto it = dyn_cast<IntegerType>(resultType);
                 it && it.getWidth() < 64)        { desiredKind = 3; slotTy = charTy; }
    }

    if (desiredKind != 0) {
        Value resultSlot;
        {
            OpBuilder::InsertionGuard guard(rewriter);
            auto parentFunc = safeOp ? safeOp->getParentOfType<LLVM::LLVMFuncOp>() : nullptr;
            if (parentFunc) rewriter.setInsertionPointToStart(&parentFunc.getBody().front());
            auto oneConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 1);
            resultSlot = rewriter.create<LLVM::AllocaOp>(loc, ptrTy, slotTy, oneConst);
        }
        Value zero;
        if (desiredKind == 1) {
            zero = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 0);
        } else if (desiredKind == 2) {
            auto zeroI = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 0);
            zero = rewriter.create<LLVM::BitcastOp>(loc, f64Ty, zeroI);
        } else {
            zero = rewriter.create<LLVM::ConstantOp>(loc, charTy, 0);
        }
        rewriter.create<LLVM::StoreOp>(loc, zero, resultSlot);

        auto desiredKindConst = rewriter.create<LLVM::ConstantOp>(loc, i8Ty,
            static_cast<int64_t>(desiredKind));
        auto evalFunc = runtime.getOrCreateClosureCallSaturatedEval(rewriter);
        rewriter.create<LLVM::CallOp>(loc, evalFunc,
            ValueRange{closureI64, newArgsArray, numNewArgsI32, layoutArg,
                       resultSlot, desiredKindConst});

        emitRestoreArgsRootRange(rewriter, loc, runtime, savedRange);

        Value result = rewriter.create<LLVM::LoadOp>(loc, slotTy, resultSlot);
        // Closes the bracket for a primitive result too: the backend's `$sat` diamond takes its fast
        // entry's return type from this value and checks the closure's result kind against the begin
        // marker's. Without the end the begin was dropped and the call stayed generic
        // (cpp-review-bugs.md "Primitive-result closure calls emit an unmatched __eco_sat_begin").
        emitSatEnd(rewriter, loc, runtime, satTok, result);
        // Only a Char narrower than i32 is adapted; any other mismatch
        // between `slotTy` and `resultType` is returned as `slotTy`.
        if (slotTy != resultType) {
            if (auto ity = dyn_cast<IntegerType>(resultType);
                ity && ity.getWidth() < eco::kEcoCharBits && desiredKind == 3) {
                result = rewriter.create<LLVM::TruncOp>(loc, resultType, result);
            }
        }
        return result;
    }

    auto closureCallFunc = runtime.getOrCreateClosureCallSaturated(rewriter);
    auto runtimeCall = rewriter.create<LLVM::CallOp>(
        loc, closureCallFunc, ValueRange{closureI64, newArgsArray, numNewArgsI32, layoutArg});
    Value resultI64 = runtimeCall.getResult();

    emitRestoreArgsRootRange(rewriter, loc, runtime, savedRange);

    emitSatEnd(rewriter, loc, runtime, satTok, resultI64);

    // Every branch returns the runtime's result as it is.
    if (origResultType && isa<eco::ValueType>(origResultType)) {
        return resultI64;
    }
    if (isHPtrLLVMType(resultType)) {
        return resultI64;
    }
    return resultI64;
}


//===----------------------------------------------------------------------===//
// eco.papExtend -> extend closure or call if saturated
//===----------------------------------------------------------------------===//

/**
 * The lowering of `eco.papExtend`, which applies a closure to `newargs`.
 *
 * Without `remaining_arity` whether the call saturates the closure is decided
 * at run time (`lowerSegmentationUnknown`, `lowerGenericApply`). With it, a
 * call whose `newargs` count equals `remaining_arity` is saturated: it calls
 * `_fast_evaluator` directly when the op has that and `_capture_abi`
 * (`emitFastClosureCall`), and otherwise goes through the runtime
 * (`emitInlineClosureCall`). Any other count is a partial application, which
 * `eco_pap_extend_l` turns into a new closure.
 *
 * When `ECO_GENCALL_COUNTERS` is set (read once per process), each op without
 * `remaining_arity` is preceded by a call to `eco_gencall_stats` with its
 * `_gencall_reason`, or 15 when it has none.
 */
struct PapExtendOpLowering : public OpConversionPattern<PapExtendOp> {
    const EcoRuntime &runtime; // Must outlive the pattern.

    // Creates the pattern, which keeps a reference to `runtime`.
    PapExtendOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx, const EcoRuntime &runtime) :
        OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    // Replaces `op`, whose `_call_kind` is `segmentation_unknown`, with a call
    // of `eco_apply_closure_eval` that applies `closureI64` to `newargs`
    // whatever the closure's remaining arity, and returns success.
    //
    // The new arguments go into a stack array in the typed convention, with
    // their boxed slots registered as GC roots for the call, and are
    // described by the eval layout of their kinds with the op's
    // `_result_kind`. The result is delivered in the kind of the op's
    // converted result type. The sequence is bracketed by saturated-call
    // markers where eligible (`emitSatBegin`). It emits the same code as
    // `lowerGenericApply`.
    LogicalResult lowerSegmentationUnknown(PapExtendOp op, OpAdaptor adaptor,
                                           ConversionPatternRewriter &rewriter,
                                           Location loc, Value closureI64,
                                           ValueRange newargs) const {
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i64Ty = IntegerType::get(ctx, 64);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);
        int64_t numNewArgs = newargs.size();

        // The eco types decide the kinds and which slots are roots.
        SmallVector<Type> origNewArgTypes;
        auto origNewargs = op.getNewargs();
        for (size_t i = 0; i < static_cast<size_t>(numNewArgs); ++i) {
            origNewArgTypes.push_back(origNewargs[i].getType());
        }

        Value satTok;
        {
            SmallVector<uint8_t> satKinds;
            for (Type t : origNewArgTypes)
                satKinds.push_back(mlirTypeToParamKind(t));
            Type satResultTy =
                getTypeConverter()->convertType(op.getResult().getType());
            satTok = emitSatBegin(rewriter, loc, runtime, closureI64, newargs,
                                  satKinds, mlirTypeToParamKind(satResultTy),
                                  satResultTy);
        }

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

        SmallVector<uint8_t> kinds;
        kinds.reserve(numNewArgs);
        SmallVector<bool> boxedSlots;
        boxedSlots.reserve(numNewArgs);
        for (size_t i = 0; i < origNewArgTypes.size(); ++i) {
            uint8_t k = mlirTypeToParamKind(origNewArgTypes[i]);
            kinds.push_back(k);
            boxedSlots.push_back(k == 0);
        }

        // The slots are filled before they are registered as roots; nothing
        // between can collect.
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

        Value typedSavedDepth;
        if (numNewArgs > 0) {
            auto rangePointFunc = runtime.getOrCreateGcStackRangePoint(rewriter);
            typedSavedDepth = rewriter.create<LLVM::CallOp>(loc, rangePointFunc, ValueRange{}).getResult();
            emitChunkedRootPush(rewriter, loc, runtime, typedArgsArray, boxedSlots);
        }

        uint8_t layoutResultKind = static_cast<uint8_t>(op.get_resultKind());
        Value layoutPtr = getOrCreateEvalLayout(rewriter, loc, runtime, kinds,
                                                layoutResultKind);

        Type origResultType = op.getResult().getType();
        Type loweredResultType = getTypeConverter()->convertType(origResultType);
        uint8_t desiredKind = mlirTypeToParamKind(loweredResultType);

        auto numNewArgsI32 = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(numNewArgs));
        Value result = emitClosureEvalCall(rewriter, loc, runtime, op,
                                           closureI64, typedArgsArray,
                                           numNewArgsI32, layoutPtr,
                                           loweredResultType, desiredKind);

        if (numNewArgs > 0) {
            emitRestoreArgsRootRange(rewriter, loc, runtime, typedSavedDepth);
        }

        emitSatEnd(rewriter, loc, runtime, satTok, result);
        rewriter.replaceOp(op, result);
        return success();
    }

    // Replaces `op`, which has no `remaining_arity`, with a call of
    // `eco_apply_closure_eval` (CGEN_058), which applies `closureI64` to
    // `newargs` whether that leaves the closure short of, at, or past its
    // arity, and returns success. The arguments, layout, result and markers
    // are as `lowerSegmentationUnknown` describes.
    LogicalResult lowerGenericApply(PapExtendOp op, OpAdaptor adaptor,
                                    ConversionPatternRewriter &rewriter,
                                    Location loc, Value closureI64,
                                    ValueRange newargs) const {
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i64Ty = IntegerType::get(ctx, 64);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);
        int64_t numNewArgs = newargs.size();

        SmallVector<Type> origNewArgTypes;
        auto origNewargs = op.getNewargs();
        for (size_t i = 0; i < newargs.size(); ++i)
            origNewArgTypes.push_back(origNewargs[i].getType());

        Value satTok;
        {
            SmallVector<uint8_t> satKinds;
            for (Type t : origNewArgTypes)
                satKinds.push_back(mlirTypeToParamKind(t));
            Type satResultTy =
                getTypeConverter()->convertType(op.getResult().getType());
            satTok = emitSatBegin(rewriter, loc, runtime, closureI64, newargs,
                                  satKinds, mlirTypeToParamKind(satResultTy),
                                  satResultTy);
        }

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

        SmallVector<uint8_t> kinds;
        kinds.reserve(numNewArgs);
        SmallVector<bool> boxedSlots;
        boxedSlots.reserve(numNewArgs);
        for (size_t i = 0; i < origNewArgTypes.size(); ++i) {
            uint8_t k = mlirTypeToParamKind(origNewArgTypes[i]);
            kinds.push_back(k);
            boxedSlots.push_back(k == 0);
        }

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

        Value savedDepth;
        if (numNewArgs > 0) {
            auto rangePointFunc = runtime.getOrCreateGcStackRangePoint(rewriter);
            savedDepth = rewriter.create<LLVM::CallOp>(loc, rangePointFunc, ValueRange{}).getResult();
            emitChunkedRootPush(rewriter, loc, runtime, typedArgsArray, boxedSlots);
        }

        uint8_t layoutResultKind = static_cast<uint8_t>(op.get_resultKind());
        Value layoutPtr = getOrCreateEvalLayout(rewriter, loc, runtime, kinds,
                                                layoutResultKind);

        Type origResultType = op.getResult().getType();
        Type loweredResultType = getTypeConverter()->convertType(origResultType);
        uint8_t desiredKind = mlirTypeToParamKind(loweredResultType);

        auto numNewArgsConst = rewriter.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(numNewArgs));
        Value result = emitClosureEvalCall(rewriter, loc, runtime, op,
                                           closureI64, typedArgsArray,
                                           numNewArgsConst, layoutPtr,
                                           loweredResultType, desiredKind);

        if (numNewArgs > 0) {
            emitRestoreArgsRootRange(rewriter, loc, runtime, savedDepth);
        }

        emitSatEnd(rewriter, loc, runtime, satTok, result);
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

        Value closureI64 = adaptor.getClosure();
        auto newargs = adaptor.getNewargs();
        int64_t numNewArgs = newargs.size();

        auto remainingArityAttr = op.getRemainingArityAttr();

        if (!remainingArityAttr) {
            static const bool gencallCounters = (::getenv("ECO_GENCALL_COUNTERS") != nullptr);
            if (gencallCounters) {
                int64_t reason = 15;
                if (auto r = op->getAttrOfType<IntegerAttr>("_gencall_reason"))
                    reason = r.getInt();
                auto reasonVal = rewriter.create<LLVM::ConstantOp>(
                    loc, rewriter.getI32Type(), rewriter.getI32IntegerAttr(static_cast<int32_t>(reason)));
                rewriter.create<LLVM::CallOp>(loc, runtime.getOrCreateGencallStats(rewriter),
                                              ValueRange{reasonVal});
            }
            auto callKindAttr = op.get_callKindAttr();
            if (callKindAttr && callKindAttr.getValue() == "segmentation_unknown") {
                return lowerSegmentationUnknown(op, adaptor, rewriter, loc, closureI64, newargs);
            }
            return lowerGenericApply(op, adaptor, rewriter, loc, closureI64, newargs);
        }

        int64_t remainingArity = remainingArityAttr.getInt();
        bool isSaturated = (numNewArgs == remainingArity);

        if (isSaturated) {
            Type convertedResultTy = getTypeConverter()->convertType(op.getResult().getType());
            Value result;

            SmallVector<Type> origNewArgTypes;
            for (Value v : op.getNewargs())
                origNewArgTypes.push_back(v.getType());
            Type origResultType = op.getResult().getType();

            auto fastEval = op->getAttrOfType<SymbolRefAttr>("_fast_evaluator");
            auto captureAbi = op->getAttrOfType<ArrayAttr>("_capture_abi");

            if (fastEval && captureAbi) {
                result = emitFastClosureCall(rewriter, loc, runtime, closureI64, newargs, fastEval, captureAbi, convertedResultTy);
            } else {
                // The layout is built by `emitInlineClosureCall` from the new arguments' own types: the
                // runtime (eco_closure_call_saturated_eval / spliceArgsForSaturatedCall) reads kinds
                // [0, num_newargs) as the NEW arguments' kinds and takes the captures' kinds from the
                // closure. `_capture_abi` without `_fast_evaluator` used to pass
                // [capture kinds..., 0 x new args] here, so a raw Int new argument was read with a
                // capture's (boxed) kind (cpp-review-bugs.md, fixed 2026-10-30).
                result = emitInlineClosureCall(rewriter, loc, runtime, closureI64, newargs, convertedResultTy,
                                               origNewArgTypes, origResultType, op, /*layoutPtr=*/Value());
            }
            rewriter.replaceOp(op, result);
        } else {
            // The kinds of the new arguments go to `eco_pap_extend_l` as an
            // eval layout with result kind 0, which the pre-pass makes for
            // every `eco.papExtend`.
            auto helperFunc = runtime.getOrCreatePapExtendL(rewriter);

            Value argsArray;
            {
                OpBuilder::InsertionGuard allocaGuard(rewriter);
                auto parentFunc = op->getParentOfType<LLVM::LLVMFuncOp>();
                if (parentFunc) rewriter.setInsertionPointToStart(&parentFunc.getBody().front());
                auto numArgsConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, rewriter.getI64IntegerAttr(numNewArgs));
                argsArray = rewriter.create<LLVM::AllocaOp>(loc, ptrTy, i64Ty, numArgsConst);
            }

            {
                auto i8Ty = IntegerType::get(ctx, 8);
                auto zeroVal = rewriter.create<LLVM::ConstantOp>(loc, i8Ty, 0);
                auto bytesLen = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, numNewArgs * 8);
                rewriter.create<LLVM::MemsetOp>(loc, argsArray, zeroVal, bytesLen, /*isVolatile=*/false);
            }

            auto rangePointFunc = runtime.getOrCreateGcStackRangePoint(rewriter);
            Value savedRange = rewriter.create<LLVM::CallOp>(loc, rangePointFunc, ValueRange{}).getResult();

            SmallVector<uint8_t> newargKinds;
            SmallVector<bool> boxedSlots;
            for (int64_t i = 0; i < numNewArgs; ++i) {
                uint8_t k = mlirTypeToParamKind(op.getNewargs()[i].getType());
                newargKinds.push_back(k);
                boxedSlots.push_back(k == 0);
            }

            for (size_t i = 0; i < newargs.size(); ++i) {
                auto idxConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, rewriter.getI64IntegerAttr(i));
                auto slotPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i64Ty, argsArray, ValueRange{idxConst});
                Value arg = newargs[i];
                if (isHPtrLLVMType(arg.getType())) {
                    // REP_LLVM_002: through the slot barrier.
                    arg = argsSlotStoreValueToI64(rewriter, loc, arg);
                } else if (arg.getType() != i64Ty && isa<LLVM::LLVMPointerType>(arg.getType())) {
                    // A `ptr` in address space 0 is not a heap pointer, and
                    // the barrier takes only `ptr addrspace(1)`.
                    arg = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, arg);
                } else if (auto intTy = dyn_cast<IntegerType>(arg.getType())) {
                    if (intTy.getWidth() < 64) {
                        arg = rewriter.create<LLVM::ZExtOp>(loc, i64Ty, arg);
                    }
                }
                // An f64 is stored as it is: the slot is 64 bits either way.
                rewriter.create<LLVM::StoreOp>(loc, arg, slotPtr);
            }

            // The slots are filled before they are registered; nothing
            // between the range point and here can collect.
            emitChunkedRootPush(rewriter, loc, runtime, argsArray, boxedSlots);

            Value layoutPtr = getOrCreateEvalLayout(rewriter, loc, runtime,
                                                    newargKinds, /*resultKind=*/0);
            auto numNewArgsConst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(numNewArgs));
            auto call = rewriter.create<LLVM::CallOp>(
                loc, helperFunc, ValueRange{closureI64, argsArray, numNewArgsConst, layoutPtr});

            emitRestoreArgsRootRange(rewriter, loc, runtime, savedRange);

            rewriter.replaceOp(op, call.getResult());
        }

        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.call -> func.call, or a call through a closure
//===----------------------------------------------------------------------===//

/**
 * The lowering of `eco.call`.
 *
 * A call with a callee becomes a `func.call`. When the callee returns more
 * than one value it is an sret function (`SretFuncOpLowering`): the call
 * passes a stack slot, allocated in the caller's entry block, as a first
 * argument, and the results are loaded from it right after the call. A call
 * with no callee calls the closure that is its first operand, and must
 * saturate it: `remaining_arity` must be present and equal the number of
 * other operands, or the pattern fails with an error. It goes through
 * `emitInlineClosureCall`.
 */
struct CallOpLowering : public OpConversionPattern<CallOp> {
    const EcoRuntime &runtime; // Must outlive the pattern.

    // Creates the pattern, which keeps a reference to `runtime`.
    CallOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx, const EcoRuntime &runtime) :
        OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult matchAndRewrite(CallOp op, OpAdaptor adaptor, ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();

        auto operands = adaptor.getOperands();

        SmallVector<Type> resultTypes;
        for (Type t: op.getResultTypes()) {
            resultTypes.push_back(getTypeConverter()->convertType(t));
        }

        auto callee = op.getCallee();
        if (callee) {
            if (resultTypes.size() > 1) {
                // The slot is in the entry block so a call in a loop reuses
                // one slot. It is ordinary memory that RS4GC does not track,
                // which is sound only because it holds heap pointers just
                // between the callee's stores before returning and the loads
                // here, with no safepoint between (CGEN_067).
                auto *ctx = rewriter.getContext();
                auto structTy = LLVM::LLVMStructType::getLiteral(ctx, resultTypes);
                auto ptrTy = LLVM::LLVMPointerType::get(ctx);
                Value slot;
                {
                    OpBuilder::InsertionGuard guard(rewriter);
                    auto parent = op->getParentOfType<LLVM::LLVMFuncOp>();
                    if (!parent)
                        return op.emitError("sret eco.call outside llvm.func");
                    rewriter.setInsertionPointToStart(&parent.getBody().front());
                    Value one = rewriter.create<LLVM::ConstantOp>(
                        loc, rewriter.getI32Type(),
                        rewriter.getI32IntegerAttr(1));
                    slot = rewriter.create<LLVM::AllocaOp>(loc, ptrTy, structTy,
                                                           one, /*alignment=*/8);
                }
                SmallVector<Value> callArgs{slot};
                callArgs.append(operands.begin(), operands.end());
                rewriter.create<func::CallOp>(loc, *callee, TypeRange{}, callArgs);
                SmallVector<Value> loads;
                for (auto [i, ft] : llvm::enumerate(resultTypes)) {
                    Value gep = rewriter.create<LLVM::GEPOp>(
                        loc, ptrTy, structTy, slot,
                        ArrayRef<LLVM::GEPArg>{0, static_cast<int32_t>(i)});
                    loads.push_back(
                        rewriter.create<LLVM::LoadOp>(loc, ft, gep));
                }
                rewriter.replaceOp(op, loads);
                return success();
            }
            auto callOp = rewriter.create<func::CallOp>(loc, *callee, resultTypes, operands);
            rewriter.replaceOp(op, callOp.getResults());
        } else {
            if (!op.getRemainingArity()) {
                return op.emitError("indirect calls require remaining_arity attribute");
            }

            int64_t remainingArity = op.getRemainingArity().value();
            Value closureI64 = operands[0];
            auto newArgs = operands.drop_front(1);

            if (static_cast<int64_t>(newArgs.size()) != remainingArity) {
                return op.emitError("remaining_arity must equal number of new arguments");
            }

            Type convertedResultTy = resultTypes[0];
            Value result;

            SmallVector<Type> origNewArgTypes;
            for (Value v : op.getOperands().drop_front(1))
                origNewArgTypes.push_back(v.getType());
            Type origResultType = op.getResultTypes()[0];

            result = emitInlineClosureCall(rewriter, loc, runtime, closureI64, newArgs, convertedResultTy,
                                           origNewArgTypes, origResultType, op);
            rewriter.replaceOp(op, result);
        }

        return success();
    }
};

// Makes the eval layouts a closure call site `op` with new arguments
// `origNewargs` may refer to: the layout of their kinds with `resultKind`, and
// the same kinds with result kind 0. More is made than a site uses; an
// unreferenced layout is a private global that LLVM can discard.
static void preMaterializeApplyLayouts(OpBuilder &builder,
                                       const EcoRuntime &runtime, Operation *op,
                                       ValueRange origNewargs, uint8_t resultKind) {
    Location loc = op->getLoc();
    SmallVector<uint8_t> kinds;
    kinds.reserve(origNewargs.size());
    for (Value v : origNewargs) kinds.push_back(mlirTypeToParamKind(v.getType()));
    ensureEvalLayoutGlobal(builder, loc, runtime, kinds, resultKind);
    if (resultKind != 0)
        ensureEvalLayoutGlobal(builder, loc, runtime, kinds, /*resultKind=*/0);
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

mlir::Value eco::detail::emitEvalDescAddrForFuncSymbol(
    OpBuilder &b, Location loc, const EcoRuntime &runtime,
    StringRef funcSymbol) {
    return emitEvalDescAddrForFunc(b, loc, runtime, funcSymbol);
}

void eco::detail::preMaterializeClosureArtifacts(
    OpBuilder &builder, const EcoRuntime &runtime,
    const TypeConverter *typeConverter,
    llvm::ArrayRef<PreMatDemand> demand) {
    // Two walks over the closure operations in `demand`, whose operands still
    // have their eco types here. The first records every call site's
    // signature (`g_satSigs`) and every target's smallest capture count
    // (`g_minCaptured`), which the descriptors made by the second walk need
    // complete. The second calls the same creators the patterns call, so that
    // in Stage 2 every lookup the patterns make finds its symbol.
    ModuleOp module = runtime.module;

    g_satSigs.clear();
    g_minCaptured.clear();
    {
        // The signature must be computed as `emitSatBegin` computes it. A
        // mismatch is safe either way (see SatSiteSig) but wasted.
        unsigned seenPe = 0, seenCall = 0;
        unsigned nHist[20] = {};
        auto note = [&](ValueRange newargs, Type resultTy) {
            size_t n = newargs.size();
            nHist[n < 20 ? n : 19]++;
            if (n == 0 || n > 8) return;
            uint64_t kc = 0;
            for (size_t i = 0; i < n; ++i)
                kc |= (static_cast<uint64_t>(
                           mlirTypeToParamKind(newargs[i].getType())) &
                       0x3)
                      << (2 * i);
            uint8_t rc = resultTy ? mlirTypeToParamKind(resultTy) : 0;
            SatSiteSig sig{static_cast<unsigned>(n), kc,
                           static_cast<uint8_t>(rc & 0x3)};
            if (!llvm::is_contained(g_satSigs, sig))
                g_satSigs.push_back(sig);
        };
        auto noteCaptures = [&](StringRef sym, unsigned captured) {
            auto it = g_minCaptured.find(sym);
            if (it == g_minCaptured.end())
                g_minCaptured[sym] = captured;
            else if (captured < it->second)
                it->second = captured;
        };

        auto noteSite = [&](Operation *op) {
            if (auto pe = dyn_cast<PapExtendOp>(op)) {
                ++seenPe;
                note(pe.getNewargs(),
                     typeConverter->convertType(pe.getResult().getType()));
            } else if (auto call = dyn_cast<CallOp>(op)) {
                if (call.getCallee()) return;
                ++seenCall;
                auto operands = call.getOperands();
                if (operands.empty()) return;
                Type rty = call.getNumResults() > 0
                               ? typeConverter->convertType(
                                     call.getResult(0).getType())
                               : Type();
                note(operands.drop_front(1), rty);
            } else if (auto pc = dyn_cast<PapCreateOp>(op)) {
                noteCaptures(pc.getFunction(),
                             static_cast<unsigned>(pc.getNumCaptured()));
            } else if (auto pg = dyn_cast<PapCreateGroupOp>(op)) {
                auto fes = pg.getFastEvaluators();
                auto ncs = pg.getNumCaptured();
                for (unsigned i = 0; i < fes.size(); ++i) {
                    unsigned nc = 0;
                    if (i < ncs.size())
                        nc = static_cast<unsigned>(
                            cast<IntegerAttr>(ncs[i]).getInt());
                    noteCaptures(cast<FlatSymbolRefAttr>(fes[i]).getValue(),
                                 nc);
                }
            }
        };
        for (const PreMatDemand &d : demand)
            for (Operation *op : d.closure)
                noteSite(op);
        if (papHisto::enabled()) {
            llvm::errs() << "[sat-walk] papExtend=" << seenPe
                         << " indirectCall=" << seenCall << " nHist:";
            for (unsigned i = 0; i < 12; ++i)
                llvm::errs() << " " << i << "=" << nHist[i];
            llvm::errs() << "\n";
            llvm::errs() << "[sat-sigs] recorded";
            for (const SatSiteSig &g : g_satSigs)
                llvm::errs() << " (" << g.n << "," << g.kc << "," << unsigned(g.rc)
                             << ")";
            llvm::errs() << "\n";
        }
    }

    // Makes a wrapper, its descriptor and the descriptor's saturated-call
    // entries together. A repeated (target, arity, result kind) would only
    // hit the creators' caches, so it is skipped before any name is built.
    llvm::DenseSet<std::tuple<StringRef, int64_t, uint8_t>> materialized;
    llvm::StringSet<> bareDescDone;
    auto materialize = [&](StringRef funcSymbol, int64_t arity, uint8_t rk,
                           Location loc) {
        if (!materialized.insert({funcSymbol, arity, rk}).second)
            return;
        std::string wrapperName;
        getOrCreateWrapper(builder, module, funcSymbol, arity, loc,
                           typeConverter, runtime,
                           /*typedNewargs=*/true, rk, &wrapperName);
        bool isTyped = wrapperWillBeTypedNewargs(runtime, funcSymbol);
        // The descriptor's `kinds` holds parameters 0 to 31, one full word,
        // not only the 20 whose kinds a closure's packed word holds.
        uint64_t kinds =
            isTyped ? kindsWord(deriveAllParamKinds(runtime, funcSymbol, arity),
                                0, std::min<int64_t>(arity, 32))
                    : 0;
        llvm::SmallString<96> descName;
        getOrCreateEvalDesc(builder, module, runtime, wrapperName,
                            /*targetSymbol=*/isTyped ? funcSymbol : StringRef(),
                            arity, kinds, rk, loc, descName);
    };

    auto visit = [&](Operation *op) {
        if (auto pc = dyn_cast<PapCreateOp>(op)) {
            materialize(pc.getFunction(), pc.getArity(),
                        static_cast<uint8_t>(pc.get_resultKind()), pc.getLoc());
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
                materialize(funcSymbol, arity, rk, pg.getLoc());
            }
        } else if (auto ac = dyn_cast<AllocateClosureOp>(op)) {
            // A closure over a bare function needs a descriptor too. A
            // repeated symbol would only hit the creator's cache.
            if (!bareDescDone.insert(ac.getFunction()).second)
                return;
            llvm::SmallString<96> n;
            getOrCreateEvalDescForFunc(builder, module, runtime,
                                       ac.getFunction(),
                                       ac.getArity(), /*kinds=*/0,
                                       /*resultKind=*/0, ac.getLoc(), n);
        } else if (auto mc = dyn_cast<MakeClosureOp>(op)) {
            if (!bareDescDone.insert(mc.getFunction()).second)
                return;
            llvm::SmallString<96> n;
            getOrCreateEvalDescForFunc(builder, module, runtime,
                                       mc.getFunction(),
                                       mc.getArity(), /*kinds=*/0,
                                       /*resultKind=*/0, mc.getLoc(), n);
        } else if (auto pe = dyn_cast<PapExtendOp>(op)) {
            preMaterializeApplyLayouts(
                builder, runtime, op, pe.getNewargs(),
                static_cast<uint8_t>(pe.get_resultKind()));
        } else if (auto call = dyn_cast<CallOp>(op)) {
            if (call.getCallee()) return;
            auto operands = call.getOperands();
            ValueRange newargs =
                operands.empty() ? ValueRange{} : ValueRange(operands.drop_front(1));
            uint8_t rk = 0;
            if (auto a = call->getAttrOfType<IntegerAttr>("_result_kind"))
                rk = static_cast<uint8_t>(a.getInt());
            preMaterializeApplyLayouts(builder, runtime, op, newargs, rk);
        }
    };
    for (const PreMatDemand &d : demand)
        for (Operation *op : d.closure)
            visit(op);
}
