/**
 * threaded-gc-07b (plans/threaded-gc-07b-tenure-ageing.md Step 8): tenure
 * age k > 1 in the region nursery. An object copied into the fill at minor j
 * ages in place and is tenured at minor j + k only if live then; the job's mark
 * over the ageing extents decides liveness (no nepotism) and the merge zaps
 * the dead. Oracle: the legacy nursery with promotion_age = k, on a fixed
 * minor schedule (legacy's to-space holds its ageing objects, so its eden
 * allotment differs and a trigger-driven schedule would not match).
 */

#include "TenureAgeingTest.hpp"

#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

#include "Allocator.hpp"
#include "AllocatorCommon.hpp"
#include "HeapHelpers.hpp"
#include "MinorWorkload.hpp"
#include "NurserySpace.hpp"
#include "OldGenSpace.hpp"
#include "TestHelpers.hpp"
#include "ThreadLocalHeap.hpp"

using namespace Elm;
using namespace Elm::TestHelpers;

namespace {

using NTA = NurserySpaceTestAccess;

// 4 MiB extents: a fixed-schedule workload never fills eden between the
// explicit minors, in either nursery.
HeapConfig ageConfig(uint32_t regions, uint32_t k, uint32_t threads = 1, uint32_t mode = 1,
                     uint32_t help_threads = 1) {
    HeapConfig cfg;
    cfg.alloc_buffer_size          = 32 * 1024;
    cfg.nursery_block_count        = 256;
    cfg.nursery_max_block_count    = 256;
    cfg.initial_old_gen_size       = 256 * 1024;
    cfg.max_heap_size              = 1024ULL * 1024 * 1024;
    cfg.large_object_threshold     = 8 * 1024;
    cfg.large_ptr_nursery_max_size = 8 * 1024;
    cfg.decommit_on_oldgen_release = false;
    cfg.old_gen_bitmap_alloc       = true;
    cfg.gc_thread_mode             = 0;
    cfg.gc_minor_threads           = threads;
    cfg.minor_lab_bytes            = 4096;
    cfg.minor_parallel_min_bytes   = 0;
    cfg.promotion_age              = k;
    cfg.nursery_regions            = regions;
    cfg.tenure_mode                = mode;
    cfg.tenure_help                = 1;
    cfg.tenure_help_threads        = help_threads;
    cfg.validate();
    return cfg;
}

ThreadLocalHeap* heapOf(Allocator& a) { return AllocatorTestAccess::getThreadHeap(a); }
NurserySpace& nurseryOf(Allocator& a) { return heapOf(a)->getNursery(); }
OldGenSpace& oldgenOf(Allocator& a) { return heapOf(a)->getOldGen(); }
RegionState& regionOf(Allocator& a) { return *NTA::region(nurseryOf(a)); }

bool young(Allocator& a, HPointer hp) {
    return NTA::contains(nurseryOf(a), AllocatorTestAccess::fromPointer(hp));
}
// The walk of p's survivor extent: true when p lies inside a zap filler
// (the merge writes one filler per dead gap, so p's own header may survive).
bool zapped(Allocator& a, void* p) {
    RegionState& R = regionOf(a);
    const int i = R.extentOf(p);
    if (i < 0) TEST_FAIL("not in a survivor extent");
    const region::Extent& X = R.x[i];
    for (char* q = X.base; q < X.surv_top;) {
        const size_t sz = getObjectSize(q);
        if (static_cast<char*>(p) >= q && static_cast<char*>(p) < q + sz) return getHeader(q)->tag == Tag_Free;
        q += sz;
    }
    TEST_FAIL("address outside the survivor part");
}

int64_t intOf(HPointer hp) {
    return static_cast<ElmInt*>(AllocatorTestAccess::fromPointer(hp))->value;
}

struct Run {
    uint64_t checksum = 0, survived = 0, promoted = 0, minors = 0, prom_by_tag = 0;
    uint64_t late = 0, stops = 0, marked = 0, zapped = 0, layout_hash = 0, layout_n = 0, par_marks = 0;
    uint64_t zapped_bytes = 0;   // object class (spans are layout class: adjacent dead objects merge)
};

// A fixed schedule: one minor every `every` workload steps.
Run runScript(const HeapConfig& cfg, uint64_t seed, size_t minors, size_t every,
              uint64_t stop_after = 0, uint64_t sleep_us = 0) {
    auto& a = cfg.nursery_regions == 0 ? initAllocator(cfg) : initRegionAllocator(cfg);
    NurserySpace& ns = nurseryOf(a);
    const bool regions = ns.regionMode();
    if (regions) {
        ns.test_record_layout_ = true;
        ns.test_layout_.clear();
        ns.test_tenure_force_stop_after_ = stop_after;
        ns.test_tenure_sleep_us_ = sleep_us;
    }
    Run r;
    {
        minortest::Workload w(a, 64, seed);
        for (size_t g = 0; g < minors; ++g) {
            w.run(every);
            a.minorGC();
            if (g % 16 == 15) r.checksum = r.checksum * 31 + w.checksum();
        }
        r.checksum = r.checksum * 31 + w.checksum();
    }
    if (regions) {
        NTA::tenureFlush(ns, oldgenOf(a));
        ns.test_tenure_force_stop_after_ = 0;
        ns.test_tenure_sleep_us_ = 0;
        ns.test_record_layout_ = false;
        uint64_t h = 1469598103934665603ull;
        for (uintptr_t x : ns.test_layout_) { h ^= x; h *= 1099511628211ull; }
        r.layout_hash = h;
        r.layout_n = ns.test_layout_.size();
        ns.test_layout_.clear();
    }
#if ENABLE_GC_STATS
    const GCStats& st = ns.getStats();
    r.survived = st.objects_survived;
    r.promoted = st.objects_promoted;
    r.minors = st.minor_gc_count;
    for (int i = 0; i < GCStats::NUM_ALLOC_TAGS; ++i) r.prom_by_tag = r.prom_by_tag * 1000003 + st.promoted_bytes_by_tag[i];
    r.late = st.rg.late;
    r.stops = st.rg.stops;
    r.marked = st.rg.age_marked;
    r.zapped = st.rg.zapped;
    r.par_marks = st.rg.age_par_marks;
    r.zapped_bytes = st.rg.zapped_bytes;
#endif
    return r;
}

// Every arm from the same parent state (the root set's hash order).
Run runInChild(const HeapConfig& cfg, uint64_t seed, size_t minors, size_t every,
               uint64_t stop_after = 0, uint64_t sleep_us = 0) {
    int fds[2];
    if (pipe(fds) != 0) TEST_FAIL("pipe");
    const pid_t pid = fork();
    if (pid == 0) {
        close(fds[0]);
        const Run r = runScript(cfg, seed, minors, every, stop_after, sleep_us);
        (void)!write(fds[1], &r, sizeof r);
        _exit(0);
    }
    close(fds[1]);
    Run r;
    const ssize_t got = read(fds[0], &r, sizeof r);
    close(fds[0]);
    int status = 0;
    waitpid(pid, &status, 0);
    if (got != static_cast<ssize_t>(sizeof r) || !WIFEXITED(status) || WEXITSTATUS(status) != 0)
        TEST_FAIL("child run failed");
    return r;
}

void dump(const char* what, const Run& x, const Run& y) {
    std::fprintf(stderr, "%s: checksum %d promoted %llu/%llu minors %llu/%llu tags %d survived %llu/%llu "
                 "layout %llu/%llu same %d marked %llu zapped %llu\n", what,
                 (int)(x.checksum == y.checksum), (unsigned long long)x.promoted, (unsigned long long)y.promoted,
                 (unsigned long long)x.minors, (unsigned long long)y.minors, (int)(x.prom_by_tag == y.prom_by_tag),
                 (unsigned long long)x.survived, (unsigned long long)y.survived,
                 (unsigned long long)x.layout_n, (unsigned long long)y.layout_n,
                 (int)(x.layout_hash == y.layout_hash), (unsigned long long)x.marked,
                 (unsigned long long)x.zapped);
}

bool childAborts(uint32_t k, const std::function<void(Allocator&)>& arm) {
    const pid_t pid = fork();
    if (pid == 0) {
        auto& a = initRegionAllocator(ageConfig(1, k));
        arm(a);
        minortest::Workload w(a, 64, 5);
        for (int g = 0; g < 120; ++g) {
            w.run(40);
            a.minorGC();
            (void)w.checksum();
        }
        _exit(0);
    }
    int status = 0;
    if (waitpid(pid, &status, 0) != pid) return false;
    return WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT;
}

}  // namespace

Testing::TestCase testAgeOracleLegacy(
    "threaded-gc-07b: E1: region promotion_age k tenures what legacy promotion_age k promotes (k 1-3; 1, 4 workers)",
    []() {
        for (uint32_t k : {1u, 2u, 3u}) {
            for (uint32_t n : {1u, 4u}) {
                const Run ref = runInChild(ageConfig(0, k, n), 61 + k, 240, 20);
                const Run r = runInChild(ageConfig(1, k, n), 61 + k, 240, 20);
                const bool ok = r.checksum == ref.checksum && r.promoted == ref.promoted &&
                                r.minors == ref.minors && r.prom_by_tag == ref.prom_by_tag;
                if (!ok) {
                    std::fprintf(stderr, "k=%u n=%u\n", k, n);
                    dump("oracle", r, ref);
                    TEST_FAIL("region ageing does not tenure what legacy promotes");
                }
#if ENABLE_GC_STATS
                TEST_ASSERT(ref.minors == 240);   // the schedule is the explicit one
                TEST_ASSERT(ref.promoted > 0);
                if (k > 1) TEST_ASSERT(r.marked > 0 && r.zapped > 0);   // non-vacuous
                if (k > 1) TEST_ASSERT(r.survived < ref.survived);      // no re-copies
#endif
            }
        }
    });

Testing::TestCase testAgeLifetime(
    "threaded-gc-07b: an object live through j minors after its first copy is tenured iff j >= k",
    []() {
        for (uint32_t k : {1u, 2u, 3u}) {
            for (uint32_t j = 0; j <= 4; ++j) {
                auto& a = initRegionAllocator(ageConfig(1, k));
                const uint64_t t0 = regionOf(a).rs.tenured;
                HPointer x = alloc::allocInt(1000 + j);
                a.getRootSet().addRoot(&x);
                a.minorGC();                          // the first copy (minor 1)
                for (uint32_t i = 0; i < j; ++i) a.minorGC();
                a.getRootSet().removeRoot(&x);
                x = alloc::listNil();
                for (int i = 0; i < 6; ++i) a.minorGC();   // everything handed over and merged
                const uint64_t tenured = regionOf(a).rs.tenured - t0;
                if (tenured != (j >= k ? 1u : 0u)) {
                    std::fprintf(stderr, "k=%u j=%u tenured %llu\n", k, j, (unsigned long long)tenured);
                    TEST_FAIL("wrong tenure decision for a j-minor lifetime");
                }
            }
        }
    });

Testing::TestCase testAgeNoNepotismAndZap(
    "threaded-gc-07b: a dead ageing holder does not tenure its target; the merge zaps it; a live one does",
    []() {
        for (bool keep : {false, true}) {
            auto& a = initRegionAllocator(ageConfig(1, 3));
            RegionState& R = regionOf(a);
            const uint64_t t0 = R.rs.tenured;
            HPointer x = alloc::allocInt(77);
            HPointer h = alloc::listNil();
            a.getRootSet().addRoot(&x);
            a.getRootSet().addRoot(&h);
            a.minorGC();                                              // minor 1: x -> G_1
            h = alloc::tuple2(alloc::boxed(x), alloc::boxed(alloc::allocInt(5)), 0);
            x = alloc::listNil();
            a.minorGC();                                              // minor 2: h -> G_2 (x ages)
            void* h_addr = AllocatorTestAccess::fromPointer(h);
            TEST_ASSERT(young(a, h));
            if (!keep) h = alloc::listNil();
            a.minorGC();                                              // 3: no hand-over yet (k = 3)
            a.minorGC();                                              // 4: G_1 handed over; job 4 marks G_2, G_3
            TEST_ASSERT(!zapped(a, h_addr));                          // not zapped before the merge
            a.minorGC();                                              // 5: merge of job 4: heal, zap
            if (!keep) {
                TEST_ASSERT(zapped(a, h_addr));                       // inside a zap filler
            } else {
                TEST_ASSERT(!zapped(a, h_addr) && getHeader(h_addr)->tag == Tag_Tuple2);
                TEST_ASSERT(intOf(static_cast<Tuple2*>(AllocatorTestAccess::fromPointer(h))->a.p) == 77);
            }
            a.minorGC();
            a.minorGC();
            const uint64_t tenured = R.rs.tenured - t0;
            if (!keep) {
                TEST_ASSERT(tenured == 0);   // neither x (nepotism) nor h
            } else {
                // x (through h's healed slot) and h (and h's Int field).
                TEST_ASSERT(tenured == 3);
                TEST_ASSERT(!young(a, h));
                Tuple2* t = static_cast<Tuple2*>(AllocatorTestAccess::fromPointer(h));
                TEST_ASSERT(!young(a, t->a.p) && intOf(t->a.p) == 77);
            }
            a.getRootSet().removeRoot(&x);
            a.getRootSet().removeRoot(&h);
        }
    });

Testing::TestCase testAgeHealThroughMark(
    "threaded-gc-07b: a live ageing holder's slot names the tenured copy after the merge (k = 3)",
    []() {
        auto& a = initRegionAllocator(ageConfig(1, 3));
        HPointer x = alloc::allocInt(4242);
        HPointer h = alloc::listNil();
        a.getRootSet().addRoot(&x);
        a.getRootSet().addRoot(&h);
        a.minorGC();                                  // 1: x -> G_1
        h = alloc::tuple2(alloc::boxed(x), alloc::boxed(alloc::allocInt(1)), 0);
        x = alloc::listNil();
        a.minorGC();                                  // 2: h -> G_2
        a.minorGC();                                  // 3
        a.minorGC();                                  // 4: G_1 handed over; the mark finds h's slot
        TEST_ASSERT(young(a, h));
        Tuple2* t = static_cast<Tuple2*>(AllocatorTestAccess::fromPointer(h));
        TEST_ASSERT(young(a, t->a.p));                // not healed until the merge
        a.minorGC();                                  // 5: merge heals h.a; G_2 handed over
        t = static_cast<Tuple2*>(AllocatorTestAccess::fromPointer(h));
        TEST_ASSERT(!young(a, t->a.p));
        TEST_ASSERT(intOf(t->a.p) == 4242);
#if ENABLE_GC_STATS
        TEST_ASSERT(regionOf(a).rs.age_heal >= 1);
#endif
        a.minorGC();
        a.minorGC();
        TEST_ASSERT(!young(a, h));
        t = static_cast<Tuple2*>(AllocatorTestAccess::fromPointer(h));
        TEST_ASSERT(intOf(t->a.p) == 4242);
        a.getRootSet().removeRoot(&x);
        a.getRootSet().removeRoot(&h);
    });

Testing::TestCase testAgeYoungLarge(
    "threaded-gc-07b: a YLOS object ages with its generation: promoted in place if live at k, freed if not",
    []() {
        for (bool keep : {true, false}) {
            auto& a = initRegionAllocator(ageConfig(1, 3));
            OldGenSpace& og = oldgenOf(a);
            HPointer y = alloc::listNil();
            HPointer h = alloc::listNil();
            a.getRootSet().addRoot(&y);
            a.getRootSet().addRoot(&h);
            {
                std::vector<HPointer> e(1500);   // 12 KB of pointers: over the region cap -> YLOS
                for (size_t i = 0; i < e.size(); ++i) e[i] = alloc::allocInt(static_cast<i64>(i));
                y = alloc::arrayFromPointers(e);
            }
            void* y_addr = AllocatorTestAccess::fromPointer(y);
            TEST_ASSERT(og.isYoungLarge(y_addr));
            a.minorGC();                                              // 1: y joins generation 1
            h = alloc::tuple2(alloc::boxed(y), alloc::boxed(alloc::allocInt(3)), 0);
            y = alloc::listNil();
            a.minorGC();                                              // 2: h -> G_2 (y: age source)
            if (!keep) h = alloc::listNil();
            for (int i = 0; i < 5; ++i) a.minorGC();                  // hand-over at 4, merge at 5
            if (keep) {
                Tuple2* t = static_cast<Tuple2*>(AllocatorTestAccess::fromPointer(h));
                void* yy = AllocatorTestAccess::fromPointer(t->a.p);
                TEST_ASSERT(yy == y_addr);                            // promoted in place
                TEST_ASSERT(!og.isYoungLarge(yy));
                ElmArray* arr = static_cast<ElmArray*>(yy);
                TEST_ASSERT(arr->length == 1500);
                TEST_ASSERT(intOf(arr->elements[1499].p) == 1499);
                TEST_ASSERT(!young(a, arr->elements[7].p));           // its children were tenured
            } else {
                TEST_ASSERT(!og.isYoungLarge(y_addr));                // freed at the hand-over
#if ENABLE_GC_STATS
                TEST_ASSERT(regionOf(a).rs.ylos_gen_freed >= 1);
#endif
            }
            a.getRootSet().removeRoot(&y);
            a.getRootSet().removeRoot(&h);
        }
    });

Testing::TestCase testAgeModesAgree(
    "threaded-gc-07b: at k = 2, 3 mode 2 (with forced stops) reproduces mode 1: every counter and placement",
    []() {
        for (uint32_t k : {2u, 3u}) {
            const Run m1 = runInChild(ageConfig(1, k, 1, 1), 71, 200, 25);
            for (uint64_t stop : {0ull, 1ull, 97ull}) {
                const Run m2 = runInChild(ageConfig(1, k, 1, 2), 71, 200, 25, stop);
                const bool ok = m2.checksum == m1.checksum && m2.promoted == m1.promoted &&
                                m2.survived == m1.survived && m2.minors == m1.minors &&
                                m2.layout_hash == m1.layout_hash && m2.layout_n == m1.layout_n &&
                                m2.marked == m1.marked && m2.zapped == m1.zapped;
                if (!ok) {
                    std::fprintf(stderr, "k=%u stop=%llu\n", k, (unsigned long long)stop);
                    dump("modes", m2, m1);
                    TEST_FAIL("ageing mode 2 differs from mode 1");
                }
            }
        }
    });

Testing::TestCase testAgeLateHelpParallel(
    "threaded-gc-07b: a slowed ageing job is finished by help on 4 workers (the mark too); objects equal",
    []() {
        const Run m1 = runScript(ageConfig(1, 2, 1, 1), 81, 120, 25);
        const Run slow = runScript(ageConfig(1, 2, 1, 2, 4), 81, 120, 25, 0, 20);
        if (!(slow.checksum == m1.checksum && slow.promoted == m1.promoted &&
              slow.survived == m1.survived && slow.minors == m1.minors && slow.marked == m1.marked &&
              slow.zapped_bytes == m1.zapped_bytes)) {
            dump("help", slow, m1);
            dump("help-ref", m1, slow);
            TEST_FAIL("help with the parallel engine changed the ageing job's objects");
        }
#if ENABLE_GC_STATS
        TEST_ASSERT(slow.late > 0);
        TEST_ASSERT(slow.par_marks > 0);   // non-vacuous: the gang finished a mark
#endif
    });

Testing::TestCase testAgeNegativeControls(
    "threaded-gc-07b: a skipped zap (TV2Y) is caught; the unbroken control survives",
    []() {
        TEST_ASSERT(!childAborts(2, [](Allocator&) {}));
        TEST_ASSERT(!childAborts(3, [](Allocator&) {}));
#if ECO_HEAP_VALIDATE
        TEST_ASSERT(childAborts(2, [](Allocator& a) { nurseryOf(a).test_skip_zap_ = true; }));
#endif
    });
