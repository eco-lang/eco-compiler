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
    // Two-pass: count list length, allocate exact-size result, then walk
    // again writing chars directly into the heap object. Eliminates the
    // std::vector + allocString intermediate copy.
    auto& allocator = Allocator::instance();

    size_t count = 0;
    HPointer current = chars;
    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;
        Cons* c = static_cast<Cons*>(cell);
        ++count;
        current = c->tail;
    }
    if (count == 0) return alloc::emptyString();

    // Root the list across the allocation; the result chars[] are filled
    // before any further alloc, so we don't need to re-root mid-loop.
    alloc::BlankString out;
    {
        Elm::StackRootGuard guard(&chars);
        out = alloc::allocStringBlank(count);
    }
    size_t idx = 0;
    current = chars;
    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;
        Cons* c = static_cast<Cons*>(cell);
        u16 charVal;
        if (Elm::tupleFieldKind(c->header.unboxed, 0) != 0) {
            charVal = c->head.c;
        } else {
            void* charObj = allocator.resolve(c->head.p);
            ElmChar* ec = static_cast<ElmChar*>(charObj);
            charVal = ec->value;
        }
        out.chars[idx++] = charVal;
        current = c->tail;
    }
    return out.hp;
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

    // Snapshot chars before any allocation. toStdU16String is tag-aware so
    // a slice input transparently materialises through its base.
    auto snapshot = StringOps::toStdU16String(str);

    HPointer result = acc;
    for (auto c : snapshot) {
        void* accObj = allocator.resolve(result);
        result = func(c, accObj);
    }
    return result;
}

HPointer foldr(FoldFunc func, HPointer acc, void* str) {
    if (!str) return acc;
    auto& allocator = Allocator::instance();

    auto snapshot = StringOps::toStdU16String(str);

    HPointer result = acc;
    for (i64 i = static_cast<i64>(snapshot.size()) - 1; i >= 0; --i) {
        void* accObj = allocator.resolve(result);
        result = func(snapshot[i], accObj);
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
    auto snapshot = StringOps::toStdU16String(str);
    size_t len = snapshot.size();

    if (len == 0) {
        return alloc::cons(alloc::boxed(alloc::emptyString()), alloc::listNil(), true);
    }

    // The snapshot std::u16string is already a contiguous u16 buffer on the
    // C stack; no need to duplicate into a separate std::vector.
    const u16* strData = reinterpret_cast<const u16*>(snapshot.data());

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
    size_t saved = rs.stackRangePoint();
    rs.pushStackRootRange(parts.data(), parts.size(), ~0ULL);

    for (size_t i = 0; i < ranges.size(); ++i) {
        parts[i] = alloc::allocString(strData + ranges[i].start, ranges[i].len);
    }

    rs.restoreStackRangePoint(saved);
    return alloc::listFromPointers(parts);
}

HPointer words(void* str) {
    // Trim and split by whitespace
    HPointer trimmed = StringOps::trim(str);

    if (StringOps::isEmpty(trimmed)) {
        return alloc::listNil();
    }

    auto& allocator = Allocator::instance();
    void* trimmedObj = allocator.resolve(trimmed);
    auto snapshot = StringOps::toStdU16String(trimmedObj);
    size_t len = snapshot.size();

    const u16* strData = reinterpret_cast<const u16*>(snapshot.data());

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
    size_t saved = rs.stackRangePoint();
    rs.pushStackRootRange(parts.data(), parts.size(), ~0ULL);

    for (size_t i = 0; i < ranges.size(); ++i) {
        parts[i] = alloc::allocString(strData + ranges[i].start, ranges[i].len);
    }

    rs.restoreStackRangePoint(saved);
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
