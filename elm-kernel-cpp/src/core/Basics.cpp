#include "Basics.hpp"
#include <cmath>
#include <limits>
#include <stdexcept>

namespace Elm::Kernel::Basics {

// ============================================================================
// Math Functions
// ============================================================================

double acos(double x) {
    /*
     * JS: var _Basics_acos = Math.acos;
     *
     * PSEUDOCODE:
     * - Return arc cosine of x in radians
     *
     * HELPERS: None
     * LIBRARIES: <cmath> std::acos
     */
    return std::acos(x);
}

double asin(double x) {
    /*
     * JS: var _Basics_asin = Math.asin;
     *
     * PSEUDOCODE:
     * - Return arc sine of x in radians
     *
     * HELPERS: None
     * LIBRARIES: <cmath> std::asin
     */
    return std::asin(x);
}

double atan(double x) {
    /*
     * JS: var _Basics_atan = Math.atan;
     *
     * PSEUDOCODE:
     * - Return arc tangent of x in radians
     *
     * HELPERS: None
     * LIBRARIES: <cmath> std::atan
     */
    return std::atan(x);
}

double atan2(double y, double x) {
    /*
     * JS: var _Basics_atan2 = F2(Math.atan2);
     *
     * PSEUDOCODE:
     * - Return arc tangent of y/x, using signs to determine quadrant
     *
     * HELPERS: None
     * LIBRARIES: <cmath> std::atan2
     */
    return std::atan2(y, x);
}

double cos(double x) {
    /*
     * JS: var _Basics_cos = Math.cos;
     *
     * PSEUDOCODE:
     * - Return cosine of x (x in radians)
     *
     * HELPERS: None
     * LIBRARIES: <cmath> std::cos
     */
    return std::cos(x);
}

double sin(double x) {
    /*
     * JS: var _Basics_sin = Math.sin;
     *
     * PSEUDOCODE:
     * - Return sine of x (x in radians)
     *
     * HELPERS: None
     * LIBRARIES: <cmath> std::sin
     */
    return std::sin(x);
}

double tan(double x) {
    /*
     * JS: var _Basics_tan = Math.tan;
     *
     * PSEUDOCODE:
     * - Return tangent of x (x in radians)
     *
     * HELPERS: None
     * LIBRARIES: <cmath> std::tan
     */
    return std::tan(x);
}

double sqrt(double x) {
    /*
     * JS: var _Basics_sqrt = Math.sqrt;
     *
     * PSEUDOCODE:
     * - Return square root of x
     *
     * HELPERS: None
     * LIBRARIES: <cmath> std::sqrt
     */
    return std::sqrt(x);
}

double log(double x) {
    /*
     * JS: var _Basics_log = Math.log;
     *
     * PSEUDOCODE:
     * - Return natural logarithm (base e) of x
     *
     * HELPERS: None
     * LIBRARIES: <cmath> std::log
     */
    return std::log(x);
}

double pow(double base, double exp) {
    /*
     * JS: var _Basics_pow = F2(Math.pow);
     *
     * PSEUDOCODE:
     * - Return base raised to the power of exp
     *
     * HELPERS: None
     * LIBRARIES: <cmath> std::pow
     */
    return std::pow(base, exp);
}

// ============================================================================
// Constants
// ============================================================================

double e() {
    /*
     * JS: var _Basics_e = Math.E;
     *
     * PSEUDOCODE:
     * - Return Euler's number e ≈ 2.718281828...
     *
     * HELPERS: None
     * LIBRARIES: <cmath> M_E or <numbers> std::numbers::e
     */
    return M_E;
}

double pi() {
    /*
     * JS: var _Basics_pi = Math.PI;
     *
     * PSEUDOCODE:
     * - Return pi ≈ 3.14159265...
     *
     * HELPERS: None
     * LIBRARIES: <cmath> M_PI or <numbers> std::numbers::pi
     */
    return M_PI;
}

// ============================================================================
// Arithmetic
// ============================================================================

double add(double a, double b) {
    /*
     * JS: var _Basics_add = F2(function(a, b) { return a + b; });
     *
     * PSEUDOCODE:
     * - Return a + b
     *
     * HELPERS: None
     * LIBRARIES: None (built-in operator)
     */
    return a + b;
}

double sub(double a, double b) {
    /*
     * JS: var _Basics_sub = F2(function(a, b) { return a - b; });
     *
     * PSEUDOCODE:
     * - Return a - b
     *
     * HELPERS: None
     * LIBRARIES: None (built-in operator)
     */
    return a - b;
}

double mul(double a, double b) {
    /*
     * JS: var _Basics_mul = F2(function(a, b) { return a * b; });
     *
     * PSEUDOCODE:
     * - Return a * b
     *
     * HELPERS: None
     * LIBRARIES: None (built-in operator)
     */
    return a * b;
}

double fdiv(double a, double b) {
    /*
     * JS: var _Basics_fdiv = F2(function(a, b) { return a / b; });
     *
     * PSEUDOCODE:
     * - Return floating-point division a / b
     *
     * HELPERS: None
     * LIBRARIES: None (built-in operator)
     */
    return a / b;
}

long long idiv(long long a, long long b) {
    /*
     * JS: var _Basics_idiv = F2(function(a, b) { return (a / b) | 0; });
     *
     * PSEUDOCODE:
     * - Return integer division of a / b, truncated toward zero
     * - The | 0 in JS truncates to 32-bit int; in C++ we use long long division
     *
     * HELPERS: None
     * LIBRARIES: None (built-in operator)
     */
    return a / b;
}

long long modBy(long long modulus, long long x) {
    /*
     * JS: var _Basics_modBy = F2(function(modulus, x)
     *     {
     *         var answer = x % modulus;
     *         return modulus === 0
     *             ? __Debug_crash(11)
     *             :
     *         ((answer > 0 && modulus < 0) || (answer < 0 && modulus > 0))
     *             ? answer + modulus
     *             : answer;
     *     });
     *
     * PSEUDOCODE:
     * - If modulus is 0, crash (division by zero)
     * - Compute answer = x % modulus
     * - If answer and modulus have different signs, adjust by adding modulus
     * - This gives "floored division" modulo (result has same sign as divisor)
     *
     * HELPERS: Debug::crash (for modulus == 0)
     * LIBRARIES: None
     *
     * Reference: https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/divmodnote-letter.pdf
     */
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
    /*
     * JS: var _Basics_remainderBy = F2(function(b, a) { return a % b; });
     *
     * PSEUDOCODE:
     * - Return x % divisor (truncated division remainder)
     * - Note: argument order is (divisor, x) to match Elm's curried style
     *
     * HELPERS: None
     * LIBRARIES: None (built-in operator)
     */
    return x % divisor;
}

// ============================================================================
// Rounding
// ============================================================================

long long ceiling(double x) {
    /*
     * JS: var _Basics_ceiling = Math.ceil;
     *
     * PSEUDOCODE:
     * - Return smallest integer >= x
     *
     * HELPERS: None
     * LIBRARIES: <cmath> std::ceil
     */
    return static_cast<long long>(std::ceil(x));
}

long long floor(double x) {
    /*
     * JS: var _Basics_floor = Math.floor;
     *
     * PSEUDOCODE:
     * - Return largest integer <= x
     *
     * HELPERS: None
     * LIBRARIES: <cmath> std::floor
     */
    return static_cast<long long>(std::floor(x));
}

long long round(double x) {
    /*
     * JS: var _Basics_round = Math.round;
     *
     * PSEUDOCODE:
     * - Return nearest integer to x (rounds half away from zero)
     *
     * HELPERS: None
     * LIBRARIES: <cmath> std::round
     */
    return static_cast<long long>(std::round(x));
}

long long truncate(double x) {
    /*
     * JS: function _Basics_truncate(n) { return n | 0; }
     *
     * PSEUDOCODE:
     * - Return integer part of x, truncating toward zero
     * - JS uses | 0 to truncate to 32-bit int
     *
     * HELPERS: None
     * LIBRARIES: <cmath> std::trunc
     */
    return static_cast<long long>(std::trunc(x));
}

// ============================================================================
// Conversion
// ============================================================================

double toFloat(long long x) {
    /*
     * JS: function _Basics_toFloat(x) { return x; }
     *
     * PSEUDOCODE:
     * - Convert integer to float (in JS this is a no-op since all numbers are floats)
     * - In C++ we need an explicit cast
     *
     * HELPERS: None
     * LIBRARIES: None
     */
    return static_cast<double>(x);
}

// ============================================================================
// Checks
// ============================================================================

bool isInfinite(double x) {
    /*
     * JS: function _Basics_isInfinite(n) { return n === Infinity || n === -Infinity; }
     *
     * PSEUDOCODE:
     * - Return true if x is positive or negative infinity
     *
     * HELPERS: None
     * LIBRARIES: <cmath> std::isinf
     */
    return std::isinf(x);
}

bool isNaN(double x) {
    /*
     * JS: var _Basics_isNaN = isNaN;
     *
     * PSEUDOCODE:
     * - Return true if x is NaN (not a number)
     *
     * HELPERS: None
     * LIBRARIES: <cmath> std::isnan
     */
    return std::isnan(x);
}

// ============================================================================
// Boolean Operations
// ============================================================================

bool and_(bool a, bool b) {
    /*
     * JS: var _Basics_and = F2(function(a, b) { return a && b; });
     *
     * PSEUDOCODE:
     * - Return logical AND of a and b
     *
     * HELPERS: None
     * LIBRARIES: None (built-in operator)
     */
    return a && b;
}

bool or_(bool a, bool b) {
    /*
     * JS: var _Basics_or = F2(function(a, b) { return a || b; });
     *
     * PSEUDOCODE:
     * - Return logical OR of a and b
     *
     * HELPERS: None
     * LIBRARIES: None (built-in operator)
     */
    return a || b;
}

bool xor_(bool a, bool b) {
    /*
     * JS: var _Basics_xor = F2(function(a, b) { return a !== b; });
     *
     * PSEUDOCODE:
     * - Return logical XOR of a and b (true if exactly one is true)
     *
     * HELPERS: None
     * LIBRARIES: None (built-in operator)
     */
    return a != b;
}

bool not_(bool a) {
    /*
     * JS: function _Basics_not(bool) { return !bool; }
     *
     * PSEUDOCODE:
     * - Return logical NOT of a
     *
     * HELPERS: None
     * LIBRARIES: None (built-in operator)
     */
    return !a;
}

} // namespace Elm::Kernel::Basics
