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

#include "mlir/IR/SymbolTable.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/StringMap.h"
#include <vector>

namespace eco {
namespace detail {

//===----------------------------------------------------------------------===//
// Type Converter
//===----------------------------------------------------------------------===//

/// Type converter that converts eco.value to ptr addrspace(1) (GC-managed pointer).
/// Implements CGEN_012: MInt->i64, MFloat->f64, MBool->i1, MChar->i32, others->eco.value->ptr<1>.
class EcoTypeConverter : public mlir::LLVMTypeConverter {
public:
    explicit EcoTypeConverter(mlir::MLIRContext *ctx);
};

//===----------------------------------------------------------------------===//
// HPointer Type Helpers
//===----------------------------------------------------------------------===//

/// Return the LLVM type used for GC-managed HPointers: ptr addrspace(1).
inline mlir::Type getHPtrLLVMType(mlir::MLIRContext &ctx) {
    return mlir::LLVM::LLVMPointerType::get(&ctx, /*addressSpace=*/1);
}

/// Check whether a type is the HPointer LLVM representation (ptr addrspace(1)).
inline bool isHPtrLLVMType(mlir::Type t) {
    if (auto ptrTy = mlir::dyn_cast<mlir::LLVM::LLVMPointerType>(t))
        return ptrTy.getAddressSpace() == 1;
    return false;
}

/// Convert an SSA value to i64 for storage in a heap slot or runtime call.
/// If the value is ptr<1>, emit ptrtoint. If already i64, pass through.
inline mlir::Value valueToI64(mlir::OpBuilder &builder, mlir::Location loc, mlir::Value v) {
    if (v.getType().isInteger(64))
        return v;
    if (isHPtrLLVMType(v.getType())) {
        auto i64Ty = mlir::IntegerType::get(builder.getContext(), 64);
        return builder.create<mlir::LLVM::PtrToIntOp>(loc, i64Ty, v);
    }
    return v;
}

/// Convert an i64 value loaded from a heap slot to ptr<1> (HPointer).
/// If already ptr<1>, pass through.
inline mlir::Value i64ToValue(mlir::OpBuilder &builder, mlir::Location loc, mlir::Value v) {
    if (isHPtrLLVMType(v.getType()))
        return v;
    if (v.getType().isInteger(64)) {
        auto hptrTy = mlir::LLVM::LLVMPointerType::get(builder.getContext(), /*addressSpace=*/1);
        return builder.create<mlir::LLVM::IntToPtrOp>(loc, hptrTy, v);
    }
    return v;
}

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

// Array layout: [Header:8][length:4][padding:4][elements:N*8]
constexpr uint64_t ArrayLengthOffset = HeaderSize;          // 8
constexpr uint64_t ArrayElementsOffset = HeaderSize + PtrSize; // 16 (length:4 + padding:4 = 8)

// Closure layout: [Header:8][packed:8][evaluator:8][values:N*8]
// packed = n_values:6 | max_values:6 | unboxed:52
constexpr uint64_t ClosurePackedOffset = HeaderSize;
constexpr uint64_t ClosureEvaluatorOffset = HeaderSize + PtrSize;
constexpr uint64_t ClosureValuesOffset = HeaderSize + 2 * PtrSize;

} // namespace layout

//===----------------------------------------------------------------------===//
// Runtime Function Helper
//===----------------------------------------------------------------------===//

/// Helper for declaring and caching runtime function references.
/// Passed by const reference to pattern population functions.
/// Note: module and caches are mutable to allow getOrCreate methods to be
/// const while still being able to insert function declarations and cache
/// lookup results.
struct EcoRuntime {
    mutable mlir::ModuleOp module;
    mlir::MLIRContext *ctx;

    /// Cached symbol map for O(1) lookups instead of O(N) module walks.
    /// Built lazily on first use from the module's top-level operations.
    mutable llvm::DenseMap<mlir::StringAttr, mlir::Operation*> symCache;

    /// Pre-scanned original function types (before LLVM type conversion).
    /// Maps function name -> original FunctionType (with eco::ValueType etc.).
    ///
    /// Populated exclusively from func::FuncOp declarations in the module
    /// (see EcoToLLVM.cpp pre-scan). For kernel functions (is_kernel=true),
    /// the types come from the Elm compiler's registerKernelCall +
    /// generateKernelDecl pipeline. EcoToLLVM must NOT attempt to infer or
    /// reconstruct these types from papCreate/papExtend usage.
    ///
    /// Missing entries for Elm_Kernel_* functions are treated as fatal errors
    /// in getOrCreateWrapper (CGEN_057).
    llvm::StringMap<mlir::FunctionType> origFuncTypes;

    explicit EcoRuntime(mlir::ModuleOp m) : module(m), ctx(m.getContext()) {}

    /// Ensure the symbol cache is populated from the module.
    void ensureSymCache() const {
        if (!symCache.empty()) return;
        for (auto &op : module.getBody()->getOperations()) {
            if (auto nameAttr = op.getAttrOfType<mlir::StringAttr>(
                    mlir::SymbolTable::getSymbolAttrName()))
                symCache[nameAttr] = &op;
        }
    }

    /// Register a newly created symbol in the cache.
    void cacheSymbol(mlir::Operation *op) const {
        if (auto nameAttr = op->getAttrOfType<mlir::StringAttr>(
                mlir::SymbolTable::getSymbolAttrName()))
            symCache[nameAttr] = op;
    }

    /// Look up a symbol in the module using the cached map (O(1)).
    template <typename T>
    T lookupSymbol(llvm::StringRef name) const {
        ensureSymCache();
        auto it = symCache.find(mlir::StringAttr::get(ctx, name));
        if (it == symCache.end()) return nullptr;
        return mlir::dyn_cast<T>(it->second);
    }

    /// Look up any operation by name using the cached map.
    mlir::Operation *lookupSymbol(llvm::StringRef name) const {
        ensureSymCache();
        auto it = symCache.find(mlir::StringAttr::get(ctx, name));
        if (it == symCache.end()) return nullptr;
        return it->second;
    }

    /// Get or create a runtime function declaration.
    mlir::LLVM::LLVMFuncOp getOrCreateFunc(
        mlir::OpBuilder &builder,
        llvm::StringRef name,
        mlir::LLVM::LLVMFunctionType funcType) const;

    // Allocation functions (original — may GC)
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

    // Fast allocation variants (bump-pointer only, no GC, return 0 on failure)
    mlir::LLVM::LLVMFuncOp getOrCreateAllocIntFast(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocFloatFast(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocCharFast(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocConsFast(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocTuple2Fast(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocTuple3Fast(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocRecordFast(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocCustomFast(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocStringFast(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocClosureFast(mlir::OpBuilder &builder) const;

    // Slow allocation variants (may GC, always succeed — used behind statepoint)
    mlir::LLVM::LLVMFuncOp getOrCreateAllocIntSlow(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocFloatSlow(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocCharSlow(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocConsSlow(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocTuple2Slow(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocTuple3Slow(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocRecordSlow(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocCustomSlow(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocStringSlow(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocClosureSlow(mlir::OpBuilder &builder) const;

    // Region allocation (fast returns nullptr, slow may GC)
    mlir::LLVM::LLVMFuncOp getOrCreateAllocRegionFast(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocRegionSlow(mlir::OpBuilder &builder) const;

    // Init-at-pointer functions (for group allocation)
    mlir::LLVM::LLVMFuncOp getOrCreateInitIntAt(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateInitFloatAt(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateInitCharAt(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateInitConsAt(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateInitTuple2At(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateInitTuple3At(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateInitRecordAt(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateInitCustomAt(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateInitStringAt(mlir::OpBuilder &builder) const;

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
    mlir::LLVM::LLVMFuncOp getOrCreateApplyClosure(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateApplySegmentationUnknown(mlir::OpBuilder &builder) const;

    // Utility functions
    mlir::LLVM::LLVMFuncOp getOrCreateResolveHPtr(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateGetTag(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateConsHeadI64(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateConsHeadF64(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateConsHeadI16(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateCrash(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateGcAddRoot(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateGcStackRangePoint(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateGcPushStackRange(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateGcRestoreStackRangePoint(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateRegisterTypeGraph(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateIntPow(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateUtilsEqual(mlir::OpBuilder &builder) const;

    // Array functions
    mlir::LLVM::LLVMFuncOp getOrCreateCloneArray(mlir::OpBuilder &builder) const;

    // Safepoint marker function
    mlir::LLVM::LLVMFuncOp getOrCreateSafepointMarker(mlir::OpBuilder &builder) const;

    // Debug functions
    mlir::LLVM::LLVMFuncOp getOrCreateDbgPrint(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateDbgPrintInt(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateDbgPrintFloat(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateDbgPrintChar(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateDbgPrintTyped(mlir::OpBuilder &builder) const;

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
// Allocation with Safepoint Marker
//===----------------------------------------------------------------------===//

/// Emit a safepoint marker + allocation call. The liveRoots parameter
/// contains pre-converted (i64) GC roots from the op adaptor — these were
/// computed by EcoGCPrepare at the Eco IR level and carried as explicit
/// operands through type conversion. Lowering must NOT recompute liveness.
/// No block splitting — safe to use inside structured regions (scf.if etc).
mlir::Value emitAllocWithSafepoint(
    mlir::Operation *op,
    mlir::ConversionPatternRewriter &rewriter,
    const EcoRuntime &runtime,
    mlir::LLVM::LLVMFuncOp allocFunc,
    mlir::ValueRange args,
    mlir::ValueRange liveRoots);

/// Emit a safepoint marker before a call. Like emitAllocWithSafepoint but
/// does NOT emit the call itself — the caller is responsible for creating
/// the actual LLVM call after this returns. This allows the marker to be
/// placed before direct calls, indirect calls, or func::CallOps.
void emitSafepointMarker(
    mlir::Operation *op,
    mlir::ConversionPatternRewriter &rewriter,
    const EcoRuntime &runtime,
    mlir::ValueRange liveRoots);

/// Emit __eco_safepoint_marker in a wrapper function body.
/// Unlike emitSafepointMarker, this takes OpBuilder & and Location directly
/// (no source Operation* needed), making it suitable for use inside
/// getOrCreateWrapper where we build a new function body.
/// liveRoots: i64 SSA values representing HPointers that must survive GC.
void emitWrapperSafepointMarker(
    mlir::OpBuilder &builder,
    const EcoRuntime &runtime,
    mlir::Location loc,
    mlir::ValueRange liveRoots);

//===----------------------------------------------------------------------===//
// Pattern Population Functions (Internal)
//===----------------------------------------------------------------------===//

/// Populate patterns for eco.constant and eco.string_literal.
void populateEcoTypePatterns(
    EcoTypeConverter &typeConverter,
    mlir::RewritePatternSet &patterns,
    const EcoRuntime &runtime);

/// Lower allocation groups with eco.gc_group_size > 1 into fast/slow/merge CFG.
/// Must run before applyFullConversion — operates on Eco+LLVM mixed IR.
/// Groups are erased; remaining singleton allocs are lowered by per-op patterns.
void lowerAllocGroups(mlir::ModuleOp module, const EcoRuntime &runtime);

/// Populate patterns for heap operations (box, unbox, allocate, construct, project).
void populateEcoHeapPatterns(
    EcoTypeConverter &typeConverter,
    mlir::RewritePatternSet &patterns,
    const EcoRuntime &runtime);

/// Populate patterns for closure operations (papCreate, papExtend, call).
void populateEcoClosurePatterns(
    EcoTypeConverter &typeConverter,
    mlir::RewritePatternSet &patterns,
    const EcoRuntime &runtime);

/// Populate patterns for control flow (case, joinpoint, jump, return, get_tag).
void populateEcoControlFlowPatterns(
    EcoTypeConverter &typeConverter,
    mlir::RewritePatternSet &patterns,
    const EcoRuntime &runtime,
    EcoCFContext &cfCtx);

/// Populate patterns for arithmetic, comparisons, bitwise, and type conversions.
void populateEcoArithPatterns(
    EcoTypeConverter &typeConverter,
    mlir::RewritePatternSet &patterns);

/// Populate arithmetic patterns that need runtime function declarations.
void populateEcoArithPatternsWithRuntime(
    EcoTypeConverter &typeConverter,
    mlir::RewritePatternSet &patterns,
    const EcoRuntime &runtime);

/// Populate patterns for global variables.
void populateEcoGlobalPatterns(
    EcoTypeConverter &typeConverter,
    mlir::RewritePatternSet &patterns);

/// Populate patterns for error handling, debug, and safepoints.
void populateEcoErrorDebugPatterns(
    EcoTypeConverter &typeConverter,
    mlir::RewritePatternSet &patterns,
    const EcoRuntime &runtime);

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
