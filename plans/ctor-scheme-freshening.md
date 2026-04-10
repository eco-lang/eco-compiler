# Plan: Freshen Ctor SchemeInfo Specialization

## Problem

In `Compiler.Monomorphize.Specialize.specializeNode`, the `TOpt.Ctor` and `TOpt.Box` branches unify the constructor's **canonical** `canType` directly against `requestedMonoType` using the shared `mvarEnv`. This means the canonical MVarIds (e.g. `b` in `Just : b -> Maybe b`) get bound in `mvarEnv` on the first specialization and leak into subsequent ones.

Example: `Just 42.0` binds `b = Float`, then `Just (f value)` (where `f : Float -> Bool`) sees the stale `b = Float` instead of freshening to `b' = Bool`, producing wrong field types in the `CtorShape`.

By contrast, all other polymorphic globals (functions, defines) go through `getOrBuildSchemeInfo` which freshens MVarIds per specialization via `buildSchemeInfo`/`refreshSchemeInfo`. Constructors are the only top-level polymorphic definitions that skip this.

## Solution

Bring constructors in line with the rest of the monomorphizer: use `getOrBuildSchemeInfo` + `TypeSubst.applySubst` on a freshened scheme, instead of unifying canonical MVarIds directly.

## Scope

**Single file:** `compiler/src/Compiler/Monomorphize/Specialize.elm`

No changes to `State.elm`, `TypeSubst.elm`, `Registry`, or codegen. All reused machinery (`SchemeInfo`, `SchemeInfoCache`, `buildSchemeInfo`, `refreshSchemeInfo`) is already defined and working.

---

## Steps

### Step 1: Add helper `specializeCtorViaScheme`

Add a new helper function near the existing `specializeNode` function (after line ~714):

```elm
specializeCtorViaScheme : Name.Name -> Int -> Int -> Can.Type MVarId -> Mono.MonoType -> MonoState -> ( Mono.MonoNode, MonoState )
specializeCtorViaScheme ctorName tag arity canType requestedMonoType state =
```

Implementation:

1. **Reconstruct `TOpt.Global` from `state.ctx.currentGlobal`:**
   Pattern-match `Just (Mono.Global canonical name)` → `TOpt.Global canonical name`.
   Crash on `Nothing` — ctors are always specialized via the worklist which sets `currentGlobal`.

2. **Call `getOrBuildSchemeInfo canType (Just ctorGlobal) state`:**
   - On cache miss: `getOrBuildSchemeInfo` internally looks up `state.ctx.annotations` for the ctor's annotation type; if not found, falls back to `canType`. Either way, `buildSchemeInfo` freshens all MVarIds. Caches the result.
   - On cache hit: `refreshSchemeInfo` re-freshens MVarIds to a new family.
   - Result: `schemeInfo` with `schemeType` using fresh, unbound MVarIds.

3. **Unify freshened scheme type with requested mono type:**
   ```elm
   ( subst, mvarEnv1 ) = TypeSubst.unify state1.ctx.mvarEnv schemeInfo.schemeType requestedMonoType
   ```
   This only binds the scheme's fresh MVarIds — no canonical pollution.

4. **Apply substitution to get monomorphic ctor function type:**
   ```elm
   ( ctorMonoTypeRaw, mvarEnv2 ) = TypeSubst.applySubst mvarEnv1 subst schemeInfo.schemeType
   ctorMonoType = Mono.forceCNumberToInt ctorMonoTypeRaw
   ```
   Using `applySubst` (not `applySubstFV`) is safe because the scheme's MVarIds are unique — the free-var filtering was a workaround for the exact problem we're fixing.

5. **Build shape and result type (unchanged logic):**
   ```elm
   shape = buildCtorShapeFromArity ctorName tag arity ctorMonoType
   ctorResultType = extractCtorResultType arity requestedMonoType
   ```

6. **Thread `mvarEnv` through state** (update `state.ctx.mvarEnv` after both `unify` and `applySubst`).

7. **Return:** `( Mono.MonoCtor shape ctorResultType, stateFinal )`

### Step 2: Replace `TOpt.Ctor` branch (lines 697-714)

Replace the existing branch body with:
```elm
TOpt.Ctor index arity canType ->
    specializeCtorViaScheme ctorName (Index.toMachine index) arity canType requestedMonoType state
```

### Step 3: Replace `TOpt.Box` branch (lines 723-739)

Replace the existing branch body with:
```elm
TOpt.Box canType ->
    specializeCtorViaScheme ctorName 0 1 canType requestedMonoType state
```

### Step 4: Run compiler front-end tests

```bash
cd compiler && npx elm-test-rs --project build-xhr --fuzz 1 2>&1 | tee /tmp/test_output.txt
```

Check for compilation errors and test failures. Fix any issues.

### Step 5: Run full E2E tests

```bash
cmake --build build --target full 2>&1 | tee /tmp/e2e_output.txt
```

Verify:
- Previously-failing tests now pass: `MaybeMapFloatToBoolTest`, `MaybeMapToStringTest`, `MaybeMapTypeMismatchTest`
- Previously-passing tests remain green: `MaybeMapIntToBoolTest`, `MaybeMapStringToBoolTest`
- No regressions in other test suites

---

## Resolved Questions

1. **`currentGlobal` is always `Just` for ctors** — ctors are top-level nodes specialized via the worklist, which always sets `currentGlobal`. Crashing on `Nothing` is correct.

2. **Annotations may not exist for ctors** — that's fine. `getOrBuildSchemeInfo` falls back to `canType`, and `buildSchemeInfo` freshens canonical MVarIds regardless. No reintroduction of the old bug.

3. **`TOpt.Enum` has same pattern but is safe to skip** — enums have no fields, so the type parameter only affects the result type, not runtime representation. Optional follow-up for type hygiene, not required for this fix.

4. **`applySubst` vs `applySubstFV` is safe** — fresh scheme MVarIds can't collide with other schemes. The free-var filtering was a workaround for the canonical-id sharing we're eliminating.

5. **Only `Specialize.elm` changes** — all reused machinery is already in place; Registry and codegen consume `MonoCtor`/`CtorShape` opaquely.
