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

HPtr Elm_Kernel_Scheduler_succeed(HPtr value) {
    uint64_t value_bits = value.toBits();
    HPointer v = decode(value_bits);
    HPointer t = Elm::Platform::Scheduler::instance().taskSucceed(v);
    return HPtr::fromBits(encode(t));
}

HPtr Elm_Kernel_Scheduler_fail(HPtr error) {
    uint64_t error_bits = error.toBits();
    HPointer e = decode(error_bits);
    HPointer t = Elm::Platform::Scheduler::instance().taskFail(e);
    return HPtr::fromBits(encode(t));
}

HPtr Elm_Kernel_Scheduler_andThen(HPtr closure, HPtr task) {
    uint64_t closure_bits = closure.toBits();
    uint64_t task_bits = task.toBits();
    HPointer cb = decode(closure_bits);
    HPointer tk = decode(task_bits);
    HPointer t = Elm::Platform::Scheduler::instance().taskAndThen(cb, tk);
    return HPtr::fromBits(encode(t));
}

HPtr Elm_Kernel_Scheduler_onError(HPtr closure, HPtr task) {
    uint64_t closure_bits = closure.toBits();
    uint64_t task_bits = task.toBits();
    HPointer cb = decode(closure_bits);
    HPointer tk = decode(task_bits);
    HPointer t = Elm::Platform::Scheduler::instance().taskOnError(cb, tk);
    return HPtr::fromBits(encode(t));
}

HPtr Elm_Kernel_Scheduler_spawn(HPtr task) {
    uint64_t task_bits = task.toBits();
    HPointer tk = decode(task_bits);
    HPointer t = Elm::Platform::Scheduler::instance().spawnTask(tk);
    return HPtr::fromBits(encode(t));
}

HPtr Elm_Kernel_Scheduler_kill(HPtr process) {
    uint64_t process_bits = process.toBits();
    HPointer proc = decode(process_bits);
    HPointer t = Elm::Platform::Scheduler::instance().killTask(proc);
    return HPtr::fromBits(encode(t));
}

} // extern "C"
