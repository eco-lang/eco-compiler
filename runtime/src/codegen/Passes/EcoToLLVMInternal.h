//===- EcoToLLVMInternal.h - Internal helpers for EcoToLLVM pass ----------===//
//
// This file defines internal helpers, constants, and utilities used by the
// modularized EcoToLLVM pass. This header is NOT part of the public API.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_TO_LLVM_INTERNAL_H
#define ECO_TO_LLVM_INTERNAL_H

#include "EcoSlotCastBarriers.h"

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
#include <mutex>

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

/// Raw primitive: convert an SSA value to i64 for storage.
/// If the value is ptr<1>, emit ptrtoint. If already i64, pass through.
/// Prefer the role-specific wrappers below for new code.
inline mlir::Value valueToI64(mlir::OpBuilder &builder, mlir::Location loc, mlir::Value v) {
    if (v.getType().isInteger(64))
        return v;
    if (isHPtrLLVMType(v.getType())) {
        auto i64Ty = mlir::IntegerType::get(builder.getContext(), 64);
        return builder.create<mlir::LLVM::PtrToIntOp>(loc, i64Ty, v);
    }
    return v;
}

/// Raw primitive: convert an i64 value to ptr<1> (HPointer).
/// If already ptr<1>, pass through.
/// Prefer the role-specific wrappers below for new code.
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
// Fold-proof boxed-slot crossings (REP_LLVM_002)
//
// plans/fold-proof-boxed-slot-crossings.md: the pre-RS4GC AlwaysInliner
// (`runCapInlinePrepass`) annihilates raw inttoptr/ptrtoint pairs met across
// an inlining seam (`ptrtoint(inttoptr(x)) -> x`), leaving a raw i64 live
// across the spliced body's statepoints — invisible to RS4GC, stale on GC.
// The slot-crossing forms below therefore emit the crossing as a call to a
// declare-only gc-leaf barrier (see EcoSlotCastBarriers.h) that no inliner
// can fold through; StripEcoCastBarriers restores the bare cast strictly
// post-RS4GC. Pass-through parity with the raw primitives is REQUIRED: a
// barrier is emitted exactly where the raw form would emit a cast, so the
// pre-RS4GC IR is a 1:1 cast->call swap (same instruction count/positions —
// keeps `bodyIsGCCallFree` and the `$cap` inline threshold env-invariant).
//
// The barrier declarations are pre-materialized unconditionally
// (materializeAllRuntimeDecls), so emitting by symbol name here is always
// resolvable; with barriers disabled the unused decls are erased by the
// EcoToLLVM unused-decl strip, restoring today's exact symbol set.
//===----------------------------------------------------------------------===//

/// Slot-crossing form of valueToI64: ptr<1> -> i64 for a boxed-slot STORE.
/// Emits the __eco_hptr_to_slot barrier (bare ptrtoint when barriers are off).
inline mlir::Value slotValueToI64(mlir::OpBuilder &builder, mlir::Location loc, mlir::Value v) {
    if (v.getType().isInteger(64))
        return v;
    if (isHPtrLLVMType(v.getType())) {
        auto i64Ty = mlir::IntegerType::get(builder.getContext(), 64);
        if (slotCastBarriersEnabled())
            return builder
                .create<mlir::LLVM::CallOp>(loc, mlir::TypeRange{i64Ty},
                                            llvm::StringRef(kHPtrToSlotSym),
                                            mlir::ValueRange{v})
                .getResult();
        return builder.create<mlir::LLVM::PtrToIntOp>(loc, i64Ty, v);
    }
    return v;
}

/// Slot-crossing form of i64ToValue: i64 -> ptr<1> for a boxed-slot LOAD.
/// Emits the __eco_slot_to_hptr barrier (bare inttoptr when barriers are off).
inline mlir::Value slotI64ToValue(mlir::OpBuilder &builder, mlir::Location loc, mlir::Value v) {
    if (isHPtrLLVMType(v.getType()))
        return v;
    if (v.getType().isInteger(64)) {
        auto hptrTy = mlir::LLVM::LLVMPointerType::get(builder.getContext(), /*addressSpace=*/1);
        if (slotCastBarriersEnabled())
            return builder
                .create<mlir::LLVM::CallOp>(loc, mlir::TypeRange{hptrTy},
                                            llvm::StringRef(kSlotToHPtrSym),
                                            mlir::ValueRange{v})
                .getResult();
        return builder.create<mlir::LLVM::IntToPtrOp>(loc, hptrTy, v);
    }
    return v;
}

//===----------------------------------------------------------------------===//
// Role-specific ptr<1> ↔ i64 boundary helpers
//
// Each helper documents the single allowed pattern it authorizes.
// The verifier pass (EcoPtrIntVerify) can key diagnostics on these roles.
// Result of store helpers must be consumed immediately by a StoreOp or
// gc-leaf CallOp argument — never reused across calls.
//===----------------------------------------------------------------------===//

/// Heap field store: ptr<1> → i64 for storing into a heap object field.
/// Result must be immediately stored via StoreOp into a heap struct slot.
/// Fold-proof (REP_LLVM_002): emits the slot-cast barrier form.
inline mlir::Value heapStoreValueToI64(mlir::OpBuilder &b, mlir::Location loc, mlir::Value v) {
    return slotValueToI64(b, loc, v);
}

/// Heap field load: i64 loaded from a heap object field → ptr<1>.
/// Operand must come directly from a LoadOp on a heap struct GEP.
/// Fold-proof (REP_LLVM_002): emits the slot-cast barrier form.
inline mlir::Value heapLoadI64ToValue(mlir::OpBuilder &b, mlir::Location loc, mlir::Value v) {
    return slotI64ToValue(b, loc, v);
}

/// Global store: ptr<1> → i64 for storing into a module-level eco.value global.
/// Result must be immediately stored via StoreOp into the global address.
/// Fold-proof (REP_LLVM_002): emits the slot-cast barrier form.
inline mlir::Value globalStoreValueToI64(mlir::OpBuilder &b, mlir::Location loc, mlir::Value v) {
    return slotValueToI64(b, loc, v);
}

/// Global load: i64 loaded from a module-level eco.value global → ptr<1>.
/// Operand must come directly from a LoadOp on a global AddressOfOp.
/// Fold-proof (REP_LLVM_002): emits the slot-cast barrier form.
inline mlir::Value globalLoadI64ToValue(mlir::OpBuilder &b, mlir::Location loc, mlir::Value v) {
    return slotI64ToValue(b, loc, v);
}

/// Closure store: ptr<1> → i64 for storing into Closure.values[] slots.
/// Result must be immediately stored via StoreOp into a closure values GEP.
/// Fold-proof (REP_LLVM_002): emits the slot-cast barrier form.
inline mlir::Value closureStoreValueToI64(mlir::OpBuilder &b, mlir::Location loc, mlir::Value v) {
    return slotValueToI64(b, loc, v);
}

/// Closure load: i64 loaded from Closure.values[] → ptr<1>.
/// Operand must come directly from a LoadOp on a closure values GEP.
/// Fold-proof (REP_LLVM_002): emits the slot-cast barrier form.
inline mlir::Value closureLoadI64ToValue(mlir::OpBuilder &b, mlir::Location loc, mlir::Value v) {
    return slotI64ToValue(b, loc, v);
}

/// Args-array store: ptr<1> → i64 for storing into a stack-allocated args
/// buffer registered via eco_gc_push_stack_range.
/// Result must be immediately stored via StoreOp into an args alloca slot.
/// Fold-proof (REP_LLVM_002): emits the slot-cast barrier form.
inline mlir::Value argsSlotStoreValueToI64(mlir::OpBuilder &b, mlir::Location loc, mlir::Value v) {
    return slotValueToI64(b, loc, v);
}

/// Args-array load: i64 loaded from an args alloca slot → ptr<1>.
/// Operand must come directly from a LoadOp on an args alloca GEP.
/// Fold-proof (REP_LLVM_002): emits the slot-cast barrier form.
inline mlir::Value argsSlotLoadI64ToValue(mlir::OpBuilder &b, mlir::Location loc, mlir::Value v) {
    return slotI64ToValue(b, loc, v);
}

/// ADT case scrutinee: ptr<1> → i64 for tag bit-tests.
/// Result must stay within the same basic block and be consumed only by
/// lshr/and/icmp bit-test chains — never stored or passed across calls.
inline mlir::Value caseScrutineeToI64(mlir::OpBuilder &b, mlir::Location loc, mlir::Value v) {
    return valueToI64(b, loc, v);
}

/// Wrapper return bridging: ptr<1> → i64 → ptr AS0.
/// This is the only GC-world → AS0 exit path for HPointers.
/// Used by evaluator wrapper functions to return values in the runtime ABI.
inline mlir::Value wrapperReturnValueToPtr0(mlir::OpBuilder &b, mlir::Location loc,
                                            mlir::Value v, mlir::Type retPtrTy) {
    mlir::Value asI64 = valueToI64(b, loc, v);
    return b.create<mlir::LLVM::IntToPtrOp>(loc, retPtrTy, mlir::ValueRange{asI64});
}

/// Wrapper arg-slot unboxing: load i64 from wrapper args alloca, convert
/// to the target type (ptr<1> for !eco.value, or pass through for primitives).
/// The loadOp must be a LoadOp from the wrapper's args array GEP.
/// The ptr<1> branch is a boxed-slot crossing → fold-proof (REP_LLVM_002);
/// the plain-AS0 branch below is kernel-pointer ABI, not a GC crossing.
inline mlir::Value wrapperLoadArgSlotToValue(mlir::OpBuilder &b, mlir::Location loc,
                                             mlir::Value loadedI64, mlir::Type targetType) {
    if (isHPtrLLVMType(targetType))
        return slotI64ToValue(b, loc, loadedI64);
    if (mlir::isa<mlir::LLVM::LLVMPointerType>(targetType))
        return b.create<mlir::LLVM::IntToPtrOp>(loc, targetType, mlir::ValueRange{loadedI64});
    return loadedI64;
}

//===----------------------------------------------------------------------===//
// Value Encoding Constants (HEAP_008, HEAP_010, HEAP_014)
//===----------------------------------------------------------------------===//

namespace value_enc {

/// Bit position of ptr_ind, the pointer/non-pointer discriminator. Must match
/// PTR_IND_BIT in Heap.hpp. The `ptr` field begins at PtrIndBit + 1 = bit 3.
constexpr unsigned PtrIndBit = 2;

/// Mask for the 2-bit constant field (bits 0-1).
constexpr uint64_t ConstFieldMask = 0x3;

/// Embedded constant kinds (must match the Constant enum in Heap.hpp): bit 0 is
/// the Bool value, bit 1 is the Empty flag. See plan D3.
enum ConstantKind : uint64_t {
    False = 0,
    True  = 1,
    Empty = 2,  // unifies Unit / EmptyRec / Nil / Nothing / ""
};

/// Encode a constant kind into an HPointer word: set ptr_ind (bit 2) and the
/// 2-bit constant field; ptr / enum_idx / padding are all zero. So False -> 0x4,
/// True -> 0x5, Empty -> 0x6. Plan D6.
inline int64_t encodeConstant(int kind) {
    return (static_cast<int64_t>(1) << PtrIndBit) | static_cast<int64_t>(kind);
}

/// Reserved constructor tag emitted for embedded "empty" constant branches. Must
/// match CONSTANT_TAG in Heap.hpp and Compiler.Data.CtorTag.constantTag. See D9.
constexpr int64_t ConstantTag = 0xFFFD;

/// Number of low bits of the object Header's first word occupied by the `tag`
/// field. Must match TAG_BITS in Heap.hpp. Used by the inline-deref expansion to
/// mask the tag out of a loaded header word.
constexpr unsigned TagBits = 5;

/// The `Tag_Forward` enumerator value: a header carrying this tag is a
/// forwarding tombstone left by old-gen compaction; the inline-deref fast path
/// tests for it and defers to eco_follow_forward. Must match the position of
/// `Tag_Forward` in the `Tag` enum in Heap.hpp. A static_assert in
/// EcoToLLVMHeap.cpp cross-checks this against the enum so the two cannot drift.
constexpr int64_t TagForward = 26; // After Tag_ConsChunk/Tag_ListBacking (chunked lists, L1.2).

/// `Tag_Cons` / `Tag_Custom` enumerator values, needed by the P2.5 inline
/// eco.get_tag lowering (plans/allocator-resolve-inlining.md R1b): the tag
/// discriminates the Cons→1 / Custom→ctor / other→0 result exactly as the
/// runtime eco_get_tag does. Cross-checked by static_asserts in
/// EcoToLLVMHeap.cpp alongside TagForward.
constexpr int64_t TagCons = 6;
constexpr int64_t TagCustom = 7;

/// Header-word composition for the inline nursery allocation fast path
/// (plans/inline-nursery-allocation.md, HEAP_034). The Header bitfields
/// (Heap.hpp) pack LSB-first as tag:5 | color:2 | pin:1 | age:2 | unboxed:6 |
/// refcount:15 | builder:1 | size:32; at allocation everything except tag,
/// unboxed, and size is zero, so one i64 constant fully initializes the
/// header. Bitfield packing is implementation-defined and therefore NOT
/// static_assert-able — the equivalence is pinned at runtime by
/// testHeaderWordComposition (test/allocator/HPointerLayoutTest.cpp), the
/// same discipline as the HPointer golden words.
constexpr unsigned HeaderUnboxedShift = 10;  // tag:5 + color:2 + pin:1 + age:2
constexpr unsigned HeaderSizeShift = 32;
constexpr uint64_t composeHeader(uint64_t tag, uint64_t unboxedBits,
                                 uint64_t sizeField) {
    return tag | (unboxedBits << HeaderUnboxedShift)
               | (sizeField << HeaderSizeShift);
}

/// Remaining Tag enumerator values needed to compose inline-alloc headers.
/// Cross-checked by static_asserts in EcoToLLVMHeap.cpp alongside
/// TagForward/TagCons/TagCustom.
constexpr int64_t TagInt = 0;
constexpr int64_t TagFloat = 1;
constexpr int64_t TagChar = 2;
constexpr int64_t TagTuple2 = 4;
constexpr int64_t TagTuple3 = 5;
constexpr int64_t TagRecord = 8;
constexpr int64_t TagClosure = 11;

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
// packed = n_values:6 | max_values:6 | unboxed:50 | flags:2
constexpr uint64_t ClosurePackedOffset = HeaderSize;
constexpr uint64_t ClosureEvaluatorOffset = HeaderSize + PtrSize;
constexpr uint64_t ClosureValuesOffset = HeaderSize + 2 * PtrSize;

// Inline-alloc fixed byte sizes (HEAP_034,
// plans/inline-nursery-allocation.md); pinned against the runtime structs by
// static_asserts in EcoToLLVMHeap.cpp (the one pass file that includes
// Heap.hpp).
constexpr uint64_t BoxedPrimSize = 16;   // ElmInt / ElmFloat / ElmChar
constexpr uint64_t ConsSize = 24;        // Header + head + tail
constexpr uint64_t Tuple2Size = 24;      // Header + a + b
constexpr uint64_t Tuple3Size = 32;      // Header + a + b + c
constexpr uint64_t RecordBaseSize = 16;  // Header + unboxed bitmap (+ N*8)
constexpr uint64_t CustomBaseSize = 16;  // Header + ctor/unboxed (+ N*8)
constexpr uint64_t ClosureBaseSize = 24; // Header + packed + evaluator (+ N*8)

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

    /// Eval-layout globals are the one artifact class whose exact demand cannot
    /// be pre-derived (the 4 getOrCreateEvalLayout call sites compute `kinds`
    /// from a path-specific type mix), so they are still created on demand
    /// during parallel Stage 2. They live OUTSIDE symCache — referenced only by
    /// name via AddressOfOp, never looked up — so guarding just their dedup set
    /// + creation with this dedicated mutex keeps the hot symCache LOCK-FREE.
    /// Contention is low: taken per closure-apply site, not per symbol ref.
    mutable llvm::DenseSet<mlir::StringAttr> evalLayoutNames;
    mutable std::mutex evalLayoutMutex;

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

    /// Monotonic counter for naming string-literal globals (__eco_str_N).
    /// Per-instance (not a function-local static) so names are deterministic
    /// per module conversion and don't leak/grow across compilations sharing
    /// one process (e.g. the JIT test runner).
    mutable uint64_t stringLiteralCounter = 0;

    /// Cache of UTF-8 -> UTF-16 conversions for string-case pattern literals,
    /// keyed by pattern content. Avoids re-running utf8ToUtf16 for repeated
    /// identical patterns during string-case lowering. Pass-lifetime: fresh
    /// per EcoRuntime instance (one is constructed per module conversion).
    mutable llvm::StringMap<std::vector<uint16_t>> utf16PatternCache;

    //===------------------------------------------------------------------===//
    // Parallel-Stage-2 support: freeze + pre-materialization side maps
    //===------------------------------------------------------------------===//

    /// Set by freeze() once serial pre-materialization is complete. While set,
    /// the module symbol table and every artifact cache are READ-ONLY so the
    /// body stage can run lock-free across functions. Any mutation after
    /// freeze() is a completeness bug (an artifact a body pattern demands was
    /// not pre-created) and trips a debug assertion.
    mutable bool frozen = false;

    /// StringLiteralOp -> assigned literal index N (global "__eco_str_N").
    /// Filled by preMaterializeStringLiterals(); read by StringLiteralOpLowering.
    mutable llvm::DenseMap<mlir::Operation *, uint64_t> stringLiteralIndexForOp;

    /// String-kind eco.case op -> assigned caseId (names its per-pattern
    /// "__eco_str_case_<caseId>_<i>" globals). Filled by preMaterializeStringCases.
    mutable llvm::DenseMap<mlir::Operation *, uint64_t> caseIdForOp;

    /// Force the symbol cache fully materialized, then mark the runtime frozen.
    /// Called once after serial pre-materialization, before body conversion.
    void freeze() const { ensureSymCache(); frozen = true; }

    /// Pre-create every runtime function declaration so body patterns only READ
    /// them. Declarations no op uses are dropped by the later internalize +
    /// globalDCE, so the emitted binary is unchanged. Must run before freeze().
    /// Defined in EcoToLLVMRuntime.cpp.
    void materializeAllRuntimeDecls(mlir::OpBuilder &builder) const;

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
        assert(!frozen &&
               "EcoRuntime::cacheSymbol() after freeze(): a Stage-2 body pattern "
               "created a module-level symbol pre-materialization missed "
               "(parallel-conversion UB)");
        if (auto nameAttr = op->getAttrOfType<mlir::StringAttr>(
                mlir::SymbolTable::getSymbolAttrName()))
            symCache[nameAttr] = op;
    }

    /// Look up a symbol in the module using the cached map (O(1)). LOCK-FREE:
    /// symCache is fully pre-materialized + frozen before parallel Stage 2, so
    /// it is READ-ONLY there (no writer races these reads). `frozen` guards the
    /// serial-only lazy build.
    template <typename T>
    T lookupSymbol(llvm::StringRef name) const {
        if (!frozen) ensureSymCache();
        auto it = symCache.find(mlir::StringAttr::get(ctx, name));
        if (it == symCache.end()) return nullptr;
        return mlir::dyn_cast<T>(it->second);
    }

    /// Look up any operation by name using the cached map. LOCK-FREE (see above).
    mlir::Operation *lookupSymbol(llvm::StringRef name) const {
        if (!frozen) ensureSymCache();
        auto it = symCache.find(mlir::StringAttr::get(ctx, name));
        if (it == symCache.end()) return nullptr;
        return it->second;
    }

    /// Get or create a runtime function declaration.
    /// If gcLeaf is true, the function is marked with gc-leaf-function
    /// (tells RS4GC not to insert a gc.statepoint around calls to it).
    mlir::LLVM::LLVMFuncOp getOrCreateFunc(
        mlir::OpBuilder &builder,
        llvm::StringRef name,
        mlir::LLVM::LLVMFunctionType funcType,
        bool gcLeaf = false) const;

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
    mlir::LLVM::LLVMFuncOp getOrCreateAllocStringLiteralUtf8(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocClosure(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocClosureK(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateInternClosure0(mlir::OpBuilder &builder) const;
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
    mlir::LLVM::LLVMFuncOp getOrCreateAllocClosureGroupSlow(mlir::OpBuilder &builder) const;

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

    // Uninit allocators + field stores (forward ABI; companion runtime
    // entries land here for future re-enable of the wrapper-fca-fix
    // plan's alloc-then-store pattern. See plans/wrapper-fca-fix.md
    // for the deferred lowering portions.).
    mlir::LLVM::LLVMFuncOp getOrCreateAllocTuple2Uninit(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocTuple3Uninit(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateAllocConsUninit(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateStoreTupleField(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateStoreTupleFieldI64(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateStoreTupleFieldF64(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateStoreConsHead(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateStoreConsHeadI64(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateStoreConsHeadF64(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateStoreConsTail(mlir::OpBuilder &builder) const;

    // Closure functions
    mlir::LLVM::LLVMFuncOp getOrCreatePapExtend(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateClosureCallSaturated(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateClosureCallSaturatedEval(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateApplyClosure(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateApplyClosureTyped(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateApplyClosureEval(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateApplySegmentationUnknown(mlir::OpBuilder &builder) const;

    // Utility functions
    mlir::LLVM::LLVMFuncOp getOrCreateResolveHPtr(mlir::OpBuilder &builder) const;

    // Inline-deref (plan P2) helpers. `__eco_resolve_fwd` is a marker call
    // emitted by heap-deref lowering: (ptr as1) -> (ptr as1), gc-leaf, expanded
    // to an inline forwarding-check diamond by the ExpandInlineDeref LLVM pass
    // before RS4GC. `eco_follow_forward` is the cold slow path it defers to.
    mlir::LLVM::LLVMFuncOp getOrCreateResolveFwdMarker(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateFollowForward(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateGetTag(mlir::OpBuilder &builder) const;
    // P2.5 R1b (plans/allocator-resolve-inlining.md): `__eco_get_tag_inline`
    // marker — (hptr) -> i32, gc-leaf, declare-only. Emitted by the
    // eco.get_tag lowering (which may sit inside single-block scf regions);
    // expanded to the open-coded emb/heap/Custom/Cons tag diamond by
    // expandGetTagMarkers (EcoBackend.cpp) before ExpandInlineDeref + RS4GC.
    mlir::LLVM::LLVMFuncOp getOrCreateGetTagInlineMarker(mlir::OpBuilder &builder) const;
    // Inline nursery allocation (plans/inline-nursery-allocation.md,
    // HEAP_034): `__eco_alloc_inline` marker — (i64 size) -> ptr as1,
    // gc-leaf, declare-only. Emitted by the converted construct/box/closure
    // lowerings (which may sit inside single-block scf regions); expanded to
    // the bump fast/slow diamond by expandInlineAllocs (EcoBackend.cpp)
    // before RS4GC and before partition splitting.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocInlineMarker(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateConsHeadI64(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateConsHeadF64(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateConsHeadI16(mlir::OpBuilder &builder) const;
    // Hybrid-spine (chunked-list) projections, used when the module carries
    // the eco.list_chunks attribute (plans/chunked-list-representation.md §6).
    // Head is non-allocating (gc-leaf); tail may MATERIALIZE a successor
    // chunk view (allocating — statepointed).
    mlir::LLVM::LLVMFuncOp getOrCreateListHeadHybrid(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateListTailHybrid(mlir::OpBuilder &builder) const;
    // Marker forms (expanded to cell-fast/chunk-slow diamonds pre-RS4GC by
    // expandListProjMarkers, EcoBackend.cpp).
    mlir::LLVM::LLVMFuncOp getOrCreateListHeadInlineMarker(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateListTailInlineMarker(mlir::OpBuilder &builder) const;
    /// True when the module being lowered carries `eco.list_chunks` (set at
    /// EcoToLLVM pass entry): list head/tail projections must handle chunk
    /// views, so !eco.value head and all tail projections go out-of-line.
    bool listChunks = false;

    // Tuple2 / Tuple3 unboxed-primitive field accessors.
    // Each is a single resolve+load behind a gc-leaf call boundary — see the
    // Pattern C fix in plans/projection-helpers-everywhere.md.
    mlir::LLVM::LLVMFuncOp getOrCreateTuple2Get0I64(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateTuple2Get1I64(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateTuple2Get0F64(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateTuple2Get1F64(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateTuple2Get0I16(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateTuple2Get1I16(mlir::OpBuilder &builder) const;

    mlir::LLVM::LLVMFuncOp getOrCreateTuple3Get0I64(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateTuple3Get1I64(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateTuple3Get2I64(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateTuple3Get0F64(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateTuple3Get1F64(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateTuple3Get2F64(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateTuple3Get0I16(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateTuple3Get1I16(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateTuple3Get2I16(mlir::OpBuilder &builder) const;

    // Record / Custom unboxed-primitive field accessors: (HPtr, i32 field) -> prim
    mlir::LLVM::LLVMFuncOp getOrCreateRecordGetI64(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateRecordGetF64(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateRecordGetI16(mlir::OpBuilder &builder) const;

    mlir::LLVM::LLVMFuncOp getOrCreateCustomGetI64(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateCustomGetF64(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateCustomGetI16(mlir::OpBuilder &builder) const;

    // Array unboxed-primitive element accessors: (HPtr, i64 index) -> prim
    mlir::LLVM::LLVMFuncOp getOrCreateArrayGetI64(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateArrayGetF64(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateArrayGetI16(mlir::OpBuilder &builder) const;

    mlir::LLVM::LLVMFuncOp getOrCreateCrash(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateGcAddRoot(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateGcStackRangePoint(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateGcPushStackRange(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateGcRestoreStackRangePoint(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateRegisterTypeGraph(mlir::OpBuilder &builder) const;
    // LSS dispatch-value plan E0.4: void eco_dispatch_stats_fast(ptr) — records a
    // stamped fast-dispatch execution under ECO_DISPATCH_STATS. GC-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateDispatchStatsFast(mlir::OpBuilder &builder) const;
    // Fold-proof slot-cast barrier decls (REP_LLVM_002): declare-only,
    // gc-leaf; every call is rewritten back to a bare inttoptr/ptrtoint by
    // StripEcoCastBarriers strictly post-RS4GC (no definition ever exists,
    // no call survives to codegen).
    mlir::LLVM::LLVMFuncOp getOrCreateSlotToHPtr(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateHPtrToSlot(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateIntPow(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateUtilsEqual(mlir::OpBuilder &builder) const;

    // Order singleton getters used by eco.{int,float,char}.cmp_order. Each
    // returns the encoded HPointer of one of the three pre-allocated Order
    // Custom values (LT/EQ/GT). gc-leaf: a single load from a value-rooted
    // slot, no GC inside.
    mlir::LLVM::LLVMFuncOp getOrCreateGetOrderLT(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateGetOrderEQ(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateGetOrderGT(mlir::OpBuilder &builder) const;

    // Array functions
    mlir::LLVM::LLVMFuncOp getOrCreateCloneArray(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateArraySetFixKind(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateArrayEmpty(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateArraySingletonInt(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateArraySingletonFloat(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateArraySingletonChar(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateArraySingletonBox(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateArrayPushInt(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateArrayPushFloat(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateArrayPushChar(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateArrayPushBox(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateArraySlice(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateArrayAppendN(mlir::OpBuilder &builder) const;

    // String functions (unboxed-arg trampolines)
    mlir::LLVM::LLVMFuncOp getOrCreateStringFromInt(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateStringFromDouble(mlir::OpBuilder &builder) const;

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
// P2.5 extended inline-deref (plans/allocator-resolve-inlining.md)
//===----------------------------------------------------------------------===//

/// Rollout switch for the EXTENDED inline-deref classes (case tag/scrutinee,
/// get_tag, aggregate unbox, closure projection/construct — the resolve
/// classes P2 never converted). Default ON; `ECO_INLINE_DEREF_EXT=0` restores
/// the out-of-line `eco_resolve_hptr`/`eco_get_tag` emission for A/B and
/// bisection. TEMPORARY per the P2 precedent: delete the env + the
/// out-of-line arms after soak (plan milestone R4).
inline bool inlineDerefExtEnabled() {
    static const bool enabled = [] {
        const char *e = ::getenv("ECO_INLINE_DEREF_EXT");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return enabled;
}

/// Rollout switch for inline nursery allocation
/// (plans/inline-nursery-allocation.md, HEAP_034). Default ON;
/// `ECO_INLINE_ALLOC=0` restores the unified `eco_alloc_*` call emission for
/// A/B, bisection, and census workflows (ECO_CLOSURE_STATS counts closure
/// creates inside eco_alloc_closure_k, and ENABLE_GC_STATS=1 builds count
/// per-alloc bytes on the runtime fast path — both go blind at inline sites,
/// so census/stats runs must set =0; the E2E harness binary cache is
/// mtime-blind, so A/B legs need the touch discipline). TEMPORARY per the
/// P2/P2.5 precedent: delete the env + the call-emission arms after soak
/// (plan milestone N6).
inline bool inlineAllocEnabled() {
    static const bool enabled = [] {
        const char *e = ::getenv("ECO_INLINE_ALLOC");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return enabled;
}

/// P2.5: resolve an HPointer base via the inline forwarding-check marker
/// (`__eco_resolve_fwd`, AS1→AS1, gc-leaf; expanded to the header-tag
/// diamond by ExpandInlineDeref before RS4GC — plan P2 machinery). The
/// operand MUST be a real heap pointer: embedded constants (False/True/
/// Empty) must be branched away BEFORE the marker, exactly as the runtime
/// `resolve()` asserts under ECO_HEAP_VALIDATE.
inline mlir::Value inlineResolvedBase(mlir::OpBuilder &b, mlir::Location loc,
                                      mlir::Value hptr,
                                      const EcoRuntime &runtime) {
    auto marker = runtime.getOrCreateResolveFwdMarker(b);
    return b.create<mlir::LLVM::CallOp>(loc, marker, mlir::ValueRange{hptr})
        .getResult();
}

/// P2.5 R5 Part 1 (plans/allocator-resolve-inlining.md §8.1): store ONE
/// construct/to_heap field into a FRESH heap object at a statically-known
/// byte offset — a direct AS1 GEP + i64 store, no resolve and no diamond
/// (HEAP_031: no safepoint can intervene between the allocation and these
/// stores, so the object cannot carry a forwarding header). Field-kind
/// handling mirrors the eco_store_field/_i64/_f64 runtime helpers exactly:
/// f64 bitcast, narrow ints zext, boxed values through the REP_LLVM_002
/// barriered helper with the store tagged `eco.boxed_slot` so
/// EcoBoxedStoreVerify re-inserts the stale-HPointer write tripwire in
/// validator builds (the array.set precedent — the always-on tripwire in
/// the out-of-line helpers is validator-build-only on this path).
inline void emitFreshFieldStore(mlir::OpBuilder &b, mlir::Location loc,
                                mlir::Value baseHptr, int64_t byteOffset,
                                mlir::Value fieldVal, mlir::Type origType) {
    auto *ctx = b.getContext();
    auto i64Ty = mlir::IntegerType::get(ctx, 64);
    auto i8Ty = mlir::IntegerType::get(ctx, 8);
    auto hptrTy = getHPtrLLVMType(*ctx);

    auto off = b.create<mlir::LLVM::ConstantOp>(loc, i64Ty, byteOffset);
    auto slotPtr = b.create<mlir::LLVM::GEPOp>(loc, hptrTy, i8Ty, baseHptr,
                                               mlir::ValueRange{off});

    bool boxed = false;
    mlir::Value word;
    if (origType.isF64()) {
        word = b.create<mlir::LLVM::BitcastOp>(loc, i64Ty, fieldVal);
    } else if (origType.isInteger(64)) {
        word = fieldVal;
    } else if (auto intTy = mlir::dyn_cast<mlir::IntegerType>(origType);
               intTy && intTy.getWidth() < 64) {
        word = b.create<mlir::LLVM::ZExtOp>(loc, i64Ty, fieldVal);
    } else {
        // Boxed field: ptr<1> value -> barriered slot word.
        boxed = true;
        word = heapStoreValueToI64(b, loc, fieldVal);
    }
    auto store = b.create<mlir::LLVM::StoreOp>(loc, word, slotPtr);
    if (boxed)
        store->setAttr("eco.boxed_slot", mlir::UnitAttr::get(ctx));
}

/// Inline nursery allocation (plans/inline-nursery-allocation.md, HEAP_034):
/// emit the `__eco_alloc_inline(byteSize)` marker call (expanded to the
/// bump-pointer fast/slow diamond by expandInlineAllocs in EcoBackend.cpp,
/// pre-RS4GC) followed by ONE i64 constant store of the composed header word
/// at offset 0. Returns the AS1 object pointer.
///
/// HEAP_034 caller contract: byteSize is a compile-time constant (8-aligned,
/// <= 4096) and the caller stores EVERY payload field via straight-line code
/// (emitFreshFieldStore / plain constant stores) before any possible
/// safepoint — no call may intervene except gc-leaf barriers. The runtime's
/// zero-init of the `*_uninit` alloc family is deliberately NOT replicated:
/// with no safepoint between the bump and the last store, the GC can never
/// observe the object partially initialized.
inline mlir::Value emitInlineAllocWithHeader(mlir::OpBuilder &b,
                                             mlir::Location loc,
                                             const EcoRuntime &runtime,
                                             uint64_t byteSize,
                                             uint64_t headerWord) {
    auto *ctx = b.getContext();
    auto i64Ty = mlir::IntegerType::get(ctx, 64);
    auto hptrTy = getHPtrLLVMType(*ctx);

    auto marker = runtime.getOrCreateAllocInlineMarker(b);
    auto sizeConst = b.create<mlir::LLVM::ConstantOp>(
        loc, i64Ty, static_cast<int64_t>(byteSize));
    mlir::Value obj =
        b.create<mlir::LLVM::CallOp>(loc, marker, mlir::ValueRange{sizeConst})
            .getResult();

    auto headerConst = b.create<mlir::LLVM::ConstantOp>(
        loc, i64Ty, static_cast<int64_t>(headerWord));
    // Store at offset 0: the object pointer IS the header address (align 8,
    // HEAP_028).
    b.create<mlir::LLVM::StoreOp>(loc, headerConst, obj, /*alignment=*/8);

    return obj;
}

/// Store a second constant metadata word at byte offset 8 (custom's
/// ctor|unboxed<<16, record's unboxed bitmap, closure's packed word).
inline void emitInlineAllocMetaWord(mlir::OpBuilder &b, mlir::Location loc,
                                    mlir::Value obj, uint64_t metaWord) {
    auto *ctx = b.getContext();
    auto i64Ty = mlir::IntegerType::get(ctx, 64);
    auto i8Ty = mlir::IntegerType::get(ctx, 8);
    auto hptrTy = getHPtrLLVMType(*ctx);
    auto off = b.create<mlir::LLVM::ConstantOp>(loc, i64Ty,
                                                static_cast<int64_t>(8));
    auto slot = b.create<mlir::LLVM::GEPOp>(loc, hptrTy, i8Ty, obj,
                                            mlir::ValueRange{off});
    auto metaConst = b.create<mlir::LLVM::ConstantOp>(
        loc, i64Ty, static_cast<int64_t>(metaWord));
    b.create<mlir::LLVM::StoreOp>(loc, metaConst, slot, /*alignment=*/8);
}

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

/// No-op stub (RS4GC handles safepoint insertion automatically).
/// Retained for API compatibility with existing call sites.
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

//===----------------------------------------------------------------------===//
// Aggregate operand boxing (Phase 1 of widen-construct-make-call-aggregates)
//===----------------------------------------------------------------------===//

/// Returns true if `t` is, or recursively contains, an Eco type that
/// converts to `ptr addrspace(1)` (i.e. `!eco.value` or any aggregate
/// that itself contains one). Used by `make.*` boxing decision: nest
/// when false (no `ptr<1>` inside the nested FCA), box when true.
bool containsGCPointer(mlir::Type t);

/// If `v` is an Eco-aggregate-typed SSA value
/// (tuple2/tuple3/record/custom/cons), emit `eco.to_heap` to box it into
/// a fresh `!eco.value` and return that. Otherwise return `v` unchanged.
/// `liveRoots` is forwarded to the inserted `eco.to_heap`.
mlir::Value materialiseAsBoxed(mlir::OpBuilder &b, mlir::Location loc,
                                mlir::Value v, mlir::ValueRange liveRoots);

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
    mlir::RewritePatternSet &patterns,
    const EcoRuntime &runtime);

/// Populate patterns for value-level aggregate ops (Phase 0 plumbing):
/// - eco.make.tuple2/3, eco.make.record, eco.make.custom,
///   eco.make.cons, eco.make.closure_env (Pure; insertvalue chains).
/// - eco.to_heap (data-aggregate -> !eco.value heap object).
/// - eco.make.closure (closure_env + function/arity -> !eco.value).
/// - project.closure for !eco.closure_env operands (small parallel
///   pattern; the heap-side eco.project.closure lowering in
///   EcoToLLVMClosures.cpp is intentionally untouched in Phase 0).
void populateEcoValueAggPatterns(
    EcoTypeConverter &typeConverter,
    mlir::RewritePatternSet &patterns,
    const EcoRuntime &runtime);

//===----------------------------------------------------------------------===//
// Phase-2 pre-materialization (create module artifacts serially before the
// per-function body stage; see EcoToLLVM.cpp runOnOperation).
//===----------------------------------------------------------------------===//

void preMaterializeStringLiterals(
    mlir::OpBuilder &builder, const EcoRuntime &runtime,
    llvm::ArrayRef<mlir::LLVM::LLVMFuncOp> funcs);
void preMaterializeStringCases(
    mlir::OpBuilder &builder, const EcoRuntime &runtime,
    llvm::ArrayRef<mlir::LLVM::LLVMFuncOp> funcs);
void preMaterializeClosureArtifacts(
    mlir::OpBuilder &builder, const EcoRuntime &runtime,
    const mlir::TypeConverter *typeConverter,
    llvm::ArrayRef<mlir::LLVM::LLVMFuncOp> funcs);

//===----------------------------------------------------------------------===//
// Shadow Root Frame (TCO-safe GC rooting for func.func parameters)
//===----------------------------------------------------------------------===//

/// Holds the state for a shadow root frame installed in a function prologue.
/// The frame parks !eco.value parameters in a stack-allocated i64 array
/// registered with the GC via eco_gc_push_stack_range, so the collector
/// can relocate them in place across safepoints (including LLVM TCO).
struct ShadowRootFrame {
    mlir::Value savedPoint;   // i64 returned by eco_gc_stack_range_point
    mlir::Value basePtr;      // ptr to roots[0] (alloca'd i64 array)
    llvm::DenseMap<mlir::BlockArgument, mlir::Value> slotForArg; // arg -> i64* slot
};

/// Install the shadow root prologue at the start of a post-conversion
/// LLVM::LLVMFuncOp: alloca, memset, stack_range_point, store args, push_range.
/// Returns an empty frame (basePtr == nullptr) if the function has no
/// ptr addrspace(1) parameters.
ShadowRootFrame installShadowRootPrologue(
    mlir::LLVM::LLVMFuncOp func,
    mlir::OpBuilder &builder,
    const EcoRuntime &runtime);

/// Emit a load from the shadow slot for a rooted BlockArgument:
///   %hp = load i64, ptr %slot
///   %v  = inttoptr i64 %hp to ptr addrspace(1)
mlir::Value loadValueFromShadowSlot(
    const ShadowRootFrame &frame,
    mlir::BlockArgument arg,
    mlir::OpBuilder &builder,
    mlir::Location loc);

/// Rewrite all uses of a rooted BlockArgument to load from its shadow slot.
void rewriteUsesViaShadowSlot(
    const ShadowRootFrame &frame,
    mlir::BlockArgument arg,
    mlir::OpBuilder &builder);

/// Insert eco_gc_restore_stack_range_point(savedPoint) before every
/// LLVM::ReturnOp in the function.
void emitShadowRootEpilogues(
    const ShadowRootFrame &frame,
    mlir::LLVM::LLVMFuncOp func,
    mlir::OpBuilder &builder,
    const EcoRuntime &runtime);

/// Generate the __eco_init_globals function to register GC roots.
void createGlobalRootInitFunction(
    mlir::ModuleOp module,
    EcoRuntime &runtime);

/// CAF memoization (plans/caf-memoization-implementation.md): wrap a nullary
/// thunk tagged `eco.caf_memo` in a load-check-return / store-on-return guard
/// against its `__eco_caf$<name>` slot (an eco.global-lowered internal i64
/// LLVM global). Must run in the serial post-Stage-2 phase, BEFORE
/// createGlobalRootInitFunction (which roots the slot) and before the
/// unused-decl strip (the barrier decls this references must count as used).
mlir::LogicalResult installCafMemoGuard(mlir::LLVM::LLVMFuncOp func);

/// CAF caller-side fast path (benchmarks/runtime-calls.md Run W): rewrite
/// every zero-arg call to a `eco.caf_memo`-tagged thunk into a
/// load-slot/icmp/diamond — the hit edge takes the barrier-cast cached
/// value with NO call; the miss edge keeps the original call (the thunk
/// retains its callee-side guard and publish logic, so unrewritten sites
/// and the miss path stay correct). Runs in the serial post-Stage-2 phase
/// on every non-external function. `ECO_CAF_CALLER_FAST=0` disables.
void rewriteCafCallSitesFast(
    mlir::LLVM::LLVMFuncOp func,
    const llvm::DenseSet<llvm::StringRef> &cafMemoFuncs);

/// Master switch for the caller-side fast path (default ON;
/// `ECO_CAF_CALLER_FAST=0` is the escape / A-B lever — lowering-time only,
/// so a same-MLIR A/B isolates its effect exactly).
inline bool cafCallerFastEnabled() {
    static const bool enabled = [] {
        const char *e = ::getenv("ECO_CAF_CALLER_FAST");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return enabled;
}

} // namespace detail
} // namespace eco

#endif // ECO_TO_LLVM_INTERNAL_H
