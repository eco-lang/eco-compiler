#ifndef ECO_REGEX_HPP
#define ECO_REGEX_HPP

/**
 * Elm Kernel Regex Module - Runtime Heap Integration
 *
 * Provides regular expression operations using GC-managed heap values.
 * Note: For full JS compatibility, PCRE2 should be used instead of std::regex.
 */

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include <functional>
#include <limits>
#include <memory>
#include <regex>

namespace Elm::Kernel::Regex {

// Regex representation (wraps std::basic_regex)
struct Regex {
    std::basic_regex<char16_t> pattern;
    std::vector<u16> patternStr;
    bool caseInsensitive = false;
    bool multiline = false;

    Regex() = default;
};

using RegexPtr = std::shared_ptr<Regex>;

// Infinity constant for "find all" operations
constexpr i64 infinity = std::numeric_limits<i64>::max();

/**
 * A regex that never matches.
 */
RegexPtr never();

/**
 * Create a regex from string with options.
 * Returns Maybe Regex (Just regex on success, Nothing on invalid pattern).
 */
HPointer fromStringWith(void* pattern, bool caseInsensitive, bool multiline);

/**
 * Check if regex matches anywhere in string.
 */
bool contains(RegexPtr regex, void* str);

/**
 * Find matches (up to n) - returns List of Match records.
 */
HPointer findAtMost(i64 n, RegexPtr regex, void* str);

// Replacer function type - receives Match record, returns replacement string pointer
using ReplacerFn = std::function<HPointer(HPointer)>;

/**
 * Replace matches (up to n).
 * Returns new string.
 */
HPointer replaceAtMost(i64 n, RegexPtr regex, ReplacerFn replacer, void* str);

/**
 * Split string by regex (up to n parts) - returns List of strings.
 */
HPointer splitAtMost(i64 n, RegexPtr regex, void* str);

} // namespace Elm::Kernel::Regex

#endif // ECO_REGEX_HPP
