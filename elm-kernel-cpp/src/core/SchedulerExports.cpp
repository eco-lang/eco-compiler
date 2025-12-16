//===- SchedulerExports.cpp - C-linkage exports for Scheduler module -------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "Scheduler.hpp"
#include "allocator/HeapHelpers.hpp"

using namespace Elm::Kernel;

extern "C" {

// Scheduler functions that take/return Tasks need special handling.
// For now, these are stubs that return placeholder values.
// Full implementation requires Task type to be represented as heap objects.

uint64_t Elm_Kernel_Scheduler_succeed(uint64_t value) {
    // Create a Task that succeeds with the given value
    // For now, return the value as-is (stub)
    return value;
}

uint64_t Elm_Kernel_Scheduler_fail(uint64_t error) {
    // Create a Task that fails with the given error
    // For now, return the error as-is (stub)
    return error;
}

} // extern "C"
