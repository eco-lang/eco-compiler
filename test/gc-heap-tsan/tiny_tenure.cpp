// M5 trace validation (b): the pause projection on the real allocator
// (plans/threaded-gc-tla-M5-tenuring.md §9; test/tla/M5-tenuring/TraceTenurePause.tla;
// test/tla/README.md, "Trace validation"). TLA+ trace builds only
// (gc-heap-trace tenure <seed> ...).
//
// The region nursery (k = 1, tenure mode 2, one exact collector, help on, no
// incremental marking, so no cycle ever starts), and at most 8 objects built
// through the real allocator. Object n is a Tuple2 (a = its one pointer field,
// or the unit constant for Nil; b = the unboxed Int kIdBase + n), exactly as in
// tiny_graph.cpp. The driver owns two RootSet roots (the model's roots 1 and 2)
// and runs the model's mutator operations (alloc, load, drop, logged in the
// model's vocabulary), explicit minors and STW majors, and pauses between its
// operations so that the tenure collector (started up to jitter us late) runs
// during the epoch, finishes before the next pause or is stopped and helped.
//
// Recorded: the driver's operations; the runtime's minor / major events (M1's
// hooks in ThreadLocalHeap.cpp); the tenure job's launch, help and merge
// (NurseryTenure.cpp: tj.launch, tj.help, tj.merge); a STW major's zap of the
// dead Young survivors (NurseryRegion.cpp: mzap, HEAP_074); the tenure gang's start,
// exit and join (GCHelperPool.cpp); and after every collection the roots (the
// id each holds and whether it is old) and the reachable ids. The engine's own
// events (TenureWork.hpp) are not recorded here: the storm (gc-tenure-trace) checks
// them one by one; here the model's engine steps are hidden.
//
//   gc-heap-trace tenure <seed> [steps [jitter_us [major %]]]
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
#include <thread>
#include <vector>
using namespace Elm;
namespace {
constexpr int kMaxId = 8;
constexpr int64_t kIdBase = 0x7E11000;   // tags the driver's objects
constexpr int kEdenOps = 1;              // allocations per epoch at most (the model's EC)
const char* const kRootName[2] = {"r1", "r2"};

[[noreturn]] void fail(const char* what, int n = -1) {
    std::fprintf(stderr, "tiny_tenure FAIL: %s %d\n", what, n);
    std::exit(1);
}

struct TinyTenure {
    Allocator& a;
    HPointer root[2];
    std::mt19937_64 rng;
    int next_id = 1;
    int fld[kMaxId + 1] = {};

    TinyTenure(Allocator& al, uint64_t seed) : a(al), rng(seed) {
        root[0] = root[1] = alloc::unit();
        a.getRootSet().addRoot(&root[0]);
        a.getRootSet().addRoot(&root[1]);
    }
    ~TinyTenure() {
        a.getRootSet().removeRoot(&root[0]);
        a.getRootSet().removeRoot(&root[1]);
    }
    static bool isNil(HPointer p) { return p.ptr_ind != 0; }
    int idOf(HPointer p) {
        if (isNil(p)) return 0;
        void* o = a.resolve(p);
        if (o == nullptr) fail("a slot resolves to nothing");
        const Header* h = getHeader(o);
        if (h->tag != Tag_Tuple2 || tupleFieldKind(h->unboxed, 1) != 1) fail("not the driver's object");
        const int64_t v = static_cast<const Tuple2*>(o)->b.i - kIdBase;
        if (v < 1 || v > kMaxId) fail("not the driver's id");
        return static_cast<int>(v);
    }
    HPointer fieldOf(HPointer p) { return static_cast<Tuple2*>(a.resolve(p))->a.p; }

    // ---- the model's mutator operations ----------------------------------------
    void opLoad(int r, int r2) {
        root[r] = fieldOf(root[r2]);
        ECO_TLA_TRACE("load", "r", kRootName[r], "r2", kRootName[r2], "v", idOf(root[r]));
    }
    void opDrop(int r) {
        root[r] = alloc::unit();
        ECO_TLA_TRACE("drop", "r", kRootName[r]);
    }
    void opAlloc(int r, int rv) {   // rv < 0: a Nil field
        const int id = next_id++;
        HPointer field = rv < 0 ? alloc::unit() : root[rv];
        const int fid = idOf(field);
        root[r] = alloc::tuple2(alloc::boxed(field), alloc::unboxedInt(kIdBase + id), 0x4);
        fld[id] = fid;
        ECO_TLA_TRACE("alloc", "o", id, "r", kRootName[r], "v", fid);
    }
    // ---- what the real heap says, after a collection -----------------------------
    void logHeap() {
        int64_t reach = 0;
        std::vector<HPointer> todo = {root[0], root[1]};
        while (!todo.empty()) {
            HPointer p = todo.back();
            todo.pop_back();
            if (isNil(p)) continue;
            const int id = idOf(p);
            if (idOf(fieldOf(p)) != fld[id]) fail("an object's field changed", id);
            if (reach & (int64_t{1} << id)) continue;
            reach |= int64_t{1} << id;
            todo.push_back(fieldOf(p));
        }
        auto old = [&](int r) { return !isNil(root[r]) && !a.isInNursery(a.resolve(root[r])); };
        ECO_TLA_TRACE("troots", "v1", idOf(root[0]), "old1", old(0), "v2", idOf(root[1]), "old2", old(1),
                      "reach", reach);
    }
};
}  // namespace

int tinyTenureMain(int argc, char** argv) {
    const uint64_t seed = argc > 1 ? std::strtoull(argv[1], nullptr, 10) : 1;
    const int steps = argc > 2 ? std::atoi(argv[2]) : 30;
    const char* jitter = argc > 3 ? argv[3] : "300";
    const unsigned major_pct = argc > 4 ? static_cast<unsigned>(std::atoi(argv[4])) : 10;
    // The tenure collector starts a random delay of up to jitter us late, so
    // some jobs are finished at the next pause and others are stopped and helped.
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
    cfg.incremental_mark = false;   // no cycles: a STW major only when the driver asks
    cfg.gc_mark_threads = 1;
    cfg.conc_mark = 0;
    cfg.nursery_regions = 1;
    cfg.tenure_mode = 2;
    cfg.tenure_collector_threads = 1;
    cfg.tenure_help = 1;
    cfg.tenure_help_threads = 0;
    cfg.promotion_age = 1;
    cfg.validate();
    auto& a = Allocator::instance();
    a.initialize(cfg);
    AllocatorTestAccess::reset(a, &cfg);
    a.initThread();

    TinyTenure t(a, seed);
    char hdr[256];
    std::snprintf(hdr, sizeof hdr,
                  "{\"harness\":\"gc-heap-trace\",\"kind\":\"tenure\",\"seed\":%llu,\"maxid\":%d,\"ec\":%d}",
                  static_cast<unsigned long long>(seed), kMaxId, kEdenOps);
    tlatrace::begin(hdr, "alloc,load,drop,minor,major,mzap,tj.,gang.start,gang.exit,gang.join,troots");

    // At most kEdenOps allocations between two minors (a STW major leaves eden
    // as it is), early in the run, so that a new object often points at one
    // copied at the last minor (a heal slot at the next).
    const int alloc_every = 1;
    int allocs = 0;
    for (int step = 0; step < steps; ++step) {
        const int nops = 1 + static_cast<int>(t.rng() % 3);
        for (int k = 0; k < nops; ++k) {
            const int r = static_cast<int>(t.rng() % 2);
            const unsigned op = static_cast<unsigned>(t.rng() % 20);
            if (op < 6) {
                if (!TinyTenure::isNil(t.root[1 - r])) t.opLoad(r, 1 - r);
            } else if (op < 7) {
                if (!TinyTenure::isNil(t.root[r])) t.opDrop(r);
            } else if (t.next_id <= kMaxId && allocs < kEdenOps && step >= (t.next_id - 1) * alloc_every) {
                const unsigned f = static_cast<unsigned>(t.rng() % 4);   // mostly a chain
                t.opAlloc(r, f == 0 ? -1 : f == 1 ? 1 - r : r);
                ++allocs;
            }
            std::this_thread::sleep_for(std::chrono::microseconds(t.rng() % 400));
        }
        if (t.rng() % 100 < major_pct) {
            a.majorGC();
        } else {
            a.minorGC();
            allocs = 0;
        }
        t.logHeap();
    }
    if (!tlatrace::end(nullptr)) fail("writing the trace");
    std::printf("tiny_tenure seed %llu: %d ids, PASS\n", static_cast<unsigned long long>(seed), t.next_id - 1);
    return 0;
}

#else
int tinyTenureMain(int, char**) { return 2; }
#endif
