//===- ProcessExports.cpp - C-linkage exports for Process module -----------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "platform/Scheduler.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/Allocator.hpp"
#include <thread>
#include <chrono>
#include <atomic>
#include <memory>

using namespace Elm;
using namespace Elm::Kernel;
using Export::encode;
using Export::decode;

// Sleep binding callback evaluator
// Captured: args[0] = sleep time (as boxed Float encoded HPointer)
// Argument: args[1] = resume closure (HPointer)
static void* sleepBindingEvaluator(void* rawArgs[]) {
    uint64_t timeEnc = reinterpret_cast<uint64_t>(rawArgs[0]);
    uint64_t resumeEnc = reinterpret_cast<uint64_t>(rawArgs[1]);

    // Extract float value from the time argument
    HPointer timeHP = Export::decode(timeEnc);
    double millis = 0.0;
    void* timePtr = Allocator::instance().resolve(timeHP);
    if (timePtr) {
        ElmFloat* floatObj = static_cast<ElmFloat*>(timePtr);
        millis = floatObj->value;
    }

    // Create a shared cancelled flag for kill handle
    auto cancelled = std::make_shared<std::atomic<bool>>(false);
    auto cancelledForThread = cancelled;

    // Register the resume closure as a GC root for the lifetime of the
    // timer thread. A raw captured HPointer would become stale after any
    // GC on the main thread; the token-based registry keeps the closure
    // tracked and evacuated correctly.
    HPointer resumeHP = Export::decode(resumeEnc);
    uint64_t resumeToken =
        Elm::Platform::Scheduler::instance().registerPendingResume(resumeHP);

    // Track pending async work before spawning thread
    Elm::Platform::Scheduler::instance().incrementPendingAsync();

    // Spawn timer thread
    std::thread([resumeToken, millis, cancelledForThread]() {
        // Init GC for this thread so we can allocate heap objects
        Allocator::instance().initThread();

        // Sleep for the specified duration
        if (millis > 0) {
            std::this_thread::sleep_for(std::chrono::milliseconds(static_cast<int64_t>(millis)));
        }

        // Retrieve the (possibly-evacuated) resume closure and clear the
        // registry entry so its storage is freed on the next GC.
        HPointer resumeClosure =
            Elm::Platform::Scheduler::instance().takePendingResume(resumeToken);

        if (!cancelledForThread->load() && !Elm::alloc::isNil(resumeClosure)) {
            // Resume the process with Task.succeed(Unit)
            HPointer succeedTask = Elm::Platform::Scheduler::instance().taskSucceed(
                Elm::alloc::unit());

            // Call resume(succeedTask) — this calls enqueue() which just pushes
            // to the run queue and signals the CV (doesn't call drain)
            Elm::Platform::Scheduler::callClosure1(resumeClosure, succeedTask);
        }

        // Decrement AFTER enqueue to prevent transient (empty, 0) state
        Elm::Platform::Scheduler::instance().decrementPendingAsync();

        Allocator::instance().cleanupThread();
    }).detach();

    // Return a kill closure that sets the cancelled flag
    // For simplicity, return Unit (no kill support for now)
    // TODO: Create a proper kill closure that sets cancelled=true
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
