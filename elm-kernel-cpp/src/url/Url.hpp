#ifndef ECO_URL_HPP
#define ECO_URL_HPP

// A C++ version of elm/url's two kernels, `Url.percentEncode` and `Url.percentDecode`, kept as a namespace API
// that nothing calls.
//
// Percent-encoding writes a byte as `%` followed by two hexadecimal digits, and is how text that may contain any
// character is carried in a URL. Both functions here work on the UTF-8 bytes of the text, and follow, apart from
// lone surrogates, JavaScript's `encodeURIComponent` and `decodeURIComponent`: a byte outside the unreserved set
// `A-Za-z0-9-_.!~*'()` is escaped, and a decoded byte sequence that is not valid UTF-8 is a failure.
//
// What Elm code gets is not this. The kernels it calls are the C-linkage exports in `UrlExports.cpp`, declared
// in `KernelExports.h`, which escape a smaller unreserved set, decode `+` as a space and do not validate UTF-8.

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"

namespace Elm::Kernel::Url {

/// Returns a String holding the UTF-8 bytes of the String at `str`, with every byte outside
/// `A-Za-z0-9-_.!~*'()` written as `%` and two uppercase hexadecimal digits.
///
/// `str` must point to a String. A lone surrogate in it is encoded as the three bytes of its unit value, where
/// `encodeURIComponent` would throw. A GC point; `str` is read before anything is allocated.
HPointer percentEncode(void* str);

/// Returns `Just` the String whose UTF-8 bytes are those of the String at `str` with each `%XX` escape replaced
/// by the byte it names, or `Nothing`.
///
/// It is `Nothing` when a `%` is followed by fewer than two characters or by a character that is not a
/// hexadecimal digit, and when the resulting bytes are not valid UTF-8: an overlong form, an encoded surrogate,
/// a value above U+10FFFF, or a truncated or malformed sequence. Characters other than escapes are kept as their
/// UTF-8 bytes, so a lone surrogate in the input also gives `Nothing`. A `+` is kept as it is. `str` must point
/// to a String. A GC point; `str` is read before anything is allocated.
HPointer percentDecode(void* str);

} // namespace Elm::Kernel::Url

#endif // ECO_URL_HPP
