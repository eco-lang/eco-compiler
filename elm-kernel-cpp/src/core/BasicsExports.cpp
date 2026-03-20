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

// Helper to reinterpret HPointer as uint64_t.
inline uint64_t fromHPointer(Elm::HPointer ptr) {
    uint64_t val;
    memcpy(&val, &ptr, sizeof(val));
    return val;
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

// Helper to box an integer result.
// Returns HPointer for consistency with JIT's eco_alloc_int.
inline uint64_t boxInt(Elm::i64 val) {
    void* obj = Elm::Allocator::instance().allocate(sizeof(Elm::ElmInt), Elm::Tag_Int);
    Elm::ElmInt* intObj = static_cast<Elm::ElmInt*>(obj);
    intObj->value = val;
    Elm::HPointer hp = Elm::Allocator::instance().wrap(obj);
    return fromHPointer(hp);
}

// Helper to box a float result.
// Returns HPointer for consistency with JIT's eco_alloc_float.
inline uint64_t boxFloat(Elm::f64 val) {
    void* obj = Elm::Allocator::instance().allocate(sizeof(Elm::ElmFloat), Elm::Tag_Float);
    Elm::ElmFloat* floatObj = static_cast<Elm::ElmFloat*>(obj);
    floatObj->value = val;
    Elm::HPointer hp = Elm::Allocator::instance().wrap(obj);
    return fromHPointer(hp);
}

} // anonymous namespace

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
uint64_t Elm_Kernel_Basics_pow(uint64_t base_ptr, uint64_t exp_ptr) {
    Elm::i64 base_i, exp_i;
    Elm::f64 base_f, exp_f;
    bool base_is_int = getNumericValue(base_ptr, base_i, base_f);
    bool exp_is_int = getNumericValue(exp_ptr, exp_i, exp_f);

    // If both are ints, do integer power
    if (base_is_int && exp_is_int) {
        // Integer power - use repeated multiplication for positive exponents
        if (exp_i < 0) {
            // Negative exponent with ints -> result is 0 (integer division)
            return boxInt(0);
        }
        Elm::i64 result = 1;
        Elm::i64 b = base_i;
        Elm::i64 e = exp_i;
        while (e > 0) {
            if (e & 1) result *= b;
            b *= b;
            e >>= 1;
        }
        return boxInt(result);
    }

    // At least one is a float - convert to float arithmetic
    Elm::f64 base_val = base_is_int ? static_cast<Elm::f64>(base_i) : base_f;
    Elm::f64 exp_val = exp_is_int ? static_cast<Elm::f64>(exp_i) : exp_f;
    return boxFloat(std::pow(base_val, exp_val));
}

// Polymorphic add - examines tags to determine Int or Float arithmetic.
uint64_t Elm_Kernel_Basics_add(uint64_t a_ptr, uint64_t b_ptr) {
    Elm::i64 a_i, b_i;
    Elm::f64 a_f, b_f;
    bool a_is_int = getNumericValue(a_ptr, a_i, a_f);
    bool b_is_int = getNumericValue(b_ptr, b_i, b_f);

    // If both are ints, do integer addition
    if (a_is_int && b_is_int) {
        return boxInt(a_i + b_i);
    }

    // At least one is a float - convert to float arithmetic
    Elm::f64 a_val = a_is_int ? static_cast<Elm::f64>(a_i) : a_f;
    Elm::f64 b_val = b_is_int ? static_cast<Elm::f64>(b_i) : b_f;
    return boxFloat(a_val + b_val);
}

// Polymorphic sub - examines tags to determine Int or Float arithmetic.
uint64_t Elm_Kernel_Basics_sub(uint64_t a_ptr, uint64_t b_ptr) {
    Elm::i64 a_i, b_i;
    Elm::f64 a_f, b_f;
    bool a_is_int = getNumericValue(a_ptr, a_i, a_f);
    bool b_is_int = getNumericValue(b_ptr, b_i, b_f);

    // If both are ints, do integer subtraction
    if (a_is_int && b_is_int) {
        return boxInt(a_i - b_i);
    }

    // At least one is a float - convert to float arithmetic
    Elm::f64 a_val = a_is_int ? static_cast<Elm::f64>(a_i) : a_f;
    Elm::f64 b_val = b_is_int ? static_cast<Elm::f64>(b_i) : b_f;
    return boxFloat(a_val - b_val);
}

// Polymorphic mul - examines tags to determine Int or Float arithmetic.
uint64_t Elm_Kernel_Basics_mul(uint64_t a_ptr, uint64_t b_ptr) {
    Elm::i64 a_i, b_i;
    Elm::f64 a_f, b_f;
    bool a_is_int = getNumericValue(a_ptr, a_i, a_f);
    bool b_is_int = getNumericValue(b_ptr, b_i, b_f);

    // If both are ints, do integer multiplication
    if (a_is_int && b_is_int) {
        return boxInt(a_i * b_i);
    }

    // At least one is a float - convert to float arithmetic
    Elm::f64 a_val = a_is_int ? static_cast<Elm::f64>(a_i) : a_f;
    Elm::f64 b_val = b_is_int ? static_cast<Elm::f64>(b_i) : b_f;
    return boxFloat(a_val * b_val);
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

uint64_t Elm_Kernel_Basics_isInfinite(double x) {
    return Export::encodeBoxedBool(Basics::isInfinite(x));
}

uint64_t Elm_Kernel_Basics_isNaN(double x) {
    return Export::encodeBoxedBool(Basics::isNaN(x));
}

uint64_t Elm_Kernel_Basics_and(uint64_t a, uint64_t b) {
    return Export::encodeBoxedBool(Basics::and_(Export::decodeBoxedBool(a), Export::decodeBoxedBool(b)));
}

uint64_t Elm_Kernel_Basics_or(uint64_t a, uint64_t b) {
    return Export::encodeBoxedBool(Basics::or_(Export::decodeBoxedBool(a), Export::decodeBoxedBool(b)));
}

uint64_t Elm_Kernel_Basics_xor(uint64_t a, uint64_t b) {
    return Export::encodeBoxedBool(Basics::xor_(Export::decodeBoxedBool(a), Export::decodeBoxedBool(b)));
}

uint64_t Elm_Kernel_Basics_not(uint64_t a) {
    return Export::encodeBoxedBool(Basics::not_(Export::decodeBoxedBool(a)));
}

} // extern "C"
