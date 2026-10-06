/**
 * Wide-object slot-kind tests beyond the Phase 0 pins
 * (plans/wide-object-tail-kind-words-phase-1.md steps 1c.1, 1c.2, 1c.4, 1c.5).
 *
 * Phase 1 is D semantics: a slot its container's header bitmap cannot describe
 * reads as boxed (kind 0). These tests pin the accessors, the chunked root
 * helper, and the runtime paths that now use them. Some build a wide
 * Custom/Record (legal since Phase 3D); the GC ones run in a fork()ed child
 * so a regression fails one test, not the binary.
 */

#include "WideKindsTest.hpp"
#include "../../runtime/src/allocator/RuntimeExports.h"
#include "../../runtime/src/allocator/Allocator.hpp"
#include "../../runtime/src/allocator/Heap.hpp"
#include "../../runtime/src/allocator/HeapHelpers.hpp"
#include "../../runtime/src/allocator/RootSet.hpp"
#include "TestHelpers.hpp"
#include "../TestSuite.hpp"
#include <cstring>
#include <sstream>
#include <string>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

using namespace Elm;
using namespace Elm::TestHelpers;

namespace {

// Runs `f` in a forked child: 0 on a normal return, the child's exit code on
// _exit(n), the negated signal number on a crash.
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

HPtr toHPtr(HPointer p) {
    HPtr h;
    std::memcpy(&h.bits, &p, sizeof(h.bits));
    return h;
}

// What Debug.toString's untyped printer (eco_print_value) writes for `v`.
std::string printed(HPtr v) {
    std::ostringstream out;
    void* prev = eco_set_output_stream(&out);
    eco_print_value(v);
    eco_set_output_stream(prev);
    return out.str();
}

std::string quoted(const std::string& s) { return "\"" + s + "\""; }

i64 boxedIntValue(const Unboxable& slot) {
    return static_cast<ElmInt*>(Allocator::instance().resolve(slot.p))->value;
}

void churn() {
    for (int i = 0; i < 100000; ++i) (void)alloc::allocInt(i);
}

uint64_t minorCount() { return Allocator::instance().getCombinedStats().minor_gc_count; }

// Hand-made objects in a plain buffer: the accessors are pure functions.
template <class T> T* inBuffer(std::vector<u64>& buf, u32 slots) {
    buf.assign((sizeof(T) + slots * sizeof(Unboxable)) / sizeof(u64) + 1, 0);
    return reinterpret_cast<T*>(buf.data());
}

// ---- 1c.1 ----
void test_ext_words_boundaries() {
    static_assert(extWords(24, 24) == 0);
    TEST_ASSERT(extWords(24, 24) == 0);
    TEST_ASSERT(extWords(25, 24) == 1);
    TEST_ASSERT(extWords(56, 24) == 1);
    TEST_ASSERT(extWords(57, 24) == 2);
    TEST_ASSERT(extWords(2040, 24) == 63);
    TEST_ASSERT(extWords(2047, 32) == 63);
    TEST_ASSERT(extWords(2047, 20) == 64);
}

void test_accessors_boxed_past_header() {
    constexpr u64 allInt = 0x5555555555555555ULL;
    std::vector<u64> cb, rb, kb;

    Custom* c = inBuffer<Custom>(cb, 30);
    c->header.tag = Tag_Custom;
    c->header.size = 30;
    c->unboxed = allInt & 0x0000FFFFFFFFFFFFULL;
    TEST_ASSERT(customSlotKind(c, 0) == 1);
    TEST_ASSERT(customSlotKind(c, 23) == 1);
    for (u32 i = 24; i < 30; ++i) TEST_ASSERT(customSlotKind(c, i) == 0);

    Record* r = inBuffer<Record>(rb, 40);
    r->header.tag = Tag_Record;
    r->header.size = 40;
    r->unboxed = allInt;
    TEST_ASSERT(recordSlotKind(r, 31) == 1);
    for (u32 i = 32; i < 40; ++i) TEST_ASSERT(recordSlotKind(r, i) == 0);

    // Phase 2: 20 inline kinds, then K = extWords(40, 20) = 1 ext word at the
    // object's tail (header.size = 40 + 1); a zero ext word reads boxed.
    Closure* k = inBuffer<Closure>(kb, 41);
    k->header.tag = Tag_Closure;
    k->header.size = 41;
    k->max_values = 40;
    k->unboxed = allInt & ((1ULL << 40) - 1);
    TEST_ASSERT(closureSlotKind(k, 19) == 1);
    for (u32 i = 20; i < 40; ++i) TEST_ASSERT(closureSlotKind(k, i) == 0);
}

// ---- 1c.2 ----
void test_debug_to_string_40_field_record_slot_32() {
    initAllocator();
    auto& a = Allocator::instance();
    std::vector<HPointer> strs(40);
    for (int i = 1; i < 40; ++i) {
        strs[i] = alloc::allocStringFromUTF8("s" + std::to_string(i));
        a.getRootSet().addRoot(&strs[i]);
    }
    std::vector<Unboxable> v(40);
    v[0] = rawInt(5);
    for (int i = 1; i < 40; ++i) v[i] = boxed(strs[i]);
    HPointer rec = alloc::record(v, 1);   // slot 0 Int, slots 1..39 boxed
    for (int i = 1; i < 40; ++i) a.getRootSet().removeRoot(&strs[i]);
    std::string out = printed(toHPtr(rec));
    TEST_ASSERT(out.find("f0 = 5") != std::string::npos);
    TEST_ASSERT(out.find("f32 = " + quoted("s32")) != std::string::npos);
    TEST_ASSERT(out.find("f39 = " + quoted("s39")) != std::string::npos);
}

// ---- 1c.4 ----
void test_closure_kinds_past_31_snapshot() {
    initAllocator();
    std::vector<u64> kb;
    Closure* k = inBuffer<Closure>(kb, 41);
    k->header.tag = Tag_Closure;
    k->header.size = 41;   // 40 value slots + 1 ext word (Phase 2)
    k->max_values = 40;
    k->unboxed = 1;   // slot 0 Int, every other slot boxed (ext word 0)
    ClosureKinds ks;
    snapshotClosureKinds(k, ks);
    TEST_ASSERT(ks.max == 40 && ks.k == 1 && ks.ext[0] == 0);
    TEST_ASSERT(closureKindAt(ks, 0) == 1);
    TEST_ASSERT(closureKindAt(ks, 31) == 0);
    TEST_ASSERT(closureKindAt(ks, 32) == 0);

    uint64_t buf[70] = {0};
    size_t before = eco_gc_stack_range_point();
    pushRootsByKinds(buf, 40, [&](uint32_t i) { return closureKindAt(ks, i); });
    size_t after = eco_gc_stack_range_point();
    TEST_ASSERT(after == before + sizeof(StackRootRangeRec));
    const StackRootRangeRec* rec = reinterpret_cast<const StackRootRangeRec*>(before);
    TEST_ASSERT(rec->count == 40);
    TEST_ASSERT(rec->hpointer_mask == ((1ULL << 40) - 2));   // bit 32 set, bit 0 clear
    eco_gc_restore_stack_range_point(before);

    // Over 64 slots: one 64-slot chunk, then the rest.
    pushRootsByKinds(buf, 70, [&](uint32_t) { return 0u; });
    after = eco_gc_stack_range_point();
    TEST_ASSERT(after == before + 2 * sizeof(StackRootRangeRec));
    rec = reinterpret_cast<const StackRootRangeRec*>(before);
    TEST_ASSERT(rec[0].count == 64 && rec[0].hpointer_mask == ~uint64_t{0});
    TEST_ASSERT(reinterpret_cast<const uint64_t*>(rec[1].base) == buf + 64);
    TEST_ASSERT(rec[1].count == 6 && rec[1].hpointer_mask == 0x3FULL);
    eco_gc_restore_stack_range_point(before);
}

// Allocates enough to force minor GCs inside the call, then returns its 40th
// argument: combined_args is a rooted buffer, so the GC must have updated it.
void* eval40(void** args) {
    churn();
    return args[39];
}

void test_closure_call_saturated_roots_40_slots() {
    int r = runInChild([] {
        auto& a = initAllocator(pressureHeapConfig());
        std::vector<HPointer> strs(40);
        for (int i = 0; i < 40; ++i) {
            strs[i] = alloc::allocStringFromUTF8("arg" + std::to_string(i));
            a.getRootSet().addRoot(&strs[i]);
        }
        HPointer c = alloc::allocClosureK(eval40, 40, PK_Boxed);
        a.getRootSet().addRoot(&c);
        for (int i = 0; i < 20; ++i)
            alloc::closureCapture(Allocator::instance().resolve(c), boxed(strs[i]), PK_Boxed);
        uint64_t newargs[20];
        for (int i = 0; i < 20; ++i) std::memcpy(&newargs[i], &strs[20 + i], sizeof(uint64_t));
        const uint64_t minors = minorCount();
        HPtr res = eco_closure_call_saturated(toHPtr(c), newargs, 20, nullptr);
        if (minorCount() == minors) _exit(4);   // vacuous: no GC ran inside
        if (printed(res) != quoted("arg39")) _exit(3);
    });
    TEST_ASSERT(r == 0);
}

// ---- 1c.5 (record() twins of the B8 / B8b pins) ----
void test_record_70_boxed_roots_every_slot() {
    int r = runInChild([] {
        auto& a = initAllocator();   // as the B8 / B8b pins
        std::vector<HPointer> held(70);
        for (int i = 0; i < 70; ++i) {
            held[i] = alloc::allocInt(1000 + i);
            a.getRootSet().addRoot(&held[i]);
        }
        // Exhaust the current allocation buffer so record() takes its slow path.
        while (a.allocateFast(16) != nullptr) {
        }
        std::vector<Unboxable> v(70);
        for (int i = 0; i < 70; ++i) v[i] = boxed(held[i]);
        HPointer h = alloc::record(v, 0);
        Record* obj = static_cast<Record*>(Allocator::instance().resolve(h));
        for (int i = 0; i < 70; ++i) {
            if (boxedIntValue(obj->values[i]) != 1000 + i) _exit(3);
        }
    });
    TEST_ASSERT(r == 0);
}

void test_record_slots_beyond_32_survive_minor_gc() {
    int r = runInChild([] {
        auto& a = initAllocator();   // as the B8 / B8b pins
        std::vector<Unboxable> v(70);
        for (int i = 0; i < 70; ++i) v[i] = boxed(alloc::allocInt(1000 + i));
        HPointer h = alloc::record(v, 0);
        a.getRootSet().addRoot(&h);
        const uint64_t minors = minorCount();
        churn();
        a.minorGC();
        if (minorCount() == minors) _exit(4);
        Record* obj = static_cast<Record*>(Allocator::instance().resolve(h));
        for (int i = 32; i < 70; ++i) {
            if (boxedIntValue(obj->values[i]) != 1000 + i) _exit(3);
        }
    });
    TEST_ASSERT(r == 0);
}

} // namespace

void registerWideKindsTests(Testing::TestSuite& suite) {
    suite.add(Testing::TestCase("wide kinds: extWords boundaries", test_ext_words_boundaries));
    suite.add(Testing::TestCase("wide kinds: accessors return boxed past the header (Phase 1)",
                                test_accessors_boxed_past_header));
    suite.add(Testing::TestCase(
        "wide kinds: Debug.toString of a 40-field record prints slot 32 as a string",
        test_debug_to_string_40_field_record_slot_32));
    suite.add(Testing::TestCase("wide kinds: closure kinds past slot 31 read boxed (snapshot)",
                                test_closure_kinds_past_31_snapshot));
    suite.add(Testing::TestCase("wide kinds: eco_closure_call_saturated roots 40 slots",
                                test_closure_call_saturated_roots_40_slots));
    suite.add(Testing::TestCase(
        "wide kinds: record() with 70 boxed fields roots every slot on the slow path",
        test_record_70_boxed_roots_every_slot));
    suite.add(Testing::TestCase(
        "wide kinds: slots 32..69 of a 70-field Record survive a later minor GC",
        test_record_slots_beyond_32_survive_minor_gc));
}
