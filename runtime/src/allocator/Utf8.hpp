/**
 * UTF-8 scanning / widening primitives.
 *
 * Header-only, layout-only dependency (Heap.hpp for the u8/u16/u32 aliases);
 * no allocator, no GC, no allocation. This is the single shared codec used by
 * the UTF-8 String representation (Tag_StringUtf8View / Tag_StringUtf8Leaf):
 * it decides whether a byte range may become a UTF-8 string form and, when it
 * may, yields the logical UTF-16 code-unit length for free.
 *
 * `scan` mirrors the validation pass of elm_utf8_decode
 * (runtime/src/allocator/ElmBytesRuntime.cpp) EXACTLY, so a byte range that
 * `scan` accepts is decoded identically by every existing decoder — the new
 * UTF-8 forms therefore never hold content the old paths would have rejected.
 * The existing six UTF-8 codec sites are intentionally left untouched (they
 * carry three deliberately different strictness levels; see
 * design_docs/utf8-string-encoding-investigation.md §1.4 / Appendix B).
 */

#ifndef ECO_UTF8_HPP
#define ECO_UTF8_HPP

#include "Heap.hpp"   // u8, u16, u32 (layout aliases only)
#include <cstddef>    // size_t

namespace Elm {
namespace Utf8 {

// Result of a single validation+count pass over a byte range.
struct ScanResult {
    bool valid;      // the range is strictly valid UTF-8
    bool ascii;      // valid AND every byte < 0x80 (equivalently utf16Units==len)
    u32  utf16Units; // logical UTF-16 code-unit count; meaningful only when valid
};

/**
 * Strict single-pass UTF-8 validation + UTF-16 code-unit count over
 * [p, p+len). Mirrors elm_utf8_decode's pass 1 exactly:
 *   - continuation-byte structure (top bits 10 on trailing bytes),
 *   - truncation at end of buffer,
 *   - overlong rejection (2-byte cp<0x80, 3-byte cp<0x800, 4-byte cp<0x10000),
 *   - UTF-16 surrogate range 0xD800..0xDFFF rejected,
 *   - cp>0x10FFFF rejected.
 * On any violation returns {valid=false, ascii=false, utf16Units=<partial>}.
 *
 * `ascii` is true iff the whole range is valid AND every byte is < 0x80. For
 * valid input that is exactly `utf16Units == len` (any multibyte sequence
 * consumes strictly more bytes than the units it contributes), which is the
 * cheap ASCII gate the UTF-8 forms rely on.
 */
inline ScanResult scan(const u8* p, size_t len) {
    u32 units = 0;
    size_t i = 0;
    while (i < len) {
        u8 c = p[i];
        if ((c & 0x80) == 0) {                     // 1-byte (ASCII)
            units += 1;
            i += 1;
        } else if ((c & 0xE0) == 0xC0) {           // 2-byte
            if (i + 1 >= len) return {false, false, units};
            u8 c2 = p[i + 1];
            if ((c2 & 0xC0) != 0x80) return {false, false, units};
            u32 cp = (static_cast<u32>(c & 0x1F) << 6) | static_cast<u32>(c2 & 0x3F);
            if (cp < 0x80) return {false, false, units};              // overlong
            units += 1;
            i += 2;
        } else if ((c & 0xF0) == 0xE0) {           // 3-byte
            if (i + 2 >= len) return {false, false, units};
            u8 c2 = p[i + 1], c3 = p[i + 2];
            if ((c2 & 0xC0) != 0x80 || (c3 & 0xC0) != 0x80)
                return {false, false, units};
            u32 cp = (static_cast<u32>(c & 0x0F) << 12) |
                     (static_cast<u32>(c2 & 0x3F) << 6) |
                     static_cast<u32>(c3 & 0x3F);
            if (cp < 0x800) return {false, false, units};             // overlong
            if (cp >= 0xD800 && cp <= 0xDFFF) return {false, false, units}; // surrogate
            units += 1;
            i += 3;
        } else if ((c & 0xF8) == 0xF0) {           // 4-byte
            if (i + 3 >= len) return {false, false, units};
            u8 c2 = p[i + 1], c3 = p[i + 2], c4 = p[i + 3];
            if ((c2 & 0xC0) != 0x80 || (c3 & 0xC0) != 0x80 || (c4 & 0xC0) != 0x80)
                return {false, false, units};
            u32 cp = (static_cast<u32>(c & 0x07) << 18) |
                     (static_cast<u32>(c2 & 0x3F) << 12) |
                     (static_cast<u32>(c3 & 0x3F) << 6) |
                     static_cast<u32>(c4 & 0x3F);
            if (cp < 0x10000 || cp > 0x10FFFF) return {false, false, units};
            units += 2;                            // astral => surrogate pair
            i += 4;
        } else {                                   // 0x80..0xBF stray / 0xF8+ lead
            return {false, false, units};
        }
    }
    return {true, units == static_cast<u32>(len), units};
}

/**
 * True iff every byte in [p, p+len) is < 0x80. All-ASCII byte ranges are
 * trivially valid UTF-8, so this is a cheaper gate than `scan` when the caller
 * does not need the (equal-to-len) unit count or full multibyte validation.
 */
inline bool allAscii(const u8* p, size_t len) {
    for (size_t i = 0; i < len; ++i) {
        if (p[i] & 0x80) return false;
    }
    return true;
}

/**
 * Zero-extend ASCII bytes to UTF-16 code units: dst[i] = src[i]. The caller
 * guarantees the range is all-ASCII (each byte < 0x80), so the widened unit
 * equals the code point. `dst` must have room for `n` u16 values.
 */
inline void widenAscii(const u8* src, size_t n, u16* dst) {
    for (size_t i = 0; i < n; ++i) {
        dst[i] = static_cast<u16>(src[i]);
    }
}

} // namespace Utf8
} // namespace Elm

#endif // ECO_UTF8_HPP
