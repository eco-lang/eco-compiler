# Fix Def-in-Cycle Specialization (Body TVar Aliasing)

## Problem

When specializing a `Def` inside a `TOpt.Cycle`, the substitution (`sharedSubst`) only has bindings for the **scheme TVars** (from `getDefCanonicalType`), not for the **body TVars** (from `meta.tipe` / `TOpt.typeOf`). These are alpha-equivalent types with different MVar IDs.

Result: recursive `VarCycle` calls inside the body see unresolved MVars, causing `enqueueSpec` to create a second, generic specialization (e.g., a boxed `foldrHelper` alongside the concrete Int-specialized one).

The `TailDef` path already handles this via `computeDefAliasMap` + `extendSubstWithAliases`. The `Def` path does not — that's the gap.

## Implementation Steps

### Step 1: Add `computeCycleDefAliasMap` helper

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`  
**Location:** After `computeDefAliasMap` (after line 2854), in the "CYCLE SPECIALIZATION HELPERS" section.

```elm
{-| Compute an alias map for a Def that appears in a Cycle.

    Links the canonical scheme type (4th field of TOpt.Def) to the body type
    (TOpt.typeOf expr). These are alpha-equivalent function types with
    potentially different MVarId families. The alias map ensures sharedSubst
    bindings propagate to the body TVars.

    Only used for Defs in cycles; local let-bound Defs use their existing
    specialization path.
-}
computeCycleDefAliasMap : TOpt.Def MVarId -> TypeSubst.MVarAliasMap
computeCycleDefAliasMap def =
    case def of
        TOpt.Def _ _ expr canType ->
            TypeSubst.linkSchemeToLocalType canType (TOpt.typeOf expr) Dict.empty

        _ ->
            Dict.empty
```

**Notes:**
- Uses the 4th field (`canType`) directly from the pattern match, not `getDefCanonicalType` (identical for `Def`, clearer in context).
- `linkSchemeToLocalType` walks both TLambda chains structurally, pairing corresponding TVars.
- For `Def`, the scheme type and body type are guaranteed to be alpha-equivalent (same TLambda shape, aliases already dealiased at this stage). If they ever diverge structurally, that's an internal bug — `linkSchemeToLocalType` silently falls through to its catch-all, producing an incomplete map. An assertion could be added later if needed.

### Step 2: Enrich `subst` in the `Def` branch of `specializeFuncDefInCycle`

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`  
**Location:** Lines 952–961 (the `TOpt.Def` branch of `specializeFuncDefInCycle`)

Replace:
```elm
        TOpt.Def _ _ expr _ ->
            let
                ( monoExpr, state1 ) =
                    specializeExpr expr subst state

                -- GlobalOpt will wrap bare expressions in closures via ensureCallableForNode
                actualType =
                    Mono.typeOf monoExpr
            in
            ( Mono.MonoDefine monoExpr actualType, state1 )
```

With:
```elm
        TOpt.Def _ _ expr _ ->
            let
                aliasMap =
                    computeCycleDefAliasMap def

                enrichedSubst =
                    TypeSubst.extendSubstWithAliases aliasMap subst

                ( monoExpr, state1 ) =
                    specializeExpr expr enrichedSubst state

                -- GlobalOpt will wrap bare expressions in closures via ensureCallableForNode
                actualType =
                    Mono.typeOf monoExpr
            in
            ( Mono.MonoDefine monoExpr actualType, state1 )
```

**How it works:**
- `subst` is `sharedSubst` from `specializeFunctionCycle`, built by unifying the scheme type with `requestedMonoType`. It has bindings for scheme TVars only.
- `computeCycleDefAliasMap` maps body TVars -> scheme TVars.
- `extendSubstWithAliases` copies bindings: for each alias `(bodyTVar -> schemeTVar)`, if `schemeTVar` has a binding in `subst` and `bodyTVar` does not, insert `bodyTVar -> monoType`.
- Now `specializeExpr` (and downstream `applySubstFV`) sees bindings for body TVars, so `VarCycle` nodes resolve to fully concrete `MonoType`s.

### Step 3: Add targeted regression test

**Location:** `compiler/tests/TestLogic/Monomorphize/`

Add a test that validates: for a `Def`-in-`Cycle` specialized at a concrete type, only **one** specialization is produced and its `MonoType` contains no residual MVars.

**Test approach (checker module):**
1. Run pipeline to mono on a minimal Elm module containing a mutual recursion cycle where at least one member is a `Def` (not `TailDef`), instantiated at a concrete type like `Int` or `List Int`.
2. Inspect the `MonoGraph` registry: for the cycle function, assert exactly one `SpecId` exists for the concrete type.
3. Optionally assert no `MVar` appears in the node's `MonoType`.

**Minimal reproducer template:** A trimmed version of `List.foldrHelper` — a lambda-wrapped recursive helper in a cycle, called from a concrete context like `List.filter (eq 5) [1,2,5]`.

Alternatively, an E2E test in the codegen suite that exercises `List.filter` on `Int` and checks correct runtime output, which would fail if the duplicate-spec / boxed-unboxed mismatch is present.

### Step 4: Build and test

```bash
cmake --build build --target full 2>&1 | tee /tmp/test_output.txt
```

Inspect for regressions. Key areas to watch:
- Cycle-related tests (any test exercising `List.foldr`, `List.filter`, mutual recursion)
- Monomorphization invariant tests (MONO_017, MONO_025, MONO_027)
- Codegen/runtime E2E tests

## Resolved Questions

1. **Structural congruence:** `canType` and `TOpt.typeOf expr` are guaranteed alpha-equivalent at this stage. Aliases are dealiased. If they diverge, it's an internal bug.
2. **4th field vs `getDefCanonicalType`:** Identical for `Def`; using the pattern-matched field directly.
3. **Test needed:** Yes — add a focused regression test, not just E2E coverage.
4. **`computeDefAliasMap` gap confirmed:** Returns `Dict.empty` for `Def`, matching the bug.

## Effect on Existing Code

- **TailDefs:** Unchanged. They already use `computeDefAliasMap` + `extendSubstWithAliases`.
- **Local defs (non-cycle):** Unchanged. `specializeDef`'s `Def` branch uses its own path.
- **`applySubstFV`:** No changes needed. It filters by free TVars of the target type; with the enriched subst, body TVars now have entries.
- **`extendSubstWithAliases`:** Skip-if-already-bound semantics prevent clobbering. Only adds entries for TVars actually present in the alias map.

## Files Modified

| File | Change |
|------|--------|
| `compiler/src/Compiler/Monomorphize/Specialize.elm` | Add `computeCycleDefAliasMap`; modify `Def` branch of `specializeFuncDefInCycle` |
| `compiler/tests/TestLogic/Monomorphize/` (new file) | Regression test for Def-in-Cycle alias propagation |
