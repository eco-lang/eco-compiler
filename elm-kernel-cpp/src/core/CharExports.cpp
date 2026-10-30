//===- CharExports.cpp - C-linkage exports for Char module -----------------===//

#include "../KernelExports.h"
#include "Char.hpp"

using namespace Elm::Kernel;

extern "C" {

// A Char is a Unicode code point held in 32 bits (REP_ABI_001: Char -> i32).
// Out-of-range codes (< 0 or > 0x10FFFF) become U+FFFD, as elm/core's JS
// String.fromCodePoint would throw on them and the eco.char.fromInt lowering
// uses the same replacement. Surrogate code points (0xD800..0xDFFF) pass
// through unchanged, as in JS.
uint32_t Elm_Kernel_Char_fromCode(int64_t code) {
    if (code < 0 || code > 0x10FFFF) return 0xFFFDu;
    return static_cast<uint32_t>(code);
}

// ABI note (x86-64 SysV): MLIR-emitted callers wrap kernel calls in LLVM
// `gc.statepoint` intrinsics. The statepoint represents the call's element
// type *without* per-arg attributes (no `zeroext`), so LLVM CodeGen emits a
// narrow `mov %eax, %edi`-style move that leaves the upper bits of %rdi with leftover
// state. If the C++ callees declared the parameter as `uint32_t`, the
// compiler would trust the SysV zero-extension contract — surfacing the leaked bits as the high half of the int64_t return.
//
// Receiving the parameter as `uint64_t` forces a full-register read; we
// then mask down to the canonical 32-bit Char value. The wider type also
// keeps the C++ compiler from optimising the mask away.
//
// Char.toCode is the code point itself: a Char is one code point (KERN_008).
int64_t Elm_Kernel_Char_toCode(uint64_t c_raw) {
    return static_cast<int64_t>(static_cast<uint32_t>(c_raw & 0xFFFFFFFFu));
}

// The four case mappers return one code point, the Unicode simple case mapping
// of the argument (Char.cpp, CaseMap.hpp, plans/char-simple-case-mapping.md).

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
