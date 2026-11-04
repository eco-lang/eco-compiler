#include "Url.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/StringOps.hpp"
#include <vector>

namespace Elm::Kernel::Url {

/// Returns whether byte `c` is one `percentEncode` leaves as it is: `A-Za-z0-9` or one of `-_.!~*'()`.
static bool isUnreserved(u8 c) {
    if (c >= 'A' && c <= 'Z') return true;
    if (c >= 'a' && c <= 'z') return true;
    if (c >= '0' && c <= '9') return true;
    switch (c) {
        case '-': case '_': case '.': case '!':
        case '~': case '*': case '\'': case '(':
        case ')':
            return true;
    }
    return false;
}

/// Returns the value of hexadecimal digit `c`, in either case, or -1 if `c` is not one.
static i64 hexValue(u16 c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

/// Returns the uppercase hexadecimal digit for `value`, which must be from 0 to 15.
static u16 toHex(i64 value) {
    if (value < 10) return static_cast<u16>('0' + value);
    return static_cast<u16>('A' + value - 10);
}

/// Returns the UTF-8 encoding of the UTF-16 units in `src`.
///
/// A high surrogate followed by a low one becomes one four-byte sequence. Any other surrogate is encoded as the
/// three-byte sequence of its unit value, which is not valid UTF-8.
static std::vector<u8> utf16ToUtf8(const std::u16string& src) {
    std::vector<u8> result;

    for (size_t i = 0; i < src.size(); i++) {
        u32 codepoint = src[i];

        if (codepoint >= 0xD800 && codepoint <= 0xDBFF && i + 1 < src.size()) {
            u16 low = src[i + 1];
            if (low >= 0xDC00 && low <= 0xDFFF) {
                codepoint = 0x10000 + ((codepoint - 0xD800) << 10) + (low - 0xDC00);
                i++;
            }
        }

        if (codepoint < 0x80) {
            result.push_back(static_cast<u8>(codepoint));
        }
        else if (codepoint < 0x800) {
            result.push_back(static_cast<u8>(0xC0 | (codepoint >> 6)));
            result.push_back(static_cast<u8>(0x80 | (codepoint & 0x3F)));
        }
        else if (codepoint < 0x10000) {
            result.push_back(static_cast<u8>(0xE0 | (codepoint >> 12)));
            result.push_back(static_cast<u8>(0x80 | ((codepoint >> 6) & 0x3F)));
            result.push_back(static_cast<u8>(0x80 | (codepoint & 0x3F)));
        }
        else {
            result.push_back(static_cast<u8>(0xF0 | (codepoint >> 18)));
            result.push_back(static_cast<u8>(0x80 | ((codepoint >> 12) & 0x3F)));
            result.push_back(static_cast<u8>(0x80 | ((codepoint >> 6) & 0x3F)));
            result.push_back(static_cast<u8>(0x80 | (codepoint & 0x3F)));
        }
    }

    return result;
}

/// Decodes the UTF-8 `bytes` into UTF-16 units in `result`, and returns whether they were valid UTF-8.
///
/// Overlong forms, encoded surrogates, values above U+10FFFF, bad continuation bytes and a sequence cut off by
/// the end are invalid. `result` is cleared first; when the function returns false it holds the units decoded
/// before the invalid sequence.
static bool utf8ToUtf16(const std::vector<u8>& bytes, std::vector<u16>& result) {
    result.clear();
    size_t i = 0;

    while (i < bytes.size()) {
        u8 b0 = bytes[i++];
        u32 codepoint;

        if ((b0 & 0x80) == 0) {
            codepoint = b0;
        }
        else if ((b0 & 0xE0) == 0xC0) {
            if (i >= bytes.size()) return false;
            u8 b1 = bytes[i++];
            if ((b1 & 0xC0) != 0x80) return false;
            codepoint = ((b0 & 0x1F) << 6) | (b1 & 0x3F);
            if (codepoint < 0x80) return false;
        }
        else if ((b0 & 0xF0) == 0xE0) {
            if (i + 1 >= bytes.size()) return false;
            u8 b1 = bytes[i++];
            u8 b2 = bytes[i++];
            if ((b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80) return false;
            codepoint = ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F);
            if (codepoint < 0x800) return false;
            if (codepoint >= 0xD800 && codepoint <= 0xDFFF) return false;
        }
        else if ((b0 & 0xF8) == 0xF0) {
            if (i + 2 >= bytes.size()) return false;
            u8 b1 = bytes[i++];
            u8 b2 = bytes[i++];
            u8 b3 = bytes[i++];
            if ((b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80 || (b3 & 0xC0) != 0x80) return false;
            codepoint = ((b0 & 0x07) << 18) | ((b1 & 0x3F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F);
            if (codepoint < 0x10000 || codepoint > 0x10FFFF) return false;
        }
        else {
            return false;
        }

        if (codepoint < 0x10000) {
            result.push_back(static_cast<u16>(codepoint));
        }
        else {
            codepoint -= 0x10000;
            result.push_back(static_cast<u16>(0xD800 | (codepoint >> 10)));
            result.push_back(static_cast<u16>(0xDC00 | (codepoint & 0x3FF)));
        }
    }

    return true;
}

HPointer percentEncode(void* str) {
    auto src = StringOps::toStdU16String(str);
    std::vector<u8> utf8 = utf16ToUtf8(src);

    std::vector<u16> result;
    for (u8 byte : utf8) {
        if (isUnreserved(byte)) {
            result.push_back(static_cast<u16>(byte));
        } else {
            result.push_back('%');
            result.push_back(toHex((byte >> 4) & 0x0F));
            result.push_back(toHex(byte & 0x0F));
        }
    }

    return alloc::allocString(result.data(), result.size());
}

HPointer percentDecode(void* str) {
    auto src = StringOps::toStdU16String(str);
    std::vector<u8> bytes;

    for (size_t i = 0; i < src.size(); i++) {
        u16 c = src[i];

        if (c == '%') {
            if (i + 2 >= src.size()) {
                return alloc::nothing();
            }

            i64 high = hexValue(src[i + 1]);
            i64 low = hexValue(src[i + 2]);

            if (high < 0 || low < 0) {
                return alloc::nothing();
            }

            bytes.push_back(static_cast<u8>((high << 4) | low));
            i += 2;
        }
        else if (c < 0x80) {
            bytes.push_back(static_cast<u8>(c));
        }
        else {
            // A character outside ASCII stands for its own UTF-8 bytes, so that the whole input can be decoded
            // as one byte sequence below.
            u32 codepoint = c;

            if (c >= 0xD800 && c <= 0xDBFF && i + 1 < src.size()) {
                u16 low = src[i + 1];
                if (low >= 0xDC00 && low <= 0xDFFF) {
                    codepoint = 0x10000 + ((c - 0xD800) << 10) + (low - 0xDC00);
                    i++;
                }
            }

            if (codepoint < 0x80) {
                bytes.push_back(static_cast<u8>(codepoint));
            }
            else if (codepoint < 0x800) {
                bytes.push_back(static_cast<u8>(0xC0 | (codepoint >> 6)));
                bytes.push_back(static_cast<u8>(0x80 | (codepoint & 0x3F)));
            }
            else if (codepoint < 0x10000) {
                bytes.push_back(static_cast<u8>(0xE0 | (codepoint >> 12)));
                bytes.push_back(static_cast<u8>(0x80 | ((codepoint >> 6) & 0x3F)));
                bytes.push_back(static_cast<u8>(0x80 | (codepoint & 0x3F)));
            }
            else {
                bytes.push_back(static_cast<u8>(0xF0 | (codepoint >> 18)));
                bytes.push_back(static_cast<u8>(0x80 | ((codepoint >> 12) & 0x3F)));
                bytes.push_back(static_cast<u8>(0x80 | ((codepoint >> 6) & 0x3F)));
                bytes.push_back(static_cast<u8>(0x80 | (codepoint & 0x3F)));
            }
        }
    }

    std::vector<u16> result;
    if (!utf8ToUtf16(bytes, result)) {
        return alloc::nothing();
    }

    HPointer resultStr = alloc::allocString(result.data(), result.size());
    return alloc::just(alloc::boxed(resultStr), true);
}

} // namespace Elm::Kernel::Url
