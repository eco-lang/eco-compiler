#include "Basics.hpp"
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

long long idiv(long long a, long long b) {
    return a / b;
}

long long modBy(long long modulus, long long x) {
    // Implements floored division modulo (result has same sign as modulus).
    // If answer and modulus have different signs, adjust by adding modulus.
    if (modulus == 0) {
        throw std::runtime_error("Elm.Kernel.Basics.modBy: modulus was zero");
    }
    long long answer = x % modulus;
    if ((answer > 0 && modulus < 0) || (answer < 0 && modulus > 0)) {
        return answer + modulus;
    }
    return answer;
}

long long remainderBy(long long divisor, long long x) {
    return x % divisor;
}

// ============================================================================
// Rounding
// ============================================================================

long long ceiling(double x) {
    return static_cast<long long>(std::ceil(x));
}

long long floor(double x) {
    return static_cast<long long>(std::floor(x));
}

long long round(double x) {
    return static_cast<long long>(std::round(x));
}

long long truncate(double x) {
    return static_cast<long long>(std::trunc(x));
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
