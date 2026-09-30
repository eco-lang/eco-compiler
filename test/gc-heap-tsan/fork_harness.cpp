// TLA+ model M6, wave 2 (plans/threaded-gc-tla-M6-lifecycle.md §8; register CR-008):
// the fork harness. The REAL allocator (helper pool on, concurrent marking on),
// driven by a synthetic mutator while a thread forks at chosen or random points.
// Not under TSan (TSan does not support fork in a threaded process); built with
// asserts and heap validation on, like the `build` preset.
//
//   gc-fork-harness <arm> [trials] [seed]
//
// Arms. Each trial runs in its own process (forked from the single-threaded
// driver) with a hard deadline, so a hung or aborted trial is counted, never
// waited for. Each forked child probes under alarm(), so a hung child is counted
// too. An arm that reproduces its register entry exits 1 (a guard that "fails on
// the current code"); an arm that does not, exits 0.
//   mut        the supported contract: the heap's own mutator forks between
//              pauses (mid-cycle included); the child finishes the cycle, checks
//              every rooted value, and calls exit(). Exits 1 on any failure.
//   host       another thread forks at random; the child probes
//              thread_mutex_ (CR-015) and then drains the helper jobs (CR-003),
//              and _exits.
//   host-exit  another thread forks at random; the child calls exit() (atexit
//              handlers, then ~Allocator: thread_mutex_, drainAll, heap teardown).
//   two-heap   two mutators, each with its own heap; one forks between its own
//              pauses while the other runs; its child probes thread_mutex_ and
//              the helper jobs, runs its own heap on, then calls exit().
//   relaunch   another thread forks at random while episodes run with slow
//              items; harness atfork handlers classify each fork: a launch after
//              stopAllForFork and before the gang's m_ lock (CR-004 window), or a
//              prepare that waited out a relaunched episode (CR-023).
//   closing    another thread forks while the closing joins run (background
//              members held until the closing, so the join does the marking):
//              CR-005, the parent aborts in closingFinish's assert.
//   closing-early  the mutator asks for a fork just before the closing step's
//              minor, while the member is inside a slow item (CR-005's wider
//              window: a stop the closing's first reap does not see finished).
//
// Output: one "RESULT ..." line per trial (the driver prints them) and a summary.
#include "Allocator.hpp"
#include "GCHelperPool.hpp"
#include "HeapHelpers.hpp"
#include "OldGenSpace.hpp"
#include "PageWork.hpp"
#include "ThreadLocalHeap.hpp"
#include "TlaTrace.hpp"

#include <execinfo.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <memory>
#include <random>
#include <string>
#include <thread>
#include <vector>

using namespace Elm;
using OA = OldGenSpaceTestAccess;

#if ECO_TLA_TRACE_ENABLED
namespace Elm::gc { extern bool tla_m6; }   // GCHelperPool.cpp: M6's hooks log while set
#endif

namespace {

uint64_t nowNs() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}

[[noreturn]] void die(const char* w) {
    std::fprintf(stderr, "fork_harness FAIL: %s\n", w);
    std::fflush(stderr);
    _exit(3);
}

// ---------------------------------------------------------------------------
// Child-side probes. A forked child has one thread; SIGALRM ends it with a code
// that says where it hung (alarm and _exit are async-signal-safe).
// ---------------------------------------------------------------------------
volatile sig_atomic_t g_phase = 0;
bool g_backtrace = false;   // FORK_HARNESS_BT=1: a hung child prints its stack (debugging)
void onAlarm(int) {
    if (g_backtrace) {
        void* frames[64];
        const int n = backtrace(frames, 64);
        backtrace_symbols_fd(frames, n, 2);
    }
    _exit(10 + g_phase);
}
void onAbort(int sig) {
    if (g_backtrace) {
        void* frames[64];
        const int n = backtrace(frames, 64);
        backtrace_symbols_fd(frames, n, 2);
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

void armAlarm(int phase, unsigned secs) {
    g_phase = phase;
    alarm(secs);
}

enum ChildCode : int {
    kClean = 0,
    kHangTm = 11,       // phase 1: thread_mutex_ is held by a thread that does not exist (CR-015)
    kHangDrain = 12,    // phase 2: drainHelperWork waits for a job no thread will run (CR-003)
    kHangHeap = 13,     // phase 3: the child's own heap did not make progress
    kHangAtexit = 14,   // phase 4: exit()'s atexit handlers (stopAllAtExit) hung
    kHangDtor = 15,     // phase 5: exit()'s static destructors (~Allocator) hung
};

const char* codeName(int st) {
    if (WIFSIGNALED(st)) return WTERMSIG(st) == SIGABRT ? "abort" : "signal";
    if (!WIFEXITED(st)) return "other";
    switch (WEXITSTATUS(st)) {
        case kClean: return "clean";
        case kHangTm: return "hang-tm";
        case kHangDrain: return "hang-drain";
        case kHangHeap: return "hang-heap";
        case kHangAtexit: return "hang-atexit";
        case kHangDtor: return "hang-dtor";
        default: return "fail";
    }
}

// Registered in the trial before any GC hook, so it runs AFTER stopAllAtExit
// (atexit runs in reverse order) and before the static destructors.
void markAtexitDone() { g_phase = 5; }

// Phase 1 then 2: thread_mutex_ (getCombinedStats takes it and nothing else),
// then every helper job (drainHelperWork takes it and waits on each slot).
void probeAllocator(Allocator& a) {
    armAlarm(1, 2);
    (void)a.getCombinedStats();
    armAlarm(2, 2);
    a.drainHelperWork();
    alarm(0);
}

// Waits for a forked child with a deadline; kills it after the deadline.
int waitChild(pid_t pid, int deadline_ms) {
    int st = 0;
    for (int waited = 0;; waited += 2) {
        const pid_t r = waitpid(pid, &st, WNOHANG);
        if (r == pid) return st;
        if (r < 0) return -1;
        if (waited >= deadline_ms) {
            kill(pid, SIGKILL);
            waitpid(pid, &st, 0);
            return -2;   // the child outlived the deadline
        }
        usleep(2000);
    }
}

// ---------------------------------------------------------------------------
// The heap: an old graph of pairs, kept values checked after each cycle.
// ---------------------------------------------------------------------------
struct Root {
    Allocator& a;
    HPointer h;
    Root(Allocator& al, HPointer v) : a(al), h(v) { a.getRootSet().addRoot(&h); }
    ~Root() { a.getRootSet().removeRoot(&h); }
};

struct Opts {
    unsigned slices = 4;
    unsigned mark_threads = 2;     // 2: the closing runs on GCMarkGang (run_m_); 1: inline
    unsigned minor_threads = 1;    // > 1 registers the mark gang first (prepare order bg_first)
    int old_pairs = 20000;
    int big_arrays = 0;            // old arrays of 20k pointers: slow items for the markers
    int alloc_per_step = 300;
    bool pool = true;              // gc_thread_mode 2 (the helper pool); false: 0
};

HeapConfig makeConfig(const Opts& o) {
    HeapConfig cfg;
    cfg.alloc_buffer_size = 32 * 1024;
    cfg.nursery_block_count = o.minor_threads > 1 ? 64 : 8;
    cfg.nursery_max_block_count = o.minor_threads > 1 ? 64 : 8;
    cfg.gc_minor_threads = o.minor_threads;
    cfg.minor_lab_bytes = 4096;
    cfg.minor_parallel_min_bytes = 0;
    cfg.initial_old_gen_size = 256 * 1024;
    cfg.max_heap_size = 512ULL << 20;
    cfg.large_object_threshold = 8 * 1024;
    // The helper pool, with jobs at most pause ends: discards (delay 0) and populates.
    cfg.gc_thread_mode = o.pool ? 2 : 0;
    cfg.gc_helper_threads = 1;
    cfg.decommit_on_oldgen_release = true;
    cfg.decommit_delay_syncs = 0;
    cfg.commit_ahead_bytes = size_t{2} << 20;
    cfg.incremental_mark = true;
    cfg.incremental_mark_slices = o.slices;
    cfg.incremental_mark_min_slice_units = 64;
    cfg.gc_mark_threads = o.mark_threads;
    cfg.conc_mark = 2;
    cfg.conc_mark_threads = 1;
    cfg.conc_mark_priority = 0;
    cfg.conc_mark_assist_lag = 4096;   // no paced assists: only the closing runs the mark gang
    cfg.nursery_regions = 0;
    cfg.validate();
    return cfg;
}

struct Heap {
    Allocator& a;
    ThreadLocalHeap* h;
    std::mt19937_64 rng;
    std::vector<std::unique_ptr<Root>> keep;
    std::vector<int64_t> want;
    int step = 0;

    Heap(Allocator& al, uint64_t seed, const Opts& o) : a(al), h(AllocatorTestAccess::getThreadHeap(al)), rng(seed) {
        for (int i = 0; i < o.old_pairs; ++i) {
            Root x(a, alloc::allocInt(i));
            Root y(a, alloc::allocInt(-i));
            HPointer t = alloc::tuple2(alloc::boxed(x.h), alloc::boxed(y.h), 0);
            if (i % 16 == 0) { keep.push_back(std::make_unique<Root>(a, t)); want.push_back(i); }
        }
        for (int b = 0; b < o.big_arrays; ++b) {
            // An array of 20k boxed pointers: one slow item for a marker. No
            // allocation happens between the array and its pushes.
            Root filler(a, alloc::allocInt(b));
            Root arr(a, alloc::allocArray(20000));
            void* ap = a.resolve(arr.h);
            for (int k = 0; k < 20000; ++k) alloc::arrayPush(ap, alloc::boxed(filler.h), true);
            keep.push_back(std::make_unique<Root>(a, arr.h));
            want.push_back(-2);
        }
    }
    OldGenSpace& og() { return h->getOldGen(); }
    bool cycleActive() { return OA::cycleActive(og()); }
    // One mutator step: churn, maybe start a cycle; the minor is the caller's.
    void churn(int n, int cycle_every) {
        for (int i = 0; i < n; ++i) {
            const size_t len = 1 + rng() % 40;
            std::vector<u16> buf(len, static_cast<u16>('a' + i % 26));
            Root s(a, alloc::allocString(buf.data(), len));
            Root v(a, alloc::allocInt(step));
            HPointer t = alloc::tuple2(alloc::boxed(s.h), alloc::boxed(v.h), 0);
            if (rng() % 64 == 0) {
                const size_t k = rng() % keep.size();
                if (want[k] != -2) {
                    keep[k]->h = t;
                    want[k] = -1000000 - step;
                }
            }
        }
        if (cycle_every > 0 && step % cycle_every == 0 && !cycleActive()) h->test_force_major_trigger_ = true;
        ++step;
    }
    bool verify() {
        for (size_t k = 0; k < keep.size(); ++k) {
            void* o = a.resolve(keep[k]->h);
            if (o == nullptr) return false;
            if (want[k] >= 0) {
                void* x = a.resolve(static_cast<Tuple2*>(o)->a.p);
                if (x == nullptr || getHeader(x)->tag != Tag_Int ||
                    static_cast<ElmInt*>(x)->value != want[k]) return false;
            } else if (want[k] <= -1000000) {
                void* x = a.resolve(static_cast<Tuple2*>(o)->b.p);
                if (x == nullptr || getHeader(x)->tag != Tag_Int ||
                    static_cast<ElmInt*>(x)->value != -(want[k] + 1000000)) return false;
            }
        }
        return true;
    }
    void finishCycle() {
        while (cycleActive()) { churn(50, 0); a.minorGC(); }
    }
};

Allocator& initHeap(const Opts& o) {
    HeapConfig cfg = makeConfig(o);
    auto& a = Allocator::instance();
    a.initialize(cfg);
    AllocatorTestAccess::reset(a, &cfg);
    a.initThread();
    return a;
}

// ---------------------------------------------------------------------------
// Harness atfork handlers (relaunch arm). kFirst is registered after the gang
// exists, so its prepare runs FIRST; kLast before any GC hook, so its prepare
// runs LAST (after the gangs locked their m_) and its parent handler runs first.
// ---------------------------------------------------------------------------
gc::GCBackgroundGang* g_gang = nullptr;
std::atomic<uint64_t> g_l0{0}, g_l1{0}, g_t0{0}, g_t1{0}, g_w0{0}, g_w1{0};
std::atomic<bool> g_r1{false};
std::atomic<uint64_t> g_lstop{~0ull};   // trace build: launches when this fork's stop was stored
void prepFirst() {
    if (g_gang == nullptr) return;
    g_lstop.store(~0ull);
    g_t0.store(nowNs());
    g_l0.store(g_gang->stats().launches.load());
    g_w0.store(g_gang->stats().join_wait_ns_total.load());
}
void prepLast() {
    if (g_gang == nullptr) return;
    g_l1.store(g_gang->stats().launches.load());
    g_w1.store(g_gang->stats().join_wait_ns_total.load());
    g_r1.store(g_gang->running());
    g_t1.store(nowNs());
}

#if ECO_TLA_TRACE_ENABLED
thread_local bool tl_host = false;   // this thread is the host (the probe callback asks)
#endif

// ---------------------------------------------------------------------------
// The forking thread ("host": not the heap's mutator).
// ---------------------------------------------------------------------------
struct Host {
    std::atomic<bool> stop{false};
    std::atomic<bool> go{false};        // closing-early: fork now
    std::thread th;
    int forks = 0;
    std::vector<int> counts = std::vector<int>(32, 0);
    std::vector<int> signals = std::vector<int>(64, 0);
    int window = 0, stall = 0, launched = 0;
    uint64_t max_prep_ns = 0;
    std::function<void()> child;        // what the child does (it must _exit or exit)
    unsigned min_us = 200, max_us = 3000;
    bool classify = false;
    bool on_signal = false;
    std::atomic<bool> det_forked{false};   // trace build: the fork has returned in the parent

    void run(uint64_t seed) {
        th = std::thread([this, seed] {
#if ECO_TLA_TRACE_ENABLED
            tl_host = true;
            Elm::tlatrace::nameThread("host", -1);
#endif
            std::mt19937_64 rng(seed);
            while (!stop.load()) {
                if (on_signal) {
                    while (!go.load() && !stop.load()) std::this_thread::yield();
                    if (stop.load()) break;
                    go.store(false);
                } else {
                    usleep(static_cast<useconds_t>(min_us + rng() % (max_us - min_us + 1)));
                }
                std::fflush(stdout);
                std::fflush(stderr);
                const pid_t pid = fork();
                if (pid < 0) die("fork");
                if (pid == 0) {
                    child();
                    _exit(kClean);
                }
                ++forks;
                if (classify) {
                    // The harness's prepare hooks run first and last: a launch between
                    // them happened inside prepare. A gang running after the gang's
                    // own prepare was launched after stopAllForFork stopped it (the
                    // CR-004 window); a join inside prepare that waited more than 5 ms
                    // waited out an episode it did not stop (CR-023; a stop is
                    // honoured within one item, microseconds here).
                    const uint64_t prep = g_t1.load() - g_t0.load();
                    const bool launch = g_l1.load() > g_l0.load();
                    if (prep > max_prep_ns) max_prep_ns = prep;
                    if (launch) ++launched;
                    if (g_r1.load()) ++window;
                    else if (g_lstop.load() != ~0ull ? g_l1.load() > g_lstop.load()   // exact (trace build)
                                                     : launch && g_w1.load() - g_w0.load() > 5'000'000) ++stall;
                }
#if ECO_TLA_TRACE_ENABLED
                det_forked.store(true);
#endif
                const int st = waitChild(pid, 5000);
                if (st == -2) ++counts[31];
                else if (st >= 0 && WIFEXITED(st)) ++counts[WEXITSTATUS(st) & 31];
                else {
                    ++counts[30];
                    if (st >= 0 && WIFSIGNALED(st)) ++signals[WTERMSIG(st) & 63];
                }
            }
        });
    }
    void finish() { stop.store(true); th.join(); }
};

void printCounts(const char* arm, const Host& ho) {
    std::printf("RESULT arm=%s forks=%d clean=%d hang_tm=%d hang_drain=%d hang_heap=%d hang_atexit=%d "
                "hang_dtor=%d killed=%d abort_or_signal=%d other=%d\n",
                arm, ho.forks, ho.counts[kClean], ho.counts[kHangTm], ho.counts[kHangDrain],
                ho.counts[kHangHeap], ho.counts[kHangAtexit], ho.counts[kHangDtor], ho.counts[31],
                ho.counts[30], ho.forks - ho.counts[kClean] - ho.counts[kHangTm] - ho.counts[kHangDrain] -
                ho.counts[kHangHeap] - ho.counts[kHangAtexit] - ho.counts[kHangDtor] - ho.counts[31] -
                ho.counts[30]);
    for (int s = 0; s < 64; ++s)
        if (ho.signals[s] != 0) std::printf("  children killed by signal %d (%s): %d\n", s, strsignal(s), ho.signals[s]);
}

// ---------------------------------------------------------------------------
// Trials (each runs in its own process).
// ---------------------------------------------------------------------------
int trialMut(uint64_t seed) {
    std::atexit(&markAtexitDone);
    Opts o;
    Allocator& a = initHeap(o);
    Heap hp(a, seed, o);
    std::mt19937_64 rng(seed * 7 + 1);
    int forks = 0, ok = 0;
    std::vector<int> bad(32, 0);
    for (int s = 0; s < 400; ++s) {
        hp.churn(o.alloc_per_step, 20);
        if (rng() % 25 == 0) {
            std::fflush(stdout);
            std::fflush(stderr);
            const pid_t pid = fork();                 // between pauses, on the mutator
            if (pid < 0) die("fork");
            if (pid == 0) {
                signal(SIGALRM, onAlarm);
                armAlarm(3, 30);
                for (int k = 0; k < 30; ++k) { hp.churn(o.alloc_per_step, 10); a.minorGC(); }
                hp.finishCycle();
                if (!hp.verify()) _exit(4);
                armAlarm(4, 10);
                std::exit(kClean);                    // full teardown: atexit, ~Allocator
            }
            ++forks;
            const int st = waitChild(pid, 60000);
            if (st >= 0 && WIFEXITED(st) && WEXITSTATUS(st) == kClean) ++ok;
            else ++bad[st < 0 ? 31 : (WIFEXITED(st) ? WEXITSTATUS(st) & 31 : 30)];
        }
        a.minorGC();
    }
    hp.finishCycle();
    const bool parent_ok = hp.verify();
    std::printf("RESULT arm=mut forks=%d ok=%d bad=%d parent=%s\n", forks, ok, forks - ok,
                parent_ok ? "ok" : "BAD");
    for (int c = 0; c < 32; ++c)
        if (bad[c] != 0) std::printf("  child code %d: %d\n", c, bad[c]);
    return (ok == forks && parent_ok) ? 0 : 1;
}

int trialHost(uint64_t seed, bool full_exit) {
    std::atexit(&markAtexitDone);
    Opts o;
    Allocator& a = initHeap(o);
    Heap hp(a, seed, o);
    Host ho;
    ho.child = [&a, full_exit] {
        signal(SIGALRM, onAlarm);
        if (full_exit) {
            armAlarm(4, 3);
            std::exit(kClean);
        }
        probeAllocator(a);
    };
    ho.run(seed * 13 + 5);
    for (int s = 0; s < 300; ++s) { hp.churn(o.alloc_per_step, 15); a.minorGC(); }
    ho.finish();
    hp.finishCycle();
    printCounts(full_exit ? "host-exit" : "host", ho);
    return hp.verify() ? 0 : 1;
}

int trialTwoHeap(uint64_t seed) {
    std::atexit(&markAtexitDone);
    Opts o;
    o.old_pairs = 8000;
    Allocator& a = initHeap(o);           // mutator A's heap (this thread)
    std::atomic<bool> stop_b{false};
    std::atomic<bool> b_ready{false};
    std::thread b([&] {                   // mutator B: its own heap, its own pauses
        a.initThread();
        {
            Heap hb(a, seed + 99, o);
            b_ready.store(true);
            while (!stop_b.load()) { hb.churn(o.alloc_per_step, 12); a.minorGC(); }
            hb.finishCycle();
        }
        a.cleanupThread();
    });
    while (!b_ready.load()) std::this_thread::yield();
    Heap ha(a, seed, o);
    std::mt19937_64 rng(seed * 3 + 11);
    int forks = 0;
    std::vector<int> counts(32, 0);
    for (int s = 0; s < 250; ++s) {
        ha.churn(o.alloc_per_step, 15);
        if (rng() % 10 == 0) {
            std::fflush(stdout);
            std::fflush(stderr);
            const pid_t pid = fork();     // A forks between its own pauses; B runs
            if (pid < 0) die("fork");
            if (pid == 0) {
                signal(SIGALRM, onAlarm);
                probeAllocator(a);
                armAlarm(3, 5);
                for (int k = 0; k < 10; ++k) { ha.churn(o.alloc_per_step, 0); a.minorGC(); }
                ha.finishCycle();
                if (!ha.verify()) _exit(4);
                armAlarm(4, 5);
                std::exit(kClean);
            }
            ++forks;
            const int st = waitChild(pid, 20000);
            ++counts[st == -2 ? 31 : (st >= 0 && WIFEXITED(st) ? WEXITSTATUS(st) & 31 : 30)];
        }
        a.minorGC();
    }
    stop_b.store(true);
    b.join();
    ha.finishCycle();
    std::printf("RESULT arm=two-heap forks=%d clean=%d hang_tm=%d hang_drain=%d hang_heap=%d "
                "hang_atexit=%d hang_dtor=%d killed=%d abort_or_signal=%d\n",
                forks, counts[kClean], counts[kHangTm], counts[kHangDrain], counts[kHangHeap],
                counts[kHangAtexit], counts[kHangDtor], counts[31], counts[30]);
    return ha.verify() ? 0 : 1;
}

int trialRelaunch(uint64_t seed) {
    pthread_atfork(&prepLast, nullptr, nullptr);   // before every GC hook: runs last
    Opts o;
    o.big_arrays = 6;
    Allocator& a = initHeap(o);
    Heap hp(a, seed, o);
    // Build the gang (the first launch), then register the prepare-first hook.
    while (!OA::hasBgGang(hp.og())) { hp.churn(o.alloc_per_step, 1); a.minorGC(); }
    g_gang = OA::bgGang(hp.og());
    pthread_atfork(&prepFirst, nullptr, nullptr);
#if ECO_TLA_TRACE_ENABLED
    // Exact CR-023: a launch after this fork's stop was stored, the gang not running at
    // the end of prepare (the stop's join waited out the relaunched episode).
    Elm::tlatrace::setProbe([](const char* where) {
        if (tl_host && std::strcmp(where, "m6.stopset") == 0) g_lstop.store(g_gang->stats().launches.load());
    });
    Elm::tlatrace::begin("{\"harness\":\"gc-fork-trace\",\"kind\":\"relaunch\"}", "m6.nothing.");
    gc::tla_m6 = true;
#endif
    Host ho;
    ho.classify = true;
    ho.min_us = 100;
    ho.max_us = 1500;
    ho.child = [] {};
    ho.run(seed * 17 + 3);
    for (int s = 0; s < 400; ++s) { hp.churn(60, 6); a.minorGC(); }
    ho.finish();
    hp.finishCycle();
    std::printf("RESULT arm=relaunch forks=%d launch_in_prepare=%d cr004_window=%d cr023_stall=%d "
                "max_prepare_ms=%.1f\n", ho.forks, ho.launched, ho.window, ho.stall,
                ho.max_prep_ns / 1e6);
    return hp.verify() ? 0 : 1;
}

int trialClosing(uint64_t seed, bool early) {
    Opts o;
    o.old_pairs = early ? 20000 : 60000;
    o.big_arrays = early ? 6 : 0;
    o.slices = 4;
    Allocator& a = initHeap(o);
    Heap hp(a, seed, o);
    Host ho;
    ho.child = [] {};
    ho.on_signal = early;
    ho.min_us = 500;
    ho.max_us = 4000;
    ho.run(seed * 19 + 7);
    int cycles = 0;
    for (int s = 0; s < 400 && cycles < 12; ++s) {
        const bool was = hp.cycleActive();
        hp.churn(o.alloc_per_step, 1);
        if (!early && hp.cycleActive()) hp.og().test_bg_hold_.store(true);   // the closing does the marking
        if (early && hp.cycleActive() && OA::cycleK(hp.og()) + 1 == o.slices) ho.go.store(true);
        a.minorGC();
        if (!early && hp.cycleActive()) hp.og().test_bg_hold_.store(true);
        if (was && !hp.cycleActive()) ++cycles;
    }
    ho.finish();
    std::printf("RESULT arm=%s forks=%d cycles=%d parent=survived\n", early ? "closing-early" : "closing",
                ho.forks, cycles);
    return 0;
}


#if ECO_TLA_TRACE_ENABLED
// ===========================================================================
// Trace build (gc-fork-trace) only.
//
// (1) Deterministic guards. The runtime's M6 probe hooks are pause points at
// the windows M6 found; the harness holds a thread there while another acts:
//   det-cr015  the mutator is paused inside post() just after its CAS (it
//              holds thread_mutex_): the host forks. The child finds
//              thread_mutex_ held by a thread it does not have (CR-015; the
//              job is also stranded in its CAS window, CR-003).
//   det-cr003  the host is paused in the pool's prepare between drain() and
//              m_.lock(): the mutator completes a post and leaves
//              thread_mutex_. The child's drain waits for a job no thread
//              will run (CR-003, the register's drain-then-post window).
//   det-cr005  the mutator is paused in closingFinish with the episode still
//              running: the host forks and the stop is stored. The parent
//              aborts in assert(bg_ep_ == Finished) (CR-005).
//   det-cr004  the host is paused after stopAllForFork, before the gang's m_
//              lock: the mutator relaunches the episode and the member marks.
//              The fork then copies a running episode whose member does not
//              exist in the child (the CR-004 window; harmless: that child
//              has no mutator for the heap).
// (2) The gang trace scenario for test/tla/M6-lifecycle/TraceGangs.tla:
//   gc-fork-trace gangs <none|host|mut-parent|mut-child> <seed> <T> <mark threads> <bg_first|mark_first> <hold>
//   (hold 1: the background members wait until the closing, so the closing join marks)
// ===========================================================================
enum DetArm : int { kDetNone = 0, kDetCr015 = 1, kDetCr003 = 2, kDetCr005 = 3, kDetCr004 = 4 };
std::atomic<int> g_det{kDetNone};
std::atomic<bool> g_det_fired{false};       // a pause point is used once per trial
std::atomic<bool> g_det_mut_go{false};      // host -> mutator: act now
std::atomic<bool> g_det_mut_done{false};    // mutator -> host: done
std::atomic<bool> g_det_armed_post{false};  // det-cr003: the next post counts
std::atomic<bool> g_det_posted{false};
std::atomic<bool> g_det_stopset{false};
Host* g_host = nullptr;

void spinUntil(const std::atomic<bool>& f) {
    while (!f.load()) std::this_thread::yield();
}

void onProbe(const char* where) {
    const int d = g_det.load();
    if (d == kDetCr015 && !tl_host && std::strcmp(where, "m6.post.cas") == 0 && !g_det_fired.exchange(true)) {
        g_host->go.store(true);                 // fork while this post holds thread_mutex_
        spinUntil(g_host->det_forked);
    } else if (d == kDetCr003 && tl_host && std::strcmp(where, "m6.pool.drained") == 0 &&
               !g_det_fired.exchange(true)) {
        g_det_mut_go.store(true);               // let the mutator post, between drain and lock
        spinUntil(g_det_mut_done);
    } else if (d == kDetCr003 && !tl_host && std::strcmp(where, "m6.post.cas") == 0 && g_det_armed_post.load()) {
        g_det_posted.store(true);
    } else if (d == kDetCr005 && !tl_host && std::strcmp(where, "m6.closing") == 0 &&
               !g_det_fired.exchange(true)) {
        g_host->go.store(true);                 // fork while the closing join is about to run
        spinUntil(g_det_stopset);
    } else if (d == kDetCr005 && tl_host && std::strcmp(where, "m6.stopset") == 0) {
        g_det_stopset.store(true);
    } else if (d == kDetCr004 && tl_host && std::strcmp(where, "m6.bg.stopped") == 0 &&
               !g_det_fired.exchange(true)) {
        g_det_mut_go.store(true);               // let the mutator relaunch before the m_ lock
        spinUntil(g_det_mut_done);
    }
}

// Grows the old gen (so that PageWork posts commit-ahead jobs) without a cycle.
void growStep(Heap& hp) {
    for (int i = 0; i < 200; ++i) {
        Root x(hp.a, alloc::allocInt(i));
        hp.keep.push_back(std::make_unique<Root>(hp.a, alloc::tuple2(alloc::boxed(x.h), alloc::boxed(x.h), 0)));
        hp.want.push_back(-3);
    }
}

int trialDet(int which, uint64_t seed) {
    if (which == kDetCr003) setenv("ECO_GC_HELPER_JITTER_US", "20000", 1);   // keep the posted job in flight
    Opts o;
    o.old_pairs = 4000;
    o.slices = 6;
    Allocator& a = initHeap(o);
    Heap hp(a, seed, o);
    Elm::tlatrace::setProbe(&onProbe);
    Elm::tlatrace::begin("{\"harness\":\"gc-fork-trace\",\"kind\":\"det\"}", "m6.nothing.");   // probes only
    gc::tla_m6 = true;                                   // M6's probes fire only while set
    Host ho;
    g_host = &ho;
    ho.on_signal = true;
    ho.child = [&a, which] {
        signal(SIGALRM, onAlarm);
        if (which == kDetCr015 || which == kDetCr003) probeAllocator(a);
    };
    ho.run(seed * 23 + 1);
    g_det.store(which);
    int steps = 0;
    const char* what = "none";
    if (which == kDetCr015) {
        // The next PageWork post (a commit-ahead populate) pauses and the host forks.
        while (!g_det_fired.load() && steps < 3000) { growStep(hp); a.minorGC(); ++steps; }
        what = g_det_fired.load() ? "fork-inside-post" : "no-post";
    } else if (which == kDetCr003) {
        ho.go.store(true);                                   // the host forks; it pauses after drain()
        while (!g_det_mut_go.load()) { hp.churn(50, 0); a.minorGC(); ++steps; }
        g_det_armed_post.store(true);
        while (!g_det_posted.load() && steps < 3000) { growStep(hp); a.minorGC(); ++steps; }
        g_det_mut_done.store(true);                          // the post is complete, thread_mutex_ free
        what = g_det_posted.load() ? "post-between-drain-and-lock" : "no-post";
    } else if (which == kDetCr005) {
        hp.h->test_force_major_trigger_ = true;
        for (; steps < 200; ++steps) {
            hp.churn(100, 0);
            if (hp.cycleActive()) hp.og().test_bg_hold_.store(true);   // the episode still runs at the closing
            a.minorGC();
            if (steps > 0 && !hp.cycleActive()) break;
        }
        what = "closing-without-abort";                      // reached only if the assert did not fire
    } else if (which == kDetCr004) {
        hp.h->test_force_major_trigger_ = true;
        hp.churn(100, 0);
        a.minorGC();                                         // t0: the episode is launched
        hp.og().test_bg_hold_.store(true);
        ho.go.store(true);                                   // the host forks; it pauses after the stops
        spinUntil(g_det_mut_go);
        gc::GCBackgroundGang* g = OA::bgGang(hp.og());
        const uint64_t l0 = g->stats().launches.load();
        while (g->stats().launches.load() == l0 && hp.cycleActive() && steps < 100) {
            hp.churn(100, 0);
            a.minorGC();                                     // reap (None) and relaunch
            ++steps;
        }
        const bool relaunched = g->stats().launches.load() > l0 && g->running();
        hp.og().test_bg_hold_.store(false);                  // the relaunched member marks
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
        g_det_mut_done.store(true);                          // the host locks m_ and forks
        spinUntil(ho.det_forked);
        ho.window = relaunched ? 1 : 0;
        what = relaunched ? "relaunch-between-stop-and-lock" : "no-relaunch";
    }
    ho.finish();
    g_det.store(kDetNone);
    gc::tla_m6 = false;
    Elm::tlatrace::end("/dev/null");
    hp.finishCycle();
    std::printf("RESULT arm=det what=%s steps=%d forks=%d clean=%d hang_tm=%d hang_drain=%d cr004_window=%d\n",
                what, steps, ho.forks, ho.counts[kClean], ho.counts[kHangTm], ho.counts[kHangDrain], ho.window);
    return 0;
}

// ---------------------------------------------------------------------------
// The gang trace scenario (TraceGangs.tla): one recorded 5c cycle of the real
// allocator, with at most one fork, between two handoffs.
// ---------------------------------------------------------------------------
int gangsTrace(int argc, char** argv) {
    if (argc != 7) {
        std::fprintf(stderr, "usage: gangs <none|host|mut-parent|mut-child> <seed> <T> <mark threads> "
                             "<bg_first|mark_first> <hold 0|1>\n");
        return 2;
    }
    const std::string mode = argv[1];
    const uint64_t seed = std::strtoull(argv[2], nullptr, 10);
    const unsigned T = static_cast<unsigned>(std::atoi(argv[3]));
    const unsigned mt = static_cast<unsigned>(std::atoi(argv[4]));
    const std::string order = argv[5];
    const bool hold = std::atoi(argv[6]) != 0;
    if ((mode != "none" && mode != "host" && mode != "mut-parent" && mode != "mut-child") || T < 3 ||
        (mt != 1 && mt != 2) || (order != "bg_first" && order != "mark_first")) {
        std::fprintf(stderr, "gangs: bad arguments\n");
        return 2;
    }
    Opts o;
    o.slices = T;
    o.mark_threads = mt;
    o.old_pairs = 3000;
    o.pool = false;                                          // M6b: the gangs only
    // Registration order decides the prepare order: prepare runs in reverse.
    if (order == "bg_first") gc::GCMarkGang::instance().configure(mt, 0);   // before the gang
    Allocator& a = initHeap(o);
    Heap hp(a, seed, o);
    Elm::tlatrace::nameThread("mut", -1);
    // One unrecorded cycle builds the background gang (and registers it).
    hp.h->test_force_major_trigger_ = true;
    do { hp.churn(100, 0); a.minorGC(); } while (hp.cycleActive());
    if (order == "mark_first") gc::GCMarkGang::instance().configure(mt, 0);   // after the gang
    gc::GCBackgroundGang* g = OA::bgGang(hp.og());
    if (g == nullptr) die("no background gang");
    std::mt19937_64 rng(seed);
    const int fork_step = 1 + static_cast<int>(rng() % std::max(1u, std::min(3u, T - 2)));
    char hdr[512];
    std::snprintf(hdr, sizeof hdr,
                  "{\"harness\":\"gc-fork-trace\",\"kind\":\"gangs\",\"mode\":\"%s\",\"seed\":%llu,\"T\":%u,"
                  "\"mark_threads\":%u,\"order\":\"%s\",\"forker\":\"%s\",\"side\":\"%s\",\"bgkey\":\"B%lld\","
                  "\"fgkey\":\"F%lld\",\"fork_step\":%d,\"hold\":%s}",
                  mode.c_str(), static_cast<unsigned long long>(seed), T, mt, order.c_str(),
                  mode == "host" ? "host" : (mode == "none" ? "none" : "mut"),
                  mode == "mut-child" ? "child" : "parent",
                  static_cast<long long>(reinterpret_cast<uintptr_t>(g)),
                  static_cast<long long>(reinterpret_cast<uintptr_t>(&gc::GCMarkGang::instance())), fork_step,
                  hold ? "true" : "false");
    Host ho;
    ho.on_signal = true;
    ho.child = [] {};
    if (mode == "host") ho.run(seed * 29 + 3);
    Elm::tlatrace::begin(hdr, "minor,t0,t0end,launch,reap,relaunch,step,closing,handoff,stop,gang.,fork.");
    gc::tla_m6 = true;
    hp.h->test_force_major_trigger_ = true;
    bool in_child = false;
    pid_t child = -1;
    for (int k = 0; k < 400; ++k) {
        hp.churn(100, 0);
        if (hold && hp.cycleActive()) hp.og().test_bg_hold_.store(true);   // released by the closing
        if (k == fork_step && mode == "host") ho.go.store(true);   // the host forks; the next pauses race it
        // A stop still pending at the closing aborts the parent in closingFinish (CR-005; the
        // det-cr005 arm): a trace cannot contain it, so the closing minor waits for the fork.
        if (mode == "host" && k >= static_cast<int>(T) && k >= fork_step && !ho.det_forked.load()) {
            // The fork's stop may be waiting out a relaunched episode (CR-023), whose member
            // the test hold would keep from ending: release it first.
            hp.og().test_bg_hold_.store(false);
            spinUntil(ho.det_forked);
        }
        if (k == fork_step && (mode == "mut-parent" || mode == "mut-child")) {
            std::fflush(stdout);
            const pid_t pid = fork();                        // between pauses, on the mutator
            if (pid < 0) die("fork");
            if (pid == 0) {
                if (mode == "mut-parent") _exit(0);
                in_child = true;
            } else {
                child = pid;
                if (mode == "mut-child") {                   // the child writes the log
                    int st = 0;
                    waitpid(pid, &st, 0);
                    std::printf("gangs trace %s PASS (child: %d)\n", mode.c_str(), st);
                    _exit(WIFEXITED(st) && WEXITSTATUS(st) == 0 ? 0 : 1);
                }
            }
        }
        a.minorGC();
        if (k > 0 && !hp.cycleActive()) break;               // the handoff
    }
    if (mode == "host") ho.finish();
    if (child > 0 && !in_child) {
        int st = 0;
        waitpid(child, &st, 0);
    }
    gc::tla_m6 = false;
    if (!Elm::tlatrace::end(nullptr)) die("writing the trace");
    std::printf("gangs trace %s PASS%s\n", mode.c_str(), in_child ? " (child log)" : "");
    std::fflush(stdout);
    if (in_child) _exit(0);
    return 0;
}
#endif

// ---------------------------------------------------------------------------
// The driver: one process per trial, a hard deadline each.
// ---------------------------------------------------------------------------
struct TrialOut {
    int status = 0;
    bool timed_out = false;
    std::string out;
};

TrialOut runTrial(const std::function<int()>& body, int deadline_s) {
    int fd[2];
    if (pipe(fd) != 0) die("pipe");
    std::fflush(stdout);
    std::fflush(stderr);
    const pid_t pid = fork();
    if (pid < 0) die("fork trial");
    if (pid == 0) {
        setpgid(0, 0);                          // the trial and its children: one group
        dup2(fd[1], 1);
        dup2(fd[1], 2);
        close(fd[0]);
        close(fd[1]);
        const int rc = body();
        std::fflush(stdout);
        std::fflush(stderr);
        _exit(rc);
    }
    close(fd[1]);
    TrialOut r;
    const uint64_t t_end = nowNs() + static_cast<uint64_t>(deadline_s) * 1'000'000'000ull;
    char buf[4096];
    for (;;) {
        pollfd p{fd[0], POLLIN, 0};
        const int n = poll(&p, 1, 200);
        if (n > 0) {
            const ssize_t k = read(fd[0], buf, sizeof buf);
            if (k <= 0) break;
            r.out.append(buf, static_cast<size_t>(k));
        }
        if (nowNs() > t_end) { r.timed_out = true; break; }
    }
    if (r.timed_out) kill(-pid, SIGKILL);
    waitpid(pid, &r.status, 0);
    if (r.timed_out) kill(-pid, SIGKILL);       // grandchildren still holding the pipe
    close(fd[0]);
    return r;
}

bool hasLine(const std::string& s, const char* what) { return s.find(what) != std::string::npos; }

int driver(const std::string& arm, int trials, uint64_t seed) {
    std::function<int(uint64_t)> body;
    int deadline = 240;
    if (arm == "mut") body = [](uint64_t s) { return trialMut(s); };
    else if (arm == "host") body = [](uint64_t s) { return trialHost(s, false); };
    else if (arm == "host-exit") body = [](uint64_t s) { return trialHost(s, true); };
    else if (arm == "two-heap") body = [](uint64_t s) { return trialTwoHeap(s); };
    else if (arm == "relaunch") body = [](uint64_t s) { return trialRelaunch(s); };
    else if (arm == "closing") body = [](uint64_t s) { return trialClosing(s, false); };
    else if (arm == "closing-early") body = [](uint64_t s) { return trialClosing(s, true); };
#if ECO_TLA_TRACE_ENABLED
    else if (arm == "det-cr015") body = [](uint64_t s) { return trialDet(kDetCr015, s); };
    else if (arm == "det-cr003") body = [](uint64_t s) { return trialDet(kDetCr003, s); };
    else if (arm == "det-cr005") body = [](uint64_t s) { return trialDet(kDetCr005, s); };
    else if (arm == "det-cr004") body = [](uint64_t s) { return trialDet(kDetCr004, s); };
#endif
    else return 2;
    int aborted_cr005 = 0, other_fail = 0, timeouts = 0;
    long tot[16] = {0};
    const char* keys[] = {"forks=", "clean=", "hang_tm=", "hang_drain=", "hang_heap=", "hang_atexit=",
                          "hang_dtor=", "killed=", "abort_or_signal=", "launch_in_prepare=", "cr004_window=",
                          "cr023_stall=", "ok=", "bad="};
    const int nkeys = sizeof keys / sizeof keys[0];
    for (int t = 0; t < trials; ++t) {
        const uint64_t s = seed + static_cast<uint64_t>(t);
        const TrialOut r = runTrial([&body, s] { return body(s); }, deadline);
        const bool cr005 = WIFSIGNALED(r.status) && WTERMSIG(r.status) == SIGABRT &&
                           hasLine(r.out, "bg_ep_ == BgEpisode::Finished");
        std::string line;
        const size_t at = r.out.find("RESULT ");
        if (at != std::string::npos) line = r.out.substr(at, r.out.find('\n', at) - at);
        std::printf("trial %d seed %llu: %s%s%s\n", t, static_cast<unsigned long long>(s),
                    r.timed_out ? "TIMEOUT " : "",
                    cr005 ? "ABORT closingFinish assert(bg_ep_ == Finished) (CR-005) "
                          : (WIFSIGNALED(r.status) ? "SIGNAL " : ""),
                    line.c_str());
        if (g_backtrace) std::printf("  --- trial output ---\n%s\n", r.out.c_str());
        if (r.timed_out) ++timeouts;
        else if (cr005) ++aborted_cr005;
        else if (!WIFEXITED(r.status) || WEXITSTATUS(r.status) != 0) {
            ++other_fail;
            std::printf("  --- trial output (tail) ---\n%s\n", r.out.substr(r.out.size() > 2000 ? r.out.size() - 2000 : 0).c_str());
        }
        for (int k = 0; k < nkeys; ++k) {
            const size_t p = line.find(keys[k]);
            if (p != std::string::npos) tot[k] += std::atol(line.c_str() + p + std::strlen(keys[k]));
        }
    }
    std::printf("SUMMARY arm=%s trials=%d timeouts=%d cr005_aborts=%d other_failures=%d", arm.c_str(), trials,
                timeouts, aborted_cr005, other_fail);
    for (int k = 0; k < nkeys; ++k)
        if (tot[k] != 0) std::printf(" %s%ld", keys[k], tot[k]);
    std::printf("\n");
    // Guards: exit 1 when the arm reproduced its register entry (or failed).
    if (arm == "mut") return (timeouts == 0 && other_fail == 0 && aborted_cr005 == 0) ? 0 : 1;
    if (arm == "closing" || arm == "closing-early" || arm == "det-cr005") return aborted_cr005 > 0 ? 1 : 0;
    if (arm == "det-cr004") return tot[10] > 0 ? 1 : 0;
    if (arm == "relaunch") return (tot[10] + tot[11] > 0) ? 1 : 0;
    // host, host-exit, two-heap: any child that hung or died.
    const long bad = tot[2] + tot[3] + tot[4] + tot[5] + tot[6] + tot[7] + tot[8];
    return (bad > 0 || timeouts > 0 || other_fail > 0) ? 1 : 0;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <mut|host|host-exit|two-heap|relaunch|closing|closing-early> "
                             "[trials [seed]]\n  trace build also: det-cr015|det-cr003|det-cr005|det-cr004 "
                             "[trials [seed]]; gangs <mode> <seed> <T> <mark threads> <order>\n", argv[0]);
        return 2;
    }
    // The validate build's P1 census keeps a process-wide mutex and tables with no
    // atfork handler: a host child can block on it or read a half-updated table
    // (AUDIT.md). It is off unless FORK_HARNESS_CENSUS=1, so that the arms measure
    // the GC's own fork protocols.
    if (std::getenv("FORK_HARNESS_CENSUS") == nullptr) setenv("ECO_P1_CENSUS", "0", 1);
#if ECO_TLA_TRACE_ENABLED
    if (std::strcmp(argv[1], "gangs") == 0) return gangsTrace(argc - 1, argv + 1);
#endif
    g_backtrace = std::getenv("FORK_HARNESS_BT") != nullptr;
    if (g_backtrace) {
        signal(SIGABRT, onAbort);
        signal(SIGSEGV, onAbort);
        signal(SIGBUS, onAbort);
    }
    const int trials = argc > 2 ? std::atoi(argv[2]) : 5;
    const uint64_t seed = argc > 3 ? std::strtoull(argv[3], nullptr, 10) : 1;
    const int rc = driver(argv[1], trials, seed);
    if (rc == 2) std::fprintf(stderr, "unknown arm %s\n", argv[1]);
    return rc;
}
