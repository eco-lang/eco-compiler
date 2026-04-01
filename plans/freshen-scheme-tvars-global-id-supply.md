# Freshen Scheme TVars Using Global MVarId Supply

## Problem

When `buildSchemeInfo` caches a `SchemeInfo` for a polymorphic callee, the scheme's
MVarIds are the callee's original ids from `AssignMVarIds`. If the caller's `subst`
already contains bindings for those same ids (because they happen to coincide with
caller-local ids), `unifyCallSiteDirect` sees stale bindings and produces wrong
specialization keys. This is the "scheme-cache contamination" bug.

## Solution (Option 3)

Freshen the scheme's MVarIds using the global `MVarEnv` id supply at
`buildSchemeInfo` time. Each fresh id is globally unique and cannot appear in any
caller's `subst`.

### Safety of cache-with-freshen-once

`callSubst` (result of `unifyCallSiteDirect`) is local to each call site — it is
never threaded back into the caller's `subst`. Specifically:

- `callSubst` is used locally to resolve processed args (`resolveProcessedArgs`),
  derive kernel ABI types (`deriveKernelAbiType`), and compute call result types
  (`callResultMonoType`).
- The *threading* substitution for specialization is `subst` (passed into
  `specializeExpr` / `specializeNode`), which is never overwritten with `callSubst`.
  It is only extended via `unifyExtend` in specific local places (value-multi, local
  fun args).
- `callResultMonoType` reads both `callerSubst` and `callSubst` but writes neither
  back.

So multiple call sites sharing the same cached SchemeInfo (same fresh ids) cannot
contaminate each other. No cache invalidation or per-call freshening is needed.

**Red flag to watch for:** If a future code path does
`specializeExpr body callSubst state` (replaces the specialization-wide `subst` with
`callSubst`), that would break this invariant. No such path exists today.

### Kernel/Debug schemes: freshened per call (no cache)

`VarKernel` and `VarDebug` pass `Nothing` to `getOrBuildSchemeInfo`, so they are not
cached. They build and freshen a `SchemeInfo` on every call. This is correct and the
per-call cost (collectMVarIds + small foldl for freshMVar + one rename traversal) is
negligible relative to specialization + codegen. No optimization needed unless
profiling shows otherwise.

---

## Steps

### Step 1: Add `renameMVarIdsInCanType` helper

**File:** `compiler/src/Compiler/Monomorphize/TypeSubst.elm` (near `collectMVarIds`)

Add a function that renames all `MVarId`s in a `Can.Type MVarId` using a
`Dict Int MVarId` (oldIdKey → freshId). Must handle all 7 `Can.Type` constructors:

- `TVar` — look up and replace
- `TLambda` — recurse both sides
- `TType` — recurse args
- `TRecord` — recurse field types AND the extensible-record `Maybe id`
- `TTuple` — recurse all elements
- `TAlias` — rename BOTH the `paramId` in each `( paramId, Type )` pair AND the
  `Type` positions, plus the alias body (`Filled`/`Holey`). This keeps the alias
  binder ids in sync with body usages (a proper alpha-renaming). Note:
  `collectMVarIds` only collects from `Type` positions, not `paramId`s, so the
  rename map is built from ids that appear in type positions — but any `paramId`
  that matches a collected id will be correctly renamed, and any dead `paramId`
  (not appearing in any type position) will pass through unchanged.
- `TUnit` — pass through

This mirrors the structure of `collectMVarIds` and existing traversals.

---

### Step 2: Add `buildSchemeRenaming` helper

**File:** `compiler/src/Compiler/Monomorphize/TypeSubst.elm` (near `buildSchemeInfo`)

```elm
buildSchemeRenaming :
    MVarEnv
    -> List MVarId
    -> ( Dict Int MVarId           -- oldIdKey -> freshId
       , List MVarId               -- fresh ids (reversed)
       , Dict Int Mono.Constraint  -- freshIdKey -> constraint
       , MVarEnv                   -- updated env
       )
```

For each original `MVarId`:
1. Look up its constraint via `State.lookupConstraint` (default `CEcoValue`)
2. Allocate a fresh id via `State.freshMVar` with that constraint
3. Record `oldKey → freshId` in the rename map
4. Record `freshKey → constraint` in the constraints dict

No `originalVarIds` tracking — omitted to keep the change minimal. Can be
reintroduced later if solver-driven MonoDirect or error reporting needs it.

---

### Step 3: Rewrite `buildSchemeInfo`

**File:** `compiler/src/Compiler/Monomorphize/TypeSubst.elm:783-817`

Change signature from:
```elm
buildSchemeInfo : MVarEnv -> Can.Type MVarId -> SchemeInfo
```
to:
```elm
buildSchemeInfo : MVarEnv -> Can.Type MVarId -> ( SchemeInfo, MVarEnv )
```

New implementation:
1. `collectMVarIds canType []` to get original ids
2. `buildSchemeRenaming env origVarIds` to allocate fresh ids and build rename map
3. `renameMVarIdsInCanType renameMap canType` to get renamed scheme type
4. `flattenTLambda renamedSchemeType []` to get arg/result types in terms of fresh ids
5. Construct `SchemeInfo` with fresh `varIds`, fresh `constraints`
6. Return `( schemeInfo, updatedEnv )`

`SchemeInfo` record is unchanged — no new fields added. Update the module's export
list if needed (signature change is visible to importers).

---

### Step 4: Update `getOrBuildSchemeInfo` to thread `MVarEnv`

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm:71-95`

Both branches (cache miss for globals + local/anonymous) must:
1. Destructure `( info, mvarEnv1 ) = TypeSubst.buildSchemeInfo ...`
2. Update `state.ctx.mvarEnv` with `mvarEnv1`

Cache hit branch: no change (returns cached info as before).

Pattern for updating ctx:
```elm
let ctx = state.ctx in { ctx | mvarEnv = mvarEnv1 }
```

---

### Step 5: Update comments

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`

Update all instances of:
- `"no renaming needed with global MVarIds"` (line ~1222) → explain that scheme
  MVarIds are freshened by `buildSchemeInfo`, so they never collide with caller
  substitutions
- `"no renaming needed"` (lines ~1257, ~1287) → same
- `getOrBuildSchemeInfo` docstring (line ~68-70) → replace "no renaming is needed"
  with explanation that `buildSchemeInfo` freshens callee MVarIds

---

### Step 6: Verify and test

1. Run `cmake --build build --target full` — all existing E2E tests should pass
2. Run `cd compiler && npx elm-test-rs --project build-xhr --fuzz 1` — frontend tests
3. Specifically verify that combinator tests (`s`/`b`) produce distinct specializations
4. No `MONO_` violations or ABI mismatches from scheme-cache contamination

---

## Files modified (summary)

| File | Change |
|------|--------|
| `TypeSubst.elm` | Add `renameMVarIdsInCanType`, `buildSchemeRenaming`; rewrite `buildSchemeInfo` to return `( SchemeInfo, MVarEnv )` |
| `Specialize.elm` | Thread `MVarEnv` in `getOrBuildSchemeInfo`; update comments |

`State.elm` is **not modified** — `SchemeInfo` record stays as-is (no `originalVarIds`
field for now).

## Invariant: no code change needed in `unifyCallSiteDirect`

The fix is entirely on the scheme construction side. Because fresh ids are allocated
from the global supply (monotonically after `AssignMVarIds`), they are guaranteed
absent from any caller's `subst`. The `baseSubst` passed to `unifyCallSiteDirect`
will never contain bindings for scheme ids, eliminating the contamination path.
