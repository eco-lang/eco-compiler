//===- SchedulerExports.cpp - C-linkage exports for Scheduler module -------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "Scheduler.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include <cassert>

using namespace Elm;
using namespace Elm::Kernel;

extern "C" {

uint64_t Elm_Kernel_Scheduler_succeed(uint64_t value) {
    // Create a Task that succeeds with the given value.
    // This requires a Task type - stub for now.
    (void)value;
    assert(false && "Elm_Kernel_Scheduler_succeed not implemented - requires Task type");
    return 0;
}

uint64_t Elm_Kernel_Scheduler_fail(uint64_t error) {
    // Create a Task that fails with the given error.
    (void)error;
    assert(false && "Elm_Kernel_Scheduler_fail not implemented - requires Task type");
    return 0;
}

uint64_t Elm_Kernel_Scheduler_andThen(uint64_t closure, uint64_t task) {
    // Create an andThen task that chains the callback after the task.
    (void)closure;
    (void)task;
    assert(false && "Elm_Kernel_Scheduler_andThen not implemented - requires Task type");
    return 0;
}

uint64_t Elm_Kernel_Scheduler_onError(uint64_t closure, uint64_t task) {
    // Create an onError task that handles errors.
    (void)closure;
    (void)task;
    assert(false && "Elm_Kernel_Scheduler_onError not implemented - requires Task type");
    return 0;
}

uint64_t Elm_Kernel_Scheduler_spawn(uint64_t task) {
    // Spawn a task as a new process.
    (void)task;
    assert(false && "Elm_Kernel_Scheduler_spawn not implemented - requires Task type");
    return 0;
}

uint64_t Elm_Kernel_Scheduler_kill(uint64_t process) {
    // Kill a process.
    (void)process;
    assert(false && "Elm_Kernel_Scheduler_kill not implemented - requires Task type");
    return 0;
}

} // extern "C"
