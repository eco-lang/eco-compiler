# Kernel Task Deferral

## Invariant

Every C++ symbol returning an Elm `Task` in `eco-kernel-cpp/` and
`elm-kernel-cpp/` must perform its IO inside a `Task_Binding` callback —
NOT at kernel-call time. See `KERNEL_TASK_IO_001` /
`KERNEL_TASK_IO_002` in `design_docs/invariants.csv`.

## Why

Pre-Phase-3 (May 2026), most C++ kernel functions performed their syscalls
eagerly:

```cpp
HPtr Eco_Kernel_File_writeString(HPtr path, HPtr content) {
    // BAD (eager): syscall happens at kernel-call time.
    std::ofstream f(toString(path));
    f << toString(content);
    return HPtr::fromBits(taskSucceedUnit());
}
```

This had several consequences:

1. **No interleaving.** Two `Task`s built from `File.readString` / `Http.fetch`
   run their syscalls sequentially at construction. The scheduler never
   observed two outstanding bindings, so it had no opportunity to
   interleave them with timer fires, HTTP completions, or other parked
   resumes.
2. **Wrong semantics for time-varying reads.** `Time.now` was historically
   frozen to module-init time before its deferred-binding fix; the same
   class of bug existed for `Runtime.random` and (more subtly) for
   `Env.rawArgs`.
3. **Blocking kernels stalled the scheduler.** `Http.fetch` / `getArchive`
   ran `curl_easy_perform` synchronously, blocking the scheduler thread
   for the full network call. `Process.wait` blocked on `waitpid`.

## The pattern

A `Task_Binding` HPointer wraps a callback closure. When the scheduler
steps the binding, it invokes the closure with the parked resume HPointer
as the last argument. The closure performs the IO and then either
(a) calls `Scheduler::callClosure1(resume, taskSucceed*(...))` itself
(synchronous-in-binding shape), or (b) registers `resume` into the
scheduler's `pendingResumes_` registry and hands the work off to a worker
pool (async-park shape).

The helpers in `runtime/src/platform/TaskBinding.hpp` factor out the
closure-allocation, capture-rooting, and trampoline boilerplate:

```cpp
// Synchronous shape — the body does IO and returns a Task to deliver.
HPointer writeStringBody(HPointer captured) {
    Tuple2* tup = static_cast<Tuple2*>(
        Allocator::instance().resolve(captured));
    std::string path = toString(Export::encode(tup->a.p));
    std::string data = toString(Export::encode(tup->b.p));
    std::ofstream f(path);
    if (!f) return failErrno(errno, path, "open failed");
    f << data;
    return succeedUnit();
}

uint64_t writeString(uint64_t path, uint64_t content) {
    HPointer pathHP = Export::decode(path);
    HPointer contentHP = Export::decode(content);
    StackRootGuard g(&pathHP, &contentHP);
    HPointer payload = tuple2(boxed(pathHP), boxed(contentHP), 0);
    return Export::encode(makeBinding<writeStringBody>(payload));
}
```

```cpp
// Async-park shape — body registers resume + submits to a worker pool.
HPointer waitBody(HPointer captured, HPointer resume) {
    int64_t pid = asTuple2(captured)->a.i;
    auto& sched = Scheduler::instance();
    uint64_t token = sched.registerPendingResume(resume);
    sched.incrementPendingAsync();
    WaitService::instance().submit(pid, token);
    return unit();  // kill handle
}
```

## Exemptions

Listed verbatim in `KERNEL_TASK_IO_001`:

- **Pure Task constructors** — `Elm_Kernel_Scheduler_succeed/fail/andThen/
  onError/spawn/kill/taskReceive`. The caller supplies the value; no IO.
- **Terminator non-returners** — `Eco_Kernel_Process_exit`,
  `Eco_Kernel_Crash_crash`. They never return; wrapping them in a Task
  would be misleading.
- **Identity / logging non-Task helpers** — `Eco_Kernel_Console_log`. Not a
  Task producer; it returns its `value` argument unchanged.
- **MVar partial-eager fast paths** — `MVar::read/take/put` short-circuit
  synchronously when the slot state already allows immediate resolution.
  No syscall, in-process state only.

## Related

- `plans/defer-eager-kernel-tasks-via-binding.md` — the migration plan.
- `plans/time-every-via-scheduler-timerservice.md` — the TimerService
  pattern that WaitService mirrors.
- `runtime/src/platform/TaskBinding.hpp` — the shared helper.
- `eco-kernel-cpp/src/eco/TaskBinding.hpp` — Eco-side `succeed*`/`fail*`
  HPointer wrappers.
