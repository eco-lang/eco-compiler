#ifndef ECO_LIST_HPP
#define ECO_LIST_HPP

// A small C++ surface over Elm lists on the GC heap, for kernel code that builds or sorts a list.
//
// An Elm list is an HPointer to its first spine node, or the embedded Nil constant (`alloc::listNil()`)
// for `[]`. A spine node is a cons cell, holding one element and the rest of the list, or a chunk view,
// holding a run of elements stored in a backing; the runtime's `alloc::cons` and chunked-list builders in
// `allocator/HeapHelpers.hpp` define both. An element ("head") is stored boxed, as an HPointer, or
// unboxed, as a raw Int, Float or Char, and its node records which: the slot kind.
//
// `cons` is the one function here that kernel code calls: the `List` exports use it. `fromArray`,
// `sortBy` and `sortWith` are compiled but have no callers; the `List.sortBy` and `List.sortWith`
// exports sort by their own code, so none of the three gives the behaviour of the Elm functions of the
// same name.
//
// Every function here may allocate and is a GC point: any raw pointer or unrooted HPointer held across a
// call may be stale afterwards.

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"

namespace Elm::Kernel::List {

// ============================================================================
// Construction
// ============================================================================

/// Returns the list `head :: tail` as one new cons cell. The head is stored with slot kind boxed when
/// `headIsBoxed` is true and Int when it is false, so a Float or Char head is given the wrong kind.
HPointer cons(Unboxable head, HPointer tail, bool headIsBoxed);

/// Returns the list of the boxed values in `array`, first to last, or Nil when it is empty. Has no
/// callers.
HPointer fromArray(const std::vector<HPointer>& array);

// ============================================================================
// Sorting
// ============================================================================

/// A function from one list element to the key it is sorted by.
///
/// The argument is the address of the element as a boxed heap object, valid only until the next
/// allocation; a boxed element that is an embedded constant is resolved anyway, which
/// `Allocator::resolve` does not allow. The returned HPointer must refer to a heap object, which
/// `sortBy` reads as an `ElmInt` whatever it is. The function may allocate.
using KeyFunc = HPointer (*)(void*);
/// Returns the elements of `list` sorted in ascending order of the Int key `keyFunc` gives each. Has no
/// callers.
///
/// An unboxed element is boxed as an Int before `keyFunc` sees it, whatever its slot kind. The sort is
/// `ListOps::sortBy`'s, which is not stable.
HPointer sortBy(KeyFunc keyFunc, HPointer list);

/// A comparison of two list elements, given as the addresses of boxed heap objects that are valid only
/// until the next allocation; a boxed element that is an embedded constant is resolved anyway, which
/// `Allocator::resolve` does not allow.
///
/// It returns a negative number when the first sorts before the second, zero when they are equal and a
/// positive number otherwise, and must be a strict weak ordering. `sortWith` narrows the result to `int`,
/// so it must fit in one. It may allocate.
using CmpFunc = i64 (*)(void*, void*);
/// Returns the elements of `list` sorted in the order `cmpFunc` defines. Has no callers.
///
/// An unboxed element is boxed at the slot kind of the first node of `list` before `cmpFunc` sees it,
/// which gives the right value only when every element has that kind. When the first node's slot is
/// boxed, an unboxed element is not boxed: its raw bits are resolved as an HPointer.
/// The sort is `ListOps::sortWith`'s, which is not stable.
HPointer sortWith(CmpFunc cmpFunc, HPointer list);

} // namespace Elm::Kernel::List

#endif // ECO_LIST_HPP
