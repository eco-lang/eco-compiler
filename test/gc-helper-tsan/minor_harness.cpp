// threaded-gc-06 (plans/threaded-gc-06-parallel-minor.md Step 3): the TSan
// harness for the parallel minor GC's std-only core -- the claim/publish header
// protocol and the LAB allocator of MinorWork.hpp -- driven by the REAL
// markwork::runMarkerLoop (MarkWork.hpp) on GCMarkGang, over a synthetic heap.
//
// Synthetic objects (8-byte words):
//   header: tag (bits 0..4: 1 node, 2 cons, 3 filler, 26 forward/busy),
//           age (bit 8), nslots / filler bytes (bits 32..63);
//   word 1: id;  words 2..: slots.
// A slot is 0 (null), odd (a constant), or the address of an object in the
// from-space, the "old" region, or (after the GC) to-space / old copies.
// Objects with age 1 are "promoted" into an old arena through a mutex (the
// promotion ladder's shape); others go to to-space LABs. Cons chains are
// copied in runs of kSpineRun with a count-based heads pass; nodes with more
// than kChunk slots are scanned in chunk entries.
//
// Young large objects (YLOS, HEAP_062; reachYoungLargeP's shape): nodes in a
// separate "ylos" region, never copied. The first worker to reach one this
// minor tests and sets its reached flag under ylos_mu, and in the same
// critical section promotes it in place (age 1 -> 0) or ages it (0 -> 1); after
// unlocking it pushes the object, which is then scanned in place. Other
// reachers see the flag and do nothing. (CR-020: before this kind, no TSan
// harness ran the parallel YLOS reach with more than one worker.)
//
// Checks per heap: (a) every reachable object copied exactly once, nothing
// else copied, every reachable YLOS reached exactly once; (b) no slot of a
// copy, a YLOS or a root points into from-space, and every copy's (and YLOS's)
// children are the copies of the original's children; (c) no BUSY word left;
// (d) to-space parses (objects + fillers) up to the top and the fillers sum to
// the reported waste; (e) no TSan report.
//
// Build: see CMakeLists.txt. Pass: "minor_harness PASS", exit 0, no TSan report.
//
// Tiny mode, `minor_harness tiny <seed> <workers> <spine run> <pace us>`: one
// heap of about eight objects in the shape of M3's example heap
// (test/tla/M3-minor-forwarding/MC.tla; seed 0 is that heap exactly, other
// seeds are random heaps of the same kind), with random pauses of up to <pace
// us> at the protocol points so that the workers interleave. In the TRACE
// build (gc-minor-trace, -DECO_TLA_TRACE=1) it records the TLA+ trace that
// TraceMinorForwarding.tla replays (plans/threaded-gc-tla-M3-minor-forwarding.md
// §9): the header words' events come from MinorWork.hpp's hooks (claim,
// publish, wait), the rest from this file (load, copy, slot, link, trunc,
// heads, scan, ylos, ypush); object ids are the model's (a copy is 100 * k + id,
// k its copy number).

#include "GCHelperPool.hpp"
#include "MarkWork.hpp"
#include "MinorWork.hpp"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <sys/mman.h>
#include <random>
#include <thread>
#include <unordered_map>
#include <vector>

using namespace Elm;
using namespace Elm::markwork;
namespace mw = Elm::minorwork;
#if ECO_TLA_TRACE_ENABLED
namespace tlatrace = Elm::tlatrace;
#endif

static void fail(const char* what, uint64_t a = 0, uint64_t b = 0) {
    std::fprintf(stderr, "minor_harness FAIL: %s (%llu, %llu)\n", what,
                 (unsigned long long)a, (unsigned long long)b);
    std::exit(1);
}

namespace {

constexpr uint64_t kNode = 1, kCons = 2, kFill = 3;
constexpr size_t kSpineRun = 512;
constexpr uint32_t kChunk = 1024;
constexpr uint64_t kAgeBit = 1ull << 8;

inline uint64_t mkHeader(uint64_t tag, bool age, uint64_t n) {
    return tag | (age ? (1ull << 8) : 0) | (n << 32);
}
inline uint64_t hTag(uint64_t h) { return h & 31; }
inline bool hAge(uint64_t h) { return (h >> 8) & 1; }
inline uint64_t hN(uint64_t h) { return h >> 32; }
inline size_t objWords(uint64_t h) {
    switch (hTag(h)) {
        case kNode: return 2 + hN(h);
        case kCons: return 4;
        case kFill: return hN(h) / 8;
        default: fail("objWords: bad tag", hTag(h)); return 0;
    }
}

// Regions are mapped below 2^43: mark entries and forward words carry
// addr >> 3 in 40 bits, exactly as for the real heap (whose reservation sits
// low). TSan's allocator returns higher addresses, so std::vector will not do.
struct Words {
    uint64_t* p = nullptr;
    size_t n = 0;
    uint64_t* data() { return p; }
    const uint64_t* data() const { return p; }
    size_t size() const { return n; }
    uint64_t& operator[](size_t i) { return p[i]; }
    void assign(size_t count, uint64_t v) {
        static uintptr_t next_hint = 0x1000000000ull;   // 64 GiB: TSan low app range
        if (p == nullptr) {
            void* m = MAP_FAILED;
            for (int tries = 0; tries < 64 && m == MAP_FAILED; ++tries) {
                m = mmap(reinterpret_cast<void*>(next_hint), count * 8, PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
                next_hint += (count * 8 + 0xFFFFFF) & ~static_cast<uintptr_t>(0xFFFFFF);
            }
            if (m == MAP_FAILED) fail("mmap below 2^43 failed");
            p = static_cast<uint64_t*>(m);
            n = count;
        }
        if (count != n) fail("Words: resize not supported");
        for (size_t i = 0; i < n; ++i) p[i] = v;
    }
};

struct Region {
    Words words;
    char* base() { return reinterpret_cast<char*>(words.data()); }
    bool contains(const void* p) const {
        const char* c = static_cast<const char*>(p);
        const char* b = reinterpret_cast<const char*>(words.data());
        return c >= b && c < b + words.size() * 8;
    }
};

struct Heap {
    Region from, to, old, ylos;
    std::vector<uint64_t> roots;
    size_t from_used = 0;       // words
    size_t ylos_used = 0;       // words
    uint64_t n_objects = 0;
    // promotion arena (the heap's SpinMutex, TSan-tested here)
    mw::SpinMutex promo_mu;
    size_t old_used = 0;        // words (guarded by promo_mu)
    // young large objects: the reached flag ("colour") per object start, and
    // the in-place promotion / ageing of the header, under ylos_mu
    std::mutex ylos_mu;
    std::vector<uint8_t> ylos_reached;   // by word offset in the ylos region
    int64_t ylos_tick = 0;               // trace builds: the ylos_mu clock
};

// Pauses of up to g_pace_us microseconds at the protocol points (tiny mode),
// so that a heap of eight objects still sees the workers interleave.
unsigned g_pace_us = 0;
void pace() {
    if (g_pace_us == 0) return;
    thread_local std::mt19937 rng(static_cast<unsigned>(
        std::hash<std::thread::id>()(std::this_thread::get_id())));
    const unsigned us = rng() % (g_pace_us + 1);
    if (us < g_pace_us / 4) std::this_thread::yield();
    else std::this_thread::sleep_for(std::chrono::microseconds(us));
}

#if ECO_TLA_TRACE_ENABLED
// The model's ids (tlatrace::obj): an original or a YLOS object logs its id
// (word 1), the pre-existing old object too; a copy logs 100 * k + id, k its
// copy number (so a second copy of an object would log 200 + id).
Heap* g_trace_heap = nullptr;
std::mutex g_copy_mu;
std::unordered_map<const void*, int64_t> g_copy_id;
std::unordered_map<int64_t, int64_t> g_copy_count;

int64_t noteCopy(const uint64_t* obj, const void* dst) {
    std::lock_guard<std::mutex> g(g_copy_mu);
    const int64_t id = static_cast<int64_t>(obj[1]);
    const int64_t k = ++g_copy_count[id];
    return g_copy_id[dst] = 100 * k + id;
}

int64_t traceObjId(const void* p) {
    Heap& h = *g_trace_heap;
    if (h.from.contains(p) || h.ylos.contains(p)) return static_cast<int64_t>(static_cast<const uint64_t*>(p)[1]);
    if (h.to.contains(p) || h.old.contains(p)) {
        std::lock_guard<std::mutex> g(g_copy_mu);
        auto it = g_copy_id.find(p);
        if (it != g_copy_id.end()) return it->second;
        if (p == h.old.words.data()) return static_cast<int64_t>(static_cast<const uint64_t*>(p)[1]);
    }
    return -1;
}
#endif

// A header load at a call site (loadHeader itself is not hooked: waitPublished
// spins on it). "w": 0 unforwarded, 1 BUSY, 2 forwarded to "to".
inline void traceLoad(uint64_t* obj, uint64_t hw) {
    ECO_TLA_TRACE("load", "obj", tlatrace::obj(obj), "rd", tlatrace::key("h", obj),
                  "val", tlatrace::key("W", static_cast<int64_t>(hw)), "w", mw::tlaWordKind(hw),
                  "to", tlatrace::obj(mw::tlaFwdTo(hw)));
    (void)obj;
    (void)hw;
}

uint64_t* allocFrom(Heap& h, size_t words) {
    if (h.from_used + words > h.from.words.size()) fail("from-space full");
    uint64_t* p = h.from.words.data() + h.from_used;
    h.from_used += words;
    return p;
}

// Builds a random heap in from-space. Returns the reachable-object count.
uint64_t* allocYlos(Heap& h, size_t words) {
    if (h.ylos_used + words > h.ylos.words.size()) fail("ylos region full");
    uint64_t* p = h.ylos.words.data() + h.ylos_used;
    h.ylos_used += words;
    return p;
}

void resetHeap(Heap& h, size_t words) {
    h.from.words.assign(words, 0);
    h.to.words.assign(words, 0);
    h.old.words.assign(words, 0);
    h.ylos.words.assign(words / 8, 0);
    h.ylos_reached.assign(words / 8, 0);
    h.from_used = 0;
    h.ylos_used = 0;
    h.old_used = 0;
    h.ylos_tick = 0;
    h.n_objects = 0;
    h.roots.clear();
}

void buildHeap(Heap& h, std::mt19937_64& rng) {
    resetHeap(h, 1 << 21);                    // 16 MiB per region
    std::vector<uint64_t*> objs;
    std::vector<uint64_t*> ylos;
    auto rnd = [&](uint64_t n) { return n ? rng() % n : 0; };
    const size_t n_nodes = 20000 + rnd(20000);
    for (size_t i = 0; i < n_nodes; ++i) {
        const bool big = rnd(1000) < 3;
        const uint64_t ns = big ? 2000 : rnd(9);
        const bool age = rnd(2) == 0;
        uint64_t* o = allocFrom(h, 2 + ns);
        o[0] = mkHeader(kNode, age, ns);
        o[1] = ++h.n_objects;
        objs.push_back(o);
    }
    // chains: cons cells built tail-first (as a mutator would)
    const size_t n_chains = 20;
    std::vector<uint64_t*> chain_heads;
    for (size_t c = 0; c < n_chains; ++c) {
        const size_t len = c == 0 ? 10000 : 1 + rnd(3000);
        uint64_t tail = 1;   // constant Nil
        const bool age = rnd(2) == 0;
        for (size_t i = 0; i < len; ++i) {
            uint64_t* o = allocFrom(h, 4);
            o[0] = mkHeader(kCons, age, 0);
            o[1] = ++h.n_objects;
            o[2] = 0;
            o[3] = tail;
            tail = reinterpret_cast<uintptr_t>(o);
            objs.push_back(o);
        }
        chain_heads.push_back(reinterpret_cast<uint64_t*>(tail));
    }
    // young large objects: nodes of 1..40 slots, some aged (promoted in place)
    const size_t n_ylos = 20 + rnd(40);
    for (size_t i = 0; i < n_ylos; ++i) {
        const uint64_t ns = 1 + rnd(40);
        uint64_t* o = allocYlos(h, 2 + ns);
        o[0] = mkHeader(kNode, rnd(2) == 0, ns);
        o[1] = ++h.n_objects;
        ylos.push_back(o);
    }
    // shared tails: a few chains end in another chain's middle
    // slots: random targets among all objects (a few YLOS, often shared),
    // some constants, some old
    uint64_t* old_obj = h.old.words.data();          // one pre-existing "old" object
    old_obj[0] = mkHeader(kNode, false, 0);
    old_obj[1] = 0;
    h.old_used = 2;
    auto slotValue = [&]() -> uint64_t {
        const uint64_t r = rnd(20);
        if (r < 11) return reinterpret_cast<uintptr_t>(objs[rnd(objs.size())]);
        if (r < 12) return reinterpret_cast<uintptr_t>(ylos[rnd(ylos.size())]);
        if (r < 16) return (rnd(1000) << 1) | 1;
        if (r < 18) return reinterpret_cast<uintptr_t>(old_obj);
        return 0;
    };
    for (uint64_t* o : ylos)
        for (uint64_t s = 0; s < hN(o[0]); ++s) o[2 + s] = slotValue();
    for (uint64_t* o : objs) {
        if (hTag(o[0]) == kNode) {
            for (uint64_t s = 0; s < hN(o[0]); ++s) o[2 + s] = slotValue();
        } else if (rnd(4) == 0) {
            o[2] = reinterpret_cast<uintptr_t>(objs[rnd(objs.size())]);   // boxed head
        } else {
            o[2] = (rnd(100) << 1) | 1;
        }
    }
    for (size_t c = 1; c < chain_heads.size(); c += 5) {   // splice: shared tails
        uint64_t* p = chain_heads[c];
        while (hTag(p[0]) == kCons && (p[3] & 1) == 0) p = reinterpret_cast<uint64_t*>(p[3]);
        p[3] = reinterpret_cast<uintptr_t>(chain_heads[0]);
    }
    for (int i = 0; i < 200; ++i) h.roots.push_back(reinterpret_cast<uintptr_t>(objs[rnd(objs.size())]));
    for (uint64_t* ch : chain_heads) h.roots.push_back(reinterpret_cast<uintptr_t>(ch));
    for (int i = 0; i < 4; ++i) h.roots.push_back(reinterpret_cast<uintptr_t>(ylos[rnd(ylos.size())]));
    h.roots.push_back(3);       // a constant root
    h.roots.push_back(0);       // a null root
}

// ---------------------------------------------------------------------------
// Tiny heaps (M3's trace): from-space ids 1..nf, one YLOS (id 7), one old
// object (id 9). Seed 0 is MC.tla's heap. Other seeds: objects in allocation
// order (a slot points only at an earlier object, so the heap is acyclic),
// ages non-increasing in allocation order (a promoted parent's children
// promote: PM5's premise), every node with at least one slot.
// ---------------------------------------------------------------------------
struct TinySpec {
    struct Obj { int id; bool cons; bool age; std::vector<int> slots; };   // 0 = a constant
    std::vector<Obj> from;     // ids 1..nf, in id order
    Obj ylos;                  // id 7
    std::vector<int> roots;
};

TinySpec tinySpec(uint64_t seed) {
    TinySpec t;
    if (seed == 0) {
        // MC.tla: 1 = Tuple(2, 7) age 1; 2 = [9] age 1; 3 = Cons(7, 4); 4 = Cons(9, 5);
        // 5 = Cons(2, Nil) age 1; 6 = garbage [3]; YLOS 7 = [5] age 1. Roots <<1, 3>>.
        t.from = {{1, false, true, {2, 7}}, {2, false, true, {9}}, {3, true, false, {7, 4}},
                  {4, true, false, {9, 5}}, {5, true, true, {2, 0}}, {6, false, false, {3}}};
        t.ylos = {7, false, true, {5}};
        t.roots = {1, 3};
        return t;
    }
    std::mt19937_64 rng(seed * 0x9E3779B97F4A7C15ull);
    auto rnd = [&](int n) { return n > 0 ? static_cast<int>(rng() % static_cast<uint64_t>(n)) : 0; };
    const int nf = 5 + rnd(2);                  // 5 or 6
    const int ypos = 1 + rnd(nf - 2);           // the YLOS is allocated after object ypos
    const int c = rnd(nf + 1);                  // objects 1..c have age 1
    t.ylos = {7, false, false, {}};
    for (int i = 1; i <= nf; ++i) {
        TinySpec::Obj o{i, false, i <= c, {}};
        o.cons = i >= 2 && rnd(3) != 0;
        std::vector<int> earlier;
        for (int j = 1; j < i; ++j) earlier.push_back(j);
        auto target = [&]() -> int {
            const int r = rnd(10);
            if (r < 6 && !earlier.empty()) return earlier[static_cast<size_t>(rnd(static_cast<int>(earlier.size())))];
            if (r < 8 && i > ypos) return 7;
            if (r < 9) return 9;
            return 0;
        };
        if (o.cons) {
            std::vector<int> conses;
            for (const auto& p : t.from) if (p.cons) conses.push_back(p.id);
            const int tail = (!conses.empty() && rnd(4) != 0) ? conses[static_cast<size_t>(rnd(static_cast<int>(conses.size())))] : 0;
            o.slots = {target(), tail};
        } else {
            const int ns = 1 + rnd(2);
            for (int s = 0; s < ns; ++s) o.slots.push_back(target());
        }
        t.from.push_back(o);
        if (i == ypos) {                        // the YLOS: 1-2 slots at objects 1..ypos
            const int ns = 1 + rnd(2);
            for (int s = 0; s < ns; ++s) t.ylos.slots.push_back(1 + rnd(ypos));
            bool kids_old = true;
            for (int k : t.ylos.slots) kids_old = kids_old && k <= c;
            t.ylos.age = kids_old && rnd(2) == 0;
        }
    }
    // PM5's premise for the YLOS's parents: a promoted parent needs a promoted YLOS
    if (!t.ylos.age)
        for (auto& o : t.from)
            if (o.age)
                for (int& v : o.slots)
                    if (v == 7) v = 9;
    // roots: the last object and two others (sometimes the YLOS): three root
    // greys, one per worker's deque with three workers
    t.roots = {nf, 1 + rnd(nf - 1), rnd(3) == 0 ? 7 : 1 + rnd(nf - 1)};
    return t;
}

// Builds a tiny heap; returns the trace header (the model's constants).
std::string buildTiny(Heap& h, uint64_t seed, unsigned workers, size_t spine_run) {
    resetHeap(h, 1 << 14);                      // 128 KiB per region
    const TinySpec t = tinySpec(seed);
    uint64_t* old_obj = h.old.words.data();     // old 9
    old_obj[0] = mkHeader(kNode, false, 0);
    old_obj[1] = 9;
    h.old_used = 2;
    std::unordered_map<int, uint64_t*> at;
    at[9] = old_obj;
    for (const auto& o : t.from) {
        uint64_t* p = allocFrom(h, o.cons ? 4 : 2 + o.slots.size());
        p[0] = mkHeader(o.cons ? kCons : kNode, o.age, o.cons ? 0 : o.slots.size());
        p[1] = static_cast<uint64_t>(o.id);
        at[o.id] = p;
    }
    uint64_t* y = allocYlos(h, 2 + t.ylos.slots.size());
    y[0] = mkHeader(kNode, t.ylos.age, t.ylos.slots.size());
    y[1] = 7;
    at[7] = y;
    auto val = [&](int id) -> uint64_t { return id == 0 ? 1 : reinterpret_cast<uintptr_t>(at.at(id)); };
    for (const auto& o : t.from)
        for (size_t s = 0; s < o.slots.size(); ++s) at[o.id][2 + s] = val(o.slots[s]);
    for (size_t s = 0; s < t.ylos.slots.size(); ++s) y[2 + s] = val(t.ylos.slots[s]);
    for (int r : t.roots) h.roots.push_back(val(r));

    auto list = [](const std::vector<int>& v) {
        std::string s = "[";
        for (size_t i = 0; i < v.size(); ++i) s += (i ? "," : "") + std::to_string(v[i]);
        return s + "]";
    };
    std::vector<int> from, cons;
    std::string objs = "[";
    auto addObj = [&](const TinySpec::Obj& o) {
        if (objs.size() > 1) objs += ",";
        objs += "[" + std::to_string(o.id) + "," + (o.age ? "1" : "0") + "," + list(o.slots) + "]";
    };
    for (const auto& o : t.from) {
        from.push_back(o.id);
        if (o.cons) cons.push_back(o.id);
        addObj(o);
    }
    addObj(t.ylos);
    objs += "]";
    return "{\"model\":\"M3\",\"seed\":" + std::to_string(seed) + ",\"workers\":" + std::to_string(workers) +
           ",\"maxrun\":" + std::to_string(spine_run) + ",\"promoage\":1,\"from\":" + list(from) +
           ",\"cons\":" + list(cons) + ",\"ylos\":[7],\"old\":[9],\"objs\":" + objs +
           ",\"roots\":" + list(t.roots) + "}";
}

// ---------------------------------------------------------------------------
// The parallel copier
// ---------------------------------------------------------------------------
struct Worker {
    std::vector<uint64_t> stack;
    std::atomic<uint64_t> priv{0};
    uint64_t pops = 0;
    WorkStealingDeque deque{8};
    MarkerCounters ctr;
    mw::Lab lab;
    mw::LabCounters lc;
    uint64_t copied = 0, promoted = 0, races = 0, busy_waits = 0;
    uint64_t ylos_won = 0, ylos_lost = 0;
};

struct Copier {
    Heap& h;
    unsigned n;
    size_t spine_run;
    mw::ToSpace ts;
    std::vector<std::unique_ptr<Worker>> w;

    Copier(Heap& heap, unsigned workers, size_t lab, size_t run = kSpineRun)
        : h(heap), n(workers), spine_run(run) {
        ts.reset(h.to.base(), h.to.base() + h.to.words.size() * 8, lab);
        for (unsigned i = 0; i < n; ++i) w.push_back(std::make_unique<Worker>());
    }

    static void fill(char* p, size_t bytes) {
        reinterpret_cast<uint64_t*>(p)[0] = mkHeader(kFill, false, bytes);
    }

    void pushGrey(Worker& wk, uint64_t e) {
        wk.stack.push_back(e);
        wk.priv.store(wk.stack.size(), std::memory_order_relaxed);
        if ((wk.stack.size() & 31) == 0) publishHalf(wk);
    }
    void publishHalf(Worker& wk) {
        if (wk.stack.size() < 64 || !wk.deque.emptyApprox()) return;
        const size_t half = wk.stack.size() / 2;
        for (size_t i = 0; i < half; ++i) wk.deque.push(wk.stack[i]);
        wk.stack.erase(wk.stack.begin(), wk.stack.begin() + static_cast<std::ptrdiff_t>(half));
        wk.priv.store(wk.stack.size(), std::memory_order_relaxed);
    }
    void publishAll(Worker& wk) {
        for (uint64_t e : wk.stack) wk.deque.push(e);
        wk.stack.clear();
        wk.priv.store(0, std::memory_order_relaxed);
    }

    char* promoAlloc(size_t words) {
        std::lock_guard<mw::SpinMutex> g(h.promo_mu);
        if (h.old_used + words > h.old.words.size()) fail("old region full");
        char* p = reinterpret_cast<char*>(h.old.words.data() + h.old_used);
        h.old_used += words;
        return p;
    }

    // Copies the claimed object `obj` (original header `hdr`); returns the copy.
    char* copyClaimed(Worker& wk, uint64_t* obj, uint64_t hdr) {
        const size_t words = objWords(hdr);
        char* dst;
        const bool promote = hAge(hdr);
        if (promote) {
            dst = promoAlloc(words);
            ++wk.promoted;
        } else {
            dst = mw::labAllocate(ts, wk.lab, wk.lc, words * 8, &Copier::fill);
        }
        ECO_TLA_TRACE_ONLY(const int64_t cid = noteCopy(obj, dst);)
        ECO_TLA_TRACE("copy", "obj", tlatrace::obj(obj), "dst", cid, "promote", promote);
        std::memcpy(dst + 8, obj + 1, (words - 1) * 8);
        reinterpret_cast<uint64_t*>(dst)[0] = hdr;
        pace();
        mw::publish(obj, dst, mw::colorOf(hdr));
        ++wk.copied;
        return dst;
    }

    uint64_t waitFwd(Worker& wk, uint64_t* obj) {
        ++wk.busy_waits;
        return mw::waitPublished(obj, [&](unsigned r) { backoff(r, wk.ctr); });
    }

    // reachYoungLargeP's shape: the whole test-and-set, and the promotion or
    // ageing, in one ylos_mu section; the push after unlocking.
    void reachYoungLarge(Worker& wk, uint64_t* obj) {
        {
            std::lock_guard<std::mutex> g(h.ylos_mu);
            const size_t k = static_cast<size_t>(obj - h.ylos.words.data());
            ECO_TLA_TRACE_ONLY(const int64_t tick = ++h.ylos_tick;)
            pace();
            if (h.ylos_reached[k]) {
                ECO_TLA_TRACE("ylos", "obj", tlatrace::obj(obj), "won", false, "promoted", false,
                              "clk", "ylos", "tick", tick);
                ++wk.ylos_lost;
                return;
            }
            h.ylos_reached[k] = 1;
            const bool promote = hAge(obj[0]);
            obj[0] = promote ? (obj[0] & ~kAgeBit) : (obj[0] | kAgeBit);   // promoteYoungLarge / age++
            ECO_TLA_TRACE("ylos", "obj", tlatrace::obj(obj), "won", true, "promoted", promote,
                          "clk", "ylos", "tick", tick);
            ++wk.ylos_won;
        }
        ECO_TLA_TRACE("ypush", "obj", tlatrace::obj(obj), "put", tlatrace::key("e", obj));
        pushGrey(wk, objEntry(obj, 0));
    }

    // Evacuates one slot (`idx` of `parent`, 1-based; parent null for a root).
    void evacuate(Worker& wk, uint64_t& slot, const void* parent, int idx) {
        const uint64_t v = slot;
        if (v == 0 || (v & 1)) return;
        uint64_t* obj = reinterpret_cast<uint64_t*>(v);
        if (!h.from.contains(obj)) {
            if (h.ylos.contains(obj)) reachYoungLarge(wk, obj);
            return;
        }
        pace();
        uint64_t hdr = mw::loadHeader(obj);
        traceLoad(obj, hdr);
        for (;;) {
            if (mw::isForwardWord(hdr)) {
                if (hdr == mw::kBusy) { hdr = waitFwd(wk, obj); continue; }
                slot = reinterpret_cast<uintptr_t>(mw::fwdAddr(hdr));
                ECO_TLA_TRACE("slot", "parent", tlatrace::obj(parent), "idx", idx,
                              "val", tlatrace::obj(reinterpret_cast<const void*>(slot)));
                return;
            }
            pace();
            if (mw::claim(obj, hdr)) break;
            ++wk.races;
        }
        char* dst = copyClaimed(wk, obj, hdr);
        slot = reinterpret_cast<uintptr_t>(dst);
        ECO_TLA_TRACE("slot", "parent", tlatrace::obj(parent), "idx", idx, "val", tlatrace::obj(dst),
                      "put", tlatrace::key("e", dst));
        pushGrey(wk, objEntry(dst, 0));
        (void)parent;
        (void)idx;
    }

    // The spine run from copy `prev` (P§3.7 shape).
    void spine(Worker& wk, uint64_t* prev) {
        uint64_t* first = nullptr;
        size_t k = 0;
        bool truncated = false, needs_heads = false;
        for (;;) {
            const uint64_t t = prev[3];
            if (t == 0 || (t & 1)) break;
            uint64_t* obj = reinterpret_cast<uint64_t*>(t);
            if (!h.from.contains(obj)) { evacuate(wk, prev[3], prev, 2); break; }
            pace();
            uint64_t hdr = mw::loadHeader(obj);
            traceLoad(obj, hdr);
            if (mw::isForwardWord(hdr)) {
                if (hdr == mw::kBusy) hdr = waitFwd(wk, obj);
                prev[3] = reinterpret_cast<uintptr_t>(mw::fwdAddr(hdr));
                break;
            }
            if (hTag(hdr) != kCons) { evacuate(wk, prev[3], prev, 2); break; }
            if (k == spine_run) {
                ECO_TLA_TRACE("trunc", "prev", tlatrace::obj(prev), "put", tlatrace::key("e", prev));
                pushGrey(wk, objEntry(prev, 0));
                truncated = true;
                break;
            }
            pace();
            if (!mw::claim(obj, hdr)) { ++wk.races; continue; }
            char* c = copyClaimed(wk, obj, hdr);
            uint64_t* cc = reinterpret_cast<uint64_t*>(c);
            if (cc[2] != 0 && (cc[2] & 1) == 0) needs_heads = true;
            prev[3] = reinterpret_cast<uintptr_t>(c);
            ECO_TLA_TRACE("link", "prev", tlatrace::obj(prev), "cell", tlatrace::obj(c));
            if (k == 0) first = cc;
            prev = cc;
            ++k;
        }
        if (needs_heads && k > 0) {
            const size_t m = truncated ? k - 1 : k;
            ECO_TLA_TRACE("heads", "m", m);
            uint64_t* c = first;
            for (size_t i = 0; i < m; ++i) {
                evacuate(wk, c[2], c, 1);
                c = reinterpret_cast<uint64_t*>(c[3]);
            }
        }
    }

    void scan(Worker& wk, uint64_t e) {
        uint64_t* o = static_cast<uint64_t*>(entryAddr(e));
        const uint64_t hdr = o[0];
        const int base = static_cast<int>(isChunk(e) ? entryField(e) * kChunk : 0);
        auto ev = [&](uint64_t s) { evacuate(wk, o[2 + s], o, static_cast<int>(s) + 1); };
        if (isChunk(e)) {
            ECO_TLA_TRACE("scan", "e", tlatrace::obj(o), "chunk", base);   // not in tiny heaps
            const uint64_t lo = static_cast<uint64_t>(base);
            const uint64_t hi = std::min<uint64_t>(hN(hdr), lo + kChunk);
            for (uint64_t s = lo; s < hi; ++s) ev(s);
            return;
        }
        ECO_TLA_TRACE("scan", "e", tlatrace::obj(o), "get", tlatrace::key("e", o));
        if (hTag(hdr) == kCons) {
            evacuate(wk, o[2], o, 1);
            spine(wk, o);
            return;
        }
        const uint64_t ns = hN(hdr);
        uint64_t hi = ns;
        if (ns > kChunk) {
            for (uint64_t c = 1; c * kChunk < ns; ++c) pushGrey(wk, chunkEntry(o, static_cast<uint32_t>(c)));
            hi = kChunk;
        }
        for (uint64_t s = 0; s < hi; ++s) ev(s);
    }

    struct Env {
        static constexpr bool kParallel = true;
        Copier& c;
        MarkerCounters& counters(unsigned i) { return c.w[i]->ctr; }
        uint64_t takeOwn(unsigned i) {
            Worker& wk = *c.w[i];
            if (!wk.stack.empty()) {
                const uint64_t e = wk.stack.back();
                wk.stack.pop_back();
                wk.priv.store(wk.stack.size(), std::memory_order_relaxed);
                if ((++wk.pops & 63) == 0) c.publishHalf(wk);
                return e;
            }
            return wk.deque.take();
        }
        uint64_t stealFrom(unsigned v) { return c.w[v]->deque.steal(); }
        bool anyWork() {   // stealable work only (as the heap's MinorEnv)
            for (unsigned i = 0; i < c.n; ++i)
                if (!c.w[i]->deque.emptyApprox()) return true;
            return false;
        }
        void prefetch(uint64_t) {}
        void scan(unsigned self, uint64_t e) { c.scan(*c.w[self], e); }
        void publishAll(unsigned self) { c.publishAll(*c.w[self]); }
    };

    struct RunArgs { Copier* c; SliceControl* ctl; };
    static void entry(void* ctx, unsigned member) {
        RunArgs* a = static_cast<RunArgs*>(ctx);
        Env env{*a->c};
        runMarkerLoop(env, member, *a->ctl);
    }

    uint64_t run(unsigned jitter) {
        // Roots, serial, on worker 0; then distribute.
        for (size_t i = 0; i < h.roots.size(); ++i) evacuate(*w[0], h.roots[i], nullptr, static_cast<int>(i) + 1);
        std::vector<uint64_t> greys;
        greys.swap(w[0]->stack);
        w[0]->priv.store(0);
        for (size_t i = 0; i < greys.size(); ++i) w[i % n]->deque.push(greys[i]);
        SliceControl ctl(kDrainBudget, n, jitter, n);
        for (unsigned i = 0; i < n; ++i) w[i]->ctr.resetRun(i);
        RunArgs args{this, &ctl};
        if (n == 1) {
            Env env{*this};
            runMarkerLoop(env, 0, ctl);
        } else {
            gc::GCMarkGang::instance().run(&Copier::entry, &args, n);
        }
        for (unsigned i = 0; i < n; ++i) {
            if (!w[i]->stack.empty() || !w[i]->deque.emptyApprox()) fail("work left after the drain");
            w[i]->deque.retireOldArrays();
        }
        std::vector<mw::Lab> labs;
        for (unsigned i = 0; i < n; ++i) labs.push_back(w[i]->lab);
        uint64_t fillers = mw::closeLabs(ts, labs.data(), n, &Copier::fill);
        for (unsigned i = 0; i < n; ++i) fillers += w[i]->lc.filler_bytes;
        return fillers;
    }
};

// Serial reference: the reachable original objects (from-space and YLOS), by DFS.
void reachable(Heap& h, std::vector<uint64_t*>& out, std::vector<uint64_t*>& out_ylos) {
    std::vector<uint64_t*> st;
    std::unordered_map<uint64_t*, bool> seen;
    auto visit = [&](uint64_t v) {
        if (v == 0 || (v & 1)) return;
        uint64_t* o = reinterpret_cast<uint64_t*>(v);
        if (!h.from.contains(o) && !h.ylos.contains(o)) return;
        if (seen.emplace(o, true).second) st.push_back(o);
    };
    for (uint64_t r : h.roots) visit(r);
    while (!st.empty()) {
        uint64_t* o = st.back();
        st.pop_back();
        (h.from.contains(o) ? out : out_ylos).push_back(o);
        if (hTag(o[0]) == kCons) { visit(o[2]); visit(o[3]); }
        else for (uint64_t s = 0; s < hN(o[0]); ++s) visit(o[2 + s]);
    }
}

void runHeap(Heap& h, unsigned n, unsigned jitter, size_t lab, size_t spine_run,
             const std::string* trace_header) {
    std::vector<uint64_t*> reach, reach_ylos;
    reachable(h, reach, reach_ylos);
    // Snapshot the originals (the GC overwrites their headers, and a YLOS's slots).
    std::unordered_map<uint64_t*, std::vector<uint64_t>> orig;
    orig.reserve((reach.size() + reach_ylos.size()) * 2);
    for (uint64_t* o : reach) orig[o] = std::vector<uint64_t>(o, o + objWords(o[0]));
    for (uint64_t* o : reach_ylos) orig[o] = std::vector<uint64_t>(o, o + objWords(o[0]));
    const std::vector<uint64_t> roots0 = h.roots;
    const size_t old_used0 = h.old_used;

    Copier c(h, n, lab, spine_run);
#if ECO_TLA_TRACE_ENABLED
    if (trace_header != nullptr) {
        g_trace_heap = &h;
        g_copy_id.clear();
        g_copy_count.clear();
        tlatrace::setObjId(&traceObjId);
        tlatrace::begin(*trace_header, "");
    }
#else
    (void)trace_header;
#endif
    const uint64_t fillers = c.run(jitter);
#if ECO_TLA_TRACE_ENABLED
    if (trace_header != nullptr && !tlatrace::end(nullptr)) fail("writing the trace");
#endif

    // (a) exactly-once
    uint64_t copied = 0, ylos_won = 0;
    for (unsigned i = 0; i < n; ++i) copied += c.w[i]->copied;
    for (unsigned i = 0; i < n; ++i) ylos_won += c.w[i]->ylos_won;
    if (copied != reach.size()) fail("copied != reachable", copied, reach.size());
    if (ylos_won != reach_ylos.size()) fail("(a) YLOS reached != reachable YLOS", ylos_won, reach_ylos.size());
    for (uint64_t* y : reach_ylos) {
        if (!h.ylos_reached[static_cast<size_t>(y - h.ylos.words.data())]) fail("(a) reachable YLOS not reached", y[1]);
        if (hAge(y[0]) == hAge(orig[y][0])) fail("(a) YLOS neither promoted nor aged", y[1]);
    }
    std::unordered_map<uint64_t*, uint64_t*> fwd;
    for (uint64_t* o : reach) {
        const uint64_t hw = o[0];
        if (hw == mw::kBusy) fail("(c) BUSY left");
        if (!mw::isForwardWord(hw)) fail("(a) reachable object not forwarded");
        fwd[o] = reinterpret_cast<uint64_t*>(mw::fwdAddr(hw));
    }
    // (c) no BUSY anywhere in from-space's objects: walk the original layout
    for (size_t off = 0; off < h.from_used;) {
        uint64_t* o = h.from.words.data() + off;
        if (o[0] == mw::kBusy) fail("(c) BUSY word in from-space");
        auto it = orig.find(o);
        off += (it != orig.end()) ? it->second.size() : objWords(o[0]);
    }
    // (b) structure: every copy's children are the copies of the originals'
    auto mapChild = [&](uint64_t v) -> uint64_t {
        if (v == 0 || (v & 1)) return v;
        uint64_t* p = reinterpret_cast<uint64_t*>(v);
        if (!h.from.contains(p)) return v;
        auto it = fwd.find(p);
        if (it == fwd.end()) fail("(b) child not forwarded");
        return reinterpret_cast<uintptr_t>(it->second);
    };
    for (uint64_t* o : reach) {
        const std::vector<uint64_t>& ow = orig[o];
        uint64_t* cp = fwd[o];
        if (!h.to.contains(cp) && !h.old.contains(cp)) fail("(b) copy outside to/old");
        if (cp[0] != ow[0] || cp[1] != ow[1]) fail("(b) header/id mismatch", cp[1], ow[1]);
        for (size_t k = 2; k < ow.size(); ++k) {
            if (h.from.contains(reinterpret_cast<void*>(cp[k])) && (cp[k] & 1) == 0 && cp[k] != 0)
                fail("(b) copy slot points into from-space");
            if (cp[k] != mapChild(ow[k])) fail("(b) copy slot != copy of the original child");
        }
    }
    for (uint64_t* y : reach_ylos) {           // scanned in place: slots updated, id kept
        const std::vector<uint64_t>& ow = orig[y];
        if (y[1] != ow[1] || hN(y[0]) != hN(ow[0])) fail("(b) YLOS header/id changed", y[1]);
        for (size_t k = 2; k < ow.size(); ++k)
            if (y[k] != mapChild(ow[k])) fail("(b) YLOS slot != copy of the original child", y[1]);
    }
    for (size_t i = 0; i < roots0.size(); ++i)
        if (h.roots[i] != mapChild(roots0[i])) fail("(b) root not updated");
    // (d) to-space parses; fillers sum to the reported waste
    char* top = c.ts.top.load();
    uint64_t seen_fill = 0, seen_objs = 0;
    for (char* p = h.to.base(); p < top;) {
        const uint64_t hw = *reinterpret_cast<uint64_t*>(p);
        const uint64_t t = hTag(hw);
        if (t == kFill) {
            if (hN(hw) < 8 || hN(hw) % 8) fail("(d) bad filler size", hN(hw));
            seen_fill += hN(hw);
        } else if (t == kNode || t == kCons) {
            ++seen_objs;
        } else {
            fail("(d) to-space does not parse", t);
        }
        p += objWords(hw) * 8;
        if (p > top) fail("(d) to-space walk overran the top");
    }
    if (seen_fill != fillers) fail("(d) filler bytes", seen_fill, fillers);
    uint64_t promoted = 0;
    for (unsigned i = 0; i < n; ++i) promoted += c.w[i]->promoted;
    if (seen_objs + promoted != copied) fail("(d) to-space objects + promoted != copied");
    (void)old_used0;
}

void runOne(uint64_t seed, unsigned n, unsigned jitter, size_t lab) {
    std::mt19937_64 rng(seed);
    static Heap h;
    buildHeap(h, rng);
    runHeap(h, n, jitter, lab, kSpineRun, nullptr);
}

}  // namespace

int main(int argc, char** argv) {
    if (argc > 1 && std::strcmp(argv[1], "tiny") == 0) {
        // tiny <seed> <workers> <spine run> <pace us>: one heap of M3's example
        // kind; in the trace build, recorded to $ECO_TLA_TRACE_OUT.
        if (argc != 6) {
            std::fprintf(stderr, "usage: %s tiny <seed> <workers> <spine run> <pace us>\n", argv[0]);
            return 2;
        }
        const uint64_t seed = std::strtoull(argv[2], nullptr, 10);
        const unsigned n = static_cast<unsigned>(std::atoi(argv[3]));
        const size_t run = static_cast<size_t>(std::atoi(argv[4]));
        g_pace_us = static_cast<unsigned>(std::atoi(argv[5]));
        if (n < 1 || n > 16 || run < 1) fail("tiny: bad arguments", n, run);
        ECO_TLA_TRACE_ONLY(tlatrace::nameThread("mut", -1);)
        gc::GCMarkGang::instance().configure(16, 0);
        static Heap h;
        const std::string hdr = buildTiny(h, seed, n, run);
        runHeap(h, n, 0, 4096, run, &hdr);
        std::printf("minor_harness PASS (tiny seed %llu, %u workers)\n", (unsigned long long)seed, n);
        return 0;
    }
    const int heaps = argc > 1 ? std::atoi(argv[1]) : 200;
    unsigned configured_jitter = ~0u;
    const unsigned ns[] = {1, 2, 4, 8, 16};
    const size_t labs[] = {4096, 32768};
    uint64_t runs = 0;
    for (unsigned jitter : {0u, 50u}) {
        if (configured_jitter != jitter) {
            if (gc::GCMarkGang::instance().configured()) gc::GCMarkGang::instance().shutdownForTesting();
            gc::GCMarkGang::instance().configure(16, jitter);
            configured_jitter = jitter;
        }
        for (int i = 0; i < heaps; ++i) {
            for (unsigned n : ns) {
                for (size_t lab : labs) {
                    // jitter 50 is slow: a subset of the heaps
                    if (jitter != 0 && i % 10 != 0) continue;
                    runOne(0x5EED0000ull + static_cast<uint64_t>(i), n, jitter, lab);
                    ++runs;
                }
            }
        }
    }
    std::printf("minor_harness PASS (%llu runs)\n", (unsigned long long)runs);
    return 0;
}
