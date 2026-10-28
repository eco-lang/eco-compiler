#ifndef ECO_OLDGENSPACE_H
#define ECO_OLDGENSPACE_H

// One heap's old generation: where objects that survive the nursery are promoted, and where objects
// that are too large for the nursery are allocated directly.
//
// An old-generation object is never moved by a collection. (The one exception is compaction, which
// only unit tests start.) So the old generation is collected by marking what is reachable and then
// reclaiming the rest in place, and it is a free-space allocator rather than a bump allocator.
// Everything in this file follows from that, and from a second fact: one old generation is entered
// by several threads, not only by the mutator that owns it. Parallel minor-GC workers promote into
// it, tenure collectors copy into blocks granted to them, and markers trace it, some of them while
// the mutator runs. Most of the class is machinery for those threads.
//
// Memory is divided into *blocks*, whose metadata `BlockTable.hpp` owns. A block is one of these:
//
//   * a *uniform* block: one page of `alloc_buffer_size` bytes divided into equal cells of one size
//     class;
//   * a *mixed* block: a page whose cells differ in size, either a page taken whole for one request
//     and then split, or a uniform block *demoted* after most of it died;
//   * a *large* block (`is_large`), which holds one object of a page or more;
//   * an *LOS block*, which holds many large objects placed by `LargeObjectSpace`.
//
// Pages committed from the `Allocator` but not yet made into blocks wait in the *bag of pages*.
//
// A *size class* is a cell size. Classes 0 to 31 are 8 to 256 bytes in steps of 8; the classes above
// are powers of two from 512 bytes up to the largest that does not exceed the large-object threshold.
// `HeapConfig::old_gen_bitmap_alloc` chooses between two ways of finding a free cell:
//
//   * In *bitmap mode* a uniform block's mark bitmap is also its allocation map: a set bit at a
//     cell's first slot means the cell is in use. Each class has a *cursor* that scans one block's
//     bitmap for clear cells, and a FIFO queue of the other uniform blocks that have free cells.
//   * Otherwise, and in bitmap mode for mixed blocks, free space is kept as free cells on per-class
//     free lists, which the sweep rebuilds.
//
// Liveness is one mark bit per 8-byte slot of a block, or one mark byte for a large block. Marking
// sets the bit of every object it reaches, and the sweep keeps exactly the objects whose bit is set.
// A major collection marks in one of two ways:
//
//   * stop-the-world, inside one pause (`startMark`, then `finishMarkAndSweep`);
//   * as a *mark cycle*, spread over several minor collections. The pause that starts it is *t0*,
//     and the cycle marks what was reachable at t0, the *snapshot*. The pause that ends it is the
//     *handoff*. Between them, mark work is done in slices at the end of minor collections, or,
//     in the concurrent mode, by *background markers* that run between pauses in *episodes* the
//     mutator launches and joins. A foreground gang may *assist* a running episode inside a pause.
//
// Two rules make a mark cycle safe without a write barrier. First, an object allocated after t0 is
// *allocated black*: its mark bit is set when it is allocated, so the sweep keeps it. Second, nothing
// that existed at t0 is freed while the cycle runs: a free that falls inside the cycle is deferred
// to the handoff. Mark bits written by a background marker, and the work it leaves behind, become
// visible to the mutator through the join of the background gang, not before.
//
// After a mark, most blocks with no live bytes are released (down to a floor), uniform blocks with
// free cells are queued for reuse, and mixed blocks are swept *lazily*: a bounded amount at a time,
// driven by allocation, until every block that needs it has been swept.
//

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

/// Where the old generation is in a major collection, as allocation and the sweep see it.
///
/// `Marking` is set only by a mark cycle, from t0 until the handoff. A stop-the-world mark leaves the
/// phase alone. `Sweeping` lasts from the end of a mark until the lazy sweep has finished.
enum class GCPhase {
    Idle,
    Marking,
    Sweeping
};

/// Timings and counts for one major collection, filled in by the `finishMarkAndSweep`
/// overloads and the handoff that take one.
///
/// Nothing in this component writes `capacity_ns`, `shrink_blocks_released` or
/// `shrink_bytes_released`, so they stay 0. The mark fields are written only by the
/// `finishMarkAndSweep` overloads.
struct MajorGCPhaseProfile {
    uint64_t mark_ns        = 0;
    uint64_t sweep_ns       = 0;
    uint64_t capacity_ns    = 0;
    uint64_t mark_iterations = 0;  ///< Rounds of at most 1,000 mark units.
    uint64_t mark_units_done = 0;  ///< Mark units done by this collection.
    size_t   mark_stack_peak = 0;  ///< Largest grey-set size seen between rounds.
    size_t   blocks_scanned  = 0;  ///< Blocks left after the releases at the end of the mark.
    size_t   live_bytes_after = 0;
    size_t   garbage_bytes    = 0;
    size_t   shrink_blocks_released = 0;
    size_t   shrink_bytes_released  = 0;
    // Blocks with nothing live, released at the end of the mark without their cells being walked.
    size_t   alldead_blocks_released = 0;
    size_t   alldead_bytes_released  = 0;
    // Uniform blocks demoted to mixed at the end of the mark because at most
    // `HeapConfig::demote_live_fraction` of their bytes were live.
    size_t   demoted_blocks          = 0;
    size_t   demoted_bytes           = 0;
    // The sweep budget of the slice run at the end of the mark, and the blocks still unswept after it.
    size_t   initial_sweep_budget_bytes = 0;
    size_t   sweep_pending_blocks = 0;
};

struct FreeCell;

/// A span of free bytes inside a block, linked into the free list of one size class.
///
/// A free cell is a heap object with tag `Tag_Free` whose `header.size` is its size in bytes, so a
/// walk over a block steps over it like any other object. There are two layouts, which share their
/// first two fields:
///
///   * a 16-byte cell (class 1) is a `FreeCell` and has only the list link;
///   * a cell of 24 bytes or more is a `FreeCellMid`, which also links to its predecessor in the
///     class list and to its neighbours among the free cells of the same block, so that the cells of
///     one block can be removed from every list without walking the lists.
///
/// The cell is identified as the larger layout by its size (`MIN_TIER_M_SIZE`), and nothing else
/// records which layout it has.
struct FreeCell {
    Header     header;          ///< Tag `Tag_Free`; `size` is the cell size in bytes.
    FreeCell*  next_in_class;   ///< The next cell on the same class list, or null.
};
static_assert(sizeof(FreeCell) == 16, "Tier-S FreeCell must be 16 bytes");

/// The layout of a free cell of 24 bytes or more; see `FreeCell`.
///
/// The predecessor in the class list is stored as its address divided by 8, a 40-bit value: the low
/// 32 bits in `prev_lo` and the high 8 bits in bits 0-7 of this cell's `header.refcount`, which a
/// `Tag_Free` cell does not otherwise use. Bit 8 of `refcount` set means the cell is the head of its
/// list. Read and write the link only through `getPrev`, `setPrev`, `setPrevHead` and `copyPrev`.
///
/// `next_in_block` and `prev_in_block` are offsets from the block start divided by 8, with
/// `FREE_CELLS_EMPTY` meaning none. A 16-bit offset in 8-byte units reaches 512 KiB, which is why
/// `OldGenSpace::initialize` aborts when `alloc_buffer_size` is larger.
struct FreeCellMid {
    Header     header;
    FreeCell*  next_in_class;
    uint32_t   prev_lo;
    uint16_t   next_in_block;
    uint16_t   prev_in_block;
};
static_assert(sizeof(FreeCellMid) == 24, "Tier-M FreeCellMid must be 24 bytes");
static_assert(offsetof(FreeCell,    next_in_class) ==
              offsetof(FreeCellMid, next_in_class),
              "FreeCell and FreeCellMid must share next_in_class offset");

/// The bits of a free cell's `header.refcount` that hold the high 8 bits of its predecessor's
/// address divided by 8.
inline constexpr u32 kPrevHiMask  = 0xFFu;
/// The bit of a free cell's `header.refcount` that marks the head of its class list.
inline constexpr u32 kPrevHeadBit = 0x100u;
static_assert(POINTER_BITS == 40,
              "back-link encoding assumes heap addresses < 2^43");

/// Marks `m` as the head of its class list (no predecessor).
inline void setPrevHead(FreeCellMid* m) {
    m->header.refcount = kPrevHeadBit;
    m->prev_lo = 0;
}
/// Records `pred` as `m`'s predecessor in its class list. `pred` must be a heap address below 2^43.
inline void setPrev(FreeCellMid* m, const FreeCell* pred) {
    const uint64_t e = reinterpret_cast<uintptr_t>(pred) >> 3;
    m->prev_lo = static_cast<uint32_t>(e);
    m->header.refcount = static_cast<u32>(e >> 32) & kPrevHiMask;
}
/// Copies `src`'s predecessor link, head mark included, into `dst`.
inline void copyPrev(FreeCellMid* dst, const FreeCellMid* src) {
    dst->prev_lo = src->prev_lo;
    dst->header.refcount = src->header.refcount & (kPrevHiMask | kPrevHeadBit);
}
/// Returns `m`'s predecessor in its class list, or null if `m` is the head.
inline FreeCell* getPrev(const FreeCellMid* m) {
    if (m->header.refcount & kPrevHeadBit) return nullptr;
    const uint64_t e =
        (uint64_t(m->header.refcount & kPrevHiMask) << 32) | m->prev_lo;
    return reinterpret_cast<FreeCell*>(static_cast<uintptr_t>(e << 3));
}

/// The smallest free cell that can be linked into a free list: one of class 1.
static constexpr size_t MIN_FREE_CELL_SIZE = sizeof(FreeCell);
/// The smallest free cell with the `FreeCellMid` layout.
static constexpr size_t MIN_TIER_M_SIZE    = sizeof(FreeCellMid);

// A free cell's `header.age` bit 0, set, marks a cell that is already on a free list. The lazy sweep
// treats such a cell as the end of a run of garbage: it does not merge it with its neighbours, rewrite
// it, or follow its link. Bit 0 clear is an ordinary free cell the sweep may merge.
/// Returns whether `hdr` is a free cell marked as already on a free list.
inline bool isFreeCellSentinel(const Header* hdr) {
    return (hdr->tag == Tag_Free) && ((hdr->age & 0b01u) != 0);
}
/// Marks the free cell `hdr` as already on a free list. Clears bit 1 of `age`.
inline void setFreeCellSentinel(Header* hdr) {
    hdr->age = (hdr->age & ~0b11u) | 0b01u;
}
/// Clears the on-a-free-list mark of the free cell `hdr`, and bit 1 of `age`.
inline void clearFreeCellSentinel(Header* hdr) {
    hdr->age = (hdr->age & ~0b11u);
}

/// The old generation's occupancy, as last computed after a sweep finished.
///
/// The three fields are filled together by `OldGenSpace::computeFragmentationStats`, from every
/// block's metadata at that moment.
struct FragmentationStats {
    size_t total_free_bytes;    ///< Sum of the blocks' `garbage_bytes`.
    size_t live_bytes;          ///< Sum of the blocks' `live_bytes`.
    size_t heap_bytes;          ///< Sum of the blocks' `end_of_objects - start`.

    /// Returns `live_bytes / heap_bytes`, or 0 when `heap_bytes` is 0.
    float utilization() const {
        return heap_bytes > 0 ? static_cast<float>(live_bytes) / heap_bytes : 0.0f;
    }
};

/// The utilization below which `OldGenSpace::shouldCompact` reports that compaction would pay.
/// Nothing calls `shouldCompact`, and compaction is started only by unit tests.
static constexpr float UTILIZATION_THRESHOLD = 0.70f;

/// A utilization fraction that nothing in the runtime or its tests reads.
static constexpr float BUFFER_RETURN_THRESHOLD = 0.50f;

/// A tenth of the live bytes `scheduleCompaction` selects for evacuation, at most.
static constexpr size_t COMPACTION_WORK_BUDGET = 8192;

/// Where a compaction is. A compaction first evacuates the live objects of selected blocks
/// (`Evacuating`), leaving forwarding stubs behind, and then rewrites every reference to an evacuated
/// object (`FixingRefs`). Only unit tests start one.
enum class CompactionPhase {
    Idle,
    Evacuating,
    FixingRefs
};

class Allocator;
class NurserySpace;
class OldGenSpaceTestAccess;
namespace p1 { struct P1CensusAccess; }

/// Returns the address that `ptr` holds. It does not follow a forwarding pointer and does not change
/// `ptr`. `ptr` must not be an embedded constant; that is asserted.
void* readBarrier(HPointer& ptr);

/// The old generation of one heap: a non-moving, mark-and-sweep space with a segregated-fits
/// allocator, as the file comment describes.
///
/// An `OldGenSpace` is constructed empty and does nothing useful until `initialize` binds it to an
/// `Allocator` and a configuration. It owns its block metadata, its large-object space and its
/// background marking gang. It does not own the memory of its blocks, which belongs to the
/// `Allocator` and is handed back to it when a block is released. It can be neither copied nor moved
/// (it has atomic and `unique_ptr` members and a user-declared destructor).
///
/// The destructor stops and joins a running background episode before releasing the metadata.
class OldGenSpace {
public:
    /// The most parallel minor-GC workers `resolveMinorThreads` returns.
    static constexpr unsigned kMaxMinorWorkers = 64;
    /// The number of per-worker promotion states a `PromoCtx` holds.
    static constexpr unsigned kMaxPromoWorkers = kMaxMinorWorkers;
    /// Creates an empty old generation with marker slot 0 already created. Call `initialize` before
    /// anything else.
    OldGenSpace();
    ~OldGenSpace();

    // ========== Allocation ==========

    /// Allocates `size` bytes, rounded up to a multiple of 8, and returns the address, or null when
    /// no free space can be found and the old generation cannot grow.
    ///
    /// The object's first 8 bytes are a header that is zero apart from its colour; the caller writes
    /// the tag and size. The object is allocated black (see the file comment) when a mark is in
    /// progress or the phase is not `Idle`. A request of `alloc_buffer_size` or more gets a block of its
    /// own. While the phase is `Sweeping`, a call first does a slice of lazy-sweep work, a smaller
    /// slice (`HeapConfig::minor_sweep_divisor`) while a minor collection is in progress.
    void *allocate(size_t size);

    // ========== Large bodies and large objects ==========
    //
    // Every large object is recorded in an index keyed by its address, as a `LargeBodyMeta` of one of
    // three kinds: a *large body* (kind 0), the payload of a large String or Bytes whose header object
    // is still young; a *young large object* (kind 1, the YLOS), a pointer-bearing object too large
    // for the nursery that is collected with the young generation; and an *old large object*
    // (kind 2). Kinds 0 and 1 are *nursery-owned*: a minor collection frees one its colour shows
    // unreached. A kind 0 or 1 entry becomes kind 2 when its owner is promoted. A major collection
    // can free an entry of any kind that is unmarked at the end of its mark.

    /// Allocates the header-less payload of a large String or Bytes, `total_size` bytes rounded up to
    /// a multiple of 8, and records it as a nursery-owned large body with minor colour
    /// `initial_color`. Returns null when the old generation cannot grow.
    ///
    /// The payload has no header: its tag and length live in the header object that owns it. The
    /// memory is not initialised. `body_tag` must be `Tag_String` or `Tag_ByteBuffer` (asserted);
    /// it and `logical_size` are otherwise ignored.
    void* allocateLargeBody(size_t total_size, size_t logical_size,
                            Tag body_tag, bool initial_color);

    /// Allocates an object of `size` bytes (at least the large-object threshold), rounded up to a
    /// multiple of 8, writes its header for `tag` with `pin` set, and records it as an old large
    /// object (kind 2), which a major collection frees when it is unmarked. Returns null when the old
    /// generation cannot grow. An object that fits one LOS block is placed by `LargeObjectSpace`;
    /// a larger one gets a large block of its own.
    void* allocateOldLarge(size_t size, Tag tag);

    /// Returns the cell size of the largest size class this old generation uses.
    size_t largestUniformClassBytes() const { return classToSize(num_size_classes_ - 1); }

    /// Returns the large-object space that places large objects inside LOS blocks.
    const LargeObjectSpace& largeObjectSpace() const { return los_; }
    /// Returns whether block `id` is an LOS block. `id` must be a live block.
    bool isLosBlock(BlockId id) const { return (blocks_.info(id).los & kLosBlock) != 0; }
    /// Returns whether `p` lies in a block that holds header-less large bodies: an LOS block of the
    /// raw pool, or a large block holding one body.
    bool isRawBody(const void* p) const;

    /// Records that a minor collection with colour `minor_color` reached the header that owns the
    /// large body at `body_hp`. Does nothing unless `body_hp` is a large body (kind 0) in the index.
    void markLargeBodySeen(HPointer body_hp, bool minor_color);

    /// Records that the header owning the large body at `body_hp` has been promoted: the body stops
    /// being nursery-owned and becomes an old large object (kind 2). Does nothing if `body_hp` is not
    /// in the index.
    void promoteLargeHeader(HPointer body_hp);

    /// Frees every nursery-owned large body and young large object whose minor colour is not
    /// `minor_color`, that is, every one the minor collection just ended did not reach, and returns
    /// how many it freed.
    ///
    /// While a mark cycle runs, a dead cell is removed from the index at once but its memory is freed
    /// only at the handoff. While a compaction is in progress nothing is freed and 0 is returned.
    /// Otherwise the young large objects' bounding box (`mayBeYoungLarge`) is then recomputed.
    size_t sweepNurseryLargeBodies(bool minor_color);

    // ========== Queries ==========

    /// The sizes of the metadata tables `OldGenSpace` reserves for an old-generation reservation of
    /// `reservation_bytes` and blocks of `page` bytes. A block is at least one page and lies inside the
    /// reservation, so no more than `max_blocks` blocks can be live at once.
    struct OldGenGeometry {
        size_t max_blocks = 0;        ///< Block ids the block table and live-byte accumulators hold.
        size_t index_slots = 0;       ///< Slots of the page index.
        size_t stride = 0;            ///< Mark-bitmap bytes per block id, a multiple of 64.
        size_t mark_arena_bytes = 0;  ///< `max_blocks * stride`, the address space the mark bitmaps reserve.
    };
    /// Returns the table sizes for `reservation_bytes` and `page`; all zero when `page` is 0.
    static OldGenGeometry geometryFor(size_t reservation_bytes, size_t page);

    /// Binds the nursery of the same heap, which marking consults to tell young objects from old.
    /// `n` is kept and must outlive this object or be replaced first.
    void bindNursery(const NurserySpace* n) { nursery_ = n; }

    /// Records whether a minor collection of the same heap is in progress. While it is, `allocate`
    /// is a promotion and does less sweep work, and its time is not charged to the mutator.
    void setInMinorGC(bool v) { in_minor_gc_ = v; }

    /// Returns the bytes of cells allocated: added at every allocation, subtracted at some frees, and
    /// reset to the live bytes at the end of a mark and when a sweep finishes.
    size_t getAllocatedBytes() const { return allocated_bytes; }

    /// Returns the size of the address range this old generation's blocks and pages lie in.
    size_t getCommittedBytes() const {
        char* const base = regionBase();
        char* const end = regionEnd();
        return (end > base) ? static_cast<size_t>(end - base) : 0;
    }

    /// The major-collection trigger that fired. `evaluateMajorGCTrigger` checks `Occupancy`,
    /// `GlobalPressure`, `Headroom`, `GarbageFraction` and `LiveBudget`, in that order, and reports the
    /// first that holds. "Since the last major" means since the last sweep finished. The thresholds
    /// are `HeapConfig` fields.
    enum class MajorGCTriggerReason {
        /// No trigger holds, or a mark cycle is running.
        None,
        /// This old generation's allocated bytes over its committed bytes reached
        /// `major_gc_initiating_occupancy`.
        Occupancy,
        /// Every old generation's committed bytes over the old-generation cap reached
        /// `major_gc_global_pressure_fraction`.
        GlobalPressure,
        /// The bytes allocated since the last major, over the committed bytes, reached
        /// `major_gc_garbage_fraction` (raised to `major_gc_garbage_backstop` when the live budget is
        /// on). In bitmap mode the committed bytes are capped at `garbage_denom_cap` times those at the
        /// last major.
        GarbageFraction,
        /// The bytes allocated since the last major (plus those expected over one cycle, when paced)
        /// reached `major_gc_live_budget` times the last major's live bytes, the latter capped at
        /// `live_growth_bound` times the major before.
        LiveBudget,
        /// Every old generation's committed bytes, plus `major_gc_headroom_margin` times the bytes
        /// expected to be promoted over one mark cycle, reached `incremental_mark_finish_fraction` of
        /// the cap.
        Headroom,
    };
    /// Updates the promotion-rate estimate at the end of a minor collection: an integer moving
    /// average, with weight 1/8, of the old-generation bytes allocated per minor collection.
    void notePacingMinorEnd() {
        const int64_t sample = static_cast<int64_t>(old_alloc_total_ - old_alloc_at_prev_minor_);
        old_alloc_at_prev_minor_ = old_alloc_total_;
        p_hat_ += (sample - p_hat_) / 8;
    }
    /// Returns the promotion-rate estimate, in bytes per minor collection.
    int64_t promoRateEstimate() const { return p_hat_; }
    /// Returns the bytes ever allocated in this old generation. Only `reset` lowers it.
    uint64_t oldAllocTotal() const { return old_alloc_total_; }
    /// Returns the number of minor collections a mark cycle is expected to span: its slice count plus
    /// one, or 1 without incremental marking.
    uint64_t pacingHorizonMinors() const {
        return (config_->incremental_mark ? config_->incremental_mark_slices : 0) + 1ull;
    }
    /// Returns, as `key=value` pairs separated by `;`, the pacing inputs recorded at the last t0 and
    /// the current cycle horizon.
    std::string pacingSnapshot() const;

    /// Returns the first major-collection trigger that holds, or `None`. Returns `None` while a mark
    /// cycle runs.
    MajorGCTriggerReason evaluateMajorGCTrigger() const;

    /// Returns whether a major-collection trigger holds.
    bool shouldTriggerMajorGC() const {
        return evaluateMajorGCTrigger() != MajorGCTriggerReason::None;
    }

    /// Returns whether `ptr` lies in [`regionBase()`, `regionEnd()`). Being in the range does not
    /// make it the address of an object, or even of a block.
    inline bool contains(void* ptr) const {
        char* p = static_cast<char*>(ptr);
        return p >= regionBase() && p < regionEnd();
    }
    // The bounds of the range blocks lie in. Background markers read them while the mutator extends
    // the range, so every read and write goes through a relaxed atomic reference, the owner's reads
    // included. During a mark cycle the range only grows, so a stale value still covers every block
    // that existed at t0.
    // TLA-REGION(OGH.regionAndOwnerAccessors) begin
    /// Returns the lowest address of the range blocks lie in; null before `initialize` and after `reset`.
    char* regionBase() const {
        return std::atomic_ref<char*>(const_cast<char*&>(region_base_)).load(std::memory_order_relaxed);
    }
    /// Returns the end of the range blocks lie in.
    char* regionEnd() const {
        return std::atomic_ref<char*>(const_cast<char*&>(region_end_)).load(std::memory_order_relaxed);
    }
    /// Sets the start of the block range.
    void setRegionBase(char* v) { std::atomic_ref<char*>(region_base_).store(v, std::memory_order_relaxed); }
    /// Sets the end of the block range.
    void setRegionEnd(char* v) { std::atomic_ref<char*>(region_end_).store(v, std::memory_order_relaxed); }


    /// Promotion-path timing samples. They are recorded only in builds with phase timers, and only
    /// for `allocate` calls during a minor collection: the lazy-sweep slice is timed one call in 16,
    /// with its bytes counted on every call, and the whole allocation one call in 256.
    struct PromoInstr {
        SampledTimer<4> sweep;
        uint64_t        sweep_bytes = 0;
        SampledTimer<8> alloc;
    };
    /// Returns the promotion-path timing samples. A reader takes differences across an interval.
    const PromoInstr& promoInstr() const { return promo_instr_; }

#if ENABLE_GC_STATS
    /// Returns this old generation's allocation statistics. Major-collection counters are not
    /// kept here.
    GCStats& getStats() { return alloc_stats_; }
    const GCStats& getStats() const { return alloc_stats_; }
#endif

    /// The owners of one page-index slot. The page index has one slot per `alloc_buffer_size` bytes
    /// of the old-generation reservation, and a slot names the blocks that overlap it, at most two:
    /// a block is at least a page long but need not start on a slot boundary. An owner is stored as
    /// its `BlockId` plus 1, so 0, the content of a fresh slot, means none.
    struct PageOwners {
        uint32_t primary;
        uint32_t secondary;
    };
    /// Returns the stored form of owner `id`.
    static constexpr uint32_t encodeOwner(BlockId id) { return id.v + 1; }
    // Owner words are read by background markers while blocks are added and removed, so every access
    // goes through an atomic reference: stores with release, loads by readers with acquire.

    /// Stores `v` in owner word `w`, with release ordering.
    static void storeOwner(uint32_t& w, uint32_t v) {
        std::atomic_ref<uint32_t>(w).store(v, std::memory_order_release);
    }
    /// Loads owner word `w` with acquire ordering.
    static uint32_t loadOwner(const uint32_t& w) {
        return std::atomic_ref<uint32_t>(const_cast<uint32_t&>(w)).load(std::memory_order_acquire);
    }
    /// Loads owner word `w` with relaxed ordering, for the thread that writes the word.
    static uint32_t loadOwnerRelaxed(const uint32_t& w) {
        return std::atomic_ref<uint32_t>(const_cast<uint32_t&>(w)).load(std::memory_order_relaxed);
    }
    // TLA-REGION(OGH.regionAndOwnerAccessors) end
    /// Returns the block an owner word names, or `NO_BLOCK_ID` for 0.
    static constexpr BlockId decodeOwner(uint32_t o) { return BlockId{o - 1}; }

private:
    // ========== Configuration ==========

    const HeapConfig* config_;    // Set by `initialize` (null before); must outlive this object.
    Allocator* allocator_;        // The block supplier, set by `initialize`; must outlive this object.

    /// The number of size classes in use, from `large_object_threshold`: between NUM_SMALL_CLASSES and
    /// NUM_SIZE_CLASSES.
    size_t num_size_classes_;

    // ========== Block Management ==========

    /// Every block, by id, and the iteration order over the live ones.
    BlockTable blocks_;
    size_t allocated_bytes;                // see getAllocatedBytes()

    /// `allocated_bytes` when the last sweep finished, less the bytes the last mark cycle allocated
    /// black. The garbage-fraction and live-budget triggers measure allocation since the last major
    /// from it.
    size_t post_sweep_live_bytes_ = 0;
    /// Live bytes found by the last two major marks (0 before them), for the live-budget trigger.
    size_t major_live_ = 0;
    size_t prev_major_live_ = 0;

    /// Bitmap mode: the committed bytes when the last major collection's sweep was set up. The
    /// garbage-fraction trigger caps its denominator at a multiple of it, so that a heap that grows
    /// between majors does not keep raising the bar it has to reach.
    size_t committed_at_major_ = 0;

#if ENABLE_GC_STATS
    /// The allocation-size histogram and allocator counters of this old generation.
    GCStats alloc_stats_;
#endif
    PromoInstr promo_instr_;

    /// The bag of pages: [start, end) extents of `alloc_buffer_size` bytes, committed and not yet
    /// made into blocks.
    std::vector<std::pair<char*, char*>> unassigned_blocks_;

    /// The block range, read and written only through regionBase() and its siblings.
    char* region_base_;
    char* region_end_;

    /// The page index: slot (p - index_base_) / alloc_buffer_size names the blocks overlapping that
    /// page. `index_base_` is the heap base, so the index covers the whole old-generation reservation.
    /// It is reserved at `initialize` and committed only up to the end of the block range, so a lookup
    /// must check the slot against `page_index_.committed()`; slots beyond it are inaccessible.
    ReservedArray<PageOwners> page_index_;
    char* index_base_ = nullptr;

    /// The `alloc_buffer_size` the metadata reservations were sized for.
    size_t reserved_page_size_ = 0;

    /// Reserves the block table, mark bitmaps, page index and the markers' live-byte accumulators for
    /// the Allocator's old-generation reservation, and resolves the marker counts. Prints the sizes
    /// and aborts if a reservation fails.
    void reserveMetadata();

#if ECO_HEAP_VALIDATE
    /// The addresses of the metadata storage at reserveMetadata(), which the validators check have
    /// not moved.
    const void* storage_bases_[BlockTable::kStorageArrays + 3] = {};
#endif

    /// Recomputes the block range from the live blocks and the bag of pages, after an address range
    /// was released, and commits the page index through the new end.
    void recomputeRegionBounds();

    /// Commits the page index through the slot that covers `end - 1`. Does nothing if it already is.
    void commitPageIndexThrough(const char* end);

    // ========== Bitmap allocation ==========
    //
    // A uniform block's `alloc_state` says where bitmap allocation has it. The four values are below.
    // Each class has at most one block in state Current, `cursor_[cls]`'s, and its Queued blocks wait
    // in `partial_[cls]` from `partial_head_[cls]` on, oldest first. The queues are rebuilt after
    // every mark.
    /// A uniform block that no cursor or queue holds.
    static constexpr uint8_t kAllocNone = 0;
    /// A uniform block waiting in its class's queue.
    static constexpr uint8_t kAllocQueued = 1;
    /// The block a class cursor allocates in, or, during a parallel promotion, a worker's or the
    /// shared one.
    static constexpr uint8_t kAllocCurrent = 2;
    /// A block granted to a tenure job, from the grant until it is returned. No allocator path may
    /// take, detach or release it.
    static constexpr uint8_t kAllocTenure = 3;
    /// A position in one uniform block's bitmap, from which allocation scans for clear cells. The
    /// fields other than the two accumulators copy the block's geometry, so a scan reads nothing
    /// else. A default-constructed cursor holds no block.
    struct AllocCursor {
        BlockId  block = NO_BLOCK_ID;
        uint32_t next_cell = 0;     ///< The first cell not yet examined.
        uint32_t num_cells = 0;
        uint32_t stride_bits = 0;   ///< Bits per cell: `cell_bytes / 8`.
        uint32_t cell_bytes = 0;
        uint8_t* bits = nullptr;    ///< The block's mark bitmap, which does not move.
        char*    base = nullptr;
        // Bytes and allocations not yet added to the block's `live_bytes` and the statistics. They
        // are added by flushing the cursor, so a reader of a uniform block's `live_bytes` calls
        // syncCursorLiveBytes() first.
        uint64_t pending_live = 0;
        uint64_t pending_allocs = 0;
    };
    /// Per class: the cursor, the queue of partially free uniform blocks, and the queue's head.
    AllocCursor cursor_[NUM_SIZE_CLASSES];
    std::vector<BlockId> partial_[NUM_SIZE_CLASSES];
    size_t partial_head_[NUM_SIZE_CLASSES] = {};

    /// Whether bitmap allocation is on.
    bool bitmapMode() const { return config_->old_gen_bitmap_alloc; }
    /// Returns the number of cells in uniform block `b`.
    static uint32_t cellsIn(const BlockInfo& b) {
        return static_cast<uint32_t>(
            static_cast<size_t>(b.end_of_objects - b.start) /
            classToSize(b.size_class));
    }
    /// Empties every cursor and queue and sets every block's state to None, after adding the cursors'
    /// pending bytes to their blocks. Aborts if a block is granted to a tenure job.
    void resetAllocCursors();
    /// Takes block `id` out of its cursor or queue and sets its state to None; does nothing for state
    /// None. Aborts for a granted block, and for a Current block during a parallel promotion.
    void detachFromAllocation(BlockId id);
    /// Makes `id` class `cls`'s cursor block, from cell 0, and sets its state to Current.
    void setCursor(size_t cls, BlockId id);
    /// Adds `cursor_[cls]`'s pending bytes and counts to its block and the statistics.
    void flushCursor(size_t cls);
public:
    /// Adds every class cursor's pending bytes to its block's `live_bytes`, so that `live_bytes` is
    /// exact for a reader. Does nothing outside bitmap mode.
    void syncCursorLiveBytes();

    // ========== Parallel promotion ==========
    //
    // During a parallel minor collection several workers promote into this old generation at once.
    // Between beginParallelPromotion and endParallelPromotion the class cursors belong to the
    // workers, and the allocator's later rungs (free lists, splitting, sweep, new blocks) run under
    // `promo_mu_`. With one worker, worker 0 takes over `cursor_` and gives it back at the end. With
    // more, the workers share one current block per class and claim *chunks* of it, runs of whole
    // 64-bit bitmap words, so that no bitmap word has two writers.

    /// One promotion worker's private state: its cursors and the counts it adds to the old
    /// generation's when the promotion ends.
    struct PromoWorker {
        AllocCursor cur[NUM_SIZE_CLASSES];
        uint64_t allocated_bytes = 0;     ///< Not yet added to `allocated_bytes`.
        uint64_t old_alloc_total = 0;     ///< Not yet added to `oldAllocTotal()`.
        uint64_t bm_allocs = 0, bm_bytes = 0;
        uint64_t mutex_acquires = 0, mutex_wait_ns = 0;
        uint64_t size_hist[GCStats::OLDGEN_ALLOC_BUCKETS] = {};
        uint64_t size_16_24 = 0;
        // Free cells popped from a class list in a batch under the lock, to be made into objects
        // outside it; the ones left over go back on their lists when the promotion ends.
        /// The most free cells a worker holds popped per class.
        static constexpr unsigned kStash = 16;
        FreeCell* stash[NUM_SIZE_CLASSES][kStash];
        uint8_t stash_n[NUM_SIZE_CLASSES] = {};
        uint64_t list_pops = 0, stash_returned = 0;
        uint8_t chunk_units[NUM_SIZE_CLASSES] = {};   ///< Chunk units of the next claim.
#if ECO_HEAP_VALIDATE
        std::vector<void*> cycle_alloc_log;
        uint64_t mutex_charges = 0;
#endif
        /// Resets everything for a new promotion, the claim sizes to one unit.
        void resetRun();
    };
    /// The shared state of one parallel promotion: the workers and, with more than one, the claim word
    /// of each class.
    struct PromoCtx {
        unsigned n = 0;
        PromoWorker w[kMaxPromoWorkers];
        // True with more than one worker. Then `shared[cls]` is the class's claim word:
        // (block id + 1) << 32 | the next unclaimed unit, 0 for no block.
        bool chunked = false;
        // One cache line per claim word, so that claims on one class do not slow claims on another.
        struct alignas(64) SharedWord { std::atomic<uint64_t> w{0}; };
        SharedWord shared[NUM_SIZE_CLASSES];
    };
    // TLA-REGION(OGH.kChunkUnitCells) begin
    /// The size of a chunk unit, in cells. 64 cells take whole 64-bit bitmap words whatever the cell
    /// size, and the bitmap scans read a word at a time, so two workers never write the same word. A
    /// worker's claim for a class starts at one unit each promotion and doubles, up to
    /// `kChunkMaxUnits`.
    static constexpr uint32_t kChunkUnitCells = 64;
    // TLA-REGION(OGH.kChunkUnitCells) end
    /// The largest claim, in chunk units.
    static constexpr uint32_t kChunkMaxUnits = 16;
    /// Returns the promotion state, creating it on first use. It lives as long as this object.
    PromoCtx& promoCtx();
    /// Starts a parallel promotion with `n` workers (1 to `kMaxPromoWorkers`). Requires bitmap mode
    /// and no promotion in progress. With one worker, worker 0 takes over the class cursors; with more,
    /// each class cursor's block becomes the class's shared block, from its next cell's chunk on.
    void beginParallelPromotion(PromoCtx& ctx, unsigned n);
    /// Ends the parallel promotion `ctx`, after every worker has stopped. Returns the workers'
    /// cursors and stashed cells, requeueing blocks with free cells at the front of their queues,
    /// adds the workers' counts, and runs the end-of-sweep shrink if the sweep finished meanwhile.
    void endParallelPromotion(PromoCtx& ctx);
    /// Allocates `size` bytes for a promotion by worker `pw`, as `allocate` would, and returns null
    /// when no space can be found. May be called by every worker at once. With `per_alloc_sweep`, it
    /// also does the lazy-sweep slice `allocate` does per promotion.
    void* allocatePromotion(PromoWorker& pw, size_t size, bool per_alloc_sweep);
    /// Returns whether a parallel promotion is in progress.
    bool parallelPromotionActive() const { return par_promo_active_; }
    /// Returns whether `cell` lies in a block the lazy sweep has not finished; false when the phase is
    /// not `Sweeping`. A cell of such a block shares bitmap words with the sweep's unlocked bit
    /// operations, so a promotion that takes one must finish it before releasing `promo_mu_`, and must
    /// not stash it. Call under `promo_mu_`: the phase is read without an atomic.
    bool cellInUnsweptBlock(void* cell) const {
        if (gc_phase_ != GCPhase::Sweeping) return false;
        const BlockId id = contains(cell) ? blockIdFor(cell) : NO_BLOCK_ID;
        return id.valid() && !blocks_.meta(id).fully_swept;
    }

    // ========== Tenure grants ==========
    //
    // A tenure job copies objects into the old generation while the mutator runs, and allocates only
    // from a *grant*: uniform blocks put into state Tenure in a pause, enough for the objects counted
    // per class, and returned in a later pause. The job reads only the cursors the grant caches, never
    // the block table or the page index.

    /// A position in one granted block, with the geometry it needs cached.
    struct TenureCursor {
        BlockId  block = NO_BLOCK_ID;
        char*    base = nullptr;
        uint8_t* bits = nullptr;
        uint32_t next_cell = 0, num_cells = 0, cell_bytes = 0, stride_bits = 0;
        uint64_t pending_live = 0, pending_allocs = 0;
    };
    /// The blocks granted to one tenure job, per class in grant order, and the counts it will add to
    /// the old generation's when it is returned.
    struct TenureGrant {
        std::vector<TenureCursor> blocks[NUM_SIZE_CLASSES];   // in grant order
        uint32_t next[NUM_SIZE_CLASSES] = {};                  ///< The block the serial cursor is in.
        uint64_t allocated_bytes = 0, old_alloc_total = 0;     ///< Added at the return.
        uint64_t size_hist[GCStats::OLDGEN_ALLOC_BUCKETS] = {};
        uint64_t size_16_24 = 0;
        uint64_t granted_cells = 0, used_cells = 0, block_count = 0, virgin_blocks = 0;
        bool active = false;
#if ECO_HEAP_VALIDATE
        bool cycle_active = false;
        std::vector<void*> cycle_alloc_log;
#endif
        // With several collector threads, each claims chunks of a block by compare-and-swap on
        // `claim[cls]` = block index << 32 | next unit, a unit being tenureChunkCells() cells.
        struct alignas(64) ClaimWord { std::atomic<uint64_t> w{0}; };
        ClaimWord claim[NUM_SIZE_CLASSES];
    };
    // TLA-REGION(OGH.tenureChunkCells) begin
    /// Returns the chunk size, in cells, for a class with `stride_bits` bitmap bits per cell:
    /// 1,024 / `stride_bits` rounded down to a multiple of 64, and never less than 64. A chunk is thus
    /// whole 64-bit bitmap words, so two collector threads never write the same word. It covers 1,024
    /// bitmap bits only when 1,024 is a multiple of 64 * `stride_bits`.
    static uint32_t tenureChunkCells(uint32_t stride_bits) {
        const uint32_t c = 1024u / (stride_bits == 0 ? 1u : stride_bits);
        return c < 64u ? 64u : (c & ~63u);
    }
    // TLA-REGION(OGH.tenureChunkCells) end
    /// One collector thread's allocation state in a grant: its current chunk per class and the cells
    /// it used, which grantFoldMember() adds to the grant.
    struct TenureMemberCursor {
        struct Cls { int32_t bi = -1; uint32_t k = 0, kend = 0, used = 0; };
        Cls c[NUM_SIZE_CLASSES];
        struct Use { uint16_t cls; uint32_t bi; uint32_t cells; };
        std::vector<Use> uses;
        uint64_t size_hist[GCStats::OLDGEN_ALLOC_BUCKETS] = {};
        uint64_t size_16_24 = 0;
#if ECO_HEAP_VALIDATE
        std::vector<void*> cycle_alloc_log;
#endif
        /// Resets everything.
        void reset() { *this = TenureMemberCursor{}; }
    };
    /// Returns the next free cell of class `cls` from the chunk of collector thread `m`, claiming a new
    /// chunk of grant `g` when it runs out, and writes a zero header. Several threads, each with its
    /// own `m`, may call it at once on one grant. Aborts when the grant has no chunk left.
    void* grantAllocateShared(TenureGrant& g, TenureMemberCursor& m, size_t cls, size_t requested_size);
    /// Adds what collector thread `m` used to grant `g` and resets `m`. Call after `m`'s thread has
    /// stopped.
    void grantFoldMember(TenureGrant& g, TenureMemberCursor& m);
    /// Fills the inactive grant `g` with enough uniform blocks for `count[c]` cells of every class `c`,
    /// plus one chunk per class for each of `slack_participants` collector threads, and returns true.
    /// Queued blocks are taken first, from the front of each queue, then new blocks. Returns false
    /// when no new block can be had (near the old-generation cap): `g` is then active with what it
    /// got, and must still be returned. Aborts if `g` is active, or if a count names a class this
    /// old generation does not use.
    bool grantTenure(const uint32_t count[NUM_SIZE_CLASSES], TenureGrant& g,
                     uint32_t slack_participants = 0);
    /// Returns the next free cell of class `cls` in grant `g`, with a zero header. For the one thread
    /// that owns `g`. Aborts when the grant has no free cell left.
    void* grantAllocate(TenureGrant& g, size_t cls, size_t requested_size);
    /// Returns grant `g` in a pause, after the job: adds its counts, sets its blocks back to None, and
    /// requeues those with free cells at the front of their queues, the first granted first. Does
    /// nothing if `g` is inactive.
    void returnTenureGrant(TenureGrant& g);
    /// Returns the number of grants not yet returned.
    unsigned activeTenureGrants() const { return active_tenure_grants_; }
    // Test hooks: grant a block that existed at t0 / let the shrink ignore granted blocks.
    bool test_grant_t0_block_ = false;
    bool test_shrink_ignores_tenure_ = false;
    /// Aborts if a block is in state Tenure while no grant is live. Does nothing while one is.
    void validateTenureBlocks(const char* where) const;
#if ECO_HEAP_VALIDATE
    // The allocated bytes when the promotion began, and whether the end-of-promotion check that they
    // balance is skipped.
    size_t pm6_allocated_before_ = 0;
    bool pm6_skip_ = false;
    // Blocks the gap sweep finished during a promotion with more than one worker, checked after the
    // workers stop (a worker may still be writing a cell of one). Written under promo_mu_.
    std::vector<std::pair<BlockId, char*>> v11_deferred_;
    // Aborts unless block `id` parses, header by header, over [start, end_of_objects).
    void validateV11(BlockId id) const;
#endif

private:
    // The worker versions of the class-cursor functions below: the same steps on the worker's cursor
    // `c`, with the counts charged to worker `pw` instead of this object. Unless a comment says it
    // runs lock-free, each must be called under `promo_mu_`.

    /// Lock-free. Adds `c`'s pending bytes to its block's `live_bytes` (atomically: several workers
    /// may flush into one block) and its counts to `pw`.
    void flushCursorW(AllocCursor& c, PromoWorker& pw);
    /// Makes `id` the block of worker cursor `c`, from cell 0, and sets its state to Current.
    void setCursorW(AllocCursor& c, size_t cls, BlockId id, PromoWorker& pw);
    /// Moves `c` to the next usable block in class `cls`'s queue; false when the queue is empty.
    bool refillCursorW(AllocCursor& c, size_t cls, PromoWorker& pw);
    /// Lock-free. Makes cell `k` of `c`'s block an object, allocated black when a mark is in progress
    /// or the phase is not Idle, and returns it.
    void* finalizeBitmapCellW(AllocCursor& c, uint32_t k, size_t requested_size, PromoWorker& pw);
    /// Lock-free. Makes the free cell `cell`, popped earlier from class `cls`'s list, an object, as
    /// finalizePoppedCell() does, with every shared write atomic; returns it.
    void* finalizePoppedCellW(FreeCell* cell, size_t cls, size_t requested_size, PromoWorker& pw);
    /// Lock-free. Allocates the next clear cell of `c`'s block; null when the block (or, with chunks,
    /// the claimed chunk) has none, after emptying `c`.
    void* cursorAllocateW(AllocCursor& c, size_t requested_size, PromoWorker& pw);
    /// Makes a new uniform block of class `cls` the block of worker cursor `c`; false when no page can
    /// be had.
    bool startVirginBlockW(AllocCursor& c, size_t cls, PromoWorker& pw);
    /// Runs the allocation ladder from its second rung for worker `pw`: free list, new block (for a
    /// small class under budget), splitting, sweep on demand, new block, a page as one cell, panic
    /// sweep. Returns null when all fail.
    void* ladderFrom2W(size_t cls, size_t requested_size, PromoWorker& pw);
    /// Puts block `id` at the front of class `cls`'s queue, in state Queued.
    void requeueFront(size_t cls, BlockId id);
    /// Lock-free. Claims the next chunk of class `cls`'s shared block into `c`; false when there is no
    /// shared block or it has no chunk left.
    bool claimChunkW(size_t cls, AllocCursor& c, PromoWorker& pw);
    /// Makes sure class `cls` has a shared block with a chunk left, retiring an exhausted one and
    /// taking the next from the queue; false when the queue has none.
    bool advanceSharedW(size_t cls);
    /// Makes a new uniform block of class `cls` the shared block; false when no page can be had.
    bool startVirginBlockShared(size_t cls);
    /// Makes `id` class `cls`'s shared block from chunk 0, with a release store of the claim word.
    void publishShared(size_t cls, BlockId id);
    /// Handles the lazy sweep finishing inside a promotion: with one worker, runs the end-of-sweep
    /// shrink at once on worker 0's behalf; with more, leaves it to endParallelPromotion.
    void sweepCompleteInPromotion();
    /// Created by promoCtx().
    std::unique_ptr<PromoCtx> promo_ctx_;
    minorwork::SpinMutex promo_mu_;   // see the guards listed at cellInUnsweptBlock and ladderFrom2W
    bool par_promo_active_ = false;
    bool sweep_complete_deferred_ = false;   // the sweep finished inside the promotion
    /// Returns the wait policy for acquiring a block from the Allocator: AvoidUnderPromo during a
    /// parallel promotion with more than one worker, Allowed otherwise. Every block acquisition a
    /// promotion can reach passes it.
    AcquireWait acquireWaitPolicy() const;
    /// Moves `cursor_[cls]` to the next usable block in the class's queue; false when it is empty.
    bool refillCursor(size_t cls);
    /// Allocates the next clear cell from class `cls`'s cursor, refilling it from the queue as needed;
    /// null when the queue runs out.
    void* cursorAllocate(size_t cls, size_t requested_size);
    /// Makes cell `k` of `c`'s block an object, allocated black when a mark is in progress or the phase
    /// is not Idle, and returns it. Sets the cell's bit, which is its allocation record.
    void* finalizeBitmapCell(AllocCursor& c, uint32_t k, size_t requested_size);
    /// Makes a new uniform block of class `cls` the class cursor's block; false when no page can be had.
    bool startVirginBlock(size_t cls);
    /// Makes a new uniform block of class `cls` from a bag page, without slicing it, and returns its id;
    /// NO_BLOCK_ID when no page can be had.
    BlockId materializeVirginBlock(size_t cls);
    unsigned active_tenure_grants_ = 0;   // see activeTenureGrants()
    /// Makes sure the bag holds a page, acquiring one from the Allocator if needed; false when none can
    /// be had.
    bool ensureBagPageAvailable();
    /// The bitmap-mode allocation ladder for class `cls`: cursor, free list, new block (small class under
    /// budget), splitting, sweep on demand, new block, a page as one cell, panic sweep.
    void* allocateFromSizeClassBitmap(size_t cls, size_t requested_size);
    /// Bitmap mode: frees one cell of uniform block `id` by clearing its bit, and makes the cell
    /// reusable at once (rewinding the cursor, or queueing the block).
    void freeUniformCell(BlockId id, char* cell);
    /// Bitmap mode, after a mark: drops from the large-object index every entry outside large blocks
    /// whose object is unmarked. Nursery-owned ids are not recycled.
    void retireDeadLargeBodies();
    /// Bitmap mode, after a mark: retires dead objects, frees large blocks whose object died, marks
    /// uniform blocks swept and queues those with free cells.
    void classifyBlocksAfterMark();
    /// Returns whether the lazy sweep has still to pass `addr` in block `id`. A cell the sweep has
    /// passed must be put on a free list when it is freed; a cell ahead of it must not be, because the
    /// sweep will reclaim it.
    bool sweepWillReach(BlockId id, const char* addr) const;

    // ========== Per-heap GC state ==========
    //
    // Collection work for this heap may run on threads other than the mutator, so this state is kept
    // here and not in thread-local storage.

    /// The heap's nursery, set by bindNursery(); null before. Must outlive this object.
    const NurserySpace* nursery_ = nullptr;

    /// True while the heap's minor collection runs, when every allocate() is a promotion.
    bool in_minor_gc_ = false;

    /// While non-zero, releaseBlockToAllocator does not recompute the block range; the caller that
    /// raised it recomputes it once at the end.
    int batch_release_depth_ = 0;

    // ========== GC state machine ==========

    /// The phase. During a parallel promotion its one write (the sweep finishing) is a relaxed atomic
    /// store and the reads outside `promo_mu_` are relaxed atomic loads. Every other access is made in
    /// a pause, by one thread or under `promo_mu_`, and is plain.
    GCPhase gc_phase_;
    static_assert(std::atomic_ref<GCPhase>::is_always_lock_free);

    // ========== Marking state ==========

    /// An object on a mark stack with the block that owns it, NO_BLOCK_ID for a nursery object.
    struct MarkStackEntry {
        void* obj;
        BlockId block;
    };
    static_assert(sizeof(MarkStackEntry) == 16,
                  "MarkStackEntry must pack to 16 bytes");

    /// The prefetch distance of the mark loop, in objects: how far ahead of scanning an object its
    /// memory is prefetched. 16 was the fastest of the depths 4 to 64 in measurements of whole
    /// self-compiles. It must be a power of two, so the ring index is a mask (asserted below).
    static constexpr size_t MARK_FIFO_DEPTH = 16;
    static_assert(MARK_FIFO_DEPTH > 0 &&
                  (MARK_FIFO_DEPTH & (MARK_FIFO_DEPTH - 1)) == 0,
                  "MARK_FIFO_DEPTH must be a power of two so the ring index "
                  "arithmetic compiles to a mask rather than a division");

    /// Nursery objects the current stop-the-world mark has reached. A major mark must not write a
    /// nursery object's header, so this set, not the header colour, stops it tracing one twice.
    std::unordered_set<void *> nursery_visited_;
    u32 current_epoch;                // Incremented at every mark start; nothing reads it.
    bool marking_active;              // From mark start until the end of the mark.
    Allocator *allocator_ref_;        // Set at mark start; must outlive the mark.

    // ========== Lazy sweep state ==========

    /// The sweep position: the iteration-order position of the block being swept, and the address
    /// reached in it.
    size_t sweep_buffer_index_;
    char* sweep_cursor_;

    /// The blocks still to be swept this cycle. Set after the end-of-mark releases, counted down as
    /// blocks become fully swept, and zeroed when the sweep finishes.
    size_t sweep_pending_blocks_;

    /// The blocks this cycle's sweep started with: the denominator of the unswept fraction that raises
    /// the per-allocation sweep budget.
    size_t sweep_total_blocks_;

    // ========== Mark bitmaps ==========

    /// One fixed-size bitmap slot per block id, one bit per 8-byte slot of the block; a large block's
    /// slot is empty and it uses its mark byte instead. A slot's address never moves.
    MarkBitArena mark_;

    // ========== The markers ==========
    //
    // A *marker slot* is a grey set with a live-byte accumulator. Slot 0 always exists and is the
    // mutator's. With F foreground markers (the mark gang) and B background markers, slots 0 to F-1
    // are foreground and F to F+B-1 background. Each marker adds live bytes to its own accumulator,
    // and the accumulators are summed into the blocks' `live_bytes` in slot order after the mark.
public:
    /// The tag for the single-threaded mark path, which uses plain bit operations on slot 0.
    struct SerialMark   { static constexpr bool kParallel = false; };
    /// The tag for the parallel mark path, which uses atomic bit operations and work stealing.
    struct ParallelMark { static constexpr bool kParallel = true; };
    /// One marker slot's state. Its owner thread alone touches `stack`; other markers read `priv` and
    /// steal from `deque`.
    struct MarkWorker {
        // Serial path: slot 0's whole grey set. Parallel path: the owner's private grey entries; the
        // oldest half moves to `deque` when that runs dry.
        std::vector<uint64_t> stack;
        std::atomic<uint64_t> priv{0};           ///< `stack.size()`, published for other markers.
        uint64_t pops = 0;
        markwork::WorkStealingDeque deque;       ///< The stealable grey entries.
        LiveBytesAccumulator live;               ///< The live bytes this marker attributed.
        markwork::MarkerCounters ctr;
        uint64_t chunks = 0;                     ///< Chunk entries pushed (statistics).
    };
    /// The largest number of marker slots.
    static constexpr unsigned kMaxMarkers = 64;
    /// Returns F, the number of foreground markers.
    unsigned markThreads() const { return mark_threads_; }
    /// Returns whether the current mark is on the parallel path.
    bool markParallel() const { return mark_parallel_; }
    /// Returns the foreground marker count `cfg` asks for: `gc_mark_threads`, or with 0 the smaller
    /// of `gc_mark_threads_cap` and the available CPUs; at most kMaxMarkers, at least 1, and 1 when
    /// bitmap allocation is off.
    static unsigned resolveMarkThreads(const HeapConfig& cfg);
    /// Returns the minor-collection worker count `cfg` asks for, as resolveMarkThreads() does for
    /// `gc_minor_threads`; at most kMaxMinorWorkers, and 1 when bitmap allocation is off.
    static unsigned resolveMinorThreads(const HeapConfig& cfg);
    /// Returns the number of parallel minor-collection workers.
    unsigned minorThreads() const { return minor_threads_; }
    /// Returns the process's mark gang, configured first if it is not, or has fewer members than the
    /// larger of the foreground marker and minor worker counts, or a different jitter. Reconfiguring
    /// shuts the gang down and restarts it.
    gc::GCMarkGang& ensureGang();
private:
    /// Created and destroyed only while no thread runs on any slot.
    std::unique_ptr<MarkWorker> markers_[kMaxMarkers];
    /// Loops over slots run to mark_slots_; loops that start the foreground gang run to mark_threads_.
    unsigned mark_threads_ = 1;      // F: foreground markers
    unsigned minor_threads_ = 1;
    unsigned conc_threads_ = 0;      // B: background markers
    unsigned mark_slots_ = 1;        // F + B
    bool mark_parallel_ = false;     // set by beginMarkCycle, cleared at mark start and handoff
    /// Returns slot 0.
    MarkWorker& w0() { return *markers_[0]; }
    const MarkWorker& w0() const { return *markers_[0]; }
    /// Returns the sum over every slot's accumulator for block `id`, leaving them unchanged.
    uint64_t markLivePeek(BlockId id) const;
    /// Returns the sum over every slot's accumulator for block `id`, and zeroes those entries.
    uint64_t markLiveTake(BlockId id);
    /// Returns every slot's accumulator total.
    uint64_t markLiveSum() const;
    /// Adds every slot's accumulator into the blocks' `live_bytes`, in slot order, and clears them.
    void markLiveMergeAll();
    /// Creates the slots up to mark_slots_ (at least one) and destroys those above.
    void ensureMarkers();
    /// Sets the mark bit of `obj` in block `id`, and returns whether it was already set. False also
    /// for an invalid id or a slot outside the bitmap.
    template <class P> bool testAndSetMark(BlockId id, const void* obj);
    /// Greys `obj` onto `w` if it is a heap object not yet marked: an old object by its mark bit, a
    /// nursery object (serial path only) through nursery_visited_. Nothing is greyed for a header-less
    /// large body, whose bit is all its marking.
    template <class P> void greyObject(MarkWorker& w, void* obj);
    /// Greys the object `ptr` refers to; nothing for an embedded constant or a non-heap address.
    template <class P> void greyHPointer(MarkWorker& w, HPointer& ptr);
    /// Greys the children of `obj`. Outside the t0 snapshot, an array or list backing longer than one
    /// chunk has its first chunk greyed and the rest pushed as chunk entries.
    template <class P> void scanChildren(MarkWorker& w, void* obj);
    /// Greys the children in chunk `chunk` of the array or list backing `obj`.
    template <class P> void scanChunk(MarkWorker& w, void* obj, uint32_t chunk);
    /// Scans grey object `obj`: adds its size to `w`'s accumulator for `block` (looked up if invalid)
    /// and greys its children. Returns false, doing nothing, for a free cell or a forwarding stub.
    template <class P> bool scanObject(MarkWorker& w, void* obj, BlockId block);
    /// Scans grey entry `e`: an object or a chunk.
    template <class P> void scanEntry(MarkWorker& w, uint64_t e);
    /// The fewest private entries publishHalf() moves.
    static constexpr size_t kPublishMin = 64;
    // TLA-REGION(OGH.publishGrey) begin
    // Owner only. Moves the oldest half of `w`'s private entries to its deque, if it has at least
    // kPublishMin and the deque looks empty.
    void publishHalf(MarkWorker& w) {
        if (w.stack.size() < kPublishMin || !w.deque.emptyApprox()) return;
        const size_t half = w.stack.size() / 2;
        for (size_t i = 0; i < half; ++i) w.deque.push(w.stack[i]);
        w.stack.erase(w.stack.begin(), w.stack.begin() + static_cast<std::ptrdiff_t>(half));
        w.priv.store(w.stack.size(), std::memory_order_relaxed);
    }
    // Owner only. Moves all of `w`'s private entries to its deque. Every exit of a parallel run calls
    // it, so no private work outlives a run and any marker can steal what is left.
    void publishAll(MarkWorker& w) {
        if (w.stack.empty()) return;
        for (uint64_t e : w.stack) w.deque.push(e);
        w.stack.clear();
        w.priv.store(0, std::memory_order_relaxed);
    }
    // Owner only. Pushes `e` onto `w`'s private stack; on the parallel path, publishes its size and
    // every 32nd push offers half to the deque.
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
    /// Does mark work with a budget of `budget` units (markwork::kDrainBudget to drain), on the
    /// foreground gang on the parallel path, else on slot 0. Returns the units done, which equals the
    /// tickets used. Must not run while a background episode runs.
    uint64_t runMarkers(int64_t budget);
    /// The mark gang's entry point for one member.
    static void markerEntry(void* ctx, unsigned member);
    /// Returns whether no slot holds a grey entry; exact only while no marker runs.
    bool markStackEmpty() const;
    /// Returns whether any slot looks to hold a grey entry, reading atomics only, so it may be called
    /// while an episode runs.
    bool markWorkApprox() const;
    /// Returns the number of grey entries; approximate on the parallel path.
    size_t markStackSize() const;
    // The two environments markwork::runMarkerLoop runs a mark in.
    struct SerialEnv;
    struct ParallelEnv;
    friend struct SerialEnv;
    friend struct ParallelEnv;
#if ECO_HEAP_VALIDATE
    /// Validation: records that grey entry `e` was scanned while armed, aborting if it already was.
    void im10NoteScan(uint64_t e);
    /// Validation: forgets the recorded scans.
    void im10Reset();
    /// Validation: checks the recorded scans against the closure of the t0 grey set; aborts on a
    /// mismatch.
    void im11Check(const char* where);
    std::vector<uint64_t> im11_t0_greys_;
    struct Im10State;
    std::unique_ptr<Im10State> im10_;
#endif
    // ========== Concurrent marking ==========
public:
    /// What a parallel marker may know about the heap outside the old generation, fixed at t0 and
    /// unchanged until the handoff. A marker that may run beside the mutator reads this, never the
    /// nursery's live bounds, the cycle state or the young-large-object index.
    struct MarkView {
        const char* nursery_lo = nullptr;   ///< The nursery's whole reservation, [lo, hi).
        const char* nursery_hi = nullptr;
#if ECO_HEAP_VALIDATE
        std::vector<const void*> ylos_t0;   ///< The young large objects at t0, sorted.
#endif
    };
    /// Where the current cycle's background episode is. `Running` lasts from a launch to the join that
    /// reaps it. `Finished` means an episode ended with the mark work done. `None` means none has
    /// been launched this cycle, or the last one was stopped or refused, with its work left in the
    /// background slots' deques.
    enum class BgEpisode : uint8_t { None, Running, Finished };
    /// Returns the background marker count `cfg` asks for: 0 unless `conc_mark` is 2 with
    /// incremental marking and bitmap allocation; else `conc_mark_threads`, or with 0 the smaller of
    /// `conc_mark_threads_cap` and one less than the available CPUs (at least 1). It is cut so that
    /// `fg` plus it does not exceed kMaxMarkers.
    static unsigned resolveConcMarkThreads(const HeapConfig& cfg, unsigned fg);
    /// Returns B, the number of background markers.
    unsigned concThreads() const { return conc_threads_; }
    /// Returns F + B, the number of marker slots.
    unsigned markSlots() const { return mark_slots_; }
    /// Returns where the current cycle's background episode is.
    BgEpisode bgEpisode() const { return bg_ep_; }
private:
    MarkView mark_view_;
    BgEpisode bg_ep_ = BgEpisode::None;
    /// For trace logging only: this cycle step's launch was refused.
    bool bg_refused_step_ = false;
    /// The background gang, created at the first launch and kept across cycles; stopped and joined
    /// before this object is destroyed or reset.
    std::unique_ptr<gc::GCBackgroundGang> bg_;
    /// The running episode's work budget and stop flag; replaced at every launch.
    std::unique_ptr<markwork::SliceControl> bg_ctl_;
    uint32_t bg_done_k_ = 0;           // the first cycle step that saw an episode finished (statistics)
public:
    /// Counts of the current cycle's mark work, by who did it: background markers, assists (with
    /// their number) and closing joins, and the step at which an episode was first seen finished.
    struct CycleProgress { uint64_t bg_units = 0, assists = 0, assist_units = 0, closing_units = 0; uint32_t done_k = 0; };
    /// Returns the current cycle's progress counts.
    CycleProgress cycleProgress() const { CycleProgress p = cyc_prog_; p.done_k = bg_done_k_; return p; }
private:
    CycleProgress cyc_prog_;
    /// The promotion-rate pacing state: bytes ever allocated, the total at the last minor end, and
    /// the estimate.
    uint64_t old_alloc_total_ = 0;
    uint64_t old_alloc_at_prev_minor_ = 0;
    int64_t  p_hat_ = 0;
    /// The pacing inputs as they were at the last t0, for pacingSnapshot().
    struct PacingAtT0 { int64_t p_hat = 0; uint64_t live_ref = 0, alloc_since_major = 0, headroom = 0; };
    PacingAtT0 pacing_t0_;
    uint64_t bg_launch_ns_ = 0;        // the clock at the last launch (statistics)
    bool fg_run_active_ = false;       // the foreground gang is running on slots 0..F-1
    /// Whether the last concurrent cycle step ran an assist or a closing join.
    bool step_pause_work_ = false;
    /// Returns whether `obj` lies in the nursery reservation recorded at t0.
    bool young_in_view(const void* obj) const {
        const char* p = static_cast<const char*>(obj);
        return p >= mark_view_.nursery_lo && p < mark_view_.nursery_hi;
    }
#if ECO_HEAP_VALIDATE
    /// Validation: whether `obj` was a young large object at t0; whether block `id` existed at t0
    /// (aborting if its id has since been re-issued); and whether the scan recorder is on.
    bool ylosAtT0(const void* obj) const;
    bool isT0Block(BlockId id) const;
    std::atomic<bool> im10_armed_{false};
#endif
    /// Moves every foreground slot's grey entries, round-robin, into the background slots' deques,
    /// and launches an episode on the background gang (creating it on first use). Returns false when
    /// a fork in progress holds the gang: the episode is then `None` and the work stays in the deques.
    bool launchBackground();
    /// Joins a running episode, merges its counters and records it `Finished` if its work is done or
    /// `None` if it was stopped. With `wait` false it returns at once if the episode looks unfinished.
    /// Does nothing unless an episode is running.
    void reapBackground(bool wait);
    /// After a join: adds the background slots' counters to the cycle's and resets them.
    void mergeBackgroundCounters();
    /// Frees the deque arrays every slot has outgrown. Call only while no marker runs.
    void retireAllDequeArrays();
    /// Returns how much of the episode's budget its markers have claimed, an over-estimate of their
    /// units; 0 with no running episode. For pause-internal decisions only.
    uint64_t bgConsumedApprox() const;
    /// The concurrent cycle step at minor end k: reaps or relaunches the episode, then, before the
    /// last step, runs an assist if marking lags its schedule, or at the last step the closing join.
    /// Returns the units marked inside this pause.
    size_t runCycleStepConcurrent();
    /// Runs the foreground gang beside the running episode for at most `budget` units. `budget` must
    /// be positive and an episode running.
    void assistEpisode(int64_t budget);
    /// Finishes the mark inside this pause: joins a running episode with the foreground gang, then
    /// drains whatever a stopped episode left. Returns the units marked in this pause; the grey sets
    /// are empty afterwards (asserted).
    size_t closingFinish();
    // The entry points of a background member, an assisting member and a closing member.
    static void bgEntry(void* ctx, unsigned member);
    static void assistEntry(void* ctx, unsigned member);
    static void closingEntry(void* ctx, unsigned member);
    /// Aborts if a slot no thread runs on holds private grey entries.
    void assertNoPrivateWork(const char* where) const;
#if ECO_HEAP_VALIDATE
    /// Validation: the depth of decision paths (triggers, the pressure finish, the allocation ladder)
    /// on the stack. A read of approximate collector progress asserts it is 0.
    mutable int in_decision_ = 0;
    /// Validation: marks a decision path for its lifetime. Refers to `og`, which must outlive it.
    struct DecisionScope {
        const OldGenSpace& og;   // the space whose depth it raises
        explicit DecisionScope(const OldGenSpace& o) : og(o) { ++og.in_decision_; }
        ~DecisionScope() { --og.in_decision_; }
    };
    /// Validation: aborts if a decision path is on the stack; `what` names the read.
    void assertNotInDecision(const char* what) const;
#endif
    /// Aborts if a gang may be running on any slot in [lo, hi): the foreground gang on [0, F), the
    /// background gang on [F, F + B). The default range is every slot.
    void assertSlotsQuiescent(const char* where, unsigned lo = 0, unsigned hi = kMaxMarkers) const;
public:
    /// Stops and joins a running background episode and reaps it. Does nothing otherwise.
    void stopBackground();
    // Test hooks for negative controls.
    bool test_skip_bg_merge_ = false;
    bool test_leave_private_on_exit_ = false;
    bool test_cursor_takes_t0_block_ = false;
    bool test_plain_allocate_black_ = false;
    std::atomic<bool> test_bg_hold_{false};   // background members wait while it is set
#if ECO_HEAP_VALIDATE
    // Negative control: an assist also resets the first background slot's counter.
    bool test_assist_resets_bg_ctr_ = false;
#endif
public:
    // Test hooks for negative controls.
    bool test_skip_merge_worker1_ = false;
    bool test_plain_bits_parallel_ = false;
    bool test_steal_without_ticket_ = false;
private:

    // ========== Fragmentation statistics ==========

    FragmentationStats frag_stats_;   // computed by computeFragmentationStats()

    // ========== Compaction state (test-only) ==========

    CompactionPhase compact_phase_;
    std::vector<BlockId> evacuation_set_;
    size_t current_evac_index_;
    char* evac_cursor_;
    BlockId evac_block_index_;
    char* evac_alloc_ptr_;
    size_t fixup_buffer_index_;               // iteration-order position
    char* fixup_cursor_;

    // ========== Free lists ==========

    /// Per class, the head of the free list; every cell on list `cls` is classToSize(cls) bytes.
    FreeCell* free_lists_[NUM_SIZE_CLASSES];

    /// An over-count of the free cells marked as already on a list since the sweep last began; 0
    /// means there are none, which lets the sweep start without walking the lists to unmark them.
    size_t free_list_sentinel_count_ = 0;

    /// Large blocks whose object died, which allocateLargeBlock reuses before acquiring a new block.
    std::vector<BlockId> free_large_blocks_;

    // ========== The large-object index ==========

public:
    /// An index into the large-object table. A freed id may be given to a new entry.
    using LargeBodyId = uint32_t;

    // TLA-REGION(OGH.LargeBodyMeta) begin
    /// One entry of the large-object index (see the large-body section above). An entry whose
    /// `body_base` is null is free or retired.
    struct LargeBodyMeta {
        void*  body_base;   ///< The object or payload's address; null when retired.
        size_t cell_size;   ///< The bytes its cell occupies.
        bool   is_large;    ///< Whether it has a large block to itself.
        bool   color;       ///< The colour of the last minor collection that reached it.
        uint8_t kind = 0;   ///< 0 large body, 1 young large object, 2 old large object.
        // For a young large object, the minor collection at which it joined a generation of the
        // region nursery, 0 before. A generation names its members by address, and a major may free a
        // member whose cell a new young large object then takes; this stamp tells them apart.
        uint64_t join_minor = 0;
    };
    // TLA-REGION(OGH.LargeBodyMeta) end

    // A young large object is a pointer-bearing object too large for the nursery. It is allocated in an
    // old-generation cell and never moved, but it is young: the minor collection scans it in place,
    // ages it, and promotes it in place, and frees it at the end of a minor that did not reach it.

    /// Allocates a young large object of `size` bytes, rounded up to a multiple of 8, writes its header
    /// for `tag` with `pin` set and age 0, and records it with minor colour `initial_color`. Returns
    /// null when the old generation cannot grow.
    void* allocateYoungLarge(size_t size, Tag tag, bool initial_color);
    // TLA-REGION(OGH.youngLargeMeta) begin
    /// Returns false for every address outside the bounding box of the young large objects (always,
    /// when there are none). True does not mean `p` is one; see youngLargeMeta().
    bool mayBeYoungLarge(const void* p) const {
        return p >= ylo_lo_ && p < ylo_hi_;
    }
    /// Returns the index entry of the young large object that starts at `p`, or null. The pointer is
    /// valid until the index next gains an entry.
    LargeBodyMeta* youngLargeMeta(const void* p) {
        if (!mayBeYoungLarge(p)) return nullptr;
        auto it = large_body_index_.find(const_cast<void*>(p));
        if (it == large_body_index_.end() || it->second >= large_bodies_.size()) return nullptr;
        LargeBodyMeta& m = large_bodies_[it->second];
        return (m.kind == 1 && m.body_base == p) ? &m : nullptr;
    }
    // TLA-REGION(OGH.youngLargeMeta) end
    /// Returns whether a young large object starts at `p`.
    bool isYoungLarge(const void* p) {
        return youngLargeMeta(p) != nullptr;
    }
    // TLA-REGION(OGH.youngLargeMember) begin
    /// Returns the entry of the young large object at `p` only if it joined the generation filled at
    /// minor `gen_minor`, else null: a member a major freed is gone from the index or its cell holds a
    /// newer object. The pointer is valid until the index next gains an entry.
    LargeBodyMeta* youngLargeMember(const void* p, uint64_t gen_minor) {
        LargeBodyMeta* m = youngLargeMeta(p);
        return (m != nullptr && m->join_minor == gen_minor) ? m : nullptr;
    }
    // TLA-REGION(OGH.youngLargeMember) end
    /// Returns whether the last stop-the-world major mark reached nursery object `p`. Valid from the
    /// end of that mark until the next mark starts.
    bool majorReachedNursery(const void* p) const {
        return nursery_visited_.count(const_cast<void*>(p)) != 0;
    }
    /// Promotes the young large object `obj` in place: it becomes an old large object (kind 2) and its
    /// age is reset. Does nothing if `obj` is not in the index.
    void promoteYoungLarge(void* obj);
    /// Returns the young-large-object count kept with the bounding box. It rises at each allocation,
    /// is recomputed at some minor ends and after some majors, and is not lowered by a promotion in
    /// between.
    size_t youngLargeCount() const { return ylo_count_; }
    /// Returns whether `body` is in the large-object index.
    bool largeBodyIndexed(void* body) const { return large_body_index_.count(body) != 0; }
    /// Returns a count raised at the end of every major mark, after which a dead young large object's
    /// cell may be reused.
    uint64_t majorEpoch() const { return major_epoch_; }
    /// Returns the live bytes the last major mark found, 0 before any.
    size_t majorLiveBytes() const { return major_live_; }

    // ---- The explicit release ----

    /// Runs the lazy sweep to completion. Aborts if a mark cycle is running.
    void finishSweepForRelease();
    /// Releases every empty block and bag page the shrink may release, down to the floor of
    /// max(`initial_old_gen_size`, `alloc_buffer_size`). Does nothing during a compaction, a mark cycle
    /// or an unfinished sweep.
    void shrinkToFloorForRelease();
    /// Recomputes the young large objects' bounding box and count from the index.
    void recomputeYoungLargeBounds();
    /// Calls `f(obj, meta)` for every nursery-owned young large object. `f` must not add to or remove
    /// from the index.
    template <typename F> void forEachYoungLarge(F&& f) {
        for (LargeBodyId id : nursery_owned_bodies_) {
            if (id >= large_bodies_.size()) continue;
            LargeBodyMeta& m = large_bodies_[id];
            if (m.body_base != nullptr && m.kind == 1) f(m.body_base, m);
        }
    }

private:
    LargeObjectSpace                       los_;
    std::vector<LargeBodyMeta>             large_bodies_;
    std::unordered_map<void*, LargeBodyId> large_body_index_;
    std::vector<LargeBodyId>               nursery_owned_bodies_;
    std::vector<LargeBodyId>               free_large_body_ids_;
    // major_epoch_ is majorEpoch()'s count. The other three are the young large objects' bounding box
    // and count (see youngLargeCount()).
    uint64_t major_epoch_ = 0;
    char*  ylo_lo_ = nullptr;
    char*  ylo_hi_ = nullptr;
    size_t ylo_count_ = 0;
    /// Clears the body address of a dead entry (the caller erases its index key). Recycles the id
    /// only for an old large object (kind 2); a nursery-owned id is dropped by the next minor sweep.
    void retireIndexEntry(LargeBodyId id);
    /// Retires every index entry whose object lies in [lo, hi), as retireIndexEntry does, erasing the
    /// keys, and returns how many.
    size_t retireIndexRange(char* lo, char* hi);

    // ========== Small-class budget ==========
    //
    // While the bytes of uniform small-class blocks are under `small_class_heap_budget_bytes`, a
    // small-class allocation takes a new block before it splits a larger free cell.

    /// The bytes of the uniform small-class blocks in use.
    size_t small_class_bytes_;

    /// The first class index not counted as small; 0 when the budget is off.
    size_t small_class_index_limit_;

    /// Recomputes small_class_index_limit_ from the configuration.
    void recomputeSmallClassLimit();

    /// Returns whether class `cls` counts as small.
    bool isSmallClassIndex(size_t cls) const {
        return cls < small_class_index_limit_;
    }

    /// Adds block `block_index`'s bytes to the budget if it is a uniform small-class block.
    void onUniformBlockDedicated(BlockId block_index);

    /// Subtracts block `block_index`'s bytes from the budget if it is a uniform small-class block.
    void onBlockReleased(BlockId block_index);

    /// Subtracts the block's bytes, as onBlockReleased does, for a block about to become large.
    void onBlockTransitioningToLarge(BlockId block_index);

    // ========== Size classes ==========

    /// Returns the class to allocate `size` bytes from: the smallest whose cells hold `size` rounded up
    /// to 8, or NUM_SIZE_CLASSES when no class does. The caller must also check the result against the
    /// classes in use (num_size_classes_).
    static size_t sizeClass(size_t size) {
        size = (size + 7) & ~7;
        if (size <= MAX_SMALL_SIZE) {
            return (size / 8) - 1;  // Classes 0..31 cover 8..256.
        }
        size_t cell = MEDIUM_CLASS_BASE;
        for (size_t i = 0; i < NUM_MEDIUM_CLASSES_MAX; ++i) {
            if (size <= cell) return NUM_SMALL_CLASSES + i;
            cell <<= 1;
        }
        return NUM_SIZE_CLASSES;  // Doesn't fit any fixed class.
    }

    /// Returns the class a free span of `span` bytes can be put on: the largest whose cell size is at
    /// most `span` rounded down to 8, so that whoever pops it gets at least the class's cell size; or
    /// NUM_SIZE_CLASSES for a span under 8 bytes. This rounds the other way from sizeClass(): a
    /// 352-byte span goes on the 256-byte class, not the 512-byte one it would overflow.
    static size_t freeListClassFor(size_t span) {
        span &= ~static_cast<size_t>(7);
        if (span < 8) return NUM_SIZE_CLASSES;
        if (span <= MAX_SMALL_SIZE) {
            return (span / 8) - 1;
        }
        if (span < MEDIUM_CLASS_BASE) {
            return NUM_SMALL_CLASSES - 1;
        }
        size_t k = 0;
        while (k + 1 < NUM_MEDIUM_CLASSES_MAX &&
               (MEDIUM_CLASS_BASE << (k + 1)) <= span) {
            ++k;
        }
        return NUM_SMALL_CLASSES + k;
    }

    /// Returns the cell size of class `cls`.
    static size_t classToSize(size_t cls) {
        if (cls < NUM_SMALL_CLASSES) return (cls + 1) * 8;
        return MEDIUM_CLASS_BASE << (cls - NUM_SMALL_CLASSES);
    }

    // ========== Setup ==========

    /// Binds this old generation to `allocator` and `config`, both kept and required to outlive it,
    /// reserves its metadata, and commits `initial_old_gen_size` bytes as pages in the bag. Aborts if
    /// `alloc_buffer_size` exceeds 512 KiB, or if a metadata reservation fails.
    void initialize(Allocator* allocator, const HeapConfig* config);

    /// Discards every block, free list, large-object entry and piece of GC state, as if just
    /// initialized, after stopping a running background episode; with `new_config`, adopts it. The
    /// blocks' memory is not given back to the Allocator, and the bag is left empty. The metadata is
    /// reserved again, so block ids restart at 0.
    void reset(const HeapConfig* new_config = nullptr);

    // ========== Stop-the-world major mark ==========

    // Starts a stop-the-world mark: finishes any lazy sweep, clears every mark bit, and greys what
    // `roots` and the raw addresses at `jit_roots` refer to, nursery objects included. Does nothing if
    // a mark is already in progress; a mark cycle must not be. The two overloads differ only in the
    // statistics they update.
#if ENABLE_GC_STATS
    void startMark(const std::unordered_set<HPointer*> &roots,
                   const std::unordered_set<uint64_t*> &jit_roots,
                   Allocator &alloc, GCStats &stats);
#else
    void startMark(const std::unordered_set<HPointer*> &roots,
                   const std::unordered_set<uint64_t*> &jit_roots,
                   Allocator &alloc);
#endif

    // Does up to `work_units` units of the stop-the-world mark and returns whether grey work is left;
    // false at once when no mark is in progress.
#if ENABLE_GC_STATS
    bool incrementalMark(size_t work_units, GCStats &stats);
#else
    bool incrementalMark(size_t work_units);
#endif

    // Finishes the stop-the-world mark and prepares the sweep: frees the dead large objects, demotes
    // mostly-dead uniform blocks, releases the empty ones, grows or shrinks the capacity, and runs the
    // first lazy-sweep slice. The `profile` overloads also record timings into it.
#if ENABLE_GC_STATS
    void finishMarkAndSweep(GCStats &stats);
    void finishMarkAndSweep(GCStats &stats, MajorGCPhaseProfile &profile);
#else
    void finishMarkAndSweep();
    void finishMarkAndSweep(MajorGCPhaseProfile &profile);
#endif

    // ========== Mark cycles ==========
    //
    // A mark cycle is driven from outside: begin at t0, a step at each later minor end, and the
    // handoff when the state becomes HandoffDue.
public:
    /// Where a mark cycle is: none, marking, or done marking and waiting for the handoff.
    enum class CycleState : uint8_t { Idle, Marking, HandoffDue };
    /// Why a cycle ended: its schedule ran out, the old generation reached the pressure-finish line,
    /// or a stop-the-world collection joined it. This component only declares it.
    enum class CycleFinish : uint8_t { Schedule, Pressure, Join };
    /// Returns whether a mark cycle is running.
    bool cycleActive() const { return cycle_state_ != CycleState::Idle; }
    /// Returns where the mark cycle is.
    CycleState cycleState() const { return cycle_state_; }
private:
    /// t0: prepares the mark as startMark does, sets the phase to Marking, fixes the cycle's plan of
    /// `slices` steps and its predicted mark work, and records the t0 view. Requires bitmap mode and no
    /// mark in progress.
    void beginMarkCycle(Allocator& alloc, uint32_t slices);
    /// The mark preparation shared by startMark and beginMarkCycle: finishes the lazy sweep, clears the
    /// mark bits, empties the grey sets and the nursery set, and zeroes the blocks' live bytes.
    void prepareMark(Allocator& alloc);
    /// Turns the t0 snapshot mode on or off. In it, greying drops nursery and young large objects.
    void setSnapshotMode(bool on) {
#if ECO_HEAP_VALIDATE
        // IM14: the snapshot pushes the t0 greys onto slot 0 as its owner.
        if (on) assertSlotsQuiescent("the t0 snapshot", 0, 1);
#endif
        snapshot_mode_ = on;
    }
    /// Greys the object a raw 64-bit root word refers to; nothing for a constant or a non-heap word.
    void markJitRootRaw(uint64_t val, Allocator& alloc);
    /// t0: marks every young large object and greys its old children.
    void snapshotYoungLarge();
    /// Does up to `work_units` units of mark work and returns the units done.
    size_t markWorkUnits(size_t work_units);
    /// The non-concurrent cycle step at minor end k (1 to T): a paced slice, or at k == T the drain
    /// that finishes the mark, after which the state is HandoffDue. Returns the units done.
    size_t runCycleSlice();
    /// Called after the t0 snapshot of a cycle with steps: launches the background episode in the
    /// concurrent mode, or marks everything at once in the synchronous mode (`conc_mark` 1).
    void afterSnapshot();
    /// Returns whether this cycle marks concurrently: background markers, steps and the parallel path.
    bool concurrentCycle() const {
        return conc_threads_ > 0 && cycle_slices_ > 0 && mark_parallel_;
    }
    /// Runs the cycle step at a minor end, concurrent or not, and returns the units marked inside the
    /// pause.
    size_t cycleStep() { return concurrentCycle() ? runCycleStepConcurrent() : runCycleSlice(); }
    /// Returns whether the last concurrent step did mark work inside its pause.
    bool lastStepHadPauseWork() const { return step_pause_work_; }
    /// Finishes the cycle's mark now (the last step, a pressure finish or a join) and returns the units
    /// done in this pause.
    size_t drainCycleMark();
    /// The handoff: requires the mark finished and no marker running; runs the end-of-mark work as
    /// finishMarkAndSweep does, including the frees the cycle deferred, with the phase back at Idle.
    /// Either pointer may be null.
    void handoffMarkCycle(GCStats* stats, MajorGCPhaseProfile* profile);
    /// Returns whether all old generations' committed bytes over the cap have reached
    /// `incremental_mark_finish_fraction`; false with no Allocator or a zero cap.
    bool cyclePressureFinishDue() const;
    // The cycle's planned step count T, the minor ends since t0, the units marked, and the units
    // predicted.
    uint32_t cycleSlicesPlanned() const { return cycle_slices_; }
    uint32_t cycleMinorsSinceT0() const { return cycle_k_; }
    /// Counts a minor end since t0.
    void noteCycleMinorEnd() { ++cycle_k_; }
    uint64_t cycleUnitsDone() const { return cycle_units_; }
    uint64_t cyclePredictedUnits() const { return cycle_predicted_; }
    /// The end-of-mark work of finishMarkAndSweep and the handoff. Either pointer may be null.
    void runPostMarkTail(GCStats* stats, MajorGCPhaseProfile* profile);
    /// Frees the large objects whose frees the cycle deferred.
    void processDeferredFrees();
#if ECO_HEAP_VALIDATE
    /// Validation: aborts if `obj`'s bit is already set before an allocation during a cycle sets it.
    void assertCellWasWhite(BlockId id, const void* obj) const;
    /// Validation: records an allocation made during a cycle.
    void noteCycleAllocation(void* obj);
    /// Validation: checks uniform blocks' live bytes against their set bits (equal when `exact`).
    void validateCycleUniformLive(const char* where, bool exact) const;
    /// Validation: a block that existed at t0, by id, id generation, start and class; and the set of
    /// them, which the handoff checks unchanged.
    struct T0Block { uint32_t id; uint32_t gen; char* start; size_t size_class; bool is_large; };
    std::vector<T0Block> t0Blocks() const;
    /// Validation: returns null if every t0 block is unchanged, else a message, with the block's start
    /// in `*where` when `where` is not null.
    const char* t0BlocksChangedWhy(char** where = nullptr) const;
    /// Validation: aborts unless every t0 block is unchanged.
    void checkT0BlocksUnchanged() const;
    std::vector<T0Block> cycle_t0_blocks_;
    bool test_im5_ignore_gen_ = false;   // negative control: compare t0 blocks without the generation
    /// Validation: aborts unless every object in `objs` is marked; `what` names the check.
    void assertAllMarked(const std::vector<void*>& objs, const char* what) const;
    std::vector<void*> cycle_t0_reach_;     // old objects reached at t0
    std::vector<void*> cycle_alloc_log_;    // allocations made during the cycle
#endif
    // Test hooks for negative controls.
    bool test_skip_allocate_black_ = false;
    bool test_keep_worker_cursor_ = false;
    bool test_idle_uncounted_ = false;        // Idle allocations skip their live-bytes add

    /// The mark cycle's state. `in_slice_` is set during a step; `cycle_tail_uses_traced_live_` makes
    /// the end-of-mark work take the live bytes from the markers' sums.
    CycleState cycle_state_ = CycleState::Idle;
    bool     snapshot_mode_ = false;
    bool     in_slice_ = false;
    bool     cycle_tail_uses_traced_live_ = false;
    uint32_t cycle_slices_ = 0;       // T, fixed at t0
    uint32_t cycle_k_ = 0;            // minor ends since t0
    uint64_t cycle_predicted_ = 0;    // predicted units, fixed at t0
    uint64_t cycle_units_ = 0;        // old-gen units marked this cycle
    uint64_t prev_cycle_units_ = 0;   // the last cycle's units, for the next prediction
    size_t   prev_cycle_occ_t0_ = 0;  // occupancy at the previous cycle's t0
    size_t   cycle_traced_live_ = 0;  // the markers' sums at the handoff
    size_t   cycle_black_bytes_ = 0;  // bytes allocated black this cycle
    size_t   baseline_black_bytes_ = 0;  // excluded from the trigger baseline until the next major
    std::vector<LargeBodyMeta> deferred_frees_;   // frees put off to the handoff

    // The serial-path forms of scanChildren, greyHPointer and greyObject, on slot 0.
    void markChildren(void *obj);
    void markHPointer(HPointer &ptr);
    void pushMarkRoot(void *obj);
    /// Greys the object `val` refers to when `is_boxed`.
    void markUnboxable(Unboxable &val, bool is_boxed);
    /// Sweeps every block to completion, entering the Sweeping phase first if needed.
    void sweep();

    /// Enters the Sweeping phase: empties the free lists and the free large blocks, which the sweep
    /// rebuilds, and resets the sweep position.
    void transitionToSweeping();
    /// Sweeps up to about `work_budget` bytes of blocks, preferring to stop once class `target_class`
    /// has a free cell, and returns the bytes walked. Ends the phase, and runs onSweepComplete(), when
    /// the last block is swept.
    size_t lazySweep(size_t target_class, size_t work_budget);
    /// At the end of a sweep: computes the occupancy statistics, re-bases the allocated bytes, and
    /// runs the light shrink. Aborts if a parallel promotion is in progress.
    void onSweepComplete();

    // Returns whether the phase is Sweeping with blocks still to sweep.
    // TLA-REGION(OGH.hasPendingSweepWork) begin
    bool hasPendingSweepWork() const {
        return gc_phase_ == GCPhase::Sweeping && sweep_pending_blocks_ > 0;
    }
    // TLA-REGION(OGH.hasPendingSweepWork) end
    /// Returns whether no sweep is in progress or no block is left to sweep.
    bool sweepComplete() const {
        return gc_phase_ != GCPhase::Sweeping || sweep_pending_blocks_ == 0;
    }

    /// Counts the blocks still to be swept from their metadata.
    void recomputeSweepPendingBlocks();

    /// Marks block `block_index` fully swept, counting it down the first time.
    void markBlockFullySwept(BlockId block_index);

    /// Allocates from class `cls`'s free list, or by splitting a larger free cell; null otherwise.
    /// Takes no new page and does not grow the old generation.
    void* tryAllocateFromFreeLists(size_t cls, size_t requested_size);

    /// Unlinks and returns the head of class `cls`'s free list, or null. The cell is not yet an
    /// object; finalizePoppedCell() makes it one.
    FreeCell* tryPopFromFreeList(size_t cls);

    /// Makes the popped cell `cell` of class `cls` an object of `requested_size` bytes (allocated
    /// black if a mark is in progress or the phase is not Idle), marks its slack free, and returns it.
    void* finalizePoppedCell(FreeCell* cell, size_t cls,
                             size_t requested_size);

    /// Returns whether a small-class allocation of class `cls` should take a new block before
    /// splitting a larger free cell: the budget is on and not reached, and the old generation is below
    /// its cap.
    bool shouldPreferBagForSmallClass(size_t cls) const;

    /// While sweep work is pending, alternates lazy-sweep slices with free-list attempts, up to the
    /// budget computeSweepBudgetForAlloc() gives, and returns the first success; null otherwise.
    void* sweepOnDemandAllocate(size_t cls, size_t requested_size);

    /// Returns this old generation's committed bytes over the Allocator's old-generation cap,
    /// clamped to [0, 1]; 0 when there is no cap.
    double committedToCapRatio() const;

    /// Returns the sweep budget, in bytes, for allocating `requested_size` bytes: proportional to the
    /// request, scaled up as the old generation nears its cap and when most blocks are unswept, and
    /// kept between `sweep_work_budget` and `max_sweep_bytes_hard`.
    size_t computeSweepBudgetForAlloc(size_t requested_size) const;

    /// Sweeps everything still pending, in slices, retrying the free lists between them, and returns
    /// the first success; null when the sweep runs out. For use once the old generation cannot grow.
    void* panicSweepAndRetryAllocation(size_t cls, size_t requested_size);

    /// After a major mark: when the live bytes are at most `major_gc_target_utilization` of the
    /// capacity (or nothing is live), runs the heavy shrink; when they are at least
    /// `major_gc_initiating_occupancy` of it, asks the Allocator to grow the capacity toward
    /// live / target utilization, within the old-generation cap.
    void adjustCapacityAfterMajorGC();

    // ========== Compaction (test-only) ==========
    //
    // Nothing outside unit tests starts a compaction.

    /// Returns whether the phase is Idle and utilization is below UTILIZATION_THRESHOLD.
    bool shouldCompact() const;
    /// Computes frag_stats_ from the blocks' metadata, and re-bases the allocated bytes and the trigger
    /// baseline on the live bytes.
    void computeFragmentationStats();
    /// Starts a compaction: selects the blocks to evacuate. Does nothing if one is in progress.
    void scheduleCompaction();
    /// Returns the blocks to evacuate, moving at most `max_live_to_move` live bytes.
    std::vector<BlockId> selectEvacuationSet(size_t max_live_to_move);
    /// Does up to `work_budget` bytes of the compaction's current stage.
    void incrementalCompactionSlice(size_t work_budget);
    /// Evacuates up to `work_budget` live bytes and returns how many it moved.
    size_t evacuateSlice(size_t work_budget);
    /// Starts rewriting references to evacuated objects.
    void prepareReferenceFixup();
    /// Rewrites references in up to `work_budget` bytes of blocks.
    void fixReferencesSlice(size_t work_budget);
    /// Rewrites the references in `obj` to evacuated objects.
    void fixPointersInObject(void* obj);
    /// Rewrites `ptr` if it refers to an evacuated object.
    void fixHPointer(HPointer& ptr);
    /// Rewrites `val` when `is_boxed`, as fixHPointer() does.
    void fixUnboxable(Unboxable& val, bool is_boxed);
    /// Allocates `size` bytes for an evacuated object.
    void* allocateForEvacuation(size_t size);
    /// Leaves a forwarding stub at `old_location` pointing to `new_location`.
    void installForwardingPointer(void* old_location, void* new_location);
    /// Returns the address `obj`'s forwarding stub points to, or null if `obj` has none.
    void* getForwardingAddress(void* obj) const;
    /// Returns whether `block` is to be evacuated.
    bool isInEvacuationSet(BlockId block) const;
    /// Removes the evacuated blocks' free cells from the free lists and returns their pages to the bag.
    void freeEvacuatedBuffers();

    // ========== Allocation ladder ==========

    /// The allocation ladder for class `cls` (outside bitmap mode, and in it the bitmap ladder):
    /// free list, a new block for a small class under budget, splitting, sweep on demand, a new block,
    /// a page as one cell, panic sweep. Returns null when all fail.
    void* allocateFromSizeClass(size_t cls, size_t requested_size);

    /// Cuts `requested_size` bytes from the mixed-block classes' free lists, then after bounded lazy
    /// sweep slices, and otherwise takes a page from the bag (acquiring one if needed) as one free
    /// cell, splits the request off the front and puts the rest on the free lists. Returns the
    /// object; null when no page can be had.
    void* allocateFromBagPage(size_t requested_size);

    /// Looks in the classes from max(`target_cls`, `num_size_classes_`) up for a free cell from which
    /// `alloc_size` bytes can be cut, returns the cut-off front as an object, and puts the remainder on
    /// the free lists; null if none.
    void* tryAllocateBySplittingLarger(size_t target_cls, size_t alloc_size);

    /// Returns the block whose [start, end) contains `addr`, or null. A linear search over the blocks;
    /// blockIdFor() is the constant-time lookup. The pointer is valid until blocks are next added or
    /// released.
    const BlockInfo* findBlockContaining(char* addr) const {
        for (size_t pos = 0; pos < blocks_.size(); ++pos) {
            const BlockInfo& block = blocks_.info(blocks_.idAt(pos));
            if (addr >= block.start && addr < block.end) {
                return &block;
            }
        }
        return nullptr;
    }

    /// Outside bitmap mode: takes a page from the bag, slices it into class `cls` cells and puts them on
    /// the class's free list. Returns whether a page was available.
    bool populateFromBlock(size_t cls);

    /// Writes a zero header with the colour for the phase: black, with the mark bit set, when a mark is
    /// in progress or the phase is not Idle. The caller writes the tag and size. The second form also
    /// adds `cell_bytes` to the block's live bytes when it is not 0.
    void initObjectHeader(void* obj);
    void initObjectHeaderWithSize(void* obj, size_t cell_bytes);

    /// Allocates a large block of its own for an object of `size` bytes (at least a page), reusing a
    /// freed large block or an empty page block when one fits. Returns null when none can be had.
    void* allocateLargeBlock(size_t size);

    // ========== Large-block reuse ==========

    /// Records large block `block_index`, whose object died, as free for reuse.
    void markBlockAsFreeLarge(BlockId block_index);

    /// Returns the start of a freed large block of at least `size` bytes, made live again with a fresh
    /// header, or null.
    void* allocateFromFreeLargeBlocks(size_t size);

    /// Turns an empty page block large enough for `size` bytes into a large block and returns its
    /// start, or null if none is.
    void* allocateFromEmptyRegularBlocks(size_t size);

    // ========== Releasing blocks ==========
    //
    // Each release gives memory back to the Allocator, which takes its own lock for it.
    /// Releases block `block_index`: drops it from the free lists, the free large blocks, the cursors,
    /// the page index and the block table, and gives its memory back to the Allocator. Must not run
    /// during a mark cycle.
    void releaseBlockToAllocator(BlockId block_index);

    /// Gives bag page `unassigned_index` back to the Allocator, swapping the last page into its place.
    void releaseUnassignedBlockToAllocator(size_t unassigned_index);

    /// Removes every free cell inside block `block_index` from the free lists.
    void removeFreeCellsForBlock(BlockId block_index);

    /// Updates the sweep and fixup positions after a release moved the block at iteration position
    /// `old_pos` to `new_pos`.
    void fixupCursorsAfterOrderMove(size_t old_pos, size_t new_pos);

    /// How hard a shrink tries. Each releases empty blocks toward `desired_heap_bytes`. `Heavy`, after
    /// a mark, and `Light`, when the sweep ends, act only when the old generation exceeds that by a
    /// margin (1.5 times for `Light`); `Heavy` skips that test under global pressure. `Forced`, the
    /// explicit release, has no margin, and does nothing during an unfinished sweep or a mark cycle.
    /// None goes below the floor of max(`initial_old_gen_size`, `alloc_buffer_size`), and none runs
    /// during a compaction.
    enum class ShrinkPass : uint8_t { Heavy, Light, Forced };
    /// Releases empty blocks and bag pages as `pass` allows.
    void maybeShrinkCapacity(size_t desired_heap_bytes,
                             ShrinkPass pass = ShrinkPass::Heavy);

    // ========== Page index ==========

    /// Commits the page index through the end of the block range.
    void resizePageIndexForRegion() { commitPageIndexThrough(regionEnd()); }

    /// Returns the first and last page-index slots block `block` covers, or SIZE_MAX if the index is
    /// not set up or the block lies below its base.
    size_t firstPageIndex(const BlockInfo& block) const;
    size_t lastPageIndex(const BlockInfo& block) const;

    /// Records block `block_index` as an owner of every slot its extent covers.
    void assignPageIndexForBlock(BlockId block_index);

    /// Removes block `block_index` from every slot its extent covers.
    void clearPageIndexForBlock(BlockId block_index);

    /// Returns the block containing `obj`, or NO_BLOCK_ID if `obj` is outside the block range or no
    /// block owns it. Constant time: one slot, at most two extent checks. Callable from background
    /// markers while blocks are added.
    BlockId blockIdFor(const void* obj) const;

    /// Adds a block described by `bi` and `m` to the table, with `mark_bytes` of mark bitmap, and to
    /// the page index, and returns its id. Every block enters through it.
    BlockId materializeBlock(const BlockInfo& bi, const BufferMetadata& m,
                             size_t mark_bytes);

    // ========== Large-object helpers ==========

    /// Adds an index entry for the cell `body` and returns its id, reusing a freed id when there is
    /// one. With `owned`, the entry is nursery-owned.
    LargeBodyId registerLargeBody(void* body, size_t cell_size, bool is_large,
                                  bool minor_color, uint8_t kind = 0, bool owned = true);
    /// Allocates the cell of a large object of `total_size` bytes: in an LOS block when it fits one,
    /// else a large block of its own. Sets `cell_size` to the cell's footprint and `is_large` to which;
    /// null when the old generation cannot grow.
    void* allocateTrackedCell(size_t total_size, size_t& cell_size, bool& is_large);

    /// Allocates `bytes` from the LOS (its raw pool when `raw`), adding an LOS block when none has
    /// room, and sets `*block_out`; null when the old generation cannot grow.
    void* allocateLos(size_t bytes, bool raw, BlockId* block_out);
    /// Allocates the cell of a header-less body, as allocateTrackedCell() does but in raw storage.
    void* allocateRawCell(size_t total_size, size_t& cell_size, bool& is_large);
    /// Accounts a new header-less cell: sets its mark bit when allocating black, and adds its bytes to
    /// block `block_id`'s live bytes.
    void attributeNewCell(BlockId block_id, void* obj, size_t cell_bytes);

    /// Takes a bag page as an LOS block (of the raw pool when `raw`); NO_BLOCK_ID when none can be had.
    BlockId addLosBlock(bool raw);
    /// At the end of a mark: frees every unmarked LOS object and sets each LOS block's live bytes to
    /// its used bytes.
    void losSweepAtMarkEnd();
    /// Releases empty LOS blocks beyond `los_empty_keep`, down to the floor.
    void losReleaseEmptyBlocks();
    /// Frees `cell_size` bytes at `cell` in LOS block `id` and subtracts them from the live counts.
    void freeLosCell(BlockId id, void* cell, size_t cell_size);
#if ECO_HEAP_VALIDATE
    /// Validation: every allocated LOS byte belongs to an index entry or a deferred free.
    void validateLosTracking(const char* where) const;
#endif

    /// Frees the cell of index entry `m` and erases its key: an LOS cell goes back to the LOS, a large
    /// block to the free large blocks, and any other cell to a free list (bitmap mode: its bit is
    /// cleared). Does nothing if `m` is already retired. Must not run during a mark cycle.
    void freeLargeBodyCell(LargeBodyMeta& m);

    // ========== Mark bits ==========

    /// The bytes one mark bit covers, which is the alignment of every object.
    static constexpr size_t MARK_ALIGNMENT = 8;

    /// Returns the number of 8-byte slots in block `block`.
    size_t slotsForBlock(const BlockInfo& block) const {
        return block.totalBytes() / MARK_ALIGNMENT;
    }

    /// Returns the bytes of mark bitmap block `block` needs.
    size_t bitmapBytesForBlock(const BlockInfo& block) const {
        return (slotsForBlock(block) + 7) / 8;
    }

    /// Sets `*byte_index` and `*mask` to the bitmap position of `obj` in block `id`. Not for a large
    /// block, which has one mark byte.
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
    // Returns whether `obj` is marked in block `id`; false for an invalid id or a position outside
    // the bitmap. Plain reads: not for use while a marker may write the byte.
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

    // Sets `obj`'s mark bit and returns whether it was already set. Returns false, setting nothing,
    // for an invalid id or a position outside the bitmap. Plain read-modify-write.
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

    // Sets `obj`'s mark bit and returns whether it was clear before: the opposite sense to
    // testAndSetMarkBitInBlock(). False also for an invalid id or a position outside the bitmap.
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

    // Sets `obj`'s mark bit with an atomic relaxed OR, for allocating black while a background marker
    // may set other bits of the same byte; a plain read-modify-write could erase the marker's bit.
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
    // Returns whether `obj` is marked, with relaxed atomic loads, for the mutator while a background
    // marker may be writing the byte.
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

    /// Clears `obj`'s mark bit and returns whether it was set.
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

    // ========== Mark-time live bytes ==========

    /// Scans `obj` on slot 0, as scanObject() does: greys its children and, for an old object, adds
    /// its size to its block's live bytes, looking up the block when `block` is NO_BLOCK_ID. Returns
    /// false for a free cell or a forwarding stub. The one-argument form looks the block up.
    bool markOneObject(void* obj, BlockId block);
    bool markOneObject(void* obj);

    /// Zeroes every block's live and garbage bytes at mark start, and marks LOS blocks swept and
    /// other blocks not swept.
    void resetBufferMetaForMark();

    /// Unless `demote_live_fraction` is 0 or less, demotes uniform blocks (not the heap-base block)
    /// whose live bytes are at most `demote_live_fraction` of their size to mixed, so that their free
    /// space goes to the free lists of any class. Run after the live bytes are final and before the
    /// sweep starts. Returns what it demoted.
    struct DemotionStats {
        size_t blocks_demoted = 0;
        size_t bytes_demoted  = 0;
    };
    DemotionStats demoteMostlyDeadUniformBlocks();

    /// After the mark: adds the markers' live bytes to the blocks, frees unmarked LOS objects, sets
    /// each block's garbage bytes, and computes frag_stats_ and the live bytes the triggers use.
    void finalizeMetaAfterMark();

    /// Resets every block's garbage bytes and swept flag before a lazy sweep, keeping its live bytes.
    void prepareMetaForLazySweep();

    // ========== Releasing dead blocks ==========

    /// What reclaimAllDeadBlocksFromMeta() released.
    struct AllDeadReclaimStats {
        size_t blocks_released = 0;
        size_t bytes_released  = 0;
    };

    /// Releases every block other than large, LOS and tenure-granted blocks whose live bytes are 0,
    /// last first, down to the floor, and returns what it released.
    AllDeadReclaimStats reclaimAllDeadBlocksFromMeta();

#if ENABLE_GC_STATS
    /// Free bytes per block, keyed by block start, which survives a release moving blocks.
    using FreeBytesByBlockStart = std::unordered_map<const char*, size_t>;

    /// Records the free-list histogram in `stats` and each block's free bytes in `out`. Must run
    /// before the sweep starts, which empties the free lists.
    void gatherFreeListSnapshotInto(GCStats& stats,
                                    FreeBytesByBlockStart& out) const;

    /// Records each block's live, free and garbage bytes in `stats`, the free bytes from
    /// `free_by_start`. Run after the end-of-mark releases and capacity adjustment.
    void gatherResidencySnapshotFrom(
        GCStats& stats,
        const FreeBytesByBlockStart& free_by_start) const;
#endif

#if ECO_HEAP_VALIDATE
    // ========== Metadata validation ==========

    /// Aborts with a message naming `where` if the block metadata is inconsistent.
    void validateOldGenMetadata(const char* where) const;
    /// Aborts if a free cell's predecessor link does not name its predecessor.
    void validateFreeListBackLinks(const char* where) const;
public:
    /// Validation: runs validateOldGenMetadata() on every 64th call.
    void validateEveryNthMinor();
private:
    uint64_t validate_minor_count_ = 0;
#endif

    friend class Allocator;
    friend class NurserySpace;
    friend class ThreadLocalHeap;
    friend class OldGenSpaceTestAccess;
    friend struct p1::P1CensusAccess;
};

/// Test-only access to the private state of an `OldGenSpace`: readers of its counters and tables,
/// drivers of its private steps, and setters of its negative-control hooks. A *negative control* is a
/// hook that makes the old generation misbehave on purpose, so that a test can show a check fires.
///
/// Every function is static and takes the old generation it works on. A returned reference or
/// pointer refers into that object's state and is valid until the object next changes that state.
/// Call only while no other thread uses the object.
class OldGenSpaceTestAccess {
public:
    // ---- Parallel promotion and bitmap allocation ----

    /// Returns the `k`-th block waiting in class `cls`'s queue, or NO_BLOCK_ID past its end.
    static BlockId partialQueueAt(const OldGenSpace& og, size_t cls, size_t k) {
        const auto& q = og.partial_[cls];
        const size_t i = og.partial_head_[cls] + k;
        return i < q.size() ? q[i] : NO_BLOCK_ID;
    }
    /// Returns the block containing `p`, as `blockIdFor`.
    static BlockId blockOf(OldGenSpace& og, const void* p) { return og.blockIdFor(p); }
    /// Negative control: leaves one worker's cursor block unreturned at the end of a promotion.
    static void setKeepWorkerCursor(OldGenSpace& og, bool on) { og.test_keep_worker_cursor_ = on; }
    /// Returns whether the end-of-sweep shrink was put off to the end of the current promotion.
    static bool sweepCompleteDeferred(const OldGenSpace& og) { return og.sweep_complete_deferred_; }
    /// Returns how often the sweep finished inside a parallel promotion; 0 in builds without
    /// statistics.
    static uint64_t sweepTailInPromotion(const OldGenSpace& og) {
#if ENABLE_GC_STATS
        return og.alloc_stats_.bm.sweep_tail_in_promotion;
#else
        (void)og;
        return 0;
#endif
    }
    /// Negative control: allocations in the Idle phase skip their live-bytes add.
    static void setIdleUncounted(OldGenSpace& og, bool on) { og.test_idle_uncounted_ = on; }
    /// Returns the generation of block id `id`, which tells its incarnations apart.
    static uint32_t blockGeneration(const OldGenSpace& og, BlockId id) { return og.blocks_.generation(id); }
#if ECO_HEAP_VALIDATE
    /// Records the current blocks as the t0 blocks, outside a cycle.
    static void captureT0Blocks(OldGenSpace& og) {
        og.cycle_t0_blocks_ = og.t0Blocks();
        std::sort(og.cycle_t0_blocks_.begin(), og.cycle_t0_blocks_.end(),
                  [](const OldGenSpace::T0Block& x, const OldGenSpace::T0Block& y) { return x.id < y.id; });
    }
    /// Returns null if every recorded t0 block is unchanged, else a message.
    static const char* t0BlocksChangedWhy(const OldGenSpace& og) { return og.t0BlocksChangedWhy(); }
    /// Forgets the recorded t0 blocks.
    static void clearT0Blocks(OldGenSpace& og) { og.cycle_t0_blocks_.clear(); }
    /// Negative control: compares t0 blocks without their id generation.
    static void setIm5IgnoreGeneration(OldGenSpace& og, bool on) { og.test_im5_ignore_gen_ = on; }
#endif
    /// Returns whether the promotion lock is held, by trying to take it (and releasing it at once if
    /// that succeeds).
    static bool promoMuHeld(OldGenSpace& og) {
        if (!og.promo_mu_.try_lock()) return true;
        og.promo_mu_.unlock();
        return false;
    }
    /// Returns cyclePressureFinishDue(), which reads the Allocator's committed bytes without its lock.
    static bool cyclePressureFinishDue(const OldGenSpace& og) { return og.cyclePressureFinishDue(); }
    /// Returns the number of live blocks.
    static size_t numBlocks(const OldGenSpace& og) { return og.blocks_.size(); }
    /// Returns getCommittedBytes().
    static uint64_t committedBytes(const OldGenSpace& og) { return og.getCommittedBytes(); }
    /// Returns an FNV-1a hash over every block, in iteration order, of its used length, class, large
    /// flag, allocation state, live bytes and (except for large blocks) mark bitmap. Equal layouts
    /// give equal hashes.
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
    // ---- Concurrent marking ----

    /// Returns B, the number of background markers.
    static unsigned concThreads(const OldGenSpace& og) { return og.conc_threads_; }
    /// Returns F + B, the number of marker slots.
    static unsigned markSlots(const OldGenSpace& og) { return og.mark_slots_; }
    /// Returns where the background episode is.
    static OldGenSpace::BgEpisode bgEpisode(const OldGenSpace& og) { return og.bg_ep_; }
    /// Returns whether the background gang has been created.
    static bool hasBgGang(const OldGenSpace& og) { return og.bg_ != nullptr; }
    /// Returns the background gang, or null before the first launch.
    static gc::GCBackgroundGang* bgGang(OldGenSpace& og) { return og.bg_.get(); }
    /// Returns whether an episode is running and its gang looks finished.
    static bool bgFinishedApprox(const OldGenSpace& og) {
        return og.bg_ep_ == OldGenSpace::BgEpisode::Running && og.bg_->finishedApprox();
    }
    /// Stops and reaps a running episode.
    static void stopBackground(OldGenSpace& og) { og.stopBackground(); }
    /// Returns the grey entries of slot `i`, private and in its deque (the latter approximate).
    static size_t slotDequeSize(const OldGenSpace& og, unsigned i) {
        return og.markers_[i]->deque.sizeApprox() + og.markers_[i]->stack.size();
    }
    /// Returns the cycle's predicted mark units.
    static uint64_t cyclePredicted(const OldGenSpace& og) { return og.cycle_predicted_; }
    // ---- Trigger pacing ----

    /// Sets the promotion-rate estimate to `v`.
    static void setPromoRate(OldGenSpace& og, int64_t v) { og.p_hat_ = v; }
    /// Adds `b` to the bytes ever allocated.
    static void addOldAlloc(OldGenSpace& og, uint64_t b) { og.old_alloc_total_ += b; }
    /// Sets the live bytes of the last two majors and the post-sweep baseline.
    static void setLiveRefs(OldGenSpace& og, size_t major_live, size_t prev_major_live,
                            size_t post_sweep) {
        og.major_live_ = major_live;
        og.prev_major_live_ = prev_major_live;
        og.post_sweep_live_bytes_ = post_sweep;
    }
    /// Returns the allocated bytes.
    static size_t allocatedBytes(const OldGenSpace& og) { return og.allocated_bytes; }
    // ---- The markers ----

    /// Runs runMarkers(`budget`) and returns its units.
    static uint64_t runMarkers(OldGenSpace& og, int64_t budget) { return og.runMarkers(budget); }
    /// Returns markStackEmpty().
    static bool markStackEmpty(const OldGenSpace& og) { return og.markStackEmpty(); }
    /// Returns every slot's live-byte total.
    static uint64_t markLiveSum(const OldGenSpace& og) { return og.markLiveSum(); }
    /// Returns F, the number of foreground markers.
    static unsigned markThreads(const OldGenSpace& og) { return og.mark_threads_; }
    /// Returns whether the mark is on the parallel path.
    static bool markParallel(const OldGenSpace& og) { return og.mark_parallel_; }
    // ---- Mark cycles ----

    /// Returns whether `obj` is a marked old-generation object; false outside every block.
    static bool isMarked(OldGenSpace& og, const void* obj) {
        const BlockId id = og.contains(const_cast<void*>(obj)) ? og.blockIdFor(obj) : NO_BLOCK_ID;
        if (!id.valid()) return false;
        return og.blocks_.info(id).is_large ? og.blocks_.largeMark(id) != 0
                                            : og.isMarkedInBlock(id, obj);
    }
    /// Returns whether a mark cycle is running.
    static bool cycleActive(const OldGenSpace& og) { return og.cycleActive(); }
    /// Returns whether `obj` lies in a uniform block.
    static bool inUniformBlock(OldGenSpace& og, const void* obj) {
        const BlockId id = og.contains(const_cast<void*>(obj)) ? og.blockIdFor(obj) : NO_BLOCK_ID;
        if (!id.valid()) return false;
        const BlockInfo& b = og.blocks_.info(id);
        return !b.is_large && b.size_class < og.num_size_classes_;
    }
    /// Returns where the mark cycle is.
    static OldGenSpace::CycleState cycleState(const OldGenSpace& og) { return og.cycle_state_; }
    /// Returns the units marked this cycle.
    static uint64_t cycleUnits(const OldGenSpace& og) { return og.cycle_units_; }
    /// Returns the units the last cycle marked.
    static uint64_t prevCycleUnits(const OldGenSpace& og) { return og.prev_cycle_units_; }
    /// Returns the minor ends since t0.
    static uint32_t cycleK(const OldGenSpace& og) { return og.cycle_k_; }
    /// Returns the number of frees deferred to the handoff.
    static size_t deferredFrees(const OldGenSpace& og) { return og.deferred_frees_.size(); }
    /// Returns the live bytes the last major mark found.
    static size_t majorLive(const OldGenSpace& og) { return og.major_live_; }
    /// Returns the post-sweep baseline of the triggers.
    static size_t postSweepLive(const OldGenSpace& og) { return og.post_sweep_live_bytes_; }
    /// Returns the markers' live-byte sums taken at the last handoff.
    static size_t cycleTracedLive(const OldGenSpace& og) { return og.cycle_traced_live_; }
    /// Returns the phase.
    static GCPhase gcPhase(const OldGenSpace& og) { return og.gc_phase_; }
    /// Negative control: allocations skip setting their mark bit.
    static void setSkipAllocateBlack(OldGenSpace& og, bool on) { og.test_skip_allocate_black_ = on; }
    /// Returns evaluateMajorGCTrigger().
    static OldGenSpace::MajorGCTriggerReason trigger(const OldGenSpace& og) {
        return og.evaluateMajorGCTrigger();
    }
    /// Appends the extent [`start`, `end`) to the bag of pages, for a validator's negative test.
    static void pushUnassignedForTesting(OldGenSpace& og, char* start, char* end) {
        og.unassigned_blocks_.emplace_back(start, end);
    }
    /// Removes the last extent of the bag of pages.
    static void popUnassignedForTesting(OldGenSpace& og) { og.unassigned_blocks_.pop_back(); }

#if ENABLE_GC_STATS
    /// Starts a stop-the-world mark from `roots`, with no JIT roots.
    static void startMark(OldGenSpace& oldgen, const std::unordered_set<HPointer*>& roots,
                          Allocator& alloc, GCStats& stats) {
        std::unordered_set<uint64_t*> empty_jit_roots;
        oldgen.startMark(roots, empty_jit_roots, alloc, stats);
    }

    /// Starts a stop-the-world mark from `roots` and the raw words at `jit_roots`.
    static void startMark(OldGenSpace& oldgen, const std::unordered_set<HPointer*>& roots,
                          const std::unordered_set<uint64_t*>& jit_roots,
                          Allocator& alloc, GCStats& stats) {
        oldgen.startMark(roots, jit_roots, alloc, stats);
    }

    /// Runs incrementalMark().
    static bool incrementalMark(OldGenSpace& oldgen, size_t work_units, GCStats& stats) {
        return oldgen.incrementalMark(work_units, stats);
    }

    /// Runs finishMarkAndSweep().
    static void finishMarkAndSweep(OldGenSpace& oldgen, GCStats& stats) {
        oldgen.finishMarkAndSweep(stats);
    }
#else
    /// Starts a stop-the-world mark from `roots`, with no JIT roots.
    static void startMark(OldGenSpace& oldgen, const std::unordered_set<HPointer*>& roots,
                          Allocator& alloc) {
        std::unordered_set<uint64_t*> empty_jit_roots;
        oldgen.startMark(roots, empty_jit_roots, alloc);
    }

    /// Starts a stop-the-world mark from `roots` and the raw words at `jit_roots`.
    static void startMark(OldGenSpace& oldgen, const std::unordered_set<HPointer*>& roots,
                          const std::unordered_set<uint64_t*>& jit_roots,
                          Allocator& alloc) {
        oldgen.startMark(roots, jit_roots, alloc);
    }

    /// Runs incrementalMark().
    static bool incrementalMark(OldGenSpace& oldgen, size_t work_units) {
        return oldgen.incrementalMark(work_units);
    }

    /// Runs finishMarkAndSweep().
    static void finishMarkAndSweep(OldGenSpace& oldgen) {
        oldgen.finishMarkAndSweep();
    }
#endif

    /// Returns sizeClass(`size`).
    static size_t sizeClass(size_t size) { return OldGenSpace::sizeClass(size); }
    /// Returns classToSize(`cls`).
    static size_t classToSize(size_t cls) { return OldGenSpace::classToSize(cls); }
    /// Returns freeListClassFor(`span`).
    static size_t freeListClassFor(size_t span) {
        return OldGenSpace::freeListClassFor(span);
    }

    /// Returns the GC phase.
    static GCPhase getGCPhase(const OldGenSpace& oldgen) { return oldgen.gc_phase_; }
    /// Returns the compaction phase.
    static CompactionPhase getCompactPhase(const OldGenSpace& oldgen) { return oldgen.compact_phase_; }

    /// Returns the iteration position of the block being swept.
    static size_t getSweepBufferIndex(const OldGenSpace& oldgen) { return oldgen.sweep_buffer_index_; }
    /// Returns the sweep's address in that block.
    static const char* getSweepCursor(const OldGenSpace& oldgen) { return oldgen.sweep_cursor_; }
    /// Returns the blocks still to sweep.
    static size_t getSweepPendingBlocks(const OldGenSpace& oldgen) {
        return oldgen.sweep_pending_blocks_;
    }
    /// Returns the blocks the sweep started with.
    static size_t getSweepTotalBlocks(const OldGenSpace& oldgen) {
        return oldgen.sweep_total_blocks_;
    }
    /// Returns hasPendingSweepWork().
    static bool hasPendingSweepWork(const OldGenSpace& oldgen) {
        return oldgen.hasPendingSweepWork();
    }
    /// Returns sweepComplete().
    static bool sweepComplete(const OldGenSpace& oldgen) {
        return oldgen.sweepComplete();
    }

    /// Returns computeSweepBudgetForAlloc(`requested_size`).
    static size_t computeSweepBudgetForAlloc(OldGenSpace& oldgen,
                                             size_t requested_size) {
        return oldgen.computeSweepBudgetForAlloc(requested_size);
    }
    /// Returns committedToCapRatio().
    static double committedToCapRatio(const OldGenSpace& oldgen) {
        return oldgen.committedToCapRatio();
    }

    /// Empties the bag of pages without giving the pages back, and returns how many it held, so that
    /// a test can reach the state where the old generation cannot grow. The caller must not touch the
    /// dropped pages.
    static size_t drainUnassignedBlocksForTest(OldGenSpace& oldgen) {
        size_t n = oldgen.unassigned_blocks_.size();
        oldgen.unassigned_blocks_.clear();
        return n;
    }

    /// Returns the fragmentation statistics.
    static const FragmentationStats& getFragStats(const OldGenSpace& oldgen) { return oldgen.frag_stats_; }

    /// Returns the block class `cls`'s cursor is in, or NO_BLOCK_ID.
    static BlockId cursorBlock(const OldGenSpace& og, size_t cls) {
        return og.cursor_[cls].block;
    }
    /// Returns the number of blocks waiting in class `cls`'s queue.
    static size_t partialQueueLength(const OldGenSpace& og, size_t cls) {
        return og.partial_[cls].size() - og.partial_head_[cls];
    }
    /// Returns the first block waiting in class `cls`'s queue, or NO_BLOCK_ID.
    static BlockId partialFront(const OldGenSpace& og, size_t cls) {
        return og.partial_head_[cls] < og.partial_[cls].size() ? og.partial_[cls][og.partial_head_[cls]]
                                                                : NO_BLOCK_ID;
    }
    /// Returns a copy of class `cls`'s queue, oldest first.
    static std::vector<BlockId> partialQueue(const OldGenSpace& og, size_t cls) {
        return std::vector<BlockId>(og.partial_[cls].begin() + static_cast<std::ptrdiff_t>(og.partial_head_[cls]),
                                    og.partial_[cls].end());
    }
    /// Runs the light shrink toward `desired` bytes.
    static void lightShrink(OldGenSpace& og, size_t desired) {
        og.maybeShrinkCapacity(desired, OldGenSpace::ShrinkPass::Light);
    }
    /// Runs allocateFromEmptyRegularBlocks(`size`).
    static void* allocFromEmptyRegular(OldGenSpace& og, size_t size) { return og.allocateFromEmptyRegularBlocks(size); }
    /// Returns whether `id` names a live block.
    static bool blockLive(const OldGenSpace& og, BlockId id) { return og.blocks_.isLive(id); }
    /// The allocation state of a block granted to a tenure job.
    static constexpr uint8_t kAllocTenure = OldGenSpace::kAllocTenure;
    /// Returns the number of cells in uniform block `id`.
    static uint32_t cellsIn(const OldGenSpace& og, BlockId id) { return OldGenSpace::cellsIn(og.blocks_.info(id)); }
    /// Returns block `id`'s allocation state.
    static uint8_t allocState(const OldGenSpace& og, BlockId id) {
        return og.blocks_.info(id).alloc_state;
    }
    /// Releases block `id` to the Allocator.
    static void releaseBlock(OldGenSpace& og, BlockId id) {
        og.releaseBlockToAllocator(id);
    }
    /// Sweeps until the phase is no longer Sweeping.
    static void driveSweepToCompletion(OldGenSpace& og) {
        while (og.gc_phase_ == GCPhase::Sweeping) {
            og.lazySweep(NUM_SIZE_CLASSES, std::numeric_limits<size_t>::max() / 2);
        }
    }
    /// Returns whether block `id` has been demoted (or was never uniform).
    static bool demoted(const OldGenSpace& og, BlockId id) {
        return og.blocks_.info(id).size_class >= og.num_size_classes_;
    }
    /// Returns block `id`'s metadata, after adding the cursors' pending bytes.
    static const BufferMetadata& metaOf(OldGenSpace& og, BlockId id) {
        og.syncCursorLiveBytes();
        return og.blocks_.meta(id);
    }
    /// Returns the bytes of free-list cells that start in [`lo`, `hi`).
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
    /// Returns whether every class cursor's block is live and Current and every queued block is live
    /// and Queued.
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
    /// Returns the bitmap-allocation statistics, after adding the cursors' pending bytes.
    static const BitmapAllocStats& bitmapStats(OldGenSpace& og) {
        og.syncCursorLiveBytes();
        return og.alloc_stats_.bm;
    }
#endif
    /// Returns the number of size classes in use.
    static size_t numSizeClasses(const OldGenSpace& og) { return og.num_size_classes_; }
    /// Returns sweepWillReach(`id`, `a`).
    static bool sweepWillReach(const OldGenSpace& og, BlockId id, const void* a) {
        return og.sweepWillReach(id, static_cast<const char*>(a));
    }

    /// Returns whether every free cell of 24 bytes or more links to its actual predecessor in its
    /// class list (null at the head).
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

    /// Returns the head of class `cls`'s free list. `cls` must be below NUM_SIZE_CLASSES (asserted).
    static FreeCell* getFreeList(const OldGenSpace& oldgen, size_t cls) {
        assert(cls < NUM_SIZE_CLASSES && "getFreeList: invalid size class (>= NUM_SIZE_CLASSES)");
        return oldgen.free_lists_[cls];
    }

    // ---- Blocks by iteration position ----

    /// Returns the number of live blocks.
    static size_t blockCount(const OldGenSpace& oldgen) {
        return oldgen.blocks_.size();
    }
    /// Returns the id of the block at position `pos`.
    static BlockId blockIdAt(const OldGenSpace& oldgen, size_t pos) {
        return oldgen.blocks_.idAt(pos);
    }
    /// Returns the description of the block at position `pos`.
    static const BlockInfo& blockInfoAt(const OldGenSpace& oldgen, size_t pos) {
        return oldgen.blocks_.info(oldgen.blocks_.idAt(pos));
    }
    /// Returns the metadata of the block at position `pos`.
    static const BufferMetadata& bufferMetaAt(const OldGenSpace& oldgen,
                                              size_t pos) {
        return oldgen.blocks_.meta(oldgen.blocks_.idAt(pos));
    }
    /// Returns the block table.
    static const BlockTable& getBlockTable(const OldGenSpace& oldgen) {
        return oldgen.blocks_;
    }
    /// Returns a copy of every block's description, element i for position i.
    static std::vector<BlockInfo> getBlocks(const OldGenSpace& oldgen) {
        std::vector<BlockInfo> v;
        v.reserve(oldgen.blocks_.size());
        for (size_t pos = 0; pos < oldgen.blocks_.size(); ++pos) {
            v.push_back(oldgen.blocks_.info(oldgen.blocks_.idAt(pos)));
        }
        return v;
    }
    /// Returns a copy of every block's metadata, element i for position i.
    static std::vector<BufferMetadata> getBufferMeta(const OldGenSpace& oldgen) {
        std::vector<BufferMetadata> v;
        v.reserve(oldgen.blocks_.size());
        for (size_t pos = 0; pos < oldgen.blocks_.size(); ++pos) {
            v.push_back(oldgen.blocks_.meta(oldgen.blocks_.idAt(pos)));
        }
        return v;
    }
    /// Returns the bag of pages.
    static const std::vector<std::pair<char*, char*>>& getUnassignedBlocks(
            const OldGenSpace& oldgen) {
        return oldgen.unassigned_blocks_;
    }
    /// Returns the freed large blocks waiting for reuse.
    static const std::vector<BlockId>& getFreeLargeBlocks(
            const OldGenSpace& oldgen) {
        return oldgen.free_large_blocks_;
    }

    /// Enters the Sweeping phase.
    static void transitionToSweeping(OldGenSpace& oldgen) { oldgen.transitionToSweeping(); }
    /// Runs lazySweep(`target_class`, `work_budget`).
    static void lazySweep(OldGenSpace& oldgen, size_t target_class, size_t work_budget) {
        oldgen.lazySweep(target_class, work_budget);
    }

    /// Returns blockIdFor(`obj`).
    static BlockId blockIdFor(const OldGenSpace& oldgen, const void* obj) {
        return oldgen.blockIdFor(obj);
    }
    /// Returns the page index.
    static const ReservedArray<OldGenSpace::PageOwners>& getPageIndex(
            const OldGenSpace& oldgen) {
        return oldgen.page_index_;
    }

    /// Returns block `id`'s mark bitmap and sets `*len_out` to its length in bytes.
    static const uint8_t* getMarkBitsForBlock(
            const OldGenSpace& oldgen, BlockId id, size_t* len_out) {
        *len_out = oldgen.mark_.len(id);
        return oldgen.mark_.slot(id);
    }
    /// Returns large block `id`'s mark byte.
    static uint8_t getLargeBlockMark(const OldGenSpace& oldgen, BlockId id) {
        return oldgen.blocks_.largeMark(id);
    }
    /// Returns whether `obj` is marked; false outside every block.
    static bool isObjectMarked(const OldGenSpace& oldgen, void* obj) {
        if (!oldgen.contains(obj)) return false;
        const BlockId id = oldgen.blockIdFor(obj);
        if (!id.valid()) return false;
        return oldgen.isMarkedInBlock(id, obj);
    }
    /// Sets `obj`'s mark bit and returns whether it was clear; false outside every block.
    static bool setObjectMark(OldGenSpace& oldgen, void* obj) {
        if (!oldgen.contains(obj)) return false;
        const BlockId id = oldgen.blockIdFor(obj);
        if (!id.valid()) return false;
        return oldgen.setMarkBitInBlock(id, obj);
    }

    /// Runs resetBufferMetaForMark().
    static void resetBufferMetaForMark(OldGenSpace& oldgen) {
        oldgen.resetBufferMetaForMark();
    }
    /// Runs finalizeMetaAfterMark().
    static void finalizeMetaAfterMark(OldGenSpace& oldgen) {
        oldgen.finalizeMetaAfterMark();
    }

    /// Runs reclaimAllDeadBlocksFromMeta().
    static OldGenSpace::AllDeadReclaimStats reclaimAllDeadBlocksFromMeta(
            OldGenSpace& oldgen) {
        return oldgen.reclaimAllDeadBlocksFromMeta();
    }

    /// Returns the bytes of uniform small-class blocks.
    static size_t getSmallClassBytes(const OldGenSpace& oldgen) {
        return oldgen.small_class_bytes_;
    }
    /// Returns the first class index not counted as small.
    static size_t getSmallClassIndexLimit(const OldGenSpace& oldgen) {
        return oldgen.small_class_index_limit_;
    }
    /// Returns shouldPreferBagForSmallClass(`cls`).
    static bool shouldPreferBagForSmallClass(const OldGenSpace& oldgen,
                                             size_t cls) {
        return oldgen.shouldPreferBagForSmallClass(cls);
    }

    /// Returns the large-object table.
    static const std::vector<OldGenSpace::LargeBodyMeta>& getLargeBodies(
            const OldGenSpace& oldgen) {
        return oldgen.large_bodies_;
    }
    /// Returns the ids of the nursery-owned entries.
    static const std::vector<OldGenSpace::LargeBodyId>& getNurseryOwnedBodies(
            const OldGenSpace& oldgen) {
        return oldgen.nursery_owned_bodies_;
    }
    /// Returns whether `body` is in the large-object index.
    static bool isBodyTracked(const OldGenSpace& oldgen, void* body) {
        return oldgen.large_body_index_.find(body) !=
               oldgen.large_body_index_.end();
    }

    // ---- Compaction, which only these functions start ----

    /// Runs scheduleCompaction().
    static void scheduleCompaction(OldGenSpace& oldgen) { oldgen.scheduleCompaction(); }
    /// Runs incrementalCompactionSlice(`work_budget`).
    static void incrementalCompactionSlice(OldGenSpace& oldgen, size_t work_budget) {
        oldgen.incrementalCompactionSlice(work_budget);
    }
    /// Returns the blocks selected for evacuation.
    static const std::vector<BlockId>& getEvacuationSet(const OldGenSpace& oldgen) {
        return oldgen.evacuation_set_;
    }
    /// Returns getForwardingAddress(`obj`).
    static void* getForwardingAddress(const OldGenSpace& oldgen, void* obj) {
        return oldgen.getForwardingAddress(obj);
    }
};

} // namespace Elm

#endif // ECO_OLDGENSPACE_H
