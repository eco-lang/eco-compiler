#ifndef ECO_JSARRAY_HPP
#define ECO_JSARRAY_HPP

// The C++ side of elm/core's kernel module `JsArray`, the flat array that Elm's `Array` is built from.
//
// An Elm `Array` is a tree whose nodes and leaves are flat arrays. Here a flat array is the runtime's
// `ElmArray` heap object, and an operation that changes an array returns a new one and leaves its
// arguments as they were. All of an array's elements share one slot kind, recorded in the low two bits of the array's
// header `unboxed` field: 0 boxed (an HPointer per element), 1 raw Int, 2 raw Float, 3 raw Char. An
// element is read back according to that kind, so an operation that builds an array must set the kind
// its elements have.
//
// Almost all of the module is in `JsArrayExports.cpp`, as the C-linkage kernel entry points declared in
// `KernelExports.h`. This header declares only what that file shares with `JsArray.cpp`:
// `initializeFromList`, which every form of `JsArray.initializeFromList` shares, and `unboxByKind`.

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include <cassert>

namespace Elm::Kernel::JsArray {

/// The `wantedKind` that asks an array builder to keep the slot kinds its elements arrive in, instead
/// of storing every element in one kind fixed by the caller.
inline constexpr int kKeepElementKind = -1;

/// Returns the raw slot of kind `kind` (1 Int, 2 Float, 3 Char) that holds the value of the boxed
/// `ElmInt`, `ElmFloat` or `ElmChar` that `boxed` names. A Char slot is zero-extended (REP_HEAP_002).
/// `boxed` must name a heap object of that type, which is asserted. Does not allocate.
inline Unboxable unboxByKind(HPointer boxed, u32 kind) {
    void* obj = Allocator::instance().resolve(boxed);
    assert(obj && "unboxByKind: expected a boxed Int, Float or Char, got an embedded constant");
    Unboxable u;
    switch (kind) {
        case 1:
            assert(getHeader(obj)->tag == Tag_Int && "unboxByKind: Int slot wanted, element is not an Int");
            u.i = static_cast<ElmInt*>(obj)->value;
            return u;
        case 2:
            assert(getHeader(obj)->tag == Tag_Float && "unboxByKind: Float slot wanted, element is not a Float");
            u.f = static_cast<ElmFloat*>(obj)->value;
            return u;
        default:
            assert(kind == 3 && getHeader(obj)->tag == Tag_Char &&
                   "unboxByKind: Char slot wanted, element is not a Char");
            return alloc::unboxedChar(static_cast<ElmChar*>(obj)->value);
    }
}

/// Builds an array from the first `max` elements of `list`, and returns the pair (array, rest of the
/// list). The rest is the list after those elements, `[]` if `list` had no more than `max`.
///
/// The array has room for `max` elements whatever the length of `list`. With `wantedKind` 1, 2 or 3 (the
/// slot kind of the call site's element type, Int, Float or Char) every element is stored in that kind,
/// a boxed list head being unboxed. With `kKeepElementKind` the array takes the slot kind of the list's
/// first element, or is boxed if it takes none, and later elements are assumed to have the same kind,
/// unchecked. `list` must be current on entry. Allocates, so it is a GC point.
HPointer initializeFromList(u32 max, HPointer list, int wantedKind = kKeepElementKind);

} // namespace Elm::Kernel::JsArray

#endif // ECO_JSARRAY_HPP
