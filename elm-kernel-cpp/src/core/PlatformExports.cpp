//===- PlatformExports.cpp - C-linkage exports for Platform module ---------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "Platform.hpp"
#include <cassert>

using namespace Elm;
using namespace Elm::Kernel;

extern "C" {

uint64_t Elm_Kernel_Platform_batch(uint64_t commands) {
    // Batch multiple commands into one.
    // This requires runtime Cmd support - stub for now.
    (void)commands;
    assert(false && "Elm_Kernel_Platform_batch not implemented - requires runtime Cmd support");
    return 0;
}

uint64_t Elm_Kernel_Platform_map(uint64_t closure, uint64_t cmd) {
    // Map a function over a command.
    (void)closure;
    (void)cmd;
    assert(false && "Elm_Kernel_Platform_map not implemented - requires runtime Cmd support");
    return 0;
}

void Elm_Kernel_Platform_sendToApp(uint64_t router, uint64_t msg) {
    // Send a message to the app.
    (void)router;
    (void)msg;
    // No-op in stub implementation
}

uint64_t Elm_Kernel_Platform_sendToSelf(uint64_t router, uint64_t msg) {
    // Send a message to self (the current effect manager).
    (void)router;
    (void)msg;
    assert(false && "Elm_Kernel_Platform_sendToSelf not implemented - requires runtime Task support");
    return 0;
}

uint64_t Elm_Kernel_Platform_worker(uint64_t impl) {
    // Create a Platform.worker program.
    // This is a stub - full implementation needs runtime initialization.
    // Return the impl unchanged for now.
    return impl;
}

} // extern "C"
