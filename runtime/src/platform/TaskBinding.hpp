//===- TaskBinding.hpp - Generic Task_Binding helper -----------------------===//
//
// `makeBinding<Body>(captured)` packages a synchronous body function as an
// Elm Task_Binding so the syscall / blocking work happens INSIDE the body —
// when the scheduler steps the binding — rather than at the kernel call
// site. Mandated for all Task-returning IO kernels by KERNEL_TASK_IO_001
// (see design_docs/invariants.csv) and the plan
// `plans/defer-eager-kernel-tasks-via-binding.md`.
//
// USAGE
//
//   // Body: receives the captured payload HPointer (built by the kernel
//   // function before calling makeBinding) and returns the Task to deliver
//   // to the scheduler-supplied `resume` continuation. The body may
//   // allocate freely; `captured` and `resume` are rooted across the call.
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
// SHAPE CHOICE
//
// The helper takes a SINGLE `HPointer captured` "payload" rather than a
// type-inferred variadic capture list. For multi-arg kernels, the caller
// packs the args into an Elm Tuple2 / Tuple3 / Record using the existing
// HeapHelpers (`tuple2`, `tuple3`, `record`); the body unpacks them via the
// usual `Allocator::instance().resolve(captured)` cast.
//
// Rationale: the Elm/native heap boundary stays explicit (every captured
// value is an HPointer, no raw int/float aliasing), the existing GC bitmap
// and rooting rules apply unchanged, and the helper signature is trivial.
//
//===----------------------------------------------------------------------===//

#ifndef ELM_PLATFORM_TASK_BINDING_HPP
#define ELM_PLATFORM_TASK_BINDING_HPP

#include "allocator/Allocator.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "platform/Scheduler.hpp"

namespace Elm::Platform {

// Two binding shapes exist in the codebase. Both are supported here so the
// helper can replace every hand-rolled evaluator in scope:
//
//   * SYNCHRONOUS-IN-BINDING (`BindingBody`): the body runs the IO inline,
//     returns a Task HPointer (via `Scheduler::taskSucceed*` / `taskFail*`),
//     and the trampoline immediately delivers it via `callClosure1(resume,
//     task)`. Use this for filesystem/Console/Env/Time-here/etc. — anything
//     where the work completes synchronously at scheduler-step time.
//
//   * ASYNC-PARK (`AsyncBindingBody`): the body registers `resume` into the
//     scheduler's `pendingResumes_` registry, hands the work off to a worker
//     pool / TimerService / WaitService / HttpService, and returns the kill
//     handle (typically `unit()`). The Task is delivered LATER, when the
//     async source's drain calls `callClosure1(resume, …)`. Use this for
//     sleep / HTTP / wait / MVar-block — anything where the work cannot
//     complete on the scheduler thread.
//
// In both cases `captured` is whatever the kernel packed (an HPointer, a
// `tuple2`/`tuple3`/`record`, or `unit()` for no-capture).
using BindingBody      = HPointer (*)(HPointer captured);
using AsyncBindingBody = HPointer (*)(HPointer captured, HPointer resume);

namespace detail {

// Bit-for-bit conversion between `HPointer` and `uint64_t`. Used so the
// trampoline never depends on Eco-layer Export helpers (this header is in
// runtime/ and must compile against the elm-kernel-cpp layer too).
inline uint64_t encodeBits(HPointer h) {
    union { HPointer hp; uint64_t val; } u;
    u.hp = h;
    return u.val;
}

inline HPointer decodeBits(uint64_t v) {
    union { HPointer hp; uint64_t val; } u;
    u.val = v;
    return u.hp;
}

// Per-body trampoline. The closure header's `evaluator` field has type
// `void* (*)(void* args[])`, so we adapt the typed body through this
// template-instantiated thunk. Because `Body` is a non-type template
// parameter, each distinct body has its own unique trampoline address —
// suitable for closure identity / GC scanning.
//
// Capture slot 0 (PK_Boxed) holds the payload; the scheduler supplies the
// resume closure HPointer as slot 1 when stepping the binding. Both are
// re-rooted on entry because `Body` may allocate freely.
template <BindingBody Body>
inline void* bindingTrampoline(void* rawArgs[]) {
    uint64_t capturedEnc = reinterpret_cast<uint64_t>(rawArgs[0]);
    uint64_t resumeEnc   = reinterpret_cast<uint64_t>(rawArgs[1]);
    HPointer captured = decodeBits(capturedEnc);
    HPointer resume   = decodeBits(resumeEnc);

    HPointer task = alloc::unit();
    {
        // Root BEFORE running the body so any allocation inside `Body`
        // transparently relocates `captured` / `resume`. `task` is also
        // rooted so `callClosure1` sees the post-GC location.
        Elm::StackRootGuard guard(&captured, &resume, &task);
        task = Body(captured);
        Scheduler::callClosure1(resume, task);
    }

    // Kill handle: status-quo Unit placeholder. Cancellation of in-flight
    // kernel work is not modelled here (matches sleepBindingEvaluator).
    return reinterpret_cast<void*>(encodeBits(alloc::unit()));
}

// Async-park trampoline. The body is given direct access to `resume` and is
// expected to register it as a pending resume; the trampoline does NOT call
// `callClosure1`. The Task is delivered later via the worker drain.
template <AsyncBindingBody Body>
inline void* asyncBindingTrampoline(void* rawArgs[]) {
    uint64_t capturedEnc = reinterpret_cast<uint64_t>(rawArgs[0]);
    uint64_t resumeEnc   = reinterpret_cast<uint64_t>(rawArgs[1]);
    HPointer captured = decodeBits(capturedEnc);
    HPointer resume   = decodeBits(resumeEnc);

    HPointer killHandle = alloc::unit();
    {
        Elm::StackRootGuard guard(&captured, &resume, &killHandle);
        killHandle = Body(captured, resume);
    }
    return reinterpret_cast<void*>(encodeBits(killHandle));
}

} // namespace detail

// Wrap `Body` + `captured` as a Task_Binding HPointer. The kernel function
// returns this through its usual encoded path; the scheduler invokes `Body`
// later, at which point the IO happens.
template <BindingBody Body>
inline HPointer makeBinding(HPointer captured) {
    Elm::StackRootGuard capRoot(&captured);

    // arity=2: slot 0 = captured payload (PK_Boxed), slot 1 = resume closure
    // (PK_Boxed, supplied by the scheduler at step time). The closure's
    // `result_kind` is PK_Boxed because `bindingTrampoline` returns a boxed
    // HPointer (the kill handle).
    HPointer cb = alloc::allocClosureK(
        reinterpret_cast<EvalFunction>(&detail::bindingTrampoline<Body>),
        /*max_values=*/2, PK_Boxed);

    void* cbPtr = Allocator::instance().resolve(cb);
    if (cbPtr) {
        alloc::closureCapture(cbPtr, alloc::boxed(captured), /*is_boxed=*/true);
    }

    return Scheduler::instance().taskBinding(cb);
}

// Async-park variant. The body MUST register `resume` into
// `Scheduler::registerPendingResume(...)` (and call
// `incrementPendingAsync()`) before returning; otherwise the Task is dropped
// silently. The body's return value is treated as the kill handle (usually
// `unit()`; in future cancellable kernels it could be a token closure).
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
