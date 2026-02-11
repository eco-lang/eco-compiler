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
// Length and Character Access
// ============================================================================

/**
 * Returns the number of code units in a string.
 * Equivalent to Elm's String.length for BMP characters.
 */
inline i64 length(void* str) {
    ElmString* s = static_cast<ElmString*>(str);
    return static_cast<i64>(s->header.size);
}

/**
 * Checks if a string is empty.
 */
inline bool isEmpty(HPointer ptr) {
    return alloc::isConstant(ptr) && ptr.constant == Const_EmptyString + 1;
}

/**
 * Returns the character at a given index (0-based).
 * Returns 0 if index is out of bounds.
 */
inline u16 charAt(void* str, i64 index) {
    ElmString* s = static_cast<ElmString*>(str);
    if (index < 0 || static_cast<size_t>(index) >= s->header.size) {
        return 0;
    }
    return s->chars[index];
}

// ============================================================================
// Concatenation
// ============================================================================

/**
 * Appends two strings: a ++ b
 */
inline HPointer append(void* a, void* b) {
    ElmString* sa = static_cast<ElmString*>(a);
    ElmString* sb = static_cast<ElmString*>(b);

    size_t len_a = sa->header.size;
    size_t len_b = sb->header.size;

    if (len_a == 0) return Allocator::instance().wrap(b);
    if (len_b == 0) return Allocator::instance().wrap(a);

    size_t total_len = len_a + len_b;
    size_t data_size = total_len * sizeof(u16);
    size_t total_size = sizeof(ElmString) + data_size;
    total_size = (total_size + 7) & ~7;

    auto& allocator = Allocator::instance();
    ElmString* result = static_cast<ElmString*>(allocator.allocate(total_size, Tag_String));
    result->header.size = static_cast<u32>(total_len);

    std::memcpy(result->chars, sa->chars, len_a * sizeof(u16));
    std::memcpy(result->chars + len_a, sb->chars, len_b * sizeof(u16));

    return allocator.wrap(result);
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
 */
inline HPointer slice(void* str, i64 start, i64 end) {
    ElmString* s = static_cast<ElmString*>(str);
    i64 len = static_cast<i64>(s->header.size);

    // Normalize negative indices
    if (start < 0) start = std::max(i64(0), len + start);
    if (end < 0) end = std::max(i64(0), len + end);

    // Clamp to bounds
    start = std::max(i64(0), std::min(start, len));
    end = std::max(i64(0), std::min(end, len));

    if (start >= end) return alloc::emptyString();

    size_t slice_len = static_cast<size_t>(end - start);
    return alloc::allocString(s->chars + start, slice_len);
}

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
    ElmString* s = static_cast<ElmString*>(str);
    i64 len = static_cast<i64>(s->header.size);
    return slice(str, len - n, len);
}

/**
 * Drops the first n characters.
 */
inline HPointer dropLeft(void* str, i64 n) {
    if (n <= 0) return Allocator::instance().wrap(str);
    ElmString* s = static_cast<ElmString*>(str);
    i64 len = static_cast<i64>(s->header.size);
    return slice(str, n, len);
}

/**
 * Drops the last n characters.
 */
inline HPointer dropRight(void* str, i64 n) {
    if (n <= 0) return Allocator::instance().wrap(str);
    ElmString* s = static_cast<ElmString*>(str);
    i64 len = static_cast<i64>(s->header.size);
    return slice(str, 0, len - n);
}

// ============================================================================
// Searching
// ============================================================================

/**
 * Checks if the substring needle is contained in haystack.
 */
inline bool contains(void* needle, void* haystack) {
    ElmString* n = static_cast<ElmString*>(needle);
    ElmString* h = static_cast<ElmString*>(haystack);

    size_t needle_len = n->header.size;
    size_t haystack_len = h->header.size;

    if (needle_len == 0) return true;
    if (needle_len > haystack_len) return false;

    // Simple substring search
    for (size_t i = 0; i <= haystack_len - needle_len; ++i) {
        bool match = true;
        for (size_t j = 0; j < needle_len && match; ++j) {
            if (h->chars[i + j] != n->chars[j]) match = false;
        }
        if (match) return true;
    }
    return false;
}

/**
 * Checks if str starts with prefix.
 */
inline bool startsWith(void* prefix, void* str) {
    ElmString* p = static_cast<ElmString*>(prefix);
    ElmString* s = static_cast<ElmString*>(str);

    size_t prefix_len = p->header.size;
    size_t str_len = s->header.size;

    if (prefix_len > str_len) return false;

    for (size_t i = 0; i < prefix_len; ++i) {
        if (s->chars[i] != p->chars[i]) return false;
    }
    return true;
}

/**
 * Checks if str ends with suffix.
 */
inline bool endsWith(void* suffix, void* str) {
    ElmString* x = static_cast<ElmString*>(suffix);
    ElmString* s = static_cast<ElmString*>(str);

    size_t suffix_len = x->header.size;
    size_t str_len = s->header.size;

    if (suffix_len > str_len) return false;

    size_t offset = str_len - suffix_len;
    for (size_t i = 0; i < suffix_len; ++i) {
        if (s->chars[offset + i] != x->chars[i]) return false;
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
    ElmString* s = static_cast<ElmString*>(str);
    size_t len = s->header.size;

    if (len == 0) return alloc::emptyString();

    size_t data_size = len * sizeof(u16);
    size_t total_size = sizeof(ElmString) + data_size;
    total_size = (total_size + 7) & ~7;

    auto& allocator = Allocator::instance();
    ElmString* result = static_cast<ElmString*>(allocator.allocate(total_size, Tag_String));
    result->header.size = static_cast<u32>(len);

    for (size_t i = 0; i < len; ++i) {
        u16 c = s->chars[i];
        if (c >= 'a' && c <= 'z') {
            result->chars[i] = c - 32;
        } else {
            result->chars[i] = c;
        }
    }

    return allocator.wrap(result);
}

/**
 * Converts string to lowercase (ASCII only).
 */
inline HPointer toLower(void* str) {
    ElmString* s = static_cast<ElmString*>(str);
    size_t len = s->header.size;

    if (len == 0) return alloc::emptyString();

    size_t data_size = len * sizeof(u16);
    size_t total_size = sizeof(ElmString) + data_size;
    total_size = (total_size + 7) & ~7;

    auto& allocator = Allocator::instance();
    ElmString* result = static_cast<ElmString*>(allocator.allocate(total_size, Tag_String));
    result->header.size = static_cast<u32>(len);

    for (size_t i = 0; i < len; ++i) {
        u16 c = s->chars[i];
        if (c >= 'A' && c <= 'Z') {
            result->chars[i] = c + 32;
        } else {
            result->chars[i] = c;
        }
    }

    return allocator.wrap(result);
}

/**
 * Reverses a string.
 */
inline HPointer reverse(void* str) {
    ElmString* s = static_cast<ElmString*>(str);
    size_t len = s->header.size;

    if (len == 0) return alloc::emptyString();
    if (len == 1) return Allocator::instance().wrap(str);

    size_t data_size = len * sizeof(u16);
    size_t total_size = sizeof(ElmString) + data_size;
    total_size = (total_size + 7) & ~7;

    auto& allocator = Allocator::instance();
    ElmString* result = static_cast<ElmString*>(allocator.allocate(total_size, Tag_String));
    result->header.size = static_cast<u32>(len);

    for (size_t i = 0; i < len; ++i) {
        result->chars[i] = s->chars[len - 1 - i];
    }

    return allocator.wrap(result);
}

/**
 * Trims whitespace from both ends.
 */
inline HPointer trim(void* str) {
    ElmString* s = static_cast<ElmString*>(str);
    size_t len = s->header.size;

    if (len == 0) return alloc::emptyString();

    // Find first non-whitespace
    size_t start = 0;
    while (start < len && (s->chars[start] == ' ' ||
                           s->chars[start] == '\t' ||
                           s->chars[start] == '\n' ||
                           s->chars[start] == '\r')) {
        ++start;
    }

    // Find last non-whitespace
    size_t end = len;
    while (end > start && (s->chars[end - 1] == ' ' ||
                           s->chars[end - 1] == '\t' ||
                           s->chars[end - 1] == '\n' ||
                           s->chars[end - 1] == '\r')) {
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
    ElmString* s = static_cast<ElmString*>(str);
    size_t len = s->header.size;

    if (len == 0) return alloc::emptyString();

    size_t start = 0;
    while (start < len && (s->chars[start] == ' ' ||
                           s->chars[start] == '\t' ||
                           s->chars[start] == '\n' ||
                           s->chars[start] == '\r')) {
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
    ElmString* s = static_cast<ElmString*>(str);
    size_t len = s->header.size;

    if (len == 0) return alloc::emptyString();

    size_t end = len;
    while (end > 0 && (s->chars[end - 1] == ' ' ||
                       s->chars[end - 1] == '\t' ||
                       s->chars[end - 1] == '\n' ||
                       s->chars[end - 1] == '\r')) {
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
    if (n <= 0) return alloc::emptyString();

    ElmString* s = static_cast<ElmString*>(str);
    size_t len = s->header.size;

    if (len == 0) return alloc::emptyString();

    size_t total_len = len * static_cast<size_t>(n);
    size_t data_size = total_len * sizeof(u16);
    size_t total_size = sizeof(ElmString) + data_size;
    total_size = (total_size + 7) & ~7;

    auto& allocator = Allocator::instance();
    ElmString* result = static_cast<ElmString*>(allocator.allocate(total_size, Tag_String));
    result->header.size = static_cast<u32>(total_len);

    for (i64 i = 0; i < n; ++i) {
        std::memcpy(result->chars + (i * len), s->chars, len * sizeof(u16));
    }

    return allocator.wrap(result);
}

/**
 * Pads string on the left to reach at least n characters.
 */
inline HPointer padLeft(void* str, i64 n, u16 padChar) {
    ElmString* s = static_cast<ElmString*>(str);
    i64 len = static_cast<i64>(s->header.size);

    if (len >= n) return Allocator::instance().wrap(str);

    size_t pad_count = static_cast<size_t>(n - len);
    size_t total_len = static_cast<size_t>(n);
    size_t data_size = total_len * sizeof(u16);
    size_t total_size = sizeof(ElmString) + data_size;
    total_size = (total_size + 7) & ~7;

    auto& allocator = Allocator::instance();
    ElmString* result = static_cast<ElmString*>(allocator.allocate(total_size, Tag_String));
    result->header.size = static_cast<u32>(total_len);

    // Fill padding
    for (size_t i = 0; i < pad_count; ++i) {
        result->chars[i] = padChar;
    }
    // Copy original
    std::memcpy(result->chars + pad_count, s->chars, len * sizeof(u16));

    return allocator.wrap(result);
}

/**
 * Pads string on the right to reach at least n characters.
 */
inline HPointer padRight(void* str, i64 n, u16 padChar) {
    ElmString* s = static_cast<ElmString*>(str);
    i64 len = static_cast<i64>(s->header.size);

    if (len >= n) return Allocator::instance().wrap(str);

    size_t total_len = static_cast<size_t>(n);
    size_t data_size = total_len * sizeof(u16);
    size_t total_size = sizeof(ElmString) + data_size;
    total_size = (total_size + 7) & ~7;

    auto& allocator = Allocator::instance();
    ElmString* result = static_cast<ElmString*>(allocator.allocate(total_size, Tag_String));
    result->header.size = static_cast<u32>(total_len);

    // Copy original
    std::memcpy(result->chars, s->chars, len * sizeof(u16));
    // Fill padding
    for (size_t i = static_cast<size_t>(len); i < total_len; ++i) {
        result->chars[i] = padChar;
    }

    return allocator.wrap(result);
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
    ElmString* s = static_cast<ElmString*>(str);
    size_t len = s->header.size;

    if (len == 0) return alloc::nothing();

    // Convert to narrow string for parsing
    std::string narrow;
    narrow.reserve(len);
    for (size_t i = 0; i < len; ++i) {
        u16 c = s->chars[i];
        if (c > 127) return alloc::nothing();  // Non-ASCII
        narrow.push_back(static_cast<char>(c));
    }

    // Parse
    char* end;
    errno = 0;
    long long val = std::strtoll(narrow.c_str(), &end, 10);

    // Check for parse errors
    if (end != narrow.c_str() + narrow.size()) return alloc::nothing();
    if (errno == ERANGE) return alloc::nothing();

    return alloc::just(alloc::unboxedInt(static_cast<i64>(val)), false);
}

/**
 * Parses a float from a string.
 * Returns Just(float) on success, Nothing on failure.
 */
inline HPointer toFloat(void* str) {
    ElmString* s = static_cast<ElmString*>(str);
    size_t len = s->header.size;

    if (len == 0) return alloc::nothing();

    // Convert to narrow string for parsing
    std::string narrow;
    narrow.reserve(len);
    for (size_t i = 0; i < len; ++i) {
        u16 c = s->chars[i];
        if (c > 127) return alloc::nothing();  // Non-ASCII
        narrow.push_back(static_cast<char>(c));
    }

    // Parse
    char* end;
    errno = 0;
    double val = std::strtod(narrow.c_str(), &end);

    // Check for parse errors
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
 */
inline HPointer cons(u16 c, void* str) {
    ElmString* s = static_cast<ElmString*>(str);
    size_t len = s->header.size;
    size_t total_len = len + 1;

    size_t data_size = total_len * sizeof(u16);
    size_t total_size = sizeof(ElmString) + data_size;
    total_size = (total_size + 7) & ~7;

    auto& allocator = Allocator::instance();
    ElmString* result = static_cast<ElmString*>(allocator.allocate(total_size, Tag_String));
    result->header.size = static_cast<u32>(total_len);

    result->chars[0] = c;
    std::memcpy(result->chars + 1, s->chars, len * sizeof(u16));

    return allocator.wrap(result);
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
    ElmString* s = static_cast<ElmString*>(str);
    for (size_t i = 0; i < s->header.size; ++i) {
        if (!pred(s->chars[i])) return false;
    }
    return true;
}

/**
 * Checks if any character satisfies a predicate.
 */
inline bool any(CharPredicate pred, void* str) {
    ElmString* s = static_cast<ElmString*>(str);
    for (size_t i = 0; i < s->header.size; ++i) {
        if (pred(s->chars[i])) return true;
    }
    return false;
}

// ============================================================================
// Utilities
// ============================================================================

/**
 * Converts an ElmString to a std::u16string (for interop/debugging).
 */
inline std::u16string toStdU16String(void* str) {
    ElmString* s = static_cast<ElmString*>(str);
    return std::u16string(reinterpret_cast<const char16_t*>(s->chars), s->header.size);
}

/**
 * Converts an ElmString to a std::string (UTF-8, for debugging).
 */
std::string toStdString(void* str);

/**
 * Compares two strings for equality.
 */
inline bool equal(void* a, void* b) {
    ElmString* sa = static_cast<ElmString*>(a);
    ElmString* sb = static_cast<ElmString*>(b);

    if (sa->header.size != sb->header.size) return false;

    return std::memcmp(sa->chars, sb->chars, sa->header.size * sizeof(u16)) == 0;
}

/**
 * Compares two strings lexicographically.
 * Returns negative if a < b, 0 if a == b, positive if a > b.
 */
inline int compare(void* a, void* b) {
    ElmString* sa = static_cast<ElmString*>(a);
    ElmString* sb = static_cast<ElmString*>(b);

    size_t min_len = std::min(sa->header.size, sb->header.size);

    for (size_t i = 0; i < min_len; ++i) {
        if (sa->chars[i] != sb->chars[i]) {
            return static_cast<int>(sa->chars[i]) - static_cast<int>(sb->chars[i]);
        }
    }

    return static_cast<int>(sa->header.size) - static_cast<int>(sb->header.size);
}

} // namespace StringOps
} // namespace Elm

#endif // ECO_STRING_OPS_H
