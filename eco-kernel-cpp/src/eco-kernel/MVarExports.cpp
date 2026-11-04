//===- MVarExports.cpp - C-linkage exports for MVar module ----------------===//

#include "KernelExports.h"
#include "KernelHelpers.hpp"
#include "MVar.hpp"
#include "TaskBinding.hpp"
#include "allocator/HeapHelpers.hpp"

using namespace Eco::Kernel;
using Elm::HPtr;

// Creates an empty MVar and returns a Task succeeding with its id. As the binding body of `MVar.new`, it
// runs each time that Task is run, so one Task value, shared or cached in a memoized CAF slot, yields a
// fresh MVar each time.
static Elm::HPointer mvarNewBody(Elm::HPointer /*captured*/) {
    int64_t id = MVar::newEmpty();
    // Task Never Int with the id stored unboxed in Task.value.
    return succeedInt(id);
}

extern "C" {

HPtr Eco_Kernel_MVar_new() {
    ECO_KERNEL_GUARD(
        return HPtr::fromBits(Export::encode(
            makeBinding<mvarNewBody>(Elm::alloc::unit())));
    )
}

HPtr Eco_Kernel_MVar_read(uint64_t id) {
    ECO_KERNEL_GUARD( return HPtr::fromBits(MVar::read(id)); )
}

HPtr Eco_Kernel_MVar_take(uint64_t id) {
    ECO_KERNEL_GUARD( return HPtr::fromBits(MVar::take(id)); )
}

HPtr Eco_Kernel_MVar_put(uint64_t id, HPtr value) {
    ECO_KERNEL_GUARD( return HPtr::fromBits(MVar::put(id, value.toBits())); )
}

// Per-instance variants. The MVar slot stores an HPointer, so the primitive is boxed here, which lets the
// call site keep the value unboxed. Nothing allocates between the boxing and the StackRootGuard in
// MVar::put, so the box needs no rooting of its own.
HPtr Eco_Kernel_MVar_put_Int(uint64_t id, int64_t value) {
    ECO_KERNEL_GUARD(
        Elm::HPointer boxed = Elm::alloc::allocInt(value);
        return HPtr::fromBits(MVar::put(id, Export::encode(boxed)));
    )
}

HPtr Eco_Kernel_MVar_put_Float(uint64_t id, double value) {
    ECO_KERNEL_GUARD(
        Elm::HPointer boxed = Elm::alloc::allocFloat(value);
        return HPtr::fromBits(MVar::put(id, Export::encode(boxed)));
    )
}

// The Char (a code point) arrives as uint64_t, and only its low 32 bits are used.
HPtr Eco_Kernel_MVar_put_Char(uint64_t id, uint64_t value_raw) {
    ECO_KERNEL_GUARD(
        Elm::HPointer boxed = Elm::alloc::allocChar(static_cast<u32>(value_raw & 0xFFFFFFFFu));
        return HPtr::fromBits(MVar::put(id, Export::encode(boxed)));
    )
}

HPtr Eco_Kernel_MVar_drop(uint64_t id) {
    ECO_KERNEL_GUARD( return HPtr::fromBits(MVar::drop(id)); )
}

extern "C" void Eco_Kernel_MVar_register_gc_roots() {
    MVar::registerGcRootScanner();
}

} // extern "C"
