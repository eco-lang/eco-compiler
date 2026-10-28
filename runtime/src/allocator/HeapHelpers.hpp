// Helpers that runtime and kernel C++ use to build and read Elm values on the garbage-collected heap
// without being left holding a pointer that a collection has made stale.
//
// Almost every allocation may run a collection, and a minor collection moves every nursery object it
// keeps. It rewrites the HPointers it can find, its roots, and nothing else. An HPointer held in a C++
// local, or a raw `void*` returned by `Allocator::resolve`, is therefore stale after any call that may
// allocate, unless it was rooted. The exceptions are a large String or Bytes body, which is pinned and
// never moves, and an object in `PermanentSpace`. This component owns the rules for working under that
// fact, and the helpers below follow them:
//
// - Pattern 1, rooting across an allocation. Code that stores existing HPointers into a new object either
//   calls a helper here that roots its own arguments (`cons`, `tuple2`, `tuple3`, `custom`, `record`,
//   `justKind`, `just`, `ok`, `err`, `stackFrame`, `consChunkView`, `makeByteBufferSlice`,
//   `listFromPointers`, `listFromUnboxables`, `arrayFromPointers`, `allocTask`, `allocTaskUnboxed`,
//   `allocProcess`), or roots them itself with a `StackRootGuard`, a `StackRootRangeGuard` or a
//   `RootedSlots` for as long as it holds them. A direct `Allocator::allocate` outside this file is safe
//   only when nothing it stores is an HPointer the caller already held.
// - Pattern 2, collect then build. A list made from a batch of values is built with `listFromPointers`
//   or `listFromUnboxables`, which root the whole batch with one shadow-stack record, and not by a loop
//   of `cons` calls over a `std::vector` that the collector cannot see.
// - Pattern 3, raw pointers. A function given a resolved `void*` copies what it needs out of the object
//   before it allocates.
//
// A *GC point*, below, is a call that may run a collection. An HPointer is *current* when no GC point has
// run since it was read from a root or returned by an allocation. Most helpers allocate through
// `eco_alloc_with_roots`, which roots the buffer of values it is given only on its slow path, the only
// path that can collect; each helper reads the values it stores back out of that buffer after the call.
//
// Values do not change once Elm code can see them, so the collector has no write barrier; `NurserySpace`
// states the collector's side of that. The builder side is here. A helper that writes into an object
// after allocating it (`arrayPush`, `arrayPushKind`, `closureCapture`, `ListChainWriter`,
// `ListChainReverseWriter`) may write only into an object that has not yet survived a collection, or
// into a *builder*. A builder is an object whose header `builder` bit is set. It must be young, in the
// nursery or the young large-object space; a collection neither ages nor promotes it while the bit is set;
// and the bit must be cleared before Elm code can reach the object. `mark_as_builder`, `clear_builder`,
// `BuilderGuard`, `allocArrayBuilder`, `listChunkChain` and `finishChunkChain` set and clear the bit.
//
// The rest of the file is constructors, accessors and predicates for each kind of value: embedded
// constants, boxed primitives and `Unboxable` slots, Strings, lists (as cons cells and as chunked lists),
// tuples, custom types and records, Bytes, arrays, closures, and tasks and processes. A field's slot kind
// is 2 bits: 0 for a boxed HPointer, 1 for Int, 2 for Float and 3 for Char (Heap.hpp); Bool is always
// boxed. Several helpers also have an overload taking `bool is_boxed`, in which `true` means kind 0 and
// `false` means Int, never Float or Char.
//
// Everything here uses the calling thread's heap and shadow stacks.

#ifndef ECO_HEAP_HELPERS_H
#define ECO_HEAP_HELPERS_H

#include "Allocator.hpp"
#include "AllocatorCommon.hpp"
#include "Heap.hpp"
#include "P1Census.hpp"
#include "RootSet.hpp"
#include "RootedSlots.hpp"
#include "RuntimeExports.h"
#include <algorithm>
#include <cstring>
#include <string>
#include <vector>
#include <initializer_list>

/// Whether the list builders here may produce chunked lists. False until `eco_enable_list_chunks` sets
/// it; that call is made at the start of `@main` only in programs compiled with chunked lists, so
/// helpers produce chunks only for code that can read them.
extern "C" bool eco_g_list_chunks;

/// Whether `cons` reports each call site to `eco_cons_site_tally`, for measurement runs
/// (`ECO_CONS_SITES`).
extern "C" bool eco_g_cons_sites;
/// Counts one `cons` call from the return address `ra`. Defined in RuntimeExports.cpp.
extern "C" void eco_cons_site_tally(void *ra);

namespace Elm {

// Declared here because StringOps.hpp includes this header.
namespace StringOps {
/// Builds a String from `data[0, len)` and stores it in `*out`, returning true. Returns false and leaves
/// `*out` alone when UTF-8 Strings are disabled in the allocator config, when `len` is 0 or above
/// 0xFFFFFFFF, or when any byte is non-ASCII. The result is a `Tag_StringUtf8Leaf` when the leaf is below
/// the large-object threshold, and otherwise a UTF-8 view over a new ByteBuffer. A GC point. `data` must
/// not point into the collected heap, because it is read after an allocation.
bool tryMakeAsciiString(const char* data, size_t len, HPointer* out);
}

/// Returns the `EvaluatorDesc` for a closure built by C++ around the evaluator `fn`, interned once per
/// (`fn`, `stage_arity`, low 2 bits of `result_kind`) for the life of the process.
///
/// Compiled code emits a descriptor for each of its evaluators; a kernel has only the function pointer,
/// so it gets one here. A kernel evaluator takes all its arguments boxed, so the descriptor's `kinds` is
/// 0 and every `sat` entry is null, which sends calls through the generic path. Takes a mutex. Defined in
/// RuntimeExports.cpp.
const EvaluatorDesc* ecoDescForKernelEvaluator(EvalFunction fn,
                                               unsigned stage_arity,
                                               unsigned char result_kind);

// ============================================================================
// GC Stack Root Guard (RAII)
// ============================================================================

/// A scope during which some HPointer variables are roots: a collection that moves what they point to
/// rewrites them in place.
///
/// Use one when code holds an HPointer in a variable, calls something that may allocate, and uses the
/// variable afterwards:
///
///     HPointer cb = ...;
///     HPointer t  = ...;
///     {
///         StackRootGuard guard(&cb, &t);
///         Task* obj = ...;   // may collect; cb and t are rewritten
///         obj->callback = cb;
///         obj->task     = t;
///     }
///
/// The constructor pushes each address onto the calling thread's single-slot shadow stack, and the
/// destructor pops both of that thread's shadow stacks back to where they were at construction, so it
/// also pops any range the guarded scope pushed and did not pop. Each variable must outlive the guard.
/// Guards nest last-in first-out with every other user of those stacks. A guard can be neither copied
/// nor moved.
class StackRootGuard {
public:
    /// Roots `*a`.
    StackRootGuard(HPointer* a) : saved_(ecoRootMark()) {
        ecoRoot1Push(a);
    }
    /// Roots `*a` and `*b`.
    StackRootGuard(HPointer* a, HPointer* b) : saved_(ecoRootMark()) {
        ecoRoot1Push(a);
        ecoRoot1Push(b);
    }
    /// Roots `*a`, `*b` and `*c`.
    StackRootGuard(HPointer* a, HPointer* b, HPointer* c) : saved_(ecoRootMark()) {
        ecoRoot1Push(a);
        ecoRoot1Push(b);
        ecoRoot1Push(c);
    }
    /// Roots `*a`, `*b`, `*c` and `*d`.
    StackRootGuard(HPointer* a, HPointer* b, HPointer* c, HPointer* d)
        : saved_(ecoRootMark()) {
        ecoRoot1Push(a);
        ecoRoot1Push(b);
        ecoRoot1Push(c);
        ecoRoot1Push(d);
    }
    /// Roots each variable `roots` points to, skipping null entries.
    StackRootGuard(std::initializer_list<HPointer*> roots) : saved_(ecoRootMark()) {
        for (HPointer* r : roots) {
            // root-bounded: one push per pointer named at the call site; popped by the destructor
            if (r != nullptr) ecoRoot1Push(r);
        }
    }
    ~StackRootGuard() {
        ecoRootRelease(saved_);
    }

    StackRootGuard(const StackRootGuard&) = delete;
    StackRootGuard& operator=(const StackRootGuard&) = delete;

private:
    EcoRootMark saved_;   // Both shadow stacks' restore points from before construction.
};

/// A scope during which a contiguous buffer of slots, such as the data of a `std::vector<HPointer>`,
/// holds roots.
///
/// The constructor pushes one record onto the calling thread's range stack (`RootSet::pushStackRootRange`,
/// which pushes nothing for a null `base` or a `count` of 0), and the destructor pops that stack back to
/// where it was at construction. Bit `i` of `hpointer_mask` makes slot `i` a root; beyond slot 63 only an
/// all-ones mask makes a slot a root. The buffer must not move or shrink while the guard lives, since the
/// record keeps its address and count. The thread must have a heap. A guard can be neither copied nor
/// moved.
class StackRootRangeGuard {
public:
    /// Roots the slots of `base[0, count)` that `hpointer_mask` selects.
    StackRootRangeGuard(HPointer* base, size_t count, uint64_t hpointer_mask) {
        auto& rs = Allocator::instance().getRootSet();
        saved_ = rs.stackRangePoint();
        rs.pushStackRootRange(base, count, hpointer_mask);
    }
    ~StackRootRangeGuard() {
        Allocator::instance().getRootSet().restoreStackRangePoint(saved_);
    }
    StackRootRangeGuard(const StackRootRangeGuard&) = delete;
    StackRootRangeGuard& operator=(const StackRootRangeGuard&) = delete;
private:
    size_t saved_;   // The range stack's restore point from before construction.
};

namespace alloc {

// ============================================================================
// Embedded Constants
// ============================================================================

/// Returns the Empty constant (word 0x6), the one value of Unit, the empty record, Nil, Nothing, the empty
/// String and the empty Bytes. The five functions after it return the same word.
inline HPointer empty() {
    HPointer p{};
    p.ptr_ind = 1;
    p.constant = Const_Empty;
    return p;
}

/// Returns `[]`, the Empty constant.
inline HPointer listNil()     { return empty(); }
/// Returns `()`, the Empty constant.
inline HPointer unit()        { return empty(); }
/// Returns `Nothing`, the Empty constant.
inline HPointer nothing()     { return empty(); }
/// Returns `""`, the Empty constant. No String of length 0 is ever allocated (HEAP_071).
inline HPointer emptyString() { return empty(); }
/// Returns `{}`, the Empty constant.
inline HPointer emptyRecord() { return empty(); }
/// Returns the empty Bytes, the Empty constant. No ByteBuffer of length 0 is ever allocated (HEAP_071);
/// `resolveBytesOrNull` turns this value into a null pointer, which the Bytes readers here treat as
/// length 0.
inline HPointer emptyBytes()  { return empty(); }

/// Returns True, the constant word 0x5, whose low bit is the Bool's i1 value.
inline HPointer elmTrue() {
    HPointer p{};
    p.ptr_ind = 1;
    p.constant = Const_True;
    return p;
}

/// Returns False, the constant word 0x4.
inline HPointer elmFalse() {
    HPointer p{};
    p.ptr_ind = 1;
    p.constant = Const_False;
    return p;
}

/// Returns whether `ptr` is an embedded constant or a null-cons word rather than a heap pointer, by its
/// `ptr_ind` bit. The null word is not a constant.
inline bool isConstant(HPointer ptr) {
    return ptr.ptr_ind != 0;
}

/// Returns whether `ptr` is the Empty constant, which is how `[]` is represented.
inline bool isNil(HPointer ptr) {
    return Elm::isEmptyBits(Elm::hpBits(ptr));
}

/// Returns whether `ptr` is the Empty constant, which is how `""` is represented. A String object of
/// length 0, which no helper allocates, is not detected; `isZeroLengthString` tests for one.
inline bool isEmptyString(HPointer ptr) {
    return Elm::isEmptyBits(Elm::hpBits(ptr));
}

/// Returns whether `ptr` is an embedded constant or a null-cons word; the same test as `isConstant`.
inline bool isEmbeddedConstant(HPointer ptr) {
    return ptr.ptr_ind != 0;
}

// ============================================================================
// Semantic HPointer constant predicates
// ============================================================================
//
// The word-level tests these build on (`hpBits`, `isConstantBits`, `isEmptyBits`) are in Heap.hpp.

/// Returns whether `p` is the Empty constant. A null-cons word is not Empty.
inline bool isEmpty(HPointer p) {
    return Elm::isEmptyBits(Elm::hpBits(p));
}

/// Returns whether `p` is `Nothing`, the Empty constant.
inline bool isNothing(HPointer p)   { return isEmpty(p); }
/// Returns whether `p` is `()`, the Empty constant.
inline bool isUnit(HPointer p)      { return isEmpty(p); }
/// Returns whether `p` is `{}`, the Empty constant.
inline bool isEmptyRec(HPointer p)  { return isEmpty(p); }

/// Returns whether `p` is True or False: a constant whose code, 0 or 1, has bit 1 clear. Empty (2) and a
/// null-cons word (3) have bit 1 set.
inline bool isBoolConst(HPointer p) {
    return p.ptr_ind != 0 && (p.constant & 2u) == 0;
}
/// Returns the value of the Bool `p`, from bit 0 of its constant code. Meaningful only when `p` is True
/// or False.
inline bool boolValue(HPointer p) { return (p.constant & 1u) != 0; }

/// Checks, in `ECO_HEAP_VALIDATE` builds only, that `hp`, about to be written into a heap field, does
/// not point into a free part of the calling thread's nursery, and aborts if it does
/// (`Allocator::validateInNurserySafe`). Such a pointer is usually one held unrooted across an
/// allocation. Does nothing in other builds.
inline void validateNurseryHPtr(HPointer hp) {
#if ECO_HEAP_VALIDATE
    Allocator::instance().validateInNurserySafe(hp);
#else
    (void)hp;
#endif
}

/// Does what `validateNurseryHPtr` does, for an HPointer held as a 64-bit word.
inline void validateNurseryHPtrBits(uint64_t bits) {
#if ECO_HEAP_VALIDATE
    HPointer hp;
    std::memcpy(&hp, &bits, sizeof(hp));
    validateNurseryHPtr(hp);
#else
    (void)bits;
#endif
}

// ============================================================================
// Primitive Allocation
// ============================================================================

/// Allocates a boxed Int holding `value`, for a place that needs an Int as an HPointer; a field of kind
/// Int holds the value itself. A GC point.
inline HPointer allocInt(i64 value) {
    ElmInt* obj = static_cast<ElmInt*>(
        eco_alloc_with_roots(Tag_Int, sizeof(ElmInt), nullptr, 0, 0));
    obj->value = value;
    return Allocator::instance().wrap(obj);
}

/// Allocates a boxed Float holding `value`, for a place that needs a Float as an HPointer. A GC point.
inline HPointer allocFloat(f64 value) {
    ElmFloat* obj = static_cast<ElmFloat*>(
        eco_alloc_with_roots(Tag_Float, sizeof(ElmFloat), nullptr, 0, 0));
    obj->value = value;
    return Allocator::instance().wrap(obj);
}

/// Allocates a boxed Char holding `value`, a Char value as CharValue.hpp defines it, for a place that
/// needs a Char as an HPointer. A GC point.
inline HPointer allocChar(u32 value) {
    ElmChar* obj = static_cast<ElmChar*>(
        eco_alloc_with_roots(Tag_Char, sizeof(ElmChar), nullptr, 0, 0));
    obj->value = value;
    return Allocator::instance().wrap(obj);
}

// ============================================================================
// Unboxable Helpers
// ============================================================================

/// Returns a slot holding the Int `value`.
inline Unboxable unboxedInt(i64 value) {
    Unboxable u;
    u.i = value;
    return u;
}

/// Returns a slot holding the Float `value`.
inline Unboxable unboxedFloat(f64 value) {
    Unboxable u;
    u.f = value;
    return u;
}

/// Returns a slot holding the Char value `cp` (a code point or, with case expansion on, an encoded
/// case-mapping result; CharValue.hpp), zero-extended to the whole 64-bit word. Code that reads a Char
/// slot as a raw word relies on bits 32 to 63 being zero, so a Char slot is written through this.
inline Unboxable unboxedChar(u32 cp) {
    Unboxable u;
    u.i = static_cast<i64>(cp);
    return u;
}

/// Returns a slot holding the HPointer `ptr`.
inline Unboxable boxed(HPointer ptr) {
    Unboxable u;
    u.p = ptr;
    return u;
}

// ============================================================================
// String Allocation
// ============================================================================

/// Returns a String holding the `length` UTF-16 units at `chars`, or the Empty constant when `length` is
/// 0.
///
/// A String whose object would be at least the large-object threshold is built by
/// `Allocator::allocLargeString`: a header in the nursery and a pinned body in the old generation. Any
/// other is one `Tag_String` leaf.
///
/// A GC point, and the units are copied after the collections it may run (on the large path, possibly
/// more than one). `chars` must therefore not point into the collected heap, unless it points into a
/// rooted large body.
inline HPointer allocString(const u16* chars, size_t length) {
    if (length == 0) {
        return emptyString();
    }

    auto& allocator = Allocator::instance();
    size_t data_size = length * sizeof(u16);
    size_t total_size = sizeof(ElmString) + data_size;
    // Round up to 8-byte alignment
    total_size = (total_size + 7) & ~7;

    // Recorded before the large/leaf split so each call counts once whichever path it takes.
    GC_STATS_STRING_RECORD_ALLOC(total_size);

    if (total_size >= allocator.getLargeObjectThreshold()) {
        return allocator.allocLargeString(chars, length);
    }

    ElmString* str = static_cast<ElmString*>(
        eco_alloc_with_roots(Tag_String, total_size, nullptr, 0, 0));
    str->header.size = static_cast<u32>(length);
    std::memcpy(str->chars, chars, data_size);

    return allocator.wrap(str);
}

/// A new String whose units have not been written yet, with a pointer to write them through.
///
/// `chars` is where the `length` units go; the caller writes all of them before anything else allocates.
/// For a leaf in the nursery, `chars` points into the object and is stale after the next allocation on
/// this thread, which may move it; for a large String it points into the pinned body and stays valid.
/// `hp` is the String itself, an HPointer the caller must root as any other. For `length` 0, `hp` is the
/// Empty constant and `chars` is null.
struct BlankString {
    HPointer hp;
    u16* chars;
    u32 length;
};

/// Allocates a String of `length` UTF-16 units without writing them, so that a caller can write the
/// units straight into the object rather than through a temporary buffer. The size split is as for
/// `allocString`. A GC point, so any HPointer the caller holds across it must be rooted.
///
/// The result's `chars` is valid only as `BlankString` says. Until every unit is written, the String
/// holds garbage and must not be read or reach Elm code.
inline BlankString allocStringBlank(size_t length) {
    if (length == 0) {
        return BlankString{emptyString(), nullptr, 0};
    }

    auto& allocator = Allocator::instance();
    size_t data_size = length * sizeof(u16);
    size_t total_size = sizeof(ElmString) + data_size;
    total_size = (total_size + 7) & ~7;

    GC_STATS_STRING_RECORD_ALLOC(total_size);

    if (total_size >= allocator.getLargeObjectThreshold()) {
        // With null `chars`, allocLargeString leaves the body unwritten.
        HPointer hp = allocator.allocLargeString(nullptr, length);
        void* header_obj = allocator.resolve(hp);
        LargeStringHeader* lh = static_cast<LargeStringHeader*>(header_obj);
        return BlankString{hp, largeStringChars(lh), static_cast<u32>(length)};
    }

    ElmString* str = static_cast<ElmString*>(
        eco_alloc_with_roots(Tag_String, total_size, nullptr, 0, 0));
    str->header.size = static_cast<u32>(length);
    HPointer hp = allocator.wrap(str);
    return BlankString{hp, str->chars, static_cast<u32>(length)};
}

/// Returns a String holding the units of `s`, as `allocString(const u16*, size_t)` does. `s` is C++
/// memory, so it is safe to read after a collection.
inline HPointer allocString(const std::u16string& s) {
    return allocString(reinterpret_cast<const u16*>(s.data()), s.size());
}

/// Returns a String holding the text of the UTF-8 bytes `utf8`, or the Empty constant when it is empty.
///
/// Input that `StringOps::tryMakeAsciiString` accepts (all ASCII, when UTF-8 Strings are enabled) becomes
/// one of the UTF-8 String forms. Anything else is decoded to UTF-16 leniently: a byte that cannot start a
/// sequence is dropped, continuation bytes are not checked, a sequence cut off by the end of the input
/// decodes with its missing bytes taken as zero, and a decoded value above 0x10FFFF is dropped. A GC
/// point.
inline HPointer allocStringFromUTF8(const std::string& utf8) {
    if (utf8.empty()) {
        return emptyString();
    }

    {
        HPointer asciiOut;
        if (StringOps::tryMakeAsciiString(utf8.data(), utf8.size(), &asciiOut)) {
            return asciiOut;
        }
    }

    std::u16string utf16;
    utf16.reserve(utf8.size());

    size_t i = 0;
    while (i < utf8.size()) {
        uint32_t codepoint;
        unsigned char c = static_cast<unsigned char>(utf8[i]);

        if ((c & 0x80) == 0) {
            // 1-byte sequence (ASCII)
            codepoint = c;
            i += 1;
        } else if ((c & 0xE0) == 0xC0) {
            // 2-byte sequence
            codepoint = (c & 0x1F) << 6;
            if (i + 1 < utf8.size()) {
                codepoint |= (utf8[i + 1] & 0x3F);
            }
            i += 2;
        } else if ((c & 0xF0) == 0xE0) {
            // 3-byte sequence
            codepoint = (c & 0x0F) << 12;
            if (i + 1 < utf8.size()) codepoint |= (utf8[i + 1] & 0x3F) << 6;
            if (i + 2 < utf8.size()) codepoint |= (utf8[i + 2] & 0x3F);
            i += 3;
        } else if ((c & 0xF8) == 0xF0) {
            // 4-byte sequence (produces surrogate pair)
            codepoint = (c & 0x07) << 18;
            if (i + 1 < utf8.size()) codepoint |= (utf8[i + 1] & 0x3F) << 12;
            if (i + 2 < utf8.size()) codepoint |= (utf8[i + 2] & 0x3F) << 6;
            if (i + 3 < utf8.size()) codepoint |= (utf8[i + 3] & 0x3F);
            i += 4;
        } else {
            // Invalid byte, skip
            i += 1;
            continue;
        }

        // Convert codepoint to UTF-16
        if (codepoint <= 0xFFFF) {
            utf16.push_back(static_cast<char16_t>(codepoint));
        } else if (codepoint <= 0x10FFFF) {
            // Surrogate pair
            codepoint -= 0x10000;
            utf16.push_back(static_cast<char16_t>(0xD800 | (codepoint >> 10)));
            utf16.push_back(static_cast<char16_t>(0xDC00 | (codepoint & 0x3FF)));
        }
    }

    return allocString(utf16);
}

/// Returns the length in UTF-16 units of the String object `str`, in any of its six forms, from its
/// `header.size` (which for the all-ASCII UTF-8 forms is also the byte count), or 0 for null.
inline size_t stringLength(void* str) {
    if (!str) return 0;
    return static_cast<Header*>(str)->size;
}

/// Returns the UTF-16 units of `str`, which must be a `Tag_String` leaf or a `Tag_LargeStringHeader`
/// (asserted); a slice, rope or UTF-8 form is read through `StringOps`. For a large String the pointer is
/// into its pinned body; for a leaf it is into `str` itself and is stale once a collection may have
/// moved it.
inline const u16* stringData(void* str) {
    Header* hdr = static_cast<Header*>(str);
    if (hdr->tag == Tag_LargeStringHeader) {
        return largeStringChars(static_cast<LargeStringHeader*>(str));
    }
    assert(hdr->tag == Tag_String && "stringData() requires a flat Tag_String leaf or Tag_LargeStringHeader");
    ElmString* s = static_cast<ElmString*>(str);
    return s->chars;
}

// ============================================================================
// List Allocation
// ============================================================================

/// Returns the list `head :: tail`, as one cons cell whose head has slot kind `head_kind` (low 2 bits
/// used). `head`, when boxed, and `tail` are rooted across the allocation. A GC point.
inline HPointer cons(Unboxable head, HPointer tail, u8 head_kind) {
    if (__builtin_expect(eco_g_cons_sites, 0))
        eco_cons_site_tally(__builtin_return_address(0));
    uint64_t roots[2] = { static_cast<uint64_t>(head.i), 0 };
    std::memcpy(&roots[1], &tail, sizeof(tail));
    uint64_t mask = (head_kind == 0) ? 0x3 : 0x2;

    Cons* cell = static_cast<Cons*>(
        eco_alloc_with_roots(Tag_Cons, sizeof(Cons), roots, 2, mask));
    cell->header.size = 0;
    cell->header.unboxed = head_kind & 0x3;
    cell->head.i = static_cast<i64>(roots[0]);
    std::memcpy(&cell->tail, &roots[1], sizeof(cell->tail));
    return Allocator::instance().wrap(cell);
}

/// Returns `head :: tail` with the head's kind boxed when `head_is_boxed` is true and Int when it is
/// false. A Float or Char head needs the kind overload. A GC point.
inline HPointer cons(Unboxable head, HPointer tail, bool head_is_boxed) {
    return cons(head, tail, static_cast<u8>(head_is_boxed ? 0 : 1));
}

// ============================================================================
// Chunked-list allocation
// ============================================================================
//
// A list's spine may mix two kinds of node. A cons cell (`Tag_Cons`) holds one element and the rest of the
// list. A chunk view (`Tag_ConsChunk`) holds a run of elements stored in a backing (`Tag_ListBacking`),
// an array of element slots of one kind. A view records its backing, the offset of its first element
// there, the list's whole logical length `len` from this node to the end, and the node after its run,
// `next`. The run is the elements from `offset` to the end of the backing, or the first `len` of them if
// that is fewer. `::` always makes a cons cell; chunked lists come from the bulk builders here and in the
// kernels, and only when `eco_g_list_chunks` is set.
//
// A chunk is filled once while it is being built and is not written after that. A backing for boxed
// elements is zeroed when allocated, so a collection that runs before it is filled sees null slots, which
// it skips.

/// Allocates a backing of `capacity` element slots, all of slot kind `elem_kind` (low 2 bits used). Slots
/// of a boxed backing are zeroed; slots of any other kind are left unwritten. A GC point.
inline HPointer listBacking(u32 capacity, u8 elem_kind) {
    size_t size = sizeof(ListBacking) + capacity * sizeof(Unboxable);
    ListBacking* lb = static_cast<ListBacking*>(
        eco_alloc_with_roots(Tag_ListBacking, size, nullptr, 0, 0));
    lb->header.size = capacity;
    lb->header.unboxed = elem_kind & 0x3;
    lb->hd = 0;
    lb->_pad = 0;
    if ((elem_kind & 0x3) == 0) {
        std::memset(lb->elems, 0, capacity * sizeof(Unboxable));
    }
    return Allocator::instance().wrap(lb);
}

/// Allocates a chunk view over `backing` starting at element `offset`, followed by `next`. `len` is the
/// logical length of the whole list the view starts, its own run included. `elem_kind` must be the
/// backing's kind; nothing checks it. `backing` and `next` are rooted across the allocation. A GC point.
inline HPointer consChunkView(HPointer backing, u32 offset, u32 len,
                              HPointer next, u8 elem_kind) {
    uint64_t roots[2];
    std::memcpy(&roots[0], &backing, sizeof(backing));
    std::memcpy(&roots[1], &next, sizeof(next));
    ConsChunk* cv = static_cast<ConsChunk*>(
        eco_alloc_with_roots(Tag_ConsChunk, sizeof(ConsChunk), roots, 2, 0x3));
    cv->header.size = 0;
    cv->header.unboxed = elem_kind & 0x3;
    std::memcpy(&cv->backing, &roots[0], sizeof(cv->backing));
    cv->offset = offset;
    cv->len = len;
    std::memcpy(&cv->next, &roots[1], sizeof(cv->next));
    return Allocator::instance().wrap(cv);
}

/// Returns the tail of the non-empty list `list`, or `[]` if `list` is not a cons cell or chunk view.
///
/// For a cons cell, and for a view whose run has one element left, this is the stored next node and
/// nothing is allocated. For a longer run it allocates a new view one element further on, so it is then
/// a GC point. The fields it needs are read before that allocation, and `consChunkView` roots them.
/// `list` must not be a constant: it is resolved without a check.
inline HPointer listTailOf(HPointer list) {
    void* obj = Allocator::instance().resolve(list);
    Header* hdr = getHeader(obj);
    if (hdr->tag == Tag_Cons) {
        return static_cast<Cons*>(obj)->tail;
    }
    if (hdr->tag == Tag_ConsChunk) {
        ConsChunk* cv = static_cast<ConsChunk*>(obj);
        ListBacking* lb = static_cast<ListBacking*>(
            Allocator::instance().resolve(cv->backing));
        u32 run = lb->header.size - cv->offset;
        if (cv->len < run) run = cv->len;
        if (run <= 1) return cv->next;
        return consChunkView(cv->backing, cv->offset + 1, cv->len - 1,
                             cv->next, static_cast<u8>(hdr->unboxed & 0x3));
    }
    return listNil();
}

/// A position in a list, from the front, that stays valid across collections, so the code walking the
/// list may allocate between steps.
///
///     alloc::RootedListCursor c(list);
///     Unboxable head; u8 kind;
///     while (c.read(head, kind)) {
///         // May allocate. If kind is 0 and head.p is used after an allocation, root it first.
///         c.advance();
///     }
///
/// The cursor roots its current node for its whole life and resolves it again at every `read` and
/// `advance`. Its rooting follows `StackRootGuard`'s rules: it must be destroyed on the thread that made
/// it, in last-in first-out order with other roots, and it can be neither copied nor moved. An element
/// returned by `read` is a copy and is not rooted. A node that is not a cons cell or chunk view ends the
/// walk.
struct RootedListCursor {
    HPointer node;  // The current node; `[]` when the walk is over.
    u32 idx;        // The current element's index within a chunk view's run; 0 in a cons cell.
    Allocator* alloc_;   // The process's allocator; not null.
    Elm::StackRootGuard guard;  // Roots `node`.

    /// Starts at the first element of `list`, which must be current.
    explicit RootedListCursor(HPointer list)
        : node(list), idx(0), alloc_(&Allocator::instance()), guard(&node) {}

    /// Stores the current element and its slot kind in `head` and `kind` and returns true, or returns
    /// false at the end of the list. Does not allocate. Calling it again without `advance` returns the
    /// same element.
    bool read(Unboxable& head, u8& kind) {
        while (true) {
            if (isNil(node) || node.ptr_ind != 0) return false;
            void* obj = alloc_->resolve(node);
            if (!obj) return false;
            Header* hdr = getHeader(obj);
            if (hdr->tag == Tag_Cons) {
                Cons* c = static_cast<Cons*>(obj);
                head = c->head;
                kind = static_cast<u8>(Elm::tupleFieldKind(hdr->unboxed, 0));
                return true;
            }
            if (hdr->tag == Tag_ConsChunk) {
                ConsChunk* cv = static_cast<ConsChunk*>(obj);
                ListBacking* lb = static_cast<ListBacking*>(
                    alloc_->resolve(cv->backing));
                u32 run = lb->header.size - cv->offset;
                if (cv->len < run) run = cv->len;
                if (idx >= run) {
                    node = cv->next;
                    idx = 0;
                    continue;
                }
                head = lb->elems[cv->offset + idx];
                kind = static_cast<u8>(hdr->unboxed & 0x3);
                return true;
            }
            return false;
        }
    }

    /// Moves past the current element. Does not allocate. The next `read` moves on to the following node
    /// when a chunk view's run is used up.
    void advance() {
        if (isNil(node) || node.ptr_ind != 0) return;
        void* obj = alloc_->resolve(node);
        if (!obj) { node = listNil(); return; }
        Header* hdr = getHeader(obj);
        if (hdr->tag == Tag_Cons) {
            node = static_cast<Cons*>(obj)->tail;
            idx = 0;
        } else if (hdr->tag == Tag_ConsChunk) {
            ++idx;  // read() rolls over into `next` when the run is exhausted
        } else {
            node = listNil();
        }
    }
};

/// A position in a list, from the front, for a walk that does not allocate.
///
/// The cursor keeps a raw pointer into the current chunk's backing and an unrooted HPointer to the rest
/// of the list, so it is stale after any allocation, which may move them. Code that must allocate during
/// a walk uses `RootedListCursor`, or copies out what it needs and starts a new cursor afterwards from a
/// rooted list. A node that is not a cons cell or chunk view ends the walk.
struct ListCursor {
    Allocator* alloc_;   // The process's allocator; not null.
    HPointer rest;      // The nodes not yet entered; `[]` at the end.
    ListBacking* lb;    // The current chunk's backing; null in a cons cell.
    u32 idx;            // The current element's index in `lb->elems`.
    u32 chunkEnd;       // One past the last index of the current run in `lb->elems`.
    Unboxable cellHead; // The current element when it is a cons cell's head.
    u8 kind;            // The current element's slot kind.
    bool inCell;        // Whether the current element is a cons cell's head.
    bool done_;

    /// Starts at the first element of `list`, which must be current.
    explicit ListCursor(HPointer list) : alloc_(&Allocator::instance()) {
        reset(list);
    }

    /// Starts again at the first element of `list`, which must be current.
    void reset(HPointer list) {
        rest = list;
        lb = nullptr;
        idx = 0;
        chunkEnd = 0;
        kind = 0;
        inCell = false;
        done_ = false;
        advanceSpine();
    }

    /// Returns whether the walk has passed the last element.
    bool done() const { return done_; }

    /// Returns the current element. The cursor must not be `done()`.
    Unboxable current() const { return inCell ? cellHead : lb->elems[idx]; }
    /// Returns the current element's slot kind. The cursor must not be `done()`.
    u8 currentKind() const { return kind; }

    /// Moves to the next element. The cursor must not be `done()`.
    void next() {
        if (inCell) {
            advanceSpine();
        } else if (idx + 1 < chunkEnd) {
            ++idx;
        } else {
            lb = nullptr;
            advanceSpine();
        }
    }

private:
    // Enters the node `rest` names, skipping chunk views with an empty run, until it reaches an element or
    // the end.
    void advanceSpine() {
        inCell = false;
        while (true) {
            if (isNil(rest) || rest.ptr_ind != 0) {
                done_ = true;
                return;
            }
            void* obj = alloc_->resolve(rest);
            if (!obj) {
                done_ = true;
                return;
            }
            Header* hdr = getHeader(obj);
            if (hdr->tag == Tag_Cons) {
                Cons* c = static_cast<Cons*>(obj);
                cellHead = c->head;
                kind = static_cast<u8>(Elm::tupleFieldKind(hdr->unboxed, 0));
                rest = c->tail;
                inCell = true;
                return;
            }
            if (hdr->tag == Tag_ConsChunk) {
                ConsChunk* cv = static_cast<ConsChunk*>(obj);
                ListBacking* backing = static_cast<ListBacking*>(
                    alloc_->resolve(cv->backing));
                u32 cap = backing->header.size;
                u32 run = cap - cv->offset;
                u32 total = cv->len;
                u32 k = run < total ? run : total;
                if (k == 0) {
                    // A view with an empty run is skipped.
                    rest = cv->next;
                    continue;
                }
                lb = backing;
                idx = cv->offset;
                chunkEnd = cv->offset + k;
                kind = static_cast<u8>(hdr->unboxed & 0x3);
                rest = cv->next;
                return;
            }
            // Not a list node: treated as the end.
            done_ = true;
            return;
        }
    }
};


/// Returns the number of elements in `list`, counting up to the first node that is neither a cons cell
/// nor a chunk view. Walks cons cells one at a time and stops at the first chunk view, whose `len` gives
/// the rest. Does not allocate.
inline u32 listLogicalLen(HPointer list) {
    u32 n = 0;
    HPointer cur = list;
    while (!isNil(cur) && cur.ptr_ind == 0) {
        void* obj = Allocator::instance().resolve(cur);
        if (!obj) break;
        Header* hdr = getHeader(obj);
        if (hdr->tag == Tag_Cons) {
            ++n;
            cur = static_cast<Cons*>(obj)->tail;
        } else if (hdr->tag == Tag_ConsChunk) {
            return n + static_cast<ConsChunk*>(obj)->len;
        } else {
            break;
        }
    }
    return n;
}

// ============================================================================
// Chunk chains
// ============================================================================
//
// A batch too large for one backing is split across several, each wrapped in its own view, the views
// linked through `next`. Such a list is a chunk chain.

/// Returns the most elements a backing may hold while its size stays below the large-object threshold,
/// so that every backing in a chain is allocated in the nursery.
inline u32 listBackingMaxElems() {
    return static_cast<u32>(
        (Allocator::instance().getLargeObjectThreshold() - 1
         - sizeof(ListBacking)) / sizeof(Unboxable));
}

/// Returns whether a chunk chain for `n` elements is small enough to build: whether an estimate of its
/// size, backings and views together, is at most a quarter of the calling thread's nursery capacity.
///
/// A chain is built as builders, which a collection keeps in the nursery, so it must fit there with room
/// to spare. A caller whose batch does not fit builds cons cells instead.
inline bool chunkChainFits(u32 n) {
    const size_t links = n / listBackingMaxElems() + 1;
    const size_t bytes = static_cast<size_t>(n) * sizeof(Unboxable) +
                         links * (sizeof(ListBacking) + sizeof(ConsChunk) + 16);
    return bytes * 4 <= Allocator::instance().nurseryCapacityBytes();
}

// Defined with the other builder helpers below.
inline void mark_as_builder(Header* h);
inline void clear_builder(Header* h);

/// Allocates an unfilled chunk chain for `n` elements of slot kind `kind`, followed by `next`, and returns
/// its first view; returns `next` itself when `n` is 0.
///
/// The chain has ceil(n / `listBackingMaxElems()`) backings. The last one holds the remainder and every
/// other one is full. Each view's `len` counts the elements from it to the end, `next`'s included. `next`
/// is rooted across the allocations, which make this a GC point.
///
/// Every backing and view is created as a builder, so a collection during the build or the fill neither
/// ages nor promotes it, and the fill is a legal write. The caller fills the chain with a
/// `ListChainWriter` or `ListChainReverseWriter` without allocating in between, then calls
/// `finishChunkChain(head, n)` before Elm code can reach the list. A boxed chain holds nulls until it is
/// filled.
inline HPointer listChunkChain(u32 n, u8 kind, HPointer next) {
    if (n == 0) return next;
    u32 maxElems = listBackingMaxElems();
    HPointer chain = next;
    StackRootGuard guard(&chain);
    u32 len = isNil(next) ? 0 : listLogicalLen(next);
    u32 remaining = n;
    auto& allocator = Allocator::instance();
    while (remaining > 0) {
        u32 run = remaining % maxElems;
        if (run == 0) run = maxElems;
        HPointer backing = listBacking(run, kind);
        mark_as_builder(getHeader(allocator.resolve(backing)));
        len += run;
        chain = consChunkView(backing, 0, len, chain, kind);
        mark_as_builder(getHeader(allocator.resolve(chain)));
        remaining -= run;
    }
    return chain;
}

/// Clears the builder bit of the views and backings of the chain `listChunkChain(n, ...)` returned as
/// `head`, leaving the list that follows them untouched. `n` must be the count the chain was built for.
/// Does not allocate.
inline void finishChunkChain(HPointer head, u32 n) {
    auto& allocator = Allocator::instance();
    u32 seen = 0;
    HPointer v = head;
    while (seen < n) {
        ConsChunk* cv = static_cast<ConsChunk*>(allocator.resolve(v));
        ListBacking* lb = static_cast<ListBacking*>(allocator.resolve(cv->backing));
        clear_builder(getHeader(cv));
        clear_builder(getHeader(lb));
        seen += lb->header.size;
        v = cv->next;
    }
}

/// A writer that fills a new chunk chain from its first element to its last.
///
/// It keeps a raw pointer to the current backing and an unrooted HPointer to the next view, so nothing
/// may allocate while it is in use. Each `put` stores the next element. The caller must not `put` more
/// elements than the chain holds; nothing checks.
struct ListChainWriter {
    Allocator* alloc_;   // The process's allocator; not null.
    ListBacking* lb;     // The backing being filled; null before the first `put`.
    HPointer nextView;   // The view whose backing is filled next.
    u32 idx, run;        // The next index in `lb`, and `lb`'s capacity.

    /// Starts at the first element of the chain whose first view is `headView`.
    explicit ListChainWriter(HPointer headView)
        : alloc_(&Allocator::instance()), lb(nullptr), nextView(headView),
          idx(0), run(0) {}

    /// Stores `v` as the next element.
    void put(Unboxable v) {
        if (idx == run) {
            ConsChunk* cv =
                static_cast<ConsChunk*>(alloc_->resolve(nextView));
            lb = static_cast<ListBacking*>(alloc_->resolve(cv->backing));
            nextView = cv->next;
            idx = 0;
            run = lb->header.size;
#if P1_CENSUS_COMPILED
            p1::noteWrite(lb, "listChainFill");   // A builder, so the write is legal.
#endif
        }
        lb->elems[idx++] = v;
    }
};

/// A position in a list, walking from the last element to the first, that stays valid across
/// collections once its nodes are rooted.
///
/// The constructor records every node of the list, one entry per cons cell or chunk view, without
/// allocating. The caller then roots those entries with `rootNodes` before anything allocates, and may
/// allocate between calls to `prev`, which resolves the current node again each time. An element `prev`
/// returns is a copy and is not rooted. A node that is not a cons cell or chunk view ends the list.
struct ListBackwardCursor {
    std::vector<HPointer> nodes;  // The list's nodes, first to last.
    size_t ni;                    // The node being read; counts down.
    i64 idx;                      // The next element's index in node `ni`'s run, or -1 to move to the node before.
    Allocator* alloc_;   // The process's allocator; not null.

    /// Records the nodes of `list`, which must be current. Allocates C++ memory only.
    explicit ListBackwardCursor(HPointer list)
        : ni(0), idx(-1), alloc_(&Allocator::instance()) {
        HPointer cur = list;
        while (!isNil(cur) && cur.ptr_ind == 0) {
            void* obj = alloc_->resolve(cur);
            if (!obj) break;
            Header* h = getHeader(obj);
            if (h->tag == Tag_Cons) {
                nodes.push_back(cur);
                cur = static_cast<Cons*>(obj)->tail;
            } else if (h->tag == Tag_ConsChunk) {
                nodes.push_back(cur);
                cur = static_cast<ConsChunk*>(obj)->next;
            } else {
                break;
            }
        }
        ni = nodes.size();
    }

    /// Pushes one record onto `rs`, the calling thread's root set, that roots every recorded node, or
    /// nothing if there are none. The caller takes `rs.stackRangePoint()` first and restores it when the
    /// walk is over, before the cursor is destroyed.
    void rootNodes(RootSet& rs) {
        if (!nodes.empty()) rs.pushStackRootRange(nodes.data(), nodes.size(), ~0ULL);
    }

    /// Stores the next element, walking backwards, and its slot kind in `out` and `kind` and returns true,
    /// or returns false when every element has been returned. Does not allocate.
    bool prev(Unboxable& out, u8& kind) {
        while (true) {
            if (idx < 0) {
                if (ni == 0) return false;
                --ni;
                void* obj = alloc_->resolve(nodes[ni]);
                Header* h = getHeader(obj);
                if (h->tag == Tag_Cons) {
                    idx = 0;
                } else {
                    ConsChunk* cv = static_cast<ConsChunk*>(obj);
                    ListBacking* lb = static_cast<ListBacking*>(
                        alloc_->resolve(cv->backing));
                    u32 avail = lb->header.size - cv->offset;
                    u32 run = cv->len < avail ? cv->len : avail;
                    idx = static_cast<i64>(run) - 1;
                }
                if (idx < 0) continue;
            }
            void* obj = alloc_->resolve(nodes[ni]);
            Header* h = getHeader(obj);
            if (h->tag == Tag_Cons) {
                Cons* c = static_cast<Cons*>(obj);
                out = c->head;
                kind = static_cast<u8>(Elm::tupleFieldKind(h->unboxed, 0));
                idx = -1;
                return true;
            }
            ConsChunk* cv = static_cast<ConsChunk*>(obj);
            ListBacking* lb =
                static_cast<ListBacking*>(alloc_->resolve(cv->backing));
            out = lb->elems[cv->offset + static_cast<u32>(idx)];
            kind = static_cast<u8>(h->unboxed & 0x3);
            --idx;
            return true;
        }
    }
};

/// A writer that fills a new chunk chain from its last element to its first, for a producer that meets
/// the elements in the reverse of list order.
///
/// The constructor records a raw pointer to every backing of the chain, so nothing may allocate while
/// the writer is in use. The caller must not `put` more elements than the chain holds; nothing checks.
struct ListChainReverseWriter {
    std::vector<ListBacking*> chunks;  // The chain's backings, first to last.
    size_t ci;                         // The backing being filled; counts down.
    u32 idx;                           // One past the next index to fill in `chunks[ci]`.

    /// Starts at the last element of the chain `listChunkChain(n, ...)` returned as `headView`. `n` must be
    /// the count the chain was built for, and not 0. Allocates C++ memory only.
    ListChainReverseWriter(HPointer headView, u32 n) : ci(0), idx(0) {
        auto& allocator = Allocator::instance();
        u32 seen = 0;
        HPointer v = headView;
        while (seen < n) {
            ConsChunk* cv = static_cast<ConsChunk*>(allocator.resolve(v));
            ListBacking* lb =
                static_cast<ListBacking*>(allocator.resolve(cv->backing));
#if P1_CENSUS_COMPILED
            p1::noteWrite(lb, "listChainFill");   // A builder, so the write is legal.
#endif
            chunks.push_back(lb);
            seen += lb->header.size;
            v = cv->next;
        }
        ci = chunks.size() - 1;
        idx = chunks[ci]->header.size;
    }

    /// Stores `v` as the element before the one stored last.
    void put(Unboxable v) {
        if (idx == 0) {
            --ci;
            idx = chunks[ci]->header.size;
        }
        chunks[ci]->elems[--idx] = v;
    }
};

/// Returns the list of the boxed values in `rooted`, first to last. Each value is read from `rooted` after
/// the allocations before it, so it is current when stored.
///
/// When `eco_g_list_chunks` is set, there are at least 4 values and `chunkChainFits` allows, the list is
/// one chunk chain; otherwise it is cons cells. A GC point.
inline HPointer listFromPointers(const RootedSlots& rooted) {
    HPointer result = listNil();
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    rs.pushStackRootRange(&result, 1, 1);
    const u32 n = static_cast<u32>(rooted.size());

    // The values are read from the rooted buffer after the chain is allocated; the fill does not allocate.
    if (eco_g_list_chunks && n >= 4 && chunkChainFits(n)) {
        HPointer head = listChunkChain(n, 0, listNil());
        ListChainWriter w(head);
        for (u32 i = 0; i < n; ++i) {
            Unboxable v;
            v.p = rooted[i];
            w.put(v);
        }
        finishChunkChain(head, n);
        rs.restoreStackRangePoint(saved);
        return head;
    }

    for (u32 i = n; i > 0; --i) {
        result = cons(boxed(rooted[i - 1]), result, true);
    }
    rs.restoreStackRangePoint(saved);
    return result;
}

/// Returns the list of the HPointers in `elements`, first to last, or `[]` when it is empty, as the
/// `RootedSlots` overload does. The values must be current on entry; they are copied into a rooted
/// buffer before anything heap-allocates. A GC point.
inline HPointer listFromPointers(const std::vector<HPointer>& elements) {
    RootedSlots rooted(elements.size());
    for (HPointer hp : elements) rooted.push(hp);
    return listFromPointers(rooted);
}

/// Returns the list of Ints in `elements`, first to last, or `[]` when it is empty. The list is one chunk
/// chain under the same conditions as `listFromPointers`, and cons cells otherwise. A GC point.
inline HPointer listFromInts(const std::vector<i64>& elements) {
    // Int slots hold no pointers, so nothing needs rooting.
    if (eco_g_list_chunks && elements.size() >= 4 &&
        chunkChainFits(static_cast<u32>(elements.size()))) {
        u32 n = static_cast<u32>(elements.size());
        HPointer head = listChunkChain(n, 1, listNil());
        ListChainWriter w(head);
        for (u32 i = 0; i < n; ++i) {
            Unboxable v;
            v.i = elements[i];
            w.put(v);
        }
        finishChunkChain(head, n);
        return head;
    }
    HPointer result = listNil();
    for (auto it = elements.rbegin(); it != elements.rend(); ++it) {
        result = cons(unboxedInt(*it), result, static_cast<u8>(1));
    }
    return result;
}

/// Returns the list of Floats in `elements`, first to last, or `[]` when it is empty. The list is always
/// cons cells. A GC point.
inline HPointer listFromFloats(const std::vector<f64>& elements) {
    HPointer result = listNil();
    for (auto it = elements.rbegin(); it != elements.rend(); ++it) {
        result = cons(unboxedFloat(*it), result, static_cast<u8>(2));
    }
    return result;
}

/// Returns the slot kind for a value known only to be boxed or not: 0 when `is_boxed` is true, 1 (Int)
/// when it is false.
///
/// A Float or Char value passed through this is given kind Int, which is wrong. Use it only where the
/// value can only be boxed or an Int; where the real kind is known, pass that.
inline u8 kindFromBoxedFlag(bool is_boxed) {
    return is_boxed ? static_cast<u8>(0) : static_cast<u8>(1);
}

/// Returns the list of the values in `elems`, each with its own slot kind, followed by `tail`; returns
/// `tail` when `elems` is empty. The kind is the full 2-bit slot kind, not a boxed flag, so Float and Char
/// elements keep their kinds.
///
/// The elements are in `elems`' order, or in reverse order when `reversed` is true. `tail`, when it is a
/// heap pointer, and the boxed values are rooted, and each value is read from `elems` after the
/// allocations before it. When `eco_g_list_chunks` is set, there are at least 4 elements,
/// `chunkChainFits` allows and every element has the same kind, the elements are one chunk chain;
/// otherwise they are cons cells. A GC point.
inline HPointer listFromUnboxables(
        const RootedElems& elems,
        HPointer tail = listNil(),
        bool reversed = false) {
    if (elems.empty()) return tail;

    // `elems` roots the boxed values; `result` is the one other root.
    HPointer result = tail;
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    rs.pushStackRootRange(&result, 1, 1);
    const u32 n = static_cast<u32>(elems.size());

    // The values are read from `elems` after the chain is allocated; the fill does not allocate.
    if (eco_g_list_chunks && n >= 4 && chunkChainFits(n) && elems.uniform()) {
        u8 kind = elems.kind(0);
        HPointer head = listChunkChain(n, kind, result);
        ListChainWriter w(head);
        if (reversed) {
            for (u32 i = n; i > 0; --i) w.put(elems.get(i - 1));
        } else {
            for (u32 i = 0; i < n; ++i) w.put(elems.get(i));
        }
        finishChunkChain(head, n);
        rs.restoreStackRangePoint(saved);
        return head;
    }

    if (reversed) {
        for (u32 i = 0; i < n; ++i) {
            result = cons(elems.get(i), result, elems.kind(i));
        }
    } else {
        for (u32 i = n; i > 0; --i) {
            result = cons(elems.get(i - 1), result, elems.kind(i - 1));
        }
    }

    rs.restoreStackRangePoint(saved);
    return result;
}

/// Returns what the `RootedElems` overload returns for the (value, slot kind) pairs in `elems`. The boxed
/// values must be current on entry; they are copied into a rooted buffer before anything heap-allocates.
/// A GC point.
inline HPointer listFromUnboxables(
        const std::vector<std::pair<Unboxable, u8>>& elems,
        HPointer tail = listNil(),
        bool reversed = false) {
    if (elems.empty()) return tail;
    RootedElems rooted(elems.size());
    for (const auto& [val, kind] : elems) rooted.push(val, kind);
    return listFromUnboxables(rooted, tail, reversed);
}

// ============================================================================
// Tuple Allocation
// ============================================================================

/// Returns the pair `(a, b)`. `unboxed_mask` holds the two slot kinds, 2 bits each, `a`'s in bits 0-1 and
/// `b`'s in bits 2-3; higher bits are ignored. The boxed fields are rooted across the allocation. A GC
/// point.
inline HPointer tuple2(Unboxable a, Unboxable b, u32 unboxed_mask) {
    uint64_t roots[2] = { static_cast<uint64_t>(a.i), static_cast<uint64_t>(b.i) };
    uint64_t mask = 0;
    if (tupleFieldKind(unboxed_mask, 0) == 0) mask |= 0x1;
    if (tupleFieldKind(unboxed_mask, 1) == 0) mask |= 0x2;

    Tuple2* tuple = static_cast<Tuple2*>(
        eco_alloc_with_roots(Tag_Tuple2, sizeof(Tuple2), roots, 2, mask));
    tuple->header.unboxed = unboxed_mask & 0xF;
    tuple->a.i = static_cast<i64>(roots[0]);
    tuple->b.i = static_cast<i64>(roots[1]);
    return Allocator::instance().wrap(tuple);
}

/// Returns the triple `(a, b, c)`. `unboxed_mask` holds the three slot kinds, 2 bits each from bit 0 in
/// field order; bits above 5 are ignored. The boxed fields are rooted across the allocation. A GC point.
inline HPointer tuple3(Unboxable a, Unboxable b, Unboxable c, u32 unboxed_mask) {
    uint64_t roots[3] = {
        static_cast<uint64_t>(a.i),
        static_cast<uint64_t>(b.i),
        static_cast<uint64_t>(c.i),
    };
    uint64_t mask = 0;
    if (tupleFieldKind(unboxed_mask, 0) == 0) mask |= 0x1;
    if (tupleFieldKind(unboxed_mask, 1) == 0) mask |= 0x2;
    if (tupleFieldKind(unboxed_mask, 2) == 0) mask |= 0x4;

    Tuple3* tuple = static_cast<Tuple3*>(
        eco_alloc_with_roots(Tag_Tuple3, sizeof(Tuple3), roots, 3, mask));
    tuple->header.unboxed = unboxed_mask & 0x3F;
    tuple->a.i = static_cast<i64>(roots[0]);
    tuple->b.i = static_cast<i64>(roots[1]);
    tuple->c.i = static_cast<i64>(roots[2]);
    return Allocator::instance().wrap(tuple);
}

// ============================================================================
// Custom Type Allocation
// ============================================================================

namespace detail {
/// Allocates a Custom or Record (`tag`) holding `values`, with field `i`'s slot kind given by `kindOf(i)`,
/// and writes the kinds and values. Aborts past the type's field limit. The caller sets anything else,
/// such as a Custom's constructor. `values` must not be empty.
///
/// The boxed values are rooted across the allocation, in records of 64 slots when there are more than 64.
/// The first kinds go in the object's own bitmap and the rest in the extension kind words after the values
/// (HEAP_019); the allocation has already zeroed those words. `KindOf` is called with a field index and
/// must return the kind in its low 2 bits. A GC point.
template <class Obj, class KindOf>
inline Obj* allocWideContainer(Tag tag, const std::vector<Unboxable>& values, KindOf kindOf) {
    const bool isC = tag == Tag_Custom;
    const u32 n = static_cast<u32>(values.size());
    if (n > (isC ? CUSTOM_MAX_FIELDS : RECORD_MAX_FIELDS))
        ecoFatalWideObject(isC ? "alloc::custom" : "alloc::record", n);
    const size_t total_size = wideByteSize(tag, n);
    std::vector<uint64_t> roots(n);
    for (u32 i = 0; i < n; ++i) std::memcpy(&roots[i], &values[i], sizeof(uint64_t));
    Obj* obj;
    if (n <= 64) {
        uint64_t hptr_mask = 0;
        for (u32 i = 0; i < n; ++i) if (kindOf(i) == 0) hptr_mask |= uint64_t{1} << i;
        obj = static_cast<Obj*>(eco_alloc_with_roots(tag, total_size,
                                roots.empty() ? nullptr : roots.data(), n, hptr_mask));
    } else {
        size_t saved = eco_gc_stack_range_point();
        pushRootsByKinds(roots.data(), n, kindOf);
        obj = static_cast<Obj*>(eco_alloc_with_roots(tag, total_size, nullptr, 0, 0));
        eco_gc_restore_stack_range_point(saved);
    }
    assert(obj->header.size == n && obj->header.unboxed == extWords(n, isC ? CUSTOM_HDR_SLOTS : RECORD_HDR_SLOTS));
    const u32 cap = isC ? CUSTOM_HDR_SLOTS : RECORD_HDR_SLOTS;
    u64 hdrBits = 0;
    for (u32 i = 0; i < n && i < cap; ++i) hdrBits |= u64(kindOf(i) & 3u) << (2 * i);
    obj->unboxed = hdrBits;
    if (n > cap) {
        u64* ext = reinterpret_cast<u64*>(&obj->values[n]);
        for (u32 i = cap; i < n; ++i) {
            const u32 r = i - cap;
            ext[r / SLOTS_PER_EXT_WORD] |= u64(kindOf(i) & 3u) << (2 * (r % SLOTS_PER_EXT_WORD));
        }
    }
    for (u32 i = 0; i < n; ++i) std::memcpy(&obj->values[i], &roots[i], sizeof(Unboxable));
    return obj;
}
} // namespace detail

/// Returns the value of constructor `ctor` of a custom type with fields `values`, whose slot kinds are
/// `kinds`, one per field. Aborts if there are more than `CUSTOM_MAX_FIELDS` fields. The boxed fields are
/// rooted across the allocation. A GC point when there are fields.
///
/// A constructor with no fields is not a heap object: for empty `values` this returns the null-cons word
/// for `ctor`, which must be at most `NULL_CONS_MAX` (asserted), and allocates nothing.
inline HPointer custom(u16 ctor, const std::vector<Unboxable>& values, const std::vector<u8>& kinds) {
    assert(kinds.size() == values.size());
    if (values.empty()) {
        // A nullary constructor must have one representation (HEAP_044): equality decides by comparing
        // words once either side is a constant, so a heap copy would compare unequal to the constant.
        assert(ctor <= NULL_CONS_MAX && "nullary ctor index exceeds null_cons_idx capacity");
        return hpFromBits(nullConsWordFor(ctor));
    }
    Custom* obj = detail::allocWideContainer<Custom>(
        Tag_Custom, values, [&](uint32_t i) -> uint32_t { return kinds[i] & 3u; });
    obj->ctor = ctor;
    return Allocator::instance().wrap(obj);
}

/// Returns what the `kinds` overload returns, with the kinds of fields 0 to 23 given 2 bits each in
/// `unboxed_mask`, which must fit in 48 bits (asserted). Fields past 23 are boxed.
inline HPointer custom(u16 ctor, const std::vector<Unboxable>& values, u64 unboxed_mask) {
    assert((unboxed_mask >> 48) == 0 && "Custom unboxed bitmap overflow (>48 bits)");
    if (values.empty()) {
        assert(ctor <= NULL_CONS_MAX && "nullary ctor index exceeds null_cons_idx capacity");
        return hpFromBits(nullConsWordFor(ctor));   // HEAP_044, as above
    }
    Custom* obj = detail::allocWideContainer<Custom>(
        Tag_Custom, values, [&](uint32_t i) -> uint32_t {
            return i < CUSTOM_HDR_SLOTS ? kindInWord(unboxed_mask, i) : 0u;
        });
    obj->ctor = ctor;
    return Allocator::instance().wrap(obj);
}

/// Returns `Just value`, where `value` has slot kind `kind` (low 2 bits used). A GC point.
inline HPointer justKind(Unboxable value, u8 kind) {
    std::vector<Unboxable> vals = {value};
    u64 mask = static_cast<u64>(kind) & 0x3;
    return custom(0, vals, mask);
}

/// Returns `Just value`, with the value boxed when `is_boxed` is true and an Int when it is false. A GC
/// point.
inline HPointer just(Unboxable value, bool is_boxed) {
    return justKind(value, static_cast<u8>(is_boxed ? 0 : 1));
}

/// Returns `Ok value` (constructor 0), with the value boxed when `is_boxed` is true and an Int when it is
/// false. A GC point.
inline HPointer ok(Unboxable value, bool is_boxed) {
    std::vector<Unboxable> vals = {value};
    u64 mask = is_boxed ? 0 : 1;
    return custom(0, vals, mask);  // Ok is ctor 0
}

/// Returns `Err value` (constructor 1), with the value boxed when `is_boxed` is true and an Int when it is
/// false. A GC point.
inline HPointer err(Unboxable value, bool is_boxed) {
    std::vector<Unboxable> vals = {value};
    u64 mask = is_boxed ? 0 : 1;
    return custom(1, vals, mask);  // Err is ctor 1
}

// ============================================================================
// Record Allocation
// ============================================================================

/// Returns the record with fields `values`, in the record type's field order, whose slot kinds are
/// `kinds`, one per field, or `{}` when `values` is empty. Aborts if there are more than
/// `RECORD_MAX_FIELDS` fields. The boxed fields are rooted across the allocation. A GC point when there
/// are fields.
inline HPointer record(const std::vector<Unboxable>& values, const std::vector<u8>& kinds) {
    assert(kinds.size() == values.size());
    if (values.empty()) {
        return emptyRecord();
    }
    Record* obj = detail::allocWideContainer<Record>(
        Tag_Record, values, [&](uint32_t i) -> uint32_t { return kinds[i] & 3u; });
    return Allocator::instance().wrap(obj);
}

/// Returns what the `kinds` overload returns, with the kinds of fields 0 to 31 given 2 bits each in
/// `unboxed_mask`. Fields past 31 are boxed.
inline HPointer record(const std::vector<Unboxable>& values, u64 unboxed_mask) {
    if (values.empty()) {
        return emptyRecord();
    }
    Record* obj = detail::allocWideContainer<Record>(
        Tag_Record, values, [&](uint32_t i) -> uint32_t {
            return i < RECORD_HDR_SLOTS ? kindInWord(unboxed_mask, i) : 0u;
        });
    return Allocator::instance().wrap(obj);
}

// ============================================================================
// ByteBuffer Allocation
// ============================================================================

/// Returns a Bytes value holding a copy of the `length` bytes at `data`, or the empty Bytes when `length`
/// is 0. With a null `data` nothing is copied, and the large path zeroes the body.
///
/// A Bytes value whose object would be at least the large-object threshold is built by
/// `Allocator::allocLargeByteBuffer`, as a nursery header and a pinned body; any other is one
/// `Tag_ByteBuffer`. A GC point, and the bytes are copied after the collections it may run. `data` must
/// therefore not point into the collected heap, unless it points into a rooted large body.
inline HPointer allocByteBuffer(const u8* data, size_t length) {
    if (length == 0) return emptyBytes();
    auto& allocator = Allocator::instance();
    size_t total_size = sizeof(ByteBuffer) + length;
    total_size = (total_size + 7) & ~7;

    if (total_size >= allocator.getLargeObjectThreshold()) {
        return allocator.allocLargeByteBuffer(data, length);
    }

    ByteBuffer* buf = static_cast<ByteBuffer*>(
        eco_alloc_with_roots(Tag_ByteBuffer, total_size, nullptr, 0, 0));
    buf->header.size = static_cast<u32>(length);
    if (data && length > 0) {
        std::memcpy(buf->bytes, data, length);
    }
    return allocator.wrap(buf);
}

/// A new Bytes value whose bytes have not been written yet, with a pointer to write them through.
///
/// `bytes` is where the `length` bytes go; the caller writes all of them before anything else allocates.
/// For a buffer in the nursery, `bytes` points into the object and is stale after the next allocation on
/// this thread; for a large buffer it points into the pinned body and stays valid. `hp` is the value
/// itself, an HPointer the caller must root as any other. For `length` 0, `hp` is the empty Bytes and
/// `bytes` is null.
struct BlankByteBuffer {
    HPointer hp;
    u8* bytes;
    u32 length;
};

/// Allocates a Bytes value of `length` bytes and returns it with a pointer to write them through, so that
/// an encoder can write straight into the object. The size split is as for `allocByteBuffer`. A GC point,
/// so any HPointer the caller holds across it must be rooted.
///
/// Nothing is written to the bytes on the small path; the large path zeroes them. The result's `bytes` is valid
/// only as `BlankByteBuffer` says.
inline BlankByteBuffer allocByteBufferBlank(size_t length) {
    if (length == 0) return BlankByteBuffer{emptyBytes(), nullptr, 0};
    auto& allocator = Allocator::instance();

    size_t total_size = sizeof(ByteBuffer) + length;
    total_size = (total_size + 7) & ~7;

    if (total_size >= allocator.getLargeObjectThreshold()) {
        HPointer hp = allocator.allocLargeByteBuffer(nullptr, length);
        void* header_obj = allocator.resolve(hp);
        LargeByteHeader* lh = static_cast<LargeByteHeader*>(header_obj);
        return BlankByteBuffer{hp, largeBytesData(lh), static_cast<u32>(length)};
    }

    ByteBuffer* buf = static_cast<ByteBuffer*>(
        eco_alloc_with_roots(Tag_ByteBuffer, total_size, nullptr, 0, 0));
    buf->header.size = static_cast<u32>(length);
    HPointer hp = allocator.wrap(buf);
    return BlankByteBuffer{hp, buf->bytes, static_cast<u32>(length)};
}

/// Returns a Bytes value of `length` zero bytes, or the empty Bytes when `length` is 0. A GC point.
inline HPointer allocByteBufferZero(size_t length) {
    if (length == 0) return emptyBytes();
    auto& allocator = Allocator::instance();
    size_t total_size = sizeof(ByteBuffer) + length;
    total_size = (total_size + 7) & ~7;

    if (total_size >= allocator.getLargeObjectThreshold()) {
        // allocLargeByteBuffer zeroes when data == nullptr.
        return allocator.allocLargeByteBuffer(nullptr, length);
    }

    ByteBuffer* buf = static_cast<ByteBuffer*>(
        eco_alloc_with_roots(Tag_ByteBuffer, total_size, nullptr, 0, 0));
    buf->header.size = static_cast<u32>(length);
    if (length > 0) {
        std::memset(buf->bytes, 0, length);
    }
    return allocator.wrap(buf);
}

/// Returns the length in bytes of the Bytes object `buf`, in any of its three forms (`Tag_ByteBuffer`,
/// `Tag_LargeByteHeader`, `Tag_ByteBufferSlice`), from its `header.size`, or 0 for null, which is how
/// `resolveBytesOrNull` returns the empty Bytes.
inline size_t byteBufferLength(void* buf) {
    if (!buf) return 0;
    Header* hdr = static_cast<Header*>(buf);
    return hdr->size;
}

/// Returns the first byte of the Bytes object `buf`, in any of its three forms, or null for null. For a
/// large buffer, or a slice of one, the pointer is into the pinned body; otherwise it is into a nursery or
/// old-generation object and is stale once a collection may have moved it.
inline const u8* byteBufferData(void* buf) {
    if (!buf) return nullptr;
    Header* hdr = static_cast<Header*>(buf);
    if (hdr->tag == Tag_ByteBufferSlice) {
        ElmByteBufferSlice* slc = static_cast<ElmByteBufferSlice*>(buf);
        void* base = Allocator::instance().resolve(slc->base);
        // A slice made by `makeByteBufferSlice` never has a slice as its base.
        Header* basehdr = static_cast<Header*>(base);
        if (basehdr->tag == Tag_LargeByteHeader) {
            return largeBytesData(static_cast<LargeByteHeader*>(base)) + slc->offset;
        }
        ByteBuffer* b = static_cast<ByteBuffer*>(base);
        return b->bytes + slc->offset;
    }
    if (hdr->tag == Tag_LargeByteHeader) {
        return largeBytesData(static_cast<LargeByteHeader*>(buf));
    }
    ByteBuffer* b = static_cast<ByteBuffer*>(buf);
    return b->bytes;
}

// ============================================================================
// Array Allocation
// ============================================================================

/// Allocates an array with room for `capacity` elements, of length 0 and element kind boxed. It is not a
/// builder. The caller fills it with `arrayPush` or `arrayPushKind` before it survives a collection, or
/// uses `allocArrayBuilder` when the fill may allocate. A GC point.
inline HPointer allocArray(size_t capacity) {
    size_t total_size = sizeof(ElmArray) + capacity * sizeof(Unboxable);
    total_size = (total_size + 7) & ~7;

    ElmArray* arr = static_cast<ElmArray*>(
        eco_alloc_with_roots(Tag_Array, total_size, nullptr, 0, 0));
    arr->header.size = static_cast<u32>(capacity);
    arr->length = 0;
    arr->padding = 0;
    arr->header.unboxed = 0;
    return Allocator::instance().wrap(arr);
}

// ============================================================================
// Builder Bit Helpers
// ============================================================================
//
// A builder, as the file comment defines it, is an object a kernel may keep writing into across
// allocations and calls back into Elm. The header bit keeps it young (HEAP_BUILDER_001), so a half-built
// object never becomes an old-generation object pointing at young ones.

/// Makes the object whose header is `h` a builder: sets its `builder` bit and sets its age to 0, since a
/// builder's age must stay 0 (HEAP_BUILDER_002). The object must be young.
inline void mark_as_builder(Header* h) {
    h->builder = 1;
    h->age = 0;
}

/// Clears the `builder` bit of the object whose header is `h`, after which it ages and may be promoted
/// like any other object. In `ECO_HEAP_VALIDATE` builds, asserts that the object is still young, in the
/// nursery or the young large-object space.
inline void clear_builder(Header* h) {
#if ECO_HEAP_VALIDATE
    assert((Allocator::instance().isInNursery(h) ||
            Allocator::instance().getCurrentThreadHeap()->getOldGen().isYoungLarge(h)) &&
           "HEAP_BUILDER_001: clear_builder on non-nursery object");
#endif
    h->builder = 0;
}

/// A scope during which an object is a builder, so that every way out of a kernel's fill clears the bit
/// before Elm code can reach the object (HEAP_BUILDER_003).
///
/// The guard keeps the address of the caller's HPointer variable, not the object, and resolves it again
/// when it clears the bit, since a collection may have moved the object meanwhile. The variable must
/// therefore be rooted, and must outlive the guard. A guard can be neither copied nor moved.
class BuilderGuard {
public:
    /// Makes the object `*hp` names a builder. `*hp` must be a young heap object, not a constant.
    explicit BuilderGuard(HPointer* hp) : hp_(hp), active_(true) {
        void* obj = Allocator::instance().resolve(*hp_);
        assert(obj && "BuilderGuard: object must resolve at construction");
        mark_as_builder(static_cast<Header*>(obj));
    }

    BuilderGuard(const BuilderGuard&) = delete;
    BuilderGuard& operator=(const BuilderGuard&) = delete;

    /// Clears the builder bit now rather than at destruction, for a kernel that hands the object on before
    /// the guard's scope ends. Does nothing if called before.
    void clear() {
        if (!active_) return;
        active_ = false;
        void* obj = Allocator::instance().resolve(*hp_);
        if (obj) {
            clear_builder(static_cast<Header*>(obj));
        }
    }

    /// Clears the builder bit, unless `clear` already has.
    ~BuilderGuard() { clear(); }

private:
    HPointer* hp_;   // The caller's variable naming the object.
    bool active_;    // Whether the bit has yet to be cleared.
};

/// Allocates an array as `allocArray` does and makes it a builder, for a kernel whose fill may allocate
/// or call back into Elm. The caller must clear the bit, with a `BuilderGuard` or `clear_builder`, before
/// Elm code can reach the array (HEAP_BUILDER_003). A GC point.
inline HPointer allocArrayBuilder(size_t capacity) {
    HPointer hp = allocArray(capacity);
    void* obj = Allocator::instance().resolve(hp);
    assert(obj && "allocArrayBuilder: array allocation resolved to null");
    mark_as_builder(static_cast<Header*>(obj));
    return hp;
}

/// Returns an array holding the HPointers in `elements`, in order, with element kind boxed. The values must
/// be current on entry; they are copied into a rooted buffer before the allocation. A GC point.
inline HPointer arrayFromPointers(const std::vector<HPointer>& elements) {
    size_t capacity = elements.size();
    size_t total_size = sizeof(ElmArray) + capacity * sizeof(Unboxable);
    total_size = (total_size + 7) & ~7;

    // eco_alloc_with_roots roots at most 64 slots, so the copy is rooted with one all-ones record instead.
    std::vector<HPointer> rooted = elements;
    Elm::StackRootRangeGuard guard(rooted.data(), rooted.size(), ~uint64_t{0});

    ElmArray* arr = static_cast<ElmArray*>(
        eco_alloc_with_roots(Tag_Array, total_size, nullptr, 0, 0));
    arr->header.size = static_cast<u32>(capacity);
    arr->length = static_cast<u32>(rooted.size());
    arr->padding = 0;
    arr->header.unboxed = 0;
    for (size_t i = 0; i < rooted.size(); ++i) {
        arr->elements[i].p = rooted[i];
    }
#if ECO_HEAP_VALIDATE
    for (size_t i = 0; i < rooted.size(); ++i)
        validateNurseryHPtr(arr->elements[i].p);
#endif
    return Allocator::instance().wrap(arr);
}

/// Returns an array holding the Ints in `elements`, in order, with element kind Int. A GC point.
inline HPointer arrayFromInts(const std::vector<i64>& elements) {
    size_t capacity = elements.size();
    size_t total_size = sizeof(ElmArray) + capacity * sizeof(Unboxable);
    total_size = (total_size + 7) & ~7;

    ElmArray* arr = static_cast<ElmArray*>(
        eco_alloc_with_roots(Tag_Array, total_size, nullptr, 0, 0));
    arr->header.size = static_cast<u32>(capacity);
    arr->length = static_cast<u32>(elements.size());
    arr->header.unboxed = 1;  // Int
    arr->padding = 0;
    for (size_t i = 0; i < elements.size(); ++i) {
        arr->elements[i].i = elements[i];
    }
    return Allocator::instance().wrap(arr);
}

/// Returns the number of elements in the array object `arr`.
inline size_t arrayLength(void* arr) {
    ElmArray* a = static_cast<ElmArray*>(arr);
    return a->length;
}

/// Returns the number of elements the array object `arr` has room for.
inline size_t arrayCapacity(void* arr) {
    ElmArray* a = static_cast<ElmArray*>(arr);
    return a->header.size;
}

/// Appends `value` to the array object `arr` and returns true, or returns false if the array is full.
///
/// All of an array's elements have one slot kind. The first push sets it, to boxed when `is_boxed` is true
/// and to Int when it is false; later pushes must agree, and nothing checks that they do. `arr` must be a
/// builder or must not yet have survived a collection; only builds with the P1 census check. Does not allocate.
inline bool arrayPush(void* arr, Unboxable value, bool is_boxed) {
    ElmArray* a = static_cast<ElmArray*>(arr);
    if (a->length >= a->header.size) {
        return false;  // At capacity
    }
#if P1_CENSUS_COMPILED
    p1::noteWrite(arr, "arrayPush");
#endif

    if (is_boxed) validateNurseryHPtr(value.p);

    size_t idx = a->length;
    a->elements[idx] = value;

    if (idx == 0) {
        a->header.unboxed = is_boxed ? 0 : 1;
    }

    a->length++;
    return true;
}

/// Appends `value`, of slot kind `kind` (low 2 bits used), as `arrayPush` does: the first push sets the
/// array's kind and later pushes must agree, unchecked.
inline bool arrayPushKind(void* arr, Unboxable value, u8 kind) {
    ElmArray* a = static_cast<ElmArray*>(arr);
    if (a->length >= a->header.size) return false;
#if P1_CENSUS_COMPILED
    p1::noteWrite(arr, "arrayPushKind");
#endif

    if ((kind & 0x3) == 0) validateNurseryHPtr(value.p);

    size_t idx = a->length;
    a->elements[idx] = value;
    if (idx == 0) {
        a->header.unboxed = kind & 0x3;
    }
    a->length++;
    return true;
}

/// Returns element `index` of the array object `arr`. `index` must be less than the length; nothing
/// checks.
inline Unboxable arrayGet(void* arr, size_t index) {
    ElmArray* a = static_cast<ElmArray*>(arr);
    return a->elements[index];
}

/// Returns whether the elements of the array object `arr` are unboxed, that is, whether its one element
/// kind is not boxed.
inline bool arrayIsUnboxed(void* arr) {
    ElmArray* a = static_cast<ElmArray*>(arr);
    return (a->header.unboxed & 0x3) != 0;
}

/// Returns the slot kind of every element of the array object `arr`.
inline u32 arrayElementKind(void* arr) {
    ElmArray* a = static_cast<ElmArray*>(arr);
    return a->header.unboxed & 0x3;
}

// ============================================================================
// Closure Allocation
// ============================================================================

/// Allocates a closure over the kernel evaluator `evaluator` with room for `max_values` arguments and
/// none yet captured. Aborts if `max_values` exceeds `CLOSURE_MAX_ARITY`. A GC point.
///
/// `result_kind` is the slot kind `evaluator` returns (low 2 bits used), kept in the closure so that code
/// calling it reads the result correctly. The closure's descriptor comes from `ecoDescForKernelEvaluator`.
/// Arguments are added with `closureCapture` before the closure survives a collection.
inline HPointer allocClosureK(EvalFunction evaluator, u32 max_values,
                               u8 result_kind) {
    if (max_values > CLOSURE_MAX_ARITY) {
        std::fprintf(stderr, "[eco] FATAL: allocClosureK: closure arity %u exceeds %u\n",
                     max_values, CLOSURE_MAX_ARITY);
        std::abort();
    }
    // max_values value slots, then K extension kind words (HEAP_078).
    const u32 K = extWords(max_values, CLOSURE_HDR_SLOTS);
    size_t total_size = sizeof(Closure) + (static_cast<size_t>(max_values) + K) * sizeof(Unboxable);

    // Nothing to root: the arguments come later, and the evaluator is not a heap value.
    Closure* cl = static_cast<Closure*>(
        eco_alloc_with_roots(Tag_Closure, total_size, nullptr, 0, 0));
    cl->header.size = max_values + K;
    cl->n_values = 0;
    cl->max_values = max_values;
    cl->result_kind = result_kind & 0x3;
    cl->unboxed = 0;
    cl->evaluator = ecoDescForKernelEvaluator(evaluator, max_values, result_kind);
    // closureCapture never writes an extension word, so every slot past the own bitmap is boxed (HEAP_077).
    u64* ext = reinterpret_cast<u64*>(&cl->values[max_values]);
    for (u32 j = 0; j < K; ++j) ext[j] = 0;
#if ECO_HEAP_VALIDATE
    assert(cl->evaluator->stage_arity == max_values &&
           "allocClosureK: max_values != evaluator->stage_arity");
#endif
    return Allocator::instance().wrap(cl);
}

/// Allocates a closure as `allocClosureK` does, for an evaluator that returns a boxed value. A GC point.
inline HPointer allocClosure(EvalFunction evaluator, u32 max_values) {
    return allocClosureK(evaluator, max_values, /*result_kind=*/0);
}

/// Appends `value`, of kind `kind`, as the next argument of the closure object `closure` and returns
/// true, or returns false if the closure already holds `max_values` arguments.
///
/// Only the first `CLOSURE_HDR_SLOTS` (20) slots have kinds in the closure's own bitmap, and this never
/// writes an extension kind word, so a capture of any kind but boxed at slot 20 or beyond aborts, in
/// every build. `closure` must not yet have survived a collection, or must be a builder; only builds with
/// the P1 census check. Does not allocate.
inline bool closureCapture(void* closure, Unboxable value, ParamKind kind) {
    Closure* cl = static_cast<Closure*>(closure);
    if (cl->n_values >= cl->max_values) {
        return false;
    }
#if P1_CENSUS_COMPILED
    p1::noteWrite(closure, "closureCapture");
#endif

    if (kind == PK_Boxed) validateNurseryHPtr(value.p);

    size_t idx = cl->n_values;
    if (kind != PK_Boxed && idx >= CLOSURE_HDR_SLOTS) {
        // The slot would read as boxed and be traced as a pointer.
        std::fprintf(stderr, "[eco] FATAL: closureCapture of a typed value at slot %zu "
                             "(inline kinds cover %u)\n", idx, CLOSURE_HDR_SLOTS);
        std::abort();
    }
    cl->values[idx] = value;
    if (kind != PK_Boxed) {
        cl->unboxed = bitmapSetKind(cl->unboxed, static_cast<unsigned>(idx),
                                    static_cast<u64>(kind));
    }

    cl->n_values++;

#if ECO_HEAP_VALIDATE
    // The kind just stored must read back as `kind`.
    {
        u64 stored = closureSlotKind(cl, static_cast<u32>(idx));
        u64 expected = (kind == PK_Boxed) ? 0ULL : static_cast<u64>(kind);
        if (stored != expected) {
            std::fprintf(stderr,
                "[heap-validate] closureCapture bitmap mismatch: closure=%p "
                "idx=%zu expected_kind=%llu stored_kind=%llu unboxed=0x%llx\n",
                closure, idx,
                (unsigned long long)expected, (unsigned long long)stored,
                (unsigned long long)cl->unboxed);
            std::fflush(stderr);
            std::abort();
        }
    }
#endif

    return true;
}

/// Appends `value` as `closureCapture` does, with kind boxed when `is_boxed` is true and Int when it is
/// false.
inline bool closureCapture(void* closure, Unboxable value, bool is_boxed) {
    return closureCapture(closure, value, is_boxed ? PK_Boxed : PK_Int);
}

/// Returns the slot `v`, of slot kind `kind`, as an HPointer: `v.p` itself for kind 0 (or any kind above
/// 3), or a new boxed Int, Float or Char for kinds 1 to 3, which makes it a GC point.
inline HPointer boxElement(Unboxable v, u32 kind) {
    switch (kind) {
        case 1: return allocInt(v.i);
        case 2: return allocFloat(v.f);
        case 3: return allocChar(v.c);
        default: return v.p;
    }
}

// ============================================================================
// Task / Process / StackFrame Allocation
// ============================================================================

/// The constructor index of a Task object.
enum TaskCtor : u16 {
    Task_Succeed  = 0,
    Task_Fail     = 1,
    Task_Binding  = 2,
    Task_AndThen  = 3,
    Task_OnError  = 4,
    Task_Receive  = 5,
};

/// The constructor index of a stack frame, the Custom that `stackFrame` builds.
static constexpr u16 CTOR_StackFrame = 0xFFFE;
/// The constructor index of an effect router. The same value as `CONSTANT_TAG`, which is reported for
/// the Empty constant.
static constexpr u16 CTOR_Router     = 0xFFFD;

/// The constructor index of a node of an effect bag.
enum FxBagTag : u16 {
    Fx_Leaf = 0,
    Fx_Node = 1,
    Fx_Map  = 2,
};

/// Returns a Task with constructor `ctor` whose four fields `value`, `callback`, `kill` and `innerTask`
/// are all HPointers, rooted across the allocation. Its id is 0. A GC point.
inline HPointer allocTask(u16 ctor, HPointer value, HPointer callback,
                          HPointer kill, HPointer innerTask) {
    size_t total_size = (sizeof(Task) + 7) & ~7;
    uint64_t roots[4];
    std::memcpy(&roots[0], &value, 8);
    std::memcpy(&roots[1], &callback, 8);
    std::memcpy(&roots[2], &kill, 8);
    std::memcpy(&roots[3], &innerTask, 8);
    Task* t = static_cast<Task*>(
        eco_alloc_with_roots(Tag_Task, total_size, roots, 4, 0xF));
    t->header.unboxed = 0;
    t->ctor = ctor;
    t->id = 0;
    t->padding = 0;
    std::memcpy(&t->value.p, &roots[0], 8);
    std::memcpy(&t->callback,   &roots[1], 8);
    std::memcpy(&t->kill,       &roots[2], 8);
    std::memcpy(&t->task,       &roots[3], 8);
    return Allocator::instance().wrap(t);
}

/// Returns a Task as `allocTask` does, except that `value` is unboxed, of slot kind `valueKind` (low 2
/// bits used; 0 would mark it boxed although it is not rooted). A GC point.
inline HPointer allocTaskUnboxed(u16 ctor, Unboxable value, u8 valueKind,
                                 HPointer callback, HPointer kill,
                                 HPointer innerTask) {
    size_t total_size = (sizeof(Task) + 7) & ~7;
    // Slot 0 holds the unboxed value, so mask bit 0 is clear.
    uint64_t roots[4];
    std::memcpy(&roots[0], &value, 8);
    std::memcpy(&roots[1], &callback, 8);
    std::memcpy(&roots[2], &kill, 8);
    std::memcpy(&roots[3], &innerTask, 8);
    Task* t = static_cast<Task*>(
        eco_alloc_with_roots(Tag_Task, total_size, roots, 4, /*mask=*/0xE));
    t->header.unboxed = static_cast<u32>(valueKind & 0x3);
    t->ctor = ctor;
    t->id = 0;
    t->padding = 0;
    std::memcpy(&t->value,    &roots[0], 8);
    std::memcpy(&t->callback, &roots[1], 8);
    std::memcpy(&t->kill,     &roots[2], 8);
    std::memcpy(&t->task,     &roots[3], 8);
    return Allocator::instance().wrap(t);
}

/// Returns a Process with id `id` and the HPointer fields `root`, `stack` and `mailbox`, rooted across the
/// allocation. A GC point.
inline HPointer allocProcess(u64 id, HPointer root, HPointer stack, HPointer mailbox) {
    size_t total_size = (sizeof(Process) + 7) & ~7;
    uint64_t roots[3];
    std::memcpy(&roots[0], &root, 8);
    std::memcpy(&roots[1], &stack, 8);
    std::memcpy(&roots[2], &mailbox, 8);
    Process* p = static_cast<Process*>(
        eco_alloc_with_roots(Tag_Process, total_size, roots, 3, 0x7));
    p->id = id;
    std::memcpy(&p->root,    &roots[0], 8);
    std::memcpy(&p->stack,   &roots[1], 8);
    std::memcpy(&p->mailbox, &roots[2], 8);
    return Allocator::instance().wrap(p);
}

/// Returns a stack frame, a Custom with constructor `CTOR_StackFrame` and fields `expectedTag` (an Int),
/// `callback` and `rest`, the two HPointers rooted across the allocation. A GC point.
inline HPointer stackFrame(u64 expectedTag, HPointer callback, HPointer rest) {
    std::vector<Unboxable> fields(3);
    fields[0].i = static_cast<i64>(expectedTag);
    fields[1].p = callback;
    fields[2].p = rest;
    return custom(CTOR_StackFrame, fields, 0x1);  // Field 0 is kind 1 (Int); the others are boxed.
}

// ============================================================================
// Type Checking Helpers
// ============================================================================

/// Returns the tag of the heap object `obj`.
inline Tag getTag(void* obj) {
    Header* hdr = static_cast<Header*>(obj);
    return static_cast<Tag>(hdr->tag);
}

/// Returns whether the heap object `obj` is a cons cell. A chunk view, the other kind of list node, is
/// not.
inline bool isCons(void* obj) {
    return getTag(obj) == Tag_Cons;
}

/// Returns whether the heap object `obj` is a String in any of its six forms: `Tag_String`,
/// `Tag_StringSlice`, `Tag_StringRope`, `Tag_LargeStringHeader`, `Tag_StringUtf8View` or
/// `Tag_StringUtf8Leaf`.
inline bool isString(void* obj) {
    Tag t = getTag(obj);
    return t == Tag_String || t == Tag_StringSlice || t == Tag_StringRope ||
           t == Tag_LargeStringHeader ||
           t == Tag_StringUtf8View || t == Tag_StringUtf8Leaf;
}

/// Returns whether `obj` is a String object of length 0. No helper allocates one, since `""` is the Empty
/// constant (HEAP_071), but the equality and ordering code treats one as equal to `""` and uses this to
/// find it. Returns false for null.
inline bool isZeroLengthString(void* obj) {
    return obj && isString(obj) && static_cast<Header*>(obj)->size == 0;
}

/// Returns whether the heap object `obj` is a `Tag_String` leaf, whose UTF-16 units are inside the object.
/// A large String is not; `stringData` and `flatStringView` read either.
inline bool isStringLeaf(void* obj) {
    return getTag(obj) == Tag_String;
}


/// The bytes of a Bytes value, as a pointer and a length, whatever form the value has.
///
/// A view does not own its bytes. For a large buffer, or a slice of one, `data` points into the pinned
/// body and stays valid while the value is reachable. Otherwise it points into a heap object and is stale
/// after the next allocation on this thread, which may move it. A null `data` with length 0 is the empty
/// Bytes.
struct ByteBufferView {
    const u8* data;
    size_t length;
};

/// Returns a view of the bytes of `obj`, which must be a `Tag_ByteBuffer` or a `Tag_LargeByteHeader`; a
/// slice is asserted against and is read with `byteBufferView`. The length is always the outer object's
/// `header.size`.
inline ByteBufferView flatBytesView(void* obj) {
    Header* hdr = static_cast<Header*>(obj);
    assert(hdr->tag != Tag_ByteBufferSlice &&
           "flatBytesView called on a Tag_ByteBufferSlice; use byteBufferView instead");
    if (hdr->tag == Tag_LargeByteHeader) {
        return ByteBufferView{largeBytesData(static_cast<LargeByteHeader*>(obj)), hdr->size};
    }
    ByteBuffer* bb = static_cast<ByteBuffer*>(obj);
    return ByteBufferView{bb->bytes, bb->header.size};
}

/// Returns a view of the bytes of the Bytes object `obj`, in any of its three forms, or an empty view for
/// null.
inline ByteBufferView byteBufferView(void* obj) {
    if (!obj) return ByteBufferView{nullptr, 0};
    Header* hdr = static_cast<Header*>(obj);
    if (hdr->tag == Tag_ByteBufferSlice) {
        ElmByteBufferSlice* slc = static_cast<ElmByteBufferSlice*>(obj);
        void* base = Allocator::instance().resolve(slc->base);
        // A slice made by `makeByteBufferSlice` never has a slice as its base.
        return ByteBufferView{flatBytesView(base).data + slc->offset, slc->header.size};
    }
    return flatBytesView(obj);
}

/// Returns the object the Bytes value `hp` names, or null when `hp` is a constant, which for a Bytes value
/// means the empty Bytes. `Allocator::resolve` must not be given a constant. `byteBufferView`,
/// `byteBufferLength` and `byteBufferData` read null as the empty Bytes.
inline void* resolveBytesOrNull(HPointer hp) {
    if (hp.ptr_ind != 0) return nullptr;
    return Allocator::instance().resolve(hp);
}

/// The length in bytes below which `makeByteBufferSlice` copies the bytes rather than make a slice.
static constexpr size_t MAKE_BYTEBUFFER_SLICE_MIN_LEN = 32;

/// Returns the `length` bytes of the Bytes value `base` starting at `offset`, or the empty Bytes when
/// `length` is 0. The range must lie within `base`; nothing checks.
///
/// Below `MAKE_BYTEBUFFER_SLICE_MIN_LEN` bytes the result is a copy. Otherwise it is a slice, an object
/// that refers to the bytes of its base. When `base` is itself a slice, the new slice refers to that
/// slice's base instead, so a slice's base is never a slice. `base` is rooted across the allocation, and
/// the bytes of a copy are read before it. A GC point.
inline HPointer makeByteBufferSlice(HPointer base, u32 offset, u32 length) {
    auto& allocator = Allocator::instance();
    if (length == 0) return emptyBytes();

    void* base_obj = allocator.resolve(base);
    if (base_obj) {
        Header* h = static_cast<Header*>(base_obj);
        if (h->tag == Tag_ByteBufferSlice) {
            ElmByteBufferSlice* inner = static_cast<ElmByteBufferSlice*>(base_obj);
            base = inner->base;
            offset += inner->offset;
        }
    }

    // The bytes are copied to the C++ stack first because allocByteBuffer copies only after it allocates,
    // and the source is not rooted (Pattern 3).
    if (length < MAKE_BYTEBUFFER_SLICE_MIN_LEN) {
        void* obj = allocator.resolve(base);
        const u8* src = flatBytesView(obj).data;
        u8 tmp[MAKE_BYTEBUFFER_SLICE_MIN_LEN];
        std::memcpy(tmp, src + offset, length);
        return allocByteBuffer(tmp, length);
    }

    size_t total_size = sizeof(ElmByteBufferSlice);
    total_size = (total_size + 7) & ~7;

    uint64_t roots[1];
    std::memcpy(&roots[0], &base, sizeof(base));
    ElmByteBufferSlice* slc = static_cast<ElmByteBufferSlice*>(
        eco_alloc_with_roots(Tag_ByteBufferSlice, total_size, roots, 1, 0x1));
    std::memcpy(&base, &roots[0], sizeof(base));
    slc->header.size = length;
    slc->base = base;
    slc->offset = offset;
    slc->_padding = 0;
    return allocator.wrap(slc);
}

/// The UTF-16 units of a String held in one piece, as a pointer and a length.
///
/// A view does not own its units. For a large String `chars` points into the pinned body; for a leaf it
/// points into the object and is stale after the next allocation on this thread, which may move it.
struct U16View {
    const u16* chars;
    u32 length;
};
/// Returns a view of the units of `obj`, which must be a `Tag_String` leaf or a `Tag_LargeStringHeader`
/// (asserted); slices, ropes and the UTF-8 forms are read through `StringOps`. The length is always the
/// outer object's `header.size`.
inline U16View flatStringView(void* obj) {
    Header* hdr = static_cast<Header*>(obj);
    assert((hdr->tag == Tag_String || hdr->tag == Tag_LargeStringHeader) &&
           "flatStringView requires a Tag_String leaf or a Tag_LargeStringHeader");
    return U16View{flatStringChars(obj), hdr->size};
}

/// Returns whether the heap object `obj` is a Bytes value in any of its three forms: `Tag_ByteBuffer`,
/// `Tag_LargeByteHeader` or `Tag_ByteBufferSlice`.
inline bool isByteBuffer(void* obj) {
    Tag t = getTag(obj);
    return t == Tag_ByteBuffer || t == Tag_LargeByteHeader ||
           t == Tag_ByteBufferSlice;
}

/// Returns whether the heap object `obj` is a Bytes slice.
inline bool isByteBufferSlice(void* obj) {
    return getTag(obj) == Tag_ByteBufferSlice;
}

/// Returns whether the heap object `obj` is an array.
inline bool isArray(void* obj) {
    return getTag(obj) == Tag_Array;
}

} // namespace alloc
} // namespace Elm

#endif // ECO_HEAP_HELPERS_H
