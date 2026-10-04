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

// Registers the Order LT/EQ/GT singleton slots used by the
// eco.{int,float,char}.cmp_order intrinsics. Defined in elm-kernel-cpp/Utils;
// declared weak here so this aggregator still links if ElmKernel is omitted
// (e.g. minimal Eco-only builds).
// clang-cl's __attribute__((weak)) on a function declaration emits a
// COMDAT weak external — under /WHOLEARCHIVE every translation unit
// that decl-sites the symbol contributes a definition, and lld-link
// flags the duplicates. On Windows we drop the weak attribute and rely
// on the /alternatename fallback baked into eco_order_weak_stub_win32.cpp
// (a default no-op that resolves the symbol if no real definition is
// linked from ElmKernel_Utils).
#if defined(_WIN32)
extern "C" void Eco_Kernel_Order_register_gc_roots();
#else
extern "C" __attribute__((weak)) void Eco_Kernel_Order_register_gc_roots();
#endif

extern "C" void Eco_Kernel_register_all_gc_roots() {
    Eco_Kernel_MVar_register_gc_roots();
    Eco_Kernel_Runtime_register_gc_roots();
    if (Eco_Kernel_Order_register_gc_roots)
        Eco_Kernel_Order_register_gc_roots();
}
