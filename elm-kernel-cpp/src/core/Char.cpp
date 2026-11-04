#include "Char.hpp"
#include "allocator/CaseMap.hpp"
#include <stdexcept>

namespace Elm::Kernel::Char {

char32_t fromCode(int32_t code) {
    if (code < 0 || code > 0x10FFFF) {
        return U'\uFFFD';
    }
    return static_cast<char32_t>(code);
}

int32_t toCode(char32_t c) {
    return static_cast<int32_t>(c);
}

char32_t toLower(char32_t c) {
    return static_cast<char32_t>(Elm::CaseMap::lower(static_cast<uint32_t>(c)));
}

char32_t toUpper(char32_t c) {
    return static_cast<char32_t>(Elm::CaseMap::upper(static_cast<uint32_t>(c)));
}

char32_t toLocaleLower(char32_t c) {
    return toLower(c);
}

char32_t toLocaleUpper(char32_t c) {
    return toUpper(c);
}

} // namespace Elm::Kernel::Char
