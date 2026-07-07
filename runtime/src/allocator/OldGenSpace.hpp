#ifndef ECO_OLDGENSPACE_H
#define ECO_OLDGENSPACE_H

#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>
#include "AllocatorCommon.hpp"
#include "RootSet.hpp"
#include "GCStats.hpp"

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
    // Uniform→mixed demotion: blocks whose live_bytes <= 50% of total at the
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
//     compact 4-byte CellHandle back-link in the size-class list and
//     16-bit per-block offsets, so removeFreeCellsForBlock can walk only
//     this block's cells and unlink each in O(1) from both threads.
//
// `prev_in_class` is a CellHandle (4 B): {block_index, cell_offset_8}.
// HEAD_SENTINEL == 0xFFFF in block_index marks the cell as the current
// head of its size-class list (no predecessor cell exists; the slot is
// `&free_lists_[cls]`).
//
// `next_in_block` / `prev_in_block` are 16-bit offsets, encoded as
// (cell_addr - block.start) / 8. FREE_CELLS_EMPTY == 0xFFFF marks the
// chain end.
//
// Bounds:
//   * block_index in [0, 0xFFFE]: max 65,535 blocks. With 24 GB max heap
//     and 512 KiB pages this is 49,152 — comfortably within range.
//   * cell_offset_8 in [0, 0xFFFF]: max byte offset 524,280 ⇒ block byte
//     size ≤ 524,288 (= 512 KiB). Enforced at OldGenSpace::initialize.
struct FreeCell;

static constexpr uint16_t FREE_CELLS_EMPTY = 0xFFFF;
static constexpr uint16_t HEAD_SENTINEL    = 0xFFFF;

// Forward decl so CellHandle::resolve can name BlockInfo.
struct BlockInfo;

// 4-byte compact reference to a free cell.
//   block_index == HEAD_SENTINEL  ⇒ cell is current head of its class list
//                                   (no predecessor cell; slot = &free_lists_[cls])
//   otherwise  ⇒ cell lives at  blocks[block_index].start + cell_offset_8 * 8
struct CellHandle {
    uint16_t block_index;
    uint16_t cell_offset_8;

    static CellHandle head() { return {HEAD_SENTINEL, 0}; }
    bool isHead() const { return block_index == HEAD_SENTINEL; }
};
static_assert(sizeof(CellHandle) == 4, "CellHandle must be 4 bytes");

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
    CellHandle prev_in_class;   // 4 B   compact back-link in the size-class list
    uint16_t   next_in_block;   // 2 B   offset/8 within block; FREE_CELLS_EMPTY = end
    uint16_t   prev_in_block;   // 2 B   offset/8 within block; FREE_CELLS_EMPTY = head
};
static_assert(sizeof(FreeCellMid) == 24, "Tier-M FreeCellMid must be 24 bytes");
static_assert(offsetof(FreeCell,    next_in_class) ==
              offsetof(FreeCellMid, next_in_class),
              "FreeCell and FreeCellMid must share next_in_class offset");

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

// ============================================================================
// Block Info Structure
// ============================================================================

// Tracks a page (or large block) currently materialized in `blocks_`. A page
// enters `blocks_` only once it has been pulled from `unassigned_blocks_` and
// either populated for a size class or wrapped as a single splittable cell.
struct BlockInfo {
    char* start;            // Start of the page/block (inclusive).
    char* end;              // End of the page/block (exclusive).
    char* end_of_objects;   // Sweep watermark: parse [start, end_of_objects).
    size_t size_class;      // Advisory: preferred class for this page (or
                            // NUM_SIZE_CLASSES if mixed/large).
    bool is_large;          // True for dedicated large-object (pinned) blocks.

    // Head (16-bit offset/8 from `start`) of this block's intrusive Tier-M
    // free-cell thread. Tier-S (class 1) cells are NOT in this thread.
    // FREE_CELLS_EMPTY (0xFFFF) when no Tier-M cells from this block are
    // currently linked. Stored as an offset (not a pointer) so the thread is
    // independent of `std::vector<BlockInfo>` reallocation.
    uint16_t free_cells_in_block = FREE_CELLS_EMPTY;

    size_t totalBytes() const { return static_cast<size_t>(end - start); }
};

// ============================================================================
// Per-Block Metadata
// ============================================================================

// Tracks per-block statistics for compaction decisions.
struct BufferMetadata {
    size_t block_index;     // Index into blocks_ vector.
    size_t live_bytes;      // Live object bytes (computed during sweep).
    size_t garbage_bytes;   // Garbage bytes (computed during sweep).
    bool fully_swept;       // True when this block has been fully swept.
};

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
class OldGenSpaceTestAccess;

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
 * Thread-local (one instance per thread).
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

#if ENABLE_GC_STATS
    // Returns the per-allocation stats accumulated by this old gen. Only the
    // allocation-size histogram is populated here; major-GC counters are
    // recorded against the ThreadLocalHeap's stats via passed references.
    GCStats& getStats() { return alloc_stats_; }
    const GCStats& getStats() const { return alloc_stats_; }
#endif

    // Up to two owning blocks_ indices per page slot. Two are required because
    // non-page-aligned block extents (e.g. a 512 KiB large block whose start
    // is not page-aligned) can intersect the same slot as a sibling block; a
    // single-owner table would lose one. For ordinary one-page blocks the
    // secondary owner stays NO_BLOCK.
    struct PageOwners {
        size_t primary;
        size_t secondary;
    };

private:
    // ========== Configuration ==========

    const HeapConfig* config_;    // Heap configuration parameters.
    Allocator* allocator_;        // Back-reference for acquiring buffers.

    // Runtime number of size classes; depends on `large_object_threshold`.
    // Always satisfies NUM_SMALL_CLASSES <= num_size_classes_ <= NUM_SIZE_CLASSES.
    size_t num_size_classes_;

    // ========== Block Management ==========

    std::vector<BlockInfo> blocks_;        // Pages currently in use.
    size_t allocated_bytes;                // Total bytes currently allocated.

    // Snapshot of `allocated_bytes` taken right after each major GC's sweep
    // completes (computeFragmentationStats sets it to live_bytes there). The
    // garbage-fraction trigger uses this as the baseline against which to
    // measure post-major mutator allocation, so the threshold expresses
    // "allocated since last major" rather than "currently held".
    size_t post_sweep_live_bytes_ = 0;

#if ENABLE_GC_STATS
    // Records the allocation-size histogram for this old gen. Combined with
    // ThreadLocalHeap's GCStats by Allocator::getCombinedStats().
    GCStats alloc_stats_;
#endif

    // Bag of pre-committed-but-unassigned pages (start, end). Each entry is
    // a page of `alloc_buffer_size` bytes carved from the initial region or
    // a post-GC capacity grow.
    std::vector<std::pair<char*, char*>> unassigned_blocks_;

    // Cached bounds for O(1) membership checks (updated when blocks change).
    char* region_base_;                    // Start of old gen region.
    char* region_end_;                     // End of committed old gen region.

    // Page slot (= (p - region_base_) / alloc_buffer_size) → up to two
    // owning blocks_ indices (see PageOwners above). Sized to
    // ceil(committed / alloc_buffer_size) and grown alongside region_end_;
    // bag pages and just-released pages hold {NO_BLOCK, NO_BLOCK}.
    std::vector<PageOwners> page_to_block_index_;

    // Recomputes region_base_/region_end_ from blocks_ + unassigned_blocks_
    // and rebuilds page_to_block_index_ from scratch. Called after any path
    // that releases or reshapes the address range (post-mark shrink, all-dead
    // reclaim, single-block release tail, compaction free pass) so the
    // page-index slots line up with the new region geometry. The initial
    // setup paths (initialize / reset) populate the index incrementally as
    // blocks are added and don't need this call.
    void recomputeRegionBoundsAndRebuildIndex();

    // Resets every page_to_block_index_ slot to {NO_BLOCK, NO_BLOCK} and
    // re-runs assignPageIndexForBlock for every block in blocks_. Cheap when
    // blocks_ is small relative to the slot count.
    void rebuildPageIndexFromBlocks();

    // Walks the page slots covered by blocks_[new_idx] and rewrites every
    // owner field that currently holds `old_idx` to point at `new_idx`. Used
    // by releaseBlockToAllocator's swap-remove tail: when blocks_[last] is
    // moved into block_index, slots that referred to `last` (the now-stale
    // index) must be retargeted to `block_index` (the new home of the same
    // BlockInfo). Without this, stale owner entries linger in the table —
    // inert against blockIndexFor (which screens via idx < blocks_.size())
    // but blocking future assignments at the same slot.
    void renamePageIndexSlots(size_t old_idx, size_t new_idx);

    // ========== GC State Machine ==========

    GCPhase gc_phase_;                // Current GC phase (Idle, Marking, or Sweeping).

    // ========== Marking State ==========

    // Each entry on the mark stack pairs an object with the blocks_ index
    // that owns it (NO_BLOCK_U32 for nursery objects and any stale entry
    // pointing at a since-released block). Caching the index on push avoids a
    // second blockIndexFor call when markOneObject attributes the object's
    // walkStep-aligned size to buffer_meta_[idx].live_bytes. uint32_t keeps
    // the entry packed at 16 bytes; CellHandle's 16-bit block_index already
    // bounds blocks_ at 65,535, well within range.
    static constexpr uint32_t NO_BLOCK_U32 = static_cast<uint32_t>(-1);
    struct MarkStackEntry {
        void* obj;
        uint32_t block_index;
    };
    static_assert(sizeof(MarkStackEntry) == 16,
                  "MarkStackEntry must pack to 16 bytes");

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
    std::vector<BufferMetadata> buffer_meta_;  // Per-block metadata for compaction.

    // Number of blocks that still need sweeping in the current GC cycle.
    // Initialised in finishMarkAndSweep AFTER reclaimAllDeadBlocksFromMeta has
    // removed all-dead blocks from buffer_meta_; decremented by
    // markBlockFullySwept whenever a block transitions to fully_swept;
    // zeroed in onSweepComplete and on reset/ctor. Drives the
    // sweep-before-grow gate in allocateFromSizeClass.
    size_t sweep_pending_blocks_;

    // Total in-cycle blocks (i.e. eligible to be swept this cycle) used as
    // the denominator for the unswept-fraction boost in
    // `computeSweepBudgetForAlloc`. Counts entries in `buffer_meta_` with
    // `!fully_swept && garbage_bytes > 0` at sweep entry, so it excludes
    // mid-cycle blocks pre-marked as fully_swept that would otherwise
    // dilute the ratio. Set in `recomputeSweepPendingBlocks` and zeroed in
    // `onSweepComplete` / reset / ctor.
    size_t sweep_total_blocks_;

    // ========== Per-Block Mark Bitmaps ==========
    //
    // Liveness for old-gen objects is tracked in per-block bitmaps (1 bit per
    // 8-byte slot). Headers retain a `color` field for compaction's debug
    // asserts but are NOT load-bearing for sweep liveness. mark_bits_[i]
    // covers regular blocks; large_block_mark_[i] is a single-bit
    // live/dead flag for is_large blocks (their mark_bits_[i] stays empty).
    // Invariant: mark_bits_.size() == large_block_mark_.size() == blocks_.size().
    std::vector<std::vector<uint8_t>> mark_bits_;
    std::vector<uint8_t>              large_block_mark_;

    // ========== Fragmentation Statistics ==========

    FragmentationStats frag_stats_;   // Heap-wide fragmentation stats (updated after sweep).

    // ========== Compaction State ==========

    CompactionPhase compact_phase_;           // Current compaction phase (Idle, Evacuating, or FixingRefs).
    std::vector<size_t> evacuation_set_;      // Block indices selected for evacuation.
    size_t current_evac_index_;               // Index within evacuation_set_ being processed.
    char* evac_cursor_;                       // Position within current evacuation block.
    size_t evac_block_index_;                 // Destination block for evacuation bump-allocation.
    char* evac_alloc_ptr_;                    // Bump pointer within evacuation destination block.
    size_t fixup_buffer_index_;               // Block index for reference fixup pass.
    char* fixup_cursor_;                      // Position within current fixup block.

    // ========== Free Lists ==========

    // Segregated free lists indexed by size class.
    // Each list contains free cells of size classToSize(i).
    FreeCell* free_lists_[NUM_SIZE_CLASSES];

    // Indices into `blocks_` of large/pinned blocks whose single object died
    // in the most recent sweep. `allocateLargeBlock` consults this list
    // before asking the Allocator for a fresh block.
    std::vector<size_t> free_large_blocks_;

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
    };

private:
    std::vector<LargeBodyMeta>             large_bodies_;
    std::unordered_map<void*, LargeBodyId> large_body_index_;
    std::vector<LargeBodyId>               nursery_owned_bodies_;
    std::vector<LargeBodyId>               free_large_body_ids_;

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
    void onUniformBlockDedicated(size_t block_index);

    // Debits the given block's totalBytes() from small_class_bytes_ if it
    // was a uniform small-class page. Called from any path that drops a
    // block from blocks_.
    void onBlockReleased(size_t block_index);

    // Same as onBlockReleased but used for in-place transitions to is_large
    // (no swap-remove). See allocateFromEmptyRegularBlocks.
    void onBlockTransitioningToLarge(size_t block_index);

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
    void lazySweep(size_t target_class, size_t work_budget);
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

    // Recomputes sweep_pending_blocks_ from buffer_meta_. Called once per
    // major-GC cycle from finishMarkAndSweep, AFTER all-dead reclaim and
    // BEFORE the initial lazy-sweep slice runs.
    void recomputeSweepPendingBlocks();

    // Centralised "this block is fully swept" mutation: sets the flag and
    // decrements sweep_pending_blocks_ if the transition is fresh.
    void markBlockFullySwept(size_t block_index);

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
    std::vector<size_t> selectEvacuationSet(size_t max_live_to_move);
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
    bool isInEvacuationSet(size_t buffer_index) const;
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
        for (const auto& block : blocks_) {
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

    // Marks `blocks_[idx]` (an `is_large` block whose single object died) as
    // available for reuse via `allocateFromFreeLargeBlocks`. Asserts that
    // the block is not already on the list.
    void markBlockAsFreeLarge(size_t block_index);

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
    void releaseBlockToAllocator(size_t block_index);

    // Releases an unassigned bag-page extent back to the Allocator. These
    // pages were never materialized into `blocks_`, so this is just an
    // Allocator round-trip plus a swap-remove from `unassigned_blocks_`.
    void releaseUnassignedBlockToAllocator(size_t unassigned_index);

    // Removes any FreeCell that lies inside `[blocks_[idx].start, ...end)`
    // from every per-class free list. Called before releasing a block so
    // its embedded free cells don't leave dangling free-list pointers.
    void removeFreeCellsForBlock(size_t block_index);

    // Patches indices stored in BufferMetadata, evacuation_set_,
    // evac_block_index_, sweep_buffer_index_, fixup_buffer_index_, and
    // free_large_blocks_ when blocks_ has had a swap-remove move the
    // last-index entry to old_idx. Called by releaseBlockToAllocator.
    void fixupIndicesAfterBlockMove(size_t old_idx, size_t new_idx);

    // Inspects post-mark live/heap and, if heap is well above the desired
    // capacity, releases fully-free pages until heap ≈ desired_heap_bytes.
    // The caller (adjustCapacityAfterMajorGC) computes desired_heap_bytes
    // from mark-derived live bytes. `light_pass=true` skips releases unless
    // current_heap > desired_heap * 1.5 — used at onSweepComplete to avoid
    // double-shrink churn after the heavy pass already ran post-mark.
    void maybeShrinkCapacity(size_t desired_heap_bytes,
                             bool light_pass = false);

    // ========== Page-index helpers (Step 1) ==========

    // Resizes page_to_block_index_ to cover [region_base_, region_end_).
    // Newly-added slots are filled with NO_BLOCK. Called after any commit/grow
    // that moves region_end_ forward.
    void resizePageIndexForRegion();

    // Returns the first / last page slot the block covers, or SIZE_MAX if
    // region_base_ is not set / the block lies outside the indexed region.
    size_t firstPageIndex(const BlockInfo& block) const;
    size_t lastPageIndex(const BlockInfo& block) const;

    // Writes `block_index` into every page_to_block_index_ slot the block's
    // extent covers. Used when a block enters blocks_.
    void assignPageIndexForBlock(size_t block_index);

    // Clears every page_to_block_index_ slot the block's extent covers
    // back to NO_BLOCK. Used immediately before a block leaves blocks_.
    void clearPageIndexForBlock(size_t block_index);

    // Returns the blocks_ index of the block containing `obj`, or
    // blocks_.size() if `obj` lies outside the committed region or no block
    // currently owns its page. O(1) when the page index is hot; falls back to
    // a linear scan if the slot is NO_BLOCK (defensive).
    size_t blockIndexFor(const void* obj) const;

    // ========== Split-Header Body Helpers ==========

    // Records a freshly-allocated body in tracking. Reuses a tombstone id from
    // free_large_body_ids_ when present.
    LargeBodyId registerLargeBody(void* body, size_t cell_size, bool is_large,
                                  bool minor_color);

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
    // block_index. Caller is responsible for routing is_large blocks to
    // large_block_mark_ instead of calling this.
    void markBitLocation(size_t block_index, const void* obj,
                         size_t* byte_index, uint8_t* mask) const {
        const BlockInfo& block = blocks_[block_index];
        const char* p = static_cast<const char*>(obj);
        const size_t offset = static_cast<size_t>(p - block.start);
        const size_t slot = offset / MARK_ALIGNMENT;
        *byte_index = slot / 8;
        *mask = static_cast<uint8_t>(1u << (slot & 7));
    }

    bool isMarkedInBlock(size_t block_index, const void* obj) const {
        if (block_index >= blocks_.size()) return false;
        if (blocks_[block_index].is_large) {
            return large_block_mark_[block_index] != 0;
        }
        size_t byte_index;
        uint8_t mask;
        markBitLocation(block_index, obj, &byte_index, &mask);
        const auto& bits = mark_bits_[block_index];
        if (byte_index >= bits.size()) return false;
        return (bits[byte_index] & mask) != 0;
    }

    // Sets the bit for `obj` and returns true if the bit was previously
    // unset (i.e. this caller observed the white→grey transition).
    bool setMarkBitInBlock(size_t block_index, const void* obj) {
        if (block_index >= blocks_.size()) return false;
        if (blocks_[block_index].is_large) {
            uint8_t prev = large_block_mark_[block_index];
            large_block_mark_[block_index] = 1;
            return prev == 0;
        }
        size_t byte_index;
        uint8_t mask;
        markBitLocation(block_index, obj, &byte_index, &mask);
        auto& bits = mark_bits_[block_index];
        if (byte_index >= bits.size()) return false;
        const bool was_set = (bits[byte_index] & mask) != 0;
        bits[byte_index] |= mask;
        return !was_set;
    }

    // Tests the bit for `obj`, clears it, and returns whether it was set.
    // Used by sweep so that the bitmap is left all-zero post-sweep
    // (precondition for the next mark cycle to skip bulk-zeroing).
    bool testAndClearMarkBitInBlock(size_t block_index, const void* obj) {
        if (block_index >= blocks_.size()) return false;
        if (blocks_[block_index].is_large) {
            uint8_t prev = large_block_mark_[block_index];
            large_block_mark_[block_index] = 0;
            return prev != 0;
        }
        size_t byte_index;
        uint8_t mask;
        markBitLocation(block_index, obj, &byte_index, &mask);
        auto& bits = mark_bits_[block_index];
        if (byte_index >= bits.size()) return false;
        const bool was_set = (bits[byte_index] & mask) != 0;
        bits[byte_index] &= static_cast<uint8_t>(~mask);
        return was_set;
    }

    // ========== Mark-time live-bytes attribution (Step 2) ==========

    // Performs the White → Grey → Black transition on `obj`, recursively
    // pushes children via markChildren, and attributes the object's
    // walkStep-aligned size to buffer_meta_[block_index].live_bytes.
    // Skips Tag_Free and already-Black objects. For nursery objects, only
    // calls markChildren — major GC must not write into nursery headers and
    // nursery cells aren't tracked in buffer_meta_. Returns true if the
    // object did real work (popped one work unit).
    //
    // The two-arg form takes the cached `block_index` produced by
    // pushMarkRoot so the hot path skips a redundant blockIndexFor lookup
    // (NO_BLOCK_U32 means "unknown / nursery"). The one-arg wrapper looks
    // up the index itself; only cold callers (lazy-sweep adjacency) use it.
    bool markOneObject(void* obj, uint32_t block_index);
    bool markOneObject(void* obj);

    // O(#blocks) reset of buffer_meta_ to match blocks_, called at major-GC
    // start so live_bytes attribution can begin from zero.
    void resetBufferMetaForMark();

    // Demotes uniform size-class blocks whose mark-derived live_bytes is at
    // most half of their total bytes to mixed (`size_class = NUM_SIZE_CLASSES`).
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

    // Walks buffer_meta_ back-to-front and releases every non-large block
    // whose live_bytes == 0 via releaseBlockToAllocator. Brackets the loop
    // with g_batch_release_depth and recomputes region_base_/region_end_
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

    friend class Allocator;
    friend class NurserySpace;
    friend class ThreadLocalHeap;
    friend class OldGenSpaceTestAccess;
};

// ============================================================================
// Test Access Helper
// ============================================================================

// For test code only - provides privileged access to OldGenSpace internals.
class OldGenSpaceTestAccess {
public:
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
    static FreeCell* getFreeList(const OldGenSpace& oldgen, size_t cls) {
        assert(cls < NUM_SIZE_CLASSES && "getFreeList: invalid size class (>= NUM_SIZE_CLASSES)");
        return oldgen.free_lists_[cls];
    }

    // Block metadata.
    static const std::vector<BufferMetadata>& getBufferMeta(const OldGenSpace& oldgen) {
        return oldgen.buffer_meta_;
    }
    static const std::vector<BlockInfo>& getBlocks(const OldGenSpace& oldgen) {
        return oldgen.blocks_;
    }
    static const std::vector<std::pair<char*, char*>>& getUnassignedBlocks(
            const OldGenSpace& oldgen) {
        return oldgen.unassigned_blocks_;
    }
    static const std::vector<size_t>& getFreeLargeBlocks(
            const OldGenSpace& oldgen) {
        return oldgen.free_large_blocks_;
    }

    // Manual control of lazy sweeping for testing.
    static void transitionToSweeping(OldGenSpace& oldgen) { oldgen.transitionToSweeping(); }
    static void lazySweep(OldGenSpace& oldgen, size_t target_class, size_t work_budget) {
        oldgen.lazySweep(target_class, work_budget);
    }

    // Page-index access for tests (Step 1).
    static size_t blockIndexFor(const OldGenSpace& oldgen, const void* obj) {
        return oldgen.blockIndexFor(obj);
    }
    static const std::vector<OldGenSpace::PageOwners>& getPageToBlockIndex(
            const OldGenSpace& oldgen) {
        return oldgen.page_to_block_index_;
    }

    // Per-block mark bitmap access for tests.
    static const std::vector<uint8_t>& getMarkBitsForBlock(
            const OldGenSpace& oldgen, size_t i) {
        return oldgen.mark_bits_[i];
    }
    static const std::vector<std::vector<uint8_t>>& getMarkBits(
            const OldGenSpace& oldgen) {
        return oldgen.mark_bits_;
    }
    static const std::vector<uint8_t>& getLargeBlockMark(
            const OldGenSpace& oldgen) {
        return oldgen.large_block_mark_;
    }
    static bool isObjectMarked(const OldGenSpace& oldgen, void* obj) {
        if (!oldgen.contains(obj)) return false;
        size_t i = oldgen.blockIndexFor(obj);
        if (i >= oldgen.blocks_.size()) return false;
        return oldgen.isMarkedInBlock(i, obj);
    }
    static bool setObjectMark(OldGenSpace& oldgen, void* obj) {
        if (!oldgen.contains(obj)) return false;
        size_t i = oldgen.blockIndexFor(obj);
        if (i >= oldgen.blocks_.size()) return false;
        return oldgen.setMarkBitInBlock(i, obj);
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
    static const std::vector<size_t>& getEvacuationSet(const OldGenSpace& oldgen) {
        return oldgen.evacuation_set_;
    }
    static void* getForwardingAddress(const OldGenSpace& oldgen, void* obj) {
        return oldgen.getForwardingAddress(obj);
    }
};

} // namespace Elm

#endif // ECO_OLDGENSPACE_H
