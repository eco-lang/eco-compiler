/**
 * OldGenSpace Implementation.
 *
 * Implements the old generation as a segregated-fits allocator backed by a
 * "Big Bag of Pages" (BBoP). See OldGenSpace.hpp for the full design.
 *
 * Single-threaded (one instance per thread).
 */

#include "OldGenSpace.hpp"
#include "GCHelperPool.hpp"
#include "HeapChildWalk.hpp"
#include "TlaTrace.hpp"   // compiled-out hooks (trace builds only)
#include <mutex>
#include "Allocator.hpp"
#include "NurserySpace.hpp"
#include "BitmapScan.hpp"
#include "P1Census.hpp"
#include <chrono>
#include <limits>
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

// W0 item 48: ECO_OLDGEN_DEBUG, read once at namespace scope. It used to be
// two function-local `static const bool`s — one in pushSpanOnFreeLists (per
// coalesced run) and one in sweep() — and a function-local static with dynamic
// initialisation costs a guard-variable atomic load plus a branch on EVERY
// call. Namespace-scope dynamic initialisation runs before main, so reads here
// are a plain load.
namespace {
const bool g_oldgen_debug = std::getenv("ECO_OLDGEN_DEBUG") != nullptr;
}
#include <functional>
#include <unordered_map>
#include <unordered_set>

namespace Elm {

// Global heap base (defined in Allocator.cpp).
extern char* g_heap_base;

// M6's trace-build switch (defined in GCHelperPool.cpp): its probe below fires only while set.
ECO_TLA_TRACE_ONLY(namespace gc { extern bool tla_m6; })

// M4 trace hooks (test/tla/M4-promotion-bitmap/TracePromoBitmap.tla; plans/
// threaded-gc-tla-M4-promotion-bitmap.md §8). Compiled out except in trace
// builds, and even there recorded only while the M4 harness sets tla_m4 (other
// harnesses leave it off, so these events and their ordering fields never enter
// their logs). tla_m4_tick is the promo_mu_ clock: only touched under the lock.
ECO_TLA_TRACE_ONLY(bool tla_m4 = false; int64_t tla_m4_tick = 0; thread_local int64_t tla_m4_flip = -1;)
#define ECO_M4_TRACE(...) ECO_TLA_TRACE_ONLY(if (::Elm::tla_m4)) ECO_TLA_TRACE(__VA_ARGS__)
// A cell of an OldGenSpace member's heap, as the M4 trace names it: its block
// id and the index of its first mark bit in that block (used in hooks only).
#define ECO_M4_BLK(p) blockIdFor(p).v
#define ECO_M4_BIT(p) static_cast<int64_t>((reinterpret_cast<const char*>(p) - \
                          blocks_.info(blockIdFor(p)).start) / MARK_ALIGNMENT)

// Forward decl — defined later in this TU; called from member functions
// above the definition.
namespace {
inline void pushSpanOnFreeLists(FreeCell** free_lists, char* span_start,
                                size_t span_bytes,
                                BlockInfo* block,
                                BlockId block_index,
                                bool age_sentinel = false);


#if ECO_HEAP_VALIDATE
// Origin tracking for free-list pushes. `g_push_origin` is set by the
// caller of pushSpanOnFreeLists right before each call; placeAndLink reads
// it when recording into `g_first_push` (cell -> first-push-origin map).
// On a duplicate push, placeAndLink looks the cell up and reports the
// original pusher's site identifier, which pins which call site
// originally placed the cell on the free list.
//
// Set of origin strings (each push site uses a unique literal):
//   "lazySweep::flushRun" — coalesced runs from sweep
//   "populateFromBlock::uniform-page"
//   "populateFromBlock::heap-base-mixed"
//   "populateMixed::remainder"
//   "splitter::remainder"
//   "freeLargeBodyCell"
//   "unknown" (fallback if a caller forgets to set the thread-local)
//
// Deliberately thread_local (HEAP_053): validator diagnostics describing what
// THIS worker is pushing. g_first_push_origin is heap-level history and is
// revisited when promotion goes parallel (threaded-gc phase 6).
thread_local const char* g_push_origin = "unknown";
thread_local std::unordered_map<void*, const char*> g_first_push_origin;

struct PushOriginScope {
    const char* prev;
    explicit PushOriginScope(const char* name) : prev(g_push_origin) {
        g_push_origin = name;
    }
    ~PushOriginScope() { g_push_origin = prev; }
};
#endif

// ====================================================================
// Tier-M per-block-thread helpers.
//
// A cell is Tier-M when its byte size is >= MIN_TIER_M_SIZE (24 B). Such
// a cell's last 4 bytes carry next_in_block / prev_in_block (16-bit
// offsets/8 within its owning block), and its bytes 16..19 carry the low
// 32 bits of its prev-in-class back-link (P§3.7 / HEAP_052; the high bits
// live in the cell's own Header.refcount). Class 1 (16 B) cells are
// Tier-S — those fields don't exist, callers must dispatch on size.
// ====================================================================

inline bool isTierM(const FreeCell* cell) {
    return cell->header.size >= MIN_TIER_M_SIZE;
}
inline bool isTierMSize(size_t bytes) { return bytes >= MIN_TIER_M_SIZE; }

inline FreeCellMid* asTierM(FreeCell* c) {
    return reinterpret_cast<FreeCellMid*>(c);
}

// Resolve a 16-bit per-block offset (offset/8 from blk.start) to a
// FreeCell*. Returns nullptr for FREE_CELLS_EMPTY.
inline FreeCell* resolveOff(const BlockInfo& blk, uint16_t off) {
    return (off == FREE_CELLS_EMPTY)
        ? nullptr
        : reinterpret_cast<FreeCell*>(blk.start + size_t(off) * 8);
}

// Encode a FreeCell* address as a 16-bit offset/8 within `blk`.
// Caller ensures `c != nullptr` and `c` lies inside [blk.start, blk.end).
inline uint16_t encodeOff(const BlockInfo& blk, const FreeCell* c) {
    if (c == nullptr) return FREE_CELLS_EMPTY;
    const size_t bytes =
        static_cast<size_t>(reinterpret_cast<const char*>(c) - blk.start);
    return static_cast<uint16_t>(bytes / 8);
}

// Free-list back-link helpers (setPrevHead / setPrev / copyPrev / getPrev)
// live in OldGenSpace.hpp next to FreeCellMid (HEAP_052).

// Tier-M only: link `c` at the head of `blk.free_cells_in_block`.
inline void blockThreadPushHead(BlockInfo& blk, FreeCell* c) {
    FreeCellMid* m = asTierM(c);
    const uint16_t old_head = blk.free_cells_in_block;
    m->prev_in_block = FREE_CELLS_EMPTY;
    m->next_in_block = old_head;
    if (old_head != FREE_CELLS_EMPTY) {
        asTierM(resolveOff(blk, old_head))->prev_in_block = encodeOff(blk, c);
    }
    blk.free_cells_in_block = encodeOff(blk, c);
}

// Tier-M only: unlink `c` from its block thread. O(1).
inline void blockThreadUnlink(BlockInfo& blk, FreeCell* c) {
    FreeCellMid* m = asTierM(c);
    if (m->prev_in_block == FREE_CELLS_EMPTY) {
        blk.free_cells_in_block = m->next_in_block;
    } else {
        asTierM(resolveOff(blk, m->prev_in_block))->next_in_block =
            m->next_in_block;
    }
    if (m->next_in_block != FREE_CELLS_EMPTY) {
        asTierM(resolveOff(blk, m->next_in_block))->prev_in_block =
            m->prev_in_block;
    }
}

// Tier-M only: O(1) class-list unlink via the cell's back-link (HEAP_052).
// Caller has already ensured `c` is on `free_lists[cls]` and is Tier-M.
inline void classListUnlinkTierM(FreeCell** free_lists, FreeCell* c,
                                 size_t cls) {
    FreeCellMid* m = asTierM(c);
    FreeCell* prev = getPrev(m);
    if (prev == nullptr) {
        // c was the head of free_lists[cls].
        free_lists[cls] = m->next_in_class;
    } else {
        prev->next_in_class = m->next_in_class;
    }
    if (m->next_in_class != nullptr) {
        // Successor's prev becomes whatever c's prev was (head sentinel
        // or the predecessor handle).
        copyPrev(asTierM(m->next_in_class), m);
    }
}

}  // namespace

// Read barrier - converts logical pointer to physical address.
// Does not follow forwarding pointers (use Allocator::resolve() for that).
void* readBarrier(HPointer& ptr) {
    // Check for embedded constants.
    assert(ptr.ptr_ind == 0 && "Cannot read barrier on embedded constant");

    // The HPointer word IS the raw absolute address (no heap_base, no shift).
    return hpToAddr(ptr);
}

// Sentinel value indicating no current block.
static constexpr size_t NO_BLOCK = std::numeric_limits<size_t>::max();

// Bytes to advance per step when walking a block linearly. Size-class
// blocks reserve a fixed cell per object (slack between the object's
// logical size and the cell boundary belongs to that allocation), so the
// walk must advance by the cell size, not the object's logical size, or
// it will land mid-cell and start parsing FreeCell.next pointers as if
// they were object headers. Bag pages and large blocks pack tightly, so
// they advance by the object's logical size.
//
// Hoisted to file scope so member functions (markOneObject, sweep,
// lazySweep, evacuateSlice, fixReferencesSlice) can all share it.
static inline size_t walkStepFor(const BlockInfo& block, size_t obj_size) {
    if (block.size_class < NUM_SIZE_CLASSES) {
        return OldGenSpaceTestAccess::classToSize(block.size_class);
    }
    return obj_size;
}

OldGenSpace::OldGenSpace() :
    config_(nullptr), allocator_(nullptr),
    num_size_classes_(NUM_SMALL_CLASSES),
    allocated_bytes(0),
    region_base_(nullptr), region_end_(nullptr),
    gc_phase_(GCPhase::Idle),
    current_epoch(0), marking_active(false), allocator_ref_(nullptr),
    sweep_buffer_index_(0), sweep_cursor_(nullptr),
    sweep_pending_blocks_(0),
    sweep_total_blocks_(0),
    frag_stats_{0, 0, 0},
    compact_phase_(CompactionPhase::Idle),
    current_evac_index_(0), evac_cursor_(nullptr),
    evac_block_index_(NO_BLOCK_ID), evac_alloc_ptr_(nullptr),
    fixup_buffer_index_(0), fixup_cursor_(nullptr),
    small_class_bytes_(0),
    small_class_index_limit_(0) {
    // Initialize free lists to empty.
    for (size_t i = 0; i < NUM_SIZE_CLASSES; i++) {
        free_lists_[i] = nullptr;
    }
    ensureMarkers();   // threaded-gc-05b: worker 0 always exists
}

// TLA-REGION(OGS.destructor) begin
OldGenSpace::~OldGenSpace() {
    // threaded-gc-05c: no background member may outlive the state it reads
    // (bg_ctl_ is destroyed before bg_; stop explicitly first).
    if (bg_) bg_->stopAndJoin();
    bg_.reset();
    // Memory blocks are owned by the Allocator's mmap region, not us.
    // Release our metadata reservations (HEAP_048).
    unassigned_blocks_.clear();
    blocks_.releaseStorage();
    mark_.release();
    page_index_.release();
    for (unsigned i = 0; i < kMaxMarkers; ++i) {
        if (markers_[i]) markers_[i]->live.release();
    }
}
// TLA-REGION(OGS.destructor) end

OldGenSpace::OldGenGeometry
OldGenSpace::geometryFor(size_t reservation_bytes, size_t page) {
    OldGenGeometry g;
    g.max_blocks = (page == 0) ? 0 : reservation_bytes / page + 1;
    g.index_slots = (page == 0) ? 0 : reservation_bytes / page + 2;
    g.stride = ((page / MARK_ALIGNMENT + 7) / 8 + 63) & ~size_t{63};
    g.mark_arena_bytes = g.max_blocks * g.stride;
    return g;
}

void OldGenSpace::reserveMetadata() {
    const size_t reservation = allocator_->getOldGenReservationBytes();
    const OldGenGeometry g =
        geometryFor(reservation, config_->alloc_buffer_size);
    index_base_ = allocator_->getHeapBase();
    // threaded-gc-05b: one accumulator per marker (HEAP_051 / HEAP_064).
    mark_threads_ = resolveMarkThreads(*config_);
    minor_threads_ = resolveMinorThreads(*config_);   // threaded-gc-06
    // threaded-gc-05c (HEAP_065): background slots after the foreground ones.
    conc_threads_ = resolveConcMarkThreads(*config_, mark_threads_);
    mark_slots_ = mark_threads_ + conc_threads_;
    ensureMarkers();
    bool live_ok = true;
    for (unsigned i = 0; i < mark_slots_; ++i) {
        live_ok = live_ok && markers_[i]->live.reserve(g.max_blocks);
    }
    if (!blocks_.reserve(g.max_blocks) || !mark_.reserve(g.max_blocks, g.stride) ||
        !page_index_.reserve(g.index_slots) || !live_ok) {
        std::fprintf(stderr,
            "[oldgen] metadata VA reservation failed (reservation=%zu B, "
            "page=%zu B: %zu block ids, %zu index slots, %zu B mark arena)\n",
            reservation, config_->alloc_buffer_size, g.max_blocks,
            g.index_slots, g.mark_arena_bytes);
        std::abort();
    }
    reserved_page_size_ = config_->alloc_buffer_size;
#if ECO_HEAP_VALIDATE
    for (int k = 0; k < BlockTable::kStorageArrays; ++k) {
        storage_bases_[k] = blocks_.storageBase(k);
    }
    storage_bases_[BlockTable::kStorageArrays] = mark_.storageBase();
    storage_bases_[BlockTable::kStorageArrays + 1] = page_index_.data();
    storage_bases_[BlockTable::kStorageArrays + 2] = w0().live.storageBase();
#endif
}

// Computes runtime number of size classes from `large_object_threshold`. The
// size-class fast path covers cell sizes up to (and including) the largest
// power-of-two <= LOT; sizes above that fall through to the page-as-single-cell
// + split path.
static size_t computeNumSizeClasses(size_t large_object_threshold) {
    size_t count = NUM_SMALL_CLASSES;
    size_t cell = MEDIUM_CLASS_BASE;
    for (size_t i = 0; i < NUM_MEDIUM_CLASSES_MAX; ++i) {
        if (cell > large_object_threshold) break;
        ++count;
        cell <<= 1;
    }
    return count;
}

void OldGenSpace::initialize(Allocator* allocator, const HeapConfig* config) {
    config_ = config;
    allocator_ = allocator;
    num_size_classes_ = computeNumSizeClasses(config_->large_object_threshold);
    allocated_bytes = 0;
    small_class_bytes_ = 0;
    recomputeSmallClassLimit();

    // Tier-M per-block-thread bounds on alloc_buffer_size: every cell sits
    // at byte-offset 8N from block.start with N < 65535, so the page byte
    // size must be at most 524288 (2^19). Enforced unconditionally because
    // it depends only on the chosen page size, not on actual heap growth.
    if (config_->alloc_buffer_size > (size_t{1} << 19)) {
        std::fprintf(stderr,
            "[oldgen] alloc_buffer_size (%zu B) exceeds 524288 B; the "
            "16-bit per-cell offset field cannot encode addresses past "
            "this within a block.\n",
            config_->alloc_buffer_size);
        std::abort();
    }
    // threaded-gc-01: there is no block-count bound any more. Free-list
    // back-links are addresses (HEAP_052), not 16-bit block indices. Every
    // metadata table is VA-reserved here for the maximum possible block
    // count (old-gen reservation / alloc_buffer_size + 1) and never moves.
    assert(allocator_ != nullptr && "OldGenSpace requires an Allocator");
    if (allocator_ != nullptr) reserveMetadata();

    // Pre-commit the initial region as one contiguous mmap, then slice into
    // pages and push each page extent into the bag of unassigned blocks.
    // HeapConfig::validate has already enforced
    // initial_old_gen_size % alloc_buffer_size == 0.
    const size_t page_size = config_->alloc_buffer_size;
    const size_t initial_size = config_->initial_old_gen_size;

    if (initial_size > 0 && page_size > 0 && allocator_ != nullptr) {
        char* region_base = allocator_->acquireOldGenRegion(initial_size, initial_size);
        if (region_base != nullptr) {
            setRegionBase(region_base);
            setRegionEnd(region_base + initial_size);

            const size_t num_pages = initial_size / page_size;
            unassigned_blocks_.reserve(num_pages);
            for (size_t i = 0; i < num_pages; ++i) {
                char* page_start = region_base + i * page_size;
                char* page_end = page_start + page_size;
                // Page 0 starts at heap_base; it is materialized like any other
                // page (no special offset-0 handling — the heap-base sentinel
                // was removed once HPointers became absolute addresses, D5).
                unassigned_blocks_.emplace_back(page_start, page_end);
            }

            // Step 1: size the page-index for the committed region. All
            // pages start as bag pages (no blocks_ entry), so every slot
            // is NO_BLOCK at this point.
            resizePageIndexForRegion();
        }
    }
}

// contains() is now inline in the header.

// TLA-REGION(OGS.reset) begin
void OldGenSpace::reset(const HeapConfig* new_config) {
    // threaded-gc-05c: stop a running background episode before anything it
    // reads is torn down; the gang is recreated for the new configuration.
    if (bg_) bg_->stopAndJoin();
#if ECO_HEAP_VALIDATE
    assertSlotsQuiescent("reset");   // IM14: every slot is cleared below
#endif
    bg_.reset();
    bg_ctl_.reset();
    bg_ep_ = BgEpisode::None;
    fg_run_active_ = false;
    for (unsigned i = 0; i < kMaxMarkers; ++i) {
        if (!markers_[i]) continue;
        markers_[i]->stack.clear();
        markers_[i]->priv.store(0, std::memory_order_relaxed);
        while (markers_[i]->deque.take() != markwork::kEmpty) {}
        markers_[i]->deque.reset();
    }
#if ECO_HEAP_VALIDATE
    im10_armed_.store(false, std::memory_order_release);
#endif
    // Update config if provided.
    if (new_config) {
        config_ = new_config;
        num_size_classes_ = computeNumSizeClasses(config_->large_object_threshold);
    }

    // Memory blocks are owned by Allocator's mmap region - just clear tracking.
    // The metadata reservations are re-made (fresh, zero) so ids restart at
    // 0 and no stale page-index owner or mark bit survives (F16: reset() has
    // no caller today; kept correct).
    blocks_.clear();
    unassigned_blocks_.clear();
    if (allocator_ != nullptr) reserveMetadata();
    for (size_t c = 0; c < NUM_SIZE_CLASSES; ++c) {
        cursor_[c] = AllocCursor{};
        partial_[c].clear();
        partial_head_[c] = 0;
    }

    // Reset state.
    allocated_bytes = 0;
    setRegionBase(nullptr);
    setRegionEnd(nullptr);
    gc_phase_ = GCPhase::Idle;
    marking_active = false;
    // threaded-gc-05c Part B.
    old_alloc_total_ = 0;
    old_alloc_at_prev_minor_ = 0;
    p_hat_ = 0;
    pacing_t0_ = PacingAtT0{};
    // threaded-gc-05a: drop any running cycle.
    cycle_state_ = CycleState::Idle;
    snapshot_mode_ = false;
    in_slice_ = false;
    cycle_tail_uses_traced_live_ = false;
    cycle_slices_ = 0;
    cycle_k_ = 0;
    cycle_predicted_ = 0;
    cycle_units_ = 0;
    prev_cycle_units_ = 0;
    prev_cycle_occ_t0_ = 0;
    cycle_black_bytes_ = 0;
    baseline_black_bytes_ = 0;
    cycle_traced_live_ = 0;
    deferred_frees_.clear();
#if ECO_HEAP_VALIDATE
    cycle_alloc_log_.clear();
    cycle_t0_blocks_.clear();
#endif
    current_epoch = 0;
    w0().stack.clear();
    batch_release_depth_ = 0;
    in_minor_gc_ = false;
    sweep_buffer_index_ = 0;
    sweep_cursor_ = nullptr;
    sweep_pending_blocks_ = 0;
    sweep_total_blocks_ = 0;
    small_class_bytes_ = 0;
    recomputeSmallClassLimit();

    // Clear all free lists.
    for (size_t i = 0; i < NUM_SIZE_CLASSES; i++) {
        free_lists_[i] = nullptr;
    }
    free_list_sentinel_count_ = 0;
    free_large_blocks_.clear();

    // Clear split-header body tracking.
    large_bodies_.clear();
    large_body_index_.clear();
    nursery_owned_bodies_.clear();
    free_large_body_ids_.clear();
    ylo_lo_ = ylo_hi_ = nullptr;
    ylo_count_ = 0;

    // Reset fragmentation stats.
    frag_stats_ = {0, 0, 0};

    // Reset compaction state.
    compact_phase_ = CompactionPhase::Idle;
    evacuation_set_.clear();
    current_evac_index_ = 0;
    evac_cursor_ = nullptr;
    evac_block_index_ = NO_BLOCK_ID;
    evac_alloc_ptr_ = nullptr;
    fixup_buffer_index_ = 0;
    fixup_cursor_ = nullptr;
}
// TLA-REGION(OGS.reset) end

// ---------------------------------------------------------------------------
// Header initialization helper.
// ---------------------------------------------------------------------------
void OldGenSpace::initObjectHeader(void* obj) {
    initObjectHeaderWithSize(obj, 0);
}

// `cell_bytes` is the number of bytes occupied by this cell (size-class slot
// size for size-class blocks, the requested size for large blocks). When
// non-zero, the cell's bytes are added to the owning block's `live_bytes` in
// EVERY phase (CR-018, HEAP_073): a block refilled after its sweep must not
// read as all-dead to the empty-block flip, the reclaim or the shrink, which
// trust `live_bytes == 0` (resetBufferMetaForMark zeroes it at every mark, and
// every reader between a sweep and the next mark treats it as an upper
// bound). Only mid-cycle (marking_active || gc_phase_ != Idle) is the cell
// black with its mark bit set: mark-time `live_bytes` attribution only covers
// cells discovered by `markOneObject`; mid-cycle cells bypass mark.
// TLA-REGION(OGS.initObjectHeaderWithSize) begin
void OldGenSpace::initObjectHeaderWithSize(void* obj, size_t cell_bytes) {
    // Note: an object at heap_base+0 is fine under absolute addressing — its
    // HPointer word equals heap_base, a valid non-null pointer (the heap is
    // reserved at a high base). The former heap-base sentinel is removed (D5).
    Header* hdr = reinterpret_cast<Header*>(obj);
    std::memset(hdr, 0, sizeof(Header));
    // Mid-cycle allocations must survive the current sweep cycle. With
    // bitmap liveness, that means setting the bit for this slot. The
    // header color is no longer load-bearing for sweep, but we keep
    // writing it so any debug asserts that still inspect color stay valid.
    // Callers hold promo_mu_ or run serially, so gc_phase_ is read plain here.
    const bool black = marking_active || gc_phase_ != GCPhase::Idle;
    hdr->color = static_cast<u32>(black ? Color::Black : Color::White);
    if (!black && cell_bytes == 0) return;   // Idle large paths: nothing to do
    if (!contains(obj)) return;
    const BlockId block_id = blockIdFor(obj);
    if (!block_id.valid()) return;
    if (black) {
#if ECO_HEAP_VALIDATE
        if (blocks_.info(block_id).alloc_state == kAllocTenure) {   // threaded-gc-07 TV5
            std::fprintf(stderr, "[heap-validate] TV5: a mutator allocation in tenure-granted "
                         "block %u\n", block_id.v);
            std::fflush(stderr);
            std::abort();
        }
#endif
#if ECO_HEAP_VALIDATE
        assertCellWasWhite(block_id, obj);   // IM4
#endif
        // threaded-gc-05c (H1): atomic -- a background marker may
        // be setting other bits of this byte (a t0 mixed block).
        if (__builtin_expect(test_plain_allocate_black_, 0))   // negative control
            setMarkBitInBlock(block_id, obj);
        else if (!test_skip_allocate_black_)      // negative-control hook only
            setMarkBitAtomic(block_id, obj);
    }
    // CR-018 (HEAP_073): attribute the cell's bytes in EVERY phase, so a block
    // that holds only cells allocated since its sweep isn't seen as all-dead by
    // the flip, the reclaim or the shrink. Owner-side write (HEAP_051).
    // test_idle_uncounted_ is the negative control (the pre-fix Idle gate).
    if (cell_bytes > 0 && (black || !test_idle_uncounted_)) {
        if (black || par_promo_active_) {
            // threaded-gc-06: atomic -- a parallel promotion worker finalizes
            // stashed cells of mixed blocks outside the promotion lock
            // (finalizePoppedCellW), and flushCursorW adds lock-free.
            std::atomic_ref<uint64_t>(blocks_.meta(block_id).live_bytes)
                .fetch_add(cell_bytes, std::memory_order_relaxed);
        } else {
            blocks_.meta(block_id).live_bytes += cell_bytes;   // the owner; nothing concurrent
        }
    }
}
// TLA-REGION(OGS.initObjectHeaderWithSize) end

// ---------------------------------------------------------------------------
// Page-index helpers (Step 1).
// ---------------------------------------------------------------------------

// TLA-REGION(OGS.commitPageIndexThrough) begin
void OldGenSpace::commitPageIndexThrough(const char* end) {
    if (index_base_ == nullptr || end == nullptr || end <= index_base_) return;
    const size_t page_size = config_->alloc_buffer_size;
    const size_t slot = static_cast<size_t>(end - index_base_ - 1) / page_size;
    const size_t want = std::min(slot + 1, page_index_.capacity());
    page_index_.ensureCommitted(want);
}
// TLA-REGION(OGS.commitPageIndexThrough) end

// TLA-REGION(OGS.recomputeRegionBounds) begin
void OldGenSpace::recomputeRegionBounds() {
    char* new_base = nullptr;
    char* new_end = nullptr;
    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        const BlockInfo& b = blocks_.info(blocks_.idAt(pos));
        if (new_base == nullptr || b.start < new_base) new_base = b.start;
        if (b.end > new_end) new_end = b.end;
    }
    for (const auto& e : unassigned_blocks_) {
        if (new_base == nullptr || e.first < new_base) new_base = e.first;
        if (e.second > new_end) new_end = e.second;
    }
    // CR-009 (05c G12, row H5): every region-bound write goes through the
    // setters (relaxed atomic_ref stores), this one included.
    setRegionBase(new_base);
    setRegionEnd(new_end);
    // threaded-gc-01 (HEAP_049): the page index is keyed from index_base_,
    // so a region-bounds change no longer rebuilds it. Committing through
    // the (possibly moved) end is a no-op unless the region grew.
    commitPageIndexThrough(new_end);
}
// TLA-REGION(OGS.recomputeRegionBounds) end

size_t OldGenSpace::firstPageIndex(const BlockInfo& block) const {
    if (index_base_ == nullptr) return std::numeric_limits<size_t>::max();
    const size_t page_size = config_->alloc_buffer_size;
    if (page_size == 0) return std::numeric_limits<size_t>::max();
    if (block.start < index_base_) return std::numeric_limits<size_t>::max();
    return static_cast<size_t>(block.start - index_base_) / page_size;
}

size_t OldGenSpace::lastPageIndex(const BlockInfo& block) const {
    if (index_base_ == nullptr) return std::numeric_limits<size_t>::max();
    const size_t page_size = config_->alloc_buffer_size;
    if (page_size == 0) return std::numeric_limits<size_t>::max();
    // block.end is the exclusive upper bound; the last page slot it covers
    // is (end - index_base_ - 1) / page_size. Defensive: never underflow.
    if (block.end <= index_base_) return std::numeric_limits<size_t>::max();
    return static_cast<size_t>(block.end - index_base_ - 1) / page_size;
}

// TLA-REGION(OGS.assignPageIndexForBlock) begin
void OldGenSpace::assignPageIndexForBlock(BlockId id) {
    if (!id.valid()) return;
    const BlockInfo& block = blocks_.info(id);
    const size_t first = firstPageIndex(block);
    const size_t last  = lastPageIndex(block);
    if (first == std::numeric_limits<size_t>::max() ||
        last == std::numeric_limits<size_t>::max()) {
        return;
    }
    page_index_.ensureCommitted(last + 1);
    const uint32_t enc = encodeOwner(id);
    for (size_t p = first; p <= last; ++p) {
        PageOwners& slot = page_index_[p];
        // CR-021: this thread is the only writer, but background markers may
        // hold an atomic_ref to the words (loadOwner in blockIdFor), so its
        // own reads go through one too (relaxed: plain moves on x86).
        const uint32_t prim = loadOwnerRelaxed(slot.primary);
        const uint32_t sec = loadOwnerRelaxed(slot.secondary);
        if (prim == enc || sec == enc) {
            // Already recorded.
            continue;
        }
        // threaded-gc-05c (H3, HEAP_049): owner words are published with
        // release -- the BlockInfo and mark slot written by materializeBlock
        // before this are visible to a background marker that loads the owner
        // with acquire in blockIdFor.
        if (prim == 0) {
            storeOwner(slot.primary, enc);
        } else if (sec == 0) {
            storeOwner(slot.secondary, enc);
        } else {
#if ECO_HEAP_VALIDATE
            // HEAP_049: every block is >= alloc_buffer_size, so a slot can
            // intersect at most two blocks. A third owner means a stale
            // entry survived a release (or the size premise broke).
            std::fprintf(stderr,
                "[heap-validate] HEAP_049: page slot %zu already has two "
                "owners (ids %u, %u) when assigning id %u\n",
                p, prim - 1, sec - 1, id.v);
            std::fflush(stderr);
            std::abort();
#endif
            // Keep the primary stable (the older owner — typically a large
            // block straddling many slots) and overwrite the secondary.
            // blockIdFor's contains-check still gates the returned id on
            // actual extent membership.
            storeOwner(slot.secondary, enc);
        }
    }
}
// TLA-REGION(OGS.assignPageIndexForBlock) end

void OldGenSpace::clearPageIndexForBlock(BlockId id) {
    if (!id.valid()) return;
    const BlockInfo& block = blocks_.info(id);
    const size_t first = firstPageIndex(block);
    const size_t last  = lastPageIndex(block);
    if (first == std::numeric_limits<size_t>::max() ||
        last == std::numeric_limits<size_t>::max()) {
        return;
    }
    const size_t cap = page_index_.committed();
    if (first >= cap) return;
    const size_t end = std::min(last, cap - 1);
    const uint32_t enc = encodeOwner(id);
    for (size_t p = first; p <= end; ++p) {
        PageOwners& slot = page_index_[p];
        // Clear whichever owner matches; leave the other owner in place.
        // CR-021: the owner's reads go through atomic_ref (relaxed).
        const uint32_t prim = loadOwnerRelaxed(slot.primary);
        const uint32_t sec = loadOwnerRelaxed(slot.secondary);
        if (prim == enc) {
            storeOwner(slot.primary, sec);
            storeOwner(slot.secondary, 0);
        } else if (sec == enc) {
            storeOwner(slot.secondary, 0);
        }
    }
}

// TLA-REGION(OGS.materializeBlock) begin
BlockId OldGenSpace::materializeBlock(const BlockInfo& bi,
                                      const BufferMetadata& m,
                                      size_t mark_bytes) {
    const BlockId id = blocks_.add(bi, m);
    mark_.assign(id, static_cast<uint32_t>(mark_bytes));
    for (unsigned i = 0; i < mark_slots_; ++i) markers_[i]->live.commitThrough(id);
    assignPageIndexForBlock(id);
    return id;
}
// TLA-REGION(OGS.materializeBlock) end

// Defined further down (size-class fast path); used by the bitmap path.
static inline void padCellSlack(void* obj, size_t requested_size,
                                size_t cell_size);

// ---------------------------------------------------------------------------
// Bitmap allocation (threaded-gc-02, HEAP_054). Cursor / queue bookkeeping.
// ---------------------------------------------------------------------------

// TLA-REGION(OGS.resetAllocCursors) begin
void OldGenSpace::resetAllocCursors() {
    syncCursorLiveBytes();
    for (size_t c = 0; c < NUM_SIZE_CLASSES; ++c) {
        cursor_[c] = AllocCursor{};
        partial_[c].clear();
        partial_head_[c] = 0;
    }
    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        BlockInfo& b = blocks_.info(blocks_.idAt(pos));
        if (__builtin_expect(b.alloc_state == kAllocTenure, 0)) {
            std::fprintf(stderr, "[gc] FATAL: resetAllocCursors met a tenure-granted block "
                         "(a mark started with a tenure job unmerged; HEAP_070)\n");
            std::fflush(stderr);
            std::abort();
        }
        b.alloc_state = kAllocNone;
    }
}
// TLA-REGION(OGS.resetAllocCursors) end

// TLA-REGION(OGS.detachFromAllocation) begin
void OldGenSpace::detachFromAllocation(BlockId id) {
    if (!id.valid()) return;
    BlockInfo& b = blocks_.info(id);
    if (b.alloc_state == kAllocNone) return;
    if (__builtin_expect(b.alloc_state == kAllocTenure, 0)) {
        // threaded-gc-07 TV5 (every build): a granted block belongs to a
        // running tenure job; detaching it would not stop the collector.
        std::fprintf(stderr, "[gc] FATAL: detachFromAllocation(%u) on a tenure-granted block "
                     "(HEAP_070 skip rule violated)\n", id.v);
        std::fflush(stderr);
        std::abort();
    }
    const size_t cls = b.size_class;
    assert(cls < NUM_SIZE_CLASSES && "detach: allocation state on a non-uniform block");
    if (b.alloc_state == kAllocCurrent) {
        // threaded-gc-06 (P§3.8.4): inside a parallel minor a Current block may
        // belong to a WORKER cursor, which this cannot see. Step 0 proved no
        // ladder rung detaches; a detach here would lose that cursor's block.
        if (__builtin_expect(par_promo_active_, 0)) {
            std::fprintf(stderr, "[gc] FATAL: detachFromAllocation(%u) during a parallel "
                         "minor (HEAP_054 worker cursors)\n", id.v);
            std::fflush(stderr);
            std::abort();
        }
        if (cursor_[cls].block == id) {
            flushCursor(cls);
            cursor_[cls] = AllocCursor{};
        }
    } else {
        // Queued: erase eagerly (rare — releases of queued blocks happen only
        // in the light shrink / empty-block repurposing). Eager erasure keeps
        // a recycled id from being seen through a stale queue entry.
        std::vector<BlockId>& q = partial_[cls];
        for (size_t k = partial_head_[cls]; k < q.size(); ++k) {
            if (q[k] == id) {
                q.erase(q.begin() + static_cast<std::ptrdiff_t>(k));
                break;
            }
        }
    }
    b.alloc_state = kAllocNone;
}
// TLA-REGION(OGS.detachFromAllocation) end

void OldGenSpace::flushCursor(size_t cls) {
    AllocCursor& c = cursor_[cls];
    if (c.block.valid() && c.pending_allocs != 0) {
        blocks_.meta(c.block).live_bytes += c.pending_live;
#if ENABLE_GC_STATS
        alloc_stats_.bm.bitmap_allocs += c.pending_allocs;
        alloc_stats_.bm.bitmap_alloc_bytes += c.pending_live;
#endif
    }
    c.pending_live = 0;
    c.pending_allocs = 0;
}

void OldGenSpace::syncCursorLiveBytes() {
    if (!config_->old_gen_bitmap_alloc) return;
    for (size_t cls = 0; cls < NUM_SIZE_CLASSES; ++cls) flushCursor(cls);
}

void OldGenSpace::setCursor(size_t cls, BlockId id) {
#if ECO_HEAP_VALIDATE
    // IM13 (threaded-gc-05c, H1b): during a cycle the cursor owns only blocks
    // created after t0 -- the premise that lets finalizeBitmapCell keep its
    // plain bit set while background markers run.
    if (isT0Block(id)) {
        std::fprintf(stderr, "[heap-validate] IM13: the uniform cursor took t0 block %u "
                     "during a mark cycle\n", id.v);
        std::fflush(stderr);
        std::abort();
    }
#endif
    flushCursor(cls);
    BlockInfo& b = blocks_.info(id);
    AllocCursor& c = cursor_[cls];
    c.block = id;
    c.next_cell = 0;
    c.num_cells = cellsIn(b);
    c.cell_bytes = static_cast<uint32_t>(classToSize(cls));
    c.stride_bits = c.cell_bytes / 8;
    c.bits = mark_.slot(id);
    c.base = b.start;
    b.alloc_state = kAllocCurrent;
}

bool OldGenSpace::refillCursor(size_t cls) {
    std::vector<BlockId>& q = partial_[cls];
    size_t& h = partial_head_[cls];
    while (h < q.size()) {
        const BlockId id = q[h++];
        if (!blocks_.isLive(id)) continue;
        BlockInfo& b = blocks_.info(id);
        if (b.alloc_state != kAllocQueued || b.is_large || b.size_class != cls) {
            continue;
        }
        if (h == q.size()) { q.clear(); h = 0; }
        setCursor(cls, id);
#if ENABLE_GC_STATS
        alloc_stats_.bm.cursor_refills++;
#endif
        return true;
    }
    q.clear();
    h = 0;
    return false;
}

// TLA-REGION(OGS.finalizeBitmapCell) begin
void* OldGenSpace::finalizeBitmapCell(AllocCursor& c, uint32_t k,
                                      size_t requested_size) {
    const size_t cell = c.cell_bytes;
    char* p = c.base + static_cast<size_t>(k) * cell;
#if ECO_HEAP_VALIDATE
    if (blocks_.info(c.block).alloc_state == kAllocTenure) {   // threaded-gc-07 TV5
        std::fprintf(stderr, "[heap-validate] TV5: the mutator cursor allocated in tenure-granted "
                     "block %u\n", c.block.v);
        std::fflush(stderr);
        std::abort();
    }
#endif
#if ECO_HEAP_VALIDATE
    assertCellWasWhite(c.block, p);   // threaded-gc-05a IM4
#endif
    // P§3.1: the bit is the allocation record — set on EVERY allocation.
    // (threaded-gc-05a: skipped only by the allocate-black negative control.)
    if (!test_skip_allocate_black_)
        bitscan::setBit(c.bits, static_cast<size_t>(k) * c.stride_bits);
    Header* hdr = reinterpret_cast<Header*>(p);
    std::memset(hdr, 0, sizeof(Header));
    hdr->color = static_cast<u32>(
        (marking_active || gc_phase_ != GCPhase::Idle) ? Color::Black
                                                       : Color::White);
    // P§3.1: live_bytes of a uniform block is exact (popcount x cell) — in
    // every phase (F7). initObjectHeaderWithSize is deliberately NOT called:
    // it would add live_bytes a second time (it too counts in every phase
    // since CR-018, HEAP_073; mixed blocks are an upper bound, uniform exact).
    // (accumulated in the cursor; flushCursor folds it into meta.live_bytes)
    c.pending_live += cell;
    c.pending_allocs++;
    allocated_bytes += cell;
    old_alloc_total_ += cell;   // 05c P-hat (monotone)
    padCellSlack(p, requested_size, cell);   // a later demotion walks mixed (F8)
    return p;
}
// TLA-REGION(OGS.finalizeBitmapCell) end

void* OldGenSpace::cursorAllocate(size_t cls, size_t requested_size) {
    AllocCursor& c = cursor_[cls];
    // Fast path: the next cell itself is free (always true in a virgin block
    // and inside a free run) — one multiply, one byte load, one test.
    if (c.next_cell < c.num_cells) {
        const size_t bit = static_cast<size_t>(c.next_cell) * c.stride_bits;
        if (((c.bits[bit >> 3] >> (bit & 7)) & 1u) == 0) {
            const uint32_t k = c.next_cell++;
            return finalizeBitmapCell(c, k, requested_size);
        }
    }
    for (;;) {
        if (c.block.valid()) {
            const uint32_t k = bitscan::nextFreeCell(c.bits, c.stride_bits,
                                                     c.next_cell, c.num_cells);
            if (k < c.num_cells) {
                c.next_cell = k + 1;
                return finalizeBitmapCell(c, k, requested_size);
            }
            // Exhausted: full (cells freed behind the cursor rewind it).
            flushCursor(cls);
            blocks_.info(c.block).alloc_state = kAllocNone;
            c = AllocCursor{};
        }
        if (!refillCursor(cls)) return nullptr;
    }
}

AcquireWait OldGenSpace::acquireWaitPolicy() const {
    return (par_promo_active_ && promo_ctx_ && promo_ctx_->n > 1) ? AcquireWait::AvoidUnderPromo
                                                                  : AcquireWait::Allowed;
}

// TLA-REGION(OGS.ensureBagPageAvailable) begin
bool OldGenSpace::ensureBagPageAvailable() {
    // Same fall-through as populateFromBlock (left untouched so the flag-off
    // path stays byte-identical): acquire a fresh page from the OS if the bag
    // is empty but address space remains below the old-gen cap.
    if (unassigned_blocks_.empty() && allocator_ != nullptr) {
        char* base = allocator_->acquireOldGenBlock(config_->alloc_buffer_size, acquireWaitPolicy());   // CR-007
        if (base != nullptr) {
            unassigned_blocks_.emplace_back(base, base + config_->alloc_buffer_size);
            if (char* const rb = regionBase(); rb == nullptr || base < rb) setRegionBase(base);
            if (base + config_->alloc_buffer_size > regionEnd()) {
                setRegionEnd(base + config_->alloc_buffer_size);
            }
            resizePageIndexForRegion();
        }
    }
    return !unassigned_blocks_.empty();
}
// TLA-REGION(OGS.ensureBagPageAvailable) end

BlockId OldGenSpace::materializeVirginBlock(size_t cls) {
    const size_t cell_bytes = classToSize(cls);
    if (!ensureBagPageAvailable()) return NO_BLOCK_ID;
    const auto extent = unassigned_blocks_.back();
    const size_t page_size = static_cast<size_t>(extent.second - extent.first);
    const size_t num_cells = page_size / cell_bytes;
    if (num_cells == 0) return NO_BLOCK_ID;
    unassigned_blocks_.pop_back();

    // A virgin block is NOT sliced (the W6 benefit): no headers, no links.
    // The all-zero bitmap from materializeBlock says every cell is free.
    BlockInfo bi;
    bi.start = extent.first;
    bi.end = extent.second;
    bi.end_of_objects = extent.first + num_cells * cell_bytes;
    bi.size_class = cls;
    bi.is_large = false;
    const BlockId id =
        materializeBlock(bi, {0, 0, /*fully_swept=*/true}, bitmapBytesForBlock(bi));
    onUniformBlockDedicated(id);
    return id;
}

bool OldGenSpace::startVirginBlock(size_t cls) {
    const BlockId id = materializeVirginBlock(cls);
    if (!id.valid()) return false;
    assert(!cursor_[cls].block.valid() && "virgin block while a cursor is live");
    setCursor(cls, id);
#if ENABLE_GC_STATS
    alloc_stats_.bm.virgin_blocks++;
#endif
    return true;
}

// P§3.4: the flag-on ladder. Virgin blocks enter ONLY at the rungs
// populateFromBlock occupied (bag-first, and after sweep-on-demand) — the W6
// rule: never above a reuse rung.
void* OldGenSpace::allocateFromSizeClassBitmap(size_t cls, size_t requested_size) {
    // (1) Reuse: the class cursor over partially free uniform blocks.
    if (void* r = cursorAllocate(cls, requested_size)) return r;
    // (2) Reuse: exact-fit pop of a mixed-block cell.
    if (FreeCell* cell = tryPopFromFreeList(cls)) {
#if ENABLE_GC_STATS
        alloc_stats_.bm.list_pops++;
#endif
        return finalizePoppedCell(cell, cls, requested_size);
    }
    // (3) Budgeted growth: bag-first for small classes (today's rung 2).
    if (shouldPreferBagForSmallClass(cls) && startVirginBlock(cls)) {
        if (void* r = cursorAllocate(cls, requested_size)) return r;
    }
    // (4) Reuse: split a larger mixed cell.
    if (void* r = tryAllocateBySplittingLarger(cls, classToSize(cls))) {
        padCellSlack(r, requested_size, classToSize(cls));
#if ENABLE_GC_STATS
        alloc_stats_.bm.split_allocs++;
#endif
        return r;
    }
    // (5) Reuse: sweep-on-demand (gap-sweeps pending mixed blocks).
    if (hasPendingSweepWork()) {
        if (void* r = sweepOnDemandAllocate(cls, requested_size)) {
#if ENABLE_GC_STATS
            alloc_stats_.bm.sweep_on_demand_hits++;
#endif
            return r;
        }
    }
    // (6) Growth: a virgin block (today's rung 5, populateFromBlock).
    if (startVirginBlock(cls)) {
        if (void* r = cursorAllocate(cls, requested_size)) return r;
    }
    // (7) Growth: a bag page as one cell.
    if (void* r = allocateFromBagPage(requested_size)) return r;
    // (8) Last resort.
    return panicSweepAndRetryAllocation(cls, requested_size);
}

void OldGenSpace::freeUniformCell(BlockId id, char* cell) {
    BlockInfo& b = blocks_.info(id);
    if (__builtin_expect(b.alloc_state == kAllocTenure, 0)) {
        std::fprintf(stderr, "[gc] FATAL: freeUniformCell on a tenure-granted block %u "
                     "(HEAP_070)\n", id.v);
        std::fflush(stderr);
        std::abort();
    }
    // The caller debits meta.live_bytes next: fold any pending bytes first.
    if (b.alloc_state == kAllocCurrent) flushCursor(b.size_class);
    const size_t cls = b.size_class;
    const size_t cell_bytes = classToSize(cls);
    const uint32_t k = static_cast<uint32_t>(
        static_cast<size_t>(cell - b.start) / cell_bytes);
    bitscan::clearBit(mark_.slot(id), static_cast<size_t>(k) * (cell_bytes / 8));
    if (b.alloc_state == kAllocCurrent) {
        if (cursor_[cls].block == id && k < cursor_[cls].next_cell) {
            cursor_[cls].next_cell = k;      // rewind: never lose the cell
        }
    } else if (b.alloc_state == kAllocNone) {
        partial_[cls].push_back(id);
        b.alloc_state = kAllocQueued;
    }
#if ENABLE_GC_STATS
    alloc_stats_.bm.uniform_cells_freed++;
#endif
}

// ---------------------------------------------------------------------------
// threaded-gc-06 (plans/threaded-gc-06-parallel-minor.md P§3.8, HEAP_054):
// promotion buffers for the parallel minor GC. The *W functions are copies of
// the serial cursor functions with the cursor passed in and every shared
// counter redirected to the worker (the serial ones are left untouched: the
// gc_minor_threads = 1 path must stay bit-identical and alignment-stable).
// ---------------------------------------------------------------------------

#if ECO_HEAP_VALIDATE
[[noreturn]] static void cycleValidateFail(const char* what, const void* p);   // defined below
#endif

namespace {
// Defined with the sweep helpers below (same unnamed namespace, same TU).
inline void pushCoalescedFreeCell(FreeCell** free_lists, char* span_start, size_t span_bytes,
                                  BlockInfo* block, BlockId block_index);
}  // namespace

void OldGenSpace::PromoWorker::resetRun() {
    for (size_t c = 0; c < NUM_SIZE_CLASSES; ++c) cur[c] = AllocCursor{};
    allocated_bytes = old_alloc_total = 0;
    bm_allocs = bm_bytes = 0;
    mutex_acquires = mutex_wait_ns = 0;
    for (auto& b : size_hist) b = 0;
    size_16_24 = 0;
    for (auto& k : stash_n) k = 0;
    list_pops = stash_returned = 0;
    for (auto& u : chunk_units) u = 1;
#if ECO_HEAP_VALIDATE
    cycle_alloc_log.clear();
    mutex_charges = 0;
#endif
}

OldGenSpace::PromoCtx& OldGenSpace::promoCtx() {
    if (!promo_ctx_) promo_ctx_ = std::make_unique<PromoCtx>();
    return *promo_ctx_;
}

// TLA-REGION(OGS.flushCursorW) begin
void OldGenSpace::flushCursorW(AllocCursor& c, PromoWorker& pw) {
    if (c.block.valid() && c.pending_allocs != 0) {
        // Atomic: with chunked cursors (N > 1) several workers flush into one
        // block.
        std::atomic_ref<uint64_t>(blocks_.meta(c.block).live_bytes)
            .fetch_add(c.pending_live, std::memory_order_relaxed);
        pw.bm_allocs += c.pending_allocs;
        pw.bm_bytes += c.pending_live;
    }
    c.pending_live = 0;
    c.pending_allocs = 0;
}
// TLA-REGION(OGS.flushCursorW) end

void OldGenSpace::setCursorW(AllocCursor& c, size_t cls, BlockId id, PromoWorker& pw) {
#if ECO_HEAP_VALIDATE
    // IM13 for worker cursors (threaded-gc-05c H1b, generalised by 06).
    if (isT0Block(id)) {
        std::fprintf(stderr, "[heap-validate] IM13: a worker promotion cursor took t0 "
                     "block %u during a mark cycle\n", id.v);
        std::fflush(stderr);
        std::abort();
    }
#endif
    flushCursorW(c, pw);
    BlockInfo& b = blocks_.info(id);
    c.block = id;
    c.next_cell = 0;
    c.num_cells = cellsIn(b);
    c.cell_bytes = static_cast<uint32_t>(classToSize(cls));
    c.stride_bits = c.cell_bytes / 8;
    c.bits = mark_.slot(id);
    c.base = b.start;
    b.alloc_state = kAllocCurrent;
}

// Step 7b (P§4, as built): a stashed free cell (popped under the lock in a
// batch) is finalized OUTSIDE the lock. Everything it writes is private to
// this worker or atomic: the header and slack (the cell is ours), the mark
// bit mid-cycle (atomic fetch_or, 5c H1), the block's live_bytes (atomic
// add, as initObjectHeaderWithSize now does), and the byte charges (pw).
// TLA-REGION(OGS.finalizePoppedCellW) begin
void* OldGenSpace::finalizePoppedCellW(FreeCell* cell, size_t cls, size_t requested_size,
                                       PromoWorker& pw) {
    void* result = static_cast<void*>(cell);
    const size_t cell_size = classToSize(cls);
    Header* hdr = reinterpret_cast<Header*>(result);
    std::memset(hdr, 0, sizeof(Header));
    // CR-001 (HEAP_067): outside promo_mu_, so a relaxed atomic_ref load (the
    // completion's write is a relaxed atomic_ref store).
    const bool black = marking_active ||
        std::atomic_ref<GCPhase>(gc_phase_).load(std::memory_order_relaxed) != GCPhase::Idle;
    // CR-018 (HEAP_073): the live_bytes add runs in every phase; only the
    // negative-control hook skips it at Idle (the pre-fix behaviour).
    const bool count = black || !test_idle_uncounted_;
    if (black) {
        hdr->color = static_cast<u32>(Color::Black);
        ECO_M4_TRACE("m4.fin", "cb", cell_size, "blk", ECO_M4_BLK(result), "c", ECO_M4_BIT(result),
                     "black", true, "cnt", true, "rd", "phase",
                     "val", static_cast<int>(cycle_state_ != CycleState::Idle ? GCPhase::Marking : GCPhase::Sweeping));
    } else {
        hdr->color = static_cast<u32>(Color::White);
        ECO_M4_TRACE("m4.fin", "cb", cell_size, "blk", ECO_M4_BLK(result), "c", ECO_M4_BIT(result),
                     "black", false, "cnt", count, "rd", "phase", "val", 0);
    }
    if (contains(result)) {
        const BlockId id = blockIdFor(result);
        if (id.valid()) {
            if (black) {
#if ECO_HEAP_VALIDATE
                assertCellWasWhite(id, result);   // IM4
#endif
                if (!test_skip_allocate_black_) setMarkBitAtomic(id, result);
            }
            // Exactly one live_bytes add per path (CR-018): lock-free, other
            // workers finalize cells of the same block concurrently.
            if (count)
                std::atomic_ref<uint64_t>(blocks_.meta(id).live_bytes)
                    .fetch_add(cell_size, std::memory_order_relaxed);
            if (black) ECO_M4_TRACE("m4.finb", "blk", id.v, "c", ECO_M4_BIT(result));
        }
    }
    padCellSlack(result, requested_size, cell_size);
    pw.allocated_bytes += cell_size;
    pw.old_alloc_total += cell_size;
    ++pw.list_pops;
    return result;
}
// TLA-REGION(OGS.finalizePoppedCellW) end

// Under promo_mu_ (it pops the shared partial_ queue).
bool OldGenSpace::refillCursorW(AllocCursor& c, size_t cls, PromoWorker& pw) {
    std::vector<BlockId>& q = partial_[cls];
    size_t& h = partial_head_[cls];
    while (h < q.size()) {
        const BlockId id = q[h++];
        if (!blocks_.isLive(id)) continue;
        BlockInfo& b = blocks_.info(id);
        if (b.alloc_state != kAllocQueued || b.is_large || b.size_class != cls) {
            continue;
        }
        if (h == q.size()) { q.clear(); h = 0; }
        setCursorW(c, cls, id, pw);
#if ENABLE_GC_STATS
        alloc_stats_.bm.cursor_refills++;   // under the lock
#endif
        return true;
    }
    q.clear();
    h = 0;
    return false;
}

// TLA-REGION(OGS.finalizeBitmapCellW) begin
void* OldGenSpace::finalizeBitmapCellW(AllocCursor& c, uint32_t k, size_t requested_size,
                                       PromoWorker& pw) {
    const size_t cell = c.cell_bytes;
    char* p = c.base + static_cast<size_t>(k) * cell;
#if ECO_HEAP_VALIDATE
    assertCellWasWhite(c.block, p);   // IM4
#endif
    // The cursor's block is private to this worker and (IM13) post-t0 during
    // a cycle: no marker writes these bitmap bytes, so a plain set is safe.
    if (!test_skip_allocate_black_)
        bitscan::setBit(c.bits, static_cast<size_t>(k) * c.stride_bits);
    ECO_M4_TRACE("m4.set", "cb", c.cell_bytes, "blk", c.block.v, "c", static_cast<size_t>(k) * c.stride_bits);
    Header* hdr = reinterpret_cast<Header*>(p);
    std::memset(hdr, 0, sizeof(Header));
    // CR-001 (HEAP_067): lock-free on the fast path, so a relaxed atomic_ref load.
    hdr->color = static_cast<u32>(
        (marking_active ||
         std::atomic_ref<GCPhase>(gc_phase_).load(std::memory_order_relaxed) != GCPhase::Idle)
            ? Color::Black : Color::White);
    // The phase this decision read (Sweeping outside a cycle), for the merger's
    // reads-from order on gc_phase_ (CR-001).
    ECO_M4_TRACE("m4.rph", "cb", c.cell_bytes, "black", hdr->color == static_cast<u32>(Color::Black),
                 "rd", "phase", "val", hdr->color == static_cast<u32>(Color::Black)
                     ? static_cast<int>(cycle_state_ != CycleState::Idle ? GCPhase::Marking : GCPhase::Sweeping) : 0);
    c.pending_live += cell;
    c.pending_allocs++;
    pw.allocated_bytes += cell;
    pw.old_alloc_total += cell;
    padCellSlack(p, requested_size, cell);
    return p;
}
// TLA-REGION(OGS.finalizeBitmapCellW) end

// Rung 1 inside the worker's current block only. nullptr when the block is
// exhausted (it is then retired to kAllocNone and the cursor emptied).
// TLA-REGION(OGS.cursorAllocateW) begin
void* OldGenSpace::cursorAllocateW(AllocCursor& c, size_t requested_size, PromoWorker& pw) {
    if (!c.block.valid()) return nullptr;
    if (c.next_cell < c.num_cells) {
        const size_t bit = static_cast<size_t>(c.next_cell) * c.stride_bits;
        if (((c.bits[bit >> 3] >> (bit & 7)) & 1u) == 0) {
            const uint32_t k = c.next_cell++;
            ECO_M4_TRACE("m4.cur", "cb", c.cell_bytes, "blk", c.block.v, "c", bit, "fast", true);
            return finalizeBitmapCellW(c, k, requested_size, pw);
        }
    }
    const uint32_t k = bitscan::nextFreeCell(c.bits, c.stride_bits, c.next_cell, c.num_cells);
    if (k < c.num_cells) {
        ECO_M4_TRACE("m4.cur", "cb", c.cell_bytes, "blk", c.block.v,
                     "c", static_cast<size_t>(k) * c.stride_bits, "fast", false);
        c.next_cell = k + 1;
        return finalizeBitmapCellW(c, k, requested_size, pw);
    }
    ECO_M4_TRACE("m4.exh", "cb", c.cell_bytes, "blk", c.block.v,
                 "flush", c.pending_allocs != 0 ? c.pending_live / c.cell_bytes : 0);
    flushCursorW(c, pw);
    // One worker per block (N = 1): retire it here. Chunked (N > 1): the
    // shared block's state is advanced under the lock (advanceSharedW).
    if (!promo_ctx_->chunked) blocks_.info(c.block).alloc_state = kAllocNone;
    c = AllocCursor{};
    return nullptr;
}
// TLA-REGION(OGS.cursorAllocateW) end

// Chunked cursors (N > 1). Lock-free: claims the next chunk of the class's
// shared block into the worker's cursor. false when there is no block or it
// is exhausted (the caller then advances under the lock).
// TLA-REGION(OGS.claimChunkW) begin
bool OldGenSpace::claimChunkW(size_t cls, AllocCursor& c, PromoWorker& pw) {
    std::atomic<uint64_t>& sh = promo_ctx_->shared[cls].w;
    uint64_t w = sh.load(std::memory_order_acquire);
    for (;;) {
        if (w == 0) {
            ECO_M4_TRACE("m4.nclaim", "cb", classToSize(cls), "rd", ::Elm::tlatrace::key("sh", cls), "val", w);
            return false;
        }
        const BlockId id{static_cast<uint32_t>(w >> 32) - 1};
        const uint32_t k = static_cast<uint32_t>(w);
        const BlockInfo& b = blocks_.info(id);
        const uint32_t ncell = cellsIn(b);
        const uint64_t lo = static_cast<uint64_t>(k) * kChunkUnitCells;
        if (lo >= ncell) {
            ECO_M4_TRACE("m4.nclaim", "cb", classToSize(cls), "rd", ::Elm::tlatrace::key("sh", cls), "val", w);
            return false;
        }
        const uint32_t units = pw.chunk_units[cls];
        if (sh.compare_exchange_weak(w, w + units, std::memory_order_acq_rel,
                                     std::memory_order_acquire)) {
            ECO_M4_TRACE("m4.claim", "cb", classToSize(cls), "blk", id.v, "u", k, "units", units,
                         "lo", lo, "hi", std::min<uint64_t>(lo + static_cast<uint64_t>(units) * kChunkUnitCells, ncell),
                         "rmw", ::Elm::tlatrace::key("sh", cls), "old", w, "new", w + units);
            if (units < kChunkMaxUnits) pw.chunk_units[cls] = static_cast<uint8_t>(units * 2);
            flushCursorW(c, pw);
            c.block = id;
            c.next_cell = static_cast<uint32_t>(lo);
            c.num_cells = static_cast<uint32_t>(
                std::min<uint64_t>(lo + static_cast<uint64_t>(units) * kChunkUnitCells, ncell));
            c.cell_bytes = static_cast<uint32_t>(classToSize(cls));
            c.stride_bits = c.cell_bytes / 8;
            c.bits = mark_.slot(id);
            c.base = b.start;
            return true;
        }
    }
}
// TLA-REGION(OGS.claimChunkW) end

// Under promo_mu_. Makes `id` the class's shared block, chunk 0.
// TLA-REGION(OGS.publishShared) begin
void OldGenSpace::publishShared(size_t cls, BlockId id) {
#if ECO_HEAP_VALIDATE
    if (isT0Block(id)) {   // IM13 for the shared chunked cursor
        std::fprintf(stderr, "[heap-validate] IM13: the shared promotion block took t0 "
                     "block %u during a mark cycle\n", id.v);
        std::fflush(stderr);
        std::abort();
    }
#endif
    blocks_.info(id).alloc_state = kAllocCurrent;
    ECO_TLA_TRACE_ONLY(const uint64_t m4_old = promo_ctx_->shared[cls].w.load(std::memory_order_relaxed);)
    promo_ctx_->shared[cls].w.store((static_cast<uint64_t>(id.v) + 1) << 32,
                                  std::memory_order_release);
    // M4: logged after the store, so a reader that loaded the old value is not
    // timestamped after it (the merger prefers timestamp order).
    ECO_M4_TRACE("m4.pub", "cb", classToSize(cls), "blk", id.v, "rmw", ::Elm::tlatrace::key("sh", cls),
                 "old", m4_old, "new", (static_cast<uint64_t>(id.v) + 1) << 32);
}
// TLA-REGION(OGS.publishShared) end

// Under promo_mu_. true when a claimable chunk is available afterwards: either
// another worker already advanced, or the partial_ queue supplied a block
// (rung 1 refill). The exhausted block is retired (kAllocNone); at the merge
// the workers' last chunks re-queue it if cells are left.
// TLA-REGION(OGS.advanceSharedW) begin
bool OldGenSpace::advanceSharedW(size_t cls) {
    std::atomic<uint64_t>& sh = promo_ctx_->shared[cls].w;
    const uint64_t w = sh.load(std::memory_order_relaxed);
    if (w != 0) {
        const BlockId id{static_cast<uint32_t>(w >> 32) - 1};
        const uint64_t lo = static_cast<uint64_t>(static_cast<uint32_t>(w)) * kChunkUnitCells;
        if (lo < cellsIn(blocks_.info(id))) return true;
        blocks_.info(id).alloc_state = kAllocNone;
        sh.store(0, std::memory_order_relaxed);
        ECO_M4_TRACE("m4.retire", "cb", classToSize(cls), "blk", id.v,
                     "rmw", ::Elm::tlatrace::key("sh", cls), "old", w, "new", 0);
    }
    std::vector<BlockId>& q = partial_[cls];
    size_t& h = partial_head_[cls];
    while (h < q.size()) {
        const BlockId id = q[h++];
        if (!blocks_.isLive(id)) continue;
        BlockInfo& b = blocks_.info(id);
        if (b.alloc_state != kAllocQueued || b.is_large || b.size_class != cls) continue;
        if (h == q.size()) { q.clear(); h = 0; }
        publishShared(cls, id);
#if ENABLE_GC_STATS
        alloc_stats_.bm.cursor_refills++;
#endif
        return true;
    }
    q.clear();
    h = 0;
    return false;
}
// TLA-REGION(OGS.advanceSharedW) end

// Under promo_mu_: a virgin block becomes the class's shared block.
// TLA-REGION(OGS.startVirginBlockShared) begin
bool OldGenSpace::startVirginBlockShared(size_t cls) {
    const size_t cell_bytes = classToSize(cls);
    if (!ensureBagPageAvailable()) return false;
    const auto extent = unassigned_blocks_.back();
    const size_t page_size = static_cast<size_t>(extent.second - extent.first);
    const size_t num_cells = page_size / cell_bytes;
    if (num_cells == 0) return false;
    unassigned_blocks_.pop_back();
    BlockInfo bi;
    bi.start = extent.first;
    bi.end = extent.second;
    bi.end_of_objects = extent.first + num_cells * cell_bytes;
    bi.size_class = cls;
    bi.is_large = false;
    const BlockId id =
        materializeBlock(bi, {0, 0, /*fully_swept=*/true}, bitmapBytesForBlock(bi));
    onUniformBlockDedicated(id);
    std::atomic<uint64_t>& sh = promo_ctx_->shared[cls].w;
    const uint64_t w = sh.load(std::memory_order_relaxed);
    if (w != 0) {   // retire the exhausted one it replaces
        blocks_.info(BlockId{static_cast<uint32_t>(w >> 32) - 1}).alloc_state = kAllocNone;
    }
    publishShared(cls, id);
#if ENABLE_GC_STATS
    alloc_stats_.bm.virgin_blocks++;
#endif
    return true;
}
// TLA-REGION(OGS.startVirginBlockShared) end

// Under promo_mu_.
// TLA-REGION(OGS.startVirginBlockW) begin
bool OldGenSpace::startVirginBlockW(AllocCursor& c, size_t cls, PromoWorker& pw) {
    const size_t cell_bytes = classToSize(cls);
    if (!ensureBagPageAvailable()) return false;
    const auto extent = unassigned_blocks_.back();
    const size_t page_size = static_cast<size_t>(extent.second - extent.first);
    const size_t num_cells = page_size / cell_bytes;
    if (num_cells == 0) return false;
    unassigned_blocks_.pop_back();
    BlockInfo bi;
    bi.start = extent.first;
    bi.end = extent.second;
    bi.end_of_objects = extent.first + num_cells * cell_bytes;
    bi.size_class = cls;
    bi.is_large = false;
    const BlockId id =
        materializeBlock(bi, {0, 0, /*fully_swept=*/true}, bitmapBytesForBlock(bi));
    onUniformBlockDedicated(id);
    assert(!c.block.valid() && "virgin block while the worker cursor is live");
    setCursorW(c, cls, id, pw);
#if ENABLE_GC_STATS
    alloc_stats_.bm.virgin_blocks++;
#endif
    return true;
}
// TLA-REGION(OGS.startVirginBlockW) end

// Rungs (2)..(8) of allocateFromSizeClassBitmap, under promo_mu_, with the
// virgin-block rungs feeding the WORKER's cursor (the W6 rule: same order).
// TLA-REGION(OGS.ladderFrom2W) begin
void* OldGenSpace::ladderFrom2W(size_t cls, size_t requested_size, PromoWorker& pw) {
    AllocCursor& c = pw.cur[cls];
    if (FreeCell* cell = tryPopFromFreeList(cls)) {
#if ENABLE_GC_STATS
        alloc_stats_.bm.list_pops++;
#endif
        return finalizePoppedCell(cell, cls, requested_size);
    }
    const bool chunked = promo_ctx_->chunked;
    auto virgin = [&]() -> void* {
        if (chunked) {
            if (!startVirginBlockShared(cls)) return nullptr;
            while (claimChunkW(cls, c, pw)) {
                if (void* r = cursorAllocateW(c, requested_size, pw)) return r;
            }
            return nullptr;
        }
        if (!startVirginBlockW(c, cls, pw)) return nullptr;
        return cursorAllocateW(c, requested_size, pw);
    };
    if (shouldPreferBagForSmallClass(cls)) {
        if (void* r = virgin()) return r;
    }
    if (void* r = tryAllocateBySplittingLarger(cls, classToSize(cls))) {
        padCellSlack(r, requested_size, classToSize(cls));
#if ENABLE_GC_STATS
        alloc_stats_.bm.split_allocs++;
#endif
        ECO_M4_TRACE("m4.split", "cb", classToSize(cls), "blk", ECO_M4_BLK(r), "c", ECO_M4_BIT(r));
        return r;
    }
    ECO_M4_TRACE("m4.ladder", "cb", classToSize(cls), "pend", hasPendingSweepWork(),
                 "rd", "phase", "val", static_cast<int>(gc_phase_));
    if (hasPendingSweepWork()) {
        if (void* r = sweepOnDemandAllocate(cls, requested_size)) {
#if ENABLE_GC_STATS
            alloc_stats_.bm.sweep_on_demand_hits++;
#endif
            return r;
        }
    }
    if (void* r = virgin()) return r;
    if (void* r = allocateFromBagPage(requested_size)) return r;
    return panicSweepAndRetryAllocation(cls, requested_size);
}
// TLA-REGION(OGS.ladderFrom2W) end

void OldGenSpace::requeueFront(size_t cls, BlockId id) {
    std::vector<BlockId>& q = partial_[cls];
    size_t& h = partial_head_[cls];
    if (h > 0) q[--h] = id;
    else q.insert(q.begin(), id);
    blocks_.info(id).alloc_state = kAllocQueued;
}

// The sweep finished inside a promotion. With one worker nothing runs
// concurrently: hand worker 0's accounting and cursors back, run the shrink
// exactly where allocate() would have, and take them again (the one-worker
// identity, P§3.8.5). With more workers the merge runs it (deferred).
// TLA-REGION(OGS.sweepCompleteInPromotion) begin
void OldGenSpace::sweepCompleteInPromotion() {
    PromoCtx& ctx = *promo_ctx_;
    if (ctx.n > 1) {
        sweep_complete_deferred_ = true;
        return;
    }
    PromoWorker& pw = ctx.w[0];
    allocated_bytes += pw.allocated_bytes;
    old_alloc_total_ += pw.old_alloc_total;
#if ECO_HEAP_VALIDATE
    pm6_skip_ = true;   // onSweepComplete re-bases allocated_bytes: PM6 cannot balance
#endif
    pw.allocated_bytes = pw.old_alloc_total = 0;
    for (size_t cls = 0; cls < NUM_SIZE_CLASSES; ++cls) {
        flushCursorW(pw.cur[cls], pw);
        cursor_[cls] = pw.cur[cls];
    }
    par_promo_active_ = false;
    onSweepComplete();
    par_promo_active_ = true;
    for (size_t cls = 0; cls < NUM_SIZE_CLASSES; ++cls) {
        pw.cur[cls] = cursor_[cls];
        cursor_[cls] = AllocCursor{};
    }
}
// TLA-REGION(OGS.sweepCompleteInPromotion) end

// TLA-REGION(OGS.beginParallelPromotion) begin
void OldGenSpace::beginParallelPromotion(PromoCtx& ctx, unsigned n) {
    assert(config_->old_gen_bitmap_alloc && "parallel promotion needs bitmap allocation");
    assert(n >= 1 && n <= kMaxPromoWorkers);
    assert(!par_promo_active_);
    ctx.n = n;
    ctx.chunked = n > 1;
    for (unsigned w = 0; w < n; ++w) ctx.w[w].resetRun();
    for (size_t cls = 0; cls < NUM_SIZE_CLASSES; ++cls) {
        ctx.shared[cls].w.store(0, std::memory_order_relaxed);
        if (!ctx.chunked) {
            ctx.w[0].cur[cls] = cursor_[cls];     // worker 0 adopts the mutator's cursors
        } else if (cursor_[cls].block.valid()) {
            // The mutator's block becomes the shared block, from the chunk of
            // its next cell (cells below it are allocated or rewound into it).
            flushCursor(cls);
            ECO_M4_TRACE("m4.begin", "cb", classToSize(cls), "blk", cursor_[cls].block.v,
                         "u", cursor_[cls].next_cell / kChunkUnitCells,
                         "rmw", ::Elm::tlatrace::key("sh", cls), "old", 0,
                         "new", ((static_cast<uint64_t>(cursor_[cls].block.v) + 1) << 32) |
                                    (cursor_[cls].next_cell / kChunkUnitCells));
            ctx.shared[cls].w.store(((static_cast<uint64_t>(cursor_[cls].block.v) + 1) << 32) |
                                      (cursor_[cls].next_cell / kChunkUnitCells),
                                  std::memory_order_relaxed);
        }
        cursor_[cls] = AllocCursor{};
    }
    sweep_complete_deferred_ = false;
#if ECO_HEAP_VALIDATE
    pm6_allocated_before_ = allocated_bytes;
    pm6_skip_ = false;
    v11_deferred_.clear();   // CR-028
#endif
    par_promo_active_ = true;
}
// TLA-REGION(OGS.beginParallelPromotion) end

// TLA-REGION(OGS.endParallelPromotion) begin
void OldGenSpace::endParallelPromotion(PromoCtx& ctx) {
    assert(par_promo_active_);
    par_promo_active_ = false;
    ECO_M4_TRACE("m4.merge", "deferred", sweep_complete_deferred_);
    uint64_t alloc_delta = 0, total_delta = 0;
    for (unsigned w = 0; w < ctx.n; ++w) {
        PromoWorker& pw = ctx.w[w];
        for (size_t cls = 0; cls < NUM_SIZE_CLASSES; ++cls) flushCursorW(pw.cur[cls], pw);
        alloc_delta += pw.allocated_bytes;
        total_delta += pw.old_alloc_total;
#if ENABLE_GC_STATS
        alloc_stats_.bm.bitmap_allocs += pw.bm_allocs;
        alloc_stats_.bm.bitmap_alloc_bytes += pw.bm_bytes;
        alloc_stats_.mergeOldGenAllocHistogram(pw.size_hist, pw.size_16_24);
#endif
#if ECO_HEAP_VALIDATE
        cycle_alloc_log_.insert(cycle_alloc_log_.end(), pw.cycle_alloc_log.begin(),
                                pw.cycle_alloc_log.end());
#endif
    }
    // Step 7b: unused stashed cells go back onto their class free list (they
    // were popped, never finalized: the sweep has passed them already).
    for (unsigned w = 0; w < ctx.n; ++w) {
        PromoWorker& pw = ctx.w[w];
        for (size_t cls = 0; cls < NUM_SIZE_CLASSES; ++cls) {
            while (pw.stash_n[cls] != 0) {
                char* cell = reinterpret_cast<char*>(pw.stash[cls][--pw.stash_n[cls]]);
                const BlockId id = blockIdFor(cell);
                pushCoalescedFreeCell(free_lists_, cell, classToSize(cls),
                                      id.valid() ? &blocks_.info(id) : nullptr, id);
                ++pw.stash_returned;
            }
        }
#if ENABLE_GC_STATS
        alloc_stats_.bm.list_pops += pw.list_pops;
#endif
    }
    if (!ctx.chunked) {
        for (size_t cls = 0; cls < NUM_SIZE_CLASSES; ++cls) cursor_[cls] = ctx.w[0].cur[cls];
        for (unsigned w = 1; w < ctx.n; ++w) {
            if (__builtin_expect(test_keep_worker_cursor_, 0) && w == 1) continue;   // negative control
            for (size_t cls = 0; cls < NUM_SIZE_CLASSES; ++cls) {
                AllocCursor& c = ctx.w[w].cur[cls];
                if (!c.block.valid()) continue;
                const uint32_t k = bitscan::nextFreeCell(c.bits, c.stride_bits, 0, c.num_cells);
                if (k < c.num_cells) requeueFront(cls, c.block);   // W6: reuse before growth
                else blocks_.info(c.block).alloc_state = kAllocNone;
                c = AllocCursor{};
            }
        }
    } else {
        bool kept_one = false;   // negative control: leave one shared block Current, unowned
        for (size_t cls = 0; cls < NUM_SIZE_CLASSES; ++cls) {
            const uint64_t sw = ctx.shared[cls].w.load(std::memory_order_relaxed);
            ECO_TLA_TRACE_ONLY(if (sw != 0))
                ECO_M4_TRACE("m4.shreset", "cb", classToSize(cls),
                             "rmw", ::Elm::tlatrace::key("sh", cls), "old", sw, "new", 0);
            ctx.shared[cls].w.store(0, std::memory_order_relaxed);
            BlockId keep = NO_BLOCK_ID;
            if (sw != 0) {
                const BlockId id{static_cast<uint32_t>(sw >> 32) - 1};
                BlockInfo& b = blocks_.info(id);
                const uint32_t n_cells = cellsIn(b);
                if (bitscan::nextFreeCell(mark_.slot(id), classToSize(cls) / 8, 0, n_cells) < n_cells) {
                    if (__builtin_expect(test_keep_worker_cursor_, 0) && !kept_one) {
                        kept_one = true;   // stays Current with no cursor_: PM4 must fire
                    } else {
                        setCursor(cls, id);          // the mutator continues in it
                        cursor_[cls].next_cell = 0;  // bitmap scan skips allocated cells
                        keep = id;
                    }
                } else {
                    b.alloc_state = kAllocNone;
                }
            }
            // The workers' last chunks: a retired block with cells left is
            // re-queued at the FRONT (W6: reuse before growth).
            for (unsigned w = 0; w < ctx.n; ++w) {
                AllocCursor& c = ctx.w[w].cur[cls];
                if (c.block.valid() && c.block != keep &&
                    blocks_.info(c.block).alloc_state == kAllocNone) {
                    const uint32_t n_cells = cellsIn(blocks_.info(c.block));
                    if (bitscan::nextFreeCell(c.bits, c.stride_bits, 0, n_cells) < n_cells)
                        requeueFront(cls, c.block);
                }
                c = AllocCursor{};
            }
        }
    }
    allocated_bytes += alloc_delta;
    old_alloc_total_ += total_delta;
#if ECO_HEAP_VALIDATE
    // PM6: every byte charged after begin is accounted: the workers' fast-path
    // deltas plus what the rungs charged under the lock.
    {
        uint64_t under_lock = 0;
        for (unsigned w = 0; w < ctx.n; ++w) under_lock += ctx.w[w].mutex_charges;
        if (!pm6_skip_ && allocated_bytes != pm6_allocated_before_ + alloc_delta + under_lock) {
            std::fprintf(stderr, "[heap-validate] PM6: allocated_bytes %zu != before %zu + "
                         "fast %llu + locked %llu\n", allocated_bytes, pm6_allocated_before_,
                         (unsigned long long)alloc_delta, (unsigned long long)under_lock);
            std::fflush(stderr);
            std::abort();
        }
    }
    // PM4: no block is Current except the mutator's cursors.
    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        const BlockId id = blocks_.idAt(pos);
        const BlockInfo& b = blocks_.info(id);
        if (b.alloc_state != kAllocCurrent) continue;
        if (b.is_large || b.size_class >= NUM_SIZE_CLASSES || cursor_[b.size_class].block != id) {
            std::fprintf(stderr, "[heap-validate] PM4: block %u is Current but no mutator "
                         "cursor owns it after a parallel minor\n", id.v);
            std::fflush(stderr);
            std::abort();
        }
    }
    // CR-028 (HEAP_055): V11 for the gap-swept blocks completed inside this
    // promotion, now that every promoted cell is fully written (the join) and
    // every stashed cell is back on its list as Tag_Free (the stash return).
    // Before the deferred shrink, which may release them. A block released or
    // re-issued meanwhile (id no longer names that start) is skipped.
    for (const auto& [id, start] : v11_deferred_)
        if (blocks_.isLive(id) && blocks_.info(id).start == start && !blocks_.info(id).is_large)
            validateV11(id);
    v11_deferred_.clear();
#endif
    if (sweep_complete_deferred_) {
        sweep_complete_deferred_ = false;
        onSweepComplete();
    }
}
// TLA-REGION(OGS.endParallelPromotion) end

// TLA-REGION(OGS.allocatePromotion) begin
void* OldGenSpace::allocatePromotion(PromoWorker& pw, size_t size, bool per_alloc_sweep) {
    size = (size + 7) & ~static_cast<size_t>(7);
#if ENABLE_GC_STATS
    pw.size_hist[GCStats::oldGenAllocBucket(size)]++;
    if (size >= 16 && size < 24) pw.size_16_24++;
#endif
    if (__builtin_expect(size >= config_->alloc_buffer_size, 0)) {
        // A nursery object at least a block long (possible when
        // alloc_buffer_size is below the nursery's large-pointer cap, as in
        // small test geometries; never at the 512 KiB default): allocate()'s
        // large path, under the lock.
        std::lock_guard<minorwork::SpinMutex> lk(promo_mu_);
        ++pw.mutex_acquires;
        ECO_M4_TRACE("m4.lock", "cb", size, "large", true, "clk", "promo", "tick", ++::Elm::tla_m4_tick);
#if ECO_HEAP_VALIDATE
        const size_t charged0 = allocated_bytes;
#endif
        ECO_TLA_TRACE_ONLY(::Elm::tla_m4_flip = -1;)
        void* r = allocateLargeBlock(size);
#if ECO_HEAP_VALIDATE
        pw.mutex_charges += allocated_bytes - charged0;
#endif
        ECO_M4_TRACE("m4.large", "flip", ::Elm::tla_m4_flip);
        ECO_M4_TRACE("m4.unlock", "clk", "promo", "tick", ++::Elm::tla_m4_tick);
        return r;
    }
    // The one-worker identity switch reproduces allocate()'s per-promotion
    // sweep slice exactly; a parallel minor runs one pre-drain slice instead.
    if (per_alloc_sweep && gc_phase_ == GCPhase::Sweeping) {
        const size_t d = config_->minor_sweep_divisor;
        const size_t budget = (d == 0) ? 0 : config_->sweep_work_budget / d;
        if (budget > 0) lazySweep(sizeClass(size), budget);
    }
    const size_t cls = sizeClass(size);
    void* result = nullptr;
    FreeCell* popped = nullptr;
    if (cls < num_size_classes_) {
        AllocCursor& c = pw.cur[cls];
        if ((result = cursorAllocateW(c, size, pw)) != nullptr) goto done;
        // Chunked (N > 1): the next chunk of the shared block, lock-free.
        if (promo_ctx_->chunked) {
            while (claimChunkW(cls, c, pw)) {
                if ((result = cursorAllocateW(c, size, pw)) != nullptr) goto done;
            }
        }
        // Rung 2, cached (Step 7b). A non-empty stash means partial_[cls] was
        // already empty in this minor, and nothing refills it mid-minor, so
        // taking a stashed cell before the lock keeps the ladder order (W6).
        if (pw.stash_n[cls] != 0) {
            popped = pw.stash[cls][--pw.stash_n[cls]];
#if ECO_HEAP_VALIDATE
            // PM8 (CR-002, HEAP_055): a stashed cell is finalized outside
            // promo_mu_, so no gap sweep may still read or clear its block's
            // mark words: while a sweep is pending its block is fully swept.
            // (Outside Sweeping blocks may be !fully_swept - a mark resets it,
            // a block made at Idle starts so - but no sweeper runs, and nothing
            // sets Sweeping inside a minor.) gc_phase_ is read outside the
            // lock here, so atomically (CR-001).
            {
                const BlockId sid = contains(popped) ? blockIdFor(popped) : NO_BLOCK_ID;
                if (sid.valid() &&
                    std::atomic_ref<GCPhase>(gc_phase_).load(std::memory_order_relaxed) == GCPhase::Sweeping &&
                    !blocks_.meta(sid).fully_swept) {
                    std::fprintf(stderr, "[heap-validate] CR-002: stashed cell of an unswept block "
                                 "(cell %p, block %u)\n", static_cast<void*>(popped), sid.v);
                    std::fflush(stderr);
                    std::abort();
                }
            }
#endif
            result = finalizePoppedCellW(popped, cls, size, pw);
            goto done;
        }
    }
    {
        std::unique_lock<minorwork::SpinMutex> lk(promo_mu_, std::try_to_lock);
        if (!lk.owns_lock()) {
#if ENABLE_GC_STATS
            const uint64_t t0 = GCStats::nowSinceProcessStartNs();
            lk.lock();
            pw.mutex_wait_ns += GCStats::nowSinceProcessStartNs() - t0;
#else
            lk.lock();
#endif
        }
        ++pw.mutex_acquires;
        ECO_M4_TRACE("m4.lock", "cb", cls < num_size_classes_ ? classToSize(cls) : size, "large", false,
                     "clk", "promo", "tick", ++::Elm::tla_m4_tick);
#if ECO_HEAP_VALIDATE
        const DecisionScope im16(*this);
        const size_t charged0 = allocated_bytes;
#endif
        if (cls < num_size_classes_) {
            AllocCursor& c = pw.cur[cls];
            if (promo_ctx_->chunked) {
                // Rung 1 refill: advance the shared block, then claim chunks.
                while (result == nullptr && advanceSharedW(cls)) {
                    while (result == nullptr && claimChunkW(cls, c, pw)) {
                        result = cursorAllocateW(c, size, pw);
                    }
                }
            } else {
                while (result == nullptr && refillCursorW(c, cls, pw)) {
                    result = cursorAllocateW(c, size, pw);
                }
            }
            // Rung 2 in a batch with more than one worker: pop up to kStash
            // cells now, finalize one after unlocking, keep the rest.
            // CR-002 (HEAP_055): a cell of a block the gap sweep has not
            // finished is finalized BEFORE the unlock and nothing is stashed;
            // otherwise only the prefix of the list in fully swept blocks is
            // stashed (the peek), so every stashed cell is safe outside the lock.
            if (result == nullptr && promo_ctx_->n > 1) {
                popped = tryPopFromFreeList(cls);
                const bool inlock = popped != nullptr && cellInUnsweptBlock(popped);
                while (popped != nullptr && !inlock && pw.stash_n[cls] < PromoWorker::kStash) {
                    FreeCell* head = free_lists_[cls];   // peek: never stash an unswept cell
                    if (head == nullptr || cellInUnsweptBlock(head)) break;
                    pw.stash[cls][pw.stash_n[cls]++] = tryPopFromFreeList(cls);
                }
                ECO_TLA_TRACE_ONLY(if (popped != nullptr))
                    ECO_M4_TRACE("m4.batch", "cb", classToSize(cls), "cnt", 1 + pw.stash_n[cls],
                                 "blk", ECO_M4_BLK(popped), "c", ECO_M4_BIT(popped), "inlock", inlock);
                if (inlock) {
                    result = finalizePoppedCellW(popped, cls, size, pw);   // before the unlock
                    popped = nullptr;
                }
            }
            if (result == nullptr && popped == nullptr) result = ladderFrom2W(cls, size, pw);
        } else {
            result = allocateFromBagPage(size);
        }
#if ECO_HEAP_VALIDATE
        pw.mutex_charges += allocated_bytes - charged0;
#endif
        ECO_M4_TRACE("m4.unlock", "clk", "promo", "tick", ++::Elm::tla_m4_tick);
    }
    if (result == nullptr && popped != nullptr) result = finalizePoppedCellW(popped, cls, size, pw);
done:
#if ECO_HEAP_VALIDATE
    if (result != nullptr && cycleActive()) {
        const BlockId id = contains(result) ? blockIdFor(result) : NO_BLOCK_ID;
        if (!id.valid()) cycleValidateFail("IM4: in-cycle promotion outside any block", result);
        if (!isMarkedInBlockRelaxed(id, result))
            cycleValidateFail("IM4: in-cycle promotion NOT allocated black", result);
        pw.cycle_alloc_log.push_back(result);
    }
#endif
    return result;
}
// TLA-REGION(OGS.allocatePromotion) end

bool OldGenSpace::sweepWillReach(BlockId id, const char* addr) const {
    if (gc_phase_ != GCPhase::Sweeping) return false;
    if (blocks_.meta(id).fully_swept) return false;
    const size_t pos = blocks_.posOf(id);
    if (pos > sweep_buffer_index_) return true;
    if (pos < sweep_buffer_index_) return false;   // behind: never revisited
    return sweep_cursor_ == nullptr || addr >= sweep_cursor_;
}

// TLA-REGION(OGS.retireDeadLargeBodies) begin
void OldGenSpace::retireDeadLargeBodies() {
    // P§3.5 / HEAP_056: the gap sweep and the cursor never read dead headers,
    // so the header sweep's duty of retiring dead nursery-owned bodies moves
    // here, before any cell can be reused (F11: otherwise a later
    // freeLargeBodyCell would free a reclaimed cell a second time). Same
    // effect as the sweep did: erase + body_base = nullptr, id NOT recycled.
    // Bodies in is_large blocks are handled by classifyBlocksAfterMark.
    for (auto it = large_body_index_.begin(); it != large_body_index_.end();) {
        void* body = it->first;
        const BlockId bid = contains(body) ? blockIdFor(body) : NO_BLOCK_ID;
        if (bid.valid() && !blocks_.info(bid).is_large &&
            !isMarkedInBlock(bid, body)) {
            retireIndexEntry(it->second);
            it = large_body_index_.erase(it);
        } else {
            ++it;
        }
    }
}
// TLA-REGION(OGS.retireDeadLargeBodies) end

// TLA-REGION(OGS.classifyBlocksAfterMark) begin
void OldGenSpace::classifyBlocksAfterMark() {
    retireDeadLargeBodies();
    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        const BlockId id = blocks_.idAt(pos);
        BlockInfo& b = blocks_.info(id);
        BufferMetadata& meta = blocks_.meta(id);
        if (b.is_large) {
            // The former lazySweep is_large branch, verbatim in effect.
            const bool live = testAndClearMarkBitInBlock(id, b.start);
            if (!live) {
                // A split-header body or a YLOS object (threaded-gc-04b):
                // the index is authoritative, whatever the tag.
                Header* hdr = reinterpret_cast<Header*>(b.start);
                if (hdr->pin) {
                    auto it = large_body_index_.find(b.start);
                    if (it != large_body_index_.end()) {
                        retireIndexEntry(it->second);
                        large_body_index_.erase(it);
                    }
                }
                meta.garbage_bytes = b.totalBytes();
                markBlockAsFreeLarge(id);
            }
            meta.fully_swept = true;
#if ENABLE_GC_STATS
            alloc_stats_.bm.blocks_classified_large++;
#endif
        } else if (b.size_class < num_size_classes_) {
            // Uniform: never lazily swept; queue if any cell is free.
            meta.fully_swept = true;
            const size_t cap =
                static_cast<size_t>(cellsIn(b)) * classToSize(b.size_class);
            if (meta.live_bytes < cap && b.alloc_state != kAllocQueued &&
                b.alloc_state != kAllocTenure) {
                // (threaded-gc-05a: a deferred free at the handoff may have
                // queued it already through freeUniformCell.)
                partial_[b.size_class].push_back(id);
                b.alloc_state = kAllocQueued;
#if ENABLE_GC_STATS
                alloc_stats_.bm.bitmap_free_bytes_at_major += cap - meta.live_bytes;
#endif
            }
#if ENABLE_GC_STATS
            alloc_stats_.bm.blocks_classified_uniform++;
#endif
        } else {
#if ENABLE_GC_STATS
            alloc_stats_.bm.blocks_classified_mixed++;
#endif
        }
    }
    // threaded-gc-04b: dead YLOS objects were retired above (both paths).
    recomputeYoungLargeBounds();
#if ECO_HEAP_VALIDATE
    // V12 (HEAP_056): every surviving nursery-owned body is marked.
    for (const auto& kv : large_body_index_) {
        void* body = kv.first;
        const BlockId bid = contains(body) ? blockIdFor(body) : NO_BLOCK_ID;
        if (bid.valid() && !blocks_.info(bid).is_large &&
            !isMarkedInBlock(bid, body)) {
            std::fprintf(stderr, "[heap-validate] classifyBlocksAfterMark: "
                "V12: unmarked body %p left in large_body_index_\n", body);
            std::fflush(stderr);
            std::abort();
        }
    }
#endif
}
// TLA-REGION(OGS.classifyBlocksAfterMark) end

// ---------------------------------------------------------------------------
// Small-class block budget bookkeeping.
// ---------------------------------------------------------------------------

void OldGenSpace::recomputeSmallClassLimit() {
    if (config_ == nullptr ||
        config_->small_class_heap_budget_bytes == 0) {
        small_class_index_limit_ = 0;
        return;
    }
    const size_t cap = config_->small_class_cell_max_bytes;
    size_t limit = 0;
    while (limit < num_size_classes_ && classToSize(limit) <= cap) {
        ++limit;
    }
    small_class_index_limit_ = limit;
}

void OldGenSpace::onUniformBlockDedicated(BlockId block_index) {
    if (!block_index.valid()) return;
    const BlockInfo& blk = blocks_.info(block_index);
    if (blk.is_large) return;
    if (!isSmallClassIndex(blk.size_class)) return;
    small_class_bytes_ += blk.totalBytes();
}

void OldGenSpace::onBlockReleased(BlockId block_index) {
    if (!block_index.valid()) return;
    const BlockInfo& blk = blocks_.info(block_index);
    if (blk.is_large) return;
    if (!isSmallClassIndex(blk.size_class)) return;
    const size_t bytes = blk.totalBytes();
    small_class_bytes_ = (small_class_bytes_ >= bytes)
                             ? small_class_bytes_ - bytes
                             : 0;
}

void OldGenSpace::onBlockTransitioningToLarge(BlockId block_index) {
    onBlockReleased(block_index);
}

bool OldGenSpace::shouldPreferBagForSmallClass(size_t cls) const {
    if (config_ == nullptr) return false;
    if (config_->small_class_heap_budget_bytes == 0) return false;
    if (!isSmallClassIndex(cls)) return false;
    if (small_class_bytes_ >= config_->small_class_heap_budget_bytes) {
        return false;
    }
    return committedToCapRatio() < 1.0;
}

// TLA-REGION(OGS.blockIdFor) begin
BlockId OldGenSpace::blockIdFor(const void* obj) const {
    const char* p = static_cast<const char*>(obj);
    // threaded-gc-05c (H3-H5): background markers call this while the mutator
    // adds blocks; region bounds are relaxed atomics (they only grow during a
    // cycle), the committed count and the owner words acquire loads.
    if (p < regionBase() || p >= regionEnd()) return NO_BLOCK_ID;
    const size_t page =
        static_cast<size_t>(p - index_base_) / config_->alloc_buffer_size;
    if (page < page_index_.committed()) {   // HEAP_049: never read uncommitted
        const PageOwners& slot = page_index_.data()[page];
        const BlockId a = decodeOwner(loadOwner(slot.primary));
        if (a.valid()) {
            const BlockInfo& blk = blocks_.info(a);
            if (p >= blk.start && p < blk.end) return a;
        }
        const BlockId b = decodeOwner(loadOwner(slot.secondary));
        if (b.valid()) {
            const BlockInfo& blk = blocks_.info(b);
            if (p >= blk.start && p < blk.end) return b;
        }
    }
    return NO_BLOCK_ID;
}
// TLA-REGION(OGS.blockIdFor) end

/**
 * Allocates memory in the old generation.
 *
 * Dispatch:
 *   1. Drive incremental marking work proportional to allocation size.
 *   2. size >= alloc_buffer_size  -> allocateLargeBlock (dedicated pinned).
 *   3. cls < num_size_classes_    -> allocateFromSizeClass (size-class fast path).
 *   4. otherwise (LOT <= size < alloc_buffer_size) -> allocateFromBagPage (split).
 */
void *OldGenSpace::allocate(size_t size) {
#if ECO_HEAP_VALIDATE
    const DecisionScope im16(*this);   // IM16: the allocation ladder decides
#endif
    size = (size + 7) & ~7;  // Align to 8 bytes.

    // Record the requested (post-alignment) size into the size-distribution
    // histogram. Done up front so allocations that fail later (return nullptr)
    // still show up as demand on the old-gen size-class distribution.
    GC_STATS_OLDGEN_RECORD_ALLOC(alloc_stats_, size);

    // Bracket the entire allocate() body. Even with gc_phase_ == Idle the
    // dispatch tail can do real allocator work (free-list walks, page
    // splits, BBoP page acquire); when gc_phase_ != Idle the body also
    // runs incremental mark + lazy sweep slices, plus — via lazySweep →
    // onSweepComplete — a maybeShrinkCapacity → releaseBlockToAllocator
    // cascade. None of that is mutator user code. Routes elapsed wall-time
    // to the mutator counter; so the accounting identity is:
    //   wall_s = minor + major + nursery_alloc_in_mutator
    //          + oldgen_alloc_in_mutator + true_mutator.
    //
    // ONLY MUTATOR-CONTEXT CALLS ARE TIMED. When in_minor_gc_ is set this is
    // a promotion: allocate() is then called once per promoted object by the
    // three nursery evacuation copiers (NurserySpace.cpp evacuate / JIT-root
    // copier / list-spine copier), ~7e8 times per self-compile. Those calls
    // are ALREADY inside the minor-GC bracket (NurserySpace::minorGC), so
    // timing them again bought a nested sub-counter at the price of two vdso
    // clock reads per promoted object — several percent of wall. The "two
    // clock reads is ~40 ns, negligible vs the dispatch" note this bracket
    // used to carry was written for the mutator path (large/pinned and region
    // allocations, a few hundred ms per run in total); it was never true of
    // the promotion path, where the dispatch is a size-class free-list pop.
#if ENABLE_GC_STATS
    const bool timed = !in_minor_gc_;
    std::chrono::high_resolution_clock::time_point helper_t0;
    if (timed) {
        helper_t0 = GC_STATS_TIMER_START();
    }
#endif

    // W0 item 13: the allocation-paced marking branch that stood here was
    // DEAD. It ran under `gc_phase_ == GCPhase::Marking`, and when it was
    // removed gc_phase_ was assigned at four sites — Idle (initialize),
    // Sweeping (transitionToSweeping), Idle (reclaim), Idle (reset) — and
    // never Marking. (No longer so, CR-027: since threaded-gc-05a
    // beginMarkCycle sets Marking for an incremental cycle, and
    // handoffMarkCycle and a completing lazySweep set Idle. A cycle's marking
    // is driven by its steps, never per allocation, so the branch stays
    // gone.) A STW major marks synchronously in finishMarkAndSweep, which
    // still calls incrementalMark; only this per-allocation branch is gone.
    // Confirmed empirically before removal: the 2026-09-22 sensitivity sweep
    // ran mark_work_ratio at 1 / 2 / 4 and every GC counter was bit-identical,
    // which is only possible if this branch never executes.

    // Drive lazy sweep work to make sure free lists fill up before we exhaust
    // the bag. Without this, all unassigned pages can be consumed before the
    // sweep ever returns garbage to a free list.
    if (gc_phase_ == GCPhase::Sweeping) {
        // W7 item 14: when this allocation is a PROMOTION (in_minor_gc_), the
        // sweep work it drives lands inside the minor pause. Throttle it by
        // minor_sweep_divisor rather than gating it outright: the work still
        // has to happen, and skipping it entirely lets the heap grow while
        // unswept garbage remains (plans/sweep-on-demand-allocation.md).
        // divisor 1 = today, 0 = full gate.
        size_t budget = config_->sweep_work_budget;
        if (in_minor_gc_) {
            const size_t d = config_->minor_sweep_divisor;
            budget = (d == 0) ? 0 : budget / d;
        }
        if (budget > 0) {
            size_t cls_for_sweep = sizeClass(size);
#if ENABLE_GC_PHASE_TIMERS
            // threaded-gc-00: promotion-path sweep bytes (exact) and time
            // (1-in-16 deterministic sample). Measurement only.
            if (in_minor_gc_) {
                if (promo_instr_.sweep.shouldSample()) {
                    const uint64_t t0 = GCStats::nowSinceProcessStartNs();
                    promo_instr_.sweep_bytes += lazySweep(cls_for_sweep, budget);
                    promo_instr_.sweep.sampled_ns += GCStats::nowSinceProcessStartNs() - t0;
                    promo_instr_.sweep.sampled_calls++;
                } else {
                    promo_instr_.sweep_bytes += lazySweep(cls_for_sweep, budget);
                }
            } else
#endif
            lazySweep(cls_for_sweep, budget);
        }
    }

    // Path 2/3/4 dispatch. These are inside the helper bracket because
    // allocateFromSizeClass can invoke sweepOnDemandAllocate, which runs
    // up to max_sweep_bytes_per_alloc of lazySweep work — this
    // is the dominant source of "minor GC outliers" when promotion calls
    // hit it during an old-gen sweep phase. allocateFromBagPage and
    // allocateLargeBlock are also covered for completeness; their cost is
    // small but non-zero (bag-page pulls, mmap commit) and they too can
    // run in either gc_phase_ context.
    void* result;
#if ENABLE_GC_PHASE_TIMERS
    // threaded-gc-00: sample the allocator's own cost per promotion (the
    // dispatch below; the upfront sweep slice above is measured separately,
    // so the two estimates never double-count). 1-in-256, deterministic.
    const bool sample_alloc = in_minor_gc_ && promo_instr_.alloc.shouldSample();
    const uint64_t t_alloc0 = sample_alloc ? GCStats::nowSinceProcessStartNs() : 0;
#endif
    if (size >= config_->alloc_buffer_size) {
        // Path 2: large objects bypass the BBoP and get a dedicated pinned block.
        result = allocateLargeBlock(size);
    } else {
        size_t cls = sizeClass(size);
        if (cls < num_size_classes_) {
            // Path 3: size-class fast path (small or medium).
            result = allocateFromSizeClass(cls, size);
        } else {
            // Path 4: in [largest fixed-cell size, alloc_buffer_size). Pull a
            // page, wrap as one big Tag_Free, split off the requested chunk.
            result = allocateFromBagPage(size);
        }
    }
#if ENABLE_GC_PHASE_TIMERS
    if (sample_alloc) {
        promo_instr_.alloc.sampled_ns += GCStats::nowSinceProcessStartNs() - t_alloc0;
        promo_instr_.alloc.sampled_calls++;
    }
#endif

#if ENABLE_GC_STATS
    if (timed) {
        alloc_stats_.total_oldgen_alloc_in_mutator_ns +=
            GC_STATS_TIMER_ELAPSED_NS(helper_t0);
    }
#endif
#if ECO_HEAP_VALIDATE
    if (cycleActive()) noteCycleAllocation(result);   // threaded-gc-05a IM4
#endif

    return result;
}

// ---------------------------------------------------------------------------
// Helpers for size-class slack handling in MIXED blocks.
// ---------------------------------------------------------------------------
//
// Sweep walks size-class blocks by classToSize(block.size_class) (fixed step)
// and MIXED blocks by getObjectSize (object's logical size). When a size-class
// allocation lands in a MIXED block (e.g. via tryAllocateBySplittingLarger
// from a coalesced span), the object's hdr->size formula gives back
// requested_size, but the cell that backs it is classToSize(cls) bytes wide.
// The slack `cell_size - requested_size` is invisible to the object's size
// formula, so a MIXED-block sweep walks into it and mis-interprets zero
// bytes as Tag_Int(0) objects.
//
// Fix: write a Tag_Free trailing header at `obj + requested_size` whenever
// there is slack >= sizeof(Header). For MIXED blocks the trailing makes
// sweep step over the slack correctly. For size-class blocks the trailing
// is unread (sweep walks by fixed cellSize), so it's a no-op there.
static inline void padCellSlack(void* obj, size_t requested_size,
                                size_t cell_size) {
    requested_size = (requested_size + 7) & ~static_cast<size_t>(7);
    if (cell_size <= requested_size) return;
    const size_t slack = cell_size - requested_size;
    if (slack < sizeof(Header)) return;
    Header* trailing = reinterpret_cast<Header*>(
        static_cast<char*>(obj) + requested_size);
    std::memset(trailing, 0, sizeof(Header));
    trailing->tag = Tag_Free;
    trailing->size = static_cast<u32>(slack);
    trailing->color = static_cast<u32>(Color::White);
    // age stays 0 (memset): trailing slack is not on a free list, so it must
    // remain coalescable for the next sweep walk.
}

// ---------------------------------------------------------------------------
// Size-class fast path.
// ---------------------------------------------------------------------------

// Pure free-list pop. Splitting and finalisation are split helpers below
// so the small-class budget path can interpose between exact-fit and split.
// TLA-REGION(OGS.tryPopFromFreeList) begin
FreeCell* OldGenSpace::tryPopFromFreeList(size_t cls) {
    assert(cls < NUM_SIZE_CLASSES);
    FreeCell* cell = free_lists_[cls];
    if (cell == nullptr) return nullptr;
    free_lists_[cls] = cell->next_in_class;
    if (isTierM(cell)) {
        // Tier-M head pop: repaint the new head's back-link to "head",
        // then unlink the popped cell from its block thread.
        if (free_lists_[cls] != nullptr) {
            setPrevHead(asTierM(free_lists_[cls]));
        }
        const BlockId blk_id = blockIdFor(cell);
        if (blk_id.valid()) {
            blockThreadUnlink(blocks_.info(blk_id), cell);
        }
    }
    return cell;
}
// TLA-REGION(OGS.tryPopFromFreeList) end

// Finalises a popped free cell into a usable object: writes the header,
// pads any slack, and accounts for the cell's bytes.
// TLA-REGION(OGS.finalizePoppedCell) begin
void* OldGenSpace::finalizePoppedCell(FreeCell* cell, size_t cls,
                                      size_t requested_size) {
    void* result = static_cast<void*>(cell);
    const size_t cell_size = classToSize(cls);
    initObjectHeaderWithSize(result, cell_size);
    // The in-lock pop: the colour is initObjectHeaderWithSize's phase decision.
    ECO_M4_TRACE("m4.pop", "cb", cell_size, "blk", ECO_M4_BLK(result), "c", ECO_M4_BIT(result),
                 "black", getHeader(result)->color == static_cast<u32>(Color::Black), "rd", "phase",
                 "val", getHeader(result)->color == static_cast<u32>(Color::Black)
                     ? static_cast<int>(cycle_state_ != CycleState::Idle ? GCPhase::Marking : GCPhase::Sweeping) : 0);
    padCellSlack(result, requested_size, cell_size);
    allocated_bytes += cell_size;
    old_alloc_total_ += cell_size;   // 05c P-hat (monotone)
    return result;
}
// TLA-REGION(OGS.finalizePoppedCell) end

// Free-list-only allocation. Pure refactor of the original first two
// paragraphs of allocateFromSizeClass — does NOT consume a bag page or
// grow committed capacity.
// TLA-REGION(OGS.tryAllocateFromFreeLists) begin
void* OldGenSpace::tryAllocateFromFreeLists(size_t cls, size_t requested_size) {
    assert(cls < NUM_SIZE_CLASSES);

    if (FreeCell* cell = tryPopFromFreeList(cls)) {
        return finalizePoppedCell(cell, cls, requested_size);
    }

    if (void* result = tryAllocateBySplittingLarger(cls, classToSize(cls))) {
        padCellSlack(result, requested_size, classToSize(cls));
        ECO_M4_TRACE("m4.split", "cb", classToSize(cls), "blk", ECO_M4_BLK(result), "c", ECO_M4_BIT(result));
        return result;
    }

    return nullptr;
}
// TLA-REGION(OGS.tryAllocateFromFreeLists) end

// Approximate committed-to-cap ratio. Numerator is this thread's old-gen
// committed bytes; denominator is the global old-gen cap
// (Allocator::getOldGenMaxBytes, HEAP_043) — NOT a locally re-derived
// `max_heap_size / 2`, which stopped being the cap once the split became
// configurable and which diverged from the real cap after any reset().
double OldGenSpace::committedToCapRatio() const {
    if (config_ == nullptr || config_->max_heap_size == 0) return 0.0;
    const size_t cap = allocator_ ? allocator_->getOldGenMaxBytes()
                                  : config_->oldGenCapBytes();
    if (cap == 0) return 0.0;
    const double ratio =
        static_cast<double>(getCommittedBytes()) / static_cast<double>(cap);
    if (ratio < 0.0) return 0.0;
    if (ratio > 1.0) return 1.0;
    return ratio;
}

// Computes the dynamic per-allocation lazy-sweep byte budget. Combines a
// base proportional to `requested_size`, a piecewise pressure step on the
// committed/cap ratio, and an unswept-fraction boost. Final value is
// clamped to config.max_sweep_bytes_hard.
size_t OldGenSpace::computeSweepBudgetForAlloc(size_t requested_size) const {
    const HeapConfig& cfg = *config_;

    // Base: bytes-per-alloc-byte, clamped to [sweep_work_budget,
    // max_sweep_bytes_per_alloc]. Anything smaller than sweep_work_budget
    // would not even cover a single slice; anything larger pre-scaling
    // would let a single allocation monopolise the sweeper before the
    // pressure scaling has a chance to kick in.
    double base = static_cast<double>(requested_size) *
                  cfg.sweep_bytes_per_alloc_byte;
    if (base < static_cast<double>(cfg.sweep_work_budget)) {
        base = static_cast<double>(cfg.sweep_work_budget);
    } else if (base > static_cast<double>(cfg.max_sweep_bytes_per_alloc)) {
        base = static_cast<double>(cfg.max_sweep_bytes_per_alloc);
    }

    // Piecewise pressure scale. Pressure is committed/cap on the old gen.
    const double pressure = committedToCapRatio();
    double scale;
    if (pressure < cfg.sweep_cap_ratio_low) {
        scale = cfg.sweep_scale_low;
    } else if (pressure < cfg.sweep_cap_ratio_medium) {
        scale = cfg.sweep_scale_medium;
    } else if (pressure < cfg.sweep_cap_ratio_high) {
        scale = cfg.sweep_scale_high;
    } else {
        scale = cfg.sweep_scale_crit;
    }
    double budget = base * scale;

    // Unswept-fraction boost: when most of the cycle's blocks haven't been
    // swept yet, the heap is much more likely to have reclaimable garbage
    // sitting in pending blocks than in newly-grown capacity, so we trade
    // a higher per-alloc slice for shorter time-to-free-cell.
    if (sweep_total_blocks_ > 0) {
        const double unswept_fraction =
            static_cast<double>(sweep_pending_blocks_) /
            static_cast<double>(sweep_total_blocks_);
        if (unswept_fraction > cfg.sweep_unswept_ratio_boost) {
            budget *= cfg.sweep_unswept_scale;
        }
    }

    if (budget > static_cast<double>(cfg.max_sweep_bytes_hard)) {
        budget = static_cast<double>(cfg.max_sweep_bytes_hard);
    }
    if (budget < static_cast<double>(cfg.sweep_work_budget)) {
        budget = static_cast<double>(cfg.sweep_work_budget);
    }
    return static_cast<size_t>(budget);
}

// Sweep-on-demand emergency driver. Computes a dynamic byte budget from
// allocation size, committed/cap pressure, and unswept-fraction; runs
// sweep_work_budget-sized slices of `lazySweep` until either the free-list
// path can satisfy the request or the dynamic budget is exhausted. The
// caller falls through to populateFromBlock / allocateFromBagPage when this
// returns nullptr. Note: requested slice == accounted bytes — `lazySweep`
// uses `work_budget` as a byte budget for `work_done`, so charging `slice`
// directly may slightly over-estimate when sweep ends mid-slice (safe
// direction for pacing).
// TLA-REGION(OGS.sweepOnDemandAllocate) begin
void* OldGenSpace::sweepOnDemandAllocate(size_t cls, size_t requested_size) {
    if (void* obj = tryAllocateFromFreeLists(cls, requested_size)) {
        return obj;
    }
    ECO_M4_TRACE("m4.npop", "cb", classToSize(cls));
    if (!hasPendingSweepWork()) return nullptr;

    const size_t max_sweep_bytes = computeSweepBudgetForAlloc(requested_size);
    size_t swept = 0;
    while (hasPendingSweepWork() && swept < max_sweep_bytes) {
        const size_t remaining = max_sweep_bytes - swept;
        const size_t slice = std::min<size_t>(config_->sweep_work_budget, remaining);
        lazySweep(cls, slice);
        swept += slice;
#if ENABLE_GC_STATS
        alloc_stats_.total_lazy_sweep_bytes_in_mutator += slice;
#endif
        if (void* obj = tryAllocateFromFreeLists(cls, requested_size)) {
            return obj;
        }
        ECO_M4_TRACE("m4.npop", "cb", classToSize(cls));
    }
    return nullptr;
}
// TLA-REGION(OGS.sweepOnDemandAllocate) end

// Panic-mode sweep: drives any remaining lazy-sweep work to completion in
// panic_sweep_slice_bytes slices and retries the free-list path between
// slices. The "growth impossible" precondition lives at the call site —
// `allocateFromSizeClass` only invokes this once `allocateFromBagPage` has
// already failed to grow capacity.
// TLA-REGION(OGS.panicSweepAndRetryAllocation) begin
void* OldGenSpace::panicSweepAndRetryAllocation(size_t cls,
                                                size_t requested_size) {
    if (!hasPendingSweepWork()) return nullptr;
    const size_t panic_slice = config_->panic_sweep_slice_bytes;
    while (hasPendingSweepWork()) {
        lazySweep(cls, panic_slice);
#if ENABLE_GC_STATS
        alloc_stats_.total_panic_sweep_bytes += panic_slice;
#endif
        if (void* obj = tryAllocateFromFreeLists(cls, requested_size)) {
            return obj;
        }
        ECO_M4_TRACE("m4.npop", "cb", classToSize(cls));
    }
    return nullptr;
}
// TLA-REGION(OGS.panicSweepAndRetryAllocation) end

void* OldGenSpace::allocateFromSizeClass(size_t cls, size_t requested_size) {
    assert(cls < num_size_classes_ && "size class out of range");
    // threaded-gc-02: the flag-on ladder (P§3.4). The body below is the
    // untouched legacy ladder.
    if (config_->old_gen_bitmap_alloc) {
        return allocateFromSizeClassBitmap(cls, requested_size);
    }

    // (1) Exact-fit pop from free_lists_[cls]. No splitting yet.
    if (FreeCell* cell = tryPopFromFreeList(cls)) {
        return finalizePoppedCell(cell, cls, requested_size);
    }

    // (2) Bag-first for small classes while under the budget. Re-pop after
    //     population; the heap-base detour produces non-uniform output, in
    //     which case the re-pop misses and we fall through.
    if (shouldPreferBagForSmallClass(cls)) {
        if (populateFromBlock(cls)) {
            if (FreeCell* cell = tryPopFromFreeList(cls)) {
                return finalizePoppedCell(cell, cls, requested_size);
            }
        }
    }

    // (3) Splitting: try carving a cell out of a larger free cell.
    if (void* result = tryAllocateBySplittingLarger(cls, classToSize(cls))) {
        padCellSlack(result, requested_size, classToSize(cls));
        return result;
    }

    // (4) Sweep-before-grow: while unswept blocks remain, drive lazy sweep
    //     until either the request is satisfied or the per-call cap is hit.
    if (hasPendingSweepWork()) {
        if (void* result = sweepOnDemandAllocate(cls, requested_size)) {
            return result;
        }
    }

    // (5) Pull a page from the bag and slice it into uniform cells. Used
    //     both when the small-class budget is exhausted and when (2) was
    //     skipped because the class is not in the small-class budget range.
    if (populateFromBlock(cls)) {
        if (FreeCell* cell = tryPopFromFreeList(cls)) {
            return finalizePoppedCell(cell, cls, requested_size);
        }
    }

    // (6) Last resort: split from a freshly-pulled page treated as one big
    //     cell. allocateFromBagPage accounts for its own bytes.
    if (void* result = allocateFromBagPage(requested_size)) {
        return result;
    }

    // (7) Panic sweep: bag-page acquisition failed, so growth is impossible.
    //     Drive any remaining lazy-sweep work to completion before OOM.
    if (void* result = panicSweepAndRetryAllocation(cls, requested_size)) {
        return result;
    }

    return nullptr;
}

// ---------------------------------------------------------------------------
// Splitting a larger cell to satisfy a smaller request.
// ---------------------------------------------------------------------------
void* OldGenSpace::tryAllocateBySplittingLarger(size_t target_cls,
                                                size_t alloc_size) {
    // Walk higher classes; for each, scan the free list for a cell large
    // enough to satisfy `alloc_size` while leaving room for either an
    // allocation or a usable Tag_Free remainder.
    //
    // Uniformity invariant: cells inside a size-class block (block.size_class
    // < NUM_SIZE_CLASSES) MUST all be exactly classToSize(block.size_class)
    // bytes — sweep walks such blocks by that fixed step, and a smaller
    // sub-cell embedded in such a block would cause sweep to mis-step
    // mid-cell. Splitting is reserved for cells in mixed blocks
    // (size_class == NUM_SIZE_CLASSES) — those came from
    // `allocateFromBagPage` and sweep walks them by header size.
    //
    // Performance shortcut: cells on free_lists_[N] for N < num_size_classes_
    // could be in EITHER a uniform-N block (the common case, from
    // populateFromBlock) OR a mixed block (rare, from sweep coalescing in
    // mixed blocks). Calling `findBlockContaining` per cell is O(blocks_)
    // which dominates Stage-7 mutator time. Conservative treat-as-uniform:
    // for cls < num_size_classes_, only accept EXACT fits. Cells on classes
    // >= num_size_classes_ exist only in mixed blocks (no uniform block
    // populates those classes), so splits from those are safe with a
    // null block-context.
    //
    // Skip uniform classes outright: only walk classes >= num_size_classes_.
    //
    // Two callers shape the start formula:
    //   * `allocateFromSizeClass` (target_cls < num_size_classes_): an
    //     exact-fit pop has already been tried at target_cls in step 1, and
    //     for cls in (target_cls, num_size_classes_) the cells (uniform-class)
    //     can't be split safely, so we begin at num_size_classes_. The
    //     `target_cls + 0 vs +1` distinction is irrelevant here because
    //     max(...) clamps to num_size_classes_ anyway.
    //   * `allocateFromBagPage` (target_cls >= num_size_classes_): cells on
    //     free_lists_[target_cls] live in mixed blocks and CAN be exact-fit
    //     popped or split. Walking should begin AT target_cls, not above it,
    //     so the reuse ladder finds them. Hence `max(target_cls, ...)` rather
    //     than `max(target_cls + 1, ...)`.
    const size_t start_cls = std::max(target_cls, num_size_classes_);
    for (size_t cls = start_cls; cls < NUM_SIZE_CLASSES; ++cls) {
        if (free_lists_[cls] == nullptr) continue;

        FreeCell** prev = &free_lists_[cls];
        FreeCell* curr = free_lists_[cls];
        while (curr != nullptr) {
            const size_t cell_bytes = curr->header.size;
            const size_t remainder = (cell_bytes >= alloc_size)
                                         ? cell_bytes - alloc_size
                                         : 0;

            if (cell_bytes >= alloc_size &&
                (remainder == 0 || remainder >= MIN_FREE_CELL_SIZE)) {
                // start_cls is clamped to >= num_size_classes_, so every
                // cell we walk here is a mixed-class cell of size >=
                // MIN_TIER_M_SIZE — i.e. always Tier-M.
                FreeCell* next_in_class = curr->next_in_class;
                // Class-list unlink (O(1) for Tier-M via the back-link).
                *prev = next_in_class;
                if (next_in_class != nullptr) {
                    copyPrev(asTierM(next_in_class), asTierM(curr));
                }

                char* base = reinterpret_cast<char*>(curr);
                const BlockId blk_id = blockIdFor(base);
                if (blk_id.valid()) {
                    blockThreadUnlink(blocks_.info(blk_id), curr);
                }

                if (remainder > 0) {
                    BlockInfo* blk =
                        blk_id.valid() ? &blocks_.info(blk_id) : nullptr;
                    // Use the on-free-list sentinel when sweep is in
                    // progress and the containing block hasn't been swept
                    // yet — otherwise the upcoming sweep slice would
                    // coalesce over this still-linked remainder and emit a
                    // duplicate push of the same byte range at the same
                    // class, forming a cycle in free_lists_. Mirrors the
                    // freeLargeBodyCell sentinel-during-sweep logic.
                    bool need_sentinel =
                        (gc_phase_ == GCPhase::Sweeping) &&
                        (!blk_id.valid() ||
                         !blocks_.meta(blk_id).fully_swept);
#if ECO_HEAP_VALIDATE
                    PushOriginScope _origin("splitter::remainder");
#endif
                    // threaded-gc-02 (P§3.7): in bitmap mode no list cell lies
                    // where the sweep will still walk, so the remainder never
                    // needs a sentinel.
                    if (config_->old_gen_bitmap_alloc) {
                        assert(!(blk_id.valid() &&
                                 sweepWillReach(blk_id, base + alloc_size)) &&
                               "splitter remainder ahead of the sweep in bitmap mode");
                        need_sentinel = false;
                    }
                    if (need_sentinel) free_list_sentinel_count_++;
                    pushSpanOnFreeLists(free_lists_, base + alloc_size,
                                        remainder, blk, blk_id,
                                        need_sentinel);
                }

                void* result = static_cast<void*>(base);
                initObjectHeaderWithSize(result, alloc_size);
                allocated_bytes += alloc_size;
                old_alloc_total_ += alloc_size;   // 05c P-hat (monotone)
                return result;
            }

            prev = &curr->next_in_class;
            curr = curr->next_in_class;
        }
    }

    return nullptr;
}

// ---------------------------------------------------------------------------
// Page-as-single-cell + split path.
// ---------------------------------------------------------------------------
// TLA-REGION(OGS.allocateFromBagPage) begin
void* OldGenSpace::allocateFromBagPage(size_t requested_size) {
    // ----- Reuse ladder for the (LOT, alloc_buffer_size) band -----
    //
    // Before committing or pulling a fresh page, try to satisfy the request
    // out of existing free space living on the mixed-only large free-list
    // classes (16 KiB / 32 KiB / 64 KiB with the default config). These
    // cells are produced by:
    //   * sweep coalescing dead spans in mixed blocks (the
    //     `pushSpanOnFreeLists` mixed packer routes the bulk of any large
    //     coalesced run onto these classes), and
    //   * uniform → mixed demotion in `demoteMostlyDeadUniformBlocks`.
    // The previous code path skipped this pool entirely and grew `blocks_`
    // by one page per visit, making the ≥-LOT allocator the dominant driver
    // of committed-heap growth. The ladder below mirrors steps 1, 3, and 4
    // of `allocateFromSizeClass` for size-classed requests.

    const size_t request_cls = sizeClass(requested_size);
    // Callers (register CR-029):
    //   * `allocate`'s large-object path (Path 4: the (LOT, alloc_buffer_size)
    //     band, request_cls >= num_size_classes_);
    //   * `allocatePromotion`'s large-object branch (the same band, under
    //     promo_mu_);
    //   * the bitmap mutator ladder's rung 7 (`allocateFromSizeClassBitmap`);
    //   * `ladderFrom2W`'s bag rung (a promotion worker, under promo_mu_);
    //   * legacy `allocateFromSizeClass` step 6.
    // The last three pass a SIZE-CLASSED request (request_cls <
    // num_size_classes_) once their virgin-block / populateFromBlock rung has
    // failed: the bag is empty and acquireOldGenBlock failed (the old-gen
    // reservation is exhausted), or, in a parallel promotion, the other
    // workers' chunk claims emptied the block this worker had just published.
    // Such a request takes the same steps as one in the band. Every step
    // carves exactly `requested_size` bytes out of a MIXED block (a cell of a
    // mixed-only free-list class, or offset 0 of a fresh page materialized as
    // a mixed block) and returns the tail as Tag_Free cells. In a mixed block
    // the walk (walkStepFor) and the mark attribution (markOneObject) use the
    // object's own size, never classToSize, so a carve smaller than the
    // class's cell leaves the block parseable and its live_bytes exact; a
    // carve is counted in live_bytes in every phase, and black mid-cycle
    // (initObjectHeaderWithSize; CR-018, HEAP_073). The precondition is therefore only the one
    // every caller establishes: `allocate` and `allocatePromotion` round the
    // size up to 8 and send anything >= alloc_buffer_size to
    // allocateLargeBlock before any ladder runs.
    assert(requested_size < config_->alloc_buffer_size &&
           (requested_size & 7) == 0 &&
           "allocateFromBagPage: request must be 8-byte aligned and below alloc_buffer_size");

    // Step 1: split or exact-fit from the mixed-only free lists. The widened
    // `start_cls = max(target_cls, num_size_classes_)` in
    // `tryAllocateBySplittingLarger` makes the walk include `request_cls`
    // itself, so cells of size classToSize(request_cls) (the common case
    // produced by `pushSpanOnFreeLists`) participate. `requested_size` is
    // passed as `alloc_size` so the carve matches the request exactly and
    // the tail goes back as a Tag_Free cell — no internal slack.
    if (void* result =
            tryAllocateBySplittingLarger(request_cls, requested_size)) {
        return result;
    }

    // Step 2: drive bounded lazy sweep and retry. Sweep coalesces dead spans
    // in survivor blocks into bigger Tag_Free cells, which often unlocks a
    // fit when the free pool is exhausted of cells >= requested_size but
    // the heap still has plenty of unswept garbage. Same dynamic budget the
    // size-classed path uses (see `sweepOnDemandAllocate` / step 4 of
    // `allocateFromSizeClass`).
    if (hasPendingSweepWork()) {
        const size_t budget = computeSweepBudgetForAlloc(requested_size);
        size_t swept = 0;
        while (hasPendingSweepWork() && swept < budget) {
            const size_t slice =
                std::min<size_t>(config_->sweep_work_budget, budget - swept);
            lazySweep(request_cls, slice);
            swept += slice;
#if ENABLE_GC_STATS
            alloc_stats_.total_lazy_sweep_bytes_in_mutator += slice;
#endif
            if (void* result =
                    tryAllocateBySplittingLarger(request_cls, requested_size)) {
                return result;
            }
        }
    }

    // Step 3: fresh-page fallback. This is the original body of
    // `allocateFromBagPage` — pop (or commit) a page, wrap it as one
    // Tag_Free cell, carve off `requested_size`, push the remainder via
    // the mixed any-class packer.

    // Same fall-through as populateFromBlock: try to acquire a fresh page
    // from the OS if the bag is empty but address space remains.
    if (unassigned_blocks_.empty() && allocator_ != nullptr) {
        char* base = allocator_->acquireOldGenBlock(config_->alloc_buffer_size, acquireWaitPolicy());   // CR-007
        if (base != nullptr) {
            unassigned_blocks_.emplace_back(base, base + config_->alloc_buffer_size);
            if (char* const rb = regionBase(); rb == nullptr || base < rb) setRegionBase(base);
            if (base + config_->alloc_buffer_size > regionEnd()) {
                setRegionEnd(base + config_->alloc_buffer_size);
            }
            resizePageIndexForRegion();
        }
    }
    if (unassigned_blocks_.empty()) return nullptr;

    auto extent = unassigned_blocks_.back();
    unassigned_blocks_.pop_back();

    char* page_start = extent.first;
    char* page_end = extent.second;
    const size_t page_size = static_cast<size_t>(page_end - page_start);
    assert(requested_size <= page_size && "request larger than a single page");

    // The request is carved out of the whole page; the remainder is placed via
    // the mixed-block any-class packer. (There is no longer a heap-base sentinel:
    // under absolute addressing an object at heap_base is a valid non-null
    // pointer, so offset 0 need not be reserved — see plan D5.)
    char* alloc_base = page_start;
    const size_t alloc_span = page_size;
    assert(requested_size <= alloc_span &&
           "allocateFromBagPage: request larger than usable page span");

    // Materialize a BlockInfo for this page. Sweep parses up to end_of_objects;
    // we set it to the page end so the single Tag_Free below is parseable, and
    // any subsequent splits remain parseable as well.
    BlockInfo bi;
    bi.start = page_start;
    bi.end = page_end;
    bi.end_of_objects = page_end;
    bi.size_class = NUM_SIZE_CLASSES;  // mixed/non-uniform
    bi.is_large = false;
    // See populateFromBlock: mid-cycle blocks are marked fully_swept so
    // lazy sweep skips the freshly-placed Tag_Free cells.
    const bool mid_cycle =
        marking_active || gc_phase_ != GCPhase::Idle;
    const BlockId block_idx =
        materializeBlock(bi, {0, 0, mid_cycle}, bitmapBytesForBlock(bi));

    // Wrap the whole page as one Tag_Free cell, then split off the request.
    FreeCell* whole = reinterpret_cast<FreeCell*>(alloc_base);
    std::memset(&whole->header, 0, sizeof(Header));
    whole->header.tag = Tag_Free;
    whole->header.size = static_cast<u32>(alloc_span);
    whole->header.color = static_cast<u32>(Color::White);
    // age stays 0 (memset): this wrapper is immediately split via
    // pushSpanOnFreeLists with age_sentinel=false, so the coalescable default
    // is correct.

    // Carve the request off the front; route the remainder via the recursive
    // span-pusher so each placed cell exactly matches its class's cellSize.
    // The block was just created with size_class = NUM_SIZE_CLASSES (mixed),
    // so `pushSpanOnFreeLists` will use its any-class packing scheme.
    // CR-033 (HEAP_024): EVERY nonzero remainder goes through the pusher, whose
    // mixed branch gives a tail under MIN_FREE_CELL_SIZE an unlinked Tag_Free
    // header, so the page parses by object size over [start, end_of_objects).
    // (A request of alloc_buffer_size - 8 used to leave an 8-byte headerless
    // tail, which the legacy header sweep read as a 16-byte object: S1.)
    const size_t remainder = alloc_span - requested_size;
    assert((remainder & 7) == 0 && "allocateFromBagPage: the remainder is 8-aligned (the request is)");
    if (remainder != 0) {
#if ECO_HEAP_VALIDATE
        PushOriginScope _origin("populateMixed::remainder");
#endif
        pushSpanOnFreeLists(free_lists_, alloc_base + requested_size,
                            remainder, &blocks_.info(block_idx),
                            block_idx);
    }

    void* result = static_cast<void*>(alloc_base);
    initObjectHeaderWithSize(result, requested_size);
    allocated_bytes += requested_size;
    old_alloc_total_ += requested_size;   // 05c P-hat (monotone)
    return result;
}
// TLA-REGION(OGS.allocateFromBagPage) end

// ---------------------------------------------------------------------------
// Population from a bag page (uniform fixed-cell slicing for a class).
// ---------------------------------------------------------------------------
bool OldGenSpace::populateFromBlock(size_t cls) {
    // threaded-gc-02 (the W6 rule): with bitmap allocation, virgin blocks
    // replace this function at exactly its ladder rungs — reaching it means a
    // rung is wired wrong.
    assert(!config_->old_gen_bitmap_alloc &&
           "populateFromBlock reached in bitmap-allocation mode");
    // Bag empty but there's still address space below the global old-gen cap?
    // Acquire a fresh page on demand. This keeps progress alive when sweep
    // produced only small free cells (e.g. one live object per page).
    if (unassigned_blocks_.empty() && allocator_ != nullptr) {
        char* base = allocator_->acquireOldGenBlock(config_->alloc_buffer_size);
        if (base != nullptr) {
            unassigned_blocks_.emplace_back(base, base + config_->alloc_buffer_size);
            if (char* const rb = regionBase(); rb == nullptr || base < rb) setRegionBase(base);
            if (base + config_->alloc_buffer_size > regionEnd()) {
                setRegionEnd(base + config_->alloc_buffer_size);
            }
            resizePageIndexForRegion();
        }
    }
    if (unassigned_blocks_.empty()) return false;

    const size_t cell_bytes = classToSize(cls);
    if (cell_bytes < MIN_FREE_CELL_SIZE) return false;  // Defensive.

    auto extent = unassigned_blocks_.back();
    unassigned_blocks_.pop_back();

    char* page_start = extent.first;
    char* page_end = extent.second;
    const size_t page_size = static_cast<size_t>(page_end - page_start);

    const size_t num_cells = page_size / cell_bytes;

    if (num_cells == 0) {
        // Cell larger than page -- shouldn't happen because cell_bytes <=
        // largest medium class which is bounded by alloc_buffer_size/2 by
        // construction. Push the page back and bail.
        unassigned_blocks_.push_back(extent);
        return false;
    }

    // Materialize a BlockInfo for this page. end_of_objects is the end of
    // the cell area (the last partial bytes, if any, are not parsed).
    BlockInfo bi;
    bi.start = page_start;
    bi.end = page_end;
    bi.end_of_objects = page_start + num_cells * cell_bytes;
    bi.size_class = cls;
    bi.is_large = false;
    // Mid-cycle population (gc_phase_ != Idle) marks the block fully_swept
    // up front so lazy sweep won't re-visit and coalesce the Tag_Free cells
    // we just placed on free_lists_; doing so would overwrite their headers
    // and dangle the free-list pointers.
    const bool mid_cycle =
        marking_active || gc_phase_ != GCPhase::Idle;
    const BlockId block_idx =
        materializeBlock(bi, {0, 0, mid_cycle}, bitmapBytesForBlock(bi));

    // Slice into uniform Tag_Free cells and link onto the class's free list.
    // Push in reverse so iteration order matches address order.
    // age stays 0 (memset): uniform-page free cells are non-sentinel — when
    // mid-cycle, the block is pre-flagged fully_swept (mid_cycle below) so
    // sweep won't re-walk and rewrite them; when not mid-cycle, they're just
    // ordinary coalescable free cells. Resolved Decisions §1.
    const bool tier_m = isTierMSize(cell_bytes);
    BlockInfo& blk_ref = blocks_.info(block_idx);
    for (size_t i = num_cells; i > 0; --i) {
        char* cell_addr = page_start + (i - 1) * cell_bytes;
        FreeCell* cell = reinterpret_cast<FreeCell*>(cell_addr);
#if ECO_HEAP_VALIDATE
        g_first_push_origin[cell] = "populateFromBlock::uniform-page";
#endif
        std::memset(&cell->header, 0, sizeof(Header));
        cell->header.tag = Tag_Free;
        cell->header.size = static_cast<u32>(cell_bytes);
        cell->header.color = static_cast<u32>(Color::White);
        if (tier_m) {
            FreeCellMid* m = asTierM(cell);
            setPrevHead(m);
            m->next_in_class = free_lists_[cls];
            if (m->next_in_class != nullptr) {
                setPrev(asTierM(m->next_in_class), cell);
            }
            free_lists_[cls] = cell;
            blockThreadPushHead(blk_ref, cell);
        } else {
            cell->next_in_class = free_lists_[cls];
            free_lists_[cls] = cell;
        }
    }

    // Credit the small-class budget for this uniform page.
    onUniformBlockDedicated(block_idx);

    return true;
}

// ---------------------------------------------------------------------------
// Dedicated large block (>= alloc_buffer_size).
// ---------------------------------------------------------------------------

void OldGenSpace::markBlockAsFreeLarge(BlockId block_index) {
    assert(block_index.valid() && "markBlockAsFreeLarge: no block");
    assert(blocks_.info(block_index).is_large &&
           "markBlockAsFreeLarge: block must be is_large");
#if ECO_GC_DEBUG
    for (BlockId idx : free_large_blocks_) {
        assert(idx != block_index &&
               "markBlockAsFreeLarge: duplicate entry");
    }
#endif
    free_large_blocks_.push_back(block_index);
}

void* OldGenSpace::allocateFromFreeLargeBlocks(size_t size) {
    size = (size + 7) & ~7;

    for (size_t k = 0; k < free_large_blocks_.size(); ++k) {
        const BlockId idx = free_large_blocks_[k];
        if (!idx.valid()) continue;
        BlockInfo& blk = blocks_.info(idx);
        if (blk.totalBytes() < size) continue;

        // swap-remove from free list.
        free_large_blocks_[k] = free_large_blocks_.back();
        free_large_blocks_.pop_back();

        // Resurrect the BlockInfo: parseable region covers just the new
        // object so sweep walks one header.
        const size_t total = blk.totalBytes();
        blk.end_of_objects = blk.start + size;

        // Reset metadata.
        {
            BufferMetadata& meta = blocks_.meta(idx);
            meta.live_bytes = size;
            meta.garbage_bytes = (total >= size) ? (total - size) : 0;
            meta.fully_swept = true;
        }
        // Defensive zero of the bitmap before any mark/sweep can observe
        // this re-purposed block. The arena slot is empty (len 0) for
        // is_large blocks; the large-mark byte is the single live/dead bit.
        mark_.clearBlock(idx);
        blocks_.largeMark(idx) = 0;

        frag_stats_.live_bytes += size;
        allocated_bytes += size;
        old_alloc_total_ += size;   // 05c P-hat (monotone)

        initObjectHeader(blk.start);
        return static_cast<void*>(blk.start);
    }
    return nullptr;
}

// TLA-REGION(OGS.allocateFromEmptyRegularBlocks) begin
void* OldGenSpace::allocateFromEmptyRegularBlocks(size_t size) {
    // CR-016 (HEAP_054): with N > 1 workers a block's live_bytes == 0 is not a
    // fact: its cells may sit in another worker's claimed chunk (unflushed
    // pending_live, a retired shared block) or stash, which are invisible here.
    // allocateLargeBlock then takes a free large block or a fresh one. N = 1
    // keeps the flip: it has no stash and no chunks, and it flushes before it
    // retires a block.
    if (par_promo_active_ && promo_ctx_ && promo_ctx_->n > 1) {
#if ENABLE_GC_STATS
        alloc_stats_.bm.flip_skipped_parallel++;
#endif
        return nullptr;
    }
    syncCursorLiveBytes();   // threaded-gc-02: readers of live_bytes
    size = (size + 7) & ~7;

    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        const BlockId i = blocks_.idAt(pos);
        const BufferMetadata& meta = blocks_.meta(i);
        if (!meta.fully_swept || meta.live_bytes != 0) continue;
        if (blocks_.info(i).is_large) continue;
        // threaded-gc-06: a worker cursor's block holds unflushed pending
        // bytes (its live_bytes may read 0) and is invisible to detach.
        if (par_promo_active_ && blocks_.info(i).alloc_state == kAllocCurrent) continue;
        // threaded-gc-07 (trap 4): a granted block reads live_bytes 0 until
        // the merge; the collector may be filling it right now.
        if (blocks_.info(i).alloc_state == kAllocTenure) continue;
        if (blocks_.info(i).totalBytes() < size) continue;

        // Drop any embedded free cells before flipping is_large; otherwise
        // the next sweep would walk the now-large block as if it were a
        // size-class page.
        if (config_->old_gen_bitmap_alloc) detachFromAllocation(i);
        removeFreeCellsForBlock(i);
        // CR-035 (HEAP_056): the new object takes the block's start, so a dead
        // body or YLOS still indexed inside the block would name it (its later
        // free erases the new object's key, and the next minor frees a live
        // object). Retire every entry in the block, as retireDeadLargeBodies
        // does: the id is NOT recycled (release semantics would hand it to the
        // caller's registerLargeBody while nursery_owned_bodies_ still lists
        // it). After CR-018 the precondition is gone; this is defence in depth.
        {
            const BlockInfo& fb = blocks_.info(i);
            const size_t retired = retireIndexRange(fb.start, fb.end);
            (void)retired;
#if ENABLE_GC_STATS
            alloc_stats_.bm.empty_block_flips++;
            alloc_stats_.bm.flip_index_retired += retired;
#endif
#if ECO_HEAP_VALIDATE
            // Class 4 (as releaseBlockToAllocator): no entry may still resolve
            // into the flipped block.
            for (const auto& kv : large_body_index_) {
                char* body_base = static_cast<char*>(const_cast<void*>(kv.first));
                if (body_base >= fb.start && body_base < fb.end) {
                    std::fprintf(stderr,
                        "[heap-validate] large_body_index_ post-cleanup violation (flip): body_base=%p "
                        "still maps into flipped block [%p,%p) (idx=%zu)\n",
                        (void*)body_base, (void*)fb.start, (void*)fb.end, (size_t)i.v);
                    std::fflush(stderr);
                    std::abort();
                }
            }
#endif
        }

        // Debit the small-class budget for this block (if it was a uniform
        // small-class page) BEFORE we flip size_class to NUM_SIZE_CLASSES.
        onBlockTransitioningToLarge(i);

        BlockInfo& blk = blocks_.info(i);
#if ECO_HEAP_VALIDATE
        // 05c H9: only a post-t0 block may change is_large while markers run.
        if (isT0Block(i)) {
            std::fprintf(stderr, "[heap-validate] H9: t0 block %u flipped to large mid-cycle\n", i.v);
            std::fflush(stderr);
            std::abort();
        }
#endif
        const size_t total = blk.totalBytes();
        ECO_TLA_TRACE_ONLY(::Elm::tla_m4_flip = i.v;)   // M4: the empty-block flip (CR-016)
        blk.is_large = true;
        blk.size_class = NUM_SIZE_CLASSES;
        blk.end_of_objects = blk.start + size;

        BufferMetadata& m = blocks_.meta(i);
        m.live_bytes = size;
        m.garbage_bytes = (total >= size) ? (total - size) : 0;
        m.fully_swept = true;
        // Block flipped to is_large: drop the per-slot bitmap and use the
        // single large-mark byte. Defensive zero on both.
        mark_.drop(i);
        blocks_.largeMark(i) = 0;

        frag_stats_.live_bytes += size;
        allocated_bytes += size;
        old_alloc_total_ += size;   // 05c P-hat (monotone)

        initObjectHeader(blk.start);
        return static_cast<void*>(blk.start);
    }
    return nullptr;
}
// TLA-REGION(OGS.allocateFromEmptyRegularBlocks) end

// TLA-REGION(OGS.allocateLargeBlock) begin
void* OldGenSpace::allocateLargeBlock(size_t size) {
    assert(allocator_ && "OldGenSpace not initialized with Allocator");
    assert(size >= config_->alloc_buffer_size && "allocateLargeBlock used for small size");

    // 1) Reuse a dedicated large block whose object died in the last sweep.
    if (void* p = allocateFromFreeLargeBlocks(size)) return p;

    // 2) Repurpose a fully-free regular page large enough to host the object.
    if (void* p = allocateFromEmptyRegularBlocks(size)) return p;

    // 3) Acquire a fresh block from the Allocator.
    // mmap requires page-aligned offsets, and acquireOldGenBlock advances a
    // bump cursor by the requested size. Round up to the OS page boundary so
    // the next acquire stays aligned. OS_PAGE_SIZE is 16 KiB on Apple Silicon
    // (Darwin's hard requirement) and 4 KiB elsewhere — see AllocatorCommon.hpp.
    constexpr size_t kPageSize = OS_PAGE_SIZE;
    size_t block_size = (size + kPageSize - 1) & ~(kPageSize - 1);

    // CR-007: with n > 1 promotion workers (CR-016 sends their large
    // promotions here) the no-wait policy applies.
    char* block_base = allocator_->acquireOldGenBlock(block_size, acquireWaitPolicy());
    if (block_base == nullptr) {
        return nullptr;
    }

    // Materialize a BlockInfo for this large block. The single object spans
    // [start, start+size); end_of_objects is the end of that object so sweep
    // walks just the object header (no trailing parsing).
    BlockInfo bi;
    bi.start = block_base;
    bi.end = block_base + block_size;
    bi.end_of_objects = block_base + size;
    bi.size_class = NUM_SIZE_CLASSES;
    bi.is_large = true;
    // Mid-cycle large blocks are fully_swept so lazy sweep skips them — the
    // single live object's Black header would otherwise get reset to White.
    const bool mid_cycle_large =
        marking_active || gc_phase_ != GCPhase::Idle;

    // Maintain the cached contains() bounds BEFORE materializing, so the
    // page index is committed through the new region end when the block's
    // slots are assigned (the former code assigned after the resize too).
    if (char* const rb = regionBase(); rb == nullptr || block_base < rb) {
        setRegionBase(block_base);
    }
    if (block_base + block_size > regionEnd()) {
        setRegionEnd(block_base + block_size);
    }
    // Commit the page index through the grown region, then materialize: the
    // block's page slots (many, for a large block) get its id. Large blocks
    // use the large-mark byte for liveness; their arena slot has length 0.
    resizePageIndexForRegion();
    materializeBlock(bi, {size, 0, mid_cycle_large}, 0);

    allocated_bytes += size;
    old_alloc_total_ += size;   // 05c P-hat (monotone)

    initObjectHeader(block_base);
    return static_cast<void*>(block_base);
}
// TLA-REGION(OGS.allocateLargeBlock) end

/**
 * Starts the marking phase of a major GC.
 * Pushes all roots onto the mark stack and prepares for incremental marking.
 */
// threaded-gc-05a D1: startMark's preparation, shared with beginMarkCycle.
void OldGenSpace::prepareMark(Allocator &alloc) {
    // Drain any in-progress lazy sweep before starting a new mark cycle.
    // The previous major GC's finishMarkAndSweep may have left gc_phase_ in
    // Sweeping (initial slice + mutator-driven slices). If we begin a new
    // mark while sweep state is partial, the new finalize/reclaim/shrink
    // would race against partially-rebuilt free lists and meta. Draining
    // here ensures a clean Idle starting state. In practice this is rare —
    // it only fires if the mutator allocated very little between cycles.
    if (gc_phase_ == GCPhase::Sweeping) {
        while (gc_phase_ == GCPhase::Sweeping) {
            lazySweep(NUM_SIZE_CLASSES,
                      std::numeric_limits<size_t>::max() / 2);
        }
    }

    // Clear all mark bits before starting a new cycle.
    //
    // The bitmap "is zero between cycles" invariant only holds when sweep
    // visits every cell — which is NOT true when the mutator pops a cell
    // off a free list mid-sweep (initObjectHeader sets the bit, but sweep
    // has already advanced past that block and won't revisit). Those carry-
    // over bits make pushMarkRoot in the next cycle return early via the
    // "already marked" check, so markOneObject never runs and the cell's
    // bytes never get attributed to its block's live_bytes. A block whose
    // entire live content is carry-over-bit cells then appears "all dead"
    // and gets released (madvise DONTNEED), zero-filling pages that other
    // long-lived objects still reference via stale HPointers.
    //
    // threaded-gc-01 (HEAP_050): every block's bitmap has a fixed per-id arena
    // slot, so there is no re-pack. clearForMark zeroes every live slot and
    // large-mark byte (the load-bearing bulk clear, W11b), then returns the
    // memory of free-and-dirty slots to the OS: what the former re-pack +
    // shrink_to_fit did for released blocks' holes (W12: +172 MB without it).
    mark_.clearForMark(blocks_);
    // threaded-gc-02: the bitmap is being rebuilt, so every cursor position
    // and queue entry is meaningless across the mark (P§3.2).
    if (config_->old_gen_bitmap_alloc) resetAllocCursors();
#if ECO_HEAP_VALIDATE
    // V4: every live slot is zero after the clear; free and is_large ids
    // have an empty slot.
    for (uint32_t i = 0; i < blocks_.highWater(); ++i) {
        const BlockId id{i};
        const bool live = blocks_.isLive(id);
        if ((!live || blocks_.info(id).is_large) && mark_.len(id) != 0) {
            std::fprintf(stderr, "[heap-validate] HEAP_050: id %u (%s) has "
                "mark len %u, expected 0\n", i, live ? "is_large" : "free",
                mark_.len(id));
            std::abort();
        }
        if (live && !mark_.slotIsZero(id)) {
            std::fprintf(stderr, "[heap-validate] HEAP_050: live id %u has "
                "a set mark bit after clearForMark\n", i);
            std::abort();
        }
    }
#endif

    marking_active = true;
    current_epoch++;
#if ECO_HEAP_VALIDATE
    assertSlotsQuiescent("prepareMark's slot reset", 0, mark_slots_);   // IM14
#endif
    for (unsigned i = 0; i < mark_slots_; ++i) {
        markers_[i]->stack.clear();
        markers_[i]->priv.store(0, std::memory_order_relaxed);
        markers_[i]->deque.reset();
    }
    mark_parallel_ = false;   // threaded-gc-05b: beginMarkCycle decides
    nursery_visited_.clear();

    // Store Allocator reference for nursery checks during marking.
    allocator_ref_ = &alloc;

    // Step 2: zero per-block live-bytes accounting so markOneObject can
    // attribute reachable objects to their owning blocks. The all-dead
    // fast path (Step 3) keys off this counter being still zero post-mark.
    resetBufferMetaForMark();

}

#if ENABLE_GC_STATS
void OldGenSpace::startMark(const std::unordered_set<HPointer*> &roots,
                            const std::unordered_set<uint64_t*> &jit_roots,
                            Allocator &alloc, GCStats &stats) {
#else
void OldGenSpace::startMark(const std::unordered_set<HPointer*> &roots,
                            const std::unordered_set<uint64_t*> &jit_roots,
                            Allocator &alloc) {
#endif
    // threaded-gc-05a: a running cycle is always finished (joined) by
    // ThreadLocalHeap::majorGC before a STW mark starts (P§3.8).
    assert(!cycleActive() && "startMark during an incremental mark cycle");
    if (marking_active)
        return;

    prepareMark(alloc);

    // Push ALL roots onto mark stack - including nursery objects.
    // Embedded constants live entirely in the `constant` tag; filter them.
    // Routed through markHPointer so nursery objects are deduped via
    // nursery_visited_ instead of via the header color (which we must not
    // write to during major GC).
    for (HPointer *root: roots) {
        markHPointer(*root);
    }

    // Push JIT roots (raw 64-bit heap pointers from JIT-compiled globals).
    // These are raw addresses, not HPointer encodings (see
    // plans/value-root-api-for-encoded-hpointers.md), so we don't decode them.
    for (uint64_t *root: jit_roots) {
        markJitRootRaw(*root, alloc);
    }

#if ENABLE_GC_STATS
    GC_STATS_MAJOR_INC_CONCURRENT_MARK(stats);
#endif
}

void OldGenSpace::markJitRootRaw(uint64_t val, Allocator &alloc) {
    if (isConstantBits(val)) {
        return;  // Skip embedded constants.
    }
    void *obj = reinterpret_cast<void*>(val);
    if (obj && alloc.isInHeap(obj)) {
        pushMarkRoot(obj);
    }
}

// ===========================================================================
// threaded-gc-05b: the marker (HEAP_064; plans/threaded-gc-05b-parallel-marking.md
// P§3.2-P§3.8). One templated mark path; SerialMark = today's plain bit ops and
// the nursery traversal of the legacy STW major, ParallelMark = atomic bit ops
// on N markers. The grey set is worker 0's stack (serial) or the markers'
// Chase-Lev deques (parallel), chosen by mark_parallel_ at beginMarkCycle.
// ===========================================================================

// TLA-REGION(OGS.resolveMarkThreads) begin
unsigned OldGenSpace::resolveMarkThreads(const HeapConfig& cfg) {
    // Parallel marking runs only inside incremental cycles, which need
    // bitmap allocation (HEAP_063).
    if (!cfg.old_gen_bitmap_alloc) return 1;
    unsigned n = cfg.gc_mark_threads;
    if (n == 0) n = std::min<unsigned>(cfg.gc_mark_threads_cap, gc::availableCpus());
    if (n > kMaxMarkers) n = kMaxMarkers;
    return n == 0 ? 1 : n;
}
// TLA-REGION(OGS.resolveMarkThreads) end

// threaded-gc-06 (HEAP_067): parallel minors run on the same gang as the
// foreground markers; it is sized for the larger of the two (P§3.14). Only
// tests reconfigure (a heap reset to a new worker count).
// TLA-REGION(OGS.ensureGang) begin
gc::GCMarkGang& OldGenSpace::ensureGang() {
    gc::GCMarkGang& gang = gc::GCMarkGang::instance();
    const unsigned jitter = allocator_ != nullptr ? allocator_->helperJitterUs() : 0;
    const unsigned want = std::max(mark_threads_, minor_threads_);
    if (!gang.configured() || gang.members() < want || gang.jitterUs() != jitter) {
        if (gang.configured()) gang.shutdownForTesting();
        gang.configure(want, jitter);
    }
    return gang;
}
// TLA-REGION(OGS.ensureGang) end

// TLA-REGION(OGS.resolveMinorThreads) begin
unsigned OldGenSpace::resolveMinorThreads(const HeapConfig& cfg) {
    // The per-worker promotion cursor is a bitmap cursor (HEAP_054).
    if (!cfg.old_gen_bitmap_alloc) return 1;
    unsigned n = cfg.gc_minor_threads;
    if (n == 0) n = std::min<unsigned>(cfg.gc_minor_threads_cap, gc::availableCpus());
    if (n > kMaxMinorWorkers) n = kMaxMinorWorkers;
    return n == 0 ? 1 : n;
}
// TLA-REGION(OGS.resolveMinorThreads) end

// TLA-REGION(OGS.resolveConcMarkThreads) begin
unsigned OldGenSpace::resolveConcMarkThreads(const HeapConfig& cfg, unsigned fg) {
    // threaded-gc-05c P§3.12: background markers only in concurrent mode with
    // multi-minor cycles; auto excludes the mutator's own core.
    if (cfg.conc_mark != 2 || !cfg.incremental_mark || !cfg.old_gen_bitmap_alloc) return 0;
    unsigned b = cfg.conc_mark_threads;
    if (b == 0) {
        const unsigned cpus = gc::availableCpus();
        b = std::min<unsigned>(cfg.conc_mark_threads_cap, cpus > 1 ? cpus - 1 : 1);
    }
    if (fg >= kMaxMarkers) return 0;
    if (b > kMaxMarkers - fg) b = kMaxMarkers - fg;
    return b;
}
// TLA-REGION(OGS.resolveConcMarkThreads) end

void OldGenSpace::ensureMarkers() {
#if ECO_HEAP_VALIDATE
    assertSlotsQuiescent("ensureMarkers");   // IM14: creates and destroys slots
#endif
    const unsigned want = mark_slots_ == 0 ? 1 : mark_slots_;
    for (unsigned i = 0; i < kMaxMarkers; ++i) {
        if (i < want) {
            if (!markers_[i]) markers_[i] = std::make_unique<MarkWorker>();
        } else if (markers_[i]) {
            markers_[i]->live.release();
            markers_[i].reset();
        }
    }
}

uint64_t OldGenSpace::markLivePeek(BlockId id) const {
    uint64_t v = 0;
    for (unsigned i = 0; i < mark_slots_; ++i) v += markers_[i]->live.peek(id);
    return v;
}

uint64_t OldGenSpace::markLiveTake(BlockId id) {
#if ECO_HEAP_VALIDATE
    assertSlotsQuiescent("markLiveTake", 0, mark_slots_);   // IM14: every slot's accumulator
#endif
    uint64_t v = 0;
    for (unsigned i = 0; i < mark_slots_; ++i) v += markers_[i]->live.take(id);
    return v;
}

uint64_t OldGenSpace::markLiveSum() const {
    uint64_t v = 0;
    for (unsigned i = 0; i < mark_slots_; ++i) v += markers_[i]->live.sum(blocks_);
    return v;
}

void OldGenSpace::markLiveMergeAll() {
    // Index order (plan trap 5): integer sums, identical to one accumulator.
#if ECO_HEAP_VALIDATE
    assertSlotsQuiescent("markLiveMergeAll", 0, mark_slots_);   // IM14: every slot's accumulator
#endif
    for (unsigned i = 0; i < mark_slots_; ++i) {
        if (i == 1 && test_skip_merge_worker1_) continue;   // negative control
        markers_[i]->live.mergeInto(blocks_);
    }
#if ECO_HEAP_VALIDATE
    // HEAP_051 at the merge itself: every accumulator is drained here. The
    // mark-start check (V5, resetBufferMetaForMark) only fires if another
    // cycle follows, so a skipped merge before the last cycle went unseen.
    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        const BlockId id = blocks_.idAt(pos);
        if (markLivePeek(id) != 0) {
            std::fprintf(stderr, "[heap-validate] HEAP_051: id %u has %llu "
                "unmerged marker live bytes after the merge\n", id.v,
                (unsigned long long)markLivePeek(id));
            std::fflush(stderr);
            std::abort();
        }
    }
#endif
}

bool OldGenSpace::markStackEmpty() const {
    if (!mark_parallel_) return w0().stack.empty();
    for (unsigned i = 0; i < mark_slots_; ++i) {
        if (!markers_[i]->deque.emptyApprox() || !markers_[i]->stack.empty()) return false;
    }
    return true;
}

bool OldGenSpace::markWorkApprox() const {
#if ECO_HEAP_VALIDATE
    assertNotInDecision("markWorkApprox");
#endif
    // threaded-gc-05c: a HINT readable while background members run -- only
    // atomics (deque indices, published private sizes), never a private
    // std::vector (P§3.10: pause-only use).
    for (unsigned i = 0; i < mark_slots_; ++i) {
        const MarkWorker& w = *markers_[i];
        if (!w.deque.emptyApprox() || w.priv.load(std::memory_order_relaxed) != 0) return true;
    }
    return false;
}

size_t OldGenSpace::markStackSize() const {
    if (!mark_parallel_) return w0().stack.size();
    size_t n = 0;
    for (unsigned i = 0; i < mark_slots_; ++i) {
        n += markers_[i]->deque.sizeApprox() + markers_[i]->stack.size();
    }
    return n;
}

// TLA-REGION(OGS.testAndSetMark) begin
template <class P>
bool OldGenSpace::testAndSetMark(BlockId id, const void* obj) {
#if ECO_HEAP_VALIDATE
    if (id.valid() && blocks_.info(id).alloc_state == kAllocTenure) {   // threaded-gc-07 TV8
        std::fprintf(stderr, "[heap-validate] TV8: a marker marked %p in tenure-granted block %u\n",
                     obj, id.v);
        std::fflush(stderr);
        std::abort();
    }
#endif
    if constexpr (!P::kParallel) {
        return testAndSetMarkBitInBlock(id, obj);
    } else {
        if (__builtin_expect(test_plain_bits_parallel_, 0)) {   // negative control
            return testAndSetMarkBitInBlock(id, obj);
        }
        if (!id.valid()) return false;
        if (blocks_.info(id).is_large) {
            std::atomic_ref<uint8_t> lm(blocks_.largeMark(id));
            if (lm.load(std::memory_order_relaxed) != 0) return true;
            return lm.exchange(1, std::memory_order_relaxed) != 0;
        }
        size_t byte_index;
        uint8_t mask;
        markBitLocation(id, obj, &byte_index, &mask);
        if (byte_index >= mark_.len(id)) return false;
        std::atomic_ref<uint8_t> b(mark_.slot(id)[byte_index]);
        // Test before set: an already-marked object costs a plain load, not
        // a locked RMW on a line other markers may be writing.
        if (b.load(std::memory_order_relaxed) & mask) return true;
        return (b.fetch_or(mask, std::memory_order_relaxed) & mask) != 0;
    }
}
// TLA-REGION(OGS.testAndSetMark) end

// TLA-REGION(OGS.greyObject) begin
template <class P>
void OldGenSpace::greyObject(MarkWorker& w, void* obj) {
    // Major GC must not write into nursery headers; minor GC owns those.
    // Use nursery_visited_ to break cycles when traversing through nursery
    // objects, instead of per-block bitmaps (which only cover old gen).
#if ECO_HEAP_VALIDATE
    // HEAP_053: the per-heap nursery must agree with the calling thread's
    // heap (HEAP_007 makes them the same heap today). Only on the mutator:
    // a gang thread has no tl_heap_.
    if constexpr (!P::kParallel) {
        assert(nursery_->contains(obj) == allocator_ref_->isInNursery(obj) &&
               "HEAP_053: bound nursery disagrees with tl_heap_'s nursery");
    }
#endif
    if constexpr (P::kParallel) {
        // threaded-gc-05c (P§3.2, H6-H8): a parallel marker may run while the
        // mutator runs, so it reads only the t0 view -- never the live nursery
        // bounds, the cycle state or the YLOS index. It always runs inside a
        // cycle and never in snapshot mode (HEAP_064: the t0 snapshot uses
        // SerialMark bit operations). A young target is impossible (HEAP_005 +
        // the t0 snapshot): every build aborts on the nursery reservation.
        if (__builtin_expect(young_in_view(obj), 0)) {
            std::fprintf(stderr, "[gc] parallel marker reached nursery object %p\n", obj);
            std::abort();
        }
#if ECO_HEAP_VALIDATE
        if (ylosAtT0(obj)) {
            std::fprintf(stderr, "[heap-validate] IM3: mark slice reached "
                "young large object %p\n", obj);
            std::fflush(stderr);
            std::abort();
        }
#endif
    } else if (__builtin_expect(cycle_state_ != CycleState::Idle, 0)) {
        // threaded-gc-05a (P§3.2): in snapshot mode young targets are walked
        // by the snapshot itself; after t0 the marker never sees one (IM3).
        if (snapshot_mode_) {
            if (nursery_->contains(obj)) return;
            if (mayBeYoungLarge(obj) && isYoungLarge(obj)) return;
        } else {
#if ECO_HEAP_VALIDATE
            if (nursery_->contains(obj) || isYoungLarge(obj)) {
                std::fprintf(stderr, "[heap-validate] IM3: mark slice reached "
                    "young object %p (tag %u)\n", obj, (unsigned)getHeader(obj)->tag);
                std::fflush(stderr);
                std::abort();
            }
#endif
        }
    }
    if constexpr (!P::kParallel) {
        if (nursery_->contains(obj)) {
            // threaded-gc-07 (P§3.16): a tenuring object whose job has merged
            // is dead after the next minor; grey the copy its shadow names.
            void* r = __builtin_expect(nursery_->regionMode(), 0) ? nursery_->majorRedirect(obj) : obj;
            if (r == obj) {
                if (nursery_visited_.insert(obj).second) {
                    pushGrey(w, markwork::objEntry(obj, 0));
                }
                return;
            }
            obj = r;
        }
    }

    // Old-gen path: bitmap discovery via O(1) page-table lookup. Setting
    // the bit IS the grey transition; popping + scanChildren IS the
    // blackening. Bit stays set until sweep clears it.
    if (!contains(obj)) return;
    const BlockId block_id = blockIdFor(obj);
    if (!block_id.valid()) return;

    // Item 40: one test-and-set instead of isMarkedInBlock + setMarkBitInBlock.
    if (testAndSetMark<P>(block_id, obj)) return;
    // M1 trace (b): a newly greyed object during a cycle; its scan gets the key.
    // (Markers run only inside a cycle; the mutator's serial greys outside
    // one are a STW major's.)
    ECO_TLA_TRACE_ONLY(if (cycle_state_ != CycleState::Idle))
        ECO_TLA_TRACE("grey", "obj", ::Elm::tlatrace::obj(obj),
                      "put", ::Elm::tlatrace::key("g", obj, ::Elm::tlatrace::bound(this, 1)));
    // Cache the block id on the entry so scanObject can skip a second
    // blockIdFor lookup when attributing live bytes.
    const uint64_t e = markwork::objEntry(obj, block_id.v + 1);
    pushGrey(w, e);
}
// TLA-REGION(OGS.greyObject) end

template <class P>
void OldGenSpace::greyHPointer(MarkWorker& w, HPointer& ptr) {
    if (ptr.ptr_ind != 0)
        return;

    void *obj = Allocator::fromPointerRaw(ptr);
    if (!obj)
        return;

    if (!allocator_ref_ || !allocator_ref_->isInHeap(obj))
        return;

    greyObject<P>(w, obj);
}

template <class P>
void OldGenSpace::scanChildren(MarkWorker& w, void* obj) {
    auto greyU = [&](Unboxable& val, bool is_boxed) {
        if (is_boxed) greyHPointer<P>(w, val.p);
    };
    auto greyH = [&](HPointer& p) { greyHPointer<P>(w, p); };

    Header *hdr = getHeader(obj);

    switch (hdr->tag) {
        case Tag_Tuple2: {
            Tuple2 *t = static_cast<Tuple2 *>(obj);
            greyU(t->a, tupleFieldKind(hdr->unboxed, 0) == 0);
            greyU(t->b, tupleFieldKind(hdr->unboxed, 1) == 0);
            break;
        }
        case Tag_Tuple3: {
            Tuple3 *t = static_cast<Tuple3 *>(obj);
            greyU(t->a, tupleFieldKind(hdr->unboxed, 0) == 0);
            greyU(t->b, tupleFieldKind(hdr->unboxed, 1) == 0);
            greyU(t->c, tupleFieldKind(hdr->unboxed, 2) == 0);
            break;
        }
        case Tag_Cons: {
            Cons *c = static_cast<Cons *>(obj);
            greyU(c->head, tupleFieldKind(hdr->unboxed, 0) == 0);
            greyH(c->tail);
            break;
        }
        case Tag_ConsChunk: {
            ConsChunk *cv = static_cast<ConsChunk *>(obj);
            greyH(cv->backing);
            greyH(cv->next);
            break;
        }
        case Tag_ListBacking: {
            // Live slots are [hd, capacity); scalar-kind backings (unboxed
            // bits 1:0 != 0) are pointer-free. Slack below hd is never traced.
            // threaded-gc-05b P§3.6: chunked above MARK_CHUNK_ELEMS slots.
            if ((hdr->unboxed & 0x3) == 0) {
                ListBacking *lb = static_cast<ListBacking *>(obj);
                const u32 hd = lb->hd;
                const u32 len = hdr->size > hd ? hdr->size - hd : 0;
                const bool snap = !P::kParallel && snapshot_mode_;   // 05c H7
                const u32 first = (snap || len < MARK_CHUNK_ELEMS) ? len : MARK_CHUNK_ELEMS;
                for (u32 i = hd; i < hd + first; i++) {
                    greyU(lb->elems[i], true);
                }
                for (u32 c = 1; first < len && static_cast<uint64_t>(c) * MARK_CHUNK_ELEMS < len; ++c) {
                    pushGrey(w, markwork::chunkEntry(obj, c));
                    ++w.chunks;
                }
            }
            break;
        }
        case Tag_Custom: {
            Custom *c = static_cast<Custom *>(obj);
            for (u32 i = 0; i < hdr->size && i < 24; i++) {
                greyU(c->values[i], fieldKind(c->unboxed, i) == 0);
            }
            break;
        }
        case Tag_Record: {
            Record *r = static_cast<Record *>(obj);
            for (u32 i = 0; i < hdr->size && i < 32; i++) {
                greyU(r->values[i], fieldKind(r->unboxed, i) == 0);
            }
            break;
        }
        case Tag_DynRecord: {
            DynRecord *dr = static_cast<DynRecord *>(obj);
            greyH(dr->fieldgroup);
            for (u32 i = 0; i < hdr->size; i++) {
                greyH(dr->values[i]);
            }
            break;
        }
        case Tag_Closure: {
            // GC scans APPLIED slots only: `n_values`, not `hdr->size`
            // (== max_values, the capacity). Slots [n_values, max_values) are
            // unapplied argument space that no code reads, so tracing them
            // only exposed uninitialised memory — the reason the closure
            // payload had to be zeroed at all
            // (plans/nursery-per-site-zeroing.md).
            //
            // See NurserySpace::scanObject's Tag_Closure arm for the
            // invariant every value-slot writer must keep, and why
            // eco_store_field* must never be used on a Closure.
            Closure *cl = static_cast<Closure *>(obj);
            for (u32 i = 0; i < cl->n_values; i++) {
                greyU(cl->values[i], fieldKind(cl->unboxed, i) == 0);
            }
            break;
        }
        case Tag_Process: {
            Process *p = static_cast<Process *>(obj);
            greyH(p->root);
            greyH(p->stack);
            greyH(p->mailbox);
            break;
        }
        case Tag_Task: {
            Task *t = static_cast<Task *>(obj);
            if ((t->header.unboxed & 0x3) == 0) {
                greyH(t->value.p);
            }
            greyH(t->callback);
            greyH(t->kill);
            greyH(t->task);
            break;
        }
        case Tag_Array: {
            // threaded-gc-05b P§3.6: boxed arrays longer than MARK_CHUNK_ELEMS
            // scan their first chunk here and push the rest as chunk entries.
            ElmArray *arr = static_cast<ElmArray *>(obj);
            if ((arr->header.unboxed & 0x3) != 0) break;   // unboxed: no children
            const u32 n = arr->length;
            // Never chunk in the t0 snapshot: a young object (YLOS array) must
            // be scanned completely at t0 -- it can die, be freed or promoted
            // after t0, and a slice must never read a young object (IM3).
            const bool snap = !P::kParallel && snapshot_mode_;   // 05c H7
            const u32 first = (snap || n < MARK_CHUNK_ELEMS) ? n : MARK_CHUNK_ELEMS;
            for (u32 i = 0; i < first; i++) {
                greyU(arr->elements[i], true);
            }
            for (u32 c = 1; first < n && static_cast<uint64_t>(c) * MARK_CHUNK_ELEMS < n; ++c) {
                pushGrey(w, markwork::chunkEntry(obj, c));
                ++w.chunks;
            }
            break;
        }
        case Tag_StringSlice: {
            ElmStringSlice *slc = static_cast<ElmStringSlice *>(obj);
            greyH(slc->base);
            break;
        }
        case Tag_StringUtf8View: {
            ElmStringUtf8View *v = static_cast<ElmStringUtf8View *>(obj);
            greyH(v->base);
            break;
        }
        case Tag_ByteBufferSlice: {
            ElmByteBufferSlice *slc = static_cast<ElmByteBufferSlice *>(obj);
            greyH(slc->base);
            break;
        }
        case Tag_StringRope: {
            ElmStringRope *r = static_cast<ElmStringRope *>(obj);
            greyH(r->left);
            greyH(r->right);
            break;
        }
        case Tag_LargeStringHeader: {
            // Split header: trace the body so it survives major GC. The body
            // is pointer-free (Tag_String chars[]), so no further traversal.
            LargeStringHeader *h = static_cast<LargeStringHeader *>(obj);
            greyH(h->body);
            break;
        }
        case Tag_LargeByteHeader: {
            LargeByteHeader *h = static_cast<LargeByteHeader *>(obj);
            greyH(h->body);
            break;
        }
        // Tag_ByteBuffer: No pointers to mark (raw bytes only).
        // Tag_FieldGroup: No pointers to mark (field IDs only).
        // Tag_Int, Tag_Float, Tag_Char, Tag_String: No children.
        // Tag_Free: Never traversed.
        default:
            break;
    }
}

template <class P>
void OldGenSpace::scanChunk(MarkWorker& w, void* obj, uint32_t chunk) {
    // threaded-gc-05b P§3.6: one MARK_CHUNK_ELEMS range of a boxed array or
    // list backing. No live bytes: the object's were attributed when its own
    // entry was scanned. Old objects are immutable (P1), so the range is the
    // one that existed when the chunk was pushed.
    Header* hdr = getHeader(obj);
    const uint64_t lo_rel = static_cast<uint64_t>(chunk) * MARK_CHUNK_ELEMS;
    if (hdr->tag == Tag_Array) {
        ElmArray* arr = static_cast<ElmArray*>(obj);
        const uint64_t n = arr->length;
        const uint64_t hi = std::min<uint64_t>(n, lo_rel + MARK_CHUNK_ELEMS);
        for (uint64_t i = lo_rel; i < hi; ++i) greyHPointer<P>(w, arr->elements[i].p);
    } else if (hdr->tag == Tag_ListBacking) {
        ListBacking* lb = static_cast<ListBacking*>(obj);
        const uint64_t hd = lb->hd;
        const uint64_t end = hdr->size;
        const uint64_t lo = hd + lo_rel;
        const uint64_t hi = std::min<uint64_t>(end, lo + MARK_CHUNK_ELEMS);
        for (uint64_t i = lo; i < hi; ++i) greyHPointer<P>(w, lb->elems[i].p);
    } else {
        std::fprintf(stderr, "[gc] chunk entry on tag %u at %p\n", (unsigned)hdr->tag, obj);
        std::abort();
    }
}

// TLA-REGION(OGS.scanObject) begin
template <class P>
bool OldGenSpace::scanObject(MarkWorker& w, void* obj, BlockId block_index) {
    if (!obj) return false;
    Header* hdr = getHeader(obj);

    // Defensive: stale mark-stack entry pointing at a free cell or a
    // forwarding pointer (compaction can leave Tag_Forward stubs behind
    // until fixup completes).
    if (hdr->tag == Tag_Free || hdr->tag == Tag_Forward) return false;

#if ECO_HEAP_VALIDATE
    // Single-representation tripwire (HEAP_044,
    // plans/null-cons-hpointer-embedding.md §2.3): nullary ctors are embedded
    // null-cons constants — a LIVE 0-field Tag_Custom (nursery or old gen)
    // means some construction path missed the embedding.
    assert(!(hdr->tag == Tag_Custom && hdr->size == 0) &&
           "HEAP_044: live 0-field Tag_Custom — nullary ctors must be "
           "embedded null-cons constants");
#endif

    // Nursery objects (legacy STW path only): traverse children but never
    // write into the header, and don't attribute bytes. The cycle break
    // lives in greyObject via nursery_visited_.
    if constexpr (P::kParallel) {
        if (__builtin_expect(young_in_view(obj), 0)) {
            std::fprintf(stderr, "[gc] parallel marker scanning nursery object %p\n", obj);
            std::abort();
        }
    } else if (nursery_ != nullptr && nursery_->contains(obj)) {
        {
#if ECO_HEAP_VALIDATE
            assert(allocator_ref_ && allocator_ref_->isInNursery(obj) &&
                   "HEAP_053: bound nursery disagrees with tl_heap_'s nursery");
#endif
            scanChildren<P>(w, obj);
            return true;
        }
    }

    // Old-gen object: the bit was already set by greyObject when this
    // object was discovered. Attribute live bytes and scan its children.
    if (!contains(obj)) return false;
#if ECO_HEAP_VALIDATE
    // HEAP_BUILDER_001: builder objects are forbidden in old gen. If we
    // observe one here, a kernel either failed to clear the bit before
    // publishing the object, or the GC promoted a builder despite the
    // !builder gate in NurserySpace::evacuate.
    // threaded-gc-04b HEAP_062: a young large object is young, so it may be
    // a builder (HEAP_BUILDER_001: builders are nursery or YLOS objects).
    // (05b plan trap 7: a concurrent read of the YLOS index, safe only
    // because the mutator is paused.)
    if constexpr (P::kParallel) {
        // 05c H8: the t0 copy of the YLOS set, never the live index.
        assert((!hdr->builder || ylosAtT0(obj)) &&
               "HEAP_BUILDER_001: builder object in old gen");
    } else {
        assert((!hdr->builder || isYoungLarge(obj)) &&
               "HEAP_BUILDER_001: builder object in old gen");
    }
#endif
    BlockId blk_idx = block_index;
    if (!blk_idx.valid()) {
        blk_idx = blockIdFor(obj);
        if (!blk_idx.valid()) return false;
    }

    // W3 item 28: walkStepFor DISCARDS its second argument whenever the block
    // is a uniform size-class page, which is the common case — so computing
    // getObjectSize(obj) eagerly paid a full size dispatch per marked object
    // for a value that was then thrown away. Compute it only on the mixed path.
    const BlockInfo& blk = blocks_.info(blk_idx);
    const size_t step = (blk.size_class < NUM_SIZE_CLASSES)
        ? OldGenSpaceTestAccess::classToSize(blk.size_class)
        : getObjectSize(obj);
    // HEAP_051: the marker attributes to ITS accumulator only; merged into
    // BufferMetadata::live_bytes at finalizeMetaAfterMark (all markers).
    w.live.add(blk_idx, step);
    scanChildren<P>(w, obj);
    return true;
}
// TLA-REGION(OGS.scanObject) end

// TLA-REGION(OGS.scanEntry) begin
template <class P>
void OldGenSpace::scanEntry(MarkWorker& w, uint64_t e) {
#if ECO_HEAP_VALIDATE
    im10NoteScan(e);
#endif
    void* obj = markwork::entryAddr(e);
    if (markwork::isChunk(e)) {
        scanChunk<P>(w, obj, markwork::entryField(e));
        return;
    }
    const uint32_t f = markwork::entryField(e);
    // M1 trace (b): one grey entry scanned (whole objects; M1 has no chunks).
    ECO_TLA_TRACE_ONLY(if (cycle_state_ != CycleState::Idle))
        ECO_TLA_TRACE("scan", "obj", ::Elm::tlatrace::obj(obj),
                      "get", ::Elm::tlatrace::key("g", obj, ::Elm::tlatrace::bound(this, 1)));
    (void)scanObject<P>(w, obj, f != 0 ? BlockId{f - 1} : NO_BLOCK_ID);
}
// TLA-REGION(OGS.scanEntry) end

// The two environments of markwork::runMarkerLoop (P§3.3).
struct OldGenSpace::SerialEnv {
    static constexpr bool kParallel = false;
    OldGenSpace& og;
    markwork::MarkerCounters& counters(unsigned) { return og.w0().ctr; }
    uint64_t takeOwn(unsigned) {
        std::vector<uint64_t>& st = og.w0().stack;
        if (st.empty()) return markwork::kEmpty;
        const uint64_t e = st.back();
        st.pop_back();
        return e;
    }
    uint64_t stealFrom(unsigned) { return markwork::kEmpty; }
    bool anyWork() { return !og.w0().stack.empty(); }
    void prefetch(uint64_t e) { __builtin_prefetch(markwork::entryAddr(e), 0, 3); }
    void scan(unsigned, uint64_t e) { og.scanEntry<SerialMark>(og.w0(), e); }
    void publishAll(unsigned) {}
};

// TLA-REGION(OGS.ParallelEnv) begin
struct OldGenSpace::ParallelEnv {
    static constexpr bool kParallel = true;
    OldGenSpace& og;
    markwork::MarkerCounters& counters(unsigned i) { return og.markers_[i]->ctr; }
    uint64_t takeOwn(unsigned i) {
        MarkWorker& w = *og.markers_[i];
        if (!w.stack.empty()) {                  // private first: no fence, no atomics
            const uint64_t e = w.stack.back();
            w.stack.pop_back();
            w.priv.store(w.stack.size(), std::memory_order_relaxed);
            if ((++w.pops & 63) == 0) og.publishHalf(w);
            return e;
        }
        return w.deque.take();
    }
    uint64_t stealFrom(unsigned v) { return og.markers_[v]->deque.steal(); }
    // Termination (P§3.3): private stacks count as work too -- their owner is
    // the only one who can take it, and it re-activates when it sees it.
    bool anyWork() {
        for (unsigned i = 0; i < og.mark_slots_; ++i) {
            const MarkWorker& w = *og.markers_[i];
            if (!w.deque.emptyApprox() || w.priv.load(std::memory_order_relaxed) != 0) return true;
        }
        return false;
    }
    void prefetch(uint64_t e) { __builtin_prefetch(markwork::entryAddr(e), 0, 3); }
    void scan(unsigned self, uint64_t e) { og.scanEntry<ParallelMark>(*og.markers_[self], e); }
    // threaded-gc-05c (IM15): every run exit publishes the private stack.
    void publishAll(unsigned self) {
        if (__builtin_expect(og.test_leave_private_on_exit_, 0)) return;   // negative control
        og.publishAll(*og.markers_[self]);
    }
};
// TLA-REGION(OGS.ParallelEnv) end

namespace {
struct MarkRunArgs {
    OldGenSpace* og;
    markwork::SliceControl* c;
};
}  // namespace

void OldGenSpace::markerEntry(void* ctx, unsigned member) {
    MarkRunArgs* a = static_cast<MarkRunArgs*>(ctx);
    ParallelEnv env{*a->og};
    markwork::runMarkerLoop(env, member, *a->c);
}

// TLA-REGION(OGS.runMarkers) begin
uint64_t OldGenSpace::runMarkers(int64_t budget) {
    if (budget <= 0) return 0;
    assert(bg_ep_ != BgEpisode::Running &&
           "05c: a 5b run while a background episode runs (use assist/closing)");
    const auto t_start = std::chrono::steady_clock::now();
    uint64_t units = 0;
    if (!mark_parallel_) {
        markwork::SliceControl c(budget, 1, 0);
#if ECO_HEAP_VALIDATE
        assertSlotsQuiescent("a serial run", 0, 1);   // IM14: the mutator is slot 0's owner
#endif
        w0().ctr.resetRun(0);
        SerialEnv env{*this};
        markwork::runMarkerLoop(env, 0, c);
        units = w0().ctr.units;
        assert(budget >= markwork::kDrainBudget ||
               static_cast<int64_t>(units) == budget - c.budget.load() ||
               !"P§3.3: serial units != consumed tickets");
    } else {
        gc::GCMarkGang& gang = ensureGang();
        const unsigned jitter = gang.jitterUs();
        // threaded-gc-05c: victims = every slot (background deques included);
        // participants = the F foreground members.
        markwork::SliceControl c(budget, mark_slots_, jitter, mark_threads_);
        c.steal_without_ticket = test_steal_without_ticket_;
#if ECO_HEAP_VALIDATE
        assertSlotsQuiescent("a foreground run's counter reset", 0, mark_threads_);   // IM14
#endif
        for (unsigned i = 0; i < mark_threads_; ++i) {
            markers_[i]->ctr.resetRun(i);
            markers_[i]->chunks = 0;
        }
        MarkRunArgs args{this, &c};
        fg_run_active_ = true;
        gang.run(&OldGenSpace::markerEntry, &args, mark_threads_);
        fg_run_active_ = false;
        assertNoPrivateWork("a foreground run");
        uint64_t umax = 0;
        // Old deque arrays: only when no thread can hold one (05c trap 6).
        if (bg_ep_ != BgEpisode::Running) retireAllDequeArrays();
#if ECO_HEAP_VALIDATE
        assertSlotsQuiescent("a foreground run's counter merge", 0, mark_threads_);   // IM14
#endif
        for (unsigned i = 0; i < mark_threads_; ++i) {
            MarkWorker& m = *markers_[i];
            units += m.ctr.units;
            umax = std::max(umax, m.ctr.units);
#if ENABLE_GC_STATS
            ParMarkStats& pm = alloc_stats_.pm;
            pm.steals += m.ctr.steals;
            pm.steal_aborts += m.ctr.steal_aborts;
            pm.steal_empty += m.ctr.steal_empty;
            pm.idle_spins += m.ctr.idle_spins;
            pm.idle_yields += m.ctr.idle_yields;
            pm.idle_sleeps += m.ctr.idle_sleeps;
            pm.chunks_pushed += m.chunks;
#endif
        }
        assert(budget >= markwork::kDrainBudget ||
               static_cast<int64_t>(units) == budget - c.budget.load() ||
               !"P§3.3: parallel units != consumed tickets");
        assert(c.active() == 0 && c.done() && "P§3.3: a marker left the slice active");
#if ENABLE_GC_STATS
        ParMarkStats& pm = alloc_stats_.pm;
        pm.runs++;
        pm.units += units;
        if (mark_threads_ > pm.members_max) pm.members_max = mark_threads_;
        if (units > 0) {
            const uint64_t imb = umax * 1000 * mark_threads_ / units;
            pm.imbalance_milli_sum += imb;
            if (imb > pm.imbalance_milli_max) pm.imbalance_milli_max = imb;
        }
        uint64_t grows = 0;
        for (unsigned i = 0; i < mark_threads_; ++i) grows += markers_[i]->deque.grows();
        pm.deque_grows = grows;
#endif
    }
#if ENABLE_GC_STATS
    if (!mark_parallel_) alloc_stats_.pm.chunks_pushed += w0().chunks, w0().chunks = 0;
    const uint64_t ns = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now() - t_start).count());
    if (mark_parallel_) {
        alloc_stats_.pm.run_ns_total += ns;
        if (ns > alloc_stats_.pm.run_ns_max) alloc_stats_.pm.run_ns_max = ns;
        alloc_stats_.pm.member_cpu_ns = gc::GCMarkGang::instance().stats().member_cpu_ns.load();
    }
#else
    (void)t_start;
#endif
    // Every unit consumed inside a cycle counts toward its pacing (IM12).
    if (cycle_state_ != CycleState::Idle) cycle_units_ += units;
    return units;
}
// TLA-REGION(OGS.runMarkers) end

#if ECO_HEAP_VALIDATE
// ---------------------------------------------------------------------------
// IM10 / IM11 (plan P§3.11). IM10: every entry is scanned at most once per
// cycle (a sharded, mutex-guarded set: validate builds only). IM11: at the
// handoff, the set of scanned OBJECT entries equals the old-gen closure of
// the t0 grey set, computed independently (visitHeapChildren).
// ---------------------------------------------------------------------------
struct OldGenSpace::Im10State {
    struct Shard {
        std::mutex m;
        std::unordered_set<uint64_t> seen;
    };
    Shard shards[64];
};

void OldGenSpace::im10Reset() {
    if (!im10_) im10_ = std::make_unique<Im10State>();
    for (auto& sh : im10_->shards) {
        std::lock_guard<std::mutex> lk(sh.m);
        sh.seen.clear();
    }
}

void OldGenSpace::im10NoteScan(uint64_t e) {
    if (!im10_armed_.load(std::memory_order_acquire) || !im10_) return;
    // Object entries are keyed by address only (the block field may differ
    // between two pushes of the same object -- which itself would be the bug).
    const uint64_t key = markwork::isChunk(e) ? e : (e & markwork::kAddrMask);
    auto& sh = im10_->shards[(key * 0x9E3779B97F4A7C15ull) >> 58];
    std::lock_guard<std::mutex> lk(sh.m);
    if (!sh.seen.insert(key).second) {
        std::fprintf(stderr, "[heap-validate] IM10: entry %p (%s) scanned twice in one "
            "cycle: the mark test-and-set is broken\n", markwork::entryAddr(e),
            markwork::isChunk(e) ? "chunk" : "object");
        std::fflush(stderr);
        std::abort();
    }
}

void OldGenSpace::im11Check(const char* where) {
    if (!im10_) return;
    constexpr size_t kCap = 5'000'000;
    std::unordered_set<uintptr_t> closure;
    std::vector<uint64_t> work(im11_t0_greys_.begin(), im11_t0_greys_.end());
    auto pushChild = [&](HPointer& hp) {
        if (hp.ptr_ind != 0) return;
        void* o = Allocator::fromPointerRaw(hp);
        if (!o || !contains(o) || nursery_->contains(o) || isYoungLarge(o)) return;
        work.push_back(markwork::objEntry(o, 0));
    };
    auto scanRange = [&](void* obj, uint64_t lo, uint64_t hi, bool backing) {
        Unboxable* el = backing ? static_cast<ListBacking*>(obj)->elems
                                : static_cast<ElmArray*>(obj)->elements;
        for (uint64_t i = lo; i < hi; ++i) pushChild(el[i].p);
    };
    while (!work.empty()) {
        if (closure.size() > kCap) return;   // too big to check: skip (counted nowhere)
        const uint64_t e = work.back();
        work.pop_back();
        void* obj = markwork::entryAddr(e);
        Header* hdr = getHeader(obj);
        if (markwork::isChunk(e)) {
            const uint64_t lo = uint64_t{markwork::entryField(e)} * MARK_CHUNK_ELEMS;
            if (hdr->tag == Tag_Array) {
                const uint64_t n = static_cast<ElmArray*>(obj)->length;
                scanRange(obj, lo, std::min<uint64_t>(n, lo + MARK_CHUNK_ELEMS), false);
            } else {
                const uint64_t hd = static_cast<ListBacking*>(obj)->hd;
                scanRange(obj, hd + lo, std::min<uint64_t>(hdr->size, hd + lo + MARK_CHUNK_ELEMS), true);
            }
            continue;
        }
        if (!closure.insert(reinterpret_cast<uintptr_t>(obj)).second) continue;
        if (hdr->tag == Tag_Process) {
            Process* pr = static_cast<Process*>(obj);
            pushChild(pr->root);
            pushChild(pr->stack);
            pushChild(pr->mailbox);
        } else {
            (void)visitHeapChildren(obj, pushChild);
        }
    }
    // IM12 (P§3.3): every scanned entry was paid for with exactly one ticket.
    {
        uint64_t scanned_all = 0;
        for (auto& sh : im10_->shards) {
            std::lock_guard<std::mutex> lk(sh.m);
            scanned_all += sh.seen.size();
        }
        if (scanned_all != cycle_units_) {
            std::fprintf(stderr, "[heap-validate] %s: IM12: %llu entries scanned but %llu "
                "units (tickets) consumed this cycle\n", where,
                (unsigned long long)scanned_all, (unsigned long long)cycle_units_);
            std::fflush(stderr);
            std::abort();
        }
    }
    // Compare with the scanned object entries (IM10's set).
    size_t scanned_objects = 0;
    for (auto& sh : im10_->shards) {
        std::lock_guard<std::mutex> lk(sh.m);
        for (uint64_t key : sh.seen) {
            if (markwork::isChunk(key)) continue;
            ++scanned_objects;
            const uintptr_t a = static_cast<uintptr_t>(key << 3);
            if (!closure.count(a)) {
                std::fprintf(stderr, "[heap-validate] %s: IM11: scanned %p (tag %u) is not in "
                    "the closure of the t0 grey set\n", where, reinterpret_cast<void*>(a),
                    (unsigned)getHeader(reinterpret_cast<void*>(a))->tag);
                std::fflush(stderr);
                std::abort();
            }
        }
    }
    if (scanned_objects != closure.size()) {
        std::fprintf(stderr, "[heap-validate] %s: IM11: %zu objects scanned, closure of the "
            "t0 greys has %zu\n", where, scanned_objects, closure.size());
        std::fflush(stderr);
        std::abort();
    }
}
#endif

// The 5a mark loop's name, now a thin wrapper (units are exact tickets).
size_t OldGenSpace::markWorkUnits(size_t work_units) {
    return static_cast<size_t>(runMarkers(static_cast<int64_t>(work_units)));
}

#if ENABLE_GC_STATS
bool OldGenSpace::incrementalMark(size_t work_units, GCStats &stats) {
#else
bool OldGenSpace::incrementalMark(size_t work_units) {
#endif
    if (!marking_active || markStackEmpty()) {
        return false;  // No work to do.
    }

    const size_t units_done = markWorkUnits(work_units);
#if ENABLE_GC_STATS
    GC_STATS_MAJOR_INC_INCREMENTAL_MARK(stats, units_done);
#else
    (void)units_done;
#endif

    return !markStackEmpty();
}

// Legacy names, on SerialMark and worker 0 (tests, the snapshot, the STW major).
void OldGenSpace::markChildren(void *obj) { scanChildren<SerialMark>(w0(), obj); }
void OldGenSpace::markHPointer(HPointer &ptr) { greyHPointer<SerialMark>(w0(), ptr); }
void OldGenSpace::pushMarkRoot(void *obj) { greyObject<SerialMark>(w0(), obj); }
void OldGenSpace::markUnboxable(Unboxable &val, bool is_boxed) {
    if (is_boxed) markHPointer(val.p);
}
bool OldGenSpace::markOneObject(void* obj, BlockId block_index) {
    return scanObject<SerialMark>(w0(), obj, block_index);
}
bool OldGenSpace::markOneObject(void* obj) {
    return markOneObject(obj, NO_BLOCK_ID);
}

void OldGenSpace::resetBufferMetaForMark() {
    // threaded-gc-01: every live BlockId has its BufferMetadata by
    // construction (BlockTable::add), so the former resize-to-blocks_ is gone.
    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        const BlockId id = blocks_.idAt(pos);
#if ECO_HEAP_VALIDATE
        // V5 (HEAP_051): the previous cycle's merge left the accumulator
        // all-zero; anything here was attributed outside [reset, merge].
        if (markLivePeek(id) != 0) {
            std::fprintf(stderr, "[heap-validate] HEAP_051: id %u has %llu "
                "unmerged marker live bytes at mark start\n", id.v,
                (unsigned long long)markLivePeek(id));
            std::abort();
        }
#endif
        BufferMetadata& meta = blocks_.meta(id);
        meta.live_bytes = 0;
        meta.garbage_bytes = 0;
        meta.fully_swept = false;
    }
}

void OldGenSpace::finalizeMetaAfterMark() {
    // HEAP_051: the mark->sweep sync point. Fold the marker's accumulator
    // into BufferMetadata::live_bytes BEFORE any post-mark reader. Marking is
    // stop-the-world, and between reset and here the only writers are the
    // marker and allocate-black, both additions, so the sum equals the
    // former direct attribution exactly.
    markLiveMergeAll();   // threaded-gc-05b: every marker, in index order
    // threaded-gc-04: the P1 census reads mark bits here, before any sweep
    // clears them (plan P§3.4, trap 1).
    p1::onMarkEnd(*this);
    ++major_epoch_;

    size_t total_live = 0;
    size_t total_heap = 0;

    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        const BlockId i = blocks_.idAt(pos);
        const BlockInfo& blk = blocks_.info(i);
        const size_t parseable =
            static_cast<size_t>(blk.end_of_objects - blk.start);
        BufferMetadata& meta = blocks_.meta(i);

        if (meta.live_bytes > parseable) meta.live_bytes = parseable;
        meta.garbage_bytes = parseable - meta.live_bytes;

        total_live += meta.live_bytes;
        total_heap += parseable;
    }

    frag_stats_.live_bytes = total_live;
    frag_stats_.heap_bytes = total_heap;
    // Estimate; lazy sweep refines this as it pushes free cells.
    frag_stats_.total_free_bytes =
        (total_heap >= total_live) ? (total_heap - total_live) : 0;
    allocated_bytes = total_live;
    // Same baseline as in computeFragmentationStats: this also runs as part
    // of the major-GC end-of-mark sequence, so the garbage-fraction trigger
    // restarts from the current live set.
    post_sweep_live_bytes_ = total_live;
    // threaded-gc-05a (P§3.6 as built, P§10): allocate-black bytes are
    // allocation SINCE the cycle's t0. A STW major at t0 would have counted
    // them as allocated since the major, so the trigger baseline excludes
    // them; otherwise every cycle's promotions would enlarge the next
    // cycle's budget. Zero for a STW major.
    baseline_black_bytes_ = cycle_tail_uses_traced_live_ ? cycle_black_bytes_ : 0;
    post_sweep_live_bytes_ = (total_live > baseline_black_bytes_)
                                 ? total_live - baseline_black_bytes_ : 0;
    prev_major_live_ = major_live_;
    // threaded-gc-05a (P§3.6, HEAP_057): a cycle's LiveBudget reference is the
    // bytes the marker TRACED; allocate-black bytes measure in-cycle
    // allocation, not the live set. Equal to total_live for a STW major.
    major_live_ = cycle_tail_uses_traced_live_ ? cycle_traced_live_ : total_live;
}

// Walks `blocks_` once and demotes any non-large uniform block whose
// mark-derived `live_bytes` is at most `demote_live_fraction` (default 0.3;
// 0.0 disables demotion) of the block's total bytes.
// "Demotion" flips `block.size_class` to NUM_SIZE_CLASSES so the next
// lazy-sweep walk parses the block by `getObjectSize` (mixed-block step)
// and re-emits its coalesced free runs through the mixed any-class packer
// in `pushSpanOnFreeLists`. The packer routes the bulk of the run to the
// large mixed-only classes (16K/32K/64K with the default config), where
// `tryAllocateBySplittingLarger` can carve smaller cells out of them.
//
// Why this is safe:
//   - Live cells in a uniform block were padded by `finalizePoppedCell`
//     (which calls `padCellSlack`) at allocation time. The padding is a
//     trailing Tag_Free header that makes mixed-mode walking step over
//     the unused tail of the cell. So a mixed-mode walk of a previously
//     uniform block lands on every cell start exactly as the uniform-step
//     walk did.
//   - Free cells in a uniform block already have `header.size = cell_size`
//     and `tag = Tag_Free`, so a mixed-mode walk steps over them by
//     `getObjectSize` returning the same `cell_size`.
//   - `transitionToSweeping`, which the caller invokes immediately after
//     this method, clears `free_lists_` so any cells currently parked on
//     `free_lists_[old_uniform_class]` are dropped without a per-cell walk.
//
// Caller order (see `finishMarkAndSweep`):
//   finalizeMetaAfterMark()                  // live_bytes is authoritative
//   gatherFreeListSnapshotInto()             // Phase A: free-list state
//   demoteMostlyDeadUniformBlocks()          // <-- this method
//   transitionToSweeping()                   // wipes free_lists_
//   reclaimAllDeadBlocksFromMeta()           // releases live_bytes==0 blocks
//   adjustCapacityAfterMajorGC()             // post-mark shrink
//   gatherResidencySnapshotFrom()            // Phase B: post-reclaim residency
//   ... lazy sweep ...
OldGenSpace::DemotionStats
OldGenSpace::demoteMostlyDeadUniformBlocks() {
    DemotionStats stats;
    // threaded-gc-02 D1b: the threshold is HeapConfig::demote_live_fraction.
    // 0.0 means OFF — an explicit early return, because the formula at 0.0
    // would still demote all-dead blocks (which reclaim then releases).
    const double demote_f = config_->demote_live_fraction;
    if (demote_f <= 0.0) return stats;
    char* heap_base = (allocator_ != nullptr)
                          ? allocator_->getHeapBase() : nullptr;

    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        const BlockId i = blocks_.idAt(pos);
        BlockInfo& block = blocks_.info(i);
        if (block.is_large) continue;
        if (block.size_class >= num_size_classes_) continue;  // already mixed.

        // The heap-base page is already materialised as mixed (see the
        // heap-base detour in populateFromBlock), so this guard normally
        // never trips. Keep it as a safety net in case a future change
        // ever creates a uniform heap-base page.
        if (heap_base != nullptr && block.start == heap_base) continue;

        const size_t total = block.totalBytes();
        const size_t live  = blocks_.meta(i).live_bytes;
        // live <= f * total. At f = 0.5 this equals the former
        // `live * 2 <= total` exactly (integers below 2^53).
        if (static_cast<double>(live) > demote_f * static_cast<double>(total)) continue;

        // Debit the small-class block-budget if this was a uniform
        // small-class page. The helper is named after the
        // is_large transition but only touches small_class_bytes_, which
        // is exactly what an in-place "uniform → mixed" change needs.
        onBlockTransitioningToLarge(i);
        if (config_->old_gen_bitmap_alloc) detachFromAllocation(i);

        block.size_class = NUM_SIZE_CLASSES;
        ++stats.blocks_demoted;
        stats.bytes_demoted += total;
    }
    return stats;
}

void OldGenSpace::prepareMetaForLazySweep() {
    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        // Preserve mark-derived live_bytes: the post-mark shrink decision
        // uses it, and lazy sweep recomputes the same value as it walks.
        BufferMetadata& meta = blocks_.meta(blocks_.idAt(pos));
        meta.garbage_bytes = 0;
        meta.fully_swept = false;
    }
}

/**
 * Complete marking phase, run the all-dead fast path and post-mark shrink,
 * and start lazy sweep. Returns with `gc_phase_ == Sweeping` for any
 * non-trivial heap; the mutator's allocation slow-path drives lazy sweep
 * to completion. See plans/gc-mark-driven-live-lazy-sweep.md for the
 * design and the rationale behind each step.
 */
// threaded-gc-05a D1: the post-mark tail, once. Every finishMarkAndSweep
// overload is "mark loop + runPostMarkTail"; the incremental cycle's handoff
// (HEAP_063) runs the same tail. `stats` / `profile` may be null; with both
// null this is exactly the former no-stats, no-profile tail.
void OldGenSpace::runPostMarkTail(GCStats* stats, MajorGCPhaseProfile* profile) {
    // M1 trace (b): the marks are the liveness decision here; a harness probe
    // may read them (a cycle's handoff, or a STW major).
    ECO_TLA_TRACE_ONLY(::Elm::tlatrace::probe(cycle_tail_uses_traced_live_ ? "handoff" : "stw");)
    auto t_sweep_start = std::chrono::high_resolution_clock::now();

    finalizeMetaAfterMark();
    // threaded-gc-05a P§3.7: bodies / YLOS cells that died during an
    // incremental cycle are freed here, against the just-merged live_bytes and
    // before demotion/reclaim so their bytes count as garbage. Empty otherwise.
    processDeferredFrees();
#if ENABLE_GC_STATS
    // Phase A of the residency snapshot: capture free-list state BEFORE
    // transitionToSweeping wipes free_lists_ / free_large_blocks_. The
    // per-block free-bytes map is keyed by BlockInfo::start so it
    // survives reclaim's swap-remove of blocks_ entries, and is consumed
    // by Phase B after reclaim + shrink.
    FreeBytesByBlockStart free_by_start;
    if (stats) gatherFreeListSnapshotInto(*stats, free_by_start);
#else
    (void)stats;
#endif
    // Retag mostly-dead uniform blocks as mixed BEFORE transitionToSweeping
    // so lazy sweep parses them with the mixed-block walk step and the
    // mixed any-class packer. See demoteMostlyDeadUniformBlocks for the
    // safety argument.
    DemotionStats demotion = demoteMostlyDeadUniformBlocks();
    // transitionToSweeping clears free_lists_ and free_large_blocks_, which
    // makes the per-block removeFreeCellsForBlock inside releaseBlockToAllocator
    // a no-op. Doing it BEFORE reclaim turns reclaim from O(B*F) (B blocks
    // released, F free-list cells) into O(B). Lazy sweep rebuilds free
    // lists as it walks the surviving blocks. prepareMetaForLazySweep
    // preserves mark-derived live_bytes so reclaim's check is unchanged.
    transitionToSweeping();
    AllDeadReclaimStats alldead = reclaimAllDeadBlocksFromMeta();
    adjustCapacityAfterMajorGC();
#if ENABLE_GC_STATS
    // Phase B of the residency snapshot: post-reclaim, post-shrink, so
    // the live_frac == 0 bucket reflects the truly retained dead pages
    // rather than candidates about to be released.
    if (stats) gatherResidencySnapshotFrom(*stats, free_by_start);
#endif
    // threaded-gc-02 (P§3.3): classify blocks, retire dead bodies, queue
    // partial uniform blocks — after reclaim/shrink, before the pending count.
    if (config_->old_gen_bitmap_alloc) {
        classifyBlocksAfterMark();
        committed_at_major_ = getCommittedBytes();
    }
    recomputeSweepPendingBlocks();
    lazySweep(NUM_SIZE_CLASSES, config_->initial_sweep_budget);

    if (profile) {
        auto t_sweep_end = std::chrono::high_resolution_clock::now();
        profile->sweep_ns =
            std::chrono::duration_cast<std::chrono::nanoseconds>(
                t_sweep_end - t_sweep_start).count();
        profile->blocks_scanned = blocks_.size();
        profile->live_bytes_after = frag_stats_.live_bytes;
        profile->garbage_bytes    = frag_stats_.total_free_bytes;
        profile->alldead_blocks_released = alldead.blocks_released;
        profile->alldead_bytes_released  = alldead.bytes_released;
        profile->demoted_blocks  = demotion.blocks_demoted;
        profile->demoted_bytes   = demotion.bytes_demoted;
        profile->initial_sweep_budget_bytes = config_->initial_sweep_budget;
        // True post-initial-slice pending count, fed by markBlockFullySwept
        // throughout the slice.
        profile->sweep_pending_blocks = sweep_pending_blocks_;
    }

#if ECO_HEAP_VALIDATE
    validateOldGenMetadata("finishMarkAndSweep");
#endif
    marking_active = false;

#if ENABLE_GC_STATS
    if (stats) GC_STATS_MAJOR_INC_MARK_SWEEP(*stats);
#endif
}

#if ENABLE_GC_STATS
void OldGenSpace::finishMarkAndSweep(GCStats &stats) {
    while (incrementalMark(1000, stats)) {
        // Keep marking.
    }
    runPostMarkTail(&stats, nullptr);
}

void OldGenSpace::finishMarkAndSweep(GCStats &stats,
                                     MajorGCPhaseProfile &profile) {
    auto t_mark_start = std::chrono::high_resolution_clock::now();
    // `mark_units_done` was declared but never written (dead telemetry until
    // the per-major event log needed it). incrementalMark already accumulates
    // objects-popped into the aggregate counter, so the per-collection figure
    // is its delta across this mark loop — no extra work in the mark path.
    const uint64_t mark_units_before = stats.total_incremental_mark_work_units;
    while (true) {
        if (markStackSize() > profile.mark_stack_peak)
            profile.mark_stack_peak = markStackSize();
        bool more = incrementalMark(1000, stats);
        profile.mark_iterations++;
        if (!more) break;
    }
    profile.mark_units_done =
        stats.total_incremental_mark_work_units - mark_units_before;
    auto t_mark_end = std::chrono::high_resolution_clock::now();
    profile.mark_ns =
        std::chrono::duration_cast<std::chrono::nanoseconds>(
            t_mark_end - t_mark_start).count();
    runPostMarkTail(&stats, &profile);
}
#else
void OldGenSpace::finishMarkAndSweep() {
    while (incrementalMark(1000)) {
        // Keep marking.
    }
    runPostMarkTail(nullptr, nullptr);
}

void OldGenSpace::finishMarkAndSweep(MajorGCPhaseProfile &profile) {
    auto t_mark_start = std::chrono::high_resolution_clock::now();
    while (true) {
        if (markStackSize() > profile.mark_stack_peak)
            profile.mark_stack_peak = markStackSize();
        bool more = incrementalMark(1000);
        profile.mark_iterations++;
        if (!more) break;
    }
    auto t_mark_end = std::chrono::high_resolution_clock::now();
    profile.mark_ns =
        std::chrono::duration_cast<std::chrono::nanoseconds>(
            t_mark_end - t_mark_start).count();
    runPostMarkTail(nullptr, &profile);
}
#endif

// ===========================================================================
// threaded-gc-05a: the incremental mark cycle (HEAP_063).
// plans/threaded-gc-05a-incremental-marking.md P§3. Driven from
// ThreadLocalHeap (startMarkCycle / stepMarkCycle / finishMarkCycleNow).
// ===========================================================================

// TLA-REGION(OGS.beginMarkCycle) begin
void OldGenSpace::beginMarkCycle(Allocator &alloc, uint32_t slices) {
    assert(!cycleActive() && !marking_active &&
           "beginMarkCycle: a mark is already in progress");
    assert(config_->old_gen_bitmap_alloc && "HEAP_063 requires bitmap allocation");
#if ENABLE_GC_STATS
    const auto t_prep = std::chrono::steady_clock::now();
#endif
    prepareMark(alloc);   // sweep drain, clearForMark, cursors, meta (F4)
#if ENABLE_GC_STATS
    {
        const uint64_t d = static_cast<uint64_t>(std::chrono::duration_cast<
            std::chrono::nanoseconds>(std::chrono::steady_clock::now() - t_prep).count());
        alloc_stats_.im.t0_prep_ns_total += d;
        if (d > alloc_stats_.im.t0_prep_ns_max) alloc_stats_.im.t0_prep_ns_max = d;
    }
#endif
    // threaded-gc-05b (HEAP_064): the cycle's mark work runs on every marker
    // when there is more than one; the t0 snapshot pushes onto worker 0's
    // deque as its owner (nobody steals until the first slice).
    mark_parallel_ = mark_slots_ > 1;
    // threaded-gc-05c (P§3.2): the t0 view; immutable until the handoff.
    mark_view_.nursery_lo = allocator_ref_->getHeapBase() + allocator_ref_->getOldGenReservationBytes();
    mark_view_.nursery_hi = allocator_ref_->getHeapBase() + allocator_ref_->getHeapReserved();
    bg_ep_ = BgEpisode::None;
    bg_done_k_ = 0;
    cyc_prog_ = CycleProgress{};
    // Part B census columns (P§3.11): the pacing state this cycle started from.
    {
        pacing_t0_ = PacingAtT0{};
        pacing_t0_.p_hat = p_hat_;
        size_t live_ref = major_live_;
        if (config_->live_growth_bound > 0.0 && prev_major_live_ > 0) {
            live_ref = std::min(live_ref, static_cast<size_t>(config_->live_growth_bound *
                                                              prev_major_live_));
        }
        pacing_t0_.live_ref = live_ref;
        pacing_t0_.alloc_since_major = allocated_bytes >= post_sweep_live_bytes_
            ? allocated_bytes - post_sweep_live_bytes_ : 0;
        if (allocator_ != nullptr) {
            const size_t cap = allocator_->getOldGenMaxBytes();
            const size_t com = allocator_->getOldGenCommittedBytes();
            const double line = config_->incremental_mark_finish_fraction * static_cast<double>(cap);
            pacing_t0_.headroom = line > static_cast<double>(com)
                ? static_cast<uint64_t>(line - static_cast<double>(com)) : 0;
        }
    }
#if ECO_HEAP_VALIDATE
    im10Reset();
    im11_t0_greys_.clear();
    mark_view_.ylos_t0.clear();
    forEachYoungLarge([&](void* obj, LargeBodyMeta&) { mark_view_.ylos_t0.push_back(obj); });
    std::sort(mark_view_.ylos_t0.begin(), mark_view_.ylos_t0.end());
    im10_armed_.store(true, std::memory_order_release);
#endif
    // M1 trace (b): a fresh cycle number for the grey -> scan ordering keys.
    ECO_TLA_TRACE_ONLY((void)::Elm::tlatrace::bind(this, 1);)
    // Every existing mid-cycle branch (allocate-black, fully_swept on new
    // blocks) keys off gc_phase_ != Idle (F10).
    gc_phase_ = GCPhase::Marking;
    cycle_state_ = CycleState::Marking;
    cycle_slices_ = slices;
    cycle_k_ = 0;
    cycle_units_ = 0;
    cycle_traced_live_ = 0;
    cycle_tail_uses_traced_live_ = true;
    // P§3.5 (as built, P§10): the previous cycle's units scaled by the
    // larger of the growth allowance and the occupancy growth since the
    // previous t0 (the live set grows with the heap), or (first cycle)
    // occupancy / 48 B, a mean object. All deterministic (GC_DET_001).
    const size_t occ = allocated_bytes;
    if (prev_cycle_units_ > 0) {
        double scale = config_->incremental_mark_predict_growth;
        if (prev_cycle_occ_t0_ > 0) {
            scale = std::max(scale, static_cast<double>(occ) /
                                    static_cast<double>(prev_cycle_occ_t0_));
        }
        cycle_predicted_ = static_cast<uint64_t>(std::ceil(
            static_cast<double>(prev_cycle_units_) * scale));
    } else {
        cycle_predicted_ = occ / 48;
    }
    prev_cycle_occ_t0_ = occ;
    deferred_frees_.clear();
#if ECO_HEAP_VALIDATE
    cycle_alloc_log_.clear();
    cycle_t0_blocks_ = t0Blocks();
    std::sort(cycle_t0_blocks_.begin(), cycle_t0_blocks_.end(),
              [](const T0Block& a, const T0Block& b) { return a.id < b.id; });   // isT0Block
#endif
}
// TLA-REGION(OGS.beginMarkCycle) end

// TLA-REGION(OGS.snapshotYoungLarge) begin
void OldGenSpace::snapshotYoungLarge() {
    assert(snapshot_mode_ && "snapshotYoungLarge outside the t0 snapshot");
    forEachYoungLarge([&](void* obj, LargeBodyMeta&) {
        const BlockId id = contains(obj) ? blockIdFor(obj) : NO_BLOCK_ID;
        if (!id.valid()) return;
        // The cell itself: marked and attributed exactly as markOneObject
        // would for an old-gen object (HEAP_051).
        if (!testAndSetMarkBitInBlock(id, obj)) {
            const BlockInfo& blk = blocks_.info(id);
            const size_t step = (blk.size_class < NUM_SIZE_CLASSES)
                ? OldGenSpaceTestAccess::classToSize(blk.size_class)
                : getObjectSize(obj);
            w0().live.add(id, step);
        }
        // Its children: old ones greyed, young ones dropped (walked anyway).
        markChildren(obj);
#if ENABLE_GC_STATS
        alloc_stats_.im.t0_ylos++;
#endif
    });
}
// TLA-REGION(OGS.snapshotYoungLarge) end

// TLA-REGION(OGS.drainCycleMark) begin
size_t OldGenSpace::drainCycleMark() {
    // threaded-gc-05c: with a background episode this cycle, the drain is the
    // closing join (P§3.5: pressure finish, join).
    if (bg_ep_ != BgEpisode::None) return closingFinish();
    // runMarkers adds to cycle_units_ itself (every path, IM12).
    return markStackEmpty() ? 0 : static_cast<size_t>(runMarkers(markwork::kDrainBudget));
}
// TLA-REGION(OGS.drainCycleMark) end

size_t OldGenSpace::runCycleSlice() {
    assert(cycle_state_ == CycleState::Marking);
    assert(cycle_k_ >= 1 && cycle_k_ <= cycle_slices_);
    in_slice_ = true;
    size_t done;
    if (cycle_k_ >= cycle_slices_) {
        // The closing slice (k == T): drain everything that is left.
        done = drainCycleMark();
        cycle_state_ = CycleState::HandoffDue;
#if ENABLE_GC_STATS
        alloc_stats_.im.closing_units += done;
        if (done > alloc_stats_.im.closing_units_max) alloc_stats_.im.closing_units_max = done;
#endif
    } else {
        // P§3.5 as built (P§10): FRONT-LOADED pacing. The predicted work is
        // spread over the first H = ceil(T/2) slices, leaving the rest as a
        // buffer; on an overrun (predicted units done, stack not empty) the
        // prediction doubles and the remainder is spread over the slices
        // left before the closing one. An under-prediction therefore lands
        // on the buffer slices instead of the closing slice (E1: the
        // spread-over-T form left up to 42 M units = ~2 s to the closing
        // slice). Deterministic: a function of units done (GC_DET_001).
        if (!markStackEmpty() && cycle_units_ >= cycle_predicted_) {
            cycle_predicted_ = std::max<uint64_t>(cycle_predicted_, cycle_units_) * 2;
        }
        const uint64_t remaining =
            cycle_predicted_ > cycle_units_ ? cycle_predicted_ - cycle_units_ : 0;
        const uint64_t half = (static_cast<uint64_t>(cycle_slices_) + 1) / 2;
        const uint64_t target = (cycle_k_ <= half) ? half : cycle_slices_ - 1;
        const uint64_t slices_left = std::max<uint64_t>(1, target - cycle_k_ + 1);
        const uint64_t b = std::max<uint64_t>(
            config_->incremental_mark_min_slice_units,
            (remaining + slices_left - 1) / slices_left);
        done = markStackEmpty() ? 0 : runMarkers(static_cast<int64_t>(b));
    }
    in_slice_ = false;
#if ENABLE_GC_STATS
    alloc_stats_.im.slices++;
    alloc_stats_.im.slice_units += done;
#endif
    return done;
}

bool OldGenSpace::cyclePressureFinishDue() const {
#if ECO_HEAP_VALIDATE
    const DecisionScope im16(*this);   // IM16
#endif
    if (allocator_ == nullptr) return false;
    const size_t cap = allocator_->getOldGenMaxBytes();
    if (cap == 0) return false;
    return static_cast<double>(allocator_->getOldGenCommittedBytes()) /
               static_cast<double>(cap) >=
           config_->incremental_mark_finish_fraction;
}

// TLA-REGION(OGS.handoffMarkCycle) begin
void OldGenSpace::handoffMarkCycle(GCStats* stats, MajorGCPhaseProfile* profile) {
    assert(cycleActive() && "handoff without a cycle");
    assert(markStackEmpty() && "IM9: handoff with a non-empty mark stack");
    assert(!in_slice_);
#if ECO_HEAP_VALIDATE
    assertSlotsQuiescent("the handoff (accumulator sum)", 0, mark_slots_);   // IM14
#endif
    // P§3.6 step 2: fold the cursors' pending bytes (post-t0 virgin blocks)
    // into live_bytes and detach every block, as startMark does, BEFORE the
    // tail reads live_bytes (trap 2).
    resetAllocCursors();
    cycle_traced_live_ = markLiveSum();
    // Before the merge, BufferMetadata::live_bytes holds exactly the bytes
    // allocated black during the cycle (reset at t0, HEAP_051).
    cycle_black_bytes_ = 0;
    for (size_t pos = 0; pos < blocks_.size(); ++pos)
        cycle_black_bytes_ += blocks_.meta(blocks_.idAt(pos)).live_bytes;
#if ENABLE_GC_STATS
    alloc_stats_.im.black_bytes += cycle_black_bytes_;
    alloc_stats_.im.traced_live_bytes += cycle_traced_live_;
#endif
#if ECO_HEAP_VALIDATE
    // IM4 (final half): every in-cycle allocation is still marked.
    assertAllMarked(cycle_alloc_log_, "IM4 in-cycle allocation");
    cycle_alloc_log_.clear();
    // IM6 equality: the mark stack is empty, so every set bit is attributed.
    validateCycleUniformLive("handoff", /*exact=*/true);
    // IM5: no block that existed at t0 changed identity or was released.
    checkT0BlocksUnchanged();
    cycle_t0_blocks_.clear();
    // IM8: every deferred free is a distinct, still-allocated cell.
    {
        std::vector<void*> cells;
        cells.reserve(deferred_frees_.size());
        for (const LargeBodyMeta& m : deferred_frees_) cells.push_back(m.body_base);
        assertAllMarked(cells, "IM8 deferred free");
        std::sort(cells.begin(), cells.end());
        if (std::adjacent_find(cells.begin(), cells.end()) != cells.end()) {
            std::fprintf(stderr, "[heap-validate] IM8: a cell was deferred twice\n");
            std::fflush(stderr);
            std::abort();
        }
    }
#endif
#if ECO_HEAP_VALIDATE
    im11Check("handoff");   // threaded-gc-05b IM10/IM11
#endif
    // P§3.6 step 5: the state today's STW major has after its mark loop.
    gc_phase_ = GCPhase::Idle;
    cycle_state_ = CycleState::Idle;
    runPostMarkTail(stats, profile);
    cycle_tail_uses_traced_live_ = false;
    prev_cycle_units_ = cycle_units_;
    assert(bg_ep_ != BgEpisode::Running && "IM14: handoff with a running background episode");
#if ECO_HEAP_VALIDATE
    assertSlotsQuiescent("the handoff's deque reset", 0, mark_slots_);   // IM14
#endif
    for (unsigned i = 0; i < mark_slots_; ++i) markers_[i]->deque.reset();
    mark_parallel_ = false;
    bg_ep_ = BgEpisode::None;
    bg_ctl_.reset();
#if ECO_HEAP_VALIDATE
    im10_armed_.store(false, std::memory_order_release);
#endif
#if ENABLE_GC_STATS
    alloc_stats_.im.cycles++;
#endif
}
// TLA-REGION(OGS.handoffMarkCycle) end


// ===========================================================================
// threaded-gc-05c: concurrent marking (HEAP_065;
// plans/threaded-gc-05c-concurrent-marking.md P§3.3-P§3.5). Background
// markers (slots F..F+B-1) mark between pauses; the mutator and the
// foreground gang JOIN the running episode for paced assists and at the
// closing step. Collector progress decides only pause-internal work
// (GC_DET_001, P§3.10).
// ===========================================================================

#if ECO_HEAP_VALIDATE
bool OldGenSpace::ylosAtT0(const void* obj) const {
    return std::binary_search(mark_view_.ylos_t0.begin(), mark_view_.ylos_t0.end(), obj);
}

bool OldGenSpace::isT0Block(BlockId id) const {
    if (!cycleActive() || !id.valid()) return false;
    const auto it = std::lower_bound(cycle_t0_blocks_.begin(), cycle_t0_blocks_.end(), id.v,
        [](const T0Block& b, uint32_t v) { return b.id < v; });
    if (it == cycle_t0_blocks_.end() || it->id != id.v) return false;
    // CR-036: the id matches but it is another incarnation: IM5 fails at once.
    if (!test_im5_ignore_gen_ && blocks_.generation(id) != it->gen)
        cycleValidateFail("IM5: a t0 block id was released and re-issued mid-cycle", it->start);
    return true;
}
#endif

void OldGenSpace::assertNoPrivateWork(const char* where) const {
    // IM15 (every build; <= 64 slots): after any run no private work remains.
    // Only the slots no thread runs on: while a background episode runs, the
    // foreground slots.
    if (!mark_parallel_) return;
    const unsigned n = (bg_ep_ == BgEpisode::Running) ? mark_threads_ : mark_slots_;
    for (unsigned i = 0; i < n; ++i) {
        const MarkWorker& w = *markers_[i];
        if (!w.stack.empty() || w.priv.load(std::memory_order_relaxed) != 0) {
            std::fprintf(stderr, "[gc] IM15: slot %u holds %zu private entries after %s\n",
                         i, w.stack.size(), where);
            std::fflush(stderr);
            std::abort();
        }
    }
}

void OldGenSpace::assertSlotsQuiescent(const char* where, unsigned lo, unsigned hi) const {
    // IM14: the mutator touches the owner-only state of slots [lo, hi) only
    // while no thread runs on them. The foreground gang runs on [0, F) while
    // fg_run_active_; the background gang on [F, F + B) from launch to join.
    // The default range (every slot) is the launch's check (every build);
    // the per-touch calls with a range are validate-only (register CR-010).
    const unsigned F = mark_threads_;
    const bool fg = fg_run_active_ && lo < hi && lo < F;
    const bool bg = bg_ && bg_->running() && lo < hi && hi > F && lo < F + bg_->members();
    if (fg || bg) {
        std::fprintf(stderr, "[gc] IM14: slots [%u, %u) touched at %s while the %s gang runs on them\n",
                     lo, hi, where, fg ? "foreground" : "background");
        std::fflush(stderr);
        std::abort();
    }
}

void OldGenSpace::retireAllDequeArrays() {
#if ECO_HEAP_VALIDATE
    // Trap 6: any running marker may hold any slot's old array (a steal).
    assertSlotsQuiescent("retireAllDequeArrays", 0, mark_slots_);
#endif
    for (unsigned i = 0; i < mark_slots_; ++i) markers_[i]->deque.retireOldArrays();
}

#if ECO_HEAP_VALIDATE
void OldGenSpace::assertNotInDecision(const char* what) const {
    if (in_decision_ != 0) {
        std::fprintf(stderr, "[heap-validate] IM16: %s read inside a GC decision path\n", what);
        std::fflush(stderr);
        std::abort();
    }
}
#endif

uint64_t OldGenSpace::bgConsumedApprox() const {
#if ECO_HEAP_VALIDATE
    assertNotInDecision("bgConsumedApprox");
#endif
    // Pause-only (P§3.10): over-counts by at most kTicketBatch * B claimed,
    // unscanned tickets.
    if (bg_ep_ != BgEpisode::Running || !bg_ctl_) return 0;
    const int64_t left = bg_ctl_->budget.load(std::memory_order_relaxed);
    return static_cast<uint64_t>(markwork::kDrainBudget - left);
}

namespace {
struct ConcArgs {
    OldGenSpace* og;
    markwork::SliceControl* c;
    std::atomic<int64_t>* pool;
};
}  // namespace

void OldGenSpace::bgEntry(void* ctx, unsigned member) {
    OldGenSpace* og = static_cast<OldGenSpace*>(ctx);
    // Test hook: hold the members before they mark (the "late collector").
    while (og->test_bg_hold_.load(std::memory_order_acquire) &&
           !og->bg_ctl_->stopRequested()) {
        markwork::sleepMicros(200);
    }
    ParallelEnv env{*og};
    const unsigned self = og->mark_threads_ + member;
    markwork::runMarkerLoop(env, self, *og->bg_ctl_, og->bg_ctl_->budget,
                            markwork::Role::Member, /*joined=*/false);
}

void OldGenSpace::assistEntry(void* ctx, unsigned member) {
    ConcArgs* a = static_cast<ConcArgs*>(ctx);
    ParallelEnv env{*a->og};
    markwork::runMarkerLoop(env, member, *a->c, *a->pool, markwork::Role::Assist,
                            /*joined=*/true);
}

void OldGenSpace::closingEntry(void* ctx, unsigned member) {
    ConcArgs* a = static_cast<ConcArgs*>(ctx);
    ParallelEnv env{*a->og};
    markwork::runMarkerLoop(env, member, *a->c, a->c->budget, markwork::Role::Member,
                            /*joined=*/true);
}

// TLA-REGION(OGS.launchBackground) begin
bool OldGenSpace::launchBackground() {
    assert(conc_threads_ > 0 && mark_parallel_);
    assertSlotsQuiescent("launch");
    const unsigned F = mark_threads_;
    const unsigned B = conc_threads_;
    // P§3.5 launch steps 1-2: everything on slot 0 (the t0 snapshot's greys,
    // or foreground leftovers) goes round-robin into the background deques.
    // Their owners are parked: the mutator acts as owner, and the launch's
    // mutex publishes the transfer.
    for (unsigned i = 0; i < F; ++i) publishAll(*markers_[i]);
    uint64_t j = 0;
    for (unsigned i = 0; i < F; ++i) {
        MarkWorker& src = *markers_[i];
        for (;;) {
            const uint64_t e = src.deque.take();
            if (e == markwork::kEmpty) break;
            markers_[F + (j++ % B)]->deque.push(e);
        }
    }
    retireAllDequeArrays();
    if (!bg_) {
        gc::GCBackgroundGang::Options o;
        o.members = B;
        o.priority = config_->conc_mark_priority;
        o.jitter_us = allocator_ != nullptr ? allocator_->helperJitterUs() : 0;
        bg_ = std::make_unique<gc::GCBackgroundGang>(o);
    }
    const unsigned jitter = bg_->options().jitter_us;
    bg_ctl_ = std::make_unique<markwork::SliceControl>(markwork::kDrainBudget, mark_slots_,
                                                       jitter, static_cast<int64_t>(B));
    for (unsigned i = F; i < mark_slots_; ++i) {
        markers_[i]->ctr.resetRun(i);
        markers_[i]->chunks = 0;
    }
    bg_launch_ns_ = gc::GCHelperPool::nowNs();
    bg_ep_ = BgEpisode::Running;
    ECO_TLA_TRACE("launch", "gang", ::Elm::tlatrace::key("B", bg_.get()));   // M1 trace
    if (!bg_->launch(&OldGenSpace::bgEntry, this, &bg_ctl_->stop)) {
        // CR-013 / CR-004 (§7.2 step 4, HEAP_065): a fork's prepare holds the gang. A
        // stopped episode: the work stays in the background deques; the next step
        // relaunches (reapBackground returns at once on None), the closing drains.
        bg_ep_ = BgEpisode::None;
        bg_refused_step_ = true;   // the M1 trace logs it as an episode a fork stopped
#if ENABLE_GC_STATS
        alloc_stats_.cm.episodes_refused++;
#endif
        return false;
    }
#if ENABLE_GC_STATS
    alloc_stats_.cm.episodes_launched++;
#endif
    return true;
}
// TLA-REGION(OGS.launchBackground) end

void OldGenSpace::mergeBackgroundCounters() {
    // After a join only: members' counters are published by the join.
#if ECO_HEAP_VALIDATE
    assertSlotsQuiescent("the background merge", mark_threads_, mark_slots_);   // IM14
#endif
    uint64_t units = 0;
    for (unsigned i = mark_threads_; i < mark_slots_; ++i) {
        MarkWorker& m = *markers_[i];
        if (i == mark_threads_ && test_skip_bg_merge_) { m.ctr.units = 0; continue; }  // negative control
        units += m.ctr.units;
#if ENABLE_GC_STATS
        ParMarkStats& pm = alloc_stats_.pm;
        pm.steals += m.ctr.steals;
        pm.steal_aborts += m.ctr.steal_aborts;
        pm.steal_empty += m.ctr.steal_empty;
        pm.idle_spins += m.ctr.idle_spins;
        pm.idle_yields += m.ctr.idle_yields;
        pm.idle_sleeps += m.ctr.idle_sleeps;
        pm.chunks_pushed += m.chunks;
#endif
        m.ctr.resetRun(i);
        m.chunks = 0;
    }
    if (cycle_state_ != CycleState::Idle) cycle_units_ += units;
    cyc_prog_.bg_units += units;
#if ENABLE_GC_STATS
    alloc_stats_.cm.bg_units += units;
    if (bg_) {
        alloc_stats_.cm.bg_cpu_ns = bg_->stats().member_cpu_ns.load(std::memory_order_relaxed);
        alloc_stats_.cm.join_wait_ns_max = bg_->stats().join_wait_ns_max.load();
        alloc_stats_.cm.stop_wait_ns_max = bg_->stats().stop_wait_ns_max.load();
    }
#endif
}

// TLA-REGION(OGS.reapBackground) begin
void OldGenSpace::reapBackground(bool wait) {
#if ECO_HEAP_VALIDATE
    assertNotInDecision("reapBackground (finishedApprox)");
#endif
    if (bg_ep_ != BgEpisode::Running) return;
    if (!wait && bg_->running() && !bg_->finishedApprox()) return;
    bg_->join();                              // exact publication
    const bool done = bg_ctl_->done();
    ECO_TLA_TRACE("reap", "done", done, "wait", wait);   // M1 trace
    mergeBackgroundCounters();
    assertNoPrivateWork("background join");
    retireAllDequeArrays();
#if ENABLE_GC_STATS
    alloc_stats_.cm.bg_wall_ns_total += gc::GCHelperPool::nowNs() - bg_launch_ns_;
    if (!done) alloc_stats_.cm.episodes_stopped++;
#endif
    if (done) {
        bg_ep_ = BgEpisode::Finished;
        if (bg_done_k_ == 0) bg_done_k_ = cycle_k_ == 0 ? 1 : cycle_k_;
    } else {
        bg_ep_ = BgEpisode::None;             // stopped (fork, test): relaunch below
    }
}
// TLA-REGION(OGS.reapBackground) end

// TLA-REGION(OGS.stopBackground) begin
void OldGenSpace::stopBackground() {
    if (bg_ep_ != BgEpisode::Running) return;
    bg_->stopAndJoin();
    reapBackground(/*wait=*/true);
}
// TLA-REGION(OGS.stopBackground) end

// TLA-REGION(OGS.assistEpisode) begin
void OldGenSpace::assistEpisode(int64_t budget) {
    assert(bg_ep_ == BgEpisode::Running && budget > 0);
    std::atomic<int64_t> pool{budget};
    ConcArgs args{this, bg_ctl_.get(), &pool};
    bg_ctl_->share_epoch.fetch_add(1, std::memory_order_relaxed);   // make private work stealable
#if ECO_HEAP_VALIDATE
    {
        // IM14: this step resets slots [0, hi): the foreground ones only (the
        // background gang runs on the others). The negative control (CR-010)
        // also resets background slot F, as a wrong reset range would.
        const unsigned hi = mark_threads_ + (test_assist_resets_bg_ctr_ ? 1u : 0u);
        assertSlotsQuiescent("an assist's counter reset", 0, hi);
        for (unsigned i = mark_threads_; i < hi; ++i) markers_[i]->ctr.resetRun(i);
    }
#endif
    for (unsigned i = 0; i < mark_threads_; ++i) {
        markers_[i]->ctr.resetRun(i);
        markers_[i]->chunks = 0;
    }
    gc::GCMarkGang& gang = ensureGang();
    fg_run_active_ = true;
    gang.run(&OldGenSpace::assistEntry, &args, mark_threads_);
    fg_run_active_ = false;
    assertNoPrivateWork("an assist");
    uint64_t units = 0;
#if ECO_HEAP_VALIDATE
    assertSlotsQuiescent("an assist's counter merge", 0, mark_threads_);   // IM14
#endif
    for (unsigned i = 0; i < mark_threads_; ++i) {
        units += markers_[i]->ctr.units;
#if ENABLE_GC_STATS
        alloc_stats_.pm.chunks_pushed += markers_[i]->chunks;
#endif
        markers_[i]->chunks = 0;
    }
    // Exact: the pool's consumption == the foreground units (P§3.3).
    assert(static_cast<int64_t>(units) == budget - pool.load() &&
           "P§3.5: assist units != consumed assist tickets");
    cycle_units_ += units;
    cyc_prog_.assists++;
    cyc_prog_.assist_units += units;
    ECO_TLA_TRACE("assist", "units", units);   // M1 trace: A_Done
    // Deque arrays are NOT retired here: background thieves may hold them (trap 6).
#if ENABLE_GC_STATS
    alloc_stats_.cm.assists++;
    alloc_stats_.cm.assist_units += units;
#endif
}
// TLA-REGION(OGS.assistEpisode) end

// TLA-REGION(OGS.closingFinish) begin
size_t OldGenSpace::closingFinish() {
    // k = T (and the pressure / join finishes): the mark must be complete
    // when this returns (P§3.5).
    const auto t_start = std::chrono::steady_clock::now();
    uint64_t fg_units = 0;                    // marked INSIDE this pause
    reapBackground(/*wait=*/false);
    // M6: a harness pause point: the episode still runs as the closing join starts (CR-005).
    // Only while an M6 harness sets gc::tla_m6: other harnesses' probe callbacks never see it.
    ECO_TLA_TRACE_ONLY(if (::Elm::gc::tla_m6 && bg_ep_ == BgEpisode::Running) ::Elm::tlatrace::probe("m6.closing");)
    bool with_work = false;
    if (bg_ep_ == BgEpisode::Running) {
        with_work = true;
        ConcArgs args{this, bg_ctl_.get(), nullptr};
        bg_ctl_->share_epoch.fetch_add(1, std::memory_order_relaxed);   // make private work stealable
#if ECO_HEAP_VALIDATE
        assertSlotsQuiescent("the closing's counter reset", 0, mark_threads_);   // IM14
#endif
        for (unsigned i = 0; i < mark_threads_; ++i) {
            markers_[i]->ctr.resetRun(i);
            markers_[i]->chunks = 0;
        }
        gc::GCMarkGang& gang = ensureGang();
        test_bg_hold_.store(false, std::memory_order_release);
        fg_run_active_ = true;
        gang.run(&OldGenSpace::closingEntry, &args, mark_threads_);
        fg_run_active_ = false;
#if ECO_HEAP_VALIDATE
        assertSlotsQuiescent("the closing's counter merge", 0, mark_threads_);   // IM14
#endif
        for (unsigned i = 0; i < mark_threads_; ++i) {
            fg_units += markers_[i]->ctr.units;
            markers_[i]->ctr.resetRun(i);
#if ENABLE_GC_STATS
            alloc_stats_.pm.chunks_pushed += markers_[i]->chunks;
#endif
            markers_[i]->chunks = 0;
        }
        cycle_units_ += fg_units;
        reapBackground(/*wait=*/true);        // done => the members exit promptly
        // CR-005 (§7.2 step 6, HEAP_065): a foreign stop (a fork's prepare,
        // stopAllAtExit, reset) can end the episode without done; its work is still in
        // the deques and the drain below completes the mark (M2 episode_stop_drain).
        assert(bg_ep_ == BgEpisode::Finished || bg_ep_ == BgEpisode::None);
    }
    if (!markStackEmpty()) {                  // an episode was stopped: plain drain
        with_work = true;
        fg_units += runMarkers(markwork::kDrainBudget);   // runMarkers adds to cycle_units_
    }
    retireAllDequeArrays();
    assertNoPrivateWork("closing");
    if (with_work) cyc_prog_.closing_units += fg_units;
    step_pause_work_ = step_pause_work_ || with_work;
    assert(markStackEmpty() && "P§3.5: closing step left mark work");
#if ENABLE_GC_STATS
    if (with_work) {
        const uint64_t ns = static_cast<uint64_t>(std::chrono::duration_cast<
            std::chrono::nanoseconds>(std::chrono::steady_clock::now() - t_start).count());
        alloc_stats_.cm.closings_with_work++;
        alloc_stats_.cm.closing_units += fg_units;
        alloc_stats_.cm.closing_ns_total += ns;
        if (ns > alloc_stats_.cm.closing_ns_max) alloc_stats_.cm.closing_ns_max = ns;
    }
    {
        const uint32_t T = cycle_slices_ == 0 ? 1 : cycle_slices_;
        const uint32_t k = bg_done_k_;
        int bucket = 4;
        if (k != 0 && !with_work) {
            if (4 * k <= T) bucket = 0;
            else if (2 * k <= T) bucket = 1;
            else if (4 * k <= 3 * T) bucket = 2;
            else bucket = 3;
        }
        alloc_stats_.cm.done_k_hist[bucket]++;
    }
#else
    (void)with_work;
    (void)t_start;
#endif
    bg_ep_ = BgEpisode::None;
    ECO_TLA_TRACE("closing", "units", fg_units, "work", with_work);   // M1 trace: D_Done
    return static_cast<size_t>(fg_units);
}
// TLA-REGION(OGS.closingFinish) end

std::string OldGenSpace::pacingSnapshot() const {
    char buf[160];
    std::snprintf(buf, sizeof buf, "p_hat=%lld;h_c=%llu;live_ref=%llu;alloc_since_major=%llu;headroom=%llu",
                  (long long)pacing_t0_.p_hat, (unsigned long long)pacingHorizonMinors(),
                  (unsigned long long)pacing_t0_.live_ref,
                  (unsigned long long)pacing_t0_.alloc_since_major,
                  (unsigned long long)pacing_t0_.headroom);
    return buf;
}

// TLA-REGION(OGS.afterSnapshot) begin
void OldGenSpace::afterSnapshot() {
    if (cycle_slices_ == 0) return;
    if (concurrentCycle()) {
        if (!launchBackground()) {
            // A refused t0 launch (CR-013/004): to M1, an episode a fork stopped at once.
            ECO_TLA_TRACE("stop", "gang", ::Elm::tlatrace::key("B", bg_.get()));   // M1 trace (a)
            bg_refused_step_ = false;
        }
    } else if (config_->conc_mark == 1 && !markStackEmpty()) {
        // Sync (P§3.1): the whole mark inside the t0 pause, on the foreground
        // gang; the steps then find nothing to do. The determinism reference.
        runMarkers(markwork::kDrainBudget);
    }
}
// TLA-REGION(OGS.afterSnapshot) end

// TLA-REGION(OGS.runCycleStepConcurrent) begin
size_t OldGenSpace::runCycleStepConcurrent() {
    assert(cycle_state_ == CycleState::Marking);
    assert(cycle_k_ >= 1 && cycle_k_ <= cycle_slices_);
    in_slice_ = true;
    size_t done = 0;
    step_pause_work_ = false;
    if (__builtin_expect(test_cursor_takes_t0_block_, 0)) {
        // Negative control (IM13): queue a t0 uniform block, detach its class's
        // cursor and refill -- the bug the validator exists for.
        test_cursor_takes_t0_block_ = false;
        std::vector<bool> done_cls(NUM_SIZE_CLASSES, false);
        for (size_t pos = 0; pos < blocks_.size(); ++pos) {
            const BlockId id = blocks_.idAt(pos);
            BlockInfo& b = blocks_.info(id);
            if (b.is_large || b.size_class >= num_size_classes_ || done_cls[b.size_class]) continue;
            if (cursor_[b.size_class].block == id) continue;
            done_cls[b.size_class] = true;
            flushCursor(b.size_class);
            if (cursor_[b.size_class].block.valid())
                blocks_.info(cursor_[b.size_class].block).alloc_state = kAllocNone;
            cursor_[b.size_class] = AllocCursor{};
            b.alloc_state = kAllocQueued;
            partial_[b.size_class].insert(partial_[b.size_class].begin() +
                static_cast<std::ptrdiff_t>(partial_head_[b.size_class]), id);
            // What the next allocation of this class does: refill (IM13 fires).
            (void)refillCursor(b.size_class);
        }
    }
    reapBackground(/*wait=*/false);
    if (bg_ep_ == BgEpisode::None && !markStackEmpty()) {
        // Stopped (a fork) or refused: relaunch; the work is already in the deques.
        ECO_TLA_TRACE("relaunch");   // M1 trace
        if (launchBackground()) {
#if ENABLE_GC_STATS
            alloc_stats_.cm.episodes_relaunched++;
            alloc_stats_.cm.episodes_launched--;
#endif
        }
    } else if (bg_ep_ == BgEpisode::None) {
        bg_ep_ = BgEpisode::Finished;
        if (bg_done_k_ == 0) bg_done_k_ = cycle_k_;
    }
    // M1 trace: P_Marking (k++, then the reap / relaunch above), and the episode after it.
    // A refused relaunch (CR-013/004) is logged as M1 sees it: the relaunched episode
    // ("running"), stopped at once by the fork ("stop" right after); M6 reads `refused`.
    ECO_TLA_TRACE("step", "k", cycle_k_, "ep",
                  bg_refused_step_ || bg_ep_ == BgEpisode::Running ? "running"
                  : bg_ep_ == BgEpisode::Finished ? "finished" : "none",
                  "refused", bg_refused_step_);
    if (bg_refused_step_) {
        ECO_TLA_TRACE("stop", "gang", ::Elm::tlatrace::key("B", bg_.get()));   // M1 trace (a)
        bg_refused_step_ = false;
    }
    if (cycle_k_ >= cycle_slices_) {
        done = closingFinish();
        cycle_state_ = CycleState::HandoffDue;
#if ENABLE_GC_STATS
        alloc_stats_.im.closing_units += done;
        if (done > alloc_stats_.im.closing_units_max) alloc_stats_.im.closing_units_max = done;
#endif
    } else if (bg_ep_ == BgEpisode::Running) {
        // P§3.5 paced assist: pause-only (GC_DET_001, P§3.10).
        const uint64_t U = cycle_units_ + bgConsumedApprox();
        if (U >= cycle_predicted_ && markWorkApprox()) {
            cycle_predicted_ = std::max<uint64_t>(cycle_predicted_, U) * 2;
        }
        const uint64_t T = cycle_slices_;
        const uint64_t H = (T + 1) / 2;
        const uint64_t L = config_->conc_mark_assist_lag;
        const uint64_t k = cycle_k_;
        uint64_t expected = 0;
        if (k > L && H > 0) {
            const uint64_t num = std::min<uint64_t>(k - L, H);
            expected = static_cast<uint64_t>(
                (static_cast<unsigned __int128>(cycle_predicted_) * num) / H);
        }
        const uint64_t deficit = expected > U ? expected - U : 0;
        if (deficit >= config_->incremental_mark_min_slice_units && markWorkApprox()) {
            // Never larger than the 05b slice budget at k.
            const uint64_t remaining = cycle_predicted_ > U ? cycle_predicted_ - U : 0;
            const uint64_t target = (k <= H) ? H : T - 1;
            const uint64_t slices_left = std::max<uint64_t>(1, target - k + 1);
            const uint64_t b_k = std::max<uint64_t>(config_->incremental_mark_min_slice_units,
                                                    (remaining + slices_left - 1) / slices_left);
            const uint64_t before = cycle_units_;
            const auto t0 = std::chrono::steady_clock::now();
            assistEpisode(static_cast<int64_t>(std::min(deficit, b_k)));
            step_pause_work_ = true;
            done = static_cast<size_t>(cycle_units_ - before);
#if ENABLE_GC_STATS
            const uint64_t ns = static_cast<uint64_t>(std::chrono::duration_cast<
                std::chrono::nanoseconds>(std::chrono::steady_clock::now() - t0).count());
            alloc_stats_.cm.assist_ns_total += ns;
            if (ns > alloc_stats_.cm.assist_ns_max) alloc_stats_.cm.assist_ns_max = ns;
#else
            (void)t0;
#endif
        }
    }
    in_slice_ = false;
#if ENABLE_GC_STATS
    alloc_stats_.im.slices++;
    alloc_stats_.im.slice_units += done;
#endif
    return done;
}
// TLA-REGION(OGS.runCycleStepConcurrent) end

void OldGenSpace::processDeferredFrees() {
    if (deferred_frees_.empty()) return;
    for (LargeBodyMeta& m : deferred_frees_) {
        // The index key was erased at deferral; freeLargeBodyCell's own erase
        // is a no-op (nothing can have re-registered the still-allocated cell).
        freeLargeBodyCell(m);
    }
    deferred_frees_.clear();
}

#if ECO_HEAP_VALIDATE
[[noreturn]] static void cycleValidateFail(const char* what, const void* p) {
    std::fprintf(stderr, "[heap-validate] %s: %p\n", what, p);
    std::fflush(stderr);
    std::abort();
}

void OldGenSpace::assertCellWasWhite(BlockId id, const void* obj) const {
    if (!cycleActive() || !id.valid()) return;
    // 05c H2: relaxed atomic reads (background markers may write this byte).
    if (blocks_.info(id).is_large) {
        if (isMarkedInBlockRelaxed(id, obj))
            cycleValidateFail("IM4: in-cycle allocation into a marked large block", obj);
        return;
    }
    if (isMarkedInBlockRelaxed(id, obj))
        cycleValidateFail("IM4: in-cycle allocation into a MARKED cell (live object)", obj);
}

void OldGenSpace::noteCycleAllocation(void* obj) {
    if (!cycleActive() || obj == nullptr) return;
    const BlockId id = contains(obj) ? blockIdFor(obj) : NO_BLOCK_ID;
    if (!id.valid()) cycleValidateFail("IM4: in-cycle allocation outside any block", obj);
    const bool marked = isMarkedInBlockRelaxed(id, obj);   // 05c H2
    if (!marked) cycleValidateFail("IM4: in-cycle allocation NOT allocated black", obj);
    cycle_alloc_log_.push_back(obj);
}

void OldGenSpace::assertAllMarked(const std::vector<void*>& objs, const char* what) const {
    for (void* obj : objs) {
        const BlockId id = contains(obj) ? blockIdFor(obj) : NO_BLOCK_ID;
        if (!id.valid()) {
            std::fprintf(stderr, "[heap-validate] %s: %p is in no old-gen block\n", what, obj);
            std::fflush(stderr);
            std::abort();
        }
        const bool marked = blocks_.info(id).is_large ? blocks_.largeMark(id) != 0
                                                      : isMarkedInBlock(id, obj);
        if (!marked) {
            std::fprintf(stderr, "[heap-validate] %s: %p (tag %u, size %u) is NOT marked\n",
                         what, obj, (unsigned)getHeader(obj)->tag,
                         (unsigned)getHeader(obj)->size);
            std::fflush(stderr);
            std::abort();
        }
    }
}

std::vector<OldGenSpace::T0Block> OldGenSpace::t0Blocks() const {
    std::vector<T0Block> v;
    v.reserve(blocks_.size());
    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        const BlockId id = blocks_.idAt(pos);
        const BlockInfo& b = blocks_.info(id);
        v.push_back(T0Block{id.v, blocks_.generation(id), b.start, b.size_class, b.is_large});
    }
    return v;
}

const char* OldGenSpace::t0BlocksChangedWhy(char** where) const {
    for (const T0Block& t : cycle_t0_blocks_) {
        const BlockId id{t.id};
        if (where != nullptr) *where = t.start;
        if (!blocks_.isLive(id)) return "IM5: a t0 block was released mid-cycle";
        // CR-036 (HEAP_048/HEAP_063): a released id re-issued at the same start
        // with the same class is a new incarnation: its generation differs.
        if (!test_im5_ignore_gen_ && blocks_.generation(id) != t.gen)
            return "IM5: a t0 block id was released and re-issued mid-cycle";
        const BlockInfo& b = blocks_.info(id);
        if (b.start != t.start || b.size_class != t.size_class || b.is_large != t.is_large)
            return "IM5: a t0 block changed start/size_class/is_large mid-cycle";
    }
    return nullptr;
}

void OldGenSpace::checkT0BlocksUnchanged() const {
    char* where = nullptr;
    if (const char* why = t0BlocksChangedWhy(&where)) cycleValidateFail(why, where);
}

void OldGenSpace::validateCycleUniformLive(const char* where, bool exact) const {
    if (!cycleActive() && !exact) return;
    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        const BlockId id = blocks_.idAt(pos);
        const BlockInfo& b = blocks_.info(id);
        if (b.is_large || b.size_class >= num_size_classes_) continue;
        if (b.alloc_state == kAllocTenure) continue;   // threaded-gc-07: collector-owned bits
        const uint8_t* bits = mark_.slot(id);
        const uint32_t n = cellsIn(b);
        const uint32_t m = static_cast<uint32_t>(classToSize(b.size_class) / 8);
        const uint64_t pc = bitscan::popcountCellStarts(bits, m, n);
        uint64_t pend = 0;
        const AllocCursor& c = cursor_[b.size_class];
        if (b.alloc_state == kAllocCurrent && c.block == id) pend = c.pending_live;
        const uint64_t have = blocks_.meta(id).live_bytes + pend + markLivePeek(id);
        const uint64_t bitsb = pc * classToSize(b.size_class);
        if (exact ? bitsb != have : bitsb < have) {
            std::fprintf(stderr, "[heap-validate] %s: IM6 block id %u class %zu: popcount "
                "%llu x %zu = %llu %s live %llu (meta %zu + pending %llu + acc %llu)\n",
                where, id.v, (size_t)b.size_class, (unsigned long long)pc,
                classToSize(b.size_class), (unsigned long long)bitsb,
                exact ? "!=" : "<", (unsigned long long)have, blocks_.meta(id).live_bytes,
                (unsigned long long)pend, (unsigned long long)markLivePeek(id));
            std::fflush(stderr);
            std::abort();
        }
    }
}
#endif

// ---------------------------------------------------------------------------
// Sweep helpers (segregated-fits + coalescing).
// ---------------------------------------------------------------------------
//
// Sweep walks each block's parseable region [start, end_of_objects). Adjacent
// non-Black entries are coalesced into a single Tag_Free cell of total size
// and pushed onto sizeClass(span)'s free list. Live Black objects have their
// color reset to White for the next cycle.
namespace {

// Pushes a coalesced free span onto the appropriate per-class free list.
// Goes via the test-access wrapper to avoid taking a friend-only entry point.
// Recursively splits `span` into exact-cellSize cells, one per non-empty
// class chosen by `freeListClassFor`. Maintains the invariant that every
// cell on free_lists_[cls] satisfies header.size == classToSize(cls), so
// the size-class fast path can pop without any size check. Trailing bytes
// (< MIN_FREE_CELL_SIZE) get a non-linked Tag_Free header so block-walking
// sweep can still parse them.
//
// `age_sentinel`: when true, every Tag_Free header written by this call has
// `age = 0b01` (the on-free-list sentinel). Used by `freeLargeBodyCell` to
// install cells onto a free list mid-major-GC; lazy sweep honors the
// sentinel as a hard run boundary so the cell isn't coalesced/rewritten.
// When false (default), `age = 0` (coalescable). See Heap.hpp for the
// `Header.age` repurposing convention.
// TLA-REGION(OGS.pushSpanOnFreeLists) begin
inline void pushSpanOnFreeLists(FreeCell** free_lists, char* span_start,
                                size_t span_bytes,
                                BlockInfo* block,
                                BlockId block_index,
                                bool age_sentinel) {
    // Diagnostic (gated on ECO_OLDGEN_DEBUG): catch sweep bugs where step >
    // remaining bytes pushes a coalesced run past the block boundary, which
    // would corrupt cells in subsequent blocks. Shipped guarded so production
    // pays nothing.
    if (g_oldgen_debug && block != nullptr) {
        char* span_end = span_start + span_bytes;
        if (span_start < block->start || span_end > block->end) {
            std::fprintf(stderr,
                "[oldgen-debug] pushSpanOnFreeLists OOB: span [%p,%p) bytes=%zu"
                " block [%p,%p) end_of_objects=%p is_large=%d size_class=%zu\n",
                (void*)span_start, (void*)span_end, span_bytes,
                (void*)block->start, (void*)block->end,
                (void*)block->end_of_objects, (int)block->is_large,
                block->size_class);
            std::fflush(stderr);
            std::abort();
        }
    }
    // Tier-M maintenance needs a block context (for the per-block thread).
    // Without one the cell remains on free_lists but stays invisible to the
    // per-block fast bulk-release path. The back-link itself is an address
    // (HEAP_052), so the block COUNT no longer matters.
    const bool can_thread = (block != nullptr);

    // Helper: place a fresh Tag_Free cell of `cellSize` bytes at `addr` and
    // link it onto free_lists[cls] + (Tier-M only) onto block's per-block
    // thread.
    auto placeAndLink = [&](char* addr, size_t cellSize, size_t cls) {
#if ECO_HEAP_VALIDATE
        // Class 4 — free-list class invariant: every cell on free_lists[cls]
        // must satisfy header.size == classToSize(cls). Catches the
        // LOT=8K-class bug pattern where a span gets sliced onto the wrong
        // size class and corrupts subsequent allocations.
        {
            size_t expected = OldGenSpaceTestAccess::classToSize(cls);
            if (cls < NUM_SIZE_CLASSES && cellSize != expected) {
                std::fprintf(stderr,
                    "[heap-validate] pushSpanOnFreeLists class invariant: "
                    "cls=%zu expected_cellSize=%zu actual_cellSize=%zu "
                    "addr=%p block=%p\n",
                    cls, expected, cellSize, (void*)addr, (void*)block);
                std::fflush(stderr);
                std::abort();
            }
        }
#endif
        FreeCell* cell = reinterpret_cast<FreeCell*>(addr);
#if ECO_HEAP_VALIDATE
        // Class 5 — push-duplicates invariant. Before linking `cell` onto
        // free_lists[cls], scan the existing chain and ensure `cell` is not
        // already on it. A duplicate push silently forms a cycle (the second
        // assignment to `free_lists[cls] = cell` makes `cell` reachable from
        // its own predecessor in the original chain). On abort, look up the
        // first-push origin so we can pin which call site placed the cell.
        // ECO_VALIDATE_FREELIST_DUP_SCAN=0 skips this O(list-length) scan
        // (threaded-gc-00): on a self-compile the post-major sweep pushes
        // millions of cells onto lists up to 1M long, which makes a validator
        // self-compile take days. Every other validator check stays on.
        static const bool dup_scan_enabled = [] {
            const char* e = std::getenv("ECO_VALIDATE_FREELIST_DUP_SCAN");
            return !(e && e[0] == '0');
        }();
        if (dup_scan_enabled) {
            size_t depth = 0;
            for (FreeCell* c = free_lists[cls]; c != nullptr;
                 c = c->next_in_class) {
                if (c == cell) {
                    const char* prior = "<not recorded>";
                    auto it = g_first_push_origin.find(cell);
                    if (it != g_first_push_origin.end()) prior = it->second;
                    std::fprintf(stderr,
                        "[heap-validate] pushSpanOnFreeLists duplicate push: "
                        "cell %p already on free_lists[%zu] at depth %zu "
                        "(cellSize=%zu, age_sentinel=%d, block=%p, "
                        "block_id=%u). First-push origin: %s. "
                        "Second-push origin: %s. Aborting.\n",
                        (void*)cell, cls, depth, cellSize,
                        (int)age_sentinel,
                        block ? (void*)block->start : nullptr,
                        block_index.v, prior, g_push_origin);
                    std::fflush(stderr);
                    std::abort();
                }
                if (++depth > 1'000'000) break;
            }
            // Record the first-push origin for this cell so a future
            // duplicate-push abort can report which call site placed it.
            g_first_push_origin[cell] = g_push_origin;
        }
#endif
        std::memset(&cell->header, 0, sizeof(Header));
        cell->header.tag = Tag_Free;
        cell->header.size = static_cast<u32>(cellSize);
        cell->header.color = static_cast<u32>(Color::White);
        cell->header.age = age_sentinel ? 0b01 : 0;

        // Class-list push at head.
        if (isTierMSize(cellSize) && can_thread) {
            FreeCellMid* m = asTierM(cell);
            setPrevHead(m);
            m->next_in_class = free_lists[cls];
            if (m->next_in_class != nullptr) {
                setPrev(asTierM(m->next_in_class), cell);
            }
            free_lists[cls] = cell;
            // Per-block thread push at head.
            blockThreadPushHead(*block, cell);
        } else {
            // Tier-S (class 1) OR Tier-M without block context: link only on
            // the class list. Tier-M-without-context is the rare nullptr
            // caller; bulk release falls back to a global walk for those.
            cell->next_in_class = free_lists[cls];
            free_lists[cls] = cell;
        }
    };

    // For UNIFORM size-class blocks, walkStep advances by classToSize(cls),
    // so every cell in the block must be exactly classToSize(cls) bytes.
    // Slice the span into class-sized cells so sweep's next walk does not
    // misstep mid-cell.
    if (block != nullptr && block->size_class < NUM_SIZE_CLASSES) {
        size_t cls = block->size_class;
        size_t cellSize = OldGenSpaceTestAccess::classToSize(cls);
        while (span_bytes >= cellSize) {
            placeAndLink(span_start, cellSize, cls);
            span_start += cellSize;
            span_bytes -= cellSize;
        }
        // A uniform block's parseable area is always a multiple of cellSize
        // (cells are populated at 16N from block.start, and `end_of_objects`
        // sits at the last fully-populated cell boundary). Any caller pushing
        // a span that doesn't end on a cell boundary has fed us a stale
        // `cell_size` from a different block — see
        // bugs/C-lot-8K-alignment-investigation.md v15/v16.
        assert(span_bytes == 0 &&
               "pushSpanOnFreeLists: uniform block span must align with cellSize");
        return;
    }

    // Mixed/large block (or no block info): pack into the largest classes
    // that fit, descending. This is the original behaviour.
    while (span_bytes >= MIN_FREE_CELL_SIZE) {
        size_t cls = OldGenSpaceTestAccess::freeListClassFor(span_bytes);
        if (cls >= NUM_SIZE_CLASSES) break;  // Below smallest class.
        size_t cellSize = OldGenSpaceTestAccess::classToSize(cls);
        placeAndLink(span_start, cellSize, cls);
        span_start += cellSize;
        span_bytes -= cellSize;
    }

    // Trailing bytes too small for any class: leave a parseable Tag_Free
    // header so sweep can walk over them. Always 8-aligned for 8-aligned
    // input, so >= sizeof(Header) when non-zero.
    if (span_bytes >= sizeof(Header)) {
        Header* hdr = reinterpret_cast<Header*>(span_start);
        std::memset(hdr, 0, sizeof(Header));
        hdr->tag = Tag_Free;
        hdr->size = static_cast<u32>(span_bytes);
        hdr->color = static_cast<u32>(Color::White);
        if (age_sentinel) hdr->age = 0b01;
        else              hdr->age = 0;
    }
}
// TLA-REGION(OGS.pushSpanOnFreeLists) end

inline void pushCoalescedFreeCell(FreeCell** free_lists, char* span_start,
                                  size_t span_bytes,
                                  BlockInfo* block,
                                  BlockId block_index) {
    // Coalesced runs from sweep are always non-sentinel: they go onto a free
    // list and stay there until allocation; the next major's sweep can safely
    // re-merge them with neighbours.
#if ECO_HEAP_VALIDATE
    PushOriginScope _origin("lazySweep::flushRun");
#endif
    pushSpanOnFreeLists(free_lists, span_start, span_bytes, block, block_index,
                        /*age_sentinel=*/false);
}

// Per-block step size. Defers to the hoisted file-scope `walkStepFor` so
// member functions (markOneObject and friends) and the sweep helpers in
// this anonymous namespace agree on the policy.
inline size_t walkStep(const BlockInfo& block, size_t obj_size) {
    return walkStepFor(block, obj_size);
}

}  // namespace

/**
 * Defensive loop-to-completion helper. Production paths reach the same
 * end state via `finishMarkAndSweep` (initial slice) and the mutator's
 * allocation slow-path (per-call slices). Tests and rare callers that
 * need "sweep is finished by the time this returns" can call here.
 */
void OldGenSpace::sweep() {
    if (gc_phase_ != GCPhase::Sweeping) {
        transitionToSweeping();
    }
    while (gc_phase_ == GCPhase::Sweeping) {
        lazySweep(NUM_SIZE_CLASSES,
                  std::numeric_limits<size_t>::max() / 2);
    }

    // Diagnostic (gated on ECO_OLDGEN_DEBUG): validate every free-list cell
    // is in-heap. Detects sweep-time corruption before shrink walks the lists.
    if (g_oldgen_debug && allocator_ != nullptr) {
        char* heap_lo = allocator_->heap_base;
        char* heap_hi = allocator_->heap_base + allocator_->getOldGenMaxBytes();
        for (size_t cls = 0; cls < NUM_SIZE_CLASSES; ++cls) {
            FreeCell* curr = free_lists_[cls];
            size_t depth = 0;
            while (curr != nullptr) {
                char* p = reinterpret_cast<char*>(curr);
                if (p < heap_lo || p >= heap_hi) {
                    std::fprintf(stderr,
                        "[oldgen-debug] sweep produced bad free cell:"
                        " cls=%zu depth=%zu curr=%p\n",
                        cls, depth, (void*)curr);
                    std::abort();
                }
                curr = curr->next_in_class;
                if (++depth > 100000000ULL) break;
            }
        }
    }
}

/**
 * Transition from marking phase to sweeping phase.
 * Prepares for lazy sweeping by initializing sweep state. Free-list cells
 * are dropped because lazy sweep rebuilds them as it walks. The per-block
 * meta is reset via `prepareMetaForLazySweep`, which preserves
 * mark-derived live_bytes (the post-mark shrink decision depends on it).
 */
void OldGenSpace::transitionToSweeping() {
    gc_phase_ = GCPhase::Sweeping;
    sweep_buffer_index_ = 0;
    sweep_cursor_ = nullptr;

#if ECO_HEAP_VALIDATE
    // Reset the per-cycle origin map. transitionToSweeping is the cycle
    // boundary: every push that follows is attributed via PushOriginScope.
    g_first_push_origin.clear();
#endif

    // Clear free lists - they'll be rebuilt during lazy sweep.
    //
    // Before clearing the heads, walk each list and downgrade any "on free
    // list" sentinel (age = 0b01) to the coalescable default (age = 0). The
    // sentinel marker says "do not coalesce — I'm still on a free list", but
    // after the head wipe these cells are NOT on any list. Leaving the
    // sentinel intact would make the upcoming lazy sweep treat each one as
    // a hard run boundary (skip + flush prior run), leaking the cell's
    // bytes until the next major-GC sees a different live/dead pattern.
    // Resetting to age=0 lets sweep merge those bytes into a coalesced run
    // as it walks. Sentinel cells originate from `freeLargeBodyCell` and
    // `splitter::remainder` mid-sweep pushes.
    // Item 43: the inner walk touches EVERY free cell in the heap, and its
    // only job is to downgrade sentinels. `free_list_sentinel_count_` counts
    // sentinel pushes since the last transition and over-counts, so a zero is
    // a proof that no sentinel is on any list and the walk can be skipped
    // outright; any non-zero value falls back to the full walk.
    if (free_list_sentinel_count_ == 0) {
        for (size_t i = 0; i < NUM_SIZE_CLASSES; i++) {
            free_lists_[i] = nullptr;
        }
    } else {
        for (size_t i = 0; i < NUM_SIZE_CLASSES; i++) {
            for (FreeCell* c = free_lists_[i]; c != nullptr;
                 c = c->next_in_class) {
                if (c->header.age == 0b01) c->header.age = 0;
            }
            free_lists_[i] = nullptr;
        }
    }
    free_list_sentinel_count_ = 0;
    // Clear per-block free-cell threads. Sweep will rebuild them as it
    // emits Tier-M cells via pushSpanOnFreeLists.
    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        blocks_.info(blocks_.idAt(pos)).free_cells_in_block = FREE_CELLS_EMPTY;
    }
    // free_large_blocks_ entries name blocks; the blocks
    // themselves remain (large dead blocks are reclaimed via this path,
    // not via reclaimAllDeadBlocksFromMeta), so we keep the list intact
    // and let lazy sweep re-seed it as it walks each large block.
    free_large_blocks_.clear();

    prepareMetaForLazySweep();

    // Initialise the sweep-pending counter from the prepared meta. After
    // prepareMetaForLazySweep, every entry has fully_swept == false, so
    // this is just blocks_.size(). Subsequent block releases (via
    // reclaimAllDeadBlocksFromMeta or releaseBlockToAllocator) decrement
    // the counter as those !fully_swept entries are removed, so by the
    // time the first lazySweep slice runs the counter is accurate.
    // finishMarkAndSweep also recomputes after reclaim as a safety reset.
    recomputeSweepPendingBlocks();
}

void OldGenSpace::recomputeSweepPendingBlocks() {
    sweep_pending_blocks_ = 0;
    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        if (!blocks_.meta(blocks_.idAt(pos)).fully_swept) ++sweep_pending_blocks_;
    }
    // Snapshot the in-cycle total used as the denominator for the
    // unswept-fraction boost in `computeSweepBudgetForAlloc`. Captured
    // here so it stays stable while mid-cycle blocks added with
    // `fully_swept = true` (from populateFromBlock / allocateFromBagPage)
    // grow `blocks_.size()` without affecting the boost decision.
    // garbage_bytes is 0 at this point because prepareMetaForLazySweep
    // runs first; filtering on `!fully_swept` is equivalent to the plan's
    // `!fully_swept && garbage_bytes > 0` once the sweeper has had a
    // chance to populate per-block garbage values.
    sweep_total_blocks_ = sweep_pending_blocks_;
}

void OldGenSpace::markBlockFullySwept(BlockId block_index) {
    if (!block_index.valid()) return;
    BufferMetadata& meta = blocks_.meta(block_index);
    if (meta.fully_swept) return;
    meta.fully_swept = true;
    if (sweep_pending_blocks_ > 0) --sweep_pending_blocks_;
}

/**
 * Lazy sweep - sweep a bounded amount of heap to find free space.
 * Coalesces adjacent garbage spans into Tag_Free cells, just like sweep().
 */
#if ECO_HEAP_VALIDATE
// V11 (HEAP_055): a gap-swept block parses by header over [start,
// end_of_objects): every gap became Tag_Free cells, every popped cell is an
// object. Run when the block completes, or (CR-028) after the join.
void OldGenSpace::validateV11(BlockId id) const {
    const BlockInfo& block = blocks_.info(id);
    char* const used_end = block.end_of_objects;
    size_t covered = 0;
    for (char* q = block.start; q < used_end;) {
        const Header qh = loadHeaderRelaxed(q);   // CR-019 (HEAP_062)
        const size_t qs = walkStep(block, getObjectSizeFromHeader(&qh));
        if (qs == 0 || q + qs > used_end) {
            std::fprintf(stderr, "[heap-validate] lazySweep: V11 block "
                "id %u parse breaks at %p (step %zu, end %p)\n",
                id.v, (void*)q, qs, (void*)used_end);
            std::abort();
        }
        covered += qs;
        q += qs;
    }
    if (covered != static_cast<size_t>(used_end - block.start)) {
        std::fprintf(stderr, "[heap-validate] lazySweep: V11 coverage\n");
        std::abort();
    }
}
#endif

// TLA-REGION(OGS.lazySweep) begin
size_t OldGenSpace::lazySweep(size_t target_class, size_t work_budget) {
    size_t work_done = 0;

    // Per-block coalescing run state, carried across iterations only within
    // a single block.
    char* run_start = nullptr;
    size_t run_bytes = 0;

    // `buf_pos` is an order POSITION (the sweep cursor), not an id.
    auto flushRun = [&](size_t buf_pos) {
        if (run_start == nullptr) return;
        const BlockId run_id =
            (buf_pos < blocks_.size()) ? blocks_.idAt(buf_pos) : NO_BLOCK_ID;
        BlockInfo* block_for_run =
            run_id.valid() ? &blocks_.info(run_id) : nullptr;
        pushCoalescedFreeCell(free_lists_, run_start, run_bytes,
                              block_for_run, run_id);
        if (run_id.valid()) {
            blocks_.meta(run_id).garbage_bytes += run_bytes;
        }
        run_start = nullptr;
        run_bytes = 0;
    };

    // CR-014 (plans/threaded-gc-register-fixes.md 4.1, HEAP_067): every
    // completion, in-loop (path 2) or tail (path 3), goes through here. Inside
    // a parallel promotion it defers like the in-loop one always did:
    // sweepCompleteInPromotion runs onSweepComplete after the join (N > 1) or
    // hands worker 0's cursors back first (N = 1). The path numbers are the
    // M4 trace's (TracePromoBitmap keys on them).
    auto completeSweep = [&](int path) {
        ECO_TLA_TRACE_ONLY(const int m4_old = static_cast<int>(gc_phase_);)
        // CR-001 (HEAP_067): the one in-minor write of gc_phase_; promotion
        // workers read it outside promo_mu_ (relaxed loads), so it is atomic.
        std::atomic_ref<GCPhase>(gc_phase_).store(GCPhase::Idle, std::memory_order_relaxed);
        ECO_M4_TRACE("m4.swend", "cb", target_class < NUM_SIZE_CLASSES ? classToSize(target_class) : 0,
                     "path", path, "par", par_promo_active_,
                     "rmw", "phase", "old", m4_old, "new", 0);
#if ENABLE_GC_STATS
        if (path == 3) {
            // Written under promo_mu_ inside a parallel promotion: no race.
            alloc_stats_.bm.sweep_tail_completions++;
            if (par_promo_active_) alloc_stats_.bm.sweep_tail_in_promotion++;
        }
        auto t0_shrink = GC_STATS_TIMER_START();
#endif
        if (par_promo_active_) sweepCompleteInPromotion();
        else onSweepComplete();
#if ENABLE_GC_STATS
        alloc_stats_.total_post_sweep_shrink_ns += GC_STATS_TIMER_ELAPSED_NS(t0_shrink);
#endif
    };

    while (work_done < work_budget && gc_phase_ == GCPhase::Sweeping) {
        if (sweep_cursor_ == nullptr) {
            if (sweep_buffer_index_ >= blocks_.size()) {
                // The in-loop completion (path 2). threaded-gc-06 (P§3.8.4):
                // inside a parallel minor the shrink would read live bytes of
                // blocks whose worker cursors hold unflushed pending bytes; the
                // merge runs it instead (completeSweep).
                completeSweep(2);
                return work_done;
            }
            // Skip blocks that were materialized mid-cycle (populated /
            // freshly-acquired during sweeping). Their meta.fully_swept is
            // pre-set to true so we walk past them — re-walking would
            // coalesce the Tag_Free cells we just placed on free_lists_,
            // overwriting their headers and dangling the free-list links.
            if (blocks_.meta(blocks_.idAt(sweep_buffer_index_)).fully_swept) {
                sweep_buffer_index_++;
                continue;
            }
            sweep_cursor_ = blocks_.info(blocks_.idAt(sweep_buffer_index_)).start;
            // live_bytes is fully populated by markOneObject during mark,
            // so sweep no longer needs to accumulate it. finalizeMetaAfterMark
            // wrote the authoritative value into this slot.
        }

        const BlockId cur_id = blocks_.idAt(sweep_buffer_index_);
        BlockInfo& block = blocks_.info(cur_id);
        char* used_end = block.end_of_objects;

        // Large/pinned blocks hold a single object. Decide live vs. dead in
        // one shot rather than running the coalescing walk: a dead large
        // block becomes a `free_large_blocks_` entry so the next
        // allocateLargeBlock reuses its address.
        if (block.is_large && sweep_cursor_ == block.start &&
            sweep_cursor_ < used_end) {
            // threaded-gc-02: every is_large block is decided eagerly by
            // classifyBlocksAfterMark (fully_swept), so this is unreachable.
            assert(!config_->old_gen_bitmap_alloc &&
                   "lazySweep reached an is_large block in bitmap mode");
            // Liveness comes from the large-mark byte; testAndClear leaves
            // the bit at zero so the next mark cycle starts clean.
            const bool live =
                testAndClearMarkBitInBlock(cur_id, sweep_cursor_);
            {
                BufferMetadata& meta = blocks_.meta(cur_id);
                if (live) {
                    // live_bytes was attributed during mark; nothing to do.
                } else {
                    // Split-header body cells (HEAP_026) are tracked in
                    // large_body_index_ until either promoteLargeHeader or
                    // sweepNurseryLargeBodies retires them. Major GC sweep
                    // can reach a body cell first when its only nursery
                    // header died; clear the side-table entry so future
                    // recycling doesn't clash with a stale id.
                    const Header lh = loadHeaderRelaxed(sweep_cursor_);   // CR-019 (HEAP_062)
                    if (lh.pin) {   // a body or a YLOS object: index is authoritative
                        auto it = large_body_index_.find(sweep_cursor_);
                        if (it != large_body_index_.end()) {
                            retireIndexEntry(it->second);
                            large_body_index_.erase(it);
                        }
                    }
                    meta.garbage_bytes = block.totalBytes();
                    markBlockAsFreeLarge(cur_id);
                }
                markBlockFullySwept(cur_id);
            }
            work_done += static_cast<size_t>(used_end - sweep_cursor_);
            sweep_cursor_ = used_end;
            // Fall through to the block-boundary handling below.
        }

        // threaded-gc-02 (P§3.6, HEAP_055): GAP SWEEP. The set bits of an
        // unswept mixed block are exactly its live objects (marking set them;
        // nothing allocates into an unswept block; startMark cleared stale
        // ones), so the maximal runs between set bits are exactly the runs the
        // header walk below builds — without reading any dead header. With
        // no sentinels in bitmap mode (P§3.7) the pushed runs are identical.
        // work_done keeps counting span bytes covered, so pacing is unchanged.
        const bool gap_sweep = config_->old_gen_bitmap_alloc;
        if (gap_sweep) {
            uint8_t* gbits = mark_.slot(cur_id);
            const size_t end_bit =
                static_cast<size_t>(used_end - block.start) / MARK_ALIGNMENT;
            while (sweep_cursor_ < used_end && work_done < work_budget) {
                const size_t from_bit =
                    static_cast<size_t>(sweep_cursor_ - block.start) / MARK_ALIGNMENT;
                const size_t nb = bitscan::nextSetBit(gbits, from_bit, end_bit);
                char* live_obj = block.start + nb * MARK_ALIGNMENT;
                if (live_obj > sweep_cursor_) {
                    const size_t gap = static_cast<size_t>(live_obj - sweep_cursor_);
                    if (run_start == nullptr) {
                        run_start = sweep_cursor_;
                        run_bytes = 0;
                    }
                    run_bytes += gap;
                    work_done += gap;
                    sweep_cursor_ = live_obj;
#if ENABLE_GC_STATS
                    alloc_stats_.bm.gap_sweep_gaps++;
                    alloc_stats_.bm.gap_sweep_bytes += gap;
#endif
                }
                if (live_obj >= used_end) break;
                // A live object: flush the pending gap, clear its bit (same
                // post-state as testAndClear), step over it reading ONLY its
                // own header -- one relaxed atomic whole-word load (CR-019: a
                // young YLOS's age may be written under ylos_mu_ meanwhile).
                const Header lh = loadHeaderRelaxed(live_obj);
                const size_t step = walkStep(block, getObjectSizeFromHeader(&lh));
                ECO_TLA_TRACE_ONLY(const int64_t m4_rs = run_start == nullptr ? -1
                                       : static_cast<int64_t>((run_start - block.start) / MARK_ALIGNMENT);
                                   const size_t m4_rb = run_start == nullptr ? 0 : run_bytes;)
                flushRun(sweep_buffer_index_);
                // M4: one gap-sweep iteration (nextSetBit's word read, the gap
                // pushed), then the plain clearBit store.
                ECO_M4_TRACE("m4.sw", "blk", cur_id.v, "rs", m4_rs, "rb", m4_rb, "l", nb,
                             "end", live_obj + step >= used_end);
                bitscan::clearBit(gbits, nb);
                ECO_M4_TRACE("m4.clr", "blk", cur_id.v, "l", nb);
                sweep_cursor_ = live_obj + step;
                work_done += step;
#if ENABLE_GC_STATS
                alloc_stats_.bm.gap_sweep_live_objects++;
                alloc_stats_.bm.gap_sweep_bytes += step;
#endif
            }
        }

        while (!gap_sweep && sweep_cursor_ < used_end && work_done < work_budget) {
            // CR-019: one relaxed atomic whole-word load (HEAP_062), reused
            // for the tag, the sentinel test and pin.
            const Header lh = loadHeaderRelaxed(sweep_cursor_);
            const Header* hdr = &lh;
            size_t step = walkStep(block, getObjectSizeFromHeader(hdr));

            // Liveness from per-block bitmap. testAndClear keeps the
            // post-sweep invariant that the mark bits are all-zero. Tag_Free
            // short-circuits to dead — including sentinel cells, whose mark
            // bit was already cleared by freeLargeBodyCell, so this branch
            // never re-reads it for them. (Resolved Decisions §4.)
            const bool live = (hdr->tag != Tag_Free) &&
                testAndClearMarkBitInBlock(cur_id, sweep_cursor_);

            if (live) {
                // Flush pending garbage run before processing live object.
                // live_bytes was attributed by markOneObject during mark.
                flushRun(sweep_buffer_index_);
            } else if (isFreeCellSentinel(hdr)) {
                // Already on a size-class free list, accounted for by
                // freeLargeBodyCell. Treat as a hard run boundary: flush any
                // pending coalesced run *before* this cell, then step over
                // it. Do NOT touch the header or its free-list link, and do
                // NOT increment garbage_bytes again — freeLargeBodyCell is
                // the authoritative accounting site (Resolved Decisions §2).
                flushRun(sweep_buffer_index_);
            } else {
                // See is_large branch above for rationale: clear the
                // large_body_index_ entry for body cells that major GC sweep
                // reaches before nursery sweep does. Defensive idempotent
                // guard — freeLargeBodyCell is authoritative (§3).
                if (hdr->pin) {   // a body or a YLOS object: index is authoritative
                    auto it = large_body_index_.find(sweep_cursor_);
                    if (it != large_body_index_.end()) {
                        retireIndexEntry(it->second);
                        large_body_index_.erase(it);
                    }
                }
                // Non-sentinel dead cells (and non-sentinel Tag_Free cells
                // from padCellSlack/trailing-leftover/uniform-page slicing,
                // which weren't on a size-class free list when sweep got
                // here) extend the coalescing run; the eventual flushRun
                // updates garbage_bytes for the run.
                if (run_start == nullptr) {
                    run_start = sweep_cursor_;
                    run_bytes = 0;
                }
                run_bytes += step;
            }

            sweep_cursor_ += step;
            work_done += step;
        }

        if (sweep_cursor_ >= used_end) {
            // Block boundary -- flush any trailing garbage run.
            ECO_TLA_TRACE_ONLY(if (run_start != nullptr))   // M4: the trailing run's iteration
                ECO_M4_TRACE("m4.sw", "blk", cur_id.v,
                             "rs", static_cast<int64_t>((run_start - block.start) / MARK_ALIGNMENT),
                             "rb", run_bytes, "l", -1, "end", true);
            flushRun(sweep_buffer_index_);
#if ECO_HEAP_VALIDATE
            if (gap_sweep) {
                // V11 (HEAP_055). CR-028: inside a parallel promotion with more
                // than one worker another worker may still be writing a cell it
                // popped from this block (header after the unlock, body after
                // that): the walk runs in endParallelPromotion after the join.
                if (par_promo_active_ && promo_ctx_ && promo_ctx_->n > 1)
                    v11_deferred_.push_back({cur_id, block.start});   // under promo_mu_
                else
                    validateV11(cur_id);
            }
#endif
            markBlockFullySwept(cur_id);
            sweep_buffer_index_++;
            sweep_cursor_ = nullptr;
        }

        // Early exit if we've found space in the target class.
        if (target_class < NUM_SIZE_CLASSES &&
            free_lists_[target_class] != nullptr) {
            // Flush any in-progress run so we don't leave it dangling across
            // an early return.
            flushRun(sweep_buffer_index_);
            ECO_M4_TRACE("m4.swend", "cb", classToSize(target_class), "path", 1, "par", par_promo_active_);
            return work_done;
        }
    }

    // Flush any in-progress run before returning (we may resume mid-block on
    // the next call).
    flushRun(sweep_buffer_index_);

    ECO_TLA_TRACE_ONLY(if (sweep_buffer_index_ < blocks_.size()))   // M4: the slice ends (budget)
        ECO_M4_TRACE("m4.swend", "cb", target_class < NUM_SIZE_CLASSES ? classToSize(target_class) : 0,
                     "path", 0, "par", par_promo_active_);
    // The tail completion (path 3): since CR-014's fix it defers inside a
    // promotion exactly like the in-loop one (completeSweep).
    if (sweep_buffer_index_ >= blocks_.size()) completeSweep(3);
    return work_done;
}
// TLA-REGION(OGS.lazySweep) end

/**
 * Called when lazy sweeping completes.
 * Computes a precise post-sweep snapshot, then runs a light second-pass
 * shrink to mop up blocks that became fully empty through padCellSlack /
 * splitting after the heavy post-mark shrink. Compaction is decided on
 * the post-sweep stats.
 */
// TLA-REGION(OGS.onSweepComplete) begin
void OldGenSpace::onSweepComplete() {
    // CR-014 tripwire (PM7, every build): the shrink never runs inside a
    // parallel promotion. Both legitimate callers inside one clear the flag
    // first (sweepCompleteInPromotion's one-worker branch, endParallelPromotion).
    if (__builtin_expect(par_promo_active_, 0)) {
        std::fprintf(stderr, "[gc] FATAL: onSweepComplete inside a parallel promotion (CR-014)\n");
        std::abort();
    }
    sweep_pending_blocks_ = 0;
    sweep_total_blocks_ = 0;
    computeFragmentationStats();

    // Light-pass shrink: only fires if heap is still well above desired.
    // The heavy pass already ran at finishMarkAndSweep time using
    // mark-derived live; this catches blocks that drained later.
    const size_t live = frag_stats_.live_bytes;
    const float target = config_->major_gc_target_utilization;
    size_t desired_heap = (target > 0.0f && live > 0)
        ? static_cast<size_t>(std::ceil(
              static_cast<double>(live) / static_cast<double>(target)))
        : 0;
    maybeShrinkCapacity(desired_heap, /*light_pass=*/true);
    // M4: the light shrink is over (its m4.rel events name what it released);
    // par: on a worker inside a parallel minor (CR-014's tail path).
    ECO_M4_TRACE("m4.shrink", "par", par_promo_active_);
}
// TLA-REGION(OGS.onSweepComplete) end

OldGenSpace::MajorGCTriggerReason
OldGenSpace::evaluateMajorGCTrigger() const {
#if ECO_HEAP_VALIDATE
    const DecisionScope im16(*this);   // IM16
#endif
    // threaded-gc-05a (HEAP_063): no trigger fires while a cycle runs; the
    // cycle's own schedule, pressure finish and joins govern it (P§3.8).
    if (cycle_state_ != CycleState::Idle) return MajorGCTriggerReason::None;
    // With lazy sweep replacing STW sweep, "earlier" major GC triggers are
    // cheap: the post-mark pause is bounded by mark + initial sweep slice;
    // remaining sweep work is amortized across mutator allocations. The
    // numbers below are unchanged from the pre-lazy-sweep regime — the win
    // here comes from (a) accurate `allocated_bytes` and (b) the post-mark
    // shrink + all-dead reclaim keeping committed from ballooning between
    // majors, NOT from lower thresholds.
    const float threshold = config_->major_gc_initiating_occupancy;

    // Per-thread trigger: allocated bytes are crowding the local committed span.
    const size_t committed = getCommittedBytes();
    if (committed != 0 &&
        static_cast<double>(allocated_bytes) / committed >= threshold) {
        return MajorGCTriggerReason::Occupancy;
    }

    // Global pressure trigger: total old-gen committed grew well past the
    // post-last-GC working set. Without this, a workload that grows the
    // committed counter faster than `allocated_bytes` (e.g.
    // `allocateFromBagPage` burning a fresh page per request even when the
    // requested chunk is much smaller than the page) can run the address
    // space all the way to the cap before the per-thread ratio crosses the
    // threshold.
    //
    // The bar is `major_gc_global_pressure_fraction` of the cap (its own
    // config field; historically hard-coded as initiating_occupancy/3,
    // which fired at ~28% of the cap and dominated major-GC counts on
    // compile workloads — see the constant's comment and Run K in
    // benchmarks/runtime-calls.md; the old "several smaller cycles beat
    // big sweeps" rationale predates lazy sweep and measured false:
    // rare majors averaged 2.76 s vs 4.56 s under the low bar). At the
    // 0.85 default this is a genuine anti-ballooning backstop; Occupancy
    // and GarbageFraction do the routine collection scheduling.
    if (allocator_ != nullptr) {
        const size_t global_committed = allocator_->getOldGenCommittedBytes();
        const size_t cap = allocator_->getOldGenMaxBytes();
        const double global_pressure_threshold =
            static_cast<double>(config_->major_gc_global_pressure_fraction);
        if (cap > 0 &&
            static_cast<double>(global_committed) / cap >=
                global_pressure_threshold) {
            return MajorGCTriggerReason::GlobalPressure;
        }
        // threaded-gc-05c Part B (P§3.11): Headroom. Start the cycle while the
        // bytes it will allocate black over its fixed H_c = T + 1 minors still
        // fit under the pressure-finish line. Deterministic: P_hat is a
        // function of mutator allocation only.
        const double margin = config_->major_gc_headroom_margin;
        if (margin > 0.0 && cap > 0 && p_hat_ > 0) {
            const double growth = margin * static_cast<double>(pacingHorizonMinors()) *
                                  static_cast<double>(p_hat_);
            if (static_cast<double>(global_committed) + growth >=
                config_->incremental_mark_finish_fraction * static_cast<double>(cap)) {
                return MajorGCTriggerReason::Headroom;
            }
        }
    }

    // Garbage-fraction trigger: long-running compiles whose live working set
    // is much smaller than the post-first-major committed never re-cross the
    // occupancy threshold (free-list reuse keeps the heap from growing), so
    // dead bytes accumulate as un-swept garbage. Catch that case by tracking
    // bytes mutator-allocated since the last sweep finished and triggering
    // when they cross a fraction of committed — i.e. "if even all of those
    // bytes died and stayed un-swept, the heap would be that fraction
    // garbage". 0 disables.
    float garb_frac = config_->major_gc_garbage_fraction;
    // threaded-gc-05c Part B: with LiveBudget on, the garbage fraction can be
    // demoted to an anti-runaway backstop.
    if (config_->major_gc_garbage_backstop > 0.0f && config_->major_gc_live_budget > 0.0 &&
        garb_frac > 0.0f) {
        garb_frac = std::max(garb_frac, config_->major_gc_garbage_backstop);
    }
    // threaded-gc-02: in bitmap mode the denominator is CAPPED at
    // garbage_denom_cap (default 2) times the committed size at the last
    // major: min(committed, cap * committed_at_major_); 0 = uncapped.
    // Identical to the legacy trigger until committed more than doubles
    // after a major — the runaway case, where garbage cannot be reused before
    // the next major, every allocated byte grows committed, and a
    // current-committed denominator chases its numerator (measured: a
    // 12.7 GB major after 682 minors, RSS 14.4 GB). Frozen and damped
    // (lower) denominators were measured and over-trigger early in the run
    // (12-16 majors vs 6, +10-18 s GC).
    const double cap = config_->garbage_denom_cap;
    const size_t garb_denom =
        (config_->old_gen_bitmap_alloc && cap > 0.0 && committed_at_major_ > 0)
            ? std::min(committed, static_cast<size_t>(cap * committed_at_major_))
            : committed;
    if (garb_frac > 0.0f && garb_denom > 0) {
        const size_t alloc_since_major =
            (allocated_bytes >= post_sweep_live_bytes_)
                ? (allocated_bytes - post_sweep_live_bytes_) : 0;
        if (static_cast<double>(alloc_since_major) / garb_denom >= garb_frac) {
            return MajorGCTriggerReason::GarbageFraction;
        }
    }
    // LiveBudget: bound allocation between majors by the live set, with one
    // major's jump in live capped at live_growth_bound x the one before — so a
    // major that lands on a transient live-set peak cannot size the next cycle
    // for the peak (the garbage-fraction trigger alone sizes the heap at about
    // gf/(1-gf)+1 times the live set seen at ONE instant).
    const double budget = config_->major_gc_live_budget;
    if (budget > 0.0 && major_live_ > 0) {
        size_t live_ref = major_live_;
        const double bound = config_->live_growth_bound;
        if (bound > 0.0 && prev_major_live_ > 0) {
            live_ref = std::min(live_ref,
                                static_cast<size_t>(bound * prev_major_live_));
        }
        const size_t alloc_since_major =
            (allocated_bytes >= post_sweep_live_bytes_)
                ? (allocated_bytes - post_sweep_live_bytes_) : 0;
        // threaded-gc-05c Part B: paced -- the budget is reached at the
        // handoff (H_c minors after t0), not at t0.
        const double ahead = (config_->major_gc_live_budget_paced && p_hat_ > 0)
            ? static_cast<double>(pacingHorizonMinors()) * static_cast<double>(p_hat_) : 0.0;
        if (static_cast<double>(alloc_since_major) + ahead >= budget * live_ref) {
            return MajorGCTriggerReason::LiveBudget;
        }
    }
    return MajorGCTriggerReason::None;
}

void OldGenSpace::adjustCapacityAfterMajorGC() {
    // Counter is initialised by recomputeSweepPendingBlocks immediately
    // after this call, so we cannot assert sweepComplete() here. We can
    // assert that we are NOT in some half-state where Sweeping has already
    // started without buffer_meta_ being prepared.
    assert((gc_phase_ == GCPhase::Sweeping || gc_phase_ == GCPhase::Idle) &&
           "adjustCapacityAfterMajorGC: unexpected gc_phase_");

    char* const region_base = regionBase();   // CR-021: through atomic_ref
    char* const region_end = regionEnd();
    if (region_base == nullptr || region_end <= region_base) return;

    const size_t capacity = static_cast<size_t>(region_end - region_base);
    const size_t live     = frag_stats_.live_bytes;
    if (capacity == 0) return;

    const double occupancy = capacity > 0
        ? static_cast<double>(live) / capacity
        : 0.0;
    const float grow_threshold = config_->major_gc_initiating_occupancy;
    const float target         = config_->major_gc_target_utilization;

    // Compute desired heap from mark-derived live bytes, clamped by the
    // floor inside maybeShrinkCapacity. Used by both the shrink branch (to
    // release surplus capacity) and the grow branch (to extend committed).
    size_t desired_heap = (target > 0.0f && live > 0)
        ? static_cast<size_t>(std::ceil(
              static_cast<double>(live) / static_cast<double>(target)))
        : capacity;

    // Shrink branch: heap is at or below the target band — release fully-free
    // pages back to the global allocator. Heavy pass: hysteresis still
    // applies (1.2x desired), but the global-pressure bypass kicks in when
    // committed is approaching the cap.
    if (live == 0 || occupancy <= target) {
        maybeShrinkCapacity(desired_heap, /*light_pass=*/false);
        return;
    }

    if (occupancy < grow_threshold) return;

    const size_t global_cap = allocator_->getOldGenMaxBytes();
    if (desired_heap > global_cap) desired_heap = global_cap;
    if (desired_heap <= capacity)  return;

    allocator_->ensureOldGenCapacityFor(*this, desired_heap);
}

// Shrink path: returns fully-free pages back to the Allocator so
// `old_gen_committed` can drop after a major GC reclaims most live data.
// `desired_heap_bytes` is the post-mark target supplied by
// adjustCapacityAfterMajorGC; this function applies the floor, hysteresis,
// and global-pressure bypass on top.
//
// `light_pass=true` is used at onSweepComplete — it skips releases unless
// current_heap is well above desired (1.5x), since the heavy post-mark
// pass already ran and we just want to mop up blocks that became empty
// through padCellSlack/splitting after that.
//
// Locking: this function MUST NOT be called while holding
// `Allocator::thread_mutex_`. Each `releaseOldGenBlock` /
// `releaseUnassignedBlockToAllocator` call acquires the mutex transiently
// inside the Allocator. The shrink path runs at the end of major GC, with
// the mutator stopped — so `removeFreeCellsForBlock` and the swap-remove
// from `blocks_` cannot race against `allocateFromEmptyRegularBlocks`.
// TLA-REGION(OGS.maybeShrinkCapacity) begin
void OldGenSpace::maybeShrinkCapacity(size_t desired_heap_bytes,
                                      bool light_pass) {
    syncCursorLiveBytes();   // threaded-gc-02: readers of live_bytes
#if ENABLE_GC_STATS
    auto t0_shrink = GC_STATS_TIMER_START();
    auto bill = [&]() {
        uint64_t ns = GC_STATS_TIMER_ELAPSED_NS(t0_shrink);
        if (light_pass) alloc_stats_.total_maybe_shrink_light_ns += ns;
        else            alloc_stats_.total_maybe_shrink_heavy_ns += ns;
    };
    struct Billing {
        std::function<void()> bill;
        ~Billing() { bill(); }
    } billing{bill};
#endif

    if (compact_phase_ != CompactionPhase::Idle) return;
    if (allocator_     == nullptr)               return;
    // Note: gc_phase_ may now be Sweeping when called from finishMarkAndSweep
    // (heavy pass) or Idle when called from onSweepComplete (light pass).
    // The Marking phase guard is unnecessary because finishMarkAndSweep has
    // already drained the mark stack before calling here.

    const size_t live = frag_stats_.live_bytes;
    const float target = config_->major_gc_target_utilization;

    // Floor: never drop below max(initial_old_gen_size, alloc_buffer_size).
    // The first ensures we honor the user's configured starting capacity;
    // the second ensures at least one page is retained for new allocations.
    const size_t min_heap = std::max(config_->initial_old_gen_size,
                                     config_->alloc_buffer_size);

    size_t desired_heap = desired_heap_bytes;
    if (desired_heap < min_heap) desired_heap = min_heap;

    // Current heap = sum of materialized block bytes + bag-page bytes.
    auto computeCurrentHeap = [&]() -> size_t {
        size_t total = 0;
        for (size_t pos = 0; pos < blocks_.size(); ++pos) {
            total += blocks_.info(blocks_.idAt(pos)).totalBytes();
        }
        for (const auto& e : unassigned_blocks_) {
            total += static_cast<size_t>(e.second - e.first);
        }
        return total;
    };

    size_t current_heap = computeCurrentHeap();

    // Hysteresis gate. Two flavors:
    //   heavy pass: 1.2x desired AND occupancy below band.
    //   light pass: 1.5x desired (no occupancy gate, no global bypass) —
    //               just a mop-up, won't churn near the boundary.
    //
    // EXCEPTION (heavy only): when the global old-gen committed is
    // approaching the cap, we MUST shrink even inside the hysteresis band.
    // Otherwise the global pressure trigger in `shouldTriggerMajorGC`
    // re-fires the GC every safepoint without ever freeing committed bytes,
    // looping until we hit the cap for real.
    if (light_pass) {
        if (current_heap <= desired_heap + (desired_heap / 2)) return;
    } else {
        const double occupancy = current_heap > 0
            ? static_cast<double>(live) / static_cast<double>(current_heap)
            : 0.0;
        const bool below_band = occupancy < (static_cast<double>(target) * 0.8);
        const bool well_above_desired =
            current_heap > desired_heap + (desired_heap / 5);  // > 1.2x

        bool global_pressure = false;
        if (allocator_ != nullptr) {
            const size_t global_committed = allocator_->getOldGenCommittedBytes();
            const size_t cap = allocator_->getOldGenMaxBytes();
            const double global_pressure_threshold = static_cast<double>(
                config_->major_gc_global_pressure_fraction);
            if (cap > 0 &&
                static_cast<double>(global_committed) / cap >=
                    global_pressure_threshold) {
                global_pressure = true;
            }
        }

        if (!global_pressure && (!below_band || !well_above_desired)) return;
    }

    // First decide which blocks to release. Walking back-to-front means
    // releaseBlockToAllocator's swap-remove never disturbs yet-to-visit
    // indices.
    std::vector<size_t> to_release;
    to_release.reserve(blocks_.size() / 4);

    auto canRelease = [&](size_t bytes) -> bool {
        if (current_heap < bytes) return false;
        if (current_heap - bytes < desired_heap) return false;
        return true;
    };

    // Pass 1: fully-free regular pages.
    for (size_t i = blocks_.size(); i > 0;) {
        --i;
        if (current_heap <= desired_heap) break;
        const BlockId id = blocks_.idAt(i);
        const BufferMetadata& meta = blocks_.meta(id);
        if (!meta.fully_swept || meta.live_bytes != 0) continue;
        if (blocks_.info(id).is_large) continue;
        // threaded-gc-07 (trap 4, F11): this light pass runs OUTSIDE pauses.
        if (blocks_.info(id).alloc_state == kAllocTenure && !test_shrink_ignores_tenure_) continue;
        const size_t bytes = blocks_.info(id).totalBytes();
        if (!canRelease(bytes)) continue;
        to_release.push_back(i);
        current_heap -= bytes;
    }

    // Pass 2: fully-free large blocks.
    for (size_t i = blocks_.size(); i > 0;) {
        --i;
        if (current_heap <= desired_heap) break;
        const BlockId id = blocks_.idAt(i);
        const BufferMetadata& meta = blocks_.meta(id);
        if (!meta.fully_swept || meta.live_bytes != 0) continue;
        if (!blocks_.info(id).is_large) continue;
        const size_t bytes = blocks_.info(id).totalBytes();
        if (!canRelease(bytes)) continue;
        to_release.push_back(i);
        current_heap -= bytes;
    }

    if (!to_release.empty()) {
        // Tier-S (class 1) batched pre-clean: walk free_lists_[1] ONCE,
        // dropping any cell whose address falls in ANY block we're about
        // to release. Only class 1 needs this — all other classes use the
        // O(cells_in_block) per-block thread inside removeFreeCellsForBlock.
        std::sort(to_release.begin(), to_release.end());
        // Positions -> ids BEFORE any release. Releasing in descending
        // position order (below) never moves a lower position, so the id at
        // each captured position is exactly the block the former
        // position-based loop released (HEAP_048: ids are stable).
        std::vector<BlockId> release_ids;
        release_ids.reserve(to_release.size());
        std::vector<std::pair<char*, char*>> ranges;
        ranges.reserve(to_release.size());
        for (size_t pos : to_release) {
            const BlockId id = blocks_.idAt(pos);
            release_ids.push_back(id);
            ranges.emplace_back(blocks_.info(id).start, blocks_.info(id).end);
        }
        std::sort(ranges.begin(), ranges.end());
        auto inAnyRange = [&](char* p) -> bool {
            auto it = std::upper_bound(
                ranges.begin(), ranges.end(),
                std::make_pair(p, static_cast<char*>(nullptr)));
            if (it == ranges.begin()) return false;
            --it;
            return p < it->second;
        };
        if (free_lists_[1] != nullptr) {
            FreeCell** prev = &free_lists_[1];
            FreeCell* curr = free_lists_[1];
            while (curr != nullptr) {
                FreeCell* next = curr->next_in_class;
                if (inAnyRange(reinterpret_cast<char*>(curr))) {
                    *prev = next;  // unlink (Tier-S has no per-block thread)
                } else {
                    prev = &curr->next_in_class;
                }
                curr = next;
            }
        }
        // Now release each block. Tier-M classes are unlinked via the
        // per-block thread inside removeFreeCellsForBlock; class 1 has
        // already been pre-cleaned above so the per-block call's class-1
        // walk finds nothing.
        ++batch_release_depth_;
        for (auto it = release_ids.rbegin(); it != release_ids.rend(); ++it) {
            releaseBlockToAllocator(*it);
        }
        --batch_release_depth_;

        // One-shot recompute of region_base_ / region_end_ over the new state
        // (the page index is keyed from index_base_ and needs no rebuild).
        recomputeRegionBounds();
    }

    // Pass 3: unassigned bag pages.
    for (size_t i = unassigned_blocks_.size(); i > 0;) {
        --i;
        if (current_heap <= desired_heap) break;
        const size_t bytes =
            static_cast<size_t>(unassigned_blocks_[i].second
                                - unassigned_blocks_[i].first);
        if (!canRelease(bytes)) continue;
        releaseUnassignedBlockToAllocator(i);
        current_heap -= bytes;
    }
#if ECO_HEAP_VALIDATE
    validateOldGenMetadata("maybeShrinkCapacity");
#endif
}
// TLA-REGION(OGS.maybeShrinkCapacity) end

void OldGenSpace::removeFreeCellsForBlock(BlockId block_index) {
    if (!block_index.valid()) return;
    BlockInfo& blk = blocks_.info(block_index);

    // Tier-M cells: O(cells in this block) walk via the per-block thread.
    // Each cell is unlinked from its class list in O(1) via the back-link,
    // and from the per-block thread in O(1) via blockThreadUnlink. We
    // walk the thread destructively, advancing to next_in_block before
    // unlink.
    {
        FreeCell* curr = resolveOff(blk, blk.free_cells_in_block);
        while (curr != nullptr) {
            FreeCell* next = resolveOff(blk, asTierM(curr)->next_in_block);
            const size_t cls = sizeClass(curr->header.size);
            // Class-list unlink (O(1)).
            classListUnlinkTierM(free_lists_, curr, cls);
            // Per-block thread unlink — actually unnecessary here because
            // we're tearing the whole thread down; clearing the head at
            // the end suffices. Skipped for speed.
            curr = next;
        }
        blk.free_cells_in_block = FREE_CELLS_EMPTY;
    }

    // Tier-S (class 1) cells: bounded global walk of free_lists_[1].
    // Skip when running inside a maybeShrinkCapacity batch — that caller
    // already pre-cleaned class 1 once across all blocks.
    if (batch_release_depth_ == 0 && free_lists_[1] != nullptr) {
        char* lo = blk.start;
        char* hi = blk.end;
        FreeCell** prev = &free_lists_[1];
        FreeCell* curr = free_lists_[1];
        while (curr != nullptr) {
            char* p = reinterpret_cast<char*>(curr);
            FreeCell* next = curr->next_in_class;
            if (p >= lo && p < hi) {
                *prev = next;
            } else {
                prev = &curr->next_in_class;
            }
            curr = next;
        }
    }

#if ECO_HEAP_VALIDATE
    // Candidate (3) probe — leaked free cells across a block release.
    // After the per-block thread + class-1 cleanups above, no cell on any
    // free_lists_[cls] should fall within [blk.start, blk.end). If one does,
    // the block release left it stranded on the class list; the page bytes
    // will be reused (unassigned_blocks_ / populateFromBlock) while the
    // stranded reference still appears in the chain — causing a later sweep
    // to re-push at the same address (a duplicate push, then a cycle).
    {
        char* lo = blk.start;
        char* hi = blk.end;
        for (size_t cls = 0; cls < NUM_SIZE_CLASSES; ++cls) {
            size_t depth = 0;
            for (FreeCell* c = free_lists_[cls]; c != nullptr;
                 c = c->next_in_class) {
                char* p = reinterpret_cast<char*>(c);
                if (p >= lo && p < hi) {
                    std::fprintf(stderr,
                        "[heap-validate] removeFreeCellsForBlock LEAK: "
                        "cell %p (header.size=%u, header.tag=%u, header.age=%u) "
                        "survives on free_lists[%zu] at depth %zu after "
                        "removing block %zu [%p, %p). class-1=%s, "
                        "batch_release_depth=%d. The block's bytes will be "
                        "reused while %p still points to it; a later "
                        "lazySweep push at this address will form a cycle.\n",
                        p, (unsigned)c->header.size, (unsigned)c->header.tag,
                        (unsigned)c->header.age, cls, depth,
                        (size_t)block_index.v,
                        (void*)lo, (void*)hi,
                        (cls == 1 ? "yes" : "no"),
                        (int)batch_release_depth_, p);
                    std::fflush(stderr);
                    std::abort();
                }
                if (++depth > 1'000'000) break;
            }
        }
    }
#endif
}

void OldGenSpace::fixupCursorsAfterOrderMove(size_t old_pos, size_t new_pos) {
    if (old_pos == new_pos) return;

    // threaded-gc-01 (HEAP_048): only the two POSITION cursors follow a
    // swap-remove. evacuation_set_, free_large_blocks_ and evac_block_index_
    // hold BlockIds, which do not move; the free-list back-links are
    // addresses (HEAP_052). (W9 item 41 had already removed the O(#blocks)
    // BufferMetadata::block_index walk that once stood here.)
    if (sweep_buffer_index_ == old_pos) sweep_buffer_index_ = new_pos;
    if (fixup_buffer_index_ == old_pos) fixup_buffer_index_ = new_pos;
}

// TLA-REGION(OGS.releaseBlockToAllocator) begin
void OldGenSpace::releaseBlockToAllocator(BlockId block_index) {
    assert(!cycleActive() && "IM5: release/compaction during an incremental mark cycle");
#if ECO_HEAP_VALIDATE
    // CR-007 / CR-014 (HEAP_058): no release inside a parallel promotion with
    // n > 1 workers (a release may wait on a populate under promo_mu_).
    if (acquireWaitPolicy() != AcquireWait::Allowed) {
        std::fprintf(stderr, "[heap-validate] CR-007: a block release inside a parallel "
                     "promotion with n > 1 workers\n");
        std::abort();
    }
#endif
    if (!block_index.valid()) return;
    ECO_M4_TRACE("m4.rel", "blk", block_index.v, "state", blocks_.info(block_index).alloc_state);
    if (config_->old_gen_bitmap_alloc) detachFromAllocation(block_index);

    // The heap-base block is released like any other block. (It was formerly
    // pinned because offset 0 had to stay reserved for the heap-base sentinel;
    // under absolute addressing heap_base is a valid non-null address, so there
    // is nothing special about it — the sentinel was removed, D5.)

    // Debit the small-class budget BEFORE we touch blocks_; the helper
    // reads info(block_index).size_class to decide whether to debit.
    onBlockReleased(block_index);

    BlockInfo blk = blocks_.info(block_index);
    const size_t total = blk.totalBytes();

    // Non-large releases must always be exactly one BBoP page (page extents in
    // unassigned_blocks_ are full-page-sized).
    assert((blk.is_large || total == config_->alloc_buffer_size) &&
           "releaseBlockToAllocator: non-large block must be one full page");

    // If this block was tracked as still needing sweep, drop it from the
    // pending count BEFORE the block-table swap-remove (so the post-swap
    // entry, which moved into block_index from the last slot, doesn't get
    // accidentally double-counted on its own future fully_swept transition).
    if (!blocks_.meta(block_index).fully_swept &&
        sweep_pending_blocks_ > 0) {
        --sweep_pending_blocks_;
    }

    // Unlink any free-list entries that overlap this block before the
    // virtual address range becomes reusable.
    removeFreeCellsForBlock(block_index);

    // Drop a free_large_blocks_ entry that points at this index (if any).
    for (size_t k = 0; k < free_large_blocks_.size();) {
        if (free_large_blocks_[k] == block_index) {
            free_large_blocks_[k] = free_large_blocks_.back();
            free_large_blocks_.pop_back();
        } else {
            ++k;
        }
    }

    // Clean up `large_body_index_` entries pointing into this block. Without
    // this, `reclaimAllDeadBlocksFromMeta` (which releases blocks where the
    // mark-derived `live_bytes` is 0, even when sweep hasn't yet walked the
    // block to clear the dead body's tracking) leaves stale entries that
    // later cause `freeLargeBodyCell` to push the body's bytes onto a free
    // list in a DIFFERENT block (the new block created at the same page
    // address by `populateFromBlock`). When that new block is uniform with
    // `cellSize != m.cell_size`, the UNIFORM-branch trailing-leftover path
    // in `pushSpanOnFreeLists` writes a sub-cellSize Tag_Free header into
    // the block — corrupting cell alignment and producing the off-by-8
    // dangling HPointer seen at LOT=8K (see
    // bugs/C-lot-8K-alignment-investigation.md v15).
    //
    // Treat any large body whose body_base falls within this block as
    // logically dead: the block's live_bytes is 0 (otherwise we wouldn't be
    // releasing it), which means mark didn't see anything live in this
    // block — including unmarked bodies whose nursery LargeStringHeader
    // didn't get rooted before the major GC fired.
    {
        char* blk_start = blk.start;
        char* blk_end = blk.end;
        for (auto it = large_body_index_.begin();
             it != large_body_index_.end();) {
            char* body_base = static_cast<char*>(const_cast<void*>(it->first));
            if (body_base >= blk_start && body_base < blk_end) {
                LargeBodyId id = it->second;
                if (id < large_bodies_.size()) {
                    large_bodies_[id].body_base = nullptr;
                    free_large_body_ids_.push_back(id);
                }
                it = large_body_index_.erase(it);
            } else {
                ++it;
            }
        }
#if ECO_HEAP_VALIDATE
        // Class 4 — large_body_index_ ↔ block invariant: after cleanup, no
        // entry should still resolve to a body inside the block being
        // released. Past LOT=8K bug surfaced from leftover entries here.
        for (const auto& kv : large_body_index_) {
            char* body_base = static_cast<char*>(const_cast<void*>(kv.first));
            if (body_base >= blk_start && body_base < blk_end) {
                std::fprintf(stderr,
                    "[heap-validate] large_body_index_ post-cleanup "
                    "violation: body_base=%p still maps into released "
                    "block [%p,%p) (idx=%zu)\n",
                    (void*)body_base, (void*)blk_start, (void*)blk_end,
                    (size_t)block_index.v);
                std::fflush(stderr);
                std::abort();
            }
        }
#endif
    }

    // Clear the page-index slots this block owned BEFORE the swap-remove,
    // so the moved-from block's slot rewrite below is the only update that
    // can reference this address range.
    clearPageIndexForBlock(block_index);

    // Hand the address range back to the Allocator.
    allocator_->releaseOldGenBlock(blk.start, total);

    // Maintain frag_stats_.heap_bytes (sum of block parseable spans).
    const size_t parseable =
        static_cast<size_t>(blk.end_of_objects - blk.start);
    if (frag_stats_.heap_bytes >= parseable) {
        frag_stats_.heap_bytes -= parseable;
    } else {
        frag_stats_.heap_bytes = 0;
    }

    // Remove from the block table with vector swap-remove semantics on the
    // ORDER (the last position moves into this one, exactly as the former
    // std::vector did); the id is retired and nothing else moves (HEAP_048).
    const size_t pos = blocks_.posOf(block_index);
    const size_t last = blocks_.size() - 1;
    mark_.retire(block_index);
    blocks_.swapRemove(block_index);

    // Patch the position cursors that referred to the moved-from slot.
    if (pos != last) {
        fixupCursorsAfterOrderMove(last, pos);
    }

    // Recompute region_base_ / region_end_ if either was anchored to the
    // released extent. A linear scan is fine for one-off releases — but in
    // batch mode (shrink path) we let the caller recompute once at the end
    // to avoid an O(N²) per-release cost.
    if (batch_release_depth_ == 0 &&
        (blk.start == regionBase() || blk.end == regionEnd())) {
        recomputeRegionBounds();
    }
}
// TLA-REGION(OGS.releaseBlockToAllocator) end

// TLA-REGION(OGS.releaseUnassignedBlockToAllocator) begin
void OldGenSpace::releaseUnassignedBlockToAllocator(size_t unassigned_index) {
    assert(!cycleActive() && "IM5: release/compaction during an incremental mark cycle");
#if ECO_HEAP_VALIDATE
    // CR-007 / CR-014 (HEAP_058): no release inside a parallel promotion with
    // n > 1 workers (a release may wait on a populate under promo_mu_).
    if (acquireWaitPolicy() != AcquireWait::Allowed) {
        std::fprintf(stderr, "[heap-validate] CR-007: a page release inside a parallel "
                     "promotion with n > 1 workers\n");
        std::abort();
    }
#endif
    if (unassigned_index >= unassigned_blocks_.size()) return;

    // Mirror releaseBlockToAllocator: keep the heap-base extent permanently
    // pinned so the sentinel discipline can never be defeated by a release
    // + acquire round-trip.
    if (allocator_ != nullptr &&
        unassigned_blocks_[unassigned_index].first ==
            allocator_->getHeapBase()) {
        return;
    }

    auto extent = unassigned_blocks_[unassigned_index];
    char* start = extent.first;
    char* end   = extent.second;
    const size_t bytes = static_cast<size_t>(end - start);

    allocator_->releaseOldGenBlock(start, bytes);

    // Swap-remove.
    const size_t last = unassigned_blocks_.size() - 1;
    if (unassigned_index != last) {
        unassigned_blocks_[unassigned_index] = unassigned_blocks_[last];
    }
    unassigned_blocks_.pop_back();

    // Recompute bounds if anchored to the released extent. Slot indices are
    // computed from (start - region_base_) / page_size, so when region_base_
    // shifts we also have to rebuild the page index.
    if (start == regionBase() || end == regionEnd()) {
        recomputeRegionBounds();
    }
}
// TLA-REGION(OGS.releaseUnassignedBlockToAllocator) end

// ---------------------------------------------------------------------------
// All-dead block fast path (Step 3).
// ---------------------------------------------------------------------------

OldGenSpace::AllDeadReclaimStats
OldGenSpace::reclaimAllDeadBlocksFromMeta() {
    AllDeadReclaimStats stats;

    // Floor: never drop committed below max(initial_old_gen_size,
    // alloc_buffer_size). Mirrors maybeShrinkCapacity so reclaim and the
    // shrink path agree on the minimum.
    const size_t min_heap =
        std::max(config_->initial_old_gen_size, config_->alloc_buffer_size);

    // Compute current committed bytes (materialized blocks + bag pages) up
    // front so the floor check can preview each release.
    size_t current_heap = 0;
    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        current_heap += blocks_.info(blocks_.idAt(pos)).totalBytes();
    }
    for (const auto& e : unassigned_blocks_) {
        current_heap += static_cast<size_t>(e.second - e.first);
    }

    // Collect indices of non-large blocks whose mark-derived live_bytes is
    // zero. is_large blocks are intentionally excluded — they continue to
    // flow through markBlockAsFreeLarge / allocateFromFreeLargeBlocks so
    // their virtual address can be reused without touching the OS. Skip
    // releases that would push committed below min_heap.
    //
    // `dead` is collected in ascending POSITION order and released in
    // descending position order, exactly as before; each position is
    // captured as its (stable) id first. Releasing a higher position never
    // moves a lower one, so the ids name exactly the blocks the former
    // position-based loop released (HEAP_048).
    std::vector<BlockId> dead;
    dead.reserve(blocks_.size() / 4);
    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        const BlockId id = blocks_.idAt(pos);
        if (blocks_.info(id).is_large) continue;
        if (blocks_.meta(id).live_bytes != 0) continue;
        if (blocks_.info(id).alloc_state == kAllocTenure) continue;   // threaded-gc-07 trap 4
        const size_t bytes = blocks_.info(id).totalBytes();
        if (current_heap < bytes) continue;
        if (current_heap - bytes < min_heap) continue;
        dead.push_back(id);
        current_heap -= bytes;
    }
    if (dead.empty()) return stats;

    // Tally bytes for the profile log before mutation.
    for (BlockId id : dead) {
        stats.bytes_released += blocks_.info(id).totalBytes();
    }
    stats.blocks_released = dead.size();

    // Bracket the loop so each release skips its O(N) bounds recompute; we
    // recompute once at the end. Walk back-to-front (descending position).
    ++batch_release_depth_;
    for (auto it = dead.rbegin(); it != dead.rend(); ++it) {
        releaseBlockToAllocator(*it);
    }
    --batch_release_depth_;

    // One-shot recompute of region_base_ / region_end_ (the page index is
    // keyed from index_base_ and needs no rebuild, HEAP_049).
    recomputeRegionBounds();

#if ECO_HEAP_VALIDATE
    validateOldGenMetadata("reclaimAllDeadBlocksFromMeta");
#endif
    return stats;
}

#if ENABLE_GC_STATS
// Keeps GCStats's free-list size-class histogram in lockstep with the
// allocator's class table; the printer reconstructs `classToSize`
// arithmetically from this width.
static_assert(NUM_SIZE_CLASSES <= GCStats::FREELIST_CLASS_BUCKETS,
              "GCStats::FREELIST_CLASS_BUCKETS must cover every "
              "OldGenSpace size class");

// Phase A of the major-GC end residency snapshot. Sampled after
// finalizeMetaAfterMark and BEFORE transitionToSweeping clears
// free_lists_ / free_large_blocks_. Walks each per-class free list to
// record (a) per-class cell/byte totals for the free-list size-class
// histogram and (b) per-block free-list bytes (keyed by BlockInfo::start
// so the map survives reclaim's swap-remove). `free_large_blocks_` is
// rolled into the per-block totals as whole-block free entries and
// reported separately to the size-class histogram.
void OldGenSpace::gatherFreeListSnapshotInto(
    GCStats& stats, FreeBytesByBlockStart& out) const {
    // Clear the latest_* mirror for the free-list portion only. The
    // residency mirror is cleared by Phase B once reclaim and shrink
    // have run.
    stats.beginFreeListSnapshot();

    out.clear();

    for (size_t cls = 0; cls < NUM_SIZE_CLASSES; ++cls) {
        // Floyd's tortoise-and-hare. A cycle in free_lists_[cls]->next_in_class
        // turns the loop below into an infinite walk that pegs CPU forever and
        // never makes the user-visible compiler progress. Detect that here and
        // abort with the entry cell so we can localize the double-push site
        // (see warm-cache Stage 7a hang investigation). The check is O(N) on
        // the same walk we'd do anyway, so the cost on healthy lists is one
        // extra pointer-load per iteration.
#if ECO_HEAP_VALIDATE
        {
            FreeCell* slow = free_lists_[cls];
            FreeCell* fast = free_lists_[cls];
            while (fast != nullptr && fast->next_in_class != nullptr) {
                slow = slow->next_in_class;
                fast = fast->next_in_class->next_in_class;
                if (slow == fast) {
                    std::fprintf(stderr,
                        "[heap-validate] free_lists_[%zu] CYCLE detected via "
                        "Floyd's algorithm at cell %p (header.size=%u, "
                        "header.tag=%u, header.age=%u). Head=%p, "
                        "blockIdFor(cell)=%u, blocks_.size()=%zu. "
                        "Aborting before the snapshot walk pegs CPU.\n",
                        cls, (void*)slow,
                        slow ? (unsigned)slow->header.size : 0u,
                        slow ? (unsigned)slow->header.tag : 0u,
                        slow ? (unsigned)slow->header.age : 0u,
                        (void*)free_lists_[cls],
                        slow ? blockIdFor(slow).v : 0u,
                        blocks_.size());
                    std::fflush(stderr);
                    std::abort();
                }
            }
        }
#endif  // ECO_HEAP_VALIDATE (W0 item 49: a debug tripwire, not telemetry)

        uint64_t cell_count = 0;
        uint64_t cell_bytes = 0;
        for (FreeCell* cell = free_lists_[cls]; cell != nullptr;
             cell = cell->next_in_class) {
            const size_t sz = cell->header.size;
            cell_count++;
            cell_bytes += sz;
            const BlockId bi = blockIdFor(cell);
            if (bi.valid()) {
                out[blocks_.info(bi).start] += sz;
            }
        }
        if (cell_count > 0) {
            stats.recordFreeListClass(cls, cell_count, cell_bytes);
        }
    }

    uint64_t large_count = 0;
    uint64_t large_bytes = 0;
    for (BlockId bi : free_large_blocks_) {
        if (!bi.valid()) continue;
        const size_t total = blocks_.info(bi).totalBytes();
        out[blocks_.info(bi).start] += total;
        large_count++;
        large_bytes += total;
    }
    if (large_count > 0) {
        stats.recordFreeListLargeBlocks(large_count, large_bytes);
    }
    stats.recordFreeListSnapshot();
}

// Phase B of the major-GC end residency snapshot. Sampled after
// reclaimAllDeadBlocksFromMeta and adjustCapacityAfterMajorGC, so the
// histogram reflects the true post-reclaim block set: the live_frac == 0
// bucket holds genuinely retained dead pages (min-heap floor, heap-base
// sentinel, is_large exclusion, pinning), not the candidates that were
// already released. Per-block free bytes come from the map captured by
// Phase A — surviving blocks' `start` keys are stable across reclaim's
// swap-remove. Reclaimed blocks drop out of `blocks_` and their entries
// in `free_by_start` are simply unused.
void OldGenSpace::gatherResidencySnapshotFrom(
    GCStats& stats, const FreeBytesByBlockStart& free_by_start) const {
    stats.beginResidencySnapshot();

    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        const BlockId i = blocks_.idAt(pos);
        const BlockInfo& blk = blocks_.info(i);
        const BufferMetadata& meta = blocks_.meta(i);
        const size_t total = blk.totalBytes();
        if (total == 0) continue;
        size_t free_bytes = 0;
        auto it = free_by_start.find(blk.start);
        if (it != free_by_start.end()) free_bytes = it->second;
        stats.recordBlockResidency(total, meta.live_bytes,
                                   free_bytes, blk.is_large);
    }
    stats.recordResidencySnapshot();
}
#endif

/**
 * Computes heap-wide fragmentation statistics from per-block metadata.
 */
// TLA-REGION(OGS.computeFragmentationStats) begin
void OldGenSpace::computeFragmentationStats() {
    syncCursorLiveBytes();   // threaded-gc-02: readers of live_bytes
    frag_stats_.live_bytes = 0;
    frag_stats_.total_free_bytes = 0;
    frag_stats_.heap_bytes = 0;

    for (size_t pos = 0; pos < blocks_.size(); pos++) {
        const BlockId i = blocks_.idAt(pos);
        const auto& meta = blocks_.meta(i);
        frag_stats_.live_bytes += meta.live_bytes;
        frag_stats_.total_free_bytes += meta.garbage_bytes;
        // heap_bytes counts the parseable region of each block.
        frag_stats_.heap_bytes += static_cast<size_t>(
            blocks_.info(i).end_of_objects - blocks_.info(i).start);
    }

    // allocated_bytes reflects actual live bytes after sweep.
    allocated_bytes = frag_stats_.live_bytes;
    // Baseline for the garbage-fraction trigger: every byte the mutator
    // allocates from this point on is "post-major" allocation, even when it
    // lands on a free-list cell that was just reclaimed.
    post_sweep_live_bytes_ = frag_stats_.live_bytes;
    // threaded-gc-05a: the last cycle's allocate-black bytes stay counted as
    // allocation since the major until the next one (see finalizeMetaAfterMark).
    post_sweep_live_bytes_ = (post_sweep_live_bytes_ > baseline_black_bytes_)
                                 ? post_sweep_live_bytes_ - baseline_black_bytes_ : 0;
}
// TLA-REGION(OGS.computeFragmentationStats) end

/**
 * Returns true if compaction should be triggered.
 * Based on heap utilization falling below threshold. Compaction is
 * forbidden while lazy sweep is in progress (the partially-rebuilt
 * meta.fully_swept flags would mislead selectEvacuationSet, and the
 * post-mark live_bytes attribution differs from the post-sweep value
 * compaction expects). The mutator drains lazy sweep before we can
 * legally schedule compaction.
 */
bool OldGenSpace::shouldCompact() const {
    if (gc_phase_ != GCPhase::Idle) return false;
    return frag_stats_.utilization() < UTILIZATION_THRESHOLD;
}

// ============================================================================
// Incremental Compaction Implementation
// ============================================================================

void OldGenSpace::scheduleCompaction() {
    assert(!cycleActive() && "IM5: release/compaction during an incremental mark cycle");
    syncCursorLiveBytes();   // threaded-gc-02: readers of live_bytes
    if (compact_phase_ != CompactionPhase::Idle) return;
    // Same gate as shouldCompact: compaction must wait for lazy sweep to
    // finish so meta is fully rebuilt and free_lists_ are stable.
    if (gc_phase_ != GCPhase::Idle) return;
    assert(sweepComplete() &&
           "scheduleCompaction: sweep must be complete (gc_phase_ == Idle)");

    evacuation_set_ = selectEvacuationSet(COMPACTION_WORK_BUDGET * 10);
    if (evacuation_set_.empty()) return;
    p1::invalidate(*this);   // threaded-gc-04: objects are about to move

    compact_phase_ = CompactionPhase::Evacuating;
    current_evac_index_ = 0;
    evac_cursor_ = nullptr;
    evac_block_index_ = NO_BLOCK_ID;
    evac_alloc_ptr_ = nullptr;
}

std::vector<BlockId> OldGenSpace::selectEvacuationSet(size_t max_live_to_move) {
    struct Candidate {
        BlockId index;
        size_t garbage_bytes;
        size_t live_bytes;
    };
    std::vector<Candidate> candidates;

    for (size_t pos = 0; pos < blocks_.size(); pos++) {
        const BlockId i = blocks_.idAt(pos);
        const auto& meta = blocks_.meta(i);
        const BlockInfo& blk = blocks_.info(i);

        if (!meta.fully_swept) continue;
        if (blk.alloc_state == kAllocTenure) continue;   // threaded-gc-07 trap 4

        // Skip the block we're currently bump-allocating into for evacuation.
        if (i == evac_block_index_) continue;

        // Skip large/pinned blocks (sweep marks pinned via the object header,
        // but we identify the block via the is_large flag for clarity).
        if (blk.is_large) continue;
        if (blk.end_of_objects > blk.start) {
            const Header* first_hdr =
                reinterpret_cast<const Header*>(blk.start);
            if (first_hdr->pin) continue;
        }

        size_t total = static_cast<size_t>(blk.end_of_objects - blk.start);
        float liveness = total > 0 ? static_cast<float>(meta.live_bytes) / total : 0.0f;

        if (liveness < 0.70f && meta.garbage_bytes > 0) {
            candidates.push_back({i, meta.garbage_bytes, meta.live_bytes});
        }
    }

    std::sort(candidates.begin(), candidates.end(),
        [](const Candidate& a, const Candidate& b) {
            return a.garbage_bytes > b.garbage_bytes;
        });

    std::vector<BlockId> evacuation_set;
    size_t total_live = 0;

    for (const auto& c : candidates) {
        if (total_live + c.live_bytes > max_live_to_move) break;
        evacuation_set.push_back(c.index);
        total_live += c.live_bytes;
    }

    return evacuation_set;
}

void OldGenSpace::incrementalCompactionSlice(size_t work_budget) {
    assert(!cycleActive() && "IM5: release/compaction during an incremental mark cycle");
    if (compact_phase_ == CompactionPhase::Idle) return;

    size_t work_done = 0;

    if (compact_phase_ == CompactionPhase::Evacuating) {
        work_done = evacuateSlice(work_budget);

        if (current_evac_index_ >= evacuation_set_.size()) {
            compact_phase_ = CompactionPhase::FixingRefs;
            prepareReferenceFixup();
        }
    }

    if (compact_phase_ == CompactionPhase::FixingRefs &&
        work_done < work_budget) {
        fixReferencesSlice(work_budget - work_done);
    }
}

size_t OldGenSpace::evacuateSlice(size_t work_budget) {
    size_t work_done = 0;

    while (work_done < work_budget &&
           current_evac_index_ < evacuation_set_.size()) {

        const BlockId src_idx = evacuation_set_[current_evac_index_];
        BlockInfo& src_block = blocks_.info(src_idx);

        if (evac_cursor_ == nullptr) {
            evac_cursor_ = src_block.start;
        }

        char* end = src_block.end_of_objects;

        // threaded-gc-02: uniform blocks are not header-parsable in bitmap
        // mode — skip cells whose start bit is clear (free).
        const bool evac_uniform_bitmap = config_->old_gen_bitmap_alloc &&
            !src_block.is_large && src_block.size_class < num_size_classes_;
        while (evac_cursor_ < end && work_done < work_budget) {
            if (evac_uniform_bitmap && !isMarkedInBlock(src_idx, evac_cursor_)) {
                evac_cursor_ += classToSize(src_block.size_class);
                continue;
            }
            Header* hdr = reinterpret_cast<Header*>(evac_cursor_);
            size_t obj_size = getObjectSize(evac_cursor_);
            size_t step = walkStep(src_block, obj_size);

            // Free cells: nothing to evacuate; advance.
            if (hdr->tag == Tag_Free) {
                evac_cursor_ += step;
                continue;
            }

            // Pinned objects must not be moved. Install a self-forwarding
            // pointer so the fixup phase resolves references through
            // getForwardingAddress without any other code changes.
            if (hdr->tag != Tag_Forward && hdr->pin) {
                installForwardingPointer(evac_cursor_, evac_cursor_);
                evac_cursor_ += step;
                continue;
            }

            if (hdr->tag != Tag_Forward) {
                // Copy only the object's logical bytes; slack between
                // obj_size and step (cell size, for size-class blocks) is
                // dead weight in the source cell and not worth carrying
                // to the evacuation destination, which packs tightly.
                void* dest = allocateForEvacuation(obj_size);
                if (dest == nullptr) {
                    // Out of space - abort compaction.
                    compact_phase_ = CompactionPhase::Idle;
                    evacuation_set_.clear();
                    return work_done;
                }

                std::memcpy(dest, evac_cursor_, obj_size);
                // Reset color: see the matching reset in
                // NurserySpace::evacuate. allocateForEvacuation does not go
                // through initObjectHeader, so the destination's color is
                // whatever bytes were there; the memcpy then clobbers it with
                // the source's color. Force White so the next major mark
                // visits this object and processes its children.
                Header* dest_hdr = getHeader(dest);
                dest_hdr->color = static_cast<u32>(Color::White);
                installForwardingPointer(evac_cursor_, dest);

                work_done += step;
            }

            evac_cursor_ += step;
        }

        if (evac_cursor_ >= end) {
            current_evac_index_++;
            evac_cursor_ = nullptr;
        }
    }

    return work_done;
}

/**
 * Allocates space for an evacuated object via a private bump cursor inside an
 * evacuation destination block (sourced from the bag). Distinct from the
 * mutator path so that compaction does not interfere with size-class lists.
 */
void* OldGenSpace::allocateForEvacuation(size_t size) {
    size = (size + 7) & ~7;

    auto bumpInBlock = [&](BlockId idx) -> void* {
        BlockInfo& blk = blocks_.info(idx);
        if (evac_alloc_ptr_ == nullptr) {
            evac_alloc_ptr_ = blk.end_of_objects;  // Resume at the watermark.
        }
        if (evac_alloc_ptr_ + size > blk.end) return nullptr;
        char* result = evac_alloc_ptr_;
        evac_alloc_ptr_ += size;
        // Advance the parseable watermark so sweep can walk evacuated objects.
        blk.end_of_objects = evac_alloc_ptr_;
        return result;
    };

    if (evac_block_index_.valid() && !isInEvacuationSet(evac_block_index_)) {
        if (void* r = bumpInBlock(evac_block_index_)) return r;
    }

    // Need a fresh page from the bag.
    if (unassigned_blocks_.empty()) {
        // Try to acquire more capacity from the allocator.
        if (allocator_) {
            char* base = allocator_->acquireOldGenBlock(config_->alloc_buffer_size);
            if (base != nullptr) {
                unassigned_blocks_.emplace_back(base, base + config_->alloc_buffer_size);
                if (char* const rb = regionBase(); rb == nullptr || base < rb) setRegionBase(base);
                if (base + config_->alloc_buffer_size > regionEnd()) {
                    setRegionEnd(base + config_->alloc_buffer_size);
                }
                resizePageIndexForRegion();
            }
        }
        if (unassigned_blocks_.empty()) return nullptr;
    }

    auto extent = unassigned_blocks_.back();
    unassigned_blocks_.pop_back();

    BlockInfo bi;
    bi.start = extent.first;
    bi.end = extent.second;
    bi.end_of_objects = extent.first;  // Empty; bump cursor will advance.
    bi.size_class = NUM_SIZE_CLASSES;
    bi.is_large = false;
    evac_block_index_ = materializeBlock(bi, {0, 0, true},
                                         bitmapBytesForBlock(bi));
    evac_alloc_ptr_ = bi.start;

    return bumpInBlock(evac_block_index_);
}

void OldGenSpace::installForwardingPointer(void* old_location, void* new_location) {
    Forward* fwd = reinterpret_cast<Forward*>(old_location);
    fwd->header.tag = Tag_Forward;
    fwd->header.forward_ptr = encodeForwardPtr(new_location, g_heap_base);
}

void* OldGenSpace::getForwardingAddress(void* obj) const {
    Header* hdr = reinterpret_cast<Header*>(obj);
    if (hdr->tag == Tag_Forward) {
        Forward* fwd = reinterpret_cast<Forward*>(obj);
        return decodeForwardPtr(fwd->header.forward_ptr, g_heap_base);
    }
    return nullptr;
}

void OldGenSpace::prepareReferenceFixup() {
    fixup_buffer_index_ = 0;
    fixup_cursor_ = nullptr;
}

void OldGenSpace::fixReferencesSlice(size_t work_budget) {
    size_t work_done = 0;

    while (work_done < work_budget &&
           fixup_buffer_index_ < blocks_.size()) {

        // fixup_buffer_index_ is an order POSITION; the set holds ids.
        const BlockId fix_id = blocks_.idAt(fixup_buffer_index_);
        if (isInEvacuationSet(fix_id)) {
            fixup_buffer_index_++;
            fixup_cursor_ = nullptr;
            continue;
        }

        BlockInfo& block = blocks_.info(fix_id);

        if (fixup_cursor_ == nullptr) {
            fixup_cursor_ = block.start;
        }

        char* end = block.end_of_objects;

        while (fixup_cursor_ < end && work_done < work_budget) {
            if (config_->old_gen_bitmap_alloc && !block.is_large &&
                block.size_class < num_size_classes_ &&
                !isMarkedInBlock(fix_id, fixup_cursor_)) {
                // threaded-gc-02: free cell of a uniform block (no header).
                fixup_cursor_ += classToSize(block.size_class);
                continue;
            }
            Header* hdr = reinterpret_cast<Header*>(fixup_cursor_);
            size_t step = walkStep(block, getObjectSize(fixup_cursor_));

            // Skip free cells and forwarding pointers.
            if (hdr->tag != Tag_Forward && hdr->tag != Tag_Free) {
                fixPointersInObject(fixup_cursor_);
            }

            fixup_cursor_ += step;
            work_done += step;
        }

        if (fixup_cursor_ >= end) {
            fixup_buffer_index_++;
            fixup_cursor_ = nullptr;
        }
    }

    if (fixup_buffer_index_ >= blocks_.size()) {
        freeEvacuatedBuffers();
        compact_phase_ = CompactionPhase::Idle;
        evac_block_index_ = NO_BLOCK_ID;
        evac_alloc_ptr_ = nullptr;
    }
}

void OldGenSpace::fixPointersInObject(void* obj) {
    Header* hdr = getHeader(obj);

    switch (hdr->tag) {
        case Tag_Tuple2: {
            Tuple2* t = static_cast<Tuple2*>(obj);
            fixUnboxable(t->a, tupleFieldKind(hdr->unboxed, 0) == 0);
            fixUnboxable(t->b, tupleFieldKind(hdr->unboxed, 1) == 0);
            break;
        }
        case Tag_Tuple3: {
            Tuple3* t = static_cast<Tuple3*>(obj);
            fixUnboxable(t->a, tupleFieldKind(hdr->unboxed, 0) == 0);
            fixUnboxable(t->b, tupleFieldKind(hdr->unboxed, 1) == 0);
            fixUnboxable(t->c, tupleFieldKind(hdr->unboxed, 2) == 0);
            break;
        }
        case Tag_Cons: {
            Cons* c = static_cast<Cons*>(obj);
            fixUnboxable(c->head, tupleFieldKind(hdr->unboxed, 0) == 0);
            fixHPointer(c->tail);
            break;
        }
        case Tag_ConsChunk: {
            ConsChunk* cv = static_cast<ConsChunk*>(obj);
            fixHPointer(cv->backing);
            fixHPointer(cv->next);
            break;
        }
        case Tag_ListBacking: {
            if ((hdr->unboxed & 0x3) == 0) {
                ListBacking* lb = static_cast<ListBacking*>(obj);
                for (u32 i = lb->hd; i < hdr->size; i++) {
                    fixUnboxable(lb->elems[i], true);
                }
            }
            break;
        }
        case Tag_Custom: {
            Custom* c = static_cast<Custom*>(obj);
            for (u32 i = 0; i < hdr->size && i < 24; i++) {
                fixUnboxable(c->values[i], fieldKind(c->unboxed, i) == 0);
            }
            break;
        }
        case Tag_Record: {
            Record* r = static_cast<Record*>(obj);
            for (u32 i = 0; i < hdr->size && i < 32; i++) {
                fixUnboxable(r->values[i], fieldKind(r->unboxed, i) == 0);
            }
            break;
        }
        case Tag_DynRecord: {
            DynRecord* dr = static_cast<DynRecord*>(obj);
            fixHPointer(dr->fieldgroup);
            for (u32 i = 0; i < hdr->size; i++) {
                fixHPointer(dr->values[i]);
            }
            break;
        }
        case Tag_Closure: {
            // Bounds on n_values, matching the nursery scan and the marking
            // pass above; see the comment there. A fix pass MUST cover
            // exactly the slots mark traced, no more and no less.
            Closure* cl = static_cast<Closure*>(obj);
            for (u32 i = 0; i < cl->n_values; i++) {
                fixUnboxable(cl->values[i], fieldKind(cl->unboxed, i) == 0);
            }
            break;
        }
        case Tag_Process: {
            Process* p = static_cast<Process*>(obj);
            fixHPointer(p->root);
            fixHPointer(p->stack);
            fixHPointer(p->mailbox);
            break;
        }
        case Tag_Task: {
            Task* t = static_cast<Task*>(obj);
            if ((t->header.unboxed & 0x3) == 0) {
                fixHPointer(t->value.p);
            }
            fixHPointer(t->callback);
            fixHPointer(t->kill);
            fixHPointer(t->task);
            break;
        }
        case Tag_Array: {
            ElmArray* arr = static_cast<ElmArray*>(obj);
            bool is_boxed = (arr->header.unboxed & 0x3) == 0;
            for (u32 i = 0; i < arr->length; i++) {
                fixUnboxable(arr->elements[i], is_boxed);
            }
            break;
        }
        case Tag_StringSlice: {
            ElmStringSlice* slc = static_cast<ElmStringSlice*>(obj);
            fixHPointer(slc->base);
            break;
        }
        case Tag_StringUtf8View: {
            ElmStringUtf8View* v = static_cast<ElmStringUtf8View*>(obj);
            fixHPointer(v->base);
            break;
        }
        case Tag_ByteBufferSlice: {
            ElmByteBufferSlice* slc = static_cast<ElmByteBufferSlice*>(obj);
            fixHPointer(slc->base);
            break;
        }
        case Tag_StringRope: {
            ElmStringRope* r = static_cast<ElmStringRope*>(obj);
            fixHPointer(r->left);
            fixHPointer(r->right);
            break;
        }
        case Tag_LargeStringHeader: {
            // Split-header bodies are pinned (header.pin = 1) and never
            // evacuated by the compactor, so their HPointer never moves.
            // fixHPointer is a no-op for non-forwarded targets, so this
            // case is here purely for tag coverage (HEAP_004).
            LargeStringHeader* h = static_cast<LargeStringHeader*>(obj);
            fixHPointer(h->body);
            break;
        }
        case Tag_LargeByteHeader: {
            LargeByteHeader* h = static_cast<LargeByteHeader*>(obj);
            fixHPointer(h->body);
            break;
        }
        default:
            // Tag_Int, Tag_Float, Tag_Char, Tag_String, Tag_FieldGroup,
            // Tag_ByteBuffer, Tag_Free, Tag_Forward: nothing to fix.
            break;
    }
}

void OldGenSpace::fixHPointer(HPointer& ptr) {
    if (ptr.ptr_ind != 0) return;

    void* obj = Allocator::fromPointerRaw(ptr);
    if (obj == nullptr) return;

    void* fwd = getForwardingAddress(obj);
    if (fwd != nullptr) {
        ptr = Allocator::toPointerRaw(fwd);
    }
}

void OldGenSpace::fixUnboxable(Unboxable& val, bool is_boxed) {
    if (is_boxed) {
        fixHPointer(val.p);
    }
}

bool OldGenSpace::isInEvacuationSet(BlockId buffer_index) const {
    return std::find(evacuation_set_.begin(), evacuation_set_.end(),
                     buffer_index) != evacuation_set_.end();
}

/**
 * Frees all evacuated blocks after compaction completes.
 *
 * Each evacuated block is returned to the bag (`unassigned_blocks_`) so the
 * BBoP allocator can re-slice it for any size class. Free-list entries that
 * point into the now-evacuated pages are dropped first to keep the lists
 * consistent.
 */
void OldGenSpace::freeEvacuatedBuffers() {
    // Collect evacuated block extents, then drop free-list entries that point
    // into them (a coalesced free cell from a prior sweep may live there).
    std::vector<std::pair<char*, char*>> evacuated_extents;
    evacuated_extents.reserve(evacuation_set_.size());
    for (BlockId idx : evacuation_set_) {
        if (blocks_.isLive(idx)) {
            evacuated_extents.emplace_back(blocks_.info(idx).start,
                                           blocks_.info(idx).end);
        }
    }

    auto inEvacuated = [&](char* p) -> bool {
        for (const auto& e : evacuated_extents) {
            if (p >= e.first && p < e.second) return true;
        }
        return false;
    };

    for (size_t cls = 0; cls < NUM_SIZE_CLASSES; ++cls) {
        FreeCell* head = free_lists_[cls];
        FreeCell* new_head = nullptr;
        FreeCell** tail_link = &new_head;
        while (head != nullptr) {
            FreeCell* next = head->next_in_class;
            if (!inEvacuated(reinterpret_cast<char*>(head))) {
                *tail_link = head;
                tail_link = &head->next_in_class;
            }
            head = next;
        }
        *tail_link = nullptr;
        free_lists_[cls] = new_head;
    }
    // Back-links of the surviving cells may name cells the filter pass just
    // dropped. They are rebuilt after the erase loop below, together with the
    // per-block threads.

    // Push evacuated extents into the bag for reuse.
    for (const auto& e : evacuated_extents) {
        unassigned_blocks_.emplace_back(e.first, e.second);
    }

    // Remove the evacuated blocks with vector::erase semantics on the ORDER
    // (later positions shift left; relative order preserved). The result is
    // independent of processing order. threaded-gc-01: clear each block's
    // page-index slots FIRST — there is no longer a rebuild afterwards
    // (HEAP_049) — and retire its mark slot; ids of the surviving blocks do
    // not change, so evac_block_index_ only needs clearing if it was erased.
    for (BlockId idx : evacuation_set_) {
        if (!blocks_.isLive(idx)) continue;
        if (config_->old_gen_bitmap_alloc) detachFromAllocation(idx);
        clearPageIndexForBlock(idx);
        mark_.retire(idx);
        blocks_.eraseOrdered(idx);
        if (evac_block_index_ == idx) {
            evac_block_index_ = NO_BLOCK_ID;
            evac_alloc_ptr_ = nullptr;
        }
    }

    evacuation_set_.clear();
    // The erase above shrinks the order under the fixup cursor, which the
    // caller (fixReferencesSlice) left at the old block count; it is dead from
    // here (the caller sets compact_phase_ = Idle next, and
    // prepareReferenceFixup resets it for the next cycle). Reset it so the
    // HEAP_048 cursor-range check below does not read a dead position.
    // (Unreachable in tests before threaded-gc-02: a major always left the
    // sweep pending, and scheduleCompaction bails while sweeping.)
    fixup_buffer_index_ = 0;
    fixup_cursor_ = nullptr;

    // Rebuild Tier-M per-block threads + prev-in-class back-links from
    // the post-erase blocks_ layout. Cells in surviving blocks kept their
    // class-list chain via the filter pass earlier, but their back-links
    // may name cells the filter dropped, and per-block thread heads may
    // also be stale. Clear all heads and walk each class list once, re-threading
    // and re-encoding back-links from scratch. O(total free cells), runs
    // only on compaction completion.
    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        blocks_.info(blocks_.idAt(pos)).free_cells_in_block = FREE_CELLS_EMPTY;
    }
    for (size_t cls = 0; cls < NUM_SIZE_CLASSES; ++cls) {
        FreeCell* prev_kept = nullptr;
        for (FreeCell* c = free_lists_[cls]; c != nullptr;
             c = c->next_in_class) {
            if (!isTierM(c)) { prev_kept = c; continue; }
            FreeCellMid* m = asTierM(c);
            // Rebuild class-list back-link (HEAP_052: an address, so no
            // block-index lookup is needed).
            if (prev_kept == nullptr) {
                setPrevHead(m);
            } else {
                setPrev(m, prev_kept);
            }
            // Re-thread onto own block.
            const BlockId blk_idx = blockIdFor(c);
            if (blk_idx.valid()) {
                blockThreadPushHead(blocks_.info(blk_idx), c);
            } else {
                m->next_in_block = FREE_CELLS_EMPTY;
                m->prev_in_block = FREE_CELLS_EMPTY;
            }
            prev_kept = c;
        }
    }

    computeFragmentationStats();
#if ECO_HEAP_VALIDATE
    validateOldGenMetadata("freeEvacuatedBuffers");
#endif
}

// ---------------------------------------------------------------------------
// Split-header body tracking (HEAP_026).
// ---------------------------------------------------------------------------

void* OldGenSpace::allocateTrackedCell(size_t total_size, size_t& cell_size,
                                       bool& is_large) {
    void* body = allocate(total_size);
    if (!body) return nullptr;
    GC_STATS_OLDGEN_DIRECT_RECORD_ALLOC(alloc_stats_, total_size);

    // Decide whether the cell landed in a dedicated is_large block. The
    // BBoP allocator places sizes >= alloc_buffer_size into is_large blocks.
    is_large = (total_size >= config_->alloc_buffer_size);

    // Cell footprint:
    //   - For is_large: the cell owns the entire block (page-aligned, possibly
    //     larger than total_size). cell_size = block totalBytes.
    //   - For size-class cells: the allocator rounded our request up to the
    //     block's size-class slot. We MUST record the slot size, not the
    //     requested size, because pushSpanOnFreeLists uses cell_size to
    //     re-emit free cells of exactly classToSize(cls). A request of
    //     2056 in a 2048 slot, freed via pushSpanOnFreeLists with
    //     span_bytes=2056 and cellSize=2048, would push one 2048 cell and
    //     orphan an 8-byte Tag_Free placeholder past the slot boundary —
    //     which lands in the next cell's header and corrupts the heap.
    cell_size = total_size;
    if (contains(body)) {
        const BlockId blk_idx = blockIdFor(body);
        if (blk_idx.valid()) {
            const BlockInfo& blk = blocks_.info(blk_idx);
            if (blk.is_large) {
                cell_size = blk.totalBytes();
            } else if (blk.size_class < NUM_SIZE_CLASSES) {
                cell_size = classToSize(blk.size_class);
            }
        }
    }
    return body;
}

void* OldGenSpace::allocateLargeBody(size_t total_size, size_t logical_size,
                                     Tag body_tag, bool initial_color) {
    assert(body_tag == Tag_String || body_tag == Tag_ByteBuffer);
    total_size = (total_size + 7) & ~static_cast<size_t>(7);

    size_t cell_size = 0;
    bool body_is_large = false;
    void* body = allocateTrackedCell(total_size, cell_size, body_is_large);
    if (!body) return nullptr;

    // The body is pointer-free; pinning keeps `body_base` stable for the
    // entire lifetime so large_body_index_'s key remains valid. allocate()
    // already zero-initialised the header and set color appropriately for
    // the current GC phase; we only need to set tag/pin and the size.
    //
    // `header.size` is the LOGICAL content length (chars for Tag_String,
    // bytes for Tag_ByteBuffer), not derived from `total_size`. The caller's
    // 8-byte alignment of `total_size` would otherwise round the apparent
    // length up and expose uninitialised padding bytes as content — see
    // Heap.hpp:261-263 for the contract that the body's `header.size`
    // matches the owning split-header's logical length.
    Header* hdr = static_cast<Header*>(body);
    hdr->tag = body_tag;
    hdr->pin = 1;
    hdr->size = static_cast<u32>(logical_size);

    registerLargeBody(body, cell_size, body_is_large, initial_color);
    return body;
}

void* OldGenSpace::allocateYoungLarge(size_t size, Tag tag, bool initial_color) {
    size = (size + 7) & ~static_cast<size_t>(7);
    size_t cell_size = 0;
    bool is_large = false;
    void* obj = allocateTrackedCell(size, cell_size, is_large);
    if (!obj) return nullptr;

    // allocate() zeroed the header and chose its color for the GC phase;
    // keep that color, write the tag's header, pin it (never moved: HEAP_062).
    Header* hdr = getHeader(obj);
    const u32 saved_color = hdr->color;
    initHeaderForTag(hdr, tag, size);
    hdr->color = saved_color;
    hdr->pin = 1;
    hdr->age = 0;

    registerLargeBody(obj, cell_size, is_large, initial_color, /*kind=*/1);
    char* lo = static_cast<char*>(obj);
    char* hi = lo + size;
    if (ylo_count_ == 0) {
        ylo_lo_ = lo;
        ylo_hi_ = hi;
    } else {
        if (lo < ylo_lo_) ylo_lo_ = lo;
        if (hi > ylo_hi_) ylo_hi_ = hi;
    }
    ++ylo_count_;
    return obj;
}

// TLA-REGION(OGS.promoteYoungLarge) begin
void OldGenSpace::promoteYoungLarge(void* obj) {
    auto it = large_body_index_.find(obj);
    if (it == large_body_index_.end()) return;
    const LargeBodyId id = it->second;
    assert(id < large_bodies_.size() && large_bodies_[id].kind == 1);
    for (size_t k = 0; k < nursery_owned_bodies_.size(); ++k) {
        if (nursery_owned_bodies_[k] == id) {
            nursery_owned_bodies_[k] = nursery_owned_bodies_.back();
            nursery_owned_bodies_.pop_back();
            break;
        }
    }
    large_body_index_.erase(it);
    large_bodies_[id].body_base = nullptr;
    large_bodies_[id].kind = 0;
    free_large_body_ids_.push_back(id);
    // An ordinary old object from here on (as a promoted copy: age 0). The
    // bounding box stays conservative until the minor-end recompute.
    // CR-019: a sweep slice under promo_mu_ may read this header word
    // (relaxed atomic whole-word store, HEAP_062).
    Header hv = loadHeaderRelaxed(obj);
    hv.age = 0;
    storeHeaderRelaxed(obj, hv);
#if ENABLE_GC_STATS
    alloc_stats_.lp.ylos_promoted_in_place++;
#endif
}
// TLA-REGION(OGS.promoteYoungLarge) end

void OldGenSpace::recomputeYoungLargeBounds() {
    char* lo = nullptr;
    char* hi = nullptr;
    size_t n = 0;
    forEachYoungLarge([&](void* obj, LargeBodyMeta&) {
        char* a = static_cast<char*>(obj);
        char* b = a + getObjectSize(obj);
        if (n == 0 || a < lo) lo = a;
        if (n == 0 || b > hi) hi = b;
        ++n;
    });
    ylo_lo_ = lo;
    ylo_hi_ = hi;
    ylo_count_ = n;
}

size_t OldGenSpace::retireIndexRange(char* lo, char* hi) {
    size_t n = 0;
    for (auto it = large_body_index_.begin(); it != large_body_index_.end();) {
        char* b = static_cast<char*>(it->first);
        if (b >= lo && b < hi) {
            retireIndexEntry(it->second);
            it = large_body_index_.erase(it);
            ++n;
        } else {
            ++it;
        }
    }
    return n;
}

void OldGenSpace::retireIndexEntry(LargeBodyId id) {
    if (id >= large_bodies_.size()) return;
#if ENABLE_GC_STATS
    if (large_bodies_[id].kind == 1 && large_bodies_[id].body_base != nullptr)
        alloc_stats_.lp.ylos_retired_major++;
#endif
    large_bodies_[id].body_base = nullptr;
}

// TLA-REGION(OGS.registerLargeBody) begin
OldGenSpace::LargeBodyId OldGenSpace::registerLargeBody(
        void* body, size_t cell_size, bool is_large, bool minor_color, uint8_t kind) {
    LargeBodyId id;
    if (!free_large_body_ids_.empty()) {
        id = free_large_body_ids_.back();
        free_large_body_ids_.pop_back();
        large_bodies_[id] = LargeBodyMeta{body, cell_size, is_large, minor_color, kind};
    } else {
        id = static_cast<LargeBodyId>(large_bodies_.size());
        large_bodies_.push_back(LargeBodyMeta{body, cell_size, is_large, minor_color, kind});
    }
    large_body_index_[body] = id;
    nursery_owned_bodies_.push_back(id);
    return id;
}
// TLA-REGION(OGS.registerLargeBody) end

// TLA-REGION(OGS.markLargeBodySeen) begin
void OldGenSpace::markLargeBodySeen(HPointer body_hp, bool minor_color) {
    if (body_hp.ptr_ind != 0) return;
    void* body = Allocator::fromPointerRaw(body_hp);
    if (!body) return;
    auto it = large_body_index_.find(body);
    if (it == large_body_index_.end()) return;
    LargeBodyId id = it->second;
    if (id >= large_bodies_.size()) return;
    LargeBodyMeta& m = large_bodies_[id];
    // HEAP_072 (amended, CR-037): lb_bodies names BODIES by address; a STW major may
    // free the body and a YLOS (kind 1) may take the cell. Never colour a YLOS here:
    // its first reach would return "already reached" (reachYoungLargeR), unscanned.
    if (m.kind != 0 || m.body_base != body) return;
    m.color = minor_color;
}
// TLA-REGION(OGS.markLargeBodySeen) end

void OldGenSpace::promoteLargeHeader(HPointer body_hp) {
    if (body_hp.ptr_ind != 0) return;
    void* body = Allocator::fromPointerRaw(body_hp);
    if (!body) return;
    auto it = large_body_index_.find(body);
    if (it == large_body_index_.end()) return;
    LargeBodyId id = it->second;
    // Swap-remove from nursery_owned_bodies_.
    for (size_t k = 0; k < nursery_owned_bodies_.size(); ++k) {
        if (nursery_owned_bodies_[k] == id) {
            nursery_owned_bodies_[k] = nursery_owned_bodies_.back();
            nursery_owned_bodies_.pop_back();
            break;
        }
    }
    // Fully untrack: the body is now governed by standard major-GC mark/sweep
    // through the promoted header. Reclaiming the meta slot keeps the index
    // map small and lets a future allocateLargeBody at the same address
    // register cleanly.
    large_body_index_.erase(it);
    if (id < large_bodies_.size()) {
        large_bodies_[id].body_base = nullptr;
        free_large_body_ids_.push_back(id);
    }
}

// TLA-REGION(OGS.sweepNurseryLargeBodies) begin
size_t OldGenSpace::sweepNurseryLargeBodies(bool minor_color) {
    // W0 item 50: the common case is an empty list — leave before the asserts
    // and the compaction-phase branch rather than after them.
    if (nursery_owned_bodies_.empty()) {
        if (ylo_count_ != 0) recomputeYoungLargeBounds();   // all promoted
        return 0;
    }

    // Defensive: reject during compaction phases where blocks_ is mid-shuffle.
    assert(compact_phase_ != CompactionPhase::Evacuating &&
           compact_phase_ != CompactionPhase::FixingRefs &&
           "sweepNurseryLargeBodies must not run during compaction");

    // Defer ONLY when compaction is in flight: compaction reshuffles blocks_
    // and BufferMetadata, so freeing a body cell mid-compaction can race with
    // evacuation. For mid-major-GC mark/sweep, freeLargeBodyCell installs the
    // on-free-list sentinel (Header.age & 0b01 = 1) on the resulting Tag_Free
    // cell, which lazy sweep honors as a hard run boundary — no coalescing
    // across, no rewriting of the header. That makes immediate reclaim safe
    // during Marking and Sweeping phases, returning the freed bytes to the
    // size-class free lists right away instead of waiting for the next major.
    //
    // On the deferred (compaction) path, walk the list once to estimate how
    // many bytes would have been freed if we'd been allowed to run, and
    // attribute those bytes to `large_body_deferred_to_major_bytes` so the
    // printed stats can quantify how much work compaction is pushing off
    // onto the next minor.
    if (compact_phase_ != CompactionPhase::Idle) {
#if ENABLE_GC_STATS
        alloc_stats_.large_body_minor_sweep_skips++;
        for (LargeBodyId id : nursery_owned_bodies_) {
            if (id >= large_bodies_.size()) continue;
            const LargeBodyMeta& m = large_bodies_[id];
            if (m.body_base == nullptr) continue;
            if (m.color == minor_color) continue;
            alloc_stats_.large_body_deferred_to_major_bytes += m.cell_size;
        }
#endif
        return 0;
    }

#if ENABLE_GC_STATS
    alloc_stats_.large_body_minor_sweep_runs++;
#endif

    size_t freed = 0;
    size_t k = 0;
    while (k < nursery_owned_bodies_.size()) {
        LargeBodyId id = nursery_owned_bodies_[k];
        if (id >= large_bodies_.size()) {
            nursery_owned_bodies_[k] = nursery_owned_bodies_.back();
            nursery_owned_bodies_.pop_back();
            continue;
        }
        LargeBodyMeta& m = large_bodies_[id];
        // Stale slot: body_base was already cleared (e.g. by an earlier
        // promoteLargeHeader) but the id wasn't drained from
        // nursery_owned_bodies_ because the swap-remove search bailed at the
        // first match. Drop it without re-pushing onto free_large_body_ids_
        // (it's already there).
        if (m.body_base == nullptr) {
            nursery_owned_bodies_[k] = nursery_owned_bodies_.back();
            nursery_owned_bodies_.pop_back();
            continue;
        }
        if (m.color == minor_color) {
            ++k;
            continue;
        }
        // Body's header in nursery did not survive this minor GC (or, for a
        // YLOS object, the object itself was not reached); free.
#if ENABLE_GC_STATS
        const size_t freed_bytes = m.cell_size;
        if (m.kind == 1) alloc_stats_.lp.ylos_freed_minor++;
#endif
        if (__builtin_expect(cycle_state_ != CycleState::Idle, 0)) {
            // threaded-gc-05a P§3.7 (M5): the cell may be marked or greyed
            // under the running cycle; unlink it now, free it at the handoff.
            deferred_frees_.push_back(m);
            large_body_index_.erase(m.body_base);
            m.body_base = nullptr;
#if ENABLE_GC_STATS
            alloc_stats_.im.deferred_frees++;
            alloc_stats_.im.deferred_free_bytes += m.cell_size;
#endif
        } else {
            freeLargeBodyCell(m);
        }
        free_large_body_ids_.push_back(id);
        nursery_owned_bodies_[k] = nursery_owned_bodies_.back();
        nursery_owned_bodies_.pop_back();
        ++freed;
#if ENABLE_GC_STATS
        alloc_stats_.large_body_minor_freed_bytes += freed_bytes;
#endif
    }

    // threaded-gc-04b: the YLOS bounding box shrinks here, after this
    // minor's promotions in place and frees.
    recomputeYoungLargeBounds();
    return freed;
}
// TLA-REGION(OGS.sweepNurseryLargeBodies) end

// TLA-REGION(OGS.freeLargeBodyCell) begin
void OldGenSpace::freeLargeBodyCell(LargeBodyMeta& m) {
    if (m.body_base == nullptr) return;
    // IM5 (HEAP_063): nothing that existed at t0 is freed under a cycle.
    assert(!cycleActive() && "freeLargeBodyCell during an incremental mark cycle");
    // Authoritative ownership transition for split-header bodies (HEAP_026,
    // Resolved Decisions §3): erasing here is what retires the LargeBodyId.
    // Major sweep's defensive `large_body_index_.erase` calls (in lazySweep
    // and the is_large branch) are idempotent guards — they must NOT push
    // onto free_large_body_ids_; only this path recycles ids.
    large_body_index_.erase(m.body_base);

    if (m.is_large) {
        // Body owns its block; route to free_large_blocks_ and reset metadata.
        if (!contains(m.body_base)) { m.body_base = nullptr; return; }
        const BlockId idx = blockIdFor(m.body_base);
        if (!idx.valid() || !blocks_.info(idx).is_large) {
            m.body_base = nullptr;
            return;
        }
        // Avoid double-free: only mark as free if not already on free_large_blocks_.
        bool already_free = false;
        for (BlockId fb : free_large_blocks_) {
            if (fb == idx) { already_free = true; break; }
        }
        if (!already_free) {
            // Reset live attribution before declaring the block free.
            {
                BufferMetadata& bm = blocks_.meta(idx);
                // HEAP_051: the former code's `= 0` also discarded any marker
                // attribution; drop the accumulator entry too (mid-mark is
                // reachable only from hand-driven unit tests).
                if (marking_active) (void)markLiveTake(idx);
                bm.live_bytes = 0;
                bm.garbage_bytes = blocks_.info(idx).totalBytes();
                bm.fully_swept = true;
            }
            blocks_.largeMark(idx) = 0;
            // Reset the header on the body so any walker observes Tag_Free.
            // is_large blocks are parked in free_large_blocks_, not on a
            // size-class free list; lazy sweep doesn't walk inside them, so
            // age = 0 is correct here (the on-free-list sentinel only applies
            // to size-class free-list cells).
            Header* hdr = reinterpret_cast<Header*>(m.body_base);
            std::memset(hdr, 0, sizeof(Header));
            hdr->tag = Tag_Free;
            hdr->size = static_cast<u32>(blocks_.info(idx).totalBytes());
            hdr->color = static_cast<u32>(Color::White);
            hdr->age = 0;
            // allocated_bytes was incremented when allocateLargeBlock landed
            // the body. Decrement now so the next major-GC trigger calculation
            // doesn't double-count the released block.
            const size_t total = blocks_.info(idx).totalBytes();
            allocated_bytes = (allocated_bytes >= total)
                ? (allocated_bytes - total) : 0;
            if (frag_stats_.live_bytes >= total) {
                frag_stats_.live_bytes -= total;
            } else {
                frag_stats_.live_bytes = 0;
            }
            free_large_blocks_.push_back(idx);
        }
    } else {
        // Size-class or split-page cell: clear the mark bit first so the
        // next sweep cycle doesn't think this address is still live, then
        // overlay a Tag_Free cell and push it onto the free list.
        if (contains(m.body_base)) {
            const BlockId idx = blockIdFor(m.body_base);
            if (idx.valid() && !blocks_.info(idx).is_large &&
                config_->old_gen_bitmap_alloc) {
                // threaded-gc-02 (P§3.7, HEAP_027 reworded): no sentinels.
                assert(gc_phase_ != GCPhase::Marking);
                char* cell = static_cast<char*>(m.body_base);
                const bool uniform =
                    blocks_.info(idx).size_class < num_size_classes_;
                // "Unswept" means the sweep will still walk over THIS cell —
                // not merely that the block is unfinished: the cursor may
                // already have passed the cell inside the current block.
                const bool unswept_mixed = !uniform && sweepWillReach(idx, cell);
                bool count_garbage = true;
                if (uniform) {
                    freeUniformCell(idx, cell);           // bit clear + rewind/queue
                } else if (unswept_mixed) {
                    // The gap sweep will reclaim the cell as part of a gap and
                    // count its garbage in flushRun — only clear the bit.
                    testAndClearMarkBitInBlock(idx, cell);
                    count_garbage = false;
                } else {
                    testAndClearMarkBitInBlock(idx, cell);
#if ECO_HEAP_VALIDATE
                    PushOriginScope _origin("freeLargeBodyCell");
#endif
                    pushSpanOnFreeLists(free_lists_, cell, m.cell_size,
                                        &blocks_.info(idx), idx,
                                        /*age_sentinel=*/false);
                }
                BufferMetadata& bm = blocks_.meta(idx);
                if (bm.live_bytes >= m.cell_size) {
                    bm.live_bytes -= m.cell_size;
                } else {
                    bm.live_bytes = 0;
                }
                if (count_garbage) bm.garbage_bytes += m.cell_size;
                allocated_bytes = (allocated_bytes >= m.cell_size)
                    ? (allocated_bytes - m.cell_size) : 0;
                if (frag_stats_.live_bytes >= m.cell_size) {
                    frag_stats_.live_bytes -= m.cell_size;
                } else {
                    frag_stats_.live_bytes = 0;
                }
                frag_stats_.total_free_bytes += m.cell_size;
            } else if (idx.valid() && !blocks_.info(idx).is_large) {
                // Clear the mark bit (no-op if already zero).
                testAndClearMarkBitInBlock(idx, m.body_base);
                // The cell goes onto a size-class free list. If the in-progress
                // major-GC sweep might still walk past this address, mark the
                // cell as a sentinel so the lazy-sweep coalescer leaves it
                // alone. Cases:
                //   - Idle:     no sweep in progress; coalescable.
                //   - Marking:  sweep hasn't started yet but will walk every
                //               block; sentinel required.
                //   - Sweeping: sentinel required iff this block hasn't been
                //               fully swept yet (or the meta entry is
                //               missing — defensive).
                bool need_sentinel = false;
                switch (gc_phase_) {
                    case GCPhase::Idle:
                        need_sentinel = false;
                        break;
                    case GCPhase::Marking:
                        // UNREACHABLE today: gc_phase_ is never set to
                        // Marking (marking runs to completion inside the
                        // major pause). Kept for threaded-gc phase 5a, which
                        // reworks this function for concurrent marking.
                        need_sentinel = true;
                        break;
                    case GCPhase::Sweeping:
                        need_sentinel = !blocks_.meta(idx).fully_swept;
                        break;
                }
#if ECO_HEAP_VALIDATE
                PushOriginScope _origin("freeLargeBodyCell");
#endif
                if (need_sentinel) free_list_sentinel_count_++;
                pushSpanOnFreeLists(free_lists_,
                                    static_cast<char*>(m.body_base),
                                    m.cell_size,
                                    &blocks_.info(idx),
                                    idx,
                                    need_sentinel);
                {
                    BufferMetadata& bm = blocks_.meta(idx);
                    // HEAP_051: the clamped subtraction below does not commute
                    // with the marker's additions. Mid-mark it is reachable
                    // only from hand-driven unit tests (marking is STW), and
                    // folding this id's accumulator first keeps them exact.
                    if (marking_active) bm.live_bytes += markLiveTake(idx);
                    if (bm.live_bytes >= m.cell_size) {
                        bm.live_bytes -= m.cell_size;
                    } else {
                        bm.live_bytes = 0;
                    }
                    // Authoritative garbage_bytes accounting for this cell —
                    // sweep's run-coalescer skips sentinel cells (Step 6), so
                    // the bytes are recorded exactly once here.
                    bm.garbage_bytes += m.cell_size;
                }
                allocated_bytes = (allocated_bytes >= m.cell_size)
                    ? (allocated_bytes - m.cell_size) : 0;
                if (frag_stats_.live_bytes >= m.cell_size) {
                    frag_stats_.live_bytes -= m.cell_size;
                } else {
                    frag_stats_.live_bytes = 0;
                }
                if (frag_stats_.total_free_bytes + m.cell_size >=
                        frag_stats_.total_free_bytes) {
                    frag_stats_.total_free_bytes += m.cell_size;
                }
            }
        }
    }

    m.body_base = nullptr;
}
// TLA-REGION(OGS.freeLargeBodyCell) end

// ===========================================================================
// threaded-gc-01 metadata validators (ECO_HEAP_VALIDATE only).
// ===========================================================================
#if ECO_HEAP_VALIDATE
[[noreturn]] static void metaValidateFail(const char* where, const char* what) {
    std::fprintf(stderr, "[heap-validate] %s: %s\n", where, what);
    std::fflush(stderr);
    std::abort();
}

void OldGenSpace::validateFreeListBackLinks(const char* where) const {
    for (size_t cls = 0; cls < NUM_SIZE_CLASSES; ++cls) {
        const FreeCell* pred = nullptr;
        size_t depth = 0;
        for (FreeCell* c = free_lists_[cls]; c != nullptr;
             c = c->next_in_class, ++depth) {
            if (config_->old_gen_bitmap_alloc) {
                // V9 (HEAP_054 / HEAP_027 reworded): no list cell in a uniform
                // block (the cursor would double-allocate it), none in a mixed
                // block the sweep has not reached yet, and no sentinels.
                const BlockId cb = blockIdFor(c);
                if (cb.valid()) {
                    const BlockInfo& cbi = blocks_.info(cb);
                    if (!cbi.is_large && cbi.size_class < num_size_classes_) {
                        metaValidateFail(where, "V9: free-list cell inside a "
                                                "uniform block (bitmap mode)");
                    }
                    if (sweepWillReach(cb, reinterpret_cast<const char*>(c))) {
                        metaValidateFail(where, "V9: free-list cell ahead of the "
                                                "lazy sweep (bitmap mode)");
                    }
                }
                if (isFreeCellSentinel(&c->header)) {
                    metaValidateFail(where, "V9: sentinel free cell in bitmap mode");
                }
            }
            if (isTierM(c)) {
                const FreeCell* got = getPrev(asTierM(c));
                if (got != pred) {
                    std::fprintf(stderr,
                        "[heap-validate] %s: HEAP_052 back-link mismatch on "
                        "free_lists[%zu] depth %zu: cell %p (size %u) "
                        "decodes prev=%p, actual predecessor=%p\n",
                        where, cls, depth, (void*)c,
                        (unsigned)c->header.size, (void*)got, (void*)pred);
                    metaValidateFail(where, "free-list back-link");
                }
            }
            pred = c;
        }
    }
}

void OldGenSpace::validateOldGenMetadata(const char* where) const {
    // V7 (HEAP_048): no metadata storage has moved since reserveMetadata().
    for (int k = 0; k < BlockTable::kStorageArrays; ++k) {
        if (blocks_.storageBase(k) != storage_bases_[k]) {
            metaValidateFail(where, "HEAP_048: BlockTable storage moved");
        }
    }
    if (mark_.storageBase() != storage_bases_[BlockTable::kStorageArrays] ||
        page_index_.data() != storage_bases_[BlockTable::kStorageArrays + 1] ||
        w0().live.storageBase() !=
            storage_bases_[BlockTable::kStorageArrays + 2]) {
        metaValidateFail(where, "HEAP_048: side-table storage moved");
    }

    // V1 (HEAP_048): order <-> pos_of_ is a bijection over live ids; every
    // id below the high-water mark is live xor on the free stack, once.
    const uint32_t hw = blocks_.highWater();
    if (blocks_.size() + blocks_.freeCount() != hw) {
        metaValidateFail(where, "HEAP_048: size + free != high-water");
    }
    std::vector<uint8_t> seen(hw, 0);
    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        const BlockId id = blocks_.idAt(pos);
        if (id.v >= hw || !blocks_.isLive(id) || blocks_.posOf(id) != pos ||
            seen[id.v]) {
            std::fprintf(stderr, "[heap-validate] %s: order pos %zu -> id %u "
                "(live=%d, posOf=%zu)\n", where, pos, id.v,
                id.v < hw ? (int)blocks_.isLive(id) : -1,
                id.v < hw ? blocks_.posOf(id) : (size_t)-1);
            metaValidateFail(where, "HEAP_048: order/pos_of_ bijection broken");
        }
        seen[id.v] = 1;
    }
    for (size_t k = 0; k < blocks_.freeCount(); ++k) {
        const BlockId id = blocks_.freeIdAt(k);
        if (id.v >= hw || blocks_.isLive(id) || seen[id.v]) {
            metaValidateFail(where, "HEAP_048: free stack holds a live or "
                                    "duplicate id");
        }
        seen[id.v] = 2;
        if (mark_.len(id) != 0) {
            metaValidateFail(where, "HEAP_050: free id with non-empty mark slot");
        }
    }

    // V2 (HEAP_049): every live block's page slots name it; every committed
    // slot's owners are live blocks whose extent intersects the slot.
    const size_t page = config_->alloc_buffer_size;
    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        const BlockId id = blocks_.idAt(pos);
        const BlockInfo& b = blocks_.info(id);
        const size_t first = firstPageIndex(b), last = lastPageIndex(b);
        for (size_t sl = first; sl <= last; ++sl) {
            if (sl >= page_index_.committed() ||
                (decodeOwner(loadOwnerRelaxed(page_index_[sl].primary)) != id &&
                 decodeOwner(loadOwnerRelaxed(page_index_[sl].secondary)) != id)) {
                std::fprintf(stderr, "[heap-validate] %s: block id %u "
                    "[%p,%p) missing from page slot %zu\n", where, id.v,
                    (void*)b.start, (void*)b.end, sl);
                metaValidateFail(where, "HEAP_049: page index misses a block");
            }
        }
    }
    for (size_t sl = 0; sl < page_index_.committed(); ++sl) {
        const char* lo = index_base_ + sl * page;
        const char* hi = lo + page;
        for (uint32_t enc : {loadOwnerRelaxed(page_index_[sl].primary),
                             loadOwnerRelaxed(page_index_[sl].secondary)}) {
            if (enc == 0) continue;
            const BlockId id = decodeOwner(enc);
            if (!blocks_.isLive(id)) {
                std::fprintf(stderr, "[heap-validate] %s: page slot %zu names "
                    "released id %u\n", where, sl, id.v);
                metaValidateFail(where, "HEAP_049: stale page-index owner");
            }
            const BlockInfo& b = blocks_.info(id);
            if (!(b.start < hi && b.end > lo)) {
                metaValidateFail(where, "HEAP_049: owner does not intersect slot");
            }
        }
    }

    // V3 (HEAP_048): stored block references (the invariant the deleted
    // fixupIndicesAfterBlockMove maintained) name live blocks; the two
    // position cursors are in range.
    for (BlockId id : free_large_blocks_) {
        if (!blocks_.isLive(id) || !blocks_.info(id).is_large) {
            metaValidateFail(where, "HEAP_048: free_large_blocks_ entry is "
                                    "not a live is_large block");
        }
    }
    if (evac_block_index_.valid() && !blocks_.isLive(evac_block_index_)) {
        metaValidateFail(where, "HEAP_048: evac_block_index_ not live");
    }
    for (BlockId id : evacuation_set_) {
        if (!blocks_.isLive(id)) {
            metaValidateFail(where, "HEAP_048: evacuation_set_ entry not live");
        }
    }
    // The cursors are only meaningful while their phase runs: a completed
    // sweep leaves sweep_buffer_index_ at the old block count, and a later
    // shrink may drop the count below it (reset by transitionToSweeping).
    if ((gc_phase_ == GCPhase::Sweeping &&
         sweep_buffer_index_ > blocks_.size()) ||
        (compact_phase_ == CompactionPhase::FixingRefs &&
         fixup_buffer_index_ > blocks_.size())) {
        metaValidateFail(where, "HEAP_048: position cursor out of range");
    }

    if (config_->old_gen_bitmap_alloc) {
        // V8 (HEAP_054): outside the mark window a uniform block's live_bytes
        // equals popcount(cell-start bits) x cell, and no bit is set off a
        // cell start or past the last cell.
        if (!marking_active) {
            for (size_t pos = 0; pos < blocks_.size(); ++pos) {
                const BlockId id = blocks_.idAt(pos);
                const BlockInfo& b = blocks_.info(id);
                if (b.is_large || b.size_class >= num_size_classes_) continue;
                // threaded-gc-07: a granted block's bits are the collector's
                // until the merge folds its live bytes in (HEAP_070).
                if (b.alloc_state == kAllocTenure) continue;
                const uint32_t m = static_cast<uint32_t>(classToSize(b.size_class) / 8);
                const uint32_t n = cellsIn(b);
                const uint8_t* bits = mark_.slot(id);
                const uint64_t pc = bitscan::popcountCellStarts(bits, m, n);
                const uint64_t pend = (cursor_[b.size_class].block == id)
                    ? cursor_[b.size_class].pending_live : 0;
                if (pc * classToSize(b.size_class) != blocks_.meta(id).live_bytes + pend) {
                    std::fprintf(stderr, "[heap-validate] %s: V8 block id %u class "
                        "%zu: popcount %llu x %zu != live_bytes %zu\n", where, id.v,
                        b.size_class, (unsigned long long)pc,
                        classToSize(b.size_class), blocks_.meta(id).live_bytes);
                    metaValidateFail(where, "V8: uniform live_bytes != popcount x cell");
                }
                const size_t nbits = static_cast<size_t>(mark_.len(id)) * 8;
                for (size_t bit = bitscan::nextSetBit(bits, 0, nbits); bit < nbits;
                     bit = bitscan::nextSetBit(bits, bit + 1, nbits)) {
                    if (bit % m != 0 || bit / m >= n) {
                        metaValidateFail(where, "V8: uniform bit off a cell start");
                    }
                }
            }
        }
        // V10 (HEAP_054): cursor / queue consistency.
        for (size_t cls = 0; cls < NUM_SIZE_CLASSES; ++cls) {
            const AllocCursor& c = cursor_[cls];
            if (c.block.valid()) {
                if (!blocks_.isLive(c.block) ||
                    blocks_.info(c.block).alloc_state != kAllocCurrent ||
                    blocks_.info(c.block).size_class != cls ||
                    blocks_.info(c.block).is_large) {
                    metaValidateFail(where, "V10: cursor names a non-Current block");
                }
            }
            for (size_t k = partial_head_[cls]; k < partial_[cls].size(); ++k) {
                const BlockId q = partial_[cls][k];
                if (!blocks_.isLive(q)) {
                    metaValidateFail(where, "V10: queue holds a released block");
                }
                const BlockInfo& qb = blocks_.info(q);
                if (qb.alloc_state == kAllocNone) {
                    metaValidateFail(where, "V10: queue holds a None block");
                }
            }
        }
        for (size_t pos = 0; pos < blocks_.size(); ++pos) {
            const BlockId id = blocks_.idAt(pos);
            const BlockInfo& b = blocks_.info(id);
            if (b.alloc_state == kAllocNone) continue;
            if (b.is_large || b.size_class >= num_size_classes_) {
                metaValidateFail(where, "V10: allocation state on a non-uniform block");
            }
            if (b.alloc_state == kAllocCurrent && cursor_[b.size_class].block != id) {
                metaValidateFail(where, "V10: Current block is not its class cursor");
            }
            if (b.alloc_state == kAllocQueued) {
                size_t hits = 0;
                const auto& q = partial_[b.size_class];
                for (size_t k = partial_head_[b.size_class]; k < q.size(); ++k) {
                    if (q[k] == id) ++hits;
                }
                if (hits != 1) {
                    metaValidateFail(where, "V10: Queued block not exactly once in its queue");
                }
            }
        }
    }

    // V6 (HEAP_052) (+ V9 in bitmap mode).
    validateFreeListBackLinks(where);
}

void OldGenSpace::validateEveryNthMinor() {
    if ((++validate_minor_count_ & 63) == 0) {
        validateOldGenMetadata("minorGC(every 64th)");
    }
}
#endif

} // namespace Elm
