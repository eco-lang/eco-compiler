//===- EcoToLLVMRuntime.cpp - Runtime function helpers for EcoToLLVM ------===//
//
// This file implements the EcoRuntime helper class and string conversion
// utilities used by the EcoToLLVM pass.
//
//===----------------------------------------------------------------------===//

#include "EcoToLLVMInternal.h"
#include "../EcoTypes.h"
#include "../BF/BFTypes.h"

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

    // Phase 0 plumbing: convert each value-level aggregate type to an
    // LLVM literal struct of its converted element types. The "value
    // layout" intentionally does NOT mirror the heap layout — boundary
    // ops (eco.to_heap, eco.make.closure) translate explicitly. (REP_AGG_001)
    auto convertElements = [this](ArrayRef<Type> elements,
                                  SmallVectorImpl<Type> &out) -> bool {
        out.reserve(elements.size());
        for (Type t : elements) {
            Type converted = convertType(t);
            if (!converted) return false;
            out.push_back(converted);
        }
        return true;
    };

    addConversion([ctx, convertElements](eco::Tuple2Type type) -> Type {
        SmallVector<Type, 2> body;
        Type elts[2] = { type.getFirst(), type.getSecond() };
        if (!convertElements(elts, body)) return Type();
        return LLVM::LLVMStructType::getLiteral(ctx, body);
    });
    addConversion([ctx, convertElements](eco::Tuple3Type type) -> Type {
        SmallVector<Type, 3> body;
        Type elts[3] = { type.getFirst(), type.getSecond(), type.getThird() };
        if (!convertElements(elts, body)) return Type();
        return LLVM::LLVMStructType::getLiteral(ctx, body);
    });
    addConversion([ctx, convertElements](eco::RecordType type) -> Type {
        SmallVector<Type, 8> body;
        if (!convertElements(type.getFields(), body)) return Type();
        return LLVM::LLVMStructType::getLiteral(ctx, body);
    });
    addConversion([ctx, convertElements](eco::CustomType type) -> Type {
        SmallVector<Type, 8> body;
        if (!convertElements(type.getFields(), body)) return Type();
        return LLVM::LLVMStructType::getLiteral(ctx, body);
    });
    addConversion([ctx, convertElements](eco::ConsType type) -> Type {
        SmallVector<Type, 2> body;
        Type elts[2] = { type.getHead(), type.getTail() };
        if (!convertElements(elts, body)) return Type();
        return LLVM::LLVMStructType::getLiteral(ctx, body);
    });
    addConversion([ctx, convertElements](eco::ClosureEnvType type) -> Type {
        SmallVector<Type, 8> body;
        if (!convertElements(type.getCaptures(), body)) return Type();
        return LLVM::LLVMStructType::getLiteral(ctx, body);
    });

    // !bf.cursor lives at the scf.while boundary of fused encoder loops
    // (e.g. `BE.sequence (length :: List.map fn xs)`). BFToLLVM lowers
    // its own bf.* ops first, but doesn't walk into scf regions to
    // rewrite the iter_arg types; the structural SCF type conversion
    // populated below (line ~294) then needs this entry to legalise the
    // remaining scf.while. Mirror BFTypeConverter's lowering: a pair of
    // raw pointers (current, end).
    addConversion([ctx](bf::CursorType) -> Type {
        auto ptrType = LLVM::LLVMPointerType::get(ctx);
        return LLVM::LLVMStructType::getLiteral(ctx, { ptrType, ptrType });
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

    // Lock-free HIT: all runtime decls are pre-declared by
    // materializeAllRuntimeDecls before freeze(), so during parallel Stage 2
    // every call hits the read-only symCache. A miss may only legitimately
    // happen in the serial phases; a miss while frozen means a decl escaped the
    // pre-declaration (parallel-conversion UB) — the assert pins it.
    if (auto func = lookupSymbol<LLVM::LLVMFuncOp>(name))
        return func;
    assert(!frozen &&
           "getOrCreateFunc miss after freeze(): a runtime decl was not "
           "pre-declared by materializeAllRuntimeDecls (parallel UB)");

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
    if (auto nameAttr = newFunc->getAttrOfType<mlir::StringAttr>(
            mlir::SymbolTable::getSymbolAttrName()))
        symCache[nameAttr] = newFunc;
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

LLVM::LLVMFuncOp
EcoRuntime::getOrCreateAllocStringLiteralUtf8(OpBuilder &builder) const {
    // eco_alloc_string_literal_utf8(bytes: ptr, byteLen: i32) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {PTR_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_alloc_string_literal_utf8", funcTy);
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

LLVM::LLVMFuncOp EcoRuntime::getOrCreateInternClosure0(OpBuilder &builder) const {
    // eco_intern_closure0(func_ptr: ptr, arity: i32, packed: i64) -> hptr
    // (H4.2: interned permanent singleton for a zero-capture papCreate)
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {PTR_TY, I32_TY, I64_TY});
    return getOrCreateFunc(builder, "eco_intern_closure0", funcTy);
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
// Uninit Allocators + Field Stores (forward ABI; not yet exercised).
//===----------------------------------------------------------------------===//

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocTuple2Uninit(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I32_TY});
    return getOrCreateFunc(builder, "eco_alloc_tuple2_uninit", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocTuple3Uninit(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I32_TY});
    return getOrCreateFunc(builder, "eco_alloc_tuple3_uninit", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocConsUninit(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I32_TY});
    return getOrCreateFunc(builder, "eco_alloc_cons_uninit", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStoreTupleField(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {HPTR_TY, I32_TY, HPTR_TY});
    return getOrCreateFunc(builder, "eco_store_tuple_field", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStoreTupleFieldI64(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {HPTR_TY, I32_TY, I64_TY});
    return getOrCreateFunc(builder, "eco_store_tuple_field_i64", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStoreTupleFieldF64(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {HPTR_TY, I32_TY, F64_TY});
    return getOrCreateFunc(builder, "eco_store_tuple_field_f64", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStoreConsHead(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {HPTR_TY, HPTR_TY});
    return getOrCreateFunc(builder, "eco_store_cons_head", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStoreConsHeadI64(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {HPTR_TY, I64_TY});
    return getOrCreateFunc(builder, "eco_store_cons_head_i64", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStoreConsHeadF64(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {HPTR_TY, F64_TY});
    return getOrCreateFunc(builder, "eco_store_cons_head_f64", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStoreConsTail(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {HPTR_TY, HPTR_TY});
    return getOrCreateFunc(builder, "eco_store_cons_tail", funcTy, /*gcLeaf=*/true);
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

LLVM::LLVMFuncOp EcoRuntime::getOrCreateClosureCallSaturatedEval(OpBuilder &builder) const {
    // eco_closure_call_saturated_eval(closure: hptr, new_args: ptr, num_newargs: i32,
    //                                  layout: ptr, result_slot: ptr, desired_kind: i8) -> void
    auto *ctx = builder.getContext();
    auto i8Ty = IntegerType::get(ctx, 8);
    auto voidTy = LLVM::LLVMVoidType::get(ctx);
    auto funcTy = LLVM::LLVMFunctionType::get(voidTy,
        {HPTR_TY, PTR_TY, I32_TY, PTR_TY, PTR_TY, i8Ty});
    return getOrCreateFunc(builder, "eco_closure_call_saturated_eval", funcTy);
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

LLVM::LLVMFuncOp EcoRuntime::getOrCreateResolveFwdMarker(OpBuilder &builder) const {
    auto *ctx = builder.getContext();
    // __eco_resolve_fwd(ptr as1) -> ptr as1. gc-leaf so RS4GC inserts no
    // statepoint; expanded inline (fast/slow forwarding-check) by
    // ExpandInlineDeref before RS4GC ever runs, so it never reaches codegen.
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "__eco_resolve_fwd", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateFollowForward(OpBuilder &builder) const {
    auto *ctx = builder.getContext();
    // eco_follow_forward(ptr as1) -> ptr as1. gc-leaf cold slow path.
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_follow_forward", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateGetTag(OpBuilder &builder) const {
    // eco_get_tag(value: hptr) -> i32
    auto funcTy = LLVM::LLVMFunctionType::get(I32_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_get_tag", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocInlineMarker(OpBuilder &builder) const {
    // __eco_alloc_inline(size: i64) -> ptr as1. Inline nursery allocation
    // marker (plans/inline-nursery-allocation.md, HEAP_034): gc-leaf,
    // declare-only; expanded to the bump-pointer fast/slow diamond by
    // expandInlineAllocs (EcoBackend.cpp) before every RS4GC flavour and
    // before partition splitting, so it never reaches codegen. The size
    // operand MUST be a compile-time constant (8-aligned, <= 4096) — the
    // expansion asserts it.
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I64_TY});
    return getOrCreateFunc(builder, "__eco_alloc_inline", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateGetTagInlineMarker(OpBuilder &builder) const {
    // __eco_get_tag_inline(hptr) -> i32 ctor tag. P2.5 R1b marker
    // (plans/allocator-resolve-inlining.md): gc-leaf, declare-only; expanded
    // to the open-coded embedded-constant / Tag_Cons / Tag_Custom tag
    // diamond by expandGetTagMarkers (EcoBackend.cpp) before
    // ExpandInlineDeref + every RS4GC flavour, so it never reaches codegen.
    auto funcTy = LLVM::LLVMFunctionType::get(I32_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "__eco_get_tag_inline", funcTy, /*gcLeaf=*/true);
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

// Chunked-list projection MARKERS (plans/chunked-list-representation.md §6):
// gc-leaf, declare-only; expanded to the cell-fast / chunk-slow diamond by
// expandListProjMarkers (EcoBackend.cpp) before ExpandInlineDeref + every
// RS4GC flavour, so they never reach codegen — the __eco_get_tag_inline
// architecture. The tail marker's expanded slow path (eco_list_tail_hybrid)
// is the allocating, statepointed edge.
LLVM::LLVMFuncOp EcoRuntime::getOrCreateListHeadInlineMarker(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "__eco_list_head_inline", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateListTailInlineMarker(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "__eco_list_tail_inline", funcTy, /*gcLeaf=*/true);
}

// Hybrid-spine (chunked-list) projections, used when the module carries the
// eco.list_chunks attribute (plans/chunked-list-representation.md §6).
LLVM::LLVMFuncOp EcoRuntime::getOrCreateListHeadHybrid(OpBuilder &builder) const {
    // eco_list_head_hybrid(list: hptr) -> hptr (raw slot bits; gc-leaf)
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_list_head_hybrid", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateListTailHybrid(OpBuilder &builder) const {
    // eco_list_tail_hybrid(list: hptr) -> hptr — may allocate a successor
    // view, so NOT gc-leaf (RS4GC statepoints the call site).
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_list_tail_hybrid", funcTy, /*gcLeaf=*/false);
}

// Tuple2 unboxed-primitive field accessors. See plans/projection-helpers-everywhere.md.
LLVM::LLVMFuncOp EcoRuntime::getOrCreateTuple2Get0I64(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_tuple2_get0_i64", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateTuple2Get1I64(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_tuple2_get1_i64", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateTuple2Get0F64(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(F64_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_tuple2_get0_f64", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateTuple2Get1F64(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(F64_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_tuple2_get1_f64", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateTuple2Get0I16(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(I16_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_tuple2_get0_i16", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateTuple2Get1I16(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(I16_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_tuple2_get1_i16", funcTy, /*gcLeaf=*/true);
}

// Tuple3 unboxed-primitive field accessors.
LLVM::LLVMFuncOp EcoRuntime::getOrCreateTuple3Get0I64(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_tuple3_get0_i64", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateTuple3Get1I64(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_tuple3_get1_i64", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateTuple3Get2I64(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_tuple3_get2_i64", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateTuple3Get0F64(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(F64_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_tuple3_get0_f64", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateTuple3Get1F64(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(F64_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_tuple3_get1_f64", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateTuple3Get2F64(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(F64_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_tuple3_get2_f64", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateTuple3Get0I16(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(I16_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_tuple3_get0_i16", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateTuple3Get1I16(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(I16_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_tuple3_get1_i16", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateTuple3Get2I16(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(I16_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_tuple3_get2_i16", funcTy, /*gcLeaf=*/true);
}

// Record unboxed-primitive field accessors.
LLVM::LLVMFuncOp EcoRuntime::getOrCreateRecordGetI64(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {HPTR_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_record_get_i64", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateRecordGetF64(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(F64_TY, {HPTR_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_record_get_f64", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateRecordGetI16(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(I16_TY, {HPTR_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_record_get_i16", funcTy, /*gcLeaf=*/true);
}

// Custom unboxed-primitive field accessors.
LLVM::LLVMFuncOp EcoRuntime::getOrCreateCustomGetI64(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {HPTR_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_custom_get_i64", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateCustomGetF64(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(F64_TY, {HPTR_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_custom_get_f64", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateCustomGetI16(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(I16_TY, {HPTR_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_custom_get_i16", funcTy, /*gcLeaf=*/true);
}

// Array unboxed-primitive element accessors. Index is i64 to mirror the
// Eco_Int SSA operand on eco.array.get.
LLVM::LLVMFuncOp EcoRuntime::getOrCreateArrayGetI64(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {HPTR_TY, I64_TY});
    return getOrCreateFunc(builder, "eco_array_get_i64", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateArrayGetF64(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(F64_TY, {HPTR_TY, I64_TY});
    return getOrCreateFunc(builder, "eco_array_get_f64", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateArrayGetI16(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(I16_TY, {HPTR_TY, I64_TY});
    return getOrCreateFunc(builder, "eco_array_get_i16", funcTy, /*gcLeaf=*/true);
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

LLVM::LLVMFuncOp EcoRuntime::getOrCreateDispatchStatsFast(OpBuilder &builder) const {
    // eco_dispatch_stats_fast(evaluator_fp: ptr) -> void  (LSS plan E0.4)
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {PTR_TY});
    return getOrCreateFunc(builder, "eco_dispatch_stats_fast", funcTy, /*gcLeaf=*/true);
}

// Fold-proof slot-cast barriers (REP_LLVM_002,
// plans/fold-proof-boxed-slot-crossings.md): declare-only; every call is
// rewritten back to a bare inttoptr/ptrtoint by StripEcoCastBarriers
// strictly post-RS4GC, so no definition ever exists and no call survives to
// codegen. Attrs are gc-leaf ONLY — do NOT add memory(none)/speculatable/
// willreturn: motion-enabling attributes would let a pre-RS4GC pass move the
// call across a statepoint, recreating exactly the raw-i64 crossing the
// barrier exists to prevent.
LLVM::LLVMFuncOp EcoRuntime::getOrCreateSlotToHPtr(OpBuilder &builder) const {
    // __eco_slot_to_hptr(slot_word: i64) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I64_TY});
    return getOrCreateFunc(builder, kSlotToHPtrSym, funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateHPtrToSlot(OpBuilder &builder) const {
    // __eco_hptr_to_slot(v: hptr) -> i64 slot word
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {HPTR_TY});
    return getOrCreateFunc(builder, kHPtrToSlotSym, funcTy, /*gcLeaf=*/true);
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

LLVM::LLVMFuncOp EcoRuntime::getOrCreateOrderFromSign(OpBuilder &builder) const {
    // eco_order_from_sign(sign: i64) -> hptr (one of the three Order singletons)
    // gc-leaf: three loads from value-rooted slots, no GC inside.
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I64_TY});
    return getOrCreateFunc(builder, "eco_order_from_sign", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStringCmp3(OpBuilder &builder) const {
    // eco_string_cmp3(a: hptr, b: hptr) -> i64 (UNCLAMPED sign)
    // gc-leaf: StringOps::compare never allocates on the GC heap.
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {HPTR_TY, HPTR_TY});
    return getOrCreateFunc(builder, "eco_string_cmp3", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStringCmpOrder(OpBuilder &builder) const {
    // eco_string_cmp_order(a: hptr, b: hptr) -> hptr (Order singleton)
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {HPTR_TY, HPTR_TY});
    return getOrCreateFunc(builder, "eco_string_cmp_order", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStringLenInlineMarker(OpBuilder &b) const {
    // __eco_string_len_inline(ptr as1) -> i64. kernel-opt-04 marker: gc-leaf,
    // declare-only; expanded to the embedded-constant / header-load diamond by
    // expandStringLenMarkers (EcoBackend.cpp) before every RS4GC flavour and
    // before partition splitting, so it never reaches codegen.
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {HPTR_TY});
    return getOrCreateFunc(b, "__eco_string_len_inline", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStringLength(OpBuilder &b) const {
    // Elm_Kernel_String_length(str: hptr) -> i64. NOT gc-leaf (today's
    // behaviour); used only on the ECO_STRING_LEN_INLINE=0 A/B leg.
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {HPTR_TY});
    return getOrCreateFunc(b, "Elm_Kernel_String_length", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStringCodeUnitAt(OpBuilder &b) const {
    // eco_string_code_unit_at(str: hptr, index: i64) -> i16. gc-leaf:
    // StringOps::charAt never allocates on any of its six tag paths
    // (StringOps.hpp:410-463 -- its only calls are Allocator::resolve),
    // so callers need no rooting.
    auto funcTy = LLVM::LLVMFunctionType::get(I16_TY, {HPTR_TY, I64_TY});
    return getOrCreateFunc(b, "eco_string_code_unit_at", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateUtilsCmp3(OpBuilder &builder) const {
    // Elm_Kernel_Utils_cmp3(a: hptr, b: hptr) -> i64 (UNCLAMPED sign).
    // NOT gc-leaf: generic cmp recurses over arbitrary heap shapes and every
    // kernel extern is deliberately gc-free poison (CGEN_072).
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {HPTR_TY, HPTR_TY});
    return getOrCreateFunc(builder, "Elm_Kernel_Utils_cmp3", funcTy);
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

// Phase-2 pre-materialization: pre-create every runtime function declaration so
// Stage 2 body patterns only READ them (symbol table read-only during the
// parallel body stage). Each getOrCreate* dedups via symCache and is idempotent;
// unused declarations are dropped by the later internalize + globalDCE, so the
// emitted binary is unchanged.
void EcoRuntime::materializeAllRuntimeDecls(OpBuilder &b) const {
    getOrCreateAllocInt(b); getOrCreateAllocFloat(b); getOrCreateAllocChar(b);
    getOrCreateAllocCons(b); getOrCreateAllocTuple2(b); getOrCreateAllocTuple3(b);
    getOrCreateAllocRecord(b); getOrCreateAllocCustom(b); getOrCreateAllocString(b);
    getOrCreateAllocStringLiteral(b); getOrCreateAllocStringLiteralUtf8(b);
    getOrCreateAllocClosure(b);
    getOrCreateAllocClosureK(b); getOrCreateInternClosure0(b);
    getOrCreateAllocate(b);
    getOrCreateAllocIntFast(b); getOrCreateAllocFloatFast(b); getOrCreateAllocCharFast(b);
    getOrCreateAllocConsFast(b); getOrCreateAllocTuple2Fast(b); getOrCreateAllocTuple3Fast(b);
    getOrCreateAllocRecordFast(b); getOrCreateAllocCustomFast(b); getOrCreateAllocStringFast(b);
    getOrCreateAllocClosureFast(b);
    getOrCreateAllocIntSlow(b); getOrCreateAllocFloatSlow(b); getOrCreateAllocCharSlow(b);
    getOrCreateAllocConsSlow(b); getOrCreateAllocTuple2Slow(b); getOrCreateAllocTuple3Slow(b);
    getOrCreateAllocRecordSlow(b); getOrCreateAllocCustomSlow(b); getOrCreateAllocStringSlow(b);
    getOrCreateAllocClosureSlow(b); getOrCreateAllocClosureGroupSlow(b);
    getOrCreateAllocRegionFast(b); getOrCreateAllocRegionSlow(b);
    getOrCreateInitIntAt(b); getOrCreateInitFloatAt(b); getOrCreateInitCharAt(b);
    getOrCreateInitConsAt(b); getOrCreateInitTuple2At(b); getOrCreateInitTuple3At(b);
    getOrCreateInitRecordAt(b); getOrCreateInitCustomAt(b); getOrCreateInitStringAt(b);
    getOrCreateStoreField(b); getOrCreateStoreFieldI64(b); getOrCreateStoreFieldF64(b);
    getOrCreateStoreRecordField(b); getOrCreateStoreRecordFieldI64(b);
    getOrCreateStoreRecordFieldF64(b); getOrCreateSetUnboxed(b);
    getOrCreateAllocTuple2Uninit(b); getOrCreateAllocTuple3Uninit(b); getOrCreateAllocConsUninit(b);
    getOrCreateStoreTupleField(b); getOrCreateStoreTupleFieldI64(b); getOrCreateStoreTupleFieldF64(b);
    getOrCreateStoreConsHead(b); getOrCreateStoreConsHeadI64(b); getOrCreateStoreConsHeadF64(b);
    getOrCreateStoreConsTail(b);
    getOrCreatePapExtend(b); getOrCreateClosureCallSaturated(b);
    getOrCreateClosureCallSaturatedEval(b); getOrCreateApplyClosure(b);
    getOrCreateApplyClosureTyped(b); getOrCreateApplyClosureEval(b);
    getOrCreateApplySegmentationUnknown(b);
    getOrCreateResolveHPtr(b); getOrCreateGetTag(b);
    getOrCreateResolveFwdMarker(b); getOrCreateFollowForward(b);
    getOrCreateGetTagInlineMarker(b);
    getOrCreateAllocInlineMarker(b);
    getOrCreateConsHeadI64(b); getOrCreateConsHeadF64(b); getOrCreateConsHeadI16(b);
    getOrCreateListHeadHybrid(b); getOrCreateListTailHybrid(b);
    getOrCreateListHeadInlineMarker(b); getOrCreateListTailInlineMarker(b);
    getOrCreateTuple2Get0I64(b); getOrCreateTuple2Get1I64(b);
    getOrCreateTuple2Get0F64(b); getOrCreateTuple2Get1F64(b);
    getOrCreateTuple2Get0I16(b); getOrCreateTuple2Get1I16(b);
    getOrCreateTuple3Get0I64(b); getOrCreateTuple3Get1I64(b); getOrCreateTuple3Get2I64(b);
    getOrCreateTuple3Get0F64(b); getOrCreateTuple3Get1F64(b); getOrCreateTuple3Get2F64(b);
    getOrCreateTuple3Get0I16(b); getOrCreateTuple3Get1I16(b); getOrCreateTuple3Get2I16(b);
    getOrCreateRecordGetI64(b); getOrCreateRecordGetF64(b); getOrCreateRecordGetI16(b);
    getOrCreateCustomGetI64(b); getOrCreateCustomGetF64(b); getOrCreateCustomGetI16(b);
    getOrCreateArrayGetI64(b); getOrCreateArrayGetF64(b); getOrCreateArrayGetI16(b);
    getOrCreateCrash(b); getOrCreateGcAddRoot(b); getOrCreateGcStackRangePoint(b);
    getOrCreateGcPushStackRange(b); getOrCreateGcRestoreStackRangePoint(b);
    getOrCreateRegisterTypeGraph(b); getOrCreateDispatchStatsFast(b);
    getOrCreateSlotToHPtr(b); getOrCreateHPtrToSlot(b);
    getOrCreateIntPow(b); getOrCreateUtilsEqual(b);
    getOrCreateGetOrderLT(b); getOrCreateGetOrderEQ(b); getOrCreateGetOrderGT(b);
    getOrCreateStringCmp3(b); getOrCreateStringCmpOrder(b); getOrCreateUtilsCmp3(b);
    getOrCreateStringLenInlineMarker(b); getOrCreateStringLength(b);
    getOrCreateStringCodeUnitAt(b);
    getOrCreateOrderFromSign(b);
    getOrCreateCloneArray(b); getOrCreateArraySetFixKind(b); getOrCreateArrayEmpty(b);
    getOrCreateArraySingletonInt(b); getOrCreateArraySingletonFloat(b);
    getOrCreateArraySingletonChar(b); getOrCreateArraySingletonBox(b);
    getOrCreateArrayPushInt(b); getOrCreateArrayPushFloat(b); getOrCreateArrayPushChar(b);
    getOrCreateArrayPushBox(b); getOrCreateArraySlice(b); getOrCreateArrayAppendN(b);
    getOrCreateStringFromInt(b); getOrCreateStringFromDouble(b);
    getOrCreateDbgPrint(b); getOrCreateDbgPrintInt(b); getOrCreateDbgPrintFloat(b);
    getOrCreateDbgPrintChar(b); getOrCreateDbgPrintTyped(b);
    getOrCreateAsin(b); getOrCreateAcos(b); getOrCreateAtan(b); getOrCreateAtan2(b);
}
