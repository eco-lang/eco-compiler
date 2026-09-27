/**
 * threaded-gc-05c Part B (plans/threaded-gc-05c-concurrent-marking.md P§3.11):
 * heap-relative trigger pacing -- the promotion-rate estimate P_hat, the
 * Headroom trigger, the paced LiveBudget and the garbage-fraction backstop.
 * Every knob is off by default; decisions never read collector progress.
 */

#include "TriggerPacingTest.hpp"

#include <cstdio>
#include <cstdlib>
#include <stdexcept>
#include <string>
#include <vector>

#include "Allocator.hpp"
#include "AllocatorCommon.hpp"
#include "GCStats.hpp"
#include "Heap.hpp"
#include "HeapHelpers.hpp"
#include "OldGenSpace.hpp"
#include "TestHelpers.hpp"
#include "ThreadLocalHeap.hpp"

using namespace Elm;
using namespace Elm::TestHelpers;

namespace {

using OA = OldGenSpaceTestAccess;
using TR = OldGenSpace::MajorGCTriggerReason;
constexpr size_t KiB = 1024;
constexpr size_t MiB = 1024 * 1024;

// Every other trigger is parked so a single reason can be isolated.
HeapConfig pacingConfig() {
    HeapConfig cfg;
    cfg.alloc_buffer_size          = 32 * KiB;
    cfg.nursery_block_count        = 8;
    cfg.nursery_max_block_count    = 8;
    cfg.initial_old_gen_size       = 256 * KiB;
    cfg.max_heap_size              = 256ULL * MiB;
    cfg.large_object_threshold     = 8 * KiB;
    cfg.decommit_on_oldgen_release = false;
    cfg.gc_thread_mode             = 0;
    cfg.incremental_mark           = true;
    cfg.incremental_mark_slices    = 8;
    cfg.major_gc_initiating_occupancy = 0.99f;
    cfg.major_gc_global_pressure_fraction = 0.85f;
    cfg.major_gc_garbage_fraction  = 0.0f;
    cfg.major_gc_live_budget       = 0.0;
    cfg.major_gc_headroom_margin   = 0.0;   // on by default since E10; tests opt in
    cfg.validate();
    return cfg;
}

ThreadLocalHeap* tlh(Allocator& a) { return AllocatorTestAccess::getThreadHeap(a); }
OldGenSpace& og(Allocator& a) { return tlh(a)->getOldGen(); }

struct Root {
    Allocator& a;
    HPointer h;
    Root(Allocator& alloc, HPointer v) : a(alloc), h(v) { a.getRootSet().addRoot(&h); }
    ~Root() { a.getRootSet().removeRoot(&h); }
    Root(const Root&) = delete;
    Root& operator=(const Root&) = delete;
};

}  // namespace

Testing::TestCase testPromoRateEwmaDeterministic(
    "threaded-gc-05c: P_hat is the exact integer EWMA of old-gen bytes per minor",
    []() {
        auto& a = initAllocator(pacingConfig());
        OldGenSpace& o = og(a);
        o.notePacingMinorEnd();                    // align with the current total
        OA::setPromoRate(o, 0);
        int64_t expect = 0;
        for (int64_t sample : {800, 800, 0, 1600, 8, 123456, 0, 0, 7}) {
            OA::addOldAlloc(o, static_cast<uint64_t>(sample));
            o.notePacingMinorEnd();
            expect += (sample - expect) / 8;
            TEST_ASSERT(o.promoRateEstimate() == expect);
        }
    });

Testing::TestCase testOldAllocTotalMonotone(
    "threaded-gc-05c: the old-gen allocation total never decreases across GCs",
    []() {
        auto& a = initAllocator(pacingConfig());
        OldGenSpace& o = og(a);
        uint64_t prev = o.oldAllocTotal();
        bool alloc_dropped = false;
        for (int round = 0; round < 6; ++round) {
            {
                Root keep(a, alloc::listNil());
                for (int i = 0; i < 20000; ++i) {
                    keep.h = alloc::cons(alloc::boxed(alloc::allocInt(i)), keep.h, true);
                }
                a.minorGC();
                a.minorGC();
            }
            while (OA::cycleActive(o)) a.minorGC();
            const size_t before = OA::allocatedBytes(o);
            tlh(a)->test_force_major_trigger_ = true;
            a.minorGC();
            while (OA::cycleActive(o)) a.minorGC();
            TEST_ASSERT(o.oldAllocTotal() >= prev);
            prev = o.oldAllocTotal();
            if (OA::allocatedBytes(o) < before) alloc_dropped = true;
        }
        TEST_ASSERT(alloc_dropped);                // allocated_bytes is NOT monotone
        TEST_ASSERT(o.promoRateEstimate() > 0);
    });

Testing::TestCase testHeadroomTriggerThreshold(
    "threaded-gc-05c: Headroom fires exactly when committed + margin * H_c * P_hat reaches the line",
    []() {
        HeapConfig cfg = pacingConfig();
        cfg.major_gc_headroom_margin = 1.5;
        cfg.validate();
        auto& a = initAllocator(cfg);
        OldGenSpace& o = og(a);
        const double cap = static_cast<double>(a.getOldGenMaxBytes());
        const double com = static_cast<double>(a.getOldGenCommittedBytes());
        const double line = cfg.incremental_mark_finish_fraction * cap;
        const double per = 1.5 * static_cast<double>(o.pacingHorizonMinors());   // 1.5 * 9
        TEST_ASSERT(o.pacingHorizonMinors() == 9);
        const int64_t p_fire = static_cast<int64_t>((line - com) / per) + 2;
        OA::setPromoRate(o, p_fire);
        TEST_ASSERT(OA::trigger(o) == TR::Headroom);
        OA::setPromoRate(o, p_fire - 4);
        TEST_ASSERT(OA::trigger(o) == TR::None);
        // Off: never.
        HeapConfig off = pacingConfig();
        auto& b = initAllocator(off);
        OA::setPromoRate(og(b), p_fire * 10);
        TEST_ASSERT(OA::trigger(og(b)) == TR::None);
    });

Testing::TestCase testHeadroomFiresBeforePressure(
    "threaded-gc-05c: on a small cap, Headroom starts cycles before a pressure finish",
    []() {
        auto scenario = [](double margin, uint64_t* pressure, uint64_t* headroom) {
            HeapConfig cfg = pacingConfig();
            cfg.max_heap_size = 48ULL * MiB;
            cfg.nursery_region_bytes = 16ULL * MiB;
            // Committed settles near 60 % of the cap here (occupancy-driven
            // cycles), so these lines are inside the range the run visits.
            cfg.major_gc_global_pressure_fraction = 0.45f;
            cfg.incremental_mark_finish_fraction = 0.60;
            cfg.incremental_mark_slices = 16;
            cfg.major_gc_headroom_margin = margin;
            cfg.validate();
            auto& a = initAllocator(cfg);
            OldGenSpace& o = og(a);
#if ENABLE_GC_STATS
            const uint64_t p0 = o.getStats().im.finish_pressure;
            const uint64_t h0 = tlh(a)->getStats().major_gc_global_pressure_triggers;
#endif
            // A sliding window of retained data: steady promotion, bounded live.
            std::vector<std::unique_ptr<Root>> win;
            for (int step = 0; step < 400; ++step) {
                Root lst(a, alloc::listNil());
                for (int i = 0; i < 10000; ++i) {
                    lst.h = alloc::cons(alloc::boxed(alloc::allocInt(step * 10000 + i)), lst.h, true);
                }
                win.push_back(std::make_unique<Root>(a, lst.h));
                if (win.size() > 12) win.erase(win.begin());
                a.minorGC();
            }
            while (OA::cycleActive(o)) a.minorGC();
#if ENABLE_GC_STATS
            *pressure = o.getStats().im.finish_pressure - p0;
            *headroom = tlh(a)->getStats().major_gc_global_pressure_triggers - h0;
#else
            *pressure = *headroom = 0;
#endif
        };
        uint64_t pc = 0, hc = 0, pt = 0, ht = 0;
        scenario(0.0, &pc, &hc);
        scenario(1.5, &pt, &ht);
        std::printf("    (pressure finishes: control %llu, headroom %llu; pressure+headroom triggers %llu vs %llu)\n",
                    (unsigned long long)pc, (unsigned long long)pt,
                    (unsigned long long)hc, (unsigned long long)ht);
        TEST_ASSERT(pt <= pc);
    });

Testing::TestCase testPacedLiveBudgetFiresEarlierByHorizon(
    "threaded-gc-05c: the paced LiveBudget fires H_c * P_hat earlier",
    []() {
        for (bool paced : {false, true}) {
            HeapConfig cfg = pacingConfig();
            cfg.major_gc_live_budget = 4.0;
            cfg.live_growth_bound = 0.0;
            cfg.major_gc_live_budget_paced = paced;
            cfg.validate();
            auto& a = initAllocator(cfg);
            OldGenSpace& o = og(a);
            Root keep(a, alloc::listNil());
            for (int i = 0; i < 20000; ++i) keep.h = alloc::cons(alloc::boxed(alloc::allocInt(i)), keep.h, true);
            a.minorGC();
            a.minorGC();
            while (OA::cycleActive(o)) a.minorGC();
            const size_t alloc_now = OA::allocatedBytes(o);
            TEST_ASSERT(alloc_now > 4096);
            // alloc_since_major = alloc_now; budget * live = alloc_now + 1000.
            const size_t live = (alloc_now + 1000) / 4 + 1;
            OA::setLiveRefs(o, live, 0, 0);
            OA::setPromoRate(o, 200);        // H_c * P_hat = 9 * 200 = 1800 > 1000
            const TR r = OA::trigger(o);
            TEST_ASSERT(r == (paced ? TR::LiveBudget : TR::None));
            OA::setPromoRate(o, 50);         // 450 < 1000: not yet, paced or not
            TEST_ASSERT(OA::trigger(o) == TR::None);
        }
    });

Testing::TestCase testGarbageBackstop(
    "threaded-gc-05c: the garbage-fraction backstop raises the threshold while LiveBudget is on",
    []() {
        for (float backstop : {0.0f, 0.99f}) {
            HeapConfig cfg = pacingConfig();
            cfg.major_gc_garbage_fraction = 0.01f;
            cfg.major_gc_live_budget = 1000.0;     // on, but far from firing
            cfg.major_gc_garbage_backstop = backstop;
            cfg.validate();
            auto& a = initAllocator(cfg);
            OldGenSpace& o = og(a);
            Root keep(a, alloc::listNil());
            for (int i = 0; i < 20000; ++i) keep.h = alloc::cons(alloc::boxed(alloc::allocInt(i)), keep.h, true);
            a.minorGC();
            a.minorGC();
            while (OA::cycleActive(o)) a.minorGC();
            // alloc_since_major / committed = allocated / committed, in [0.01, 0.99).
            OA::setLiveRefs(o, 1ull << 40, 0, 0);
            const double frac = static_cast<double>(OA::allocatedBytes(o)) /
                                static_cast<double>(o.getCommittedBytes());
            TEST_ASSERT(frac >= 0.01 && frac < 0.99);
            TEST_ASSERT(OA::trigger(o) == (backstop > 0.0f ? TR::None : TR::GarbageFraction));
        }
    });

Testing::TestCase testPacingIgnoresMarkProgress(
    "threaded-gc-05c: paced triggers decide identically in mode 0 and mode 2 (+ jitter)",
    []() {
        auto scenario = [](uint32_t mode) {
            HeapConfig cfg = pacingConfig();
            cfg.max_heap_size = 64ULL * MiB;
            cfg.nursery_region_bytes = 16ULL * MiB;
            cfg.major_gc_live_budget = 3.0;
            cfg.live_growth_bound = 1.5;
            cfg.major_gc_live_budget_paced = true;
            cfg.major_gc_headroom_margin = 1.5;
            cfg.gc_mark_threads = 2;
            cfg.conc_mark = mode;
            cfg.conc_mark_threads = 1;
            cfg.conc_mark_priority = 0;
            cfg.validate();
            auto& a = initAllocator(cfg);
            OldGenSpace& o = og(a);
            std::vector<uint64_t> starts;
            std::vector<std::unique_ptr<Root>> win;
            bool was = false;
            uint64_t minors = 0;
            for (int step = 0; step < 300; ++step) {
                Root lst(a, alloc::listNil());
                for (int i = 0; i < 2000; ++i) {
                    lst.h = alloc::cons(alloc::boxed(alloc::allocInt(step * 10000 + i)), lst.h, true);
                }
                win.push_back(std::make_unique<Root>(a, lst.h));
                if (win.size() > 20) win.erase(win.begin());
                a.minorGC();
                ++minors;
                const bool now = OA::cycleActive(o);
                if (now && !was) starts.push_back(minors);
                was = now;
            }
            starts.push_back(static_cast<uint64_t>(o.promoRateEstimate()));
            starts.push_back(o.oldAllocTotal());
            return starts;
        };
        const char* old = std::getenv("ECO_GC_HELPER_JITTER_US");
        const std::string saved = old ? old : "";
        const char* oldm = std::getenv("ECO_GC_CONC_MARK");
        const std::string savedm = oldm ? oldm : "";
        unsetenv("ECO_GC_CONC_MARK");
        const auto ref = scenario(0);
        TEST_ASSERT(ref.size() > 3);                     // cycles happened
        TEST_ASSERT(scenario(2) == ref);
        setenv("ECO_GC_HELPER_JITTER_US", "50", 1);
        const auto jit = scenario(2);
        if (old) setenv("ECO_GC_HELPER_JITTER_US", saved.c_str(), 1);
        else unsetenv("ECO_GC_HELPER_JITTER_US");
        if (oldm) setenv("ECO_GC_CONC_MARK", savedm.c_str(), 1);
        TEST_ASSERT(jit == ref);
    });
