# Plan: Prefer VarEnv for Local Variable Type Resolution in Specialize.elm

## Problem

When a local variable (lambda param, tail-def param, let-bound def, destruct root) is referenced
inside `specializeExpr`, its type is currently derived by applying the current `Substitution` to
the canonical type on the node (`meta.tipe` + `applySubstFV`). This can see a different MVarId
family (body node types) than the substitution keys (scheme MVarIds), causing residual MVars in
types that should be fully concrete — the "Family A" bug (e.g. `List.foldrHelper`).

## Invariant

Whenever a local variable is referenced, its type should come from the **monomorphic VarEnv**
(populated at binding time with correct scheme-side MVarIds) rather than by re-applying the
current Substitution to `meta.tipe`.

## File

All changes in `compiler/src/Compiler/Monomorphize/Specialize.elm`.

## Resolved Design Decisions

1. **`monoTypeFromMeta` when VarEnv hits**: Keep computing it unconditionally. The cost is
   tiny and the code stays simple. Could reorder to only compute in the fallback branch,
   but correctness doesn't depend on this — not worth complicating the code.

2. **`Nothing` fallback reachability**: Every bound local (lambda param, let-bound name,
   destructor root, pattern-bound var) is inserted into `varEnv` before use, so the
   `Nothing` branch should be rare or unreachable. Keep the meta-based fallback as a
   defensive path. No debug logging needed in the final version.

3. **Debug logging (`VARLOCAL_IN_FOLDR`)**: Purely diagnostic, not part of the fix.
   Not in the current baseline. Do not add it as part of this change.

4. **Value-multi targets**: Do NOT exclude value-multi from the VarEnv preference.
   For value-multi roots, `varEnv` is already populated with a preliminary monotype
   using the same `applySubstFV + forceCNumberToInt` pattern. Subsequent unifications
   only make that entry more concrete, so `envType` is always at least as precise as
   what we'd re-derive from `meta.tipe`. The "return the var as-is" comment is about
   not renaming to a fresh clone name, not about ignoring concrete types.

5. **`forceCNumberToInt` on `envType`**: Not needed. All VarEnv insertion points already
   store types that have gone through `forceCNumberToInt`. VarEnv always stores normalized
   monotypes — no redundant normalization call required.

## Steps

### Step 1: Update `TOpt.VarLocal` branch (line ~1111)

**Current** (non-local-multi path):
```elm
( Mono.MonoVarLocal name monoType, state )
```

**Change to:**
- Rename `monoType` → `monoTypeFromMeta` for clarity.
- In the non-local-multi `else` branch, attempt `State.lookupVar name state.ctx.varEnv`.
  - `Just envType` → use `envType`.
  - `Nothing` → fall back to `monoTypeFromMeta`.
- Local-multi path stays unchanged (still uses `monoTypeFromMeta` + `getOrCreateLocalInstance`).

```elm
TOpt.VarLocal name meta ->
    let
        canType =
            meta.tipe

        monoTypeFromMeta =
            Mono.forceCNumberToInt (applySubstFV state subst canType)
    in
    if isLocalMultiTarget name state then
        let
            ( freshName, state1 ) =
                getOrCreateLocalInstance name monoTypeFromMeta subst state
        in
        ( Mono.MonoVarLocal freshName monoTypeFromMeta, state1 )

    else
        case State.lookupVar name state.ctx.varEnv of
            Just envType ->
                ( Mono.MonoVarLocal name envType, state )

            Nothing ->
                ( Mono.MonoVarLocal name monoTypeFromMeta, state )
```

### Step 2: Update `TOpt.TrackedVarLocal` branch (line ~1131)

Mirror the same pattern as Step 1:

```elm
TOpt.TrackedVarLocal _ name meta ->
    let
        canType =
            meta.tipe

        monoTypeFromMeta =
            Mono.forceCNumberToInt (applySubstFV state subst canType)
    in
    if isLocalMultiTarget name state then
        let
            ( freshName, state1 ) =
                getOrCreateLocalInstance name monoTypeFromMeta subst state
        in
        ( Mono.MonoVarLocal freshName monoTypeFromMeta, state1 )

    else
        case State.lookupVar name state.ctx.varEnv of
            Just envType ->
                ( Mono.MonoVarLocal name envType, state )

            Nothing ->
                ( Mono.MonoVarLocal name monoTypeFromMeta, state )
```

### Step 3: Build & test

1. `cd compiler && npx elm-test-rs --project build-xhr --fuzz 1` — front-end tests.
2. `cmake --build build --target full` — full E2E tests.
3. Focus on previously-failing tests:
   - `EqualityIntPapWithStringChainTest`
   - `EqualityMultiTypePapTest`
   - `ListFilterTest`, `ListPartitionTest`
   - `IntegrationListEncodingTest`
   - `FloatSpecialValuesTest`
   - `TimerEffectTest`
4. Verify MLIR for `List.foldrHelper` has one concrete specialization per element type (no residual MVars).

### Step 4: Verify no regressions

- Confirm no new failures in the full E2E suite.
- Check monomorphization invariant tests (MONO_024: fully monomorphic specializations have no CEcoValue in reachable MonoTypes).

## What does NOT change

- `State.elm` — no modifications needed; `lookupVar`, `insertVar`, `VarEnv` already exist.
- Local-multi path — still uses `applySubstFV` on `meta.tipe` for call-site specialization keying.
- All VarEnv insertion points (lambda params, tail-def params, let defs, destruct roots) — already correct.
- `specializePath` / `specializeDtPath` — already use `State.lookupVar` exclusively.

## Why VarEnv is safe here

Every local binding site already inserts a monomorphic type into varEnv:
- `specializeLambda` (line ~577): inserts `monoParams` via `State.insertVar`.
- Tail defs (line ~993): inserts mono args into pushed frame.
- Let defs (lines ~1694, 1814, 1862, 1910, 2027, 2029): insert `defMonoType` before body.
- Destructors (line ~2065): insert `destructorType`.

The `Nothing` fallback preserves existing behavior for any edge case where a local has no varEnv entry.
