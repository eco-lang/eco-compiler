/**
 * Elm Kernel String Module - Runtime Heap Integration
 *
 * This module delegates to StringOps helpers from the runtime allocator.
 * All string operations work with GC-managed ElmString objects on the heap.
 */

#include "String.hpp"
#include "allocator/StringOps.hpp"
#include "allocator/Allocator.hpp"

namespace Elm::Kernel::String {

// ============================================================================
// Length
// ============================================================================

i64 length(void* str) {
    return StringOps::length(str);
}

// ============================================================================
// Concatenation
// ============================================================================

HPointer append(void* a, void* b) {
    return StringOps::append(a, b);
}

HPointer join(void* sep, HPointer stringList) {
    return StringOps::join(sep, stringList);
}

// ============================================================================
// Character Operations
// ============================================================================

HPointer cons(u16 c, void* str) {
    return StringOps::cons(c, str);
}

HPointer uncons(void* str) {
    return StringOps::uncons(str);
}

HPointer fromList(HPointer chars) {
    // Convert list of Char values to a single string.
    // List heads can be either:
    //   - Unboxed: raw i16 char value in head.c (header.unboxed bit 0 set)
    //   - Boxed: HPointer to ElmChar in head.p (header.unboxed bit 0 clear)
    auto& allocator = Allocator::instance();

    // First pass: count total characters (one per cons cell)
    size_t total_len = 0;
    HPointer current = chars;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        total_len++;
        current = c->tail;
    }

    if (total_len == 0) return alloc::emptyString();

    // Allocate result
    size_t data_size = total_len * sizeof(u16);
    size_t total_size = sizeof(ElmString) + data_size;
    total_size = (total_size + 7) & ~7;

    ElmString* result = static_cast<ElmString*>(allocator.allocate(total_size, Tag_String));
    result->header.size = static_cast<u32>(total_len);

    // Second pass: extract char values
    size_t offset = 0;
    current = chars;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        u16 charVal;
        if (c->header.unboxed & 1) {
            // Unboxed: raw char value stored directly
            charVal = c->head.c;
        } else {
            // Boxed: HPointer to ElmChar
            void* charObj = allocator.resolve(c->head.p);
            ElmChar* ec = static_cast<ElmChar*>(charObj);
            charVal = ec->value;
        }
        result->chars[offset++] = charVal;
        current = c->tail;
    }

    return allocator.wrap(result);
}

// ============================================================================
// Higher-Order Operations
// ============================================================================

HPointer map(CharMapper func, void* str) {
    return StringOps::map(func, str);
}

HPointer filter(CharPredicate pred, void* str) {
    return StringOps::filter(pred, str);
}

bool any(CharPredicate pred, void* str) {
    return StringOps::any(pred, str);
}

bool all(CharPredicate pred, void* str) {
    return StringOps::all(pred, str);
}

// ============================================================================
// Folding
// ============================================================================

HPointer foldl(FoldFunc func, HPointer acc, void* str) {
    if (!str) return acc;
    auto& allocator = Allocator::instance();
    ElmString* s = static_cast<ElmString*>(str);

    HPointer result = acc;
    for (u32 i = 0; i < s->header.size; ++i) {
        void* accObj = allocator.resolve(result);
        result = func(s->chars[i], accObj);
    }
    return result;
}

HPointer foldr(FoldFunc func, HPointer acc, void* str) {
    if (!str) return acc;
    auto& allocator = Allocator::instance();
    ElmString* s = static_cast<ElmString*>(str);

    HPointer result = acc;
    for (i64 i = s->header.size - 1; i >= 0; --i) {
        void* accObj = allocator.resolve(result);
        result = func(s->chars[i], accObj);
    }
    return result;
}

// ============================================================================
// Slicing
// ============================================================================

HPointer slice(i64 start, i64 end, void* str) {
    return StringOps::slice(str, start, end);
}

// ============================================================================
// Splitting
// ============================================================================

HPointer split(void* sep, void* str) {
    return StringOps::split(sep, str);
}

HPointer lines(void* str) {
    if (!str) {
        return alloc::cons(alloc::boxed(alloc::emptyString()), alloc::listNil(), true);
    }
    // Split by \r\n, \r, or \n
    ElmString* s = static_cast<ElmString*>(str);
    size_t len = s->header.size;

    if (len == 0) {
        // Empty string -> list with one empty string
        return alloc::cons(alloc::boxed(alloc::emptyString()), alloc::listNil(), true);
    }

    std::vector<HPointer> parts;
    size_t start = 0;

    for (size_t i = 0; i < len; ++i) {
        bool is_line_end = false;
        size_t skip = 0;

        if (s->chars[i] == '\r') {
            is_line_end = true;
            if (i + 1 < len && s->chars[i + 1] == '\n') {
                skip = 2;  // \r\n
            } else {
                skip = 1;  // \r
            }
        } else if (s->chars[i] == '\n') {
            is_line_end = true;
            skip = 1;  // \n
        }

        if (is_line_end) {
            parts.push_back(alloc::allocString(s->chars + start, i - start));
            start = i + skip;
            i = start - 1;  // Will be incremented by loop
        }
    }

    // Add final part
    parts.push_back(alloc::allocString(s->chars + start, len - start));

    return alloc::listFromPointers(parts);
}

HPointer words(void* str) {
    // Trim and split by whitespace
    HPointer trimmed = StringOps::trim(str);

    if (StringOps::isEmpty(trimmed)) {
        return alloc::listNil();
    }

    auto& allocator = Allocator::instance();
    ElmString* s = static_cast<ElmString*>(allocator.resolve(trimmed));
    size_t len = s->header.size;

    std::vector<HPointer> parts;
    size_t start = 0;
    bool in_word = false;

    for (size_t i = 0; i <= len; ++i) {
        bool is_whitespace = (i == len) ||
            s->chars[i] == ' ' || s->chars[i] == '\t' ||
            s->chars[i] == '\n' || s->chars[i] == '\r';

        if (is_whitespace) {
            if (in_word) {
                parts.push_back(alloc::allocString(s->chars + start, i - start));
                in_word = false;
            }
        } else {
            if (!in_word) {
                start = i;
                in_word = true;
            }
        }
    }

    return alloc::listFromPointers(parts);
}

// ============================================================================
// Transformation
// ============================================================================

HPointer reverse(void* str) {
    return StringOps::reverse(str);
}

HPointer toUpper(void* str) {
    return StringOps::toUpper(str);
}

HPointer toLower(void* str) {
    return StringOps::toLower(str);
}

HPointer trim(void* str) {
    return StringOps::trim(str);
}

HPointer trimLeft(void* str) {
    return StringOps::trimLeft(str);
}

HPointer trimRight(void* str) {
    return StringOps::trimRight(str);
}

// ============================================================================
// Searching
// ============================================================================

bool startsWith(void* prefix, void* str) {
    return StringOps::startsWith(prefix, str);
}

bool endsWith(void* suffix, void* str) {
    return StringOps::endsWith(suffix, str);
}

bool contains(void* needle, void* haystack) {
    return StringOps::contains(needle, haystack);
}

HPointer indexes(void* needle, void* haystack) {
    return StringOps::indexes(needle, haystack);
}

// ============================================================================
// Conversion
// ============================================================================

HPointer toInt(void* str) {
    return StringOps::toInt(str);
}

HPointer toFloat(void* str) {
    return StringOps::toFloat(str);
}

HPointer fromNumber(void* n) {
    if (!n) return alloc::emptyString();
    // Detect type and convert accordingly
    Header* hdr = static_cast<Header*>(n);
    if (hdr->tag == Tag_Int) {
        ElmInt* i = static_cast<ElmInt*>(n);
        return StringOps::fromInt(i->value);
    } else if (hdr->tag == Tag_Float) {
        ElmFloat* f = static_cast<ElmFloat*>(n);
        return StringOps::fromFloat(f->value);
    }
    // Fallback to empty string
    return alloc::emptyString();
}

} // namespace Elm::Kernel::String
