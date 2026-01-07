//===- ProcessExports.cpp - C-linkage exports for Process module -----------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "Process.hpp"
#include <cassert>

using namespace Elm;
using namespace Elm::Kernel;

extern "C" {

uint64_t Elm_Kernel_Process_sleep(double time) {
    // Create a Task that sleeps for the given time (in milliseconds).
    // This requires platform runtime support - stub for now.
    (void)time;
    assert(false && "Elm_Kernel_Process_sleep not implemented - requires platform runtime");
    return 0;
}

} // extern "C"
