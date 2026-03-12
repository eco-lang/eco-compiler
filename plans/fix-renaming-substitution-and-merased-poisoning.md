# Fix Renaming/Substitution Alignment & MErased Poisoning

## Overview

Two interrelated bugs cause spurious `MErased` types to appear in monomorphized output, violating MONO_024 and MONO_025:

**Bug 1 (Renaming disconnect):** `unifyCallSiteWithRenaming` produces a `callSubst` with bindings keyed by *renamed* TVar names (e.g. `"a__def_prefix_0"` or `"a__callee0_0"`), but when `specializeExpr func callSubst` re-specializes the callee, the callee's `Can.Type` annotations use *original* names (`"a"`, `"b"`). So `applySubst callSubst (TVar "a")` finds no binding, defaults to `MVar "a" CEcoValue`, and eventually gets erased to `MErased`.

**Bug 2 (MErased poisoning):** In `unifyHelp`, the `(TVar name, _)` branch unconditionally calls `insertBindingSafe name monoType` even when the new `monoType` is `MErased` and there's already a concrete binding. This overwrites good concrete types with `MErased`.

## Affected invariants

- **MONO_024**: Fully monomorphic specs must have no CEcoValue anywhere
- **MONO_025**: Closure MonoType must match specialization key
- **MONO_020**: No CEcoValue MVar in reachable user-defined local functions
- **MONO_021**: No CEcoValue MVar in user-defined function types (post-erasure)

## Decisions

- **VarGlobal branch gets reverse renaming:** Yes. Apply reverse renaming at all 4 call sites for correctness and consistency.
- **`unifyMonoMono` MErased guard:** Deferred. The `unifyHelp` guard is the true gatekeeper; revisit only if testing reveals issues.
- **Test scope:** 3 targeted test cases for now. More can be added later after comparing with existing coverage.

---

## Bug 1 Fix: Reverse-Rename Merge

### Root Cause

In `Specialize.elm` at the non-global `TOpt.Call` fallback (line 1239–1272), after `unifyCallSiteWithRenaming` produces `callSubst`, the code calls `specializeExpr func callSubst`. The `func`'s internal canonical types still use original TVar names (`"a"`, `"b"`), but `callSubst` only has bindings for renamed names like `"a__def___local_0"`.

The same issue affects all 4 call sites. `callResultMonoType subst callSubst canType` uses `callSubst` with the original `canType`, and the `callResultMonoType` fallback path applies `callSubst` to `canType` when the caller's result has CEcoValue MVars. Without reverse renaming, this fallback finds no binding for original names.

### Design

Add a function `applyReverseRenaming` to `TypeSubst.elm` that takes the rename map (original → renamed) from the SchemeInfo and merges original-keyed bindings back into the substitution. For each original TVar name, look up the renamed name in `callSubst`, and if found, insert the same MonoType under the original name.

#### New function in `TypeSubst.elm`

```elm
applyReverseRenaming : Dict Name Mono.MonoType -> Data.Map.Dict String Name Name -> Dict Name Mono.MonoType
applyReverseRenaming subst renameMap =
    -- For each entry in renameMap (orig -> renamed),
    -- if callSubst has a binding for renamed, copy it to orig
    Data.Map.foldl identity
        (\orig renamed acc ->
            case Dict.get renamed acc of
                Just monoType ->
                    case Dict.get orig acc of
                        Nothing ->
                            Dict.insert orig monoType acc
                        Just existing ->
                            -- If already bound and identical, keep. Otherwise keep existing
                            -- (which was set by caller's context — caller wins).
                            acc
                Nothing ->
                    acc
        )
        subst
        renameMap
```

**Key detail:** The pre-rename map is stored in `SchemeInfo.preRenameMap` (maps `"a" -> "a__def_prefix_0"`). The per-call rename map (used in the conflict fallback path of `unifyCallSiteWithRenaming`) maps `"a" -> "a__callee0_0"`. Both are `Data.Map.Dict String Name Name`.

The function must work with whichever rename map was actually used. Since `unifyCallSiteWithRenaming` uses either the pre-rename map or a fresh per-call map (via `buildRenameMap`), we need to capture which map was used and pass it to `applyReverseRenaming`.

### Changes to `unifyCallSiteWithRenaming`

Currently returns `( callSubst, renamedFuncType, funcMonoType )`. We need to also return the rename map that was used, so the caller can reverse it. Change the return type to include the map:

```elm
unifyCallSiteWithRenaming : ... -> ( Substitution, Can.Type, Mono.MonoType, Data.Map.Dict String Name Name )
```

In the conflict branch, we already have `renameMap`. In the non-conflict branch, `info.preRenameMap` is the map. Return it as the 4th element.

### Changes to `Specialize.elm` — all 4 call sites

At each of the 4 call sites (VarGlobal, VarKernel, VarDebug, non-global fallback):

1. Destructure the 4-tuple: `( callSubst, funcCanTypeRenamed, directFuncMonoType, renameMapUsed )`
2. Compute `callSubstAligned = TypeSubst.applyReverseRenaming callSubst renameMapUsed`
3. Use `callSubstAligned` in place of `callSubst` for:
   - `resolveProcessedArgs`
   - `callResultMonoType`
   - `specializeExpr func` (only in the non-global fallback branch)

**VarKernel/VarDebug note:** `deriveKernelAbiType` takes `funcCanTypeRenamed` (already renamed) and `callSubst` (renamed-keyed). This pairing is correct as-is — both use the renamed namespace. Only the downstream consumers (`resolveProcessedArgs`, `callResultMonoType`) that mix `callSubst` with original-named `canType` need the aligned substitution.

### Files changed

1. **`compiler/src/Compiler/Monomorphize/TypeSubst.elm`**
   - Add `applyReverseRenaming` function
   - Add it to the module's export list

2. **`compiler/src/Compiler/Monomorphize/Specialize.elm`**
   - Update `unifyCallSiteWithRenaming` return type to include `renameMap`
   - At all 4 call sites, destructure the 4-tuple and call `TypeSubst.applyReverseRenaming` on `callSubst` before using it

---

## Bug 2 Fix: Prevent MErased from Overwriting Concrete Bindings

### Root Cause

In `TypeSubst.unifyHelp` (line 266–387), the `(Can.TVar name, _)` case:

```elm
( Can.TVar name, _ ) ->
    case Dict.get name subst of
        Just existingMono ->
            let
                substWithTransitives =
                    unifyMonoMono existingMono monoType subst
            in
            insertBindingSafe name monoType substWithTransitives

        Nothing ->
            insertBindingSafe name monoType subst
```

The call to `insertBindingSafe name monoType substWithTransitives` at line 276 unconditionally overwrites the existing binding with the new `monoType`. When the new type is `MErased` (from an argument like `[] : List MErased`) and the existing binding is a concrete type (from another argument), the concrete type is destroyed.

### Design

Guard `insertBindingSafe` so that `MErased` never overwrites a non-erased binding:

```elm
( Can.TVar name, _ ) ->
    case Dict.get name subst of
        Just existingMono ->
            let
                substWithTransitives =
                    unifyMonoMono existingMono monoType subst
            in
            case ( existingMono, monoType ) of
                -- New type is MErased, existing is concrete: keep existing
                ( _, Mono.MErased ) ->
                    substWithTransitives

                -- Existing is MErased, new is concrete: upgrade to concrete
                ( Mono.MErased, _ ) ->
                    insertBindingSafe name monoType substWithTransitives

                -- Both non-erased: default behavior (overwrite with new)
                _ ->
                    insertBindingSafe name monoType substWithTransitives

        Nothing ->
            insertBindingSafe name monoType subst
```

### Interaction with `fillUnconstrainedCEcoWithErased`

The existing function `fillUnconstrainedCEcoWithErased` (line 581) only inserts `MErased` for names **not already in subst** (`if Dict.member name acc then acc`). With Bug 2's fix, `MErased` also cannot enter via unification when a concrete binding exists. Together, this ensures `MErased` only appears for genuinely unconstrained type variables.

### Interaction with `unifyMonoMono`

`unifyMonoMono` (line 399) also has a catch-all `_ -> subst` case. When called with `(MTuple [...], MErased)`, neither side is `MVar`, and it falls into the catch-all, returning `subst` unchanged. This is fine — the catch-all means "these structures don't match, don't add new bindings." The problem was only in the caller (`unifyHelp`) which then overwrote regardless.

No changes to `unifyMonoMono` — deferred unless testing reveals issues.

### Files changed

1. **`compiler/src/Compiler/Monomorphize/TypeSubst.elm`**
   - Modify the `(Can.TVar name, _)` branch of `unifyHelp` to guard against MErased overwriting

---

## Implementation Steps

### Step 1: Fix `unifyHelp` TVar branch (Bug 2)

File: `compiler/src/Compiler/Monomorphize/TypeSubst.elm`, function `unifyHelp`, lines 268–279.

Replace the `Just existingMono` sub-branch with the guarded version above. This is a self-contained change with no API changes.

### Step 2: Add `applyReverseRenaming` to TypeSubst.elm (Bug 1)

File: `compiler/src/Compiler/Monomorphize/TypeSubst.elm`.

Add the new function near `buildSchemeInfo` (after line ~847). Add it to the module's export list on line 1–11.

The function signature:

```elm
applyReverseRenaming : Dict Name Mono.MonoType -> Data.Map.Dict String Name Name -> Dict Name Mono.MonoType
```

It iterates the rename map entries, and for each `(orig, renamed)` pair, copies the binding for `renamed` into `orig` (if not already bound in the substitution).

### Step 3: Update `unifyCallSiteWithRenaming` return type (Bug 1)

File: `compiler/src/Compiler/Monomorphize/Specialize.elm`, function `unifyCallSiteWithRenaming`, lines 174–211.

Change the return type from `( Substitution, Can.Type, Mono.MonoType )` to `( Substitution, Can.Type, Mono.MonoType, Data.Map.Dict String Name Name )`.

In the conflict branch (line 186–196), return the freshly-built `renameMap` as 4th element.
In the non-conflict branch (line 199–205), return `info.preRenameMap` as 4th element.

### Step 4: Update all 4 call sites in `Specialize.elm`

Call sites at lines 1095, 1132, 1163, 1252. At each:

1. Destructure the 4-tuple: `( callSubst, funcCanTypeRenamed, directFuncMonoType, renameMapUsed )`
2. Compute `callSubstAligned = TypeSubst.applyReverseRenaming callSubst renameMapUsed`
3. Use `callSubstAligned` in place of `callSubst` for:
   - `resolveProcessedArgs`
   - `callResultMonoType`
   - `specializeExpr func` (only in the non-global fallback branch)

For VarKernel and VarDebug, `deriveKernelAbiType` continues to use the *non-aligned* `callSubst` with `funcCanTypeRenamed`, since both are in the renamed namespace.

### Step 5: Add tests

File: `compiler/tests/TestLogic/Monomorphize/`

Add test cases that exercise the specific scenarios:

1. **Polymorphic identity in record field** (Bug 1 scenario 3):
   ```elm
   main = let r = { fn = \x -> x } in r.fn 42
   ```
   Assert the closure's MonoType is `MFunction [MInt] MInt`, no MErased.

2. **makeAdder curried call** (Bug 1 scenario 5):
   ```elm
   makeAdder n = \x -> (n, x)
   main = makeAdder 5 3
   ```
   Assert inner closure type is `MFunction [MInt] (MTuple [MInt, MInt])`, no MErased.

3. **Fold with empty list** (Bug 2 scenario 11):
   ```elm
   myFoldl step init entries = ...
   main = myFoldl (\entry acc -> acc + 1) 0 []
   ```
   Assert the `step` parameter type retains concrete types, not `MErased`.

These tests should check MONO_024 (fully monomorphic specs have no CEcoValue) against these specific inputs.
