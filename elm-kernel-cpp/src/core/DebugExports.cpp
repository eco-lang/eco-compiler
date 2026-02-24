//===- DebugExports.cpp - C-linkage exports for Debug module ---------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "Debug.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/RuntimeExports.h"

using namespace Elm;
using namespace Elm::Kernel;

namespace {

// Convert ElmString to std::string (UTF-16 to UTF-8)
std::string elmStringToStd(void* ptr) {
    if (!ptr) return "";
    ElmString* s = static_cast<ElmString*>(ptr);
    std::string result;
    result.reserve(s->header.size);
    for (u32 i = 0; i < s->header.size; i++) {
        u16 c = s->chars[i];
        if (c < 0x80) {
            result.push_back(static_cast<char>(c));
        } else if (c < 0x800) {
            result.push_back(static_cast<char>(0xC0 | (c >> 6)));
            result.push_back(static_cast<char>(0x80 | (c & 0x3F)));
        } else {
            result.push_back(static_cast<char>(0xE0 | (c >> 12)));
            result.push_back(static_cast<char>(0x80 | ((c >> 6) & 0x3F)));
            result.push_back(static_cast<char>(0x80 | (c & 0x3F)));
        }
    }
    return result;
}

} // anonymous namespace

extern "C" {

uint64_t Elm_Kernel_Debug_log(uint64_t tag, uint64_t value) {
    // log prints the tag and value, then returns the value unchanged
    // In JIT mode, parameters are HPointers (logical pointers)
    std::string tagStr = elmStringToStd(Elm::Kernel::Export::toPtr(tag));

    // Output to the captured stream (or stderr if not capturing)
    // Use eco_print_elm_value to unwrap Guida's Ctor0 box wrappers
    eco_output_text(tagStr.c_str());
    eco_output_text(": ");
    eco_print_elm_value(value);
    eco_output_text("\n");

    // Return the value unchanged
    return value;
}

uint64_t Elm_Kernel_Debug_todo(uint64_t message) {
    // In JIT mode, parameters are HPointers (logical pointers)
    std::string msgStr = elmStringToStd(Elm::Kernel::Export::toPtr(message));
    eco_output_text("Debug.todo: ");
    eco_output_text(msgStr.c_str());
    eco_output_text("\n");
    exit(1);
    // Never reached, but needed for return type
    return 0;
}

uint64_t Elm_Kernel_Debug_toString(uint64_t value, int64_t type_id) {
    // Convert the value to its string representation using type info
    // eco_value_to_string_typed returns HPointer as uint64_t
    return eco_value_to_string_typed(value, type_id);
}

} // extern "C"
