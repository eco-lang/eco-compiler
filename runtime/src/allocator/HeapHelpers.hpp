/**
 * Heap Allocation Helpers for Elm Runtime.
 *
 * This file provides high-level allocation utilities for creating Elm values
 * on the GC-managed heap. These helpers abstract the low-level allocator
 * interface and handle header initialization, unboxing decisions, and
 * pointer wrapping.
 *
 * Usage Pattern:
 *   auto& alloc = Allocator::instance();
 *   HPointer str = alloc::allocString(u"Hello");
 *   HPointer list = alloc::cons(Unboxable{.i = 42}, listNil(), true);
 *
 * Key concepts:
 *   - HPointer: Logical pointer (40-bit offset) for heap references
 *   - Unboxable: Union of i64/f64/char16_t/HPointer for polymorphic storage
 *   - Embedded constants: Nil, True, False, Unit, Nothing stored in HPointer
 *   - Unboxing: Primitives stored directly without heap allocation
 *
 * ============================================================================
 * GC Rooting Patterns (mandatory for all runtime/kernel C++)
 * ============================================================================
 *
 * Pattern 1 — Root across a GC-capable call:
 *   Any helper that stores existing HPointers or boxed Unboxable slots into a
 *   freshly allocated object must either:
 *   (a) call a centralized alloc::* helper whose internal implementation
 *       already roots (cons, tuple2/3, custom, record, just, ok, err,
 *       stackFrame, listFromPointers, arrayFromPointers, allocTask,
 *       allocProcess), or
 *   (b) wrap the boxed locals in a StackRootGuard (<=~8 slots) or
 *       StackRootRangeGuard (contiguous buffer) for the lifetime of the
 *       allocation.
 *   Raw Allocator::allocate calls outside HeapHelpers.hpp are permitted only
 *   when all stored fields are unboxed primitives or newly-initialized memory.
 *
 * Pattern 2 — GC-safe collect-then-build:
 *   Kernel/runtime C++ that constructs an Elm list from a pre-collected batch
 *   of values MUST use one of:
 *   - alloc::listFromPointers     (input: std::vector<HPointer>)
 *   - alloc::listFromUnboxables   (input: std::vector<pair<Unboxable,u8 kind>>)
 *   Hand-rolled loops over alloc::cons across a std::vector are forbidden.
 *
 * Pattern 3 — void* parameters:
 *   Functions receiving void* (resolved heap pointers) must copy any data
 *   they need from the object BEFORE performing any allocation, because GC
 *   can move the object and invalidate the void* pointer.
 */

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

// Chunked-list production switch (plans/chunked-list-representation.md §6).
// Set ONCE at program start by eco_enable_list_chunks(), which the backend
// injects into @main's entry ONLY for modules compiled with
// config.list.chunks — so kernels produce chunk spines exactly when the
// compiled code's projections are chunk-aware. Defined in RuntimeExports.cpp.
extern "C" bool eco_g_list_chunks;

// Cons-site tally (ECO_CONS_SITES=1 measurement runs; RuntimeExports.cpp).
extern "C" bool eco_g_cons_sites;
extern "C" void eco_cons_site_tally(void *ra);

namespace Elm {

// Forward declaration for the UTF-8 ingestion gate. Defined in StringOps.cpp
// (layering: StringOps.hpp includes THIS header, so it cannot be included from
// here). If `data[0..len)` is all-ASCII and UTF-8 strings are enabled, builds a
// Tag_StringUtf8Leaf (small) or a ByteBuffer + Tag_StringUtf8View (>= LOT) and
// returns true; otherwise leaves *out untouched and returns false. `data` must
// be C-heap memory (not a GC payload) — it is read after allocations.
// See plans/utf8-string-pipeline-wiring.md (W2, BB-1).
namespace StringOps {
bool tryMakeAsciiString(const char* data, size_t len, HPointer* out);
}

// Descriptor for a C++-kernel evaluator (plans/gc-root-registration-cost.md
// Phase 2, risk R6). Compiled code gets its `EvaluatorDesc` emitted as a static
// global beside the wrapper, but a kernel that builds a closure has only a
// function pointer, so the runtime interns one descriptor per
// (fn, stage_arity, result_kind) for the life of the process. Kernel evaluators
// use the all-boxed `void*[]` convention, so `kinds` is 0 and every `sat[]` slot
// is null — such a closure fails the fast-path guard closed and takes exactly
// the path it takes today. Defined in RuntimeExports.cpp.
const EvaluatorDesc* ecoDescForKernelEvaluator(EvalFunction fn,
                                               unsigned stage_arity,
                                               unsigned char result_kind);

// ============================================================================
// GC Stack Root Guard (RAII)
// ============================================================================
//
// Roots one or more HPointer locals on the C++ stack so that they survive any
// allocation that triggers a minor GC. The GC walks `RootSet::getStackRootRanges()`
// and updates the pointed-to HPointer values in place to their post-evacuation
// locations. The destructor restores the prior stack-range point.
//
// Use this around any code path that:
//   1) holds an HPointer in a C++ local that refers to a heap object, AND
//   2) calls into the allocator (or any helper that may transitively allocate),
// then reads/uses that local after the call.
//
// Example:
//   HPointer cb = ...;
//   HPointer t  = ...;
//   {
//       StackRootGuard guard(&cb, &t);
//       Task* obj = allocator.allocate(...);  // GC may run; cb/t are updated.
//       obj->callback = cb;
//       obj->task     = t;
//   }
class StackRootGuard {
public:
    // Each pointer becomes one 8-byte entry on the single-slot shadow stack
    // (plans/gc-root-registration-cost.md §3.3) — it used to be a 24-byte
    // one-element RANGE each, so the four-pointer form wrote 96 bytes to say
    // "four pointers". Both cursors are saved because a guarded scope may also
    // push real ranges (a kernel that builds an args buffer inside one).
    StackRootGuard(HPointer* a) : saved_(ecoRootMark()) {
        ecoRoot1Push(a);
    }
    StackRootGuard(HPointer* a, HPointer* b) : saved_(ecoRootMark()) {
        ecoRoot1Push(a);
        ecoRoot1Push(b);
    }
    StackRootGuard(HPointer* a, HPointer* b, HPointer* c) : saved_(ecoRootMark()) {
        ecoRoot1Push(a);
        ecoRoot1Push(b);
        ecoRoot1Push(c);
    }
    StackRootGuard(HPointer* a, HPointer* b, HPointer* c, HPointer* d)
        : saved_(ecoRootMark()) {
        ecoRoot1Push(a);
        ecoRoot1Push(b);
        ecoRoot1Push(c);
        ecoRoot1Push(d);
    }
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
    EcoRootMark saved_;
};

// RAII wrapper for pushStackRootRange / restoreStackRangePoint.
// Use for contiguous buffers of HPointers (e.g. std::vector<HPointer>).
class StackRootRangeGuard {
public:
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
    size_t saved_;
};

namespace alloc {

// ============================================================================
// Embedded Constants
// ============================================================================

/**
 * Returns the unified empty/nullary constant (word 0x6): ptr_ind set, the empty
 * bit set. Under the merged representation Unit, EmptyRec, Nil, Nothing, and ""
 * all share this one bit pattern (plan D3); the builders below are aliases.
 */
inline HPointer empty() {
    HPointer p{};
    p.ptr_ind = 1;
    p.constant = Const_Empty;
    return p;
}

inline HPointer listNil()     { return empty(); }  // []
inline HPointer unit()        { return empty(); }  // ()
inline HPointer nothing()     { return empty(); }  // Nothing
inline HPointer emptyString() { return empty(); }  // ""
inline HPointer emptyRecord() { return empty(); }  // {}
// Empty Bytes (plans/empty-bytes-embedded-constant.md, HEAP_071): like "", an
// empty ByteBuffer is the merged Empty constant, never an 8-byte header-only
// heap object. Readers see it as (nullptr, 0) via resolveBytesOrNull.
inline HPointer emptyBytes()  { return empty(); }

/**
 * Returns an HPointer representing the True boolean (word 0x5): ptr_ind set,
 * constant bit 0 set so the word's low bit is the i1 value.
 */
inline HPointer elmTrue() {
    HPointer p{};
    p.ptr_ind = 1;
    p.constant = Const_True;
    return p;
}

/**
 * Returns an HPointer representing the False boolean (word 0x4).
 */
inline HPointer elmFalse() {
    HPointer p{};
    p.ptr_ind = 1;
    p.constant = Const_False;
    return p;
}

/**
 * Checks if an HPointer is an embedded constant (not a heap pointer).
 */
inline bool isConstant(HPointer ptr) {
    return ptr.ptr_ind != 0;
}

/**
 * Returns true if pointer represents Nil / any merged empty (empty list, etc.).
 */
inline bool isNil(HPointer ptr) {
    return Elm::isEmptyBits(Elm::hpBits(ptr));
}

inline bool isEmptyString(HPointer ptr) {
    return Elm::isEmptyBits(Elm::hpBits(ptr));
}

/// Returns true if the HPointer is any embedded constant.
inline bool isEmbeddedConstant(HPointer ptr) {
    return ptr.ptr_ind != 0;
}

// ============================================================================
// Semantic HPointer constant predicates (see plan D2/D3)
// ============================================================================
//
// Low-level word/forward helpers (hpBits/hpFromBits/isConstantBits/
// isEmptyBits/encode|decodeForwardPtr) live in Heap.hpp so the GC core can use
// them without depending on this higher-level file. The predicates below add
// the specific-constant and Bool classifications used by the printer, JSON,
// equality, and kernels.
//
// Under the merged representation all five empties share one bit pattern, so the
// specific-empty predicates all collapse to isEmpty; Bool is read from bit 0.
// See plan D3.

// True for the unified empty constant (Unit/EmptyRec/Nil/Nothing/"") — i.e. an
// embedded constant that is not a Bool.
inline bool isEmpty(HPointer p) {
    return Elm::isEmptyBits(Elm::hpBits(p));
}

// Specific-constant predicates (all now the merged empty constant).
inline bool isNothing(HPointer p)   { return isEmpty(p); }
inline bool isUnit(HPointer p)      { return isEmpty(p); }
inline bool isEmptyRec(HPointer p)  { return isEmpty(p); }

// Bool-constant predicates. Bool codes are 0/1 (bit 1 clear); Empty (2) and
// NullCons (3, HEAP_044) both carry bit 1 and are NOT Bools.
inline bool isBoolConst(HPointer p) {
    return p.ptr_ind != 0 && (p.constant & 2u) == 0;
}
inline bool boolValue(HPointer p) { return (p.constant & 1u) != 0; }

/**
 * Per-write stale-pointer tripwire (ECO_HEAP_VALIDATE-gated).
 *
 * Validates an HPointer-encoded value at the moment it's about to be written
 * into a heap field. Routes through `Allocator::validateInNurserySafe`,
 * which calls `debugAssertValidNurseryPointer` for any nursery target,
 * aborting if the pointer resolves into a free (post-swap) region — i.e.
 * the "stale by-value HPointer across an alloc" pattern.
 *
 * Compiles to a no-op outside validator builds: the call sites are spread
 * across every heap-write hot path (eco_store_field, closureCapture,
 * arrayPush, etc.), so an always-on body materially slows the runtime.
 * Enable via -DECO_HEAP_VALIDATE=ON for heap-profile / stress runs.
 */
inline void validateNurseryHPtr(HPointer hp) {
#if ECO_HEAP_VALIDATE
    Allocator::instance().validateInNurserySafe(hp);
#else
    (void)hp;
#endif
}

/// Same as validateNurseryHPtr, taking a uint64_t-encoded HPointer (the form
/// used by closure args, eco_store_field, etc.).
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

/**
 * Allocates a boxed Int on the heap.
 *
 * In most cases, prefer storing ints unboxed in container fields.
 * Only use this when a heap-allocated Int object is required.
 */
inline HPointer allocInt(i64 value) {
    ElmInt* obj = static_cast<ElmInt*>(
        eco_alloc_with_roots(Tag_Int, sizeof(ElmInt), nullptr, 0, 0));
    obj->value = value;
    return Allocator::instance().wrap(obj);
}

/**
 * Allocates a boxed Float on the heap.
 *
 * In most cases, prefer storing floats unboxed in container fields.
 * Only use this when a heap-allocated Float object is required.
 */
inline HPointer allocFloat(f64 value) {
    ElmFloat* obj = static_cast<ElmFloat*>(
        eco_alloc_with_roots(Tag_Float, sizeof(ElmFloat), nullptr, 0, 0));
    obj->value = value;
    return Allocator::instance().wrap(obj);
}

/**
 * Allocates a boxed Char on the heap.
 *
 * In most cases, prefer storing chars unboxed in container fields.
 * Only use this when a heap-allocated Char object is required.
 */
inline HPointer allocChar(u16 value) {
    ElmChar* obj = static_cast<ElmChar*>(
        eco_alloc_with_roots(Tag_Char, sizeof(ElmChar), nullptr, 0, 0));
    obj->value = value;
    return Allocator::instance().wrap(obj);
}

// ============================================================================
// Unboxable Helpers
// ============================================================================

/**
 * Creates an Unboxable containing an unboxed integer.
 */
inline Unboxable unboxedInt(i64 value) {
    Unboxable u;
    u.i = value;
    return u;
}

/**
 * Creates an Unboxable containing an unboxed float.
 */
inline Unboxable unboxedFloat(f64 value) {
    Unboxable u;
    u.f = value;
    return u;
}

/**
 * Creates an Unboxable containing an unboxed char.
 */
inline Unboxable unboxedChar(u16 value) {
    Unboxable u;
    u.c = value;
    return u;
}

/**
 * Creates an Unboxable containing a heap pointer.
 */
inline Unboxable boxed(HPointer ptr) {
    Unboxable u;
    u.p = ptr;
    return u;
}

// ============================================================================
// String Allocation
// ============================================================================

/**
 * Allocates an ElmString from a UTF-16 buffer.
 *
 * @param chars  Pointer to UTF-16 code units.
 * @param length Number of code units.
 * @return HPointer to the allocated string.
 *
 * Returns the empty string constant for zero-length input.
 *
 * GC contract (plans/large-body-gc-trigger.md D5): this call is a GC point -
 * it may run a minor GC, a major GC, or (on the large split path, D4) a
 * minor then a major before it copies. `chars` must therefore not point into
 * the GC heap unless it is a rooted, pinned large body.
 */
inline HPointer allocString(const u16* chars, size_t length) {
    if (length == 0) {
        return emptyString();
    }

    auto& allocator = Allocator::instance();
    size_t data_size = length * sizeof(u16);
    size_t total_size = sizeof(ElmString) + data_size;
    // Round up to 8-byte alignment
    total_size = (total_size + 7) & ~7;

    // Per-thread histogram of fresh-leaf String sizes. Recorded once here
    // (before the large/inline-leaf split) so each call contributes to
    // exactly one bucket regardless of which storage path is taken.
    GC_STATS_STRING_RECORD_ALLOC(total_size);

    // At/above the large-object threshold, route to the split path: small
    // Tag_LargeStringHeader in nursery + pinned Tag_String body in old gen.
    // See HEAP_026.
    if (total_size >= allocator.getLargeObjectThreshold()) {
        return allocator.allocLargeString(chars, length);
    }

    ElmString* str = static_cast<ElmString*>(
        eco_alloc_with_roots(Tag_String, total_size, nullptr, 0, 0));
    str->header.size = static_cast<u32>(length);
    std::memcpy(str->chars, chars, data_size);

    return allocator.wrap(str);
}

/**
 * Result of `allocStringBlank`. The fresh string has been allocated with
 * uninitialized chars[]; the caller is responsible for writing all
 * `length` code units BEFORE any subsequent allocation. After the next
 * allocation in this thread, `chars` may dangle (small-path strings live in
 * the nursery and can be moved by a minor GC); the GC-tracked `hp` remains
 * valid throughout.
 */
struct BlankString {
    HPointer hp;
    u16* chars;
    u32 length;
};

/**
 * Allocates a fresh string of `length` code units with uninitialized
 * chars[]. Returns the GC-tracked handle and a writable pointer.
 *
 * Routes length==0 to the embedded empty-string constant (chars == nullptr
 * in that case; caller must check `length > 0` before writing).
 *
 * Pairs with `StringOps::forEachSegment` / `StringOps::copyInto` to let
 * transformation ops (toUpper, reverse, etc.) write directly into the heap
 * object instead of through a `std::vector<u16>` intermediate buffer.
 *
 * Safety contract: the writable pointer is valid only until the next
 * allocation by this thread. Do not call any allocator function (including
 * implicit allocation via alloc::* helpers) between getting `chars` and
 * finishing the write. For payload sizes that route through the large-object
 * split-header path, the body is pinned in old gen and `chars` remains
 * stable across subsequent allocations — but callers should not depend on
 * that without checking the tag.
 *
 * GC contract (plans/large-body-gc-trigger.md D5): this call is a GC point -
 * it may run a minor GC, a major GC, or (on the large split path, D4) a
 * minor then a major. Any heap pointer the caller holds across it must be
 * rooted; a source it copies from afterwards must not point into the GC heap
 * unless it is a rooted, pinned large body.
 */
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
        // Large path: split-header + pinned body. allocLargeString accepts a
        // nullptr `chars` argument and leaves the body uninitialized
        // (the existing `if (chars && length > 0) memcpy(...)` guard); we then
        // resolve through the header to expose the body's writable chars[].
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

/**
 * Allocates an ElmString from a std::u16string.
 */
inline HPointer allocString(const std::u16string& s) {
    return allocString(reinterpret_cast<const u16*>(s.data()), s.size());
}

/**
 * Allocates an ElmString from a UTF-8 std::string.
 * Converts UTF-8 to UTF-16 internally.
 */
inline HPointer allocStringFromUTF8(const std::string& utf8) {
    if (utf8.empty()) {
        return emptyString();
    }

    // ASCII fast path (HEAP_032): an all-ASCII payload becomes a UTF-8 form
    // (inline leaf, or ByteBuffer + zero-copy view >= LOT) instead of widening
    // to UTF-16. This is the single ingestion chokepoint behind
    // Eco.File.readString, Console, Env, Http, and ports — so they all produce
    // UTF-8 for ASCII with no call-site change, which is what lets the parser
    // scan its own source at 1 byte/char. Non-ASCII / invalid input falls
    // through to the legacy lenient transcode below, byte-for-byte unchanged.
    // See plans/utf8-string-pipeline-wiring.md (W2).
    {
        HPointer asciiOut;
        if (StringOps::tryMakeAsciiString(utf8.data(), utf8.size(), &asciiOut)) {
            return asciiOut;
        }
    }

    // Simple UTF-8 to UTF-16 conversion
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

/**
 * Returns the length (in code units) of any String form (Tag_String,
 * Tag_StringSlice, Tag_StringRope, Tag_LargeStringHeader). header.size
 * carries the logical length for all string forms.
 */
inline size_t stringLength(void* str) {
    if (!str) return 0;
    return static_cast<Header*>(str)->size;
}

/**
 * Returns a pointer to the character data of a flat ElmString leaf, or
 * resolves through a Tag_LargeStringHeader to its Tag_String body. Asserts
 * the object is a flat leaf or split header — slice/rope callers must go
 * through Elm::StringOps::charAt or toStdU16String / ensureFlat instead.
 */
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

/**
 * Allocates a Cons cell for building lists.
 *
 * @param head      The head value (may be boxed or unboxed).
 * @param tail      Pointer to the tail list (or Nil).
 * @param head_is_boxed  True if head contains a heap pointer.
 * @return HPointer to the allocated Cons cell.
 *
 * The unboxed flag is stored in the header for GC scanning.
 */
// `head_kind`: 2-bit slot kind (0=boxed HPointer, 1=Int, 2=Float, 3=Char).
inline HPointer cons(Unboxable head, HPointer tail, u8 head_kind) {
    if (__builtin_expect(eco_g_cons_sites, 0))
        eco_cons_site_tally(__builtin_return_address(0));
    // Pack head + tail as roots; the helper roots only on the slow path.
    uint64_t roots[2] = { static_cast<uint64_t>(head.i), 0 };
    std::memcpy(&roots[1], &tail, sizeof(tail));
    uint64_t mask = (head_kind == 0) ? 0x3 : 0x2;

    Cons* cell = static_cast<Cons*>(
        eco_alloc_with_roots(Tag_Cons, sizeof(Cons), roots, 2, mask));
    cell->header.size = 0;
    cell->header.unboxed = head_kind & 0x3;
    // Read post-GC field values back from roots[].
    cell->head.i = static_cast<i64>(roots[0]);
    std::memcpy(&cell->tail, &roots[1], sizeof(cell->tail));
    return Allocator::instance().wrap(cell);
}

// Boolean-friendly overload: true = boxed (kind 0), false = Int (kind 1).
// Preserved for callers that previously used the bool API and meant Int.
inline HPointer cons(Unboxable head, HPointer tail, bool head_is_boxed) {
    return cons(head, tail, static_cast<u8>(head_is_boxed ? 0 : 1));
}

// ============================================================================
// Chunked-list allocation (plans/chunked-list-representation.md §6 L1.2).
//
// Hybrid spines: `::` stays a Cons cell; chunk views/backings are ADDITIONAL
// spine forms that bulk builders produce. v1 chunks are built whole and are
// IMMUTABLE once observable (hd == 0 always; §10 slack fill deferred).
//
// Construction discipline (GC safety): allocate the backing FIRST, fill every
// live slot, then allocate the view. For boxed element kinds the backing's
// slots are ZEROED at allocation, so a GC between backing allocation and the
// fill scans null HPointers (skipped) rather than garbage. Callers that fill
// across allocation points must root the backing (StackRootGuard or builder
// bit) exactly like any fresh object.
// ============================================================================

/**
 * Allocates a Tag_ListBacking with `capacity` element slots of uniform
 * 2-bit kind `elem_kind` (0=boxed HPointer, 1=Int, 2=Float, 3=Char).
 * Boxed-kind slots are zero-initialized; scalar kinds are left raw (they
 * are never traced). hd = 0.
 */
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

/**
 * Allocates a Tag_ConsChunk view over `backing`. `len` is the TOTAL logical
 * length of the resulting list (elements in this chunk's run plus everything
 * in `next`). `elem_kind` mirrors the backing's uniform kind. `backing` and
 * `next` are rooted across the allocation.
 */
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

/**
 * Logical tail of a non-empty hybrid list node. For a Cons cell this is the
 * stored tail (no allocation). For a chunk view whose run has more than one
 * element it MATERIALIZES the successor view {backing, offset+1, len-1,
 * next} — the plan's allocating-tail (§2.3(b)); with one element left it is
 * `next` directly. All needed fields are copied by value before the
 * allocation and consChunkView roots its HPointer arguments, so the call is
 * GC-safe without extra rooting.
 */
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

/**
 * Allocation-TOLERANT forward cursor over a hybrid list spine. Holds only a
 * rooted spine-node HPointer plus an index, and re-resolves on every read
 * and advance, so user code (predicates, mappers) may allocate and trigger
 * GC between reads (the kernelListMapN stale-cursor lesson baked into the
 * type). Usage:
 *
 *     alloc::RootedListCursor c(list);
 *     Unboxable head; u8 kind;
 *     while (c.read(head, kind)) {
 *         // ... call user code; may GC. Root `head.p` if kind == 0 and the
 *         // call can allocate before using it.
 *         c.advance();
 *     }
 */
struct RootedListCursor {
    HPointer node;  // Current spine node (a list value; Nil when finished).
    u32 idx;        // Index within the current view's run.
    Allocator* alloc_;  // Hoisted singleton (stable address across GC).
    Elm::StackRootGuard guard;

    explicit RootedListCursor(HPointer list)
        : node(list), idx(0), alloc_(&Allocator::instance()), guard(&node) {}

    // Fetch the current element (fresh resolve). Returns false at list end.
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

    // Step past the element the last read() returned (fresh resolve).
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

/**
 * Non-allocating forward cursor over a hybrid list spine (cells + chunk
 * views). GC DISCIPLINE: the cursor caches raw interior state that is
 * invalidated by ANY allocation (objects move); after an allocation the
 * caller must re-create the cursor from a rooted list HPointer and re-skip,
 * or better, snapshot what it needs before allocating (the kernelListMapN
 * stale-cursor lesson). Suitable as-is for the read-only walkers
 * (eq/compare/toString/length) which never allocate mid-walk. For walks
 * that allocate, use RootedListCursor above.
 */
struct ListCursor {
    Allocator* alloc_;  // Hoisted singleton (walks are non-allocating).
    HPointer rest;      // Un-entered part of the spine (list value; Nil at end).
    ListBacking* lb;    // Current chunk's backing (null when in a cell / done).
    u32 idx;            // Current index into lb->elems.
    u32 chunkEnd;       // One past the last live index of the current run.
    Unboxable cellHead; // Current element when walking a Cons cell.
    u8 kind;            // 2-bit element kind of the CURRENT element.
    bool inCell;        // True when current element came from a Cons cell.
    bool done_;

    explicit ListCursor(HPointer list) : alloc_(&Allocator::instance()) {
        reset(list);
    }

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

    bool done() const { return done_; }

    // Current element (valid when !done()).
    Unboxable current() const { return inCell ? cellHead : lb->elems[idx]; }
    u8 currentKind() const { return kind; }

    // Advance to the next element.
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
    // Enter the node `rest` points at (following the spine until an element
    // is found or the list ends).
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
                    // Degenerate empty run (should not be constructed); skip.
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
            // Not a list node: treat as end (mirrors existing walkers'
            // defensive `tag != Tag_Cons` breaks).
            done_ = true;
            return;
        }
    }
};


/**
 * Builds a list from a vector of (Unboxable, is_boxed) pairs with proper
 * GC rooting. All boxed entries are registered as stack roots for the
 * duration of the build phase, so a minor GC triggered by any cons()
 * call updates them in place.
 *
 * @param elems    Mutable ref to (value, is_boxed) pairs. Boxed entries
 *                 may be updated in-place by GC. Must not be resized
 *                 during the call (addresses registered as roots).
 * @param tail     Initial tail for the list (default: Nil).
 * @param reversed If true, iterate forward (producing a reversed list).
 */
// Logical length of a list value (O(spine-nodes): a chunk view completes in
// O(1) via its `len`). Non-allocating.
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
// Chunk chains (plan §6 L2): over-cap batches split across linked backings
// ============================================================================

// Largest element count whose backing stays strictly below the large-object
// threshold — the §2.2 nursery-born invariant every chain link preserves (an
// over-LOT backing would land in pinned old gen and hold unrecorded
// old→young edges once filled with nursery pointers).
inline u32 listBackingMaxElems() {
    return static_cast<u32>(
        (Allocator::instance().getLargeObjectThreshold() - 1
         - sizeof(ListBacking)) / sizeof(Unboxable));
}

// Builds the chunk spine for an n-element batch ending in `next`:
// ⌈n / listBackingMaxElems()⌉ nursery-born backings wrapped in views chained
// tail-first (the tail-most link takes the remainder; earlier links are
// full), each view's len telescoping per the len-consistency invariant.
// Returns the head view. Boxed-kind slots are zero-initialized, so a GC
// during construction scans nulls; callers fill AFTER this returns and must
// not allocate between construction and the end of the fill.
//
// threaded-gc-04 S1: a chunk chain is built as builder objects, which stay in
// the nursery until finishChunkChain. Take the chunk path only when the whole
// chain (backings + views) fits in a quarter of the current nursery; larger
// batches use the cons-cell path, which never needs builders.
inline bool chunkChainFits(u32 n) {
    const size_t links = n / listBackingMaxElems() + 1;
    const size_t bytes = static_cast<size_t>(n) * sizeof(Unboxable) +
                         links * (sizeof(ListBacking) + sizeof(ConsChunk) + 16);
    return bytes * 4 <= Allocator::instance().nurseryCapacityBytes();
}

// (Defined with the other builder helpers below.)
inline void mark_as_builder(Header* h);
inline void clear_builder(Header* h);

// threaded-gc-04 S1 (HEAP_SNAPSHOT_001): every backing AND view is created
// with builder = 1, so a minor GC during the construction neither ages nor
// promotes them (a promoted backing filled afterwards would hold unremembered
// old->young pointers; an aged one would be a write into a survived object).
// Views are builders too because a builder child of a promoted parent is
// forbidden (HEAP_BUILDER_001). The caller MUST call finishChunkChain(head, n)
// after its fill and before the list escapes (HEAP_BUILDER_003).
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

// Ends the construction window listChunkChain opened: clears the builder bit
// of the chain's first ceil(n / listBackingMaxElems()) views and their
// backings (the part listChunkChain built; the `next` tail is untouched).
// Allocation-free.
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

// Sequential logical-order writer over a freshly built chunk chain. Caches
// raw pointers: the caller must not allocate while writing.
struct ListChainWriter {
    Allocator* alloc_;
    ListBacking* lb;
    HPointer nextView;
    u32 idx, run;

    explicit ListChainWriter(HPointer headView)
        : alloc_(&Allocator::instance()), lb(nullptr), nextView(headView),
          idx(0), run(0) {}

    void put(Unboxable v) {
        if (idx == run) {
            ConsChunk* cv =
                static_cast<ConsChunk*>(alloc_->resolve(nextView));
            lb = static_cast<ListBacking*>(alloc_->resolve(cv->backing));
            nextView = cv->next;
            idx = 0;
            run = lb->header.size;
#if P1_CENSUS_COMPILED
            p1::noteWrite(lb, "listChainFill");   // builder: legal (S1)
#endif
        }
        lb->elems[idx++] = v;
    }
};

// Reverse-order writer: fills the last logical slot first. Used by reverse,
// whose source cursor can only walk forward. Resolves the whole chain's
// backings up front (raw pointers — same no-allocation discipline).
/// Backward iterator over a hybrid spine (plan §6 "backward-cursor foldr
/// walks"). The constructor collects the spine NODES front-to-back — one
/// entry per Cons cell or chunk view, so chunk runs collapse to a single
/// entry instead of per-element copies — and prev() then yields elements in
/// REVERSE order, indexing backward through each chunk's run. Allocation-
/// TOLERANT: the caller roots `nodes` (contiguous HPointer storage, stable
/// after construction) and every read re-resolves, so fold callbacks may
/// allocate and trigger GC between reads.
struct ListBackwardCursor {
    std::vector<HPointer> nodes;  // spine nodes, front-to-back
    size_t ni;                    // node being drained (moving toward 0)
    i64 idx;                      // next element index in ni's run, or -1
    Allocator* alloc_;

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

    // Roots the node array with ONE all-boxed record (an all-ones mask covers
    // a range of any length; plans/kernel-root-stack-bounded-rooting.md). Pair
    // with rs.restoreStackRangePoint(save-point taken before this call). The
    // array must not grow after this.
    void rootNodes(RootSet& rs) {
        if (!nodes.empty()) rs.pushStackRootRange(nodes.data(), nodes.size(), ~0ULL);
    }

    // Yields the next element in reverse order; false when exhausted.
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

struct ListChainReverseWriter {
    std::vector<ListBacking*> chunks;
    size_t ci;
    u32 idx;

    ListChainReverseWriter(HPointer headView, u32 n) : ci(0), idx(0) {
        auto& allocator = Allocator::instance();
        u32 seen = 0;
        HPointer v = headView;
        while (seen < n) {
            ConsChunk* cv = static_cast<ConsChunk*>(allocator.resolve(v));
            ListBacking* lb =
                static_cast<ListBacking*>(allocator.resolve(cv->backing));
#if P1_CENSUS_COMPILED
            p1::noteWrite(lb, "listChainFill");   // builder: legal (S1)
#endif
            chunks.push_back(lb);
            seen += lb->header.size;
            v = cv->next;
        }
        ci = chunks.size() - 1;
        idx = chunks[ci]->header.size;
    }

    void put(Unboxable v) {
        if (idx == 0) {
            --ci;
            idx = chunks[ci]->header.size;
        }
        chunks[ci]->elems[--idx] = v;
    }
};

/**
 * Builds a list from a rooted buffer of boxed HPointers (first element becomes
 * head). The buffer is ONE shadow-stack record whatever its length
 * (plans/kernel-root-stack-bounded-rooting.md); elements are re-read from it
 * after each allocation.
 */
inline HPointer listFromPointers(const RootedSlots& rooted) {
    HPointer result = listNil();
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    rs.pushStackRootRange(&result, 1, 1);
    const u32 n = static_cast<u32>(rooted.size());

    // Chunks: one dense chain instead of n cells (String.split parts and
    // the other pointer-list builders). Elements are re-read from the
    // rooted buffer after construction; the fill never allocates.
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

/**
 * Builds a list from a vector of boxed HPointers.
 * All elements are treated as boxed pointers. The pointers must be valid on
 * entry (read since the last possible GC); they are copied into one rooted
 * buffer before anything allocates.
 *
 * @param elements Vector of HPointers (first element becomes head).
 * @return HPointer to the list head (or Nil if empty).
 */
inline HPointer listFromPointers(const std::vector<HPointer>& elements) {
    RootedSlots rooted(elements.size());
    for (HPointer hp : elements) rooted.push(hp);
    return listFromPointers(rooted);
}

/**
 * Builds a list from a vector of unboxed integers.
 *
 * @param elements Vector of i64 values.
 * @return HPointer to the list head (or Nil if empty).
 */
inline HPointer listFromInts(const std::vector<i64>& elements) {
    // Chunks: scalar backings need no rooting discipline at all.
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

/**
 * Builds a list from a vector of unboxed floats.
 *
 * @param elements Vector of f64 values.
 * @return HPointer to the list head (or Nil if empty).
 */
inline HPointer listFromFloats(const std::vector<f64>& elements) {
    HPointer result = listNil();
    for (auto it = elements.rbegin(); it != elements.rend(); ++it) {
        result = cons(unboxedFloat(*it), result, static_cast<u8>(2));
    }
    return result;
}

// A user callback reports only whether its result is a POINTER, never WHICH
// unboxed kind it is, so an unboxed callback result can only be stored as Int
// — the historical behaviour of the `cons(…, bool)` overload. Sound for Int
// and boxed results; a Float- or Char-returning mapper routed through one of
// those paths would be stored at the wrong kind. The LIVE map/indexedMap
// exports do NOT route there (they carry `meta.result_kind` through
// `kernelListMapN`), which is why this is a documented limitation and not a
// live defect. Every path whose element kind IS knowable — anything copying
// or permuting an existing list — passes the real kind instead.
inline u8 kindFromBoxedFlag(bool is_boxed) {
    return is_boxed ? static_cast<u8>(0) : static_cast<u8>(1);
}

// Build a list from (value, KIND) pairs.
//
// The second field is a 2-bit slot kind (0 = boxed pointer, 1 = Int,
// 2 = Float, 3 = Char), NOT a boolean. It used to be `bool is_boxed`, which
// collapsed every unboxed kind to Int: a Float list rebuilt through here came
// back with its f64 bit patterns sitting in Int-kinded slots, so consumers
// reading at the static (Float) kind — arithmetic folds, structural equality —
// silently disagreed with the values `Debug.log` printed from the header.
inline HPointer listFromUnboxables(
        const RootedElems& elems,
        HPointer tail = listNil(),
        bool reversed = false) {
    if (elems.empty()) return tail;

    // `elems` roots its boxed values with ONE record
    // (plans/kernel-root-stack-bounded-rooting.md); `result` is the one other
    // root.
    HPointer result = tail;
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    rs.pushStackRootRange(&result, 1, 1);
    const u32 n = static_cast<u32>(elems.size());

    // Chunked-list fast path (plans/chunked-list-representation.md §6): when
    // the program was compiled chunk-aware, a kind-UNIFORM batch becomes a
    // chunk chain — one dense backing per listBackingMaxElems() run — instead
    // of n cells. Mixed batches fall back to cells. Threshold 4 avoids
    // tiny-chunk overhead. Elements are re-read from the rooted buffer after
    // construction, and the fill itself never allocates.
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

// Vector form: the values must be valid on entry (read since the last possible
// GC); they are copied into one rooted buffer before anything allocates.
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

/**
 * Allocates a Tuple2.
 *
 * @param a           First element.
 * @param b           Second element.
 * @param unboxed_mask Bitmask: bit 0 = a is unboxed, bit 1 = b is unboxed.
 * @return HPointer to the allocated tuple.
 */
// `unboxed_mask`: 2-bit-per-slot kind bitmap (4 bits used for 2 slots).
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

/**
 * Allocates a Tuple3.
 *
 * @param a           First element.
 * @param b           Second element.
 * @param c           Third element.
 * @param unboxed_mask Bitmask: bit 0 = a, bit 1 = b, bit 2 = c is unboxed.
 * @return HPointer to the allocated tuple.
 */
// `unboxed_mask`: 2-bit-per-slot kind bitmap (6 bits used for 3 slots).
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
// Shared body of custom()/record() (layout C, HEAP_019): n fields, kinds from
// kindOf(i) for every slot. Roots the boxed values across the allocation
// (64-slot chunks over 64), then writes the header bitmap, the K ext kind words
// (initHeaderForTag set size = n, unboxed = K and zeroed them) and the values.
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

/**
 * Allocates a Custom type value (algebraic data type).
 *
 * @param ctor   Constructor index.
 * @param values Vector of field values (1..CUSTOM_MAX_FIELDS; aborts past it).
 * @param kinds  One 2-bit kind per field (0 boxed, 1 Int, 2 Float, 3 Char);
 *               fields >= 24 go to the ext kind words (HEAP_019).
 * @return HPointer to the allocated Custom value.
 */
inline HPointer custom(u16 ctor, const std::vector<Unboxable>& values, const std::vector<u8>& kinds) {
    assert(kinds.size() == values.size());
    if (values.empty()) {
        // Single-representation invariant (plans/null-cons-hpointer-embedding.md
        // §2.3, HEAP_044): nullary ctors are embedded HPointer constants, never
        // heap objects — resolveAndCompare/eco.value.eq decide by word
        // (in)equality the moment either side is embedded, so a heap copy here
        // would make equal values compare unequal.
        assert(ctor <= NULL_CONS_MAX && "nullary ctor index exceeds null_cons_idx capacity");
        return hpFromBits(nullConsWordFor(ctor));
    }
    Custom* obj = detail::allocWideContainer<Custom>(
        Tag_Custom, values, [&](uint32_t i) -> uint32_t { return kinds[i] & 3u; });
    obj->ctor = ctor;
    return Allocator::instance().wrap(obj);
}

// u64 overload: `unboxed_mask` is the 2-bit-per-slot header bitmap (slots 0..23,
// 48 bits); slots past it are boxed.
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

/**
 * Allocates a Just value (Maybe with a value).
 *
 * @param value The wrapped value.
 * @param is_boxed True if value is a heap pointer.
 * @return HPointer to the Just value.
 */
// `kind`: 0=boxed, 1=Int, 2=Float, 3=Char.
inline HPointer justKind(Unboxable value, u8 kind) {
    std::vector<Unboxable> vals = {value};
    u64 mask = static_cast<u64>(kind) & 0x3;
    return custom(0, vals, mask);
}

inline HPointer just(Unboxable value, bool is_boxed) {
    return justKind(value, static_cast<u8>(is_boxed ? 0 : 1));
}

/**
 * Allocates an Ok value (Result.Ok).
 *
 * @param value The success value.
 * @param is_boxed True if value is a heap pointer.
 * @return HPointer to the Ok value.
 */
inline HPointer ok(Unboxable value, bool is_boxed) {
    std::vector<Unboxable> vals = {value};
    u64 mask = is_boxed ? 0 : 1;
    return custom(0, vals, mask);  // Ok is ctor 0
}

/**
 * Allocates an Err value (Result.Err).
 *
 * @param value The error value.
 * @param is_boxed True if value is a heap pointer.
 * @return HPointer to the Err value.
 */
inline HPointer err(Unboxable value, bool is_boxed) {
    std::vector<Unboxable> vals = {value};
    u64 mask = is_boxed ? 0 : 1;
    return custom(1, vals, mask);  // Err is ctor 1
}

// ============================================================================
// Record Allocation
// ============================================================================

/**
 * Allocates a fixed-layout Record.
 *
 * @param values Vector of field values (in canonical field order; up to RECORD_MAX_FIELDS).
 * @param kinds  One 2-bit kind per field; fields >= 32 go to the ext kind words (HEAP_019).
 * @return HPointer to the allocated Record.
 */
inline HPointer record(const std::vector<Unboxable>& values, const std::vector<u8>& kinds) {
    assert(kinds.size() == values.size());
    if (values.empty()) {
        return emptyRecord();
    }
    Record* obj = detail::allocWideContainer<Record>(
        Tag_Record, values, [&](uint32_t i) -> uint32_t { return kinds[i] & 3u; });
    return Allocator::instance().wrap(obj);
}

// u64 overload: `unboxed_mask` is the 2-bit-per-slot header bitmap (slots 0..31);
// slots past it are boxed.
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

/**
 * Allocates an immutable ByteBuffer.
 *
 * @param data   Pointer to byte data.
 * @param length Number of bytes.
 * @return HPointer to the allocated ByteBuffer.
 *
 * GC contract (plans/large-body-gc-trigger.md D5): this call is a GC point -
 * it may run a minor GC, a major GC, or (on the large split path, D4) a
 * minor then a major before it copies. `data` must therefore not point into
 * the GC heap unless it is a rooted, pinned large body.
 */
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

/**
 * Result of `allocByteBufferBlank`. Mirrors BlankString: a freshly
 * allocated ByteBuffer with uninitialized `bytes[]`. The caller must
 * write all `length` bytes BEFORE the next allocation in this thread.
 * Sub-LOT bytes pointer dangles after a minor GC; large-path bodies are
 * pinned and remain stable.
 */
struct BlankByteBuffer {
    HPointer hp;
    u8* bytes;
    u32 length;
};

/**
 * Allocates a ByteBuffer of `length` bytes with uninitialized payload,
 * returning the handle plus a writable pointer. Pairs with the same
 * two-pass count→allocate→fill pattern used by allocStringBlank, allowing
 * direct decoders/encoders to bypass an intermediate std::vector copy.
 *
 * Safety contract: do not allocate between getting `bytes` and finishing
 * the write. For payloads routing through the large-object split path
 * the body is pinned in old gen and `bytes` remains stable.
 *
 * GC contract (plans/large-body-gc-trigger.md D5): this call is a GC point -
 * it may run a minor GC, a major GC, or (on the large split path, D4) a
 * minor then a major. Any heap pointer the caller holds across it must be
 * rooted; a source it copies from afterwards must not point into the GC heap
 * unless it is a rooted, pinned large body.
 */
inline BlankByteBuffer allocByteBufferBlank(size_t length) {
    // Empty Bytes is the embedded constant (HEAP_071); nothing to write.
    if (length == 0) return BlankByteBuffer{emptyBytes(), nullptr, 0};
    auto& allocator = Allocator::instance();

    size_t total_size = sizeof(ByteBuffer) + length;
    total_size = (total_size + 7) & ~7;

    // Mirror allocByteBuffer's split: only payloads at/over the LOT take
    // the split-header path.
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

/**
 * Allocates a zero-initialized ByteBuffer.
 *
 * @param length Number of bytes.
 * @return HPointer to the allocated ByteBuffer.
 */
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

/**
 * Returns the length of a ByteBuffer in any form (Tag_ByteBuffer,
 * Tag_LargeByteHeader, Tag_ByteBufferSlice). header.size carries the
 * logical length for all three.
 */
inline size_t byteBufferLength(void* buf) {
    if (!buf) return 0;
    Header* hdr = static_cast<Header*>(buf);
    return hdr->size;
}

/**
 * Returns a pointer to the byte data of a ByteBuffer, resolving through a
 * Tag_LargeByteHeader to its Tag_ByteBuffer body or through a
 * Tag_ByteBufferSlice to base + offset.
 */
inline const u8* byteBufferData(void* buf) {
    if (!buf) return nullptr;
    Header* hdr = static_cast<Header*>(buf);
    if (hdr->tag == Tag_ByteBufferSlice) {
        ElmByteBufferSlice* slc = static_cast<ElmByteBufferSlice*>(buf);
        void* base = Allocator::instance().resolve(slc->base);
        // The base is a flat Tag_ByteBuffer or a Tag_LargeByteHeader.
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

/**
 * Allocates a mutable Array with specified capacity.
 *
 * @param capacity  Maximum number of elements.
 * @return HPointer to the allocated Array (length starts at 0).
 */
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
// Builder Bit Helpers (HEAP_BUILDER_001..003)
// ============================================================================
//
// Builder objects are pinned to the nursery while a runtime kernel is mutating
// them in place across closure calls. The bit gates promotion in
// NurserySpace::evacuate so a half-built container can never become an old-gen
// parent of nursery-resident children.

/**
 * Sets `builder = 1` and resets `age = 0` to maintain HEAP_BUILDER_002. Both
 * writes are required: the invariant `builder ⇒ age == 0` is checked in
 * minor-GC evacuation under ECO_HEAP_VALIDATE.
 */
inline void mark_as_builder(Header* h) {
    h->builder = 1;
    h->age = 0;
}

/**
 * Clears the builder bit. After this returns, the cell ages from 0 like a
 * fresh allocation and may promote on a subsequent minor GC. Under
 * ECO_HEAP_VALIDATE, asserts the cell is still in the nursery — clearing
 * builder on an old-gen object would mean HEAP_BUILDER_001 was already
 * violated, but the assert documents the intent.
 */
inline void clear_builder(Header* h) {
#if ECO_HEAP_VALIDATE
    // threaded-gc-04b HEAP_062: or a young large object (a large builder).
    assert((Allocator::instance().isInNursery(h) ||
            Allocator::instance().getCurrentThreadHeap()->getOldGen().isYoungLarge(h)) &&
           "HEAP_BUILDER_001: clear_builder on non-nursery object");
#endif
    h->builder = 0;
}

/**
 * RAII guard that marks an object as a builder on construction and clears
 * the bit on scope exit. Use this for the duration of a kernel's mutation
 * window so every exit path (return, exception, early break) clears the
 * bit before the result becomes reachable to user Elm code (HEAP_BUILDER_003).
 *
 * Holds an `HPointer*` (not a raw object pointer) so it can re-resolve the
 * cell on destruction — the underlying object may have been relocated by a
 * minor GC during the guarded scope.
 */
class BuilderGuard {
public:
    explicit BuilderGuard(HPointer* hp) : hp_(hp), active_(true) {
        void* obj = Allocator::instance().resolve(*hp_);
        assert(obj && "BuilderGuard: object must resolve at construction");
        mark_as_builder(static_cast<Header*>(obj));
    }

    BuilderGuard(const BuilderGuard&) = delete;
    BuilderGuard& operator=(const BuilderGuard&) = delete;

    /// Manually clear the builder bit before the guard goes out of scope.
    /// Useful when a kernel publishes the result on the last iteration and
    /// wants to drop builder semantics before the function returns.
    void clear() {
        if (!active_) return;
        active_ = false;
        void* obj = Allocator::instance().resolve(*hp_);
        if (obj) {
            clear_builder(static_cast<Header*>(obj));
        }
    }

    ~BuilderGuard() { clear(); }

private:
    HPointer* hp_;
    bool active_;
};

/**
 * Allocates a mutable Array with specified capacity AND sets the builder
 * bit so the GC will not promote the array while it is being mutated in
 * place. Caller must clear the bit (via BuilderGuard or clear_builder)
 * before the array becomes reachable to user code (HEAP_BUILDER_003).
 *
 * Use this for the "alloc + mutate across closure calls" pattern. One-shot
 * allocators that fill the array atomically before any GC point can stay
 * on `allocArray`.
 */
inline HPointer allocArrayBuilder(size_t capacity) {
    HPointer hp = allocArray(capacity);
    void* obj = Allocator::instance().resolve(hp);
    assert(obj && "allocArrayBuilder: array allocation resolved to null");
    mark_as_builder(static_cast<Header*>(obj));
    return hp;
}

/**
 * Allocates an Array and initializes it with boxed pointers.
 *
 * @param elements Vector of HPointers.
 * @return HPointer to the allocated Array.
 */
inline HPointer arrayFromPointers(const std::vector<HPointer>& elements) {
    size_t capacity = elements.size();
    size_t total_size = sizeof(ElmArray) + capacity * sizeof(Unboxable);
    total_size = (total_size + 7) & ~7;

    // Element count can exceed 64; the eco_alloc_with_roots single-call
    // hptr_mask only covers 64 slots. Keep an outer batch rooting via
    // StackRootRangeGuard around the whole construction so the inner
    // helper's slow-path rooting is redundant-but-harmless.
    std::vector<HPointer> rooted = elements;
    Elm::StackRootRangeGuard guard(rooted.data(), rooted.size(), ~uint64_t{0});

    ElmArray* arr = static_cast<ElmArray*>(
        eco_alloc_with_roots(Tag_Array, total_size, nullptr, 0, 0));
    arr->header.size = static_cast<u32>(capacity);
    arr->length = static_cast<u32>(rooted.size());
    arr->padding = 0;
    arr->header.unboxed = 0;  // All elements are boxed pointers
    for (size_t i = 0; i < rooted.size(); ++i) {
        arr->elements[i].p = rooted[i];
    }
#if ECO_HEAP_VALIDATE
    // All-boxed: validate every element write.
    for (size_t i = 0; i < rooted.size(); ++i)
        validateNurseryHPtr(arr->elements[i].p);
#endif
    return Allocator::instance().wrap(arr);
}

/**
 * Allocates an Array and initializes it with unboxed integers.
 *
 * @param elements Vector of i64 values.
 * @return HPointer to the allocated Array.
 */
inline HPointer arrayFromInts(const std::vector<i64>& elements) {
    size_t capacity = elements.size();
    size_t total_size = sizeof(ElmArray) + capacity * sizeof(Unboxable);
    total_size = (total_size + 7) & ~7;

    ElmArray* arr = static_cast<ElmArray*>(
        eco_alloc_with_roots(Tag_Array, total_size, nullptr, 0, 0));
    arr->header.size = static_cast<u32>(capacity);
    arr->length = static_cast<u32>(elements.size());
    arr->header.unboxed = 1;  // Uniform kind: Int (kind 01)
    arr->padding = 0;
    for (size_t i = 0; i < elements.size(); ++i) {
        arr->elements[i].i = elements[i];
    }
    return Allocator::instance().wrap(arr);
}

/**
 * Returns the length of an Array.
 */
inline size_t arrayLength(void* arr) {
    ElmArray* a = static_cast<ElmArray*>(arr);
    return a->length;
}

/**
 * Returns the capacity of an Array.
 */
inline size_t arrayCapacity(void* arr) {
    ElmArray* a = static_cast<ElmArray*>(arr);
    return a->header.size;
}

/**
 * Pushes a value onto an Array (must have capacity).
 *
 * Arrays are uniform: all elements must be either boxed or unboxed.
 * The first push sets the unboxed flag; subsequent pushes must be consistent.
 *
 * @param arr      Pointer to the Array.
 * @param value    Value to push.
 * @param is_boxed True if value is a heap pointer.
 * @return True if successful, false if at capacity.
 */
inline bool arrayPush(void* arr, Unboxable value, bool is_boxed) {
    ElmArray* a = static_cast<ElmArray*>(arr);
    if (a->length >= a->header.size) {
        return false;  // At capacity
    }
#if P1_CENSUS_COMPILED
    p1::noteWrite(arr, "arrayPush");   // threaded-gc-04 detector W
#endif

    // Per-write stale-pointer tripwire (boxed slots only).
    if (is_boxed) validateNurseryHPtr(value.p);

    size_t idx = a->length;
    a->elements[idx] = value;

    // Set uniform kind on first push (0=boxed, 1=Int for legacy callers).
    if (idx == 0) {
        a->header.unboxed = is_boxed ? 0 : 1;
    }
    // Note: subsequent pushes must be consistent (not enforced here)

    a->length++;
    return true;
}

// Variant of arrayPush that takes an explicit kind (0=boxed, 1=Int, 2=Float, 3=Char).
inline bool arrayPushKind(void* arr, Unboxable value, u8 kind) {
    ElmArray* a = static_cast<ElmArray*>(arr);
    if (a->length >= a->header.size) return false;
#if P1_CENSUS_COMPILED
    p1::noteWrite(arr, "arrayPushKind");   // threaded-gc-04 detector W
#endif

    // Per-write stale-pointer tripwire (boxed slots only).
    if ((kind & 0x3) == 0) validateNurseryHPtr(value.p);

    size_t idx = a->length;
    a->elements[idx] = value;
    if (idx == 0) {
        a->header.unboxed = kind & 0x3;
    }
    a->length++;
    return true;
}

/**
 * Gets an element from an Array.
 *
 * @param arr   Pointer to the Array.
 * @param index Index of element to get.
 * @return The element value (undefined if index >= length).
 */
inline Unboxable arrayGet(void* arr, size_t index) {
    ElmArray* a = static_cast<ElmArray*>(arr);
    return a->elements[index];
}

/**
 * Checks if an array's elements are unboxed.
 *
 * Arrays are uniform: either ALL elements are unboxed or ALL are boxed.
 *
 * @param arr   Pointer to the Array.
 * @return True if all elements are unboxed primitives, false if all are boxed pointers.
 */
inline bool arrayIsUnboxed(void* arr) {
    ElmArray* a = static_cast<ElmArray*>(arr);
    return (a->header.unboxed & 0x3) != 0;
}

/**
 * Returns the uniform-kind code for an Array's elements (0=boxed, 1=Int, 2=Float, 3=Char).
 */
inline u32 arrayElementKind(void* arr) {
    ElmArray* a = static_cast<ElmArray*>(arr);
    return a->header.unboxed & 0x3;
}

// ============================================================================
// Closure Allocation
// ============================================================================

/**
 * Allocates a Closure (function value).
 *
 * @param evaluator   Function pointer to the evaluator.
 * @param max_values  Maximum number of captured values.
 * @return HPointer to the allocated Closure.
 */
/**
 * Allocates a Closure (function value) with an explicit `result_kind`.
 *
 * `result_kind` records the C-ABI return type of `evaluator` (ParamKind:
 * 0 = PK_Boxed / HPtr, 1 = PK_Int, 2 = PK_Float, 3 = PK_Char). Stored
 * on the closure header so every closure-invocation entry point can
 * cast `closure->evaluator` correctly without per-call-site plumbing.
 */
inline HPointer allocClosureK(EvalFunction evaluator, u32 max_values,
                               u8 result_kind) {
    if (max_values > CLOSURE_MAX_ARITY) {
        std::fprintf(stderr, "[eco] FATAL: allocClosureK: closure arity %u exceeds %u\n",
                     max_values, CLOSURE_MAX_ARITY);
        std::abort();
    }
    // Closure layout v2 (HEAP_078): max_values value slots, then
    // K = extWords(max_values, CLOSURE_HDR_SLOTS) ext kind words.
    const u32 K = extWords(max_values, CLOSURE_HDR_SLOTS);
    size_t total_size = sizeof(Closure) + (static_cast<size_t>(max_values) + K) * sizeof(Unboxable);

    // Captures are filled later via closureCapture; nothing to root here
    // (evaluator is a code pointer).
    Closure* cl = static_cast<Closure*>(
        eco_alloc_with_roots(Tag_Closure, total_size, nullptr, 0, 0));
    cl->header.size = max_values + K;
    cl->n_values = 0;
    cl->max_values = max_values;
    cl->result_kind = result_kind & 0x3;
    cl->unboxed = 0;
    cl->evaluator = ecoDescForKernelEvaluator(evaluator, max_values, result_kind);
    // Kernel closure slots >= CLOSURE_HDR_SLOTS are boxed (closureCapture never
    // writes an ext word, HEAP_077): all K words are zero.
    u64* ext = reinterpret_cast<u64*>(&cl->values[max_values]);
    for (u32 j = 0; j < K; ++j) ext[j] = 0;
#if ECO_HEAP_VALIDATE
    assert(cl->evaluator->stage_arity == max_values &&
           "allocClosureK: max_values != evaluator->stage_arity");
#endif
    return Allocator::instance().wrap(cl);
}

inline HPointer allocClosure(EvalFunction evaluator, u32 max_values) {
    return allocClosureK(evaluator, max_values, /*result_kind=*/0);
}

/**
 * Appends a captured value to a Closure.
 *
 * @param closure   Pointer to the Closure.
 * @param value     Value to capture.
 * @param is_boxed  True if value is a heap pointer.
 * @return True if successful, false if at capacity.
 */
// `kind`: 2-bit slot kind. 0 = boxed HPointer, 1 = Int, 2 = Float, 3 = Char.
// Only the first CLOSURE_HDR_SLOTS (20) slots have a kind in the 40-bit
// inline field; closureCapture never writes an ext word, so a typed capture
// past them aborts (B6 / HEAP_077, release builds too) instead of being
// traced as a pointer.
inline bool closureCapture(void* closure, Unboxable value, ParamKind kind) {
    Closure* cl = static_cast<Closure*>(closure);
    if (cl->n_values >= cl->max_values) {
        return false;
    }
#if P1_CENSUS_COMPILED
    p1::noteWrite(closure, "closureCapture");   // threaded-gc-04 detector W
#endif

    // Per-write stale-pointer tripwire (boxed captures only). Catches the
    // common bug of capturing an HPointer that has gone stale across a
    // prior allocation in the caller.
    if (kind == PK_Boxed) validateNurseryHPtr(value.p);

    size_t idx = cl->n_values;
    if (kind != PK_Boxed && idx >= CLOSURE_HDR_SLOTS) {
        // B6 / HEAP_077: kernel closures keep slots past the inline kinds boxed; a typed
        // capture here would be traced as a pointer. Permanent.
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
    // Class 2 — closure capture bitmap consistency: the just-set bit at
    // position `idx` must match `kind`. Catches mis-encoded bitmaps at
    // the construction site. Slots past the inline kinds read boxed
    // (closureSlotKind), and only boxed captures reach them (abort above).
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

// Boolean-friendly overload: true = boxed, false = legacy Int (kind 1).
inline bool closureCapture(void* closure, Unboxable value, bool is_boxed) {
    return closureCapture(closure, value, is_boxed ? PK_Boxed : PK_Int);
}

// Boxes an Unboxable slot back into an HPointer based on its 2-bit kind.
// For kind==0 the value is already an HPointer and returned directly;
// for Int/Float/Char kinds, allocates the appropriate boxed primitive.
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

enum TaskCtor : u16 {
    Task_Succeed  = 0,
    Task_Fail     = 1,
    Task_Binding  = 2,
    Task_AndThen  = 3,
    Task_OnError  = 4,
    Task_Receive  = 5,
};

static constexpr u16 CTOR_StackFrame = 0xFFFE;
static constexpr u16 CTOR_Router     = 0xFFFD;

enum FxBagTag : u16 {
    Fx_Leaf = 0,
    Fx_Node = 1,
    Fx_Map  = 2,
};

// Allocate a Task whose `value` is a boxed HPointer (kind 0).
inline HPointer allocTask(u16 ctor, HPointer value, HPointer callback,
                          HPointer kill, HPointer innerTask) {
    size_t total_size = (sizeof(Task) + 7) & ~7;
    // All four fields are HPointers. Pack them as roots; the helper roots
    // only on slow path. Reading values back out post-call picks up GC
    // relocations.
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

// Allocate a Task whose `value` is an unboxed primitive (kind 1=Int, 2=Float,
// 3=Char). Other fields (callback/kill/innerTask) are always boxed pointers.
inline HPointer allocTaskUnboxed(u16 ctor, Unboxable value, u8 valueKind,
                                 HPointer callback, HPointer kill,
                                 HPointer innerTask) {
    size_t total_size = (sizeof(Task) + 7) & ~7;
    // value is unboxed; only callback/kill/innerTask are HPointers to root.
    // Pack value at slot 0 (mask bit 0 cleared), HPointer fields at 1..3.
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

inline HPointer allocProcess(u16 id, HPointer root, HPointer stack, HPointer mailbox) {
    size_t total_size = (sizeof(Process) + 7) & ~7;
    uint64_t roots[3];
    std::memcpy(&roots[0], &root, 8);
    std::memcpy(&roots[1], &stack, 8);
    std::memcpy(&roots[2], &mailbox, 8);
    Process* p = static_cast<Process*>(
        eco_alloc_with_roots(Tag_Process, total_size, roots, 3, 0x7));
    p->id = id;
    p->padding = 0;
    std::memcpy(&p->root,    &roots[0], 8);
    std::memcpy(&p->stack,   &roots[1], 8);
    std::memcpy(&p->mailbox, &roots[2], 8);
    return Allocator::instance().wrap(p);
}

inline HPointer stackFrame(u64 expectedTag, HPointer callback, HPointer rest) {
    std::vector<Unboxable> fields(3);
    fields[0].i = static_cast<i64>(expectedTag);
    fields[1].p = callback;
    fields[2].p = rest;
    return custom(CTOR_StackFrame, fields, 0x1);  // bit 0 = field 0 is unboxed
}

// ============================================================================
// Type Checking Helpers
// ============================================================================

/**
 * Returns the tag of a heap object.
 */
inline Tag getTag(void* obj) {
    Header* hdr = static_cast<Header*>(obj);
    return static_cast<Tag>(hdr->tag);
}

/**
 * Returns true if the object is a Cons cell.
 */
inline bool isCons(void* obj) {
    return getTag(obj) == Tag_Cons;
}

/**
 * Returns true if the object is any String form
 * (Tag_String / Tag_StringSlice / Tag_StringRope / Tag_LargeStringHeader).
 */
inline bool isString(void* obj) {
    Tag t = getTag(obj);
    return t == Tag_String || t == Tag_StringSlice || t == Tag_StringRope ||
           t == Tag_LargeStringHeader ||
           t == Tag_StringUtf8View || t == Tag_StringUtf8Leaf;
}

/**
 * Returns true iff the object is a flat string leaf (Tag_String) — i.e. has
 * an inline `chars[]` array directly readable. Tag_LargeStringHeader is
 * NOT a leaf in this sense (callers must resolve through `body`); use
 * Tag_LargeStringHeader's body for raw chars[] access.
 */
inline bool isStringLeaf(void* obj) {
    return getTag(obj) == Tag_String;
}


/**
 * Read-only view of a ByteBuffer in any structural form:
 *   - Tag_ByteBuffer        -> data = bb->bytes,            length = bb->header.size
 *   - Tag_LargeByteHeader   -> data = body->bytes,          length = hdr->size
 *   - Tag_ByteBufferSlice   -> data = base.data + slc->offset, length = slc->header.size
 *
 * The returned `data` pointer is valid only until the next allocation
 * by this thread for sub-LOT byte buffers (which can be moved by a minor
 * GC); split-header bodies are pinned in old gen and the pointer is stable.
 * Callers in hot loops must avoid allocating between the view call and the
 * final byte access.
 */
struct ByteBufferView {
    const u8* data;
    size_t length;
};

/**
 * The payload of a flat byte buffer: a Tag_ByteBuffer or a Tag_LargeByteHeader
 * (HEAP_026 split form; plans/large-object-space.md D4: the body is read raw and
 * the length is always the outer header's). Not for slices: use byteBufferView.
 */
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

inline ByteBufferView byteBufferView(void* obj) {
    if (!obj) return ByteBufferView{nullptr, 0};
    Header* hdr = static_cast<Header*>(obj);
    if (hdr->tag == Tag_ByteBufferSlice) {
        ElmByteBufferSlice* slc = static_cast<ElmByteBufferSlice*>(obj);
        void* base = Allocator::instance().resolve(slc->base);
        // Construction collapses slice-of-slice; the base is a flat
        // Tag_ByteBuffer or a Tag_LargeByteHeader (makeByteBufferSlice keeps
        // a large header as the base).
        return ByteBufferView{flatBytesView(base).data + slc->offset, slc->header.size};
    }
    return flatBytesView(obj);
}

/**
 * Constant-safe resolve for a Bytes value. Empty Bytes is the embedded Empty
 * constant (HEAP_071), which Allocator::resolve must never see; it resolves
 * here to nullptr, which byteBufferView / byteBufferLength read as (nullptr, 0).
 */
inline void* resolveBytesOrNull(HPointer hp) {
    if (hp.ptr_ind != 0) return nullptr;
    return Allocator::instance().resolve(hp);
}

/**
 * Allocates a Tag_ByteBufferSlice over `base` for `length` bytes starting
 * at `offset`. Slice-of-slice collapses: if `base` resolves to another
 * Tag_ByteBufferSlice, the resulting slice points at the inner base with
 * `offset + inner.offset`. If `base` is a Tag_LargeByteHeader the slice
 * keeps that as its base — the view layer follows the indirection.
 *
 * Returns the embedded empty-Bytes constant for length==0 (HEAP_071).
 *
 * Threshold: for very small slices (under MAKE_BYTEBUFFER_SLICE_MIN_LEN)
 * the slice header itself wastes more space than a direct copy, so we
 * collapse to a flat ByteBuffer. Tuned to match Tag_StringSlice behaviour.
 */
static constexpr size_t MAKE_BYTEBUFFER_SLICE_MIN_LEN = 32;

inline HPointer makeByteBufferSlice(HPointer base, u32 offset, u32 length) {
    auto& allocator = Allocator::instance();
    if (length == 0) return emptyBytes();

    // Collapse slice-of-slice. Resolve base; if it's another slice,
    // absorb its offset.
    void* base_obj = allocator.resolve(base);
    if (base_obj) {
        Header* h = static_cast<Header*>(base_obj);
        if (h->tag == Tag_ByteBufferSlice) {
            ElmByteBufferSlice* inner = static_cast<ElmByteBufferSlice*>(base_obj);
            base = inner->base;
            offset += inner->offset;
        }
    }

    // Tiny slices: flatten to a copy. Snapshot the payload to the C stack
    // BEFORE allocating (Pattern 3): allocByteBuffer allocates first and
    // memcpys after, so a GC during the alloc could move/reclaim the
    // unrooted source buffer and leave `src->bytes + offset` dangling.
    if (length < MAKE_BYTEBUFFER_SLICE_MIN_LEN) {
        // Re-resolve base post-collapse — possible Tag_LargeByteHeader.
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

/**
 * The units of a flat string: a Tag_String leaf or a Tag_LargeStringHeader
 * (plans/large-object-space.md D4: the body is read raw and the length is
 * always the outer header's). For a hot path that indexes chars directly;
 * slices and ropes go through StringOps (charAt / toStdU16String / ensureFlat).
 */
struct U16View {
    const u16* chars;
    u32 length;
};
inline U16View flatStringView(void* obj) {
    Header* hdr = static_cast<Header*>(obj);
    assert((hdr->tag == Tag_String || hdr->tag == Tag_LargeStringHeader) &&
           "flatStringView requires a Tag_String leaf or a Tag_LargeStringHeader");
    return U16View{flatStringChars(obj), hdr->size};
}

/**
 * Returns true if the object is any byte buffer form (Tag_ByteBuffer,
 * Tag_LargeByteHeader, or Tag_ByteBufferSlice).
 */
inline bool isByteBuffer(void* obj) {
    Tag t = getTag(obj);
    return t == Tag_ByteBuffer || t == Tag_LargeByteHeader ||
           t == Tag_ByteBufferSlice;
}

inline bool isByteBufferSlice(void* obj) {
    return getTag(obj) == Tag_ByteBufferSlice;
}

/**
 * Returns true if the object is an ElmArray.
 */
inline bool isArray(void* obj) {
    return getTag(obj) == Tag_Array;
}

} // namespace alloc
} // namespace Elm

#endif // ECO_HEAP_HELPERS_H
