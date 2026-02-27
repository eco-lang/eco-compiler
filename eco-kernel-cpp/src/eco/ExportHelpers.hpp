//===- ExportHelpers.hpp - Helpers for Eco kernel export functions ---------===//
//
// Helper functions for converting between HPointer and uint64_t in the
// Eco kernel export layer. Mirrors elm-kernel-cpp/src/ExportHelpers.hpp.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_KERNEL_EXPORT_HELPERS_H
#define ECO_KERNEL_EXPORT_HELPERS_H

#include "allocator/Heap.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/HeapHelpers.hpp"
#include <cstdint>

namespace Eco::Kernel::Export {

using Elm::HPointer;
using Elm::Allocator;

// Encode HPointer as uint64_t for JIT interface.
inline uint64_t encode(HPointer h) {
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

    if (h.constant >= 1 && h.constant <= 7) {
        return nullptr;
    }

    if (h.constant != 0) {
        return reinterpret_cast<void*>(val);
    }

    if (h.padding != 0) {
        return reinterpret_cast<void*>(val);
    }

    return Allocator::instance().resolve(h);
}

// Encode a raw pointer as uint64_t.
inline uint64_t fromPtr(void* ptr) {
    HPointer h = Allocator::instance().wrap(ptr);
    return encode(h);
}

// Encode a boolean as a boxed !eco.value (HPointer constant).
inline uint64_t encodeBoxedBool(bool b) {
    return encode(b ? Elm::alloc::elmTrue() : Elm::alloc::elmFalse());
}

// Decode a boxed !eco.value boolean (HPointer constant) to raw bool.
inline bool decodeBoxedBool(uint64_t val) {
    HPointer h = decode(val);
    return h.constant == (Elm::Const_True + 1);
}

// Encode Unit as a boxed HPointer constant.
inline uint64_t encodeUnit() {
    return encode(Elm::alloc::unit());
}

} // namespace Eco::Kernel::Export

#endif // ECO_KERNEL_EXPORT_HELPERS_H
