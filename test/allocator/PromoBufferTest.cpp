/**
 * threaded-gc-06 Step 4 (plans/threaded-gc-06-parallel-minor.md P§3.8): the
 * per-worker promotion buffers. Exercised serially: the identity switch
 * (NurserySpace::test_serial_promo_via_ctx_) routes the serial minor's
 * promotions through worker 0 of a promotion context, which must reproduce
 * OldGenSpace::allocate bit for bit.
 */

#include "PromoBufferTest.hpp"

#include <cstdio>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <vector>

#include "Allocator.hpp"
#include "AllocatorCommon.hpp"
#include "Heap.hpp"
#include "HeapHelpers.hpp"
#include "MinorWorkload.hpp"
#include "OldGenSpace.hpp"
#include "TestHelpers.hpp"
#include "ThreadLocalHeap.hpp"

using namespace Elm;
using namespace Elm::TestHelpers;

#define PB_ASSERT(cond)                                                     \
    do {                                                                    \
        if (!(cond)) {                                                      \
            std::ostringstream oss;                                         \
            oss << "PromoBuffer assertion failed: " #cond                   \
                << " at " __FILE__ ":" << __LINE__;                         \
            std::cerr << oss.str() << std::endl;                            \
            throw std::runtime_error(oss.str());                            \
        }                                                                   \
    } while (0)

namespace {

using OA = OldGenSpaceTestAccess;

// A promotion cell handed out outside a minor must hold a parsable object
// (the heap validators walk mixed blocks by header): a ByteBuffer of `sz`.
void formatAsBytes(void* p, size_t sz) {
    std::memset(p, 0, sz);
    Header* h = getHeader(p);
    h->tag = Tag_ByteBuffer;
    h->size = static_cast<u32>(sz - sizeof(ByteBuffer));
}

HeapConfig promoConfig() {
    // The 05b test geometry (small nursery, roomy old gen): the churn below
    // must not exhaust the old gen between majors.
    HeapConfig cfg;
    cfg.alloc_buffer_size          = 32 * 1024;
    cfg.nursery_block_count        = 8;
    cfg.nursery_max_block_count    = 8;
    cfg.initial_old_gen_size       = 256 * 1024;
    cfg.max_heap_size              = 512ULL * 1024 * 1024;
    cfg.large_object_threshold     = 8 * 1024;
    cfg.decommit_on_oldgen_release = false;
    cfg.old_gen_bitmap_alloc = true;
    cfg.gc_minor_threads = 1;
    cfg.minor_lab_bytes = 4096;   // pins the minor config (ECO_TEST_MINOR_THREADS leaves it)
    cfg.gc_thread_mode = 0;
    cfg.validate();
    return cfg;
}

ThreadLocalHeap* tlh(Allocator& a) { return AllocatorTestAccess::getThreadHeap(a); }
OldGenSpace& og(Allocator& a) { return tlh(a)->getOldGen(); }

struct Outcome {
    uint64_t checksum, layout, allocated, committed, blocks, promoted, survived, minors, majors;
};

Outcome runScript(bool via_ctx, uint64_t seed, size_t steps) {
    auto& a = initLegacyAllocator(promoConfig());
    tlh(a)->getNursery().test_serial_promo_via_ctx_ = via_ctx;
    if (std::getenv("PB_DEBUG")) std::fprintf(stderr, "[pb] arm via_ctx=%d seed=%llu\n", (int)via_ctx, (unsigned long long)seed);
    Outcome o{};
    {
        minortest::Workload w(a, 96, seed);
        w.run(steps);
        a.minorGC();
        o.checksum = w.checksum();
    }
    OldGenSpace& g = og(a);
    g.syncCursorLiveBytes();
    o.layout = OA::layoutHash(g);
    o.allocated = OA::allocatedBytes(g);
    o.committed = OA::committedBytes(g);
    o.blocks = OA::numBlocks(g);
#if ENABLE_GC_STATS
    const GCStats& st = tlh(a)->getNursery().getStats();
    o.promoted = st.objects_promoted;
    o.survived = st.objects_survived;
    o.minors = st.minor_gc_count;
#endif
    tlh(a)->getNursery().test_serial_promo_via_ctx_ = false;
    return o;
}

}  // namespace

Testing::TestCase testPromoViaCtxMatchesSerial(
    "threaded-gc-06: promotion through worker 0 of a context reproduces allocate() exactly",
    []() {
        for (uint64_t seed : {1ull, 2ull, 3ull}) {
            const Outcome a = runScript(false, seed, 60000);
            const Outcome b = runScript(true, seed, 60000);
            PB_ASSERT(a.checksum == b.checksum);
            PB_ASSERT(a.layout == b.layout);
            PB_ASSERT(a.allocated == b.allocated);
            PB_ASSERT(a.committed == b.committed);
            PB_ASSERT(a.blocks == b.blocks);
            PB_ASSERT(a.promoted == b.promoted);
            PB_ASSERT(a.survived == b.survived);
            PB_ASSERT(a.minors == b.minors);
#if ENABLE_GC_STATS
            PB_ASSERT(a.minors > 5);        // non-vacuous
            PB_ASSERT(a.promoted > 1000);
#endif
        }
    });

Testing::TestCase testWorkerCursorReturnedToFront(
    "threaded-gc-06: chunked promotion shares a block; a retired block with cells left goes to the FRONT (W6)",
    []() {
        auto& a = initLegacyAllocator(promoConfig());
        OldGenSpace& g = og(a);
        const size_t cls = OA::sizeClass(sizeof(Tuple2));
        OldGenSpace::PromoCtx& ctx = g.promoCtx();
        g.beginParallelPromotion(ctx, 3);   // N > 1: chunked shared blocks
        void* p1 = g.allocatePromotion(ctx.w[1], sizeof(Tuple2), false);
        void* p2 = g.allocatePromotion(ctx.w[2], sizeof(Tuple2), false);
        PB_ASSERT(p1 && p2);
        formatAsBytes(p1, sizeof(Tuple2));
        formatAsBytes(p2, sizeof(Tuple2));
        const BlockId b1 = OA::blockOf(g, p1);
        PB_ASSERT(b1.valid() && OA::blockOf(g, p2) == b1);            // one shared block
        // Different chunks (units of 64 cells): never a shared bitmap byte.
        const size_t cell = OA::classToSize(cls);
        const size_t d = static_cast<char*>(p1) < static_cast<char*>(p2)
            ? static_cast<char*>(p2) - static_cast<char*>(p1)
            : static_cast<char*>(p1) - static_cast<char*>(p2);
        PB_ASSERT(d >= OldGenSpace::kChunkUnitCells * cell);
        // Worker 2 fills the rest of the block until the shared block moves on.
        BlockId b2 = b1;
        for (int i = 0; i < 1000000 && b2 == b1; ++i) {
            void* p = g.allocatePromotion(ctx.w[2], sizeof(Tuple2), false);
            PB_ASSERT(p != nullptr);
            formatAsBytes(p, sizeof(Tuple2));
            b2 = OA::blockOf(g, p);
        }
        PB_ASSERT(b2 != b1);
        g.endParallelPromotion(ctx);
        // b1 was retired with cells left in worker 1's chunk: re-queued first.
        PB_ASSERT(OA::partialQueueAt(g, cls, 0) == b1);
        PB_ASSERT(OA::allocState(g, b1) == 1 /* kAllocQueued */);
        // The shared block is the mutator's cursor again.
        PB_ASSERT(OA::cursorBlock(g, cls) == b2);
        PB_ASSERT(OA::allocState(g, b2) == 2 /* kAllocCurrent */);
        PB_ASSERT(OA::allocStateConsistent(g));
    });

Testing::TestCase testLadderUnderMutexAccounting(
    "threaded-gc-06: every promotion byte is accounted after the merge (PM6)",
    []() {
        auto& a = initLegacyAllocator(promoConfig());
        OldGenSpace& g = og(a);
        const size_t before = OA::allocatedBytes(g);
        OldGenSpace::PromoCtx& ctx = g.promoCtx();
        g.beginParallelPromotion(ctx, 2);
        size_t expect = 0;
        // Class sizes through the cursors, and a class-less size (bag path,
        // charged its requested size under the lock).
        const size_t sizes[] = {16, 24, 40, 64, 136, 520, 3000};
        for (int rep = 0; rep < 2000; ++rep) {
            for (size_t sz : sizes) {
                OldGenSpace::PromoWorker& pw = ctx.w[rep & 1];
                void* p = g.allocatePromotion(pw, sz, false);
                PB_ASSERT(p != nullptr);
                formatAsBytes(p, sz);
                const size_t cls = OA::sizeClass(sz);
                expect += cls < OA::numSizeClasses(g) ? OA::classToSize(cls) : sz;
            }
        }
        g.endParallelPromotion(ctx);
        PB_ASSERT(OA::allocatedBytes(g) - before == expect);
        PB_ASSERT(OA::allocStateConsistent(g));
    });
