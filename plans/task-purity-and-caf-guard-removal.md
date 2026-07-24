# Task Purity: Defer the Last Eager Tasks, Stop Mutating Task Nodes, Drop the CAF Effect Guard

## Status: IMPLEMENTING (2026-07-23)

## Contract

Tasks, like everything in Elm, are immutable values. A Task never performs
its IO at creation — it *captures a request* for IO, performed only when the
scheduler fulfils it. Running the same Task value twice performs the IO
twice. A Task is therefore a constant that can be fulfilled many times —
including a **memoized CAF** holding a Task.

This is what broke CAF memoization for effect types
(`MVarDropReleasesSlotTest`, see `task-impurity-bug.md` and
`plans/caf-memoization-implementation.md`): the `monoTypeHasEffects` guard
was a workaround for kernel impurities, not a law. This plan removes the
impurities, then removes the guard.

## Survey (2026-07-23, current code — supersedes the stale audit tables in
## `plans/defer-eager-kernel-tasks-via-binding.md`, whose Phases 0–8 have LANDED)

Already deferred via `Elm::Platform::makeBinding` / hand-rolled binding
evaluators (verified by `TaskBinding.hpp` inclusion + binding refs):
`File.cpp` (all), `Console.cpp`, `Env.cpp`, `Process.cpp` (eco),
`Runtime.cpp` (dirname/random/saveState/loadState), `NativeDriver.cpp`,
`Http.cpp` (via HttpService workers), `TimeExports.cpp` (now/here/
getZoneName), `ProcessExports.cpp` (sleep), `Http toTask`. Exemptions that
remain correct: `crash`/`exit` (non-returners), `Console_log` (not a Task).

**Remaining impurities — the entire fix surface:**

| # | Site | Impurity |
|---|---|---|
| I1 | `MVarExports.cpp:13` `Eco_Kernel_MVar_new` | `MVar::newEmpty()` allocates the slot at task CREATION; returns `Task_Succeed id` |
| I2 | `MVar.cpp read()/take()/put()` fast paths | slot state read/popped/stored at CREATION when non-blocking (`take` pops at :264-271, `put` stores at :293-298, `read` snapshots at :242); not-found check also eager |
| I3 | `MVar.cpp drop()` (+`Eco_Kernel_MVar_drop`) | slot erased + waiters abandoned at CREATION |
| I4 | `Scheduler.cpp:455` `spawnTask` | `rawSpawn` allocates AND ENQUEUES the child at CREATION (comment even says "But for simplicity… do it directly"); official Elm's `Scheduler.spawn` is a binding |
| I5 | `Scheduler.cpp:473` `killTask` | performs the kill attempt at CREATION |
| I6 | `Scheduler.cpp:862` | **the only Task-node mutation in the tree**: `currentTask->kill = killHandle` written into the (potentially shared) `Task_Binding` |

Non-findings, checked: no other writes through `Task*` anywhere in
`runtime/`, `eco-kernel-cpp/`, `elm-kernel-cpp/`; Cmd/Sub dispatch
(`PlatformRuntime.cpp`) does not mutate effect values; `succeed/fail/
andThen/onError/taskReceive` are genuinely pure constructors; the binding
step's `closureCapture` backpatch (Scheduler.cpp:843) targets the
per-execution FRESH resume closure, not shared state; closure invocation is
read-only (`eco_pap_extend` copies).

## Fixes

### F1 — MVar: always-binding (deletes KERNEL_TASK_IO_001 exemption (d))

`MVar::read/take/put` already have binding evaluators containing the
full at-EXECUTION logic (fast-resume when the slot state allows, park in
`pendingResumes_` otherwise). So:

- `read()/take()/put()` — delete the creation-time short-circuits AND the
  creation-time not-found check; unconditionally build the evaluator
  closure + `taskBinding` (the code already present as the slow path).
- `readBindingEvaluator/takeBindingEvaluator/putBindingEvaluator` — the
  missing-mvar arm currently returns WITHOUT resuming (dead fiber, was
  unreachable while the eager check ran first). Make it resume with the
  same `taskFailIO(0,"","MVar not found: id")` the eager path produced.
- `newEmpty` wiring: `Eco_Kernel_MVar_new` becomes
  `makeBinding<newBody>(unit())` where `newBody` runs `MVar::newEmpty()`
  and returns `succeedInt(id)` (TaskBinding.hpp wrapper). Effect now fires
  per fulfilment: running a shared/memoized `MVar.new` twice creates two
  MVars — the user contract, and JS/XHR parity (`Eco.XHR.jsonTask`).
- `drop(id)` becomes `makeBinding<dropBody>(payload)` with the id packed
  per File.cpp's Q2 convention (`tuple2(unboxedInt(id), unit, 0x1)`); the
  erase + waiter-abandonment moves into the body.
- `_put_Int/_put_Float/_put_Char` — unchanged code: they box (pure) and
  delegate to the now-always-binding `put`.

### F2 — Scheduler spawn/kill become bindings (fixes exemption (a)'s mislabel)

In `Scheduler.cpp`, using the runtime-side `Elm::Platform::makeBinding`:

- `spawnTask(task)` → `makeBinding<spawnBody>(task)`; `spawnBody` runs
  `rawSpawn(captured)` and returns `taskSucceed(procHP)`. The child is
  allocated and enqueued when the binding is STEPPED, matching elm/core's
  `spawn = binding (\cb -> cb (succeed (rawSpawn task)))`.
- `killTask(procHP)` → `makeBinding<killBody>(procHP)`; `killBody`
  performs today's best-effort kill-attempt logic and returns
  `taskSucceed(unit())`.
- `rawSpawn` itself is untouched (it IS the effect; `Platform.worker`
  startup and effect managers call it directly, correctly).

### F3 — Kill-handle copy-on-install (removes the Task mutation, I6)

Replace the in-place write at Scheduler.cpp:858-864 with a fresh node:
when, after the bind callback returns, the current root is still a
`Task_Binding`, build `newRoot = allocTask(Task_Binding, nil,
root->callback, killHandle, nil)` and `procEncoded =
encodeHP(procWithRoot(currentProcHP(), newRoot))`. The SHARED binding node
is never written; the per-execution copy carries the kill handle.
`killTask`'s reader (`proc->root->kill`) is unchanged — suspended
processes' roots are now the kill-carrying copies. GC discipline: root
`killHandle` across the two allocations (`StackRootGuard`), re-resolve
`proc`/root pointers after each (allocTask may GC — the standing pattern
in this function). The Task GC scanners already trace `t->kill`.

### F4 — Remove the CAF effect guard

- Delete `monoTypeHasEffects` (Functions.elm) and its two uses
  (`cafMemoQualifies`, the `MonoEnum` arm's `enumResultType` check, and
  the now-unused `IO` import + `decomposeFunctionType` plumbing).
- Keep: main-entry strip (shadow-roots balance), port-node exclusion
  (PORT_003), trivial-body filter, `!eco.value`-ABI scope (scalar-slot
  rooting hazard, HEAP_035 — unrelated to effects).
- Soundness after F1–F3: kernel task values defer all effects to
  fulfilment; Task nodes are immutable (interpretation is stack-push
  based; the one writer is gone); sharing one Task_Binding across
  sequential or interleaved executions is safe (per-execution resume
  closures + parking tokens). Cmd/Sub wrap tasks and are read-only at
  dispatch. ProcessId/Router cannot be constructed at the top level.

### F5 — Docs & invariants

- `KERNEL_TASK_IO_001`: delete exemption (d); narrow exemption (a) to
  `succeed/fail/andThen/onError/taskReceive` (spawn/kill are bindings
  now). Add the immutability clause: no code may write into a Task heap
  node after construction (the kill handle travels on per-execution
  copies).
- `CGEN_068`: remove the effect-type-exclusion clause from the predicate
  description.
- `design_docs/caf-memoization-design.md`: rewrite the EXCEPTION block as
  history (resolved by this plan).
- `plans/defer-eager-kernel-tasks-via-binding.md`: status line → LANDED,
  pointer here for the Q5-overturn.
- `plans/caf-memoization-implementation.md` §1.4a note updated.

### F6 — Tests

- New E2E `test/eco-kernel/src/MVarSharedNewTaskTest.elm` (auto-discovered
  beside the 8 existing MVar tests): bind ONE `let t = MV.new` value twice
  — `t ⟹ m1, put m1 111, drop m1, t ⟹ m2, put m2 222, take m2 == 222`.
  Fails if the shared task yields one id (the old eager semantics), passes
  under per-fulfilment semantics. This is the memoized-CAF shape by
  construction once the guard is gone (MV.new IS a CAF).
- Existing suites are the real gate: the 8 MVar E2E tests, full corpus,
  the caf_memo fixtures (unchanged — they don't involve tasks).

### F7 — Gates & benchmark

1. `cmake --build build --target full 2>&1 | tee /tmp/test_output_taskpure.txt`
   (ONCE; grep). Watch for tests depending on EAGER spawn ordering — JS
   parity says deferred is correct; any failure is triaged against the JS
   backend's behavior, not the old native behavior.
2. `cmake --build build --target bootstrap` — 4b + 8c fixed points.
3. Run U battery per `benchmarks/runtime-calls.md` methodology (A/B vs the
   Run T binary): expect ~wall-neutral (MVar/spawn are cold in the
   self-compile; the guard removal adds the ~39 effect-typed CAF slots).
   Record walls + majors/minors (capture the GC-stats STDOUT — Run T
   lesson) + census + slot count.

## Risks

| Risk | Mitigation |
|---|---|
| Deferred spawn changes observable startup ordering for effect managers | rawSpawn call sites in PlatformRuntime/EffectRegistry are direct (not via spawnTask) — unchanged; only Elm-level `Process.spawn` defers. E2E + elm-tests decide. |
| A test depends on eager MVar.take delivering pre-popped values | JS parity is the spec; fix the test if so (none known — the MVar suite passed pre-CAF with recompute-per-reference, which IS per-fulfilment semantics). |
| Kill copy-on-install misses a GC edge | copy path follows the function's existing snapshot+root+re-resolve discipline; tiny-nursery `ECO_HEAP_VALIDATE` leg if anything smells. |
| Binding alloc overhead on hot MVar paths | MVar ops are scheduler-coordination frequency, not per-value; Run U measures. |
