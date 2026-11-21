// Unit tests of the JsArray kernel entry points (elm-kernel-cpp/src/core/JsArrayExports.cpp), called directly.
// The compiler never reaches the boxed `unsafeSet`/`push` roots with a primitive array, and elm/core masks every
// index to 0..31, so no Elm program can show the first three; `push_int` into a boxed array also has an E2E
// trigger (test/elm-conformance/src/ArrayMapDebugLogKindTest.elm, ARRAY-NEW-1). Each case asserts the fixed
// behaviour; before the fixes:
//
//   wide-index (ARRAY-01)       unsafeSet/unsafeGet checked the index on its low 32 bits only: (2^32 + 1) passed
//                               the range check against length 2, so the store landed 32 GiB past the array and
//                               the get returned element 1.
//   boxed-unsafe-set (ARRAY-02) the boxed unsafeSet on a Float or Char array read the new value as an ElmInt and
//                               marked the copy kind 1 (Int).
//   boxed-push (ARRAY-03)       the boxed push on a Float or Char array copied the 64 bits after the value's
//                               header (a Char's padding included) and marked the copy kind 1.
//   push-int (ARRAY-05)         elm_array_push_int on a nonempty kind-0 (boxed) array stored the raw Int in a
//                               slot the GC traces as a pointer, and kept kind 0. Under HEAP_046 no producer
//                               builds such an array any more, so the fixture is built by hand; the case keeps
//                               testing bindPrimitiveKind's defensive conversion.
//   HEAP_046                    every producer binds an array holding boxed Ints, Floats or Chars to their
//                               primitive kind and stores them unboxed; before, singleton, push onto an empty
//                               array, push_box and the kKeep builders made kind-0 arrays of boxed primitives,
//                               and push_box relabelled a primitive array boxed.
//
// Each case runs in its own spawned process: it initializes the allocator, and the cases that may crash run in
// a forked child (ForkedChild::runInChild).

#include "JsArrayKernelTest.hpp"

#include "../ForkedChild.hpp"
#include "../TestSuite.hpp"
#include "../allocator/TestHelpers.hpp"

#include "../../elm-kernel-cpp/src/ExportHelpers.hpp"
#include "../../elm-kernel-cpp/src/KernelExports.h"
#include "../../runtime/src/allocator/Allocator.hpp"
#include "../../runtime/src/allocator/Heap.hpp"
#include "../../runtime/src/allocator/HeapHelpers.hpp"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#if !defined(_WIN32)
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

using namespace Elm;
namespace Ex = Elm::Kernel::Export;

namespace {

// ---- JsArray helpers --------------------------------------------------------

HPtr enc(HPointer h) { return HPtr::fromBits(Ex::encode(h)); }

ElmArray* arrayOf(HPtr a) { return static_cast<ElmArray*>(Ex::toPtr(a.toBits())); }

uint32_t kindOf(HPtr a) { return arrayOf(a)->header.unboxed & 0x3; }

// The heap object a boxed kernel result names (null for an embedded constant).
Header* objectOf(HPtr h) { return static_cast<Header*>(Ex::toPtr(h.toBits())); }

HPtr boxedInt(int64_t v) { return enc(alloc::allocInt(v)); }
HPtr boxedFloat(double v) { return enc(alloc::allocFloat(v)); }
HPtr boxedChar(uint32_t v) { return enc(alloc::allocChar(v)); }

// "kind K [e0, e1, ...]" with each slot printed as a raw 64-bit hex word.
std::string describeArray(HPtr a) {
    ElmArray* arr = arrayOf(a);
    std::ostringstream os;
    os << "kind " << (arr->header.unboxed & 0x3) << " len " << arr->length << " [";
    for (uint32_t i = 0; i < arr->length; i++) {
        if (i) os << ",";
        os << "0x" << std::hex << static_cast<uint64_t>(arr->elements[i].i) << std::dec;
    }
    os << "]";
    return os.str();
}

#if !defined(_WIN32)
std::string describeStatus(const ForkedChild::ChildResult& r) {
    std::ostringstream os;
    if (WIFSIGNALED(r.status)) os << "child signal " << WTERMSIG(r.status);
    else if (WIFEXITED(r.status)) os << "child exit " << WEXITSTATUS(r.status);
    else os << "child status " << r.status;
    if (!r.stderrText.empty()) os << ", stderr: " << r.stderrText;
    return os.str();
}
#endif

constexpr int64_t kWideIndex = (int64_t{1} << 32) + 1;   // low 32 bits = 1
constexpr int kChildDefect = 10;   // exit status: the child saw the defect's value
constexpr int kChildOther = 3;     // exit status: neither the fixed nor the defective result

// ---- ARRAY-01 ---------------------------------------------------------------

// unsafeSet_Int / boxed unsafeSet with index 2^32 + 1 on [10, 20]: fixed, the copy is returned unchanged.
// Today the index passes the 32-bit check and the store goes 32 GiB past the copy (usually SIGSEGV; a store
// into mapped memory cannot be seen). unsafeGet_Int with the same index: fixed, it traps (an assert) or at
// least does not return an in-range element; today it returns element 1 (20), deterministically.
void testArray01WideIndex() {
#if defined(_WIN32)
    std::cout << "  skipped on Windows (fork)\n";
#else
    initAllocator();
    HPtr arr = Elm_Kernel_JsArray_push_Int(20, Elm_Kernel_JsArray_push_Int(10, Elm_Kernel_JsArray_empty()));
    TEST_ASSERT(kindOf(arr) == 1 && arrayOf(arr)->length == 2);

    auto setScenario = [arr](bool boxedVariant) {
        return [arr, boxedVariant]() -> int {
            HPtr r = boxedVariant
                         ? Elm_Kernel_JsArray_unsafeSet(boxedInt(kWideIndex), boxedInt(7), arr)
                         : Elm_Kernel_JsArray_unsafeSet_Int(kWideIndex, 7, arr);
            ElmArray* a = arrayOf(r);
            const bool same = a->length == 2 && a->elements[0].i == 10 && a->elements[1].i == 20;
            if (!same) std::fprintf(stderr, "result %s", describeArray(r).c_str());
            return same ? 0 : kChildOther;
        };
    };
    const auto setInt = ForkedChild::runInChild(setScenario(false));
    const auto setBoxed = ForkedChild::runInChild(setScenario(true));
    const bool setIntOk = WIFEXITED(setInt.status) && WEXITSTATUS(setInt.status) == 0;
    const bool setBoxedOk = WIFEXITED(setBoxed.status) && WEXITSTATUS(setBoxed.status) == 0;

    const auto get = ForkedChild::runInChild([arr]() -> int {
        HPtr r = Elm_Kernel_JsArray_unsafeGet_Int(kWideIndex, arr);
        Header* h = objectOf(r);
        if (h && h->tag == Tag_Int && reinterpret_cast<ElmInt*>(h)->value == 20) {
            std::fprintf(stderr, "unsafeGet_Int(2^32+1) returned element 1 (20)");
            return kChildDefect;
        }
        return 0;
    });
    const bool getDefect = WIFEXITED(get.status) && WEXITSTATUS(get.status) == kChildDefect;

    const bool defect = !setIntOk || !setBoxedOk || getDefect;
    if (defect) {
        TEST_FAIL("ARRAY-01: unsafeSet_Int(2^32+1): " + describeStatus(setInt) +
                  "; unsafeSet(boxed 2^32+1): " + describeStatus(setBoxed) +
                  "; unsafeGet_Int(2^32+1): " + describeStatus(get));
    }
#endif
}

// ---- ARRAY-02 ---------------------------------------------------------------

// The boxed unsafeSet on a Float array and on a Char array must keep the array's kind and store the value
// in that kind; a boxed (kind 0) array of Strings must stay kind 0 (control, a plain assertion).
void testArray02BoxedUnsafeSetKind() {
    initAllocator();
    std::ostringstream how;
    bool defect = false;

    // Float.
    {
        HPtr arr = Elm_Kernel_JsArray_push_Float(2.5, Elm_Kernel_JsArray_push_Float(1.5, Elm_Kernel_JsArray_empty()));
        TEST_ASSERT(kindOf(arr) == 2);
        HPtr r = Elm_Kernel_JsArray_unsafeSet(boxedInt(0), boxedFloat(9.25), arr);
        const uint32_t kind = kindOf(r);
        const double f0 = arrayOf(r)->elements[0].f;
        Header* g = objectOf(Elm_Kernel_JsArray_unsafeGet(boxedInt(1), r));
        const bool getOk = g && g->tag == Tag_Float && reinterpret_cast<ElmFloat*>(g)->value == 2.5;
        const bool ok = kind == 2 && f0 == 9.25 && getOk;
        defect = defect || !ok;
        how << "Float: kind " << kind << " (want 2), elements[0].f " << f0 << ", unsafeGet 1 tag "
            << (g ? static_cast<int>(g->tag) : -1) << " (want Tag_Float " << static_cast<int>(Tag_Float) << ")";
    }
    // Char.
    {
        HPtr arr = Elm_Kernel_JsArray_push_Char('y', Elm_Kernel_JsArray_push_Char('x', Elm_Kernel_JsArray_empty()));
        TEST_ASSERT(kindOf(arr) == 3);
        HPtr r = Elm_Kernel_JsArray_unsafeSet(boxedInt(0), boxedChar('z'), arr);
        const uint32_t kind = kindOf(r);
        const uint64_t w0 = static_cast<uint64_t>(arrayOf(r)->elements[0].i);
        Header* g = objectOf(Elm_Kernel_JsArray_unsafeGet(boxedInt(0), r));
        const bool getOk = g && g->tag == Tag_Char && reinterpret_cast<ElmChar*>(g)->value == 'z';
        const bool ok = kind == 3 && w0 == 'z' && getOk;
        defect = defect || !ok;
        how << "; Char: kind " << kind << " (want 3), elements[0] 0x" << std::hex << w0 << std::dec
            << ", unsafeGet 0 tag " << (g ? static_cast<int>(g->tag) : -1) << " (want Tag_Char "
            << static_cast<int>(Tag_Char) << ")";
    }
    // Control: a boxed array of Strings stays boxed and gets the new pointer.
    {
        HPtr s1 = enc(alloc::allocString(u"one"));
        HPtr s2 = enc(alloc::allocString(u"two"));
        HPtr s3 = enc(alloc::allocString(u"three"));
        HPtr arr = elm_array_push_box(s2, elm_array_push_box(s1, Elm_Kernel_JsArray_empty()));
        TEST_ASSERT(kindOf(arr) == 0);
        HPtr r = Elm_Kernel_JsArray_unsafeSet(boxedInt(0), s3, arr);
        TEST_ASSERT(kindOf(r) == 0);
        TEST_ASSERT(Ex::encode(arrayOf(r)->elements[0].p) == s3.toBits());
        TEST_ASSERT(Ex::encode(arrayOf(r)->elements[1].p) == s2.toBits());
    }
    if (defect) TEST_FAIL("ARRAY-02: " + how.str());
}

// ---- ARRAY-03 ---------------------------------------------------------------

// The boxed push on a Char array, with a boxed Char whose padding word is 0xFFFFFFFF (what nursery poison
// would leave), must give a kind-3 array whose new slot has its upper 32 bits zero (REP_HEAP_002); on a
// Float array, a kind-2 array holding the value.
void testArray03BoxedPushKind() {
    initAllocator();
    std::ostringstream how;
    bool defect = false;

    // Char.
    {
        HPtr arr = Elm_Kernel_JsArray_push_Char('a', Elm_Kernel_JsArray_empty());
        TEST_ASSERT(kindOf(arr) == 3);
        HPtr b = boxedChar('b');
        reinterpret_cast<ElmChar*>(objectOf(b))->padding = 0xFFFFFFFFu;
        HPtr r = Elm_Kernel_JsArray_push(b, arr);
        const uint32_t kind = kindOf(r);
        const uint64_t w1 = static_cast<uint64_t>(arrayOf(r)->elements[1].i);
        Header* g = objectOf(Elm_Kernel_JsArray_unsafeGet(boxedInt(1), r));
        const bool getOk = g && g->tag == Tag_Char && reinterpret_cast<ElmChar*>(g)->value == 'b';
        const bool ok = kind == 3 && (w1 >> 32) == 0 && getOk;
        defect = defect || !ok;
        how << "Char: kind " << kind << " (want 3), elements[1] 0x" << std::hex << w1 << std::dec
            << " (want 0x62), unsafeGet 1 tag " << (g ? static_cast<int>(g->tag) : -1);
    }
    // Float.
    {
        HPtr arr = Elm_Kernel_JsArray_push_Float(1.5, Elm_Kernel_JsArray_empty());
        TEST_ASSERT(kindOf(arr) == 2);
        HPtr r = Elm_Kernel_JsArray_push(boxedFloat(3.75), arr);
        const uint32_t kind = kindOf(r);
        const double f1 = arrayOf(r)->elements[1].f;
        Header* g = objectOf(Elm_Kernel_JsArray_unsafeGet(boxedInt(1), r));
        const bool getOk = g && g->tag == Tag_Float && reinterpret_cast<ElmFloat*>(g)->value == 3.75;
        const bool ok = kind == 2 && f1 == 3.75 && getOk;
        defect = defect || !ok;
        how << "; Float: kind " << kind << " (want 2), elements[1].f " << f1 << ", unsafeGet 1 tag "
            << (g ? static_cast<int>(g->tag) : -1);
    }
    if (defect) TEST_FAIL("ARRAY-03: " + how.str());
}

// ---- ARRAY-05 ---------------------------------------------------------------

// elm_array_push_int(4) on the kind-0 array [boxed 1, boxed 2]: fixed, either a kind-1 [1,2,4] (convert) or
// an abort (assert). Today the result is kind 0 with the raw word 4 in slot 2, which a GC would trace as a
// pointer.
void testArray05PushIntIntoBoxed() {
#if defined(_WIN32)
    std::cout << "  skipped on Windows (fork)\n";
#else
    initAllocator();
    // A kind-0 array of boxed Ints, which no producer builds under HEAP_046, built by hand.
    HPointer one = alloc::allocInt(1);
    HPointer two = alloc::allocInt(2);
    HPointer raw = alloc::allocArray(2);
    void* rawObj = Allocator::instance().resolve(raw);
    alloc::arrayPush(rawObj, alloc::boxed(one), true);
    alloc::arrayPush(rawObj, alloc::boxed(two), true);
    HPtr arr = enc(raw);
    TEST_ASSERT(kindOf(arr) == 0 && arrayOf(arr)->length == 2);

    const auto r = ForkedChild::runInChild([arr]() -> int {
        HPtr res = elm_array_push_int(4, arr);
        ElmArray* a = arrayOf(res);
        std::fprintf(stderr, "result %s", describeArray(res).c_str());
        if ((a->header.unboxed & 0x3) == 0 && a->length == 3 && a->elements[2].i == 4) return kChildDefect;
        if ((a->header.unboxed & 0x3) == 1 && a->length == 3 && a->elements[0].i == 1 &&
            a->elements[1].i == 2 && a->elements[2].i == 4)
            return 0;
        return kChildOther;
    });
    const bool fixedConvert = WIFEXITED(r.status) && WEXITSTATUS(r.status) == 0;
    const bool fixedAbort = WIFSIGNALED(r.status) && WTERMSIG(r.status) == SIGABRT;
    if (!(fixedConvert || fixedAbort)) TEST_FAIL("ARRAY-05: " + describeStatus(r));
#endif
}

// ---- HEAP_046 ---------------------------------------------------------------

// Each producer that receives boxed values builds an array of the values' primitive kind, holding them raw,
// and keeps it through a minor collection. A boxed non-primitive (a String) still gives a kind-0 array.
void testHeap046ProducersBindPrimitiveKind() {
    initAllocator();
    std::ostringstream how;
    bool defect = false;
    auto check = [&](const char* what, HPtr a, uint32_t wantKind, uint32_t wantLen) {
        const bool ok = kindOf(a) == wantKind && arrayOf(a)->length == wantLen;
        if (!ok) { defect = true; how << what << ": " << describeArray(a) << " (want kind " << wantKind << "); "; }
    };

    check("singleton_box Int", elm_array_singleton_box(boxedInt(5)), 1, 1);
    check("singleton_box Float", elm_array_singleton_box(boxedFloat(1.5)), 2, 1);
    check("singleton_box Char", elm_array_singleton_box(boxedChar('q')), 3, 1);
    check("singleton_box String", elm_array_singleton_box(enc(alloc::allocStringFromUTF8("s"))), 0, 1);
    check("JsArray.singleton Int", Elm_Kernel_JsArray_singleton(boxedInt(6)), 1, 1);
    check("JsArray.push onto empty", Elm_Kernel_JsArray_push(boxedInt(7), Elm_Kernel_JsArray_empty()), 1, 1);
    check("push_box onto empty", elm_array_push_box(boxedInt(8), Elm_Kernel_JsArray_empty()), 1, 1);

    HPtr ints = elm_array_push_int(2, elm_array_push_int(1, Elm_Kernel_JsArray_empty()));
    HPtr pushed = elm_array_push_box(boxedInt(9), ints);
    check("push_box onto kind 1", pushed, 1, 3);
    if (arrayOf(pushed)->elements[2].i != 9) { defect = true; how << "push_box element 2 not 9; "; }

    // kKeep: a list of boxed Ints gives an Int array.
    std::vector<HPointer> heads = {alloc::allocInt(10), alloc::allocInt(11), alloc::allocInt(12)};
    HPointer list = alloc::listFromPointers(heads);
    HPtr pair = Elm_Kernel_JsArray_initializeFromList(boxedInt(8), enc(list));
    HPtr fromList = enc(static_cast<Tuple2*>(Ex::toPtr(pair.toBits()))->a.p);
    check("initializeFromList kKeep", fromList, 1, 3);

    // The values survive a minor collection, read raw.
    uint64_t roots[2] = {pushed.toBits(), fromList.toBits()};
    eco_gc_add_value_root(&roots[0]);
    eco_gc_add_value_root(&roots[1]);
    eco_minor_gc();
    ElmArray* p = arrayOf(HPtr::fromBits(roots[0]));
    ElmArray* f = arrayOf(HPtr::fromBits(roots[1]));
    if (!(p->elements[0].i == 1 && p->elements[1].i == 2 && p->elements[2].i == 9)) {
        defect = true; how << "after GC push_box: " << describeArray(HPtr::fromBits(roots[0])) << "; ";
    }
    if (!(f->elements[0].i == 10 && f->elements[1].i == 11 && f->elements[2].i == 12)) {
        defect = true; how << "after GC initializeFromList: " << describeArray(HPtr::fromBits(roots[1])) << "; ";
    }
    eco_gc_remove_value_root(&roots[0]);
    eco_gc_remove_value_root(&roots[1]);
    if (defect) TEST_FAIL("HEAP_046: " + how.str());
}
}  // namespace

void registerJsArrayKernelTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite) {
    suite.add(Testing::TestCase("js-array-kernel/index-checked-on-all-64-bits", testArray01WideIndex));
    suite.add(Testing::TestCase("js-array-kernel/boxed-unsafe-set-keeps-float-char-kind", testArray02BoxedUnsafeSetKind));
    suite.add(Testing::TestCase("js-array-kernel/boxed-push-keeps-kind-and-zero-char-padding", testArray03BoxedPushKind));
    suite.add(Testing::TestCase("js-array-kernel/push-int-into-nonempty-boxed-array", testArray05PushIntIntoBoxed));
    suite.add(Testing::TestCase("js-array-kernel/producers-bind-primitive-kind", testHeap046ProducersBindPrimitiveKind));
}
