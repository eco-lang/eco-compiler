//===- BFToLLVM.cpp - BF dialect to LLVM dialect lowering -----------------===//
//
// This file implements the pass for lowering BF (ByteFusion) dialect operations
// to LLVM dialect. The bf.cursor type is lowered to a struct {i8*, i8*} and
// operations are lowered to runtime helper calls and inline LLVM ops.
//
//===----------------------------------------------------------------------===//

#include "../BF/BFDialect.h"
#include "../BF/BFOps.h"
#include "../BF/BFTypes.h"
#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../Passes.h"

#include "mlir/Conversion/LLVMCommon/ConversionTarget.h"
#include "mlir/Conversion/LLVMCommon/TypeConverter.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/Pass/Pass.h"
#include "mlir/Transforms/DialectConversion.h"

using namespace mlir;
using namespace bf;

namespace {

//===----------------------------------------------------------------------===//
// Type Converter
//===----------------------------------------------------------------------===//

/// Type converter for BF dialect.
/// Converts bf.cursor to LLVM struct {i8*, i8*}.
/// Also converts eco.value to i64 for interoperability.
class BFTypeConverter : public LLVMTypeConverter {
public:
    explicit BFTypeConverter(MLIRContext *ctx) : LLVMTypeConverter(ctx) {
        addConversion([](bf::CursorType type) -> Type {
            // Cursor is (current_ptr, end_ptr)
            auto ptrType = LLVM::LLVMPointerType::get(type.getContext());
            return LLVM::LLVMStructType::getLiteral(type.getContext(),
                                                     {ptrType, ptrType});
        });

        // eco.value -> i64 (tagged pointer representation)
        addConversion([](eco::ValueType type) -> Type {
            return IntegerType::get(type.getContext(), 64);
        });
    }
};

//===----------------------------------------------------------------------===//
// Runtime Function Declarations
//===----------------------------------------------------------------------===//

/// Ensure runtime functions are declared in the module.
static void ensureRuntimeFunctions(ModuleOp module, OpBuilder &builder) {
    auto loc = module.getLoc();
    auto ctx = module.getContext();
    auto i8Ptr = LLVM::LLVMPointerType::get(ctx);
    auto i32 = builder.getI32Type();
    auto i64 = builder.getI64Type();

    auto declareFunc = [&](StringRef name, Type resultType,
                           ArrayRef<Type> argTypes) {
        if (module.lookupSymbol<LLVM::LLVMFuncOp>(name))
            return;  // Already declared
        auto funcType = LLVM::LLVMFunctionType::get(resultType, argTypes);
        builder.setInsertionPointToStart(module.getBody());
        builder.create<LLVM::LLVMFuncOp>(loc, name, funcType);
    };

    // ByteBuffer operations
    declareFunc("elm_alloc_bytebuffer", i64, {i32});
    declareFunc("elm_bytebuffer_len", i32, {i64});
    declareFunc("elm_bytebuffer_data", i8Ptr, {i64});

    // UTF-8 operations
    declareFunc("elm_utf8_width", i32, {i64});
    declareFunc("elm_utf8_copy", i32, {i64, i8Ptr});
    declareFunc("elm_utf8_decode", i64, {i8Ptr, i32});

    // Maybe operations
    declareFunc("elm_maybe_nothing", i64, {});
    declareFunc("elm_maybe_just", i64, {i64});
}

//===----------------------------------------------------------------------===//
// Helper Functions
//===----------------------------------------------------------------------===//

/// Create a cursor struct value from ptr and end pointers.
static Value createCursor(OpBuilder &builder, Location loc, Value ptr,
                          Value end, Type cursorLLVMType) {
    Value cursor = builder.create<LLVM::UndefOp>(loc, cursorLLVMType);
    cursor = builder.create<LLVM::InsertValueOp>(loc, cursor, ptr,
                                                  ArrayRef<int64_t>{0});
    cursor = builder.create<LLVM::InsertValueOp>(loc, cursor, end,
                                                  ArrayRef<int64_t>{1});
    return cursor;
}

/// Extract the current pointer from a cursor.
static Value extractPtr(OpBuilder &builder, Location loc, Value cursor) {
    auto ptrType = LLVM::LLVMPointerType::get(builder.getContext());
    return builder.create<LLVM::ExtractValueOp>(loc, ptrType, cursor,
                                                 ArrayRef<int64_t>{0});
}

/// Extract the end pointer from a cursor.
static Value extractEnd(OpBuilder &builder, Location loc, Value cursor) {
    auto ptrType = LLVM::LLVMPointerType::get(builder.getContext());
    return builder.create<LLVM::ExtractValueOp>(loc, ptrType, cursor,
                                                 ArrayRef<int64_t>{1});
}

/// Advance cursor pointer by given number of bytes and return new cursor.
static Value advanceCursor(OpBuilder &builder, Location loc, Value cursor,
                           Value bytes, Type cursorLLVMType) {
    Value ptr = extractPtr(builder, loc, cursor);
    Value end = extractEnd(builder, loc, cursor);

    // gep ptr, bytes
    Value newPtr = builder.create<LLVM::GEPOp>(
        loc, ptr.getType(), builder.getI8Type(), ptr, bytes);

    return createCursor(builder, loc, newPtr, end, cursorLLVMType);
}

//===----------------------------------------------------------------------===//
// Lowering Patterns
//===----------------------------------------------------------------------===//

/// Lower bf.alloc to call @elm_alloc_bytebuffer.
struct AllocOpLowering : public OpConversionPattern<bf::AllocOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(AllocOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto module = op->getParentOfType<ModuleOp>();
        auto func = module.lookupSymbol<LLVM::LLVMFuncOp>("elm_alloc_bytebuffer");
        if (!func)
            return failure();

        auto result = rewriter.create<LLVM::CallOp>(
            loc, func, ValueRange{adaptor.getSize()});
        rewriter.replaceOp(op, result.getResult());
        return success();
    }
};

/// Lower bf.cursor.init to runtime calls for ptr and len.
struct CursorInitOpLowering : public OpConversionPattern<bf::CursorInitOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(CursorInitOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto module = op->getParentOfType<ModuleOp>();

        auto dataFunc = module.lookupSymbol<LLVM::LLVMFuncOp>("elm_bytebuffer_data");
        auto lenFunc = module.lookupSymbol<LLVM::LLVMFuncOp>("elm_bytebuffer_len");
        if (!dataFunc || !lenFunc)
            return failure();

        // Get data pointer
        auto dataCall = rewriter.create<LLVM::CallOp>(
            loc, dataFunc, ValueRange{adaptor.getBuffer()});
        Value ptr = dataCall.getResult();

        // Get length
        auto lenCall = rewriter.create<LLVM::CallOp>(
            loc, lenFunc, ValueRange{adaptor.getBuffer()});
        Value len = lenCall.getResult();

        // Compute end = ptr + len
        Value end = rewriter.create<LLVM::GEPOp>(
            loc, ptr.getType(), rewriter.getI8Type(), ptr, len);

        // Create cursor struct
        Type cursorType = getTypeConverter()->convertType(op.getType());
        Value cursor = createCursor(rewriter, loc, ptr, end, cursorType);

        rewriter.replaceOp(op, cursor);
        return success();
    }
};

/// Lower bf.write.u8 to store and cursor advance.
struct WriteU8OpLowering : public OpConversionPattern<bf::WriteU8Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(WriteU8Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        // Truncate i64 value to i8
        Value byte = rewriter.create<LLVM::TruncOp>(
            loc, rewriter.getI8Type(), adaptor.getValue());

        // Store byte
        rewriter.create<LLVM::StoreOp>(loc, byte, ptr);

        // Advance cursor by 1
        Value one = rewriter.create<LLVM::ConstantOp>(
            loc, rewriter.getI32Type(), 1);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(),
                                        one, cursorType);

        rewriter.replaceOp(op, newCursor);
        return success();
    }
};

/// Lower bf.write.u16 to stores (with endianness) and cursor advance.
struct WriteU16OpLowering : public OpConversionPattern<bf::WriteU16Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(WriteU16Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        // Truncate i64 value to i16
        Value val16 = rewriter.create<LLVM::TruncOp>(
            loc, rewriter.getI16Type(), adaptor.getValue());

        // Handle endianness
        if (op.getEndianness() == bf::Endianness::BE) {
            val16 = rewriter.create<LLVM::ByteSwapOp>(loc, val16);
        }

        // Store as unaligned i16
        rewriter.create<LLVM::StoreOp>(loc, val16, ptr, /*alignment=*/1);

        // Advance cursor by 2
        Value two = rewriter.create<LLVM::ConstantOp>(
            loc, rewriter.getI32Type(), 2);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(),
                                        two, cursorType);

        rewriter.replaceOp(op, newCursor);
        return success();
    }
};

/// Lower bf.write.u32 to stores (with endianness) and cursor advance.
struct WriteU32OpLowering : public OpConversionPattern<bf::WriteU32Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(WriteU32Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        // Truncate i64 value to i32
        Value val32 = rewriter.create<LLVM::TruncOp>(
            loc, rewriter.getI32Type(), adaptor.getValue());

        // Handle endianness
        if (op.getEndianness() == bf::Endianness::BE) {
            val32 = rewriter.create<LLVM::ByteSwapOp>(loc, val32);
        }

        // Store as unaligned i32
        rewriter.create<LLVM::StoreOp>(loc, val32, ptr, /*alignment=*/1);

        // Advance cursor by 4
        Value four = rewriter.create<LLVM::ConstantOp>(
            loc, rewriter.getI32Type(), 4);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(),
                                        four, cursorType);

        rewriter.replaceOp(op, newCursor);
        return success();
    }
};

/// Lower bf.write.f32 to cast + store and cursor advance.
struct WriteF32OpLowering : public OpConversionPattern<bf::WriteF32Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(WriteF32Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        // Cast f64 to f32
        Value val32 = rewriter.create<LLVM::FPTruncOp>(
            loc, rewriter.getF32Type(), adaptor.getValue());

        // Bitcast f32 to i32 for byte swapping
        Value asInt = rewriter.create<LLVM::BitcastOp>(
            loc, rewriter.getI32Type(), val32);

        // Handle endianness
        if (op.getEndianness() == bf::Endianness::BE) {
            asInt = rewriter.create<LLVM::ByteSwapOp>(loc, asInt);
        }

        // Bitcast back to f32
        val32 = rewriter.create<LLVM::BitcastOp>(loc, rewriter.getF32Type(), asInt);

        // Store as unaligned f32
        rewriter.create<LLVM::StoreOp>(loc, val32, ptr, /*alignment=*/1);

        // Advance cursor by 4
        Value four = rewriter.create<LLVM::ConstantOp>(
            loc, rewriter.getI32Type(), 4);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(),
                                        four, cursorType);

        rewriter.replaceOp(op, newCursor);
        return success();
    }
};

/// Lower bf.write.f64 to store and cursor advance.
struct WriteF64OpLowering : public OpConversionPattern<bf::WriteF64Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(WriteF64Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());
        Value val64 = adaptor.getValue();

        // Bitcast f64 to i64 for byte swapping
        Value asInt = rewriter.create<LLVM::BitcastOp>(
            loc, rewriter.getI64Type(), val64);

        // Handle endianness
        if (op.getEndianness() == bf::Endianness::BE) {
            asInt = rewriter.create<LLVM::ByteSwapOp>(loc, asInt);
        }

        // Bitcast back to f64
        val64 = rewriter.create<LLVM::BitcastOp>(loc, rewriter.getF64Type(), asInt);

        // Store as unaligned f64
        rewriter.create<LLVM::StoreOp>(loc, val64, ptr, /*alignment=*/1);

        // Advance cursor by 8
        Value eight = rewriter.create<LLVM::ConstantOp>(
            loc, rewriter.getI32Type(), 8);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(),
                                        eight, cursorType);

        rewriter.replaceOp(op, newCursor);
        return success();
    }
};

/// Lower bf.write.bytes to memcpy and cursor advance.
struct WriteBytesOpLowering : public OpConversionPattern<bf::WriteBytesOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(WriteBytesOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto module = op->getParentOfType<ModuleOp>();
        Type cursorType = getTypeConverter()->convertType(op.getType());

        auto dataFunc = module.lookupSymbol<LLVM::LLVMFuncOp>("elm_bytebuffer_data");
        auto lenFunc = module.lookupSymbol<LLVM::LLVMFuncOp>("elm_bytebuffer_len");
        if (!dataFunc || !lenFunc)
            return failure();

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        // Get source data pointer
        auto srcDataCall = rewriter.create<LLVM::CallOp>(
            loc, dataFunc, ValueRange{adaptor.getBytes()});
        Value srcPtr = srcDataCall.getResult();

        // Get source length
        auto srcLenCall = rewriter.create<LLVM::CallOp>(
            loc, lenFunc, ValueRange{adaptor.getBytes()});
        Value len = srcLenCall.getResult();

        // Extend len to i64 for memcpy
        Value len64 = rewriter.create<LLVM::ZExtOp>(
            loc, rewriter.getI64Type(), len);

        // memcpy(dst, src, len)
        rewriter.create<LLVM::MemcpyOp>(
            loc, ptr, srcPtr, len64, /*isVolatile=*/false);

        // Advance cursor by len
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(),
                                        len, cursorType);

        rewriter.replaceOp(op, newCursor);
        return success();
    }
};

/// Lower bf.write.utf8 to call @elm_utf8_copy and cursor advance.
struct WriteUtf8OpLowering : public OpConversionPattern<bf::WriteUtf8Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(WriteUtf8Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto module = op->getParentOfType<ModuleOp>();
        Type cursorType = getTypeConverter()->convertType(op.getType());

        auto copyFunc = module.lookupSymbol<LLVM::LLVMFuncOp>("elm_utf8_copy");
        if (!copyFunc)
            return failure();

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        // Call elm_utf8_copy(string, ptr) -> bytesWritten
        auto copyCall = rewriter.create<LLVM::CallOp>(
            loc, copyFunc, ValueRange{adaptor.getString(), ptr});
        Value bytesWritten = copyCall.getResult();

        // Advance cursor by bytesWritten
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(),
                                        bytesWritten, cursorType);

        rewriter.replaceOp(op, newCursor);
        return success();
    }
};

/// Lower bf.utf8_width to call @elm_utf8_width.
struct Utf8WidthOpLowering : public OpConversionPattern<bf::Utf8WidthOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(Utf8WidthOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto module = op->getParentOfType<ModuleOp>();

        auto widthFunc = module.lookupSymbol<LLVM::LLVMFuncOp>("elm_utf8_width");
        if (!widthFunc)
            return failure();

        auto result = rewriter.create<LLVM::CallOp>(
            loc, widthFunc, ValueRange{adaptor.getString()});
        rewriter.replaceOp(op, result.getResult());
        return success();
    }
};

/// Lower bf.bytes_width to call @elm_bytebuffer_len.
struct BytesWidthOpLowering : public OpConversionPattern<bf::BytesWidthOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(BytesWidthOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto module = op->getParentOfType<ModuleOp>();

        auto lenFunc = module.lookupSymbol<LLVM::LLVMFuncOp>("elm_bytebuffer_len");
        if (!lenFunc)
            return failure();

        auto result = rewriter.create<LLVM::CallOp>(
            loc, lenFunc, ValueRange{adaptor.getBuffer()});
        rewriter.replaceOp(op, result.getResult());
        return success();
    }
};

/// Lower bf.require to bounds check.
struct RequireOpLowering : public OpConversionPattern<bf::RequireOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(RequireOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());
        Value end = extractEnd(rewriter, loc, adaptor.getCursor());

        // Compute ptr + bytes
        Value newPtr = rewriter.create<LLVM::GEPOp>(
            loc, ptr.getType(), rewriter.getI8Type(), ptr, adaptor.getBytes());

        // Compare newPtr <= end (unsigned)
        Value ok = rewriter.create<LLVM::ICmpOp>(
            loc, LLVM::ICmpPredicate::ule, newPtr, end);

        rewriter.replaceOp(op, ok);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Read Operations Lowering (Decoder - Phase 2)
//===----------------------------------------------------------------------===//

/// Lower bf.read.u8 to load + zext + cursor advance.
struct ReadU8OpLowering : public OpConversionPattern<bf::ReadU8Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ReadU8Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getNewCursor().getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        // Load byte
        Value byte = rewriter.create<LLVM::LoadOp>(loc, rewriter.getI8Type(), ptr);

        // Zero-extend to i64 (Elm Int representation)
        Value value = rewriter.create<LLVM::ZExtOp>(loc, rewriter.getI64Type(), byte);

        // Advance cursor by 1
        Value one = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 1);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(), one, cursorType);

        rewriter.replaceOp(op, {value, newCursor});
        return success();
    }
};

/// Lower bf.read.i8 to load + sext + cursor advance.
struct ReadI8OpLowering : public OpConversionPattern<bf::ReadI8Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ReadI8Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getNewCursor().getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        // Load byte
        Value byte = rewriter.create<LLVM::LoadOp>(loc, rewriter.getI8Type(), ptr);

        // Sign-extend to i64 (Elm Int representation)
        Value value = rewriter.create<LLVM::SExtOp>(loc, rewriter.getI64Type(), byte);

        // Advance cursor by 1
        Value one = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 1);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(), one, cursorType);

        rewriter.replaceOp(op, {value, newCursor});
        return success();
    }
};

/// Lower bf.read.u16 to byte-wise load + zext + cursor advance.
struct ReadU16OpLowering : public OpConversionPattern<bf::ReadU16Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ReadU16Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getNewCursor().getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        // Load 2 bytes
        Value b0 = rewriter.create<LLVM::LoadOp>(loc, rewriter.getI8Type(), ptr);
        Value oneVal = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 1);
        Value ptr1 = rewriter.create<LLVM::GEPOp>(
            loc, ptr.getType(), rewriter.getI8Type(), ptr, oneVal);
        Value b1 = rewriter.create<LLVM::LoadOp>(loc, rewriter.getI8Type(), ptr1);

        // Extend to i16
        Value b0_16 = rewriter.create<LLVM::ZExtOp>(loc, rewriter.getI16Type(), b0);
        Value b1_16 = rewriter.create<LLVM::ZExtOp>(loc, rewriter.getI16Type(), b1);

        // Combine based on endianness
        Value eight = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI16Type(), 8);
        Value val16;
        if (op.getEndianness() == bf::Endianness::BE) {
            // Big-endian: (b0 << 8) | b1
            Value shifted = rewriter.create<LLVM::ShlOp>(loc, b0_16, eight);
            val16 = rewriter.create<LLVM::OrOp>(loc, shifted, b1_16);
        } else {
            // Little-endian: (b1 << 8) | b0
            Value shifted = rewriter.create<LLVM::ShlOp>(loc, b1_16, eight);
            val16 = rewriter.create<LLVM::OrOp>(loc, shifted, b0_16);
        }

        // Zero-extend to i64
        Value value = rewriter.create<LLVM::ZExtOp>(loc, rewriter.getI64Type(), val16);

        // Advance cursor by 2
        Value two = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 2);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(), two, cursorType);

        rewriter.replaceOp(op, {value, newCursor});
        return success();
    }
};

/// Lower bf.read.i16 to byte-wise load + sext + cursor advance.
struct ReadI16OpLowering : public OpConversionPattern<bf::ReadI16Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ReadI16Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getNewCursor().getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        // Load 2 bytes
        Value b0 = rewriter.create<LLVM::LoadOp>(loc, rewriter.getI8Type(), ptr);
        Value oneVal = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 1);
        Value ptr1 = rewriter.create<LLVM::GEPOp>(
            loc, ptr.getType(), rewriter.getI8Type(), ptr, oneVal);
        Value b1 = rewriter.create<LLVM::LoadOp>(loc, rewriter.getI8Type(), ptr1);

        // Extend to i16
        Value b0_16 = rewriter.create<LLVM::ZExtOp>(loc, rewriter.getI16Type(), b0);
        Value b1_16 = rewriter.create<LLVM::ZExtOp>(loc, rewriter.getI16Type(), b1);

        // Combine based on endianness
        Value eight = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI16Type(), 8);
        Value val16;
        if (op.getEndianness() == bf::Endianness::BE) {
            Value shifted = rewriter.create<LLVM::ShlOp>(loc, b0_16, eight);
            val16 = rewriter.create<LLVM::OrOp>(loc, shifted, b1_16);
        } else {
            Value shifted = rewriter.create<LLVM::ShlOp>(loc, b1_16, eight);
            val16 = rewriter.create<LLVM::OrOp>(loc, shifted, b0_16);
        }

        // Sign-extend to i64
        Value value = rewriter.create<LLVM::SExtOp>(loc, rewriter.getI64Type(), val16);

        // Advance cursor by 2
        Value two = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 2);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(), two, cursorType);

        rewriter.replaceOp(op, {value, newCursor});
        return success();
    }
};

/// Lower bf.read.u32 to byte-wise load + zext + cursor advance.
struct ReadU32OpLowering : public OpConversionPattern<bf::ReadU32Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ReadU32Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getNewCursor().getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        // Load 4 bytes
        Value bytes[4];
        for (int i = 0; i < 4; ++i) {
            Value offset = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), i);
            Value ptrI = rewriter.create<LLVM::GEPOp>(
                loc, ptr.getType(), rewriter.getI8Type(), ptr, offset);
            bytes[i] = rewriter.create<LLVM::LoadOp>(loc, rewriter.getI8Type(), ptrI);
        }

        // Extend to i32 and combine
        Value val32 = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 0);
        for (int i = 0; i < 4; ++i) {
            int byteIdx = (op.getEndianness() == bf::Endianness::BE) ? i : (3 - i);
            Value ext = rewriter.create<LLVM::ZExtOp>(loc, rewriter.getI32Type(), bytes[byteIdx]);
            int shift = (3 - i) * 8;
            if (shift > 0) {
                Value shiftAmt = rewriter.create<LLVM::ConstantOp>(
                    loc, rewriter.getI32Type(), shift);
                ext = rewriter.create<LLVM::ShlOp>(loc, ext, shiftAmt);
            }
            val32 = rewriter.create<LLVM::OrOp>(loc, val32, ext);
        }

        // Zero-extend to i64
        Value value = rewriter.create<LLVM::ZExtOp>(loc, rewriter.getI64Type(), val32);

        // Advance cursor by 4
        Value four = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 4);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(), four, cursorType);

        rewriter.replaceOp(op, {value, newCursor});
        return success();
    }
};

/// Lower bf.read.i32 to byte-wise load + sext + cursor advance.
struct ReadI32OpLowering : public OpConversionPattern<bf::ReadI32Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ReadI32Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getNewCursor().getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        // Load 4 bytes
        Value bytes[4];
        for (int i = 0; i < 4; ++i) {
            Value offset = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), i);
            Value ptrI = rewriter.create<LLVM::GEPOp>(
                loc, ptr.getType(), rewriter.getI8Type(), ptr, offset);
            bytes[i] = rewriter.create<LLVM::LoadOp>(loc, rewriter.getI8Type(), ptrI);
        }

        // Extend to i32 and combine
        Value val32 = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 0);
        for (int i = 0; i < 4; ++i) {
            int byteIdx = (op.getEndianness() == bf::Endianness::BE) ? i : (3 - i);
            Value ext = rewriter.create<LLVM::ZExtOp>(loc, rewriter.getI32Type(), bytes[byteIdx]);
            int shift = (3 - i) * 8;
            if (shift > 0) {
                Value shiftAmt = rewriter.create<LLVM::ConstantOp>(
                    loc, rewriter.getI32Type(), shift);
                ext = rewriter.create<LLVM::ShlOp>(loc, ext, shiftAmt);
            }
            val32 = rewriter.create<LLVM::OrOp>(loc, val32, ext);
        }

        // Sign-extend to i64
        Value value = rewriter.create<LLVM::SExtOp>(loc, rewriter.getI64Type(), val32);

        // Advance cursor by 4
        Value four = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 4);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(), four, cursorType);

        rewriter.replaceOp(op, {value, newCursor});
        return success();
    }
};

/// Lower bf.read.f32 to byte-wise load + bitcast + fpext + cursor advance.
struct ReadF32OpLowering : public OpConversionPattern<bf::ReadF32Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ReadF32Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getNewCursor().getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        // Load 4 bytes
        Value bytes[4];
        for (int i = 0; i < 4; ++i) {
            Value offset = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), i);
            Value ptrI = rewriter.create<LLVM::GEPOp>(
                loc, ptr.getType(), rewriter.getI8Type(), ptr, offset);
            bytes[i] = rewriter.create<LLVM::LoadOp>(loc, rewriter.getI8Type(), ptrI);
        }

        // Extend to i32 and combine
        Value val32 = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 0);
        for (int i = 0; i < 4; ++i) {
            int byteIdx = (op.getEndianness() == bf::Endianness::BE) ? i : (3 - i);
            Value ext = rewriter.create<LLVM::ZExtOp>(loc, rewriter.getI32Type(), bytes[byteIdx]);
            int shift = (3 - i) * 8;
            if (shift > 0) {
                Value shiftAmt = rewriter.create<LLVM::ConstantOp>(
                    loc, rewriter.getI32Type(), shift);
                ext = rewriter.create<LLVM::ShlOp>(loc, ext, shiftAmt);
            }
            val32 = rewriter.create<LLVM::OrOp>(loc, val32, ext);
        }

        // Bitcast i32 to f32
        Value f32Val = rewriter.create<LLVM::BitcastOp>(loc, rewriter.getF32Type(), val32);

        // Extend f32 to f64 (Elm Float representation)
        Value value = rewriter.create<LLVM::FPExtOp>(loc, rewriter.getF64Type(), f32Val);

        // Advance cursor by 4
        Value four = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 4);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(), four, cursorType);

        rewriter.replaceOp(op, {value, newCursor});
        return success();
    }
};

/// Lower bf.read.f64 to byte-wise load + bitcast + cursor advance.
struct ReadF64OpLowering : public OpConversionPattern<bf::ReadF64Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ReadF64Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getNewCursor().getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        // Load 8 bytes
        Value bytes[8];
        for (int i = 0; i < 8; ++i) {
            Value offset = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), i);
            Value ptrI = rewriter.create<LLVM::GEPOp>(
                loc, ptr.getType(), rewriter.getI8Type(), ptr, offset);
            bytes[i] = rewriter.create<LLVM::LoadOp>(loc, rewriter.getI8Type(), ptrI);
        }

        // Extend to i64 and combine
        Value val64 = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI64Type(), 0);
        for (int i = 0; i < 8; ++i) {
            int byteIdx = (op.getEndianness() == bf::Endianness::BE) ? i : (7 - i);
            Value ext = rewriter.create<LLVM::ZExtOp>(loc, rewriter.getI64Type(), bytes[byteIdx]);
            int shift = (7 - i) * 8;
            if (shift > 0) {
                Value shiftAmt = rewriter.create<LLVM::ConstantOp>(
                    loc, rewriter.getI64Type(), shift);
                ext = rewriter.create<LLVM::ShlOp>(loc, ext, shiftAmt);
            }
            val64 = rewriter.create<LLVM::OrOp>(loc, val64, ext);
        }

        // Bitcast i64 to f64 (Elm Float)
        Value value = rewriter.create<LLVM::BitcastOp>(loc, rewriter.getF64Type(), val64);

        // Advance cursor by 8
        Value eight = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 8);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(), eight, cursorType);

        rewriter.replaceOp(op, {value, newCursor});
        return success();
    }
};

/// Lower bf.read.bytes to runtime call + cursor advance.
struct ReadBytesOpLowering : public OpConversionPattern<bf::ReadBytesOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ReadBytesOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto module = op->getParentOfType<ModuleOp>();
        Type cursorType = getTypeConverter()->convertType(op.getNewCursor().getType());

        auto allocFunc = module.lookupSymbol<LLVM::LLVMFuncOp>("elm_alloc_bytebuffer");
        if (!allocFunc)
            return failure();

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        // Allocate new ByteBuffer
        auto allocCall = rewriter.create<LLVM::CallOp>(
            loc, allocFunc, ValueRange{adaptor.getLen()});
        Value newBuffer = allocCall.getResult();

        // Get destination data pointer
        auto dataFunc = module.lookupSymbol<LLVM::LLVMFuncOp>("elm_bytebuffer_data");
        if (!dataFunc)
            return failure();

        auto dataCall = rewriter.create<LLVM::CallOp>(
            loc, dataFunc, ValueRange{newBuffer});
        Value dstPtr = dataCall.getResult();

        // Copy bytes: memcpy(dst, src, len)
        Value len64 = rewriter.create<LLVM::ZExtOp>(
            loc, rewriter.getI64Type(), adaptor.getLen());
        rewriter.create<LLVM::MemcpyOp>(loc, dstPtr, ptr, len64, /*isVolatile=*/false);

        // Advance cursor by len
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(),
                                        adaptor.getLen(), cursorType);

        // ok = true (allocation success assumed for simplicity)
        Value ok = rewriter.create<LLVM::ConstantOp>(
            loc, rewriter.getI1Type(), 1);

        rewriter.replaceOp(op, {newBuffer, newCursor, ok});
        return success();
    }
};

/// Lower bf.read.utf8 to runtime call + cursor advance.
struct ReadUtf8OpLowering : public OpConversionPattern<bf::ReadUtf8Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ReadUtf8Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto module = op->getParentOfType<ModuleOp>();
        Type cursorType = getTypeConverter()->convertType(op.getNewCursor().getType());

        auto decodeFunc = module.lookupSymbol<LLVM::LLVMFuncOp>("elm_utf8_decode");
        if (!decodeFunc)
            return failure();

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        // Call elm_utf8_decode(ptr, len) -> eco.value (0 on failure)
        auto decodeCall = rewriter.create<LLVM::CallOp>(
            loc, decodeFunc, ValueRange{ptr, adaptor.getLen()});
        Value stringVal = decodeCall.getResult();

        // ok = (stringVal != 0)
        Value zero = rewriter.create<LLVM::ConstantOp>(
            loc, rewriter.getI64Type(), 0);
        Value ok = rewriter.create<LLVM::ICmpOp>(
            loc, LLVM::ICmpPredicate::ne, stringVal, zero);

        // Advance cursor by len
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(),
                                        adaptor.getLen(), cursorType);

        rewriter.replaceOp(op, {stringVal, newCursor, ok});
        return success();
    }
};

/// Lower bf.decoder.cursor.init - same as bf.cursor.init.
struct DecoderCursorInitOpLowering : public OpConversionPattern<bf::DecoderCursorInitOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(DecoderCursorInitOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto module = op->getParentOfType<ModuleOp>();

        auto dataFunc = module.lookupSymbol<LLVM::LLVMFuncOp>("elm_bytebuffer_data");
        auto lenFunc = module.lookupSymbol<LLVM::LLVMFuncOp>("elm_bytebuffer_len");
        if (!dataFunc || !lenFunc)
            return failure();

        // Get data pointer
        auto dataCall = rewriter.create<LLVM::CallOp>(
            loc, dataFunc, ValueRange{adaptor.getBytes()});
        Value ptr = dataCall.getResult();

        // Get length
        auto lenCall = rewriter.create<LLVM::CallOp>(
            loc, lenFunc, ValueRange{adaptor.getBytes()});
        Value len = lenCall.getResult();

        // Compute end = ptr + len
        Value end = rewriter.create<LLVM::GEPOp>(
            loc, ptr.getType(), rewriter.getI8Type(), ptr, len);

        // Create cursor struct
        Type cursorType = getTypeConverter()->convertType(op.getType());
        Value cursor = createCursor(rewriter, loc, ptr, end, cursorType);

        rewriter.replaceOp(op, cursor);
        return success();
    }
};

/// Lower bf.cursor.ptr to extract current pointer.
struct CursorPtrOpLowering : public OpConversionPattern<bf::CursorPtrOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(CursorPtrOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());
        // Cast pointer to i64
        Value ptrAsInt = rewriter.create<LLVM::PtrToIntOp>(
            loc, rewriter.getI64Type(), ptr);
        rewriter.replaceOp(op, ptrAsInt);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Pass Definition
//===----------------------------------------------------------------------===//

struct BFToLLVMPass : public PassWrapper<BFToLLVMPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(BFToLLVMPass)

    StringRef getArgument() const override { return "bf-to-llvm"; }
    StringRef getDescription() const override {
        return "Lower BF dialect to LLVM dialect";
    }

    void getDependentDialects(DialectRegistry &registry) const override {
        registry.insert<LLVM::LLVMDialect>();
        registry.insert<bf::BFDialect>();
    }

    void runOnOperation() override {
        ModuleOp module = getOperation();
        MLIRContext *ctx = &getContext();

        // Ensure runtime functions are declared
        OpBuilder builder(ctx);
        ensureRuntimeFunctions(module, builder);

        // Set up type converter
        BFTypeConverter typeConverter(ctx);

        // Set up conversion target
        ConversionTarget target(*ctx);
        target.addLegalDialect<LLVM::LLVMDialect>();
        target.addIllegalDialect<bf::BFDialect>();

        // Populate patterns
        RewritePatternSet patterns(ctx);
        patterns.add<
            // Allocation and cursor init
            AllocOpLowering,
            CursorInitOpLowering,
            CursorPtrOpLowering,
            DecoderCursorInitOpLowering,
            // Write operations (encoder)
            WriteU8OpLowering,
            WriteU16OpLowering,
            WriteU32OpLowering,
            WriteF32OpLowering,
            WriteF64OpLowering,
            WriteBytesOpLowering,
            WriteUtf8OpLowering,
            // Width operations
            Utf8WidthOpLowering,
            BytesWidthOpLowering,
            // Bounds check
            RequireOpLowering,
            // Read operations (decoder)
            ReadU8OpLowering,
            ReadI8OpLowering,
            ReadU16OpLowering,
            ReadI16OpLowering,
            ReadU32OpLowering,
            ReadI32OpLowering,
            ReadF32OpLowering,
            ReadF64OpLowering,
            ReadBytesOpLowering,
            ReadUtf8OpLowering
        >(typeConverter, ctx);

        if (failed(applyPartialConversion(module, target, std::move(patterns))))
            signalPassFailure();
    }
};

} // anonymous namespace

//===----------------------------------------------------------------------===//
// Pass Registration
//===----------------------------------------------------------------------===//

namespace eco {

std::unique_ptr<Pass> createBFToLLVMPass() {
    return std::make_unique<BFToLLVMPass>();
}

} // namespace eco
