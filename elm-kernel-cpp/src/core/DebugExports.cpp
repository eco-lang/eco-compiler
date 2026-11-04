//===- DebugExports.cpp - C-linkage exports for Debug module ---------------===//
//
// Defines the elm/core `Debug` kernel functions declared in `KernelExports.h`. Output goes to the calling
// thread's print destination, which `eco_set_output_stream` in `RuntimeExports.h` sets.

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

// Returns the String at address `ptr` as UTF-8, as `StringOps::toStdString` converts it.
std::string elmStringToStd(void* ptr) {
    return Elm::StringOps::toStdString(ptr);
}

} // anonymous namespace

extern "C" {

HPtr Elm_Kernel_Debug_log(HPtr tag, HPtr value) {
    uint64_t tag_bits = tag.toBits();
    uint64_t value_bits = value.toBits();
    std::string tagStr = elmStringToStd(Elm::Kernel::Export::toPtr(tag_bits));

    eco_output_text(tagStr.c_str());
    eco_output_text(": ");
    eco_print_elm_value(value);
    eco_output_text("\n");

    return value;
}

HPtr Elm_Kernel_Debug_todo(HPtr message) {
    uint64_t message_bits = message.toBits();
    std::string msgStr = elmStringToStd(Elm::Kernel::Export::toPtr(message_bits));
    eco_output_text("Debug.todo: ");
    eco_output_text(msgStr.c_str());
    eco_output_text("\n");
    exit(1);
    return HPtr::fromBits(0);
}

// The symbol used when Debug.toString is a function value (a kernel closure). Its MLIR declaration has one
// parameter, so it takes exactly one, and it prints with the untyped printer.
HPtr Elm_Kernel_Debug_toString(HPtr value) {
    return eco_value_to_string_typed(value, -1);
}

// A separate symbol from Elm_Kernel_Debug_toString, so the closure path never reads a type id it was not
// given, as a one-argument call into a two-parameter function would.
HPtr Elm_Kernel_Debug_toString_typed(HPtr value, int64_t type_id) {
    return eco_value_to_string_typed(value, type_id);
}

} // extern "C"
