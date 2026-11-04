//===- UrlExports.cpp - C-linkage exports for Url module -------------------===//
//
// The kernels elm/url's `Url.percentEncode` and `Url.percentDecode` call, declared in `KernelExports.h`.
//
// Percent-encoding writes a byte as `%` followed by two hexadecimal digits. Both kernels work on a UTF-8 copy of
// the argument, made by `StringOps::toStdString`, and behave as JavaScript's `encodeURIComponent` and
// `decodeURIComponent`, which elm/url calls:
//
// - The encoder leaves the unreserved bytes `A-Za-z0-9-_.!~*'()` as they are and escapes every other byte.
// - The decoder keeps a `+` (it is not a space here).
// - The decoder returns `Nothing` for a `%` followed by fewer than two characters or by a byte that is not a
//   hexadecimal digit, and for decoded bytes that are not valid UTF-8 (`decodeURIComponent` throws a URIError
//   there, which elm/url turns into `Nothing`).

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/StringOps.hpp"
#include <string>
#include <sstream>
#include <iomanip>
#include <vector>

using namespace Elm;
using namespace Elm::Kernel;

namespace {

/// Returns the text of the String at `ptr` as UTF-8, as `StringOps::toStdString` does.
std::string elmStringToStd(void* ptr) {
    return Elm::StringOps::toStdString(ptr);
}

/// Returns whether byte `c` is escaped by the encoder: whether it is outside `A-Za-z0-9-_.!~*'()`, the set
/// `encodeURIComponent` leaves as it is.
inline bool shouldEncode(char c) {
    if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) {
        return false;
    }
    switch (c) {
        case '-': case '_': case '.': case '!':
        case '~': case '*': case '\'': case '(':
        case ')':
            return false;
    }
    return true;
}

/// Returns the value of hexadecimal digit `c`, in either case, or -1 if `c` is not one.
inline int hexToInt(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'A' && c <= 'F') return 10 + (c - 'A');
    if (c >= 'a' && c <= 'f') return 10 + (c - 'a');
    return -1;
}

/// Decodes the UTF-8 `bytes` into UTF-16 units in `result`, and returns whether they were valid UTF-8.
///
/// Overlong forms, encoded surrogates, values above U+10FFFF, bad lead or continuation bytes and a sequence cut
/// off by the end are invalid, as they are for `decodeURIComponent`. `result` is cleared first; when the function
/// returns false it holds the units decoded before the invalid sequence.
bool utf8ToUtf16(const std::string& bytes, std::vector<u16>& result) {
    result.clear();
    size_t i = 0;

    while (i < bytes.size()) {
        u8 b0 = static_cast<u8>(bytes[i++]);
        u32 codepoint;

        if ((b0 & 0x80) == 0) {
            codepoint = b0;
        }
        else if ((b0 & 0xE0) == 0xC0) {
            if (i >= bytes.size()) return false;
            u8 b1 = static_cast<u8>(bytes[i++]);
            if ((b1 & 0xC0) != 0x80) return false;
            codepoint = ((b0 & 0x1F) << 6) | (b1 & 0x3F);
            if (codepoint < 0x80) return false;
        }
        else if ((b0 & 0xF0) == 0xE0) {
            if (i + 1 >= bytes.size()) return false;
            u8 b1 = static_cast<u8>(bytes[i++]);
            u8 b2 = static_cast<u8>(bytes[i++]);
            if ((b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80) return false;
            codepoint = ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F);
            if (codepoint < 0x800) return false;
            if (codepoint >= 0xD800 && codepoint <= 0xDFFF) return false;
        }
        else if ((b0 & 0xF8) == 0xF0) {
            if (i + 2 >= bytes.size()) return false;
            u8 b1 = static_cast<u8>(bytes[i++]);
            u8 b2 = static_cast<u8>(bytes[i++]);
            u8 b3 = static_cast<u8>(bytes[i++]);
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

} // anonymous namespace

extern "C" {

HPtr Elm_Kernel_Url_percentEncode(HPtr str) {
    void* ptr = Export::toPtr(str.toBits());
    std::string input = elmStringToStd(ptr);

    std::ostringstream encoded;
    encoded.fill('0');
    encoded << std::hex << std::uppercase;

    for (unsigned char c : input) {
        if (shouldEncode(c)) {
            encoded << '%' << std::setw(2) << static_cast<int>(c);
        } else {
            encoded << c;
        }
    }

    HPointer result = alloc::allocStringFromUTF8(encoded.str());
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_Url_percentDecode(HPtr str) {
    void* ptr = Export::toPtr(str.toBits());
    std::string input = elmStringToStd(ptr);

    std::string decoded;
    decoded.reserve(input.length());

    for (size_t i = 0; i < input.length(); i++) {
        if (input[i] == '%') {
            if (i + 2 >= input.length()) {
                return HPtr::fromBits(Export::encode(alloc::nothing()));
            }
            int high = hexToInt(input[i + 1]);
            int low = hexToInt(input[i + 2]);
            if (high < 0 || low < 0) {
                return HPtr::fromBits(Export::encode(alloc::nothing()));
            }
            decoded += static_cast<char>((high << 4) | low);
            i += 2;
        } else {
            decoded += input[i];
        }
    }

    std::vector<u16> units;
    if (!utf8ToUtf16(decoded, units)) {
        return HPtr::fromBits(Export::encode(alloc::nothing()));
    }

    HPointer decodedStr = alloc::allocString(units.data(), units.size());
    Unboxable val;
    val.p = decodedStr;
    HPointer result = alloc::just(val, true);  // true = boxed pointer
    return HPtr::fromBits(Export::encode(result));
}

} // extern "C"
