//===- RuntimeSymbols.cpp - JIT Symbol Registration for Eco Runtime -------===//
//
// Implementation of the shared symbol registration API used by both ecoc
// and EcoRunner.
//
//===----------------------------------------------------------------------===//

#include "RuntimeSymbols.h"

#include "mlir/ExecutionEngine/ExecutionEngine.h"

#include "llvm/ExecutionEngine/Orc/Mangling.h"

// Include runtime exports for JIT symbol registration.
#include "../allocator/RuntimeExports.h"

// Include byte fusion runtime exports for fused Bytes.Encode/Decode operations.
#include "../allocator/ElmBytesRuntime.h"

// Include kernel exports for JIT symbol registration.
#include "KernelExports.h"

using namespace mlir;

namespace eco {

void registerRuntimeSymbols(ExecutionEngine &engine) {
    engine.registerSymbols([](llvm::orc::MangleAndInterner interner) {
        llvm::orc::SymbolMap symbolMap;

        // Heap allocation functions.
        symbolMap[interner("eco_alloc_custom")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_alloc_custom),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_alloc_cons")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_alloc_cons),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_alloc_tuple2")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_alloc_tuple2),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_alloc_tuple3")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_alloc_tuple3),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_alloc_string")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_alloc_string),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_alloc_string_literal")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_alloc_string_literal),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_alloc_closure")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_alloc_closure),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_alloc_int")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_alloc_int),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_alloc_float")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_alloc_float),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_alloc_char")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_alloc_char),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_allocate")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_allocate),
                llvm::JITSymbolFlags::Exported);

        // Field store functions.
        symbolMap[interner("eco_store_field")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_store_field),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_store_field_i64")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_store_field_i64),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_store_field_f64")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_store_field_f64),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_set_unboxed")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_set_unboxed),
                llvm::JITSymbolFlags::Exported);

        // Record allocation and field store functions.
        symbolMap[interner("eco_alloc_record")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_alloc_record),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_store_record_field")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_store_record_field),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_store_record_field_i64")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_store_record_field_i64),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_store_record_field_f64")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_store_record_field_f64),
                llvm::JITSymbolFlags::Exported);

        // Closure operations.
        symbolMap[interner("eco_apply_closure")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_apply_closure),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_pap_extend")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_pap_extend),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_closure_call_saturated")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_closure_call_saturated),
                llvm::JITSymbolFlags::Exported);

        // Runtime utilities.
        symbolMap[interner("eco_crash")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_crash),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_dbg_print")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_dbg_print),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_dbg_print_int")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_dbg_print_int),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_dbg_print_float")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_dbg_print_float),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_dbg_print_char")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_dbg_print_char),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_dbg_print_typed")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_dbg_print_typed),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_register_type_graph")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_register_type_graph),
                llvm::JITSymbolFlags::Exported);

        // GC interface.
        symbolMap[interner("eco_safepoint")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_safepoint),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_minor_gc")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_minor_gc),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_major_gc")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_major_gc),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_gc_add_root")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_gc_add_root),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_gc_remove_root")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_gc_remove_root),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_gc_jit_root_count")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_gc_jit_root_count),
                llvm::JITSymbolFlags::Exported);

        // Tag extraction.
        symbolMap[interner("eco_get_header_tag")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_get_header_tag),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_get_custom_ctor")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_get_custom_ctor),
                llvm::JITSymbolFlags::Exported);

        // Arithmetic helpers.
        symbolMap[interner("eco_int_pow")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_int_pow),
                llvm::JITSymbolFlags::Exported);

        // HPointer conversion.
        symbolMap[interner("eco_resolve_hptr")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_resolve_hptr),
                llvm::JITSymbolFlags::Exported);

        // Constructor tag extraction (handles both heap objects and embedded constants).
        symbolMap[interner("eco_get_tag")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_get_tag),
                llvm::JITSymbolFlags::Exported);

        // List element access (handles both boxed and unboxed heads).
        symbolMap[interner("eco_cons_head_i64")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_cons_head_i64),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_cons_head_f64")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_cons_head_f64),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_cons_head_i16")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_cons_head_i16),
                llvm::JITSymbolFlags::Exported);

        // =================================================================
        // ByteFusion Runtime Symbols (for fused Bytes.Encode/Decode)
        // =================================================================

        // ByteBuffer operations
        symbolMap[interner("elm_alloc_bytebuffer")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&elm_alloc_bytebuffer),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("elm_bytebuffer_len")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&elm_bytebuffer_len),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("elm_bytebuffer_data")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&elm_bytebuffer_data),
                llvm::JITSymbolFlags::Exported);

        // UTF-8 string operations
        symbolMap[interner("elm_utf8_width")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&elm_utf8_width),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("elm_utf8_copy")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&elm_utf8_copy),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("elm_utf8_decode")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&elm_utf8_decode),
                llvm::JITSymbolFlags::Exported);

        // Maybe operations for decoder results
        symbolMap[interner("elm_maybe_nothing")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&elm_maybe_nothing),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("elm_maybe_just")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&elm_maybe_just),
                llvm::JITSymbolFlags::Exported);

        // List operations for fused byte decoders
        symbolMap[interner("elm_list_reverse")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&elm_list_reverse),
                llvm::JITSymbolFlags::Exported);

        // =================================================================
        // Elm Kernel Function Symbols
        // =================================================================

        // Helper macro for registering kernel symbols.
        #define KERNEL_SYM(name) \
            symbolMap[interner(#name)] = \
                llvm::orc::ExecutorSymbolDef( \
                    llvm::orc::ExecutorAddr::fromPtr(&name), \
                    llvm::JITSymbolFlags::Exported);

        // Basics module
        KERNEL_SYM(Elm_Kernel_Basics_acos)
        KERNEL_SYM(Elm_Kernel_Basics_asin)
        KERNEL_SYM(Elm_Kernel_Basics_atan)
        KERNEL_SYM(Elm_Kernel_Basics_atan2)
        KERNEL_SYM(Elm_Kernel_Basics_cos)
        KERNEL_SYM(Elm_Kernel_Basics_sin)
        KERNEL_SYM(Elm_Kernel_Basics_tan)
        KERNEL_SYM(Elm_Kernel_Basics_sqrt)
        KERNEL_SYM(Elm_Kernel_Basics_log)
        KERNEL_SYM(Elm_Kernel_Basics_pow)
        KERNEL_SYM(Elm_Kernel_Basics_e)
        KERNEL_SYM(Elm_Kernel_Basics_pi)
        KERNEL_SYM(Elm_Kernel_Basics_add)
        KERNEL_SYM(Elm_Kernel_Basics_sub)
        KERNEL_SYM(Elm_Kernel_Basics_mul)
        KERNEL_SYM(Elm_Kernel_Basics_fdiv)
        KERNEL_SYM(Elm_Kernel_Basics_idiv)
        KERNEL_SYM(Elm_Kernel_Basics_modBy)
        KERNEL_SYM(Elm_Kernel_Basics_remainderBy)
        KERNEL_SYM(Elm_Kernel_Basics_ceiling)
        KERNEL_SYM(Elm_Kernel_Basics_floor)
        KERNEL_SYM(Elm_Kernel_Basics_round)
        KERNEL_SYM(Elm_Kernel_Basics_truncate)
        KERNEL_SYM(Elm_Kernel_Basics_toFloat)
        KERNEL_SYM(Elm_Kernel_Basics_isInfinite)
        KERNEL_SYM(Elm_Kernel_Basics_isNaN)
        KERNEL_SYM(Elm_Kernel_Basics_and)
        KERNEL_SYM(Elm_Kernel_Basics_or)
        KERNEL_SYM(Elm_Kernel_Basics_xor)
        KERNEL_SYM(Elm_Kernel_Basics_not)

        // Bitwise module
        KERNEL_SYM(Elm_Kernel_Bitwise_and)
        KERNEL_SYM(Elm_Kernel_Bitwise_or)
        KERNEL_SYM(Elm_Kernel_Bitwise_xor)
        KERNEL_SYM(Elm_Kernel_Bitwise_complement)
        KERNEL_SYM(Elm_Kernel_Bitwise_shiftLeftBy)
        KERNEL_SYM(Elm_Kernel_Bitwise_shiftRightBy)
        KERNEL_SYM(Elm_Kernel_Bitwise_shiftRightZfBy)

        // Char module
        KERNEL_SYM(Elm_Kernel_Char_fromCode)
        KERNEL_SYM(Elm_Kernel_Char_toCode)
        KERNEL_SYM(Elm_Kernel_Char_toLower)
        KERNEL_SYM(Elm_Kernel_Char_toUpper)
        KERNEL_SYM(Elm_Kernel_Char_toLocaleLower)
        KERNEL_SYM(Elm_Kernel_Char_toLocaleUpper)

        // String module
        KERNEL_SYM(Elm_Kernel_String_length)
        KERNEL_SYM(Elm_Kernel_String_append)
        KERNEL_SYM(Elm_Kernel_String_join)
        KERNEL_SYM(Elm_Kernel_String_cons)
        KERNEL_SYM(Elm_Kernel_String_uncons)
        KERNEL_SYM(Elm_Kernel_String_fromList)
        KERNEL_SYM(Elm_Kernel_String_slice)
        KERNEL_SYM(Elm_Kernel_String_split)
        KERNEL_SYM(Elm_Kernel_String_lines)
        KERNEL_SYM(Elm_Kernel_String_words)
        KERNEL_SYM(Elm_Kernel_String_reverse)
        KERNEL_SYM(Elm_Kernel_String_toUpper)
        KERNEL_SYM(Elm_Kernel_String_toLower)
        KERNEL_SYM(Elm_Kernel_String_trim)
        KERNEL_SYM(Elm_Kernel_String_trimLeft)
        KERNEL_SYM(Elm_Kernel_String_trimRight)
        KERNEL_SYM(Elm_Kernel_String_startsWith)
        KERNEL_SYM(Elm_Kernel_String_endsWith)
        KERNEL_SYM(Elm_Kernel_String_contains)
        KERNEL_SYM(Elm_Kernel_String_indexes)
        KERNEL_SYM(Elm_Kernel_String_toInt)
        KERNEL_SYM(Elm_Kernel_String_toFloat)
        KERNEL_SYM(Elm_Kernel_String_fromNumber)
        KERNEL_SYM(Elm_Kernel_String_map)
        KERNEL_SYM(Elm_Kernel_String_filter)
        KERNEL_SYM(Elm_Kernel_String_any)
        KERNEL_SYM(Elm_Kernel_String_all)
        KERNEL_SYM(Elm_Kernel_String_foldl)
        KERNEL_SYM(Elm_Kernel_String_foldr)

        // List module
        KERNEL_SYM(Elm_Kernel_List_cons)
        KERNEL_SYM(Elm_Kernel_List_fromArray)
        KERNEL_SYM(Elm_Kernel_List_toArray)
        KERNEL_SYM(Elm_Kernel_List_map2)
        KERNEL_SYM(Elm_Kernel_List_map3)
        KERNEL_SYM(Elm_Kernel_List_map4)
        KERNEL_SYM(Elm_Kernel_List_map5)
        KERNEL_SYM(Elm_Kernel_List_sortBy)
        KERNEL_SYM(Elm_Kernel_List_sortWith)

        // Utils module
        KERNEL_SYM(Elm_Kernel_Utils_compare)
        KERNEL_SYM(Elm_Kernel_Utils_equal)
        KERNEL_SYM(Elm_Kernel_Utils_notEqual)
        KERNEL_SYM(Elm_Kernel_Utils_lt)
        KERNEL_SYM(Elm_Kernel_Utils_le)
        KERNEL_SYM(Elm_Kernel_Utils_gt)
        KERNEL_SYM(Elm_Kernel_Utils_ge)
        KERNEL_SYM(Elm_Kernel_Utils_append)

        // JsArray module
        KERNEL_SYM(Elm_Kernel_JsArray_empty)
        KERNEL_SYM(Elm_Kernel_JsArray_singleton)
        KERNEL_SYM(Elm_Kernel_JsArray_length)
        KERNEL_SYM(Elm_Kernel_JsArray_unsafeGet)
        KERNEL_SYM(Elm_Kernel_JsArray_unsafeSet)
        KERNEL_SYM(Elm_Kernel_JsArray_push)
        KERNEL_SYM(Elm_Kernel_JsArray_slice)
        KERNEL_SYM(Elm_Kernel_JsArray_appendN)
        KERNEL_SYM(Elm_Kernel_JsArray_initialize)
        KERNEL_SYM(Elm_Kernel_JsArray_initializeFromList)
        KERNEL_SYM(Elm_Kernel_JsArray_map)
        KERNEL_SYM(Elm_Kernel_JsArray_indexedMap)
        KERNEL_SYM(Elm_Kernel_JsArray_foldl)
        KERNEL_SYM(Elm_Kernel_JsArray_foldr)

        // VirtualDom module
        KERNEL_SYM(Elm_Kernel_VirtualDom_text)
        KERNEL_SYM(Elm_Kernel_VirtualDom_node)
        KERNEL_SYM(Elm_Kernel_VirtualDom_nodeNS)
        KERNEL_SYM(Elm_Kernel_VirtualDom_keyedNode)
        KERNEL_SYM(Elm_Kernel_VirtualDom_keyedNodeNS)
        KERNEL_SYM(Elm_Kernel_VirtualDom_attribute)
        KERNEL_SYM(Elm_Kernel_VirtualDom_attributeNS)
        KERNEL_SYM(Elm_Kernel_VirtualDom_property)
        KERNEL_SYM(Elm_Kernel_VirtualDom_style)
        KERNEL_SYM(Elm_Kernel_VirtualDom_on)
        KERNEL_SYM(Elm_Kernel_VirtualDom_map)
        KERNEL_SYM(Elm_Kernel_VirtualDom_mapAttribute)
        KERNEL_SYM(Elm_Kernel_VirtualDom_lazy)
        KERNEL_SYM(Elm_Kernel_VirtualDom_lazy2)
        KERNEL_SYM(Elm_Kernel_VirtualDom_lazy3)
        KERNEL_SYM(Elm_Kernel_VirtualDom_lazy4)
        KERNEL_SYM(Elm_Kernel_VirtualDom_lazy5)
        KERNEL_SYM(Elm_Kernel_VirtualDom_lazy6)
        KERNEL_SYM(Elm_Kernel_VirtualDom_lazy7)
        KERNEL_SYM(Elm_Kernel_VirtualDom_lazy8)
        KERNEL_SYM(Elm_Kernel_VirtualDom_noScript)
        KERNEL_SYM(Elm_Kernel_VirtualDom_noOnOrFormAction)
        KERNEL_SYM(Elm_Kernel_VirtualDom_noInnerHtmlOrFormAction)
        KERNEL_SYM(Elm_Kernel_VirtualDom_noJavaScriptOrHtmlUri)
        KERNEL_SYM(Elm_Kernel_VirtualDom_noJavaScriptOrHtmlJson)

        // Debug module
        KERNEL_SYM(Elm_Kernel_Debug_log)
        KERNEL_SYM(Elm_Kernel_Debug_todo)
        KERNEL_SYM(Elm_Kernel_Debug_toString)

        // Scheduler module
        KERNEL_SYM(Elm_Kernel_Scheduler_succeed)
        KERNEL_SYM(Elm_Kernel_Scheduler_fail)
        KERNEL_SYM(Elm_Kernel_Scheduler_andThen)
        KERNEL_SYM(Elm_Kernel_Scheduler_onError)
        KERNEL_SYM(Elm_Kernel_Scheduler_spawn)
        KERNEL_SYM(Elm_Kernel_Scheduler_kill)

        // Debugger module
        KERNEL_SYM(Elm_Kernel_Debugger_init)
        KERNEL_SYM(Elm_Kernel_Debugger_isOpen)
        KERNEL_SYM(Elm_Kernel_Debugger_open)
        KERNEL_SYM(Elm_Kernel_Debugger_scroll)
        KERNEL_SYM(Elm_Kernel_Debugger_messageToString)
        KERNEL_SYM(Elm_Kernel_Debugger_download)
        KERNEL_SYM(Elm_Kernel_Debugger_upload)
        KERNEL_SYM(Elm_Kernel_Debugger_unsafeCoerce)

        // Platform module
        KERNEL_SYM(Elm_Kernel_Platform_batch)
        KERNEL_SYM(Elm_Kernel_Platform_map)
        KERNEL_SYM(Elm_Kernel_Platform_sendToApp)
        KERNEL_SYM(Elm_Kernel_Platform_sendToSelf)
        KERNEL_SYM(Elm_Kernel_Platform_worker)

        // Process module
        KERNEL_SYM(Elm_Kernel_Process_sleep)

        // Browser module
        KERNEL_SYM(Elm_Kernel_Browser_element)
        KERNEL_SYM(Elm_Kernel_Browser_document)
        KERNEL_SYM(Elm_Kernel_Browser_application)
        KERNEL_SYM(Elm_Kernel_Browser_load)
        KERNEL_SYM(Elm_Kernel_Browser_reload)
        KERNEL_SYM(Elm_Kernel_Browser_pushUrl)
        KERNEL_SYM(Elm_Kernel_Browser_replaceUrl)
        KERNEL_SYM(Elm_Kernel_Browser_go)
        KERNEL_SYM(Elm_Kernel_Browser_getViewport)
        KERNEL_SYM(Elm_Kernel_Browser_getViewportOf)
        KERNEL_SYM(Elm_Kernel_Browser_setViewport)
        KERNEL_SYM(Elm_Kernel_Browser_setViewportOf)
        KERNEL_SYM(Elm_Kernel_Browser_getElement)
        KERNEL_SYM(Elm_Kernel_Browser_on)
        KERNEL_SYM(Elm_Kernel_Browser_decodeEvent)
        KERNEL_SYM(Elm_Kernel_Browser_doc)
        KERNEL_SYM(Elm_Kernel_Browser_window)
        KERNEL_SYM(Elm_Kernel_Browser_withWindow)
        KERNEL_SYM(Elm_Kernel_Browser_rAF)
        KERNEL_SYM(Elm_Kernel_Browser_now)
        KERNEL_SYM(Elm_Kernel_Browser_visibilityInfo)
        KERNEL_SYM(Elm_Kernel_Browser_call)

        // Json module
        KERNEL_SYM(Elm_Kernel_Json_decodeString)
        KERNEL_SYM(Elm_Kernel_Json_decodeBool)
        KERNEL_SYM(Elm_Kernel_Json_decodeInt)
        KERNEL_SYM(Elm_Kernel_Json_decodeFloat)
        KERNEL_SYM(Elm_Kernel_Json_decodeNull)
        KERNEL_SYM(Elm_Kernel_Json_decodeList)
        KERNEL_SYM(Elm_Kernel_Json_decodeArray)
        KERNEL_SYM(Elm_Kernel_Json_decodeField)
        KERNEL_SYM(Elm_Kernel_Json_decodeIndex)
        KERNEL_SYM(Elm_Kernel_Json_decodeKeyValuePairs)
        KERNEL_SYM(Elm_Kernel_Json_decodeValue)
        KERNEL_SYM(Elm_Kernel_Json_succeed)
        KERNEL_SYM(Elm_Kernel_Json_fail)
        KERNEL_SYM(Elm_Kernel_Json_andThen)
        KERNEL_SYM(Elm_Kernel_Json_oneOf)
        KERNEL_SYM(Elm_Kernel_Json_map1)
        KERNEL_SYM(Elm_Kernel_Json_map2)
        KERNEL_SYM(Elm_Kernel_Json_map3)
        KERNEL_SYM(Elm_Kernel_Json_map4)
        KERNEL_SYM(Elm_Kernel_Json_map5)
        KERNEL_SYM(Elm_Kernel_Json_map6)
        KERNEL_SYM(Elm_Kernel_Json_map7)
        KERNEL_SYM(Elm_Kernel_Json_map8)
        KERNEL_SYM(Elm_Kernel_Json_run)
        KERNEL_SYM(Elm_Kernel_Json_runOnString)
        KERNEL_SYM(Elm_Kernel_Json_encode)
        KERNEL_SYM(Elm_Kernel_Json_wrap)
        KERNEL_SYM(Elm_Kernel_Json_encodeNull)
        KERNEL_SYM(Elm_Kernel_Json_emptyArray)
        KERNEL_SYM(Elm_Kernel_Json_emptyObject)
        KERNEL_SYM(Elm_Kernel_Json_addEntry)
        KERNEL_SYM(Elm_Kernel_Json_addField)

        // Time module
        KERNEL_SYM(Elm_Kernel_Time_now)
        KERNEL_SYM(Elm_Kernel_Time_here)
        KERNEL_SYM(Elm_Kernel_Time_getZoneName)
        KERNEL_SYM(Elm_Kernel_Time_setInterval)

        // Url module
        KERNEL_SYM(Elm_Kernel_Url_percentEncode)
        KERNEL_SYM(Elm_Kernel_Url_percentDecode)

        // Http module
        KERNEL_SYM(Elm_Kernel_Http_emptyBody)
        KERNEL_SYM(Elm_Kernel_Http_pair)
        KERNEL_SYM(Elm_Kernel_Http_toTask)
        KERNEL_SYM(Elm_Kernel_Http_expect)
        KERNEL_SYM(Elm_Kernel_Http_mapExpect)
        KERNEL_SYM(Elm_Kernel_Http_bytesToBlob)
        KERNEL_SYM(Elm_Kernel_Http_toDataView)
        KERNEL_SYM(Elm_Kernel_Http_toFormData)

        // Bytes module (stubs)
        KERNEL_SYM(Elm_Kernel_Bytes_width)
        KERNEL_SYM(Elm_Kernel_Bytes_getHostEndianness)
        KERNEL_SYM(Elm_Kernel_Bytes_getStringWidth)
        KERNEL_SYM(Elm_Kernel_Bytes_encode)
        KERNEL_SYM(Elm_Kernel_Bytes_decode)
        KERNEL_SYM(Elm_Kernel_Bytes_decodeFailure)
        KERNEL_SYM(Elm_Kernel_Bytes_read_i8)
        KERNEL_SYM(Elm_Kernel_Bytes_read_i16)
        KERNEL_SYM(Elm_Kernel_Bytes_read_i32)
        KERNEL_SYM(Elm_Kernel_Bytes_read_u8)
        KERNEL_SYM(Elm_Kernel_Bytes_read_u16)
        KERNEL_SYM(Elm_Kernel_Bytes_read_u32)
        KERNEL_SYM(Elm_Kernel_Bytes_read_f32)
        KERNEL_SYM(Elm_Kernel_Bytes_read_f64)
        KERNEL_SYM(Elm_Kernel_Bytes_read_bytes)
        KERNEL_SYM(Elm_Kernel_Bytes_read_string)
        KERNEL_SYM(Elm_Kernel_Bytes_write_i8)
        KERNEL_SYM(Elm_Kernel_Bytes_write_i16)
        KERNEL_SYM(Elm_Kernel_Bytes_write_i32)
        KERNEL_SYM(Elm_Kernel_Bytes_write_u8)
        KERNEL_SYM(Elm_Kernel_Bytes_write_u16)
        KERNEL_SYM(Elm_Kernel_Bytes_write_u32)
        KERNEL_SYM(Elm_Kernel_Bytes_write_f32)
        KERNEL_SYM(Elm_Kernel_Bytes_write_f64)
        KERNEL_SYM(Elm_Kernel_Bytes_write_bytes)
        KERNEL_SYM(Elm_Kernel_Bytes_write_string)

        // File module (stubs)
        KERNEL_SYM(Elm_Kernel_File_decoder)
        KERNEL_SYM(Elm_Kernel_File_name)
        KERNEL_SYM(Elm_Kernel_File_mime)
        KERNEL_SYM(Elm_Kernel_File_size)
        KERNEL_SYM(Elm_Kernel_File_lastModified)
        KERNEL_SYM(Elm_Kernel_File_toString)
        KERNEL_SYM(Elm_Kernel_File_toBytes)
        KERNEL_SYM(Elm_Kernel_File_toUrl)
        KERNEL_SYM(Elm_Kernel_File_download)
        KERNEL_SYM(Elm_Kernel_File_downloadUrl)
        KERNEL_SYM(Elm_Kernel_File_uploadOne)
        KERNEL_SYM(Elm_Kernel_File_uploadOneOrMore)
        KERNEL_SYM(Elm_Kernel_File_makeBytesSafeForInternetExplorer)

        // Parser module (stubs)
        KERNEL_SYM(Elm_Kernel_Parser_isSubChar)
        KERNEL_SYM(Elm_Kernel_Parser_isSubString)
        KERNEL_SYM(Elm_Kernel_Parser_findSubString)
        KERNEL_SYM(Elm_Kernel_Parser_chompBase10)
        KERNEL_SYM(Elm_Kernel_Parser_consumeBase)
        KERNEL_SYM(Elm_Kernel_Parser_consumeBase16)
        KERNEL_SYM(Elm_Kernel_Parser_isAsciiCode)

        // Regex module (stubs)
        KERNEL_SYM(Elm_Kernel_Regex_never)
        KERNEL_SYM(Elm_Kernel_Regex_infinity)
        KERNEL_SYM(Elm_Kernel_Regex_fromStringWith)
        KERNEL_SYM(Elm_Kernel_Regex_contains)
        KERNEL_SYM(Elm_Kernel_Regex_findAtMost)
        KERNEL_SYM(Elm_Kernel_Regex_replaceAtMost)
        KERNEL_SYM(Elm_Kernel_Regex_splitAtMost)

        #undef KERNEL_SYM

        return symbolMap;
    });
}

} // namespace eco
