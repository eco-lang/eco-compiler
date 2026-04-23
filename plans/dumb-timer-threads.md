# Plan: Dumb Timer Threads for `Process.sleep`

## Status: PLAN — questions resolved, ready for implementation

---

## Goal

Make the timer OS threads that back `Process.sleep` "dumb":

- They never touch `HPointer`, never allocate, never call `Allocator::instance()`, never run JIT/Elm code.
- They only manipulate primitive C++ state: `double` delays, `std::uint64_t` tokens, a `std::priority_queue`, a mutex, a condvar.
- All GC-managed state (pending resume closures, `Task_Succeed` allocation, `callClosure1`) stays on the main scheduler thread.

This restores the project-wide invariant that each thread only touches its own heap, and closes the class of bugs where cross-thread `callClosure1` / allocation on the timer path corrupted GC state.

The design mirrors the input spec the user pasted; this plan just localises it to the current tree.

---

## Current State (verified against the tree)

- `runtime/src/platform/Scheduler.hpp` already has:
  - `registerPendingResume` / `takePendingResume` (mutex-guarded `pendingResumes_` map).
  - `incrementPendingAsync` / `decrementPendingAsync`.
  - `eventCV_`, `mutex_`, `runEventLoop()` (Scheduler.cpp:458).
  - An external root scanner registered in the ctor that evacuates `runQueue_`, `latestProc_`, and `pendingResumes_` values.
- `elm-kernel-cpp/src/core/ProcessExports.cpp::sleepBindingEvaluator` today:
  - Registers the resume closure with `registerPendingResume` (good — stays).
  - Increments `pendingAsync_` (good — stays).
  - Spawns `std::thread` that calls `Allocator::instance().initThread()`, sleeps, `takePendingResume`, `taskSucceed(unit)`, `callClosure1`, `decrementPendingAsync`, `Allocator::instance().cleanupThread()`. **All of this moves off the timer thread.**
- `runtime/src/platform/Scheduler.cpp::runEventLoop` currently waits on `!runQueue_.empty() || pendingAsync_.load() == 0`.
- No `TimerService` exists yet. `runtime/src/platform/` currently contains only `Scheduler.{hpp,cpp}` and `PlatformRuntime.{hpp,cpp}`.
- `elm-kernel-cpp/src/time/TimeEffectManager.cpp::timerWorker` has the *same* cross-thread-GC bug (`allocInt`, `eco_apply_closure`, `sendToApp` all from the timer thread). Related but **out of scope** for this plan — see open question Q5.

---

## Plan

### Step 1 — Add `TimerService` (new module, no GC coupling)

**New files:**
- `runtime/src/platform/TimerService.hpp`
- `runtime/src/platform/TimerService.cpp`

**Singleton shape (per Q1 resolution): leaky, heap-allocated, never destroyed.** `instance()` returns a reference to a `TimerService*` that was `new`'d inside a `static` init and never deleted. This removes the static-destruction interaction with `Scheduler::instance()` entirely — the worker keeps running until `exit(3)` tears the process down. Matches the existing "detached timer thread, never joined" posture in `sleepBindingEvaluator`.

**Header surface (`TimerService.hpp`):**

```cpp
namespace Elm::Platform {
class TimerService {
public:
    static TimerService& instance();
    void schedule(double millis, std::uint64_t resumeToken);
    bool tryPopReadyToken(std::uint64_t& outToken);
    bool hasReadyTokens() const;
private:
    TimerService();
    ~TimerService();
    void workerLoop();

    using Clock     = std::chrono::steady_clock;
    using TimePoint = Clock::time_point;
    struct TimerEntry { TimePoint deadline; std::uint64_t token; };
    struct TimerCompare { bool operator()(const TimerEntry&, const TimerEntry&) const; };

    mutable std::mutex timersMutex_;
    std::condition_variable timersCV_;
    std::priority_queue<TimerEntry, std::vector<TimerEntry>, TimerCompare> timers_;
    mutable std::mutex readyMutex_;
    std::queue<std::uint64_t> readyTokens_;
    std::thread worker_;
};
} // namespace Elm::Platform
```

No `stop_` flag and no destructor — the singleton is leaked intentionally (Q1).

**Implementation notes:**
- `instance()` returns `*s_instance` where `s_instance` is a file-scope `TimerService*` initialised inside a function-local `static` (thread-safe init), never deleted.
- Ctor starts one detached worker thread: `std::thread([]{ instance().workerLoop(); }).detach()`.
- `schedule()`: push `(deadline, token)` into `timers_` min-heap, `timersCV_.notify_one()`. Uniform path for all delays including `millis == 0` (Q2 — no fast path).
- `workerLoop()`:
  - If `timers_` empty → `timersCV_.wait()`.
  - Else peek min; if `now >= deadline`, pop, push token into `readyTokens_`, call `Scheduler::instance().notifyWorkAvailableFromAsync()`, loop.
  - Else `timersCV_.wait_until(lk, deadline)`.
  - No shutdown path — the thread runs until the process exits.
- `tryPopReadyToken()`, `hasReadyTokens()`: short critical sections on `readyMutex_` only.
- **No** include of `allocator/*.hpp`, **no** `HPointer`, **no** `Allocator::instance()`.
- Includes only `<chrono>`, `<mutex>`, `<condition_variable>`, `<queue>`, `<vector>`, `<thread>`, `<cstdint>`, and (in `.cpp`) `platform/Scheduler.hpp` for the wakeup call.

**Build wiring (Q8 — resolved against the actual tree):** `Scheduler.cpp` and `PlatformRuntime.cpp` are listed in `runtime/src/codegen/CMakeLists.txt` at three separate source lists (lines 316–317, 400–401, 480–481 — three build targets share these platform sources). Add `../platform/TimerService.cpp` next to them at all three sites. No new library target. (The "codegen" directory name is misleading — it's where the runtime library targets are composed, and platform sources happen to be pulled in from there.)

---

### Step 2 — Add `Scheduler::notifyWorkAvailableFromAsync()`

**File:** `runtime/src/platform/Scheduler.hpp`

Add alongside `decrementPendingAsync()`:

```cpp
// Called by helper threads (e.g. TimerService worker) to wake the main
// event loop when new async work is ready. Must not allocate or touch GC.
void notifyWorkAvailableFromAsync();
```

Also add `#include "platform/TimerService.hpp"` at the top (needed by `runEventLoop` predicate — see Step 3).

**File:** `runtime/src/platform/Scheduler.cpp`

```cpp
void Scheduler::notifyWorkAvailableFromAsync() {
    std::lock_guard<std::mutex> lk(mutex_);
    eventCV_.notify_one();
}
```

Taking `mutex_` is conservative but cheap; it mirrors the existing `enqueue`/`decrementPendingAsync` pattern and avoids any missed-wakeup window.

---

### Step 3 — `processReadyAsync()` on the main thread

**File:** `runtime/src/platform/Scheduler.hpp` (private section):

```cpp
// Pull ready tokens from TimerService, resolve their resume closures,
// allocate Task_Succeed(unit), invoke callClosure1, decrement pendingAsync_.
// Runs only on the main scheduler thread.
void processReadyAsync();
```

**File:** `runtime/src/platform/Scheduler.cpp`

```cpp
void Scheduler::processReadyAsync() {
    std::uint64_t token;
    while (TimerService::instance().tryPopReadyToken(token)) {
        HPointer resumeClosure = takePendingResume(token);
        if (alloc::isNil(resumeClosure)) {
            decrementPendingAsync();
            continue;
        }
        HPointer succeedTask = listNil();
        {
            StackRootGuard guard(&resumeClosure, &succeedTask);
            succeedTask = taskSucceed(unit());
            callClosure1(resumeClosure, succeedTask);
        }
        decrementPendingAsync();
    }
}
```

Rationale:
- `resumeClosure` survives GC while queued in `pendingResumes_` (external root scanner already covers that map). Once `takePendingResume` removes it from the map, we root it on the C++ stack via `StackRootGuard` for the duration of `taskSucceed` + `callClosure1`.
- `succeedTask` is rooted across `callClosure1` (which may trigger GC inside the callee).
- Decrement `pendingAsync_` once per token regardless of whether the closure was cancelled/absent, so the `registerPendingResume` + `incrementPendingAsync` pair in `sleepBindingEvaluator` stays balanced.

---

### Step 4 — Update `runEventLoop`

**File:** `runtime/src/platform/Scheduler.cpp:458-472`

Replace the existing loop with:

```cpp
void Scheduler::runEventLoop() {
    while (true) {
        drain();
        processReadyAsync();          // may enqueue procs; loop will drain them
        if (!runQueue_.empty()) continue;  // re-drain after async-produced work
        std::unique_lock<std::mutex> lock(mutex_);
        if (runQueue_.empty() && pendingAsync_.load() == 0) break;
        eventCV_.wait(lock, [this] {
            return !runQueue_.empty()
                || pendingAsync_.load() == 0
                || TimerService::instance().hasReadyTokens();
        });
    }
}
```

Key properties:
- `processReadyAsync()` runs every iteration; a timer that fired between `drain()` and the wait predicate is handled before we sleep.
- The predicate also consults `TimerService::hasReadyTokens()`, so even if the worker's `notifyWorkAvailableFromAsync` raced with the predicate evaluation, we still don't go to sleep with a ready token sitting in the queue. (This is the specific failure mode flagged in the input spec's "missed wakeup" warning.)
- After `processReadyAsync()` enqueues work, we `continue` so `drain()` runs on the new processes before we consider sleeping. Without this, a single timer firing with no other pending work would get handed off for resume, enqueue a process, and then the predicate would see `runQueue_` non-empty — harmless but we'd take an extra lap.

---

### Step 5 — Rewrite `sleepBindingEvaluator`

**File:** `elm-kernel-cpp/src/core/ProcessExports.cpp:22-80`

New body:

```cpp
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

    return reinterpret_cast<void*>(encode(Elm::alloc::unit()));
}
```

Removals:
- No `std::thread`, no `detach()`.
- No `Allocator::instance().initThread()` / `cleanupThread()`.
- No `takePendingResume` / `taskSucceed` / `callClosure1` here — those move to `processReadyAsync()`.
- No `cancelled` shared atomic — current kill path already returns plain `unit` (see line 77–79 comment "TODO: Create a proper kill closure"), so we carry no new regression. Cancellation stays status quo (Q3); a main-side-only cancel via `pendingResumes_` removal is deferred to a follow-up.

Includes to add to the file:
- `"platform/TimerService.hpp"`

---

### Step 6 — Smoke test and failure-mode check

Manual/automated verification before declaring done:

1. Build `cmake --build build` cleanly.
2. Run the existing `ProcessSleepTest` / `TimerEffectTest` E2E targets (see `test/elm/src/TimerEffectTest.elm` — already written per the sibling plan `timer-effect-test-runtime-support.md`). Expected: same pass/fail shape as before, but all `Debug.log` output captured on main (matches the capture story Step 4 of the sibling plan relied on).
3. Stress test: `TEST_FILTER=stress cmake --build build --target full` — the `project_stress_test_baseline.md` and `project_process_immutable_fix.md` memories note current counts. Ensure no regression.
4. Grep for `Allocator::instance().initThread` or `std::thread(` in `elm-kernel-cpp/src/core/ProcessExports.cpp` — should be zero after this change.

---

## File Change Summary

| File | Kind | Change |
|---|---|---|
| `runtime/src/platform/TimerService.hpp` | NEW | TimerService singleton interface |
| `runtime/src/platform/TimerService.cpp` | NEW | Worker thread + token queues; no GC calls |
| `runtime/src/platform/Scheduler.hpp` | MODIFY | `#include "platform/TimerService.hpp"`; add `notifyWorkAvailableFromAsync()`; add private `processReadyAsync()` |
| `runtime/src/platform/Scheduler.cpp` | MODIFY | Implement the two new methods; update `runEventLoop` predicate + integration |
| `elm-kernel-cpp/src/core/ProcessExports.cpp` | MODIFY | Drop the `std::thread` block in `sleepBindingEvaluator`; call `TimerService::schedule` instead |
| `runtime/src/codegen/CMakeLists.txt` | MODIFY | Add `../platform/TimerService.cpp` at the three source lists that already list `../platform/Scheduler.cpp` (lines 316, 400, 480) |

No test file changes required (existing `TimerEffectTest` / `ProcessSleepTest` stay the same).

---

## Resolved Decisions

### Q1 — Shutdown race: **accept, via leaky singleton**
`TimerService` is a never-destroyed heap singleton with a detached worker. No `~TimerService()`, no `stop_` flag, no coordinated shutdown. This matches the posture of the current `sleepBindingEvaluator` (detached thread, never joined) and removes the static-destruction interaction with `Scheduler::instance()` entirely.

### Q2 — `schedule(millis=0)`: **uniform path, no fast path**
Everything, including 0-delay, goes through the worker's priority queue. A special-cased 0 path (previously attempted and rolled back alongside other refactors) can be revisited as a micro-optimization after correctness stabilizes.

### Q3 — Cancellation: **status quo in this patch**
Leave the kill path as "return Unit" as today. Main-side-only cancellation via `takePendingResume` returning nil is deferred to a focused follow-up; no change to `TimerService`.

### Q4 — Base: **current `Scheduler.cpp::runEventLoop`**
`timer-effect-test-runtime-support.md` Step 3c is landed. No in-flight refactor to rebase on.

### Q5 — `TimeEffectManager` migration: **separate follow-up**
Out of scope for this patch. Will land as `dumb-timer-threads-time-every.md` once this change is stable; likely motivates a repeating-timer API on `TimerService` or a self-reschedule pattern on main.

### Q6 — `resumeMutex_`: **keep**
`registerPendingResume` / `takePendingResume` are documented as "safe to call from any thread" and used by other async sources (HTTP, future kernels). Removing the mutex is premature until all async completion is consolidated onto main.

### Q7 — Re-entry: **documented, safe, no code change**
`processReadyAsync` → `callClosure1` → Elm → `Process.sleep` → `TimerService::schedule` is unbounded but not recursive: new tokens land in `timers_` and fire on a later worker iteration, re-waking main via `notifyWorkAvailableFromAsync`. No synchronous recursion into TimerService, no unbounded stack.

### Q8 — Build wiring: **add to `runtime/src/codegen/CMakeLists.txt`** alongside `Scheduler.cpp`
Verified against the tree: `Scheduler.cpp` is listed at lines 316, 400, 480 in that file across three build targets. `TimerService.cpp` goes next to it at all three sites. No new library target.

---

## Why this satisfies the invariant

- Timer worker thread: only `(deadline, token, mutex, cv, priority_queue<POD>)`. Zero `HPointer`, zero GC entry points.
- Main scheduler thread: still the sole owner of `runQueue_`, `pendingResumes_` (effectively), `callClosure1`, `Allocator::instance()`.
- Cross-thread interface: two short critical sections on `readyMutex_`/`timersMutex_` exchanging only `std::uint64_t` and `double`, plus a condvar notify that does not touch GC state.
- GC correctness: resume closures live in `pendingResumes_` (external rooted) between `registerPendingResume` and `takePendingResume`; `StackRootGuard` covers the window where `processReadyAsync` holds them on the C++ stack across `taskSucceed` + `callClosure1`. That is already the rooting pattern used in `Scheduler::popStackMatching` (Scheduler.cpp:329).
