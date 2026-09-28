/**
 * threaded-gc-07 Step 4 (plans/threaded-gc-07-concurrent-tenuring.md P§3.12,
 * HEAP_070): the promotion grant. Uniform blocks in state kAllocTenure,
 * reuse (partial_ front) before virgin blocks, returned to the front of
 * partial_ at the merge, invisible to every block-selection path meanwhile.
 */

#include "TenureGrantTest.hpp"

#include <algorithm>
#include <cstdio>
#include <random>
#include <vector>

#include "Allocator.hpp"
#include "AllocatorCommon.hpp"
#include "HeapHelpers.hpp"
#include "OldGenSpace.hpp"
#include "TestHelpers.hpp"
#include "ThreadLocalHeap.hpp"

using namespace Elm;
using namespace Elm::TestHelpers;

namespace {

using OA = OldGenSpaceTestAccess;

HeapConfig grantConfig() {
    HeapConfig cfg;
    cfg.alloc_buffer_size          = 32 * 1024;
    cfg.nursery_block_count        = 16;
    cfg.nursery_max_block_count    = 16;
    cfg.initial_old_gen_size       = 256 * 1024;
    cfg.max_heap_size              = 512ULL * 1024 * 1024;
    cfg.large_object_threshold     = 8 * 1024;
    cfg.decommit_on_oldgen_release = false;
    cfg.old_gen_bitmap_alloc       = true;
    cfg.gc_thread_mode             = 0;
    cfg.incremental_mark           = false;
    cfg.gc_minor_threads           = 1;
    cfg.validate();
    return cfg;
}

OldGenSpace& oldgenOf(Allocator& a) { return AllocatorTestAccess::getThreadHeap(a)->getOldGen(); }

// Allocates `n` 16-byte old-gen Ints (class 1), roots every `keep`-th one,
// then runs a major: the dead cells leave partially free uniform blocks on
// partial_[1].
struct PartialBlocks {
    std::vector<HPointer> roots;
    Allocator& a;
    size_t keep_;
    PartialBlocks(Allocator& al, size_t n, size_t keep) : a(al), keep_(keep) {
        OldGenSpace& og = oldgenOf(a);
        roots.reserve(n / keep + 1);
        for (size_t i = 0; i < n; ++i) {
            void* p = og.allocate(16);
            Header* h = getHeader(p);
            h->tag = Tag_Int;
            h->size = 16;
            static_cast<ElmInt*>(p)->value = static_cast<i64>(i);
            if (i % keep == 0) roots.push_back(AllocatorTestAccess::toPointer(p));
        }
        for (auto& r : roots) a.getRootSet().addRoot(&r);
        a.majorGC();
        OA::driveSweepToCompletion(og);
    }
    ~PartialBlocks() { for (auto& r : roots) a.getRootSet().removeRoot(&r); }
    bool intact() const {
        for (size_t k = 0; k < roots.size(); ++k)
            if (static_cast<ElmInt*>(AllocatorTestAccess::fromPointer(roots[k]))->value != static_cast<i64>(k * keep_))
                return false;
        return true;
    }
};

}  // namespace

Testing::TestCase testGrantCoversCounts(
    "threaded-gc-07: a grant covers every class count, reuse (partial_ front) before virgin blocks",
    []() {
        auto& a = initAllocator(grantConfig());
        OldGenSpace& og = oldgenOf(a);
        PartialBlocks pb(a, 20000, 7);
        const size_t cls1 = OA::sizeClass(16);
        const std::vector<BlockId> queued = OA::partialQueue(og, cls1);
        TEST_ASSERT(!queued.empty());
        std::mt19937_64 rng(5);
        for (int round = 0; round < 4; ++round) {
            uint32_t count[NUM_SIZE_CLASSES] = {};
            count[cls1] = 1000 + static_cast<uint32_t>(rng() % 20000);
            for (int k = 0; k < 4; ++k) count[rng() % OA::numSizeClasses(og)] += static_cast<uint32_t>(rng() % 3000);
            OldGenSpace::TenureGrant g;
            og.grantTenure(count, g);
            TEST_ASSERT(g.active && og.activeTenureGrants() == 1);
            for (size_t c = 0; c < NUM_SIZE_CLASSES; ++c) {
                uint64_t free_cells = 0;
                for (const auto& b : g.blocks[c]) {
                    TEST_ASSERT(OA::allocState(og, b.block) == OA::kAllocTenure);
                    free_cells += b.num_cells;   // an upper bound; the exact check is allocation below
                }
                if (count[c] == 0) TEST_ASSERT(g.blocks[c].empty());
            }
            // W6: the first granted blocks of class 1 are the queue's front.
            if (round == 0) {
                const size_t k = std::min(queued.size(), g.blocks[cls1].size());
                for (size_t i = 0; i < k; ++i) TEST_ASSERT(g.blocks[cls1][i].block == queued[i]);
            }
            // Every counted cell can be allocated (the exact engine never runs out).
            for (size_t c = 0; c < NUM_SIZE_CLASSES; ++c) {
                for (uint32_t i = 0; i < count[c]; ++i) {
                    void* p = og.grantAllocate(g, c, OA::classToSize(c));
                    TEST_ASSERT(p != nullptr);
                }
            }
            og.returnTenureGrant(g);
            TEST_ASSERT(!g.active && og.activeTenureGrants() == 0);
            og.validateTenureBlocks("testGrantCoversCounts");
        }
        TEST_ASSERT(pb.intact());
    });

Testing::TestCase testGrantReturnToFront(
    "threaded-gc-07: after a partial use the grant's blocks sit at the partial_ front in grant order",
    []() {
        auto& a = initAllocator(grantConfig());
        OldGenSpace& og = oldgenOf(a);
        PartialBlocks pb(a, 20000, 5);
        const size_t cls1 = OA::sizeClass(16);
        uint32_t count[NUM_SIZE_CLASSES] = {};
        count[cls1] = 30000;
        OldGenSpace::TenureGrant g;
        og.grantTenure(count, g);
        std::vector<BlockId> granted;
        for (const auto& b : g.blocks[cls1]) granted.push_back(b.block);
        TEST_ASSERT(granted.size() >= 2);
        for (int i = 0; i < 100; ++i) (void)og.grantAllocate(g, cls1, 16);   // a partial use
        og.returnTenureGrant(g);
        const std::vector<BlockId> q = OA::partialQueue(og, cls1);
        TEST_ASSERT(q.size() >= granted.size());
        for (size_t i = 0; i < granted.size(); ++i) TEST_ASSERT(q[i] == granted[i]);
        // The next cursor allocation takes the first-granted block.
        const BlockId cur0 = OA::cursorBlock(og, cls1);
        void* p = nullptr;
        // Drain the current cursor block first (if any) so a refill happens.
        for (int i = 0; i < 1000000 && OA::cursorBlock(og, cls1) == cur0 && cur0.valid(); ++i) p = og.allocate(16);
        if (!cur0.valid()) p = og.allocate(16);
        (void)p;
        TEST_ASSERT(OA::cursorBlock(og, cls1) == granted[0]);
        TEST_ASSERT(pb.intact());
    });

Testing::TestCase testGrantAccountingMerge(
    "threaded-gc-07: allocated_bytes after a grant's return equals cursor allocation of the same cells",
    []() {
        size_t via_grant = 0, via_cursor = 0;
        for (int arm = 0; arm < 2; ++arm) {
            auto& a = initAllocator(grantConfig());
            OldGenSpace& og = oldgenOf(a);
            PartialBlocks pb(a, 20000, 3);
            const size_t cls1 = OA::sizeClass(16);
            const size_t before = OA::allocatedBytes(og);
            if (arm == 0) {
                uint32_t count[NUM_SIZE_CLASSES] = {};
                count[cls1] = 5000;
                OldGenSpace::TenureGrant g;
                og.grantTenure(count, g);
                for (int i = 0; i < 5000; ++i) (void)og.grantAllocate(g, cls1, 16);
                TEST_ASSERT(OA::allocatedBytes(og) == before);   // deltas merge at the return
                og.returnTenureGrant(g);
                via_grant = OA::allocatedBytes(og) - before;
            } else {
                for (int i = 0; i < 5000; ++i) (void)og.allocate(16);
                via_cursor = OA::allocatedBytes(og) - before;
            }
        }
        TEST_ASSERT(via_grant == via_cursor);
    });

Testing::TestCase testShrinkSkipsGranted(
    "threaded-gc-07: the light shrink and the empty-block flip skip a granted block (trap 4)",
    []() {
        auto& a = initAllocator(grantConfig());
        OldGenSpace& og = oldgenOf(a);
        const size_t cls = OA::sizeClass(64);
        uint32_t count[NUM_SIZE_CLASSES] = {};
        count[cls] = 100;                       // one virgin block, empty until the merge
        OldGenSpace::TenureGrant g;
        og.grantTenure(count, g);
        TEST_ASSERT(g.blocks[cls].size() == 1);
        const BlockId id = g.blocks[cls][0].block;
        TEST_ASSERT(OA::allocState(og, id) == OA::kAllocTenure);
        OA::lightShrink(og, 0);                 // wants to release every empty block
        TEST_ASSERT(OA::blockLive(og, id) && OA::allocState(og, id) == OA::kAllocTenure);
        void* big = OA::allocFromEmptyRegular(og, 1024);   // must not flip the granted block
        if (big != nullptr) TEST_ASSERT(OA::blockIdFor(og, big) != id);
        TEST_ASSERT(OA::allocState(og, id) == OA::kAllocTenure);
        (void)og.grantAllocate(g, cls, 64);
        og.returnTenureGrant(g);
        TEST_ASSERT(OA::allocState(og, id) != OA::kAllocTenure);
    });
