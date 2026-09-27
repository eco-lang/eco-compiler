/**
 * threaded-gc-05a (plans/threaded-gc-05a-incremental-marking.md): the
 * incremental mark cycle (HEAP_063). Configs are built programmatically (unit
 * tests do not see ECO_HEAP_CONFIG in the old gen). A cycle is started
 * deterministically with ThreadLocalHeap::test_force_major_trigger_: the next
 * minor end behaves as if a major trigger fired.
 *
 * Validate builds additionally run IM1-IM9 on every cycle these tests drive.
 */

#include "IncrementalMarkTest.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <stdexcept>
#include <unordered_set>
#include <vector>

#if !defined(_WIN32)
#include <fcntl.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

#include "Allocator.hpp"
#include "AllocatorCommon.hpp"
#include "GCStats.hpp"
#include "Heap.hpp"
#include "HeapConfigJson.hpp"
#include "HeapHelpers.hpp"
#include "NurserySpace.hpp"
#include "OldGenSpace.hpp"
#include "TestHelpers.hpp"
#include "ThreadLocalHeap.hpp"

using namespace Elm;
using namespace Elm::TestHelpers;

namespace {

using OA = OldGenSpaceTestAccess;
using CS = OldGenSpace::CycleState;

constexpr size_t KiB = 1024;
constexpr size_t MiB = 1024 * 1024;

// 64 KiB-per-side nursery, 32 KiB old-gen pages, T = `slices`, one-unit
// minimum slices (so every slice does paced work on these small heaps).
HeapConfig incrConfig(uint32_t slices, bool on = true, uint32_t divisor = 8) {
    HeapConfig cfg;
    cfg.alloc_buffer_size          = 32 * KiB;
    cfg.nursery_block_count        = 4;
    cfg.nursery_max_block_count    = 4;
    cfg.initial_old_gen_size       = 256 * KiB;
    cfg.max_heap_size              = 256ULL * MiB;
    cfg.large_object_threshold     = 8 * KiB;
    cfg.large_ptr_nursery_divisor  = divisor;
    cfg.decommit_on_oldgen_release = false;
    cfg.gc_thread_mode             = 0;
    cfg.incremental_mark           = on;
    cfg.incremental_mark_slices    = slices;
    cfg.incremental_mark_min_slice_units = 1;
    // threaded-gc-05b: rerun every 5a test on N markers with the test-only
    // variable ECO_TEST_MARK_THREADS (plan Step 6.4); default 1 (serial).
    if (const char* mt = std::getenv("ECO_TEST_MARK_THREADS")) {
        cfg.gc_mark_threads = static_cast<uint32_t>(std::atoi(mt));
    }
    // threaded-gc-05c: the compiled default (conc_mark = 2) runs these 05a
    // scenarios with background marking; ECO_TEST_CONC_MARK=0 reruns them on
    // the 05b in-pause path.
    if (const char* cm = std::getenv("ECO_TEST_CONC_MARK")) {
        cfg.conc_mark = static_cast<uint32_t>(std::atoi(cm));
    }
    cfg.validate();
    return cfg;
}

ThreadLocalHeap* tlh(Allocator& a) { return AllocatorTestAccess::getThreadHeap(a); }
OldGenSpace& og(Allocator& a) { return tlh(a)->getOldGen(); }

#if ENABLE_GC_STATS
const IncrMarkStats& im(Allocator& a) { return og(a).getStats().im; }
#endif

// A long-lived root slot that unregisters itself.
struct Root {
    Allocator& a;
    HPointer h;
    Root(Allocator& alloc, HPointer v) : a(alloc), h(v) { a.getRootSet().addRoot(&h); }
    ~Root() { a.getRootSet().removeRoot(&h); }
    Root(const Root&) = delete;
    Root& operator=(const Root&) = delete;
};

i64 intValue(Allocator& a, HPointer hp) {
    void* obj = a.resolve(hp);
    if (obj == nullptr || getHeader(obj)->tag != Tag_Int) {
        throw std::runtime_error("expected a heap Int");
    }
    return static_cast<ElmInt*>(obj)->value;
}

bool marked(Allocator& a, const void* obj) { return OA::isMarked(og(a), obj); }

// Old-gen Int (two minors promote at promotion_age 1). Must be called with no
// cycle active, or the minors are cycle steps.
HPointer oldInt(Allocator& a, i64 v) {
    Root r(a, alloc::allocInt(v));
    a.minorGC();
    a.minorGC();
    if (a.isInNursery(a.resolve(r.h))) throw std::runtime_error("oldInt: not promoted");
    return r.h;
}

void churn(size_t n) {
    for (size_t i = 0; i < n; ++i) (void)alloc::allocInt(static_cast<i64>(0x5A5A0000 + i));
}


// Drives minors until the mark is complete (HandoffDue): mark bits are
// exactly the cycle's result here, before the tail sweeps anything.
void runToHandoffDue(Allocator& a) {
    for (int guard = 0; OA::cycleState(og(a)) == CS::Marking; ++guard) {
        if (guard > 100000) throw std::runtime_error("cycle never closed");
        a.minorGC();
    }
}

void runToHandoff(Allocator& a) {
    for (int guard = 0; OA::cycleActive(og(a)); ++guard) {
        if (guard > 100000) throw std::runtime_error("cycle never handed off");
        a.minorGC();
    }
}

// The next minor end starts a cycle (T = 0: the whole cycle runs in it). A
// cycle the heap's own triggers started is finished first, so the new t0 is
// exactly here.
void startCycle(Allocator& a) {
    runToHandoff(a);
    tlh(a)->test_force_major_trigger_ = true;
    a.minorGC();
}

HPointer tupleOf(HPointer x, HPointer y) {
    return alloc::tuple2(alloc::boxed(x), alloc::boxed(y), 0);
}

// A large (n-slot) pointer array of fresh Ints value(i) = i * mul.
HPointer makeLargeIntArray(Allocator& alloc, size_t n, i64 mul) {
    std::vector<HPointer> elems(n, alloc::listNil());
    StackRootRangeGuard guard(elems.data(), elems.size(), ~uint64_t{0});
    for (size_t i = 0; i < n; ++i) elems[i] = alloc::allocInt(static_cast<i64>(i) * mul);
    const size_t total = (sizeof(ElmArray) + n * sizeof(Unboxable) + 7) & ~size_t{7};
    ElmArray* a0 = static_cast<ElmArray*>(alloc.allocate(total, Tag_Array));
    a0->header.size = static_cast<u32>(n);
    a0->length = 0;
    a0->padding = 0;
    a0->header.unboxed = 0;
    for (size_t i = 0; i < n; ++i) alloc::arrayPush(a0, alloc::boxed(elems[i]), true);
    return alloc.wrap(a0);
}

void checkLargeIntArray(Allocator& alloc, HPointer arr, size_t n, i64 mul, const char* what) {
    ElmArray* a = static_cast<ElmArray*>(alloc.resolve(arr));
    if (a->length != n) throw std::runtime_error(std::string(what) + ": length");
    for (size_t i = 0; i < n; ++i) {
        if (intValue(alloc, a->elements[i].p) != static_cast<i64>(i) * mul) {
            throw std::runtime_error(std::string(what) + ": element " + std::to_string(i));
        }
    }
}

HPointer bigString(size_t chars, u16 fill) {
    std::vector<u16> buf(chars, fill);
    return alloc::allocString(buf.data(), buf.size());
}

void* stringBody(Allocator& a, HPointer s) {
    void* h = a.resolve(s);
    if (getHeader(h)->tag != Tag_LargeStringHeader) throw std::runtime_error("not split");
    return a.resolve(static_cast<LargeStringHeader*>(h)->body);
}

#if !defined(_WIN32)
// Runs `fn` in a forked child with stderr silenced. Returns the child's wait
// status: WIFSIGNALED for a validator abort, WEXITSTATUS otherwise.
int runInChild(const std::function<int()>& fn) {
    std::fflush(stdout);
    std::fflush(stderr);
    pid_t pid = fork();
    if (pid == 0) {
        if (std::getenv("ECO_TEST_CHILD_STDERR") == nullptr) {   // debugging aid
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
// Step 2: config and pause kinds
// ============================================================================

Testing::TestCase testIncrConfigJson(
    "threaded-gc-05a: incremental_mark_* JSON keys and validation",
    []() {
        HeapConfig def;
        TEST_ASSERT(def.incremental_mark == INCREMENTAL_MARK);
        TEST_ASSERT(def.incremental_mark_slices == INCREMENTAL_MARK_SLICES);
#if !defined(_WIN32)
        auto load = [](const char* json, HeapConfig& out) {
            char path[] = "/tmp/eco-gc05a-cfg-XXXXXX";
            int fd = mkstemp(path);
            TEST_ASSERT(fd >= 0);
            TEST_ASSERT(write(fd, json, std::strlen(json)) ==
                        static_cast<ssize_t>(std::strlen(json)));
            close(fd);
            applyHeapConfigJsonFile(out, path);
            unlink(path);
        };
        HeapConfig a;
        load("{\"incremental_mark\": true, \"incremental_mark_slices\": 7,"
             " \"incremental_mark_min_slice_units\": \"2K\","
             " \"incremental_mark_predict_growth\": 1.5,"
             " \"incremental_mark_finish_fraction\": 0.9}", a);
        TEST_ASSERT(a.incremental_mark);
        TEST_ASSERT(a.incremental_mark_slices == 7);
        TEST_ASSERT(a.incremental_mark_min_slice_units == 2048);
        TEST_ASSERT(a.incremental_mark_predict_growth == 1.5);
        TEST_ASSERT(a.incremental_mark_finish_fraction == 0.9);
        a.validate();
#endif
        auto throws = [](HeapConfig c) {
            try {
                c.validate();
            } catch (const std::invalid_argument&) {
                return true;
            }
            return false;
        };
        HeapConfig b;
        b.incremental_mark = true;
        b.old_gen_bitmap_alloc = false;
        TEST_ASSERT(throws(b));                    // requires bitmap allocation
        HeapConfig c;
        c.incremental_mark_finish_fraction = c.major_gc_global_pressure_fraction;
        TEST_ASSERT(throws(c));                    // must exceed the pressure trigger
        HeapConfig d;
        d.incremental_mark_predict_growth = 0.5;
        TEST_ASSERT(throws(d));
        HeapConfig e;
        e.incremental_mark_slices = 5000;
        TEST_ASSERT(throws(e));
    });

Testing::TestCase testPauseKindsCounted(
    "threaded-gc-05a: pause kinds 0-5 are counted",
    []() {
#if ENABLE_GC_STATS
        GCPhaseTotals t;
        for (uint8_t k = 0; k < 6; ++k) t.addPause(1000 * k, 10, k);
        for (int k = 0; k < 6; ++k) TEST_ASSERT(t.pause_count_by_kind[k] == 1);
        GCPhaseTotals u;
        u.merge(t);
        for (int k = 0; k < 6; ++k) TEST_ASSERT(u.pause_count_by_kind[k] == 1);
#endif
    });

// ============================================================================
// Step 3: the t0 snapshot (T = 0)
// ============================================================================

namespace {

struct T0Result {
    size_t major_live, post_sweep_live, allocated;
    bool o_marked;
    i64 o_value;
};

// Old list kept, old list dropped, and an old object O reachable only
// through a young survivor tuple at the trigger minor.
T0Result t0Scenario(bool incremental) {
    auto& a = initAllocator(incrConfig(0, incremental));
    Root keep(a, alloc::listNil());
    Root drop(a, alloc::listNil());
    for (i64 i = 0; i < 3000; ++i) {
        keep.h = alloc::cons(alloc::boxed(alloc::allocInt(i)), keep.h, true);
        drop.h = alloc::cons(alloc::boxed(alloc::allocInt(-i)), drop.h, true);
    }
    a.minorGC();
    a.minorGC();
    drop.h = alloc::listNil();
    HPointer o = oldInt(a, 4242);
    void* o_ptr = a.resolve(o);
    Root x(a, tupleOf(o, o));                    // young; the only path to O
    TEST_ASSERT(a.isInNursery(a.resolve(x.h)));
    startCycle(a);                               // STW major / T = 0 cycle here
    TEST_ASSERT(!OA::cycleActive(og(a)));
    T0Result r{OA::majorLive(og(a)), OA::postSweepLive(og(a)),
               og(a).getAllocatedBytes(), marked(a, o_ptr), 0};
    Tuple2* t = static_cast<Tuple2*>(a.resolve(x.h));
    r.o_value = intValue(a, t->a.p);
    return r;
}

}  // namespace

Testing::TestCase testIncrT0MatchesStwLiveSet(
    "threaded-gc-05a: T = 0 marks exactly what the STW major marks",
    []() {
        const T0Result stw = t0Scenario(false);
        const T0Result inc = t0Scenario(true);
        TEST_ASSERT(stw.o_marked && inc.o_marked);
        TEST_ASSERT(stw.o_value == 4242 && inc.o_value == 4242);
        TEST_ASSERT(stw.major_live == inc.major_live);
        TEST_ASSERT(stw.post_sweep_live == inc.post_sweep_live);
        TEST_ASSERT(stw.allocated == inc.allocated);
    });

// These two use T = 1 so the mark state can be read at HandoffDue (the
// handoff's first gap-sweep slice clears mixed-block bits); the snapshot is
// the same code for every T.
Testing::TestCase testIncrT0YlosCellMarked(
    "threaded-gc-05a: a YLOS object reachable through a young object is marked at t0",
    []() {
        auto& a = initAllocator(incrConfig(1, true, /*divisor=*/0));
        HPointer arr0 = makeLargeIntArray(a, 1500, 3);
        Root arr(a, arr0);
        void* arr_ptr = a.resolve(arr.h);
        TEST_ASSERT(og(a).isYoungLarge(arr_ptr));
        Root x(a, tupleOf(arr.h, arr.h));
        arr.h = alloc::listNil();                // only the tuple holds it now
        startCycle(a);
        TEST_ASSERT(marked(a, arr_ptr));         // the snapshot marks the cell
        runToHandoffDue(a);
        TEST_ASSERT(marked(a, arr_ptr));
        runToHandoff(a);
        Tuple2* t = static_cast<Tuple2*>(a.resolve(x.h));
        checkLargeIntArray(a, t->a.p, 1500, 3, "YLOS after the cycle");
        for (int k = 0; k < 3; ++k) {
            churn(2000);
            a.minorGC();
        }
        t = static_cast<Tuple2*>(a.resolve(x.h));
        checkLargeIntArray(a, t->a.p, 1500, 3, "YLOS after minors");
    });

Testing::TestCase testIncrT0BuilderChildrenSurvive(
    "threaded-gc-05a: a nursery builder holding the only reference to an old object",
    []() {
        auto& a = initAllocator(incrConfig(1));
        HPointer o = oldInt(a, 77);
        void* o_ptr = a.resolve(o);
        Root b(a, alloc::allocArrayBuilder(8));
        alloc::arrayPush(static_cast<ElmArray*>(a.resolve(b.h)), alloc::boxed(o), true);
        startCycle(a);
        runToHandoffDue(a);
        TEST_ASSERT(marked(a, o_ptr));
        runToHandoff(a);
        ElmArray* arr = static_cast<ElmArray*>(a.resolve(b.h));
        TEST_ASSERT(intValue(a, arr->elements[0].p) == 77);
    });

// ============================================================================
// Step 4: the multi-minor cycle
// ============================================================================

Testing::TestCase testIncrScheduleFixed(
    "threaded-gc-05a: the handoff is at minor t0 + T + 1 whatever the progress",
    []() {
        auto& a = initAllocator(incrConfig(4));
        Root keep(a, alloc::listNil());
        for (i64 i = 0; i < 2000; ++i)
            keep.h = alloc::cons(alloc::boxed(alloc::allocInt(i)), keep.h, true);
        a.minorGC();
        a.minorGC();
#if ENABLE_GC_STATS
        const uint64_t slices0 = im(a).slices;
        const uint64_t cycles0 = im(a).cycles;
#endif
        startCycle(a);
        TEST_ASSERT(OA::cycleState(og(a)) == CS::Marking);
        TEST_ASSERT(OA::gcPhase(og(a)) == GCPhase::Marking);
        for (uint32_t k = 1; k <= 3; ++k) {
            a.minorGC();
            TEST_ASSERT(OA::cycleK(og(a)) == k);
            TEST_ASSERT(OA::cycleState(og(a)) == CS::Marking);
        }
        a.minorGC();                                  // k = 4: closing slice
        TEST_ASSERT(OA::cycleState(og(a)) == CS::HandoffDue);
        a.minorGC();                                  // k = 5: handoff
        TEST_ASSERT(!OA::cycleActive(og(a)));
        TEST_ASSERT(OA::gcPhase(og(a)) != GCPhase::Marking);
        TEST_ASSERT(OA::prevCycleUnits(og(a)) >= 2000);
#if ENABLE_GC_STATS
        TEST_ASSERT(im(a).slices - slices0 == 4);
        TEST_ASSERT(im(a).cycles - cycles0 == 1);
#endif
        // A tiny live set: the stack empties early, later slices do nothing,
        // and the handoff is still at k = T + 1.
        keep.h = alloc::listNil();
        startCycle(a);
        a.minorGC();
        a.minorGC();
        const uint64_t units_after_2 = OA::cycleUnits(og(a));
        a.minorGC();
        TEST_ASSERT(OA::cycleUnits(og(a)) == units_after_2);
        a.minorGC();
        TEST_ASSERT(OA::cycleState(og(a)) == CS::HandoffDue);
        a.minorGC();
        TEST_ASSERT(!OA::cycleActive(og(a)));
    });

Testing::TestCase testIncrOldReachableOnlyFromSurvivor(
    "threaded-gc-05a: an old object reachable only through a t0 survivor survives",
    []() {
        auto& a = initAllocator(incrConfig(4));
        HPointer o = oldInt(a, 31337);
        void* o_ptr = a.resolve(o);
        Root x(a, tupleOf(o, o));
        startCycle(a);                       // X survives (age 1) and is walked
        a.minorGC();                         // X promoted black: never traced
        TEST_ASSERT(!a.isInNursery(a.resolve(x.h)));
        runToHandoffDue(a);
        TEST_ASSERT(marked(a, o_ptr));
        runToHandoff(a);
        // Reuse the old gen hard; O must be intact.
        for (int k = 0; k < 4; ++k) {
            Root tmp(a, alloc::listNil());
            for (i64 i = 0; i < 3000; ++i)
                tmp.h = alloc::cons(alloc::boxed(alloc::allocInt(i)), tmp.h, true);
            a.minorGC();
            a.minorGC();
        }
        Tuple2* t = static_cast<Tuple2*>(a.resolve(x.h));
        TEST_ASSERT(intValue(a, t->a.p) == 31337);
    });

Testing::TestCase testIncrRootOverwrittenAfterT0(
    "threaded-gc-05a: a root overwritten after t0 cannot lose its old target",
    []() {
        auto& a = initAllocator(incrConfig(4));
        Root r(a, oldInt(a, 555));
        void* o_ptr = a.resolve(r.h);
        startCycle(a);
        Root n(a, tupleOf(r.h, r.h));        // mutator copies O into a new object
        r.h = alloc::listNil();              // ... and overwrites the root
        runToHandoffDue(a);                  // N is promoted black on the way
        TEST_ASSERT(marked(a, o_ptr));
        runToHandoff(a);
        Tuple2* t = static_cast<Tuple2*>(a.resolve(n.h));
        TEST_ASSERT(intValue(a, t->a.p) == 555);
        // Once N is unrooted before a t0, the next cycle frees O.
        n.h = alloc::listNil();
        startCycle(a);
        runToHandoffDue(a);
        TEST_ASSERT(!marked(a, o_ptr));
        runToHandoff(a);
    });

namespace {
std::vector<uint64_t> g_test_store;   // an off-heap store (the CellStore pattern)
bool g_test_store_registered = false;
void registerTestStore(Allocator& a) {
    // initAllocator resets the RootSet, so register once per allocator reset.
    (void)g_test_store_registered;
    a.getRootSet().addExternalRootScanner(
        [](RootSet::EvacuateFn f) {
            for (uint64_t& w : g_test_store) f(w);
        },
        "test-incr-store");
}
uint64_t bitsOf(HPointer h) {
    uint64_t b;
    std::memcpy(&b, &h, sizeof(b));
    return b;
}
HPointer hpOf(uint64_t b) {
    HPointer h;
    std::memcpy(&h, &b, sizeof(h));
    return h;
}
}  // namespace

Testing::TestCase testIncrExternalStoreOverwrittenAfterT0(
    "threaded-gc-05a: an off-heap store overwritten after t0 cannot lose its old target",
    []() {
        auto& a = initAllocator(incrConfig(4));
        g_test_store.assign(1, bitsOf(alloc::listNil()));
        registerTestStore(a);
        g_test_store[0] = bitsOf(oldInt(a, 909));
        void* o_ptr = a.resolve(hpOf(g_test_store[0]));
        startCycle(a);
        Root n(a, tupleOf(hpOf(g_test_store[0]), hpOf(g_test_store[0])));
        g_test_store[0] = bitsOf(alloc::listNil());
        runToHandoffDue(a);
        TEST_ASSERT(marked(a, o_ptr));
        runToHandoff(a);
        Tuple2* t = static_cast<Tuple2*>(a.resolve(n.h));
        TEST_ASSERT(intValue(a, t->a.p) == 909);
        g_test_store.clear();
    });

Testing::TestCase testIncrAllocateBlackEveryEntryPoint(
    "threaded-gc-05a: every old-gen allocation during a cycle is black",
    []() {
        auto& a = initAllocator(incrConfig(16, true, /*divisor=*/0));
        Root seed(a, oldInt(a, 1));
        startCycle(a);
        TEST_ASSERT(OA::cycleActive(og(a)));
        // Promotion into a post-t0 uniform block.
        Root list(a, alloc::listNil());
        for (i64 i = 0; i < 500; ++i)
            list.h = alloc::cons(alloc::boxed(alloc::allocInt(i)), list.h, true);
        a.minorGC();
        a.minorGC();
        void* head = a.resolve(list.h);
        TEST_ASSERT(!a.isInNursery(head));
        TEST_ASSERT(marked(a, head));
        // A split-header string: 10 KiB body in a bag page (mixed block).
        Root s1(a, bigString(5000, 'a'));
        void* b1 = stringBody(a, s1.h);
        TEST_ASSERT(marked(a, b1));
        // A 40 KiB body: a dedicated large block.
        Root s2(a, bigString(20000, 'b'));
        void* b2 = stringBody(a, s2.h);
        TEST_ASSERT(marked(a, b2));
        // A YLOS object.
        Root y(a, makeLargeIntArray(a, 1500, 5));
        void* y_ptr = a.resolve(y.h);
        TEST_ASSERT(og(a).isYoungLarge(y_ptr));
        TEST_ASSERT(marked(a, y_ptr));
        // A permanent (old-gen) literal.
        void* p = a.allocatePermanent(sizeof(ElmInt), Tag_Int);
        static_cast<ElmInt*>(p)->value = 12;
        TEST_ASSERT(marked(a, p));
        TEST_ASSERT(OA::cycleActive(og(a)));
        runToHandoffDue(a);
        TEST_ASSERT(marked(a, a.resolve(list.h)));
        TEST_ASSERT(marked(a, b1) && marked(a, b2) && marked(a, y_ptr) && marked(a, p));
        runToHandoff(a);
        checkLargeIntArray(a, y.h, 1500, 5, "YLOS allocated black");
        TEST_ASSERT(static_cast<u16>(static_cast<ElmString*>(stringBody(a, s2.h))->chars[19999]) == 'b');
    });

Testing::TestCase testIncrNoPreT0UniformReuse(
    "threaded-gc-05a: free cells of pre-t0 uniform blocks are not reused mid-cycle",
    []() {
        auto& a = initAllocator(incrConfig(8));
        const size_t n = 3000;
        std::vector<HPointer> v(n, alloc::listNil());
        for (auto& h : v) a.getRootSet().addRoot(&h);
        for (size_t i = 0; i < n; ++i) v[i] = alloc::allocInt(static_cast<i64>(i));
        a.minorGC();
        a.minorGC();
        std::vector<void*> dead;
        for (size_t i = 0; i < n; i += 2) {
            dead.push_back(a.resolve(v[i]));
            v[i] = alloc::listNil();
        }
        startCycle(a);                  // cycle 1 frees the dead half
        runToHandoff(a);
        // Only cells whose block is still UNIFORM after cycle 1 count: a
        // mostly-dead block is demoted to mixed at the handoff, and its free
        // cells then go to the free lists (reusable mid-cycle, by design).
        std::unordered_set<void*> dead_uniform;
        for (void* p : dead)
            if (OA::inUniformBlock(og(a), p)) dead_uniform.insert(p);
        TEST_ASSERT(!dead_uniform.empty());   // otherwise the test is vacuous
        startCycle(a);                  // cycle 2: must not reuse those cells
        // (Mixed-block free-list cells built before t0 MAY be reused: they
        // were free at t0. Only pre-t0 UNIFORM cells are off limits.)
        std::vector<HPointer> w(1500, alloc::listNil());
        for (auto& h : w) a.getRootSet().addRoot(&h);
        for (size_t i = 0; i < w.size(); ++i) w[i] = alloc::allocInt(static_cast<i64>(i));
        a.minorGC();
        a.minorGC();
        TEST_ASSERT(OA::cycleActive(og(a)));
        size_t reused = 0;
        for (auto& h : w) if (dead_uniform.count(a.resolve(h))) ++reused;
        TEST_ASSERT(reused == 0);
        runToHandoff(a);
        // After the handoff the cells are queued again and reused.
        std::vector<HPointer> z(1500, alloc::listNil());
        for (auto& h : z) a.getRootSet().addRoot(&h);
        for (size_t i = 0; i < z.size(); ++i) z[i] = alloc::allocInt(static_cast<i64>(i));
        a.minorGC();
        a.minorGC();
        size_t reused_after = 0;
        for (auto& h : z) if (dead_uniform.count(a.resolve(h))) ++reused_after;
        TEST_ASSERT(reused_after > 0);
        for (auto& h : v) a.getRootSet().removeRoot(&h);
        for (auto& h : w) a.getRootSet().removeRoot(&h);
        for (auto& h : z) a.getRootSet().removeRoot(&h);
    });

Testing::TestCase testIncrTriggersSuppressed(
    "threaded-gc-05a: no major trigger fires while a cycle is active",
    []() {
        HeapConfig cfg = incrConfig(4);
        cfg.major_gc_garbage_fraction = 0.0001f;    // would fire at every minor end
        cfg.validate();
        auto& a = initAllocator(cfg);
        Root keep(a, alloc::listNil());
        for (i64 i = 0; i < 2000; ++i)
            keep.h = alloc::cons(alloc::boxed(alloc::allocInt(i)), keep.h, true);
        // The garbage trigger starts cycles on its own now; drive to one.
        for (int k = 0; k < 50 && !OA::cycleActive(og(a)); ++k) {
            churn(1000);
            a.minorGC();
        }
        TEST_ASSERT(OA::cycleActive(og(a)));
        while (OA::cycleActive(og(a))) {
            TEST_ASSERT(OA::trigger(og(a)) == OldGenSpace::MajorGCTriggerReason::None);
            churn(1000);
            a.minorGC();
        }
    });

Testing::TestCase testIncrLiveBudgetUsesTracedLive(
    "threaded-gc-05a: the LiveBudget reference and trigger baseline exclude allocate-black bytes",
    []() {
        auto& a = initAllocator(incrConfig(4));
        Root keep(a, alloc::listNil());
        for (i64 i = 0; i < 2000; ++i)
            keep.h = alloc::cons(alloc::boxed(alloc::allocInt(i)), keep.h, true);
        a.minorGC();
        a.minorGC();
        startCycle(a);
        Root more(a, alloc::listNil());
        for (i64 i = 0; i < 2000; ++i)
            more.h = alloc::cons(alloc::boxed(alloc::allocInt(i)), more.h, true);
        runToHandoff(a);                           // the new list is promoted black
        TEST_ASSERT(OA::majorLive(og(a)) == OA::cycleTracedLive(og(a)));
        // The trigger baseline excludes the black bytes: they count as
        // allocated since the major, as they would after a STW major at t0.
        TEST_ASSERT(OA::postSweepLive(og(a)) == OA::majorLive(og(a)));
        TEST_ASSERT(og(a).getAllocatedBytes() > OA::postSweepLive(og(a)));
    });

Testing::TestCase testIncrBuilderFilledDuringCycle(
    "threaded-gc-05a: a t0 builder filled during the cycle keeps its elements",
    []() {
        auto& a = initAllocator(incrConfig(4));
        const size_t n = 32;
        std::vector<HPointer> olds(n, alloc::listNil());
        for (auto& h : olds) a.getRootSet().addRoot(&h);
        for (size_t i = 0; i < n; ++i) olds[i] = alloc::allocInt(static_cast<i64>(i) * 13);
        a.minorGC();
        a.minorGC();
        Root b(a, alloc::allocArrayBuilder(n));
        startCycle(a);
        for (size_t i = 0; i < n; ++i) {
            alloc::arrayPush(static_cast<ElmArray*>(a.resolve(b.h)), alloc::boxed(olds[i]), true);
            olds[i] = alloc::listNil();            // the builder is the only holder
        }
        alloc::clear_builder(getHeader(a.resolve(b.h)));
        runToHandoff(a);
        startCycle(a);
        runToHandoff(a);
        ElmArray* arr = static_cast<ElmArray*>(a.resolve(b.h));
        TEST_ASSERT(arr->length == n);
        for (size_t i = 0; i < n; ++i)
            TEST_ASSERT(intValue(a, arr->elements[i].p) == static_cast<i64>(i) * 13);
        for (auto& h : olds) a.getRootSet().removeRoot(&h);
    });

// ============================================================================
// Step 5: deferred frees
// ============================================================================

Testing::TestCase testIncrDeferredBodyFree(
    "threaded-gc-05a: a body whose header dies mid-cycle is freed at the handoff",
    []() {
        auto& a = initAllocator(incrConfig(6));
        Root s(a, bigString(5000, 'x'));
        startCycle(a);
        void* body = stringBody(a, s.h);
        TEST_ASSERT(marked(a, body));
        s.h = alloc::listNil();
        a.minorGC();                                  // the header dies here
        TEST_ASSERT(OA::cycleActive(og(a)));
        TEST_ASSERT(OA::deferredFrees(og(a)) == 1);
        TEST_ASSERT(marked(a, body));                 // still allocated
        Root s2(a, bigString(5000, 'y'));
        TEST_ASSERT(stringBody(a, s2.h) != body);     // never reused mid-cycle
        runToHandoff(a);
        TEST_ASSERT(OA::deferredFrees(og(a)) == 0);
#if ENABLE_GC_STATS
        TEST_ASSERT(im(a).deferred_frees >= 1);
#endif
    });

Testing::TestCase testIncrDeferredYlosFree(
    "threaded-gc-05a: a YLOS object that dies mid-cycle is freed at the handoff",
    []() {
        auto& a = initAllocator(incrConfig(6, true, /*divisor=*/0));
        Root y(a, makeLargeIntArray(a, 1500, 2));
        startCycle(a);
        void* y_ptr = a.resolve(y.h);
        TEST_ASSERT(marked(a, y_ptr));
        y.h = alloc::listNil();
        a.minorGC();
        TEST_ASSERT(OA::deferredFrees(og(a)) == 1);
        TEST_ASSERT(marked(a, y_ptr));
        runToHandoff(a);
        TEST_ASSERT(OA::deferredFrees(og(a)) == 0);
        TEST_ASSERT(!marked(a, y_ptr));
    });

Testing::TestCase testIncrYlosPromotedInPlaceDuringCycle(
    "threaded-gc-05a: a t0 YLOS object promoted in place mid-cycle survives",
    []() {
        auto& a = initAllocator(incrConfig(6, true, /*divisor=*/0));
        Root y(a, makeLargeIntArray(a, 1500, 9));
        void* y_ptr = a.resolve(y.h);
        startCycle(a);                                // age 0 -> 1
        TEST_ASSERT(og(a).isYoungLarge(y_ptr));
        a.minorGC();                                  // promoted in place
        TEST_ASSERT(!og(a).isYoungLarge(y_ptr));
        TEST_ASSERT(OA::deferredFrees(og(a)) == 0);
        runToHandoffDue(a);
        TEST_ASSERT(marked(a, y_ptr));
        runToHandoff(a);
        checkLargeIntArray(a, y.h, 1500, 9, "after handoff");
        startCycle(a);
        runToHandoff(a);
        checkLargeIntArray(a, y.h, 1500, 9, "after next cycle");
    });

Testing::TestCase testIncrNoReleaseDuringCycle(
    "threaded-gc-05a: dead blocks at t0 are released only at the handoff",
    []() {
        auto& a = initAllocator(incrConfig(6));
        {
            Root big(a, alloc::listNil());
            for (i64 i = 0; i < 40000; ++i)
                big.h = alloc::cons(alloc::boxed(alloc::allocInt(i)), big.h, true);
            a.minorGC();
            a.minorGC();
        }                                             // all of it is dead now
        startCycle(a);
        const size_t blocks_t0 = OA::blockCount(og(a));
        while (OA::cycleState(og(a)) == CS::Marking) {
            TEST_ASSERT(OA::blockCount(og(a)) >= blocks_t0);
            a.minorGC();
        }
        TEST_ASSERT(OA::blockCount(og(a)) >= blocks_t0);
        a.minorGC();                                  // handoff
        TEST_ASSERT(!OA::cycleActive(og(a)));
        TEST_ASSERT(OA::blockCount(og(a)) < blocks_t0);
    });

// ============================================================================
// Step 6: joins and emergency finishes
// ============================================================================

Testing::TestCase testIncrJoinOnExplicitMajor(
    "threaded-gc-05a: an explicit major joins the cycle, then runs a STW major",
    []() {
        auto& a = initAllocator(incrConfig(8));
        Root o(a, oldInt(a, 64));
        void* o_ptr = a.resolve(o.h);
#if ENABLE_GC_STATS
        const uint64_t joins0 = im(a).finish_join;
#endif
        startCycle(a);
        a.minorGC();
        o.h = alloc::listNil();                       // dead after t0: floating
        a.majorGC();
        TEST_ASSERT(!OA::cycleActive(og(a)));
#if ENABLE_GC_STATS
        TEST_ASSERT(im(a).finish_join == joins0 + 1);
#endif
        TEST_ASSERT(!marked(a, o_ptr));               // freed by the STW major
    });

Testing::TestCase testIncrJoinOnYlosAllocFailure(
    "threaded-gc-05a: an allocation-failure major joins the cycle",
    []() {
        auto& a = initAllocator(incrConfig(8));
        Root keep(a, oldInt(a, 5));
        startCycle(a);
        a.minorGC();
        // The exact call allocateYoungLarge / allocateLargePinned make on an
        // old-gen allocation failure.
        tlh(a)->majorGC(GCStats::MajorReason::AllocFailure);
        TEST_ASSERT(!OA::cycleActive(og(a)));
        TEST_ASSERT(intValue(a, keep.h) == 5);
        // The heap is usable afterwards: another full cycle.
        startCycle(a);
        runToHandoff(a);
        TEST_ASSERT(intValue(a, keep.h) == 5);
    });

Testing::TestCase testIncrPressureFinish(
    "threaded-gc-05a: old-gen pressure finishes the cycle early",
    []() {
        HeapConfig cfg = incrConfig(8);
        cfg.major_gc_global_pressure_fraction = 0.0005f;
        cfg.incremental_mark_finish_fraction = 0.0009;   // already exceeded at t0
        cfg.validate();
        auto& a = initAllocator(cfg);
        Root keep(a, oldInt(a, 8));
#if ENABLE_GC_STATS
        const uint64_t p0 = im(a).finish_pressure;
#endif
        if (!OA::cycleActive(og(a))) startCycle(a);
        a.minorGC();                                  // first step: pressure finish
#if ENABLE_GC_STATS
        TEST_ASSERT(im(a).finish_pressure > p0);
#endif
        TEST_ASSERT(intValue(a, keep.h) == 8);
    });

Testing::TestCase testIncrResetMidCycle(
    "threaded-gc-05a: an allocator reset mid-cycle drops the cycle",
    []() {
        HeapConfig cfg = incrConfig(6);
        {
            auto& a = initAllocator(cfg);
            Root s(a, bigString(5000, 'r'));
            startCycle(a);
            s.h = alloc::listNil();
            a.minorGC();
            TEST_ASSERT(OA::cycleActive(og(a)));
        }
        auto& a = initAllocator(cfg);
        TEST_ASSERT(!OA::cycleActive(og(a)));
        TEST_ASSERT(OA::deferredFrees(og(a)) == 0);
        Root k(a, oldInt(a, 3));
        startCycle(a);
        runToHandoff(a);
        TEST_ASSERT(intValue(a, k.h) == 3);
    });

// ============================================================================
// Step 7: negative controls. Each removes one piece of the protocol; in a
// validate build the matching validator must abort, otherwise the resulting
// hole must be observable (the object is left unmarked).
// ============================================================================

namespace {
bool expectHole(const std::function<int()>& scenario) {
#if defined(_WIN32)
    (void)scenario;
    return true;
#else
    const int st = runInChild(scenario);
#if ECO_HEAP_VALIDATE
    return WIFSIGNALED(st);                        // IM1 / IM4 abort
#else
    return WIFEXITED(st) && WEXITSTATUS(st) == 0;  // hole observed
#endif
#endif
}
}  // namespace

Testing::TestCase testIncrNegativeSkipYoungWalk(
    "threaded-gc-05a: negative control — no young walk at t0 loses an object",
    []() {
        TEST_ASSERT(expectHole([]() -> int {
            auto& a = initAllocator(incrConfig(4));
            HPointer o = oldInt(a, 1);
            void* o_ptr = a.resolve(o);
            Root x(a, tupleOf(o, o));
            tlh(a)->test_snapshot_skip_young_walk_ = true;
            startCycle(a);
            tlh(a)->test_snapshot_skip_young_walk_ = false;
            runToHandoffDue(a);
            const bool m = marked(a, o_ptr);
            runToHandoff(a);                          // IM1 aborts here (validate)
            return m ? 1 : 0;
        }));
    });

Testing::TestCase testIncrNegativeSkipExternal(
    "threaded-gc-05a: negative control — no external roots at t0 loses an object",
    []() {
        TEST_ASSERT(expectHole([]() -> int {
            auto& a = initAllocator(incrConfig(4));
            g_test_store.assign(1, bitsOf(alloc::listNil()));
            registerTestStore(a);
            g_test_store[0] = bitsOf(oldInt(a, 2));
            void* o_ptr = a.resolve(hpOf(g_test_store[0]));
            tlh(a)->test_snapshot_skip_external_ = true;
            startCycle(a);
            tlh(a)->test_snapshot_skip_external_ = false;
            Root n(a, tupleOf(hpOf(g_test_store[0]), hpOf(g_test_store[0])));
            g_test_store[0] = bitsOf(alloc::listNil());
            runToHandoffDue(a);
            const bool m = marked(a, o_ptr);
            runToHandoff(a);                          // IM1 aborts here (validate)
            return m ? 1 : 0;
        }));
    });

Testing::TestCase testIncrNegativeSkipAllocateBlack(
    "threaded-gc-05a: negative control — no allocate-black leaves promotions white",
    []() {
        TEST_ASSERT(expectHole([]() -> int {
            auto& a = initAllocator(incrConfig(8));
            Root seed(a, oldInt(a, 1));
            startCycle(a);
            OA::setSkipAllocateBlack(og(a), true);
            Root x(a, alloc::allocInt(99));
            a.minorGC();
            a.minorGC();                              // promoted (IM4 aborts here)
            void* p = a.resolve(x.h);
            OA::setSkipAllocateBlack(og(a), false);
            return (!a.isInNursery(p) && !marked(a, p)) ? 0 : 1;
        }));
    });
