//===- ProcessExports.cpp - C-linkage exports for Process module -----------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "platform/Scheduler.hpp"
#include "platform/TimerService.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/Allocator.hpp"

using namespace Elm;
using namespace Elm::Kernel;
using Export::encode;
using Export::decode;

// Sleep binding callback evaluator — runs on the main scheduler thread.
// Captured: args[0] = sleep time (boxed Float encoded HPointer)
// Argument: args[1] = resume closure (HPointer)
//
// All this does is register the resume closure as a GC root, bump
// pendingAsync_, and hand a (millis, token) pair to TimerService. The
// expiration — including taskSucceed/callClosure1 — runs on main via
// Scheduler::processReadyAsync; no cross-thread GC interaction.
static void* sleepBindingEvaluator(void* rawArgs[]) {
    uint64_t timeEnc   = reinterpret_cast<uint64_t>(rawArgs[0]);
    uint64_t resumeEnc = reinterpret_cast<uint64_t>(rawArgs[1]);

    HPointer timeHP = Export::decode(timeEnc);
    double millis = 0.0;
    if (void* timePtr = Allocator::instance().resolve(timeHP)) {
        millis = static_cast<ElmFloat*>(timePtr)->value;
    }

    HPointer resumeHP = Export::decode(resumeEnc);
    uint64_t resumeToken =
        Elm::Platform::Scheduler::instance().registerPendingResume(resumeHP);

    Elm::Platform::Scheduler::instance().incrementPendingAsync();
    Elm::Platform::TimerService::instance().schedule(millis, resumeToken);

    // Kill handle: status-quo Unit placeholder. Cancellation is deferred
    // (see plans/dumb-timer-threads.md Q3).
    return reinterpret_cast<void*>(encode(Elm::alloc::unit()));
}

extern "C" {

HPtr Elm_Kernel_Process_sleep(double time) {
    // Create a boxed Float for the time value
    HPointer timeHP = Elm::alloc::allocFloat(time);

    // Root timeHP across allocClosure (which may trigger GC)
    Elm::StackRootGuard guard(&timeHP);

    // Create a binding callback closure that captures the time
    HPointer bindingCB = Elm::alloc::allocClosure(
        reinterpret_cast<EvalFunction>(sleepBindingEvaluator), 2);
    void* cbPtr = Allocator::instance().resolve(bindingCB);
    if (cbPtr) {
        Elm::alloc::closureCapture(cbPtr, Elm::alloc::boxed(timeHP), true);
    }

    // Create a Binding task with this callback
    HPointer task = Elm::Platform::Scheduler::instance().taskBinding(bindingCB);
    return HPtr::fromBits(encode(task));
}

} // extern "C"
