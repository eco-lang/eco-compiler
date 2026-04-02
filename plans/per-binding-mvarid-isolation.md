# Per-Binding MVarId Isolation in AssignMVarIds

## Problem

In `Compiler.Monomorphize.AssignMVarIds`, type variable name-to-MVarId mappings leak
across bindings that should be independent:

1. **Cycle members share env**: `TOpt.Cycle` passes one `ctx` through all value defs
   and func defs sequentially. If `s`, `k`, and `b` all use type vars named `a`/`b`/`c`,
   they get the *same* MVarIds, causing cross-contamination (e.g. `b = s (k s) k` sees
   `k`'s scheme variables as its own).

2. **Let-bound defs leak env outward**: `rewriteDef` threads `ctx` (including `env`)
   straight through and back to the caller. Multiple let-bound polymorphic defs in the
   same scope share env, so their identically-named type vars collide.

The result: downstream monomorphization can produce `i64`-vs-`f64` mismatches and
incorrect specializations when solver number variables or user-polymorphic variables
from different bindings are conflated.

## Goal

- **Per-binding independence**: Each binding (top-level def, cycle member, let-bound def)
  gets its own `env : Dict Name MVarId`. Two bindings never share env, so identically-named
  type vars produce distinct MVarIds.
- **Intra-binding coherence**: Within a single binding, all occurrences of the same type
  variable name (especially `number`, `number1`, etc.) map to one MVarId, preserving
  numeric ABI coherence.
- **Global state continuity**: `GlobalMVarState` (`nextId` + `constraints`) still threads
  through all bindings sequentially, so MVarIds are globally unique and constraints are
  recorded correctly.

## File to modify

`compiler/src/Compiler/Monomorphize/AssignMVarIds.elm` — all changes are local to this file.

## Implementation Steps

### Step 1: Add `withFreshBinding` helper

Add after the `Ctx` type alias (around line 43), before the ENTRY POINT section:

```elm
withFreshBinding : Ctx -> (Ctx -> ( a, Ctx )) -> ( a, Ctx )
withFreshBinding outerCtx work =
    let
        bindingCtx =
            { env = Dict.empty, state = outerCtx.state }

        ( result, bindingCtx1 ) =
            work bindingCtx
    in
    ( result, { env = outerCtx.env, state = bindingCtx1.state } )
```

**Semantics**: Runs `work` with an empty env (fresh binding scope), then discards the
binding-local env and restores the outer env, keeping only the evolved global state.

### Step 2: Isolate each value def in a Cycle

Replace `rewriteValueDefs` (lines 740-742). Currently it delegates to
`rewriteNamedExprList` which threads env across all defs.

New implementation — each value def gets a fresh env via `withFreshBinding`:

```elm
rewriteValueDefs : Ctx -> List ( Name, TOpt.Expr Name ) -> ( List ( Name, TOpt.Expr TypeIds.MVarId ), Ctx )
rewriteValueDefs ctx defs =
    List.foldl
        (\( name, expr ) ( acc, outerCtx ) ->
            let
                ( newExpr, outerCtx1 ) =
                    withFreshBinding outerCtx (\bindingCtx -> rewriteExpr bindingCtx expr)
            in
            ( ( name, newExpr ) :: acc, outerCtx1 )
        )
        ( [], ctx )
        defs
        |> Tuple.mapFirst List.reverse
```

Value defs in a cycle are `( Name, Expr )` pairs without a `Def` wrapper, so they don't
go through `rewriteDef`. The `withFreshBinding` here is the only isolation point for them.

### Step 3: `rewriteDefs` — no `withFreshBinding` needed

`rewriteDefs` (lines 745-757) just maps over defs calling `rewriteDef`. Since `rewriteDef`
itself will handle `withFreshBinding` (step 4), `rewriteDefs` stays as a simple fold that
threads only `state` — no redundant outer wrapping.

**No code change needed** — the existing `rewriteDefs` implementation is already correct
once `rewriteDef` handles its own isolation.

### Step 4: Isolate each Def/TailDef (the single scheme-root reset point)

Replace `rewriteDef` (lines 760-784). Currently it uses and mutates the caller's `ctx.env`,
leaking the binding's internal type var mappings outward.

`rewriteDef` is the single place where `withFreshBinding` is applied for function defs.
This covers both call sites: `rewriteDefs` (cycle func defs) and `TOpt.Let` (let-bound defs).

New implementation:

```elm
rewriteDef : Ctx -> TOpt.Def Name -> ( TOpt.Def TypeIds.MVarId, Ctx )
rewriteDef outerCtx def =
    case def of
        TOpt.Def region name body canType ->
            withFreshBinding outerCtx
                (\bindingCtx ->
                    let
                        ( newType, bindingCtx1 ) =
                            rewriteCanType bindingCtx canType

                        ( newBody, bindingCtx2 ) =
                            rewriteExpr bindingCtx1 body
                    in
                    ( TOpt.Def region name newBody newType, bindingCtx2 )
                )

        TOpt.TailDef region name args body canType maybeTvar ->
            withFreshBinding outerCtx
                (\bindingCtx ->
                    let
                        ( newType, bindingCtx1 ) =
                            rewriteCanType bindingCtx canType

                        ( newArgs, bindingCtx2 ) =
                            rewriteTrackedArgs bindingCtx1 args

                        ( newBody, bindingCtx3 ) =
                            rewriteExpr bindingCtx2 body
                    in
                    ( TOpt.TailDef region name newArgs newBody newType maybeTvar, bindingCtx3 )
                )
```

### Step 5: No changes needed

The following are already correct and require no modification:

- **`rewriteAnnotation`** (line 171): Already creates a fresh `env` from `Forall freeVars`.
- **`rewriteNodes`** (line 213): Already creates `{ env = Dict.empty, state = st }` per node.
- **`ensureMVarId`** (line 127): Allocation logic is unchanged.
- **`constraintFromName`** / **`freshMVarId`**: Unchanged.
- **Non-cycle node branches** in `rewriteNode`: Each is already one binding per node.

### Step 6: Test

Run the full E2E test suite:
```bash
cmake --build build --target full
```

Also run the compiler front-end tests:
```bash
cd compiler && npx elm-test-rs --project build-xhr --fuzz 1
```

Look specifically for:
- Regressions in combinator-heavy tests (SKI, church encodings)
- Numeric ABI mismatches (`i64` vs `f64` coercion errors)
- Any new monomorphization failures

## What does NOT change

- `GlobalMVarState` structure
- Constraint recording (`CNumber` vs `CEcoValue`)
- `KernelAbi.deriveKernelAbiMode` — still reads constraints by MVarId
- `TypeSubst.buildSchemeInfo` — freshens scheme vars from MVarEnv, unaffected
- MLIR codegen — sees correct, non-conflated MVarIds

## Resolved Design Decisions

### D1: Single `withFreshBinding` per binding — in `rewriteDef` only

`withFreshBinding` lives in `rewriteDef`, not in `rewriteDefs`. This is the single
scheme-root reset point. `rewriteDefs` just folds and threads state. No redundancy.

### D2: `TOpt.Let` call site — no changes needed

`TOpt.Let` (line 501) calls `rewriteDef ctx1 def`. After step 4, `rewriteDef` handles
its own `withFreshBinding`, so the let-bound def is automatically isolated. The returned
ctx has `env = ctx1.env` (outer env) plus evolved state. The body sees the outer env.

### D3: `rewriteNamedExprList` unchanged

Still used for expression-level `(Name, Expr)` pairs (record fields, call args) which
share the enclosing binding's env. These are not scheme roots. `rewriteValueDefs` no
longer delegates to it.

### D4: `maybeTvar` in `TailDef` — unchanged, correct as-is

`TailDef`'s `maybeTvar` is a solver node/variable ID (`IO.Pt n`), not a canonical type
TVar. It's used downstream in typed-optimization / tail-call analysis to recover the
function's solver variable, not as a monomorphization MVarId. No consumer expects an
MVarId there. Passing it through unchanged is correct.

### D5: Cycles and mutual recursion — independent schemes are safe

TypedOptimized already has fully-annotated types per definition; mutual-recursion
constraints are resolved by the HM solver before this phase. The monomorphizer does not
rely on cross-def MVarId equality — it renames callee type variables at each call site
via `getOrBuildSchemeInfo` and `unifyCallSiteWithRenaming`. Making each cycle member's
scheme independent is safe.
