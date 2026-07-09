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
#include "Utf8.hpp"
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
 * True if `obj` is a UTF-8 (all-ASCII) String form — an inline-bytes leaf or a
 * zero-copy byte view. These hold 1 ASCII byte per logical UTF-16 code unit.
 */
inline bool isUtf8View(void* obj) { return alloc::getTag(obj) == Tag_StringUtf8View; }
inline bool isUtf8Leaf(void* obj) { return alloc::getTag(obj) == Tag_StringUtf8Leaf; }
inline bool isUtf8(void* obj) {
    Tag t = alloc::getTag(obj);
    return t == Tag_StringUtf8View || t == Tag_StringUtf8Leaf;
}

/**
 * Resolves a UTF-8 String form to its contiguous ASCII byte payload and byte
 * length. A leaf returns its inline bytes; a view resolves its base
 * (Tag_ByteBuffer, Tag_LargeByteHeader body, or Tag_StringUtf8Leaf) and adds
 * the byte offset. No allocation — the returned pointer is valid only until the
 * next allocation (same contract as singleSegmentView). Caller must have
 * verified isUtf8(o).
 */
inline std::pair<const u8*, u32> utf8Bytes(void* o) {
    Header* hdr = static_cast<Header*>(o);
    if (hdr->tag == Tag_StringUtf8Leaf) {
        ElmStringUtf8Leaf* l = static_cast<ElmStringUtf8Leaf*>(o);
        return {l->bytes, l->header.size};
    }
    // Tag_StringUtf8View
    ElmStringUtf8View* v = static_cast<ElmStringUtf8View*>(o);
    void* base = Allocator::instance().resolve(v->base);
    if (!base) return {nullptr, 0};
    Header* bh = static_cast<Header*>(base);
    const u8* p;
    if (bh->tag == Tag_StringUtf8Leaf) {
        p = static_cast<ElmStringUtf8Leaf*>(base)->bytes;
    } else if (bh->tag == Tag_LargeByteHeader) {
        void* body = Allocator::instance().resolve(
            static_cast<LargeByteHeader*>(base)->body);
        if (!body) return {nullptr, 0};
        p = static_cast<ByteBuffer*>(body)->bytes;
    } else {
        // Tag_ByteBuffer
        p = static_cast<ByteBuffer*>(base)->bytes;
    }
    return {p + v->offset, v->byteLen};
}

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
 * Allocates a Tag_StringUtf8View over `base` (a Tag_ByteBuffer,
 * Tag_LargeByteHeader, or Tag_StringUtf8Leaf) with the given byte `offset` and
 * logical length `len` (== byteLen under the all-ASCII invariant). If `base`
 * resolves to a Tag_ByteBufferSlice or another Tag_StringUtf8View, the offset
 * is absorbed so the view's base is never itself a slice/view. len==0 returns
 * the empty constant. Roots `base` across the allocation internally.
 */
HPointer makeUtf8View(HPointer base, u32 byteOffset, u32 len);

/**
 * Allocates a Tag_StringUtf8Leaf holding a copy of `bytes[0..len)`. The bytes
 * MUST be all-ASCII (each < 0x80); asserted under ECO_HEAP_VALIDATE. If the
 * object would meet the large-object threshold it falls back to a widened
 * UTF-16 leaf (no large UTF-8 form in v1). `bytes` may point into the movable
 * heap; the payload is snapshotted before the allocation. len==0 returns empty.
 */
HPointer makeUtf8LeafFromBytes(const u8* bytes, u32 len);

/**
 * ASCII result builder (W4, plans/utf8-string-pipeline-wiring.md). Lets a
 * conservative-widening op emit "ASCII in => UTF-8 out" without each site
 * re-deriving the leaf-vs-large-buffer split. Usage contract:
 *
 *   AsciiOut out = allocAsciiOut(len);   // len > 0; ONE allocation
 *   ... write exactly `len` ASCII bytes to out.dst, with NO other allocation
 *       on this thread in between (out.dst is a fresh leaf payload or a pinned
 *       >= LOT buffer body; a GC would move a sub-LOT leaf) ...
 *   HPointer result = finishAsciiOut(out);   // out.dst invalid afterwards
 *
 * Callers gate on utf8_strings_enabled before using this (else widen to UTF-16
 * as before). finishAsciiOut asserts every byte < 0x80 under ECO_HEAP_VALIDATE.
 */
struct AsciiOut {
    HPointer hp;    // the leaf itself, or the backing ByteBuffer (buffer case)
    u8* dst;        // write target: exactly `len` bytes
    u32 len;
    bool isLeaf;
};
AsciiOut allocAsciiOut(size_t len);
HPointer finishAsciiOut(const AsciiOut& out);

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
//
// forEachSegmentEx distinguishes the two payload widths: it fires
// `u16cb(const u16*, u32)` for UTF-16 segments (Tag_String leaves, slices,
// large-header bodies) and `u8cb(const u8*, u32)` for UTF-8 segments
// (Tag_StringUtf8Leaf / Tag_StringUtf8View), in logical order. Both callbacks
// receive STABLE pointers into the actual heap payload — safe to retain until
// the next allocation. Ropes may freely mix UTF-8 and UTF-16 children.
template <class F16, class F8>
inline void forEachSegmentEx(void* str, F16&& u16cb, F8&& u8cb) {
    if (!str) return;
    auto& allocator = Allocator::instance();
    Header* hdr = static_cast<Header*>(str);

    if (hdr->tag == Tag_String) {
        ElmString* s = static_cast<ElmString*>(str);
        if (s->header.size > 0) u16cb(static_cast<const u16*>(s->chars), s->header.size);
        return;
    }
    if (hdr->tag == Tag_LargeStringHeader) {
        LargeStringHeader* h = static_cast<LargeStringHeader*>(str);
        void* body = allocator.resolve(h->body);
        if (!body) return;
        ElmString* leaf = static_cast<ElmString*>(body);
        if (leaf->header.size > 0)
            u16cb(static_cast<const u16*>(leaf->chars), leaf->header.size);
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
        u16cb(static_cast<const u16*>(leaf->chars + slc->offset), slc->header.size);
        return;
    }
    if (hdr->tag == Tag_StringUtf8View || hdr->tag == Tag_StringUtf8Leaf) {
        auto pr = utf8Bytes(str);
        if (pr.second > 0) u8cb(pr.first, pr.second);
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
                u16cb(static_cast<const u16*>(s->chars), s->header.size);
        } else if (h->tag == Tag_LargeStringHeader) {
            LargeStringHeader* lh = static_cast<LargeStringHeader*>(top);
            void* body = allocator.resolve(lh->body);
            if (body) {
                ElmString* leaf = static_cast<ElmString*>(body);
                if (leaf->header.size > 0)
                    u16cb(static_cast<const u16*>(leaf->chars), leaf->header.size);
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
                        u16cb(static_cast<const u16*>(leaf->chars + slc->offset),
                              slc->header.size);
                    }
                }
            }
        } else if (h->tag == Tag_StringUtf8View || h->tag == Tag_StringUtf8Leaf) {
            auto pr = utf8Bytes(top);
            if (pr.second > 0) u8cb(pr.first, pr.second);
        } else if (h->tag == Tag_StringRope) {
            ElmStringRope* r = static_cast<ElmStringRope*>(top);
            void* rightObj = allocator.resolve(r->right);
            void* leftObj  = allocator.resolve(r->left);
            if (rightObj) stack.push_back(rightObj);
            if (leftObj)  stack.push_back(leftObj);
        }
    }
}

// Thin u16-only wrapper: fires `cb(const u16*, u32)` for every segment,
// widening UTF-8 (ASCII) segments through a small transient stack buffer.
// IMPORTANT: for UTF-8 inputs the pointer passed to `cb` is TRANSIENT — it may
// point into the stack buffer below and is only valid for that one call.
// Callers that RETAIN segment pointers past the callback (equal/compare) must
// use forEachSegmentEx instead. All other callers (which consume the pointer
// immediately, e.g. copyInto/map/filter) are safe with this wrapper.
template <class F>
inline void forEachSegment(void* str, F&& cb) {
    forEachSegmentEx(
        str,
        [&](const u16* p, u32 n) { cb(p, n); },
        [&](const u8* p, u32 n) {
            GC_STATS_UTF8_WIDEN_SITE(UTF8_WIDEN_SEGMENT_CHUNK, n);
            u16 tmp[512];
            u32 i = 0;
            while (i < n) {
                u32 chunk = std::min<u32>(n - i, 512);
                for (u32 j = 0; j < chunk; ++j) tmp[j] = static_cast<u16>(p[i + j]);
                cb(static_cast<const u16*>(tmp), chunk);
                i += chunk;
            }
        });
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
        if (hdr->tag == Tag_StringUtf8View || hdr->tag == Tag_StringUtf8Leaf) {
            // ASCII: the unit index is the byte index (bounds checked above).
            auto pr = utf8Bytes(str);
            if (!pr.first) return 0;
            return static_cast<u16>(pr.first[index]);
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
        // Both UTF-8 => byte-concat into a UTF-8 result (ASCII+ASCII=ASCII).
        // W4.b. Mixed encodings fall through to the UTF-16 widen below.
        if (isUtf8(a) && isUtf8(b) &&
            Allocator::instance().getConfig().utf8_strings_enabled) {
            auto& allocator = Allocator::instance();
            HPointer aHp = allocator.wrap(a);
            HPointer bHp = allocator.wrap(b);
            AsciiOut out;
            { Elm::StackRootGuard g(&aHp, &bHp); out = allocAsciiOut(total_len); }
            auto pa = utf8Bytes(allocator.resolve(aHp));
            auto pb = utf8Bytes(allocator.resolve(bHp));
            std::memcpy(out.dst, pa.first, pa.second);
            std::memcpy(out.dst + pa.second, pb.first, pb.second);
            return finishAsciiOut(out);
        }
        if (isUtf8(a)) GC_STATS_UTF8_WIDEN_SITE(UTF8_WIDEN_APPEND_MIXED, len_a);
        if (isUtf8(b)) GC_STATS_UTF8_WIDEN_SITE(UTF8_WIDEN_APPEND_MIXED, len_b);
        auto bufA = toStdU16String(a);
        auto bufB = toStdU16String(b);
        std::vector<u16> data(total_len);
        std::memcpy(data.data(), bufA.data(), bufA.size() * sizeof(u16));
        std::memcpy(data.data() + bufA.size(), bufB.data(), bufB.size() * sizeof(u16));
        // H2 (chain healing): a mixed-encoding append whose CONTENT is all
        // ASCII returns a UTF-8 result, so one UTF-16 operand (e.g. a name
        // sliced from a non-ASCII source file) stops poisoning every
        // subsequent append in the chain. `data` is C-heap: safe across the
        // allocation, no rooting needed.
        if (Allocator::instance().getConfig().utf8_strings_enabled) {
            u16 acc = 0;
            for (size_t i = 0; i < total_len; ++i) acc |= data[i];
            if (acc < 0x80) {
                AsciiOut out = allocAsciiOut(total_len);
                for (size_t i = 0; i < total_len; ++i)
                    out.dst[i] = static_cast<u8>(data[i]);
                return finishAsciiOut(out);
            }
        }
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

    // Both UTF-8 (ASCII): byte-level std::search — bytes == units, so a byte
    // match is a unit match. The common case now that literals are UTF-8.
    if (isUtf8(needle) && isUtf8(haystack)) {
        auto n = utf8Bytes(needle);
        auto h = utf8Bytes(haystack);
        return std::search(h.first, h.first + h.second, n.first,
                           n.first + n.second) != h.first + h.second;
    }

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

    // Both UTF-8 (ASCII): byte memcmp.
    if (isUtf8(prefix) && isUtf8(str)) {
        auto p = utf8Bytes(prefix);
        auto s = utf8Bytes(str);
        return std::memcmp(s.first, p.first, prefix_len) == 0;
    }

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

    // Both UTF-8 (ASCII): byte memcmp at the tail.
    if (isUtf8(suffix) && isUtf8(str)) {
        auto suf = utf8Bytes(suffix);
        auto s = utf8Bytes(str);
        return std::memcmp(s.first + offset, suf.first, suffix_len) == 0;
    }

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

    // UTF-8 in => UTF-8 out (ASCII upper-case is closed over ASCII). W4.d.
    if (isUtf8(str) && Allocator::instance().getConfig().utf8_strings_enabled) {
        auto& allocator = Allocator::instance();
        HPointer srcHp = allocator.wrap(str);
        AsciiOut out;
        { Elm::StackRootGuard guard(&srcHp); out = allocAsciiOut(len); }
        auto pr = utf8Bytes(allocator.resolve(srcHp));
        for (u32 i = 0; i < len; ++i) {
            u8 c = pr.first[i];
            out.dst[i] = (c >= 'a' && c <= 'z') ? static_cast<u8>(c - 32) : c;
        }
        return finishAsciiOut(out);
    }

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

    // UTF-8 in => UTF-8 out (ASCII lower-case is closed over ASCII). W4.d.
    if (isUtf8(str) && Allocator::instance().getConfig().utf8_strings_enabled) {
        auto& allocator = Allocator::instance();
        HPointer srcHp = allocator.wrap(str);
        AsciiOut out;
        { Elm::StackRootGuard guard(&srcHp); out = allocAsciiOut(len); }
        auto pr = utf8Bytes(allocator.resolve(srcHp));
        for (u32 i = 0; i < len; ++i) {
            u8 c = pr.first[i];
            out.dst[i] = (c >= 'A' && c <= 'Z') ? static_cast<u8>(c + 32) : c;
        }
        return finishAsciiOut(out);
    }

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

    // UTF-8 in => UTF-8 out: reversing ASCII bytes is a valid ASCII string
    // (astral pairs would be a problem, but the gate forbids them). W4.d.
    if (isUtf8(str) && Allocator::instance().getConfig().utf8_strings_enabled) {
        auto& allocator = Allocator::instance();
        HPointer srcHp = allocator.wrap(str);
        AsciiOut out;
        { Elm::StackRootGuard guard(&srcHp); out = allocAsciiOut(len); }
        auto pr = utf8Bytes(allocator.resolve(srcHp));
        for (u32 i = 0; i < len; ++i) out.dst[i] = pr.first[len - 1 - i];
        return finishAsciiOut(out);
    }

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
    if (isUtf8(str))
        GC_STATS_UTF8_WIDEN_SITE(UTF8_WIDEN_TRIM, static_cast<Header*>(str)->size);
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
    if (isUtf8(str))
        GC_STATS_UTF8_WIDEN_SITE(UTF8_WIDEN_TRIM, static_cast<Header*>(str)->size);
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
    if (isUtf8(str))
        GC_STATS_UTF8_WIDEN_SITE(UTF8_WIDEN_TRIM, static_cast<Header*>(str)->size);
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

    // UTF-8 in => UTF-8 out: repeat one ASCII copy then fan it out. W4.d.
    if (isUtf8(str) && Allocator::instance().getConfig().utf8_strings_enabled) {
        size_t total = static_cast<size_t>(srcLen) * static_cast<size_t>(n);
        auto& allocator = Allocator::instance();
        HPointer srcHp = allocator.wrap(str);
        AsciiOut out;
        { Elm::StackRootGuard guard(&srcHp); out = allocAsciiOut(total); }
        auto pr = utf8Bytes(allocator.resolve(srcHp));
        std::memcpy(out.dst, pr.first, srcLen);
        for (i64 i = 1; i < n; ++i)
            std::memcpy(out.dst + static_cast<size_t>(i) * srcLen, out.dst, srcLen);
        return finishAsciiOut(out);
    }

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
        if (padChar < 0x80 && Allocator::instance().getConfig().utf8_strings_enabled) {
            AsciiOut out = allocAsciiOut(static_cast<size_t>(n));
            for (u32 i = 0; i < out.len; ++i) out.dst[i] = static_cast<u8>(padChar);
            return finishAsciiOut(out);
        }
        alloc::BlankString out = alloc::allocStringBlank(static_cast<size_t>(n));
        for (u32 i = 0; i < out.length; ++i) out.chars[i] = padChar;
        return out.hp;
    }
    u32 len = rawLen(str);
    if (static_cast<i64>(len) >= n) return Allocator::instance().wrap(str);

    size_t pad_count = static_cast<size_t>(n) - len;

    // UTF-8 in + ASCII pad char => UTF-8 out. W4.d.
    if (padChar < 0x80 && isUtf8(str) &&
        Allocator::instance().getConfig().utf8_strings_enabled) {
        auto& allocator = Allocator::instance();
        HPointer srcHp = allocator.wrap(str);
        AsciiOut out;
        { Elm::StackRootGuard guard(&srcHp); out = allocAsciiOut(static_cast<size_t>(n)); }
        for (size_t i = 0; i < pad_count; ++i) out.dst[i] = static_cast<u8>(padChar);
        auto pr = utf8Bytes(allocator.resolve(srcHp));
        std::memcpy(out.dst + pad_count, pr.first, len);
        return finishAsciiOut(out);
    }

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
        if (padChar < 0x80 && Allocator::instance().getConfig().utf8_strings_enabled) {
            AsciiOut out = allocAsciiOut(static_cast<size_t>(n));
            for (u32 i = 0; i < out.len; ++i) out.dst[i] = static_cast<u8>(padChar);
            return finishAsciiOut(out);
        }
        alloc::BlankString out = alloc::allocStringBlank(static_cast<size_t>(n));
        for (u32 i = 0; i < out.length; ++i) out.chars[i] = padChar;
        return out.hp;
    }
    u32 len = rawLen(str);
    if (static_cast<i64>(len) >= n) return Allocator::instance().wrap(str);

    // UTF-8 in + ASCII pad char => UTF-8 out. W4.d.
    if (padChar < 0x80 && isUtf8(str) &&
        Allocator::instance().getConfig().utf8_strings_enabled) {
        auto& allocator = Allocator::instance();
        HPointer srcHp = allocator.wrap(str);
        AsciiOut out;
        { Elm::StackRootGuard guard(&srcHp); out = allocAsciiOut(static_cast<size_t>(n)); }
        auto pr = utf8Bytes(allocator.resolve(srcHp));
        std::memcpy(out.dst, pr.first, len);
        for (u32 i = len; i < out.len; ++i) out.dst[i] = static_cast<u8>(padChar);
        return finishAsciiOut(out);
    }

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
    // UTF-8 form: bytes are already ASCII (HEAP_032) — memcpy, no widen.
    if (isUtf8(str)) {
        auto pr = utf8Bytes(str);
        if (pr.second > cap) return false;
        std::memcpy(buf, pr.first, pr.second);
        *out_len = pr.second;
        return true;
    }
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
    (void)ec;
    // Decimal digits + optional '-' are pure ASCII, so emit a UTF-8 leaf.
    return makeUtf8LeafFromBytes(reinterpret_cast<const u8*>(buf),
                                 static_cast<u32>(end - buf));
}

/**
 * Converts a float to a string.
 */
inline HPointer fromFloat(f64 n) {
    // All outputs are pure ASCII, so emit UTF-8 leaves.
    if (std::isnan(n))
        return makeUtf8LeafFromBytes(reinterpret_cast<const u8*>("NaN"), 3);
    if (std::isinf(n)) {
        return n > 0
                   ? makeUtf8LeafFromBytes(reinterpret_cast<const u8*>("Infinity"), 8)
                   : makeUtf8LeafFromBytes(reinterpret_cast<const u8*>("-Infinity"), 9);
    }
    if (n == 0.0)
        return makeUtf8LeafFromBytes(reinterpret_cast<const u8*>("0"), 1);

    // Use std::to_chars for the shortest round-trip representation,
    // matching JavaScript/Elm's Number.prototype.toString() behavior.
    char buf[32];
    auto [ptr, ec] = std::to_chars(buf, buf + sizeof(buf), n);
    (void)ec;
    return makeUtf8LeafFromBytes(reinterpret_cast<const u8*>(buf),
                                 static_cast<u32>(ptr - buf));
}

/**
 * Converts a character to a single-character string. ASCII chars produce a
 * 1-byte UTF-8 leaf — fromChar was the dominant UTF-16 "seed" that made
 * otherwise-UTF-8 append/concat chains widen (98.4% of measured widen events;
 * see design_docs/utf8-widen-attribution.md). Non-ASCII keeps the UTF-16 leaf.
 */
inline HPointer fromChar(u16 c) {
    if (c < 0x80 && Allocator::instance().getConfig().utf8_strings_enabled) {
        u8 b = static_cast<u8>(c);
        return makeUtf8LeafFromBytes(&b, 1);
    }
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

    // ASCII char onto a UTF-8 string => UTF-8 result (seed elimination, see
    // plans/utf16-seed-elimination.md). Same wrap/guard/re-resolve discipline
    // as append's byte arm.
    if (c < 0x80 && isUtf8(str) && allocator.getConfig().utf8_strings_enabled) {
        HPointer srcHp = allocator.wrap(str);
        AsciiOut out;
        { Elm::StackRootGuard guard(&srcHp); out = allocAsciiOut(total_len); }
        out.dst[0] = static_cast<u8>(c);
        auto pr = utf8Bytes(allocator.resolve(srcHp));
        std::memcpy(out.dst + 1, pr.first, pr.second);
        return finishAsciiOut(out);
    }

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
    if (hdr->tag == Tag_StringUtf8View || hdr->tag == Tag_StringUtf8Leaf) {
        auto pr = utf8Bytes(str);
        GC_STATS_UTF8_WIDEN(pr.second);
        std::u16string out(pr.second, u'\0');
        if (pr.second > 0)
            Utf8::widenAscii(pr.first, pr.second, reinterpret_cast<u16*>(out.data()));
        return out;
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
        } else if (h->tag == Tag_StringUtf8View || h->tag == Tag_StringUtf8Leaf) {
            auto pr = utf8Bytes(top);
            GC_STATS_UTF8_WIDEN_SITE(UTF8_WIDEN_ROPE_CHILD, pr.second);
            for (u32 k = 0; k < pr.second; ++k)
                dst[k] = static_cast<char16_t>(pr.first[k]);
            dst += pr.second;
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

// ---------------------------------------------------------------------------
// Mixed-width segment collection, used by equal/compare when a rope (which may
// mix UTF-8 and UTF-16 children) is involved. Pointers are gathered via
// forEachSegmentEx and are STABLE (no widening buffer), so retaining them
// across the lockstep loop is safe — equal/compare never allocate in between.
// ---------------------------------------------------------------------------
struct SegView {
    const void* p;
    u32 len;
    bool isU16;
};

inline void collectSegs(void* str, std::vector<SegView>& out) {
    forEachSegmentEx(
        str,
        [&](const u16* p, u32 n) { out.push_back(SegView{p, n, true}); },
        [&](const u8* p, u32 n) { out.push_back(SegView{p, n, false}); });
}

// Reads logical unit `i` of a segment, widening ASCII bytes to a u16 unit.
inline u16 segElemAt(const SegView& s, u32 i) {
    return s.isU16 ? static_cast<const u16*>(s.p)[i]
                   : static_cast<u16>(static_cast<const u8*>(s.p)[i]);
}

/**
 * Compares two strings for equality. Pure leaf+leaf path is unchanged
 * (memcmp on chars[]). Both-UTF-8 compares bytes directly. Otherwise a
 * width-aware lockstep over collected segments handles slices, ropes, and any
 * UTF-8/UTF-16 mixture without flattening.
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

    // Both UTF-8: byte memcmp. ASCII => byte value == unit value, and sizes
    // (== byteLen) are already known equal.
    if (isUtf8(a) && isUtf8(b)) {
        auto pa = utf8Bytes(a);
        auto pb = utf8Bytes(b);
        return pa.second == pb.second &&
               std::memcmp(pa.first, pb.first, pa.second) == 0;
    }

    // Single-segment-on-each-side fast path (pure UTF-16): leaf / slice /
    // large-split-header without flattening. UTF-8 forms return {nullptr,0}
    // from singleSegmentView, so at least one side reaching here as UTF-8
    // falls through to the width-aware walk below.
    auto [aPtr, aLen] = singleSegmentView(a);
    auto [bPtr, bLen] = singleSegmentView(b);
    if (aPtr && bPtr) {
        return std::memcmp(aPtr, bPtr, ha->size * sizeof(u16)) == 0;
    }

    // General width-aware lockstep: handles ropes that may mix UTF-8 and
    // UTF-16 children, and any UTF-8-vs-UTF-16 pairing. Stable pointers,
    // allocation-free beyond two small segment vectors.
    std::vector<SegView> aSegs, bSegs;
    aSegs.reserve(16); bSegs.reserve(16);
    collectSegs(a, aSegs);
    collectSegs(b, bSegs);

    size_t ai = 0, bi = 0;
    u32 aOff = 0, bOff = 0;
    while (ai < aSegs.size() && bi < bSegs.size()) {
        if (segElemAt(aSegs[ai], aOff) != segElemAt(bSegs[bi], bOff)) return false;
        if (++aOff == aSegs[ai].len) { ++ai; aOff = 0; }
        if (++bOff == bSegs[bi].len) { ++bi; bOff = 0; }
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

    // Both UTF-8: byte compare. ASCII => byte order == UTF-16 unit order, so
    // memcmp's sign is the correct lexicographic sign.
    if (isUtf8(a) && isUtf8(b)) {
        auto pa = utf8Bytes(a);
        auto pb = utf8Bytes(b);
        size_t min_len = std::min<size_t>(pa.second, pb.second);
        int c = std::memcmp(pa.first, pb.first, min_len);
        if (c != 0) return c;
        return static_cast<int>(pa.second) - static_cast<int>(pb.second);
    }

    // Single-segment-on-each-side fast path (pure UTF-16).
    auto [aPtr, aLen] = singleSegmentView(a);
    auto [bPtr, bLen] = singleSegmentView(b);
    if (aPtr && bPtr) {
        size_t min_len = std::min<size_t>(aLen, bLen);
        int c = charCompare(aPtr, bPtr, min_len);
        if (c != 0) return c;
        return static_cast<int>(aLen) - static_cast<int>(bLen);
    }

    // General width-aware lockstep (ropes possibly mixing UTF-8 / UTF-16, or
    // any UTF-8-vs-UTF-16 pairing). ASCII bytes widen to u16 units, matching
    // UTF-16 unit order.
    std::vector<SegView> aSegs, bSegs;
    aSegs.reserve(16); bSegs.reserve(16);
    collectSegs(a, aSegs);
    collectSegs(b, bSegs);

    size_t ai = 0, bi = 0;
    u32 aOff = 0, bOff = 0;
    while (ai < aSegs.size() && bi < bSegs.size()) {
        u16 ca = segElemAt(aSegs[ai], aOff);
        u16 cb = segElemAt(bSegs[bi], bOff);
        if (ca != cb) return static_cast<int>(ca) - static_cast<int>(cb);
        if (++aOff == aSegs[ai].len) { ++ai; aOff = 0; }
        if (++bOff == bSegs[bi].len) { ++bi; bOff = 0; }
    }
    return static_cast<int>(ha->size) - static_cast<int>(hb->size);
}

} // namespace StringOps
} // namespace Elm

#endif // ECO_STRING_OPS_H
