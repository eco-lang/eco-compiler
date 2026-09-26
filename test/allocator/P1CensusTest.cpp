/**
 * threaded-gc-04 (plans/threaded-gc-04-frozen-published-heap.md): the P1
 * census (detectors O and W) and the two P1 hazards the static audit found:
 *   S1  chunk-chain backings filled after later allocations;
 *   S2  large pointer-bearing objects born in the old gen.
 *
 * The census tests only do something where the census is compiled
 * (ECO_HEAP_VALIDATE or -DECO_P1_CENSUS=ON); the S1/S2 regression tests are
 * correctness tests and run in every build. Configs are built
 * programmatically (unit tests do not see ECO_HEAP_CONFIG).
 */

#include "P1CensusTest.hpp"

#include <cstring>
#include <stdexcept>
#include <vector>

#include "Allocator.hpp"
#include "Heap.hpp"
#include "HeapHelpers.hpp"
#include "NurserySpace.hpp"
#include "OldGenSpace.hpp"
#include "P1Census.hpp"
#include "TestHelpers.hpp"
#include "ThreadLocalHeap.hpp"

using namespace Elm;
using namespace Elm::TestHelpers;

extern "C" bool eco_g_list_chunks;

namespace {

HeapConfig smallConfig() {
    HeapConfig cfg;
    cfg.alloc_buffer_size       = 32 * 1024;
    cfg.nursery_block_count     = 4;
    cfg.initial_old_gen_size    = 256 * 1024;
    cfg.max_heap_size           = 256ULL * 1024 * 1024;
    cfg.large_object_threshold  = 8 * 1024;
    cfg.decommit_on_oldgen_release = false;
    cfg.gc_thread_mode          = 0;
    cfg.validate();
    return cfg;
}

// A small, non-growing nursery (64 KiB per side): a chain of 20,000
// elements (160 KiB of backings) cannot be built without several minors.
HeapConfig smallNurseryConfig() {
    HeapConfig cfg = smallConfig();
    cfg.nursery_block_count     = 4;
    cfg.nursery_max_block_count = 4;
    cfg.validate();
    return cfg;
}

i64 intValue(HPointer hp) {
    void* obj = Allocator::instance().resolve(hp);
    if (obj == nullptr || getHeader(obj)->tag != Tag_Int) {
        throw std::runtime_error("expected a heap Int");
    }
    return static_cast<ElmInt*>(obj)->value;
}

// Allocates garbage so the nursery is reused (overwrites dead cells).
void churn(size_t n) {
    for (size_t i = 0; i < n; ++i) (void)alloc::allocInt(static_cast<i64>(0x5A5A0000 + i));
}

#if P1_CENSUS_COMPILED
struct CensusMode {
    explicit CensusMode(int m, uint32_t sample = 1) {
        p1::setModeForTesting(m);
        p1::setSampleForTesting(sample);
        p1::resetForTesting();
        NurserySpaceTestAccess::resetSurvivorWriteCensus();
    }
    ~CensusMode() {
        p1::resetForTesting();
        p1::setSampleForTesting(0);
        p1::setModeForTesting(-1);
    }
};
#endif

}  // namespace

// ============================================================================
// Detector O / W (census builds only)
// ============================================================================

Testing::TestCase testP1CensusModeParsing(
    "HEAP_SNAPSHOT_001: census mode override and defaults",
    []() {
#if P1_CENSUS_COMPILED
        const int m = p1::mode();
        TEST_ASSERT(m >= 0 && m <= 2);
        p1::setModeForTesting(0);
        TEST_ASSERT(p1::mode() == 0);
        p1::setModeForTesting(2);
        TEST_ASSERT(p1::mode() == 2);
        p1::setModeForTesting(-1);
        TEST_ASSERT(p1::mode() == m);
        TEST_ASSERT(p1::sample() >= 1 && (p1::sample() & (p1::sample() - 1)) == 0);
        TEST_ASSERT(p1::every() >= 1);
        // The hash ignores the GC-owned header bits.
        alignas(8) char obj[24] = {};
        Header* h = reinterpret_cast<Header*>(obj);
        h->tag = Tag_Int;
        const uint64_t h0 = p1::hashObject(obj, sizeof obj);
        h->age = 2; h->color = 1; h->builder = 1;
        TEST_ASSERT(p1::hashObject(obj, sizeof obj) == h0);
        obj[8] = 1;
        TEST_ASSERT(p1::hashObject(obj, sizeof obj) != h0);
#endif
    });

Testing::TestCase testP1OldGenCatchesWriteAfterPromotion(
    "HEAP_SNAPSHOT_001: detector O catches a write into a promoted object",
    []() {
#if P1_CENSUS_COMPILED
        CensusMode cm(1);
        auto& alloc = initAllocator(smallConfig());
        const u64 kTwoInts = 0b0101;
        Unboxable v1; v1.i = 1;
        Unboxable v2; v2.i = 2;
        HPointer obj = alloc::custom(7, {v1, v2}, kTwoInts);
        alloc.getRootSet().addRoot(&obj);
        alloc.minorGC();                       // age 1
        alloc.minorGC();                       // promoted; recorded after the drain
        TEST_ASSERT(p1::countsForTesting().o_recorded >= 1);
        static_cast<Custom*>(alloc.resolve(obj))->values[1].i = 99;   // the violation
        alloc.majorGC();                       // major-start verify
        TEST_ASSERT(p1::countsForTesting().o_mismatched == 1);
        TEST_ASSERT(p1::oHitsForTesting(Tag_Custom, 7, 3) == 1);
        alloc.majorGC();                       // counted once, not again
        TEST_ASSERT(p1::countsForTesting().o_mismatched == 1);
        alloc.getRootSet().removeRoot(&obj);
#endif
    });

Testing::TestCase testP1OldGenNoFalsePositiveAcrossMajors(
    "HEAP_SNAPSHOT_001: detector O has no false positives across majors and cell reuse",
    []() {
#if P1_CENSUS_COMPILED
        CensusMode cm(1);
        auto& alloc = initAllocator(smallConfig());
        std::vector<HPointer> keep;
        keep.reserve(4000);
        for (int round = 0; round < 6; ++round) {
            for (int i = 0; i < 4000; ++i) {
                HPointer p = alloc::allocInt(round * 10000 + i);
                if (i % 5 == 0 && keep.size() < keep.capacity()) {
                    keep.push_back(p);
                    alloc.getRootSet().addRoot(&keep.back());
                }
            }
            alloc.minorGC();
            alloc.minorGC();
            alloc.majorGC();                   // prune, then cells get reused
            churn(20000);
        }
        auto c = p1::countsForTesting();
        TEST_ASSERT(c.o_recorded > 0);
        TEST_ASSERT(c.o_checked > 0);
        TEST_ASSERT(c.o_mismatched == 0);
        for (auto& h : keep) alloc.getRootSet().removeRoot(&h);
#endif
    });

Testing::TestCase testP1OldGenPruneDropsDead(
    "HEAP_SNAPSHOT_001: detector O drops unmarked objects at mark end",
    []() {
#if P1_CENSUS_COMPILED
        CensusMode cm(1);
        auto& alloc = initAllocator(smallConfig());
        HPointer obj = alloc::allocInt(42);
        alloc.getRootSet().addRoot(&obj);
        alloc.minorGC();
        alloc.minorGC();                       // promoted + recorded
        const uint64_t entries = p1::countsForTesting().o_entries;
        TEST_ASSERT(entries >= 1);
        alloc.getRootSet().removeRoot(&obj);   // now garbage
        alloc.majorGC();
        auto c = p1::countsForTesting();
        TEST_ASSERT(c.o_dropped >= 1);
        TEST_ASSERT(c.o_entries < entries);
#endif
    });

Testing::TestCase testP1OldGenCompactionInvalidates(
    "HEAP_SNAPSHOT_001: scheduling compaction clears detector O's table",
    []() {
#if P1_CENSUS_COMPILED
        CensusMode cm(1);
        auto& alloc = initAllocator(smallConfig());
        std::vector<HPointer> keep;
        keep.reserve(400);
        for (int i = 0; i < 20000; ++i) {
            HPointer p = alloc::allocInt(i);
            if (i % 50 == 0 && keep.size() < keep.capacity()) {
                keep.push_back(p);
                alloc.getRootSet().addRoot(&keep.back());
            }
        }
        alloc.minorGC();
        alloc.minorGC();
        alloc.majorGC();                       // sparse blocks: compaction candidates
        auto* og = AllocatorTestAccess::getOldGen(alloc);
        const uint64_t before = p1::countsForTesting().o_entries;
        OldGenSpaceTestAccess::scheduleCompaction(*og);
        if (OldGenSpaceTestAccess::getCompactPhase(*og) != CompactionPhase::Idle && before > 0) {
            auto c = p1::countsForTesting();
            TEST_ASSERT(c.o_entries == 0);
            TEST_ASSERT(c.o_invalidations == 1);
        }
        for (auto& h : keep) alloc.getRootSet().removeRoot(&h);
        initAllocator(smallConfig());          // leave no compaction in flight
#endif
    });

Testing::TestCase testP1WriteSiteFreshIsLegal(
    "HEAP_SNAPSHOT_001: detector W accepts writes into fresh objects",
    []() {
#if P1_CENSUS_COMPILED
        CensusMode cm(1);
        initAllocator(smallConfig());
        HPointer arr = alloc::allocArray(4);
        Unboxable v; v.i = 5;
        alloc::arrayPush(Allocator::instance().resolve(arr), v, false);
        auto c = p1::countsForTesting();
        TEST_ASSERT(c.w_calls >= 1);
        TEST_ASSERT(c.w_violations == 0);
#endif
    });

Testing::TestCase testP1WriteSiteAgedCaught(
    "HEAP_SNAPSHOT_001: detector W catches a push into a survived array",
    []() {
#if P1_CENSUS_COMPILED
        CensusMode cm(1);
        auto& alloc = initAllocator(smallConfig());
        HPointer arr = alloc::allocArray(4);
        alloc.getRootSet().addRoot(&arr);
        alloc.minorGC();                        // survives: age 1
        Unboxable v; v.i = 5;
        alloc::arrayPush(alloc.resolve(arr), v, false);   // the violation
        TEST_ASSERT(p1::wViolationsForTesting("arrayPush") == 1);
        alloc.getRootSet().removeRoot(&arr);
#endif
    });

Testing::TestCase testP1WriteSiteBuilderExempt(
    "HEAP_SNAPSHOT_001: detector W exempts builder objects",
    []() {
#if P1_CENSUS_COMPILED
        CensusMode cm(1);
        auto& alloc = initAllocator(smallConfig());
        HPointer arr = alloc::allocArrayBuilder(4);
        alloc.getRootSet().addRoot(&arr);
        alloc.minorGC();                        // builder: not aged, not promoted
        Unboxable v; v.i = 5;
        alloc::arrayPush(alloc.resolve(arr), v, false);
        TEST_ASSERT(p1::countsForTesting().w_violations == 0);
        alloc::clear_builder(getHeader(alloc.resolve(arr)));
        alloc.getRootSet().removeRoot(&arr);
#endif
    });

// ============================================================================
// S1: chunk chains survive GCs during their construction (every build)
// ============================================================================

namespace {

void checkList(HPointer list, size_t n, i64 mul, i64 add, const char* what) {
    size_t i = 0;
    for (alloc::ListCursor c(list); !c.done(); c.next(), ++i) {
        if (i >= n || intValue(c.current().p) != static_cast<i64>(i) * mul + add) {
            throw std::runtime_error(std::string(what) + ": element " + std::to_string(i) + " wrong");
        }
    }
    if (i != n) throw std::runtime_error(std::string(what) + ": wrong length");
}

bool anyBuilderInSpine(HPointer list) {
    auto& alloc = Allocator::instance();
    for (HPointer cur = list; !alloc::isNil(cur);) {
        void* o = alloc.resolve(cur);
        Header* h = getHeader(o);
        if (h->builder) return true;
        if (h->tag == Tag_ConsChunk) {
            ConsChunk* cv = static_cast<ConsChunk*>(o);
            if (getHeader(alloc.resolve(cv->backing))->builder) return true;
            cur = cv->next;
        } else if (h->tag == Tag_Cons) {
            cur = static_cast<Cons*>(o)->tail;
        } else {
            break;
        }
    }
    return false;
}

}  // namespace

Testing::TestCase testP1ChunkChainSurvivesMidConstructionGC(
    "HEAP_SNAPSHOT_001 S1: a chunk-chain list built across a minor GC keeps every element",
    []() {
#if P1_CENSUS_COMPILED
        CensusMode cm(1);
#endif
        auto& alloc = initAllocator(smallNurseryConfig());
        const bool saved = eco_g_list_chunks;
        eco_g_list_chunks = true;
        NurserySpace& nursery = AllocatorTestAccess::getThreadHeap(alloc)->getNursery();

        // (1) A chain that fits the builder budget, built across a minor GC:
        // the nursery is parked so the FIRST backing fits and a later chain
        // allocation collects (the backing exists, unfilled, at that GC).
        const u32 maxElems = alloc::listBackingMaxElems();
        const size_t n = maxElems + maxElems / 2;          // two links
        TEST_ASSERT(alloc::chunkChainFits(static_cast<u32>(n)));
        std::vector<HPointer> elems(n, alloc::listNil());
        Elm::StackRootRangeGuard elems_guard(elems.data(), elems.size(), ~uint64_t{0});
        for (size_t i = 0; i < n; ++i) elems[i] = alloc::allocInt(static_cast<i64>(i * 3 + 1));
        alloc.minorGC();
        alloc.minorGC();                                  // elements now old
        const size_t first_link = (n % maxElems) * sizeof(Unboxable) + 64;
        while (NurserySpaceTestAccess::headroom(nursery) > first_link + 1024) {
            (void)alloc::allocInt(-1);
        }
        const uint64_t minors0 = alloc.getCombinedStats().minor_gc_count;
        HPointer list = alloc::listFromPointers(elems);
        alloc.getRootSet().addRoot(&list);
        TEST_ASSERT(alloc.getCombinedStats().minor_gc_count > minors0);   // GC mid-build
        churn(20000);
        alloc.minorGC();
        churn(20000);
        alloc.minorGC();
        checkList(list, n, 3, 1, "S1 chunk chain");
        TEST_ASSERT(!anyBuilderInSpine(list));
#if P1_CENSUS_COMPILED
        alloc.majorGC();                                  // detector O's verify
        auto c = p1::countsForTesting();
        auto n1 = NurserySpaceTestAccess::survivorWriteCensusCounts();
        if (c.o_mismatched != 0 || n1.mismatched != 0 || c.w_violations != 0) {
            throw std::runtime_error("S1: chunk chain written after survival: O=" +
                std::to_string(c.o_mismatched) + " N=" + std::to_string(n1.mismatched) +
                " W=" + std::to_string(c.w_violations));
        }
#endif
        alloc.getRootSet().removeRoot(&list);

        // (2) Over the builder budget: the cons-cell path, still correct.
        const size_t big = 20000;
        TEST_ASSERT(!alloc::chunkChainFits(static_cast<u32>(big)));
        std::vector<HPointer> many(big, alloc::listNil());
        Elm::StackRootRangeGuard many_guard(many.data(), many.size(), ~uint64_t{0});
        for (size_t i = 0; i < big; ++i) many[i] = alloc::allocInt(static_cast<i64>(i * 5 + 2));
        HPointer biglist = alloc::listFromPointers(many);
        alloc.getRootSet().addRoot(&biglist);
        churn(20000);
        alloc.minorGC();
        checkList(biglist, big, 5, 2, "S1 cons fallback");
        alloc.getRootSet().removeRoot(&biglist);
        eco_g_list_chunks = saved;
    });

// ============================================================================
// S2: large pointer-bearing objects born in the old gen (every build)
// ============================================================================

Testing::TestCase testBornOldArrayChildrenSurviveMinors(
    "HEAP_061 S2: a born-old array's young children survive minor GCs",
    []() {
#if P1_CENSUS_COMPILED
        CensusMode cm(1);
#endif
        auto& alloc = initAllocator(smallConfig());
        const size_t n = 2000;   // 16 KB of slots: over the 8 KB threshold
        std::vector<HPointer> elems(n, alloc::listNil());
        // allocArray goes through ThreadLocalHeap::allocate: >= the large
        // object threshold is born in the old gen. Rooting `elems` across the
        // allocation, then filling with no allocation in between, is the
        // kernel pattern (arrayFromPointers when its fast path misses,
        // ListExports toArray).
        HPointer arr;
        {
            Elm::StackRootRangeGuard guard(elems.data(), elems.size(), ~uint64_t{0});
            for (size_t i = 0; i < n; ++i) elems[i] = alloc::allocInt(static_cast<i64>(i * 7));
            // Allocator::allocate -> ThreadLocalHeap::allocate: at or above the
            // large-object threshold the array is born in the old gen.
            const size_t total = (sizeof(ElmArray) + n * sizeof(Unboxable) + 7) & ~size_t{7};
            ElmArray* a0 = static_cast<ElmArray*>(alloc.allocate(total, Tag_Array));
            a0->header.size = static_cast<u32>(n);
            a0->length = 0;
            a0->padding = 0;
            a0->header.unboxed = 0;
            TEST_ASSERT(!alloc.isInNursery(a0));   // born old
            for (size_t i = 0; i < n; ++i) alloc::arrayPush(a0, alloc::boxed(elems[i]), true);
            arr = alloc.wrap(a0);
        }
        alloc.getRootSet().addRoot(&arr);
        elems.clear();                         // the array is the only owner now
        for (int k = 0; k < 3; ++k) {
            churn(30000);
            alloc.minorGC();
        }
        ElmArray* a = static_cast<ElmArray*>(alloc.resolve(arr));
        TEST_ASSERT(a->length == n);
        for (size_t i = 0; i < n; ++i) {
            if (intValue(a->elements[i].p) != static_cast<i64>(i * 7)) {
                throw std::runtime_error("S2: element " + std::to_string(i) + " lost");
            }
        }
        alloc.majorGC();
        a = static_cast<ElmArray*>(alloc.resolve(arr));
        for (size_t i = 0; i < n; ++i) TEST_ASSERT(intValue(a->elements[i].p) == static_cast<i64>(i * 7));
#if P1_CENSUS_COMPILED
        TEST_ASSERT(p1::countsForTesting().w_violations == 0);
#endif
        alloc.getRootSet().removeRoot(&arr);
    });

Testing::TestCase testBornOldEntryRetires(
    "HEAP_061: a born-old entry retires after promotion_age + 1 quiet minors",
    []() {
        auto& alloc = initAllocator(smallConfig());
        auto& og = AllocatorTestAccess::getThreadHeap(alloc)->getOldGen();
        const size_t n = 1500;
        const size_t total = (sizeof(ElmArray) + n * sizeof(Unboxable) + 7) & ~size_t{7};
        ElmArray* a0 = static_cast<ElmArray*>(alloc.allocate(total, Tag_Array));
        a0->header.size = static_cast<u32>(n);
        a0->length = 0;
        a0->padding = 0;
        a0->header.unboxed = 0;
        HPointer arr = alloc.wrap(a0);
        alloc.getRootSet().addRoot(&arr);
        TEST_ASSERT(og.isBornOldPending(a0));
        const size_t before = og.bornOld().size();
        alloc.minorGC();
        TEST_ASSERT(og.isBornOldPending(a0));             // 1 quiet minor
        alloc.minorGC();                                  // 2 > promotion_age (1)
        TEST_ASSERT(!og.isBornOldPending(a0));
        TEST_ASSERT(og.bornOld().size() + 1 == before);
        alloc.getRootSet().removeRoot(&arr);
    });

Testing::TestCase testBornOldDeadEntryPrunedAtMark(
    "HEAP_061: an unreachable born-old entry is dropped at mark end",
    []() {
        auto& alloc = initAllocator(smallConfig());
        auto& og = AllocatorTestAccess::getThreadHeap(alloc)->getOldGen();
        const size_t total = (sizeof(ElmArray) + 1500 * sizeof(Unboxable) + 7) & ~size_t{7};
        ElmArray* a0 = static_cast<ElmArray*>(alloc.allocate(total, Tag_Array));
        a0->header.size = 1500;
        a0->length = 0;
        a0->padding = 0;
        TEST_ASSERT(og.isBornOldPending(a0));
        alloc.majorGC();                                  // unrooted: unmarked
        TEST_ASSERT(!og.isBornOldPending(a0));
    });

Testing::TestCase testBornOldRegionSplitAtMark(
    "HEAP_061: a born-old region is split into its live objects at mark end",
    []() {
        auto& alloc = initAllocator(smallConfig());
        auto& og = AllocatorTestAccess::getThreadHeap(alloc)->getOldGen();
        const size_t count = 700;                        // 700 x 16 B = 11,200 B: born old
        char* region = static_cast<char*>(alloc.allocateRegionSlow(count * sizeof(ElmInt)));
        TEST_ASSERT(!alloc.isInNursery(region));
        std::vector<HPointer> keep;
        for (size_t i = 0; i < count; ++i) {
            ElmInt* e = reinterpret_cast<ElmInt*>(region + i * sizeof(ElmInt));
            std::memset(e, 0, sizeof(ElmInt));
            initHeaderForTag(&e->header, Tag_Int, sizeof(ElmInt));
            e->value = static_cast<i64>(i);
            if (i % 100 == 0) keep.push_back(alloc.wrap(e));
        }
        for (auto& h : keep) alloc.getRootSet().addRoot(&h);
        TEST_ASSERT(og.isBornOldPending(region));
        alloc.majorGC();
        size_t entries = 0;
        for (const auto& b : og.bornOld()) {
            if (b.obj >= region && b.obj < region + count * sizeof(ElmInt)) {
                TEST_ASSERT(b.region == 0);
                ++entries;
            }
        }
        TEST_ASSERT(entries == keep.size());
        for (auto& h : keep) {
            TEST_ASSERT(og.isBornOldPending(alloc.resolve(h)));
            alloc.getRootSet().removeRoot(&h);
        }
    });
