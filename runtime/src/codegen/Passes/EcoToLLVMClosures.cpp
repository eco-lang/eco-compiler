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
                                           int64_t arity, Location loc, const TypeConverter *typeConverter) {
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

    // Look up target function to get its actual signature
    // Try func.func first, then LLVM::LLVMFuncOp
    SmallVector<Type> targetParamTypes;
    Type targetResultType = i64Ty;  // Default to i64

    if (auto funcFunc = module.lookupSymbol<func::FuncOp>(funcName)) {
        auto funcType = funcFunc.getFunctionType();
        for (auto paramType : funcType.getInputs()) {
            // Convert through type converter to handle !eco.value -> i64
            Type convertedType = typeConverter ? typeConverter->convertType(paramType) : paramType;
            targetParamTypes.push_back(convertedType ? convertedType : paramType);
        }
        if (funcType.getNumResults() > 0) {
            Type resultType = funcType.getResult(0);
            // Convert through type converter to handle !eco.value -> i64
            Type convertedResult = typeConverter ? typeConverter->convertType(resultType) : resultType;
            targetResultType = convertedResult ? convertedResult : resultType;
        }
    } else if (auto llvmFunc = module.lookupSymbol<LLVM::LLVMFuncOp>(funcName)) {
        auto funcType = llvmFunc.getFunctionType();
        for (unsigned i = 0; i < funcType.getNumParams(); ++i) {
            targetParamTypes.push_back(funcType.getParamType(i));
        }
        targetResultType = funcType.getReturnType();
    } else {
        // Target function not found - create external declaration with all-i64 signature
        // This handles kernel functions that are provided at link time
        for (int64_t i = 0; i < arity; ++i) {
            targetParamTypes.push_back(i64Ty);
        }
        // Create the external function declaration
        OpBuilder::InsertionGuard declGuard(rewriter);
        rewriter.setInsertionPointToStart(module.getBody());
        auto targetFuncType = LLVM::LLVMFunctionType::get(targetResultType, targetParamTypes, false);
        auto externFunc = rewriter.create<LLVM::LLVMFuncOp>(loc, funcName, targetFuncType);
        externFunc.setLinkage(LLVM::Linkage::External);
    }

    // Create wrapper function type: void* (*)(void**)
    // In LLVM terms: ptr (*)(ptr)
    auto wrapperType = LLVM::LLVMFunctionType::get(ptrTy, {ptrTy}, false);

    // Insert wrapper at module level
    OpBuilder::InsertionGuard guard(rewriter);
    rewriter.setInsertionPointToStart(module.getBody());

    auto wrapperFunc = rewriter.create<LLVM::LLVMFuncOp>(loc, wrapperName, wrapperType);
    wrapperFunc.setLinkage(LLVM::Linkage::Internal);

    // Create entry block with args array parameter
    Block *entryBlock = wrapperFunc.addEntryBlock(rewriter);
    rewriter.setInsertionPointToStart(entryBlock);

    Value argsArray = entryBlock->getArgument(0);

    // Load arguments from the array and convert to target types
    SmallVector<Value> callArgs;
    for (int64_t i = 0; i < arity; ++i) {
        auto idxConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, i);
        auto argPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i64Ty, argsArray, ValueRange{idxConst});
        Value argI64 = rewriter.create<LLVM::LoadOp>(loc, i64Ty, argPtr);

        // Convert to target type if needed
        Type targetType = (i < (int64_t)targetParamTypes.size()) ? targetParamTypes[i] : i64Ty;
        Value convertedArg = argI64;

        if (targetType == f64Ty) {
            // Bitcast i64 -> f64
            convertedArg = rewriter.create<LLVM::BitcastOp>(loc, f64Ty, argI64);
        } else if (isa<LLVM::LLVMPointerType>(targetType)) {
            // IntToPtr for pointer types
            convertedArg = rewriter.create<LLVM::IntToPtrOp>(loc, targetType, ValueRange{argI64});
        } else if (targetType != i64Ty) {
            // For other integer types, truncate or extend as needed
            if (auto intTy = dyn_cast<IntegerType>(targetType)) {
                if (intTy.getWidth() < 64) {
                    convertedArg = rewriter.create<LLVM::TruncOp>(loc, targetType, argI64);
                }
            }
        }
        callArgs.push_back(convertedArg);
    }

    // Build the target function type for the call
    auto targetFuncType = LLVM::LLVMFunctionType::get(targetResultType, targetParamTypes, false);
    auto funcSymbolRef = FlatSymbolRefAttr::get(ctx, funcName);
    auto call = rewriter.create<LLVM::CallOp>(loc, targetFuncType, funcSymbolRef, callArgs);

    // Convert result to ptr for the runtime
    Value resultValue = call.getResult();
    Value resultPtr;

    if (targetResultType == f64Ty) {
        // Bitcast f64 -> i64, then inttoptr
        Value resultI64 = rewriter.create<LLVM::BitcastOp>(loc, i64Ty, resultValue);
        resultPtr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, ValueRange{resultI64});
    } else if (isa<LLVM::LLVMPointerType>(targetResultType)) {
        // Already a pointer
        resultPtr = resultValue;
    } else if (auto intTy = dyn_cast<IntegerType>(targetResultType)) {
        // Integer result - extend to i64 if needed, then inttoptr
        Value resultI64 = resultValue;
        if (intTy.getWidth() < 64) {
            resultI64 = rewriter.create<LLVM::ZExtOp>(loc, i64Ty, resultValue);
        }
        resultPtr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, ValueRange{resultI64});
    } else {
        // Default: assume i64-like, convert to ptr
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
        auto funcSymbol = op.getFunction();
        auto module = op->getParentOfType<ModuleOp>();
        auto wrapperFunc = getOrCreateWrapper(rewriter, module, funcSymbol, arity, loc, getTypeConverter());
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

#ifndef NDEBUG
        // Optional: verify attribute matches operand types in debug builds
        uint64_t computedBitmap = 0;
        for (size_t i = 0; i < captured.size(); ++i) {
            Type origType = op.getCaptured()[i].getType();
            if (!isa<ValueType>(origType)) {
                computedBitmap |= (1ULL << i);
            }
        }
        assert(computedBitmap == unboxedBitmap && "unboxed_bitmap mismatch with operand types");
#endif

        uint64_t packedValue =
            static_cast<uint64_t>(numCaptured) | (static_cast<uint64_t>(arity) << 6) | (unboxedBitmap << 12);

        auto packedConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, rewriter.getI64IntegerAttr(packedValue));

        // Store packed field at offset 8
        auto offset8 =
            rewriter.create<LLVM::ConstantOp>(loc, i64Ty, rewriter.getI64IntegerAttr(layout::ClosurePackedOffset));
        auto packedPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, closurePtr, ValueRange{offset8});
        rewriter.create<LLVM::StoreOp>(loc, packedConst, packedPtr);

        // Store captured values starting at offset 24
        for (size_t i = 0; i < captured.size(); ++i) {
            int64_t valueOffset = layout::ClosureValuesOffset + i * layout::PtrSize;
            auto offsetConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, rewriter.getI64IntegerAttr(valueOffset));
            auto valuePtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, closurePtr, ValueRange{offsetConst});

            Value capturedValue = captured[i];
            if (capturedValue.getType() != i64Ty) {
                if (isa<LLVM::LLVMPointerType>(capturedValue.getType())) {
                    capturedValue = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, capturedValue);
                }
            }
            rewriter.create<LLVM::StoreOp>(loc, capturedValue, valuePtr);
        }

        rewriter.replaceOp(op, closureHPtr);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Shared helper: inline closure call
//===----------------------------------------------------------------------===//

/// Emit inline LLVM ops to call a closure's evaluator with combined
/// (captured + new) arguments. Used by both papExtend-saturated and
/// indirect eco.call.
///
/// closureI64:  the closure HPointer as i64
/// newArgs:     the new arguments to append
/// resultType:  the expected LLVM result type (i64, f64, or ptr)
/// Returns the result Value with the correct type.
///
/// This function uses scf.while for the captured values copy loop, ensuring
/// it can be used inside scf.if regions without violating the single-block
/// constraint. No block splitting occurs.
static Value emitInlineClosureCall(ConversionPatternRewriter &rewriter, Location loc, const EcoRuntime &runtime,
                                   Value closureI64, ValueRange newArgs, Type resultType) {
    auto *ctx = rewriter.getContext();
    auto i8Ty = IntegerType::get(ctx, 8);
    auto i64Ty = IntegerType::get(ctx, 64);
    auto f64Ty = Float64Type::get(ctx);
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);

    // Resolve closure HPointer to raw pointer
    auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
    auto resolveCall = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{closureI64});
    Value closurePtr = resolveCall.getResult();

    // Load packed field at offset 8
    auto offset8 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::ClosurePackedOffset);
    auto packedPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, closurePtr, ValueRange{offset8});
    Value packed = rewriter.create<LLVM::LoadOp>(loc, i64Ty, packedPtr);

    // Extract n_values (bits 0-5)
    auto mask6 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 0x3F);
    Value nValues = rewriter.create<LLVM::AndOp>(loc, packed, mask6);

    // Load evaluator pointer at offset 16
    auto offset16 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::ClosureEvaluatorOffset);
    auto evalPtrPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, closurePtr, ValueRange{offset16});
    Value evaluator = rewriter.create<LLVM::LoadOp>(loc, ptrTy, evalPtrPtr);

    // Total args = n_values + newArgs.size()
    int64_t numNewArgs = newArgs.size();
    auto numNewArgsConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, numNewArgs);
    Value totalArgs = rewriter.create<LLVM::AddOp>(loc, nValues, numNewArgsConst);

    // Allocate args array on stack
    Value argsArray = rewriter.create<LLVM::AllocaOp>(loc, ptrTy, i64Ty, totalArgs);

    // Use scf.while to copy captured values (avoids block splitting)
    // Loop: for i in [0, nValues): argsArray[i] = captured[i]
    Value zero = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 0);

    // Create scf.while with one loop-carried variable: i : i64
    auto whileOp = rewriter.create<scf::WhileOp>(
        loc,
        /*resultTypes=*/TypeRange{i64Ty},
        /*operands=*/ValueRange{zero});

    // "before" region: condition check (i < nValues)
    {
        OpBuilder::InsertionGuard guard(rewriter);
        Block *beforeBlock = rewriter.createBlock(&whileOp.getBefore());
        beforeBlock->addArgument(i64Ty, loc);
        Value iArg = beforeBlock->getArgument(0);

        rewriter.setInsertionPointToStart(beforeBlock);
        // cond = (iArg < nValues)
        auto cond = rewriter.create<LLVM::ICmpOp>(loc, LLVM::ICmpPredicate::slt, iArg, nValues);
        // Pass iArg through as the loop-carried value
        rewriter.create<scf::ConditionOp>(loc, cond, ValueRange{iArg});
    }

    // "after" region: copy one captured value and increment i
    {
        OpBuilder::InsertionGuard guard(rewriter);
        Block *afterBlock = rewriter.createBlock(&whileOp.getAfter());
        afterBlock->addArgument(i64Ty, loc);
        Value iIter = afterBlock->getArgument(0);

        rewriter.setInsertionPointToStart(afterBlock);

        // Compute pointer to closure->values[iIter]
        auto offset24 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::ClosureValuesOffset);
        auto eight = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::PtrSize);
        auto valueOffset = rewriter.create<LLVM::MulOp>(loc, iIter, eight);
        auto totalOffset = rewriter.create<LLVM::AddOp>(loc, offset24, valueOffset);
        auto srcPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, closurePtr, ValueRange{totalOffset});
        Value capturedVal = rewriter.create<LLVM::LoadOp>(loc, i64Ty, srcPtr);

        // Compute pointer to argsArray[iIter]
        auto dstPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i64Ty, argsArray, ValueRange{iIter});
        rewriter.create<LLVM::StoreOp>(loc, capturedVal, dstPtr);

        // iNext = iIter + 1
        auto one = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 1);
        Value iNext = rewriter.create<LLVM::AddOp>(loc, iIter, one);

        // Yield new i
        rewriter.create<scf::YieldOp>(loc, ValueRange{iNext});
    }

    // Continue after the while loop (insertion point is already after whileOp)
    rewriter.setInsertionPointAfter(whileOp);

    // Copy new arguments to argsArray[nValues + j]
    for (size_t j = 0; j < newArgs.size(); ++j) {
        auto jConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, static_cast<int64_t>(j));
        auto idx = rewriter.create<LLVM::AddOp>(loc, nValues, jConst);
        auto argDstPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i64Ty, argsArray, ValueRange{idx});
        // Store directly - opaque pointers handle any 64-bit type
        rewriter.create<LLVM::StoreOp>(loc, newArgs[j], argDstPtr);
    }

    // Indirect call through evaluator: ptr(ptr) -> ptr
    auto evalFuncTy = LLVM::LLVMFunctionType::get(ptrTy, {ptrTy});
    SmallVector<Value> callOperands;
    callOperands.push_back(evaluator);
    callOperands.push_back(argsArray);
    auto indirectCallOp = rewriter.create<LLVM::CallOp>(loc, evalFuncTy, callOperands);

    // Convert ptr result to i64, then to final resultType
    Value resultI64 = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, indirectCallOp.getResult());

    Value result = resultI64;
    if (resultType == f64Ty) {
        // i64 -> f64 via bitcast
        result = rewriter.create<LLVM::BitcastOp>(loc, f64Ty, resultI64);
    } else if (isa<LLVM::LLVMPointerType>(resultType)) {
        // i64 -> ptr via inttoptr
        result = rewriter.create<LLVM::IntToPtrOp>(loc, resultType, resultI64);
    }
    // else: resultType is i64, no conversion needed

    return result;
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
            // Saturated call: emit inline closure call
            Type convertedResultTy = getTypeConverter()->convertType(op.getResult().getType());
            Value result = emitInlineClosureCall(rewriter, loc, runtime, closureI64, newargs, convertedResultTy);
            rewriter.replaceOp(op, result);
        } else {
            // Partial application: use runtime helper to create extended closure
            auto helperFunc = runtime.getOrCreatePapExtend(rewriter);

            // Build args array on stack
            auto numArgsConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, rewriter.getI64IntegerAttr(numNewArgs));
            Value argsArray = rewriter.create<LLVM::AllocaOp>(loc, ptrTy, i64Ty, numArgsConst);

            for (size_t i = 0; i < newargs.size(); ++i) {
                auto idxConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, rewriter.getI64IntegerAttr(i));
                auto slotPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i64Ty, argsArray, ValueRange{idxConst});
                Value arg = newargs[i];
                if (arg.getType() != i64Ty && isa<LLVM::LLVMPointerType>(arg.getType())) {
                    arg = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, arg);
                }
                rewriter.create<LLVM::StoreOp>(loc, arg, slotPtr);
            }

            auto numNewArgsConst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(numNewArgs));

            // Get bitmap from attribute (source-of-truth)
            uint64_t newargsBitmap = op.getNewargsUnboxedBitmap();
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
            Value result = emitInlineClosureCall(rewriter, loc, runtime, closureI64, newArgs, convertedResultTy);
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
    patterns.add<AllocateClosureOpLowering>(typeConverter, ctx, runtime);
    patterns.add<PapCreateOpLowering>(typeConverter, ctx, runtime);
    patterns.add<PapExtendOpLowering>(typeConverter, ctx, runtime);
    patterns.add<CallOpLowering>(typeConverter, ctx, runtime);
}
