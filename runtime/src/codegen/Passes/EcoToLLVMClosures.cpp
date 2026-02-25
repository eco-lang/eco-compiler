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

#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/SCF/IR/SCF.h"

using namespace mlir;
using namespace eco;
using namespace eco::detail;

namespace {

//===----------------------------------------------------------------------===//
// eco.project.closure -> load capture from closure values array
//===----------------------------------------------------------------------===//

struct ProjectClosureOpLowering : public OpConversionPattern<ProjectClosureOp> {
    EcoRuntime runtime;

    ProjectClosureOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx, EcoRuntime runtime) :
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
            }
            // else: i64, no conversion needed
        } else {
            // Boxed value (!eco.value) - keep as i64
            // Result type should be i64 after type conversion
        }

        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.allocate_closure -> call eco_alloc_closure
//===----------------------------------------------------------------------===//

struct AllocateClosureOpLowering : public OpConversionPattern<AllocateClosureOp> {
    EcoRuntime runtime;

    AllocateClosureOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx, EcoRuntime runtime) :
        OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult matchAndRewrite(AllocateClosureOp op, OpAdaptor adaptor,
                                  ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        auto func = runtime.getOrCreateAllocClosure(rewriter);
        auto funcSymbol = op.getFunction();
        Value funcPtr = rewriter.create<LLVM::AddressOfOp>(loc, ptrTy, funcSymbol);
        auto arityConst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(op.getArity()));

        auto call = rewriter.create<LLVM::CallOp>(loc, func, ValueRange{funcPtr, arityConst});
        rewriter.replaceOp(op, call.getResult());
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
static LLVM::LLVMFuncOp getOrCreateWrapper(PatternRewriter &rewriter, ModuleOp module, StringRef funcName,
                                           int64_t arity, Location loc, const TypeConverter *typeConverter,
                                           const EcoRuntime &runtime) {
    auto *ctx = rewriter.getContext();
    auto i64Ty = IntegerType::get(ctx, 64);
    auto f64Ty = Float64Type::get(ctx);
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);

    // Check if target function already uses args-array convention
    if (auto existingFunc = module.lookupSymbol<LLVM::LLVMFuncOp>(funcName)) {
        if (usesArgsArrayConvention(existingFunc)) {
            // Function already takes (ptr) -> i64/ptr, use it directly
            return existingFunc;
        }
    }

    // Wrapper function name
    std::string wrapperName = ("__closure_wrapper_" + funcName).str();

    // Check if wrapper already exists
    if (auto existingWrapper = module.lookupSymbol<LLVM::LLVMFuncOp>(wrapperName)) {
        return existingWrapper;
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
        if (!module.lookupSymbol<func::FuncOp>(funcName) &&
            !module.lookupSymbol<LLVM::LLVMFuncOp>(funcName)) {
            OpBuilder::InsertionGuard declGuard(rewriter);
            rewriter.setInsertionPointToStart(module.getBody());
            auto externFuncType = LLVM::LLVMFunctionType::get(targetResultType, targetParamTypes, false);
            auto externFunc = rewriter.create<LLVM::LLVMFuncOp>(loc, funcName, externFuncType);
            externFunc.setLinkage(LLVM::Linkage::External);
        }
    } else if (auto funcFunc = module.lookupSymbol<func::FuncOp>(funcName)) {
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
    } else if (auto llvmFunc = module.lookupSymbol<LLVM::LLVMFuncOp>(funcName)) {
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
    }

    // Create wrapper function type: ptr (*)(ptr)
    auto wrapperType = LLVM::LLVMFunctionType::get(ptrTy, {ptrTy}, false);

    // Insert wrapper at module level
    OpBuilder::InsertionGuard guard(rewriter);
    rewriter.setInsertionPointToStart(module.getBody());

    auto wrapperFunc = rewriter.create<LLVM::LLVMFuncOp>(loc, wrapperName, wrapperType);
    wrapperFunc.setLinkage(LLVM::Linkage::Internal);

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
            // !eco.value param: arg is HPointer, inner function expects i64 HPointer
            // Pass through as-is (argI64 is already i64 HPointer bits)
        } else if (origType && origType.isInteger(64)) {
            // Int param: arg is HPointer to ElmInt → resolve and read value at offset 8
            auto resolved = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{argI64});
            auto off8 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::HeaderSize);
            auto valPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty,
                                                        resolved.getResult(), ValueRange{off8});
            convertedArg = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valPtr);
        } else if (origType && origType.isF64()) {
            // Float param: arg is HPointer to ElmFloat → resolve, read i64 at offset 8, bitcast
            auto resolved = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{argI64});
            auto off8 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::HeaderSize);
            auto valPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty,
                                                        resolved.getResult(), ValueRange{off8});
            Value loadedI64 = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valPtr);
            convertedArg = rewriter.create<LLVM::BitcastOp>(loc, f64Ty, loadedI64);
        } else if (auto intTy = dyn_cast<IntegerType>(targetType); intTy && intTy.getWidth() < 64) {
            // Char (i16/i32): arg is HPointer to ElmChar → resolve and read value at offset 8
            auto resolved = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{argI64});
            auto off8 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::HeaderSize);
            auto valPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty,
                                                        resolved.getResult(), ValueRange{off8});
            Value fullVal = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valPtr);
            convertedArg = rewriter.create<LLVM::TruncOp>(loc, targetType, fullVal);
        } else if (targetType == f64Ty && !origType) {
            // Fallback: no orig types, target is f64 → unbox from HPointer
            auto resolved = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{argI64});
            auto off8 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::HeaderSize);
            auto valPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty,
                                                        resolved.getResult(), ValueRange{off8});
            Value loadedI64 = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valPtr);
            convertedArg = rewriter.create<LLVM::BitcastOp>(loc, f64Ty, loadedI64);
        } else if (isa<LLVM::LLVMPointerType>(targetType)) {
            convertedArg = rewriter.create<LLVM::IntToPtrOp>(loc, targetType, ValueRange{argI64});
        }
        // else: i64 with no orig type or orig is eco.value — pass through as-is
        callArgs.push_back(convertedArg);
    }

    // Call the target function
    auto targetFuncType = LLVM::LLVMFunctionType::get(targetResultType, targetParamTypes, false);
    auto funcSymbolRef = FlatSymbolRefAttr::get(ctx, funcName);
    auto call = rewriter.create<LLVM::CallOp>(loc, targetFuncType, funcSymbolRef, callArgs);

    // Convert result to ptr for the runtime.
    // Convention: the wrapper returns HPointer-encoded values as ptr.
    // For primitive results (Int, Float, Char), we box via eco_alloc_*.
    // For !eco.value results, the inner function already returns i64 HPointer.
    Value resultValue = call.getResult();
    Value resultPtr;

    if (origResultType && isa<eco::ValueType>(origResultType)) {
        // !eco.value result: inner function returns i64 HPointer → convert to ptr
        resultPtr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, ValueRange{resultValue});
    } else if (origResultType && origResultType.isInteger(64)) {
        // Int result: inner function returns raw i64 → box via eco_alloc_int
        auto allocIntFunc = runtime.getOrCreateAllocInt(rewriter);
        auto boxCall = rewriter.create<LLVM::CallOp>(loc, allocIntFunc, ValueRange{resultValue});
        resultPtr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, ValueRange{boxCall.getResult()});
    } else if (origResultType && origResultType.isF64()) {
        // Float result: inner function returns f64 → box via eco_alloc_float
        auto allocFloatFunc = runtime.getOrCreateAllocFloat(rewriter);
        auto boxCall = rewriter.create<LLVM::CallOp>(loc, allocFloatFunc, ValueRange{resultValue});
        resultPtr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, ValueRange{boxCall.getResult()});
    } else if (origResultType && isa<IntegerType>(origResultType) &&
               cast<IntegerType>(origResultType).getWidth() < 64) {
        // Char result: inner function returns i16 → box via eco_alloc_char
        auto allocCharFunc = runtime.getOrCreateAllocChar(rewriter);
        auto boxCall = rewriter.create<LLVM::CallOp>(loc, allocCharFunc, ValueRange{resultValue});
        resultPtr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, ValueRange{boxCall.getResult()});
    } else if (isa<LLVM::LLVMPointerType>(targetResultType)) {
        // ptr result: pass through
        resultPtr = resultValue;
    } else if (targetResultType == f64Ty && !origResultType) {
        // Fallback: no orig types, target returns f64 → box
        auto allocFloatFunc = runtime.getOrCreateAllocFloat(rewriter);
        auto boxCall = rewriter.create<LLVM::CallOp>(loc, allocFloatFunc, ValueRange{resultValue});
        resultPtr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, ValueRange{boxCall.getResult()});
    } else if (auto intTy = dyn_cast<IntegerType>(targetResultType); intTy && !origResultType) {
        // Fallback: no orig types, target returns integer
        if (intTy.getWidth() < 64) {
            // Char: box via eco_alloc_char
            auto allocCharFunc = runtime.getOrCreateAllocChar(rewriter);
            auto boxCall = rewriter.create<LLVM::CallOp>(loc, allocCharFunc, ValueRange{resultValue});
            resultPtr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, ValueRange{boxCall.getResult()});
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
    EcoRuntime runtime;

    PapCreateOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx, EcoRuntime runtime) :
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
        auto captured = adaptor.getCaptured();

        auto allocFunc = runtime.getOrCreateAllocClosure(rewriter);
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
        auto wrapperFunc = getOrCreateWrapper(rewriter, module, funcSymbol, arity, loc, getTypeConverter(), runtime);
        Value funcPtr = rewriter.create<LLVM::AddressOfOp>(loc, ptrTy, wrapperFunc.getSymName());

        // Allocate closure with max_values = arity, n_values = 0
        auto arityConst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(arity));
        auto allocCall = rewriter.create<LLVM::CallOp>(loc, allocFunc, ValueRange{funcPtr, arityConst});
        Value closureHPtr = allocCall.getResult();

        // Convert HPointer to raw pointer for memory operations
        auto resolveCall = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{closureHPtr});
        Value closurePtr = resolveCall.getResult();

        // Use unboxed_bitmap attribute as source-of-truth (verifier ensures consistency)
        uint64_t unboxedBitmap = op.getUnboxedBitmap();
        auto f64Ty = Float64Type::get(ctx);

        uint64_t packedValue =
            static_cast<uint64_t>(numCaptured) | (static_cast<uint64_t>(arity) << 6) | (unboxedBitmap << 12);

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
                capturedValue = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, capturedValue);
            }
            // i64 (both Int and !eco.value) stored directly
            rewriter.create<LLVM::StoreOp>(loc, capturedValue, valuePtr);
        }

        // Handle self-capturing closures: if self_capture_indices is present,
        // store the closure's own HPointer at the specified capture slots.
        // This implements recursive closure backpatching.
        if (auto selfCaptureAttr = op->getAttrOfType<ArrayAttr>("self_capture_indices")) {
            for (auto indexAttr : selfCaptureAttr) {
                int64_t selfIdx = cast<IntegerAttr>(indexAttr).getInt();
                int64_t valueOffset = layout::ClosureValuesOffset + selfIdx * layout::PtrSize;
                auto offsetConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
                    rewriter.getI64IntegerAttr(valueOffset));
                auto valuePtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, closurePtr,
                    ValueRange{offsetConst});
                rewriter.create<LLVM::StoreOp>(loc, closureHPtr, valuePtr);
            }
        }

        rewriter.replaceOp(op, closureHPtr);
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
                                 ArrayAttr captureAbiTypes, Type resultType) {
    auto *ctx = rewriter.getContext();
    auto i8Ty = IntegerType::get(ctx, 8);
    auto i64Ty = IntegerType::get(ctx, 64);
    auto f64Ty = Float64Type::get(ctx);
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);

    // Resolve closure HPointer to raw pointer
    auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
    auto resolveCall = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{closureI64});
    Value closurePtr = resolveCall.getResult();

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

    // Get address of fast clone function
    auto flatSymbol = FlatSymbolRefAttr::get(ctx, fastEvaluator.getRootReference());
    Value funcPtr = rewriter.create<LLVM::AddressOfOp>(loc, ptrTy, flatSymbol);

    // Build function type and indirect call (funcPtr first, then args)
    Type llvmResultType = resultType;
    auto funcType = LLVM::LLVMFunctionType::get(llvmResultType, paramTypes, /*isVarArg=*/false);
    SmallVector<Value> callOperands;
    callOperands.push_back(funcPtr);
    callOperands.append(callArgs.begin(), callArgs.end());
    auto callOp = rewriter.create<LLVM::CallOp>(loc, funcType, callOperands);

    return callOp.getResult();
}

/// Emit a closure call via the generic clone.
/// Calls the generic clone stored in closure.evaluator with (Closure*, args...).
/// This is used when _dispatch_mode="closure".
static Value emitClosureCall(ConversionPatternRewriter &rewriter, Location loc, const EcoRuntime &runtime,
                             Value closureI64, ValueRange newArgs, Type resultType) {
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
    auto callOp = rewriter.create<LLVM::CallOp>(loc, funcType, callOperands);

    return callOp.getResult();
}

/// Emit a closure call when dispatch mode is unknown.
/// Logs a diagnostic and falls back to generic closure call via emitInlineClosureCall.
/// This is used when _dispatch_mode="unknown".
static Value emitUnknownClosureCall(ConversionPatternRewriter &rewriter, Location loc, const EcoRuntime &runtime,
                                    Value closureI64, ValueRange newArgs, Type resultType,
                                    ArrayRef<Type> origNewArgTypes = {},
                                    Type origResultType = {});  // Forward declaration

/// Dispatch a closure call based on the _dispatch_mode attribute.
/// Returns Value() and emits error if dispatch mode is invalid or missing required attributes.
static Value emitDispatchedClosureCall(ConversionPatternRewriter &rewriter, Location loc, const EcoRuntime &runtime,
                                       Operation *op, Value closureI64, ValueRange newArgs, Type resultType,
                                       ArrayRef<Type> origNewArgTypes = {},
                                       Type origResultType = {}) {
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
        return emitFastClosureCall(rewriter, loc, runtime, closureI64, newArgs, fastEval, captureAbi, resultType);
    }

    if (mode == "closure") {
        return emitClosureCall(rewriter, loc, runtime, closureI64, newArgs, resultType);
    }

    if (mode == "unknown") {
        return emitUnknownClosureCall(rewriter, loc, runtime, closureI64, newArgs, resultType,
                                      origNewArgTypes, origResultType);
    }

    op->emitError("unrecognized _dispatch_mode: ") << mode;
    return Value();
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
///
/// Convention: the evaluator wrapper (getOrCreateWrapper) expects arguments
/// as HPointer-encoded i64. This function:
///   1. Copies captured values from the closure, boxing raw (unboxed) captures
///      to HPointer using the unboxed bitmap.
///   2. Boxes new arguments to HPointer based on origNewArgTypes.
///   3. Calls the wrapper and unboxes the result based on origResultType.
///
/// This function uses scf.while for the captured values copy loop, ensuring
/// it can be used inside scf.if regions without violating the single-block
/// constraint. No block splitting occurs.
static Value emitInlineClosureCall(ConversionPatternRewriter &rewriter, Location loc, const EcoRuntime &runtime,
                                   Value closureI64, ValueRange newArgs, Type resultType,
                                   ArrayRef<Type> origNewArgTypes = {},
                                   Type origResultType = {}) {
    auto *ctx = rewriter.getContext();
    auto i8Ty = IntegerType::get(ctx, 8);
    auto i64Ty = IntegerType::get(ctx, 64);
    auto i32Ty = IntegerType::get(ctx, 32);
    auto f64Ty = Float64Type::get(ctx);
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);

    // INV_2: Route through eco_closure_call_saturated instead of inline
    // bitmap interpretation + evaluator call.
    // We only need to: (1) box new args to HPointer, (2) call the runtime.

    int64_t numNewArgs = newArgs.size();

    // === Box new arguments to HPointer-encoded i64 ===
    auto allocIntFunc = runtime.getOrCreateAllocInt(rewriter);
    auto allocCharFunc = runtime.getOrCreateAllocChar(rewriter);
    auto allocFloatFunc = runtime.getOrCreateAllocFloat(rewriter);
    bool hasOrigNewArgTypes = !origNewArgTypes.empty();

    // Allocate array for new args only (runtime handles captures)
    auto numNewArgsConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, numNewArgs);
    Value newArgsArray = rewriter.create<LLVM::AllocaOp>(loc, ptrTy, i64Ty, numNewArgsConst);

    for (size_t j = 0; j < newArgs.size(); ++j) {
        auto jConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, static_cast<int64_t>(j));
        auto argDstPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i64Ty, newArgsArray, ValueRange{jConst});
        Value arg = newArgs[j];

        Type origArgType = (hasOrigNewArgTypes && j < origNewArgTypes.size())
                               ? origNewArgTypes[j] : Type();

        if (origArgType && isa<eco::ValueType>(origArgType)) {
            // !eco.value → already HPointer i64, pass through
        } else if (origArgType && origArgType.isInteger(64)) {
            // Int → box via eco_alloc_int
            auto boxCall = rewriter.create<LLVM::CallOp>(loc, allocIntFunc, ValueRange{arg});
            arg = boxCall.getResult();
        } else if (origArgType && origArgType.isF64()) {
            // Float → box via eco_alloc_float
            auto boxCall = rewriter.create<LLVM::CallOp>(loc, allocFloatFunc, ValueRange{arg});
            arg = boxCall.getResult();
        } else if (origArgType && isa<IntegerType>(origArgType) &&
                   cast<IntegerType>(origArgType).getWidth() < 64) {
            // Char → box via eco_alloc_char
            auto boxCall = rewriter.create<LLVM::CallOp>(loc, allocCharFunc, ValueRange{arg});
            arg = boxCall.getResult();
        } else {
            // No orig type → fallback heuristics
            if (auto intTy = dyn_cast<IntegerType>(arg.getType())) {
                if (intTy.getWidth() == 16) {
                    auto boxCall = rewriter.create<LLVM::CallOp>(loc, allocCharFunc, ValueRange{arg});
                    arg = boxCall.getResult();
                }
                // i64 without orig type → assume !eco.value, pass through
            } else if (arg.getType() == f64Ty) {
                auto boxCall = rewriter.create<LLVM::CallOp>(loc, allocFloatFunc, ValueRange{arg});
                arg = boxCall.getResult();
            }
        }
        rewriter.create<LLVM::StoreOp>(loc, arg, argDstPtr);
    }

    // === Call eco_closure_call_saturated(closure_hptr, new_args, num_newargs) ===
    auto closureCallFunc = runtime.getOrCreateClosureCallSaturated(rewriter);
    auto numNewArgsI32 = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int64_t>(numNewArgs));
    auto runtimeCall = rewriter.create<LLVM::CallOp>(
        loc, closureCallFunc, ValueRange{closureI64, newArgsArray, numNewArgsI32});
    Value resultI64 = runtimeCall.getResult();

    // === Convert result from HPointer i64 to caller's expected type ===
    // The runtime returns HPointer-encoded i64. Use origResultType to unbox:
    //   - !eco.value → pass through HPointer
    //   - Int (i64)  → resolve HPointer → load value at offset 8
    //   - Float (f64) → resolve → load i64 → bitcast to f64
    //   - Char (i16)  → resolve → load i64 → trunc
    //   - No orig type → fallback
    auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);

    Value result;
    if (origResultType && isa<eco::ValueType>(origResultType)) {
        // !eco.value → HPointer pass through
        result = resultI64;
    } else if (origResultType && origResultType.isInteger(64)) {
        // Int → unbox: resolve HPointer → load i64 value at offset 8
        auto resolveResult = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{resultI64});
        auto off8 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::HeaderSize);
        auto valPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty,
                                                    resolveResult.getResult(), ValueRange{off8});
        result = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valPtr);
    } else if (origResultType && origResultType.isF64()) {
        // Float → unbox: resolve → load i64 → bitcast to f64
        auto resolveResult = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{resultI64});
        auto off8 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::HeaderSize);
        auto valPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty,
                                                    resolveResult.getResult(), ValueRange{off8});
        Value loadedI64 = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valPtr);
        result = rewriter.create<LLVM::BitcastOp>(loc, f64Ty, loadedI64);
    } else if (origResultType && isa<IntegerType>(origResultType) &&
               cast<IntegerType>(origResultType).getWidth() < 64) {
        // Char → unbox: resolve → load i64 → trunc
        auto resolveResult = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{resultI64});
        auto off8 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::HeaderSize);
        auto valPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty,
                                                    resolveResult.getResult(), ValueRange{off8});
        Value loadedI64 = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valPtr);
        result = rewriter.create<LLVM::TruncOp>(loc, resultType, loadedI64);
    } else if (!origResultType && resultType == f64Ty) {
        // Fallback: no orig type, converted type is f64 → unbox
        auto resolveResult = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{resultI64});
        auto off8 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::HeaderSize);
        auto valPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty,
                                                    resolveResult.getResult(), ValueRange{off8});
        Value loadedI64 = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valPtr);
        result = rewriter.create<LLVM::BitcastOp>(loc, f64Ty, loadedI64);
    } else if (isa<LLVM::LLVMPointerType>(resultType)) {
        result = rewriter.create<LLVM::IntToPtrOp>(loc, resultType, resultI64);
    } else {
        // Default: i64 with no orig type → assume HPointer, pass through
        result = resultI64;
    }

    return result;
}

/// Implementation of emitUnknownClosureCall.
/// Emits a warning diagnostic and falls back to the legacy inline closure call.
static Value emitUnknownClosureCall(ConversionPatternRewriter &rewriter, Location loc, const EcoRuntime &runtime,
                                    Value closureI64, ValueRange newArgs, Type resultType,
                                    ArrayRef<Type> origNewArgTypes,
                                    Type origResultType) {
    emitWarning(loc) << "closure call with _dispatch_mode='unknown' - "
                     << "closure kind metadata was not propagated; "
                     << "using generic dispatch";
    // Fall back to legacy inline closure call (args-array convention)
    return emitInlineClosureCall(rewriter, loc, runtime, closureI64, newArgs, resultType,
                                 origNewArgTypes, origResultType);
}

//===----------------------------------------------------------------------===//
// eco.papExtend -> extend closure or call if saturated
//===----------------------------------------------------------------------===//

struct PapExtendOpLowering : public OpConversionPattern<PapExtendOp> {
    EcoRuntime runtime;

    PapExtendOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx, EcoRuntime runtime) :
        OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult matchAndRewrite(PapExtendOp op, OpAdaptor adaptor,
                                  ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i64Ty = IntegerType::get(ctx, 64);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        int64_t remainingArity = op.getRemainingArity();
        auto newargs = adaptor.getNewargs();
        int64_t numNewArgs = newargs.size();

        Value closureI64 = adaptor.getClosure();
        bool isSaturated = (numNewArgs == remainingArity);

        if (isSaturated) {
            // Saturated call: use typed closure call if attributes present
            Type convertedResultTy = getTypeConverter()->convertType(op.getResult().getType());
            Value result;

            // Extract original types for inline/unknown closure call paths
            SmallVector<Type> origNewArgTypes;
            for (auto arg : op.getNewargs()) {
                origNewArgTypes.push_back(arg.getType());
            }
            Type origResultType = op.getResult().getType();

            // Check for typed closure calling attributes
            auto fastEval = op->getAttrOfType<SymbolRefAttr>("_fast_evaluator");
            auto captureAbi = op->getAttrOfType<ArrayAttr>("_capture_abi");
            auto closureKind = op->getAttr("_closure_kind");

            if (fastEval && captureAbi) {
                // Fast path: known homogeneous closure, call fast clone directly
                result = emitFastClosureCall(rewriter, loc, runtime, closureI64, newargs, fastEval, captureAbi, convertedResultTy);
            } else if (closureKind) {
                // Has closure kind but not fast path -> heterogeneous, use closure call
                result = emitClosureCall(rewriter, loc, runtime, closureI64, newargs, convertedResultTy);
            } else {
                // No typed closure info -> use legacy inline closure call.
                result = emitInlineClosureCall(rewriter, loc, runtime, closureI64, newargs, convertedResultTy,
                                               origNewArgTypes, origResultType);
            }
            rewriter.replaceOp(op, result);
        } else {
            // Partial application: use runtime helper to create extended closure
            auto helperFunc = runtime.getOrCreatePapExtend(rewriter);

            // Build args array on stack
            auto numArgsConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, rewriter.getI64IntegerAttr(numNewArgs));
            Value argsArray = rewriter.create<LLVM::AllocaOp>(loc, ptrTy, i64Ty, numArgsConst);

            // Get bitmap from attribute (source-of-truth) - may be modified below
            uint64_t newargsBitmap = op.getNewargsUnboxedBitmap();

            for (size_t i = 0; i < newargs.size(); ++i) {
                auto idxConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, rewriter.getI64IntegerAttr(i));
                auto slotPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i64Ty, argsArray, ValueRange{idxConst});
                Value arg = newargs[i];
                if (arg.getType() != i64Ty && isa<LLVM::LLVMPointerType>(arg.getType())) {
                    arg = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, arg);
                } else if (auto intTy = dyn_cast<IntegerType>(arg.getType())) {
                    if (intTy.getWidth() == 16) {
                        // Box i16 (Char) so the wrapper can unbox it later.
                        // Clear the unboxed bit so the GC traces it as an HPointer.
                        auto allocCharFunc = runtime.getOrCreateAllocChar(rewriter);
                        auto boxCall = rewriter.create<LLVM::CallOp>(loc, allocCharFunc, ValueRange{arg});
                        arg = boxCall.getResult();
                        newargsBitmap &= ~(1ULL << i);
                    }
                }
                rewriter.create<LLVM::StoreOp>(loc, arg, slotPtr);
            }

            auto numNewArgsConst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(numNewArgs));
            auto bitmapConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, rewriter.getI64IntegerAttr(newargsBitmap));

            auto call = rewriter.create<LLVM::CallOp>(
                loc, helperFunc, ValueRange{closureI64, argsArray, numNewArgsConst, bitmapConst});
            rewriter.replaceOp(op, call.getResult());
        }

        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.call -> llvm.call or indirect call through closure
//===----------------------------------------------------------------------===//

struct CallOpLowering : public OpConversionPattern<CallOp> {
    EcoRuntime runtime;

    CallOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx, EcoRuntime runtime) :
        OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult matchAndRewrite(CallOp op, OpAdaptor adaptor, ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();

        // Convert result types
        SmallVector<Type> resultTypes;
        for (Type t: op.getResultTypes()) {
            resultTypes.push_back(getTypeConverter()->convertType(t));
        }

        auto callee = op.getCallee();
        if (callee) {
            // Direct call to a known function
            auto callOp = rewriter.create<func::CallOp>(loc, *callee, resultTypes, adaptor.getOperands());
            rewriter.replaceOp(op, callOp.getResults());
        } else {
            // Indirect call through closure
            if (!op.getRemainingArity()) {
                return op.emitError("indirect calls require remaining_arity attribute");
            }

            int64_t remainingArity = op.getRemainingArity().value();
            auto allOperands = adaptor.getOperands();
            Value closureI64 = allOperands[0];
            auto newArgs = allOperands.drop_front(1);

            if (static_cast<int64_t>(newArgs.size()) != remainingArity) {
                return op.emitError("remaining_arity must equal number of new arguments");
            }

            Type convertedResultTy = resultTypes[0];
            Value result;

            // Extract original types for inline/unknown closure call paths
            SmallVector<Type> origNewArgTypes;
            auto origOperands = op.getOperands();
            for (size_t i = 1; i < origOperands.size(); ++i) {
                origNewArgTypes.push_back(origOperands[i].getType());
            }
            Type origResultType = op.getResultTypes()[0];

            // Check for typed closure calling attributes.
            auto dispatchMode = op->getAttrOfType<StringAttr>("_dispatch_mode");
            if (dispatchMode) {
                // Use dispatched closure call based on _dispatch_mode.
                result = emitDispatchedClosureCall(rewriter, loc, runtime, op, closureI64, newArgs, convertedResultTy,
                                                   origNewArgTypes, origResultType);
                if (!result) {
                    return failure();  // Error was already emitted
                }
            } else {
                // No _dispatch_mode -> use legacy inline closure call.
                result = emitInlineClosureCall(rewriter, loc, runtime, closureI64, newArgs, convertedResultTy,
                                               origNewArgTypes, origResultType);
            }
            rewriter.replaceOp(op, result);
        }

        return success();
    }
};

} // namespace

//===----------------------------------------------------------------------===//
// Pattern Population
//===----------------------------------------------------------------------===//

void eco::detail::populateEcoClosurePatterns(EcoTypeConverter &typeConverter, RewritePatternSet &patterns,
                                             EcoRuntime runtime) {

    auto *ctx = patterns.getContext();
    patterns.add<ProjectClosureOpLowering>(typeConverter, ctx, runtime);
    patterns.add<AllocateClosureOpLowering>(typeConverter, ctx, runtime);
    patterns.add<PapCreateOpLowering>(typeConverter, ctx, runtime);
    patterns.add<PapExtendOpLowering>(typeConverter, ctx, runtime);
    patterns.add<CallOpLowering>(typeConverter, ctx, runtime);
}
