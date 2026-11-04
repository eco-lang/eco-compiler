//===- GCExports.cpp - C-linkage exports for the GC module ----------------===//

#include "KernelExports.h"
#include "GC.hpp"

using namespace Eco::Kernel;
using Elm::HPtr;

HPtr Eco_Kernel_GC_minorGC() {
    ECO_KERNEL_GUARD( return HPtr::fromBits(GC::minorGC()); )
}

HPtr Eco_Kernel_GC_majorGC() {
    ECO_KERNEL_GUARD( return HPtr::fromBits(GC::majorGC()); )
}
