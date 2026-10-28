//===- EcoToLLVMRuntime.cpp - Runtime declarations and type converter -----===//
//
// Defines the `EcoTypeConverter` constructor, `EcoRuntime::getOrCreateFunc`,
// one `getOrCreateX` member per runtime function, `materializeAllRuntimeDecls`,
// `emitAllocWithSafepoint` and `utf8ToUtf16`. Their contracts are on the
// declarations in EcoToLLVMInternal.h.
//
// Most of the file is the `getOrCreateX` members. Each one fixes a runtime
// symbol's LLVM signature and whether its declaration is marked gc-leaf. RS4GC
// turns a call to a declaration that is not gc-leaf into a statepoint, so the
// marking must be false for any function that can collect. Nothing in this
// file adds any attribute other than gc-leaf (REP_LLVM_002).
//
//===----------------------------------------------------------------------===//

#include "EcoToLLVMInternal.h"
#include "../EcoDialect.h"
#include "../BF/BFTypes.h"

using namespace mlir;
using namespace eco::detail;

//===----------------------------------------------------------------------===//
// EcoTypeConverter Implementation
//===----------------------------------------------------------------------===//

static LowerToLLVMOptions ecoLLVMOptions(MLIRContext *ctx) {
    LowerToLLVMOptions opts(ctx);
    // Eco lowers no memrefs, so the bare-pointer convention changes nothing it
    // emits. Setting it makes MLIR's call lowering skip a symbol-table lookup,
    // per call, for the `llvm.bareptr` attribute on the callee.
    opts.useBarePtrCallConv = true;
    return opts;
}

EcoTypeConverter::EcoTypeConverter(MLIRContext *ctx)
    : LLVMTypeConverter(ctx, ecoLLVMOptions(ctx)) {
    addConversion([ctx](eco::ValueType type) {
        return LLVM::LLVMPointerType::get(ctx, /*addressSpace=*/1);
    });

    // An aggregate whose element types do not all convert does not convert.
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

    // A `!bf.cursor` can be an `scf.while` iter_arg. BFToLLVM lowers the bf.*
    // ops but does not rewrite those loop types, so the structural SCF
    // conversion needs this entry. It must match BFTypeConverter's lowering.
    addConversion([ctx](bf::CursorType) -> Type {
        auto ptrType = LLVM::LLVMPointerType::get(ctx);
        return LLVM::LLVMStructType::getLiteral(ctx, { ptrType, ptrType });
    });

    // Both materializations cast exactly one value; any other count fails.
    addSourceMaterialization([](OpBuilder &builder, Type resultType,
                                ValueRange inputs, Location loc) -> Value {
        if (inputs.size() != 1)
            return nullptr;
        return builder.create<UnrealizedConversionCastOp>(loc, resultType, inputs).getResult(0);
    });

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

    // A hit only reads the cache, which is safe while frozen.
    // A miss while frozen would create a symbol from a parallel worker.
    if (auto func = lookupSymbol<LLVM::LLVMFuncOp>(name))
        return func;
    assert(!frozen &&
           "getOrCreateFunc miss after freeze(): a runtime decl was not "
           "pre-declared by materializeAllRuntimeDecls (parallel UB)");

    OpBuilder::InsertionGuard guard(builder);
    builder.setInsertionPointToStart(module.getBody());
    auto newFunc = builder.create<LLVM::LLVMFuncOp>(module.getLoc(), name, funcType);

    if (gcLeaf)
        attachGcLeafPassthrough(builder, newFunc);
    if (auto nameAttr = newFunc->getAttrOfType<mlir::StringAttr>(
            mlir::SymbolTable::getSymbolAttrName()))
        symCache[nameAttr] = newFunc;
    return newFunc;
}

// Shorthands for the LLVM types in runtime signatures. Each reads the `ctx` in
// scope where it is expanded.
#define I64_TY IntegerType::get(ctx, 64)
#define I32_TY IntegerType::get(ctx, 32)
#define CHAR_TY IntegerType::get(ctx, eco::kEcoCharBits)  // Char = i32 code point
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
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {CHAR_TY});
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
    // eco_alloc_custom(ctor_id: i32, field_count: i32) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I32_TY, I32_TY});
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
    // eco_alloc_closure(func_ptr: ptr, arity: i32) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {PTR_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_alloc_closure", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocClosureK(OpBuilder &builder) const {
    // eco_alloc_closure_k(func_ptr: ptr, arity: i32, result_kind: i8) -> hptr
    auto i8Ty = IntegerType::get(builder.getContext(), 8);
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {PTR_TY, I32_TY, i8Ty});
    return getOrCreateFunc(builder, "eco_alloc_closure_k", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateInternClosure0(OpBuilder &builder) const {
    // eco_intern_closure0(func_ptr: ptr, arity: i32, packed: i64) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {PTR_TY, I32_TY, I64_TY});
    return getOrCreateFunc(builder, "eco_intern_closure0", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocate(OpBuilder &builder) const {
    // eco_allocate(size: i64, tag: i32) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I64_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_allocate", funcTy);
}

//===----------------------------------------------------------------------===//
// Fast Allocation Functions (gc-leaf)
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
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {CHAR_TY});
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
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I32_TY, I32_TY});
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
// Slow Allocation Functions (not gc-leaf: they may collect)
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
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {CHAR_TY});
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
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I32_TY, I32_TY});
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

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocClosureGroupL(OpBuilder &builder) const {
    // eco_alloc_closure_group_l(
    //   numSiblings: i64,
    //   evaluators: ptr, arities: ptr, numCaptured: ptr,
    //   hdrKinds: ptr, extKinds: ptr, extOffsets: ptr, resultKinds: ptr,
    //   captureOffsets: ptr, captures: ptr, crossEdges: ptr,
    //   numCrossEdges: i64, outClosures: ptr
    // ) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(
        LLVM::LLVMVoidType::get(builder.getContext()),
        {I64_TY, PTR_TY, PTR_TY, PTR_TY, PTR_TY, PTR_TY, PTR_TY, PTR_TY,
         PTR_TY, PTR_TY, PTR_TY, I64_TY, PTR_TY});
    return getOrCreateFunc(builder, "eco_alloc_closure_group_l", funcTy);
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
    // eco_init_char_at(ptr, value: i32 code point) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {PTR_TY, CHAR_TY});
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
    // eco_init_custom_at(ptr, ctor_id: i32, field_count: i32) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {PTR_TY, I32_TY, I32_TY});
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
// Uninitialised Allocators and Field Stores
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

LLVM::LLVMFuncOp EcoRuntime::getOrCreatePapExtendL(OpBuilder &builder) const {
    // eco_pap_extend_l(closure: hptr, args: ptr, num_args: i32, layout: ptr) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {HPTR_TY, PTR_TY, I32_TY, PTR_TY});
    return getOrCreateFunc(builder, "eco_pap_extend_l", funcTy);
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
    // __eco_resolve_fwd(ptr as1) -> ptr as1. Declaration only: EcoBackend's
    // expandInlineDerefs replaces every call before RS4GC.
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "__eco_resolve_fwd", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateFollowForward(OpBuilder &builder) const {
    auto *ctx = builder.getContext();
    // eco_follow_forward(ptr as1) -> ptr as1
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_follow_forward", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateGetTag(OpBuilder &builder) const {
    // eco_get_tag(value: hptr) -> i32
    auto funcTy = LLVM::LLVMFunctionType::get(I32_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_get_tag", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocInlineMarker(OpBuilder &builder) const {
    // __eco_alloc_inline(size: i64) -> ptr as1. Declaration only: EcoBackend's
    // expandInlineAllocs replaces every call with a bump-pointer allocation,
    // and fails on a size it cannot expand.
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I64_TY});
    return getOrCreateFunc(builder, "__eco_alloc_inline", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateGetTagInlineMarker(OpBuilder &builder) const {
    // __eco_get_tag_inline(hptr) -> i32 constructor tag. Declaration only:
    // EcoBackend's expandGetTagMarkers replaces every call with inline code.
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

LLVM::LLVMFuncOp EcoRuntime::getOrCreateConsHeadChar(OpBuilder &builder) const {
    // eco_cons_head_char(cons: hptr) -> i32
    auto funcTy = LLVM::LLVMFunctionType::get(CHAR_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_cons_head_char", funcTy, /*gcLeaf=*/true);
}

// The chunked-list projection markers are declarations only: EcoBackend's
// expandListProjMarkers replaces each call with inline code.
LLVM::LLVMFuncOp EcoRuntime::getOrCreateListHeadInlineMarker(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "__eco_list_head_inline", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateListTailInlineMarker(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "__eco_list_tail_inline", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateListHeadHybrid(OpBuilder &builder) const {
    // eco_list_head_hybrid(list: hptr) -> hptr (raw slot bits)
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_list_head_hybrid", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateListTailHybrid(OpBuilder &builder) const {
    // eco_list_tail_hybrid(list: hptr) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_list_tail_hybrid", funcTy, /*gcLeaf=*/false);
}

// Tuple2 unboxed-primitive field accessors.
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

LLVM::LLVMFuncOp EcoRuntime::getOrCreateTuple2Get0Char(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(CHAR_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_tuple2_get0_char", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateTuple2Get1Char(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(CHAR_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_tuple2_get1_char", funcTy, /*gcLeaf=*/true);
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

LLVM::LLVMFuncOp EcoRuntime::getOrCreateTuple3Get0Char(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(CHAR_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_tuple3_get0_char", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateTuple3Get1Char(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(CHAR_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_tuple3_get1_char", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateTuple3Get2Char(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(CHAR_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_tuple3_get2_char", funcTy, /*gcLeaf=*/true);
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

LLVM::LLVMFuncOp EcoRuntime::getOrCreateRecordGetChar(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(CHAR_TY, {HPTR_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_record_get_char", funcTy, /*gcLeaf=*/true);
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

LLVM::LLVMFuncOp EcoRuntime::getOrCreateCustomGetChar(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(CHAR_TY, {HPTR_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_custom_get_char", funcTy, /*gcLeaf=*/true);
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

LLVM::LLVMFuncOp EcoRuntime::getOrCreateArrayGetChar(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(CHAR_TY, {HPTR_TY, I64_TY});
    return getOrCreateFunc(builder, "eco_array_get_char", funcTy, /*gcLeaf=*/true);
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

// The saturated-call markers are expanded by EcoBackend's expandSatMarkers, in
// LLVM IR, into a fast path and the generic slow path. They are markers rather
// than branches emitted here because the call can sit in a single-block `scf`
// region, where this conversion cannot create blocks. Both are variadic so that
// one declaration covers every call shape:
//   __eco_sat_begin(cloResolved: ptr as1, N, KC, RC, satByteOff: i64, ...newargs)
//   __eco_sat_end(tok: ptr, slowResult: <R>)
LLVM::LLVMFuncOp EcoRuntime::getOrCreateSatBeginMarker(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(
        PTR_TY, {HPTR_TY, I64_TY, I64_TY, I64_TY, I64_TY}, /*isVarArg=*/true);
    return getOrCreateFunc(builder, "__eco_sat_begin", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateSatEndMarker(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {PTR_TY},
                                              /*isVarArg=*/true);
    return getOrCreateFunc(builder, "__eco_sat_end", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateRegisterTypeGraph(OpBuilder &builder) const {
    // eco_register_type_graph(graph: ptr) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {PTR_TY});
    return getOrCreateFunc(builder, "eco_register_type_graph", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateDispatchStatsFast(OpBuilder &builder) const {
    // eco_dispatch_stats_fast(evaluator_fp: ptr) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {PTR_TY});
    return getOrCreateFunc(builder, "eco_dispatch_stats_fast", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateGencallStats(OpBuilder &builder) const {
    // eco_gencall_stats(reason: i32) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {I32_TY});
    return getOrCreateFunc(builder, "eco_gencall_stats", funcTy, /*gcLeaf=*/true);
}

// The slot-cast barriers are declarations only: StripEcoCastBarriers turns
// every call back into a bare inttoptr or ptrtoint after RS4GC.
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
    // Elm_Kernel_Utils_equal(a: hptr, b: hptr) -> hptr (boxed Bool).
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {HPTR_TY, HPTR_TY});
    return getOrCreateFunc(builder, "Elm_Kernel_Utils_equal", funcTy,
                           /*gcLeaf=*/kernelGcLeafEnabled());
}

// __eco_value_eq(a: hptr, b: hptr) -> i1 is a declaration only: EcoBackend's
// expandValueEqFastPath, which spells the same name, replaces every call. The
// two names must stay equal.
LLVM::LLVMFuncOp EcoRuntime::getOrCreateValueEqMarker(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(I1_TY, {HPTR_TY, HPTR_TY});
    return getOrCreateFunc(builder, "__eco_value_eq", funcTy, /*gcLeaf=*/true);
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
    // eco_order_from_sign(sign: i64) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {I64_TY});
    return getOrCreateFunc(builder, "eco_order_from_sign", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStringCmp3(OpBuilder &builder) const {
    // eco_string_cmp3(a: hptr, b: hptr) -> i64
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {HPTR_TY, HPTR_TY});
    return getOrCreateFunc(builder, "eco_string_cmp3", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStringCmpOrder(OpBuilder &builder) const {
    // eco_string_cmp_order(a: hptr, b: hptr) -> hptr (Order singleton)
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {HPTR_TY, HPTR_TY});
    return getOrCreateFunc(builder, "eco_string_cmp_order", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStringLenInlineMarker(OpBuilder &b) const {
    // __eco_string_len_inline(ptr as1) -> i64. Declaration only: EcoBackend's
    // expandStringLenMarkers replaces every call with inline code.
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {HPTR_TY});
    return getOrCreateFunc(b, "__eco_string_len_inline", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStringLength(OpBuilder &b) const {
    // Elm_Kernel_String_length(str: hptr) -> i64
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {HPTR_TY});
    return getOrCreateFunc(b, "Elm_Kernel_String_length", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStringAppend(OpBuilder &builder) const {
    // eco_string_append(a: hptr, b: hptr) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {HPTR_TY, HPTR_TY});
    return getOrCreateFunc(builder, "eco_string_append", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateListAppend(OpBuilder &builder) const {
    // eco_list_append(a: hptr, b: hptr) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {HPTR_TY, HPTR_TY});
    return getOrCreateFunc(builder, "eco_list_append", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateUtilsCmp3(OpBuilder &builder) const {
    // Elm_Kernel_Utils_cmp3(a: hptr, b: hptr) -> i64
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
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {CHAR_TY});
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
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {CHAR_TY, HPTR_TY});
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
    // eco_dbg_print_char(value: i32) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {CHAR_TY});
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
#undef CHAR_TY
#undef I8_TY
#undef F64_TY
#undef PTR_TY
#undef HPTR_TY
#undef VOID_TY

//===----------------------------------------------------------------------===//
// Allocation Call
//===----------------------------------------------------------------------===//

Value eco::detail::emitAllocWithSafepoint(
    Operation *op,
    ConversionPatternRewriter &rewriter,
    const EcoRuntime &runtime,
    LLVM::LLVMFuncOp allocFunc,
    ValueRange args) {
    auto allocCall = rewriter.create<LLVM::CallOp>(op->getLoc(), allocFunc, args);
    return allocCall.getResult();
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

// A `getOrCreateX` member added to EcoToLLVMInternal.h must also be called here.
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
    getOrCreateAllocClosureSlow(b); getOrCreateAllocClosureGroupL(b);
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
    getOrCreatePapExtendL(b); getOrCreateClosureCallSaturated(b);
    getOrCreateClosureCallSaturatedEval(b); getOrCreateApplyClosure(b);
    getOrCreateApplyClosureTyped(b); getOrCreateApplyClosureEval(b);
    getOrCreateResolveHPtr(b); getOrCreateGetTag(b);
    getOrCreateResolveFwdMarker(b); getOrCreateFollowForward(b);
    getOrCreateGetTagInlineMarker(b);
    getOrCreateAllocInlineMarker(b);
    getOrCreateConsHeadI64(b); getOrCreateConsHeadF64(b); getOrCreateConsHeadChar(b);
    getOrCreateListHeadHybrid(b); getOrCreateListTailHybrid(b);
    getOrCreateListHeadInlineMarker(b); getOrCreateListTailInlineMarker(b);
    getOrCreateTuple2Get0I64(b); getOrCreateTuple2Get1I64(b);
    getOrCreateTuple2Get0F64(b); getOrCreateTuple2Get1F64(b);
    getOrCreateTuple2Get0Char(b); getOrCreateTuple2Get1Char(b);
    getOrCreateTuple3Get0I64(b); getOrCreateTuple3Get1I64(b); getOrCreateTuple3Get2I64(b);
    getOrCreateTuple3Get0F64(b); getOrCreateTuple3Get1F64(b); getOrCreateTuple3Get2F64(b);
    getOrCreateTuple3Get0Char(b); getOrCreateTuple3Get1Char(b); getOrCreateTuple3Get2Char(b);
    getOrCreateRecordGetI64(b); getOrCreateRecordGetF64(b); getOrCreateRecordGetChar(b);
    getOrCreateCustomGetI64(b); getOrCreateCustomGetF64(b); getOrCreateCustomGetChar(b);
    getOrCreateArrayGetI64(b); getOrCreateArrayGetF64(b); getOrCreateArrayGetChar(b);
    getOrCreateCrash(b); getOrCreateGcAddRoot(b); getOrCreateGcStackRangePoint(b);
    getOrCreateGcPushStackRange(b); getOrCreateGcRestoreStackRangePoint(b);
    getOrCreateSatBeginMarker(b); getOrCreateSatEndMarker(b);
    getOrCreateRegisterTypeGraph(b); getOrCreateDispatchStatsFast(b); getOrCreateGencallStats(b);
    getOrCreateSlotToHPtr(b); getOrCreateHPtrToSlot(b);
    getOrCreateIntPow(b); getOrCreateUtilsEqual(b);
    getOrCreateValueEqMarker(b);
    getOrCreateGetOrderLT(b); getOrCreateGetOrderEQ(b); getOrCreateGetOrderGT(b);
    getOrCreateStringCmp3(b); getOrCreateStringCmpOrder(b); getOrCreateUtilsCmp3(b);
    getOrCreateStringLenInlineMarker(b); getOrCreateStringLength(b);
    getOrCreateOrderFromSign(b);
    getOrCreateCloneArray(b); getOrCreateArraySetFixKind(b); getOrCreateArrayEmpty(b);
    getOrCreateArraySingletonInt(b); getOrCreateArraySingletonFloat(b);
    getOrCreateArraySingletonChar(b); getOrCreateArraySingletonBox(b);
    getOrCreateArrayPushInt(b); getOrCreateArrayPushFloat(b); getOrCreateArrayPushChar(b);
    getOrCreateArrayPushBox(b); getOrCreateArraySlice(b); getOrCreateArrayAppendN(b);
    getOrCreateStringFromInt(b); getOrCreateStringFromDouble(b);
    getOrCreateStringAppend(b); getOrCreateListAppend(b);
    getOrCreateDbgPrint(b); getOrCreateDbgPrintInt(b); getOrCreateDbgPrintFloat(b);
    getOrCreateDbgPrintChar(b); getOrCreateDbgPrintTyped(b);
    getOrCreateAsin(b); getOrCreateAcos(b); getOrCreateAtan(b); getOrCreateAtan2(b);
}
