// The C++ side of elm/core's `Basics` module: the arithmetic, rounding and Bool operations whose
// Elm meaning differs from what the same C++ expression does.
//
// This kernel fixes a result for nearly every input. Integer division and `remainderBy` by 0 or
// -1 have defined answers, a Float outside the Int range converts to a defined Int, and `round`
// breaks ties the way JavaScript's `Math.round` does. In C++ the plain expressions are undefined
// for some of these inputs, or give a different answer, so the functions here spell out the Elm
// result case by case. `modBy` with a zero modulus gives 0, as the inline lowering does, where
// elm/core crashes (CGEN_084, design_docs/elm-divergence.md).
// Int is a 64-bit two's-complement integer here (`long long`) and Float is a `double`.
//
// A *saturating* conversion from Float to Int, used by every rounding function, gives 0 for NaN,
// the largest Int for a value at or above 2^63, the smallest Int for a value below -2^63, and
// otherwise the value truncated toward zero.
//
// Everything here is a pure function of its arguments and touches no heap. The `extern "C"` exports
// declared in `KernelExports.h` call most of them. `pow`, `add`, `sub` and `mul` are not called by
// those exports, which compute their results inline.
#ifndef ECO_BASICS_HPP
#define ECO_BASICS_HPP

namespace Elm::Kernel::Basics {

// ============================================================================
// Math Functions
// ============================================================================

/// Returns the arc cosine of `x`, in radians, as `std::acos` does.
double acos(double x);

/// Returns the arc sine of `x`, in radians, as `std::asin` does.
double asin(double x);

/// Returns the arc tangent of `x`, in radians, as `std::atan` does.
double atan(double x);

/// Returns the angle, in radians, of the point (`x`, `y`), as `std::atan2(y, x)` does. The signs of
/// both arguments choose the quadrant.
double atan2(double y, double x);

/// Returns the cosine of `x`, which is in radians.
double cos(double x);

/// Returns the sine of `x`, which is in radians.
double sin(double x);

/// Returns the tangent of `x`, which is in radians.
double tan(double x);

/// Returns the square root of `x`, as `std::sqrt` does (NaN for a negative `x`).
double sqrt(double x);

/// Returns the natural logarithm of `x`, as `std::log` does.
double log(double x);

/// Returns `base` raised to the power `exp`, as `std::pow` does. The `Basics.pow` exports do not
/// call it.
double pow(double base, double exp);

// ============================================================================
// Constants
// ============================================================================

/// Returns Euler's number, the base of the natural logarithm (`M_E`).
double e();

/// Returns the ratio of a circle's circumference to its diameter (`M_PI`).
double pi();

// ============================================================================
// Arithmetic
// ============================================================================

/// Returns the Float sum of `a` and `b`. The `Basics.add` exports do not call it.
double add(double a, double b);

/// Returns `a` minus `b` as a Float. The `Basics.sub` exports do not call it.
double sub(double a, double b);

/// Returns the Float product of `a` and `b`. The `Basics.mul` exports do not call it.
double mul(double a, double b);

/// Returns `a` divided by `b` in IEEE arithmetic, so a zero `b` gives an infinity or NaN.
double fdiv(double a, double b);

/// Returns `a` divided by `b`, truncated toward zero.
///
/// A zero `b` gives 0. A `b` of -1 gives `-a` with two's-complement wrapping, so the smallest Int
/// divided by -1 is the smallest Int.
long long idiv(long long a, long long b);

/// Returns `x` modulo `modulus` by floored division, so a non-zero result has the sign of `modulus`.
///
/// A `modulus` of -1 or 0 gives 0.
long long modBy(long long modulus, long long x);

/// Returns the remainder of `x` divided by `divisor` by truncated division, so a non-zero result has
/// the sign of `x`. A `divisor` of 0 or -1 gives 0.
long long remainderBy(long long divisor, long long x);

// ============================================================================
// Rounding
// ============================================================================

/// Returns the smallest integer not less than `x`, converted to Int saturating.
long long ceiling(double x);

/// Returns the largest integer not greater than `x`, converted to Int saturating.
long long floor(double x);

/// Returns the integer nearest to `x`, converted to Int saturating.
///
/// A tie goes toward positive infinity, as JavaScript's `Math.round` does: 2.5 gives 3 and -2.5
/// gives -2, where `std::round` would give -3.
long long round(double x);

/// Returns `x` truncated toward zero, converted to Int saturating.
long long truncate(double x);

// ============================================================================
// Conversion
// ============================================================================

/// Returns the Float nearest to `x`; an Int beyond 2^53 in magnitude may not be exact.
double toFloat(long long x);

// ============================================================================
// Checks
// ============================================================================

/// Returns whether `x` is positive or negative infinity.
bool isInfinite(double x);

/// Returns whether `x` is NaN.
bool isNaN(double x);

// ============================================================================
// Boolean Operations
// ============================================================================

/// Returns whether both `a` and `b` are true. Both are already evaluated, so nothing short-circuits.
bool and_(bool a, bool b);

/// Returns whether `a` or `b` is true. Both are already evaluated, so nothing short-circuits.
bool or_(bool a, bool b);

/// Returns whether exactly one of `a` and `b` is true.
bool xor_(bool a, bool b);

/// Returns the negation of `a`.
bool not_(bool a);

} // namespace Elm::Kernel::Basics

#endif // ECO_BASICS_HPP
