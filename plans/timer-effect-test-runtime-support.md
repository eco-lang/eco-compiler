# Plan: Runtime Support for Timer/Effect E2E Test

## Goal

Make `test/elm/src/TimerEffectTest.elm` pass as an E2E test. This `Platform.worker` program fires `Process.sleep 100` five times via `Task.perform`, counting firings with `Debug.log`, then exits.

Four gaps must be closed:
0. **Compiler fix** — `Task.command` generates a stub returning Unit; it needs to create `Fx_Leaf` bags
1. **Task effect manager** — `Task.perform` needs an effect manager to route commands
2. **Single-threaded event loop** — timer threads must not run Elm code; the main thread needs an event loop
3. **Output capture** — solved automatically once all Elm code runs on the main thread

---

## Current Architecture (and what's wrong)

### Compiler: `Task.command` is a dead stub

Compiled MLIR shows `Task_command_$_17` returns Unit:
```mlir
"func.func"() ({
    ^bb0(%arg0: !eco.value):
      %1 = "eco.constant"() {kind = 1 : i32} : () -> !eco.value  // Unit!
      "eco.return"(%1) ...
}) {sym_name = "Task_command_$_17"} : () -> ()
```

**Root cause**: In `Compiler/LocalOpt/Typed/Module.elm`, the `$fx$` global is created as `TOpt.Manager effectsType`, and `Task.command` is a `TOpt.Link` to `$fx$`. The monomorphizer (`Specialize.elm` line 356) handles `Manager` by producing `MonoExtern`, which the MLIR codegen turns into a stub.

In the JS backend (`Generate/JavaScript.elm`), the Manager node instead generates `_Platform_leaf(moduleName)` — a partial application that creates `Fx_Leaf` bags. The MLIR backend has no equivalent.

**`Task.perform` call chain** (from MLIR):
```
Task_perform_$_12(toMsg, task)
  → Task_map(toMsg, task)        // wraps in Task_AndThen
  → Task_Perform(mappedTask)     // wraps in a Perform ctor
  → Task_command_$_17(perform)   // SHOULD create Fx_Leaf("Task", perform)
                                 // ACTUALLY returns Unit
```

### Timer thread runs the entire Elm update cycle

When `Process.sleep` fires, its detached `std::thread` calls:
```
sleepBindingEvaluator timer thread
  → callClosure1(resumeClosure, succeedTask)     // runs on timer thread
    → resumeEvaluator
      → Scheduler::enqueue(proc)
        → drain()                                 // runs on timer thread!
          → stepProcess → ... → sendToApp
            → workerSendToAppEvaluator
              → update(msg, model)                // Elm code on timer thread!
              → enqueueEffects(newCmd, newSubs)
```

**Same bug exists in `TimeEffectManager.cpp`**: `timerWorker` directly calls `PlatformRuntime::sendToApp(router, msg)` from the timer thread.

### No event loop

`PlatformRuntime::initWorker()` calls `Scheduler::drain()` once, then returns. There is no mechanism to wait for async effects (timer threads) to complete.

### Thread-local output capture

`tl_output_stream` is `thread_local`. Timer threads have `tl_output_stream = nullptr`, so their `Debug.log` output falls through to `fputs(stderr)`. The captured output buffer on the main thread misses all timer-driven output.

### No Task effect manager

Only Time and Http are registered in `EffectManagerRegistry.cpp`. `Task.perform` creates an `Fx_Leaf` with home `"Task"`, but no manager matches that home string, so the command is silently dropped.

---

## Plan

### Step 0: Fix compiler — generate `Elm_Kernel_Platform_leaf` calls for Manager nodes

**Decision**: Fix the compiler's MLIR codegen (option a). This is the correct architectural fix.

The JS backend's `generateManager` produces `_Platform_leaf(moduleName)`. We need the MLIR backend to produce equivalent code: a function that calls `Elm_Kernel_Platform_leaf(homeString, value)`.

#### Step 0a: Add `MonoManagerLeaf` variant to `MonoNode`

**File**: `compiler/src/Compiler/AST/Monomorphized.elm`

Add a new variant that carries the home module name:

```elm
type MonoNode
    = MonoDefine MonoExpr MonoType
    | MonoTailFunc (List ( Name, MonoType )) MonoExpr MonoType
    | MonoCtor CtorShape MonoType
    | MonoEnum Int MonoType
    | MonoExtern MonoType
    | MonoManagerLeaf String MonoType  -- NEW: home module name, type
    | MonoPortIncoming MonoExpr MonoType
    | MonoPortOutgoing MonoExpr MonoType
    | MonoCycle (List ( Name, MonoExpr )) MonoType
```

Update `nodeType` to handle the new variant:
```elm
        MonoManagerLeaf _ t ->
            t
```

#### Step 0b: Monomorphizer generates `MonoManagerLeaf` instead of `MonoExtern`

**File**: `compiler/src/Compiler/Monomorphize/Specialize.elm` (line 356)

Change the `Manager` case. The home module name is extracted from `state.currentGlobal`, which is always set by `processWorklist` before entering `specializeNode`:

```elm
        TOpt.Manager _ ->
            let
                homeModuleName =
                    case state.currentGlobal of
                        Just (Mono.Global (IO.Canonical _ modName) _) ->
                            Name.toElmString modName

                        _ ->
                            -- Should not happen; Manager nodes are always reached
                            -- through a global reference that sets currentGlobal
                            "Unknown"
            in
            ( Mono.MonoManagerLeaf homeModuleName requestedMonoType, state )
```

**Why `state.currentGlobal` is safe**: The Manager node is always reached through `Task.command` → Link → `Task.$fx$` → Manager. `processWorklist` sets `state.currentGlobal = Just (Mono.Global (IO.Canonical pkg "Task") "command")` before calling `specializeNode`. The module name "Task" from `currentGlobal` matches the Manager's home module.

#### Step 0c: MLIR codegen generates leaf function body

**File**: `compiler/src/Compiler/Generate/MLIR/Functions.elm`

Add a new case in `generateNode`:

```elm
        Mono.MonoManagerLeaf homeModuleName monoType ->
            let
                ( ctx1, op ) =
                    generateManagerLeaf ctx funcName homeModuleName monoType
            in
            ( [ op ], ctx1 )
```

Implement `generateManagerLeaf`. This generates a function that:
1. Creates a string constant for the home module name
2. Calls `Elm_Kernel_Platform_leaf(homeStr, arg0)`
3. Returns the result

Expected MLIR output for `Task_command_$_17`:
```mlir
"func.func"() ({
    ^bb0(%arg0: !eco.value):
      %0 = "eco.string_literal"() {value = "Task"} : () -> !eco.value
      %1 = "eco.call"(%0, %arg0) {callee = @Elm_Kernel_Platform_leaf, ...}
           : (!eco.value, !eco.value) -> !eco.value
      "eco.return"(%1) : (!eco.value) -> ()
}) {sym_name = "Task_command_$_17", function_type = (!eco.value) -> !eco.value}
```

Note: `ecoCallNamed` with prefix `"Elm_Kernel_"` auto-registers the kernel function via `Ctx.registerKernelCall`, which causes a `func.func` extern declaration with `is_kernel = true` to be emitted. No manual registration needed.

#### Step 0d: Update all other passes that match on `MonoNode`

Add `MonoManagerLeaf` handling (treat identically to `MonoExtern` in all cases):

| File | Change |
|------|--------|
| `compiler/src/Compiler/Generate/MLIR/Context.elm` (~line 592) | Add `MonoManagerLeaf _ monoType ->` case alongside `MonoExtern` |
| `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm` | Add to arity count (line ~162), pass-through (line ~1051), extern detection (line ~1317), arity lookup (line ~1383) |
| `compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm` | Already uses `_ ->` wildcard (line ~535) for pass-through — **no change needed** |
| `compiler/src/Compiler/GlobalOpt/Staging/ProducerInfo.elm` (~line 65) | Add case alongside `MonoExtern` |
| `compiler/src/Compiler/Monomorphize/Analysis.elm` (~line 284) | Add case for type collection |

### Step 1: Add `Elm_Kernel_Platform_leaf` C++ kernel export

**Files**: `elm-kernel-cpp/src/core/PlatformExports.cpp`, `elm-kernel-cpp/src/KernelExports.h`, `runtime/src/codegen/RuntimeSymbols.cpp`

Add a function that creates an `Fx_Leaf` bag:

```cpp
extern "C" uint64_t Elm_Kernel_Platform_leaf(uint64_t home, uint64_t value) {
    HPointer homeHP = decode(home);
    HPointer valueHP = decode(value);
    std::vector<Unboxable> fields(2);
    fields[0].p = homeHP;
    fields[1].p = valueHP;
    HPointer bag = alloc::custom(Fx_Leaf, fields, 0);
    return encode(bag);
}
```

Register in `RuntimeSymbols.cpp` alongside the other Platform symbols.

### Step 2: Implement Task effect manager

**New file**: `elm-kernel-cpp/src/core/TaskEffectManager.cpp`
**Modified files**: `elm-kernel-cpp/src/KernelExports.h`, `elm-kernel-cpp/src/EffectManagerRegistry.cpp`

The Task effect manager has commands only (no subscriptions). Its `onEffects` receives a list of `Perform(task)` commands and spawns each task, routing the result back to the app via `Platform.sendToApp`.

**onEffects logic** (C++):
```
for each cmd in cmds:
    task = cmd.values[0]   // extract the Task from Perform(task)
    // Chain: task |> andThen(\value -> sendToApp(router, value))
    chainedTask = taskAndThen(sendToAppClosure, task)
    rawSpawn(chainedTask)
return taskSucceed(state)
```

Key details:
- Register with home string `"Task"` (matches the string generated by Step 0c)
- `cmdMap` creates a closure that maps over the inner task of a `Perform` value
- `subMap` is `Nil` (Task has no subscriptions)
- `onSelfMsg` is a no-op that returns `taskSucceed(state)`

### Step 3: Single-threaded event loop

The principle: **timer threads only enqueue events; the main thread runs all Elm code.**

#### Step 3a: Add event queue infrastructure to Scheduler

**File**: `runtime/src/platform/Scheduler.hpp`

```cpp
// New members:
std::condition_variable eventCV_;
std::atomic<int> pendingAsync_{0};

// New public methods:
void runEventLoop();           // Main thread blocks here
void incrementPendingAsync();  // Called before spawning async work
void decrementPendingAsync();  // Called when async work completes
```

#### Step 3b: Modify `Scheduler::enqueue` to never call `drain`

**File**: `runtime/src/platform/Scheduler.cpp`

Current:
```cpp
void Scheduler::enqueue(HPointer proc) {
    { lock; runQueue_.push_back(rp); }
    if (!working_) drain();   // BUG: runs on calling thread
}
```

New:
```cpp
void Scheduler::enqueue(HPointer proc) {
    { lock; runQueue_.push_back(rp); }
    eventCV_.notify_one();  // Wake the main thread
}
```

`drain()` is now only called from `runEventLoop()` on the main thread.

#### Step 3c: Implement `Scheduler::runEventLoop`

```cpp
void Scheduler::runEventLoop() {
    while (true) {
        drain();  // Process all queued work on main thread

        std::unique_lock<std::mutex> lock(mutex_);
        // Exit when no queued work AND no pending async operations
        if (runQueue_.empty() && pendingAsync_.load() == 0) {
            break;
        }
        // Block until something is enqueued or all async work finishes
        eventCV_.wait(lock, [this] {
            return !runQueue_.empty() || pendingAsync_.load() == 0;
        });
    }
}
```

**Race condition prevention (Q5)**: Timer threads MUST call `enqueue()` BEFORE `decrementPendingAsync()`. Both operations acquire `mutex_`, ensuring the main thread never sees a transient `(empty queue, 0 pending)` state. The `enqueue` → lock → push → notify → unlock → `decrementPendingAsync` → lock → decrement → notify → unlock sequence guarantees the run queue is non-empty before the pending count drops.

#### Step 3d: Modify `Process.sleep` timer thread — init GC per thread

**File**: `elm-kernel-cpp/src/core/ProcessExports.cpp`

**Decision (Q3)**: Initialize GC per timer thread. This is simpler than eliminating all allocation from timer threads.

```cpp
// Before spawning thread:
Scheduler::instance().incrementPendingAsync();

std::thread([procHP, millis, cancelledForThread, resumeClosure]() {
    Allocator::initThread();   // Init GC for this thread

    std::this_thread::sleep_for(chrono::milliseconds(millis));

    if (!cancelledForThread->load()) {
        // Create succeed(unit) task on this thread (now safe with GC init)
        auto succeedTask = taskSucceed(unit());
        // Call resume closure to set proc->root = succeedTask
        callClosure1(resumeClosure, encode(succeedTask));
        // enqueue() just pushes to queue + signals CV (no drain)
    }

    Scheduler::instance().decrementPendingAsync();
    Allocator::cleanupThread();
}).detach();
```

With the Step 3b change, `enqueue` no longer calls `drain()`, so the timer thread only pushes onto the queue and signals the condition variable. The main thread's event loop then drains.

#### Step 3e: Modify `PlatformRuntime::initWorker` to use event loop

**File**: `runtime/src/platform/PlatformRuntime.cpp`

Replace the current Phase 7:
```cpp
// Phase 7: Drain the scheduler to process initial effects
Scheduler::instance().drain();
```

With:
```cpp
// Phase 7: Run the event loop (blocks until program is idle)
Scheduler::instance().runEventLoop();
```

#### Step 3f: Fix `TimeEffectManager.cpp` timer threading

**Decision (Q6)**: Fix now for consistency.

The Time effect manager's `timerWorker` directly calls `PlatformRuntime::sendToApp(router, msg)` from the timer thread. Fix to use the same pattern: init GC, build the message, `enqueue` a process that calls `sendToApp`, then `decrementPendingAsync`.

### Step 4: Output capture works automatically

Once all Elm code runs on the main thread (via `runEventLoop` inside `initWorker`, which is inside `main`, which is inside `executeJIT` where output capture is active), `Debug.log` calls will write to the thread-local capture buffer correctly. No separate fix needed.

---

## Execution Order

```
Step 0 (compiler fix)      ── must be first (changes compiled output)
  ↓
Step 1 (Platform_leaf)     ─┐
Step 2 (Task manager)      ─┤── can be done in parallel
Step 3a-3f (event loop)    ─┘
  ↓
Step 4: verify (automatic)
```

---

## Resolved Questions

### Q1: Compiler naming — RESOLVED via MLIR inspection
The compiler generates `Task_command_$_17` as a stub returning Unit. After Step 0, it will generate a function calling `Elm_Kernel_Platform_leaf("Task", value)`. The home string `"Task"` comes from the module's canonical name.

### Q2: Home string for Task effect manager — RESOLVED
The home string is `"Task"` (the module name). This is confirmed by inspecting how `Module.elm` creates the Manager node from `IO.Canonical pkg "Task"`. The same string is used in the generated `eco.string_literal` op (Step 0c) and the effect manager registration (Step 2).

### Q3: Timer thread heap allocation — RESOLVED: init GC per thread
Timer threads call `Allocator::initThread()` / `cleanupThread()`. This is simpler than eliminating all allocation. With the `enqueue` change (Step 3b), timer threads still don't run the full Elm update cycle.

### Q4: Event loop exit condition — RESOLVED: simple for now
`runQueue.empty && pendingAsync == 0` is sufficient. Subscription tracking deferred to a future task.

### Q5: Race condition in exit check — RESOLVED: mutex-guarded ordering
Timer thread does `enqueue()` (acquires mutex, pushes, notifies) THEN `decrementPendingAsync()` (acquires mutex, decrements, notifies). The mutex serialization guarantees the main thread never sees transient `(empty, 0)`.

### Q6: TimeEffectManager threading — RESOLVED: fix now
Fix `TimeEffectManager.cpp` in Step 3f for consistency, using the same pattern as Process.sleep.

---

## Files Modified

| File | Change |
|------|--------|
| `compiler/src/Compiler/AST/Monomorphized.elm` | Add `MonoManagerLeaf` variant to `MonoNode` |
| `compiler/src/Compiler/Monomorphize/Specialize.elm` | Manager case produces `MonoManagerLeaf` |
| `compiler/src/Compiler/Generate/MLIR/Functions.elm` | `generateNode` handles `MonoManagerLeaf`; new `generateManagerLeaf` |
| `compiler/src/Compiler/Generate/MLIR/Context.elm` | Add `MonoManagerLeaf` case |
| `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm` | Add `MonoManagerLeaf` cases (4 sites) |
| `compiler/src/Compiler/GlobalOpt/Staging/ProducerInfo.elm` | Add `MonoManagerLeaf` case |
| `compiler/src/Compiler/Monomorphize/Analysis.elm` | Add `MonoManagerLeaf` case |
| `elm-kernel-cpp/src/core/PlatformExports.cpp` | Add `Elm_Kernel_Platform_leaf` |
| `elm-kernel-cpp/src/KernelExports.h` | Declare `Elm_Kernel_Platform_leaf`, `eco_register_task_effect_manager` |
| `elm-kernel-cpp/src/core/TaskEffectManager.cpp` | **New** — Task effect manager implementation |
| `elm-kernel-cpp/src/EffectManagerRegistry.cpp` | Add `eco_register_task_effect_manager()` call |
| `runtime/src/codegen/RuntimeSymbols.cpp` | Register `Elm_Kernel_Platform_leaf` symbol |
| `runtime/src/platform/Scheduler.hpp` | Add `eventCV_`, `pendingAsync_`, `runEventLoop()`, `incrementPendingAsync()`, `decrementPendingAsync()` |
| `runtime/src/platform/Scheduler.cpp` | Implement event loop; modify `enqueue` to not call `drain` |
| `runtime/src/platform/PlatformRuntime.cpp` | `initWorker` calls `runEventLoop()` instead of `drain()` |
| `elm-kernel-cpp/src/core/ProcessExports.cpp` | Timer thread: init GC, increment/decrement pendingAsync |
| `elm-kernel-cpp/src/time/TimeEffectManager.cpp` | Fix timer threading (same pattern as Process.sleep) |
| `test/elm/src/TimerEffectTest.elm` | Already written |

---

## Risk: `enqueue` change affects synchronous callers

Today, `enqueue` calls `drain()` when `!working_`. Several call sites rely on this for synchronous processing:
- `rawSpawn` → `enqueue` (during `initWorker` setup)
- Effect manager `onEffects` may spawn processes that need to complete before continuing

With the new `enqueue` (no drain), these synchronous callers would need to call `drain()` explicitly. Audit all `enqueue` callers:
- `Scheduler::rawSpawn` — called from `setupEffects` and effect manager `onEffects`. The subsequent `drain()` call in `initWorker` (or `runEventLoop`) would handle it.
- `Scheduler::rawSend` — sends a message to a process mailbox and enqueues.
- `resumeEvaluator` — timer thread resume.

The key insight: during `initWorker`, the initial effects are processed by the explicit `drain()` (or `runEventLoop`). Calls to `enqueue` within that drain cycle will add to the run queue, and drain's loop picks them up. So synchronous callers during drain are fine. Only the "first kick" (starting drain from enqueue) is removed.

**However**: `rawSpawn` during `setupEffects` (effect manager init) calls `enqueue`, which currently triggers `drain`. If we remove that, the init tasks won't be processed until the next drain. Since `setupEffects` explicitly calls `drain()` after each init task, this should be fine — but needs verification.

---

## Open Items

### The `createManager` call
In the JS backend, `generateManager` also emits a `_Platform_createManager(init, onEffects, onSelfMsg, cmdMap, subMap)` call that registers the effect manager at runtime. In our architecture, this registration happens in C++ via `eco_register_all_effect_managers()`. So the compiler does NOT need to generate a `createManager` call — the C++ registration in Step 2 is the equivalent.

### Subscription leaf (`Task.subscription`)
The Task module is `Cmd`-only, so it only has `command`, not `subscription`. For modules with `Sub` or `Fx` effects types, the same `MonoManagerLeaf` mechanism will work — the MLIR codegen generates the same `Elm_Kernel_Platform_leaf(moduleName, value)` call. The effect manager's `subMap` then routes the leaf to the correct subscription list. No additional work needed for the Task test.
