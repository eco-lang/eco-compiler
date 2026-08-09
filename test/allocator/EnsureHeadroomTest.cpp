/**
 * The ensure primitive behind capacity-check hoisting (HEAP_041,
 * plans/capacity-check-hoisting.md §2.4 / §4 Step 2).
 *
 * `ThreadLocalHeap::ensureNursery(n)` must make `bump.end - bump.ptr >= n`
 * true WITHOUT allocating, so a covered straight-line run can then perform
 * UNCHECKED bumps totalling <= n bytes. These tests exercise the three arms
 * of its escalation ladder (advance-on-exhaustion / minor GC / fail-soft
 * unclamp) plus the state the abandoned tails leave behind.
 *
 * Tiny heaps are configured PROGRAMMATICALLY (initAllocator(cfg)) rather
 * than via ECO_HEAP_CONFIG — an env file would apply to every initialize in
 * the test binary and pollute all other suites.
 *
 * The "unchecked bump" helper below is the C++ mirror of what the covered
 * expansion emits: load ptr, bump, store, then write the header and payload
 * in the merge position. It writes a REAL header every time, because the
 * ECO_HEAP_VALIDATE pre-evacuation walk parses [block_start, bump_.ptr) of
 * the current block by header.
 */

#include "EnsureHeadroomTest.hpp"

#include <cstdint>
#include <iostream>
#include <sstream>
#include <vector>

// Loud assertion: prints the failed condition + file:line to stderr before
// throwing, so the silent catch in TestCase::runWithResult doesn't swallow
// the diagnostic (same idiom as GCPressureTest).
#define EH_ASSERT(cond)                                                     \
    do {                                                                    \
        if (!(cond)) {                                                      \
            std::ostringstream oss;                                         \
            oss << "EnsureHeadroom assertion failed: " #cond                \
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

static_assert(sizeof(ElmInt) % 8 == 0, "unchecked bumps must stay 8-aligned");
constexpr size_t kCell = sizeof(ElmInt);

// A tiny heap whose proactive-GC trip point sits BELOW the 4096 B budget
// ceiling (threshold_total_bytes_ = 0.02 * 8 * 16 KiB = 2621 B < 4096), which
// is the only configuration that can reach ensureNursery's fail-soft arm.
HeapConfig tinyThresholdConfig() {
    HeapConfig cfg;
    cfg.alloc_buffer_size      = 16 * 1024;
    cfg.nursery_block_count    = 16;   // 8 blocks per semi-space = 128 KiB
    cfg.initial_old_gen_size   = 256 * 1024;
    cfg.max_heap_size          = 64ULL * 1024 * 1024;
    cfg.large_object_threshold = 16 * 1024;
    cfg.nursery_gc_threshold   = 0.02f;
    cfg.validate();
    return cfg;
}

// One unchecked bump: exactly what a covered marker expands to, plus the
// header/field stores the lowering emits after it.
void* uncheckedBumpInt(NurserySpace& nursery, i64 value) {
    void* obj = NTA::bumpPtr(nursery);
    NTA::bumpBy(nursery, kCell);
    initHeaderForTag(getHeader(obj), Tag_Int, kCell);
    static_cast<ElmInt*>(obj)->value = value;
    return obj;
}

// The bump pointer must always sit inside the block current_from_idx_ names
// — the coherence property failSoftUnclampCurrentBlock exists to restore.
void assertBumpCoherent(NurserySpace& nursery) {
    const size_t idx = NTA::currentFromIdx(nursery);
    char* block = NTA::fromBlockAt(nursery, idx);
    EH_ASSERT(block != nullptr);
    EH_ASSERT(NTA::bumpPtr(nursery) >= block);
    EH_ASSERT(NTA::bumpPtr(nursery) <= block + NTA::blockSize(nursery));
    EH_ASSERT(NTA::bumpEnd(nursery) >= block);
    EH_ASSERT(NTA::bumpEnd(nursery) <= block + NTA::blockSize(nursery));
}

#if ENABLE_GC_STATS
// NurserySpace and ThreadLocalHeap keep SEPARATE GCStats objects (the printed
// banner combines all three per-heap objects). minor_gc_count and
// nursery_block_advances are recorded by the nursery; ensure_slow_calls by
// the heap, at ensureNursery's entry.
uint64_t minors(NurserySpace& nursery) { return nursery.getStats().minor_gc_count; }
uint64_t advances(NurserySpace& nursery) {
    return nursery.getStats().nursery_block_advances;
}
uint64_t ensureCalls(ThreadLocalHeap* heap) {
    return heap->getStats().ensure_slow_calls;
}
#endif

} // namespace

// ============================================================================
// (a) The post-condition holds across block advances and across minor GCs
// ============================================================================

Testing::TestCase testEnsureHeadroomPostconditionAcrossAdvanceAndGC(
    "HEAP_041: ensure(n) guarantees n bytes across block advances and GCs",
    []() {
        auto& alloc = initAllocator(pressureHeapConfig());
        auto* heap = AllocatorTestAccess::getThreadHeap(alloc);
        EH_ASSERT(heap != nullptr);
        NurserySpace& nursery = heap->getNursery();

        // A 4-cell run — the shape M2 folds: one ensure, then four unchecked
        // bumps that consume exactly the guaranteed budget.
        constexpr size_t kUnits = 4;
        constexpr size_t kRun = kUnits * kCell;
        // 128 KiB of from-space at 64 B per run = 2048 runs per fill; this
        // drives many block advances and dozens of minor GCs.
        constexpr size_t kRuns = 40000;

#if ENABLE_GC_STATS
        const uint64_t minors0 = minors(nursery);
        const uint64_t advances0 = advances(nursery);
        const uint64_t ensures0 = ensureCalls(heap);
#endif

        for (size_t i = 0; i < kRuns; ++i) {
            heap->ensureNursery(kRun);

            // THE post-condition. Everything else in this plan rides on it.
            EH_ASSERT(NTA::headroom(nursery) >= kRun);
            assertBumpCoherent(nursery);

            for (size_t j = 0; j < kUnits; ++j) {
                void* obj = uncheckedBumpInt(nursery, static_cast<i64>(i * kUnits + j));
                EH_ASSERT(obj != nullptr);
                EH_ASSERT(NurserySpaceTestAccess::contains(nursery, obj));
            }
            // The run consumed exactly its budget: never past the clamped end.
            EH_ASSERT(NTA::bumpPtr(nursery) <= NTA::bumpEnd(nursery));

            // Every so often force a GC mid-stream and re-assert immediately
            // afterwards: the post-GC bump resumes mid-block after survivors,
            // so this is the arm that needs the loop in ensureHeadroom.
            if (i % 997 == 996) {
                alloc.minorGC();
                heap->ensureNursery(kRun);
                EH_ASSERT(NTA::headroom(nursery) >= kRun);
                assertBumpCoherent(nursery);
            }
        }

#if ENABLE_GC_STATS
        // Non-vacuity: this workload must actually have crossed both a block
        // boundary and a GC, or the test proved nothing.
        EH_ASSERT(advances(nursery) > advances0);
        EH_ASSERT(minors(nursery) > minors0);
        EH_ASSERT(ensureCalls(heap) - ensures0 >= kRuns);
#endif
    });

// ============================================================================
// (b) A miss at a threshold-CLAMPED block goes to GC, never to a block advance
// ============================================================================
//
// This is the §2.4 disambiguator. Advancing past a mid-block proactive-GC trip
// would land every subsequent block in computeAllocEndForBlock's already-full
// fail-soft clause (full block ends), silently disabling the proactive trigger
// for the rest of the nursery cycle — megabytes of drift, not "<= n bytes".

Testing::TestCase testEnsureAtClampedBlockGCsInsteadOfAdvancing(
    "HEAP_041: an ensure miss at a threshold-clamped block triggers GC, not an advance",
    []() {
        auto& alloc = initAllocator(pressureHeapConfig());
        auto* heap = AllocatorTestAccess::getThreadHeap(alloc);
        EH_ASSERT(heap != nullptr);
        NurserySpace& nursery = heap->getNursery();

        // Start from a known-clean bump state.
        alloc.minorGC();

        // Put some real objects in the block first, so the pre-evacuation
        // walk has something to parse and bump_.ptr is genuinely mid-block.
        heap->ensureNursery(16 * kCell);
        for (size_t j = 0; j < 16; ++j) {
            uncheckedBumpInt(nursery, static_cast<i64>(j));
        }

        char* block = NTA::fromBlockAt(nursery, NTA::currentFromIdx(nursery));
        EH_ASSERT(block != nullptr);
        // Precondition: we are genuinely mid-block, not at its end.
        EH_ASSERT(NTA::bumpPtr(nursery) < block + NTA::blockSize(nursery));

        // Simulate the proactive-GC threshold tripping INSIDE this block.
        NTA::clampCurrentBlockEnd(nursery, 8);
        EH_ASSERT(NTA::bumpEnd(nursery) < block + NTA::blockSize(nursery));

#if ENABLE_GC_STATS
        const uint64_t minors0 = minors(nursery);
        const uint64_t advances0 = advances(nursery);
#endif

        heap->ensureNursery(64);

        EH_ASSERT(NTA::headroom(nursery) >= 64);
        assertBumpCoherent(nursery);

#if ENABLE_GC_STATS
        // Exactly one minor GC, and NO block advance: the clamp was read as a
        // threshold trip, not as exhaustion.
        EH_ASSERT(minors(nursery) == minors0 + 1);
        EH_ASSERT(advances(nursery) == advances0);
#endif
    });

// ============================================================================
// (c) The tiny-config fail-soft corner terminates and restores coherence
// ============================================================================
//
// threshold_total_bytes_ < n makes even a FRESH block's clamped end too small,
// so advance-then-GC can never satisfy the request and the ladder would loop.
// The fail-soft arm unclamps the current block only — after rewinding
// current_from_idx_ to the block actually holding bump_.ptr.

Testing::TestCase testEnsureFailSoftTinyConfigTerminates(
    "HEAP_041: ensure fail-soft unclamp terminates and restores index coherence",
    []() {
        auto& alloc = initAllocator(tinyThresholdConfig());
        auto* heap = AllocatorTestAccess::getThreadHeap(alloc);
        EH_ASSERT(heap != nullptr);
        NurserySpace& nursery = heap->getNursery();

        // Precondition for this corner: a fresh block's CLAMPED headroom is
        // below the maximum budget. If this ever stops holding the test is
        // no longer exercising the fail-soft arm.
        EH_ASSERT(NTA::headroom(nursery) < 4096);

        heap->ensureNursery(4096);

        EH_ASSERT(NTA::headroom(nursery) >= 4096);
        assertBumpCoherent(nursery);

        // The guarantee is real: consume all of it with unchecked bumps.
        for (size_t j = 0; j < 4096 / kCell; ++j) {
            uncheckedBumpInt(nursery, static_cast<i64>(j));
        }
        EH_ASSERT(NTA::bumpPtr(nursery) <= NTA::bumpEnd(nursery));

        // And the allocator is still usable afterwards: ordinary allocation
        // and a minor GC both work off the restored state.
        for (size_t j = 0; j < 512; ++j) {
            void* obj = alloc.allocate(sizeof(ElmInt), Tag_Int);
            EH_ASSERT(obj != nullptr);
            static_cast<ElmInt*>(obj)->value = static_cast<i64>(j);
        }
        alloc.minorGC();
        assertBumpCoherent(nursery);

        // Repeating the corner must still terminate (no accumulated damage).
        for (size_t round = 0; round < 8; ++round) {
            heap->ensureNursery(4096);
            EH_ASSERT(NTA::headroom(nursery) >= 4096);
            assertBumpCoherent(nursery);
            for (size_t j = 0; j < 4096 / kCell; ++j) {
                uncheckedBumpInt(nursery, static_cast<i64>(j));
            }
        }
    });

// ============================================================================
// (d) Abandoned tails don't trip the validate walker
// ============================================================================
//
// ensureHeadroom's advance arm abandons the current block's tail. The
// ECO_HEAP_VALIDATE pre-evacuation walk parses the CURRENT block only
// ([block_start, bump_.ptr)), so tails in completed blocks are tolerated —
// this test is the one that would catch it if that ever changed. Under a
// non-validate build it degrades to a plain retention roundtrip.

Testing::TestCase testEnsureAbandonedTailsSurviveValidateWalk(
    "HEAP_041: tails abandoned by ensure advances don't trip the validate walk",
    []() {
        auto& alloc = initAllocator(pressureHeapConfig());
        auto* heap = AllocatorTestAccess::getThreadHeap(alloc);
        EH_ASSERT(heap != nullptr);
        NurserySpace& nursery = heap->getNursery();

        // 512 B is the default ECO_ALLOC_HOIST_MAX_BYTES — the largest run a
        // covered region can request, so the largest tail an advance abandons.
        constexpr size_t kRun = 512;
        constexpr size_t kUnits = kRun / kCell;
        constexpr size_t kRuns = 6000;
        constexpr size_t kRootEvery = 64;

        std::vector<HPointer> roots;
        roots.reserve(kRuns * kUnits / kRootEvery + 16);

        size_t counter = 0;
        for (size_t i = 0; i < kRuns; ++i) {
            heap->ensureNursery(kRun);
            EH_ASSERT(NTA::headroom(nursery) >= kRun);

            for (size_t j = 0; j < kUnits; ++j) {
                void* obj = uncheckedBumpInt(nursery, static_cast<i64>(counter));
                if (counter % kRootEvery == 0) {
                    roots.push_back(AllocatorTestAccess::toPointer(obj));
                    alloc.getRootSet().addRoot(&roots.back());
                }
                ++counter;
            }

            // Drive the walk often: every explicit minorGC re-parses the
            // current block and re-evacuates the rooted survivors.
            if (i % 64 == 63) {
                alloc.minorGC();
            }
        }

        alloc.minorGC();

        // Every rooted Int must have survived with its value intact.
        for (size_t k = 0; k < roots.size(); ++k) {
            void* obj = readBarrier(roots[k]);
            EH_ASSERT(obj != nullptr);
            EH_ASSERT(getHeader(obj)->tag == Tag_Int);
            EH_ASSERT(static_cast<ElmInt*>(obj)->value ==
                      static_cast<i64>(k * kRootEvery));
        }

        for (auto& root : roots) {
            alloc.getRootSet().removeRoot(&root);
        }
    });
