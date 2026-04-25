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
#include <limits>
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstring>
#include <functional>

namespace Elm {

// Global heap base (defined in Allocator.cpp).
extern char* g_heap_base;

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
// Size-class fast path.
// ---------------------------------------------------------------------------
void* OldGenSpace::allocateFromSizeClass(size_t cls, size_t requested_size) {
    assert(cls < num_size_classes_ && "size class out of range");

    // 1) Pop from this class's free list if non-empty.
    if (free_lists_[cls] != nullptr) {
        FreeCell* cell = free_lists_[cls];
        free_lists_[cls] = cell->next;
        void* result = static_cast<void*>(cell);
        initObjectHeader(result);
        return result;
    }

    // 2) Try splitting a larger free cell.
    if (void* result = tryAllocateBySplittingLarger(cls, classToSize(cls))) {
        return result;
    }

    // 3) Pull a page from the bag and slice it into uniform cells.
    if (populateFromBlock(cls)) {
        FreeCell* cell = free_lists_[cls];
        if (cell != nullptr) {
            free_lists_[cls] = cell->next;
            void* result = static_cast<void*>(cell);
            initObjectHeader(result);
            return result;
        }
    }

    // 4) Last resort: split from a freshly-pulled page treated as one big
    //    cell. populateFromBlock failed (bag empty); allocateFromBagPage will
    //    also fail in that case but allows the caller to observe nullptr.
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
    // allocation or a usable Tag_Free remainder. We accept either a
    // perfect-fit (no remainder) or a remainder >= MIN_FREE_CELL_SIZE.
    for (size_t cls = target_cls + 1; cls < NUM_SIZE_CLASSES; ++cls) {
        if (free_lists_[cls] == nullptr) continue;

        FreeCell** prev = &free_lists_[cls];
        FreeCell* curr = free_lists_[cls];
        while (curr != nullptr) {
            const size_t cell_bytes = curr->header.size;
            const size_t remainder = (cell_bytes >= alloc_size)
                                         ? cell_bytes - alloc_size
                                         : 0;

            // Accept either an exact fit or one that leaves a usable cell.
            if (cell_bytes >= alloc_size &&
                (remainder == 0 || remainder >= MIN_FREE_CELL_SIZE)) {
                // Unlink curr from this list.
                *prev = curr->next;

                char* base = reinterpret_cast<char*>(curr);
                if (remainder > 0) {
                    // Carve the front for the allocation; push the back as a
                    // new Tag_Free cell on the appropriate class.
                    FreeCell* tail = reinterpret_cast<FreeCell*>(base + alloc_size);
                    std::memset(&tail->header, 0, sizeof(Header));
                    tail->header.tag = Tag_Free;
                    tail->header.size = static_cast<u32>(remainder);
                    tail->header.color = static_cast<u32>(Color::White);

                    size_t tail_cls = sizeClass(remainder);
                    if (tail_cls >= NUM_SIZE_CLASSES) {
                        // Remainder doesn't fit any class (rare: larger than
                        // any medium class). Park it on the largest medium
                        // class; future splits can carve it further.
                        tail_cls = NUM_SIZE_CLASSES - 1;
                    }
                    tail->next = free_lists_[tail_cls];
                    free_lists_[tail_cls] = tail;
                }

                void* result = static_cast<void*>(base);
                initObjectHeader(result);
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

    // Carve the request off the front. The remainder, if any, becomes a
    // Tag_Free cell pushed onto the appropriate free list.
    const size_t remainder = page_size - requested_size;
    if (remainder >= MIN_FREE_CELL_SIZE) {
        FreeCell* tail = reinterpret_cast<FreeCell*>(page_start + requested_size);
        std::memset(&tail->header, 0, sizeof(Header));
        tail->header.tag = Tag_Free;
        tail->header.size = static_cast<u32>(remainder);
        tail->header.color = static_cast<u32>(Color::White);

        size_t tail_cls = sizeClass(remainder);
        if (tail_cls >= NUM_SIZE_CLASSES) {
            tail_cls = NUM_SIZE_CLASSES - 1;
        }
        tail->next = free_lists_[tail_cls];
        free_lists_[tail_cls] = tail;
    }

    void* result = static_cast<void*>(page_start);
    initObjectHeader(result);
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
void* OldGenSpace::allocateLargeBlock(size_t size) {
    assert(allocator_ && "OldGenSpace not initialized with Allocator");
    assert(size >= config_->alloc_buffer_size && "allocateLargeBlock used for small size");

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
#else
void OldGenSpace::finishMarkAndSweep() {
    while (incrementalMark(1000)) {
        // Keep marking.
    }

    sweep();

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
inline void pushCoalescedFreeCell(FreeCell** free_lists, char* span_start,
                                  size_t span_bytes) {
    if (span_bytes < MIN_FREE_CELL_SIZE) return;  // Cannot link a tiny span.

    FreeCell* cell = reinterpret_cast<FreeCell*>(span_start);
    std::memset(&cell->header, 0, sizeof(Header));
    cell->header.tag = Tag_Free;
    cell->header.size = static_cast<u32>(span_bytes);
    cell->header.color = static_cast<u32>(Color::White);

    size_t cls = OldGenSpaceTestAccess::sizeClass(span_bytes);
    if (cls >= NUM_SIZE_CLASSES) {
        cls = NUM_SIZE_CLASSES - 1;  // Park oversize spans on the largest class.
    }
    cell->next = free_lists[cls];
    free_lists[cls] = cell;
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

        // Coalescing run: accumulate adjacent non-Black bytes into a single
        // Tag_Free span, flushing whenever we hit a Black object or block end.
        char* run_start = nullptr;
        size_t run_bytes = 0;

        while (ptr < used_end) {
            Header* hdr = reinterpret_cast<Header*>(ptr);
            size_t obj_size = getObjectSize(ptr);

            if (hdr->color == static_cast<u32>(Color::Black)) {
                // Flush any pending garbage span.
                if (run_start != nullptr) {
                    pushCoalescedFreeCell(free_lists_, run_start, run_bytes);
                    buffer_meta_[buf_idx].garbage_bytes += run_bytes;
                    run_start = nullptr;
                    run_bytes = 0;
                }

                hdr->color = static_cast<u32>(Color::White);
                buffer_meta_[buf_idx].live_bytes += obj_size;
            } else {
                // Garbage or pre-existing Tag_Free; merge into current run.
                if (run_start == nullptr) {
                    run_start = ptr;
                    run_bytes = 0;
                }
                run_bytes += obj_size;
            }

            ptr += obj_size;
        }

        if (run_start != nullptr) {
            pushCoalescedFreeCell(free_lists_, run_start, run_bytes);
            buffer_meta_[buf_idx].garbage_bytes += run_bytes;
        }
    }

    computeFragmentationStats();
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
        pushCoalescedFreeCell(free_lists_, run_start, run_bytes);
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

        while (sweep_cursor_ < used_end && work_done < work_budget) {
            Header* hdr = reinterpret_cast<Header*>(sweep_cursor_);
            size_t obj_size = getObjectSize(sweep_cursor_);

            if (sweep_buffer_index_ < buffer_meta_.size()) {
                BufferMetadata& meta = buffer_meta_[sweep_buffer_index_];

                if (hdr->color == static_cast<u32>(Color::Black)) {
                    // Flush pending garbage run before processing live object.
                    flushRun(sweep_buffer_index_);
                    hdr->color = static_cast<u32>(Color::White);
                    meta.live_bytes += obj_size;
                } else {
                    if (run_start == nullptr) {
                        run_start = sweep_cursor_;
                        run_bytes = 0;
                    }
                    run_bytes += obj_size;
                }
            }

            sweep_cursor_ += obj_size;
            work_done += obj_size;
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
    const size_t committed = getCommittedBytes();
    if (committed == 0) return false;
    return static_cast<double>(allocated_bytes) / committed
           >= config_->major_gc_initiating_occupancy;
}

void OldGenSpace::adjustCapacityAfterMajorGC() {
    if (region_base_ == nullptr || region_end_ <= region_base_) return;

    const size_t capacity = static_cast<size_t>(region_end_ - region_base_);
    const size_t live     = frag_stats_.live_bytes;
    if (live == 0 || capacity == 0) return;

    const double occupancy = static_cast<double>(live) / capacity;
    const float grow_threshold = config_->major_gc_initiating_occupancy;
    const float target         = config_->major_gc_target_utilization;

    if (occupancy <= target)         return;
    if (occupancy <  grow_threshold) return;

    size_t desired = static_cast<size_t>(
        std::ceil(static_cast<double>(live) / static_cast<double>(target)));

    const size_t global_cap = allocator_->getOldGenMaxBytes();
    if (desired > global_cap) desired = global_cap;
    if (desired <= capacity)  return;

    allocator_->ensureOldGenCapacityFor(*this, desired);
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

            // Free cells: nothing to evacuate; advance.
            if (hdr->tag == Tag_Free) {
                evac_cursor_ += obj_size;
                continue;
            }

            // Pinned objects must not be moved. Install a self-forwarding
            // pointer so the fixup phase resolves references through
            // getForwardingAddress without any other code changes.
            if (hdr->tag != Tag_Forward && hdr->pin) {
                installForwardingPointer(evac_cursor_, evac_cursor_);
                evac_cursor_ += obj_size;
                continue;
            }

            if (hdr->tag != Tag_Forward) {
                void* dest = allocateForEvacuation(obj_size);
                if (dest == nullptr) {
                    // Out of space - abort compaction.
                    compact_phase_ = CompactionPhase::Idle;
                    evacuation_set_.clear();
                    return work_done;
                }

                std::memcpy(dest, evac_cursor_, obj_size);
                installForwardingPointer(evac_cursor_, dest);

                work_done += obj_size;
            }

            evac_cursor_ += obj_size;
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
            size_t obj_size = getObjectSize(fixup_cursor_);

            // Skip free cells and forwarding pointers.
            if (hdr->tag != Tag_Forward && hdr->tag != Tag_Free) {
                fixPointersInObject(fixup_cursor_);
            }

            fixup_cursor_ += obj_size;
            work_done += obj_size;
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
