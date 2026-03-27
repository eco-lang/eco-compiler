//===- CrashExports.cpp - C-linkage exports for Crash module --------------===//

#include "KernelExports.h"
#include "Crash.hpp"

using namespace Eco::Kernel;

uint64_t Eco_Kernel_Crash_crash(uint64_t message) {
    return Crash::crash(message);
}
