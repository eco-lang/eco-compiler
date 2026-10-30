#pragma once
// Unicode simple case mapping of Chars (plans/char-simple-case-mapping.md, invariant KERN_008,
// design_docs/char-case-mapping.md). A Char is one code point (0..0x10FFFF; a lone surrogate is its
// unit value), and case mapping takes one code point to one code point: UnicodeData.txt fields 12
// and 13, from the generated CaseMapTables.hpp, with no context and no locale. Every function is
// inline and allocation-free.
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <iterator>

#include "CaseMapTables.hpp"

namespace Elm::CaseMap {

namespace detail {
// The `to` of the pair whose `from` is `cp` in the sorted table `t` of `n` pairs, or `cp` when
// there is none.
inline uint32_t lookup(const CasePair* t, size_t n, uint32_t cp) {
    const CasePair* end = t + n;
    const CasePair* it =
        std::lower_bound(t, end, cp, [](const CasePair& p, uint32_t c) { return p.from < c; });
    return (it != end && it->from == cp) ? it->to : cp;
}
}  // namespace detail

// Char.toUpper: the simple uppercase mapping of `cp`, or `cp` itself.
inline uint32_t upper(uint32_t cp) {
    if (cp < 0x80) return (cp >= 'a' && cp <= 'z') ? cp - 32 : cp;
    return detail::lookup(kUpper, std::size(kUpper), cp);
}

// Char.toLower: the simple lowercase mapping of `cp`, or `cp` itself.
inline uint32_t lower(uint32_t cp) {
    if (cp < 0x80) return (cp >= 'A' && cp <= 'Z') ? cp + 32 : cp;
    return detail::lookup(kLower, std::size(kLower), cp);
}

// The number of UTF-16 units `writeUnits` writes for `cp`: 2 for a supplementary code point, 1
// otherwise (a value above 0x10FFFF is written as one U+FFFD).
inline uint32_t units(uint32_t cp) { return (cp >= 0x10000 && cp <= 0x10FFFF) ? 2 : 1; }

// Writes `cp` to `out` as UTF-16 and returns the number of units, 1 or 2. A surrogate value is
// written as its own unit. Nothing produces a value above 0x10FFFF; one is written as U+FFFD so
// that no invalid pair is ever written. Agrees with `units`.
inline uint32_t writeUnits(uint32_t cp, uint16_t* out) {
    if (cp > 0x10FFFF) {
        out[0] = 0xFFFD;
        return 1;
    }
    if (cp < 0x10000) {
        out[0] = static_cast<uint16_t>(cp);
        return 1;
    }
    uint32_t v = cp - 0x10000;
    out[0] = static_cast<uint16_t>(0xD800 + (v >> 10));
    out[1] = static_cast<uint16_t>(0xDC00 + (v & 0x3FF));
    return 2;
}

}  // namespace Elm::CaseMap
