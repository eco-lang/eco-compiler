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

// ABI note (x86-64 SysV): MLIR-emitted callers wrap kernel calls in LLVM
// `gc.statepoint` intrinsics. The statepoint represents the call's element
// type *without* per-arg attributes (no `zeroext`), so LLVM CodeGen emits a
// narrow `mov %ax, %di` that leaves the upper bits of %rdi with leftover
// state. If the C++ callees declared the parameter as `uint16_t`, the
// compiler would trust the SysV zero-extension contract and read only %edi
// — surfacing the leaked bits as the high half of the int64_t return.
//
// Receiving the parameter as `uint64_t` forces a full-register read; we
// then mask down to the canonical 16-bit Char value. The wider type also
// keeps the C++ compiler from optimising the mask away.
int64_t Elm_Kernel_Char_toCode(uint64_t c_raw) {
    return static_cast<int64_t>(c_raw & 0xFFFFu);
}

uint16_t Elm_Kernel_Char_toLower(uint64_t c_raw) {
    char32_t result = Char::toLower(static_cast<char32_t>(c_raw & 0xFFFFu));
    return static_cast<uint16_t>(result & 0xFFFF);
}

uint16_t Elm_Kernel_Char_toUpper(uint64_t c_raw) {
    char32_t result = Char::toUpper(static_cast<char32_t>(c_raw & 0xFFFFu));
    return static_cast<uint16_t>(result & 0xFFFF);
}

uint16_t Elm_Kernel_Char_toLocaleLower(uint64_t c_raw) {
    char32_t result = Char::toLocaleLower(static_cast<char32_t>(c_raw & 0xFFFFu));
    return static_cast<uint16_t>(result & 0xFFFF);
}

uint16_t Elm_Kernel_Char_toLocaleUpper(uint64_t c_raw) {
    char32_t result = Char::toLocaleUpper(static_cast<char32_t>(c_raw & 0xFFFFu));
    return static_cast<uint16_t>(result & 0xFFFF);
}

} // extern "C"
