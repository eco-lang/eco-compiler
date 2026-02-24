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
uint64_t Elm_Kernel_Basics_pow(uint64_t base, uint64_t exp);
uint64_t Elm_Kernel_Basics_add(uint64_t a, uint64_t b);
uint64_t Elm_Kernel_Basics_sub(uint64_t a, uint64_t b);
uint64_t Elm_Kernel_Basics_mul(uint64_t a, uint64_t b);
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
uint64_t Elm_Kernel_Basics_isInfinite(double x);
uint64_t Elm_Kernel_Basics_isNaN(double x);
uint64_t Elm_Kernel_Basics_and(uint64_t a, uint64_t b);
uint64_t Elm_Kernel_Basics_or(uint64_t a, uint64_t b);
uint64_t Elm_Kernel_Basics_xor(uint64_t a, uint64_t b);
uint64_t Elm_Kernel_Basics_not(uint64_t a);

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

int64_t Elm_Kernel_String_length(uint64_t str);
uint64_t Elm_Kernel_String_append(uint64_t a, uint64_t b);
uint64_t Elm_Kernel_String_join(uint64_t sep, uint64_t stringList);
uint64_t Elm_Kernel_String_cons(uint16_t c, uint64_t str);
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
uint64_t Elm_Kernel_String_startsWith(uint64_t prefix, uint64_t str);
uint64_t Elm_Kernel_String_endsWith(uint64_t suffix, uint64_t str);
uint64_t Elm_Kernel_String_contains(uint64_t needle, uint64_t haystack);
uint64_t Elm_Kernel_String_indexes(uint64_t needle, uint64_t haystack);
uint64_t Elm_Kernel_String_toInt(uint64_t str);
uint64_t Elm_Kernel_String_toFloat(uint64_t str);
uint64_t Elm_Kernel_String_fromNumber(uint64_t n);
// Higher-order String functions (closure is a pointer to Closure object)
uint64_t Elm_Kernel_String_map(uint64_t closure, uint64_t str);
uint64_t Elm_Kernel_String_filter(uint64_t closure, uint64_t str);
uint64_t Elm_Kernel_String_any(uint64_t closure, uint64_t str);
uint64_t Elm_Kernel_String_all(uint64_t closure, uint64_t str);
uint64_t Elm_Kernel_String_foldl(uint64_t closure, uint64_t acc, uint64_t str);
uint64_t Elm_Kernel_String_foldr(uint64_t closure, uint64_t acc, uint64_t str);

//===----------------------------------------------------------------------===//
// List Module (elm/core)
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_List_cons(uint64_t head, uint64_t tail);
uint64_t Elm_Kernel_List_fromArray(uint64_t array);
uint64_t Elm_Kernel_List_toArray(uint64_t list);
// Higher-order List functions
uint64_t Elm_Kernel_List_map2(uint64_t closure, uint64_t xs, uint64_t ys);
uint64_t Elm_Kernel_List_map3(uint64_t closure, uint64_t xs, uint64_t ys, uint64_t zs);
uint64_t Elm_Kernel_List_map4(uint64_t closure, uint64_t ws, uint64_t xs, uint64_t ys, uint64_t zs);
uint64_t Elm_Kernel_List_map5(uint64_t closure, uint64_t vs, uint64_t ws, uint64_t xs, uint64_t ys, uint64_t zs);
uint64_t Elm_Kernel_List_sortBy(uint64_t closure, uint64_t list);
uint64_t Elm_Kernel_List_sortWith(uint64_t closure, uint64_t list);

//===----------------------------------------------------------------------===//
// Utils Module (elm/core)
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_Utils_compare(uint64_t a, uint64_t b);
uint64_t Elm_Kernel_Utils_equal(uint64_t a, uint64_t b);
uint64_t Elm_Kernel_Utils_notEqual(uint64_t a, uint64_t b);
uint64_t Elm_Kernel_Utils_lt(uint64_t a, uint64_t b);
uint64_t Elm_Kernel_Utils_le(uint64_t a, uint64_t b);
uint64_t Elm_Kernel_Utils_gt(uint64_t a, uint64_t b);
uint64_t Elm_Kernel_Utils_ge(uint64_t a, uint64_t b);
uint64_t Elm_Kernel_Utils_append(uint64_t a, uint64_t b);

//===----------------------------------------------------------------------===//
// JsArray Module (elm/core)
//===----------------------------------------------------------------------===//

// AllBoxed ABI: all params and returns are uint64_t (boxed eco.value).
// Integer arguments (index, length, etc.) arrive as boxed Elm Int HPointers
// and are unboxed inside the implementation.
uint64_t Elm_Kernel_JsArray_empty();
uint64_t Elm_Kernel_JsArray_singleton(uint64_t value);
uint64_t Elm_Kernel_JsArray_length(uint64_t array);
uint64_t Elm_Kernel_JsArray_unsafeGet(uint64_t index, uint64_t array);
uint64_t Elm_Kernel_JsArray_unsafeSet(uint64_t index, uint64_t value, uint64_t array);
uint64_t Elm_Kernel_JsArray_push(uint64_t value, uint64_t array);
uint64_t Elm_Kernel_JsArray_slice(uint64_t start, uint64_t end, uint64_t array);
uint64_t Elm_Kernel_JsArray_appendN(uint64_t n, uint64_t dest, uint64_t source);
// Higher-order JsArray functions
uint64_t Elm_Kernel_JsArray_initialize(uint64_t size, uint64_t offset, uint64_t closure);
uint64_t Elm_Kernel_JsArray_initializeFromList(uint64_t max, uint64_t list);
uint64_t Elm_Kernel_JsArray_map(uint64_t closure, uint64_t array);
uint64_t Elm_Kernel_JsArray_indexedMap(uint64_t closure, uint64_t offset, uint64_t array);
uint64_t Elm_Kernel_JsArray_foldl(uint64_t closure, uint64_t acc, uint64_t array);
uint64_t Elm_Kernel_JsArray_foldr(uint64_t closure, uint64_t acc, uint64_t array);

//===----------------------------------------------------------------------===//
// Debug Module (elm/core)
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_Debug_log(uint64_t tag, uint64_t value);
uint64_t Elm_Kernel_Debug_todo(uint64_t message);
uint64_t Elm_Kernel_Debug_toString(uint64_t value, int64_t type_id);

//===----------------------------------------------------------------------===//
// Platform Module (elm/core)
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_Platform_batch(uint64_t commands);
uint64_t Elm_Kernel_Platform_map(uint64_t closure, uint64_t cmd);
void Elm_Kernel_Platform_sendToApp(uint64_t router, uint64_t msg);
uint64_t Elm_Kernel_Platform_sendToSelf(uint64_t router, uint64_t msg);
uint64_t Elm_Kernel_Platform_worker(uint64_t impl);

//===----------------------------------------------------------------------===//
// Process Module (elm/core)
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_Process_sleep(double time);

//===----------------------------------------------------------------------===//
// Scheduler Module (elm/core)
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_Scheduler_succeed(uint64_t value);
uint64_t Elm_Kernel_Scheduler_fail(uint64_t error);
uint64_t Elm_Kernel_Scheduler_andThen(uint64_t closure, uint64_t task);
uint64_t Elm_Kernel_Scheduler_onError(uint64_t closure, uint64_t task);
uint64_t Elm_Kernel_Scheduler_spawn(uint64_t task);
uint64_t Elm_Kernel_Scheduler_kill(uint64_t process);

//===----------------------------------------------------------------------===//
// VirtualDom Module (elm/virtual-dom)
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
uint64_t Elm_Kernel_VirtualDom_on(uint64_t event, uint64_t decoder);
uint64_t Elm_Kernel_VirtualDom_map(uint64_t closure, uint64_t vnode);
uint64_t Elm_Kernel_VirtualDom_mapAttribute(uint64_t closure, uint64_t fact);
uint64_t Elm_Kernel_VirtualDom_lazy(uint64_t closure, uint64_t arg);
uint64_t Elm_Kernel_VirtualDom_lazy2(uint64_t closure, uint64_t a, uint64_t b);
uint64_t Elm_Kernel_VirtualDom_lazy3(uint64_t closure, uint64_t a, uint64_t b, uint64_t c);
uint64_t Elm_Kernel_VirtualDom_lazy4(uint64_t closure, uint64_t a, uint64_t b, uint64_t c, uint64_t d);
uint64_t Elm_Kernel_VirtualDom_lazy5(uint64_t closure, uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t e);
uint64_t Elm_Kernel_VirtualDom_lazy6(uint64_t closure, uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t e, uint64_t f);
uint64_t Elm_Kernel_VirtualDom_lazy7(uint64_t closure, uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t e, uint64_t f, uint64_t g);
uint64_t Elm_Kernel_VirtualDom_lazy8(uint64_t closure, uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t e, uint64_t f, uint64_t g, uint64_t h);
uint64_t Elm_Kernel_VirtualDom_noScript(uint64_t tag);
uint64_t Elm_Kernel_VirtualDom_noOnOrFormAction(uint64_t key);
uint64_t Elm_Kernel_VirtualDom_noInnerHtmlOrFormAction(uint64_t key);
uint64_t Elm_Kernel_VirtualDom_noJavaScriptOrHtmlUri(uint64_t value);
uint64_t Elm_Kernel_VirtualDom_noJavaScriptOrHtmlJson(uint64_t value);

//===----------------------------------------------------------------------===//
// Browser Module (elm/browser)
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_Browser_element(uint64_t impl);
uint64_t Elm_Kernel_Browser_document(uint64_t impl);
uint64_t Elm_Kernel_Browser_application(uint64_t impl);
uint64_t Elm_Kernel_Browser_load(uint64_t url);
uint64_t Elm_Kernel_Browser_reload(bool skipCache);
uint64_t Elm_Kernel_Browser_pushUrl(uint64_t key, uint64_t url);
uint64_t Elm_Kernel_Browser_replaceUrl(uint64_t key, uint64_t url);
uint64_t Elm_Kernel_Browser_go(uint64_t key, int64_t steps);
uint64_t Elm_Kernel_Browser_getViewport();
uint64_t Elm_Kernel_Browser_getViewportOf(uint64_t id);
uint64_t Elm_Kernel_Browser_setViewport(double x, double y);
uint64_t Elm_Kernel_Browser_setViewportOf(uint64_t id, double x, double y);
uint64_t Elm_Kernel_Browser_getElement(uint64_t id);
uint64_t Elm_Kernel_Browser_on(uint64_t node, uint64_t eventName, uint64_t handler);
uint64_t Elm_Kernel_Browser_decodeEvent(uint64_t decoder, uint64_t event);
uint64_t Elm_Kernel_Browser_doc();
uint64_t Elm_Kernel_Browser_window();
uint64_t Elm_Kernel_Browser_withWindow(uint64_t closure);
uint64_t Elm_Kernel_Browser_rAF();
uint64_t Elm_Kernel_Browser_now();
uint64_t Elm_Kernel_Browser_visibilityInfo();
uint64_t Elm_Kernel_Browser_call(uint64_t closure);

//===----------------------------------------------------------------------===//
// Debugger Module (elm/browser)
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_Debugger_init(uint64_t value);
uint64_t Elm_Kernel_Debugger_isOpen(uint64_t popout);
uint64_t Elm_Kernel_Debugger_open(uint64_t popout);
uint64_t Elm_Kernel_Debugger_scroll(uint64_t popout);
uint64_t Elm_Kernel_Debugger_messageToString(uint64_t message);
uint64_t Elm_Kernel_Debugger_download(int64_t historyLength, uint64_t json);
uint64_t Elm_Kernel_Debugger_upload();
uint64_t Elm_Kernel_Debugger_unsafeCoerce(uint64_t value);

//===----------------------------------------------------------------------===//
// Json Module (elm/json)
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_Json_decodeString();
uint64_t Elm_Kernel_Json_decodeBool();
uint64_t Elm_Kernel_Json_decodeInt();
uint64_t Elm_Kernel_Json_decodeFloat();
uint64_t Elm_Kernel_Json_decodeNull(uint64_t fallback);
uint64_t Elm_Kernel_Json_decodeList(uint64_t decoder);
uint64_t Elm_Kernel_Json_decodeArray(uint64_t decoder);
uint64_t Elm_Kernel_Json_decodeField(uint64_t fieldName, uint64_t decoder);
uint64_t Elm_Kernel_Json_decodeIndex(int64_t index, uint64_t decoder);
uint64_t Elm_Kernel_Json_decodeKeyValuePairs(uint64_t decoder);
uint64_t Elm_Kernel_Json_decodeValue();
uint64_t Elm_Kernel_Json_succeed(uint64_t value);
uint64_t Elm_Kernel_Json_fail(uint64_t message);
uint64_t Elm_Kernel_Json_andThen(uint64_t closure, uint64_t decoder);
uint64_t Elm_Kernel_Json_oneOf(uint64_t decoders);
uint64_t Elm_Kernel_Json_map1(uint64_t closure, uint64_t d1);
uint64_t Elm_Kernel_Json_map2(uint64_t closure, uint64_t d1, uint64_t d2);
uint64_t Elm_Kernel_Json_map3(uint64_t closure, uint64_t d1, uint64_t d2, uint64_t d3);
uint64_t Elm_Kernel_Json_map4(uint64_t closure, uint64_t d1, uint64_t d2, uint64_t d3, uint64_t d4);
uint64_t Elm_Kernel_Json_map5(uint64_t closure, uint64_t d1, uint64_t d2, uint64_t d3, uint64_t d4, uint64_t d5);
uint64_t Elm_Kernel_Json_map6(uint64_t closure, uint64_t d1, uint64_t d2, uint64_t d3, uint64_t d4, uint64_t d5, uint64_t d6);
uint64_t Elm_Kernel_Json_map7(uint64_t closure, uint64_t d1, uint64_t d2, uint64_t d3, uint64_t d4, uint64_t d5, uint64_t d6, uint64_t d7);
uint64_t Elm_Kernel_Json_map8(uint64_t closure, uint64_t d1, uint64_t d2, uint64_t d3, uint64_t d4, uint64_t d5, uint64_t d6, uint64_t d7, uint64_t d8);
uint64_t Elm_Kernel_Json_run(uint64_t decoder, uint64_t value);
uint64_t Elm_Kernel_Json_runOnString(uint64_t decoder, uint64_t jsonString);
uint64_t Elm_Kernel_Json_encode(int64_t indent, uint64_t value);
uint64_t Elm_Kernel_Json_wrap(uint64_t value);
uint64_t Elm_Kernel_Json_encodeNull();
uint64_t Elm_Kernel_Json_emptyArray();
uint64_t Elm_Kernel_Json_emptyObject();
uint64_t Elm_Kernel_Json_addEntry(uint64_t func, uint64_t entry, uint64_t array);
uint64_t Elm_Kernel_Json_addField(uint64_t key, uint64_t value, uint64_t object);

//===----------------------------------------------------------------------===//
// Time Module (elm/time)
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_Time_now();
uint64_t Elm_Kernel_Time_here();
uint64_t Elm_Kernel_Time_getZoneName();
uint64_t Elm_Kernel_Time_setInterval(double intervalMs, uint64_t task);

//===----------------------------------------------------------------------===//
// Url Module (elm/url)
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_Url_percentEncode(uint64_t str);
uint64_t Elm_Kernel_Url_percentDecode(uint64_t str);

//===----------------------------------------------------------------------===//
// Http Module (elm/http)
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_Http_emptyBody();
uint64_t Elm_Kernel_Http_pair(uint64_t key, uint64_t value);
uint64_t Elm_Kernel_Http_toTask(uint64_t request);
uint64_t Elm_Kernel_Http_expect(uint64_t responseToResult);
uint64_t Elm_Kernel_Http_mapExpect(uint64_t closure, uint64_t expectVal);
uint64_t Elm_Kernel_Http_bytesToBlob(uint64_t bytes, uint64_t mimeType);
uint64_t Elm_Kernel_Http_toDataView(uint64_t bytes);
uint64_t Elm_Kernel_Http_toFormData(uint64_t parts);

//===----------------------------------------------------------------------===//
// Bytes Module (elm/bytes) - STUBS
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_Bytes_width(uint64_t bytes);
uint64_t Elm_Kernel_Bytes_getHostEndianness();
int64_t Elm_Kernel_Bytes_getStringWidth(uint64_t str);
uint64_t Elm_Kernel_Bytes_encode(uint64_t encoder);
uint64_t Elm_Kernel_Bytes_decode(uint64_t decoder, uint64_t bytes);
uint64_t Elm_Kernel_Bytes_decodeFailure();
uint64_t Elm_Kernel_Bytes_read_i8(uint64_t bytes, int64_t offset);
uint64_t Elm_Kernel_Bytes_read_i16(uint64_t isLE, uint64_t bytes, int64_t offset);
uint64_t Elm_Kernel_Bytes_read_i32(uint64_t isLE, uint64_t bytes, int64_t offset);
uint64_t Elm_Kernel_Bytes_read_u8(uint64_t bytes, int64_t offset);
uint64_t Elm_Kernel_Bytes_read_u16(uint64_t isLE, uint64_t bytes, int64_t offset);
uint64_t Elm_Kernel_Bytes_read_u32(uint64_t isLE, uint64_t bytes, int64_t offset);
uint64_t Elm_Kernel_Bytes_read_f32(uint64_t isLE, uint64_t bytes, int64_t offset);
uint64_t Elm_Kernel_Bytes_read_f64(uint64_t isLE, uint64_t bytes, int64_t offset);
uint64_t Elm_Kernel_Bytes_read_bytes(int64_t length, uint64_t bytes, int64_t offset);
uint64_t Elm_Kernel_Bytes_read_string(int64_t length, uint64_t bytes, int64_t offset);
// Write functions create Encoder tree nodes (Custom types)
// Endianness parameter is eco.value (LE=ctor 0, BE=ctor 1), NOT bool
uint64_t Elm_Kernel_Bytes_write_i8(int64_t value);
uint64_t Elm_Kernel_Bytes_write_i16(uint64_t endianness, int64_t value);
uint64_t Elm_Kernel_Bytes_write_i32(uint64_t endianness, int64_t value);
uint64_t Elm_Kernel_Bytes_write_u8(int64_t value);
uint64_t Elm_Kernel_Bytes_write_u16(uint64_t endianness, int64_t value);
uint64_t Elm_Kernel_Bytes_write_u32(uint64_t endianness, int64_t value);
uint64_t Elm_Kernel_Bytes_write_f32(uint64_t endianness, double value);
uint64_t Elm_Kernel_Bytes_write_f64(uint64_t endianness, double value);
uint64_t Elm_Kernel_Bytes_write_bytes(uint64_t bytes);
uint64_t Elm_Kernel_Bytes_write_string(uint64_t str);

//===----------------------------------------------------------------------===//
// File Module (elm/file) - STUBS
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_File_decoder();
uint64_t Elm_Kernel_File_name(uint64_t file);
uint64_t Elm_Kernel_File_mime(uint64_t file);
int64_t Elm_Kernel_File_size(uint64_t file);
int64_t Elm_Kernel_File_lastModified(uint64_t file);
uint64_t Elm_Kernel_File_toString(uint64_t file);
uint64_t Elm_Kernel_File_toBytes(uint64_t file);
uint64_t Elm_Kernel_File_toUrl(uint64_t file);
uint64_t Elm_Kernel_File_download(uint64_t name, uint64_t mime, uint64_t content);
uint64_t Elm_Kernel_File_downloadUrl(uint64_t name, uint64_t url);
uint64_t Elm_Kernel_File_uploadOne(uint64_t mimes);
uint64_t Elm_Kernel_File_uploadOneOrMore(uint64_t mimes);
uint64_t Elm_Kernel_File_makeBytesSafeForInternetExplorer(uint64_t bytes);

//===----------------------------------------------------------------------===//
// Parser Module (elm/parser) - STUBS
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_Parser_isSubChar(uint64_t closure, int64_t offset, uint64_t str);
uint64_t Elm_Kernel_Parser_isSubString(uint64_t target, int64_t offset, int64_t row, int64_t col, uint64_t str);
int64_t Elm_Kernel_Parser_findSubString(uint64_t target, int64_t offset, int64_t row, int64_t col, uint64_t str);
uint64_t Elm_Kernel_Parser_chompBase10(int64_t offset, uint64_t str);
uint64_t Elm_Kernel_Parser_consumeBase(int64_t base, int64_t offset, uint64_t str);
uint64_t Elm_Kernel_Parser_consumeBase16(int64_t offset, uint64_t str);
uint64_t Elm_Kernel_Parser_isAsciiCode(int64_t code, int64_t offset, uint64_t str);

//===----------------------------------------------------------------------===//
// Regex Module (elm/regex) - STUBS
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_Regex_never();
double Elm_Kernel_Regex_infinity();
uint64_t Elm_Kernel_Regex_fromStringWith(uint64_t options, uint64_t pattern);
uint64_t Elm_Kernel_Regex_contains(uint64_t regex, uint64_t str);
uint64_t Elm_Kernel_Regex_findAtMost(int64_t n, uint64_t regex, uint64_t str);
uint64_t Elm_Kernel_Regex_replaceAtMost(int64_t n, uint64_t regex, uint64_t closure, uint64_t str);
uint64_t Elm_Kernel_Regex_splitAtMost(int64_t n, uint64_t regex, uint64_t str);

//===----------------------------------------------------------------------===//
// Effect Manager Registration
//===----------------------------------------------------------------------===//

void eco_register_time_effect_manager();
void eco_register_http_effect_manager();
void eco_register_all_effect_managers();

} // extern "C"

#endif // ELM_KERNEL_EXPORTS_H
