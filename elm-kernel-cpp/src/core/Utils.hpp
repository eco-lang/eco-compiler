#ifndef ECO_UTILS_HPP
#define ECO_UTILS_HPP

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
// Order Singletons
// ============================================================================

// Allocate the three Order Custom values (LT, EQ, GT) once and store them in
// rooted slots. Idempotent. Must run after Allocator::initThread() and before
// any Elm code that might call compare/allocate runs.
void initOrderSingletons();

// Encoded HPointer accessors for the three singletons. Caller may treat the
// return value as an Elm value — equivalent to a successful `compare` result.
uint64_t getOrderLT();
uint64_t getOrderEQ();
uint64_t getOrderGT();

// ============================================================================
// Comparison Operations
// ============================================================================

/**
 * Compare two comparable values, returns Elm Order (LT, EQ, GT).
 * Order is represented as Custom with ctor 0/1/2.
 */
HPointer compare(void* a, void* b);

/**
 * Three-way compare returning a sign int (<0 / 0 / >0) instead of an Order
 * value — the Order-free half of `compare`. The magnitude is UNCLAMPED: it may
 * be a code-unit difference, a memcmp result, or a size difference, so callers
 * must test the sign and never compare against +/-1.
 */
int cmp3(void* a, void* b);

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
// Append Operation
// ============================================================================

/**
 * Appends two appendable values (strings or lists).
 */
HPointer append(void* a, void* b);

} // namespace Elm::Kernel::Utils

#endif // ECO_UTILS_HPP
