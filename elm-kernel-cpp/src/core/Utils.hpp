#ifndef ELM_KERNEL_UTILS_HPP
#define ELM_KERNEL_UTILS_HPP

/**
 * Elm Kernel Utils Module - Runtime Heap Integration
 *
 * This module provides core comparison, equality, and utility functions
 * that work with the GC-managed heap values.
 */

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"

namespace Elm::Kernel::Utils {

// ============================================================================
// Comparison Operations
// ============================================================================

/**
 * Low-level comparison returning -1 (LT), 0 (EQ), or 1 (GT).
 * Works on Int, Float, Char, String, Tuple, List.
 */
int cmp(void* a, void* b);

/**
 * Compare two comparable values, returns Elm Order (LT, EQ, GT).
 * Order is represented as Custom with ctor 0/1/2.
 */
HPointer compare(void* a, void* b);

// ============================================================================
// Equality Operations
// ============================================================================

/**
 * Check structural equality of two values.
 */
bool equal(void* a, void* b);

/**
 * Check inequality of two values.
 */
bool notEqual(void* a, void* b);

/**
 * Less than comparison.
 */
bool lt(void* a, void* b);

/**
 * Less than or equal comparison.
 */
bool le(void* a, void* b);

/**
 * Greater than comparison.
 */
bool gt(void* a, void* b);

/**
 * Greater than or equal comparison.
 */
bool ge(void* a, void* b);

// ============================================================================
// Tuple Constructors
// ============================================================================

/**
 * Returns unit value ().
 */
HPointer Tuple0();

/**
 * Creates a 2-tuple (a, b).
 */
HPointer Tuple2(HPointer a, HPointer b);

/**
 * Creates a 3-tuple (a, b, c).
 */
HPointer Tuple3(HPointer a, HPointer b, HPointer c);

// ============================================================================
// Character Wrapper
// ============================================================================

/**
 * Wraps a character code point as an Elm Char.
 */
HPointer chr(u16 c);

// ============================================================================
// Append Operation
// ============================================================================

/**
 * Appends two appendable values (strings or lists).
 */
HPointer append(void* a, void* b);

} // namespace Elm::Kernel::Utils

#endif // ELM_KERNEL_UTILS_HPP
