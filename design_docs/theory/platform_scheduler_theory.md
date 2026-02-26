# Platform & Scheduler Theory

## Overview

The Platform and Scheduler subsystem implements Elm's effect manager architecture, task execution, and process scheduling at runtime. It bridges the gap between Elm's pure functional programming model and side-effectful operations (HTTP requests, timers, subscriptions) by providing a cooperative, task-based concurrency system.

**Phase**: Runtime

**Pipeline Position**: After LLVM lowering, at execution time

**Related Modules**:
- `runtime/src/platform/PlatformRuntime.hpp/cpp` — Effect manager lifecycle, dispatch, and Platform.worker initialization
- `runtime/src/platform/Scheduler.hpp/cpp` — Task stepping, process management, run queue
- `elm-kernel-cpp/src/core/PlatformExports.cpp` — C-linkage exports for `Platform.batch`, `Platform.map`, routing
- `elm-kernel-cpp/src/core/SchedulerExports.cpp` — C-linkage exports for `Scheduler.succeed`, `andThen`, `spawn`, etc.
- `elm-kernel-cpp/src/core/ProcessExports.cpp` — C-linkage exports for `Process.sleep`
- `elm-kernel-cpp/src/EffectManagerRegistry.cpp` — Central registration of all effect managers
- `runtime/src/allocator/Heap.hpp` — `Task` and `Process` struct definitions
- `runtime/src/allocator/HeapHelpers.hpp` — Task/Process allocation, StackFrame/Router/FxBag constants

## Motivation

Elm programs describe side effects declaratively through commands (`Cmd msg`) and subscriptions (`Sub msg`). The runtime must:

1. **Execute tasks**: Chain asynchronous operations (Task.andThen, Task.onError) with proper success/failure propagation.
2. **Manage processes**: Each spawned task runs in its own lightweight process with a mailbox for message passing.
3. **Dispatch effects**: Collect commands and subscriptions from the Elm update cycle, route them to the appropriate effect managers, and feed resulting messages back into the Elm program.

This mirrors the Elm kernel's JavaScript scheduler but targets native execution with GC-managed heap objects.

## Task ADT

Tasks are heap-resident objects with tag `Tag_Task`. The `Task` struct layout:

```cpp
typedef struct {
    Header header;
    u64 ctor : CTOR_BITS;   // TaskCtor enum value
    u64 id : ID_BITS;       // (unused, reserved)
    u64 padding : 32;
    HPointer value;          // For Succeed/Fail: the result value
    HPointer callback;       // For AndThen/OnError/Binding/Receive: closure to call
    HPointer kill;           // For Binding: kill handle closure
    HPointer task;           // For AndThen/OnError: inner task to evaluate first
} Task;
```

Six task constructors model the full lifecycle:

| Ctor | Value | Fields Used | Semantics |
|------|-------|-------------|-----------|
| `Task_Succeed` | 0 | `value` | Terminal success with a result value |
| `Task_Fail` | 1 | `value` | Terminal failure with an error value |
| `Task_Binding` | 2 | `callback`, `kill` | Suspends process; callback receives a resume closure |
| `Task_AndThen` | 3 | `callback`, `task` | On inner task success, call callback with result |
| `Task_OnError` | 4 | `callback`, `task` | On inner task failure, call callback with error |
| `Task_Receive` | 5 | `callback` | Wait for a mailbox message, then call callback |

Tasks are allocated via `allocTask()` in `HeapHelpers.hpp`.

## Process Model

A `Process` represents a lightweight execution context:

```cpp
typedef struct {
    Header header;
    u64 id : ID_BITS;
    u64 padding : 48;
    HPointer root;      // Current task being executed
    HPointer stack;     // Linked list of StackFrame Custom objects
    HPointer mailbox;   // Linked list of pending messages (LIFO cons list)
} Process;
```

- **root**: The currently active task. Stepping mutates this as the process advances.
- **stack**: A linked list of `StackFrame` objects. Each frame records an expected tag (`Task_Succeed` or `Task_Fail`) and a callback closure to invoke when a matching terminal task is reached.
- **mailbox**: An Elm cons list used as a message queue. Messages are prepended (cons); FIFO order is restored by reversing on pop.

### StackFrame

A StackFrame is a `Custom` object with `ctor = CTOR_StackFrame` (0xFFFE) and three fields:

| Field | Boxed? | Content |
|-------|--------|---------|
| `values[0]` | Unboxed (i64) | Expected tag: `Task_Succeed` or `Task_Fail` |
| `values[1]` | Boxed | Callback closure |
| `values[2]` | Boxed | Next frame in the stack (or Nil) |

The `unboxed_bitmap` is `0x1` (bit 0 set for the unboxed tag field).

## Scheduler

The `Scheduler` is a singleton (`Scheduler::instance()`) that owns the run queue and drives process execution.

### Run Queue

The run queue is a `std::deque<RootedProc>` of encoded `HPointer` values, each pointing to a `Process`. The queue is protected by a mutex for thread safety.

- **`enqueue(proc)`**: Adds a process to the back of the queue. If the scheduler is not already draining, triggers `drain()`.
- **`drain()`**: Sets `working_ = true`, then pops and steps processes until the queue is empty. New processes enqueued during stepping are processed in the same drain cycle.

### stepProcess Loop

`stepProcess` is the core interpreter loop. It repeatedly examines the process's root task and acts based on its constructor:

1. **Task_Succeed / Task_Fail**: Pop the stack looking for a frame whose `expectedTag` matches the task's ctor. If found, call the frame's callback with the task's value and set the result as the new root. If no matching frame exists, the process is finished.

2. **Task_AndThen**: Push a stack frame with `expectedTag = Task_Succeed` and the callback. Set root to the inner task. Continue.

3. **Task_OnError**: Push a stack frame with `expectedTag = Task_Fail` and the callback. Set root to the inner task. Continue.

4. **Task_Binding**: Create a "resume" closure that captures the process pointer. Call the binding callback with this closure. The callback is expected to arrange for the resume closure to be called later (e.g., after a timer or I/O completes). The process suspends (returns from stepProcess).

5. **Task_Receive**: Pop a message from the mailbox. If a message is available, call the receive callback with it and continue. If the mailbox is empty, the process blocks (returns).

**GC safety**: After every closure call, all heap pointers are re-resolved via `resolveHP()` because GC may have relocated objects.

### Closure Calling Helpers

The scheduler provides static helpers for calling Elm closures from C++:

- **`callClosure1(closure, arg)`**: Calls a 1-argument closure via `eco_apply_closure`.
- **`callClosure2(closure, arg1, arg2)`**: Calls a 2-argument closure.
- **`callClosure4(closure, a1, a2, a3, a4)`**: Calls a 4-argument closure (used for `onEffects`).

Arguments are encoded as `uint64_t` before calling `eco_apply_closure`, which handles PAP/saturated dispatch correctly.

## Effect Bag Tree

Elm commands and subscriptions are represented as effect bag trees using `Custom` objects with the `FxBagTag` constructors:

| Ctor | Value | Fields | Semantics |
|------|-------|--------|-----------|
| `Fx_Leaf` | 0 | `values[0]` = home string, `values[1]` = effect value | A single effect for a specific manager |
| `Fx_Node` | 1 | `values[0]` = list of child bags | A batch of effects (`Platform.batch`) |
| `Fx_Map` | 2 | `values[0]` = tagger function, `values[1]` = inner bag | Maps messages through a tagger (`Platform.map`) |

### gatherEffects Traversal

`PlatformRuntime::gatherEffects` recursively walks the bag tree, collecting effects per manager:

- **Fx_Leaf**: Extract the `home` string, apply accumulated taggers to the value, and append to the manager's cmd or sub list.
- **Fx_Node**: Iterate over the child bag list, recursing on each.
- **Fx_Map**: Prepend the tagger to the taggers list, then recurse on the inner bag.

### applyTaggers

Taggers accumulate as a cons list (innermost first). `applyTaggers` walks this list, calling each tagger closure on the value sequentially.

## PlatformRuntime

`PlatformRuntime` is a singleton that manages the effect manager lifecycle and the Platform.worker program loop.

### Manager Registry

Effect managers register via `registerManager(home, info)` where `ManagerInfo` contains:

```cpp
struct ManagerInfo {
    HPointer init;        // Task that produces initial manager state
    HPointer onEffects;   // (router, cmdList, subList, state) -> Task state
    HPointer onSelfMsg;   // (router, selfMsg, state) -> Task state
    HPointer cmdMap;      // Nullable tagger for commands
    HPointer subMap;      // Nullable tagger for subscriptions
};
```

Per-manager runtime state is tracked in `ManagerState`:

```cpp
struct ManagerState {
    uint64_t selfProcess;  // Process that handles onSelfMsg
    uint64_t router;       // Router Custom object
    uint64_t state;        // Current manager state value
};
```

### setupEffects

Called once during `Platform.worker` initialization:

1. For each registered manager:
   - Spawn a self-process running a `Task_Receive` loop for `onSelfMsg`.
   - Create a Router object (see below).
   - Run the manager's `init` task to obtain the initial state.
   - Store the resulting `ManagerState`.
2. Return an empty record (ports not yet supported).

### enqueueEffects / dispatchEffects

`enqueueEffects` buffers effect batches and processes them sequentially to prevent re-entrant dispatch:

1. Push `(cmdBag, subBag)` onto `effectsQueue_`.
2. If not already active (`effectsActive_`), drain the queue by calling `dispatchEffects` for each batch.

`dispatchEffects` does the actual work:

1. Initialize empty effect lists for all registered managers.
2. Call `gatherEffects` on the cmd bag and sub bag to populate per-manager lists.
3. For each manager with a non-nil `onEffects`:
   - Build Elm lists from the gathered cmd/sub vectors.
   - Call `onEffects(router, cmdList, subList, state)`.
   - Spawn and drain the returned task to get the new state.
   - Update `ManagerState.state`.

## Router and Process Communication

A **Router** is a `Custom` object with `ctor = CTOR_Router` (0xFFFD) and two boxed fields:

| Field | Content |
|-------|---------|
| `values[0]` | `sendToApp` closure (sends messages to the Elm program) |
| `values[1]` | Self-process `HPointer` (for `sendToSelf`) |

### sendToApp

Extracts the `sendToApp` closure from the router and calls it with the message. This triggers the Elm update cycle.

### sendToSelf

Extracts the self-process from the router and calls `Scheduler::rawSend(selfProcess, msg)`. This enqueues the message in the self-process's mailbox and re-enqueues the process. Returns `Task.succeed(Unit)`.

## Platform.worker Initialization

`initWorker(impl)` bootstraps an Elm worker program. The `impl` record has fields in canonical order: `{ init, subscriptions, update }`.

**Phases**:

1. **Decode flags**: Currently uses `Unit` as flags (simplified path).
2. **Call init**: `init(flags)` returns `(model, cmd)`.
3. **Root model as GC root**: Store the model in `modelStorage_` and register it with `eco_gc_add_root`.
4. **Build sendToApp closure**: Create a closure capturing `impl` and a pointer to `modelStorage_`, with `workerSendToAppEvaluator` as the evaluator.
5. **Setup effect managers**: Call `setupEffects(sendToAppCl)`.
6. **Initial effects**: Call `subscriptions(model)` and `enqueueEffects(cmd0, subs0)`.
7. **Drain scheduler**: Process all initial tasks and effects.

## Update Cycle

`workerSendToAppEvaluator` is the C function that runs the Elm update cycle when a message arrives:

1. Read the current model from `modelStorage_`.
2. Call `update(msg, model)` → `(newModel, cmd)`.
3. Store `newModel` back to `modelStorage_`.
4. Call `subscriptions(newModel)` → `subs`.
5. Call `enqueueEffects(cmd, subs)`.

The evaluator is a raw C function pointer stored in a Closure, with three captured values:
- `captured[0]` = `impl` record (boxed)
- `captured[1]` = `&modelStorage_` address (unboxed i64)

The argument (`args[2]`) is the incoming message.

## Effect Manager Registration

### ManagerInfo and Registration Protocol

Each effect manager must provide:
- **init**: A `Task` that produces the manager's initial state.
- **onEffects**: `(Router, List cmd, List sub, state) -> Task state` — called on each update cycle with the gathered effects.
- **onSelfMsg**: `(Router, selfMsg, state) -> Task state` — called when the manager sends a message to itself.
- **cmdMap / subMap**: Tagger functions for `Platform.map` (Nil if unused).

Registration happens via `PlatformRuntime::registerManager(home, info)`.

### eco_register_all_effect_managers

`EffectManagerRegistry.cpp` provides a single entry point called before any Elm program runs:

```cpp
void eco_register_all_effect_managers() {
    eco_register_time_effect_manager();
    eco_register_http_effect_manager();
}
```

Each `eco_register_*` function creates the appropriate closures and calls `registerManager`.

### Adding New Effect Managers

To add a new effect manager:

1. Implement the manager's Elm module (e.g., `MyManager.elm`) with `init`, `onEffects`, `onSelfMsg`.
2. Implement C++ kernel exports for any native operations the manager needs.
3. Create an `eco_register_my_manager()` function that:
   - Builds closures for `init`, `onEffects`, `onSelfMsg`.
   - Calls `PlatformRuntime::instance().registerManager("MyManager", info)`.
4. Add the call to `eco_register_all_effect_managers()`.

## GC Root Management

Two categories of values must survive GC across the program's lifetime:

### modelStorage_

The current Elm model is stored as `uint64_t modelStorage_` in `PlatformRuntime`. It is registered as a GC root via `eco_gc_add_root(&modelStorage_)` so the GC knows to trace and update it during collection.

### RootedProc in Run Queue

Processes in the run queue are stored as encoded `HPointer` values (`RootedProc.encoded`). While the current implementation does not individually register each process as a GC root, the scheduler's drain loop re-resolves process pointers after every closure call to handle GC relocation.

## Key Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `Task_Succeed` | 0 | Task completed successfully |
| `Task_Fail` | 1 | Task completed with error |
| `Task_Binding` | 2 | Task suspended for async callback |
| `Task_AndThen` | 3 | Chain: on success, call callback |
| `Task_OnError` | 4 | Chain: on failure, call callback |
| `Task_Receive` | 5 | Wait for mailbox message |
| `CTOR_StackFrame` | 0xFFFE | Custom ctor for stack frames |
| `CTOR_Router` | 0xFFFD | Custom ctor for router objects |
| `Fx_Leaf` | 0 | Single effect for one manager |
| `Fx_Node` | 1 | Batch of effects |
| `Fx_Map` | 2 | Mapped/tagged effect |
| `Tag_Task` | (enum) | Heap object tag for Task structs |
| `Tag_Process` | (enum) | Heap object tag for Process structs |

## Relationship to Other Subsystems

- **EcoToLLVM**: The compiled Elm code calls kernel exports (`Elm_Kernel_Scheduler_*`, `Elm_Kernel_Platform_*`) which are lowered to direct C function calls by the LLVM backend.
- **Heap/GC**: Task, Process, StackFrame, Router, and FxBag objects are all GC-managed heap objects. The scheduler must re-resolve pointers after any allocation or closure call.
- **Kernel ABI**: Platform and Scheduler kernel functions use `AllBoxed` ABI (all arguments are `uint64_t`-encoded `HPointer` values).
- **JSON**: `Platform.worker` flag decoding will integrate with the [JSON heap representation](json_heap_representation_theory.md) for parsing initialization flags.

## See Also

- [Heap Representation Theory](heap_representation_theory.md) — Custom struct layout, HPointer encoding
- [EcoToLLVM Theory](pass_eco_to_llvm_theory.md) — How kernel calls are lowered
- [Kernel ABI Theory](kernel_abi_theory.md) — AllBoxed ABI used by Platform/Scheduler exports
- [JSON Heap Representation Theory](json_heap_representation_theory.md) — JSON decoding for flags
