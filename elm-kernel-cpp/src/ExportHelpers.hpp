//===- ExportHelpers.hpp - Helpers for kernel export functions ------------===//
//
// The kernel exports receive and return Elm values as 64-bit words, and this header converts between
// such a word and the runtime's `HPointer`, the address of the object it refers to, and a C++ `bool`.
//
// The word layout, the embedded constants and how a word resolves to an object are defined by `HPointer`
// and `Allocator` in the runtime. An embedded constant is a word with `ptr_ind` set that refers to no
// heap object: False, True, Empty (Unit, Nil, Nothing, the empty String and others) and the nullary
// constructors. The facts this header adds are how `toPtr` treats a word, and that Bool crosses the ABI as
// the False or True constant, not as a raw 0 or 1.
//
//===----------------------------------------------------------------------===//

#ifndef ELM_KERNEL_EXPORT_HELPERS_H
#define ELM_KERNEL_EXPORT_HELPERS_H

#include "allocator/Heap.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/HeapHelpers.hpp"
#include <cstdint>

namespace Elm::Kernel::Export {

/// Returns the word whose bits are those of `h`.
inline uint64_t encode(HPointer h) {
    // A union reinterprets the bits; `HPointer` is exactly 64 bits.
    union { HPointer hp; uint64_t val; } u;
    u.hp = h;
    return u.val;
}

/// Returns the `HPointer` whose bits are those of `val`; the inverse of `encode`.
inline HPointer decode(uint64_t val) {
    union { HPointer hp; uint64_t val; } u;
    u.val = val;
    return u.hp;
}

/// Returns the address of the object the word `val` refers to, or a null pointer if it refers to none.
///
/// An embedded constant (`ptr_ind` set, `ptr` and `padding` zero) gives a null pointer, so a kernel
/// that receives Empty sees null; so does the zero word. A word that lies inside the reserved heap range
/// is a heap `HPointer`, whose word is the object's address, and is resolved with
/// `Allocator::resolveFast`, which follows a forwarding header. Any other word, such as one referring to
/// an interned literal in `PermanentSpace`, which is outside the heap range, is returned as the address
/// it already is.
///
/// The result is a bare address and roots nothing. A heap object may move at a collection, after which
/// the address must be obtained again.
inline void* toPtr(uint64_t val) {
    HPointer h = decode(val);

    // A real pointer is 8-byte aligned, so its ptr_ind bit is clear; the `ptr` and `padding` tests keep a
    // malformed word with `ptr_ind` set and other bits set from being taken for a constant.
    if (h.ptr_ind != 0 && h.ptr == 0 && h.padding == 0) {
        return nullptr;
    }

    void* raw = reinterpret_cast<void*>(val);

    if (Allocator::instance().isInHeap(raw)) {
        return Allocator::resolveFast(h);
    }
    return raw;
}

/// Returns the word for the object at `ptr`.
///
/// `ptr` must be the address of an object in the heap or in `PermanentSpace`, as `Allocator::wrap`
/// requires.
inline uint64_t fromPtr(void* ptr) {
    HPointer h = Allocator::instance().wrap(ptr);
    return encode(h);
}

/// Returns the word for the Elm Bool `b`: the True or the False constant.
///
/// This is the form a Bool takes at the ABI boundary.
inline uint64_t encodeBoxedBool(bool b) {
    return encode(b ? alloc::elmTrue() : alloc::elmFalse());
}

/// Returns the Bool the word `val` holds, read from bit 0 of the word.
///
/// `val` must be the True or the False constant; for any other word the result means nothing.
inline bool decodeBoxedBool(uint64_t val) {
    return Elm::boolValueBits(val) != 0;
}

/// Returns `b` as a raw 0 or 1.
///
/// This is not the ABI form of a Bool. DEPRECATED: use `encodeBoxedBool` at ABI boundaries.
inline int64_t encodeBool(bool b) {
    return b ? 1 : 0;
}

/// Returns whether the raw integer `val` is non-zero.
///
/// This reads a raw 0 or 1 as `encodeBool` produces, not the ABI form of a Bool, for which
/// `decodeBoxedBool` is used.
inline bool decodeBool(int64_t val) {
    return val != 0;
}

} // namespace Elm::Kernel::Export

#endif // ELM_KERNEL_EXPORT_HELPERS_H
