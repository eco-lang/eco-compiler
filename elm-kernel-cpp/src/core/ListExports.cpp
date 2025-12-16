//===- ListExports.cpp - C-linkage exports for List module -----------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "List.hpp"
#include "allocator/HeapHelpers.hpp"

using namespace Elm;
using namespace Elm::Kernel;

extern "C" {

// Simple cons that treats head as boxed pointer.
// For unboxed primitives, a different signature would be needed.
uint64_t Elm_Kernel_List_cons(uint64_t head, uint64_t tail) {
    Unboxable headVal;
    headVal.p = Export::decode(head);
    HPointer result = List::cons(headVal, Export::decode(tail), true);
    return Export::encode(result);
}

} // extern "C"
