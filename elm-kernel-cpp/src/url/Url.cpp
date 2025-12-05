/**
 * Elm Kernel Url Module - Runtime Heap Integration
 *
 * Provides URL encoding/decoding using GC-managed heap values.
 */

#include "Url.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/StringOps.hpp"
#include <vector>

namespace Elm::Kernel::Url {

// Helper: Check if character is unreserved (not percent-encoded)
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

// Helper: Convert hex character to value, returns -1 on invalid
static i64 hexValue(u16 c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

// Helper: Convert value to uppercase hex character
static u16 toHex(i64 value) {
    if (value < 10) return static_cast<u16>('0' + value);
    return static_cast<u16>('A' + value - 10);
}

// Helper: Encode UTF-16 to UTF-8 bytes
static std::vector<u8> utf16ToUtf8(ElmString* s) {
    std::vector<u8> result;

    for (u32 i = 0; i < s->header.size; i++) {
        u32 codepoint = s->chars[i];

        // Handle surrogate pairs
        if (codepoint >= 0xD800 && codepoint <= 0xDBFF && i + 1 < s->header.size) {
            u16 low = s->chars[i + 1];
            if (low >= 0xDC00 && low <= 0xDFFF) {
                codepoint = 0x10000 + ((codepoint - 0xD800) << 10) + (low - 0xDC00);
                i++;
            }
        }

        // Encode codepoint as UTF-8
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

// Helper: Decode UTF-8 bytes to UTF-16 chars, returns false on invalid
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

        // Convert codepoint to UTF-16
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
    ElmString* s = static_cast<ElmString*>(str);
    std::vector<u8> utf8 = utf16ToUtf8(s);

    // Build result string
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
    ElmString* s = static_cast<ElmString*>(str);
    std::vector<u8> bytes;

    for (u32 i = 0; i < s->header.size; i++) {
        u16 c = s->chars[i];

        if (c == '%') {
            if (i + 2 >= s->header.size) {
                return alloc::nothing();
            }

            i64 high = hexValue(s->chars[i + 1]);
            i64 low = hexValue(s->chars[i + 2]);

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
            // Non-ASCII character - encode to UTF-8
            u32 codepoint = c;

            // Handle surrogate pair
            if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s->header.size) {
                u16 low = s->chars[i + 1];
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

    // Convert UTF-8 bytes to UTF-16
    std::vector<u16> result;
    if (!utf8ToUtf16(bytes, result)) {
        return alloc::nothing();
    }

    HPointer resultStr = alloc::allocString(result.data(), result.size());
    return alloc::just(alloc::boxed(resultStr), true);
}

} // namespace Elm::Kernel::Url
