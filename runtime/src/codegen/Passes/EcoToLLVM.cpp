//===- EcoToLLVM.cpp - Eco dialect to LLVM dialect lowering ---------------===//
//
// This file implements the combined pass for lowering Eco dialect operations
// to LLVM dialect. It handles:
//   - Type conversion: eco.value -> i64 (tagged pointer)
//   - Heap operations: allocate_*, project, box, unbox
//   - Constants: eco.constant -> i64 constant
//   - Calls: eco.call with tailcc convention
//   - Safepoints: eco.safepoint -> no-op
//   - String literals: UTF-8 -> UTF-16 conversion
//
//===----------------------------------------------------------------------===//

#include "mlir/Conversion/LLVMCommon/ConversionTarget.h"
#include "mlir/Conversion/LLVMCommon/TypeConverter.h"
#include "mlir/Conversion/FuncToLLVM/ConvertFuncToLLVM.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlow.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlowOps.h"
#include "mlir/Conversion/ControlFlowToLLVM/ControlFlowToLLVM.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/SCF/IR/SCF.h"
#include "mlir/Dialect/SCF/Transforms/Patterns.h"
#include "mlir/Conversion/SCFToControlFlow/SCFToControlFlow.h"
#include "mlir/Dialect/Func/Transforms/FuncConversions.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/IRMapping.h"
#include "mlir/IR/PatternMatch.h"
#include "mlir/Pass/Pass.h"
#include "mlir/Transforms/DialectConversion.h"

#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../EcoTypes.h"
#include "../Passes.h"

#include <codecvt>
#include <limits>
#include <locale>

using namespace mlir;
using namespace ::eco;

//===----------------------------------------------------------------------===//
// Type Converter
//===----------------------------------------------------------------------===//

namespace {

class EcoTypeConverter : public LLVMTypeConverter {
public:
    EcoTypeConverter(MLIRContext *ctx) : LLVMTypeConverter(ctx) {
        // Convert eco.value -> i64 (tagged pointer representation).
        addConversion([ctx](ValueType type) {
            return IntegerType::get(ctx, 64);
        });
    }
};

} // namespace

//===----------------------------------------------------------------------===//
// Helper Functions
//===----------------------------------------------------------------------===//

namespace {

// Gets or inserts a function declaration for a runtime function.
static LLVM::LLVMFuncOp getOrInsertFunc(ModuleOp module, OpBuilder &builder,
                                         StringRef name,
                                         LLVM::LLVMFunctionType funcType) {
    if (auto func = module.lookupSymbol<LLVM::LLVMFuncOp>(name))
        return func;

    OpBuilder::InsertionGuard guard(builder);
    builder.setInsertionPointToStart(module.getBody());
    return builder.create<LLVM::LLVMFuncOp>(module.getLoc(), name, funcType);
}

// Converts HPointer constant kind to the encoded i64 value.
// The constant field is at bits 40-43 of the HPointer.
// The ConstantKind enum values are 1-based (Unit=1, ..., EmptyString=7).
// This matches the HPointer encoding where 0 means regular pointer.
static int64_t encodeConstant(int kind) {
    return static_cast<int64_t>(kind) << 40;
}

// Converts UTF-8 string to UTF-16.
static std::vector<uint16_t> utf8ToUtf16(StringRef utf8) {
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

} // namespace

//===----------------------------------------------------------------------===//
// Lowering Patterns
//===----------------------------------------------------------------------===//

namespace {

// ============================================================================
// eco.constant -> i64 constant with embedded tag
// ============================================================================

struct ConstantOpLowering : public OpConversionPattern<ConstantOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ConstantOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);

        // Get the constant kind and encode it in the HPointer format.
        // The ConstantKind enum values are 1-based, matching the HPointer encoding.
        int64_t kindValue = static_cast<int64_t>(op.getKind());
        int64_t encoded = kindValue << 40;

        auto result = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, encoded);
        rewriter.replaceOp(op, result);
        return success();
    }
};

// ============================================================================
// eco.safepoint -> no-op (erase)
// ============================================================================

struct SafepointOpLowering : public OpConversionPattern<SafepointOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(SafepointOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        // Safepoints are not needed for tracing GC; erase them.
        rewriter.eraseOp(op);
        return success();
    }
};

// ============================================================================
// eco.dbg -> call eco_dbg_print / eco_dbg_print_int / eco_dbg_print_float / eco_dbg_print_char
// ============================================================================

struct DbgOpLowering : public OpConversionPattern<DbgOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(DbgOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto module = op->getParentOfType<ModuleOp>();
        auto *ctx = rewriter.getContext();

        auto ptrTy = LLVM::LLVMPointerType::get(ctx);
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i64Ty = IntegerType::get(ctx, 64);
        auto f64Ty = Float64Type::get(ctx);
        auto voidTy = LLVM::LLVMVoidType::get(ctx);

        // Get the original (pre-conversion) argument types from the op
        auto origArgs = op.getArgs();
        auto args = adaptor.getArgs();

        for (size_t i = 0; i < args.size(); i++) {
            Type origType = origArgs[i].getType();
            Value arg = args[i];

            if (origType.isInteger(64)) {
                // Unboxed i64 -> eco_dbg_print_int
                auto funcTy = LLVM::LLVMFunctionType::get(voidTy, {i64Ty});
                getOrInsertFunc(module, rewriter, "eco_dbg_print_int", funcTy);
                rewriter.create<LLVM::CallOp>(
                    loc, TypeRange{}, SymbolRefAttr::get(ctx, "eco_dbg_print_int"),
                    ValueRange{arg});
            } else if (origType.isF64()) {
                // Unboxed f64 -> eco_dbg_print_float
                auto funcTy = LLVM::LLVMFunctionType::get(voidTy, {f64Ty});
                getOrInsertFunc(module, rewriter, "eco_dbg_print_float", funcTy);
                rewriter.create<LLVM::CallOp>(
                    loc, TypeRange{}, SymbolRefAttr::get(ctx, "eco_dbg_print_float"),
                    ValueRange{arg});
            } else if (origType.isInteger(16)) {
                // Unboxed i16 (char) -> eco_dbg_print_char
                auto i16Ty = IntegerType::get(ctx, 16);
                auto funcTy = LLVM::LLVMFunctionType::get(voidTy, {i16Ty});
                getOrInsertFunc(module, rewriter, "eco_dbg_print_char", funcTy);
                rewriter.create<LLVM::CallOp>(
                    loc, TypeRange{}, SymbolRefAttr::get(ctx, "eco_dbg_print_char"),
                    ValueRange{arg});
            } else {
                // Boxed value (!eco.value) -> eco_dbg_print with array
                auto funcTy = LLVM::LLVMFunctionType::get(voidTy, {ptrTy, i32Ty});
                getOrInsertFunc(module, rewriter, "eco_dbg_print", funcTy);

                // Allocate single-element array on stack
                auto arrayTy = LLVM::LLVMArrayType::get(i64Ty, 1);
                auto one = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, 1);
                auto alloca = rewriter.create<LLVM::AllocaOp>(loc, ptrTy, arrayTy, one);

                // Store the value
                auto zero = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, 0);
                auto gep = rewriter.create<LLVM::GEPOp>(loc, ptrTy, arrayTy, alloca,
                                                        ValueRange{zero, zero});
                rewriter.create<LLVM::StoreOp>(loc, arg, gep);

                // Call eco_dbg_print
                rewriter.create<LLVM::CallOp>(
                    loc, TypeRange{}, SymbolRefAttr::get(ctx, "eco_dbg_print"),
                    ValueRange{alloca, one});
            }
        }

        rewriter.eraseOp(op);
        return success();
    }
};

// ============================================================================
// eco.box -> call eco_alloc_* + ptrtoint
// ============================================================================

struct BoxOpLowering : public OpConversionPattern<BoxOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(BoxOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto module = op->getParentOfType<ModuleOp>();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        Value input = adaptor.getValue();
        Type inputType = input.getType();
        Value result;

        if (inputType.isInteger(64)) {
            // Box i64 -> eco_alloc_int.
            auto funcTy = LLVM::LLVMFunctionType::get(ptrTy, {i64Ty});
            getOrInsertFunc(module, rewriter, "eco_alloc_int", funcTy);

            auto call = rewriter.create<LLVM::CallOp>(
                loc, ptrTy, SymbolRefAttr::get(ctx, "eco_alloc_int"),
                ValueRange{input});
            result = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, call.getResult());
        } else if (inputType.isF64()) {
            // Box f64 -> eco_alloc_float.
            auto f64Ty = Float64Type::get(ctx);
            auto funcTy = LLVM::LLVMFunctionType::get(ptrTy, {f64Ty});
            getOrInsertFunc(module, rewriter, "eco_alloc_float", funcTy);

            auto call = rewriter.create<LLVM::CallOp>(
                loc, ptrTy, SymbolRefAttr::get(ctx, "eco_alloc_float"),
                ValueRange{input});
            result = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, call.getResult());
        } else if (inputType.isInteger(16)) {
            // Box i16 (char) -> eco_alloc_char.
            auto i16Ty = IntegerType::get(ctx, 16);
            auto funcTy = LLVM::LLVMFunctionType::get(ptrTy, {i16Ty});
            getOrInsertFunc(module, rewriter, "eco_alloc_char", funcTy);

            auto call = rewriter.create<LLVM::CallOp>(
                loc, ptrTy, SymbolRefAttr::get(ctx, "eco_alloc_char"),
                ValueRange{input});
            result = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, call.getResult());
        } else if (inputType.isInteger(1)) {
            // Box i1 (bool) -> use embedded constant True/False.
            // ConstantKind::True = 3, ConstantKind::False = 4.
            auto trueCst = rewriter.create<LLVM::ConstantOp>(
                loc, i64Ty, encodeConstant(3));  // True
            auto falseCst = rewriter.create<LLVM::ConstantOp>(
                loc, i64Ty, encodeConstant(4)); // False
            result = rewriter.create<LLVM::SelectOp>(loc, input, trueCst, falseCst);
        } else {
            return op.emitError("unsupported type for boxing: ") << inputType;
        }

        rewriter.replaceOp(op, result);
        return success();
    }
};

// ============================================================================
// eco.unbox -> inttoptr + gep + load
// ============================================================================

struct UnboxOpLowering : public OpConversionPattern<UnboxOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(UnboxOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);
        auto i8Ty = IntegerType::get(ctx, 8);
        auto i1Ty = IntegerType::get(ctx, 1);

        Value input = adaptor.getValue();
        Type resultType = getTypeConverter()->convertType(op.getResult().getType());

        // Special case for i1 (Bool): boxed bools are embedded constants, not heap objects.
        // True = encodeConstant(3) = 3 << 40, False = encodeConstant(4) = 4 << 40.
        // To unbox, compare with True constant.
        if (resultType == i1Ty) {
            auto trueConst = rewriter.create<LLVM::ConstantOp>(
                loc, i64Ty, encodeConstant(3));  // True
            Value result = rewriter.create<LLVM::ICmpOp>(
                loc, LLVM::ICmpPredicate::eq, input, trueConst);
            rewriter.replaceOp(op, result);
            return success();
        }

        // Convert tagged i64 to pointer.
        auto ptr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, input);

        // Offset 8 bytes past the Header to access the value field.
        auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 8);
        auto valuePtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr,
                                                      ValueRange{offset});

        // Load the unboxed value.
        Value result = rewriter.create<LLVM::LoadOp>(loc, resultType, valuePtr);

        rewriter.replaceOp(op, result);
        return success();
    }
};

// ============================================================================
// eco.allocate -> call eco_allocate + ptrtoint
// ============================================================================

struct AllocateOpLowering : public OpConversionPattern<AllocateOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(AllocateOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto module = op->getParentOfType<ModuleOp>();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i64Ty = IntegerType::get(ctx, 64);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        // Get or insert eco_allocate declaration: void* eco_allocate(uint64_t size, uint32_t tag)
        auto funcTy = LLVM::LLVMFunctionType::get(ptrTy, {i64Ty, i32Ty});
        getOrInsertFunc(module, rewriter, "eco_allocate", funcTy);

        // The size operand is already converted to i64
        auto size = adaptor.getSize();

        // For the tag, we use Tag_Custom (7) as a default since eco.allocate
        // is typically used for generic ADT allocation. The type attribute
        // is informational for debugging/GC root registration.
        auto tag = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, 7);  // Tag_Custom

        // Call eco_allocate
        auto call = rewriter.create<LLVM::CallOp>(
            loc, ptrTy, SymbolRefAttr::get(ctx, "eco_allocate"),
            ValueRange{size, tag});

        // Convert ptr to i64
        auto result = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, call.getResult());

        rewriter.replaceOp(op, result);
        return success();
    }
};

// ============================================================================
// eco.allocate_ctor -> call eco_alloc_custom + ptrtoint
// ============================================================================

struct AllocateCtorOpLowering : public OpConversionPattern<AllocateCtorOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(AllocateCtorOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto module = op->getParentOfType<ModuleOp>();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i64Ty = IntegerType::get(ctx, 64);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        // Get or insert eco_alloc_custom declaration
        auto funcTy = LLVM::LLVMFunctionType::get(ptrTy, {i32Ty, i32Ty, i32Ty});
        getOrInsertFunc(module, rewriter, "eco_alloc_custom", funcTy);

        // Create constants for arguments
        auto tag = rewriter.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(op.getTag()));
        auto size = rewriter.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(op.getSize()));
        auto scalarBytes = rewriter.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(op.getScalarBytes()));

        // Call eco_alloc_custom
        auto call = rewriter.create<LLVM::CallOp>(
            loc, ptrTy, SymbolRefAttr::get(ctx, "eco_alloc_custom"),
            ValueRange{tag, size, scalarBytes});

        // Convert ptr to i64
        auto result = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, call.getResult());

        rewriter.replaceOp(op, result);
        return success();
    }
};

// ============================================================================
// eco.allocate_string -> call eco_alloc_string + ptrtoint
// ============================================================================

struct AllocateStringOpLowering : public OpConversionPattern<AllocateStringOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(AllocateStringOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto module = op->getParentOfType<ModuleOp>();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i64Ty = IntegerType::get(ctx, 64);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        // Get or insert eco_alloc_string declaration
        auto funcTy = LLVM::LLVMFunctionType::get(ptrTy, {i32Ty});
        getOrInsertFunc(module, rewriter, "eco_alloc_string", funcTy);

        // Create length constant
        auto length = rewriter.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(op.getLength()));

        // Call eco_alloc_string
        auto call = rewriter.create<LLVM::CallOp>(
            loc, ptrTy, SymbolRefAttr::get(ctx, "eco_alloc_string"),
            ValueRange{length});

        // Convert ptr to i64
        auto result = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, call.getResult());

        rewriter.replaceOp(op, result);
        return success();
    }
};

// ============================================================================
// eco.allocate_closure -> call eco_alloc_closure + ptrtoint
// ============================================================================

struct AllocateClosureOpLowering : public OpConversionPattern<AllocateClosureOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(AllocateClosureOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto module = op->getParentOfType<ModuleOp>();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i64Ty = IntegerType::get(ctx, 64);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        // Get or insert eco_alloc_closure declaration
        auto allocClosureTy = LLVM::LLVMFunctionType::get(ptrTy, {ptrTy, i32Ty});
        getOrInsertFunc(module, rewriter, "eco_alloc_closure", allocClosureTy);

        // Get function address for the closure.
        // func.func will be converted to llvm.func by func-to-llvm patterns
        // that are part of this pass, so AddressOfOp will find the llvm.func.
        auto funcSymbol = op.getFunction();
        Value funcPtr = rewriter.create<LLVM::AddressOfOp>(loc, ptrTy, funcSymbol);

        // Create arity constant (max_values for the closure)
        auto arityConst = rewriter.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(op.getArity()));

        // Call eco_alloc_closure(func_ptr, arity)
        auto call = rewriter.create<LLVM::CallOp>(
            loc, ptrTy, SymbolRefAttr::get(ctx, "eco_alloc_closure"),
            ValueRange{funcPtr, arityConst});

        // Convert ptr to i64
        auto result = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, call.getResult());

        rewriter.replaceOp(op, result);
        return success();
    }
};

// ============================================================================
// eco.papCreate -> alloc_closure + store n_values + store captured values
// ============================================================================

struct PapCreateOpLowering : public OpConversionPattern<PapCreateOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(PapCreateOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto module = op->getParentOfType<ModuleOp>();
        auto *ctx = rewriter.getContext();
        auto i8Ty = IntegerType::get(ctx, 8);
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i64Ty = IntegerType::get(ctx, 64);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        int64_t arity = op.getArity();
        int64_t numCaptured = op.getNumCaptured();
        auto captured = adaptor.getCaptured();

        // Get or insert eco_alloc_closure declaration.
        auto allocClosureTy = LLVM::LLVMFunctionType::get(ptrTy, {ptrTy, i32Ty});
        getOrInsertFunc(module, rewriter, "eco_alloc_closure", allocClosureTy);

        // Get function address for the closure.
        // func.func will be converted to llvm.func by func-to-llvm patterns
        // that are part of this pass, so AddressOfOp will find the llvm.func.
        auto funcSymbol = op.getFunction();
        Value funcPtr = rewriter.create<LLVM::AddressOfOp>(loc, ptrTy, funcSymbol);

        // Call eco_alloc_closure(func_ptr, arity).
        // This allocates a closure with max_values = arity, n_values = 0.
        auto arityConst = rewriter.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(arity));
        auto call = rewriter.create<LLVM::CallOp>(
            loc, ptrTy, SymbolRefAttr::get(ctx, "eco_alloc_closure"),
            ValueRange{funcPtr, arityConst});
        Value closurePtr = call.getResult();

        // Closure layout:
        //   Header: offset 0, size 8
        //   Packed (n_values:6, max_values:6, unboxed:52): offset 8, size 8
        //   evaluator: offset 16, size 8
        //   values[]: offset 24

        // Update the packed field at offset 8 to set n_values = numCaptured.
        // After eco_alloc_closure, the packed value is: (arity << 6).
        // We need: numCaptured | (arity << 6) | (unboxed_bitmap << 12).

        // Compute unboxed bitmap: bit i is set if captured[i] is a primitive (not eco.value).
        uint64_t unboxedBitmap = 0;
        for (size_t i = 0; i < captured.size(); ++i) {
            // If the original operand type was not eco.value, it's unboxed.
            Type origType = op.getCaptured()[i].getType();
            if (!isa<ValueType>(origType)) {
                unboxedBitmap |= (1ULL << i);
            }
        }

        uint64_t packedValue = static_cast<uint64_t>(numCaptured) |
                               (static_cast<uint64_t>(arity) << 6) |
                               (unboxedBitmap << 12);

        auto packedConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
            rewriter.getI64IntegerAttr(packedValue));

        // GEP to offset 8 (packed field).
        auto offset8 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
            rewriter.getI64IntegerAttr(8));
        auto packedPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, closurePtr,
                                                       ValueRange{offset8});
        rewriter.create<LLVM::StoreOp>(loc, packedConst, packedPtr);

        // Store captured values starting at offset 24.
        for (size_t i = 0; i < captured.size(); ++i) {
            int64_t valueOffset = 24 + i * 8;
            auto offsetConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
                rewriter.getI64IntegerAttr(valueOffset));
            auto valuePtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, closurePtr,
                                                          ValueRange{offsetConst});

            Value capturedValue = captured[i];
            // Ensure the value is i64 for storage.
            if (capturedValue.getType() != i64Ty) {
                // If it's a pointer, convert to i64.
                if (isa<LLVM::LLVMPointerType>(capturedValue.getType())) {
                    capturedValue = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, capturedValue);
                }
                // Other types (i32, f64, etc.) need appropriate conversion.
                // For now, assume converted operands are already i64.
            }
            rewriter.create<LLVM::StoreOp>(loc, capturedValue, valuePtr);
        }

        // Convert closure ptr to i64 for eco.value representation.
        auto result = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, closurePtr);
        rewriter.replaceOp(op, result);
        return success();
    }
};

// ============================================================================
// eco.papExtend -> either allocate new closure (partial) or call function (saturated)
// ============================================================================

struct PapExtendOpLowering : public OpConversionPattern<PapExtendOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(PapExtendOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto module = op->getParentOfType<ModuleOp>();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i64Ty = IntegerType::get(ctx, 64);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        int64_t remainingArity = op.getRemainingArity();
        auto newargs = adaptor.getNewargs();
        int64_t numNewArgs = newargs.size();

        // Convert closure i64 to pointer.
        Value closureI64 = adaptor.getClosure();
        Value closurePtr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, closureI64);

        // Determine if this is a saturated call.
        bool isSaturated = (numNewArgs == remainingArity);

        if (isSaturated) {
            // Saturated call: load all captured values and call the function directly.

            // Closure layout:
            //   offset 8: packed (n_values:6, max_values:6, unboxed:52)
            //   offset 16: evaluator (function pointer)
            //   offset 24: values[]

            // Load packed field to get n_values (bits 0-5).
            // For saturated calls, we call a runtime helper that handles extracting
            // captured values and dispatching to the evaluator.
            auto helperTy = LLVM::LLVMFunctionType::get(i64Ty, {ptrTy, ptrTy, i32Ty});
            getOrInsertFunc(module, rewriter, "eco_closure_call_saturated", helperTy);

            // Build args array on stack.
            auto numArgsConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
                rewriter.getI64IntegerAttr(numNewArgs));
            Value argsArray = rewriter.create<LLVM::AllocaOp>(loc, ptrTy, i64Ty, numArgsConst);

            for (size_t i = 0; i < newargs.size(); ++i) {
                auto idxConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
                    rewriter.getI64IntegerAttr(i));
                auto slotPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i64Ty, argsArray,
                                                            ValueRange{idxConst});
                Value arg = newargs[i];
                if (arg.getType() != i64Ty && isa<LLVM::LLVMPointerType>(arg.getType())) {
                    arg = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, arg);
                }
                rewriter.create<LLVM::StoreOp>(loc, arg, slotPtr);
            }

            auto numNewArgsConst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
                static_cast<int32_t>(numNewArgs));

            auto call = rewriter.create<LLVM::CallOp>(
                loc, i64Ty, SymbolRefAttr::get(ctx, "eco_closure_call_saturated"),
                ValueRange{closurePtr, argsArray, numNewArgsConst});

            rewriter.replaceOp(op, call.getResult());
        } else {
            // Partial application: allocate new closure with combined captured values.
            // Call runtime helper to create extended closure.

            auto helperTy = LLVM::LLVMFunctionType::get(ptrTy, {ptrTy, ptrTy, i32Ty});
            getOrInsertFunc(module, rewriter, "eco_pap_extend", helperTy);

            // Build args array on stack.
            auto numArgsConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
                rewriter.getI64IntegerAttr(numNewArgs));
            Value argsArray = rewriter.create<LLVM::AllocaOp>(loc, ptrTy, i64Ty, numArgsConst);

            for (size_t i = 0; i < newargs.size(); ++i) {
                auto idxConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
                    rewriter.getI64IntegerAttr(i));
                auto slotPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i64Ty, argsArray,
                                                            ValueRange{idxConst});
                Value arg = newargs[i];
                if (arg.getType() != i64Ty && isa<LLVM::LLVMPointerType>(arg.getType())) {
                    arg = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, arg);
                }
                rewriter.create<LLVM::StoreOp>(loc, arg, slotPtr);
            }

            auto numNewArgsConst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
                static_cast<int32_t>(numNewArgs));

            auto call = rewriter.create<LLVM::CallOp>(
                loc, ptrTy, SymbolRefAttr::get(ctx, "eco_pap_extend"),
                ValueRange{closurePtr, argsArray, numNewArgsConst});

            auto result = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, call.getResult());
            rewriter.replaceOp(op, result);
        }

        return success();
    }
};

// ============================================================================
// Type-Specific Construction and Projection Lowerings
// ============================================================================

// eco.construct.list -> call eco_alloc_cons(head, tail, head_unboxed)
struct ListConstructOpLowering : public OpConversionPattern<ListConstructOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ListConstructOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto module = op->getParentOfType<ModuleOp>();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i64Ty = IntegerType::get(ctx, 64);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        // eco_alloc_cons(void* head, void* tail, uint32_t head_unboxed)
        auto funcTy = LLVM::LLVMFunctionType::get(ptrTy, {ptrTy, ptrTy, i32Ty});
        getOrInsertFunc(module, rewriter, "eco_alloc_cons", funcTy);

        // Convert operands: head and tail are i64 tagged pointers, convert to ptr.
        auto headVal = adaptor.getHead();
        auto tailVal = adaptor.getTail();
        auto headPtr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, headVal);
        auto tailPtr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, tailVal);

        // head_unboxed attribute.
        uint32_t headUnboxed = op.getHeadUnboxed() ? 1 : 0;
        auto headUnboxedVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, headUnboxed);

        // Call eco_alloc_cons.
        auto call = rewriter.create<LLVM::CallOp>(
            loc, ptrTy, SymbolRefAttr::get(ctx, "eco_alloc_cons"),
            ValueRange{headPtr, tailPtr, headUnboxedVal});

        // Convert result ptr to i64.
        auto result = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, call.getResult());
        rewriter.replaceOp(op, result);
        return success();
    }
};

// eco.project.list_head -> load from Cons.head (offset 8)
struct ListHeadOpLowering : public OpConversionPattern<ListHeadOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ListHeadOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i8Ty = IntegerType::get(ctx, 8);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        Value input = adaptor.getList();
        auto ptr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, input);

        // Cons layout: Header (8) + head (8) + tail (8).
        // Head is at offset 8.
        int64_t offsetBytes = 8;
        auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, offsetBytes);
        auto fieldPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr,
                                                      ValueRange{offset});

        Type resultType = getTypeConverter()->convertType(op.getResult().getType());
        Value result = rewriter.create<LLVM::LoadOp>(loc, resultType, fieldPtr);
        rewriter.replaceOp(op, result);
        return success();
    }
};

// eco.project.list_tail -> load from Cons.tail (offset 16)
struct ListTailOpLowering : public OpConversionPattern<ListTailOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ListTailOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i8Ty = IntegerType::get(ctx, 8);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        Value input = adaptor.getList();
        auto ptr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, input);

        // Cons layout: Header (8) + head (8) + tail (8).
        // Tail is at offset 16.
        int64_t offsetBytes = 16;
        auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, offsetBytes);
        auto fieldPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr,
                                                      ValueRange{offset});

        Type resultType = getTypeConverter()->convertType(op.getResult().getType());
        Value result = rewriter.create<LLVM::LoadOp>(loc, resultType, fieldPtr);
        rewriter.replaceOp(op, result);
        return success();
    }
};

// eco.construct.tuple2 -> call eco_alloc_tuple2(a, b, unboxed_mask)
struct Tuple2ConstructOpLowering : public OpConversionPattern<Tuple2ConstructOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(Tuple2ConstructOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto module = op->getParentOfType<ModuleOp>();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i64Ty = IntegerType::get(ctx, 64);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        // eco_alloc_tuple2(void* a, void* b, uint32_t unboxed_mask)
        auto funcTy = LLVM::LLVMFunctionType::get(ptrTy, {ptrTy, ptrTy, i32Ty});
        getOrInsertFunc(module, rewriter, "eco_alloc_tuple2", funcTy);

        auto aVal = adaptor.getA();
        auto bVal = adaptor.getB();
        auto aPtr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, aVal);
        auto bPtr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, bVal);

        int64_t unboxedMask = op.getUnboxedBitmap();
        auto unboxedVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
            static_cast<int32_t>(unboxedMask));

        auto call = rewriter.create<LLVM::CallOp>(
            loc, ptrTy, SymbolRefAttr::get(ctx, "eco_alloc_tuple2"),
            ValueRange{aPtr, bPtr, unboxedVal});

        auto result = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, call.getResult());
        rewriter.replaceOp(op, result);
        return success();
    }
};

// eco.construct.tuple3 -> call eco_alloc_tuple3(a, b, c, unboxed_mask)
struct Tuple3ConstructOpLowering : public OpConversionPattern<Tuple3ConstructOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(Tuple3ConstructOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto module = op->getParentOfType<ModuleOp>();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i64Ty = IntegerType::get(ctx, 64);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        // eco_alloc_tuple3(void* a, void* b, void* c, uint32_t unboxed_mask)
        auto funcTy = LLVM::LLVMFunctionType::get(ptrTy, {ptrTy, ptrTy, ptrTy, i32Ty});
        getOrInsertFunc(module, rewriter, "eco_alloc_tuple3", funcTy);

        auto aVal = adaptor.getA();
        auto bVal = adaptor.getB();
        auto cVal = adaptor.getC();
        auto aPtr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, aVal);
        auto bPtr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, bVal);
        auto cPtr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, cVal);

        int64_t unboxedMask = op.getUnboxedBitmap();
        auto unboxedVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
            static_cast<int32_t>(unboxedMask));

        auto call = rewriter.create<LLVM::CallOp>(
            loc, ptrTy, SymbolRefAttr::get(ctx, "eco_alloc_tuple3"),
            ValueRange{aPtr, bPtr, cPtr, unboxedVal});

        auto result = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, call.getResult());
        rewriter.replaceOp(op, result);
        return success();
    }
};

// eco.project.tuple2 -> load from Tuple2.a (offset 8) or Tuple2.b (offset 16)
struct Tuple2ProjectOpLowering : public OpConversionPattern<Tuple2ProjectOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(Tuple2ProjectOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i8Ty = IntegerType::get(ctx, 8);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        Value input = adaptor.getTuple();
        int64_t field = op.getField();
        auto ptr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, input);

        // Tuple2 layout: Header (8) + a (8) + b (8).
        // field 0 = offset 8, field 1 = offset 16.
        int64_t offsetBytes = 8 + field * 8;
        auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, offsetBytes);
        auto fieldPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr,
                                                      ValueRange{offset});

        Type resultType = getTypeConverter()->convertType(op.getResult().getType());
        Value result = rewriter.create<LLVM::LoadOp>(loc, resultType, fieldPtr);
        rewriter.replaceOp(op, result);
        return success();
    }
};

// eco.project.tuple3 -> load from Tuple3 fields
struct Tuple3ProjectOpLowering : public OpConversionPattern<Tuple3ProjectOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(Tuple3ProjectOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i8Ty = IntegerType::get(ctx, 8);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        Value input = adaptor.getTuple();
        int64_t field = op.getField();
        auto ptr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, input);

        // Tuple3 layout: Header (8) + a (8) + b (8) + c (8).
        // field 0 = offset 8, field 1 = offset 16, field 2 = offset 24.
        int64_t offsetBytes = 8 + field * 8;
        auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, offsetBytes);
        auto fieldPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr,
                                                      ValueRange{offset});

        Type resultType = getTypeConverter()->convertType(op.getResult().getType());
        Value result = rewriter.create<LLVM::LoadOp>(loc, resultType, fieldPtr);
        rewriter.replaceOp(op, result);
        return success();
    }
};

// eco.construct.record -> call eco_alloc_record, then store fields
struct RecordConstructOpLowering : public OpConversionPattern<RecordConstructOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(RecordConstructOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto module = op->getParentOfType<ModuleOp>();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i64Ty = IntegerType::get(ctx, 64);
        auto f64Ty = Float64Type::get(ctx);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);
        auto voidTy = LLVM::LLVMVoidType::get(ctx);

        // eco_alloc_record(uint32_t field_count, uint64_t unboxed_bitmap)
        auto allocFuncTy = LLVM::LLVMFunctionType::get(ptrTy, {i32Ty, i64Ty});
        getOrInsertFunc(module, rewriter, "eco_alloc_record", allocFuncTy);

        // eco_store_record_field(void* record, uint32_t index, void* value)
        auto storeFuncTy = LLVM::LLVMFunctionType::get(voidTy, {ptrTy, i32Ty, ptrTy});
        getOrInsertFunc(module, rewriter, "eco_store_record_field", storeFuncTy);

        // eco_store_record_field_i64(void* record, uint32_t index, int64_t value)
        auto storeI64FuncTy = LLVM::LLVMFunctionType::get(voidTy, {ptrTy, i32Ty, i64Ty});
        getOrInsertFunc(module, rewriter, "eco_store_record_field_i64", storeI64FuncTy);

        // eco_store_record_field_f64(void* record, uint32_t index, double value)
        auto storeF64FuncTy = LLVM::LLVMFunctionType::get(voidTy, {ptrTy, i32Ty, f64Ty});
        getOrInsertFunc(module, rewriter, "eco_store_record_field_f64", storeF64FuncTy);

        int64_t fieldCount = op.getFieldCount();
        int64_t unboxedBitmap = op.getUnboxedBitmap();

        auto fieldCountVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
            static_cast<int32_t>(fieldCount));
        auto unboxedBitmapVal = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, unboxedBitmap);

        auto allocCall = rewriter.create<LLVM::CallOp>(
            loc, ptrTy, SymbolRefAttr::get(ctx, "eco_alloc_record"),
            ValueRange{fieldCountVal, unboxedBitmapVal});
        auto objPtr = allocCall.getResult();

        // Store each field.
        auto origFields = op.getFields();
        auto fields = adaptor.getFields();
        for (size_t i = 0; i < fields.size(); i++) {
            auto idx = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(i));
            Type origType = origFields[i].getType();
            Value fieldVal = fields[i];

            if (origType.isF64()) {
                rewriter.create<LLVM::CallOp>(
                    loc, TypeRange{}, SymbolRefAttr::get(ctx, "eco_store_record_field_f64"),
                    ValueRange{objPtr, idx, fieldVal});
            } else if (origType.isInteger(1) || origType.isInteger(16)) {
                // Bool or Char -> extend to i64.
                auto extended = rewriter.create<LLVM::ZExtOp>(loc, i64Ty, fieldVal);
                rewriter.create<LLVM::CallOp>(
                    loc, TypeRange{}, SymbolRefAttr::get(ctx, "eco_store_record_field_i64"),
                    ValueRange{objPtr, idx, extended});
            } else if (origType.isInteger(64)) {
                rewriter.create<LLVM::CallOp>(
                    loc, TypeRange{}, SymbolRefAttr::get(ctx, "eco_store_record_field_i64"),
                    ValueRange{objPtr, idx, fieldVal});
            } else {
                // Boxed !eco.value -> convert to ptr.
                auto valPtr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, fieldVal);
                rewriter.create<LLVM::CallOp>(
                    loc, TypeRange{}, SymbolRefAttr::get(ctx, "eco_store_record_field"),
                    ValueRange{objPtr, idx, valPtr});
            }
        }

        auto result = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, objPtr);
        rewriter.replaceOp(op, result);
        return success();
    }
};

// eco.project.record -> load from Record.values[index]
struct RecordProjectOpLowering : public OpConversionPattern<RecordProjectOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(RecordProjectOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i8Ty = IntegerType::get(ctx, 8);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        Value input = adaptor.getRecord();
        int64_t index = op.getFieldIndex();
        auto ptr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, input);

        // Record layout: Header (8) + unboxed (8) + values[index * 8].
        // Field at index N is at offset 16 + N * 8.
        int64_t offsetBytes = 16 + index * 8;
        auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, offsetBytes);
        auto fieldPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr,
                                                      ValueRange{offset});

        Type resultType = getTypeConverter()->convertType(op.getResult().getType());
        Value result = rewriter.create<LLVM::LoadOp>(loc, resultType, fieldPtr);
        rewriter.replaceOp(op, result);
        return success();
    }
};

// eco.construct.custom -> call eco_alloc_custom, then store fields
struct CustomConstructOpLowering : public OpConversionPattern<CustomConstructOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(CustomConstructOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto module = op->getParentOfType<ModuleOp>();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i64Ty = IntegerType::get(ctx, 64);
        auto f64Ty = Float64Type::get(ctx);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);
        auto voidTy = LLVM::LLVMVoidType::get(ctx);

        // eco_alloc_custom(ctor_id, field_count, scalar_bytes)
        auto allocFuncTy = LLVM::LLVMFunctionType::get(ptrTy, {i32Ty, i32Ty, i32Ty});
        getOrInsertFunc(module, rewriter, "eco_alloc_custom", allocFuncTy);

        auto storeFuncTy = LLVM::LLVMFunctionType::get(voidTy, {ptrTy, i32Ty, i64Ty});
        getOrInsertFunc(module, rewriter, "eco_store_field", storeFuncTy);

        auto storeI64FuncTy = LLVM::LLVMFunctionType::get(voidTy, {ptrTy, i32Ty, i64Ty});
        getOrInsertFunc(module, rewriter, "eco_store_field_i64", storeI64FuncTy);

        auto storeF64FuncTy = LLVM::LLVMFunctionType::get(voidTy, {ptrTy, i32Ty, f64Ty});
        getOrInsertFunc(module, rewriter, "eco_store_field_f64", storeF64FuncTy);

        auto setUnboxedFuncTy = LLVM::LLVMFunctionType::get(voidTy, {ptrTy, i64Ty});
        getOrInsertFunc(module, rewriter, "eco_set_unboxed", setUnboxedFuncTy);

        auto tag = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(op.getTag()));
        auto size = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(op.getSize()));
        auto scalarBytes = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, 0);

        auto allocCall = rewriter.create<LLVM::CallOp>(
            loc, ptrTy, SymbolRefAttr::get(ctx, "eco_alloc_custom"),
            ValueRange{tag, size, scalarBytes});
        auto objPtr = allocCall.getResult();

        // Store each field.
        auto origFields = op.getFields();
        auto fields = adaptor.getFields();
        for (size_t i = 0; i < fields.size(); i++) {
            auto idx = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(i));
            Type origType = origFields[i].getType();
            Value fieldVal = fields[i];

            if (origType.isF64()) {
                rewriter.create<LLVM::CallOp>(
                    loc, TypeRange{}, SymbolRefAttr::get(ctx, "eco_store_field_f64"),
                    ValueRange{objPtr, idx, fieldVal});
            } else if (origType.isInteger(1) || origType.isInteger(16)) {
                auto extended = rewriter.create<LLVM::ZExtOp>(loc, i64Ty, fieldVal);
                rewriter.create<LLVM::CallOp>(
                    loc, TypeRange{}, SymbolRefAttr::get(ctx, "eco_store_field_i64"),
                    ValueRange{objPtr, idx, extended});
            } else if (origType.isInteger(64)) {
                rewriter.create<LLVM::CallOp>(
                    loc, TypeRange{}, SymbolRefAttr::get(ctx, "eco_store_field_i64"),
                    ValueRange{objPtr, idx, fieldVal});
            } else {
                rewriter.create<LLVM::CallOp>(
                    loc, TypeRange{}, SymbolRefAttr::get(ctx, "eco_store_field"),
                    ValueRange{objPtr, idx, fieldVal});
            }
        }

        // Set unboxed bitmap if non-zero.
        int64_t bitmap = op.getUnboxedBitmap();
        if (bitmap != 0) {
            auto bitmapVal = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, bitmap);
            rewriter.create<LLVM::CallOp>(
                loc, TypeRange{}, SymbolRefAttr::get(ctx, "eco_set_unboxed"),
                ValueRange{objPtr, bitmapVal});
        }

        auto result = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, objPtr);
        rewriter.replaceOp(op, result);
        return success();
    }
};

// eco.project.custom -> load from Custom.values[index]
struct CustomProjectOpLowering : public OpConversionPattern<CustomProjectOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(CustomProjectOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i8Ty = IntegerType::get(ctx, 8);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        Value input = adaptor.getContainer();
        int64_t index = op.getFieldIndex();
        auto ptr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, input);

        // Custom layout: Header (8) + ctor/unboxed (8) + values[index * 8].
        // Field at index N is at offset 16 + N * 8.
        int64_t offsetBytes = 16 + index * 8;
        auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, offsetBytes);
        auto fieldPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr,
                                                      ValueRange{offset});

        Type resultType = getTypeConverter()->convertType(op.getResult().getType());
        Value result = rewriter.create<LLVM::LoadOp>(loc, resultType, fieldPtr);
        rewriter.replaceOp(op, result);
        return success();
    }
};

// ============================================================================
// eco.string_literal -> global constant + address
// ============================================================================

struct StringLiteralOpLowering : public OpConversionPattern<StringLiteralOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(StringLiteralOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto module = op->getParentOfType<ModuleOp>();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i16Ty = IntegerType::get(ctx, 16);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        StringRef utf8Value = op.getValue();

        // Empty strings use an embedded constant rather than a heap allocation.
        if (utf8Value.empty()) {
            // ConstantKind::EmptyString = 7.
            auto result = rewriter.create<LLVM::ConstantOp>(
                loc, i64Ty, encodeConstant(7));
            rewriter.replaceOp(op, result);
            return success();
        }

        // Convert UTF-8 to UTF-16 for Elm's string representation.
        auto utf16 = utf8ToUtf16(utf8Value);

        // Generate a unique global name for this string literal.
        static int stringCounter = 0;
        std::string globalName = "__eco_str_" + std::to_string(stringCounter++);

        // Build the header with tag and size.
        // Header layout: tag(5) | color(2) | pin(1) | epoch(2) | age(2) | unboxed(3) | padding(1) | refcount(16) | size(32).
        uint64_t header = 3;  // Tag_String.
        header |= static_cast<uint64_t>(utf16.size()) << 32;

        // Create global with header + UTF-16 data.
        // Layout: [header:i64, chars:array<N x i16>].
        auto charArrayTy = LLVM::LLVMArrayType::get(i16Ty, utf16.size());
        auto structTy = LLVM::LLVMStructType::getLiteral(ctx, {i64Ty, charArrayTy});

        // Build the initializer for the global string.
        // Use APInt to handle surrogate pairs (values > 32767) correctly.
        OpBuilder::InsertionGuard guard(rewriter);
        rewriter.setInsertionPointToStart(module.getBody());

        // Create the LLVM global with the struct type.
        auto global = rewriter.create<LLVM::GlobalOp>(
            loc, structTy, /*isConstant=*/true, LLVM::Linkage::Internal,
            globalName, Attribute());

        // Initialize the global with header and character data.
        {
            Block *initBlock = rewriter.createBlock(&global.getInitializer());
            rewriter.setInsertionPointToStart(initBlock);

            // Start with an undefined struct value.
            auto undef = rewriter.create<LLVM::UndefOp>(loc, structTy);

            // Insert the header at index 0.
            auto headerVal = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, header);
            auto withHeader = rewriter.create<LLVM::InsertValueOp>(
                loc, structTy, undef, headerVal, ArrayRef<int64_t>{0});

            // Insert each UTF-16 character into the array at index 1.
            // Note: Use APInt to avoid signedness issues with surrogate pairs
            // (UTF-16 code units in 0xD800-0xDFFF range are > 32767).
            Value current = withHeader;
            for (size_t i = 0; i < utf16.size(); i++) {
                // Create APInt with 16 bits, treating value as unsigned
                llvm::APInt charInt(16, utf16[i], /*isSigned=*/false);
                auto charAttr = rewriter.getIntegerAttr(i16Ty, charInt);
                auto charVal = rewriter.create<LLVM::ConstantOp>(loc, i16Ty, charAttr);
                current = rewriter.create<LLVM::InsertValueOp>(
                    loc, structTy, current, charVal,
                    ArrayRef<int64_t>{1, static_cast<int64_t>(i)});
            }

            rewriter.create<LLVM::ReturnOp>(loc, current);
        }

        // Restore insertion point to the original operation location.
        rewriter.setInsertionPoint(op);

        // Get the address of the global and convert to tagged i64.
        auto addr = rewriter.create<LLVM::AddressOfOp>(loc, ptrTy, globalName);
        auto result = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, addr);

        rewriter.replaceOp(op, result);
        return success();
    }
};

// ============================================================================
// eco.return -> func.return (will be lowered by func-to-llvm)
// ============================================================================

struct ReturnOpLowering : public OpConversionPattern<ReturnOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ReturnOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<func::ReturnOp>(op, adaptor.getResults());
        return success();
    }
};

// ============================================================================
// eco.call -> llvm.call with tailcc
// ============================================================================

struct CallOpLowering : public OpConversionPattern<CallOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(CallOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();

        // Convert result types to LLVM types.
        SmallVector<Type> resultTypes;
        for (Type t : op.getResultTypes()) {
            resultTypes.push_back(getTypeConverter()->convertType(t));
        }

        auto callee = op.getCallee();
        if (callee) {
            // Direct call to a known function.
            // Use func.call to call func.func functions. A later pass
            // (func-to-llvm) will convert to LLVM dialect.
            auto callOp = rewriter.create<func::CallOp>(
                loc, *callee, resultTypes, adaptor.getOperands());

            rewriter.replaceOp(op, callOp.getResults());
        } else {
            // === Indirect call through closure ===

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

            auto i8Ty = IntegerType::get(ctx, 8);
            auto i64Ty = IntegerType::get(ctx, 64);
            auto ptrTy = LLVM::LLVMPointerType::get(ctx);

            // Convert closure to pointer
            Value closurePtr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, closureI64);

            // Load packed field at offset 8: [n_values:6 | max_values:6 | unboxed:52]
            auto offset8 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 8);
            auto packedPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, closurePtr,
                                                           ValueRange{offset8});
            Value packed = rewriter.create<LLVM::LoadOp>(loc, i64Ty, packedPtr);

            // Extract n_values (bits 0-5)
            auto mask6 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 0x3F);
            Value nValues = rewriter.create<LLVM::AndOp>(loc, packed, mask6);

            // Load evaluator pointer at offset 16
            auto offset16 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 16);
            auto evalPtrPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, closurePtr,
                                                            ValueRange{offset16});
            Value evaluator = rewriter.create<LLVM::LoadOp>(loc, ptrTy, evalPtrPtr);

            // Total args = n_values + remainingArity
            auto remainingConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, remainingArity);
            Value totalArgs = rewriter.create<LLVM::AddOp>(loc, nValues, remainingConst);

            // Allocate args array on stack
            Value argsArray = rewriter.create<LLVM::AllocaOp>(loc, ptrTy, i64Ty, totalArgs);

            // === Create loop to copy captured values ===
            Block *currentBlock = rewriter.getInsertionBlock();
            Region *region = currentBlock->getParent();

            // Split current block - ops after eco.call go to continuation
            Block *contBlock = rewriter.splitBlock(currentBlock, rewriter.getInsertionPoint());

            // Add block argument to continuation for the result value
            contBlock->addArgument(i64Ty, loc);

            Block *loopCheck = rewriter.createBlock(region, contBlock->getIterator());
            Block *loopBody = rewriter.createBlock(region, contBlock->getIterator());
            Block *loopDone = rewriter.createBlock(region, contBlock->getIterator());

            // Current block: jump to loop with i=0
            rewriter.setInsertionPointToEnd(currentBlock);
            auto zero = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 0);
            rewriter.create<LLVM::BrOp>(loc, ValueRange{zero}, loopCheck);

            // Loop check: if i >= n_values, exit loop
            loopCheck->addArgument(i64Ty, loc);  // %i
            Value i = loopCheck->getArgument(0);
            rewriter.setInsertionPointToStart(loopCheck);
            auto cmp = rewriter.create<LLVM::ICmpOp>(loc, LLVM::ICmpPredicate::uge, i, nValues);
            rewriter.create<LLVM::CondBrOp>(loc, cmp, loopDone, loopBody);

            // Loop body: copy closure->values[i] to args[i]
            rewriter.setInsertionPointToStart(loopBody);
            auto offset24 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 24);
            auto eight = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 8);
            auto valueOffset = rewriter.create<LLVM::MulOp>(loc, i, eight);
            auto totalOffset = rewriter.create<LLVM::AddOp>(loc, offset24, valueOffset);
            auto srcPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, closurePtr,
                                                        ValueRange{totalOffset});
            Value capturedVal = rewriter.create<LLVM::LoadOp>(loc, i64Ty, srcPtr);

            auto dstPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i64Ty, argsArray,
                                                        ValueRange{i});
            rewriter.create<LLVM::StoreOp>(loc, capturedVal, dstPtr);

            // i++, back to loop check
            auto one = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 1);
            Value iNext = rewriter.create<LLVM::AddOp>(loc, i, one);
            rewriter.create<LLVM::BrOp>(loc, ValueRange{iNext}, loopCheck);

            // Loop done: copy new arguments (unrolled since count is compile-time known)
            rewriter.setInsertionPointToStart(loopDone);
            for (size_t j = 0; j < newArgs.size(); ++j) {
                auto jConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, static_cast<int64_t>(j));
                auto idx = rewriter.create<LLVM::AddOp>(loc, nValues, jConst);
                auto dstPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i64Ty, argsArray,
                                                            ValueRange{idx});
                rewriter.create<LLVM::StoreOp>(loc, newArgs[j], dstPtr);
            }

            // Indirect call through evaluator
            // Evaluator signature: ptr @eval(ptr %args) -> ptr
            // For indirect calls, operands are [callee_ptr, args...]
            auto evalFuncTy = LLVM::LLVMFunctionType::get(ptrTy, {ptrTy});
            SmallVector<Value> callOperands;
            callOperands.push_back(evaluator);
            callOperands.push_back(argsArray);
            auto indirectCallOp = rewriter.create<LLVM::CallOp>(loc, evalFuncTy, callOperands);

            // Convert result ptr to i64
            Value result = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, indirectCallOp.getResult());

            // Branch to continuation, passing the result
            rewriter.create<LLVM::BrOp>(loc, ValueRange{result}, contBlock);

            // Replace op uses with continuation block argument
            rewriter.replaceOp(op, contBlock->getArgument(0));
        }

        return success();
    }
};

// ============================================================================
// eco.crash -> call eco_crash + unreachable
// ============================================================================

struct CrashOpLowering : public OpConversionPattern<CrashOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(CrashOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto module = op->getParentOfType<ModuleOp>();
        auto *ctx = rewriter.getContext();
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);
        auto voidTy = LLVM::LLVMVoidType::get(ctx);

        // Get or insert eco_crash declaration: void eco_crash(void* message)
        auto funcTy = LLVM::LLVMFunctionType::get(voidTy, {ptrTy});
        getOrInsertFunc(module, rewriter, "eco_crash", funcTy);

        // Convert the message from i64 (tagged pointer) back to ptr.
        Value msgPtr = rewriter.create<LLVM::IntToPtrOp>(
            loc, ptrTy, adaptor.getMessage());

        // Call eco_crash (which is [[noreturn]])
        rewriter.create<LLVM::CallOp>(
            loc, TypeRange{}, SymbolRefAttr::get(ctx, "eco_crash"),
            ValueRange{msgPtr});

        // Add unreachable since eco_crash never returns
        rewriter.create<LLVM::UnreachableOp>(loc);

        rewriter.eraseOp(op);
        return success();
    }
};

// ============================================================================
// eco.expect -> conditional crash with passthrough
// ============================================================================

struct ExpectOpLowering : public OpConversionPattern<ExpectOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ExpectOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto module = op->getParentOfType<ModuleOp>();
        auto *ctx = rewriter.getContext();
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);
        auto voidTy = LLVM::LLVMVoidType::get(ctx);

        // Get or insert eco_crash declaration.
        auto funcTy = LLVM::LLVMFunctionType::get(voidTy, {ptrTy});
        getOrInsertFunc(module, rewriter, "eco_crash", funcTy);

        // Get parent block.
        Block *currentBlock = op->getBlock();

        // Split the block at this operation.
        Block *continueBlock = rewriter.splitBlock(currentBlock, op->getIterator());
        Block *crashBlock = rewriter.createBlock(continueBlock);

        // In crash block: call eco_crash and unreachable.
        rewriter.setInsertionPointToStart(crashBlock);
        Value msgPtr = rewriter.create<LLVM::IntToPtrOp>(
            loc, ptrTy, adaptor.getMessage());
        rewriter.create<LLVM::CallOp>(
            loc, TypeRange{}, SymbolRefAttr::get(ctx, "eco_crash"),
            ValueRange{msgPtr});
        rewriter.create<LLVM::UnreachableOp>(loc);

        // In current block: conditional branch - if true continue, else crash.
        rewriter.setInsertionPointToEnd(currentBlock);
        rewriter.create<cf::CondBranchOp>(loc, adaptor.getCondition(),
                                          continueBlock, crashBlock);

        // Replace uses of the expect result with the passthrough value.
        rewriter.setInsertionPointToStart(continueBlock);
        rewriter.replaceOp(op, adaptor.getPassthrough());

        return success();
    }
};

// ============================================================================
// eco.global -> LLVM global variable declaration
// ============================================================================

struct GlobalOpLowering : public OpConversionPattern<GlobalOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(GlobalOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);

        // eco.value becomes i64 (tagged pointer).
        // Create an LLVM global initialized to 0 (null).
        auto zeroAttr = rewriter.getI64IntegerAttr(0);

        rewriter.replaceOpWithNewOp<LLVM::GlobalOp>(
            op,
            i64Ty,
            /*isConstant=*/false,
            LLVM::Linkage::Internal,
            op.getSymName(),
            zeroAttr);

        return success();
    }
};

// ============================================================================
// eco.load_global -> LLVM load from global address
// ============================================================================

struct LoadGlobalOpLowering : public OpConversionPattern<LoadGlobalOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(LoadGlobalOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        // Get address of global.
        auto globalAddr = rewriter.create<LLVM::AddressOfOp>(
            loc, ptrTy, op.getGlobal());

        // Load the value (i64 tagged pointer).
        auto loadedValue = rewriter.create<LLVM::LoadOp>(loc, i64Ty, globalAddr);

        rewriter.replaceOp(op, loadedValue.getResult());
        return success();
    }
};

// ============================================================================
// eco.store_global -> LLVM store to global address
// ============================================================================

struct StoreGlobalOpLowering : public OpConversionPattern<StoreGlobalOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(StoreGlobalOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        // Get address of global.
        auto globalAddr = rewriter.create<LLVM::AddressOfOp>(
            loc, ptrTy, op.getGlobal());

        // Store the value (already converted to i64).
        rewriter.create<LLVM::StoreOp>(loc, adaptor.getValue(), globalAddr);

        rewriter.eraseOp(op);
        return success();
    }
};

// ============================================================================
// eco.case -> cf.switch on constructor tag
// ============================================================================

// ============================================================================
// eco.get_tag -> Extract constructor tag from ADT value
// ============================================================================

struct GetTagOpLowering : public OpConversionPattern<GetTagOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(GetTagOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i32Ty = IntegerType::get(ctx, 32);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);
        auto i8Ty = IntegerType::get(ctx, 8);

        // Extract constructor tag from value.
        // For Custom objects: ctor field is at offset 8, first 16 bits.
        // Memory layout: [Header (8 bytes)][ctor:16 | unboxed:48][values...]
        Value value = adaptor.getValue();
        auto ptr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, value);

        // Load the ctor field at offset 8 (after the Header).
        auto offset8 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 8);
        auto ctorPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr,
                                                    ValueRange{offset8});
        // Load as i32 (ctor is 16 bits but we use i32 for switch compatibility).
        auto ctorTag = rewriter.create<LLVM::LoadOp>(loc, i32Ty, ctorPtr);

        rewriter.replaceOp(op, ctorTag);
        return success();
    }
};

// ============================================================================
// eco.case -> cf.switch
// ============================================================================

struct CaseOpLowering : public OpConversionPattern<CaseOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(CaseOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i32Ty = IntegerType::get(ctx, 32);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);
        auto i8Ty = IntegerType::get(ctx, 8);

        // Get the parent block and function.
        Block *currentBlock = op->getBlock();
        Region *parentRegion = currentBlock->getParent();

        // Extract constructor tag from scrutinee.
        // For Custom objects: ctor field is at offset 8, first 16 bits.
        // Memory layout: [Header (8 bytes)][ctor:16 | unboxed:48][values...]
        //
        // Special handling for embedded constants:
        // - Embedded constants have bits 40-43 non-zero (constant field)
        // - Nil constant (constant field = 5) should map to tag 0 for list pattern matching
        // - We must NOT load from embedded constants as they're not valid pointers
        //
        // Use conditional branching to avoid loading from invalid addresses.
        Value scrutinee = adaptor.getScrutinee();
        Value ctorTag;

        // Check if scrutinee is i1 (boolean) - if so, skip embedded constant logic
        // since i1 can only be 0 or 1 and cannot be an embedded constant
        auto scrutineeType = scrutinee.getType();
        bool isI1Scrutinee = scrutineeType.isInteger(1);

        if (isI1Scrutinee) {
            // For i1 scrutinees, just zero-extend to i32 for the switch
            ctorTag = rewriter.create<LLVM::ZExtOp>(loc, i32Ty, scrutinee);
        } else {
            // Check if this is an embedded constant: (scrutinee >> 40) & 0xF != 0
            auto shift40 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 40);
            auto shifted = rewriter.create<LLVM::LShrOp>(loc, scrutinee, shift40);
            auto maskF = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 0xF);
            auto constField = rewriter.create<LLVM::AndOp>(loc, shifted, maskF);
            auto zero64 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 0);
            auto isConstant = rewriter.create<LLVM::ICmpOp>(loc, LLVM::ICmpPredicate::ne,
                                                             constField, zero64);

            // Create blocks for constant vs heap case
            Block *constBlock = rewriter.createBlock(parentRegion);
            Block *heapBlock = rewriter.createBlock(parentRegion);
            Block *tagMergeBlock = rewriter.createBlock(parentRegion);
            tagMergeBlock->addArgument(i32Ty, loc);  // phi for ctorTag

            // Branch based on whether it's a constant
            rewriter.setInsertionPointToEnd(currentBlock);
            rewriter.create<cf::CondBranchOp>(loc, isConstant, constBlock, heapBlock);

            // Constant case: map Nil (5) to tag 0, others keep their value
            rewriter.setInsertionPointToStart(constBlock);
            auto nilConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 5);
            auto isNil = rewriter.create<LLVM::ICmpOp>(loc, LLVM::ICmpPredicate::eq,
                                                        constField, nilConst);
            auto tag0_64 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 0);
            auto constTag64 = rewriter.create<LLVM::SelectOp>(loc, isNil, tag0_64, constField);
            auto constTag = rewriter.create<LLVM::TruncOp>(loc, i32Ty, constTag64);
            rewriter.create<cf::BranchOp>(loc, tagMergeBlock, ValueRange{constTag});

            // Heap case: load ctor from offset 8
            rewriter.setInsertionPointToStart(heapBlock);
            auto ptr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, scrutinee);
            auto offset8 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 8);
            auto ctorPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr,
                                                        ValueRange{offset8});
            auto ctorFromHeap = rewriter.create<LLVM::LoadOp>(loc, i32Ty, ctorPtr);
            rewriter.create<cf::BranchOp>(loc, tagMergeBlock, ValueRange{ctorFromHeap});

            // Continue from merge block with phi result
            rewriter.setInsertionPointToStart(tagMergeBlock);
            ctorTag = tagMergeBlock->getArgument(0);

            // Update currentBlock to be the merge block for subsequent code
            currentBlock = tagMergeBlock;
        }

        // Save the original block containing the CaseOp.
        // We need this to correctly move operations that follow the CaseOp.
        Block *originalOpBlock = op->getBlock();

        // Create a merge block after the case (where all branches converge).
        Block *mergeBlock = rewriter.createBlock(parentRegion);
        mergeBlock->moveBefore(currentBlock->getNextNode());

        // Get the tags array.
        ArrayRef<int64_t> tags = op.getTags();
        auto alternatives = op.getAlternatives();

        // Create case blocks and collect switch cases.
        SmallVector<int64_t> caseValues;
        SmallVector<Block *> caseBlocks;

        for (size_t i = 0; i < alternatives.size(); ++i) {
            Block *caseBlock = rewriter.createBlock(parentRegion);
            caseBlock->moveBefore(mergeBlock);
            caseValues.push_back(tags[i]);
            caseBlocks.push_back(caseBlock);
        }

        // Move operations after eco.case to the merge block first.
        // This ensures the switch becomes the terminator.
        // IMPORTANT: Use originalOpBlock (where CaseOp is) not currentBlock (tagMergeBlock).
        {
            auto opsToMove = llvm::make_early_inc_range(
                llvm::make_range(std::next(Block::iterator(op)), originalOpBlock->end()));
            for (Operation &opToMove : opsToMove) {
                opToMove.moveBefore(mergeBlock, mergeBlock->end());
            }
        }

        // Insert switch at the end of current block (after moving trailing ops).
        rewriter.setInsertionPointToEnd(currentBlock);

        // Build switch case values as int32.
        SmallVector<int32_t> caseValuesI32;
        for (int64_t v : caseValues) {
            caseValuesI32.push_back(static_cast<int32_t>(v));
        }

        // Build empty operand ranges for each case.
        SmallVector<ValueRange> caseOperands(caseBlocks.size(), ValueRange{});

        // Use cf.switch for control flow.
        // Default case goes to merge block (unreachable in well-formed programs).
        rewriter.create<cf::SwitchOp>(
            loc, ctorTag, mergeBlock, ValueRange{},
            ArrayRef<int32_t>(caseValuesI32),
            caseBlocks, caseOperands);

        // Get the original scrutinee (before type conversion) for use replacement.
        // Note: Use getOperand(0) instead of getScrutinee() to avoid type cast
        // issues when CaseOp is inside a joinpoint body where types are converted.
        Value originalScrutinee = op->getOperand(0);

        // Now inline each alternative region into its case block.
        // We MOVE operations instead of cloning to handle nested CaseOps correctly.
        // Cloning doesn't apply IRMapping to operations inside nested regions,
        // which causes "operation destroyed but still has uses" errors.
        for (size_t i = 0; i < alternatives.size(); ++i) {
            Region &altRegion = alternatives[i];
            Block *caseBlock = caseBlocks[i];

            if (altRegion.empty()) {
                // Empty region - just add branch to merge block.
                rewriter.setInsertionPointToEnd(caseBlock);
                rewriter.create<cf::BranchOp>(loc, mergeBlock);
                continue;
            }

            Block &entryBlock = altRegion.front();

            // Move all operations from the region block to the case block.
            // This preserves SSA references correctly, even for nested CaseOps.
            rewriter.inlineBlockBefore(&entryBlock, caseBlock, caseBlock->end());
        }

        // After inlining all regions, replace uses of original scrutinee with
        // converted scrutinee in all case blocks.
        for (Block *caseBlock : caseBlocks) {
            for (Operation &op : *caseBlock) {
                op.replaceUsesOfWith(originalScrutinee, scrutinee);
            }
        }

        // Now fix up terminators: replace eco.return with cf.br to merge block.
        for (Block *caseBlock : caseBlocks) {
            if (caseBlock->empty())
                continue;

            Operation *term = caseBlock->getTerminator();
            if (isa<ReturnOp>(term)) {
                rewriter.setInsertionPoint(term);
                rewriter.create<cf::BranchOp>(loc, mergeBlock);
                rewriter.eraseOp(term);
            }
            // JumpOps are handled by JumpOpLowering - leave them alone.
        }

        // Safe to erase - regions are now empty (operations were moved out).
        rewriter.eraseOp(op);
        return success();
    }
};

// ============================================================================
// eco.joinpoint / eco.jump -> cf blocks and branches
//
// Strategy: We track joinpoint blocks using a module-level attribute map.
// When we see a joinpoint, we create a block and store its "address".
// When we see a jump, we look up the target block and branch to it.
// ============================================================================

// Global map for joinpoint blocks (populated during lowering).
// This is a simplification - in production we'd use a proper pass-local state.
static llvm::DenseMap<int64_t, Block*> joinpointBlocks;

// Forward declaration for recursive helper
static void lowerJoinpointRegion(
    Block &sourceBlock, Block *targetBlock, Block *exitBlock,
    IRMapping &mapping, ConversionPatternRewriter &rewriter,
    const TypeConverter *typeConverter, bool isBodyRegion);

// Helper to lower a nested JoinpointOp found during region inlining
static void lowerNestedJoinpoint(
    JoinpointOp nestedJP, Block *outerExitBlock,
    IRMapping &mapping, ConversionPatternRewriter &rewriter,
    const TypeConverter *typeConverter) {

    auto loc = nestedJP.getLoc();
    int64_t jpId = nestedJP.getId();

    // Get the current insertion point's block and parent region
    Block *insertBlock = rewriter.getInsertionBlock();
    Region *parentRegion = insertBlock->getParent();

    // Create exit block for nested joinpoint (code after it flows here)
    // NOTE: createBlock changes the insertion point, so we must save insertBlock first
    Block *nestedExitBlock = rewriter.createBlock(parentRegion);

    // Create the joinpoint body block
    Block *jpBlock = rewriter.createBlock(parentRegion);
    jpBlock->moveBefore(nestedExitBlock);

    // Add block arguments matching the body region's entry block
    Region &bodyRegion = nestedJP.getBody();
    Block &bodyEntry = bodyRegion.front();
    for (BlockArgument arg : bodyEntry.getArguments()) {
        Type convertedType = typeConverter->convertType(arg.getType());
        jpBlock->addArgument(convertedType, loc);
    }

    // Store the block in our map for eco.jump to find
    joinpointBlocks[jpId] = jpBlock;

    // Create continuation block
    Block *contBlock = rewriter.createBlock(parentRegion);
    contBlock->moveBefore(jpBlock);

    // Branch from the ORIGINAL insertion block (not contBlock!) to continuation
    // This is the control flow: code before nested JP -> continuation -> body -> exit
    rewriter.setInsertionPointToEnd(insertBlock);
    rewriter.create<cf::BranchOp>(loc, contBlock);

    // Create mapping for body region arguments
    IRMapping bodyMapping(mapping);
    for (auto [oldArg, newArg] : llvm::zip(bodyEntry.getArguments(),
                                            jpBlock->getArguments())) {
        bodyMapping.map(oldArg, newArg);
    }

    // Lower body region into jpBlock
    rewriter.setInsertionPointToEnd(jpBlock);
    lowerJoinpointRegion(bodyEntry, jpBlock, nestedExitBlock, bodyMapping,
                         rewriter, typeConverter, /*isBodyRegion=*/true);

    // Lower continuation region into contBlock
    rewriter.setInsertionPointToEnd(contBlock);
    Region &contRegion = nestedJP.getContinuation();
    if (!contRegion.empty()) {
        Block &contEntry = contRegion.front();
        IRMapping contMapping(mapping);
        lowerJoinpointRegion(contEntry, contBlock, nestedExitBlock, contMapping,
                             rewriter, typeConverter, /*isBodyRegion=*/false);
    }

    // Set insertion point to nestedExitBlock for any operations that follow
    // the nested joinpoint in the source. The caller will add those operations
    // (and their terminators) here.
    rewriter.setInsertionPointToEnd(nestedExitBlock);
}

// Helper to lower operations from a region block into a target block
static void lowerJoinpointRegion(
    Block &sourceBlock, Block *targetBlock, Block *exitBlock,
    IRMapping &mapping, ConversionPatternRewriter &rewriter,
    const TypeConverter *typeConverter, bool isBodyRegion) {

    auto loc = sourceBlock.getParentOp()->getLoc();

    for (Operation &innerOp : llvm::make_early_inc_range(sourceBlock)) {
        if (isa<ReturnOp>(&innerOp)) {
            // eco.return exits to the exit block
            rewriter.create<cf::BranchOp>(loc, exitBlock);
        } else if (isa<JumpOp>(&innerOp)) {
            // eco.jump - clone with mapping (will be converted by JumpOpLowering)
            rewriter.clone(innerOp, mapping);
        } else if (auto nestedJP = dyn_cast<JoinpointOp>(&innerOp)) {
            // Handle nested joinpoint recursively
            lowerNestedJoinpoint(nestedJP, exitBlock, mapping, rewriter, typeConverter);
        } else {
            // Clone other ops with mapping
            Operation *cloned = rewriter.clone(innerOp, mapping);
            for (auto [oldResult, newResult] :
                 llvm::zip(innerOp.getResults(), cloned->getResults())) {
                mapping.map(oldResult, newResult);
            }
        }
    }
}

struct JoinpointOpLowering : public OpConversionPattern<JoinpointOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(JoinpointOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        int64_t jpId = op.getId();

        Block *currentBlock = op->getBlock();
        Region *parentRegion = currentBlock->getParent();

        // Create the joinpoint body block with arguments from the body region.
        Region &bodyRegion = op.getBody();
        Block &bodyEntry = bodyRegion.front();

        // Create a block for code after the joinpoint (where eco.return exits to).
        Block *exitBlock = rewriter.createBlock(parentRegion);
        exitBlock->moveBefore(currentBlock->getNextNode());

        // Move operations after eco.joinpoint to the exit block.
        {
            auto opsToMove = llvm::make_early_inc_range(
                llvm::make_range(std::next(Block::iterator(op)), currentBlock->end()));
            for (Operation &opToMove : opsToMove) {
                opToMove.moveBefore(exitBlock, exitBlock->end());
            }
        }

        // Create a new block for the joinpoint body.
        Block *jpBlock = rewriter.createBlock(parentRegion);
        jpBlock->moveBefore(exitBlock);

        // Add block arguments matching the body region's entry block.
        for (BlockArgument arg : bodyEntry.getArguments()) {
            Type convertedType = getTypeConverter()->convertType(arg.getType());
            jpBlock->addArgument(convertedType, loc);
        }

        // Store the block in our map for eco.jump to find.
        joinpointBlocks[jpId] = jpBlock;

        // Create a block for the continuation (entry point).
        Block *contBlock = rewriter.createBlock(parentRegion);
        contBlock->moveBefore(jpBlock);

        // At current position, branch to continuation.
        rewriter.setInsertionPointToEnd(currentBlock);
        rewriter.create<cf::BranchOp>(loc, contBlock);

        // Create a mapping from old block arguments to new ones.
        IRMapping mapping;
        for (auto [oldArg, newArg] : llvm::zip(bodyEntry.getArguments(),
                                                jpBlock->getArguments())) {
            mapping.map(oldArg, newArg);
        }

        // Lower body region into joinpoint block (handles nested joinpoints)
        rewriter.setInsertionPointToEnd(jpBlock);
        lowerJoinpointRegion(bodyEntry, jpBlock, exitBlock, mapping,
                             rewriter, getTypeConverter(), /*isBodyRegion=*/true);

        // Lower continuation region into continuation block
        rewriter.setInsertionPointToEnd(contBlock);
        Region &contRegion = op.getContinuation();
        if (!contRegion.empty()) {
            Block &contEntry = contRegion.front();
            IRMapping contMapping;
            lowerJoinpointRegion(contEntry, contBlock, exitBlock, contMapping,
                                 rewriter, getTypeConverter(), /*isBodyRegion=*/false);
        }

        rewriter.eraseOp(op);
        return success();
    }
};

struct JumpOpLowering : public OpConversionPattern<JumpOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(JumpOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        int64_t targetId = op.getTarget();

        // Look up the target joinpoint block.
        auto it = joinpointBlocks.find(targetId);
        if (it == joinpointBlocks.end()) {
            return op.emitError("jump to unknown joinpoint id ") << targetId;
        }

        Block *targetBlock = it->second;

        // Branch to the joinpoint block with converted arguments.
        rewriter.replaceOpWithNewOp<cf::BranchOp>(op, targetBlock,
                                                   adaptor.getArgs());
        return success();
    }
};

// ============================================================================
// 9.1 Integer Arithmetic Lowerings
// ============================================================================

struct IntAddOpLowering : public OpConversionPattern<IntAddOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntAddOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::AddIOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct IntSubOpLowering : public OpConversionPattern<IntSubOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntSubOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::SubIOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct IntMulOpLowering : public OpConversionPattern<IntMulOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntMulOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::MulIOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct IntDivOpLowering : public OpConversionPattern<IntDivOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntDivOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);

        Value lhs = adaptor.getLhs();
        Value rhs = adaptor.getRhs();

        // Check if rhs == 0
        auto zero = rewriter.create<arith::ConstantIntOp>(loc, i64Ty, 0);
        auto isZero = rewriter.create<arith::CmpIOp>(
            loc, arith::CmpIPredicate::eq, rhs, zero);

        // Use select: if rhs == 0, result is 0, else do division
        // But we need to avoid divide by zero in the division itself.
        // Use select on rhs to make it 1 when zero, then select on result.
        auto one = rewriter.create<arith::ConstantIntOp>(loc, i64Ty, 1);
        auto safeRhs = rewriter.create<arith::SelectOp>(loc, isZero, one, rhs);
        auto divResult = rewriter.create<arith::DivSIOp>(loc, lhs, safeRhs);
        auto result = rewriter.create<arith::SelectOp>(loc, isZero, zero, divResult);

        rewriter.replaceOp(op, result.getResult());
        return success();
    }
};

struct IntModByOpLowering : public OpConversionPattern<IntModByOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntModByOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);

        Value modulus = adaptor.getModulus();
        Value x = adaptor.getX();

        // Check if modulus == 0
        auto zero = rewriter.create<arith::ConstantIntOp>(loc, i64Ty, 0);
        auto isZero = rewriter.create<arith::CmpIOp>(
            loc, arith::CmpIPredicate::eq, modulus, zero);

        // Floored modulo: result = x - floor(x / modulus) * modulus
        // Or equivalently: r = x % modulus; if (r != 0 && (r < 0) != (modulus < 0)) r += modulus
        auto one = rewriter.create<arith::ConstantIntOp>(loc, i64Ty, 1);
        auto safeModulus = rewriter.create<arith::SelectOp>(loc, isZero, one, modulus);

        // Truncated remainder
        auto truncRem = rewriter.create<arith::RemSIOp>(loc, x, safeModulus);

        // Check if we need to adjust for floored modulo
        // Adjustment needed when: truncRem != 0 && sign(truncRem) != sign(modulus)
        auto remIsZero = rewriter.create<arith::CmpIOp>(
            loc, arith::CmpIPredicate::eq, truncRem, zero);
        auto remNeg = rewriter.create<arith::CmpIOp>(
            loc, arith::CmpIPredicate::slt, truncRem, zero);
        auto modNeg = rewriter.create<arith::CmpIOp>(
            loc, arith::CmpIPredicate::slt, safeModulus, zero);
        auto signsDiffer = rewriter.create<arith::XOrIOp>(loc, remNeg, modNeg);
        // needsAdjust = !remIsZero && signsDiffer
        auto i1Ty = IntegerType::get(ctx, 1);
        auto trueVal = rewriter.create<arith::ConstantIntOp>(loc, i1Ty, 1);
        auto notRemIsZero = rewriter.create<arith::XOrIOp>(loc, remIsZero, trueVal);
        auto needsAdjust = rewriter.create<arith::AndIOp>(loc, notRemIsZero, signsDiffer);

        // adjusted = truncRem + modulus
        auto adjusted = rewriter.create<arith::AddIOp>(loc, truncRem, safeModulus);
        auto flooredRem = rewriter.create<arith::SelectOp>(loc, needsAdjust, adjusted, truncRem);

        // Return 0 if modulus was 0
        auto result = rewriter.create<arith::SelectOp>(loc, isZero, zero, flooredRem);

        rewriter.replaceOp(op, result.getResult());
        return success();
    }
};

struct IntRemainderByOpLowering : public OpConversionPattern<IntRemainderByOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntRemainderByOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);

        Value divisor = adaptor.getDivisor();
        Value x = adaptor.getX();

        // Check if divisor == 0
        auto zero = rewriter.create<arith::ConstantIntOp>(loc, i64Ty, 0);
        auto isZero = rewriter.create<arith::CmpIOp>(
            loc, arith::CmpIPredicate::eq, divisor, zero);

        // Truncated remainder (arith.remsi already does truncated)
        auto one = rewriter.create<arith::ConstantIntOp>(loc, i64Ty, 1);
        auto safeDivisor = rewriter.create<arith::SelectOp>(loc, isZero, one, divisor);
        auto truncRem = rewriter.create<arith::RemSIOp>(loc, x, safeDivisor);

        // Return 0 if divisor was 0
        auto result = rewriter.create<arith::SelectOp>(loc, isZero, zero, truncRem);

        rewriter.replaceOp(op, result.getResult());
        return success();
    }
};

struct IntNegateOpLowering : public OpConversionPattern<IntNegateOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntNegateOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);

        // negate(x) = 0 - x
        auto zero = rewriter.create<arith::ConstantIntOp>(loc, i64Ty, 0);
        rewriter.replaceOpWithNewOp<arith::SubIOp>(op, zero, adaptor.getValue());
        return success();
    }
};

struct IntAbsOpLowering : public OpConversionPattern<IntAbsOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntAbsOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);

        Value x = adaptor.getValue();
        auto zero = rewriter.create<arith::ConstantIntOp>(loc, i64Ty, 0);
        auto isNeg = rewriter.create<arith::CmpIOp>(
            loc, arith::CmpIPredicate::slt, x, zero);
        auto negated = rewriter.create<arith::SubIOp>(loc, zero, x);
        rewriter.replaceOpWithNewOp<arith::SelectOp>(op, isNeg, negated, x);
        return success();
    }
};

struct IntPowOpLowering : public OpConversionPattern<IntPowOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntPowOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto module = op->getParentOfType<ModuleOp>();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);

        Value base = adaptor.getBase();
        Value exp = adaptor.getExp();

        // Check if exp < 0
        auto zero = rewriter.create<arith::ConstantIntOp>(loc, i64Ty, 0);
        auto expNeg = rewriter.create<arith::CmpIOp>(
            loc, arith::CmpIPredicate::slt, exp, zero);

        // Call runtime helper for integer power.
        auto funcTy = LLVM::LLVMFunctionType::get(i64Ty, {i64Ty, i64Ty});
        getOrInsertFunc(module, rewriter, "eco_int_pow", funcTy);

        auto call = rewriter.create<LLVM::CallOp>(
            loc, i64Ty, SymbolRefAttr::get(ctx, "eco_int_pow"),
            ValueRange{base, exp});

        // Return 0 if exp was negative
        auto result = rewriter.create<arith::SelectOp>(loc, expNeg, zero, call.getResult());

        rewriter.replaceOp(op, result.getResult());
        return success();
    }
};

// ============================================================================
// 9.2 Float Arithmetic Lowerings
// ============================================================================

struct FloatAddOpLowering : public OpConversionPattern<FloatAddOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatAddOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::AddFOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct FloatSubOpLowering : public OpConversionPattern<FloatSubOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatSubOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::SubFOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct FloatMulOpLowering : public OpConversionPattern<FloatMulOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatMulOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::MulFOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct FloatDivOpLowering : public OpConversionPattern<FloatDivOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatDivOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        // IEEE 754 division handles divide-by-zero naturally (returns inf/nan)
        rewriter.replaceOpWithNewOp<arith::DivFOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct FloatNegateOpLowering : public OpConversionPattern<FloatNegateOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatNegateOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::NegFOp>(op, adaptor.getValue());
        return success();
    }
};

struct FloatAbsOpLowering : public OpConversionPattern<FloatAbsOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatAbsOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<LLVM::FAbsOp>(op, adaptor.getValue());
        return success();
    }
};

struct FloatPowOpLowering : public OpConversionPattern<FloatPowOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatPowOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<LLVM::PowOp>(op, adaptor.getBase(), adaptor.getExp());
        return success();
    }
};

struct FloatSqrtOpLowering : public OpConversionPattern<FloatSqrtOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatSqrtOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<LLVM::SqrtOp>(op, adaptor.getValue());
        return success();
    }
};

// ============================================================================
// 9.2b Trigonometric Function Lowerings
// ============================================================================

struct FloatSinOpLowering : public OpConversionPattern<FloatSinOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatSinOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<LLVM::SinOp>(op, adaptor.getValue());
        return success();
    }
};

struct FloatCosOpLowering : public OpConversionPattern<FloatCosOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatCosOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<LLVM::CosOp>(op, adaptor.getValue());
        return success();
    }
};

struct FloatTanOpLowering : public OpConversionPattern<FloatTanOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatTanOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        // tan(x) = sin(x) / cos(x)
        auto loc = op.getLoc();
        auto sinVal = rewriter.create<LLVM::SinOp>(loc, adaptor.getValue());
        auto cosVal = rewriter.create<LLVM::CosOp>(loc, adaptor.getValue());
        rewriter.replaceOpWithNewOp<arith::DivFOp>(op, sinVal, cosVal);
        return success();
    }
};

struct FloatAsinOpLowering : public OpConversionPattern<FloatAsinOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatAsinOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto module = op->getParentOfType<ModuleOp>();
        auto f64Ty = Float64Type::get(ctx);

        // Call libm asin function
        auto funcTy = LLVM::LLVMFunctionType::get(f64Ty, {f64Ty});
        getOrInsertFunc(module, rewriter, "asin", funcTy);

        auto call = rewriter.create<LLVM::CallOp>(
            loc, f64Ty, SymbolRefAttr::get(ctx, "asin"),
            ValueRange{adaptor.getValue()});
        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

struct FloatAcosOpLowering : public OpConversionPattern<FloatAcosOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatAcosOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto module = op->getParentOfType<ModuleOp>();
        auto f64Ty = Float64Type::get(ctx);

        // Call libm acos function
        auto funcTy = LLVM::LLVMFunctionType::get(f64Ty, {f64Ty});
        getOrInsertFunc(module, rewriter, "acos", funcTy);

        auto call = rewriter.create<LLVM::CallOp>(
            loc, f64Ty, SymbolRefAttr::get(ctx, "acos"),
            ValueRange{adaptor.getValue()});
        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

struct FloatAtanOpLowering : public OpConversionPattern<FloatAtanOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatAtanOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto module = op->getParentOfType<ModuleOp>();
        auto f64Ty = Float64Type::get(ctx);

        // Call libm atan function
        auto funcTy = LLVM::LLVMFunctionType::get(f64Ty, {f64Ty});
        getOrInsertFunc(module, rewriter, "atan", funcTy);

        auto call = rewriter.create<LLVM::CallOp>(
            loc, f64Ty, SymbolRefAttr::get(ctx, "atan"),
            ValueRange{adaptor.getValue()});
        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

struct FloatAtan2OpLowering : public OpConversionPattern<FloatAtan2Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatAtan2Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto module = op->getParentOfType<ModuleOp>();
        auto f64Ty = Float64Type::get(ctx);

        // Call libm atan2 function
        auto funcTy = LLVM::LLVMFunctionType::get(f64Ty, {f64Ty, f64Ty});
        getOrInsertFunc(module, rewriter, "atan2", funcTy);

        auto call = rewriter.create<LLVM::CallOp>(
            loc, f64Ty, SymbolRefAttr::get(ctx, "atan2"),
            ValueRange{adaptor.getY(), adaptor.getX()});
        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

struct FloatLogOpLowering : public OpConversionPattern<FloatLogOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatLogOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<LLVM::LogOp>(op, adaptor.getValue());
        return success();
    }
};

// ============================================================================
// 9.2c Float Classification Lowerings
// ============================================================================

struct FloatIsNaNOpLowering : public OpConversionPattern<FloatIsNaNOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatIsNaNOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        // NaN is the only value where x != x (unordered comparison with itself returns true)
        rewriter.replaceOpWithNewOp<arith::CmpFOp>(
            op, arith::CmpFPredicate::UNO, adaptor.getValue(), adaptor.getValue());
        return success();
    }
};

struct FloatIsInfiniteOpLowering : public OpConversionPattern<FloatIsInfiniteOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatIsInfiniteOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto f64Ty = Float64Type::get(ctx);

        // Check if |x| == infinity
        auto absVal = rewriter.create<LLVM::FAbsOp>(loc, adaptor.getValue());
        auto inf = rewriter.create<arith::ConstantOp>(
            loc, f64Ty, rewriter.getF64FloatAttr(std::numeric_limits<double>::infinity()));
        rewriter.replaceOpWithNewOp<arith::CmpFOp>(
            op, arith::CmpFPredicate::OEQ, absVal, inf);
        return success();
    }
};

// ============================================================================
// 9.3 Type Conversion Lowerings
// ============================================================================

struct IntToFloatOpLowering : public OpConversionPattern<IntToFloatOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntToFloatOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::SIToFPOp>(
            op, Float64Type::get(rewriter.getContext()), adaptor.getValue());
        return success();
    }
};

struct FloatRoundOpLowering : public OpConversionPattern<FloatRoundOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatRoundOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);

        // Round to nearest, ties away from zero (Elm's semantics)
        auto rounded = rewriter.create<LLVM::RoundOp>(loc, adaptor.getValue());
        rewriter.replaceOpWithNewOp<arith::FPToSIOp>(op, i64Ty, rounded);
        return success();
    }
};

struct FloatFloorOpLowering : public OpConversionPattern<FloatFloorOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatFloorOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);

        auto floored = rewriter.create<LLVM::FFloorOp>(loc, adaptor.getValue());
        rewriter.replaceOpWithNewOp<arith::FPToSIOp>(op, i64Ty, floored);
        return success();
    }
};

struct FloatCeilingOpLowering : public OpConversionPattern<FloatCeilingOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatCeilingOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);

        auto ceiled = rewriter.create<LLVM::FCeilOp>(loc, adaptor.getValue());
        rewriter.replaceOpWithNewOp<arith::FPToSIOp>(op, i64Ty, ceiled);
        return success();
    }
};

struct FloatTruncateOpLowering : public OpConversionPattern<FloatTruncateOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatTruncateOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);

        // FPToSIOp inherently truncates toward zero
        rewriter.replaceOpWithNewOp<arith::FPToSIOp>(op, i64Ty, adaptor.getValue());
        return success();
    }
};

// ============================================================================
// 9.4 Comparison Lowerings
// ============================================================================

// Integer comparisons - lower to arith.cmpi with signed predicates

struct IntLtOpLowering : public OpConversionPattern<IntLtOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntLtOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::CmpIOp>(
            op, arith::CmpIPredicate::slt, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct IntLeOpLowering : public OpConversionPattern<IntLeOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntLeOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::CmpIOp>(
            op, arith::CmpIPredicate::sle, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct IntGtOpLowering : public OpConversionPattern<IntGtOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntGtOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::CmpIOp>(
            op, arith::CmpIPredicate::sgt, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct IntGeOpLowering : public OpConversionPattern<IntGeOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntGeOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::CmpIOp>(
            op, arith::CmpIPredicate::sge, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct IntEqOpLowering : public OpConversionPattern<IntEqOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntEqOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::CmpIOp>(
            op, arith::CmpIPredicate::eq, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct IntNeOpLowering : public OpConversionPattern<IntNeOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntNeOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::CmpIOp>(
            op, arith::CmpIPredicate::ne, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

// Float comparisons - lower to arith.cmpf with ordered predicates
// Ordered comparisons return false if either operand is NaN

struct FloatLtOpLowering : public OpConversionPattern<FloatLtOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatLtOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::CmpFOp>(
            op, arith::CmpFPredicate::OLT, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct FloatLeOpLowering : public OpConversionPattern<FloatLeOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatLeOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::CmpFOp>(
            op, arith::CmpFPredicate::OLE, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct FloatGtOpLowering : public OpConversionPattern<FloatGtOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatGtOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::CmpFOp>(
            op, arith::CmpFPredicate::OGT, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct FloatGeOpLowering : public OpConversionPattern<FloatGeOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatGeOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::CmpFOp>(
            op, arith::CmpFPredicate::OGE, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct FloatEqOpLowering : public OpConversionPattern<FloatEqOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatEqOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::CmpFOp>(
            op, arith::CmpFPredicate::OEQ, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct FloatNeOpLowering : public OpConversionPattern<FloatNeOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatNeOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::CmpFOp>(
            op, arith::CmpFPredicate::ONE, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct IntMinOpLowering : public OpConversionPattern<IntMinOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntMinOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::MinSIOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct IntMaxOpLowering : public OpConversionPattern<IntMaxOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntMaxOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::MaxSIOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct FloatMinOpLowering : public OpConversionPattern<FloatMinOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatMinOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        // minnum propagates NaN if both inputs are NaN, otherwise returns non-NaN
        // For proper NaN propagation we use minimumnum which propagates NaN
        rewriter.replaceOpWithNewOp<LLVM::MinNumOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct FloatMaxOpLowering : public OpConversionPattern<FloatMaxOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(FloatMaxOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<LLVM::MaxNumOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

// ============================================================================
// 9.5 Bitwise Lowerings
// ============================================================================

struct IntAndOpLowering : public OpConversionPattern<IntAndOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntAndOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::AndIOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct IntOrOpLowering : public OpConversionPattern<IntOrOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntOrOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::OrIOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct IntXorOpLowering : public OpConversionPattern<IntXorOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntXorOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::XOrIOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct IntComplementOpLowering : public OpConversionPattern<IntComplementOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntComplementOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);

        // complement(x) = x XOR -1 (all bits set)
        auto allOnes = rewriter.create<arith::ConstantIntOp>(loc, i64Ty, -1);
        rewriter.replaceOpWithNewOp<arith::XOrIOp>(op, adaptor.getValue(), allOnes);
        return success();
    }
};

struct IntShiftLeftOpLowering : public OpConversionPattern<IntShiftLeftOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntShiftLeftOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        // Elm: shiftLeftBy amount value
        rewriter.replaceOpWithNewOp<arith::ShLIOp>(op, adaptor.getValue(), adaptor.getAmount());
        return success();
    }
};

struct IntShiftRightOpLowering : public OpConversionPattern<IntShiftRightOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntShiftRightOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        // Arithmetic shift right (preserves sign)
        rewriter.replaceOpWithNewOp<arith::ShRSIOp>(op, adaptor.getValue(), adaptor.getAmount());
        return success();
    }
};

struct IntShiftRightZfOpLowering : public OpConversionPattern<IntShiftRightZfOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(IntShiftRightZfOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        // Logical shift right (zero fill)
        rewriter.replaceOpWithNewOp<arith::ShRUIOp>(op, adaptor.getValue(), adaptor.getAmount());
        return success();
    }
};

// ============================================================================
// Boolean Operations
// ============================================================================

struct BoolNotOpLowering : public OpConversionPattern<BoolNotOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(BoolNotOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        // Create constant 1 with bit width 1 (i1)
        auto trueVal = rewriter.create<arith::ConstantIntOp>(loc, 1, /*width=*/1);
        rewriter.replaceOpWithNewOp<arith::XOrIOp>(op, adaptor.getValue(), trueVal);
        return success();
    }
};

struct BoolAndOpLowering : public OpConversionPattern<BoolAndOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(BoolAndOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::AndIOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct BoolOrOpLowering : public OpConversionPattern<BoolOrOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(BoolOrOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::OrIOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct BoolXorOpLowering : public OpConversionPattern<BoolXorOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(BoolXorOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.replaceOpWithNewOp<arith::XOrIOp>(op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

// ============================================================================
// Character Operations
// ============================================================================

struct CharToIntOpLowering : public OpConversionPattern<CharToIntOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(CharToIntOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto i64Ty = IntegerType::get(rewriter.getContext(), 64);
        // Zero-extend i16 to i64 (char codes are always non-negative)
        rewriter.replaceOpWithNewOp<arith::ExtUIOp>(op, i64Ty, adaptor.getValue());
        return success();
    }
};

struct CharFromIntOpLowering : public OpConversionPattern<CharFromIntOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(CharFromIntOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i16Ty = IntegerType::get(ctx, 16);

        Value input = adaptor.getValue();

        // Clamp to valid range [0, 0xFFFF]
        Value zero = rewriter.create<arith::ConstantIntOp>(loc, 0, /*width=*/64);
        Value maxChar = rewriter.create<arith::ConstantIntOp>(loc, 0xFFFF, /*width=*/64);

        // clamp: max(0, min(input, 0xFFFF))
        Value clampedLow = rewriter.create<arith::MaxSIOp>(loc, input, zero);
        Value clamped = rewriter.create<arith::MinSIOp>(loc, clampedLow, maxChar);

        // Truncate to i16
        rewriter.replaceOpWithNewOp<arith::TruncIOp>(op, i16Ty, clamped);
        return success();
    }
};

} // namespace

//===----------------------------------------------------------------------===//
// Pass Definition
//===----------------------------------------------------------------------===//

namespace {

struct EcoToLLVMPass : public PassWrapper<EcoToLLVMPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoToLLVMPass)

    StringRef getArgument() const override { return "eco-to-llvm"; }

    StringRef getDescription() const override {
        return "Lower Eco dialect to LLVM dialect";
    }

    void getDependentDialects(DialectRegistry &registry) const override {
        registry.insert<LLVM::LLVMDialect, func::FuncDialect>();
    }

    void runOnOperation() override {
        ModuleOp module = getOperation();
        auto *ctx = &getContext();

        // Set up type converter for eco.value -> i64.
        EcoTypeConverter typeConverter(ctx);

        // Set up conversion target to allow LLVM/arith/cf dialects.
        ConversionTarget target(*ctx);
        target.addLegalDialect<LLVM::LLVMDialect>();
        target.addLegalDialect<arith::ArithDialect>();
        target.addLegalDialect<cf::ControlFlowDialect>();
        target.addLegalOp<ModuleOp>();

        // SCF ops need structural type conversion - they'll be dynamically legal
        // based on whether their types have been converted from !eco.value to i64.
        // This is configured by populateSCFStructuralTypeConversionsAndLegality below.

        // func dialect: convert func.func to llvm.func so that AddressOfOp
        // can reference functions when lowering eco.papCreate.
        // Note: func.call and func.return will also be converted.
        target.addIllegalOp<func::FuncOp>();
        target.addIllegalOp<func::CallOp>();
        target.addIllegalOp<func::ReturnOp>();

        // Mark all Eco dialect operations as illegal (to be lowered).
        target.addIllegalDialect<EcoDialect>();

        // Set up lowering patterns.
        RewritePatternSet patterns(ctx);

        // Add func-to-llvm conversion patterns FIRST - this ensures func.func
        // is converted to llvm.func before eco.papCreate tries to reference it.
        populateFuncToLLVMConversionPatterns(typeConverter, patterns);

        // Add branch type conversion pattern for cf.br/cf.cond_br when block
        // argument types are converted.
        populateBranchOpInterfaceTypeConversionPattern(patterns, typeConverter);

        // Add SCF structural type conversion patterns and legality.
        // This converts !eco.value types in scf.while/scf.for/scf.if to i64.
        scf::populateSCFStructuralTypeConversionsAndLegality(typeConverter, patterns, target);

        // Clear joinpoint map for this module.
        joinpointBlocks.clear();

        patterns.add<
            ConstantOpLowering,
            SafepointOpLowering,
            DbgOpLowering,
            BoxOpLowering,
            UnboxOpLowering,
            AllocateOpLowering,
            AllocateCtorOpLowering,
            AllocateStringOpLowering,
            AllocateClosureOpLowering,
            PapCreateOpLowering,
            PapExtendOpLowering,
            // Type-specific construction/projection
            ListConstructOpLowering,
            ListHeadOpLowering,
            ListTailOpLowering,
            Tuple2ConstructOpLowering,
            Tuple3ConstructOpLowering,
            Tuple2ProjectOpLowering,
            Tuple3ProjectOpLowering,
            RecordConstructOpLowering,
            RecordProjectOpLowering,
            CustomConstructOpLowering,
            CustomProjectOpLowering,
            StringLiteralOpLowering,
            ReturnOpLowering,
            CallOpLowering,
            CrashOpLowering,
            ExpectOpLowering,
            GlobalOpLowering,
            LoadGlobalOpLowering,
            StoreGlobalOpLowering,
            GetTagOpLowering,
            CaseOpLowering,
            JoinpointOpLowering,
            JumpOpLowering,
            // Integer arithmetic
            IntAddOpLowering,
            IntSubOpLowering,
            IntMulOpLowering,
            IntDivOpLowering,
            IntModByOpLowering,
            IntRemainderByOpLowering,
            IntNegateOpLowering,
            IntAbsOpLowering,
            IntPowOpLowering,
            // Float arithmetic
            FloatAddOpLowering,
            FloatSubOpLowering,
            FloatMulOpLowering,
            FloatDivOpLowering,
            FloatNegateOpLowering,
            FloatAbsOpLowering,
            FloatPowOpLowering,
            FloatSqrtOpLowering,
            // Trigonometric functions
            FloatSinOpLowering,
            FloatCosOpLowering,
            FloatTanOpLowering,
            FloatAsinOpLowering,
            FloatAcosOpLowering,
            FloatAtanOpLowering,
            FloatAtan2OpLowering,
            FloatLogOpLowering,
            // Float classification
            FloatIsNaNOpLowering,
            FloatIsInfiniteOpLowering,
            // Type conversions
            IntToFloatOpLowering,
            FloatRoundOpLowering,
            FloatFloorOpLowering,
            FloatCeilingOpLowering,
            FloatTruncateOpLowering,
            // Comparisons
            IntLtOpLowering,
            IntLeOpLowering,
            IntGtOpLowering,
            IntGeOpLowering,
            IntEqOpLowering,
            IntNeOpLowering,
            FloatLtOpLowering,
            FloatLeOpLowering,
            FloatGtOpLowering,
            FloatGeOpLowering,
            FloatEqOpLowering,
            FloatNeOpLowering,
            IntMinOpLowering,
            IntMaxOpLowering,
            FloatMinOpLowering,
            FloatMaxOpLowering,
            // Bitwise
            IntAndOpLowering,
            IntOrOpLowering,
            IntXorOpLowering,
            IntComplementOpLowering,
            IntShiftLeftOpLowering,
            IntShiftRightOpLowering,
            IntShiftRightZfOpLowering,
            // Boolean operations
            BoolNotOpLowering,
            BoolAndOpLowering,
            BoolOrOpLowering,
            BoolXorOpLowering,
            // Character operations
            CharToIntOpLowering,
            CharFromIntOpLowering
        >(typeConverter, ctx);

        // Apply the conversion patterns to the module.
        if (failed(applyPartialConversion(module, target, std::move(patterns))))
            signalPassFailure();

        // Generate global root initialization.
        // Collect all LLVM globals that came from eco.global and generate
        // a constructor that calls eco_gc_add_root for each.
        generateGlobalRootInit(module, ctx);
    }

    /// Generates module initialization code to register globals as GC roots.
    /// Creates a function __eco_init_globals.
    void generateGlobalRootInit(ModuleOp module, MLIRContext *ctx) {
        // Collect all internal LLVM globals (these came from eco.global).
        SmallVector<LLVM::GlobalOp> ecoGlobals;
        module.walk([&](LLVM::GlobalOp globalOp) {
            // eco.global creates internal linkage globals with i64 type.
            if (globalOp.getLinkage() == LLVM::Linkage::Internal &&
                globalOp.getGlobalType().isInteger(64)) {
                ecoGlobals.push_back(globalOp);
            }
        });

        // Skip if there's nothing to initialize.
        if (ecoGlobals.empty())
            return;

        auto loc = module.getLoc();
        OpBuilder builder(ctx);
        builder.setInsertionPointToEnd(module.getBody());

        auto ptrTy = LLVM::LLVMPointerType::get(ctx);
        auto voidTy = LLVM::LLVMVoidType::get(ctx);

        // Get or create the eco_gc_add_root function declaration.
        auto addRootFuncType = LLVM::LLVMFunctionType::get(voidTy, {ptrTy});
        auto addRootFunc = getOrInsertFunc(module, builder, "eco_gc_add_root", addRootFuncType);

        // Create the __eco_init_globals function.
        // Use External linkage so the JIT can look it up by name.
        auto initFuncType = LLVM::LLVMFunctionType::get(voidTy, {});
        auto initFunc = builder.create<LLVM::LLVMFuncOp>(
            loc, "__eco_init_globals", initFuncType);
        initFunc.setLinkage(LLVM::Linkage::External);

        // Create the function body.
        Block *entryBlock = initFunc.addEntryBlock(builder);
        builder.setInsertionPointToStart(entryBlock);

        // Call eco_gc_add_root for each global.
        for (auto globalOp : ecoGlobals) {
            auto globalAddr = builder.create<LLVM::AddressOfOp>(
                loc, ptrTy, globalOp.getSymName());
            builder.create<LLVM::CallOp>(loc, addRootFunc, ValueRange{globalAddr});
        }

        builder.create<LLVM::ReturnOp>(loc, ValueRange{});

        // Note: We don't generate llvm.global_ctors because:
        // 1. For JIT: The MLIR ExecutionEngine processes global_ctors before
        //    custom symbols are registered, causing symbol resolution failures.
        //    Instead, ecoc.cpp calls __eco_init_globals manually after symbol registration.
        // 2. For AOT: A future AOT compiler could add global_ctors generation,
        //    or the linker can be configured to call __eco_init_globals.
    }
};

} // namespace

//===----------------------------------------------------------------------===//
// Pass Registration
//===----------------------------------------------------------------------===//

std::unique_ptr<Pass> eco::createEcoToLLVMPass() {
    return std::make_unique<EcoToLLVMPass>();
}

std::unique_ptr<TypeConverter> eco::createEcoToLLVMTypeConverter(MLIRContext *ctx) {
    return std::make_unique<EcoTypeConverter>(ctx);
}

void eco::registerEcoPasses() {
    // Register all eco passes
    PassRegistration<EcoToLLVMPass>();
}
