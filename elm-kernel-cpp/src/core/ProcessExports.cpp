//===- ProcessExports.cpp - C-linkage exports for Process module -----------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "platform/Scheduler.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
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

    // Spawn timer thread
    std::thread([resumeEnc, millis, cancelledForThread]() {
        // Sleep for the specified duration
        if (millis > 0) {
            std::this_thread::sleep_for(std::chrono::milliseconds(static_cast<int64_t>(millis)));
        }

        if (!cancelledForThread->load()) {
            // Resume the process with Task.succeed(Unit)
            HPointer succeedTask = Elm::Platform::Scheduler::instance().taskSucceed(
                Elm::alloc::unit());
            HPointer resumeClosure = Export::decode(resumeEnc);

            // Call resume(succeedTask)
            Elm::Platform::Scheduler::callClosure1(resumeClosure, succeedTask);
        }
    }).detach();

    // Return a kill closure that sets the cancelled flag
    // For simplicity, return Unit (no kill support for now)
    // TODO: Create a proper kill closure that sets cancelled=true
    return reinterpret_cast<void*>(encode(Elm::alloc::unit()));
}

extern "C" {

uint64_t Elm_Kernel_Process_sleep(double time) {
    // Create a boxed Float for the time value
    HPointer timeHP = Elm::alloc::allocFloat(time);

    // Create a binding callback closure that captures the time
    HPointer bindingCB = Elm::alloc::allocClosure(
        reinterpret_cast<EvalFunction>(sleepBindingEvaluator), 2);
    void* cbPtr = Allocator::instance().resolve(bindingCB);
    if (cbPtr) {
        Elm::alloc::closureCapture(cbPtr, Elm::alloc::boxed(timeHP), true);
    }

    // Create a Binding task with this callback
    HPointer task = Elm::Platform::Scheduler::instance().taskBinding(bindingCB);
    return encode(task);
}

} // extern "C"
