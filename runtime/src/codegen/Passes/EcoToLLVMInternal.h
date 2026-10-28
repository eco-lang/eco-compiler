//===- EcoToLLVMInternal.h - Shared machinery of the Eco-to-LLVM lowering -===//
//
// The `eco-to-llvm` pass is split across several translation units, one per
// group of eco operations, and they must agree on what an Elm value is once it
// is LLVM IR. This header is that agreement. Everything in it is in
// `eco::detail` and is internal to the code generator; besides the pass files,
// a few other passes and the LLVM backend include it for its constants and
// switches.
//
// Four facts shape the contents.
//
// Every boxed Elm value becomes `ptr addrspace(1)`, the pointer type that LLVM's
// statepoint rewriting (RS4GC) tracks and that the collector may move. In a heap
// field, a closure capture, a global or an argument buffer the same value is a
// 64-bit word, a *boxed slot*. Converting between the two is a *slot crossing*.
// Before RS4GC a crossing must not be a bare `inttoptr`/`ptrtoint`, because
// inlining can fold a pair of them away and leave a raw word live across a
// safepoint; `EcoSlotCastBarriers.h` states the rule and names the barrier
// functions. The `slot*` helpers, and the role wrappers built on them, emit the
// barrier form.
//
// Generated code reads and writes heap objects itself, so the word encodings and
// byte layouts of `allocator/Heap.hpp` (`HPointer`, `Header`, `Tag` and the
// object structs) are restated here as constants in `value_enc` and `layout`.
// Each must equal its Heap.hpp counterpart. `static_assert`s in
// EcoToLLVMHeap.cpp check the tag values, `TagBits`, the null-cons constants,
// the Custom and Record header-slot counts, `SlotsPerExtWord` and the fixed
// object sizes; `check-ctor-tags.sh` checks `ConstantTag`. The header bit positions that
// `composeHeader` uses cannot be checked at compile time; HPointerLayoutTest
// checks the same positions at run time. The other offsets and constants are
// not checked against Heap.hpp.
//
// A *slot kind* is the 2-bit code the collector reads to tell a boxed slot from
// an unboxed one: 0 boxed, 1 Int, 2 Float, 3 Char (`allocator/Heap` owns the
// encoding). Here kinds come from the SSA type of the stored value
// (`slotKindOf`), so Bool, which is a boxed constant in the heap, is kind 0.
//
// The body conversion runs on chunks of functions in parallel, and its threads
// must not create module-level symbols. So everything a body pattern
// would create (runtime declarations, string-literal globals, closure wrappers
// and their descriptors) is created first, serially, by *pre-materialization*,
// and `EcoRuntime` is then *frozen*: its symbol cache becomes read-only and
// every lookup is a lock-free read. `EcoRuntime` is most of this header: it
// declares and caches the runtime functions generated code calls, and carries
// the side tables pre-materialization fills.
//
// The rest is the inline code emitters shared by several pattern files, the
// entry points that add each file's patterns, and the passes over the whole
// module that run after the body conversion.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_TO_LLVM_INTERNAL_H
#define ECO_TO_LLVM_INTERNAL_H

#include "EcoSlotCastBarriers.h"
#include "../EcoOps.h"  // eco::isEcoCharType / kEcoCharBits (Char = i32)

#include "mlir/Conversion/LLVMCommon/TypeConverter.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/Transforms/DialectConversion.h"

#include "mlir/IR/SymbolTable.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringMap.h"
#include "llvm/ADT/StringSet.h"
#include <algorithm>
#include <cassert>
#include <cstdlib>
#include <functional>
#include <vector>
#include <mutex>

namespace eco {
namespace detail {

//===----------------------------------------------------------------------===//
// Type Converter
//===----------------------------------------------------------------------===//

/// The type mapping from eco types to LLVM types used by every eco-to-LLVM
/// pattern.
///
/// Primitive types (i64 Int, f64 Float, i32 Char, and the i1 that an SSA Bool
/// is) are left as they are; i1 appears only in SSA control flow, never in
/// heap, closure or ABI positions. `!eco.value` becomes `ptr addrspace(1)`. A
/// value-level aggregate (tuple, record, custom, cons, closure environment)
/// becomes an LLVM literal struct of its converted element types, which is not
/// the heap layout of the same value. A `!bf.cursor` becomes a struct of two
/// plain pointers. Casts between unconverted and converted values are
/// `unrealized_conversion_cast`s.
class EcoTypeConverter : public mlir::LLVMTypeConverter {
public:
    explicit EcoTypeConverter(mlir::MLIRContext *ctx);
};

//===----------------------------------------------------------------------===//
// HPointer Type Helpers
//===----------------------------------------------------------------------===//

/// Returns `ptr addrspace(1)`, the LLVM type of a boxed Elm value.
inline mlir::Type getHPtrLLVMType(mlir::MLIRContext &ctx) {
    return mlir::LLVM::LLVMPointerType::get(&ctx, /*addressSpace=*/1);
}

/// Returns whether `t` is `ptr addrspace(1)`.
inline bool isHPtrLLVMType(mlir::Type t) {
    if (auto ptrTy = mlir::dyn_cast<mlir::LLVM::LLVMPointerType>(t))
        return ptrTy.getAddressSpace() == 1;
    return false;
}

/// Returns `v` as an i64 word: a bare `ptrtoint` of a `ptr addrspace(1)`, or
/// `v` itself if it is i64 or of any other type.
///
/// This is not a slot crossing and must not be used for one; use
/// `slotValueToI64` or a role wrapper.
inline mlir::Value valueToI64(mlir::OpBuilder &builder, mlir::Location loc, mlir::Value v) {
    if (v.getType().isInteger(64))
        return v;
    if (isHPtrLLVMType(v.getType())) {
        auto i64Ty = mlir::IntegerType::get(builder.getContext(), 64);
        return builder.create<mlir::LLVM::PtrToIntOp>(loc, i64Ty, v);
    }
    return v;
}

/// Returns `v` as a `ptr addrspace(1)`: a bare `inttoptr` of an i64, or `v`
/// itself if it is already that pointer or of any other type.
///
/// This is not a slot crossing and must not be used for one; use
/// `slotI64ToValue` or a role wrapper.
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
// Slot crossings
//
// These emit a crossing as a call to the barrier `EcoSlotCastBarriers.h` names,
// or, when `slotCastBarriersEnabled()` is false, as the bare cast. They emit a
// barrier exactly where `valueToI64`/`i64ToValue` would emit a cast and pass
// every other value through in the same way, so the two settings produce the
// same instructions at the same positions, differing only in call versus cast.
//
// The barrier is called by symbol name. `EcoRuntime::materializeAllRuntimeDecls`
// declares both barriers, so the name always resolves.
//===----------------------------------------------------------------------===//

/// Returns `v` as a boxed-slot word for storing: a call to the
/// `__eco_hptr_to_slot` barrier if `v` is a `ptr addrspace(1)`, or `v` itself
/// if it is i64 or of any other type.
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

/// Returns a loaded boxed-slot word `v` as a `ptr addrspace(1)`: a call to the
/// `__eco_slot_to_hptr` barrier if `v` is i64, or `v` itself if it is already
/// that pointer or of any other type.
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
// Crossings by role
//
// One function per place a boxed value crosses between `ptr addrspace(1)` and
// an i64 word. Each names the one use its result is for, and the caller must
// keep to it: a store helper's word goes straight into a store or a gc-leaf
// call argument, and a load helper's operand comes straight from the load. A
// word kept past a call that can collect is a raw pointer RS4GC cannot see.
// Nothing checks these rules.
//===----------------------------------------------------------------------===//

/// Returns `v` as the word to store into a field of a heap object, through the
/// slot-crossing barrier.
inline mlir::Value heapStoreValueToI64(mlir::OpBuilder &b, mlir::Location loc, mlir::Value v) {
    return slotValueToI64(b, loc, v);
}

/// Returns the word `v`, loaded from a field of a heap object, as a
/// `ptr addrspace(1)`, through the slot-crossing barrier.
inline mlir::Value heapLoadI64ToValue(mlir::OpBuilder &b, mlir::Location loc, mlir::Value v) {
    return slotI64ToValue(b, loc, v);
}

/// Returns `v` as the word to store into an i64 module global that holds a
/// boxed value, through the slot-crossing barrier.
inline mlir::Value globalStoreValueToI64(mlir::OpBuilder &b, mlir::Location loc, mlir::Value v) {
    return slotValueToI64(b, loc, v);
}

/// Returns the word `v`, loaded from an i64 module global that holds a boxed
/// value, as a `ptr addrspace(1)`, through the slot-crossing barrier.
inline mlir::Value globalLoadI64ToValue(mlir::OpBuilder &b, mlir::Location loc, mlir::Value v) {
    return slotI64ToValue(b, loc, v);
}

/// Returns `v` as the word to store into a closure's `values`, through the
/// slot-crossing barrier.
inline mlir::Value closureStoreValueToI64(mlir::OpBuilder &b, mlir::Location loc, mlir::Value v) {
    return slotValueToI64(b, loc, v);
}

/// Returns the word `v`, loaded from a closure's `values`, as a
/// `ptr addrspace(1)`, through the slot-crossing barrier.
inline mlir::Value closureLoadI64ToValue(mlir::OpBuilder &b, mlir::Location loc, mlir::Value v) {
    return slotI64ToValue(b, loc, v);
}

/// Returns `v` as the word to store into a stack argument buffer that is
/// registered as a root range with `eco_gc_push_stack_range`, through the
/// slot-crossing barrier.
inline mlir::Value argsSlotStoreValueToI64(mlir::OpBuilder &b, mlir::Location loc, mlir::Value v) {
    return slotValueToI64(b, loc, v);
}

/// Returns the word `v`, loaded from a stack argument buffer, as a
/// `ptr addrspace(1)`, through the slot-crossing barrier.
inline mlir::Value argsSlotLoadI64ToValue(mlir::OpBuilder &b, mlir::Location loc, mlir::Value v) {
    return slotI64ToValue(b, loc, v);
}

/// Returns the bits of a case scrutinee `v` as an i64, with a bare `ptrtoint`,
/// for testing which kind of word it is.
///
/// This is not a slot crossing. The result must be used only by shift, mask
/// and compare instructions in the same block, never stored and never live
/// across a call.
inline mlir::Value caseScrutineeToI64(mlir::OpBuilder &b, mlir::Location loc, mlir::Value v) {
    return valueToI64(b, loc, v);
}

/// Returns `v` converted to the plain pointer type `retPtrTy` by a bare
/// `ptrtoint` and `inttoptr`, for an evaluator wrapper that returns a boxed
/// value through the runtime's C ABI.
///
/// The result is invisible to RS4GC, so it must be returned at once.
inline mlir::Value wrapperReturnValueToPtr0(mlir::OpBuilder &b, mlir::Location loc,
                                            mlir::Value v, mlir::Type retPtrTy) {
    mlir::Value asI64 = valueToI64(b, loc, v);
    return b.create<mlir::LLVM::IntToPtrOp>(loc, retPtrTy, mlir::ValueRange{asI64});
}

/// Returns the word `loadedI64`, loaded from an evaluator wrapper's argument
/// array, as a value of `targetType`.
///
/// A `ptr addrspace(1)` target goes through the slot-crossing barrier. Any other
/// pointer target is a plain pointer argument, not a heap value, and gets a bare
/// `inttoptr`. Any other target is returned as the i64 word unchanged.
inline mlir::Value wrapperLoadArgSlotToValue(mlir::OpBuilder &b, mlir::Location loc,
                                             mlir::Value loadedI64, mlir::Type targetType) {
    if (isHPtrLLVMType(targetType))
        return slotI64ToValue(b, loc, loadedI64);
    if (mlir::isa<mlir::LLVM::LLVMPointerType>(targetType))
        return b.create<mlir::LLVM::IntToPtrOp>(loc, targetType, mlir::ValueRange{loadedI64});
    return loadedI64;
}

//===----------------------------------------------------------------------===//
// Value encoding: the `HPointer` word and the object header word
//===----------------------------------------------------------------------===//

/// The encodings of a boxed value's 64-bit word and of a heap object's header
/// word, as `allocator/Heap.hpp` defines them in `HPointer` and `Header`. Each
/// constant must equal the Heap.hpp value it names.
namespace value_enc {

/// The bit that is set in an embedded constant and clear in a heap pointer
/// (`PTR_IND_BIT`).
constexpr unsigned PtrIndBit = 2;

/// The mask of `HPointer.constant`, the 2-bit code that says which embedded
/// constant a word is.
constexpr uint64_t ConstFieldMask = 0x3;

/// The values of `HPointer.constant` in an embedded constant, as Heap.hpp's
/// `Constant` enum defines them. They are written into compiled code and must
/// not be renumbered.
enum ConstantKind : uint64_t {
    False = 0,
    True  = 1,
    Empty = 2,  ///< Unit, the empty record, Nil, Nothing, the empty String and the empty Bytes.
    NullCons = 3,  ///< A nullary constructor; its declaration index is in bits 43-52.
};

/// Returns the word of the embedded constant `kind`: False 0x4, True 0x5,
/// Empty 0x6.
///
/// `kind` must be `False`, `True` or `Empty`. Nothing checks it; `NullCons`
/// gives 0x7, the null-cons word for declaration index 0.
inline int64_t encodeConstant(int kind) {
    return (static_cast<int64_t>(1) << PtrIndBit) | static_cast<int64_t>(kind);
}

/// The bit at which a null-cons word holds the declaration index
/// (`NULL_CONS_SHIFT`).
constexpr unsigned NullConsShift = 43;
/// The largest declaration index a null-cons word can hold (`NULL_CONS_MAX`).
constexpr uint64_t NullConsMax = 1023;

/// Returns the null-cons word of the nullary constructor with zero-based
/// declaration index `idx`: `(idx << 43) | 0b111`, the word Heap.hpp's
/// `nullConsWordFor` gives.
///
/// `idx` must not exceed `NullConsMax`; nothing here checks it.
inline int64_t encodeNullCons(uint64_t idx) {
    return static_cast<int64_t>((idx << NullConsShift)
                                | (uint64_t{1} << PtrIndBit)
                                | static_cast<uint64_t>(NullCons));
}

/// The constructor tag that case dispatch gives the Empty constant
/// (`CONSTANT_TAG`). The compiler uses the same value.
constexpr int64_t ConstantTag = 0xFFFD;

/// The width in bits of `Header.tag`, the lowest field of the header word
/// (`TAG_BITS`).
constexpr unsigned TagBits = 5;

/// The value of `Tag_Forward`, the tag of a word that has replaced the header of
/// an object a collector has moved.
constexpr int64_t TagForward = 26;

/// The value of `Tag_Cons`.
constexpr int64_t TagCons = 6;
/// The value of `Tag_Custom`.
constexpr int64_t TagCustom = 7;

/// The bit at which the header word holds `Header.unboxed`, assuming the
/// fields before it (tag, color, pin, age) are packed from bit 0 upwards.
constexpr unsigned HeaderUnboxedShift = 10;  // tag:5 + color:2 + pin:1 + age:2
/// The bit at which the header word holds `Header.size`.
constexpr unsigned HeaderSizeShift = 32;
/// Returns the header word of a newly allocated object with tag `tag`,
/// `Header.unboxed` equal to `unboxedBits` and `Header.size` equal to
/// `sizeField`, with every other field 0.
///
/// The arguments must fit their fields; nothing masks them. The bit positions
/// assume a bit-field packing the language leaves to the compiler, so they
/// cannot be checked by `static_assert`; HPointerLayoutTest checks the same
/// positions against `Header` at run time.
constexpr uint64_t composeHeader(uint64_t tag, uint64_t unboxedBits,
                                 uint64_t sizeField) {
    return tag | (unboxedBits << HeaderUnboxedShift)
               | (sizeField << HeaderSizeShift);
}

/// The value of `Tag_Int`.
constexpr int64_t TagInt = 0;
/// The value of `Tag_Float`.
constexpr int64_t TagFloat = 1;
/// The value of `Tag_Char`.
constexpr int64_t TagChar = 2;
/// The value of `Tag_Tuple2`.
constexpr int64_t TagTuple2 = 4;
/// The value of `Tag_Tuple3`.
constexpr int64_t TagTuple3 = 5;
/// The value of `Tag_Record`.
constexpr int64_t TagRecord = 8;
/// The value of `Tag_Closure`.
constexpr int64_t TagClosure = 11;

} // namespace value_enc

//===----------------------------------------------------------------------===//
// Heap object layout
//===----------------------------------------------------------------------===//

/// The byte offsets and sizes of the heap objects generated code builds and
/// reads, as the structs in `allocator/Heap.hpp` lay them out. Offsets are from
/// the object's address, which is the address of its header. Each constant must
/// equal what Heap.hpp gives.
///
/// The object kinds that hold a variable number of slots (Custom, Record and
/// Closure) keep the kinds of their first slots in a word at offset 8, and the
/// kinds of the rest in *extension kind words*: 32 kinds to a word, stored after
/// the slots, at the end of the object. A Custom with n fields is
/// `16 + 8 * (n + K)` bytes, where K is the number of extension words, and K is
/// stored in `Header.unboxed`. A Closure's `Header.size` counts its value slots
/// plus K.
namespace layout {

/// The size of the header word, in bytes.
constexpr uint64_t HeaderSize = 8;

/// The size of one slot, and of a pointer, in bytes.
constexpr uint64_t PtrSize = 8;

/// The alignment of every heap object, in bytes.
constexpr uint64_t Alignment = 8;

/// The offset of a Cons cell's `head`.
constexpr uint64_t ConsHeadOffset = HeaderSize;
/// The offset of a Cons cell's `tail`.
constexpr uint64_t ConsTailOffset = HeaderSize + PtrSize;

/// The offset of a Tuple2's first field; the second follows it.
constexpr uint64_t Tuple2FirstOffset = HeaderSize;

/// The offset of a Tuple3's first field; the others follow it.
constexpr uint64_t Tuple3FirstOffset = HeaderSize;

/// The offset of a Record's kind word, which holds the kinds of fields 0 to 31.
constexpr uint64_t RecordUnboxedOffset = HeaderSize;
/// The offset of a Record's first field.
constexpr uint64_t RecordFieldsOffset = HeaderSize + PtrSize;

/// The offset of a Custom's second word: the constructor index in its low 16
/// bits and the kinds of fields 0 to 23 in the 48 bits above.
constexpr uint64_t CustomCtorOffset = HeaderSize;
/// The offset of a Custom's first field.
constexpr uint64_t CustomFieldsOffset = HeaderSize + PtrSize;

/// The offset of an array's 32-bit element count; 32 bits of padding follow.
constexpr uint64_t ArrayLengthOffset = HeaderSize;
/// The offset of an array's first element.
constexpr uint64_t ArrayElementsOffset = HeaderSize + PtrSize;

/// The offset of a Closure's packed word (see `packClosureWord`).
constexpr uint64_t ClosurePackedOffset = HeaderSize;
/// The offset of a Closure's `evaluator`, a pointer to the static
/// `EvaluatorDesc` of the function it calls.
constexpr uint64_t ClosureEvaluatorOffset = HeaderSize + PtrSize;
/// The offset of a Closure's first value slot.
constexpr uint64_t ClosureValuesOffset = HeaderSize + 2 * PtrSize;

// Offsets within an `EvaluatorDesc`, the static description of an evaluator.
// Heap.hpp asserts that the struct has these offsets. `sat` has entries only
// when `stage_arity <= SAT_MAX_ARITY`, so code must check that before reading
// it; an entry with no generated function is null.

/// The offset of `EvaluatorDesc::generic`, the entry that takes an argument
/// array.
constexpr uint64_t EvaluatorDescGenericOffset = 0;
/// The offset of `EvaluatorDesc::kinds`.
constexpr uint64_t EvaluatorDescKindsOffset = 8;
/// The offset of `EvaluatorDesc::stage_arity`, a 16-bit field.
constexpr uint64_t EvaluatorDescStageArityOffset = 18;
/// The offset of `EvaluatorDesc::result_kind`, an 8-bit field.
constexpr uint64_t EvaluatorDescResultKindOffset = 17;
/// The offset of `EvaluatorDesc::sat`, the array of saturated-call entries.
constexpr uint64_t EvaluatorDescSatOffset = 24;

// Fixed object sizes in bytes. `static_assert`s in EcoToLLVMHeap.cpp check
// these against `sizeof` of the Heap.hpp structs.

/// The size of a boxed Int, Float or Char.
constexpr uint64_t BoxedPrimSize = 16;   // ElmInt / ElmFloat / ElmChar
/// The size of a Cons cell.
constexpr uint64_t ConsSize = 24;        // Header + head + tail
/// The size of a Tuple2.
constexpr uint64_t Tuple2Size = 24;      // Header + a + b
/// The size of a Tuple3.
constexpr uint64_t Tuple3Size = 32;      // Header + a + b + c
/// The size of a Record with no fields; see `recordByteSize`.
constexpr uint64_t RecordBaseSize = 16;  // Header + kind word
/// The size of a Custom with no fields; see `customByteSize`.
constexpr uint64_t CustomBaseSize = 16;  // Header + ctor/kind word
/// The size of a Closure with no value slots.
constexpr uint64_t ClosureBaseSize = 24; // Header + packed + evaluator

/// The number of slots whose kinds fit in the word at offset 8, for a Custom, a
/// Record and a Closure (`CUSTOM_HDR_SLOTS`, `RECORD_HDR_SLOTS`,
/// `CLOSURE_HDR_SLOTS`).
constexpr unsigned CustomHdrSlots = 24, RecordHdrSlots = 32, ClosureHdrSlots = 20;
/// The bit positions of `max_values`, `result_kind` and the kinds in a
/// Closure's packed word.
constexpr unsigned ClosureMaxShift = 11, ClosureRkShift = 22, ClosureKindsShift = 24;
/// The mask of `n_values` and of `max_values` in a Closure's packed word.
constexpr uint64_t ClosureCountMask = 0x7FF;
/// The largest stage arity a Closure can have (`CLOSURE_MAX_ARITY`).
constexpr unsigned ClosureMaxArity = 2047;
/// The largest stage arity whose `EvaluatorDesc` has `sat` entries
/// (`SAT_MAX_ARITY`).
constexpr unsigned SatMaxArity = ClosureHdrSlots;
/// Returns the number of extension kind words for `n` slots of which the first
/// `hdrSlots` have their kinds in the object's kind word. Heap.hpp's `extWords`
/// gives the same.
constexpr unsigned extWordsFor(unsigned n, unsigned hdrSlots) {
    return n > hdrSlots ? (n - hdrSlots + 31) / 32 : 0;
}

/// The number of slot kinds one extension kind word holds
/// (`SLOTS_PER_EXT_WORD`).
constexpr unsigned SlotsPerExtWord = 32;
/// Returns the number of extension kind words for `n` slots of which the first
/// `hdr` have their kinds in the object's kind word, as `extWordsFor` does.
constexpr uint64_t extWords(uint64_t n, unsigned hdr) {
    return n > hdr ? (n - hdr + SlotsPerExtWord - 1) / SlotsPerExtWord : 0;
}
/// Returns the size in bytes of a Record with `n` fields, extension kind words
/// included.
constexpr uint64_t recordByteSize(uint64_t n) {
    return RecordBaseSize + (n + extWords(n, RecordHdrSlots)) * PtrSize;
}
/// Returns the size in bytes of a Custom with `n` fields, extension kind words
/// included.
constexpr uint64_t customByteSize(uint64_t n) {
    return CustomBaseSize + (n + extWords(n, CustomHdrSlots)) * PtrSize;
}
static_assert(recordByteSize(32) == 16 + 32 * 8 && recordByteSize(33) == 16 + 34 * 8);
static_assert(customByteSize(24) == 16 + 24 * 8 && customByteSize(60) == 16 + 62 * 8);
static_assert(extWords(2047, RecordHdrSlots) == 63 && extWords(2040, CustomHdrSlots) == 63);

} // namespace layout

//===----------------------------------------------------------------------===//
// Slot kinds
//===----------------------------------------------------------------------===//

/// The width of 16-bit storage that is not a Char: one UTF-16 unit of a string
/// literal body, or a u16 header field (Custom ctor, closure stage_arity,
/// EvalParamLayout num_params). An Elm Char is an i32 code point; see
/// `eco::isEcoCharType`.
constexpr unsigned kU16StorageBits = 16;
inline mlir::IntegerType getU16StorageType(mlir::MLIRContext *ctx) {
    return mlir::IntegerType::get(ctx, kU16StorageBits);
}

/// Returns the slot kind a value of type `t` is stored with: 1 for i64 (Int),
/// 2 for f64 (Float), 3 for i32 (Char, `eco::isEcoCharType`), and 0 (boxed)
/// for every other type, including i1, since a Bool is stored as a boxed
/// constant. The answer is the same for an eco type and for the LLVM type it
/// converts to.
inline uint8_t slotKindOf(mlir::Type t) {
    if (t.isInteger(64)) return 1;
    if (t.isF64()) return 2;
    if (eco::isEcoCharType(t)) return 3;
    return 0;
}

/// Returns the kinds `kinds[first, first + count)` packed into one word, 2 bits
/// each, the first in the lowest bits. Positions past the end of `kinds` are 0.
///
/// `count` must be at most 32; this is asserted.
inline uint64_t kindsWord(llvm::ArrayRef<uint8_t> kinds, size_t first,
                          size_t count) {
    assert(count <= 32 && "kindsWord: a word holds at most 32 2-bit kinds");
    uint64_t w = 0;
    for (size_t i = 0; i < count && first + i < kinds.size(); ++i)
        w |= uint64_t(kinds[first + i] & 3) << (2 * i);
    return w;
}

/// The slot kinds of one object, packed as the object stores them.
struct PackedKinds {
    uint64_t hdrBits; ///< The kinds that go in the object's kind word, unshifted.
    llvm::SmallVector<uint64_t, 2> ext; ///< The extension kind words, in order, zero words included.
};
/// Returns `kinds` packed for an object whose kind word holds `hdrSlots` kinds:
/// the first `hdrSlots` in `hdrBits`, and the rest 32 to a word in `ext`.
inline PackedKinds packKinds(llvm::ArrayRef<uint8_t> kinds, unsigned hdrSlots) {
    PackedKinds p;
    p.hdrBits = kindsWord(kinds, 0, std::min<size_t>(hdrSlots, kinds.size()));
    for (size_t s = hdrSlots; s < kinds.size(); s += 32)
        p.ext.push_back(
            kindsWord(kinds, s, std::min<size_t>(32, kinds.size() - s)));
    return p;
}

/// Returns the slot kind of each type in `ts`, as `slotKindOf` gives it.
inline llvm::SmallVector<uint8_t> slotKindsOfTypes(mlir::TypeRange ts) {
    llvm::SmallVector<uint8_t> ks;
    ks.reserve(ts.size());
    for (mlir::Type t : ts) ks.push_back(slotKindOf(t));
    return ks;
}

/// Returns a Closure's packed word: `n_values` (bits 0-10), `max_values`
/// (bits 11-21), `result_kind` (bits 22-23) and the kinds of parameters 0 to 19
/// (bits 24-63, `hdrBits`).
///
/// Each argument must fit its field; this is asserted.
inline uint64_t packClosureWord(uint32_t nValues, uint32_t maxValues,
                                uint8_t resultKind, uint64_t hdrBits) {
    assert(nValues <= layout::ClosureCountMask &&
           maxValues <= layout::ClosureCountMask && resultKind < 4 &&
           (hdrBits >> 40) == 0 && "packClosureWord: field out of range");
    return uint64_t(nValues) |
           (uint64_t(maxValues) << layout::ClosureMaxShift) |
           (uint64_t(resultKind & 3) << layout::ClosureRkShift) |
           (hdrBits << layout::ClosureKindsShift);
}

//===----------------------------------------------------------------------===//
// The runtime-function cache and the conversion's shared state
//===----------------------------------------------------------------------===//

/// The state one module conversion shares among all its patterns: a cache of
/// the module's top-level symbols, the declarations of the runtime functions
/// generated code calls, and the side tables that pre-materialization fills for
/// the body patterns to read.
///
/// Patterns receive it by `const` reference; the members a pattern must be
/// able to change are `mutable`, so `const` here does not mean read-only. It
/// refers to `module`, which must outlive it, and its cache holds pointers to
/// the module's operations.
///
/// Each `getOrCreateX` member returns the module's declaration of one runtime
/// function, creating it at the start of the module if there is none (see
/// `getOrCreateFunc`). Its comment names the symbol and whether the declaration
/// is marked gc-leaf: a call to a gc-leaf function is never made a safepoint by
/// RS4GC, so it must not collect. A *marker* is a declaration with no definition
/// that the LLVM backend replaces with inline code before RS4GC.
///
/// Threads. Until `freeze()` every member may be changed, and only one thread
/// may use the object. After `freeze()`, and until `frozen` is cleared, the
/// symbol cache and the side tables are only read, so several threads may look
/// up symbols and call `getOrCreateX` at once, provided every declaration they
/// ask for already exists. Creating one while frozen is an error, caught only by
/// an assertion.
struct EcoRuntime {
    /// The module being converted. Not owned.
    mutable mlir::ModuleOp module;
    /// The context of `module`.
    mlir::MLIRContext *ctx;

    /// The module's top-level operations by symbol name. It is filled from the
    /// module on the first lookup made while it is empty, and by `cacheSymbol`.
    /// The pointers dangle once an operation is erased or replaced, so the cache
    /// must be cleared after a step that replaces top-level operations.
    mutable llvm::DenseMap<mlir::StringAttr, mlir::Operation*> symCache;

    /// The names of the eval-layout globals already created, so that each is
    /// created once. Eval layouts are named by content and referred to only by
    /// name, so they are not in `symCache`. Writes are not synchronised;
    /// creating a layout while `frozen` trips an assertion.
    mutable llvm::StringSet<> evalLayoutNames;

    /// The eco-level type of each `func.func` in the module, kernel
    /// declarations included, by name, recorded before conversion replaces them
    /// with `llvm.func`s. A function that is not in it was never a `func.func`.
    llvm::StringMap<mlir::FunctionType> origFuncTypes;

    /// The index the next string-literal global `__eco_str_N` gets. It starts
    /// at 0 in each `EcoRuntime`, so the names depend only on the module.
    mutable uint64_t stringLiteralCounter = 0;

    /// Unused: nothing fills or reads it.
    mutable llvm::StringMap<std::vector<uint16_t>> utf16PatternCache;

    //===------------------------------------------------------------------===//
    // Freezing and pre-materialization
    //===------------------------------------------------------------------===//

    /// Whether the object is frozen (see the type comment). `freeze()` sets it;
    /// nothing in this type clears it, so code that needs serial changes again
    /// clears it directly.
    mutable bool frozen = false;

    /// While non-null, a creator of a module-level operation whose body or
    /// initializer can be built later makes the operation empty, in its place,
    /// and appends a job here that builds the contents. Every name, counter and
    /// cache entry is still decided serially. The jobs may run in parallel, so
    /// each must build only inside its own operation and only read this object.
    /// The vector is owned by whoever sets the pointer.
    mutable std::vector<std::function<void()>> *deferredBodies = nullptr;

    /// One operation that belongs at the start of the module, recorded in
    /// `topLog` to be built and inserted later.
    ///
    /// Exactly one of `make` and `op` is set. `make` builds the operation
    /// detached, and may run on any thread. `op` is an operation already made,
    /// detached. `cache` says whether the operation is to be added to the symbol
    /// cache when it is inserted.
    struct TopLevelEntry {
        std::function<mlir::Operation *()> make; ///< Empty when `op` is set.
        mlir::Operation *op = nullptr;           ///< Null when `make` is set.
        bool cache = false;
    };
    /// While non-null, operations that belong at the start of the module are
    /// appended here, in creation order, instead of being inserted (see
    /// `emitTopLevel` and `placeTopLevel`). Inserting each entry at the start of
    /// the module, in log order, gives the order inserting them at once would
    /// have. The vector is owned by whoever sets the pointer.
    mutable std::vector<TopLevelEntry> *topLog = nullptr;
    /// The names of logged operations that will be cached once built, so that a
    /// creator sees them as existing before they are.
    mutable llvm::StringSet<> pendingSymbols;
    /// Returns whether `name` is logged in `topLog` to be built and cached. It
    /// is false whenever `topLog` is null.
    bool isPending(llvm::StringRef name) const {
        return topLog && pendingSymbols.contains(name);
    }

    /// The index N of the global `__eco_str_N` that holds each non-empty
    /// `eco.string_literal`, by operation. Filled by
    /// `preMaterializeStringLiterals`. Keyed by operations the body conversion
    /// erases, so it is valid only until then.
    mutable llvm::DenseMap<mlir::Operation *, uint64_t> stringLiteralIndexForOp;

    /// The id each string `eco.case` was given, by operation; its pattern
    /// globals are named `__eco_str_case_<id>_<i>`. Filled by
    /// `preMaterializeStringCases`. Keyed by operations the body conversion
    /// erases, so it is valid only until then.
    mutable llvm::DenseMap<mlir::Operation *, uint64_t> caseIdForOp;

    /// Fills the symbol cache from the module if it is empty, then makes the
    /// object frozen.
    void freeze() const { ensureSymCache(); frozen = true; }

    /// Declares every runtime function that has a `getOrCreateX` member, so that
    /// none needs creating later. Declarations that end up unused stay in the
    /// module until something removes them. Must be called before `freeze()`.
    void materializeAllRuntimeDecls(mlir::OpBuilder &builder) const;

    /// Makes the state for converting `m`.
    explicit EcoRuntime(mlir::ModuleOp m) : module(m), ctx(m.getContext()) {}

    /// Fills the symbol cache with every top-level operation of the module that
    /// has a symbol name, unless the cache already holds anything.
    ///
    /// A cache that is non-empty but incomplete, because `cacheSymbol` was
    /// called before the first lookup, is left as it is.
    void ensureSymCache() const {
        if (!symCache.empty()) return;
        for (auto &op : module.getBody()->getOperations()) {
            if (auto nameAttr = op.getAttrOfType<mlir::StringAttr>(
                    mlir::SymbolTable::getSymbolAttrName()))
                symCache[nameAttr] = &op;
        }
    }

    /// Adds `op` to the symbol cache under its symbol name, if it has one.
    /// Must not be called while frozen; this is asserted.
    void cacheSymbol(mlir::Operation *op) const {
        assert(!frozen &&
               "EcoRuntime::cacheSymbol() after freeze(): a Stage-2 body pattern "
               "created a module-level symbol pre-materialization missed "
               "(parallel-conversion UB)");
        if (auto nameAttr = op->getAttrOfType<mlir::StringAttr>(
                mlir::SymbolTable::getSymbolAttrName()))
            symCache[nameAttr] = op;
    }

    /// Returns the top-level operation named `name` as a `T`, or null if the
    /// cache has no such name or the operation is not a `T`.
    ///
    /// While not frozen this first fills an empty cache from the module. While
    /// frozen it only reads, and may run on several threads at once.
    template <typename T>
    T lookupSymbol(llvm::StringRef name) const {
        if (!frozen) ensureSymCache();
        auto it = symCache.find(mlir::StringAttr::get(ctx, name));
        if (it == symCache.end()) return nullptr;
        return mlir::dyn_cast<T>(it->second);
    }

    /// Returns the top-level operation named `name`, or null if the cache has
    /// none, in the same way as the template overload.
    mlir::Operation *lookupSymbol(llvm::StringRef name) const {
        if (!frozen) ensureSymCache();
        auto it = symCache.find(mlir::StringAttr::get(ctx, name));
        if (it == symCache.end()) return nullptr;
        return it->second;
    }

    /// Returns the `llvm.func` named `name`, declaring it with type `funcType`
    /// at the start of the module and caching it if the cache has no
    /// `llvm.func` of that name.
    ///
    /// A new declaration is marked gc-leaf when `gcLeaf` is true. An existing
    /// one is returned unchanged, whatever its type and marking. Creating one
    /// while frozen is an error, caught only by an assertion.
    mlir::LLVM::LLVMFuncOp getOrCreateFunc(
        mlir::OpBuilder &builder,
        llvm::StringRef name,
        mlir::LLVM::LLVMFunctionType funcType,
        bool gcLeaf = false) const;

    /// Declares `eco_alloc_int`, which boxes an i64. It may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocInt(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_float`, which boxes an f64. It may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocFloat(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_char`, which boxes an i32. It may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocChar(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_cons(head, tail, head kind)`, which builds a Cons cell.
    /// It may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocCons(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_tuple2(a, b, kinds)`, which builds a Tuple2. It may
    /// collect.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocTuple2(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_tuple3(a, b, c, kinds)`, which builds a Tuple3. It may
    /// collect.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocTuple3(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_record(field count, kind word)`, which allocates a
    /// Record. It may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocRecord(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_custom(constructor, field count)`, which allocates a
    /// Custom. It may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocCustom(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_string(length)`. It may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocString(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_string_literal(chars, length)`, which makes a String
    /// from UTF-16 static data. It may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocStringLiteral(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_string_literal_utf8(bytes, length)`, which makes a
    /// String from all-ASCII static data. It may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocStringLiteralUtf8(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_closure(evaluator, arity)`. It may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocClosure(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_closure_k(evaluator, arity, result kind)`. It may
    /// collect.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocClosureK(mlir::OpBuilder &builder) const;
    /// Declares `eco_intern_closure0(evaluator, arity, packed word)`, which
    /// returns a shared closure with no captured values. It is not gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateInternClosure0(mlir::OpBuilder &builder) const;
    /// Declares `eco_allocate(size, tag)`. It may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocate(mlir::OpBuilder &builder) const;

    /// Declares `eco_alloc_int_fast`, gc-leaf: it never collects, and returns
    /// null when the nursery has no room.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocIntFast(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_float_fast`, gc-leaf: it never collects, and returns
    /// null when the nursery has no room.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocFloatFast(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_char_fast`, gc-leaf: it never collects, and returns
    /// null when the nursery has no room.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocCharFast(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_cons_fast`, gc-leaf: it never collects, and returns
    /// null when the nursery has no room.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocConsFast(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_tuple2_fast`, gc-leaf: it never collects, and returns
    /// null when the nursery has no room.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocTuple2Fast(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_tuple3_fast`, gc-leaf: it never collects, and returns
    /// null when the nursery has no room.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocTuple3Fast(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_record_fast`, gc-leaf: it never collects, and returns
    /// null when the nursery has no room.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocRecordFast(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_custom_fast`, gc-leaf: it never collects, and returns
    /// null when the nursery has no room.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocCustomFast(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_string_fast`, gc-leaf: it never collects, and returns
    /// null when the nursery has no room.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocStringFast(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_closure_fast`, gc-leaf: it never collects, and returns
    /// null when the nursery has no room.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocClosureFast(mlir::OpBuilder &builder) const;

    /// Declares `eco_alloc_int_slow`, which may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocIntSlow(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_float_slow`, which may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocFloatSlow(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_char_slow`, which may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocCharSlow(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_cons_slow`, which may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocConsSlow(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_tuple2_slow`, which may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocTuple2Slow(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_tuple3_slow`, which may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocTuple3Slow(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_record_slow`, which may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocRecordSlow(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_custom_slow`, which may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocCustomSlow(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_string_slow`, which may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocStringSlow(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_closure_slow`, which may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocClosureSlow(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_closure_group_l`, which allocates a group of closures
    /// that capture one another. It may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocClosureGroupL(mlir::OpBuilder &builder) const;

    /// Declares `eco_gc_alloc_region_fast(bytes)`, gc-leaf: it never collects,
    /// and returns null when the nursery has no room.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocRegionFast(mlir::OpBuilder &builder) const;
    /// Declares `eco_gc_alloc_region_slow(bytes)`, which may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocRegionSlow(mlir::OpBuilder &builder) const;

    /// Declares `eco_init_int_at`, gc-leaf, which initialises an object at an
    /// address already allocated.
    mlir::LLVM::LLVMFuncOp getOrCreateInitIntAt(mlir::OpBuilder &builder) const;
    /// Declares `eco_init_float_at`, gc-leaf, which initialises an object at an
    /// address already allocated.
    mlir::LLVM::LLVMFuncOp getOrCreateInitFloatAt(mlir::OpBuilder &builder) const;
    /// Declares `eco_init_char_at`, gc-leaf, which initialises an object at an
    /// address already allocated.
    mlir::LLVM::LLVMFuncOp getOrCreateInitCharAt(mlir::OpBuilder &builder) const;
    /// Declares `eco_init_cons_at`, gc-leaf, which initialises an object at an
    /// address already allocated.
    mlir::LLVM::LLVMFuncOp getOrCreateInitConsAt(mlir::OpBuilder &builder) const;
    /// Declares `eco_init_tuple2_at`, gc-leaf, which initialises an object at an
    /// address already allocated.
    mlir::LLVM::LLVMFuncOp getOrCreateInitTuple2At(mlir::OpBuilder &builder) const;
    /// Declares `eco_init_tuple3_at`, gc-leaf, which initialises an object at an
    /// address already allocated.
    mlir::LLVM::LLVMFuncOp getOrCreateInitTuple3At(mlir::OpBuilder &builder) const;
    /// Declares `eco_init_record_at`, gc-leaf, which initialises an object at an
    /// address already allocated.
    mlir::LLVM::LLVMFuncOp getOrCreateInitRecordAt(mlir::OpBuilder &builder) const;
    /// Declares `eco_init_custom_at`, gc-leaf, which initialises an object at an
    /// address already allocated.
    mlir::LLVM::LLVMFuncOp getOrCreateInitCustomAt(mlir::OpBuilder &builder) const;
    /// Declares `eco_init_string_at`, gc-leaf, which initialises an object at an
    /// address already allocated.
    mlir::LLVM::LLVMFuncOp getOrCreateInitStringAt(mlir::OpBuilder &builder) const;

    /// Declares `eco_store_field`, gc-leaf, which stores a boxed field.
    mlir::LLVM::LLVMFuncOp getOrCreateStoreField(mlir::OpBuilder &builder) const;
    /// Declares `eco_store_field_i64`, gc-leaf, which stores an i64 field.
    mlir::LLVM::LLVMFuncOp getOrCreateStoreFieldI64(mlir::OpBuilder &builder) const;
    /// Declares `eco_store_field_f64`, gc-leaf, which stores an f64 field.
    mlir::LLVM::LLVMFuncOp getOrCreateStoreFieldF64(mlir::OpBuilder &builder) const;
    /// Declares `eco_store_record_field`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateStoreRecordField(mlir::OpBuilder &builder) const;
    /// Declares `eco_store_record_field_i64`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateStoreRecordFieldI64(mlir::OpBuilder &builder) const;
    /// Declares `eco_store_record_field_f64`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateStoreRecordFieldF64(mlir::OpBuilder &builder) const;
    /// Declares `eco_set_unboxed`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateSetUnboxed(mlir::OpBuilder &builder) const;

    /// Declares `eco_alloc_tuple2_uninit`, which may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocTuple2Uninit(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_tuple3_uninit`, which may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocTuple3Uninit(mlir::OpBuilder &builder) const;
    /// Declares `eco_alloc_cons_uninit`, which may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocConsUninit(mlir::OpBuilder &builder) const;
    /// Declares `eco_store_tuple_field`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateStoreTupleField(mlir::OpBuilder &builder) const;
    /// Declares `eco_store_tuple_field_i64`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateStoreTupleFieldI64(mlir::OpBuilder &builder) const;
    /// Declares `eco_store_tuple_field_f64`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateStoreTupleFieldF64(mlir::OpBuilder &builder) const;
    /// Declares `eco_store_cons_head`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateStoreConsHead(mlir::OpBuilder &builder) const;
    /// Declares `eco_store_cons_head_i64`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateStoreConsHeadI64(mlir::OpBuilder &builder) const;
    /// Declares `eco_store_cons_head_f64`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateStoreConsHeadF64(mlir::OpBuilder &builder) const;
    /// Declares `eco_store_cons_tail`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateStoreConsTail(mlir::OpBuilder &builder) const;

    /// Declares `eco_pap_extend_l`, which applies a closure to more arguments. It
    /// may collect.
    mlir::LLVM::LLVMFuncOp getOrCreatePapExtendL(mlir::OpBuilder &builder) const;
    /// Declares `eco_closure_call_saturated`. It may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateClosureCallSaturated(mlir::OpBuilder &builder) const;
    /// Declares `eco_closure_call_saturated_eval`, which writes its result
    /// through a pointer. It may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateClosureCallSaturatedEval(mlir::OpBuilder &builder) const;
    /// Declares `eco_apply_closure`. It may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateApplyClosure(mlir::OpBuilder &builder) const;
    /// Declares `eco_apply_closure_typed`. It may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateApplyClosureTyped(mlir::OpBuilder &builder) const;
    /// Declares `eco_apply_closure_eval`, which writes its result through a
    /// pointer. It may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateApplyClosureEval(mlir::OpBuilder &builder) const;
    /// Declares the variadic marker `__eco_sat_begin`, gc-leaf, which with
    /// `__eco_sat_end` brackets a generic closure call that the backend may replace
    /// with a direct saturated call.
    mlir::LLVM::LLVMFuncOp getOrCreateSatBeginMarker(mlir::OpBuilder &builder) const;
    /// Declares the variadic marker `__eco_sat_end`, gc-leaf; see
    /// `getOrCreateSatBeginMarker`.
    mlir::LLVM::LLVMFuncOp getOrCreateSatEndMarker(mlir::OpBuilder &builder) const;

    /// Declares `eco_resolve_hptr`, gc-leaf, which returns the plain address of the
    /// heap object a word points to.
    mlir::LLVM::LLVMFuncOp getOrCreateResolveHPtr(mlir::OpBuilder &builder) const;

    /// Declares the marker `__eco_resolve_fwd`, gc-leaf, which takes and returns
    /// a `ptr addrspace(1)`; the backend replaces it with an inline check for a
    /// forwarding word that calls `eco_follow_forward` when there is one.
    mlir::LLVM::LLVMFuncOp getOrCreateResolveFwdMarker(mlir::OpBuilder &builder) const;
    /// Declares `eco_follow_forward`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateFollowForward(mlir::OpBuilder &builder) const;
    /// Declares `eco_get_tag`, gc-leaf, which returns the constructor tag of a
    /// value.
    mlir::LLVM::LLVMFuncOp getOrCreateGetTag(mlir::OpBuilder &builder) const;
    /// Declares the marker `__eco_get_tag_inline`, gc-leaf, which the backend
    /// replaces with inline code computing what `eco_get_tag` returns.
    mlir::LLVM::LLVMFuncOp getOrCreateGetTagInlineMarker(mlir::OpBuilder &builder) const;
    /// Declares the marker `__eco_alloc_inline(bytes)`, gc-leaf, which the
    /// backend replaces with an inline nursery allocation; see
    /// `emitInlineAllocWithHeader`.
    mlir::LLVM::LLVMFuncOp getOrCreateAllocInlineMarker(mlir::OpBuilder &builder) const;
    /// Declares `eco_cons_head_i64`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateConsHeadI64(mlir::OpBuilder &builder) const;
    /// Declares `eco_cons_head_f64`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateConsHeadF64(mlir::OpBuilder &builder) const;
    /// Declares `eco_cons_head_char`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateConsHeadChar(mlir::OpBuilder &builder) const;
    /// Declares `eco_list_head_hybrid`, gc-leaf, which returns the head of a list
    /// whose first node may be a chunk.
    mlir::LLVM::LLVMFuncOp getOrCreateListHeadHybrid(mlir::OpBuilder &builder) const;
    /// Declares `eco_list_tail_hybrid`, which returns the tail of a list whose
    /// first node may be a chunk. It is not gc-leaf: it may allocate.
    mlir::LLVM::LLVMFuncOp getOrCreateListTailHybrid(mlir::OpBuilder &builder) const;
    /// Declares the marker `__eco_list_head_inline`, gc-leaf, which the backend
    /// replaces with inline code for the head of a chunked list.
    mlir::LLVM::LLVMFuncOp getOrCreateListHeadInlineMarker(mlir::OpBuilder &builder) const;
    /// Declares the marker `__eco_list_tail_inline`, gc-leaf, which the backend
    /// replaces with inline code for the tail of a chunked list. The code it
    /// becomes may call `eco_list_tail_hybrid`, which may allocate.
    mlir::LLVM::LLVMFuncOp getOrCreateListTailInlineMarker(mlir::OpBuilder &builder) const;
    /// Whether lists in the module being converted may contain chunk nodes as
    /// well as Cons cells. When set, list projections are emitted as the
    /// chunk-aware calls or markers instead of direct loads from a Cons cell.
    bool listChunks = false;

    /// Declares `eco_tuple2_get0_i64`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateTuple2Get0I64(mlir::OpBuilder &builder) const;
    /// Declares `eco_tuple2_get1_i64`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateTuple2Get1I64(mlir::OpBuilder &builder) const;
    /// Declares `eco_tuple2_get0_f64`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateTuple2Get0F64(mlir::OpBuilder &builder) const;
    /// Declares `eco_tuple2_get1_f64`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateTuple2Get1F64(mlir::OpBuilder &builder) const;
    /// Declares `eco_tuple2_get0_char`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateTuple2Get0Char(mlir::OpBuilder &builder) const;
    /// Declares `eco_tuple2_get1_char`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateTuple2Get1Char(mlir::OpBuilder &builder) const;

    /// Declares `eco_tuple3_get0_i64`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateTuple3Get0I64(mlir::OpBuilder &builder) const;
    /// Declares `eco_tuple3_get1_i64`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateTuple3Get1I64(mlir::OpBuilder &builder) const;
    /// Declares `eco_tuple3_get2_i64`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateTuple3Get2I64(mlir::OpBuilder &builder) const;
    /// Declares `eco_tuple3_get0_f64`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateTuple3Get0F64(mlir::OpBuilder &builder) const;
    /// Declares `eco_tuple3_get1_f64`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateTuple3Get1F64(mlir::OpBuilder &builder) const;
    /// Declares `eco_tuple3_get2_f64`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateTuple3Get2F64(mlir::OpBuilder &builder) const;
    /// Declares `eco_tuple3_get0_char`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateTuple3Get0Char(mlir::OpBuilder &builder) const;
    /// Declares `eco_tuple3_get1_char`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateTuple3Get1Char(mlir::OpBuilder &builder) const;
    /// Declares `eco_tuple3_get2_char`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateTuple3Get2Char(mlir::OpBuilder &builder) const;

    /// Declares `eco_record_get_i64(object, field index)`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateRecordGetI64(mlir::OpBuilder &builder) const;
    /// Declares `eco_record_get_f64(object, field index)`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateRecordGetF64(mlir::OpBuilder &builder) const;
    /// Declares `eco_record_get_char(object, field index)`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateRecordGetChar(mlir::OpBuilder &builder) const;

    /// Declares `eco_custom_get_i64(object, field index)`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateCustomGetI64(mlir::OpBuilder &builder) const;
    /// Declares `eco_custom_get_f64(object, field index)`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateCustomGetF64(mlir::OpBuilder &builder) const;
    /// Declares `eco_custom_get_char(object, field index)`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateCustomGetChar(mlir::OpBuilder &builder) const;

    /// Declares `eco_array_get_i64(array, index)`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateArrayGetI64(mlir::OpBuilder &builder) const;
    /// Declares `eco_array_get_f64(array, index)`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateArrayGetF64(mlir::OpBuilder &builder) const;
    /// Declares `eco_array_get_char(array, index)`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateArrayGetChar(mlir::OpBuilder &builder) const;

    /// Declares `eco_crash(message)`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateCrash(mlir::OpBuilder &builder) const;
    /// Declares `eco_gc_add_root(address)`, gc-leaf, which registers the word at
    /// `address` as a root.
    mlir::LLVM::LLVMFuncOp getOrCreateGcAddRoot(mlir::OpBuilder &builder) const;
    /// Declares `eco_gc_stack_range_point`, gc-leaf, which returns the current
    /// depth of the root-range stack.
    mlir::LLVM::LLVMFuncOp getOrCreateGcStackRangePoint(mlir::OpBuilder &builder) const;
    /// Declares `eco_gc_push_stack_range(base, count, mask)`, gc-leaf, which
    /// registers up to 64 stack words as roots; see `emitChunkedRootPush`.
    mlir::LLVM::LLVMFuncOp getOrCreateGcPushStackRange(mlir::OpBuilder &builder) const;
    /// Declares `eco_gc_restore_stack_range_point(depth)`, gc-leaf, which pops
    /// the root ranges pushed since `depth`.
    mlir::LLVM::LLVMFuncOp getOrCreateGcRestoreStackRangePoint(mlir::OpBuilder &builder) const;
    /// Declares `eco_register_type_graph`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateRegisterTypeGraph(mlir::OpBuilder &builder) const;
    /// Declares `eco_dispatch_stats_fast`, gc-leaf, a statistics counter.
    mlir::LLVM::LLVMFuncOp getOrCreateDispatchStatsFast(mlir::OpBuilder &builder) const;
    /// Declares `eco_gencall_stats`, gc-leaf, a statistics counter.
    mlir::LLVM::LLVMFuncOp getOrCreateGencallStats(mlir::OpBuilder &builder) const;
    /// Declares the slot-crossing barrier `__eco_slot_to_hptr`, gc-leaf and with no
    /// other attribute.
    mlir::LLVM::LLVMFuncOp getOrCreateSlotToHPtr(mlir::OpBuilder &builder) const;
    /// Declares the slot-crossing barrier `__eco_hptr_to_slot`, gc-leaf and with no
    /// other attribute.
    mlir::LLVM::LLVMFuncOp getOrCreateHPtrToSlot(mlir::OpBuilder &builder) const;
    /// Declares `eco_int_pow`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateIntPow(mlir::OpBuilder &builder) const;
    /// Declares `Elm_Kernel_Utils_equal`, gc-leaf when `kernelGcLeafEnabled()`.
    mlir::LLVM::LLVMFuncOp getOrCreateUtilsEqual(mlir::OpBuilder &builder) const;
    /// Declares the marker `__eco_value_eq`, gc-leaf, which the backend replaces
    /// with inline equality code.
    mlir::LLVM::LLVMFuncOp getOrCreateValueEqMarker(mlir::OpBuilder &builder) const;

    /// Declares `Eco_Runtime_getOrderLT`, gc-leaf, which returns the `LT` value.
    mlir::LLVM::LLVMFuncOp getOrCreateGetOrderLT(mlir::OpBuilder &builder) const;
    /// Declares `Eco_Runtime_getOrderEQ`, gc-leaf, which returns the `EQ` value.
    mlir::LLVM::LLVMFuncOp getOrCreateGetOrderEQ(mlir::OpBuilder &builder) const;
    /// Declares `Eco_Runtime_getOrderGT`, gc-leaf, which returns the `GT` value.
    mlir::LLVM::LLVMFuncOp getOrCreateGetOrderGT(mlir::OpBuilder &builder) const;

    /// Declares `eco_order_from_sign`, gc-leaf, which turns a sign into an
    /// `Order` value.
    mlir::LLVM::LLVMFuncOp getOrCreateOrderFromSign(mlir::OpBuilder &builder) const;
    /// Declares `eco_string_cmp3`, gc-leaf, which compares two strings and
    /// returns an i64 whose sign is the result; its magnitude means nothing.
    mlir::LLVM::LLVMFuncOp getOrCreateStringCmp3(mlir::OpBuilder &builder) const;
    /// Declares `eco_string_cmp_order`, gc-leaf, which compares two strings and
    /// returns an `Order` value.
    mlir::LLVM::LLVMFuncOp getOrCreateStringCmpOrder(mlir::OpBuilder &builder) const;
    /// Declares the marker `__eco_string_len_inline`, gc-leaf, which the backend
    /// replaces with inline code for a string's length.
    mlir::LLVM::LLVMFuncOp getOrCreateStringLenInlineMarker(mlir::OpBuilder &builder) const;
    /// Declares `Elm_Kernel_String_length`. It is not gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateStringLength(mlir::OpBuilder &builder) const;
    /// Declares `eco_string_append`, which may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateStringAppend(mlir::OpBuilder &builder) const;
    /// Declares `eco_list_append`, which may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateListAppend(mlir::OpBuilder &builder) const;
    /// Declares `Elm_Kernel_Utils_cmp3`, which compares two values and returns an
    /// i64 whose sign is the result. It is not gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateUtilsCmp3(mlir::OpBuilder &builder) const;

    /// Declares `eco_clone_array`, which may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateCloneArray(mlir::OpBuilder &builder) const;
    /// Declares `eco_array_set_fix_kind`. It is not gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateArraySetFixKind(mlir::OpBuilder &builder) const;
    /// Declares `elm_array_empty`. It is not gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateArrayEmpty(mlir::OpBuilder &builder) const;
    /// Declares `elm_array_singleton_int`, which may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateArraySingletonInt(mlir::OpBuilder &builder) const;
    /// Declares `elm_array_singleton_float`, which may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateArraySingletonFloat(mlir::OpBuilder &builder) const;
    /// Declares `elm_array_singleton_char`, which may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateArraySingletonChar(mlir::OpBuilder &builder) const;
    /// Declares `elm_array_singleton_box`, which may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateArraySingletonBox(mlir::OpBuilder &builder) const;
    /// Declares `elm_array_push_int`, which may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateArrayPushInt(mlir::OpBuilder &builder) const;
    /// Declares `elm_array_push_float`, which may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateArrayPushFloat(mlir::OpBuilder &builder) const;
    /// Declares `elm_array_push_char`, which may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateArrayPushChar(mlir::OpBuilder &builder) const;
    /// Declares `elm_array_push_box`, which may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateArrayPushBox(mlir::OpBuilder &builder) const;
    /// Declares `elm_array_slice`, which may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateArraySlice(mlir::OpBuilder &builder) const;
    /// Declares `elm_array_append_n`, which may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateArrayAppendN(mlir::OpBuilder &builder) const;

    /// Declares `elm_string_from_int`, which may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateStringFromInt(mlir::OpBuilder &builder) const;
    /// Declares `elm_string_from_double`, which may collect.
    mlir::LLVM::LLVMFuncOp getOrCreateStringFromDouble(mlir::OpBuilder &builder) const;

    /// Declares `eco_dbg_print`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateDbgPrint(mlir::OpBuilder &builder) const;
    /// Declares `eco_dbg_print_int`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateDbgPrintInt(mlir::OpBuilder &builder) const;
    /// Declares `eco_dbg_print_float`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateDbgPrintFloat(mlir::OpBuilder &builder) const;
    /// Declares `eco_dbg_print_char`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateDbgPrintChar(mlir::OpBuilder &builder) const;
    /// Declares `eco_dbg_print_typed`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateDbgPrintTyped(mlir::OpBuilder &builder) const;

    /// Declares the C library's `asin`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateAsin(mlir::OpBuilder &builder) const;
    /// Declares the C library's `acos`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateAcos(mlir::OpBuilder &builder) const;
    /// Declares the C library's `atan`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateAtan(mlir::OpBuilder &builder) const;
    /// Declares the C library's `atan2`, gc-leaf.
    mlir::LLVM::LLVMFuncOp getOrCreateAtan2(mlir::OpBuilder &builder) const;
};

//===----------------------------------------------------------------------===//
// Switches
//
// Each switch below is read from the environment on its first call and kept for
// the life of the process.
//===----------------------------------------------------------------------===//

/// Returns whether heap reads in case dispatch, `eco.get_tag`, aggregate
/// unboxing and closure projection and construction are emitted inline, through
/// the `__eco_resolve_fwd` and `__eco_get_tag_inline` markers and direct
/// stores, rather than as calls to `eco_resolve_hptr`, `eco_get_tag` and the
/// store functions. True unless `ECO_INLINE_DEREF_EXT` is exactly `0`.
inline bool inlineDerefExtEnabled() {
    static const bool enabled = [] {
        const char *e = ::getenv("ECO_INLINE_DEREF_EXT");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return enabled;
}

/// Returns whether objects of fixed small size are allocated inline
/// (`emitInlineAllocWithHeader`) rather than by calling an `eco_alloc_*`
/// function. True unless `ECO_INLINE_ALLOC` is exactly `0`.
///
/// Allocation counts that the runtime keeps inside its allocation functions,
/// such as closure statistics and per-allocation byte counts, do not see inline
/// allocations.
inline bool inlineAllocEnabled() {
    static const bool enabled = [] {
        const char *e = ::getenv("ECO_INLINE_ALLOC");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return enabled;
}

/// Returns whether a kernel function declaration that the compiler marked
/// `eco.gc_leaf` is declared gc-leaf. True unless `ECO_KERNEL_GCLEAF` is exactly
/// `0`; when false, the `eco.gc_leaf` mark is ignored.
inline bool kernelGcLeafEnabled() {
    static const bool enabled = [] {
        const char *e = ::getenv("ECO_KERNEL_GCLEAF");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return enabled;
}

/// Marks `fn` gc-leaf by adding `"gc-leaf-function"` to its `passthrough`
/// attributes, keeping the others. Does nothing if it is already there.
///
/// gc-leaf is the only attribute a declaration that takes or returns
/// `ptr addrspace(1)` may have before RS4GC. An attribute that lets LLVM move
/// or drop a call (`memory`, `speculatable`, `willreturn`) could carry a slot
/// crossing past a safepoint.
inline void attachGcLeafPassthrough(mlir::OpBuilder &builder,
                                    mlir::LLVM::LLVMFuncOp fn) {
    llvm::SmallVector<mlir::Attribute> attrs;
    if (auto existing = fn->getAttrOfType<mlir::ArrayAttr>("passthrough")) {
        for (mlir::Attribute a : existing) {
            if (auto str = llvm::dyn_cast<mlir::StringAttr>(a))
                if (str.getValue() == "gc-leaf-function")
                    return;
            attrs.push_back(a);
        }
    }
    attrs.push_back(builder.getStringAttr("gc-leaf-function"));
    fn->setAttr("passthrough", builder.getArrayAttr(attrs));
}

/// Returns whether `eco.string.length` is emitted as the
/// `__eco_string_len_inline` marker rather than a call to
/// `Elm_Kernel_String_length`. True unless `ECO_STRING_LEN_INLINE` is exactly
/// `0`.
inline bool stringLenInlineEnabled() {
    static const bool enabled = [] {
        const char *e = ::getenv("ECO_STRING_LEN_INLINE");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return enabled;
}

//===----------------------------------------------------------------------===//
// Inline heap access
//
// A *fresh* object is one allocated since the last call that can collect. It
// cannot have been moved, so it has no forwarding word, and it can be written
// through its `ptr addrspace(1)` directly.
//===----------------------------------------------------------------------===//

/// Returns `hptr` through the `__eco_resolve_fwd` marker, which the backend
/// replaces with an inline check that follows a forwarding word.
///
/// `hptr` must point to a heap object: an embedded constant or null-cons word
/// must have been branched away before this.
inline mlir::Value inlineResolvedBase(mlir::OpBuilder &b, mlir::Location loc,
                                      mlir::Value hptr,
                                      const EcoRuntime &runtime) {
    auto marker = runtime.getOrCreateResolveFwdMarker(b);
    return b.create<mlir::LLVM::CallOp>(loc, marker, mlir::ValueRange{hptr})
        .getResult();
}

/// Stores `fieldVal` into the fresh object `baseHptr` at `byteOffset`, as one
/// 64-bit word.
///
/// `origType` is the field's type before conversion and decides the word: an f64
/// is bitcast, an i64 is stored as it is, a narrower integer is zero-extended,
/// and anything else is a boxed value, stored through `heapStoreValueToI64`.
/// The store of a boxed value carries the `eco.boxed_slot` attribute, which
/// `EcoBoxedStoreVerify` reads.
///
/// No call that can collect may come between the allocation of `baseHptr` and
/// this store.
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
        boxed = true;
        word = heapStoreValueToI64(b, loc, fieldVal);
    }
    auto store = b.create<mlir::LLVM::StoreOp>(loc, word, slotPtr);
    if (boxed)
        store->setAttr("eco.boxed_slot", mlir::UnitAttr::get(ctx));
}

/// Stores the extension kind words `ext` into the fresh Custom or Record `obj`
/// with `n` fields starting at `fieldsOffset`: word j goes in slot `n + j`.
/// Every word is stored, zero words included.
///
/// No call that can collect may come between the allocation of `obj` and these
/// stores.
inline void emitExtKindWordStores(mlir::OpBuilder &b, mlir::Location loc,
                                  mlir::Value obj, uint64_t fieldsOffset,
                                  uint64_t n, llvm::ArrayRef<uint64_t> ext) {
    auto i64Ty = mlir::IntegerType::get(b.getContext(), 64);
    for (size_t j = 0; j < ext.size(); ++j) {
        mlir::Value w = b.create<mlir::LLVM::ConstantOp>(
            loc, i64Ty, static_cast<int64_t>(ext[j]));
        emitFreshFieldStore(b, loc, obj,
                            static_cast<int64_t>(fieldsOffset + (n + j) * layout::PtrSize),
                            w, i64Ty);
    }
}

/// Stores the extension kind words `ext` into the fresh Custom or Record `obj`
/// with `n` fields, as `emitExtKindWordStores` does, for an object a runtime
/// function allocated with room for them. Does nothing if `ext` is empty.
///
/// When `inlineDerefExtEnabled()` the words are stored directly; otherwise each
/// is stored by calling `storeI64Func(obj, n + j, word)`, which must be a
/// gc-leaf function that stores an i64 field.
///
/// No call that can collect may come between the allocation of `obj` and these
/// stores.
inline void emitExtKindWordStoresCall(mlir::OpBuilder &b, mlir::Location loc,
                                      mlir::Value obj, uint64_t fieldsOffset,
                                      uint64_t n, llvm::ArrayRef<uint64_t> ext,
                                      mlir::LLVM::LLVMFuncOp storeI64Func) {
    if (ext.empty()) return;
    if (inlineDerefExtEnabled()) {
        emitExtKindWordStores(b, loc, obj, fieldsOffset, n, ext);
        return;
    }
    auto i32Ty = mlir::IntegerType::get(b.getContext(), 32);
    auto i64Ty = mlir::IntegerType::get(b.getContext(), 64);
    for (size_t j = 0; j < ext.size(); ++j) {
        auto idx = b.create<mlir::LLVM::ConstantOp>(loc, i32Ty, static_cast<int32_t>(n + j));
        auto w = b.create<mlir::LLVM::ConstantOp>(loc, i64Ty, static_cast<int64_t>(ext[j]));
        b.create<mlir::LLVM::CallOp>(loc, storeI64Func, mlir::ValueRange{obj, idx, w});
    }
}

/// Whether `emitInlineAllocWithHeader` zeroes an object's payload when its
/// caller does not say.
///
/// An inline allocation's payload is not zeroed by default: it keeps whatever
/// the memory held, and is correct only because the caller writes every word a
/// collector reads before any safepoint. A Closure is read only up to
/// `n_values`, so its unused value slots may hold anything.
inline constexpr bool kZeroPayloadDefault = false;

/// Returns whether to zero an inline allocation's payload: true when the call
/// site asks (`siteRequested`), or when `ECO_INLINE_ZERO` begins with `1`. The
/// variable changes the emitted code.
inline bool inlineZeroPayload(bool siteRequested) {
    static const bool force = []{
        const char *e = std::getenv("ECO_INLINE_ZERO");
        return e != nullptr && e[0] == '1';
    }();
    return siteRequested || force;
}

/// Allocates a `byteSize`-byte object in the nursery inline, stores
/// `headerWord` as its header, and returns its `ptr addrspace(1)`.
///
/// The allocation is the `__eco_alloc_inline` marker, which the backend replaces
/// before RS4GC with a bump of the nursery pointer and a call that may collect
/// when the nursery is full. `byteSize` must be a multiple of 8 in (0, 4096];
/// the backend rejects anything else. When `inlineZeroPayload(zeroPayload)` is
/// true, every byte after the header is zeroed before the header is stored.
///
/// The caller must then store every word of the object that a collector reads,
/// with straight-line code, before any call that can collect; only gc-leaf calls
/// such as the slot-crossing barriers may come between.
inline mlir::Value emitInlineAllocWithHeader(mlir::OpBuilder &b,
                                             mlir::Location loc,
                                             const EcoRuntime &runtime,
                                             uint64_t byteSize,
                                             uint64_t headerWord,
                                             bool zeroPayload = kZeroPayloadDefault) {
    auto *ctx = b.getContext();
    auto i64Ty = mlir::IntegerType::get(ctx, 64);
    auto hptrTy = getHPtrLLVMType(*ctx);

    auto marker = runtime.getOrCreateAllocInlineMarker(b);
    auto sizeConst = b.create<mlir::LLVM::ConstantOp>(
        loc, i64Ty, static_cast<int64_t>(byteSize));
    mlir::Value obj =
        b.create<mlir::LLVM::CallOp>(loc, marker, mlir::ValueRange{sizeConst})
            .getResult();

    if (inlineZeroPayload(zeroPayload) && byteSize > 8) {
        auto i8Ty = mlir::IntegerType::get(ctx, 8);
        auto zeroI8 = b.create<mlir::LLVM::ConstantOp>(
            loc, i8Ty, b.getI8IntegerAttr(0));
        auto eight = b.create<mlir::LLVM::ConstantOp>(loc, i64Ty,
                                                      static_cast<int64_t>(8));
        mlir::Value payload = b.create<mlir::LLVM::GEPOp>(
            loc, obj.getType(), i8Ty, obj, mlir::ValueRange{eight});
        auto lenConst = b.create<mlir::LLVM::ConstantOp>(
            loc, i64Ty, static_cast<int64_t>(byteSize - 8));
        b.create<mlir::LLVM::MemsetOp>(loc, payload, zeroI8, lenConst,
                                       /*isVolatile=*/false);
    }

    auto headerConst = b.create<mlir::LLVM::ConstantOp>(
        loc, i64Ty, static_cast<int64_t>(headerWord));
    // The object's address is the address of its header.
    b.create<mlir::LLVM::StoreOp>(loc, headerConst, obj, /*alignment=*/8);

    return obj;
}

/// Stores `metaWord` at byte offset 8 of the object `obj`: a Custom's
/// constructor and kind word, a Record's kind word or a Closure's packed word.
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

/// The state the control-flow patterns share: the block each joinpoint
/// became, so that a jump can find its target.
///
/// Joinpoint ids are unique only within a function, so a block is keyed by the
/// function and the id. The pointers refer to operations and blocks of the
/// module being converted and are valid only while those exist.
struct EcoCFContext {
    /// The block made for each (enclosing function, joinpoint id).
    llvm::DenseMap<std::pair<mlir::Operation*, int64_t>, mlir::Block*> joinpointBlocks;

    /// Forgets every joinpoint.
    void clear() { joinpointBlocks.clear(); }
};

//===----------------------------------------------------------------------===//
// String Conversion Utilities
//===----------------------------------------------------------------------===//

/// Returns `utf8` as UTF-16 code units. A byte that cannot start a UTF-8
/// sequence becomes U+FFFD; a sequence cut short by the end of the input is
/// decoded from the bytes present. Nothing else is validated.
std::vector<uint16_t> utf8ToUtf16(llvm::StringRef utf8);

//===----------------------------------------------------------------------===//
// Allocation Call
//===----------------------------------------------------------------------===//

/// Emits a call to `allocFunc` with `args` at `op`'s location, and returns its
/// result.
///
/// It emits nothing else: if `allocFunc` is not gc-leaf, RS4GC later makes the
/// call a safepoint. It creates no blocks, so it may be used inside a
/// single-block region.
mlir::Value emitAllocWithSafepoint(
    mlir::Operation *op,
    mlir::ConversionPatternRewriter &rewriter,
    const EcoRuntime &runtime,
    mlir::LLVM::LLVMFuncOp allocFunc,
    mlir::ValueRange args);

//===----------------------------------------------------------------------===//
// Pattern sets
//
// Each populate function adds one pattern file's conversion patterns to
// `patterns`. Patterns that take `runtime` keep a reference to it, so it must
// outlive the pattern set; `typeConverter` likewise.
//===----------------------------------------------------------------------===//

/// Adds the patterns for `eco.constant`, the null-cons constant and
/// `eco.string_literal`. The string-literal pattern requires
/// `preMaterializeStringLiterals` to have run.
void populateEcoTypePatterns(
    EcoTypeConverter &typeConverter,
    mlir::RewritePatternSet &patterns,
    const EcoRuntime &runtime);

/// Replaces each allocation group in the module's `func.func` bodies (an op
/// with `eco.gc_group_size` greater than 1, followed by its members) with one
/// allocation of the whole group's memory, which may collect only on its slow
/// path, and the initialisation of each member in it.
///
/// It must run before the pattern conversion, on eco operations. Allocations
/// not in a group are left to the patterns.
void lowerAllocGroups(mlir::ModuleOp module, const EcoRuntime &runtime);

/// Returns whether `t` is `!eco.value` or a value-level aggregate (tuple,
/// record, custom, cons) with an element for which this is true. A closure
/// environment is not looked into.
bool containsGCPointer(mlir::Type t);

/// Adds the patterns for heap operations: boxing and unboxing, allocation,
/// construction and projection of lists, tuples, records and customs, arrays,
/// and the string and list operations with runtime calls.
void populateEcoHeapPatterns(
    EcoTypeConverter &typeConverter,
    mlir::RewritePatternSet &patterns,
    const EcoRuntime &runtime);

/// Adds the patterns for closures: `eco.project.closure`,
/// `eco.allocate_closure`, `eco.papCreate`, `eco.papCreateGroup`,
/// `eco.papExtend` and `eco.call`. They require
/// `preMaterializeClosureArtifacts` to have run.
void populateEcoClosurePatterns(
    EcoTypeConverter &typeConverter,
    mlir::RewritePatternSet &patterns,
    const EcoRuntime &runtime);

/// Adds the patterns for `eco.return`, `eco.get_tag`, `eco.case`, `eco.yield`,
/// `eco.joinpoint` and `eco.jump`. The joinpoint patterns keep a reference to
/// `cfCtx`, which must outlive the pattern set. A string case requires
/// `preMaterializeStringCases` to have run.
void populateEcoControlFlowPatterns(
    EcoTypeConverter &typeConverter,
    mlir::RewritePatternSet &patterns,
    const EcoRuntime &runtime,
    EcoCFContext &cfCtx);

/// Adds the patterns for arithmetic, comparison, bitwise and conversion
/// operations that need no runtime function.
void populateEcoArithPatterns(
    EcoTypeConverter &typeConverter,
    mlir::RewritePatternSet &patterns);

/// Adds the arithmetic patterns that call runtime functions: integer power,
/// the inverse trigonometric functions and the comparisons that produce an
/// `Order` or a sign.
void populateEcoArithPatternsWithRuntime(
    EcoTypeConverter &typeConverter,
    mlir::RewritePatternSet &patterns,
    const EcoRuntime &runtime);

/// Adds the patterns for `eco.global`, its loads and stores, and the type
/// table.
void populateEcoGlobalPatterns(
    EcoTypeConverter &typeConverter,
    mlir::RewritePatternSet &patterns);

/// Adds the patterns for `eco.dbg`, `eco.crash` and `eco.expect`.
void populateEcoErrorDebugPatterns(
    EcoTypeConverter &typeConverter,
    mlir::RewritePatternSet &patterns,
    const EcoRuntime &runtime);

/// Adds the patterns that convert kernel function declarations, and functions
/// that return a value through a pointer argument, ahead of the standard
/// function conversion.
void populateEcoFuncPatterns(
    EcoTypeConverter &typeConverter,
    mlir::RewritePatternSet &patterns,
    const EcoRuntime &runtime);

/// Adds the patterns for value-level aggregates, which live in SSA rather than
/// on the heap: the `eco.make.*` operations that build them, `eco.to_heap` and
/// `eco.from_heap` that move one onto and off the heap, `eco.make.closure`, and
/// projection from a closure environment.
void populateEcoValueAggPatterns(
    EcoTypeConverter &typeConverter,
    mlir::RewritePatternSet &patterns,
    const EcoRuntime &runtime);

//===----------------------------------------------------------------------===//
// Pre-materialization
//
// Before the parallel body conversion, everything module-level that a body
// pattern would create is created serially, function by function in module
// order, so that names and counters do not depend on thread timing.
//===----------------------------------------------------------------------===//

/// The operations in one function that make the body conversion create
/// module-level symbols, each list in post-order.
struct PreMatDemand {
    llvm::SmallVector<mlir::Operation *, 0> literals; ///< `eco.string_literal` operations.
    llvm::SmallVector<mlir::Operation *, 0> cases;    ///< `eco.case` operations, of every kind.
    /// `eco.papExtend`, `eco.call`, `eco.papCreate`, `eco.papCreateGroup`,
    /// `eco.allocate_closure` and `eco.make_closure` operations.
    llvm::SmallVector<mlir::Operation *, 0> closure;
};

/// Builds the contents of a module-level operation by calling `build` with a
/// builder, now if `runtime.deferredBodies` is null, otherwise later as a job
/// appended to it.
///
/// `build` must set its own insertion point. A deferred `build` is copied or
/// moved into the job and may run on any thread, with a new builder on `ctx`;
/// whatever it captures by reference must outlive the job.
template <typename Fn>
inline void deferOrBuild(const EcoRuntime &runtime, mlir::MLIRContext *ctx,
                         Fn &&build, mlir::OpBuilder &builder) {
    if (runtime.deferredBodies) {
        runtime.deferredBodies->push_back(
            [ctx, build = std::forward<Fn>(build)]() mutable {
                mlir::OpBuilder b(ctx);
                build(b);
            });
        return;
    }
    mlir::OpBuilder::InsertionGuard guard(builder);
    build(builder);
}

/// Creates an operation that belongs at the start of the module by calling
/// `make`, which must build it detached, contents included, and return it.
///
/// If `runtime.topLog` is null, the operation is made now, inserted at the start
/// of the module, added to the symbol cache when `cache` is true, and returned.
/// Otherwise `make` is logged to run later, possibly on another thread, `name`
/// is recorded as pending when `cache` is true, and a null `OpT` is returned.
template <typename OpT, typename Fn>
inline OpT emitTopLevel(const EcoRuntime &runtime, llvm::StringRef name,
                        bool cache, Fn &&make) {
    if (runtime.topLog) {
        EcoRuntime::TopLevelEntry e;
        e.make = std::forward<Fn>(make);
        e.cache = cache;
        runtime.topLog->push_back(std::move(e));
        if (cache)
            runtime.pendingSymbols.insert(name);
        return OpT();
    }
    mlir::Operation *op = make();
    runtime.module.getBody()->push_front(op);
    if (cache)
        runtime.cacheSymbol(op);
    return mlir::cast<OpT>(op);
}

/// Adds `op`, which must be detached, to the symbol cache, and inserts it at
/// the start of the module, or, if `runtime.topLog` is set, logs it to be
/// inserted in order later.
inline void placeTopLevel(const EcoRuntime &runtime, mlir::Operation *op) {
    runtime.cacheSymbol(op);
    if (runtime.topLog) {
        EcoRuntime::TopLevelEntry e;
        e.op = op;
        runtime.topLog->push_back(std::move(e));
        return;
    }
    runtime.module.getBody()->push_front(op);
}

/// Replaces `out` with one `PreMatDemand` per function in `funcs`, in the same
/// order. The functions are scanned in parallel on `ctx`'s thread pool.
void collectPreMatDemand(mlir::MLIRContext *ctx,
                         llvm::ArrayRef<mlir::LLVM::LLVMFuncOp> funcs,
                         std::vector<PreMatDemand> &out);

/// Creates, in demand order, the global `__eco_str_N` holding each non-empty
/// string literal in `demand`, and records N in
/// `runtime.stringLiteralIndexForOp`. An all-ASCII literal is stored as bytes,
/// any other as UTF-16. The globals' initializers go through `deferOrBuild`.
void preMaterializeStringLiterals(
    mlir::OpBuilder &builder, const EcoRuntime &runtime,
    llvm::ArrayRef<PreMatDemand> demand);
/// Gives each string `eco.case` in `demand` an id, in demand order, records it in
/// `runtime.caseIdForOp`, and creates a global `__eco_str_case_<id>_<i>` for each
/// non-empty pattern i, built at once.
void preMaterializeStringCases(
    mlir::OpBuilder &builder, const EcoRuntime &runtime,
    llvm::ArrayRef<PreMatDemand> demand);
/// Creates every closure wrapper, saturated-call entry, evaluator descriptor and
/// eval-layout global that the closure operations in `demand` will need.
void preMaterializeClosureArtifacts(
    mlir::OpBuilder &builder, const EcoRuntime &runtime,
    const mlir::TypeConverter *typeConverter,
    llvm::ArrayRef<PreMatDemand> demand);

//===----------------------------------------------------------------------===//
// Shadow root frames
//
// A function given a shadow root frame keeps its `ptr addrspace(1)` parameters
// in a stack array that is registered as a root range, and reads them back from
// it, so the collector finds and updates them there.
//===----------------------------------------------------------------------===//

/// The values that describe one function's shadow root frame. A frame refers to
/// values in that function and is valid only while the function is.
struct ShadowRootFrame {
    mlir::Value savedPoint;   ///< The root-range depth before the frame was pushed.
    mlir::Value basePtr;      ///< The array's address; null when the function has no frame.
    llvm::DenseMap<mlir::BlockArgument, mlir::Value> slotForArg; ///< Each rooted parameter's slot address.
};

/// Inserts a shadow root frame at the start of `func`'s entry block and returns
/// it: a zeroed array with one slot per `ptr addrspace(1)` parameter, each
/// parameter stored into its slot, and the array pushed as root ranges.
///
/// Returns a frame with a null `basePtr`, having changed nothing, if `func` has
/// no such parameter. It does not rewrite the parameters' uses or pop the
/// ranges; `rewriteUsesViaShadowSlot` and `emitShadowRootEpilogues` do.
ShadowRootFrame installShadowRootPrologue(
    mlir::LLVM::LLVMFuncOp func,
    mlir::OpBuilder &builder,
    const EcoRuntime &runtime);

/// Emits, at `builder`'s insertion point, a load of `arg` from its slot in
/// `frame`, and returns it as a `ptr addrspace(1)`.
///
/// `arg` must be in `frame`; this is asserted. The conversion is a bare
/// `inttoptr`, not a slot-crossing barrier.
mlir::Value loadValueFromShadowSlot(
    const ShadowRootFrame &frame,
    mlir::BlockArgument arg,
    mlir::OpBuilder &builder,
    mlir::Location loc);

/// Makes every use of `arg` read it from its slot in `frame` instead, with a
/// load placed just before the user.
///
/// A `ptrtoint` of `arg` whose result has a single use, by a store, is left
/// alone, whether or not that store is one of the frame's, so that the frame's
/// own stores keep using `arg`.
void rewriteUsesViaShadowSlot(
    const ShadowRootFrame &frame,
    mlir::BlockArgument arg,
    mlir::OpBuilder &builder);

/// Inserts a call that pops `frame`'s root ranges before every `llvm.return` in
/// `func`.
void emitShadowRootEpilogues(
    const ShadowRootFrame &frame,
    mlir::LLVM::LLVMFuncOp func,
    mlir::OpBuilder &builder,
    const EcoRuntime &runtime);

/// Adds the function `__eco_init_globals`, with external linkage, at the end of
/// the module. It registers `__eco_type_graph`, if the module has one, and
/// registers as a root each internal i64 global, except the `__eco_caf$` and
/// `__eco_strlit$` slots. Adds nothing if there is neither.
void createGlobalRootInitFunction(
    mlir::ModuleOp module,
    EcoRuntime &runtime);

/// Declares the runtime function `eco_caf_promote`, gc-leaf, at the end of
/// `module`, unless the module already has it.
void declareCafPromote(mlir::ModuleOp module, mlir::Location loc);
/// Makes the body of `func`, a CAF (a constant defined at top level, compiled as
/// a function of no arguments), run at most once, keeping its value in the
/// global `__eco_caf$<name>`.
///
/// On entry the function returns the slot's value if the slot is not 0.
/// Otherwise its body runs, and each return passes the result through
/// `eco_caf_promote`, stores what that returns in the slot, and returns it. No
/// valid value is the word 0.
///
/// Returns failure, with an error on `func`, if `func` takes arguments or does
/// not return `ptr addrspace(1)`; succeeds without change if it is a
/// declaration. Unless `promoteDeclared` is true, this declares
/// `eco_caf_promote` first (see `declareCafPromote`), and it sets
/// `promoteDeclared` to true. Declaring it changes the module, so callers on
/// several threads must declare it beforehand and pass true.
mlir::LogicalResult installCafMemoGuard(mlir::LLVM::LLVMFuncOp func,
                                        bool &promoteDeclared);

/// Rewrites each call in `func` to a function named in `cafMemoFuncs` that
/// takes no arguments and returns `ptr addrspace(1)`, so that it reads the
/// callee's `__eco_caf$` slot first and makes the call only if the slot is 0.
///
/// The test is an `scf.if`, not new blocks, so it may sit in a single-block
/// region. The callees must be guarded by `installCafMemoGuard`, which fills the
/// slots. Changes only `func`. Does nothing to a declaration.
void rewriteCafCallSitesFast(
    mlir::LLVM::LLVMFuncOp func,
    const llvm::DenseSet<llvm::StringRef> &cafMemoFuncs);

/// Adds, at the end of `module`, a zero-initialised internal i64 global
/// `__eco_strlit$<name>` for each internal array global whose name begins
/// `__eco_str_`, and declares `eco_string_literal_fill` and
/// `eco_string_literal_utf8_fill` unless the module has them. Adds to `slots`
/// the name of every `__eco_strlit$` global the module then holds.
///
/// Does nothing unless the cache is on: it is on unless `ECO_STRLIT_CACHE` is
/// exactly `0`.
void materializeStringLiteralSlots(mlir::ModuleOp module,
                                   llvm::StringSet<> &slots);

/// Rewrites each call in `func` to `eco_alloc_string_literal` or
/// `eco_alloc_string_literal_utf8` on a `__eco_str_` global whose slot is in
/// `slots`, so that it returns the slot's value when the slot is not 0, and
/// otherwise calls the matching `*_fill` function, which also fills the slot.
///
/// The test is an `scf.if`, as in `rewriteCafCallSitesFast`. Changes only
/// `func`. Does nothing to a declaration, or when the cache is off (see
/// `materializeStringLiteralSlots`).
void rewriteStringLiteralCallSitesFast(mlir::LLVM::LLVMFuncOp func,
                                       const llvm::StringSet<> &slots);

/// Returns whether CAF call sites are to be rewritten by
/// `rewriteCafCallSitesFast`, which does not check this itself. True unless
/// `ECO_CAF_CALLER_FAST` is exactly `0`; read once and kept for the life of the
/// process.
inline bool cafCallerFastEnabled() {
    static const bool enabled = [] {
        const char *e = ::getenv("ECO_CAF_CALLER_FAST");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return enabled;
}

/// Emits and returns the address of the `EvaluatorDesc` of the function
/// `funcSymbol` itself, as opposed to a wrapper around it.
///
/// The descriptor must already exist (`preMaterializeClosureArtifacts` creates
/// it); this is asserted.
mlir::Value emitEvalDescAddrForFuncSymbol(mlir::OpBuilder &b, mlir::Location loc,
                                          const EcoRuntime &runtime,
                                          mlir::StringRef funcSymbol);


/// Emits the pushes that register the i64 array at `base` as roots: slot i is a
/// root when `boxed[i]` is true. One `eco_gc_push_stack_range` call covers each
/// run of 64 slots, and a run with no root gets none.
///
/// The caller must save the root-range depth before these pushes and restore
/// it afterwards.
inline void emitChunkedRootPush(mlir::OpBuilder &b, mlir::Location loc,
                                const EcoRuntime &rt, mlir::Value base,
                                llvm::ArrayRef<bool> boxed) {
    auto i64 = b.getI64Type();
    auto push = rt.getOrCreateGcPushStackRange(b);
    for (size_t off = 0; off < boxed.size(); off += 64) {
        size_t c = std::min<size_t>(64, boxed.size() - off);
        uint64_t m = 0;
        for (size_t i = 0; i < c; ++i)
            if (boxed[off + i]) m |= uint64_t{1} << i;
        if (!m) continue;
        mlir::Value p = base;
        if (off) {
            auto offC = b.create<mlir::LLVM::ConstantOp>(loc, i64, static_cast<int64_t>(off));
            p = b.create<mlir::LLVM::GEPOp>(loc, base.getType(), i64, base,
                                            mlir::ValueRange{offC});
        }
        auto cnt = b.create<mlir::LLVM::ConstantOp>(loc, i64, static_cast<int64_t>(c));
        auto mask = b.create<mlir::LLVM::ConstantOp>(
            loc, i64, b.getI64IntegerAttr(static_cast<int64_t>(m)));
        b.create<mlir::LLVM::CallOp>(loc, push, mlir::ValueRange{p, cnt, mask});
    }
}

} // namespace detail
} // namespace eco

#endif // ECO_TO_LLVM_INTERNAL_H
