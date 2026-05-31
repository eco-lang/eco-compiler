# Error Handling Notes

## TODO — remove silent drop of unhandled `Task.fail` in the scheduler

`runtime/src/platform/Scheduler.cpp:737-742` currently absorbs an unhandled
top-level `Task.fail` with a warning to stderr and continues:

```cpp
if (ctor == Task_Fail) {
    std::fprintf(stderr,
        "[eco-runtime] unhandled top-level Task.fail "
        "(no surrounding Task.onError) — failure value dropped\n");
    std::fflush(stderr);
}
break;
```

This is reached when `popStackMatching(Task_Fail)` walks the entire process
stack without finding a matching `Task_OnError` frame — i.e. user code spawned
a `Task x a` whose `x` was never handled. The process is killed (the
surrounding `break` exits the drain loop) but the program does not crash:
other processes can still run, and the failure value itself is dropped.

**This is the wrong default.** A `Task.fail` that reaches the top of a Process
with no `Task.onError` is an unhandled exception in Elm terms — symmetric to an
uncaught panic in any other language. The runtime should crash with a
diagnostic so the user sees it immediately, not drop it silently.

### What to change

Replace the `fprintf` + `break` with a hard crash, mirroring
`Eco.Kernel.Crash.crash` (Crash.cpp:20-33) — format the failure value via the
existing `Eco.IO.Error.toString` decoder where possible, fall through to a
generic "unhandled Task.fail" message otherwise, then `::exit(1)`.

If a single failed Process should be survivable for some use case (long-lived
daemon, REPL?), gate THAT behind an explicit opt-in (env var, runtime flag),
not the silent default.

### Notes on what already works correctly

`crashOnError` (`compiler/src/System/IO.elm:258-260`) wraps every fallible
internal IO with `Task.onError (\err -> crash ...)`, so the compiler's own
build pipeline does NOT hit this silent path — IO errors crash loudly via the
`Eco.Kernel.Crash.crash` exit. The drop path only fires for user code (or
future runtime code) that forgets the `onError` and lets the failure flow off
the top of a Process.

Related: any `Task` that uses `Task.attempt` instead of `Task.perform`
explicitly reifies failure into a `Result`, so those are fine too. This change
only affects code that uses neither.
