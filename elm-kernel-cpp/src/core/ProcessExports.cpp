//===- ProcessExports.cpp - C-linkage exports for Process module -----------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "platform/Scheduler.hpp"
#include "platform/TimerService.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/Allocator.hpp"
#include <cstring>

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
    // Captured: [0] = unboxed Float (PK_Float). Passed: [1] = resume closure.
    //
    // Per the Phase E typed-args convention (REP_ABI_001),
    // `eco_closure_call_saturated` delivers a PK_Float capture as the raw
    // IEEE-754 bits in rawArgs[0], NOT as an HPointer-to-ElmFloat. Recover
    // the double by bit-casting from the uint64_t.
    uint64_t timeBits  = reinterpret_cast<uint64_t>(rawArgs[0]);
    uint64_t resumeEnc = reinterpret_cast<uint64_t>(rawArgs[1]);

    double millis;
    std::memcpy(&millis, &timeBits, sizeof(double));

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
    // Create a binding callback closure that captures the time as an unboxed
    // Float; the runtime re-boxes it before invoking sleepBindingEvaluator.
    HPointer bindingCB = Elm::alloc::allocClosure(
        reinterpret_cast<EvalFunction>(sleepBindingEvaluator), 2);
    void* cbPtr = Allocator::instance().resolve(bindingCB);
    if (cbPtr) {
        Elm::alloc::closureCapture(cbPtr, Elm::alloc::unboxedFloat(time),
                                   Elm::PK_Float);
    }

    // Create a Binding task with this callback
    HPointer task = Elm::Platform::Scheduler::instance().taskBinding(bindingCB);
    return HPtr::fromBits(encode(task));
}

} // extern "C"
