#pragma once
// A Char value (invariant KERN_008, plans/char-case-mapping-elm-exact.md): a u32 that is either
// an ordinary Unicode code point (0..0x10FFFF; a lone surrogate is its unit value) or an encoded
// multi-code-point case-mapping result (Char.toUpper 'ß' is "SS"):
//
//    31   29 28        21 20                   0
//   ┌───────┬────────────┬──────────────────────┐
//   │ 0 0 0 │ rank+1 (8) │ code point (21 b)    │
//   └───────┴────────────┴──────────────────────┘
//
// bits 0-20 hold the expansion's first code point, bits 21-28 hold rank + 1 into
// CaseMap::kEntries (CaseMap.hpp), and bits 29-31 are reserved and always zero. Only
// Char.toUpper/toLower/toLocaleUpper/toLocaleLower produce encoded values.
//
// Build flag ECO_CHAR_CASE_EXPANSION (root CMakeLists.txt, default ON). OFF makes isEncoded the
// constant false and firstCodePoint/sortKey the identity, so every encoded-value path is compiled
// out, and CaseMap::upper/lower leave an expanding code point unchanged. This header holds no
// tables and depends only on <cstdint>, so the codegen can include it.
#include <cstdint>

#ifndef ECO_CHAR_CASE_EXPANSION
#error "ECO_CHAR_CASE_EXPANSION is not defined: this file is compiled outside the CMake build"
#endif

namespace Elm::CharValue {

inline constexpr bool kExpansions = ECO_CHAR_CASE_EXPANSION != 0;

inline constexpr uint32_t kFirstMask = 0x1FFFFF;                       // bits 0-20
inline constexpr uint32_t kRankShift = 21;                             // bits 21-28 = rank + 1
inline constexpr uint32_t kRankBits = 8;                               // at most 255 entries
inline constexpr uint32_t kRankMask = 0xFFu << kRankShift;             // 0x1FE00000
inline constexpr uint32_t kReservedMask = ~(kFirstMask | kRankMask);   // bits 29-31, always zero
inline constexpr uint32_t kMaxCharUnits = kExpansions ? 3 : 2;         // UTF-16 units of one Char

// The raw bit test; only the table code (CaseMap::upper/lower, CaseMapTest) uses it.
inline constexpr bool hasRankBits(uint32_t v) { return v > kFirstMask; }

// Constant false when OFF, so every encoded-value path guarded by it is compiled out.
inline constexpr bool isEncoded(uint32_t v) { return kExpansions && hasRankBits(v); }

// Char.toCode: the code point, or an expansion's first code point.
inline constexpr uint32_t firstCodePoint(uint32_t v) {
    if constexpr (kExpansions) return v & kFirstMask;
    else return v;
}

// Index into CaseMap::kEntries; isEncoded(v) only.
inline constexpr uint32_t rank(uint32_t v) { return ((v & kRankMask) >> kRankShift) - 1; }

// The ordering key: rotl32(v, 11). With bits 29-31 zero, (v >> 21) is exactly rank + 1 (0 for an
// ordinary code point), so Chars order by (first code point, then 0 or rank + 1), which equals
// JS UTF-16 string order wherever an encoded value takes part.
inline constexpr uint32_t sortKey(uint32_t v) {
    if constexpr (kExpansions) return (v << 11) | (v >> kRankShift);
    else return v;
}

inline constexpr int compare(uint32_t a, uint32_t b) {
    uint32_t x = sortKey(a), y = sortKey(b);
    return x < y ? -1 : x > y ? 1 : 0;
}

// Build-mismatch guard: the runtime defines only the function of its own setting
// (RuntimeExports.cpp), and the backend calls the one of its setting at the top of @main
// (EcoToLLVM.cpp). A program lowered with one setting fails to link against a runtime built with
// the other, instead of comparing encoded Chars as raw integers.
inline constexpr const char* kBuildGuardSymbol =
    kExpansions ? "eco_char_case_expansion_on" : "eco_char_case_expansion_off";

}  // namespace Elm::CharValue
