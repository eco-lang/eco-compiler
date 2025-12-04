#ifndef ELM_KERNEL_STRING_HPP
#define ELM_KERNEL_STRING_HPP

#include <string>
#include <functional>
#include <optional>

namespace Elm::Kernel::String {

// Forward declarations
struct Value;
struct List;
struct Maybe;

// Length of string
size_t length(const std::u16string& str);

// String concatenation
std::u16string append(const std::u16string& a, const std::u16string& b);

// Prepend a character to a string
std::u16string cons(char32_t c, const std::u16string& str);

// Remove first character and return (char, rest) or Nothing
Value* uncons(const std::u16string& str);

// Convert list of characters to string
std::u16string fromList(List* chars);

// Map over characters in string
std::u16string map(std::function<char32_t(char32_t)> func, const std::u16string& str);

// Filter characters in string
std::u16string filter(std::function<bool(char32_t)> pred, const std::u16string& str);

// Fold left over characters
Value* foldl(std::function<Value*(char32_t, Value*)> func, Value* acc, const std::u16string& str);

// Fold right over characters
Value* foldr(std::function<Value*(char32_t, Value*)> func, Value* acc, const std::u16string& str);

// Check if any character satisfies predicate
bool any(std::function<bool(char32_t)> pred, const std::u16string& str);

// Check if all characters satisfy predicate
bool all(std::function<bool(char32_t)> pred, const std::u16string& str);

// Reverse a string
std::u16string reverse(const std::u16string& str);

// Slice a string
std::u16string slice(int start, int end, const std::u16string& str);

// Split string by separator
List* split(const std::u16string& sep, const std::u16string& str);

// Join strings with separator
std::u16string join(const std::u16string& sep, List* strings);

// Split into lines
List* lines(const std::u16string& str);

// Split into words
List* words(const std::u16string& str);

// Trim whitespace from both ends
std::u16string trim(const std::u16string& str);

// Trim whitespace from left
std::u16string trimLeft(const std::u16string& str);

// Trim whitespace from right
std::u16string trimRight(const std::u16string& str);

// Check if string starts with prefix
bool startsWith(const std::u16string& prefix, const std::u16string& str);

// Check if string ends with suffix
bool endsWith(const std::u16string& suffix, const std::u16string& str);

// Check if string contains substring
bool contains(const std::u16string& sub, const std::u16string& str);

// Find all indexes of substring
List* indexes(const std::u16string& sub, const std::u16string& str);

// Convert to lowercase
std::u16string toLower(const std::u16string& str);

// Convert to uppercase
std::u16string toUpper(const std::u16string& str);

// Parse string as integer
Value* toInt(const std::u16string& str);

// Parse string as float
Value* toFloat(const std::u16string& str);

// Convert number to string
std::u16string fromNumber(double n);

} // namespace Elm::Kernel::String

#endif // ELM_KERNEL_STRING_HPP
