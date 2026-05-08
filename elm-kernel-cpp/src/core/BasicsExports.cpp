//===- BasicsExports.cpp - C-linkage exports for Basics module -------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "Basics.hpp"

#include <cmath>

using namespace Elm::Kernel;

extern "C" {

double Elm_Kernel_Basics_acos(double x) {
    return Basics::acos(x);
}

double Elm_Kernel_Basics_asin(double x) {
    return Basics::asin(x);
}

double Elm_Kernel_Basics_atan(double x) {
    return Basics::atan(x);
}

double Elm_Kernel_Basics_atan2(double y, double x) {
    return Basics::atan2(y, x);
}

double Elm_Kernel_Basics_cos(double x) {
    return Basics::cos(x);
}

double Elm_Kernel_Basics_sin(double x) {
    return Basics::sin(x);
}

double Elm_Kernel_Basics_tan(double x) {
    return Basics::tan(x);
}

double Elm_Kernel_Basics_sqrt(double x) {
    return Basics::sqrt(x);
}

double Elm_Kernel_Basics_log(double x) {
    return Basics::log(x);
}

// Phase E.2 / Phase F: per-instance Int / Float variants. Direct uses
// are intrinsic-lowered; these are reached only by indirect uses where
// (+) etc. is captured into a PAP. The polymorphic boxed kernels
// (Elm_Kernel_Basics_add(HPtr, HPtr) etc.) were retired in Phase F
// step 7 — `kernelInstanceSymbol` always selects `_Int` or `_Float`
// for concrete numeric calls. Semantics match `eco.int.*` /
// `eco.float.*` intrinsics.

int64_t Elm_Kernel_Basics_add_Int(int64_t a, int64_t b) {
    return a + b;
}

double Elm_Kernel_Basics_add_Float(double a, double b) {
    return a + b;
}

int64_t Elm_Kernel_Basics_sub_Int(int64_t a, int64_t b) {
    return a - b;
}

double Elm_Kernel_Basics_sub_Float(double a, double b) {
    return a - b;
}

int64_t Elm_Kernel_Basics_mul_Int(int64_t a, int64_t b) {
    return a * b;
}

double Elm_Kernel_Basics_mul_Float(double a, double b) {
    return a * b;
}

// Integer power matches the polymorphic kernel's same-tag branch:
// negative exponent yields 0; non-negative uses repeated squaring.
int64_t Elm_Kernel_Basics_pow_Int(int64_t base, int64_t exp) {
    if (exp < 0) {
        return 0;
    }
    int64_t result = 1;
    int64_t b = base;
    int64_t e = exp;
    while (e > 0) {
        if (e & 1) result *= b;
        b *= b;
        e >>= 1;
    }
    return result;
}

double Elm_Kernel_Basics_pow_Float(double base, double exp) {
    return std::pow(base, exp);
}

double Elm_Kernel_Basics_e() {
    return Basics::e();
}

double Elm_Kernel_Basics_pi() {
    return Basics::pi();
}

double Elm_Kernel_Basics_fdiv(double a, double b) {
    return Basics::fdiv(a, b);
}

int64_t Elm_Kernel_Basics_idiv(int64_t a, int64_t b) {
    return Basics::idiv(a, b);
}

int64_t Elm_Kernel_Basics_modBy(int64_t modulus, int64_t x) {
    return Basics::modBy(modulus, x);
}

int64_t Elm_Kernel_Basics_remainderBy(int64_t divisor, int64_t x) {
    return Basics::remainderBy(divisor, x);
}

int64_t Elm_Kernel_Basics_ceiling(double x) {
    return Basics::ceiling(x);
}

int64_t Elm_Kernel_Basics_floor(double x) {
    return Basics::floor(x);
}

int64_t Elm_Kernel_Basics_round(double x) {
    return Basics::round(x);
}

int64_t Elm_Kernel_Basics_truncate(double x) {
    return Basics::truncate(x);
}

double Elm_Kernel_Basics_toFloat(int64_t x) {
    return Basics::toFloat(x);
}

HPtr Elm_Kernel_Basics_isInfinite(double x) {
    return HPtr::fromBits(Export::encodeBoxedBool(Basics::isInfinite(x)));
}

HPtr Elm_Kernel_Basics_isNaN(double x) {
    return HPtr::fromBits(Export::encodeBoxedBool(Basics::isNaN(x)));
}

HPtr Elm_Kernel_Basics_and(HPtr a, HPtr b) {
    return HPtr::fromBits(Export::encodeBoxedBool(Basics::and_(Export::decodeBoxedBool(a.toBits()), Export::decodeBoxedBool(b.toBits()))));
}

HPtr Elm_Kernel_Basics_or(HPtr a, HPtr b) {
    return HPtr::fromBits(Export::encodeBoxedBool(Basics::or_(Export::decodeBoxedBool(a.toBits()), Export::decodeBoxedBool(b.toBits()))));
}

HPtr Elm_Kernel_Basics_xor(HPtr a, HPtr b) {
    return HPtr::fromBits(Export::encodeBoxedBool(Basics::xor_(Export::decodeBoxedBool(a.toBits()), Export::decodeBoxedBool(b.toBits()))));
}

HPtr Elm_Kernel_Basics_not(HPtr a) {
    return HPtr::fromBits(Export::encodeBoxedBool(Basics::not_(Export::decodeBoxedBool(a.toBits()))));
}

} // extern "C"
