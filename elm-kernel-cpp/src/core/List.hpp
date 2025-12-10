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

/**
 * Converts a list to a vector of HPointers.
 */
std::vector<HPointer> toArray(HPointer list);

// ============================================================================
// Map Operations (multiple lists)
// These take a combining function as first argument.
// ============================================================================

/**
 * Function type for map2: (a, b) -> result
 */
using Map2Func = HPointer (*)(void*, void*);

/**
 * Combines two lists element-wise using a function.
 * Stops when the shorter list ends.
 */
HPointer map2(Map2Func func, HPointer xs, HPointer ys);

/**
 * Function type for map3: (a, b, c) -> result
 */
using Map3Func = HPointer (*)(void*, void*, void*);

/**
 * Combines three lists element-wise using a function.
 * Stops when the shortest list ends.
 */
HPointer map3(Map3Func func, HPointer xs, HPointer ys, HPointer zs);

/**
 * Function type for map4: (a, b, c, d) -> result
 */
using Map4Func = HPointer (*)(void*, void*, void*, void*);

/**
 * Combines four lists element-wise using a function.
 * Stops when the shortest list ends.
 */
HPointer map4(Map4Func func, HPointer ws, HPointer xs, HPointer ys, HPointer zs);

/**
 * Function type for map5: (a, b, c, d, e) -> result
 */
using Map5Func = HPointer (*)(void*, void*, void*, void*, void*);

/**
 * Combines five lists element-wise using a function.
 * Stops when the shortest list ends.
 */
HPointer map5(Map5Func func, HPointer vs, HPointer ws, HPointer xs, HPointer ys, HPointer zs);

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
