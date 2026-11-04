#ifndef ECO_LIST_HPP
#define ECO_LIST_HPP

// A small C++ surface over Elm lists on the GC heap, for kernel code that builds a list.
//
// An Elm list is an HPointer to its first spine node, or the embedded Nil constant (`alloc::listNil()`)
// for `[]`. A spine node is a cons cell, holding one element and the rest of the list, or a chunk view,
// holding a run of elements stored in a backing; the runtime's `alloc::cons` and chunked-list builders in
// `allocator/HeapHelpers.hpp` define both. An element ("head") is stored boxed, as an HPointer, or
// unboxed, as a raw Int, Float or Char, and its node records which: the slot kind.
//
// `cons` is the one function here; the `List` exports use it.
//
// It allocates and is a GC point: any raw pointer or unrooted HPointer held across a call may be stale
// afterwards.

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"

namespace Elm::Kernel::List {

// ============================================================================
// Construction
// ============================================================================

/// Returns the list `head :: tail` as one new cons cell. The head is stored with slot kind boxed when
/// `headIsBoxed` is true and Int when it is false, so a Float or Char head would be given the wrong kind;
/// the one caller, the boxed `List.cons` export, passes only boxed heads (`true`).
HPointer cons(Unboxable head, HPointer tail, bool headIsBoxed);

} // namespace Elm::Kernel::List

#endif // ECO_LIST_HPP
