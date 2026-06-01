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

// Phase-0 validation site for the generic Task_Binding helper
// (`plans/defer-eager-kernel-tasks-via-binding.md`, Section "Phase 0 — 0.2").
//
// Sleep is an ASYNC-PARK binding: the body registers `resume` with the
// scheduler's pending-resume registry and hands a (millis, token) pair to
// TimerService. The Task is delivered later via Scheduler::processReadyAsync.
// The captured payload is a single boxed ElmFloat (per Q2 — no kind-inferred
// raw-primitive captures); boxing is a microsecond-scale allocation and the
// uniformity wins over the small per-call float-box overhead.
static HPointer sleepBindingBody(HPointer captured, HPointer resume) {
    void* ptr = Allocator::instance().resolve(captured);
    double millis = static_cast<ElmFloat*>(ptr)->value;

    uint64_t resumeToken =
        Elm::Platform::Scheduler::instance().registerPendingResume(resume);
    Elm::Platform::Scheduler::instance().incrementPendingAsync();
    Elm::Platform::TimerService::instance().schedule(millis, resumeToken);

    // Kill handle: status-quo Unit placeholder (cancellation deferred —
    // plans/dumb-timer-threads.md Q3).
    return Elm::alloc::unit();
}

extern "C" {

HPtr Elm_Kernel_Process_sleep(double time) {
    // Box the float once so the binding payload follows the standard
    // HPointer-only capture shape used by makeBinding /
    // makeAsyncBinding. The previous PK_Float capture worked fine but
    // required the closureCapture/typed-args path to special-case the kind;
    // the boxed shape is uniform with every other deferred kernel.
    HPointer floatHP = Elm::alloc::allocFloat(time);
    return HPtr::fromBits(encode(
        Elm::Platform::makeAsyncBinding<sleepBindingBody>(floatHP)));
}

} // extern "C"
