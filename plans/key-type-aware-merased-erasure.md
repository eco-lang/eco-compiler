# Key-Type-Aware MErased Erasure

## Goal

Make MVar→MErased erasure *key-type aware*: only specs whose specialization key type still contains `MVar _ CEcoValue` get their CEcoValue MVars erased to `MErased`. Specs with fully monomorphic key types keep their MVars visible so MONO_021 catches real specialization bugs (e.g. the cycle case).

## Context

Currently in `monomorphizeFromEntry` (Monomorphize.elm:122–135):
- **Dead-value specs** (not in `valueUsedWithMain`): all MVars → MErased via `patchNodeTypesToErased`
- **Value-used specs**: no patching at all → any remaining `MVar _ CEcoValue` trips MONO_021

The problem: 5 "benign unconstrained" cases (wildcard lambda, record-update lambda, partially applied local, standalone accessors, unused Either branch) are value-used but have MVars that were *never constrained* — they're phantom. Meanwhile, the cycle bug has MVars from *failed propagation* in a monomorphic-key spec. We need to distinguish these structurally.

**Structural rule**: If a spec's registry key type has `MVar _ CEcoValue`, all CEcoValue MVars in that spec are erasable phantoms. If the key type is fully monomorphic, any remaining CEcoValue MVars are a real bug.

All 5 benign cases are confirmed to have polymorphic key types (verified by tracing through `canTypeToMonoType` and the specialization worklist seeding).

---

## Step-by-Step Plan

### Step 1: Add `containsCEcoMVar` to `Monomorphized.elm`

**File**: `compiler/src/Compiler/AST/Monomorphized.elm`
**Location**: After `eraseTypeVarsToErased` (line ~340)

Add a function that detects whether a `MonoType` contains any `MVar _ CEcoValue`:
```elm
containsCEcoMVar : MonoType -> Bool
```
Recurse into `MList`, `MFunction`, `MTuple`, `MRecord`, `MCustom`. Only `MVar _ CEcoValue` returns `True`; `MVar _ CNumber` returns `False`. Scalars, `MErased` return `False`.

### Step 2: Add `eraseCEcoVarsToErased` to `Monomorphized.elm`

**File**: `compiler/src/Compiler/AST/Monomorphized.elm`
**Location**: After `containsCEcoMVar`

Add a type-level eraser that *only* rewrites `MVar _ CEcoValue → MErased`, leaving `MVar _ CNumber` intact:
```elm
eraseCEcoVarsToErased : MonoType -> MonoType
```
Same recursive structure as `eraseTypeVarsToErased` (line 299–340) but the `MVar` case branches on constraint: `CEcoValue → MErased`, `CNumber → monoType`.

### Step 3: Refactor expression erasure via parameterized helpers in `Monomorphize.elm`

**File**: `compiler/src/Compiler/Monomorphize/Monomorphize.elm`

Replace the existing `eraseExprTypeVars` / `eraseOneExprType` with a parameterized internal helper to avoid duplicating the ~65-line case expression:

1. **Introduce `mapOneExprType`** — factor `eraseOneExprType` into a generic version parameterized on `(MonoType -> MonoType)`:
   ```elm
   mapOneExprType : (Mono.MonoType -> Mono.MonoType) -> Mono.MonoExpr -> Mono.MonoExpr
   mapOneExprType f expr =
       case expr of
           Mono.MonoLiteral lit t -> Mono.MonoLiteral lit (f t)
           ...  -- same structure as current eraseOneExprType
   ```

2. **Introduce `mapExprTypes`** — wraps `Traverse.mapExpr`:
   ```elm
   mapExprTypes : (Mono.MonoType -> Mono.MonoType) -> Mono.MonoExpr -> Mono.MonoExpr
   mapExprTypes f = Traverse.mapExpr (mapOneExprType f)
   ```

3. **Redefine existing functions as thin wrappers**:
   ```elm
   eraseExprTypeVars : Mono.MonoExpr -> Mono.MonoExpr
   eraseExprTypeVars = mapExprTypes Mono.eraseTypeVarsToErased

   eraseExprCEcoVars : Mono.MonoExpr -> Mono.MonoExpr
   eraseExprCEcoVars = mapExprTypes Mono.eraseCEcoVarsToErased
   ```

4. **Similarly parameterize destructor/path erasure**:
   ```elm
   mapDestructorTypes : (Mono.MonoType -> Mono.MonoType) -> Mono.MonoDestructor -> Mono.MonoDestructor
   mapPathTypes : (Mono.MonoType -> Mono.MonoType) -> Mono.MonoPath -> Mono.MonoPath
   ```
   Then `eraseDestructorTypes = mapDestructorTypes Mono.eraseTypeVarsToErased` (preserves existing API).

This keeps the public `eraseExprTypeVars` signature unchanged and avoids any duplication.

### Step 4: Add `patchNodeTypesCEcoToErased` to `Monomorphize.elm`

**File**: `compiler/src/Compiler/Monomorphize/Monomorphize.elm`
**Location**: After `patchNodeTypesToErased` (~line 574)

Add the new node-level patcher for value-used, polymorphic-key specs:
```elm
patchNodeTypesCEcoToErased : Mono.MonoNode -> Mono.MonoNode
patchNodeTypesCEcoToErased node =
    case node of
        Mono.MonoDefine expr t ->
            Mono.MonoDefine
                (eraseExprCEcoVars expr)
                (Mono.eraseCEcoVarsToErased t)

        Mono.MonoTailFunc params expr t ->
            Mono.MonoTailFunc
                (List.map (\( n, ty ) -> ( n, Mono.eraseCEcoVarsToErased ty )) params)
                (eraseExprCEcoVars expr)
                (Mono.eraseCEcoVarsToErased t)

        -- Do NOT patch: cycles (preserve MONO_021 visibility), ports (ABI obligations),
        -- externs/managers (kernel ABI), ctors/enums (no MVars in practice)
        _ ->
            node
```

Cycles are explicitly excluded from both patchers — if a benign polymorphic-key cycle case arises in the future, a dedicated cycle-aware fix can be added then.

### Step 5: Update `patchedNodes` in `monomorphizeFromEntry`

**File**: `compiler/src/Compiler/Monomorphize/Monomorphize.elm`
**Location**: Lines 125–135 (the `patchedNodes` binding)

Replace the current two-branch logic with a three-branch version:

```elm
patchedNodes : Dict Int Int Mono.MonoNode
patchedNodes =
    Dict.map
        (\specId node ->
            let
                isValueUsed =
                    BitSet.member specId valueUsedWithMain

                maybeEntry =
                    Array.get specId oldReg.reverseMapping |> Maybe.andThen identity

                keyHasCEcoMVar =
                    case maybeEntry of
                        Just ( _, keyType, _ ) ->
                            Mono.containsCEcoMVar keyType

                        Nothing ->
                            False
            in
            if isValueUsed then
                if keyHasCEcoMVar then
                    -- Value-used, polymorphic key: erase only CEco MVars (phantom)
                    patchNodeTypesCEcoToErased node
                else
                    -- Value-used, monomorphic key: keep MVars visible for MONO_021
                    node
            else
                -- Dead-value spec: erase ALL MVars to MErased
                patchNodeTypesToErased node
        )
        finalState.nodes
```

Note: `oldReg` binding already exists in the `patchedRegistry` let-block (line 141). It needs to be moved up or the `patchedNodes` binding needs access to `finalState.registry` directly.

The registry rebuild logic (lines 137–181) stays unchanged. Key collisions after erasure are semantically benign — they'd only occur for specs differing solely in phantom type variable names, which have identical runtime behavior.

### Step 6: Update MONO_021 checker to accept `MErased`

**File**: `compiler/tests/TestLogic/Monomorphize/NoCEcoValueInUserFunctions.elm`
(The `build-xhr/tests/` copy is a symlink to `../tests`, so only one file needs editing.)

In `collectCEcoValueVars` (line 397–426), change the `MErased` branch:
```elm
-- Before:
Mono.MErased ->
    [ "<MErased>" ]

-- After:
Mono.MErased ->
    []
```

Update the module doc comment (lines 7–19) to reflect that `MErased` in reachable specs is now expected for erasable phantom type variables and is not a violation.

### Step 7: Update `MErased` doc comments

**File**: `compiler/src/Compiler/AST/Monomorphized.elm`

Update the doc comments at lines 189–192 and the inline comment on line 209 to reflect the new semantics: `MErased` may now appear in reachable specs when the spec's key type is polymorphic (phantom type variables). It is no longer exclusively for dead-value specializations.

### Step 8: Run tests

```bash
cd compiler && npx elm-test-rs --project build-xhr --fuzz 1
```

Verify:
- The 5 "benign unconstrained" cases pass MONO_021 (their CEcoValue MVars are now MErased)
- The cycle test case still fails MONO_021 (its key type is monomorphic, so MVars are not erased)
- No other regressions

---

## Files Modified

| File | Change |
|------|--------|
| `compiler/src/Compiler/AST/Monomorphized.elm` | Add `containsCEcoMVar`, `eraseCEcoVarsToErased` |
| `compiler/src/Compiler/Monomorphize/Monomorphize.elm` | Refactor erasure into parameterized `mapOneExprType`/`mapExprTypes`/`mapDestructorTypes`/`mapPathTypes`; add `patchNodeTypesCEcoToErased`, `eraseExprCEcoVars`; update `patchedNodes` to three-branch key-aware logic |
| `compiler/tests/TestLogic/Monomorphize/NoCEcoValueInUserFunctions.elm` | Update `collectCEcoValueVars` to allow `MErased`; update module doc |

---

## Resolved Questions

### Q1: Parameterize vs duplicate — RESOLVED: Parameterize
Introduce internal `mapOneExprType : (MonoType -> MonoType) -> MonoExpr -> MonoExpr` and `mapExprTypes` wrapper. Redefine `eraseExprTypeVars` and `eraseExprCEcoVars` as thin wrappers. Same for destructor/path erasure. No public API changes.

### Q2: MonoCycle in `patchNodeTypesCEcoToErased` — RESOLVED: Skip
Both patchers skip `MonoCycle`. If a benign polymorphic-key cycle arises later, a dedicated cycle-aware fix can be added then.

### Q3: 5 benign cases have polymorphic key types — RESOLVED: Yes
All 5 confirmed: wildcard lambda (`MFunction [MVar _ CEcoValue] MInt`), record-update lambda, partial application residual, standalone accessors (`.x`, `.y`), unused Either branch. All have `MVar _ CEcoValue` in their spec key types.

### Q4: Registry key collision risk — RESOLVED: Benign
Collisions would only occur for specs differing solely in phantom type variable names — identical runtime behavior. The `reverseMapping` retains both entries by index; pruning and MONO_005 invariants remain intact.

### Q5: `build-xhr/tests` — RESOLVED: Symlink
`build-xhr/tests` → `../tests` (confirmed symlink). Only one file to edit.

---

## Remaining Assumptions

1. **`oldReg` scoping**: The current `oldReg` binding is inside the `patchedRegistry` let-block. Step 5 needs `finalState.registry.reverseMapping` in the `patchedNodes` binding, which is defined *before* `patchedRegistry`. We'll reference `finalState.registry` directly (or extract `oldReg` to the outer let).

2. **Backend crash guards are sufficient**: The MLIR codegen has crash guards for `MErased` in `Types.elm:monoTypeToAbi` (line 175) and `monoTypeToOperand` (line 242), plus `TypeTable.elm:processType` (line 256). After this change, `MErased` will appear in value-used specs that survive pruning — but only in phantom positions that never reach ABI/operand conversion. These crashes are the intended safety net: if `MErased` ever does reach an operational position, it crashes loudly, catching any case where the phantom assumption was wrong.

3. **No other test logic treats `MErased` as a violation**: Verified that only `NoCEcoValueInUserFunctions.elm` flags `MErased` as a problem. Other test files (`RegistryNodeTypeConsistency.elm`, `MonoCtorLayoutIntegrity.elm`, `TailFuncSpecializationTest.elm`, `MonoTypeShape.elm`) handle `MErased` as a valid type variant for debug formatting. `GraphBuilder.elm` maps it to `"Erased"` for staging (benign). No other changes needed.

4. **`MErased` doc comment in `Monomorphized.elm`**: Lines 189–192 and 209 describe `MErased` as "must not appear in any reachable spec after pruning". This doc comment should be updated to reflect the new semantics: `MErased` may appear in reachable specs for phantom type variables whose spec key type is polymorphic.
