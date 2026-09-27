/**
 * threaded-gc-06 Step 1 (plans/threaded-gc-06-parallel-minor.md P§3.5,
 * HEAP_068): the survivor prefix may hold Tag_Free fillers (a parallel
 * minor's LAB tails), and every nursery policy input counts OBJECT bytes.
 *
 * Fillers are injected with NurserySpaceTestAccess::appendFillerAfterMinor,
 * which writes exactly what a parallel minor leaves behind: a Tag_Free header
 * inside the prefix and the matching filler_bytes_.
 */

#include "NurseryFillerTest.hpp"

#include <cstdint>
#include <iostream>
#include <sstream>
#include <stdexcept>

#include "Allocator.hpp"
#include "Heap.hpp"
#include "NurserySpace.hpp"
#include "TestHelpers.hpp"
#include "ThreadLocalHeap.hpp"

using namespace Elm;
using namespace Elm::TestHelpers;

#define NF_ASSERT(cond)                                                     \
    do {                                                                    \
        if (!(cond)) {                                                      \
            std::ostringstream oss;                                         \
            oss << "NurseryFiller assertion failed: " #cond                 \
                << " at " __FILE__ ":" << __LINE__;                         \
            std::cerr << oss.str() << std::endl;                            \
            throw std::runtime_error(oss.str());                            \
        }                                                                   \
    } while (0)

namespace {

using NTA = NurserySpaceTestAccess;

// Allocates Ints (fresh, unreferenced) until the next minor GC runs; returns
// how many allocations it took. The GC count is read from the nursery stats,
// so this only works in stats builds.
#if ENABLE_GC_STATS
uint64_t allocsUntilNextMinor(ThreadLocalHeap* heap) {
    NurserySpace& nursery = heap->getNursery();
    const uint64_t m0 = nursery.getStats().minor_gc_count;
    uint64_t n = 0;
    while (nursery.getStats().minor_gc_count == m0) {
        void* obj = heap->allocate(sizeof(ElmInt), Tag_Int);
        NF_ASSERT(obj != nullptr);
        static_cast<ElmInt*>(obj)->value = static_cast<i64>(n);
        ++n;
        NF_ASSERT(n < 100000000);
    }
    return n;
}
#endif

}  // namespace

Testing::TestCase testFillerSkippedBySurvivorWalk(
    "HEAP_068: forEachSurvivor skips fillers and reports object bytes",
    []() {
        auto& alloc = initAllocator(pressureHeapConfig());
        auto* heap = AllocatorTestAccess::getThreadHeap(alloc);
        NurserySpace& nursery = heap->getNursery();
        // Some rooted survivors, then a minor so the prefix is exact.
        std::vector<HPointer> keep;
        for (int i = 0; i < 64; ++i) {
            void* obj = heap->allocate(sizeof(ElmInt), Tag_Int);
            static_cast<ElmInt*>(obj)->value = i;
            keep.push_back(alloc.wrap(obj));
        }
        for (auto& hp : keep) alloc.getRootSet().addRoot(&hp);
        alloc.minorGC();
        size_t bytes0 = 0;
        const size_t n0 = nursery.forEachSurvivor([](void*) {}, &bytes0);
        NTA::appendFillerAfterMinor(nursery, 4096);
        NTA::appendFillerAfterMinor(nursery, 8);   // a bare-header filler
        NF_ASSERT(NTA::fillerBytes(nursery) == 4104);
        size_t bytes1 = 0;
        size_t tags_ok = 0;
        const size_t n1 = nursery.forEachSurvivor([&](void* o) {
            if (getHeader(o)->tag != Tag_Free) ++tags_ok;
        }, &bytes1);
        NF_ASSERT(n1 == n0);
        NF_ASSERT(tags_ok == n1);
        NF_ASSERT(bytes1 == bytes0);
        NF_ASSERT(NTA::objectBytesAllocated(nursery) == bytes0);
        // The next minor copies no filler and leaves none behind (the Ints,
        // age 1 now, are promoted: promotion_age 1).
        alloc.minorGC();
        NF_ASSERT(NTA::fillerBytes(nursery) == 0);
        size_t bytes2 = 0;
        NF_ASSERT(nursery.forEachSurvivor([](void*) {}, &bytes2) == 0);
        NF_ASSERT(bytes2 == 0);
        for (auto& hp : keep) alloc.getRootSet().removeRoot(&hp);
    });

Testing::TestCase testTriggerCountsObjectBytes(
    "HEAP_068: the next minor fires after the same allocation with or without fillers",
    []() {
#if ENABLE_GC_STATS
        uint64_t with_filler = 0, without = 0;
        for (int arm = 0; arm < 2; ++arm) {
            auto& alloc = initAllocator(pressureHeapConfig());
            auto* heap = AllocatorTestAccess::getThreadHeap(alloc);
            NurserySpace& nursery = heap->getNursery();
            alloc.minorGC();
            if (arm == 1) {
                // A filler inside the threshold slack (a larger one is capped
                // and counted: testAllocEndCappedCounted).
                const size_t slack = static_cast<size_t>(NTA::fromEnd(nursery) - NTA::bumpEnd(nursery));
                NTA::appendFillerAfterMinor(nursery, (slack / 2) & ~static_cast<size_t>(7));
            }
            const uint64_t n = allocsUntilNextMinor(heap);
            (arm == 1 ? with_filler : without) = n;
        }
        if (with_filler != without)
            std::cerr << "allocs until next minor: without " << without << " with " << with_filler << std::endl;
        NF_ASSERT(without > 1000);
        NF_ASSERT(with_filler == without);
#endif
    });

Testing::TestCase testGrowthCountsObjectBytes(
    "HEAP_068: nursery growth reads object bytes, not filler bytes",
    []() {
        auto& alloc = initAllocator(pressureHeapConfig());
        auto* heap = AllocatorTestAccess::getThreadHeap(alloc);
        NurserySpace& nursery = heap->getNursery();
        const size_t cap = NTA::capacity(nursery);
        const size_t ceiling = NTA::growthCeiling(nursery);
        if (ceiling <= cap) return;   // this config cannot grow: vacuous but harmless
        // Raw occupancy far over any growth threshold, object bytes tiny.
        NTA::checkAndGrowAt(nursery, cap - 64, cap - 128);
        NF_ASSERT(NTA::capacity(nursery) == cap);
        // The same raw bytes as objects: grows.
        NTA::checkAndGrowAt(nursery, cap - 64, 0);
        NF_ASSERT(NTA::capacity(nursery) > cap);
    });

Testing::TestCase testFailSoftUsesObjectBytes(
    "HEAP_068: the fail-soft test and the clamp count object bytes",
    []() {
        auto& alloc = initAllocator(pressureHeapConfig());
        auto* heap = AllocatorTestAccess::getThreadHeap(alloc);
        NurserySpace& nursery = heap->getNursery();
        alloc.minorGC();
        char* base = NTA::fromBase(nursery);
        char* end0 = NTA::bumpEnd(nursery);
        const size_t thr = static_cast<size_t>(end0 - base);   // empty prefix: base + threshold
        NF_ASSERT(end0 < NTA::fromEnd(nursery));
        // A filler below the slack keeps the clamp at threshold + filler.
        NTA::appendFillerAfterMinor(nursery, 1024);
        NF_ASSERT(NTA::bumpEnd(nursery) == base + thr + 1024);
        // Object bytes are still ~0, so fail-soft must NOT engage even though
        // raw prefix bytes grow: the end stays threshold + fillers.
        NF_ASSERT(NTA::bumpEnd(nursery) < NTA::fromEnd(nursery));
    });

Testing::TestCase testAllocEndCappedCounted(
    "HEAP_068: a filler pushing threshold + fillers past the extent is capped and counted",
    []() {
        auto& alloc = initAllocator(pressureHeapConfig());
        auto* heap = AllocatorTestAccess::getThreadHeap(alloc);
        NurserySpace& nursery = heap->getNursery();
        alloc.minorGC();
        char* base = NTA::fromBase(nursery);
        const size_t room = static_cast<size_t>(NTA::fromEnd(nursery) - base);
        const size_t thr = static_cast<size_t>(NTA::bumpEnd(nursery) - base);
        const size_t slack = room - thr;
        const size_t filler = ((slack + 4096) + 7) & ~static_cast<size_t>(7);
        NF_ASSERT(filler < room);
#if ENABLE_GC_STATS
        const uint64_t c0 = nursery.getStats().pmin.alloc_end_capped;
#endif
        NTA::appendFillerAfterMinor(nursery, filler);
        NF_ASSERT(NTA::bumpEnd(nursery) == NTA::fromEnd(nursery));
#if ENABLE_GC_STATS
        NF_ASSERT(nursery.getStats().pmin.alloc_end_capped == c0 + 1);
#endif
        alloc.minorGC();   // leaves the heap clean for the next test
    });
