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
 *   - alloc::listFromUnboxables   (input: std::vector<pair<Unboxable,bool>>)
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
#include "RootSet.hpp"
#include "RuntimeExports.h"
#include <algorithm>
#include <cstring>
#include <string>
#include <vector>
#include <initializer_list>

namespace Elm {

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
    // Each pointer is registered as a 1-element stack root range.
    StackRootGuard(HPointer* a) {
        auto& rs = Allocator::instance().getRootSet();
        savedPoint_ = rs.stackRangePoint();
        rs.pushStackRootRange(a, 1, 1);
    }
    StackRootGuard(HPointer* a, HPointer* b) {
        auto& rs = Allocator::instance().getRootSet();
        savedPoint_ = rs.stackRangePoint();
        rs.pushStackRootRange(a, 1, 1);
        rs.pushStackRootRange(b, 1, 1);
    }
    StackRootGuard(HPointer* a, HPointer* b, HPointer* c) {
        auto& rs = Allocator::instance().getRootSet();
        savedPoint_ = rs.stackRangePoint();
        rs.pushStackRootRange(a, 1, 1);
        rs.pushStackRootRange(b, 1, 1);
        rs.pushStackRootRange(c, 1, 1);
    }
    StackRootGuard(HPointer* a, HPointer* b, HPointer* c, HPointer* d) {
        auto& rs = Allocator::instance().getRootSet();
        savedPoint_ = rs.stackRangePoint();
        rs.pushStackRootRange(a, 1, 1);
        rs.pushStackRootRange(b, 1, 1);
        rs.pushStackRootRange(c, 1, 1);
        rs.pushStackRootRange(d, 1, 1);
    }
    StackRootGuard(std::initializer_list<HPointer*> roots) {
        auto& rs = Allocator::instance().getRootSet();
        savedPoint_ = rs.stackRangePoint();
        for (HPointer* r : roots) {
            if (r != nullptr) rs.pushStackRootRange(r, 1, 1);
        }
    }
    ~StackRootGuard() {
        Allocator::instance().getRootSet().restoreStackRangePoint(savedPoint_);
    }

    StackRootGuard(const StackRootGuard&) = delete;
    StackRootGuard& operator=(const StackRootGuard&) = delete;

private:
    size_t savedPoint_;
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
 * Returns an HPointer representing the Nil constant (empty list).
 */
inline HPointer listNil() {
    HPointer ptr;
    ptr.ptr = 0;
    ptr.constant = Const_Nil + 1;  // +1 because 0 means "real pointer"
    ptr.padding = 0;
    return ptr;
}

/**
 * Returns an HPointer representing the Unit constant ().
 */
inline HPointer unit() {
    HPointer ptr;
    ptr.ptr = 0;
    ptr.constant = Const_Unit + 1;
    ptr.padding = 0;
    return ptr;
}

/**
 * Returns an HPointer representing the True boolean.
 */
inline HPointer elmTrue() {
    HPointer ptr;
    ptr.ptr = 0;
    ptr.constant = Const_True + 1;
    ptr.padding = 0;
    return ptr;
}

/**
 * Returns an HPointer representing the False boolean.
 */
inline HPointer elmFalse() {
    HPointer ptr;
    ptr.ptr = 0;
    ptr.constant = Const_False + 1;
    ptr.padding = 0;
    return ptr;
}

/**
 * Returns an HPointer representing Nothing (Maybe).
 */
inline HPointer nothing() {
    HPointer ptr;
    ptr.ptr = 0;
    ptr.constant = Const_Nothing + 1;
    ptr.padding = 0;
    return ptr;
}

/**
 * Returns an HPointer representing the empty string.
 */
inline HPointer emptyString() {
    HPointer ptr;
    ptr.ptr = 0;
    ptr.constant = Const_EmptyString + 1;
    ptr.padding = 0;
    return ptr;
}

/**
 * Returns an HPointer representing an empty record {}.
 */
inline HPointer emptyRecord() {
    HPointer ptr;
    ptr.ptr = 0;
    ptr.constant = Const_EmptyRec + 1;
    ptr.padding = 0;
    return ptr;
}

/**
 * Checks if an HPointer is an embedded constant.
 */
inline bool isConstant(HPointer ptr) {
    return ptr.constant != 0;
}

/**
 * Returns true if pointer represents Nil (empty list).
 */
inline bool isNil(HPointer ptr) {
    return ptr.constant == Const_Nil + 1;
}

inline bool isEmptyString(HPointer ptr) {
    return ptr.constant == Const_EmptyString + 1;
}

/// Returns true if the HPointer is any embedded constant (constant field 1-7).
inline bool isEmbeddedConstant(HPointer ptr) {
    return ptr.constant != 0;
}

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
        LargeStringHeader* h = static_cast<LargeStringHeader*>(str);
        void* body = Allocator::instance().resolve(h->body);
        assert(body && "Tag_LargeStringHeader body resolved to null");
        ElmString* leaf = static_cast<ElmString*>(body);
        return leaf->chars;
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

/**
 * Builds a list from a vector of boxed HPointers.
 * All elements are treated as boxed pointers.
 *
 * @param elements Vector of HPointers (first element becomes head).
 * @return HPointer to the list head (or Nil if empty).
 */
inline HPointer listFromPointers(const std::vector<HPointer>& elements) {
    // Copy elements into a local buffer and root them all (and the result
    // accumulator) across the cons() calls, since each cons may GC.
    std::vector<HPointer> rooted = elements;
    HPointer result = listNil();
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    rs.pushStackRootRange(&result, 1, 1);
    for (auto& hp : rooted) rs.pushStackRootRange(&hp, 1, 1);
    for (auto it = rooted.rbegin(); it != rooted.rend(); ++it) {
        result = cons(boxed(*it), result, true);
    }
    rs.restoreStackRangePoint(saved);
    return result;
}

/**
 * Builds a list from a vector of unboxed integers.
 *
 * @param elements Vector of i64 values.
 * @return HPointer to the list head (or Nil if empty).
 */
inline HPointer listFromInts(const std::vector<i64>& elements) {
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
inline HPointer listFromUnboxables(
        std::vector<std::pair<Unboxable, bool>>& elems,
        HPointer tail = listNil(),
        bool reversed = false) {
    if (elems.empty()) return tail;

    HPointer result = tail;
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();

    rs.pushStackRootRange(&result, 1, 1);
    for (auto& [val, is_boxed] : elems) {
        if (is_boxed) rs.pushStackRootRange(&val.p, 1, 1);
    }

    if (reversed) {
        for (auto& [val, is_boxed] : elems) {
            result = cons(val, result, is_boxed);
        }
    } else {
        for (auto it = elems.rbegin(); it != elems.rend(); ++it) {
            result = cons(it->first, result, it->second);
        }
    }

    rs.restoreStackRangePoint(saved);
    return result;
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

/**
 * Allocates a Custom type value (algebraic data type).
 *
 * @param ctor         Constructor index.
 * @param values       Vector of field values.
 * @param unboxed_mask Bitmap indicating which fields are unboxed.
 * @return HPointer to the allocated Custom value.
 */
// `unboxed_mask`: 2-bit-per-slot kind bitmap (up to 24 fields, 48 bits used).
inline HPointer custom(u16 ctor, const std::vector<Unboxable>& values, u64 unboxed_mask) {
    assert((unboxed_mask >> 48) == 0 && "Custom unboxed bitmap overflow (>48 bits)");
    size_t total_size = sizeof(Custom) + values.size() * sizeof(Unboxable);
    total_size = (total_size + 7) & ~7;

    // Pack values into a contiguous uint64_t buffer for the helper. Build
    // an HPointer mask that mirrors `unboxed_mask` but with one bit per
    // slot (boxed → 1, unboxed → 0). The helper roots only on slow path.
    std::vector<uint64_t> roots(values.size());
    uint64_t hptr_mask = 0;
    for (size_t i = 0; i < values.size(); ++i) {
        std::memcpy(&roots[i], &values[i], sizeof(uint64_t));
        if (fieldKind(unboxed_mask, i) == 0 && i < 64) {
            hptr_mask |= (uint64_t{1} << i);
        }
    }

    Custom* obj = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, total_size,
                             roots.empty() ? nullptr : roots.data(),
                             static_cast<uint32_t>(values.size()),
                             hptr_mask));
    obj->ctor = ctor;
    obj->unboxed = unboxed_mask;
    for (size_t i = 0; i < values.size(); ++i) {
        std::memcpy(&obj->values[i], &roots[i], sizeof(Unboxable));
    }
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
 * @param values       Vector of field values (in canonical field order).
 * @param unboxed_mask Bitmap indicating which fields are unboxed.
 * @return HPointer to the allocated Record.
 */
// `unboxed_mask`: 2-bit-per-slot kind bitmap (up to 32 fields, 64 bits used).
inline HPointer record(const std::vector<Unboxable>& values, u64 unboxed_mask) {
    if (values.empty()) {
        return emptyRecord();
    }

    size_t total_size = sizeof(Record) + values.size() * sizeof(Unboxable);
    total_size = (total_size + 7) & ~7;

    // Same packing strategy as custom() above.
    std::vector<uint64_t> roots(values.size());
    uint64_t hptr_mask = 0;
    for (size_t i = 0; i < values.size(); ++i) {
        std::memcpy(&roots[i], &values[i], sizeof(uint64_t));
        if (fieldKind(unboxed_mask, i) == 0 && i < 64) {
            hptr_mask |= (uint64_t{1} << i);
        }
    }

    Record* obj = static_cast<Record*>(
        eco_alloc_with_roots(Tag_Record, total_size, roots.data(),
                             static_cast<uint32_t>(values.size()), hptr_mask));
    obj->unboxed = unboxed_mask;
    for (size_t i = 0; i < values.size(); ++i) {
        std::memcpy(&obj->values[i], &roots[i], sizeof(Unboxable));
    }
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
 */
inline HPointer allocByteBuffer(const u8* data, size_t length) {
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
 * Allocates a zero-initialized ByteBuffer.
 *
 * @param length Number of bytes.
 * @return HPointer to the allocated ByteBuffer.
 */
inline HPointer allocByteBufferZero(size_t length) {
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
 * Returns the length of a ByteBuffer (or Tag_LargeByteHeader). header.size
 * carries the logical length for both forms.
 */
inline size_t byteBufferLength(void* buf) {
    if (!buf) return 0;
    Header* hdr = static_cast<Header*>(buf);
    return hdr->size;
}

/**
 * Returns a pointer to the byte data of a ByteBuffer, resolving through a
 * Tag_LargeByteHeader to its Tag_ByteBuffer body if needed.
 */
inline const u8* byteBufferData(void* buf) {
    Header* hdr = static_cast<Header*>(buf);
    if (hdr->tag == Tag_LargeByteHeader) {
        LargeByteHeader* h = static_cast<LargeByteHeader*>(buf);
        void* body = Allocator::instance().resolve(h->body);
        assert(body && "Tag_LargeByteHeader body resolved to null");
        ByteBuffer* b = static_cast<ByteBuffer*>(body);
        return b->bytes;
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
inline HPointer allocClosure(EvalFunction evaluator, u32 max_values) {
    size_t total_size = sizeof(Closure) + max_values * sizeof(Unboxable);
    total_size = (total_size + 7) & ~7;

    // Captures are filled later via closureCapture; nothing to root here
    // (evaluator is a code pointer).
    Closure* cl = static_cast<Closure*>(
        eco_alloc_with_roots(Tag_Closure, total_size, nullptr, 0, 0));
    cl->header.size = max_values;
    cl->n_values = 0;
    cl->max_values = max_values;
    cl->unboxed = 0;
    cl->evaluator = evaluator;
    return Allocator::instance().wrap(cl);
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
// Only the first 25 typed slots fit in the 50-bit 2-bit-encoded bitfield
// (the upper 2 bits of the 52-bit field are now Closure::flags); later
// slots fall through as boxed with no primitive bit set.
inline bool closureCapture(void* closure, Unboxable value, ParamKind kind) {
    Closure* cl = static_cast<Closure*>(closure);
    if (cl->n_values >= cl->max_values) {
        return false;
    }

    // Per-write stale-pointer tripwire (boxed captures only). Catches the
    // common bug of capturing an HPointer that has gone stale across a
    // prior allocation in the caller.
    if (kind == PK_Boxed) validateNurseryHPtr(value.p);

    size_t idx = cl->n_values;
    cl->values[idx] = value;

    if (kind != PK_Boxed && idx < 25) {
        cl->unboxed = bitmapSetKind(cl->unboxed, static_cast<unsigned>(idx),
                                    static_cast<u64>(kind));
    }

    cl->n_values++;

#if ECO_HEAP_VALIDATE
    // Class 2 — closure capture bitmap consistency: the just-set bit at
    // position `idx` must match `kind`. Catches mis-encoded bitmaps at
    // the construction site.
    if (idx < 26) {
        u64 stored = (cl->unboxed >> (idx * 2)) & 0x3ULL;
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
           t == Tag_LargeStringHeader;
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
 * If `obj` is a Tag_LargeByteHeader (HEAP_026 split form), follow its body
 * HPointer to the underlying Tag_ByteBuffer in old gen and return that.
 * Otherwise return `obj` unchanged. Returns nullptr if `obj` is null or the
 * body resolves to nullptr.
 *
 * Use at every entry point that takes a `void* bytes` from the runtime/JIT
 * boundary (or from `Allocator::resolve`) and then accesses `bb->bytes[]` or
 * does pointer arithmetic on the byte payload. The returned `ByteBuffer*`
 * has the same field layout (`header.size`, `bytes[]`) as a flat ByteBuffer,
 * so downstream code keeps working unchanged.
 */
inline ByteBuffer* resolveByteBufferBody(void* obj) {
    if (!obj) return nullptr;
    Header* hdr = static_cast<Header*>(obj);
    if (hdr->tag == Tag_LargeByteHeader) {
        LargeByteHeader* h = static_cast<LargeByteHeader*>(obj);
        void* body = Allocator::instance().resolve(h->body);
        return static_cast<ByteBuffer*>(body);
    }
    return static_cast<ByteBuffer*>(obj);
}

/**
 * Same idea for strings: resolves through Tag_LargeStringHeader to its
 * Tag_String body so callers can keep using `s->chars[i]` directly.
 *
 * Use this where a hot path bypasses StringOps::charAt for performance and
 * indexes `chars[]` directly. Code that goes through StringOps::charAt /
 * toStdU16String already handles the split form transparently.
 */
inline ElmString* resolveStringBody(void* obj) {
    if (!obj) return nullptr;
    Header* hdr = static_cast<Header*>(obj);
    if (hdr->tag == Tag_LargeStringHeader) {
        LargeStringHeader* h = static_cast<LargeStringHeader*>(obj);
        void* body = Allocator::instance().resolve(h->body);
        return static_cast<ElmString*>(body);
    }
    return static_cast<ElmString*>(obj);
}

/**
 * Returns true if the object is any byte buffer form (Tag_ByteBuffer or
 * Tag_LargeByteHeader).
 */
inline bool isByteBuffer(void* obj) {
    Tag t = getTag(obj);
    return t == Tag_ByteBuffer || t == Tag_LargeByteHeader;
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
