//===- BasicsExports.cpp - C-linkage exports for Basics module -------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "Basics.hpp"
#include "../../../runtime/src/allocator/IntArith.hpp"

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

// `add`, `sub`, `mul` and `pow` come in three forms: an `_Int` variant on raw `int64_t`, a `_Float`
// variant on raw `double`, and a boxed form on two `HPtr` words that each refer to a heap `ElmInt` or
// `ElmFloat`. The boxed form reads the tag of `a` only, calls the matching typed variant on the two
// unboxed values, and allocates the boxed result after both values have been read, so nothing is
// held across that allocation.
//
// The typed Int variants wrap modulo 2^64 on overflow (they compute in `uint64_t`). Their bodies are
// `Elm::ecoIntAdd`, `ecoIntSub`, `ecoIntMul` and `ecoIntPow` (runtime allocator/IntArith.hpp).

namespace {

/// Returns the heap tag of the object `p` refers to.
///
/// `p` must refer to a heap object. An Int or Float is never an embedded constant, so a boxed number
/// always qualifies; an embedded constant would be dereferenced as an address.
inline Elm::Tag tagOfBoxed(HPtr p) {
    void* obj = Elm::Kernel::Export::toPtr(p.toBits());
    return Elm::alloc::getTag(obj);
}

/// Returns the value of the heap `ElmInt` that `p` refers to. The tag is not checked.
inline int64_t intOfBoxed(HPtr p) {
    void* obj = Elm::Kernel::Export::toPtr(p.toBits());
    return static_cast<Elm::ElmInt*>(obj)->value;
}

/// Returns the value of the heap `ElmFloat` that `p` refers to. The tag is not checked.
inline double floatOfBoxed(HPtr p) {
    void* obj = Elm::Kernel::Export::toPtr(p.toBits());
    return static_cast<Elm::ElmFloat*>(obj)->value;
}

/// Allocates a heap `ElmInt` holding `v` and returns its word. The allocation is a GC point.
inline HPtr boxInt(int64_t v) {
    return HPtr::fromBits(Elm::Kernel::Export::encode(Elm::alloc::allocInt(v)));
}

/// Allocates a heap `ElmFloat` holding `v` and returns its word. The allocation is a GC point.
inline HPtr boxFloat(double v) {
    return HPtr::fromBits(Elm::Kernel::Export::encode(Elm::alloc::allocFloat(v)));
}

} // anonymous namespace

HPtr Elm_Kernel_Basics_add(HPtr a, HPtr b) {
    if (tagOfBoxed(a) == Elm::Tag_Int) {
        return boxInt(Elm_Kernel_Basics_add_Int(intOfBoxed(a), intOfBoxed(b)));
    }
    return boxFloat(Elm_Kernel_Basics_add_Float(floatOfBoxed(a), floatOfBoxed(b)));
}

HPtr Elm_Kernel_Basics_sub(HPtr a, HPtr b) {
    if (tagOfBoxed(a) == Elm::Tag_Int) {
        return boxInt(Elm_Kernel_Basics_sub_Int(intOfBoxed(a), intOfBoxed(b)));
    }
    return boxFloat(Elm_Kernel_Basics_sub_Float(floatOfBoxed(a), floatOfBoxed(b)));
}

HPtr Elm_Kernel_Basics_mul(HPtr a, HPtr b) {
    if (tagOfBoxed(a) == Elm::Tag_Int) {
        return boxInt(Elm_Kernel_Basics_mul_Int(intOfBoxed(a), intOfBoxed(b)));
    }
    return boxFloat(Elm_Kernel_Basics_mul_Float(floatOfBoxed(a), floatOfBoxed(b)));
}

HPtr Elm_Kernel_Basics_pow(HPtr a, HPtr b) {
    if (tagOfBoxed(a) == Elm::Tag_Int) {
        return boxInt(Elm_Kernel_Basics_pow_Int(intOfBoxed(a), intOfBoxed(b)));
    }
    return boxFloat(Elm_Kernel_Basics_pow_Float(floatOfBoxed(a), floatOfBoxed(b)));
}

int64_t Elm_Kernel_Basics_add_Int(int64_t a, int64_t b) {
    return Elm::ecoIntAdd(a, b);
}

double Elm_Kernel_Basics_add_Float(double a, double b) {
    return a + b;
}

int64_t Elm_Kernel_Basics_sub_Int(int64_t a, int64_t b) {
    return Elm::ecoIntSub(a, b);
}

double Elm_Kernel_Basics_sub_Float(double a, double b) {
    return a - b;
}

int64_t Elm_Kernel_Basics_mul_Int(int64_t a, int64_t b) {
    return Elm::ecoIntMul(a, b);
}

double Elm_Kernel_Basics_mul_Float(double a, double b) {
    return a * b;
}

// A negative exponent gives 0. Otherwise this is exponentiation by squaring, wrapped modulo 2^64.
int64_t Elm_Kernel_Basics_pow_Int(int64_t base, int64_t exp) {
    return Elm::ecoIntPow(base, exp);
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
