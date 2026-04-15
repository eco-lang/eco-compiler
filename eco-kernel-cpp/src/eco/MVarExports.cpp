//===- MVarExports.cpp - C-linkage exports for MVar module ----------------===//

#include "KernelExports.h"
#include "KernelHelpers.hpp"
#include "MVar.hpp"
#include "allocator/HeapHelpers.hpp"

using namespace Eco::Kernel;

uint64_t Eco_Kernel_MVar_new() {
    int64_t id = MVar::newEmpty();
    // Wrap as Task Never Int: taskSucceed(boxed Int).
    Elm::HPointer boxedId = Elm::alloc::allocInt(id);
    return taskSucceed(boxedId);
}

uint64_t Eco_Kernel_MVar_read(uint64_t id) {
    return MVar::read(id);
}

uint64_t Eco_Kernel_MVar_take(uint64_t id) {
    return MVar::take(id);
}

uint64_t Eco_Kernel_MVar_put(uint64_t id, uint64_t value) {
    return MVar::put(id, value);
}

uint64_t Eco_Kernel_MVar_drop(uint64_t id) {
    return MVar::drop(id);
}

extern "C" void Eco_Kernel_MVar_register_gc_roots() {
    MVar::registerGcRootScanner();
}
