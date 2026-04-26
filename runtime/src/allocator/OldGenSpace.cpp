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
#include <chrono>
#include <limits>
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>

namespace Elm {

// Global heap base (defined in Allocator.cpp).
extern char* g_heap_base;

// Forward decl — defined later in this TU; called from member functions
// above the definition.
namespace {
inline void pushSpanOnFreeLists(FreeCell** free_lists, char* span_start,
                                size_t span_bytes,
                                const BlockInfo* block);

// When non-zero, releaseBlockToAllocator skips the per-call recomputation
// of region_base_/region_end_ — the caller (typically `maybeShrinkCapacity`)
// is in batch mode and will recompute bounds once at the end. Avoids an
// O(N) scan inside each release call when shrink is freeing thousands of
// blocks in one pass.
thread_local int g_batch_release_depth = 0;
}

// Read barrier - converts logical pointer to physical address.
// Does not follow forwarding pointers (use Allocator::resolve() for that).
void* readBarrier(HPointer& ptr) {
    // Check for embedded constants.
    assert(ptr.constant == 0 && "Cannot read barrier on embedded constant");

    // Convert logical pointer to physical address and return.
    return g_heap_base + (ptr.ptr << 3);
}

// Sentinel value indicating no current block.
static constexpr size_t NO_BLOCK = std::numeric_limits<size_t>::max();

OldGenSpace::OldGenSpace() :
    config_(nullptr), allocator_(nullptr),
    num_size_classes_(NUM_SMALL_CLASSES),
    allocated_bytes(0),
    region_base_(nullptr), region_end_(nullptr),
    gc_phase_(GCPhase::Idle),
    current_epoch(0), marking_active(false), allocator_ref_(nullptr),
    sweep_buffer_index_(0), sweep_cursor_(nullptr),
    frag_stats_{0, 0, 0},
    compact_phase_(CompactionPhase::Idle),
    current_evac_index_(0), evac_cursor_(nullptr),
    evac_block_index_(NO_BLOCK), evac_alloc_ptr_(nullptr),
    fixup_buffer_index_(0), fixup_cursor_(nullptr) {
    // Initialize free lists to empty.
    for (size_t i = 0; i < NUM_SIZE_CLASSES; i++) {
        free_lists_[i] = nullptr;
    }
}

OldGenSpace::~OldGenSpace() {
    // Memory blocks are owned by the Allocator's mmap region, not us.
    // Just clear our tracking structures.
    blocks_.clear();
    unassigned_blocks_.clear();
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
                // Reserve `heap_base + 0`: HPointer{ptr=0, constant=0} encodes
                // to bits=0, which the runtime (eco_get_tag) treats as null.
                // Any cell handed out at heap_base+0 would look null to a
                // reader. Bump page 0's start past offset 0 to avoid this.
                if (page_start == g_heap_base) {
                    page_start += 8;
                }
                unassigned_blocks_.emplace_back(page_start, page_end);
            }
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
    blocks_.clear();
    buffer_meta_.clear();
    unassigned_blocks_.clear();

    // Reset state.
    allocated_bytes = 0;
    region_base_ = nullptr;
    region_end_ = nullptr;
    gc_phase_ = GCPhase::Idle;
    marking_active = false;
    current_epoch = 0;
    mark_stack.clear();
    sweep_buffer_index_ = 0;
    sweep_cursor_ = nullptr;

    // Clear all free lists.
    for (size_t i = 0; i < NUM_SIZE_CLASSES; i++) {
        free_lists_[i] = nullptr;
    }
    free_large_blocks_.clear();

    // Reset fragmentation stats.
    frag_stats_ = {0, 0, 0};

    // Reset compaction state.
    compact_phase_ = CompactionPhase::Idle;
    evacuation_set_.clear();
    current_evac_index_ = 0;
    evac_cursor_ = nullptr;
    evac_block_index_ = NO_BLOCK;
    evac_alloc_ptr_ = nullptr;
    fixup_buffer_index_ = 0;
    fixup_cursor_ = nullptr;
}

// ---------------------------------------------------------------------------
// Header initialization helper.
// ---------------------------------------------------------------------------
void OldGenSpace::initObjectHeader(void* obj) {
    // Defense: never hand out heap_base+0. Its HPointer encoding is bits=0,
    // which the runtime treats as null (eco_get_tag asserts). The bag is
    // initialized in OldGenSpace::initialize so the first page skips offset 0,
    // but assert here in case future code changes regress this invariant.
    assert(reinterpret_cast<char*>(obj) != g_heap_base &&
           "OldGenSpace handed out heap_base+0; HPointer encoding would be null");

    Header* hdr = reinterpret_cast<Header*>(obj);
    std::memset(hdr, 0, sizeof(Header));
    // Mid-cycle allocations must be Black so the current sweep does not
    // reclaim them; otherwise White (the next GC cycle will mark them).
    if (marking_active || gc_phase_ != GCPhase::Idle) {
        hdr->color = static_cast<u32>(Color::Black);
    } else {
        hdr->color = static_cast<u32>(Color::White);
    }
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

    // Allocation-paced marking: do marking work proportional to allocation.
    if (gc_phase_ == GCPhase::Marking && !mark_stack.empty()) {
        size_t mark_budget = size * MARK_WORK_RATIO;
#if ENABLE_GC_STATS
        // Stats are not available on the allocation hot path; inline a
        // minimal marking step that mirrors incrementalMark without
        // touching the stats counters.
        while (mark_budget > 0 && !mark_stack.empty()) {
            void *obj = mark_stack.back();
            mark_stack.pop_back();
            Header *hdr = getHeader(obj);
            if (hdr->tag == Tag_Free) continue;
            if (hdr->color == static_cast<u32>(Color::Black)) continue;
            hdr->color = static_cast<u32>(Color::Grey);
            markChildren(obj);
            hdr->color = static_cast<u32>(Color::Black);
            mark_budget = (mark_budget > 1) ? mark_budget - 1 : 0;
        }
#else
        incrementalMark(mark_budget);
#endif
        if (mark_stack.empty()) {
            transitionToSweeping();
        }
    }

    // Drive lazy sweep work to make sure free lists fill up before we exhaust
    // the bag. Without this, all unassigned pages can be consumed before the
    // sweep ever returns garbage to a free list.
    if (gc_phase_ == GCPhase::Sweeping) {
        size_t cls_for_sweep = sizeClass(size);
        lazySweep(cls_for_sweep, SWEEP_WORK_BUDGET);
    }

    // Path 2: large objects bypass the BBoP and get a dedicated pinned block.
    if (size >= config_->alloc_buffer_size) {
        return allocateLargeBlock(size);
    }

    size_t cls = sizeClass(size);
    if (cls < num_size_classes_) {
        // Path 3: size-class fast path (small or medium).
        return allocateFromSizeClass(cls, size);
    }

    // Path 4: in [largest fixed-cell size, alloc_buffer_size). Pull a page,
    // wrap it as one big Tag_Free, and split off the requested chunk.
    return allocateFromBagPage(size);
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
}

// ---------------------------------------------------------------------------
// Size-class fast path.
// ---------------------------------------------------------------------------
void* OldGenSpace::allocateFromSizeClass(size_t cls, size_t requested_size) {
    assert(cls < num_size_classes_ && "size class out of range");

    // 1) Pop from this class's free list if non-empty.
    //    Cell carries the full class size; the slack between requested_size
    //    and classToSize(cls) is unrecoverable for re-allocation, so the
    //    cell-size is the correct figure for getAllocatedBytes() until the
    //    next sweep. We DO write a Tag_Free trailing into the slack so
    //    sweep walks past this cell correctly even when it lives in a
    //    MIXED block (size_class == NUM_SIZE_CLASSES).
    if (free_lists_[cls] != nullptr) {
        FreeCell* cell = free_lists_[cls];
        free_lists_[cls] = cell->next;
        void* result = static_cast<void*>(cell);
        initObjectHeader(result);
        padCellSlack(result, requested_size, classToSize(cls));
        allocated_bytes += classToSize(cls);
        return result;
    }

    // 2) Try splitting a larger free cell. The split path itself accounts
    //    for the carved-out portion via allocated_bytes += alloc_size and
    //    pads the slack with a Tag_Free trailing for MIXED-block sweeps.
    if (void* result = tryAllocateBySplittingLarger(cls, classToSize(cls))) {
        padCellSlack(result, requested_size, classToSize(cls));
        return result;
    }

    // 3) Pull a page from the bag and slice it into uniform cells. Cells
    //    from a freshly-populated page are in a size-class block (sweep
    //    walks by classToSize), so the slack pad is a no-op for sweep
    //    correctness, but still safe.
    if (populateFromBlock(cls)) {
        FreeCell* cell = free_lists_[cls];
        if (cell != nullptr) {
            free_lists_[cls] = cell->next;
            void* result = static_cast<void*>(cell);
            initObjectHeader(result);
            padCellSlack(result, requested_size, classToSize(cls));
            allocated_bytes += classToSize(cls);
            return result;
        }
    }

    // 4) Last resort: split from a freshly-pulled page treated as one big
    //    cell. allocateFromBagPage accounts for its own bytes.
    if (void* result = allocateFromBagPage(requested_size)) {
        return result;
    }

    // 5) Truly out of memory in this old gen.
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
    for (size_t cls = target_cls + 1; cls < NUM_SIZE_CLASSES; ++cls) {
        if (free_lists_[cls] == nullptr) continue;

        const bool maybe_uniform_block = cls < num_size_classes_;

        FreeCell** prev = &free_lists_[cls];
        FreeCell* curr = free_lists_[cls];
        while (curr != nullptr) {
            const size_t cell_bytes = curr->header.size;
            const size_t remainder = (cell_bytes >= alloc_size)
                                         ? cell_bytes - alloc_size
                                         : 0;

            // For potentially-uniform classes (cls < num_size_classes_)
            // accept only exact fits to preserve the uniform-block invariant
            // without paying for an O(N) lookup. For higher classes, splits
            // are always safe.
            const bool acceptable_for_block =
                !maybe_uniform_block || remainder == 0;

            if (cell_bytes >= alloc_size &&
                (remainder == 0 || remainder >= MIN_FREE_CELL_SIZE) &&
                acceptable_for_block) {
                // Unlink curr from this list.
                *prev = curr->next;

                char* base = reinterpret_cast<char*>(curr);
                if (remainder > 0) {
                    // No block context passed: cells we split came from a
                    // class >= num_size_classes_, which only exists in mixed
                    // blocks, so the mixed (any-class packing) path in
                    // pushSpanOnFreeLists is correct.
                    pushSpanOnFreeLists(free_lists_, base + alloc_size,
                                        remainder, nullptr);
                }

                void* result = static_cast<void*>(base);
                initObjectHeader(result);
                allocated_bytes += alloc_size;
                return result;
            }

            prev = &curr->next;
            curr = curr->next;
        }
    }

    return nullptr;
}

// ---------------------------------------------------------------------------
// Page-as-single-cell + split path.
// ---------------------------------------------------------------------------
void* OldGenSpace::allocateFromBagPage(size_t requested_size) {
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
        }
    }
    if (unassigned_blocks_.empty()) return nullptr;

    auto extent = unassigned_blocks_.back();
    unassigned_blocks_.pop_back();

    char* page_start = extent.first;
    char* page_end = extent.second;
    const size_t page_size = static_cast<size_t>(page_end - page_start);
    assert(requested_size <= page_size && "request larger than a single page");

    // Materialize a BlockInfo for this page. Sweep parses up to end_of_objects;
    // we set it to the page end so the single Tag_Free below is parseable, and
    // any subsequent splits remain parseable as well.
    BlockInfo bi;
    bi.start = page_start;
    bi.end = page_end;
    bi.end_of_objects = page_end;
    bi.size_class = NUM_SIZE_CLASSES;  // mixed/non-uniform
    bi.is_large = false;
    blocks_.push_back(bi);
    const size_t block_idx = blocks_.size() - 1;
    buffer_meta_.push_back({block_idx, 0, 0, false});

    // Wrap the entire page as one Tag_Free cell, then split off the request.
    FreeCell* whole = reinterpret_cast<FreeCell*>(page_start);
    std::memset(&whole->header, 0, sizeof(Header));
    whole->header.tag = Tag_Free;
    whole->header.size = static_cast<u32>(page_size);
    whole->header.color = static_cast<u32>(Color::White);

    // Carve the request off the front; route the remainder via the recursive
    // span-pusher so each placed cell exactly matches its class's cellSize.
    // The block was just created with size_class = NUM_SIZE_CLASSES (mixed),
    // so `pushSpanOnFreeLists` will use its any-class packing scheme.
    const size_t remainder = page_size - requested_size;
    if (remainder >= MIN_FREE_CELL_SIZE) {
        pushSpanOnFreeLists(free_lists_, page_start + requested_size,
                            remainder, &blocks_.back());
    }

    void* result = static_cast<void*>(page_start);
    initObjectHeader(result);
    allocated_bytes += requested_size;
    return result;
}

// ---------------------------------------------------------------------------
// Population from a bag page (uniform fixed-cell slicing for a class).
// ---------------------------------------------------------------------------
bool OldGenSpace::populateFromBlock(size_t cls) {
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
    blocks_.push_back(bi);
    const size_t block_idx = blocks_.size() - 1;
    buffer_meta_.push_back({block_idx, 0, 0, false});

    // Slice into uniform Tag_Free cells and link onto the class's free list.
    // Push in reverse so iteration order matches address order.
    for (size_t i = num_cells; i > 0; --i) {
        char* cell_addr = page_start + (i - 1) * cell_bytes;
        FreeCell* cell = reinterpret_cast<FreeCell*>(cell_addr);
        std::memset(&cell->header, 0, sizeof(Header));
        cell->header.tag = Tag_Free;
        cell->header.size = static_cast<u32>(cell_bytes);
        cell->header.color = static_cast<u32>(Color::White);
        cell->next = free_lists_[cls];
        free_lists_[cls] = cell;
    }

    return true;
}

// ---------------------------------------------------------------------------
// Dedicated large block (>= alloc_buffer_size).
// ---------------------------------------------------------------------------

void OldGenSpace::markBlockAsFreeLarge(size_t block_index) {
    assert(block_index < blocks_.size() && "markBlockAsFreeLarge: index OOB");
    assert(blocks_[block_index].is_large &&
           "markBlockAsFreeLarge: block must be is_large");
#if ECO_GC_DEBUG
    for (size_t idx : free_large_blocks_) {
        assert(idx != block_index &&
               "markBlockAsFreeLarge: duplicate entry");
    }
#endif
    free_large_blocks_.push_back(block_index);
}

void* OldGenSpace::allocateFromFreeLargeBlocks(size_t size) {
    size = (size + 7) & ~7;

    for (size_t k = 0; k < free_large_blocks_.size(); ++k) {
        const size_t idx = free_large_blocks_[k];
        if (idx >= blocks_.size()) continue;
        BlockInfo& blk = blocks_[idx];
        if (blk.totalBytes() < size) continue;

        // swap-remove from free list.
        free_large_blocks_[k] = free_large_blocks_.back();
        free_large_blocks_.pop_back();

        // Resurrect the BlockInfo: parseable region covers just the new
        // object so sweep walks one header.
        const size_t total = blk.totalBytes();
        blk.end_of_objects = blk.start + size;

        // Reset metadata.
        if (idx < buffer_meta_.size()) {
            buffer_meta_[idx].live_bytes = size;
            buffer_meta_[idx].garbage_bytes =
                (total >= size) ? (total - size) : 0;
            buffer_meta_[idx].fully_swept = true;
        }

        frag_stats_.live_bytes += size;
        allocated_bytes += size;

        initObjectHeader(blk.start);
        return static_cast<void*>(blk.start);
    }
    return nullptr;
}

void* OldGenSpace::allocateFromEmptyRegularBlocks(size_t size) {
    size = (size + 7) & ~7;

    for (size_t i = 0; i < blocks_.size(); ++i) {
        if (i >= buffer_meta_.size()) continue;
        const BufferMetadata& meta = buffer_meta_[i];
        if (!meta.fully_swept || meta.live_bytes != 0) continue;
        if (blocks_[i].is_large) continue;
        if (blocks_[i].totalBytes() < size) continue;

        // Drop any embedded free cells before flipping is_large; otherwise
        // the next sweep would walk the now-large block as if it were a
        // size-class page.
        removeFreeCellsForBlock(i);

        BlockInfo& blk = blocks_[i];
        const size_t total = blk.totalBytes();
        blk.is_large = true;
        blk.size_class = NUM_SIZE_CLASSES;
        blk.end_of_objects = blk.start + size;

        buffer_meta_[i].live_bytes = size;
        buffer_meta_[i].garbage_bytes =
            (total >= size) ? (total - size) : 0;
        buffer_meta_[i].fully_swept = true;

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
    // the next acquire stays aligned.
    constexpr size_t PAGE_SIZE = 4096;
    size_t block_size = (size + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);

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
    blocks_.push_back(bi);
    const size_t block_idx = blocks_.size() - 1;
    buffer_meta_.push_back({block_idx, size, 0, false});

    // Maintain the cached contains() bounds.
    if (region_base_ == nullptr || block_base < region_base_) {
        region_base_ = block_base;
    }
    if (block_base + block_size > region_end_) {
        region_end_ = block_base + block_size;
    }

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

    // Defense-in-depth: reset any Black cell in old gen back to White before
    // we begin marking. Sweep already does this for every cell it walks, but
    // a stale Black can still reach old gen via the minor-GC promotion /
    // to-space `memcpy` (it copies the source header verbatim — see the
    // matching color reset in NurserySpace::evacuate). If any leak path is
    // missed, the next mark cycle would see a Black cell as already-processed
    // and skip its children, leaving them White → swept → Tag_Free, and
    // subsequent reads of the parent's pointer fields hit a freed cell.
    //
    // O(N) per major GC; toggled off with ECO_GC_RESET_BLACK_AT_MARK=0.
    {
        const char* e = std::getenv("ECO_GC_RESET_BLACK_AT_MARK");
        const bool enabled = !(e && e[0] == '0' && e[1] == '\0');
        if (enabled) {
            for (auto& blk : blocks_) {
                char* p = blk.start;
                char* end = blk.end_of_objects;
                while (p < end) {
                    Header* hdr = reinterpret_cast<Header*>(p);
                    size_t step;
                    if (hdr->tag == Tag_Free) {
                        step = hdr->size;
                    } else if (blk.is_large) {
                        step = blk.totalBytes();
                    } else {
                        step = (getObjectSize(p) + 7) & ~static_cast<size_t>(7);
                        if (step < 8) step = 8;
                    }
                    if (hdr->tag != Tag_Free &&
                        hdr->color == static_cast<u32>(Color::Black)) {
                        hdr->color = static_cast<u32>(Color::White);
                    }
                    p += step;
                    if (step == 0) break;
                }
            }
        }
    }

    marking_active = true;
    current_epoch++;
    mark_stack.clear();

    // Store Allocator reference for nursery checks during marking.
    allocator_ref_ = &alloc;

    // Push ALL roots onto mark stack - including nursery objects.
    // Embedded constants live entirely in the `constant` tag; filter them.
    for (HPointer *root: roots) {
        if (root->constant != 0) continue;
        void *obj = Allocator::fromPointerRaw(*root);
        if (obj && alloc.isInHeap(obj)) {
            mark_stack.push_back(obj);
        }
    }

    // Push JIT roots (raw 64-bit heap pointers from JIT-compiled globals).
    for (uint64_t *root: jit_roots) {
        uint64_t val = *root;

        uint64_t ptr_part = val & 0xFFFFFFFFFFULL;
        uint64_t const_part = (val >> 40) & 0xF;
        if (ptr_part == 0 && const_part >= 1 && const_part <= 7) {
            continue;  // Skip embedded constants.
        }

        void *obj = reinterpret_cast<void*>(val);
        if (obj && alloc.isInHeap(obj)) {
            mark_stack.push_back(obj);
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

    while (!mark_stack.empty() && units_done < work_units) {
        void *obj = mark_stack.back();
        mark_stack.pop_back();

        Header *hdr = getHeader(obj);

        // Skip free cells defensively (a stale mark-stack entry could in
        // principle point at one if the heap layout were inconsistent; the
        // marker should never traverse Tag_Free).
        if (hdr->tag == Tag_Free) continue;

        // Skip if already black.
        if (hdr->color == static_cast<u32>(Color::Black)) {
            continue;
        }

        // Mark grey first.
        hdr->color = static_cast<u32>(Color::Grey);

        // Process children.
        markChildren(obj);

        // Mark black.
        hdr->color = static_cast<u32>(Color::Black);


        units_done++;
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
            // Iterate hdr->size (== max_values) to match the nursery scan
            // (NurserySpace::scanObject Tag_Closure). n_values is the count
            // of slots already written by the closure-construction sequence
            // and may be less than max_values mid-construction; using it
            // here would skip captures that are stored but not yet "applied"
            // and let major GC reclaim them.
            Closure *cl = static_cast<Closure *>(obj);
            for (u32 i = 0; i < hdr->size; i++) {
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
            markHPointer(t->value);
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
        // Tag_ByteBuffer: No pointers to mark (raw bytes only).
        // Tag_FieldGroup: No pointers to mark (field IDs only).
        // Tag_Int, Tag_Float, Tag_Char, Tag_String: No children.
        // Tag_Free: Never traversed.
        default:
            break;
    }
}

void OldGenSpace::markHPointer(HPointer &ptr) {
    if (ptr.constant != 0)
        return;

    void *obj = Allocator::fromPointerRaw(ptr);
    if (!obj)
        return;

    if (allocator_ref_ && allocator_ref_->isInHeap(obj)) {
        Header *hdr = getHeader(obj);
        if (hdr->color != static_cast<u32>(Color::Black)) {
            mark_stack.push_back(obj);
        }
    }
}

void OldGenSpace::markUnboxable(Unboxable &val, bool is_boxed) {
    if (is_boxed) {
        markHPointer(val.p);
    }
}

/**
 * Complete marking phase and perform sweep.
 */
#if ENABLE_GC_STATS
void OldGenSpace::finishMarkAndSweep(GCStats &stats) {
    while (incrementalMark(1000, stats)) {
        // Keep marking.
    }

    sweep();

    marking_active = false;

    GC_STATS_MAJOR_INC_MARK_SWEEP(stats);
}

void OldGenSpace::finishMarkAndSweep(GCStats &stats,
                                     MajorGCPhaseProfile &profile) {
    auto t_mark_start = std::chrono::high_resolution_clock::now();
    while (true) {
        if (mark_stack.size() > profile.mark_stack_peak)
            profile.mark_stack_peak = mark_stack.size();
        bool more = incrementalMark(1000, stats);
        profile.mark_iterations++;
        if (!more) break;
    }
    auto t_mark_end = std::chrono::high_resolution_clock::now();

    auto t_sweep_start = t_mark_end;
    sweep();
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

    marking_active = false;

    GC_STATS_MAJOR_INC_MARK_SWEEP(stats);
}
#else
void OldGenSpace::finishMarkAndSweep() {
    while (incrementalMark(1000)) {
        // Keep marking.
    }

    sweep();

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

    sweep();
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
inline void pushSpanOnFreeLists(FreeCell** free_lists, char* span_start,
                                size_t span_bytes,
                                const BlockInfo* block = nullptr) {
    // Diagnostic (gated on ECO_OLDGEN_DEBUG): catch sweep bugs where step >
    // remaining bytes pushes a coalesced run past the block boundary, which
    // would corrupt cells in subsequent blocks. Shipped guarded so production
    // pays nothing.
    static const bool kDbg = std::getenv("ECO_OLDGEN_DEBUG") != nullptr;
    if (kDbg && block != nullptr) {
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
    // For UNIFORM size-class blocks, walkStep advances by classToSize(cls),
    // so every cell in the block must be exactly classToSize(cls) bytes.
    // Slice the span into class-sized cells so sweep's next walk does not
    // misstep mid-cell.
    if (block != nullptr && block->size_class < NUM_SIZE_CLASSES) {
        size_t cls = block->size_class;
        size_t cellSize = OldGenSpaceTestAccess::classToSize(cls);
        while (span_bytes >= cellSize) {
            FreeCell* cell = reinterpret_cast<FreeCell*>(span_start);
            std::memset(&cell->header, 0, sizeof(Header));
            cell->header.tag = Tag_Free;
            cell->header.size = static_cast<u32>(cellSize);
            cell->header.color = static_cast<u32>(Color::White);
            cell->next = free_lists[cls];
            free_lists[cls] = cell;
            span_start += cellSize;
            span_bytes -= cellSize;
        }
        if (span_bytes >= sizeof(Header)) {
            Header* hdr = reinterpret_cast<Header*>(span_start);
            std::memset(hdr, 0, sizeof(Header));
            hdr->tag = Tag_Free;
            hdr->size = static_cast<u32>(span_bytes);
            hdr->color = static_cast<u32>(Color::White);
        }
        return;
    }

    // Mixed/large block (or no block info): pack into the largest classes
    // that fit, descending. This is the original behaviour.
    while (span_bytes >= MIN_FREE_CELL_SIZE) {
        size_t cls = OldGenSpaceTestAccess::freeListClassFor(span_bytes);
        if (cls >= NUM_SIZE_CLASSES) break;  // Below smallest class.
        size_t cellSize = OldGenSpaceTestAccess::classToSize(cls);

        FreeCell* cell = reinterpret_cast<FreeCell*>(span_start);
        std::memset(&cell->header, 0, sizeof(Header));
        cell->header.tag = Tag_Free;
        cell->header.size = static_cast<u32>(cellSize);
        cell->header.color = static_cast<u32>(Color::White);
        cell->next = free_lists[cls];
        free_lists[cls] = cell;

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
    }
}

inline void pushCoalescedFreeCell(FreeCell** free_lists, char* span_start,
                                  size_t span_bytes,
                                  const BlockInfo* block = nullptr) {
    pushSpanOnFreeLists(free_lists, span_start, span_bytes, block);
}

// Bytes to advance per step when walking a block linearly. Size-class
// blocks reserve a fixed cell per object (slack between the object's
// logical size and the cell boundary belongs to that allocation), so the
// walk must advance by the cell size, not the object's logical size, or
// it will land mid-cell and start parsing FreeCell.next pointers as if
// they were object headers. Bag pages and large blocks pack tightly, so
// they advance by the object's logical size.
inline size_t walkStep(const BlockInfo& block, size_t obj_size) {
    if (block.size_class < NUM_SIZE_CLASSES) {
        return OldGenSpaceTestAccess::classToSize(block.size_class);
    }
    return obj_size;
}

}  // namespace

void OldGenSpace::sweep() {
    // Clear all free lists before rebuilding them.
    for (size_t i = 0; i < NUM_SIZE_CLASSES; i++) {
        free_lists_[i] = nullptr;
    }

    while (buffer_meta_.size() < blocks_.size()) {
        buffer_meta_.push_back({buffer_meta_.size(), 0, 0, false});
    }

    for (size_t buf_idx = 0; buf_idx < blocks_.size(); buf_idx++) {
        BlockInfo& block = blocks_[buf_idx];
        char* ptr = block.start;
        char* used_end = block.end_of_objects;

        buffer_meta_[buf_idx].live_bytes = 0;
        buffer_meta_[buf_idx].garbage_bytes = 0;
        buffer_meta_[buf_idx].fully_swept = true;

        // Large/pinned blocks hold a single object. If it died, register the
        // whole block on `free_large_blocks_` rather than building a Tag_Free
        // cell — these blocks can't be sliced for size classes anyway, and
        // recording a free-large entry lets the next allocateLargeBlock reuse
        // the same address.
        if (block.is_large && ptr < used_end) {
            Header* hdr = reinterpret_cast<Header*>(ptr);
            if (hdr->color == static_cast<u32>(Color::Black)) {
                hdr->color = static_cast<u32>(Color::White);
                buffer_meta_[buf_idx].live_bytes = block.totalBytes();
            } else {
                buffer_meta_[buf_idx].garbage_bytes = block.totalBytes();
                markBlockAsFreeLarge(buf_idx);
            }
            continue;
        }

        // Coalescing run: accumulate adjacent non-Black bytes into a single
        // Tag_Free span, flushing whenever we hit a Black object or block end.
        char* run_start = nullptr;
        size_t run_bytes = 0;

        while (ptr < used_end) {
            Header* hdr = reinterpret_cast<Header*>(ptr);
            size_t step = walkStep(block, getObjectSize(ptr));

            if (hdr->color == static_cast<u32>(Color::Black)) {
                // Flush any pending garbage span.
                if (run_start != nullptr) {
                    pushCoalescedFreeCell(free_lists_, run_start, run_bytes, &block);
                    buffer_meta_[buf_idx].garbage_bytes += run_bytes;
                    run_start = nullptr;
                    run_bytes = 0;
                }

                hdr->color = static_cast<u32>(Color::White);
                buffer_meta_[buf_idx].live_bytes += step;
            } else {
                // Garbage or pre-existing Tag_Free; merge into current run.
                if (run_start == nullptr) {
                    run_start = ptr;
                    run_bytes = 0;
                }
                run_bytes += step;
            }

            ptr += step;
        }

        if (run_start != nullptr) {
            pushCoalescedFreeCell(free_lists_, run_start, run_bytes, &block);
            buffer_meta_[buf_idx].garbage_bytes += run_bytes;
        }
    }

    computeFragmentationStats();

    // Diagnostic (gated on ECO_OLDGEN_DEBUG): validate every free-list cell
    // is in-heap. Detects sweep-time corruption before shrink walks the lists.
    static const bool kSweepDebug = std::getenv("ECO_OLDGEN_DEBUG") != nullptr;
    if (kSweepDebug && allocator_ != nullptr) {
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
                curr = curr->next;
                if (++depth > 100000000ULL) break;
            }
        }
    }

    adjustCapacityAfterMajorGC();
}

/**
 * Transition from marking phase to sweeping phase.
 * Prepares for lazy sweeping by initializing sweep state.
 */
void OldGenSpace::transitionToSweeping() {
    gc_phase_ = GCPhase::Sweeping;
    sweep_buffer_index_ = 0;
    sweep_cursor_ = nullptr;

    // Clear free lists - they'll be rebuilt during lazy sweep.
    for (size_t i = 0; i < NUM_SIZE_CLASSES; i++) {
        free_lists_[i] = nullptr;
    }

    while (buffer_meta_.size() < blocks_.size()) {
        buffer_meta_.push_back({buffer_meta_.size(), 0, 0, false});
    }

    for (auto& meta : buffer_meta_) {
        meta.live_bytes = 0;
        meta.garbage_bytes = 0;
        meta.fully_swept = false;
    }
}

/**
 * Lazy sweep - sweep a bounded amount of heap to find free space.
 * Coalesces adjacent garbage spans into Tag_Free cells, just like sweep().
 */
void OldGenSpace::lazySweep(size_t target_class, size_t work_budget) {
    size_t work_done = 0;

    // Per-block coalescing run state, carried across iterations only within
    // a single block.
    char* run_start = nullptr;
    size_t run_bytes = 0;

    auto flushRun = [&](size_t buf_idx) {
        if (run_start == nullptr) return;
        const BlockInfo* block_for_run =
            (buf_idx < blocks_.size()) ? &blocks_[buf_idx] : nullptr;
        pushCoalescedFreeCell(free_lists_, run_start, run_bytes, block_for_run);
        if (buf_idx < buffer_meta_.size()) {
            buffer_meta_[buf_idx].garbage_bytes += run_bytes;
        }
        run_start = nullptr;
        run_bytes = 0;
    };

    while (work_done < work_budget && gc_phase_ == GCPhase::Sweeping) {
        if (sweep_cursor_ == nullptr) {
            if (sweep_buffer_index_ >= blocks_.size()) {
                gc_phase_ = GCPhase::Idle;
                onSweepComplete();
                return;
            }
            sweep_cursor_ = blocks_[sweep_buffer_index_].start;
        }

        BlockInfo& block = blocks_[sweep_buffer_index_];
        char* used_end = block.end_of_objects;

        // Large/pinned blocks hold a single object. Decide live vs. dead in
        // one shot rather than running the coalescing walk: a dead large
        // block becomes a `free_large_blocks_` entry so the next
        // allocateLargeBlock reuses its address.
        if (block.is_large && sweep_cursor_ == block.start &&
            sweep_cursor_ < used_end) {
            Header* hdr = reinterpret_cast<Header*>(sweep_cursor_);
            if (sweep_buffer_index_ < buffer_meta_.size()) {
                BufferMetadata& meta = buffer_meta_[sweep_buffer_index_];
                if (hdr->color == static_cast<u32>(Color::Black)) {
                    hdr->color = static_cast<u32>(Color::White);
                    meta.live_bytes = block.totalBytes();
                } else {
                    meta.garbage_bytes = block.totalBytes();
                    markBlockAsFreeLarge(sweep_buffer_index_);
                }
                meta.fully_swept = true;
            }
            work_done += static_cast<size_t>(used_end - sweep_cursor_);
            sweep_cursor_ = used_end;
            // Fall through to the block-boundary handling below.
        }

        while (sweep_cursor_ < used_end && work_done < work_budget) {
            Header* hdr = reinterpret_cast<Header*>(sweep_cursor_);
            size_t step = walkStep(block, getObjectSize(sweep_cursor_));

            if (sweep_buffer_index_ < buffer_meta_.size()) {
                BufferMetadata& meta = buffer_meta_[sweep_buffer_index_];

                if (hdr->color == static_cast<u32>(Color::Black)) {
                    // Flush pending garbage run before processing live object.
                    flushRun(sweep_buffer_index_);
                    hdr->color = static_cast<u32>(Color::White);
                    meta.live_bytes += step;
                } else {
                    if (run_start == nullptr) {
                        run_start = sweep_cursor_;
                        run_bytes = 0;
                    }
                    run_bytes += step;
                }
            }

            sweep_cursor_ += step;
            work_done += step;
        }

        if (sweep_cursor_ >= used_end) {
            // Block boundary -- flush any trailing garbage run.
            flushRun(sweep_buffer_index_);
            if (sweep_buffer_index_ < buffer_meta_.size()) {
                buffer_meta_[sweep_buffer_index_].fully_swept = true;
            }
            sweep_buffer_index_++;
            sweep_cursor_ = nullptr;
        }

        // Early exit if we've found space in the target class.
        if (target_class < NUM_SIZE_CLASSES &&
            free_lists_[target_class] != nullptr) {
            // Flush any in-progress run so we don't leave it dangling across
            // an early return.
            flushRun(sweep_buffer_index_);
            return;
        }
    }

    // Flush any in-progress run before returning (we may resume mid-block on
    // the next call).
    flushRun(sweep_buffer_index_);

    if (sweep_buffer_index_ >= blocks_.size()) {
        gc_phase_ = GCPhase::Idle;
        onSweepComplete();
    }
}

/**
 * Called when lazy sweeping completes.
 * Computes fragmentation statistics and may trigger compaction.
 */
void OldGenSpace::onSweepComplete() {
    computeFragmentationStats();
    adjustCapacityAfterMajorGC();
}

bool OldGenSpace::shouldTriggerMajorGC() const {
    const float threshold = config_->major_gc_initiating_occupancy;

    // Per-thread trigger: allocated bytes are crowding the local committed span.
    const size_t committed = getCommittedBytes();
    if (committed != 0 &&
        static_cast<double>(allocated_bytes) / committed >= threshold) {
        return true;
    }

    // Global pressure trigger: total old-gen committed grew well past the
    // post-last-GC working set. Without this, a workload that grows the
    // committed counter faster than `allocated_bytes` (e.g.
    // `allocateFromBagPage` burning a fresh page per request even when the
    // requested chunk is much smaller than the page) can run the address
    // space all the way to the cap before the per-thread ratio crosses the
    // threshold.
    //
    // We use 1/3 of `initiating_occupancy` (≈0.25 with the default 0.75)
    // as the global cap threshold. A major GC fires at ~25% of the cap so
    // the per-thread shrink path can release the freshly-emptied pages
    // before the cap is approached, and the mutator never gets close to
    // OOM. Empirically: triggering later (e.g. at 0.75 of cap) means each
    // GC cycle has to sweep many more blocks at once, which is slower
    // overall than several smaller cycles.
    if (allocator_ != nullptr) {
        const size_t global_committed = allocator_->getOldGenCommittedBytes();
        const size_t cap = allocator_->getOldGenMaxBytes();
        const double global_pressure_threshold =
            static_cast<double>(threshold) / 3.0;
        if (cap > 0 &&
            static_cast<double>(global_committed) / cap >=
                global_pressure_threshold) {
            return true;
        }
    }
    return false;
}

void OldGenSpace::adjustCapacityAfterMajorGC() {
    if (region_base_ == nullptr || region_end_ <= region_base_) return;

    const size_t capacity = static_cast<size_t>(region_end_ - region_base_);
    const size_t live     = frag_stats_.live_bytes;
    if (capacity == 0) return;

    const double occupancy = capacity > 0
        ? static_cast<double>(live) / capacity
        : 0.0;
    const float grow_threshold = config_->major_gc_initiating_occupancy;
    const float target         = config_->major_gc_target_utilization;

    // Shrink branch: heap is well under the target band — release fully-free
    // pages back to the global allocator. `maybeShrinkCapacity` applies its
    // own hysteresis and floor checks, and is a no-op when conditions are
    // not met.
    if (live == 0 || occupancy <= target) {
        maybeShrinkCapacity();
        return;
    }

    if (occupancy < grow_threshold) return;

    size_t desired = static_cast<size_t>(
        std::ceil(static_cast<double>(live) / static_cast<double>(target)));

    const size_t global_cap = allocator_->getOldGenMaxBytes();
    if (desired > global_cap) desired = global_cap;
    if (desired <= capacity)  return;

    allocator_->ensureOldGenCapacityFor(*this, desired);
}

// Shrink path: returns fully-free pages back to the Allocator so
// `old_gen_committed` can drop after a major GC reclaims most live data.
//
// Locking: this function MUST NOT be called while holding
// `Allocator::thread_mutex_`. Each `releaseOldGenBlock` /
// `releaseUnassignedBlockToAllocator` call acquires the mutex transiently
// inside the Allocator. The shrink path runs at the end of major GC, with
// the mutator stopped — so `removeFreeCellsForBlock` and the swap-remove
// from `blocks_` cannot race against `allocateFromEmptyRegularBlocks`.
void OldGenSpace::maybeShrinkCapacity() {
    if (compact_phase_ != CompactionPhase::Idle) return;
    if (gc_phase_      != GCPhase::Idle)         return;
    if (allocator_     == nullptr)               return;

    const size_t live = frag_stats_.live_bytes;
    const float target = config_->major_gc_target_utilization;

    // Floor: never drop below max(initial_old_gen_size, alloc_buffer_size).
    // The first ensures we honor the user's configured starting capacity;
    // the second ensures at least one page is retained for new allocations.
    const size_t min_heap = std::max(config_->initial_old_gen_size,
                                     config_->alloc_buffer_size);

    // Desired heap derived from target utilization, clamped below by min_heap.
    size_t desired_heap;
    if (target > 0.0f && live > 0) {
        desired_heap = static_cast<size_t>(
            std::ceil(static_cast<double>(live) / static_cast<double>(target)));
    } else {
        desired_heap = min_heap;
    }
    if (desired_heap < min_heap) desired_heap = min_heap;

    // Current heap = sum of materialized block bytes + bag-page bytes.
    auto computeCurrentHeap = [&]() -> size_t {
        size_t total = 0;
        for (const auto& b : blocks_) total += b.totalBytes();
        for (const auto& e : unassigned_blocks_) {
            total += static_cast<size_t>(e.second - e.first);
        }
        return total;
    };

    size_t current_heap = computeCurrentHeap();

    // Hysteresis gate: only proceed if utilization is well below target AND
    // the heap is meaningfully larger than the desired size. Both must hold;
    // otherwise we'd churn at the boundary on every GC.
    //
    // EXCEPTION: when the global old-gen committed is approaching the cap,
    // we MUST shrink even inside the hysteresis band. Otherwise the global
    // pressure trigger in `shouldTriggerMajorGC` re-fires the GC every
    // safepoint without ever freeing committed bytes, looping until we hit
    // the cap for real.
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
        const double global_pressure_threshold =
            static_cast<double>(config_->major_gc_initiating_occupancy) / 3.0;
        if (cap > 0 &&
            static_cast<double>(global_committed) / cap >=
                global_pressure_threshold) {
            global_pressure = true;
        }
    }

    if (!global_pressure && (!below_band || !well_above_desired)) return;

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
        if (i >= buffer_meta_.size()) continue;
        const BufferMetadata& meta = buffer_meta_[i];
        if (!meta.fully_swept || meta.live_bytes != 0) continue;
        if (blocks_[i].is_large) continue;
        const size_t bytes = blocks_[i].totalBytes();
        if (!canRelease(bytes)) continue;
        to_release.push_back(i);
        current_heap -= bytes;
    }

    // Pass 2: fully-free large blocks.
    for (size_t i = blocks_.size(); i > 0;) {
        --i;
        if (current_heap <= desired_heap) break;
        if (i >= buffer_meta_.size()) continue;
        const BufferMetadata& meta = buffer_meta_[i];
        if (!meta.fully_swept || meta.live_bytes != 0) continue;
        if (!blocks_[i].is_large) continue;
        const size_t bytes = blocks_[i].totalBytes();
        if (!canRelease(bytes)) continue;
        to_release.push_back(i);
        current_heap -= bytes;
    }

    if (!to_release.empty()) {
        // O(N+M) batch unlink: walk every per-class free list ONCE, dropping
        // any cell whose address falls in ANY block we're about to release.
        // Avoids the O(N*M) cost of calling `removeFreeCellsForBlock` per
        // released block, which is the dominant cost when blocks_ contains
        // tens of thousands of pages with millions of free cells (the
        // Stage 7 workload).
        std::sort(to_release.begin(), to_release.end());
        std::vector<std::pair<char*, char*>> ranges;
        ranges.reserve(to_release.size());
        for (size_t idx : to_release) {
            ranges.emplace_back(blocks_[idx].start, blocks_[idx].end);
        }
        std::sort(ranges.begin(), ranges.end());
        auto inAnyRange = [&](char* p) -> bool {
            // Binary search for the range whose start <= p, then check end.
            auto it = std::upper_bound(
                ranges.begin(), ranges.end(),
                std::make_pair(p, static_cast<char*>(nullptr)));
            if (it == ranges.begin()) return false;
            --it;
            return p < it->second;
        };
        for (size_t cls = 0; cls < NUM_SIZE_CLASSES; ++cls) {
            FreeCell** prev = &free_lists_[cls];
            FreeCell* curr = free_lists_[cls];
            while (curr != nullptr) {
                FreeCell* next = curr->next;
                if (inAnyRange(reinterpret_cast<char*>(curr))) {
                    *prev = next;  // unlink
                } else {
                    prev = &curr->next;
                }
                curr = next;
            }
        }
        // Now release each block. The per-block `removeFreeCellsForBlock`
        // call inside `releaseBlockToAllocator` becomes a no-op since we
        // already cleared the lists above — kept for safety against a
        // future caller that doesn't pre-clean.
        // Walk back-to-front (highest indices first) so the swap-remove in
        // releaseBlockToAllocator never moves an index we're still planning
        // to release. (We sorted ascending above; iterate reversed.)
        // Bracket the loop with the batch flag so each release skips its
        // O(N) bounds recomputation; we recompute once after.
        ++g_batch_release_depth;
        for (auto it = to_release.rbegin(); it != to_release.rend(); ++it) {
            releaseBlockToAllocator(*it);
        }
        --g_batch_release_depth;

        // One-shot recompute of region_base_ / region_end_ over the new state.
        char* new_base = nullptr;
        char* new_end = nullptr;
        for (const auto& b : blocks_) {
            if (new_base == nullptr || b.start < new_base) new_base = b.start;
            if (b.end > new_end) new_end = b.end;
        }
        for (const auto& e : unassigned_blocks_) {
            if (new_base == nullptr || e.first < new_base) new_base = e.first;
            if (e.second > new_end) new_end = e.second;
        }
        region_base_ = new_base;
        region_end_  = new_end;
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
}

void OldGenSpace::removeFreeCellsForBlock(size_t block_index) {
    if (block_index >= blocks_.size()) return;
    char* lo = blocks_[block_index].start;
    char* hi = blocks_[block_index].end;

    for (size_t cls = 0; cls < NUM_SIZE_CLASSES; ++cls) {
        FreeCell** prev = &free_lists_[cls];
        FreeCell* curr = free_lists_[cls];
        while (curr != nullptr) {
            char* p = reinterpret_cast<char*>(curr);
            FreeCell* next = curr->next;
            if (p >= lo && p < hi) {
                *prev = next;  // unlink
            } else {
                prev = &curr->next;
            }
            curr = next;
        }
    }
}

void OldGenSpace::fixupIndicesAfterBlockMove(size_t old_idx, size_t new_idx) {
    if (old_idx == new_idx) return;

    // BufferMetadata::block_index is denormalized; rewrite if it pointed at
    // the moved entry. (Note: callers also swap-remove buffer_meta_, so this
    // mostly normalizes the back-reference.)
    for (auto& m : buffer_meta_) {
        if (m.block_index == old_idx) m.block_index = new_idx;
    }

    for (size_t& idx : evacuation_set_) {
        if (idx == old_idx) idx = new_idx;
    }
    for (size_t& idx : free_large_blocks_) {
        if (idx == old_idx) idx = new_idx;
    }

    if (evac_block_index_ == old_idx)  evac_block_index_  = new_idx;
    if (sweep_buffer_index_ == old_idx) sweep_buffer_index_ = new_idx;
    if (fixup_buffer_index_ == old_idx) fixup_buffer_index_ = new_idx;
}

void OldGenSpace::releaseBlockToAllocator(size_t block_index) {
    if (block_index >= blocks_.size()) return;

    BlockInfo blk = blocks_[block_index];
    const size_t total = blk.totalBytes();

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

    // Swap-remove from blocks_ and buffer_meta_.
    const size_t last = blocks_.size() - 1;
    if (block_index != last) {
        blocks_[block_index] = blocks_[last];
    }
    blocks_.pop_back();

    if (block_index < buffer_meta_.size()) {
        const size_t meta_last = buffer_meta_.size() - 1;
        if (block_index != meta_last) {
            buffer_meta_[block_index] = buffer_meta_[meta_last];
        }
        buffer_meta_.pop_back();
    }

    // Patch any state that referred to the moved-from slot.
    if (block_index != last) {
        fixupIndicesAfterBlockMove(last, block_index);
    }

    // Recompute region_base_ / region_end_ if either was anchored to the
    // released extent. A linear scan is fine for one-off releases — but in
    // batch mode (shrink path) we let the caller recompute once at the end
    // to avoid an O(N²) per-release cost.
    if (g_batch_release_depth == 0 &&
        (blk.start == region_base_ || blk.end == region_end_)) {
        char* new_base = nullptr;
        char* new_end = nullptr;
        for (const auto& b : blocks_) {
            if (new_base == nullptr || b.start < new_base) new_base = b.start;
            if (b.end > new_end) new_end = b.end;
        }
        for (const auto& e : unassigned_blocks_) {
            if (new_base == nullptr || e.first < new_base) new_base = e.first;
            if (e.second > new_end) new_end = e.second;
        }
        region_base_ = new_base;
        region_end_  = new_end;
    }
}

void OldGenSpace::releaseUnassignedBlockToAllocator(size_t unassigned_index) {
    if (unassigned_index >= unassigned_blocks_.size()) return;

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

    // Recompute bounds if anchored to the released extent.
    if (start == region_base_ || end == region_end_) {
        char* new_base = nullptr;
        char* new_end = nullptr;
        for (const auto& b : blocks_) {
            if (new_base == nullptr || b.start < new_base) new_base = b.start;
            if (b.end > new_end) new_end = b.end;
        }
        for (const auto& e : unassigned_blocks_) {
            if (new_base == nullptr || e.first < new_base) new_base = e.first;
            if (e.second > new_end) new_end = e.second;
        }
        region_base_ = new_base;
        region_end_  = new_end;
    }
}

/**
 * Computes heap-wide fragmentation statistics from per-block metadata.
 */
void OldGenSpace::computeFragmentationStats() {
    frag_stats_.live_bytes = 0;
    frag_stats_.total_free_bytes = 0;
    frag_stats_.heap_bytes = 0;

    for (size_t i = 0; i < buffer_meta_.size() && i < blocks_.size(); i++) {
        const auto& meta = buffer_meta_[i];
        frag_stats_.live_bytes += meta.live_bytes;
        frag_stats_.total_free_bytes += meta.garbage_bytes;
        // heap_bytes counts the parseable region of each block.
        frag_stats_.heap_bytes += static_cast<size_t>(
            blocks_[i].end_of_objects - blocks_[i].start);
    }

    // allocated_bytes reflects actual live bytes after sweep.
    allocated_bytes = frag_stats_.live_bytes;
}

/**
 * Returns true if compaction should be triggered.
 * Based on heap utilization falling below threshold.
 */
bool OldGenSpace::shouldCompact() const {
    return frag_stats_.utilization() < UTILIZATION_THRESHOLD;
}

// ============================================================================
// Incremental Compaction Implementation
// ============================================================================

void OldGenSpace::scheduleCompaction() {
    if (compact_phase_ != CompactionPhase::Idle) return;

    evacuation_set_ = selectEvacuationSet(COMPACTION_WORK_BUDGET * 10);
    if (evacuation_set_.empty()) return;

    compact_phase_ = CompactionPhase::Evacuating;
    current_evac_index_ = 0;
    evac_cursor_ = nullptr;
    evac_block_index_ = NO_BLOCK;
    evac_alloc_ptr_ = nullptr;
}

std::vector<size_t> OldGenSpace::selectEvacuationSet(size_t max_live_to_move) {
    struct Candidate {
        size_t index;
        size_t garbage_bytes;
        size_t live_bytes;
    };
    std::vector<Candidate> candidates;

    for (size_t i = 0; i < buffer_meta_.size() && i < blocks_.size(); i++) {
        const auto& meta = buffer_meta_[i];

        if (!meta.fully_swept) continue;

        // Skip the block we're currently bump-allocating into for evacuation.
        if (i == evac_block_index_) continue;

        // Skip large/pinned blocks (sweep marks pinned via the object header,
        // but we identify the block via the is_large flag for clarity).
        if (blocks_[i].is_large) continue;
        if (blocks_[i].end_of_objects > blocks_[i].start) {
            const Header* first_hdr =
                reinterpret_cast<const Header*>(blocks_[i].start);
            if (first_hdr->pin) continue;
        }

        size_t total = static_cast<size_t>(
            blocks_[i].end_of_objects - blocks_[i].start);
        float liveness = total > 0 ? static_cast<float>(meta.live_bytes) / total : 0.0f;

        if (liveness < 0.70f && meta.garbage_bytes > 0) {
            candidates.push_back({i, meta.garbage_bytes, meta.live_bytes});
        }
    }

    std::sort(candidates.begin(), candidates.end(),
        [](const Candidate& a, const Candidate& b) {
            return a.garbage_bytes > b.garbage_bytes;
        });

    std::vector<size_t> evacuation_set;
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

        size_t src_idx = evacuation_set_[current_evac_index_];
        BlockInfo& src_block = blocks_[src_idx];

        if (evac_cursor_ == nullptr) {
            evac_cursor_ = src_block.start;
        }

        char* end = src_block.end_of_objects;

        while (evac_cursor_ < end && work_done < work_budget) {
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

    auto bumpInBlock = [&](size_t idx) -> void* {
        BlockInfo& blk = blocks_[idx];
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

    if (evac_block_index_ != NO_BLOCK && !isInEvacuationSet(evac_block_index_)) {
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
    blocks_.push_back(bi);
    evac_block_index_ = blocks_.size() - 1;
    buffer_meta_.push_back({evac_block_index_, 0, 0, true});
    evac_alloc_ptr_ = bi.start;

    return bumpInBlock(evac_block_index_);
}

void OldGenSpace::installForwardingPointer(void* old_location, void* new_location) {
    Forward* fwd = reinterpret_cast<Forward*>(old_location);
    fwd->header.tag = Tag_Forward;

    char* new_ptr = static_cast<char*>(new_location);
    u64 offset = (new_ptr - g_heap_base) >> 3;
    fwd->header.forward_ptr = offset;
}

void* OldGenSpace::getForwardingAddress(void* obj) const {
    Header* hdr = reinterpret_cast<Header*>(obj);
    if (hdr->tag == Tag_Forward) {
        Forward* fwd = reinterpret_cast<Forward*>(obj);
        return g_heap_base + (fwd->header.forward_ptr << 3);
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

        if (isInEvacuationSet(fixup_buffer_index_)) {
            fixup_buffer_index_++;
            fixup_cursor_ = nullptr;
            continue;
        }

        BlockInfo& block = blocks_[fixup_buffer_index_];

        if (fixup_cursor_ == nullptr) {
            fixup_cursor_ = block.start;
        }

        char* end = block.end_of_objects;

        while (fixup_cursor_ < end && work_done < work_budget) {
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
        evac_block_index_ = NO_BLOCK;
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
            // Iterate hdr->size to match the nursery scan and the marking
            // pass above; see comment there for the rationale.
            Closure* cl = static_cast<Closure*>(obj);
            for (u32 i = 0; i < hdr->size; i++) {
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
            fixHPointer(t->value);
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
        default:
            // Tag_Int, Tag_Float, Tag_Char, Tag_String, Tag_FieldGroup,
            // Tag_ByteBuffer, Tag_Free, Tag_Forward: nothing to fix.
            break;
    }
}

void OldGenSpace::fixHPointer(HPointer& ptr) {
    if (ptr.constant != 0) return;

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

bool OldGenSpace::isInEvacuationSet(size_t buffer_index) const {
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
    for (size_t idx : evacuation_set_) {
        if (idx < blocks_.size()) {
            evacuated_extents.emplace_back(blocks_[idx].start, blocks_[idx].end);
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
            FreeCell* next = head->next;
            if (!inEvacuated(reinterpret_cast<char*>(head))) {
                *tail_link = head;
                tail_link = &head->next;
            }
            head = next;
        }
        *tail_link = nullptr;
        free_lists_[cls] = new_head;
    }

    // Push evacuated extents into the bag for reuse.
    for (const auto& e : evacuated_extents) {
        unassigned_blocks_.emplace_back(e.first, e.second);
    }

    // Sort evacuation set descending and erase from blocks_/buffer_meta_.
    std::vector<size_t> sorted_set = evacuation_set_;
    std::sort(sorted_set.begin(), sorted_set.end(), std::greater<size_t>());

    for (size_t idx : sorted_set) {
        if (idx < blocks_.size()) {
            blocks_.erase(blocks_.begin() + idx);
        }
        if (idx < buffer_meta_.size()) {
            buffer_meta_.erase(buffer_meta_.begin() + idx);
        }

        // Compaction's bump cursor lives in evac_block_index_; if that block
        // was just removed or shifted, fix the index.
        if (evac_block_index_ != NO_BLOCK) {
            if (evac_block_index_ == idx) {
                evac_block_index_ = NO_BLOCK;
                evac_alloc_ptr_ = nullptr;
            } else if (evac_block_index_ > idx) {
                evac_block_index_--;
            }
        }
    }

    evacuation_set_.clear();

    computeFragmentationStats();
}

} // namespace Elm
