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
// Length and Character Access
// ============================================================================

/**
 * Returns the number of code units in a string.
 * Equivalent to Elm's String.length for BMP characters.
 */
i64 length(void* str);

/**
 * Checks if a string is empty.
 */
bool isEmpty(HPointer str);

// ============================================================================
// Concatenation
// ============================================================================

/**
 * Appends two strings: a ++ b
 */
HPointer append(void* a, void* b);

/**
 * Concatenates a list of strings.
 */
HPointer concat(HPointer stringList);

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

/**
 * Converts a string to a list of single-character strings.
 */
HPointer toList(void* str);

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
// Slicing
// ============================================================================

/**
 * Extracts a substring from start (inclusive) to end (exclusive).
 * Negative indices count from end.
 */
HPointer slice(i64 start, i64 end, void* str);

/**
 * Returns the first n characters.
 */
HPointer left(i64 n, void* str);

/**
 * Returns the last n characters.
 */
HPointer right(i64 n, void* str);

/**
 * Drops the first n characters.
 */
HPointer dropLeft(i64 n, void* str);

/**
 * Drops the last n characters.
 */
HPointer dropRight(i64 n, void* str);

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

/**
 * Pads string on the left to reach at least n characters.
 */
HPointer padLeft(i64 n, u16 padChar, void* str);

/**
 * Pads string on the right to reach at least n characters.
 */
HPointer padRight(i64 n, u16 padChar, void* str);

/**
 * Repeats a string n times.
 */
HPointer repeat(i64 n, void* str);

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
 * Converts an integer to a string.
 */
HPointer fromInt(i64 n);

/**
 * Converts a float to a string.
 */
HPointer fromFloat(f64 n);

/**
 * Converts a character to a single-character string.
 */
HPointer fromChar(u16 c);

} // namespace Elm::Kernel::String

#endif // ELM_KERNEL_STRING_HPP
