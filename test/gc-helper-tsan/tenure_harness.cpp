// threaded-gc-07 (plans/threaded-gc-07-concurrent-tenuring.md Steps 3 and 10):
// the TSan harness for the tenure job's std-only core (TenureWork.hpp: the
// shadow-entry claim / publish protocol and the resumable exact engine), run
// on the REAL GCBackgroundGang (launch / stopAndJoin / join), over a
// synthetic heap.
//
// Synthetic objects (8-byte words):
//   header: tag (bits 0..4: 1 node, 2 cons), age (bit 8), nslots (bits 32..63)
//   word 1: id;  words 2..: slots (cons: slot 0 = head, slot 1 = tail).
// A slot is 0 (null), odd (a constant), or an object address in the
// TENURING arena, the FRESH arena (the mutator's newest objects; their slots
// are the heal list), the OLD arena, or the YLOS arena.
//
// Checks per job: (a) the promoted set == the set reachable from the starts
// and the heal slots' values through tenuring objects and reached YLOS
// objects; (b) every such object copied exactly once; (c) every copy's slots
// point at copies, old objects, constants or YLOS objects -- never the
// tenuring arena; (d) no BUSY entry left; (e) payloads (ids) preserved; (f)
// with stops injected after every 1, 7 and 1,000 items and resumed on another
// thread, the copies' addresses are IDENTICAL to an uninterrupted run; (g) a
// reader thread walks the tenuring arena and the heal slots while the
// collector runs; the "pause" joins, heals and verifies. (h) Storm: 10,000
// jobs on the real gang with random stops. Pass: "tenure_harness PASS", exit
// 0, no ThreadSanitizer report.
//
// threaded-gc-07b: even seeds add an AGEING arena (objects pointing into the
// tenuring arena, the ageing arena, old objects and constants) and age starts.
// (i) the mark marks exactly the ageing objects reachable from the age starts,
// (j) the zap spans cover exactly the unmarked ageing objects, (k) the heal list
// gains exactly the marked objects' slots into the tenuring arena, all under
// the same stop / resume identity and on the real gang.
//
// M5's TLA+ trace (plans/threaded-gc-tla-M5-tenuring.md §9; test/tla/M5-tenuring/
// TraceTenuring.tla): `tiny <seed> <jobs> <nten> <nfresh> <nold> <nylos> <nf>
// <stop %> <pace us>` runs a storm of jobs over TINY heaps (node objects of nf
// slots each, rebuilt at the same addresses for every job, so the shadow keeps
// the entries of earlier generations) on the real gang: launch, then join or
// stopAndJoin, help, and a replica of mergeJob's YLOS resolve and heal. In the
// trace build (gc-tenure-trace) it records the engine's hooks (TenureWork.hpp)
// and the pause's events to $ECO_TLA_TRACE_OUT; the header carries every job's heap.

#include "GCHelperPool.hpp"
#include "TenureWork.hpp"

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <sys/mman.h>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>

using namespace Elm;
namespace tw = Elm::tenurework;
#if ECO_TLA_TRACE_ENABLED
namespace tlatrace = Elm::tlatrace;
#endif

[[noreturn]] static void fail(const char* what, uint64_t a = 0, uint64_t b = 0) {
    std::fprintf(stderr, "tenure_harness FAIL: %s (%llu, %llu)\n", what, (unsigned long long)a,
                 (unsigned long long)b);
    std::exit(1);
}

namespace {

constexpr uint64_t kNode = 1, kCons = 2;
inline uint64_t mkHeader(uint64_t tag, uint64_t n) { return tag | (1ull << 8) | (n << 32); }
inline uint64_t hTag(uint64_t h) { return h & 31; }
inline uint64_t hN(uint64_t h) { return h >> 32; }

struct Arena {
    char* base = nullptr;
    size_t cap = 0;
    size_t top = 0;
    // Heap addresses are < 2^43 (HPOINTER_ADDRESS_LIMIT; the shadow entry
    // encodes 40 address bits): place every arena below that.
    void init(size_t bytes) {
        static uintptr_t hint = 0x0400000000ull;   // 16 GiB (inside TSan's low app range)
        void* p = MAP_FAILED;
        for (int tries = 0; tries < 256 && p == MAP_FAILED; ++tries) {
            p = mmap(reinterpret_cast<void*>(hint), bytes, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
            hint += (bytes + (1ull << 30)) & ~((1ull << 30) - 1);
        }
        if (p == MAP_FAILED || reinterpret_cast<uintptr_t>(p) + bytes > (1ull << 43)) fail("mmap");
        base = static_cast<char*>(p);
        cap = bytes;
        top = 0;
    }
    uint64_t* alloc(size_t words) {
        if (top + words * 8 > cap) fail("arena full", top, cap);
        uint64_t* p = reinterpret_cast<uint64_t*>(base + top);
        top += words * 8;
        return p;
    }
    bool has(const void* p) const {
        const char* q = static_cast<const char*>(p);
        return q >= base && q < base + top;
    }
    void reset() {
        std::memset(base, 0, top);
        top = 0;
    }
};

inline uint64_t* obj(uint64_t w) { return reinterpret_cast<uint64_t*>(static_cast<uintptr_t>(w)); }
inline bool isPtr(uint64_t w) { return w != 0 && (w & 7) == 0; }

struct Heap {
    Arena ten, fresh, old, ylos, dst, age;
    std::vector<uint64_t> shadow;         // one per 8-byte granule of `ten`
    std::vector<uint64_t*> ten_objs, fresh_objs, old_objs, ylos_objs, age_objs;
    std::vector<uint64_t> age_bits;       // the job's mark over `age`
    uint32_t gen = 0;
    std::mt19937_64 rng;

    void init() {
        ten.init(64ull << 20);
        fresh.init(16ull << 20);
        old.init(4ull << 20);
        ylos.init(4ull << 20);
        dst.init(96ull << 20);
        age.init(8ull << 20);
        shadow.assign((64ull << 20) / 8, 0);
        age_bits.assign((8ull << 20) / 8 / 64, 0);
    }
    uint64_t pickTarget(bool allow_fresh) {
        const uint64_t r = rng() % 100;
        if (r < 8) return 0;
        if (r < 14) return (rng() % 1000) * 2 + 1;   // odd = a constant
        if (r < 20 && !old_objs.empty()) return reinterpret_cast<uint64_t>(old_objs[rng() % old_objs.size()]);
        if (r < 24 && !ylos_objs.empty()) return reinterpret_cast<uint64_t>(ylos_objs[rng() % ylos_objs.size()]);
        if (allow_fresh && r < 30 && !fresh_objs.empty())
            return reinterpret_cast<uint64_t>(fresh_objs[rng() % fresh_objs.size()]);
        if (!ten_objs.empty()) return reinterpret_cast<uint64_t>(ten_objs[rng() % ten_objs.size()]);
        return 0;
    }
    // Builds one generation: old objects, YLOS objects pointing into the
    // tenuring arena, tenuring objects (nodes, 10k-cell cons chains, shared
    // subgraphs, cycles), fresh objects pointing into all of them.
    void build(uint64_t seed) {
        rng.seed(seed);
        ten.reset(); fresh.reset(); old.reset(); ylos.reset(); dst.reset(); age.reset();
        ten_objs.clear(); fresh_objs.clear(); old_objs.clear(); ylos_objs.clear(); age_objs.clear();
        uint64_t id = 1;
        for (int i = 0; i < 200; ++i) {
            uint64_t* o = old.alloc(3);
            o[0] = mkHeader(kNode, 1); o[1] = id++; o[2] = 0;
            old_objs.push_back(o);
        }
        // Tenuring objects first get slot values patched later (cycles).
        const int nodes = 20000 + static_cast<int>(rng() % 10000);
        for (int i = 0; i < nodes; ++i) {
            const uint64_t k = rng() % 9;
            uint64_t* o = ten.alloc(2 + k);
            o[0] = mkHeader(kNode, k); o[1] = id++;
            for (uint64_t j = 0; j < k; ++j) o[2 + j] = 0;
            ten_objs.push_back(o);
        }
        // Cons chains of 10,000 cells (heads: tenuring nodes or constants).
        for (int c = 0; c < 3; ++c) {
            uint64_t* prev = nullptr;
            for (int i = 0; i < 10000; ++i) {
                uint64_t* o = ten.alloc(4);
                o[0] = mkHeader(kCons, 2); o[1] = id++;
                o[2] = (i % 3 == 0) ? 7 : reinterpret_cast<uint64_t>(ten_objs[rng() % nodes]);
                o[3] = 0;
                if (prev) prev[3] = reinterpret_cast<uint64_t>(o);
                prev = o;
                ten_objs.push_back(o);
            }
        }
        // YLOS objects (never moved) pointing into tenuring / old / other YLOS.
        for (int i = 0; i < 40; ++i) {
            const uint64_t k = 1 + rng() % 30;
            uint64_t* y = ylos.alloc(2 + k);
            y[0] = mkHeader(kNode, k); y[1] = id++;
            ylos_objs.push_back(y);
        }
        for (uint64_t* y : ylos_objs)
            for (uint64_t j = 0; j < hN(y[0]); ++j) y[2 + j] = pickTarget(false);
        // Slots of tenuring nodes: tenuring (cycles, sharing), old, YLOS, constants.
        for (int i = 0; i < nodes; ++i) {
            uint64_t* o = ten_objs[i];
            for (uint64_t j = 0; j < hN(o[0]); ++j) o[2 + j] = pickTarget(false);
        }
        // 07b: ageing objects (even seeds): younger than the tenuring arena,
        // older than the fresh one; slots into tenuring / ageing / old / constants.
        if (seed % 2 == 0) {
            for (int i = 0; i < 6000; ++i) {
                const uint64_t k = rng() % 5;
                uint64_t* o = age.alloc(2 + k);
                o[0] = mkHeader(kNode, k); o[1] = id++;
                age_objs.push_back(o);
            }
            for (uint64_t* o : age_objs) {
                for (uint64_t j = 0; j < hN(o[0]); ++j) {
                    const uint64_t r = rng() % 10;
                    o[2 + j] = r < 4 ? reinterpret_cast<uint64_t>(age_objs[rng() % age_objs.size()])
                                     : pickTarget(false);
                }
            }
        }
        for (int i = 0; i < 3000; ++i) {
            const uint64_t k = 1 + rng() % 4;
            uint64_t* f = fresh.alloc(2 + k);
            f[0] = mkHeader(kNode, k); f[1] = id++;
            for (uint64_t j = 0; j < k; ++j) f[2 + j] = pickTarget(false);
            fresh_objs.push_back(f);
        }
        ++gen;
    }
};

#if ECO_TLA_TRACE_ENABLED
// The model's ids (tlatrace::obj) in the tiny scenario: tenuring object i is
// 100 + i, fresh j 200 + j, old k 300 + k, YLOS y 400 + y, a copy 1000 + its
// number in the whole run; nullptr (a null or constant slot) is 0.
Heap* g_trace_heap = nullptr;
size_t g_tiny_words = 0;                     // words per tiny object (2 + nf)
std::unordered_map<const void*, int64_t> g_copy_id;
int64_t g_copies = 0;

int64_t tinyIndex(const Arena& a, const void* p) {
    return static_cast<int64_t>((static_cast<const char*>(p) - a.base) / static_cast<std::ptrdiff_t>(g_tiny_words * 8));
}
int64_t traceObjId(const void* p) {
    if (p == nullptr) return 0;
    Heap& h = *g_trace_heap;
    if (h.ten.has(p)) return 100 + tinyIndex(h.ten, p);
    if (h.fresh.has(p)) return 200 + tinyIndex(h.fresh, p);
    if (h.old.has(p)) return 300 + tinyIndex(h.old, p);
    if (h.ylos.has(p)) return 400 + tinyIndex(h.ylos, p);
    auto it = g_copy_id.find(p);
    return it != g_copy_id.end() ? it->second : -1;
}
#endif

struct Env {
    Heap& h;
    std::vector<uintptr_t>* layout = nullptr;
    void* target(uint64_t w) const { return isPtr(w) ? obj(w) : nullptr; }
    uint64_t word(const void* o) const { return reinterpret_cast<uint64_t>(o); }
    bool inTenuring(const void* p) const { return h.ten.has(p); }
    bool ylosMaybe(const void* p) const { return h.ylos.has(p); }
    bool youngElsewhere(const void* p) const { return h.fresh.has(p); }
    uint64_t* shadow(const void* o) const {
        return &h.shadow[static_cast<size_t>(static_cast<const char*>(o) - h.ten.base) >> 3];
    }
    uint32_t gen() const { return h.gen; }
    size_t sizeOf(const void* o) const { return (2 + hN(*static_cast<const uint64_t*>(o))) * 8; }
    void* copy(const void* o, size_t size) {
        uint64_t* d = h.dst.alloc(size / 8);
        std::memcpy(d, o, size);
        d[0] &= ~(1ull << 8);   // age 0
        if (layout) layout->push_back(reinterpret_cast<uintptr_t>(d));
        ECO_TLA_TRACE_ONLY(if (g_trace_heap != nullptr) g_copy_id[d] = 1000 + ++g_copies;)
        return d;
    }
    template <class F> void forEachChildSlot(void* o, F&& f) {
        uint64_t* p = static_cast<uint64_t*>(o);
        for (uint64_t j = 0; j < hN(p[0]); ++j) f(&p[2 + j]);
    }
    uint64_t* consTail(void* o) const {
        uint64_t* p = static_cast<uint64_t*>(o);
        return hTag(p[0]) == kCons ? &p[3] : nullptr;
    }
    uint64_t* consHead(void* o) const {
        uint64_t* p = static_cast<uint64_t*>(o);
        return hTag(p[0]) == kCons ? &p[2] : nullptr;
    }
    [[noreturn]] void abortYoungChild(const void*, const void*) const { fail("young child (TV6)"); }
    // 07b: one ageing extent (the `age` arena).
    int ageIndex(const void* p) const { return h.age.has(p) ? 0 : -1; }
    bool markAge(int, const void* o) const {
        const size_t g = static_cast<size_t>(static_cast<const char*>(o) - h.age.base) >> 3;
        uint64_t& w = h.age_bits[g >> 6];
        const uint64_t m = uint64_t{1} << (g & 63);
        if (w & m) return false;
        w |= m;
        return true;
    }
    bool isMarkedAge(int, const void* o) const {
        const size_t g = static_cast<size_t>(static_cast<const char*>(o) - h.age.base) >> 3;
        return (h.age_bits[g >> 6] >> (g & 63)) & 1;
    }
    char* ageBase(unsigned) const { return h.age.base; }
    char* ageTop(unsigned) const { return h.age.base + h.age.top; }
    bool ageYlosMaybe(const void*) const { return false; }
    const uint64_t* ageBits(unsigned) const { return h.age_bits.data(); }
};

// Inputs of one job over the heap: random starts + heal slots of fresh objects.
void makeJob(Heap& h, tw::SerialState& st, uint64_t seed) {
    std::mt19937_64 r(seed);
    st.starts.clear();
    st.heal.clear();
    for (int i = 0; i < 50; ++i) st.starts.push_back(h.ten_objs[r() % h.ten_objs.size()]);
    for (uint64_t* f : h.fresh_objs)
        for (uint64_t j = 0; j < hN(f[0]); ++j)
            if (h.ten.has(obj(f[2 + j]))) st.heal.push_back(&f[2 + j]);
    st.ylos.clear();
    std::vector<uint64_t*> ys = h.ylos_objs;
    std::sort(ys.begin(), ys.end());
    for (uint64_t* y : ys)
        st.ylos.push_back(tw::YlosEntry{reinterpret_cast<const char*>(y),
                                        reinterpret_cast<const char*>(y) + (2 + hN(y[0])) * 8});
    st.reached.assign(st.ylos.size(), 0);
    st.age_starts.clear();
    st.n_age = 0;
    std::fill(h.age_bits.begin(), h.age_bits.end(), 0);
    if (!h.age_objs.empty()) {
        for (int i = 0; i < 40; ++i) st.age_starts.push_back(h.age_objs[r() % h.age_objs.size()]);
        st.n_age = 1;
    }
    st.clearProgress();
}

// Checks (a)-(e) after a finished job, then heals the fresh slots.
void verify(Heap& h, tw::SerialState& st) {
    // 07b (i)-(k): the ageing phases against an independent trace.
    if (st.n_age != 0) {
        std::unordered_set<uint64_t*> areach;
        std::vector<uint64_t*> as;
        for (void* s : st.age_starts) if (areach.insert(static_cast<uint64_t*>(s)).second) as.push_back(static_cast<uint64_t*>(s));
        size_t heal_expect = 0;
        while (!as.empty()) {
            uint64_t* o = as.back();
            as.pop_back();
            for (uint64_t j = 0; j < hN(o[0]); ++j) {
                const uint64_t w = o[2 + j];
                if (!isPtr(w)) continue;
                if (h.age.has(obj(w))) { if (areach.insert(obj(w)).second) as.push_back(obj(w)); }
                else if (h.ten.has(obj(w))) ++heal_expect;
            }
        }
        if (st.age_marked != areach.size()) fail("(i) marked != reachable ageing objects", st.age_marked, areach.size());
        // Spans are disjoint, in address order, and cover an object iff it is unmarked.
        for (size_t i = 1; i < st.zap.size(); ++i)
            if (st.zap[i].p < st.zap[i - 1].p + st.zap[i - 1].bytes) fail("(j) zap spans overlap");
        for (uint64_t* o : h.age_objs) {
            const char* lo = reinterpret_cast<const char*>(o);
            const char* hi = lo + (2 + hN(o[0])) * 8;
            auto it = std::upper_bound(st.zap.begin(), st.zap.end(), lo,
                                       [](const char* q, const tw::Span& sp) { return q < sp.p; });
            bool covered = false, touched = false;
            if (it != st.zap.begin()) {
                const tw::Span& sp = *(it - 1);
                covered = lo >= sp.p && hi <= sp.p + sp.bytes;
                touched = lo < sp.p + sp.bytes;
            }
            if (it != st.zap.end() && it->p < hi) touched = true;
            if (areach.count(o) != 0 ? touched : !covered) fail("(j) zap spans != unmarked ageing objects");
        }
        if (st.age_heal != heal_expect) fail("(k) heal slots from the mark", st.age_heal, heal_expect);
    }
    std::unordered_set<uint64_t*> reach;
    std::vector<uint64_t*> stack;
    std::unordered_set<uint64_t*> ylos_seen;
    auto visit = [&](uint64_t w) {
        if (!isPtr(w)) return;
        uint64_t* o = obj(w);
        if (h.ten.has(o)) { if (reach.insert(o).second) stack.push_back(o); }
        else if (h.ylos.has(o)) { if (ylos_seen.insert(o).second) stack.push_back(o); }
    };
    for (void* s : st.starts) visit(reinterpret_cast<uint64_t>(s));
    for (uint64_t* s : st.heal) visit(*s);
    while (!stack.empty()) {
        uint64_t* o = stack.back();
        stack.pop_back();
        for (uint64_t j = 0; j < hN(o[0]); ++j) visit(o[2 + j]);
    }
    uint64_t fwd = 0;
    for (uint64_t* o : h.ten_objs) {
        const uint64_t e = h.shadow[static_cast<size_t>(reinterpret_cast<char*>(o) - h.ten.base) >> 3];
        if (tw::genOf(e) == h.gen && tw::stateOf(e) == tw::kStateBusy) fail("(d) BUSY left");
        char* d = tw::fwdOf(e, h.gen);
        const bool live = reach.count(o) != 0;
        if (live != (d != nullptr)) fail("(a) promoted set != reachable set", live, d != nullptr);
        if (!d) continue;
        ++fwd;
        uint64_t* c = reinterpret_cast<uint64_t*>(d);
        if (c[1] != o[1]) fail("(e) payload changed", c[1], o[1]);
        for (uint64_t j = 0; j < hN(c[0]); ++j) {
            const uint64_t w = c[2 + j];
            if (isPtr(w) && h.ten.has(obj(w))) fail("(c) a copy points into the tenuring arena");
            if (isPtr(o[2 + j]) && h.ten.has(obj(o[2 + j]))) {
                if (reinterpret_cast<char*>(w) != tw::fwdOf(h.shadow[(static_cast<size_t>(
                        reinterpret_cast<char*>(obj(o[2 + j])) - h.ten.base)) >> 3], h.gen))
                    fail("(c) a copy's child is not the copy of the original's child");
            }
        }
    }
    if (fwd != st.tenured) fail("(b) forwarded != tenured", fwd, st.tenured);
    if (h.dst.top / 8 < fwd * 2) fail("(b) copies");
    for (size_t k = 0; k < st.ylos.size(); ++k) {
        const bool seen = ylos_seen.count(reinterpret_cast<uint64_t*>(const_cast<char*>(st.ylos[k].obj))) != 0;
        if (seen != (st.reached[k] != 0)) fail("(a) YLOS reached set", seen, st.reached[k]);
    }
    // The "pause": heal.
    for (uint64_t* s : st.heal) {
        char* d = tw::fwdOf(h.shadow[static_cast<size_t>(reinterpret_cast<char*>(obj(*s)) - h.ten.base) >> 3], h.gen);
        if (!d) fail("heal target not forwarded");
        *s = reinterpret_cast<uint64_t>(d);
    }
}

struct CollectorCtx {
    Heap* h;
    tw::SerialState* st;
    std::vector<uintptr_t>* layout;
    std::atomic<bool>* stop;
};

void collectorEntry(void* ctx, unsigned) {
    CollectorCtx* c = static_cast<CollectorCtx*>(ctx);
    Env env{*c->h, c->layout};
    (void)tw::tenureDrainSerial(*c->st, env, c->stop);
}

// ---- the tiny scenario (M5's trace) -----------------------------------------
struct TinyCfg {
    int nten, nfresh, nold, nylos, nf;
};

// Builds job k's tiny heap at the arenas' bases (the same addresses every job)
// and its inputs; returns the job as JSON for the trace header (slot values as
// the model's ids: 0 for null or a constant).
std::string buildTiny(Heap& h, const TinyCfg& c, uint64_t seed, uint64_t k, tw::SerialState& st) {
    std::mt19937_64 r(seed * 1000003ull + k);
    h.ten.reset(); h.fresh.reset(); h.old.reset(); h.ylos.reset(); h.dst.reset(); h.age.reset();
    h.ten_objs.clear(); h.fresh_objs.clear(); h.old_objs.clear(); h.ylos_objs.clear(); h.age_objs.clear();
    const uint64_t nf = static_cast<uint64_t>(c.nf);
    uint64_t id = 1;
    auto mk = [&](Arena& a, std::vector<uint64_t*>& v, int n) {
        for (int i = 0; i < n; ++i) {
            uint64_t* o = a.alloc(2 + nf);
            o[0] = mkHeader(kNode, nf); o[1] = id++;
            for (uint64_t j = 0; j < nf; ++j) o[2 + j] = 0;
            v.push_back(o);
        }
    };
    mk(h.old, h.old_objs, c.nold);
    mk(h.ten, h.ten_objs, c.nten);
    mk(h.ylos, h.ylos_objs, c.nylos);
    mk(h.fresh, h.fresh_objs, c.nfresh);
    auto any = [&](const std::vector<uint64_t*>& v) { return reinterpret_cast<uint64_t>(v[r() % v.size()]); };
    // A slot of a tenuring or YLOS object: tenuring (cycles, sharing), old, YLOS, null, constant.
    auto pick = [&](bool fresh_holder) -> uint64_t {
        const uint64_t x = r() % 10;
        if (x < 2) return 0;
        if (x == 2) return 7;
        if (x == 3 && !h.old_objs.empty()) return any(h.old_objs);
        if (x == 4 && !fresh_holder && !h.ylos_objs.empty()) return any(h.ylos_objs);
        return any(h.ten_objs);
    };
    for (uint64_t* o : h.ten_objs) for (uint64_t j = 0; j < nf; ++j) o[2 + j] = pick(false);
    for (uint64_t* o : h.ylos_objs) for (uint64_t j = 0; j < nf; ++j) o[2 + j] = pick(false);
    for (uint64_t* o : h.fresh_objs) for (uint64_t j = 0; j < nf; ++j) o[2 + j] = pick(true);
    st.starts.clear();
    st.heal.clear();
    const int ns = static_cast<int>(r() % 3);
    for (int i = 0; i < ns; ++i) st.starts.push_back(h.ten_objs[r() % h.ten_objs.size()]);
    for (uint64_t* f : h.fresh_objs)
        for (uint64_t j = 0; j < nf; ++j)
            if (isPtr(f[2 + j]) && h.ten.has(obj(f[2 + j]))) st.heal.push_back(&f[2 + j]);
    st.ylos.clear();
    for (uint64_t* y : h.ylos_objs)   // allocated in address order: already sorted
        st.ylos.push_back(tw::YlosEntry{reinterpret_cast<const char*>(y),
                                        reinterpret_cast<const char*>(y) + (2 + nf) * 8});
    st.reached.assign(st.ylos.size(), 0);
    st.age_starts.clear();
    st.n_age = 0;
    st.clearProgress();
    // The job for the header, in the model's ids.
    auto idOf = [&](uint64_t w) -> int64_t {
        if (!isPtr(w)) return 0;
        const void* p = obj(w);
        const int64_t words = static_cast<int64_t>(2 + nf) * 8;
        if (h.ten.has(p)) return 100 + (static_cast<const char*>(p) - h.ten.base) / words;
        if (h.old.has(p)) return 300 + (static_cast<const char*>(p) - h.old.base) / words;
        if (h.ylos.has(p)) return 400 + (static_cast<const char*>(p) - h.ylos.base) / words;
        fail("tiny: a slot outside the arenas");
    };
    auto cells = [&](const std::vector<uint64_t*>& v) {
        std::string s = "[";
        for (size_t i = 0; i < v.size(); ++i) {
            s += i ? ",[" : "[";
            for (uint64_t j = 0; j < nf; ++j) s += (j ? "," : "") + std::to_string(idOf(v[i][2 + j]));
            s += "]";
        }
        return s + "]";
    };
    std::string js = "{\"gen\":" + std::to_string(k) + ",\"ten\":" + cells(h.ten_objs) +
                     ",\"fresh\":" + cells(h.fresh_objs) + ",\"ylos\":" + cells(h.ylos_objs) + ",\"starts\":[";
    for (size_t i = 0; i < st.starts.size(); ++i)
        js += (i ? "," : "") + std::to_string(idOf(reinterpret_cast<uint64_t>(st.starts[i])));
    js += "],\"heal\":[";
    for (size_t i = 0; i < st.heal.size(); ++i) {
        const size_t off = static_cast<size_t>(reinterpret_cast<char*>(st.heal[i]) - h.fresh.base);
        js += (i ? ",[" : "[") + std::to_string(off / ((2 + nf) * 8)) + "," +
              std::to_string((off % ((2 + nf) * 8)) / 8 - 1) + "]";   // fresh index, slot 1..nf
    }
    return js + "]}";
}

// tiny <seed> <jobs> <nten> <nfresh> <nold> <nylos> <nf> <stop %> <pace us>
int tinyMain(int argc, char** argv) {
    if (argc != 11) {
        std::fprintf(stderr, "usage: %s tiny <seed> <jobs> <nten> <nfresh> <nold> <nylos> <nf> <stop %%> <pace us>\n",
                     argv[0]);
        return 2;
    }
    const uint64_t seed = std::strtoull(argv[2], nullptr, 10);
    const uint64_t jobs = std::strtoull(argv[3], nullptr, 10);
    const TinyCfg c{std::atoi(argv[4]), std::atoi(argv[5]), std::atoi(argv[6]), std::atoi(argv[7]), std::atoi(argv[8])};
    const unsigned stop_pct = static_cast<unsigned>(std::atoi(argv[9]));
    const unsigned pace = static_cast<unsigned>(std::atoi(argv[10]));
    if (jobs < 1 || c.nten < 1 || c.nfresh < 0 || c.nold < 0 || c.nylos < 0 || c.nf < 1 || c.nf > 4)
        fail("tiny: bad arguments");
    static Heap h;
    h.init();
    gc::GCBackgroundGang::Options opt;
    opt.members = 1;
    opt.name = "eco-tenure";
    gc::GCBackgroundGang gang(opt);
#if ECO_TLA_TRACE_ENABLED
    tlatrace::nameThread("mut", -1);
    g_trace_heap = &h;
    g_tiny_words = static_cast<size_t>(2 + c.nf);
    tlatrace::setObjId(&traceObjId);
    {
        std::string hdr = "{\"model\":\"M5\",\"scenario\":\"tiny\",\"seed\":" + std::to_string(seed) +
                          ",\"nf\":" + std::to_string(c.nf) + ",\"slot0\":16,\"stride\":8" +
                          ",\"nten\":" + std::to_string(c.nten) + ",\"nfresh\":" + std::to_string(c.nfresh) +
                          ",\"nold\":" + std::to_string(c.nold) + ",\"nylos\":" + std::to_string(c.nylos) +
                          ",\"njobs\":" + std::to_string(jobs) + ",\"jobs\":[";
        for (uint64_t k = 1; k <= jobs; ++k) {
            tw::SerialState tmp;
            hdr += (k > 1 ? "," : "") + buildTiny(h, c, seed, k, tmp);
        }
        tlatrace::begin(hdr + "]}", "");
    }
#endif
    std::mt19937_64 r(seed ^ 0x7E4E7E4Eull);
    uint64_t stops = 0, helps = 0;
    for (uint64_t k = 1; k <= jobs; ++k) {
        tw::SerialState st;
        (void)buildTiny(h, c, seed, k, st);
        h.gen = static_cast<uint32_t>(k);
        st.test_sleep_us_per_item = pace;
        std::atomic<bool> stop{false};
        CollectorCtx cc{&h, &st, nullptr, &stop};
        ECO_TLA_TRACE("job", "k", k);
        gang.launch(&collectorEntry, &cc, &stop);
        if (r() % 100 < stop_pct) {
            const uint64_t d = r() % (static_cast<uint64_t>(pace) * static_cast<uint64_t>(c.nten + 2) + 1);
            if (d != 0) std::this_thread::sleep_for(std::chrono::microseconds(d));
            ECO_TLA_TRACE("tstopreq", "put", tlatrace::key("S", &stop, static_cast<int64_t>(k)));
            gang.stopAndJoin();
            ++stops;
        } else {
            gang.join();
        }
        st.test_sleep_us_per_item = 0;
        if (!st.done()) {   // help, in the pause
            Env env{h, nullptr};
            if (tw::tenureDrainSerial(st, env, nullptr) != tw::DrainResult::Done) fail("tiny: help not done");
            ++helps;
        }
        // The merge (a replica of mergeJob's steps 4 and 5): resolve the reached
        // YLOS objects' slots into the extent, heal the recorded slots; then the
        // whole shadow of the extent, for the trace spec to compare.
        ECO_TLA_TRACE("tmerge", "k", k);
        auto fwd = [&](uint64_t w) -> char* {
            char* d = tw::fwdOf(h.shadow[static_cast<size_t>(reinterpret_cast<char*>(obj(w)) - h.ten.base) >> 3], h.gen);
            if (d == nullptr) fail("tiny: TV1, no forwarding at the merge", k);
            return d;
        };
        for (size_t y = 0; y < st.ylos.size(); ++y) {
            if (!st.reached[y]) continue;
            uint64_t* yo = reinterpret_cast<uint64_t*>(const_cast<char*>(st.ylos[y].obj));
            for (uint64_t j = 0; j < static_cast<uint64_t>(c.nf); ++j) {
                if (!isPtr(yo[2 + j]) || !h.ten.has(obj(yo[2 + j]))) continue;
                yo[2 + j] = reinterpret_cast<uint64_t>(fwd(yo[2 + j]));
                ECO_TLA_TRACE("tyres", "par", tlatrace::obj(yo), "off", static_cast<int64_t>(16 + 8 * j),
                              "val", tlatrace::obj(obj(yo[2 + j])));
            }
        }
        for (uint64_t* s : st.heal) {
            if (!isPtr(*s) || !h.ten.has(obj(*s))) continue;
            *s = reinterpret_cast<uint64_t>(fwd(*s));
            ECO_TLA_TRACE_ONLY(const size_t off = static_cast<size_t>(reinterpret_cast<char*>(s) - h.fresh.base);)
            ECO_TLA_TRACE_ONLY(uint64_t* holder = reinterpret_cast<uint64_t*>(h.fresh.base + (off / (g_tiny_words * 8)) * g_tiny_words * 8);)
            ECO_TLA_TRACE("theal", "par", tlatrace::obj(holder),
                          "off", static_cast<int64_t>(reinterpret_cast<char*>(s) - reinterpret_cast<char*>(holder)),
                          "val", tlatrace::obj(obj(*s)));
        }
        for (uint64_t* o : h.ten_objs) {
            const uint64_t e = h.shadow[static_cast<size_t>(reinterpret_cast<char*>(o) - h.ten.base) >> 3];
            if (tw::genOf(e) == h.gen && tw::stateOf(e) == tw::kStateBusy) fail("tiny: BUSY left");
            ECO_TLA_TRACE("tshadow", "obj", tlatrace::obj(o), "st", tw::stateOf(e), "g", tw::genOf(e),
                          "dst", tlatrace::obj(tw::fwdOf(e, h.gen)));
            (void)e;
        }
    }
#if ECO_TLA_TRACE_ENABLED
    if (!tlatrace::end(nullptr)) fail("writing the trace");
#endif
    std::printf("tenure_harness PASS (tiny seed %llu, %llu jobs, %llu stops, %llu helps)\n",
                (unsigned long long)seed, (unsigned long long)jobs, (unsigned long long)stops,
                (unsigned long long)helps);
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc > 1 && std::strcmp(argv[1], "tiny") == 0) return tinyMain(argc, argv);
    const int storm = argc > 1 ? std::atoi(argv[1]) : 10000;
    Heap h;
    h.init();
    gc::GCBackgroundGang::Options opt;
    opt.members = 1;
    gc::GCBackgroundGang gang(opt);

    // (a)-(f): per seed, an uninterrupted reference, then stops every 1, 7,
    // 1,000 items resumed on another thread; placements must be identical.
    for (uint64_t seed = 1; seed <= 6; ++seed) {
        std::vector<uintptr_t> ref_layout;
        {
            h.build(seed);
            tw::SerialState st;
            makeJob(h, st, seed);
            Env env{h, &ref_layout};
            if (tw::tenureDrainSerial(st, env, nullptr) != tw::DrainResult::Done) fail("ref not done");
            verify(h, st);
        }
        for (uint64_t k : {1ull, 7ull, 1000ull}) {
            h.build(seed);
            --h.gen; ++h.gen;
            tw::SerialState st;
            makeJob(h, st, seed);
            std::vector<uintptr_t> layout;
            std::atomic<bool> stop{false};
            CollectorCtx cc{&h, &st, &layout, &stop};
            // Alternate threads: the gang member, then this thread, ...
            bool on_gang = true;
            while (!st.done()) {
                st.test_stop_after = st.items + k;
                if (on_gang) {
                    gang.launch(&collectorEntry, &cc, &stop);
                    gang.join();
                } else {
                    Env env{h, &layout};
                    (void)tw::tenureDrainSerial(st, env, nullptr);
                }
                on_gang = !on_gang;
            }
            if (layout != ref_layout) fail("(f) a stopped / resumed job placed copies differently", layout.size(), ref_layout.size());
            verify(h, st);
        }
    }
    std::fprintf(stderr, "tenure_harness: stop/resume identity OK\n");

    // (g): a concurrent reader walks the tenuring arena and the heal slots
    // (read-only) while the collector tenures; then the pause joins and heals.
    for (uint64_t seed = 20; seed < 30; ++seed) {
        h.build(seed);
        tw::SerialState st;
        makeJob(h, st, seed);
        std::atomic<bool> stop{false};
        CollectorCtx cc{&h, &st, nullptr, &stop};
        std::atomic<bool> done{false};
        // The pause's heal list (the job appends the mark's slots privately).
        const std::vector<uint64_t*> heal0 = st.heal;
        std::thread reader([&] {
            uint64_t sum = 0;
            while (!done.load(std::memory_order_acquire)) {
                for (uint64_t* o : h.ten_objs) sum += o[1] + hN(o[0]);
                for (uint64_t* o : h.age_objs) sum += o[1] + hN(o[0]);
                for (uint64_t* s : heal0) sum += *s;
            }
            if (sum == 42) std::fprintf(stderr, " ");
        });
        gang.launch(&collectorEntry, &cc, &stop);
        gang.join();
        done.store(true, std::memory_order_release);
        reader.join();
        if (!st.done()) fail("(g) job not done");
        verify(h, st);
    }
    std::fprintf(stderr, "tenure_harness: concurrent reader OK\n");

    // (h): a storm of jobs with random stops on the real gang.
    std::mt19937_64 r(99);
    const uint64_t builds = std::max(1, storm / 500);
    int jobs = 0;
    for (uint64_t b = 0; b < builds && jobs < storm; ++b) {
        h.build(1000 + b);
        for (int j = 0; j < 500 && jobs < storm; ++j, ++jobs) {
            // A fresh generation of the same arena: gens make old entries unvisited.
            ++h.gen;
            h.dst.reset();
            tw::SerialState st;
            makeJob(h, st, 5000 + static_cast<uint64_t>(jobs));
            std::atomic<bool> stop{false};
            CollectorCtx cc{&h, &st, nullptr, &stop};
            gang.launch(&collectorEntry, &cc, &stop);
            if (r() % 2) {
                if (r() % 4 == 0) std::this_thread::sleep_for(std::chrono::microseconds(r() % 50));
                gang.stopAndJoin();
            } else {
                gang.join();
            }
            if (!st.done()) {
                Env env{h, nullptr};
                if (tw::tenureDrainSerial(st, env, nullptr) != tw::DrainResult::Done) fail("help not done");
            }
            // Verify without healing (the fresh slots must stay pointing into
            // the arena for the next job of this build).
            uint64_t fwd = 0;
            for (uint64_t* o : h.ten_objs) {
                const uint64_t e = h.shadow[static_cast<size_t>(reinterpret_cast<char*>(o) - h.ten.base) >> 3];
                if (tw::genOf(e) == (h.gen & tw::kGenMask) && tw::stateOf(e) == tw::kStateBusy) fail("storm: BUSY");
                if (tw::fwdOf(e, h.gen)) ++fwd;
            }
            if (fwd != st.tenured) fail("storm: forwarded != tenured", fwd, st.tenured);
        }
    }
    std::fprintf(stderr, "tenure_harness: storm of %d jobs OK\n", jobs);
    std::fprintf(stderr, "tenure_harness PASS\n");
    return 0;
}
