#ifndef ELM_KERNEL_JSARRAY_HPP
#define ELM_KERNEL_JSARRAY_HPP

/**
 * Elm Kernel JsArray Module - Runtime Heap Integration
 *
 * This module provides array operations that work with the GC-managed heap.
 * Arrays are represented as HPointer to ElmArray objects on the heap.
 *
 * ElmArray is a mutable/growable array used internally by Elm's Array type.
 * Elm's Array uses a relaxed radix balanced tree (RRB tree) structure,
 * and JsArray provides the leaf node operations.
 *
 * IMPORTANT: Most operations create NEW arrays (immutable semantics)
 * rather than mutating in place, except for arrayPush on arrays with capacity.
 */

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"

namespace Elm::Kernel::JsArray {

// ============================================================================
// Construction
// ============================================================================

/**
 * Creates an empty array with default capacity.
 */
HPointer empty();

/**
 * Creates an array with a single element.
 */
HPointer singleton(HPointer value);

/**
 * Creates an array with specified initial capacity.
 */
HPointer withCapacity(u32 capacity);

// ============================================================================
// Length and Capacity
// ============================================================================

/**
 * Returns the number of elements in the array.
 */
u32 length(void* array);

/**
 * Returns the allocated capacity of the array.
 */
u32 capacity(void* array);

// ============================================================================
// Initialization
// ============================================================================

/**
 * Initializer function type: takes index, returns value.
 */
using InitFunc = HPointer (*)(u32);

/**
 * Creates an array of given size, initializing each element with func(offset + i).
 */
HPointer initialize(u32 size, u32 offset, InitFunc func);

/**
 * Creates an array from up to max elements of a list.
 * Returns Tuple2(array, remaining_list).
 */
HPointer initializeFromList(u32 max, HPointer list);

// ============================================================================
// Element Access
// ============================================================================

/**
 * Gets the element at index (no bounds check).
 * Returns the unboxable value - caller must check isUnboxed to interpret.
 */
Unboxable unsafeGet(u32 index, void* array);

/**
 * Gets the element as an HPointer (boxing if needed).
 */
HPointer get(u32 index, void* array);

/**
 * Sets the element at index, returning a new array (immutable).
 */
HPointer unsafeSet(u32 index, HPointer value, void* array);

// ============================================================================
// Modification
// ============================================================================

/**
 * Appends a value to the array, returning a new array.
 * If the array has spare capacity, may reuse storage.
 */
HPointer push(HPointer value, void* array);

// ============================================================================
// Folding
// ============================================================================

/**
 * Fold function type: (element, accumulator) -> new_accumulator
 */
using FoldFunc = HPointer (*)(void*, void*);

/**
 * Folds left over the array: foldl f acc [a,b,c] = f(c, f(b, f(a, acc)))
 */
HPointer foldl(FoldFunc func, HPointer acc, void* array);

/**
 * Folds right over the array: foldr f acc [a,b,c] = f(a, f(b, f(c, acc)))
 */
HPointer foldr(FoldFunc func, HPointer acc, void* array);

// ============================================================================
// Mapping
// ============================================================================

/**
 * Map function type: element -> new_element
 */
using MapFunc = HPointer (*)(void*);

/**
 * Maps a function over each element, producing a new array.
 */
HPointer map(MapFunc func, void* array);

/**
 * Indexed map function type: (index, element) -> new_element
 */
using IndexedMapFunc = HPointer (*)(u32, void*);

/**
 * Maps a function over each element with its index.
 * Index is offset + actual_index.
 */
HPointer indexedMap(IndexedMapFunc func, u32 offset, void* array);

// ============================================================================
// Slicing
// ============================================================================

/**
 * Extracts a slice from start (inclusive) to end (exclusive).
 * Negative indices count from end.
 */
HPointer slice(i64 start, i64 end, void* array);

/**
 * Appends up to n elements from source to dest, returning new array.
 * Copies min(n - dest.length, source.length) elements from source.
 */
HPointer appendN(u32 n, void* dest, void* source);

} // namespace Elm::Kernel::JsArray

#endif // ELM_KERNEL_JSARRAY_HPP
