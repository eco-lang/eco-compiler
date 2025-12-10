#ifndef ECO_CHAR_HPP
#define ECO_CHAR_HPP

#include <cstdint>

namespace Elm::Kernel::Char {

// Converts Unicode code point to character.
char32_t fromCode(int32_t code);

// Returns Unicode code point from character.
int32_t toCode(char32_t c);

// Converts character to lowercase (locale-independent).
char32_t toLower(char32_t c);

// Converts character to uppercase (locale-independent).
char32_t toUpper(char32_t c);

// Converts character to lowercase (locale-dependent).
char32_t toLocaleLower(char32_t c);

// Converts character to uppercase (locale-dependent).
char32_t toLocaleUpper(char32_t c);

} // namespace Elm::Kernel::Char

#endif // ECO_CHAR_HPP
