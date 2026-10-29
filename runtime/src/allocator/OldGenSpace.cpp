// The implementation of `OldGenSpace`, apart from the tenure grants, which are in OldGenTenure.cpp.

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

namespace {
// Whether the `ECO_OLDGEN_DEBUG` environment variable was set at start-up, which turns on extra
// checks in the sweep. It is read once, during static initialisation, so a test of it is a plain
// load rather than the guarded load of a function-local static.
const bool g_oldgen_debug = std::getenv("ECO_OLDGEN_DEBUG") != nullptr;
}
#include <functional>
#include <unordered_map>
#include <unordered_set>

namespace Elm {

// Global heap base (defined in Allocator.cpp).
extern char* g_heap_base;

// The M6 trace switch, defined in GCHelperPool.cpp. In a trace build, the M6 probe in this file
// fires only while it is set.
ECO_TLA_TRACE_ONLY(namespace gc { extern bool tla_m6; })

// Trace hooks for the TLA+ model M4, which models promotion into bitmap blocks. They compile to
// nothing unless ECO_TLA_TRACE is set, and in a trace build they log only while an M4 harness sets
// `tla_m4`, so traces taken for the other models are unchanged. `tla_m4_tick` orders the events
// logged under `promo_mu_` and is written only under it. `tla_m4_flip` is the block id of the
// calling thread's last empty-block flip, or -1.
ECO_TLA_TRACE_ONLY(bool tla_m4 = false; int64_t tla_m4_tick = 0; thread_local int64_t tla_m4_flip = -1;)
// Logs a trace event, as `ECO_TLA_TRACE` does, while `tla_m4` is set.
#define ECO_M4_TRACE(...) ECO_TLA_TRACE_ONLY(if (::Elm::tla_m4)) ECO_TLA_TRACE(__VA_ARGS__)
// The two halves of the name the M4 trace gives a cell `p` of this old generation: its block id and
// the index of its first mark bit in that block. Both expand to member calls, so they can be used
// only inside `OldGenSpace` member functions.
#define ECO_M4_BLK(p) blockIdFor(p).v
#define ECO_M4_BIT(p) static_cast<int64_t>((reinterpret_cast<const char*>(p) - \
                          blocks_.info(blockIdFor(p)).start) / MARK_ALIGNMENT)

// Declared here for the member functions above its definition, which is with the sweep below.
namespace {
inline void pushSpanOnFreeLists(FreeCell** free_lists, char* span_start,
                                size_t span_bytes,
                                BlockInfo* block,
                                BlockId block_index,
                                bool age_sentinel = false);


#if ECO_HEAP_VALIDATE
// Validating builds record which call site put each cell on a free list, so that a cell pushed
// twice can be reported with both sites. Each site names itself with a string literal. Both
// variables are thread_local (HEAP_053): they describe what the calling thread is pushing.

// The name of the call site now pushing onto the free lists; "unknown" outside a
// `PushOriginScope`.
thread_local const char* g_push_origin = "unknown";
// The site that first pushed each cell, as recorded on this thread.
thread_local std::unordered_map<void*, const char*> g_first_push_origin;

/**
 * Names the call site, as `g_push_origin`, for the lifetime of the scope, and restores the previous
 * name when it ends. The name must be a string that outlives the scope, such as a literal.
 */
struct PushOriginScope {
    const char* prev;   // The name to restore.
    // Makes `name` the current site.
    explicit PushOriginScope(const char* name) : prev(g_push_origin) {
        g_push_origin = name;
    }
    ~PushOriginScope() { g_push_origin = prev; }
};
#endif

// ====================================================================
// The links of `FreeCellMid` cells: the per-block list of free cells, and
// the class-list unlink through the predecessor link. A 16-byte cell has
// neither, so callers check the size first.
// ====================================================================

// Returns whether free cell `cell` has the `FreeCellMid` layout, which its size decides.
inline bool isTierM(const FreeCell* cell) {
    return cell->header.size >= MIN_TIER_M_SIZE;
}
// Returns whether a free cell of `bytes` bytes has the `FreeCellMid` layout.
inline bool isTierMSize(size_t bytes) { return bytes >= MIN_TIER_M_SIZE; }

// Returns `c` as a `FreeCellMid`. `c` must have that layout.
inline FreeCellMid* asTierM(FreeCell* c) {
    return reinterpret_cast<FreeCellMid*>(c);
}

// Returns the free cell at `off` 8-byte units from `blk.start`, or null when `off` is
// `FREE_CELLS_EMPTY`.
inline FreeCell* resolveOff(const BlockInfo& blk, uint16_t off) {
    return (off == FREE_CELLS_EMPTY)
        ? nullptr
        : reinterpret_cast<FreeCell*>(blk.start + size_t(off) * 8);
}

// Returns `c`'s offset from `blk.start` in 8-byte units, or `FREE_CELLS_EMPTY` when `c` is null.
// A non-null `c` must lie in `blk`.
inline uint16_t encodeOff(const BlockInfo& blk, const FreeCell* c) {
    if (c == nullptr) return FREE_CELLS_EMPTY;
    const size_t bytes =
        static_cast<size_t>(reinterpret_cast<const char*>(c) - blk.start);
    return static_cast<uint16_t>(bytes / 8);
}

// Links the `FreeCellMid` cell `c` at the head of the list of `blk`'s free cells.
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

// Unlinks the `FreeCellMid` cell `c` from the list of `blk`'s free cells, in constant time. `c`'s
// own links are left as they were.
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

// Unlinks the `FreeCellMid` cell `c` from the class list `free_lists[cls]`, in constant time
// through its predecessor link. `c` must be on that list. The list of its block's free cells is
// left alone.
inline void classListUnlinkTierM(FreeCell** free_lists, FreeCell* c,
                                 size_t cls) {
    FreeCellMid* m = asTierM(c);
    FreeCell* prev = getPrev(m);
    if (prev == nullptr) {
        free_lists[cls] = m->next_in_class;
    } else {
        prev->next_in_class = m->next_in_class;
    }
    if (m->next_in_class != nullptr) {
        copyPrev(asTierM(m->next_in_class), m);
    }
}

}  // namespace

void* readBarrier(HPointer& ptr) {
    assert(ptr.ptr_ind == 0 && "Cannot read barrier on embedded constant");

    // An HPointer's word is the absolute address, with no base or shift.
    return hpToAddr(ptr);
}

// A `size_t` block index that means no block. Nothing in this file uses it.
static constexpr size_t NO_BLOCK = std::numeric_limits<size_t>::max();

// Returns how far a walk over `block` moves past an object of `obj_size` bytes: the class's cell
// size in a uniform block, and `obj_size` in any other.
//
// An object in a uniform block owns its whole cell, including any slack after its own size, and a
// walk that stepped by the object's size could land inside the cell and read a free-list link as
// a header.
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
    for (size_t i = 0; i < NUM_SIZE_CLASSES; i++) {
        free_lists_[i] = nullptr;
    }
    ensureMarkers();
}

// TLA-REGION(OGS.destructor) begin
OldGenSpace::~OldGenSpace() {
    // Members are destroyed in reverse order, so `bg_ctl_` would go before `bg_`, whose members read
    // it: stop the gang first.
    if (bg_) bg_->stopAndJoin();
    bg_.reset();
    // HEAP_048: the blocks' memory is the Allocator's; only the metadata reservations are released.
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
    // A page's mark bitmap, one bit per MARK_ALIGNMENT bytes, rounded up to a multiple of 64 bytes.
    g.stride = ((page / MARK_ALIGNMENT + 7) / 8 + 63) & ~size_t{63};
    g.mark_arena_bytes = g.max_blocks * g.stride;
    return g;
}

void OldGenSpace::reserveMetadata() {
    const size_t reservation = allocator_->getOldGenReservationBytes();
    const OldGenGeometry g =
        geometryFor(reservation, config_->alloc_buffer_size);
    index_base_ = allocator_->getHeapBase();
    mark_threads_ = resolveMarkThreads(*config_);
    minor_threads_ = resolveMinorThreads(*config_);
    // HEAP_065: the background marker slots follow the foreground ones.
    conc_threads_ = resolveConcMarkThreads(*config_, mark_threads_);
    mark_slots_ = mark_threads_ + conc_threads_;
    ensureMarkers();
    // HEAP_051, HEAP_064: one live-byte accumulator per marker slot.
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

// Returns the number of size classes in use for `large_object_threshold`: every small class, and
// the medium classes, powers of two from `MEDIUM_CLASS_BASE`, whose cell size does not exceed the
// threshold. A request above the largest class in use, but below a page, is cut from a larger free
// cell or a page instead.
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
    los_.init(config_->alloc_buffer_size, OS_PAGE_SIZE);
    allocated_bytes = 0;
    small_class_bytes_ = 0;
    recomputeSmallClassLimit();

    // A free cell's block links are 16-bit offsets in 8-byte units (FreeCellMid), which reach only
    // 512 KiB into a block.
    if (config_->alloc_buffer_size > (size_t{1} << 19)) {
        std::fprintf(stderr,
            "[oldgen] alloc_buffer_size (%zu B) exceeds 524288 B; the "
            "16-bit per-cell offset field cannot encode addresses past "
            "this within a block.\n",
            config_->alloc_buffer_size);
        std::abort();
    }
    assert(allocator_ != nullptr && "OldGenSpace requires an Allocator");
    if (allocator_ != nullptr) reserveMetadata();

    // Commit the initial region in one piece and put each of its pages in the bag.
    // HeapConfig::validate makes initial_old_gen_size a multiple of alloc_buffer_size.
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
                unassigned_blocks_.emplace_back(page_start, page_end);
            }

            // No page is a block yet, so this only commits the index; every slot stays empty.
            resizePageIndexForRegion();
        }
    }
}

// TLA-REGION(OGS.reset) begin
void OldGenSpace::reset(const HeapConfig* new_config) {
    // Stop the background gang before anything it reads is torn down. It is dropped, so the next
    // one is made for the new configuration.
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
    if (new_config) {
        config_ = new_config;
        num_size_classes_ = computeNumSizeClasses(config_->large_object_threshold);
    }

    // The blocks' memory is the Allocator's, so only the tracking is cleared. The metadata is
    // reserved again, zeroed, so ids restart at 0 and no page-index owner or mark bit survives.
    blocks_.clear();
    unassigned_blocks_.clear();
    if (allocator_ != nullptr) reserveMetadata();
    for (size_t c = 0; c < NUM_SIZE_CLASSES; ++c) {
        cursor_[c] = AllocCursor{};
        partial_[c].clear();
        partial_head_[c] = 0;
    }

    allocated_bytes = 0;
    setRegionBase(nullptr);
    setRegionEnd(nullptr);
    gc_phase_ = GCPhase::Idle;
    marking_active = false;
    old_alloc_total_ = 0;
    old_alloc_at_prev_minor_ = 0;
    p_hat_ = 0;
    pacing_t0_ = PacingAtT0{};
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

    for (size_t i = 0; i < NUM_SIZE_CLASSES; i++) {
        free_lists_[i] = nullptr;
    }
    free_list_sentinel_count_ = 0;
    free_large_blocks_.clear();

    // The LOS's blocks went with blocks_: start it empty, with the configuration's geometry.
    los_.init(config_->alloc_buffer_size, OS_PAGE_SIZE);

    large_bodies_.clear();
    large_body_index_.clear();
    nursery_owned_bodies_.clear();
    free_large_body_ids_.clear();
    ylo_lo_ = ylo_hi_ = nullptr;
    ylo_count_ = 0;

    frag_stats_ = {0, 0, 0};

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

// CR-018 (HEAP_073): `cell_bytes` is counted in every phase, not only mid-cycle. The empty-block
// flip, the reclaim and the shrink take `live_bytes == 0` to mean the block is dead, so a block
// refilled after its sweep must not read 0. Between a sweep and the next mark `live_bytes` is an
// upper bound; the mark zeroes it and counts the cells it reaches. A cell allocated mid-cycle
// already has its bit set, so the mark does not reach it to count it.
// TLA-REGION(OGS.initObjectHeaderWithSize) begin
void OldGenSpace::initObjectHeaderWithSize(void* obj, size_t cell_bytes) {
    Header* hdr = reinterpret_cast<Header*>(obj);
    std::memset(hdr, 0, sizeof(Header));
    // The mark bit, not the colour, is what keeps a mid-cycle cell through the sweep; the colour is
    // written for the checks that read it.
    const bool black = marking_active || gc_phase_ != GCPhase::Idle;
    hdr->color = static_cast<u32>(black ? Color::Black : Color::White);
    if (!black && cell_bytes == 0) return;   // Idle large paths: nothing to do
    if (!contains(obj)) return;
    const BlockId block_id = blockIdFor(obj);
    if (!block_id.valid()) return;
    if (black) {
#if ECO_HEAP_VALIDATE
        if (blocks_.info(block_id).alloc_state == kAllocTenure) {
            std::fprintf(stderr, "[heap-validate] TV5: a mutator allocation in tenure-granted "
                         "block %u\n", block_id.v);
            std::fflush(stderr);
            std::abort();
        }
#endif
#if ECO_HEAP_VALIDATE
        assertCellWasWhite(block_id, obj);   // IM4
#endif
        // H1: atomic, because a background marker may be setting other bits of the same byte (in a
        // mixed block that existed at t0).
        if (__builtin_expect(test_plain_allocate_black_, 0))   // negative control
            setMarkBitInBlock(block_id, obj);
        else if (!test_skip_allocate_black_)      // negative-control hook only
            setMarkBitAtomic(block_id, obj);
    }
    // test_idle_uncounted_ is a negative control that skips the count while Idle.
    if (cell_bytes > 0 && (black || !test_idle_uncounted_)) {
        if (black || par_promo_active_) {
            // During a parallel promotion, finalizePoppedCellW and flushCursorW add to live_bytes
            // outside the promotion lock, so the add is atomic.
            std::atomic_ref<uint64_t>(blocks_.meta(block_id).live_bytes)
                .fetch_add(cell_bytes, std::memory_order_relaxed);
        } else {
            blocks_.meta(block_id).live_bytes += cell_bytes;   // the owner; nothing concurrent
        }
    }
}
// TLA-REGION(OGS.initObjectHeaderWithSize) end

// ---------------------------------------------------------------------------
// The page index.
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
    // CR-009: every region-bound write goes through the setters, which store through relaxed
    // atomic_ref.
    setRegionBase(new_base);
    setRegionEnd(new_end);
    // HEAP_049: the page index is keyed from index_base_, so new bounds need no rebuild. This
    // commits more of it only if the end moved past what is committed.
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
    // block.end is exclusive, so the last slot covers end - 1.
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
        // CR-021: this thread is the only writer, but background markers load the words through
        // atomic_ref (blockIdFor), so this thread's reads go through one too.
        const uint32_t prim = loadOwnerRelaxed(slot.primary);
        const uint32_t sec = loadOwnerRelaxed(slot.secondary);
        if (prim == enc || sec == enc) {
            continue;
        }
        // H3 (HEAP_049): a release store, so a background marker that loads the owner with acquire
        // in blockIdFor sees the BlockInfo and mark slot materializeBlock wrote before it.
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
            // Keep the older owner in the primary and overwrite the secondary. blockIdFor checks
            // the extent of the block it returns, so a wrong owner is not returned.
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
        // Remove `id`; a remaining secondary owner moves up to primary. CR-021: reads go through
        // atomic_ref, as in assignPageIndexForBlock.
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

// Declared here for the bitmap path; defined with the size-class path below.
static inline void padCellSlack(void* obj, size_t requested_size,
                                size_t cell_size);

// ---------------------------------------------------------------------------
// Bitmap allocation: the class cursors and queues (HEAP_054).
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
        // TV5, checked in every build: a granted block belongs to a running tenure job, and
        // detaching it would not stop the job.
        std::fprintf(stderr, "[gc] FATAL: detachFromAllocation(%u) on a tenure-granted block "
                     "(HEAP_070 skip rule violated)\n", id.v);
        std::fflush(stderr);
        std::abort();
    }
    const size_t cls = b.size_class;
    assert(cls < NUM_SIZE_CLASSES && "detach: allocation state on a non-uniform block");
    if (b.alloc_state == kAllocCurrent) {
        // During a parallel promotion a Current block may be a worker cursor's, which this cannot
        // see; detaching it would lose that cursor's block.
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
        // Queued: erase the entry now, so that a recycled id is never reached through a stale
        // entry.
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
    // IM13 (H1b): during a cycle the cursor takes only blocks made after t0, which background
    // markers never write; that is what lets finalizeBitmapCell set its bit with a plain store.
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
    if (blocks_.info(c.block).alloc_state == kAllocTenure) {
        std::fprintf(stderr, "[heap-validate] TV5: the mutator cursor allocated in tenure-granted "
                     "block %u\n", c.block.v);
        std::fflush(stderr);
        std::abort();
    }
#endif
#if ECO_HEAP_VALIDATE
    assertCellWasWhite(c.block, p);   // IM4
#endif
    // The bit is the allocation record, set on every allocation; only the allocate-black negative
    // control skips it.
    if (!test_skip_allocate_black_)
        bitscan::setBit(c.bits, static_cast<size_t>(k) * c.stride_bits);
    Header* hdr = reinterpret_cast<Header*>(p);
    std::memset(hdr, 0, sizeof(Header));
    hdr->color = static_cast<u32>(
        (marking_active || gc_phase_ != GCPhase::Idle) ? Color::Black
                                                       : Color::White);
    // A uniform block's live_bytes is exact (set cells times cell size) in every phase. The bytes
    // collect in the cursor until flushCursor adds them, so initObjectHeaderWithSize, which would
    // count the cell as well, is not called.
    c.pending_live += cell;
    c.pending_allocs++;
    allocated_bytes += cell;
    old_alloc_total_ += cell;
    padCellSlack(p, requested_size, cell);   // the block may later be demoted and walked as mixed
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
    // The same acquisition as in allocateFromBagPage, which keeps its own copy.
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

    // No cell is written: the zero bitmap materializeBlock gives the block says every cell is free.
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

// New uniform blocks enter at (3) and (6), the rungs matching allocateFromSizeClass's (2) and (5),
// so the two ladders reuse and grow in the same order.
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
    // (3) Growth: a new block for a small class under the budget.
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
    // (6) Growth: a new block.
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
// Parallel promotion. The *W functions repeat the steps of the class-cursor
// functions on a worker's cursor. They are separate copies, so the serial
// functions are left exactly as they are.
// ---------------------------------------------------------------------------

#if ECO_HEAP_VALIDATE
// Prints a mark-cycle validation failure, `what` and the address `p`, to stderr and aborts.
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
    // IM13: during a mark cycle no worker cursor may take a block that
    // existed when the cycle started.
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

// Runs outside promo_mu_. Everything it writes is private to this worker or
// atomic: the header and slack (the cell is this worker's), the mark bit (an
// atomic fetch_or, since markers may set other bits of the byte), the block's
// live_bytes (an atomic add) and the worker's charges.
// TLA-REGION(OGS.finalizePoppedCellW) begin
void* OldGenSpace::finalizePoppedCellW(FreeCell* cell, size_t cls, size_t requested_size,
                                       PromoWorker& pw) {
    void* result = static_cast<void*>(cell);
    const size_t cell_size = classToSize(cls);
    Header* hdr = reinterpret_cast<Header*>(result);
    std::memset(hdr, 0, sizeof(Header));
    // Outside promo_mu_, so a relaxed atomic_ref load, matching the sweep
    // completion's relaxed atomic_ref store.
    const bool black = marking_active ||
        std::atomic_ref<GCPhase>(gc_phase_).load(std::memory_order_relaxed) != GCPhase::Idle;
    // The live_bytes add runs in every phase; only the test hook
    // test_idle_uncounted_ skips it at Idle.
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
            // Atomic: other workers finalize cells of the same block at once.
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
    // A plain set: the cursor's cells are this worker's alone, and during a
    // cycle its block was created after the cycle started (IM13), so no
    // marker writes these bitmap bytes.
    if (!test_skip_allocate_black_)
        bitscan::setBit(c.bits, static_cast<size_t>(k) * c.stride_bits);
    ECO_M4_TRACE("m4.set", "cb", c.cell_bytes, "blk", c.block.v, "c", static_cast<size_t>(k) * c.stride_bits);
    Header* hdr = reinterpret_cast<Header*>(p);
    std::memset(hdr, 0, sizeof(Header));
    // Lock-free, so a relaxed atomic_ref load of gc_phase_.
    hdr->color = static_cast<u32>(
        (marking_active ||
         std::atomic_ref<GCPhase>(gc_phase_).load(std::memory_order_relaxed) != GCPhase::Idle)
            ? Color::Black : Color::White);
    // Traces the phase this decision read (Sweeping outside a cycle).
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
    // With one worker the block is retired here; with chunks, the shared
    // block is retired under the lock by advanceSharedW.
    if (!promo_ctx_->chunked) blocks_.info(c.block).alloc_state = kAllocNone;
    c = AllocCursor{};
    return nullptr;
}
// TLA-REGION(OGS.cursorAllocateW) end

// The claim is a CAS that adds the worker's claim size, in units, to the low
// half of the claim word; each successful claim doubles the next one, up to
// kChunkMaxUnits.
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
    // Traced after the store, so a reader that loaded the old value is not
    // timestamped after it.
    ECO_M4_TRACE("m4.pub", "cb", classToSize(cls), "blk", id.v, "rmw", ::Elm::tlatrace::key("sh", cls),
                 "old", m4_old, "new", (static_cast<uint64_t>(id.v) + 1) << 32);
}
// TLA-REGION(OGS.publishShared) end

// Returns true at once when the shared block still has a chunk (another worker
// may have advanced it). An exhausted block is retired to kAllocNone even if
// the workers' last chunks still have free cells; endParallelPromotion
// re-queues it then.
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

// The rungs are in allocateFromSizeClassBitmap's order; only the new-block
// rungs differ, feeding the worker's cursor or, with chunks, the shared block.
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

// With one worker nothing runs concurrently, so worker 0's counts and cursors
// are handed back to this object, onSweepComplete runs where allocate() would
// run it, and the cursors are taken again.
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
    pm6_skip_ = true;   // onSweepComplete changes allocated_bytes, so PM6 cannot balance
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
    v11_deferred_.clear();
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
    // Unused stashed cells go back onto their class free lists. They were
    // popped but never made objects, and the sweep has already passed them.
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
                if (k < c.num_cells) requeueFront(cls, c.block);   // reused before any new block
                else blocks_.info(c.block).alloc_state = kAllocNone;
                c = AllocCursor{};
            }
        }
    } else {
        bool kept_one = false;   // test hook: leave one shared block Current, unowned
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
            // re-queued at the front, to be reused before any new block.
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
    // V11 for the gap-swept blocks completed inside this
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
        // An object at least a block long: allocate()'s large path, under
        // the lock.
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
    // The same lazy-sweep slice allocate() runs per promotion.
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
        // With chunks: the next chunk of the shared block, lock-free.
        if (promo_ctx_->chunked) {
            while (claimChunkW(cls, c, pw)) {
                if ((result = cursorAllocateW(c, size, pw)) != nullptr) goto done;
            }
        }
        // Rung 2 from the stash. A non-empty stash means partial_[cls] was
        // already empty in this minor, and nothing refills it mid-minor, so
        // taking a stashed cell before the lock keeps the ladder order.
        if (pw.stash_n[cls] != 0) {
            popped = pw.stash[cls][--pw.stash_n[cls]];
#if ECO_HEAP_VALIDATE
            // PM8: a stashed cell is finalized outside
            // promo_mu_, so no gap sweep may still read or clear its block's
            // mark words: while a sweep is pending its block is fully swept.
            // (Outside Sweeping blocks may be !fully_swept - a mark resets it,
            // a block made at Idle starts so - but no sweeper runs, and nothing
            // sets Sweeping inside a minor.) gc_phase_ is read outside the
            // lock here, so atomically.
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
            // A cell of a block the gap sweep has not
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
    // The gap sweep and the cursor never read dead headers, so dead bodies
    // are retired here, before any cell can be reused; otherwise a later
    // freeLargeBodyCell would free a reclaimed cell a second time. Bodies in
    // is_large blocks are handled by classifyBlocksAfterMark.
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
        if (b.los & kLosBlock) {
            // An LOS block's dead objects were freed at mark end
            // (losSweepAtMarkEnd); nothing to classify.
            meta.fully_swept = true;
            continue;
        }
        if (b.is_large) {
            const bool live = testAndClearMarkBitInBlock(id, b.start);
            if (!live) {
                // A pinned header (a split-header body or a young large
                // object) or a raw block, which has no header, may have an
                // index entry, whatever the tag.
                const bool tracked = (b.los & kLosRaw) != 0 ||
                                     reinterpret_cast<Header*>(b.start)->pin;
                if (tracked) {
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
                // (A deferred free at the handoff may have queued it already
                // through freeUniformCell.)
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
    // Dead young large objects were retired above, on both paths.
    recomputeYoungLargeBounds();
#if ECO_HEAP_VALIDATE
    // V12: every surviving nursery-owned body is marked.
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
    // Background markers call this while the mutator adds blocks: the region
    // bounds are relaxed atomic loads (they only grow during a cycle), and the
    // committed count and the owner words are acquire loads.
    if (p < regionBase() || p >= regionEnd()) return NO_BLOCK_ID;
    const size_t page =
        static_cast<size_t>(p - index_base_) / config_->alloc_buffer_size;
    if (page < page_index_.committed()) {   // never read an uncommitted slot
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

void *OldGenSpace::allocate(size_t size) {
#if ECO_HEAP_VALIDATE
    const DecisionScope im16(*this);   // IM16: the allocation ladder decides
#endif
    size = (size + 7) & ~7;  // Align to 8 bytes.

    // Recorded before the dispatch, so a request that fails still counts as demand.
    GC_STATS_OLDGEN_RECORD_ALLOC(alloc_stats_, size);

    // The whole call, sweep and shrink work included, is timed into the mutator's old-gen
    // allocation time, so that wall time = minor + major + nursery allocation + old-gen allocation
    // + the mutator's own. A call made while a minor collection is in progress is a promotion, which
    // the minor collection's own timer already covers, and it is not timed, which saves two clock
    // reads per promoted object.
#if ENABLE_GC_STATS
    const bool timed = !in_minor_gc_;
    std::chrono::high_resolution_clock::time_point helper_t0;
    if (timed) {
        helper_t0 = GC_STATS_TIMER_START();
    }
#endif

    // CR-027: allocation never drives marking. A mark cycle advances in its own steps, and a
    // stop-the-world mark runs inside its pause.

    // Drive lazy sweep work so that free lists fill up before the bag runs out. Without this, all
    // the bag's pages can be used before the sweep returns any garbage to a free list.
    if (gc_phase_ == GCPhase::Sweeping) {
        // A promotion's sweep work lands inside the minor pause, so it is divided by
        // minor_sweep_divisor, where 0 skips it. Skipping it lets the heap grow while unswept
        // garbage remains.
        size_t budget = config_->sweep_work_budget;
        if (in_minor_gc_) {
            const size_t d = config_->minor_sweep_divisor;
            budget = (d == 0) ? 0 : budget / d;
        }
        if (budget > 0) {
            size_t cls_for_sweep = sizeClass(size);
#if ENABLE_GC_PHASE_TIMERS
            // Measurement only: the promotion path's sweep bytes, exactly, and its time, sampled.
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

    // The dispatch can itself sweep: allocateFromSizeClass and allocateFromBagPage can run lazy-sweep
    // slices.
    void* result;
#if ENABLE_GC_PHASE_TIMERS
    // Samples the dispatch's own cost per promotion. The sweep slice above is measured separately,
    // so the two do not overlap.
    const bool sample_alloc = in_minor_gc_ && promo_instr_.alloc.shouldSample();
    const uint64_t t_alloc0 = sample_alloc ? GCStats::nowSinceProcessStartNs() : 0;
#endif
    if (size >= config_->alloc_buffer_size) {
        // A block of its own.
        result = allocateLargeBlock(size);
    } else {
        size_t cls = sizeClass(size);
        if (cls < num_size_classes_) {
            // A size class.
            result = allocateFromSizeClass(cls, size);
        } else {
            // Above the largest class in use, below a page: cut from a free cell or a page.
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
    if (cycleActive()) noteCycleAllocation(result);   // IM4
#endif

    return result;
}

// ---------------------------------------------------------------------------
// Slack after an object in its cell.
// ---------------------------------------------------------------------------

// Writes a free-cell header over the slack between the end of an object of `requested_size`
// bytes, rounded up to 8, at `obj` and the end of its `cell_size`-byte cell, when the slack can
// hold a header. The header is linked into no free list and has age 0, so a later sweep may merge
// it.
//
// A walk over a mixed block steps by each object's own size, so without the header it would land
// in the slack and read whatever is there as an object. A walk over a uniform block steps by the
// cell size and never reads it, but the block may later be demoted to mixed.
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
}

// ---------------------------------------------------------------------------
// Size-class fast path.
// ---------------------------------------------------------------------------

// TLA-REGION(OGS.tryPopFromFreeList) begin
FreeCell* OldGenSpace::tryPopFromFreeList(size_t cls) {
    assert(cls < NUM_SIZE_CLASSES);
    FreeCell* cell = free_lists_[cls];
    if (cell == nullptr) return nullptr;
    free_lists_[cls] = cell->next_in_class;
    if (isTierM(cell)) {
        // Mark the new head as the head, and unlink the popped cell from its block's list.
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

// TLA-REGION(OGS.finalizePoppedCell) begin
void* OldGenSpace::finalizePoppedCell(FreeCell* cell, size_t cls,
                                      size_t requested_size) {
    void* result = static_cast<void*>(cell);
    const size_t cell_size = classToSize(cls);
    initObjectHeaderWithSize(result, cell_size);
    // M4 trace of a pop under the lock: the colour is the one initObjectHeaderWithSize chose.
    ECO_M4_TRACE("m4.pop", "cb", cell_size, "blk", ECO_M4_BLK(result), "c", ECO_M4_BIT(result),
                 "black", getHeader(result)->color == static_cast<u32>(Color::Black), "rd", "phase",
                 "val", getHeader(result)->color == static_cast<u32>(Color::Black)
                     ? static_cast<int>(cycle_state_ != CycleState::Idle ? GCPhase::Marking : GCPhase::Sweeping) : 0);
    padCellSlack(result, requested_size, cell_size);
    allocated_bytes += cell_size;
    old_alloc_total_ += cell_size;
    return result;
}
// TLA-REGION(OGS.finalizePoppedCell) end

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

// HEAP_043: the denominator is the Allocator's cap, not one derived here from the configuration,
// which can differ from it. The configuration's is used only when there is no Allocator.
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

size_t OldGenSpace::computeSweepBudgetForAlloc(size_t requested_size) const {
    const HeapConfig& cfg = *config_;

    // Base: bytes per allocated byte, clamped to [sweep_work_budget, max_sweep_bytes_per_alloc].
    // Less than sweep_work_budget would not cover one slice; the upper clamp applies before the
    // pressure scaling.
    double base = static_cast<double>(requested_size) *
                  cfg.sweep_bytes_per_alloc_byte;
    if (base < static_cast<double>(cfg.sweep_work_budget)) {
        base = static_cast<double>(cfg.sweep_work_budget);
    } else if (base > static_cast<double>(cfg.max_sweep_bytes_per_alloc)) {
        base = static_cast<double>(cfg.max_sweep_bytes_per_alloc);
    }

    // A step function of the pressure, committed bytes over the old-generation cap.
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

    // While most blocks are unswept, free space is more likely to be found by sweeping than by
    // growing, so the budget is raised.
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

// Each slice is charged its whole budget, even when the sweep finishes partway through it, so the
// bytes counted may exceed the bytes swept.
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
    // Bitmap mode has its own ladder.
    if (config_->old_gen_bitmap_alloc) {
        return allocateFromSizeClassBitmap(cls, requested_size);
    }

    // (1) Exact-fit pop from free_lists_[cls]. No splitting yet.
    if (FreeCell* cell = tryPopFromFreeList(cls)) {
        return finalizePoppedCell(cell, cls, requested_size);
    }

    // (2) A new block first, for a small class under the budget.
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

    // (5) Pull a page from the bag and slice it into cells of the class.
    if (populateFromBlock(cls)) {
        if (FreeCell* cell = tryPopFromFreeList(cls)) {
            return finalizePoppedCell(cell, cls, requested_size);
        }
    }

    // (6) Last resort: allocateFromBagPage, which accounts for its own bytes.
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
    // Only the classes from num_size_classes_ up are walked. Uniform blocks exist only for the
    // classes below, so these cells lie in mixed blocks, which a walk steps through by object
    // size, and cutting one leaves its block parseable. A cell of a lower class may lie in a
    // uniform block, which a walk steps through by cell size, and finding out would cost a block
    // search per cell. When `target_cls` is itself above the uniform classes the walk starts at
    // it, so an exact fit of that class is found too.
    //
    // A cell is taken when it fits exactly or leaves at least a minimal free cell.
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
                // Every class walked has cells of at least MIN_TIER_M_SIZE, so `curr` is a
                // FreeCellMid.
                FreeCell* next_in_class = curr->next_in_class;
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
                    // Mark the remainder as already on a list while its block is still to be
                    // swept; otherwise the sweep would merge over it and push the same bytes a
                    // second time, making a cycle in the free list.
                    bool need_sentinel =
                        (gc_phase_ == GCPhase::Sweeping) &&
                        (!blk_id.valid() ||
                         !blocks_.meta(blk_id).fully_swept);
#if ECO_HEAP_VALIDATE
                    PushOriginScope _origin("splitter::remainder");
#endif
                    // In bitmap mode no list cell lies where the sweep has still to walk, so the
                    // remainder never needs the mark.
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
                old_alloc_total_ += alloc_size;
                return result;
            }

            prev = &curr->next_in_class;
            curr = curr->next_in_class;
        }
    }

    return nullptr;
}

// ---------------------------------------------------------------------------
// Requests above the size classes, and the last rung of the class ladders.
// ---------------------------------------------------------------------------
// TLA-REGION(OGS.allocateFromBagPage) begin
void* OldGenSpace::allocateFromBagPage(size_t requested_size) {
    // Free space is reused before a page is taken: first a cut from the free lists of the classes
    // only mixed blocks use, which the sweep and demotion fill; then bounded lazy sweep, retrying
    // after each slice; then a fresh page.

    const size_t request_cls = sizeClass(requested_size);
    // CR-029: the request may be of any size below a page, including one that fits a size class.
    // Every step cuts exactly `requested_size` bytes from a mixed block and returns the rest as
    // free cells. A mixed block is walked, and its live bytes counted by the mark, by each
    // object's own size, so a cut smaller than a class's cell leaves the block parseable and its
    // live_bytes exact.
    assert(requested_size < config_->alloc_buffer_size &&
           (requested_size & 7) == 0 &&
           "allocateFromBagPage: request must be 8-byte aligned and below alloc_buffer_size");

    // Step 1: an exact fit or a cut from the mixed-only classes (tryAllocateBySplittingLarger). The cut is
    // exactly `requested_size`, so no slack is left.
    if (void* result =
            tryAllocateBySplittingLarger(request_cls, requested_size)) {
        return result;
    }

    // Step 2: bounded lazy sweep, retrying step 1 after each slice. The sweep merges dead spans into
    // larger free cells. The budget is the one sweepOnDemandAllocate uses.
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

    // Step 3: a page from the bag, acquired from the Allocator if the bag is empty, made a mixed
    // block holding one free cell, from whose front the request is cut.
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

    char* alloc_base = page_start;
    const size_t alloc_span = page_size;
    assert(requested_size <= alloc_span &&
           "allocateFromBagPage: request larger than usable page span");

    // The sweep parses up to end_of_objects: the page end, so the free cell below and every later
    // cut of it parse.
    BlockInfo bi;
    bi.start = page_start;
    bi.end = page_end;
    bi.end_of_objects = page_end;
    bi.size_class = NUM_SIZE_CLASSES;  // mixed/non-uniform
    bi.is_large = false;
    // Mid-cycle, the block is marked swept, so the lazy sweep does not rewrite the free cells
    // placed here.
    const bool mid_cycle =
        marking_active || gc_phase_ != GCPhase::Idle;
    const BlockId block_idx =
        materializeBlock(bi, {0, 0, mid_cycle}, bitmapBytesForBlock(bi));

    // The page as one free cell, from whose front the request is cut.
    FreeCell* whole = reinterpret_cast<FreeCell*>(alloc_base);
    std::memset(&whole->header, 0, sizeof(Header));
    whole->header.tag = Tag_Free;
    whole->header.size = static_cast<u32>(alloc_span);
    whole->header.color = static_cast<u32>(Color::White);

    // CR-033 (HEAP_024): every non-zero remainder goes through the pusher, which in a mixed block
    // places cells of class sizes and gives a tail too small for a list an unlinked free-cell
    // header, so the page parses by object size up to end_of_objects.
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
    old_alloc_total_ += requested_size;
    return result;
}
// TLA-REGION(OGS.allocateFromBagPage) end

// ---------------------------------------------------------------------------
// Population from a bag page (uniform fixed-cell slicing for a class).
// ---------------------------------------------------------------------------
bool OldGenSpace::populateFromBlock(size_t cls) {
    // In bitmap mode new blocks take this function's place on the ladder.
    assert(!config_->old_gen_bitmap_alloc &&
           "populateFromBlock reached in bitmap-allocation mode");
    // An empty bag: acquire a page from the Allocator, if the old generation may still grow.
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
    if (cell_bytes < MIN_FREE_CELL_SIZE) return false;

    auto extent = unassigned_blocks_.back();
    unassigned_blocks_.pop_back();

    char* page_start = extent.first;
    char* page_end = extent.second;
    const size_t page_size = static_cast<size_t>(page_end - page_start);

    const size_t num_cells = page_size / cell_bytes;

    if (num_cells == 0) {
        // A cell larger than the page: give the page back.
        unassigned_blocks_.push_back(extent);
        return false;
    }

    // end_of_objects is the end of the last whole cell; bytes after it are not parsed.
    BlockInfo bi;
    bi.start = page_start;
    bi.end = page_end;
    bi.end_of_objects = page_start + num_cells * cell_bytes;
    bi.size_class = cls;
    bi.is_large = false;
    // Mid-cycle, the block is marked swept, so the lazy sweep does not merge the listed free cells
    // placed here, which would overwrite their headers under the list links.
    const bool mid_cycle =
        marking_active || gc_phase_ != GCPhase::Idle;
    const BlockId block_idx =
        materializeBlock(bi, {0, 0, mid_cycle}, bitmapBytesForBlock(bi));

    // Pushed in reverse, so the list runs in address order. The cells have age 0, not the
    // on-a-list mark: mid-cycle the sweep skips the block, and otherwise it may merge them.
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

        free_large_blocks_[k] = free_large_blocks_.back();
        free_large_blocks_.pop_back();

        // Resurrect the BlockInfo: parseable region covers just the new
        // object so sweep walks one header.
        const size_t total = blk.totalBytes();
        blk.end_of_objects = blk.start + size;
        // Reused as a headered block; allocateRawCell marks it raw again if it takes it.
        blk.los = 0;

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
        old_alloc_total_ += size;

        initObjectHeader(blk.start);
        return static_cast<void*>(blk.start);
    }
    return nullptr;
}

// TLA-REGION(OGS.allocateFromEmptyRegularBlocks) begin
void* OldGenSpace::allocateFromEmptyRegularBlocks(size_t size) {
    // CR-016 (HEAP_054): with more than one promotion worker, live_bytes == 0 does not show a block
    // is empty: its cells may be in another worker's claimed chunk or stash, not yet counted. One
    // worker has neither, and flushes before it retires a block.
    if (par_promo_active_ && promo_ctx_ && promo_ctx_->n > 1) {
#if ENABLE_GC_STATS
        alloc_stats_.bm.flip_skipped_parallel++;
#endif
        return nullptr;
    }
    syncCursorLiveBytes();   // live_bytes is read below
    size = (size + 7) & ~7;

    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        const BlockId i = blocks_.idAt(pos);
        const BufferMetadata& meta = blocks_.meta(i);
        if (!meta.fully_swept || meta.live_bytes != 0) continue;
        if (blocks_.info(i).is_large) continue;
        if (blocks_.info(i).los != 0) continue;   // LOS blocks are the LOS's
        // A worker cursor's block may read live_bytes 0 with bytes still pending, and detach
        // cannot see the cursor.
        if (par_promo_active_ && blocks_.info(i).alloc_state == kAllocCurrent) continue;
        // A granted block reads live_bytes 0 until it is returned; its tenure job may be filling it.
        if (blocks_.info(i).alloc_state == kAllocTenure) continue;
        if (blocks_.info(i).totalBytes() < size) continue;

        // Take the block's free cells off the lists before it becomes large.
        if (config_->old_gen_bitmap_alloc) detachFromAllocation(i);
        removeFreeCellsForBlock(i);
        // CR-035 (HEAP_056): the new object takes the block's start, so a large-object index entry
        // still inside the block could name it, and its later free would erase the new object's
        // entry. Every entry in the block is retired, as retireDeadLargeBodies does.
        {
            const BlockInfo& fb = blocks_.info(i);
            const size_t retired = retireIndexRange(fb.start, fb.end);
            (void)retired;
#if ENABLE_GC_STATS
            alloc_stats_.bm.empty_block_flips++;
            alloc_stats_.bm.flip_index_retired += retired;
#endif
#if ECO_HEAP_VALIDATE
            // As in releaseBlockToAllocator: no entry may still resolve into the flipped block.
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

        // Debit the small-class budget, if this was a small-class uniform block, while size_class
        // still says so.
        onBlockTransitioningToLarge(i);

        BlockInfo& blk = blocks_.info(i);
#if ECO_HEAP_VALIDATE
        // H9: only a block made after t0 may change is_large while markers run.
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
        // A large block's liveness is its large-mark byte, not a bitmap.
        mark_.drop(i);
        blocks_.largeMark(i) = 0;

        frag_stats_.live_bytes += size;
        allocated_bytes += size;
        old_alloc_total_ += size;

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

    // 3) Acquire a fresh block from the Allocator. acquireOldGenBlock advances a bump cursor by the
    // size asked for, so the size is rounded up to OS_PAGE_SIZE to keep the next acquire aligned.
    constexpr size_t kPageSize = OS_PAGE_SIZE;
    size_t block_size = (size + kPageSize - 1) & ~(kPageSize - 1);

    // CR-007: with more than one promotion worker the no-wait policy applies.
    char* block_base = allocator_->acquireOldGenBlock(block_size, acquireWaitPolicy());
    if (block_base == nullptr) {
        return nullptr;
    }

    // end_of_objects is the end of the one object, so the sweep reads only its header.
    BlockInfo bi;
    bi.start = block_base;
    bi.end = block_base + block_size;
    bi.end_of_objects = block_base + size;
    bi.size_class = NUM_SIZE_CLASSES;
    bi.is_large = true;
    // Mid-cycle, the block is marked swept, so the lazy sweep does not reset the black header.
    const bool mid_cycle_large =
        marking_active || gc_phase_ != GCPhase::Idle;

    // The bounds grow before the block is materialized, so the page index is committed through
    // the new end when the block's slots are assigned.
    if (char* const rb = regionBase(); rb == nullptr || block_base < rb) {
        setRegionBase(block_base);
    }
    if (block_base + block_size > regionEnd()) {
        setRegionEnd(block_base + block_size);
    }
    resizePageIndexForRegion();
    // A large block's liveness is its large-mark byte, so its bitmap slot has length 0.
    materializeBlock(bi, {size, 0, mid_cycle_large}, 0);

    allocated_bytes += size;
    old_alloc_total_ += size;

    initObjectHeader(block_base);
    return static_cast<void*>(block_base);
}
// TLA-REGION(OGS.allocateLargeBlock) end

void OldGenSpace::prepareMark(Allocator &alloc) {
    // Finish the previous collection's lazy sweep first: a mark that began over half-rebuilt free
    // lists and block metadata would have its own end-of-mark work run against them.
    if (gc_phase_ == GCPhase::Sweeping) {
        while (gc_phase_ == GCPhase::Sweeping) {
            lazySweep(NUM_SIZE_CLASSES,
                      std::numeric_limits<size_t>::max() / 2);
        }
    }

    // Every mark bit is cleared here rather than trusted to be zero: a cell allocated during the
    // lazy sweep, in a block the sweep had passed, keeps its bit. The next mark would stop at such
    // a cell as already marked, without counting its bytes, and a block holding only such cells
    // would look dead and be released under objects still in use. HEAP_050: clearForMark zeroes
    // every live block's slot and large-mark byte, and gives the memory of slots no live block uses
    // back to the OS.
    mark_.clearForMark(blocks_);
    // The bitmap is cleared, so every cursor position and queue entry is stale.
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
    mark_parallel_ = false;   // beginMarkCycle may set it
    nursery_visited_.clear();

    // Store Allocator reference for nursery checks during marking.
    allocator_ref_ = &alloc;

    // The mark counts each block's live bytes from zero; a block still at zero after it is dead.
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
    assert(!cycleActive() && "startMark during an incremental mark cycle");
    if (marking_active)
        return;

    prepareMark(alloc);

    // markHPointer skips embedded constants, and records nursery objects in nursery_visited_
    // rather than in their header colour, which a major collection must not write.
    for (HPointer *root: roots) {
        markHPointer(*root);
    }

    // JIT roots hold raw addresses, not HPointer encodings.
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
// The marker. The mark path is written once, as templates over SerialMark and
// ParallelMark. SerialMark uses plain bit operations, keeps its grey set on
// slot 0's stack, and may traverse nursery objects. ParallelMark uses atomic
// bit operations, and its grey set is the slots' private stacks and
// work-stealing deques. mark_parallel_ selects the path for the current mark.
// ===========================================================================

// TLA-REGION(OGS.resolveMarkThreads) begin
unsigned OldGenSpace::resolveMarkThreads(const HeapConfig& cfg) {
    // Parallel marking runs only in mark cycles, which require bitmap
    // allocation.
    if (!cfg.old_gen_bitmap_alloc) return 1;
    unsigned n = cfg.gc_mark_threads;
    if (n == 0) n = std::min<unsigned>(cfg.gc_mark_threads_cap, gc::availableCpus());
    if (n > kMaxMarkers) n = kMaxMarkers;
    return n == 0 ? 1 : n;
}
// TLA-REGION(OGS.resolveMarkThreads) end

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
    // Each minor worker promotes through its own bitmap-allocation cursor.
    if (!cfg.old_gen_bitmap_alloc) return 1;
    unsigned n = cfg.gc_minor_threads;
    if (n == 0) n = std::min<unsigned>(cfg.gc_minor_threads_cap, gc::availableCpus());
    if (n > kMaxMinorWorkers) n = kMaxMinorWorkers;
    return n == 0 ? 1 : n;
}
// TLA-REGION(OGS.resolveMinorThreads) end

// TLA-REGION(OGS.resolveConcMarkThreads) begin
unsigned OldGenSpace::resolveConcMarkThreads(const HeapConfig& cfg, unsigned fg) {
    // With conc_mark_threads == 0 (auto), the count is cpus - 1 (at least 1),
    // capped by conc_mark_threads_cap.
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
    assertSlotsQuiescent("ensureMarkers");   // slots are created and destroyed here
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
    assertSlotsQuiescent("markLiveTake", 0, mark_slots_);   // every slot's accumulator is read
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
    // The sums are integers, so the result does not depend on how the mark
    // was split among slots.
#if ECO_HEAP_VALIDATE
    assertSlotsQuiescent("markLiveMergeAll", 0, mark_slots_);   // every slot's accumulator is read
#endif
    for (unsigned i = 0; i < mark_slots_; ++i) {
        if (i == 1 && test_skip_merge_worker1_) continue;   // test switch: skip slot 1
        markers_[i]->live.mergeInto(blocks_);
    }
#if ECO_HEAP_VALIDATE
    // Every accumulator must be drained here. The same check in
    // resetBufferMetaForMark runs only if another mark follows.
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
    // Only atomics (deque indices and published private sizes), never a
    // slot's private stack, which its owner may be changing.
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
    if (id.valid() && blocks_.info(id).alloc_state == kAllocTenure) {   // TV8
        std::fprintf(stderr, "[heap-validate] TV8: a marker marked %p in tenure-granted block %u\n",
                     obj, id.v);
        std::fflush(stderr);
        std::abort();
    }
#endif
    if constexpr (!P::kParallel) {
        return testAndSetMarkBitInBlock(id, obj);
    } else {
        if (__builtin_expect(test_plain_bits_parallel_, 0)) {   // test switch: plain bits
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
    // The mark never writes a nursery header, and the mark bitmaps cover
    // only the old generation, so nursery objects reached on the serial path
    // are deduplicated through nursery_visited_.
#if ECO_HEAP_VALIDATE
    // HEAP_053: the bound nursery must be the calling thread's heap's. Only
    // checked on the serial path: a gang thread has no tl_heap_.
    if constexpr (!P::kParallel) {
        assert(nursery_->contains(obj) == allocator_ref_->isInNursery(obj) &&
               "HEAP_053: bound nursery disagrees with tl_heap_'s nursery");
    }
#endif
    if constexpr (P::kParallel) {
        // A parallel marker may run beside the mutator, so it reads only the
        // t0 view, never the live nursery bounds, the cycle state or the
        // young-large-object index. Reaching a nursery object is a bug, and
        // every build aborts on it.
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
        // In the t0 snapshot, young objects are walked by the snapshot itself
        // and skipped here. After t0 a mark slice must never reach one (IM3).
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
            // In region mode, a tenuring object whose job has merged dies at
            // the next minor, so its old-generation copy is greyed instead.
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

    // Setting the mark bit makes an old object grey, and scanning its popped
    // entry makes it black. The bit stays set until the sweep clears it.
    if (!contains(obj)) return;
    const BlockId block_id = blockIdFor(obj);
    if (!block_id.valid()) return;

    if (testAndSetMark<P>(block_id, obj)) return;
    // A header-less large body is pointer-free: the bit is all its marking.
    if (__builtin_expect(blocks_.info(block_id).los & kLosRaw, 0)) return;
    // Trace builds record a grey only inside a cycle; outside one, greying is
    // a stop-the-world major's.
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
            if ((hdr->unboxed & 0x3) == 0) {
                ListBacking *lb = static_cast<ListBacking *>(obj);
                const u32 hd = lb->hd;
                const u32 len = hdr->size > hd ? hdr->size - hd : 0;
                const bool snap = !P::kParallel && snapshot_mode_;   // never chunked at t0
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
            // Header-bitmap slots, then the slots whose kinds are in the ext
            // kind words at the object's tail.
            Custom *c = static_cast<Custom *>(obj);
#if ECO_HEAP_VALIDATE
            validateExtKinds(obj, "OldGenSpace::scanChildren");
#endif
            const u32 n = hdr->size, h = n < CUSTOM_HDR_SLOTS ? n : CUSTOM_HDR_SLOTS;
            for (u32 i = 0; i < h; i++) greyU(c->values[i], kindInWord(c->unboxed, i) == 0);
            for (u32 i = h; i < n; i++) greyU(c->values[i], customSlotKind(c, i) == 0);
            break;
        }
        case Tag_Record: {
            Record *r = static_cast<Record *>(obj);
#if ECO_HEAP_VALIDATE
            validateExtKinds(obj, "OldGenSpace::scanChildren");
#endif
            const u32 n = hdr->size, h = n < RECORD_HDR_SLOTS ? n : RECORD_HDR_SLOTS;
            for (u32 i = 0; i < h; i++) greyU(r->values[i], kindInWord(r->unboxed, i) == 0);
            for (u32 i = h; i < n; i++) greyU(r->values[i], recordSlotKind(r, i) == 0);
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
            // Only the applied slots, [0, n_values), are traced. hdr->size is
            // the capacity plus the ext kind words, and slots from n_values
            // to the capacity are unapplied argument space that may be
            // uninitialised. NurserySpace::scanObject's Tag_Closure arm states
            // the rule every value-slot writer must keep.
            Closure *cl = static_cast<Closure *>(obj);
            for (u32 i = 0; i < cl->n_values; i++) {
                greyU(cl->values[i], closureSlotKind(cl, i) == 0);
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
            // A boxed array longer than MARK_CHUNK_ELEMS greys its first chunk
            // here and pushes the rest as chunk entries.
            ElmArray *arr = static_cast<ElmArray *>(obj);
            if ((arr->header.unboxed & 0x3) != 0) break;   // unboxed: no children
            const u32 n = arr->length;
            // Never chunk in the t0 snapshot: a young object (YLOS array) must
            // be scanned completely at t0 -- it can die, be freed or promoted
            // after t0, and a slice must never read a young object (IM3).
            const bool snap = !P::kParallel && snapshot_mode_;
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
    // No live bytes: the object's were attributed when its own entry was
    // scanned.
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
#if ECO_HEAP_VALIDATE
    if (isRawBody(obj)) {
        std::fprintf(stderr, "[heap-validate] HEAP_081: scanObject on a header-less body %p\n", obj);
        std::fflush(stderr);
        std::abort();
    }
#endif
    Header* hdr = getHeader(obj);

    // Defensive: stale mark-stack entry pointing at a free cell or a
    // forwarding pointer (compaction can leave Tag_Forward stubs behind
    // until fixup completes).
    if (hdr->tag == Tag_Free || hdr->tag == Tag_Forward) return false;

#if ECO_HEAP_VALIDATE
    // HEAP_044: nullary constructors are embedded constants, so a live
    // 0-field Tag_Custom means a construction path missed the embedding.
    assert(!(hdr->tag == Tag_Custom && hdr->size == 0) &&
           "HEAP_044: live 0-field Tag_Custom — nullary ctors must be "
           "embedded null-cons constants");
#endif

    // A nursery object (serial path only): grey its children, but write no
    // header and attribute no bytes. greyObject breaks cycles through
    // nursery_visited_.
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
    // HEAP_BUILDER_001: a builder object is a nursery or young large
    // object, never an old one. The serial path reads the live young-large
    // index, which is safe because the mutator is paused.
    if constexpr (P::kParallel) {
        // The t0 copy of the young-large set, never the live index.
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

    // A uniform block's step is its class size; only a mixed block needs the
    // object's own size.
    const BlockInfo& blk = blocks_.info(blk_idx);
    const size_t step = (blk.size_class < NUM_SIZE_CLASSES)
        ? OldGenSpaceTestAccess::classToSize(blk.size_class)
        : getObjectSize(obj);
    // HEAP_051: each marker adds to its own accumulator only;
    // markLiveMergeAll folds them into the blocks' live_bytes.
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
    // Trace builds record object entries only, not chunks.
    ECO_TLA_TRACE_ONLY(if (cycle_state_ != CycleState::Idle))
        ECO_TLA_TRACE("scan", "obj", ::Elm::tlatrace::obj(obj),
                      "get", ::Elm::tlatrace::key("g", obj, ::Elm::tlatrace::bound(this, 1)));
    (void)scanObject<P>(w, obj, f != 0 ? BlockId{f - 1} : NO_BLOCK_ID);
}
// TLA-REGION(OGS.scanEntry) end

/**
 * The environment markwork::runMarkerLoop runs the serial mark in: slot 0's
 * stack, with nothing to steal and nothing to publish.
 */
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
// The environment markwork::runMarkerLoop runs the parallel mark in. A member
// takes from its slot's private stack first, then from its deque, and steals
// from any slot's deque.
struct OldGenSpace::ParallelEnv {
    static constexpr bool kParallel = true;
    OldGenSpace& og;
    markwork::MarkerCounters& counters(unsigned i) { return og.markers_[i]->ctr; }
    uint64_t takeOwn(unsigned i) {
        MarkWorker& w = *og.markers_[i];
        if (!w.stack.empty()) {                  // private first: no fence
            const uint64_t e = w.stack.back();
            w.stack.pop_back();
            w.priv.store(w.stack.size(), std::memory_order_relaxed);
            if ((++w.pops & 63) == 0) og.publishHalf(w);
            return e;
        }
        return w.deque.take();
    }
    uint64_t stealFrom(unsigned v) { return og.markers_[v]->deque.steal(); }
    // Private stacks count as work, although only their owning marker can
    // pop them.
    bool anyWork() {
        for (unsigned i = 0; i < og.mark_slots_; ++i) {
            const MarkWorker& w = *og.markers_[i];
            if (!w.deque.emptyApprox() || w.priv.load(std::memory_order_relaxed) != 0) return true;
        }
        return false;
    }
    void prefetch(uint64_t e) { __builtin_prefetch(markwork::entryAddr(e), 0, 3); }
    void scan(unsigned self, uint64_t e) { og.scanEntry<ParallelMark>(*og.markers_[self], e); }
    // IM15: called at every exit of a run, so no private work outlives it.
    void publishAll(unsigned self) {
        if (__builtin_expect(og.test_leave_private_on_exit_, 0)) return;   // test switch
        og.publishAll(*og.markers_[self]);
    }
};
// TLA-REGION(OGS.ParallelEnv) end

namespace {
/**
 * What markerEntry receives through the gang's context pointer. `og` is the
 * space; this struct and `c` live in runMarkers's frame and are valid for
 * its gang.run call.
 */
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
        assertSlotsQuiescent("a serial run", 0, 1);   // the mutator owns slot 0
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
        // Every slot, background deques included, may be stolen from; only
        // the mark_threads_ foreground members take part.
        markwork::SliceControl c(budget, mark_slots_, jitter, mark_threads_);
        c.steal_without_ticket = test_steal_without_ticket_;
#if ECO_HEAP_VALIDATE
        assertSlotsQuiescent("a foreground run's counter reset", 0, mark_threads_);
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
        // Outgrown deque arrays are freed only when no background marker can
        // still be reading one.
        if (bg_ep_ != BgEpisode::Running) retireAllDequeArrays();
#if ECO_HEAP_VALIDATE
        assertSlotsQuiescent("a foreground run's counter merge", 0, mark_threads_);
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
    // Every unit used inside a cycle counts toward its pacing.
    if (cycle_state_ != CycleState::Idle) cycle_units_ += units;
    return units;
}
// TLA-REGION(OGS.runMarkers) end

#if ECO_HEAP_VALIDATE
// ---------------------------------------------------------------------------
// Checks of the mark, in validate builds. IM10: no entry is scanned twice in
// one cycle. IM11: at the handoff, the scanned object entries are exactly the
// old-generation closure of the t0 grey set, computed independently with
// visitHeapChildren. IM12: the entries scanned equal the tickets used.
// ---------------------------------------------------------------------------
// The entries scanned so far in this cycle, in 64 mutex-guarded shards so
// that markers rarely contend.
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
        if (closure.size() > kCap) return;   // too big to check: skip silently
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
        // HEAP_081: a header-less body is marked without a push, so it is never
        // scanned: it is not part of the scanned closure IM11 counts.
        if (isRawBody(obj)) continue;
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
    // IM12: every scanned entry used exactly one ticket.
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
    // Every block has its BufferMetadata from BlockTable::add.
    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        const BlockId id = blocks_.idAt(pos);
#if ECO_HEAP_VALIDATE
        // HEAP_051: the previous merge left every accumulator zero; anything
        // here was attributed outside a mark.
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
        // An LOS block is never lazily swept; its live_bytes counts in-cycle
        // LOS allocations until mark end.
        meta.fully_swept = isLosBlock(id);
    }
}

void OldGenSpace::finalizeMetaAfterMark() {
    // HEAP_051: the markers' accumulators are folded into live_bytes before
    // anything after the mark reads it.
    markLiveMergeAll();
    // p1::onMarkEnd reads the mark bits here, before any sweep clears them.
    p1::onMarkEnd(*this);
    ++major_epoch_;
    // Frees unmarked LOS objects and sets every LOS block's live_bytes to its
    // used granules, before the totals below.
    losSweepAtMarkEnd();

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
    post_sweep_live_bytes_ = total_live;
    // The garbage-fraction trigger restarts from the live set, less the
    // allocate-black bytes of a cycle: those are allocation since t0, which a
    // stop-the-world major at t0 would have counted as allocation after it.
    // Otherwise each cycle's promotions would enlarge the next one's budget.
    baseline_black_bytes_ = cycle_tail_uses_traced_live_ ? cycle_black_bytes_ : 0;
    post_sweep_live_bytes_ = (total_live > baseline_black_bytes_)
                                 ? total_live - baseline_black_bytes_ : 0;
    prev_major_live_ = major_live_;
    // HEAP_057: after a cycle, the live-budget reference is the bytes the
    // marker traced, since allocate-black bytes measure in-cycle allocation,
    // not the live set. After a stop-the-world major it is total_live.
    major_live_ = cycle_tail_uses_traced_live_ ? cycle_traced_live_ : total_live;
}

// Demotion sets `block.size_class` to NUM_SIZE_CLASSES, so the next
// lazy-sweep walk parses the block by `getObjectSize` (mixed-block step)
// and re-emits its coalesced free runs through the mixed any-class packer
// in `pushSpanOnFreeLists`. The packer routes the bulk of the run to the
// large mixed-only classes, where
// `tryAllocateBySplittingLarger` can carve smaller cells out of them.
//
// Why this is safe:
//   - Live cells in a uniform block were padded by `padCellSlack`. The
//     padding is a trailing Tag_Free header that makes mixed-mode walking step over
//     the unused tail of the cell. So a mixed-mode walk of a previously
//     uniform block lands on every cell start exactly as the uniform-step
//     walk did.
//   - In free-list mode, free cells in a uniform block already have
//     `header.size = cell_size` and `tag = Tag_Free`, so a mixed-mode walk
//     steps over them by `getObjectSize` returning the same `cell_size`.
//   - `transitionToSweeping`, which the caller invokes immediately after
//     this method, clears `free_lists_` so any cells currently parked on
//     `free_lists_[old_uniform_class]` are dropped without a per-cell walk.
OldGenSpace::DemotionStats
OldGenSpace::demoteMostlyDeadUniformBlocks() {
    DemotionStats stats;
    // 0.0 means off. The early return is needed because the comparison below
    // would still demote all-dead blocks at 0.0.
    const double demote_f = config_->demote_live_fraction;
    if (demote_f <= 0.0) return stats;
    char* heap_base = (allocator_ != nullptr)
                          ? allocator_->getHeapBase() : nullptr;

    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        const BlockId i = blocks_.idAt(pos);
        BlockInfo& block = blocks_.info(i);
        if (block.is_large) continue;
        if (block.size_class >= num_size_classes_) continue;  // already mixed.

        // The block starting at the heap base is never demoted.
        if (heap_base != nullptr && block.start == heap_base) continue;

        const size_t total = block.totalBytes();
        const size_t live  = blocks_.meta(i).live_bytes;
        // Demote when live <= f * total.
        if (static_cast<double>(live) > demote_f * static_cast<double>(total)) continue;

        // Debits the small-class block budget for a uniform small-class
        // block. The helper is named for the is_large transition but touches
        // only small_class_bytes_, which is what this change needs.
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
        const BlockId id = blocks_.idAt(pos);
        BufferMetadata& meta = blocks_.meta(id);
        meta.garbage_bytes = 0;
        // The LOS manages LOS blocks' space; the lazy sweep never walks them.
        meta.fully_swept = isLosBlock(id);
    }
}

void OldGenSpace::runPostMarkTail(GCStats* stats, MajorGCPhaseProfile* profile) {
    // Trace builds: the marks are the liveness decision here, and a harness
    // probe may read them.
    ECO_TLA_TRACE_ONLY(::Elm::tlatrace::probe(cycle_tail_uses_traced_live_ ? "handoff" : "stw");)
    auto t_sweep_start = std::chrono::high_resolution_clock::now();

    finalizeMetaAfterMark();
    // Large objects that died during a cycle are freed here, after the merge
    // and before demotion and reclaim, so their bytes count as garbage.
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
    losReleaseEmptyBlocks();
    adjustCapacityAfterMajorGC();
#if ENABLE_GC_STATS
    // Phase B of the residency snapshot: post-reclaim, post-shrink, so
    // the live_frac == 0 bucket reflects the truly retained dead pages
    // rather than candidates about to be released.
    if (stats) gatherResidencySnapshotFrom(*stats, free_by_start);
#endif
    // Classify blocks, retire dead bodies and queue partial uniform blocks:
    // after reclaim and shrink, before the pending count.
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
    // incrementalMark adds to the aggregate unit counter, so this mark's
    // units are its delta across the loop.
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
// The incremental mark cycle: beginMarkCycle at t0, a step at each later
// minor end, and handoffMarkCycle once the mark is finished.
// ===========================================================================

// TLA-REGION(OGS.beginMarkCycle) begin
void OldGenSpace::beginMarkCycle(Allocator &alloc, uint32_t slices) {
    assert(!cycleActive() && !marking_active &&
           "beginMarkCycle: a mark is already in progress");
    assert(config_->old_gen_bitmap_alloc && "HEAP_063 requires bitmap allocation");
#if ENABLE_GC_STATS
    const auto t_prep = std::chrono::steady_clock::now();
#endif
    prepareMark(alloc);
#if ENABLE_GC_STATS
    {
        const uint64_t d = static_cast<uint64_t>(std::chrono::duration_cast<
            std::chrono::nanoseconds>(std::chrono::steady_clock::now() - t_prep).count());
        alloc_stats_.im.t0_prep_ns_total += d;
        if (d > alloc_stats_.im.t0_prep_ns_max) alloc_stats_.im.t0_prep_ns_max = d;
    }
#endif
    // The cycle's mark work runs on every marker slot when there is more than
    // one; the t0 snapshot pushes onto slot 0's deque as its owner.
    mark_parallel_ = mark_slots_ > 1;
    // The t0 view; unchanged until the handoff.
    mark_view_.nursery_lo = allocator_ref_->getHeapBase() + allocator_ref_->getOldGenReservationBytes();
    mark_view_.nursery_hi = allocator_ref_->getHeapBase() + allocator_ref_->getHeapReserved();
    bg_ep_ = BgEpisode::None;
    bg_done_k_ = 0;
    cyc_prog_ = CycleProgress{};
    // The pacing state this cycle started from, for pacingSnapshot().
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
    // Trace: a fresh cycle number for the grey-to-scan ordering keys.
    ECO_TLA_TRACE_ONLY((void)::Elm::tlatrace::bind(this, 1);)
    // Allocate-black and the other mid-mark branches test gc_phase_ != Idle.
    gc_phase_ = GCPhase::Marking;
    cycle_state_ = CycleState::Marking;
    cycle_slices_ = slices;
    cycle_k_ = 0;
    cycle_units_ = 0;
    cycle_traced_live_ = 0;
    cycle_tail_uses_traced_live_ = true;
    // The predicted units: the previous cycle's, scaled by the larger of
    // incremental_mark_predict_growth and the occupancy growth since the
    // previous t0; on the first cycle, occupancy / 48 B (a mean object). It
    // depends only on occupancy and past units, never on collector progress.
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
              [](const T0Block& a, const T0Block& b) { return a.id < b.id; });   // isT0Block searches by id
#endif
}
// TLA-REGION(OGS.beginMarkCycle) end

// TLA-REGION(OGS.snapshotYoungLarge) begin
void OldGenSpace::snapshotYoungLarge() {
    assert(snapshot_mode_ && "snapshotYoungLarge outside the t0 snapshot");
    forEachYoungLarge([&](void* obj, LargeBodyMeta&) {
        const BlockId id = contains(obj) ? blockIdFor(obj) : NO_BLOCK_ID;
        if (!id.valid()) return;
        // The cell itself: marked and its bytes attributed as markOneObject
        // does for an old-gen object.
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
    // With a background episode running or finished this cycle, the closing
    // join finishes the mark.
    if (bg_ep_ != BgEpisode::None) return closingFinish();
    // runMarkers adds to cycle_units_ itself.
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
        // Front-loaded pacing: the predicted work is spread over the first
        // H = ceil(T/2) slices, leaving the rest as a buffer. On an overrun
        // (predicted units done, grey work left) the prediction doubles. The
        // remainder is spread over slices k..H while k <= H, and over slices
        // k..T-1 after that. The budget depends only on units done.
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
    // Fold the cursors' pending bytes into live_bytes and detach every block,
    // as startMark does, before the tail reads live_bytes.
    resetAllocCursors();
    cycle_traced_live_ = markLiveSum();
    // Until runPostMarkTail merges the traced bytes, live_bytes holds exactly
    // the bytes allocated black during the cycle (prepareMark zeroed it).
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
    im11Check("handoff");   // IM10/IM11
#endif
    // From here the state is that of a stop-the-world major after its mark.
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
// Concurrent marking. Background markers (the conc_threads_ slots after the
// mark_threads_ foreground ones) mark between pauses; the foreground gang
// joins the running episode for paced assists and at the closing step. Approximate collector progress decides only work
// inside a pause, never a decision path (assertNotInDecision).
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
    // The id matches but the block is another incarnation: IM5 fails at once.
    if (!test_im5_ignore_gen_ && blocks_.generation(id) != it->gen)
        cycleValidateFail("IM5: a t0 block id was released and re-issued mid-cycle", it->start);
    return true;
}
#endif

void OldGenSpace::assertNoPrivateWork(const char* where) const {
    // IM15, checked in every build. While a background episode runs only the
    // foreground slots are checked.
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
    // IM14. The foreground gang runs on [0, F) while fg_run_active_; the
    // background gang on [F, F + B) while it is running.
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
    // Any running marker may hold any slot's old array through a steal.
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
    // The budget's consumption counts tickets claimed in batches but not yet
    // used, so it over-counts the units done.
    if (bg_ep_ != BgEpisode::Running || !bg_ctl_) return 0;
    const int64_t left = bg_ctl_->budget.load(std::memory_order_relaxed);
    return static_cast<uint64_t>(markwork::kDrainBudget - left);
}

namespace {
/**
 * The context of an assist or closing member: the space, the running
 * episode's control, and the assist's unit pool (null for a closing join,
 * whose members draw on the episode's own budget). og and c are non-null.
 * It lives on the caller's stack and is valid only during that gang run.
 */
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
    // Every foreground slot's grey entries go round-robin into the background
    // deques. No thread runs on those slots, so the mutator acts as their
    // owner; the gang's launch hands the deques to the members.
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
    ECO_TLA_TRACE("launch", "gang", ::Elm::tlatrace::key("B", bg_.get()));
    if (!bg_->launch(&OldGenSpace::bgEntry, this, &bg_ctl_->stop)) {
        // A fork's prepare holds the gang. As for a stopped episode, the work
        // stays in the background deques: the next step relaunches, or the
        // closing step drains it.
        bg_ep_ = BgEpisode::None;
        bg_refused_step_ = true;   // traced as an episode a fork stopped
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
    // Call only after a join, which publishes the members' counters.
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
    ECO_TLA_TRACE("reap", "done", done, "wait", wait);
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
        bg_ep_ = BgEpisode::None;             // stopped before its work was done
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
        // IM14: the counters reset here must be the foreground slots' only.
        // The negative control also resets background slot F, as a wrong
        // range would.
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
    // Exact: the pool's consumption equals the foreground units.
    assert(static_cast<int64_t>(units) == budget - pool.load() &&
           "P§3.5: assist units != consumed assist tickets");
    cycle_units_ += units;
    cyc_prog_.assists++;
    cyc_prog_.assist_units += units;
    ECO_TLA_TRACE("assist", "units", units);   // an assist ended
    // Deque arrays are not retired here: background thieves may hold them.
#if ENABLE_GC_STATS
    alloc_stats_.cm.assists++;
    alloc_stats_.cm.assist_units += units;
#endif
}
// TLA-REGION(OGS.assistEpisode) end

// TLA-REGION(OGS.closingFinish) begin
size_t OldGenSpace::closingFinish() {
    const auto t_start = std::chrono::steady_clock::now();
    uint64_t fg_units = 0;                    // marked INSIDE this pause
    reapBackground(/*wait=*/false);
    // M6: a harness pause point: the episode still runs as the closing join starts.
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
        // A foreign stop (a fork's prepare, stopAllAtExit, reset) can end the
        // episode before its work is done; the work is still in the deques and
        // the drain below completes the mark.
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
    ECO_TLA_TRACE("closing", "units", fg_units, "work", with_work);   // the closing step ended
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
            // A refused t0 launch is traced as an episode a fork stopped at once.
            ECO_TLA_TRACE("stop", "gang", ::Elm::tlatrace::key("B", bg_.get()));
            bg_refused_step_ = false;
        }
    } else if (config_->conc_mark == 1 && !markStackEmpty()) {
        // Synchronous mode: the whole mark runs inside the t0 pause on the
        // foreground gang, and the steps find nothing to do.
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
        ECO_TLA_TRACE("relaunch");
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
    // Traces the step (k counted, then the reap or relaunch above) and the
    // episode after it. A refused relaunch is traced as an episode "running"
    // that the fork stopped at once ("stop" right after).
    ECO_TLA_TRACE("step", "k", cycle_k_, "ep",
                  bg_refused_step_ || bg_ep_ == BgEpisode::Running ? "running"
                  : bg_ep_ == BgEpisode::Finished ? "finished" : "none",
                  "refused", bg_refused_step_);
    if (bg_refused_step_) {
        ECO_TLA_TRACE("stop", "gang", ::Elm::tlatrace::key("B", bg_.get()));
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
        // Paced assist: approximate progress decides only this in-pause work.
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
            // predicted * num / H exactly, without a 128-bit divide (__udivti3 is not in
            // the MSVC runtime): with predicted = q*H + r, q*num <= predicted, and
            // r*num < H*H <= 2^62 because T is a uint32_t.
            const uint64_t q = cycle_predicted_ / H, r = cycle_predicted_ % H;
            expected = q * num + (r * num) / H;
        }
        const uint64_t deficit = expected > U ? expected - U : 0;
        if (deficit >= config_->incremental_mark_min_slice_units && markWorkApprox()) {
            // runCycleSlice's budget formula, with U as the units done.
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
    // Relaxed atomic reads: background markers may write this byte.
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
    const bool marked = isMarkedInBlockRelaxed(id, obj);
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
        // A released id re-issued at the same start with the same class is a
        // new incarnation: its generation differs.
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
        if (b.alloc_state == kAllocTenure) continue;   // tenure blocks: collector-owned bits
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
// Sweep helpers.
// ---------------------------------------------------------------------------
//
// The sweep walks each block's parseable region [start, end_of_objects).
// Consecutive dead objects and unlisted free cells form a run, and each run is
// cut into free cells and pushed onto the free lists. Liveness comes from the
// block's mark bits, which the sweep clears as it reads them.
namespace {

// Cuts the `span_bytes` bytes at `span_start` into free cells and pushes each
// onto `free_lists`, so that every cell on list `cls` is exactly
// classToSize(cls) bytes. In a block of one size class (`block->size_class`
// below NUM_SIZE_CLASSES) every cell is that class's size, and the span must
// be a whole number of them (asserted). Otherwise the span is cut front to
// back into the largest class that fits, and a remainder too small for any
// class but at least a Header gets an unlinked Tag_Free header so that a
// header walk can step over it.
//
// `block`, when not null, must be the block holding the span; with it, cells
// with the FreeCellMid layout are also threaded onto the block's own
// free-cell list. Without it they go on the class list only. `block_index`
// is used only in diagnostics.
//
// With `age_sentinel`, every header written is marked as already on a free
// list (isFreeCellSentinel), so that the lazy sweep steps over it rather than
// merging it; otherwise the cells may be merged by a later sweep.
// TLA-REGION(OGS.pushSpanOnFreeLists) begin
inline void pushSpanOnFreeLists(FreeCell** free_lists, char* span_start,
                                size_t span_bytes,
                                BlockInfo* block,
                                BlockId block_index,
                                bool age_sentinel) {
    // With ECO_OLDGEN_DEBUG: abort on a span reaching outside its block, which
    // would overwrite cells of the next block.
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
    // A FreeCellMid cell is threaded onto its block's list only when the block
    // is known. Without it the cell is on its class list alone.
    const bool can_thread = (block != nullptr);

    // Writes a Tag_Free cell of `cellSize` bytes at `addr` and links it at the
    // head of free_lists[cls] and, for a FreeCellMid cell, of the block's list.
    auto placeAndLink = [&](char* addr, size_t cellSize, size_t cls) {
#if ECO_HEAP_VALIDATE
        // Every cell on free_lists[cls] must be classToSize(cls) bytes.
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
        // A cell pushed twice onto one list makes the list a cycle, so abort
        // if `cell` is already on it, naming the call sites of both pushes.
        // The scan costs the list's length per push;
        // ECO_VALIDATE_FREELIST_DUP_SCAN=0 turns it off.
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
            // A FreeCell-sized cell (class 1), or any cell with no block: the
            // class list only.
            cell->next_in_class = free_lists[cls];
            free_lists[cls] = cell;
        }
    };

    // A walk of a one-class block steps by classToSize(cls) (walkStepFor), so
    // every cell in it must be that size.
    if (block != nullptr && block->size_class < NUM_SIZE_CLASSES) {
        size_t cls = block->size_class;
        size_t cellSize = OldGenSpaceTestAccess::classToSize(cls);
        while (span_bytes >= cellSize) {
            placeAndLink(span_start, cellSize, cls);
            span_start += cellSize;
            span_bytes -= cellSize;
        }
        // A span in a one-class block that does not end on a cell boundary
        // was computed with another block's cell size.
        assert(span_bytes == 0 &&
               "pushSpanOnFreeLists: uniform block span must align with cellSize");
        return;
    }

    // A mixed or large block, or no block: the largest class that fits, front
    // to back.
    while (span_bytes >= MIN_FREE_CELL_SIZE) {
        size_t cls = OldGenSpaceTestAccess::freeListClassFor(span_bytes);
        if (cls >= NUM_SIZE_CLASSES) break;  // Below smallest class.
        size_t cellSize = OldGenSpaceTestAccess::classToSize(cls);
        placeAndLink(span_start, cellSize, cls);
        span_start += cellSize;
        span_bytes -= cellSize;
    }

    // Bytes too few for any class: an unlinked Tag_Free header, so a header
    // walk can step over them.
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

// Pushes a run the lazy sweep collected, as pushSpanOnFreeLists does without
// the sentinel mark: a later sweep may merge the cells with their neighbours.
inline void pushCoalescedFreeCell(FreeCell** free_lists, char* span_start,
                                  size_t span_bytes,
                                  BlockInfo* block,
                                  BlockId block_index) {
#if ECO_HEAP_VALIDATE
    PushOriginScope _origin("lazySweep::flushRun");
#endif
    pushSpanOnFreeLists(free_lists, span_start, span_bytes, block, block_index,
                        /*age_sentinel=*/false);
}

// Returns walkStepFor(`block`, `obj_size`): the bytes a walk of `block`
// advances past an object of `obj_size` bytes.
inline size_t walkStep(const BlockInfo& block, size_t obj_size) {
    return walkStepFor(block, obj_size);
}

}  // namespace

void OldGenSpace::sweep() {
    if (gc_phase_ != GCPhase::Sweeping) {
        transitionToSweeping();
    }
    while (gc_phase_ == GCPhase::Sweeping) {
        lazySweep(NUM_SIZE_CLASSES,
                  std::numeric_limits<size_t>::max() / 2);
    }

    // With ECO_OLDGEN_DEBUG: abort if a free-list cell lies outside the old
    // generation's address range.
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

void OldGenSpace::transitionToSweeping() {
    gc_phase_ = GCPhase::Sweeping;
    sweep_buffer_index_ = 0;
    sweep_cursor_ = nullptr;

#if ECO_HEAP_VALIDATE
    // The duplicate-push check records origins per sweep.
    g_first_push_origin.clear();
#endif

    // Once the heads are cleared no cell is on a list, so a cell still marked
    // as listed (isFreeCellSentinel) would be stepped over by the sweep and
    // its bytes never reused. Clear those marks first. The walk touches every
    // free cell; `free_list_sentinel_count_` is nonzero whenever a marked
    // cell exists, so when it is 0 the walk is skipped.
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
    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        blocks_.info(blocks_.idAt(pos)).free_cells_in_block = FREE_CELLS_EMPTY;
    }
    // The blocks stay; the sweep lists each dead large block again.
    free_large_blocks_.clear();

    prepareMetaForLazySweep();

    // Releasing an unswept block later counts it down
    // (releaseBlockToAllocator).
    recomputeSweepPendingBlocks();
}

void OldGenSpace::recomputeSweepPendingBlocks() {
    sweep_pending_blocks_ = 0;
    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        if (!blocks_.meta(blocks_.idAt(pos)).fully_swept) ++sweep_pending_blocks_;
    }
    // The denominator of computeSweepBudgetForAlloc's unswept fraction, fixed
    // here so that blocks added already swept during the sweep do not change
    // it.
    sweep_total_blocks_ = sweep_pending_blocks_;
}

void OldGenSpace::markBlockFullySwept(BlockId block_index) {
    if (!block_index.valid()) return;
    BufferMetadata& meta = blocks_.meta(block_index);
    if (meta.fully_swept) return;
    meta.fully_swept = true;
    if (sweep_pending_blocks_ > 0) --sweep_pending_blocks_;
}

#if ECO_HEAP_VALIDATE
// After a gap sweep (HEAP_055) every gap is free cells and every popped cell
// an object, so the block parses header by header.
void OldGenSpace::validateV11(BlockId id) const {
    const BlockInfo& block = blocks_.info(id);
    char* const used_end = block.end_of_objects;
    size_t covered = 0;
    for (char* q = block.start; q < used_end;) {
        const Header qh = loadHeaderRelaxed(q);   // HEAP_062
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

    // `buf_pos` is the sweep's block position, not a block id.
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

    // Ends the sweep (HEAP_067). Inside a parallel promotion the completion
    // goes through sweepCompleteInPromotion, which defers onSweepComplete
    // until the shrink may run. `path` is the M4 trace's label: 2 for the
    // in-loop completion, 3 for the one after the loop.
    auto completeSweep = [&](int path) {
        ECO_TLA_TRACE_ONLY(const int m4_old = static_cast<int>(gc_phase_);)
        // Promotion workers read gc_phase_ outside promo_mu_ (HEAP_067), so
        // this write is atomic.
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
                completeSweep(2);
                return work_done;
            }
            // A block added during the sweep starts fully swept. Walking it
            // would merge free cells that are already on the lists.
            if (blocks_.meta(blocks_.idAt(sweep_buffer_index_)).fully_swept) {
                sweep_buffer_index_++;
                continue;
            }
            sweep_cursor_ = blocks_.info(blocks_.idAt(sweep_buffer_index_)).start;
        }

        const BlockId cur_id = blocks_.idAt(sweep_buffer_index_);
        BlockInfo& block = blocks_.info(cur_id);
        char* used_end = block.end_of_objects;

        // Large blocks hold a single object. Decide live vs. dead in
        // one shot rather than running the coalescing walk: a dead large
        // block becomes a `free_large_blocks_` entry so the next
        // allocateLargeBlock reuses its address.
        if (block.is_large && sweep_cursor_ == block.start &&
            sweep_cursor_ < used_end) {
            // In bitmap mode every large block is already fully swept.
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
                    // A dead tracked large body (HEAP_026) or young large
                    // object leaves large_body_index_ here. A raw block
                    // (HEAP_081) has no header and is always looked up.
                    const bool raw_blk = (block.los & kLosRaw) != 0;
                    const Header lh = raw_blk ? Header{} : loadHeaderRelaxed(sweep_cursor_);   // HEAP_062
                    if (raw_blk || lh.pin) {   // a body or a YLOS object: index is authoritative
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

        // Gap sweep (HEAP_055), in bitmap mode: the set mark bits of an
        // unswept block are exactly its live objects, so the gaps between them
        // are the runs, found without reading a dead header. work_done counts
        // the bytes covered, as in the header walk.
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
                // A live object: push the run before it, clear its bit, and
                // step over it. Its header is read with one relaxed atomic
                // load (HEAP_062): a young large object's age may be written
                // under ylos_mu_ meanwhile.
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
            // One relaxed atomic load of the header (HEAP_062).
            const Header lh = loadHeaderRelaxed(sweep_cursor_);
            const Header* hdr = &lh;
            size_t step = walkStep(block, getObjectSizeFromHeader(hdr));

            // A free cell is dead without a mark-bit test.
            const bool live = (hdr->tag != Tag_Free) &&
                testAndClearMarkBitInBlock(cur_id, sweep_cursor_);

            if (live) {
                flushRun(sweep_buffer_index_);
            } else if (isFreeCellSentinel(hdr)) {
                // Already on a free list: ends the run, and is left
                // untouched.
                flushRun(sweep_buffer_index_);
            } else {
                // As in the large-block case above.
                if (hdr->pin) {   // a body or a YLOS object: index is authoritative
                    auto it = large_body_index_.find(sweep_cursor_);
                    if (it != large_body_index_.end()) {
                        retireIndexEntry(it->second);
                        large_body_index_.erase(it);
                    }
                }
                // Dead objects and unlisted free cells join the run.
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
            ECO_TLA_TRACE_ONLY(if (run_start != nullptr))   // M4: the trailing run's iteration
                ECO_M4_TRACE("m4.sw", "blk", cur_id.v,
                             "rs", static_cast<int64_t>((run_start - block.start) / MARK_ALIGNMENT),
                             "rb", run_bytes, "l", -1, "end", true);
            flushRun(sweep_buffer_index_);
#if ECO_HEAP_VALIDATE
            if (gap_sweep) {
                // With more than one promotion worker, another may still be
                // writing a cell it popped from this block, so the check
                // waits for the workers to stop.
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

        if (target_class < NUM_SIZE_CLASSES &&
            free_lists_[target_class] != nullptr) {
            flushRun(sweep_buffer_index_);
            ECO_M4_TRACE("m4.swend", "cb", classToSize(target_class), "path", 1, "par", par_promo_active_);
            return work_done;
        }
    }

    // The next call resumes mid-block with a new run.
    flushRun(sweep_buffer_index_);

    ECO_TLA_TRACE_ONLY(if (sweep_buffer_index_ < blocks_.size()))   // M4: the slice ends (budget)
        ECO_M4_TRACE("m4.swend", "cb", target_class < NUM_SIZE_CLASSES ? classToSize(target_class) : 0,
                     "path", 0, "par", par_promo_active_);
    if (sweep_buffer_index_ >= blocks_.size()) completeSweep(3);
    return work_done;
}
// TLA-REGION(OGS.lazySweep) end

// TLA-REGION(OGS.onSweepComplete) begin
void OldGenSpace::onSweepComplete() {
    // Checked in every build: the shrink must not run inside a parallel
    // promotion.
    if (__builtin_expect(par_promo_active_, 0)) {
        std::fprintf(stderr, "[gc] FATAL: onSweepComplete inside a parallel promotion (CR-014)\n");
        std::abort();
    }
    sweep_pending_blocks_ = 0;
    sweep_total_blocks_ = 0;
    computeFragmentationStats();

    const size_t live = frag_stats_.live_bytes;
    const float target = config_->major_gc_target_utilization;
    size_t desired_heap = (target > 0.0f && live > 0)
        ? static_cast<size_t>(std::ceil(
              static_cast<double>(live) / static_cast<double>(target)))
        : 0;
    maybeShrinkCapacity(desired_heap, ShrinkPass::Light);
    // M4: the light shrink is over (its m4.rel events name what it released).
    ECO_M4_TRACE("m4.shrink", "par", par_promo_active_);
}
// TLA-REGION(OGS.onSweepComplete) end

OldGenSpace::MajorGCTriggerReason
OldGenSpace::evaluateMajorGCTrigger() const {
#if ECO_HEAP_VALIDATE
    const DecisionScope im16(*this);
#endif
    // HEAP_063: no trigger fires while a cycle runs.
    if (cycle_state_ != CycleState::Idle) return MajorGCTriggerReason::None;
    const float threshold = config_->major_gc_initiating_occupancy;

    // Occupancy: allocated bytes over this old generation's committed bytes.
    const size_t committed = getCommittedBytes();
    if (committed != 0 &&
        static_cast<double>(allocated_bytes) / committed >= threshold) {
        return MajorGCTriggerReason::Occupancy;
    }

    // Global pressure: all old generations' committed bytes at or above
    // major_gc_global_pressure_fraction of the cap.
    // This catches committed bytes growing faster than `allocated_bytes`, as
    // when each request takes a page it does not fill.
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
        // Headroom: start the cycle while the bytes promoted over its
        // pacingHorizonMinors() minors, at the estimated rate p_hat_ times the
        // margin, still fit under incremental_mark_finish_fraction of the
        // cap.
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

    // Garbage fraction: bytes allocated since the baseline set when the last
    // sweep ended, over committed. A heap whose free lists absorb allocation
    // never reaches the occupancy threshold, and this bounds the garbage it
    // can build up. 0 disables it.
    float garb_frac = config_->major_gc_garbage_fraction;
    // With LiveBudget on, a backstop value raises the garbage fraction.
    if (config_->major_gc_garbage_backstop > 0.0f && config_->major_gc_live_budget > 0.0 &&
        garb_frac > 0.0f) {
        garb_frac = std::max(garb_frac, config_->major_gc_garbage_backstop);
    }
    // In bitmap mode the denominator is at most garbage_denom_cap times the
    // committed bytes at the last major (0: no cap). When garbage cannot be
    // reused before the next major, each allocated byte grows committed, and
    // an uncapped denominator would grow with the numerator.
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
    // LiveBudget: allocation since the baseline reaches the budget times the
    // last major's live bytes, those capped at live_growth_bound times the
    // previous major's, so that one transient peak does not size the next
    // cycle.
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
        // Paced: count the bytes expected over the cycle's horizon too, so
        // the budget is reached when the cycle ends rather than when it starts.
        const double ahead = (config_->major_gc_live_budget_paced && p_hat_ > 0)
            ? static_cast<double>(pacingHorizonMinors()) * static_cast<double>(p_hat_) : 0.0;
        if (static_cast<double>(alloc_since_major) + ahead >= budget * live_ref) {
            return MajorGCTriggerReason::LiveBudget;
        }
    }
    return MajorGCTriggerReason::None;
}

void OldGenSpace::adjustCapacityAfterMajorGC() {
    assert((gc_phase_ == GCPhase::Sweeping || gc_phase_ == GCPhase::Idle) &&
           "adjustCapacityAfterMajorGC: unexpected gc_phase_");

    char* const region_base = regionBase();
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

    // live / target utilization; maybeShrinkCapacity applies its floor.
    size_t desired_heap = (target > 0.0f && live > 0)
        ? static_cast<size_t>(std::ceil(
              static_cast<double>(live) / static_cast<double>(target)))
        : capacity;

    if (live == 0 || occupancy <= target) {
        maybeShrinkCapacity(desired_heap, ShrinkPass::Heavy);
        return;
    }

    if (occupancy < grow_threshold) return;

    const size_t global_cap = allocator_->getOldGenMaxBytes();
    if (desired_heap > global_cap) desired_heap = global_cap;
    if (desired_heap <= capacity)  return;

    allocator_->ensureOldGenCapacityFor(*this, desired_heap);
}

// The releases run in three passes, each walking back to front and stopping
// at the target: empty swept page blocks (not LOS or tenure-granted ones),
// then empty large blocks, then bag pages.
// TLA-REGION(OGS.maybeShrinkCapacity) begin
void OldGenSpace::maybeShrinkCapacity(size_t desired_heap_bytes,
                                      ShrinkPass pass) {
    syncCursorLiveBytes();   // before reading live_bytes
#if ENABLE_GC_STATS
    auto t0_shrink = GC_STATS_TIMER_START();
    auto bill = [&]() {
        uint64_t ns = GC_STATS_TIMER_ELAPSED_NS(t0_shrink);
        switch (pass) {
            case ShrinkPass::Light:  alloc_stats_.total_maybe_shrink_light_ns += ns; break;
            case ShrinkPass::Heavy:  alloc_stats_.total_maybe_shrink_heavy_ns += ns; break;
            case ShrinkPass::Forced: alloc_stats_.total_maybe_shrink_forced_ns += ns; break;
        }
    };
    struct Billing {
        std::function<void()> bill;
        ~Billing() { bill(); }
    } billing{bill};
#endif

    if (compact_phase_ != CompactionPhase::Idle) return;
    if (allocator_     == nullptr)               return;
    if (pass == ShrinkPass::Forced &&
        (gc_phase_ != GCPhase::Idle || cycleActive())) return;

    const size_t live = frag_stats_.live_bytes;
    const float target = config_->major_gc_target_utilization;

    const size_t min_heap = std::max(config_->initial_old_gen_size,
                                     config_->alloc_buffer_size);

    size_t desired_heap = desired_heap_bytes;
    if (desired_heap < min_heap) desired_heap = min_heap;

    // The blocks' bytes plus the bag pages' bytes.
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

    // Heavy: above 1.2 times the target and occupancy below 0.8 of target
    // utilization, unless under global pressure, where a shrink must happen
    // anyway or the global pressure trigger would keep firing with nothing
    // released. Light: above 1.5 times the target.
    if (pass == ShrinkPass::Forced) {
    } else if (pass == ShrinkPass::Light) {
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

    // Choose first, release after. A swap-remove fills a position from the
    // last one, so releasing in descending position order moves none still
    // to be released.
    std::vector<size_t> to_release;
    to_release.reserve(blocks_.size() / 4);

    auto canRelease = [&](size_t bytes) -> bool {
        if (current_heap < bytes) return false;
        if (current_heap - bytes < desired_heap) return false;
        return true;
    };

    for (size_t i = blocks_.size(); i > 0;) {
        --i;
        if (current_heap <= desired_heap) break;
        const BlockId id = blocks_.idAt(i);
        const BufferMetadata& meta = blocks_.meta(id);
        if (!meta.fully_swept || meta.live_bytes != 0) continue;
        if (blocks_.info(id).is_large) continue;
        if (blocks_.info(id).los != 0) continue;   // the LOS releases its own
        if (blocks_.info(id).alloc_state == kAllocTenure && !test_shrink_ignores_tenure_) continue;
        const size_t bytes = blocks_.info(id).totalBytes();
        if (!canRelease(bytes)) continue;
        to_release.push_back(i);
        current_heap -= bytes;
    }

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
        // Class 1 cells are on no per-block list, so one walk of class 1
        // drops those of every block to be released; removeFreeCellsForBlock
        // skips that walk inside the batch.
        std::sort(to_release.begin(), to_release.end());
        // Ids are taken before any release; they do not move (HEAP_048).
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
                    *prev = next;
                } else {
                    prev = &curr->next_in_class;
                }
                curr = next;
            }
        }
        ++batch_release_depth_;
        for (auto it = release_ids.rbegin(); it != release_ids.rend(); ++it) {
            releaseBlockToAllocator(*it);
        }
        --batch_release_depth_;

        // Inside the batch each release leaves the bounds to this.
        recomputeRegionBounds();
    }

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

void OldGenSpace::finishSweepForRelease() {
    if (cycleActive()) {
        std::fprintf(stderr, "[gc] FATAL: finishSweepForRelease during a mark cycle (HEAP_076)\n");
        std::abort();
    }
    while (gc_phase_ != GCPhase::Idle) {   // "!=" keeps the F.gc_phase grep quiet
        lazySweep(NUM_SIZE_CLASSES, std::numeric_limits<size_t>::max() / 2);
    }
}

void OldGenSpace::shrinkToFloorForRelease() {
    maybeShrinkCapacity(0, ShrinkPass::Forced);
}

void OldGenSpace::removeFreeCellsForBlock(BlockId block_index) {
    if (!block_index.valid()) return;
    BlockInfo& blk = blocks_.info(block_index);

    // FreeCellMid cells: walk the block's own list, unlinking each from its
    // class list through its back-link. The block's list is dropped whole.
    {
        FreeCell* curr = resolveOff(blk, blk.free_cells_in_block);
        while (curr != nullptr) {
            FreeCell* next = resolveOff(blk, asTierM(curr)->next_in_block);
            const size_t cls = sizeClass(curr->header.size);
            classListUnlinkTierM(free_lists_, curr, cls);
            curr = next;
        }
        blk.free_cells_in_block = FREE_CELLS_EMPTY;
    }

    // Class 1 cells: a walk of the whole class 1 list, which a batch release
    // has already done for all its blocks.
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
    // No listed cell may remain in the block: its bytes will be reused, and a
    // later push at the same address would make the list a cycle.
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

    // Only these two hold positions; everything else holds BlockIds, which
    // do not move (HEAP_048), or addresses (HEAP_052).
    if (sweep_buffer_index_ == old_pos) sweep_buffer_index_ = new_pos;
    if (fixup_buffer_index_ == old_pos) fixup_buffer_index_ = new_pos;
}

// TLA-REGION(OGS.releaseBlockToAllocator) begin
void OldGenSpace::releaseBlockToAllocator(BlockId block_index) {
    assert(!cycleActive() && "IM5: release/compaction during an incremental mark cycle");
#if ECO_HEAP_VALIDATE
    // HEAP_058: no release inside a parallel promotion with more than one
    // worker (a release may wait on a populate under promo_mu_).
    if (acquireWaitPolicy() != AcquireWait::Allowed) {
        std::fprintf(stderr, "[heap-validate] CR-007: a block release inside a parallel "
                     "promotion with n > 1 workers\n");
        std::abort();
    }
#endif
    if (!block_index.valid()) return;
    ECO_M4_TRACE("m4.rel", "blk", block_index.v, "state", blocks_.info(block_index).alloc_state);
    if (config_->old_gen_bitmap_alloc) detachFromAllocation(block_index);

    // Before blocks_ changes: onBlockReleased reads the block's size class.
    onBlockReleased(block_index);

    BlockInfo blk = blocks_.info(block_index);
    const size_t total = blk.totalBytes();

    assert((blk.is_large || total == config_->alloc_buffer_size) &&
           "releaseBlockToAllocator: non-large block must be one full page");

    if (!blocks_.meta(block_index).fully_swept &&
        sweep_pending_blocks_ > 0) {
        --sweep_pending_blocks_;
    }

    removeFreeCellsForBlock(block_index);

    for (size_t k = 0; k < free_large_blocks_.size();) {
        if (free_large_blocks_[k] == block_index) {
            free_large_blocks_[k] = free_large_blocks_.back();
            free_large_blocks_.pop_back();
        } else {
            ++k;
        }
    }

    // Forget every tracked large body inside the block. A block can be
    // released before the sweep reaches it (reclaimAllDeadBlocksFromMeta),
    // and a stale entry would later have freeLargeBodyCell push the body's
    // bytes onto a free list as part of whatever block reuses the address.
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

    clearPageIndexForBlock(block_index);

    allocator_->releaseOldGenBlock(blk.start, total);

    const size_t parseable =
        static_cast<size_t>(blk.end_of_objects - blk.start);
    if (frag_stats_.heap_bytes >= parseable) {
        frag_stats_.heap_bytes -= parseable;
    } else {
        frag_stats_.heap_bytes = 0;
    }

    // The last position moves into this one; ids do not move (HEAP_048).
    const size_t pos = blocks_.posOf(block_index);
    const size_t last = blocks_.size() - 1;
    mark_.retire(block_index);
    blocks_.swapRemove(block_index);

    if (pos != last) {
        fixupCursorsAfterOrderMove(last, pos);
    }

    // Inside a batch the caller recomputes the bounds once at the end.
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
    // HEAP_058, as in releaseBlockToAllocator.
    if (acquireWaitPolicy() != AcquireWait::Allowed) {
        std::fprintf(stderr, "[heap-validate] CR-007: a page release inside a parallel "
                     "promotion with n > 1 workers\n");
        std::abort();
    }
#endif
    if (unassigned_index >= unassigned_blocks_.size()) return;

    // A bag page starting at the heap base is never released, although a
    // block there is (releaseBlockToAllocator).
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

    const size_t last = unassigned_blocks_.size() - 1;
    if (unassigned_index != last) {
        unassigned_blocks_[unassigned_index] = unassigned_blocks_[last];
    }
    unassigned_blocks_.pop_back();

    if (start == regionBase() || end == regionEnd()) {
        recomputeRegionBounds();
    }
}
// TLA-REGION(OGS.releaseUnassignedBlockToAllocator) end

// ---------------------------------------------------------------------------
// Releasing blocks the mark found empty.
// ---------------------------------------------------------------------------

OldGenSpace::AllDeadReclaimStats
OldGenSpace::reclaimAllDeadBlocksFromMeta() {
    AllDeadReclaimStats stats;

    // The same floor as maybeShrinkCapacity.
    const size_t min_heap =
        std::max(config_->initial_old_gen_size, config_->alloc_buffer_size);

    size_t current_heap = 0;
    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        current_heap += blocks_.info(blocks_.idAt(pos)).totalBytes();
    }
    for (const auto& e : unassigned_blocks_) {
        current_heap += static_cast<size_t>(e.second - e.first);
    }

    // Large blocks are kept: the sweep lists a dead one for reuse at the same
    // address. Releases go in descending position order, which moves none
    // still to be released.
    std::vector<BlockId> dead;
    dead.reserve(blocks_.size() / 4);
    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        const BlockId id = blocks_.idAt(pos);
        if (blocks_.info(id).is_large) continue;
        if (blocks_.info(id).los != 0) continue;   // released by losReleaseEmptyBlocks
        if (blocks_.meta(id).live_bytes != 0) continue;
        if (blocks_.info(id).alloc_state == kAllocTenure) continue;
        const size_t bytes = blocks_.info(id).totalBytes();
        if (current_heap < bytes) continue;
        if (current_heap - bytes < min_heap) continue;
        dead.push_back(id);
        current_heap -= bytes;
    }
    if (dead.empty()) return stats;

    for (BlockId id : dead) {
        stats.bytes_released += blocks_.info(id).totalBytes();
    }
    stats.blocks_released = dead.size();

    // Inside the batch the releases leave the bounds to the end.
    ++batch_release_depth_;
    for (auto it = dead.rbegin(); it != dead.rend(); ++it) {
        releaseBlockToAllocator(*it);
    }
    --batch_release_depth_;

    recomputeRegionBounds();

#if ECO_HEAP_VALIDATE
    validateOldGenMetadata("reclaimAllDeadBlocksFromMeta");
#endif
    return stats;
}

#if ENABLE_GC_STATS
// GCStats's free-list histogram has a bucket for every size class.
static_assert(NUM_SIZE_CLASSES <= GCStats::FREELIST_CLASS_BUCKETS,
              "GCStats::FREELIST_CLASS_BUCKETS must cover every "
              "OldGenSpace size class");

// A free large block counts whole toward its block's free bytes, and goes in
// the histogram apart from the classes.
void OldGenSpace::gatherFreeListSnapshotInto(
    GCStats& stats, FreeBytesByBlockStart& out) const {
    stats.beginFreeListSnapshot();

    out.clear();

    for (size_t cls = 0; cls < NUM_SIZE_CLASSES; ++cls) {
        // A list that is a cycle would make the walk below endless: detect
        // one (Floyd's algorithm) and abort.
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
#endif  // ECO_HEAP_VALIDATE

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

// Entries of `free_by_start` for blocks released since it was filled are
// unused.
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

// TLA-REGION(OGS.computeFragmentationStats) begin
void OldGenSpace::computeFragmentationStats() {
    syncCursorLiveBytes();   // before reading live_bytes
    frag_stats_.live_bytes = 0;
    frag_stats_.total_free_bytes = 0;
    frag_stats_.heap_bytes = 0;

    for (size_t pos = 0; pos < blocks_.size(); pos++) {
        const BlockId i = blocks_.idAt(pos);
        const auto& meta = blocks_.meta(i);
        frag_stats_.live_bytes += meta.live_bytes;
        frag_stats_.total_free_bytes += meta.garbage_bytes;
        frag_stats_.heap_bytes += static_cast<size_t>(
            blocks_.info(i).end_of_objects - blocks_.info(i).start);
    }

    allocated_bytes = frag_stats_.live_bytes;
    // The triggers' baseline: what is allocated from here counts as
    // allocation since the major.
    post_sweep_live_bytes_ = frag_stats_.live_bytes;
    // The bytes the last cycle allocated black stay counted as allocation
    // since the major.
    post_sweep_live_bytes_ = (post_sweep_live_bytes_ > baseline_black_bytes_)
                                 ? post_sweep_live_bytes_ - baseline_black_bytes_ : 0;
}
// TLA-REGION(OGS.computeFragmentationStats) end

// During a sweep the swept flags and garbage bytes are incomplete, and
// selectEvacuationSet relies on both.
bool OldGenSpace::shouldCompact() const {
    if (gc_phase_ != GCPhase::Idle) return false;
    return frag_stats_.utilization() < UTILIZATION_THRESHOLD;
}

// ============================================================================
// Incremental Compaction Implementation
// ============================================================================

void OldGenSpace::scheduleCompaction() {
    assert(!cycleActive() && "IM5: release/compaction during an incremental mark cycle");
    syncCursorLiveBytes();   // before reading live_bytes
    if (compact_phase_ != CompactionPhase::Idle) return;
    // As in shouldCompact.
    if (gc_phase_ != GCPhase::Idle) return;
    assert(sweepComplete() &&
           "scheduleCompaction: sweep must be complete (gc_phase_ == Idle)");

    evacuation_set_ = selectEvacuationSet(COMPACTION_WORK_BUDGET * 10);
    if (evacuation_set_.empty()) return;
    p1::invalidate(*this);   // objects are about to move

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
        if (blk.alloc_state == kAllocTenure) continue;

        if (i == evac_block_index_) continue;

        // Large, LOS and pinned objects do not move.
        if (blk.is_large) continue;
        if (blk.los != 0) continue;
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

        // In bitmap mode a one-class block's free cells have no header: a
        // clear bit is a free cell.
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

                if (hdr->tag == Tag_Free) {
                evac_cursor_ += step;
                continue;
            }

            // A pinned object forwards to itself.
            if (hdr->tag != Tag_Forward && hdr->pin) {
                installForwardingPointer(evac_cursor_, evac_cursor_);
                evac_cursor_ += step;
                continue;
            }

            if (hdr->tag != Tag_Forward) {
                // Copy only the object's logical bytes; slack between
                // obj_size and step (cell size, for size-class blocks) is
                // not copied.
                void* dest = allocateForEvacuation(obj_size);
                if (dest == nullptr) {
                    // Out of space: the compaction is abandoned.
                    compact_phase_ = CompactionPhase::Idle;
                    evacuation_set_.clear();
                    return work_done;
                }

                std::memcpy(dest, evac_cursor_, obj_size);
                // The copy carries the source's colour; white makes the next
                // mark trace it.
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

// Bumps through a destination block of its own taken from the bag, apart from
// the free lists.
void* OldGenSpace::allocateForEvacuation(size_t size) {
    size = (size + 7) & ~7;

    auto bumpInBlock = [&](BlockId idx) -> void* {
        BlockInfo& blk = blocks_.info(idx);
        if (evac_alloc_ptr_ == nullptr) {
            evac_alloc_ptr_ = blk.end_of_objects;
        }
        if (evac_alloc_ptr_ + size > blk.end) return nullptr;
        char* result = evac_alloc_ptr_;
        evac_alloc_ptr_ += size;
        blk.end_of_objects = evac_alloc_ptr_;
        return result;
    };

    if (evac_block_index_.valid() && !isInEvacuationSet(evac_block_index_)) {
        if (void* r = bumpInBlock(evac_block_index_)) return r;
    }

    if (unassigned_blocks_.empty()) {
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
    bi.end_of_objects = extent.first;
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

        const BlockId fix_id = blocks_.idAt(fixup_buffer_index_);
        if (isInEvacuationSet(fix_id)) {
            fixup_buffer_index_++;
            fixup_cursor_ = nullptr;
            continue;
        }

        BlockInfo& block = blocks_.info(fix_id);

        if (block.los != 0) {
            // An LOS block cannot be walked by header: fix the tracked
            // objects in it.
            if (!(block.los & kLosRaw)) {
                for (const auto& kv : large_body_index_) {
                    char* o = static_cast<char*>(kv.first);
                    if (o >= block.start && o < block.end) fixPointersInObject(o);
                }
            }
            work_done += block.totalBytes();
            fixup_buffer_index_++;
            fixup_cursor_ = nullptr;
            continue;
        }

        if (fixup_cursor_ == nullptr) {
            fixup_cursor_ = block.start;
        }

        char* end = block.end_of_objects;

        while (fixup_cursor_ < end && work_done < work_budget) {
            if (config_->old_gen_bitmap_alloc && !block.is_large &&
                block.size_class < num_size_classes_ &&
                !isMarkedInBlock(fix_id, fixup_cursor_)) {
                // A free cell of a one-class block, which has no header.
                fixup_cursor_ += classToSize(block.size_class);
                continue;
            }
            Header* hdr = reinterpret_cast<Header*>(fixup_cursor_);
            size_t step = walkStep(block, getObjectSize(fixup_cursor_));

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
            // Same slots as the mark pass (scanChildren): header slots, then the tail.
            Custom* c = static_cast<Custom*>(obj);
            const u32 n = hdr->size, h = n < CUSTOM_HDR_SLOTS ? n : CUSTOM_HDR_SLOTS;
            for (u32 i = 0; i < h; i++) fixUnboxable(c->values[i], kindInWord(c->unboxed, i) == 0);
            for (u32 i = h; i < n; i++) fixUnboxable(c->values[i], customSlotKind(c, i) == 0);
            break;
        }
        case Tag_Record: {
            Record* r = static_cast<Record*>(obj);
            const u32 n = hdr->size, h = n < RECORD_HDR_SLOTS ? n : RECORD_HDR_SLOTS;
            for (u32 i = 0; i < h; i++) fixUnboxable(r->values[i], kindInWord(r->unboxed, i) == 0);
            for (u32 i = h; i < n; i++) fixUnboxable(r->values[i], recordSlotKind(r, i) == 0);
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
            // The same slots the mark traces.
            Closure* cl = static_cast<Closure*>(obj);
            for (u32 i = 0; i < cl->n_values; i++) {
                fixUnboxable(cl->values[i], closureSlotKind(cl, i) == 0);
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
            // The body is pinned and has no header (HEAP_081), so it is not
            // followed: fixHPointer would read payload as a tag.
            break;
        }
        case Tag_LargeByteHeader: {
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

// Each evacuated block's page goes back to the bag, after its free cells
// leave the free lists.
void OldGenSpace::freeEvacuatedBuffers() {
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
    for (const auto& e : evacuated_extents) {
        unassigned_blocks_.emplace_back(e.first, e.second);
    }

    // Later positions shift down, keeping their order; ids do not change
    // (HEAP_048). The page index is not rebuilt (HEAP_049), so each block's
    // slots are cleared here.
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
    // The erase left the fixup position past the end; reset it so the
    // validator's position-range check (HEAP_048) passes.
    fixup_buffer_index_ = 0;
    fixup_cursor_ = nullptr;

    // The filter kept the class lists linked, but FreeCellMid back-links and
    // per-block lists may name dropped cells: rebuild both from the class
    // lists.
    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        blocks_.info(blocks_.idAt(pos)).free_cells_in_block = FREE_CELLS_EMPTY;
    }
    for (size_t cls = 0; cls < NUM_SIZE_CLASSES; ++cls) {
        FreeCell* prev_kept = nullptr;
        for (FreeCell* c = free_lists_[cls]; c != nullptr;
             c = c->next_in_class) {
            if (!isTierM(c)) { prev_kept = c; continue; }
            FreeCellMid* m = asTierM(c);
            if (prev_kept == nullptr) {
                setPrevHead(m);
            } else {
                setPrev(m, prev_kept);
            }
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
// Large-object allocation and the large-body index.
// ---------------------------------------------------------------------------

void* OldGenSpace::allocateTrackedCell(size_t total_size, size_t& cell_size,
                                       bool& is_large) {
    total_size = (total_size + 7) & ~static_cast<size_t>(7);
    if (total_size <= los_.maxObjectBytes()) {
        BlockId bid;
        void* cell = allocateLos(total_size, /*raw=*/false, &bid);
        if (!cell) return nullptr;
        GC_STATS_OLDGEN_DIRECT_RECORD_ALLOC(alloc_stats_, total_size);
        cell_size = los_.granulesFor(total_size) * los_.granuleBytes();
        is_large = false;
        // Also sets the mark bit when allocating black and adds the cell to
        // the block's live_bytes.
        initObjectHeaderWithSize(cell, cell_size);
        allocated_bytes += cell_size;
        old_alloc_total_ += cell_size;
#if ECO_HEAP_VALIDATE
        if (cycleActive()) noteCycleAllocation(cell);
#endif
        return cell;
    }
    assert(total_size >= config_->alloc_buffer_size &&
           "allocateTrackedCell: the LOS covers everything below one block");
    void* body = allocate(total_size);
    if (!body) return nullptr;
    GC_STATS_OLDGEN_DIRECT_RECORD_ALLOC(alloc_stats_, total_size);
    is_large = true;
    cell_size = total_size;
    if (contains(body)) {
        const BlockId blk_idx = blockIdFor(body);
        if (blk_idx.valid() && blocks_.info(blk_idx).is_large) {
            cell_size = blocks_.info(blk_idx).totalBytes();
            blocks_.info(blk_idx).los = 0;   // a reused block may have held a raw body
        }
    }
    return body;
}

// ---------------------------------------------------------------------------
// LOS blocks.
// ---------------------------------------------------------------------------

BlockId OldGenSpace::addLosBlock(bool raw) {
    // Taken the way a bag page is, then materialized as a block outside
    // every size class.
    if (!ensureBagPageAvailable()) return NO_BLOCK_ID;
    const auto extent = unassigned_blocks_.back();
    unassigned_blocks_.pop_back();
    assert(static_cast<size_t>(extent.second - extent.first) == config_->alloc_buffer_size);
    BlockInfo bi;
    bi.start = extent.first;
    bi.end = extent.second;
    bi.end_of_objects = extent.second;   // live_bytes is clamped to this span
    bi.size_class = NUM_SIZE_CLASSES;
    bi.is_large = false;
    bi.los = static_cast<uint8_t>(kLosBlock | (raw ? kLosRaw : 0));
    const BlockId id =
        materializeBlock(bi, {0, 0, /*fully_swept=*/true}, bitmapBytesForBlock(bi));
    los_.addBlock(id.v, bi.start, raw);
    return id;
}

void* OldGenSpace::allocateLos(size_t bytes, bool raw, BlockId* block_out) {
    uint32_t idv = BlockId::kNone;
    void* p = los_.tryAllocate(bytes, raw, &idv);
    if (p == nullptr) {
        if (!addLosBlock(raw).valid()) return nullptr;
        p = los_.tryAllocate(bytes, raw, &idv);
        assert(p != nullptr && "allocateLos: a fresh LOS block must fit any LOS object");
    }
    *block_out = BlockId{idv};
    return p;
}

void OldGenSpace::freeLosCell(BlockId id, void* cell, size_t cell_size) {
    los_.free(id.v, cell, cell_size);
    // A deferred free may still be marked.
    testAndClearMarkBitInBlock(id, cell);
    BufferMetadata& bm = blocks_.meta(id);
    bm.live_bytes = (bm.live_bytes >= cell_size) ? bm.live_bytes - cell_size : 0;
    allocated_bytes = (allocated_bytes >= cell_size) ? allocated_bytes - cell_size : 0;
    frag_stats_.live_bytes =
        (frag_stats_.live_bytes >= cell_size) ? frag_stats_.live_bytes - cell_size : 0;
#if ECO_HEAP_VALIDATE
    std::memset(cell, 0xD8, cell_size);   // poison: nothing may read a freed LOS cell
#endif
}

void OldGenSpace::losSweepAtMarkEnd() {
    // Walks the index, not the blocks; deferred frees are not in it and are
    // freed later by processDeferredFrees. A nursery-owned id is dropped by
    // the next minor sweep.
    for (auto it = large_body_index_.begin(); it != large_body_index_.end();) {
        void* obj = it->first;
        const BlockId bid = contains(obj) ? blockIdFor(obj) : NO_BLOCK_ID;
        if (!bid.valid() || !isLosBlock(bid) || isMarkedInBlock(bid, obj)) {
            ++it;
            continue;
        }
        LargeBodyMeta& m = large_bodies_[it->second];
        freeLosCell(bid, obj, m.cell_size);
        retireIndexEntry(it->second);
        it = large_body_index_.erase(it);
    }
    // The marker attributes only scanned objects and raw bodies are never
    // scanned, so LOS live_bytes is taken from the LOS's used bytes.
    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        const BlockId id = blocks_.idAt(pos);
        const BlockInfo& b = blocks_.info(id);
        if (b.los & kLosBlock) {
            blocks_.meta(id).live_bytes = los_.usedBytes(id.v);
        } else if (b.is_large && (b.los & kLosRaw) && isMarkedInBlock(id, b.start)) {
            // A marked raw huge body was never scanned, so nothing attributed
            // its bytes; left at 0 the shrink would release a live block.
            blocks_.meta(id).live_bytes = b.totalBytes();
        }
    }
#if ECO_HEAP_VALIDATE
    validateLosTracking("losSweepAtMarkEnd");
#endif
}

#if ECO_HEAP_VALIDATE
void OldGenSpace::validateLosTracking(const char* where) const {
    std::unordered_map<uint32_t, size_t> tracked;
    auto add = [&](void* p, size_t cs) {
        if (p == nullptr || !contains(p)) return;
        const BlockId b = blockIdFor(p);
        if (b.valid() && isLosBlock(b)) tracked[b.v] += cs;
    };
    for (const auto& kv : large_body_index_) add(kv.first, large_bodies_[kv.second].cell_size);
    for (const LargeBodyMeta& m : deferred_frees_) add(m.body_base, m.cell_size);
    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        const BlockId id = blocks_.idAt(pos);
        if (!isLosBlock(id)) continue;
        const size_t used = los_.usedBytes(id.v);
        const auto it = tracked.find(id.v);
        const size_t t = it == tracked.end() ? 0 : it->second;
        if (used != t) {
            std::fprintf(stderr, "[heap-validate] HEAP_080 (%s): LOS block %u has %zu used "
                         "bytes but its tracked objects cover %zu\n", where, id.v, used, t);
            std::fflush(stderr);
            std::abort();
        }
    }
}
#endif

void OldGenSpace::losReleaseEmptyBlocks() {
    const auto empty = los_.emptyBlocks();
    const size_t keep = config_->los_empty_keep;
    if (empty.size() <= keep) return;
    // Never drop the committed heap below max(initial_old_gen_size,
    // alloc_buffer_size).
    const size_t min_heap =
        std::max(config_->initial_old_gen_size, config_->alloc_buffer_size);
    size_t current_heap = 0;
    for (size_t pos = 0; pos < blocks_.size(); ++pos)
        current_heap += blocks_.info(blocks_.idAt(pos)).totalBytes();
    for (const auto& e : unassigned_blocks_)
        current_heap += static_cast<size_t>(e.second - e.first);
    for (size_t k = keep; k < empty.size(); ++k) {
        const BlockId id{empty[k]};
        const size_t bytes = blocks_.info(id).totalBytes();
        if (current_heap < bytes || current_heap - bytes < min_heap) break;
        los_.removeBlock(id.v);
        releaseBlockToAllocator(id);
        current_heap -= bytes;
    }
}

void* OldGenSpace::allocateLargeBody(size_t total_size, size_t logical_size,
                                     Tag body_tag, bool initial_color) {
    assert(body_tag == Tag_String || body_tag == Tag_ByteBuffer);
    (void)logical_size;
    (void)body_tag;
    size_t raw_cell = 0;
    bool raw_large = false;
    void* raw = allocateRawCell(total_size, raw_cell, raw_large);
    if (!raw) return nullptr;
    registerLargeBody(raw, raw_cell, raw_large, initial_color);
    return raw;
}

void* OldGenSpace::allocateRawCell(size_t total_size, size_t& cell_size, bool& is_large) {
    total_size = (total_size + 7) & ~static_cast<size_t>(7);
    if (total_size <= los_.maxObjectBytes()) {
        BlockId bid;
        void* cell = allocateLos(total_size, /*raw=*/true, &bid);
        if (!cell) return nullptr;
        GC_STATS_OLDGEN_DIRECT_RECORD_ALLOC(alloc_stats_, total_size);
        cell_size = los_.granulesFor(total_size) * los_.granuleBytes();
        is_large = false;
        attributeNewCell(bid, cell, cell_size);
        allocated_bytes += cell_size;
        old_alloc_total_ += cell_size;
#if ECO_HEAP_VALIDATE
        if (cycleActive()) noteCycleAllocation(cell);
#endif
        return cell;
    }
    // allocate() writes an object header at the block start; the payload
    // overwrites it, and kLosRaw tells every reader there is no header.
    void* body = allocate(total_size);
    if (!body) return nullptr;
    GC_STATS_OLDGEN_DIRECT_RECORD_ALLOC(alloc_stats_, total_size);
    const BlockId hid = blockIdFor(body);
    assert(hid.valid() && blocks_.info(hid).is_large);
    blocks_.info(hid).los = kLosRaw;
    cell_size = blocks_.info(hid).totalBytes();
    is_large = true;
    return body;
}

void OldGenSpace::attributeNewCell(BlockId block_id, void* obj, size_t cell_bytes) {
    // initObjectHeaderWithSize without the header.
    const bool black = marking_active || gc_phase_ != GCPhase::Idle;
    if (black) {
#if ECO_HEAP_VALIDATE
        assertCellWasWhite(block_id, obj);
#endif
        setMarkBitAtomic(block_id, obj);
    }
    if (black || par_promo_active_) {
        std::atomic_ref<uint64_t>(blocks_.meta(block_id).live_bytes)
            .fetch_add(cell_bytes, std::memory_order_relaxed);
    } else {
        blocks_.meta(block_id).live_bytes += cell_bytes;
    }
}

bool OldGenSpace::isRawBody(const void* p) const {
    if (!contains(const_cast<void*>(p))) return false;
    const BlockId id = blockIdFor(p);
    return id.valid() && (blocks_.info(id).los & kLosRaw) != 0;
}

void* OldGenSpace::allocateYoungLarge(size_t size, Tag tag, bool initial_color) {
    size = (size + 7) & ~static_cast<size_t>(7);
    size_t cell_size = 0;
    bool is_large = false;
    void* obj = allocateTrackedCell(size, cell_size, is_large);
    if (!obj) return nullptr;

    // Keep the colour the allocation chose; pin the object, as it is never
    // moved.
    Header* hdr = getHeader(obj);
    const u32 saved_color = hdr->color;
    initHeaderForTag(hdr, tag, size);
    Header h = loadHeaderRelaxed(hdr);
    h.color = saved_color;
    h.pin = 1;
    h.age = 0;
    storeHeaderRelaxed(hdr, h);                  // one word: never a size without its K

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

void* OldGenSpace::allocateOldLarge(size_t size, Tag tag) {
    size = (size + 7) & ~static_cast<size_t>(7);
    size_t cell_size = 0;
    bool is_large = false;
    void* obj = allocateTrackedCell(size, cell_size, is_large);
    if (!obj) return nullptr;
    Header* hdr = getHeader(obj);
    const u32 saved_color = hdr->color;
    initHeaderForTag(hdr, tag, size);
    Header h = loadHeaderRelaxed(hdr);
    h.color = saved_color;
    h.pin = 1;
    storeHeaderRelaxed(hdr, h);
    registerLargeBody(obj, cell_size, is_large, /*minor_color=*/false, /*kind=*/2,
                      /*owned=*/false);
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
    // It stays in the index so the major GC frees it when unmarked.
    large_bodies_[id].kind = 2;
    // Age 0, as for a promoted copy. The young bounding box stays wide until
    // the minor's recompute. A sweep slice may read this header word
    // concurrently, hence one relaxed whole-word store.
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
    if (large_bodies_[id].kind == 2) free_large_body_ids_.push_back(id);
}

// TLA-REGION(OGS.registerLargeBody) begin
OldGenSpace::LargeBodyId OldGenSpace::registerLargeBody(
        void* body, size_t cell_size, bool is_large, bool minor_color, uint8_t kind,
        bool owned) {
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
    if (owned) nursery_owned_bodies_.push_back(id);
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
    // The body may have been freed and its cell reused by a young large
    // object (kind 1). Colouring that would make its first reach report
    // "already reached" and leave it unscanned.
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
    for (size_t k = 0; k < nursery_owned_bodies_.size(); ++k) {
        if (nursery_owned_bodies_[k] == id) {
            nursery_owned_bodies_[k] = nursery_owned_bodies_.back();
            nursery_owned_bodies_.pop_back();
            break;
        }
    }
    // It stays in the index: the LOS frees memory only through the index,
    // so an untracked body would never be freed.
    if (id < large_bodies_.size()) large_bodies_[id].kind = 2;
}

// TLA-REGION(OGS.sweepNurseryLargeBodies) begin
size_t OldGenSpace::sweepNurseryLargeBodies(bool minor_color) {
    // The common case: nothing nursery-owned.
    if (nursery_owned_bodies_.empty()) {
        if (ylo_count_ != 0) recomputeYoungLargeBounds();   // all promoted
        return 0;
    }

    assert(compact_phase_ != CompactionPhase::Evacuating &&
           compact_phase_ != CompactionPhase::FixingRefs &&
           "sweepNurseryLargeBodies must not run during compaction");

    // During a compaction nothing is freed: compaction moves blocks and
    // their metadata. The statistics count the bytes left for a later sweep.
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
        // A retired entry, or a stale duplicate of an id now held by an old
        // large object (kind 2): drop it without freeing or recycling.
        if (m.body_base == nullptr || m.kind == 2) {
            nursery_owned_bodies_[k] = nursery_owned_bodies_.back();
            nursery_owned_bodies_.pop_back();
            continue;
        }
        if (m.color == minor_color) {
            ++k;
            continue;
        }
        // The owning header (or, for kind 1, the object itself) was not
        // reached by this minor GC.
#if ENABLE_GC_STATS
        const size_t freed_bytes = m.cell_size;
        if (m.kind == 1) alloc_stats_.lp.ylos_freed_minor++;
#endif
        if (__builtin_expect(cycle_state_ != CycleState::Idle, 0)) {
            // The running cycle may have marked or greyed the cell: unlink it
            // now and leave it on deferred_frees_ to be freed after the cycle.
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

    // Shrinks the young bounding box after this minor's promotions and frees.
    recomputeYoungLargeBounds();
    return freed;
}
// TLA-REGION(OGS.sweepNurseryLargeBodies) end

// TLA-REGION(OGS.freeLargeBodyCell) begin
void OldGenSpace::freeLargeBodyCell(LargeBodyMeta& m) {
    if (m.body_base == nullptr) return;
    assert(!cycleActive() && "freeLargeBodyCell during an incremental mark cycle");
    large_body_index_.erase(m.body_base);

    if (!m.is_large && contains(m.body_base)) {
        const BlockId lid = blockIdFor(m.body_base);
        if (lid.valid() && isLosBlock(lid)) {
            freeLosCell(lid, m.body_base, m.cell_size);
            m.body_base = nullptr;
            return;
        }
    }

    if (m.is_large) {
        if (!contains(m.body_base)) { m.body_base = nullptr; return; }
        const BlockId idx = blockIdFor(m.body_base);
        if (!idx.valid() || !blocks_.info(idx).is_large) {
            m.body_base = nullptr;
            return;
        }
        bool already_free = false;
        for (BlockId fb : free_large_blocks_) {
            if (fb == idx) { already_free = true; break; }
        }
        if (!already_free) {
            {
                BufferMetadata& bm = blocks_.meta(idx);
                // Mid-mark, drop the marker's pending attribution as well.
                if (marking_active) (void)markLiveTake(idx);
                bm.live_bytes = 0;
                bm.garbage_bytes = blocks_.info(idx).totalBytes();
                bm.fully_swept = true;
            }
            blocks_.largeMark(idx) = 0;
            // A walker sees a free cell. The block is not on a free list, so
            // it gets no free-list sentinel (age 0).
            Header* hdr = reinterpret_cast<Header*>(m.body_base);
            std::memset(hdr, 0, sizeof(Header));
            hdr->tag = Tag_Free;
            hdr->size = static_cast<u32>(blocks_.info(idx).totalBytes());
            hdr->color = static_cast<u32>(Color::White);
            hdr->age = 0;
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
        if (contains(m.body_base)) {
            const BlockId idx = blockIdFor(m.body_base);
            if (idx.valid() && !blocks_.info(idx).is_large &&
                config_->old_gen_bitmap_alloc) {
                // Bitmap mode uses no free-list sentinels.
                assert(gc_phase_ != GCPhase::Marking);
                char* cell = static_cast<char*>(m.body_base);
                const bool uniform =
                    blocks_.info(idx).size_class < num_size_classes_;
                // Whether the sweep will still walk over this cell, not just
                // whether the block is unfinished.
                const bool unswept_mixed = !uniform && sweepWillReach(idx, cell);
                bool count_garbage = true;
                if (uniform) {
                    freeUniformCell(idx, cell);
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
                testAndClearMarkBitInBlock(idx, m.body_base);
                // A sentinel keeps the lazy-sweep coalescer off a cell the
                // sweep may still walk past: during Marking every block will
                // be swept, during Sweeping only the unswept ones.
                bool need_sentinel = false;
                switch (gc_phase_) {
                    case GCPhase::Idle:
                        need_sentinel = false;
                        break;
                    case GCPhase::Marking:
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
                    // The clamped subtraction does not commute with the
                    // marker's additions, so fold its pending ones in first.
                    if (marking_active) bm.live_bytes += markLiveTake(idx);
                    if (bm.live_bytes >= m.cell_size) {
                        bm.live_bytes -= m.cell_size;
                    } else {
                        bm.live_bytes = 0;
                    }
                    // The sweep's coalescer skips sentinel cells, so it does
                    // not count these bytes as garbage.
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
// Metadata validators (ECO_HEAP_VALIDATE only).
// ===========================================================================
#if ECO_HEAP_VALIDATE
// Prints `what` for check site `where` to stderr and aborts.
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
                // No list cell in a uniform block (the cursor would allocate
                // it twice), none ahead of the sweep, and no sentinels.
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
    // No metadata storage has moved since reserveMetadata().
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

    // Order and position agree over live ids; every id below the high-water
    // mark is either live or on the free stack, once.
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

    // Every live block's page slots name it; every committed slot's owners
    // are live blocks whose extent intersects the slot.
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

    // Stored block ids name live blocks; the position cursors are in range.
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
        // Outside a mark, a uniform block's live_bytes (plus its cursor's
        // pending bytes) is its marked cells times the cell size, and no bit
        // is set off a cell start or past the last cell.
        if (!marking_active) {
            for (size_t pos = 0; pos < blocks_.size(); ++pos) {
                const BlockId id = blocks_.idAt(pos);
                const BlockInfo& b = blocks_.info(id);
                if (b.is_large || b.size_class >= num_size_classes_) continue;
                // A tenure block's bits belong to the collector until its
                // live bytes are merged.
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
        // Cursors and partial queues agree with each block's allocation state.
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

    validateFreeListBackLinks(where);
}

void OldGenSpace::validateEveryNthMinor() {
    if ((++validate_minor_count_ & 63) == 0) {
        validateOldGenMetadata("minorGC(every 64th)");
    }
}
#endif

} // namespace Elm
