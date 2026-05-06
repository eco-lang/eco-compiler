# Plan: `Time.every` via Scheduler + TimerService (no cross-thread HPointers)

## Status: PLAN — questions resolved, ready for implementation

---

## Goal

Eliminate **all cross-thread `HPointer` use** from `elm-kernel-cpp/src/time/TimeEffectManager.cpp`. The current `timerWorker` calls `Allocator::initThread()` to spawn its own heap, then `allocInt`, `eco_apply_closure`, and `PlatformRuntime::sendToApp` from the timer thread on closures owned by the main thread. This is the same class of bug that motivated the `Process.sleep` rewrite (see `plans/dumb-timer-threads.md`).

End state:

- The **only** thread that ever touches `HPointer`s or calls Elm closures is the main scheduler thread.
- The timer worker (already in `runtime/src/platform/TimerService.cpp`) only ever sees `(deadline, uint64_t token)` pairs.
- `Time.every` is implemented as a chain of one-shot timers that re-arm via `Scheduler::pendingResumes_` + `TimerService::schedule`, mirroring `Process.sleep`'s shape.
- `Time.every` taggers receive a properly-shaped `Posix` `Custom` value (ctor 0, one unboxed Int field), not a `Tag_Int` heap object. (Folded in per Q1 — landing the scheduling refactor without this would leave the same heap-layout-punning regression we just fixed in `Time.now`.)

---

## Current state (verified against the tree)

- `runtime/src/platform/Scheduler.{hpp,cpp}` already exposes:
  - `registerPendingResume(HPointer) → u64` and `takePendingResume(u64) → HPointer` (`Scheduler.cpp:81-95`).
  - `incrementPendingAsync() / decrementPendingAsync()`, `notifyWorkAvailableFromAsync()`.
  - `processReadyAsync()` (`Scheduler.cpp:526`) — drains `TimerService` ready tokens, takes the resume from `pendingResumes_`, calls `callClosure1(resume, taskSucceed(unit()))`. **The resume closure is invoked with one Elm-applied arg (the Task).**
  - An external root scanner (registered in the ctor) that evacuates encoded HPointers in `pendingResumes_`.
- `runtime/src/platform/TimerService.{hpp,cpp}` exists and is POD-only: `schedule(double, u64) → void`, `tryPopReadyToken(u64&) → bool`. The worker thread holds zero HPointers.
- `elm-kernel-cpp/src/core/ProcessExports.cpp:24-44` (`sleepBindingEvaluator`) is the canonical reference for the pattern: `registerPendingResume → incrementPendingAsync → TimerService::schedule`.
- `elm-kernel-cpp/src/time/TimeEffectManager.cpp` today:
  - Spawns one `std::thread` per active interval via `timerWorker`.
  - Calls `Allocator::initThread()`, `allocInt(ms)`, `eco_apply_closure`, `sendToApp` from that worker thread — the cross-thread bug.
  - Has an external root scanner already (`timerRegisterScannerOnce`) but it walks `g_activeTimers`, which is the very state we're replacing.
- `compiler/src/Compiler/Data/CtorTag.elm` — confirms `Posix` (only ctor in `type Posix = Posix Int`) has runtime ctor tag `0`.

---

## Plan

### Step 1 — Includes and dead-code removal (`TimeEffectManager.cpp`)

- **Remove** `#include <thread>` and `#include <atomic>` (the file no longer spawns threads or uses atomics for timer state; `g_nextGeneration` is a single `std::atomic<uint64_t>` counter — Step 2 — but `<atomic>` is still pulled in transitively via `platform/Scheduler.hpp`; keep this include only if the build complains, otherwise drop).
- **Add** `#include "platform/TimerService.hpp"`.
- **Delete** the `TimerState` struct, `g_activeTimers`, `g_timerThreads`, `timerWorker`, `stopTimers`, `startTimer`. Keep the file-local `encodeHP` / `decodeHP` helpers and `g_timerMutex`.

### Step 2 — New main-thread interval state

After `encodeHP` / `decodeHP`, add:

```cpp
// Per-interval state. Lives only on the main scheduler thread.
//
// Invariant: ALL accesses to g_intervals (mutation, lookup, scanning) take
// g_timerMutex. We must NOT hold g_timerMutex across any Allocator call —
// the GC scanner re-enters this mutex during evacuation, and any allocation
// can trigger GC. Copy primitives out, drop the lock, then allocate.
struct IntervalState {
    double   intervalMs;
    uint64_t generation;  // bumped on (re)subscription; stale ticks self-cancel
    uint64_t taggerEnc;   // encoded HPointer to (Posix -> msg) closure
    uint64_t routerEnc;   // encoded HPointer to Router
};

static std::mutex g_timerMutex;
static std::unordered_map<double, IntervalState> g_intervals;
static std::atomic<uint64_t> g_nextGeneration{1};
```

### Step 3 — Repoint the external root scanner at `g_intervals`

Adapt `timerRegisterScannerOnce` so its lambda walks `g_intervals` under `g_timerMutex` and calls `evac(state.taggerEnc) / evac(state.routerEnc)` for each entry. Same shape as `Scheduler::pendingResumes_`'s scanner (`Scheduler.cpp:62`). The scanner already runs on the main thread during GC; no new locking concerns.

Add a comment above the scanner:

```cpp
// Invariant: no Allocator calls while holding g_timerMutex. The scanner
// runs during GC, which is triggered by allocations. If a thread held the
// mutex across an allocation, GC's scanner would deadlock on the same
// (non-recursive) mutex on the same thread.
```

### Step 4 — `scheduleTimerTick` helper

Forward-declare the tick evaluator:

```cpp
static void* timerTickEvaluator(void* args[]);
```

Add the helper that builds the tick closure and registers it with `Scheduler` + `TimerService`:

```cpp
// Schedule a single Time.every tick for (intervalMs, generation).
// Mirrors sleepBindingEvaluator's order: registerPendingResume →
// incrementPendingAsync → TimerService::schedule.
static void scheduleTimerTick(double intervalMs, uint64_t generation) {
    // Box metadata as Elm values so they're GC-visible and can travel
    // through the closure's captures.
    HPointer intervalHP = allocFloat(intervalMs);
    HPointer genHP      = allocInt(static_cast<i64>(generation));

    HPointer tickCl = listNil();
    {
        StackRootGuard guard({ &intervalHP, &genHP, &tickCl });
        tickCl = allocClosure(timerTickEvaluator, /*max_values=*/3);
        if (void* clPtr = Allocator::instance().resolve(tickCl)) {
            closureCapture(clPtr, boxed(intervalHP), /*is_boxed=*/true);
            closureCapture(clPtr, boxed(genHP),      /*is_boxed=*/true);
        }
    }

    auto& sched = Scheduler::instance();
    uint64_t token = sched.registerPendingResume(tickCl);
    sched.incrementPendingAsync();
    TimerService::instance().schedule(intervalMs, token);
}
```

The 2 captures + 1 applied arg (the `Task` from `processReadyAsync`) saturate the closure at `max_values=3`, so the evaluator fires when the scheduler applies the third arg.

### Step 5 — `timerTickEvaluator`

```cpp
// rawArgs[0] = intervalHP   (boxed ElmFloat capture)
// rawArgs[1] = genHP        (boxed ElmInt capture)
// rawArgs[2] = Task succeed unit  (applied by Scheduler::processReadyAsync)
static void* timerTickEvaluator(void* args[]) {
    HPointer intervalHP = decodeHP(reinterpret_cast<uint64_t>(args[0]));
    HPointer genHP      = decodeHP(reinterpret_cast<uint64_t>(args[1]));
    (void)args[2];

    auto& allocator = Allocator::instance();
    void* intervalPtr = allocator.resolve(intervalHP);
    void* genPtr      = allocator.resolve(genHP);
    if (!intervalPtr || !genPtr) {
        return reinterpret_cast<void*>(
            encodeHP(Scheduler::instance().taskSucceed(alloc::unit())));
    }
    double  intervalMs = static_cast<ElmFloat*>(intervalPtr)->value;
    uint64_t generation = static_cast<uint64_t>(
                              static_cast<ElmInt*>(genPtr)->value);

    // Snapshot encodings under the mutex; drop it before any allocation.
    uint64_t taggerEnc = 0, routerEnc = 0;
    bool active = false;
    {
        std::lock_guard<std::mutex> lock(g_timerMutex);
        auto it = g_intervals.find(intervalMs);
        if (it != g_intervals.end() && it->second.generation == generation) {
            taggerEnc = it->second.taggerEnc;
            routerEnc = it->second.routerEnc;
            active = true;
        }
    }

    HPointer succeedTask = Scheduler::instance().taskSucceed(alloc::unit());
    if (!active) {
        // Interval was unsubscribed (or re-created with a new generation).
        // Decrement happens in processReadyAsync; we just return.
        return reinterpret_cast<void*>(encodeHP(succeedTask));
    }

    // Per Q2: decode immediately, root before any allocation, and re-encode
    // from the rooted HPointers at every use site. Do NOT reuse taggerEnc /
    // routerEnc after allocations.
    HPointer taggerHP = decodeHP(taggerEnc);
    HPointer routerHP = decodeHP(routerEnc);
    HPointer posixHP  = listNil();
    HPointer msgHP    = listNil();

    {
        StackRootGuard guard(
            { &taggerHP, &routerHP, &posixHP, &msgHP, &succeedTask });

        // Q1: build the Posix Custom directly; do NOT pass a raw ElmInt to
        // the tagger (would alias offset-16 reads in posixToMillis to past
        // the end of the ElmInt). Posix is `type Posix = Posix Int`, ctor
        // index 0, one unboxed Int field.
        std::vector<Unboxable> vals(1);
        vals[0].i = static_cast<i64>(
            std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::system_clock::now().time_since_epoch()).count());
        posixHP = custom(/*ctor=*/0, vals, /*kind_bitmap=*/0b01);

        uint64_t posixArg = encodeHP(posixHP);
        uint64_t msgEnc = eco_apply_closure(
            HPtr::fromBits(encodeHP(taggerHP)), &posixArg, 1).toBits();
        msgHP = decodeHP(msgEnc);

        PlatformRuntime::instance().sendToApp(routerHP, msgHP);
    }

    // Chain the next tick. scheduleTimerTick allocates; we're outside the
    // guard now, but allocations from here on don't need taggerHP/routerHP
    // alive any more.
    scheduleTimerTick(intervalMs, generation);

    return reinterpret_cast<void*>(encodeHP(succeedTask));
}
```

Notes:

- The `succeedTask` rooted via `StackRootGuard` is the value returned to `processReadyAsync` — `processReadyAsync` ignores the closure's return value, but we still construct one for symmetry with the rest of the file. (Confirmed by reading `Scheduler.cpp:526-543`: the loop pops the token, calls `callClosure1`, and discards the return.)
- `eco_apply_closure` is declared in `runtime/src/allocator/RuntimeExports.h`. The current file already pulls it in via `RuntimeExports.h` (added in the `Time.now` fix).
- `custom(...)` does its own internal rooting of incoming values via `eco_alloc_with_roots`, so we don't need to pre-root the `Unboxable` vector.
- The `(double)0.0` / `(double)-0.0` map-key footgun is normalized in Step 6 at insertion time and again here when we read `intervalMs` from the boxed `ElmFloat`. Q6.

### Step 6 — Rewrite the update half of `timeOnEffectsEvaluator`

Keep the router-decoding header and the `requestedIntervals` build loop. Replace the `toStop` / `startTimer` block with:

```cpp
// Q6: fold -0.0 to +0.0 so the double map key is stable.
auto normalize = [](double d) -> double {
    return d == 0.0 ? 0.0 : d;
};

// Build a normalized map of requested intervals.
std::unordered_map<double, uint64_t> normalizedRequested;
for (auto& [interval, taggerEnc] : requestedIntervals) {
    double k = normalize(interval);
    if (std::isnan(k)) continue;  // NaN intervals are nonsensical; skip.
    normalizedRequested[k] = taggerEnc;
}

timerRegisterScannerOnce();

struct PendingStart {
    double   intervalMs;
    uint64_t generation;
};
std::vector<PendingStart> toStart;

{
    std::lock_guard<std::mutex> lock(g_timerMutex);

    // Erase intervals that are no longer requested.
    for (auto it = g_intervals.begin(); it != g_intervals.end(); ) {
        if (normalizedRequested.find(it->first) == normalizedRequested.end()) {
            it = g_intervals.erase(it);
        } else {
            ++it;
        }
    }

    // Insert new / update existing.
    for (auto& [intervalMs, taggerEnc] : normalizedRequested) {
        auto it = g_intervals.find(intervalMs);
        if (it == g_intervals.end()) {
            uint64_t gen = g_nextGeneration.fetch_add(1);
            g_intervals.emplace(intervalMs, IntervalState{
                intervalMs, gen, taggerEnc, routerEnc
            });
            toStart.push_back({ intervalMs, gen });
        } else {
            // Per Q7: in-place mutation is safe under the Q2 rooting
            // discipline. Old encodings lose their root the moment we
            // overwrite; any in-flight tick that already snapshotted the
            // old taggerEnc/routerEnc has rooted the decoded HPointers on
            // its stack, so the old closures stay alive until that tick
            // returns.
            it->second.taggerEnc = taggerEnc;
            it->second.routerEnc = routerEnc;
        }
    }
}

// Allocations only AFTER releasing g_timerMutex (see Step 3 invariant).
for (const auto& ps : toStart) {
    scheduleTimerTick(ps.intervalMs, ps.generation);
}
```

The `taskSucceed(Nil)` return at the end of `timeOnEffectsEvaluator` stays as-is.

### Step 7 — Leave `init` / `onSelfMsg` / `subMap` alone

These already run on the main thread and don't touch off-thread state. `composedTaggerEvaluator` only re-applies whatever value the timer hands it — once that value is a properly-shaped `Posix` (Step 5), the composed-tagger path works without changes.

Optional: refresh the file-level comment header (currently says "maintaining timer threads") to describe the new design.

### Step 8 — Add E2E test for `Time.every`

Per Q8, land alongside the kernel changes. Modelled on `test/elm/src/TimerEffectTest.elm` (the existing `Process.sleep` smoke test), but driven by a `Time.every` subscription so it actually exercises the new path.

#### 8a. Test source — `test/elm-time/src/TimeEveryTest.elm`

The E2E harness in `test/ElmE2ETestBase.hpp:295-328` reads `-- CHECK: ...` lines from the source and **substring-matches** each pattern against stdout (`output.find(pattern) == std::string::npos` ⇒ fail). This means the CHECK patterns must be deterministic — Posix timestamps differ each run, so we can't put a literal ms count in a CHECK line. Instead, the test program performs the timing checks internally and emits a fixed line per successful tick:

```elm
module TimeEveryTest exposing (main)

{-| Test that Time.every delivers the expected number of ticks and that
each Posix value is strictly greater than the previous one. Mirrors
TimerEffectTest.elm's shape (Platform.worker, log per tick, stop after N)
but uses the Time.every subscription so it exercises the new
scheduling/rooting path.
-}

-- CHECK: TimeEveryTest: tick 1
-- CHECK: TimeEveryTest: tick 2
-- CHECK: TimeEveryTest: tick 3
-- CHECK: TimeEveryTest: tick 4
-- CHECK: TimeEveryTest: tick 5
-- CHECK: TimeEveryTest: done

import Platform
import Time


type Msg
    = Tick Time.Posix


type alias Model =
    { count : Int
    , lastMs : Int       -- 0 sentinel; first tick must produce a positive ms
    , done : Bool
    }


target : Int
target =
    5


intervalMs : Float
intervalMs =
    50


init : () -> ( Model, Cmd Msg )
init _ =
    ( { count = 0, lastMs = 0, done = False }
    , Cmd.none
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Tick posix ->
            let
                ms = Time.posixToMillis posix
                -- Q1 regression guard: a Posix Custom decodes to a current-
                -- epoch ms (>1e12 in 2026). A Tag_Int read at the Custom
                -- offsets returns 0 or near-0 garbage. Strict monotonic
                -- increase plus the >0 floor catches both forms of the bug.
                strictlyIncreasing = ms > model.lastMs
                positive = ms > 0
                newCount = model.count + 1
            in
            if not (strictlyIncreasing && positive) then
                -- Note the absent CHECK line: harness will report the
                -- missing "tick N" pattern as a failure. We also log so
                -- the failure mode is obvious in stderr.
                let _ = Debug.log "TimeEveryTest" "non-monotonic or non-positive"
                in
                ( model, Cmd.none )

            else
                let
                    _ = Debug.log "TimeEveryTest" ("tick " ++ String.fromInt newCount)
                    nextModel = { count = newCount, lastMs = ms, done = newCount >= target }
                in
                if nextModel.done then
                    let _ = Debug.log "TimeEveryTest" "done"
                    in ( nextModel, Cmd.none )

                else
                    ( nextModel, Cmd.none )


subscriptions : Model -> Sub Msg
subscriptions model =
    if model.done then
        Sub.none
    else
        Time.every intervalMs Tick


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = subscriptions
        }
```

What this exercises end-to-end:

- **Scheduling path.** Subscribing forces `timeOnEffectsEvaluator` to insert a new entry into `g_intervals` and call `scheduleTimerTick`. Each tick fires through `TimerService → processReadyAsync → timerTickEvaluator → scheduleTimerTick` (the chain), so a successful run proves the chain reschedules itself.
- **Q1 — Posix shape.** `Time.posixToMillis (Posix m) = m` reads field 0 at the `Custom` offset. If the timer kernel hands a raw `Tag_Int` (today's bug), the read either lands past the end of the `ElmInt` (garbage, often 0) or into the next heap object's header. `positive` (`ms > 0`) and `strictlyIncreasing` (`ms > model.lastMs`) both fail in that case, so the `tick N` lines never get logged and the harness reports the missing CHECK pattern.
- **Q4 — first tick at `t = intervalMs`.** Implicit: the test passes regardless of whether the first tick is at `0` or `intervalMs`, but combined with the wall-clock budget at the `--target check` level we'd notice a runaway-immediate-fire bug as a flooded log.
- **Subscription teardown.** Once `model.done = True`, `subscriptions = Sub.none`. `timeOnEffectsEvaluator` runs again and erases the interval entry. Any in-flight tick already in `pendingResumes_` self-cancels via the generation check (Q7). The program then has no pending async work and exits cleanly.

#### 8b. Wire the test into the harness

The existing `test/elm-time/` machinery picks up `*.elm` under `src/` automatically (see `TimePosixTest.elm` / `TimePartsTest.elm` — no per-test C++ wiring beyond `ElmTimeTest.hpp`). Confirm this during implementation by:

1. Dropping `TimeEveryTest.elm` into `test/elm-time/src/`.
2. Running `cmake --build build --target check` and looking for it in the parameterised suite output.

If the harness needs explicit registration, the failure mode will be a missing test-name line — at that point, follow whatever pattern `TimePartsTest.elm` uses (registration site likely in `test/CMakeLists.txt` or an `*.eco-stuff/1.0.0/` rebuild). Resolve before finalising the patch.

#### 8c. Why we don't reuse `test/elm/src/TimerEffectTest.elm`

`TimerEffectTest` validates `Process.sleep` — keeping a separate test for `Time.every` ensures both kernel paths have independent regression coverage. The new file lives under `test/elm-time/` because that's where Time-module tests are organised (`TimePosixTest`, `TimePartsTest`).

### Step 9 — Build and verify

```bash
cmake --build build --target eco-boot-native           # rebuilds runtime + relinks eco-compiler
cmake --build build --target check 2>&1 | tee /tmp/test_output.txt   # full E2E
cmake --build build --target stress 2>&1 | tee /tmp/stress_output.txt
TEST_FILTER=time cmake --build build --target check    # focused timer + Posix tests
```

Plus a manual smoke run of `compiler/examples/src/CurrentTime.elm` to confirm the displayed clock advances second-by-second.

---

## Out of scope

- `Process.sleep` already uses this design (`plans/dumb-timer-threads.md`); no changes there.
- Hard cancellation of in-flight timers on subscription removal. Q5: the existing `Process.sleep` has the same tail-latency-bounded-by-longest-interval shutdown property; we accept that here too. A `TimerService::cancel(token)` API is a separate, low-priority follow-up.
- `Time.now` is already fixed (it captures `millisToPosix` and applies it in the binding evaluator). `Time.every` cannot use the same trick because its `Sub` doesn't carry the `Posix` constructor; we go with direct `custom(0, ...)` construction (Q1 fix (a)).
- `Elm_Kernel_Time_here` and `Elm_Kernel_Time_getZoneName` already construct their `Custom` values by hand with the right ctor indices; no change needed there.

---

## Resolved questions (recorded for future readers)

- **Q1 — Posix wrapping.** Folded into this plan. `timerTickEvaluator` builds the `Posix` `Custom` directly via `custom(0, {{.i = ms}}, 0b01)`. Hardcodes the ctor index alongside the existing precedent for `ZoneName.Name` (ctor 0) / `ZoneName.Offset` (ctor 1) in the same file. The CtorTag invariant lives in `compiler/src/Compiler/Data/CtorTag.elm`.
- **Q2 — Stale encodings.** Snapshot under the mutex, decode immediately, root via `StackRootGuard`, re-encode from rooted `HPointer` at every use site. Never reuse the snapshotted encoding after an allocation.
- **Q3 — `g_timerMutex`.** Keep it. Invariant: no `Allocator` calls while holding it. Comment on the scanner and the `onEffects` mutation block.
- **Q4 — Initial-tick semantics.** First tick at `t = intervalMs` (sleep first). Matches existing `timerWorker` and the JS kernel.
- **Q5 — Shutdown.** Tail latency bounded by longest active interval. Acceptable; matches `Process.sleep`. Cancellation is a future change.
- **Q6 — `double` map keys.** Fold `-0.0 → +0.0`; skip `NaN` intervals. One-line comment in `onEffects`.
- **Q7 — In-place `IntervalState` mutation.** Safe under the Q2 rooting discipline; old encodings lose their root on overwrite, but any in-flight tick that already snapshotted the old encoding has already rooted the decoded HPointer on its stack.
- **Q8 — Test coverage.** Land an E2E `Time.every` test in the same patch.
