//===- BasicsExports.cpp - C-linkage exports for Basics module -------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "Basics.hpp"

// Include allocator for polymorphic arithmetic that needs to examine tagged values.
#include "../../../runtime/src/allocator/Allocator.hpp"
#include "../../../runtime/src/allocator/Heap.hpp"
#include <cmath>
#include <cstring>

using namespace Elm::Kernel;

namespace {

// Helper to reinterpret uint64_t as HPointer (they're both 64 bits).
inline Elm::HPointer toHPointer(uint64_t val) {
    Elm::HPointer ptr;
    static_assert(sizeof(ptr) == sizeof(val), "HPointer must be 64 bits");
    memcpy(&ptr, &val, sizeof(ptr));
    return ptr;
}

// Convert uint64_t to void pointer, handling both raw pointers and HPointers.
// Same logic as in ExportHelpers.hpp::toPtr().
inline void* toPtr(uint64_t val) {
    Elm::HPointer h = toHPointer(val);

    // Check for embedded constants (constant field 1-7).
    if (h.constant >= 1 && h.constant <= 7) {
        return nullptr;
    }

    // If constant is non-zero but outside valid range, it's a raw pointer.
    if (h.constant != 0) {
        return reinterpret_cast<void*>(val);
    }

    // constant == 0: Check padding to distinguish HPointer from raw pointer.
    // For valid HPointers, padding must be 0.
    // For raw x86-64 pointers (e.g., 0x7f38835ba0e0), bits 44+ will be non-zero.
    if (h.padding != 0) {
        return reinterpret_cast<void*>(val);
    }

    // padding == 0 and constant == 0: This is a valid HPointer.
    return Elm::Allocator::instance().resolve(h);
}

// Helper to get numeric values from a pointer (either raw or HPointer).
// Returns true if it's an Int (value in intVal), false if Float (value in floatVal).
inline bool getNumericValue(uint64_t hptr, Elm::i64& intVal, Elm::f64& floatVal) {
    void* obj = toPtr(hptr);
    if (!obj) {
        // Invalid pointer - treat as 0
        intVal = 0;
        return true;
    }
    Elm::Header* hdr = static_cast<Elm::Header*>(obj);
    if (hdr->tag == Elm::Tag_Int) {
        Elm::ElmInt* intObj = static_cast<Elm::ElmInt*>(obj);
        intVal = intObj->value;
        return true;
    } else if (hdr->tag == Elm::Tag_Float) {
        Elm::ElmFloat* floatObj = static_cast<Elm::ElmFloat*>(obj);
        floatVal = floatObj->value;
        return false;
    }
    // Unknown type - treat as 0
    intVal = 0;
    return true;
}

} // anonymous namespace

// Route boxing through the canonical runtime symbols so a counter on
// eco_alloc_int / eco_alloc_float catches polymorphic arithmetic too.
extern "C" Elm::HPtr eco_alloc_int(int64_t value);
extern "C" Elm::HPtr eco_alloc_float(double value);

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

// Polymorphic pow - examines tags to determine Int or Float arithmetic.
HPtr Elm_Kernel_Basics_pow(HPtr base, HPtr exp) {
    uint64_t base_ptr = base.toBits();
    uint64_t exp_ptr = exp.toBits();
    Elm::i64 base_i, exp_i;
    Elm::f64 base_f, exp_f;
    bool base_is_int = getNumericValue(base_ptr, base_i, base_f);
    bool exp_is_int = getNumericValue(exp_ptr, exp_i, exp_f);

    // If both are ints, do integer power
    if (base_is_int && exp_is_int) {
        // Integer power - use repeated multiplication for positive exponents
        if (exp_i < 0) {
            // Negative exponent with ints -> result is 0 (integer division)
            return eco_alloc_int(0);
        }
        Elm::i64 result = 1;
        Elm::i64 b = base_i;
        Elm::i64 e = exp_i;
        while (e > 0) {
            if (e & 1) result *= b;
            b *= b;
            e >>= 1;
        }
        return eco_alloc_int(result);
    }

    // At least one is a float - convert to float arithmetic
    Elm::f64 base_val = base_is_int ? static_cast<Elm::f64>(base_i) : base_f;
    Elm::f64 exp_val = exp_is_int ? static_cast<Elm::f64>(exp_i) : exp_f;
    return eco_alloc_float(std::pow(base_val, exp_val));
}

// Polymorphic add - examines tags to determine Int or Float arithmetic.
HPtr Elm_Kernel_Basics_add(HPtr a, HPtr b) {
    uint64_t a_ptr = a.toBits();
    uint64_t b_ptr = b.toBits();
    Elm::i64 a_i, b_i;
    Elm::f64 a_f, b_f;
    bool a_is_int = getNumericValue(a_ptr, a_i, a_f);
    bool b_is_int = getNumericValue(b_ptr, b_i, b_f);

    // If both are ints, do integer addition
    if (a_is_int && b_is_int) {
        return eco_alloc_int(a_i + b_i);
    }

    // At least one is a float - convert to float arithmetic
    Elm::f64 a_val = a_is_int ? static_cast<Elm::f64>(a_i) : a_f;
    Elm::f64 b_val = b_is_int ? static_cast<Elm::f64>(b_i) : b_f;
    return eco_alloc_float(a_val + b_val);
}

// Polymorphic sub - examines tags to determine Int or Float arithmetic.
HPtr Elm_Kernel_Basics_sub(HPtr a, HPtr b) {
    uint64_t a_ptr = a.toBits();
    uint64_t b_ptr = b.toBits();
    Elm::i64 a_i, b_i;
    Elm::f64 a_f, b_f;
    bool a_is_int = getNumericValue(a_ptr, a_i, a_f);
    bool b_is_int = getNumericValue(b_ptr, b_i, b_f);

    // If both are ints, do integer subtraction
    if (a_is_int && b_is_int) {
        return eco_alloc_int(a_i - b_i);
    }

    // At least one is a float - convert to float arithmetic
    Elm::f64 a_val = a_is_int ? static_cast<Elm::f64>(a_i) : a_f;
    Elm::f64 b_val = b_is_int ? static_cast<Elm::f64>(b_i) : b_f;
    return eco_alloc_float(a_val - b_val);
}

// Polymorphic mul - examines tags to determine Int or Float arithmetic.
HPtr Elm_Kernel_Basics_mul(HPtr a, HPtr b) {
    uint64_t a_ptr = a.toBits();
    uint64_t b_ptr = b.toBits();
    Elm::i64 a_i, b_i;
    Elm::f64 a_f, b_f;
    bool a_is_int = getNumericValue(a_ptr, a_i, a_f);
    bool b_is_int = getNumericValue(b_ptr, b_i, b_f);

    // If both are ints, do integer multiplication
    if (a_is_int && b_is_int) {
        return eco_alloc_int(a_i * b_i);
    }

    // At least one is a float - convert to float arithmetic
    Elm::f64 a_val = a_is_int ? static_cast<Elm::f64>(a_i) : a_f;
    Elm::f64 b_val = b_is_int ? static_cast<Elm::f64>(b_i) : b_f;
    return eco_alloc_float(a_val * b_val);
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
