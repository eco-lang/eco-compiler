//===- KernelExports.h - C-linkage wrappers for Elm kernel functions ------===//
//
// Compiled Elm code calls the C++ kernels by symbol name, so every kernel entry point needs one
// C-linkage declaration with a fixed name and signature. This header is that list for the
// elm-kernel-cpp modules: elm/core, elm/virtual-dom, elm/browser, elm/json, elm/time, elm/url,
// elm/http, elm/bytes, elm/file, elm/parser and elm/regex. The definitions live in each module's
// *Exports.cpp.
//
// Names. A kernel function `Module.fn` is the symbol Elm_Kernel_ followed by `Module_fn`. Besides
// these the header declares a few other entry points: the elm_* and eco_* call targets of eco.*
// intrinsics, which take unboxed arguments; the three Order getters; and the eco_register_*
// effect-manager hooks.
//
// Per-instance variants. A symbol ending in _Int, _Float or _Char is a per-instance variant of
// the unsuffixed one: the same kernel function, with the parameters of that Elm type passed raw
// instead of boxed; its Int parameters may be raw too, and its signature is authoritative. The
// compiler chooses a variant for the kernel functions and primitive argument types listed in
// kernelInstanceSymbol (compiler/src/Compiler/Generate/MLIR/KernelAbi.elm), and the unsuffixed
// symbol for every other call.
//
// The ABI. An Int is passed as `int64_t` and a Float as `double`. A Char (a Unicode code point)
// is received as a `uint64_t` whose low 32 bits are used, and returned as `uint32_t`; the wider
// parameter is there because the upper register bits are not guaranteed to be zero through LLVM
// gc.statepoint calls. A Bool crosses as a boxed `HPtr` (the True or False constant word,
// REP_ABI_001), not as a C `bool`, except the parameter of Browser.reload. Every other Elm value
// is an `HPtr`, the 64-bit encoded HPointer defined in runtime/src/allocator/Heap.hpp. A closure
// argument is an `HPtr` to a Closure object. A function that takes an Int as `HPtr` receives it
// boxed.
//
// Stubs. Most Browser, Debugger and File entry points are not implemented: they assert when
// assertions are on, and otherwise return 0.
//
//===----------------------------------------------------------------------===//

#ifndef ELM_KERNEL_EXPORTS_H
#define ELM_KERNEL_EXPORTS_H

#include <cstdint>
#include "../../runtime/src/allocator/Heap.hpp"
using Elm::HPtr;

namespace Elm {
/// The exception a failing Bytes decoder throws: a primitive read past the end, or `Bytes.Decode.fail`.
/// Carries nothing. In the kernels, only kernel `Bytes.decode` catches it, and turns it into Nothing.
struct BytesDecodeFailure {};
}  // namespace Elm

extern "C" {

//===----------------------------------------------------------------------===//
// Basics Module (elm/core)
//===----------------------------------------------------------------------===//

/// Implements kernel `Basics.acos`.
double Elm_Kernel_Basics_acos(double x);
/// Implements kernel `Basics.asin`.
double Elm_Kernel_Basics_asin(double x);
/// Implements kernel `Basics.atan`.
double Elm_Kernel_Basics_atan(double x);
/// Implements kernel `Basics.atan2`.
double Elm_Kernel_Basics_atan2(double y, double x);
/// Implements kernel `Basics.cos`.
double Elm_Kernel_Basics_cos(double x);
/// Implements kernel `Basics.sin`.
double Elm_Kernel_Basics_sin(double x);
/// Implements kernel `Basics.tan`.
double Elm_Kernel_Basics_tan(double x);
/// Implements kernel `Basics.sqrt`.
double Elm_Kernel_Basics_sqrt(double x);
/// Implements kernel `Basics.log`.
double Elm_Kernel_Basics_log(double x);
/// Implements kernel `Basics.add` for Int: the Int-typed parameters arrive as raw `int64_t`.
int64_t Elm_Kernel_Basics_add_Int  (int64_t a, int64_t b);
/// Implements kernel `Basics.add` for Float: the Float-typed parameters arrive as raw `double`.
double  Elm_Kernel_Basics_add_Float(double  a, double  b);
/// Implements kernel `Basics.sub` for Int: the Int-typed parameters arrive as raw `int64_t`.
int64_t Elm_Kernel_Basics_sub_Int  (int64_t a, int64_t b);
/// Implements kernel `Basics.sub` for Float: the Float-typed parameters arrive as raw `double`.
double  Elm_Kernel_Basics_sub_Float(double  a, double  b);
/// Implements kernel `Basics.mul` for Int: the Int-typed parameters arrive as raw `int64_t`.
int64_t Elm_Kernel_Basics_mul_Int  (int64_t a, int64_t b);
/// Implements kernel `Basics.mul` for Float: the Float-typed parameters arrive as raw `double`.
double  Elm_Kernel_Basics_mul_Float(double  a, double  b);
/// Implements kernel `Basics.pow` for Int: the Int-typed parameters arrive as raw `int64_t`.
int64_t Elm_Kernel_Basics_pow_Int  (int64_t base, int64_t exp);
/// Implements kernel `Basics.pow` for Float: the Float-typed parameters arrive as raw `double`.
double  Elm_Kernel_Basics_pow_Float(double  base, double  exp);

/// Implements kernel `Basics.add` on boxed numbers: dispatches on the heap tag of `a` (Int, else Float)
/// to the typed variant and returns the result boxed.
HPtr Elm_Kernel_Basics_add(HPtr a, HPtr b);
/// Implements kernel `Basics.sub` on boxed numbers, dispatching on `a`'s heap tag like `Basics.add`.
HPtr Elm_Kernel_Basics_sub(HPtr a, HPtr b);
/// Implements kernel `Basics.mul` on boxed numbers, dispatching on `a`'s heap tag like `Basics.add`.
HPtr Elm_Kernel_Basics_mul(HPtr a, HPtr b);
/// Implements kernel `Basics.pow` on boxed numbers, dispatching on `a`'s heap tag like `Basics.add`.
HPtr Elm_Kernel_Basics_pow(HPtr a, HPtr b);
/// Implements kernel `Basics.e`.
double Elm_Kernel_Basics_e();
/// Implements kernel `Basics.pi`.
double Elm_Kernel_Basics_pi();
/// Implements kernel `Basics.fdiv`.
double Elm_Kernel_Basics_fdiv(double a, double b);
/// Implements kernel `Basics.idiv`.
int64_t Elm_Kernel_Basics_idiv(int64_t a, int64_t b);
/// Implements kernel `Basics.modBy`.
int64_t Elm_Kernel_Basics_modBy(int64_t modulus, int64_t x);
/// Implements kernel `Basics.remainderBy`.
int64_t Elm_Kernel_Basics_remainderBy(int64_t divisor, int64_t x);
/// Implements kernel `Basics.ceiling`.
int64_t Elm_Kernel_Basics_ceiling(double x);
/// Implements kernel `Basics.floor`.
int64_t Elm_Kernel_Basics_floor(double x);
/// Implements kernel `Basics.round`.
int64_t Elm_Kernel_Basics_round(double x);
/// Implements kernel `Basics.truncate`.
int64_t Elm_Kernel_Basics_truncate(double x);
/// Implements kernel `Basics.toFloat`.
double Elm_Kernel_Basics_toFloat(int64_t x);
/// Implements kernel `Basics.isInfinite`.
HPtr Elm_Kernel_Basics_isInfinite(double x);
/// Implements kernel `Basics.isNaN`.
HPtr Elm_Kernel_Basics_isNaN(double x);
/// Implements kernel `Basics.and`.
HPtr Elm_Kernel_Basics_and(HPtr a, HPtr b);
/// Implements kernel `Basics.or`.
HPtr Elm_Kernel_Basics_or(HPtr a, HPtr b);
/// Implements kernel `Basics.xor`.
HPtr Elm_Kernel_Basics_xor(HPtr a, HPtr b);
/// Implements kernel `Basics.not`.
HPtr Elm_Kernel_Basics_not(HPtr a);

//===----------------------------------------------------------------------===//
// Bitwise Module (elm/core)
//===----------------------------------------------------------------------===//

/// Implements kernel `Bitwise.and`.
int64_t Elm_Kernel_Bitwise_and(int64_t a, int64_t b);
/// Implements kernel `Bitwise.or`.
int64_t Elm_Kernel_Bitwise_or(int64_t a, int64_t b);
/// Implements kernel `Bitwise.xor`.
int64_t Elm_Kernel_Bitwise_xor(int64_t a, int64_t b);
/// Implements kernel `Bitwise.complement`.
int64_t Elm_Kernel_Bitwise_complement(int64_t a);
/// Implements kernel `Bitwise.shiftLeftBy`.
int64_t Elm_Kernel_Bitwise_shiftLeftBy(int64_t offset, int64_t a);
/// Implements kernel `Bitwise.shiftRightBy`.
int64_t Elm_Kernel_Bitwise_shiftRightBy(int64_t offset, int64_t a);
/// Implements kernel `Bitwise.shiftRightZfBy`.
uint64_t Elm_Kernel_Bitwise_shiftRightZfBy(int64_t offset, int64_t a);

//===----------------------------------------------------------------------===//
// Char Module (elm/core)
//===----------------------------------------------------------------------===//

/// Returns `code` as a Char, or U+FFFD when `code` is below 0 or above 0x10FFFF. A surrogate code is returned
/// unchanged.
uint32_t Elm_Kernel_Char_fromCode(int64_t code);
/// Returns the code point of the Char in the low 32 bits of `c_raw`.
int64_t Elm_Kernel_Char_toCode(uint64_t c_raw);
/// Returns the Unicode simple lowercase mapping of the Char in the low 32 bits of `c_raw`, or that Char when it has
/// none.
uint32_t Elm_Kernel_Char_toLower(uint64_t c_raw);
/// Returns the Unicode simple uppercase mapping of the Char in the low 32 bits of `c_raw`, or that Char when it has
/// none.
uint32_t Elm_Kernel_Char_toUpper(uint64_t c_raw);
/// Returns what `Elm_Kernel_Char_toLower` returns: no locale is consulted.
uint32_t Elm_Kernel_Char_toLocaleLower(uint64_t c_raw);
/// Returns what `Elm_Kernel_Char_toUpper` returns: no locale is consulted.
uint32_t Elm_Kernel_Char_toLocaleUpper(uint64_t c_raw);

//===----------------------------------------------------------------------===//
// String Module (elm/core)
//===----------------------------------------------------------------------===//

/// Implements kernel `String.length`.
int64_t Elm_Kernel_String_length(HPtr str);
/// Implements kernel `String.append`.
HPtr Elm_Kernel_String_append(HPtr a, HPtr b);
/// Implements kernel `String.join`.
HPtr Elm_Kernel_String_join(HPtr sep, HPtr stringList);
/// Implements kernel `String.cons`.
HPtr Elm_Kernel_String_cons(uint64_t c_raw, HPtr str);
/// Implements kernel `String.uncons`.
HPtr Elm_Kernel_String_uncons(HPtr str);
/// Implements kernel `String.fromList`.
HPtr Elm_Kernel_String_fromList(HPtr chars);
/// Implements kernel `String.slice`.
HPtr Elm_Kernel_String_slice(int64_t start, int64_t end, HPtr str);
/// Implements kernel `String.split`.
HPtr Elm_Kernel_String_split(HPtr sep, HPtr str);
/// Implements kernel `String.lines`.
HPtr Elm_Kernel_String_lines(HPtr str);
/// Implements kernel `String.words`.
HPtr Elm_Kernel_String_words(HPtr str);
/// Implements kernel `String.reverse`.
HPtr Elm_Kernel_String_reverse(HPtr str);
/// Implements kernel `String.toUpper`.
HPtr Elm_Kernel_String_toUpper(HPtr str);
/// Implements kernel `String.toLower`.
HPtr Elm_Kernel_String_toLower(HPtr str);
/// Implements kernel `String.trim`.
HPtr Elm_Kernel_String_trim(HPtr str);
/// Implements kernel `String.trimLeft`.
HPtr Elm_Kernel_String_trimLeft(HPtr str);
/// Implements kernel `String.trimRight`.
HPtr Elm_Kernel_String_trimRight(HPtr str);
/// Implements kernel `String.startsWith`.
HPtr Elm_Kernel_String_startsWith(HPtr prefix, HPtr str);
/// Implements kernel `String.endsWith`.
HPtr Elm_Kernel_String_endsWith(HPtr suffix, HPtr str);
/// Implements kernel `String.contains`.
HPtr Elm_Kernel_String_contains(HPtr needle, HPtr haystack);
/// Implements kernel `String.indexes`.
HPtr Elm_Kernel_String_indexes(HPtr needle, HPtr haystack);
/// Implements kernel `String.toInt`.
HPtr Elm_Kernel_String_toInt(HPtr str);
/// Implements kernel `String.toFloat`.
HPtr Elm_Kernel_String_toFloat(HPtr str);
/// Implements kernel `String.fromNumber`.
HPtr Elm_Kernel_String_fromNumber(HPtr n);
/// Implements kernel `String.fromNumber` for Int: the Int-typed parameters arrive as raw `int64_t`.
HPtr Elm_Kernel_String_fromNumber_Int  (int64_t n);
/// Implements kernel `String.fromNumber` for Float: the Float-typed parameters arrive as raw `double`.
HPtr Elm_Kernel_String_fromNumber_Float(double  n);
/// Returns the String form of `n`; the call target of the `eco.string.from_int` intrinsic.
HPtr elm_string_from_int(int64_t n);
/// Returns the String form of `f`; the call target of the `eco.string.from_float` intrinsic.
HPtr elm_string_from_double(double f);
/// Implements kernel `String.map`.
HPtr Elm_Kernel_String_map(HPtr closure, HPtr str);
/// Implements kernel `String.filter`.
HPtr Elm_Kernel_String_filter(HPtr closure, HPtr str);
/// Implements kernel `String.any`.
HPtr Elm_Kernel_String_any(HPtr closure, HPtr str);
/// Implements kernel `String.all`.
HPtr Elm_Kernel_String_all(HPtr closure, HPtr str);
/// Implements kernel `String.foldl`.
HPtr Elm_Kernel_String_foldl(HPtr closure, HPtr acc, HPtr str);
/// Implements kernel `String.foldr`.
HPtr Elm_Kernel_String_foldr(HPtr closure, HPtr acc, HPtr str);

//===----------------------------------------------------------------------===//
// List Module (elm/core)
//===----------------------------------------------------------------------===//

/// Implements kernel `List.cons`.
HPtr Elm_Kernel_List_cons(HPtr head, HPtr tail);
/// Implements kernel `List.cons` for Int: the Int-typed parameters arrive as raw `int64_t`.
HPtr Elm_Kernel_List_cons_Int  (int64_t  head, HPtr tail);
/// Implements kernel `List.cons` for Float: the Float-typed parameters arrive as raw `double`.
HPtr Elm_Kernel_List_cons_Float(double   head, HPtr tail);
/// Implements kernel `List.cons` for Char: the Char-typed parameters arrive as raw `uint64_t`.
HPtr Elm_Kernel_List_cons_Char (uint64_t head_raw, HPtr tail);
/// Implements kernel `List.fromArray`.
HPtr Elm_Kernel_List_fromArray(HPtr array);
/// Implements kernel `List.toArray`.
HPtr Elm_Kernel_List_toArray(HPtr list);
/// Implements kernel `List.reverse`.
HPtr Elm_Kernel_List_reverse(HPtr list);
/// Implements kernel `List.append`.
HPtr Elm_Kernel_List_append(HPtr a, HPtr b);
/// Implements kernel `List.concat`.
HPtr Elm_Kernel_List_concat(HPtr listOfLists);
/// Implements kernel `List.take`.
HPtr Elm_Kernel_List_take(int64_t n, HPtr list);
/// Implements kernel `List.drop`.
HPtr Elm_Kernel_List_drop(int64_t n, HPtr list);
/// Implements kernel `List.map2`.
HPtr Elm_Kernel_List_map2(HPtr closure, HPtr xs, HPtr ys);
/// Implements kernel `List.map3`.
HPtr Elm_Kernel_List_map3(HPtr closure, HPtr xs, HPtr ys, HPtr zs);
/// Implements kernel `List.map4`.
HPtr Elm_Kernel_List_map4(HPtr closure, HPtr ws, HPtr xs, HPtr ys, HPtr zs);
/// Implements kernel `List.map5`.
HPtr Elm_Kernel_List_map5(HPtr closure, HPtr vs, HPtr ws, HPtr xs, HPtr ys, HPtr zs);
/// Implements kernel `List.sortBy`.
HPtr Elm_Kernel_List_sortBy(HPtr closure, HPtr list);
/// Implements kernel `List.sortWith`.
HPtr Elm_Kernel_List_sortWith(HPtr closure, HPtr list);

//===----------------------------------------------------------------------===//
// Utils Module (elm/core)
//===----------------------------------------------------------------------===//

// The exports that take words decide by what a value means, as `core/Utils.hpp` describes. `equal` and `notEqual`
// decide an equality in which either word is an embedded constant on the words themselves, except that the Empty
// constant equals a String of length 0. The ordering exports (`compare`, `cmp3`, `lt`, `le`, `gt`, `ge`) hand
// `Utils` object addresses, in which every embedded constant is null, so they cannot tell two constants apart. The
// Float variants that return a Bool use IEEE comparison, so NaN is unequal to itself and no ordering with NaN holds;
// `compare_Float` uses the total order of `Utils::compareFloat`, in which NaN equals NaN and is above every number.

/// Implements kernel `Utils.compare`.
HPtr Elm_Kernel_Utils_compare(HPtr a, HPtr b);
/// Implements kernel `Utils.compare` for Int: the Int-typed parameters arrive as raw `int64_t`.
HPtr Elm_Kernel_Utils_compare_Int  (int64_t  a, int64_t  b);
/// Implements kernel `Utils.compare` for Float: the Float-typed parameters arrive as raw `double`.
HPtr Elm_Kernel_Utils_compare_Float(double   a, double   b);
/// Implements kernel `Utils.compare` for Char: the Char-typed parameters arrive as raw `uint64_t`.
HPtr Elm_Kernel_Utils_compare_Char (uint64_t a_raw, uint64_t b_raw);
/// Compares `a` and `b` structurally and returns an unclamped sign (any negative, zero or positive value).
int64_t Elm_Kernel_Utils_cmp3(HPtr a, HPtr b);
/// Compares two Strings and returns an unclamped sign. Allocates nothing on the GC heap.
int64_t eco_string_cmp3(HPtr a, HPtr b);
/// Compares two Strings and returns the Order value for the result.
HPtr    eco_string_cmp_order(HPtr a, HPtr b);
/// Returns String `a` followed by `b`; the call target of `eco.string.append`. Allocates.
HPtr eco_string_append(HPtr a, HPtr b);
/// Returns List `a` followed by `b`; the call target of `eco.list.append`. Allocates.
HPtr eco_list_append(HPtr a, HPtr b);
/// Returns the Order value LT, EQ or GT for a negative, zero or positive `sign`. Allocates nothing; the
/// `eco.*.cmp_order` lowering calls it as a gc-leaf (CGEN_075).
HPtr    eco_order_from_sign(int64_t sign);
/// Implements kernel `Utils.equal`.
HPtr Elm_Kernel_Utils_equal(HPtr a, HPtr b);
/// Implements kernel `Utils.notEqual`.
HPtr Elm_Kernel_Utils_notEqual(HPtr a, HPtr b);
/// Implements kernel `Utils.lt`.
HPtr Elm_Kernel_Utils_lt(HPtr a, HPtr b);
/// Implements kernel `Utils.le`.
HPtr Elm_Kernel_Utils_le(HPtr a, HPtr b);
/// Implements kernel `Utils.gt`.
HPtr Elm_Kernel_Utils_gt(HPtr a, HPtr b);
/// Implements kernel `Utils.ge`.
HPtr Elm_Kernel_Utils_ge(HPtr a, HPtr b);
/// Implements kernel `Utils.append`.
HPtr Elm_Kernel_Utils_append(HPtr a, HPtr b);
/// Implements kernel `Utils.equal` for Int: the Int-typed parameters arrive as raw `int64_t`.
HPtr Elm_Kernel_Utils_equal_Int     (int64_t  a, int64_t  b);
/// Implements kernel `Utils.equal` for Float: the Float-typed parameters arrive as raw `double`.
HPtr Elm_Kernel_Utils_equal_Float   (double   a, double   b);
/// Implements kernel `Utils.equal` for Char: the Char-typed parameters arrive as raw `uint64_t`.
HPtr Elm_Kernel_Utils_equal_Char    (uint64_t a_raw, uint64_t b_raw);
/// Implements kernel `Utils.notEqual` for Int: the Int-typed parameters arrive as raw `int64_t`.
HPtr Elm_Kernel_Utils_notEqual_Int  (int64_t  a, int64_t  b);
/// Implements kernel `Utils.notEqual` for Float: the Float-typed parameters arrive as raw `double`.
HPtr Elm_Kernel_Utils_notEqual_Float(double   a, double   b);
/// Implements kernel `Utils.notEqual` for Char: the Char-typed parameters arrive as raw `uint64_t`.
HPtr Elm_Kernel_Utils_notEqual_Char (uint64_t a_raw, uint64_t b_raw);
/// Implements kernel `Utils.lt` for Int: the Int-typed parameters arrive as raw `int64_t`.
HPtr Elm_Kernel_Utils_lt_Int        (int64_t  a, int64_t  b);
/// Implements kernel `Utils.lt` for Float: the Float-typed parameters arrive as raw `double`.
HPtr Elm_Kernel_Utils_lt_Float      (double   a, double   b);
/// Implements kernel `Utils.lt` for Char: the Char-typed parameters arrive as raw `uint64_t`.
HPtr Elm_Kernel_Utils_lt_Char       (uint64_t a_raw, uint64_t b_raw);
/// Implements kernel `Utils.le` for Int: the Int-typed parameters arrive as raw `int64_t`.
HPtr Elm_Kernel_Utils_le_Int        (int64_t  a, int64_t  b);
/// Implements kernel `Utils.le` for Float: the Float-typed parameters arrive as raw `double`.
HPtr Elm_Kernel_Utils_le_Float      (double   a, double   b);
/// Implements kernel `Utils.le` for Char: the Char-typed parameters arrive as raw `uint64_t`.
HPtr Elm_Kernel_Utils_le_Char       (uint64_t a_raw, uint64_t b_raw);
/// Implements kernel `Utils.gt` for Int: the Int-typed parameters arrive as raw `int64_t`.
HPtr Elm_Kernel_Utils_gt_Int        (int64_t  a, int64_t  b);
/// Implements kernel `Utils.gt` for Float: the Float-typed parameters arrive as raw `double`.
HPtr Elm_Kernel_Utils_gt_Float      (double   a, double   b);
/// Implements kernel `Utils.gt` for Char: the Char-typed parameters arrive as raw `uint64_t`.
HPtr Elm_Kernel_Utils_gt_Char       (uint64_t a_raw, uint64_t b_raw);
/// Implements kernel `Utils.ge` for Int: the Int-typed parameters arrive as raw `int64_t`.
HPtr Elm_Kernel_Utils_ge_Int        (int64_t  a, int64_t  b);
/// Implements kernel `Utils.ge` for Float: the Float-typed parameters arrive as raw `double`.
HPtr Elm_Kernel_Utils_ge_Float      (double   a, double   b);
/// Implements kernel `Utils.ge` for Char: the Char-typed parameters arrive as raw `uint64_t`.
HPtr Elm_Kernel_Utils_ge_Char       (uint64_t a_raw, uint64_t b_raw);

/// Returns the Order value LT, an embedded constant word. Allocates nothing.
HPtr Eco_Runtime_getOrderLT();
/// Returns the Order value EQ, an embedded constant word. Allocates nothing.
HPtr Eco_Runtime_getOrderEQ();
/// Returns the Order value GT, an embedded constant word. Allocates nothing.
HPtr Eco_Runtime_getOrderGT();

/// Does nothing: the Order values are embedded constants and need no roots. An init hook that
/// ecoc, EcoRunner and eco-kernel's RuntimeExports call when linked.
void Eco_Kernel_Order_register_gc_roots();

//===----------------------------------------------------------------------===//
// JsArray Module (elm/core)
//===----------------------------------------------------------------------===//

/// Implements kernel `JsArray.empty`.
HPtr Elm_Kernel_JsArray_empty();
/// Implements kernel `JsArray.singleton`.
HPtr Elm_Kernel_JsArray_singleton(HPtr value);
/// Implements kernel `JsArray.length`; returns the length unboxed.
int64_t Elm_Kernel_JsArray_length(HPtr array);
/// Implements kernel `JsArray.unsafeGet`.
HPtr Elm_Kernel_JsArray_unsafeGet(HPtr index, HPtr array);
/// Returns a copy of `array` with element `index` replaced by `value`. The index is checked only on its low 32 bits,
/// read unsigned: when they are not below the length, the copy is returned unchanged. The same holds for the typed
/// `unsafeSet` variants below.
HPtr Elm_Kernel_JsArray_unsafeSet(HPtr index, HPtr value, HPtr array);
/// Implements kernel `JsArray.push`.
HPtr Elm_Kernel_JsArray_push(HPtr value, HPtr array);
/// Returns the elements of `array` from `start` up to, not including, `end`. A negative `start` or `end` counts from
/// the end of the array; both are then clamped to the array, and an empty range gives an empty array.
HPtr Elm_Kernel_JsArray_slice(HPtr start, HPtr end, HPtr array);
/// Returns `dest` followed by the leading elements of `source`, as many as bring the length up to `n`, or `dest`'s
/// elements alone when it already has `n` or more. `n` is read as its low 32 bits, unsigned.
HPtr Elm_Kernel_JsArray_appendN(HPtr n, HPtr dest, HPtr source);
/// Implements kernel `JsArray.singleton` for Int: the Int-typed parameters arrive as raw `int64_t`.
HPtr Elm_Kernel_JsArray_singleton_Int  (int64_t  v);
/// Implements kernel `JsArray.singleton` for Float: the Float-typed parameters arrive as raw `double`.
HPtr Elm_Kernel_JsArray_singleton_Float(double   v);
/// Implements kernel `JsArray.singleton` for Char: the Char-typed parameters arrive as raw `uint64_t`.
HPtr Elm_Kernel_JsArray_singleton_Char (uint64_t v_raw);
/// Implements kernel `JsArray.unsafeGet` for Int: the Int-typed parameters arrive as raw `int64_t`.
HPtr Elm_Kernel_JsArray_unsafeGet_Int  (int64_t  index, HPtr array);
/// Implements kernel `JsArray.unsafeSet` for Int: the Int-typed parameters arrive as raw `int64_t`.
HPtr Elm_Kernel_JsArray_unsafeSet_Int  (int64_t  index, int64_t  value, HPtr array);
/// Implements kernel `JsArray.unsafeSet` for Float: the Float-typed parameters arrive as raw `double`.
HPtr Elm_Kernel_JsArray_unsafeSet_Float(int64_t  index, double   value, HPtr array);
/// Implements kernel `JsArray.unsafeSet` for Char: the Char-typed parameters arrive as raw `uint64_t`.
HPtr Elm_Kernel_JsArray_unsafeSet_Char (int64_t  index, uint64_t value_raw, HPtr array);
/// Implements kernel `JsArray.push` for Int: the Int-typed parameters arrive as raw `int64_t`.
HPtr Elm_Kernel_JsArray_push_Int       (int64_t  v, HPtr array);
/// Implements kernel `JsArray.push` for Float: the Float-typed parameters arrive as raw `double`.
HPtr Elm_Kernel_JsArray_push_Float     (double   v, HPtr array);
/// Implements kernel `JsArray.push` for Char: the Char-typed parameters arrive as raw `uint64_t`.
HPtr Elm_Kernel_JsArray_push_Char      (uint64_t v_raw, HPtr array);
/// Implements kernel `JsArray.slice` for Int: the Int-typed parameters arrive as raw `int64_t`.
HPtr Elm_Kernel_JsArray_slice_Int      (int64_t  start, int64_t end, HPtr array);
/// Implements kernel `JsArray.appendN` for Int: the Int-typed parameters arrive as raw `int64_t`.
HPtr Elm_Kernel_JsArray_appendN_Int    (int64_t  n, HPtr dest, HPtr source);
/// Returns an empty array; the call target of the `eco.array.*` lowering.
HPtr elm_array_empty();
/// Returns a one-element array holding `v`, given as a raw Int; an `eco.array.*` target.
HPtr elm_array_singleton_int(int64_t v);
/// Returns a one-element array holding `v`, given as a raw Float; an `eco.array.*` target.
HPtr elm_array_singleton_float(double v);
/// Returns a one-element array holding `v`, given as a raw Char; an `eco.array.*` target.
HPtr elm_array_singleton_char(uint64_t v_raw);
/// Returns a one-element array holding `value`; an `eco.array.*` target.
HPtr elm_array_singleton_box(HPtr value);
/// Returns `array` with `v` appended, given as a raw Int; an `eco.array.*` target.
HPtr elm_array_push_int(int64_t v, HPtr array);
/// Returns `array` with `v` appended, given as a raw Float; an `eco.array.*` target.
HPtr elm_array_push_float(double v, HPtr array);
/// Returns `array` with `v` appended, given as a raw Char; an `eco.array.*` target.
HPtr elm_array_push_char(uint64_t v_raw, HPtr array);
/// Returns `array` with `value` appended; an `eco.array.*` target.
HPtr elm_array_push_box(HPtr value, HPtr array);
/// Returns elements `start` up to `end` of `array`; the unboxed-argument `eco.array.*` target.
HPtr elm_array_slice(int64_t start, int64_t end, HPtr array);
/// Implements `JsArray.appendN` with an unboxed `n`; the `eco.array.*` target.
HPtr elm_array_append_n(int64_t n, HPtr dest, HPtr source);
/// Implements kernel `JsArray.initialize`.
HPtr Elm_Kernel_JsArray_initialize(HPtr size, HPtr offset, HPtr closure);
/// Implements kernel `JsArray.initializeFromList`.
HPtr Elm_Kernel_JsArray_initializeFromList(HPtr max, HPtr list);
/// Implements kernel `JsArray.initialize` for Int: the Int-typed parameters arrive as raw `int64_t`.
HPtr Elm_Kernel_JsArray_initialize_Int        (int64_t size, int64_t offset, HPtr closure);
/// Implements kernel `JsArray.initializeFromList` for Int: the Int-typed parameters arrive as raw `int64_t`.
HPtr Elm_Kernel_JsArray_initializeFromList_Int(int64_t max, HPtr list);
/// Implements kernel `JsArray.map`.
HPtr Elm_Kernel_JsArray_map(HPtr closure, HPtr array);
/// Implements kernel `JsArray.indexedMap`.
HPtr Elm_Kernel_JsArray_indexedMap(HPtr closure, HPtr offset, HPtr array);
/// Implements kernel `JsArray.indexedMap` for Int: the Int-typed parameters arrive as raw `int64_t`.
HPtr Elm_Kernel_JsArray_indexedMap_Int(HPtr closure, int64_t offset, HPtr array);
/// Implements kernel `JsArray.foldl`.
HPtr Elm_Kernel_JsArray_foldl(HPtr closure, HPtr acc, HPtr array);
/// Implements kernel `JsArray.foldr`.
HPtr Elm_Kernel_JsArray_foldr(HPtr closure, HPtr acc, HPtr array);

//===----------------------------------------------------------------------===//
// Debug Module (elm/core)
//===----------------------------------------------------------------------===//

/// Writes `tag`, `: `, `value` as `eco_print_elm_value` prints it, and a newline to the calling thread's print
/// destination, and returns `value`.
HPtr Elm_Kernel_Debug_log(HPtr tag, HPtr value);
/// Writes `Debug.todo: `, `message` and a newline to the calling thread's print destination, then ends the process
/// with `exit(1)`; it does not throw and does not return.
HPtr Elm_Kernel_Debug_todo(HPtr message);
/// Implements kernel `Debug.toString`.
HPtr Elm_Kernel_Debug_toString(HPtr value);
/// Implements a saturated `Debug.toString` call; `type_id` is the argument's type id, supplied by the
/// code generator so that constructor names can be printed.
HPtr Elm_Kernel_Debug_toString_typed(HPtr value, int64_t type_id);

//===----------------------------------------------------------------------===//
// Platform Module (elm/core)
//===----------------------------------------------------------------------===//

/// Implements kernel `Platform.batch`.
HPtr Elm_Kernel_Platform_batch(HPtr commands);
/// Implements kernel `Platform.map`.
HPtr Elm_Kernel_Platform_map(HPtr closure, HPtr cmd);
/// Implements kernel `Platform.sendToApp`.
void Elm_Kernel_Platform_sendToApp(HPtr router, HPtr msg);
/// Implements kernel `Platform.sendToSelf`.
HPtr Elm_Kernel_Platform_sendToSelf(HPtr router, HPtr msg);
/// Implements kernel `Platform.worker`.
HPtr Elm_Kernel_Platform_worker(HPtr impl);
/// Implements kernel `Platform.leaf`.
HPtr Elm_Kernel_Platform_leaf(HPtr home, HPtr value);
/// Implements kernel `Platform.registerIncomingPort`.
HPtr Elm_Kernel_Platform_registerIncomingPort(HPtr name, HPtr decoder);
/// Implements kernel `Platform.registerOutgoingPort`.
HPtr Elm_Kernel_Platform_registerOutgoingPort(HPtr name);
/// Implements kernel `Platform.registerFlagsDecoder`.
HPtr Elm_Kernel_Platform_registerFlagsDecoder(HPtr decoder);

//===----------------------------------------------------------------------===//
// Process Module (elm/core)
//===----------------------------------------------------------------------===//

/// Returns a Task that, each time it runs, completes after `time` milliseconds; killing it withdraws its timer.
/// `time` is handed to `TimerService::schedule` unchecked, so it must meet that function's precondition.
HPtr Elm_Kernel_Process_sleep(double time);

//===----------------------------------------------------------------------===//
// Scheduler Module (elm/core)
//===----------------------------------------------------------------------===//

/// Implements kernel `Scheduler.succeed`.
HPtr Elm_Kernel_Scheduler_succeed(HPtr value);
/// Implements kernel `Scheduler.fail`.
HPtr Elm_Kernel_Scheduler_fail(HPtr error);
/// Implements kernel `Scheduler.andThen`.
HPtr Elm_Kernel_Scheduler_andThen(HPtr closure, HPtr task);
/// Implements kernel `Scheduler.onError`.
HPtr Elm_Kernel_Scheduler_onError(HPtr closure, HPtr task);
/// Implements kernel `Scheduler.spawn`.
HPtr Elm_Kernel_Scheduler_spawn(HPtr task);
/// Implements kernel `Scheduler.kill`.
HPtr Elm_Kernel_Scheduler_kill(HPtr process);

//===----------------------------------------------------------------------===//
// VirtualDom Module (elm/virtual-dom)
//===----------------------------------------------------------------------===//

/// Implements kernel `VirtualDom.text`.
HPtr Elm_Kernel_VirtualDom_text(HPtr str);
/// Implements kernel `VirtualDom.node`.
HPtr Elm_Kernel_VirtualDom_node(HPtr tag, HPtr factList, HPtr kidList);
/// Implements kernel `VirtualDom.nodeNS`.
HPtr Elm_Kernel_VirtualDom_nodeNS(HPtr ns, HPtr tag, HPtr factList, HPtr kidList);
/// Implements kernel `VirtualDom.keyedNode`.
HPtr Elm_Kernel_VirtualDom_keyedNode(HPtr tag, HPtr factList, HPtr keyedKidList);
/// Implements kernel `VirtualDom.keyedNodeNS`.
HPtr Elm_Kernel_VirtualDom_keyedNodeNS(HPtr ns, HPtr tag, HPtr factList, HPtr keyedKidList);
/// Implements kernel `VirtualDom.attribute`.
HPtr Elm_Kernel_VirtualDom_attribute(HPtr key, HPtr value);
/// Implements kernel `VirtualDom.attributeNS`.
HPtr Elm_Kernel_VirtualDom_attributeNS(HPtr ns, HPtr key, HPtr value);
/// Implements kernel `VirtualDom.property`.
HPtr Elm_Kernel_VirtualDom_property(HPtr key, HPtr value);
/// Implements kernel `VirtualDom.style`.
HPtr Elm_Kernel_VirtualDom_style(HPtr key, HPtr value);
/// Implements kernel `VirtualDom.on`.
HPtr Elm_Kernel_VirtualDom_on(HPtr event, HPtr decoder);
/// Returns a `Mapped` node holding `closure` and `vnode`; no closure is composed.
HPtr Elm_Kernel_VirtualDom_map(HPtr closure, HPtr vnode);
/// Returns a copy of an `Event` fact with `closure` consed onto its tagger list, so the outermost tagger is first.
/// Any other fact, or an embedded constant, is returned unchanged.
HPtr Elm_Kernel_VirtualDom_mapAttribute(HPtr closure, HPtr fact);
// The `lazy` functions apply `closure` to their arguments at once and return the resulting node: nothing is deferred
// or memoised.

/// Implements kernel `VirtualDom.lazy`.
HPtr Elm_Kernel_VirtualDom_lazy(HPtr closure, HPtr arg);
/// Implements kernel `VirtualDom.lazy2`.
HPtr Elm_Kernel_VirtualDom_lazy2(HPtr closure, HPtr a, HPtr b);
/// Implements kernel `VirtualDom.lazy3`.
HPtr Elm_Kernel_VirtualDom_lazy3(HPtr closure, HPtr a, HPtr b, HPtr c);
/// Implements kernel `VirtualDom.lazy4`.
HPtr Elm_Kernel_VirtualDom_lazy4(HPtr closure, HPtr a, HPtr b, HPtr c, HPtr d);
/// Implements kernel `VirtualDom.lazy5`.
HPtr Elm_Kernel_VirtualDom_lazy5(HPtr closure, HPtr a, HPtr b, HPtr c, HPtr d, HPtr e);
/// Implements kernel `VirtualDom.lazy6`.
HPtr Elm_Kernel_VirtualDom_lazy6(HPtr closure, HPtr a, HPtr b, HPtr c, HPtr d, HPtr e, HPtr f);
/// Implements kernel `VirtualDom.lazy7`.
HPtr Elm_Kernel_VirtualDom_lazy7(HPtr closure, HPtr a, HPtr b, HPtr c, HPtr d, HPtr e, HPtr f, HPtr g);
/// Implements kernel `VirtualDom.lazy8`.
HPtr Elm_Kernel_VirtualDom_lazy8(HPtr closure, HPtr a, HPtr b, HPtr c, HPtr d, HPtr e, HPtr f, HPtr g, HPtr h);
/// Implements kernel `VirtualDom.noScript`.
HPtr Elm_Kernel_VirtualDom_noScript(HPtr tag);
/// Implements kernel `VirtualDom.noOnOrFormAction`.
HPtr Elm_Kernel_VirtualDom_noOnOrFormAction(HPtr key);
/// Implements kernel `VirtualDom.noInnerHtmlOrFormAction`.
HPtr Elm_Kernel_VirtualDom_noInnerHtmlOrFormAction(HPtr key);
/// Implements kernel `VirtualDom.noJavaScriptUri`.
HPtr Elm_Kernel_VirtualDom_noJavaScriptUri(HPtr value);
/// Implements kernel `VirtualDom.noJavaScriptOrHtmlUri`.
HPtr Elm_Kernel_VirtualDom_noJavaScriptOrHtmlUri(HPtr value);
/// Returns `Json.Encode.string ""` for a JSON String or array whose JavaScript `String(value)` passes
/// `Xss::isJavaScriptOrHtmlUri`, and `value` unchanged otherwise.
HPtr Elm_Kernel_VirtualDom_noJavaScriptOrHtmlJson(HPtr value);

//===----------------------------------------------------------------------===//
// Browser Module (elm/browser)
//===----------------------------------------------------------------------===//

/// Returns `impl` unchanged.
HPtr Elm_Kernel_Browser_element(HPtr impl);
/// Returns `impl` unchanged.
HPtr Elm_Kernel_Browser_document(HPtr impl);
/// Returns `impl` unchanged.
HPtr Elm_Kernel_Browser_application(HPtr impl);
/// Stands in for kernel `Browser.load`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_Browser_load(HPtr url);
/// Stands in for kernel `Browser.reload`: asserts when assertions are on, else returns word 0. The
/// only raw `bool` parameter in this header.
HPtr Elm_Kernel_Browser_reload(bool skipCache);
/// Stands in for kernel `Browser.pushUrl`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_Browser_pushUrl(HPtr key, HPtr url);
/// Stands in for kernel `Browser.replaceUrl`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_Browser_replaceUrl(HPtr key, HPtr url);
/// Stands in for kernel `Browser.go`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_Browser_go(HPtr key, int64_t steps);
/// Stands in for kernel `Browser.getViewport`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_Browser_getViewport();
/// Stands in for kernel `Browser.getViewportOf`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_Browser_getViewportOf(HPtr id);
/// Stands in for kernel `Browser.setViewport`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_Browser_setViewport(double x, double y);
/// Stands in for kernel `Browser.setViewportOf`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_Browser_setViewportOf(HPtr id, double x, double y);
/// Stands in for kernel `Browser.getElement`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_Browser_getElement(HPtr id);
/// Stands in for kernel `Browser.on`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_Browser_on(HPtr node, HPtr eventName, HPtr handler);
/// Stands in for kernel `Browser.decodeEvent`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_Browser_decodeEvent(HPtr decoder, HPtr event);
/// Stands in for kernel `Browser.doc`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_Browser_doc();
/// Stands in for kernel `Browser.window`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_Browser_window();
/// Stands in for kernel `Browser.withWindow`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_Browser_withWindow(HPtr closure);
/// Stands in for kernel `Browser.rAF`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_Browser_rAF();
/// Stands in for kernel `Browser.now`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_Browser_now();
/// Stands in for kernel `Browser.visibilityInfo`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_Browser_visibilityInfo();
/// Stands in for kernel `Browser.call`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_Browser_call(HPtr closure);

//===----------------------------------------------------------------------===//
// Debugger Module (elm/browser)
//===----------------------------------------------------------------------===//

/// Stands in for kernel `Debugger.init`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_Debugger_init(HPtr value);
/// Stands in for kernel `Debugger.isOpen`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_Debugger_isOpen(HPtr popout);
/// Stands in for kernel `Debugger.open`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_Debugger_open(HPtr popout);
/// Stands in for kernel `Debugger.scroll`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_Debugger_scroll(HPtr popout);
/// Stands in for kernel `Debugger.messageToString`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_Debugger_messageToString(HPtr message);
/// Stands in for kernel `Debugger.download`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_Debugger_download(int64_t historyLength, HPtr json);
/// Stands in for kernel `Debugger.upload`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_Debugger_upload();
/// Stands in for kernel `Debugger.unsafeCoerce`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_Debugger_unsafeCoerce(HPtr value);

//===----------------------------------------------------------------------===//
// Json Module (elm/json)
//===----------------------------------------------------------------------===//

/// Implements kernel `Json.decodeString`.
HPtr Elm_Kernel_Json_decodeString();
/// Implements kernel `Json.decodeBool`.
HPtr Elm_Kernel_Json_decodeBool();
/// Implements kernel `Json.decodeInt`.
HPtr Elm_Kernel_Json_decodeInt();
/// Implements kernel `Json.decodeFloat`.
HPtr Elm_Kernel_Json_decodeFloat();
/// Implements kernel `Json.decodeNull`.
HPtr Elm_Kernel_Json_decodeNull(HPtr fallback);
/// Implements kernel `Json.decodeList`.
HPtr Elm_Kernel_Json_decodeList(HPtr decoder);
/// Implements kernel `Json.decodeArray`.
HPtr Elm_Kernel_Json_decodeArray(HPtr decoder);
/// Implements kernel `Json.decodeField`.
HPtr Elm_Kernel_Json_decodeField(HPtr fieldName, HPtr decoder);
/// Implements kernel `Json.decodeIndex`.
HPtr Elm_Kernel_Json_decodeIndex(int64_t index, HPtr decoder);
/// Implements kernel `Json.decodeKeyValuePairs`.
HPtr Elm_Kernel_Json_decodeKeyValuePairs(HPtr decoder);
/// Implements kernel `Json.decodeValue`.
HPtr Elm_Kernel_Json_decodeValue();
/// Implements kernel `Json.succeed`.
HPtr Elm_Kernel_Json_succeed(HPtr value);
/// Implements kernel `Json.fail`.
HPtr Elm_Kernel_Json_fail(HPtr message);
/// Implements kernel `Json.andThen`.
HPtr Elm_Kernel_Json_andThen(HPtr closure, HPtr decoder);
/// Implements kernel `Json.oneOf`.
HPtr Elm_Kernel_Json_oneOf(HPtr decoders);
/// Implements kernel `Json.map1`.
HPtr Elm_Kernel_Json_map1(HPtr closure, HPtr d1);
/// Implements kernel `Json.map2`.
HPtr Elm_Kernel_Json_map2(HPtr closure, HPtr d1, HPtr d2);
/// Implements kernel `Json.map3`.
HPtr Elm_Kernel_Json_map3(HPtr closure, HPtr d1, HPtr d2, HPtr d3);
/// Implements kernel `Json.map4`.
HPtr Elm_Kernel_Json_map4(HPtr closure, HPtr d1, HPtr d2, HPtr d3, HPtr d4);
/// Implements kernel `Json.map5`.
HPtr Elm_Kernel_Json_map5(HPtr closure, HPtr d1, HPtr d2, HPtr d3, HPtr d4, HPtr d5);
/// Implements kernel `Json.map6`.
HPtr Elm_Kernel_Json_map6(HPtr closure, HPtr d1, HPtr d2, HPtr d3, HPtr d4, HPtr d5, HPtr d6);
/// Implements kernel `Json.map7`.
HPtr Elm_Kernel_Json_map7(HPtr closure, HPtr d1, HPtr d2, HPtr d3, HPtr d4, HPtr d5, HPtr d6, HPtr d7);
/// Implements kernel `Json.map8`.
HPtr Elm_Kernel_Json_map8(HPtr closure, HPtr d1, HPtr d2, HPtr d3, HPtr d4, HPtr d5, HPtr d6, HPtr d7, HPtr d8);
/// Implements kernel `Json.run`.
HPtr Elm_Kernel_Json_run(HPtr decoder, HPtr value);
/// Implements kernel `Json.runOnString`.
HPtr Elm_Kernel_Json_runOnString(HPtr decoder, HPtr jsonString);
/// Implements kernel `Json.encode`.
HPtr Elm_Kernel_Json_encode(int64_t indent, HPtr value);
/// Implements kernel `Json.wrap`.
HPtr Elm_Kernel_Json_wrap(HPtr value);
/// Implements kernel `Json.wrap` for Int: the Int-typed parameters arrive as raw `int64_t`.
HPtr Elm_Kernel_Json_wrap_Int  (int64_t  value);
/// Implements kernel `Json.wrap` for Float: the Float-typed parameters arrive as raw `double`.
HPtr Elm_Kernel_Json_wrap_Float(double   value);
/// Implements kernel `Json.wrap` for Char: the Char-typed parameters arrive as raw `uint64_t`.
HPtr Elm_Kernel_Json_wrap_Char (uint64_t value_raw);
/// Implements kernel `Json.encodeNull`.
HPtr Elm_Kernel_Json_encodeNull();
/// Implements kernel `Json.emptyArray`.
HPtr Elm_Kernel_Json_emptyArray();
/// Implements kernel `Json.emptyObject`.
HPtr Elm_Kernel_Json_emptyObject();
/// Implements kernel `Json.addEntry`.
HPtr Elm_Kernel_Json_addEntry(HPtr func, HPtr entry, HPtr array);
/// Implements kernel `Json.addField`.
HPtr Elm_Kernel_Json_addField(HPtr key, HPtr value, HPtr object);

//===----------------------------------------------------------------------===//
// Time Module (elm/time)
//===----------------------------------------------------------------------===//

/// Implements kernel `Time.now`.
HPtr Elm_Kernel_Time_now(HPtr millisToPosix);
/// Implements kernel `Time.here`.
HPtr Elm_Kernel_Time_here();
/// Implements kernel `Time.getZoneName`.
HPtr Elm_Kernel_Time_getZoneName();
/// Returns a subscription value, not a Task: a Custom with constructor `CTOR_TIME_EVERY` and fields `intervalMs` and
/// `task`, whatever `task` is. It starts no timer; the Time effect manager does that.
HPtr Elm_Kernel_Time_setInterval(double intervalMs, HPtr task);

//===----------------------------------------------------------------------===//
// Url Module (elm/url)
//===----------------------------------------------------------------------===//

/// Returns `str` with every UTF-8 byte outside `A-Za-z0-9-_.~` written as `%` and two hexadecimal digits. Unlike
/// JavaScript's `encodeURIComponent` it also escapes `!*'()`.
HPtr Elm_Kernel_Url_percentEncode(HPtr str);
/// Returns `Just` the String decoded from `str`'s percent escapes, with `+` turned into a space, or `Nothing` when a
/// `%` is followed by fewer than two bytes or by a byte that is not a hexadecimal digit. The decoded bytes
/// are not checked to be UTF-8; invalid sequences are decoded leniently, as `alloc::allocStringFromUTF8` does.
HPtr Elm_Kernel_Url_percentDecode(HPtr str);

//===----------------------------------------------------------------------===//
// Http Module (elm/http)
//===----------------------------------------------------------------------===//

/// Implements kernel `Http.emptyBody`.
HPtr Elm_Kernel_Http_emptyBody();
/// Implements kernel `Http.pair`.
HPtr Elm_Kernel_Http_pair(HPtr key, HPtr value);
/// Implements kernel `Http.toTask`.
HPtr Elm_Kernel_Http_toTask(HPtr router, HPtr resultToTask, HPtr request);
/// Implements kernel `Http.expect`.
HPtr Elm_Kernel_Http_expect(HPtr type, HPtr toBody, HPtr toValue);
/// Implements kernel `Http.mapExpect`.
HPtr Elm_Kernel_Http_mapExpect(HPtr closure, HPtr expectVal);
/// Implements kernel `Http.bytesToBlob`.
HPtr Elm_Kernel_Http_bytesToBlob(HPtr mimeType, HPtr bytes);
/// Implements kernel `Http.toDataView`.
HPtr Elm_Kernel_Http_toDataView(HPtr bytes);
/// Implements kernel `Http.toFormData`.
HPtr Elm_Kernel_Http_toFormData(HPtr parts);

//===----------------------------------------------------------------------===//
// Bytes Module (elm/bytes)
//===----------------------------------------------------------------------===//

/// Implements kernel `Bytes.width`.
HPtr Elm_Kernel_Bytes_width(HPtr bytes);
/// Implements kernel `Bytes.getHostEndianness`: returns a Task that succeeds with `le` on a little-endian host and
/// with `be` on a big-endian one.
HPtr Elm_Kernel_Bytes_getHostEndianness(HPtr le, HPtr be);
/// Implements kernel `Bytes.getStringWidth`.
int64_t Elm_Kernel_Bytes_getStringWidth(HPtr str);
/// Implements kernel `Bytes.encode`.
HPtr Elm_Kernel_Bytes_encode(HPtr encoder);
/// Implements kernel `Bytes.decode`: returns Nothing when a read or `fail` throws
/// `Elm::BytesDecodeFailure` below it.
HPtr Elm_Kernel_Bytes_decode(HPtr decoder, HPtr bytes);
/// Implements `Bytes.Decode.fail` by throwing `Elm::BytesDecodeFailure`.
HPtr Elm_Kernel_Bytes_decodeFailure();
// Each `read_*` reads at `offset` in `bytes` and returns `Tuple2(newOffset, value)`, the offset past what was read
// first. `isLE` is a Bool, True meaning little-endian. A read that runs past the end, or has a negative offset or
// length, throws `Elm::BytesDecodeFailure`, which only `Elm_Kernel_Bytes_decode` catches; so does `read_string` on
// malformed UTF-8. A `read_string` of length 0 returns `""` at any offset, unchecked.

/// Implements kernel `Bytes.read_i8`.
HPtr Elm_Kernel_Bytes_read_i8(HPtr bytes, int64_t offset);
/// Implements kernel `Bytes.read_i16`.
HPtr Elm_Kernel_Bytes_read_i16(HPtr isLE, HPtr bytes, int64_t offset);
/// Implements kernel `Bytes.read_i32`.
HPtr Elm_Kernel_Bytes_read_i32(HPtr isLE, HPtr bytes, int64_t offset);
/// Implements kernel `Bytes.read_u8`.
HPtr Elm_Kernel_Bytes_read_u8(HPtr bytes, int64_t offset);
/// Implements kernel `Bytes.read_u16`.
HPtr Elm_Kernel_Bytes_read_u16(HPtr isLE, HPtr bytes, int64_t offset);
/// Implements kernel `Bytes.read_u32`.
HPtr Elm_Kernel_Bytes_read_u32(HPtr isLE, HPtr bytes, int64_t offset);
/// Implements kernel `Bytes.read_f32`.
HPtr Elm_Kernel_Bytes_read_f32(HPtr isLE, HPtr bytes, int64_t offset);
/// Implements kernel `Bytes.read_f64`.
HPtr Elm_Kernel_Bytes_read_f64(HPtr isLE, HPtr bytes, int64_t offset);
/// Implements kernel `Bytes.read_bytes`.
HPtr Elm_Kernel_Bytes_read_bytes(int64_t length, HPtr bytes, int64_t offset);
/// Implements kernel `Bytes.read_string`.
HPtr Elm_Kernel_Bytes_read_string(int64_t length, HPtr bytes, int64_t offset);
/// Implements kernel `Bytes.write_i8`.
HPtr Elm_Kernel_Bytes_write_i8(int64_t value);
/// Implements kernel `Bytes.write_i16`.
HPtr Elm_Kernel_Bytes_write_i16(HPtr endianness, int64_t value);
/// Implements kernel `Bytes.write_i32`.
HPtr Elm_Kernel_Bytes_write_i32(HPtr endianness, int64_t value);
/// Implements kernel `Bytes.write_u8`.
HPtr Elm_Kernel_Bytes_write_u8(int64_t value);
/// Implements kernel `Bytes.write_u16`.
HPtr Elm_Kernel_Bytes_write_u16(HPtr endianness, int64_t value);
/// Implements kernel `Bytes.write_u32`.
HPtr Elm_Kernel_Bytes_write_u32(HPtr endianness, int64_t value);
/// Implements kernel `Bytes.write_f32`.
HPtr Elm_Kernel_Bytes_write_f32(HPtr endianness, double value);
/// Implements kernel `Bytes.write_f64`.
HPtr Elm_Kernel_Bytes_write_f64(HPtr endianness, double value);
/// Implements kernel `Bytes.write_bytes`.
HPtr Elm_Kernel_Bytes_write_bytes(HPtr bytes);
/// Implements kernel `Bytes.write_string`.
HPtr Elm_Kernel_Bytes_write_string(HPtr str);

//===----------------------------------------------------------------------===//
// File Module (elm/file) - STUBS
//===----------------------------------------------------------------------===//

/// Stands in for kernel `File.decoder`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_File_decoder();
/// Stands in for kernel `File.name`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_File_name(HPtr file);
/// Stands in for kernel `File.mime`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_File_mime(HPtr file);
/// Stands in for kernel `File.size`: asserts when assertions are on, else returns 0.
int64_t Elm_Kernel_File_size(HPtr file);
/// Stands in for kernel `File.lastModified`: asserts when assertions are on, else returns 0.
int64_t Elm_Kernel_File_lastModified(HPtr file);
/// Stands in for kernel `File.toString`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_File_toString(HPtr file);
/// Stands in for kernel `File.toBytes`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_File_toBytes(HPtr file);
/// Stands in for kernel `File.toUrl`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_File_toUrl(HPtr file);
/// Stands in for kernel `File.download`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_File_download(HPtr name, HPtr mime, HPtr content);
/// Stands in for kernel `File.downloadUrl`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_File_downloadUrl(HPtr name, HPtr url);
/// Stands in for kernel `File.uploadOne`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_File_uploadOne(HPtr mimes);
/// Stands in for kernel `File.uploadOneOrMore`: asserts when assertions are on, else returns word 0.
HPtr Elm_Kernel_File_uploadOneOrMore(HPtr mimes);
/// Implements kernel `File.makeBytesSafeForInternetExplorer`.
HPtr Elm_Kernel_File_makeBytesSafeForInternetExplorer(HPtr bytes);

//===----------------------------------------------------------------------===//
// Parser Module (elm/parser)
//===----------------------------------------------------------------------===//

/// Implements kernel `Parser.isSubChar`.
int64_t Elm_Kernel_Parser_isSubChar(HPtr closure, int64_t offset, HPtr str);
/// Implements kernel `Parser.isSubString`.
HPtr Elm_Kernel_Parser_isSubString(HPtr target, int64_t offset, int64_t row, int64_t col, HPtr str);
/// Implements kernel `Parser.findSubString`.
HPtr Elm_Kernel_Parser_findSubString(HPtr target, int64_t offset, int64_t row, int64_t col, HPtr str);
/// Implements kernel `Parser.chompBase10`.
int64_t Elm_Kernel_Parser_chompBase10(int64_t offset, HPtr str);
/// Implements kernel `Parser.consumeBase`.
HPtr Elm_Kernel_Parser_consumeBase(int64_t base, int64_t offset, HPtr str);
/// Implements kernel `Parser.consumeBase16`.
HPtr Elm_Kernel_Parser_consumeBase16(int64_t offset, HPtr str);
/// Implements kernel `Parser.isAsciiCode`.
HPtr Elm_Kernel_Parser_isAsciiCode(int64_t code, int64_t offset, HPtr str);

//===----------------------------------------------------------------------===//
// Regex Module (elm/regex)
//===----------------------------------------------------------------------===//

/// Implements kernel `Regex.never`.
HPtr Elm_Kernel_Regex_never();
/// Implements kernel `Regex.infinity`.
double Elm_Kernel_Regex_infinity();
/// Implements kernel `Regex.fromStringWith`.
HPtr Elm_Kernel_Regex_fromStringWith(HPtr options, HPtr pattern);
/// Implements kernel `Regex.contains`.
HPtr Elm_Kernel_Regex_contains(HPtr regex, HPtr str);
/// Implements kernel `Regex.findAtMost`.
HPtr Elm_Kernel_Regex_findAtMost(int64_t n, HPtr regex, HPtr str);
/// Implements kernel `Regex.replaceAtMost`.
HPtr Elm_Kernel_Regex_replaceAtMost(int64_t n, HPtr regex, HPtr closure, HPtr str);
/// Implements kernel `Regex.splitAtMost`.
HPtr Elm_Kernel_Regex_splitAtMost(int64_t n, HPtr regex, HPtr str);

//===----------------------------------------------------------------------===//
// Effect Manager Registration
//===----------------------------------------------------------------------===//

/// Registers the Time effect manager.
void eco_register_time_effect_manager();
/// Registers the Http effect manager.
void eco_register_http_effect_manager();
/// Registers the Task effect manager.
void eco_register_task_effect_manager();
/// Registers the Time, Http and Task effect managers, in that order. Runs on the eco thread once it has a heap, and
/// must run before `Platform.worker` sets up effects: a manager registered after `setupEffects` gets no
/// self-process, and its effects are never dispatched.
void eco_register_all_effect_managers();

} // extern "C"

#endif // ELM_KERNEL_EXPORTS_H
