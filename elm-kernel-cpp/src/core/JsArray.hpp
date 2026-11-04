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
// `KernelExports.h`. This header declares only `initializeFromList`, which both forms of
// `JsArray.initializeFromList` (boxed `max` and raw `int64_t` `max`) share.

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"

namespace Elm::Kernel::JsArray {

/// Builds an array from the first `max` elements of `list`, and returns the pair (array, rest of the
/// list). The rest is the list after those elements, `[]` if `list` had no more than `max`.
///
/// The array has room for `max` elements whatever the length of `list`. It takes the slot kind of the
/// list's first element, or is boxed if it takes none; later elements are assumed to have the same kind,
/// unchecked. `list` must be current on entry. Allocates, so it is a GC point.
HPointer initializeFromList(u32 max, HPointer list);

} // namespace Elm::Kernel::JsArray

#endif // ECO_JSARRAY_HPP
