/**
 * Fail-first pins for the wide-object plan (plans/wide-object-tail-kind-words-phase-0.md,
 * step 0.6d). Each test asserts the CORRECT behaviour, so it fails while its bug exists;
 * the phase that turns it green is named in the test name's comment.
 *
 * Every pin that can crash today runs in a fork()ed child, so a red pin fails one test
 * instead of killing the test binary. The GC pins (B7 closure captures, B8b) are only
 * deterministic in a build-validate tree, whose poisoned from-space turns a missed
 * trace into a wrong value or a validate abort; in the default tree they may pass by luck.
 */

#include "WideObjectPinsTest.hpp"
#include "../../runtime/src/allocator/RuntimeExports.h"
#include "../../runtime/src/allocator/Allocator.hpp"
#include "../../runtime/src/allocator/Heap.hpp"
#include "../../runtime/src/allocator/HeapHelpers.hpp"
#include "../../elm-kernel-cpp/src/KernelExports.h"
#include "../../elm-kernel-cpp/src/ExportHelpers.hpp"
#include "TestHelpers.hpp"
#include "../TestSuite.hpp"
#include <csignal>
#include <cstring>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

using namespace Elm;
using namespace Elm::TestHelpers;

namespace {

// Runs `f` in a forked child. A child that returns normally exits 0; an abort
// shows up as the negated signal number.
template <class F> int runInChild(F f) {
    pid_t pid = fork();
    if (pid == 0) {
        f();
        _exit(0);
    }
    int st = 0;
    waitpid(pid, &st, 0);
    return WIFSIGNALED(st) ? -WTERMSIG(st) : WEXITSTATUS(st);
}

void* stubEval(void**) { return nullptr; }

Unboxable boxed(HPointer p) {
    Unboxable u;
    u.p = p;
    return u;
}

Unboxable rawInt(i64 v) {
    Unboxable u;
    u.i = v;
    return u;
}

// The Int value of the boxed ElmInt in `slot`.
i64 boxedIntValue(const Unboxable& slot) {
    return static_cast<ElmInt*>(Allocator::instance().resolve(slot.p))->value;
}

// Allocates enough short-lived Ints to force several minor GCs.
void churn() {
    for (int i = 0; i < 100000; ++i) (void)alloc::allocInt(i);
}

HPtr toHPtr(HPointer p) {
    HPtr h;
    std::memcpy(&h.bits, &p, sizeof(h.bits));
    return h;
}

// ---- B6 (green P1): closureCapture must not store a typed value it cannot describe ----
void test_b6_closure_capture_typed_beyond_slot_aborts() {
    int r = runInChild([] {
        initAllocator();
        HPointer c = alloc::allocClosureK(stubEval, 30, PK_Boxed);
        for (int i = 0; i < 25; ++i) {
            HPointer v = alloc::allocInt(i);
            alloc::closureCapture(Allocator::instance().resolve(c), boxed(v), PK_Boxed);
        }
        alloc::closureCapture(Allocator::instance().resolve(c), rawInt(7), PK_Int);
    });
    TEST_ASSERT(r == -SIGABRT);
}

// ---- B7 (green P1): kind reads at slot >= 32 must not shift by >= 64 ----
void test_b7_pointer_mask_slots_beyond_32_boxed() {
    volatile u64 bm = 1;       // slot 0 = Int, every other slot boxed
    volatile unsigned n = 40;
    u64 m = pointerMaskFromKindBitmap(bm, n);
    TEST_ASSERT(m == ((1ULL << 40) - 2));
}

void test_b7_record_equality_slots_beyond_32() {
    initAllocator();
    auto build = [] {
        std::vector<Unboxable> v(40);
        v[0] = rawInt(5);
        for (int i = 1; i < 40; ++i) v[i] = boxed(alloc::allocInt(1000 + i));
        return alloc::record(v, 1);
    };
    HPointer a = build();
    HPointer b = build();    // equal contents, distinct boxed Int pointers
    HPtr eq = Elm_Kernel_Utils_equal(toHPtr(a), toHPtr(b));
    TEST_ASSERT(eq.toBits() == Elm::Kernel::Export::encodeBoxedBool(true));
}

void test_b7_closure_captures_beyond_32_survive_minor_gc() {
    int r = runInChild([] {
        auto& a = initAllocator();
        HPointer c = alloc::allocClosureK(stubEval, 40, 0);
        a.getRootSet().addRoot(&c);
        alloc::closureCapture(Allocator::instance().resolve(c), rawInt(5), PK_Int);
        for (int i = 1; i < 40; ++i) {
            HPointer v = alloc::allocInt(1000 + i);
            alloc::closureCapture(Allocator::instance().resolve(c), boxed(v), PK_Boxed);
        }
        for (int g = 0; g < 2; ++g) {
            churn();
            a.minorGC();
        }
        Closure* cl = static_cast<Closure*>(Allocator::instance().resolve(c));
        for (int i = 32; i < 40; ++i) {
            if (boxedIntValue(cl->values[i]) != 1000 + i) _exit(3);
        }
    });
    TEST_ASSERT(r == 0);
}

// ---- B8 (green P1): custom() must root every boxed slot on the slow path ----
void test_b8_custom_70_boxed_roots_every_slot() {
    int r = runInChild([] {
        auto& a = initAllocator();
        std::vector<HPointer> held(70);
        for (int i = 0; i < 70; ++i) {
            held[i] = alloc::allocInt(1000 + i);
            a.getRootSet().addRoot(&held[i]);
        }
        // Exhaust the current allocation buffer so custom() takes its slow path.
        while (a.allocateFast(16) != nullptr) {
        }
        std::vector<Unboxable> v(70);
        for (int i = 0; i < 70; ++i) v[i] = boxed(held[i]);
        HPointer h = alloc::custom(0, v, 0);
        Custom* obj = static_cast<Custom*>(Allocator::instance().resolve(h));
        for (int i = 0; i < 70; ++i) {
            if (boxedIntValue(obj->values[i]) != 1000 + i) _exit(3);
        }
    });
    TEST_ASSERT(r == 0);
}

// ---- B8b (green P1, step 1d): Custom slots >= 24 must be traced by the GC ----
// Built on the fast path (no slow-path rooting involved), so the only failure
// mode left is the Custom walker stopping at slot 24.
void test_b8b_custom_slots_beyond_24_survive_minor_gc() {
    int r = runInChild([] {
        auto& a = initAllocator();
        std::vector<Unboxable> v(70);
        for (int i = 0; i < 70; ++i) v[i] = boxed(alloc::allocInt(1000 + i));
        HPointer h = alloc::custom(0, v, 0);
        a.getRootSet().addRoot(&h);
        churn();
        a.minorGC();
        Custom* obj = static_cast<Custom*>(Allocator::instance().resolve(h));
        for (int i = 24; i < 70; ++i) {
            if (boxedIntValue(obj->values[i]) != 1000 + i) _exit(3);
        }
    });
    TEST_ASSERT(r == 0);
}

// ---- B11 (green P1): eco_set_unboxed must reject a Record ----
void test_b11_set_unboxed_on_record_aborts() {
    int r = runInChild([] {
        initAllocator();
        HPointer rec = alloc::record({boxed(alloc::allocInt(1)), boxed(alloc::allocInt(2))}, 0);
        eco_set_unboxed(toHPtr(rec), 3);
    });
    TEST_ASSERT(r == -SIGABRT);
}

} // namespace

void registerWideObjectPinsTests(Testing::TestSuite& suite) {
    suite.add(Testing::TestCase(
        "wide B6: closureCapture of a typed kind at slot >= 25 aborts",
        test_b6_closure_capture_typed_beyond_slot_aborts));
    suite.add(Testing::TestCase(
        "wide B7: pointerMaskFromKindBitmap treats slots >= 32 as boxed",
        test_b7_pointer_mask_slots_beyond_32_boxed));
    suite.add(Testing::TestCase(
        "wide B7: equality of 40-field records compares slots >= 32 as boxed",
        test_b7_record_equality_slots_beyond_32));
    suite.add(Testing::TestCase(
        "wide B7: boxed captures 32..39 of a 40-slot closure survive minor GCs",
        test_b7_closure_captures_beyond_32_survive_minor_gc));
    suite.add(Testing::TestCase(
        "wide B8: custom() with 70 boxed fields roots every slot on the slow path",
        test_b8_custom_70_boxed_roots_every_slot));
    suite.add(Testing::TestCase(
        "wide B8b: slots 24..69 of a 70-field Custom survive a later minor GC",
        test_b8b_custom_slots_beyond_24_survive_minor_gc));
    suite.add(Testing::TestCase(
        "wide B11: eco_set_unboxed on a Record aborts",
        test_b11_set_unboxed_on_record_aborts));
}
