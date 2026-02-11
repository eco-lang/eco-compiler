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

EcoTypeConverter::EcoTypeConverter(MLIRContext *ctx) : LLVMTypeConverter(ctx) {
    // Convert eco.value -> i64 (tagged pointer representation).
    // This implements CGEN_012 for the eco.value type.
    addConversion([ctx](eco::ValueType type) {
        return IntegerType::get(ctx, 64);
    });

    // Source materialization: create i64 from !eco.value
    // This is called when converted operations need values from unconverted operations.
    // Since eco.value is represented as i64 (tagged pointer), no actual conversion
    // is needed at runtime - they're the same bit representation.
    // Use UnrealizedConversionCastOp which works with any types.
    addSourceMaterialization([](OpBuilder &builder, Type resultType,
                                ValueRange inputs, Location loc) -> Value {
        if (inputs.size() != 1)
            return nullptr;
        return builder.create<UnrealizedConversionCastOp>(loc, resultType, inputs).getResult(0);
    });

    // Target materialization: create !eco.value from i64
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
    LLVM::LLVMFunctionType funcType) const {

    if (auto func = module.lookupSymbol<LLVM::LLVMFuncOp>(name))
        return func;

    OpBuilder::InsertionGuard guard(builder);
    builder.setInsertionPointToStart(module.getBody());
    return builder.create<LLVM::LLVMFuncOp>(module.getLoc(), name, funcType);
}

// Helper macros for common type patterns
#define I64_TY IntegerType::get(ctx, 64)
#define I32_TY IntegerType::get(ctx, 32)
#define I16_TY IntegerType::get(ctx, 16)
#define I8_TY IntegerType::get(ctx, 8)
#define I1_TY IntegerType::get(ctx, 1)
#define F64_TY Float64Type::get(ctx)
#define PTR_TY LLVM::LLVMPointerType::get(ctx)
#define VOID_TY LLVM::LLVMVoidType::get(ctx)

//===----------------------------------------------------------------------===//
// Allocation Functions
//===----------------------------------------------------------------------===//

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocInt(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {I64_TY});
    return getOrCreateFunc(builder, "eco_alloc_int", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocFloat(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {F64_TY});
    return getOrCreateFunc(builder, "eco_alloc_float", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocChar(OpBuilder &builder) const {
    // eco_alloc_char(value: i16) -> i64 (i16 maps to Elm Char, promoted to i32 at ABI)
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {I16_TY});
    return getOrCreateFunc(builder, "eco_alloc_char", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocCons(OpBuilder &builder) const {
    // eco_alloc_cons(head: i64, tail: i64, head_unboxed: i32) -> i64
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {I64_TY, I64_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_alloc_cons", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocTuple2(OpBuilder &builder) const {
    // eco_alloc_tuple2(a: i64, b: i64, unboxed_mask: i32) -> i64
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {I64_TY, I64_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_alloc_tuple2", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocTuple3(OpBuilder &builder) const {
    // eco_alloc_tuple3(a: i64, b: i64, c: i64, unboxed_mask: i32) -> i64
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {I64_TY, I64_TY, I64_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_alloc_tuple3", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocRecord(OpBuilder &builder) const {
    // eco_alloc_record(field_count: i32, unboxed_bitmap: i64) -> i64
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {I32_TY, I64_TY});
    return getOrCreateFunc(builder, "eco_alloc_record", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocCustom(OpBuilder &builder) const {
    // eco_alloc_custom(ctor_id: i32, field_count: i32, scalar_bytes: i32) -> i64
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {I32_TY, I32_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_alloc_custom", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocString(OpBuilder &builder) const {
    // eco_alloc_string(length: i32) -> i64
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {I32_TY});
    return getOrCreateFunc(builder, "eco_alloc_string", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocStringLiteral(OpBuilder &builder) const {
    // eco_alloc_string_literal(chars: ptr, length: i32) -> i64
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {PTR_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_alloc_string_literal", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocClosure(OpBuilder &builder) const {
    // eco_alloc_closure(func_ptr: ptr, num_captures: i32) -> i64
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {PTR_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_alloc_closure", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAllocate(OpBuilder &builder) const {
    // eco_allocate(size: i64, tag: i32) -> i64
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {I64_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_allocate", funcTy);
}

//===----------------------------------------------------------------------===//
// Field Storage Functions
//===----------------------------------------------------------------------===//

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStoreField(OpBuilder &builder) const {
    // eco_store_field(obj_hptr: i64, index: i32, value: i64) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {I64_TY, I32_TY, I64_TY});
    return getOrCreateFunc(builder, "eco_store_field", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStoreFieldI64(OpBuilder &builder) const {
    // eco_store_field_i64(obj_hptr: i64, index: i32, value: i64) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {I64_TY, I32_TY, I64_TY});
    return getOrCreateFunc(builder, "eco_store_field_i64", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStoreFieldF64(OpBuilder &builder) const {
    // eco_store_field_f64(obj_hptr: i64, index: i32, value: f64) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {I64_TY, I32_TY, F64_TY});
    return getOrCreateFunc(builder, "eco_store_field_f64", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStoreRecordField(OpBuilder &builder) const {
    // eco_store_record_field(record_hptr: i64, index: i32, value: i64) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {I64_TY, I32_TY, I64_TY});
    return getOrCreateFunc(builder, "eco_store_record_field", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStoreRecordFieldI64(OpBuilder &builder) const {
    // eco_store_record_field_i64(record_hptr: i64, index: i32, value: i64) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {I64_TY, I32_TY, I64_TY});
    return getOrCreateFunc(builder, "eco_store_record_field_i64", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStoreRecordFieldF64(OpBuilder &builder) const {
    // eco_store_record_field_f64(record_hptr: i64, index: i32, value: f64) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {I64_TY, I32_TY, F64_TY});
    return getOrCreateFunc(builder, "eco_store_record_field_f64", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateSetUnboxed(OpBuilder &builder) const {
    // eco_set_unboxed(obj_hptr: i64, bitmap: i64) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {I64_TY, I64_TY});
    return getOrCreateFunc(builder, "eco_set_unboxed", funcTy);
}

//===----------------------------------------------------------------------===//
// Closure Functions
//===----------------------------------------------------------------------===//

LLVM::LLVMFuncOp EcoRuntime::getOrCreatePapExtend(OpBuilder &builder) const {
    // eco_pap_extend(closure_hptr: i64, args: ptr, num_args: i32, new_unboxed_bitmap: i64) -> i64
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {I64_TY, PTR_TY, I32_TY, I64_TY});
    return getOrCreateFunc(builder, "eco_pap_extend", funcTy);
}

//===----------------------------------------------------------------------===//
// Utility Functions
//===----------------------------------------------------------------------===//

LLVM::LLVMFuncOp EcoRuntime::getOrCreateResolveHPtr(OpBuilder &builder) const {
    // eco_resolve_hptr(hptr: i64) -> ptr
    auto funcTy = LLVM::LLVMFunctionType::get(PTR_TY, {I64_TY});
    return getOrCreateFunc(builder, "eco_resolve_hptr", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateGetTag(OpBuilder &builder) const {
    // eco_get_tag(value: i64) -> i32
    // Handles both heap Custom objects and embedded constants (Nothing, Nil).
    auto funcTy = LLVM::LLVMFunctionType::get(I32_TY, {I64_TY});
    return getOrCreateFunc(builder, "eco_get_tag", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateConsHeadI64(OpBuilder &builder) const {
    // eco_cons_head_i64(cons: i64) -> i64
    // Gets head of Cons cell, handling both boxed and unboxed heads.
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {I64_TY});
    return getOrCreateFunc(builder, "eco_cons_head_i64", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateConsHeadF64(OpBuilder &builder) const {
    // eco_cons_head_f64(cons: i64) -> f64
    // Gets head of Cons cell, handling both boxed and unboxed heads.
    auto f64Ty = Float64Type::get(ctx);
    auto funcTy = LLVM::LLVMFunctionType::get(f64Ty, {I64_TY});
    return getOrCreateFunc(builder, "eco_cons_head_f64", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateConsHeadI16(OpBuilder &builder) const {
    // eco_cons_head_i16(cons: i64) -> i16
    // Gets head of Cons cell (Char), handling both boxed and unboxed heads.
    auto i16Ty = IntegerType::get(ctx, 16);
    auto funcTy = LLVM::LLVMFunctionType::get(i16Ty, {I64_TY});
    return getOrCreateFunc(builder, "eco_cons_head_i16", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateCrash(OpBuilder &builder) const {
    // eco_crash(message_val: i64) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {I64_TY});
    return getOrCreateFunc(builder, "eco_crash", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateGcAddRoot(OpBuilder &builder) const {
    // eco_gc_add_root(ptr: ptr) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {PTR_TY});
    return getOrCreateFunc(builder, "eco_gc_add_root", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateRegisterTypeGraph(OpBuilder &builder) const {
    // eco_register_type_graph(graph: ptr) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {PTR_TY});
    return getOrCreateFunc(builder, "eco_register_type_graph", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateIntPow(OpBuilder &builder) const {
    // eco_int_pow(base: i64, exp: i64) -> i64
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {I64_TY, I64_TY});
    return getOrCreateFunc(builder, "eco_int_pow", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateUtilsEqual(OpBuilder &builder) const {
    // Elm_Kernel_Utils_equal(a: i64, b: i64) -> i64 (boxed Bool)
    // Returns a boxed Bool (True/False embedded constant) if the two Elm values
    // are structurally equal. Caller must unbox by comparing with True constant.
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {I64_TY, I64_TY});
    return getOrCreateFunc(builder, "Elm_Kernel_Utils_equal", funcTy);
}

//===----------------------------------------------------------------------===//
// Debug Functions
//===----------------------------------------------------------------------===//

LLVM::LLVMFuncOp EcoRuntime::getOrCreateDbgPrint(OpBuilder &builder) const {
    // eco_dbg_print(values: ptr, count: i32) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {PTR_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_dbg_print", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateDbgPrintInt(OpBuilder &builder) const {
    // eco_dbg_print_int(value: i64) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {I64_TY});
    return getOrCreateFunc(builder, "eco_dbg_print_int", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateDbgPrintFloat(OpBuilder &builder) const {
    // eco_dbg_print_float(value: f64) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {F64_TY});
    return getOrCreateFunc(builder, "eco_dbg_print_float", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateDbgPrintChar(OpBuilder &builder) const {
    // eco_dbg_print_char(value: i16) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {I16_TY});
    return getOrCreateFunc(builder, "eco_dbg_print_char", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateDbgPrintTyped(OpBuilder &builder) const {
    // eco_dbg_print_typed(values: ptr, type_ids: ptr, num_args: i32) -> void
    auto funcTy = LLVM::LLVMFunctionType::get(VOID_TY, {PTR_TY, PTR_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_dbg_print_typed", funcTy);
}

//===----------------------------------------------------------------------===//
// Libc Math Functions
//===----------------------------------------------------------------------===//

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAsin(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(F64_TY, {F64_TY});
    return getOrCreateFunc(builder, "asin", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAcos(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(F64_TY, {F64_TY});
    return getOrCreateFunc(builder, "acos", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAtan(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(F64_TY, {F64_TY});
    return getOrCreateFunc(builder, "atan", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateAtan2(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(F64_TY, {F64_TY, F64_TY});
    return getOrCreateFunc(builder, "atan2", funcTy);
}

#undef I64_TY
#undef I32_TY
#undef I16_TY
#undef I8_TY
#undef F64_TY
#undef PTR_TY
#undef VOID_TY

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
