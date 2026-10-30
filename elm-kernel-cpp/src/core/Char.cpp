#include "Char.hpp"
#include "allocator/CaseMap.hpp"
#include <stdexcept>

namespace Elm::Kernel::Char {

char32_t fromCode(int32_t code) {
    /*
     * JS: function _Char_fromCode(code)
     *     {
     *         return __Utils_chr(
     *             (code < 0 || 0x10FFFF < code)
     *                 ? '\uFFFD'
     *                 :
     *             (code <= 0xFFFF)
     *                 ? String.fromCharCode(code)
     *                 :
     *             (code -= 0x10000,
     *                 String.fromCharCode(Math.floor(code / 0x400) + 0xD800, code % 0x400 + 0xDC00)
     *             )
     *         );
     *     }
     *
     * PSEUDOCODE:
     * - If code is out of valid Unicode range (< 0 or > 0x10FFFF), return replacement char U+FFFD
     * - If code <= 0xFFFF (BMP), return it directly as char32_t
     * - If code > 0xFFFF (supplementary plane), it's valid - return as char32_t
     *   (JS needs surrogate pairs for UTF-16, but C++ char32_t handles it natively)
     *
     * HELPERS: __Utils_chr (wraps string as Elm Char - not needed in C++ with char32_t)
     * LIBRARIES: None (char32_t is native)
     */
    if (code < 0 || code > 0x10FFFF) {
        return U'\uFFFD';  // Replacement character
    }
    return static_cast<char32_t>(code);
}

int32_t toCode(char32_t c) {
    /*
     * JS: function _Char_toCode(char)
     *     {
     *         var code = char.charCodeAt(0);
     *         if (0xD800 <= code && code <= 0xDBFF)
     *         {
     *             return (code - 0xD800) * 0x400 + char.charCodeAt(1) - 0xDC00 + 0x10000
     *         }
     *         return code;
     *     }
     *
     * PSEUDOCODE:
     * - In JS, need to handle UTF-16 surrogate pairs for chars > 0xFFFF
     * - In C++, a Char (KERN_008) is one code point, which is the answer
     *
     * HELPERS: None
     * LIBRARIES: None
     */
    return static_cast<int32_t>(c);
}

char32_t toLower(char32_t c) {
    /*
     * JS: function _Char_toLower(char) { return __Utils_chr(char.toLowerCase()); }
     *
     * PSEUDOCODE:
     * - Convert character to lowercase using Unicode rules
     * - For ASCII (0-127), simple: if 'A'-'Z', add 32
     * - For full Unicode, need ICU or similar library
     *
     * HELPERS: __Utils_chr (not needed in C++)
     * LIBRARIES: ICU (for full Unicode) or <cctype> tolower (ASCII only)
     *
     * NOTE: the Unicode simple lowercase mapping, one code point to one code
     * point (CaseMap.hpp, plans/char-simple-case-mapping.md). Where Elm's full
     * mapping gives several code points (toLower 'İ' == "i̇"), eco gives one
     * ('i'): design_docs/char-case-mapping.md.
     */
    return static_cast<char32_t>(Elm::CaseMap::lower(static_cast<uint32_t>(c)));
}

char32_t toUpper(char32_t c) {
    /*
     * JS: function _Char_toUpper(char) { return __Utils_chr(char.toUpperCase()); }
     *
     * PSEUDOCODE:
     * - Convert character to uppercase using Unicode rules
     * - For ASCII (0-127), simple: if 'a'-'z', subtract 32
     * - For full Unicode, need ICU or similar library
     *
     * HELPERS: __Utils_chr (not needed in C++)
     * LIBRARIES: ICU (for full Unicode) or <cctype> toupper (ASCII only)
     *
     * NOTE: the Unicode simple uppercase mapping, one code point to one code
     * point (CaseMap.hpp, plans/char-simple-case-mapping.md). Where Elm's full
     * mapping gives several code points (toUpper 'ß' == "SS"), eco keeps one
     * ('ß'): design_docs/char-case-mapping.md.
     */
    return static_cast<char32_t>(Elm::CaseMap::upper(static_cast<uint32_t>(c)));
}

char32_t toLocaleLower(char32_t c) {
    /*
     * JS: function _Char_toLocaleLower(char) { return __Utils_chr(char.toLocaleLowerCase()); }
     *
     * PSEUDOCODE:
     * - Convert character to lowercase using locale-specific rules
     * - Examples: Turkish 'I' -> 'ı' (dotless i), not 'i'
     * - Requires locale-aware Unicode library
     *
     * HELPERS: __Utils_chr (not needed in C++)
     * LIBRARIES: ICU with locale support
     *
     * NOTE: the same as toLower (plans/char-simple-case-mapping.md): case
     * mapping has no locale in eco. On node, toLocaleLowerCase() with no
     * argument also ignores the locale; in a browser with a Turkish, Azeri or
     * Lithuanian locale Elm would apply that locale's rules (a documented
     * divergence, design_docs/char-case-mapping.md).
     */
    return toLower(c);
}

char32_t toLocaleUpper(char32_t c) {
    /*
     * JS: function _Char_toLocaleUpper(char) { return __Utils_chr(char.toLocaleUpperCase()); }
     *
     * PSEUDOCODE:
     * - Convert character to uppercase using locale-specific rules
     * - Examples: Turkish 'i' -> 'İ' (dotted I), not 'I'
     * - Requires locale-aware Unicode library
     *
     * HELPERS: __Utils_chr (not needed in C++)
     * LIBRARIES: ICU with locale support
     *
     * NOTE: the same as toUpper (plans/char-simple-case-mapping.md): case
     * mapping has no locale in eco. On node, toLocaleUpperCase() with no
     * argument also ignores the locale; in a browser with a Turkish, Azeri or
     * Lithuanian locale Elm would apply that locale's rules (a documented
     * divergence, design_docs/char-case-mapping.md).
     */
    return toUpper(c);
}

} // namespace Elm::Kernel::Char
