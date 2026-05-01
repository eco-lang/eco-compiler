/**
 * Common Definitions for Allocator Components.
 *
 * This file contains shared constants, types, and utilities used across
 * the allocator subsystem (NurserySpace, OldGenSpace, Allocator).
 *
 * Key contents:
 *   - Sizing constants: Heap size, nursery size, AllocBuffer size.
 *   - Color enum: Tri-color marking states (White, Grey, Black).
 *   - Utility functions: getHeader(), getObjectSize().
 */

#ifndef ECO_ALLOCATOR_COMMON_H
#define ECO_ALLOCATOR_COMMON_H

#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include "Heap.hpp"

// Enable extra GC assertions and nursery invariants in debug builds.
// Normally set via CMake (-DECO_GC_DEBUG=1); this provides a safe fallback.
#ifndef ECO_GC_DEBUG
#define ECO_GC_DEBUG 0
#endif

namespace Elm {

class Allocator;

// Tri-color marking states for mark-and-sweep GC.
enum class Color : u32 {
    White = 0,   // Not yet marked (potential garbage).
    Grey = 1,    // Marked but children not yet scanned.
    Black = 2    // Marked and all children scanned.
};

// ============================================================================
// Sizing Constants
// ============================================================================

// Heap sizing.
constexpr size_t DEFAULT_MAX_HEAP_SIZE = 24ULL * 1024 * 1024 * 1024;  // 32 GB address space (12 GB old gen + 12 GB nursery).
constexpr size_t INITIAL_OLD_GEN_SIZE = 16 * 1024 * 1024;            // 16 MB initial commit.

// Default cap on bytes committed to uniform small-class pages before
// the allocator starts splitting larger free cells to satisfy
// fixed-size-class requests. See HeapConfig::small_class_heap_budget_bytes.
constexpr size_t DEFAULT_SMALL_CLASS_HEAP_BUDGET = 1024ULL * 1024 * 1024;  // 1 GiB

// AllocBuffer sizing.
constexpr size_t ALLOC_BUFFER_SIZE = 128 * 1024;  // 128 KB default AllocBuffer.

// Nursery sizing (in blocks, same size as AllocBuffer).
// Block count must be even (split into from-space and to-space).
constexpr size_t NURSERY_BLOCK_COUNT = 64;  // 32 blocks = 4 MB total (16 per semi-space).

// Promotion and GC triggers.
constexpr u32 PROMOTION_AGE = 2;                            // Promote after surviving 2 minor GCs.
constexpr float NURSERY_GC_THRESHOLD = 0.9f;                // Trigger minor GC at 90% full.

// Adaptive nursery growth: after a minor GC, request more blocks if to-space
// occupancy exceeds this fraction. Lower values grow the nursery more
// aggressively (cheaper minor GCs, larger working set).
constexpr float NURSERY_GROWTH_THRESHOLD = 0.1f;

// Returns the header of a heap object.
inline Header *getHeader(void *obj) { return static_cast<Header *>(obj); }

// Returns the size of a heap object in bytes (8-byte aligned).
inline size_t getObjectSize(void *obj) {
    Header *hdr = getHeader(obj);

    size_t size;
    switch (hdr->tag) {
        case Tag_Int:
            size = sizeof(ElmInt);
            break;
        case Tag_Float:
            size = sizeof(ElmFloat);
            break;
        case Tag_Char:
            size = sizeof(ElmChar);
            break;
        case Tag_String:
            size = sizeof(ElmString) + hdr->size * sizeof(u16);
            break;
        case Tag_StringSlice:
            // Fixed-size view: header.size is the logical UTF-16 length, not
            // a byte count. The slice itself is a fixed struct.
            size = sizeof(ElmStringSlice);
            break;
        case Tag_StringRope:
            // Fixed-size concat-tree node: header.size is the total logical
            // UTF-16 length; the rope struct itself has fixed footprint.
            size = sizeof(ElmStringRope);
            break;
        case Tag_Tuple2:
            size = sizeof(Tuple2);
            break;
        case Tag_Tuple3:
            size = sizeof(Tuple3);
            break;
        case Tag_Cons:
            size = sizeof(Cons);
            break;
        case Tag_Custom:
            size = sizeof(Custom) + hdr->size * sizeof(Unboxable);
            break;
        case Tag_Record:
            size = sizeof(Record) + hdr->size * sizeof(Unboxable);
            break;
        case Tag_DynRecord:
            size = sizeof(DynRecord) + hdr->size * sizeof(HPointer);
            break;
        case Tag_FieldGroup:
            size = sizeof(FieldGroup) + hdr->size * sizeof(u32);
            break;
        case Tag_Closure:
            size = sizeof(Closure) + hdr->size * sizeof(Unboxable);
            break;
        case Tag_Process:
            size = sizeof(Process);
            break;
        case Tag_Task:
            size = sizeof(Task);
            break;
        case Tag_Forward:
            size = sizeof(Forward);
            break;
        case Tag_Free:
            // Free cells store their full byte size directly in header.size.
            // Already 8-byte aligned at the time the cell was created.
            size = hdr->size;
            break;
        case Tag_ByteBuffer:
            // Header size field stores byte count.
            size = sizeof(ByteBuffer) + hdr->size * sizeof(u8);
            break;
        case Tag_Array: {
            // Size based on CAPACITY (header.size), not length: the heap
            // object occupies bytes for the full capacity reserved at
            // allocation time, so sweep must walk by capacity to land on
            // the next object's header. Iterating only `length` elements
            // is for marking/copying/fixup — but the heap footprint and
            // the per-object stride during sweep both need capacity.
            ElmArray *arr = static_cast<ElmArray *>(obj);
            size = sizeof(ElmArray) + arr->header.size * sizeof(Unboxable);
            break;
        }
        case Tag_LargeStringHeader:
            // Fixed-size split header. header.size carries the body's logical
            // UTF-16 length (not a byte count for this object).
            size = sizeof(LargeStringHeader);
            break;
        case Tag_LargeByteHeader:
            // Fixed-size split header. header.size carries the body's logical
            // byte count (not a byte count for this object).
            size = sizeof(LargeByteHeader);
            break;
        default:
            size = sizeof(Header);
            break;
    }

    // All heap objects are 8-byte aligned.
    return (size + 7) & ~7;
}

// ============================================================================
// Heap Configuration
// ============================================================================

/**
 * Configuration for heap and allocator parameters.
 *
 * All fields have sensible defaults from the constants above. Users can
 * override any field before passing to Allocator::initialize().
 */
struct HeapConfig {
    // Heap sizing.
    size_t max_heap_size = DEFAULT_MAX_HEAP_SIZE;
    size_t initial_old_gen_size = INITIAL_OLD_GEN_SIZE;

    // AllocBuffer sizing.
    size_t alloc_buffer_size = ALLOC_BUFFER_SIZE;

    // Nursery sizing (in blocks, not bytes).
    // Block count must be even (split into from-space and to-space).
    size_t nursery_block_count = NURSERY_BLOCK_COUNT;

    // Promotion & GC triggers.
    u32 promotion_age = PROMOTION_AGE;
    float nursery_gc_threshold = NURSERY_GC_THRESHOLD;

    // After a minor GC, NurserySpace requests additional blocks when the
    // to-space occupancy after evacuation exceeds this fraction.
    float nursery_growth_threshold = NURSERY_GROWTH_THRESHOLD;

    // Major GC policy (old-gen).
    //  * initiating_occupancy: fraction of old-gen cap that, once crossed by
    //    `old_gen_committed`, schedules a major GC at the next safepoint.
    //  * target_utilization:   immediately after a major GC, if
    //    live / committed > initiating_occupancy, grow committed capacity so
    //    that live / committed <= target (bounded by the global old-gen cap).
    // Invariant: initiating_occupancy > target_utilization (prevents a
    // grow-loop where post-grow occupancy re-triggers the rule).
    float major_gc_initiating_occupancy = 0.75f;
    float major_gc_target_utilization   = 0.50f;

    // List locality optimization: two-pass spine copying.
    // When enabled, Cons list spines are copied contiguously using a two-pass
    // algorithm (pass 1: copy tail chain, pass 2: evacuate heads), which
    // provides better cache locality when traversing lists later.
    // All other types use standard Cheney's BFS evacuation.
    bool use_hybrid_dfs = true;

    // Large-object threshold (bytes). Allocations of this size or larger
    // bypass the nursery and are placed directly in old gen as pinned
    // objects (Header.pin = 1) so the compactor leaves them in place. For
    // Tag_String / Tag_ByteBuffer this same threshold also triggers the
    // split-header path (HEAP_026): a small Tag_LargeStringHeader /
    // Tag_LargeByteHeader lives in the nursery while the body lives pinned
    // in old gen and is never copied. See plans/large-object-split-header-bodies.md.
    // Default: max(8 KiB, alloc_buffer_size / 16). With the default
    // alloc_buffer_size of 128 KiB this resolves to 8 KiB.
    size_t large_object_threshold =
        (ALLOC_BUFFER_SIZE / 16 > 8 * 1024) ? (ALLOC_BUFFER_SIZE / 16) : (8 * 1024);

    // When `releaseOldGenBlock` is called, also `madvise(MADV_DONTNEED)` the
    // released extent so its physical RSS drops. The virtual mapping is
    // retained either way; this flag controls only the RSS behaviour.
    //
    // TEMP: defaulting to false while debugging missed-mark-roots that
    // produce stale HPointers into released pages. With decommit ON, those
    // stale pointers read zero (madvise zeros); with decommit OFF, the bytes
    // stay intact so the symptom either disappears (if it really was just
    // zero reads) or shifts to a clearly observable mark-phase issue.
    bool decommit_on_oldgen_release = true;

    // Cap on bytes committed to uniform small-class pages before we start
    // splitting larger free cells down into those classes. 0 disables.
    size_t small_class_heap_budget_bytes = DEFAULT_SMALL_CLASS_HEAP_BUDGET;

    // Cell-size cap that defines "small" for budgeting. Defaults to the
    // large-object threshold so the heuristic covers all fast-path classes.
    size_t small_class_cell_max_bytes = large_object_threshold;

    // Derived value: total nursery size in bytes.
    size_t nurserySize() const { return nursery_block_count * alloc_buffer_size; }

    // Default constructor uses in-class member initializers.
    HeapConfig() = default;

    // Validates all configuration parameters.
    // Throws std::invalid_argument with descriptive message on validation failure.
    void validate() const {
        // ========== 1. Basic Size Constraints ==========

        if (max_heap_size == 0) {
            throw std::invalid_argument("max_heap_size must be > 0");
        }

        if (initial_old_gen_size == 0) {
            throw std::invalid_argument("initial_old_gen_size must be > 0");
        }

        if (alloc_buffer_size == 0) {
            throw std::invalid_argument("alloc_buffer_size must be > 0");
        }

        if (nursery_block_count == 0) {
            throw std::invalid_argument("nursery_block_count must be > 0");
        }

        // ========== 2. Heap Partitioning Constraints ==========
        // Heap is split: [0, max/2) = old gen, [max/2, max) = nursery.

        size_t old_gen_space = max_heap_size / 2;

        if (initial_old_gen_size >= old_gen_space) {
            throw std::invalid_argument(
                "initial_old_gen_size must be < max_heap_size / 2 "
                "(old gen lives in first half of heap)");
        }

        size_t nursery_size = nurserySize();
        if (nursery_size >= old_gen_space) {
            throw std::invalid_argument(
                "nursery total size must be < max_heap_size / 2 "
                "(nursery lives in second half of heap)");
        }

        // ========== 3. Nursery Block Constraints ==========
        // Nursery is split into two semi-spaces (from and to).

        if (nursery_block_count % 2 != 0) {
            throw std::invalid_argument(
                "nursery_block_count must be even (split into from-space and to-space)");
        }

        if (nursery_block_count < 2) {
            throw std::invalid_argument(
                "nursery_block_count must be >= 2 (at least 1 block per semi-space)");
        }

        // ========== 4. AllocBuffer Constraints ==========

        constexpr size_t MIN_BUFFER_SIZE = 4096;  // 4KB minimum.
        if (alloc_buffer_size < MIN_BUFFER_SIZE) {
            throw std::invalid_argument(
                "alloc_buffer_size must be >= 4KB");
        }

        if (alloc_buffer_size > old_gen_space) {
            throw std::invalid_argument(
                "alloc_buffer_size must be <= max_heap_size / 2 "
                "(can't exceed old gen space)");
        }

        // Old gen is sliced into BBoP pages of `alloc_buffer_size` at init.
        if (initial_old_gen_size % alloc_buffer_size != 0) {
            throw std::invalid_argument(
                "initial_old_gen_size must be a multiple of alloc_buffer_size "
                "(old gen is sliced into pages at init time)");
        }

        // ========== 4b. Large-Object Threshold Constraints ==========

        if (large_object_threshold < sizeof(Header)) {
            throw std::invalid_argument(
                "large_object_threshold must be >= sizeof(Header)");
        }
        if (large_object_threshold > old_gen_space) {
            throw std::invalid_argument(
                "large_object_threshold must be <= max_heap_size / 2 "
                "(can't exceed old gen space)");
        }
        // Any object below large_object_threshold is allocated in the
        // nursery, where the unit of allocation is a single block of
        // alloc_buffer_size bytes. The semi-space evacuator can only
        // copy an object that fits in a single block. So every object
        // routed through the nursery — i.e. every object whose aligned
        // size is < large_object_threshold — must also be < alloc_buffer_size.
        // The simplest sufficient invariant: large_object_threshold <=
        // alloc_buffer_size. Otherwise an allocation in the gap would
        // either fail to allocate or fail to evacuate after one minor GC.
        if (large_object_threshold > alloc_buffer_size) {
            throw std::invalid_argument(
                "large_object_threshold must be <= alloc_buffer_size "
                "(otherwise objects in [alloc_buffer_size, "
                "large_object_threshold) take the nursery path but cannot "
                "fit in a single nursery block)");
        }

        // ========== 5. Promotion Constraints ==========

        if (promotion_age < 1) {
            throw std::invalid_argument(
                "promotion_age must be >= 1 (must survive at least 1 GC)");
        }

        if (promotion_age > 3) {
            throw std::invalid_argument(
                "promotion_age must be <= 3 (header age field is 2 bits)");
        }

        // ========== 6. Threshold Constraints ==========

        if (nursery_gc_threshold <= 0.0f || nursery_gc_threshold > 1.0f) {
            throw std::invalid_argument(
                "nursery_gc_threshold must be in (0.0, 1.0]");
        }

        if (nursery_growth_threshold <= 0.0f ||
            nursery_growth_threshold >= 1.0f) {
            throw std::invalid_argument(
                "nursery_growth_threshold must be in (0.0, 1.0)");
        }

        if (major_gc_initiating_occupancy <= 0.0f ||
            major_gc_initiating_occupancy >= 1.0f) {
            throw std::invalid_argument(
                "major_gc_initiating_occupancy must be in (0.0, 1.0)");
        }

        if (major_gc_target_utilization <= 0.0f ||
            major_gc_target_utilization >= 1.0f) {
            throw std::invalid_argument(
                "major_gc_target_utilization must be in (0.0, 1.0)");
        }

        if (major_gc_initiating_occupancy <= major_gc_target_utilization) {
            throw std::invalid_argument(
                "major_gc_initiating_occupancy must be > "
                "major_gc_target_utilization");
        }

        // ========== 7. Small-Class Block Budget ==========
        //
        // small_class_heap_budget_bytes can be set to any value. When it
        // exceeds the old-gen cap (max_heap_size / 2), the heuristic is
        // effectively unbounded: small-class allocations always prefer
        // bag-first until the cap itself is hit. The default of 1 GiB is
        // well within the default 12 GiB old-gen cap; smaller test heaps
        // simply get the unbounded behaviour, which still respects
        // committedToCapRatio < 1.0.

        // FreeCell footprint: Header + a pointer link. The small-class
        // cell-size cap must be at least this so any class included in the
        // budget can legitimately host a FreeCell on its free list.
        constexpr size_t MIN_FREE_CELL_FOOTPRINT = sizeof(Header) + sizeof(void*);
        if (small_class_cell_max_bytes != 0 &&
            small_class_cell_max_bytes < MIN_FREE_CELL_FOOTPRINT) {
            throw std::invalid_argument(
                "small_class_cell_max_bytes must be >= sizeof(FreeCell)");
        }
        // Note: small_class_cell_max_bytes may exceed large_object_threshold.
        // Allocations below LOT but at/below small_class_cell_max_bytes still
        // route through fixed-size cell classes; cells larger than the
        // requested size simply waste the slack space.
    }
};

} // namespace Elm

#endif // ECO_ALLOCATOR_COMMON_H
