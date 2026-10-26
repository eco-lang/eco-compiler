# Scheduler and Services

A compiled program runs Elm's scheduler, implemented again in C++ over the Eco heap. Tasks and processes are ordinary heap values that are never changed once built. The eco thread steps them one at a time, and it runs every effect manager and every port to completion inside the update that produced their effects. Work that blocks, such as a timer, an HTTP request or a wait for a child process, waits on a worker thread that holds only plain data, and a message from a host program arrives as bytes in a queue. The worker or the queue hands back plain data, and the eco thread turns it into an Elm value. The program stays alive exactly while it holds at least one hold, a counted claim on something it asked for, and the event loop exits when the last one is released and nothing is left to run.

## Elm on one thread, plain data everywhere else

Everything Elm can see lives on the eco thread, and every other thread talks to it in plain data: strings, integers and tokens. The runtime document gives the reason. The collector allows one mutator per process, and it needs no write barrier because no object is written once the program can see it. A second thread running Elm code, or a worker that allocates its own result, breaks the one-mutator rule: the collector would no longer have the heap to itself when it runs, and an allocation on one thread could move an object another thread is reading. So the scheduler is an event loop on the eco thread, and every blocking service has the same shape: a plain request goes in, a token comes out, and all heap work happens later in a drain on the eco thread.

Timers show what goes wrong otherwise. A thread per sleep that resumes Elm from its own thread allocates off the eco thread and corrupts the collector's state. The timer service keeps only deadlines and tokens instead, and the HTTP and child-wait services, and the system library's sockets, signals and file watches, all have its shape.

Parallel Elm is not obtained by locking the stepper so that several threads share one heap. That design is rejected, because the collector and every service contract assume one mutator per heap; [runtime.md](runtime.md) sets out the rejected design and the heap-per-thread direction, which is not built.

Two more rules shape the rest of the scheduler. A process is never changed in place, so code that needs a process later keeps its id, not a pointer to it. And a program is alive only while some piece of outstanding work holds it alive.

## Tasks and processes are heap values

A Task is a heap object with six constructors that match elm/core's scheduler. Succeed and Fail carry a result. AndThen and OnError carry a callback to run on success or on failure, and the inner task to run first. Binding carries the callback that does real work, such as starting a timer. Receive waits for a message. A process is a running task: an id, a root task, a stack of pending callbacks and a mailbox. Keeping both as Elm heap values follows elm/core's scheduler closely. A scheduler built from reference-counted C++ objects in the kernel layer fights the collector and drifts from elm/core's behavior.

Both layouts are short. Besides the header and the small integer fields (the id and a Task's constructor), every field is a heap word, and the collector traces each one that holds a pointer.

```cpp
typedef struct {
    Header header;
    u64 id;
    HPointer root;
    HPointer stack;
    HPointer mailbox;
} Process;
...
typedef struct {
    Header header;
    u64 ctor : CTOR_BITS;
    u64 id : ID_BITS;
    u64 padding : 32;
    Unboxable value;
    HPointer callback;
    HPointer kill;
    HPointer task;
} Task;
```

From `runtime/src/allocator/Heap.hpp`, where `ID_BITS` (the Task id) is 16. Notice two things. A Task's `value` is not always a pointer: a kind bit in the header says whether it holds a boxed value or a raw Int, Float or Char, so a primitive result reaches its callback unboxed. And the process id is a full 64-bit word, which matters below.

The scheduler steps a process by reading its root task and acting on the constructor it finds there. The order of steps within each case is the design.

```text
stepProcess(proc):              -- proc held in a rooted encoded word
  loop on task = proc.root:
    Succeed | Fail:
      pop frames to the nearest one tagged with the same ctor
      none -> stop (finished; an unhandled Fail is logged and dropped, SCHED_002)
      else -> newTask = frame.callback(task.value)
              (primitive value: eco_apply_closure_eval, no boxing)
              proc = procWithRoot(proc, newTask)
    AndThen | OnError:
      proc = pushStack(proc, Succeed | Fail, task.callback)
      proc = procWithRoot(proc, task.task)
    Binding:
      resume = new closure capturing this proc snapshot
      kill   = task.callback(resume)       -- the kernel body runs here
      proc   = procWithRoot(proc, copy of the Binding carrying kill)
      stop                                 -- resume re-enqueues it later
    Receive:
      (proc, msg) = mailboxPopFront(proc); no msg -> stop (blocked)
      proc.id is a self-process -> self-message handler(msg); continue
      else proc = procWithRoot(proc, task.callback(msg))
```

Checked against `stepProcess` in `runtime/src/platform/Scheduler.cpp`. Every case that changes the process produces a fresh one, and the Binding case is the only place where input or output starts. When the work behind a Binding finishes, the resume closure builds a process from the snapshot it captured, with the delivered task as its root, and puts it on the run queue.

The Binding case writes the kill handle into a copy of the Binding made for this one run, never into the Binding itself. A Task is a value: it may be shared, or memoized in a top-level constant, and run many times. A kill handle written into the shared node would let later runs see the first run's state.

Any closure call can allocate, and any allocation can move objects. The stepper therefore keeps the process it is stepping in a rooted word and resolves it again after every call.

## Finding a process by its id

Every change to a process, whether to its root, its stack or its mailbox, allocates a fresh process with the same id. The scheduler records each fresh version in a table from id to the latest process, `latestProc_`. Anything that must reach a process later looks it up by id there: a kill, a message a manager sends to itself, effect dispatch, and the self-message step.

A process is replaced rather than written because it is often old and the value written into it is young. Writing a nursery pointer into an old process's root, stack or mailbox creates an old-to-young pointer that the barrier-free collector cannot see, and in programs that use MVars or spawn processes it corrupts the heap. Replacing the process costs one allocation per step. It also means that any pointer to a process is a snapshot that may already be out of date. That is why the router handed to an effect manager stores its self-process as an id, and why a kill finds its target by id.

The lookup by id is exact because an id names one process for the life of the program and a finished process leaves the table (SD-1, fixed 2026-10-24). The id is a full 64-bit word taken from a counter that never wraps; it was 16 bits until then, and every update spawns one process per registered manager and port, so an ordinary program reused ids after about 22,000 updates, misdelivered self-messages and could kill the wrong process. When a process finishes (its root is Succeed or Fail with no handler on its stack), the stepper drops its table entry and its self-message handler, so neither the process nor its result stays rooted, and a kill aimed at it resolves to nothing and does nothing. Effect dispatch still needs the result of the state process it spawned after the drain: it asks for it before draining (`keepResultOnFinish`), the stepper then moves the finished process to a rooted hand-over slot, and dispatch empties that slot (`takeFinishedProcess`). Pinned by the `platform-services/SD-1` cases in `test/platform/SchedulerPidTest.cpp`.

## The run queue and the event loop

Putting a process on the run queue never runs it. Enqueuing takes the queue's lock, pushes and wakes the loop; nothing else. Processes run only when something drains the queue, and the places that drain are explicit: the event loop, effect dispatch, and kernels that drain on purpose. Draining steps processes until the queue is empty, and it can be entered recursively, which dispatch relies on.

The event loop repeats one cycle of three steps:

1. Drain the run queue.
2. Collect finished outside work. Each fired timer resumes its process with success, and the timer's hold is released only after the resume. Then every registered source of outside work runs its drain on the eco thread.
3. Wait or exit. If the run queue is empty and no holds remain, the loop asks each source whether it has anything ready, then asks the quiescence listeners, consumers that want a last chance to act before the program stops. It exits unless one of them delivered something. Otherwise it sleeps until a stop request, a queued process, a fired timer, a ready source, or the release of the last hold wakes it.

A quiescence listener reports whether it delivered anything, and it decides for itself when to arm again. The scheduler keeps no armed flag on its behalf. If the scheduler armed every listener again whenever outside work arrived, a listener whose handler does input or output would arm itself and fire forever.

The loop's own heap state reaches the collector through one scanner, registered when the scheduler is built. It visits the run queue, the table of latest processes and the resume closures waiting for workers, which all live in C++ containers the collector cannot otherwise see.

## Worker services

Three services in the runtime own worker threads. Each keeps only plain data, and a worker finishes by pushing onto a mutex-guarded queue and waking the loop.

- The timer service keeps deadlines in order, an index from token to timer so a timer can be canceled, and a queue of fired tokens. It starts with the program, because the loop's wait condition reads it. The other two start on first use.
- The HTTP service runs one worker thread that performs requests one after another through libcurl. A queued request waits behind the one that is running. The service keeps a result queue for elm/http, another for the compiler's IO layer `eco/kernel`, which downloads packages through it, a queue of progress reports, and an abort state for each request.
- The wait service blocks waiting for any child process to exit. It keeps a ready queue for each of its two consumers, `eco/kernel` and `eco/system`, and it remembers children that exit before anyone asks about them. On Windows it uses one waiting thread per child.

The HTTP and wait services keep a queue per consumer because two independent libraries use each of them, and neither may take the other's results.

Services outside the runtime join the loop by registering a pair of functions. The drain does all heap work on the eco thread; the readiness test feeds the loop's wait condition. The system library's sockets, signals and file watches, and the queue of port messages from a host, join this way, which is why the loop needs no knowledge of any of them.

## Bindings: where input and output start

A kernel function that returns a Task builds a Binding and does nothing else; the work happens when the scheduler steps it. The runtime document gives the reasons, which come from what an Elm Task means. Two helpers build Bindings, and they differ in whether the work blocks.

- A synchronous binding, built with `makeBinding`, does its work when stepped and resumes at once with the Task it returns. Its kill handle is Unit. `Process.spawn` and `Process.kill` are built this way, so, as in elm/core, they act when stepped and not when constructed.
- An asynchronous binding, built with `makeAsyncBinding`, parks. Its body registers the resume closure under a token and takes a hold in one call (`parkResume`), hands a plain request to a worker, and returns a kill handle.

Both helpers root their argument and the resume closure before the body runs, because the body may allocate. In builds with assertions or heap validation, the asynchronous helper records any body that returns without either queuing work or taking a hold, since such a body leaves its process stopped with nothing to wake it.

## Holds: why the program is still running

A program runs while it waits for something it asked for. Each such wait takes a hold, and the scheduler's count of holds is private: it changes only through the hold interface, which parks a resume, takes or releases a free-standing hold, or does either inside a scoped helper that releases automatically. Deciding liveness resource by resource, through counters scattered across the code, gives counts that disagree about lifetimes, re-arming and cancellation, and leaves a program that never exits with no way to say why.

Three details of the rule matter when writing a service. Sources that merely exist, such as a listener nobody is waiting on, hold nothing. A hold is released only after its result has been delivered to Elm, which is why the loop releases a timer's hold after the resume. And every hold carries a kind. The kind affects only the diagnostic count and embedding, where a host's lifetime hold does not count as work.

The single interface is what makes a stuck program diagnosable. In builds with assertions or heap validation it aborts on a release of an unknown hold or a second release of the same one, and a diagnostic report lists the holds still open by the code that took them.

Cancellation releases a hold exactly once. Killing a sleep withdraws its timer, and releases the hold only if the timer had not yet fired (`withdrawParkedTimer`). Aborting an HTTP request claims it if it is still queued (`RequestControl`). Fire-and-forget cancellation would leave a killed sleep holding its timer and the program, and a canceled request running inside libcurl.

## Effect managers

An effect manager turns commands and subscriptions into work. It has its own state, an initializer, a handler for each batch of effects, a handler for messages it sends itself, and functions that apply the program's taggers to its commands and subscriptions. The platform runtime keeps a table from each manager's home module to these functions, stored as heap references that its own scanner visits. Entries come from four sources:

1. The three elm/* managers, Time, Http and Task, registered when the eco thread starts.
2. The system library's managers, registered by a preamble the compiler generates, one for each manager the program uses.
3. One pseudo-manager for each incoming port, with its decoder.
4. One pseudo-manager for each outgoing port.

The same generated preamble registers both kinds of port, and it runs before the program starts.

Starting a headless program (`initWorker`) runs these steps in order:

1. Decode the host's JSON flags with the decoder the compiler registered.
2. Call the program's init, and root the model.
3. Build the closure that delivers a message to the program. It runs update, then subscriptions, then queues the resulting effects.
4. Set up every manager.
5. Dispatch the initial effects.
6. Tell the host the program is ready, and enter the event loop.

Setting up a manager spawns its self-process, whose root is a Receive, and builds the router the manager's handlers receive: the delivery closure and the self-process's id as an unboxed Int. Setup then calls the initializer, spawns the Task it returns, drains, and reads the initial state. The initializer is a closure with no arguments, so it is called explicitly as a saturated call. Applying zero arguments the ordinary way returns the closure unchanged, and the closure would then be spawned as if it were a Task.

Dispatch is synchronous and complete. Batches of commands and subscriptions are queued and handled one at a time, and a delivery that happens during dispatch only adds to the queue, so two batches never interleave. Gathering walks each batch and hands every leaf to its owning manager with the taggers applied. Then every manager's effect handler runs, even when its lists are empty: its Task is spawned, the whole run queue is drained, and the manager's updated state is read back from that process by id. Every manager runs on every update so that a manager that sees an empty subscription list can drop its timers or listeners, as elm/core's JavaScript does.

Two things depend on dispatch finishing inside the drain that ran the update. The state is read straight back after the drain, so a handler Task that parked would leave the state silently unchanged. And every hold a subscription takes exists before the run queue can empty, so the loop never sees a false moment with nothing to do. No grace hold covering the gap between an update and its subscriptions is needed, because there is no gap.

Self-messages need a step of their own. A process cannot carry the manager's state from one step to the next, and the self-message handler needs the router, the message and the state together. So the scheduler recognizes a self-process by its id, and when one has a message it calls back into the platform runtime, which owns the state. The platform runtime runs the handler, spawns its Task, drains, stores the updated state, and the process waits again. A sender must drain once per message. Putting several snapshots of the same process on the queue before any of them is stepped gives them overlapping mailboxes, and messages are delivered twice.

The platform runtime also keeps its in-progress dispatch state in member fields that its scanner visits while dispatch runs, because handlers allocate and the state must survive a collection.

## Ports and embedding

A port is an effect manager keyed by its bare name. Ports therefore reuse dispatch, tagging and the manager table exactly as elm/core's JavaScript does. Outgoing values arrive already encoded as JSON, and the eco thread turns them into strings for the host's callbacks, holding them until the first subscriber appears. A host may send an incoming value from any thread: the bytes are copied into a queue, each item takes a hold, and the loop wakes. A drain on the eco thread then decodes each payload, applies every subscribed tagger and delivers the messages to the program.

When Eco is embedded, the host owns the process's lifetime, so the loop never exits because the program has gone quiet, and a stop request takes effect after the current drain. A host such as Node needs to know when the eco thread has real work, so the loop reports busy and idle to an activity hook. The host's lifetime hold has its own kind and is left out of the count of work, so an idle embedded program reports idle.

## Start-up, teardown and child processes

The program's entry point does no Elm work. It starts one thread with a 64 MB stack and waits for it to finish. That thread becomes the eco thread: it sets up its heap, registers the kernel's roots, reads the stack maps, registers the elm/* managers and calls the compiled program, whose `Platform.worker` ends in the event loop. The stack is large because compiled Elm recurses deeply, most of all when the compiler compiles itself, and the size matches the stack the JavaScript build gets under Node. Running on a dedicated thread lets an embedding host keep its own thread; the embedding entry point does the same work on a thread the host creates.

The scheduler and its services are singletons that are never destroyed, and their worker threads are detached and never joined. An embedded host can exit the process while the eco thread is still running, so destroying scheduler state in a static destructor would free memory that thread still uses. On Windows the C runtime's teardown would deadlock on locks that parked workers hold, so the entry point ends the process directly.

One component, `Spawn`, starts child processes. It takes plain data and never touches the heap. It spawns rather than forks. A fork copies the whole Eco heap and runs the handlers that stop the collector's helper threads, only to throw all of it away when the child starts its program. On Windows it passes handles to the child explicitly and can tie the child's life to the parent's.

## Examples of changes that fit the theory
A change fits when it keeps every heap interaction on the eco thread, finds processes by id, and keeps the program alive only through named holds.

- A blocking service is a worker holding plain data, a ready queue, a token from `parkResume`, a drain and readiness test registered with the loop, and a hold kind. The wait service's per-consumer queues and the HTTP progress queue have this shape. An evented HTTP client that runs requests concurrently would fit behind the same service interface, because the loop sees only its queues.
- A Task-returning kernel uses `makeBinding`, or `makeAsyncBinding` with the hold taken before the body returns, so the work runs when stepped and the loop knows to wait for it.
- An effect manager goes into the manager table, through the system library's preamble or as a port. It then gets dispatch, the self-message step and tagging with no scheduler change, because the platform runtime finds managers only through that table.
- A cancelable wait returns a kill handle that withdraws the work and releases the hold exactly once, in the manner of `withdrawParkedTimer` and `RequestControl`.
- A consumer that must act when the program goes quiet, or a host that must watch the loop, uses a quiescence listener, a stop hook or the activity hook, and keeps its arming state to itself.
- A fast path for a primitive result goes in the stepper, beside the unboxed Succeed path.

## Examples of changes that would break the theory
Each of these breaks one of the three rules: Elm only on the eco thread, processes found by id, liveness only through holds.

### Work done in the wrong place

- Doing the system call in the kernel function's body, or caching a result inside a Task. The Task stops describing work, and a shared Task acts once. Build a Binding and let its body do the work.
- Touching a heap reference, the allocator or a closure call from a worker, even to allocate the result. That repeats the timer corruption. Return plain data and build the value in the drain.
- Adding locks around stepping so that Elm runs on several threads. The collector and every service assume one mutator. Parallel Elm belongs to the heap-per-thread design.
- Forking to start a child. It copies the heap and stops the collector's helpers. Use `Spawn`.

### Process identity

- Changing a process or Task in place to save an allocation. It creates old-to-young pointers the collector cannot see. Build a fresh one and look the process up by id.
- Keeping a pointer to a process across a step, or storing one for later. The pointer goes stale at the next step. Store the id.
- Putting the same logical process on the queue more than once before it is stepped, for example several self-messages followed by one drain. The snapshots' mailboxes overlap and messages repeat. Drain once per message.

### Liveness

- Changing the hold count directly, or adding a private counter, to keep the program alive. The diagnostic report then misses a reason the program is running. Take a named hold.
- Letting an effect handler or self-message handler park, or dispatching effects outside the drain that ran the update. The manager's state is lost, and the loop can exit before the subscription's hold exists. Keep the handler's Task synchronous.
- Treating a source that merely exists, such as an open listener, as a reason to stay alive. The program then never exits on its own. Take a hold only while waiting for a result.

## References

Parent: [runtime.md](runtime.md). Sibling: [garbage-collector.md](garbage-collector.md).

Code:

- `runtime/src/platform/Scheduler.hpp`, `Scheduler.cpp`: `stepProcess`, `procWithRoot` and the other `procWith*` functions, `enqueue`, `drain`, `runEventLoop`, `processReadyAsync`, `latestProc_`, `latestProcessById`, `rawSpawn` (the 64-bit id), `processFinished`, `keepResultOnFinish`, `takeFinishedProcess`, `registerAsyncSource`, `addQuiescenceListener`, the self-process registry.
- `runtime/src/platform/TaskBinding.hpp`: `makeBinding`, `makeAsyncBinding`, `parkResume`.
- `runtime/src/platform/Liveness.hpp`: hold tokens, `HoldKind`, `LivenessHold`, `HoldRelease`.
- `runtime/src/platform/PlatformRuntime.hpp`, `PlatformRuntime.cpp`: the manager table, `initWorker`, `setupEffects`, `enqueueEffects`, `gatherEffects`, `dispatchEffects`, `handleSelfMsg`, `sendToSelf`, flags.
- `runtime/src/platform/PortRuntime.hpp`, `PortRuntime.cpp`: ports and the host interface (`eco_port_send`).
- `runtime/src/platform/TimerService.*`, `HttpService.*`, `WaitService.*`: the three worker services, `withdrawParkedTimer`, `RequestControl`.
- `runtime/src/platform/Spawn.hpp`, `Spawn.cpp`: child processes.
- `runtime/src/codegen/eco_entry.cpp`, `runtime/src/embed/eco_embed.cpp`: the eco thread's entry points.
- `runtime/src/allocator/Heap.hpp`: the Process and Task layouts, `ID_BITS`.
- `elm-kernel-cpp/src/EffectManagerRegistry.cpp`, `elm-kernel-cpp/src/core/TaskEffectManager.cpp`, `elm-kernel-cpp/src/http/HttpExports.cpp`: the elm/* managers, and the per-message drain for HTTP progress.
- `test/platform/PlatformServicesTest.cpp`, `test/platform/SpawnTest.cpp`: timer cancellation, wait lanes, quiescence listeners, subscription holds during dispatch, spawning without fork.
- `ECO_LIVENESS_REPORT=1`: lists open holds by site at exit and during long idle waits. Builds with `!NDEBUG` or `ECO_HEAP_VALIDATE` keep the hold census.

Invariants (`design_docs/invariants.csv`):

- HEAP_005, HEAP_007, HEAP_031, HEAP_035: fresh-object stores, one mutator, no raw scalars in the root set.
- KERNEL_TASK_IO_001, KERNEL_TASK_IO_002: deferred kernel IO and rooting in bindings.
- SCHED_001: a process id names one process for the life of the program. SCHED_002: an unhandled `Task.fail` ends only its process, with a warning on stderr.
- LIVE_001 to LIVE_006: holds; LIVE_004 is synchronous dispatch, LIVE_005 quiescence listeners, LIVE_006 the private count.
- PORT_001 to PORT_007: ports as managers, the eco thread, JSON flags.
- SYS_002 to SYS_004, SYS_007: system-library managers, services and spawning.

Documents:

- `design_docs/multi-threaded-eco/01-baseline-and-boundary.md`: one mutator today, the rejected shared heap, the heap-per-thread direction.
