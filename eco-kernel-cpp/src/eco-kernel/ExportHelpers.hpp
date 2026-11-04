//===- ExportHelpers.hpp - Helpers for Eco kernel export functions ---------===//
//
// The eco kernel export functions take and return Elm values as `uint64_t` words, and this header converts
// between those words and the runtime's `Elm::HPointer`.
//
// A word is the 64-bit image of an `HPointer` (layout owned by `allocator/Heap.hpp`). It is either a heap
// pointer, whose bits are the object's address, or an *embedded constant*: `ptr_ind` set and `ptr` and
// `padding` zero, such as False (0x4), True (0x5) and Empty (0x6), naming no heap object. Bool and Unit cross
// the boundary as these constant words, never as a C++ `bool`, and Unit never as an absent value.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_KERNEL_EXPORT_HELPERS_H
#define ECO_KERNEL_EXPORT_HELPERS_H

#include "allocator/Heap.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/HeapHelpers.hpp"
#include <cassert>
#include <cstdint>

namespace Eco::Kernel::Export {

using Elm::HPointer;
using Elm::Allocator;

/// Returns the 64-bit word of `h`, bit for bit. Does not allocate.
inline uint64_t encode(HPointer h) {
    union { HPointer hp; uint64_t val; } u;
    u.hp = h;
    return u.val;
}

/// Returns the `HPointer` whose bits are `val`; the inverse of `encode`. Does not allocate.
inline HPointer decode(uint64_t val) {
    union { HPointer hp; uint64_t val; } u;
    u.val = val;
    return u.hp;
}

/// Returns the address of the object the word `val` names, or null for an embedded constant. `val` must be an
/// embedded constant or the word of a heap or `PermanentSpace` object; the zero word is neither.
///
/// A non-constant `val` is resolved with `Allocator::resolveFast`, which follows a forwarding header. The
/// pointer is valid only until the next allocation, which can move the object. Under `ECO_HEAP_VALIDATE` a
/// non-constant word with any of `ptr_ind`, `null_cons_idx` or `padding` set fails an assertion.
inline void* toPtr(uint64_t val) {
    HPointer h = decode(val);
    // Embedded constant, including a null-cons word carrying its ctor index in null_cons_idx.
    if (h.ptr_ind != 0 && h.ptr == 0 && h.padding == 0) {
        return nullptr;
    }
#if ECO_HEAP_VALIDATE
    assert(h.ptr_ind == 0 && h.null_cons_idx == 0 && h.padding == 0 &&
           "Export::toPtr: not a heap pointer (ptr_ind/enum/padding bits set)");
#endif
    return Allocator::resolveFast(h);
}

/// Returns the word for the object at `ptr`. `ptr` must be the address of an object in the heap or in
/// `PermanentSpace`; `Allocator::wrap` asserts it.
inline uint64_t fromPtr(void* ptr) {
    HPointer h = Allocator::instance().wrap(ptr);
    return encode(h);
}

/// Returns the Elm Bool word for `b`: the True or False constant.
inline uint64_t encodeBoxedBool(bool b) {
    return encode(b ? Elm::alloc::elmTrue() : Elm::alloc::elmFalse());
}

/// Returns the C++ value of the Elm Bool word `val`, read from bit 0. Meaningful only for True or False.
inline bool decodeBoxedBool(uint64_t val) {
    return Elm::boolValueBits(val) != 0;
}

/// Returns the word for `()`, the Empty constant.
inline uint64_t encodeUnit() {
    return encode(Elm::alloc::unit());
}

} // namespace Eco::Kernel::Export

#endif // ECO_KERNEL_EXPORT_HELPERS_H
