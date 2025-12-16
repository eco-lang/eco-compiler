//===- CharExports.cpp - C-linkage exports for Char module -----------------===//

#include "../KernelExports.h"
#include "Char.hpp"

using namespace Elm::Kernel;

extern "C" {

int32_t Elm_Kernel_Char_fromCode(int32_t code) {
    return static_cast<int32_t>(Char::fromCode(code));
}

int32_t Elm_Kernel_Char_toCode(int32_t c) {
    return Char::toCode(static_cast<char32_t>(c));
}

int32_t Elm_Kernel_Char_toLower(int32_t c) {
    return static_cast<int32_t>(Char::toLower(static_cast<char32_t>(c)));
}

int32_t Elm_Kernel_Char_toUpper(int32_t c) {
    return static_cast<int32_t>(Char::toUpper(static_cast<char32_t>(c)));
}

int32_t Elm_Kernel_Char_toLocaleLower(int32_t c) {
    return static_cast<int32_t>(Char::toLocaleLower(static_cast<char32_t>(c)));
}

int32_t Elm_Kernel_Char_toLocaleUpper(int32_t c) {
    return static_cast<int32_t>(Char::toLocaleUpper(static_cast<char32_t>(c)));
}

} // extern "C"
