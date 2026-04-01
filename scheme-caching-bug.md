# Scheme Caching Bug: E2E Combinator SIGSEGV Root Cause

**Date**: 2026-04-01

---

## Key finding: the `buildCurriedFuncType` truncation fix IS already applied

The code at `TypeSubst.elm:909-946` already resolves all remaining scheme arg types (lines 920-936). The fix from `mono-ids-fails.md` was already implemented. The monomorphizer produces correct types — confirmed by the test pipeline diagnostic showing `b` with arity 3 and `s` with two distinct specializations.

## The real bug is NOT type truncation — it's an incorrect specialization being used at a call site

### Evidence from the MLIR (`CombinatorBComposeTest`)

Inside `b_$_3`, the call `s (k_s) k arg0` references `s_$_9` which has signature:
```
s_$_9(!eco.value, !eco.value, i64) -> !eco.value
```
The third parameter is `i64`. But `arg0` is `!eco.value` (the function `square`). This is an **ABI type mismatch** — `s_$_9` was specialized for `x: Int` but is being called with `x: (Int→Int)`.

There are only two specializations of `s` in the E2E MLIR:
- `s_$_6(!eco.value, !eco.value, i64) -> i64`
- `s_$_9(!eco.value, !eco.value, i64) -> !eco.value`

Both have `i64` as third param. Neither has a fully-boxed version where all args are `!eco.value`.

### Evidence from the test pipeline (diagnostic output)

The test pipeline produces TWO DIFFERENT specializations of `s`:
- **SpecId 6**: `s` specialized at `bf: Int→Int→Int, uf: Int→Int, x: Int` — for the final computation
- **SpecId 9**: `s` specialized at higher-order function types — for the use inside `b`'s body where args are function-typed

Inside `b`'s node (Node 5), VarGlobal refs correctly point to:
- SpecId 9 for the call `s (k_s) k` (higher-order specialization)
- SpecId 6 for the `s` passed to `k` as a value

These are **distinct SpecKeys** because the `funcMonoType` computed by `unifyCallSiteDirect` is different in each context — function-type arguments produce distinct `MFunction` structures in the MonoType.

## Why the E2E path produces wrong specializations

The test pipeline and E2E path use identical monomorphizer code (`Compiler.Monomorphize.Monomorphize.monomorphize`). The difference must be in the input.

### Scheme caching (`getOrBuildSchemeInfo`)

`getOrBuildSchemeInfo` (`Specialize.elm:71-95`) **caches schemes by global name**:

```elm
getOrBuildSchemeInfo funcCanType maybeGlobal state =
    case maybeGlobal of
        Just global ->
            case Data.Map.get TOpt.toComparableGlobal global accum.schemeCache of
                Just info ->
                    ( info, state )   -- ← returns CACHED scheme, ignores funcCanType
                Nothing ->
                    ...build from funcCanType and cache...
```

The scheme contains `argTypes` extracted from the `funcCanType` passed at the FIRST call site. The `funcCanType` uses MVarIds from whichever definition's SchemeEnv was active during `AssignMVarIds`.

**The scheme caching is the vulnerability.** When `s` is called from two different definitions (`main` and `b`), the `funcCanType` at each call site uses different MVarIds (from different SchemeEnvs, reset per top-level definition at `AssignMVarIds.elm:219`). The first call to `s` caches the scheme; subsequent calls get the cached scheme with the first caller's MVarIds.

### The contamination path

`unifyCallSiteDirect` (`TypeSubst.elm:909`) takes `baseSubst` which is the **caller's substitution**:

```elm
( callSubst, funcMonoTypeRaw, _ ) =
    TypeSubst.unifyCallSiteDirect state1a.ctx.mvarEnv schemeInfo.argTypes schemeInfo.resultType argTypes subst
                                                                                                        ^^^^
                                                                            -- baseSubst = caller's subst!
```

When processing `b`'s body, `baseSubst` contains bindings from `b`'s specialization: e.g., `MVarId(4) → MInt, MVarId(5) → MInt, MVarId(6) → MInt`.

If the cached scheme's `argTypes` contain MVarIds that **collide** with `b`'s MVarIds (same integer IDs allocated from the global counter), the `baseSubst` contains pre-existing bindings for those scheme variables.

`unifyArgTypesZip` then calls `unifyHelp` which finds the pre-existing binding:

```elm
-- TypeSubst.elm:270-277
( Can.TVar mvarId, _ ) ->
    case Dict.get (Id.toComparable mvarId) subst of
        Just existingMono ->
            let (substWithTransitives, env1) =
                    unifyMonoMono env existingMono monoType subst     -- step A
            in
            insertBindingSafe env1 mvarId monoType substWithTransitives  -- step B
```

If `mvarId` is already bound to `MInt` (from `b`'s substitution) but the actual call-site arg is a function type, `unifyMonoMono` tries to unify `MInt` with a function type — which either fails silently or produces a corrupted substitution.

The result: `funcMonoType` for `s` inside `b`'s body gets computed with `MInt` where it should have a function type. This produces the SAME `funcMonoType` as the direct `Int`-typed call, leading to the SAME SpecKey and SAME SpecId — **incorrect specialization sharing**.

## The lifecycle of tvar instantiation

The monomorphizer's substitution lifecycle:

1. **`specializeNode`** (`Specialize.elm:541`): Creates `subst` by unifying the node's `canType` with `requestedMonoType`. This binds the node's own MVarIds.

2. **`specializeExpr`**: Threads `subst` through expression processing. For each `VarGlobal` call:

3. **`getOrBuildSchemeInfo`** (line 1220): Returns cached or freshly-built scheme. The scheme's `argTypes` and `resultType` contain canonical types with MVarIds from whatever definition first triggered the cache.

4. **`unifyCallSiteDirect`** (line 1224): Takes `baseSubst = subst` (the caller's substitution) and extends it with bindings from unifying scheme arg types against call-site arg types. Returns `callSubst`.

5. **`enqueueSpec`** (line 1242): Uses `funcMonoType` (computed from the unified scheme) as the SpecKey. If two different call sites produce the same `funcMonoType`, they share the same specialization.

**The problem**: Step 4 uses `baseSubst` which already contains bindings from Step 1. If the scheme's MVarIds (from Step 3's cache) happen to be the SAME integer IDs as bindings already in `baseSubst`, the unification in `unifyArgTypesZip` finds pre-existing bindings and unifies them with the arg types. This can produce incorrect results if the pre-existing binding maps `scheme_mvar → MInt` when the actual context requires `scheme_mvar → MFunction [MInt] MInt`.

**This is the contamination path**: the caller's substitution (`baseSubst`) leaks into the scheme's type variable resolution because the cached scheme may contain MVarIds that collide with the caller's MVarIds.

## Why the test pipeline avoids this

In the test pipeline, `SourceBuilder.makeModuleWithDefs` constructs ASTs that go through the same `AssignMVarIds`. But the MVarId allocation order may differ from the E2E path because `DMap.foldl` iterates in a different order than the full compiler's definition ordering. If the test pipeline's ordering ensures no MVarId collisions between `b`'s vars and the cached scheme's vars, the contamination doesn't occur.

## Proposed fix direction

The root cause is that `unifyCallSiteDirect` uses the **caller's substitution as baseSubst**, which can contain bindings that interfere with the cached scheme's MVarIds. The fix should either:

1. **Start with an empty substitution** for scheme unification (not the caller's), then merge results back — analogous to creating fresh flex vars for each instantiation in the solver.

2. **Don't cache schemes across definitions** — build a fresh scheme for each call site using the local `funcCanType` (which has the correct MVarIds for the current definition).

3. **Rename the cached scheme's MVarIds** to fresh IDs before unification, ensuring no collision with the caller's substitution.

Option 2 is the simplest but may have performance implications. Option 3 is the most principled — it's analogous to the solver's rigid/flex variable instantiation pattern where rigid vars persist and fresh flex vars are created at each instantiation.

## Relationship to mono-ids-fails.md

The `mono-ids-fails.md` report identified `buildCurriedFuncType` truncation as the root cause. That fix has been applied. But the report also noted (Group 2, "Array type variable scoping"):

> **ROOT CAUSE: `unifyMonoMono` uses `insertBinding` without occurs check** ... When MVarId 29 is already bound to `MVar 29` (self-referential, from polymorphic specialization `a → MVar 29`): Step A creates a cyclic binding without occurs check...

This is the same family of bugs — **caller substitution contaminating scheme unification** through shared MVarIds. The Group 2 fix (using `insertBindingSafe` instead of `insertBinding`) addresses one symptom. The scheme caching issue described here is a different manifestation of the same architectural problem: the monomorphizer does not create a clean binding scope for each call-site instantiation.
