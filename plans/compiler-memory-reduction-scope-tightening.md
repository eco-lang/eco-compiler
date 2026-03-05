# Compiler Memory Reduction: Scope Tightening

## Summary

Remove the unused `GlobalTypeEnv` parameter from the post-monomorphization pipeline (GlobalOpt, MLIR backend) and tighten scopes in `Generate.generateMonoDevOutput` so large intermediate data structures become GC-eligible earlier.

## Investigation Findings

### Current State

The `generateMonoDevOutput` function (`compiler/src/Builder/Generate.elm:592`) already uses a `Task.andThen` chain with comments marking "GC boundary" points. This is a good start, but there's a significant remaining issue: **`GlobalTypeEnv` is threaded through the entire post-monomorphization pipeline despite never being used.**

Evidence:

| Call site | Accepts `typeEnv`? | Uses it? |
|---|---|---|
| `Monomorphize.monomorphize` (line 61) | Yes | **Yes** — stored in MonoState, used for union lookups |
| `MonoGlobalOptimize.globalOptimize` (line 97) | Yes | **No** — passes to children that also ignore it |
| `MonoInlineSimplify.optimize` (line 51–52) | Yes | **No** — binds to `_` |
| `Staging.analyzeAndSolveStaging` (line 60–64) | Yes | **No** — binds to `_` |
| `MLIR.Backend.generateMlirModule` (line 48–49) | Yes | **No** — binds to `_` |
| `MLIR.Backend.generateProgram` (line 113–115) | Yes | **No** — passes through to generateMlirModule |
| `CodeGen.MonoCodeGenConfig.typeEnv` (line 148) | Required field | **Never read** |

### What `GlobalTypeEnv` Contains

`TypeEnv.GlobalTypeEnv` = `Dict (List String) IO.Canonical ModuleTypeEnv`, where each `ModuleTypeEnv` contains:
- `home : IO.Canonical`
- `unions : Dict String Name Can.Union`
- `aliases : Dict String Name Can.Alias`

For a full Elm program, this includes the union/alias definitions for every module (including all elm-core packages). This is a substantial data structure.

### Why It's Currently Retained

In `generateMonoDevOutput` (line 592), the second `Task.andThen` callback (line 617) receives `typeEnv` as part of its parameter tuple and passes it to `generateMonoOutput`, which packs it into `MonoCodeGenConfig.typeEnv`. This keeps the entire `GlobalTypeEnv` alive through the MLIR generation phase — even though every function that receives it ignores it.

### Proposals 1 & 2: Already Effectively Implemented

The current `Task.andThen` chain in `generateMonoDevOutput` already creates scope boundaries:
- `objects` is not captured by either `andThen` callback (V8 and other JS engines will only retain variables actually referenced in closures)
- `typedGraph` flows into the first callback's parameter, is consumed by `Monomorphize.monomorphize`, and is not passed to the second callback

These scope boundaries are sufficient for modern JS engines. Extracting separate helper functions would make the intent more explicit but would not change observable behavior — the compiler already relies on task-chaining for this separation.

### Proposal 3: Actionable and Impactful

Removing the unused `GlobalTypeEnv` parameter from the post-monomorphization pipeline is the only change that has a concrete, guaranteed impact. Currently `typeEnv` is explicitly threaded through the Task chain and packed into records, so the JS GC **cannot** collect it regardless of closure analysis. Removing it allows collection right after monomorphization.

## Plan

### Step 1: Remove `typeEnv` from `MonoCodeGenConfig`

**File:** `compiler/src/Compiler/Generate/CodeGen.elm`

Remove the `typeEnv` field from `MonoCodeGenConfig`:

```elm
type alias MonoCodeGenConfig =
    { sourceMaps : SourceMaps
    , leadingLines : Int
    , mode : Mode.Mode
    , graph : Mono.MonoGraph
    }
```

Remove the `TypeEnv` import if no longer needed.

### Step 2: Remove `typeEnv` from MLIR Backend

**File:** `compiler/src/Compiler/Generate/MLIR/Backend.elm`

- `generateMlirModule`: Change signature from `Mode.Mode -> TypeEnv.GlobalTypeEnv -> Mono.MonoGraph -> MlirModule` to `Mode.Mode -> Mono.MonoGraph -> MlirModule`
- `generateProgram`: Same removal
- `backend.generate`: Stop extracting `config.typeEnv`
- Remove `TypeEnv` import

### Step 3: Remove `typeEnv` from GlobalOpt entry point

**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

- `globalOptimize`: Change from `TypeEnv.GlobalTypeEnv -> Mono.MonoGraph -> Mono.MonoGraph` to `Mono.MonoGraph -> Mono.MonoGraph`
- Remove `typeEnv` from calls to `MonoInlineSimplify.optimize` and `Staging.analyzeAndSolveStaging`
- Remove `TypeEnv` import

### Step 4: Remove `typeEnv` from MonoInlineSimplify and Staging

**Files:**
- `compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm`: Remove `typeEnv` parameter from `optimize` signature
- `compiler/src/Compiler/GlobalOpt/Staging.elm`: Remove `typeEnv` parameter from `analyzeAndSolveStaging` signature
- Remove `TypeEnv` imports from both files

### Step 5: Update Generate.elm orchestration

**File:** `compiler/src/Builder/Generate.elm`

In `generateMonoDevOutput` (line 592):
- The first `andThen` callback currently returns `( monoGraph0, typeEnv )` — change to just `monoGraph0`
- The second `andThen` callback: call `globalOptimize` without `typeEnv`, call `generateMonoOutput` without `typeEnv`
- `generateMonoOutput`: Remove `typeEnv` parameter, don't pack it into the config record

### Step 6: Update test helpers

**Files:**
- `compiler/tests/TestLogic/TestPipeline.elm`: Update `runMLIRGeneration` to not pass `typeEnv` to config or `generateMlirModule`. Update `runGlobalOptimize` pipeline step.
- `compiler/tests/TestLogic/GlobalOpt/MonoInlineSimplifyTest.elm`: Update calls to `MonoInlineSimplify.optimize` (3 call sites at lines 214, 238, 269)
- Any other test files that construct `MonoCodeGenConfig` or call updated functions

## Scope

This plan covers **Proposal 3** only, as Proposals 1 and 2 are already effectively implemented via the existing `Task.andThen` scoping pattern.

## Risk Assessment

**Low risk.** Every removed parameter is currently bound to `_` (unused). The change is mechanical: remove parameter, update callers. No behavioral change. All existing tests should pass with trivial call-site updates.

## Questions

1. **Should we also remove the `TypeEnv` import from `MonoGlobalOptimize.elm` and `Staging.elm` if they become fully unused?** (Yes, this is standard cleanup.)
2. **`generateMlirModule` is exported and used directly by `TestPipeline.elm` — should its signature change be considered a breaking API change?** (No, it's internal to the project, and the test will be updated in the same change.)
