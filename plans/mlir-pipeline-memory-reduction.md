# MLIR Pipeline Memory Reduction

## Problem

Stage 5 of the bootstrap (MLIR self-compilation) runs out of memory. The monomorphization and codegen phases are memory-heavy, but the bigger issue is that **large data structures from earlier pipeline stages are retained in memory long after they're needed**, because JavaScript closures in `Task.andThen` chains capture values that keep entire graphs alive.

## Background: How GC Boundaries Work in This Compiler

The Eco compiler is itself Elm compiled to JavaScript, running under Node.js. The `Task.andThen` chain is executed by a kernel scheduler loop (`_Scheduler_step` in `eco-boot.js`, line 939):

```js
// line 954: when a Task succeeds, call the andThen callback with its result
proc.f = proc.g.b(proc.f.a);
proc.g = proc.g.i;  // pop callback stack
```

Each `andThen` callback runs in its own JS function scope. After the callback returns, its local variables become unreachable (eligible for GC). The previous task's result is also overwritten in `proc.f`. This means **`Task.andThen` creates real GC boundaries** — but only if closures don't inadvertently capture values from outer scopes.

Conversely, all `let`-bound variables within a single Elm function compile to `var` declarations in one JS function scope. V8's interpreter (Ignition) does **not** reclaim local variables mid-function, so they all remain live until the function returns.

### Verified: Elm compiles field access eagerly

Confirmed in `eco-boot.js` line 159296:
```js
A5($eco$compiler$Builder$Generate$generateMonoDevOutput,
    backend, withSourceMaps, leadingLines, root,
    artifacts.roots),  // <-- field access evaluated BEFORE partial application
```
So partial applications like `(f ... record.field)` capture the field **value**, not the record.

### Verified: Closure captures full parent variables

Confirmed in `eco-boot.js` line 159327–159333:
```js
function (builder) {          // <-- closure created for Task.andThen
    return A4(
        $eco$compiler$Terminal$Make$generate,
        ctx.style,            // <-- `ctx` captured (not just `.style`)
        target,
        builder,
        $eco$compiler$Builder$Build$getRootNames(artifacts));
                              // <-- `artifacts` captured whole
},
```
Field accesses on `ctx` and `artifacts` inside the closure body means the entire objects are captured.

## Decision Log

| Question | Decision |
|----------|----------|
| Skip Fix 3 (globalOptimize → Task)? | **Yes**, skip for now. Measure impact of Fixes 1-2 first. |
| Fix `handleJsOutput` too? | **Yes**, same pattern, same fix for consistency. |
| Fix `handleHtmlOutput`? | **No** — verified it doesn't have the retention problem (its `generateHtml` closure doesn't capture `artifacts`). |
| Measure peak memory? | **Yes** — use `/usr/bin/time -v` for peak RSS. |
| Inject `global.gc()` at Task boundaries? | **Yes** — patch `_Scheduler_step` in compiled JS for diagnostic runs. |
| Verify eager field access in compiled JS? | **Done** — confirmed above. |

## Fixes

### Fix 1 (CRITICAL): Stop retaining `artifacts` across the MLIR pipeline

**File:** `compiler/src/Terminal/Make.elm`
**Function:** `handleMlirOutput` (line 268)

**Current code:**
```elm
handleMlirOutput ctx target artifacts =
    case getNoMains artifacts of
        [] ->
            toMonoBuilder Generate.mlirBackend ctx.withSourceMaps 0
                ctx.root ctx.maybeBuildDir ctx.localPackage
                ctx.details ctx.desiredMode artifacts
                |> Task.andThen
                    (\builder -> generate ctx.style target builder
                        (Build.getRootNames artifacts))
                    --  captures `artifacts` (entire Build.Artifacts) AND `ctx` (with Details)
```

**What stays alive because of this closure:**
- Every module's `I.Interface` (type signatures, unions, aliases, binops)
- Every module's `Opt.LocalGraph` (untyped optimization graph — **never used in MLIR path**)
- Every module's `Maybe TOpt.LocalGraph` (already consumed by `loadTypedObjects`)
- Every module's `Maybe TypeEnv.ModuleTypeEnv` (already consumed)
- `Dependencies` — `Dict Canonical DependencyInterface` for all packages
- `Root` values — with their own `Opt.LocalGraph` and `TOpt.LocalGraph` copies
- `Details` (via `ctx`) — locals, foreigns, deps, extras

All of this stays alive throughout monomorphization, globalOpt, and MLIR codegen — just to extract `rootNames` (a small `NE.Nonempty Name`) and `style` (a small enum) at the very end.

**Fix:** Extract `rootNames` and `style` eagerly before entering the pipeline:

```elm
handleMlirOutput ctx target artifacts =
    case getNoMains artifacts of
        [] ->
            let
                rootNames =
                    Build.getRootNames artifacts

                style =
                    ctx.style
            in
            toMonoBuilder Generate.mlirBackend ctx.withSourceMaps 0
                ctx.root ctx.maybeBuildDir ctx.localPackage
                ctx.details ctx.desiredMode artifacts
                |> Task.andThen (\builder -> generate style target builder rootNames)

        name :: names ->
            Task.throw (Exit.MakeNonMainFilesIntoJavaScript name names)
```

Now the closure captures only `style`, `target`, `rootNames`. After `toMonoBuilder` consumes `artifacts` and returns a Task, `artifacts` and `ctx` are out of scope.

**Also apply to `handleJsOutput`** (line 240) — identical pattern, identical fix:

```elm
handleJsOutput ctx target artifacts =
    case getNoMains artifacts of
        [] ->
            let
                rootNames =
                    Build.getRootNames artifacts

                style =
                    ctx.style
            in
            toBuilder Generate.javascriptBackend ctx.withSourceMaps 0
                ctx.root ctx.maybeBuildDir ctx.details ctx.desiredMode artifacts
                |> Task.andThen (\builder -> generate style target builder rootNames)

        name :: names ->
            Task.throw (Exit.MakeNonMainFilesIntoJavaScript name names)
```

**Not applied to `handleHtmlOutput`** — verified that `buildAndGenerateHtml`'s inner closure `(generateHtml ctx.style target name)` does not capture `artifacts`.

### Fix 2 (HIGH): Break `generateMonoDevOutput` into Task.andThen stages

**File:** `compiler/src/Builder/Generate.elm`
**Function:** `generateMonoDevOutput` (line 592)

**Current code:**
```elm
generateMonoDevOutput backend withSourceMaps leadingLines root roots objects =
    let
        mode = Mode.Dev Nothing
        baseGraph = typedObjectsToGlobalGraph objects
        baseTypeEnv = typedObjectsToGlobalTypeEnv objects
        typedGraph = List.foldl addRootTypedGraph baseGraph (NE.toList roots)
        globalTypeEnv = List.foldl addRootTypeEnv baseTypeEnv (NE.toList roots)
    in
    case Monomorphize.monomorphize "main" globalTypeEnv typedGraph of
        Err err ->
            Task.throw (Exit.GenerateMonomorphizationError err)
        Ok monoGraph0 ->
            let
                monoGraph = MonoGlobalOptimize.globalOptimize globalTypeEnv monoGraph0
            in
            prepareSourceMaps withSourceMaps root
                |> Task.map (generateMonoOutput backend leadingLines mode monoGraph globalTypeEnv)
```

**Problem:** Single synchronous function. V8 Ignition keeps all `var`s alive for the full function:
- `objects` (TypedObjects) alive during monomorphize and globalOptimize
- `baseGraph`, `baseTypeEnv` alive during monomorphize and globalOptimize
- `typedGraph` alive during globalOptimize (no longer needed)
- `monoGraph0` alive during codegen (no longer needed)

**Fix:** Split into Task.andThen stages:

```elm
generateMonoDevOutput backend withSourceMaps leadingLines root roots objects =
    let
        typedGraph =
            List.foldl addRootTypedGraph (typedObjectsToGlobalGraph objects) (NE.toList roots)

        globalTypeEnv =
            List.foldl addRootTypeEnv (typedObjectsToGlobalTypeEnv objects) (NE.toList roots)
    in
    -- After this function returns: `objects`, `roots`, intermediate merge results → out of scope
    Task.succeed ( typedGraph, globalTypeEnv )
        |> Task.andThen
            (\( tGraph, typeEnv ) ->
                -- Only typedGraph + typeEnv are alive. `objects` is gone.
                case Monomorphize.monomorphize "main" typeEnv tGraph of
                    Err err ->
                        Task.throw (Exit.GenerateMonomorphizationError err)

                    Ok monoGraph0 ->
                        -- After return: `tGraph` (typedGraph) → out of scope
                        Task.succeed ( monoGraph0, typeEnv )
            )
        |> Task.andThen
            (\( monoGraph0, typeEnv ) ->
                -- Only monoGraph0 + typeEnv are alive. typedGraph is gone.
                let
                    monoGraph =
                        MonoGlobalOptimize.globalOptimize typeEnv monoGraph0
                in
                -- After return: `monoGraph0` → out of scope
                prepareSourceMaps withSourceMaps root
                    |> Task.map
                        (generateMonoOutput backend leadingLines (Mode.Dev Nothing) monoGraph typeEnv)
            )
```

**GC boundary timeline:**

| Point | What becomes GC-eligible |
|-------|--------------------------|
| After outer function returns | `objects` (TypedObjects), `roots`, intermediate `baseGraph`/`baseTypeEnv` |
| After Stage B callback returns | `typedGraph` (TOpt.GlobalGraph — entire typed AST for all modules) |
| After Stage C callback returns | `monoGraph0` (pre-optimization MonoGraph) |

## Implementation Steps

### Step 0: Measure baseline peak memory

```bash
cd /work/compiler/build-kernel
/usr/bin/time -v node --max-old-space-size=16384 bin/eco-boot-2-runner.js make \
    --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/eco-compiler.mlir \
    /work/compiler/src/Terminal/Main.elm 2>&1 | grep "Maximum resident"
```

Record the "Maximum resident set size (kbytes)" as the baseline.

### Step 1: Fix 1 — Eager extraction in `handleMlirOutput` and `handleJsOutput`

1. Edit `handleMlirOutput` in `compiler/src/Terminal/Make.elm` (line 268): extract `rootNames` and `style` into a `let` before the pipeline, remove `artifacts` and `ctx` references from the `andThen` closure.
2. Edit `handleJsOutput` in `compiler/src/Terminal/Make.elm` (line 240): same change.
3. `handleHtmlOutput` — no change needed (verified no retention issue).

### Step 2: Fix 2 — Break `generateMonoDevOutput` into Task stages

1. Edit `generateMonoDevOutput` in `compiler/src/Builder/Generate.elm` (line 592): restructure into three `Task.andThen` stages as shown above.
2. Verify that `Task.succeed` and `Task.andThen` are already imported (they should be — the function already uses `Task.throw` and `Task.map`).
3. The function's return type does not change (`Task Exit.Generate CodeGen.Output`) so no call-site changes needed.

### Step 3: Rebuild and verify correctness

1. Run bootstrap stages 1–4:
   ```bash
   export NODE_OPTIONS="--max-old-space-size=16384"
   cd /work/compiler
   ./scripts/build.sh bin           # Stage 1
   ./scripts/build-self.sh bin      # Stage 2
   ./scripts/build-verify.sh        # Stages 3+4 (fixed-point check)
   ```
   The fixed-point check is the ultimate correctness guarantee — if stages 3 and 4 produce identical output, the compiler's behavior is unchanged.

2. Run Elm frontend tests:
   ```bash
   cd /work/compiler
   npx elm-test-rs --project build-xhr --fuzz 1
   ```

3. Run E2E backend tests:
   ```bash
   cmake --build build --target check
   ```

### Step 4: Measure improvement

```bash
cd /work/compiler/build-kernel
/usr/bin/time -v node --max-old-space-size=16384 bin/eco-boot-2-runner.js make \
    --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/eco-compiler.mlir \
    /work/compiler/src/Terminal/Main.elm 2>&1 | grep "Maximum resident"
```

Compare with baseline from Step 0.

### Step 5: Diagnostic GC forcing (if Step 4 shows less improvement than expected)

Patch `_Scheduler_step` in the compiled `eco-boot-2.js` (line 954) to force GC after each `andThen` callback:

```js
// Original line 954:
proc.f = proc.g.b(proc.f.a);

// Patched:
proc.f = proc.g.b(proc.f.a);
if (typeof global.gc === 'function') { global.gc(); }
```

Then run with `--expose-gc`:
```bash
/usr/bin/time -v node --expose-gc --max-old-space-size=16384 bin/eco-boot-2-runner.js make \
    --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/eco-compiler.mlir \
    /work/compiler/src/Terminal/Main.elm 2>&1 | grep "Maximum resident"
```

This shows the **theoretical minimum** peak memory — the best we can achieve given the current data structures, if V8 GC'd perfectly at every boundary. The gap between this and Step 4 tells us how much V8's lazy GC is costing us, and whether Fix 3 (globalOptimize Task stages) or further changes would help.

**Note:** This will be extremely slow (GC after every single Task step). Only for diagnostic purposes.

## Assumptions

1. The bootstrap stages 1-4 produce a fixed-point compiler that we can use for Stage 5 testing. If bootstrap is currently broken for unrelated reasons, we'll need to fix that first.
2. `Task.succeed` followed immediately by `Task.andThen` in the kernel scheduler loop (line 954) does create a JS function scope boundary. Verified by reading the scheduler: `proc.f = proc.g.b(proc.f.a)` calls the callback in a new frame.
3. V8 will actually reclaim dead objects at the scope boundaries during the heavy allocation phases (monomorphize/globalOpt). If V8 defers GC too aggressively, the `global.gc()` diagnostic step (Step 5) will reveal this.
