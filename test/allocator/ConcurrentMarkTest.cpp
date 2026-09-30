/**
 * threaded-gc-05c (plans/threaded-gc-05c-concurrent-marking.md): concurrent
 * marking (HEAP_065). Configs are programmatic (the old gen of a unit test
 * ignores ECO_HEAP_CONFIG); conc_mark / conc_mark_threads are set per test.
 * The environment variables ECO_GC_CONC_MARK / ECO_GC_CONC_MARK_THREADS still
 * override them (Allocator::initialize), so the tests that pin a mode say so.
 */

#include "ConcurrentMarkTest.hpp"

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <functional>
#include <iterator>
#include <random>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#if !defined(_WIN32)
#include <fcntl.h>
#include <sched.h>
#include <sys/resource.h>
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

using OA = OldGenSpaceTestAccess;
using CS = OldGenSpace::CycleState;
using BE = OldGenSpace::BgEpisode;
constexpr size_t KiB = 1024;
constexpr size_t MiB = 1024 * 1024;

// mode: 0 = 05b in-pause slices, 1 = sync, 2 = concurrent. The environment
// overrides are cleared for the duration of a scenario that pins a mode.
HeapConfig concConfig(uint32_t mode, uint32_t fg = 2, uint32_t bg = 2, uint32_t slices = 8) {
    HeapConfig cfg;
    cfg.alloc_buffer_size          = 32 * KiB;
    cfg.nursery_block_count        = 8;
    cfg.nursery_max_block_count    = 8;
    cfg.initial_old_gen_size       = 256 * KiB;
    cfg.max_heap_size              = 512ULL * MiB;
    cfg.large_object_threshold     = 8 * KiB;
    cfg.large_ptr_nursery_divisor  = 8;
    cfg.decommit_on_oldgen_release = false;
    cfg.gc_thread_mode             = 0;
    cfg.incremental_mark           = true;
    cfg.incremental_mark_slices    = slices;
    cfg.incremental_mark_min_slice_units = 64;
    cfg.gc_mark_threads            = fg;
    cfg.conc_mark                  = mode;
    cfg.conc_mark_threads          = bg;
    cfg.conc_mark_priority         = 0;     // tests: do not starve on a loaded machine
    cfg.validate();
    return cfg;
}

// Pins the mode: the ECO_GC_CONC_MARK* variables would otherwise win.
struct EnvGuard {
    std::string m, t;
    bool hm = false, ht = false;
    EnvGuard() {
        if (const char* v = std::getenv("ECO_GC_CONC_MARK")) { m = v; hm = true; }
        if (const char* v = std::getenv("ECO_GC_CONC_MARK_THREADS")) { t = v; ht = true; }
        unsetenv("ECO_GC_CONC_MARK");
        unsetenv("ECO_GC_CONC_MARK_THREADS");
    }
    ~EnvGuard() {
        if (hm) setenv("ECO_GC_CONC_MARK", m.c_str(), 1);
        if (ht) setenv("ECO_GC_CONC_MARK_THREADS", t.c_str(), 1);
    }
};

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
// Holds the background members of the NEXT cycle (test_bg_hold_). A cycle
// the build started is finished first: startCycle would run it to its
// handoff, and a closing step that joins a running episode (closingFinish)
// clears the hold, so the forced cycle's members would start unheld
// (register CR-030). Callers assert the hold is still set after startCycle.
void holdNextCycle(Allocator& a) {
    runToHandoff(a);
    og(a).test_bg_hold_.store(true);
}

i64 intValue(Allocator& a, HPointer hp) {
    void* obj = a.resolve(hp);
    if (!obj || getHeader(obj)->tag != Tag_Int) throw std::runtime_error("expected an Int");
    return static_cast<ElmInt*>(obj)->value;
}

// Waits (outside any pause) until the background episode's members returned.
bool waitBackground(Allocator& a, int ms = 20000) {
    for (int i = 0; i < ms; ++i) {
        if (OA::bgEpisode(og(a)) != BE::Running || OA::bgFinishedApprox(og(a))) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return false;
}

// A deterministic random graph of `n` old Tuple2 nodes (same shape as the
// 05b tests). Returns node addresses; `roots` keeps a random subset.
std::vector<void*> buildGraph(Allocator& a, size_t n, uint64_t seed,
                              std::vector<HPointer>& roots, size_t n_roots) {
    std::mt19937_64 rng(seed);
    Root list(a, alloc::listNil());
    std::vector<HPointer> nodes;
    for (size_t i = 0; i < n; ++i) {
        HPointer x, y;
        {
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

// Decision-relevant record of a scenario (P§3.10): identical in every mode.
struct Decisions {
    std::vector<uint8_t> marked;           // first cycle, at HandoffDue
    std::vector<uint64_t> cycle_units;     // per cycle (prev_cycle_units_)
    std::vector<size_t> major_live, post_sweep;
    uint64_t traced = 0;
    bool operator==(const Decisions& o) const {
        return marked == o.marked && cycle_units == o.cycle_units &&
               major_live == o.major_live && post_sweep == o.post_sweep && traced == o.traced;
    }
};

Decisions graphScenario(uint32_t mode, uint32_t bg, size_t n, int cycles, uint32_t slices = 8) {
    auto& a = initAllocator(concConfig(mode, 2, bg, slices));
    std::vector<HPointer> roots;
    std::vector<void*> addrs = buildGraph(a, n, 4321, roots, 40);
    for (auto& r : roots) a.getRootSet().addRoot(&r);
    Decisions d;
    for (int c = 0; c < cycles; ++c) {
        startCycle(a);
        // Allocate and promote while the cycle runs (allocate-black).
        while (OA::cycleState(og(a)) == CS::Marking) {
            for (int i = 0; i < 200; ++i) (void)alloc::allocInt(i);
            a.minorGC();
        }
        if (c == 0) {
            for (void* p : addrs) d.marked.push_back(OA::isMarked(og(a), p) ? 1 : 0);
            d.traced = OA::markLiveSum(og(a));
        }
        runToHandoff(a);
        d.cycle_units.push_back(OA::prevCycleUnits(og(a)));
        d.major_live.push_back(OA::majorLive(og(a)));
        d.post_sweep.push_back(OA::postSweepLive(og(a)));
    }
    for (auto& r : roots) a.getRootSet().removeRoot(&r);
    return d;
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

#if ENABLE_GC_STATS
const ConcMarkStats& cm(Allocator& a) { return og(a).getStats().cm; }
const IncrMarkStats& im(Allocator& a) { return og(a).getStats().im; }
#endif

}  // namespace

// ============================================================================
// Step 4: GCBackgroundGang
// ============================================================================

Testing::TestCase testBgGangLaunchJoinEveryMemberOnce(
    "threaded-gc-05c: GCBackgroundGang runs every member once per launch",
    []() {
        for (unsigned m = 1; m <= 8; ++m) {
            gc::GCBackgroundGang::Options o;
            o.members = m;
            gc::GCBackgroundGang g(o);
            struct Ctx { std::atomic<uint32_t> hits[8]; std::atomic<uint32_t> returned{0}; } ctx;
            std::atomic<bool> stop{false};
            for (int r = 0; r < 300; ++r) {
                for (auto& h : ctx.hits) h.store(0);
                ctx.returned.store(0);
                g.launch([](void* c, unsigned i) {
                    auto* x = static_cast<Ctx*>(c);
                    x->hits[i].fetch_add(1);
                    x->returned.fetch_add(1);
                }, &ctx, &stop);
                TEST_ASSERT(g.running());
                g.join();
                TEST_ASSERT(!g.running());
                TEST_ASSERT(ctx.returned.load() == m);
                for (unsigned i = 0; i < 8; ++i) TEST_ASSERT(ctx.hits[i].load() == (i < m ? 1u : 0u));
            }
        }
    });

Testing::TestCase testBgGangStopAndJoinBounded(
    "threaded-gc-05c: GCBackgroundGang stopAndJoin returns promptly",
    []() {
        gc::GCBackgroundGang::Options o;
        o.members = 4;
        gc::GCBackgroundGang g(o);
        std::atomic<bool> stop{false};
        g.launch([](void* c, unsigned) {
            auto* s = static_cast<std::atomic<bool>*>(c);
            while (!s->load(std::memory_order_acquire)) std::this_thread::yield();
        }, &stop, &stop);
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
        TEST_ASSERT(!g.finishedApprox());
        const auto t0 = std::chrono::steady_clock::now();
        g.stopAndJoin();
        const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - t0).count();
        TEST_ASSERT(!g.running());
        TEST_ASSERT(ms < 100);
    });

Testing::TestCase testBgGangPriorityApplied(
    "threaded-gc-05c: GCBackgroundGang applies its priority once per thread",
    []() {
#if defined(__linux__)
        for (int prio : {10, 20}) {
            gc::GCBackgroundGang::Options o;
            o.members = 2;
            o.priority = prio;
            gc::GCBackgroundGang g(o);
            std::atomic<bool> stop{false};
            g.launch([](void*, unsigned) {}, nullptr, &stop);
            g.join();
            const std::vector<long> tids = g.memberTids();
            TEST_ASSERT(tids.size() == 2);
            for (long tid : tids) {
                TEST_ASSERT(tid > 0);
                if (prio <= 19) {
                    errno = 0;
                    const int p = getpriority(PRIO_PROCESS, static_cast<id_t>(tid));
                    TEST_ASSERT(errno == 0 && p == prio);
                } else {
                    TEST_ASSERT(sched_getscheduler(static_cast<pid_t>(tid)) == SCHED_IDLE);
                }
            }
        }
#endif
    });

Testing::TestCase testBgGangForkWhileRunning(
    "threaded-gc-05c: fork stops a running GCBackgroundGang; both sides relaunch",
    []() {
#if !defined(_WIN32)
        gc::GCBackgroundGang::Options o;
        o.members = 3;
        gc::GCBackgroundGang g(o);
        std::atomic<bool> stop{false};
        auto spin = [](void* c, unsigned) {
            auto* s = static_cast<std::atomic<bool>*>(c);
            while (!s->load(std::memory_order_acquire)) std::this_thread::yield();
        };
        g.launch(spin, &stop, &stop);
        const int st = runInChild([&]() -> int {
            if (g.running()) return 1;          // the prepare hook stopped it
            std::atomic<bool> s2{false};
            std::atomic<uint32_t> n{0};
            g.launch([](void* c, unsigned) { static_cast<std::atomic<uint32_t>*>(c)->fetch_add(1); },
                     &n, &s2);
            g.join();
            return n.load() == 3 ? 0 : 2;
        });
        TEST_ASSERT(WIFEXITED(st) && WEXITSTATUS(st) == 0);
        // Parent: the episode was stopped (and joined) by the prepare hook.
        TEST_ASSERT(!g.running());
        TEST_ASSERT(g.stats().fork_stops.load() >= 1);
        stop.store(false);
        std::atomic<uint32_t> n{0};
        g.launch([](void* c, unsigned) { static_cast<std::atomic<uint32_t>*>(c)->fetch_add(1); },
                 &n, &stop);
        g.join();
        TEST_ASSERT(n.load() == 3);
#endif
    });

Testing::TestCase testBgGangDestructorStops(
    "threaded-gc-05c: destroying a running GCBackgroundGang stops and joins it",
    []() {
        std::atomic<bool> stop{false};
        std::atomic<uint32_t> exited{0};
        struct Ctx { std::atomic<bool>* s; std::atomic<uint32_t>* e; } ctx{&stop, &exited};
        {
            gc::GCBackgroundGang::Options o;
            o.members = 4;
            gc::GCBackgroundGang g(o);
            g.launch([](void* c, unsigned) {
                auto* x = static_cast<Ctx*>(c);
                while (!x->s->load(std::memory_order_acquire)) std::this_thread::yield();
                x->e->fetch_add(1);
            }, &ctx, &stop);
        }
        TEST_ASSERT(exited.load() == 4);
    });

// ============================================================================
// Step 5: configuration
// ============================================================================

Testing::TestCase testConcMarkConfigJson(
    "threaded-gc-05c: conc_mark_* and Part B JSON keys and validation",
    []() {
        HeapConfig def;
        TEST_ASSERT(def.conc_mark == CONC_MARK);
        TEST_ASSERT(def.conc_mark_threads_cap == CONC_MARK_THREADS_CAP);
        TEST_ASSERT(def.major_gc_headroom_margin == MAJOR_GC_HEADROOM_MARGIN);
        const char* path = "/tmp/eco-05c-conc-mark-config.json";
        {
            std::ofstream f(path);
            f << R"({"conc_mark": 2, "conc_mark_threads": 5, "conc_mark_threads_cap": 7,
                    "conc_mark_priority": 19, "conc_mark_assist_lag": 9,
                    "major_gc_headroom_margin": 1.5, "major_gc_live_budget_paced": true,
                    "major_gc_garbage_backstop": 0.85})";
        }
        HeapConfig c;
        applyHeapConfigJsonFile(c, path);
        c.validate();
        TEST_ASSERT(c.conc_mark == 2 && c.conc_mark_threads == 5 && c.conc_mark_threads_cap == 7);
        TEST_ASSERT(c.conc_mark_priority == 19 && c.conc_mark_assist_lag == 9);
        TEST_ASSERT(c.major_gc_headroom_margin == 1.5 && c.major_gc_live_budget_paced);
        TEST_ASSERT(c.major_gc_garbage_backstop > 0.84f && c.major_gc_garbage_backstop < 0.86f);
        std::remove(path);
        auto rejects = [](auto mutate) {
            HeapConfig x;
            mutate(x);
            try { x.validate(); } catch (const std::invalid_argument&) { return true; }
            return false;
        };
        TEST_ASSERT(rejects([](HeapConfig& x) { x.conc_mark = 3; }));
        TEST_ASSERT(rejects([](HeapConfig& x) { x.conc_mark_threads = 64; }));
        TEST_ASSERT(rejects([](HeapConfig& x) { x.conc_mark_threads_cap = 0; }));
        TEST_ASSERT(rejects([](HeapConfig& x) { x.conc_mark_priority = 21; }));
        TEST_ASSERT(rejects([](HeapConfig& x) { x.major_gc_headroom_margin = 9.0; }));
        TEST_ASSERT(rejects([](HeapConfig& x) { x.major_gc_garbage_backstop = 0.5f; }));
    });

Testing::TestCase testConcMarkEnvOverrides(
    "threaded-gc-05c: ECO_GC_CONC_MARK / ECO_GC_CONC_MARK_THREADS parse and win",
    []() {
        HeapConfig c;
        applyConcMarkEnv(c, "2", "6");
        TEST_ASSERT(c.conc_mark == 2 && c.conc_mark_threads == 6);
        applyConcMarkEnv(c, "1", nullptr);
        TEST_ASSERT(c.conc_mark == 1 && c.conc_mark_threads == 6);
        auto throws = [](const char* m, const char* t) {
            HeapConfig x;
            try { applyConcMarkEnv(x, m, t); } catch (const std::invalid_argument&) { return true; }
            return false;
        };
        TEST_ASSERT(throws("3", nullptr));
        TEST_ASSERT(throws("22", nullptr));
        TEST_ASSERT(throws(nullptr, "64"));
        TEST_ASSERT(throws(nullptr, "x"));
    });

Testing::TestCase testConcMarkThreadsResolution(
    "threaded-gc-05c: background marker count resolution and clamping",
    []() {
        HeapConfig c = concConfig(2, 4, 3);
        TEST_ASSERT(OldGenSpace::resolveConcMarkThreads(c, 4) == 3);
        TEST_ASSERT(OldGenSpace::resolveConcMarkThreads(c, 62) == 2);   // F + B <= 64
        c.conc_mark = 0;
        TEST_ASSERT(OldGenSpace::resolveConcMarkThreads(c, 4) == 0);
        c.conc_mark = 1;
        TEST_ASSERT(OldGenSpace::resolveConcMarkThreads(c, 4) == 0);
        c.conc_mark = 2;
        c.incremental_mark = false;
        TEST_ASSERT(OldGenSpace::resolveConcMarkThreads(c, 4) == 0);
#if defined(__linux__)
        c.incremental_mark = true;
        c.conc_mark_threads = 0;       // auto: min(cap, CPUs - 1)
        c.conc_mark_threads_cap = 8;
        cpu_set_t old;
        CPU_ZERO(&old);
        if (sched_getaffinity(0, sizeof old, &old) == 0 && CPU_COUNT(&old) >= 3) {
            cpu_set_t three;
            CPU_ZERO(&three);
            int got = 0;
            for (int cpu = 0; cpu < CPU_SETSIZE && got < 3; ++cpu) {
                if (CPU_ISSET(cpu, &old)) { CPU_SET(cpu, &three); ++got; }
            }
            sched_setaffinity(0, sizeof three, &three);
            const unsigned b = OldGenSpace::resolveConcMarkThreads(c, 2);
            sched_setaffinity(0, sizeof old, &old);
            TEST_ASSERT(b == 2);
        }
#endif
    });

// ============================================================================
// Step 6: the cycle driver
// ============================================================================

Testing::TestCase testConcMarkMatchesPauseMark(
    "threaded-gc-05c: mode 2 marks exactly what mode 0 marks (same decisions)",
    []() {
        EnvGuard env;
        const Decisions ref = graphScenario(0, 0, 60000, 2);
        const Decisions got = graphScenario(2, 4, 60000, 2);
        TEST_ASSERT(got == ref);
        const Decisions sync = graphScenario(1, 0, 60000, 2);
        TEST_ASSERT(sync == ref);
    });

Testing::TestCase testConcMarkRunsDuringMinorGCs(
    "threaded-gc-05c: background marking runs while minors promote into the old gen",
    []() {
        EnvGuard env;
        auto& a = initAllocator(concConfig(2, 2, 2, 16));
        std::vector<HPointer> roots;
        buildGraph(a, 40000, 99, roots, 40);
        for (auto& r : roots) a.getRootSet().addRoot(&r);
        // Hold the members for the first few minors so the episode overlaps
        // the promotions below (mixed and uniform cells, large string bodies).
        holdNextCycle(a);
        startCycle(a);
        TEST_ASSERT(og(a).test_bg_hold_.load());
        TEST_ASSERT(OA::bgEpisode(og(a)) == BE::Running);
        std::vector<std::unique_ptr<Root>> keep;
        std::mt19937_64 rng(5);
        int k = 0;
        while (OA::cycleState(og(a)) == CS::Marking) {
            if (k == 2) og(a).test_bg_hold_.store(false);
            for (int i = 0; i < 64; ++i) {
                const size_t len = 1 + rng() % 40;
                std::vector<u16> buf(len, static_cast<u16>('a' + (i % 26)));
                HPointer s = alloc::allocString(buf.data(), buf.size());
                HPointer t = alloc::tuple2(alloc::boxed(s), alloc::boxed(alloc::allocInt(k * 1000 + i)), 0);
                if (i % 8 == 0) keep.push_back(std::make_unique<Root>(a, t));
            }
            if (k % 3 == 0) {
                std::vector<u16> big(6000, static_cast<u16>('Z'));
                keep.push_back(std::make_unique<Root>(a, alloc::allocString(big.data(), big.size())));
            }
            a.minorGC();
            ++k;
        }
        runToHandoff(a);
        startCycle(a);
        runToHandoff(a);
        // Every kept tuple is intact after two handoffs.
        int checked = 0;
        for (auto& r : keep) {
            void* obj = a.resolve(r->h);
            TEST_ASSERT(obj != nullptr);
            if (getHeader(obj)->tag == Tag_Tuple2) {
                Tuple2* t = static_cast<Tuple2*>(obj);
                const i64 v = intValue(a, t->b.p);
                TEST_ASSERT(v >= 0 && v < 1000000);
                ++checked;
            }
        }
        TEST_ASSERT(checked > 0);
        for (auto& r : roots) a.getRootSet().removeRoot(&r);
    });

Testing::TestCase testConcMarkUnitsExactAcrossB(
    "threaded-gc-05c: decisions and cycle units identical at every B and mode",
    []() {
        EnvGuard env;
        const Decisions ref = graphScenario(0, 0, 30000, 3);
        for (uint32_t b : {1u, 2u, 4u, 8u}) {
            TEST_ASSERT(graphScenario(2, b, 30000, 3) == ref);
        }
    });

Testing::TestCase testConcMarkAssistWhenLate(
    "threaded-gc-05c: a held background gets assists; the handoff stays at T + 1",
    []() {
        EnvGuard env;
        const Decisions ref = graphScenario(0, 0, 60000, 1, 16);
        HeapConfig cfg = concConfig(2, 2, 2, 16);
        cfg.conc_mark_assist_lag = 2;
        cfg.incremental_mark_min_slice_units = 16;
        auto& a = initAllocator(cfg);
        std::vector<HPointer> roots;
        buildGraph(a, 60000, 4321, roots, 40);
        for (auto& r : roots) a.getRootSet().addRoot(&r);
        holdNextCycle(a);   // before the baseline: a drained build cycle may assist
#if ENABLE_GC_STATS
        const uint64_t assists0 = cm(a).assists;
#endif
        startCycle(a);
        TEST_ASSERT(og(a).test_bg_hold_.load());
        uint32_t handoff_k = 0;
        while (OA::cycleActive(og(a))) {
            if (OA::cycleK(og(a)) == 15) og(a).test_bg_hold_.store(false);
            const uint32_t k = OA::cycleK(og(a));
            for (int i = 0; i < 200; ++i) (void)alloc::allocInt(i);
            a.minorGC();
            if (!OA::cycleActive(og(a))) handoff_k = k + 1;
        }
        TEST_ASSERT(handoff_k == 17);                     // T + 1
        TEST_ASSERT(OA::prevCycleUnits(og(a)) == ref.cycle_units[0]);
#if ENABLE_GC_STATS
        TEST_ASSERT(cm(a).assists > assists0);
#endif
        for (auto& r : roots) a.getRootSet().removeRoot(&r);
    });

Testing::TestCase testConcMarkClosingJoinsRunningEpisode(
    "threaded-gc-05c: the closing step joins a running episode until termination",
    []() {
        EnvGuard env;
        const Decisions ref = graphScenario(0, 0, 40000, 1, 6);
        HeapConfig cfg = concConfig(2, 2, 2, 6);
        cfg.conc_mark_assist_lag = 4096;    // no assists: everything is left to the closing
        auto& a = initAllocator(cfg);
        std::vector<HPointer> roots;
        buildGraph(a, 40000, 4321, roots, 40);
        for (auto& r : roots) a.getRootSet().addRoot(&r);
        runToHandoff(a);
#if ENABLE_GC_STATS
        const uint64_t c0 = cm(a).closings_with_work;
        const uint64_t a0 = cm(a).assists;
#endif
        og(a).test_bg_hold_.store(true);        // released by the closing step
        startCycle(a);
        while (OA::cycleActive(og(a))) {
            for (int i = 0; i < 200; ++i) (void)alloc::allocInt(i);
            a.minorGC();
        }
        TEST_ASSERT(OA::prevCycleUnits(og(a)) == ref.cycle_units[0]);
#if ENABLE_GC_STATS
        TEST_ASSERT(cm(a).closings_with_work == c0 + 1);
        TEST_ASSERT(cm(a).assists == a0);
#endif
        for (auto& r : roots) a.getRootSet().removeRoot(&r);
    });

Testing::TestCase testConcMarkNoAssistWhenOnTime(
    "threaded-gc-05c: a background that finishes early needs no in-pause work",
    []() {
        EnvGuard env;
        auto& a = initAllocator(concConfig(2, 2, 2, 16));
        std::vector<HPointer> roots;
        buildGraph(a, 20000, 7, roots, 20);
        for (auto& r : roots) a.getRootSet().addRoot(&r);
        runToHandoff(a);            // a cycle the build itself triggered
#if ENABLE_GC_STATS
        const uint64_t a0 = cm(a).assists, c0 = cm(a).closings_with_work;
        const uint64_t early0 = cm(a).done_k_hist[0];
#endif
        startCycle(a);
        TEST_ASSERT(waitBackground(a));
        runToHandoff(a);
#if ENABLE_GC_STATS
        TEST_ASSERT(cm(a).assists == a0);
        TEST_ASSERT(cm(a).closings_with_work == c0);
        if (cm(a).done_k_hist[0] != early0 + 1) {
            std::fprintf(stderr, "    DIAG done_k_hist: %llu %llu %llu %llu %llu (early0 %llu)\n",
                (unsigned long long)cm(a).done_k_hist[0], (unsigned long long)cm(a).done_k_hist[1],
                (unsigned long long)cm(a).done_k_hist[2], (unsigned long long)cm(a).done_k_hist[3],
                (unsigned long long)cm(a).done_k_hist[4], (unsigned long long)early0);
        }
        TEST_ASSERT(cm(a).done_k_hist[0] == early0 + 1);
#endif
        for (auto& r : roots) a.getRootSet().removeRoot(&r);
    });

Testing::TestCase testConcMarkStoppedEpisodeRelaunches(
    "threaded-gc-05c: a stopped episode is relaunched at the next step",
    []() {
        EnvGuard env;
        const Decisions ref = graphScenario(0, 0, 40000, 1, 8);
        auto& a = initAllocator(concConfig(2, 2, 3, 8));
        std::vector<HPointer> roots;
        buildGraph(a, 40000, 4321, roots, 40);
        for (auto& r : roots) a.getRootSet().addRoot(&r);
#if ENABLE_GC_STATS
        const uint64_t r0 = cm(a).episodes_relaunched;
#endif
        og(a).test_bg_hold_.store(true);
        startCycle(a);
        OA::stopBackground(og(a));
        TEST_ASSERT(OA::bgEpisode(og(a)) == BE::None);
        og(a).test_bg_hold_.store(false);
        while (OA::cycleActive(og(a))) {
            for (int i = 0; i < 200; ++i) (void)alloc::allocInt(i);
            a.minorGC();
        }
        TEST_ASSERT(OA::prevCycleUnits(og(a)) == ref.cycle_units[0]);
#if ENABLE_GC_STATS
        TEST_ASSERT(cm(a).episodes_relaunched == r0 + 1);
#endif
        for (auto& r : roots) a.getRootSet().removeRoot(&r);
    });

Testing::TestCase testConcMarkJoinOnExplicitMajor(
    "threaded-gc-05c: an explicit major joins a running background episode",
    []() {
        EnvGuard env;
        auto& a = initAllocator(concConfig(2, 2, 2, 16));
        std::vector<HPointer> roots;
        buildGraph(a, 30000, 8, roots, 20);
        for (auto& r : roots) a.getRootSet().addRoot(&r);
        Root keep(a, roots[0]);
        holdNextCycle(a);
        startCycle(a);
        TEST_ASSERT(og(a).test_bg_hold_.load());
        TEST_ASSERT(OA::bgEpisode(og(a)) == BE::Running);
#if ENABLE_GC_STATS
        const uint64_t joins0 = im(a).finish_join;
#endif
        a.majorGC();
        TEST_ASSERT(!OA::cycleActive(og(a)));
        TEST_ASSERT(OA::bgEpisode(og(a)) != BE::Running);
        TEST_ASSERT(a.resolve(keep.h) != nullptr);
#if ENABLE_GC_STATS
        TEST_ASSERT(im(a).finish_join == joins0 + 1);
#endif
        for (auto& r : roots) a.getRootSet().removeRoot(&r);
    });

Testing::TestCase testConcMarkPressureFinish(
    "threaded-gc-05c: old-gen pressure finishes a concurrent cycle through the closing join",
    []() {
        EnvGuard env;
        HeapConfig cfg = concConfig(2, 2, 2, 8);
        cfg.major_gc_global_pressure_fraction = 0.0005f;
        cfg.incremental_mark_finish_fraction = 0.0009;   // already exceeded at t0
        cfg.validate();
        auto& a = initAllocator(cfg);
        std::vector<HPointer> roots;
        buildGraph(a, 20000, 9, roots, 20);
        for (auto& r : roots) a.getRootSet().addRoot(&r);
        runToHandoff(a);
#if ENABLE_GC_STATS
        const uint64_t p0 = im(a).finish_pressure;
#endif
        og(a).test_bg_hold_.store(true);
        startCycle(a);
        a.minorGC();                                  // first step: pressure finish
        TEST_ASSERT(!OA::cycleActive(og(a)) || OA::cycleK(og(a)) == 0);
#if ENABLE_GC_STATS
        TEST_ASSERT(im(a).finish_pressure > p0);
#endif
        og(a).test_bg_hold_.store(false);
        for (auto& r : roots) TEST_ASSERT(a.resolve(r) != nullptr);
        for (auto& r : roots) a.getRootSet().removeRoot(&r);
    });

Testing::TestCase testConcMarkResetMidEpisode(
    "threaded-gc-05c: an allocator reset stops a running episode",
    []() {
        EnvGuard env;
        HeapConfig cfg = concConfig(2, 2, 2, 8);
        {
            auto& a = initAllocator(cfg);
            std::vector<HPointer> roots;
            buildGraph(a, 20000, 3, roots, 20);
            holdNextCycle(a);
            startCycle(a);
            TEST_ASSERT(og(a).test_bg_hold_.load());
            TEST_ASSERT(OA::bgEpisode(og(a)) == BE::Running);
        }
        auto& a = initAllocator(cfg);
        TEST_ASSERT(!OA::cycleActive(og(a)));
        TEST_ASSERT(OA::bgEpisode(og(a)) == BE::None);
        Root k(a, alloc::allocInt(3));
        startCycle(a);
        runToHandoff(a);
        TEST_ASSERT(intValue(a, k.h) == 3);
    });

Testing::TestCase testConcMarkForkDuringEpisode(
    "threaded-gc-05c: fork during a running episode; both sides finish the cycle",
    []() {
#if !defined(_WIN32)
        EnvGuard env;
        const Decisions ref = graphScenario(0, 0, 40000, 1, 8);
        auto& a = initAllocator(concConfig(2, 2, 2, 8));
        std::vector<HPointer> roots;
        buildGraph(a, 40000, 4321, roots, 40);
        for (auto& r : roots) a.getRootSet().addRoot(&r);
        og(a).test_bg_hold_.store(true);
        startCycle(a);
        TEST_ASSERT(OA::bgEpisode(og(a)) == BE::Running);
        const uint64_t want = ref.cycle_units[0];
        const int st = runInChild([&a, want]() -> int {
            og(a).test_bg_hold_.store(false);
            while (OA::cycleActive(og(a))) {
                for (int i = 0; i < 200; ++i) (void)alloc::allocInt(i);
                a.minorGC();
            }
            return OA::prevCycleUnits(og(a)) == want ? 0 : 1;
        });
        TEST_ASSERT(WIFEXITED(st) && WEXITSTATUS(st) == 0);
        og(a).test_bg_hold_.store(false);
        while (OA::cycleActive(og(a))) {
            for (int i = 0; i < 200; ++i) (void)alloc::allocInt(i);
            a.minorGC();
        }
        TEST_ASSERT(OA::prevCycleUnits(og(a)) == want);
        for (auto& r : roots) a.getRootSet().removeRoot(&r);
#endif
    });

Testing::TestCase testConcMarkSyncModeMarksAtT0(
    "threaded-gc-05c: mode 1 (sync) marks everything at t0 without background threads",
    []() {
        EnvGuard env;
        auto& a = initAllocator(concConfig(1, 2, 2, 8));
        std::vector<HPointer> roots;
        buildGraph(a, 30000, 11, roots, 20);
        for (auto& r : roots) a.getRootSet().addRoot(&r);
        startCycle(a);
        TEST_ASSERT(OA::cycleActive(og(a)));
        TEST_ASSERT(OA::markStackEmpty(og(a)));
        TEST_ASSERT(!OA::hasBgGang(og(a)));
        TEST_ASSERT(OA::concThreads(og(a)) == 0);
        runToHandoff(a);
        for (auto& r : roots) a.getRootSet().removeRoot(&r);
    });

Testing::TestCase testConcMarkT0DistributesToBackground(
    "threaded-gc-05c: the t0 greys are distributed over the background deques",
    []() {
        EnvGuard env;
        auto& a = initAllocator(concConfig(2, 2, 3, 8));
        std::vector<HPointer> roots;
        buildGraph(a, 20000, 12, roots, 60);
        for (auto& r : roots) a.getRootSet().addRoot(&r);
        holdNextCycle(a);
        startCycle(a);
        TEST_ASSERT(og(a).test_bg_hold_.load());   // the members are still held
        TEST_ASSERT(OA::markSlots(og(a)) == 5);
        TEST_ASSERT(OA::slotDequeSize(og(a), 0) == 0);
        TEST_ASSERT(OA::slotDequeSize(og(a), 1) == 0);
        for (unsigned i = 2; i < 5; ++i) TEST_ASSERT(OA::slotDequeSize(og(a), i) > 0);
        og(a).test_bg_hold_.store(false);
        runToHandoff(a);
        for (auto& r : roots) a.getRootSet().removeRoot(&r);
    });

Testing::TestCase testConcMarkIncrementalOffNoBackground(
    "threaded-gc-05c: incremental off never creates background markers",
    []() {
        EnvGuard env;
        HeapConfig cfg = concConfig(2, 4, 2, 8);
        cfg.incremental_mark = false;
        cfg.validate();
        auto& a = initAllocator(cfg);
        TEST_ASSERT(OA::concThreads(og(a)) == 0);
        Root k(a, alloc::allocInt(5));
        tlh(a)->test_force_major_trigger_ = true;
        a.minorGC();
        TEST_ASSERT(!OA::cycleActive(og(a)));
        TEST_ASSERT(!OA::hasBgGang(og(a)));
        TEST_ASSERT(intValue(a, k.h) == 5);
    });

// ============================================================================
// Step 7: negative controls (P§3.9)
// ============================================================================

Testing::TestCase testConcMarkNegativeSkipBgMerge(
    "threaded-gc-05c: negative control — skipping a background merge is caught",
    []() {
#if !defined(_WIN32)
        EnvGuard env;
        const Decisions ref = graphScenario(0, 0, 40000, 1, 8);
        const uint64_t want = ref.cycle_units[0];
        // One background member (B = 1): the t0 greys all go to its deque and
        // it marks them before waitBackground returns, so skipping its merge
        // always loses units. With B = 2 the skipped member could mark nothing
        // (register CR-030). A build-started cycle is finished unhooked first.
        // Exit 2: the member never finished (the control did not run).
        const int st = runInChild([want]() -> int {
            auto& a = initAllocator(concConfig(2, 2, 1, 8));
            std::vector<HPointer> roots;
            buildGraph(a, 40000, 4321, roots, 40);
            for (auto& r : roots) a.getRootSet().addRoot(&r);
            runToHandoff(a);
            og(a).test_skip_bg_merge_ = true;
            startCycle(a);
            if (!waitBackground(a)) return 2;
            runToHandoff(a);                        // IM12 aborts here (validate)
            return OA::prevCycleUnits(og(a)) < want ? 0 : 1;
        });
        if (WIFEXITED(st) && WEXITSTATUS(st) != 0) {
            std::fprintf(stderr, "    DIAG: child exit %d (%s)\n", WEXITSTATUS(st),
                         WEXITSTATUS(st) == 2 ? "the background member never finished"
                                              : "the skipped merge was not seen");
        }
#if ECO_HEAP_VALIDATE
        TEST_ASSERT(WIFSIGNALED(st));
#else
        TEST_ASSERT(WIFEXITED(st) && WEXITSTATUS(st) == 0);
#endif
#endif
    });

Testing::TestCase testConcMarkNegativeLeavePrivate(
    "threaded-gc-05c: negative control — private work left after a run is caught (IM15)",
    []() {
#if !defined(_WIN32)
        EnvGuard env;
        // Budgeted foreground runs (mode 0, tiny slices): members routinely
        // end a run on budget exhaustion with a private stack, which every
        // exit must publish. IM15 runs in every build.
        const int st = runInChild([]() -> int {
            HeapConfig cfg = concConfig(0, 4, 0, 64);
            cfg.incremental_mark_min_slice_units = 1;
            auto& a = initAllocator(cfg);
            std::vector<HPointer> roots;
            buildGraph(a, 60000, 51, roots, 400);
            for (auto& r : roots) a.getRootSet().addRoot(&r);
            og(a).test_leave_private_on_exit_ = true;
            startCycle(a);
            for (int i = 0; i < 1000 && OA::cycleActive(og(a)); ++i) {
                (void)OA::runMarkers(og(a), 5);
            }
            return 0;
        });
        TEST_ASSERT(WIFSIGNALED(st));
#endif
    });

Testing::TestCase testConcMarkNegativeCursorT0Block(
    "threaded-gc-05c: negative control — the cursor taking a t0 block is caught (IM13)",
    []() {
#if !defined(_WIN32) && ECO_HEAP_VALIDATE
        EnvGuard env;
        const int st = runInChild([]() -> int {
            auto& a = initAllocator(concConfig(2, 2, 2, 8));
            std::vector<HPointer> roots;
            buildGraph(a, 20000, 13, roots, 20);
            for (auto& r : roots) a.getRootSet().addRoot(&r);
            og(a).test_cursor_takes_t0_block_ = true;
            startCycle(a);
            // Promotions of many small sizes until some class's cursor refills.
            for (int k = 0; k < 8 && OA::cycleActive(og(a)); ++k) {
                std::vector<std::unique_ptr<Root>> keep;
                for (int i = 0; i < 2000; ++i) {
                    std::vector<u16> buf(1 + i % 48, 'c');
                    keep.push_back(std::make_unique<Root>(a, alloc::allocString(buf.data(), buf.size())));
                }
                a.minorGC();
                a.minorGC();
            }
            return 0;
        });
        if (!WIFSIGNALED(st)) std::fprintf(stderr, "    DIAG child status %d\n", st);
        TEST_ASSERT(WIFSIGNALED(st));
#endif
    });

Testing::TestCase testConcMarkNegativePlainAllocateBlack(
    "threaded-gc-05c: negative control — plain allocate-black under a running episode (rate)",
    []() {
#if !defined(_WIN32) && ECO_HEAP_VALIDATE
        EnvGuard env;
        int fired = 0;
        const int attempts = 20;
        for (int attempt = 0; attempt < attempts; ++attempt) {
            const int st = runInChild([attempt]() -> int {
                auto& a = initAllocator(concConfig(2, 2, 4, 16));
                std::vector<HPointer> roots;
                buildGraph(a, 60000, 200 + attempt, roots, 400);
                for (auto& r : roots) a.getRootSet().addRoot(&r);
                og(a).test_plain_allocate_black_ = true;
                startCycle(a);
                std::vector<std::unique_ptr<Root>> keep;
                std::mt19937_64 rng(attempt);
                while (OA::cycleActive(og(a))) {
                    for (int i = 0; i < 400; ++i) {
                        const size_t len = 1 + rng() % 60;
                        std::vector<u16> buf(len, 'q');
                        keep.push_back(std::make_unique<Root>(a, alloc::allocString(buf.data(), len)));
                    }
                    a.minorGC();
                }
                return 0;
            });
            if (WIFSIGNALED(st)) ++fired;
        }
        // Not asserted (P§3.9): the lost update needs an exact interleaving.
        std::printf("    (plain allocate-black control fired in %d of %d attempts)\n", fired, attempts);
#endif
    });

// IM14 per slot (register CR-010): validate builds check every mutator touch
// of owner-only slot state for exactly the slots it touches. An assist resets
// the foreground counters while the background gang legitimately runs on the
// other slots; the hook widens that reset to background slot F.
#if !defined(_WIN32) && ECO_HEAP_VALIDATE
namespace {
// runInChild, with the child's stderr kept in `path` (which validator fired).
int runInChildStderrTo(const std::function<int()>& fn, const char* path) {
    std::fflush(stdout);
    std::fflush(stderr);
    pid_t pid = fork();
    if (pid == 0) {
        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (fd >= 0) dup2(fd, 2);
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

std::string slurp(const char* path) {
    std::ifstream f(path);
    return std::string(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
}

// testConcMarkAssistWhenLate's shape: the background is held, so the steps
// assist while its gang runs. 0 = the cycle handed off after an assist.
int assistWhileBackgroundRuns(bool reset_bg_ctr) {
    HeapConfig cfg = concConfig(2, 2, 2, 16);
    cfg.conc_mark_assist_lag = 2;
    cfg.incremental_mark_min_slice_units = 16;
    auto& a = initAllocator(cfg);
    std::vector<HPointer> roots;
    buildGraph(a, 40000, 4321, roots, 40);
    for (auto& r : roots) a.getRootSet().addRoot(&r);
    runToHandoff(a);                              // a cycle the build itself started
#if ENABLE_GC_STATS
    const uint64_t assists0 = cm(a).assists;
#endif
    og(a).test_assist_resets_bg_ctr_ = reset_bg_ctr;
    og(a).test_bg_hold_.store(true);
    startCycle(a);
    while (OA::cycleActive(og(a))) {
        if (OA::cycleK(og(a)) == 15) og(a).test_bg_hold_.store(false);
        for (int i = 0; i < 200; ++i) (void)alloc::allocInt(i);
        a.minorGC();
    }
    for (auto& r : roots) a.getRootSet().removeRoot(&r);
#if ENABLE_GC_STATS
    if (cm(a).assists == assists0) return 2;      // the scenario never assisted
#endif
    return 0;
}
}  // namespace
#endif

Testing::TestCase testConcMarkNegativeAssistResetsBgCounter(
    "threaded-gc-05c: negative control — an assist resetting a background slot's counter is caught (IM14, CR-010)",
    []() {
#if !defined(_WIN32) && ECO_HEAP_VALIDATE
        EnvGuard env;
        char path[] = "/tmp/eco-cr010-XXXXXX";
        const int fd = mkstemp(path);
        TEST_ASSERT(fd >= 0);
        close(fd);
        // The normal path: assists run beside the background gang; IM14 is quiet.
        const int ok = runInChildStderrTo([]() { return assistWhileBackgroundRuns(false); }, path);
        const std::string ok_err = slurp(path);
        // The hook: the first assist's reset also touches background slot F.
        const int st = runInChildStderrTo([]() { return assistWhileBackgroundRuns(true); }, path);
        const std::string err = slurp(path);
        unlink(path);
        if (!WIFEXITED(ok) || WEXITSTATUS(ok) != 0 || !WIFSIGNALED(st)) {
            std::fprintf(stderr, "    DIAG control status %d (%s); hooked status %d (%s)\n",
                         ok, ok_err.c_str(), st, err.c_str());
        }
        TEST_ASSERT(WIFEXITED(ok) && WEXITSTATUS(ok) == 0);
        TEST_ASSERT(ok_err.find("IM14") == std::string::npos);
        TEST_ASSERT(WIFSIGNALED(st) && WTERMSIG(st) == SIGABRT);
        TEST_ASSERT(err.find("IM14: slots [0, ") != std::string::npos);
        TEST_ASSERT(err.find("at an assist's counter reset while the background gang runs") !=
                    std::string::npos);
#endif
    });

// ============================================================================
// E7 (plan P§5): heap-size independence of the in-pause mark. Disabled unless
// ECO_CONC_SCALE_BENCH=1 (it builds a multi-GB old gen). A live graph of
// ECO_CONC_SCALE_GB (default 1) GB of old Tuple2 nodes; then forced cycles
// with a mutator that "computes" 20 ms between minors (as the self-compile
// does ~86 ms), printing per mode the in-pause cycle work.
// ============================================================================

Testing::TestCase testConcMarkScaleBench(
    "threaded-gc-05c: E7 scale bench (ECO_CONC_SCALE_BENCH=1)",
    []() {
        if (std::getenv("ECO_CONC_SCALE_BENCH") == nullptr) return;
        EnvGuard env;
        const double gb = std::getenv("ECO_CONC_SCALE_GB") ? std::atof(std::getenv("ECO_CONC_SCALE_GB")) : 1.0;
        const int sleep_ms = std::getenv("ECO_CONC_SCALE_SLEEP_MS") ? std::atoi(std::getenv("ECO_CONC_SCALE_SLEEP_MS")) : 20;
        for (uint32_t mode : {0u, 2u}) {
            HeapConfig cfg;
            cfg.max_heap_size = 24ULL << 30;
            cfg.gc_thread_mode = 0;
            cfg.incremental_mark = true;
            cfg.incremental_mark_slices = 32;
            cfg.gc_mark_threads = 0;        // auto (cap 16)
            cfg.conc_mark = mode;
            cfg.conc_mark_threads = 4;
            cfg.conc_mark_assist_lag = 8;
            cfg.major_gc_garbage_fraction = 0.0f;   // cycles are forced below
            cfg.major_gc_live_budget = 0.0;
            cfg.validate();
            auto& a = initAllocator(cfg);
            // ~56 B per node (Tuple2 + two Ints): nodes = gb * 2^30 / 56.
            const size_t nodes = static_cast<size_t>(gb * static_cast<double>(1ull << 30) / 56.0);
            const size_t lists = 256;
            std::vector<std::unique_ptr<Root>> heads;
            for (size_t l = 0; l < lists; ++l) heads.push_back(std::make_unique<Root>(a, alloc::listNil()));
            for (size_t i = 0; i < nodes; ++i) {
                Root x(a, alloc::allocInt(static_cast<i64>(i)));
                Root y(a, alloc::allocInt(-static_cast<i64>(i)));
                Root t(a, alloc::tuple2(alloc::boxed(x.h), alloc::boxed(y.h), 0));
                Root& h = *heads[i % lists];
                h.h = alloc::cons(alloc::boxed(t.h), h.h, true);
            }
            runToHandoff(a);
#if ENABLE_GC_STATS
            OldGenSpace& o = og(a);
            const IncrMarkStats im0 = o.getStats().im;
            const ConcMarkStats cm0 = o.getStats().cm;
            const ParMarkStats pm0 = o.getStats().pm;
#endif
            const int cycles = 3;
            for (int c = 0; c < cycles; ++c) {
                tlh(a)->test_force_major_trigger_ = true;
                a.minorGC();
                while (OA::cycleActive(og(a))) {
                    for (int i = 0; i < 2000; ++i) (void)alloc::allocInt(i);   // garbage
                    std::this_thread::sleep_for(std::chrono::milliseconds(sleep_ms));   // "compute"
                    a.minorGC();
                }
            }
#if ENABLE_GC_STATS
            const IncrMarkStats& im1 = o.getStats().im;
            const ConcMarkStats& cm1 = o.getStats().cm;
            const ParMarkStats& pm1 = o.getStats().pm;
            const double inpause_mark_ms = mode == 0
                ? (pm1.run_ns_total - pm0.run_ns_total) / 1e6 / cycles
                : ((cm1.assist_ns_total - cm0.assist_ns_total) +
                   (cm1.closing_ns_total - cm0.closing_ns_total)) / 1e6 / cycles;
            std::printf("    E7 %.1f GB (minor every %d ms) mode %u: in-pause mark per cycle %.3f ms; t0 max %.3f ms "
                        "(prepare max %.3f); handoff max %.3f ms; assists %llu closings %llu; units/cycle %llu\n",
                        gb, sleep_ms, mode, inpause_mark_ms, im1.t0_ns_max / 1e6, im1.t0_prep_ns_max / 1e6,
                        im1.handoff_ns_max / 1e6,
                        (unsigned long long)(cm1.assists - cm0.assists),
                        (unsigned long long)(cm1.closings_with_work - cm0.closings_with_work),
                        (unsigned long long)OA::prevCycleUnits(o));
#endif
        }
    });
