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

#include "GCHelperPool.hpp"
#include "TenureWork.hpp"

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <sys/mman.h>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>

using namespace Elm;
namespace tw = Elm::tenurework;

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
    Arena ten, fresh, old, ylos, dst;
    std::vector<uint64_t> shadow;         // one per 8-byte granule of `ten`
    std::vector<uint64_t*> ten_objs, fresh_objs, old_objs, ylos_objs;
    uint32_t gen = 0;
    std::mt19937_64 rng;

    void init() {
        ten.init(64ull << 20);
        fresh.init(16ull << 20);
        old.init(4ull << 20);
        ylos.init(4ull << 20);
        dst.init(96ull << 20);
        shadow.assign((64ull << 20) / 8, 0);
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
        ten.reset(); fresh.reset(); old.reset(); ylos.reset(); dst.reset();
        ten_objs.clear(); fresh_objs.clear(); old_objs.clear(); ylos_objs.clear();
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
    st.clearProgress();
}

// Checks (a)-(e) after a finished job, then heals the fresh slots.
void verify(Heap& h, tw::SerialState& st) {
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

}  // namespace

int main(int argc, char** argv) {
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
        std::thread reader([&] {
            uint64_t sum = 0;
            while (!done.load(std::memory_order_acquire)) {
                for (uint64_t* o : h.ten_objs) sum += o[1] + hN(o[0]);
                for (uint64_t* s : st.heal) sum += *s;
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
