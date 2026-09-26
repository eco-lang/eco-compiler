#ifndef ECO_OLDGENSPACE_H
#define ECO_OLDGENSPACE_H

#include <limits>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>
#include "AllocatorCommon.hpp"
#include "RootSet.hpp"
#include "GCStats.hpp"
#include "BlockTable.hpp"

namespace Elm {

// ============================================================================
// GC Phase State Machine
// ============================================================================

enum class GCPhase {
    Idle,       // No collection in progress.
    Marking,    // Incremental marking in progress.
    Sweeping    // Lazy sweeping in progress.
};

// Per-major-GC phase telemetry. Filled in by majorGC()/finishMarkAndSweep
// when ECO_GC_PHASE_PROFILE is set. Costs nothing when disabled.
struct MajorGCPhaseProfile {
    uint64_t mark_ns        = 0;
    uint64_t sweep_ns       = 0;
    uint64_t capacity_ns    = 0;
    uint64_t mark_iterations = 0;  // Calls to incrementalMark(1000) in the loop.
    uint64_t mark_units_done = 0;  // Total objects popped from mark stack.
    size_t   mark_stack_peak = 0;  // Peak mark-stack depth observed.
    size_t   blocks_scanned  = 0;  // Buffer count walked in sweep.
    size_t   live_bytes_after = 0;
    size_t   garbage_bytes    = 0;
    size_t   shrink_blocks_released = 0;
    size_t   shrink_bytes_released  = 0;
    // All-dead block fast path (Step 3): blocks released in O(#blocks) without
    // scanning their cells.
    size_t   alldead_blocks_released = 0;
    size_t   alldead_bytes_released  = 0;
    // Uniform→mixed demotion: blocks whose live_bytes <= demote_live_fraction
    // (default 50%) of total at the
    // mark/sweep boundary, retagged so their freed space lands in the
    // splittable mixed-only free-list classes.
    size_t   demoted_blocks          = 0;
    size_t   demoted_bytes           = 0;
    // Lazy sweep (Step 4): how much sweep work is being deferred to the mutator
    // after finishMarkAndSweep returns.
    size_t   initial_sweep_budget_bytes = 0;
    size_t   sweep_pending_blocks = 0;
};

// ============================================================================
// Free-List Constants (Segregated-Fits + Big Bag of Pages)
// ============================================================================
//
// The old gen is a segregated-fits allocator backed by a "Big Bag of Pages":
//
//   - At init, the configured initial_old_gen_size is committed as one
//     contiguous region and sliced into pages of `alloc_buffer_size` bytes.
//     Each page extent lives in `unassigned_blocks_` until it is first used.
//
//   - Allocation requests of size < `large_object_threshold` are routed to a
//     fixed-cell size class: small classes (8..256, step 8) and medium
//     classes (powers of two: 512, 1024, 2048, ...). On first use, a class
//     pulls a page from the bag and slices it into uniform Tag_Free cells.
//
//   - Allocation requests in [large_object_threshold, alloc_buffer_size) pull
//     a page from the bag, install a single Tag_Free cell spanning the page,
//     and split it via the larger-cell path (no fixed-cell slicing).
//
//   - Allocation requests >= `alloc_buffer_size` go to allocateLargeBlock,
//     which acquires a dedicated pinned block sized to fit the object.
//
//   - Sweep coalesces adjacent garbage into a single Tag_Free cell and pushes
//     it onto the free list of the appropriate size class. Splitting is the
//     only mechanism that re-divides large free cells into smaller ones.
//
//   - Below `small_class_heap_budget_bytes`, small-class allocations prefer
//     pulling a fresh uniform bag page over splitting larger free cells. This
//     trades early committed capacity for less fragmentation of medium/large
//     free spans into tiny cells. See `shouldPreferBagForSmallClass` and
//     `HeapConfig::small_class_heap_budget_bytes`.

// Free-list size-class layout constants (NUM_SMALL_CLASSES, MAX_SMALL_SIZE,
// MEDIUM_CLASS_BASE, NUM_MEDIUM_CLASSES_MAX, NUM_SIZE_CLASSES) and the
// sweep / mark pacing knobs (SWEEP_WORK_BUDGET, INITIAL_SWEEP_BUDGET,
// MARK_WORK_RATIO, SWEEP_BYTES_PER_ALLOC_BYTE, MAX_SWEEP_BYTES_PER_ALLOC,
// MAX_SWEEP_BYTES_HARD, SWEEP_CAP_RATIO_*, SWEEP_SCALE_*,
// SWEEP_UNSWEPT_RATIO_BOOST, SWEEP_UNSWEPT_SCALE, PANIC_SWEEP_SLICE_BYTES)
// now live in AllocatorCommon.hpp. The pacing knobs are mirrored as fields
// on HeapConfig and are read at runtime via `config_->...`. The size-class
// constants stay compile-time because they size static arrays.

// ============================================================================
// Free Cell Structure (tiered: 16-B Tier-S for class 1, 24-B Tier-M for ≥ 2)
// ============================================================================
//
// A free cell overlays a span of unallocated bytes and chains into a
// per-class free list. The header carries Tag_Free and the cell's full byte
// size, so any sweep walk can skip over it just like any other heap object.
//
// Two flavours share the same starting layout (Header + next_in_class). The
// size class determines which view applies:
//   * Tier-S (cls == 1, cellSize == 16 B): no per-block thread, no class
//     back-link. Bulk release walks free_lists_[1] end-to-end (bounded —
//     class 1 is the smallest list).
//   * Tier-M (cls ≥ 2, cellSize ≥ 24 B): cell additionally carries a
//     back-link to its predecessor in the size-class list and 16-bit
//     per-block offsets, so removeFreeCellsForBlock can walk only this
//     block's cells and unlink each in O(1) from both threads.
//
// The class-list back-link (threaded-gc-01, HEAP_052) is the predecessor's
// ADDRESS >> 3 in 40 bits: the low 32 bits in `prev_lo`, the high 8 bits in
// bits [0,8) of the cell's own Header.refcount (unused on Tag_Free cells),
// with refcount bit 8 marking "head of its class list". Only setPrevHead /
// setPrev / copyPrev (OldGenSpace.cpp) write these bits. The encoding needs
// no block metadata and imposes no bound on the block count.
//
// `next_in_block` / `prev_in_block` are 16-bit offsets, encoded as
// (cell_addr - block.start) / 8. FREE_CELLS_EMPTY == 0xFFFF marks the
// chain end. cell offset/8 in [0, 0xFFFF] bounds the block byte size to
// 524,288 (= 512 KiB); enforced at OldGenSpace::initialize.
struct FreeCell;

// FREE_CELLS_EMPTY lives in BlockTable.hpp (with BlockInfo).


// Tier-S (16 B): minimal layout for class 1. Tier-M is laid out so its
// header + next_in_class share offsets with the Tier-S view.
struct FreeCell {
    Header     header;          // 8 B  Tag_Free; header.size = byte size of this cell.
    FreeCell*  next_in_class;   // 8 B  Free-list link, stored in the cell's data area.
};
static_assert(sizeof(FreeCell) == 16, "Tier-S FreeCell must be 16 bytes");

// Tier-M (24 B): used for cells of size ≥ MIN_TIER_M_SIZE. The first two
// fields overlay Tier-S so a `FreeCell*` view can read header / next_in_class
// without a downcast.
struct FreeCellMid {
    Header     header;          // 8 B
    FreeCell*  next_in_class;   // 8 B
    uint32_t   prev_lo;         // 4 B   back-link, low 32 bits (HEAP_052)
    uint16_t   next_in_block;   // 2 B   offset/8 within block; FREE_CELLS_EMPTY = end
    uint16_t   prev_in_block;   // 2 B   offset/8 within block; FREE_CELLS_EMPTY = head
};
static_assert(sizeof(FreeCellMid) == 24, "Tier-M FreeCellMid must be 24 bytes");
static_assert(offsetof(FreeCell,    next_in_class) ==
              offsetof(FreeCellMid, next_in_class),
              "FreeCell and FreeCellMid must share next_in_class offset");

// Free-list back-link encoding (threaded-gc-01 P§3.7, HEAP_052). A Tier-M
// cell's predecessor in its size-class list is stored as its address >> 3
// (40 bits; heap addresses are < 2^43): the low 32 bits in
// FreeCellMid::prev_lo, the high 8 in bits [0,8) of THIS cell's
// Header.refcount. refcount bit 8 marks "no predecessor: head of the list".
// refcount is unused on Tag_Free cells (Heap.hpp), and ONLY these three
// helpers touch it there. Resolving a back-link reads no block metadata, and
// Tier-M threading no longer depends on the block count (the former 16-bit
// CellHandle capped it at 65,535 blocks).
inline constexpr u32 kPrevHiMask  = 0xFFu;
inline constexpr u32 kPrevHeadBit = 0x100u;
static_assert(POINTER_BITS == 40,
              "back-link encoding assumes heap addresses < 2^43");

inline void setPrevHead(FreeCellMid* m) {
    m->header.refcount = kPrevHeadBit;
    m->prev_lo = 0;
}
inline void setPrev(FreeCellMid* m, const FreeCell* pred) {
    const uint64_t e = reinterpret_cast<uintptr_t>(pred) >> 3;
    m->prev_lo = static_cast<uint32_t>(e);
    m->header.refcount = static_cast<u32>(e >> 32) & kPrevHiMask;
}
inline void copyPrev(FreeCellMid* dst, const FreeCellMid* src) {
    dst->prev_lo = src->prev_lo;
    dst->header.refcount = src->header.refcount & (kPrevHiMask | kPrevHeadBit);
}
inline FreeCell* getPrev(const FreeCellMid* m) {
    if (m->header.refcount & kPrevHeadBit) return nullptr;
    const uint64_t e =
        (uint64_t(m->header.refcount & kPrevHiMask) << 32) | m->prev_lo;
    return reinterpret_cast<FreeCell*>(static_cast<uintptr_t>(e << 3));
}

// Smallest free cell that can be linked into a free list (Tier-S, class 1).
static constexpr size_t MIN_FREE_CELL_SIZE = sizeof(FreeCell);
// Smallest free cell that gets the per-block thread treatment (Tier-M).
static constexpr size_t MIN_TIER_M_SIZE    = sizeof(FreeCellMid);

// ============================================================================
// Free-Cell Sentinel Helpers (Header.age repurposed for Tag_Free)
// ============================================================================
//
// For Tag_Free cells in old gen, `Header.age` is repurposed:
//   age & 0b01 == 1  → "already on a free list" sentinel. Lazy sweep must
//                      treat this as a hard run boundary; do NOT merge,
//                      rewrite, or follow the free-list link.
//   age & 0b01 == 0  → ordinary coalescable Tag_Free cell.
//   age & 0b10       → reserved for future use; must remain 0.
inline bool isFreeCellSentinel(const Header* hdr) {
    return (hdr->tag == Tag_Free) && ((hdr->age & 0b01u) != 0);
}
inline void setFreeCellSentinel(Header* hdr) {
    hdr->age = (hdr->age & ~0b11u) | 0b01u;
}
inline void clearFreeCellSentinel(Header* hdr) {
    hdr->age = (hdr->age & ~0b11u);
}

// BlockInfo, BufferMetadata, BlockId, BlockTable and MarkBitArena live in
// BlockTable.hpp (threaded-gc-01, HEAP_048/HEAP_050).

// ============================================================================
// Fragmentation Statistics
// ============================================================================

// Heap-wide fragmentation metrics (computed after each sweep completes).
struct FragmentationStats {
    size_t total_free_bytes;    // Total bytes in free lists (reclaimed garbage).
    size_t live_bytes;          // Total bytes in live objects.
    size_t heap_bytes;          // Total committed heap bytes (all blocks).

    // Returns heap utilization as a fraction in range [0.0, 1.0].
    // Low utilization indicates fragmentation or excess garbage.
    float utilization() const {
        return heap_bytes > 0 ? static_cast<float>(live_bytes) / heap_bytes : 0.0f;
    }
};

// Utilization threshold below which compaction is triggered.
static constexpr float UTILIZATION_THRESHOLD = 0.70f;

// Target utilization after returning surplus buffers to the OS.
static constexpr float BUFFER_RETURN_THRESHOLD = 0.50f;

// Maximum bytes of live data to evacuate per incremental compaction slice.
static constexpr size_t COMPACTION_WORK_BUDGET = 8192;

// ============================================================================
// Compaction State Machine
// ============================================================================

enum class CompactionPhase {
    Idle,           // No compaction in progress.
    Evacuating,     // Moving live objects out of source buffers.
    FixingRefs      // Updating pointers to forwarding addresses.
};

// Forward declarations.
class Allocator;
class NurserySpace;
class OldGenSpaceTestAccess;
namespace p1 { struct P1CensusAccess; }

// Follows a forwarding pointer if present, updating the HPointer in place.
// Primarily for test code; production uses Allocator::resolve() instead.
void* readBarrier(HPointer& ptr);

/**
 * Old generation with mark-and-sweep collection.
 *
 * Segregated-fits allocator backed by a "Big Bag of Pages": the initial
 * old-gen region is precommitted and sliced into pages, each pulled from the
 * bag on demand. See the file-level comment block above for the full design.
 *
 * Thread-local (one instance per thread). Block metadata storage is
 * VA-reserved and never moves; blocks have stable BlockIds (HEAP_048).
 */
class OldGenSpace {
public:
    OldGenSpace();
    ~OldGenSpace();

    // ========== Allocation ==========

    // Allocates memory using the segregated-fits + BBoP scheme described
    // above. Acquires additional capacity from the Allocator only if the bag
    // of pages is empty AND no free cell of sufficient size is available.
    void *allocate(size_t size);

    // ========== Split-Header Body API (HEAP_026) ==========

    // Allocates a body cell of `total_size` bytes in old gen and writes a
    // header with `body_tag` (Tag_String / Tag_ByteBuffer), `pin = 1`. The
    // body's `header.size` is set to `logical_size`, which must match the
    // owning Tag_LargeStringHeader / Tag_LargeByteHeader's `header.size` (the
    // logical UTF-16 char count for strings, byte count for buffers). It is
    // NOT derived from `total_size` because the caller's 8-byte alignment
    // padding would inflate the count and expose uninitialised slack bytes
    // as content (see Heap.hpp:261-263 for the design contract). Body bytes
    // (the chars[] / bytes[] payload) are NOT touched here; the caller copies
    // them in. Registers the body in `nursery_owned_bodies_` with the supplied
    // initial color.
    void* allocateLargeBody(size_t total_size, size_t logical_size,
                            Tag body_tag, bool initial_color);

    // Records `body_hp` as still-live for `minor_color`. O(1) lookup; no-op if
    // the body isn't currently nursery-owned (e.g. promoted, or untracked).
    void markLargeBodySeen(HPointer body_hp, bool minor_color);

    // Removes `body_hp` from `nursery_owned_bodies_` because the owning
    // header has been promoted to old gen. Idempotent.
    void promoteLargeHeader(HPointer body_hp);

    // Walks `nursery_owned_bodies_` and frees every body whose recorded
    // color != current `minor_color`. Compacts the vector in place. Returns
    // the number freed. Skipped while a major GC or compaction is mid-cycle
    // (deferred to the next minor GC after they complete).
    size_t sweepNurseryLargeBodies(bool minor_color);

    // ========== Queries ==========

    // threaded-gc-01 metadata geometry (P§3.3) for an old-gen reservation of
    // `reservation_bytes` and pages of `page` bytes. Every block is >= one
    // page and lies inside the reservation, so max_blocks bounds the live
    // block count and no table can overflow. A pure function so the scale
    // test can check the arithmetic at 8 TB.
    struct OldGenGeometry {
        size_t max_blocks = 0;        // BlockTable / accumulator capacity (ids)
        size_t index_slots = 0;       // page-index slots
        size_t stride = 0;            // mark-arena bytes per id
        size_t mark_arena_bytes = 0;  // max_blocks * stride (VA)
    };
    static OldGenGeometry geometryFor(size_t reservation_bytes, size_t page);

    // Binds the owning heap's nursery (HEAP_053). Called once by the
    // ThreadLocalHeap constructor.
    void bindNursery(const NurserySpace* n) { nursery_ = n; }

    // Set by NurserySpace::minorGC around its collection bracket.
    void setInMinorGC(bool v) { in_minor_gc_ = v; }

    // Returns the current number of bytes allocated in this old gen space.
    size_t getAllocatedBytes() const { return allocated_bytes; }

    // Returns committed capacity of this thread-local old gen (bytes).
    size_t getCommittedBytes() const {
        return (region_end_ > region_base_)
                   ? static_cast<size_t>(region_end_ - region_base_)
                   : 0;
    }

    // Reason `evaluateMajorGCTrigger` fired (or `None` if no trigger is live).
    // The order of evaluation in shouldTriggerMajorGC mirrors the priority
    // here: Occupancy > GlobalPressure > GarbageFraction.
    enum class MajorGCTriggerReason {
        None,
        Occupancy,        // per-thread allocated/committed >= initiating
        GlobalPressure,   // global old-gen committed/cap >= initiating/3
        GarbageFraction,  // (allocated - post-sweep-live) / committed >=
                          // major_gc_garbage_fraction
        LiveBudget,       // allocated since major >= major_gc_live_budget *
                          // min(L_i, live_growth_bound * L_{i-1})
    };

    // Returns which trigger condition (if any) is live. Thread-local: each
    // thread's old gen triggers its own major GC.
    MajorGCTriggerReason evaluateMajorGCTrigger() const;

    // True when any trigger condition is live.
    bool shouldTriggerMajorGC() const {
        return evaluateMajorGCTrigger() != MajorGCTriggerReason::None;
    }

    // Returns true if the pointer is within this old gen's committed region.
    // O(1) check using cached bounds. Inlined for performance.
    inline bool contains(void* ptr) const {
        char* p = static_cast<char*>(ptr);
        return p >= region_base_ && p < region_end_;
    }

    // threaded-gc-00: promotion-path instruments (promotions only, i.e.
    // allocate() while in_minor_gc_). Deterministic 1-in-16 sampling of the
    // in-pause lazy-sweep slice and 1-in-256 of the allocator dispatch. The
    // nursery takes start/end differences per minor GC.
    struct PromoInstr {
        SampledTimer<4> sweep;
        uint64_t        sweep_bytes = 0;
        SampledTimer<8> alloc;
    };
    const PromoInstr& promoInstr() const { return promo_instr_; }

#if ENABLE_GC_STATS
    // Returns the per-allocation stats accumulated by this old gen. Only the
    // allocation-size histogram is populated here; major-GC counters are
    // recorded against the ThreadLocalHeap's stats via passed references.
    GCStats& getStats() { return alloc_stats_; }
    const GCStats& getStats() const { return alloc_stats_; }
#endif

    // Up to two owning blocks per page slot (HEAP_049). Two are required
    // because non-page-aligned block extents (e.g. a large block whose start
    // is not alloc_buffer_size-aligned) can intersect the same slot as a
    // sibling block; every block is >= alloc_buffer_size, so a slot can
    // intersect at most two. Owners are stored ENCODED as BlockId.v + 1, so a
    // fresh zero-filled slot means "no owner" (decodeOwner(0) == NO_BLOCK_ID).
    struct PageOwners {
        uint32_t primary;
        uint32_t secondary;
    };
    static constexpr uint32_t encodeOwner(BlockId id) { return id.v + 1; }
    static constexpr BlockId decodeOwner(uint32_t o) { return BlockId{o - 1}; }

private:
    // ========== Configuration ==========

    const HeapConfig* config_;    // Heap configuration parameters.
    Allocator* allocator_;        // Back-reference for acquiring buffers.

    // Runtime number of size classes; depends on `large_object_threshold`.
    // Always satisfies NUM_SMALL_CLASSES <= num_size_classes_ <= NUM_SIZE_CLASSES.
    size_t num_size_classes_;

    // ========== Block Management ==========

    // Blocks currently in use: stable BlockId identity + iteration order that
    // reproduces the former std::vector<BlockInfo> exactly (HEAP_048).
    BlockTable blocks_;
    size_t allocated_bytes;                // Total bytes currently allocated.

    // Snapshot of `allocated_bytes` taken right after each major GC's sweep
    // completes (computeFragmentationStats sets it to live_bytes there). The
    // garbage-fraction trigger uses this as the baseline against which to
    // measure post-major mutator allocation, so the threshold expresses
    // "allocated since last major" rather than "currently held".
    size_t post_sweep_live_bytes_ = 0;
    // Mark-derived live at the end of the last two majors (LiveBudget trigger).
    size_t major_live_ = 0;
    size_t prev_major_live_ = 0;

    // threaded-gc-02 (bitmap mode): committed bytes at the end of the last
    // major GC. The garbage-fraction trigger divides by
    // min(committed, 2 * this) instead of the current committed size: while
    // garbage cannot be reused before the next major, every allocated byte
    // grows committed, so a current-committed denominator chases its
    // numerator (measured: a 12.7 GB major after 682 minors, RSS 14.4 GB).
    size_t committed_at_major_ = 0;

#if ENABLE_GC_STATS
    // Records the allocation-size histogram for this old gen. Combined with
    // ThreadLocalHeap's GCStats by Allocator::getCombinedStats().
    GCStats alloc_stats_;
#endif
    PromoInstr promo_instr_;   // threaded-gc-00 (see promoInstr())

    // Bag of pre-committed-but-unassigned pages (start, end). Each entry is
    // a page of `alloc_buffer_size` bytes carved from the initial region or
    // a post-GC capacity grow.
    std::vector<std::pair<char*, char*>> unassigned_blocks_;

    // Cached bounds for O(1) membership checks (updated when blocks change).
    char* region_base_;                    // Start of old gen region.
    char* region_end_;                     // End of committed old gen region.

    // Page index (HEAP_049): slot (p - index_base_) / alloc_buffer_size ->
    // up to two owning blocks. index_base_ is the heap base, so the index
    // covers the WHOLE old-gen reservation [heap_base, heap_base +
    // nursery_offset); it is VA-reserved at initialize(), committed through
    // region_end_, and never rebuilt: blocks are added and removed
    // incrementally and ids never move. Lookups must bounds-check against
    // page_index_.committed() (uncommitted slots are PROT_NONE).
    ReservedArray<PageOwners> page_index_;
    char* index_base_ = nullptr;

    // alloc_buffer_size the reservations were sized for.
    size_t reserved_page_size_ = 0;

    // Reserves every metadata table (BlockTable, MarkBitArena, page index)
    // for geometryFor(allocator reservation, alloc_buffer_size). Aborts with
    // the requested sizes on failure: a silently smaller table would
    // overflow later.
    void reserveMetadata();

#if ECO_HEAP_VALIDATE
    // V7: storage base addresses recorded at reserveMetadata(); asserted
    // unchanged at every validator run (HEAP_048: storage never moves).
    const void* storage_bases_[BlockTable::kStorageArrays + 3] = {};
#endif

    // Recomputes region_base_/region_end_ from blocks_ + unassigned_blocks_.
    // Called after any path that releases address range (post-mark shrink,
    // all-dead reclaim, single-block release tail, compaction free pass).
    // threaded-gc-01: no longer rebuilds the page index (it is keyed from
    // index_base_, not region_base_).
    void recomputeRegionBounds();

    // Commits the page index through the slot covering `end - 1` (no-op when
    // already committed). Every site that grows region_end_ calls this.
    void commitPageIndexThrough(const char* end);

    // ========== Bitmap allocation (threaded-gc-02, HEAP_054) ==========
    //
    // With HeapConfig::old_gen_bitmap_alloc, a uniform block's mark bitmap is
    // its allocation map (cell-start bit set <=> allocated). Per size class
    // one AllocCursor owns at most one block (alloc_state Current) and scans
    // its bitmap for clear cell starts; partially free blocks wait on
    // partial_[cls] (FIFO from partial_head_[cls]) in the position order
    // classifyBlocksAfterMark saw them. Reset at startMark. See
    // plans/threaded-gc-02-bitmap-allocation.md P§3.
    static constexpr uint8_t kAllocNone = 0;
    static constexpr uint8_t kAllocQueued = 1;
    static constexpr uint8_t kAllocCurrent = 2;
    struct AllocCursor {
        BlockId  block = NO_BLOCK_ID;
        uint32_t next_cell = 0;     // first cell index not yet examined
        uint32_t num_cells = 0;
        uint32_t stride_bits = 0;   // cell_bytes / 8
        uint32_t cell_bytes = 0;
        uint8_t* bits = nullptr;    // mark_.slot(block) (stable, HEAP_050)
        char*    base = nullptr;    // block start
        // Hot-path accumulators, flushed into the block's BufferMetadata /
        // the stats by flushCursor (measured: updating meta.live_bytes and
        // two stats counters on every promotion made the bitmap path slower
        // than the legacy pop, 34.1 vs 31.1 ns). Every reader of a uniform
        // block's live_bytes calls syncCursorLiveBytes() first.
        uint64_t pending_live = 0;
        uint64_t pending_allocs = 0;
    };
    AllocCursor cursor_[NUM_SIZE_CLASSES];
    std::vector<BlockId> partial_[NUM_SIZE_CLASSES];
    size_t partial_head_[NUM_SIZE_CLASSES] = {};

    bool bitmapMode() const { return config_->old_gen_bitmap_alloc; }
    // Cells in a uniform block: (end_of_objects - start) / cell size.
    static uint32_t cellsIn(const BlockInfo& b) {
        return static_cast<uint32_t>(
            static_cast<size_t>(b.end_of_objects - b.start) /
            classToSize(b.size_class));
    }
    void resetAllocCursors();
    // Removes `id` from its class cursor / queue (before release, flip to
    // large, demotion or compaction). No-op for kAllocNone.
    void detachFromAllocation(BlockId id);
    void setCursor(size_t cls, BlockId id);
    // Folds cursor_[cls]'s pending live bytes / counts into its block's meta
    // and the stats. syncCursorLiveBytes does it for every class.
    void flushCursor(size_t cls);
public:
    // Folds every bitmap cursor's pending live bytes / counts into the block
    // metadata and stats (threaded-gc-02). Called before readers.
    void syncCursorLiveBytes();

private:
    bool refillCursor(size_t cls);
    void* cursorAllocate(size_t cls, size_t requested_size);
    void* finalizeBitmapCell(AllocCursor& c, uint32_t k, size_t requested_size);
    bool startVirginBlock(size_t cls);
    bool ensureBagPageAvailable();
    void* allocateFromSizeClassBitmap(size_t cls, size_t requested_size);
    // Frees one cell of a uniform block (bitmap mode): clears its bit and
    // rewinds the cursor / queues the block so the cell is reusable now.
    void freeUniformCell(BlockId id, char* cell);
    // Post-mark (bitmap mode): retire dead nursery-owned bodies, decide
    // is_large blocks, mark uniform blocks swept and queue partial ones.
    void retireDeadLargeBodies();
    void classifyBlocksAfterMark();
    // True iff the in-progress lazy sweep will still walk over `addr` in
    // block `id`: the block is not fully swept and lies ahead of the sweep
    // cursor (a later position, or the current block at/after sweep_cursor_).
    // A cell the sweep has already passed must be pushed onto a free list; a
    // cell ahead of it must NOT be (the gap sweep reclaims it). P§3.7.
    bool sweepWillReach(BlockId id, const char* addr) const;

    // ========== Per-heap GC state (HEAP_053) ==========
    //
    // threaded-gc-01: these were thread_locals. Collection code for a heap
    // reads the heap's own state, never the calling thread's TLS, so a helper
    // thread doing this heap's GC work (phase 3 onward) sees the right values.

    // The owning heap's nursery. Bound by the ThreadLocalHeap constructor;
    // replaces Allocator::isInNursery (which resolved the CALLING thread's
    // heap through tl_heap_) on the mark path.
    const NurserySpace* nursery_ = nullptr;

    // True while this heap's NurserySpace::minorGC is running, i.e. every
    // allocate() is a PROMOTION. Set/cleared by NurserySpace::minorGC.
    bool in_minor_gc_ = false;

    // When non-zero, releaseBlockToAllocator skips the per-call recomputation
    // of region_base_/region_end_: the caller (typically `maybeShrinkCapacity`)
    // is in batch mode and will recompute bounds once at the end. Avoids an
    // O(N) scan inside each release call when shrink is freeing thousands of
    // blocks in one pass.
    int batch_release_depth_ = 0;

    // ========== GC State Machine ==========

    GCPhase gc_phase_;                // Current GC phase (Idle, Marking, or Sweeping).

    // ========== Marking State ==========

    // Each entry on the mark stack pairs an object with the BlockId that
    // owns it (NO_BLOCK_ID for nursery objects). Caching the id on push avoids
    // a second blockIdFor call when markOneObject attributes the object's
    // walkStep-aligned size to the live-bytes accumulator (HEAP_051). The
    // 32-bit id keeps the entry packed at 16 bytes.
    struct MarkStackEntry {
        void* obj;
        BlockId block;      // NO_BLOCK_ID for nursery objects
    };
    static_assert(sizeof(MarkStackEntry) == 16,
                  "MarkStackEntry must pack to 16 bytes");

    // Item 54 FIFO variant: prefetch distance, in objects of real scanning
    // work, between popping an entry off the mark stack and scanning it.
    //
    // MEASURED, do not re-tune by intuition (benchmarks/gc-opt-loop.md, W13d).
    // Median mark time over three cold self-compiles, against 7713.3 ms with
    // no prefetching at all:
    //
    //     depth  4 -> 9492.1 ms   (+23 % — WORSE THAN NO PREFETCH)
    //     depth  8 -> 7269.8 ms   (-5.8 %)
    //     depth 16 -> 6880.2 ms   (-10.8 %)  <-- optimum
    //     depth 32 -> 6947.5 ms   (-9.9 %)
    //     depth 64 -> 7058.0 ms   (-8.5 %)
    //
    // The ring costs something whatever the depth: it trades the mark stack's
    // depth-first locality for an interleaved frontier. Below ~8 the prefetch
    // lands too late to cover the miss, so that cost is paid for nothing --
    // which is why depth 4 is worse than not prefetching. Above ~16 the core
    // runs out of line-fill buffers and L1 pressure grows (64 entries is 4 KiB
    // of prefetched lines), so the extra distance buys nothing.
    //
    // Keep it a POWER OF TWO: the ring index arithmetic is `% MARK_FIFO_DEPTH`,
    // which is a mask only while that holds and becomes a real division
    // otherwise -- a division on the hottest path in mark. The static_assert
    // below enforces it.
    static constexpr size_t MARK_FIFO_DEPTH = 16;
    static_assert(MARK_FIFO_DEPTH > 0 &&
                  (MARK_FIFO_DEPTH & (MARK_FIFO_DEPTH - 1)) == 0,
                  "MARK_FIFO_DEPTH must be a power of two so the ring index "
                  "arithmetic compiles to a mask rather than a division");

    std::vector<MarkStackEntry> mark_stack;  // Grey set: object + cached block index.
    // Nursery objects pushed during the current major-GC mark. Major GC must
    // not write color into nursery headers (minor GC owns them), so we use
    // this set instead of the header `color` field to break cycles when
    // traversing through nursery objects.
    std::unordered_set<void *> nursery_visited_;
    u32 current_epoch;                // Current GC epoch number (increments each cycle).
    bool marking_active;              // True if marking is in progress (legacy flag).
    Allocator *allocator_ref_;        // Reference to Allocator (for nursery membership checks).

    // ========== Lazy Sweep State ==========

    size_t sweep_buffer_index_;       // Index of block currently being swept.
    char* sweep_cursor_;              // Current position within sweep block.
    // (Per-block BufferMetadata lives in blocks_, addressed by BlockId.)

    // Number of blocks that still need sweeping in the current GC cycle.
    // Initialised in finishMarkAndSweep AFTER reclaimAllDeadBlocksFromMeta has
    // removed all-dead blocks from the block table; decremented by
    // markBlockFullySwept whenever a block transitions to fully_swept;
    // zeroed in onSweepComplete and on reset/ctor. Drives the
    // sweep-before-grow gate in allocateFromSizeClass.
    size_t sweep_pending_blocks_;

    // Total in-cycle blocks (i.e. eligible to be swept this cycle) used as
    // the denominator for the unswept-fraction boost in
    // `computeSweepBudgetForAlloc`. Counts blocks whose BufferMetadata has
    // `!fully_swept && garbage_bytes > 0` at sweep entry, so it excludes
    // mid-cycle blocks pre-marked as fully_swept that would otherwise
    // dilute the ratio. Set in `recomputeSweepPendingBlocks` and zeroed in
    // `onSweepComplete` / reset / ctor.
    size_t sweep_total_blocks_;

    // ========== Per-Block Mark Bitmaps (HEAP_050) ==========
    //
    // Liveness for old-gen objects is tracked in per-block bitmaps (1 bit per
    // 8-byte slot). Headers retain a `color` field for compaction's debug
    // asserts but are NOT load-bearing for sweep liveness. Regular blocks use
    // their MarkBitArena slot; is_large blocks use the single large-mark byte
    // in blocks_ (their arena slot has length 0).
    //
    // threaded-gc-01: one fixed-stride slot per BlockId (see MarkBitArena).
    // The slot address never moves; there is no per-block offset table and
    // no re-pack at startMark.
    MarkBitArena mark_;

    // Marker-side live-bytes attribution (HEAP_051): markOneObject adds
    // here; finalizeMetaAfterMark merges into BufferMetadata::live_bytes.
    LiveBytesAccumulator mark_live_;

    // ========== Fragmentation Statistics ==========

    FragmentationStats frag_stats_;   // Heap-wide fragmentation stats (updated after sweep).

    // ========== Compaction State ==========

    CompactionPhase compact_phase_;           // Current compaction phase (Idle, Evacuating, or FixingRefs).
    std::vector<BlockId> evacuation_set_;     // Blocks selected for evacuation.
    size_t current_evac_index_;               // Index within evacuation_set_ being processed.
    char* evac_cursor_;                       // Position within current evacuation block.
    BlockId evac_block_index_;                // Destination block for evacuation bump-allocation.
    char* evac_alloc_ptr_;                    // Bump pointer within evacuation destination block.
    size_t fixup_buffer_index_;               // Block index for reference fixup pass.
    char* fixup_cursor_;                      // Position within current fixup block.

    // ========== Free Lists ==========

    // Segregated free lists indexed by size class.
    // Each list contains free cells of size classToSize(i).
    FreeCell* free_lists_[NUM_SIZE_CLASSES];

    // Number of "on free list" sentinel cells (Header.age & 0b01) PUSHED onto
    // free_lists_ since the last `transitionToSweeping` (item 43). Counted per
    // sentinel PUSH CALL, not per cell: a push can link several cells, so this
    // OVER-counts — which is the safe direction. It is consulted only for the
    // exact-zero case, where it lets transitionToSweeping null the list heads
    // without walking every free cell in the heap to downgrade sentinels that
    // provably do not exist. Reset to 0 by that walk, so it cannot drift
    // across cycles. Only two call sites can produce a sentinel:
    // `splitter::remainder` and `freeLargeBodyCell`.
    size_t free_list_sentinel_count_ = 0;

    // Indices into `blocks_` of large/pinned blocks whose single object died
    // in the most recent sweep. `allocateLargeBlock` consults this list
    // before asking the Allocator for a fresh block.
    std::vector<BlockId> free_large_blocks_;

    // ========== Split-Header Body Tracking (HEAP_026) ==========
    //
    // Bodies of Tag_LargeStringHeader / Tag_LargeByteHeader headers live in
    // old gen but are owned by their nursery header until the header is
    // promoted. While owned, the body is eligible for early reclamation at
    // the end of any minor GC whose evacuation pass did not encounter the
    // header. A 1-bit "seen this minor GC" color decides this — minor GC
    // flips its color at the start, marks bodies as headers are scanned,
    // and frees bodies whose color did not match at the end.
    //
    // Bodies are freed in all GC phases except compaction (sweepNurseryLargeBodies
    // defers only when compact_phase_ != Idle, since compaction reshuffles
    // blocks_). When the body is freed mid-major-GC, freeLargeBodyCell
    // installs the on-free-list sentinel (Header.age & 0b01 = 1) on the
    // resulting Tag_Free cell, so the in-progress lazy sweep treats the
    // cell as a hard run boundary and never coalesces or rewrites it.
    // freeLargeBodyCell is the authoritative ownership transition for
    // split-header bodies — the defensive `large_body_index_.erase` calls
    // in major sweep are idempotent guards only.

public:
    using LargeBodyId = uint32_t;

    struct LargeBodyMeta {
        void*  body_base;   // Raw pointer to the body's Header (Tag_String / Tag_ByteBuffer).
        size_t cell_size;   // Total cell footprint in bytes (includes Header).
        bool   is_large;    // True iff the body sits in a dedicated is_large block.
        bool   color;       // Last minor_color that observed a live header.
        uint8_t kind = 0;   // 0 = split-header body; 1 = young large object (YLOS).
    };

    // ---- threaded-gc-04b HEAP_062: the young large-object space (YLOS) ----
    // A large pointer-bearing object too big for the nursery is allocated in
    // an old-gen cell (pinned, never moved) but is YOUNG: a kind-1 entry in
    // the HEAP_026 index, colored per minor like a split-header body. The
    // minor GC reaches it through the copiers (NurserySpace::reachYoungLarge),
    // scans it in place, ages it, and promotes it in place at promotion_age;
    // an unreached one is freed at minor end. No old object may point at one.

    // Allocates the cell, writes the header for `tag` (pin = 1, age = 0) and
    // registers the kind-1 entry with `initial_color`. nullptr on failure.
    void* allocateYoungLarge(size_t size, Tag tag, bool initial_color);
    // Cheap filter: false for every pointer outside the bounding box of the
    // kind-1 entries (and always false when there are none). Conservative:
    // true does not imply a YLOS object (use youngLargeMeta).
    bool mayBeYoungLarge(const void* p) const {
        return p >= ylo_lo_ && p < ylo_hi_;
    }
    // The kind-1 entry whose object starts at `p`, or nullptr.
    LargeBodyMeta* youngLargeMeta(const void* p) {
        if (!mayBeYoungLarge(p)) return nullptr;
        auto it = large_body_index_.find(const_cast<void*>(p));
        if (it == large_body_index_.end() || it->second >= large_bodies_.size()) return nullptr;
        LargeBodyMeta& m = large_bodies_[it->second];
        return (m.kind == 1 && m.body_base == p) ? &m : nullptr;
    }
    bool isYoungLarge(const void* p) {
        return youngLargeMeta(p) != nullptr;
    }
    // Promotes a YLOS object in place: drops its entry (it is now an ordinary
    // old object governed by the major GC) and resets its age.
    void promoteYoungLarge(void* obj);
    size_t youngLargeCount() const { return ylo_count_; }
    // Bumped at every major mark end (finalizeMetaAfterMark), after which a
    // dead YLOS cell may be retired and reused. The P1 census drops YLOS
    // records across a change.
    uint64_t majorEpoch() const { return major_epoch_; }
    // Recomputes ylo_lo_/ylo_hi_/ylo_count_ from the live kind-1 entries.
    void recomputeYoungLargeBounds();
    // Calls f(obj, meta) for every live kind-1 entry.
    template <typename F> void forEachYoungLarge(F&& f) {
        for (LargeBodyId id : nursery_owned_bodies_) {
            if (id >= large_bodies_.size()) continue;
            LargeBodyMeta& m = large_bodies_[id];
            if (m.body_base != nullptr && m.kind == 1) f(m.body_base, m);
        }
    }

private:
    std::vector<LargeBodyMeta>             large_bodies_;
    std::unordered_map<void*, LargeBodyId> large_body_index_;
    std::vector<LargeBodyId>               nursery_owned_bodies_;
    std::vector<LargeBodyId>               free_large_body_ids_;
    // YLOS bounding box and count (threaded-gc-04b). Grown on registration,
    // recomputed at minor end and after major retirement; conservative in
    // between (promotion in place does not shrink it).
    uint64_t major_epoch_ = 0;
    char*  ylo_lo_ = nullptr;
    char*  ylo_hi_ = nullptr;
    size_t ylo_count_ = 0;
    // Clears an index entry that the major GC found dead: counts a kind-1
    // retirement. Does NOT recycle the id (see freeLargeBodyCell).
    void retireIndexEntry(LargeBodyId id);

    // ========== Small-Class Block Budget ==========
    //
    // While `small_class_bytes_ < config_->small_class_heap_budget_bytes`,
    // small-class (cellSize <= small_class_cell_max_bytes) allocations
    // prefer pulling a fresh uniform bag page over splitting a larger
    // free cell. See `shouldPreferBagForSmallClass`.

    // Sum of totalBytes() of UNIFORM small-class pages currently in
    // `blocks_` (size_class < num_size_classes_ AND size_class is a
    // small class).
    size_t small_class_bytes_;

    // Exclusive upper bound on size-class indices considered "small" for
    // budget purposes. Recomputed from config_ in initialize/reset.
    size_t small_class_index_limit_;

    // Recomputes small_class_index_limit_ from config_->small_class_cell_max_bytes.
    void recomputeSmallClassLimit();

    // True iff `cls` is a small-class index (cls < small_class_index_limit_).
    bool isSmallClassIndex(size_t cls) const {
        return cls < small_class_index_limit_;
    }

    // Credits the given block's totalBytes() to small_class_bytes_ if it
    // is a uniform small-class page. Called immediately after
    // `populateFromBlock` materialises a uniform block.
    void onUniformBlockDedicated(BlockId block_index);

    // Debits the given block's totalBytes() from small_class_bytes_ if it
    // was a uniform small-class page. Called from any path that drops a
    // block from blocks_.
    void onBlockReleased(BlockId block_index);

    // Same as onBlockReleased but used for in-place transitions to is_large
    // (no swap-remove). See allocateFromEmptyRegularBlocks.
    void onBlockTransitioningToLarge(BlockId block_index);

    // ========== Size Class Helpers ==========

    // Maps an allocation request size to its size-class index. Used at
    // ALLOCATION time: returns the smallest class whose cellSize >= size, so
    // a popped cell can always satisfy the request. Returns NUM_SIZE_CLASSES
    // if the size doesn't fit any fixed-cell class (caller must use the
    // page-as-single-cell + split path).
    static size_t sizeClass(size_t size) {
        size = (size + 7) & ~7;
        if (size <= MAX_SMALL_SIZE) {
            return (size / 8) - 1;  // Classes 0..31 cover 8..256.
        }
        // Medium classes 32..(NUM_SMALL_CLASSES + NUM_MEDIUM_CLASSES_MAX - 1).
        // Class i (i >= 32) holds cells of size MEDIUM_CLASS_BASE << (i - 32).
        // Find smallest medium class that holds `size`.
        size_t cell = MEDIUM_CLASS_BASE;
        for (size_t i = 0; i < NUM_MEDIUM_CLASSES_MAX; ++i) {
            if (size <= cell) return NUM_SMALL_CLASSES + i;
            cell <<= 1;
        }
        return NUM_SIZE_CLASSES;  // Doesn't fit any fixed class.
    }

    // Maps a free-cell SPAN size to the class it can safely live on. Used
    // at PLACEMENT time (split tails, coalesced runs, bag-page tails): returns
    // the LARGEST class whose cellSize <= span, so the fast-path consumer of
    // free_lists_[cls] is guaranteed a cell of at least classToSize(cls)
    // bytes (the invariant the fast path relies on). Returns NUM_SIZE_CLASSES
    // if span is below the smallest cell size (caller must drop or merge it).
    //
    // This differs from `sizeClass` (which rounds UP for allocation lookup):
    // medium classes step by powers of 2, so a 352-byte span placed via
    // sizeClass would land on cls=32 (cellSize=512). The fast path would
    // then hand it out as a 512-byte slot, causing buffer overflow when the
    // caller writes more than 352 bytes. freeListClassFor instead routes
    // 352 bytes to cls=31 (cellSize=256), and leftover bytes are pushed onto
    // smaller classes by the cell-placement helper.
    static size_t freeListClassFor(size_t span) {
        span &= ~static_cast<size_t>(7);
        if (span < 8) return NUM_SIZE_CLASSES;
        if (span <= MAX_SMALL_SIZE) {
            // Small classes step by 8: largest cls with (cls+1)*8 <= span.
            return (span / 8) - 1;
        }
        if (span < MEDIUM_CLASS_BASE) {
            // span in (256, 512): no medium fits. Largest small class (256).
            return NUM_SMALL_CLASSES - 1;
        }
        // Medium: largest k with (MEDIUM_CLASS_BASE << k) <= span.
        size_t k = 0;
        while (k + 1 < NUM_MEDIUM_CLASSES_MAX &&
               (MEDIUM_CLASS_BASE << (k + 1)) <= span) {
            ++k;
        }
        return NUM_SMALL_CLASSES + k;
    }

    // Maps a size class index back to its allocation size in bytes.
    static size_t classToSize(size_t cls) {
        if (cls < NUM_SMALL_CLASSES) return (cls + 1) * 8;
        return MEDIUM_CLASS_BASE << (cls - NUM_SMALL_CLASSES);
    }

    // ========== Internal Methods ==========

    // Initializes this old gen space: precommits `initial_old_gen_size` and
    // slices it into pages stored in `unassigned_blocks_`.
    void initialize(Allocator* allocator, const HeapConfig* config);

    // Resets to initial state (clears all blocks, stats, and GC state).
    // If new_config is provided, reconfigures with new parameters. Used for testing.
    void reset(const HeapConfig* new_config = nullptr);

    // Begins incremental marking phase.
    // Pushes all root pointers onto the mark stack for processing.
    // jit_roots contains raw 64-bit heap pointers from JIT-compiled globals.
#if ENABLE_GC_STATS
    void startMark(const std::unordered_set<HPointer*> &roots,
                   const std::unordered_set<uint64_t*> &jit_roots,
                   Allocator &alloc, GCStats &stats);
#else
    void startMark(const std::unordered_set<HPointer*> &roots,
                   const std::unordered_set<uint64_t*> &jit_roots,
                   Allocator &alloc);
#endif

    // Performs incremental marking work (processes work_units worth of objects).
    // Returns true if more marking work remains.
#if ENABLE_GC_STATS
    bool incrementalMark(size_t work_units, GCStats &stats);
#else
    bool incrementalMark(size_t work_units);
#endif

    // Finishes any remaining marking work and transitions to lazy sweeping.
#if ENABLE_GC_STATS
    void finishMarkAndSweep(GCStats &stats);
    void finishMarkAndSweep(GCStats &stats, MajorGCPhaseProfile &profile);
#else
    void finishMarkAndSweep();
    void finishMarkAndSweep(MajorGCPhaseProfile &profile);
#endif

    void markChildren(void *obj);
    void markHPointer(HPointer &ptr);
    // Pushes a heap object onto the mark stack. Routes nursery objects
    // through nursery_visited_ (no header color writes) and old-gen objects
    // through the standard tri-color check.
    void pushMarkRoot(void *obj);
    void markUnboxable(Unboxable &val, bool is_boxed);
    void sweep();

    // Lazy sweeping methods.
    void transitionToSweeping();
    // Returns heap bytes walked (the unit of work_budget).
    size_t lazySweep(size_t target_class, size_t work_budget);
    void onSweepComplete();

    // True if the current GC cycle still has blocks that haven't been fully
    // swept. False when gc_phase_ != Sweeping or when every BufferMetadata
    // entry has fully_swept == true.
    bool hasPendingSweepWork() const {
        return gc_phase_ == GCPhase::Sweeping && sweep_pending_blocks_ > 0;
    }
    bool sweepComplete() const {
        return gc_phase_ != GCPhase::Sweeping || sweep_pending_blocks_ == 0;
    }

    // Recomputes sweep_pending_blocks_ from the blocks' BufferMetadata. Called once per
    // major-GC cycle from finishMarkAndSweep, AFTER all-dead reclaim and
    // BEFORE the initial lazy-sweep slice runs.
    void recomputeSweepPendingBlocks();

    // Centralised "this block is fully swept" mutation: sets the flag and
    // decrements sweep_pending_blocks_ if the transition is fresh.
    void markBlockFullySwept(BlockId block_index);

    // Free-list-only allocation attempt: pop from free_lists_[cls], else
    // try splitting a larger free cell. Does NOT consume a bag page or
    // grow capacity. Returns nullptr on failure. Behaviour-preserving
    // refactor of the first two paragraphs of allocateFromSizeClass.
    void* tryAllocateFromFreeLists(size_t cls, size_t requested_size);

    // Pure free-list manipulation. Pops the head cell of free_lists_[cls]
    // and returns it as a raw pointer (or nullptr if the list is empty).
    // Does NOT touch the header, padding, allocated_bytes, or stats; the
    // caller finalises the cell into an object via finalizePoppedCell.
    FreeCell* tryPopFromFreeList(size_t cls);

    // Behaviour-preserving extraction of the "turn this cell into an
    // object" sequence: initObjectHeaderWithSize → padCellSlack →
    // allocated_bytes += cellSize. Returns the cell as void*.
    void* finalizePoppedCell(FreeCell* cell, size_t cls,
                             size_t requested_size);

    // Returns true while small-class allocations should bag-first instead
    // of splitting larger free cells. See implementation for the predicate.
    bool shouldPreferBagForSmallClass(size_t cls) const;

    // Sweep-on-demand driver: computes a dynamic per-allocation sweep
    // budget via `computeSweepBudgetForAlloc` and, while
    // `hasPendingSweepWork()` and the budget remains, runs sweep_work_budget
    // slices of `lazySweep` and retries `tryAllocateFromFreeLists`. Returns
    // the allocation on success, or nullptr when the sweep finishes or the
    // dynamic budget is exhausted. Called from allocateFromSizeClass on the
    // slow path before falling through to populateFromBlock /
    // allocateFromBagPage.
    void* sweepOnDemandAllocate(size_t cls, size_t requested_size);

    // Returns committed / cap as a fraction in [0, 1]. Approximate:
    // numerator is `getCommittedBytes()` (this thread's old-gen extent),
    // denominator is `config_->max_heap_size / 2` as a stand-in for the
    // global old-gen cap. If Allocator later exposes a cheap
    // `getOldGenCapBytes()` / `getOldGenCommittedBytes()`, swap to that
    // without changing call sites.
    double committedToCapRatio() const;

    // Returns the per-allocation lazy-sweep byte budget for a request of
    // `requested_size` bytes. Combines base proportionality, pressure
    // scaling, and the unswept-fraction boost; clamped to
    // config.max_sweep_bytes_hard.
    size_t computeSweepBudgetForAlloc(size_t requested_size) const;

    // Panic-mode sweep driver: while `hasPendingSweepWork()`, sweeps in
    // panic_sweep_slice_bytes slices and retries the free-list path.
    // Invariant lives at the call site: panic only fires after the bag-page
    // / capacity-grow paths in `allocateFromSizeClass` have failed, meaning
    // growth is impossible. Returns the allocation on success, or nullptr
    // once sweep is exhausted.
    void* panicSweepAndRetryAllocation(size_t cls, size_t requested_size);

    // Post-major-GC growth: if live/capacity > initiating_occupancy, grow
    // committed capacity so live/capacity <= target_utilization. Bounded by
    // the global old-gen cap. See `major_gc_75_50_policy.md`.
    void adjustCapacityAfterMajorGC();

    // Fragmentation and compaction methods.
    bool shouldCompact() const;
    void computeFragmentationStats();
    void scheduleCompaction();
    std::vector<BlockId> selectEvacuationSet(size_t max_live_to_move);
    void incrementalCompactionSlice(size_t work_budget);
    size_t evacuateSlice(size_t work_budget);
    void prepareReferenceFixup();
    void fixReferencesSlice(size_t work_budget);
    void fixPointersInObject(void* obj);
    void fixHPointer(HPointer& ptr);
    void fixUnboxable(Unboxable& val, bool is_boxed);
    void* allocateForEvacuation(size_t size);
    void installForwardingPointer(void* old_location, void* new_location);
    void* getForwardingAddress(void* obj) const;
    bool isInEvacuationSet(BlockId block) const;
    void freeEvacuatedBuffers();

    // ========== Segregated-Fits + BBoP Internal Helpers ==========

    // Top-level dispatch for non-large allocations: tries the size-class
    // fast path, then splitting from larger cells, then population from a
    // bag page.
    void* allocateFromSizeClass(size_t cls, size_t requested_size);

    // Allocates by pulling an unassigned page, wrapping it as a single
    // Tag_Free cell, and splitting off a `requested_size` chunk. Used for
    // allocations in the [large_object_threshold, alloc_buffer_size) range,
    // and as a fallback when no fixed-cell class can satisfy a request.
    void* allocateFromBagPage(size_t requested_size);

    // Walks free lists for classes > target_cls; if a cell large enough is
    // found, carves off `alloc_size` bytes and returns the front, pushing
    // the remainder onto the appropriate free list.
    void* tryAllocateBySplittingLarger(size_t target_cls, size_t alloc_size);

    // Linear scan over `blocks_` to find the BlockInfo whose [start, end)
    // contains addr. Returns nullptr if no block matches (e.g. the address
    // is from a freshly-acquired bag page that hasn't been registered yet).
    // Linear cost: blocks_.size() is bounded by total committed pages.
    const BlockInfo* findBlockContaining(char* addr) const {
        for (size_t pos = 0; pos < blocks_.size(); ++pos) {
            const BlockInfo& block = blocks_.info(blocks_.idAt(pos));
            if (addr >= block.start && addr < block.end) {
                return &block;
            }
        }
        return nullptr;
    }

    // Pulls a page from `unassigned_blocks_`, slices it into uniform cells
    // of `classToSize(cls)`, and links them onto `free_lists_[cls]`. Returns
    // true if a page was available and populated.
    bool populateFromBlock(size_t cls);

    // Initializes an object header in newly allocated memory. Sets color to
    // Black during marking/sweeping (so the object is not treated as garbage
    // mid-cycle), White otherwise. Tag/size are written by the caller.
    void initObjectHeader(void* obj);
    void initObjectHeaderWithSize(void* obj, size_t cell_bytes);

    // Allocates a single object that exceeds alloc_buffer_size by acquiring
    // a dedicated old-gen block sized exactly to fit it. The caller is
    // expected to mark the resulting object's header with pin = 1 so it is
    // excluded from compaction.
    void* allocateLargeBlock(size_t size);

    // ========== Large-block reuse helpers ==========

    // Marks block `idx` (an `is_large` block whose single object died) as
    // available for reuse via `allocateFromFreeLargeBlocks`. Asserts that
    // the block is not already on the list.
    void markBlockAsFreeLarge(BlockId block_index);

    // Returns a previously-released large block sized >= `size`, or nullptr
    // if no such block is available. On success, resets the block's
    // BufferMetadata to live, re-initialises the object header, and updates
    // bookkeeping. The caller initialises the tag/size after.
    void* allocateFromFreeLargeBlocks(size_t size);

    // Looks for a fully-free regular page large enough to host `size` and
    // re-purposes it as a large block. On success, flips `is_large = true`,
    // drops embedded free cells, resets `end_of_objects` and bookkeeping,
    // and returns the page base. Returns nullptr if no such page exists.
    void* allocateFromEmptyRegularBlocks(size_t size);

    // ========== Shrink path helpers ==========
    //
    // Called from `adjustCapacityAfterMajorGC` to release fully-free pages
    // back to the Allocator after a major GC reclaims most live data.
    // Must NOT be called while holding `Allocator::thread_mutex_`; each
    // helper acquires it transiently inside the Allocator.

    // Releases a fully-free block from `blocks_` back to the Allocator.
    // Walks free lists to drop any FreeCell that lies inside the block, drops
    // a `free_large_blocks_` entry if applicable, removes the BlockInfo and
    // BufferMetadata, and patches indices that referenced the moved-from slot.
    void releaseBlockToAllocator(BlockId block_index);

    // Releases an unassigned bag-page extent back to the Allocator. These
    // pages were never materialized into `blocks_`, so this is just an
    // Allocator round-trip plus a swap-remove from `unassigned_blocks_`.
    void releaseUnassignedBlockToAllocator(size_t unassigned_index);

    // Removes any FreeCell that lies inside `[info(idx).start, ...end)`
    // from every per-class free list. Called before releasing a block so
    // its embedded free cells don't leave dangling free-list pointers.
    void removeFreeCellsForBlock(BlockId block_index);

    // Patches the two POSITION cursors (sweep_buffer_index_,
    // fixup_buffer_index_) when a release's swap-remove moved the block at
    // order position `old_pos` to `new_pos`. Every other stored block
    // reference is a BlockId and does not move (threaded-gc-01, HEAP_048).
    void fixupCursorsAfterOrderMove(size_t old_pos, size_t new_pos);

    // Inspects post-mark live/heap and, if heap is well above the desired
    // capacity, releases fully-free pages until heap ≈ desired_heap_bytes.
    // The caller (adjustCapacityAfterMajorGC) computes desired_heap_bytes
    // from mark-derived live bytes. `light_pass=true` skips releases unless
    // current_heap > desired_heap * 1.5 — used at onSweepComplete to avoid
    // double-shrink churn after the heavy pass already ran post-mark.
    void maybeShrinkCapacity(size_t desired_heap_bytes,
                             bool light_pass = false);

    // ========== Page-index helpers (Step 1) ==========

    // Commits the page index through region_end_. Called after any
    // commit/grow that moves region_end_ forward (formerly
    // resizePageIndexForRegion).
    void resizePageIndexForRegion() { commitPageIndexThrough(region_end_); }

    // Returns the first / last page slot the block covers, or SIZE_MAX if
    // the index is not set up / the block lies below index_base_.
    size_t firstPageIndex(const BlockInfo& block) const;
    size_t lastPageIndex(const BlockInfo& block) const;

    // Records `block_index` as an owner of every page slot the block's
    // extent covers. Used when a block is materialized.
    void assignPageIndexForBlock(BlockId block_index);

    // Removes `block_index` from every page slot the block's extent covers.
    // Used immediately before a block is released (both removal paths).
    void clearPageIndexForBlock(BlockId block_index);

    // Returns the id of the block containing `obj`, or NO_BLOCK_ID if `obj`
    // lies outside [region_base_, region_end_) or no block currently owns its
    // page. O(1): one page-index slot, at most two extent checks (there is no
    // linear fallback).
    BlockId blockIdFor(const void* obj) const;

    // Materializes a block: BlockTable::add + mark-arena slot + page index.
    // The one place a block enters the old gen (threaded-gc-01 Step 5.1).
    BlockId materializeBlock(const BlockInfo& bi, const BufferMetadata& m,
                             size_t mark_bytes);

    // ========== Split-Header Body Helpers ==========

    // Records a freshly-allocated body in tracking. Reuses a tombstone id from
    // free_large_body_ids_ when present.
    LargeBodyId registerLargeBody(void* body, size_t cell_size, bool is_large,
                                  bool minor_color, uint8_t kind = 0);
    // allocate() + the cell-footprint computation shared by the split-header
    // body and YLOS allocators. Returns the cell and its footprint.
    void* allocateTrackedCell(size_t total_size, size_t& cell_size, bool& is_large);

    // Frees a body cell. For is_large bodies, hands the block to
    // free_large_blocks_ via markBlockAsFreeLarge. For size-class / split-
    // page bodies, writes Tag_Free over the cell and pushes onto the
    // appropriate free list, decrementing live_bytes for the owning block.
    // Erases m.body_base from large_body_index_.
    void freeLargeBodyCell(LargeBodyMeta& m);


    // ========== Per-Block Mark Bitmap Helpers ==========

    // Bitmap granularity: one bit per 8-byte heap slot. Header is 8 bytes
    // and all heap allocations are 8-byte-aligned, so bits map 1:1 to
    // possible object start addresses.
    static constexpr size_t MARK_ALIGNMENT = 8;

    // Number of 8-byte slots in this block (regular blocks only). For
    // is_large blocks the per-byte vector stays empty.
    size_t slotsForBlock(const BlockInfo& block) const {
        return block.totalBytes() / MARK_ALIGNMENT;
    }

    size_t bitmapBytesForBlock(const BlockInfo& block) const {
        return (slotsForBlock(block) + 7) / 8;
    }

    // Computes the (byte_index, mask) for the bit covering `obj` inside
    // block `id`. Caller is responsible for routing is_large blocks to the
    // large-mark byte instead of calling this.
    void markBitLocation(BlockId id, const void* obj,
                         size_t* byte_index, uint8_t* mask) const {
        const BlockInfo& block = blocks_.info(id);
        const char* p = static_cast<const char*>(obj);
        const size_t offset = static_cast<size_t>(p - block.start);
        const size_t slot = offset / MARK_ALIGNMENT;
        *byte_index = slot / 8;
        *mask = static_cast<uint8_t>(1u << (slot & 7));
    }

    bool isMarkedInBlock(BlockId id, const void* obj) const {
        if (!id.valid()) return false;
        if (blocks_.info(id).is_large) {
            return blocks_.largeMark(id) != 0;
        }
        size_t byte_index;
        uint8_t mask;
        markBitLocation(id, obj, &byte_index, &mask);
        if (byte_index >= mark_.len(id)) return false;
        return (mark_.slot(id)[byte_index] & mask) != 0;
    }

    // Item 40: `pushMarkRoot` used to call isMarkedInBlock and then
    // setMarkBitInBlock — two full lookups for one logical test-and-set.
    // Returns true if the bit was ALREADY set (caller should stop), false if
    // this call set it (caller should push the object). An out-of-range slot
    // returns false and sets nothing, which is the behaviour the pair had.
    bool testAndSetMarkBitInBlock(BlockId id, const void* obj) {
        if (!id.valid()) return false;
        if (blocks_.info(id).is_large) {
            uint8_t& lm = blocks_.largeMark(id);
            const uint8_t prev = lm;
            lm = 1;
            return prev != 0;
        }
        size_t byte_index;
        uint8_t mask;
        markBitLocation(id, obj, &byte_index, &mask);
        if (byte_index >= mark_.len(id)) return false;
        uint8_t& b = mark_.slot(id)[byte_index];
        const bool was_set = (b & mask) != 0;
        b |= mask;
        return was_set;
    }

    // Sets the bit for `obj` and returns true if the bit was previously
    // unset (i.e. this caller observed the white→grey transition).
    bool setMarkBitInBlock(BlockId id, const void* obj) {
        if (!id.valid()) return false;
        if (blocks_.info(id).is_large) {
            uint8_t& lm = blocks_.largeMark(id);
            const uint8_t prev = lm;
            lm = 1;
            return prev == 0;
        }
        size_t byte_index;
        uint8_t mask;
        markBitLocation(id, obj, &byte_index, &mask);
        if (byte_index >= mark_.len(id)) return false;
        uint8_t& b = mark_.slot(id)[byte_index];
        const bool was_set = (b & mask) != 0;
        b |= mask;
        return !was_set;
    }

    // Tests the bit for `obj`, clears it, and returns whether it was set.
    // Used by sweep so that the bitmap is left all-zero post-sweep
    // (precondition for the next mark cycle to skip bulk-zeroing).
    bool testAndClearMarkBitInBlock(BlockId id, const void* obj) {
        if (!id.valid()) return false;
        if (blocks_.info(id).is_large) {
            uint8_t& lm = blocks_.largeMark(id);
            const uint8_t prev = lm;
            lm = 0;
            return prev != 0;
        }
        size_t byte_index;
        uint8_t mask;
        markBitLocation(id, obj, &byte_index, &mask);
        if (byte_index >= mark_.len(id)) return false;
        uint8_t& b = mark_.slot(id)[byte_index];
        const bool was_set = (b & mask) != 0;
        b &= static_cast<uint8_t>(~mask);
        return was_set;
    }

    // ========== Mark-time live-bytes attribution (Step 2) ==========

    // Performs the White → Grey → Black transition on `obj`, recursively
    // pushes children via markChildren, and attributes the object's
    // walkStep-aligned size to the live-bytes accumulator (HEAP_051).
    // Skips Tag_Free and already-Black objects. For nursery objects, only
    // calls markChildren — major GC must not write into nursery headers and
    // nursery cells aren't tracked per block. Returns true if the
    // object did real work (popped one work unit).
    //
    // The two-arg form takes the cached block id produced by
    // pushMarkRoot so the hot path skips a redundant blockIdFor lookup
    // (NO_BLOCK_ID means "unknown / nursery"). The one-arg wrapper looks
    // up the index itself; only cold callers (lazy-sweep adjacency) use it.
    bool markOneObject(void* obj, BlockId block);
    bool markOneObject(void* obj);

    // O(#blocks) reset of every live block's BufferMetadata, called at major-GC
    // start so live_bytes attribution can begin from zero.
    void resetBufferMetaForMark();

    // Demotes uniform size-class blocks whose mark-derived live_bytes is at
    // most HeapConfig::demote_live_fraction (default 0.5; 0.0 = never) of their
    // total bytes to mixed (`size_class = NUM_SIZE_CLASSES`).
    // Run after `finalizeMetaAfterMark` and before `transitionToSweeping` so
    // that (a) the residency snapshot still sees the pre-demotion class
    // assignments and (b) `transitionToSweeping` then wipes free_lists_,
    // discarding any stale uniform-class cells without us having to walk
    // them. Lazy sweep parses demoted blocks by `getObjectSize` (the
    // mixed-block walk step) and re-emits coalesced runs through the
    // any-class packer in `pushSpanOnFreeLists`, so the freed space lands on
    // mixed-only classes (>= num_size_classes_) and becomes splittable for
    // smaller demand. Returns {blocks_demoted, total_bytes_in_demoted_blocks}.
    struct DemotionStats {
        size_t blocks_demoted = 0;
        size_t bytes_demoted  = 0;
    };
    DemotionStats demoteMostlyDeadUniformBlocks();

    // After the mark stack drains: clamp meta.live_bytes <= block.totalBytes(),
    // set meta.garbage_bytes = block.totalBytes() - meta.live_bytes, and
    // populate frag_stats_.{live_bytes, heap_bytes, total_free_bytes} from the
    // mark-derived totals. Called from finishMarkAndSweep.
    void finalizeMetaAfterMark();

    // Resets meta.garbage_bytes and meta.fully_swept for every block in
    // preparation for lazy sweep, while preserving mark-derived
    // meta.live_bytes (which the post-mark shrink depends on).
    void prepareMetaForLazySweep();

    // ========== All-dead block fast path (Step 3) ==========

    struct AllDeadReclaimStats {
        size_t blocks_released = 0;
        size_t bytes_released  = 0;
    };

    // Walks the blocks back-to-front (by position) and releases every non-large block
    // whose live_bytes == 0 via releaseBlockToAllocator. Brackets the loop
    // with batch_release_depth_ and recomputes region_base_/region_end_
    // once at the end. Excludes is_large blocks (which continue to flow
    // through markBlockAsFreeLarge / allocateFromFreeLargeBlocks).
    AllDeadReclaimStats reclaimAllDeadBlocksFromMeta();

#if ENABLE_GC_STATS
    // Per-block free-bytes map keyed by `BlockInfo::start`. The key is
    // stable across `releaseBlockToAllocator`'s swap-remove of `blocks_`
    // entries, so a snapshot taken before reclaim can be looked up after
    // reclaim has completed.
    using FreeBytesByBlockStart = std::unordered_map<const char*, size_t>;

    // Phase A of the major-GC end residency snapshot. Walks `free_lists_`
    // and `free_large_blocks_` to record the per-class free-list
    // histogram into `stats` and to populate `out` with the per-block
    // free byte totals (keyed by start address). MUST be called BEFORE
    // `transitionToSweeping`, which wipes `free_lists_` /
    // `free_large_blocks_`. The four-way breakdown
    // {live, free, garbage, unallocated-tail} relies on this map being
    // captured here while the free-list state is still meaningful.
    void gatherFreeListSnapshotInto(GCStats& stats,
                                    FreeBytesByBlockStart& out) const;

    // Phase B of the major-GC end residency snapshot. Walks every
    // surviving block in `blocks_` and records its live / free / garbage
    // breakdown into `stats`. MUST be called AFTER
    // `reclaimAllDeadBlocksFromMeta` and `adjustCapacityAfterMajorGC` so
    // that the histogram reflects the true post-reclaim block set: the
    // `live_frac == 0` bucket is then the genuinely retained dead pages
    // (held by the min-heap floor, `is_large` exclusion, or pinning), not
    // blocks about to be released. Per-block
    // free bytes are looked up in `free_by_start`, which the caller must
    // have populated via `gatherFreeListSnapshotInto` BEFORE
    // `transitionToSweeping`.
    void gatherResidencySnapshotFrom(
        GCStats& stats,
        const FreeBytesByBlockStart& free_by_start) const;
#endif

#if ECO_HEAP_VALIDATE
    // ========== threaded-gc-01 metadata validators (P§4 Step 9) ==========
    //
    // One entry point, run at the old gen's sync points (end of
    // finishMarkAndSweep, end of every release batch, compaction free pass,
    // every 64th minor GC). Each check re-derives an invariant that
    // threaded-gc-01 relies on or whose maintaining code it deleted. Aborts
    // with a "[heap-validate] <where>: ..." line on the first violation.
    void validateOldGenMetadata(const char* where) const;
    // V6: every Tier-M free cell's back-link names its actual predecessor
    // in its size-class list (HEAP_052).
    void validateFreeListBackLinks(const char* where) const;
public:
    // Runs validateOldGenMetadata on every 64th call (deterministic). Called
    // at the end of every minor GC by NurserySpace::minorGC.
    void validateEveryNthMinor();
private:
    uint64_t validate_minor_count_ = 0;
#endif

    friend class Allocator;
    friend class NurserySpace;
    friend class ThreadLocalHeap;
    friend class OldGenSpaceTestAccess;
    friend struct p1::P1CensusAccess;   // threaded-gc-04: reads mark bits at mark end
};

// ============================================================================
// Test Access Helper
// ============================================================================

// For test code only - provides privileged access to OldGenSpace internals.
class OldGenSpaceTestAccess {
public:
    // threaded-gc-03 V2 negative test: plant an extent in the unassigned list.
    static void pushUnassignedForTesting(OldGenSpace& og, char* start, char* end) {
        og.unassigned_blocks_.emplace_back(start, end);
    }
    static void popUnassignedForTesting(OldGenSpace& og) { og.unassigned_blocks_.pop_back(); }

#if ENABLE_GC_STATS
    static void startMark(OldGenSpace& oldgen, const std::unordered_set<HPointer*>& roots,
                          Allocator& alloc, GCStats& stats) {
        std::unordered_set<uint64_t*> empty_jit_roots;
        oldgen.startMark(roots, empty_jit_roots, alloc, stats);
    }

    static void startMark(OldGenSpace& oldgen, const std::unordered_set<HPointer*>& roots,
                          const std::unordered_set<uint64_t*>& jit_roots,
                          Allocator& alloc, GCStats& stats) {
        oldgen.startMark(roots, jit_roots, alloc, stats);
    }

    static bool incrementalMark(OldGenSpace& oldgen, size_t work_units, GCStats& stats) {
        return oldgen.incrementalMark(work_units, stats);
    }

    static void finishMarkAndSweep(OldGenSpace& oldgen, GCStats& stats) {
        oldgen.finishMarkAndSweep(stats);
    }
#else
    static void startMark(OldGenSpace& oldgen, const std::unordered_set<HPointer*>& roots,
                          Allocator& alloc) {
        std::unordered_set<uint64_t*> empty_jit_roots;
        oldgen.startMark(roots, empty_jit_roots, alloc);
    }

    static void startMark(OldGenSpace& oldgen, const std::unordered_set<HPointer*>& roots,
                          const std::unordered_set<uint64_t*>& jit_roots,
                          Allocator& alloc) {
        oldgen.startMark(roots, jit_roots, alloc);
    }

    static bool incrementalMark(OldGenSpace& oldgen, size_t work_units) {
        return oldgen.incrementalMark(work_units);
    }

    static void finishMarkAndSweep(OldGenSpace& oldgen) {
        oldgen.finishMarkAndSweep();
    }
#endif

    // Size class helpers.
    static size_t sizeClass(size_t size) { return OldGenSpace::sizeClass(size); }
    static size_t classToSize(size_t cls) { return OldGenSpace::classToSize(cls); }
    static size_t freeListClassFor(size_t span) {
        return OldGenSpace::freeListClassFor(span);
    }

    // GC phase state.
    static GCPhase getGCPhase(const OldGenSpace& oldgen) { return oldgen.gc_phase_; }
    static CompactionPhase getCompactPhase(const OldGenSpace& oldgen) { return oldgen.compact_phase_; }

    // Sweep state.
    static size_t getSweepBufferIndex(const OldGenSpace& oldgen) { return oldgen.sweep_buffer_index_; }
    static const char* getSweepCursor(const OldGenSpace& oldgen) { return oldgen.sweep_cursor_; }
    static size_t getSweepPendingBlocks(const OldGenSpace& oldgen) {
        return oldgen.sweep_pending_blocks_;
    }
    static size_t getSweepTotalBlocks(const OldGenSpace& oldgen) {
        return oldgen.sweep_total_blocks_;
    }
    static bool hasPendingSweepWork(const OldGenSpace& oldgen) {
        return oldgen.hasPendingSweepWork();
    }
    static bool sweepComplete(const OldGenSpace& oldgen) {
        return oldgen.sweepComplete();
    }

    // Adaptive lazy-sweep pacing (Stage 5 §13).
    static size_t computeSweepBudgetForAlloc(OldGenSpace& oldgen,
                                             size_t requested_size) {
        return oldgen.computeSweepBudgetForAlloc(requested_size);
    }
    static double committedToCapRatio(const OldGenSpace& oldgen) {
        return oldgen.committedToCapRatio();
    }

    // Forces the "no growth available + pending sweep" precondition so
    // panic-path tests are deterministic: empties unassigned bag pages by
    // pretending they were already consumed (caller is responsible for not
    // touching the released memory). Returns the bag size before the drain
    // so the test can assert the precondition was non-trivial.
    static size_t drainUnassignedBlocksForTest(OldGenSpace& oldgen) {
        size_t n = oldgen.unassigned_blocks_.size();
        oldgen.unassigned_blocks_.clear();
        return n;
    }

    // Fragmentation stats.
    static const FragmentationStats& getFragStats(const OldGenSpace& oldgen) { return oldgen.frag_stats_; }

    // Free lists.
    // ---- threaded-gc-02 bitmap allocation (HEAP_054) ----
    static BlockId cursorBlock(const OldGenSpace& og, size_t cls) {
        return og.cursor_[cls].block;
    }
    static size_t partialQueueLength(const OldGenSpace& og, size_t cls) {
        return og.partial_[cls].size() - og.partial_head_[cls];
    }
    static uint8_t allocState(const OldGenSpace& og, BlockId id) {
        return og.blocks_.info(id).alloc_state;
    }
    static void releaseBlock(OldGenSpace& og, BlockId id) {
        og.releaseBlockToAllocator(id);
    }
    static void driveSweepToCompletion(OldGenSpace& og) {
        while (og.gc_phase_ == GCPhase::Sweeping) {
            og.lazySweep(NUM_SIZE_CLASSES, std::numeric_limits<size_t>::max() / 2);
        }
    }
    static bool demoted(const OldGenSpace& og, BlockId id) {
        return og.blocks_.info(id).size_class >= og.num_size_classes_;
    }
    static const BufferMetadata& metaOf(OldGenSpace& og, BlockId id) {
        og.syncCursorLiveBytes();
        return og.blocks_.meta(id);
    }
    // Bytes of free-list cells whose start lies in [lo, hi).
    static size_t freeListBytesIn(const OldGenSpace& og, const char* lo,
                                  const char* hi) {
        size_t n = 0;
        for (size_t cls = 0; cls < NUM_SIZE_CLASSES; ++cls) {
            for (FreeCell* c = og.free_lists_[cls]; c != nullptr; c = c->next_in_class) {
                const char* p = reinterpret_cast<const char*>(c);
                if (p >= lo && p < hi) n += c->header.size;
            }
        }
        return n;
    }
    // Non-aborting V10: cursor / queue / alloc_state consistency.
    static bool allocStateConsistent(const OldGenSpace& og) {
        for (size_t cls = 0; cls < NUM_SIZE_CLASSES; ++cls) {
            const BlockId b = og.cursor_[cls].block;
            if (b.valid() && (!og.blocks_.isLive(b) ||
                              og.blocks_.info(b).alloc_state != OldGenSpace::kAllocCurrent)) {
                return false;
            }
            for (size_t k = og.partial_head_[cls]; k < og.partial_[cls].size(); ++k) {
                const BlockId q = og.partial_[cls][k];
                if (!og.blocks_.isLive(q) ||
                    og.blocks_.info(q).alloc_state != OldGenSpace::kAllocQueued) {
                    return false;
                }
            }
        }
        return true;
    }
#if ENABLE_GC_STATS
    static const BitmapAllocStats& bitmapStats(OldGenSpace& og) {
        og.syncCursorLiveBytes();
        return og.alloc_stats_.bm;
    }
#endif
    static size_t numSizeClasses(const OldGenSpace& og) { return og.num_size_classes_; }
    static bool sweepWillReach(const OldGenSpace& og, BlockId id, const void* a) {
        return og.sweepWillReach(id, static_cast<const char*>(a));
    }

    // threaded-gc-01 (HEAP_052): true iff every Tier-M cell on every class
    // list decodes its back-link to its actual predecessor (nullptr at the
    // head). Non-aborting twin of OldGenSpace::validateFreeListBackLinks.
    static bool freeListBackLinksConsistent(const OldGenSpace& oldgen) {
        for (size_t cls = 0; cls < NUM_SIZE_CLASSES; ++cls) {
            const FreeCell* pred = nullptr;
            for (FreeCell* c = oldgen.free_lists_[cls]; c != nullptr;
                 c = c->next_in_class) {
                if (c->header.size >= MIN_TIER_M_SIZE &&
                    getPrev(reinterpret_cast<const FreeCellMid*>(c)) != pred) {
                    return false;
                }
                pred = c;
            }
        }
        return true;
    }

    static FreeCell* getFreeList(const OldGenSpace& oldgen, size_t cls) {
        assert(cls < NUM_SIZE_CLASSES && "getFreeList: invalid size class (>= NUM_SIZE_CLASSES)");
        return oldgen.free_lists_[cls];
    }

    // Block metadata.
    // threaded-gc-01: position-indexed views (positions == the former
    // std::vector subscripts, so tests keep their meaning).
    static size_t blockCount(const OldGenSpace& oldgen) {
        return oldgen.blocks_.size();
    }
    static BlockId blockIdAt(const OldGenSpace& oldgen, size_t pos) {
        return oldgen.blocks_.idAt(pos);
    }
    static const BlockInfo& blockInfoAt(const OldGenSpace& oldgen, size_t pos) {
        return oldgen.blocks_.info(oldgen.blocks_.idAt(pos));
    }
    static const BufferMetadata& bufferMetaAt(const OldGenSpace& oldgen,
                                              size_t pos) {
        return oldgen.blocks_.meta(oldgen.blocks_.idAt(pos));
    }
    static const BlockTable& getBlockTable(const OldGenSpace& oldgen) {
        return oldgen.blocks_;
    }
    // Order-position snapshots: element i describes position i, exactly as
    // the former getBlocks()/getBufferMeta() vectors did.
    static std::vector<BlockInfo> getBlocks(const OldGenSpace& oldgen) {
        std::vector<BlockInfo> v;
        v.reserve(oldgen.blocks_.size());
        for (size_t pos = 0; pos < oldgen.blocks_.size(); ++pos) {
            v.push_back(oldgen.blocks_.info(oldgen.blocks_.idAt(pos)));
        }
        return v;
    }
    static std::vector<BufferMetadata> getBufferMeta(const OldGenSpace& oldgen) {
        std::vector<BufferMetadata> v;
        v.reserve(oldgen.blocks_.size());
        for (size_t pos = 0; pos < oldgen.blocks_.size(); ++pos) {
            v.push_back(oldgen.blocks_.meta(oldgen.blocks_.idAt(pos)));
        }
        return v;
    }
    static const std::vector<std::pair<char*, char*>>& getUnassignedBlocks(
            const OldGenSpace& oldgen) {
        return oldgen.unassigned_blocks_;
    }
    static const std::vector<BlockId>& getFreeLargeBlocks(
            const OldGenSpace& oldgen) {
        return oldgen.free_large_blocks_;
    }

    // Manual control of lazy sweeping for testing.
    static void transitionToSweeping(OldGenSpace& oldgen) { oldgen.transitionToSweeping(); }
    static void lazySweep(OldGenSpace& oldgen, size_t target_class, size_t work_budget) {
        oldgen.lazySweep(target_class, work_budget);
    }

    // Page-index access for tests (Step 1).
    static BlockId blockIdFor(const OldGenSpace& oldgen, const void* obj) {
        return oldgen.blockIdFor(obj);
    }
    static const ReservedArray<OldGenSpace::PageOwners>& getPageIndex(
            const OldGenSpace& oldgen) {
        return oldgen.page_index_;
    }

    // Per-block mark bitmap access for tests. Item 40 replaced the
    // vector-of-vectors with an arena; these return a pointer+length view.
    // (A repo-wide grep found no users outside this header at the time of
    // the change.)
    static const uint8_t* getMarkBitsForBlock(
            const OldGenSpace& oldgen, BlockId id, size_t* len_out) {
        *len_out = oldgen.mark_.len(id);
        return oldgen.mark_.slot(id);
    }
    static uint8_t getLargeBlockMark(const OldGenSpace& oldgen, BlockId id) {
        return oldgen.blocks_.largeMark(id);
    }
    static bool isObjectMarked(const OldGenSpace& oldgen, void* obj) {
        if (!oldgen.contains(obj)) return false;
        const BlockId id = oldgen.blockIdFor(obj);
        if (!id.valid()) return false;
        return oldgen.isMarkedInBlock(id, obj);
    }
    static bool setObjectMark(OldGenSpace& oldgen, void* obj) {
        if (!oldgen.contains(obj)) return false;
        const BlockId id = oldgen.blockIdFor(obj);
        if (!id.valid()) return false;
        return oldgen.setMarkBitInBlock(id, obj);
    }

    // Mark-time live attribution (Step 2): drive the helper directly.
    static void resetBufferMetaForMark(OldGenSpace& oldgen) {
        oldgen.resetBufferMetaForMark();
    }
    static void finalizeMetaAfterMark(OldGenSpace& oldgen) {
        oldgen.finalizeMetaAfterMark();
    }

    // All-dead reclaim (Step 3) for tests.
    static OldGenSpace::AllDeadReclaimStats reclaimAllDeadBlocksFromMeta(
            OldGenSpace& oldgen) {
        return oldgen.reclaimAllDeadBlocksFromMeta();
    }

    // Small-class budget access for tests.
    static size_t getSmallClassBytes(const OldGenSpace& oldgen) {
        return oldgen.small_class_bytes_;
    }
    static size_t getSmallClassIndexLimit(const OldGenSpace& oldgen) {
        return oldgen.small_class_index_limit_;
    }
    static bool shouldPreferBagForSmallClass(const OldGenSpace& oldgen,
                                             size_t cls) {
        return oldgen.shouldPreferBagForSmallClass(cls);
    }

    // Split-header body tracking access for tests.
    static const std::vector<OldGenSpace::LargeBodyMeta>& getLargeBodies(
            const OldGenSpace& oldgen) {
        return oldgen.large_bodies_;
    }
    static const std::vector<OldGenSpace::LargeBodyId>& getNurseryOwnedBodies(
            const OldGenSpace& oldgen) {
        return oldgen.nursery_owned_bodies_;
    }
    static bool isBodyTracked(const OldGenSpace& oldgen, void* body) {
        return oldgen.large_body_index_.find(body) !=
               oldgen.large_body_index_.end();
    }

    // Compaction control for testing.
    static void scheduleCompaction(OldGenSpace& oldgen) { oldgen.scheduleCompaction(); }
    static void incrementalCompactionSlice(OldGenSpace& oldgen, size_t work_budget) {
        oldgen.incrementalCompactionSlice(work_budget);
    }
    static const std::vector<BlockId>& getEvacuationSet(const OldGenSpace& oldgen) {
        return oldgen.evacuation_set_;
    }
    static void* getForwardingAddress(const OldGenSpace& oldgen, void* obj) {
        return oldgen.getForwardingAddress(obj);
    }
};

} // namespace Elm

#endif // ECO_OLDGENSPACE_H
