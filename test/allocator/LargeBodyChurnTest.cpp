/**
 * GC triggers for large-body allocation (plans/large-body-gc-trigger.md).
 *
 * A split String/Bytes costs the nursery a 16-byte header and puts its body
 * straight into the old generation (HEAP_026). Before the plan, a program
 * that mostly moved big buffers ran almost no minors, so dead bodies were
 * never swept and the old gen filled to its cap (an abort in
 * allocLargeByteBuffer). These cases run the split path hard on a small heap:
 *   (a) churn: nothing kept; the debt (D1-D3) must keep minors running;
 *   (b) promoted garbage: kept bodies die old, so majors must run;
 *   (c) recovery only: with the debt off, D4's minor-then-major retry alone
 *       must keep the churn alive;
 *   (d) budget 0 turns the debt off;
 *   (e) the HeapConfig / JSON knob.
 * And the deferred-bytes finish (plans/large-body-deferral-pacing.md, HEAP_084):
 *   (f) one held body plus churn during a cycle: the bodies the cycle defers
 *       stay within its bound, and the cycle ends early;
 *   (g) the finish is deterministic (GC_DET_001);
 *   (h) its two HeapConfig / JSON knobs.
 *
 * Registered in an isolated (forked) suite: before the fix (a) aborted the
 * whole process.
 */

#include "LargeBodyChurnTest.hpp"

#include <algorithm>
#include <cstring>
#include <stdexcept>
#include <vector>

#if !defined(_WIN32)
#include <unistd.h>
#endif

#include "Allocator.hpp"
#include "Heap.hpp"
#include "HeapConfigJson.hpp"
#include "HeapHelpers.hpp"
#include "NurserySpace.hpp"
#include "OldGenSpace.hpp"
#include "TestHelpers.hpp"
#include "ThreadLocalHeap.hpp"

using namespace Elm;

namespace {

// A 256 KiB nursery and a 64 MiB reservation (32 MiB old-gen cap): a
// few hundred dead 60 KiB bodies fill the old gen unless something collects.
HeapConfig churnHeapConfig() {
    HeapConfig cfg;
    cfg.alloc_buffer_size    = 64 * 1024;
    cfg.nursery_block_count  = 4;                 // 256 KiB nursery.
    // plans/region-nursery-everywhere.md Phase 3: a fixed nursery, so the region
    // layout's heap slot (extents x the max nursery side) fits this small heap.
    cfg.nursery_max_block_count = 4;
    cfg.initial_old_gen_size = 256 * 1024;
    cfg.max_heap_size        = 64ULL * 1024 * 1024;
    cfg.validate();
    return cfg;
}

constexpr size_t kBodyBytes = 60 * 1024;   // >= large_object_threshold: the split path
constexpr size_t kChurnCount = 20000;      // 1.2 GB of bodies

uint64_t minorSeq(Allocator& alloc) {
    return alloc.getCurrentThreadHeap()->getNursery().minorSeq();
}

// ----- The deferred-bytes finish (f)-(h) -----

constexpr size_t kHeldBytes = 2 * 1024 * 1024;   // pointer-free: never scanned, not in live_ref
constexpr size_t kHeldListLength = 20000;         // ~0.6-1 MB of traced cons cells and Ints
constexpr size_t kHoldChurnCount = 3000;          // ~180 MB of bodies: several full cycles' worth

// What one held-body churn run saw of the cycle it started.
struct HoldChurnRun {
    uint64_t max_deferred = 0;    // the most bytes the cycle had deferred at any allocation
    uint64_t bound = 0;           // max(F x live_ref, floor), from the cycle's t0
    uint64_t floor = 0;           // ThreadLocalHeap::deferredFinishFloor()
    uint64_t budget = 0;          // one minor's direct allocation (HEAP_079)
    uint64_t span_minors = 0;     // minors from t0 to the handoff
    uint32_t slices = 0;          // the cycle's T
    std::vector<uint64_t> finish_minors;   // every cycle's handoff, by minor number
};

// Holds a kHeldBytes body and a list of kHeldListLength Ints, runs one cycle so that the next one's
// live estimate counts the list (a raw body is never scanned, so it adds nothing to the markers'
// sums, HEAP_057), then starts a cycle and drops large bodies until kHoldChurnCount have been
// allocated. Cycles the heap's own triggers start are recorded in finish_minors too.
HoldChurnRun runHoldChurn(const HeapConfig& cfg) {
    using OA = OldGenSpaceTestAccess;
    auto& alloc = initAllocator(cfg);
    ThreadLocalHeap* heap = alloc.getCurrentThreadHeap();
    OldGenSpace& og = heap->getOldGen();
    HoldChurnRun r;
    r.budget = heap->directAllocBudget();

    HPointer held = alloc.allocLargeByteBuffer(nullptr, kHeldBytes);
    alloc.getRootSet().addRoot(&held);
    HPointer list = alloc::listNil();
    alloc.getRootSet().addRoot(&list);
    for (size_t i = 0; i < kHeldListLength; ++i) {
        const HPointer n = alloc::allocInt(static_cast<i64>(i));
        list = alloc::cons(alloc::boxed(n), list, true);
    }
    auto runToHandoff = [&]() {
        for (int guard = 0; OA::cycleActive(og); ++guard) {
            if (guard > 100000) throw std::runtime_error("cycle never handed off");
            alloc.minorGC();
        }
    };
    runToHandoff();
    heap->test_force_major_trigger_ = true;
    alloc.minorGC();
    runToHandoff();

    heap->test_force_major_trigger_ = true;
    alloc.minorGC();
    TEST_ASSERT(OA::cycleActive(og));
    const uint64_t t0 = minorSeq(alloc);
    r.slices = cfg.incremental_mark_slices;
    r.floor = heap->deferredFinishFloor();
    r.bound = std::max<uint64_t>(
        static_cast<uint64_t>(cfg.incremental_mark_deferred_finish *
                              static_cast<double>(OA::cycleLiveRef(og))),
        r.floor);
    bool first = true;
    bool was_active = true;
    for (size_t i = 0; i < kHoldChurnCount; ++i) {
        (void)alloc.allocLargeByteBuffer(nullptr, kBodyBytes);
        const bool active = OA::cycleActive(og);
        if (active && first) r.max_deferred = std::max(r.max_deferred, og.cycleDeferredBytes());
        if (was_active && !active) {
            r.finish_minors.push_back(minorSeq(alloc));
            if (first) r.span_minors = minorSeq(alloc) - t0;
            first = false;
        }
        was_active = active;
    }
    runToHandoff();
    alloc.getRootSet().removeRoot(&list);
    alloc.getRootSet().removeRoot(&held);
    TEST_ASSERT(!first);   // the cycle ended within the churn
    return r;
}

// churnHeapConfig with the cycle's mode fixed: the test pins its own schedule.
HeapConfig holdChurnConfig(double deferred_finish) {
    HeapConfig cfg = churnHeapConfig();
    cfg.incremental_mark = true;
    cfg.incremental_mark_slices = 32;
    cfg.incremental_mark_deferred_finish = deferred_finish;
    cfg.validate();
    return cfg;
}

}  // namespace

// ----------------------------------------------------------------------------
// (a) Churn: no buffer kept. The debt must request minors.
// ----------------------------------------------------------------------------

Testing::TestCase testLargeBodyChurnRunsMinors(
    "LargeBodyChurn: dropped split bodies are swept by debt-requested minors", []() {
    auto& alloc = initAllocator(churnHeapConfig());
    ThreadLocalHeap* heap = alloc.getCurrentThreadHeap();
    const size_t budget = heap->directAllocBudget();
    TEST_ASSERT(budget > 0);

    const uint64_t seq0 = minorSeq(alloc);
    for (size_t i = 0; i < kChurnCount; ++i) {
        HPointer b = alloc.allocLargeByteBuffer(nullptr, kBodyBytes);
        TEST_ASSERT(b.ptr != 0);
    }
    const uint64_t minors = minorSeq(alloc) - seq0;
    const uint64_t expected_min = (kChurnCount * kBodyBytes) / (2 * budget);
    TEST_ASSERT(minors >= expected_min);
#if ENABLE_GC_STATS
    TEST_ASSERT(heap->getStats().minor_gc_debt_requests > 0);
#endif
});

// ----------------------------------------------------------------------------
// (b) Promoted garbage: kept headers are promoted, so their bodies die old
// and only majors free them (~75 MB of old garbage against a 32 MiB cap).
// ----------------------------------------------------------------------------

Testing::TestCase testLargeBodyPromotedGarbageRunsMajors(
    "LargeBodyChurn: bodies of promoted headers are reclaimed by majors", []() {
    auto& alloc = initAllocator(churnHeapConfig());

    constexpr size_t kRing = 64;
    std::vector<HPointer> ring(kRing);
    for (auto& r : ring) {
        r = alloc.allocLargeByteBuffer(nullptr, kBodyBytes);
        alloc.getRootSet().addRoot(&r);
    }
    size_t next = 0;
    for (size_t i = 0; i < kChurnCount; ++i) {
        HPointer b = alloc.allocLargeByteBuffer(nullptr, kBodyBytes);
        if (i % 16 == 0) {
            ring[next] = b;   // overwrite the oldest: its body becomes old garbage
            next = (next + 1) % kRing;
        }
    }
    // Every kept buffer is still readable.
    for (auto& r : ring) {
        TEST_ASSERT(r.ptr != 0);
        alloc.getRootSet().removeRoot(&r);
    }
});

// ----------------------------------------------------------------------------
// (c) Recovery only: the debt off, D4's retry alone keeps the churn alive.
// ----------------------------------------------------------------------------

Testing::TestCase testLargeBodyRecoveryWithoutBudget(
    "LargeBodyChurn: a failed body allocation recovers with a minor (budget 0)", []() {
    HeapConfig cfg = churnHeapConfig();
    cfg.direct_alloc_minor_budget = 0;
    cfg.validate();
    auto& alloc = initAllocator(cfg);
    ThreadLocalHeap* heap = alloc.getCurrentThreadHeap();
    TEST_ASSERT(heap->directAllocBudget() == 0);

    // ~120 MB: well past the 32 MiB cap. Once the cap is reached nearly
    // every allocation recovers with a minor (each a full heap walk in
    // validate builds), so the count stays small.
    constexpr size_t kRecoverCount = 2000;
    for (size_t i = 0; i < kRecoverCount; ++i) {
        HPointer s = (i % 2 == 0)
            ? alloc.allocLargeByteBuffer(nullptr, kBodyBytes)
            : alloc::allocString(std::u16string(kBodyBytes / 2, u'x'));
        TEST_ASSERT(s.ptr != 0);
    }
#if ENABLE_GC_STATS
    TEST_ASSERT(heap->getStats().minor_gc_debt_requests == 0);
    // Body allocation fails only at the end of the old-gen ADDRESS range,
    // which the first initialize in the process fixes (first-init-wins). Run
    // alone (--filter LargeBodyChurn) that is this config's 32 MiB and the
    // churn must have recovered; after an earlier test reserved the default
    // 24 GiB the reconfigured cap is only a trigger figure and nothing fails.
    if (AllocatorTestAccess::oldGenReservationBytes(alloc) <= alloc.getOldGenMaxBytes()) {
        TEST_ASSERT(heap->getStats().large_body_recover_minors > 0);
    }
#endif
});

// ----------------------------------------------------------------------------
// (d) Budget 0 is off: small allocations after many large ones run no minor
// the nursery itself does not call for.
// ----------------------------------------------------------------------------

Testing::TestCase testLargeBodyBudgetZeroIsOff(
    "LargeBodyChurn: direct_alloc_minor_budget = 0 requests no minor", []() {
    // 64 bodies = ~4 MiB: many budgets' worth at the default, far below the
    // 32 MiB cap, and 64 headers + 1000 small objects stay below the
    // nursery's own threshold after a fresh minor.
    auto run = [](HeapConfig cfg, uint64_t& large_minors, uint64_t& small_minors) {
        auto& alloc = initAllocator(cfg);
        alloc.minorGC();
        const uint64_t s0 = minorSeq(alloc);
        for (size_t i = 0; i < 64; ++i) {
            alloc.allocLargeByteBuffer(nullptr, kBodyBytes);
        }
        alloc.minorGC();   // pay any debt left over from the large phase
        const uint64_t s1 = minorSeq(alloc);
        for (size_t i = 0; i < 1000; ++i) {
            void* obj = alloc.allocate(sizeof(ElmInt), Tag_Int);
            TEST_ASSERT(obj != nullptr);
        }
        large_minors = s1 - 1 - s0;
        small_minors = minorSeq(alloc) - s1;
    };

    HeapConfig off = churnHeapConfig();
    off.direct_alloc_minor_budget = 0;
    off.validate();
    uint64_t large_off = 0, small_off = 0;
    run(off, large_off, small_off);
    TEST_ASSERT(large_off == 0);
    TEST_ASSERT(small_off == 0);

    // Control: the default budget does request minors in the large phase.
    uint64_t large_on = 0, small_on = 0;
    run(churnHeapConfig(), large_on, small_on);
    TEST_ASSERT(large_on > 0);
    TEST_ASSERT(small_on == 0);
});

// ----------------------------------------------------------------------------
// (e) The knob: JSON round trip and validate() range.
// ----------------------------------------------------------------------------

Testing::TestCase testDirectAllocMinorBudgetConfig(
    "LargeBodyChurn: direct_alloc_minor_budget parses and validates", []() {
    HeapConfig d;
    TEST_ASSERT(d.direct_alloc_minor_budget == DIRECT_ALLOC_MINOR_BUDGET);

    auto rejects = [](double v) {
        HeapConfig c;
        c.direct_alloc_minor_budget = v;
        try {
            c.validate();
        } catch (const std::invalid_argument&) {
            return true;
        }
        return false;
    };
    TEST_ASSERT(rejects(-1.0));
    TEST_ASSERT(rejects(100.0));
    TEST_ASSERT(!rejects(0.0));
    TEST_ASSERT(!rejects(64.0));

#if !defined(_WIN32)
    char path[] = "/tmp/eco-large-body-cfg-XXXXXX";
    int fd = mkstemp(path);
    TEST_ASSERT(fd >= 0);
    const char* json = "{\"direct_alloc_minor_budget\": 2.5}";
    TEST_ASSERT(write(fd, json, std::strlen(json)) == static_cast<ssize_t>(std::strlen(json)));
    close(fd);
    HeapConfig j;
    applyHeapConfigJsonFile(j, path);
    unlink(path);
    TEST_ASSERT(j.direct_alloc_minor_budget == 2.5);
    j.validate();
#endif
});

// ----------------------------------------------------------------------------
// (f) Held body, churn during a cycle: the deferred bytes stay within
// max(F x live_ref, floor) plus one minor's direct allocation, and the cycle
// ends before its schedule. With F = 0 they do not: the control shows the test
// detects the unbounded deferral it guards against.
// ----------------------------------------------------------------------------

Testing::TestCase testDeferredFinishBoundsCycle(
    "LargeBodyChurn: a cycle's deferred large bodies stay bounded (HEAP_084)", []() {
    const HoldChurnRun on = runHoldChurn(holdChurnConfig(INCREMENTAL_MARK_DEFERRED_FINISH));
    TEST_ASSERT(on.budget > 0);
    TEST_ASSERT(on.bound > on.floor);   // the live estimate (the held list) sets the bound
    TEST_ASSERT(on.max_deferred <= on.bound + on.budget + kBodyBytes);
    TEST_ASSERT(on.span_minors <= on.slices);   // before the scheduled handoff at T + 1
#if ENABLE_GC_STATS
    {
        const IncrMarkStats& im = Allocator::instance().getCurrentThreadHeap()->getOldGen().getStats().im;
        TEST_ASSERT(im.finish_deferred >= 1);
        TEST_ASSERT(im.finish_deferred <= im.finish_pressure);
        TEST_ASSERT(im.deferred_bytes_at_finish_max >= on.bound);
    }
#endif

    const HoldChurnRun off = runHoldChurn(holdChurnConfig(0.0));
    TEST_ASSERT(off.max_deferred > on.bound + on.budget + kBodyBytes);
    TEST_ASSERT(off.span_minors == off.slices + 1);
#if ENABLE_GC_STATS
    TEST_ASSERT(Allocator::instance().getCurrentThreadHeap()->getOldGen().getStats().im.finish_deferred ==
                0);
#endif
});

// ----------------------------------------------------------------------------
// (g) Determinism (GC_DET_001): the finish reads only mutator state, so the
// same allocations finish their cycles at the same minors whether page work
// and marking run inline or on helper threads.
// ----------------------------------------------------------------------------

Testing::TestCase testDeferredFinishDeterministic(
    "LargeBodyChurn: the deferred-bytes finish is deterministic (GC_DET_001)", []() {
    HeapConfig inline_cfg = holdChurnConfig(INCREMENTAL_MARK_DEFERRED_FINISH);
    inline_cfg.gc_thread_mode = 0;
    inline_cfg.conc_mark = 0;
    inline_cfg.validate();
    HeapConfig threaded_cfg = holdChurnConfig(INCREMENTAL_MARK_DEFERRED_FINISH);
    threaded_cfg.gc_thread_mode = 2;
    threaded_cfg.conc_mark = 2;
    threaded_cfg.validate();

    const HoldChurnRun a = runHoldChurn(inline_cfg);
    const HoldChurnRun b = runHoldChurn(threaded_cfg);
    TEST_ASSERT(!a.finish_minors.empty());
    TEST_ASSERT(a.finish_minors == b.finish_minors);
    TEST_ASSERT(a.max_deferred == b.max_deferred);
});

// ----------------------------------------------------------------------------
// (h) The knobs: defaults, JSON round trip and validate() ranges.
// ----------------------------------------------------------------------------

Testing::TestCase testDeferredFinishConfig(
    "LargeBodyChurn: incremental_mark_deferred_finish / _floor parse and validate", []() {
    HeapConfig d;
    TEST_ASSERT(d.incremental_mark_deferred_finish == INCREMENTAL_MARK_DEFERRED_FINISH);
    TEST_ASSERT(d.incremental_mark_deferred_floor == INCREMENTAL_MARK_DEFERRED_FLOOR);

    auto rejects = [](double finish, double floor) {
        HeapConfig c;
        c.incremental_mark_deferred_finish = finish;
        c.incremental_mark_deferred_floor = floor;
        try {
            c.validate();
        } catch (const std::invalid_argument&) {
            return true;
        }
        return false;
    };
    TEST_ASSERT(!rejects(0.0, 1.0));
    TEST_ASSERT(!rejects(0.25, 1.0));
    TEST_ASSERT(!rejects(64.0, 1024.0));
    TEST_ASSERT(rejects(0.1, 1.0));
    TEST_ASSERT(rejects(-1.0, 1.0));
    TEST_ASSERT(rejects(65.0, 1.0));
    TEST_ASSERT(rejects(1.0, 0.5));
    TEST_ASSERT(rejects(1.0, 2000.0));

#if !defined(_WIN32)
    char path[] = "/tmp/eco-deferred-finish-cfg-XXXXXX";
    int fd = mkstemp(path);
    TEST_ASSERT(fd >= 0);
    const char* json =
        "{\"incremental_mark_deferred_finish\": 2.5, \"incremental_mark_deferred_floor\": 8}";
    TEST_ASSERT(write(fd, json, std::strlen(json)) == static_cast<ssize_t>(std::strlen(json)));
    close(fd);
    HeapConfig j;
    applyHeapConfigJsonFile(j, path);
    unlink(path);
    TEST_ASSERT(j.incremental_mark_deferred_finish == 2.5);
    TEST_ASSERT(j.incremental_mark_deferred_floor == 8.0);
    j.validate();
#endif
});
