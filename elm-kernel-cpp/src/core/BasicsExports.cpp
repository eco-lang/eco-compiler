//===- BasicsExports.cpp - C-linkage exports for Basics module -------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "Basics.hpp"

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

double Elm_Kernel_Basics_pow(double base, double exp) {
    return Basics::pow(base, exp);
}

double Elm_Kernel_Basics_e() {
    return Basics::e();
}

double Elm_Kernel_Basics_pi() {
    return Basics::pi();
}

double Elm_Kernel_Basics_add(double a, double b) {
    return Basics::add(a, b);
}

double Elm_Kernel_Basics_sub(double a, double b) {
    return Basics::sub(a, b);
}

double Elm_Kernel_Basics_mul(double a, double b) {
    return Basics::mul(a, b);
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

int64_t Elm_Kernel_Basics_isInfinite(double x) {
    return Export::encodeBool(Basics::isInfinite(x));
}

int64_t Elm_Kernel_Basics_isNaN(double x) {
    return Export::encodeBool(Basics::isNaN(x));
}

int64_t Elm_Kernel_Basics_and(int64_t a, int64_t b) {
    return Export::encodeBool(Basics::and_(Export::decodeBool(a), Export::decodeBool(b)));
}

int64_t Elm_Kernel_Basics_or(int64_t a, int64_t b) {
    return Export::encodeBool(Basics::or_(Export::decodeBool(a), Export::decodeBool(b)));
}

int64_t Elm_Kernel_Basics_xor(int64_t a, int64_t b) {
    return Export::encodeBool(Basics::xor_(Export::decodeBool(a), Export::decodeBool(b)));
}

int64_t Elm_Kernel_Basics_not(int64_t a) {
    return Export::encodeBool(Basics::not_(Export::decodeBool(a)));
}

} // extern "C"
