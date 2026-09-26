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
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <random>
#include <thread>
#include <vector>

using namespace Elm;
using namespace Elm::markwork;

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
    };
    std::vector<std::unique_ptr<Worker>> w;
    SynthHeap(const Graph& gr, unsigned members) : g(gr), n(members),
        marks(new std::atomic<uint8_t>[gr.kids.size()]) {
        for (size_t i = 0; i < gr.kids.size(); ++i) marks[i].store(0);
        for (unsigned i = 0; i < members; ++i) w.push_back(std::make_unique<Worker>());
    }
    static constexpr size_t kPublishMin = 64;
    void publishHalf(Worker& x) {
        if (x.stack.size() < kPublishMin || !x.dq.emptyApprox()) return;
        const size_t half = x.stack.size() / 2;
        for (size_t i = 0; i < half; ++i) x.dq.push(x.stack[i]);
        x.stack.erase(x.stack.begin(), x.stack.begin() + static_cast<std::ptrdiff_t>(half));
        x.priv.store(x.stack.size(), std::memory_order_relaxed);
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
    bool empty() const {
        for (auto& x : w) if (!x->dq.emptyApprox() || !x->stack.empty()) return false;
        return true;
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

int main() {
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
    std::printf("mark_harness PASS\n");
    return 0;
}
