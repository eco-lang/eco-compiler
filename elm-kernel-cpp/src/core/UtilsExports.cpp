//===- UtilsExports.cpp - C-linkage exports for Utils module ---------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "Utils.hpp"
#include "allocator/StringOps.hpp"

using namespace Elm;
using namespace Elm::Kernel;

extern "C" {

HPtr Elm_Kernel_Utils_compare(HPtr a, HPtr b) {
    HPointer result = Utils::compare(Export::toPtr(a.toBits()), Export::toPtr(b.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

// Order-free sibling of Elm_Kernel_Utils_compare, emitted by the compare-case
// rewrite (EcoCompareCaseRewrite) for residual boxed keys. NOT gc-leaf: the
// generic `cmp` recurses over arbitrary heap shapes, and every kernel extern is
// deliberately poison for gc-free propagation (CGEN_072).
//
// RETURN-WIDTH TRAP: this MUST be defined returning int64_t so the widening is
// the C++ int->int64_t return conversion (sign-extending). Defining it `int`
// under an i64 MLIR/LLVM declaration leaves RAX's upper 32 bits undefined on
// SysV x86-64, and the i64 sign tests then read garbage.
int64_t Elm_Kernel_Utils_cmp3(HPtr a, HPtr b) {
    return Utils::cmp3(Export::toPtr(a.toBits()), Export::toPtr(b.toBits()));
}

// String three-way compare: the sign of StringOps::compare, UNCLAMPED.
// gc-leaf-safe — StringOps::compare never allocates on the GC heap on any of
// its four paths (leaf charCompare / both-UTF-8 memcmp / single-segment view /
// general lockstep, whose only scratch is a C++-heap std::vector).
// Lives here, not in RuntimeExports, because Export::toPtr's full resolution
// (embedded-constant -> nullptr; isInHeap -> resolveFast; else raw non-heap
// pointer for rodata literals) is required for parity with the kernel path,
// and RuntimeExports' local hpointerToPtr is NOT equivalent.
// Same return-width trap as above.
int64_t eco_string_cmp3(HPtr a, HPtr b) {
    void* pa = Export::toPtr(a.toBits());
    void* pb = Export::toPtr(b.toBits());
    if (pa == pb) return 0;  // includes both-Empty (both nullptr)
    if (!pa) return -1;      // empty < non-empty
    if (!pb) return 1;
    return StringOps::compare(pa, pb);
}

// Phase C: pick an Order singleton from an UNCLAMPED sign in ONE gc-leaf call,
// replacing the three unconditional Eco_Runtime_getOrder* calls (plus two
// selects) that emitOrderSelect used to emit per cmp_order execution.
HPtr eco_order_from_sign(int64_t sign) {
    uint64_t enc = (sign < 0) ? Utils::getOrderLT()
                 : (sign > 0) ? Utils::getOrderGT()
                              : Utils::getOrderEQ();
    return HPtr::fromBits(enc);
}

// One-call replacement for the three getOrder calls: sign + singleton pick.
HPtr eco_string_cmp_order(HPtr a, HPtr b) {
    return eco_order_from_sign(eco_string_cmp3(a, b));
}

// Phase B per-instance variants. Each takes the corresponding primitive ABI
// type (int64_t / double / uint16_t) directly and returns the encoded HPtr
// of the appropriate Order singleton.
HPtr Elm_Kernel_Utils_compare_Int(int64_t a, int64_t b) {
    uint64_t enc = (a < b) ? Utils::getOrderLT()
                 : (a > b) ? Utils::getOrderGT()
                           : Utils::getOrderEQ();
    return HPtr::fromBits(enc);
}

HPtr Elm_Kernel_Utils_compare_Float(double a, double b) {
    uint64_t enc = (a < b) ? Utils::getOrderLT()
                 : (a > b) ? Utils::getOrderGT()
                           : Utils::getOrderEQ();
    return HPtr::fromBits(enc);
}

HPtr Elm_Kernel_Utils_compare_Char(uint16_t a, uint16_t b) {
    uint64_t enc = (a < b) ? Utils::getOrderLT()
                 : (a > b) ? Utils::getOrderGT()
                           : Utils::getOrderEQ();
    return HPtr::fromBits(enc);
}

// Structural equality on embedded constants (True/False/Nil/Unit/etc.) must be
// resolved by HPointer constant-field, not by passing them through toPtr().
// toPtr() collapses every embedded constant to nullptr, so without this guard
// Utils::eqHelp would short-circuit via `if (a == b) return true;` and report
// any two distinct constants as equal — in particular True == False == true,
// which silently corrupts every Bool-pattern match in the compiler.
static bool equalRespectingConstants(uint64_t aBits, uint64_t bBits) {
    // Embedded constants are canonical words: two constants are equal iff their
    // words are equal (True==True, Empty==Empty, …), and a constant is never
    // equal to a heap pointer. Elm's type system forbids comparing values of
    // different types, so a merged empty can only ever be compared against the
    // same-type empty — a whole-word compare is correct under both the legacy
    // and the merged representations (plan D6/P0.6).
    if (isConstantBits(aBits) || isConstantBits(bBits)) {
        return aBits == bBits;
    }
    return Utils::equal(Export::toPtr(aBits), Export::toPtr(bBits));
}

HPtr Elm_Kernel_Utils_equal(HPtr a, HPtr b) {
    return HPtr::fromBits(Export::encodeBoxedBool(equalRespectingConstants(a.toBits(), b.toBits())));
}

HPtr Elm_Kernel_Utils_notEqual(HPtr a, HPtr b) {
    return HPtr::fromBits(Export::encodeBoxedBool(!equalRespectingConstants(a.toBits(), b.toBits())));
}

HPtr Elm_Kernel_Utils_lt(HPtr a, HPtr b) {
    return HPtr::fromBits(Export::encodeBoxedBool(Utils::lt(Export::toPtr(a.toBits()), Export::toPtr(b.toBits()))));
}

HPtr Elm_Kernel_Utils_le(HPtr a, HPtr b) {
    return HPtr::fromBits(Export::encodeBoxedBool(Utils::le(Export::toPtr(a.toBits()), Export::toPtr(b.toBits()))));
}

HPtr Elm_Kernel_Utils_gt(HPtr a, HPtr b) {
    return HPtr::fromBits(Export::encodeBoxedBool(Utils::gt(Export::toPtr(a.toBits()), Export::toPtr(b.toBits()))));
}

HPtr Elm_Kernel_Utils_ge(HPtr a, HPtr b) {
    return HPtr::fromBits(Export::encodeBoxedBool(Utils::ge(Export::toPtr(a.toBits()), Export::toPtr(b.toBits()))));
}

// Phase C per-instance variants for equality and ordering on primitives.
// Each takes the corresponding primitive ABI type directly and returns the
// boxed Bool (HPtr to the True / False singleton). C operators give the
// correct semantics: IEEE 754 comparison for Float (NaN-aware), unsigned
// comparison for Char (Unicode code point).
HPtr Elm_Kernel_Utils_equal_Int   (int64_t  a, int64_t  b) { return HPtr::fromBits(Export::encodeBoxedBool(a == b)); }
HPtr Elm_Kernel_Utils_equal_Float (double   a, double   b) { return HPtr::fromBits(Export::encodeBoxedBool(a == b)); }
HPtr Elm_Kernel_Utils_equal_Char  (uint16_t a, uint16_t b) { return HPtr::fromBits(Export::encodeBoxedBool(a == b)); }

HPtr Elm_Kernel_Utils_notEqual_Int  (int64_t  a, int64_t  b) { return HPtr::fromBits(Export::encodeBoxedBool(a != b)); }
HPtr Elm_Kernel_Utils_notEqual_Float(double   a, double   b) { return HPtr::fromBits(Export::encodeBoxedBool(a != b)); }
HPtr Elm_Kernel_Utils_notEqual_Char (uint16_t a, uint16_t b) { return HPtr::fromBits(Export::encodeBoxedBool(a != b)); }

HPtr Elm_Kernel_Utils_lt_Int  (int64_t  a, int64_t  b) { return HPtr::fromBits(Export::encodeBoxedBool(a < b)); }
HPtr Elm_Kernel_Utils_lt_Float(double   a, double   b) { return HPtr::fromBits(Export::encodeBoxedBool(a < b)); }
HPtr Elm_Kernel_Utils_lt_Char (uint16_t a, uint16_t b) { return HPtr::fromBits(Export::encodeBoxedBool(a < b)); }

HPtr Elm_Kernel_Utils_le_Int  (int64_t  a, int64_t  b) { return HPtr::fromBits(Export::encodeBoxedBool(a <= b)); }
HPtr Elm_Kernel_Utils_le_Float(double   a, double   b) { return HPtr::fromBits(Export::encodeBoxedBool(a <= b)); }
HPtr Elm_Kernel_Utils_le_Char (uint16_t a, uint16_t b) { return HPtr::fromBits(Export::encodeBoxedBool(a <= b)); }

HPtr Elm_Kernel_Utils_gt_Int  (int64_t  a, int64_t  b) { return HPtr::fromBits(Export::encodeBoxedBool(a > b)); }
HPtr Elm_Kernel_Utils_gt_Float(double   a, double   b) { return HPtr::fromBits(Export::encodeBoxedBool(a > b)); }
HPtr Elm_Kernel_Utils_gt_Char (uint16_t a, uint16_t b) { return HPtr::fromBits(Export::encodeBoxedBool(a > b)); }

HPtr Elm_Kernel_Utils_ge_Int  (int64_t  a, int64_t  b) { return HPtr::fromBits(Export::encodeBoxedBool(a >= b)); }
HPtr Elm_Kernel_Utils_ge_Float(double   a, double   b) { return HPtr::fromBits(Export::encodeBoxedBool(a >= b)); }
HPtr Elm_Kernel_Utils_ge_Char (uint16_t a, uint16_t b) { return HPtr::fromBits(Export::encodeBoxedBool(a >= b)); }

HPtr Elm_Kernel_Utils_append(HPtr a, HPtr b) {
    uint64_t a_bits = a.toBits();
    uint64_t b_bits = b.toBits();
    void* ptrA = Export::toPtr(a_bits);
    void* ptrB = Export::toPtr(b_bits);
    // Both are embedded constants (e.g. "" ++ "" or [] ++ []).
    // toPtr returns nullptr for embedded constants, so return either one directly.
    if (!ptrA && !ptrB) return a;
    HPointer result = Utils::append(ptrA, ptrB);
    return HPtr::fromBits(Export::encode(result));
}

// ============================================================================
// Order Singletons
// ============================================================================
//
// Three pre-allocated Order Custom values shared by every primitive `compare`
// call. The encoded HPointer slots are registered as value roots so the GC
// updates them in place if the underlying object moves; the lowering for
// eco.{int,float,char}.cmp_order calls these helpers and treats the return
// value as a regular Elm value.

HPtr Eco_Runtime_getOrderLT() { return HPtr::fromBits(Utils::getOrderLT()); }
HPtr Eco_Runtime_getOrderEQ() { return HPtr::fromBits(Utils::getOrderEQ()); }
HPtr Eco_Runtime_getOrderGT() { return HPtr::fromBits(Utils::getOrderGT()); }

void Eco_Kernel_Order_register_gc_roots() {
    Utils::initOrderSingletons();
}

} // extern "C"
