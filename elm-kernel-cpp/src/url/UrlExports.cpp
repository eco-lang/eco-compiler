//===- UrlExports.cpp - C-linkage exports for Url module -------------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include <string>
#include <sstream>
#include <iomanip>

using namespace Elm;
using namespace Elm::Kernel;

namespace {

// Convert ElmString (UTF-16) to std::string (UTF-8).
std::string elmStringToStd(void* ptr) {
    if (!ptr) return "";
    ElmString* s = static_cast<ElmString*>(ptr);
    std::string result;
    result.reserve(s->header.size);
    for (u32 i = 0; i < s->header.size; i++) {
        u16 c = s->chars[i];
        if (c < 0x80) {
            result.push_back(static_cast<char>(c));
        } else if (c < 0x800) {
            result.push_back(static_cast<char>(0xC0 | (c >> 6)));
            result.push_back(static_cast<char>(0x80 | (c & 0x3F)));
        } else {
            result.push_back(static_cast<char>(0xE0 | (c >> 12)));
            result.push_back(static_cast<char>(0x80 | ((c >> 6) & 0x3F)));
            result.push_back(static_cast<char>(0x80 | (c & 0x3F)));
        }
    }
    return result;
}

// Check if a character should be encoded in a URL.
inline bool shouldEncode(char c) {
    // RFC 3986 unreserved characters.
    if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
        (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~') {
        return false;
    }
    return true;
}

// Convert hex character to int.
inline int hexToInt(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'A' && c <= 'F') return 10 + (c - 'A');
    if (c >= 'a' && c <= 'f') return 10 + (c - 'a');
    return -1;
}

} // anonymous namespace

extern "C" {

uint64_t Elm_Kernel_Url_percentEncode(uint64_t str) {
    // Percent-encode a string for use in URLs.
    void* ptr = Export::toPtr(str);
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
    return Export::encode(result);
}

uint64_t Elm_Kernel_Url_percentDecode(uint64_t str) {
    // Percent-decode a URL-encoded string.
    // Returns Maybe String (Just decoded or Nothing if invalid).
    void* ptr = Export::toPtr(str);
    std::string input = elmStringToStd(ptr);

    std::string decoded;
    decoded.reserve(input.length());

    for (size_t i = 0; i < input.length(); i++) {
        if (input[i] == '%') {
            if (i + 2 >= input.length()) {
                // Invalid: not enough characters after %.
                return Export::encode(alloc::nothing());
            }
            int high = hexToInt(input[i + 1]);
            int low = hexToInt(input[i + 2]);
            if (high < 0 || low < 0) {
                // Invalid hex characters.
                return Export::encode(alloc::nothing());
            }
            decoded += static_cast<char>((high << 4) | low);
            i += 2;
        } else if (input[i] == '+') {
            // Plus signs are sometimes used for spaces.
            decoded += ' ';
        } else {
            decoded += input[i];
        }
    }

    HPointer decodedStr = alloc::allocStringFromUTF8(decoded);
    Unboxable val;
    val.p = decodedStr;
    HPointer result = alloc::just(val, true);  // true = boxed pointer
    return Export::encode(result);
}

} // extern "C"
