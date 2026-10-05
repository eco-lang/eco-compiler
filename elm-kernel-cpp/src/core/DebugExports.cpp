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

// Debug.toString as a function VALUE (a kernel closure): its MLIR declaration has one
// parameter, so it must take exactly one. Prints without type information.
HPtr Elm_Kernel_Debug_toString(HPtr value) {
    return eco_value_to_string_typed(value, -1);
}

// Saturated Debug.toString call: the code generator passes the argument's type id so
// constructor names print. A separate symbol, so the closure path above never reads a
// type id it was not given (a one-argument call into a two-parameter function).
HPtr Elm_Kernel_Debug_toString_typed(HPtr value, int64_t type_id) {
    return eco_value_to_string_typed(value, type_id);
}

} // extern "C"
