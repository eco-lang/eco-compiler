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

} // namespace Elm

#endif // ECO_ALLOCATOR_COMMON_H
