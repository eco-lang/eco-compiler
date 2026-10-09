/**
 * threaded-gc-02 Step 10 (plans/threaded-gc-02-bitmap-allocation.md).
 *
 * Every test builds its HeapConfig programmatically with
 * old_gen_bitmap_alloc set explicitly — never via ECO_HEAP_CONFIG, which would
 * leak into every suite. Under ECO_HEAP_VALIDATE the V8–V12 validators also run
 * inside these tests (at every major-GC end and release batch).
 */

#include "OldGenBitmapAllocTest.hpp"

#include <cstring>
#include <stdexcept>
#include <vector>

#include "Allocator.hpp"
#include "Heap.hpp"
#include "OldGenSpace.hpp"
#include "TestHelpers.hpp"
#include "ThreadLocalHeap.hpp"

using namespace Elm;
using namespace Elm::TestHelpers;
using OTA = OldGenSpaceTestAccess;

namespace {

HeapConfig bitmapConfig(bool on) {
    HeapConfig cfg;
    cfg.alloc_buffer_size       = 32 * 1024;
    cfg.nursery_block_count     = 4;
    cfg.initial_old_gen_size    = 256 * 1024;
    cfg.max_heap_size           = 64ULL * 1024 * 1024;
    cfg.large_object_threshold  = 8 * 1024;
    cfg.decommit_on_oldgen_release = false;
    cfg.old_gen_bitmap_alloc    = on;
    // threaded-gc-05a: incremental marking requires bitmap allocation; the
    // legacy arm runs the STW major.
    if (!on) cfg.incremental_mark = false;
    return cfg;
}

OldGenSpace& oldGen(Allocator& alloc) {
    auto* heap = AllocatorTestAccess::getThreadHeap(alloc);
    TEST_ASSERT(heap != nullptr);
    return heap->getOldGen();
}

// Allocates a pointer-free object whose LOGICAL size is exactly `bytes`
// (16: Int, 24: Tuple2 of two unboxed Ints, 32: Tuple3 of three) — the walk
// of a demoted (mixed) block steps by getObjectSize, so it must match.
void* allocInt(OldGenSpace& og, size_t bytes, i64 v) {
    void* p = og.allocate(bytes);
    TEST_ASSERT(p != nullptr);
    Header* h = reinterpret_cast<Header*>(p);
    if (bytes == 16) {
        h->tag = Tag_Int;
        reinterpret_cast<ElmInt*>(p)->value = v;
    } else if (bytes == 24) {
        h->tag = Tag_Tuple2;
        h->unboxed = 0b0101;
        auto* t = reinterpret_cast<Tuple2*>(p);
        t->a.i = v; t->b.i = v;
    } else {
        TEST_ASSERT(bytes == 32);
        h->tag = Tag_Tuple3;
        h->unboxed = 0b010101;
        auto* t = reinterpret_cast<Tuple3*>(p);
        t->a.i = v; t->b.i = v; t->c.i = v;
    }
    TEST_ASSERT(getObjectSize(p) == bytes);
    return p;
}

struct Rooted {
    std::vector<HPointer> hps;
    Allocator& alloc;
    explicit Rooted(Allocator& a) : alloc(a) {}
    void reserve(size_t n) { hps.reserve(n); }
    void add(void* p) { hps.push_back(AllocatorTestAccess::toPointer(p)); }
    void commit() { for (auto& h : hps) alloc.getRootSet().addRoot(&h); }
    ~Rooted() { for (auto& h : hps) alloc.getRootSet().removeRoot(&h); }
};

}  // namespace

Testing::TestCase testBitmapVirginBlockAddressOrder(
    "HEAP_054: a virgin block hands out consecutive cells from one block",
    []() {
        auto cfg = bitmapConfig(true);
        cfg.validate();
        auto& alloc = initAllocator(cfg);
        auto& og = oldGen(alloc);
        const size_t cls = OTA::sizeClass(16);
        char* first = static_cast<char*>(allocateIntInOldGen(og, 0));
        const BlockId b = OTA::cursorBlock(og, cls);
        TEST_ASSERT(b.valid());
        for (int i = 1; i < 100; ++i) {
            TEST_ASSERT(allocateIntInOldGen(og, i) == first + i * 16);
        }
        TEST_ASSERT(OTA::cursorBlock(og, cls) == b);
        TEST_ASSERT(OTA::metaOf(og, b).live_bytes == 100 * 16);
#if ENABLE_GC_STATS
        TEST_ASSERT(OTA::bitmapStats(og).virgin_blocks == 1);
        TEST_ASSERT(OTA::bitmapStats(og).bitmap_allocs == 100);
#endif
    });

Testing::TestCase testBitmapReuseDeadCellsAfterMajor(
    "HEAP_054: after a major the cursor reuses exactly the dead cells, in address order",
    []() {
        auto cfg = bitmapConfig(true);
        cfg.demote_live_fraction = 0.0;   // keep the block uniform
        cfg.validate();
        auto& alloc = initAllocator(cfg);
        auto& og = oldGen(alloc);
        std::vector<char*> ptrs;
        Rooted roots(alloc);
        roots.reserve(100);
        for (int i = 0; i < 200; ++i) {
            ptrs.push_back(static_cast<char*>(allocateIntInOldGen(og, i)));
            if (i % 2 == 0) roots.add(ptrs.back());
        }
        roots.commit();
        runMarkAndSweep(alloc);
        const BlockId b = OTA::blockIdFor(og, ptrs[0]);
        TEST_ASSERT(b.valid());
        TEST_ASSERT(!OTA::demoted(og, b));
        TEST_ASSERT(OTA::metaOf(og, b).live_bytes == 100 * 16);
        for (int i = 0; i < 100; ++i) {
            TEST_ASSERT(allocateIntInOldGen(og, 1000 + i) == ptrs[2 * i + 1]);
        }
        TEST_ASSERT(OTA::allocStateConsistent(og));
    });

Testing::TestCase testBitmapSplitBeforeVirginW6Rule(
    "W6 rule: a small class splits a mixed free cell before taking a virgin block",
    []() {
        auto cfg = bitmapConfig(true);
        cfg.small_class_heap_budget_bytes = 0;   // no bag-first rung
        cfg.validate();
        auto& alloc = initAllocator(cfg);
        auto& og = oldGen(alloc);
        // A 16 KiB object goes to a bag page; its 16 KiB remainder becomes a
        // mixed-class free cell.
        TEST_ASSERT(og.allocate(16 * 1024) != nullptr);
        TEST_ASSERT(allocateIntInOldGen(og, 7) != nullptr);
#if ENABLE_GC_STATS
        TEST_ASSERT(OTA::bitmapStats(og).split_allocs == 1);
        TEST_ASSERT(OTA::bitmapStats(og).virgin_blocks == 0);
#endif
    });

Testing::TestCase testBitmapFreeBodyInUniformBlock(
    "LOS: a freed body returns its granules and clears its bit; the space is reused at once",
    []() {
        // plans/large-object-space.md D2: bodies live in LOS blocks, never in
        // uniform or mixed blocks; a free is a granule-bitmap clear.
        auto cfg = bitmapConfig(true);
        cfg.validate();
        auto& alloc = initAllocator(cfg);
        auto& og = oldGen(alloc);
        void* body = og.allocateLargeBody(64, 64 - 8, Tag_ByteBuffer, /*initial_color=*/false);
        TEST_ASSERT(body != nullptr);
        const BlockId b = OTA::blockIdFor(og, body);
        TEST_ASSERT(og.isLosBlock(b));
        const size_t g = og.largeObjectSpace().granuleBytes();
        const size_t live0 = OTA::metaOf(og, b).live_bytes;
        TEST_ASSERT(live0 >= g);
        TEST_ASSERT(og.sweepNurseryLargeBodies(/*minor_color=*/true) == 1);
        TEST_ASSERT(OTA::metaOf(og, b).live_bytes == live0 - g);
        TEST_ASSERT(og.largeObjectSpace().usedGranules(b.v) == 0);
        void* again = og.allocateLargeBody(64, 64 - 8, Tag_ByteBuffer, false);
        TEST_ASSERT(again == body);               // the freed granule, at once
    });

Testing::TestCase testBitmapFreeBodyInUnsweptMixedBlock(
    "LOS: a body block is never lazily swept; a rooted body survives a major, then frees once",
    []() {
        auto cfg = bitmapConfig(true);
        cfg.initial_sweep_budget = cfg.sweep_work_budget;   // minimum: one slice
        cfg.validate();
        auto& alloc = initAllocator(cfg);
        auto& og = oldGen(alloc);
        char* body = static_cast<char*>(
            og.allocateLargeBody(10 * 1024, 10 * 1024 - 8, Tag_ByteBuffer, false));
        TEST_ASSERT(body != nullptr);
        const BlockId b = OTA::blockIdFor(og, body);
        TEST_ASSERT(og.isLosBlock(b));
        Rooted roots(alloc);
        roots.add(body);
        roots.commit();
        runMarkAndSweep(alloc);                // body marked (rooted): kept
        TEST_ASSERT(OTA::metaOf(og, b).fully_swept);
        const size_t used = og.largeObjectSpace().usedGranules(b.v);
        TEST_ASSERT(used == og.largeObjectSpace().granulesFor(10 * 1024));
        TEST_ASSERT(og.sweepNurseryLargeBodies(/*minor_color=*/true) == 1);
        TEST_ASSERT(og.largeObjectSpace().usedGranules(b.v) == 0);
        TEST_ASSERT(og.sweepNurseryLargeBodies(/*minor_color=*/true) == 0);   // once
    });

Testing::TestCase testBitmapGapSweepDemotedBlock(
    "HEAP_055: a demoted block's gap sweep frees exactly its non-live bytes",
    []() {
        auto cfg = bitmapConfig(true);         // demote at <= 0.5 live
        cfg.validate();
        auto& alloc = initAllocator(cfg);
        auto& og = oldGen(alloc);
        std::vector<char*> ptrs;
        Rooted roots(alloc);
        roots.reserve(80);
        for (int i = 0; i < 400; ++i) {
            ptrs.push_back(static_cast<char*>(allocateIntInOldGen(og, i)));
            if (i % 5 == 0) roots.add(ptrs.back());
        }
        roots.commit();
        runMarkAndSweep(alloc);
        const BlockId b = OTA::blockIdFor(og, ptrs[0]);
        TEST_ASSERT(OTA::demoted(og, b));
        OTA::driveSweepToCompletion(og);
        const BlockInfo& bi = OTA::getBlockTable(og).info(b);
        TEST_ASSERT(OTA::freeListBytesIn(og, bi.start, bi.end) ==
                    bi.totalBytes() - 80 * 16);
        for (int i = 0; i < 400; i += 5) {      // live objects untouched
            TEST_ASSERT(reinterpret_cast<ElmInt*>(ptrs[i])->value == i);
        }
    });

Testing::TestCase testBitmapDetachOnRelease(
    "HEAP_054: releasing the cursor's block detaches it; allocation moves elsewhere",
    []() {
        auto cfg = bitmapConfig(true);
        cfg.validate();
        auto& alloc = initAllocator(cfg);
        auto& og = oldGen(alloc);
        char* p = static_cast<char*>(allocateIntInOldGen(og, 1));
        const size_t cls = OTA::sizeClass(16);
        const BlockId b = OTA::cursorBlock(og, cls);
        const BlockInfo bi = OTA::getBlockTable(og).info(b);
        OTA::releaseBlock(og, b);
        TEST_ASSERT(!OTA::cursorBlock(og, cls).valid());
        TEST_ASSERT(OTA::allocStateConsistent(og));
        char* q = static_cast<char*>(allocateIntInOldGen(og, 2));
        TEST_ASSERT(q != nullptr);
        TEST_ASSERT(OTA::cursorBlock(og, cls).valid());
        TEST_ASSERT(OTA::cursorBlock(og, cls) != b ||
                    OTA::getBlockTable(og).info(OTA::cursorBlock(og, cls)).start != bi.start ||
                    q != p);
        TEST_ASSERT(OTA::allocStateConsistent(og));
    });

Testing::TestCase testBitmapDeadBodyRetiredAtMark(
    "HEAP_056: a dead nursery-owned body is retired at mark end and never freed twice",
    []() {
        auto cfg = bitmapConfig(true);
        cfg.validate();
        auto& alloc = initAllocator(cfg);
        auto& og = oldGen(alloc);
        // Keep the uniform class block alive with a rooted neighbour.
        Rooted roots(alloc);
        // A 64-byte class needs a real 64-byte object: a Tuple3 is 32 B, so
        // use a pinned 64-byte string body kept alive by a root instead.
        void* keep = og.allocateLargeBody(64, 64 - 8, Tag_ByteBuffer, /*initial_color=*/true);
        roots.add(keep);
        roots.commit();
        void* body = og.allocateLargeBody(64, 64 - 8, Tag_ByteBuffer, false);
        TEST_ASSERT(OTA::isBodyTracked(og, body));
        runMarkAndSweep(alloc);                          // body unmarked
        TEST_ASSERT(!OTA::isBodyTracked(og, body));
        TEST_ASSERT(og.sweepNurseryLargeBodies(true) == 0);   // stale slot only
#if ENABLE_GC_STATS
        TEST_ASSERT(OTA::bitmapStats(og).uniform_cells_freed == 0);
#endif
        void* a = og.allocate(64);
        void* c = og.allocate(64);
        TEST_ASSERT(a != c);
        TEST_ASSERT(OTA::allocStateConsistent(og));
    });

Testing::TestCase testDemoteLiveFractionLever(
    "D1b: demote_live_fraction 0.5 / 0.0 / 0.75 demotes the expected blocks; 1.2 is rejected",
    []() {
        struct Case { double f; bool d10, d40, d60; };
        const Case cases[] = {{0.5, true, true, false},
                              {0.0, false, false, false},
                              {0.75, true, true, true}};
        for (bool flag : {false, true}) {
            for (const Case& k : cases) {
                auto cfg = bitmapConfig(flag);
                cfg.demote_live_fraction = k.f;
                cfg.small_class_heap_budget_bytes = 0;
                cfg.validate();
                // Bitmap allocation off is the legacy old gen, which only the legacy
                // nursery can run (HEAP_069): that arm asks for it explicitly.
                auto& alloc = flag ? initAllocator(cfg) : initLegacyAllocator(cfg);
                auto& og = oldGen(alloc);
                // One full block per class, with 10 % / 40 % / 60 % rooted.
                const size_t sizes[] = {16, 24, 32};
                const int pct[] = {10, 40, 60};
                char* firsts[3];
                Rooted roots(alloc);
                roots.reserve(2048);
                for (int c = 0; c < 3; ++c) {
                    const size_t n = cfg.alloc_buffer_size / sizes[c];
                    for (size_t i = 0; i < n; ++i) {
                        char* p = static_cast<char*>(allocInt(og, sizes[c], (i64)i));
                        if (i == 0) firsts[c] = p;
                        if (static_cast<int>(i % 10) < pct[c] / 10) roots.add(p);
                    }
                }
                roots.commit();
                runMarkAndSweep(alloc);
                const bool expect[] = {k.d10, k.d40, k.d60};
                for (int c = 0; c < 3; ++c) {
                    const BlockId b = OTA::blockIdFor(og, firsts[c]);
                    TEST_ASSERT(b.valid());
                    TEST_ASSERT(OTA::demoted(og, b) == expect[c]);
                }
            }
        }
        auto bad = bitmapConfig(true);
        bad.demote_live_fraction = 1.2;
        bool threw = false;
        try { bad.validate(); } catch (const std::invalid_argument&) { threw = true; }
        TEST_ASSERT(threw);
    });
