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

// Reads the Char value out of a list cell (unboxed slot or boxed ElmChar).
// Resolve-only: performs no allocation.
static u16 consCellChar(Allocator& allocator, Cons* c) {
    if (Elm::tupleFieldKind(c->header.unboxed, 0) != 0) {
        return c->head.c;
    }
    void* charObj = allocator.resolve(c->head.p);
    return static_cast<ElmChar*>(charObj)->value;
}

HPointer fromList(HPointer chars) {
    // Two-pass: count list length, allocate exact-size result, then walk
    // again writing chars directly into the heap object. Eliminates the
    // std::vector + allocString intermediate copy.
    auto& allocator = Allocator::instance();

    size_t count = 0;
    u16 acc = 0;  // or-accumulate: acc < 0x80 <=> every char is ASCII
    HPointer current = chars;
    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;
        Cons* c = static_cast<Cons*>(cell);
        acc |= consCellChar(allocator, c);
        ++count;
        current = c->tail;
    }
    if (count == 0) return alloc::emptyString();

    // All-ASCII => UTF-8 result (seed elimination, see
    // plans/utf16-seed-elimination.md). Same rooting discipline as the
    // UTF-16 path below: one allocation with the list rooted, then an
    // allocation-free write walk.
    if (acc < 0x80 && allocator.getConfig().utf8_strings_enabled) {
        StringOps::AsciiOut out;
        {
            Elm::StackRootGuard guard(&chars);
            out = StringOps::allocAsciiOut(count);
        }
        size_t idx = 0;
        current = chars;
        while (!alloc::isNil(current)) {
            void* cell = allocator.resolve(current);
            if (!cell) break;
            Cons* c = static_cast<Cons*>(cell);
            out.dst[idx++] = static_cast<u8>(consCellChar(allocator, c));
            current = c->tail;
        }
        return StringOps::finishAsciiOut(out);
    }

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
        out.chars[idx++] = consCellChar(allocator, c);
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
    // UTF-8 in => UTF-8 parts (scan bytes, cut via slice; no widen, no UTF-16
    // parts). W4.c. CR/LF are ASCII so the byte scan is identical.
    if (StringOps::isUtf8(str) &&
        Allocator::instance().getConfig().utf8_strings_enabled) {
        auto& allocator = Allocator::instance();
        auto pr = StringOps::utf8Bytes(str);
        const u8* d = pr.first;
        size_t len = pr.second;
        if (len == 0) {
            return alloc::cons(alloc::boxed(alloc::emptyString()), alloc::listNil(), true);
        }
        struct LineRange { size_t start; size_t len; };
        std::vector<LineRange> ranges;
        size_t start = 0;
        for (size_t i = 0; i < len; ++i) {
            bool eol = false;
            size_t skip = 0;
            if (d[i] == '\r') { eol = true; skip = (i + 1 < len && d[i + 1] == '\n') ? 2 : 1; }
            else if (d[i] == '\n') { eol = true; skip = 1; }
            if (eol) { ranges.push_back({start, i - start}); start = i + skip; i = start - 1; }
        }
        ranges.push_back({start, len - start});
        std::vector<HPointer> parts(ranges.size(), alloc::listNil());
        HPointer srcHp = allocator.wrap(str);
        auto& rs = allocator.getRootSet();
        size_t saved = rs.stackRangePoint();
        // Chunk into <=64-slot ranges (StackRootRange mask is 1ULL<<i, UB
        // for i>=64 — see JsonExports.cpp).
        for (size_t base = 0; base < parts.size(); base += 64) {
            size_t chunk = std::min<size_t>(64, parts.size() - base);
            uint64_t mask = (chunk == 64) ? ~uint64_t{0} : ((uint64_t{1} << chunk) - 1);
            rs.pushStackRootRange(parts.data() + base, chunk, mask);
        }
        rs.pushStackRootRange(&srcHp, 1, ~0ULL);
        for (size_t i = 0; i < ranges.size(); ++i) {
            parts[i] = StringOps::slice(allocator.resolve(srcHp),
                                        static_cast<i64>(ranges[i].start),
                                        static_cast<i64>(ranges[i].start + ranges[i].len));
        }
        rs.restoreStackRangePoint(saved);
        return alloc::listFromPointers(parts);
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
    // Chunk into <=64-slot ranges (StackRootRange mask is 1ULL<<i, UB for
    // i>=64 — see JsonExports.cpp). Pre-existing single-range fixed alongside
    // the new UTF-8 arm.
    for (size_t base = 0; base < parts.size(); base += 64) {
        size_t chunk = std::min<size_t>(64, parts.size() - base);
        uint64_t mask = (chunk == 64) ? ~uint64_t{0} : ((uint64_t{1} << chunk) - 1);
        rs.pushStackRootRange(parts.data() + base, chunk, mask);
    }

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

    // UTF-8 in => UTF-8 parts. trim() already returned a UTF-8 form (it cuts
    // via slice); scan its bytes and cut words via slice — no widen. W4.c.
    if (StringOps::isUtf8(allocator.resolve(trimmed)) &&
        allocator.getConfig().utf8_strings_enabled) {
        HPointer trimmedHp = trimmed;
        auto pr = StringOps::utf8Bytes(allocator.resolve(trimmedHp));
        const u8* d = pr.first;
        size_t len = pr.second;
        struct WordRange { size_t start; size_t len; };
        std::vector<WordRange> ranges;
        size_t start = 0;
        bool in_word = false;
        for (size_t i = 0; i <= len; ++i) {
            bool ws = (i == len) ||
                d[i] == ' ' || d[i] == '\t' || d[i] == '\n' || d[i] == '\r';
            if (ws) {
                if (in_word) { ranges.push_back({start, i - start}); in_word = false; }
            } else if (!in_word) {
                start = i;
                in_word = true;
            }
        }
        if (ranges.empty()) return alloc::listNil();
        std::vector<HPointer> parts(ranges.size(), alloc::listNil());
        auto& rs = allocator.getRootSet();
        size_t saved = rs.stackRangePoint();
        // Chunk into <=64-slot ranges (mask is 1ULL<<i, UB for i>=64).
        for (size_t base = 0; base < parts.size(); base += 64) {
            size_t chunk = std::min<size_t>(64, parts.size() - base);
            uint64_t mask = (chunk == 64) ? ~uint64_t{0} : ((uint64_t{1} << chunk) - 1);
            rs.pushStackRootRange(parts.data() + base, chunk, mask);
        }
        rs.pushStackRootRange(&trimmedHp, 1, ~0ULL);
        for (size_t i = 0; i < ranges.size(); ++i) {
            parts[i] = StringOps::slice(allocator.resolve(trimmedHp),
                                        static_cast<i64>(ranges[i].start),
                                        static_cast<i64>(ranges[i].start + ranges[i].len));
        }
        rs.restoreStackRangePoint(saved);
        return alloc::listFromPointers(parts);
    }

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
    // Chunk into <=64-slot ranges (StackRootRange mask is 1ULL<<i, UB for
    // i>=64 — see JsonExports.cpp). Pre-existing single-range fixed alongside
    // the new UTF-8 arm.
    for (size_t base = 0; base < parts.size(); base += 64) {
        size_t chunk = std::min<size_t>(64, parts.size() - base);
        uint64_t mask = (chunk == 64) ? ~uint64_t{0} : ((uint64_t{1} << chunk) - 1);
        rs.pushStackRootRange(parts.data() + base, chunk, mask);
    }

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
