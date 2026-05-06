//===- UtilsExports.cpp - C-linkage exports for Utils module ---------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "Utils.hpp"

using namespace Elm;
using namespace Elm::Kernel;

extern "C" {

HPtr Elm_Kernel_Utils_compare(HPtr a, HPtr b) {
    HPointer result = Utils::compare(Export::toPtr(a.toBits()), Export::toPtr(b.toBits()));
    return HPtr::fromBits(Export::encode(result));
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

HPtr Elm_Kernel_Utils_equal(HPtr a, HPtr b) {
    return HPtr::fromBits(Export::encodeBoxedBool(Utils::equal(Export::toPtr(a.toBits()), Export::toPtr(b.toBits()))));
}

HPtr Elm_Kernel_Utils_notEqual(HPtr a, HPtr b) {
    return HPtr::fromBits(Export::encodeBoxedBool(Utils::notEqual(Export::toPtr(a.toBits()), Export::toPtr(b.toBits()))));
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
