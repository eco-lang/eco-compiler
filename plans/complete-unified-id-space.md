# Plan: Complete Unified ID Space Implementation

## Overview

This plan eliminates dual code paths and completes the unified ID space for expressions and patterns. After implementation, all expressions and patterns will share a single incrementing ID counter, with no placeholder IDs.

**Goals:**
1. Remove all non-WithIds variants (make WithIds the only path)
2. Update Module.elm to thread IdState through top-level definitions
3. Fix all expression handlers to properly thread IdState
4. Eliminate placeholder IDs in detectCycles and binops
5. Clean up exports and unused functions

---

## Phase 1: Update All Expression Handlers in canonicalizeNode

**File:** `src/Compiler/Canonicalize/Expression.elm`

### 1.1 Update List Handler (Line 227-228)

**Current:**
```elm
Src.List exprs _ ->
    wrapResult (ReportingResult.map Can.List (ReportingResult.traverse (canonicalize syntaxVersion env) (List.map Tuple.second exprs)))
```

**New:**
```elm
Src.List exprs _ ->
    traverseWithState syntaxVersion env state0 (List.map Tuple.second exprs)
        |> ReportingResult.map (\( items, finalState ) ->
            let ( id, nextState ) = Ids.allocId finalState
            in ( A.At region { id = id, node = Can.List items }, nextState )
        )
```

**Helper needed:**
```elm
traverseWithState : SyntaxVersion -> Env.Env -> IdState -> List Src.Expr
    -> EResult FreeLocals (List W.Warning) ( List Can.Expr, IdState )
```

### 1.2 Update Negate Handler (Line 239-240)

**Current:**
```elm
Src.Negate expr ->
    wrapResult (ReportingResult.map Can.Negate (canonicalize syntaxVersion env expr))
```

**New:**
```elm
Src.Negate expr ->
    let ( negateId, stateAfterNegate ) = Ids.allocId state0
    in
    canonicalizeWithIds syntaxVersion env stateAfterNegate expr
        |> ReportingResult.map (\( cexpr, finalState ) ->
            ( A.At region { id = negateId, node = Can.Negate cexpr }, finalState )
        )
```

### 1.3 Update Call Handler (Line 274-278)

**Current:**
```elm
Src.Call func args ->
    wrapResult
        (ReportingResult.map Can.Call (canonicalize syntaxVersion env func)
            |> ReportingResult.apply (ReportingResult.traverse (canonicalize syntaxVersion env) (List.map Src.c1Value args))
        )
```

**New:**
```elm
Src.Call func args ->
    let ( callId, stateAfterCall ) = Ids.allocId state0
    in
    canonicalizeWithIds syntaxVersion env stateAfterCall func
        |> ReportingResult.andThen (\( cfunc, stateAfterFunc ) ->
            traverseWithState syntaxVersion env stateAfterFunc (List.map Src.c1Value args)
                |> ReportingResult.map (\( cargs, finalState ) ->
                    ( A.At region { id = callId, node = Can.Call cfunc cargs }, finalState )
                )
        )
```

### 1.4 Update If Handler (Line 280-287)

**Current:**
```elm
Src.If firstBranch branches finally ->
    wrapResult
        (ReportingResult.map Can.If
            (ReportingResult.traverse (canonicalizeIfBranch syntaxVersion env) ...)
            |> ReportingResult.apply (canonicalize syntaxVersion env (Src.c1Value finally))
        )
```

**New:**
```elm
Src.If firstBranch branches finally ->
    let ( ifId, stateAfterIf ) = Ids.allocId state0
    in
    traverseIfBranchesWithIds syntaxVersion env stateAfterIf
        (List.map (Src.c1Value >> Tuple.mapBoth Src.c2Value Src.c2Value) (firstBranch :: branches))
        |> ReportingResult.andThen (\( cBranches, stateAfterBranches ) ->
            canonicalizeWithIds syntaxVersion env stateAfterBranches (Src.c1Value finally)
                |> ReportingResult.map (\( cfinally, finalState ) ->
                    ( A.At region { id = ifId, node = Can.If cBranches cfinally }, finalState )
                )
        )
```

**Helper needed:**
```elm
canonicalizeIfBranchWithIds : SyntaxVersion -> Env.Env -> IdState -> ( Src.Expr, Src.Expr )
    -> EResult FreeLocals (List W.Warning) ( ( Can.Expr, Can.Expr ), IdState )

traverseIfBranchesWithIds : SyntaxVersion -> Env.Env -> IdState -> List ( Src.Expr, Src.Expr )
    -> EResult FreeLocals (List W.Warning) ( List ( Can.Expr, Can.Expr ), IdState )
```

### 1.5 Update Accessor Handler (Line 314-315)

**Current:**
```elm
Src.Accessor field ->
    wrapResult (ReportingResult.ok (Can.Accessor field))
```

**New:**
```elm
Src.Accessor field ->
    let ( id, newState ) = Ids.allocId state0
    in ReportingResult.ok ( A.At region { id = id, node = Can.Accessor field }, newState )
```

### 1.6 Update Access Handler (Line 317-321)

**Current:**
```elm
Src.Access record field ->
    wrapResult
        (ReportingResult.map Can.Access (canonicalize syntaxVersion env record)
            |> ReportingResult.apply (ReportingResult.ok field)
        )
```

**New:**
```elm
Src.Access record field ->
    let ( accessId, stateAfterAccess ) = Ids.allocId state0
    in
    canonicalizeWithIds syntaxVersion env stateAfterAccess record
        |> ReportingResult.map (\( crecord, finalState ) ->
            ( A.At region { id = accessId, node = Can.Access crecord field }, finalState )
        )
```

### 1.7 Update Update Handler (Line 323-332)

**Current:** Uses `canonicalize` for field values and record expression.

**New:** Thread IdState through record expression and all field updates.

### 1.8 Update Record Handler (Line 334-341)

**Current:** Uses `canonicalize` for field values.

**New:** Thread IdState through all field values using a dict traversal helper.

### 1.9 Update Tuple Handler (Line 346-351)

**Current:** Uses `canonicalize` for tuple elements.

**New:** Thread IdState through all tuple elements.

### 1.10 Update Parens Handler (Line 356-358)

**Current:**
```elm
Src.Parens ( _, expr ) ->
    canonicalize syntaxVersion env expr
        |> ReportingResult.map (\e -> ( e, state0 ))
```

**New:**
```elm
Src.Parens ( _, expr ) ->
    canonicalizeWithIds syntaxVersion env state0 expr
```

---

## Phase 2: Fix Binop Handler with Proper IDs

**File:** `src/Compiler/Canonicalize/Expression.elm`

### 2.1 Update canonicalizeBinops to Thread IdState

**Current signature:**
```elm
canonicalizeBinops : SyntaxVersion -> A.Region -> Env.Env -> List ( Src.Expr, A.Located Name.Name ) -> Src.Expr
    -> EResult FreeLocals (List W.Warning) Can.Expr
```

**New signature:**
```elm
canonicalizeBinops : SyntaxVersion -> A.Region -> Env.Env -> IdState -> List ( Src.Expr, A.Located Name.Name ) -> Src.Expr
    -> EResult FreeLocals (List W.Warning) ( Can.Expr, IdState )
```

### 2.2 Update toBinop to Accept IdState

**Current:**
```elm
toBinop : Env.Binop -> Can.Expr -> Can.Expr -> Can.Expr
toBinop (Env.Binop binopData) left right =
    mergeExprs left right (Can.Binop ...)
```

**New:**
```elm
toBinop : Env.Binop -> IdState -> Can.Expr -> Can.Expr -> ( Can.Expr, IdState )
toBinop (Env.Binop binopData) state left right =
    let ( id, newState ) = Ids.allocId state
        region = A.mergeRegions (A.getRegion left) (A.getRegion right)
    in
    ( A.At region { id = id, node = Can.Binop binopData.op binopData.home binopData.name binopData.annotation left right }
    , newState
    )
```

### 2.3 Update Step Type and Helpers

The `Step` type and `runBinopStepper`, `toBinopStep` functions need to carry IdState through the stepping process.

---

## Phase 3: Fix detectCycles with Proper IDs

**File:** `src/Compiler/Canonicalize/Expression.elm`

### 3.1 Update detectCycles Signature

**Current:**
```elm
detectCycles : A.Region -> List (Graph.SCC Binding) -> Can.Expr -> EResult i w Can.Expr
```

**New:**
```elm
detectCycles : A.Region -> IdState -> List (Graph.SCC Binding) -> Can.Expr -> EResult i w ( Can.Expr, IdState )
```

### 3.2 Allocate IDs for Let/LetDestruct/LetRec

**Current:**
```elm
Define def ->
    detectCycles letRegion subSccs body
        |> ReportingResult.map (Can.Let def)
        |> ReportingResult.map (makeExprPlaceholder letRegion)
```

**New:**
```elm
Define def ->
    detectCycles letRegion stateAfterLet subSccs body
        |> ReportingResult.map (\( bodyExpr, finalState ) ->
            let ( letId, nextState ) = Ids.allocId finalState
            in ( A.At letRegion { id = letId, node = Can.Let def bodyExpr }, nextState )
        )
```

### 3.3 Update canonicalizeLetWithIds to Pass State to detectCycles

The state after processing body should be passed to detectCycles.

---

## Phase 4: Update Module-Level Canonicalization

**File:** `src/Compiler/Canonicalize/Module.elm`

### 4.1 Add IdState Threading to canonicalizeValues

**Current:**
```elm
canonicalizeValues : SyntaxVersion -> Env.Env -> List (A.Located Src.Value) -> MResult i (List W.Warning) Can.Decls
```

**New:**
```elm
canonicalizeValues : SyntaxVersion -> Env.Env -> List (A.Located Src.Value) -> MResult i (List W.Warning) Can.Decls
-- Internally starts with Ids.initialIdState and threads through all values
```

### 4.2 Update toNodeOne to Use WithIds

**Current (line 289):**
```elm
Pattern.canonicalize syntaxVersion env
```

**New:**
```elm
Pattern.traverseWithIds syntaxVersion env state (List.map Src.c1Value srcArgs)
```

### 4.3 Update Body Canonicalization (lines 295, 322)

**Current:**
```elm
Expr.canonicalize syntaxVersion newEnv body
```

**New:**
```elm
Expr.canonicalizeWithIds syntaxVersion newEnv stateAfterArgs body
```

### 4.4 Update gatherTypedArgs Usage (line 316)

**Current:**
```elm
Expr.gatherTypedArgs syntaxVersion env name ...
```

**New:**
```elm
Expr.gatherTypedArgsWithIds syntaxVersion env name state ...
```

---

## Phase 5: Remove Dual Code Paths

### 5.1 Expression.elm - Remove Non-WithIds Variants

**Remove:**
- `canonicalize` (make it call `canonicalizeWithIds` and extract first element)
- `canonicalizeCaseBranch` (only keep `canonicalizeCaseBranchWithIds`)
- `canonicalizeIfBranch` (replace with `canonicalizeIfBranchWithIds`)
- `addDefNodes` (only keep `addDefNodesWithIds`)
- `canonicalizeLet` (only keep `canonicalizeLetWithIds`)
- `gatherTypedArgs` (only keep `gatherTypedArgsWithIds`)
- `verifyBindings` (only keep `verifyBindingsWithIds`)
- `directUsage` (only keep `directUsageWithIds`)
- `delayedUsage` (only keep `delayedUsageWithIds`)
- `logLetLocals` (only keep `logLetLocalsWithIds`)
- `wrapResult` helper
- `makeExprPlaceholder` and `mergeExprs`

**Keep (rename):**
- `canonicalizeWithIds` -> `canonicalize` (update all callers)
- All `*WithIds` functions become the primary versions

### 5.2 Pattern.elm - Simplify

**Current `canonicalize`:**
```elm
canonicalize syntaxVersion env srcPattern =
    canonicalizeWithIds syntaxVersion env Ids.initialIdState srcPattern
        |> ReportingResult.map Tuple.first
```

**Option A:** Keep this convenience wrapper for backward compatibility.
**Option B:** Remove and require all callers to use WithIds.

**Recommendation:** Option A - keep the wrapper for external callers, but ensure Module.elm uses WithIds directly.

### 5.3 Update Exports

**Expression.elm exports:**
```elm
module Compiler.Canonicalize.Expression exposing
    ( EResult, FreeLocals, Uses(..)
    , canonicalize, canonicalizeWithIds
    , gatherTypedArgsWithIds
    , verifyBindingsWithIds
    )
```

Remove from exports:
- `gatherTypedArgs` (only WithIds version)
- `verifyBindings` (only WithIds version)

---

## Phase 6: Clean Up Helper Functions

### 6.1 Add Missing Traverse Helpers

```elm
{-| Traverse expressions while threading IdState. -}
traverseWithState : SyntaxVersion -> Env.Env -> IdState -> List Src.Expr
    -> EResult FreeLocals (List W.Warning) ( List Can.Expr, IdState )
traverseWithState syntaxVersion env state exprs =
    case exprs of
        [] -> ReportingResult.ok ( [], state )
        expr :: rest ->
            canonicalizeWithIds syntaxVersion env state expr
                |> ReportingResult.andThen (\( cexpr, stateAfter ) ->
                    traverseWithState syntaxVersion env stateAfter rest
                        |> ReportingResult.map (\( crest, finalState ) ->
                            ( cexpr :: crest, finalState )
                        )
                )

{-| Traverse a dict while threading IdState. -}
traverseDictWithState : ...
```

### 6.2 Remove Unused Helpers

- `wrapResult` - no longer needed
- `wrapNode` - no longer needed
- `makeExprPlaceholder` - no longer needed
- `mergeExprs` - no longer needed

---

## Implementation Order

| Step | Description | Risk | Dependency |
|------|-------------|------|------------|
| 1 | Add `traverseWithState` and other helpers | Low | None |
| 2 | Update simple handlers (Accessor, Parens) | Low | Step 1 |
| 3 | Update Negate, Access handlers | Low | Step 1 |
| 4 | Update List, Tuple handlers | Medium | Step 1 |
| 5 | Update Call, If handlers | Medium | Step 1 |
| 6 | Update Record, Update handlers | Medium | Step 1 |
| 7 | Update binop handling with IdState | High | Steps 1-6 |
| 8 | Update detectCycles with IdState | High | Step 7 |
| 9 | Update canonicalizeLetWithIds to use new detectCycles | Medium | Step 8 |
| 10 | Update Module.elm to use WithIds | High | Steps 1-9 |
| 11 | Remove dual code paths | Medium | Step 10 |
| 12 | Update exports | Low | Step 11 |
| 13 | Build and test | - | Step 12 |

---

## Testing Strategy

1. **Build after each step** - Ensure no type errors
2. **Run test suite after steps 9, 10, 13** - Verify functionality
3. **Verify pattern IDs are sequential with expression IDs** - Add debug logging
4. **Check nodeTypes dictionary** - Ensure patterns appear with correct types

---

## Files Modified

| File | Changes |
|------|---------|
| `src/Compiler/Canonicalize/Expression.elm` | Update all handlers, remove dual paths |
| `src/Compiler/Canonicalize/Module.elm` | Thread IdState through top-level defs |
| `src/Compiler/Canonicalize/Pattern.elm` | Minor - keep WithIds as primary |

---

## Success Criteria

1. All expressions and patterns share a single ID counter starting from 0
2. No placeholder IDs (id = -1) anywhere in the canonical AST
3. Pattern types appear correctly in the nodeTypes dictionary
4. All existing tests pass
5. No dual code paths - only WithIds variants exist
6. Build compiles without warnings about unused functions

---

## Estimated Scope

- **Lines added:** ~200 (new helpers and updated handlers)
- **Lines removed:** ~300 (dual code paths)
- **Net change:** ~-100 lines (cleaner code)
- **Files modified:** 3
