#include "Url.hpp"
#include <stdexcept>

namespace Elm::Kernel::Url {

/*
 * Url module provides URL percent-encoding/decoding for Elm.
 *
 * Percent-encoding (URL encoding) converts characters to %XX format
 * where XX is the hex value of the UTF-8 byte.
 *
 * encodeURIComponent behavior (per ECMAScript spec):
 * - Leaves unreserved characters unchanged:
 *   - A-Z, a-z, 0-9
 *   - - _ . ! ~ * ' ( )
 * - Encodes all other characters as UTF-8 bytes in %XX format
 *
 * decodeURIComponent behavior:
 * - Decodes %XX sequences to bytes
 * - Interprets resulting bytes as UTF-8
 * - Throws on invalid sequences (malformed UTF-8 or invalid %XX)
 *
 * LIBRARIES: None needed (implement with standard library)
 */

std::u16string percentEncode(const std::u16string& str) {
    /*
     * JS: function _Url_percentEncode(string)
     *     {
     *         return encodeURIComponent(string);
     *     }
     *
     * PSEUDOCODE:
     * - Convert UTF-16 string to UTF-8 bytes
     * - For each byte:
     *   - If unreserved char (A-Z, a-z, 0-9, -_.!~*'()): output as-is
     *   - Otherwise: output %XX where XX is uppercase hex
     * - Return encoded string
     *
     * Unreserved character set (RFC 3986):
     *   ALPHA / DIGIT / "-" / "." / "_" / "~"
     * Plus encodeURIComponent also preserves:
     *   "!" / "'" / "(" / ")" / "*"
     *
     * Example:
     *   "Hello World" -> "Hello%20World"
     *   "café" -> "caf%C3%A9" (é is 0xC3 0xA9 in UTF-8)
     *
     * HELPERS: None
     * LIBRARIES: None (implement UTF-16 to UTF-8 conversion manually)
     */
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Url.percentEncode not implemented");
}

Value* percentDecode(const std::u16string& str) {
    /*
     * JS: function _Url_percentDecode(string)
     *     {
     *         try
     *         {
     *             return __Maybe_Just(decodeURIComponent(string));
     *         }
     *         catch (e)
     *         {
     *             return __Maybe_Nothing;
     *         }
     *     }
     *
     * PSEUDOCODE:
     * - Scan string for %XX sequences
     * - For each %XX: convert hex XX to byte value
     * - Collect decoded bytes
     * - Convert UTF-8 bytes to UTF-16 string
     * - If any error (invalid hex, invalid UTF-8): return Nothing
     * - Otherwise: return Just(decodedString)
     *
     * Error cases:
     * - %X (only one hex digit)
     * - %XY where X or Y is not hex
     * - Decoded bytes form invalid UTF-8 sequence
     * - Lone surrogate (shouldn't happen in valid URLs)
     *
     * Example:
     *   "Hello%20World" -> Just "Hello World"
     *   "caf%C3%A9" -> Just "café"
     *   "%ZZ" -> Nothing (invalid hex)
     *   "%C3" -> Nothing (incomplete UTF-8)
     *
     * HELPERS:
     * - __Maybe_Just, __Maybe_Nothing
     *
     * LIBRARIES: None (implement manually)
     */
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Url.percentDecode not implemented");
}

} // namespace Elm::Kernel::Url
