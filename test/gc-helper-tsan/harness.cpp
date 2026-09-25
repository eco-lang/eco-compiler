// threaded-gc-03 Step 8: TSan harness for GCHelperPool + PageWork.
// See README.md. Build with g++ -fsanitize=thread (CMakeLists.txt here).

#include <atomic>
#include <cerrno>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <mutex>
#include <random>
#include <thread>
#include <vector>

#include <sys/mman.h>
#include <unistd.h>

#include "GCHelperPool.hpp"
#include "PageWork.hpp"

using namespace Elm::gc;

namespace {

[[noreturn]] void die(const char* what, long a = 0) {
    std::fprintf(stderr, "HARNESS FAILURE: %s (%ld)\n", what, a);
    std::fflush(stderr);
    std::abort();
}

GCHelperPool& freshPool(HelperMode mode, unsigned threads, unsigned jitter) {
    auto& pool = GCHelperPool::instance();
    if (pool.configured()) pool.shutdownForTesting();
    pool.configure(mode, threads, -1, jitter);
    return pool;
}

// ---------------------------------------------------------------------------
// H1: pool protocol under 3 concurrent posters.
// ---------------------------------------------------------------------------
struct CountJob : HelperJob {
    uint64_t value = 0;      // written by the runner, read after wait()
    uint64_t input = 0;      // written by the poster before post()
    static void body(HelperJob* j) {
        auto* c = static_cast<CountJob*>(j);
        c->value = c->input * 2 + 1;
    }
};

void h1(unsigned threads, unsigned jitter) {
    auto& pool = freshPool(HelperMode::Concurrent, threads, jitter);
    const int kPer = jitter ? 2000 : 20000;
    auto poster = [&](int id) {
        std::mt19937_64 rng(id * 7919 + 1);
        std::vector<CountJob> jobs(8);
        for (auto& j : jobs) { j.run = &CountJob::body; j.client = HelperClient::Test; }
        for (int i = 0; i < kPer; ++i) {
            CountJob& j = jobs[i % jobs.size()];
            if (!j.isIdle()) {
                pool.wait(j, true);
                if (j.value != j.input * 2 + 1) die("H1: job result not visible after wait");
                j.resetForReuse();
            }
            j.input = static_cast<uint64_t>(id) << 32 | static_cast<uint64_t>(i);
            pool.post(j);
            if (rng() % 97 == 0) pool.drain();
        }
        for (auto& j : jobs) {
            if (!j.isIdle()) {
                pool.wait(j, true);
                if (j.value != j.input * 2 + 1) die("H1: final result");
            }
        }
    };
    std::thread a(poster, 1), b(poster, 2), c(poster, 3);
    a.join(); b.join(); c.join();
    pool.drain();
    pool.shutdownForTesting();
}

// ---------------------------------------------------------------------------
// H2 / H3: PageWork driven by a random mutator script.
// ---------------------------------------------------------------------------
constexpr size_t kExtents = 1024;
constexpr size_t kExt = 512 * 1024;
constexpr size_t kPage = 4096;

enum : int { NeverUsed = 0, InUse = 1, Free = 2 };

struct World {
    char* base = nullptr;              // fake (H2) or real reservation (H3)
    bool real = false;
    std::atomic<int> state[kExtents];
    std::atomic<uint64_t> violations{0};
    World() { for (auto& s : state) s.store(NeverUsed); }
    size_t idx(char* p) const { return static_cast<size_t>(p - base) / kExt; }
};

World* g_world = nullptr;

bool opDiscard(void* ctx, char* p, size_t n) {
    auto* w = static_cast<World*>(ctx);
    for (size_t k = w->idx(p); k < w->idx(p + n - 1) + 1; ++k) {
        if (w->state[k].load() != Free) die("discard of an extent that is not free", (long)k);
    }
    if (w->real && madvise(p, n, MADV_DONTNEED) != 0) die("madvise DONTNEED", errno);
    std::this_thread::yield();
    for (size_t k = w->idx(p); k < w->idx(p + n - 1) + 1; ++k) {
        if (w->state[k].load() != Free) die("extent reused while its discard ran", (long)k);
    }
    return true;
}

bool opPopulate(void* ctx, char* p, size_t n) {
    auto* w = static_cast<World*>(ctx);
#ifndef MADV_POPULATE_WRITE
#define MADV_POPULATE_WRITE 23
#endif
    if (p < w->base || p >= w->base + kExtents * kExt) {
        // The construction-time support probe (PageWork's own page).
        return w->real ? madvise(p, n, MADV_POPULATE_WRITE) == 0 : true;
    }
    auto check = [&] {
        for (size_t k = w->idx(p); k < w->idx(p + n - 1) + 1 && k < kExtents; ++k) {
            if (w->state[k].load() == Free) die("populate over a released extent", (long)k);
        }
    };
    check();
    if (w->real && madvise(p, n, MADV_POPULATE_WRITE) != 0) {
        if (errno == EINVAL) return false;
        die("madvise POPULATE_WRITE", errno);
    }
    check();
    return true;
}

bool opCommit(void* ctx, char* p, size_t n) {
    auto* w = static_cast<World*>(ctx);
    if (!w->real) return true;
    void* r = mmap(p, n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    return r == p;
}

void writePattern(World& w, size_t k, uint64_t gen) {
    if (!w.real) return;
    char* p = w.base + k * kExt;
    for (size_t off = 0; off < kExt; off += kPage) {
        uint64_t v = (static_cast<uint64_t>(k) << 40) | gen | 1;
        std::memcpy(p + off, &v, 8);
    }
}

void checkPattern(World& w, size_t k, uint64_t gen) {
    if (!w.real) return;
    char* p = w.base + k * kExt;
    for (size_t off = 0; off < kExt; off += kPage) {
        uint64_t v;
        std::memcpy(&v, p + off, 8);
        if (v != ((static_cast<uint64_t>(k) << 40) | gen | 1)) {
            die("owned extent lost its contents (a discard hit owned memory)", (long)k);
        }
    }
}

void script(HelperMode mode, unsigned threads, unsigned jitter, bool real, int steps,
            size_t ahead) {
    auto& pool = freshPool(mode, threads, jitter);
    World w;
    w.real = real;
    if (real) {
        void* r = mmap(nullptr, kExtents * kExt + (2u << 20), PROT_NONE,
                       MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
        if (r == MAP_FAILED) die("reserve");
        uintptr_t a = (reinterpret_cast<uintptr_t>(r) + (2u << 20) - 1) & ~uintptr_t((2u << 20) - 1);
        w.base = reinterpret_cast<char*>(a);
    } else {
        w.base = reinterpret_cast<char*>(uintptr_t{0x200000000000ull});
    }
    PageOps ops;
    ops.discard = &opDiscard;
    ops.populate = &opPopulate;
    ops.commit = &opCommit;
    ops.ctx = &w;
    PageWorkConfig cfg;
    cfg.decommit = true;
    cfg.delay = 2;
    cfg.pending_cap = 16 * kExt;
    cfg.ahead_bytes = ahead;
    std::mutex big_lock;   // stands in for Allocator::thread_mutex_
    std::vector<uint64_t> gen(kExtents, 0);
    {
        PageWork pw(ops, cfg, pool);
        std::mt19937_64 rng(real ? 3 : 2);
        size_t bump = 0;                   // next never-used extent
        std::vector<size_t> in_use;
        std::vector<size_t> free_list;     // first-fit order, swap-remove (like acquire)
        uint64_t epoch = 0;
        for (int step = 0; step < steps; ++step) {
            std::lock_guard<std::mutex> lk(big_lock);
            const unsigned r = rng() % 100;
            if (r < 35 && !free_list.empty()) {
                // Reuse the first free extent.
                const size_t k = free_list.front();
                free_list.front() = free_list.back();
                free_list.pop_back();
                pw.onReuse(w.base + k * kExt, kExt, rng() % 2);
                w.state[k].store(InUse);
                writePattern(w, k, ++gen[k]);
                in_use.push_back(k);
            } else if (r < 55 && bump < kExtents - 8) {
                char* p = w.base + bump * kExt;
                char* from = nullptr;
                const size_t n = pw.onFreshBump(p, kExt, &from);
                if (n > 0 && !opCommit(&w, from, n)) die("bump commit");
                w.state[bump].store(InUse);
                writePattern(w, bump, ++gen[bump]);
                in_use.push_back(bump);
                ++bump;
            } else if (r < 85 && !in_use.empty()) {
                const size_t i = rng() % in_use.size();
                const size_t k = in_use[i];
                in_use[i] = in_use.back();
                in_use.pop_back();
                checkPattern(w, k, gen[k]);
                pw.onRelease(w.base + k * kExt, kExt, true);
                w.state[k].store(Free);
                free_list.push_back(k);
            } else {
                pw.syncPoint(++epoch, w.base + bump * kExt, w.base + kExtents * kExt, true);
            }
            // Owned extents keep their pattern, whatever the helpers do.
            if (real && step % 64 == 0) {
                for (size_t k : in_use) checkPattern(w, k, gen[k]);
            }
        }
        std::lock_guard<std::mutex> lk(big_lock);
        pw.drainAll(true);
        for (size_t k : in_use) checkPattern(w, k, gen[k]);
    }
    pool.drain();
    pool.shutdownForTesting();
}

}  // namespace

int main() {
    const unsigned kThreads[] = {1, 2, 4};
    const unsigned kJitter[] = {0, 300};
    for (unsigned t : kThreads) {
        for (unsigned j : kJitter) {
            std::printf("H1 threads=%u jitter=%u\n", t, j);
            std::fflush(stdout);
            h1(t, j);
            std::printf("H2 threads=%u jitter=%u\n", t, j);
            std::fflush(stdout);
            script(HelperMode::Concurrent, t, j, /*real=*/false, j ? 20000 : 100000, 4 * kExt);
            std::printf("H3 threads=%u jitter=%u\n", t, j);
            std::fflush(stdout);
            script(HelperMode::Concurrent, t, j, /*real=*/true, j ? 5000 : 20000, 4 * kExt);
        }
    }
    std::printf("H2/H3 sync mode\n");
    script(HelperMode::Sync, 1, 0, false, 50000, 4 * kExt);
    script(HelperMode::Sync, 1, 0, true, 10000, 4 * kExt);
    std::printf("ALL PASSED\n");
    return 0;
}
