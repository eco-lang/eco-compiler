/**
 * String Operations for Elm Runtime.
 *
 * This file provides string manipulation utilities that work with the
 * GC-managed heap. Functions operate on ElmString objects and return
 * new strings (Elm strings are immutable).
 *
 * Key operations:
 *   - Concatenation: append, concat, join
 *   - Slicing: slice, left, right, dropLeft, dropRight
 *   - Searching: contains, startsWith, endsWith, indexes
 *   - Transformation: toUpper, toLower, trim, reverse
 *   - Conversion: toInt, toFloat, fromInt, fromFloat
 *   - Character access: uncons, cons, all, any, map, filter, foldl, foldr
 */

#ifndef ECO_STRING_OPS_H
#define ECO_STRING_OPS_H

#include "Allocator.hpp"
#include "HeapHelpers.hpp"
#include <algorithm>
#include <cctype>
#include <charconv>
#include <cmath>
#include <cstdlib>
#include <limits>
#include <sstream>
#include <iomanip>
#include <utility>

namespace Elm {
namespace StringOps {

// ============================================================================
// Tag-Aware Helpers (Phase 1: leaf + slice)
// ============================================================================

/**
 * True if `obj` is a flat string leaf for rope/slice purposes — either a
 * Tag_String (inline chars[]) or a Tag_LargeStringHeader (resolves to a
 * Tag_String body in old gen, conceptually flat).
 * Caller must have already verified `obj` is non-null and a string-like tag.
 */
inline bool isLeaf(void* obj) {
    Tag t = alloc::getTag(obj);
    return t == Tag_String || t == Tag_LargeStringHeader;
}

/**
 * True if `obj` is a structural string slice (Tag_StringSlice).
 */
inline bool isSlice(void* obj) { return alloc::getTag(obj) == Tag_StringSlice; }

/**
 * True if `obj` is a concat-tree rope node (Tag_StringRope).
 */
inline bool isRope(void* obj) { return alloc::getTag(obj) == Tag_StringRope; }

/**
 * Logical UTF-16 length read directly from the header. Works for any
 * string tag (Tag_String / Tag_StringSlice / Tag_StringRope) — header.size
 * is defined to be the logical length for all string forms.
 */
inline u32 rawLen(void* obj) { return static_cast<Header*>(obj)->size; }

/**
 * Tree height of a string. 0 for leaves and slices (slices are flat from a
 * tree-traversal perspective even though they share a buffer); for ropes,
 * stored in the rope header.
 */
inline u32 heightOf(void* obj) {
    Tag t = alloc::getTag(obj);
    if (t == Tag_StringRope) return static_cast<ElmStringRope*>(obj)->height;
    return 0;
}

/**
 * Number of leaves in a string. 1 for leaves; 1 for slices (the slice
 * resolves to a single underlying leaf); for ropes, stored in the header.
 */
inline u32 leafCountOf(void* obj) {
    Tag t = alloc::getTag(obj);
    if (t == Tag_StringRope) return static_cast<ElmStringRope*>(obj)->leafCount;
    return 1;
}

// Rope/slice heuristic thresholds live on HeapConfig (see AllocatorCommon.hpp);
// access them via Allocator::instance().getConfig().{string_flatten_limit, ...}.

enum class FlattenReason {
    Structural,
    Equality,
    Utf8Encode,
    RandomAccess,
    Transform,
};

/**
 * Allocates a fresh leaf wrapping `len` UTF-16 code units. Routes len==0 to
 * the embedded empty-string constant (never allocates a zero-length leaf).
 */
HPointer makeLeafFromBuffer(const u16* data, u32 len);

/**
 * Allocates a Tag_StringSlice over leaf `base` with the given `offset` /
 * `len`. Caller must root `base` across this call. len==0 returns the empty
 * constant; the constructor never allocates a zero-length slice.
 */
HPointer makeSlice(HPointer base, u32 offset, u32 len);

/**
 * Allocates a Tag_StringRope joining `left` and `right`. Both children
 * must be rooted by the caller across this call. Empty children are
 * collapsed: if either side is empty/empty-constant, the other side is
 * returned directly. The resulting header.size is `leftLen + rightLen`,
 * and `height` / `leafCount` are computed from the children.
 */
HPointer makeRope(HPointer left, HPointer right);

/**
 * Materialise any string into a fresh leaf. Returns the empty constant for
 * len==0. Roots `s` across the allocation internally so callers don't need
 * to (the only field read after the alloc is the leaf's own chars[]).
 */
HPointer flattenToLeaf(HPointer s);

/**
 * Decision point for "should I flatten this string before further work?".
 * Phase 1 behaviour: leaves and the empty constant pass through; slices
 * with len <= string_flatten_limit are flattened; larger slices pass
 * through (the caller is then responsible for using charAt-style access).
 */
HPointer maybeFlattenOrRebalance(HPointer s, FlattenReason reason);

/**
 * Returns a leaf HPointer for `s`. If `s` is already a leaf or empty
 * constant, returns it unchanged; otherwise allocates a flat copy.
 * Caller must root any HPointer it holds across this call (it may allocate).
 */
HPointer ensureFlat(HPointer s);

// ============================================================================
// Length and Character Access
// ============================================================================

/**
 * Returns the number of code units in a string.
 * Equivalent to Elm's String.length for BMP characters.
 */
inline i64 length(void* str) {
    if (!str) return 0;
    return static_cast<i64>(rawLen(str));
}

/**
 * Checks if a string is empty.
 */
inline bool isEmpty(HPointer ptr) {
    return alloc::isConstant(ptr) && Elm::alloc::isEmptyString(ptr);
}

// Forward declaration so all inline ops below can call toStdU16String to
// snapshot a string into a contiguous std::u16string before allocation.
inline std::u16string toStdU16String(void* str);

// ============================================================================
// Tag-aware segment visitor (zero-allocation path for leaves/slices/large)
// ============================================================================
//
// Invokes `cb(const u16* segPtr, u32 segLen)` for each contiguous u16 segment
// of `str`, in logical order. The callback must NOT allocate (resolved
// pointers passed in would be invalidated by a GC).
//
// Replaces the "snapshot to std::u16string then copy" idiom in transforms
// and search ops. For pure leaves the callback fires once with the leaf's
// own chars[]; no heap allocation at all. Ropes use a small std::vector
// stack to avoid C-stack blowup on deep trees — that is the only allocation
// the visitor itself performs.
template <class F>
inline void forEachSegment(void* str, F&& cb) {
    if (!str) return;
    auto& allocator = Allocator::instance();
    Header* hdr = static_cast<Header*>(str);

    if (hdr->tag == Tag_String) {
        ElmString* s = static_cast<ElmString*>(str);
        if (s->header.size > 0) cb(static_cast<const u16*>(s->chars), s->header.size);
        return;
    }
    if (hdr->tag == Tag_LargeStringHeader) {
        LargeStringHeader* h = static_cast<LargeStringHeader*>(str);
        void* body = allocator.resolve(h->body);
        if (!body) return;
        ElmString* leaf = static_cast<ElmString*>(body);
        if (leaf->header.size > 0)
            cb(static_cast<const u16*>(leaf->chars), leaf->header.size);
        return;
    }
    if (hdr->tag == Tag_StringSlice) {
        ElmStringSlice* slc = static_cast<ElmStringSlice*>(str);
        if (slc->header.size == 0) return;
        void* base = allocator.resolve(slc->base);
        if (!base) return;
        if (static_cast<Header*>(base)->tag == Tag_LargeStringHeader) {
            LargeStringHeader* lh = static_cast<LargeStringHeader*>(base);
            base = allocator.resolve(lh->body);
            if (!base) return;
        }
        ElmString* leaf = static_cast<ElmString*>(base);
        cb(static_cast<const u16*>(leaf->chars + slc->offset), slc->header.size);
        return;
    }
    if (hdr->tag != Tag_StringRope) return;

    // Rope path: in-order DFS via explicit stack so deep trees can't blow
    // the C stack. No allocator calls inside the walk → pointers stay valid.
    std::vector<void*> stack;
    stack.reserve(32);
    stack.push_back(str);
    while (!stack.empty()) {
        void* top = stack.back();
        stack.pop_back();
        Header* h = static_cast<Header*>(top);
        if (h->tag == Tag_String) {
            ElmString* s = static_cast<ElmString*>(top);
            if (s->header.size > 0)
                cb(static_cast<const u16*>(s->chars), s->header.size);
        } else if (h->tag == Tag_LargeStringHeader) {
            LargeStringHeader* lh = static_cast<LargeStringHeader*>(top);
            void* body = allocator.resolve(lh->body);
            if (body) {
                ElmString* leaf = static_cast<ElmString*>(body);
                if (leaf->header.size > 0)
                    cb(static_cast<const u16*>(leaf->chars), leaf->header.size);
            }
        } else if (h->tag == Tag_StringSlice) {
            ElmStringSlice* slc = static_cast<ElmStringSlice*>(top);
            if (slc->header.size > 0) {
                void* base = allocator.resolve(slc->base);
                if (base) {
                    if (static_cast<Header*>(base)->tag == Tag_LargeStringHeader) {
                        LargeStringHeader* lh = static_cast<LargeStringHeader*>(base);
                        base = allocator.resolve(lh->body);
                    }
                    if (base) {
                        ElmString* leaf = static_cast<ElmString*>(base);
                        cb(static_cast<const u16*>(leaf->chars + slc->offset),
                           slc->header.size);
                    }
                }
            }
        } else if (h->tag == Tag_StringRope) {
            ElmStringRope* r = static_cast<ElmStringRope*>(top);
            void* rightObj = allocator.resolve(r->right);
            void* leftObj  = allocator.resolve(r->left);
            if (rightObj) stack.push_back(rightObj);
            if (leftObj)  stack.push_back(leftObj);
        }
    }
}

// Copies the contents of `str` into `dst` (which must have room for
// rawLen(str) u16 code units). No allocation. Caller must ensure `str`
// remains valid (no GC between resolving and calling).
inline void copyInto(void* str, u16* dst) {
    forEachSegment(str, [&](const u16* p, u32 n) {
        std::memcpy(dst, p, n * sizeof(u16));
        dst += n;
    });
}

/**
 * Returns the character at a given index (0-based).
 * Returns 0 if index is out of bounds.
 *
 * Tag-dispatched: leaves index chars[] directly; slices resolve their base
 * and index `chars[offset + idx]`; ropes recurse into left/right based on
 * the left subtree's length. Resolution does not allocate, so charAt is
 * safe to call without rooting.
 */
inline u16 charAt(void* str, i64 index) {
    if (!str) return 0;
    auto& allocator = Allocator::instance();

    // Walk down ropes iteratively so deep trees don't blow the C stack.
    while (true) {
        Header* hdr = static_cast<Header*>(str);
        if (index < 0 || static_cast<u32>(index) >= hdr->size) {
            return 0;
        }
        if (hdr->tag == Tag_String) {
            ElmString* s = static_cast<ElmString*>(str);
            return s->chars[index];
        }
        if (hdr->tag == Tag_LargeStringHeader) {
            // Split header: resolve to the Tag_String body and read chars[].
            LargeStringHeader* h = static_cast<LargeStringHeader*>(str);
            void* body = allocator.resolve(h->body);
            if (!body) return 0;
            ElmString* leaf = static_cast<ElmString*>(body);
            return leaf->chars[index];
        }
        if (hdr->tag == Tag_StringSlice) {
            ElmStringSlice* slc = static_cast<ElmStringSlice*>(str);
            void* base = allocator.resolve(slc->base);
            if (!base) return 0;
            // Slice's base may itself be a split header — resolve through it.
            if (static_cast<Header*>(base)->tag == Tag_LargeStringHeader) {
                LargeStringHeader* h = static_cast<LargeStringHeader*>(base);
                base = allocator.resolve(h->body);
                if (!base) return 0;
            }
            ElmString* leaf = static_cast<ElmString*>(base);
            return leaf->chars[slc->offset + index];
        }
        // Tag_StringRope: descend.
        ElmStringRope* r = static_cast<ElmStringRope*>(str);
        void* leftObj = allocator.resolve(r->left);
        u32 leftLen = leftObj ? static_cast<Header*>(leftObj)->size : 0;
        if (static_cast<u64>(index) < leftLen) {
            str = leftObj;
        } else {
            index -= leftLen;
            str = allocator.resolve(r->right);
            if (!str) return 0;
        }
    }
}

// ============================================================================
// Concatenation
// ============================================================================

/**
 * Appends two strings: a ++ b
 *
 * Builds a flat leaf when the total fits in config.string_flatten_limit (so
 * short strings keep the existing memcpy fast path). Above that threshold,
 * builds a Tag_StringRope joining the two HPointers — sharing both subtrees
 * and giving O(1) amortised concat for repeated appends.
 */
inline HPointer append(void* a, void* b) {
    if (!a && !b) return alloc::emptyString();
    if (!a) return Allocator::instance().wrap(b);
    if (!b) return Allocator::instance().wrap(a);

    size_t len_a = rawLen(a);
    size_t len_b = rawLen(b);

    if (len_a == 0) return Allocator::instance().wrap(b);
    if (len_b == 0) return Allocator::instance().wrap(a);

    size_t total_len = len_a + len_b;
    if (total_len <= Allocator::instance().getConfig().string_flatten_limit) {
        auto bufA = toStdU16String(a);
        auto bufB = toStdU16String(b);
        std::vector<u16> data(total_len);
        std::memcpy(data.data(), bufA.data(), bufA.size() * sizeof(u16));
        std::memcpy(data.data() + bufA.size(), bufB.data(), bufB.size() * sizeof(u16));
        return alloc::allocString(data.data(), total_len);
    }

    // Large total: build a rope. Wrap inputs as HPointers up front so we
    // can root them across the rope allocation (resolved void*s are unsafe
    // across allocate(); the wrapped HPointers are GC-tracked).
    auto& allocator = Allocator::instance();
    HPointer aHp = allocator.wrap(a);
    HPointer bHp = allocator.wrap(b);
    return makeRope(aHp, bHp);
}

/**
 * Concatenates a list of strings.
 * Takes an HPointer to a list of strings.
 */
HPointer concat(HPointer stringList);

/**
 * Joins strings with a separator.
 * Takes a separator string and a list of strings.
 */
HPointer join(void* sep, HPointer stringList);

// ============================================================================
// Slicing
// ============================================================================

/**
 * Extracts a substring from start (inclusive) to end (exclusive).
 * Negative indices count from end. Clamps to valid range.
 *
 * For ranges below string_tiny_slice_limit, builds a flat leaf (avoids the
 * slice metadata for short ranges). Larger ranges over a leaf build a
 * Tag_StringSlice that shares the source buffer. Slice-of-slice collapses
 * to a single slice over the deepest leaf base.
 */
HPointer slice(void* str, i64 start, i64 end);

/**
 * Returns the first n characters.
 */
inline HPointer left(void* str, i64 n) {
    if (n <= 0) return alloc::emptyString();
    return slice(str, 0, n);
}

/**
 * Returns the last n characters.
 */
inline HPointer right(void* str, i64 n) {
    if (n <= 0) return alloc::emptyString();
    if (!str) return alloc::emptyString();
    i64 len = static_cast<i64>(rawLen(str));
    return slice(str, len - n, len);
}

/**
 * Drops the first n characters.
 */
inline HPointer dropLeft(void* str, i64 n) {
    if (n <= 0) return Allocator::instance().wrap(str);
    if (!str) return alloc::emptyString();
    i64 len = static_cast<i64>(rawLen(str));
    return slice(str, n, len);
}

/**
 * Drops the last n characters.
 */
inline HPointer dropRight(void* str, i64 n) {
    if (n <= 0) return Allocator::instance().wrap(str);
    if (!str) return alloc::emptyString();
    i64 len = static_cast<i64>(rawLen(str));
    return slice(str, 0, len - n);
}

// ============================================================================
// Searching
// ============================================================================

/**
 * Checks if the substring needle is contained in haystack.
 * Both sides are read via tag-aware charAt, so this transparently
 * handles slice inputs without allocation.
 */
// Internal: returns a `(ptr, len)` view into `str` if it is a single
// contiguous u16 segment (leaf, large-header, or slice). Returns
// `(nullptr, 0)` for ropes / empty. No allocation.
inline std::pair<const u16*, u32> singleSegmentView(void* str) {
    if (!str) return {nullptr, 0};
    Header* hdr = static_cast<Header*>(str);
    if (hdr->tag == Tag_String) {
        ElmString* s = static_cast<ElmString*>(str);
        return {s->chars, s->header.size};
    }
    if (hdr->tag == Tag_LargeStringHeader) {
        LargeStringHeader* h = static_cast<LargeStringHeader*>(str);
        void* body = Allocator::instance().resolve(h->body);
        if (!body) return {nullptr, 0};
        ElmString* leaf = static_cast<ElmString*>(body);
        return {leaf->chars, leaf->header.size};
    }
    if (hdr->tag == Tag_StringSlice) {
        ElmStringSlice* slc = static_cast<ElmStringSlice*>(str);
        void* base = Allocator::instance().resolve(slc->base);
        if (!base) return {nullptr, 0};
        if (static_cast<Header*>(base)->tag == Tag_LargeStringHeader) {
            LargeStringHeader* lh = static_cast<LargeStringHeader*>(base);
            base = Allocator::instance().resolve(lh->body);
            if (!base) return {nullptr, 0};
        }
        ElmString* leaf = static_cast<ElmString*>(base);
        return {leaf->chars + slc->offset, slc->header.size};
    }
    return {nullptr, 0};
}

inline bool contains(void* needle, void* haystack) {
    if (!needle) return true;
    if (!haystack) return false;

    size_t needle_len = rawLen(needle);
    size_t haystack_len = rawLen(haystack);
    if (needle_len == 0) return true;
    if (needle_len > haystack_len) return false;

    // Fast path: both sides are contiguous u16 segments (leaf, slice, or
    // large-split-header). Use std::search; for libstdc++ this is the
    // straightforward naive search but operates on raw u16* without any
    // per-char tag dispatch or slice resolution.
    auto [nPtr, nLen] = singleSegmentView(needle);
    auto [hPtr, hLen] = singleSegmentView(haystack);
    if (nPtr && hPtr) {
        return std::search(hPtr, hPtr + hLen, nPtr, nPtr + nLen) != hPtr + hLen;
    }

    // Slow path (rope on either side): keep the per-char charAt walk.
    for (size_t i = 0; i <= haystack_len - needle_len; ++i) {
        bool match = true;
        for (size_t j = 0; j < needle_len && match; ++j) {
            if (charAt(haystack, static_cast<i64>(i + j)) !=
                charAt(needle, static_cast<i64>(j))) match = false;
        }
        if (match) return true;
    }
    return false;
}

/**
 * Checks if str starts with prefix.
 */
inline bool startsWith(void* prefix, void* str) {
    if (!prefix) return true;
    if (!str) return false;

    size_t prefix_len = rawLen(prefix);
    size_t str_len = rawLen(str);
    if (prefix_len > str_len) return false;
    if (prefix_len == 0) return true;

    auto [pPtr, pLen] = singleSegmentView(prefix);
    auto [sPtr, sLen] = singleSegmentView(str);
    if (pPtr && sPtr) {
        return std::memcmp(sPtr, pPtr, prefix_len * sizeof(u16)) == 0;
    }

    for (size_t i = 0; i < prefix_len; ++i) {
        if (charAt(str, static_cast<i64>(i)) != charAt(prefix, static_cast<i64>(i))) return false;
    }
    return true;
}

/**
 * Checks if str ends with suffix.
 */
inline bool endsWith(void* suffix, void* str) {
    if (!suffix) return true;
    if (!str) return false;

    size_t suffix_len = rawLen(suffix);
    size_t str_len = rawLen(str);
    if (suffix_len > str_len) return false;
    if (suffix_len == 0) return true;

    size_t offset = str_len - suffix_len;
    auto [sufPtr, sufLen] = singleSegmentView(suffix);
    auto [sPtr, sLen]     = singleSegmentView(str);
    if (sufPtr && sPtr) {
        return std::memcmp(sPtr + offset, sufPtr, suffix_len * sizeof(u16)) == 0;
    }

    for (size_t i = 0; i < suffix_len; ++i) {
        if (charAt(str, static_cast<i64>(offset + i)) !=
            charAt(suffix, static_cast<i64>(i))) return false;
    }
    return true;
}

/**
 * Returns a list of all indices where needle appears in haystack.
 */
HPointer indexes(void* needle, void* haystack);

// ============================================================================
// Transformation
// ============================================================================

/**
 * Converts string to uppercase (ASCII only).
 */
inline HPointer toUpper(void* str) {
    if (!str) return alloc::emptyString();
    u32 len = rawLen(str);
    if (len == 0) return alloc::emptyString();

    // Root the source across allocStringBlank (which may GC); after the
    // alloc, resolve back and copy directly into the result chars[].
    auto& allocator = Allocator::instance();
    HPointer srcHp = allocator.wrap(str);
    alloc::BlankString out;
    {
        Elm::StackRootGuard guard(&srcHp);
        out = alloc::allocStringBlank(len);
    }
    copyInto(allocator.resolve(srcHp), out.chars);
    for (u32 i = 0; i < out.length; ++i) {
        u16 c = out.chars[i];
        if (c >= 'a' && c <= 'z') out.chars[i] = c - 32;
    }
    return out.hp;
}

/**
 * Converts string to lowercase (ASCII only).
 */
inline HPointer toLower(void* str) {
    if (!str) return alloc::emptyString();
    u32 len = rawLen(str);
    if (len == 0) return alloc::emptyString();

    auto& allocator = Allocator::instance();
    HPointer srcHp = allocator.wrap(str);
    alloc::BlankString out;
    {
        Elm::StackRootGuard guard(&srcHp);
        out = alloc::allocStringBlank(len);
    }
    copyInto(allocator.resolve(srcHp), out.chars);
    for (u32 i = 0; i < out.length; ++i) {
        u16 c = out.chars[i];
        if (c >= 'A' && c <= 'Z') out.chars[i] = c + 32;
    }
    return out.hp;
}

/**
 * Reverses a string.
 */
inline HPointer reverse(void* str) {
    if (!str) return alloc::emptyString();
    u32 len = rawLen(str);
    if (len == 0) return alloc::emptyString();
    if (len == 1 && isLeaf(str)) return Allocator::instance().wrap(str);

    auto& allocator = Allocator::instance();
    HPointer srcHp = allocator.wrap(str);
    alloc::BlankString out;
    {
        Elm::StackRootGuard guard(&srcHp);
        out = alloc::allocStringBlank(len);
    }
    // Walk source segments in logical order, writing reversed.
    u32 written = 0;
    forEachSegment(allocator.resolve(srcHp), [&](const u16* p, u32 n) {
        // Place this segment at the *tail end* of the remaining target.
        u16* dst = out.chars + (out.length - written - n);
        for (u32 i = 0; i < n; ++i) dst[i] = p[n - 1 - i];
        written += n;
    });
    return out.hp;
}

/**
 * Trims whitespace from both ends. Returns a slice of the source where
 * possible (no buffer copy) by delegating to slice().
 */
inline HPointer trim(void* str) {
    if (!str) return alloc::emptyString();
    auto buf = toStdU16String(str);
    size_t len = buf.size();
    if (len == 0) return alloc::emptyString();

    size_t start = 0;
    while (start < len && (buf[start] == ' ' || buf[start] == '\t' ||
                           buf[start] == '\n' || buf[start] == '\r')) {
        ++start;
    }
    size_t end = len;
    while (end > start && (buf[end - 1] == ' ' || buf[end - 1] == '\t' ||
                           buf[end - 1] == '\n' || buf[end - 1] == '\r')) {
        --end;
    }
    if (start >= end) return alloc::emptyString();
    if (start == 0 && end == len) return Allocator::instance().wrap(str);

    return slice(str, static_cast<i64>(start), static_cast<i64>(end));
}

/**
 * Trims whitespace from the left.
 */
inline HPointer trimLeft(void* str) {
    if (!str) return alloc::emptyString();
    auto buf = toStdU16String(str);
    size_t len = buf.size();
    if (len == 0) return alloc::emptyString();

    size_t start = 0;
    while (start < len && (buf[start] == ' ' || buf[start] == '\t' ||
                           buf[start] == '\n' || buf[start] == '\r')) {
        ++start;
    }
    if (start == 0) return Allocator::instance().wrap(str);
    if (start >= len) return alloc::emptyString();

    return slice(str, static_cast<i64>(start), static_cast<i64>(len));
}

/**
 * Trims whitespace from the right.
 */
inline HPointer trimRight(void* str) {
    if (!str) return alloc::emptyString();
    auto buf = toStdU16String(str);
    size_t len = buf.size();
    if (len == 0) return alloc::emptyString();

    size_t end = len;
    while (end > 0 && (buf[end - 1] == ' ' || buf[end - 1] == '\t' ||
                       buf[end - 1] == '\n' || buf[end - 1] == '\r')) {
        --end;
    }
    if (end == len) return Allocator::instance().wrap(str);
    if (end == 0) return alloc::emptyString();

    return slice(str, 0, static_cast<i64>(end));
}

/**
 * Repeats a string n times.
 */
inline HPointer repeat(void* str, i64 n) {
    if (n <= 0 || !str) return alloc::emptyString();

    u32 srcLen = rawLen(str);
    if (srcLen == 0) return alloc::emptyString();

    size_t total_len = static_cast<size_t>(srcLen) * static_cast<size_t>(n);
    auto& allocator = Allocator::instance();
    HPointer srcHp = allocator.wrap(str);
    alloc::BlankString out;
    {
        Elm::StackRootGuard guard(&srcHp);
        out = alloc::allocStringBlank(total_len);
    }
    void* src = allocator.resolve(srcHp);
    // Materialise one copy into the first srcLen slots via the segment walk;
    // then memcpy that prefix forward n-1 times.
    copyInto(src, out.chars);
    for (i64 i = 1; i < n; ++i) {
        std::memcpy(out.chars + i * srcLen, out.chars, srcLen * sizeof(u16));
    }
    return out.hp;
}

/**
 * Pads string on the left to reach at least n characters.
 */
inline HPointer padLeft(void* str, i64 n, u16 padChar) {
    if (n <= 0) {
        return str ? Allocator::instance().wrap(str) : alloc::emptyString();
    }
    if (!str) {
        // All padding, no source data.
        alloc::BlankString out = alloc::allocStringBlank(static_cast<size_t>(n));
        for (u32 i = 0; i < out.length; ++i) out.chars[i] = padChar;
        return out.hp;
    }
    u32 len = rawLen(str);
    if (static_cast<i64>(len) >= n) return Allocator::instance().wrap(str);

    size_t pad_count = static_cast<size_t>(n) - len;
    auto& allocator = Allocator::instance();
    HPointer srcHp = allocator.wrap(str);
    alloc::BlankString out;
    {
        Elm::StackRootGuard guard(&srcHp);
        out = alloc::allocStringBlank(static_cast<size_t>(n));
    }
    for (size_t i = 0; i < pad_count; ++i) out.chars[i] = padChar;
    copyInto(allocator.resolve(srcHp), out.chars + pad_count);
    return out.hp;
}

/**
 * Pads string on the right to reach at least n characters.
 */
inline HPointer padRight(void* str, i64 n, u16 padChar) {
    if (n <= 0) {
        return str ? Allocator::instance().wrap(str) : alloc::emptyString();
    }
    if (!str) {
        alloc::BlankString out = alloc::allocStringBlank(static_cast<size_t>(n));
        for (u32 i = 0; i < out.length; ++i) out.chars[i] = padChar;
        return out.hp;
    }
    u32 len = rawLen(str);
    if (static_cast<i64>(len) >= n) return Allocator::instance().wrap(str);

    auto& allocator = Allocator::instance();
    HPointer srcHp = allocator.wrap(str);
    alloc::BlankString out;
    {
        Elm::StackRootGuard guard(&srcHp);
        out = alloc::allocStringBlank(static_cast<size_t>(n));
    }
    copyInto(allocator.resolve(srcHp), out.chars);
    for (u32 i = len; i < out.length; ++i) out.chars[i] = padChar;
    return out.hp;
}

// ============================================================================
// Splitting
// ============================================================================

/**
 * Splits a string on a separator into a list of strings.
 */
HPointer split(void* sep, void* str);

/**
 * Splits a string into individual characters as a list of single-char strings.
 */
HPointer toList(void* str);

// ============================================================================
// Conversion
// ============================================================================

/**
 * Parses an integer from a string.
 * Returns Just(int) on success, Nothing on failure.
 */
// Narrows a u16 string to a stack buffer of ASCII chars. Returns false if
// the string is too long for the buffer or contains a non-ASCII char.
// Tag-aware: uses forEachSegment so leaves/slices/ropes all work without
// allocating an intermediate std::u16string.
inline bool narrowAsciiToStack(void* str, char* buf, size_t cap, size_t* out_len) {
    size_t written = 0;
    bool ok = true;
    forEachSegment(str, [&](const u16* p, u32 n) {
        if (!ok) return;
        if (written + n > cap) { ok = false; return; }
        for (u32 i = 0; i < n; ++i) {
            u16 c = p[i];
            if (c > 127) { ok = false; return; }
            buf[written + i] = static_cast<char>(c);
        }
        written += n;
    });
    if (!ok) return false;
    *out_len = written;
    return true;
}

inline HPointer toInt(void* str) {
    if (!str) return alloc::nothing();
    u32 len = rawLen(str);
    if (len == 0) return alloc::nothing();

    // Typical int literals fit in a 32-char stack buffer (i64 ± sign ≤ 21).
    char buf[64];
    size_t narrowed_len;
    if (len > sizeof(buf) || !narrowAsciiToStack(str, buf, sizeof(buf), &narrowed_len)) {
        return alloc::nothing();
    }

    i64 val;
    auto [end, ec] = std::from_chars(buf, buf + narrowed_len, val, 10);
    if (ec != std::errc() || end != buf + narrowed_len) return alloc::nothing();

    return alloc::just(alloc::unboxedInt(val), false);
}

/**
 * Parses a float from a string.
 * Returns Just(float) on success, Nothing on failure.
 */
inline HPointer toFloat(void* str) {
    if (!str) return alloc::nothing();
    u32 len = rawLen(str);
    if (len == 0) return alloc::nothing();

    // Typical float literals fit well within 64 chars; longer inputs are
    // unlikely to parse meaningfully anyway.
    char buf[128];
    size_t narrowed_len;
    if (len > sizeof(buf) - 1 ||
        !narrowAsciiToStack(str, buf, sizeof(buf) - 1, &narrowed_len)) {
        return alloc::nothing();
    }
    buf[narrowed_len] = '\0';

    // libstdc++ supports std::from_chars for floats from version 11 onwards,
    // but strtod is universally reliable. Use strtod with the C locale.
    char* end;
    errno = 0;
    double val = std::strtod(buf, &end);
    if (end != buf + narrowed_len) return alloc::nothing();
    if (errno == ERANGE) return alloc::nothing();
    if (std::isinf(val) || std::isnan(val)) return alloc::nothing();

    return alloc::just(alloc::unboxedFloat(val), false);
}

/**
 * Converts an integer to a string.
 */
inline HPointer fromInt(i64 n) {
    // std::to_chars is locale-free, allocates nothing, and produces the
    // shortest decimal representation. i64 max is 20 chars including sign.
    char buf[24];
    auto [end, ec] = std::to_chars(buf, buf + sizeof(buf), n);
    size_t len = static_cast<size_t>(end - buf);
    u16 wide[24];
    for (size_t i = 0; i < len; ++i) wide[i] = static_cast<u16>(buf[i]);
    return alloc::allocString(wide, len);
}

/**
 * Converts a float to a string.
 */
inline HPointer fromFloat(f64 n) {
    if (std::isnan(n)) return alloc::allocString(u"NaN");
    if (std::isinf(n)) {
        return n > 0 ? alloc::allocString(u"Infinity")
                     : alloc::allocString(u"-Infinity");
    }
    if (n == 0.0) return alloc::allocString(u"0");

    // Use std::to_chars for the shortest round-trip representation,
    // matching JavaScript/Elm's Number.prototype.toString() behavior.
    char buf[32];
    auto [ptr, ec] = std::to_chars(buf, buf + sizeof(buf), n);
    std::string s(buf, ptr);
    std::u16string u16(s.begin(), s.end());
    return alloc::allocString(u16);
}

/**
 * Converts a character to a single-character string.
 */
inline HPointer fromChar(u16 c) {
    u16 buf[1] = {c};
    return alloc::allocString(buf, 1);
}

/**
 * Prepends a character to a string: cons.
 *
 * Snapshots the source bytes via toStdU16String first so a slice input
 * works the same as a leaf input. Always returns a flat leaf in Phase 1.
 */
inline HPointer cons(u16 c, void* str) {
    if (!str) return fromChar(c);
    u32 len = rawLen(str);
    size_t total_len = static_cast<size_t>(len) + 1;

    auto& allocator = Allocator::instance();
    HPointer srcHp = allocator.wrap(str);
    alloc::BlankString out;
    {
        Elm::StackRootGuard guard(&srcHp);
        out = alloc::allocStringBlank(total_len);
    }
    out.chars[0] = c;
    if (len > 0) copyInto(allocator.resolve(srcHp), out.chars + 1);
    return out.hp;
}

/**
 * Removes and returns the first character: uncons.
 * Returns Just (char, rest) or Nothing if empty.
 */
HPointer uncons(void* str);

// ============================================================================
// Higher-Order Operations
// ============================================================================

/**
 * Applies a function to each character and collects results.
 * The function takes a u16 and returns an Unboxable.
 */
using CharMapper = Unboxable (*)(u16);

/**
 * Maps a function over each character, producing a new string.
 * mapFunc should transform one character to another.
 */
using CharToCharMapper = u16 (*)(u16);

HPointer map(CharToCharMapper mapFunc, void* str);

/**
 * Filters characters based on a predicate.
 */
using CharPredicate = bool (*)(u16);

HPointer filter(CharPredicate pred, void* str);

/**
 * Left fold over characters.
 */
using CharFolder = Unboxable (*)(u16, Unboxable);

Unboxable foldl(CharFolder fold, Unboxable acc, void* str);

/**
 * Right fold over characters.
 */
Unboxable foldr(CharFolder fold, Unboxable acc, void* str);

/**
 * Checks if all characters satisfy a predicate.
 */
inline bool all(CharPredicate pred, void* str) {
    if (!str) return true;
    size_t len = rawLen(str);
    for (size_t i = 0; i < len; ++i) {
        if (!pred(charAt(str, static_cast<i64>(i)))) return false;
    }
    return true;
}

/**
 * Checks if any character satisfies a predicate.
 */
inline bool any(CharPredicate pred, void* str) {
    if (!str) return false;
    size_t len = rawLen(str);
    for (size_t i = 0; i < len; ++i) {
        if (pred(charAt(str, static_cast<i64>(i)))) return true;
    }
    return false;
}

// ============================================================================
// Utilities
// ============================================================================

/**
 * Converts a String into a contiguous std::u16string. Tag-aware: leaves
 * copy directly from chars[]; slices resolve their base and copy with
 * offset; ropes traverse the tree filling a pre-sized buffer in order.
 * Does not allocate on the Elm heap.
 */
inline std::u16string toStdU16String(void* str) {
    if (!str) return {};
    Header* hdr = static_cast<Header*>(str);
    if (hdr->tag == Tag_String) {
        ElmString* s = static_cast<ElmString*>(str);
        return std::u16string(reinterpret_cast<const char16_t*>(s->chars), s->header.size);
    }
    if (hdr->tag == Tag_LargeStringHeader) {
        LargeStringHeader* h = static_cast<LargeStringHeader*>(str);
        void* body = Allocator::instance().resolve(h->body);
        if (!body) return {};
        ElmString* leaf = static_cast<ElmString*>(body);
        return std::u16string(reinterpret_cast<const char16_t*>(leaf->chars),
                              leaf->header.size);
    }
    if (hdr->tag == Tag_StringSlice) {
        ElmStringSlice* slc = static_cast<ElmStringSlice*>(str);
        u32 len = slc->header.size;
        u32 offset = slc->offset;
        void* base = Allocator::instance().resolve(slc->base);
        if (!base) return {};
        // A slice's base can be a split-header — resolve through it.
        if (static_cast<Header*>(base)->tag == Tag_LargeStringHeader) {
            LargeStringHeader* h = static_cast<LargeStringHeader*>(base);
            base = Allocator::instance().resolve(h->body);
            if (!base) return {};
        }
        ElmString* leaf = static_cast<ElmString*>(base);
        return std::u16string(reinterpret_cast<const char16_t*>(leaf->chars + offset), len);
    }
    // Tag_StringRope: in-order DFS, copying each leaf/slice segment into the
    // result buffer. The buffer is pre-sized to avoid reallocation. We use an
    // explicit stack so deep ropes don't blow the C stack.
    auto& allocator = Allocator::instance();
    std::u16string out;
    out.resize(hdr->size);
    char16_t* dst = reinterpret_cast<char16_t*>(out.data());

    std::vector<void*> stack;
    stack.reserve(32);
    stack.push_back(str);
    while (!stack.empty()) {
        void* top = stack.back();
        stack.pop_back();
        Header* h = static_cast<Header*>(top);
        if (h->tag == Tag_String) {
            ElmString* s = static_cast<ElmString*>(top);
            std::memcpy(dst, s->chars, s->header.size * sizeof(u16));
            dst += s->header.size;
        } else if (h->tag == Tag_LargeStringHeader) {
            // Split header: resolve to body and copy from its chars[].
            LargeStringHeader* lh = static_cast<LargeStringHeader*>(top);
            void* body = allocator.resolve(lh->body);
            if (body) {
                ElmString* leaf = static_cast<ElmString*>(body);
                std::memcpy(dst, leaf->chars, leaf->header.size * sizeof(u16));
                dst += leaf->header.size;
            }
        } else if (h->tag == Tag_StringSlice) {
            ElmStringSlice* slc = static_cast<ElmStringSlice*>(top);
            void* base = allocator.resolve(slc->base);
            if (base) {
                // A slice's base may be a Tag_LargeStringHeader; resolve
                // through it to the body (mirrors charAt / top-level slice
                // handler in this file).
                if (static_cast<Header*>(base)->tag == Tag_LargeStringHeader) {
                    LargeStringHeader* lh = static_cast<LargeStringHeader*>(base);
                    base = allocator.resolve(lh->body);
                }
                if (base) {
                    ElmString* leaf = static_cast<ElmString*>(base);
                    std::memcpy(dst, leaf->chars + slc->offset, slc->header.size * sizeof(u16));
                    dst += slc->header.size;
                }
            }
        } else if (h->tag == Tag_StringRope) {
            ElmStringRope* r = static_cast<ElmStringRope*>(top);
            // Push right then left so we visit left first (in-order).
            void* rightObj = allocator.resolve(r->right);
            void* leftObj = allocator.resolve(r->left);
            if (rightObj) stack.push_back(rightObj);
            if (leftObj) stack.push_back(leftObj);
        }
    }
    return out;
}

/**
 * Converts an ElmString to a std::string (UTF-8, for debugging).
 */
std::string toStdString(void* str);

/**
 * Compares two strings for equality. Pure leaf+leaf path is unchanged
 * (memcmp on chars[]). If either side is a slice or rope and the total
 * length is below config.string_flatten_limit, both are snapshotted via
 * toStdU16String and compared with memcmp. Above the limit, falls back to
 * a char-by-char walk via charAt to keep peak memory bounded
 * (// TODO: streaming compare).
 */
inline bool equal(void* a, void* b) {
    if (!a || !b) return a == b;  // both nullptr means both EmptyString
    Header* ha = static_cast<Header*>(a);
    Header* hb = static_cast<Header*>(b);
    if (ha->size != hb->size) return false;

    if (ha->tag == Tag_String && hb->tag == Tag_String) {
        ElmString* sa = static_cast<ElmString*>(a);
        ElmString* sb = static_cast<ElmString*>(b);
        return std::memcmp(sa->chars, sb->chars, ha->size * sizeof(u16)) == 0;
    }

    // Single-segment-on-each-side fast path: covers any combination of
    // leaf / slice / large-split-header without flattening.
    auto [aPtr, aLen] = singleSegmentView(a);
    auto [bPtr, bLen] = singleSegmentView(b);
    if (aPtr && bPtr) {
        return std::memcmp(aPtr, bPtr, ha->size * sizeof(u16)) == 0;
    }

    // Lockstep leaf-segment walk: collect contiguous segments from each
    // side and memcmp them piecewise. No allocation beyond two small
    // segment vectors (one per side), regardless of total string size.
    std::vector<std::pair<const u16*, u32>> aSegs, bSegs;
    aSegs.reserve(16); bSegs.reserve(16);
    forEachSegment(a, [&](const u16* p, u32 n) { aSegs.emplace_back(p, n); });
    forEachSegment(b, [&](const u16* p, u32 n) { bSegs.emplace_back(p, n); });

    size_t ai = 0, bi = 0;
    u32 aOff = 0, bOff = 0;
    while (ai < aSegs.size() && bi < bSegs.size()) {
        u32 aRem = aSegs[ai].second - aOff;
        u32 bRem = bSegs[bi].second - bOff;
        u32 chunk = std::min(aRem, bRem);
        if (std::memcmp(aSegs[ai].first + aOff, bSegs[bi].first + bOff,
                        chunk * sizeof(u16)) != 0) return false;
        aOff += chunk; bOff += chunk;
        if (aOff == aSegs[ai].second) { ++ai; aOff = 0; }
        if (bOff == bSegs[bi].second) { ++bi; bOff = 0; }
    }
    return ai == aSegs.size() && bi == bSegs.size();
}

/**
 * Compares two strings lexicographically.
 * Returns negative if a < b, 0 if a == b, positive if a > b.
 *
 * Pure leaf+leaf path is unchanged. Otherwise, snapshots via toStdU16String
 * when the longest side fits in config.string_flatten_limit, falling back
 * to a charAt walk for very large mixed-form inputs
 * (// TODO: streaming compare).
 */
inline int compare(void* a, void* b) {
    if (!a && !b) return 0;
    if (!a) return -1;
    if (!b) return 1;
    Header* ha = static_cast<Header*>(a);
    Header* hb = static_cast<Header*>(b);

    auto charCompare = [](const u16* pa, const u16* pb, size_t n) -> int {
        for (size_t i = 0; i < n; ++i) {
            if (pa[i] != pb[i]) {
                return static_cast<int>(pa[i]) - static_cast<int>(pb[i]);
            }
        }
        return 0;
    };

    if (ha->tag == Tag_String && hb->tag == Tag_String) {
        ElmString* sa = static_cast<ElmString*>(a);
        ElmString* sb = static_cast<ElmString*>(b);
        size_t min_len = std::min<size_t>(ha->size, hb->size);
        int c = charCompare(sa->chars, sb->chars, min_len);
        if (c != 0) return c;
        return static_cast<int>(ha->size) - static_cast<int>(hb->size);
    }

    // Single-segment-on-each-side fast path.
    auto [aPtr, aLen] = singleSegmentView(a);
    auto [bPtr, bLen] = singleSegmentView(b);
    if (aPtr && bPtr) {
        size_t min_len = std::min<size_t>(aLen, bLen);
        int c = charCompare(aPtr, bPtr, min_len);
        if (c != 0) return c;
        return static_cast<int>(aLen) - static_cast<int>(bLen);
    }

    // Lockstep leaf-segment walk: memcmp-compatible char-compare in chunks.
    std::vector<std::pair<const u16*, u32>> aSegs, bSegs;
    aSegs.reserve(16); bSegs.reserve(16);
    forEachSegment(a, [&](const u16* p, u32 n) { aSegs.emplace_back(p, n); });
    forEachSegment(b, [&](const u16* p, u32 n) { bSegs.emplace_back(p, n); });

    size_t ai = 0, bi = 0;
    u32 aOff = 0, bOff = 0;
    while (ai < aSegs.size() && bi < bSegs.size()) {
        u32 aRem = aSegs[ai].second - aOff;
        u32 bRem = bSegs[bi].second - bOff;
        u32 chunk = std::min(aRem, bRem);
        int c = charCompare(aSegs[ai].first + aOff,
                            bSegs[bi].first + bOff, chunk);
        if (c != 0) return c;
        aOff += chunk; bOff += chunk;
        if (aOff == aSegs[ai].second) { ++ai; aOff = 0; }
        if (bOff == bSegs[bi].second) { ++bi; bOff = 0; }
    }
    return static_cast<int>(ha->size) - static_cast<int>(hb->size);
}

} // namespace StringOps
} // namespace Elm

#endif // ECO_STRING_OPS_H
