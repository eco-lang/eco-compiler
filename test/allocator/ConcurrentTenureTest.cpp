/**
 * threaded-gc-07 Part B (plans/threaded-gc-07-concurrent-tenuring.md Step 9):
 * the tenure job on the heap's collector thread (tenure_mode 2). Mode 1 (the
 * job inside the hand-over pause) is mode 2's exact oracle at one minor
 * worker with the exact engine: every counter AND every old-gen placement.
 */

#include "ConcurrentTenureTest.hpp"

#include <csignal>
#if !defined(_WIN32)
#include <dirent.h>
#endif
#include <thread>
#include <cstdio>
#include <cstdlib>
#include <functional>
#if !defined(_WIN32)
#include <sys/wait.h>
#include <unistd.h>
#endif
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

HeapConfig tenureConfig(uint32_t mode, uint32_t threads = 1, uint32_t help_threads = 1) {
    HeapConfig cfg;
    cfg.alloc_buffer_size          = 32 * 1024;
    cfg.nursery_block_count        = 64;
    cfg.nursery_max_block_count    = 64;
    cfg.initial_old_gen_size       = 256 * 1024;
    cfg.max_heap_size              = 512ULL * 1024 * 1024;
    cfg.large_object_threshold     = 8 * 1024;
    cfg.large_ptr_nursery_max_size = 8 * 1024;
    cfg.decommit_on_oldgen_release = false;
    cfg.old_gen_bitmap_alloc       = true;
    cfg.gc_thread_mode             = 0;
    cfg.gc_minor_threads           = threads;
    cfg.minor_lab_bytes            = 4096;
    cfg.minor_parallel_min_bytes   = 0;
    cfg.nursery_regions            = 1;
    cfg.tenure_mode                = mode;
    cfg.tenure_help                = 1;
    cfg.tenure_help_threads        = help_threads;
    cfg.validate();
    return cfg;
}

ThreadLocalHeap* heapOf(Allocator& a) { return AllocatorTestAccess::getThreadHeap(a); }
NurserySpace& nurseryOf(Allocator& a) { return heapOf(a)->getNursery(); }
OldGenSpace& oldgenOf(Allocator& a) { return heapOf(a)->getOldGen(); }

struct Run {
    uint64_t checksum = 0, survived = 0, promoted = 0, minors = 0, majors = 0;
    uint64_t allocated = 0, committed = 0, late = 0, stops = 0;
    std::vector<uintptr_t> layout;
};

// A deterministic workload with a major every 40 minors of mutator time.
Run runScript(const HeapConfig& cfg, uint64_t seed, uint64_t stop_after, uint64_t sleep_us,
              bool majors = true) {
    auto& a = initRegionAllocator(cfg);
    NurserySpace& ns = nurseryOf(a);
    ns.test_record_layout_ = true;
    ns.test_layout_.clear();
    ns.test_tenure_force_stop_after_ = stop_after;
    ns.test_tenure_sleep_us_ = sleep_us;
    Run r;
    {
        minortest::Workload w(a, 128, seed);
        for (int g = 0; g < 60; ++g) {
            w.run(1500);
            if (majors && g % 20 == 19) a.majorGC();
            r.checksum = r.checksum * 31 + w.checksum();
        }
        a.minorGC();
        r.checksum = r.checksum * 31 + w.checksum();
    }
    NTA::tenureFlush(ns, oldgenOf(a));
    ns.test_tenure_force_stop_after_ = 0;
    ns.test_tenure_sleep_us_ = 0;
    ns.test_record_layout_ = false;
    r.layout = ns.test_layout_;
    ns.test_layout_.clear();
#if ENABLE_GC_STATS
    const GCStats& st = ns.getStats();
    r.survived = st.objects_survived;
    r.promoted = st.objects_promoted;
    r.minors = st.minor_gc_count;
    r.late = st.rg.late;
    r.stops = st.rg.stops;
#endif
    r.allocated = oldgenOf(a).getAllocatedBytes();
    r.committed = oldgenOf(a).getCommittedBytes();
    return r;
}

[[maybe_unused]] bool sameRun(const Run& x, const Run& y, const char* what) {
    const bool ok = x.checksum == y.checksum && x.survived == y.survived && x.promoted == y.promoted &&
                    x.minors == y.minors && x.allocated == y.allocated && x.committed == y.committed &&
                    x.layout == y.layout;
    if (!ok) {
        std::fprintf(stderr, "%s: checksum %d survived %llu/%llu promoted %llu/%llu minors %llu/%llu "
                     "allocated %llu/%llu committed %llu/%llu layout %zu/%zu same %d\n", what,
                     (int)(x.checksum == y.checksum), (unsigned long long)x.survived,
                     (unsigned long long)y.survived, (unsigned long long)x.promoted,
                     (unsigned long long)y.promoted, (unsigned long long)x.minors,
                     (unsigned long long)y.minors, (unsigned long long)x.allocated,
                     (unsigned long long)y.allocated, (unsigned long long)x.committed,
                     (unsigned long long)y.committed, x.layout.size(), y.layout.size(),
                     (int)(x.layout == y.layout));
    }
    return ok;
}

#if !defined(_WIN32)   // fork()ed children: POSIX only; those tests are no-ops on Windows
// Runs the script in a forked child and returns its figures (the layout as a
// hash + length). Every child forks from the same parent state, so the
// long-lived root set (an unordered_set of slot ADDRESSES, whose iteration
// order is the start-set order) sees identical malloc placement in every arm.
Run runInChild(const HeapConfig& cfg, uint64_t seed, uint64_t stop_after, uint64_t sleep_us,
               bool majors = true) {
    int fds[2];
    if (pipe(fds) != 0) TEST_FAIL("pipe");
    const pid_t pid = fork();
    if (pid == 0) {
        close(fds[0]);
        const Run r = runScript(cfg, seed, stop_after, sleep_us, majors);
        uint64_t h = 1469598103934665603ull;
        for (uintptr_t a : r.layout) { h ^= a; h *= 1099511628211ull; }
        const uint64_t out[11] = {r.checksum, r.survived, r.promoted, r.minors, r.majors, r.allocated,
                                  r.committed, r.late, r.stops, h, r.layout.size()};
        (void)!write(fds[1], out, sizeof out);
        _exit(0);
    }
    close(fds[1]);
    uint64_t in[11] = {};
    const ssize_t got = read(fds[0], in, sizeof in);
    close(fds[0]);
    int status = 0;
    waitpid(pid, &status, 0);
    if (got != static_cast<ssize_t>(sizeof in) || !WIFEXITED(status) || WEXITSTATUS(status) != 0)
        TEST_FAIL("child run failed");
    Run r;
    r.checksum = in[0]; r.survived = in[1]; r.promoted = in[2]; r.minors = in[3]; r.majors = in[4];
    r.allocated = in[5]; r.committed = in[6]; r.late = in[7]; r.stops = in[8];
    r.layout = {static_cast<uintptr_t>(in[9]), static_cast<uintptr_t>(in[10])};
    return r;
}
#endif

}  // namespace

Testing::TestCase testTenureStopResumeSameLayout(
    "threaded-gc-07: a job stopped after k items and finished in the pause places every copy as mode 1",
    []() {
#if !defined(_WIN32)
        const Run ref = runInChild(tenureConfig(1), 31, 0, 0);
        TEST_ASSERT(ref.promoted > 0 && ref.layout[1] > 0);
        for (uint64_t k : {1ull, 13ull, 5000ull}) {
            const Run m2 = runInChild(tenureConfig(2), 31, k, 0);
            if (!sameRun(m2, ref, "stop/resume")) TEST_FAIL("mode 2 with forced stops differs from mode 1");
        }
#endif
    });

Testing::TestCase testTenureModesAgreeOnCounters(
    "threaded-gc-07: E2 in a unit test: modes 1 and 2 agree on every counter and placement (1 worker)",
    []() {
#if !defined(_WIN32)
        for (uint64_t seed : {41ull, 42ull}) {
            const Run m1 = runInChild(tenureConfig(1), seed, 0, 0);
            const Run m2 = runInChild(tenureConfig(2), seed, 0, 0);
            if (!sameRun(m2, m1, "modes")) TEST_FAIL("tenure modes 1 and 2 differ");
        }
        // With 4 minor workers: the object class still agrees.
        const Run a4 = runScript(tenureConfig(1, 4), 43, 0, 0);
        const Run b4 = runScript(tenureConfig(2, 4), 43, 0, 0);
        TEST_ASSERT(a4.checksum == b4.checksum && a4.survived == b4.survived &&
                    a4.promoted == b4.promoted && a4.minors == b4.minors);
#endif
    });

Testing::TestCase testTenureLateHelpParallel(
    "threaded-gc-07: a slowed collector is stopped and its job finished by help (objects equal mode 1)",
    []() {
        const Run m1 = runScript(tenureConfig(1, 1), 51, 0, 0, /*majors=*/false);
        const Run slow = runScript(tenureConfig(2, 1, 4), 51, 0, 20, /*majors=*/false);
        TEST_ASSERT(slow.checksum == m1.checksum && slow.survived == m1.survived &&
                    slow.promoted == m1.promoted && slow.minors == m1.minors);
#if ENABLE_GC_STATS
        TEST_ASSERT(slow.late > 0);   // non-vacuous: help ran
#endif
    });

Testing::TestCase testTenureForkChild(
    "threaded-gc-07: fork while a tenure job runs: parent and child each finish it and continue",
    []() {
#if !defined(_WIN32)
        auto& a = initRegionAllocator(tenureConfig(2));
        NurserySpace& ns = nurseryOf(a);
        minortest::Workload w(a, 64, 61);
        w.run(5000);
        a.minorGC();
        w.run(5000);
        ns.test_tenure_sleep_us_ = 200;   // the next job is still running at the fork
        a.minorGC();
        ns.test_tenure_sleep_us_ = 0;
        const uint64_t before = w.checksum();
        const pid_t pid = fork();
        if (pid == 0) {
            int ok = 1;
            if (w.checksum() != before) ok = 0;
            for (int g = 0; g < 20 && ok; ++g) {
                w.run(2000);
                a.minorGC();
                (void)w.checksum();
            }
            _exit(ok ? 0 : 3);
        }
        for (int g = 0; g < 20; ++g) {
            w.run(2000);
            a.minorGC();
            (void)w.checksum();
        }
        int status = 0;
        TEST_ASSERT(waitpid(pid, &status, 0) == pid);
        TEST_ASSERT(WIFEXITED(status) && WEXITSTATUS(status) == 0);
#endif
    });

Testing::TestCase testTenureExitWhileRunning(
    "threaded-gc-07: process exit with a running tenure job (a child process) is clean",
    []() {
#if !defined(_WIN32)
        const pid_t pid = fork();
        if (pid == 0) {
            auto& a = initRegionAllocator(tenureConfig(2));
            NurserySpace& ns = nurseryOf(a);
            minortest::Workload w(a, 64, 71);
            for (int g = 0; g < 6; ++g) {
                w.run(3000);
                a.minorGC();
            }
            ns.test_tenure_sleep_us_ = 500;   // a long job at exit
            w.run(3000);
            a.minorGC();
            std::exit(0);                      // atexit + static destructors with the job running
        }
        int status = 0;
        TEST_ASSERT(waitpid(pid, &status, 0) == pid);
        TEST_ASSERT(WIFEXITED(status) && WEXITSTATUS(status) == 0);
#endif
    });

namespace {
uint64_t cycleScript(uint32_t mode, uint32_t threads) {
    HeapConfig cfg = tenureConfig(mode, threads);
    cfg.incremental_mark = true;
    cfg.incremental_mark_slices = 6;
    cfg.incremental_mark_min_slice_units = 64;
    cfg.gc_mark_threads = 2;
    cfg.conc_mark = 2;
    cfg.conc_mark_threads = 2;
    cfg.conc_mark_assist_lag = 1;
    cfg.validate();
    auto& a = initRegionAllocator(cfg);
    ThreadLocalHeap* h = heapOf(a);
    uint64_t sum = 0;
    {
        minortest::Workload w(a, 128, 81);
        for (int g = 0; g < 60; ++g) {
            w.run(2500);
            if (g % 12 == 0 && !h->getOldGen().cycleActive()) h->test_force_major_trigger_ = true;
            a.minorGC();
            if (g % 10 == 0) sum = sum * 31 + w.checksum();
        }
        while (h->getOldGen().cycleActive()) a.minorGC();
        sum = sum * 31 + w.checksum();
    }
    return sum;
}
}  // namespace

Testing::TestCase testTenureDuringCycle(
    "threaded-gc-07: tenure jobs (modes 1, 2) under running concurrent mark cycles keep every value",
    []() {
        const uint64_t ref = cycleScript(1, 1);
        TEST_ASSERT(cycleScript(2, 1) == ref);
        TEST_ASSERT(cycleScript(2, 4) == ref);
    });

// ============================================================================
// Negative controls (P§3.19): each broken premise is caught by its validator.
// Each runs in a forked child that must die by SIGABRT.
// ============================================================================
namespace {
#if !defined(_WIN32)
bool childAbortsT(uint32_t mode, const std::function<void(Allocator&)>& arm) {
    const pid_t pid = fork();
    if (pid == 0) {
        auto& a = initRegionAllocator(tenureConfig(mode));
        arm(a);
        minortest::Workload w(a, 128, 3);
        for (int g = 0; g < 30; ++g) {
            w.run(4000);
            a.minorGC();
            (void)w.checksum();
        }
        _exit(0);   // survived: the validator did not fire
    }
    int status = 0;
    if (waitpid(pid, &status, 0) != pid) return false;
    return WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT;
}
#endif
}  // namespace

Testing::TestCase testTenureNegativeControls(
    "threaded-gc-07: TV1 / TV7 / the body check / TV5 fire on a skipped start, heal, re-mark, grant",
    []() {
#if !defined(_WIN32)
        for (uint32_t mode : {1u, 2u}) {
            // TV1 (every build): a skipped start entry leaves a live object untenured.
            TEST_ASSERT(childAbortsT(mode, [](Allocator& a) { nurseryOf(a).test_tenure_skip_start_every_ = 3; }));
            // The unbroken control survives.
            TEST_ASSERT(!childAbortsT(mode, [](Allocator&) {}));
        }
#if ECO_HEAP_VALIDATE
        // A skipped heal slot leaves a slot pointing into the retired (poisoned) extent.
        TEST_ASSERT(childAbortsT(1, [](Allocator& a) { nurseryOf(a).test_heal_skip_one_ = true; }));
#endif
#endif
    });

Testing::TestCase testTenureBodyRemarkControl(
    "threaded-gc-07: skipping the hand-over body re-mark is caught at the merge",
    []() {
#if !defined(_WIN32)
        const pid_t pid = fork();
        if (pid == 0) {
            auto& a = initRegionAllocator(tenureConfig(1));
            nurseryOf(a).test_no_body_remark_ = true;
            std::u16string big(40000, u'q');
            HPointer s = alloc::allocString(big);
            a.getRootSet().addRoot(&s);
            for (int g = 0; g < 4; ++g) {
                for (int i = 0; i < 20000; ++i) (void)alloc::allocInt(i);
                a.minorGC();
            }
            _exit(0);
        }
        int status = 0;
        TEST_ASSERT(waitpid(pid, &status, 0) == pid);
        TEST_ASSERT(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT);
#endif
    });

Testing::TestCase testTenureShrinkSkipsGranted(
    "threaded-gc-07: a granted block is never released, detached or reused before the merge",
    []() {
        auto& a = initRegionAllocator(tenureConfig(1));
        OldGenSpace& og = oldgenOf(a);
        {
            minortest::Workload w(a, 128, 91);
            for (int g = 0; g < 10; ++g) {
                w.run(3000);
                a.minorGC();
                // Between minors (mode 1): the job is Done and its grant live.
                TEST_ASSERT(og.activeTenureGrants() <= 1);
                a.majorGC();   // merges first: no grant survives into a mark
                TEST_ASSERT(og.activeTenureGrants() == 0);
            }
        }
        og.validateTenureBlocks("test");
    });


Testing::TestCase testTenureCollectorThreads(
    "threaded-gc-07 L3: B = 2 / 4 collector threads reproduce mode 1's objects (placement free)",
    []() {
#if !defined(_WIN32)
        for (uint64_t seed : {101ull, 102ull}) {
            const Run m1 = runInChild(tenureConfig(1), seed, 0, 0);
            for (uint32_t B : {2u, 4u}) {
                for (uint32_t n : {1u, 4u}) {
                    HeapConfig cfg = tenureConfig(2, n, /*help_threads=*/0);
                    cfg.tenure_collector_threads = B;
                    cfg.validate();
                    const Run r = runInChild(cfg, seed, 0, 0);
                    if (r.checksum != m1.checksum || r.survived != m1.survived ||
                        r.promoted != m1.promoted || r.minors != m1.minors) {
                        std::fprintf(stderr, "B=%u n=%u seed=%llu: promoted %llu/%llu survived %llu/%llu\n",
                                     B, n, (unsigned long long)seed, (unsigned long long)r.promoted,
                                     (unsigned long long)m1.promoted, (unsigned long long)r.survived,
                                     (unsigned long long)m1.survived);
                        TEST_FAIL("L3 collector threads changed the object class");
                    }
                }
            }
        }
        // Late help with B members: majors in the script stop running jobs.
        HeapConfig cfg = tenureConfig(2, 4, 0);
        cfg.tenure_collector_threads = 4;
        cfg.validate();
        uint64_t sum = 0;
        for (int rep = 0; rep < 3; ++rep) {
            const Run r = runInChild(cfg, 103, 0, 0);
            if (rep == 0) sum = r.checksum;
            TEST_ASSERT(r.checksum == sum);
        }
#endif
    });

namespace {
#if !defined(_WIN32)
size_t threadCount() {
    size_t n = 0;
    if (DIR* d = opendir("/proc/self/task")) {
        while (dirent* e = readdir(d)) if (e->d_name[0] != '.') ++n;
        closedir(d);
    }
    return n;
}
#endif
}  // namespace

Testing::TestCase testTenureRespawnAndForkStorm(
    "threaded-gc-07 E11: 100 spawned heaps and 100 forks in mode 2: no failure, no leaked collector threads",
    []() {
#if !defined(_WIN32)
        HeapConfig cfg = tenureConfig(2, 1, 0);
        cfg.tenure_collector_threads = 2;
        cfg.validate();
        auto& a = initRegionAllocator(cfg);
        {
            minortest::Workload w(a, 32, 5);
            w.run(2000);
            a.minorGC();
        }
        const size_t threads0 = threadCount();
        // CR-012 (HEAP_007): the spawned heaps run while this thread's heap is
        // live, a second mutator, so this harness opts in (unsupported mode).
        Allocator::instance().allowMultipleMutators(true);
        // Spawn-heavy: each thread claims a region slot (Issue #40 reuse), runs
        // mode-2 minors with jobs in flight, and exits with a job running.
        for (int it = 0; it < 100; ++it) {
            std::thread t([&] {
                Allocator& al = Allocator::instance();
                al.initThread();
                {
                    // Small: a destroyed heap's old-gen blocks are not returned to
                    // the allocator (pre-existing), so 100 heaps share one region.
                    minortest::Workload w(al, 16, 100 + static_cast<uint64_t>(it));
                    for (int g = 0; g < 3; ++g) {
                        w.run(300);
                        al.minorGC();
                    }
                    (void)w.checksum();
                }
                al.cleanupThread();
            });
            t.join();
        }
        const size_t threads1 = threadCount();
        if (threads1 > threads0 + 2) {
            std::fprintf(stderr, "threads before %zu after %zu\n", threads0, threads1);
            TEST_FAIL("collector threads leaked across spawned heaps");
        }
        // Fork-heavy: every child finishes the inherited job and runs minors.
        int bad = 0;
        minortest::Workload w(a, 64, 6);
        for (int it = 0; it < 100; ++it) {
            w.run(800);
            a.minorGC();
            const pid_t pid = fork();
            if (pid == 0) {
                for (int g = 0; g < 3; ++g) {
                    w.run(800);
                    a.minorGC();
                }
                (void)w.checksum();
                _exit(0);
            }
            int status = 0;
            if (waitpid(pid, &status, 0) != pid || !WIFEXITED(status) || WEXITSTATUS(status) != 0) ++bad;
        }
        TEST_ASSERT(bad == 0);
#endif
    });

Testing::TestCase testTenureFifoOrder(
    "threaded-gc-07: breadth-first (FIFO) tenure order keeps objects, and stop/resume placement is exact",
    []() {
#if !defined(_WIN32)
        HeapConfig m1 = tenureConfig(1);
        m1.tenure_fifo_order = true;
        m1.validate();
        HeapConfig m2 = tenureConfig(2);
        m2.tenure_fifo_order = true;
        m2.validate();
        const Run ref_lifo = runInChild(tenureConfig(1), 131, 0, 0);
        const Run ref = runInChild(m1, 131, 0, 0);
        TEST_ASSERT(ref.checksum == ref_lifo.checksum && ref.promoted == ref_lifo.promoted &&
                    ref.survived == ref_lifo.survived && ref.minors == ref_lifo.minors);
        TEST_ASSERT(ref.layout != ref_lifo.layout);   // non-vacuous: a different order
        for (uint64_t k : {1ull, 37ull}) {
            const Run r = runInChild(m2, 131, k, 0);
            if (!sameRun(r, ref, "fifo stop/resume")) TEST_FAIL("FIFO mode 2 with forced stops differs from FIFO mode 1");
        }
#endif
    });

// HEAP_072 (2-gc-bugs.md bug 2): an extent's ylos_gen list names its
// generation's YLOS objects by address. A major frees a dead member; a new
// YLOS object reusing that cell before the next minor must NOT be taken for
// the generation's member (it was: scanned read-only as hand-over, promoted in
// place at the merge with its children still in the nursery -- an old->young
// pointer the next major read as garbage, "HEAP_044 size-0 Custom").
Testing::TestCase testTenureYlosCellReuse(
    "threaded-gc-07: a new YLOS object in a generation member's freed cell stays young (HEAP_072)",
    []() {
        auto& a = initRegionAllocator(tenureConfig(1));
        OldGenSpace& og = oldgenOf(a);
        constexpr size_t kElems = 1600;   // 12.8 KB > large_object_threshold: a YLOS array
        auto freshArray = [&](int64_t base) {
            HPointer tmp = alloc::listNil();
            a.getRootSet().addRoot(&tmp);
            std::vector<HPointer> e(kElems);
            for (size_t i = 0; i < kElems; ++i) {
                e[i] = alloc::allocInt(base + static_cast<i64>(i));
                tmp = alloc::cons(alloc::boxed(e[i]), tmp, true);   // keeps the Ints alive
            }
            // The cons list roots the Ints across the array allocation; re-read
            // them from it (a GC may have moved them).
            size_t i = kElems;
            for (HPointer c = tmp; c.ptr_ind == 0;) {
                Cons* cell = static_cast<Cons*>(a.resolve(c));
                e[--i] = cell->head.p;
                c = cell->tail;
            }
            HPointer arr = alloc::arrayFromPointers(e);
            a.getRootSet().removeRoot(&tmp);
            return arr;
        };

        // A joins a generation at its first minor, then dies and a major frees it.
        HPointer A = freshArray(0);
        a.getRootSet().addRoot(&A);
        void* a_obj = a.resolve(A);
        TEST_ASSERT(og.isYoungLarge(a_obj));
        a.minorGC();
        TEST_ASSERT(og.isYoungLarge(a_obj));
        a.getRootSet().removeRoot(&A);
        a.majorGC();
        TEST_ASSERT(!og.isYoungLarge(a_obj));

        // B takes A's cell (same size class, LIFO reuse) before the next minor.
        HPointer B = freshArray(100000);
        a.getRootSet().addRoot(&B);
        void* b_obj = a.resolve(B);
        if (b_obj != a_obj) {
            a.getRootSet().removeRoot(&B);
            TEST_FAIL("B did not reuse A's cell: the scenario is not exercised");
        }
        // Hand-over of A's generation, then its merge; then B's own tenure.
        for (int m = 0; m < 4; ++m) {
            a.minorGC();
            // While B is young its children may be young; once promoted, none may be.
            if (!og.isYoungLarge(b_obj)) {
                ElmArray* arr = static_cast<ElmArray*>(b_obj);
                for (u32 i = 0; i < arr->length; ++i) {
                    void* c = AllocatorTestAccess::fromPointer(arr->elements[i].p);
                    if (a.isInNursery(c)) {
                        a.getRootSet().removeRoot(&B);
                        TEST_FAIL("B was promoted with a child still in the nursery");
                    }
                }
            }
        }
        a.majorGC();
        ElmArray* arr = static_cast<ElmArray*>(a.resolve(B));
        for (u32 i = 0; i < arr->length; ++i) {
            ElmInt* v = static_cast<ElmInt*>(a.resolve(arr->elements[i].p));
            TEST_ASSERT(getHeader(v)->tag == Tag_Int && v->value == 100000 + static_cast<i64>(i));
        }
        a.getRootSet().removeRoot(&B);
    });
