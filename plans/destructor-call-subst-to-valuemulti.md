# Plan: Thread Destructor Call-Site Substitutions Back Into Value-Multi Instances

## 1. Problem & Goal

When a let-bound value is value-multi-eligible and its destructors introduce *function*
locals (e.g. `getter`, `setter` from a pair), the destructors are called later in the
body. The call-site unification there discovers concrete types (e.g. record field
`a : MInt`), but today that information **does not flow back** into the
`ValueInstanceInfo.subst` that will be used to specialize the original let-bound def
at emit time. As a result, the nested lambdas inside `let` are specialized with still-
polymorphic types; unboxed-field layouts then diverge between producer and consumer.

Example:

```elm
let
    ( getter, setter ) =
        case loc of
            First  -> ( .a, \x m -> { m | a = x } )
            Second -> ( .b, \x m -> { m | b = x } )
in
    getter rec
    setter 99 rec
```

We want `getter`/`setter`'s call-site substitutions (binding `m ↦ MRecord { a = MInt,
b = MInt }`, etc.) to be merged into the value-multi root instance's `subst`, so that
when we emit the def `_v0` we re-derive its `MonoType` from `defCanType ∘ refined
subst` and specialize the body (including the inner `\x m -> ...` lambdas) with
concrete types.

**Target regression test:** `LetDestructFuncTupleTest`.

## 2. Files Touched

- `compiler/src/Compiler/Monomorphize/State.elm`
- `compiler/src/Compiler/Monomorphize/Specialize.elm`

No runtime, MLIR codegen, or invariants changes. Pure compiler-side bookkeeping.

## 3. Design Decisions (resolved)

These are no longer open — fix the implementation to match.

- **D1 Merge policy.** Do **not** invent an ad-hoc "merge two substitutions"
  function. Instead, refine directly by calling `TypeSubst.unifyArgsOnly` with
  `info.subst` as the starting substitution. `unifyArgsOnly` is monotone in the usual
  HM sense, so bindings only become more concrete, and we can't accidentally regress
  a concrete `MInt` back to an alias. We then overwrite `info.subst := newSubst` and
  `mvarEnv := newEnv` for that instance.
- **D2 Unifier choice.** For destructor calls use `TypeSubst.unifyArgsOnly` on
  `funcCanType = TOpt.typeOf func` with `argTypes` and base `info.subst`. Never use
  `unifyCallSiteDirect` on a destructor: it freshens/renames MVarIds and would emit a
  substitution whose keys don't line up with `info.subst`, silently producing a no-op.
  This means we add a *third* branch in the `TOpt.Call` fallback, checked before the
  existing `localMultiName` / scheme-direct branches: if `func` is a `VarLocal` /
  `TrackedVarLocal` whose name is a registered destructor on the `valueMulti` stack,
  take the destructor-call branch.
- **D3 Innermost wins.** `valueMulti` is already a stack with the innermost let at
  the head. When resolving a destructor name, walk the list head-to-tail and stop at
  the first `ValueMultiState` whose instances include a matching
  `derivedDestructorNames` entry. Only that instance gets refined.
- **D4 No aliasing support.** Calls through `let g2 = getter` aliases are out of
  scope: no extra machinery tracks "`g2` aliases `getter`." Those calls remain type-
  correct but won't contribute refinements. Document as a known limitation.
- **D5 No localMulti interaction.** `localMulti` is only pushed for `TOpt.Let` whose
  `defCanType` is `Can.TLambda`. Destructors arrive via `TOpt.Destruct` as locals,
  never as let-bound `Def`s, so `isLocalMultiTarget` is always `False` for destructor
  names. No special case required.
- **D6 Do not mutate `info.monoType`.** It stays the root container shape — used
  only as the instance key and, historically, as a second argument to
  `unifyExtend`. Emit-time instance MonoType is instead derived from `defCanType +
  info.subst` via `applySubstFV`. Container shape doesn't change when we learn field
  element types; those live in `info.subst`.
- **D7 Fail fast on missing instance keys.** `tagValueInstanceWithDestructor` must
  crash with a clear message if the instance key isn't present; silently skipping
  would reintroduce exactly the class of bugs this plan fixes. Mirror
  `updateValueMultiStack`'s crash style.
- **D8 Regression surface is small.** Non-function-destructor value-multi cases
  don't call destructors, so the new refinement path never fires. The only emit-time
  change that affects them is `info.monoType` → `applySubstFV info.subst defCanType`;
  for those cases the two coincide (info.subst contains only structural aliases from
  the destructor path). Still, add focused regression tests to lock this in.

## 4. Step-by-step Implementation Plan

### Step 4.1 — Extend `ValueInstanceInfo` (State.elm)

At `State.elm:286`:

```elm
type alias ValueInstanceInfo =
    { freshName : Name
    , monoType : Mono.MonoType
    , subst : Substitution
    , derivedDestructorNames : Set.Set Name
    }
```

Update the doc comment to describe the new field. `Set` is already imported.

### Step 4.2 — Initialize new field (Specialize.elm)

In `updateValueMultiStack` (line ~737), in the `Nothing` branch of the instance lookup:

```elm
newInfo =
    { freshName = freshName_
    , monoType = monoType
    , subst = currentSubst
    , derivedDestructorNames = Set.empty
    }
```

Confirm `Set` is imported in `Specialize.elm`; add if missing.

### Step 4.3 — Helper: tag an instance with a destructor name

Near `updateValueMultiStack`. Crashes on missing key per D7:

```elm
tagValueInstanceWithDestructor :
    Name                -- defName of the value-multi root
    -> String           -- instance key
    -> Name             -- destructor local name
    -> List ValueMultiState
    -> List ValueMultiState
tagValueInstanceWithDestructor defName instanceKey destructorName stack =
    case stack of
        [] ->
            Utils.Crash.crash
                ("Specialize.tagValueInstanceWithDestructor: defName not found: " ++ defName)

        entry :: rest ->
            if entry.defName == defName then
                case Dict.get instanceKey entry.instances of
                    Just info ->
                        let
                            newInfo =
                                { info
                                    | derivedDestructorNames =
                                        Set.insert destructorName info.derivedDestructorNames
                                }

                            newInstances =
                                Dict.insert instanceKey newInfo entry.instances
                        in
                        { entry | instances = newInstances } :: rest

                    Nothing ->
                        Utils.Crash.crash
                            ("Specialize.tagValueInstanceWithDestructor: instance key not found for "
                                ++ defName ++ " / " ++ instanceKey
                            )

            else
                entry :: tagValueInstanceWithDestructor defName instanceKey destructorName rest
```

### Step 4.4 — Helper: look up + refine the innermost destructor owner

Replaces the earlier `refineValueMultiFromDestructorCall`. This helper performs the
actual `unifyArgsOnly` refinement in one shot, per D1/D2/D3:

```elm
{-| If funcName is a destructor registered on the innermost valueMulti instance,
run `unifyArgsOnly` with that instance's subst as the base, overwrite the instance's
subst with the result, and return (newSubst, newMVarEnv, newStack) for the caller
to use. Returns `Nothing` if funcName is not a destructor on any stack entry.

Walks the stack head-to-tail (innermost-first) and stops at the first match.
-}
refineValueMultiForDestructorCall :
    Name                  -- destructor local name at call site
    -> Can.Type MVarId    -- destructor's canonical function type
    -> List Mono.MonoType -- monomorphic arg types at this call site
    -> MVarEnv
    -> List ValueMultiState
    -> Maybe ( Substitution, MVarEnv, List ValueMultiState )
```

Implementation sketch:

- Walk `stack` from head.
- For each `ValueMultiState`, scan its `instances` `Dict` for a
  `ValueInstanceInfo` whose `derivedDestructorNames` contains `funcName`.
- On first match: run
  `TypeSubst.unifyArgsOnly mvarEnv funcCanType argMonoTypes info.subst` →
  `( newSubst, newEnv )`. Overwrite `info.subst := newSubst`. Return
  `Just (newSubst, newEnv, updatedStack)`.
- If no match across the whole stack, return `Nothing`.

There's at most one match because innermost-wins and we stop immediately.

### Step 4.5 — Tag destructors at `TOpt.Destruct` creation

`Specialize.elm:2516`, inside the `Just ( rootName, rootCanType ) ->` branch.

- Capture `dname` in the irrefutable `Destructor` pattern at line ~2516 (currently
  `TOpt.Destructor _ destructorPath destructorMeta`).
- Immediately after `getOrCreateValueInstance`, compute
  `instanceKey = Mono.toComparableMonoType rootInstanceMonoType` and call
  `tagValueInstanceWithDestructor rootName instanceKey dname stateI.ctx.valueMulti`.
- Thread the updated stack into `stateI` (replace `stateI.ctx.valueMulti`) and
  continue with the existing `rewrittenDestructor` + `stateWithRoot` construction off
  that updated state.

### Step 4.6 — New destructor-call branch in `TOpt.Call` fallback

`Specialize.elm:~1930`, the `_` (fallback) branch after global/kernel/debug cases.

Re-structure the fallback as three branches (in order):

1. **Destructor-call branch** (new):
   - Extract `maybeFuncName` from `func` (Just for `VarLocal`/`TrackedVarLocal`,
     Nothing otherwise).
   - If `maybeFuncName = Just fname`, call
     `refineValueMultiForDestructorCall fname funcCanType argTypes state1r.ctx.mvarEnv state1r.ctx.valueMulti`.
   - If it returns `Just (callSubst, newEnv, newStack)`:
     - Build `state1d` with `ctx.mvarEnv := newEnv` and `ctx.valueMulti := newStack`.
     - Use `callSubst` as the call's substitution for the remainder:
       - `funcMonoType = Mono.forceCNumberToInt (applySubstFV state1d callSubst funcCanType)`
       - `paramTypes = TypeSubst.extractParamTypes funcMonoType`
       - `( monoArgs, state2 ) = resolveProcessedArgs processedArgs paramTypes callSubst state1d`
       - `resultMonoType = callResultMonoType state2.ctx.mvarEnv state2.ctx.currentFreeVars callSubst canType`
       - `( monoFunc, state3 ) = specializeExpr func callSubst state2`
     - Return `( Mono.MonoCall region monoFunc monoArgs resultMonoType Mono.defaultCallInfo, state3 )`.
   - Otherwise, fall through to (2).
2. **LocalMulti branch** (unchanged): existing `Just name` logic using
   `unifyArgsOnly` + `getOrCreateLocalInstance`.
3. **Non-local scheme branch** (unchanged): existing `unifyCallSiteDirect` logic.

This keeps destructor traffic on the shared-MVar `unifyArgsOnly` path and leaves
scheme-based call logic untouched.

### Step 4.7 — Re-derive instance MonoType at value-multi emit

`Specialize.elm:~2389` onward, the "we have instances" branch of the value-multi Let
case.

Per D6 — do not mutate `info.monoType`; only use it as instance key / shape hint.

1. In the per-instance fold that produces `instanceDefs`, compute a freshly-derived
   `instanceDefMonoType0` and feed it to `unifyExtend`:

```elm
instanceDefMonoType0 =
    Mono.forceCNumberToInt
        (applySubstFV stateAfterBody info.subst defCanType)

mergedSubst =
    Tuple.first
        (TypeSubst.unifyExtend
            state.ctx.mvarEnv
            defCanType
            instanceDefMonoType0
            info.subst
        )
```

2. In `stateWithVars`, insert `instanceDefMonoType0` (not `info.monoType`) into
   `varEnv` for each `info.freshName`.

### Step 4.8 — Tests

Per CLAUDE.md run discipline: one-shot, redirected to `/tmp/test_output.txt`.

- Primary: `LetDestructFuncTupleTest` must go green.
- Guardrails (D8):
  - A value-multi let whose pattern destructures a tuple/record of **plain
    (non-function)** values, never calling anything. Expect behavior identical to
    pre-change.
  - A value-multi let with a mixed tuple containing lambdas that are pattern-matched
    but never called. Expect the lambdas to still compile with their original
    polymorphic-ish monoTypes (no refinement fires).
  - Broader value-multi family run to catch incidental regressions.
- Run `cmake --build build --target full` (not `check`) so fresh MLIR is regenerated.

## 5. Expected Effect on the Motivating Example

For the `choose` example:

1. `TOpt.Let` pushes a valueMulti entry for `_v0`.
2. `TOpt.Destruct` for `getter`/`setter`: `getOrCreateValueInstance` allocates the
   instance; `tagValueInstanceWithDestructor` records `"getter"`/`"setter"` in
   `derivedDestructorNames`.
3. Calls `getter rec` / `setter 99 rec`: new destructor-call branch fires,
   `unifyArgsOnly` extends `info.subst` with bindings `m ↦ MRecord{...}`,
   `a ↦ MInt`, etc. Stack and `mvarEnv` carry the new state through the rest of the
   body.
4. `TOpt.Let` emit: `applySubstFV stateAfterBody info.subst defCanType` yields a
   concrete `MonoType` with `MInt` record fields. `specializeDef` runs with
   `mergedSubst` containing these concrete bindings, so nested lambdas see concrete
   types and generate correct unboxed record updates. Producer and consumer agree on
   layout.

## 6. Non-goals

- Changing the value-multi instance keying (still root `MonoType`).
- Re-architecting destructor representation.
- Alias tracking for `let g2 = getter`.
- Anything outside `State.elm` / `Specialize.elm`.

## 7. Known Limitations

- **Destructor aliasing** (D4): calls through `let g2 = getter` don't refine
  anything. Remains type-correct, just suboptimal unboxing. Documented here so the
  next reader doesn't rediscover it.
