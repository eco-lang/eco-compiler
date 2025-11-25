/**
 * Common Definitions for Garbage Collector Components.
 *
 * This file contains shared constants, types, and utilities used across
 * the GC subsystem (NurserySpace, OldGenSpace, GarbageCollector).
 *
 * Key contents:
 *   - Sizing constants: Heap size, nursery size, TLAB size, block size.
 *   - Color enum: Tri-color marking states (White, Grey, Black).
 *   - Utility functions: getHeader(), getObjectSize(), pointer conversion.
 */

#ifndef ECO_ALLOCATOR_COMMON_H
#define ECO_ALLOCATOR_COMMON_H

#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include "Heap.hpp"

namespace Elm {

class GarbageCollector;

// Tri-color marking states for concurrent GC.
enum class Color : u32 {
    White = 0,   // Not yet marked (potential garbage).
    Grey = 1,    // Marked but children not yet scanned.
    Black = 2    // Marked and all children scanned.
};

// ============================================================================
// GC Sizing Constants
// ============================================================================

// ----- Heap Sizing -----
constexpr size_t DEFAULT_MAX_HEAP_SIZE = 1ULL * 1024 * 1024 * 1024;  // 1 GB address space.
constexpr size_t INITIAL_OLD_GEN_SIZE = 1 * 1024 * 1024;             // 1 MB initial commit.
constexpr size_t MIN_OLD_GEN_CHUNK_SIZE = 1 * 1024 * 1024;           // 1 MB minimum growth.

// ----- Nursery Sizing -----
constexpr size_t NURSERY_SIZE = 4 * 1024 * 1024;  // 4 MB total (2 MB per semi-space).

// ----- TLAB Sizing -----
constexpr size_t TLAB_DEFAULT_SIZE = 128 * 1024;  // 128 KB default TLAB.
constexpr size_t TLAB_MIN_SIZE = 64 * 1024;       // 64 KB minimum TLAB.

// ----- Block Sizing (for compaction) -----
constexpr size_t BLOCK_SIZE = 256 * 1024;  // 256 KB blocks for compaction metadata.

// ----- Promotion & GC Triggers -----
constexpr u32 PROMOTION_AGE = 1;                            // Promote after 1 minor GC survival.
constexpr float NURSERY_GC_THRESHOLD = 0.9f;                // Trigger minor GC at 90% full.

// ----- Compaction Thresholds -----
constexpr double EVACUATION_THRESHOLD = 0.25;       // Evacuate blocks below 25% occupancy.
constexpr double EVACUATION_DEST_THRESHOLD = 0.75;  // Blocks below 75% can receive objects.
constexpr double MAX_EVACUATION_RATIO = 0.10;       // Evacuate at most 10% of heap per cycle.

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
        case Tag_Closure: {
            Closure *cl = static_cast<Closure *>(obj);
            size = sizeof(Closure) + cl->n_values * sizeof(Unboxable);
            break;
        }
        case Tag_Process:
            size = sizeof(Process);
            break;
        case Tag_Task:
            size = sizeof(Task);
            break;
        case Tag_Forward:
            size = sizeof(Forward);
            break;
        default:
            size = sizeof(Header);
            break;
    }

    // All heap objects are 8-byte aligned.
    return (size + 7) & ~7;
}

// ============================================================================
// GC Configuration
// ============================================================================

/**
 * Configuration for garbage collector parameters.
 *
 * All fields have sensible defaults from the constants above. Users can
 * override any field before passing to GarbageCollector::initialize().
 */
struct GCConfig {
    // Heap sizing
    size_t max_heap_size = DEFAULT_MAX_HEAP_SIZE;
    size_t initial_old_gen_size = INITIAL_OLD_GEN_SIZE;
    size_t min_old_gen_chunk_size = MIN_OLD_GEN_CHUNK_SIZE;

    // Nursery sizing
    size_t nursery_size = NURSERY_SIZE;

    // TLAB sizing
    size_t tlab_default_size = TLAB_DEFAULT_SIZE;
    size_t tlab_min_size = TLAB_MIN_SIZE;

    // Block sizing (for compaction)
    size_t block_size = BLOCK_SIZE;

    // Promotion & GC triggers
    u32 promotion_age = PROMOTION_AGE;
    float nursery_gc_threshold = NURSERY_GC_THRESHOLD;

    // Compaction thresholds
    double evacuation_threshold = EVACUATION_THRESHOLD;
    double evacuation_dest_threshold = EVACUATION_DEST_THRESHOLD;
    double max_evacuation_ratio = MAX_EVACUATION_RATIO;

    // Default constructor using in-class member initializers.
    GCConfig() = default;

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

        if (min_old_gen_chunk_size == 0) {
            throw std::invalid_argument("min_old_gen_chunk_size must be > 0");
        }

        if (nursery_size == 0) {
            throw std::invalid_argument("nursery_size must be > 0");
        }

        if (tlab_default_size == 0) {
            throw std::invalid_argument("tlab_default_size must be > 0");
        }

        if (tlab_min_size == 0) {
            throw std::invalid_argument("tlab_min_size must be > 0");
        }

        if (block_size == 0) {
            throw std::invalid_argument("block_size must be > 0");
        }

        // ========== 2. Heap Partitioning Constraints ==========
        // Heap is split: [0, max/2) = old gen, [max/2, max) = nurseries

        size_t old_gen_space = max_heap_size / 2;

        if (initial_old_gen_size >= old_gen_space) {
            throw std::invalid_argument(
                "initial_old_gen_size must be < max_heap_size / 2 "
                "(old gen lives in first half of heap)");
        }

        if (min_old_gen_chunk_size > old_gen_space) {
            throw std::invalid_argument(
                "min_old_gen_chunk_size must be <= max_heap_size / 2 "
                "(chunk can't exceed old gen space)");
        }

        if (nursery_size >= old_gen_space) {
            throw std::invalid_argument(
                "nursery_size must be < max_heap_size / 2 "
                "(nurseries live in second half of heap)");
        }

        // ========== 3. Nursery Constraints ==========
        // Nursery is split into two semi-spaces.

        if (nursery_size % 2 != 0) {
            throw std::invalid_argument(
                "nursery_size must be even (split into two semi-spaces)");
        }

        if (nursery_size < 64 * 1024) {
            throw std::invalid_argument(
                "nursery_size must be >= 64KB (32KB per semi-space minimum)");
        }

        // ========== 4. TLAB Constraints ==========

        if (tlab_min_size > tlab_default_size) {
            throw std::invalid_argument(
                "tlab_min_size must be <= tlab_default_size");
        }

        // FreeBlock is 16 bytes (size_t + pointer)
        constexpr size_t MIN_TLAB_SIZE = 16;
        if (tlab_min_size < MIN_TLAB_SIZE) {
            throw std::invalid_argument(
                "tlab_min_size must be >= 16 bytes (sizeof(FreeBlock))");
        }

        if (tlab_default_size > old_gen_space) {
            throw std::invalid_argument(
                "tlab_default_size must be <= max_heap_size / 2 "
                "(can't exceed old gen space)");
        }

        // ========== 5. Block Size Constraints ==========

        constexpr size_t MIN_BLOCK_SIZE = 4096;  // 4KB
        if (block_size < MIN_BLOCK_SIZE) {
            throw std::invalid_argument(
                "block_size must be >= 4KB for meaningful compaction granularity");
        }

        if (block_size > old_gen_space / 4) {
            throw std::invalid_argument(
                "block_size must be <= max_heap_size / 8 "
                "(need at least 4 blocks in old gen)");
        }

        if (initial_old_gen_size < block_size) {
            throw std::invalid_argument(
                "initial_old_gen_size must be >= block_size "
                "(old gen should have at least one block)");
        }

        // ========== 6. Promotion Constraints ==========

        if (promotion_age < 1) {
            throw std::invalid_argument(
                "promotion_age must be >= 1 (must survive at least 1 GC)");
        }

        if (promotion_age > 15) {
            throw std::invalid_argument(
                "promotion_age must be <= 15 (header age field limit)");
        }

        // ========== 7. Threshold Constraints ==========

        if (nursery_gc_threshold <= 0.0f || nursery_gc_threshold > 1.0f) {
            throw std::invalid_argument(
                "nursery_gc_threshold must be in (0.0, 1.0]");
        }

        if (evacuation_threshold < 0.0 || evacuation_threshold > 1.0) {
            throw std::invalid_argument(
                "evacuation_threshold must be in [0.0, 1.0]");
        }

        if (evacuation_dest_threshold < 0.0 || evacuation_dest_threshold > 1.0) {
            throw std::invalid_argument(
                "evacuation_dest_threshold must be in [0.0, 1.0]");
        }

        if (max_evacuation_ratio < 0.0 || max_evacuation_ratio > 1.0) {
            throw std::invalid_argument(
                "max_evacuation_ratio must be in [0.0, 1.0]");
        }

        // Destination blocks must be less full than source blocks to allow evacuation.
        if (evacuation_dest_threshold < evacuation_threshold) {
            throw std::invalid_argument(
                "evacuation_dest_threshold must be >= evacuation_threshold "
                "(destination blocks must be less full than evacuation sources)");
        }
    }
};

} // namespace Elm

#endif // ECO_ALLOCATOR_COMMON_H
