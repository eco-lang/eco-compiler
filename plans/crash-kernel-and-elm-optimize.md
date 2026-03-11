# Plan: Move Utils.Crash to Eco.Crash Kernel + elm-optimize-level-2

## Goal
1. Remove `Debug.todo` from `Utils.Crash` so the compiler can be built with `--optimize`
2. Implement `Eco.Crash.crash` in both the XHR and kernel API paths
3. Add `Crash.crash` handler to `eco-io-handler.js`
4. Implement JS and C++ kernel crash functions (C++ already exists as `eco_crash`)
5. Investigate `elm-optimize-level-2` for the XHR bootstrap build

## Background

`Utils.Crash.crash : String -> a` uses `Debug.todo` which blocks `--optimize` compilation.
The polymorphic return type `a` means crash can't be a `Task` — it must be a synchronous,
never-returning function. Elm's self-recursion (`crash str = crash str`) compiles to a
tail-call-optimized `while(true)` loop, which satisfies the type checker and `--optimize`.

The C++ runtime already has `eco_crash` at `runtime/src/allocator/RuntimeExports.cpp:643`.

## Changes

### 1. Create `compiler/src-xhr/Eco/Crash.elm` (XHR variant)

```elm
module Eco.Crash exposing (crash)

crash : String -> a
crash str =
    crash str
```

Self-recursive — compiles to a `while(true)` loop. The `replacements.js` post-processing
step patches the compiled JS to print a stack trace and exit instead of looping.

### 2. Create `eco-kernel-cpp/src/Eco/Crash.elm` (kernel variant)

```elm
module Eco.Crash exposing (crash)

import Eco.Kernel.Crash

crash : String -> a
crash str =
    Eco.Kernel.Crash.crash str
```

Delegates to kernel JS implementation.

### 3. Create `eco-kernel-cpp/src/Eco/Kernel/Crash.js`

```javascript
/**/

var _Crash_crash = function(str) {
    Error.stackTraceLimit = Infinity;
    try {
        throw new Error(str);
    } catch(e) {
        console.error(e.stack);
    }
    typeof process !== "undefined" && process.exit(1);
};
```

The kernel JS directly crashes with a stack trace — no Scheduler involvement since
crash is synchronous and never returns (it exits the process).

### 4. Update `compiler/src/Utils/Crash.elm`

```elm
module Utils.Crash exposing (crash)

import Eco.Crash

crash : String -> a
crash str =
    Eco.Crash.crash str
```

Remove `Debug.todo`, delegate to `Eco.Crash.crash`. Both XHR and kernel builds will
resolve `Eco.Crash` from their respective source directories.

### 5. Update `eco-kernel-cpp/elm.json`

Add `"Eco.Crash"` to the `exposed-modules` list.

### 6. Add `Crash.crash` handler to `compiler/bin/eco-io-handler.js`

```javascript
case "Crash.crash": {
    Error.stackTraceLimit = Infinity;
    console.error(new Error(args.message).stack);
    process.exit(1);
    break;
}
```

Added for protocol completeness, even though the XHR Elm code doesn't call it
as a Task (the crash is intercepted at the JS level by replacements.js).

### 7. Update `compiler/scripts/replacements.js`

Change the crash replacement pattern:
- **Old pattern**: matches `$author$project$Utils$Crash$crash` (self-recursive while loop)
- **New pattern**: matches `$author$project$Eco$Crash$crash` (self-recursive while loop)

The compiled JS for the XHR build will have `Eco.Crash.crash` as the self-recursive
function (Utils.Crash.crash just calls it). The replacement patches the inner function.

The replacement implementation stays the same: throw Error with stack trace, exit(1).

### 8. elm-optimize-level-2 Investigation

**Findings:**
- Available via npx (`elm-optimize-level-2@0.3.5`)
- Compiles Elm source files with its own `elm make` + additional JS transforms
- Uses `--optimize` internally, so removing Debug.todo is a prerequisite
- Only applicable to Stage 1 (XHR build) since Stages 2+ use the eco compiler
- Transforms include: more aggressive inlining, object shape optimization, record access optimization

**Recommendation:** Defer elm-optimize-level-2 integration to a follow-up task. Reason:
- It re-runs `elm make` internally, so it would replace our Stage 1 elm make call
- The JS transforms may break the string patterns that `replacements.js` matches
- Needs careful testing to ensure the transformed output works with the mock XHR setup
- The primary goal (removing Debug.todo) unlocks `--optimize` which is the bigger win

We note this as a future optimization opportunity in the plan file, but don't implement it now.

## Files Modified

| File | Action |
|------|--------|
| `compiler/src-xhr/Eco/Crash.elm` | **Create** — XHR crash module |
| `eco-kernel-cpp/src/Eco/Crash.elm` | **Create** — kernel crash module |
| `eco-kernel-cpp/src/Eco/Kernel/Crash.js` | **Create** — kernel JS implementation |
| `compiler/src/Utils/Crash.elm` | **Edit** — delegate to Eco.Crash, remove Debug.todo |
| `eco-kernel-cpp/elm.json` | **Edit** — expose Eco.Crash |
| `compiler/bin/eco-io-handler.js` | **Edit** — add Crash.crash handler |
| `compiler/scripts/replacements.js` | **Edit** — update crash pattern match |

## Testing

1. `cd compiler && npx elm-test-rs --project build-xhr --fuzz 1` — front-end tests
2. `cmake --build build --target full` — full E2E rebuild + tests
3. Verify the bootstrap produces identical output (eco-boot-2 == eco-boot-3 fixed-point)
