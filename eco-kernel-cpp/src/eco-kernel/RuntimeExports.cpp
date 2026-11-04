//===- RuntimeExports.cpp - C-linkage exports for Runtime module ----------===//
//
// The kernel entry points of `Eco.Runtime` and the GC root hooks. Their contracts are on their declarations in
// `KernelExports.h`. Each Runtime export converts between the `HPtr` of that declaration and the 64-bit word the
// `Eco::Kernel::Runtime` functions take and return; `random` returns that word unchanged.
//===----------------------------------------------------------------------===//

#include "KernelExports.h"
#include "Runtime.hpp"

using namespace Eco::Kernel;
using Elm::HPtr;

HPtr Eco_Kernel_Runtime_dirname() {
    ECO_KERNEL_GUARD( return HPtr::fromBits(Runtime::dirname()); )
}

uint64_t Eco_Kernel_Runtime_random() {
    ECO_KERNEL_GUARD( return Runtime::random(); )
}

HPtr Eco_Kernel_Runtime_saveState(HPtr state) {
    ECO_KERNEL_GUARD( return HPtr::fromBits(Runtime::saveState(state.toBits())); )
}

HPtr Eco_Kernel_Runtime_loadState() {
    ECO_KERNEL_GUARD( return HPtr::fromBits(Runtime::loadState()); )
}

extern "C" void Eco_Kernel_Runtime_register_gc_roots() {
    Runtime::registerGcRootScanner();
}

// elm-kernel-cpp's hook that registers the scanner for its Order values, defined in its core Utils exports. Off
// Windows it is declared weak, so the aggregate hook below still links without elm-kernel-cpp, and the address test
// there skips it. clang-cl turns a weak declaration into a weak definition that lld-link reports as a duplicate
// under /WHOLEARCHIVE, so on Windows the declaration is strong, and the runtime's
// `eco_order_weak_stub_win32.cpp` supplies a no-op default through /alternatename when no real definition is linked.
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
