//===- CharExports.cpp - C-linkage exports for Char module -----------------===//

#include "../KernelExports.h"
#include "Char.hpp"

using namespace Elm::Kernel;

extern "C" {

// Checks the range on the full 64-bit Int rather than calling `Char::fromCode`, which takes a
// 32-bit code. Codes below 0 or above 0x10FFFF become U+FFFD, as in elm/core's JS kernel and in
// the `eco.char.fromInt` lowering; surrogate codes pass through unchanged.
uint32_t Elm_Kernel_Char_fromCode(int64_t code) {
    if (code < 0 || code > 0x10FFFF) return 0xFFFDu;
    return static_cast<uint32_t>(code);
}

// Char ABI masking. Each Char parameter in this file is declared `uint64_t` and masked to
// its low 32 bits, because the caller does not guarantee the upper bits are zero. Compiled code
// calls kernels through LLVM `gc.statepoint`, which does not carry the `zeroext` attribute on
// arguments, so the caller need not zero-extend the 32-bit Char into the 64-bit register.
// Declared `uint64_t`, the full register is read and the mask is a real operation the compiler
// must keep.
int64_t Elm_Kernel_Char_toCode(uint64_t c_raw) {
    return static_cast<int64_t>(static_cast<uint32_t>(c_raw & 0xFFFFFFFFu));
}

uint32_t Elm_Kernel_Char_toLower(uint64_t c_raw) {
    char32_t result = Char::toLower(static_cast<char32_t>(c_raw & 0xFFFFFFFFu));
    return static_cast<uint32_t>(result);
}

uint32_t Elm_Kernel_Char_toUpper(uint64_t c_raw) {
    char32_t result = Char::toUpper(static_cast<char32_t>(c_raw & 0xFFFFFFFFu));
    return static_cast<uint32_t>(result);
}

uint32_t Elm_Kernel_Char_toLocaleLower(uint64_t c_raw) {
    char32_t result = Char::toLocaleLower(static_cast<char32_t>(c_raw & 0xFFFFFFFFu));
    return static_cast<uint32_t>(result);
}

uint32_t Elm_Kernel_Char_toLocaleUpper(uint64_t c_raw) {
    char32_t result = Char::toLocaleUpper(static_cast<char32_t>(c_raw & 0xFFFFFFFFu));
    return static_cast<uint32_t>(result);
}

} // extern "C"
