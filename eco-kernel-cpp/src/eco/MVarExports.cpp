//===- MVarExports.cpp - C-linkage exports for MVar module ----------------===//

#include "KernelExports.h"
#include "KernelHelpers.hpp"
#include "MVar.hpp"
#include "allocator/HeapHelpers.hpp"

using namespace Eco::Kernel;
using Elm::HPtr;

extern "C" {

HPtr Eco_Kernel_MVar_new() {
    int64_t id = MVar::newEmpty();
    // Wrap as Task Never Int: taskSucceed(boxed Int).
    Elm::HPointer boxedId = Elm::alloc::allocInt(id);
    return HPtr::fromBits(taskSucceed(boxedId));
}

HPtr Eco_Kernel_MVar_read(uint64_t id) {
    return HPtr::fromBits(MVar::read(id));
}

HPtr Eco_Kernel_MVar_take(uint64_t id) {
    return HPtr::fromBits(MVar::take(id));
}

HPtr Eco_Kernel_MVar_put(uint64_t id, HPtr value) {
    return HPtr::fromBits(MVar::put(id, value.toBits()));
}

HPtr Eco_Kernel_MVar_drop(uint64_t id) {
    return HPtr::fromBits(MVar::drop(id));
}

extern "C" void Eco_Kernel_MVar_register_gc_roots() {
    MVar::registerGcRootScanner();
}

} // extern "C"
