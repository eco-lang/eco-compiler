//===- EcoToLLVMRuntime.cpp - Runtime function helpers for EcoToLLVM ------===//
//
// This file implements the EcoRuntime helper class and string conversion
// utilities used by the EcoToLLVM pass.
//
//===----------------------------------------------------------------------===//

#include "EcoToLLVMInternal.h"
#include "../EcoTypes.h"

using namespace mlir;
using namespace eco::detail;

//===----------------------------------------------------------------------===//
// EcoTypeConverter Implementation
//===----------------------------------------------------------------------===//

static LowerToLLVMOptions ecoLLVMOptions(MLIRContext *ctx) {
    LowerToLLVMOptions opts(ctx);
    // Eco never uses memref or bare-pointer calling convention. Setting this
    // to true makes MLIR's CallOpLowering skip the per-call O(N) symbol table
    // lookup that checks for the llvm.bareptr attribute on each callee.
    // With 92K calls × 49K functions this eliminates ~4.5B comparisons.
    opts.useBarePtrCallConv = true;
    return opts;
}

EcoTypeConverter::EcoTypeConverter(MLIRContext *ctx)
    : LLVMTypeConverter(ctx, ecoLLVMOptions(ctx)) {
    // Convert eco.value -> ptr addrspace(1) (GC-managed pointer).
    // This implements CGEN_012 for the eco.value type.
    addConversion([ctx](eco::ValueType type) {
        return LLVM::LLVMPointerType::get(ctx, /*addressSpace=*/1);
    });

    // Source materialization: create ptr<1> from !eco.value
    // This is called when converted operations need values from unconverted operations.
    // Use UnrealizedConversionCastOp which works with any types.
    addSourceMaterialization([](OpBuilder &builder, Type resultType,
                                ValueRange inputs, Location loc) -> Value {
        if (inputs.size() != 1)
            return nullptr;
        return builder.create<UnrealizedConversionCastOp>(loc, resultType, inputs).getResult(0);
    });

    // Target materialization: create !eco.value from ptr<1>
    // This is called when unconverted operations need values from converted operations.
    addTargetMaterialization([](OpBuilder &builder, Type resultType,
                                ValueRange inputs, Location loc) -> Value {
        if (inputs.size() != 1)
            return nullptr;
        return builder.create<UnrealizedConversionCastOp>(loc, resultType, inputs).getResult(0);
    });
}

//===----------------------------------------------------------------------===//
// EcoRuntime Implementation
//===----------------------------------------------------------------------===//

LLVM::LLVMFuncOp EcoRuntime::getOrCreateFunc(
    OpBuilder &builder,
    StringRef name,
    LLVM::LLVMFunctionType funcType,
    bool gcLeaf) const {

    if (auto func = lookupSymbol<LLVM::LLVMFuncOp>(name))
        return func;

    OpBuilder::InsertionGuard guard(builder);
    builder.setInsertionPointToStart(module.getBody());
    auto newFunc = builder.create<LLVM::LLVMFuncOp>(module.getLoc(), name, funcType);

    if (gcLeaf) {
        SmallVector<Attribute> attrs;
        if (auto existing = newFunc->getAttrOfType<ArrayAttr>("passthrough"))
            attrs.append(existing.begin(), existing.end());
        attrs.push_back(builder.getStringAttr("gc-leaf-function"));
        newFunc->setAttr("passthrough", builder.getArrayAttr(attrs));
    }

    // Register in cached symbol map so subsequent lookups find it in O(1)
    cacheSymbol(newFunc);
    return newFunc;
}

// Helper macros for common type patterns
#define I64_TY IntegerType::get(ctx, 64)
#define I32_TY IntegerType::get(ctx, 32)
#define I16_TY IntegerType::get(ctx, 16)
#define I8_TY IntegerType::get(ctx, 8)
#define I1_TY IntegerType::get(ctx, 1)
#define F64_TY Float64Type::get(ctx)
#define PTR_TY LLVM::LLVMPointerType::get(ctx)
#define HPTR_TY LLVM::LLVMPointerType::get(ctx, /*addressSpace=*/1)
#define VOID_TY LLVM::LLVMVoidType::get(ctx)

//===----------------------------------------------------------------------===//
// Allocation Functions
//===----------------------------------------------------------------------===//

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocInt(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I64_TY});
    return getOrCreateFunc(builder, "eco_alloc_int", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocFloat(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {F64_TY});
    return getOrCreateFunc(builder, "eco_alloc_float", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocChar(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I16_TY});
    return getOrCreateFunc(builder, "eco_alloc_char", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocCons(OpBuilder &builder) const {
    // eco_alloc_cons(head: i64, tail: hptr, head_unboxed: i32) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I64_TY, HPTR_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_alloc_cons", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocTuple2(OpBuilder &builder) const {
    // eco_alloc_tuple2(a: i64, b: i64, unboxed_mask: i32) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I64_TY, I64_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_alloc_tuple2", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocTuple3(OpBuilder &builder) const {
    // eco_alloc_tuple3(a: i64, b: i64, c: i64, unboxed_mask: i32) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I64_TY, I64_TY, I64_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_alloc_tuple3", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocRecord(OpBuilder &builder) const {
    // eco_alloc_record(field_count: i32, unboxed_bitmap: i64) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I32_TY, I64_TY});
    return getOrCreateFunc(builder, "eco_alloc_record", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocCustom(OpBuilder &builder) const {
    // eco_alloc_custom(ctor_id: i32, field_count: i32, scalar_bytes: i32) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I32_TY, I32_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_alloc_custom", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocString(OpBuilder &builder) const {
    // eco_alloc_string(length: i32) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I32_TY});
    return getOrCreateFunc(builder, "eco_alloc_string", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocStringLiteral(OpBuilder &builder) const {
    // eco_alloc_string_literal(chars: ptr, length: i32) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {PTR_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_alloc_string_literal", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocClosure(OpBuilder &builder) const {
    // eco_alloc_closure(func_ptr: ptr, num_captures: i32) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {PTR_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_alloc_closure", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocClosureK(OpBuilder &builder) const {
    // eco_alloc_closure_k(func_ptr: ptr, num_captures: i32, result_kind: i8) -> hptr
    auto i8Ty = IntegerType::get(builder.getContext(), 8);
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {PTR_TY, I32_TY, i8Ty});
    return getOrCreateFunc(builder, "eco_alloc_closure_k", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocate(OpBuilder &builder) const {
    // eco_allocate(size: i64, tag: i32) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I64_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_allocate", funcTy);
}

//===----------------------------------------------------------------------===//
// Fast Allocation Functions (bump-pointer only, no GC, return 0 on failure)
//===----------------------------------------------------------------------===//

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocIntFast(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I64_TY});
    return getOrCreateFunc(builder, "eco_alloc_int_fast", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocFloatFast(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {F64_TY});
    return getOrCreateFunc(builder, "eco_alloc_float_fast", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocCharFast(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I16_TY});
    return getOrCreateFunc(builder, "eco_alloc_char_fast", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocConsFast(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I64_TY, HPTR_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_alloc_cons_fast", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocTuple2Fast(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I64_TY, I64_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_alloc_tuple2_fast", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocTuple3Fast(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I64_TY, I64_TY, I64_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_alloc_tuple3_fast", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocRecordFast(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I32_TY, I64_TY});
    return getOrCreateFunc(builder, "eco_alloc_record_fast", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocCustomFast(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I32_TY, I32_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_alloc_custom_fast", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocStringFast(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I32_TY});
    return getOrCreateFunc(builder, "eco_alloc_string_fast", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocClosureFast(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {PTR_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_alloc_closure_fast", funcTy, /*gcLeaf=*/true);
}

//===----------------------------------------------------------------------===//
// Slow Allocation Functions (may GC — used behind statepoint)
//===----------------------------------------------------------------------===//

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocIntSlow(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I64_TY});
    return getOrCreateFunc(builder, "eco_alloc_int_slow", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocFloatSlow(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {F64_TY});
    return getOrCreateFunc(builder, "eco_alloc_float_slow", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocCharSlow(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I16_TY});
    return getOrCreateFunc(builder, "eco_alloc_char_slow", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocConsSlow(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I64_TY, HPTR_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_alloc_cons_slow", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocTuple2Slow(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I64_TY, I64_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_alloc_tuple2_slow", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocTuple3Slow(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I64_TY, I64_TY, I64_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_alloc_tuple3_slow", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocRecordSlow(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I32_TY, I64_TY});
    return getOrCreateFunc(builder, "eco_alloc_record_slow", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocCustomSlow(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I32_TY, I32_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_alloc_custom_slow", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocStringSlow(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I32_TY});
    return getOrCreateFunc(builder, "eco_alloc_string_slow", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocClosureSlow(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {PTR_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_alloc_closure_slow", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocClosureGroupSlow(OpBuilder &builder) const {
    // eco_alloc_closure_group_slow(
    //   numSiblings: i64,
    //   evaluators: ptr, arities: ptr, numCaptured: ptr,
    //   unboxedBitmaps: ptr, resultKinds: ptr, captureOffsets: ptr,
    //   captures: ptr, crossEdges: ptr, numCrossEdges: i64,
    //   outClosures: ptr
    // ) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(
        LLVM::LLVMVoidType::get(builder.getContext()),
        {I64_TY, PTR_TY, PTR_TY, PTR_TY, PTR_TY, PTR_TY, PTR_TY, PTR_TY, PTR_TY, I64_TY, PTR_TY});
    return getOrCreateFunc(builder, "eco_alloc_closure_group_slow", funcTy);
}

//===----------------------------------------------------------------------===//
// Region Allocation Functions
//===----------------------------------------------------------------------===//

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocRegionFast(OpBuilder &builder) const {
    // eco_gc_alloc_region_fast(total: i64) -> ptr (nullptr on failure)
    auto funcTy = LLVM::LLVMFunctionType::get(PTR_TY, {I64_TY});
    return getOrCreateFunc(builder, "eco_gc_alloc_region_fast", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocRegionSlow(OpBuilder &builder) const {
    // eco_gc_alloc_region_slow(total: i64) -> ptr
    auto funcTy = LLVM::LLVMFunctionType::get(PTR_TY, {I64_TY});
    return getOrCreateFunc(builder, "eco_gc_alloc_region_slow", funcTy);
}

//===----------------------------------------------------------------------===//
// Init-at-pointer Functions (for group allocation)
//===----------------------------------------------------------------------===//

LLVM::LLVMFuncOp EcoRuntime::getOrCreateInitIntAt(OpBuilder &builder) const {
    // eco_init_int_at(ptr, value: i64) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {PTR_TY, I64_TY});
    return getOrCreateFunc(builder, "eco_init_int_at", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateInitFloatAt(OpBuilder &builder) const {
    // eco_init_float_at(ptr, value: f64) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {PTR_TY, F64_TY});
    return getOrCreateFunc(builder, "eco_init_float_at", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateInitCharAt(OpBuilder &builder) const {
    // eco_init_char_at(ptr, value: i32) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {PTR_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_init_char_at", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateInitConsAt(OpBuilder &builder) const {
    // eco_init_cons_at(ptr, head: i64, tail: hptr, head_unboxed: i32) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {PTR_TY, I64_TY, HPTR_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_init_cons_at", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateInitTuple2At(OpBuilder &builder) const {
    // eco_init_tuple2_at(ptr, a: i64, b: i64, unboxed: i32) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {PTR_TY, I64_TY, I64_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_init_tuple2_at", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateInitTuple3At(OpBuilder &builder) const {
    // eco_init_tuple3_at(ptr, a: i64, b: i64, c: i64, unboxed: i32) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {PTR_TY, I64_TY, I64_TY, I64_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_init_tuple3_at", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateInitRecordAt(OpBuilder &builder) const {
    // eco_init_record_at(ptr, field_count: i32, unboxed_bitmap: i64) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {PTR_TY, I32_TY, I64_TY});
    return getOrCreateFunc(builder, "eco_init_record_at", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateInitCustomAt(OpBuilder &builder) const {
    // eco_init_custom_at(ptr, ctor_id: i32, field_count: i32, scalar_bytes: i32) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {PTR_TY, I32_TY, I32_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_init_custom_at", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateInitStringAt(OpBuilder &builder) const {
    // eco_init_string_at(ptr, length: i32) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {PTR_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_init_string_at", funcTy, /*gcLeaf=*/true);
}

//===----------------------------------------------------------------------===//
// Field Storage Functions
//===----------------------------------------------------------------------===//

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStoreField(OpBuilder &builder) const {
    // eco_store_field(obj_hptr: hptr, index: i32, value: hptr) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {HPTR_TY, I32_TY, HPTR_TY});
    return getOrCreateFunc(builder, "eco_store_field", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStoreFieldI64(OpBuilder &builder) const {
    // eco_store_field_i64(obj_hptr: hptr, index: i32, value: i64) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {HPTR_TY, I32_TY, I64_TY});
    return getOrCreateFunc(builder, "eco_store_field_i64", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStoreFieldF64(OpBuilder &builder) const {
    // eco_store_field_f64(obj_hptr: hptr, index: i32, value: f64) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {HPTR_TY, I32_TY, F64_TY});
    return getOrCreateFunc(builder, "eco_store_field_f64", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStoreRecordField(OpBuilder &builder) const {
    // eco_store_record_field(record_hptr: hptr, index: i32, value: hptr) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {HPTR_TY, I32_TY, HPTR_TY});
    return getOrCreateFunc(builder, "eco_store_record_field", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStoreRecordFieldI64(OpBuilder &builder) const {
    // eco_store_record_field_i64(record_hptr: hptr, index: i32, value: i64) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {HPTR_TY, I32_TY, I64_TY});
    return getOrCreateFunc(builder, "eco_store_record_field_i64", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStoreRecordFieldF64(OpBuilder &builder) const {
    // eco_store_record_field_f64(record_hptr: hptr, index: i32, value: f64) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {HPTR_TY, I32_TY, F64_TY});
    return getOrCreateFunc(builder, "eco_store_record_field_f64", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateSetUnboxed(OpBuilder &builder) const {
    // eco_set_unboxed(obj_hptr: hptr, bitmap: i64) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {HPTR_TY, I64_TY});
    return getOrCreateFunc(builder, "eco_set_unboxed", funcTy, /*gcLeaf=*/true);
}

//===----------------------------------------------------------------------===//
// Closure Functions
//===----------------------------------------------------------------------===//

LLVM::LLVMFuncOp EcoRuntime::getOrCreatePapExtend(OpBuilder &builder) const {
    // eco_pap_extend(closure_hptr: hptr, args: ptr, num_args: i32, new_unboxed_bitmap: i64) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {HPTR_TY, PTR_TY, I32_TY, I64_TY});
    return getOrCreateFunc(builder, "eco_pap_extend", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateClosureCallSaturated(OpBuilder &builder) const {
    // eco_closure_call_saturated(closure_hptr: hptr, new_args: ptr, num_newargs: i32, layout: ptr) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {HPTR_TY, PTR_TY, I32_TY, PTR_TY});
    return getOrCreateFunc(builder, "eco_closure_call_saturated", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateApplyClosure(OpBuilder &builder) const {
    // eco_apply_closure(closure_hptr: hptr, args: ptr, num_args: i32) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {HPTR_TY, PTR_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_apply_closure", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateApplyClosureTyped(OpBuilder &builder) const {
    // eco_apply_closure_typed(closure_hptr: hptr, typed_args: ptr, num_args: i32, args_layout: ptr) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {HPTR_TY, PTR_TY, I32_TY, PTR_TY});
    return getOrCreateFunc(builder, "eco_apply_closure_typed", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateApplyClosureEval(OpBuilder &builder) const {
    // eco_apply_closure_eval(closure_hptr: hptr, typed_args: ptr, num_args: i32,
    //                        args_layout: ptr, result_slot: ptr, desired_kind: i8) -> void
    auto *ctx = builder.getContext();
    auto i8Ty = IntegerType::get(ctx, 8);
    auto voidTy = LLVM::LLVMVoidType::get(ctx);
    auto funcTy = LLVM::LLVMFunctionType::get(voidTy,
        {HPTR_TY, PTR_TY, I32_TY, PTR_TY, PTR_TY, i8Ty});
    return getOrCreateFunc(builder, "eco_apply_closure_eval", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateApplySegmentationUnknown(OpBuilder &builder) const {
    // eco_apply_segmentation_unknown(closure: hptr, typed_args: ptr, num_args: i32,
    //                                args_layout: ptr) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {HPTR_TY, PTR_TY, I32_TY, PTR_TY});
    return getOrCreateFunc(builder, "eco_apply_segmentation_unknown", funcTy);
}

//===----------------------------------------------------------------------===//
// Utility Functions
//===----------------------------------------------------------------------===//

LLVM::LLVMFuncOp EcoRuntime::getOrCreateResolveHPtr(OpBuilder &builder) const {
    // eco_resolve_hptr(hptr: hptr) -> ptr
    auto funcTy = LLVM::LLVMFunctionType::get(PTR_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_resolve_hptr", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateGetTag(OpBuilder &builder) const {
    // eco_get_tag(value: hptr) -> i32
    auto funcTy = LLVM::LLVMFunctionType::get(I32_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_get_tag", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateConsHeadI64(OpBuilder &builder) const {
    // eco_cons_head_i64(cons: hptr) -> i64
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_cons_head_i64", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateConsHeadF64(OpBuilder &builder) const {
    // eco_cons_head_f64(cons: hptr) -> f64
    auto f64Ty = Float64Type::get(ctx);
    auto funcTy = LLVM::LLVMFunctionType::get(f64Ty, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_cons_head_f64", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateConsHeadI16(OpBuilder &builder) const {
    // eco_cons_head_i16(cons: hptr) -> i16
    auto i16Ty = IntegerType::get(ctx, 16);
    auto funcTy = LLVM::LLVMFunctionType::get(i16Ty, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_cons_head_i16", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateCrash(OpBuilder &builder) const {
    // eco_crash(message_val: hptr) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_crash", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateGcAddRoot(OpBuilder &builder) const {
    // eco_gc_add_root(ptr: ptr) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {PTR_TY});
    return getOrCreateFunc(builder, "eco_gc_add_root", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateGcStackRangePoint(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {});
    return getOrCreateFunc(builder, "eco_gc_stack_range_point", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateGcPushStackRange(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {PTR_TY, I64_TY, I64_TY});
    return getOrCreateFunc(builder, "eco_gc_push_stack_range", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateGcRestoreStackRangePoint(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {I64_TY});
    return getOrCreateFunc(builder, "eco_gc_restore_stack_range_point", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateRegisterTypeGraph(OpBuilder &builder) const {
    // eco_register_type_graph(graph: ptr) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {PTR_TY});
    return getOrCreateFunc(builder, "eco_register_type_graph", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateIntPow(OpBuilder &builder) const {
    // eco_int_pow(base: i64, exp: i64) -> i64
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {I64_TY, I64_TY});
    return getOrCreateFunc(builder, "eco_int_pow", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateUtilsEqual(OpBuilder &builder) const {
    // Elm_Kernel_Utils_equal(a: hptr, b: hptr) -> hptr (boxed Bool)
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {HPTR_TY, HPTR_TY});
    return getOrCreateFunc(builder, "Elm_Kernel_Utils_equal", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateGetOrderLT(OpBuilder &builder) const {
    // Eco_Runtime_getOrderLT() -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {});
    return getOrCreateFunc(builder, "Eco_Runtime_getOrderLT", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateGetOrderEQ(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {});
    return getOrCreateFunc(builder, "Eco_Runtime_getOrderEQ", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateGetOrderGT(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {});
    return getOrCreateFunc(builder, "Eco_Runtime_getOrderGT", funcTy, /*gcLeaf=*/true);
}

//===----------------------------------------------------------------------===//
// Array Functions
//===----------------------------------------------------------------------===//

LLVM::LLVMFuncOp EcoRuntime::getOrCreateCloneArray(OpBuilder &builder) const {
    // eco_clone_array(array_hptr: hptr) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_clone_array", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateArraySetFixKind(OpBuilder &builder) const {
    // eco_array_set_fix_kind(array_hptr: hptr, intended_kind: i32) -> void
    auto i32Ty = mlir::IntegerType::get(builder.getContext(), 32);
    auto voidTy = LLVM::LLVMVoidType::get(builder.getContext());
    auto funcTy = LLVM::LLVMFunctionType::get(voidTy, {HPTR_TY, i32Ty});
    return getOrCreateFunc(builder, "eco_array_set_fix_kind", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStringFromInt(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I64_TY});
    return getOrCreateFunc(builder, "elm_string_from_int", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStringFromDouble(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {F64_TY});
    return getOrCreateFunc(builder, "elm_string_from_double", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateArrayEmpty(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {});
    return getOrCreateFunc(builder, "elm_array_empty", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateArraySingletonInt(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I64_TY});
    return getOrCreateFunc(builder, "elm_array_singleton_int", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateArraySingletonFloat(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {F64_TY});
    return getOrCreateFunc(builder, "elm_array_singleton_float", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateArraySingletonChar(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I16_TY});
    return getOrCreateFunc(builder, "elm_array_singleton_char", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateArraySingletonBox(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "elm_array_singleton_box", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateArrayPushInt(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I64_TY, HPTR_TY});
    return getOrCreateFunc(builder, "elm_array_push_int", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateArrayPushFloat(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {F64_TY, HPTR_TY});
    return getOrCreateFunc(builder, "elm_array_push_float", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateArrayPushChar(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I16_TY, HPTR_TY});
    return getOrCreateFunc(builder, "elm_array_push_char", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateArrayPushBox(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {HPTR_TY, HPTR_TY});
    return getOrCreateFunc(builder, "elm_array_push_box", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateArraySlice(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I64_TY, I64_TY, HPTR_TY});
    return getOrCreateFunc(builder, "elm_array_slice", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateArrayAppendN(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I64_TY, HPTR_TY, HPTR_TY});
    return getOrCreateFunc(builder, "elm_array_append_n", funcTy);
}

//===----------------------------------------------------------------------===//
// Debug Functions
//===----------------------------------------------------------------------===//

LLVM::LLVMFuncOp EcoRuntime::getOrCreateDbgPrint(OpBuilder &builder) const {
    // eco_dbg_print(values: ptr, count: i32) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {PTR_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_dbg_print", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateDbgPrintInt(OpBuilder &builder) const {
    // eco_dbg_print_int(value: i64) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {I64_TY});
    return getOrCreateFunc(builder, "eco_dbg_print_int", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateDbgPrintFloat(OpBuilder &builder) const {
    // eco_dbg_print_float(value: f64) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {F64_TY});
    return getOrCreateFunc(builder, "eco_dbg_print_float", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateDbgPrintChar(OpBuilder &builder) const {
    // eco_dbg_print_char(value: i16) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {I16_TY});
    return getOrCreateFunc(builder, "eco_dbg_print_char", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateDbgPrintTyped(OpBuilder &builder) const {
    // eco_dbg_print_typed(values: ptr, type_ids: ptr, num_args: i32) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {PTR_TY, PTR_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_dbg_print_typed", funcTy, /*gcLeaf=*/true);
}

//===----------------------------------------------------------------------===//
// Libc Math Functions
//===----------------------------------------------------------------------===//

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAsin(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(F64_TY, {F64_TY});
    return getOrCreateFunc(builder, "asin", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAcos(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(F64_TY, {F64_TY});
    return getOrCreateFunc(builder, "acos", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAtan(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(F64_TY, {F64_TY});
    return getOrCreateFunc(builder, "atan", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAtan2(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(F64_TY, {F64_TY, F64_TY});
    return getOrCreateFunc(builder, "atan2", funcTy, /*gcLeaf=*/true);
}

#undef I64_TY
#undef I32_TY
#undef I16_TY
#undef I8_TY
#undef F64_TY
#undef PTR_TY
#undef HPTR_TY
#undef VOID_TY

//===----------------------------------------------------------------------===//
// Allocation with Safepoint
//===----------------------------------------------------------------------===//

Value eco::detail::emitAllocWithSafepoint(
    Operation *op,
    ConversionPatternRewriter &rewriter,
    const EcoRuntime &runtime,
    LLVM::LLVMFuncOp allocFunc,
    ValueRange args,
    ValueRange liveRoots) {

    auto loc = op->getLoc();

    // RS4GC handles safepoint insertion automatically — no marker needed.
    // Just emit the allocation call directly.
    auto allocCall = rewriter.create<LLVM::CallOp>(loc, allocFunc, args);
    return allocCall.getResult();
}

//===----------------------------------------------------------------------===//
// Safepoint Marker (for call-like safepoints)
//===----------------------------------------------------------------------===//

void eco::detail::emitSafepointMarker(
    Operation *op,
    ConversionPatternRewriter &rewriter,
    const EcoRuntime &runtime,
    ValueRange liveRoots) {
    // RS4GC handles safepoint insertion automatically — no marker needed.
}

//===----------------------------------------------------------------------===//
// Wrapper Safepoint Marker (for closure wrapper bodies)
//===----------------------------------------------------------------------===//

void eco::detail::emitWrapperSafepointMarker(
    OpBuilder &builder,
    const EcoRuntime &runtime,
    Location loc,
    ValueRange liveRoots) {
    // RS4GC handles safepoint insertion automatically — no marker needed.
}

//===----------------------------------------------------------------------===//
// String Conversion Utilities
//===----------------------------------------------------------------------===//

std::vector<uint16_t> eco::detail::utf8ToUtf16(StringRef utf8) {
    std::vector<uint16_t> result;
    result.reserve(utf8.size());

    const char *ptr = utf8.data();
    const char *end = ptr + utf8.size();

    while (ptr < end) {
        uint32_t codepoint;
        unsigned char c = *ptr++;

        if ((c & 0x80) == 0) {
            // Single-byte ASCII character.
            codepoint = c;
        } else if ((c & 0xE0) == 0xC0) {
            // 2-byte UTF-8 sequence.
            codepoint = (c & 0x1F) << 6;
            if (ptr < end) codepoint |= (*ptr++ & 0x3F);
        } else if ((c & 0xF0) == 0xE0) {
            // 3-byte UTF-8 sequence.
            codepoint = (c & 0x0F) << 12;
            if (ptr < end) codepoint |= (*ptr++ & 0x3F) << 6;
            if (ptr < end) codepoint |= (*ptr++ & 0x3F);
        } else if ((c & 0xF8) == 0xF0) {
            // 4-byte UTF-8 sequence (requires surrogate pair in UTF-16).
            codepoint = (c & 0x07) << 18;
            if (ptr < end) codepoint |= (*ptr++ & 0x3F) << 12;
            if (ptr < end) codepoint |= (*ptr++ & 0x3F) << 6;
            if (ptr < end) codepoint |= (*ptr++ & 0x3F);
        } else {
            // Invalid UTF-8 sequence, use Unicode replacement character.
            codepoint = 0xFFFD;
        }

        // Encode codepoint as UTF-16.
        if (codepoint <= 0xFFFF) {
            result.push_back(static_cast<uint16_t>(codepoint));
        } else {
            // Encode as UTF-16 surrogate pair.
            codepoint -= 0x10000;
            result.push_back(static_cast<uint16_t>(0xD800 + (codepoint >> 10)));
            result.push_back(static_cast<uint16_t>(0xDC00 + (codepoint & 0x3FF)));
        }
    }

    return result;
}
