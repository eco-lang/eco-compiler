/**
 * String Operations Implementation.
 */

#include "StringOps.hpp"
#include <vector>

namespace Elm {
namespace StringOps {

HPointer concat(HPointer stringList) {
    auto& allocator = Allocator::instance();

    // First pass: calculate total length
    size_t total_len = 0;
    HPointer current = stringList;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        void* strObj = allocator.resolve(c->head.p);
        if (strObj) {
            ElmString* s = static_cast<ElmString*>(strObj);
            total_len += s->header.size;
        }
        current = c->tail;
    }

    if (total_len == 0) return alloc::emptyString();

    // Allocate result
    size_t data_size = total_len * sizeof(u16);
    size_t total_size = sizeof(ElmString) + data_size;
    total_size = (total_size + 7) & ~7;

    ElmString* result = static_cast<ElmString*>(allocator.allocate(total_size, Tag_String));
    result->header.size = static_cast<u32>(total_len);

    // Second pass: copy strings
    size_t offset = 0;
    current = stringList;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        void* strObj = allocator.resolve(c->head.p);
        if (strObj) {
            ElmString* s = static_cast<ElmString*>(strObj);
            std::memcpy(result->chars + offset, s->chars, s->header.size * sizeof(u16));
            offset += s->header.size;
        }
        current = c->tail;
    }

    return allocator.wrap(result);
}

HPointer join(void* sep, HPointer stringList) {
    auto& allocator = Allocator::instance();
    ElmString* separator = static_cast<ElmString*>(sep);
    size_t sep_len = separator->header.size;

    // First pass: count strings and total length
    size_t total_len = 0;
    size_t count = 0;
    HPointer current = stringList;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        void* strObj = allocator.resolve(c->head.p);
        if (strObj) {
            ElmString* s = static_cast<ElmString*>(strObj);
            total_len += s->header.size;
            ++count;
        }
        current = c->tail;
    }

    if (count == 0) return alloc::emptyString();

    // Add separator lengths
    total_len += sep_len * (count - 1);

    // Allocate result
    size_t data_size = total_len * sizeof(u16);
    size_t total_size = sizeof(ElmString) + data_size;
    total_size = (total_size + 7) & ~7;

    ElmString* result = static_cast<ElmString*>(allocator.allocate(total_size, Tag_String));
    result->header.size = static_cast<u32>(total_len);

    // Second pass: copy strings with separators
    size_t offset = 0;
    bool first = true;
    current = stringList;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        void* strObj = allocator.resolve(c->head.p);
        if (strObj) {
            ElmString* s = static_cast<ElmString*>(strObj);

            if (!first && sep_len > 0) {
                std::memcpy(result->chars + offset, separator->chars, sep_len * sizeof(u16));
                offset += sep_len;
            }
            first = false;

            std::memcpy(result->chars + offset, s->chars, s->header.size * sizeof(u16));
            offset += s->header.size;
        }
        current = c->tail;
    }

    return allocator.wrap(result);
}

HPointer indexes(void* needle, void* haystack) {
    ElmString* n = static_cast<ElmString*>(needle);
    ElmString* h = static_cast<ElmString*>(haystack);

    size_t needle_len = n->header.size;
    size_t haystack_len = h->header.size;

    // Collect indices
    std::vector<i64> indices;

    if (needle_len == 0) {
        // Empty needle matches at every position
        for (size_t i = 0; i <= haystack_len; ++i) {
            indices.push_back(static_cast<i64>(i));
        }
    } else if (needle_len <= haystack_len) {
        // Simple substring search
        for (size_t i = 0; i <= haystack_len - needle_len; ++i) {
            bool match = true;
            for (size_t j = 0; j < needle_len && match; ++j) {
                if (h->chars[i + j] != n->chars[j]) match = false;
            }
            if (match) {
                indices.push_back(static_cast<i64>(i));
            }
        }
    }

    // Build list from indices
    return alloc::listFromInts(indices);
}

HPointer split(void* sep, void* str) {
    auto& allocator = Allocator::instance();
    ElmString* separator = static_cast<ElmString*>(sep);
    ElmString* s = static_cast<ElmString*>(str);

    size_t sep_len = separator->header.size;
    size_t str_len = s->header.size;

    if (str_len == 0) {
        // Empty string -> list with one empty string
        return alloc::cons(alloc::boxed(alloc::emptyString()), alloc::listNil(), true);
    }

    if (sep_len == 0) {
        // Empty separator -> split into individual characters
        return toList(str);
    }

    // Collect substrings
    std::vector<HPointer> parts;
    size_t start = 0;

    for (size_t i = 0; i <= str_len - sep_len; ++i) {
        bool match = true;
        for (size_t j = 0; j < sep_len && match; ++j) {
            if (s->chars[i + j] != separator->chars[j]) match = false;
        }

        if (match) {
            // Found separator - add substring before it
            parts.push_back(alloc::allocString(s->chars + start, i - start));
            start = i + sep_len;
            i = start - 1;  // Will be incremented by loop
        }
    }

    // Add final substring
    parts.push_back(alloc::allocString(s->chars + start, str_len - start));

    return alloc::listFromPointers(parts);
}

HPointer toList(void* str) {
    ElmString* s = static_cast<ElmString*>(str);
    size_t len = s->header.size;

    HPointer result = alloc::listNil();

    // Build list in reverse order for efficiency
    for (size_t i = len; i > 0; --i) {
        HPointer charStr = fromChar(s->chars[i - 1]);
        result = alloc::cons(alloc::boxed(charStr), result, true);
    }

    return result;
}

HPointer uncons(void* str) {
    ElmString* s = static_cast<ElmString*>(str);

    if (s->header.size == 0) {
        return alloc::nothing();
    }

    u16 firstChar = s->chars[0];
    HPointer rest = slice(str, 1, static_cast<i64>(s->header.size));

    // Create tuple (char, rest)
    Unboxable charVal = alloc::unboxedChar(firstChar);
    Unboxable restVal = alloc::boxed(rest);

    // Return Just (char, rest) - tuple with char unboxed, rest boxed
    HPointer tuple = alloc::tuple2(charVal, restVal, 0x1);  // bit 0 = a is unboxed
    return alloc::just(alloc::boxed(tuple), true);
}

HPointer map(CharToCharMapper mapFunc, void* str) {
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
        result->chars[i] = mapFunc(s->chars[i]);
    }

    return allocator.wrap(result);
}

HPointer filter(CharPredicate pred, void* str) {
    ElmString* s = static_cast<ElmString*>(str);
    size_t len = s->header.size;

    if (len == 0) return alloc::emptyString();

    // First pass: count matching chars
    size_t match_count = 0;
    for (size_t i = 0; i < len; ++i) {
        if (pred(s->chars[i])) ++match_count;
    }

    if (match_count == 0) return alloc::emptyString();
    if (match_count == len) return Allocator::instance().wrap(str);

    // Allocate result
    size_t data_size = match_count * sizeof(u16);
    size_t total_size = sizeof(ElmString) + data_size;
    total_size = (total_size + 7) & ~7;

    auto& allocator = Allocator::instance();
    ElmString* result = static_cast<ElmString*>(allocator.allocate(total_size, Tag_String));
    result->header.size = static_cast<u32>(match_count);

    // Second pass: copy matching chars
    size_t j = 0;
    for (size_t i = 0; i < len; ++i) {
        if (pred(s->chars[i])) {
            result->chars[j++] = s->chars[i];
        }
    }

    return allocator.wrap(result);
}

Unboxable foldl(CharFolder fold, Unboxable acc, void* str) {
    ElmString* s = static_cast<ElmString*>(str);
    Unboxable result = acc;

    for (size_t i = 0; i < s->header.size; ++i) {
        result = fold(s->chars[i], result);
    }

    return result;
}

Unboxable foldr(CharFolder fold, Unboxable acc, void* str) {
    ElmString* s = static_cast<ElmString*>(str);
    Unboxable result = acc;

    for (size_t i = s->header.size; i > 0; --i) {
        result = fold(s->chars[i - 1], result);
    }

    return result;
}

std::string toStdString(void* str) {
    ElmString* s = static_cast<ElmString*>(str);
    std::string result;
    result.reserve(s->header.size * 3);  // Worst case for UTF-8

    for (size_t i = 0; i < s->header.size; ++i) {
        u16 c = s->chars[i];

        // Handle surrogate pairs
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s->header.size) {
            u16 c2 = s->chars[i + 1];
            if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
                // Valid surrogate pair
                uint32_t codepoint = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
                result.push_back(static_cast<char>(0xF0 | ((codepoint >> 18) & 0x07)));
                result.push_back(static_cast<char>(0x80 | ((codepoint >> 12) & 0x3F)));
                result.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3F)));
                result.push_back(static_cast<char>(0x80 | (codepoint & 0x3F)));
                ++i;
                continue;
            }
        }

        // Regular BMP character
        if (c < 0x80) {
            result.push_back(static_cast<char>(c));
        } else if (c < 0x800) {
            result.push_back(static_cast<char>(0xC0 | ((c >> 6) & 0x1F)));
            result.push_back(static_cast<char>(0x80 | (c & 0x3F)));
        } else {
            result.push_back(static_cast<char>(0xE0 | ((c >> 12) & 0x0F)));
            result.push_back(static_cast<char>(0x80 | ((c >> 6) & 0x3F)));
            result.push_back(static_cast<char>(0x80 | (c & 0x3F)));
        }
    }

    return result;
}

} // namespace StringOps
} // namespace Elm
