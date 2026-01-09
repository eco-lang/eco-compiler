//===- EcoToLLVMInternal.h - Internal helpers for EcoToLLVM pass ----------===//
//
// This file defines internal helpers, constants, and utilities used by the
// modularized EcoToLLVM pass. This header is NOT part of the public API.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_TO_LLVM_INTERNAL_H
#define ECO_TO_LLVM_INTERNAL_H

#include "mlir/Conversion/LLVMCommon/TypeConverter.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/Transforms/DialectConversion.h"

#include <vector>

namespace eco {
namespace detail {

//===----------------------------------------------------------------------===//
// Type Converter
//===----------------------------------------------------------------------===//

/// Type converter that converts eco.value to i64 (tagged pointer representation).
/// Implements CGEN_012: MInt->i64, MFloat->f64, MBool->i1, MChar->i32, others->eco.value->i64.
class EcoTypeConverter : public mlir::LLVMTypeConverter {
public:
    explicit EcoTypeConverter(mlir::MLIRContext *ctx);
};

//===----------------------------------------------------------------------===//
// Value Encoding Constants (HEAP_008, HEAP_010, HEAP_014)
//===----------------------------------------------------------------------===//

namespace value_enc {

/// Number of bits for heap offset in HPointer (40 bits = 1TB address space).
constexpr unsigned HeapOffsetBits = 40;

/// Shift amount for constant field in HPointer.
constexpr unsigned ConstFieldShift = HeapOffsetBits;

/// Mask for constant field (4 bits).
constexpr uint64_t ConstFieldMask = 0xF;

/// Embedded constant kinds (matches HPointer::ConstantKind in Heap.hpp).
enum ConstantKind : uint64_t {
    Unit        = 1,
    EmptyRec    = 2,
    True        = 3,
    False       = 4,
    Nil         = 5,
    Nothing     = 6,
    EmptyString = 7
};

/// Encode a constant kind into HPointer format.
inline int64_t encodeConstant(int kind) {
    return static_cast<int64_t>(kind) << ConstFieldShift;
}

} // namespace value_enc

//===----------------------------------------------------------------------===//
// Layout Constants (HEAP_001, HEAP_002, XPHASE_001)
//===----------------------------------------------------------------------===//

namespace layout {

/// Size of object header in bytes.
constexpr uint64_t HeaderSize = 8;

/// Pointer size in bytes.
constexpr uint64_t PtrSize = 8;

/// Object alignment (all heap objects are 8-byte aligned per HEAP_002).
constexpr uint64_t Alignment = 8;

// Cons layout: [Header:8][head:8][tail:8]
constexpr uint64_t ConsHeadOffset = HeaderSize;
constexpr uint64_t ConsTailOffset = HeaderSize + PtrSize;

// Tuple2 layout: [Header:8][a:8][b:8]
constexpr uint64_t Tuple2FirstOffset = HeaderSize;

// Tuple3 layout: [Header:8][a:8][b:8][c:8]
constexpr uint64_t Tuple3FirstOffset = HeaderSize;

// Record layout: [Header:8][unboxed_bitmap:8][fields:N*8]
constexpr uint64_t RecordUnboxedOffset = HeaderSize;
constexpr uint64_t RecordFieldsOffset = HeaderSize + PtrSize;

// Custom layout: [Header:8][ctor_unboxed:8][fields:N*8]
// Note: ctor is in lower 16 bits, unboxed bitmap in upper 48 bits
constexpr uint64_t CustomCtorOffset = HeaderSize;
constexpr uint64_t CustomFieldsOffset = HeaderSize + PtrSize;

// Closure layout: [Header:8][packed:8][evaluator:8][values:N*8]
// packed = n_values:6 | max_values:6 | unboxed:52
constexpr uint64_t ClosurePackedOffset = HeaderSize;
constexpr uint64_t ClosureEvaluatorOffset = HeaderSize + PtrSize;
constexpr uint64_t ClosureValuesOffset = HeaderSize + 2 * PtrSize;

} // namespace layout

//===----------------------------------------------------------------------===//
// Runtime Function Helper
//===----------------------------------------------------------------------===//

/// Lightweight helper for declaring and caching runtime function references.
/// Passed by value to pattern population functions (cheap to copy since it
/// only holds a ModuleOp handle and context pointer).
/// Note: module is mutable to allow getOrCreate methods to be const while
/// still being able to insert function declarations.
struct EcoRuntime {
    mutable mlir::ModuleOp module;
    mlir::MLIRContext *ctx;

    explicit EcoRuntime(mlir::ModuleOp m) : module(m), ctx(m.getContext()) {}

    /// Get or create a runtime function declaration.
    mlir::LLVM::LLVMFuncOp getOrCreateFunc(
        mlir::OpBuilder &builder,
        llvm::StringRef name,
        mlir::LLVM::LLVMFunctionType funcType) const;

    // Allocation functions
    mlir::LLVM::LLVMFuncOp getOrCreateAllocInt(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocFloat(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocChar(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocCons(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocTuple2(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocTuple3(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocRecord(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocCustom(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocString(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocStringLiteral(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocClosure(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocate(mlir::OpBuilder &builder) const;

    // Field storage functions
    mlir::LLVM::LLVMFuncOp getOrCreateStoreField(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateStoreFieldI64(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateStoreFieldF64(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateStoreRecordField(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateStoreRecordFieldI64(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateStoreRecordFieldF64(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateSetUnboxed(mlir::OpBuilder &builder) const;

    // Closure functions
    mlir::LLVM::LLVMFuncOp getOrCreatePapExtend(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateClosureCallSaturated(mlir::OpBuilder &builder) const;

    // Utility functions
    mlir::LLVM::LLVMFuncOp getOrCreateResolveHPtr(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateCrash(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateGcAddRoot(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateIntPow(mlir::OpBuilder &builder) const;

    // Debug functions
    mlir::LLVM::LLVMFuncOp getOrCreateDbgPrint(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateDbgPrintInt(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateDbgPrintFloat(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateDbgPrintChar(mlir::OpBuilder &builder) const;

    // Libc math functions
    mlir::LLVM::LLVMFuncOp getOrCreateAsin(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAcos(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAtan(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAtan2(mlir::OpBuilder &builder) const;
};

//===----------------------------------------------------------------------===//
// Control Flow Context
//===----------------------------------------------------------------------===//

/// Per-pass context for control flow lowering.
/// Stores joinpoint block mappings keyed by (function, joinpoint-id) to avoid
/// clashes across functions and eliminate static global state.
struct EcoCFContext {
    /// Map from (parent function op, joinpoint id) to the created block.
    llvm::DenseMap<std::pair<mlir::Operation*, int64_t>, mlir::Block*> joinpointBlocks;

    /// Clear the context (called at start of each module conversion).
    void clear() { joinpointBlocks.clear(); }
};

//===----------------------------------------------------------------------===//
// String Conversion Utilities
//===----------------------------------------------------------------------===//

/// Convert UTF-8 string to UTF-16 (used for string literals).
std::vector<uint16_t> utf8ToUtf16(llvm::StringRef utf8);

//===----------------------------------------------------------------------===//
// Pattern Population Functions (Internal)
//===----------------------------------------------------------------------===//

/// Populate patterns for eco.constant and eco.string_literal.
void populateEcoTypePatterns(
    EcoTypeConverter &typeConverter,
    mlir::RewritePatternSet &patterns,
    EcoRuntime runtime);

/// Populate patterns for heap operations (box, unbox, allocate, construct, project).
void populateEcoHeapPatterns(
    EcoTypeConverter &typeConverter,
    mlir::RewritePatternSet &patterns,
    EcoRuntime runtime);

/// Populate patterns for closure operations (papCreate, papExtend, call).
void populateEcoClosurePatterns(
    EcoTypeConverter &typeConverter,
    mlir::RewritePatternSet &patterns,
    EcoRuntime runtime);

/// Populate patterns for control flow (case, joinpoint, jump, return, get_tag).
void populateEcoControlFlowPatterns(
    EcoTypeConverter &typeConverter,
    mlir::RewritePatternSet &patterns,
    EcoRuntime runtime,
    EcoCFContext &cfCtx);

/// Populate patterns for arithmetic, comparisons, bitwise, and type conversions.
void populateEcoArithPatterns(
    EcoTypeConverter &typeConverter,
    mlir::RewritePatternSet &patterns);

/// Populate arithmetic patterns that need runtime function declarations.
void populateEcoArithPatternsWithRuntime(
    EcoTypeConverter &typeConverter,
    mlir::RewritePatternSet &patterns,
    EcoRuntime runtime);

/// Populate patterns for global variables.
void populateEcoGlobalPatterns(
    EcoTypeConverter &typeConverter,
    mlir::RewritePatternSet &patterns);

/// Populate patterns for error handling, debug, and safepoints.
void populateEcoErrorDebugPatterns(
    EcoTypeConverter &typeConverter,
    mlir::RewritePatternSet &patterns,
    EcoRuntime runtime);

/// Populate patterns for kernel function lowering.
void populateEcoFuncPatterns(
    EcoTypeConverter &typeConverter,
    mlir::RewritePatternSet &patterns);

/// Generate the __eco_init_globals function to register GC roots.
void createGlobalRootInitFunction(
    mlir::ModuleOp module,
    EcoRuntime &runtime);

} // namespace detail
} // namespace eco

#endif // ECO_TO_LLVM_INTERNAL_H
