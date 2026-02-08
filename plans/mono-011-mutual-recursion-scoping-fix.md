# Plan: MONO_011 Mutual Recursion Scoping Fix

## Overview

The MONO_011 test ("MonoGraph is closed and hygienic") incorrectly rejects valid mutually recursive function definitions. The test assumes sequential let-binding scoping, but the Mono IR encodes `LetRec` groups as nested `MonoLet` expressions where all names should be mutually visible.

## Problem Statement

### Current Behavior (Incorrect)

When checking:
```elm
MonoLet (MonoDef "isEven" <body containing MonoVarLocal "isOdd" ...>)
    (MonoLet (MonoDef "isOdd" <body containing MonoVarLocal "isEven" ...>)
        <final body>)
```

The test logic:
1. Checks `isEven`'s body with scope `{isEven}` only
2. `MonoVarLocal "isOdd"` is flagged as unbound → **false violation**

### Root Cause

The Mono IR loses the distinction between sequential lets and mutually recursive let-rec groups:
- `Can.LetRec [isEven, isOdd] body` → `TOpt.Let isEven (TOpt.Let isOdd body)` → nested `MonoLet`s
- The test logic treats each `MonoLet` as sequential, but the semantic intent is mutual recursion

### Desired Behavior

Treat contiguous `MonoLet` chains as a single mutually visible scope:
- All definition names in the chain are in scope for all definition bodies
- All definition names are in scope for the final body expression

## Updated MONO_011 Intent

### What MONO_011 Should Check

1. **Local Variable Scoping**: Every `MonoVarLocal` must resolve to a binder in its lexical region:
   - Parameters of the enclosing closure or tail function
   - Destruct bindings (`MonoDestruct`)
   - Local value definitions (`MonoLet`), treating any contiguous chain of nested `MonoLet`s as a single mutually visible scope
   - Forward references within such a `MonoLet` chain are allowed

2. **Global References**: Every `MonoVarGlobal`'s `SpecId` must exist in `MonoGraph.nodes`

3. **Registry Consistency**: Every registry entry's `SpecId` must appear in the graph

### What MONO_011 Should NOT Check

- Source-level sequential-let scoping rules
- Whether a reference is "forward" or "backward" within a let chain

## Affected Files

| Action | File |
|--------|------|
| **EDIT** | `design_docs/invariant-test-logic.md` |
| **EDIT** | `compiler/tests/TestLogic/Generate/MonoGraphIntegrity.elm` |

## Implementation

### Step 1: Update Documentation

**File**: `design_docs/invariant-test-logic.md`

Find the MONO_011 entry and update the `logic:` block:

**Old**:
```text
logic: For each local/global variable and specialization:
  * Check every `MonoVarLocal` resolves to a binder in scope.
  * Check every `MonoVarGlobal` and `SpecId` refer to existing MonoNodes.
  * Detect unreachable `SpecId`s and ensure they're either optimized away or flagged.
```

**New**:
```text
logic: For each local/global variable and specialization:
  * Check every `MonoVarLocal` resolves to a binder in its lexical region:
      - Parameters of the enclosing closure or tail function
      - Destruct bindings (MonoDestruct)
      - Local value definitions (MonoLet), treating any contiguous chain of
        nested MonoLets as a single mutually visible scope.
      - Forward references within such a MonoLet chain are allowed.
  * Check every `MonoVarGlobal` and `SpecId` refer to existing MonoNodes.
  * Detect unreachable `SpecId`s and ensure they're either optimized away or flagged.
```

Add rationale comment:
```text
Note: Typed optimization and monomorphization encode `let rec` groups as nested
`MonoLet` expressions. At Mono level, scoping for such chains is *mutual*, not
sequential: all definitions in a contiguous `MonoLet` chain are considered in
scope for each other's bodies and for the chain's final body. MONO_011 enforces
that every `MonoVarLocal` is backed by some binder in this sense, rather than
enforcing source-level sequential-let rules.
```

### Step 2: Add Helper Function

**File**: `compiler/tests/TestLogic/Generate/MonoGraphIntegrity.elm`

Add near other local helpers:

```elm
{-| Collect a contiguous chain of nested MonoLet expressions.

Starting from the first `def` and `body`, walks down
`MonoLet nextDef nextBody _` as long as they occur directly in the body
position. Returns the full list of defs (in order) and the final body
expression after the chain.
-}
collectLetChain :
    Mono.MonoDef
    -> Mono.MonoExpr
    -> ( List Mono.MonoDef, Mono.MonoExpr )
collectLetChain firstDef firstBody =
    let
        go defs expr =
            case expr of
                Mono.MonoLet def nextBody _ ->
                    go (defs ++ [ def ]) nextBody

                _ ->
                    ( defs, expr )
    in
    go [ firstDef ] firstBody
```

### Step 3: Update MonoLet Case in checkExprLocalVarScoping

**File**: `compiler/tests/TestLogic/Generate/MonoGraphIntegrity.elm`

**Current code** (lines 445-454):
```elm
Mono.MonoLet def bodyExpr _ ->
    let
        defName =
            getDefName def

        defScope =
            Set.insert identity defName inScope
    in
    checkDefLocalVarScoping context inScope def
        ++ checkExprLocalVarScoping context defScope bodyExpr
```

**Replace with**:
```elm
Mono.MonoLet def bodyExpr _ ->
    -- Treat any contiguous chain of MonoLet as a single
    -- mutually recursive scope.
    let
        ( defs, finalBody ) =
            collectLetChain def bodyExpr

        groupNames : Set String
        groupNames =
            defs
                |> List.map getDefName
                |> List.foldl (Set.insert identity) Set.empty

        groupScope : Set String
        groupScope =
            Set.union inScope groupNames

        defViolations : List (() -> Expectation)
        defViolations =
            -- Pass groupScope so each def body sees all names in chain
            defs
                |> List.concatMap (checkDefLocalVarScoping context groupScope)

        bodyViolations : List (() -> Expectation)
        bodyViolations =
            checkExprLocalVarScoping context groupScope finalBody
    in
    defViolations ++ bodyViolations
```

### Step 4: No Changes to checkDefLocalVarScoping

The existing `checkDefLocalVarScoping` function remains unchanged:

```elm
checkDefLocalVarScoping context inScope def =
    case def of
        Mono.MonoDef name expr ->
            let
                defScope =
                    Set.insert identity name inScope
            in
            checkExprLocalVarScoping context defScope expr

        Mono.MonoTailDef name params expr ->
            let
                paramNames =
                    List.map (\( n, _ ) -> n) params
                        |> Set.fromList identity

                defScope =
                    Set.union (Set.insert identity name inScope) paramNames
            in
            checkExprLocalVarScoping context defScope expr
```

This works because:
- We now pass `groupScope` as `inScope` from the `MonoLet` case
- The function still adds the def's own name (idempotent since already in `groupScope`)
- Parameters are still added correctly for `MonoTailDef`

### Step 5: No Changes to Other Constructs

The following cases in `checkExprLocalVarScoping` remain unchanged:
- `MonoClosure` - adds closure params to scope
- `MonoDestruct` - adds destructor binding name to scope
- `MonoCase` - uses scrutinee name for branches
- Global/SpecId validation - unchanged

## Verification

After implementation, run:

```bash
cd compiler
npx elm-test-rs --fuzz 1
```

Expected result:
- "Two mutually recursive functions" tests should pass
- All other MONO_011 tests should continue to pass
- No new failures introduced

## Effect on Failing Tests

### Test: LetRecCases / Two mutually recursive functions

**Before fix**: `MonoVarLocal 'isOdd' is not in scope at SpecId 0`

**After fix**:
1. `collectLetChain` discovers `[isEvenDef, isOddDef]`
2. `groupNames = {isEven, isOdd}`
3. `groupScope = inScope ∪ {isEven, isOdd}`
4. Both definition bodies checked with `groupScope`
5. `MonoVarLocal "isOdd"` in isEven's body resolves ✓
6. `MonoVarLocal "isEven"` in isOdd's body resolves ✓

### Test: SpecializeCycleCases / Two mutually recursive functions

Same fix applies - identical pattern.

## Why This Doesn't Mask Real Bugs

The invariant only promises "no dangling locals/globals/specs" - it never claimed to enforce source-level sequential scoping.

To create a false negative, the compiler would need to:
1. Introduce a reference to name `c` that wasn't in scope in source, **AND**
2. Also introduce a spurious `MonoDef c = ...` in the same let chain

This is a much stronger bug than a simple dangling reference. The canonicalizer and typed optimization phases already reject illegal forward references and attach correct types. The realistic bug class is "dangling MonoVarLocal", not "refers to wrong def in same chain".

## Summary

| Step | Action | Description |
|------|--------|-------------|
| 1 | Update docs | Clarify MONO_011 allows mutual visibility in let chains |
| 2 | Add helper | `collectLetChain` to gather contiguous MonoLet defs |
| 3 | Fix MonoLet case | Use `groupScope` containing all chain names |
| 4 | Keep other cases | No changes to closure, destruct, case, or global checks |
| 5 | Verify | Run tests, confirm 2 failures now pass |
