#ifndef ELM_KERNEL_REGEX_HPP
#define ELM_KERNEL_REGEX_HPP

#include <string>
#include <functional>
#include <limits>

namespace Elm::Kernel::Regex {

// Forward declarations
struct Value;
struct Regex;
struct List;

// A regex that never matches
Regex* never();

// Infinity constant for "find all" operations
constexpr int infinity = std::numeric_limits<int>::max();

// Create a regex from string with options
Value* fromStringWith(const std::u16string& pattern, bool caseInsensitive, bool multiline);

// Check if regex matches anywhere in string
bool contains(Regex* regex, const std::u16string& str);

// Find matches (up to n)
List* findAtMost(int n, Regex* regex, const std::u16string& str);

// Replace matches (up to n)
std::u16string replaceAtMost(int n, Regex* regex, std::function<std::u16string(Value*)> replacer, const std::u16string& str);

// Split string by regex (up to n parts)
List* splitAtMost(int n, Regex* regex, const std::u16string& str);

} // namespace Elm::Kernel::Regex

#endif // ELM_KERNEL_REGEX_HPP
