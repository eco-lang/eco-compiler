#ifndef ECO_URL_HPP
#define ECO_URL_HPP

/**
 * Elm Kernel Url Module - Runtime Heap Integration
 *
 * Provides URL encoding/decoding using GC-managed heap values.
 */

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"

namespace Elm::Kernel::Url {

/**
 * Percent-encode a string for URLs (encodeURIComponent behavior).
 * Returns an ElmString.
 */
HPointer percentEncode(void* str);

/**
 * Percent-decode a URL string.
 * Returns Maybe String (Just string on success, Nothing on invalid encoding).
 */
HPointer percentDecode(void* str);

} // namespace Elm::Kernel::Url

#endif // ECO_URL_HPP
