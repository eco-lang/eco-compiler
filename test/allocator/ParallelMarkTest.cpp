/**
 * threaded-gc-05b (plans/threaded-gc-05b-parallel-marking.md): parallel
 * marking (HEAP_064). Configs are programmatic (the old gen of a unit test
 * ignores ECO_HEAP_CONFIG); gc_mark_threads is set per test. The mark gang is
 * (re)configured on demand by OldGenSpace::runMarkers.
 */

#include "ParallelMarkTest.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <random>
#include <stdexcept>
#include <thread>
#include <vector>

#if !defined(_WIN32)
#include <fcntl.h>
#include <sched.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

#include "Allocator.hpp"
#include "AllocatorCommon.hpp"
#include "GCHelperPool.hpp"
#include "GCStats.hpp"
#include "Heap.hpp"
#include "HeapConfigJson.hpp"
#include "HeapHelpers.hpp"
#include "MarkWork.hpp"
#include "OldGenSpace.hpp"
#include "TestHelpers.hpp"
#include "ThreadLocalHeap.hpp"

using namespace Elm;
using namespace Elm::TestHelpers;

namespace {

std::vector<uint64_t>& lastSeq() {
    static std::vector<uint64_t> v;
    return v;
}

using OA = OldGenSpaceTestAccess;
using CS = OldGenSpace::CycleState;
constexpr size_t KiB = 1024;
constexpr size_t MiB = 1024 * 1024;

HeapConfig parConfig(uint32_t threads, uint32_t slices = 4, uint32_t divisor = 8) {
    HeapConfig cfg;
    cfg.alloc_buffer_size          = 32 * KiB;
    cfg.nursery_block_count        = 8;
    cfg.nursery_max_block_count    = 8;
    cfg.initial_old_gen_size       = 256 * KiB;
    cfg.max_heap_size              = 512ULL * MiB;
    cfg.large_object_threshold     = 8 * KiB;
    cfg.large_ptr_nursery_divisor  = divisor;
    cfg.decommit_on_oldgen_release = false;
    cfg.gc_thread_mode             = 0;
    cfg.incremental_mark           = true;
    cfg.incremental_mark_slices    = slices;
    cfg.incremental_mark_min_slice_units = 64;
    cfg.gc_mark_threads            = threads;
    // threaded-gc-05c: these tests drive the 05b in-pause marker directly
    // (runMarkers, slice-by-slice units), so they pin conc_mark = 0; the test
    // switch ECO_TEST_CONC_MARK overrides it for the scenarios that allow it.
    cfg.conc_mark                  = 0;
    if (const char* cm = std::getenv("ECO_TEST_CONC_MARK")) {
        cfg.conc_mark = static_cast<uint32_t>(std::atoi(cm));
    }
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

void runToHandoff(Allocator& a) {
    for (int g = 0; OA::cycleActive(og(a)); ++g) {
        if (g > 100000) throw std::runtime_error("cycle never handed off");
        a.minorGC();
    }
}
void startCycle(Allocator& a) {
    runToHandoff(a);
    tlh(a)->test_force_major_trigger_ = true;
    a.minorGC();
}

i64 intValue(Allocator& a, HPointer hp) {
    void* obj = a.resolve(hp);
    if (!obj || getHeader(obj)->tag != Tag_Int) throw std::runtime_error("expected an Int");
    return static_cast<ElmInt*>(obj)->value;
}

// A deterministic random graph of `n` old Tuple2 nodes (children: earlier
// nodes or fresh Ints). Returns the node addresses in creation order, after
// promotion; `roots` (rooted by the caller) keep a random subset reachable.
std::vector<void*> buildGraph(Allocator& a, size_t n, uint64_t seed,
                              std::vector<HPointer>& roots, size_t n_roots) {
    std::mt19937_64 rng(seed);
    Root list(a, alloc::listNil());
    std::vector<HPointer> nodes;   // rebuilt from the list after each GC
    // Build as a cons list so everything stays rooted while building.
    for (size_t i = 0; i < n; ++i) {
        HPointer x, y;
        {
            // Pick children from the most recent 64 list cells (cheap walk).
            HPointer c = list.h;
            const size_t kx = rng() % 64, ky = rng() % 64;
            x = alloc::listNil();
            y = alloc::listNil();
            for (size_t k = 0; k < 64 && !alloc::isNil(c); ++k) {
                Cons* cell = static_cast<Cons*>(a.resolve(c));
                if (k == kx) x = cell->head.p;
                if (k == ky) y = cell->head.p;
                c = cell->tail;
            }
        }
        if (alloc::isNil(x)) x = alloc::allocInt(static_cast<i64>(i));
        Root rx(a, x);
        Root ry(a, alloc::isNil(y) ? alloc::allocInt(-static_cast<i64>(i)) : y);
        HPointer t = alloc::tuple2(alloc::boxed(rx.h), alloc::boxed(ry.h), 0);
        list.h = alloc::cons(alloc::boxed(t), list.h, true);
    }
    a.minorGC();
    a.minorGC();
    std::vector<void*> addrs;
    for (HPointer c = list.h; !alloc::isNil(c);) {
        Cons* cell = static_cast<Cons*>(a.resolve(c));
        nodes.push_back(cell->head.p);
        addrs.push_back(a.resolve(cell->head.p));
        c = cell->tail;
    }
    if (a.isInNursery(addrs.front())) throw std::runtime_error("graph not promoted");
    roots.clear();
    for (size_t r = 0; r < n_roots; ++r) roots.push_back(nodes[rng() % nodes.size()]);
    return addrs;
}

struct MarkRecord {
    std::vector<uint8_t> marked;
    std::vector<uint64_t> units_after_slice;
    uint64_t traced = 0;
    size_t major_live = 0, post_sweep = 0;
    bool operator==(const MarkRecord& o) const {
        return marked == o.marked && units_after_slice == o.units_after_slice &&
               traced == o.traced && major_live == o.major_live && post_sweep == o.post_sweep;
    }
};

// Builds the graph, runs `cycles` T = 4 cycles, records the first cycle's
// per-slice units and mark bits at HandoffDue, and the policy numbers after
// the last.
MarkRecord graphScenario(uint32_t threads, size_t n, int cycles = 1) {
    auto& a = initAllocator(parConfig(threads));
    std::vector<HPointer> roots;
    std::vector<void*> addrs = buildGraph(a, n, 1234, roots, 40);
    for (auto& r : roots) a.getRootSet().addRoot(&r);
    MarkRecord rec;
    for (int c = 0; c < cycles; ++c) {
        startCycle(a);
        while (OA::cycleState(og(a)) == CS::Marking) {
            a.minorGC();
            if (c == 0) rec.units_after_slice.push_back(OA::cycleUnits(og(a)));
        }
        if (c == 0) {
            for (void* p : addrs) rec.marked.push_back(OA::isMarked(og(a), p) ? 1 : 0);
            rec.traced = OA::markLiveSum(og(a));
        }
        runToHandoff(a);
    }
    rec.major_live = OA::majorLive(og(a));
    rec.post_sweep = OA::postSweepLive(og(a));
    for (auto& r : roots) a.getRootSet().removeRoot(&r);
    return rec;
}

#if !defined(_WIN32)
int runInChild(const std::function<int()>& fn) {
    std::fflush(stdout);
    std::fflush(stderr);
    pid_t pid = fork();
    if (pid == 0) {
        if (std::getenv("ECO_TEST_CHILD_STDERR") == nullptr) {
            int fd = open("/dev/null", O_WRONLY);
            if (fd >= 0) dup2(fd, 2);
        }
        int rc = 3;
        try {
            rc = fn();
        } catch (...) {
            rc = 4;
        }
        _exit(rc);
    }
    int st = 0;
    waitpid(pid, &st, 0);
    return st;
}
#endif

}  // namespace

// ============================================================================
// The std-only core
// ============================================================================

Testing::TestCase testMarkEntryEncoding(
    "threaded-gc-05b: mark entry encoding round-trips",
    []() {
        using namespace markwork;
        // A synthetic heap-range address (entries only encode, never deref).
        void* p = reinterpret_cast<void*>(uintptr_t{0x10000001000});
        const uint64_t e = objEntry(p, 12345);
        TEST_ASSERT(!isChunk(e) && entryAddr(e) == p && entryField(e) == 12345);
        TEST_ASSERT(entryField(objEntry(p, kFieldMax + 1)) == 0);   // overflow -> unknown
        const uint64_t c = chunkEntry(p, 77);
        TEST_ASSERT(isChunk(c) && entryAddr(c) == p && entryField(c) == 77);
        TEST_ASSERT(e != kEmpty && c != kEmpty && e != kAbort && c != kAbort);
    });

Testing::TestCase testDequeLifoOwnerFifoThief(
    "threaded-gc-05b: deque is LIFO for the owner, FIFO for a thief",
    []() {
        markwork::WorkStealingDeque d(4);
        for (uint64_t v = 1; v <= 5; ++v) d.push(v);
        TEST_ASSERT(d.steal() == 1);
        TEST_ASSERT(d.take() == 5);
        TEST_ASSERT(d.steal() == 2);
        TEST_ASSERT(d.take() == 4);
        TEST_ASSERT(d.take() == 3);
        TEST_ASSERT(d.take() == markwork::kEmpty);
        TEST_ASSERT(d.steal() == markwork::kEmpty);
        d.reset();
    });

Testing::TestCase testDequeGrowKeepsEntries(
    "threaded-gc-05b: deque growth keeps every entry (1 M, take + steal)",
    []() {
        markwork::WorkStealingDeque d(4);
        const uint64_t n = 1000000;
        for (uint64_t v = 1; v <= n; ++v) d.push(v);
        TEST_ASSERT(d.grows() >= 10);
        std::vector<uint8_t> seen(n + 1, 0);
        uint64_t got = 0;
        for (uint64_t k = 0;; ++k) {
            const uint64_t e = (k & 1) ? d.steal() : d.take();
            if (e == markwork::kEmpty) {
                if (d.emptyApprox()) break;
                continue;
            }
            TEST_ASSERT(e >= 1 && e <= n && seen[e] == 0);
            seen[e] = 1;
            ++got;
        }
        TEST_ASSERT(got == n);
        d.retireOldArrays();
    });

Testing::TestCase testGangRunsEveryMemberOnce(
    "threaded-gc-05b: GCMarkGang runs every member exactly once per run",
    []() {
        auto& g = gc::GCMarkGang::instance();
        if (g.configured()) g.shutdownForTesting();
        g.configure(8, 0);
        struct Ctx { std::atomic<uint32_t> hits[8]; } ctx;
        for (unsigned n = 1; n <= 8; ++n) {
            for (int r = 0; r < 1000; ++r) {
                for (auto& h : ctx.hits) h.store(0);
                g.run([](void* c, unsigned i) { static_cast<Ctx*>(c)->hits[i].fetch_add(1); },
                      &ctx, n);
                for (unsigned i = 0; i < 8; ++i)
                    TEST_ASSERT(ctx.hits[i].load() == (i < n ? 1u : 0u));
            }
        }
        g.shutdownForTesting();
    });

Testing::TestCase testGangForkChild(
    "threaded-gc-05b: a forked child can run the gang",
    []() {
#if !defined(_WIN32)
        auto& g = gc::GCMarkGang::instance();
        if (g.configured()) g.shutdownForTesting();
        g.configure(4, 0);
        std::atomic<uint32_t> hits{0};
        g.run([](void* c, unsigned) { static_cast<std::atomic<uint32_t>*>(c)->fetch_add(1); },
              &hits, 4);
        TEST_ASSERT(hits.load() == 4);
        const int st = runInChild([]() -> int {
            std::atomic<uint32_t> h{0};
            gc::GCMarkGang::instance().run(
                [](void* c, unsigned) { static_cast<std::atomic<uint32_t>*>(c)->fetch_add(1); },
                &h, 4);
            return h.load() == 4 ? 0 : 1;
        });
        TEST_ASSERT(WIFEXITED(st) && WEXITSTATUS(st) == 0);
        g.shutdownForTesting();
#endif
    });

Testing::TestCase testMarkThreadsConfig(
    "threaded-gc-05b: gc_mark_threads JSON, env and validation",
    []() {
        HeapConfig def;
        TEST_ASSERT(def.gc_mark_threads == GC_MARK_THREADS);
        TEST_ASSERT(def.gc_mark_threads_cap == GC_MARK_THREADS_CAP);
        HeapConfig a;
        applyMarkThreadsEnv(a, "6");
        TEST_ASSERT(a.gc_mark_threads == 6);
        bool threw = false;
        try { applyMarkThreadsEnv(a, "65"); } catch (const std::invalid_argument&) { threw = true; }
        TEST_ASSERT(threw);
        threw = false;
        try { applyMarkThreadsEnv(a, "x"); } catch (const std::invalid_argument&) { threw = true; }
        TEST_ASSERT(threw);
        HeapConfig b;
        b.gc_mark_threads_cap = 0;
        threw = false;
        try { b.validate(); } catch (const std::invalid_argument&) { threw = true; }
        TEST_ASSERT(threw);
        // Bitmap allocation off: always serial.
        HeapConfig c;
        c.old_gen_bitmap_alloc = false;
        c.incremental_mark = false;
        c.gc_mark_threads = 8;
        TEST_ASSERT(OldGenSpace::resolveMarkThreads(c) == 1);
    });

Testing::TestCase testParMarkAutoThreadCount(
    "threaded-gc-05b: auto marker count = min(cap, available CPUs)",
    []() {
        HeapConfig c;
        c.gc_mark_threads = 0;
        c.gc_mark_threads_cap = 64;
        TEST_ASSERT(OldGenSpace::resolveMarkThreads(c) == std::min(64u, gc::availableCpus()));
        c.gc_mark_threads_cap = 3;
        TEST_ASSERT(OldGenSpace::resolveMarkThreads(c) == std::min(3u, gc::availableCpus()));
        c.gc_mark_threads = 5;
        TEST_ASSERT(OldGenSpace::resolveMarkThreads(c) == 5);   // explicit wins over the cap
#if defined(__linux__)
        cpu_set_t old;
        CPU_ZERO(&old);
        TEST_ASSERT(sched_getaffinity(0, sizeof old, &old) == 0);
        if (CPU_COUNT(&old) >= 2) {
            cpu_set_t two;
            CPU_ZERO(&two);
            int added = 0;
            for (int cpu = 0; cpu < CPU_SETSIZE && added < 2; ++cpu) {
                if (CPU_ISSET(cpu, &old)) { CPU_SET(cpu, &two); ++added; }
            }
            TEST_ASSERT(sched_setaffinity(0, sizeof two, &two) == 0);
            const unsigned got = gc::availableCpus();
            sched_setaffinity(0, sizeof old, &old);
            TEST_ASSERT(got == 2);
        }
#endif
    });

// ============================================================================
// Chunking
// ============================================================================

Testing::TestCase testMarkChunkedArrayAllChildren(
    "threaded-gc-05b: a 100,000-element array is marked through chunk entries",
    []() {
        for (uint32_t threads : {1u, 4u}) {
            auto& a = initAllocator(parConfig(threads, 4, /*divisor=*/0));
            const size_t n = 100000;
            std::vector<HPointer> elems(n, alloc::listNil());
            HPointer arr_h;
            {
                StackRootRangeGuard guard(elems.data(), elems.size(), ~uint64_t{0});
                for (size_t i = 0; i < n; ++i) elems[i] = alloc::allocInt(static_cast<i64>(i) * 3);
                const size_t total = sizeof(ElmArray) + n * sizeof(Unboxable);
                ElmArray* a0 = static_cast<ElmArray*>(a.allocate(total, Tag_Array));
                a0->header.size = static_cast<u32>(n);
                a0->length = 0;
                a0->padding = 0;
                a0->header.unboxed = 0;
                for (size_t i = 0; i < n; ++i) alloc::arrayPush(a0, alloc::boxed(elems[i]), true);
                arr_h = a.wrap(a0);
            }
            Root arr(a, arr_h);
            a.minorGC();
            a.minorGC();
            a.minorGC();                                 // promoted (in place, YLOS)
            TEST_ASSERT(!og(a).isYoungLarge(a.resolve(arr.h)));
#if ENABLE_GC_STATS
            const uint64_t chunks0 = og(a).getStats().pm.chunks_pushed;
#endif
            startCycle(a);
            while (OA::cycleState(og(a)) == CS::Marking) a.minorGC();
            ElmArray* ap = static_cast<ElmArray*>(a.resolve(arr.h));
            for (size_t i = 0; i < n; i += 997)
                TEST_ASSERT(OA::isMarked(og(a), a.resolve(ap->elements[i].p)));
            TEST_ASSERT(OA::isMarked(og(a), a.resolve(ap->elements[n - 1].p)));
#if ENABLE_GC_STATS
            TEST_ASSERT(og(a).getStats().pm.chunks_pushed - chunks0 == (n + 1023) / 1024 - 1);
#endif
            runToHandoff(a);
            TEST_ASSERT(intValue(a, static_cast<ElmArray*>(a.resolve(arr.h))->elements[n - 1].p) ==
                        static_cast<i64>(n - 1) * 3);
        }
    });

Testing::TestCase testMarkChunkedListBacking(
    "threaded-gc-05b: a long list backing with hd > 0 is marked through chunks",
    []() {
        auto& a = initAllocator(parConfig(4, 4, /*divisor=*/0));
        const u32 cap = 5000, hd = 300;
        Root lb(a, alloc::listBacking(cap, 0));
        static_cast<ListBacking*>(a.resolve(lb.h))->hd = hd;
        for (u32 i = hd; i < cap; ++i) {
            HPointer v = alloc::allocInt(static_cast<i64>(i));
            static_cast<ListBacking*>(a.resolve(lb.h))->elems[i] = alloc::boxed(v);
        }
        a.minorGC();
        a.minorGC();
        a.minorGC();
        startCycle(a);
        while (OA::cycleState(og(a)) == CS::Marking) a.minorGC();
        ListBacking* p = static_cast<ListBacking*>(a.resolve(lb.h));
        for (u32 i = hd; i < cap; i += 101)
            TEST_ASSERT(OA::isMarked(og(a), a.resolve(p->elems[i].p)));
        TEST_ASSERT(OA::isMarked(og(a), a.resolve(p->elems[cap - 1].p)));
        runToHandoff(a);
        p = static_cast<ListBacking*>(a.resolve(lb.h));
        TEST_ASSERT(intValue(a, p->elems[cap - 1].p) == static_cast<i64>(cap - 1));
    });

Testing::TestCase testMarkChunkBudgetSplitsArray(
    "threaded-gc-05b: chunks spread over slices; the handoff stays at t0 + T + 1",
    []() {
        HeapConfig cfg = parConfig(2, 6, /*divisor=*/0);
        cfg.incremental_mark_min_slice_units = 10;
        cfg.validate();
        auto& a = initAllocator(cfg);
        std::vector<HPointer> elems(40000, alloc::listNil());
        HPointer arr_h;
        {
            StackRootRangeGuard guard(elems.data(), elems.size(), ~uint64_t{0});
            for (size_t i = 0; i < elems.size(); ++i) elems[i] = alloc::allocInt(static_cast<i64>(i));
            const size_t total = sizeof(ElmArray) + elems.size() * sizeof(Unboxable);
            ElmArray* a0 = static_cast<ElmArray*>(a.allocate(total, Tag_Array));
            a0->header.size = static_cast<u32>(elems.size());
            a0->length = 0;
            a0->padding = 0;
            a0->header.unboxed = 0;
            for (auto& e : elems) alloc::arrayPush(a0, alloc::boxed(e), true);
            arr_h = a.wrap(a0);
        }
        Root arr(a, arr_h);
        a.minorGC();
        a.minorGC();
        a.minorGC();
        startCycle(a);
        for (uint32_t k = 1; k <= 6; ++k) {
            a.minorGC();
            TEST_ASSERT(OA::cycleK(og(a)) == k);
        }
        TEST_ASSERT(OA::cycleState(og(a)) == CS::HandoffDue);
        a.minorGC();
        TEST_ASSERT(!OA::cycleActive(og(a)));
    });

// ============================================================================
// Parallel marking: equivalence and determinism
// ============================================================================

Testing::TestCase testParMarkMatchesSerial(
    "threaded-gc-05b: 4 markers mark exactly what 1 marks, slice by slice",
    []() {
        const MarkRecord serial = graphScenario(1, 60000);
        const MarkRecord par = graphScenario(4, 60000);
        TEST_ASSERT(serial.units_after_slice == par.units_after_slice);
        TEST_ASSERT(serial.marked == par.marked);
        TEST_ASSERT(serial.traced == par.traced);
        size_t n_marked = 0;
        for (uint8_t m : serial.marked) n_marked += m;
        TEST_ASSERT(n_marked > 0 && n_marked < serial.marked.size());   // not vacuous
    });

Testing::TestCase testParMarkUnitsExactPerSlice(
    "threaded-gc-05b: a run consumes exactly min(budget, remaining) at any N",
    []() {
        std::vector<uint64_t> ref;
        for (uint32_t threads : {1u, 2u, 3u, 8u}) {
            auto& a = initAllocator(parConfig(threads, 64));
            std::vector<HPointer> roots;
            buildGraph(a, 40000, 99, roots, 30);
            for (auto& r : roots) a.getRootSet().addRoot(&r);
            startCycle(a);
            std::vector<uint64_t> seq;
            const int64_t budgets[] = {1, 7, 1000, 1, 250, 1000000000};
            for (int64_t b : budgets) seq.push_back(OA::runMarkers(og(a), b));
            TEST_ASSERT(OA::markStackEmpty(og(a)));
            if (threads == 1) {
                ref = seq;
                TEST_ASSERT(ref[0] == 1 && ref[1] == 7 && ref[2] == 1000);
            } else {
                TEST_ASSERT(seq == ref);
            }
            runToHandoff(a);
            for (auto& r : roots) a.getRootSet().removeRoot(&r);
        }
    });

Testing::TestCase testParMarkDeterministicAcrossThreadCounts(
    "threaded-gc-05b: three cycles are bit-identical at 1, 2, 3, 8 markers and with jitter",
    []() {
        const MarkRecord ref = graphScenario(1, 30000, 3);
        for (uint32_t threads : {2u, 3u, 8u}) {
            TEST_ASSERT(graphScenario(threads, 30000, 3) == ref);
        }
    });

Testing::TestCase testParMarkResumesAcrossSlices(
    "threaded-gc-05b: work left in several deques is resumed by later runs",
    []() {
        auto& a = initAllocator(parConfig(4, 64));
        std::vector<HPointer> roots;
        buildGraph(a, 40000, 5, roots, 30);
        for (auto& r : roots) a.getRootSet().addRoot(&r);
        startCycle(a);
        int runs = 0;
        uint64_t total = 0;
        while (!OA::markStackEmpty(og(a))) {
            const uint64_t u = OA::runMarkers(og(a), 500);
            TEST_ASSERT(u <= 500);
            total += u;
            TEST_ASSERT(++runs < 100000);
        }
        TEST_ASSERT(runs > 3 && total > 0);
        runToHandoff(a);
        for (auto& r : roots) a.getRootSet().removeRoot(&r);
    });

Testing::TestCase testParMarkStealingHappens(
    "threaded-gc-05b: a wide root is shared between markers by stealing",
    []() {
#if ENABLE_GC_STATS
        auto& a = initAllocator(parConfig(4, 4));
        std::vector<HPointer> roots;
        buildGraph(a, 80000, 17, roots, 200);
        for (auto& r : roots) a.getRootSet().addRoot(&r);
        const uint64_t steals0 = og(a).getStats().pm.steals;
        startCycle(a);
        runToHandoff(a);
        TEST_ASSERT(og(a).getStats().pm.steals > steals0);
        for (auto& r : roots) a.getRootSet().removeRoot(&r);
#endif
    });

Testing::TestCase testParMarkIncrementalOffUsesT0Cycle(
    "threaded-gc-05b: incremental off + 4 markers runs trigger majors as T = 0 cycles",
    []() {
        auto scenario = [](uint32_t threads) {
            HeapConfig cfg = parConfig(threads);
            cfg.incremental_mark = false;
            cfg.validate();
            auto& a = initAllocator(cfg);
            std::vector<HPointer> roots;
            buildGraph(a, 30000, 3, roots, 20);
            for (auto& r : roots) a.getRootSet().addRoot(&r);
#if ENABLE_GC_STATS
            const uint64_t cycles0 = og(a).getStats().im.cycles;
#endif
            tlh(a)->test_force_major_trigger_ = true;
            a.minorGC();
            TEST_ASSERT(!OA::cycleActive(og(a)));
#if ENABLE_GC_STATS
            // 1 marker: the legacy STW major (no cycle); 4: a T = 0 cycle.
            TEST_ASSERT(og(a).getStats().im.cycles - cycles0 == (threads > 1 ? 1u : 0u));
#endif
            const size_t live = OA::majorLive(og(a));
            for (auto& r : roots) a.getRootSet().removeRoot(&r);
            return live;
        };
        TEST_ASSERT(scenario(1) == scenario(4));
    });

Testing::TestCase testParMarkJoinDrainParallel(
    "threaded-gc-05b: an explicit major joins the cycle with a parallel drain",
    []() {
        auto& a = initAllocator(parConfig(4, 16));
        std::vector<HPointer> roots;
        buildGraph(a, 30000, 8, roots, 20);
        for (auto& r : roots) a.getRootSet().addRoot(&r);
        startCycle(a);
        TEST_ASSERT(OA::markParallel(og(a)));
#if ENABLE_GC_STATS
        const uint64_t runs0 = og(a).getStats().pm.runs;
        const uint64_t joins0 = og(a).getStats().im.finish_join;
#endif
        a.majorGC();
        TEST_ASSERT(!OA::cycleActive(og(a)));
#if ENABLE_GC_STATS
        TEST_ASSERT(og(a).getStats().pm.runs > runs0);
        TEST_ASSERT(og(a).getStats().im.finish_join == joins0 + 1);
#endif
        for (auto& r : roots) a.getRootSet().removeRoot(&r);
    });

// ============================================================================
// Negative controls (P§3.11). Validate builds: the named validator aborts the
// child. Other builds: the hole is observed.
// ============================================================================

Testing::TestCase testParMarkNegativeSkipMergeWorker1(
    "threaded-gc-05b: negative control — skipping marker 1's accumulator is caught",
    []() {
#if !defined(_WIN32)
        const size_t ref_live = [] {
            auto& a = initAllocator(parConfig(1));
            std::vector<HPointer> roots;
            buildGraph(a, 60000, 21, roots, 40);
            for (auto& r : roots) a.getRootSet().addRoot(&r);
            startCycle(a);
            runToHandoff(a);
            // The MERGED per-block totals (major_live_ is the traced sum,
            // computed before any merge, so it cannot show a skipped merge).
            const size_t v = OA::postSweepLive(og(a));
            for (auto& r : roots) a.getRootSet().removeRoot(&r);
            return v;
        }();
        // Which markers get work is schedule-dependent: under load marker 1
        // can mark nothing in a cycle, and skipping an empty accumulator loses
        // nothing (register CR-030). So the child finishes any cycle the build
        // started before setting the hook, then forces cycles until one loses
        // marker 1's bytes (validate: HEAP_051's post-merge check aborts at that
        // handoff). Exit 2: marker 1 marked nothing in 32 cycles, so the control
        // never ran.
        const int st = runInChild([ref_live]() -> int {
            auto& a = initAllocator(parConfig(4));
            std::vector<HPointer> roots;
            buildGraph(a, 60000, 21, roots, 40);
            for (auto& r : roots) a.getRootSet().addRoot(&r);
            runToHandoff(a);                         // a build-started cycle runs unhooked
            og(a).test_skip_merge_worker1_ = true;
            for (int c = 1; c <= 32; ++c) {
                startCycle(a);
                runToHandoff(a);                     // HEAP_051 post-merge check aborts here (validate)
                const size_t got = OA::postSweepLive(og(a));
                if (got < ref_live) {                // marker 1's bytes are missing: caught
                    std::fprintf(stderr, "    child: caught in forced cycle %d\n", c);
                    return 0;
                }
                if (got != ref_live) return 1;       // a different live set: not this fault
            }
            return 2;
        });
        if (WIFEXITED(st) && WEXITSTATUS(st) != 0) {
            std::fprintf(stderr, "    DIAG: child exit %d (%s)\n", WEXITSTATUS(st),
                         WEXITSTATUS(st) == 2 ? "marker 1 marked nothing in 32 forced cycles"
                                              : "the skipped accumulator was not seen");
        }
#if ECO_HEAP_VALIDATE
        // Validate builds: HEAP_051's post-merge check (markLiveMergeAll) aborts at the
        // first handoff whose skipped accumulator is non-empty, in any block. (IM6 alone
        // checks UNIFORM blocks only; the child's own post-sweep comparison, exit 0, was
        // the catcher for mixed blocks.) Either is the fault being caught; 1 or 2 is not.
        TEST_ASSERT(WIFSIGNALED(st) || (WIFEXITED(st) && WEXITSTATUS(st) == 0));
#else
        TEST_ASSERT(WIFEXITED(st) && WEXITSTATUS(st) == 0);
#endif
#endif
    });

Testing::TestCase testParMarkNegativePlainBits(
    "threaded-gc-05b: negative control — non-atomic mark bits are caught by IM10 (probabilistic)",
    []() {
#if !defined(_WIN32) && ECO_HEAP_VALIDATE
        int fired = 0;
        for (int attempt = 0; attempt < 20 && fired == 0; ++attempt) {
            const int st = runInChild([attempt]() -> int {
                auto& a = initAllocator(parConfig(8, 4));
                std::vector<HPointer> roots;
                buildGraph(a, 60000, 100 + attempt, roots, 400);
                for (auto& r : roots) a.getRootSet().addRoot(&r);
                og(a).test_plain_bits_parallel_ = true;
                startCycle(a);
                runToHandoff(a);
                return 0;
            });
            if (WIFSIGNALED(st)) ++fired;
        }
        std::printf("    (plain-bit control fired within %s)\n", fired ? "20 attempts" : "NO attempt");
        TEST_ASSERT(fired > 0);
#endif
    });

Testing::TestCase testParMarkNegativeStealWithoutTicket(
    "threaded-gc-05b: negative control — stealing without a ticket breaks exact units",
    []() {
#if !defined(_WIN32)
        auto runsUntilEmpty = [](uint32_t threads, bool hook, bool to_handoff) {
            auto& a = initAllocator(parConfig(threads, 64));
            std::vector<HPointer> roots;
            buildGraph(a, 60000, 31, roots, 400);
            for (auto& r : roots) a.getRootSet().addRoot(&r);
            og(a).test_steal_without_ticket_ = hook;
            startCycle(a);
            int runs = 0;
            std::vector<uint64_t>& seq = lastSeq();
            seq.clear();
            while (!OA::markStackEmpty(og(a)) && runs < 1000000) {
                seq.push_back(OA::runMarkers(og(a), 3));
                ++runs;
            }
            og(a).test_steal_without_ticket_ = false;
            if (to_handoff) runToHandoff(a);          // IM12 (validate): scanned != units
            for (auto& r : roots) a.getRootSet().removeRoot(&r);
            return runs;
        };
        const int ref = runsUntilEmpty(1, false, false);
        const std::vector<uint64_t> ref_seq = lastSeq();
        const int got = runsUntilEmpty(8, false, false);
        if (got != ref) {
            const std::vector<uint64_t>& s8 = lastSeq();
            size_t k = 0;
            while (k < ref_seq.size() && k < s8.size() && ref_seq[k] == s8[k]) ++k;
            std::fprintf(stderr, "    DIAG: runs %d vs %d; first divergence at run %zu: "
                "serial %llu, 8 markers %llu (of %zu / %zu runs)\n", ref, got, k,
                (unsigned long long)(k < ref_seq.size() ? ref_seq[k] : 0),
                (unsigned long long)(k < s8.size() ? s8[k] : 0), ref_seq.size(), s8.size());
        }
        TEST_ASSERT(got == ref);   // exact tickets
        int broke = 0;
        for (int attempt = 0; attempt < 10 && broke == 0; ++attempt) {
            const int st = runInChild([&]() -> int {
                return runsUntilEmpty(8, true, true) != ref ? 0 : 1;
            });
#if ECO_HEAP_VALIDATE
            if (WIFSIGNALED(st)) ++broke;                         // IM12 abort
#endif
            if (WIFEXITED(st) && WEXITSTATUS(st) == 0) ++broke;   // counts diverged
        }
        TEST_ASSERT(broke > 0);
#endif
    });
