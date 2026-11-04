#include "Basics.hpp"
// MSVC's <cmath>/<math.h> hides M_E / M_PI behind _USE_MATH_DEFINES — define
// it BEFORE the first include of <cmath> to pull them in. POSIX libstdc++
// exposes them unconditionally; the macro is a no-op there.
#define _USE_MATH_DEFINES
#include <cmath>
#include <limits>
#include <stdexcept>

namespace Elm::Kernel::Basics {

// ============================================================================
// Math Functions
// ============================================================================

double acos(double x) {
    return std::acos(x);
}

double asin(double x) {
    return std::asin(x);
}

double atan(double x) {
    return std::atan(x);
}

double atan2(double y, double x) {
    return std::atan2(y, x);
}

double cos(double x) {
    return std::cos(x);
}

double sin(double x) {
    return std::sin(x);
}

double tan(double x) {
    return std::tan(x);
}

double sqrt(double x) {
    return std::sqrt(x);
}

double log(double x) {
    return std::log(x);
}

double pow(double base, double exp) {
    return std::pow(base, exp);
}

// ============================================================================
// Constants
// ============================================================================

double e() {
    return M_E;
}

double pi() {
    return M_PI;
}

// ============================================================================
// Arithmetic
// ============================================================================

double add(double a, double b) {
    return a + b;
}

double sub(double a, double b) {
    return a - b;
}

double mul(double a, double b) {
    return a * b;
}

double fdiv(double a, double b) {
    return a / b;
}

long long idiv(long long a, long long b) {  // a / -1 is undefined for the smallest Int; unsigned negation wraps
    return b == 0 ? 0 : b == -1 ? static_cast<long long>(0ULL - static_cast<unsigned long long>(a)) : a / b;
}

long long modBy(long long modulus, long long x) {
    // `%` truncates; adding `modulus` to a remainder of the other sign gives the floored result.
    if (modulus == 0) {
        throw std::runtime_error("Elm.Kernel.Basics.modBy: modulus was zero");
    }
    long long answer = modulus == -1 ? 0 : x % modulus;  // x % -1 is undefined for the smallest Int
    if ((answer > 0 && modulus < 0) || (answer < 0 && modulus > 0)) {
        return answer + modulus;
    }
    return answer;
}

long long remainderBy(long long divisor, long long x) {  // x % -1 is undefined for the smallest Int
    return (divisor == 0 || divisor == -1) ? 0 : x % divisor;
}

// ============================================================================
// Rounding
// ============================================================================

/// Returns `x` converted to a 64-bit Int saturating: NaN gives 0, a value at or above 2^63 gives the
/// largest Int, one below -2^63 the smallest, and any other value is truncated toward zero.
///
/// A plain cast is undefined outside the Int range, which is why the bounds are tested first.
static long long saturateToInt(double x) {
    if (x != x) return 0;
    if (x >= 9223372036854775808.0) return std::numeric_limits<long long>::max();
    if (x < -9223372036854775808.0) return std::numeric_limits<long long>::min();
    return static_cast<long long>(x);
}

long long ceiling(double x) {
    return saturateToInt(std::ceil(x));
}

long long floor(double x) {
    return saturateToInt(std::floor(x));
}

// Tests x - floor(x) rather than adding 0.5 first, so 0.49999999999999994 is not rounded up
// as floor(x + 0.5) would round it.
long long round(double x) {
    double f = std::floor(x);
    if (x - f >= 0.5) f += 1.0;
    return saturateToInt(f);
}

long long truncate(double x) {
    return saturateToInt(x);
}

// ============================================================================
// Conversion
// ============================================================================

double toFloat(long long x) {
    return static_cast<double>(x);
}

// ============================================================================
// Checks
// ============================================================================

bool isInfinite(double x) {
    return std::isinf(x);
}

bool isNaN(double x) {
    return std::isnan(x);
}

// ============================================================================
// Boolean Operations
// ============================================================================

bool and_(bool a, bool b) {
    return a && b;
}

bool or_(bool a, bool b) {
    return a || b;
}

bool xor_(bool a, bool b) {
    return a != b;
}

bool not_(bool a) {
    return !a;
}

} // namespace Elm::Kernel::Basics
