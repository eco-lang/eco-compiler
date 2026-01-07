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

// ----- Heap Sizing -----
constexpr size_t DEFAULT_MAX_HEAP_SIZE = 1ULL * 1024 * 1024 * 1024;  // 1 GB address space.
constexpr size_t INITIAL_OLD_GEN_SIZE = 1 * 1024 * 1024;             // 1 MB initial commit.

// ----- AllocBuffer Sizing -----
constexpr size_t ALLOC_BUFFER_SIZE = 128 * 1024;  // 128 KB default AllocBuffer.

// ----- Nursery Sizing -----
// Nursery is composed of blocks (same size as AllocBuffer).
// Block count must be even (split into from-space and to-space).
constexpr size_t NURSERY_BLOCK_COUNT = 32;  // 32 blocks = 4 MB total (16 per semi-space).

// ----- Promotion & GC Triggers -----
constexpr u32 PROMOTION_AGE = 1;                            // Promote objects after surviving 1 minor GC.
constexpr float NURSERY_GC_THRESHOLD = 0.9f;                // Trigger minor GC when 90% full.

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
        case Tag_ByteBuffer:
            // header.size = byte count
            size = sizeof(ByteBuffer) + hdr->size * sizeof(u8);
            break;
        case Tag_Array: {
            // For arrays, we copy based on length (used elements), not capacity
            // header.size = capacity, but we use the actual length field for sizing
            ElmArray *arr = static_cast<ElmArray *>(obj);
            size = sizeof(ElmArray) + arr->length * sizeof(Unboxable);
            break;
        }
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

    // List locality optimization: two-pass spine copying.
    // When enabled, Cons list spines are copied contiguously using a two-pass
    // algorithm (pass 1: copy tail chain, pass 2: evacuate heads), which
    // provides better cache locality when traversing lists later.
    // All other types use standard Cheney's BFS evacuation.
    bool use_hybrid_dfs = true;

    // Derived value: total nursery size in bytes.
    size_t nurserySize() const { return nursery_block_count * alloc_buffer_size; }

    // Default constructor using in-class member initializers.
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
    }
};

} // namespace Elm

#endif // ECO_ALLOCATOR_COMMON_H
