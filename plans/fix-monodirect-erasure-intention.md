# Fix MonoDirect Erasure Intention: Defer CEcoValue→MErased to Graph Assembly

## Problem Statement

MonoDirect monomorphization has **premature type erasure** during specialization.
The current code applies `eraseCEcoVarsToErased` inside `resolveFunctionTypeWithPhantomsErased`
at specialization time, converting `MVar _ CEcoValue` to `MErased` too early. This violates
the erasure intention: `MErased` should only be introduced during final graph assembly
(`assembleRawGraph`), never during expression specialization.

Current test results: 75 failures out of 9468 tests (all in MonoDirect-related suites).

### The erasure intention

`MErased` has a narrow, late-stage purpose:

1. **Dead-value specializations**: specs never value-used → all `MVar` erased to `MErased`
   via `patchNodeTypesToErased` in `assembleRawGraph`.
2. **Phantom CEcoValue vars for polymorphic keys**: value-used specs whose key type still
   contains `CEcoValue` → only `CEcoValue` `MVar` erased to `MErased` via
   `patchNodeTypesCEcoToErased` in `assembleRawGraph`.

**During specialization, `MErased` must never appear as a bare type for user code.**
Unconstrained boxed polymorphism is represented as `MVar _ CEcoValue` throughout
specialization. Only `assembleRawGraph` introduces `MErased`, after it knows each spec's
value-use and key-type status.

### What is currently wrong

The existing `resolveFunctionTypeWithPhantomsErased` helper (Specialize.elm:212-214):
```elm
resolveFunctionTypeWithPhantomsErased view meta =
    Mono.eraseCEcoVarsToErased (resolveType view meta)
```

This is called at:
- `specializeLambda` (line 613): function type for lambda params
- `specializeLet` TailDef branch (line 702): function type for tail-recursive params

This prematurely converts `MVar _ CEcoValue` → `MErased` during specialization, producing
`MFunction [MErased] MErased` where the correct output is `MFunction [MVar "a" CEcoValue] (MVar "b" CEcoValue)`.

**Effects of premature erasure:**
- SpecKeys diverge from Monomorphize (which applies `fillUnconstrainedCEcoWithErased` at a
  different granularity tied to scheme variables, not blanket erasure of all CEcoValue MVars)
- `assembleRawGraph`'s `patchNodeTypesCEcoToErased` finds fewer `MVar _ CEcoValue` to erase
  (they're already `MErased`), so the *composition* appears correct but the *intermediate
  representation* is wrong
- Comparison tests detect the structural mismatch in SpecKeys and node types

### Why MErased must never be bare during specialization

1. `flattenFunctionType MErased` yields `([], MErased)` — zero params. If a function's
   solver tvar somehow resolves to bare `MErased`, all lambda params vanish from VarEnv,
   causing "Root variable not found in VarEnv" crashes in `specializePath`.
2. `MErased` in expression types during specialization confuses downstream type projections
   (`computeIndexProjectionType`, `computeCustomFieldType`, record field lookups).
3. The distinction between `MVar _ CEcoValue` (boxed polymorphic, valid during specialization)
   and `MErased` (late erasure artifact) is meaningful and must be preserved until graph assembly.

## Design: Correct Time and Shape for Erasure

### During solver & specialization (MonoDirect specialization phase)

- Types returned by `resolveType` / `resolveDestructorType` must **never** be bare `MErased`.
- Unconstrained erased/boxed polymorphism is represented as `MVar _ CEcoValue`.
- Numeric polymorphism is resolved by `forceCNumberToInt`.
- If the solver ever returns bare `MErased` (a bug), reconstruct from canonical type.

### During final graph assembly (`assembleRawGraph`)

- Decide per-spec if it's:
  - Dead-value → erase all `MVar` via `patchNodeTypesToErased`.
  - Value-used with polymorphic key → erase only `CEcoValue` vars via `patchNodeTypesCEcoToErased`.
  - Value-used with monomorphic key → clean internal expressions via `patchInternalExprCEcoToErased`.

### At MLIR entry (after erasure)

- No reachable user function has `CEcoValue` or `MErased` in param/result positions (MONO_021).

## Implementation

### Step 1: Remove `resolveFunctionTypeWithPhantomsErased`

**File:** `compiler/src/Compiler/MonoDirect/Specialize.elm`

Delete the `resolveFunctionTypeWithPhantomsErased` helper (lines 205-214):
```elm
-- DELETE THIS ENTIRE FUNCTION:
resolveFunctionTypeWithPhantomsErased : LocalView -> TOpt.Meta -> Mono.MonoType
resolveFunctionTypeWithPhantomsErased view meta =
    Mono.eraseCEcoVarsToErased (resolveType view meta)
```

This function is the source of premature erasure.

### Step 2: Revert `specializeLambda` to use `resolveType`

**File:** `compiler/src/Compiler/MonoDirect/Specialize.elm`, line 613

Change:
```elm
funcMonoType =
    resolveFunctionTypeWithPhantomsErased view meta
```
to:
```elm
funcMonoType =
    resolveType view meta
```

Lambda parameters will now see `MVar _ CEcoValue` for unconstrained type variables,
preserving function structure for `flattenFunctionType` and VarEnv population.

### Step 3: Revert `specializeLet` TailDef to use `resolveType`

**File:** `compiler/src/Compiler/MonoDirect/Specialize.elm`, line 702

Change:
```elm
funcMonoType =
    resolveFunctionTypeWithPhantomsErased view { tipe = defCanType, tvar = defTvar }
```
to:
```elm
funcMonoType =
    resolveType view { tipe = defCanType, tvar = defTvar }
```

Same rationale: TailDef function params should see `MVar _ CEcoValue`, not premature `MErased`.

### Step 4: Harden `resolveType` against bare `MErased`

**File:** `compiler/src/Compiler/MonoDirect/Specialize.elm`

Replace `resolveType` with a version that defensively catches bare `MErased` from the solver
and reconstructs from canonical type:

```elm
resolveType : LocalView -> TOpt.Meta -> Mono.MonoType
resolveType view meta =
    let
        rawType =
            case meta.tvar of
                Just tvar ->
                    view.monoTypeOf tvar

                Nothing ->
                    if isMonomorphicCanType meta.tipe then
                        KernelAbi.canTypeToMonoType_preserveVars meta.tipe
                    else
                        Utils.Crash.crash
                            ("MonoDirect.resolveType: missing solver tvar for polymorphic type "
                                ++ Debug.toString meta.tipe
                            )

        normalized =
            Mono.forceCNumberToInt rawType
    in
    case normalized of
        Mono.MErased ->
            -- MonoDirect should never see top-level MErased from the solver.
            -- Erasure of CEcoValue variables is handled later in assembleRawGraph.
            -- Reconstruct from canonical type to preserve function structure.
            Mono.forceCNumberToInt (KernelAbi.canTypeToMonoType_preserveVars meta.tipe)

        _ ->
            normalized
```

This defensive guard catches the case where `monoTypeOf` returns bare `MErased` (which
should not happen with the current `canTypeToMonoType Dict.empty` implementation, but
guards against future regressions or solver changes).

### Step 5: Harden `resolveDestructorType` against bare `MErased`

**File:** `compiler/src/Compiler/MonoDirect/Specialize.elm`

Replace `resolveDestructorType` with the same defensive pattern:

```elm
resolveDestructorType : LocalView -> TOpt.Meta -> Mono.MonoType
resolveDestructorType view meta =
    let
        rawType =
            case meta.tvar of
                Just tvar ->
                    view.monoTypeOf tvar

                Nothing ->
                    KernelAbi.canTypeToMonoType_preserveVars meta.tipe

        normalized =
            Mono.forceCNumberToInt rawType
    in
    case normalized of
        Mono.MErased ->
            -- Destructors should never see a fully-erased type; reconstruct
            -- from canonical type to preserve record/ADT structure.
            Mono.forceCNumberToInt (KernelAbi.canTypeToMonoType_preserveVars meta.tipe)

        _ ->
            normalized
```

### Step 6: Verify `monoTypeOf` in SolverSnapshot never returns `MErased`

**File:** `compiler/src/Compiler/Type/SolverSnapshot.elm`

Current code (line 236-237):
```elm
monoTypeOfVar var =
    TypeSubst.canTypeToMonoType Dict.empty (typeOfVar var)
```

`canTypeToMonoType Dict.empty` (i.e., `applySubst Dict.empty`) maps:
- `Can.TVar name` with `CNumber` constraint → `MInt`
- `Can.TVar name` with `CEcoValue` constraint → `MVar name CEcoValue`
- Never produces `MErased`

**No code change needed here.** The current implementation is correct — it preserves
`MVar _ CEcoValue` for unconstrained type variables and never introduces `MErased`.
The defensive checks in Steps 4-5 are a safety net against future regressions.

### Step 7: Verify `assembleRawGraph` erasure composes correctly

**File:** `compiler/src/Compiler/MonoDirect/Monomorphize.elm`

With specialization now preserving `MVar _ CEcoValue` (instead of prematurely erasing to
`MErased`), the `assembleRawGraph` erasure passes become the **sole authority** for
CEcoValue→MErased conversion:

- Dead-value specs: `patchNodeTypesToErased` erases all `MVar` → `MErased`. ✓
- Value-used with polymorphic key: `patchNodeTypesCEcoToErased` erases `MVar _ CEcoValue`
  → `MErased`. Now does MORE work (previously some were already erased), same result. ✓
- Value-used with monomorphic key: `patchInternalExprCEcoToErased` cleans internal
  expression types, leaving node types unchanged. ✓

**No code change needed here.** The existing erasure logic is correct and will now
operate on the correct inputs (types with `MVar _ CEcoValue` rather than premature `MErased`).

### Step 8: Verify `deriveKernelAbiTypeDirect` kernel path

**File:** `compiler/src/Compiler/MonoDirect/Specialize.elm`, lines 1168-1205

The kernel ABI fallback produces `MVar _ CEcoValue` via `canTypeToMonoType_preserveVars`
when the solver type is not fully monomorphic. The `isFullyMonomorphicType` check
(lines 1208-1230) correctly returns `False` for `MVar _ _` and `True` for concrete types
and `MErased` (via the `_ -> True` catch-all).

**No code change needed here.** With specialization preserving `MVar _ CEcoValue`,
kernel types remain consistent: monomorphic types use solver-resolved values,
polymorphic types fall back to `canTypeToMonoType_preserveVars`.

## Files to Modify

1. **`compiler/src/Compiler/MonoDirect/Specialize.elm`**
   - Delete `resolveFunctionTypeWithPhantomsErased` helper
   - Revert `specializeLambda` line 613: `resolveType view meta` (not phantom-erased)
   - Revert `specializeLet` TailDef line 702: `resolveType view ...` (not phantom-erased)
   - Harden `resolveType`: catch bare `MErased`, reconstruct from canonical type
   - Harden `resolveDestructorType`: same defensive pattern

2. **No changes to `SolverSnapshot.elm`** — `monoTypeOf` already preserves `MVar _ CEcoValue`.
3. **No changes to `Monomorphize.elm`** — `assembleRawGraph` erasure is already correct.
4. **No changes to `Monomorphized.elm`** — `isFullyMonomorphicType` handles `MErased` via catch-all.

## Testing Plan

1. Run the full test suite:
   ```bash
   cd compiler && npx elm-test-rs --project build-xhr --fuzz 1
   ```

2. Specifically verify:
   - All 11 VarEnv crash tests now pass (Root variable not found in VarEnv)
   - MonoDirect comparison tests improve or stay stable (comparison is post-assembly,
     so `assembleRawGraph` erasure normalizes `MVar _ CEcoValue` → `MErased` for both
     pipelines before comparison)
   - No new failures introduced in other test suites

3. If comparison mismatches remain after graph assembly, categorize and address as follow-up:
   - SpecKey differences → acceptable intermediate divergence
   - Node type differences → may indicate `assembleRawGraph` erasure is missing a case
   - Destructor type differences → check `resolveDestructorType` canonical fallback

## Resolved Questions

- **Comparison tests are post-assembly.** Both pipelines run their respective erasure passes
  before comparison, so intermediate `MVar _ CEcoValue` vs `MErased` differences during
  specialization are normalized away by `assembleRawGraph`.

- **SpecKey divergence is acceptable as an intermediate state.** The two pipelines may
  produce different SpecIds due to `MVar _ CEcoValue` vs `MErased` in key types, but this
  is expected. Both produce equivalent behavior.

- **Assume `assembleRawGraph` erasure is correct for now.** If post-assembly comparison
  reveals mismatches, those will be addressed as a separate follow-up.
