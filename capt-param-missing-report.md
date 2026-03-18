# Bug Report: Captured Function Parameters Missing from `varSourceArity` in `annotateExprCalls`

## Summary

When a closure captures a function parameter from an enclosing scope and applies it to more arguments than its first-stage arity, the compiler drops arguments silently and generates type-mismatched MLIR. This bug blocks bootstrap Stage 6 (MLIR → native ELF).

## Failing Tests

| Test | Failure Mode |
|------|-------------|
| `DictMapStagedCaptureTest.elm` | MLIR parse error: `i64` vs `!eco.value` type mismatch — **identical to bootstrap Stage 6 failure** |
| `CapturedStagedFuncCallTest.elm` | Wrong runtime result: `129` instead of `15` — dropped argument causes garbage value |

### Bootstrap Stage 6 Error

```
loc("compiler/build-kernel/bin/eco-compiler.mlir":572105:41):
  error: use of value '%8' expects different type than prior uses: 'i64' vs '!eco.value'
Error: Failed to parse MLIR file
```

### Test MLIR Error (identical pattern)

```
loc("eco_runner_input":349:43):
  error: use of value '%86' expects different type than prior uses: 'i64' vs '!eco.value'
FAILED: JIT execution failed: Failed to parse or verify MLIR source
```

## Elm Source That Triggers the Bug

The pattern originates in `Data.Map.map` (`compiler/src/Data/Map.elm:255-257`):

```elm
map : (k -> a -> b) -> Dict c k a -> Dict c k b
map alter (D dict) =
    D (Dict.map (\_ ( key, value ) -> ( key, alter key value )) dict)
```

The lambda `\_ ( key, value ) -> ( key, alter key value )` captures `alter` from the enclosing scope and applies it to two arguments (`key` and `value`).

### Minimal Reproduction (`DictMapStagedCaptureTest.elm`)

```elm
makeAdder : String -> (Int -> Int)
makeAdder key =
    \value -> String.length key + value

mapTupleDict : (String -> Int -> Int) -> Dict.Dict String ( String, Int ) -> Dict.Dict String ( String, Int )
mapTupleDict alter dict =
    Dict.map (\_ ( key, value ) -> ( key, alter key value )) dict
```

## Generated MLIR (Buggy)

### Bootstrap (`Terminal_Main_lambda_16426$cap`)

```mlir
^bb0(%alter: !eco.value, %_v1: !eco.value, %_v2: !eco.value):
    %5 = "eco.project.tuple2"(%_v2) {field = 0} : (!eco.value) -> !eco.value       -- key
    %7 = "eco.project.tuple2"(%_v2) {field = 1} : (!eco.value) -> !eco.value       -- value (UNUSED!)
    %8 = "eco.papExtend"(%alter, %5) {remaining_arity = 1} : (!eco.value, !eco.value) -> !eco.value
    %9 = "eco.construct.tuple2"(%5, %8) {unboxed_bitmap = 2} : (!eco.value, i64) -> !eco.value
    "eco.return"(%9) : (!eco.value) -> ()
```

### Test (`DictMapStagedCaptureTest_lambda_3$cap`)

```mlir
^bb0(%alter: !eco.value, %_v0: !eco.value, %_v1: !eco.value):
    %83 = "eco.project.tuple2"(%_v1) {field = 0} : (!eco.value) -> !eco.value      -- key
    %85 = "eco.project.tuple2"(%_v1) {field = 1} : (!eco.value) -> i64             -- value (UNUSED!)
    %86 = "eco.papExtend"(%alter, %83) {remaining_arity = 1} : (!eco.value, !eco.value) -> !eco.value
    %87 = "eco.construct.tuple2"(%83, %86) {unboxed_bitmap = 2} : (!eco.value, i64) -> !eco.value
    "eco.return"(%87) : (!eco.value) -> ()
```

### What Correct MLIR Should Look Like

```mlir
^bb0(%alter: !eco.value, %_v0: !eco.value, %_v1: !eco.value):
    %83 = "eco.project.tuple2"(%_v1) {field = 0} : (!eco.value) -> !eco.value      -- key
    %85 = "eco.project.tuple2"(%_v1) {field = 1} : (!eco.value) -> i64             -- value
    %86 = "eco.papExtend"(%alter, %83) {remaining_arity = 1} : (!eco.value, !eco.value) -> !eco.value
    %87 = "eco.papExtend"(%86, %85) {remaining_arity = 1} : (!eco.value, i64) -> i64   -- fully applied
    %88 = "eco.construct.tuple2"(%83, %87) {unboxed_bitmap = 2} : (!eco.value, i64) -> !eco.value
    "eco.return"(%88) : (!eco.value) -> ()
```

Two bugs are visible:
1. `alter key value` compiled as only `papExtend(alter, key)` — `value` is dropped
2. `construct.tuple2` declares `(!eco.value, i64)` but receives `(!eco.value, !eco.value)` — type mismatch

## Root Cause

**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`
**Function:** `annotateExprCalls` (line ~1182)

When processing a `MonoClosure`, the code adds **captured variable** arities to `envWithCaptures` but **never adds closure parameters**:

```elm
Mono.MonoClosure info body closureType ->
    let
        newCaptures = ...

        -- BUG: only captures are added, NOT the closure's own parameters
        envWithCaptures =
            List.foldl
                (\( name, captureExpr, _ ) envAcc ->
                    case sourceArityForExpr graph envAcc captureExpr of
                        Just arity ->
                            { envAcc
                                | varSourceArity =
                                    Dict.insert name arity envAcc.varSourceArity
                            }
                        Nothing ->
                            envAcc
                )
                env
                newCaptures

        newBody =
            annotateExprCalls graph envWithCaptures body  -- params NOT in env
```

## Full Trace

### Step 1 — Outer Closure Processing

`mapTupleDict` (or `Data.Map.map`) is compiled. Its closure has parameter `alter : k -> v -> w`. The `annotateExprCalls` function processes this outer `MonoClosure` but does **not** add `alter` to `env.varSourceArity`.

### Step 2 — Inner Lambda Capture Processing

The inner lambda `\_ (key, value) -> (key, alter key value)` captures `alter`. When building `envWithCaptures` for this inner closure, `sourceArityForExpr` is called on the capture expression `MonoVarLocal "alter"`:

```elm
Mono.MonoVarLocal name _ ->
    Dict.get name env.varSourceArity    -- Returns Nothing! (alter not in env)
```

Since `alter` (an outer parameter) isn't in the env, this returns `Nothing`. So `alter` is **not** added to the inner closure's `envWithCaptures`.

### Step 3 — Call Annotation Falls Back to Type-Based Arity

Inside the inner lambda body, `alter key value` is a `MonoCall` with 2 args. `computeCallInfo` calls `sourceArityForCallee`:

```elm
sourceArityForCallee graph env funcExpr =
    case sourceArityForExpr graph env funcExpr of
        Just arity -> arity
        Nothing ->
            -- FALLBACK: first-stage arity only
            firstStageArityFromType (Mono.typeOf funcExpr)
```

Again, `alter` not in env → falls back to `firstStageArityFromType`.

### Step 4 — First-Stage Arity Is Wrong for Staged Functions

After GlobalOpt Phase 2 (staging analysis), `alter`'s type is `MFunction [k] (MFunction [v] w)` — staged because `makeAdder` has 1 param and returns a closure. `firstStageArityFromType` returns **1** (first `MFunction`'s arg count):

```elm
firstStageArityFromType monoType =
    case monoType of
        Mono.MFunction argTypes _ ->
            List.length argTypes    -- Returns 1 for MFunction [k] (MFunction [v] w)
        _ ->
            0
```

### Step 5 — `computeCallInfo` Gets Wrong Arity

`computeCallInfo` sets:
- `initialRemaining = 1` (source arity from fallback)
- `remainingStageArities = []` (unknown callee → empty list)

### Step 6 — `applyByStages` Drops the Second Argument

`applyByStages` in codegen (`Expr.elm:1253`) processes 2 args with `sourceRemaining = 1`:

**Iteration 1:** `batchSize = min(1, 2) = 1`. Applies `key` via `papExtend(alter, key)`.
`rawResultRemaining = 1 - 1 = 0`. Since `remainingStageArities = []`, `resultRemaining = 0`.

**Iteration 2:** 1 arg remaining (`value`), but `sourceRemaining = 0`:

```elm
if sourceRemaining <= 0 then
    -- Defensive: zero-arity stage shouldn't happen with remaining args
    -- Return current value (treat as fully applied)
    { ops = List.reverse accOps, resultVar = funcVar, ... }
```

**`value` is silently dropped.**

### Step 7 — Type Mismatch in Tuple Construction

The result of `papExtend(alter, key)` has MLIR type `!eco.value` (a PAP/closure). But `construct.tuple2` uses `unboxed_bitmap = 2` (computed from MonoType which says the second field is `Int`), declaring the operand type as `i64`. This creates:

```
use of value '%86' expects different type than prior uses: 'i64' vs '!eco.value'
```

## Impact

This bug affects any code where:
1. A closure captures a function parameter from an enclosing scope
2. The captured function has a **staged type** (returns a function)
3. The closure applies the captured function to more args than the first-stage arity

The bug causes:
- **MLIR parse errors** when the result is stored in a context expecting an unboxable type (e.g. tuple with `unboxed_bitmap`)
- **Silent wrong results** when the result stays boxed (garbage memory is interpreted as the dropped argument's value)
- **Runtime assertion failures** (`eco_closure_call_saturated: argument count mismatch`) when the incomplete PAP is later called

### Scope

- Blocks bootstrap Stage 6 (native ELF compilation)
- Many of the 48 pre-existing E2E test failures (SIGABRT crashes) likely stem from the same root cause
- The `CapturedStagedFuncCallTest` demonstrates silent data corruption (returns `129` instead of `15`)

## Files Involved

| File | Role |
|------|------|
| `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm` | **Primary bug location** — `annotateExprCalls` MonoClosure case (line ~1182) |
| `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm` | `computeCallInfo` (line ~1755) — sets wrong `initialRemaining` due to fallback |
| `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm` | `sourceArityForExpr` (line ~1410) — `MonoVarLocal` lookup fails |
| `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm` | `firstStageArityFromType` (line ~1571) — returns first-stage arity only |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | `applyByStages` (line ~1253) — drops args when `sourceRemaining <= 0` |
| `compiler/src/Data/Map.elm` | `map` (line 255) — Elm source that triggers the bug pattern |
