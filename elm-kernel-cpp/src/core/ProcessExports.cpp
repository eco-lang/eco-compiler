//===- ProcessExports.cpp - C-linkage exports for Process module -----------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "platform/Scheduler.hpp"
#include "platform/TaskBinding.hpp"
#include "platform/TimerService.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/Allocator.hpp"
#include <cstring>

using namespace Elm;
using namespace Elm::Kernel;
using Export::encode;
using Export::decode;

// Withdraws a sleep's timer and returns Unit. This is the evaluator of the sleep's kill handle: `args[0]` is
// the captured resume token, as raw Int bits, and `args[1]` is the `()` the handle is applied to. Must run on
// the eco thread, as `withdrawParkedTimer` requires.
static void* sleepKillEval(void* args[]) {
    uint64_t token = reinterpret_cast<uint64_t>(args[0]);
    Elm::Platform::withdrawParkedTimer(token);
    return reinterpret_cast<void*>(encode(Elm::alloc::unit()));
}

// Starts one run of a sleep and returns its kill handle. `captured` is the boxed `ElmFloat` delay in
// milliseconds. Parks `resume` under a Task hold, schedules a timer for the delay carrying the resume token,
// and returns a closure of `sleepKillEval` that captures the token. Allocates.
static HPointer sleepBindingBody(HPointer captured, HPointer resume) {
    void* ptr = Allocator::instance().resolve(captured);
    double millis = static_cast<ElmFloat*>(ptr)->value;

    uint64_t resumeToken = Elm::Platform::Scheduler::instance().parkResume(
        resume, Elm::Platform::HoldKind::Task, "Process.sleep");
    Elm::Platform::TimerService::instance().schedule(millis, resumeToken);

    // Killing the sleep withdraws its timer (see `withdrawParkedTimer` for when the hold is released). The
    // token is captured unboxed, and nothing allocates between `allocClosureK` and the capture, so `p` stays
    // valid.
    HPointer kill = Elm::alloc::allocClosureK(&sleepKillEval, /*max_values=*/2, Elm::PK_Boxed);
    void* p = Allocator::instance().resolve(kill);
    Elm::alloc::closureCapture(p, Elm::alloc::unboxedInt(static_cast<int64_t>(resumeToken)),
                               Elm::PK_Int);
    return kill;
}

extern "C" {

HPtr Elm_Kernel_Process_sleep(double time) {
    // The delay is boxed because `makeAsyncBinding` captures its payload as a boxed value.
    HPointer floatHP = Elm::alloc::allocFloat(time);
    return HPtr::fromBits(encode(
        Elm::Platform::makeAsyncBinding<sleepBindingBody>(floatHP)));
}

} // extern "C"
