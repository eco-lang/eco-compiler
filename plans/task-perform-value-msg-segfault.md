# `Platform.worker` SIGSEGVs when the model type is UNBOXED — FIXED

**Status: FIXED 2026-08-25** (`runtime/src/platform/PlatformRuntime.cpp`,
`initWorker` + the update path). Regression tests:
`test/elm/src/TaskPerformValueTest.elm`, `TaskAttemptErrorTest.elm`.

## The bug

`Platform.worker` crashed for any program whose **model type is an unboxed
primitive** (`Int`, `Float`, `Char`). `init _ = ( 0, … )` was enough.

```
Thread 2 received signal SIGSEGV
#0  Elm::Allocator::resolve (ptr=...)                Allocator.cpp:883
#1  hpointerToPtr (val=0)                            RuntimeExports.cpp:62
#2  spliceArgsForSaturatedCall                       RuntimeExports.cpp:2453
#4  eco_apply_closure_eval                           RuntimeExports.cpp:2105
#7  Elm::Platform::Scheduler::callClosure1           Scheduler.cpp:174
#8  Elm::Platform::PlatformRuntime::initWorker       PlatformRuntime.cpp:843
```

## Root cause

`initWorker` extracted the model from `init`'s `( model, cmd )` tuple by
reading the slot **as a pointer**:

```cpp
Tuple2* initTuple = static_cast<Tuple2*>(pairPtr);
HPointer model = initTuple->a.p;      // <-- unconditional .p
HPointer cmd0  = initTuple->b.p;
```

A `Tuple2` carries its own slot kinds in `header.unboxed` — 2 bits per slot,
`00` boxed HPointer, `01` Int, `10` Float, `11` Char — and for
`( Int, Cmd msg )` slot a is a raw `i64`. Reading `.p` reinterprets that
scalar as a pointer. Confirmed under gdb at `PlatformRuntime.cpp:814` with
`init _ = ( 1, … )`:

```
model = {constant = 0x1, ptr_ind = 0x0, ptr = 0x0}
```

— the raw `1`, with `ptr_ind` clear, so it is not even a valid embedded
constant (HEAP_010). It then went two places, both wrong:

1. `modelStorage_ = encodeHP(model)` followed by
   `eco_gc_add_value_root(&modelStorage_)` — **a direct HEAP_035 violation**:
   "a slot holding a raw scalar (i64 Int / f64 / i16 Char) must NEVER enter
   the root set".
2. `callClosure1(subscriptionsFn, currentModel)` → `spliceArgsForSaturatedCall`
   → `Allocator::resolve(0x1)` → SIGSEGV, at the first use.

The identical defect was present in the update path (`tuple->a.p` at what was
line 691), so a program surviving init would have crashed on its first
message instead.

## Why it hid for so long

Every existing worker fixture used a model that really is a pointer or a
tagged constant:

| fixture | model | why it survived |
|---|---|---|
| `TimerEffectTest` | `{ count : Int }` | record ⇒ real pointer |
| `MVarSharedNewTaskTest` | `Maybe Bool` | `Nothing` ⇒ embedded constant, `ptr_ind` set |
| the new fixtures | `Int` | raw scalar ⇒ **crash** |

**A CORRECTION TO THIS FILE'S FIRST VERSION.** The original bisect concluded
"`Task.perform` crashes when the produced Msg CARRIES the task's value",
because the one passing case used `\_ -> TimerFired`. That was wrong: the
passing case ALSO happened to use a record model (`{ count = 0 }`) while every
failing case used a bare `Int` model. Two variables moved at once and the
conclusion was attached to the wrong one. `Task.perform` was never implicated
— nor were the LSS_022 `Scheduler` licences, nor lambda sets at all (it
reproduced under `ECO_MONO_LSS=0`). The lesson is the ordinary one: change one
thing per bisect step, and prefer a debugger over inference once a crash is in
hand — the gdb frame named the real cause in one shot.

## The fix

Both sites now consult the tuple's own slot kinds and box through the existing
`Elm::alloc::boxElement(Unboxable, kind)` helper. The platform boundary is
all-boxed in both directions — `callClosure1/2` hand the model back to Elm
through the all-boxed arg layout, and HEAP_035 requires the rooted slot to be
boxed — so boxing here is the contract, not a workaround.

`boxElement` allocates for an unboxed kind and can therefore move the tuple,
so each site re-resolves the pair before reading slot b.

## Coverage added

- `TaskPerformValueTest` — `Task.perform` delivering an `Int`, a negative
  `Int`, a `String`, and (as a control that would have caught the mis-bisect)
  a nullary Msg, all with an `Int` model.
- `TaskAttemptErrorTest` — `Task.attempt` on both outcomes, which also pins
  `Scheduler.onError`'s success and failure edges.
- `KernelLicenseTaskTest` — the LSS_022 `Scheduler` licence fixture, which
  originally tripped over this defect and is now landed.
