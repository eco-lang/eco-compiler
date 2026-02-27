//===- RuntimeExports.cpp - C-linkage exports for Runtime module ----------===//

#include "KernelExports.h"
#include "Runtime.hpp"

using namespace Eco::Kernel;

uint64_t Eco_Kernel_Runtime_dirname() {
    return Runtime::dirname();
}

double Eco_Kernel_Runtime_random() {
    return Runtime::random();
}

uint64_t Eco_Kernel_Runtime_saveState(uint64_t state) {
    return Runtime::saveState(state);
}

uint64_t Eco_Kernel_Runtime_loadState() {
    return Runtime::loadState();
}
