/**
 * OldGenSpace Implementation.
 *
 * Implements the old generation for long-lived objects using:
 *   - Block-based bump-pointer allocation.
 *   - Tri-color mark-and-sweep collection.
 *
 * Each block is a contiguous region of memory obtained from the
 * Allocator. Objects are allocated by bumping a pointer within the
 * current block. When a block is exhausted, a new one is acquired.
 *
 * Single-threaded version.
 */

#include "OldGenSpace.hpp"
#include "Allocator.hpp"
#include <limits>
#include <algorithm>
#include <cassert>
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
    current_block_index_(NO_BLOCK), allocated_bytes(0),
    region_base_(nullptr), region_end_(nullptr),
    gc_phase_(GCPhase::Idle),
    current_epoch(0), marking_active(false), allocator_ref_(nullptr),
    sweep_buffer_index_(0), sweep_cursor_(nullptr),
    frag_stats_{0, 0, 0},
    compact_phase_(CompactionPhase::Idle),
    current_evac_index_(0), evac_cursor_(nullptr),
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
    current_block_index_ = NO_BLOCK;
}

void OldGenSpace::initialize(Allocator* allocator, const HeapConfig* config) {
    config_ = config;
    allocator_ = allocator;
    current_block_index_ = NO_BLOCK;
    allocated_bytes = 0;
}

// contains() is now inline in the header.

void OldGenSpace::reset(const HeapConfig* new_config) {
    // Update config if provided.
    if (new_config) {
        config_ = new_config;
    }

    // Memory blocks are owned by Allocator's mmap region - just clear tracking.
    blocks_.clear();
    buffer_meta_.clear();
    current_block_index_ = NO_BLOCK;

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
    fixup_buffer_index_ = 0;
    fixup_cursor_ = nullptr;
}

/**
 * Allocates memory in the old generation.
 *
 * Allocation strategy:
 *   1. If marking, do incremental marking work proportional to allocation size.
 *   2. Try free list for small objects (size <= MAX_SMALL_SIZE).
 *   3. If sweeping, do lazy sweep work to find free space.
 *   4. Fall back to bump-pointer allocation in current buffer.
 *   5. Acquire new AllocBuffer if current is exhausted.
 */
void *OldGenSpace::allocate(size_t size) {
    size = (size + 7) & ~7;  // Align to 8 bytes.
    size_t cls = sizeClass(size);

    // Allocation-paced marking: do marking work proportional to allocation.
    // This spreads marking work across allocations to avoid long pauses.
    if (gc_phase_ == GCPhase::Marking && !mark_stack.empty()) {
        size_t mark_budget = size * MARK_WORK_RATIO;
#if ENABLE_GC_STATS
        // Note: stats not available here, use version without stats
        while (mark_budget > 0 && !mark_stack.empty()) {
            void *obj = mark_stack.back();
            mark_stack.pop_back();

            Header *hdr = getHeader(obj);
            if (hdr->color == static_cast<u32>(Color::Black)) {
                continue;
            }

            hdr->color = static_cast<u32>(Color::Grey);
            markChildren(obj);
            hdr->color = static_cast<u32>(Color::Black);
            hdr->epoch = current_epoch & 3;

            mark_budget = (mark_budget > 1) ? mark_budget - 1 : 0;
        }
#else
        incrementalMark(mark_budget);
#endif

        // Check if marking is complete.
        if (mark_stack.empty()) {
            transitionToSweeping();
        }
    }

    // Try free list first for small objects.
    if (cls < NUM_SIZE_CLASSES && free_lists_[cls] != nullptr) {
        // Pop from free list.
        FreeCell* cell = free_lists_[cls];
        free_lists_[cls] = cell->next;

        void* result = static_cast<void*>(cell);

        // Initialize header.
        Header* hdr = reinterpret_cast<Header*>(result);
        std::memset(hdr, 0, sizeof(Header));

        // During marking or sweeping, new objects must be Black to survive this cycle.
        if (marking_active || gc_phase_ != GCPhase::Idle) {
            hdr->color = static_cast<u32>(Color::Black);
            hdr->epoch = current_epoch & 3;
        } else {
            hdr->color = static_cast<u32>(Color::White);
        }

        // Note: allocated_bytes not incremented - space was already counted.
        return result;
    }

    // If sweeping, do lazy sweep work to find free space.
    if (gc_phase_ == GCPhase::Sweeping) {
        lazySweep(cls, SWEEP_WORK_BUDGET);

        // Try free list again after sweeping.
        if (cls < NUM_SIZE_CLASSES && free_lists_[cls] != nullptr) {
            FreeCell* cell = free_lists_[cls];
            free_lists_[cls] = cell->next;

            void* result = static_cast<void*>(cell);

            Header* hdr = reinterpret_cast<Header*>(result);
            std::memset(hdr, 0, sizeof(Header));
            hdr->color = static_cast<u32>(Color::Black);
            hdr->epoch = current_epoch & 3;

            return result;
        }
    }

    // Fall back to bump allocation.
    return bumpAllocate(size);
}

/**
 * Bump-pointer allocation from current or new block.
 */
void* OldGenSpace::bumpAllocate(size_t size) {
    // Try current block first.
    if (current_block_index_ != NO_BLOCK) {
        BlockInfo& block = blocks_[current_block_index_];
        void* result = block.allocate(size);
        if (result) {
            allocated_bytes += size;

            // Initialize header.
            Header* hdr = reinterpret_cast<Header*>(result);
            std::memset(hdr, 0, sizeof(Header));

            // During marking or sweeping, new objects must be Black to survive this cycle.
            if (marking_active || gc_phase_ == GCPhase::Sweeping) {
                hdr->color = static_cast<u32>(Color::Black);
                hdr->epoch = current_epoch & 3;
            } else {
                hdr->color = static_cast<u32>(Color::White);
            }

            return result;
        }
    }

    // Current block exhausted or doesn't exist - acquire new one.
    assert(allocator_ && "OldGenSpace not initialized with Allocator");
    assert(size <= config_->alloc_buffer_size && "Object too large for block");

    char* block_base = allocator_->acquireOldGenBlock(config_->alloc_buffer_size);
    assert(block_base && "Failed to acquire old gen block");

    // Create new block info.
    BlockInfo new_block;
    new_block.start = block_base;
    new_block.end = block_base + config_->alloc_buffer_size;
    new_block.alloc_ptr = block_base;

    blocks_.push_back(new_block);
    current_block_index_ = blocks_.size() - 1;

    // Add metadata for new block.
    buffer_meta_.push_back({current_block_index_, 0, 0, false});

    // Update cached bounds for O(1) contains() check.
    if (region_base_ == nullptr) {
        region_base_ = block_base;
    }
    region_end_ = new_block.end;

    void* result = blocks_[current_block_index_].allocate(size);
    assert(result && "Failed to allocate from fresh block");

    allocated_bytes += size;

    // Initialize header.
    Header* hdr = reinterpret_cast<Header*>(result);
    std::memset(hdr, 0, sizeof(Header));

    // During marking or sweeping, new objects must be Black to survive this cycle.
    if (marking_active || gc_phase_ == GCPhase::Sweeping) {
        hdr->color = static_cast<u32>(Color::Black);
        hdr->epoch = current_epoch & 3;
    } else {
        hdr->color = static_cast<u32>(Color::White);
    }

    return result;
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
    // Nursery objects will be marked (grey->black) like old gen objects.
    // This is harmless since minor GC uses forwarding pointers, not colors.
    for (HPointer *root: roots) {
        void *obj = Allocator::fromPointerRaw(*root);
        if (obj && alloc.isInHeap(obj)) {
            mark_stack.push_back(obj);
        }
    }

    // Push JIT roots (raw 64-bit heap pointers from JIT-compiled globals).
    // These are full heap addresses, not HPointer-encoded values.
    for (uint64_t *root: jit_roots) {
        uint64_t val = *root;

        // Check for embedded constants: lower 40 bits = 0, bits 40-43 = 1-7.
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
        hdr->epoch = current_epoch & 3;

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
            markUnboxable(t->a, !(hdr->unboxed & 1));
            markUnboxable(t->b, !(hdr->unboxed & 2));
            break;
        }
        case Tag_Tuple3: {
            Tuple3 *t = static_cast<Tuple3 *>(obj);
            markUnboxable(t->a, !(hdr->unboxed & 1));
            markUnboxable(t->b, !(hdr->unboxed & 2));
            markUnboxable(t->c, !(hdr->unboxed & 4));
            break;
        }
        case Tag_Cons: {
            Cons *c = static_cast<Cons *>(obj);
            markUnboxable(c->head, !(hdr->unboxed & 1));
            markHPointer(c->tail);
            break;
        }
        case Tag_Custom: {
            Custom *c = static_cast<Custom *>(obj);
            for (u32 i = 0; i < hdr->size && i < 48; i++) {
                markUnboxable(c->values[i], !(c->unboxed & (1ULL << i)));
            }
            break;
        }
        case Tag_Record: {
            Record *r = static_cast<Record *>(obj);
            for (u32 i = 0; i < hdr->size && i < 64; i++) {
                markUnboxable(r->values[i], !(r->unboxed & (1ULL << i)));
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
                markUnboxable(cl->values[i], !(cl->unboxed & (1ULL << i)));
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
            bool is_boxed = !arr->header.unboxed;
            for (u32 i = 0; i < arr->length; i++) {
                markUnboxable(arr->elements[i], is_boxed);
            }
            break;
        }
        // Tag_ByteBuffer: No pointers to mark (raw bytes only).
        // Tag_FieldGroup: No pointers to mark (field IDs only).
        // Tag_Int, Tag_Float, Tag_Char, Tag_String: No children.
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

    // Push both old gen and nursery objects onto mark stack.
    // Nursery objects will be marked grey->black like old gen objects.
    // This is harmless since minor GC uses forwarding pointers, not colors.
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
    // Complete any remaining marking.
    while (incrementalMark(1000, stats)) {
        // Keep marking.
    }

    sweep();

    marking_active = false;

    GC_STATS_MAJOR_INC_MARK_SWEEP(stats);
}
#else
void OldGenSpace::finishMarkAndSweep() {
    // Complete any remaining marking.
    while (incrementalMark(1000)) {
        // Keep marking.
    }

    sweep();

    marking_active = false;
}
#endif

/**
 * Sweep phase - reset colors of live objects and reclaim dead ones.
 *
 * Live objects (Black) have their color reset to White for the next cycle.
 * Dead objects (White) are added to the appropriate free list for reuse.
 */
void OldGenSpace::sweep() {
    // Clear all free lists before rebuilding them.
    for (size_t i = 0; i < NUM_SIZE_CLASSES; i++) {
        free_lists_[i] = nullptr;
    }

    // Ensure buffer metadata matches blocks.
    while (buffer_meta_.size() < blocks_.size()) {
        buffer_meta_.push_back({buffer_meta_.size(), 0, 0, false});
    }

    // Walk all blocks.
    for (size_t buf_idx = 0; buf_idx < blocks_.size(); buf_idx++) {
        BlockInfo& block = blocks_[buf_idx];
        char* ptr = block.start;
        char* used_end = block.alloc_ptr;

        // Reset metadata for this block.
        buffer_meta_[buf_idx].live_bytes = 0;
        buffer_meta_[buf_idx].garbage_bytes = 0;
        buffer_meta_[buf_idx].fully_swept = true;

        while (ptr < used_end) {
            Header* hdr = reinterpret_cast<Header*>(ptr);
            size_t obj_size = getObjectSize(ptr);

            if (hdr->color == static_cast<u32>(Color::Black)) {
                // Live object: reset color to white for next GC cycle.
                hdr->color = static_cast<u32>(Color::White);
                buffer_meta_[buf_idx].live_bytes += obj_size;
            } else {
                // Dead object: add to free list for reuse.
                buffer_meta_[buf_idx].garbage_bytes += obj_size;
                size_t cls = sizeClass(obj_size);
                if (cls < NUM_SIZE_CLASSES) {
                    FreeCell* cell = reinterpret_cast<FreeCell*>(ptr);
                    cell->next = free_lists_[cls];
                    free_lists_[cls] = cell;
                }
                // Large objects (cls >= NUM_SIZE_CLASSES) are left as holes.
            }

            ptr += obj_size;
        }
    }

    // Compute fragmentation stats from buffer metadata.
    computeFragmentationStats();
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

    // Ensure buffer metadata matches blocks.
    while (buffer_meta_.size() < blocks_.size()) {
        buffer_meta_.push_back({buffer_meta_.size(), 0, 0, false});
    }

    // Reset per-block stats for this sweep.
    for (auto& meta : buffer_meta_) {
        meta.live_bytes = 0;
        meta.garbage_bytes = 0;
        meta.fully_swept = false;
    }
}

/**
 * Lazy sweep - sweep a bounded amount of heap to find free space.
 * Called during allocation when free list is empty.
 *
 * @param target_class The size class we're trying to allocate.
 * @param work_budget Maximum bytes to sweep before returning.
 */
void OldGenSpace::lazySweep(size_t target_class, size_t work_budget) {
    size_t work_done = 0;

    while (work_done < work_budget && gc_phase_ == GCPhase::Sweeping) {
        // Get current sweep position.
        if (sweep_cursor_ == nullptr) {
            if (sweep_buffer_index_ >= blocks_.size()) {
                // All blocks swept - sweeping complete.
                gc_phase_ = GCPhase::Idle;
                onSweepComplete();
                return;
            }
            sweep_cursor_ = blocks_[sweep_buffer_index_].start;
        }

        BlockInfo& block = blocks_[sweep_buffer_index_];
        char* used_end = block.alloc_ptr;

        // Process objects in current block.
        while (sweep_cursor_ < used_end && work_done < work_budget) {
            Header* hdr = reinterpret_cast<Header*>(sweep_cursor_);
            size_t obj_size = getObjectSize(sweep_cursor_);

            if (sweep_buffer_index_ < buffer_meta_.size()) {
                BufferMetadata& meta = buffer_meta_[sweep_buffer_index_];

                if (hdr->color == static_cast<u32>(Color::Black)) {
                    // Live object: reset to white for next cycle.
                    hdr->color = static_cast<u32>(Color::White);
                    meta.live_bytes += obj_size;
                } else {
                    // Dead object: add to free list.
                    meta.garbage_bytes += obj_size;
                    size_t cls = sizeClass(obj_size);
                    if (cls < NUM_SIZE_CLASSES) {
                        FreeCell* cell = reinterpret_cast<FreeCell*>(sweep_cursor_);
                        cell->next = free_lists_[cls];
                        free_lists_[cls] = cell;
                    }
                }
            }

            sweep_cursor_ += obj_size;
            work_done += obj_size;
        }

        // Check if we've finished this block.
        if (sweep_cursor_ >= used_end) {
            if (sweep_buffer_index_ < buffer_meta_.size()) {
                buffer_meta_[sweep_buffer_index_].fully_swept = true;
            }
            sweep_buffer_index_++;
            sweep_cursor_ = nullptr;
        }

        // Early exit if we found space in target class.
        if (target_class < NUM_SIZE_CLASSES && free_lists_[target_class] != nullptr) {
            return;
        }
    }

    // Check if all blocks are swept.
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

    // Note: Actual compaction implementation is deferred to Phase 6.
    // For now, just compute the stats and check if compaction would be needed.
    // if (shouldCompact()) {
    //     scheduleCompaction();
    // }
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
        frag_stats_.heap_bytes += blocks_[i].usedBytes();
    }

    // Update allocated_bytes to reflect actual live bytes.
    // This accounts for memory reclaimed during sweep.
    allocated_bytes = frag_stats_.live_bytes;
}

/**
 * Returns true if compaction should be triggered.
 * Based on heap utilization falling below threshold.
 */
bool OldGenSpace::shouldCompact() const {
    // Compact when utilization is below threshold, indicating fragmentation.
    return frag_stats_.utilization() < UTILIZATION_THRESHOLD;
}

// ============================================================================
// Incremental Compaction Implementation
// ============================================================================

/**
 * Schedules compaction by selecting buffers to evacuate.
 */
void OldGenSpace::scheduleCompaction() {
    if (compact_phase_ != CompactionPhase::Idle) {
        return;  // Compaction already in progress.
    }

    // Select buffers with the most garbage for evacuation.
    // Limit total live bytes to move to keep pause times reasonable.
    evacuation_set_ = selectEvacuationSet(COMPACTION_WORK_BUDGET * 10);

    if (evacuation_set_.empty()) {
        return;  // Nothing to evacuate.
    }

    // Start evacuation phase.
    compact_phase_ = CompactionPhase::Evacuating;
    current_evac_index_ = 0;
    evac_cursor_ = nullptr;
}

/**
 * Selects blocks for evacuation, prioritizing those with most garbage.
 *
 * @param max_live_to_move Maximum live bytes to evacuate.
 * @return Vector of block indices to evacuate.
 */
std::vector<size_t> OldGenSpace::selectEvacuationSet(size_t max_live_to_move) {
    // Build candidate list: blocks with significant garbage (>30% dead).
    struct Candidate {
        size_t index;
        size_t garbage_bytes;
        size_t live_bytes;
    };
    std::vector<Candidate> candidates;

    for (size_t i = 0; i < buffer_meta_.size() && i < blocks_.size(); i++) {
        const auto& meta = buffer_meta_[i];

        // Skip current allocation block and non-swept blocks.
        if (i == current_block_index_ || !meta.fully_swept) {
            continue;
        }

        // Compute liveness for this block.
        size_t total = blocks_[i].usedBytes();
        float liveness = total > 0 ? static_cast<float>(meta.live_bytes) / total : 0.0f;

        // Only consider blocks with significant garbage (liveness < 70%).
        if (liveness < 0.70f && meta.garbage_bytes > 0) {
            candidates.push_back({i, meta.garbage_bytes, meta.live_bytes});
        }
    }

    // Sort by garbage bytes descending (worst first).
    std::sort(candidates.begin(), candidates.end(),
        [](const Candidate& a, const Candidate& b) {
            return a.garbage_bytes > b.garbage_bytes;
        });

    // Select buffers up to live-bytes budget.
    std::vector<size_t> evacuation_set;
    size_t total_live = 0;

    for (const auto& c : candidates) {
        if (total_live + c.live_bytes > max_live_to_move) {
            break;
        }
        evacuation_set.push_back(c.index);
        total_live += c.live_bytes;
    }

    return evacuation_set;
}

/**
 * Performs incremental compaction work.
 *
 * @param work_budget Maximum bytes of work to perform.
 */
void OldGenSpace::incrementalCompactionSlice(size_t work_budget) {
    if (compact_phase_ == CompactionPhase::Idle) {
        return;
    }

    size_t work_done = 0;

    if (compact_phase_ == CompactionPhase::Evacuating) {
        work_done = evacuateSlice(work_budget);

        if (current_evac_index_ >= evacuation_set_.size()) {
            // All buffers evacuated, now fix references.
            compact_phase_ = CompactionPhase::FixingRefs;
            prepareReferenceFixup();
        }
    }

    if (compact_phase_ == CompactionPhase::FixingRefs &&
        work_done < work_budget) {
        fixReferencesSlice(work_budget - work_done);
    }
}

/**
 * Evacuates live objects from one block slice.
 *
 * @param work_budget Maximum bytes to evacuate.
 * @return Bytes of work performed.
 */
size_t OldGenSpace::evacuateSlice(size_t work_budget) {
    size_t work_done = 0;

    while (work_done < work_budget &&
           current_evac_index_ < evacuation_set_.size()) {

        size_t src_idx = evacuation_set_[current_evac_index_];
        BlockInfo& src_block = blocks_[src_idx];

        // Initialize cursor if starting a new block.
        if (evac_cursor_ == nullptr) {
            evac_cursor_ = src_block.start;
        }

        char* end = src_block.alloc_ptr;

        while (evac_cursor_ < end && work_done < work_budget) {
            Header* hdr = reinterpret_cast<Header*>(evac_cursor_);
            size_t obj_size = getObjectSize(evac_cursor_);

            // Only move live objects (tag != Forward).
            if (hdr->tag != Tag_Forward) {
                // Allocate in a non-evacuating buffer.
                void* dest = allocateForEvacuation(obj_size);
                if (dest == nullptr) {
                    // Out of space - abort compaction.
                    compact_phase_ = CompactionPhase::Idle;
                    evacuation_set_.clear();
                    return work_done;
                }

                // Copy object to new location.
                std::memcpy(dest, evac_cursor_, obj_size);

                // Install forwarding pointer in old location.
                installForwardingPointer(evac_cursor_, dest);

                work_done += obj_size;
            }

            evac_cursor_ += obj_size;
        }

        if (evac_cursor_ >= end) {
            // Block fully evacuated.
            current_evac_index_++;
            evac_cursor_ = nullptr;
        }
    }

    return work_done;
}

/**
 * Allocates space for an evacuated object.
 * Allocates in blocks not in the evacuation set.
 */
void* OldGenSpace::allocateForEvacuation(size_t size) {
    // Try current block if it's not being evacuated.
    if (current_block_index_ != NO_BLOCK && !isInEvacuationSet(current_block_index_)) {
        void* result = blocks_[current_block_index_].allocate(size);
        if (result) {
            return result;
        }
    }

    // Need a new block - acquire from allocator.
    // Note: During compaction we skip the normal allocation path
    // to avoid triggering more GC work.
    if (allocator_) {
        char* block_base = allocator_->acquireOldGenBlock(config_->alloc_buffer_size);
        if (block_base) {
            BlockInfo new_block;
            new_block.start = block_base;
            new_block.end = block_base + config_->alloc_buffer_size;
            new_block.alloc_ptr = block_base;

            blocks_.push_back(new_block);
            current_block_index_ = blocks_.size() - 1;
            buffer_meta_.push_back({current_block_index_, 0, 0, false});

            // Update cached bounds.
            if (region_base_ == nullptr) {
                region_base_ = block_base;
            }
            region_end_ = new_block.end;

            return blocks_[current_block_index_].allocate(size);
        }
    }

    return nullptr;  // Out of memory.
}

/**
 * Installs a forwarding pointer at the old object location.
 */
void OldGenSpace::installForwardingPointer(void* old_location, void* new_location) {
    // Use the Forward struct layout from heap.hpp.
    Forward* fwd = reinterpret_cast<Forward*>(old_location);
    fwd->header.tag = Tag_Forward;

    // Compute logical pointer offset for the new location.
    char* new_ptr = static_cast<char*>(new_location);
    u64 offset = (new_ptr - g_heap_base) >> 3;  // Convert to 8-byte aligned offset.
    fwd->header.forward_ptr = offset;
}

/**
 * Gets the forwarding address for an object, if forwarded.
 *
 * @return New location, or nullptr if not forwarded.
 */
void* OldGenSpace::getForwardingAddress(void* obj) const {
    Header* hdr = reinterpret_cast<Header*>(obj);
    if (hdr->tag == Tag_Forward) {
        Forward* fwd = reinterpret_cast<Forward*>(obj);
        return g_heap_base + (fwd->header.forward_ptr << 3);
    }
    return nullptr;  // Not forwarded.
}

/**
 * Prepares for the reference fixup phase.
 */
void OldGenSpace::prepareReferenceFixup() {
    fixup_buffer_index_ = 0;
    fixup_cursor_ = nullptr;
}

/**
 * Fixes references in a slice of the heap.
 *
 * @param work_budget Maximum bytes of work to perform.
 */
void OldGenSpace::fixReferencesSlice(size_t work_budget) {
    size_t work_done = 0;

    while (work_done < work_budget &&
           fixup_buffer_index_ < blocks_.size()) {

        // Skip evacuated blocks (they're about to be freed).
        if (isInEvacuationSet(fixup_buffer_index_)) {
            fixup_buffer_index_++;
            fixup_cursor_ = nullptr;
            continue;
        }

        BlockInfo& block = blocks_[fixup_buffer_index_];

        // Initialize cursor if starting a new block.
        if (fixup_cursor_ == nullptr) {
            fixup_cursor_ = block.start;
        }

        char* end = block.alloc_ptr;

        while (fixup_cursor_ < end && work_done < work_budget) {
            Header* hdr = reinterpret_cast<Header*>(fixup_cursor_);
            size_t obj_size = getObjectSize(fixup_cursor_);

            // Only fix live objects (not forwarding pointers).
            if (hdr->tag != Tag_Forward) {
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
        // Reference fixup complete - free evacuated blocks.
        freeEvacuatedBuffers();
        compact_phase_ = CompactionPhase::Idle;
    }
}

/**
 * Fixes all pointers within an object that point to evacuated objects.
 */
void OldGenSpace::fixPointersInObject(void* obj) {
    Header* hdr = getHeader(obj);

    switch (hdr->tag) {
        case Tag_Tuple2: {
            Tuple2* t = static_cast<Tuple2*>(obj);
            fixUnboxable(t->a, !(hdr->unboxed & 1));
            fixUnboxable(t->b, !(hdr->unboxed & 2));
            break;
        }
        case Tag_Tuple3: {
            Tuple3* t = static_cast<Tuple3*>(obj);
            fixUnboxable(t->a, !(hdr->unboxed & 1));
            fixUnboxable(t->b, !(hdr->unboxed & 2));
            fixUnboxable(t->c, !(hdr->unboxed & 4));
            break;
        }
        case Tag_Cons: {
            Cons* c = static_cast<Cons*>(obj);
            fixUnboxable(c->head, !(hdr->unboxed & 1));
            fixHPointer(c->tail);
            break;
        }
        case Tag_Custom: {
            Custom* c = static_cast<Custom*>(obj);
            for (u32 i = 0; i < hdr->size && i < 48; i++) {
                fixUnboxable(c->values[i], !(c->unboxed & (1ULL << i)));
            }
            break;
        }
        case Tag_Record: {
            Record* r = static_cast<Record*>(obj);
            for (u32 i = 0; i < hdr->size && i < 64; i++) {
                fixUnboxable(r->values[i], !(r->unboxed & (1ULL << i)));
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
                fixUnboxable(cl->values[i], !(cl->unboxed & (1ULL << i)));
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
            bool is_boxed = !arr->header.unboxed;
            for (u32 i = 0; i < arr->length; i++) {
                fixUnboxable(arr->elements[i], is_boxed);
            }
            break;
        }
        default:
            // No pointers to fix (Int, Float, Char, String, FieldGroup, ByteBuffer).
            break;
    }
}

/**
 * Fixes an HPointer if it points to a forwarded object.
 */
void OldGenSpace::fixHPointer(HPointer& ptr) {
    if (ptr.constant != 0) {
        return;  // Constant, not a heap pointer.
    }

    void* obj = Allocator::fromPointerRaw(ptr);
    if (obj == nullptr) {
        return;
    }

    void* fwd = getForwardingAddress(obj);
    if (fwd != nullptr) {
        // Update pointer to new location.
        ptr = Allocator::toPointerRaw(fwd);
    }
}

/**
 * Fixes an Unboxable value if it's boxed and points to a forwarded object.
 */
void OldGenSpace::fixUnboxable(Unboxable& val, bool is_boxed) {
    if (is_boxed) {
        fixHPointer(val.p);
    }
}

/**
 * Checks if a block index is in the evacuation set.
 */
bool OldGenSpace::isInEvacuationSet(size_t buffer_index) const {
    return std::find(evacuation_set_.begin(), evacuation_set_.end(),
                     buffer_index) != evacuation_set_.end();
}

/**
 * Frees all evacuated blocks after compaction completes.
 */
void OldGenSpace::freeEvacuatedBuffers() {
    // Sort evacuation set in descending order for safe removal.
    std::vector<size_t> sorted_set = evacuation_set_;
    std::sort(sorted_set.begin(), sorted_set.end(), std::greater<size_t>());

    for (size_t idx : sorted_set) {
        // Memory is owned by Allocator's mmap region - just remove from vectors.
        blocks_.erase(blocks_.begin() + idx);
        if (idx < buffer_meta_.size()) {
            buffer_meta_.erase(buffer_meta_.begin() + idx);
        }

        // Update current_block_index_ if needed.
        if (current_block_index_ != NO_BLOCK) {
            if (current_block_index_ == idx) {
                current_block_index_ = NO_BLOCK;
            } else if (current_block_index_ > idx) {
                current_block_index_--;
            }
        }
    }

    evacuation_set_.clear();

    // Recalculate fragmentation stats after compaction.
    computeFragmentationStats();
}

} // namespace Elm
