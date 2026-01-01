# Implementation Plan: Kernel Mono Closures Fix

Based on design document: `/work/design_docs/kernel-mono-closures.md`

## Status: FIXED ✓

**Root cause identified and fixed:** The issue was hypothesis #2 - the `requestedMonoType` was an unresolved type variable (`MVar "a" CEcoValue`) instead of the correct function type (`MFunction [MString] ...`).

### What was implemented:

1. **Invariant check** (`checkCallableTopLevels`): Verifies that all function-typed `MonoDefine` nodes have `MonoClosure` expressions. This helped diagnose the issue and now catches future regressions.

2. **Type resolution fix** in `specializeExpr` for `TOpt.VarGlobal`: When the canonical type resolves to an unresolved type variable (`MVar`), we now look up the global's actual type from its definition and use that instead.

### Test results:
- Before: All tests failed with `'llvm.call' op incorrect number of operands (1) for callee (expecting: 0)`
- After: 14 tests pass, 123 fail (but no longer due to kernel alias issues)
- Remaining 4 operand errors are partial application/currying issues (separate problem)

---

## Original Problem Summary

Kernel function aliases like `VirtualDom.text = Elm.Kernel.VirtualDom.text` are not being properly eta-expanded during monomorphization. This results in:
- Call sites passing arguments (e.g., `Html_text_$_1` calls `VirtualDom_text_$_2` with 1 argument)
- Callee definitions expecting zero arguments (`VirtualDom_text_$_2` is a nullary function)
- LLVM lowering fails: `'llvm.call' op incorrect number of operands (1) for callee (expecting: 0)`

## Current State Assessment

| Design Section | Status | Notes |
|----------------|--------|-------|
| 1. `ensureCallableTopLevel` handling | **ALREADY EXISTS** | The `MonoVarKernel` case is present |
| 2. All defines go through `ensureCallableTopLevel` | **WORKS** | The issue was the type, not the call path |
| 3. Debug-time invariant check | **IMPLEMENTED** | `checkCallableTopLevels` now exists |
| 4. MLIR codegen guard rails | **NOT IMPLEMENTED** | Not strictly needed now (invariant catches issues) |
| 5. Sanity tests | **NOT IMPLEMENTED** | Could be added for extra safety |

## Root Cause (Confirmed)

**Hypothesis #2 was correct:** `requestedMonoType` was not a function type.

When `Html.text`'s body references `VirtualDom.text`, the canonical type of that reference was a fresh type variable (`TVar "a"`) that wasn't in the substitution map. When `applySubst` was called, it produced `MVar "a" CEcoValue` instead of the correct function type.

Since `ensureCallableTopLevel` checks `case monoType of MFunction ...`, the unresolved type variable caused it to skip wrapping the expression in a closure.

---

## Implementation Strategy

**Approach: Invariant Check First**

Rather than guessing which hypothesis is correct, implement the invariant check first. When it fails, it will tell us exactly which node is wrong and what its type/expression look like.

---

## Implementation Steps

### Step 1: Implement `checkCallableTopLevels` Invariant Check (FIRST PRIORITY)

This is the highest priority step. It will immediately tell us which node is broken and why.

**File:** `compiler/src/Compiler/Generate/Monomorphize.elm`

**Location:** Add below `MonoState` / `WorkItem` definitions (around line 170)

#### 1a. Add `isFunctionType` helper

```elm
{-| Check if a MonoType represents a function type.
-}
isFunctionType : Mono.MonoType -> Bool
isFunctionType monoType =
    case monoType of
        Mono.MFunction _ _ ->
            True

        _ ->
            False
```

#### 1b. Add `checkCallableTopLevels` function

```elm
{-| Verify that all function-typed MonoDefine nodes have MonoClosure expressions.
Returns an error message if the invariant is violated.
-}
checkCallableTopLevels : MonoState -> Result String ()
checkCallableTopLevels state =
    let
        checkNode : ( Int, Mono.MonoNode ) -> Maybe String
        checkNode ( specId, node ) =
            case node of
                Mono.MonoDefine expr monoType ->
                    if isFunctionType monoType then
                        case expr of
                            Mono.MonoClosure _ _ _ ->
                                Nothing

                            _ ->
                                let
                                    globalName =
                                        case Mono.lookupSpecKey specId state.registry of
                                            Just ( Mono.Global home name, _, _ ) ->
                                                home ++ "." ++ name
                                            Nothing ->
                                                "unknown"
                                in
                                Just
                                    ("Monomorphization invariant violated: "
                                        ++ "function-typed MonoDefine is not a MonoClosure.\n"
                                        ++ "  Global: " ++ globalName ++ "\n"
                                        ++ "  SpecId: " ++ String.fromInt specId ++ "\n"
                                        ++ "  Type: " ++ Debug.toString monoType ++ "\n"
                                        ++ "  Expr: " ++ Debug.toString expr
                                    )

                    else
                        Nothing

                _ ->
                    Nothing
    in
    case Dict.toList identity state.nodes
        |> List.filterMap checkNode
        |> List.head of
        Just msg ->
            Err msg

        Nothing ->
            Ok ()
```

#### 1c. Wire into `monomorphizeFromEntry`

**Location:** Around line 106, after `finalState = processWorklist stateWithMain`

**Change from:**
```elm
finalState : MonoState
finalState =
    processWorklist stateWithMain

mainKey : List String
mainKey =
    ...
in
Ok (Mono.MonoGraph ...)
```

**Change to:**
```elm
finalState : MonoState
finalState =
    processWorklist stateWithMain
in
case checkCallableTopLevels finalState of
    Err msg ->
        Err ("COMPILER BUG: " ++ msg)

    Ok () ->
        let
            mainKey : List String
            mainKey =
                ...
        in
        Ok (Mono.MonoGraph ...)
```

#### 1d. Run tests and analyze output

```bash
./build/test/test --filter elm
```

The invariant check will now tell us:
- Which global function is broken (e.g., `VirtualDom.text`)
- Its SpecId
- Its MonoType (is it `MFunction` or something else?)
- Its expression (is it `MonoVarKernel`, `MonoVarGlobal`, or something else?)

---

### Step 2: Diagnose Based on Invariant Check Output

Based on what Step 1 reveals, we'll know exactly which hypothesis is correct:

**If the type is NOT `MFunction`:**
- Issue is in how `requestedMonoType` is computed
- Add logging in `specializeNode` / the worklist to trace type derivation

**If the type IS `MFunction` but expr is `MonoVarKernel`:**
- `ensureCallableTopLevel` is not being called for this node
- Check which `TOpt.Node` variant this comes from (likely `TOpt.Link` → `TOpt.Kernel`)

**If the type IS `MFunction` but expr is something else:**
- May be a different code path entirely

---

### Step 3: Fix the Root Cause

*This step depends on Step 2's findings. Likely fixes:*

**If `TOpt.Link` → `TOpt.Kernel` bypasses `ensureCallableTopLevel`:**
- The `TOpt.Kernel` case in `specializeNode` returns `MonoExtern` directly
- Need to either:
  - Wrap `MonoExtern` in a closure for function types, OR
  - Change how kernel aliases are represented in `TOpt`

**If `requestedMonoType` is wrong:**
- Trace back to where the type was computed
- Fix type derivation logic

---

### Step 4: Add MLIR Codegen Guard Rails

**File:** `compiler/src/Compiler/Generate/CodeGen/MLIR.elm`

These are secondary defense-in-depth checks. Once the monomorphizer is fixed, these should never trigger.

#### 4a. Add `isFunctionType` helper (around line 155)

```elm
{-| Check if a MonoType represents a function type.
-}
isFunctionType : Mono.MonoType -> Bool
isFunctionType monoType =
    case monoType of
        Mono.MFunction _ _ ->
            True

        _ ->
            False
```

#### 4b. Update `extractNodeSignature` (around line 259)

**Change from:**
```elm
_ ->
    -- Thunk (nullary function) - no params
    Just
        { paramTypes = []
        , returnType = monoType
        }
```

**Change to:**
```elm
_ ->
    if isFunctionType monoType then
        Debug.todo
            ("extractNodeSignature: function-typed MonoDefine "
                ++ "without MonoClosure expression: "
                ++ Debug.toString monoType
            )

    else
        -- Non-function thunk (e.g. top-level value)
        Just
            { paramTypes = []
            , returnType = monoType
            }
```

#### 4c. Update `generateDefine` (around line 878)

**Change from:**
```elm
_ ->
    -- Value (thunk) - wrap in nullary function
    let
        ...
```

**Change to:**
```elm
_ ->
    if isFunctionType monoType then
        Debug.todo
            ("generateDefine: function-typed MonoDefine "
                ++ "without MonoClosure expression for "
                ++ funcName
            )

    else
        -- Value (thunk) - wrap in nullary function
        let
            ...
```

### Step 5: Add Comprehensive Regression Tests

**Location:** `test/elm/src/`

Create multiple test files covering different arity and usage patterns:

#### 5a. Single-arg kernel alias: `Html.text` / `VirtualDom.text`

**File:** `test/elm/src/KernelAliasTextTest.elm`

```elm
module KernelAliasTextTest exposing (main)

import Html exposing (Html, text)

main : Html msg
main =
    Html.text "hello"
```

#### 5b. Higher-order use of single-arg alias

**File:** `test/elm/src/KernelAliasHigherOrderTest.elm`

```elm
module KernelAliasHigherOrderTest exposing (main)

import Html exposing (Html, div, text)

main : Html msg
main =
    div [] (List.map Html.text ["a", "b", "c"])
```

#### 5c. Two-arg kernel alias: `List.cons` / `(::)`

**File:** `test/elm/src/KernelAliasConsTest.elm`

```elm
module KernelAliasConsTest exposing (main)

import Html exposing (Html, text)

main : Html msg
main =
    let
        -- Direct call
        list1 = 1 :: [2, 3]

        -- Higher-order use
        list2 = List.foldr (::) [] [4, 5, 6]
    in
    text (Debug.toString list1 ++ " " ++ Debug.toString list2)
```

#### 5d. Multi-arg kernel alias: `Html.node` / `VirtualDom.node`

**File:** `test/elm/src/KernelAliasNodeTest.elm`

```elm
module KernelAliasNodeTest exposing (main)

import Html exposing (Html, node, text)
import Html.Attributes exposing (class)

main : Html msg
main =
    node "custom-element" [ class "test" ] [ text "content" ]
```

#### 5e. Zero-arg cases (should be thunks, NOT closures)

These should work correctly as nullary functions:

**File:** `test/elm/src/ZeroArityTest.elm`

```elm
module ZeroArityTest exposing (main)

import Html exposing (Html, text)

main : Html msg
main =
    text (String.fromFloat pi)
```

---

## Testing Strategy

### Step 1: Run invariant check
```bash
./build/test/test --filter elm
```
**Expected:** Clear "COMPILER BUG" message with details about the offending node

### Step 2-3: After diagnosis and fix
```bash
./build/test/test --filter elm
```
**Expected:** Either tests pass OR invariant check fails with different node

### Step 4: After MLIR guard rails
```bash
./build/test/test --filter elm
```
**Expected:** Tests pass. If invariant missed something, get clear `Debug.todo` crash

### Step 5: After regression tests added
```bash
./build/test/test --filter KernelAlias
./build/test/test --filter elm
```
**Expected:** All tests pass

---

## Files to Modify

1. **`compiler/src/Compiler/Generate/Monomorphize.elm`**
   - Add `isFunctionType` helper
   - Add `checkCallableTopLevels` function
   - Modify `monomorphizeFromEntry` to call the check
   - Fix the root cause (TBD based on Step 2 diagnosis)

2. **`compiler/src/Compiler/Generate/CodeGen/MLIR.elm`**
   - Add `isFunctionType` helper
   - Modify `extractNodeSignature` with guard rail
   - Modify `generateDefine` with guard rail

3. **`test/elm/src/`** (new files)
   - `KernelAliasTextTest.elm`
   - `KernelAliasHigherOrderTest.elm`
   - `KernelAliasConsTest.elm`
   - `KernelAliasNodeTest.elm`
   - `ZeroArityTest.elm`

---

## Summary

**Execution Order:**
1. Implement `checkCallableTopLevels` + wire into `monomorphizeFromEntry`
2. Run tests → get precise error message
3. Diagnose and fix root cause based on error
4. Add MLIR guard rails (defense in depth)
5. Add regression tests

**Key Decision:** Always run invariant check (cheap, catches bugs early, can gate behind flag later)
