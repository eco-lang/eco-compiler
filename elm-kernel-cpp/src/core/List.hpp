#ifndef ECO_LIST_HPP
#define ECO_LIST_HPP

/**
 * Elm Kernel List Module - Runtime Heap Integration
 *
 * This module provides list operations that work with the GC-managed heap.
 * All lists are represented as HPointer to Cons cells on the heap, with
 * Nil represented by the embedded Const_Nil constant.
 *
 * Functions delegate to ListOps helpers from the runtime allocator.
 */

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"

namespace Elm::Kernel::List {

// ============================================================================
// Construction
// ============================================================================

/**
 * Creates a Cons cell: head :: tail
 * The head can be boxed (pointer) or unboxed (primitive).
 */
HPointer cons(Unboxable head, HPointer tail, bool headIsBoxed);

/**
 * Converts a vector of HPointers to a list.
 */
HPointer fromArray(const std::vector<HPointer>& array);

// ============================================================================
// Sorting
// ============================================================================

/**
 * Sorts by applying a key function to each element.
 * keyFunc takes an element (void*) and returns a comparable value (HPointer).
 */
using KeyFunc = HPointer (*)(void*);
HPointer sortBy(KeyFunc keyFunc, HPointer list);

/**
 * Sorts using a custom comparison function.
 * cmpFunc takes two elements (void*, void*) and returns Order (LT=-1, EQ=0, GT=1).
 */
using CmpFunc = i64 (*)(void*, void*);
HPointer sortWith(CmpFunc cmpFunc, HPointer list);

} // namespace Elm::Kernel::List

#endif // ECO_LIST_HPP
