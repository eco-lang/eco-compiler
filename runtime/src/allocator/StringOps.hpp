// Elm's `String` operations, written once over every form a String can take on the heap.
//
// A String is not one kind of object. `Heap.hpp` defines six forms, and a String value may be any
// of them:
//
// - a UTF-16 leaf (`ElmString`, `Tag_String`), which holds its UTF-16 code units;
// - a large String (`LargeStringHeader`), whose units are in a pinned body that never moves;
// - a slice (`ElmStringSlice`), a run of the units of a UTF-16 leaf or large String, shared rather
//   than copied;
// - a rope (`ElmStringRope`), the concatenation of two Strings of any form;
// - a UTF-8 leaf (`ElmStringUtf8Leaf`), which holds bytes that are all below 0x80;
// - a UTF-8 view (`ElmStringUtf8View`), such bytes shared from a ByteBuffer, large Bytes or UTF-8
//   leaf.
//
// The first two are the flat UTF-16 forms, and the last two are the UTF-8 forms. A UTF-8 form's
// bytes are ASCII, so each byte is one UTF-16 unit. In every form, therefore, `header.size` is the
// length in UTF-16 units, and a position in a String is an index in UTF-16 units. The empty String
// is the Empty constant, never an object of length 0.
//
// The forms let common operations avoid copying. `append` joins long Strings into a rope, `slice`
// shares a long run as a slice or UTF-8 view, and ASCII text takes one byte per character in a
// UTF-8 form. Most of this file follows from that: each operation dispatches on the forms of its
// operands, takes a byte path when every operand is a UTF-8 form, and otherwise widens, which means
// reading the bytes as UTF-16 units. A UTF-8 form is created only when the `utf8_strings_enabled`
// setting of `HeapConfig` is on. Several operations that build an all-ASCII result through UTF-16
// store it as a UTF-8 form again, so that one UTF-16 operand does not make every later operation on
// the result widen too.
//
// A Char is a Char value as `CharValue.hpp` defines it: a code point or, with
// `ECO_CHAR_CASE_EXPANSION` on, an encoded case-mapping result that stands for two or three UTF-16
// units. Operations that turn a String into Chars decode code points, and combine two units only
// when they are a valid surrogate pair; a lone surrogate becomes a Char of its own unit value.
// Operations that turn Chars into a String write each value's whole expansion.
//
// Any allocation may move a nursery object. A function that takes a String as `void*` takes the
// address of a String object, which the caller has resolved and which is valid only until the next
// allocation. Most such functions also accept null and treat it as the empty String; those that do
// not say so. A function that allocates keeps the operands it still needs alive across its own
// allocations, so the caller need not root them for its sake, except where its comment says
// otherwise; the caller must root any other HPointer it holds across the call. A raw pointer
// into a String's payload that this file hands out is valid until the next allocation, except that
// one into a large String's or large Bytes' body stays valid while that object is live.

#ifndef ECO_STRING_OPS_H
#define ECO_STRING_OPS_H

#include "Allocator.hpp"
#include "CaseMap.hpp"
#include "HeapHelpers.hpp"
#include "Utf8.hpp"
#include <algorithm>
#include <cctype>
#include <cstring>
#include <charconv>
#include <cmath>
#include <cstdlib>
#include <limits>
#include <sstream>
#include <iomanip>
#include <utility>
#include <vector>

namespace Elm {
namespace StringOps {

// ============================================================================
// Form predicates and accessors
// ============================================================================
//
// None of these accepts null: each reads the header of `obj`, which must be a String object.

// Returns whether `obj` is a flat UTF-16 form: a UTF-16 leaf or a large String. A UTF-8 leaf is
// not one.
inline bool isLeaf(void* obj) {
    Tag t = alloc::getTag(obj);
    return t == Tag_String || t == Tag_LargeStringHeader;
}

// Returns whether `obj` is a slice.
inline bool isSlice(void* obj) { return alloc::getTag(obj) == Tag_StringSlice; }

// Returns whether `obj` is a rope.
inline bool isRope(void* obj) { return alloc::getTag(obj) == Tag_StringRope; }

// Returns whether `obj` is a UTF-8 view.
inline bool isUtf8View(void* obj) { return alloc::getTag(obj) == Tag_StringUtf8View; }
// Returns whether `obj` is a UTF-8 leaf.
inline bool isUtf8Leaf(void* obj) { return alloc::getTag(obj) == Tag_StringUtf8Leaf; }
// Returns whether `obj` is either UTF-8 form, a leaf or a view.
inline bool isUtf8(void* obj) {
    Tag t = alloc::getTag(obj);
    return t == Tag_StringUtf8View || t == Tag_StringUtf8Leaf;
}

// Returns the ASCII bytes of the UTF-8 form `o` and their count, which is also its length.
//
// `o` must be a UTF-8 form; anything else is read as a view. The pointer is valid until the next
// allocation, or, when a view's base is large Bytes, while that base is live. A view whose base
// is the null word gives null and 0.
inline std::pair<const u8*, u32> utf8Bytes(void* o) {
    Header* hdr = static_cast<Header*>(o);
    if (hdr->tag == Tag_StringUtf8Leaf) {
        ElmStringUtf8Leaf* l = static_cast<ElmStringUtf8Leaf*>(o);
        return {l->bytes, l->header.size};
    }
    // Tag_StringUtf8View
    ElmStringUtf8View* v = static_cast<ElmStringUtf8View*>(o);
    void* base = Allocator::resolveFast(v->base);
    if (!base) return {nullptr, 0};
    Header* bh = static_cast<Header*>(base);
    const u8* p;
    if (bh->tag == Tag_StringUtf8Leaf) {
        p = static_cast<ElmStringUtf8Leaf*>(base)->bytes;
    } else if (bh->tag == Tag_LargeByteHeader) {
        p = largeBytesData(static_cast<LargeByteHeader*>(base));
    } else {
        // Tag_ByteBuffer
        p = static_cast<ByteBuffer*>(base)->bytes;
    }
    return {p + v->offset, v->byteLen};
}

// Returns the length of `obj` in UTF-16 units, which every form keeps in `header.size`.
inline u32 rawLen(void* obj) { return static_cast<Header*>(obj)->size; }

// Returns the height of `obj` as a rope tree: a rope's stored height, and 0 for every other form.
inline u32 heightOf(void* obj) {
    Tag t = alloc::getTag(obj);
    if (t == Tag_StringRope) return static_cast<ElmStringRope*>(obj)->height;
    return 0;
}

// Returns the number of flat pieces in `obj`: a rope's stored leaf count, and 1 for every other
// form.
inline u32 leafCountOf(void* obj) {
    Tag t = alloc::getTag(obj);
    if (t == Tag_StringRope) return static_cast<ElmStringRope*>(obj)->leafCount;
    return 1;
}

// The size thresholds below (`string_flatten_limit`, `string_tiny_slice_limit`) and the
// `utf8_strings_enabled` switch are settings of `HeapConfig`, read through
// `Allocator::instance().getConfig()`.

// ============================================================================
// Constructors of the forms, and flattening
// ============================================================================

// Returns a new UTF-16 String holding the `len` units at `data`, or the Empty constant when `len`
// is 0. A GC point; as for `alloc::allocString`, `data` must not point into the collected heap.
HPointer makeLeafFromBuffer(const u16* data, u32 len);

// Returns a new slice of the `len` units of `base` starting at unit `offset`, or the Empty
// constant when `len` is 0.
//
// `base` must be a UTF-16 leaf or a large String, and the run must lie inside it; nothing here
// checks either. `base` is kept alive across the allocation. A GC point.
HPointer makeSlice(HPointer base, u32 offset, u32 len);

// Returns a new rope that is `left` followed by `right`, or one of them alone when the other is
// empty (the Empty constant, another embedded constant, or of length 0), or the Empty constant
// when both are.
//
// The rope's height is one more than its taller child's, and its leaf count is the sum of its
// children's. Both arguments are kept alive across the allocation. A GC point.
HPointer makeRope(HPointer left, HPointer right);

// Returns a new UTF-8 view of the `len` bytes of `base` starting at byte `byteOffset`, or the Empty
// constant when `len` is 0.
//
// `base` must be a ByteBuffer, large Bytes or UTF-8 leaf, or a Bytes slice or UTF-8 view of one;
// a slice or view is replaced by its own base, with the offsets added, so a view's base is never
// itself a slice or view. The bytes must be ASCII and lie inside the base; nothing here checks
// either. `base` is kept alive across the allocation. A GC point.
HPointer makeUtf8View(HPointer base, u32 byteOffset, u32 len);

// Returns a new String holding a copy of the `len` bytes at `bytes`, or the Empty constant when
// `len` is 0.
//
// The bytes must all be below 0x80; only `ECO_HEAP_VALIDATE` builds check it. The result is a
// UTF-8 leaf, except that it is a UTF-16 String when UTF-8 Strings are disabled or when the leaf
// would reach the large-object threshold, since there is no large UTF-8 form. `bytes` may point
// into the collected heap: it is copied before the allocation. A GC point.
HPointer makeUtf8LeafFromBytes(const u8* bytes, u32 len);

/**
 * A UTF-8 form allocated but not yet written: the means by which an operation that knows its
 * result is ASCII produces it in a UTF-8 form.
 *
 * `allocAsciiOut(len)` makes one; the caller writes exactly `len` bytes, all below 0x80, to `dst`,
 * and passes it to `finishAsciiOut` for the String. `dst` is into a UTF-8 leaf when the leaf would
 * be below the large-object threshold, and into the pinned body of new large Bytes otherwise. A
 * leaf can move, so the caller must not allocate between the two calls. The caller must also check
 * that UTF-8 Strings are enabled before making one, because nothing here does.
 */
struct AsciiOut {
    HPointer hp;    // The leaf, when `isLeaf`, or else the large Bytes the view will refer to.
    u8* dst;        // Where the `len` bytes are written. Not owned.
    u32 len;
    bool isLeaf;    // True when `dst` is in a UTF-8 leaf; false when it is in large Bytes.
};
// Allocates an `AsciiOut` for `len` bytes. `len` must be more than 0, which is asserted, and at
// most 0xFFFFFFFF. A GC point.
AsciiOut allocAsciiOut(size_t len);
// Returns the String whose bytes were written to `out`: the leaf itself, or a new UTF-8 view of all
// the large Bytes, which allocates and is then a GC point. `out.dst` must not be used afterwards.
// Only `ECO_HEAP_VALIDATE` builds check that the bytes are below 0x80.
HPointer finishAsciiOut(const AsciiOut& out);

// Returns `s` as a flat UTF-16 String with the same units.
//
// `s` itself is returned when it is a UTF-16 leaf, a large String or an embedded constant, and
// the Empty constant when it is of length 0. Any other form is copied into a new UTF-16 String,
// which is a large String when it reaches the large-object threshold. A GC point.
HPointer flattenToLeaf(HPointer s);

// Returns `s` in a form an operation needing random access can index directly, unless it is too
// long to copy.
//
// A UTF-16 leaf, a large String or an embedded constant is returned as it is. A UTF-8 form is
// always copied into a UTF-16 String, as `flattenToLeaf` does. A slice or rope is copied when its
// length is at most `string_flatten_limit`, and otherwise returned as it is, so the caller must
// still handle a slice or rope. A GC point.
HPointer ensureFlat(HPointer s);

// ============================================================================
// Length and Character Access
// ============================================================================

// Returns the length of `str` in UTF-16 units, as Elm's `String.length` counts it; 0 for null.
inline i64 length(void* str) {
    if (!str) return 0;
    return static_cast<i64>(rawLen(str));
}

// Returns whether `ptr` is the Empty constant, which is how the empty String is held.
inline bool isEmpty(HPointer ptr) {
    return alloc::isConstant(ptr) && Elm::alloc::isEmptyString(ptr);
}

// Declared here so that the inline operations below can copy a String into C++ memory before they
// allocate; the contract is on the definition, under "Utilities".
inline std::u16string toStdU16String(void* str);

// ============================================================================
// Segment visitors
// ============================================================================
//
// A segment is a run of a String's contents that lies contiguously in memory: all of a flat or UTF-8
// form, or one such piece of a rope. Visiting the segments in order reads a String of any form
// without copying it.

// Calls `u16cb(p, n)` for each UTF-16 segment of `str` and `u8cb(p, n)` for each UTF-8 segment, in
// order, skipping empty ones; for null it calls neither.
//
// The pointers are into the Strings themselves, valid until the next allocation (or while the
// String is live, for a large String's body), so a callback may keep them while no allocation
// happens. A callback must not allocate while the walk is in progress, since the rest of the walk
// reads `str` through raw pointers. A rope is walked with an explicit stack in a `std::vector`, so
// a deep rope uses no recursion; that vector is the walk's only allocation, and it is in C++
// memory, not the Elm heap.
template <class F16, class F8>
inline void forEachSegmentEx(void* str, F16&& u16cb, F8&& u8cb) {
    if (!str) return;
    Header* hdr = static_cast<Header*>(str);

    if (hdr->tag == Tag_String) {
        ElmString* s = static_cast<ElmString*>(str);
        if (s->header.size > 0) u16cb(static_cast<const u16*>(s->chars), s->header.size);
        return;
    }
    if (hdr->tag == Tag_LargeStringHeader) {
        LargeStringHeader* h = static_cast<LargeStringHeader*>(str);
        if (h->header.size > 0)
            u16cb(static_cast<const u16*>(largeStringChars(h)), h->header.size);
        return;
    }
    if (hdr->tag == Tag_StringSlice) {
        ElmStringSlice* slc = static_cast<ElmStringSlice*>(str);
        if (slc->header.size == 0) return;
        void* base = Allocator::resolveFast(slc->base);
        if (!base) return;
        u16cb(static_cast<const u16*>(flatStringChars(base) + slc->offset), slc->header.size);
        return;
    }
    if (hdr->tag == Tag_StringUtf8View || hdr->tag == Tag_StringUtf8Leaf) {
        auto pr = utf8Bytes(str);
        if (pr.second > 0) u8cb(pr.first, pr.second);
        return;
    }
    if (hdr->tag != Tag_StringRope) return;

    // In-order walk: the right child is pushed first so that the left is visited first.
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
            if (lh->header.size > 0)
                u16cb(static_cast<const u16*>(largeStringChars(lh)), lh->header.size);
        } else if (h->tag == Tag_StringSlice) {
            ElmStringSlice* slc = static_cast<ElmStringSlice*>(top);
            if (slc->header.size > 0) {
                void* base = Allocator::resolveFast(slc->base);
                if (base) {
                    {
                        u16cb(static_cast<const u16*>(flatStringChars(base) + slc->offset),
                              slc->header.size);
                    }
                }
            }
        } else if (h->tag == Tag_StringUtf8View || h->tag == Tag_StringUtf8Leaf) {
            auto pr = utf8Bytes(top);
            if (pr.second > 0) u8cb(pr.first, pr.second);
        } else if (h->tag == Tag_StringRope) {
            ElmStringRope* r = static_cast<ElmStringRope*>(top);
            void* rightObj = Allocator::resolveFast(r->right);
            void* leftObj  = Allocator::resolveFast(r->left);
            if (rightObj) stack.push_back(rightObj);
            if (leftObj)  stack.push_back(leftObj);
        }
    }
}

// Calls `cb(p, n)` with the UTF-16 units of `str`, in order, as `forEachSegmentEx` does, but with
// each UTF-8 segment widened to UTF-16 in pieces of at most 512 units.
//
// For a widened piece, `p` points into a buffer on this function's stack and is valid only during
// that call of `cb`. A caller that keeps segment pointers must use `forEachSegmentEx`. `cb` must
// not allocate.
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

// Writes the UTF-16 units of `str` to `dst`, which must have room for `rawLen(str)` of them.
// Writes nothing for null. Does not allocate on the Elm heap.
inline void copyInto(void* str, u16* dst) {
    forEachSegment(str, [&](const u16* p, u32 n) {
        std::memcpy(dst, p, n * sizeof(u16));
        dst += n;
    });
}

// Returns the UTF-16 unit at index `index` of `str`, or 0 when `str` is null or `index` is out of
// range.
//
// A rope is descended by comparing `index` with its left child's length, without recursion, so the
// cost grows with the rope's depth. Does not allocate.
inline u16 charAt(void* str, i64 index) {
    if (!str) return 0;
    auto& allocator = Allocator::instance();

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
            LargeStringHeader* h = static_cast<LargeStringHeader*>(str);
            return largeStringChars(h)[index];
        }
        if (hdr->tag == Tag_StringSlice) {
            ElmStringSlice* slc = static_cast<ElmStringSlice*>(str);
            void* base = allocator.resolve(slc->base);
            if (!base) return 0;
            // The base may be a large String; flatStringChars reads either flat form.
            return flatStringChars(base)[slc->offset + index];
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
// Between UTF-16 units and Chars
// ============================================================================
//
// Decoding gives only code points, never an encoded case-mapping value, and combines only a valid
// high-then-low surrogate pair. A lone surrogate decodes to its own unit value and encodes back to
// that one unit, so decoding a String and encoding the Chars again gives the same units.

// Returns whether the UTF-16 unit `u` is a high (leading) surrogate.
inline bool isHighSurrogate(u32 u) { return u >= 0xD800u && u <= 0xDBFFu; }
// Returns whether the UTF-16 unit `u` is a low (trailing) surrogate.
inline bool isLowSurrogate(u32 u) { return u >= 0xDC00u && u <= 0xDFFFu; }

// Returns the code point that the surrogate pair `hi`, `lo` encodes. Neither is checked.
inline u32 combineSurrogates(u32 hi, u32 lo) {
    return 0x10000u + ((hi - 0xD800u) << 10) + (lo - 0xDC00u);
}

// Returns the code point that starts at `p[i]` and advances `i` past it, by 2 for a valid
// surrogate pair and by 1 otherwise. `i` must be less than `len`.
inline u32 nextCodePoint(const u16* p, size_t len, size_t& i) {
    u32 u = p[i++];
    if (isHighSurrogate(u) && i < len && isLowSurrogate(p[i])) {
        return combineSurrogates(u, p[i++]);
    }
    return u;
}

// Returns the code point that ends just before `p[i]` and moves `i` back to its first unit. `i`
// must be more than 0.
//
// A low surrogate combines only with a high surrogate before it, so stepping back from the end
// gives the code points that `nextCodePoint` gives from the start, in reverse.
inline u32 prevCodePoint(const u16* p, size_t& i) {
    u32 u = p[--i];
    if (isLowSurrogate(u) && i > 0 && isHighSurrogate(p[i - 1])) {
        return combineSurrogates(p[--i], u);
    }
    return u;
}

// Returns how many UTF-16 units `encodeCodePoint` writes for the Char value `cp`, from 1 to
// `CharValue::kMaxCharUnits`.
inline u32 codePointUnits(u32 cp) { return CaseMap::units(cp); }

// Writes the Char value `cp` to `out` as UTF-16 units and returns how many it wrote, as
// `CaseMap::writeUnits` does. `out` must have room for `CharValue::kMaxCharUnits` units.
inline u32 encodeCodePoint(u32 cp, u16* out) { return CaseMap::writeUnits(cp, out); }

// Appends the UTF-16 units of the Char value `cp` to `out`.
inline void appendCodePoint(std::vector<u16>& out, u32 cp) {
    u16 buf[CharValue::kMaxCharUnits];
    u32 n = encodeCodePoint(cp, buf);
    out.insert(out.end(), buf, buf + n);
}

// Returns the code point that starts at unit `i` of `str`, whose length is `len`, and advances `i`
// as `nextCodePoint` does. Reads through `charAt`, so works on any form without allocating.
inline u32 codePointAt(void* str, size_t len, size_t& i) {
    u32 u = charAt(str, static_cast<i64>(i++));
    if (isHighSurrogate(u) && i < len) {
        u32 lo = charAt(str, static_cast<i64>(i));
        if (isLowSurrogate(lo)) { ++i; return combineSurrogates(u, lo); }
    }
    return u;
}

// ============================================================================
// Concatenation
// ============================================================================

// Returns `a` followed by `b`.
//
// When either is null or empty, the other is returned as it is. When the total length is at most
// `string_flatten_limit` the result is a new copy: a UTF-8 form when UTF-8 Strings are enabled and
// either both are UTF-8 forms or the units are all ASCII, and a UTF-16 String otherwise.
// Above that length the result is a rope sharing `a` and `b`, built without copying either. A GC
// point.
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
        // Both UTF-8: join the bytes. Mixed forms fall through to the UTF-16 copy below.
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
        // An all-ASCII result goes back to a UTF-8 form, so that a UTF-16 operand holding only
        // ASCII does not make every later append to the result widen. `data` is C++ memory, so
        // it stays valid across the allocation.
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

    // makeRope keeps its HPointer arguments alive across its allocation; the raw `a` and `b`
    // would not be updated by a collection.
    auto& allocator = Allocator::instance();
    HPointer aHp = allocator.wrap(a);
    HPointer bHp = allocator.wrap(b);
    return makeRope(aHp, bHp);
}

// Returns the Strings of the Elm list `stringList` joined in order.
//
// The result is the Empty constant when the total length is 0. Up to `string_flatten_limit` it is
// a new copy: a UTF-8 form when UTF-8 Strings are enabled and either every non-empty element is
// one or the copied units are all ASCII, and a UTF-16 String otherwise. Above that length it
// shares the non-empty elements, as a balanced tree of ropes or, when there is only one, that
// element itself. A GC point.
HPointer concat(HPointer stringList);

// Returns the Strings of the Elm list `stringList` joined in order, with `sep` between each two
// of them, empty ones included. Null `sep` is the empty String.
//
// The result is the Empty constant for an empty list or a total length of 0. Otherwise it is
// formed as `concat`'s is, except that the UTF-8 copy also needs `sep` to be empty or a UTF-8
// form. A GC point.
HPointer join(void* sep, HPointer stringList);

// ============================================================================
// Slicing
// ============================================================================

// Returns the units of `str` from index `start` up to but not including `end`, as Elm's
// `String.slice` does: a negative index counts from the end, and both are then clamped to the
// String.
//
// An empty range gives the Empty constant, and the whole String gives `str` itself. A range of at
// most `string_tiny_slice_limit` units is copied into a new String. That is a UTF-8 leaf when the
// source is a UTF-8 form, or when the source is not a rope, UTF-8 Strings are enabled and the range
// is at most 512 units, all ASCII; otherwise it is a UTF-16 String. A longer range shares the
// source: it is a UTF-8 view of a UTF-8 form, a slice of a flat form or of a slice's base, and,
// for a rope, the slice of the child that holds the range, or a new rope joining the slices of
// both children when the range spans them. A GC point.
HPointer slice(void* str, i64 start, i64 end);

// Returns the first `n` units of `str`, or the Empty constant when `n` is not positive. Formed as
// by `slice`.
inline HPointer left(void* str, i64 n) {
    if (n <= 0) return alloc::emptyString();
    return slice(str, 0, n);
}

// Returns the last `n` units of `str`, or the Empty constant when `n` is not positive. Formed as
// by `slice`.
inline HPointer right(void* str, i64 n) {
    if (n <= 0) return alloc::emptyString();
    if (!str) return alloc::emptyString();
    i64 len = static_cast<i64>(rawLen(str));
    return slice(str, len - n, len);
}

// Returns `str` without its first `n` units, formed as by `slice`. When `n` is not positive it
// returns `str` itself, so `str` must not then be null.
inline HPointer dropLeft(void* str, i64 n) {
    if (n <= 0) return Allocator::instance().wrap(str);
    if (!str) return alloc::emptyString();
    i64 len = static_cast<i64>(rawLen(str));
    return slice(str, n, len);
}

// Returns `str` without its last `n` units, formed as by `slice`. When `n` is not positive it
// returns `str` itself, so `str` must not then be null.
inline HPointer dropRight(void* str, i64 n) {
    if (n <= 0) return Allocator::instance().wrap(str);
    if (!str) return alloc::emptyString();
    i64 len = static_cast<i64>(rawLen(str));
    return slice(str, 0, len - n);
}

// ============================================================================
// Searching
// ============================================================================

// Returns the UTF-16 units of `str` and their count when they lie contiguously in memory, which is
// when `str` is a UTF-16 leaf, a large String or a slice; otherwise null and 0, as for null, a
// rope or a UTF-8 form.
//
// The pointer is valid until the next allocation, or, into a large String's body, while that
// String is live.
inline std::pair<const u16*, u32> singleSegmentView(void* str) {
    if (!str) return {nullptr, 0};
    Header* hdr = static_cast<Header*>(str);
    if (hdr->tag == Tag_String) {
        ElmString* s = static_cast<ElmString*>(str);
        return {s->chars, s->header.size};
    }
    if (hdr->tag == Tag_LargeStringHeader) {
        LargeStringHeader* h = static_cast<LargeStringHeader*>(str);
        return {largeStringChars(h), h->header.size};
    }
    if (hdr->tag == Tag_StringSlice) {
        ElmStringSlice* slc = static_cast<ElmStringSlice*>(str);
        void* base = Allocator::resolveFast(slc->base);
        if (!base) return {nullptr, 0};
        return {flatStringChars(base) + slc->offset, slc->header.size};
    }
    return {nullptr, 0};
}

// Returns whether the units of `needle` occur in `haystack`. A null `needle` occurs in anything, and
// a non-null one in no null `haystack`. Does not allocate on the Elm heap.
inline bool contains(void* needle, void* haystack) {
    if (!needle) return true;
    if (!haystack) return false;

    size_t needle_len = rawLen(needle);
    size_t haystack_len = rawLen(haystack);
    if (needle_len == 0) return true;
    if (needle_len > haystack_len) return false;

    // Both UTF-8: each byte is one unit, so a byte match is a unit match.
    if (isUtf8(needle) && isUtf8(haystack)) {
        auto n = utf8Bytes(needle);
        auto h = utf8Bytes(haystack);
        return std::search(h.first, h.first + h.second, n.first,
                           n.first + n.second) != h.first + h.second;
    }

    auto [nPtr, nLen] = singleSegmentView(needle);
    auto [hPtr, hLen] = singleSegmentView(haystack);
    if (nPtr && hPtr) {
        return std::search(hPtr, hPtr + hLen, nPtr, nPtr + nLen) != hPtr + hLen;
    }

    // A rope, or a UTF-8 form against a UTF-16 one: compare unit by unit through charAt.
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

// Returns whether the units of `str` begin with those of `prefix`. A null `prefix` begins anything,
// and a non-null one no null `str`. Does not allocate on the Elm heap.
inline bool startsWith(void* prefix, void* str) {
    if (!prefix) return true;
    if (!str) return false;

    size_t prefix_len = rawLen(prefix);
    size_t str_len = rawLen(str);
    if (prefix_len > str_len) return false;
    if (prefix_len == 0) return true;

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

// Returns whether the units of `str` end with those of `suffix`. A null `suffix` ends anything, and
// a non-null one no null `str`. Does not allocate on the Elm heap.
inline bool endsWith(void* suffix, void* str) {
    if (!suffix) return true;
    if (!str) return false;

    size_t suffix_len = rawLen(suffix);
    size_t str_len = rawLen(str);
    if (suffix_len > str_len) return false;
    if (suffix_len == 0) return true;

    size_t offset = str_len - suffix_len;

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

// Returns an Elm list of every unit index at which `needle` occurs in `haystack`, in increasing
// order, overlapping occurrences included.
//
// A null `haystack` gives the empty list. An empty or null `needle` gives every index from 0 to
// the length of `haystack` inclusive. A GC point.
HPointer indexes(void* needle, void* haystack);

// ============================================================================
// Transformation
// ============================================================================

// Returns `str` with each code point mapped by `CaseMap::upper`, when `upper`, or else by
// `CaseMap::lower`, writing each mapped value's whole expansion, so the length may change.
//
// When lowering, a capital sigma (U+03A3) becomes the final form U+03C2 where
// `CaseMap::finalSigmaAt` says it ends a word, and U+03C3 elsewhere. The result is a UTF-8 form
// when it is all ASCII and UTF-8 Strings are enabled, and a UTF-16 String otherwise. `str` is
// copied into C++ memory first, so it need not stay valid. `str` must be non-null and non-empty.
// A GC point.
inline HPointer caseMapGeneral(void* str, bool upper) {
    std::u16string src = toStdU16String(str);
    const u16* p = reinterpret_cast<const u16*>(src.data());
    const size_t n = src.size();
    std::vector<u16> out;
    out.reserve(n + 8);
    u16 acc = 0;
    for (size_t i = 0; i < n;) {
        const size_t start = i;
        const u32 cp = nextCodePoint(p, n, i);
        u32 m;
        if (!upper && cp == 0x3A3u) {
            m = CaseMap::finalSigmaAt(p, n, start, i) ? 0x3C2u : 0x3C3u;
        } else {
            m = upper ? CaseMap::upper(cp) : CaseMap::lower(cp);
        }
        const size_t before = out.size();
        appendCodePoint(out, m);
        for (size_t k = before; k < out.size(); ++k) acc |= out[k];
    }
    if (acc < 0x80 && Allocator::instance().getConfig().utf8_strings_enabled) {
        AsciiOut ao = allocAsciiOut(out.size());
        for (size_t k = 0; k < out.size(); ++k) ao.dst[k] = static_cast<u8>(out[k]);
        return finishAsciiOut(ao);
    }
    return alloc::allocString(out.data(), out.size());
}

// Returns whether every UTF-16 unit of `str` is below 0x80; true for null. A UTF-8 segment is
// taken to be ASCII without being read. Does not allocate on the Elm heap.
inline bool allUnitsAscii(void* str) {
    bool ascii = true;
    forEachSegmentEx(
        str,
        [&](const u16* q, u32 k) {
            for (u32 j = 0; j < k && ascii; ++j) ascii = q[j] < 0x80;
        },
        [](const u8*, u32) {});
    return ascii;
}

// Returns `str` in upper case, as `caseMapGeneral` maps it, or the Empty constant for null or
// empty `str`.
//
// An all-ASCII String needs only `a` to `z` changed: from a UTF-8 form, with UTF-8 Strings
// enabled, the result is a UTF-8 form, and otherwise a UTF-16 String of the same length. A String
// with any other unit goes through `caseMapGeneral`. A GC point.
inline HPointer toUpper(void* str) {
    if (!str) return alloc::emptyString();
    u32 len = rawLen(str);
    if (len == 0) return alloc::emptyString();

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

    // A non-ASCII unit needs the full mapping (which may change the length).
    if (!allUnitsAscii(str)) return caseMapGeneral(str, /*upper=*/true);

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

// Returns `str` in lower case, as `caseMapGeneral` maps it, or the Empty constant for null or
// empty `str`.
//
// An all-ASCII String needs only `A` to `Z` changed: from a UTF-8 form, with UTF-8 Strings
// enabled, the result is a UTF-8 form, and otherwise a UTF-16 String of the same length. A String
// with any other unit goes through `caseMapGeneral`, which treats a word-final capital sigma
// specially. A GC point.
inline HPointer toLower(void* str) {
    if (!str) return alloc::emptyString();
    u32 len = rawLen(str);
    if (len == 0) return alloc::emptyString();

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

    // A non-ASCII unit needs the full mapping (which may change the length).
    if (!allUnitsAscii(str)) return caseMapGeneral(str, /*upper=*/false);

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

// Returns the code points of `str` in reverse order, or the Empty constant for null or empty `str`.
//
// A valid surrogate pair stays in order as one code point; a lone surrogate is moved as a unit. A
// flat UTF-16 String of length 1 is returned as it is. From a UTF-8 form, with UTF-8 Strings
// enabled, the result is a UTF-8 form; otherwise it is a new UTF-16 String. A GC point.
inline HPointer reverse(void* str) {
    if (!str) return alloc::emptyString();
    u32 len = rawLen(str);
    if (len == 0) return alloc::emptyString();
    if (len == 1 && isLeaf(str)) return Allocator::instance().wrap(str);

    // ASCII has no surrogate pairs, so reversing the bytes reverses the code points.
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
    u32 written = 0;
    forEachSegment(allocator.resolve(srcHp), [&](const u16* p, u32 n) {
        // Each segment, reversed, goes just before the segments already written.
        u16* dst = out.chars + (out.length - written - n);
        for (u32 i = 0; i < n; ++i) dst[i] = p[n - 1 - i];
        written += n;
    });
    // A valid pair H L, reversed unit by unit, reads L H, so swap each L H back. A low surrogate
    // pairs only with the unit before it, so this left-to-right scan restores exactly the
    // source's valid pairs and leaves lone surrogates alone.
    for (u32 i = 0; i + 1 < out.length; ++i) {
        if (isLowSurrogate(out.chars[i]) && isHighSurrogate(out.chars[i + 1])) {
            std::swap(out.chars[i], out.chars[i + 1]);
            ++i;
        }
    }
    return out.hp;
}

// Returns whether the UTF-16 unit `c` is whitespace as JavaScript's `\s` (and so `String.prototype.trim`)
// defines it: TAB, LF, VT, FF, CR, SPACE, U+00A0, U+1680, U+2000-U+200A, U+2028, U+2029, U+202F, U+205F,
// U+3000 and U+FEFF. elm/core's String.trim, trimLeft, trimRight and words use this set.
inline bool isJsWhitespace(u16 c) {
    if (c <= 0x20) return c == 0x20 || (c >= 0x09 && c <= 0x0D);
    if (c < 0xA0) return false;
    return c == 0x00A0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200A) || c == 0x2028 ||
           c == 0x2029 || c == 0x202F || c == 0x205F || c == 0x3000 || c == 0xFEFF;
}

// Returns `str` without the whitespace at either end, where whitespace is `isJsWhitespace`'s set, as in
// elm/core's `_String_trim` (`str.trim()`).
//
// The result is `str` itself when there is none to remove, the Empty constant when nothing else
// remains or `str` is null, and otherwise what `slice` gives for the rest. A GC point.
inline HPointer trim(void* str) {
    if (!str) return alloc::emptyString();
    if (isUtf8(str))
        GC_STATS_UTF8_WIDEN_SITE(UTF8_WIDEN_TRIM, static_cast<Header*>(str)->size);
    auto buf = toStdU16String(str);
    size_t len = buf.size();
    if (len == 0) return alloc::emptyString();

    size_t start = 0;
    while (start < len && isJsWhitespace(buf[start])) {
        ++start;
    }
    size_t end = len;
    while (end > start && isJsWhitespace(buf[end - 1])) {
        --end;
    }
    if (start >= end) return alloc::emptyString();
    if (start == 0 && end == len) return Allocator::instance().wrap(str);

    return slice(str, static_cast<i64>(start), static_cast<i64>(end));
}

// Returns `str` without the whitespace at its start, as `trim` defines and forms it.
inline HPointer trimLeft(void* str) {
    if (!str) return alloc::emptyString();
    if (isUtf8(str))
        GC_STATS_UTF8_WIDEN_SITE(UTF8_WIDEN_TRIM, static_cast<Header*>(str)->size);
    auto buf = toStdU16String(str);
    size_t len = buf.size();
    if (len == 0) return alloc::emptyString();

    size_t start = 0;
    while (start < len && isJsWhitespace(buf[start])) {
        ++start;
    }
    if (start == 0) return Allocator::instance().wrap(str);
    if (start >= len) return alloc::emptyString();

    return slice(str, static_cast<i64>(start), static_cast<i64>(len));
}

// Returns `str` without the whitespace at its end, as `trim` defines and forms it.
inline HPointer trimRight(void* str) {
    if (!str) return alloc::emptyString();
    if (isUtf8(str))
        GC_STATS_UTF8_WIDEN_SITE(UTF8_WIDEN_TRIM, static_cast<Header*>(str)->size);
    auto buf = toStdU16String(str);
    size_t len = buf.size();
    if (len == 0) return alloc::emptyString();

    size_t end = len;
    while (end > 0 && isJsWhitespace(buf[end - 1])) {
        --end;
    }
    if (end == len) return Allocator::instance().wrap(str);
    if (end == 0) return alloc::emptyString();

    return slice(str, 0, static_cast<i64>(end));
}

// Returns `n` copies of `str` joined, or the Empty constant when `n` is not positive or `str` is
// null or empty.
//
// The result is always a new copy: a UTF-8 form from a UTF-8 form, with UTF-8 Strings enabled, and
// a UTF-16 String otherwise. Nothing checks that the total length fits in 32 bits. A GC point.
inline HPointer repeat(void* str, i64 n) {
    if (n <= 0 || !str) return alloc::emptyString();

    u32 srcLen = rawLen(str);
    if (srcLen == 0) return alloc::emptyString();

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
    // Copy the source once, then copy that first copy forward.
    copyInto(src, out.chars);
    for (i64 i = 1; i < n; ++i) {
        std::memcpy(out.chars + i * srcLen, out.chars, srcLen * sizeof(u16));
    }
    return out.hp;
}

// Returns `str` with copies of the unit `padChar` before it, enough to make it `n` units long.
//
// `str` is returned as it is when it is already at least `n` units long, and when `n` is not
// positive (the Empty constant, for null `str`). A null `str` gives `n` pad units. A new result
// is a UTF-8 form when `padChar` is below 0x80, UTF-8 Strings are enabled, and `str` is null or a
// UTF-8 form; otherwise it is a UTF-16 String. A GC point.
inline HPointer padLeft(void* str, i64 n, u16 padChar) {
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

    size_t pad_count = static_cast<size_t>(n) - len;

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

// Returns `str` with copies of the unit `padChar` after it, enough to make it `n` units long,
// in the cases and forms `padLeft` describes.
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

// Returns an Elm list of the pieces of `str` between occurrences of `sep`, found from the left
// without overlapping.
//
// A null or empty `str` gives a list holding only the empty String, and a null or empty `sep`
// gives `toList(str)`. When both are UTF-8 forms and UTF-8 Strings are enabled, each piece is what
// `slice` gives for its range, so long pieces share `str`; otherwise each piece is a new UTF-16
// String, or the Empty constant when empty. A GC point.
HPointer split(void* sep, void* str);

// Returns an Elm list of one-Char Strings, one for each code point of `str` in order, each formed
// as `fromChar` forms it. A null or empty `str` gives the empty list. A GC point.
HPointer toList(void* str);

// ============================================================================
// Conversion
// ============================================================================

// Copies the units of `str` to `buf` as `char`s and sets `*out_len` to how many there are, when
// they are all below 0x80 and number at most `cap`; returns whether it did.
//
// `str` must not be null. On failure `*out_len` is unchanged and `buf` may hold a partial copy.
// No terminating nul is written. Does not allocate on the Elm heap.
inline bool narrowAsciiToStack(void* str, char* buf, size_t cap, size_t* out_len) {
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

// Returns `Just` the Int that `str` spells in decimal, or `Nothing`.
//
// It gives `Just` only when `str` is ASCII, at most 64 units long, and an optional `+` or `-` followed
// by at least one decimal digit and nothing else, with a value that fits in 64 bits, as elm/core's
// `_String_toInt` accepts (`"+5"` is `Just 5`; `"+"`, `"-"`, `"+-5"` and `"++5"` are `Nothing`);
// anything else, including a null or empty `str` or spaces, gives `Nothing`. A GC point.
inline HPointer toInt(void* str) {
    if (!str) return alloc::nothing();
    u32 len = rawLen(str);
    if (len == 0) return alloc::nothing();

    // A 64-bit integer with its sign is at most 20 characters.
    char buf[64];
    size_t narrowed_len;
    if (len > sizeof(buf) || !narrowAsciiToStack(str, buf, sizeof(buf), &narrowed_len)) {
        return alloc::nothing();
    }

    // std::from_chars accepts a leading `-` but not `+`, so a `+` is skipped here; after either sign a
    // digit must follow, or "+-5" would parse as -5.
    const char* first = buf;
    const char* digits = buf;
    if (buf[0] == '+') {
        first = digits = buf + 1;   // the digits start right after it: "+-5" is not a number
    } else if (buf[0] == '-') {
        digits = buf + 1;           // from_chars reads the `-` itself
    }
    if (digits == buf + narrowed_len || *digits < '0' || *digits > '9') return alloc::nothing();

    i64 val;
    auto [end, ec] = std::from_chars(first, buf + narrowed_len, val, 10);
    if (ec != std::errc() || end != buf + narrowed_len) return alloc::nothing();

    return alloc::just(alloc::unboxedInt(val), false);
}

// Returns `Just` the Float that `str` spells, or `Nothing`, as elm/core's `_String_toFloat` does.
//
// A null or empty `str`, one that is not ASCII or longer than 127 units, or one holding white space
// or an `x`, `b` or `o` gives `Nothing`. Otherwise the result is JavaScript's `Number(str)`, which is
// `Nothing` only when that is NaN: an out-of-range literal gives `Just` infinity or minus infinity on
// overflow and `Just` 0 or a subnormal on underflow, and `Infinity` with an optional sign is
// accepted. A GC point.
inline HPointer toFloat(void* str) {
    if (!str) return alloc::nothing();
    u32 len = rawLen(str);
    if (len == 0) return alloc::nothing();

    char buf[128];
    size_t narrowed_len;
    if (len > sizeof(buf) - 1 ||
        !narrowAsciiToStack(str, buf, sizeof(buf) - 1, &narrowed_len)) {
        return alloc::nothing();
    }
    buf[narrowed_len] = '\0';

    // Elm rejects whitespace and the x/b/o of hex, binary and octal literals.
    for (size_t i = 0; i < narrowed_len; ++i) {
        char c = buf[i];
        if (c == 'x' || c == 'b' || c == 'o' || std::isspace(static_cast<unsigned char>(c))) {
            return alloc::nothing();
        }
    }
    // JavaScript's Number accepts exactly "Infinity", optionally signed.
    const char* body = (buf[0] == '+' || buf[0] == '-') ? buf + 1 : buf;
    if (std::strcmp(body, "Infinity") == 0) {
        double inf = std::numeric_limits<double>::infinity();
        return alloc::justKind(alloc::unboxedFloat(buf[0] == '-' ? -inf : inf), 2);
    }
    // strtod also reads spellings Number does not: inf, nan, infinity in any
    // case, and hexadecimal floats with a p exponent.
    for (const char* q = body; *q; ++q) {
        char c = *q;
        if (c == 'i' || c == 'I' || c == 'n' || c == 'N' || c == 'p' || c == 'P') {
            return alloc::nothing();
        }
    }

    // libstdc++ supports std::from_chars for floats from version 11 onwards,
    // but strtod is universally reliable. Use strtod with the C locale. Its
    // ERANGE results are what Number gives: +-HUGE_VAL (infinity) on
    // overflow, and 0 or a subnormal on underflow.
    char* end;
    double val = std::strtod(buf, &end);
    if (end != buf + narrowed_len) return alloc::nothing();
    if (std::isnan(val)) return alloc::nothing();

    return alloc::justKind(alloc::unboxedFloat(val), 2);
}

// Returns the decimal text of `n`, with a leading `-` when negative, as a String formed by
// `makeUtf8LeafFromBytes`. A GC point.
inline HPointer fromInt(i64 n) {
    // A 64-bit integer with its sign is at most 20 characters.
    char buf[24];
    auto [end, ec] = std::to_chars(buf, buf + sizeof(buf), n);
    (void)ec;
    return makeUtf8LeafFromBytes(reinterpret_cast<const u8*>(buf),
                                 static_cast<u32>(end - buf));
}

// Writes the text of `n` as JavaScript's `Number.prototype.toString` writes it to `buf`, which must
// have room for 32 bytes, and returns its length. No terminating nul is written.
//
// The text is "NaN", "Infinity" or "-Infinity" for those values, "0" for either zero, and
// otherwise the shortest digits that read back as `n`: in fixed notation when
// 1e-6 <= |n| < 1e21 ("1000000000", "0.000001"), and in exponent form otherwise ("1e+21",
// "1e-7", "1.5e+300"). It does not use `std::to_chars`' own choice between the two notations,
// which writes 1e9 as "1e+09".
inline size_t formatFloatShortest(f64 n, char* buf) {
    if (std::isnan(n)) {
        std::memcpy(buf, "NaN", 3);
        return 3;
    }
    if (std::isinf(n)) {
        if (n > 0) {
            std::memcpy(buf, "Infinity", 8);
            return 8;
        }
        std::memcpy(buf, "-Infinity", 9);
        return 9;
    }
    if (n == 0.0) {
        buf[0] = '0';
        return 1;
    }
    // The shortest round-trip digits, as "[-]d[.ddd]e(+|-)xx".
    char sci[32];
    auto [sciEnd, ec] = std::to_chars(sci, sci + sizeof(sci), n, std::chars_format::scientific);
    (void)ec;
    const char* p = sci;
    size_t len = 0;
    if (*p == '-') {
        buf[len++] = '-';
        ++p;
    }
    char digits[20];
    int k = 0;
    for (; p < sciEnd && *p != 'e'; ++p) {
        if (*p != '.')
            digits[k++] = *p;
    }
    int exp10 = 0;
    std::from_chars(p + 1 + (p[1] == '+' ? 1 : 0), sciEnd, exp10);

    // ECMAScript Number::toString: the value is 0.d1..dk x 10^point.
    const int point = exp10 + 1;
    auto put = [&](char c) { buf[len++] = c; };
    if (k <= point && point <= 21) {
        // Integer: the digits, then zeros ("1000000000").
        for (int i = 0; i < k; ++i) put(digits[i]);
        for (int i = k; i < point; ++i) put('0');
    } else if (0 < point && point <= 21) {
        // Decimal point inside the digits ("3.14").
        for (int i = 0; i < point; ++i) put(digits[i]);
        put('.');
        for (int i = point; i < k; ++i) put(digits[i]);
    } else if (-6 < point && point <= 0) {
        // Leading zeros after the point ("0.000001").
        put('0');
        put('.');
        for (int i = point; i < 0; ++i) put('0');
        for (int i = 0; i < k; ++i) put(digits[i]);
    } else {
        // Exponent form ("1e+21", "1.5e-7").
        put(digits[0]);
        if (k > 1) {
            put('.');
            for (int i = 1; i < k; ++i) put(digits[i]);
        }
        put('e');
        const int e = point - 1;
        put(e < 0 ? '-' : '+');
        auto [expEnd, ec2] = std::to_chars(buf + len, buf + 32, e < 0 ? -e : e);
        (void)ec2;
        len = static_cast<size_t>(expEnd - buf);
    }
    return len;
}

// Returns the text `formatFloatShortest` writes for `n`, as a String formed by
// `makeUtf8LeafFromBytes`. A GC point.
inline HPointer fromFloat(f64 n) {
    char buf[32];
    size_t len = formatFloatShortest(n, buf);
    return makeUtf8LeafFromBytes(reinterpret_cast<const u8*>(buf), static_cast<u32>(len));
}

// Returns the String of the one Char value `c`.
//
// A Char below 0x80, with UTF-8 Strings enabled, gives a one-byte UTF-8 leaf, so that a String
// built from ASCII Chars stays in UTF-8 forms. Any other gives a UTF-16 String of the units
// `encodeCodePoint` writes. A GC point.
inline HPointer fromChar(u32 c) {
    if (c < 0x80 && Allocator::instance().getConfig().utf8_strings_enabled) {
        u8 b = static_cast<u8>(c);
        return makeUtf8LeafFromBytes(&b, 1);
    }
    // The test c < 0x80 above cannot catch an encoded value, which is at least 0x200000.
    u16 buf[CharValue::kMaxCharUnits];
    u32 n = encodeCodePoint(c, buf);
    return alloc::allocString(buf, n);
}

// Returns the units of the Char value `c` followed by `str`, as a new String; `fromChar(c)` when
// `str` is null.
//
// The result is a UTF-8 form when `c` is below 0x80, `str` is a UTF-8 form and UTF-8 Strings are
// enabled, and a UTF-16 String otherwise. A GC point.
inline HPointer cons(u32 c, void* str) {
    if (!str) return fromChar(c);
    u32 len = rawLen(str);
    u16 units[CharValue::kMaxCharUnits];
    u32 n = encodeCodePoint(c, units);
    size_t total_len = static_cast<size_t>(len) + n;

    auto& allocator = Allocator::instance();

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
    for (u32 k = 0; k < n; ++k) out.chars[k] = units[k];
    if (len > 0) copyInto(allocator.resolve(srcHp), out.chars + n);
    return out.hp;
}

// Returns `Just (c, rest)`, where `c` is the first code point of `str` and `rest` the units after
// it, or `Nothing` when `str` is null or empty.
//
// A valid surrogate pair is one code point, and `rest` then starts two units in. Unless `str` is a
// rope, `rest` shares `str` rather than copying it, whatever its length: it is a slice of a flat
// UTF-16 form or of a slice's base, or a UTF-8 view of a UTF-8 form. So taking the first code point
// of each `rest` in turn does not copy the String each time. For a rope, `rest` is what `slice`
// gives. A GC point.
HPointer uncons(void* str);

// ============================================================================
// Higher-Order Operations
// ============================================================================

// A function from a code point to an Elm value. No function in this component takes one.
using CharMapper = Unboxable (*)(u32);

// A function from the code point of one Char to the Char value that replaces it, which may be an
// encoded case-mapping result.
using CharToCharMapper = u32 (*)(u32);

// Returns a new UTF-16 String of the values `mapFunc` gives for the code points of `str`, in order,
// each written with its whole expansion, or the Empty constant for null or empty `str`.
//
// `mapFunc` is called once per code point, in order. `str` is copied into C++ memory before the
// first call. A GC point.
HPointer map(CharToCharMapper mapFunc, void* str);

// A test of the code point of one Char. The functions here that take one call it while they hold
// raw pointers into the String, so it must not allocate on the Elm heap.
using CharPredicate = bool (*)(u32);

// Returns the code points of `str` for which `pred` is true, in order, or the Empty constant when
// there are none or `str` is null or empty.
//
// `str` itself is returned when `pred` keeps everything and `str` is a UTF-8 form (with UTF-8
// Strings enabled) or a flat UTF-16 form. Otherwise the result is new: a UTF-8 form from a UTF-8
// form, with UTF-8 Strings enabled, and a UTF-16 String otherwise. `pred` may be called twice for
// each byte of a UTF-8 form. A GC point.
HPointer filter(CharPredicate pred, void* str);

// A step of a fold: takes the code point of one Char and the accumulator, and returns the new
// accumulator. It may allocate, since the folds read only a copy of the String.
using CharFolder = Unboxable (*)(u32, Unboxable);

// Returns `acc` passed through `fold` with each code point of `str` from first to last, or `acc`
// itself for null `str`. `str` is copied into C++ memory before the first call of `fold`.
Unboxable foldl(CharFolder fold, Unboxable acc, void* str);

// Returns `acc` passed through `fold` with each code point of `str` from last to first, or `acc`
// itself for null `str`. `str` is copied into C++ memory before the first call of `fold`.
Unboxable foldr(CharFolder fold, Unboxable acc, void* str);

// Returns whether `pred` is true for every code point of `str`, stopping at the first that fails;
// true for null `str`. Does not allocate on the Elm heap.
inline bool all(CharPredicate pred, void* str) {
    if (!str) return true;
    size_t len = rawLen(str);
    for (size_t i = 0; i < len;) {
        if (!pred(codePointAt(str, len, i))) return false;
    }
    return true;
}

// Returns whether `pred` is true for some code point of `str`, stopping at the first that is;
// false for null `str`. Does not allocate on the Elm heap.
inline bool any(CharPredicate pred, void* str) {
    if (!str) return false;
    size_t len = rawLen(str);
    for (size_t i = 0; i < len;) {
        if (pred(codePointAt(str, len, i))) return true;
    }
    return false;
}

// ============================================================================
// Utilities
// ============================================================================

// Returns a copy of the UTF-16 units of `str`, empty for null. Being C++ memory, the copy stays
// valid across collections. Does not allocate on the Elm heap.
inline std::u16string toStdU16String(void* str) {
    if (!str) return {};
    Header* hdr = static_cast<Header*>(str);
    if (hdr->tag == Tag_String) {
        ElmString* s = static_cast<ElmString*>(str);
        return std::u16string(reinterpret_cast<const char16_t*>(s->chars), s->header.size);
    }
    if (hdr->tag == Tag_LargeStringHeader) {
        LargeStringHeader* h = static_cast<LargeStringHeader*>(str);
        return std::u16string(reinterpret_cast<const char16_t*>(largeStringChars(h)),
                              h->header.size);
    }
    if (hdr->tag == Tag_StringSlice) {
        ElmStringSlice* slc = static_cast<ElmStringSlice*>(str);
        u32 len = slc->header.size;
        u32 offset = slc->offset;
        void* base = Allocator::instance().resolve(slc->base);
        if (!base) return {};
        // The base may be a large String; flatStringChars reads either flat form.
        return std::u16string(reinterpret_cast<const char16_t*>(flatStringChars(base) + offset), len);
    }
    if (hdr->tag == Tag_StringUtf8View || hdr->tag == Tag_StringUtf8Leaf) {
        auto pr = utf8Bytes(str);
        GC_STATS_UTF8_WIDEN(pr.second);
        std::u16string out(pr.second, u'\0');
        if (pr.second > 0)
            Utf8::widenAscii(pr.first, pr.second, reinterpret_cast<u16*>(out.data()));
        return out;
    }
    // A rope: an in-order walk with an explicit stack, as in forEachSegmentEx, copying into a
    // result sized from the rope's length.
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
            LargeStringHeader* lh = static_cast<LargeStringHeader*>(top);
            std::memcpy(dst, largeStringChars(lh), lh->header.size * sizeof(u16));
            dst += lh->header.size;
        } else if (h->tag == Tag_StringSlice) {
            ElmStringSlice* slc = static_cast<ElmStringSlice*>(top);
            void* base = allocator.resolve(slc->base);
            if (base) {
                std::memcpy(dst, flatStringChars(base) + slc->offset, slc->header.size * sizeof(u16));
                dst += slc->header.size;
            }
        } else if (h->tag == Tag_StringUtf8View || h->tag == Tag_StringUtf8Leaf) {
            auto pr = utf8Bytes(top);
            GC_STATS_UTF8_WIDEN_SITE(UTF8_WIDEN_ROPE_CHILD, pr.second);
            for (u32 k = 0; k < pr.second; ++k)
                dst[k] = static_cast<char16_t>(pr.first[k]);
            dst += pr.second;
        } else if (h->tag == Tag_StringRope) {
            ElmStringRope* r = static_cast<ElmStringRope*>(top);
            void* rightObj = allocator.resolve(r->right);
            void* leftObj = allocator.resolve(r->left);
            if (rightObj) stack.push_back(rightObj);
            if (leftObj) stack.push_back(leftObj);
        }
    }
    return out;
}

// Returns the text of `str` encoded as UTF-8, empty for null.
//
// A valid surrogate pair becomes one four-byte sequence. A lone surrogate becomes the three-byte
// sequence of its unit value, which is not valid UTF-8. Does not allocate on the Elm heap.
std::string toStdString(void* str);

/**
 * One segment of a String, as `forEachSegmentEx` gives it, kept so that two Strings' segments can
 * be walked side by side.
 *
 * `p` is valid as `forEachSegmentEx` says: until the next allocation.
 */
struct SegView {
    const void* p;   // The first unit when `isU16`, and otherwise the first byte. Not owned.
    u32 len;         // In units, which for a UTF-8 segment is also bytes.
    bool isU16;
};

// Appends the segments of `str` to `out`, in order. Does not allocate on the Elm heap.
inline void collectSegs(void* str, std::vector<SegView>& out) {
    forEachSegmentEx(
        str,
        [&](const u16* p, u32 n) { out.push_back(SegView{p, n, true}); },
        [&](const u8* p, u32 n) { out.push_back(SegView{p, n, false}); });
}

// Returns UTF-16 unit `i` of the segment `s`, a byte of a UTF-8 segment being one unit. `i` must be
// less than `s.len`.
inline u16 segElemAt(const SegView& s, u32 i) {
    return s.isU16 ? static_cast<const u16*>(s.p)[i]
                   : static_cast<u16>(static_cast<const u8*>(s.p)[i]);
}

// `equalSlow` and `compareSlow` handle the pairs of forms that `equal` and `compare` do not handle
// inline. They are out of line and marked cold so that their larger frames (two vectors of segments)
// stay out of the inline code at each call site.

// Returns whether `a` and `b` hold the same units, for any forms. Neither may be null, and they
// must have the same length. Does not allocate on the Elm heap.
[[gnu::noinline, gnu::cold]] bool equalSlow(void* a, void* b);
// Returns a number that is negative, zero or positive as `a` orders before, the same as or after
// `b`, as `compare` does, for any forms. Neither may be null. Does not allocate on the Elm heap.
[[gnu::noinline, gnu::cold]] int compareSlow(void* a, void* b);

// Returns whether `a` and `b` hold the same units, whatever their forms. Null equals only null.
// Does not allocate on the Elm heap.
inline bool equal(void* a, void* b) {
    if (!a || !b) return a == b;
    Header* ha = static_cast<Header*>(a);
    Header* hb = static_cast<Header*>(b);
    if (ha->size != hb->size) return false;

    if (ha->tag == Tag_String && hb->tag == Tag_String) {
        ElmString* sa = static_cast<ElmString*>(a);
        ElmString* sb = static_cast<ElmString*>(b);
        return std::memcmp(sa->chars, sb->chars, ha->size * sizeof(u16)) == 0;
    }

    // Both UTF-8: a byte is its unit, and the lengths are already known to be equal.
    if (isUtf8(a) && isUtf8(b)) {
        auto pa = utf8Bytes(a);
        auto pb = utf8Bytes(b);
        return pa.second == pb.second &&
               std::memcmp(pa.first, pb.first, pa.second) == 0;
    }

    return equalSlow(a, b);
}

// Returns a number that is negative, zero or positive as `a` orders before, the same as or after
// `b`. Only the sign means anything.
//
// Strings order by their UTF-16 units, compared as unsigned numbers from the first, and a String
// orders before any longer String it begins. Null orders before every non-null String and equals
// null. Does not allocate on the Elm heap.
inline int compare(void* a, void* b) {
    if (!a && !b) return 0;
    if (!a) return -1;
    if (!b) return 1;
    Header* ha = static_cast<Header*>(a);
    Header* hb = static_cast<Header*>(b);
    Tag ta = static_cast<Tag>(ha->tag);
    Tag tb = static_cast<Tag>(hb->tag);
    bool u8a = (ta == Tag_StringUtf8Leaf) | (ta == Tag_StringUtf8View);
    bool u8b = (tb == Tag_StringUtf8Leaf) | (tb == Tag_StringUtf8View);

    // Both UTF-8: bytes below 0x80 order as their units do, so memcmp gives the right sign.
    if (__builtin_expect(u8a & u8b, 1)) {
        const u8* pa;
        u32 la;
        const u8* pb;
        u32 lb;
        if (ta == Tag_StringUtf8Leaf) {
            pa = static_cast<ElmStringUtf8Leaf*>(a)->bytes;
            la = ha->size;
        } else {
            auto p = utf8Bytes(a);
            pa = p.first;
            la = p.second;
        }
        if (tb == Tag_StringUtf8Leaf) {
            pb = static_cast<ElmStringUtf8Leaf*>(b)->bytes;
            lb = hb->size;
        } else {
            auto p = utf8Bytes(b);
            pb = p.first;
            lb = p.second;
        }
        u32 m = la < lb ? la : lb;
        int c = std::memcmp(pa, pb, m);
        if (c != 0) return c;
        return static_cast<int>(la) - static_cast<int>(lb);
    }

    if (ta == Tag_String && tb == Tag_String) {
        const u16* pa = static_cast<ElmString*>(a)->chars;
        const u16* pb = static_cast<ElmString*>(b)->chars;
        u32 m = ha->size < hb->size ? ha->size : hb->size;
        for (u32 i = 0; i < m; ++i) {
            if (pa[i] != pb[i]) return static_cast<int>(pa[i]) - static_cast<int>(pb[i]);
        }
        return static_cast<int>(ha->size) - static_cast<int>(hb->size);
    }

    return compareSlow(a, b);
}

} // namespace StringOps
} // namespace Elm

#endif // ECO_STRING_OPS_H
