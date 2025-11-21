#ifndef ECO_ALLOCATOR_COMMON_H
#define ECO_ALLOCATOR_COMMON_H

#include <cstddef>
#include <cstdint>
#include "Heap.hpp"

namespace Elm {

// Forward declarations
class GarbageCollector;

// GC Color states for tri-color marking
enum class Color : u32 {
    White = 0, // Not marked (garbage)
    Grey = 1, // Marked but children not scanned
    Black = 2 // Marked and children scanned
};

// Maximum age before promotion to old gen
constexpr u32 PROMOTION_AGE = 1;

// Nursery size per thread (e.g., 4MB)
constexpr size_t NURSERY_SIZE = 4 * 1024 * 1024;

// Helper functions for heap operations
inline Header *getHeader(void *obj) { return static_cast<Header *>(obj); }

// Forward declarations for functions that need GarbageCollector
// (implementations are in GarbageCollector.hpp after class definition)
void *fromPointer(HPointer ptr);
HPointer toPointer(void *obj);

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

    // Always return 8-byte aligned size
    return (size + 7) & ~7;
}

} // namespace Elm

#endif // ECO_ALLOCATOR_COMMON_H
