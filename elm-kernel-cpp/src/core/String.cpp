#include "String.hpp"
#include <stdexcept>
#include <algorithm>
#include <sstream>
#include <cmath>
#include <regex>

namespace Elm::Kernel::String {

// ============================================================================
// UTF-16 Surrogate Pair Helpers
// ============================================================================

// Check if a code unit is a high surrogate (first part of surrogate pair)
static inline bool isHighSurrogate(char16_t c) {
    return c >= 0xD800 && c <= 0xDBFF;
}

// Check if a code unit is a low surrogate (second part of surrogate pair)
static inline bool isLowSurrogate(char16_t c) {
    return c >= 0xDC00 && c <= 0xDFFF;
}

// Decode a surrogate pair to a Unicode code point
static inline char32_t decodeSurrogatePair(char16_t high, char16_t low) {
    return ((static_cast<char32_t>(high) - 0xD800) << 10) +
           (static_cast<char32_t>(low) - 0xDC00) + 0x10000;
}

// Encode a Unicode code point to UTF-16 (may produce 1 or 2 code units)
static inline void encodeToUtf16(char32_t cp, std::u16string& out) {
    if (cp <= 0xFFFF) {
        out.push_back(static_cast<char16_t>(cp));
    } else {
        // Encode as surrogate pair
        cp -= 0x10000;
        out.push_back(static_cast<char16_t>((cp >> 10) + 0xD800));
        out.push_back(static_cast<char16_t>((cp & 0x3FF) + 0xDC00));
    }
}

// ============================================================================
// Core String Functions
// ============================================================================

size_t length(const std::u16string& str) {
    /*
     * JS: function _String_length(str) { return str.length; }
     *
     * PSEUDOCODE:
     * - Return the length of the string in UTF-16 code units
     * - Note: This counts code units, not Unicode code points
     *   (a character outside BMP takes 2 code units)
     *
     * HELPERS: None
     * LIBRARIES: None
     */
    return str.length();
}

std::u16string append(const std::u16string& a, const std::u16string& b) {
    /*
     * JS: var _String_append = F2(function(a, b) { return a + b; });
     *
     * PSEUDOCODE:
     * - Concatenate strings a and b
     * - Return the result
     *
     * HELPERS: None
     * LIBRARIES: None
     */
    return a + b;
}

std::u16string cons(char32_t c, const std::u16string& str) {
    /*
     * JS: var _String_cons = F2(function(chr, str) { return chr + str; });
     *
     * PSEUDOCODE:
     * - Prepend character c to string str
     * - If c > 0xFFFF, encode as surrogate pair
     * - Return the result
     *
     * HELPERS: __Utils_chr (wraps char - not needed in C++ with char32_t)
     * LIBRARIES: None
     */
    std::u16string result;
    encodeToUtf16(c, result);
    result += str;
    return result;
}

Value* uncons(const std::u16string& str) {
    /*
     * JS: function _String_uncons(string)
     *     {
     *         var word = string.charCodeAt(0);
     *         return !isNaN(word)
     *             ? __Maybe_Just(
     *                 0xD800 <= word && word <= 0xDBFF
     *                     ? __Utils_Tuple2(__Utils_chr(string[0] + string[1]), string.slice(2))
     *                     : __Utils_Tuple2(__Utils_chr(string[0]), string.slice(1))
     *             )
     *             : __Maybe_Nothing;
     *     }
     *
     * PSEUDOCODE:
     * - If string is empty, return Nothing
     * - Get first character (may be surrogate pair)
     * - If first code unit is high surrogate (0xD800-0xDBFF):
     *   - Combine with next code unit to form full character
     *   - Return Just (char, rest_of_string_from_index_2)
     * - Else:
     *   - Return Just (first_code_unit, rest_of_string_from_index_1)
     *
     * HELPERS:
     * - __Maybe_Just, __Maybe_Nothing (Maybe constructors)
     * - __Utils_Tuple2 (creates 2-tuple)
     * - __Utils_chr (wraps string as Elm Char)
     *
     * LIBRARIES: None
     */
    if (str.empty()) {
        // Return Nothing
        // TODO: Return proper Maybe::Nothing value
        return nullptr;
    }

    char16_t first = str[0];
    char32_t c;
    size_t restStart;

    if (isHighSurrogate(first) && str.length() > 1) {
        // Surrogate pair
        c = decodeSurrogatePair(first, str[1]);
        restStart = 2;
    } else {
        c = static_cast<char32_t>(first);
        restStart = 1;
    }

    std::u16string rest = str.substr(restStart);

    // TODO: Return proper Maybe::Just(Tuple2(char, rest)) value
    throw std::runtime_error("Elm.Kernel.String.uncons: needs Value type integration");
}

std::u16string fromList(List* chars) {
    /*
     * JS: function _String_fromList(chars) { return __List_toArray(chars).join(''); }
     *
     * PSEUDOCODE:
     * - Convert List of Chars to array
     * - Join all characters into a single string
     * - Return the result
     *
     * HELPERS:
     * - __List_toArray (converts Elm List to JS array)
     *
     * LIBRARIES: None
     */
    // TODO: Implement when List type is available
    throw std::runtime_error("Elm.Kernel.String.fromList: needs List type integration");
}

std::u16string map(std::function<char32_t(char32_t)> func, const std::u16string& str) {
    /*
     * JS: var _String_map = F2(function(func, string)
     *     {
     *         var len = string.length;
     *         var array = new Array(len);
     *         var i = 0;
     *         while (i < len)
     *         {
     *             var word = string.charCodeAt(i);
     *             if (0xD800 <= word && word <= 0xDBFF)
     *             {
     *                 array[i] = func(__Utils_chr(string[i] + string[i+1]));
     *                 i += 2;
     *                 continue;
     *             }
     *             array[i] = func(__Utils_chr(string[i]));
     *             i++;
     *         }
     *         return array.join('');
     *     });
     *
     * PSEUDOCODE:
     * - Iterate through string, handling surrogate pairs
     * - For each code point (character):
     *   - Apply func to get new character
     *   - Append result to output
     * - Return the result string
     *
     * HELPERS: __Utils_chr (wraps char)
     * LIBRARIES: None
     */
    std::u16string result;
    size_t i = 0;
    while (i < str.length()) {
        char16_t word = str[i];
        char32_t cp;

        if (isHighSurrogate(word) && i + 1 < str.length()) {
            cp = decodeSurrogatePair(word, str[i + 1]);
            i += 2;
        } else {
            cp = static_cast<char32_t>(word);
            i++;
        }

        char32_t newCp = func(cp);
        encodeToUtf16(newCp, result);
    }
    return result;
}

std::u16string filter(std::function<bool(char32_t)> pred, const std::u16string& str) {
    /*
     * JS: var _String_filter = F2(function(isGood, str)
     *     {
     *         var arr = [];
     *         var len = str.length;
     *         var i = 0;
     *         while (i < len)
     *         {
     *             var char = str[i];
     *             var word = str.charCodeAt(i);
     *             i++;
     *             if (0xD800 <= word && word <= 0xDBFF)
     *             {
     *                 char += str[i];
     *                 i++;
     *             }
     *             if (isGood(__Utils_chr(char)))
     *             {
     *                 arr.push(char);
     *             }
     *         }
     *         return arr.join('');
     *     });
     *
     * PSEUDOCODE:
     * - Iterate through string, handling surrogate pairs
     * - For each code point:
     *   - If predicate returns true, append to result
     * - Return filtered string
     *
     * HELPERS: __Utils_chr (wraps char)
     * LIBRARIES: None
     */
    std::u16string result;
    size_t i = 0;
    while (i < str.length()) {
        char16_t word = str[i];
        char32_t cp;
        size_t start = i;

        if (isHighSurrogate(word) && i + 1 < str.length()) {
            cp = decodeSurrogatePair(word, str[i + 1]);
            i += 2;
        } else {
            cp = static_cast<char32_t>(word);
            i++;
        }

        if (pred(cp)) {
            // Append original code units to preserve encoding
            result += str.substr(start, i - start);
        }
    }
    return result;
}

Value* foldl(std::function<Value*(char32_t, Value*)> func, Value* acc, const std::u16string& str) {
    /*
     * JS: var _String_foldl = F3(function(func, state, string)
     *     {
     *         var len = string.length;
     *         var i = 0;
     *         while (i < len)
     *         {
     *             var char = string[i];
     *             var word = string.charCodeAt(i);
     *             i++;
     *             if (0xD800 <= word && word <= 0xDBFF)
     *             {
     *                 char += string[i];
     *                 i++;
     *             }
     *             state = A2(func, __Utils_chr(char), state);
     *         }
     *         return state;
     *     });
     *
     * PSEUDOCODE:
     * - Initialize state with acc
     * - Iterate left-to-right through string, handling surrogate pairs
     * - For each character: state = func(char, state)
     * - Return final state
     *
     * HELPERS:
     * - __Utils_chr (wraps char)
     * - A2 (apply 2-argument function)
     *
     * LIBRARIES: None
     */
    // TODO: Implement when Value type is available
    throw std::runtime_error("Elm.Kernel.String.foldl: needs Value type integration");
}

Value* foldr(std::function<Value*(char32_t, Value*)> func, Value* acc, const std::u16string& str) {
    /*
     * JS: var _String_foldr = F3(function(func, state, string)
     *     {
     *         var i = string.length;
     *         while (i--)
     *         {
     *             var char = string[i];
     *             var word = string.charCodeAt(i);
     *             if (0xDC00 <= word && word <= 0xDFFF)
     *             {
     *                 i--;
     *                 char = string[i] + char;
     *             }
     *             state = A2(func, __Utils_chr(char), state);
     *         }
     *         return state;
     *     });
     *
     * PSEUDOCODE:
     * - Initialize state with acc
     * - Iterate right-to-left through string
     * - When encountering low surrogate (0xDC00-0xDFFF), combine with previous
     * - For each character: state = func(char, state)
     * - Return final state
     *
     * HELPERS:
     * - __Utils_chr (wraps char)
     * - A2 (apply 2-argument function)
     *
     * LIBRARIES: None
     */
    // TODO: Implement when Value type is available
    throw std::runtime_error("Elm.Kernel.String.foldr: needs Value type integration");
}

bool any(std::function<bool(char32_t)> pred, const std::u16string& str) {
    /*
     * JS: var _String_any = F2(function(isGood, string)
     *     {
     *         var i = string.length;
     *         while (i--)
     *         {
     *             var char = string[i];
     *             var word = string.charCodeAt(i);
     *             if (0xDC00 <= word && word <= 0xDFFF)
     *             {
     *                 i--;
     *                 char = string[i] + char;
     *             }
     *             if (isGood(__Utils_chr(char)))
     *             {
     *                 return true;
     *             }
     *         }
     *         return false;
     *     });
     *
     * PSEUDOCODE:
     * - Iterate right-to-left through string (handles surrogates)
     * - For each character, if pred(char) is true, return true
     * - If no character satisfies predicate, return false
     *
     * HELPERS: __Utils_chr (wraps char)
     * LIBRARIES: None
     */
    if (str.empty()) return false;

    size_t i = str.length();
    while (i > 0) {
        i--;
        char16_t word = str[i];
        char32_t cp;

        if (isLowSurrogate(word) && i > 0) {
            i--;
            cp = decodeSurrogatePair(str[i], word);
        } else {
            cp = static_cast<char32_t>(word);
        }

        if (pred(cp)) {
            return true;
        }
    }
    return false;
}

bool all(std::function<bool(char32_t)> pred, const std::u16string& str) {
    /*
     * JS: var _String_all = F2(function(isGood, string)
     *     {
     *         var i = string.length;
     *         while (i--)
     *         {
     *             var char = string[i];
     *             var word = string.charCodeAt(i);
     *             if (0xDC00 <= word && word <= 0xDFFF)
     *             {
     *                 i--;
     *                 char = string[i] + char;
     *             }
     *             if (!isGood(__Utils_chr(char)))
     *             {
     *                 return false;
     *             }
     *         }
     *         return true;
     *     });
     *
     * PSEUDOCODE:
     * - Iterate right-to-left through string (handles surrogates)
     * - For each character, if pred(char) is false, return false
     * - If all characters satisfy predicate, return true
     *
     * HELPERS: __Utils_chr (wraps char)
     * LIBRARIES: None
     */
    if (str.empty()) return true;

    size_t i = str.length();
    while (i > 0) {
        i--;
        char16_t word = str[i];
        char32_t cp;

        if (isLowSurrogate(word) && i > 0) {
            i--;
            cp = decodeSurrogatePair(str[i], word);
        } else {
            cp = static_cast<char32_t>(word);
        }

        if (!pred(cp)) {
            return false;
        }
    }
    return true;
}

std::u16string reverse(const std::u16string& str) {
    /*
     * JS: function _String_reverse(str)
     *     {
     *         var len = str.length;
     *         var arr = new Array(len);
     *         var i = 0;
     *         while (i < len)
     *         {
     *             var word = str.charCodeAt(i);
     *             if (0xD800 <= word && word <= 0xDBFF)
     *             {
     *                 arr[len - i] = str[i + 1];
     *                 i++;
     *                 arr[len - i] = str[i - 1];
     *                 i++;
     *             }
     *             else
     *             {
     *                 arr[len - i] = str[i];
     *                 i++;
     *             }
     *         }
     *         return arr.join('');
     *     }
     *
     * PSEUDOCODE:
     * - Create result array of same length
     * - Iterate through string
     * - For surrogate pairs: swap the two code units to keep them together
     * - For regular chars: just reverse position
     * - Return reversed string
     *
     * HELPERS: None
     * LIBRARIES: None
     */
    size_t len = str.length();
    std::u16string result(len, u'\0');
    size_t i = 0;

    while (i < len) {
        char16_t word = str[i];
        if (isHighSurrogate(word) && i + 1 < len) {
            // Surrogate pair: place low surrogate first, then high
            result[len - i - 2] = str[i];      // high surrogate
            result[len - i - 1] = str[i + 1];  // low surrogate
            i += 2;
        } else {
            result[len - i - 1] = str[i];
            i++;
        }
    }
    return result;
}

std::u16string slice(int start, int end, const std::u16string& str) {
    /*
     * JS: var _String_slice = F3(function(start, end, str) { return str.slice(start, end); });
     *
     * PSEUDOCODE:
     * - Handle negative indices (from end of string)
     * - Extract substring from start to end (exclusive)
     * - Return the slice
     *
     * HELPERS: None
     * LIBRARIES: None
     *
     * NOTE: This operates on code units, not code points, matching JS behavior
     */
    int len = static_cast<int>(str.length());

    // Handle negative indices
    if (start < 0) start = std::max(0, len + start);
    if (end < 0) end = std::max(0, len + end);

    // Clamp to valid range
    start = std::min(start, len);
    end = std::min(end, len);

    if (start >= end) return u"";

    return str.substr(static_cast<size_t>(start), static_cast<size_t>(end - start));
}

List* split(const std::u16string& sep, const std::u16string& str) {
    /*
     * JS: var _String_split = F2(function(sep, str) { return str.split(sep); });
     *
     * PSEUDOCODE:
     * - Split string by separator
     * - Return List of resulting strings
     *
     * HELPERS: __List_fromArray (converts JS array to Elm List)
     * LIBRARIES: None
     */
    // TODO: Implement when List type is available
    throw std::runtime_error("Elm.Kernel.String.split: needs List type integration");
}

std::u16string join(const std::u16string& sep, List* strings) {
    /*
     * JS: var _String_join = F2(function(sep, strs) { return strs.join(sep); });
     *
     * PSEUDOCODE:
     * - Join List of strings with separator
     * - Return concatenated result
     *
     * HELPERS: __List_toArray (converts Elm List to JS array)
     * LIBRARIES: None
     */
    // TODO: Implement when List type is available
    throw std::runtime_error("Elm.Kernel.String.join: needs List type integration");
}

List* lines(const std::u16string& str) {
    /*
     * JS: function _String_lines(str) { return __List_fromArray(str.split(/\r\n|\r|\n/g)); }
     *
     * PSEUDOCODE:
     * - Split string by line endings (\r\n, \r, or \n)
     * - Return List of lines
     *
     * HELPERS: __List_fromArray (converts JS array to Elm List)
     * LIBRARIES: std::regex or manual parsing
     */
    // TODO: Implement when List type is available
    throw std::runtime_error("Elm.Kernel.String.lines: needs List type integration");
}

List* words(const std::u16string& str) {
    /*
     * JS: function _String_words(str) { return __List_fromArray(str.trim().split(/\s+/g)); }
     *
     * PSEUDOCODE:
     * - Trim whitespace from string
     * - Split by one or more whitespace characters
     * - Return List of words
     *
     * HELPERS: __List_fromArray (converts JS array to Elm List)
     * LIBRARIES: std::regex or manual parsing
     */
    // TODO: Implement when List type is available
    throw std::runtime_error("Elm.Kernel.String.words: needs List type integration");
}

std::u16string trim(const std::u16string& str) {
    /*
     * JS: function _String_trim(str) { return str.trim(); }
     *
     * PSEUDOCODE:
     * - Remove leading and trailing whitespace
     * - Whitespace includes: space, tab, newline, carriage return, etc.
     * - Return trimmed string
     *
     * HELPERS: None
     * LIBRARIES: None (manual implementation or ICU for full Unicode)
     */
    if (str.empty()) return str;

    // Find first non-whitespace
    size_t start = 0;
    while (start < str.length() && (str[start] == u' ' || str[start] == u'\t' ||
           str[start] == u'\n' || str[start] == u'\r' || str[start] == u'\f' ||
           str[start] == u'\v')) {
        start++;
    }

    if (start == str.length()) return u"";

    // Find last non-whitespace
    size_t end = str.length();
    while (end > start && (str[end - 1] == u' ' || str[end - 1] == u'\t' ||
           str[end - 1] == u'\n' || str[end - 1] == u'\r' || str[end - 1] == u'\f' ||
           str[end - 1] == u'\v')) {
        end--;
    }

    return str.substr(start, end - start);
}

std::u16string trimLeft(const std::u16string& str) {
    /*
     * JS: function _String_trimLeft(str) { return str.replace(/^\s+/, ''); }
     *
     * PSEUDOCODE:
     * - Remove leading whitespace (regex: ^\s+)
     * - Return result
     *
     * HELPERS: None
     * LIBRARIES: std::regex or manual implementation
     */
    if (str.empty()) return str;

    size_t start = 0;
    while (start < str.length() && (str[start] == u' ' || str[start] == u'\t' ||
           str[start] == u'\n' || str[start] == u'\r' || str[start] == u'\f' ||
           str[start] == u'\v')) {
        start++;
    }

    return str.substr(start);
}

std::u16string trimRight(const std::u16string& str) {
    /*
     * JS: function _String_trimRight(str) { return str.replace(/\s+$/, ''); }
     *
     * PSEUDOCODE:
     * - Remove trailing whitespace (regex: \s+$)
     * - Return result
     *
     * HELPERS: None
     * LIBRARIES: std::regex or manual implementation
     */
    if (str.empty()) return str;

    size_t end = str.length();
    while (end > 0 && (str[end - 1] == u' ' || str[end - 1] == u'\t' ||
           str[end - 1] == u'\n' || str[end - 1] == u'\r' || str[end - 1] == u'\f' ||
           str[end - 1] == u'\v')) {
        end--;
    }

    return str.substr(0, end);
}

bool startsWith(const std::u16string& prefix, const std::u16string& str) {
    /*
     * JS: var _String_startsWith = F2(function(sub, str) { return str.indexOf(sub) === 0; });
     *
     * PSEUDOCODE:
     * - Check if string starts with prefix
     * - Return true if prefix is found at index 0
     *
     * HELPERS: None
     * LIBRARIES: None
     */
    if (prefix.length() > str.length()) return false;
    return str.compare(0, prefix.length(), prefix) == 0;
}

bool endsWith(const std::u16string& suffix, const std::u16string& str) {
    /*
     * JS: var _String_endsWith = F2(function(sub, str)
     *     {
     *         return str.length >= sub.length &&
     *             str.lastIndexOf(sub) === str.length - sub.length;
     *     });
     *
     * PSEUDOCODE:
     * - Check if string ends with suffix
     * - Return true if suffix is at end of string
     *
     * HELPERS: None
     * LIBRARIES: None
     */
    if (suffix.length() > str.length()) return false;
    return str.compare(str.length() - suffix.length(), suffix.length(), suffix) == 0;
}

bool contains(const std::u16string& sub, const std::u16string& str) {
    /*
     * JS: var _String_contains = F2(function(sub, str) { return str.indexOf(sub) > -1; });
     *
     * PSEUDOCODE:
     * - Search for substring in string
     * - Return true if found, false otherwise
     *
     * HELPERS: None
     * LIBRARIES: None
     */
    return str.find(sub) != std::u16string::npos;
}

List* indexes(const std::u16string& sub, const std::u16string& str) {
    /*
     * JS: var _String_indexes = F2(function(sub, str)
     *     {
     *         var subLen = sub.length;
     *         if (subLen < 1) { return __List_Nil; }
     *         var i = 0;
     *         var is = [];
     *         while ((i = str.indexOf(sub, i)) > -1)
     *         {
     *             is.push(i);
     *             i = i + subLen;
     *         }
     *         return __List_fromArray(is);
     *     });
     *
     * PSEUDOCODE:
     * - If substring is empty, return empty List
     * - Find all occurrences of substring in string
     * - Collect indices in array
     * - Convert to List and return
     *
     * HELPERS:
     * - __List_Nil (empty list)
     * - __List_fromArray (converts array to List)
     *
     * LIBRARIES: None
     */
    // TODO: Implement when List type is available
    throw std::runtime_error("Elm.Kernel.String.indexes: needs List type integration");
}

std::u16string toLower(const std::u16string& str) {
    /*
     * JS: function _String_toLower(str) { return str.toLowerCase(); }
     *
     * PSEUDOCODE:
     * - Convert all characters to lowercase
     * - Use Unicode-aware case conversion
     * - Return result
     *
     * HELPERS: None
     * LIBRARIES: ICU for full Unicode, or ASCII-only fallback
     *
     * NOTE: This implementation only handles ASCII. Full Unicode case
     * conversion requires ICU or a Unicode-aware library.
     */
    std::u16string result;
    result.reserve(str.length());

    for (char16_t c : str) {
        if (c >= u'A' && c <= u'Z') {
            result.push_back(c + 32);
        } else {
            result.push_back(c);
        }
    }
    // TODO: Full Unicode case conversion requires ICU
    return result;
}

std::u16string toUpper(const std::u16string& str) {
    /*
     * JS: function _String_toUpper(str) { return str.toUpperCase(); }
     *
     * PSEUDOCODE:
     * - Convert all characters to uppercase
     * - Use Unicode-aware case conversion
     * - Return result
     *
     * HELPERS: None
     * LIBRARIES: ICU for full Unicode, or ASCII-only fallback
     *
     * NOTE: This implementation only handles ASCII. Full Unicode case
     * conversion requires ICU or a Unicode-aware library.
     */
    std::u16string result;
    result.reserve(str.length());

    for (char16_t c : str) {
        if (c >= u'a' && c <= u'z') {
            result.push_back(c - 32);
        } else {
            result.push_back(c);
        }
    }
    // TODO: Full Unicode case conversion requires ICU
    return result;
}

Value* toInt(const std::u16string& str) {
    /*
     * JS: function _String_toInt(str)
     *     {
     *         var total = 0;
     *         var code0 = str.charCodeAt(0);
     *         var start = code0 == 0x2B || code0 == 0x2D ? 1 : 0; // + or -
     *         for (var i = start; i < str.length; ++i)
     *         {
     *             var code = str.charCodeAt(i);
     *             if (code < 0x30 || 0x39 < code) { return __Maybe_Nothing; }
     *             total = 10 * total + code - 0x30;
     *         }
     *         return i == start
     *             ? __Maybe_Nothing
     *             : __Maybe_Just(code0 == 0x2D ? -total : total);
     *     }
     *
     * PSEUDOCODE:
     * - Check for leading + or - sign
     * - Parse digits (0x30-0x39 = '0'-'9')
     * - If any non-digit found, return Nothing
     * - If empty (only sign), return Nothing
     * - Return Just(value) with appropriate sign
     *
     * HELPERS:
     * - __Maybe_Just, __Maybe_Nothing (Maybe constructors)
     *
     * LIBRARIES: None
     */
    if (str.empty()) {
        // Return Nothing
        return nullptr;
    }

    long long total = 0;
    char16_t code0 = str[0];
    size_t start = (code0 == 0x2B || code0 == 0x2D) ? 1 : 0;  // + or -

    for (size_t i = start; i < str.length(); ++i) {
        char16_t code = str[i];
        if (code < 0x30 || code > 0x39) {
            // Non-digit found, return Nothing
            return nullptr;
        }
        total = 10 * total + (code - 0x30);
    }

    if (start == str.length()) {
        // Only sign, no digits
        return nullptr;
    }

    if (code0 == 0x2D) {
        total = -total;
    }

    // TODO: Return proper Maybe::Just(total) value
    throw std::runtime_error("Elm.Kernel.String.toInt: needs Value type integration");
}

Value* toFloat(const std::u16string& str) {
    /*
     * JS: function _String_toFloat(s)
     *     {
     *         // check if it is a hex, octal, or binary number
     *         if (s.length === 0 || /[\sxbo]/.test(s)) { return __Maybe_Nothing; }
     *         var n = +s;
     *         // faster isNaN check
     *         return n === n ? __Maybe_Just(n) : __Maybe_Nothing;
     *     }
     *
     * PSEUDOCODE:
     * - If empty, return Nothing
     * - If contains whitespace, 'x', 'b', or 'o', return Nothing
     *   (rejects hex 0x, binary 0b, octal 0o literals)
     * - Convert to number using unary +
     * - If result is NaN, return Nothing
     * - Otherwise return Just(n)
     *
     * HELPERS:
     * - __Maybe_Just, __Maybe_Nothing (Maybe constructors)
     *
     * LIBRARIES: None (or std::stod for parsing)
     */
    if (str.empty()) {
        return nullptr;
    }

    // Check for forbidden characters (whitespace, x, b, o)
    for (char16_t c : str) {
        if (c == u' ' || c == u'\t' || c == u'\n' || c == u'\r' ||
            c == u'x' || c == u'X' || c == u'b' || c == u'B' || c == u'o' || c == u'O') {
            return nullptr;
        }
    }

    // Convert u16string to std::string for parsing
    std::string narrowStr;
    for (char16_t c : str) {
        if (c > 127) {
            // Non-ASCII, can't be a valid number
            return nullptr;
        }
        narrowStr.push_back(static_cast<char>(c));
    }

    try {
        size_t pos;
        double n = std::stod(narrowStr, &pos);
        if (pos != narrowStr.length()) {
            // Not all characters consumed
            return nullptr;
        }
        if (std::isnan(n)) {
            return nullptr;
        }
        // TODO: Return proper Maybe::Just(n) value
        throw std::runtime_error("Elm.Kernel.String.toFloat: needs Value type integration");
    } catch (...) {
        return nullptr;
    }
}

std::u16string fromNumber(double n) {
    /*
     * JS: function _String_fromNumber(number) { return number + ''; }
     *
     * PSEUDOCODE:
     * - Convert number to string representation
     * - In JS, concatenating with '' converts to string
     * - Return the string
     *
     * HELPERS: None
     * LIBRARIES: std::to_string or std::ostringstream
     */
    std::ostringstream oss;
    oss << n;
    std::string narrowStr = oss.str();

    // Convert to u16string
    std::u16string result;
    for (char c : narrowStr) {
        result.push_back(static_cast<char16_t>(c));
    }
    return result;
}

} // namespace Elm::Kernel::String
