//===- IntArith.hpp - Elm Int add, sub, mul and pow ------------------------===//
//
// The bodies of Elm's Int `+`, `-`, `*` and `^` as the kernel calls them: `Elm_Kernel_Basics_add_Int`,
// `sub_Int`, `mul_Int` and `pow_Int` (elm-kernel-cpp core/BasicsExports.cpp), and the runtime helper
// `eco_int_pow` that `eco.int.pow` lowers to (RuntimeExports.cpp). They live here, header-only and
// `constexpr`, so that one definition serves both callers and a test can evaluate them in a constant
// expression, where the compiler rejects any undefined behaviour.
//
// Elm Int arithmetic wraps modulo 2^64 (design_docs/elm-divergence.md section 1). Signed overflow is
// undefined behaviour in C++, so every body computes in `uint64_t`, where C++ defines wrap-around,
// and converts back (a modular conversion since C++20). The generated code is the same plain
// `add`/`sub`/`imul` (BASICS-01/02/NEW-1).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_ALLOCATOR_INT_ARITH_HPP
#define ECO_ALLOCATOR_INT_ARITH_HPP

#include <cstdint>

namespace Elm {

/// Returns `a + b`, wrapped modulo 2^64.
constexpr int64_t ecoIntAdd(int64_t a, int64_t b) {
    return static_cast<int64_t>(static_cast<uint64_t>(a) + static_cast<uint64_t>(b));
}

/// Returns `a - b`, wrapped modulo 2^64.
constexpr int64_t ecoIntSub(int64_t a, int64_t b) {
    return static_cast<int64_t>(static_cast<uint64_t>(a) - static_cast<uint64_t>(b));
}

/// Returns `a * b`, wrapped modulo 2^64.
constexpr int64_t ecoIntMul(int64_t a, int64_t b) {
    return static_cast<int64_t>(static_cast<uint64_t>(a) * static_cast<uint64_t>(b));
}

/// Returns `base` raised to the power `exp`, wrapped modulo 2^64, or 0 when `exp` is negative, by
/// exponentiation by squaring. The base is not squared after the last exponent bit is used, so no
/// needless intermediate is computed.
constexpr int64_t ecoIntPow(int64_t base, int64_t exp) {
    if (exp < 0) {
        return 0;
    }
    uint64_t result = 1;
    uint64_t b = static_cast<uint64_t>(base);
    uint64_t e = static_cast<uint64_t>(exp);
    while (e) {
        if (e & 1) result *= b;
        e >>= 1;
        if (e) b *= b;
    }
    return static_cast<int64_t>(result);
}

} // namespace Elm

#endif // ECO_ALLOCATOR_INT_ARITH_HPP
