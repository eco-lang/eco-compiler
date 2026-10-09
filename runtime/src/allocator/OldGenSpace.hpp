#ifndef ECO_OLDGENSPACE_H
#define ECO_OLDGENSPACE_H

#include <limits>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>
#include "AllocatorCommon.hpp"
#include "RootSet.hpp"
#include "GCStats.hpp"
#include "BlockTable.hpp"
#include "LargeObjectSpace.hpp"
#include "MarkWork.hpp"
#include "GCHelperPool.hpp"
#include "MinorWork.hpp"
#include <memory>
#include <mutex>

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
    // threaded-gc-06: parallel minor workers (HEAP_067); promotion contexts.
    static constexpr unsigned kMaxMinorWorkers = 64;
    static constexpr unsigned kMaxPromoWorkers = kMaxMinorWorkers;
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

    // plans/large-object-space.md D3 (HEAP_080): a pointer-free pinned large
    // object or a permanent-space fallback of `size` bytes (>= LOT) in the LOS
    // object pool (huge tier above one LOS block). Writes the header for `tag`
    // (pin = 1) and tracks it as a kind-2 (old, not nursery-owned) entry, freed
    // by the major GC when unmarked. nullptr on failure.
    void* allocateOldLarge(size_t size, Tag tag);

    // The largest uniform size class (8 KiB at defaults): old-gen objects above
    // it live in the LOS (D3; the legacy nursery placement cap).
    size_t largestUniformClassBytes() const { return classToSize(num_size_classes_ - 1); }

    const LargeObjectSpace& largeObjectSpace() const { return los_; }
    bool isLosBlock(BlockId id) const { return (blocks_.info(id).los & kLosBlock) != 0; }
    // Is `p` in a raw block (an LOS raw block or a raw huge block): a
    // header-less large body (HEAP_081)?
    bool isRawBody(const void* p) const;

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
        char* const base = regionBase();   // CR-021: through atomic_ref
        char* const end = regionEnd();
        return (end > base) ? static_cast<size_t>(end - base) : 0;
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
        Headroom,         // threaded-gc-05c: committed + margin * H_c * P_hat >=
                          // finish_fraction * cap
    };
    // threaded-gc-05c Part B (P§3.11): heap-relative trigger pacing.
    // P_hat = integer EWMA (1/8) of old-gen bytes allocated per minor, from
    // the monotone old_alloc_total_; H_c = T + 1 minors (the fixed schedule).
    void notePacingMinorEnd() {
        const int64_t sample = static_cast<int64_t>(old_alloc_total_ - old_alloc_at_prev_minor_);
        old_alloc_at_prev_minor_ = old_alloc_total_;
        p_hat_ += (sample - p_hat_) / 8;
    }
    int64_t promoRateEstimate() const { return p_hat_; }
    uint64_t oldAllocTotal() const { return old_alloc_total_; }
    uint64_t pacingHorizonMinors() const {
        return (config_->incremental_mark ? config_->incremental_mark_slices : 0) + 1ull;
    }
    // "p_hat=..;live_ref=..;alloc_since_major=..;headroom=.." at the last t0.
    std::string pacingSnapshot() const;

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
        return p >= regionBase() && p < regionEnd();
    }
    // threaded-gc-05c (H5): the region bounds are read by background markers
    // while the mutator extends the region; every write goes through
    // setRegionBase/setRegionEnd (CR-009) and every read, the owner's own
    // included, through regionBase/regionEnd (CR-021: [atomics.ref.generic]/3)
    // -- relaxed atomics, plain moves on x86. During
    // a cycle the region only grows, so a stale value still covers every
    // block that existed at t0.
    // TLA-REGION(OGH.regionAndOwnerAccessors) begin
    char* regionBase() const {
        return std::atomic_ref<char*>(const_cast<char*&>(region_base_)).load(std::memory_order_relaxed);
    }
    char* regionEnd() const {
        return std::atomic_ref<char*>(const_cast<char*&>(region_end_)).load(std::memory_order_relaxed);
    }
    void setRegionBase(char* v) { std::atomic_ref<char*>(region_base_).store(v, std::memory_order_relaxed); }
    void setRegionEnd(char* v) { std::atomic_ref<char*>(region_end_).store(v, std::memory_order_relaxed); }

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
    // threaded-gc-05c (H3): owner words are read by background markers.
    static void storeOwner(uint32_t& w, uint32_t v) {
        std::atomic_ref<uint32_t>(w).store(v, std::memory_order_release);
    }
    static uint32_t loadOwner(const uint32_t& w) {
        return std::atomic_ref<uint32_t>(const_cast<uint32_t&>(w)).load(std::memory_order_acquire);
    }
    // CR-021: the writer's own reads of an owner word. It is the only writer,
    // so relaxed suffices; while a marker may hold an atomic_ref to the word
    // ([atomics.ref.generic]/3) the read must still go through one.
    static uint32_t loadOwnerRelaxed(const uint32_t& w) {
        return std::atomic_ref<uint32_t>(const_cast<uint32_t&>(w)).load(std::memory_order_relaxed);
    }
    // TLA-REGION(OGH.regionAndOwnerAccessors) end
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
    // threaded-gc-07 (HEAP_070): owned by one tenure job from grant to merge.
    // No allocator path may select, detach or release such a block (trap 4).
    static constexpr uint8_t kAllocTenure = 3;
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

    // ========== Promotion buffers (threaded-gc-06 P§3.8, HEAP_054) ==========
    //
    // Inside a parallel minor each worker owns one AllocCursor per size class
    // (rung 1 of the bitmap ladder, no lock); rungs 2-8 run under promo_mu_.
    // Fast-path accounting goes to the worker's fields and is merged after the
    // join. Worker cursors exist only between beginParallelPromotion and
    // endParallelPromotion; worker 0 adopts cursor_[] there and hands it back.
    struct PromoWorker {
        AllocCursor cur[NUM_SIZE_CLASSES];
        uint64_t allocated_bytes = 0;     // allocated_bytes delta (fast path)
        uint64_t old_alloc_total = 0;     // old_alloc_total_ delta (fast path)
        uint64_t bm_allocs = 0, bm_bytes = 0;   // alloc_stats_.bm cursor counters
        uint64_t mutex_acquires = 0, mutex_wait_ns = 0;
        uint64_t size_hist[GCStats::OLDGEN_ALLOC_BUCKETS] = {};
        uint64_t size_16_24 = 0;
        // Step 7b: rung-2 free cells popped in a batch under the lock and
        // finalized one by one outside it (N > 1 only); returned at the merge.
        static constexpr unsigned kStash = 16;
        FreeCell* stash[NUM_SIZE_CLASSES][kStash];
        uint8_t stash_n[NUM_SIZE_CLASSES] = {};
        uint64_t list_pops = 0, stash_returned = 0;
        uint8_t chunk_units[NUM_SIZE_CLASSES] = {};   // next claim size (units), per minor
#if ECO_HEAP_VALIDATE
        std::vector<void*> cycle_alloc_log;   // IM4, appended to cycle_alloc_log_
        uint64_t mutex_charges = 0;           // PM6: bytes charged under the lock
#endif
        void resetRun();
    };
    struct PromoCtx {
        unsigned n = 0;
        PromoWorker w[kMaxPromoWorkers];
        // N > 1 (as built, P§10.1): workers share ONE current block per class
        // and claim chunks of it by CAS on shared[cls] = (block id + 1) << 32 |
        // next unit index (0 = no block), a unit being kChunkUnitCells cells.
        // A unit of 64 cells of any 8-byte-multiple size covers whole 64-bit
        // bitmap words (not just bytes: the scans read a word at a time,
        // bitscan::loadWord, CR-022), so workers never share one; open-block
        // slack is N chunks, not N blocks.
        bool chunked = false;
        // One cache line per class: hot classes are claimed by every worker,
        // and packed words made each claim invalidate its neighbours' line.
        struct alignas(64) SharedWord { std::atomic<uint64_t> w{0}; };
        SharedWord shared[NUM_SIZE_CLASSES];
    };
    // Chunks are counted in units of kChunkUnitCells (64 cells of any
    // 8-byte-multiple size = whole 64-bit bitmap words, the unit
    // bitscan::nextFreeCell/nextSetBit read: CR-022; a unit below 64 cells
    // would let two workers' scans share a word). A worker's claim for a class
    // starts at 1 unit each minor and doubles up to kChunkMaxUnits (1,024
    // cells): classes a worker barely uses leave little open slack (the
    // committed bytes the garbage-fraction trigger reads), hot classes claim
    // rarely (E2 as built: fixed 256 cost +9 % minor time, fixed 1,024 moved
    // the first major from minor 91 to 145).
    // TLA-REGION(OGH.kChunkUnitCells) begin
    static constexpr uint32_t kChunkUnitCells = 64;
    // TLA-REGION(OGH.kChunkUnitCells) end
    static constexpr uint32_t kChunkMaxUnits = 16;
    // Lazily allocated; valid for the heap's lifetime.
    PromoCtx& promoCtx();
    // n >= 1 workers; worker 0 adopts cursor_[]. Requires bitmap allocation.
    void beginParallelPromotion(PromoCtx& ctx, unsigned n);
    // After the join, single-threaded: flushes, returns worker cursors to the
    // FRONT of partial_[] (W6), merges accounting, runs a deferred sweep end.
    void endParallelPromotion(PromoCtx& ctx);
    // A promotion by worker `pw` (any thread inside a parallel minor).
    // `per_alloc_sweep` reproduces allocate()'s per-promotion lazy-sweep slice
    // (the one-worker identity switch only; P§3.8.5).
    void* allocatePromotion(PromoWorker& pw, size_t size, bool per_alloc_sweep);
    bool parallelPromotionActive() const { return par_promo_active_; }
    // Under promo_mu_. CR-002 (plans/threaded-gc-register-fixes.md 4.3, HEAP_055):
    // a cell of a block the gap sweep has not finished shares mark words with the
    // sweeper's plain nextSetBit / clearBit, so it must be finalized before
    // promo_mu_ is released and never stashed. The gap sweep touches mark words
    // only while gc_phase_ == Sweeping, and nothing sets Sweeping inside a minor,
    // so outside Sweeping no cell needs the lock (gc_phase_ is read plain: under
    // promo_mu_, its only in-minor write is under it too).
    bool cellInUnsweptBlock(void* cell) const {
        if (gc_phase_ != GCPhase::Sweeping) return false;
        const BlockId id = contains(cell) ? blockIdFor(cell) : NO_BLOCK_ID;
        return id.valid() && !blocks_.meta(id).fully_swept;
    }

    // ========== Promotion grant (threaded-gc-07 P§3.12, HEAP_070) ==========
    //
    // A tenure job allocates its copies ONLY from a grant: uniform blocks in
    // state kAllocTenure, sized in the hand-over pause from the tenuring
    // extent's per-class object counts, returned at the merge. A cursor
    // caches everything the collector needs (block start, cell size, bitmap
    // slot, cell count), so the collector never reads blocks_, the page
    // index or any other shared allocator table (trap 5).
    struct TenureCursor {
        BlockId  block = NO_BLOCK_ID;
        char*    base = nullptr;
        uint8_t* bits = nullptr;
        uint32_t next_cell = 0, num_cells = 0, cell_bytes = 0, stride_bits = 0;
        uint64_t pending_live = 0, pending_allocs = 0;
    };
    struct TenureGrant {
        std::vector<TenureCursor> blocks[NUM_SIZE_CLASSES];   // in grant order
        uint32_t next[NUM_SIZE_CLASSES] = {};                  // index of the block in use
        uint64_t allocated_bytes = 0, old_alloc_total = 0;     // deltas, merged at the return
        uint64_t size_hist[GCStats::OLDGEN_ALLOC_BUCKETS] = {};
        uint64_t size_16_24 = 0;
        uint64_t granted_cells = 0, used_cells = 0, block_count = 0, virgin_blocks = 0;
        bool active = false;
#if ECO_HEAP_VALIDATE
        bool cycle_active = false;                             // IM4 logging
        std::vector<void*> cycle_alloc_log;
#endif
        // Lever L3 (several collector threads): members claim 64-cell chunks
        // (whole 64-bit bitmap words, the unit the scans read, so members
        // never share one: CR-022) by CAS on
        // claim[cls] = block index << 32 | next unit, over the blocks above.
        struct alignas(64) ClaimWord { std::atomic<uint64_t> w{0}; };
        ClaimWord claim[NUM_SIZE_CLASSES];
    };
    // L3 chunk size in cells for a class of stride_bits (= cell / 8) bits:
    // >= 1,024 bitmap bits (two cache lines), >= 64 cells.
    // TLA-REGION(OGH.tenureChunkCells) begin
    static uint32_t tenureChunkCells(uint32_t stride_bits) {
        const uint32_t c = 1024u / (stride_bits == 0 ? 1u : stride_bits);
        return c < 64u ? 64u : (c & ~63u);
    }
    // TLA-REGION(OGH.tenureChunkCells) end
    // A collector member's private allocation cursor over the grant (L3).
    struct TenureMemberCursor {
        struct Cls { int32_t bi = -1; uint32_t k = 0, kend = 0, used = 0; };
        Cls c[NUM_SIZE_CLASSES];
        struct Use { uint16_t cls; uint32_t bi; uint32_t cells; };
        std::vector<Use> uses;                                 // folded at the merge
        uint64_t size_hist[GCStats::OLDGEN_ALLOC_BUCKETS] = {};
        uint64_t size_16_24 = 0;
#if ECO_HEAP_VALIDATE
        std::vector<void*> cycle_alloc_log;
#endif
        void reset() { *this = TenureMemberCursor{}; }
    };
    // Any thread owning a member cursor of the live grant: the next free cell
    // of class cls from the member's chunk (claiming a new chunk as needed).
    void* grantAllocateShared(TenureGrant& g, TenureMemberCursor& m, size_t cls, size_t requested_size);
    // In a pause, after the members: folds their usage into the grant cursors.
    void grantFoldMember(TenureGrant& g, TenureMemberCursor& m);
    // In the pause: builds `g` (which must be inactive) covering count[c]
    // cells of every class c. W6: partial_ front first, then virgin blocks.
    // `slack_participants` (L3): every class also covers one chunk per
    // participant (tenureChunkCells of the class). Returns false when the
    // old gen cannot supply enough blocks (near its cap): the grant then
    // holds what it got (active) and the caller returns it and falls back
    // to the in-pause parallel engine, whose ladder is the legacy one.
    bool grantTenure(const uint32_t count[NUM_SIZE_CLASSES], TenureGrant& g,
                     uint32_t slack_participants = 0);
    // Any thread owning `g` (the collector): the next free cell of class cls.
    // Aborts when the grant is exhausted (its histogram was wrong).
    void* grantAllocate(TenureGrant& g, size_t cls, size_t requested_size);
    // In the pause, after the job: flushes, requeues blocks with free cells
    // at the FRONT of partial_ (first-granted first), merges accounting.
    void returnTenureGrant(TenureGrant& g);
    // Live grants (TV5: no kAllocTenure block outside one).
    unsigned activeTenureGrants() const { return active_tenure_grants_; }
    // Test hooks (negative controls, P§3.19).
    bool test_grant_t0_block_ = false;
    bool test_shrink_ignores_tenure_ = false;
    // TV5 (validate): every kAllocTenure block belongs to a live grant.
    void validateTenureBlocks(const char* where) const;
#if ECO_HEAP_VALIDATE
    // PM6: allocated_bytes before the drain, for the post-merge check.
    size_t pm6_allocated_before_ = 0;
    bool pm6_skip_ = false;
    // CR-028 (plans/threaded-gc-register-fixes.md 4.4, HEAP_055): gap-swept
    // blocks completed inside a parallel promotion with N > 1, walked by V11 in
    // endParallelPromotion after the join (a worker may still be writing a cell
    // it popped from the block). Written under promo_mu_; cleared at begin.
    std::vector<std::pair<BlockId, char*>> v11_deferred_;
    // V11: the gap-swept block parses exactly by header over [start, end_of_objects).
    void validateV11(BlockId id) const;
#endif

private:
    // threaded-gc-06 worker-cursor variants (P§3.8.2). Duplicates of the
    // serial functions (which stay untouched) with the cursor passed in and
    // accounting redirected to the worker.
    void flushCursorW(AllocCursor& c, PromoWorker& pw);
    void setCursorW(AllocCursor& c, size_t cls, BlockId id, PromoWorker& pw);
    bool refillCursorW(AllocCursor& c, size_t cls, PromoWorker& pw);
    void* finalizeBitmapCellW(AllocCursor& c, uint32_t k, size_t requested_size, PromoWorker& pw);
    void* finalizePoppedCellW(FreeCell* cell, size_t cls, size_t requested_size, PromoWorker& pw);
    void* cursorAllocateW(AllocCursor& c, size_t requested_size, PromoWorker& pw);
    bool startVirginBlockW(AllocCursor& c, size_t cls, PromoWorker& pw);
    void* ladderFrom2W(size_t cls, size_t requested_size, PromoWorker& pw);
    void requeueFront(size_t cls, BlockId id);
    bool claimChunkW(size_t cls, AllocCursor& c, PromoWorker& pw);
    bool advanceSharedW(size_t cls);
    bool startVirginBlockShared(size_t cls);
    void publishShared(size_t cls, BlockId id);
    void sweepCompleteInPromotion();
    std::unique_ptr<PromoCtx> promo_ctx_;
    minorwork::SpinMutex promo_mu_;   // short sections: spin, not futex (P§3.8.3)
    bool par_promo_active_ = false;
    bool sweep_complete_deferred_ = false;   // onSweepComplete held for the merge
    // CR-007 (HEAP_058/HEAP_059): AvoidUnderPromo while a parallel promotion
    // with more than one worker is active (the caller holds promo_mu_ or is a
    // worker), else Allowed. Passed to every acquireOldGenBlock a promotion
    // can reach (ensureBagPageAvailable, allocateFromBagPage, allocateLargeBlock).
    AcquireWait acquireWaitPolicy() const;
    bool refillCursor(size_t cls);
    void* cursorAllocate(size_t cls, size_t requested_size);
    void* finalizeBitmapCell(AllocCursor& c, uint32_t k, size_t requested_size);
    bool startVirginBlock(size_t cls);
    // threaded-gc-07: the block-creation half of startVirginBlock (no cursor).
    BlockId materializeVirginBlock(size_t cls);
    unsigned active_tenure_grants_ = 0;
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

    // Current GC phase (Idle, Marking, or Sweeping). CR-001 (HEAP_067): inside
    // a parallel promotion its one write (lazySweep's completeSweep) is a relaxed
    // atomic_ref store and the reads outside promo_mu_ (finalizePoppedCellW,
    // finalizeBitmapCellW) relaxed atomic_ref loads; every other access runs in a
    // pause, serially or under promo_mu_ and stays plain.
    GCPhase gc_phase_;
    static_assert(std::atomic_ref<GCPhase>::is_always_lock_free);

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

    // threaded-gc-05b (HEAP_064): the grey set lives in the markers (worker 0's
    // `stack` on the serial path, the markers' deques on the parallel path).
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

    // ========== threaded-gc-05b: the markers (HEAP_064, HEAP_051) ==========
    // One MarkWorker per marker: worker 0 always exists (the mutator; the
    // serial and legacy paths use only it). Each marker attributes live bytes
    // to its OWN accumulator; finalizeMetaAfterMark merges them in index order.
public:
    struct SerialMark   { static constexpr bool kParallel = false; };
    struct ParallelMark { static constexpr bool kParallel = true; };
    struct MarkWorker {
        // Serial: worker 0's grey set. Parallel: this marker's PRIVATE stack
        // (owner-only, no atomics); its oldest half is published to `deque`
        // when the deque runs dry, and thieves steal only from the deque.
        std::vector<uint64_t> stack;
        std::atomic<uint64_t> priv{0};           // stack.size(), for other markers' termination checks
        uint64_t pops = 0;
        markwork::WorkStealingDeque deque;       // parallel grey set
        LiveBytesAccumulator live;               // HEAP_051: this marker's bytes
        markwork::MarkerCounters ctr;
        uint64_t chunks = 0;                     // chunk entries pushed (stats)
    };
    static constexpr unsigned kMaxMarkers = 64;
    unsigned markThreads() const { return mark_threads_; }
    bool markParallel() const { return mark_parallel_; }
    // gc_mark_threads resolved: 0 = auto (min(cap, available CPUs)); 1 when
    // bitmap allocation is off (parallel marking runs only inside cycles).
    static unsigned resolveMarkThreads(const HeapConfig& cfg);
    // threaded-gc-06 (HEAP_067): gc_minor_threads resolved (0 = auto); 1 when
    // bitmap allocation is off. The gang is sized for max(mark, minor).
    static unsigned resolveMinorThreads(const HeapConfig& cfg);
    unsigned minorThreads() const { return minor_threads_; }
    gc::GCMarkGang& ensureGang();
private:
    std::unique_ptr<MarkWorker> markers_[kMaxMarkers];
    // threaded-gc-05c (P§3.2): marker SLOTS. 0..F-1 foreground (0 = the
    // mutator; F = mark_threads_, the GCMarkGang size), F..F+B-1 background
    // (B = conc_threads_). Every slot has an accumulator and a deque; loops
    // about slots run to mark_slots_, loops that start a gang to F.
    unsigned mark_threads_ = 1;      // F: foreground markers
    unsigned minor_threads_ = 1;     // threaded-gc-06: parallel minor workers
    unsigned conc_threads_ = 0;      // B: background markers (conc_mark = 2 only)
    unsigned mark_slots_ = 1;        // F + B
    bool mark_parallel_ = false;     // fixed at beginMarkCycle (mark_slots_ > 1)
    MarkWorker& w0() { return *markers_[0]; }
    const MarkWorker& w0() const { return *markers_[0]; }
    // Sum of every marker's accumulator for `id` (IM6, V5).
    uint64_t markLivePeek(BlockId id) const;
    uint64_t markLiveTake(BlockId id);
    uint64_t markLiveSum() const;
    void markLiveMergeAll();
    void ensureMarkers();
    template <class P> bool testAndSetMark(BlockId id, const void* obj);
    template <class P> void greyObject(MarkWorker& w, void* obj);
    template <class P> void greyHPointer(MarkWorker& w, HPointer& ptr);
    template <class P> void scanChildren(MarkWorker& w, void* obj);
    template <class P> void scanChunk(MarkWorker& w, void* obj, uint32_t chunk);
    template <class P> bool scanObject(MarkWorker& w, void* obj, BlockId block);
    template <class P> void scanEntry(MarkWorker& w, uint64_t e);
    static constexpr size_t kPublishMin = 64;
    // Publish the OLDEST half of w's private stack to its stealable deque
    // when the deque is empty (owner only).
    // TLA-REGION(OGH.publishGrey) begin
    void publishHalf(MarkWorker& w) {
        if (w.stack.size() < kPublishMin || !w.deque.emptyApprox()) return;
        const size_t half = w.stack.size() / 2;
        for (size_t i = 0; i < half; ++i) w.deque.push(w.stack[i]);
        w.stack.erase(w.stack.begin(), w.stack.begin() + static_cast<std::ptrdiff_t>(half));
        w.priv.store(w.stack.size(), std::memory_order_relaxed);
    }
    // threaded-gc-05c: move the WHOLE private stack to the deque (owner only).
    // Every exit of a parallel run calls it, so no private work survives a run
    // (IM15) and any thread can steal what is left.
    void publishAll(MarkWorker& w) {
        if (w.stack.empty()) return;
        for (uint64_t e : w.stack) w.deque.push(e);
        w.stack.clear();
        w.priv.store(0, std::memory_order_relaxed);
    }
    void pushGrey(MarkWorker& w, uint64_t e) {
#if ECO_HEAP_VALIDATE
        if (snapshot_mode_) im11_t0_greys_.push_back(e);   // IM11: the t0 grey set
#endif
        w.stack.push_back(e);
        if (mark_parallel_) {
            w.priv.store(w.stack.size(), std::memory_order_relaxed);
            if ((w.stack.size() & 31) == 0) publishHalf(w);
        }
    }
    // TLA-REGION(OGH.publishGrey) end
    // Runs marking with `budget` tickets (markwork::kDrainBudget = drain) on
    // mark_threads_ markers when mark_parallel_, else serially on worker 0.
    // Returns the units consumed (exact, P§3.3).
    uint64_t runMarkers(int64_t budget);
    static void markerEntry(void* ctx, unsigned member);
    bool markStackEmpty() const;      // exact only when no marker runs (05c trap 12)
    bool markWorkApprox() const;      // 05c: atomics only; safe while an episode runs
    size_t markStackSize() const;
    struct SerialEnv;
    struct ParallelEnv;
    friend struct SerialEnv;
    friend struct ParallelEnv;
#if ECO_HEAP_VALIDATE
    // IM10 (scanned once) / IM11 (scanned set == closure of the t0 greys).
    void im10NoteScan(uint64_t e);
    void im10Reset();
    void im11Check(const char* where);
    std::vector<uint64_t> im11_t0_greys_;
    struct Im10State;
    std::unique_ptr<Im10State> im10_;
#endif
    // ========== threaded-gc-05c: concurrent marking (HEAP_065) ==========
public:
    // The t0 view (P§3.2): every scalar a ParallelMark path needs, filled in
    // beginMarkCycle and immutable until the handoff -- markers never read the
    // live nursery bounds, cycle state or the YLOS index.
    struct MarkView {
        const char* nursery_lo = nullptr;   // the nursery RESERVATION (immutable)
        const char* nursery_hi = nullptr;
#if ECO_HEAP_VALIDATE
        std::vector<const void*> ylos_t0;   // sorted YLOS addresses at t0
#endif
    };
    enum class BgEpisode : uint8_t { None, Running, Finished };
    static unsigned resolveConcMarkThreads(const HeapConfig& cfg, unsigned fg);
    unsigned concThreads() const { return conc_threads_; }
    unsigned markSlots() const { return mark_slots_; }
    BgEpisode bgEpisode() const { return bg_ep_; }
private:
    MarkView mark_view_;
    BgEpisode bg_ep_ = BgEpisode::None;
    // M1 trace only: a refused launch in this cycle step (logged as a launched episode
    // that a fork stopped at once: register-fixes §7.2 step 4).
    bool bg_refused_step_ = false;
    std::unique_ptr<gc::GCBackgroundGang> bg_;
    std::unique_ptr<markwork::SliceControl> bg_ctl_;
    uint32_t bg_done_k_ = 0;           // stats: first step that saw it finished
public:
    // Per-cycle progress counters for the event-log cycle row (P§3.13).
    struct CycleProgress { uint64_t bg_units = 0, assists = 0, assist_units = 0, closing_units = 0; uint32_t done_k = 0; };
    CycleProgress cycleProgress() const { CycleProgress p = cyc_prog_; p.done_k = bg_done_k_; return p; }
private:
    CycleProgress cyc_prog_;
    // Part B state (mutator-only; deterministic).
    uint64_t old_alloc_total_ = 0;
    uint64_t old_alloc_at_prev_minor_ = 0;
    int64_t  p_hat_ = 0;
    struct PacingAtT0 { int64_t p_hat = 0; uint64_t live_ref = 0, alloc_since_major = 0, headroom = 0; };
    PacingAtT0 pacing_t0_;
    uint64_t bg_launch_ns_ = 0;        // stats: wall at launch
    bool fg_run_active_ = false;       // a GCMarkGang run is in progress (IM14)
    bool step_pause_work_ = false;     // the last concurrent step ran an assist or a closing join
    bool young_in_view(const void* obj) const {
        const char* p = static_cast<const char*>(obj);
        return p >= mark_view_.nursery_lo && p < mark_view_.nursery_hi;
    }
#if ECO_HEAP_VALIDATE
    bool ylosAtT0(const void* obj) const;
    bool isT0Block(BlockId id) const;
    std::atomic<bool> im10_armed_{false};
#endif
    // Background episode (P§3.5). False when a fork's prepare held the gang (the
    // launch was refused, CR-013/004): bg_ep_ is None, the work stays in the deques.
    bool launchBackground();
    void reapBackground(bool wait);
    void mergeBackgroundCounters();
    void retireAllDequeArrays();
    uint64_t bgConsumedApprox() const;
    size_t runCycleStepConcurrent();
    void assistEpisode(int64_t budget);
    size_t closingFinish();
    static void bgEntry(void* ctx, unsigned member);
    static void assistEntry(void* ctx, unsigned member);
    static void closingEntry(void* ctx, unsigned member);
    void assertNoPrivateWork(const char* where) const;
#if ECO_HEAP_VALIDATE
    // IM16 (P§3.9): a decision path (trigger, pressure finish, allocation
    // ladder) is on the stack; collector-progress reads assert it is not.
    mutable int in_decision_ = 0;
    struct DecisionScope {
        const OldGenSpace& og;
        explicit DecisionScope(const OldGenSpace& o) : og(o) { ++og.in_decision_; }
        ~DecisionScope() { --og.in_decision_; }
    };
    void assertNotInDecision(const char* what) const;
#endif
    // IM14: aborts if a gang runs on any of slots [lo, hi) (the foreground
    // gang on [0, F), the background gang on [F, F + B)). The default range
    // is every slot: no gang runs at all (the launch's check).
    void assertSlotsQuiescent(const char* where, unsigned lo = 0, unsigned hi = kMaxMarkers) const;
public:
    // Stops and joins a running background episode (reset, destruction, tests).
    void stopBackground();
    // Test hooks (P§3.9, Step 6).
    bool test_skip_bg_merge_ = false;
    bool test_leave_private_on_exit_ = false;
    bool test_cursor_takes_t0_block_ = false;
    bool test_plain_allocate_black_ = false;
    std::atomic<bool> test_bg_hold_{false};   // bg members wait while set
#if ECO_HEAP_VALIDATE
    // Negative control (IM14, register CR-010): an assist also resets
    // background slot F's counter while the background gang runs.
    bool test_assist_resets_bg_ctr_ = false;
#endif
public:
    // Negative-control hooks (tests only; P§3.11).
    bool test_skip_merge_worker1_ = false;
    bool test_plain_bits_parallel_ = false;
    bool test_steal_without_ticket_ = false;
private:

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

    // TLA-REGION(OGH.LargeBodyMeta) begin
    struct LargeBodyMeta {
        void*  body_base;   // Raw pointer to the body's Header (Tag_String / Tag_ByteBuffer).
        size_t cell_size;   // Total cell footprint in bytes (includes Header).
        bool   is_large;    // True iff the body sits in a dedicated is_large block.
        bool   color;       // Last minor_color that observed a live header.
        uint8_t kind = 0;   // 0 = split-header body; 1 = young large object (YLOS);
                            // 2 = old LOS object (plans/large-object-space.md: pinned
                            // pointer-free, permanent fallback, promoted YLOS; never owned).
        // Region nursery (HEAP_072): the minor at which this YLOS incarnation
        // joined a generation (0 = not yet). An extent's ylos_gen list names
        // objects by ADDRESS, and a major may free a dead member whose cell a
        // new YLOS then reuses before the list is next read; the stamp tells
        // the two incarnations apart (youngLargeMember).
        uint64_t join_minor = 0;
    };
    // TLA-REGION(OGH.LargeBodyMeta) end

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
    // TLA-REGION(OGH.youngLargeMeta) begin
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
    // TLA-REGION(OGH.youngLargeMeta) end
    bool isYoungLarge(const void* p) {
        return youngLargeMeta(p) != nullptr;
    }
    // The kind-1 entry at `p` only if it is the incarnation that joined the
    // generation filled at `gen_minor` (HEAP_072), else nullptr: a member
    // freed by a major is either gone from the index or its cell now holds
    // a newer YLOS object (unjoined, or joined at a later minor).
    // TLA-REGION(OGH.youngLargeMember) begin
    LargeBodyMeta* youngLargeMember(const void* p, uint64_t gen_minor) {
        LargeBodyMeta* m = youngLargeMeta(p);
        return (m != nullptr && m->join_minor == gen_minor) ? m : nullptr;
    }
    // TLA-REGION(OGH.youngLargeMember) end
    // CR-017 (HEAP_074): whether the last STW major reached nursery object `p`
    // (nursery_visited_). Valid from a STW major's mark end until the next
    // prepareMark; NurserySpace::zapDeadAfterMajor reads it right after the mark.
    bool majorReachedNursery(const void* p) const {
        return nursery_visited_.count(const_cast<void*>(p)) != 0;
    }
    // Promotes a YLOS object in place: drops its entry (it is now an ordinary
    // old object governed by the major GC) and resets its age.
    void promoteYoungLarge(void* obj);
    size_t youngLargeCount() const { return ylo_count_; }
    // threaded-gc-07: the body is still tracked by the index (nursery-owned).
    bool largeBodyIndexed(void* body) const { return large_body_index_.count(body) != 0; }
    // Bumped at every major mark end (finalizeMetaAfterMark), after which a
    // dead YLOS cell may be retired and reused. The P1 census drops YLOS
    // records across a change.
    uint64_t majorEpoch() const { return major_epoch_; }
    // Mark-derived live bytes at the end of the last major (the LiveBudget
    // trigger's input); GCReport::live_after_mark (HEAP_076). 0 before any.
    size_t majorLiveBytes() const { return major_live_; }

    // ---- The explicit release (plans/frontend-heap-release.md §3.3, HEAP_076) ----
    // Drives the lazy sweep to Idle (pattern: OldGenSpaceTestAccess::
    // driveSweepToCompletion). Called inside ThreadLocalHeap::majorGCAndShrink's
    // pause, after the STW major, never during a mark cycle.
    void finishSweepForRelease();
    // maybeShrinkCapacity(0, ShrinkPass::Forced): releases every fully-swept
    // live_bytes == 0 block and unassigned page down to the floor.
    void shrinkToFloorForRelease();
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
    LargeObjectSpace                       los_;   // plans/large-object-space.md D2
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
    // CR-035 (HEAP_056): retires every index entry whose body lies in [lo, hi)
    // with retireDeadLargeBodies' semantics -- the id is NOT recycled;
    // sweepNurseryLargeBodies drops its stale owned entry. Returns the count.
    size_t retireIndexRange(char* lo, char* hi);

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

    // ========== threaded-gc-05a: the incremental mark cycle (HEAP_063) ==========
    // plans/threaded-gc-05a-incremental-marking.md. Driven by ThreadLocalHeap
    // (it owns the roots); single-threaded, deterministic (GC_DET_001).
public:
    enum class CycleState : uint8_t { Idle, Marking, HandoffDue };
    enum class CycleFinish : uint8_t { Schedule, Pressure, Join };
    bool cycleActive() const { return cycle_state_ != CycleState::Idle; }
    CycleState cycleState() const { return cycle_state_; }
private:
    // t0: startMark's preparation (sweep drain, clearForMark, cursors, meta),
    // then gc_phase_ = Marking and the cycle bookkeeping for `slices` = T.
    void beginMarkCycle(Allocator& alloc, uint32_t slices);
    // Shared by startMark and beginMarkCycle.
    void prepareMark(Allocator& alloc);
    // Snapshot mode (P§3.2): pushMarkRoot drops nursery and YLOS targets.
    void setSnapshotMode(bool on) {
#if ECO_HEAP_VALIDATE
        // IM14: the snapshot pushes the t0 greys onto slot 0 as its owner.
        if (on) assertSlotsQuiescent("the t0 snapshot", 0, 1);
#endif
        snapshot_mode_ = on;
    }
    // One JIT root word (startMark's JIT loop body).
    void markJitRootRaw(uint64_t val, Allocator& alloc);
    // t0: mark every YLOS cell and grey its old-gen children.
    void snapshotYoungLarge();
    // Mark work: processes up to `work_units` objects (ring drained) and
    // returns the old-gen units done.
    size_t markWorkUnits(size_t work_units);
    // One cycle step at minor end k (1 <= k <= T): a paced slice, or the
    // closing drain at k == T. Returns units done.
    size_t runCycleSlice();
    // threaded-gc-05c: after the t0 snapshot (T >= 1): launch the background
    // episode (conc_mark 2) or mark everything now (conc_mark 1, sync).
    void afterSnapshot();
    // conc_mark 2 with background markers, in a multi-minor cycle.
    bool concurrentCycle() const {
        return conc_threads_ > 0 && cycle_slices_ > 0 && mark_parallel_;
    }
    // The mode-2 step at minor end k: reap, paced assist, closing. Returns the
    // units marked INSIDE this pause.
    size_t cycleStep() { return concurrentCycle() ? runCycleStepConcurrent() : runCycleSlice(); }
    bool lastStepHadPauseWork() const { return step_pause_work_; }
    // Drains the mark stack completely (closing slice / emergency / join).
    size_t drainCycleMark();
    // The handoff (P§3.6): runs the post-mark tail and returns to Idle.
    void handoffMarkCycle(GCStats* stats, MajorGCPhaseProfile* profile);
    // True when old-gen committed / cap >= incremental_mark_finish_fraction.
    bool cyclePressureFinishDue() const;
    uint32_t cycleSlicesPlanned() const { return cycle_slices_; }
    uint32_t cycleMinorsSinceT0() const { return cycle_k_; }
    void noteCycleMinorEnd() { ++cycle_k_; }
    uint64_t cycleUnitsDone() const { return cycle_units_; }
    uint64_t cyclePredictedUnits() const { return cycle_predicted_; }
    // The post-mark tail, shared by every finishMarkAndSweep overload and the
    // handoff. stats/profile may be null.
    void runPostMarkTail(GCStats* stats, MajorGCPhaseProfile* profile);
    // Handoff step 6: frees deferred during the cycle (P§3.7).
    void processDeferredFrees();
#if ECO_HEAP_VALIDATE
    // IM4: the target cell's bit is clear before an in-cycle allocation sets it.
    void assertCellWasWhite(BlockId id, const void* obj) const;
    // IM4: logs an in-cycle allocation and asserts its bit is set.
    void noteCycleAllocation(void* obj);
    // IM6: uniform-block consistency during a cycle (equality when `exact`).
    void validateCycleUniformLive(const char* where, bool exact) const;
    // IM5: every t0 block (id, generation, start, size_class, is_large),
    // re-checked at the handoff. CR-036: the key includes the id's BlockTable
    // generation, so a same-id, same-start re-issue is caught.
    struct T0Block { uint32_t id; uint32_t gen; char* start; size_t size_class; bool is_large; };
    std::vector<T0Block> t0Blocks() const;
    // nullptr when every t0 block is unchanged; else the IM5 message (and the
    // block's t0 start in *where).
    const char* t0BlocksChangedWhy(char** where = nullptr) const;
    void checkT0BlocksUnchanged() const;
    std::vector<T0Block> cycle_t0_blocks_;
    bool test_im5_ignore_gen_ = false;   // CR-036 negative control: IM5 without the generation
    // IM1/IM2 hooks, run by ThreadLocalHeap with an independent tracer.
    void assertAllMarked(const std::vector<void*>& objs, const char* what) const;
    std::vector<void*> cycle_t0_reach_;     // IM1: old objects reached at t0
    std::vector<void*> cycle_alloc_log_;    // IM4: in-cycle allocations
#endif
    // Test hooks for the negative controls (P§3.13).
    bool test_skip_allocate_black_ = false;
    bool test_keep_worker_cursor_ = false;    // threaded-gc-06 PM4 negative control
    bool test_idle_uncounted_ = false;        // CR-018 (HEAP_073) negative control: Idle allocations skip live_bytes

    // threaded-gc-05a cycle state (HEAP_063).
    CycleState cycle_state_ = CycleState::Idle;
    bool     snapshot_mode_ = false;
    bool     in_slice_ = false;
    bool     cycle_tail_uses_traced_live_ = false;
    uint32_t cycle_slices_ = 0;       // T, fixed at t0
    uint32_t cycle_k_ = 0;            // minor ends since t0
    uint64_t cycle_predicted_ = 0;    // predicted units, fixed at t0
    uint64_t cycle_units_ = 0;        // old-gen units marked this cycle
    uint64_t prev_cycle_units_ = 0;   // carried across cycles
    size_t   prev_cycle_occ_t0_ = 0;  // occupancy at the previous cycle's t0
    size_t   cycle_traced_live_ = 0;  // accumulator sum at the handoff
    size_t   cycle_black_bytes_ = 0;  // allocated black this cycle (handoff)
    size_t   baseline_black_bytes_ = 0;  // excluded from the trigger baseline until the next major
    std::vector<LargeBodyMeta> deferred_frees_;   // P§3.7

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
    // TLA-REGION(OGH.hasPendingSweepWork) begin
    bool hasPendingSweepWork() const {
        return gc_phase_ == GCPhase::Sweeping && sweep_pending_blocks_ > 0;
    }
    // TLA-REGION(OGH.hasPendingSweepWork) end
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
    // from mark-derived live bytes. ShrinkPass::Light skips releases unless
    // current_heap > desired_heap * 1.5 — used at onSweepComplete to avoid
    // double-shrink churn after the heavy pass already ran post-mark.
    // ShrinkPass::Forced (the explicit release, HEAP_076) skips the
    // hysteresis, keeps the floor, and does nothing during a compaction, an
    // unfinished sweep or a mark cycle.
    enum class ShrinkPass : uint8_t { Heavy, Light, Forced };
    void maybeShrinkCapacity(size_t desired_heap_bytes,
                             ShrinkPass pass = ShrinkPass::Heavy);

    // ========== Page-index helpers (Step 1) ==========

    // Commits the page index through region_end_. Called after any
    // commit/grow that moves region_end_ forward (formerly
    // resizePageIndexForRegion).
    void resizePageIndexForRegion() { commitPageIndexThrough(regionEnd()); }

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
    // `owned` = false for kind 2 (old) entries, which are never nursery-owned.
    LargeBodyId registerLargeBody(void* body, size_t cell_size, bool is_large,
                                  bool minor_color, uint8_t kind = 0, bool owned = true);
    // The cell of a large object: an LOS block (plans/large-object-space.md D2;
    // granule-rounded footprint) when it fits one, else a huge-tier is_large
    // block. Returns the cell and its footprint; nullptr when the old gen is full.
    void* allocateTrackedCell(size_t total_size, size_t& cell_size, bool& is_large);

    // ---- plans/large-object-space.md D2: the LOS ----
    // Allocates `bytes` from the LOS pool (object pool unless `raw`), adding an
    // LOS block when none has room. nullptr when the old gen cannot grow.
    void* allocateLos(size_t bytes, bool raw, BlockId* block_out);
    // A header-less body cell (D4): raw LOS pool, else a raw huge-tier block.
    void* allocateRawCell(size_t total_size, size_t& cell_size, bool& is_large);
    // initObjectHeaderWithSize's mark-bit and live_bytes part, no header.
    void attributeNewCell(BlockId block_id, void* obj, size_t cell_bytes);

    // Acquires and materializes one LOS block of alloc_buffer_size.
    BlockId addLosBlock(bool raw);
    // At mark end (finalizeMetaAfterMark): frees every unmarked tracked LOS
    // entry and re-derives each LOS block's live_bytes from its used granules.
    void losSweepAtMarkEnd();
    // After the post-mark reclaim: releases empty LOS blocks beyond los_empty_keep.
    void losReleaseEmptyBlocks();
    // Frees an LOS cell's granules and its live accounting (no index work).
    void freeLosCell(BlockId id, void* cell, size_t cell_size);
#if ECO_HEAP_VALIDATE
    void validateLosTracking(const char* where) const;
#endif

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

    // TLA-REGION(OGH.markBitHelpers) begin
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

    // threaded-gc-05c (H1, HEAP_050): allocate-black on the non-cursor paths
    // during a cycle. A background marker may fetch_or other bits of the same
    // byte: a plain RMW here could erase its bit and the sweep would free a
    // live object. Relaxed: the RMW only has to be indivisible.
    void setMarkBitAtomic(BlockId id, const void* obj) {
        if (!id.valid()) return;
        if (blocks_.info(id).is_large) {
            std::atomic_ref<uint8_t>(blocks_.largeMark(id)).store(1, std::memory_order_relaxed);
            return;
        }
        size_t byte_index;
        uint8_t mask;
        markBitLocation(id, obj, &byte_index, &mask);
        if (byte_index >= mark_.len(id)) return;
        std::atomic_ref<uint8_t>(mark_.slot(id)[byte_index]).fetch_or(mask, std::memory_order_relaxed);
    }
    // threaded-gc-05c (H2): a mutator-side read of a mark byte a background
    // marker may be writing (validators).
    bool isMarkedInBlockRelaxed(BlockId id, const void* obj) const {
        if (!id.valid()) return false;
        if (blocks_.info(id).is_large) {
            return std::atomic_ref<uint8_t>(const_cast<OldGenSpace*>(this)->blocks_.largeMark(id))
                       .load(std::memory_order_relaxed) != 0;
        }
        size_t byte_index;
        uint8_t mask;
        markBitLocation(id, obj, &byte_index, &mask);
        if (byte_index >= mark_.len(id)) return false;
        return (std::atomic_ref<uint8_t>(const_cast<uint8_t&>(mark_.slot(id)[byte_index]))
                    .load(std::memory_order_relaxed) & mask) != 0;
    }
    // TLA-REGION(OGH.markBitHelpers) end

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
    // most HeapConfig::demote_live_fraction (default 0.3; 0.0 = never) of their
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
    // ---- threaded-gc-06 (promotion buffers, P§3.8) ----
    static BlockId partialQueueAt(const OldGenSpace& og, size_t cls, size_t k) {
        const auto& q = og.partial_[cls];
        const size_t i = og.partial_head_[cls] + k;
        return i < q.size() ? q[i] : NO_BLOCK_ID;
    }
    static BlockId blockOf(OldGenSpace& og, const void* p) { return og.blockIdFor(p); }
    static void setKeepWorkerCursor(OldGenSpace& og, bool on) { og.test_keep_worker_cursor_ = on; }
    // CR-001: the in-loop completion held onSweepComplete for the merge.
    static bool sweepCompleteDeferred(const OldGenSpace& og) { return og.sweep_complete_deferred_; }
    // CR-014 (register-fixes Step 0.3): lazySweep tail completions inside a parallel
    // promotion (stats builds; 0 otherwise). Proves the tail path once both paths defer.
    static uint64_t sweepTailInPromotion(const OldGenSpace& og) {
#if ENABLE_GC_STATS
        return og.alloc_stats_.bm.sweep_tail_in_promotion;
#else
        (void)og;
        return 0;
#endif
    }
    // CR-018 (register-fixes Step 0.3 / §3.2): negative-control hook; Idle allocations
    // skip their live_bytes add (the pre-fix behaviour of HEAP_073).
    static void setIdleUncounted(OldGenSpace& og, bool on) { og.test_idle_uncounted_ = on; }
    // CR-036 (register-fixes §3.5): the per-id BlockTable generation.
    static uint32_t blockGeneration(const OldGenSpace& og, BlockId id) { return og.blocks_.generation(id); }
#if ECO_HEAP_VALIDATE
    // CR-036: IM5's t0-block capture and check, callable outside a cycle.
    static void captureT0Blocks(OldGenSpace& og) {
        og.cycle_t0_blocks_ = og.t0Blocks();
        std::sort(og.cycle_t0_blocks_.begin(), og.cycle_t0_blocks_.end(),
                  [](const OldGenSpace::T0Block& x, const OldGenSpace::T0Block& y) { return x.id < y.id; });
    }
    static const char* t0BlocksChangedWhy(const OldGenSpace& og) { return og.t0BlocksChangedWhy(); }
    static void clearT0Blocks(OldGenSpace& og) { og.cycle_t0_blocks_.clear(); }
    static void setIm5IgnoreGeneration(OldGenSpace& og, bool on) { og.test_im5_ignore_gen_ = on; }
#endif
    // CR-007: try_lock probe of the promotion lock (a success is undone at once).
    static bool promoMuHeld(OldGenSpace& og) {
        if (!og.promo_mu_.try_lock()) return true;
        og.promo_mu_.unlock();
        return false;
    }
    // CR-012(a): the handoff trigger that reads old_gen_in_use_bytes_ unlocked.
    static bool cyclePressureFinishDue(const OldGenSpace& og) { return og.cyclePressureFinishDue(); }
    static size_t numBlocks(const OldGenSpace& og) { return og.blocks_.size(); }
    static uint64_t committedBytes(const OldGenSpace& og) { return og.getCommittedBytes(); }
    // FNV-1a over (block start, size class, alloc state, bitmap bytes) of every
    // block in position order: equal iff the two heaps' layouts are equal.
    static uint64_t layoutHash(OldGenSpace& og) {
        uint64_t h = 1469598103934665603ull;
        auto mix = [&](uint64_t v) { h ^= v; h *= 1099511628211ull; };
        for (size_t pos = 0; pos < og.blocks_.size(); ++pos) {
            const BlockId id = og.blocks_.idAt(pos);
            const BlockInfo& b = og.blocks_.info(id);
            mix(static_cast<uint64_t>(b.end_of_objects - b.start));
            mix(b.size_class); mix(b.is_large); mix(b.alloc_state);
            mix(og.blocks_.meta(id).live_bytes);
            if (!b.is_large) {
                const uint8_t* bits = og.mark_.slot(id);
                const size_t n = og.bitmapBytesForBlock(b);
                for (size_t i = 0; i < n; ++i) mix(bits[i]);
            }
        }
        return h;
    }
    // ---- threaded-gc-05c (HEAP_065) ----
    static unsigned concThreads(const OldGenSpace& og) { return og.conc_threads_; }
    static unsigned markSlots(const OldGenSpace& og) { return og.mark_slots_; }
    static OldGenSpace::BgEpisode bgEpisode(const OldGenSpace& og) { return og.bg_ep_; }
    static bool hasBgGang(const OldGenSpace& og) { return og.bg_ != nullptr; }
    static gc::GCBackgroundGang* bgGang(OldGenSpace& og) { return og.bg_.get(); }
    static bool bgFinishedApprox(const OldGenSpace& og) {
        return og.bg_ep_ == OldGenSpace::BgEpisode::Running && og.bg_->finishedApprox();
    }
    static void stopBackground(OldGenSpace& og) { og.stopBackground(); }
    static size_t slotDequeSize(const OldGenSpace& og, unsigned i) {
        return og.markers_[i]->deque.sizeApprox() + og.markers_[i]->stack.size();
    }
    static uint64_t cyclePredicted(const OldGenSpace& og) { return og.cycle_predicted_; }
    // ---- threaded-gc-05c Part B ----
    static void setPromoRate(OldGenSpace& og, int64_t v) { og.p_hat_ = v; }
    static void addOldAlloc(OldGenSpace& og, uint64_t b) { og.old_alloc_total_ += b; }
    static void setLiveRefs(OldGenSpace& og, size_t major_live, size_t prev_major_live,
                            size_t post_sweep) {
        og.major_live_ = major_live;
        og.prev_major_live_ = prev_major_live;
        og.post_sweep_live_bytes_ = post_sweep;
    }
    static size_t allocatedBytes(const OldGenSpace& og) { return og.allocated_bytes; }
    // ---- threaded-gc-05b (HEAP_064) ----
    static uint64_t runMarkers(OldGenSpace& og, int64_t budget) { return og.runMarkers(budget); }
    static bool markStackEmpty(const OldGenSpace& og) { return og.markStackEmpty(); }
    static uint64_t markLiveSum(const OldGenSpace& og) { return og.markLiveSum(); }
    static unsigned markThreads(const OldGenSpace& og) { return og.mark_threads_; }
    static bool markParallel(const OldGenSpace& og) { return og.mark_parallel_; }
    // ---- threaded-gc-05a (HEAP_063) ----
    static bool isMarked(OldGenSpace& og, const void* obj) {
        const BlockId id = og.contains(const_cast<void*>(obj)) ? og.blockIdFor(obj) : NO_BLOCK_ID;
        if (!id.valid()) return false;
        return og.blocks_.info(id).is_large ? og.blocks_.largeMark(id) != 0
                                            : og.isMarkedInBlock(id, obj);
    }
    static bool cycleActive(const OldGenSpace& og) { return og.cycleActive(); }
    static bool inUniformBlock(OldGenSpace& og, const void* obj) {
        const BlockId id = og.contains(const_cast<void*>(obj)) ? og.blockIdFor(obj) : NO_BLOCK_ID;
        if (!id.valid()) return false;
        const BlockInfo& b = og.blocks_.info(id);
        return !b.is_large && b.size_class < og.num_size_classes_;
    }
    static OldGenSpace::CycleState cycleState(const OldGenSpace& og) { return og.cycle_state_; }
    static uint64_t cycleUnits(const OldGenSpace& og) { return og.cycle_units_; }
    static uint64_t prevCycleUnits(const OldGenSpace& og) { return og.prev_cycle_units_; }
    static uint32_t cycleK(const OldGenSpace& og) { return og.cycle_k_; }
    static size_t deferredFrees(const OldGenSpace& og) { return og.deferred_frees_.size(); }
    static size_t majorLive(const OldGenSpace& og) { return og.major_live_; }
    static size_t postSweepLive(const OldGenSpace& og) { return og.post_sweep_live_bytes_; }
    static size_t cycleTracedLive(const OldGenSpace& og) { return og.cycle_traced_live_; }
    static GCPhase gcPhase(const OldGenSpace& og) { return og.gc_phase_; }
    static void setSkipAllocateBlack(OldGenSpace& og, bool on) { og.test_skip_allocate_black_ = on; }
    static OldGenSpace::MajorGCTriggerReason trigger(const OldGenSpace& og) {
        return og.evaluateMajorGCTrigger();
    }
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
    // threaded-gc-07: the tenure grant.
    static BlockId partialFront(const OldGenSpace& og, size_t cls) {
        return og.partial_head_[cls] < og.partial_[cls].size() ? og.partial_[cls][og.partial_head_[cls]]
                                                                : NO_BLOCK_ID;
    }
    static std::vector<BlockId> partialQueue(const OldGenSpace& og, size_t cls) {
        return std::vector<BlockId>(og.partial_[cls].begin() + static_cast<std::ptrdiff_t>(og.partial_head_[cls]),
                                    og.partial_[cls].end());
    }
    static void lightShrink(OldGenSpace& og, size_t desired) {
        og.maybeShrinkCapacity(desired, OldGenSpace::ShrinkPass::Light);
    }
    static void* allocFromEmptyRegular(OldGenSpace& og, size_t size) { return og.allocateFromEmptyRegularBlocks(size); }
    static bool blockLive(const OldGenSpace& og, BlockId id) { return og.blocks_.isLive(id); }
    static constexpr uint8_t kAllocTenure = OldGenSpace::kAllocTenure;
    static uint32_t cellsIn(const OldGenSpace& og, BlockId id) { return OldGenSpace::cellsIn(og.blocks_.info(id)); }
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
