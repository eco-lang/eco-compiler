//===- TaskBinding.hpp - Generic Task_Binding helper -----------------------===//
//
// A kernel function that returns an Elm Task must not do its IO when it is
// called, only when the Task is run, because a Task is a value that may be
// built once and run many times, or never (invariant KERNEL_TASK_IO_001). This
// header lets a kernel meet that rule by writing its IO as a body function and
// wrapping it in a Binding Task (a Task whose step is a callback closure),
// which the scheduler calls each time it steps the Task.
//
// A body comes in one of two shapes. A synchronous body (`BindingBody`) does
// its work when called and returns the Task to continue with; `makeBinding`
// wraps it. An async-park body (`AsyncBindingBody`) starts work that finishes
// later, keeps the resume closure so the result can be delivered then, and
// returns at once; `makeAsyncBinding` wraps it.
//
// Every body receives one captured payload, an HPointer the kernel builds before
// wrapping: a single value, a tuple or record of several (built with the
// HeapHelpers `tuple2`, `tuple3` or `record`), or `unit()` when there is
// nothing to capture. The body unpacks it with `Allocator::instance().resolve`.
//
//   static HPointer myBody(HPointer captured) {
//       ... do IO ...
//       return Scheduler::instance().taskSucceed(...);
//   }
//
//   HPtr Some_Kernel_Function(HPtr arg) {
//       HPointer argHP = decode(arg.toBits());
//       return HPtr::fromBits(encode(
//           Elm::Platform::makeBinding<myBody>(argHP)));
//   }
//
//===----------------------------------------------------------------------===//

#ifndef ELM_PLATFORM_TASK_BINDING_HPP
#define ELM_PLATFORM_TASK_BINDING_HPP

#include "allocator/Allocator.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "platform/Scheduler.hpp"

namespace Elm::Platform {

// A synchronous body: does the work for `captured` and returns the Task to
// continue with, normally one built by `Scheduler::taskSucceed` or `taskFail`.
// It may allocate, but the trampoline roots only its own copy of `captured`:
// the body's parameter is an unrooted copy that a moving GC will not update.
// A body that allocates must root `captured` (and, for an async body,
// `resume`) itself, or unpack them before its first allocation.
using BindingBody      = HPointer (*)(HPointer captured);
// An async-park body: like `BindingBody`, but it is also given the resume
// closure, and returns the binding's kill handle (see `makeAsyncBinding`).
using AsyncBindingBody = HPointer (*)(HPointer captured, HPointer resume);

namespace detail {

// Returns the 64 bits of `h` as an integer, unchanged.
inline uint64_t encodeBits(HPointer h) {
    union { HPointer hp; uint64_t val; } u;
    u.hp = h;
    return u.val;
}

// Returns the HPointer whose 64 bits are `v`; the inverse of `encodeBits`.
inline HPointer decodeBits(uint64_t v) {
    union { HPointer hp; uint64_t val; } u;
    u.val = v;
    return u.hp;
}

// The closure evaluator for a binding made by `makeBinding<Body>`. One is
// instantiated per `Body`.
//
// `rawArgs[0]` is the captured payload and `rawArgs[1]` the resume closure the
// scheduler supplies. Calls `Body(captured)`, passes the Task it returns to the
// resume closure with `Scheduler::callClosure1`, and returns `unit()` as the
// kill handle, encoded as a pointer. Cancelling in-flight work is not
// modelled.
template <BindingBody Body>
inline void* bindingTrampoline(void* rawArgs[]) {
    uint64_t capturedEnc = reinterpret_cast<uint64_t>(rawArgs[0]);
    uint64_t resumeEnc   = reinterpret_cast<uint64_t>(rawArgs[1]);
    HPointer captured = decodeBits(capturedEnc);
    HPointer resume   = decodeBits(resumeEnc);

    HPointer task = alloc::unit();
    {
        // Rooted before `Body` runs, since it and the resume call may allocate
        // and move all three.
        Elm::StackRootGuard guard(&captured, &resume, &task);
        task = Body(captured);
        Scheduler::callClosure1(resume, task);
    }

    return reinterpret_cast<void*>(encodeBits(alloc::unit()));
}

// The closure evaluator for a binding made by `makeAsyncBinding<Body>`. One is
// instantiated per `Body`.
//
// Calls `Body(captured, resume)` with the two arguments as in
// `bindingTrampoline`, and returns what the body returns, encoded as a
// pointer, as the kill handle. It never calls the resume closure itself.
//
// When `Scheduler::holdCensusEnabled()`, it checks that the body either
// enqueued something or acquired a hold (holds are defined in Liveness.hpp),
// by comparing `enqueueSerial` and `acquireSerial` before and after. A body
// that did neither is reported to `Scheduler::noteHoldlessPark` under this
// function's name. In builds without the census, no check is made.
template <AsyncBindingBody Body>
inline void* asyncBindingTrampoline(void* rawArgs[]) {
    uint64_t capturedEnc = reinterpret_cast<uint64_t>(rawArgs[0]);
    uint64_t resumeEnc   = reinterpret_cast<uint64_t>(rawArgs[1]);
    HPointer captured = decodeBits(capturedEnc);
    HPointer resume   = decodeBits(resumeEnc);

    HPointer killHandle = alloc::unit();
    auto& sched = Scheduler::instance();
    const bool check = sched.holdCensusEnabled();
    const u64 acq0 = check ? sched.acquireSerial() : 0;
    const u64 enq0 = check ? sched.enqueueSerial() : 0;
    {
        Elm::StackRootGuard guard(&captured, &resume, &killHandle);
        killHandle = Body(captured, resume);
    }
    if (check && sched.acquireSerial() == acq0 && sched.enqueueSerial() == enq0) {
        sched.noteHoldlessPark(__PRETTY_FUNCTION__);
    }
    return reinterpret_cast<void*>(encodeBits(killHandle));
}

} // namespace detail

// Returns a new Binding Task that, each time the scheduler steps it, calls
// `Body(captured)` and continues with the Task the body returns.
//
// `captured` is stored boxed in the binding's closure and stays reachable for
// as long as the Task does; if `resolve(cb)` returns null the capture is
// skipped and the closure holds no payload. Making the Task does no IO. Allocates.
template <BindingBody Body>
inline HPointer makeBinding(HPointer captured) {
    Elm::StackRootGuard capRoot(&captured);

    // Two slots: the payload, captured here, and the resume closure, which the
    // scheduler supplies when it steps the binding.
    HPointer cb = alloc::allocClosureK(
        reinterpret_cast<EvalFunction>(&detail::bindingTrampoline<Body>),
        /*max_values=*/2, PK_Boxed);

    void* cbPtr = Allocator::instance().resolve(cb);
    if (cbPtr) {
        alloc::closureCapture(cbPtr, alloc::boxed(captured), /*is_boxed=*/true);
    }

    return Scheduler::instance().taskBinding(cb);
}

// Returns a new Binding Task that, each time the scheduler steps it, calls
// `Body(captured, resume)` with the resume closure of that run.
//
// The body must, before returning, either resume synchronously (call
// `resume`, which enqueues the process) or keep `resume` under a hold:
// `Scheduler::parkResume`, or `Scheduler::registerPendingResume` plus a hold
// the kernel owns. Otherwise nothing keeps the event loop running until the
// result arrives, so the Task can be dropped silently; only census builds
// report it (see `asyncBindingTrampoline`). The body's return value becomes
// the kill handle; `unit()` when there is nothing to cancel.
//
// `captured` is stored as in `makeBinding`, with the same null-`resolve` skip. Allocates.
template <AsyncBindingBody Body>
inline HPointer makeAsyncBinding(HPointer captured) {
    Elm::StackRootGuard capRoot(&captured);

    HPointer cb = alloc::allocClosureK(
        reinterpret_cast<EvalFunction>(&detail::asyncBindingTrampoline<Body>),
        /*max_values=*/2, PK_Boxed);

    void* cbPtr = Allocator::instance().resolve(cb);
    if (cbPtr) {
        alloc::closureCapture(cbPtr, alloc::boxed(captured), /*is_boxed=*/true);
    }

    return Scheduler::instance().taskBinding(cb);
}

} // namespace Elm::Platform

#endif // ELM_PLATFORM_TASK_BINDING_HPP
