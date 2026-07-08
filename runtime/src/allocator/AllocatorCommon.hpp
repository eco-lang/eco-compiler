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

// Heap-validator switch. Independent of ECO_GC_DEBUG. Gates the always-on
// stale-HPointer detection (write/read/arg-side hooks, free-region
// poisoning), the per-container bitmap-mismatch tripwires, the post-GC
// heap-integrity walker, the from-space pre-evacuation walk, the
// forward-chain depth assert, and the old-gen / BBoP invariant audits.
// Off by default — these are hot-path checks. Turn on via CMake
// (-DECO_HEAP_VALIDATE=ON) for diagnostic runs (heap-profile, stress).
#ifndef ECO_HEAP_VALIDATE
#define ECO_HEAP_VALIDATE 0
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
// Default Configuration Constants
// ============================================================================
// Every HeapConfig field's default initializer pulls its value from one of
// these constants — keep them in sync. Grouped by scope: heap-wide, string /
// rope heuristics, nursery, then old generation. HeapConfig declares its
// fields in the same order.

// ---- Heap-wide ----

// OS page size for mmap(MAP_FIXED) alignment of old-gen large-block extents.
// mmap rejects MAP_FIXED requests whose address or length is not a page
// multiple, so the allocator's bump pointer must advance in multiples of the
// OS's page size — not a smaller "logical page". Darwin on Apple Silicon uses
// 16 KiB pages (`sysctl hw.pagesize`); Linux on x86-64/aarch64 and Darwin on
// x86-64 use 4 KiB. We can't make this dynamic without unwinding a lot of
// constexpr math, so pin it at compile time per platform and assert at
// allocator init that getpagesize() matches.
#if defined(__APPLE__) && defined(__aarch64__)
constexpr size_t OS_PAGE_SIZE = 16384;
#else
constexpr size_t OS_PAGE_SIZE = 4096;
#endif

// Reserved virtual address space for the heap (24 GiB; ~12 GiB old gen + ~12 GiB nursery).
constexpr size_t DEFAULT_MAX_HEAP_SIZE = 24ULL * 1024 * 1024 * 1024;

// Size of one AllocBuffer / nursery block / old-gen BBoP page in bytes.
constexpr size_t ALLOC_BUFFER_SIZE = 512 * 1024;

// Allocations of this size or larger bypass the nursery and are pinned in old gen (also triggers split-header path for strings/byte buffers).
constexpr size_t LARGE_OBJECT_THRESHOLD = 8 * 1024;

// ---- String / rope heuristics ----

// Concat results <= this many UTF-16 code units flatten to a single leaf; larger totals build a Tag_StringRope.
constexpr size_t STRING_FLATTEN_LIMIT = 32 * 1024;

// slice() ranges <= this many UTF-16 code units flatten directly instead of allocating a Tag_StringSlice.
constexpr size_t STRING_TINY_SLICE_LIMIT = 128;

// Bytes.Decode.string builds a zero-copy Tag_StringUtf8View for valid all-ASCII
// payloads at least this many bytes; shorter valid-ASCII input copies a small
// Tag_StringUtf8Leaf (mirrors MAKE_BYTEBUFFER_SLICE_MIN_LEN).
constexpr size_t UTF8_VIEW_MIN_LEN = 32;

// Master switch for creating any UTF-8 String form (view or leaf). When false,
// every creation path falls back to the UTF-16 forms — a config-only rollback.
constexpr bool UTF8_STRINGS_ENABLED = true;

// Rope tree depth above which the rebalance heuristic flags the rope (rebalance itself is TODO).
constexpr u32 ROPE_MAX_HEIGHT = 32;

// Leaf count above which the rebalance heuristic checks for too-many-small-leaves (paired with ROPE_MIN_LEAF_SIZE).
constexpr u32 ROPE_LEAF_COUNT_LIMIT = 64;

// Average leaf size below which a rope at/over ROPE_LEAF_COUNT_LIMIT is flagged as a rebalance candidate.
constexpr u32 ROPE_MIN_LEAF_SIZE = 128;

// ---- Nursery ----

// Initial nursery size in blocks (must be even; split into from/to semi-spaces).
constexpr size_t NURSERY_BLOCK_COUNT = 256;

// Hard upper bound on adaptive nursery growth, in blocks (must be even).
constexpr size_t NURSERY_MAX_BLOCKS = 1024;

// Nursery occupancy fraction that triggers a minor GC.
constexpr float NURSERY_GC_THRESHOLD = 0.95f;

// Post-minor-GC to-space occupancy above which the nursery requests more blocks.
constexpr float NURSERY_GROWTH_THRESHOLD = 0.20f;

// Minor-GC survivals required before an object is promoted to old gen (header age field is 2 bits).
constexpr u32 PROMOTION_AGE = 2;

// Enable two-pass DFS spine copying for Cons lists during minor GC (else BFS for all types).
constexpr bool USE_HYBRID_DFS = true;

// ---- Old generation ----

// Initial committed bytes of the old generation at startup.
constexpr size_t INITIAL_OLD_GEN_SIZE = 16 * 1024 * 1024;

// Old-gen committed/cap fraction above which a major GC is scheduled (must exceed MAJOR_GC_TARGET_UTILIZATION).
constexpr float MAJOR_GC_INITIATING_OCCUPANCY = 0.85f;

// Post-major-GC live/committed target; the old-gen cap is grown to keep utilization below this.
constexpr float MAJOR_GC_TARGET_UTILIZATION = 0.50f;

// Fraction of old-gen committed that, once allocated since the last major, schedules another (0.0 disables).
constexpr float MAJOR_GC_GARBAGE_FRACTION = 0.70f;

// On releaseOldGenBlock, also madvise(MADV_DONTNEED) to drop physical RSS (virtual mapping is retained either way).
constexpr bool DECOMMIT_ON_OLDGEN_RELEASE = true;

// Default cap on bytes committed to uniform small-class pages before splitting larger free cells.
constexpr size_t DEFAULT_SMALL_CLASS_HEAP_BUDGET = 1024ULL * 1024 * 1024;

// ---- Old-gen sweep & mark pacing ----

// Bytes of lazy-sweep work the allocator does per slow-path invocation (per slice).
constexpr size_t SWEEP_WORK_BUDGET = 4096;

// Bytes of sweep work `finishMarkAndSweep` runs synchronously before returning (seeds free lists for the first allocations).
constexpr size_t INITIAL_SWEEP_BUDGET = SWEEP_WORK_BUDGET * 16;

// Incremental marking work ratio: bytes marked per byte allocated during the marking phase.
constexpr size_t MARK_WORK_RATIO = 2;

// Base proportionality factor for the per-allocation sweep budget (bytes swept per byte requested), pre pressure scaling.
constexpr double SWEEP_BYTES_PER_ALLOC_BYTE = 2.0;

// Soft cap on the per-allocation sweep budget BEFORE pressure scaling (1 MiB).
constexpr size_t MAX_SWEEP_BYTES_PER_ALLOC = 1u << 20;

// Hard cap applied AFTER pressure scaling and unswept-ratio boost (4 MiB).
constexpr size_t MAX_SWEEP_BYTES_HARD = 4u << 20;

// Pressure thresholds on committedToCapRatio: each step picks the matching SWEEP_SCALE_*.
constexpr double SWEEP_CAP_RATIO_LOW    = 0.50;
constexpr double SWEEP_CAP_RATIO_MEDIUM = 0.75;
constexpr double SWEEP_CAP_RATIO_HIGH   = 0.90;

// Per-allocation sweep budget multipliers, indexed by pressure step (must be non-decreasing and >= 1.0).
constexpr double SWEEP_SCALE_LOW    = 1.0;
constexpr double SWEEP_SCALE_MEDIUM = 2.0;
constexpr double SWEEP_SCALE_HIGH   = 4.0;
constexpr double SWEEP_SCALE_CRIT   = 8.0;

// Unswept-block fraction above which the per-allocation sweep budget gets a SWEEP_UNSWEPT_SCALE boost.
constexpr double SWEEP_UNSWEPT_RATIO_BOOST = 0.50;

// Multiplier applied on top of pressure scaling when the unswept-block fraction is above the boost threshold.
constexpr double SWEEP_UNSWEPT_SCALE = 2.0;

// Per-slice budget for the panic-path sweeper (drives lazy sweep to completion before declaring OOM).
constexpr size_t PANIC_SWEEP_SLICE_BYTES = 1u << 20;

// ---- Old-gen free-list layout (compile-time, not runtime-configurable) ----
// These size class-counts compile into static array dimensions
// (e.g. OldGenSpace::free_lists_[NUM_SIZE_CLASSES]) and the corresponding
// telemetry buckets in GCStats, so they cannot be moved into HeapConfig
// without converting those arrays to dynamic containers.

// Number of small-cell size classes: 8 B steps from 8 up through MAX_SMALL_SIZE.
constexpr size_t NUM_SMALL_CLASSES = 32;

// Largest cell size served by a small class (last small class is exactly this many bytes).
constexpr size_t MAX_SMALL_SIZE = 256;

// First medium class size in bytes; subsequent medium classes are powers-of-two from here.
constexpr size_t MEDIUM_CLASS_BASE = 512;

// Medium-class slots reserved at compile time; the runtime cap depends on large_object_threshold.
constexpr size_t NUM_MEDIUM_CLASSES_MAX = 8;

// Total fixed-size class count; sizes the per-class free-list array.
constexpr size_t NUM_SIZE_CLASSES = NUM_SMALL_CLASSES + NUM_MEDIUM_CLASSES_MAX;

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
        case Tag_ByteBufferSlice:
            // Fixed-size view: header.size is the logical byte count, not the
            // struct footprint. Mirrors the Tag_StringSlice case above; without
            // it a 24-byte slice was mis-sized as sizeof(Header)=8, corrupting
            // GC evacuation/scan stride (HEAP_004).
            size = sizeof(ElmByteBufferSlice);
            break;
        case Tag_StringUtf8View:
            // Fixed-size byte view; header.size is the logical unit count, not
            // the footprint. Mirrors Tag_StringSlice / Tag_ByteBufferSlice.
            size = sizeof(ElmStringUtf8View);
            break;
        case Tag_StringUtf8Leaf:
            // Inline ASCII bytes: 1 byte per unit. Footprint derives from
            // header.size exactly like Tag_String (but u8, not u16).
            size = sizeof(ElmStringUtf8Leaf) + hdr->size * sizeof(u8);
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
    // ---- Heap-wide ----

    // Reserved virtual address space for the heap.
    size_t max_heap_size = DEFAULT_MAX_HEAP_SIZE;

    // Size of one AllocBuffer / nursery block / old-gen BBoP page in bytes.
    size_t alloc_buffer_size = ALLOC_BUFFER_SIZE;

    // Allocations of this size or larger bypass the nursery and are pinned in old gen.
    size_t large_object_threshold = LARGE_OBJECT_THRESHOLD;

    // ---- String / rope heuristics ----

    // Concat results <= this many UTF-16 code units flatten to a single leaf; larger totals build a rope.
    size_t string_flatten_limit = STRING_FLATTEN_LIMIT;

    // slice() ranges <= this many UTF-16 code units flatten directly instead of allocating a slice.
    size_t string_tiny_slice_limit = STRING_TINY_SLICE_LIMIT;

    // Min byte length for Bytes.Decode.string to build a zero-copy UTF-8 view
    // (shorter valid-ASCII decodes copy a small UTF-8 leaf).
    size_t utf8_view_min_len = UTF8_VIEW_MIN_LEN;

    // Master switch: when false, no UTF-8 String form is ever created.
    bool utf8_strings_enabled = UTF8_STRINGS_ENABLED;

    // Rope tree depth above which the rebalance heuristic flags the rope.
    u32 rope_max_height = ROPE_MAX_HEIGHT;

    // Leaf count above which the rebalance heuristic checks for too-many-small-leaves.
    u32 rope_leaf_count_limit = ROPE_LEAF_COUNT_LIMIT;

    // Average leaf size below which a rope at/over rope_leaf_count_limit is flagged as a rebalance candidate.
    u32 rope_min_leaf_size = ROPE_MIN_LEAF_SIZE;

    // ---- Nursery ----

    // Initial nursery size in blocks (even; split into from/to semi-spaces).
    size_t nursery_block_count = NURSERY_BLOCK_COUNT;

    // Hard upper bound on adaptive nursery growth, in blocks (even; >= nursery_block_count).
    size_t nursery_max_block_count = NURSERY_MAX_BLOCKS;

    // Nursery occupancy fraction that triggers a minor GC.
    float nursery_gc_threshold = NURSERY_GC_THRESHOLD;

    // Post-minor-GC to-space occupancy above which the nursery requests more blocks.
    float nursery_growth_threshold = NURSERY_GROWTH_THRESHOLD;

    // Minor-GC survivals required before an object is promoted to old gen.
    u32 promotion_age = PROMOTION_AGE;

    // Enable two-pass DFS spine copying for Cons lists during minor GC (else BFS for all types).
    bool use_hybrid_dfs = USE_HYBRID_DFS;

    // ---- Old generation ----

    // Initial committed bytes of the old generation at startup.
    size_t initial_old_gen_size = INITIAL_OLD_GEN_SIZE;

    // Old-gen committed/cap fraction above which a major GC is scheduled (must be > target_utilization).
    float major_gc_initiating_occupancy = MAJOR_GC_INITIATING_OCCUPANCY;

    // Post-major-GC live/committed target; the old-gen cap is grown to stay below this.
    float major_gc_target_utilization = MAJOR_GC_TARGET_UTILIZATION;

    // Fraction of old-gen committed allocated-since-last-major that schedules another major (0.0 disables).
    float major_gc_garbage_fraction = MAJOR_GC_GARBAGE_FRACTION;

    // On releaseOldGenBlock, also madvise(MADV_DONTNEED) to drop physical RSS.
    bool decommit_on_oldgen_release = DECOMMIT_ON_OLDGEN_RELEASE;

    // Cap on bytes committed to uniform small-class pages before splitting larger free cells (0 disables).
    size_t small_class_heap_budget_bytes = DEFAULT_SMALL_CLASS_HEAP_BUDGET;

    // Cell-size cap that defines "small" for budgeting; allocations larger than this are not budgeted.
    size_t small_class_cell_max_bytes = LARGE_OBJECT_THRESHOLD;

    // ---- Old-gen sweep & mark pacing ----

    // Bytes of lazy-sweep work the allocator does per slow-path invocation.
    size_t sweep_work_budget = SWEEP_WORK_BUDGET;

    // Bytes of sweep work finishMarkAndSweep runs synchronously before returning.
    size_t initial_sweep_budget = INITIAL_SWEEP_BUDGET;

    // Incremental marking work ratio: bytes marked per byte allocated during the marking phase.
    size_t mark_work_ratio = MARK_WORK_RATIO;

    // Base proportionality factor for the per-allocation sweep budget (bytes swept per byte requested).
    double sweep_bytes_per_alloc_byte = SWEEP_BYTES_PER_ALLOC_BYTE;

    // Soft cap on the per-allocation sweep budget BEFORE pressure scaling.
    size_t max_sweep_bytes_per_alloc = MAX_SWEEP_BYTES_PER_ALLOC;

    // Hard cap applied AFTER pressure scaling and unswept-ratio boost.
    size_t max_sweep_bytes_hard = MAX_SWEEP_BYTES_HARD;

    // Pressure thresholds on committed/cap ratio (must satisfy 0 < low < medium < high < 1).
    double sweep_cap_ratio_low    = SWEEP_CAP_RATIO_LOW;
    double sweep_cap_ratio_medium = SWEEP_CAP_RATIO_MEDIUM;
    double sweep_cap_ratio_high   = SWEEP_CAP_RATIO_HIGH;

    // Per-allocation sweep-budget multipliers per pressure step (must be non-decreasing and >= 1.0).
    double sweep_scale_low    = SWEEP_SCALE_LOW;
    double sweep_scale_medium = SWEEP_SCALE_MEDIUM;
    double sweep_scale_high   = SWEEP_SCALE_HIGH;
    double sweep_scale_crit   = SWEEP_SCALE_CRIT;

    // Unswept-block fraction above which the per-allocation sweep budget gets a sweep_unswept_scale boost.
    double sweep_unswept_ratio_boost = SWEEP_UNSWEPT_RATIO_BOOST;

    // Multiplier applied on top of pressure scaling when the unswept-block fraction exceeds the boost threshold.
    double sweep_unswept_scale = SWEEP_UNSWEPT_SCALE;

    // Per-slice budget for the panic-path sweeper.
    size_t panic_sweep_slice_bytes = PANIC_SWEEP_SLICE_BYTES;

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

        if (nursery_max_block_count == 0) {
            throw std::invalid_argument("nursery_max_block_count must be > 0");
        }

        if (nursery_max_block_count % 2 != 0) {
            throw std::invalid_argument(
                "nursery_max_block_count must be even (split into from-space and to-space)");
        }

        if (nursery_block_count > nursery_max_block_count) {
            throw std::invalid_argument(
                "nursery_block_count must be <= nursery_max_block_count "
                "(initial size cannot exceed the adaptive-growth cap)");
        }

        // ========== 4. AllocBuffer Constraints ==========

        // Lower bound is the OS page size: mmap(MAP_FIXED) operates in
        // page-sized units, so a sub-page BBoP would either fail to map
        // exactly the requested extent or leave the bump pointer mis-aligned
        // for the next acquire. 4 KiB on Linux / Darwin x86-64; 16 KiB on
        // Darwin arm64 (Apple Silicon).
        constexpr size_t MIN_BUFFER_SIZE = OS_PAGE_SIZE;
        if (alloc_buffer_size < MIN_BUFFER_SIZE) {
            throw std::invalid_argument(
                "alloc_buffer_size must be >= the OS page size "
                "(4 KiB on x86-64, 16 KiB on Apple Silicon)");
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

        if (major_gc_garbage_fraction < 0.0f ||
            major_gc_garbage_fraction >= 1.0f) {
            throw std::invalid_argument(
                "major_gc_garbage_fraction must be in [0.0, 1.0)");
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

        // ========== 8. Old-gen Sweep & Mark Pacing ==========

        if (sweep_work_budget == 0) {
            throw std::invalid_argument("sweep_work_budget must be > 0");
        }
        if (initial_sweep_budget < sweep_work_budget) {
            throw std::invalid_argument(
                "initial_sweep_budget must be >= sweep_work_budget "
                "(at least one slice per startup pass)");
        }
        if (mark_work_ratio < 1) {
            throw std::invalid_argument("mark_work_ratio must be >= 1");
        }
        if (sweep_bytes_per_alloc_byte <= 0.0) {
            throw std::invalid_argument(
                "sweep_bytes_per_alloc_byte must be > 0.0");
        }
        if (max_sweep_bytes_per_alloc < sweep_work_budget) {
            throw std::invalid_argument(
                "max_sweep_bytes_per_alloc must be >= sweep_work_budget "
                "(soft cap below one slice would degenerate)");
        }
        if (max_sweep_bytes_hard < max_sweep_bytes_per_alloc) {
            throw std::invalid_argument(
                "max_sweep_bytes_hard must be >= max_sweep_bytes_per_alloc "
                "(hard cap is applied AFTER pressure scaling)");
        }
        if (panic_sweep_slice_bytes < sweep_work_budget) {
            throw std::invalid_argument(
                "panic_sweep_slice_bytes must be >= sweep_work_budget");
        }

        // Pressure thresholds: 0 < low < medium < high < 1.
        if (sweep_cap_ratio_low <= 0.0 || sweep_cap_ratio_high >= 1.0) {
            throw std::invalid_argument(
                "sweep_cap_ratio_{low,high} must lie in (0.0, 1.0)");
        }
        if (!(sweep_cap_ratio_low < sweep_cap_ratio_medium &&
              sweep_cap_ratio_medium < sweep_cap_ratio_high)) {
            throw std::invalid_argument(
                "sweep_cap_ratio_low < sweep_cap_ratio_medium < "
                "sweep_cap_ratio_high required");
        }

        // Pressure scales: non-decreasing and >= 1.0.
        if (sweep_scale_low < 1.0) {
            throw std::invalid_argument("sweep_scale_low must be >= 1.0");
        }
        if (!(sweep_scale_low <= sweep_scale_medium &&
              sweep_scale_medium <= sweep_scale_high &&
              sweep_scale_high <= sweep_scale_crit)) {
            throw std::invalid_argument(
                "sweep_scale_{low,medium,high,crit} must be non-decreasing");
        }

        // Unswept boost: ratio in (0, 1), scale >= 1.0.
        if (sweep_unswept_ratio_boost <= 0.0 ||
            sweep_unswept_ratio_boost >= 1.0) {
            throw std::invalid_argument(
                "sweep_unswept_ratio_boost must be in (0.0, 1.0)");
        }
        if (sweep_unswept_scale < 1.0) {
            throw std::invalid_argument(
                "sweep_unswept_scale must be >= 1.0 (scale never shrinks the budget)");
        }
    }
};

} // namespace Elm

#endif // ECO_ALLOCATOR_COMMON_H
