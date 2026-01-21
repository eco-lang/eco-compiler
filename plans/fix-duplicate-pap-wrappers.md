# Fix Duplicate PAP Wrapper Functions

## Problem Statement

The MLIR backend generates duplicate `*_pap_wrapper` function definitions when the same specialized function is referenced multiple times in a module. This causes MLIR parse errors like:

```
func.func @CaseReturnFunctionTest_getOp_$_2_pap_wrapper ...
func.func @CaseReturnFunctionTest_getOp_$_2_pap_wrapper ...  // duplicate - parse error
```

## Root Cause

In `Expr.elm`, the `generateVarGlobal` function (around line 336-350):

1. Computes a deterministic wrapper name: `funcName ++ "_pap_wrapper"`
2. Creates a new `PendingWrapper` and adds it to `ctx.pendingWrappers` **every time** the function is referenced
3. Has **no check** for whether this wrapper was already queued

When `processPendingWrappers` runs in `Lambdas.elm`, it generates a `func.func` for **every entry** without deduplication.

**Key insight:** PAP wrappers are keyed by the function being *referenced*, and each reference re-enqueues the same wrapper. This differs from lambdas, which are keyed by definition site (unique `lambdaId`).

## Implementation Plan

### Step 1: Add `generatedWrappers` field to Context

**File:** `compiler/src/Compiler/Generate/MLIR/Context.elm`

Add import at top of file:
```elm
import Set
```

Add new field to `Context` type alias:
```elm
type alias Context =
    { nextVar : Int
    , nextOpId : Int
    , mode : Mode.Mode
    , registry : Mono.SpecializationRegistry
    , pendingLambdas : List PendingLambda
    , pendingWrappers : List PendingWrapper
    , signatures : Dict.Dict Int FuncSignature
    , varMappings : Dict.Dict String ( String, MlirType )
    , currentLetSiblings : Dict.Dict String ( String, MlirType )
    , kernelDecls : Dict.Dict String ( List MlirType, MlirType )
    , typeRegistry : TypeRegistry
    , generatedWrappers : Set.Set String  -- NEW: Track wrapper names already queued
    }
```

Initialize in `initContext`:
```elm
    , generatedWrappers = Set.empty
```

### Step 2: Add Set import to Expr.elm

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

Add import at top of file:
```elm
import Set
```

### Step 3: Update wrapper registration in generateVarGlobal

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

**Location:** Around line 336-350, in the `generateVarGlobal` function

**Current code:**
```elm
( targetName, ctx2 ) =
    if needsWrapper then
        let
            wrapperName =
                funcName ++ "_pap_wrapper"

            wrapper : Ctx.PendingWrapper
            wrapper =
                { wrapperName = wrapperName
                , targetFuncName = funcName
                , paramTypes = sig.paramTypes
                , returnType = sig.returnType
                }
        in
        ( wrapperName, { ctx1 | pendingWrappers = wrapper :: ctx1.pendingWrappers } )

    else
        ( funcName, ctx1 )
```

**New code:**
```elm
( targetName, ctx2 ) =
    if needsWrapper then
        let
            wrapperName =
                funcName ++ "_pap_wrapper"
        in
        if Set.member wrapperName ctx1.generatedWrappers then
            -- Already queued; just reuse the name
            ( wrapperName, ctx1 )

        else
            -- First time seeing this wrapper; queue it and mark as generated
            let
                wrapper : Ctx.PendingWrapper
                wrapper =
                    { wrapperName = wrapperName
                    , targetFuncName = funcName
                    , paramTypes = sig.paramTypes
                    , returnType = sig.returnType
                    }
            in
            ( wrapperName
            , { ctx1
                | pendingWrappers = wrapper :: ctx1.pendingWrappers
                , generatedWrappers = Set.insert wrapperName ctx1.generatedWrappers
              }
            )

    else
        ( funcName, ctx1 )
```

### Step 4: Add invariant test (optional but recommended)

**File:** `compiler/tests/Compiler/Generate/CodeGen/InvariantTests.elm` (or similar)

Add a test that:
1. Generates MLIR for a module that references the same function twice in a PAP context
2. Collects all `func.func` symbol names from the generated MLIR AST
3. Asserts no duplicates exist

Example test case (Elm source):
```elm
module Test exposing (..)

getOp : Int -> Int -> Int
getOp a b = a + b

test1 = getOp   -- First reference, creates PAP
test2 = getOp   -- Second reference, should reuse wrapper
```

## Files to Modify

| File | Changes |
|------|---------|
| `compiler/src/Compiler/Generate/MLIR/Context.elm` | Add `import Set`, add `generatedWrappers` field, initialize in `initContext` |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | Add `import Set`, update `generateVarGlobal` to check cache before enqueueing |

## Design Notes

### Why `Set.Set String` is appropriate

- Simple and efficient for membership checking
- `wrapperName` is deterministic and derived from `SpecId`, so it uniquely identifies a wrapper
- No risk of aliasing incompatible wrappers: if signature changed, `funcName` would differ

### Why only `wrapperName` as cache key

- `funcName` is derived from `SpecId` (specialization ID)
- Specializations have fixed `paramTypes`/`returnType` in `signatures`
- A different signature would produce a different `funcName`, thus different `wrapperName`

### Why lambdas don't need this fix

- `PendingLambda` uses unique `lambdaId` from AST
- Each lambda definition is traversed exactly once
- Wrappers are different: keyed by function being *referenced*, not definition site

### Scope

- `Context` is created fresh per module via `initContext`
- `generatedWrappers` is naturally per-module, matching `pendingWrappers`
- Cross-module symbol uniqueness handled upstream (module names in `funcName`)

## Testing

1. **Build compiler:** `cmake --build build`
2. **Run existing tests:** Ensure no regressions
3. **Test the specific failure case:** Compile a module that references the same function multiple times as a PAP
4. **Verify single wrapper:** Check generated MLIR has exactly one `*_pap_wrapper` per function

## Success Criteria

- MLIR generation produces exactly one `*_pap_wrapper` function per base function
- No "redefinition of symbol" parse errors from duplicate wrapper names
- All existing tests continue to pass
