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
#include <cstdint>
#include <cstdio>

namespace Elm::Kernel::Export {

// Encode HPointer as uint64_t for JIT interface.
// HPointer layout: [ptr:40 | constant:4 | padding:20]
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

    // Check if this looks like an embedded constant.
    // Valid embedded constants have constant field values 1-7.
    // (0 = regular pointer, 1-7 = Unit/EmptyRec/True/False/Nil/Nothing/EmptyString)
    // Values outside this range (like 15) indicate this is actually a raw pointer
    // whose address bits 40-43 happen to be set.
    if (h.constant >= 1 && h.constant <= 7) {
        // This is a valid embedded constant - return nullptr
        return nullptr;
    }

    // If constant is non-zero but outside the valid constant range (1-7),
    // this is a raw pointer address that happens to have high bits set.
    // Treat it as a raw pointer.
    if (h.constant != 0) {
        return reinterpret_cast<void*>(val);
    }

    // constant == 0: This could be either:
    // 1. A valid HPointer (heap offset)
    // 2. A raw pointer that happens to have bits 40-43 all zero
    //
    // Detection strategy: Check the padding field (bits 44-63).
    // For valid HPointers, padding must be 0.
    // For raw x86-64 pointers (e.g., 0x7f38835ba0e0), bits 44+ will be non-zero.

    if (h.padding != 0) {
        // Padding bits set - this is a raw pointer
        return reinterpret_cast<void*>(val);
    }

    // padding == 0 and constant == 0: This is a valid HPointer
    // Use resolve() to properly handle HPointer decoding and forwarding.
    return Allocator::instance().resolve(h);
}

// Encode a raw pointer as uint64_t (assumes it's a valid heap address).
// Uses Allocator::wrap() to properly convert actual heap address to logical pointer.
inline uint64_t fromPtr(void* ptr) {
    HPointer h = Allocator::instance().wrap(ptr);
    return encode(h);
}

// Encode a boolean as int64_t for the JIT interface.
inline int64_t encodeBool(bool b) {
    return b ? 1 : 0;
}

// Decode int64_t to boolean.
inline bool decodeBool(int64_t val) {
    return val != 0;
}

} // namespace Elm::Kernel::Export

#endif // ELM_KERNEL_EXPORT_HELPERS_H
