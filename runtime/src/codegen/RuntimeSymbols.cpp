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

        // List module
        KERNEL_SYM(Elm_Kernel_List_cons)

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

        // Debug module
        KERNEL_SYM(Elm_Kernel_Debug_log)
        KERNEL_SYM(Elm_Kernel_Debug_todo)
        KERNEL_SYM(Elm_Kernel_Debug_toString)

        // Scheduler module
        KERNEL_SYM(Elm_Kernel_Scheduler_succeed)
        KERNEL_SYM(Elm_Kernel_Scheduler_fail)

        #undef KERNEL_SYM

        return symbolMap;
    });
}

} // namespace eco
