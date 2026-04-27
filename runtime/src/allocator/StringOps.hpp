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
#include <cctype>
#include <charconv>
#include <cmath>
#include <cstdlib>
#include <limits>
#include <sstream>
#include <iomanip>

namespace Elm {
namespace StringOps {

// ============================================================================
// Tag-Aware Helpers (Phase 1: leaf + slice)
// ============================================================================

/**
 * True if `obj` is a flat string leaf (Tag_String).
 * Caller must have already verified `obj` is non-null and a string-like tag.
 */
inline bool isLeaf(void* obj) { return alloc::getTag(obj) == Tag_String; }

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

// Configuration constants (rope/slice heuristics).
namespace detail {
    constexpr size_t FLATTEN_LIMIT = 32 * 1024; // ~64 KiB of UTF-16 code units
    constexpr size_t TINY_SLICE_LIMIT = FLATTEN_LIMIT / 4; // small ranges flatten directly
    // Rope shape thresholds — only consulted when ropes exist (Phase 2).
    constexpr u32 MAX_HEIGHT = 32;        // emit rebalance TODO above this depth
    constexpr u32 LEAFCOUNT_LIMIT = 64;   // many leaves with low avg = candidate for rebalance
    constexpr u32 MIN_LEAF_SIZE = 128;    // avg below this triggers the TODO when over LEAFCOUNT_LIMIT
}

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
 * with len <= FLATTEN_LIMIT are flattened; larger slices pass through (the
 * caller is then responsible for using charAt-style access).
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
    return alloc::isConstant(ptr) && ptr.constant == Const_EmptyString + 1;
}

// Forward declaration so all inline ops below can call toStdU16String to
// snapshot a string into a contiguous std::u16string before allocation.
inline std::u16string toStdU16String(void* str);

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
        if (hdr->tag == Tag_StringSlice) {
            ElmStringSlice* slc = static_cast<ElmStringSlice*>(str);
            void* base = allocator.resolve(slc->base);
            if (!base) return 0;
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
 * Builds a flat leaf when the total fits in FLATTEN_LIMIT (so short strings
 * keep the existing memcpy fast path). Above that threshold, builds a
 * Tag_StringRope joining the two HPointers — sharing both subtrees and
 * giving O(1) amortised concat for repeated appends.
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
    if (total_len <= detail::FLATTEN_LIMIT) {
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
 * For ranges below TINY_SLICE_LIMIT, builds a flat leaf (avoids the slice
 * metadata for short ranges). Larger ranges over a leaf build a
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
inline bool contains(void* needle, void* haystack) {
    if (!needle) return true;  // Empty needle always matches
    if (!haystack) return false;  // Empty haystack never contains non-empty

    size_t needle_len = rawLen(needle);
    size_t haystack_len = rawLen(haystack);

    if (needle_len == 0) return true;
    if (needle_len > haystack_len) return false;

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
    if (!prefix) return true;   // Empty prefix always matches
    if (!str) return false;     // Empty string only starts with empty

    size_t prefix_len = rawLen(prefix);
    size_t str_len = rawLen(str);

    if (prefix_len > str_len) return false;

    for (size_t i = 0; i < prefix_len; ++i) {
        if (charAt(str, static_cast<i64>(i)) != charAt(prefix, static_cast<i64>(i))) return false;
    }
    return true;
}

/**
 * Checks if str ends with suffix.
 */
inline bool endsWith(void* suffix, void* str) {
    if (!suffix) return true;   // Empty suffix always matches
    if (!str) return false;     // Empty string only ends with empty

    size_t suffix_len = rawLen(suffix);
    size_t str_len = rawLen(str);

    if (suffix_len > str_len) return false;

    size_t offset = str_len - suffix_len;
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
    auto buf = toStdU16String(str);
    if (buf.empty()) return alloc::emptyString();

    std::vector<u16> data(buf.begin(), buf.end());
    for (auto& c : data) {
        if (c >= 'a' && c <= 'z') c = c - 32;
    }
    return alloc::allocString(data.data(), data.size());
}

/**
 * Converts string to lowercase (ASCII only).
 */
inline HPointer toLower(void* str) {
    if (!str) return alloc::emptyString();
    auto buf = toStdU16String(str);
    if (buf.empty()) return alloc::emptyString();

    std::vector<u16> data(buf.begin(), buf.end());
    for (auto& c : data) {
        if (c >= 'A' && c <= 'Z') c = c + 32;
    }
    return alloc::allocString(data.data(), data.size());
}

/**
 * Reverses a string.
 */
inline HPointer reverse(void* str) {
    if (!str) return alloc::emptyString();
    auto buf = toStdU16String(str);
    size_t len = buf.size();
    if (len == 0) return alloc::emptyString();
    if (len == 1 && isLeaf(str)) return Allocator::instance().wrap(str);

    std::vector<u16> data(len);
    for (size_t i = 0; i < len; ++i) {
        data[i] = buf[len - 1 - i];
    }
    return alloc::allocString(data.data(), len);
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

    auto srcBuf = toStdU16String(str);
    size_t len = srcBuf.size();
    if (len == 0) return alloc::emptyString();

    size_t total_len = len * static_cast<size_t>(n);
    std::vector<u16> data(total_len);
    for (i64 i = 0; i < n; ++i) {
        std::memcpy(data.data() + (i * len), srcBuf.data(), len * sizeof(u16));
    }
    return alloc::allocString(data.data(), total_len);
}

/**
 * Pads string on the left to reach at least n characters.
 */
inline HPointer padLeft(void* str, i64 n, u16 padChar) {
    if (!str) {
        size_t total_len = static_cast<size_t>(n > 0 ? n : 0);
        if (total_len == 0) return alloc::emptyString();
        std::vector<u16> data(total_len, padChar);
        return alloc::allocString(data.data(), total_len);
    }
    auto buf = toStdU16String(str);
    i64 len = static_cast<i64>(buf.size());
    if (len >= n) return Allocator::instance().wrap(str);

    size_t pad_count = static_cast<size_t>(n - len);
    size_t total_len = static_cast<size_t>(n);
    std::vector<u16> data(total_len);
    for (size_t i = 0; i < pad_count; ++i) data[i] = padChar;
    std::memcpy(data.data() + pad_count, buf.data(), len * sizeof(u16));
    return alloc::allocString(data.data(), total_len);
}

/**
 * Pads string on the right to reach at least n characters.
 */
inline HPointer padRight(void* str, i64 n, u16 padChar) {
    if (!str) {
        size_t total_len = static_cast<size_t>(n > 0 ? n : 0);
        if (total_len == 0) return alloc::emptyString();
        std::vector<u16> data(total_len, padChar);
        return alloc::allocString(data.data(), total_len);
    }
    auto buf = toStdU16String(str);
    i64 len = static_cast<i64>(buf.size());
    if (len >= n) return Allocator::instance().wrap(str);

    size_t total_len = static_cast<size_t>(n);
    std::vector<u16> data(total_len, padChar);
    std::memcpy(data.data(), buf.data(), len * sizeof(u16));
    return alloc::allocString(data.data(), total_len);
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
inline HPointer toInt(void* str) {
    if (!str) return alloc::nothing();
    auto buf = toStdU16String(str);
    size_t len = buf.size();
    if (len == 0) return alloc::nothing();

    std::string narrow;
    narrow.reserve(len);
    for (auto c : buf) {
        if (c > 127) return alloc::nothing();
        narrow.push_back(static_cast<char>(c));
    }

    char* end;
    errno = 0;
    long long val = std::strtoll(narrow.c_str(), &end, 10);
    if (end != narrow.c_str() + narrow.size()) return alloc::nothing();
    if (errno == ERANGE) return alloc::nothing();

    return alloc::just(alloc::unboxedInt(static_cast<i64>(val)), false);
}

/**
 * Parses a float from a string.
 * Returns Just(float) on success, Nothing on failure.
 */
inline HPointer toFloat(void* str) {
    if (!str) return alloc::nothing();
    auto buf = toStdU16String(str);
    size_t len = buf.size();
    if (len == 0) return alloc::nothing();

    std::string narrow;
    narrow.reserve(len);
    for (auto c : buf) {
        if (c > 127) return alloc::nothing();
        narrow.push_back(static_cast<char>(c));
    }

    char* end;
    errno = 0;
    double val = std::strtod(narrow.c_str(), &end);
    if (end != narrow.c_str() + narrow.size()) return alloc::nothing();
    if (errno == ERANGE) return alloc::nothing();
    if (std::isinf(val) || std::isnan(val)) return alloc::nothing();

    return alloc::just(alloc::unboxedFloat(val), false);
}

/**
 * Converts an integer to a string.
 */
inline HPointer fromInt(i64 n) {
    std::ostringstream oss;
    oss << n;
    std::string s = oss.str();
    std::u16string u16(s.begin(), s.end());
    return alloc::allocString(u16);
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
    auto buf = toStdU16String(str);
    size_t len = buf.size();
    size_t total_len = len + 1;

    std::vector<u16> data(total_len);
    data[0] = c;
    if (len > 0) std::memcpy(data.data() + 1, buf.data(), len * sizeof(u16));

    return alloc::allocString(data.data(), total_len);
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
    if (hdr->tag == Tag_StringSlice) {
        ElmStringSlice* slc = static_cast<ElmStringSlice*>(str);
        u32 len = slc->header.size;
        u32 offset = slc->offset;
        void* base = Allocator::instance().resolve(slc->base);
        if (!base) return {};
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
        } else if (h->tag == Tag_StringSlice) {
            ElmStringSlice* slc = static_cast<ElmStringSlice*>(top);
            void* base = allocator.resolve(slc->base);
            if (base) {
                ElmString* leaf = static_cast<ElmString*>(base);
                std::memcpy(dst, leaf->chars + slc->offset, slc->header.size * sizeof(u16));
                dst += slc->header.size;
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
 * length is below FLATTEN_LIMIT, both are snapshotted via toStdU16String
 * and compared with memcmp. Above the limit, falls back to a char-by-char
 * walk via charAt to keep peak memory bounded (// TODO: streaming compare).
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

    if (ha->size <= detail::FLATTEN_LIMIT) {
        auto sa = toStdU16String(a);
        auto sb = toStdU16String(b);
        if (sa.size() != sb.size()) return false;
        return std::memcmp(sa.data(), sb.data(), sa.size() * sizeof(u16)) == 0;
    }

    // Bounded-memory path for very large mixed-form strings.
    // TODO: streaming compare without per-char tag dispatch.
    size_t len = ha->size;
    for (size_t i = 0; i < len; ++i) {
        if (charAt(a, static_cast<i64>(i)) != charAt(b, static_cast<i64>(i))) {
            return false;
        }
    }
    return true;
}

/**
 * Compares two strings lexicographically.
 * Returns negative if a < b, 0 if a == b, positive if a > b.
 *
 * Pure leaf+leaf path is unchanged. Otherwise, snapshots via toStdU16String
 * when the longest side fits in FLATTEN_LIMIT, falling back to a charAt
 * walk for very large mixed-form inputs (// TODO: streaming compare).
 */
inline int compare(void* a, void* b) {
    if (!a && !b) return 0;
    if (!a) return -1;
    if (!b) return 1;
    Header* ha = static_cast<Header*>(a);
    Header* hb = static_cast<Header*>(b);

    if (ha->tag == Tag_String && hb->tag == Tag_String) {
        ElmString* sa = static_cast<ElmString*>(a);
        ElmString* sb = static_cast<ElmString*>(b);
        size_t min_len = std::min<size_t>(ha->size, hb->size);
        for (size_t i = 0; i < min_len; ++i) {
            if (sa->chars[i] != sb->chars[i]) {
                return static_cast<int>(sa->chars[i]) - static_cast<int>(sb->chars[i]);
            }
        }
        return static_cast<int>(ha->size) - static_cast<int>(hb->size);
    }

    size_t maxLen = std::max<size_t>(ha->size, hb->size);
    if (maxLen <= detail::FLATTEN_LIMIT) {
        auto sa = toStdU16String(a);
        auto sb = toStdU16String(b);
        size_t min_len = std::min(sa.size(), sb.size());
        for (size_t i = 0; i < min_len; ++i) {
            if (sa[i] != sb[i]) {
                return static_cast<int>(sa[i]) - static_cast<int>(sb[i]);
            }
        }
        return static_cast<int>(sa.size()) - static_cast<int>(sb.size());
    }

    // TODO: streaming compare. Bounded-memory char walk.
    size_t min_len = std::min<size_t>(ha->size, hb->size);
    for (size_t i = 0; i < min_len; ++i) {
        u16 ca = charAt(a, static_cast<i64>(i));
        u16 cb = charAt(b, static_cast<i64>(i));
        if (ca != cb) return static_cast<int>(ca) - static_cast<int>(cb);
    }
    return static_cast<int>(ha->size) - static_cast<int>(hb->size);
}

} // namespace StringOps
} // namespace Elm

#endif // ECO_STRING_OPS_H
