//===- EnvExports.cpp - C-linkage exports for Env module ------------------===//

#include "KernelExports.h"
#include "Env.hpp"

using namespace Eco::Kernel;
using Elm::HPtr;

HPtr Eco_Kernel_Env_lookup(HPtr name) {
    return HPtr::fromBits(Env::lookup(name.toBits()));
}

HPtr Eco_Kernel_Env_rawArgs() {
    return HPtr::fromBits(Env::rawArgs());
}
