//===- MVarExports.cpp - C-linkage exports for MVar module ----------------===//

#include "KernelExports.h"
#include "MVar.hpp"

using namespace Eco::Kernel;

int64_t Eco_Kernel_MVar_new() {
    return MVar::newEmpty();
}

uint64_t Eco_Kernel_MVar_read(uint64_t typeTag, uint64_t id) {
    return MVar::read(typeTag, id);
}

uint64_t Eco_Kernel_MVar_take(uint64_t typeTag, uint64_t id) {
    return MVar::take(typeTag, id);
}

uint64_t Eco_Kernel_MVar_put(uint64_t typeTag, uint64_t id, uint64_t value) {
    return MVar::put(typeTag, id, value);
}
