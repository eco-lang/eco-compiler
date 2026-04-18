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
    auto& allocator = Allocator::instance();

    // Collect all char values first (no allocation)
    std::vector<u16> charData;
    HPointer current = chars;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        u16 charVal;
        if (c->header.unboxed & 1) {
            charVal = c->head.c;
        } else {
            void* charObj = allocator.resolve(c->head.p);
            ElmChar* ec = static_cast<ElmChar*>(charObj);
            charVal = ec->value;
        }
        charData.push_back(charVal);
        current = c->tail;
    }

    if (charData.empty()) return alloc::emptyString();

    return alloc::allocString(charData.data(), charData.size());
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

    // Copy char data before any allocation (func may trigger GC)
    std::vector<u16> chars(s->chars, s->chars + s->header.size);

    HPointer result = acc;
    for (size_t i = 0; i < chars.size(); ++i) {
        void* accObj = allocator.resolve(result);
        result = func(chars[i], accObj);
    }
    return result;
}

HPointer foldr(FoldFunc func, HPointer acc, void* str) {
    if (!str) return acc;
    auto& allocator = Allocator::instance();
    ElmString* s = static_cast<ElmString*>(str);

    // Copy char data before any allocation (func may trigger GC)
    std::vector<u16> chars(s->chars, s->chars + s->header.size);

    HPointer result = acc;
    for (i64 i = static_cast<i64>(chars.size()) - 1; i >= 0; --i) {
        void* accObj = allocator.resolve(result);
        result = func(chars[i], accObj);
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
    ElmString* s = static_cast<ElmString*>(str);
    size_t len = s->header.size;

    if (len == 0) {
        return alloc::cons(alloc::boxed(alloc::emptyString()), alloc::listNil(), true);
    }

    // Copy string data before any allocation (void* str can move during GC)
    std::vector<u16> strData(s->chars, s->chars + len);

    // Phase 1: find line boundaries (no allocation)
    struct LineRange { size_t start; size_t len; };
    std::vector<LineRange> ranges;
    size_t start = 0;

    for (size_t i = 0; i < len; ++i) {
        bool is_line_end = false;
        size_t skip = 0;

        if (strData[i] == '\r') {
            is_line_end = true;
            if (i + 1 < len && strData[i + 1] == '\n') {
                skip = 2;
            } else {
                skip = 1;
            }
        } else if (strData[i] == '\n') {
            is_line_end = true;
            skip = 1;
        }

        if (is_line_end) {
            ranges.push_back({start, i - start});
            start = i + skip;
            i = start - 1;
        }
    }
    ranges.push_back({start, len - start});

    // Phase 2: create strings with rooting
    std::vector<HPointer> parts(ranges.size(), alloc::listNil());
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRootPoint();
    for (auto& hp : parts) rs.pushStackRoot(&hp);

    for (size_t i = 0; i < ranges.size(); ++i) {
        parts[i] = alloc::allocString(strData.data() + ranges[i].start, ranges[i].len);
    }

    rs.restoreStackRootPoint(saved);
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

    // Copy string data before any allocation
    std::vector<u16> strData(s->chars, s->chars + len);

    // Phase 1: find word boundaries (no allocation)
    struct WordRange { size_t start; size_t len; };
    std::vector<WordRange> ranges;
    size_t start = 0;
    bool in_word = false;

    for (size_t i = 0; i <= len; ++i) {
        bool is_whitespace = (i == len) ||
            strData[i] == ' ' || strData[i] == '\t' ||
            strData[i] == '\n' || strData[i] == '\r';

        if (is_whitespace) {
            if (in_word) {
                ranges.push_back({start, i - start});
                in_word = false;
            }
        } else {
            if (!in_word) {
                start = i;
                in_word = true;
            }
        }
    }

    if (ranges.empty()) return alloc::listNil();

    // Phase 2: create strings with rooting
    std::vector<HPointer> parts(ranges.size(), alloc::listNil());
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRootPoint();
    for (auto& hp : parts) rs.pushStackRoot(&hp);

    for (size_t i = 0; i < ranges.size(); ++i) {
        parts[i] = alloc::allocString(strData.data() + ranges[i].start, ranges[i].len);
    }

    rs.restoreStackRootPoint(saved);
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
