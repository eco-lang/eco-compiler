#pragma once
// Unicode case mapping of Char values (plans/char-case-mapping-elm-exact.md, KERN_008): node's
// toUpperCase/toLowerCase per code point, from the generated CaseMapTables.hpp. Every function is
// inline and allocation-free.
#include <cassert>
#include <cstddef>
#include <cstdint>

#include "CaseMapTables.hpp"
#include "CharValue.hpp"

namespace Elm::CaseMap {

// The table entry of an encoded Char value.
inline const Entry& entry(uint32_t v) {
    assert((v & CharValue::kReservedMask) == 0 && CharValue::isEncoded(v));
    uint32_t r = CharValue::rank(v);
    assert(r < kEntryCount);
    const Entry& e = kEntries[r];
    assert(e.units[0] == CharValue::firstCodePoint(v));
    return e;
}

namespace detail {
// The `to` of `from == cp` in a table sorted by `from`, or cp when absent.
inline uint32_t lookup(const Pair* table, uint32_t count, uint32_t cp) {
    uint32_t lo = 0, hi = count;
    while (lo < hi) {
        uint32_t mid = lo + (hi - lo) / 2;
        if (table[mid].from < cp) lo = mid + 1;
        else hi = mid;
    }
    if (lo < count && table[lo].from == cp) {
        uint32_t to = table[lo].to;
        // Build flag OFF: an expanding mapping leaves the code point unchanged.
        if constexpr (!CharValue::kExpansions) {
            if (CharValue::hasRankBits(to)) return cp;
        }
        return to;
    }
    return cp;
}

inline bool inRanges(const Range* table, uint32_t count, uint32_t cp) {
    uint32_t lo = 0, hi = count;
    while (lo < hi) {
        uint32_t mid = lo + (hi - lo) / 2;
        if (table[mid].hi < cp) lo = mid + 1;
        else hi = mid;
    }
    return lo < count && table[lo].lo <= cp;
}
}  // namespace detail

// Char.toUpper: Char value to Char value.
inline uint32_t upper(uint32_t v) {
    if (v < 0x80) return (v >= 'a' && v <= 'z') ? v - 32 : v;
    if (CharValue::isEncoded(v)) return entry(v).upper;
    return detail::lookup(kUpper, kUpperCount, v);
}

// Char.toLower: Char value to Char value.
inline uint32_t lower(uint32_t v) {
    if (v < 0x80) return (v >= 'A' && v <= 'Z') ? v + 32 : v;
    if (CharValue::isEncoded(v)) return entry(v).lower;
    return detail::lookup(kLower, kLowerCount, v);
}

// UTF-16 units of the String of a Char value (1..CharValue::kMaxCharUnits).
inline uint32_t units(uint32_t v) {
    if (v <= 0xFFFFu) return 1;
    if (v <= 0x10FFFFu) return 2;
    if (CharValue::isEncoded(v)) return entry(v).len;
    return 1;   // 0x110000..0x1FFFFF (never produced): U+FFFD
}

// Writes the String of a Char value as UTF-16 into out (room for CharValue::kMaxCharUnits
// units); returns the unit count. A code point <= 0xFFFF (a lone surrogate too) is one unit,
// 0x10000..0x10FFFF a surrogate pair, an encoded value its expansion, anything else U+FFFD.
inline uint32_t writeUnits(uint32_t v, uint16_t* out) {
    if (v <= 0xFFFFu) { out[0] = static_cast<uint16_t>(v); return 1; }
    if (v <= 0x10FFFFu) {
        uint32_t w = v - 0x10000u;
        out[0] = static_cast<uint16_t>(0xD800u + (w >> 10));
        out[1] = static_cast<uint16_t>(0xDC00u + (w & 0x3FFu));
        return 2;
    }
    if (CharValue::isEncoded(v)) {
        const Entry& e = entry(v);
        for (uint32_t i = 0; i < e.len; i++) out[i] = e.units[i];
        return e.len;
    }
    out[0] = 0xFFFDu;
    return 1;
}

inline bool isCased(uint32_t cp) { return detail::inRanges(kCased, kCasedCount, cp); }
inline bool isCaseIgnorable(uint32_t cp) { return detail::inRanges(kCaseIgnorable, kCaseIgnorableCount, cp); }

// Final_Sigma for the capital sigma at units [start, end) of p[0..n): true (lower to U+03C2) iff
// scanning back from it, skipping Case_Ignorable code points, reaches a Cased one, and scanning
// forward the same way does not. The skip is greedy: a code point that is both Cased and
// Case_Ignorable is skipped. Decoding pairs only valid surrogate pairs, like
// StringOps::nextCodePoint/prevCodePoint.
inline bool finalSigmaAt(const uint16_t* p, size_t n, size_t start, size_t end) {
    auto isHi = [](uint32_t u) { return u >= 0xD800u && u <= 0xDBFFu; };
    auto isLo = [](uint32_t u) { return u >= 0xDC00u && u <= 0xDFFFu; };
    auto join = [](uint32_t h, uint32_t l) { return 0x10000u + ((h - 0xD800u) << 10) + (l - 0xDC00u); };
    bool before = false;
    for (size_t i = start; i > 0;) {
        uint32_t u = p[--i];
        if (isLo(u) && i > 0 && isHi(p[i - 1])) u = join(p[--i], u);
        if (isCaseIgnorable(u)) continue;
        before = isCased(u);
        break;
    }
    if (!before) return false;
    for (size_t i = end; i < n;) {
        uint32_t u = p[i++];
        if (isHi(u) && i < n && isLo(p[i])) u = join(u, p[i++]);
        if (isCaseIgnorable(u)) continue;
        return !isCased(u);
    }
    return true;
}

}  // namespace Elm::CaseMap
