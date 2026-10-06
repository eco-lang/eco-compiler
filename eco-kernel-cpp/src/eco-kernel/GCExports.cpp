//===- GCExports.cpp - C-linkage exports for the GC module ----------------===//
//
// plans/frontend-heap-release.md §4.3 (HEAP_076).

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
