//===- SchedulerExports.cpp - C-linkage exports for Scheduler module -------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "platform/Scheduler.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"

using namespace Elm;
using namespace Elm::Kernel;
using Export::encode;
using Export::decode;

extern "C" {

uint64_t Elm_Kernel_Scheduler_succeed(uint64_t value) {
    HPointer v = decode(value);
    HPointer t = Elm::Platform::Scheduler::instance().taskSucceed(v);
    return encode(t);
}

uint64_t Elm_Kernel_Scheduler_fail(uint64_t error) {
    HPointer e = decode(error);
    HPointer t = Elm::Platform::Scheduler::instance().taskFail(e);
    return encode(t);
}

uint64_t Elm_Kernel_Scheduler_andThen(uint64_t closure, uint64_t task) {
    HPointer cb = decode(closure);
    HPointer tk = decode(task);
    HPointer t = Elm::Platform::Scheduler::instance().taskAndThen(cb, tk);
    return encode(t);
}

uint64_t Elm_Kernel_Scheduler_onError(uint64_t closure, uint64_t task) {
    HPointer cb = decode(closure);
    HPointer tk = decode(task);
    HPointer t = Elm::Platform::Scheduler::instance().taskOnError(cb, tk);
    return encode(t);
}

uint64_t Elm_Kernel_Scheduler_spawn(uint64_t task) {
    HPointer tk = decode(task);
    HPointer t = Elm::Platform::Scheduler::instance().spawnTask(tk);
    return encode(t);
}

uint64_t Elm_Kernel_Scheduler_kill(uint64_t process) {
    HPointer proc = decode(process);
    HPointer t = Elm::Platform::Scheduler::instance().killTask(proc);
    return encode(t);
}

} // extern "C"
