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

/// Returns `base` raised to a negative power `exp`: the truncation of the real result, which is
/// 1 for base 1, 1 or -1 for base -1 (by the parity of `exp`), and 0 for every other base, 0 included
/// (The Definition of Standard Elm, ruling A43). Branch-free: for a base in {-1, 0, 1} the result is
/// the base itself when `exp` is odd and `base & 1` when it is even, and the unsigned compare
/// `base + 1 <= 2` masks every other base to 0. Computed in `uint64_t`, so no step overflows.
constexpr int64_t ecoIntPowNegative(int64_t base, int64_t exp) {
    uint64_t b = static_cast<uint64_t>(base);
    uint64_t inRange = -static_cast<uint64_t>(b + 1 <= 2);           // all ones iff base in {-1, 0, 1}
    uint64_t keep = -static_cast<uint64_t>(exp & 1) | 1;            // odd: all ones; even: 1
    return static_cast<int64_t>(b & keep & inRange);
}

/// Returns `base` raised to the power `exp`, wrapped modulo 2^64, by exponentiation by squaring; a
/// negative `exp` is handled by `ecoIntPowNegative`. The base is not squared after the last exponent
/// bit is used, so no needless intermediate is computed.
constexpr int64_t ecoIntPow(int64_t base, int64_t exp) {
    if (exp < 0) {
        return ecoIntPowNegative(base, exp);
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
