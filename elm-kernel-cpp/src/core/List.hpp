#ifndef ELM_KERNEL_LIST_HPP
#define ELM_KERNEL_LIST_HPP

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
 * Returns the empty list (Nil).
 */
HPointer Nil();

/**
 * Creates a Cons cell: head :: tail
 * The head can be boxed (pointer) or unboxed (primitive).
 */
HPointer Cons(Unboxable head, HPointer tail, bool headIsBoxed);

/**
 * Convenience: Cons with a boxed HPointer head.
 */
HPointer ConsBoxed(HPointer head, HPointer tail);

/**
 * Converts a vector of HPointers to a list.
 */
HPointer fromArray(const std::vector<HPointer>& array);

/**
 * Converts a list to a vector of HPointers.
 */
std::vector<HPointer> toArray(HPointer list);

// ============================================================================
// Basic Operations
// ============================================================================

/**
 * Checks if the list is empty (Nil).
 */
bool isEmpty(HPointer list);

/**
 * Returns the length of the list.
 */
i64 length(HPointer list);

/**
 * Returns the head of the list, or Nothing if empty.
 */
HPointer head(HPointer list);

/**
 * Returns the tail of the list, or Nothing if empty.
 */
HPointer tail(HPointer list);

// ============================================================================
// Map Operations (multiple lists)
// ============================================================================

/**
 * Zips two lists into a list of Tuple2.
 * Stops when the shorter list ends.
 */
HPointer map2(HPointer xs, HPointer ys);

/**
 * Zips three lists into a list of Tuple3.
 * Stops when the shortest list ends.
 */
HPointer map3(HPointer xs, HPointer ys, HPointer zs);

// ============================================================================
// Transformation
// ============================================================================

/**
 * Reverses a list.
 */
HPointer reverse(HPointer list);

/**
 * Appends two lists: xs ++ ys
 */
HPointer append(HPointer xs, HPointer ys);

/**
 * Concatenates a list of lists into a single list.
 */
HPointer concat(HPointer listOfLists);

/**
 * Takes the first n elements.
 */
HPointer take(i64 n, HPointer list);

/**
 * Drops the first n elements.
 */
HPointer drop(i64 n, HPointer list);

// ============================================================================
// Sorting
// ============================================================================

/**
 * Sorts a list of comparable values (ints, floats, strings).
 */
HPointer sort(HPointer list);

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

// ============================================================================
// Folding
// ============================================================================

/**
 * Sum of a list of integers.
 */
i64 sum(HPointer list);

/**
 * Product of a list of integers.
 */
i64 product(HPointer list);

/**
 * Maximum of a list. Returns Nothing for empty list.
 */
HPointer maximum(HPointer list);

/**
 * Minimum of a list. Returns Nothing for empty list.
 */
HPointer minimum(HPointer list);

// ============================================================================
// Membership
// ============================================================================

/**
 * Checks if an element is in the list.
 * Uses structural equality.
 */
bool member(HPointer element, HPointer list);

// ============================================================================
// Range
// ============================================================================

/**
 * Creates a list from low to high (inclusive).
 */
HPointer range(i64 low, i64 high);

/**
 * Repeats a value n times.
 */
HPointer repeat(i64 n, HPointer value);

} // namespace Elm::Kernel::List

#endif // ELM_KERNEL_LIST_HPP
