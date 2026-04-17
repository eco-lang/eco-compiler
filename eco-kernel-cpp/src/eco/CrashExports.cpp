//===- CrashExports.cpp - C-linkage exports for Crash module --------------===//

#include "KernelExports.h"
#include "Crash.hpp"

using namespace Eco::Kernel;
using Elm::HPtr;

HPtr Eco_Kernel_Crash_crash(HPtr message) {
    return HPtr::fromBits(Crash::crash(message.toBits()));
}
