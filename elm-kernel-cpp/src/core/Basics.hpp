#ifndef ELM_KERNEL_BASICS_HPP
#define ELM_KERNEL_BASICS_HPP

namespace Elm::Kernel::Basics {

// Math functions
double acos(double x);
double asin(double x);
double atan(double x);
double atan2(double y, double x);
double cos(double x);
double sin(double x);
double tan(double x);
double sqrt(double x);
double log(double x);
double pow(double base, double exp);

// Constants
double e();
double pi();

// Arithmetic
double add(double a, double b);
double sub(double a, double b);
double mul(double a, double b);
double fdiv(double a, double b);
long long idiv(long long a, long long b);
long long modBy(long long modulus, long long x);
long long remainderBy(long long divisor, long long x);

// Rounding
long long ceiling(double x);
long long floor(double x);
long long round(double x);
long long truncate(double x);

// Conversion
double toFloat(long long x);

// Checks
bool isInfinite(double x);
bool isNaN(double x);

// Boolean operations
bool and_(bool a, bool b);
bool or_(bool a, bool b);
bool xor_(bool a, bool b);
bool not_(bool a);

} // namespace Elm::Kernel::Basics

#endif // ELM_KERNEL_BASICS_HPP
