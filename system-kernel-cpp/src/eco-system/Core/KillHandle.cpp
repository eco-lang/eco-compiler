//===- KillHandle.cpp - T7 kill handle for cancellable async bindings -----===//
//
// `Process.kill` calls a Task_Binding's kill handle with `()`
// (Scheduler.cpp killBindingBody). The handle built here captures the
// binding's resume token and a CancelFn, and implements the T7 rule
// (plans/eco-system-library.md §3.3.2):
//
//   * the killed task must never resume: the pending resume is discarded;
//   * EXACTLY ONE side decrements pendingAsync. `cancel(token)` returns true
//     only if it removed a job that had not yet produced a result; then the
//     job will never reach a drain, so the handle decrements. Otherwise the
//     result is (or will be) queued, and the drain finds
//     takePendingResume(token) nil, decrements, and skips the resume (G10).
//
// Typed captures arrive as raw bits (MVar.cpp readBindingEvaluator), so the
// token and the cancel function pointer are read straight from args[0..1].
//
// Templates used: T7.
//
//===----------------------------------------------------------------------===//

#include "eco-system/Core/Core.hpp"

namespace Eco::System {

namespace {

// args[0] = token (PK_Int), args[1] = cancel fn bits (PK_Int), args[2] = ().
void* killEval(void* args[]) {
    uint64_t token = reinterpret_cast<uint64_t>(args[0]);
    auto cancel = reinterpret_cast<CancelFn>(reinterpret_cast<uintptr_t>(args[1]));
    auto& s = Scheduler::instance();
    (void)s.takePendingResume(token);       // discard: the killed task never resumes
    if (cancel && cancel(token)) s.decrementPendingAsync();   // we removed the job
    return reinterpret_cast<void*>(enc(alloc::unit()));
}

} // namespace

HPointer makeKillHandle(uint64_t token, CancelFn cancel) {
    HPointer cl = alloc::allocClosureK(&killEval, /*max_values=*/3, PK_Boxed);
    // No allocation until both captures are written (G8).
    void* p = Allocator::instance().resolve(cl);
    alloc::closureCapture(p, alloc::unboxedInt(static_cast<int64_t>(token)), PK_Int);
    alloc::closureCapture(
        p,
        alloc::unboxedInt(static_cast<int64_t>(reinterpret_cast<uintptr_t>(cancel))),
        PK_Int);
    return cl;
}

} // namespace Eco::System
