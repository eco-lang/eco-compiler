//===- TimeExports.cpp - C-linkage exports for Time module -----------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include <cassert>

using namespace Elm;
using namespace Elm::Kernel;

extern "C" {

uint64_t Elm_Kernel_Time_now() {
    assert(false && "Elm_Kernel_Time_now not implemented - requires Task type");
    return 0;
}

uint64_t Elm_Kernel_Time_here() {
    assert(false && "Elm_Kernel_Time_here not implemented - requires Task type");
    return 0;
}

uint64_t Elm_Kernel_Time_getZoneName() {
    assert(false && "Elm_Kernel_Time_getZoneName not implemented - requires Task type");
    return 0;
}

uint64_t Elm_Kernel_Time_setInterval(double intervalMs, uint64_t task) {
    (void)intervalMs;
    (void)task;
    assert(false && "Elm_Kernel_Time_setInterval not implemented - requires subscription support");
    return 0;
}

} // extern "C"
