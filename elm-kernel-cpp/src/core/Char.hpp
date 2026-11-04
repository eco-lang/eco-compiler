// The C++ side of elm/core's `Char` module: case mapping.
//
// A Char is one Unicode code point, 0 to 0x10FFFF, held in 32 bits; a lone surrogate (0xD800 to
// 0xDFFF) is a Char too, with its own unit value. Elm's JS kernel stores a Char as a UTF-16
// string and has to join and split surrogate pairs; here the code point is the value, so the code
// conversions are range checks and casts, done inline in CharExports.cpp.
//
// Case mapping is the Unicode simple case mapping, which takes one code point to one code point,
// with no context and no locale, as `Elm::CaseMap` (runtime/src/allocator/CaseMap.hpp) defines it.
// Where Elm's full mapping gives several code points, the result here is one: `toLower` of U+0130
// (capital I with dot above) is 'i', and `toUpper` of 'ß' is 'ß', not "SS".
//
// The C-linkage entry points the compiled program calls are in CharExports.cpp, declared in
// KernelExports.h; they call the four case mappers below.
#ifndef ECO_CHAR_HPP
#define ECO_CHAR_HPP

#include <cstdint>

namespace Elm::Kernel::Char {

/// Returns the Unicode simple lowercase mapping of `c`, or `c` when it has none.
char32_t toLower(char32_t c);

/// Returns the Unicode simple uppercase mapping of `c`, or `c` when it has none.
char32_t toUpper(char32_t c);

/// Returns `toLower(c)`. No locale is consulted, so the Turkish, Azeri and Lithuanian rules that
/// JS `toLocaleLowerCase` can apply are not.
char32_t toLocaleLower(char32_t c);

/// Returns `toUpper(c)`. No locale is consulted, so the Turkish, Azeri and Lithuanian rules that
/// JS `toLocaleUpperCase` can apply are not.
char32_t toLocaleUpper(char32_t c);

} // namespace Elm::Kernel::Char

#endif // ECO_CHAR_HPP
