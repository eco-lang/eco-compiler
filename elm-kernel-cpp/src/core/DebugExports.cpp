//===- DebugExports.cpp - C-linkage exports for Debug module ---------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "Debug.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/RuntimeExports.h"
#include "allocator/StringOps.hpp"

using namespace Elm;
using namespace Elm::Kernel;

namespace {

// Convert any String form (leaf or slice) to a UTF-8 std::string.
// Routes through StringOps::toStdString — the canonical interop path.
std::string elmStringToStd(void* ptr) {
    return Elm::StringOps::toStdString(ptr);
}

} // anonymous namespace

extern "C" {

HPtr Elm_Kernel_Debug_log(HPtr tag, HPtr value) {
    uint64_t tag_bits = tag.toBits();
    uint64_t value_bits = value.toBits();
    // log prints the tag and value, then returns the value unchanged
    // In JIT mode, parameters are HPointers (logical pointers)
    std::string tagStr = elmStringToStd(Elm::Kernel::Export::toPtr(tag_bits));

    // Output to the captured stream (or stderr if not capturing)
    // Use eco_print_elm_value to unwrap Guida's Ctor0 box wrappers
    eco_output_text(tagStr.c_str());
    eco_output_text(": ");
    eco_print_elm_value(value);
    eco_output_text("\n");

    // Return the value unchanged
    return value;
}

HPtr Elm_Kernel_Debug_todo(HPtr message) {
    uint64_t message_bits = message.toBits();
    // In JIT mode, parameters are HPointers (logical pointers)
    std::string msgStr = elmStringToStd(Elm::Kernel::Export::toPtr(message_bits));
    eco_output_text("Debug.todo: ");
    eco_output_text(msgStr.c_str());
    eco_output_text("\n");
    exit(1);
    // Never reached, but needed for return type
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_Debug_toString(HPtr value, int64_t type_id) {
    // Convert the value to its string representation using type info
    // eco_value_to_string_typed returns HPtr
    return eco_value_to_string_typed(value, type_id);
}

} // extern "C"
