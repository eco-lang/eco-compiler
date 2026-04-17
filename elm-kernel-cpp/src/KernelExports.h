//===- KernelExports.h - C-linkage wrappers for Elm kernel functions ------===//
//
// This file declares all kernel functions with extern "C" linkage so they can
// be found by the LLVM JIT. Functions are named using the pattern:
//   Elm_Kernel_<Module>_<function>
//
// Elm heap values are passed as HPtr (opaque 64-bit HPointer wrapper).
// Primitive types (int64_t, double, uint16_t, bool) are passed directly.
//
//===----------------------------------------------------------------------===//

#ifndef ELM_KERNEL_EXPORTS_H
#define ELM_KERNEL_EXPORTS_H

#include <cstdint>
#include "../../runtime/src/allocator/Heap.hpp"
using Elm::HPtr;

extern "C" {

//===----------------------------------------------------------------------===//
// Basics Module (elm/core)
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
// Polymorphic operations take HPointer (tagged Int or Float) and return boxed result.
// These examine the tag at runtime to determine whether to perform Int or Float arithmetic.
HPtr Elm_Kernel_Basics_pow(HPtr base, HPtr exp);
HPtr Elm_Kernel_Basics_add(HPtr a, HPtr b);
HPtr Elm_Kernel_Basics_sub(HPtr a, HPtr b);
HPtr Elm_Kernel_Basics_mul(HPtr a, HPtr b);
double Elm_Kernel_Basics_e();
double Elm_Kernel_Basics_pi();
double Elm_Kernel_Basics_fdiv(double a, double b);
int64_t Elm_Kernel_Basics_idiv(int64_t a, int64_t b);
int64_t Elm_Kernel_Basics_modBy(int64_t modulus, int64_t x);
int64_t Elm_Kernel_Basics_remainderBy(int64_t divisor, int64_t x);
int64_t Elm_Kernel_Basics_ceiling(double x);
int64_t Elm_Kernel_Basics_floor(double x);
int64_t Elm_Kernel_Basics_round(double x);
int64_t Elm_Kernel_Basics_truncate(double x);
double Elm_Kernel_Basics_toFloat(int64_t x);
HPtr Elm_Kernel_Basics_isInfinite(double x);
HPtr Elm_Kernel_Basics_isNaN(double x);
HPtr Elm_Kernel_Basics_and(HPtr a, HPtr b);
HPtr Elm_Kernel_Basics_or(HPtr a, HPtr b);
HPtr Elm_Kernel_Basics_xor(HPtr a, HPtr b);
HPtr Elm_Kernel_Basics_not(HPtr a);

//===----------------------------------------------------------------------===//
// Bitwise Module (elm/core)
//===----------------------------------------------------------------------===//

int64_t Elm_Kernel_Bitwise_and(int64_t a, int64_t b);
int64_t Elm_Kernel_Bitwise_or(int64_t a, int64_t b);
int64_t Elm_Kernel_Bitwise_xor(int64_t a, int64_t b);
int64_t Elm_Kernel_Bitwise_complement(int64_t a);
int64_t Elm_Kernel_Bitwise_shiftLeftBy(int64_t offset, int64_t a);
int64_t Elm_Kernel_Bitwise_shiftRightBy(int64_t offset, int64_t a);
uint64_t Elm_Kernel_Bitwise_shiftRightZfBy(int64_t offset, int64_t a);

//===----------------------------------------------------------------------===//
// Char Module (elm/core)
//===----------------------------------------------------------------------===//

uint16_t Elm_Kernel_Char_fromCode(int64_t code);
int64_t Elm_Kernel_Char_toCode(uint16_t c);
uint16_t Elm_Kernel_Char_toLower(uint16_t c);
uint16_t Elm_Kernel_Char_toUpper(uint16_t c);
uint16_t Elm_Kernel_Char_toLocaleLower(uint16_t c);
uint16_t Elm_Kernel_Char_toLocaleUpper(uint16_t c);

//===----------------------------------------------------------------------===//
// String Module (elm/core)
//===----------------------------------------------------------------------===//

int64_t Elm_Kernel_String_length(HPtr str);
HPtr Elm_Kernel_String_append(HPtr a, HPtr b);
HPtr Elm_Kernel_String_join(HPtr sep, HPtr stringList);
HPtr Elm_Kernel_String_cons(uint16_t c, HPtr str);
HPtr Elm_Kernel_String_uncons(HPtr str);
HPtr Elm_Kernel_String_fromList(HPtr chars);
HPtr Elm_Kernel_String_slice(int64_t start, int64_t end, HPtr str);
HPtr Elm_Kernel_String_split(HPtr sep, HPtr str);
HPtr Elm_Kernel_String_lines(HPtr str);
HPtr Elm_Kernel_String_words(HPtr str);
HPtr Elm_Kernel_String_reverse(HPtr str);
HPtr Elm_Kernel_String_toUpper(HPtr str);
HPtr Elm_Kernel_String_toLower(HPtr str);
HPtr Elm_Kernel_String_trim(HPtr str);
HPtr Elm_Kernel_String_trimLeft(HPtr str);
HPtr Elm_Kernel_String_trimRight(HPtr str);
HPtr Elm_Kernel_String_startsWith(HPtr prefix, HPtr str);
HPtr Elm_Kernel_String_endsWith(HPtr suffix, HPtr str);
HPtr Elm_Kernel_String_contains(HPtr needle, HPtr haystack);
HPtr Elm_Kernel_String_indexes(HPtr needle, HPtr haystack);
HPtr Elm_Kernel_String_toInt(HPtr str);
HPtr Elm_Kernel_String_toFloat(HPtr str);
HPtr Elm_Kernel_String_fromNumber(HPtr n);
// Higher-order String functions (closure is a pointer to Closure object)
HPtr Elm_Kernel_String_map(HPtr closure, HPtr str);
HPtr Elm_Kernel_String_filter(HPtr closure, HPtr str);
HPtr Elm_Kernel_String_any(HPtr closure, HPtr str);
HPtr Elm_Kernel_String_all(HPtr closure, HPtr str);
HPtr Elm_Kernel_String_foldl(HPtr closure, HPtr acc, HPtr str);
HPtr Elm_Kernel_String_foldr(HPtr closure, HPtr acc, HPtr str);

//===----------------------------------------------------------------------===//
// List Module (elm/core)
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_List_cons(HPtr head, HPtr tail);
HPtr Elm_Kernel_List_fromArray(HPtr array);
HPtr Elm_Kernel_List_toArray(HPtr list);
// Higher-order List functions
HPtr Elm_Kernel_List_map2(HPtr closure, HPtr xs, HPtr ys);
HPtr Elm_Kernel_List_map3(HPtr closure, HPtr xs, HPtr ys, HPtr zs);
HPtr Elm_Kernel_List_map4(HPtr closure, HPtr ws, HPtr xs, HPtr ys, HPtr zs);
HPtr Elm_Kernel_List_map5(HPtr closure, HPtr vs, HPtr ws, HPtr xs, HPtr ys, HPtr zs);
HPtr Elm_Kernel_List_sortBy(HPtr closure, HPtr list);
HPtr Elm_Kernel_List_sortWith(HPtr closure, HPtr list);

//===----------------------------------------------------------------------===//
// Utils Module (elm/core)
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_Utils_compare(HPtr a, HPtr b);
HPtr Elm_Kernel_Utils_equal(HPtr a, HPtr b);
HPtr Elm_Kernel_Utils_notEqual(HPtr a, HPtr b);
HPtr Elm_Kernel_Utils_lt(HPtr a, HPtr b);
HPtr Elm_Kernel_Utils_le(HPtr a, HPtr b);
HPtr Elm_Kernel_Utils_gt(HPtr a, HPtr b);
HPtr Elm_Kernel_Utils_ge(HPtr a, HPtr b);
HPtr Elm_Kernel_Utils_append(HPtr a, HPtr b);

//===----------------------------------------------------------------------===//
// JsArray Module (elm/core)
//===----------------------------------------------------------------------===//

// AllBoxed ABI: all params and returns are HPtr (boxed eco.value).
// Integer arguments (index, length, etc.) arrive as boxed Elm Int HPointers
// and are unboxed inside the implementation.
HPtr Elm_Kernel_JsArray_empty();
HPtr Elm_Kernel_JsArray_singleton(HPtr value);
HPtr Elm_Kernel_JsArray_length(HPtr array);
HPtr Elm_Kernel_JsArray_unsafeGet(HPtr index, HPtr array);
HPtr Elm_Kernel_JsArray_unsafeSet(HPtr index, HPtr value, HPtr array);
HPtr Elm_Kernel_JsArray_push(HPtr value, HPtr array);
HPtr Elm_Kernel_JsArray_slice(HPtr start, HPtr end, HPtr array);
HPtr Elm_Kernel_JsArray_appendN(HPtr n, HPtr dest, HPtr source);
// Higher-order JsArray functions
HPtr Elm_Kernel_JsArray_initialize(HPtr size, HPtr offset, HPtr closure);
HPtr Elm_Kernel_JsArray_initializeFromList(HPtr max, HPtr list);
HPtr Elm_Kernel_JsArray_map(HPtr closure, HPtr array);
HPtr Elm_Kernel_JsArray_indexedMap(HPtr closure, HPtr offset, HPtr array);
HPtr Elm_Kernel_JsArray_foldl(HPtr closure, HPtr acc, HPtr array);
HPtr Elm_Kernel_JsArray_foldr(HPtr closure, HPtr acc, HPtr array);

//===----------------------------------------------------------------------===//
// Debug Module (elm/core)
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_Debug_log(HPtr tag, HPtr value);
HPtr Elm_Kernel_Debug_todo(HPtr message);
HPtr Elm_Kernel_Debug_toString(HPtr value, int64_t type_id);

//===----------------------------------------------------------------------===//
// Platform Module (elm/core)
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_Platform_batch(HPtr commands);
HPtr Elm_Kernel_Platform_map(HPtr closure, HPtr cmd);
void Elm_Kernel_Platform_sendToApp(HPtr router, HPtr msg);
HPtr Elm_Kernel_Platform_sendToSelf(HPtr router, HPtr msg);
HPtr Elm_Kernel_Platform_worker(HPtr impl);
HPtr Elm_Kernel_Platform_leaf(HPtr home, HPtr value);

//===----------------------------------------------------------------------===//
// Process Module (elm/core)
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_Process_sleep(double time);

//===----------------------------------------------------------------------===//
// Scheduler Module (elm/core)
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_Scheduler_succeed(HPtr value);
HPtr Elm_Kernel_Scheduler_fail(HPtr error);
HPtr Elm_Kernel_Scheduler_andThen(HPtr closure, HPtr task);
HPtr Elm_Kernel_Scheduler_onError(HPtr closure, HPtr task);
HPtr Elm_Kernel_Scheduler_spawn(HPtr task);
HPtr Elm_Kernel_Scheduler_kill(HPtr process);

//===----------------------------------------------------------------------===//
// VirtualDom Module (elm/virtual-dom)
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_VirtualDom_text(HPtr str);
HPtr Elm_Kernel_VirtualDom_node(HPtr tag, HPtr factList, HPtr kidList);
HPtr Elm_Kernel_VirtualDom_nodeNS(HPtr ns, HPtr tag, HPtr factList, HPtr kidList);
HPtr Elm_Kernel_VirtualDom_keyedNode(HPtr tag, HPtr factList, HPtr keyedKidList);
HPtr Elm_Kernel_VirtualDom_keyedNodeNS(HPtr ns, HPtr tag, HPtr factList, HPtr keyedKidList);
HPtr Elm_Kernel_VirtualDom_attribute(HPtr key, HPtr value);
HPtr Elm_Kernel_VirtualDom_attributeNS(HPtr ns, HPtr key, HPtr value);
HPtr Elm_Kernel_VirtualDom_property(HPtr key, HPtr value);
HPtr Elm_Kernel_VirtualDom_style(HPtr key, HPtr value);
HPtr Elm_Kernel_VirtualDom_on(HPtr event, HPtr decoder);
HPtr Elm_Kernel_VirtualDom_map(HPtr closure, HPtr vnode);
HPtr Elm_Kernel_VirtualDom_mapAttribute(HPtr closure, HPtr fact);
HPtr Elm_Kernel_VirtualDom_lazy(HPtr closure, HPtr arg);
HPtr Elm_Kernel_VirtualDom_lazy2(HPtr closure, HPtr a, HPtr b);
HPtr Elm_Kernel_VirtualDom_lazy3(HPtr closure, HPtr a, HPtr b, HPtr c);
HPtr Elm_Kernel_VirtualDom_lazy4(HPtr closure, HPtr a, HPtr b, HPtr c, HPtr d);
HPtr Elm_Kernel_VirtualDom_lazy5(HPtr closure, HPtr a, HPtr b, HPtr c, HPtr d, HPtr e);
HPtr Elm_Kernel_VirtualDom_lazy6(HPtr closure, HPtr a, HPtr b, HPtr c, HPtr d, HPtr e, HPtr f);
HPtr Elm_Kernel_VirtualDom_lazy7(HPtr closure, HPtr a, HPtr b, HPtr c, HPtr d, HPtr e, HPtr f, HPtr g);
HPtr Elm_Kernel_VirtualDom_lazy8(HPtr closure, HPtr a, HPtr b, HPtr c, HPtr d, HPtr e, HPtr f, HPtr g, HPtr h);
HPtr Elm_Kernel_VirtualDom_noScript(HPtr tag);
HPtr Elm_Kernel_VirtualDom_noOnOrFormAction(HPtr key);
HPtr Elm_Kernel_VirtualDom_noInnerHtmlOrFormAction(HPtr key);
HPtr Elm_Kernel_VirtualDom_noJavaScriptOrHtmlUri(HPtr value);
HPtr Elm_Kernel_VirtualDom_noJavaScriptOrHtmlJson(HPtr value);

//===----------------------------------------------------------------------===//
// Browser Module (elm/browser)
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_Browser_element(HPtr impl);
HPtr Elm_Kernel_Browser_document(HPtr impl);
HPtr Elm_Kernel_Browser_application(HPtr impl);
HPtr Elm_Kernel_Browser_load(HPtr url);
HPtr Elm_Kernel_Browser_reload(bool skipCache);
HPtr Elm_Kernel_Browser_pushUrl(HPtr key, HPtr url);
HPtr Elm_Kernel_Browser_replaceUrl(HPtr key, HPtr url);
HPtr Elm_Kernel_Browser_go(HPtr key, int64_t steps);
HPtr Elm_Kernel_Browser_getViewport();
HPtr Elm_Kernel_Browser_getViewportOf(HPtr id);
HPtr Elm_Kernel_Browser_setViewport(double x, double y);
HPtr Elm_Kernel_Browser_setViewportOf(HPtr id, double x, double y);
HPtr Elm_Kernel_Browser_getElement(HPtr id);
HPtr Elm_Kernel_Browser_on(HPtr node, HPtr eventName, HPtr handler);
HPtr Elm_Kernel_Browser_decodeEvent(HPtr decoder, HPtr event);
HPtr Elm_Kernel_Browser_doc();
HPtr Elm_Kernel_Browser_window();
HPtr Elm_Kernel_Browser_withWindow(HPtr closure);
HPtr Elm_Kernel_Browser_rAF();
HPtr Elm_Kernel_Browser_now();
HPtr Elm_Kernel_Browser_visibilityInfo();
HPtr Elm_Kernel_Browser_call(HPtr closure);

//===----------------------------------------------------------------------===//
// Debugger Module (elm/browser)
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_Debugger_init(HPtr value);
HPtr Elm_Kernel_Debugger_isOpen(HPtr popout);
HPtr Elm_Kernel_Debugger_open(HPtr popout);
HPtr Elm_Kernel_Debugger_scroll(HPtr popout);
HPtr Elm_Kernel_Debugger_messageToString(HPtr message);
HPtr Elm_Kernel_Debugger_download(int64_t historyLength, HPtr json);
HPtr Elm_Kernel_Debugger_upload();
HPtr Elm_Kernel_Debugger_unsafeCoerce(HPtr value);

//===----------------------------------------------------------------------===//
// Json Module (elm/json)
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_Json_decodeString();
HPtr Elm_Kernel_Json_decodeBool();
HPtr Elm_Kernel_Json_decodeInt();
HPtr Elm_Kernel_Json_decodeFloat();
HPtr Elm_Kernel_Json_decodeNull(HPtr fallback);
HPtr Elm_Kernel_Json_decodeList(HPtr decoder);
HPtr Elm_Kernel_Json_decodeArray(HPtr decoder);
HPtr Elm_Kernel_Json_decodeField(HPtr fieldName, HPtr decoder);
HPtr Elm_Kernel_Json_decodeIndex(int64_t index, HPtr decoder);
HPtr Elm_Kernel_Json_decodeKeyValuePairs(HPtr decoder);
HPtr Elm_Kernel_Json_decodeValue();
HPtr Elm_Kernel_Json_succeed(HPtr value);
HPtr Elm_Kernel_Json_fail(HPtr message);
HPtr Elm_Kernel_Json_andThen(HPtr closure, HPtr decoder);
HPtr Elm_Kernel_Json_oneOf(HPtr decoders);
HPtr Elm_Kernel_Json_map1(HPtr closure, HPtr d1);
HPtr Elm_Kernel_Json_map2(HPtr closure, HPtr d1, HPtr d2);
HPtr Elm_Kernel_Json_map3(HPtr closure, HPtr d1, HPtr d2, HPtr d3);
HPtr Elm_Kernel_Json_map4(HPtr closure, HPtr d1, HPtr d2, HPtr d3, HPtr d4);
HPtr Elm_Kernel_Json_map5(HPtr closure, HPtr d1, HPtr d2, HPtr d3, HPtr d4, HPtr d5);
HPtr Elm_Kernel_Json_map6(HPtr closure, HPtr d1, HPtr d2, HPtr d3, HPtr d4, HPtr d5, HPtr d6);
HPtr Elm_Kernel_Json_map7(HPtr closure, HPtr d1, HPtr d2, HPtr d3, HPtr d4, HPtr d5, HPtr d6, HPtr d7);
HPtr Elm_Kernel_Json_map8(HPtr closure, HPtr d1, HPtr d2, HPtr d3, HPtr d4, HPtr d5, HPtr d6, HPtr d7, HPtr d8);
HPtr Elm_Kernel_Json_run(HPtr decoder, HPtr value);
HPtr Elm_Kernel_Json_runOnString(HPtr decoder, HPtr jsonString);
HPtr Elm_Kernel_Json_encode(int64_t indent, HPtr value);
HPtr Elm_Kernel_Json_wrap(HPtr value);
HPtr Elm_Kernel_Json_encodeNull();
HPtr Elm_Kernel_Json_emptyArray();
HPtr Elm_Kernel_Json_emptyObject();
HPtr Elm_Kernel_Json_addEntry(HPtr func, HPtr entry, HPtr array);
HPtr Elm_Kernel_Json_addField(HPtr key, HPtr value, HPtr object);

//===----------------------------------------------------------------------===//
// Time Module (elm/time)
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_Time_now();
HPtr Elm_Kernel_Time_here();
HPtr Elm_Kernel_Time_getZoneName();
HPtr Elm_Kernel_Time_setInterval(double intervalMs, HPtr task);

//===----------------------------------------------------------------------===//
// Url Module (elm/url)
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_Url_percentEncode(HPtr str);
HPtr Elm_Kernel_Url_percentDecode(HPtr str);

//===----------------------------------------------------------------------===//
// Http Module (elm/http)
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_Http_emptyBody();
HPtr Elm_Kernel_Http_pair(HPtr key, HPtr value);
HPtr Elm_Kernel_Http_toTask(HPtr request);
HPtr Elm_Kernel_Http_expect(HPtr responseToResult);
HPtr Elm_Kernel_Http_mapExpect(HPtr closure, HPtr expectVal);
HPtr Elm_Kernel_Http_bytesToBlob(HPtr bytes, HPtr mimeType);
HPtr Elm_Kernel_Http_toDataView(HPtr bytes);
HPtr Elm_Kernel_Http_toFormData(HPtr parts);

//===----------------------------------------------------------------------===//
// Bytes Module (elm/bytes) - STUBS
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_Bytes_width(HPtr bytes);
HPtr Elm_Kernel_Bytes_getHostEndianness();
int64_t Elm_Kernel_Bytes_getStringWidth(HPtr str);
HPtr Elm_Kernel_Bytes_encode(HPtr encoder);
HPtr Elm_Kernel_Bytes_decode(HPtr decoder, HPtr bytes);
HPtr Elm_Kernel_Bytes_decodeFailure();
HPtr Elm_Kernel_Bytes_read_i8(HPtr bytes, int64_t offset);
HPtr Elm_Kernel_Bytes_read_i16(HPtr isLE, HPtr bytes, int64_t offset);
HPtr Elm_Kernel_Bytes_read_i32(HPtr isLE, HPtr bytes, int64_t offset);
HPtr Elm_Kernel_Bytes_read_u8(HPtr bytes, int64_t offset);
HPtr Elm_Kernel_Bytes_read_u16(HPtr isLE, HPtr bytes, int64_t offset);
HPtr Elm_Kernel_Bytes_read_u32(HPtr isLE, HPtr bytes, int64_t offset);
HPtr Elm_Kernel_Bytes_read_f32(HPtr isLE, HPtr bytes, int64_t offset);
HPtr Elm_Kernel_Bytes_read_f64(HPtr isLE, HPtr bytes, int64_t offset);
HPtr Elm_Kernel_Bytes_read_bytes(int64_t length, HPtr bytes, int64_t offset);
HPtr Elm_Kernel_Bytes_read_string(int64_t length, HPtr bytes, int64_t offset);
// Write functions create Encoder tree nodes (Custom types)
// Endianness parameter is eco.value (LE=ctor 0, BE=ctor 1), NOT bool
HPtr Elm_Kernel_Bytes_write_i8(int64_t value);
HPtr Elm_Kernel_Bytes_write_i16(HPtr endianness, int64_t value);
HPtr Elm_Kernel_Bytes_write_i32(HPtr endianness, int64_t value);
HPtr Elm_Kernel_Bytes_write_u8(int64_t value);
HPtr Elm_Kernel_Bytes_write_u16(HPtr endianness, int64_t value);
HPtr Elm_Kernel_Bytes_write_u32(HPtr endianness, int64_t value);
HPtr Elm_Kernel_Bytes_write_f32(HPtr endianness, double value);
HPtr Elm_Kernel_Bytes_write_f64(HPtr endianness, double value);
HPtr Elm_Kernel_Bytes_write_bytes(HPtr bytes);
HPtr Elm_Kernel_Bytes_write_string(HPtr str);

//===----------------------------------------------------------------------===//
// File Module (elm/file) - STUBS
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_File_decoder();
HPtr Elm_Kernel_File_name(HPtr file);
HPtr Elm_Kernel_File_mime(HPtr file);
int64_t Elm_Kernel_File_size(HPtr file);
int64_t Elm_Kernel_File_lastModified(HPtr file);
HPtr Elm_Kernel_File_toString(HPtr file);
HPtr Elm_Kernel_File_toBytes(HPtr file);
HPtr Elm_Kernel_File_toUrl(HPtr file);
HPtr Elm_Kernel_File_download(HPtr name, HPtr mime, HPtr content);
HPtr Elm_Kernel_File_downloadUrl(HPtr name, HPtr url);
HPtr Elm_Kernel_File_uploadOne(HPtr mimes);
HPtr Elm_Kernel_File_uploadOneOrMore(HPtr mimes);
HPtr Elm_Kernel_File_makeBytesSafeForInternetExplorer(HPtr bytes);

//===----------------------------------------------------------------------===//
// Parser Module (elm/parser) - STUBS
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_Parser_isSubChar(HPtr closure, int64_t offset, HPtr str);
HPtr Elm_Kernel_Parser_isSubString(HPtr target, int64_t offset, int64_t row, int64_t col, HPtr str);
int64_t Elm_Kernel_Parser_findSubString(HPtr target, int64_t offset, int64_t row, int64_t col, HPtr str);
HPtr Elm_Kernel_Parser_chompBase10(int64_t offset, HPtr str);
HPtr Elm_Kernel_Parser_consumeBase(int64_t base, int64_t offset, HPtr str);
HPtr Elm_Kernel_Parser_consumeBase16(int64_t offset, HPtr str);
HPtr Elm_Kernel_Parser_isAsciiCode(int64_t code, int64_t offset, HPtr str);

//===----------------------------------------------------------------------===//
// Regex Module (elm/regex) - STUBS
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_Regex_never();
double Elm_Kernel_Regex_infinity();
HPtr Elm_Kernel_Regex_fromStringWith(HPtr options, HPtr pattern);
HPtr Elm_Kernel_Regex_contains(HPtr regex, HPtr str);
HPtr Elm_Kernel_Regex_findAtMost(int64_t n, HPtr regex, HPtr str);
HPtr Elm_Kernel_Regex_replaceAtMost(int64_t n, HPtr regex, HPtr closure, HPtr str);
HPtr Elm_Kernel_Regex_splitAtMost(int64_t n, HPtr regex, HPtr str);

//===----------------------------------------------------------------------===//
// Effect Manager Registration
//===----------------------------------------------------------------------===//

void eco_register_time_effect_manager();
void eco_register_http_effect_manager();
void eco_register_task_effect_manager();
void eco_register_all_effect_managers();

} // extern "C"

#endif // ELM_KERNEL_EXPORTS_H
