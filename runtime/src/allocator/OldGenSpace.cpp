/**
 * OldGenSpace Implementation.
 *
 * Implements the old generation as a segregated-fits allocator backed by a
 * "Big Bag of Pages" (BBoP). See OldGenSpace.hpp for the full design.
 *
 * Single-threaded (one instance per thread).
 */

#include "OldGenSpace.hpp"
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
}

OldGenSpace::~OldGenSpace() {
    // Memory blocks are owned by the Allocator's mmap region, not us.
    // Release our metadata reservations (HEAP_048).
    unassigned_blocks_.clear();
    blocks_.releaseStorage();
    mark_.release();
    page_index_.release();
    mark_live_.release();
}

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
    if (!blocks_.reserve(g.max_blocks) || !mark_.reserve(g.max_blocks, g.stride) ||
        !page_index_.reserve(g.index_slots) || !mark_live_.reserve(g.max_blocks)) {
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
    storage_bases_[BlockTable::kStorageArrays + 2] = mark_live_.storageBase();
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
            region_base_ = region_base;
            region_end_ = region_base + initial_size;

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

void OldGenSpace::reset(const HeapConfig* new_config) {
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
    region_base_ = nullptr;
    region_end_ = nullptr;
    gc_phase_ = GCPhase::Idle;
    marking_active = false;
    current_epoch = 0;
    mark_stack.clear();
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

// ---------------------------------------------------------------------------
// Header initialization helper.
// ---------------------------------------------------------------------------
void OldGenSpace::initObjectHeader(void* obj) {
    initObjectHeaderWithSize(obj, 0);
}

// `cell_bytes` is the number of bytes occupied by this cell (size-class slot
// size for size-class blocks, the requested size for large blocks). When
// non-zero and the alloc happens mid-cycle, the cell's bytes are added to
// the owning block's `live_bytes` so it isn't reported as all-dead during
// the next finalize/reclaim/shrink. Mark-time `live_bytes` attribution only
// covers cells discovered by `markOneObject`; mid-cycle cells bypass mark.
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
    if (marking_active || gc_phase_ != GCPhase::Idle) {
        hdr->color = static_cast<u32>(Color::Black);
        if (contains(obj)) {
            const BlockId block_id = blockIdFor(obj);
            if (block_id.valid()) {
                setMarkBitInBlock(block_id, obj);
                if (cell_bytes > 0) {
                    // Attribute the cell's bytes so a block that contained
                    // only mid-cycle allocations isn't seen as all-dead by
                    // finalize/reclaim/shrink. Owner-side write (HEAP_051).
                    blocks_.meta(block_id).live_bytes += cell_bytes;
                }
            }
        }
    } else {
        hdr->color = static_cast<u32>(Color::White);
    }
}

// ---------------------------------------------------------------------------
// Page-index helpers (Step 1).
// ---------------------------------------------------------------------------

void OldGenSpace::commitPageIndexThrough(const char* end) {
    if (index_base_ == nullptr || end == nullptr || end <= index_base_) return;
    const size_t page_size = config_->alloc_buffer_size;
    const size_t slot = static_cast<size_t>(end - index_base_ - 1) / page_size;
    const size_t want = std::min(slot + 1, page_index_.capacity());
    page_index_.ensureCommitted(want);
}

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
    region_base_ = new_base;
    region_end_  = new_end;
    // threaded-gc-01 (HEAP_049): the page index is keyed from index_base_,
    // so a region-bounds change no longer rebuilds it. Committing through
    // the (possibly moved) end is a no-op unless the region grew.
    commitPageIndexThrough(region_end_);
}

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
        if (slot.primary == enc || slot.secondary == enc) {
            // Already recorded.
            continue;
        }
        if (slot.primary == 0) {
            slot.primary = enc;
        } else if (slot.secondary == 0) {
            slot.secondary = enc;
        } else {
#if ECO_HEAP_VALIDATE
            // HEAP_049: every block is >= alloc_buffer_size, so a slot can
            // intersect at most two blocks. A third owner means a stale
            // entry survived a release (or the size premise broke).
            std::fprintf(stderr,
                "[heap-validate] HEAP_049: page slot %zu already has two "
                "owners (ids %u, %u) when assigning id %u\n",
                p, slot.primary - 1, slot.secondary - 1, id.v);
            std::fflush(stderr);
            std::abort();
#endif
            // Keep the primary stable (the older owner — typically a large
            // block straddling many slots) and overwrite the secondary.
            // blockIdFor's contains-check still gates the returned id on
            // actual extent membership.
            slot.secondary = enc;
        }
    }
}

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
        if (slot.primary == enc) {
            slot.primary = slot.secondary;
            slot.secondary = 0;
        } else if (slot.secondary == enc) {
            slot.secondary = 0;
        }
    }
}

BlockId OldGenSpace::materializeBlock(const BlockInfo& bi,
                                      const BufferMetadata& m,
                                      size_t mark_bytes) {
    const BlockId id = blocks_.add(bi, m);
    mark_.assign(id, static_cast<uint32_t>(mark_bytes));
    mark_live_.commitThrough(id);
    assignPageIndexForBlock(id);
    return id;
}

// Defined further down (size-class fast path); used by the bitmap path.
static inline void padCellSlack(void* obj, size_t requested_size,
                                size_t cell_size);

// ---------------------------------------------------------------------------
// Bitmap allocation (threaded-gc-02, HEAP_054). Cursor / queue bookkeeping.
// ---------------------------------------------------------------------------

void OldGenSpace::resetAllocCursors() {
    syncCursorLiveBytes();
    for (size_t c = 0; c < NUM_SIZE_CLASSES; ++c) {
        cursor_[c] = AllocCursor{};
        partial_[c].clear();
        partial_head_[c] = 0;
    }
    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        blocks_.info(blocks_.idAt(pos)).alloc_state = kAllocNone;
    }
}

void OldGenSpace::detachFromAllocation(BlockId id) {
    if (!id.valid()) return;
    BlockInfo& b = blocks_.info(id);
    if (b.alloc_state == kAllocNone) return;
    const size_t cls = b.size_class;
    assert(cls < NUM_SIZE_CLASSES && "detach: allocation state on a non-uniform block");
    if (b.alloc_state == kAllocCurrent) {
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

void* OldGenSpace::finalizeBitmapCell(AllocCursor& c, uint32_t k,
                                      size_t requested_size) {
    const size_t cell = c.cell_bytes;
    char* p = c.base + static_cast<size_t>(k) * cell;
    // P§3.1: the bit is the allocation record — set on EVERY allocation.
    bitscan::setBit(c.bits, static_cast<size_t>(k) * c.stride_bits);
    Header* hdr = reinterpret_cast<Header*>(p);
    std::memset(hdr, 0, sizeof(Header));
    hdr->color = static_cast<u32>(
        (marking_active || gc_phase_ != GCPhase::Idle) ? Color::Black
                                                       : Color::White);
    // P§3.1: live_bytes of a uniform block is exact (popcount x cell) — not
    // only while not Idle (F7). initObjectHeaderWithSize is deliberately NOT
    // called: it would add live_bytes a second time mid-cycle.
    // (accumulated in the cursor; flushCursor folds it into meta.live_bytes)
    c.pending_live += cell;
    c.pending_allocs++;
    allocated_bytes += cell;
    padCellSlack(p, requested_size, cell);   // a later demotion walks mixed (F8)
    return p;
}

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

bool OldGenSpace::ensureBagPageAvailable() {
    // Same fall-through as populateFromBlock (left untouched so the flag-off
    // path stays byte-identical): acquire a fresh page from the OS if the bag
    // is empty but address space remains below the old-gen cap.
    if (unassigned_blocks_.empty() && allocator_ != nullptr) {
        char* base = allocator_->acquireOldGenBlock(config_->alloc_buffer_size);
        if (base != nullptr) {
            unassigned_blocks_.emplace_back(base, base + config_->alloc_buffer_size);
            if (region_base_ == nullptr || base < region_base_) region_base_ = base;
            if (base + config_->alloc_buffer_size > region_end_) {
                region_end_ = base + config_->alloc_buffer_size;
            }
            resizePageIndexForRegion();
        }
    }
    return !unassigned_blocks_.empty();
}

bool OldGenSpace::startVirginBlock(size_t cls) {
    const size_t cell_bytes = classToSize(cls);
    if (!ensureBagPageAvailable()) return false;
    const auto extent = unassigned_blocks_.back();
    const size_t page_size = static_cast<size_t>(extent.second - extent.first);
    const size_t num_cells = page_size / cell_bytes;
    if (num_cells == 0) return false;
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

bool OldGenSpace::sweepWillReach(BlockId id, const char* addr) const {
    if (gc_phase_ != GCPhase::Sweeping) return false;
    if (blocks_.meta(id).fully_swept) return false;
    const size_t pos = blocks_.posOf(id);
    if (pos > sweep_buffer_index_) return true;
    if (pos < sweep_buffer_index_) return false;   // behind: never revisited
    return sweep_cursor_ == nullptr || addr >= sweep_cursor_;
}

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
            const LargeBodyId id = it->second;
            if (id < large_bodies_.size()) large_bodies_[id].body_base = nullptr;
            it = large_body_index_.erase(it);
        } else {
            ++it;
        }
    }
}

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
                Header* hdr = reinterpret_cast<Header*>(b.start);
                if (hdr->pin && (hdr->tag == Tag_String ||
                                 hdr->tag == Tag_ByteBuffer)) {
                    auto it = large_body_index_.find(b.start);
                    if (it != large_body_index_.end()) {
                        const LargeBodyId lid = it->second;
                        if (lid < large_bodies_.size()) {
                            large_bodies_[lid].body_base = nullptr;
                        }
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
            if (meta.live_bytes < cap) {
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

BlockId OldGenSpace::blockIdFor(const void* obj) const {
    const char* p = static_cast<const char*>(obj);
    if (p < region_base_ || p >= region_end_) return NO_BLOCK_ID;
    const size_t page =
        static_cast<size_t>(p - index_base_) / config_->alloc_buffer_size;
    if (page < page_index_.committed()) {   // HEAP_049: never read uncommitted
        const PageOwners& slot = page_index_[page];
        const BlockId a = decodeOwner(slot.primary);
        if (a.valid()) {
            const BlockInfo& blk = blocks_.info(a);
            if (p >= blk.start && p < blk.end) return a;
        }
        const BlockId b = decodeOwner(slot.secondary);
        if (b.valid()) {
            const BlockInfo& blk = blocks_.info(b);
            if (p >= blk.start && p < blk.end) return b;
        }
    }
    return NO_BLOCK_ID;
}

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
    // DEAD. It ran under `gc_phase_ == GCPhase::Marking`, and gc_phase_ is
    // assigned at exactly four sites — Idle (initialize), Sweeping
    // (transitionToSweeping), Idle (reclaim), Idle (reset) — and never
    // Marking. Marking is driven synchronously by finishMarkAndSweep, which
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

// Finalises a popped free cell into a usable object: writes the header,
// pads any slack, and accounts for the cell's bytes.
void* OldGenSpace::finalizePoppedCell(FreeCell* cell, size_t cls,
                                      size_t requested_size) {
    void* result = static_cast<void*>(cell);
    const size_t cell_size = classToSize(cls);
    initObjectHeaderWithSize(result, cell_size);
    padCellSlack(result, requested_size, cell_size);
    allocated_bytes += cell_size;
    return result;
}

// Free-list-only allocation. Pure refactor of the original first two
// paragraphs of allocateFromSizeClass — does NOT consume a bag page or
// grow committed capacity.
void* OldGenSpace::tryAllocateFromFreeLists(size_t cls, size_t requested_size) {
    assert(cls < NUM_SIZE_CLASSES);

    if (FreeCell* cell = tryPopFromFreeList(cls)) {
        return finalizePoppedCell(cell, cls, requested_size);
    }

    if (void* result = tryAllocateBySplittingLarger(cls, classToSize(cls))) {
        padCellSlack(result, requested_size, classToSize(cls));
        return result;
    }

    return nullptr;
}

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
void* OldGenSpace::sweepOnDemandAllocate(size_t cls, size_t requested_size) {
    if (void* obj = tryAllocateFromFreeLists(cls, requested_size)) {
        return obj;
    }
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
    }
    return nullptr;
}

// Panic-mode sweep: drives any remaining lazy-sweep work to completion in
// panic_sweep_slice_bytes slices and retries the free-list path between
// slices. The "growth impossible" precondition lives at the call site —
// `allocateFromSizeClass` only invokes this once `allocateFromBagPage` has
// already failed to grow capacity.
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
    }
    return nullptr;
}

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
    // Branch (C) is the only caller; the routing in `OldGenSpace::allocate`
    // ensures `request_cls >= num_size_classes_`.
    assert(request_cls >= num_size_classes_ &&
           "allocateFromBagPage: caller must route size-classed requests "
           "through allocateFromSizeClass");

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
        char* base = allocator_->acquireOldGenBlock(config_->alloc_buffer_size);
        if (base != nullptr) {
            unassigned_blocks_.emplace_back(base, base + config_->alloc_buffer_size);
            if (region_base_ == nullptr || base < region_base_) region_base_ = base;
            if (base + config_->alloc_buffer_size > region_end_) {
                region_end_ = base + config_->alloc_buffer_size;
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
    const size_t remainder = alloc_span - requested_size;
    if (remainder >= MIN_FREE_CELL_SIZE) {
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
    return result;
}

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
            if (region_base_ == nullptr || base < region_base_) region_base_ = base;
            if (base + config_->alloc_buffer_size > region_end_) {
                region_end_ = base + config_->alloc_buffer_size;
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

        initObjectHeader(blk.start);
        return static_cast<void*>(blk.start);
    }
    return nullptr;
}

void* OldGenSpace::allocateFromEmptyRegularBlocks(size_t size) {
    syncCursorLiveBytes();   // threaded-gc-02: readers of live_bytes
    size = (size + 7) & ~7;

    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        const BlockId i = blocks_.idAt(pos);
        const BufferMetadata& meta = blocks_.meta(i);
        if (!meta.fully_swept || meta.live_bytes != 0) continue;
        if (blocks_.info(i).is_large) continue;
        if (blocks_.info(i).totalBytes() < size) continue;

        // Drop any embedded free cells before flipping is_large; otherwise
        // the next sweep would walk the now-large block as if it were a
        // size-class page.
        if (config_->old_gen_bitmap_alloc) detachFromAllocation(i);
        removeFreeCellsForBlock(i);

        // Debit the small-class budget for this block (if it was a uniform
        // small-class page) BEFORE we flip size_class to NUM_SIZE_CLASSES.
        onBlockTransitioningToLarge(i);

        BlockInfo& blk = blocks_.info(i);
        const size_t total = blk.totalBytes();
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

        initObjectHeader(blk.start);
        return static_cast<void*>(blk.start);
    }
    return nullptr;
}

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

    char* block_base = allocator_->acquireOldGenBlock(block_size);
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
    if (region_base_ == nullptr || block_base < region_base_) {
        region_base_ = block_base;
    }
    if (block_base + block_size > region_end_) {
        region_end_ = block_base + block_size;
    }
    // Commit the page index through the grown region, then materialize: the
    // block's page slots (many, for a large block) get its id. Large blocks
    // use the large-mark byte for liveness; their arena slot has length 0.
    resizePageIndexForRegion();
    materializeBlock(bi, {size, 0, mid_cycle_large}, 0);

    allocated_bytes += size;

    initObjectHeader(block_base);
    return static_cast<void*>(block_base);
}

/**
 * Starts the marking phase of a major GC.
 * Pushes all roots onto the mark stack and prepares for incremental marking.
 */
#if ENABLE_GC_STATS
void OldGenSpace::startMark(const std::unordered_set<HPointer*> &roots,
                            const std::unordered_set<uint64_t*> &jit_roots,
                            Allocator &alloc, GCStats &stats) {
#else
void OldGenSpace::startMark(const std::unordered_set<HPointer*> &roots,
                            const std::unordered_set<uint64_t*> &jit_roots,
                            Allocator &alloc) {
#endif
    if (marking_active)
        return;

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
    mark_stack.clear();
    nursery_visited_.clear();

    // Store Allocator reference for nursery checks during marking.
    allocator_ref_ = &alloc;

    // Step 2: zero per-block live-bytes accounting so markOneObject can
    // attribute reachable objects to their owning blocks. The all-dead
    // fast path (Step 3) keys off this counter being still zero post-mark.
    resetBufferMetaForMark();

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
        uint64_t val = *root;

        if (isConstantBits(val)) {
            continue;  // Skip embedded constants.
        }

        void *obj = reinterpret_cast<void*>(val);
        if (obj && alloc.isInHeap(obj)) {
            pushMarkRoot(obj);
        }
    }

#if ENABLE_GC_STATS
    GC_STATS_MAJOR_INC_CONCURRENT_MARK(stats);
#endif
}

/**
 * Performs incremental marking work for up to work_units objects.
 * Returns true if more work remains, false if marking is complete.
 */
#if ENABLE_GC_STATS
bool OldGenSpace::incrementalMark(size_t work_units, GCStats &stats) {
#else
bool OldGenSpace::incrementalMark(size_t work_units) {
#endif
    if (!marking_active || mark_stack.empty()) {
        return false;  // No work to do.
    }

    size_t units_done = 0;

    // Item 54, FIFO variant (gc_handbook/02-mark-sweep.md §2.6). A small ring
    // sits between the mark stack and the scan: entries are popped into the
    // ring and prefetched on the way in, and the entry that falls out the far
    // end is the one scanned. That fixes the prefetch distance at
    // MARK_FIFO_DEPTH objects of real work, where prefetch-on-grey's distance
    // was whatever the LIFO happened to give — often 1, for the last child
    // pushed.
    //
    // The ring MUST be drained before returning: `incrementalMark` signals
    // completion with `!mark_stack.empty()`, so an entry left in flight would
    // never be scanned, its children would never be marked, and live objects
    // would be swept. The budget therefore overshoots `work_units` by at most
    // MARK_FIFO_DEPTH-1 objects, which is what the trailing drain does.
    MarkStackEntry fifo[MARK_FIFO_DEPTH];
    size_t head = 0, tail = 0, count = 0;

    while (units_done < work_units) {
        while (count < MARK_FIFO_DEPTH && !mark_stack.empty()) {
            MarkStackEntry e = mark_stack.back();
            mark_stack.pop_back();
            __builtin_prefetch(e.obj, 0, 3);
            fifo[tail] = e;
            tail = (tail + 1) % MARK_FIFO_DEPTH;
            ++count;
        }
        if (count == 0) break;
        MarkStackEntry entry = fifo[head];
        head = (head + 1) % MARK_FIFO_DEPTH;
        --count;
        if (markOneObject(entry.obj, entry.block)) ++units_done;
    }

    while (count > 0) {   // trailing drain — never return with entries in flight
        MarkStackEntry entry = fifo[head];
        head = (head + 1) % MARK_FIFO_DEPTH;
        --count;
        if (markOneObject(entry.obj, entry.block)) ++units_done;
    }

#if ENABLE_GC_STATS
    GC_STATS_MAJOR_INC_INCREMENTAL_MARK(stats, units_done);
#endif

    return !mark_stack.empty();
}

void OldGenSpace::markChildren(void *obj) {
    Header *hdr = getHeader(obj);

    switch (hdr->tag) {
        case Tag_Tuple2: {
            Tuple2 *t = static_cast<Tuple2 *>(obj);
            markUnboxable(t->a, tupleFieldKind(hdr->unboxed, 0) == 0);
            markUnboxable(t->b, tupleFieldKind(hdr->unboxed, 1) == 0);
            break;
        }
        case Tag_Tuple3: {
            Tuple3 *t = static_cast<Tuple3 *>(obj);
            markUnboxable(t->a, tupleFieldKind(hdr->unboxed, 0) == 0);
            markUnboxable(t->b, tupleFieldKind(hdr->unboxed, 1) == 0);
            markUnboxable(t->c, tupleFieldKind(hdr->unboxed, 2) == 0);
            break;
        }
        case Tag_Cons: {
            Cons *c = static_cast<Cons *>(obj);
            markUnboxable(c->head, tupleFieldKind(hdr->unboxed, 0) == 0);
            markHPointer(c->tail);
            break;
        }
        case Tag_ConsChunk: {
            ConsChunk *cv = static_cast<ConsChunk *>(obj);
            markHPointer(cv->backing);
            markHPointer(cv->next);
            break;
        }
        case Tag_ListBacking: {
            // Live slots are [hd, capacity); scalar-kind backings (unboxed
            // bits 1:0 != 0) are pointer-free. Slack below hd is never traced.
            if ((hdr->unboxed & 0x3) == 0) {
                ListBacking *lb = static_cast<ListBacking *>(obj);
                for (u32 i = lb->hd; i < hdr->size; i++) {
                    markUnboxable(lb->elems[i], true);
                }
            }
            break;
        }
        case Tag_Custom: {
            Custom *c = static_cast<Custom *>(obj);
            for (u32 i = 0; i < hdr->size && i < 24; i++) {
                markUnboxable(c->values[i], fieldKind(c->unboxed, i) == 0);
            }
            break;
        }
        case Tag_Record: {
            Record *r = static_cast<Record *>(obj);
            for (u32 i = 0; i < hdr->size && i < 32; i++) {
                markUnboxable(r->values[i], fieldKind(r->unboxed, i) == 0);
            }
            break;
        }
        case Tag_DynRecord: {
            DynRecord *dr = static_cast<DynRecord *>(obj);
            markHPointer(dr->fieldgroup);
            for (u32 i = 0; i < hdr->size; i++) {
                markHPointer(dr->values[i]);
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
                markUnboxable(cl->values[i], fieldKind(cl->unboxed, i) == 0);
            }
            break;
        }
        case Tag_Process: {
            Process *p = static_cast<Process *>(obj);
            markHPointer(p->root);
            markHPointer(p->stack);
            markHPointer(p->mailbox);
            break;
        }
        case Tag_Task: {
            Task *t = static_cast<Task *>(obj);
            if ((t->header.unboxed & 0x3) == 0) {
                markHPointer(t->value.p);
            }
            markHPointer(t->callback);
            markHPointer(t->kill);
            markHPointer(t->task);
            break;
        }
        case Tag_Array: {
            ElmArray *arr = static_cast<ElmArray *>(obj);
            bool is_boxed = (arr->header.unboxed & 0x3) == 0;
            for (u32 i = 0; i < arr->length; i++) {
                markUnboxable(arr->elements[i], is_boxed);
            }
            break;
        }
        case Tag_StringSlice: {
            ElmStringSlice *slc = static_cast<ElmStringSlice *>(obj);
            markHPointer(slc->base);
            break;
        }
        case Tag_StringUtf8View: {
            ElmStringUtf8View *v = static_cast<ElmStringUtf8View *>(obj);
            markHPointer(v->base);
            break;
        }
        case Tag_ByteBufferSlice: {
            ElmByteBufferSlice *slc = static_cast<ElmByteBufferSlice *>(obj);
            markHPointer(slc->base);
            break;
        }
        case Tag_StringRope: {
            ElmStringRope *r = static_cast<ElmStringRope *>(obj);
            markHPointer(r->left);
            markHPointer(r->right);
            break;
        }
        case Tag_LargeStringHeader: {
            // Split header: trace the body so it survives major GC. The body
            // is pointer-free (Tag_String chars[]), so no further traversal.
            LargeStringHeader *h = static_cast<LargeStringHeader *>(obj);
            markHPointer(h->body);
            break;
        }
        case Tag_LargeByteHeader: {
            LargeByteHeader *h = static_cast<LargeByteHeader *>(obj);
            markHPointer(h->body);
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

void OldGenSpace::markHPointer(HPointer &ptr) {
    if (ptr.ptr_ind != 0)
        return;

    void *obj = Allocator::fromPointerRaw(ptr);
    if (!obj)
        return;

    if (!allocator_ref_ || !allocator_ref_->isInHeap(obj))
        return;

    pushMarkRoot(obj);
}

void OldGenSpace::pushMarkRoot(void *obj) {
    // Major GC must not write into nursery headers; minor GC owns those.
    // Use nursery_visited_ to break cycles when traversing through nursery
    // objects, instead of per-block bitmaps (which only cover old gen).
#if ECO_HEAP_VALIDATE
    // HEAP_053: the per-heap nursery must agree with the calling thread's
    // heap (HEAP_007 makes them the same heap today).
    assert(nursery_->contains(obj) == allocator_ref_->isInNursery(obj) &&
           "HEAP_053: bound nursery disagrees with tl_heap_'s nursery");
#endif
    if (nursery_->contains(obj)) {
        if (nursery_visited_.insert(obj).second) {
            mark_stack.push_back(MarkStackEntry{obj, NO_BLOCK_ID});
        }
        return;
    }

    // Old-gen path: bitmap discovery via O(1) page-table lookup. Setting
    // the bit IS the grey transition; popping + markChildren IS the
    // blackening. Bit stays set until sweep clears it.
    if (!contains(obj)) return;
    const BlockId block_id = blockIdFor(obj);
    if (!block_id.valid()) return;

    // Item 40: one test-and-set instead of isMarkedInBlock + setMarkBitInBlock.
    if (testAndSetMarkBitInBlock(block_id, obj)) return;
    // Cache the block id on the entry so markOneObject can skip a second
    // blockIdFor lookup when attributing live bytes.
    mark_stack.push_back(MarkStackEntry{obj, block_id});
}

void OldGenSpace::markUnboxable(Unboxable &val, bool is_boxed) {
    if (is_boxed) {
        markHPointer(val.p);
    }
}

// ---------------------------------------------------------------------------
// Mark-time live-bytes attribution (Step 2).
// ---------------------------------------------------------------------------

bool OldGenSpace::markOneObject(void* obj, BlockId block_index) {
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

    // Nursery objects: traverse children but never write into the header,
    // and don't attribute bytes (nursery cells aren't tracked in
    // per block; only old-gen blocks are). The cycle break lives in
    // pushMarkRoot via nursery_visited_.
#if ECO_HEAP_VALIDATE
    assert((nursery_ != nullptr && nursery_->contains(obj)) ==
               (allocator_ref_ && allocator_ref_->isInNursery(obj)) &&
           "HEAP_053: bound nursery disagrees with tl_heap_'s nursery");
#endif
    if (nursery_ != nullptr && nursery_->contains(obj)) {
        markChildren(obj);
        return true;
    }

    // Old-gen object: the bit was already set by pushMarkRoot when this
    // object was discovered, so we don't need to test it again here. Just
    // attribute live bytes and recurse into children. markChildren may
    // call back into pushMarkRoot for child references; those will set
    // their own bits and push themselves on the mark stack.
    if (!contains(obj)) return false;
#if ECO_HEAP_VALIDATE
    // HEAP_BUILDER_001: builder objects are forbidden in old gen. If we
    // observe one here, a kernel either failed to clear the bit before
    // publishing the object, or the GC promoted a builder despite the
    // !builder gate in NurserySpace::evacuate.
    // threaded-gc-04 HEAP_061: a born-old pending object may be a builder.
    assert((!hdr->builder || isBornOldPending(obj)) &&
           "HEAP_BUILDER_001: builder object in old gen");
#endif
    // Use the cached block id when valid; fall back to blockIdFor only
    // when the cache is empty (cold callers / nursery sentinel).
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
    // HEAP_051: the marker attributes to its accumulator only; merged into
    // BufferMetadata::live_bytes at finalizeMetaAfterMark.
    mark_live_.add(blk_idx, step);
    markChildren(obj);
    return true;
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
        if (mark_live_.peek(id) != 0) {
            std::fprintf(stderr, "[heap-validate] HEAP_051: id %u has %llu "
                "unmerged marker live bytes at mark start\n", id.v,
                (unsigned long long)mark_live_.peek(id));
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
    mark_live_.mergeInto(blocks_);
    // threaded-gc-04: the P1 census reads mark bits here, before any sweep
    // clears them (plan P§3.4, trap 1).
    p1::onMarkEnd(*this);
    pruneBornOldAtMarkEnd();   // threaded-gc-04 HEAP_061

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
    prev_major_live_ = major_live_;
    major_live_ = total_live;
}

// Walks `blocks_` once and demotes any non-large uniform block whose
// mark-derived `live_bytes` is at most `demote_live_fraction` (default 0.5;
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
#if ENABLE_GC_STATS
void OldGenSpace::finishMarkAndSweep(GCStats &stats) {
    while (incrementalMark(1000, stats)) {
        // Keep marking.
    }

    finalizeMetaAfterMark();
    // Phase A of the residency snapshot: capture free-list state BEFORE
    // transitionToSweeping wipes free_lists_ / free_large_blocks_. The
    // per-block free-bytes map is keyed by BlockInfo::start so it
    // survives reclaim's swap-remove of blocks_ entries, and is consumed
    // by Phase B after reclaim + shrink.
    FreeBytesByBlockStart free_by_start;
    gatherFreeListSnapshotInto(stats, free_by_start);
    // Retag mostly-dead uniform blocks as mixed BEFORE transitionToSweeping.
    // The wipe of free_lists_ then drops their stale uniform-class cells
    // for free; lazy sweep re-emits the coalesced runs on mixed-only
    // classes where the splitter can carve smaller cells.
    demoteMostlyDeadUniformBlocks();
    transitionToSweeping();
    reclaimAllDeadBlocksFromMeta();
    adjustCapacityAfterMajorGC();
    // Phase B of the residency snapshot: post-reclaim, post-shrink, so
    // the live_frac == 0 bucket reflects the truly retained dead pages
    // rather than candidates about to be released.
    gatherResidencySnapshotFrom(stats, free_by_start);
    // threaded-gc-02 (P§3.3): classify blocks, retire dead bodies, queue
    // partial uniform blocks — after reclaim/shrink, before the pending count.
    if (config_->old_gen_bitmap_alloc) {
        classifyBlocksAfterMark();
        committed_at_major_ = getCommittedBytes();
    }
    recomputeSweepPendingBlocks();
    lazySweep(NUM_SIZE_CLASSES, config_->initial_sweep_budget);

#if ECO_HEAP_VALIDATE
    validateOldGenMetadata("finishMarkAndSweep");
#endif
    marking_active = false;

    GC_STATS_MAJOR_INC_MARK_SWEEP(stats);
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
        if (mark_stack.size() > profile.mark_stack_peak)
            profile.mark_stack_peak = mark_stack.size();
        bool more = incrementalMark(1000, stats);
        profile.mark_iterations++;
        if (!more) break;
    }
    profile.mark_units_done =
        stats.total_incremental_mark_work_units - mark_units_before;
    auto t_mark_end = std::chrono::high_resolution_clock::now();

    auto t_sweep_start = t_mark_end;

    finalizeMetaAfterMark();
    // Phase A of the residency snapshot: capture free-list state BEFORE
    // transitionToSweeping wipes free_lists_ / free_large_blocks_. The
    // per-block free-bytes map is keyed by BlockInfo::start so it
    // survives reclaim's swap-remove of blocks_ entries, and is consumed
    // by Phase B after reclaim + shrink.
    FreeBytesByBlockStart free_by_start;
    gatherFreeListSnapshotInto(stats, free_by_start);
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
    // Phase B of the residency snapshot: post-reclaim, post-shrink, so
    // the live_frac == 0 bucket reflects the truly retained dead pages
    // rather than candidates about to be released.
    gatherResidencySnapshotFrom(stats, free_by_start);
    // threaded-gc-02 (P§3.3): classify blocks, retire dead bodies, queue
    // partial uniform blocks — after reclaim/shrink, before the pending count.
    if (config_->old_gen_bitmap_alloc) {
        classifyBlocksAfterMark();
        committed_at_major_ = getCommittedBytes();
    }
    recomputeSweepPendingBlocks();
    lazySweep(NUM_SIZE_CLASSES, config_->initial_sweep_budget);

    auto t_sweep_end = std::chrono::high_resolution_clock::now();

    profile.mark_ns =
        std::chrono::duration_cast<std::chrono::nanoseconds>(
            t_mark_end - t_mark_start).count();
    profile.sweep_ns =
        std::chrono::duration_cast<std::chrono::nanoseconds>(
            t_sweep_end - t_sweep_start).count();

    profile.blocks_scanned = blocks_.size();
    profile.live_bytes_after = frag_stats_.live_bytes;
    profile.garbage_bytes    = frag_stats_.total_free_bytes;
    profile.alldead_blocks_released = alldead.blocks_released;
    profile.alldead_bytes_released  = alldead.bytes_released;
    profile.demoted_blocks  = demotion.blocks_demoted;
    profile.demoted_bytes   = demotion.bytes_demoted;
    profile.initial_sweep_budget_bytes = config_->initial_sweep_budget;
    // True post-initial-slice pending count, fed by markBlockFullySwept
    // throughout the slice.
    profile.sweep_pending_blocks = sweep_pending_blocks_;

#if ECO_HEAP_VALIDATE
    validateOldGenMetadata("finishMarkAndSweep");
#endif
    marking_active = false;

    GC_STATS_MAJOR_INC_MARK_SWEEP(stats);
}
#else
void OldGenSpace::finishMarkAndSweep() {
    while (incrementalMark(1000)) {
        // Keep marking.
    }

    finalizeMetaAfterMark();
    demoteMostlyDeadUniformBlocks();
    transitionToSweeping();
    reclaimAllDeadBlocksFromMeta();
    adjustCapacityAfterMajorGC();
    // threaded-gc-02 (P§3.3): classify blocks, retire dead bodies, queue
    // partial uniform blocks — after reclaim/shrink, before the pending count.
    if (config_->old_gen_bitmap_alloc) {
        classifyBlocksAfterMark();
        committed_at_major_ = getCommittedBytes();
    }
    recomputeSweepPendingBlocks();
    lazySweep(NUM_SIZE_CLASSES, config_->initial_sweep_budget);

#if ECO_HEAP_VALIDATE
    validateOldGenMetadata("finishMarkAndSweep");
#endif
    marking_active = false;
}

void OldGenSpace::finishMarkAndSweep(MajorGCPhaseProfile &profile) {
    auto t_mark_start = std::chrono::high_resolution_clock::now();
    while (true) {
        if (mark_stack.size() > profile.mark_stack_peak)
            profile.mark_stack_peak = mark_stack.size();
        bool more = incrementalMark(1000);
        profile.mark_iterations++;
        if (!more) break;
    }
    auto t_mark_end = std::chrono::high_resolution_clock::now();

    finalizeMetaAfterMark();
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
    // threaded-gc-02 (P§3.3): classify blocks, retire dead bodies, queue
    // partial uniform blocks — after reclaim/shrink, before the pending count.
    if (config_->old_gen_bitmap_alloc) {
        classifyBlocksAfterMark();
        committed_at_major_ = getCommittedBytes();
    }
    recomputeSweepPendingBlocks();
    lazySweep(NUM_SIZE_CLASSES, config_->initial_sweep_budget);

    auto t_sweep_end = std::chrono::high_resolution_clock::now();

    profile.mark_ns =
        std::chrono::duration_cast<std::chrono::nanoseconds>(
            t_mark_end - t_mark_start).count();
    profile.sweep_ns =
        std::chrono::duration_cast<std::chrono::nanoseconds>(
            t_sweep_end - t_mark_end).count();

    profile.blocks_scanned = blocks_.size();
    profile.live_bytes_after = frag_stats_.live_bytes;
    profile.garbage_bytes    = frag_stats_.total_free_bytes;
    profile.alldead_blocks_released = alldead.blocks_released;
    profile.alldead_bytes_released  = alldead.bytes_released;
    profile.demoted_blocks  = demotion.blocks_demoted;
    profile.demoted_bytes   = demotion.bytes_demoted;
    profile.initial_sweep_budget_bytes = config_->initial_sweep_budget;
    profile.sweep_pending_blocks = sweep_pending_blocks_;

#if ECO_HEAP_VALIDATE
    validateOldGenMetadata("finishMarkAndSweep");
#endif
    marking_active = false;
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

    while (work_done < work_budget && gc_phase_ == GCPhase::Sweeping) {
        if (sweep_cursor_ == nullptr) {
            if (sweep_buffer_index_ >= blocks_.size()) {
                gc_phase_ = GCPhase::Idle;
#if ENABLE_GC_STATS
                auto t0_shrink = GC_STATS_TIMER_START();
#endif
                onSweepComplete();
#if ENABLE_GC_STATS
                alloc_stats_.total_post_sweep_shrink_ns +=
                    GC_STATS_TIMER_ELAPSED_NS(t0_shrink);
#endif
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
                    Header* hdr = reinterpret_cast<Header*>(sweep_cursor_);
                    if (hdr->pin && (hdr->tag == Tag_String ||
                                     hdr->tag == Tag_ByteBuffer)) {
                        auto it = large_body_index_.find(sweep_cursor_);
                        if (it != large_body_index_.end()) {
                            LargeBodyId id = it->second;
                            if (id < large_bodies_.size()) {
                                large_bodies_[id].body_base = nullptr;
                            }
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
                // own header.
                flushRun(sweep_buffer_index_);
                bitscan::clearBit(gbits, nb);
                const size_t step = walkStep(block, getObjectSize(live_obj));
                sweep_cursor_ = live_obj + step;
                work_done += step;
#if ENABLE_GC_STATS
                alloc_stats_.bm.gap_sweep_live_objects++;
                alloc_stats_.bm.gap_sweep_bytes += step;
#endif
            }
        }

        while (!gap_sweep && sweep_cursor_ < used_end && work_done < work_budget) {
            Header* hdr = reinterpret_cast<Header*>(sweep_cursor_);
            size_t step = walkStep(block, getObjectSize(sweep_cursor_));

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
                if (hdr->pin && (hdr->tag == Tag_String ||
                                 hdr->tag == Tag_ByteBuffer)) {
                    auto it = large_body_index_.find(sweep_cursor_);
                    if (it != large_body_index_.end()) {
                        LargeBodyId id = it->second;
                        if (id < large_bodies_.size()) {
                            large_bodies_[id].body_base = nullptr;
                        }
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
            flushRun(sweep_buffer_index_);
#if ECO_HEAP_VALIDATE
            if (gap_sweep) {
                // V11 (HEAP_055): the gap-swept block parses by header over
                // [start, end_of_objects): every gap became Tag_Free cells.
                size_t covered = 0;
                for (char* q = block.start; q < used_end;) {
                    const size_t qs = walkStep(block, getObjectSize(q));
                    if (qs == 0 || q + qs > used_end) {
                        std::fprintf(stderr, "[heap-validate] lazySweep: V11 block "
                            "id %u parse breaks at %p (step %zu, end %p)\n",
                            cur_id.v, (void*)q, qs, (void*)used_end);
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
            return work_done;
        }
    }

    // Flush any in-progress run before returning (we may resume mid-block on
    // the next call).
    flushRun(sweep_buffer_index_);

    if (sweep_buffer_index_ >= blocks_.size()) {
        gc_phase_ = GCPhase::Idle;
#if ENABLE_GC_STATS
        auto t0_shrink = GC_STATS_TIMER_START();
#endif
        onSweepComplete();
#if ENABLE_GC_STATS
        alloc_stats_.total_post_sweep_shrink_ns +=
            GC_STATS_TIMER_ELAPSED_NS(t0_shrink);
#endif
    }
    return work_done;
}

/**
 * Called when lazy sweeping completes.
 * Computes a precise post-sweep snapshot, then runs a light second-pass
 * shrink to mop up blocks that became fully empty through padCellSlack /
 * splitting after the heavy post-mark shrink. Compaction is decided on
 * the post-sweep stats.
 */
void OldGenSpace::onSweepComplete() {
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
}

OldGenSpace::MajorGCTriggerReason
OldGenSpace::evaluateMajorGCTrigger() const {
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
    }

    // Garbage-fraction trigger: long-running compiles whose live working set
    // is much smaller than the post-first-major committed never re-cross the
    // occupancy threshold (free-list reuse keeps the heap from growing), so
    // dead bytes accumulate as un-swept garbage. Catch that case by tracking
    // bytes mutator-allocated since the last sweep finished and triggering
    // when they cross a fraction of committed — i.e. "if even all of those
    // bytes died and stayed un-swept, the heap would be that fraction
    // garbage". 0 disables.
    const float garb_frac = config_->major_gc_garbage_fraction;
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
        if (static_cast<double>(alloc_since_major) >= budget * live_ref) {
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

    if (region_base_ == nullptr || region_end_ <= region_base_) return;

    const size_t capacity = static_cast<size_t>(region_end_ - region_base_);
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

void OldGenSpace::releaseBlockToAllocator(BlockId block_index) {
    if (!block_index.valid()) return;
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
        (blk.start == region_base_ || blk.end == region_end_)) {
        recomputeRegionBounds();
    }
}

void OldGenSpace::releaseUnassignedBlockToAllocator(size_t unassigned_index) {
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
    if (start == region_base_ || end == region_end_) {
        recomputeRegionBounds();
    }
}

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
}

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
    syncCursorLiveBytes();   // threaded-gc-02: readers of live_bytes
    if (compact_phase_ != CompactionPhase::Idle) return;
    // Same gate as shouldCompact: compaction must wait for lazy sweep to
    // finish so meta is fully rebuilt and free_lists_ are stable.
    if (gc_phase_ != GCPhase::Idle) return;
    assert(sweepComplete() &&
           "scheduleCompaction: sweep must be complete (gc_phase_ == Idle)");

    // threaded-gc-04 HEAP_061: born-old pending objects hold old->young
    // edges the minor GC fixes up in place; never move them (or anything)
    // while any is pending.
    if (!born_old_.empty()) return;
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
                if (region_base_ == nullptr || base < region_base_) region_base_ = base;
                if (base + config_->alloc_buffer_size > region_end_) {
                    region_end_ = base + config_->alloc_buffer_size;
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

void* OldGenSpace::allocateLargeBody(size_t total_size, size_t logical_size,
                                     Tag body_tag, bool initial_color) {
    assert(body_tag == Tag_String || body_tag == Tag_ByteBuffer);
    total_size = (total_size + 7) & ~static_cast<size_t>(7);

    void* body = allocate(total_size);
    if (!body) return nullptr;
    GC_STATS_OLDGEN_DIRECT_RECORD_ALLOC(alloc_stats_, total_size);

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

    // Decide whether the body landed in a dedicated is_large block. The
    // BBoP allocator places sizes >= alloc_buffer_size into is_large blocks.
    const bool body_is_large = (total_size >= config_->alloc_buffer_size);

    // Cell footprint:
    //   - For is_large: body owns the entire block (page-aligned, possibly
    //     larger than total_size). cell_size = block totalBytes.
    //   - For size-class cells: the allocator rounded our request up to the
    //     block's size-class slot. We MUST record the slot size, not the
    //     requested size, because pushSpanOnFreeLists uses cell_size to
    //     re-emit free cells of exactly classToSize(cls). A request of
    //     2056 in a 2048 slot, freed via pushSpanOnFreeLists with
    //     span_bytes=2056 and cellSize=2048, would push one 2048 cell and
    //     orphan an 8-byte Tag_Free placeholder past the slot boundary —
    //     which lands in the next cell's header and corrupts the heap.
    size_t cell_size = total_size;
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

    registerLargeBody(body, cell_size, body_is_large, initial_color);
    return body;
}

OldGenSpace::LargeBodyId OldGenSpace::registerLargeBody(
        void* body, size_t cell_size, bool is_large, bool minor_color) {
    LargeBodyId id;
    if (!free_large_body_ids_.empty()) {
        id = free_large_body_ids_.back();
        free_large_body_ids_.pop_back();
        large_bodies_[id] = LargeBodyMeta{body, cell_size, is_large, minor_color};
    } else {
        id = static_cast<LargeBodyId>(large_bodies_.size());
        large_bodies_.push_back(LargeBodyMeta{body, cell_size, is_large, minor_color});
    }
    large_body_index_[body] = id;
    nursery_owned_bodies_.push_back(id);
    return id;
}

void OldGenSpace::markLargeBodySeen(HPointer body_hp, bool minor_color) {
    if (body_hp.ptr_ind != 0) return;
    void* body = Allocator::fromPointerRaw(body_hp);
    if (!body) return;
    auto it = large_body_index_.find(body);
    if (it == large_body_index_.end()) return;
    LargeBodyId id = it->second;
    if (id < large_bodies_.size()) {
        large_bodies_[id].color = minor_color;
    }
}

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

size_t OldGenSpace::sweepNurseryLargeBodies(bool minor_color) {
    // W0 item 50: the common case is an empty list — leave before the asserts
    // and the compaction-phase branch rather than after them.
    if (nursery_owned_bodies_.empty()) return 0;

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
        // Body's header in nursery did not survive this minor GC; free.
#if ENABLE_GC_STATS
        const size_t freed_bytes = m.cell_size;
#endif
        freeLargeBodyCell(m);
        free_large_body_ids_.push_back(id);
        nursery_owned_bodies_[k] = nursery_owned_bodies_.back();
        nursery_owned_bodies_.pop_back();
        ++freed;
#if ENABLE_GC_STATS
        alloc_stats_.large_body_minor_freed_bytes += freed_bytes;
#endif
    }

    return freed;
}

void OldGenSpace::freeLargeBodyCell(LargeBodyMeta& m) {
    if (m.body_base == nullptr) return;
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
                if (marking_active) (void)mark_live_.take(idx);
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
                    if (marking_active) bm.live_bytes += mark_live_.take(idx);
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
        mark_live_.storageBase() !=
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
                (decodeOwner(page_index_[sl].primary) != id &&
                 decodeOwner(page_index_[sl].secondary) != id)) {
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
        for (uint32_t enc : {page_index_[sl].primary, page_index_[sl].secondary}) {
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
