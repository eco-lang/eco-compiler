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

HPointer cons(u32 c, void* str) {
    return StringOps::cons(c, str);
}

HPointer uncons(void* str) {
    return StringOps::uncons(str);
}

// Returns the Char in the head of the list cell `c`, held unboxed or as a boxed `ElmChar`. Does not
// allocate. Nothing calls it.
static u32 consCellChar(Allocator& allocator, Cons* c) {
    if (Elm::tupleFieldKind(c->header.unboxed, 0) != 0) {
        return c->head.c;
    }
    void* charObj = allocator.resolve(c->head.p);
    return static_cast<ElmChar*>(charObj)->value;
}

// Returns the Char in the list element `v` whose slot kind is `kind`, as `alloc::ListCursor` gives
// them: `v` holds it unboxed when `kind` is nonzero, and otherwise refers to a boxed `ElmChar`. Does
// not allocate.
static u32 elemChar(Allocator& allocator, Elm::Unboxable v, u8 kind) {
    if (kind != 0) return v.c;
    void* charObj = allocator.resolve(v.p);
    return static_cast<ElmChar*>(charObj)->value;
}

HPointer fromList(HPointer chars) {
    // Two passes over the list: the first counts the result's units without allocating, and the
    // second writes the Chars straight into the one String allocated between them.
    auto& allocator = Allocator::instance();

    // `count` is in UTF-16 units: an astral code point encodes as a
    // surrogate pair (StringOps::encodeCodePoint). The ASCII gate stays valid
    // because any code point >= 0x80 sets a bit >= 0x80 in `acc`.
    size_t count = 0;
    u32 acc = 0;  // or-accumulate: acc < 0x80 <=> every char is ASCII
    for (alloc::ListCursor c(chars); !c.done(); c.next()) {
        u32 cp = elemChar(allocator, c.current(), c.currentKind());
        acc |= cp;
        count += StringOps::codePointUnits(cp);
    }
    if (count == 0) return alloc::emptyString();

    // All ASCII: the result is a UTF-8 form, allocated and written as on the UTF-16 path below.
    if (acc < 0x80 && allocator.getConfig().utf8_strings_enabled) {
        StringOps::AsciiOut out;
        {
            Elm::StackRootGuard guard(&chars);
            out = StringOps::allocAsciiOut(count);
        }
        size_t idx = 0;
        for (alloc::ListCursor c(chars); !c.done(); c.next()) {
            out.dst[idx++] =
                static_cast<u8>(elemChar(allocator, c.current(), c.currentKind()));
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
    for (alloc::ListCursor c(chars); !c.done(); c.next()) {
        idx += StringOps::encodeCodePoint(
            elemChar(allocator, c.current(), c.currentKind()), out.chars + idx);
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

    // Copied out of the heap before `func`, which may allocate, is first called. toStdU16String
    // reads every String form.
    auto snapshot = StringOps::toStdU16String(str);

    HPointer result = acc;
    const u16* p = reinterpret_cast<const u16*>(snapshot.data());
    size_t n = snapshot.size();
    for (size_t i = 0; i < n;) {
        u32 cp = StringOps::nextCodePoint(p, n, i);
        void* accObj = allocator.resolve(result);
        result = func(cp, accObj);
    }
    return result;
}

HPointer foldr(FoldFunc func, HPointer acc, void* str) {
    if (!str) return acc;
    auto& allocator = Allocator::instance();

    auto snapshot = StringOps::toStdU16String(str);

    HPointer result = acc;
    const u16* p = reinterpret_cast<const u16*>(snapshot.data());
    for (size_t i = snapshot.size(); i > 0;) {
        u32 cp = StringOps::prevCodePoint(p, i);
        void* accObj = allocator.resolve(result);
        result = func(cp, accObj);
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
    // A UTF-8 form: scan its bytes, which are UTF-16 units under the ASCII rule, and cut each line
    // with slice rather than widening the String.
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
        // One range roots the whole buffer: an all-ones mask marks every slot whatever the length,
        // and a slot not yet filled holds the Nil constant, which the collector leaves alone.
        rs.pushStackRootRange(parts.data(), parts.size(), ~0ULL);
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

    // The copy's buffer is C++ memory, outside the collected heap, so the allocations below do not
    // move it.
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
    // One range roots the whole buffer: an all-ones mask marks every slot whatever the length,
    // and a slot not yet filled holds the Nil constant, which the collector leaves alone.
    rs.pushStackRootRange(parts.data(), parts.size(), ~0ULL);

    for (size_t i = 0; i < ranges.size(); ++i) {
        parts[i] = alloc::allocString(strData + ranges[i].start, ranges[i].len);
    }

    rs.restoreStackRangePoint(saved);
    return alloc::listFromPointers(parts);
}

HPointer words(void* str) {
    // elm/core's JS kernel computes `str.trim().split(/\s+/g)`; this does the same.
    HPointer trimmed = StringOps::trim(str);

    if (StringOps::isEmpty(trimmed)) {
        std::vector<HPointer> one{alloc::emptyString()};
        return alloc::listFromPointers(one);
    }

    auto& allocator = Allocator::instance();

    // A UTF-8 form: scan its bytes and cut each word with slice rather than widening the String.
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
            // UTF-8 forms hold ASCII only, so a byte is a whole unit here.
            bool ws = (i == len) || StringOps::isJsWhitespace(d[i]);
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
        // One range roots the whole buffer: an all-ones mask marks every slot whatever the length,
        // and a slot not yet filled holds the Nil constant, which the collector leaves alone.
        rs.pushStackRootRange(parts.data(), parts.size(), ~0ULL);
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
        bool is_whitespace = (i == len) || StringOps::isJsWhitespace(strData[i]);

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
    // One range roots the whole buffer: an all-ones mask marks every slot whatever the length,
    // and a slot not yet filled holds the Nil constant, which the collector leaves alone.
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
    Header* hdr = static_cast<Header*>(n);
    if (hdr->tag == Tag_Int) {
        ElmInt* i = static_cast<ElmInt*>(n);
        return StringOps::fromInt(i->value);
    } else if (hdr->tag == Tag_Float) {
        ElmFloat* f = static_cast<ElmFloat*>(n);
        return StringOps::fromFloat(f->value);
    }
    return alloc::emptyString();
}

} // namespace Elm::Kernel::String
