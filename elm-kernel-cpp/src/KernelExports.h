//===- KernelExports.h - C-linkage wrappers for Elm kernel functions ------===//
//
// This file declares all kernel functions with extern "C" linkage so they can
// be found by the LLVM JIT. Functions are named using the pattern:
//   Elm_Kernel_<Module>_<function>
//
// All values are passed as uint64_t (encoded HPointer) or primitive types.
//
//===----------------------------------------------------------------------===//

#ifndef ELM_KERNEL_EXPORTS_H
#define ELM_KERNEL_EXPORTS_H

#include <cstdint>

extern "C" {

//===----------------------------------------------------------------------===//
// Basics Module
//===----------------------------------------------------------------------===//

double Elm_Kernel_Basics_acos(double x);
double Elm_Kernel_Basics_asin(double x);
double Elm_Kernel_Basics_atan(double x);
double Elm_Kernel_Basics_atan2(double y, double x);
double Elm_Kernel_Basics_cos(double x);
double Elm_Kernel_Basics_sin(double x);
double Elm_Kernel_Basics_tan(double x);
double Elm_Kernel_Basics_sqrt(double x);
double Elm_Kernel_Basics_log(double x);
double Elm_Kernel_Basics_pow(double base, double exp);
double Elm_Kernel_Basics_e();
double Elm_Kernel_Basics_pi();
double Elm_Kernel_Basics_add(double a, double b);
double Elm_Kernel_Basics_sub(double a, double b);
double Elm_Kernel_Basics_mul(double a, double b);
double Elm_Kernel_Basics_fdiv(double a, double b);
int64_t Elm_Kernel_Basics_idiv(int64_t a, int64_t b);
int64_t Elm_Kernel_Basics_modBy(int64_t modulus, int64_t x);
int64_t Elm_Kernel_Basics_remainderBy(int64_t divisor, int64_t x);
int64_t Elm_Kernel_Basics_ceiling(double x);
int64_t Elm_Kernel_Basics_floor(double x);
int64_t Elm_Kernel_Basics_round(double x);
int64_t Elm_Kernel_Basics_truncate(double x);
double Elm_Kernel_Basics_toFloat(int64_t x);
int64_t Elm_Kernel_Basics_isInfinite(double x);
int64_t Elm_Kernel_Basics_isNaN(double x);
int64_t Elm_Kernel_Basics_and(int64_t a, int64_t b);
int64_t Elm_Kernel_Basics_or(int64_t a, int64_t b);
int64_t Elm_Kernel_Basics_xor(int64_t a, int64_t b);
int64_t Elm_Kernel_Basics_not(int64_t a);

//===----------------------------------------------------------------------===//
// Bitwise Module
//===----------------------------------------------------------------------===//

int32_t Elm_Kernel_Bitwise_and(int32_t a, int32_t b);
int32_t Elm_Kernel_Bitwise_or(int32_t a, int32_t b);
int32_t Elm_Kernel_Bitwise_xor(int32_t a, int32_t b);
int32_t Elm_Kernel_Bitwise_complement(int32_t a);
int32_t Elm_Kernel_Bitwise_shiftLeftBy(int32_t offset, int32_t a);
int32_t Elm_Kernel_Bitwise_shiftRightBy(int32_t offset, int32_t a);
uint32_t Elm_Kernel_Bitwise_shiftRightZfBy(int32_t offset, int32_t a);

//===----------------------------------------------------------------------===//
// Char Module
//===----------------------------------------------------------------------===//

int32_t Elm_Kernel_Char_fromCode(int32_t code);
int32_t Elm_Kernel_Char_toCode(int32_t c);
int32_t Elm_Kernel_Char_toLower(int32_t c);
int32_t Elm_Kernel_Char_toUpper(int32_t c);
int32_t Elm_Kernel_Char_toLocaleLower(int32_t c);
int32_t Elm_Kernel_Char_toLocaleUpper(int32_t c);

//===----------------------------------------------------------------------===//
// String Module
//===----------------------------------------------------------------------===//

int64_t Elm_Kernel_String_length(uint64_t str);
uint64_t Elm_Kernel_String_append(uint64_t a, uint64_t b);
uint64_t Elm_Kernel_String_join(uint64_t sep, uint64_t stringList);
uint64_t Elm_Kernel_String_cons(uint32_t c, uint64_t str);
uint64_t Elm_Kernel_String_uncons(uint64_t str);
uint64_t Elm_Kernel_String_fromList(uint64_t chars);
uint64_t Elm_Kernel_String_slice(int64_t start, int64_t end, uint64_t str);
uint64_t Elm_Kernel_String_split(uint64_t sep, uint64_t str);
uint64_t Elm_Kernel_String_lines(uint64_t str);
uint64_t Elm_Kernel_String_words(uint64_t str);
uint64_t Elm_Kernel_String_reverse(uint64_t str);
uint64_t Elm_Kernel_String_toUpper(uint64_t str);
uint64_t Elm_Kernel_String_toLower(uint64_t str);
uint64_t Elm_Kernel_String_trim(uint64_t str);
uint64_t Elm_Kernel_String_trimLeft(uint64_t str);
uint64_t Elm_Kernel_String_trimRight(uint64_t str);
int64_t Elm_Kernel_String_startsWith(uint64_t prefix, uint64_t str);
int64_t Elm_Kernel_String_endsWith(uint64_t suffix, uint64_t str);
int64_t Elm_Kernel_String_contains(uint64_t needle, uint64_t haystack);
uint64_t Elm_Kernel_String_indexes(uint64_t needle, uint64_t haystack);
uint64_t Elm_Kernel_String_toInt(uint64_t str);
uint64_t Elm_Kernel_String_toFloat(uint64_t str);
uint64_t Elm_Kernel_String_fromNumber(uint64_t n);

//===----------------------------------------------------------------------===//
// List Module
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_List_cons(uint64_t head, uint64_t tail);

//===----------------------------------------------------------------------===//
// Utils Module
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_Utils_compare(uint64_t a, uint64_t b);
int64_t Elm_Kernel_Utils_equal(uint64_t a, uint64_t b);
int64_t Elm_Kernel_Utils_notEqual(uint64_t a, uint64_t b);
int64_t Elm_Kernel_Utils_lt(uint64_t a, uint64_t b);
int64_t Elm_Kernel_Utils_le(uint64_t a, uint64_t b);
int64_t Elm_Kernel_Utils_gt(uint64_t a, uint64_t b);
int64_t Elm_Kernel_Utils_ge(uint64_t a, uint64_t b);
uint64_t Elm_Kernel_Utils_append(uint64_t a, uint64_t b);

//===----------------------------------------------------------------------===//
// JsArray Module
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_JsArray_empty();
uint64_t Elm_Kernel_JsArray_singleton(uint64_t value);
uint32_t Elm_Kernel_JsArray_length(uint64_t array);
uint64_t Elm_Kernel_JsArray_unsafeGet(uint32_t index, uint64_t array);
uint64_t Elm_Kernel_JsArray_unsafeSet(uint32_t index, uint64_t value, uint64_t array);
uint64_t Elm_Kernel_JsArray_push(uint64_t value, uint64_t array);
uint64_t Elm_Kernel_JsArray_slice(int64_t start, int64_t end, uint64_t array);
uint64_t Elm_Kernel_JsArray_appendN(uint32_t n, uint64_t dest, uint64_t source);

//===----------------------------------------------------------------------===//
// VirtualDom Module
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_VirtualDom_text(uint64_t str);
uint64_t Elm_Kernel_VirtualDom_node(uint64_t tag, uint64_t factList, uint64_t kidList);
uint64_t Elm_Kernel_VirtualDom_nodeNS(uint64_t ns, uint64_t tag, uint64_t factList, uint64_t kidList);
uint64_t Elm_Kernel_VirtualDom_keyedNode(uint64_t tag, uint64_t factList, uint64_t keyedKidList);
uint64_t Elm_Kernel_VirtualDom_keyedNodeNS(uint64_t ns, uint64_t tag, uint64_t factList, uint64_t keyedKidList);
uint64_t Elm_Kernel_VirtualDom_attribute(uint64_t key, uint64_t value);
uint64_t Elm_Kernel_VirtualDom_attributeNS(uint64_t ns, uint64_t key, uint64_t value);
uint64_t Elm_Kernel_VirtualDom_property(uint64_t key, uint64_t value);
uint64_t Elm_Kernel_VirtualDom_style(uint64_t key, uint64_t value);

//===----------------------------------------------------------------------===//
// Debug Module
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_Debug_log(uint64_t tag, uint64_t value);
uint64_t Elm_Kernel_Debug_todo(uint64_t message);
uint64_t Elm_Kernel_Debug_toString(uint64_t value);

//===----------------------------------------------------------------------===//
// Platform Module
//===----------------------------------------------------------------------===//

// Platform functions are stubs for now

//===----------------------------------------------------------------------===//
// Scheduler Module
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_Scheduler_succeed(uint64_t value);
uint64_t Elm_Kernel_Scheduler_fail(uint64_t error);

} // extern "C"

#endif // ELM_KERNEL_EXPORTS_H
