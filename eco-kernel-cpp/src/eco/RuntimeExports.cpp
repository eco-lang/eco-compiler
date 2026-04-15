//===- RuntimeExports.cpp - C-linkage exports for Runtime module ----------===//

#include "KernelExports.h"
#include "Runtime.hpp"

using namespace Eco::Kernel;

uint64_t Eco_Kernel_Runtime_dirname() {
    return Runtime::dirname();
}

uint64_t Eco_Kernel_Runtime_random() {
    return Runtime::random();
}

uint64_t Eco_Kernel_Runtime_saveState(uint64_t state) {
    return Runtime::saveState(state);
}

uint64_t Eco_Kernel_Runtime_loadState() {
    return Runtime::loadState();
}

extern "C" void Eco_Kernel_Runtime_register_gc_roots() {
    Runtime::registerGcRootScanner();
}

extern "C" void Eco_Kernel_register_all_gc_roots() {
    Eco_Kernel_MVar_register_gc_roots();
    Eco_Kernel_Runtime_register_gc_roots();
}
