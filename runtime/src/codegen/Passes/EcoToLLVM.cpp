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
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlow.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/PatternMatch.h"
#include "mlir/Pass/Pass.h"
#include "mlir/Transforms/DialectConversion.h"

#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../EcoTypes.h"
#include "../Passes.h"

#include <codecvt>
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
// eco.dbg -> call eco_dbg_print
// ============================================================================

struct DbgOpLowering : public OpConversionPattern<DbgOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(DbgOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto module = op->getParentOfType<ModuleOp>();
        auto *ctx = rewriter.getContext();

        // Get or insert eco_dbg_print declaration.
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);
        auto i32Ty = IntegerType::get(ctx, 32);
        auto voidTy = LLVM::LLVMVoidType::get(ctx);
        auto funcTy = LLVM::LLVMFunctionType::get(voidTy, {ptrTy, i32Ty});
        getOrInsertFunc(module, rewriter, "eco_dbg_print", funcTy);

        // Allocate array on stack for the debug arguments.
        auto args = adaptor.getArgs();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto arrayTy = LLVM::LLVMArrayType::get(i64Ty, args.size());
        auto one = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, 1);
        auto alloca = rewriter.create<LLVM::AllocaOp>(loc, ptrTy, arrayTy, one);

        // Store each argument into the array.
        auto zero = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, 0);
        for (size_t i = 0; i < args.size(); i++) {
            auto idx = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(i));
            // GEP with two indices: first 0 dereferences the alloca, second indexes the array.
            auto gep = rewriter.create<LLVM::GEPOp>(loc, ptrTy, arrayTy, alloca,
                                                    ValueRange{zero, idx});
            rewriter.create<LLVM::StoreOp>(loc, args[i], gep);
        }

        // Call eco_dbg_print with the array and count.
        auto numArgs = rewriter.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(args.size()));
        rewriter.create<LLVM::CallOp>(
            loc, TypeRange{}, SymbolRefAttr::get(ctx, "eco_dbg_print"),
            ValueRange{alloca, numArgs});

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
        } else if (inputType.isInteger(32)) {
            // Box i32 (char) -> eco_alloc_char.
            auto i32Ty = IntegerType::get(ctx, 32);
            auto funcTy = LLVM::LLVMFunctionType::get(ptrTy, {i32Ty});
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

        Value input = adaptor.getValue();
        Type resultType = getTypeConverter()->convertType(op.getResult().getType());

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
// eco.construct -> eco_alloc_custom + eco_store_field calls
// ============================================================================

struct ConstructOpLowering : public OpConversionPattern<ConstructOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ConstructOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto module = op->getParentOfType<ModuleOp>();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i64Ty = IntegerType::get(ctx, 64);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);
        auto voidTy = LLVM::LLVMVoidType::get(ctx);

        // Get or insert function declarations.
        auto allocFuncTy = LLVM::LLVMFunctionType::get(ptrTy, {i32Ty, i32Ty, i32Ty});
        getOrInsertFunc(module, rewriter, "eco_alloc_custom", allocFuncTy);

        auto storeFuncTy = LLVM::LLVMFunctionType::get(voidTy, {ptrTy, i32Ty, i64Ty});
        getOrInsertFunc(module, rewriter, "eco_store_field", storeFuncTy);

        // Allocate the custom object.
        auto tag = rewriter.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(op.getTag()));
        auto size = rewriter.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(op.getSize()));
        auto scalarBytes = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, 0);

        auto allocCall = rewriter.create<LLVM::CallOp>(
            loc, ptrTy, SymbolRefAttr::get(ctx, "eco_alloc_custom"),
            ValueRange{tag, size, scalarBytes});
        auto objPtr = allocCall.getResult();

        // Store each field into the allocated object.
        auto fields = adaptor.getFields();
        for (size_t i = 0; i < fields.size(); i++) {
            auto idx = rewriter.create<LLVM::ConstantOp>(
                loc, i32Ty, static_cast<int32_t>(i));
            // Fields are already i64 after type conversion.
            rewriter.create<LLVM::CallOp>(
                loc, TypeRange{}, SymbolRefAttr::get(ctx, "eco_store_field"),
                ValueRange{objPtr, idx, fields[i]});
        }

        // Convert pointer to tagged i64 for the result.
        auto result = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, objPtr);
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
        auto funcTy = LLVM::LLVMFunctionType::get(ptrTy, {ptrTy, i32Ty});
        getOrInsertFunc(module, rewriter, "eco_alloc_closure", funcTy);

        // Get function address for the closure.
        // TODO: For now, use a null pointer. Need to look up the function symbol.
        auto funcPtr = rewriter.create<LLVM::ZeroOp>(loc, ptrTy);

        // Create num_captures constant
        auto numCaptures = rewriter.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(op.getNumCaptures()));

        // Call eco_alloc_closure
        auto call = rewriter.create<LLVM::CallOp>(
            loc, ptrTy, SymbolRefAttr::get(ctx, "eco_alloc_closure"),
            ValueRange{funcPtr, numCaptures});

        // Convert ptr to i64
        auto result = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, call.getResult());

        rewriter.replaceOp(op, result);
        return success();
    }
};

// ============================================================================
// eco.project -> inttoptr + gep + load
// ============================================================================

struct ProjectOpLowering : public OpConversionPattern<ProjectOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ProjectOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i8Ty = IntegerType::get(ctx, 8);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        Value input = adaptor.getValue();
        int64_t index = op.getIndex();

        // Convert tagged i64 to pointer.
        auto ptr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, input);

        // Calculate byte offset to the field in Custom object layout.
        // Custom layout: Header (8) + ctor/unboxed (8) + fields[index * 8].
        int64_t offsetBytes = 8 + 8 + index * 8;
        auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, offsetBytes);

        // Compute field address via GEP.
        auto fieldPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr,
                                                      ValueRange{offset});

        // Load the field value.
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
        SmallVector<Attribute> charAttrs;
        for (uint16_t c : utf16) {
            charAttrs.push_back(rewriter.getI16IntegerAttr(c));
        }

        OpBuilder::InsertionGuard guard(rewriter);
        rewriter.setInsertionPointToStart(module.getBody());

        // Create the global
        auto headerAttr = rewriter.getI64IntegerAttr(header);
        auto charsAttr = DenseIntElementsAttr::get(
            RankedTensorType::get({static_cast<int64_t>(utf16.size())}, i16Ty),
            charAttrs);

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
            Value current = withHeader;
            for (size_t i = 0; i < utf16.size(); i++) {
                auto charVal = rewriter.create<LLVM::ConstantOp>(
                    loc, i16Ty, static_cast<int16_t>(utf16[i]));
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
            auto callOp = rewriter.create<LLVM::CallOp>(
                loc, resultTypes, *callee, adaptor.getOperands());

            // Use tail calling convention for Eco-to-Eco calls.
            callOp.setCConv(LLVM::CConv::Tail);

            // Mark as musttail if required for tail call elimination.
            if (op.getMusttail().value_or(false)) {
                callOp.setTailCallKind(LLVM::TailCallKind::MustTail);
            }

            rewriter.replaceOp(op, callOp.getResults());
        } else {
            // Indirect call through closure.
            // TODO: Implement closure call lowering via eco_apply_closure.
            return op.emitError("indirect closure calls not yet implemented");
        }

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

        // Set up conversion target to allow LLVM/func/arith/cf dialects.
        ConversionTarget target(*ctx);
        target.addLegalDialect<LLVM::LLVMDialect>();
        target.addLegalDialect<func::FuncDialect>();
        target.addLegalDialect<arith::ArithDialect>();
        target.addLegalDialect<cf::ControlFlowDialect>();
        target.addLegalOp<ModuleOp>();

        // Mark all Eco dialect operations as illegal (to be lowered).
        target.addIllegalDialect<EcoDialect>();

        // Set up lowering patterns.
        RewritePatternSet patterns(ctx);

        patterns.add<
            ConstantOpLowering,
            SafepointOpLowering,
            DbgOpLowering,
            BoxOpLowering,
            UnboxOpLowering,
            ConstructOpLowering,
            AllocateCtorOpLowering,
            AllocateStringOpLowering,
            AllocateClosureOpLowering,
            ProjectOpLowering,
            StringLiteralOpLowering,
            ReturnOpLowering,
            CallOpLowering
        >(typeConverter, ctx);

        // Apply the conversion patterns to the module.
        if (failed(applyPartialConversion(module, target, std::move(patterns))))
            signalPassFailure();
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
