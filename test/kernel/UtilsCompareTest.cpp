// Unit tests of the Utils kernel's ordering (elm-kernel-cpp/src/core/Utils.cpp) on mixed slot layouts.
//
//   mixed-float-list-heads (UTILS-02): `compareListElem` (now `compareMixedSlot`) ordered a boxed Float against
//   an unboxed Float with the raw `<` / `==`, not `compareFloat` (NaN equal to NaN and above every number). So
//   mixed `[1.0]` vs `[NaN]` was GT and mixed `[NaN]` vs `[NaN]` was GT, while the same lists with both heads
//   unboxed are LT and EQ.
//
//   mixed-tuple-slot (UTILS-03): `cmp` on a Tuple2/Tuple3 whose slot is boxed on one side and unboxed on the
//   other ordered by slot KIND (0 < 1) instead of by value, while `equal` (`eqUnboxableSlot`) compares the
//   values: `(1, 7)` with slot 0 unboxed equals `(1, 7)` with slot 0 boxed, but compared GT to it.
//
// Compiled Elm never builds these mixed layouts (REP_HEAP_001 / MONO_029 fix a slot's kind by its type), so
// the defects are reachable only from hand-built values; that is what these tests do. They allocate a handful
// of small objects and root what they hold across each allocation. The E2E programs of the same area are
// test/elm-conformance/src/DeepEqualityTest.elm and test/elm/src/FunctionEqualityFalseTest.elm.

#include "UtilsCompareTest.hpp"

#include "../TestSuite.hpp"
#include "../allocator/TestHelpers.hpp"

#include "../../elm-kernel-cpp/src/ExportHelpers.hpp"
#include "../../elm-kernel-cpp/src/KernelExports.h"
#include "../../runtime/src/allocator/Allocator.hpp"
#include "../../runtime/src/allocator/Heap.hpp"
#include "../../runtime/src/allocator/HeapHelpers.hpp"

#include <cmath>
#include <limits>
#include <string>

namespace {

using namespace Elm;
using namespace Elm::TestHelpers;
namespace Ex = Elm::Kernel::Export;

const char* orderName(HPtr o) {
    const uint64_t b = o.toBits();
    if (b == Eco_Runtime_getOrderLT().toBits()) return "LT";
    if (b == Eco_Runtime_getOrderEQ().toBits()) return "EQ";
    if (b == Eco_Runtime_getOrderGT().toBits()) return "GT";
    return "?";
}

std::string ord(HPtr a, HPtr b) { return orderName(Elm_Kernel_Utils_compare(a, b)); }

std::string signName(int64_t s) { return s < 0 ? "LT" : s > 0 ? "GT" : "EQ"; }

std::string ord3(HPtr a, HPtr b) { return signName(Elm_Kernel_Utils_cmp3(a, b)); }

bool isTrue(HPtr b) { return Ex::decodeBoxedBool(b.toBits()); }

HPtr hp(HPointer p) { return HPtr::fromHPointer(p); }

// A one-element Float list with an unboxed head (slot kind 2).
HPointer unboxedFloatList(f64 v) { return alloc::cons(alloc::unboxedFloat(v), alloc::listNil(), static_cast<u8>(2)); }

// A one-element Float list with a boxed head (slot kind 0). `cons` roots the boxed head itself.
HPointer boxedFloatList(f64 v) {
    HPointer f = alloc::allocFloat(v);
    return alloc::cons(alloc::boxed(f), alloc::listNil(), static_cast<u8>(0));
}

// UTILS-02: mixed boxed/unboxed Float list heads must order like two unboxed heads.
void testMixedFloatListCompare() {
    initAllocator();
    const f64 nan = std::numeric_limits<f64>::quiet_NaN();

    HPointer u1 = unboxedFloatList(1.0);
    HPointer uNan = unboxedFloatList(nan);
    HPointer uNan2 = unboxedFloatList(nan);
    HPointer bNan = alloc::listNil();
    HPointer bNan2 = alloc::listNil();
    StackRootGuard g1(&u1, &uNan, &uNan2);
    StackRootGuard g2(&bNan, &bNan2);
    bNan = boxedFloatList(nan);
    bNan2 = boxedFloatList(nan);

    // Precondition: the reference (both heads unboxed) uses compareFloat's total order.
    TEST_ASSERT(ord(hp(u1), hp(uNan)) == "LT");
    TEST_ASSERT(ord(hp(uNan), hp(uNan2)) == "EQ");
    // And the lists really have the mixed layout.
    TEST_ASSERT(alloc::getTag(Ex::toPtr(hp(bNan).toBits())) == Tag_Cons);

    const std::string m1 = ord(hp(u1), hp(bNan));        // want LT
    const std::string m2 = ord(hp(bNan), hp(u1));        // want GT
    const std::string m3 = ord(hp(uNan), hp(bNan));      // want EQ
    const std::string m4 = ord(hp(bNan2), hp(uNan));     // want EQ
    const std::string c1 = ord3(hp(u1), hp(bNan));       // want LT
    const std::string c3 = ord3(hp(uNan), hp(bNan));     // want EQ

    const bool defect = m1 != "LT" || m2 != "GT" || m3 != "EQ" || m4 != "EQ" || c1 != "LT" || c3 != "EQ";
    if (defect) {
        TEST_FAIL("UTILS-02: compare [1.0](unboxed) [NaN](boxed) = " + m1 + " (want LT), reversed = " + m2 +
                           " (want GT), [NaN](unboxed) vs [NaN](boxed) = " + m3 + " / " + m4 +
                  " (want EQ), cmp3 = " + c1 + " / " + c3 + " (want LT / EQ)");
    }
}

// UTILS-03: a tuple slot boxed on one side and unboxed on the other must order by value, as `==`
// already compares it.
void testMixedTupleSlotCompare() {
    initAllocator();

    // Tuple2: slot 0 Int (unboxed kind 1 or boxed kind 0), slot 1 unboxed Int (kind 1, bits 2..3).
    HPointer t1 = alloc::tuple2(alloc::unboxedInt(1), alloc::unboxedInt(7), 0x5);
    HPointer t2 = alloc::listNil();
    HPointer t3 = alloc::listNil();
    StackRootGuard g1(&t1, &t2, &t3);
    {
        HPointer one = alloc::allocInt(1);
        t2 = alloc::tuple2(alloc::boxed(one), alloc::unboxedInt(7), 0x4);
        HPointer two = alloc::allocInt(2);
        t3 = alloc::tuple2(alloc::boxed(two), alloc::unboxedInt(7), 0x4);
    }

    // Tuple3: slots Int (kind 1), Char (kind 3), then slot 2 a Float or a Char, unboxed or boxed.
    const u32 base = 1u | (3u << 2);
    HPointer f1 = alloc::tuple3(alloc::unboxedInt(1), alloc::unboxedChar('x'), alloc::unboxedFloat(2.5),
                                base | (2u << 4));
    HPointer f2 = alloc::listNil();
    HPointer c1 = alloc::listNil();
    HPointer c2 = alloc::listNil();
    StackRootGuard g2(&f1, &f2, &c1, &c2);
    {
        HPointer bf = alloc::allocFloat(2.5);
        f2 = alloc::tuple3(alloc::unboxedInt(1), alloc::unboxedChar('x'), alloc::boxed(bf), base);
        c1 = alloc::tuple3(alloc::unboxedInt(1), alloc::unboxedChar('x'), alloc::unboxedChar('q'),
                           base | (3u << 4));
        HPointer bc = alloc::allocChar('q');
        c2 = alloc::tuple3(alloc::unboxedInt(1), alloc::unboxedChar('x'), alloc::boxed(bc), base);
    }

    // Precondition: `==` already treats the mixed slots as equal values.
    TEST_ASSERT(isTrue(Elm_Kernel_Utils_equal(hp(t1), hp(t2))));
    TEST_ASSERT(isTrue(Elm_Kernel_Utils_equal(hp(f1), hp(f2))));
    TEST_ASSERT(isTrue(Elm_Kernel_Utils_equal(hp(c1), hp(c2))));
    TEST_ASSERT(!isTrue(Elm_Kernel_Utils_equal(hp(t1), hp(t3))));

    const std::string a = ord(hp(t1), hp(t2));   // want EQ
    const std::string b = ord(hp(t1), hp(t3));   // want LT
    const std::string c = ord(hp(t3), hp(t1));   // want GT
    const std::string d = ord(hp(f1), hp(f2));   // want EQ
    const std::string e = ord(hp(c2), hp(c1));   // want EQ
    const std::string a3 = ord3(hp(t1), hp(t2)); // want EQ
    const std::string b3 = ord3(hp(t1), hp(t3)); // want LT

    const bool defect = a != "EQ" || b != "LT" || c != "GT" || d != "EQ" || e != "EQ" || a3 != "EQ" ||
                        b3 != "LT";
    if (defect) {
        TEST_FAIL("UTILS-03: compare (1u,7) (1b,7) = " + a + " (want EQ, == says True), (1u,7) vs (2b,7) = " + b +
                           " (want LT), reversed = " + c + " (want GT), Tuple3 Float slot = " + d +
                           " (want EQ), Tuple3 Char slot = " + e + " (want EQ), cmp3 = " + a3 + " / " + b3 +
                  " (want EQ / LT)");
    }
}

}  // namespace

void registerUtilsCompareTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite) {
    // Both initialize the allocator, so they run in their own process.
    suite.add(Testing::TestCase("utils-compare/mixed-float-list-heads-order-by-compare-float",
                                testMixedFloatListCompare));
    suite.add(Testing::TestCase("utils-compare/mixed-tuple-slot-orders-by-value-as-equal-does",
                                testMixedTupleSlotCompare));
}
