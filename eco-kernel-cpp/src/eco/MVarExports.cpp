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
    // Wrap as Task Never Int with the id stored unboxed in Task.value.
    return HPtr::fromBits(taskSucceedInt(id));
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

// Per-instance variants. The MVar slot stores an HPointer, so the primitive
// must be boxed somewhere; doing it here lets the call site keep the value
// unboxed in SSA and skip the boxing op in MLIR. eco_alloc_* may trigger GC,
// so the StackRootGuard inside MVar::put picks up the freshly-allocated
// pointer; we don't need to root anything before the call because the
// Allocator returns a fresh HPointer.
HPtr Eco_Kernel_MVar_put_Int(uint64_t id, int64_t value) {
    Elm::HPointer boxed = Elm::alloc::allocInt(value);
    return HPtr::fromBits(MVar::put(id, Export::encode(boxed)));
}

HPtr Eco_Kernel_MVar_put_Float(uint64_t id, double value) {
    Elm::HPointer boxed = Elm::alloc::allocFloat(value);
    return HPtr::fromBits(MVar::put(id, Export::encode(boxed)));
}

HPtr Eco_Kernel_MVar_put_Char(uint64_t id, uint16_t value) {
    Elm::HPointer boxed = Elm::alloc::allocChar(value);
    return HPtr::fromBits(MVar::put(id, Export::encode(boxed)));
}

HPtr Eco_Kernel_MVar_drop(uint64_t id) {
    return HPtr::fromBits(MVar::drop(id));
}

extern "C" void Eco_Kernel_MVar_register_gc_roots() {
    MVar::registerGcRootScanner();
}

} // extern "C"
