//===- RuntimeExports.cpp - C-linkage exports for Runtime module ----------===//

#include "KernelExports.h"
#include "Runtime.hpp"

using namespace Eco::Kernel;
using Elm::HPtr;

HPtr Eco_Kernel_Runtime_dirname() {
    return HPtr::fromBits(Runtime::dirname());
}

uint64_t Eco_Kernel_Runtime_random() {
    return Runtime::random();
}

HPtr Eco_Kernel_Runtime_saveState(HPtr state) {
    return HPtr::fromBits(Runtime::saveState(state.toBits()));
}

HPtr Eco_Kernel_Runtime_loadState() {
    return HPtr::fromBits(Runtime::loadState());
}

extern "C" void Eco_Kernel_Runtime_register_gc_roots() {
    Runtime::registerGcRootScanner();
}

extern "C" void Eco_Kernel_register_all_gc_roots() {
    Eco_Kernel_MVar_register_gc_roots();
    Eco_Kernel_Runtime_register_gc_roots();
}
