#ifndef ELM_KERNEL_STRING_HPP
#define ELM_KERNEL_STRING_HPP

/**
 * Elm Kernel String Module - Runtime Heap Integration
 *
 * This module provides string operations that work with the GC-managed heap.
 * All strings are represented as HPointer to ElmString objects on the heap.
 *
 * Functions delegate to StringOps helpers from the runtime allocator.
 */

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"

namespace Elm::Kernel::String {

// ============================================================================
// Length
// ============================================================================

/**
 * Returns the number of code units in a string.
 * Equivalent to Elm's String.length for BMP characters.
 */
i64 length(void* str);

// ============================================================================
// Concatenation
// ============================================================================

/**
 * Appends two strings: a ++ b
 */
HPointer append(void* a, void* b);

/**
 * Joins strings with a separator.
 */
HPointer join(void* sep, HPointer stringList);

// ============================================================================
// Character Operations
// ============================================================================

/**
 * Prepends a character to a string.
 * Takes a Unicode code point (char32_t stored as u16 for BMP).
 */
HPointer cons(u16 c, void* str);

/**
 * Removes and returns the first character.
 * Returns Just(Tuple2(char, rest)) or Nothing if empty.
 */
HPointer uncons(void* str);

/**
 * Converts a list of characters to a string.
 */
HPointer fromList(HPointer chars);

// ============================================================================
// Higher-Order Operations
// ============================================================================

/**
 * Function pointer for character transformation.
 */
using CharMapper = u16 (*)(u16);

/**
 * Function pointer for character predicates.
 */
using CharPredicate = bool (*)(u16);

/**
 * Maps a function over each character, producing a new string.
 */
HPointer map(CharMapper func, void* str);

/**
 * Filters characters based on a predicate.
 */
HPointer filter(CharPredicate pred, void* str);

/**
 * Checks if any character satisfies a predicate.
 */
bool any(CharPredicate pred, void* str);

/**
 * Checks if all characters satisfy a predicate.
 */
bool all(CharPredicate pred, void* str);

// ============================================================================
// Folding
// ============================================================================

/**
 * Fold function type: (char, accumulator) -> new_accumulator
 */
using FoldFunc = HPointer (*)(u16, void*);

/**
 * Folds left over characters.
 */
HPointer foldl(FoldFunc func, HPointer acc, void* str);

/**
 * Folds right over characters.
 */
HPointer foldr(FoldFunc func, HPointer acc, void* str);

// ============================================================================
// Slicing
// ============================================================================

/**
 * Extracts a substring from start (inclusive) to end (exclusive).
 * Negative indices count from end.
 */
HPointer slice(i64 start, i64 end, void* str);

// ============================================================================
// Splitting
// ============================================================================

/**
 * Splits a string on a separator into a list of strings.
 */
HPointer split(void* sep, void* str);

/**
 * Splits a string into lines.
 */
HPointer lines(void* str);

/**
 * Splits a string into words.
 */
HPointer words(void* str);

// ============================================================================
// Transformation
// ============================================================================

/**
 * Reverses a string.
 */
HPointer reverse(void* str);

/**
 * Converts string to uppercase (ASCII only).
 */
HPointer toUpper(void* str);

/**
 * Converts string to lowercase (ASCII only).
 */
HPointer toLower(void* str);

/**
 * Trims whitespace from both ends.
 */
HPointer trim(void* str);

/**
 * Trims whitespace from the left.
 */
HPointer trimLeft(void* str);

/**
 * Trims whitespace from the right.
 */
HPointer trimRight(void* str);

// ============================================================================
// Searching
// ============================================================================

/**
 * Checks if str starts with prefix.
 */
bool startsWith(void* prefix, void* str);

/**
 * Checks if str ends with suffix.
 */
bool endsWith(void* suffix, void* str);

/**
 * Checks if the substring needle is contained in haystack.
 */
bool contains(void* needle, void* haystack);

/**
 * Returns a list of all indices where needle appears in haystack.
 */
HPointer indexes(void* needle, void* haystack);

// ============================================================================
// Conversion
// ============================================================================

/**
 * Parses an integer from a string.
 * Returns Just(int) on success, Nothing on failure.
 */
HPointer toInt(void* str);

/**
 * Parses a float from a string.
 * Returns Just(float) on success, Nothing on failure.
 */
HPointer toFloat(void* str);

/**
 * Converts a number to a string.
 * Works for both Int and Float types.
 */
HPointer fromNumber(void* n);

} // namespace Elm::Kernel::String

#endif // ELM_KERNEL_STRING_HPP
