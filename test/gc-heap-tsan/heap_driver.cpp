// threaded-gc-05c Step 8 (D9): the real allocator under TSan with background
// marking. A synthetic mutator keeps an old random graph plus a churning set
// of rooted young/large objects, forces a cycle every ~40 minors, and checks
// every rooted value after each handoff. Validators (IM1-IM16) are on.
#include "Allocator.hpp"
#include "HeapHelpers.hpp"
#include "OldGenSpace.hpp"
#include "ThreadLocalHeap.hpp"

#include <cstdio>
#include <cstdlib>
#include <memory>
#include <random>
#include <vector>

using namespace Elm;

namespace {
[[noreturn]] void fail(const char* w) {
    std::fprintf(stderr, "heap_driver FAIL: %s\n", w);
    std::exit(1);
}
struct Root {
    Allocator& a;
    HPointer h;
    Root(Allocator& al, HPointer v) : a(al), h(v) { a.getRootSet().addRoot(&h); }
    ~Root() { a.getRootSet().removeRoot(&h); }
};
i64 intOf(Allocator& a, HPointer hp) {
    void* o = a.resolve(hp);
    if (!o || getHeader(o)->tag != Tag_Int) fail("expected an Int");
    return static_cast<ElmInt*>(o)->value;
}

void scenario(unsigned bg, unsigned slices, uint64_t seed) {
    HeapConfig cfg;
    cfg.alloc_buffer_size = 32 * 1024;
    cfg.nursery_block_count = 8;
    cfg.nursery_max_block_count = 8;
    cfg.initial_old_gen_size = 256 * 1024;
    cfg.max_heap_size = 512ULL << 20;
    cfg.large_object_threshold = 8 * 1024;
    cfg.decommit_on_oldgen_release = false;
    cfg.gc_thread_mode = 0;
    cfg.incremental_mark = true;
    cfg.incremental_mark_slices = slices;
    cfg.incremental_mark_min_slice_units = 64;
    cfg.gc_mark_threads = 2;
    cfg.conc_mark = 2;
    cfg.conc_mark_threads = bg;
    cfg.conc_mark_priority = 0;
    cfg.conc_mark_assist_lag = 1;
    cfg.validate();
    auto& a = Allocator::instance();
    a.initialize(cfg);
    AllocatorTestAccess::reset(a, &cfg);
    a.initThread();
    ThreadLocalHeap* h = AllocatorTestAccess::getThreadHeap(a);
    std::mt19937_64 rng(seed);
    // Old graph: a list of (Int, Int) pairs.
    std::vector<std::unique_ptr<Root>> keep;
    std::vector<i64> want;
    for (int i = 0; i < 60000; ++i) {
        Root x(a, alloc::allocInt(i));
        Root y(a, alloc::allocInt(-i));
        HPointer t = alloc::tuple2(alloc::boxed(x.h), alloc::boxed(y.h), 0);
        if (i % 16 == 0) { keep.push_back(std::make_unique<Root>(a, t)); want.push_back(i); }
    }
    uint64_t cycles = 0;
    for (int step = 0; step < 900; ++step) {
        for (int i = 0; i < 300; ++i) {
            const size_t len = 1 + rng() % 50;
            std::vector<u16> buf(len, static_cast<u16>('a' + i % 26));
            Root s(a, alloc::allocString(buf.data(), len));
            Root n(a, alloc::allocInt(step));
            HPointer t = alloc::tuple2(alloc::boxed(s.h), alloc::boxed(n.h), 0);
            if (rng() % 64 == 0) {
                const size_t k = rng() % keep.size();
                keep[k]->h = t;
                want[k] = -1000000 - step;
            }
        }
        if (step % 9 == 0) {
            std::vector<u16> big(5000, 'L');
            keep.push_back(std::make_unique<Root>(a, alloc::allocString(big.data(), big.size())));
            want.push_back(-1);
        }
        if (step % 40 == 0 && !OldGenSpaceTestAccess::cycleActive(h->getOldGen())) {
            h->test_force_major_trigger_ = true;
            ++cycles;
        }
        a.minorGC();
        // Verify everything rooted.
        if (step % 25 == 0) {
            for (size_t k = 0; k < keep.size(); ++k) {
                void* o = a.resolve(keep[k]->h);
                if (!o) fail("a rooted value vanished");
                if (want[k] >= 0) {
                    Tuple2* t = static_cast<Tuple2*>(o);
                    if (intOf(a, t->a.p) != want[k]) fail("a rooted value changed");
                } else if (want[k] <= -1000000) {
                    Tuple2* t = static_cast<Tuple2*>(o);
                    if (intOf(a, t->b.p) != -(want[k] + 1000000)) fail("a replaced value changed");
                }
            }
        }
    }
    while (OldGenSpaceTestAccess::cycleActive(h->getOldGen())) a.minorGC();
    const ConcMarkStats& cm = h->getOldGen().getStats().cm;
    std::printf("heap scenario B=%u T=%u: %llu forced cycles ok (episodes %llu, bg units %llu, "
                "assists %llu, closings with work %llu, early done %llu)\n", bg, slices,
                (unsigned long long)cycles, (unsigned long long)cm.episodes_launched,
                (unsigned long long)cm.bg_units, (unsigned long long)cm.assists,
                (unsigned long long)cm.closings_with_work, (unsigned long long)cm.done_k_hist[0]);
}
}  // namespace

int main() {
    scenario(2, 4, 1);
    scenario(4, 16, 2);
    scenario(3, 8, 3);
    std::printf("heap_driver PASS\n");
    return 0;
}
