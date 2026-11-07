// Elm Int arithmetic wraps modulo 2^64 (decision D31, design_docs/elm-divergence.md section 1). The kernel
// and runtime bodies (`Elm_Kernel_Basics_*`, `eco_int_pow`, which `eco.int.pow` lowers to) are the `constexpr`
// helpers of runtime/src/allocator/IntArith.hpp, so evaluating them in a constant expression makes the compiler
// reject any signed overflow (undefined behaviour) on the way: they must compute in `uint64_t` and cast back,
// and `ecoIntPow` must not square once more after the exponent's last bit (2^62 would compute 2^64).
// Compiled with -fsyntax-only by test/scripts/run-static-asserts.sh.
//
// STATIC-ASSERT-REF: runtime/src/allocator/RuntimeExports.cpp

#include "allocator/IntArith.hpp"

#include <cstdint>
#include <limits>

namespace {
constexpr int64_t kMax = std::numeric_limits<int64_t>::max();
constexpr int64_t kMin = std::numeric_limits<int64_t>::min();
}  // namespace

// `+`, `-`, `*` wrap.
static_assert(Elm::ecoIntAdd(40, 2) == 42);
static_assert(Elm::ecoIntAdd(kMax, 1) == kMin, "maxInt + 1 wraps to minInt");
static_assert(Elm::ecoIntSub(kMin, 1) == kMax, "minInt - 1 wraps to maxInt");
static_assert(Elm::ecoIntMul(kMax, 2) == -2, "maxInt * 2 wraps to -2");
static_assert(Elm::ecoIntMul(kMin, -1) == kMin, "minInt * -1 wraps to minInt");

// `^`: results that fit never overflow on the way.
static_assert(Elm::ecoIntPow(5, -1) == 0, "negative exponent of another base gives 0");

// `^` with a negative exponent: the truncation of the real result (ruling A43).
static_assert(Elm::ecoIntPow(1, -1) == 1, "1^-1 is 1");
static_assert(Elm::ecoIntPow(1, kMin) == 1, "1^minInt is 1");
static_assert(Elm::ecoIntPow(-1, -1) == -1, "(-1)^-1 is -1");
static_assert(Elm::ecoIntPow(-1, -3) == -1, "(-1)^-3 is -1");
static_assert(Elm::ecoIntPow(-1, -2) == 1, "(-1)^-2 is 1");
static_assert(Elm::ecoIntPow(-1, kMin) == 1, "(-1)^minInt is 1 (minInt is even)");
static_assert(Elm::ecoIntPow(0, -1) == 0, "0^-1 is 0");
static_assert(Elm::ecoIntPow(2, -1) == 0, "2^-1 is 0");
static_assert(Elm::ecoIntPow(-2, -1) == 0, "(-2)^-1 is 0");
static_assert(Elm::ecoIntPow(kMax, -1) == 0, "maxInt^-1 is 0 (base + 1 must not wrap into range)");
static_assert(Elm::ecoIntPow(kMin, -1) == 0, "minInt^-1 is 0");
static_assert(Elm::ecoIntPow(0, 0) == 1, "0^0 is 1");
static_assert(Elm::ecoIntPow(2, 10) == 1024);
static_assert(Elm::ecoIntPow(2, 62) == 4611686018427387904LL, "2^62 fits");
static_assert(Elm::ecoIntPow(3, 39) == 4052555153018976267LL, "3^39 fits");
static_assert(Elm::ecoIntPow(-2, 63) == kMin, "(-2)^63 is minInt");
static_assert(Elm::ecoIntPow(-3, 39) == -4052555153018976267LL, "(-3)^39 fits");
static_assert(Elm::ecoIntPow(7, 22) == 3909821048582988049LL, "7^22 fits");
