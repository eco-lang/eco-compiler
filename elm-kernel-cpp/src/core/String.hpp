// The C++ side of elm/core's `String` module, for programs eco compiles to native code.
//
// A String on the runtime heap is not one kind of object. It may be a UTF-16 leaf, a large String,
// a slice, a rope, or one of two UTF-8 forms whose bytes are all ASCII, as `Elm::StringOps`
// (runtime/src/allocator/StringOps.hpp) defines them; the empty String is the Empty constant,
// never an object. Whatever the form, a length or a position is counted in UTF-16 units, which is
// how Elm counts them. A Char is one code point, so an operation that turns a String into Chars
// reads a valid surrogate pair as one Char, and one that turns Chars into a String writes a code
// above 0xFFFF as two units.
//
// The functions here take each String as `void*`: the address of a String object that the caller
// has resolved, or null for the empty String. Such a pointer is valid only until the next
// allocation, which may move the object. Most functions forward to the `StringOps` operation of
// the same name, whose comment gives the result's form; `fromList`, `lines`, `words` and
// `fromNumber` are written here. A function that allocates keeps the Strings it still needs alive
// across its own allocations, so the caller need not root them for its sake.
//
// The C-linkage entry points the compiled program calls are in StringExports.cpp, declared in
// KernelExports.h. They decode their arguments and call the functions below, except for `map`,
// `filter`, `any` and `all`. Those take an Elm closure, which these function-pointer versions cannot
// call, so the exports implement them themselves and the versions here have no callers. (`foldl`
// and `foldr` are likewise implemented by their exports alone.)
#ifndef ECO_STRING_HPP
#define ECO_STRING_HPP

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"

namespace Elm::Kernel::String {

// ============================================================================
// Length
// ============================================================================

/// Returns the length of `str` in UTF-16 units, as Elm's `String.length` counts it; 0 for null.
i64 length(void* str);

// ============================================================================
// Concatenation
// ============================================================================

/// Returns `a` followed by `b`, as `StringOps::append` forms it. A GC point.
HPointer append(void* a, void* b);

/// Returns the Strings of the Elm list `stringList` joined in order with `sep` between each two, as
/// `StringOps::join` forms it. A GC point.
HPointer join(void* sep, HPointer stringList);

// ============================================================================
// Character Operations
// ============================================================================

/// Returns the Char `c` followed by `str`. A code point above 0xFFFF is written as its UTF-16
/// surrogate pair. A GC point.
HPointer cons(u32 c, void* str);

/// Returns `Just (c, rest)`, where `c` is the first Char of `str` and `rest` the remainder, or
/// `Nothing` when `str` is null or empty. A GC point.
HPointer uncons(void* str);

/// Returns the String of the Chars in the Elm list `chars`, in order, or the Empty constant for an
/// empty list.
///
/// The list's cells may hold each Char unboxed or as a boxed `ElmChar`. The result is a UTF-8 form
/// when every Char is below 0x80 and UTF-8 Strings are enabled, and a UTF-16 String otherwise. A GC
/// point.
HPointer fromList(HPointer chars);

// ============================================================================
// Higher-Order Operations
// ============================================================================
//
// The functions in this section have no callers: the exports for `String.map`, `filter`, `any`
// and `all` apply Elm closures and do not use them.

/// A function that maps one Char, as a code point, to another.
using CharMapper = u32 (*)(u32);

/// A function that answers a yes-or-no question about one Char, given as a code point.
using CharPredicate = bool (*)(u32);

/// Returns `str` with each Char replaced by `func` of it, as `StringOps::map` does. A GC point.
HPointer map(CharMapper func, void* str);

/// Returns the Chars of `str` for which `pred` is true, in order, as `StringOps::filter` does. A GC
/// point.
HPointer filter(CharPredicate pred, void* str);

/// Returns whether `pred` is true of some Char of `str`.
bool any(CharPredicate pred, void* str);

/// Returns whether `pred` is true of every Char of `str`; true for an empty `str`.
bool all(CharPredicate pred, void* str);

// ============================================================================
// Slicing
// ============================================================================

/// Returns the units of `str` from index `start` up to but not including `end`, as Elm's
/// `String.slice` does: a negative index counts from the end, and both are then clamped to the
/// String. A GC point.
HPointer slice(i64 start, i64 end, void* str);

// ============================================================================
// Splitting
// ============================================================================

/// Returns an Elm list of the pieces of `str` between non-overlapping occurrences of `sep`, found
/// from the left, as `StringOps::split` forms them. A null or empty `str` gives a list holding only
/// the empty String; otherwise a null or empty `sep` splits `str` into its Chars. A GC point.
HPointer split(void* sep, void* str);

/// Returns an Elm list of the lines of `str`, split at each `"\r\n"`, `"\r"` and `"\n"`.
///
/// A line break at the very end gives a final empty line, and a null or empty `str` gives a list
/// holding only the empty String. When `str` is a UTF-8 form and UTF-8 Strings are enabled, each
/// line is what `slice` gives for its range, so a long line shares `str`; otherwise each non-empty
/// line is a new UTF-16 String. A GC point.
HPointer lines(void* str);

/// Returns an Elm list of the words of `str`, as elm/core's JS kernel finds them: `str` is trimmed,
/// then split at each run of whitespace, where whitespace is `StringOps::isJsWhitespace`'s set.
///
/// A `str` that is null, empty or all whitespace gives a list holding only the empty String. When
/// the trimmed String is a UTF-8 form and UTF-8 Strings are enabled, each word is what `slice`
/// gives for its range; otherwise each is a new UTF-16 String. A GC point.
HPointer words(void* str);

// ============================================================================
// Transformation
// ============================================================================

/// Returns the Chars of `str` in reverse order; a valid surrogate pair stays in order as one Char.
/// A GC point.
HPointer reverse(void* str);

/// Returns `str` in upper case, by the Unicode simple case mapping as `StringOps::toUpper` applies
/// it: each code point maps to one code point, with no context and no locale. A GC point.
HPointer toUpper(void* str);

/// Returns `str` in lower case, by the Unicode simple case mapping as `StringOps::toLower` applies
/// it. A GC point.
HPointer toLower(void* str);

/// Returns `str` without the whitespace at either end, where whitespace is
/// `StringOps::isJsWhitespace`'s set. A GC point.
HPointer trim(void* str);

/// Returns `str` without the whitespace at its start, as `trim` defines it. A GC point.
HPointer trimLeft(void* str);

/// Returns `str` without the whitespace at its end, as `trim` defines it. A GC point.
HPointer trimRight(void* str);

// ============================================================================
// Searching
// ============================================================================

/// Returns whether `str` begins with `prefix`. A null `prefix` begins any String.
bool startsWith(void* prefix, void* str);

/// Returns whether `str` ends with `suffix`. A null `suffix` ends any String.
bool endsWith(void* suffix, void* str);

/// Returns whether `needle` occurs in `haystack`. A null `needle` occurs in any String.
bool contains(void* needle, void* haystack);

/// Returns an Elm list of every unit index at which `needle` occurs in `haystack`, in increasing
/// order, overlapping occurrences included. A null or empty `needle`, or a null `haystack`, gives the
/// empty list. A GC point.
HPointer indexes(void* needle, void* haystack);

// ============================================================================
// Conversion
// ============================================================================

/// Returns `Just` the Int that `str` spells in decimal, or `Nothing`, as `StringOps::toInt`
/// decides. A GC point.
HPointer toInt(void* str);

/// Returns `Just` the Float that `str` spells, or `Nothing`, as `StringOps::toFloat` decides. A GC
/// point.
HPointer toFloat(void* str);

/// Returns the text of the number `n`, as `StringOps::fromInt` or `StringOps::fromFloat` writes it.
/// `n` is the address of a boxed `ElmInt` or `ElmFloat`; a null `n`, or an object with any other
/// tag, gives the Empty constant. A GC point.
HPointer fromNumber(void* n);

} // namespace Elm::Kernel::String

#endif // ECO_STRING_HPP
