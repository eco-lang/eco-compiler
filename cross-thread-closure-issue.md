# Cross-thread closure HPointer leak in `TimeEffectManager` and `httpWorkerThread`

**Status:** Open. Two effect-manager paths in `elm-kernel-cpp` stash an
HPointer-encoded closure in a side table, then call it from a worker thread
that owns its own thread-local heap. The origin thread's GC has no way to
visit the side table, and the worker's GC doesn't own the closure cell — so
any minor or major GC on the origin thread can move/sweep the cell while the
worker keeps using the now-stale encoded HPointer.

This is **structurally distinct** from the `JsArray_foldl/foldr/map/indexedMap`
issue fixed on 2026-05-02 (see
`heap-profiles/hunter/closure-arg-crash-report.md`). That bug was
*intra-thread*: the kernel forgot to root its own parameter across an inner
GC. The fix was a `StackRootGuard` extension. The cases below can't be fixed
that way — the origin thread isn't even on the stack while the worker runs.

## Why this exists

Eco's GC is per-thread by design: each thread that calls
`Allocator::initThread()` gets its own `ThreadLocalHeap` (nursery + old gen),
and only that thread's mutator runs minor/major GC against it. Roots are
tracked per-thread (`RootSet` lives in `ThreadLocalHeap`). The heap *base*
address is global, so an HPointer can be resolved from any thread, but a
collection on thread A only walks A's roots — anything held only by thread B
becomes invisible.

That contract works as long as a cell allocated on thread A is only used on
thread A. The two cases below break it: thread A allocates a closure (because
the user's Elm code subscribed to a timer or kicked off an HTTP request),
the kernel saves the encoded HPointer in a C++ side table, and a *different*
thread later loads it back out and calls `eco_apply_closure(…)`.

## Case 1: `TimeEffectManager::timerWorker`

Source: `elm-kernel-cpp/src/time/TimeEffectManager.cpp`

The Elm-side path: `Time.every interval msg` → effect manager →
`startTimer(intervalMs, taggerEnc, routerEnc)`.

```cpp
// elm-kernel-cpp/src/time/TimeEffectManager.cpp
struct TimerState {
    std::atomic<bool> running{true};
    double intervalMs;
    uint64_t taggerEnc;  // Encoded closure  <-- HPointer bits
    uint64_t routerEnc;  // Encoded router for sendToApp
};

static std::unordered_map<double, std::unique_ptr<TimerState>> g_activeTimers;
static std::unordered_map<double, std::thread> g_timerThreads;

void timerWorker(double intervalMs) {
    TimerState* state = …;          // looked up under g_timerMutex

    // Init GC for this thread so we can allocate heap objects
    Allocator::instance().initThread();   // <-- worker gets ITS OWN heap

    auto interval = std::chrono::milliseconds(static_cast<int64_t>(intervalMs));
    while (state->running.load()) {
        std::this_thread::sleep_for(interval);
        if (!state->running.load()) break;

        // Allocate a Posix Int on the WORKER's nursery.
        HPointer posix = allocInt(ms);

        // Decode taggerEnc as if it were valid here, and call it.
        uint64_t posixEnc = encodeHP(posix);
        uint64_t msgEnc =
            eco_apply_closure(HPtr::fromBits(state->taggerEnc), &posixEnc, 1).toBits();

        HPointer router = decodeHP(state->routerEnc);
        HPointer msg    = decodeHP(msgEnc);
        PlatformRuntime::instance().sendToApp(router, msg);
    }
    Allocator::instance().cleanupThread();
    Scheduler::instance().decrementPendingAsync();
}
```

`taggerEnc` is the user's `Posix -> msg` function — a closure allocated by
whichever thread first called `startTimer`. That's the main mutator thread
in normal use. Whenever the mutator runs a minor GC, the closure cell can:

- be evacuated to the mutator's to-space (a forward is left at the old
  address, but `taggerEnc` is a `uint64_t` in a C++ struct — neither the
  evacuator nor any external root scanner registered against the mutator's
  RootSet knows it exists, so the encoded value isn't updated);
- be promoted to the mutator's old-gen, then freed in a later major GC if
  no live root keeps it alive (and again, none does).

The mutator's RootSet has only one external scanner that touches HPointers
in `TimeEffectManager`: there isn't one. `g_activeTimers` is invisible to
GC. A few minor GCs after the subscription is registered, `taggerEnc` is
stale.

The worker thread's GC is even worse: when the worker calls
`eco_apply_closure(state->taggerEnc, …)`, that function internally does
`hpointerToPtr(closure_bits)` → `heap_base + (bits.ptr << 3)` → an address
inside the *mutator's* nursery (or old gen). The worker's
`ThreadLocalHeap::isInNursery(ptr)` returns *false* for that address (it's
not in the worker's region), so the worker won't try to collect it — but
that doesn't help, because the cell's contents have already been overwritten
by the mutator's evacuator/sweeper.

Result: depending on how soon the timer fires after subscription:

- Most often the worker's first call lands while the cell is still a valid
  closure in the mutator's nursery (the mutator hasn't GC'd yet). It works
  exactly once.
- After any minor GC on the mutator, the cell is `Tag_Forward` and the
  worker walks into the forwarded address pretending it's a closure header,
  reading whatever happens to be at offset 1/2/3 — the assertion in
  `eco_closure_call_saturated` fires, or worse, a wild evaluator pointer is
  invoked.
- If the mutator runs a major GC in between, the cell is reclaimed and
  re-used; the worker now reads bytes from an unrelated allocation, fails
  silently (sends a garbage message), or crashes with a SIGSEGV when the
  evaluator pointer dereferences something nonsensical.

There is a second cross-thread footgun in the same file: the Posix `Int`
allocated on line 88 (`HPointer posix = allocInt(ms);`) is allocated on the
**worker's** heap, then `sendToApp` hands it to the main thread via the
scheduler — so now the mutator might, on its own GC, walk a pointer that
resolves into the worker's heap, which the mutator's evacuator doesn't own.
Same family of bug, different direction.

## Case 2: `httpWorkerThread`

Source: `elm-kernel-cpp/src/http/HttpExports.cpp`

```cpp
// elm-kernel-cpp/src/http/HttpExports.cpp
struct HttpContext {
    …
    uint64_t resumeClosureEnc;   // Encoded closure to call on completion
    uint64_t expectHandlerEnc;   // Encoded expect handler closure
};

void httpWorkerThread(HttpContext ctx) {
    // (no initThread call shown here, but the path eventually calls
    //  eco_apply_closure on a heap that wasn't the origin's)
    …
    uint64_t resultEnc = eco_apply_closure(
        HPtr::fromBits(ctx.expectHandlerEnc), &responseEnc, 1).toBits();
    …
    eco_apply_closure(HPtr::fromBits(ctx.resumeClosureEnc), &taskEnc, 1);
}

// Caller (binding evaluator):
auto bindingEval = [](void* args[]) -> void* {
    …
    cap->ctx.resumeClosureEnc = resumeEnc;        // <-- resume closure from scheduler
    cap->ctx.expectHandlerEnc = cap->expectHandler;
    std::thread worker(httpWorkerThread, cap->ctx);
    worker.detach();
    …
};
```

The shape is identical to the timer case:

1. Some Elm code calls `Http.send` → produces a Task.Binding whose
   resume-closure is allocated on the mutator's heap.
2. The binding evaluator stores the encoded closure bits in
   `HttpContext::resumeClosureEnc` and `expectHandlerEnc` and spawns a
   detached worker.
3. The mutator goes back to running other tasks. Any GC during the network
   round-trip moves or sweeps the closure cell, and the encoded values in
   `HttpContext` aren't updated.
4. When the network call completes, the worker calls `eco_apply_closure` on
   the (potentially) stale encoded HPointer. Same failure modes as the
   timer case.

The mutator doesn't even know the HTTP context exists — it's a stack
variable in a C++ lambda copied into a worker thread. No root scanner is
registered against it.

## Why this hasn't bitten the eco-compiler

The eco-compiler `make` workload uses neither `Time.every` nor
`Http.request`:

- `compiler/src/Builder/Reporting.elm:90`, `Builder/Deps/Registry.elm:212`
  etc. call `Time.now`, which is a synchronous read — no worker thread
  spawned.
- `grep -rn 'Process\.sleep' /work/compiler/src` returns no hits.
- `grep -rn 'Time\.every\|Http\.' /work/compiler/src` returns no hits.

So the timer worker thread starts up only because `TimerService::instance()`
is constructed (the singleton spawns a detached thread that just blocks on
its `timersCV_` waiting for tokens — it never holds an HPointer). The
`TimeEffectManager` and `HttpExports` paths are dead in compiler runs.

In the closure-arg crash investigation, `gettid()` instrumentation across
the crashing run showed all 49 tagged log lines on a single tid; no worker
thread ever spawned. That's why the JsArray fix alone is enough for the
compiler workload, even though these cross-thread holes remain in the
runtime.

But the moment an Elm app uses `Time.every` (e.g., a clock subscription, a
poll loop) or `Http.request` (any web call) under non-trivial GC pressure,
this lands. The tighter `nursery_growth_threshold` (we ship 0.85 by default
now) probably masks it for short-lived demo apps; a long-running app with
periodic timers and any allocation pressure will trip it.

## Fix options

There are two ways to make this safe.

**Option A — register a per-origin-thread external root scanner.**
The runtime already supports this for `Scheduler::pendingResumes_`,
`PlatformRuntime::managers_`, and the MVar table:
`RootSet::addExternalRootScanner` takes a closure that the GC invokes during
mark/evacuate, and the closure can hand the GC every encoded `uint64_t`
slot it owns. `TimeEffectManager` would register a scanner on the *origin
thread's* RootSet (not the worker's) when it first creates a TimerState,
walking `g_activeTimers` and evacuating each `taggerEnc`/`routerEnc`.

The catch: the scanner needs to know which thread "owns" each
`TimerState` — the thread that allocated the closure, not the worker. That
means recording the origin `ThreadLocalHeap*` (or RootSet*) when
`startTimer` runs, and only registering the scanner once per origin thread.
Same idea for `HttpContext`: each context's encoded closures need to be
visible to the origin's GC for the lifetime of the HTTP call.

The protocol change is small but invasive: every kernel that detaches a
worker thread holding HPointers needs to publish those HPointers somewhere
the origin's RootSet can find them, and unpublish them when the worker is
done.

**Option B — marshal the call back to the origin thread.**
Instead of `eco_apply_closure(state->taggerEnc, …)` running on the worker,
the worker could enqueue a "fire this closure with this Posix" message into
the scheduler's `pendingResumes_` (which already has an external root
scanner) and let the main thread's `processReadyAsync` pick it up. The
worker thread becomes purely an event source (it allocates nothing on the
heap; it just pushes a token).

This is closer to how `Process.sleep` already works:
`TimerService::workerLoop` holds only `uint64_t` tokens, never HPointers,
and the *main* thread handles the resume via
`Scheduler::processReadyAsync`. Reshaping `Time.every` and `Http.request`
into the same pattern eliminates the cross-thread HPointer entirely.

Option B is structurally cleaner and matches the existing safe pattern. It
costs a context-switch per fire (worker enqueues, main thread drains) and
forces the response message to round-trip through the scheduler queue, but
both are tolerable for the use cases. Option A keeps the current
worker-allocates pattern at the cost of more bookkeeping.

## Reproduction plan (when this gets prioritised)

A minimal Elm program that subscribes to `Time.every 100 Tick` and
allocates moderately on each tick should reproduce the bug under
`nursery_growth_threshold=0.125` within seconds. The same crash signature
as the JsArray bug — `eco_closure_call_saturated`'s
`closure->n_values + num_newargs != max_values` assertion — will fire,
likely after a minor GC moves the tagger closure between two timer fires.
Repro is harder under default `nursery_growth_threshold=0.85` because GCs
are sparse and a tagger usually survives a tick.

For HTTP, `Http.send` against a deliberately slow endpoint (or a local
mock that delays the response by ~500 ms) while the main thread runs
allocation-heavy work in parallel will exhibit the same crash on response.

## References

- Closure-arg crash root cause + fix:
  `heap-profiles/hunter/closure-arg-crash-report.md`
- External root scanner mechanism:
  `runtime/src/allocator/RootSet.hpp` (`ExternalRootScanner` /
  `addExternalRootScanner`)
- Existing safe pattern for `Process.sleep`:
  `runtime/src/platform/TimerService.cpp` (token-only worker) +
  `runtime/src/platform/Scheduler.cpp` (`processReadyAsync`)
- Cross-thread sites listed in this doc:
  - `elm-kernel-cpp/src/time/TimeEffectManager.cpp` (timer worker)
  - `elm-kernel-cpp/src/http/HttpExports.cpp` (HTTP worker)
