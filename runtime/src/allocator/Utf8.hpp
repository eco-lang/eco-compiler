// Utf8.hpp - strict UTF-8 validation and ASCII widening over raw bytes.
//
// An Elm string may be held as UTF-8 bytes (the `Tag_StringUtf8View` and
// `Tag_StringUtf8Leaf` forms) as well as UTF-16 code units. Bytes may take a
// UTF-8 form only if they are valid UTF-8, and the runtime counts a string's
// length in UTF-16 code units, so whoever builds such a form needs both answers
// about the bytes. `scan` gives them in one pass. `allAscii` and `widenAscii`
// serve the all-ASCII case, a range of bytes all below 0x80, which is valid
// UTF-8 and whose UTF-16 units equal its bytes.
//
// Valid here means strict: no truncated sequence, no stray continuation byte,
// no overlong encoding, no surrogate code point (0xD800..0xDFFF), and nothing
// above 0x10FFFF. `scan` applies the same checks, in the same order, as the
// first (validating) pass of `elm_utf8_decode` in ElmBytesRuntime.cpp, so a
// range `scan` accepts is one that decoder accepts too. That correspondence is
// kept by hand; nothing in the code ties the two together.
//
// Everything here is a pure function over caller-owned memory: it allocates
// nothing and knows nothing of the heap beyond the `u8`/`u16`/`u32` aliases
// from Heap.hpp.

#ifndef ECO_UTF8_HPP
#define ECO_UTF8_HPP

#include "Heap.hpp"   // u8, u16, u32 (layout aliases only)
#include <cstddef>    // size_t

namespace Elm {
namespace Utf8 {

/// What one `scan` learned about a range of bytes.
struct ScanResult {
    bool valid;      ///< The range is strictly valid UTF-8.
    bool ascii;      ///< The range is valid and every byte is below 0x80. Always false when `valid` is false.
    /// The length of the range in UTF-16 code units. When `valid` is false it
    /// counts only the sequences before the first invalid one.
    u32  utf16Units;
};

/// Checks that the `len` bytes at `p` are strictly valid UTF-8, as the file
/// comment defines it, and counts the UTF-16 code units they decode to.
///
/// A code point above 0xFFFF counts as two units, a surrogate pair; every
/// other code point counts as one. A valid range is therefore all ASCII
/// exactly when its unit count equals `len`, which is how `ascii` is decided.
/// The scan stops at the first invalid sequence. An empty range is valid and
/// ASCII, with no units. `p` must point to at least `len` readable bytes; it
/// is not kept.
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

/// Returns whether every one of the `len` bytes at `p` is below 0x80.
///
/// Such a range is valid UTF-8 and its UTF-16 unit count is `len`, so this is
/// a cheaper test than `scan` when only the all-ASCII case is wanted.
inline bool allAscii(const u8* p, size_t len) {
    for (size_t i = 0; i < len; ++i) {
        if (p[i] & 0x80) return false;
    }
    return true;
}

/// Writes each of the `n` bytes at `src`, zero-extended, to the `n` UTF-16
/// code units at `dst`.
///
/// The bytes must all be below 0x80, which nothing here checks; only then is
/// each unit the character its byte encodes. `dst` must have room for `n`
/// units.
inline void widenAscii(const u8* src, size_t n, u16* dst) {
    for (size_t i = 0; i < n; ++i) {
        dst[i] = static_cast<u16>(src[i]);
    }
}

} // namespace Utf8
} // namespace Elm

#endif // ECO_UTF8_HPP
