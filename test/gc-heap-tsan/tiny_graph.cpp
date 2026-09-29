// M1 trace validation (b): the tiny-graph driver
// (plans/threaded-gc-tla-M1-snapshot-mark.md §8 (b); test/tla/README.md,
// "Trace validation"). TLA+ trace builds only (gc-heap-trace tiny <seed> ...).
//
// At most 8 objects, built through the real allocator with concurrent marking
// on. Object n is a Tuple2 (a = its one pointer field, or the unit constant
// for Nil; b = the unboxed Int kIdBase + n), so every hook reads an object's
// model id straight from the object (Elm::tlatrace::setObjId): no address
// table is needed, and addresses may change at every minor. The driver owns
// every root: two RootSet slots (the model's r1, r2) and one external root
// scanner slot (the model's off-heap store c1). It never reuses an id.
//
// It logs its own operations, in the model's vocabulary (load, drop, cellw,
// cellr, alloc), and after every collection a "heap" event: which ids are
// allocated and old, and which are allocated and young, as the real heap
// says. The runtime hooks log the cycle (minor, t0, step, reap, assist,
// closing, handoff, major, stop, ...), every grey (a newly set mark bit) and
// every scan, and the gangs' launch / start / exit / join events that order
// the markers' threads against the mutator. TraceHeap.tla replays the log
// against M1's Next.
//
//   gc-heap-trace tiny <seed> [steps [bg [T [jitter_us]]]]
#include "Allocator.hpp"
#include "HeapHelpers.hpp"
#include "OldGenSpace.hpp"
#include "RootSet.hpp"
#include "ThreadLocalHeap.hpp"
#include "TlaTrace.hpp"

#if ECO_TLA_TRACE_ENABLED
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
#include <vector>

using namespace Elm;

namespace {

constexpr int kMaxId = 8;
constexpr int64_t kIdBase = 0x7A11000;   // tags the driver's objects
const char* const kRootName[2] = {"r1", "r2"};

[[noreturn]] void fail(const char* what, int n = -1) {
    std::fprintf(stderr, "tiny_graph FAIL: %s %d\n", what, n);
    std::exit(1);
}

int64_t idOfObject(const void* p) {
    const Header* h = reinterpret_cast<const Header*>(p);
    if (h->tag != Tag_Tuple2 || tupleFieldKind(h->unboxed, 1) != 1) return -1;
    const int64_t v = static_cast<const Tuple2*>(p)->b.i - kIdBase;
    return (v >= 1 && v <= kMaxId) ? v : -1;
}

uint64_t g_cell = 0;   // the off-heap store c1 (an encoded HPointer), scanned as an external root

struct Tiny {
    Allocator& a;
    ThreadLocalHeap* h;
    HPointer root[2];
    std::mt19937_64 rng;
    int next_id = 1;
    // The driver's shadow of the graph: the field of each id (0 = Nil) and
    // what it last saw of it.
    int fld[kMaxId + 1] = {};
    bool live[kMaxId + 1] = {};        // allocated, as far as the driver knows
    void* where_[kMaxId + 1] = {};     // last address (stable while old)
    bool old[kMaxId + 1] = {};

    Tiny(Allocator& al, ThreadLocalHeap* hp, uint64_t seed) : a(al), h(hp), rng(seed) {
        root[0] = root[1] = alloc::unit();
        a.getRootSet().addRoot(&root[0]);
        a.getRootSet().addRoot(&root[1]);
    }
    ~Tiny() {
        a.getRootSet().removeRoot(&root[0]);
        a.getRootSet().removeRoot(&root[1]);
    }

    static bool isNil(HPointer p) { return p.ptr_ind != 0; }
    HPointer cell() const { HPointer p; std::memcpy(&p, &g_cell, sizeof p); return p; }
    void setCell(HPointer p) { std::memcpy(&g_cell, &p, sizeof p); }
    int idOf(HPointer p) {
        if (isNil(p)) return 0;
        void* o = a.resolve(p);
        const int64_t id = o ? idOfObject(o) : -1;
        if (id < 1) fail("a slot holds an object that is not the driver's");
        return static_cast<int>(id);
    }
    HPointer fieldOf(HPointer p) {
        Tuple2* t = static_cast<Tuple2*>(a.resolve(p));
        return t->a.p;
    }
    HPointer make(int id, HPointer field) {
        return alloc::tuple2(alloc::boxed(field), alloc::unboxedInt(kIdBase + id), 0x4);
    }

    // ---- the model's mutator operations --------------------------------------------
    void opLoad(int r, int r2) {
        root[r] = fieldOf(root[r2]);
        ECO_TLA_TRACE("load", "r", kRootName[r], "r2", kRootName[r2], "v", idOf(root[r]));
    }
    void opDrop(int r) {
        root[r] = alloc::unit();
        ECO_TLA_TRACE("drop", "r", kRootName[r]);
    }
    void opCellW(int r) {
        setCell(root[r]);
        ECO_TLA_TRACE("cellw", "c", "c1", "r", kRootName[r], "v", idOf(cell()));
    }
    void opCellR(int r) {
        root[r] = cell();
        ECO_TLA_TRACE("cellr", "r", kRootName[r], "c", "c1", "v", idOf(root[r]));
    }
    void opAlloc(int r, int rv) {   // rv < 0: a Nil field
        const int id = next_id++;
        HPointer field = rv < 0 ? alloc::unit() : root[rv];
        const int fid = idOf(field);
        root[r] = make(id, field);
        fld[id] = fid;
        live[id] = true;
        ECO_TLA_TRACE("alloc", "o", id, "r", kRootName[r], "v", fid);
    }

    // ---- what the real heap says ----------------------------------------------------
    // Reachable ids (roots, the store, then fields), and the address of each.
    void reach(std::vector<int>& ids) {
        ids.clear();
        std::vector<HPointer> todo = {root[0], root[1], cell()};
        while (!todo.empty()) {
            HPointer p = todo.back();
            todo.pop_back();
            if (isNil(p)) continue;
            const int id = idOf(p);
            if (std::find(ids.begin(), ids.end(), id) != ids.end()) continue;
            ids.push_back(id);
            void* o = a.resolve(p);
            where_[id] = o;
            old[id] = !a.isInNursery(o);
            if (idOf(fieldOf(p)) != fld[id]) fail("an object's field changed", id);
            todo.push_back(fieldOf(p));
        }
    }
    // The "tail" probe (OldGenSpace::runPostMarkTail, inside the pause): the
    // marks are the liveness decision of a handoff or a STW major. Log which of
    // the allocated old ids are marked; the tail frees the others.
    void probe(const char* where) {
        std::vector<int> ids;
        reach(ids);                    // addresses after this pause's minor (promotions)
        int64_t marked = 0;
        for (int id = 1; id < next_id; ++id) {
            if (!live[id] || !old[id]) continue;
            if (idOfObject(where_[id]) != id) fail("an allocated old object was overwritten", id);
            if (OldGenSpaceTestAccess::isMarked(h->getOldGen(), where_[id])) marked |= int64_t{1} << id;
            else live[id] = false;
        }
        ECO_TLA_TRACE("marks", "where", where, "marked", marked);
    }
    // After a collection: which ids are allocated. A reachable id is. An
    // unreachable young id is gone after a minor (it copies only what is
    // reachable), not after a STW major (it moves nothing). An unreachable old
    // id stays until a tail (above) finds it unmarked.
    void logHeap(bool minor) {
        std::vector<int> ids;
        reach(ids);
        const bool cyc = OldGenSpaceTestAccess::cycleActive(h->getOldGen());
        int64_t olds = 0, youngs = 0;       // sets of ids as bitmasks (bit n = id n)
        for (int id = 1; id < next_id; ++id) {
            if (!live[id]) continue;
            const bool reachable = std::find(ids.begin(), ids.end(), id) != ids.end();
            if (!reachable && !old[id] && minor) live[id] = false;
            if (!live[id]) continue;
            (old[id] ? olds : youngs) |= int64_t{1} << id;
        }
        ECO_TLA_TRACE("heap", "old", olds, "young", youngs, "cyc", cyc);
    }
};

Tiny* g_tiny = nullptr;
void onProbe(const char* where) {
    if (g_tiny != nullptr) g_tiny->probe(where);
}

void forkNow() {
    const pid_t pid = fork();
    if (pid < 0) fail("fork");
    if (pid == 0) _exit(0);
    int st = 0;
    if (waitpid(pid, &st, 0) != pid || !WIFEXITED(st) || WEXITSTATUS(st) != 0) fail("fork child");
}

}  // namespace

int tinyGraphMain(int argc, char** argv) {
    const uint64_t seed = argc > 1 ? std::strtoull(argv[1], nullptr, 10) : 1;
    const int steps = argc > 2 ? std::atoi(argv[2]) : 40;
    const unsigned bg = argc > 3 ? static_cast<unsigned>(std::atoi(argv[3])) : 2;
    const unsigned T = argc > 4 ? static_cast<unsigned>(std::atoi(argv[4])) : 2;
    const char* jitter = argc > 5 ? argv[5] : "300";
    // Background members start late (a random delay of up to jitter us), so
    // mutator operations and minors interleave with their scans.
    setenv("ECO_GC_HELPER_JITTER_US", jitter, 1);

    HeapConfig cfg;
    cfg.alloc_buffer_size = 32 * 1024;
    cfg.nursery_block_count = 8;
    cfg.nursery_max_block_count = 8;
    cfg.gc_minor_threads = 1;
    cfg.initial_old_gen_size = 256 * 1024;
    cfg.max_heap_size = 64ULL << 20;
    cfg.large_object_threshold = 8 * 1024;
    cfg.decommit_on_oldgen_release = false;
    cfg.gc_thread_mode = 0;
    cfg.incremental_mark = true;
    cfg.incremental_mark_slices = T;
    cfg.incremental_mark_min_slice_units = 1;
    cfg.gc_mark_threads = 2;
    cfg.conc_mark = 2;
    cfg.conc_mark_threads = bg;
    cfg.conc_mark_priority = 0;
    cfg.conc_mark_assist_lag = 1;
    cfg.nursery_regions = 0;
    cfg.promotion_age = 1;
    cfg.validate();
    auto& a = Allocator::instance();
    a.initialize(cfg);
    AllocatorTestAccess::reset(a, &cfg);
    a.initThread();
    ThreadLocalHeap* h = AllocatorTestAccess::getThreadHeap(a);
    tlatrace::setObjId(&idOfObject);
    g_cell = 0;
    {
        HPointer nil = alloc::unit();
        std::memcpy(&g_cell, &nil, sizeof nil);
    }
    a.getRootSet().addExternalRootScanner(
        [](RootSet::EvacuateFn f) { f(g_cell); }, "tla-tiny-cell");

    Tiny t(a, h, seed);
    g_tiny = &t;
    tlatrace::setProbe(&onProbe);
    // The starting heap, the shape of M1's MC.tla up to renaming: old 2 -> 1
    // and 3, young 4 -> 3; r1 -> 2, r2 -> 4; c1 empty. (Recording has not
    // begun, so these operations are not logged; the header describes them.)
    t.opAlloc(1, -1);                 // 1 (a Nil field), in r2
    t.opAlloc(0, 1);                  // 2 -> 1, in r1
    t.opAlloc(1, -1);                 // 3 (a Nil field), in r2
    a.minorGC();
    a.minorGC();                      // 1, 2, 3 promoted (promotion_age 1)
    t.opAlloc(1, 1);                  // 4 -> 3, young, in r2
    std::vector<int> ids;
    t.reach(ids);
    for (int id = 1; id <= 3; ++id)
        if (!t.old[id]) fail("setup: not promoted", id);
    if (t.old[4] || OldGenSpaceTestAccess::cycleActive(h->getOldGen())) fail("setup");

    char hdr[512];
    std::snprintf(hdr, sizeof hdr,
                  "{\"harness\":\"gc-heap-trace\",\"kind\":\"tiny\",\"seed\":%llu,\"T\":%u,\"bg\":%u,"
                  "\"maxid\":%d,\"init\":{\"alloc\":[1,2,3,4],\"old\":[1,2,3],"
                  "\"fld\":[[1,%d],[2,%d],[3,%d],[4,%d]],\"root\":{\"r1\":%d,\"r2\":%d},\"cell\":{\"c1\":0}}}",
                  static_cast<unsigned long long>(seed), T, bg, kMaxId, t.fld[1], t.fld[2], t.fld[3],
                  t.fld[4], t.idOf(t.root[0]), t.idOf(t.root[1]));
    tlatrace::begin(hdr, "");

    auto cycleOn = [&] { return OldGenSpaceTestAccess::cycleActive(h->getOldGen()); };
    auto bgRunning = [&] {
        gc::GCBackgroundGang* g = OldGenSpaceTestAccess::bgGang(h->getOldGen());
        return g != nullptr && g->running();
    };
    // Allocations are spread over the run (ids are never reused); the mutator
    // pauses a little after its operations, so that the background members
    // (started up to jitter us late) scan while it runs.
    const int alloc_every = std::max(1, steps / (2 * (kMaxId - 4) + 1));
    for (int step = 0; step < steps; ++step) {
        const int nops = 1 + static_cast<int>(t.rng() % 3);
        for (int k = 0; k < nops; ++k) {
            const int r = static_cast<int>(t.rng() % 2);
            const unsigned op = static_cast<unsigned>(t.rng() % 20);
            if (op < 6) {
                if (!Tiny::isNil(t.root[1 - r])) t.opLoad(r, 1 - r);
            } else if (op < 7) {
                t.opDrop(r);
            } else if (op < 10) {
                t.opCellW(r);
            } else if (op < 13) {
                t.opCellR(r);
            } else if (t.next_id <= kMaxId && step >= (t.next_id - 4) * alloc_every) {
                // mostly a chain: the new object points at what its root held
                const unsigned f = static_cast<unsigned>(t.rng() % 4);
                t.opAlloc(r, f == 0 ? -1 : f == 1 ? 1 - r : r);
            }
            std::this_thread::sleep_for(std::chrono::microseconds(t.rng() % 200));
        }
        const unsigned pick = static_cast<unsigned>(t.rng() % 12);
        if (!cycleOn() && pick < 5) h->test_force_major_trigger_ = true;
        if (cycleOn() && bgRunning() && pick >= 9) forkNow();   // a fork stop
        if (pick == 8) a.majorGC();
        else a.minorGC();
        t.logHeap(pick != 8);
    }
    while (cycleOn()) {
        a.minorGC();
        t.logHeap(true);
    }
    if (!tlatrace::end(nullptr)) fail("writing the trace");
    tlatrace::setProbe(nullptr);
    g_tiny = nullptr;
    std::printf("tiny_graph seed %llu: %d ids, PASS\n", static_cast<unsigned long long>(seed), t.next_id - 1);
    return 0;
}

#else
int tinyGraphMain(int, char**) { return 2; }
#endif
