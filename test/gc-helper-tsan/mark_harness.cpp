// threaded-gc-05b (plans/threaded-gc-05b-parallel-marking.md Step 5): the TSan
// harness for the parallel marker's std-only core -- WorkStealingDeque,
// GCMarkGang and the REAL markwork::runMarkerLoop on a synthetic heap.
//
//   (1) deque storm: one owner (random push/take) + thieves; every value
//       consumed exactly once, with growth from a tiny initial array;
//   (2) gang storm: many runs at n = 2..8, with and without jitter;
//   (3) synthetic marker: a random graph with atomic mark bits and chunked
//       "large" nodes, marked in slices with random budgets. Checks:
//       (a) the marked set == the reachable set;
//       (b) each slice consumes exactly min(budget, entries remaining);
//       (c) per-slice consumption is identical at n = 1, 2, 4, 8 and with jitter.
//
// Build: see CMakeLists.txt (g++ -fsanitize=thread). Pass: exit 0, no TSan report.

#include "GCHelperPool.hpp"
#include "MarkWork.hpp"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <random>
#include <string>
#include <thread>
#include <vector>

using namespace Elm;
using namespace Elm::markwork;
#if ECO_TLA_TRACE_ENABLED
namespace tlatrace = Elm::tlatrace;
#endif

static void fail(const char* what) {
    std::fprintf(stderr, "mark_harness FAIL: %s\n", what);
    std::exit(1);
}

// ---------------------------------------------------------------------------
// (1) deque storm
// ---------------------------------------------------------------------------
static void dequeStorm(unsigned thieves, uint64_t ops) {
    WorkStealingDeque dq(/*log_initial=*/4);
    const uint64_t n_values = ops / 2;
    std::vector<std::atomic<uint8_t>> seen(n_values + 1);
    std::atomic<bool> stop{false};
    std::atomic<uint64_t> consumed{0};
    auto consume = [&](uint64_t v) {
        if (v == 0 || v > n_values) fail("deque: bad value");
        if (seen[v].fetch_add(1) != 0) fail("deque: value consumed twice");
        consumed.fetch_add(1);
    };
    std::vector<std::thread> ts;
    for (unsigned t = 0; t < thieves; ++t) {
        ts.emplace_back([&] {
            while (!stop.load(std::memory_order_acquire)) {
                const uint64_t e = dq.steal();
                if (e != kEmpty && e != kAbort) consume(e);
            }
        });
    }
    std::mt19937_64 rng(42);
    uint64_t next = 1;
    while (next <= n_values) {
        if ((rng() & 3) != 0) {
            dq.push(next++);
        } else {
            const uint64_t e = dq.take();
            if (e != kEmpty) consume(e);
        }
    }
    for (;;) {
        const uint64_t e = dq.take();
        if (e == kEmpty) break;
        consume(e);
    }
    while (consumed.load() < n_values) std::this_thread::yield();
    stop.store(true, std::memory_order_release);
    for (auto& t : ts) t.join();
    dq.retireOldArrays();
    for (uint64_t v = 1; v <= n_values; ++v)
        if (seen[v].load() != 1) fail("deque: value lost");
    std::printf("deque storm: %u thieves, %llu values ok (grows %llu)\n", thieves,
                (unsigned long long)n_values, (unsigned long long)dq.grows());
}

// ---------------------------------------------------------------------------
// (2) gang storm
// ---------------------------------------------------------------------------
static void gangStorm(unsigned runs, unsigned jitter) {
    auto& g = gc::GCMarkGang::instance();
    if (g.configured()) g.shutdownForTesting();
    g.configure(8, jitter);
    struct Ctx { std::atomic<uint64_t> hits[8]; } ctx;
    for (unsigned r = 0; r < runs; ++r) {
        const unsigned n = 2 + r % 7;
        for (auto& h : ctx.hits) h.store(0);
        g.run([](void* c, unsigned i) { static_cast<Ctx*>(c)->hits[i].fetch_add(1); }, &ctx, n);
        for (unsigned i = 0; i < 8; ++i) {
            if (ctx.hits[i].load() != (i < n ? 1u : 0u)) fail("gang: member ran wrong number of times");
        }
    }
    std::printf("gang storm: %u runs ok (jitter %u us)\n", runs, jitter);
}

// ---------------------------------------------------------------------------
// (3) synthetic marker
// ---------------------------------------------------------------------------
constexpr uint32_t kChunk = 64;

struct Graph {
    std::vector<std::vector<uint32_t>> kids;
    std::vector<uint32_t> roots;
};

static Graph makeGraph(uint32_t nodes, uint64_t seed) {
    Graph g;
    g.kids.resize(nodes);
    std::mt19937_64 rng(seed);
    for (uint32_t i = 0; i < nodes; ++i) {
        const bool big = (rng() % 100) < 2;
        const uint32_t deg = big ? 200 + static_cast<uint32_t>(rng() % 300) : static_cast<uint32_t>(rng() % 5);
        for (uint32_t k = 0; k < deg; ++k) g.kids[i].push_back(static_cast<uint32_t>(rng() % nodes));
    }
    for (int r = 0; r < 50; ++r) g.roots.push_back(static_cast<uint32_t>(rng() % nodes));
    return g;
}

struct SynthHeap {
    const Graph& g;
    unsigned n;
    std::unique_ptr<std::atomic<uint8_t>[]> marks;
    // Mirrors OldGenSpace::MarkWorker + ParallelEnv (plan P§10.1 item 1):
    // a PRIVATE owner-only stack, published half at a time to the deque.
    struct Worker {
        WorkStealingDeque dq{4};
        std::vector<uint64_t> stack;
        std::atomic<uint64_t> priv{0};
        uint64_t pops = 0;
        MarkerCounters ctr;
        unsigned slot = 0;
    };
    std::vector<std::unique_ptr<Worker>> w;
    unsigned pace_us = 0;             // M2's trace scenarios: a random pause per scan
    SynthHeap(const Graph& gr, unsigned members) : g(gr), n(members),
        marks(new std::atomic<uint8_t>[gr.kids.size()]) {
        for (size_t i = 0; i < gr.kids.size(); ++i) marks[i].store(0);
        for (unsigned i = 0; i < members; ++i) {
            w.push_back(std::make_unique<Worker>());
            w.back()->slot = i;
        }
    }
    // The M2 trace events (test/tla/M2-slice-control/MAPPING.md): each deque
    // push of a publish ("mw.pub", which the steal of that entry follows), the
    // priv store that ends it ("mw.priv"), and each private push ("mw.push").
    static constexpr size_t kPublishMin = 64;
    void publishHalf(Worker& x) {
        if (x.stack.size() < kPublishMin || !x.dq.emptyApprox()) return;
        const size_t half = x.stack.size() / 2;
        for (size_t i = 0; i < half; ++i) {
            x.dq.push(x.stack[i]);
            ECO_TLA_TRACE("mw.pub", "w", x.slot, "e", x.stack[i],
                          "put", tlatrace::key("mwe", static_cast<int64_t>(x.stack[i])));
        }
        x.stack.erase(x.stack.begin(), x.stack.begin() + static_cast<std::ptrdiff_t>(half));
        x.priv.store(x.stack.size(), std::memory_order_relaxed);
        ECO_TLA_TRACE("mw.priv", "w", x.slot, "cnt", x.stack.size());
    }
    void pushGrey(unsigned self, uint64_t e) {
        Worker& x = *w[self];
        x.stack.push_back(e);
        x.priv.store(x.stack.size(), std::memory_order_relaxed);
        ECO_TLA_TRACE("mw.push", "w", self, "e", e);
        if ((x.stack.size() & 31) == 0) publishHalf(x);
    }
    void publishAll(unsigned self) {
        Worker& x = *w[self];
        ECO_TLA_TRACE_ONLY(const bool some = !x.stack.empty();)
        for (uint64_t e : x.stack) {
            x.dq.push(e);
            ECO_TLA_TRACE("mw.pub", "w", self, "e", e, "put", tlatrace::key("mwe", static_cast<int64_t>(e)));
        }
        x.stack.clear();
        x.priv.store(0, std::memory_order_relaxed);
        ECO_TLA_TRACE_ONLY(if (some)) ECO_TLA_TRACE("mw.priv", "w", self, "cnt", 0);
    }
    uint64_t takeOwn(unsigned self) {
        Worker& x = *w[self];
        if (!x.stack.empty()) {
            const uint64_t e = x.stack.back();
            x.stack.pop_back();
            x.priv.store(x.stack.size(), std::memory_order_relaxed);
            if ((++x.pops & 63) == 0) publishHalf(x);
            return e;
        }
        return x.dq.take();
    }
    bool empty() const {
        for (auto& x : w) if (!x->dq.emptyApprox() || !x->stack.empty()) return false;
        return true;
    }
    void pace() const {
        thread_local uint64_t r = 0x9E3779B97F4A7C15ull ^ reinterpret_cast<uintptr_t>(&r);
        r ^= r << 13; r ^= r >> 7; r ^= r << 17;
        const unsigned us = static_cast<unsigned>(r % (pace_us + 1));
        if (us > pace_us / 2) std::this_thread::sleep_for(std::chrono::microseconds(us));
    }
    // Entries: object = index + 1; chunk = kChunkBit | (index + 1) | (c << 40).
    void grey(unsigned self, uint32_t idx) {
        if (marks[idx].exchange(1, std::memory_order_relaxed) != 0) return;
        pushGrey(self, uint64_t{idx} + 1);
    }
    void scanRange(unsigned self, uint32_t idx, uint32_t lo, uint32_t hi) {
        for (uint32_t k = lo; k < hi; ++k) grey(self, g.kids[idx][k]);
    }
    void scan(unsigned self, uint64_t e) {
        const uint32_t idx = static_cast<uint32_t>((e & kAddrMask) - 1);
        const auto& ks = g.kids[idx];
        // Pause only while holding no private work: with priv counted, an idle
        // member re-wakes, fails to steal and idles again for as long as another
        // holds private work (a real cost of ParallelEnv's anyWork), and a pause
        // there made one trace 22,000 events long.
        if (pace_us != 0 && w[self]->stack.empty()) pace();
        if (isChunk(e)) {
            const uint32_t c = entryField(e);
            scanRange(self, idx, c * kChunk, std::min<uint32_t>(ks.size(), (c + 1) * kChunk));
            return;
        }
        scanRange(self, idx, 0, std::min<uint32_t>(ks.size(), kChunk));
        for (uint32_t c = 1; uint64_t{c} * kChunk < ks.size(); ++c)
            pushGrey(self, kChunkBit | (uint64_t{idx} + 1) | (uint64_t{c} << 40));
    }
};

struct SynthEnv {
    static constexpr bool kParallel = true;
    SynthHeap& h;
    MarkerCounters& counters(unsigned i) { return h.w[i]->ctr; }
    uint64_t takeOwn(unsigned i) { return h.takeOwn(i); }
    uint64_t stealFrom(unsigned v) { return h.w[v]->dq.steal(); }
    bool anyWork() {
        for (auto& x : h.w)
            if (!x->dq.emptyApprox() || x->priv.load(std::memory_order_relaxed) != 0) return true;
        return false;
    }
    void prefetch(uint64_t) {}
    void scan(unsigned self, uint64_t e) { h.scan(self, e); }
    void publishAll(unsigned self) { h.publishAll(self); }
};

struct RunArgs { SynthHeap* h; SliceControl* c; };

static void markerFn(void* ctx, unsigned member) {
    auto* a = static_cast<RunArgs*>(ctx);
    SynthEnv env{*a->h};
    runMarkerLoop(env, member, *a->c);
}

// Returns the per-slice consumption sequence.
static std::vector<uint64_t> synthMark(const Graph& g, unsigned n, unsigned jitter,
                                       const std::vector<int64_t>& budgets) {
    auto& gang = gc::GCMarkGang::instance();
    if (gang.configured()) gang.shutdownForTesting();
    gang.configure(n, jitter);
    SynthHeap h(g, n);
    for (uint32_t r : g.roots) h.grey(0, r);            // the "t0 snapshot", on member 0
    std::vector<uint64_t> per_slice;
    for (int64_t b : budgets) {
        SliceControl c(b, n, jitter);
        for (unsigned i = 0; i < n; ++i) h.w[i]->ctr.resetRun(i);
        RunArgs args{&h, &c};
        gang.run(&markerFn, &args, n);
        uint64_t units = 0;
        for (auto& x : h.w) { units += x->ctr.units; x->dq.retireOldArrays(); }
        if (static_cast<int64_t>(units) != b - c.budget.load()) fail("synth: units != consumed tickets");
        if (c.active() != 0 || !c.done()) fail("synth: a marker left active");
        per_slice.push_back(units);
    }
    // Finish with a drain; then compare with the reachable set.
    SliceControl c(kDrainBudget, n, jitter);
    for (unsigned i = 0; i < n; ++i) h.w[i]->ctr.resetRun(i);
    RunArgs args{&h, &c};
    gang.run(&markerFn, &args, n);
    uint64_t drain = 0;
    for (auto& x : h.w) drain += x->ctr.units;
    if (!h.empty()) fail("synth: work left after drain");
    per_slice.push_back(drain);
    // Reachability (serial BFS).
    std::vector<uint8_t> reach(g.kids.size(), 0);
    std::vector<uint32_t> st(g.roots.begin(), g.roots.end());
    uint64_t entries = 0;
    while (!st.empty()) {
        const uint32_t i = st.back();
        st.pop_back();
        if (reach[i]) continue;
        reach[i] = 1;
        entries += 1 + (g.kids[i].size() > kChunk ? (g.kids[i].size() - 1) / kChunk : 0);
        for (uint32_t k : g.kids[i]) st.push_back(k);
    }
    for (size_t i = 0; i < g.kids.size(); ++i)
        if ((h.marks[i].load() != 0) != (reach[i] != 0)) fail("synth: marked set != reachable set");
    // (b): each slice consumed min(budget, remaining).
    uint64_t done = 0;
    for (size_t k = 0; k < budgets.size(); ++k) {
        const uint64_t expect = std::min<uint64_t>(static_cast<uint64_t>(budgets[k]), entries - done);
        if (per_slice[k] != expect) fail("synth: slice consumption != min(budget, remaining)");
        done += per_slice[k];
    }
    if (done + drain != entries) fail("synth: total consumption != entries");
    return per_slice;
}

// (4) termination-race stress (plan P§10.1 item 10): a single chain, so all
// the work sits on one marker's private stack while the others keep deciding
// termination, over thousands of 1-3-ticket slices. A slice that ends early
// (with work and budget left) consumes less than min(budget, remaining).
static void terminationStress(unsigned n, int slices) {
    Graph g;
    const uint32_t len = 60000;
    g.kids.resize(len);
    for (uint32_t i = 0; i + 1 < len; ++i) g.kids[i].push_back(i + 1);
    g.roots.push_back(0);
    auto& gang = gc::GCMarkGang::instance();
    if (gang.configured()) gang.shutdownForTesting();
    gang.configure(n, 0);
    SynthHeap h(g, n);
    h.grey(0, 0);
    std::mt19937_64 rng(5);
    uint64_t done = 0;
    for (int k = 0; k < slices && !h.empty(); ++k) {
        const int64_t b = 1 + static_cast<int64_t>(rng() % 3);
        SliceControl c(b, n, 0);
        for (unsigned i = 0; i < n; ++i) h.w[i]->ctr.resetRun(i);
        RunArgs args{&h, &c};
        gang.run(&markerFn, &args, n);
        uint64_t units = 0;
        for (auto& x : h.w) { units += x->ctr.units; x->dq.retireOldArrays(); }
        if (units != static_cast<uint64_t>(std::min<int64_t>(b, static_cast<int64_t>(len - done)))) {
            std::fprintf(stderr, "slice %d: budget %lld consumed %llu with %llu entries left\n", k,
                         (long long)b, (unsigned long long)units, (unsigned long long)(len - done));
            fail("termination: a slice ended with work and budget left");
        }
        done += units;
    }
    std::printf("termination stress: n = %u, %llu entries in 1-3-ticket slices ok\n", n,
                (unsigned long long)done);
}

// ---------------------------------------------------------------------------
// (5) threaded-gc-05c episode storm (plans/threaded-gc-05c-concurrent-marking.md
// P§4 Step 3): B background Members run a drain episode on a GCBackgroundGang
// while a "mutator" thread, at random, (a) joins as Assists with a bounded
// pool, (b) fetch_ors "allocate-black" bits into bytes the markers share,
// (c) stops the episode and relaunches a fresh one, and finally (d) joins as
// Members until termination. Mark bits are PACKED (8 nodes a byte) so the
// mutator's bits and the markers' bits share bytes. Phantom nodes (idx % 8 ==
// 7) are never reachable and are set only by the mutator. Checks: the marked
// real nodes == the reachable set; every phantom bit set by the mutator
// survives; the total units == the entry count; no private work after a run.
// ---------------------------------------------------------------------------
struct PackedHeap {
    const Graph& g;
    unsigned n;                       // slots
    std::unique_ptr<std::atomic<uint8_t>[]> bits;
    struct Worker {
        WorkStealingDeque dq{4};
        std::vector<uint64_t> stack;
        std::atomic<uint64_t> priv{0};
        uint64_t pops = 0;
        MarkerCounters ctr;
    };
    std::vector<std::unique_ptr<Worker>> w;
    PackedHeap(const Graph& gr, unsigned slots) : g(gr), n(slots),
        bits(new std::atomic<uint8_t>[(gr.kids.size() + 7) / 8]) {
        for (size_t i = 0; i < (gr.kids.size() + 7) / 8; ++i) bits[i].store(0);
        for (unsigned i = 0; i < slots; ++i) w.push_back(std::make_unique<Worker>());
    }
    bool marked(uint32_t idx) const { return (bits[idx / 8].load() >> (idx % 8)) & 1u; }
    void setBit(uint32_t idx) { bits[idx / 8].fetch_or(uint8_t(1u << (idx % 8)), std::memory_order_relaxed); }
    static constexpr size_t kPublishMin = 64;
    void publishHalf(Worker& x) {
        if (x.stack.size() < kPublishMin || !x.dq.emptyApprox()) return;
        const size_t half = x.stack.size() / 2;
        for (size_t i = 0; i < half; ++i) x.dq.push(x.stack[i]);
        x.stack.erase(x.stack.begin(), x.stack.begin() + static_cast<std::ptrdiff_t>(half));
        x.priv.store(x.stack.size(), std::memory_order_relaxed);
    }
    void publishAll(unsigned self) {
        Worker& x = *w[self];
        for (uint64_t e : x.stack) x.dq.push(e);
        x.stack.clear();
        x.priv.store(0, std::memory_order_relaxed);
    }
    void pushGrey(unsigned self, uint64_t e) {
        Worker& x = *w[self];
        x.stack.push_back(e);
        x.priv.store(x.stack.size(), std::memory_order_relaxed);
        if ((x.stack.size() & 31) == 0) publishHalf(x);
    }
    uint64_t takeOwn(unsigned self) {
        Worker& x = *w[self];
        if (!x.stack.empty()) {
            const uint64_t e = x.stack.back();
            x.stack.pop_back();
            x.priv.store(x.stack.size(), std::memory_order_relaxed);
            if ((++x.pops & 63) == 0) publishHalf(x);
            return e;
        }
        return x.dq.take();
    }
    void grey(unsigned self, uint32_t idx) {
        std::atomic<uint8_t>& b = bits[idx / 8];
        const uint8_t m = uint8_t(1u << (idx % 8));
        if (b.load(std::memory_order_relaxed) & m) return;          // test before set
        if (b.fetch_or(m, std::memory_order_relaxed) & m) return;
        pushGrey(self, uint64_t{idx} + 1);
    }
    void scan(unsigned self, uint64_t e) {
        const uint32_t idx = static_cast<uint32_t>((e & kAddrMask) - 1);
        const auto& ks = g.kids[idx];
        if (isChunk(e)) {
            const uint32_t c = entryField(e);
            for (uint32_t k = c * kChunk; k < std::min<uint32_t>(ks.size(), (c + 1) * kChunk); ++k) grey(self, ks[k]);
            return;
        }
        for (uint32_t k = 0; k < std::min<uint32_t>(ks.size(), kChunk); ++k) grey(self, ks[k]);
        for (uint32_t c = 1; uint64_t{c} * kChunk < ks.size(); ++c)
            pushGrey(self, kChunkBit | (uint64_t{idx} + 1) | (uint64_t{c} << 40));
    }
    bool empty() const {
        for (auto& x : w) if (!x->dq.emptyApprox() || !x->stack.empty()) return false;
        return true;
    }
};

struct PackedEnv {
    static constexpr bool kParallel = true;
    PackedHeap& h;
    MarkerCounters& counters(unsigned i) { return h.w[i]->ctr; }
    uint64_t takeOwn(unsigned i) { return h.takeOwn(i); }
    uint64_t stealFrom(unsigned v) { return h.w[v]->dq.steal(); }
    bool anyWork() {
        for (auto& x : h.w)
            if (!x->dq.emptyApprox() || x->priv.load(std::memory_order_relaxed) != 0) return true;
        return false;
    }
    void prefetch(uint64_t) {}
    void scan(unsigned self, uint64_t e) { h.scan(self, e); }
    void publishAll(unsigned self) { h.publishAll(self); }
};

struct EpisodeCtx {
    PackedHeap* h;
    SliceControl* c;
    unsigned F;                       // foreground slots 0..F-1, background F..
    std::atomic<int64_t>* pool;
};

static Graph makePackedGraph(uint32_t nodes, uint64_t seed) {
    // Real nodes: idx % 8 != 7. Phantom nodes are never a child or a root.
    Graph g;
    g.kids.resize(nodes);
    std::mt19937_64 rng(seed);
    auto real = [&]() { uint32_t v; do { v = static_cast<uint32_t>(rng() % nodes); } while (v % 8 == 7); return v; };
    for (uint32_t i = 0; i < nodes; ++i) {
        if (i % 8 == 7) continue;
        const bool big = (rng() % 100) < 2;
        const uint32_t deg = big ? 200 + static_cast<uint32_t>(rng() % 300) : static_cast<uint32_t>(rng() % 5);
        for (uint32_t k = 0; k < deg; ++k) g.kids[i].push_back(real());
    }
    for (int r = 0; r < 50; ++r) g.roots.push_back(real());
    return g;
}

static void episodeStorm(unsigned F, unsigned B, unsigned jitter, uint64_t seed) {
    const Graph g = makePackedGraph(80000, seed);
    const unsigned slots = F + B;
    PackedHeap h(g, slots);
    for (uint32_t r : g.roots) h.grey(0, r);        // the t0 snapshot on slot 0
    h.publishAll(0);
    auto& fg = gc::GCMarkGang::instance();
    if (fg.configured()) fg.shutdownForTesting();
    fg.configure(F, jitter);
    gc::GCBackgroundGang::Options o;
    o.members = B;
    o.jitter_us = jitter;
    gc::GCBackgroundGang bg(o);
    std::mt19937_64 rng(seed * 7 + 1);
    uint64_t units = 0;
    auto sumUnits = [&](unsigned lo, unsigned hi) {
        for (unsigned i = lo; i < hi; ++i) { units += h.w[i]->ctr.units; h.w[i]->ctr.resetRun(i); }
    };
    auto noPrivate = [&](unsigned lo, unsigned hi, const char* where) {
        for (unsigned i = lo; i < hi; ++i) {
            if (!h.w[i]->stack.empty() || h.w[i]->priv.load() != 0) {
                std::fprintf(stderr, "slot %u after %s\n", i, where);
                fail("episode: private work left after a run");
            }
        }
    };
    std::vector<uint32_t> phantoms;
    int stops = 0, assists = 0, episodes = 0;
    bool finished = false;
    while (!finished) {
        auto c = std::make_unique<SliceControl>(kDrainBudget, slots, jitter, static_cast<int64_t>(B));
        EpisodeCtx ctx{&h, c.get(), F, nullptr};
        for (unsigned i = F; i < slots; ++i) h.w[i]->ctr.resetRun(i);
        ++episodes;
        bg.launch([](void* p, unsigned j) {
            auto* x = static_cast<EpisodeCtx*>(p);
            PackedEnv env{*x->h};
            runMarkerLoop(env, x->F + j, *x->c, x->c->budget, Role::Member, false);
        }, &ctx, &c->stop);
        bool stopped = false;
        for (int act = 0; act < 40 && !stopped; ++act) {
            const unsigned what = static_cast<unsigned>(rng() % 10);
            if (what < 4) {                             // (a) assist
                std::atomic<int64_t> pool{1 + static_cast<int64_t>(rng() % 3000)};
                const int64_t b0 = pool.load();
                EpisodeCtx a{&h, c.get(), F, &pool};
                c->share_epoch.fetch_add(1, std::memory_order_relaxed);
                for (unsigned i = 0; i < F; ++i) h.w[i]->ctr.resetRun(i);
                fg.run([](void* p, unsigned i) {
                    auto* x = static_cast<EpisodeCtx*>(p);
                    PackedEnv env{*x->h};
                    runMarkerLoop(env, i, *x->c, *x->pool, Role::Assist, true);
                }, &a, F);
                uint64_t fu = 0;
                for (unsigned i = 0; i < F; ++i) fu += h.w[i]->ctr.units;
                if (static_cast<int64_t>(fu) != b0 - pool.load()) fail("assist: units != consumed tickets");
                sumUnits(0, F);
                noPrivate(0, F, "an assist");
                ++assists;
            } else if (what < 8) {                      // (b) allocate-black on shared bytes
                for (int k = 0; k < 64; ++k) {
                    const uint32_t ph = static_cast<uint32_t>((rng() % (g.kids.size() / 8)) * 8 + 7);
                    h.setBit(ph);
                    phantoms.push_back(ph);
                }
            } else if (what == 8 && stops < 6) {        // (c) stop and relaunch
                bg.stopAndJoin();
                sumUnits(F, slots);
                noPrivate(0, slots, "a stop");
                for (auto& x : h.w) x->dq.retireOldArrays();
                ++stops;
                stopped = true;
            } else {
                std::this_thread::sleep_for(std::chrono::microseconds(rng() % 200));
            }
        }
        if (stopped) {
            if (h.empty()) finished = true;
            continue;
        }
        // (d) the closing join: foreground Members until termination.
        EpisodeCtx cl{&h, c.get(), F, nullptr};
        c->share_epoch.fetch_add(1, std::memory_order_relaxed);
        for (unsigned i = 0; i < F; ++i) h.w[i]->ctr.resetRun(i);
        fg.run([](void* p, unsigned i) {
            auto* x = static_cast<EpisodeCtx*>(p);
            PackedEnv env{*x->h};
            runMarkerLoop(env, i, *x->c, x->c->budget, Role::Member, true);
        }, &cl, F);
        sumUnits(0, F);
        bg.join();
        if (!c->done()) fail("episode: closing join returned before termination");
        sumUnits(F, slots);
        noPrivate(0, slots, "the closing");
        for (auto& x : h.w) x->dq.retireOldArrays();
        if (!h.empty()) fail("episode: work left after termination");
        finished = true;
    }
    // Reachability and exact units.
    std::vector<uint8_t> reach(g.kids.size(), 0);
    std::vector<uint32_t> st(g.roots.begin(), g.roots.end());
    uint64_t entries = 0;
    while (!st.empty()) {
        const uint32_t i = st.back();
        st.pop_back();
        if (reach[i]) continue;
        reach[i] = 1;
        entries += 1 + (g.kids[i].size() > kChunk ? (g.kids[i].size() - 1) / kChunk : 0);
        for (uint32_t k : g.kids[i]) st.push_back(k);
    }
    for (size_t i = 0; i < g.kids.size(); ++i) {
        if (i % 8 == 7) continue;
        if (h.marked(static_cast<uint32_t>(i)) != (reach[i] != 0)) fail("episode: marked set != reachable set");
    }
    for (uint32_t ph : phantoms) if (!h.marked(ph)) fail("episode: a mutator (allocate-black) bit was lost");
    if (units != entries) {
        std::fprintf(stderr, "units %llu entries %llu\n", (unsigned long long)units, (unsigned long long)entries);
        fail("episode: total units != entries");
    }
    std::printf("episode storm: F=%u B=%u jitter %u: %d episodes, %d assists, %d stops, %zu black bits ok\n",
                F, B, jitter, episodes, assists, stops, phantoms.size());
}

// (6) threaded-gc-05c bg-gang storm: launch/join and stop/join cycles.
static void bgGangStorm(unsigned launches, unsigned stops) {
    std::mt19937_64 rng(3);
    for (unsigned m = 1; m <= 8; m *= 2) {
        gc::GCBackgroundGang::Options o;
        o.members = m;
        gc::GCBackgroundGang g(o);
        std::atomic<bool> stop{false};
        std::atomic<uint64_t> hits{0};
        struct Ctx { std::atomic<bool>* s; std::atomic<uint64_t>* h; } ctx{&stop, &hits};
        for (unsigned r = 0; r < launches / 4; ++r) {
            g.launch([](void* p, unsigned) { static_cast<Ctx*>(p)->h->fetch_add(1); }, &ctx, &stop);
            if (rng() & 1) { while (!g.finishedApprox()) std::this_thread::yield(); }
            g.join();
        }
        if (hits.load() != uint64_t{launches / 4} * m) fail("bg gang: a member ran a wrong number of times");
        for (unsigned r = 0; r < stops / 4; ++r) {
            stop.store(false);
            g.launch([](void* p, unsigned) {
                auto* x = static_cast<Ctx*>(p);
                while (!x->s->load(std::memory_order_acquire)) std::this_thread::yield();
            }, &ctx, &stop);
            g.stopAndJoin();
            if (g.running()) fail("bg gang: running after stopAndJoin");
        }
    }
    std::printf("bg gang storm: %u launches, %u stops per size ok\n", launches / 4, stops / 4);
}

// ---------------------------------------------------------------------------
// (7) M2's TLA+ trace scenarios (plans/threaded-gc-tla-M2-slice-control.md §8;
// test/tla/M2-slice-control/MAPPING.md, "Trace validation"). Small instances of
// (3)/(4) and (5) on SynthHeap: in the TRACE build (gc-mark-trace,
// -DECO_TLA_TRACE=1) each run is recorded to $ECO_TLA_TRACE_OUT (MarkWork.hpp's
// "mw." hooks, SynthHeap's push/publish events, the gangs' ordering events).
//
// The graph: root 0 -> {1, hub}; the chain 1 -> 2 -> ... -> L; node 2 -> hub
// too (two parents: the mark test-and-set can race); hub -> F leaves (F <= 64,
// so no chunk entries; F = 64 makes pushGrey's publishHalf reachable). Kids in
// ascending id order: the model greys children in id order. Model ids are
// index + 1 (SynthHeap's object entries).
//
//   slices <n> <L> <F> <slices> <max budget> <seed> <pace us>
//       n Members (GCMarkGang; member 0 is this thread), the root on slot 0's
//       private stack; up to <slices> slices of 1..<max budget> tickets, then
//       a drain (kDrainBudget) if work is left.
//   episode <B> <L> <F> <assists> <assist budget> <end> <seed> <pace us>
//       a drain episode of B background Members (slots 1..B; the root in slot
//       1's deque, as launchBackground), this thread as slot 0: <assists>
//       assists of <assist budget> tickets, then <end> 0: the closing join;
//       1: a stop (stopAndJoin); 2: the closing join once the members have
//       returned (closingFinish's join when finishedApprox lags: the join
//       finds the control done).
// ---------------------------------------------------------------------------
static Graph traceGraph(uint32_t L, uint32_t F) {
    Graph g;
    const uint32_t hub = L + 1;
    g.kids.resize(L + 2 + F);
    g.kids[0].push_back(1);
    if (F > 0) g.kids[0].push_back(hub);
    for (uint32_t i = 1; i < L; ++i) g.kids[i].push_back(i + 1);
    if (F > 0 && L >= 2) g.kids[2].push_back(hub);
    for (uint32_t k = 0; k < F; ++k) g.kids[hub].push_back(hub + 1 + k);
    for (auto& ks : g.kids) std::sort(ks.begin(), ks.end());
    g.roots.push_back(0);
    return g;
}

static std::string traceGraphJson(const Graph& g) {
    std::string j = "\"nodes\":" + std::to_string(g.kids.size()) + ",\"edges\":[";
    bool first = true;
    for (size_t i = 0; i < g.kids.size(); ++i)
        for (uint32_t k : g.kids[i]) {
            j += (first ? "[" : ",[") + std::to_string(i + 1) + "," + std::to_string(k + 1) + "]";
            first = false;
        }
    return j + "]";
}

static std::string traceSeq(const std::vector<uint64_t>& v) {
    std::string j = "[";
    for (size_t i = 0; i < v.size(); ++i) j += (i ? "," : "") + std::to_string(v[i]);
    return j + "]";
}

static uint64_t reachEntries(const Graph& g) {
    std::vector<uint8_t> reach(g.kids.size(), 0);
    std::vector<uint32_t> st(g.roots.begin(), g.roots.end());
    uint64_t entries = 0;
    while (!st.empty()) {
        const uint32_t i = st.back();
        st.pop_back();
        if (reach[i]) continue;
        reach[i] = 1;
        ++entries;
        for (uint32_t k : g.kids[i]) st.push_back(k);
    }
    return entries;
}

static void traceBegin(const std::string& hdr) {
#if ECO_TLA_TRACE_ENABLED
    tlatrace::nameThread("mut", -1);
    tlatrace::begin(hdr, "mw.,gang.");
#else
    (void)hdr;
#endif
}

static void traceEnd() {
#if ECO_TLA_TRACE_ENABLED
    if (!tlatrace::end(nullptr)) fail("trace: cannot write the log");
#endif
}

static void traceSlices(unsigned n, uint32_t L, uint32_t F, int slices, int maxb, uint64_t seed,
                        unsigned pace) {
    if (n < 1 || n > 8 || F > kChunk || maxb < 1) fail("slices: bad arguments");
    const Graph g = traceGraph(L, F);
    auto& gang = gc::GCMarkGang::instance();
    if (gang.configured()) gang.shutdownForTesting();
    gang.configure(n, 0);
    SynthHeap h(g, n);
    h.pace_us = pace;
    h.grey(0, 0);                                    // the t0 grey, on slot 0's private stack
    traceBegin("{\"model\":\"M2\",\"scenario\":\"slices\",\"n\":" + std::to_string(n) + "," +
               traceGraphJson(g) + ",\"stack0\":" + traceSeq(h.w[0]->stack) + "}");
    std::mt19937_64 rng(seed);
    const uint64_t entries = reachEntries(g);
    uint64_t done = 0;
    for (int k = 0; k <= slices && !h.empty(); ++k) {
        const bool drain = k == slices;
        const int64_t b = drain ? kDrainBudget : 1 + static_cast<int64_t>(rng() % static_cast<uint64_t>(maxb));
        SliceControl c(b, n, 0);
        for (unsigned i = 0; i < n; ++i) h.w[i]->ctr.resetRun(i);
        ECO_TLA_TRACE("mw.ctl", "ctl", c.tla_ctl, "budget", drain ? 0 : b, "drain", drain, "active", n,
                      "victims", n);
        RunArgs args{&h, &c};
        gang.run(&markerFn, &args, n);
        uint64_t units = 0;
        for (auto& x : h.w) { units += x->ctr.units; x->dq.retireOldArrays(); }
        ECO_TLA_TRACE("mw.end", "ctl", c.tla_ctl, "units", units, "left", drain ? 0 : c.budget.load(),
                      "done", c.done());
        if (!drain && static_cast<int64_t>(units) != b - c.budget.load()) fail("slices: units != consumed tickets");
        if (c.active() != 0 || !c.done()) fail("slices: a marker left the slice active");
        if (units != std::min<uint64_t>(static_cast<uint64_t>(b), entries - done)) fail("slices: early end");
        done += units;
    }
    if (!h.empty() || done != entries) fail("slices: work left");
    traceEnd();
    std::printf("mark_harness PASS (slices: n = %u, %llu entries)\n", n, (unsigned long long)entries);
}

struct TraceEpisodeCtx {
    SynthHeap* h;
    SliceControl* c;
    std::atomic<int64_t>* pool;
};

static void traceEpisode(unsigned B, uint32_t L, uint32_t F, int assists, int64_t abudget, int end,
                         uint64_t seed, unsigned pace) {
    if (B < 1 || B > 8 || F > kChunk || abudget < 1 || end < 0 || end > 2) fail("episode: bad arguments");
    const bool stop = end == 1;
    const Graph g = traceGraph(L, F);
    const unsigned slots = 1 + B;
    auto& fg = gc::GCMarkGang::instance();
    if (fg.configured()) fg.shutdownForTesting();
    fg.configure(1, 0);
    gc::GCBackgroundGang::Options o;
    o.members = B;
    gc::GCBackgroundGang bg(o);
    SynthHeap h(g, slots);
    h.pace_us = pace;
    h.grey(0, 0);                                    // the t0 grey on slot 0 ...
    h.publishAll(0);                                 // ... round-robin into the background
    for (uint64_t j = 0;; ++j) {                     // deques (launchBackground)
        const uint64_t e = h.w[0]->dq.take();
        if (e == kEmpty) break;
        h.w[1 + j % B]->dq.push(e);
    }
    std::string deques = "[";
    for (unsigned i = 0; i < slots; ++i) {
        std::vector<uint64_t> d;
        if (i == 1) d.push_back(1);                  // the root (one entry: slot 1)
        deques += (i ? "," : "") + traceSeq(d);
    }
    deques += "]";
    traceBegin("{\"model\":\"M2\",\"scenario\":\"episode\",\"B\":" + std::to_string(B) + "," +
               traceGraphJson(g) + ",\"deque0\":" + deques + ",\"assists\":" + std::to_string(assists) +
               ",\"abudget\":" + std::to_string(abudget) + ",\"stop\":" + (stop ? "true" : "false") + "}");
    std::mt19937_64 rng(seed);
    SliceControl c(kDrainBudget, slots, 0, static_cast<int64_t>(B));
    for (unsigned i = 0; i < slots; ++i) h.w[i]->ctr.resetRun(i);
    ECO_TLA_TRACE("mw.ctl", "ctl", c.tla_ctl, "budget", 0, "drain", true, "active", B, "victims", slots);
    TraceEpisodeCtx ctx{&h, &c, nullptr};
    bg.launch([](void* p, unsigned j) {
        auto* x = static_cast<TraceEpisodeCtx*>(p);
        SynthEnv env{*x->h};
        runMarkerLoop(env, 1 + j, *x->c, x->c->budget, Role::Member, false);
    }, &ctx, &c.stop);
    uint64_t units = 0;
    for (int a = 0; a < assists; ++a) {
        std::this_thread::sleep_for(std::chrono::microseconds(rng() % (pace + 1)));
        std::atomic<int64_t> pool{abudget};
        TraceEpisodeCtx ac{&h, &c, &pool};
        ECO_TLA_TRACE("mw.assist", "budget", abudget);
        c.share_epoch.fetch_add(1, std::memory_order_relaxed);
        h.w[0]->ctr.resetRun(0);
        fg.run([](void* p, unsigned i) {
            auto* x = static_cast<TraceEpisodeCtx*>(p);
            SynthEnv env{*x->h};
            runMarkerLoop(env, i, *x->c, *x->pool, Role::Assist, true);
        }, &ac, 1);
        const uint64_t u = h.w[0]->ctr.units;
        ECO_TLA_TRACE("mw.assistEnd", "units", u, "left", pool.load());
        if (static_cast<int64_t>(u) != abudget - pool.load()) fail("episode: assist units != consumed tickets");
        if (!h.w[0]->stack.empty() || h.w[0]->priv.load() != 0) fail("episode: private work after an assist");
        units += u;
    }
    std::this_thread::sleep_for(std::chrono::microseconds(rng() % (pace + 1)));
    if (stop) {
        ECO_TLA_TRACE("mw.stopReq", "put", tlatrace::key("stop", c.tla_ctl));
        bg.stopAndJoin();
    } else {
        if (end == 2) {
            while (!bg.finishedApprox()) std::this_thread::yield();
        }
        TraceEpisodeCtx cl{&h, &c, nullptr};
        ECO_TLA_TRACE("mw.closing");
        c.share_epoch.fetch_add(1, std::memory_order_relaxed);
        h.w[0]->ctr.resetRun(0);
        fg.run([](void* p, unsigned i) {
            auto* x = static_cast<TraceEpisodeCtx*>(p);
            SynthEnv env{*x->h};
            runMarkerLoop(env, i, *x->c, x->c->budget, Role::Member, true);
        }, &cl, 1);
        units += h.w[0]->ctr.units;
        bg.join();
    }
    for (unsigned i = 1; i < slots; ++i) units += h.w[i]->ctr.units;
    uint64_t left = 0;
    for (auto& x : h.w) left += x->dq.sizeApprox();
    ECO_TLA_TRACE("mw.joined", "done", c.done(), "units", units, "left", left);
    for (auto& x : h.w)
        if (!x->stack.empty() || x->priv.load() != 0) fail("episode: private work after the episode");
    const uint64_t entries = reachEntries(g);
    uint64_t marked = 0;
    for (size_t i = 0; i < g.kids.size(); ++i) marked += h.marks[i].load() != 0;
    if (!stop && (!c.done() || left != 0 || units != entries)) fail("episode: the closing did not finish");
    if (units + left != marked) fail("episode: a greyed entry is neither scanned nor in a deque (Drain)");
    traceEnd();
    std::printf("mark_harness PASS (episode: B = %u, %d assists, %s, %llu units, %llu left)\n", B, assists,
                stop ? "stopped" : end == 2 ? "closed after the members" : "closed", (unsigned long long)units, (unsigned long long)left);
}

int main(int argc, char** argv) {
    if (argc > 1 && std::strcmp(argv[1], "slices") == 0) {
        if (argc != 9) {
            std::fprintf(stderr, "usage: %s slices <n> <L> <F> <slices> <max budget> <seed> <pace us>\n", argv[0]);
            return 2;
        }
        traceSlices(static_cast<unsigned>(std::atoi(argv[2])), static_cast<uint32_t>(std::atoi(argv[3])),
                    static_cast<uint32_t>(std::atoi(argv[4])), std::atoi(argv[5]), std::atoi(argv[6]),
                    std::strtoull(argv[7], nullptr, 10), static_cast<unsigned>(std::atoi(argv[8])));
        gc::GCMarkGang::instance().shutdownForTesting();
        return 0;
    }
    if (argc > 1 && std::strcmp(argv[1], "episode") == 0) {
        if (argc != 10) {
            std::fprintf(stderr, "usage: %s episode <B> <L> <F> <assists> <assist budget> <end 0|1|2> <seed> "
                                 "<pace us>\n", argv[0]);
            return 2;
        }
        traceEpisode(static_cast<unsigned>(std::atoi(argv[2])), static_cast<uint32_t>(std::atoi(argv[3])),
                     static_cast<uint32_t>(std::atoi(argv[4])), std::atoi(argv[5]), std::atoll(argv[6]),
                     std::atoi(argv[7]), std::strtoull(argv[8], nullptr, 10),
                     static_cast<unsigned>(std::atoi(argv[9])));
        gc::GCMarkGang::instance().shutdownForTesting();
        return 0;
    }
    terminationStress(8, 40000);
    terminationStress(16, 40000);
    dequeStorm(3, 400000);
    dequeStorm(7, 400000);
    gangStorm(20000, 0);
    gangStorm(2000, 50);
    const Graph g = makeGraph(60000, 7);
    std::mt19937_64 rng(11);
    std::vector<int64_t> budgets;
    for (int k = 0; k < 20; ++k) budgets.push_back(1 + static_cast<int64_t>(rng() % 3000));
    for (int k = 0; k < 400; ++k) budgets.push_back(1 + static_cast<int64_t>(rng() % 8));
    const auto ref = synthMark(g, 1, 0, budgets);
    for (unsigned n : {2u, 4u, 8u}) {
        if (synthMark(g, n, 0, budgets) != ref) fail("synth: consumption differs across n");
    }
    if (synthMark(g, 4, 50, budgets) != ref) fail("synth: consumption differs with jitter");
    // Repeat the n = 8 run: the termination race of the first build needed
    // many small-budget slices to show (plan P§10.1 item 10).
    for (int rep = 0; rep < 5; ++rep)
        if (synthMark(g, 8, 0, budgets) != ref) fail("synth: consumption differs on a repeat");
    std::printf("synthetic marker: 60000 nodes, 420 slices, n = 1/2/4/8 + jitter + 5 repeats identical\n");
    gc::GCMarkGang::instance().shutdownForTesting();
    bgGangStorm(50000, 5000);
    for (unsigned rep = 0; rep < 3; ++rep) {
        episodeStorm(2, 2, 0, 100 + rep);
        episodeStorm(1, 4, 0, 200 + rep);
        episodeStorm(4, 8, 0, 300 + rep);
        episodeStorm(3, 3, 50, 400 + rep);
    }
    gc::GCMarkGang::instance().shutdownForTesting();
    std::printf("mark_harness PASS\n");
    return 0;
}
