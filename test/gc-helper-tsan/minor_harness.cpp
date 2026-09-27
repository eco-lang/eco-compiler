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
// Checks per heap: (a) every reachable object copied exactly once, nothing
// else copied; (b) no slot of a copy or a root points into from-space, and
// every copy's children are the copies of the original's children; (c) no
// BUSY word left; (d) to-space parses (objects + fillers) up to the top and
// the fillers sum to the reported waste; (e) no TSan report.
//
// Build: see CMakeLists.txt. Pass: "minor_harness PASS", exit 0, no TSan report.

#include "GCHelperPool.hpp"
#include "MarkWork.hpp"
#include "MinorWork.hpp"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <sys/mman.h>
#include <random>
#include <unordered_map>
#include <vector>

using namespace Elm;
using namespace Elm::markwork;
namespace mw = Elm::minorwork;

static void fail(const char* what, uint64_t a = 0, uint64_t b = 0) {
    std::fprintf(stderr, "minor_harness FAIL: %s (%llu, %llu)\n", what,
                 (unsigned long long)a, (unsigned long long)b);
    std::exit(1);
}

namespace {

constexpr uint64_t kNode = 1, kCons = 2, kFill = 3;
constexpr size_t kSpineRun = 512;
constexpr uint32_t kChunk = 1024;

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
    Region from, to, old;
    std::vector<uint64_t> roots;
    size_t from_used = 0;       // words
    uint64_t n_objects = 0;
    // promotion arena (the heap's SpinMutex, TSan-tested here)
    mw::SpinMutex promo_mu;
    size_t old_used = 0;        // words (guarded by promo_mu)
};

uint64_t* allocFrom(Heap& h, size_t words) {
    if (h.from_used + words > h.from.words.size()) fail("from-space full");
    uint64_t* p = h.from.words.data() + h.from_used;
    h.from_used += words;
    return p;
}

// Builds a random heap in from-space. Returns the reachable-object count.
void buildHeap(Heap& h, std::mt19937_64& rng) {
    h.from.words.assign(1 << 21, 0);          // 16 MiB
    h.to.words.assign(1 << 21, 0);
    h.old.words.assign(1 << 21, 0);
    h.from_used = 0;
    h.old_used = 0;
    h.roots.clear();
    std::vector<uint64_t*> objs;
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
    // shared tails: a few chains end in another chain's middle
    // slots: random targets among all objects, some constants, some old
    uint64_t* old_obj = h.old.words.data();          // one pre-existing "old" object
    old_obj[0] = mkHeader(kNode, false, 0);
    old_obj[1] = 0;
    h.old_used = 2;
    for (uint64_t* o : objs) {
        if (hTag(o[0]) == kNode) {
            for (uint64_t s = 0; s < hN(o[0]); ++s) {
                const uint64_t r = rnd(10);
                uint64_t v;
                if (r < 6) v = reinterpret_cast<uintptr_t>(objs[rnd(objs.size())]);
                else if (r < 8) v = (rnd(1000) << 1) | 1;
                else if (r < 9) v = reinterpret_cast<uintptr_t>(old_obj);
                else v = 0;
                o[2 + s] = v;
            }
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
    h.roots.push_back(3);       // a constant root
    h.roots.push_back(0);       // a null root
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
};

struct Copier {
    Heap& h;
    unsigned n;
    mw::ToSpace ts;
    std::vector<std::unique_ptr<Worker>> w;

    Copier(Heap& heap, unsigned workers, size_t lab) : h(heap), n(workers) {
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
        if (hAge(hdr)) {
            dst = promoAlloc(words);
            ++wk.promoted;
        } else {
            dst = mw::labAllocate(ts, wk.lab, wk.lc, words * 8, &Copier::fill);
        }
        std::memcpy(dst + 8, obj + 1, (words - 1) * 8);
        reinterpret_cast<uint64_t*>(dst)[0] = hdr;
        mw::publish(obj, dst, mw::colorOf(hdr));
        ++wk.copied;
        return dst;
    }

    uint64_t waitFwd(Worker& wk, uint64_t* obj) {
        ++wk.busy_waits;
        return mw::waitPublished(obj, [&](unsigned r) { backoff(r, wk.ctr); });
    }

    // Evacuates one slot. Returns the (possibly new) value.
    void evacuate(Worker& wk, uint64_t& slot) {
        const uint64_t v = slot;
        if (v == 0 || (v & 1)) return;
        uint64_t* obj = reinterpret_cast<uint64_t*>(v);
        if (!h.from.contains(obj)) return;
        uint64_t hdr = mw::loadHeader(obj);
        for (;;) {
            if (mw::isForwardWord(hdr)) {
                if (hdr == mw::kBusy) { hdr = waitFwd(wk, obj); continue; }
                slot = reinterpret_cast<uintptr_t>(mw::fwdAddr(hdr));
                return;
            }
            if (mw::claim(obj, hdr)) break;
            ++wk.races;
        }
        char* dst = copyClaimed(wk, obj, hdr);
        slot = reinterpret_cast<uintptr_t>(dst);
        pushGrey(wk, objEntry(dst, 0));
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
            if (!h.from.contains(obj)) { evacuate(wk, prev[3]); break; }
            uint64_t hdr = mw::loadHeader(obj);
            if (mw::isForwardWord(hdr)) {
                if (hdr == mw::kBusy) hdr = waitFwd(wk, obj);
                prev[3] = reinterpret_cast<uintptr_t>(mw::fwdAddr(hdr));
                break;
            }
            if (hTag(hdr) != kCons) { evacuate(wk, prev[3]); break; }
            if (k == kSpineRun) {
                pushGrey(wk, objEntry(prev, 0));
                truncated = true;
                break;
            }
            if (!mw::claim(obj, hdr)) { ++wk.races; continue; }
            char* c = copyClaimed(wk, obj, hdr);
            uint64_t* cc = reinterpret_cast<uint64_t*>(c);
            if (cc[2] != 0 && (cc[2] & 1) == 0) needs_heads = true;
            prev[3] = reinterpret_cast<uintptr_t>(c);
            if (k == 0) first = cc;
            prev = cc;
            ++k;
        }
        if (needs_heads && k > 0) {
            const size_t m = truncated ? k - 1 : k;
            uint64_t* c = first;
            for (size_t i = 0; i < m; ++i) {
                evacuate(wk, c[2]);
                c = reinterpret_cast<uint64_t*>(c[3]);
            }
        }
    }

    void scan(Worker& wk, uint64_t e) {
        uint64_t* o = static_cast<uint64_t*>(entryAddr(e));
        const uint64_t hdr = o[0];
        if (isChunk(e)) {
            const uint64_t lo = static_cast<uint64_t>(entryField(e)) * kChunk;
            const uint64_t hi = std::min<uint64_t>(hN(hdr), lo + kChunk);
            for (uint64_t s = lo; s < hi; ++s) evacuate(wk, o[2 + s]);
            return;
        }
        if (hTag(hdr) == kCons) {
            evacuate(wk, o[2]);
            spine(wk, o);
            return;
        }
        const uint64_t ns = hN(hdr);
        uint64_t hi = ns;
        if (ns > kChunk) {
            for (uint64_t c = 1; c * kChunk < ns; ++c) pushGrey(wk, chunkEntry(o, static_cast<uint32_t>(c)));
            hi = kChunk;
        }
        for (uint64_t s = 0; s < hi; ++s) evacuate(wk, o[2 + s]);
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
        for (uint64_t& r : h.roots) evacuate(*w[0], r);
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

// Serial reference: the reachable original objects, by DFS.
std::vector<uint64_t*> reachable(Heap& h) {
    std::vector<uint64_t*> out, st;
    std::unordered_map<uint64_t*, bool> seen;
    auto visit = [&](uint64_t v) {
        if (v == 0 || (v & 1)) return;
        uint64_t* o = reinterpret_cast<uint64_t*>(v);
        if (!h.from.contains(o)) return;
        if (seen.emplace(o, true).second) st.push_back(o);
    };
    for (uint64_t r : h.roots) visit(r);
    while (!st.empty()) {
        uint64_t* o = st.back();
        st.pop_back();
        out.push_back(o);
        if (hTag(o[0]) == kCons) { visit(o[2]); visit(o[3]); }
        else for (uint64_t s = 0; s < hN(o[0]); ++s) visit(o[2 + s]);
    }
    return out;
}

void runOne(uint64_t seed, unsigned n, unsigned jitter, size_t lab) {
    std::mt19937_64 rng(seed);
    static Heap h;
    buildHeap(h, rng);
    const std::vector<uint64_t*> reach = reachable(h);
    // Snapshot the originals (the GC overwrites their headers).
    std::unordered_map<uint64_t*, std::vector<uint64_t>> orig;
    orig.reserve(reach.size() * 2);
    for (uint64_t* o : reach) orig[o] = std::vector<uint64_t>(o, o + objWords(o[0]));
    const std::vector<uint64_t> roots0 = h.roots;
    const size_t old_used0 = h.old_used;

    Copier c(h, n, lab);
    const uint64_t fillers = c.run(jitter);

    // (a) exactly-once
    uint64_t copied = 0;
    for (unsigned i = 0; i < n; ++i) copied += c.w[i]->copied;
    if (copied != reach.size()) fail("copied != reachable", copied, reach.size());
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

}  // namespace

int main(int argc, char** argv) {
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
