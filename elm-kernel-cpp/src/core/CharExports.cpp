//===- CharExports.cpp - C-linkage exports for Char module -----------------===//

#include "../KernelExports.h"
#include "Char.hpp"
#include <algorithm>

using namespace Elm::Kernel;

extern "C" {

uint16_t Elm_Kernel_Char_fromCode(int64_t code) {
    // Clamp to valid BMP range [0, 0xFFFF]
    int64_t clamped = std::max(int64_t(0), std::min(code, int64_t(0xFFFF)));
    return static_cast<uint16_t>(clamped);
}

int64_t Elm_Kernel_Char_toCode(uint16_t c) {
    // Zero-extend to int64_t
    return static_cast<int64_t>(c);
}

uint16_t Elm_Kernel_Char_toLower(uint16_t c) {
    char32_t result = Char::toLower(static_cast<char32_t>(c));
    // Result should stay in BMP; truncate just in case
    return static_cast<uint16_t>(result & 0xFFFF);
}

uint16_t Elm_Kernel_Char_toUpper(uint16_t c) {
    char32_t result = Char::toUpper(static_cast<char32_t>(c));
    return static_cast<uint16_t>(result & 0xFFFF);
}

uint16_t Elm_Kernel_Char_toLocaleLower(uint16_t c) {
    char32_t result = Char::toLocaleLower(static_cast<char32_t>(c));
    return static_cast<uint16_t>(result & 0xFFFF);
}

uint16_t Elm_Kernel_Char_toLocaleUpper(uint16_t c) {
    char32_t result = Char::toLocaleUpper(static_cast<char32_t>(c));
    return static_cast<uint16_t>(result & 0xFFFF);
}

} // extern "C"
