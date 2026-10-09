/**
 * threaded-gc-06 (plans/threaded-gc-06-parallel-minor.md): parallel minor GC
 * (HEAP_067) and object-byte nursery accounting (HEAP_068). Configs are
 * programmatic: a unit test's heap ignores ECO_GC_* after the first
 * Allocator::initialize, so every test pins gc_minor_threads in its config.
 */

#include "ParallelMinorTest.hpp"

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#if defined(_WIN32)
#include <filesystem>
#include <random>
#else
#include <unistd.h>
#endif

#include "Allocator.hpp"
#include "AllocatorCommon.hpp"
#include "GCHelperPool.hpp"
#include "HeapConfigJson.hpp"
#include "OldGenSpace.hpp"
#include "TestHelpers.hpp"
#include "ThreadLocalHeap.hpp"
#include "HeapHelpers.hpp"
#include "MinorWorkload.hpp"
#include "NurserySpace.hpp"

#if !defined(_WIN32)
#include <sys/wait.h>
#endif
#include <csignal>
#include <functional>

using namespace Elm;
using namespace Elm::TestHelpers;

namespace {

std::string writeTempJson(const std::string& body) {
#if defined(_WIN32)
    // No mkstemp: a random name in the temp directory.
    const std::string path = (std::filesystem::temp_directory_path() /
                              ("eco-minor-cfg-" + std::to_string(std::random_device{}()) + ".json"))
                                 .string();
    std::ofstream out(path, std::ios::binary);
    out << body;
    TEST_ASSERT(out.good());
    return path;
#else
    char path[] = "/tmp/eco-minor-cfg-XXXXXX";
    const int fd = mkstemp(path);
    TEST_ASSERT(fd >= 0);
    TEST_ASSERT(write(fd, body.data(), body.size()) == static_cast<ssize_t>(body.size()));
    close(fd);
    return path;
#endif
}

}  // namespace

Testing::TestCase testMinorThreadsConfigParse(
    "threaded-gc-06: gc_minor_threads parses from JSON and env; 0 = auto honours the cap",
    []() {
        HeapConfig c;
        TEST_ASSERT(c.gc_minor_threads == GC_MINOR_THREADS);
        const std::string p = writeTempJson(
            "{\"gc_minor_threads\": 6, \"gc_minor_threads_cap\": 3, \"minor_lab_bytes\": \"8K\","
            " \"minor_parallel_min_bytes\": \"1M\", \"minor_prefetch_children\": true}");
        applyHeapConfigJsonFile(c, p.c_str());
        std::remove(p.c_str());
        c.validate();
        TEST_ASSERT(c.gc_minor_threads == 6);
        TEST_ASSERT(c.gc_minor_threads_cap == 3);
        TEST_ASSERT(c.minor_lab_bytes == 8 * 1024);
        TEST_ASSERT(c.minor_parallel_min_bytes == 1024 * 1024);
        TEST_ASSERT(c.minor_prefetch_children);
        applyMinorThreadsEnv(c, "4");                 // env wins over JSON
        TEST_ASSERT(c.gc_minor_threads == 4);
        applyMinorThreadsEnv(c, nullptr);             // unset: unchanged
        TEST_ASSERT(c.gc_minor_threads == 4);
        bool threw = false;
        try { applyMinorThreadsEnv(c, "65"); } catch (const std::invalid_argument&) { threw = true; }
        TEST_ASSERT(threw);
        threw = false;
        try { applyMinorThreadsEnv(c, "x"); } catch (const std::invalid_argument&) { threw = true; }
        TEST_ASSERT(threw);
        // Resolution: explicit, auto with the cap, bitmap allocation off.
        c.old_gen_bitmap_alloc = true;
        TEST_ASSERT(OldGenSpace::resolveMinorThreads(c) == 4);
        c.gc_minor_threads = 0;
        TEST_ASSERT(OldGenSpace::resolveMinorThreads(c) == std::min(3u, gc::availableCpus()));
        c.old_gen_bitmap_alloc = false;
        TEST_ASSERT(OldGenSpace::resolveMinorThreads(c) == 1);
        // Validation.
        HeapConfig bad;
        bad.minor_lab_bytes = 1000;
        threw = false;
        try { bad.validate(); } catch (const std::invalid_argument&) { threw = true; }
        TEST_ASSERT(threw);
    });

Testing::TestCase testGangSizedForMinorAndMark(
    "threaded-gc-06: the gang is sized for max(gc_mark_threads, gc_minor_threads)",
    []() {
        HeapConfig cfg = pressureHeapConfig();
        // The allocator reserves its heap at the FIRST initialize of the
        // process; keep every phase-6 test on the same roomy reservation.
        cfg.max_heap_size = 512ULL * 1024 * 1024;
        cfg.gc_mark_threads = 2;
        cfg.gc_minor_threads = 6;
        cfg.validate();
        auto& a = initLegacyAllocator(cfg);
        OldGenSpace& og = AllocatorTestAccess::getThreadHeap(a)->getOldGen();
        TEST_ASSERT(og.minorThreads() == 6);
        gc::GCMarkGang& g = og.ensureGang();
        TEST_ASSERT(g.configured() && g.members() >= 6);
    });

// ============================================================================
// The parallel engine (Steps 5-6)
// ============================================================================

namespace {

using NTA = NurserySpaceTestAccess;
using OA = OldGenSpaceTestAccess;

// 1 MiB per nursery side (room for N LABs), a roomy old gen, 4 KiB LABs, no
// serial threshold. `threads` pins gc_minor_threads (the env is ignored after
// the first initialize of the test binary).
HeapConfig minorConfig(uint32_t threads) {
    HeapConfig cfg;
    cfg.alloc_buffer_size          = 32 * 1024;
    cfg.nursery_block_count        = 64;
    cfg.nursery_max_block_count    = 64;
    cfg.initial_old_gen_size       = 256 * 1024;
    cfg.max_heap_size              = 512ULL * 1024 * 1024;
    cfg.large_object_threshold     = 8 * 1024;
    cfg.decommit_on_oldgen_release = false;
    cfg.old_gen_bitmap_alloc       = true;
    cfg.gc_thread_mode             = 0;
    cfg.gc_minor_threads           = threads;
    cfg.minor_lab_bytes            = 4096;
    cfg.minor_parallel_min_bytes   = 0;
    if (const char* cm = std::getenv("ECO_TEST_CONC_MARK")) cfg.conc_mark = static_cast<uint32_t>(std::atoi(cm));
    cfg.validate();
    return cfg;
}

ThreadLocalHeap* heapOf(Allocator& a) { return AllocatorTestAccess::getThreadHeap(a); }
NurserySpace& nurseryOf(Allocator& a) { return heapOf(a)->getNursery(); }

// Threads 0 = the serial path; 1 = the forced one-worker engine; > 1 parallel.
Allocator& initMinor(uint32_t threads) {
    auto& a = initLegacyAllocator(minorConfig(threads == 0 ? 1 : threads));
    nurseryOf(a).test_force_parallel_engine_ = threads == 1;
    return a;
}

struct Counts {
    uint64_t checksum = 0, survived = 0, promoted = 0, minors = 0, parallel = 0, fillers = 0;
    uint64_t surv_by_tag = 0, prom_by_tag = 0;
};

Counts workloadCounts(uint32_t threads, uint64_t seed, size_t steps) {
    auto& a = initMinor(threads);
    Counts c;
    {
        minortest::Workload w(a, 128, seed);
        w.run(steps);
        a.minorGC();
        c.checksum = w.checksum();
    }
#if ENABLE_GC_STATS
    const GCStats& st = nurseryOf(a).getStats();
    c.survived = st.objects_survived;
    c.promoted = st.objects_promoted;
    c.minors = st.minor_gc_count;
    c.parallel = st.pmin.minors_parallel;
    c.fillers = st.pmin.filler_bytes_total;
    for (int i = 0; i < GCStats::NUM_ALLOC_TAGS; ++i) {
        c.surv_by_tag = c.surv_by_tag * 1000003 + st.survived_bytes_by_tag[i];
        c.prom_by_tag = c.prom_by_tag * 1000003 + st.promoted_bytes_by_tag[i];
    }
#endif
    nurseryOf(a).test_force_parallel_engine_ = false;
    return c;
}

int64_t sumIntList(HPointer l) {
    int64_t s = 0;
    while (l.ptr_ind == 0 && l.ptr != 0) {
        Cons* c = static_cast<Cons*>(AllocatorTestAccess::fromPointer(l));
        HPointer h = c->head.p;
        s += static_cast<ElmInt*>(AllocatorTestAccess::fromPointer(h))->value;
        l = c->tail;
    }
    return s;
}

}  // namespace

Testing::TestCase testEngineMatchesSerialObjectCounters(
    "threaded-gc-06: the parallel engine reproduces the serial object counters (1..8 workers)",
    []() {
        for (uint64_t seed : {11ull, 12ull}) {
            const Counts ref = workloadCounts(0, seed, 80000);
            TEST_ASSERT(ref.parallel == 0);
            for (uint32_t n : {1u, 2u, 4u, 8u}) {
                const Counts c = workloadCounts(n, seed, 80000);
                if (c.checksum != ref.checksum || c.survived != ref.survived ||
                    c.promoted != ref.promoted || c.minors != ref.minors ||
                    c.surv_by_tag != ref.surv_by_tag || c.prom_by_tag != ref.prom_by_tag) {
                    std::fprintf(stderr, "n=%u seed=%llu: survived %llu/%llu promoted %llu/%llu "
                                 "minors %llu/%llu checksum %d\n", n, (unsigned long long)seed,
                                 (unsigned long long)c.survived, (unsigned long long)ref.survived,
                                 (unsigned long long)c.promoted, (unsigned long long)ref.promoted,
                                 (unsigned long long)c.minors, (unsigned long long)ref.minors,
                                 (int)(c.checksum == ref.checksum));
                    TEST_FAIL("object counters differ from the serial reference");
                }
#if ENABLE_GC_STATS
                TEST_ASSERT(c.parallel > 0);          // non-vacuous: the engine ran
                TEST_ASSERT(ref.minors > 10);
#endif
            }
        }
    });

Testing::TestCase testEngineLongListRuns(
    "threaded-gc-06: a 100,000-cell list survives in spine runs (1, 4 workers)",
    []() {
        for (uint32_t n : {1u, 4u}) {
            auto& a = initMinor(n);
            HPointer l = alloc::listNil();
            a.getRootSet().addRoot(&l);
            int64_t expect = 0;
            for (int64_t i = 0; i < 100000; ++i) {
                const HPointer x = alloc::allocInt(i);
                l = alloc::cons(alloc::boxed(x), l, true);
                expect += i;
            }
            a.minorGC();
            TEST_ASSERT(sumIntList(l) == expect);
#if ENABLE_GC_STATS
            TEST_ASSERT(nurseryOf(a).getStats().pmin.spine_splits > 0);
#endif
            a.minorGC();   // promoted now
            TEST_ASSERT(sumIntList(l) == expect);
            TEST_ASSERT(!NTA::contains(nurseryOf(a), AllocatorTestAccess::fromPointer(l)));
            a.getRootSet().removeRoot(&l);
            nurseryOf(a).test_force_parallel_engine_ = false;
        }
    });

Testing::TestCase testEngineSharedTailList(
    "threaded-gc-06: two lists sharing a 1,000-cell tail keep one tail (4 workers)",
    []() {
        auto& a = initMinor(4);
        HPointer tail = alloc::listNil(), l1 = alloc::listNil(), l2 = alloc::listNil();
        a.getRootSet().addRoot(&tail);
        a.getRootSet().addRoot(&l1);
        a.getRootSet().addRoot(&l2);
        for (int i = 0; i < 1000; ++i) { const HPointer x = alloc::allocInt(i); tail = alloc::cons(alloc::boxed(x), tail, true); }
        l1 = tail; l2 = tail;
        for (int i = 0; i < 500; ++i) { const HPointer x = alloc::allocInt(1); l1 = alloc::cons(alloc::boxed(x), l1, true); }
        for (int i = 0; i < 700; ++i) { const HPointer x = alloc::allocInt(2); l2 = alloc::cons(alloc::boxed(x), l2, true); }
        tail = alloc::listNil();
        for (int g = 0; g < 3; ++g) {
            a.minorGC();
            // Walk to the shared part of each list: the same cell.
            HPointer p1 = l1, p2 = l2;
            for (int i = 0; i < 500; ++i) p1 = static_cast<Cons*>(AllocatorTestAccess::fromPointer(p1))->tail;
            for (int i = 0; i < 700; ++i) p2 = static_cast<Cons*>(AllocatorTestAccess::fromPointer(p2))->tail;
            TEST_ASSERT(AllocatorTestAccess::fromPointer(p1) == AllocatorTestAccess::fromPointer(p2));
            TEST_ASSERT(sumIntList(l1) == 500 + 499500);
            TEST_ASSERT(sumIntList(l2) == 1400 + 499500);
        }
        a.getRootSet().removeRoot(&tail);
        a.getRootSet().removeRoot(&l1);
        a.getRootSet().removeRoot(&l2);
    });

Testing::TestCase testEngineChunkedArray(
    "threaded-gc-06: a 16,000-element boxed array is scanned in chunks (4 workers)",
    []() {
        auto& a = initMinor(4);
        std::vector<HPointer> elems(16000, alloc::listNil());
        HPointer arr = alloc::listNil();
        {
            StackRootRangeGuard guard(elems.data(), elems.size(), ~uint64_t{0});
            for (size_t i = 0; i < elems.size(); ++i) elems[i] = alloc::allocInt(static_cast<i64>(i));
            arr = alloc::arrayFromPointers(elems);
        }
        a.getRootSet().addRoot(&arr);
#if ENABLE_GC_STATS
        const uint64_t ch0 = nurseryOf(a).getStats().pmin.chunks;
#endif
        a.minorGC();
        a.minorGC();
        ElmArray* ar = static_cast<ElmArray*>(AllocatorTestAccess::fromPointer(arr));
        TEST_ASSERT(ar->length == 16000);
        for (u32 i = 0; i < ar->length; ++i)
            TEST_ASSERT(static_cast<ElmInt*>(AllocatorTestAccess::fromPointer(ar->elements[i].p))->value == static_cast<i64>(i));
#if ENABLE_GC_STATS
        TEST_ASSERT(nurseryOf(a).getStats().pmin.chunks > ch0);
#endif
        a.getRootSet().removeRoot(&arr);
    });

// Reads back a Tag_String or a split-header (LargeStringHeader) string.
static std::u16string readU16(HPointer hp) {
    void* o = AllocatorTestAccess::fromPointer(hp);
    Header* h = getHeader(o);
    TEST_ASSERT(h->tag == Tag_String || h->tag == Tag_LargeStringHeader);
    // flatStringChars reads a split body raw (plans/large-object-space.md D4).
    return std::u16string(reinterpret_cast<const char16_t*>(flatStringChars(o)), h->size);
}

Testing::TestCase testEngineLargeBodies(
    "threaded-gc-06: split-header strings survive and promote in a parallel minor",
    []() {
        auto& a = initMinor(4);
        std::u16string big(40000, u'x');
        for (size_t i = 0; i < big.size(); i += 97) big[i] = static_cast<char16_t>(u'a' + (i % 26));
        HPointer s1 = alloc::allocString(big);
        a.getRootSet().addRoot(&s1);
        HPointer s2 = alloc::allocString(big + u"y");
        a.getRootSet().addRoot(&s2);
        const uint32_t tag0 = getHeader(AllocatorTestAccess::fromPointer(s1))->tag;
        for (int g = 0; g < 4; ++g) {
            for (int i = 0; i < 20000; ++i) (void)alloc::allocInt(i);   // churn: survive -> promote
            a.minorGC();
            TEST_ASSERT(getHeader(AllocatorTestAccess::fromPointer(s1))->tag == tag0);
            TEST_ASSERT(readU16(s1) == big);
            TEST_ASSERT(readU16(s2) == big + u"y");
        }
        a.getRootSet().removeRoot(&s1);
        a.getRootSet().removeRoot(&s2);
    });

Testing::TestCase testEngineBuilderStaysYoung(
    "threaded-gc-06: a builder object survives parallel minors young (age 0)",
    []() {
        auto& a = initMinor(4);
        HPointer b = alloc::allocArrayBuilder(16);
        a.getRootSet().addRoot(&b);
        for (int g = 0; g < 3; ++g) {
            for (int i = 0; i < 20000; ++i) (void)alloc::allocInt(i);
            a.minorGC();
            void* o = AllocatorTestAccess::fromPointer(b);
            TEST_ASSERT(NTA::contains(nurseryOf(a), o));
            TEST_ASSERT(getHeader(o)->builder == 1 && getHeader(o)->age == 0);
        }
        alloc::clear_builder(getHeader(AllocatorTestAccess::fromPointer(b)));
        a.getRootSet().removeRoot(&b);
    });

Testing::TestCase testParMinorStealing(
    "threaded-gc-06: a single wide root is shared by stealing (4 workers)",
    []() {
        auto& a = initMinor(4);
        std::vector<HPointer> elems(50000, alloc::listNil());
        HPointer arr = alloc::listNil();
        {
            StackRootRangeGuard guard(elems.data(), elems.size(), ~uint64_t{0});
            for (size_t i = 0; i < elems.size(); ++i) {
                const HPointer x = alloc::allocInt(static_cast<i64>(i));
                elems[i] = alloc::tuple2(alloc::boxed(x), alloc::boxed(x), 0);
            }
            arr = alloc::arrayFromPointers(elems);
        }
        a.getRootSet().addRoot(&arr);
#if ENABLE_GC_STATS
        const uint64_t st0 = nurseryOf(a).getStats().pmin.steals;
        a.minorGC();
        TEST_ASSERT(nurseryOf(a).getStats().pmin.steals > st0);
#else
        a.minorGC();
#endif
        ElmArray* ar = static_cast<ElmArray*>(AllocatorTestAccess::fromPointer(arr));
        for (u32 i = 0; i < ar->length; ++i) {
            Tuple2* t = static_cast<Tuple2*>(AllocatorTestAccess::fromPointer(ar->elements[i].p));
            TEST_ASSERT(static_cast<ElmInt*>(AllocatorTestAccess::fromPointer(t->a.p))->value == static_cast<i64>(i));
            TEST_ASSERT(t->a.p.ptr == t->b.p.ptr);   // one copy, shared
        }
        a.getRootSet().removeRoot(&arr);
    });

Testing::TestCase testParMinorFallbackSpace(
    "threaded-gc-06: a minor whose survivors could overflow LAB slack runs serially",
    []() {
        HeapConfig cfg = minorConfig(4);
        cfg.minor_lab_bytes = 256 * 1024;      // 4 x 256 KiB of LABs > a 1 MiB side's slack
        cfg.validate();
        auto& a = initLegacyAllocator(cfg);
#if ENABLE_GC_STATS
        const uint64_t s0 = nurseryOf(a).getStats().pmin.serial_space;
        for (int i = 0; i < 200000; ++i) (void)alloc::allocInt(i);
        a.minorGC();
        TEST_ASSERT(nurseryOf(a).getStats().pmin.serial_space > s0);
        TEST_ASSERT(NTA::fillerBytes(nurseryOf(a)) == 0);
#endif
    });

Testing::TestCase testParMinorFallbackSmall(
    "threaded-gc-06: below minor_parallel_min_bytes a minor runs serially",
    []() {
        HeapConfig cfg = minorConfig(4);
        cfg.minor_parallel_min_bytes = 64ULL * 1024 * 1024;
        cfg.validate();
        auto& a = initLegacyAllocator(cfg);
#if ENABLE_GC_STATS
        const uint64_t s0 = nurseryOf(a).getStats().pmin.serial_small;
        const uint64_t p0 = nurseryOf(a).getStats().pmin.minors_parallel;
        for (int i = 0; i < 1000; ++i) (void)alloc::allocInt(i);
        a.minorGC();
        TEST_ASSERT(nurseryOf(a).getStats().pmin.serial_small > s0);
        TEST_ASSERT(nurseryOf(a).getStats().pmin.minors_parallel == p0);
#endif
    });

Testing::TestCase testParMinorFillersParse(
    "threaded-gc-06: after a parallel minor the survivor prefix parses and counts object bytes",
    []() {
        auto& a = initMinor(8);
        minortest::Workload w(a, 256, 99);
        for (int g = 0; g < 20; ++g) {
            w.run(3000);
            a.minorGC();
            size_t bytes = 0;
            const size_t n = nurseryOf(a).forEachSurvivor([](void* o) {
                TEST_ASSERT(getHeader(o)->tag != Tag_Free);
            }, &bytes);
            TEST_ASSERT(bytes == NTA::objectBytesAllocated(nurseryOf(a)));
            (void)n;
        }
#if ENABLE_GC_STATS
        TEST_ASSERT(nurseryOf(a).getStats().pmin.minors_parallel > 0);
#endif
        (void)w.checksum();
    });

Testing::TestCase testParMinorForkChild(
    "threaded-gc-06: a forked child runs parallel minors",
    []() {
#if !defined(_WIN32)
        auto& a = initMinor(4);
        for (int i = 0; i < 50000; ++i) (void)alloc::allocInt(i);
        a.minorGC();
        const pid_t pid = fork();
        if (pid == 0) {
            int ok = 1;
            try {
                minortest::Workload w(a, 64, 5);
                w.run(20000);
                a.minorGC();
                (void)w.checksum();
            } catch (...) { ok = 0; }
            _exit(ok ? 0 : 3);
        }
        int status = 0;
        TEST_ASSERT(waitpid(pid, &status, 0) == pid);
        TEST_ASSERT(WIFEXITED(status) && WEXITSTATUS(status) == 0);
#endif
    });

namespace {
// A workload with a forced mark cycle every 15 minors and 2 background
// markers (conc_mark 2): parallel minors promote (allocate-black) while
// background markers run.
uint64_t cycleWorkload(uint32_t threads, uint64_t* cycles_out) {
    HeapConfig cfg = minorConfig(threads == 0 ? 1 : threads);
    cfg.incremental_mark = true;
    cfg.incremental_mark_slices = 6;
    cfg.incremental_mark_min_slice_units = 64;
    cfg.gc_mark_threads = 2;
    cfg.conc_mark = 2;
    cfg.conc_mark_threads = 2;
    cfg.conc_mark_assist_lag = 1;
    cfg.validate();
    auto& a = initLegacyAllocator(cfg);
    nurseryOf(a).test_force_parallel_engine_ = threads == 1;
    ThreadLocalHeap* h = heapOf(a);
    uint64_t sum = 0, cycles = 0;
    {
        minortest::Workload w(a, 128, 77);
        for (int g = 0; g < 90; ++g) {
            w.run(2500);
            if (g % 15 == 0 && !OA::cycleActive(h->getOldGen())) {
                h->test_force_major_trigger_ = true;
                ++cycles;
            }
            a.minorGC();
            if (g % 10 == 0) sum = sum * 31 + w.checksum();
        }
        while (OA::cycleActive(h->getOldGen())) a.minorGC();
        sum = sum * 31 + w.checksum();
    }
    nurseryOf(a).test_force_parallel_engine_ = false;
    if (cycles_out) *cycles_out = cycles;
    return sum;
}
}  // namespace

Testing::TestCase testParMinorDuringCycle(
    "threaded-gc-06: parallel minors under a running concurrent mark cycle keep every value",
    []() {
        uint64_t cycles = 0;
        const uint64_t ref = cycleWorkload(0, &cycles);
        TEST_ASSERT(cycles >= 5);
        for (uint32_t n : {1u, 4u}) TEST_ASSERT(cycleWorkload(n, nullptr) == ref);
    });

// ============================================================================
// Negative controls (Step 7, P§3.13): each broken invariant must be caught by
// its validator. Validate builds only; each runs in a forked child and must
// die by SIGABRT.
// ============================================================================

namespace {
#if ECO_HEAP_VALIDATE && !defined(_WIN32)
bool childAborts(const std::function<void(Allocator&)>& arm) {
    const pid_t pid = fork();
    if (pid == 0) {
        auto& a = initMinor(4);
        arm(a);
        minortest::Workload w(a, 128, 3);
        for (int g = 0; g < 30; ++g) {
            w.run(4000);
            a.minorGC();
        }
        _exit(0);   // survived: the validator did not fire
    }
    int status = 0;
    if (waitpid(pid, &status, 0) != pid) return false;
    return WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT;
}
#endif
}  // namespace

Testing::TestCase testParMinorNegativeControls(
    "threaded-gc-06: PM1 / PM3 / PM4 fire on a double copy, a missing filler, a kept cursor",
    []() {
#if ECO_HEAP_VALIDATE && !defined(_WIN32)
        TEST_ASSERT(childAborts([](Allocator& a) { nurseryOf(a).test_minor_double_copy_every_ = 997; }));
        TEST_ASSERT(childAborts([](Allocator& a) { nurseryOf(a).test_minor_skip_filler_ = true; }));
        TEST_ASSERT(childAborts([](Allocator& a) {
            OA::setKeepWorkerCursor(heapOf(a)->getOldGen(), true);
        }));
        // And the unbroken control survives.
        TEST_ASSERT(!childAborts([](Allocator&) {}));
#endif
    });
