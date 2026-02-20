# Platform + Scheduler Implementation Plan

## Status: PLAN — Decisions resolved, ready for implementation

---

## Context

`design_docs/platform.md` provides a comprehensive design for implementing Elm's Scheduler (cooperative Task/Process execution) and Platform (Cmd/Sub effect manager framework) in ECO's C++ runtime. This plan turns that design into concrete implementation steps.

### Current State (verified by codebase exploration)

**Already done — no work needed:**
- `Tag_Task` (13) and `Tag_Process` (12) in `Heap.hpp` Tag enum
- `Task` and `Process` structs in `Heap.hpp` (lines 224-242) with HPointer fields
- GC fully handles both: `getObjectSize`, `markChildren`, `evacuate`, `fixPointersInObject` all have Task/Process cases
- 12 kernel symbols registered in `RuntimeSymbols.cpp` (lines 434-459)
- CMake targets `ElmKernel_Scheduler`, `ElmKernel_Platform`, `ElmKernel_Process` exist
- Closure calling pattern: `closure->evaluator(args)` with captured values prepended (StringExports.cpp)
- Generic closure helpers: `eco_apply_closure`, `eco_pap_extend`, `eco_closure_call_saturated` in RuntimeExports.h
- GC root API: `eco_gc_add_root(uint64_t*)` / `eco_gc_remove_root(uint64_t*)` in RootSet
- `alloc::custom(ctor, values, unboxed_mask)` for Custom type allocation
- `ExportHelpers.hpp` encode/decode for HPointer ↔ uint64_t

**Exists but must be replaced:**
- `elm-kernel-cpp/src/core/Scheduler.cpp/.hpp` — uses `std::shared_ptr`, incompatible with heap representation

**Stubbed — needs implementation:**
- All 12 kernel exports in `*Exports.cpp` (all `assert(false)`)
- No `runtime/src/platform/` directory
- No Task/Process allocation helpers in HeapHelpers
- No StackFrame allocation
- No effect bag (Cmd/Sub) allocation
- No PlatformRuntime (effect manager registry/dispatch)
- No Platform.worker initialization

---

## Resolved Design Decisions

### Q1: Representation — **A: Delete old Scheduler.cpp**

Remove `elm-kernel-cpp/src/core/Scheduler.cpp/.hpp` from the build. The new heap-native implementation lives in `runtime/src/platform/Scheduler.*`. The old code can be moved to `design_docs/reference/` if desired, but must not remain in the live tree. A `std::shared_ptr`-based scheduler fights the GC, diverges from Elm's JS scheduler semantics, and creates confusion.

### Q2: StackFrame type — **B: Use Custom with dedicated ctor**

Stack frames `{expectedTag, callback, rest}` are allocated as `Custom` objects with a reserved ctor tag (e.g., `CTOR_StackFrame = 0xFFFF` or similar sentinel). GC already handles Custom generically via child slot scanning — no changes to `getObjectSize`, `scanObject`, or `markChildren` needed. Helper:
```cpp
HPointer alloc::stackFrame(u64 expectedTag, HPointer callback, HPointer rest);
```
The `expectedTag` is stored as an unboxed i64 field (bit 0 in unboxed_mask), `callback` and `rest` are boxed HPointers.

### Q3: GC root strategy — **A: Per-process roots**

Each process in the run queue is registered as a GC root via `eco_gc_add_root` / `eco_gc_remove_root`. The Scheduler stores process HPointers as `uint64_t` values with corresponding root registrations. When a process completes (root goes null), its root is unregistered. This matches the design in `platform.md` and requires no GC changes.

### Q4: Json dependency — **C now, A later**

For initial implementation, `Platform.worker` uses a minimal flag path: pass `()` (Unit) to `impl.init` without calling `Json.run`. This unblocks all Scheduler/Platform work. Later, implement full Json kernel and update `Platform.worker` to decode flags properly.

### Q5: Cmd/Sub bag origin — **Kernel-constructed**

Bags are built only through `Elm_Kernel_Platform_batch`, `Elm_Kernel_Platform_map`, and an internal `leaf` helper. The C++ kernel allocates `Leaf`/`Node`/`Map` as Custom heap objects with specific ctor tags. The compiler emits calls to these kernel functions; it doesn't know the internal layout.

### Q6: Effect manager registration — **B: C++ kernel registers managers**

Each C++ kernel module (Time, Http, etc.) registers its manager info by calling `PlatformRuntime::registerManager("home", info)`. Registration happens either via static initialization or via a one-time init function called from `Platform.worker` before `setupEffects`. Clean path to compiler-emitted registration later if needed.

### Q7: Implementation ordering — **Bottom-up (Phase 0 → 1 → 2 → 3 → 4 → 5 → 6)**

Implement every phase in order, completing each fully before moving to the next. This ensures a solid foundation at each layer and avoids partial implementations that are hard to test in isolation.

---

## Implementation Phases

### Phase 0: Foundation — Heap Allocation Helpers + Cleanup

**Goal:** Add Task/Process/StackFrame allocation helpers. Remove old Scheduler from build.

**Files to modify:**
- `runtime/src/allocator/HeapHelpers.hpp` — Add Task/Process/StackFrame allocation declarations
- `runtime/src/allocator/HeapHelpers.cpp` — Add implementations (if not inline)
- `elm-kernel-cpp/CMakeLists.txt` — Remove `Scheduler.cpp` from `ElmKernel_Scheduler` sources (keep `SchedulerExports.cpp`)

**Files to move (out of build, keep as reference):**
- `elm-kernel-cpp/src/core/Scheduler.cpp` → `design_docs/reference/Scheduler_old.cpp`
- `elm-kernel-cpp/src/core/Scheduler.hpp` → `design_docs/reference/Scheduler_old.hpp`

**New allocation helpers:**
```cpp
namespace alloc {

// Task allocation — fields: value, callback, kill, task (all boxed HPointers)
// ctor: TaskCtor enum (Succeed=0, Fail=1, Binding=2, AndThen=3, OnError=4, Receive=5)
inline HPointer allocTask(u16 ctor, HPointer value, HPointer callback,
                          HPointer kill, HPointer innerTask) {
    auto& allocator = Allocator::instance();
    size_t total_size = sizeof(Task);
    total_size = (total_size + 7) & ~7;
    Task* t = static_cast<Task*>(allocator.allocate(total_size, Tag_Task));
    t->ctor = ctor;
    t->id = 0;  // Scheduler assigns IDs
    t->value = value;
    t->callback = callback;
    t->kill = kill;
    t->task = innerTask;
    return allocator.wrap(t);
}

// Process allocation — fields: root, stack, mailbox (all boxed HPointers)
inline HPointer allocProcess(u16 id, HPointer root, HPointer stack, HPointer mailbox) {
    auto& allocator = Allocator::instance();
    size_t total_size = sizeof(Process);
    total_size = (total_size + 7) & ~7;
    Process* p = static_cast<Process*>(allocator.allocate(total_size, Tag_Process));
    p->id = id;
    p->root = root;
    p->stack = stack;
    p->mailbox = mailbox;
    return allocator.wrap(p);
}

// StackFrame — Custom with 3 fields: expectedTag (unboxed i64), callback (boxed), rest (boxed)
// Uses a reserved ctor tag to distinguish from user Custom types.
static constexpr u16 CTOR_StackFrame = 0xFFFE;

inline HPointer stackFrame(u64 expectedTag, HPointer callback, HPointer rest) {
    Unboxable fields[3];
    fields[0].i = expectedTag;                           // unboxed i64
    fields[1].i = static_cast<u64>(callback.ptr) | (static_cast<u64>(callback.constant) << 40);
    fields[2].i = static_cast<u64>(rest.ptr) | (static_cast<u64>(rest.constant) << 40);
    std::vector<Unboxable> v(fields, fields + 3);
    return custom(CTOR_StackFrame, v, 0x1);  // bit 0 = field 0 is unboxed
}

} // namespace alloc
```

**TaskCtor enum** (add to HeapHelpers.hpp or a shared header):
```cpp
enum TaskCtor : u16 {
    Task_Succeed  = 0,
    Task_Fail     = 1,
    Task_Binding  = 2,
    Task_AndThen  = 3,
    Task_OnError  = 4,
    Task_Receive  = 5,
};
```

**No GC changes needed** — Tag_Task/Tag_Process already handled. StackFrame uses Tag_Custom which is also handled.

**Estimate:** ~100 lines new code + build file edits.

---

### Phase 1: Core Scheduler — Task Constructors & Step Loop

**Goal:** Implement the cooperative Scheduler runtime and wire up all 6 Scheduler kernel exports.

**Files to create:**
- `runtime/src/platform/Scheduler.hpp`
- `runtime/src/platform/Scheduler.cpp`

**Files to modify:**
- `elm-kernel-cpp/src/core/SchedulerExports.cpp` — Replace all 6 stubs
- `runtime/src/codegen/CMakeLists.txt` — Add `../platform/Scheduler.cpp` to source list
- `elm-kernel-cpp/CMakeLists.txt` — Add include path for `runtime/src/platform/`

**Scheduler class design:**
```cpp
namespace Elm::Platform {

class Scheduler {
public:
    static Scheduler& instance();

    // === Task constructors (allocate heap Task objects) ===
    HPointer taskSucceed(HPointer value);
    HPointer taskFail(HPointer error);
    HPointer taskBinding(HPointer callback);
    HPointer taskAndThen(HPointer callback, HPointer task);
    HPointer taskOnError(HPointer callback, HPointer task);
    HPointer taskReceive(HPointer callback);

    // === Process API ===
    HPointer rawSpawn(HPointer rootTask);    // Create process, enqueue, return Process HPointer
    HPointer spawnTask(HPointer rootTask);   // Returns Task that yields Process handle
    void rawSend(HPointer proc, HPointer msg);  // Append to mailbox, enqueue
    HPointer sendTask(HPointer proc, HPointer msg);  // Returns Task.succeed(Unit)
    HPointer killTask(HPointer proc);        // Returns Task that kills process

private:
    Scheduler();

    // === Run loop ===
    void enqueue(HPointer proc);
    void drain();                    // Process run queue until empty
    void stepProcess(HPointer proc); // Execute one step of a process

    // === Closure calling helper ===
    // Calls an Elm closure (HPointer to Closure) with one HPointer argument.
    // Returns the HPointer result.
    static HPointer callClosure1(HPointer closurePtr, HPointer arg);

    // === Mailbox helpers (Elm List as FIFO) ===
    static bool mailboxPopFront(Process* proc, HPointer& outMsg);
    static void mailboxPushBack(Process* proc, HPointer msg);

    // === Stack helpers ===
    static void pushStack(Process* proc, u64 expectedTag, HPointer callback);
    static bool popStackMatching(Process* proc, u64 rootTag, HPointer& outCallback);

    // === GC root management ===
    struct RootedProc {
        uint64_t encoded;  // HPointer as uint64_t (for eco_gc_add_root)
    };
    void registerRoot(RootedProc& rp);
    void unregisterRoot(RootedProc& rp);

    // === State ===
    std::deque<RootedProc> runQueue_;
    bool working_;
    std::mutex mutex_;
    std::atomic<u32> nextProcId_{0};
};

} // namespace Elm::Platform
```

**Step loop pseudocode** (mirrors JS `_Scheduler_step` exactly):
```
stepProcess(proc):
    while proc->root is not null:
        task = resolve(proc->root)
        switch task->ctor:
            case Succeed/Fail:
                if popStackMatching(proc, task->ctor, callback):
                    newTask = callClosure1(callback, task->value)
                    proc->root = newTask
                else:
                    proc->root = null  // process finished
                    return

            case Binding:
                // Create resume closure, call binding callback
                // binding returns kill handle
                // Process suspends (return without nulling root)
                return

            case Receive:
                if mailboxPopFront(proc, msg):
                    newTask = callClosure1(task->callback, msg)
                    proc->root = newTask
                else:
                    return  // block until message arrives

            case AndThen:
                pushStack(proc, Task_Succeed, task->callback)
                proc->root = task->task

            case OnError:
                pushStack(proc, Task_Fail, task->callback)
                proc->root = task->task
```

**Binding tasks — the resume closure problem:**
The Binding callback signature is `(resume: Task -> ()) -> killHandle`. The `resume` function must:
1. Set `proc->root = newTask`
2. Re-enqueue the process

This requires creating an Elm closure in C++ that captures a process HPointer. Options:
- **Option A:** Allocate a Closure on the heap with a C function pointer as evaluator and the process HPointer as a captured value. The evaluator function casts args back and calls `Scheduler::instance().enqueue()`.
- **Option B:** Use `eco_apply_closure` indirectly — but we need to create the closure first.

Option A is the standard approach. We create a small C function:
```cpp
static void* resumeEvaluator(void* args[]) {
    HPointer proc = decodeFromArg(args[0]);   // captured
    HPointer newTask = decodeFromArg(args[1]); // argument
    Process* p = resolve(proc);
    p->root = newTask;
    Scheduler::instance().enqueue(proc);
    return reinterpret_cast<void*>(encode(alloc::unit()));
}
```
Then allocate a Closure with `evaluator = resumeEvaluator`, `n_values = 1`, `max_values = 2`, `values[0] = proc`.

**Kernel exports** (thin wrappers in SchedulerExports.cpp):
```cpp
uint64_t Elm_Kernel_Scheduler_succeed(uint64_t value) {
    HPointer v = Export::decode(value);
    HPointer t = Elm::Platform::Scheduler::instance().taskSucceed(v);
    return Export::encode(t);
}
// ... similarly for fail, andThen, onError, spawn, kill
```

**Estimate:** ~500 lines (Scheduler.hpp/cpp) + ~80 lines (exports).

---

### Phase 2: Process.sleep — Async Timer

**Goal:** Implement `Elm_Kernel_Process_sleep` using a binding Task.

**Files to modify:**
- `elm-kernel-cpp/src/core/ProcessExports.cpp` — Replace stub

**Implementation:**
```cpp
uint64_t Elm_Kernel_Process_sleep(uint64_t timeVal) {
    // timeVal is a boxed Float (Elm's Time.Posix is Float milliseconds)
    HPointer timePtr = Export::decode(timeVal);
    // Extract float value (resolve -> ElmFloat -> value field)

    // Create a binding task:
    // callback receives "resume" closure, spawns timer thread, returns kill closure
    HPointer bindingCallback = allocBindingSleepClosure(milliseconds);
    return Export::encode(Scheduler::instance().taskBinding(bindingCallback));
}
```

The binding callback:
1. Receives `resume` closure as argument
2. Spawns `std::thread` that sleeps then calls `resume(Task.succeed(Unit))`
3. Returns a kill closure that sets `std::atomic<bool> cancelled = true`

**Threading:** The timer thread calls back into the main thread via `Scheduler::enqueue`. The mutex in Scheduler protects the run queue. After enqueuing, `drain()` is called if not already working.

**Kill handle:** Allocate a Closure that captures a `std::atomic<bool>*` and sets it to true. The timer thread checks this flag after waking.

**Concern:** The `std::atomic<bool>` lives on the C++ heap (not GC heap) — must be cleaned up. Use a small helper struct allocated with `new` that the kill closure and timer thread share via `std::shared_ptr<std::atomic<bool>>` or raw pointer with clear ownership.

**Estimate:** ~100 lines.

---

### Phase 3: Platform Basics — Cmd/Sub Bags

**Goal:** Implement `Platform.batch` and `Platform.map` kernel exports, plus the internal `leaf` helper.

**Files to modify:**
- `elm-kernel-cpp/src/core/PlatformExports.cpp` — Replace batch/map stubs

**Bag ctor tags:**
```cpp
enum FxBagTag : u16 {
    Fx_Leaf = 0,  // { home: String, value: a }  — 2 boxed fields
    Fx_Node = 1,  // { bags: List(Bag) }          — 1 boxed field
    Fx_Map  = 2,  // { func: a->b, bag: Bag a }  — 2 boxed fields
};
```

**Implementation:**
```cpp
// Internal: leaf(home, value) — called by effect manager kernels
HPointer platformLeaf(HPointer home, HPointer value) {
    std::vector<Unboxable> fields = {{.i = encode(home)}, {.i = encode(value)}};
    return alloc::custom(Fx_Leaf, fields, 0);  // both boxed
}

// batch(listOfBags) -> Cmd msg
uint64_t Elm_Kernel_Platform_batch(uint64_t listVal) {
    HPointer list = Export::decode(listVal);
    std::vector<Unboxable> fields = {{.i = encode(list)}};
    HPointer bag = alloc::custom(Fx_Node, fields, 0);
    return Export::encode(bag);
}

// map(tagger, bag) -> Cmd msg
uint64_t Elm_Kernel_Platform_map(uint64_t taggerVal, uint64_t bagVal) {
    HPointer tagger = Export::decode(taggerVal);
    HPointer bag = Export::decode(bagVal);
    std::vector<Unboxable> fields = {{.i = encode(tagger)}, {.i = encode(bag)}};
    HPointer mapped = alloc::custom(Fx_Map, fields, 0);
    return Export::encode(mapped);
}
```

**Estimate:** ~60 lines.

---

### Phase 4: Effect Dispatch — PlatformRuntime

**Goal:** Implement the effect manager registry, effect gathering, and dispatch queue.

**Files to create:**
- `runtime/src/platform/PlatformRuntime.hpp`
- `runtime/src/platform/PlatformRuntime.cpp`

**Files to modify:**
- `elm-kernel-cpp/src/core/PlatformExports.cpp` — sendToApp, sendToSelf
- `runtime/src/codegen/CMakeLists.txt` — Add PlatformRuntime.cpp

**PlatformRuntime class:**
```cpp
namespace Elm::Platform {

class PlatformRuntime {
public:
    static PlatformRuntime& instance();

    // === Manager registry ===
    struct ManagerInfo {
        HPointer init;       // Task (initial state)
        HPointer onEffects;  // router -> List cmd -> List sub -> state -> Task state
        HPointer onSelfMsg;  // router -> selfMsg -> state -> Task state
        HPointer cmdMap;     // nullable
        HPointer subMap;     // nullable
    };

    void registerManager(const std::string& home, const ManagerInfo& info);

    // === Effect setup (called once from Platform.worker) ===
    // Creates routers + manager processes, returns ports record (or null).
    HPointer setupEffects(HPointer sendToAppClosure);

    // === Effect dispatch ===
    void enqueueEffects(HPointer cmdBag, HPointer subBag);

    // === Routing ===
    HPointer sendToApp(HPointer router, HPointer msg);
    HPointer sendToSelf(HPointer router, HPointer msg);

private:
    PlatformRuntime();

    // Walk bag tree, collect effects per manager home
    void gatherEffects(bool isCmd, HPointer bag,
                       std::unordered_map<std::string, std::pair<HPointer,HPointer>>& effects,
                       HPointer taggers);
    HPointer applyTaggers(HPointer taggers, HPointer value);

    // Dispatch collected effects to manager processes
    void dispatchEffects();

    // === State ===
    std::unordered_map<std::string, ManagerInfo> managers_;

    // Per-manager runtime state (created by setupEffects)
    struct ManagerState {
        HPointer selfProcess;  // Manager's own Process
        HPointer router;       // Router Custom with {sendToApp, selfProcess}
        HPointer state;        // Current manager state
    };
    std::unordered_map<std::string, ManagerState> managerStates_;

    // Effects queue (re-entrant safe)
    struct FxBatch { HPointer cmdBag; HPointer subBag; };
    std::vector<FxBatch> effectsQueue_;
    bool effectsActive_;
};

} // namespace Elm::Platform
```

**Router structure** — Custom with 2 boxed fields:
```cpp
static constexpr u16 CTOR_Router = 0xFFFD;
// fields[0] = sendToApp closure, fields[1] = selfProcess
```

**sendToApp kernel export:**
```cpp
uint64_t Elm_Kernel_Platform_sendToApp(uint64_t routerVal, uint64_t msgVal) {
    HPointer router = Export::decode(routerVal);
    HPointer msg = Export::decode(msgVal);
    HPointer task = PlatformRuntime::instance().sendToApp(router, msg);
    return Export::encode(task);
}
```

`sendToApp` creates a binding Task that:
1. Resolves router → extracts sendToApp closure
2. Calls `sendToApp(msg)`
3. Resumes with `Task.succeed(Unit)`

**sendToSelf** calls `Scheduler::rawSend(router.selfProcess, wrappedMsg)`.

**Estimate:** ~400 lines.

---

### Phase 5: Platform.worker — Full Initialization

**Goal:** Implement `Elm_Kernel_Platform_worker` to initialize a worker program.

**Files to modify:**
- `elm-kernel-cpp/src/core/PlatformExports.cpp` — worker function

**Platform.worker logic** (mirrors JS `_Platform_initialize`):

```
worker(impl, flagDecoder, debugMetadata, args):
    // Phase 1: Decode flags (MINIMAL PATH: skip Json, pass Unit)
    flags = Unit

    // Phase 2: Call init
    initPair = callClosure1(impl.__$init, flags)  // (model, Cmd msg)
    model = getTuple2Field0(initPair)
    cmd0 = getTuple2Field1(initPair)

    // Phase 3: Build sendToApp closure
    // sendToApp(msg) must:
    //   pair = callClosure2(impl.__$update, msg, model)
    //   model = pair.a
    //   newCmd = pair.b
    //   subs = callClosure1(impl.__$subscriptions, model)
    //   PlatformRuntime::enqueueEffects(newCmd, subs)
    sendToAppClosure = allocSendToAppClosure(impl, &model)

    // Phase 4: Setup effect managers
    ports = PlatformRuntime::instance().setupEffects(sendToAppClosure)

    // Phase 5: Enqueue initial effects
    subs0 = callClosure1(impl.__$subscriptions, model)
    PlatformRuntime::instance().enqueueEffects(cmd0, subs0)

    // Phase 6: Return ports (or empty record for worker)
    return ports
```

**Accessing `impl` fields:** `impl` is an Elm Record. Need to access fields like `__$init`, `__$update`, `__$subscriptions`. These are record field accesses by index. The compiler determines field order; we need to know the indices. For Platform's `impl` record, the field names and order are known (they come from the Elm Platform module).

**The `model` mutable state problem:** `sendToApp` must read and update `model`. In JS this is a mutable variable in closure scope. In C++:
- Allocate `model` as a global variable (HPointer stored outside the heap, registered as GC root)
- The sendToApp closure captures a pointer to this storage location
- On each update call, write the new model to that location

**Estimate:** ~300 lines.

---

### Phase 6: Testing

**Goal:** Comprehensive tests for each phase.

**Test files to create:**

1. `test/elm/src/TaskChainTest.elm` — Task.succeed / andThen / fail / onError chains
2. `test/elm/src/ProcessSleepTest.elm` — Process.sleep with timer
3. `test/elm/src/CmdBatchTest.elm` — Platform.batch, Platform.map
4. `test/elm/src/WorkerTest.elm` — Minimal Platform.worker

**TaskChainTest.elm example:**
```elm
module TaskChainTest exposing (main)
-- CHECK: TaskChainTest: 43
import Task
main =
    Task.succeed 42
        |> Task.andThen (\x -> Task.succeed (x + 1))
        |> Task.perform (\result -> Debug.log "TaskChainTest" result)
```

**WorkerTest.elm example:**
```elm
module WorkerTest exposing (main)
-- CHECK: WorkerTest: initialized
import Platform
main = Platform.worker
    { init = \() -> (0, Cmd.none) |> Debug.log "WorkerTest: initialized"
    , update = \msg model -> (model, Cmd.none)
    , subscriptions = \_ -> Sub.none
    }
```

**C++ unit tests:**
- Allocate Task/Process objects, verify GC traces them correctly
- Spawn processes, trigger GC mid-execution, verify survival

**Estimate:** ~200 lines.

---

## Dependency Graph (Bottom-Up)

```
Phase 0: Heap Helpers + Cleanup
    ↓
Phase 1: Core Scheduler (task constructors, step loop, GC roots)
    ↓
Phase 2: Process.sleep (async binding with timer thread)
    ↓
Phase 3: Platform Bags (batch, map, leaf)
    ↓
Phase 4: PlatformRuntime (effect manager registry, dispatch, routing)
    ↓
Phase 5: Platform.worker (full TEA initialization loop)
    ↓
Phase 6: Testing (comprehensive E2E + unit tests)
```

Strict sequential ordering. Each phase fully complete before starting the next.

---

## Risk Assessment

1. **Closure creation from C++:** The step loop's Binding handler must create a "resume" Closure on the heap with a C function pointer as evaluator. This is the most novel pattern — no existing kernel code creates Closures from C++. Must carefully set `n_values`, `max_values`, `unboxed` bitmap, and `evaluator` pointer. The Closure must survive GC (it's on the heap, so it will if reachable from a rooted process).

2. **GC during closure calls:** Calling an Elm closure may trigger allocation which may trigger GC. Any HPointers held in local C++ variables may become stale if the objects get moved. Must re-resolve HPointers after any closure call or allocation. Pattern: hold `uint64_t` encoded values (stable across GC) and decode to HPointer only when needed.

3. **Reentrancy in effects queue:** Dispatching effects may call Elm closures that trigger more effects. The `effectsActive_` flag + queue approach from the JS design handles this correctly.

4. **Thread safety for Process.sleep:** Timer thread calls back into Scheduler from a different thread. The mutex in `Scheduler::enqueue` protects the run queue. Must ensure `drain()` is only called from the main thread — the timer thread only enqueues, does not drain.

5. **Platform.worker's mutable model:** The `model` state must be a GC-rooted HPointer that persists across update cycles. Using a global `uint64_t` registered with `eco_gc_add_root` is the simplest approach.

6. **Record field access for `impl`:** Platform.worker must access `impl.__$init`, `impl.__$update`, `impl.__$subscriptions`. These are record field accesses by index. Need to determine or hardcode the field indices for the Platform impl record.

---

## Estimated Total Effort

| Phase | Lines (approx) | Complexity |
|-------|----------------|------------|
| Phase 0: Heap helpers + cleanup | ~100 | Low |
| Phase 1: Core Scheduler | ~580 | High |
| Phase 2: Process.sleep | ~100 | Medium |
| Phase 3: Platform bags | ~60 | Low |
| Phase 4: PlatformRuntime | ~400 | High |
| Phase 5: Platform.worker | ~300 | Very High |
| Phase 6: Testing | ~200 | Medium |
| **Total** | **~1740** | |

---

## Files Summary

### New files
| File | Phase | Purpose |
|------|-------|---------|
| `runtime/src/platform/Scheduler.hpp` | 1 | Scheduler class declaration |
| `runtime/src/platform/Scheduler.cpp` | 1 | Scheduler implementation |
| `runtime/src/platform/PlatformRuntime.hpp` | 4 | Effect manager registry/dispatch |
| `runtime/src/platform/PlatformRuntime.cpp` | 4 | PlatformRuntime implementation |
| `test/elm/src/TaskChainTest.elm` | 6 | Task chain E2E test |
| `test/elm/src/ProcessSleepTest.elm` | 6 | Process.sleep E2E test |
| `test/elm/src/WorkerTest.elm` | 6 | Platform.worker E2E test |

### Modified files
| File | Phase | Change |
|------|-------|--------|
| `runtime/src/allocator/HeapHelpers.hpp` | 0 | Add allocTask, allocProcess, stackFrame helpers |
| `elm-kernel-cpp/CMakeLists.txt` | 0 | Remove old Scheduler.cpp from build |
| `runtime/src/codegen/CMakeLists.txt` | 1,4 | Add platform/*.cpp sources |
| `elm-kernel-cpp/src/core/SchedulerExports.cpp` | 1 | Replace 6 stubs with real implementations |
| `elm-kernel-cpp/src/core/ProcessExports.cpp` | 2 | Replace sleep stub |
| `elm-kernel-cpp/src/core/PlatformExports.cpp` | 3,4,5 | Replace batch/map/sendToApp/sendToSelf/worker stubs |

### Moved files
| File | Phase | Destination |
|------|-------|-------------|
| `elm-kernel-cpp/src/core/Scheduler.cpp` | 0 | `design_docs/reference/Scheduler_old.cpp` |
| `elm-kernel-cpp/src/core/Scheduler.hpp` | 0 | `design_docs/reference/Scheduler_old.hpp` |
