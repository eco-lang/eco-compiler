#pragma once

#include "TestSuite.hpp"
#include "Heap.hpp"

namespace Elm {

// ============================================================================
// Elm List Runtime Functions
// ============================================================================

// Returns the Nil constant (empty list).
HPointer elm_nil();

// Allocates a Cons cell with the given head and tail.
HPointer elm_cons(HPointer head, HPointer tail);

// Allocates a Cons cell with an unboxed integer head.
HPointer elm_cons_int(i64 value, HPointer tail);

// Folds left over a list, applying func to each element and accumulator.
// func takes (element, accumulator) and returns new accumulator.
HPointer elm_foldl(HPointer (*func)(HPointer, HPointer), HPointer acc, HPointer list);

// Reverses a list.
HPointer elm_reverse(HPointer list);

// ============================================================================
// Test Helpers
// ============================================================================

// Creates a list from a vector of integers.
HPointer elm_list_from_ints(const std::vector<i64>& values);

// Extracts a list to a vector of integers.
std::vector<i64> elm_list_to_ints(HPointer list);

// Returns the length of a list.
size_t elm_list_length(HPointer list);

}  // namespace Elm

// ============================================================================
// Elm Tests
// ============================================================================

extern Testing::TestCase testElmNilConstant;
extern Testing::TestCase testElmConsAllocation;
extern Testing::TestCase testElmListFromInts;
extern Testing::TestCase testElmReverseEmpty;
extern Testing::TestCase testElmReverseSingle;
extern Testing::TestCase testElmReverseMultiple;
extern Testing::TestCase testElmReverseSurvivesGC;
extern Testing::TestCase testElmReverseLargeList;
