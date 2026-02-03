//===- DebuggerExports.cpp - C-linkage exports for Debugger module ---------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "Debugger.hpp"
#include <cassert>

using namespace Elm;
using namespace Elm::Kernel;

extern "C" {

uint64_t Elm_Kernel_Debugger_init(uint64_t value) {
    // Initialize debugger state.
    // For now, just return the value unchanged.
    return value;
}

uint64_t Elm_Kernel_Debugger_isOpen(uint64_t popout) {
    // Check if the debugger popout is open.
    // Always return false in this native implementation.
    (void)popout;
    return Export::encodeBoxedBool(false);
}

uint64_t Elm_Kernel_Debugger_open(uint64_t popout) {
    // Open the debugger popout.
    (void)popout;
    assert(false && "Elm_Kernel_Debugger_open not implemented - requires Task type");
    return 0;
}

uint64_t Elm_Kernel_Debugger_scroll(uint64_t popout) {
    // Scroll the debugger view.
    (void)popout;
    assert(false && "Elm_Kernel_Debugger_scroll not implemented - requires Task type");
    return 0;
}

uint64_t Elm_Kernel_Debugger_messageToString(uint64_t message) {
    // Convert a message to string for debugging.
    // Use the same logic as Debug.toString.
    extern uint64_t Elm_Kernel_Debug_toString(uint64_t value);
    return Elm_Kernel_Debug_toString(message);
}

uint64_t Elm_Kernel_Debugger_download(int64_t historyLength, uint64_t json) {
    // Download debug history as JSON.
    (void)historyLength;
    (void)json;
    assert(false && "Elm_Kernel_Debugger_download not implemented - requires Task type");
    return 0;
}

uint64_t Elm_Kernel_Debugger_upload() {
    // Upload debug history.
    assert(false && "Elm_Kernel_Debugger_upload not implemented - requires Task type");
    return 0;
}

uint64_t Elm_Kernel_Debugger_unsafeCoerce(uint64_t value) {
    // Unsafe coercion - just return the value unchanged.
    // This is used for type system escape hatches.
    return value;
}

} // extern "C"
