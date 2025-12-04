#ifndef ELM_KERNEL_CHAR_HPP
#define ELM_KERNEL_CHAR_HPP

#include <cstdint>

namespace Elm::Kernel::Char {

// Convert Unicode code point to character
char32_t fromCode(int32_t code);

// Get Unicode code point from character
int32_t toCode(char32_t c);

// Case conversion (locale-independent)
char32_t toLower(char32_t c);
char32_t toUpper(char32_t c);

// Case conversion (locale-dependent)
char32_t toLocaleLower(char32_t c);
char32_t toLocaleUpper(char32_t c);

} // namespace Elm::Kernel::Char

#endif // ELM_KERNEL_CHAR_HPP
