//===- UrlExports.cpp - C-linkage exports for Url module -------------------===//
//
// The kernels elm/url's `Url.percentEncode` and `Url.percentDecode` call, declared in `KernelExports.h`.
//
// Percent-encoding writes a byte as `%` followed by two hexadecimal digits. Both kernels work on a UTF-8 copy of
// the argument, made by `StringOps::toStdString`, and differ from JavaScript's `encodeURIComponent` and
// `decodeURIComponent` in three ways:
//
// - The encoder leaves only the unreserved bytes `A-Za-z0-9-_.~` as they are, so it also escapes
//   `!*'()`.
// - The decoder turns `+` into a space.
// - The decoder does not check that the decoded bytes are UTF-8. It returns `Nothing` only for a `%` followed by
//   fewer than two characters or by a byte that is not a hexadecimal digit. Otherwise it returns `Just` the
//   String that `alloc::allocStringFromUTF8` makes of the bytes, which decodes invalid UTF-8 leniently instead
//   of failing.
//
// The unused namespace functions in `Url.hpp` follow JavaScript instead.

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/StringOps.hpp"
#include <string>
#include <sstream>
#include <iomanip>

using namespace Elm;
using namespace Elm::Kernel;

namespace {

/// Returns the text of the String at `ptr` as UTF-8, as `StringOps::toStdString` does.
std::string elmStringToStd(void* ptr) {
    return Elm::StringOps::toStdString(ptr);
}

/// Returns whether byte `c` is escaped by the encoder: whether it is outside `A-Za-z0-9-_.~`.
inline bool shouldEncode(char c) {
    if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
        (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~') {
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
        } else if (input[i] == '+') {
            // `decodeURIComponent` keeps a `+`; this decodes it as a space.
            decoded += ' ';
        } else {
            decoded += input[i];
        }
    }

    HPointer decodedStr = alloc::allocStringFromUTF8(decoded);
    Unboxable val;
    val.p = decodedStr;
    HPointer result = alloc::just(val, true);  // true = boxed pointer
    return HPtr::fromBits(Export::encode(result));
}

} // extern "C"
