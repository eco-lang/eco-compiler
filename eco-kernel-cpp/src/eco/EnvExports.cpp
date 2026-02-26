//===- EnvExports.cpp - C-linkage exports for Env module ------------------===//

#include "KernelExports.h"
#include "Env.hpp"

using namespace Eco::Kernel;

uint64_t Eco_Kernel_Env_lookup(uint64_t name) {
    return Env::lookup(name);
}

uint64_t Eco_Kernel_Env_rawArgs() {
    return Env::rawArgs();
}
