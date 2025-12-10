#ifndef ECO_BASICS_HPP
#define ECO_BASICS_HPP

namespace Elm::Kernel::Basics {

// ============================================================================
// Math Functions
// ============================================================================

// Returns arc cosine of x in radians.
double acos(double x);

// Returns arc sine of x in radians.
double asin(double x);

// Returns arc tangent of x in radians.
double atan(double x);

// Returns arc tangent of y/x, using signs to determine quadrant.
double atan2(double y, double x);

// Returns cosine of x (x in radians).
double cos(double x);

// Returns sine of x (x in radians).
double sin(double x);

// Returns tangent of x (x in radians).
double tan(double x);

// Returns square root of x.
double sqrt(double x);

// Returns natural logarithm (base e) of x.
double log(double x);

// Returns base raised to the power of exp.
double pow(double base, double exp);

// ============================================================================
// Constants
// ============================================================================

// Returns Euler's number e (approximately 2.718281828).
double e();

// Returns pi (approximately 3.14159265).
double pi();

// ============================================================================
// Arithmetic
// ============================================================================

// Returns a + b.
double add(double a, double b);

// Returns a - b.
double sub(double a, double b);

// Returns a * b.
double mul(double a, double b);

// Returns floating-point division a / b.
double fdiv(double a, double b);

// Returns integer division of a / b, truncated toward zero.
long long idiv(long long a, long long b);

// Returns modulo using floored division (result has same sign as modulus).
long long modBy(long long modulus, long long x);

// Returns remainder using truncated division (result has same sign as dividend).
long long remainderBy(long long divisor, long long x);

// ============================================================================
// Rounding
// ============================================================================

// Returns smallest integer >= x.
long long ceiling(double x);

// Returns largest integer <= x.
long long floor(double x);

// Returns nearest integer to x (rounds half away from zero).
long long round(double x);

// Returns integer part of x, truncating toward zero.
long long truncate(double x);

// ============================================================================
// Conversion
// ============================================================================

// Converts integer to float.
double toFloat(long long x);

// ============================================================================
// Checks
// ============================================================================

// Returns true if x is positive or negative infinity.
bool isInfinite(double x);

// Returns true if x is NaN (not a number).
bool isNaN(double x);

// ============================================================================
// Boolean Operations
// ============================================================================

// Returns logical AND of a and b.
bool and_(bool a, bool b);

// Returns logical OR of a and b.
bool or_(bool a, bool b);

// Returns logical XOR of a and b (true if exactly one is true).
bool xor_(bool a, bool b);

// Returns logical NOT of a.
bool not_(bool a);

} // namespace Elm::Kernel::Basics

#endif // ECO_BASICS_HPP
