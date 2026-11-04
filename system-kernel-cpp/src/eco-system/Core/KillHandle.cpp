//===- KillHandle.cpp - Kill handle for cancellable async bindings --------===//
//
// A killed task must never resume, and the hold registered under the token must be released exactly once. The
// handle and the job's drain split that release between them by the result of `cancel(token)`:
//
//   * true: the job was removed before it produced a result, so no drain will see the token; the handle
//     releases the hold.
//   * false: the result is, or will be, queued; the drain finds `takePendingResume(token)` returning nil,
//     releases the hold, and skips the resume.
//
// The handle always takes the pending resume first, which is what makes the drain's lookup come back nil.
//
// The token and the cancel function pointer are captured as unboxed Ints, so they reach the evaluator as
// raw bits in `args[0]` and `args[1]`.
//
//===----------------------------------------------------------------------===//

#include "eco-system/Core/Core.hpp"

namespace Eco::System {

namespace {

// Evaluates the kill handle: `args[0]` is the token, `args[1]` the `CancelFn` bits and `args[2]` the `()` the
// handle is applied to. Implements the split described in the file comment.
void* killEval(void* args[]) {
    uint64_t token = reinterpret_cast<uint64_t>(args[0]);
    auto cancel = reinterpret_cast<CancelFn>(reinterpret_cast<uintptr_t>(args[1]));
    auto& s = Scheduler::instance();
    (void)s.takePendingResume(token);
    if (cancel && cancel(token)) s.releaseHold(token);
    return reinterpret_cast<void*>(enc(alloc::unit()));
}

} // namespace

HPointer makeKillHandle(uint64_t token, CancelFn cancel) {
    HPointer cl = alloc::allocClosureK(&killEval, /*max_values=*/3, PK_Boxed);
    // `p` stays valid only while nothing allocates; closureCapture does not.
    void* p = Allocator::instance().resolve(cl);
    alloc::closureCapture(p, alloc::unboxedInt(static_cast<int64_t>(token)), PK_Int);
    alloc::closureCapture(
        p,
        alloc::unboxedInt(static_cast<int64_t>(reinterpret_cast<uintptr_t>(cancel))),
        PK_Int);
    return cl;
}

} // namespace Eco::System
