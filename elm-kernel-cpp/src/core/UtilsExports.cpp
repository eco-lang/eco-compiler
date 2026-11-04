//===- UtilsExports.cpp - C-linkage exports for Utils module ---------------===//
//
// The `extern "C"` wrappers for `Utils.hpp`, declared in `KernelExports.h`, together with the variants
// that take Int, Float or Char raw and the typed String and List entry points the compiler's lowering
// calls. They convert words with `Export::toPtr`, which turns every embedded constant into a null
// pointer, so any export whose result depends on telling two constants apart decides that on the words.
//
// The back end may treat an export as a gc-leaf call, one that allocates nothing on the GC heap and so
// needs no statepoint. Where it matters, a note below says whether an export may be treated so.
//
//===----------------------------------------------------------------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "Utils.hpp"
#include "allocator/StringOps.hpp"
#include "allocator/ListOps.hpp"

using namespace Elm;
using namespace Elm::Kernel;

extern "C" {

HPtr Elm_Kernel_Utils_compare(HPtr a, HPtr b) {
    HPointer result = Utils::compare(Export::toPtr(a.toBits()), Export::toPtr(b.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

// Not gc-leaf, although `Utils::cmp3` allocates nothing: the back end treats every kernel export as
// possibly allocating unless it is listed as gc-leaf.
//
// The return type must stay `int64_t`. The caller declares the result as a 64-bit integer, and returning
// `int` would leave the upper 32 bits of the return register undefined on SysV x86-64; `int64_t` makes
// the widening the C++ conversion, which sign-extends.
int64_t Elm_Kernel_Utils_cmp3(HPtr a, HPtr b) {
    return Utils::cmp3(Export::toPtr(a.toBits()), Export::toPtr(b.toBits()));
}

// May be treated as gc-leaf: `StringOps::compare` allocates nothing on the GC heap. Defined here rather
// than beside the runtime exports so that it converts words with `Export::toPtr`, as the polymorphic
// path does; the runtime exports' own helper resolves every non-constant word with `Allocator::resolve`
// instead. The return type must stay `int64_t`, as for the export above.
int64_t eco_string_cmp3(HPtr a, HPtr b) {
    void* pa = Export::toPtr(a.toBits());
    void* pb = Export::toPtr(b.toBits());
    // Two nulls are both "", the only String constant.
    if (pa == pb) return 0;
    if (!pa) return alloc::isZeroLengthString(pb) ? 0 : -1;
    if (!pb) return alloc::isZeroLengthString(pa) ? 0 : 1;
    return StringOps::compare(pa, pb);
}

HPtr eco_order_from_sign(int64_t sign) {
    uint64_t enc = (sign < 0) ? Utils::getOrderLT()
                 : (sign > 0) ? Utils::getOrderGT()
                              : Utils::getOrderEQ();
    return HPtr::fromBits(enc);
}

HPtr eco_string_cmp_order(HPtr a, HPtr b) {
    return eco_order_from_sign(eco_string_cmp3(a, b));
}

HPtr Elm_Kernel_Utils_compare_Int(int64_t a, int64_t b) {
    uint64_t enc = (a < b) ? Utils::getOrderLT()
                 : (a > b) ? Utils::getOrderGT()
                           : Utils::getOrderEQ();
    return HPtr::fromBits(enc);
}

// Uses `Utils::compareFloat`'s total order, unlike the Float `lt`/`gt` variants below, which are IEEE.
HPtr Elm_Kernel_Utils_compare_Float(double a, double b) {
    const int c = Utils::compareFloat(a, b);
    uint64_t enc = (c < 0)  ? Utils::getOrderLT()
                 : (c == 0) ? Utils::getOrderEQ()
                            : Utils::getOrderGT();
    return HPtr::fromBits(enc);
}

// Chars arrive as `uint64_t` because the caller does not promise to zero-extend them, so only the low 32
// bits are read. They compare in code-point order.
HPtr Elm_Kernel_Utils_compare_Char(uint64_t a_raw, uint64_t b_raw) {
    const uint32_t a = static_cast<uint32_t>(a_raw & 0xFFFFFFFFu);
    const uint32_t b = static_cast<uint32_t>(b_raw & 0xFFFFFFFFu);
    const int c = a < b ? -1 : (a > b ? 1 : 0);
    uint64_t enc = (c < 0) ? Utils::getOrderLT()
                 : (c > 0) ? Utils::getOrderGT()
                           : Utils::getOrderEQ();
    return HPtr::fromBits(enc);
}

/// Returns whether the words `aBits` and `bBits` are equal Elm values.
///
/// When either is an embedded constant the words decide: two constants are equal when their words are,
/// and a constant is unequal to a heap value except that the Empty constant equals a String of length 0.
/// Otherwise the result is `Utils::equal` on the two objects. The words must be tested first because
/// `Export::toPtr` turns every constant into null, and `Utils::equal` reports two nulls equal, which
/// would make True equal False.
static bool equalRespectingConstants(uint64_t aBits, uint64_t bBits) {
    // A whole-word test is enough because Elm compares only values of one type, and one type never has two
    // different constants with the same word.
    const bool aConst = isConstantBits(aBits);
    const bool bConst = isConstantBits(bBits);
    if (aConst || bConst) {
        if (aBits == bBits) return true;
        if (aConst == bConst) return false;
        return isEmptyBits(aConst ? aBits : bBits) &&
               alloc::isZeroLengthString(Export::toPtr(aConst ? bBits : aBits));
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

// The C++ operators give Elm's results: IEEE 754 comparison for Floats, so a NaN is unequal to itself and
// orders with nothing, and code-point order on the low 32 bits for Chars. Each returns True or False.
HPtr Elm_Kernel_Utils_equal_Int   (int64_t  a, int64_t  b) { return HPtr::fromBits(Export::encodeBoxedBool(a == b)); }
HPtr Elm_Kernel_Utils_equal_Float (double   a, double   b) { return HPtr::fromBits(Export::encodeBoxedBool(a == b)); }
HPtr Elm_Kernel_Utils_equal_Char  (uint64_t a, uint64_t b) { return HPtr::fromBits(Export::encodeBoxedBool((a & 0xFFFFFFFFu) == (b & 0xFFFFFFFFu))); }

HPtr Elm_Kernel_Utils_notEqual_Int  (int64_t  a, int64_t  b) { return HPtr::fromBits(Export::encodeBoxedBool(a != b)); }
HPtr Elm_Kernel_Utils_notEqual_Float(double   a, double   b) { return HPtr::fromBits(Export::encodeBoxedBool(a != b)); }
HPtr Elm_Kernel_Utils_notEqual_Char (uint64_t a, uint64_t b) { return HPtr::fromBits(Export::encodeBoxedBool((a & 0xFFFFFFFFu) != (b & 0xFFFFFFFFu))); }

HPtr Elm_Kernel_Utils_lt_Int  (int64_t  a, int64_t  b) { return HPtr::fromBits(Export::encodeBoxedBool(a < b)); }
HPtr Elm_Kernel_Utils_lt_Float(double   a, double   b) { return HPtr::fromBits(Export::encodeBoxedBool(a < b)); }
HPtr Elm_Kernel_Utils_lt_Char (uint64_t a, uint64_t b) { return HPtr::fromBits(Export::encodeBoxedBool((a & 0xFFFFFFFFu) < (b & 0xFFFFFFFFu))); }

HPtr Elm_Kernel_Utils_le_Int  (int64_t  a, int64_t  b) { return HPtr::fromBits(Export::encodeBoxedBool(a <= b)); }
HPtr Elm_Kernel_Utils_le_Float(double   a, double   b) { return HPtr::fromBits(Export::encodeBoxedBool(a <= b)); }
HPtr Elm_Kernel_Utils_le_Char (uint64_t a, uint64_t b) { return HPtr::fromBits(Export::encodeBoxedBool((a & 0xFFFFFFFFu) <= (b & 0xFFFFFFFFu))); }

HPtr Elm_Kernel_Utils_gt_Int  (int64_t  a, int64_t  b) { return HPtr::fromBits(Export::encodeBoxedBool(a > b)); }
HPtr Elm_Kernel_Utils_gt_Float(double   a, double   b) { return HPtr::fromBits(Export::encodeBoxedBool(a > b)); }
HPtr Elm_Kernel_Utils_gt_Char (uint64_t a, uint64_t b) { return HPtr::fromBits(Export::encodeBoxedBool((a & 0xFFFFFFFFu) > (b & 0xFFFFFFFFu))); }

HPtr Elm_Kernel_Utils_ge_Int  (int64_t  a, int64_t  b) { return HPtr::fromBits(Export::encodeBoxedBool(a >= b)); }
HPtr Elm_Kernel_Utils_ge_Float(double   a, double   b) { return HPtr::fromBits(Export::encodeBoxedBool(a >= b)); }
HPtr Elm_Kernel_Utils_ge_Char (uint64_t a, uint64_t b) { return HPtr::fromBits(Export::encodeBoxedBool((a & 0xFFFFFFFFu) >= (b & 0xFFFFFFFFu))); }

HPtr Elm_Kernel_Utils_append(HPtr a, HPtr b) {
    uint64_t a_bits = a.toBits();
    uint64_t b_bits = b.toBits();
    void* ptrA = Export::toPtr(a_bits);
    void* ptrB = Export::toPtr(b_bits);
    // Both empty: either word will do.
    if (!ptrA && !ptrB) return a;
    HPointer result = Utils::append(ptrA, ptrB);
    return HPtr::fromBits(Export::encode(result));
}

// These reach the same `StringOps::append` and `ListOps::append` as `Utils::append`, so either operand may
// be in any String form or any list spine form. Not gc-leaf: both may allocate. Neither wrapper
// allocates before that call, so there is nothing for it to root; the callee roots what it needs across
// its own allocations.
HPtr eco_string_append(HPtr a, HPtr b) {
    void* pa = Export::toPtr(a.toBits());
    void* pb = Export::toPtr(b.toBits());
    if (!pa && !pb) return a;
    HPointer result = StringOps::append(pa, pb);
    return HPtr::fromBits(Export::encode(result));
}

HPtr eco_list_append(HPtr a, HPtr b) {
    void* pa = Export::toPtr(a.toBits());
    void* pb = Export::toPtr(b.toBits());
    // `[]` is the Empty constant, which `toPtr` turns into null.
    if (!pa) return b;
    if (!pb) return a;
    auto& allocator = Allocator::instance();
    // Nothing allocates between the two wraps. `pa` and `pb` must not be used after `ListOps::append`,
    // which may move the objects.
    HPointer la = allocator.wrap(pa);
    HPointer lb = allocator.wrap(pb);
    HPointer result = ListOps::append(la, lb);
    return HPtr::fromBits(Export::encode(result));
}

// ============================================================================
// Order Constants
// ============================================================================

HPtr Eco_Runtime_getOrderLT() { return HPtr::fromBits(Utils::getOrderLT()); }
HPtr Eco_Runtime_getOrderEQ() { return HPtr::fromBits(Utils::getOrderEQ()); }
HPtr Eco_Runtime_getOrderGT() { return HPtr::fromBits(Utils::getOrderGT()); }

void Eco_Kernel_Order_register_gc_roots() {
    Utils::initOrderSingletons();
}

} // extern "C"
