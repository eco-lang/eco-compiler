// threaded-gc-05c Step 8 (D9): the real allocator under TSan with background
// marking. A synthetic mutator keeps an old random graph plus a churning set
// of rooted young/large objects, forces a cycle every ~40 minors, and checks
// every rooted value after each handoff. Validators (IM1-IM16) are on.
//
// TLA+ trace build (-DECO_TLA_TRACE=ON, test/tla/README.md "Trace
// validation"): `gc-heap-trace cycle <name>` runs one of the traceScenarios
// below, shorter and with fork stops and explicit majors, and records M1's
// cycle events (plans/threaded-gc-tla-M1-snapshot-mark.md §8 (a));
// `gc-heap-trace tiny <seed>` runs tiny_graph.cpp (§8 (b)). With no arguments
// the trace build runs nothing. The TSan build and its scenarios are unchanged.
#include "Allocator.hpp"
#include "GCHelperPool.hpp"   // CR-006: the pool arm's counters
#include "HeapHelpers.hpp"
#include "OldGenSpace.hpp"
#include "PageWork.hpp"
#include "ThreadLocalHeap.hpp"
#include "TlaTrace.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <random>
#include <vector>
#if ECO_TLA_TRACE_ENABLED
#include <cstring>
#include <string>
#include <sys/wait.h>
#include <unistd.h>
#include "GCHelperPool.hpp"
int tinyGraphMain(int argc, char** argv);   // tiny_graph.cpp (M1 trace (b))
int promoTraceMain(int argc, char** argv);  // promo_sweep.cpp (M4 trace)
int tinyTenureMain(int argc, char** argv);  // tiny_tenure.cpp (M5 trace (b))
#endif

using namespace Elm;

namespace {
[[noreturn]] void fail(const char* w) {
    std::fprintf(stderr, "heap_driver FAIL: %s\n", w);
    std::exit(1);
}
struct Root {
    Allocator& a;
    HPointer h;
    Root(Allocator& al, HPointer v) : a(al), h(v) { a.getRootSet().addRoot(&h); }
    ~Root() { a.getRootSet().removeRoot(&h); }
};
i64 intOf(Allocator& a, HPointer hp) {
    void* o = a.resolve(hp);
    if (!o || getHeader(o)->tag != Tag_Int) fail("expected an Int");
    return static_cast<ElmInt*>(o)->value;
}

// threaded-gc-06 Step 8: `minor` > 1 runs every minor on that many parallel
// workers (a 1 MiB nursery side leaves room for their LABs), overlapping the
// background markers' episodes.
// threaded-gc-07 Step 10: `regions` runs the region nursery in tenure mode 2
// with `collectors` tenure collector threads (1 = the exact engine; > 1 = L3).
// Knobs: the defaults are the TSan scenarios' values; the fork, major and
// trace knobs act only in a TLA+ trace build.
struct Knobs {
    int steps = 900;
    int cycle_every = 40;               // force a cycle at step % cycle_every == 0 when idle
    int old_pairs = 60000;
    int fork_every = 0, fork_at = 0;    // fork (the child _exits) while a cycle runs
    int major_every = 0, major_at = 0;  // an explicit STW major while a cycle runs
    double finish_fraction = 0;         // incremental_mark_finish_fraction; 0 = the default
    float global_fraction = 0;          // major_gc_global_pressure_fraction; 0 = the default
    size_t max_heap_mb = 0;             // max_heap_size; 0 = the default (512 MiB)
    const char* trace = nullptr;        // record this scenario's M1 cycle events
    // Register CR-006 (`pool` arm): gc_thread_mode 2, so the helper pool runs
    // deferred-decommit and commit-ahead jobs while background markers and
    // parallel minors run (a gang worker may wait on a posted discard: CR-007).
    bool pool = false;
    // Register CR-020 (`ylos` arm): every `ylos_every` steps a young large
    // object family (buildFamily below); 0 = none.
    int ylos_every = 0;
    // Register CR-037 / CR-017 (`lbaba` arm, plans/threaded-gc-register-repros-
    // impl.md Step 30). The defaults leave every other scenario unchanged.
    int cycle_at = 0;                              // force at step % cycle_every == cycle_at
    int idle_major_every = 0, idle_major_at = 0;   // an explicit STW major, cycle or not
    int lb_every = 0;                              // CR-037: a dying large string, 8+2L == 16+8*ylos_len
    int doom_every = 0;                            // CR-017: young x -> old doomed Tuple2; both die next period step
    size_t ylos_len = 0;                           // the families' fixed length (0 = random)
    int verify_every = 25;
};

// CR-020: a young large object family. A pointer-bearing Array above
// large_object_threshold (legacy: the nursery up to 12 KiB, else the YLOS;
// region mode: always the YLOS) -- a mixed bag page below alloc_buffer_size,
// one in eight a large block above it -- whose elements point at eight young
// Ints, at old Tuple2s (keep[] entries) and, at element 0, at the previous
// family's Array (a YLOS -> YLOS edge; the chain is cut every fourth family),
// under kFamilyParents young Tuple2 parents (Array, Int serial), each its own
// RootSet root: a parallel minor's worker 0 copies the roots and deals their
// grey entries round-robin to the gang (minorGCParallel step 4), so several
// workers scan a parent of one Array and reach it in the same minor (the
// parallel YLOS reach under ylos_mu_: reachYoungLargeP / reachYoungLargeR).
// (A tree of parents under one root stays on one worker: a private stack is
// published only from 64 entries up.)
constexpr int kFamilyParents = 8;
constexpr size_t kFamilyRing = 16;   // live families; each lives 16 x ylos_every steps
struct Family {
    std::vector<std::unique_ptr<Root>> parents;   // empty: no family in this slot
    int64_t serial = 0;
    size_t len = 0;
    bool chained = false;
};
i64 familyInt(int64_t serial, size_t i) { return serial * 16 + static_cast<i64>(i % 8); }
bool familyOld(size_t i) { return i % 3 == 0; }
size_t familyOldIndex(int64_t serial, size_t i, size_t n) {
    return (static_cast<size_t>(serial) * 7919 + i) % n;
}

// keep[0, tuples) are the old graph's Tuple2 roots (replaced by Tuple2s).
void buildFamily(Allocator& a, int64_t serial, size_t len, bool chained, HPointer prev_array,
                 const std::vector<std::unique_ptr<Root>>& keep, size_t tuples,
                 std::vector<std::unique_ptr<Root>>& parents) {
    Root prev(a, prev_array);   // a nursery Array moves in the minors below
    std::vector<std::unique_ptr<Root>> young;
    for (size_t j = 0; j < 8; ++j)
        young.push_back(std::make_unique<Root>(a, alloc::allocInt(familyInt(serial, j))));
    std::vector<HPointer> e(len);   // no allocation between the fill and the Array
    for (size_t i = 0; i < len; ++i) {
        if (i == 0 && chained) e[i] = prev.h;
        else if (familyOld(i)) e[i] = keep[familyOldIndex(serial, i, tuples)]->h;
        else e[i] = young[i % 8]->h;
    }
    Root arr(a, alloc::arrayFromPointers(e));
    parents.clear();
    for (int p = 0; p < kFamilyParents; ++p) {
        Root n(a, alloc::allocInt(serial));
        parents.push_back(std::make_unique<Root>(
            a, alloc::tuple2(alloc::boxed(arr.h), alloc::boxed(n.h), 0)));
    }
}

Tuple2* familyParent(Allocator& a, const Root& r) {
    void* o = a.resolve(r.h);
    if (!o || getHeader(o)->tag != Tag_Tuple2) fail("a family parent changed");
    return static_cast<Tuple2*>(o);
}

// A family's Array (its first parent's field a).
HPointer familyArray(Allocator& a, const Family& f) {
    return familyParent(a, *f.parents[0])->a.p;
}

void checkFamily(Allocator& a, const Family& f) {
    void* arr = nullptr;
    for (const auto& r : f.parents) {
        Tuple2* t = familyParent(a, *r);
        void* x = a.resolve(t->a.p);
        if (arr == nullptr) arr = x;
        if (x == nullptr || x != arr) fail("a family's parents disagree on its Array");
        if (intOf(a, t->b.p) != f.serial) fail("a family parent changed");
    }
    const ElmArray* A = static_cast<const ElmArray*>(arr);
    if (A->header.tag != Tag_Array || A->length != f.len) fail("a family Array changed");
    for (size_t i = 0; i < f.len; ++i) {
        void* o = a.resolve(A->elements[i].p);
        if (o == nullptr) fail("a family element vanished");
        const uint32_t tag = getHeader(o)->tag;
        if (i == 0 && f.chained) {
            if (tag != Tag_Array) fail("a family's previous Array changed");
        } else if (familyOld(i)) {
            if (tag != Tag_Tuple2) fail("a family's old element changed");
        } else if (intOf(a, A->elements[i].p) != familyInt(f.serial, i)) {
            fail("a family's young element changed");
        }
    }
}

#if ECO_TLA_TRACE_ENABLED
// A mutator fork: the atfork prepare handlers stop every running background
// episode (GCBackgroundGang::stopAllForFork); the child exits at once.
void forkNow() {
    const pid_t pid = fork();
    if (pid < 0) fail("fork");
    if (pid == 0) _exit(0);
    int st = 0;
    if (waitpid(pid, &st, 0) != pid || !WIFEXITED(st) || WEXITSTATUS(st) != 0) fail("fork child");
}
#endif

void scenario(unsigned bg, unsigned slices, uint64_t seed, unsigned minor = 1,
              bool regions = false, unsigned collectors = 1, unsigned age = 1,
              const Knobs& kn = Knobs{}) {
    HeapConfig cfg;
    cfg.alloc_buffer_size = 32 * 1024;
    cfg.nursery_block_count = minor > 1 ? 64 : 8;
    cfg.nursery_max_block_count = minor > 1 ? 64 : 8;
    cfg.gc_minor_threads = minor;
    cfg.minor_lab_bytes = 4096;
    cfg.minor_parallel_min_bytes = 0;
    cfg.initial_old_gen_size = 256 * 1024;
    cfg.max_heap_size = 512ULL << 20;
    cfg.large_object_threshold = 8 * 1024;
    cfg.decommit_on_oldgen_release = false;
    cfg.gc_thread_mode = 0;
    cfg.incremental_mark = true;
    cfg.incremental_mark_slices = slices;
    cfg.incremental_mark_min_slice_units = 64;
    cfg.gc_mark_threads = 2;
    cfg.conc_mark = 2;
    cfg.conc_mark_threads = bg;
    cfg.conc_mark_priority = 0;
    cfg.conc_mark_assist_lag = 1;
    cfg.nursery_regions = 0;   // TG7d: the default is auto; legacy scenarios pin it off
    if (regions) {
        cfg.nursery_regions = 1;
        cfg.tenure_mode = 2;
        cfg.tenure_collector_threads = collectors;
        cfg.tenure_help_threads = 0;
        cfg.promotion_age = age;   // threaded-gc-07b: the tenure age k
    }
    if (kn.finish_fraction > 0) cfg.incremental_mark_finish_fraction = kn.finish_fraction;
    if (kn.global_fraction > 0) cfg.major_gc_global_pressure_fraction = kn.global_fraction;
    if (kn.max_heap_mb > 0) cfg.max_heap_size = kn.max_heap_mb << 20;
    if (kn.pool) {
        // CR-006: two pool workers; a released extent is discarded (a posted
        // Discard job) at the next pause end, so a reuse soon after -- a
        // promotion worker's virgin block under promo_mu_ included (CR-007)
        // -- can meet a posted job; a 1 MiB commit-ahead window posts a
        // Populate job each time the bump crosses a 2 MiB granule.
        cfg.gc_thread_mode = 2;
        cfg.gc_helper_threads = 2;
        cfg.decommit_on_oldgen_release = true;
        cfg.decommit_delay_syncs = 0;
        cfg.decommit_delay_majors = 1;
        cfg.commit_ahead_bytes = 1 << 20;
    }
    // CR-020: legacy mode places a pointer-bearing large object up to 12 KiB
    // in the nursery and a larger one in the YLOS (region mode: every one
    // above the largest size class, 8 KiB, is a YLOS).
    if (kn.ylos_every > 0 && !regions) cfg.large_ptr_nursery_max_size = 12 * 1024;
    cfg.validate();
    auto& a = Allocator::instance();
    a.initialize(cfg);
    AllocatorTestAccess::reset(a, &cfg);
    a.initThread();
    ThreadLocalHeap* h = AllocatorTestAccess::getThreadHeap(a);
    std::mt19937_64 rng(seed);
    // Old graph: a list of (Int, Int) pairs.
    std::vector<std::unique_ptr<Root>> keep;
    std::vector<i64> want;
    for (int i = 0; i < kn.old_pairs; ++i) {
        Root x(a, alloc::allocInt(i));
        Root y(a, alloc::allocInt(-i));
        HPointer t = alloc::tuple2(alloc::boxed(x.h), alloc::boxed(y.h), 0);
        if (i % 16 == 0) { keep.push_back(std::make_unique<Root>(a, t)); want.push_back(i); }
    }
    const size_t tuples = keep.size();   // CR-020: the old Tuple2 roots a family points at
    std::vector<Family> fams(kFamilyRing);
    std::mt19937_64 frng(seed * 7919 + 1);   // families only: the base churn is unchanged
    int64_t serial = 0;
    uint64_t fam_ylos = 0, fam_large = 0;
    // CR-017 (lbaba): old Tuple2s, each in turn the target of one young x
    // (x_slot) and dropped together with it one step later.
    std::vector<std::unique_ptr<Root>> doomed;
    if (kn.doom_every > 0)
        for (int i = 0; i < 4096; ++i)
            doomed.push_back(std::make_unique<Root>(
                a, alloc::tuple2(alloc::unboxedInt(i), alloc::unboxedInt(-i), 0x3)));
    std::unique_ptr<Root> lb_slot, x_slot;   // CR-037's dying string, CR-017's young x
    size_t doom_next = 0;
#if ECO_TLA_TRACE_ENABLED
    if (kn.trace != nullptr) {
        // Start between collections: no cycle may be half recorded.
        while (OldGenSpaceTestAccess::cycleActive(h->getOldGen())) a.minorGC();
        char hdr[256];
        std::snprintf(hdr, sizeof hdr,
                      "{\"harness\":\"gc-heap-trace\",\"kind\":\"cycle\",\"scenario\":\"%s\","
                      "\"T\":%u,\"bg\":%u,\"minor\":%u,\"regions\":%s}",
                      kn.trace, slices, bg, minor, regions ? "true" : "false");
        tlatrace::begin(hdr, "minor,major,t0,t0end,launch,relaunch,step,reap,stop,pressure,join,"
                             "finish,assist,closing,handoff");
    }
#endif
    uint64_t cycles = 0;
    for (int step = 0; step < kn.steps; ++step) {
        for (int i = 0; i < 300; ++i) {
            const size_t len = 1 + rng() % 50;
            std::vector<u16> buf(len, static_cast<u16>('a' + i % 26));
            Root s(a, alloc::allocString(buf.data(), len));
            Root n(a, alloc::allocInt(step));
            HPointer t = alloc::tuple2(alloc::boxed(s.h), alloc::boxed(n.h), 0);
            if (rng() % 64 == 0) {
                const size_t k = rng() % keep.size();
                keep[k]->h = t;
                want[k] = -1000000 - step;
            }
        }
        if (step % 9 == 0) {
            std::vector<u16> big(5000, 'L');
            keep.push_back(std::make_unique<Root>(a, alloc::allocString(big.data(), big.size())));
            want.push_back(-1);
        }
        // lbaba (CR-037 / CR-017): the previous period's string, x and doomed
        // Tuple2 die now; an idle STW major frees them (so the next family can
        // reuse the string's cell).
        if (kn.lb_every && step % kn.lb_every == 1) lb_slot.reset();
        if (kn.doom_every && step % kn.doom_every == 1) {
            x_slot.reset();
            if (doom_next) doomed[doom_next - 1].reset();
        }
        if (kn.idle_major_every && step % kn.idle_major_every == kn.idle_major_at) a.majorGC();
        if (kn.ylos_every > 0 && step % kn.ylos_every == 0) {
            // CR-020: a new family replaces the oldest (whose Array, by now
            // promoted in place, becomes old garbage).
            ++serial;
            const bool large = frng() % 8 == 0;
            const size_t len = kn.ylos_len ? kn.ylos_len
                             : large ? 4100 + frng() % 1900    // 32.8-48 KiB: a large block
                                     : 1030 + frng() % 2600;   // 8.1-29 KiB: a mixed bag page
            Family& prev = fams[static_cast<size_t>(serial - 1) % kFamilyRing];
            const bool chained = serial % 4 != 0 && !prev.parents.empty();
            // The previous family's Array, through its first parent (rooted
            // by buildFamily before it allocates).
            const HPointer pa = chained ? familyArray(a, prev) : alloc::unit();
            Family& f = fams[static_cast<size_t>(serial) % kFamilyRing];
            f.parents.clear();
            buildFamily(a, serial, len, chained, pa, keep, tuples, f.parents);
            f.serial = serial;
            f.len = len;
            f.chained = chained;
            if (large) ++fam_large;
            if (h->getOldGen().isYoungLarge(a.resolve(familyArray(a, f)))) ++fam_ylos;
        }
        // CR-037: a large string whose body (8 + 2L bytes) is the family
        // Array's size, so after the idle major the next family can land in
        // its freed cell (a reused lb_bodies address).
        if (kn.lb_every && step % kn.lb_every == 0) {
            std::vector<u16> lb(4 * kn.ylos_len + 4, u'l');
            lb_slot = std::make_unique<Root>(a, alloc::allocString(lb.data(), lb.size()));
        }
        // CR-017: a young x pointing at the next doomed old Tuple2.
        if (kn.doom_every && step >= 8 && step % kn.doom_every == 0 && doom_next < doomed.size())
            x_slot = std::make_unique<Root>(
                a, alloc::tuple2(alloc::boxed(doomed[doom_next++]->h), alloc::boxed(alloc::allocInt(step)), 0));
        if (step % kn.cycle_every == kn.cycle_at && !OldGenSpaceTestAccess::cycleActive(h->getOldGen())) {
            h->test_force_major_trigger_ = true;
            ++cycles;
        }
#if ECO_TLA_TRACE_ENABLED
        if (kn.fork_every > 0 && step % kn.fork_every == kn.fork_at &&
            OldGenSpaceTestAccess::cycleActive(h->getOldGen())) {
            forkNow();
        }
#endif
        a.minorGC();
#if ECO_TLA_TRACE_ENABLED
        if (kn.major_every > 0 && step % kn.major_every == kn.major_at &&
            OldGenSpaceTestAccess::cycleActive(h->getOldGen())) {
            a.majorGC();
        }
#endif
        // lbaba: this step's family, right after the minor that follows the
        // idle major (the reused-address window, CR-037).
        if (kn.lb_every && step % kn.lb_every == 1 && kn.ylos_every > 0) {
            const Family& f = fams[static_cast<size_t>(serial) % kFamilyRing];
            if (!f.parents.empty()) checkFamily(a, f);
        }
        // Verify everything rooted.
        if (step % kn.verify_every == 0) {
            for (size_t k = 0; k < keep.size(); ++k) {
                void* o = a.resolve(keep[k]->h);
                if (!o) fail("a rooted value vanished");
                if (want[k] >= 0) {
                    Tuple2* t = static_cast<Tuple2*>(o);
                    if (intOf(a, t->a.p) != want[k]) fail("a rooted value changed");
                } else if (want[k] <= -1000000) {
                    Tuple2* t = static_cast<Tuple2*>(o);
                    if (intOf(a, t->b.p) != -(want[k] + 1000000)) fail("a replaced value changed");
                }
            }
            for (const Family& f : fams)
                if (!f.parents.empty()) checkFamily(a, f);
        }
    }
    while (OldGenSpaceTestAccess::cycleActive(h->getOldGen())) a.minorGC();
#if ECO_TLA_TRACE_ENABLED
    if (kn.trace != nullptr && !tlatrace::end(nullptr)) fail("writing the trace");
#endif
    const ConcMarkStats& cm = h->getOldGen().getStats().cm;
    if (regions) {
        const RegionTenureStats& rg = h->getNursery().getStats().rg;
        std::printf("region scenario collectors=%u age=%u: minors %llu, tenured %llu, late %llu, par runs %llu, "
                    "marked %llu, zapped %llu\n",
                    collectors, age, (unsigned long long)rg.minors, (unsigned long long)rg.tenured,
                    (unsigned long long)rg.late, (unsigned long long)rg.par_runs,
                    (unsigned long long)rg.age_marked, (unsigned long long)rg.zapped);
    }
    std::printf("heap scenario B=%u T=%u minor=%u: %llu forced cycles ok (episodes %llu, bg units %llu, "
                "assists %llu, closings with work %llu, early done %llu, parallel minors %llu)\n", bg, slices, minor,
                (unsigned long long)cycles, (unsigned long long)cm.episodes_launched,
                (unsigned long long)cm.bg_units, (unsigned long long)cm.assists,
                (unsigned long long)cm.closings_with_work, (unsigned long long)cm.done_k_hist[0],
                (unsigned long long)h->getNursery().getStats().pmin.minors_parallel);
    if (kn.ylos_every > 0) {
        for (const Family& f : fams)
            if (!f.parents.empty()) checkFamily(a, f);
        const LargePtrStats& lh = h->getStats().lp;
        const LargePtrStats& ln = h->getNursery().getStats().lp;
        const LargePtrStats& lo = h->getOldGen().getStats().lp;
        std::printf("  ylos: %lld families (%llu YLOS at birth, %llu large blocks); large allocs: nursery %llu, "
                    "YLOS %llu; reach calls %llu, scans %llu; promoted in place %llu, freed at a minor %llu, "
                    "retired at a major %llu\n",
                    (long long)serial, (unsigned long long)fam_ylos, (unsigned long long)fam_large,
                    (unsigned long long)lh.nursery_allocs, (unsigned long long)lh.ylos_allocs,
                    (unsigned long long)ln.ylos_reach_calls, (unsigned long long)ln.ylos_scans,
                    (unsigned long long)lo.ylos_promoted_in_place, (unsigned long long)lo.ylos_freed_minor,
                    (unsigned long long)lo.ylos_retired_major);
    }
    if (kn.pool && a.pageWork() != nullptr) {
        const gc::PageWorkCounters& pc = a.pageWork()->counters();
        const gc::GCHelperPool::Stats& ps = gc::GCHelperPool::instance().stats();
        std::printf("  pool: released %llu extents, discard jobs %llu (%llu extents), cancelled %llu, "
                    "populate jobs %llu (supported %d), waits: reuse %llu, release %llu, slot %llu; "
                    "process pool: posts %llu, stalls %llu (outside a pause %llu)\n",
                    (unsigned long long)pc.released_extents, (unsigned long long)pc.discard_jobs,
                    (unsigned long long)pc.discard_posted_extents, (unsigned long long)pc.cancelled_extents,
                    (unsigned long long)pc.populate_jobs, pc.populate_supported ? 1 : 0,
                    (unsigned long long)pc.reuse_waits, (unsigned long long)pc.release_waits,
                    (unsigned long long)pc.slot_full_waits, (unsigned long long)ps.posts.load(),
                    (unsigned long long)ps.stall_count.load(), (unsigned long long)ps.stall_outside_pause.load());
    }
}
#if ECO_TLA_TRACE_ENABLED
// M1 trace (a): the cycle projection (plans/threaded-gc-tla-M1-snapshot-mark.md
// §8 (a)). Shorter than the TSan scenarios; each forks a few steps after a t0
// (a fork stop, then a relaunch or a finished episode) and runs explicit
// majors mid-cycle (a join).
struct TraceScenario {
    const char* name;
    unsigned bg, slices, minor;
    bool regions;
    Knobs kn;
};
Knobs traceKnobs(int fork_at, int major_at) {
    Knobs k;
    k.steps = 200;
    k.cycle_every = 20;
    k.old_pairs = 60000;
    k.fork_every = 20;
    k.fork_at = fork_at;
    k.major_every = 60;
    k.major_at = major_at;
    return k;
}
// A small heap near its cap: cycles start on global pressure, and some end
// early on the pressure finish.
Knobs pressureKnobs() {
    Knobs k = traceKnobs(3, 37);
    k.max_heap_mb = 20;          // tuned: about half the cycles end on pressure
    k.global_fraction = 0.4f;
    k.finish_fraction = 0.7;
    return k;
}
const TraceScenario kTraceScenarios[] = {
    {"legacy-b2", 2, 4, 1, false, traceKnobs(2, 23)},
    {"legacy-b4-t8", 4, 8, 1, false, traceKnobs(1, 25)},
    {"parminor-b2", 2, 4, 4, false, traceKnobs(3, 41)},
    {"region-b2", 2, 4, 4, true, traceKnobs(2, 43)},
    {"pressure-b2", 2, 8, 1, false, pressureKnobs()},
};

int traceMain(int argc, char** argv) {
    tlatrace::nameThread("mut", -1);
    if (argc >= 3 && std::strcmp(argv[1], "cycle") == 0) {
        for (const TraceScenario& s : kTraceScenarios) {
            if (std::strcmp(s.name, argv[2]) != 0) continue;
            Knobs kn = s.kn;
            kn.trace = s.name;
            scenario(s.bg, s.slices, 11, s.minor, s.regions, 1, 1, kn);
            std::printf("heap_driver trace %s PASS\n", s.name);
            return 0;
        }
    }
    if (argc >= 2 && std::strcmp(argv[1], "tiny") == 0) return tinyGraphMain(argc - 1, argv + 1);
    if (argc >= 2 && std::strcmp(argv[1], "promo") == 0) return promoTraceMain(argc - 1, argv + 1);
    if (argc >= 2 && std::strcmp(argv[1], "tenure") == 0) return tinyTenureMain(argc - 1, argv + 1);
    std::fprintf(stderr, "usage: gc-heap-trace cycle <name> | tiny <seed> ... | tenure <seed> ...\n  cycle scenarios:");
    for (const TraceScenario& s : kTraceScenarios) std::fprintf(stderr, " %s", s.name);
    std::fprintf(stderr, "\n");
    return 2;
}
#endif
}  // namespace

#if ECO_TLA_TRACE_ENABLED
int main(int argc, char** argv) { return traceMain(argc, argv); }
#else
int promoSweepMain(int argc, char** argv);   // promo_sweep.cpp (M4; not in the default run)
int ylosSweepMain(int argc, char** argv);    // ylos_sweep.cpp (CR-019; not in the default run)
// Register reproductions, Phase C (plans/threaded-gc-register-repros-impl.md
// §5): deterministic TSan pairs, not in the default run (each reports by design).
int promoDetMain(int argc, char** argv);     // promo_sweep.cpp: det-cr014-live, det-cr001, det-cr002
int ylosDetMain(int argc, char** argv);      // ylos_sweep.cpp: det-cr019
int cr012Main(int argc, char** argv);        // cr012_two_heap.cpp: cr012 a|e
namespace {
// The default run's nine scenarios, for the arms below.
struct ListEntry {
    unsigned bg, slices;
    uint64_t seed;
    unsigned minor;
    bool regions;
    unsigned collectors, age;
};
const ListEntry kDefaultList[] = {
    {2, 4, 1, 1, false, 1, 1}, {4, 16, 2, 1, false, 1, 1}, {3, 8, 3, 1, false, 1, 1},
    {2, 4, 4, 4, false, 1, 1}, {4, 16, 5, 3, false, 1, 1},
    {2, 4, 6, 4, true, 1, 1},  {2, 4, 7, 4, true, 4, 1},
    {2, 4, 8, 4, true, 1, 2},  {2, 4, 9, 4, true, 1, 3},
};
// `gc-heap-tsan pool|ylos [jitter_us [first [count]]]`: the default list (or
// entries [first, first + count) of it) with the arm's knobs. jitter_us sets
// ECO_GC_HELPER_JITTER_US before the allocator's first initialize (pool jobs,
// mark gang, background gang and tenure collectors sleep a random [0, n) us).
//   pool: CR-006 -- gc_thread_mode 2 (Knobs::pool) plus the CR-020 families
//         every 2 steps, whose promoted Arrays become old garbage the
//         post-sweep shrink releases (so the pool has discard work);
//   ylos: CR-020 -- the families every 2 steps, gc_thread_mode 0.
int armMain(int argc, char** argv) {
    const bool pool = std::strcmp(argv[1], "pool") == 0;
    if (argc > 2 && std::strcmp(argv[2], "0") != 0) setenv("ECO_GC_HELPER_JITTER_US", argv[2], 1);
    const size_t n = sizeof kDefaultList / sizeof kDefaultList[0];
    const size_t first = argc > 3 ? std::strtoull(argv[3], nullptr, 10) : 0;
    const size_t count = argc > 4 ? std::strtoull(argv[4], nullptr, 10) : n;
    Knobs kn;
    kn.pool = pool;
    kn.ylos_every = 2;
    for (size_t k = first; k < n && k < first + count; ++k) {
        const ListEntry& e = kDefaultList[k];
        scenario(e.bg, e.slices, e.seed, e.minor, e.regions, e.collectors, e.age, kn);
    }
    std::printf("heap_driver %s PASS\n", argv[1]);
    return 0;
}
// Register CR-037 / CR-017 (plans/threaded-gc-register-repros-impl.md Step
// 30): `gc-heap-tsan lbaba [jitter_us [seed0]]`. Region nursery (mode 2, one
// collector), ages 1 and 2, B = 1..4 background markers, fixed family lengths
// 1600 and 4500 (12,816 / 36,016 B: a bag cell and a large block). Every third
// step a large string of the family Array's size dies and an idle STW major
// frees it, so the next family's YLOS Array can take its freed lb_bodies cell
// (CR-037); a young x -> an old doomed Tuple2, both dying one step later
// (CR-017); cycles forced off the idle major's step. Oracles: "a family's young
// element changed" or TV7 (CR-037); IM4 or "parallel marker reached nursery
// object" (CR-017); TSan reports. Expected to FAIL today; not in the default run.
int lbabaMain(int argc, char** argv) {
    if (argc > 2 && std::strcmp(argv[2], "0") != 0) setenv("ECO_GC_HELPER_JITTER_US", argv[2], 1);
    const uint64_t seed0 = argc > 3 ? std::strtoull(argv[3], nullptr, 10) : 1;
    uint64_t n = 0;
    for (unsigned age : {1u, 2u}) {
        for (unsigned bg = 1; bg <= 4; ++bg) {
            for (size_t len : {size_t{1600}, size_t{4500}}) {
                Knobs kn;
                kn.steps = 600;
                kn.old_pairs = 20000;
                kn.cycle_every = 2 + static_cast<int>(n % 3);
                kn.cycle_at = 1 % kn.cycle_every;
                kn.idle_major_every = 3;
                kn.idle_major_at = 1;
                kn.lb_every = kn.doom_every = 3;
                kn.ylos_every = 1;
                kn.ylos_len = len;
                kn.verify_every = 3;
                std::printf("lbaba run %llu: age %u, B %u, ylos_len %zu\n", (unsigned long long)n, age, bg, len);
                std::fflush(stdout);
                scenario(bg, 4, seed0 + n++, /*minor=*/1, /*regions=*/true, 1, age, kn);
            }
        }
    }
    std::printf("heap_driver lbaba PASS\n");
    return 0;
}
}  // namespace
int main(int argc, char** argv) {
    // M4: `gc-heap-tsan promo [seed [rounds [workers [jitter_us [exact
    // [sweep_bytes]]]]]]`, parallel promotion during a pending lazy sweep
    // (promo_sweep.cpp). Expected to fail under TSan until CR-001, CR-002 and
    // CR-016 are fixed, so the default run below leaves it out.
    if (argc >= 2 && std::strcmp(argv[1], "promo") == 0) return promoSweepMain(argc - 1, argv + 1);
    // CR-006 / CR-020 arms (armMain above).
    if (argc >= 2 && (std::strcmp(argv[1], "pool") == 0 || std::strcmp(argv[1], "ylos") == 0))
        return armMain(argc, argv);
    // CR-037 / CR-017: `gc-heap-tsan lbaba [jitter_us [seed0]]` (lbabaMain above).
    if (argc >= 2 && std::strcmp(argv[1], "lbaba") == 0) return lbabaMain(argc, argv);
    // CR-019: `gc-heap-tsan ylos-sweep [seed [rounds [workers [jitter_us [age
    // [sweep_bytes]]]]]]` (ylos_sweep.cpp): a legacy parallel minor sweeps a
    // mixed block holding a young large object that another worker ages.
    if (argc >= 2 && std::strcmp(argv[1], "ylos-sweep") == 0) return ylosSweepMain(argc - 1, argv + 1);
    // Register reproductions (Phase C): `det-cr014-live`, `det-cr001 {rf|wf}
    // {inloop|tail}`, `det-cr002`, `det-cr019 {t1first|t2first}`, `cr012 {a|e}`.
    // Exit 0 clean, 3 NOT REACHED, 66 a TSan report (expected today).
    if (argc >= 2 && std::strcmp(argv[1], "det-cr019") == 0) return ylosDetMain(argc - 1, argv + 1);
    if (argc >= 2 && std::strncmp(argv[1], "det-cr0", 7) == 0) return promoDetMain(argc - 1, argv + 1);
    if (argc >= 2 && std::strcmp(argv[1], "cr012") == 0) return cr012Main(argc - 1, argv + 1);
    scenario(2, 4, 1);
    scenario(4, 16, 2);
    scenario(3, 8, 3);
    // threaded-gc-06: parallel minors overlapping background episodes.
    scenario(2, 4, 4, 4);
    scenario(4, 16, 5, 3);
    // threaded-gc-07: the region nursery with concurrent tenuring (mode 2),
    // a 5c cycle every ~40 minors, 4 parallel minor workers.
    scenario(2, 4, 6, 4, /*regions=*/true, /*collectors=*/1);
    scenario(2, 4, 7, 4, /*regions=*/true, /*collectors=*/4);
    // threaded-gc-07b: tenure ageing (k = 2, 3): the ageing mark on the
    // collector, the zap in the merge, 5c cycles, 4 minor workers.
    scenario(2, 4, 8, 4, /*regions=*/true, /*collectors=*/1, /*age=*/2);
    scenario(2, 4, 9, 4, /*regions=*/true, /*collectors=*/1, /*age=*/3);
    // Register CR-006 and CR-020: the helper pool (gc_thread_mode 2) and the
    // young large object families, one legacy parallel-minor scenario and one
    // region scenario (the `pool` arm runs all nine).
    Knobs pool_ylos;
    pool_ylos.pool = true;
    pool_ylos.ylos_every = 2;
    scenario(2, 4, 10, 4, /*regions=*/false, 1, 1, pool_ylos);
    scenario(2, 4, 11, 4, /*regions=*/true, 1, 1, pool_ylos);
    std::printf("heap_driver PASS\n");
    return 0;
}
#endif
