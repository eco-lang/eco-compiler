//===- EnvExports.cpp - C-linkage exports for Env module ------------------===//

#include "KernelExports.h"
#include "Env.hpp"

using namespace Eco::Kernel;
using Elm::HPtr;

HPtr Eco_Kernel_Env_lookup(HPtr name) {
    ECO_KERNEL_GUARD( return HPtr::fromBits(Env::lookup(name.toBits())); )
}

HPtr Eco_Kernel_Env_rawArgs() {
    ECO_KERNEL_GUARD( return HPtr::fromBits(Env::rawArgs()); )
}
