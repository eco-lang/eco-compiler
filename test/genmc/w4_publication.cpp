// W4: publishing a new old-gen block to background markers
// (plans/threaded-gc-tla-W-weak-memory.md §8). A pinned REDUCTION: OldGenSpace
// cannot be instantiated in a litmus test, so this file copies the exact
// accesses and orders of the functions below, IN THE CODE'S ORDER, over small
// static arrays. The canary pins the originals (§11).
//
//   the mutator (or a promotion worker under promo_mu_), allocateLargeBlock
//   (OldGenSpace.cpp:2765-2775) / ensureBagPageAvailable (:874-878):
//     1. setRegionEnd (relaxed atomic_ref store, OldGenSpace.hpp:413);
//     2. resizePageIndexForRegion -> commitPageIndexThrough (:540-546) ->
//        ReservedArray::ensureCommitted (ReservedArray.hpp:110-136):
//        committed_.store(release) after the commit, or a no-op;
//     3. materializeBlock (:657-664): blocks_.add writes BlockInfo (plain),
//     4. mark_.assign zeroes the slot and writes len_ (plain, memset),
//     6. assignPageIndexForBlock (:586-627) -> storeOwner (release,
//        OldGenSpace.hpp:446-448): the only edge that publishes 3-4.
//     (5, live.commitThrough, is omitted: markers read committed_ there only
//     in an assert, which the NDEBUG build does not have.)
//   a background marker, blockIdFor (:1797-1816): region bounds relaxed,
//     committed() acquire (ReservedArray.hpp:174), loadOwner acquire
//     (OldGenSpace.hpp:449-451), then plain reads of BlockInfo (and mark_.len).
//
// (*) A byte loop, not memset: GenMC 0.19 aborts promoting a memset whose
// destination is a constant expression (PromoteMemIntrinsicPass lowers those
// for memcpy only). Both are the same plain bulk write for happens-before and
// races, and no other thread reads the slot.
//
// Variants: -DW4_COMMITTED0=2 (w4_commit: this block's growth commits the page
// index slots). Driver mutants: MUTANT_W4_RELAXED_OWNER, MUTANT_W4_REGION_SHRINK,
// MUTANT_W4_RECOMPUTE_PLAIN.
#include <atomic>
#include "wdriver.hpp"

#ifndef W4_COMMITTED0
#define W4_COMMITTED0 4   // page-index slots already committed (the usual case: 64 KiB chunks)
#endif

struct BlockInfo { char* start; char* end; };
static char heap[4 * 64];                    // 4 "pages" of 64 bytes
static BlockInfo info[2];                    // BlockTable::info_ (plain)
static uint32_t mark_len[2];                 // MarkBitArena::len_ (plain)
static uint8_t mark_slot[2][8];              // MarkBitArena slots (plain)
struct PageOwners { uint32_t primary, secondary; };
static PageOwners page_index[4];             // page_index_ (owner words through atomic_ref)
static std::atomic<size_t> committed{W4_COMMITTED0};   // page_index_.committed_
static char* region_base;
static char* region_end;

static void storeOwner(uint32_t& w, uint32_t v) {            // OldGenSpace.hpp:446-448
#ifdef MUTANT_W4_RELAXED_OWNER
    std::atomic_ref<uint32_t>(w).store(v, std::memory_order_relaxed);
#else
    std::atomic_ref<uint32_t>(w).store(v, std::memory_order_release);
#endif
}
static uint32_t loadOwner(const uint32_t& w) {               // OldGenSpace.hpp:449-451
    return std::atomic_ref<uint32_t>(const_cast<uint32_t&>(w)).load(std::memory_order_acquire);
}
static char* regionBase() {                                  // OldGenSpace.hpp:407-409
    return std::atomic_ref<char*>(region_base).load(std::memory_order_relaxed);
}
static char* regionEnd() {                                   // OldGenSpace.hpp:410-412
    return std::atomic_ref<char*>(region_end).load(std::memory_order_relaxed);
}

static int blockIdFor(const char* p) {       // OldGenSpace.cpp:1797-1816; returns id or -1
    if (p < regionBase() || p >= regionEnd()) return -1;
    const size_t page = static_cast<size_t>(p - heap) / 64;
    if (page < committed.load(std::memory_order_acquire)) {
        const uint32_t a = loadOwner(page_index[page].primary);
        if (a != 0 && p >= info[a - 1].start && p < info[a - 1].end) return static_cast<int>(a - 1);
        const uint32_t b = loadOwner(page_index[page].secondary);
        if (b != 0 && p >= info[b - 1].start && p < info[b - 1].end) return static_cast<int>(b - 1);
    }
    return -1;
}

// The mutator adds block 1 = pages [2, 4) while a marker runs, in the code's
// order: the region grows and the page index is committed BEFORE
// materializeBlock, so the owner store is the only edge publishing BlockInfo.
static void* mutator(void*) {
#if defined(MUTANT_W4_REGION_SHRINK)
    std::atomic_ref<char*>(region_end).store(heap + 64, std::memory_order_relaxed);   // IM5 violated
#elif defined(MUTANT_W4_RECOMPUTE_PLAIN)
    region_end = heap + 256;                 // recomputeRegionBounds :561 (CR-009) inside a cycle
#else
    std::atomic_ref<char*>(region_end).store(heap + 256, std::memory_order_relaxed);   // setRegionEnd
#endif
    if (committed.load(std::memory_order_relaxed) < 4)                    // ensureCommitted :111
        committed.store(4, std::memory_order_release);                    //                 :135
    info[1].start = heap + 128;                                           // blocks_.add (word-wise, §7.6)
    info[1].end = heap + 256;
    for (int i = 0; i < 8; ++i) mark_slot[1][i] = 0;                      // mark_.assign's memset (*)
    mark_len[1] = 8;
    storeOwner(page_index[2].primary, 2);                                 // assignPageIndexForBlock
    storeOwner(page_index[3].primary, 2);
    return nullptr;
}

// A background marker: looks up a t0 object (block 0, page 1), and probes block 1.
static void* marker(void*) {
    assert(blockIdFor(heap + 72) == 0);                        // t0 lookups never fail
    const int id = blockIdFor(heap + 130);
    if (id >= 0) {
        assert(id == 1);
        const uint32_t len = mark_len[id];                     // new block: full metadata seen
        assert(len == 8);
    }
    return nullptr;
}

int main() {
    // Everything before the launch (GCBackgroundGang::launch's mutex, or here
    // thread creation) happens-before both threads.
    info[0].start = heap;
    info[0].end = heap + 128;                                  // t0 block 0 = pages [0, 2)
    mark_len[0] = 8;
    page_index[0].primary = 1;
    page_index[1].primary = 1;
    region_base = heap;
    region_end = heap + 128;
    wthread m = spawn(mutator), k = spawn(marker);
    join(m);
    join(k);
    return 0;
}
