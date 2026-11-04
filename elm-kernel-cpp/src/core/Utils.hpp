#ifndef ECO_UTILS_HPP
#define ECO_UTILS_HPP

// Elm's `==`, `compare` and `++` are polymorphic, and the values they are given can be stored in more than
// one form, so this component decides them by what a value means rather than by how it is laid out.
//
// It holds structural equality (`equal`, `notEqual`), ordering (`compare`, `cmp3`, `lt`, `le`, `gt`, `ge`,
// `compareFloat`), `append`, and the three Order values. Its `extern "C"` exports, declared in
// `KernelExports.h`, wrap these for generated code and add variants that take Int, Float and Char raw.
//
// Three facts about the heap shape everything here.
//
// First, one Elm value can have several heap forms. A String may be any of the String forms
// `alloc::isString` accepts; a non-empty List may be a spine of `Tag_Cons` cells, `Tag_ConsChunk` views,
// or both; a Bytes value may be any form `alloc::byteBufferView` reads. A slot of a tuple, list cell,
// Custom, Record or Array may hold an Int, Float or Char unboxed (raw) or boxed (a pointer to a heap Int,
// Float or Char); the slot's 2-bit kind (0 boxed, 1 Int, 2 Float, 3 Char) says which. Two values that
// differ only in these choices are equal here, with the exceptions stated on `compare` and `equal`.
//
// Second, a value with no fields is an embedded constant word, not a heap object: Unit, `[]`, `""`,
// Nothing, True, False, the Order values and other nullary constructors. The functions taking `void*`
// receive object addresses, as `Export::toPtr` produces them, and a null pointer stands for any embedded
// constant, so they cannot tell two constants apart. A caller holding words must decide an equality in
// which either side is a constant on the words before calling them. Constants nested inside a heap value
// are read as words and handled here.
//
// Third, `""` is the Empty constant, and a String object of length 0 is treated as equal to it wherever
// the two meet.
//
// Like every kernel, it runs on the eco thread, the one thread that runs Elm code and kernel exports.

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"

namespace Elm::Kernel::Utils {

// ============================================================================
// Order Constants
// ============================================================================

/// Does nothing. The Order values are embedded constants, which need no allocation and no GC roots; the
/// function remains because the Order root-registration export calls it.
void initOrderSingletons();

/// Returns the word of the Order value LT, an embedded constant, usable directly as an Elm value.
uint64_t getOrderLT();
/// Returns the word of the Order value EQ, an embedded constant, usable directly as an Elm value.
uint64_t getOrderEQ();
/// Returns the word of the Order value GT, an embedded constant, usable directly as an Elm value.
uint64_t getOrderGT();

// ============================================================================
// Comparison Operations
// ============================================================================

/// Returns the Order value LT, EQ or GT for the sign of `cmp3(a, b)`.
///
/// Allocates nothing; the result is an embedded constant.
HPointer compare(void* a, void* b);

/// Compares `a` and `b` and returns a negative number, zero or a positive number as `a` orders below,
/// equal to or above `b`.
///
/// The magnitude is unclamped: it may be a code-unit difference, a `memcmp` result, a length difference
/// or a difference of heap tags, so a caller must test only the sign. A null pointer is a constant: two
/// nulls are 0, and a null orders below any non-null value except a String of length 0, which it equals.
/// Strings compare by content whatever their forms, through `StringOps::compare`. Ints compare
/// numerically, Floats by `compareFloat`, Chars by code point. Tuples compare slot by slot, and Lists
/// element by element, with a shorter list below a longer one that starts with it; list spines in either
/// form are walked element by element. A boxed and an unboxed list element of the same primitive type
/// compare by value; an Int, Float or Char tuple slot that is boxed on one side and unboxed on the other
/// orders by its kind, not its value. Values with different heap tags order by tag, and two values with a
/// tag not listed here, such as Customs or Records, compare as 0.
///
/// `a` and `b` must be the addresses of heap or `PermanentSpace` objects, or null. Allocates nothing.
int cmp3(void* a, void* b);

/// Returns -1, 0 or 1 as `a` is below, equal to or above `b` in Float's total order, in which NaN equals
/// NaN and is above every number, and -0 equals +0.
///
/// `compare` and `cmp3` use this order for Floats, including Floats inside tuples and lists, except that a
/// boxed and an unboxed Float list element compare with raw `<` and `==`. The `lt`, `le`, `gt` and `ge`
/// functions do not use it for two Floats.
inline int compareFloat(double a, double b) {
    if (a < b) return -1;
    if (a > b) return 1;
    if (a == b) return 0;
    const bool aNaN = a != a;
    const bool bNaN = b != b;
    return aNaN == bNaN ? 0 : (aNaN ? 1 : -1);
}

// ============================================================================
// Equality Operations
// ============================================================================

/// Returns whether `a` and `b` are structurally equal.
///
/// The same address is always equal, so two nulls, which stand for any two constants, are equal. A null and a non-null
/// value are equal only when the non-null one is a String of length 0. Strings and Bytes compare by content whatever
/// their forms, and list spines in either form element by element. Ints and Chars compare by value, Floats with IEEE
/// `==`. Tuples compare slot by slot, Customs once their constructor and field count agree, Records once their field
/// count agrees, and Arrays once their length agrees. A boxed and an unboxed slot holding the same primitive value are
/// equal. A Dict compares by its key/value pairs in key order, whatever the shape or colours of its tree. Apart from
/// the String, Bytes and list forms above, values with different heap tags, functions, and tags not listed here are
/// unequal.
///
/// The recursion is bounded: two values with the same tag, other than Strings and Bytes, whose comparison
/// is reached through more than 100 levels of boxed slots are reported equal without being examined. A
/// list's own spine does not count towards that depth.
///
/// `a` and `b` must be the addresses of heap or `PermanentSpace` objects, or null. Allocates nothing.
bool equal(void* a, void* b);

/// Returns `!equal(a, b)`.
bool notEqual(void* a, void* b);

/// Returns whether `a` is below `b`. For two boxed Floats this is IEEE `<`, false when either is NaN;
/// for anything else it is `cmp3(a, b) < 0`.
bool lt(void* a, void* b);

/// Returns whether `a` is below or equal to `b`. For two boxed Floats this is IEEE `<=`, false when either
/// is NaN; for anything else it is `cmp3(a, b) <= 0`.
bool le(void* a, void* b);

/// Returns whether `a` is above `b`. For two boxed Floats this is IEEE `>`, false when either is NaN;
/// for anything else it is `cmp3(a, b) > 0`.
bool gt(void* a, void* b);

/// Returns whether `a` is above or equal to `b`. For two boxed Floats this is IEEE `>=`, false when either
/// is NaN; for anything else it is `cmp3(a, b) >= 0`.
bool ge(void* a, void* b);

// ============================================================================
// Append Operation
// ============================================================================

/// Returns `a ++ b` for two Strings or two Lists.
///
/// A null `a` or `b` stands for the empty value: two nulls give the Empty constant, and one null gives the
/// other argument itself. Two Strings are joined by `StringOps::append`, two Lists by `ListOps::append`.
/// When `a` is a List, it goes to `ListOps::append` whatever `b` is; for any other non-null `a`, `a`
/// itself is returned.
///
/// May allocate, which is a GC point: after the call `a` and `b` may no longer be valid addresses.
HPointer append(void* a, void* b);

} // namespace Elm::Kernel::Utils

#endif // ECO_UTILS_HPP
