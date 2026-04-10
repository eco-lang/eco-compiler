# Wrong Constructor Specialization Bug

## Summary

`Maybe.map (\x -> x > 0) (Just 42.0)` crashes because the `Just` constructor
inside `Maybe.map`'s body is compiled with the **wrong type specialization**.
The codegen generates code to unbox a Float from the callback result, but the
result is actually a Bool (embedded constant), causing a null dereference in
`eco_resolve_hptr`.

## Evidence Chain

| Stage | What was traced | Result |
|-------|----------------|--------|
| **Monomorphizer (specializeExpr)** | `[VarGlobal Ctor]` on the `Just` expression inside `Maybe.map` | `canType=TType Maybe [TVar 222]`, `mono0=MCustom Maybe [MBool]` — **CORRECT** |
| **Monomorphizer (generateCall)** | `[CODEGEN call]` for all calls | `Maybe.map` return type `Maybe [MBool]` — **CORRECT**; `f value` returns `MBool` — **CORRECT** |
| **Codegen (generateSaturatedCall)** | specId, funcType, sigReturn for `Just (f value)` | `specId=6`, `funcType=MFunction [MBool] (Maybe [MFloat])` — **WRONG**; `sigReturn=Maybe [MFloat]` — **WRONG**; `sigParams=[MFloat]` — **WRONG** |
| **Codegen (generateSaturatedCall)** | Same for `Just 42.0` | `specId=2`, `sigReturn=Maybe [MFloat]`, `sigParams=[MFloat]` — **CORRECT** for Float |

## Root Cause

The `Just` constructor at **specId=6** (the one inside `Maybe.map`, supposed to
be `Just : Bool -> Maybe Bool`) has a **signature identical to specId=2**
(`Just : Float -> Maybe Float`). The signature at specId=6 has
`paramTypes=[MFloat]` and `returnType=Maybe [MFloat]`, not `[MBool]` /
`Maybe [MBool]`.

The monomorphizer correctly enqueues specId=6 with `MCustom Maybe [MBool]`. But
the compiled `MonoCtor` node at specId=6 in the MonoGraph has the Float types.

This means one of two things happened between `enqueueSpec` and the final
MonoGraph:

1. **`updateRegistryType`** (Monomorphize.elm line 446) overwrote specId=6's
   type with Float types after the node was compiled.
2. **The spec at specId=6 was compiled using the wrong requested type** —
   because the scheme cache returned stale MVarIds (the cache bug identified
   earlier), causing `unify` in the Ctor specialization path to resolve `b` to
   `Float` instead of `Bool`.

The stale scheme cache is the most likely root cause: `getOrBuildSchemeInfo`
caches the `Just` constructor's scheme with MVarIds that became bound to
`MFloat` during the first specialization (`Just 42.0`). When the second
specialization (`Just (f value)`) reuses the cached scheme, the MVarIds are
already bound to `MFloat`, and `unifyCallSiteDirect` or `unify` in the Ctor
path picks up the stale `MFloat` binding instead of the fresh `MBool`.

## Why the `refreshSchemeInfo` Fix Didn't Work

The Ctor specialization path (Specialize.elm lines 697–714) uses
`TypeSubst.unify` directly — it does NOT go through `getOrBuildSchemeInfo` or
the scheme cache. It unifies the constructor's canonical type with the requested
monoType:

```elm
subst = Tuple.first (TypeSubst.unify state.ctx.mvarEnv canType requestedMonoType)
```

The `canType` is `TLambda (TVar b) (TType Maybe [TVar b])`. The
`requestedMonoType` is `MCustom Maybe [MBool]`.

`TypeSubst.unify` resolves MVarIds through the global `mvarEnv`. If MVarId for
`b` was PREVIOUSLY bound to `MFloat` in the mvarEnv (from the first `Just 42.0`
call going through the scheme cache), then `unify` would see `b = MFloat` and
use that, producing `subst = {b: MFloat}` instead of `{b: MBool}`.

The `refreshSchemeInfo` fix only affects `getOrBuildSchemeInfo` calls (the
`VarGlobal` call-site path). It does NOT affect the `unify` call in the Ctor
specialization path, which reads from the SAME polluted mvarEnv.

## Proposed Fix

The fix needs to prevent stale MVarId bindings in the mvarEnv from leaking
between different specializations of the same polymorphic function/constructor.
Two approaches:

1. **Fix the scheme cache** (already implemented with `refreshSchemeInfo`) AND
   fix the Ctor specialization path to also use fresh MVarIds when unifying.
2. **Prevent `unifyCallSiteDirect`/`unify` from binding scheme MVarIds in the
   global mvarEnv** — use a local/temporary mvarEnv for scheme unification that
   doesn't persist.

Approach 2 is more robust: it addresses all code paths (call sites, Ctor
specialization, etc.) rather than patching each one individually.

## Reproducing E2E Tests

- `MaybeMapFloatToBoolTest` — `Maybe.map (\x -> x > 0) (Just 42.0)` — CRASH
  (resolve embedded Bool as heap Float)
- `MaybeMapToStringTest` — `Maybe.map String.fromInt (Just 42)` — CRASH
  (unbox String)
- `MaybeMapTypeMismatchTest` — `Maybe.map (\x -> x > 0) (Just 1.0)` — CRASH

Passing tests (input/output types happen to share ABI representation):
- `MaybeMapIntToBoolTest` — `Maybe.map (\x -> x > 0) (Just 42)` — PASS
  (Int and Bool both i64)
- `MaybeMapStringToBoolTest` — `Maybe.map String.isEmpty (Just "")` — PASS
  (String and Bool both eco.value)

## Files Involved

- `Compiler/Monomorphize/Specialize.elm` — `enqueueSpec` (correct), Ctor specialization path (lines 697–714, uses polluted mvarEnv)
- `Compiler/Monomorphize/TypeSubst.elm` — `buildSchemeInfo`/`refreshSchemeInfo`, `unify` (reads stale bindings from mvarEnv)
- `Compiler/Monomorphize/Monomorphize.elm` — `updateRegistryType` (line 446, may overwrite with wrong type)
- `Compiler/Monomorphize/Registry.elm` — `getOrCreateSpecId` (keying is correct)
- `Compiler/Generate/MLIR/Context.elm` — `extractNodeSignature` / `buildSignatures` (reads from MonoGraph nodes)
- `Compiler/Generate/MLIR/Expr.elm` — `generateSaturatedCall` (uses `sig.returnType` for result MLIR type)
