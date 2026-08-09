/**
 * Contiguous nursery extents and the slice layer (HEAP_042,
 * plans/contiguous-nursery-space.md §4 Step 2).
 *
 * These pin the properties the extent rewrite is FOR, and the two hazards
 * the plan's adversarial verification surfaced:
 *
 *   - growth must re-derive the membership bounds before the next GC, or
 *     objects in the grown region are treated as non-nursery and never
 *     evacuated (silent corruption);
 *   - a slot's retained physical commit must never be confused with a
 *     heap's logical capacity, and must be dropped when the geometry moves
 *     under a reconfigure (a stale record would skip committing pages that
 *     were never mapped at the new slot base).
 *
 * Heaps are configured PROGRAMMATICALLY (initAllocator(cfg)); an
 * ECO_HEAP_CONFIG env file would apply to every initialize in the binary.
 */

#include "NurseryContiguityTest.hpp"

#include <cstdint>
#include <iostream>
#include <sstream>
#include <vector>

// Loud assertion (same idiom as EnsureHeadroomTest / GCPressureTest): print
// the failed condition before throwing, so the silent catch in
// TestCase::runWithResult doesn't swallow the diagnostic.
#define NC_ASSERT(cond)                                                     \
    do {                                                                    \
        if (!(cond)) {                                                      \
            std::ostringstream oss;                                         \
            oss << "NurseryContiguity assertion failed: " #cond             \
                << " at " __FILE__ ":" << __LINE__;                         \
            std::cerr << oss.str() << std::endl;                            \
            throw std::runtime_error(oss.str());                            \
        }                                                                   \
    } while (0)

#include "Allocator.hpp"
#include "Heap.hpp"
#include "NurserySpace.hpp"
#include "TestHelpers.hpp"
#include "ThreadLocalHeap.hpp"

using namespace Elm;
using namespace Elm::TestHelpers;

namespace {

using NTA = NurserySpaceTestAccess;

constexpr size_t kCell = sizeof(ElmInt);

// A heap small enough that a handful of allocations fills it, with a growth
// threshold low enough that the FIRST minor GC with live survivors grows the
// nursery. 16 KiB pages x 16 blocks = 128 KiB per side initially; the cap
// allows several doublings.
HeapConfig growableHeapConfig() {
    HeapConfig cfg;
    cfg.alloc_buffer_size          = 16 * 1024;
    cfg.nursery_block_count        = 16;    // 128 KiB per side
    cfg.nursery_max_block_count    = 256;   // 2 MiB per side ceiling
    cfg.initial_old_gen_size       = 256 * 1024;
    cfg.max_heap_size              = 64ULL * 1024 * 1024;
    cfg.large_object_threshold     = 16 * 1024;
    cfg.nursery_growth_threshold   = 0.01f;  // grow on the first live GC
    cfg.promotion_age              = 3;      // keep survivors IN the nursery
    cfg.validate();
    return cfg;
}

// Same shape, different block size — used to move every slot base so a
// stale retained-commit record would be caught.
HeapConfig otherGeometryConfig() {
    HeapConfig cfg = growableHeapConfig();
    cfg.alloc_buffer_size      = 32 * 1024;
    cfg.nursery_block_count    = 8;         // still 128 KiB per side
    cfg.large_object_threshold = 32 * 1024;
    cfg.initial_old_gen_size   = 256 * 1024;
    cfg.validate();
    return cfg;
}

// Allocates `count` Ints, rooting every `root_every`-th one so a minor GC has
// real survivors to copy. Returns the roots (registered with the root set).
std::vector<HPointer> allocateAndRoot(Allocator& alloc, size_t count,
                                      size_t root_every,
                                      std::vector<HPointer>& storage) {
    storage.reserve(count / root_every + 8);
    for (size_t i = 0; i < count; ++i) {
        void* obj = alloc.allocate(sizeof(ElmInt), Tag_Int);
        NC_ASSERT(obj != nullptr);
        static_cast<ElmInt*>(obj)->value = static_cast<i64>(i);
        if (i % root_every == 0) {
            storage.push_back(AllocatorTestAccess::toPointer(obj));
            alloc.getRootSet().addRoot(&storage.back());
        }
    }
    return storage;
}

void dropRoots(Allocator& alloc, std::vector<HPointer>& roots) {
    for (auto& r : roots) alloc.getRootSet().removeRoot(&r);
}

} // namespace

// ============================================================================
// (1) Both semi-spaces are single contiguous extents, mirrored and equal
// ============================================================================

Testing::TestCase testNurseryExtentsAreContiguousAndMirrored(
    "HEAP_042: semi-spaces are contiguous, equal-sized, low < high extents",
    []() {
        auto& alloc = initAllocator(growableHeapConfig());
        auto* heap = AllocatorTestAccess::getThreadHeap(alloc);
        NC_ASSERT(heap != nullptr);
        NurserySpace& nursery = heap->getNursery();

        char* from_base = NTA::fromBase(nursery);
        char* to_base   = NTA::toBase(nursery);
        const size_t cap = NTA::capacity(nursery);

        NC_ASSERT(from_base != nullptr && to_base != nullptr);
        NC_ASSERT(cap > 0);

        // From-space starts low (initialize seats from_is_low_ = true), and
        // every low address is below every high address — the property the
        // O(1) membership tests rely on.
        NC_ASSERT(NTA::fromIsLow(nursery));
        NC_ASSERT(from_base + cap <= to_base);

        // Bump starts at the base and the clamped end never exceeds the
        // extent.
        NC_ASSERT(NTA::bumpPtr(nursery) == from_base);
        NC_ASSERT(NTA::bumpEnd(nursery) <= from_base + cap);

        // Every byte of the extent is inside the nursery — no interior gaps.
        // (The block design's cached bounds spanned inter-block holes; this
        // is the property that replaces it.)
        for (size_t off = 0; off < cap; off += 4096) {
            NC_ASSERT(NTA::contains(nursery, from_base + off));
            NC_ASSERT(NTA::isInFromSpace(nursery, from_base + off));
            NC_ASSERT(NTA::contains(nursery, to_base + off));
            NC_ASSERT(NTA::isInToSpace(nursery, to_base + off));
        }
        NC_ASSERT(!NTA::contains(nursery, from_base - 8));
        NC_ASSERT(!NTA::contains(nursery, to_base + cap));

        // Allocation walks the extent contiguously: consecutive objects are
        // adjacent, with no block-boundary jumps.
        void* prev = alloc.allocate(sizeof(ElmInt), Tag_Int);
        NC_ASSERT(prev != nullptr);
        for (size_t i = 0; i < 256; ++i) {
            void* obj = alloc.allocate(sizeof(ElmInt), Tag_Int);
            NC_ASSERT(obj != nullptr);
            NC_ASSERT(static_cast<char*>(obj) == static_cast<char*>(prev) + kCell);
            prev = obj;
        }
    });

// ============================================================================
// (2) Growth extends both extents IN PLACE, and the grown region is collected
// ============================================================================
//
// THE regression this test exists for (verification BLOCKER): checkAndGrow
// must re-derive low_end_/high_end_ after raising capacity. If it does not,
// isInFromSpace() is stale, and the next minor GC treats objects allocated in
// the grown region as non-nursery — evacuate() returns without forwarding
// them and the mutator reads freed memory.

Testing::TestCase testNurseryGrowthExtendsInPlaceAndSurvivesGC(
    "HEAP_042: growth extends extents in place and the grown region still collects",
    []() {
        auto& alloc = initAllocator(growableHeapConfig());
        auto* heap = AllocatorTestAccess::getThreadHeap(alloc);
        NC_ASSERT(heap != nullptr);
        NurserySpace& nursery = heap->getNursery();

        char* low0  = NTA::fromBase(nursery);
        char* high0 = NTA::toBase(nursery);
        const size_t cap0 = NTA::capacity(nursery);

        // Fill with rooted survivors and collect: to-space occupancy above
        // nursery_growth_threshold (1%) triggers growth.
        std::vector<HPointer> roots;
        allocateAndRoot(alloc, 2000, 4, roots);
        alloc.minorGC();

        const size_t cap1 = NTA::capacity(nursery);
        NC_ASSERT(cap1 > cap0);                       // it grew
        NC_ASSERT(cap1 <= NTA::growthCeiling(nursery));

        // IN PLACE: the extents kept their bases (both sides), so no object
        // moved and no copy was needed. from/to have swapped roles, so
        // compare against the pair of bases rather than a fixed side.
        char* low1  = NTA::fromIsLow(nursery) ? NTA::fromBase(nursery) : NTA::toBase(nursery);
        char* high1 = NTA::fromIsLow(nursery) ? NTA::toBase(nursery)   : NTA::fromBase(nursery);
        NC_ASSERT(low1 == low0);
        NC_ASSERT(high1 == high0);

        // Both sides grew equally — capacity is one value for the pair.
        NC_ASSERT(low1 + cap1 <= high1);

        // The GROWN region is live nursery: bounds were refreshed. Allocate
        // into it (past the old capacity), root it, collect, and read back.
        NC_ASSERT(NTA::contains(nursery, low1 + cap0));
        NC_ASSERT(NTA::contains(nursery, high1 + cap0));

        std::vector<HPointer> grown_roots;
        // RESERVE: the root set stores &grown_roots.back(), so a reallocation
        // would dangle every previously-registered root.
        grown_roots.reserve(cap1 / kCell + 16);
        // Push the bump beyond the pre-growth capacity, rooting as we go.
        while (static_cast<size_t>(NTA::bumpPtr(nursery) - NTA::fromBase(nursery)) < cap0 + 4096) {
            void* obj = alloc.allocate(sizeof(ElmInt), Tag_Int);
            if (!obj) break;                 // threshold tripped: collect below
            static_cast<ElmInt*>(obj)->value = 0x5EED;
            grown_roots.push_back(AllocatorTestAccess::toPointer(obj));
            alloc.getRootSet().addRoot(&grown_roots.back());
        }
        NC_ASSERT(!grown_roots.empty());

        alloc.minorGC();

        // Every object allocated in the grown region survived with its value
        // intact. A stale-bounds bug shows up exactly here.
        for (auto& r : grown_roots) {
            void* obj = readBarrier(r);
            NC_ASSERT(obj != nullptr);
            NC_ASSERT(getHeader(obj)->tag == Tag_Int);
            NC_ASSERT(static_cast<ElmInt*>(obj)->value == 0x5EED);
        }

        dropRoots(alloc, grown_roots);
        dropRoots(alloc, roots);
    });

// ============================================================================
// (3) Releasing a slice retains its commit; re-acquiring reuses the slot
// ============================================================================

Testing::TestCase testNurserySliceReleaseRetainsCommitAcrossReacquire(
    "HEAP_042: a released slice slot is reused and its committed pages retained",
    []() {
        auto& alloc = initAllocator(growableHeapConfig());
        auto* heap = AllocatorTestAccess::getThreadHeap(alloc);
        NC_ASSERT(heap != nullptr);

        // Grow the nursery so the slot's retained commit exceeds what a fresh
        // heap asks for — the case where retained > capacity.
        {
            NurserySpace& nursery = heap->getNursery();
            std::vector<HPointer> roots;
            allocateAndRoot(alloc, 2000, 4, roots);
            alloc.minorGC();
            NC_ASSERT(NTA::capacity(nursery) > 0);
            dropRoots(alloc, roots);
        }

        const size_t committed_low_before  = alloc.getNurseryLowCommittedBytes();
        const size_t committed_high_before = alloc.getNurseryHighCommittedBytes();
        NC_ASSERT(committed_low_before > 0);
        NC_ASSERT(committed_low_before == committed_high_before);

        // Tear the heap down and stand a new one up on the SAME geometry:
        // the freed slot is reclaimed and its pages are reused, so the
        // process-wide committed totals must not grow (the Issue-#40
        // property the block free-lists used to provide).
        alloc.cleanupThread();
        alloc.initThread();

        auto* heap2 = AllocatorTestAccess::getThreadHeap(alloc);
        NC_ASSERT(heap2 != nullptr);
        NurserySpace& nursery2 = heap2->getNursery();

        NC_ASSERT(alloc.getNurseryLowCommittedBytes() == committed_low_before);
        NC_ASSERT(alloc.getNurseryHighCommittedBytes() == committed_high_before);

        // Slot 0 was free, so the new heap claims it: same bases as the
        // original heap had.
        NC_ASSERT(NTA::sliceSlot(nursery2) == 0);

        // Its CAPACITY, though, restarts at the configured initial size —
        // retained commit is physical and dormant, never part of the extent.
        NC_ASSERT(NTA::capacity(nursery2) ==
                  growableHeapConfig().nurseryInitialPerSideBytes());

        // And the reused pages are usable.
        for (size_t i = 0; i < 512; ++i) {
            void* obj = alloc.allocate(sizeof(ElmInt), Tag_Int);
            NC_ASSERT(obj != nullptr);
            static_cast<ElmInt*>(obj)->value = static_cast<i64>(i);
        }
        alloc.minorGC();
    });

// ============================================================================
// (4) A reconfigure that moves slot bases drops stale retained-commit records
// ============================================================================
//
// Slice geometry is config-derived while the region is first-init-wins, so a
// reset with a different alloc_buffer_size moves every slot base. A retained
// record kept across that change would make the next acquire skip committing
// pages that were never mapped at the new base — a PROT_NONE fault on first
// touch. (The unit-test binary reconfigures like this constantly.)

Testing::TestCase testNurserySliceGeometryRebuiltOnReconfigure(
    "HEAP_042: reconfiguring the heap rebuilds slice geometry and re-commits",
    []() {
        // First geometry: 16 KiB pages.
        {
            auto& alloc = initAllocator(growableHeapConfig());
            auto* heap = AllocatorTestAccess::getThreadHeap(alloc);
            NC_ASSERT(heap != nullptr);
            std::vector<HPointer> roots;
            allocateAndRoot(alloc, 1500, 8, roots);
            alloc.minorGC();
            dropRoots(alloc, roots);
        }

        // Second geometry: 32 KiB pages — every slot base moves.
        {
            auto& alloc = initAllocator(otherGeometryConfig());
            auto* heap = AllocatorTestAccess::getThreadHeap(alloc);
            NC_ASSERT(heap != nullptr);
            NurserySpace& nursery = heap->getNursery();

            NC_ASSERT(NTA::capacity(nursery) ==
                      otherGeometryConfig().nurseryInitialPerSideBytes());

            // Touch every page of BOTH extents: if a stale retained record
            // had suppressed the commit, this faults.
            char* from_base = NTA::fromBase(nursery);
            char* to_base   = NTA::toBase(nursery);
            const size_t cap = NTA::capacity(nursery);
            for (size_t off = 0; off + 8 <= cap; off += 4096) {
                *reinterpret_cast<volatile uint64_t*>(from_base + off) = 0xA5;
                *reinterpret_cast<volatile uint64_t*>(to_base + off)   = 0x5A;
            }

            // And the heap still works end to end.
            std::vector<HPointer> roots;
            allocateAndRoot(alloc, 1500, 8, roots);
            alloc.minorGC();
            for (auto& r : roots) {
                void* obj = readBarrier(r);
                NC_ASSERT(obj != nullptr);
                NC_ASSERT(getHeader(obj)->tag == Tag_Int);
            }
            dropRoots(alloc, roots);
        }

        // Back to the first geometry, to prove the rebuild is not one-way.
        {
            auto& alloc = initAllocator(growableHeapConfig());
            auto* heap = AllocatorTestAccess::getThreadHeap(alloc);
            NC_ASSERT(heap != nullptr);
            NurserySpace& nursery = heap->getNursery();
            NC_ASSERT(NTA::capacity(nursery) ==
                      growableHeapConfig().nurseryInitialPerSideBytes());
            char* from_base = NTA::fromBase(nursery);
            for (size_t off = 0; off + 8 <= NTA::capacity(nursery); off += 4096) {
                *reinterpret_cast<volatile uint64_t*>(from_base + off) = 0xC3;
            }
            std::vector<HPointer> roots;
            allocateAndRoot(alloc, 800, 8, roots);
            alloc.minorGC();
            dropRoots(alloc, roots);
        }
    });

// ============================================================================
// (5) computeAllocEnd fail-softs when survivors already sit past the threshold
// ============================================================================
//
// If a GC leaves survivors at or beyond threshold_total_bytes_, re-clamping
// would hand the mutator zero headroom and the next allocation would trigger
// another GC that can free nothing — a GC loop. The fail-soft hands out the
// rest of the extent instead. (This clause is inherited from the block
// design's already-full arm, which the nursery-threshold-fast-path plan
// introduced for exactly this reason.)

Testing::TestCase testNurseryAllocEndFailSoftWhenSurvivorsPastThreshold(
    "HEAP_042: computeAllocEnd fail-softs to the extent end when survivors exceed the threshold",
    []() {
        HeapConfig cfg = growableHeapConfig();
        cfg.nursery_growth_threshold = 0.99f;  // never grow: force the corner
        cfg.nursery_gc_threshold     = 0.10f;  // trip at 10% of the extent
        cfg.validate();

        auto& alloc = initAllocator(cfg);
        auto* heap = AllocatorTestAccess::getThreadHeap(alloc);
        NC_ASSERT(heap != nullptr);
        NurserySpace& nursery = heap->getNursery();

        const size_t cap = NTA::capacity(nursery);
        const size_t threshold = static_cast<size_t>(cap * 0.10f);

        // Root well past the threshold so the survivors alone exceed it.
        std::vector<HPointer> roots;
        const size_t want = (threshold / kCell) * 2 + 64;
        allocateAndRoot(alloc, want, 1, roots);

        alloc.minorGC();

        // Survivors now sit past the trip point ...
        NC_ASSERT(static_cast<size_t>(NTA::bumpPtr(nursery) -
                                      NTA::fromBase(nursery)) >= threshold);
        // ... so the end fail-softs to the extent end rather than clamping
        // behind the bump pointer.
        NC_ASSERT(NTA::bumpEnd(nursery) == NTA::fromEnd(nursery));
        NC_ASSERT(NTA::bumpEnd(nursery) >= NTA::bumpPtr(nursery));

        // The mutator can therefore make progress instead of GC-looping.
        for (size_t i = 0; i < 64; ++i) {
            void* obj = alloc.allocate(sizeof(ElmInt), Tag_Int);
            NC_ASSERT(obj != nullptr);
            static_cast<ElmInt*>(obj)->value = static_cast<i64>(i);
        }

        dropRoots(alloc, roots);
    });
