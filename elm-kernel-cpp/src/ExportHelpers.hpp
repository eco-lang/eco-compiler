//===- ExportHelpers.hpp - Helpers for kernel export functions ------------===//
//
// Helper functions for converting between HPointer and uint64_t in the
// kernel export layer.
//
//===----------------------------------------------------------------------===//

#ifndef ELM_KERNEL_EXPORT_HELPERS_H
#define ELM_KERNEL_EXPORT_HELPERS_H

#include "allocator/Heap.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/HeapHelpers.hpp"
#include <cstdint>
#include <cstdio>

namespace Elm::Kernel::Export {

// Encode HPointer as uint64_t for JIT interface.
// HPointer layout: [constant:2 | ptr_ind:1 | ptr:40 | enum_idx:10 | padding:11]
inline uint64_t encode(HPointer h) {
    // Use union for type-punning since HPointer is exactly 64 bits
    union { HPointer hp; uint64_t val; } u;
    u.hp = h;
    return u.val;
}

// Decode uint64_t back to HPointer.
inline HPointer decode(uint64_t val) {
    union { HPointer hp; uint64_t val; } u;
    u.val = val;
    return u.hp;
}

// Decode uint64_t to raw pointer (for accessing heap objects).
// Handles two cases:
// 1. HPointer (encoded heap offset): Uses Allocator::resolve() to convert.
// 2. Raw pointer (e.g., global string literals): Used directly.
//
// Detection strategy:
// - If constant field is set, it's an embedded constant - return nullptr.
// - Try interpreting as a raw pointer first. If it's in heap bounds, it could
//   be a raw pointer or an HPointer that happens to decode to an in-heap address.
// - If the raw value as a pointer is NOT in heap, use HPointer decoding.
// - This works because global string literals are in the data segment,
//   which is at a completely different address range than the mmap'd heap.
inline void* toPtr(uint64_t val) {
    HPointer h = decode(val);

    // Embedded constant (False 0x4 / True 0x5 / Empty 0x6): ptr_ind set with all
    // higher fields zero, so the word is a tiny value. A real pointer whose
    // address happens to have bit 2 set is NOT caught here because its ptr /
    // enum_idx / padding fields are non-zero. Constants resolve to no heap object.
    if (h.ptr_ind != 0 && h.ptr == 0 && h.enum_idx == 0 && h.padding == 0) {
        return nullptr;
    }

    void* raw = reinterpret_cast<void*>(val);

    // A heap HPointer's word IS its absolute in-heap address (plan D6), so if the
    // word lands inside the reserved heap range it is a heap reference — resolve()
    // handles forwarding. Otherwise it is a raw non-heap pointer (e.g. a global
    // string literal in the data segment) and is used directly.
    if (Allocator::instance().isInHeap(raw)) {
        return Allocator::instance().resolve(h);
    }
    return raw;
}

// Encode a raw pointer as uint64_t (assumes it's a valid heap address).
// Uses Allocator::wrap() to properly convert actual heap address to logical pointer.
inline uint64_t fromPtr(void* ptr) {
    HPointer h = Allocator::instance().wrap(ptr);
    return encode(h);
}

// Encode a boolean as a boxed !eco.value (HPointer constant) for ABI boundaries.
// Per REP_ABI_001, Bool at ABI boundaries must be boxed as True/False HPointer constants.
inline uint64_t encodeBoxedBool(bool b) {
    return encode(b ? alloc::elmTrue() : alloc::elmFalse());
}

// Decode a boxed !eco.value boolean (HPointer constant) to raw bool.
// Per REP_ABI_001, Bool at ABI boundaries is boxed as True/False HPointer
// constants (words 0x5/0x4); the i1 value is bit 0 of the word.
inline bool decodeBoxedBool(uint64_t val) {
    return Elm::boolValueBits(val) != 0;
}

// Legacy: Encode a boolean as int64_t (raw 0/1) for internal use.
// DEPRECATED: Use encodeBoxedBool for ABI boundaries.
inline int64_t encodeBool(bool b) {
    return b ? 1 : 0;
}

// Decode int64_t to boolean.
inline bool decodeBool(int64_t val) {
    return val != 0;
}

} // namespace Elm::Kernel::Export

#endif // ELM_KERNEL_EXPORT_HELPERS_H
