# Plan: Unified ID Space for Expression and Pattern Canonicalization

## Overview

This plan completes Step 1 of the pattern-type-ids implementation by refactoring `canonicalizeNode` in Expression.elm to thread `IdState` through Lambda, Case, Let, and other pattern canonicalization sites.

**Goal:** Expressions and patterns share a single incrementing ID counter, ensuring no ID collisions and enabling pattern types to be tracked alongside expression types.

## Current Architecture

### The Problem

Currently, `canonicalizeNode` has the signature:
```elm
canonicalizeNode : SyntaxVersion -> Env.Env -> IdState -> A.Region -> Src.Expr_
    -> EResult FreeLocals (List W.Warning) ( Can.Expr, IdState )
```

The function receives `state0` (the current ID state) and returns `( Can.Expr, IdState )`. However, when patterns are canonicalized (Lambda args, Case patterns, etc.), the code calls `Pattern.canonicalize` which starts a fresh ID counter:

```elm
-- Current: Pattern.canonicalize ignores state0 and starts fresh
Pattern.canonicalize syntaxVersion env pattern
```

This means patterns get IDs from a separate counter, causing potential ID collisions.

### Key Complexity: Free Locals Tracking

The `EResult` type tracks free local variables:
```elm
type alias EResult i w a = RResult i w Error a
-- where i = FreeLocals for most operations
```

Two wrapper functions handle free locals:
- `delayedUsage`: For Lambdas - marks variables as potentially unused
- `directUsage`: For Let/Case - marks variables as definitely used

Both expect: `EResult () w ( expr, FreeLocals ) -> EResult FreeLocals w expr`

The challenge is that we need to also thread `IdState` through these wrappers while maintaining free locals tracking.

---

## Pattern Canonicalization Sites

There are 5 places in Expression.elm that call `Pattern.canonicalize`:

| Line | Context | Current Call |
|------|---------|--------------|
| 249 | Lambda args | `ReportingResult.traverse (Pattern.canonicalize ...)` |
| 372 | Case branch | `Pattern.canonicalize syntaxVersion env pattern` |
| 584 | Def args (untyped) | `ReportingResult.traverse (Pattern.canonicalize ...)` |
| 638 | Destruct | `Pattern.canonicalize syntaxVersion env pattern` |
| 775 | gatherTypedArgs | `Pattern.canonicalize syntaxVersion env srcArg` |

---

## Implementation Strategy

### Approach: Tuple-Threading with Helper Functions

Rather than restructuring the entire monadic flow, we'll:
1. Add new helper functions that thread `IdState` through pattern canonicalization
2. Update each pattern site to use these helpers
3. Modify `delayedUsage`/`directUsage` to handle the extra state

### Step 1: Add delayedUsageWithIds and directUsageWithIds

**File:** `src/Compiler/Canonicalize/Expression.elm`

```elm
{-| Like delayedUsage but also threads IdState through the result.
-}
delayedUsageWithIds :
    IdState
    -> EResult () w ( ( expr, IdState ), FreeLocals )
    -> EResult FreeLocals w ( expr, IdState )

{-| Like directUsage but also threads IdState through the result.
-}
directUsageWithIds :
    IdState
    -> EResult () w ( ( expr, IdState ), FreeLocals )
    -> EResult FreeLocals w ( expr, IdState )
```

These functions:
- Unwrap the inner `( expr, IdState )` tuple
- Apply free locals tracking (delayed vs direct)
- Re-wrap with the IdState for the outer context

### Step 2: Update Lambda Handler (Line 246-262)

**Current:**
```elm
Src.Lambda ( _, srcArgs ) ( _, body ) ->
    delayedUsage <|
        (Pattern.verify Error.DPLambdaArgs
            (ReportingResult.traverse (Pattern.canonicalize syntaxVersion env) ...)
            |> ReportingResult.andThen (\( args, andThenings ) -> ...)
        )
```

**New:**
```elm
Src.Lambda ( _, srcArgs ) ( _, body ) ->
    delayedUsageWithIds state0 <|
        (Pattern.verifyWithIds Error.DPLambdaArgs
            (Pattern.traverseWithIds syntaxVersion env state0 (List.map Src.c1Value srcArgs))
            |> ReportingResult.andThen
                (\( args, andThenings, stateAfterPatterns ) ->
                    Env.addLocals andThenings env
                        |> ReportingResult.andThen
                            (\newEnv ->
                                verifyBindings W.Pattern andThenings
                                    (canonicalizeWithIds syntaxVersion newEnv stateAfterPatterns body)
                                    |> ReportingResult.map
                                        (\( ( cbody, finalState ), freeLocals ) ->
                                            let
                                                ( lambdaExpr, _ ) =
                                                    makeExpr region state0 (Can.Lambda args cbody)
                                            in
                                            ( ( lambdaExpr, finalState ), freeLocals )
                                        )
                            )
                )
        )
```

**Key changes:**
1. Use `Pattern.traverseWithIds` with `state0` to get `stateAfterPatterns`
2. Use `Pattern.verifyWithIds` which returns `( patterns, bindings, IdState )`
3. Call `canonicalizeWithIds` for body with `stateAfterPatterns`
4. Lambda expr uses `state0` for its own ID (allocated first)
5. Return `finalState` from body for subsequent expressions

### Step 3: Update Case Handler

**Current (calls canonicalizeCaseBranch):**
```elm
Src.Case expr branches ->
    wrapResult
        (ReportingResult.map Can.Case (canonicalize syntaxVersion env (Src.c2Value expr))
            |> ReportingResult.apply
                (ReportingResult.traverse (canonicalizeCaseBranch syntaxVersion env) ...)
        )
```

**Changes needed:**
1. Add `canonicalizeCaseBranchWithIds` that takes and returns `IdState`
2. Use `traverseWithIdsState` helper to thread state through branches
3. Thread state from scrutinee expression through all branches

### Step 4: Update canonicalizeLet (Line 480-501)

The Let handler is more complex because it:
1. Detects duplicate bindings
2. Adds locals to environment
3. Processes definition nodes
4. Detects cycles
5. Canonicalizes body

**Changes needed:**
1. Add `canonicalizeLetWithIds` that takes and returns `IdState`
2. Thread state through `addDefNodes` → `canonicalize body`
3. Update `directUsageWithIds` wrapper

### Step 5: Update Destruct Handler (Line 636-665)

**Current:**
```elm
Src.Destruct pattern ( _, body ) ->
    Pattern.verify Error.DPDestruct
        (Pattern.canonicalize syntaxVersion env pattern)
        |> ...
```

**New:**
```elm
Src.Destruct pattern ( _, body ) ->
    Pattern.verifyWithIds Error.DPDestruct
        (Pattern.canonicalizeWithIds syntaxVersion env state0 pattern)
        |> ReportingResult.andThen
            (\( cpattern, _, stateAfterPattern ) ->
                -- continue with stateAfterPattern
            )
```

### Step 6: Update gatherTypedArgs (Line 772-778)

This is called recursively to collect typed arguments.

**Current signature:**
```elm
gatherTypedArgs : ... -> List ( Can.Pattern, Can.Type )
    -> PResult i w ( List ( Can.Pattern, Can.Type ), Can.Type )
```

**New signature:**
```elm
gatherTypedArgsWithIds : ... -> IdState -> List ( Can.Pattern, Can.Type )
    -> PResult i w ( List ( Can.Pattern, Can.Type ), Can.Type, IdState )
```

### Step 7: Update Def Canonicalization (Line 584)

The untyped def handler in `toNodeInfo` needs similar updates to use `Pattern.traverseWithIds`.

---

## Helper Functions to Add

### 1. traverseWithIdsState

Thread IdState through a list of operations that each consume and produce IdState:

```elm
traverseWithIdsState :
    (a -> IdState -> EResult i w ( b, IdState ))
    -> List a
    -> IdState
    -> EResult i w ( List b, IdState )
```

### 2. verifyBindingsWithIds

Like `verifyBindings` but handles `( expr, IdState )` in the result:

```elm
verifyBindingsWithIds :
    W.Context
    -> Bindings
    -> EResult FreeLocals w ( expr, IdState )
    -> EResult FreeLocals w ( ( expr, IdState ), FreeLocals )
```

---

## Implementation Order

1. **Add helper functions** (no changes to existing logic)
   - `delayedUsageWithIds`
   - `directUsageWithIds`
   - `traverseWithIdsState`
   - `verifyBindingsWithIds`

2. **Update simple sites first** (less complex)
   - Destruct (Line 638) - single pattern
   - gatherTypedArgs (Line 775) - single pattern per call

3. **Update Lambda handler** (Line 246-262)
   - Multiple patterns via `Pattern.traverseWithIds`
   - Body via `canonicalizeWithIds`

4. **Update Case handler** (Line 283-287)
   - Scrutinee via `canonicalizeWithIds`
   - `canonicalizeCaseBranchWithIds` for each branch

5. **Update Let handler** (Line 279-281)
   - Most complex due to cycle detection
   - Update `canonicalizeLetWithIds`

6. **Update Def args** (Line 584)
   - In `toNodeInfo`, use `Pattern.traverseWithIds`

7. **Build and test**

---

## Testing Strategy

1. Build after each major change
2. Verify with existing test suite
3. Add specific test: verify that pattern IDs are unique and sequential with expression IDs
4. Debug by printing ID assignments during canonicalization

---

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| ReportingResult monad complexity | Add one helper at a time, verify types compile |
| Free locals tracking breaks | Preserve exact semantics in `*WithIds` variants |
| Performance regression | IdState is just `{ nextId : Int }`, minimal overhead |
| ID ordering changes | IDs are for type tracking, order doesn't matter for correctness |

---

## Success Criteria

1. Build compiles successfully
2. All existing tests pass
3. Pattern IDs and expression IDs share the same counter
4. No duplicate IDs within a module
5. Pattern types appear correctly in `nodeTypes` dictionary

---

## Estimated Complexity

| Component | Complexity | Reason |
|-----------|------------|--------|
| Helper functions | Low | Straightforward tuple threading |
| Destruct/gatherTypedArgs | Low | Single pattern sites |
| Lambda | Medium | Multiple patterns + body |
| Case | Medium | Scrutinee + multiple branches |
| Let | High | Cycle detection, def nodes, complex flow |

Total: ~300-400 lines of changes, primarily adding `*WithIds` variants of existing functions.
