# Plan: SpecKey Invariants + Container-Aware Specialization

## Goal

Two changes:
1. **SpecKeys always use the fully instantiated function `MonoType`** — enforce normalization and assert no residual `CNumber` vars at `enqueueSpec`.
2. **Container-aware unification** — refine the caller substitution from argument expression types so helpers like `foldrHelper` get distinct specializations for `List Int` vs `List String`.

## Problem

Today, when specializing helpers like `foldrHelper : (a -> b -> b) -> b -> Int -> List a -> b`:
- The callback type may collapse to `!eco.value -> !eco.value -> !eco.value` (from boxed kernels like `(==)`)
- The list argument ends up as `List !eco.value` in MonoType
- The helper's full function type is identical for both `List Int` and `List String` cases
- Identical SpecKeys → single specialization → wrong `list_head` projection types

## Steps

### Step 1: Normalize and assert at `enqueueSpec`

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`, function `enqueueSpec` (line ~172)

- Apply `Mono.forceCNumberToInt` to the incoming `monoType` before passing to `Registry.getOrCreateSpecId`.
- Add an assertion: after normalization, the type should not contain any `MVar _ CNumber`. The only surviving MVars should be `MVar _ CEcoValue` (genuinely polymorphic kernel ABI).
- Use `Mono.containsAnyMVar` and `Mono.containsCEcoMVar` for the check — if `containsAnyMVar && not containsCEcoMVar`, that means a non-CEcoValue MVar (i.e. CNumber) leaked through.
- Use `Utils.Crash.crash` (single String arg) for the assertion, not `Debug.todo`.

```elm
enqueueSpec global rawMonoType maybeLambda state =
    let
        monoType =
            Mono.forceCNumberToInt rawMonoType

        _ =
            if Mono.containsAnyMVar monoType && not (Mono.containsCEcoMVar monoType) then
                Utils.Crash.crash
                    ("enqueueSpec: residual CNumber MVar in monoType: "
                        ++ Mono.monoTypeToDebugString monoType
                    )
            else
                ()

        accum = state.accum
        ( specId, newRegistry ) =
            Registry.getOrCreateSpecId global monoType maybeLambda accum.registry
    in
    ...
```

**Risk:** Low. `forceCNumberToInt` is idempotent — callers already do this. The crash assertion is a safety net that should never fire in correct code. Ensure `Utils.Crash` is imported.

### Step 2: Add `refineSubstFromArgExprs` helper

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`, near `processCallArgs` (~line 2327)

New function that takes the original `TOpt.Expr` arguments, their computed `argTypes` (MonoTypes), and the current substitution + MVarEnv, then unifies each argument's canonical type (`TOpt.typeOf expr`) with its monotype to enrich the substitution with container element type information.

**Must return both `Substitution` and updated `MVarEnv`** — `unifyExtend` → `unifyHelp` can allocate fresh MVarIds and update constraints via `insertBindingSafe` / `unifyMonoMono`. Discarding the updated env would cause stale constraint lookups or ID collisions downstream.

```elm
refineSubstFromArgExprs :
    State.MVarEnv
    -> List (TOpt.Expr MVarId)
    -> List Mono.MonoType
    -> Substitution
    -> ( Substitution, State.MVarEnv )
refineSubstFromArgExprs mvarEnv args argTypes subst =
    List.foldl
        (\( expr, argMono ) ( s, env ) ->
            TypeSubst.unifyExtend env (TOpt.typeOf expr) argMono s
        )
        ( subst, mvarEnv )
        (List.map2 Tuple.pair args argTypes)
```

**Why this is additive (not redundant with `processCallArgs`):**
- `processCallArgs` calls `applySubst` (Can.Type → MonoType) but does **not write back** into the Substitution — it only consumes `subst`.
- `refineSubstFromArgExprs` uses `unifyExtend`, which **does** push reverse bindings. For example, unifying `List a` (canonical) with `MList MInt` (mono) hits the `Can.TType _ _ args, Mono.MList inner` branch in `unifyHelp` and binds `a ↦ MInt`.
- This is the key mechanism: container element types from arg expressions flow back as type variable bindings.

### Step 3: Integrate refinement into the `TOpt.Call` case

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`, `specializeExpr` `TOpt.Call` branch (line ~1270)

After computing `processCallArgs`, refine the substitution **and thread the updated MVarEnv back into state**:

```elm
TOpt.Call region func args meta ->
    let
        canType = meta.tipe

        ( processedArgs, argTypes, state1 ) =
            processCallArgs args subst state

        -- Refine substitution with container element types from arg exprs
        ( substForCall, mvarEnv1 ) =
            refineSubstFromArgExprs state1.ctx.mvarEnv args argTypes subst

        -- Thread updated MVarEnv back into state before any further use
        state1r =
            let ctx = state1.ctx in
            { state1 | ctx = { ctx | mvarEnv = mvarEnv1 } }
    in
    case func of ...
```

Then apply these substitutions per sub-case:

#### 3a. Global calls (line ~1292)
- Replace `subst` → `substForCall` in `unifyCallSiteDirect`
- Replace `state1` → `state1r` in `getOrBuildSchemeInfo` and downstream

```elm
TOpt.VarGlobal funcRegion global funcMeta ->
    let
        funcCanType = funcMeta.tipe
        ( schemeInfo, state1a ) =
            getOrBuildSchemeInfo funcCanType (Just global) state1r
        ( callSubst, funcMonoTypeRaw, _ ) =
            TypeSubst.unifyCallSiteDirect state1a.ctx.mvarEnv schemeInfo.argTypes schemeInfo.resultType argTypes substForCall
        ...
```

#### 3b. Kernel calls (line ~1327)
- Replace `subst` → `substForCall` in `unifyCallSiteDirect`
- Replace `state1` → `state1r` in `getOrBuildSchemeInfo` and downstream

#### 3c. Debug calls (line ~1357)
- Same pattern as kernel calls

#### 3d. Local multi-target calls (line ~1409) — **SKIP refinement**

Do **not** use `substForCall` here. Keep using the original `subst` and `state1`.

**Rationale:** Local multi-target calls share MVarIds between def and uses (no freshening). Refinement bindings could collide with the callee's own type vars, breaking the "single scheme per binding" model. These calls already do the right "sharing" via `unifyArgsOnly`.

#### 3e. Non-local function fallback (line ~1440)
- Replace `subst` → `substForCall` in `unifyCallSiteDirect`
- Replace `state1` → `state1r` in `getOrBuildSchemeInfo` and downstream

**Summary of what changes per sub-case:**

| Sub-case | Use `substForCall`? | Use `state1r`? |
|---|---|---|
| 3a Global | Yes | Yes |
| 3b Kernel | Yes | Yes |
| 3c Debug | Yes | Yes |
| 3d Local multi-target | **No** (keep `subst`) | **No** (keep `state1`) |
| 3e Non-local fallback | Yes | Yes |

### Step 4: Audit all other `enqueueSpec` call sites

Search the codebase for all calls to `enqueueSpec` to confirm they pass a full function type (not a fragment). The normalization in Step 1 is the safety net, but we should verify no call site is passing a raw un-normalized type that differs from the function's true type.

### Step 5: Test

- Run the full E2E test suite: `cmake --build build --target full`
- Run compiler front-end tests: `cd compiler && npx elm-test-rs --project build-xhr --fuzz 1`
- Specifically watch for:
  - `List Int` vs `List String` getting distinct SpecIds for `foldrHelper` / `foldl` etc.
  - No `Utils.Crash.crash` assertions firing (CNumber leak)
  - No regressions in existing specialization behavior

## Resolved Design Decisions

### R1. MVarEnv threading — RESOLVED: Must thread

`unifyExtend` → `unifyHelp` can allocate fresh MVarIds and update constraints. The helper returns `( Substitution, MVarEnv )` and the updated env is threaded into `state1r` before any downstream use (`getOrBuildSchemeInfo`, `unifyCallSiteDirect`, etc.). This ensures `buildSchemeInfo` freshening uses an up-to-date env as seed.

### R2. Refinement is additive — RESOLVED: Confirmed

`processCallArgs` uses `applySubst` which consumes but does not extend the substitution. `refineSubstFromArgExprs` uses `unifyExtend` which does push reverse bindings. In the `List Int` / `List String` case: `unifyExtend` for `List a` vs `MList MInt` runs the `Can.TType .. args, Mono.MList inner` branch and binds `a ↦ MInt`. This is the missing binding that makes `foldrHelper` get distinct specializations.

### R3. Local multi-target — RESOLVED: Skip refinement

Local multi-target calls share MVarIds (no freshening). Extra refinement could collide with the callee's type vars. These calls already do the right sharing via `unifyArgsOnly`. Refinement is only applied for global, kernel, debug, and non-local fallback paths.

### R4. Interaction with deferred args — RESOLVED: Refine from all args

All arg expressions have valid `TOpt.typeOf` canonical types regardless of whether they become `ResolvedArg`, `PendingGlobal`, `PendingAccessor`, or `PendingKernel`. Unifying them is semantically correct in all cases. For `PendingAccessor`/`PendingKernel`, refinement may be redundant but is harmless. For `PendingGlobal` with containers, it can be genuinely useful.

### R5. Crash mechanism — RESOLVED: Use `Utils.Crash.crash`

Use `Utils.Crash.crash : String -> a` (single string argument) rather than `Debug.todo`. This is the project's standard for unrecoverable invariant violations. Ensure `import Utils.Crash` is added to Specialize.elm.

### R6. Stale env from getOrBuildSchemeInfo — RESOLVED: Not a problem

As long as `refineSubstFromArgExprs` returns its updated env and we thread it into `state1r` *before* `getOrBuildSchemeInfo`, the order is correct. `buildSchemeInfo` freshening only advances the MVarId counter for callee scheme vars — it doesn't touch caller var constraints.

### R7. Performance — RESOLVED: Accept for now, gate later if needed

N `unifyExtend` calls per call site is acceptable. Most canonical arg types are small. If profiling later shows a hotspot, gate refinement on a heuristic:
- Only run when the arg's `Can.Type` contains TVars (`collectMVarIds` non-empty) **and** the arg's `MonoType` contains containers (`MList`, `MCustom` with args, `MRecord`, `MTuple`) or `MVar`.
- This prunes primitive cases where no extra info can be gained.

Not implementing this gate initially — optimize only if measured.
