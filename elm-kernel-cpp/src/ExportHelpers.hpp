//===- ExportHelpers.hpp - Helpers for kernel export functions ------------===//
//
// Helper functions for converting between HPointer and uint64_t in the
// kernel export layer.
//
//===----------------------------------------------------------------------===//

#ifndef ELM_KERNEL_EXPORT_HELPERS_H
#define ELM_KERNEL_EXPORT_HELPERS_H

#include "allocator/Heap.hpp"
#include <cstdint>

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
inline void* toPtr(uint64_t val) {
    HPointer h = decode(val);
    // If it's a constant, return nullptr
    if (h.constant != 0) return nullptr;
    // Convert logical pointer to raw pointer via allocator
    return reinterpret_cast<void*>(h.ptr);
}

// Encode a raw pointer as uint64_t (assumes it's a valid heap address).
inline uint64_t fromPtr(void* ptr) {
    HPointer h;
    h.ptr = reinterpret_cast<uint64_t>(ptr);
    h.constant = 0;
    h.padding = 0;
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
