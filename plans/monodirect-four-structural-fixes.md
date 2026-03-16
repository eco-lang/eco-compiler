# MonoDirect: Four Structural Fixes

This plan implements four root-cause fixes to align MonoDirect with the standard monomorphizer, eliminating competing type sources, normalizing poly-let handling, making accessor typing robust, and adding a shared joinpoint-flattening pass.

---

## Fix 1 – Single source of truth for types: `Can.Type + view.subst`

**Goal:** Eliminate competing notions of "the" type. All `MonoType` derivation goes through:
1. Principal `Can.Type` (from `Meta.tipe` / node metadata), and
2. A substitution (`view.subst`) computed via the solver snapshot.

This removes all runtime calls into `Type.variableToCanType` (avoiding `Error` crashes) and aligns MonoDirect's type shapes with the old monomorphizer.

### Step 1.1 – Rewrite `resolveType` in Specialize.elm

**File:** `compiler/src/Compiler/MonoDirect/Specialize.elm` (lines 237–258)

**Current** (three-way dispatch: `meta.tvar` → solver, monomorphic → preserveVars, polymorphic → subst):
```elm
resolveType view meta =
    let
        rawType =
            case meta.tvar of
                Just tvar -> view.monoTypeOf tvar
                Nothing ->
                    if isMonomorphicCanType meta.tipe then
                        KernelAbi.canTypeToMonoType_preserveVars meta.tipe
                    else
                        TypeSubst.canTypeToMonoType view.subst meta.tipe
    in
    Mono.forceCNumberToInt rawType
```

**Replace with** (always `Can.Type + view.subst`):
```elm
resolveType view meta =
    let
        instantiatedCanType =
            TypeSubst.applySubst view.subst meta.tipe
    in
    Mono.forceCNumberToInt instantiatedCanType
```

Note: `TypeSubst.applySubst` and `TypeSubst.canTypeToMonoType` are aliases (`canTypeToMonoType = applySubst`, both `Substitution -> Can.Type -> Mono.MonoType`). The substitution `view.subst` already encodes solver unification results, so the solver is still honored — just indirectly through the subst rather than via direct variable lookup.

### Step 1.2 – Rewrite `resolveDestructorType` in Specialize.elm

**File:** `compiler/src/Compiler/MonoDirect/Specialize.elm` (lines 2130–2144)

**Current** (uses `view.monoTypeOf tvar` when tvar is available, falls back to `canTypeToMonoType_preserveVars`):
```elm
resolveDestructorType view meta =
    case meta.tvar of
        Just tvar -> Mono.forceCNumberToInt (view.monoTypeOf tvar)
        Nothing -> Mono.forceCNumberToInt (KernelAbi.canTypeToMonoType_preserveVars meta.tipe)
```

**Replace with** (same approach as `resolveType`):
```elm
resolveDestructorType view meta =
    Mono.forceCNumberToInt (TypeSubst.applySubst view.subst meta.tipe)
```

### Step 1.3 – Rewrite `deriveKernelAbiTypeDirect` in Specialize.elm

**File:** `compiler/src/Compiler/MonoDirect/Specialize.elm` (lines 2426–2463)

**Current** uses `view.typeOf tvar` (for the Can.Type needed by `deriveKernelAbiMode`) and `view.monoTypeOf tvar` (for the MonoType). Both go through the solver's `Type.toCanTypeBatch`, which can crash on `Error` variables.

**Replace with:** Derive both from `meta.tipe + view.subst`:
```elm
deriveKernelAbiTypeDirect ( home, name ) meta view =
    let
        canType =
            meta.tipe

        monoType =
            Mono.forceCNumberToInt (TypeSubst.applySubst view.subst canType)

        mode =
            KernelAbi.deriveKernelAbiMode ( home, name ) canType

        isFullyMono =
            isFullyMonomorphicType monoType
    in
    case mode of
        KernelAbi.UseSubstitution ->
            monoType

        KernelAbi.NumberBoxed ->
            if isFullyMono then monoType
            else KernelAbi.canTypeToMonoType_preserveVars canType

        KernelAbi.PreserveVars ->
            if isFullyMono then monoType
            else KernelAbi.canTypeToMonoType_preserveVars canType
```

Note: `deriveKernelAbiMode` takes a `Can.Type` to inspect type variable structure (checking if the type is polymorphic). Passing `meta.tipe` (the principal type) is correct for this purpose — it retains the `TVar` names needed to determine polymorphism. The `Nothing` branch that crashes is removed — if `meta.tvar` is absent, we still proceed using `meta.tipe` directly.

### Step 1.4 – Rewrite `resolveMainType` in Monomorphize.elm

**File:** `compiler/src/Compiler/MonoDirect/Monomorphize.elm` (lines 100–108)

**Current:** `view.monoTypeOf tvar`

**Replace with:**
```elm
resolveMainType snapshot node =
    case nodeMetaTvar node of
        Just _ ->
            SolverSnapshot.withLocalUnification snapshot [] []
                (\view ->
                    let
                        canType = nodeCanType node
                        mono = TypeSubst.applySubst view.subst canType
                    in
                    Mono.forceCNumberToInt mono
                )

        Nothing ->
            Utils.Crash.crash "MonoDirect.resolveMainType: main node has no tvar"
```

### Step 1.5 – Simplify `LocalView` in SolverSnapshot.elm (optional but recommended)

**File:** `compiler/src/Compiler/Type/SolverSnapshot.elm` (lines 137–141, 253–276)

After Steps 1.1–1.4, `typeOf` and `monoTypeOf` on `LocalView` are no longer used by MonoDirect specialization code. They are only used indirectly by `deriveKernelAbiTypeDirect` which we've now rewritten.

**Option A (minimal):** Leave `LocalView` unchanged. The fields become dead code for MonoDirect but are harmless.

**Option B (clean):** Remove `typeOf` and `monoTypeOf` from `LocalView`, leaving only `subst`:
```elm
type alias LocalView =
    { subst : Dict String Mono.MonoType
    }
```

And simplify `buildLocalView`:
```elm
buildLocalView substDict _ =
    { subst = substDict }
```

**Decision needed:** Option B is cleaner but may break other code that uses `LocalView.typeOf`/`monoTypeOf` outside MonoDirect.

### Questions for Fix 1

1. **`deriveKernelAbiMode` and principal `Can.Type`:** `deriveKernelAbiMode` inspects the Can.Type to determine if a kernel is polymorphic. With the principal type (from `meta.tipe`), TVars are still present as `Can.TVar "a"` etc., so `deriveKernelAbiMode`'s polymorphism check will still work correctly. Is there a case where the solver-resolved Can.Type (with TVars replaced by concrete types) was needed by `deriveKernelAbiMode`, or is the principal type sufficient?

2. **LocalView simplification scope:** Are `view.typeOf` / `view.monoTypeOf` used anywhere outside MonoDirect (e.g., in standard monomorphizer code or tests)? If not, Option B is safe. If yes, we should keep the fields but just stop calling them from MonoDirect.

3. **`buildLocalView` still calling `Type.toCanTypeBatch`:** Even if MonoDirect no longer uses `typeOf`/`monoTypeOf`, the `buildLocalView` function still constructs them, meaning `Type.toCanTypeBatch` is still called. With Option A, the crash path through `Type.variableToCanType` still exists but just isn't hit. With Option B, it's removed entirely. Does the caller side (e.g., `withLocalUnification`, `specializeChainedWithSubst`) need these closures for any other purpose?

---

## Fix 2 – One uniform algorithm for poly let multi-specialization

**Goal:** Ensure let-bound polymorphic functions are always handled by a single algorithm — no "short-circuit" path that bypasses instance defs.

### Step 2.1 – Unify `specializeLetFuncDef` branches

**File:** `compiler/src/Compiler/MonoDirect/Specialize.elm` (lines 1445–1538)

**Current:** Two branches after body specialization:
- `Dict.isEmpty topEntry.instances` → single-instance fallback (re-specializes body without going through `specializeDefForInstance`)
- Else → multi-instance path via `specializeDefForInstance` per instance

**Change:** Always go through the multi-instance path.

After popping the `localMulti` stack entry:
```elm
case stateAfterBody.localMulti of
    topEntry :: restOfStack ->
        let
            statePopped =
                { stateAfterBody | localMulti = restOfStack }

            rawInstances =
                Dict.values topEntry.instances

            instancesList =
                case rawInstances of
                    [] ->
                        -- Synthesize a default instance for the principal type
                        [ { freshName = defName
                          , monoType = funcMonoType0
                          , subst = Dict.empty
                          }
                        ]

                    xs ->
                        List.sortBy
                            (\info -> Mono.monoTypeToDebugString info.monoType)
                            xs

            -- For each instance: re-specialize defExpr
            ( instanceDefs, stateWithDefs ) =
                List.foldl
                    (\info ( defsAcc, stAcc ) ->
                        let
                            ( monoDef, st1 ) =
                                specializeDefForInstance view snapshot
                                    defName defExpr info stAcc
                        in
                        ( monoDef :: defsAcc, st1 )
                    )
                    ( [], statePopped )
                    instancesList

            -- Register all instance names in VarEnv
            stateWithVars =
                List.foldl
                    (\info st ->
                        { st | varEnv = State.insertVar info.freshName info.monoType st.varEnv }
                    )
                    stateWithDefs
                    instancesList

            finalExpr =
                List.foldl
                    (\def_ accBody ->
                        Mono.MonoLet def_ accBody (Mono.typeOf accBody)
                    )
                    monoBody
                    instanceDefs
        in
        ( finalExpr, stateWithVars )
```

The key change: when `rawInstances` is empty, we synthesize a `LocalInstanceInfo` with `monoType = funcMonoType0` (the function's principal type in the current context) and `freshName = defName`. This ensures the exact same code path (via `specializeDefForInstance`) is taken regardless of instance count.

**Note on `funcMonoType0`:** The current `specializeLetFuncDef` doesn't compute `funcMonoType0` explicitly — for the single-instance fallback it just specializes `defExpr` directly. We need to compute it. It should be `resolveType view { tipe = defCanType, tvar = defTvar }` where `defCanType` comes from the `TOpt.Def`'s canonical type. Looking at the current code, `specializeLetFuncDef` receives `monoType` (the let-expression's result type, not the def's function type). We need the function's own type. This is available from the `defExpr` — if it's a `TOpt.Function`, its `funcMeta.tipe` gives the canonical function type and `funcMeta.tvar` gives the solver variable. So:
```elm
funcMonoType0 =
    resolveType view (TOpt.metaOf defExpr)
```

### Step 2.2 – Unify `specializeLetTailDef` branches

**File:** `compiler/src/Compiler/MonoDirect/Specialize.elm` (lines 1135–1210)

**Current:** Two divergent paths:
- `containsAnyMVar funcMonoType0` → polymorphic branch with local-multi discovery
  - Within that: `Dict.isEmpty topEntry.instances` → calls `specializeLetTailDefSingle`
  - Else → multi-instance via `specializeTailDefForInstance`
- No MVars → directly calls `specializeLetTailDefSingle`

**Change:** Apply the same normalization as for `specializeLetFuncDef`:

1. Inside the polymorphic branch (`containsAnyMVar funcMonoType0`), when `Dict.isEmpty topEntry.instances`, synthesize a default instance and go through `specializeTailDefForInstance` instead of `specializeLetTailDefSingle`:

```elm
if Dict.isEmpty topEntry.instances then
    let
        defaultInstance =
            { freshName = defName
            , monoType = funcMonoType0
            , subst = Dict.empty
            }

        instancesList = [ defaultInstance ]

        statePopped =
            { stateAfterBody | localMulti = restOfStack }

        ( instanceDefs, stateWithDefs ) =
            List.foldl
                (\info ( defsAcc, stAcc ) ->
                    let ( monoDef, st1 ) =
                            specializeTailDefForInstance view snapshot
                                defName defParams defBody defCanType defTvar info stAcc
                    in ( monoDef :: defsAcc, st1 )
                )
                ( [], statePopped )
                instancesList

        stateWithVars =
            List.foldl
                (\info st ->
                    { st | varEnv = State.insertVar info.freshName info.monoType st.varEnv }
                )
                stateWithDefs
                instancesList

        finalExpr =
            List.foldl
                (\def_ accBody -> Mono.MonoLet def_ accBody (Mono.typeOf accBody))
                monoBody
                instanceDefs
    in
    ( finalExpr, stateWithVars )
```

2. The concrete-type path (`else` of `containsAnyMVar`) can remain as-is (calling `specializeLetTailDefSingle` directly) since when the type is fully concrete, there's no polymorphism to handle — the function has exactly one shape. The design spec says: "You may still keep `specializeLetTailDefSingle` as a helper used when the TailDef is monomorphic... but inside the polymorphic branch there should be only one algorithm."

### Step 2.3 – Deterministic instance ordering

**File:** `compiler/src/Compiler/MonoDirect/Specialize.elm`

In both `specializeLetFuncDef` and `specializeLetTailDef`, when building `instancesList` from non-empty `Dict.values`, sort deterministically:
```elm
instancesList =
    Dict.values topEntry.instances
        |> List.sortBy (\info -> Mono.monoTypeToDebugString info.monoType)
```

This ensures comparison tests see consistent output regardless of Dict iteration order.

### Questions for Fix 2

1. **`funcMonoType0` in `specializeLetFuncDef`:** The current function doesn't have this computed. Should we derive it from `resolveType view (TOpt.metaOf defExpr)`, or from the `defCanType` in the `TOpt.Def`? The latter is available from the outer `specializeLet` which destructures `TOpt.Def defRegion defName defExpr defCanType`. Currently `specializeLetFuncDef` doesn't receive `defCanType` — we may need to pass it through, or compute from `defExpr`'s meta.

2. **Body re-specialization in the single-instance case:** The current single-instance fallback in `specializeLetFuncDef` re-specializes the body a second time (`monoBody2`) with `defName` bound. The multi-instance path does NOT re-specialize the body — it uses `monoBody` (from the first pass) directly. When we unify to the single path, should we:
   - (a) Keep using `monoBody` from the first pass (matching multi-instance behavior), or
   - (b) Re-specialize the body to get `monoBody2` with all instance names in scope?

   The design spec says to use `monoBody` from the first body specialization. This is consistent with how the multi-instance path works. But note: if the body references the function by name (not via a call-site that registers an instance), it may see an unresolved name. The standard monomorphizer presumably handles this. We should match its behavior.

3. **`specializeLetTailDefSingle` deletion:** The design says to "eliminate the distinct `specializeLetTailDefSingle` path" for the polymorphic branch but keep it for the monomorphic branch. Should we refactor `specializeLetTailDefSingle` to also go through `specializeTailDefForInstance` for consistency, or is the monomorphic case fine as-is since it produces the same structure anyway?

---

## Fix 3 – Robust accessor typing based on callee parameter types

**Goal:** Ensure accessor typing is derived from the callee's instantiated parameter types, not from whatever shape the argument happens to have.

### Step 3.1 – Verify `finishProcessedArgs` passes callee param types

**File:** `compiler/src/Compiler/MonoDirect/Specialize.elm`

The current `finishProcessedArgs` (lines 896–919) already walks `processedArgs` and `paramTypes` in lockstep, passing each `maybeParam` to `finishProcessedArg`. The `paramTypes` are extracted from `funcMonoType` via `Closure.flattenFunctionType` in `specializeCall`.

**Action:** Audit `specializeCall` to confirm that `paramTypes` passed to `finishProcessedArgs` are always the **callee's** parameter types (from `Closure.flattenFunctionType funcMonoType`), not the argument expression types. Based on the code structure, this appears to already be the case — `specializeCall` computes `funcMonoType` for the callee and extracts `paramTypes` from it.

No code change needed here if the audit confirms correctness.

### Step 3.2 – Generalize `extractRecordFields`

**File:** `compiler/src/Compiler/MonoDirect/Specialize.elm` (lines 998–1008)

**Current:**
```elm
extractRecordFields monoType =
    case monoType of
        Mono.MFunction [ Mono.MRecord fields ] _ -> fields
        Mono.MRecord fields -> fields
        _ -> Dict.empty
```

Only matches `MFunction` with exactly one arg that's an `MRecord`. If the function has multiple args, or the record is not the first arg, this fails silently.

**Replace with:**
```elm
extractRecordFields monoType =
    case monoType of
        Mono.MRecord fields ->
            fields

        Mono.MFunction args _ ->
            args
                |> List.filterMap
                    (\arg ->
                        case arg of
                            Mono.MRecord fields -> Just fields
                            _ -> Nothing
                    )
                |> List.head
                |> Maybe.withDefault Dict.empty

        _ ->
            Dict.empty
```

This finds the first record-typed parameter in any function type, regardless of arity or position.

### Step 3.3 – `resolveAccessor` unchanged

The `resolveAccessor` function (lines 962–995) remains unchanged. With `finishProcessedArg` passing the callee's param type (Step 3.1) and `extractRecordFields` being robust (Step 3.2), accessor resolution is now correct for all cases including let-bound accessors.

### Questions for Fix 3

1. **Is there ever a case where the callee's param type is an `MVar` (unresolved) at the accessor resolution point?** If so, `extractRecordFields` would return `Dict.empty` and `resolveAccessor` would crash. Is this expected to be prevented by Fix 1 ensuring all types are fully instantiated?

2. **Multiple record params:** The new `extractRecordFields` takes the *first* record-typed arg. For accessors (`.fieldName`), the accessor function always takes exactly one record argument, so this should be correct. But if the callee param type is itself a function type with a record in its args (e.g., a higher-order function taking a record accessor), the traversal might pick up the wrong record. Is this a concern, or are accessor param types always direct `MFunction [MRecord ...] fieldType`?

---

## Fix 4 – Joinpoint ABI as an explicit Mono-level closure-flattening pass

**Goal:** Match the old monomorphizer's behavior for joinpoint-style functions (case returning lambdas) by an explicit shared pass over `Mono` that flattens such closures.

### Step 4.1 – Create `JoinpointFlatten.elm`

**File:** `compiler/src/Compiler/Monomorphize/JoinpointFlatten.elm` (new file)

This module provides a single post-monomorphization pass that:
1. Traverses all `MonoNode`s in a `MonoGraph`
2. Detects the pattern: `MonoClosure info (MonoCase ...) funcType` where all case branches return `MonoClosure`s with compatible param lists
3. Flattens: merges inner closure params into the outer closure's params, strips inner closures from branches, adjusts the function type

**Key types and functions:**

```elm
module Compiler.Monomorphize.JoinpointFlatten exposing (flattenGraphJoinpoints)

flattenGraphJoinpoints : Mono.MonoGraph -> Mono.MonoGraph
-- Traverses all nodes, applying flattenExpr to each expression

flattenExpr : Mono.MonoExpr -> Mono.MonoExpr
-- Recursion over all MonoExpr constructors, calling flattenJoinpointClosure for MonoClosure

flattenJoinpointClosure : Mono.ClosureInfo -> Mono.MonoExpr -> Mono.MonoType -> Mono.MonoExpr
-- Detects: body is MonoCase where all branches return MonoClosure
-- If pattern matches: merge params, strip inner closures, recompute type
-- If not: return original closure

extractLambdaBranches :
    List ( Int, Mono.MonoExpr )
    -> Maybe ( List ( Name, Mono.MonoType ), List ( Int, Mono.MonoExpr ), Mono.MonoType )
-- Inspects all jump targets; if all are MonoClosure with compatible params,
-- returns (extraParams, newBranches, finalResultType)

recomputeFunctionType : List ( Name, Mono.MonoType ) -> Mono.MonoType -> Mono.MonoType
-- Builds curried MFunction from params and result type
```

**Pattern detection specifics:**

The joinpoint pattern in Mono IR is:
```
MonoClosure { params = outerParams, ... }
    (MonoCase scrutName scrutVar (Decider ...) jumps resultType)
    funcType
```
Where each jump target `(idx, expr)` in `jumps` has the form:
```
MonoClosure { params = innerParams, ... } innerBody innerFuncType
```
And all `innerParams` lists are compatible (same length and types).

The flattened result:
```
MonoClosure { params = outerParams ++ innerParams, ... }
    (MonoCase scrutName scrutVar (Decider ...) newJumps finalResultType)
    newFuncType
```
Where each `newJumps` entry `(idx, expr)` is just `innerBody` (inner closures stripped), and `newFuncType` reflects the full parameter list.

**Note on `MonoCase` structure:** The `MonoCase` constructor is:
```elm
MonoCase Name Name (Decider MonoChoice) (List ( Int, MonoExpr )) MonoType
```
The jump targets are in the `List ( Int, MonoExpr )` — the `Decider` contains `Jump Int` leaves that index into this list. The flattening only affects the jump-target expressions, not the `Decider` tree structure.

**Note on captures:** When merging closures, the outer closure's captures may need updating. The inner closures' captures become locals in the flattened body. Since captures are computed from free variables, after flattening, the outer closure's captures should be recomputed via `Closure.computeClosureCaptures` with the merged param list and the new body.

### Step 4.2 – Wire into both monomorphizers

**File:** `compiler/src/Compiler/MonoDirect/Monomorphize.elm` (lines 54–58)

Change:
```elm
rawGraph = assembleRawGraph finalState mainSpecId
prunedGraph = Prune.pruneUnreachableSpecs globalTypeEnv rawGraph
```
To:
```elm
rawGraph = assembleRawGraph finalState mainSpecId
flattenedGraph = JoinpointFlatten.flattenGraphJoinpoints rawGraph
prunedGraph = Prune.pruneUnreachableSpecs globalTypeEnv flattenedGraph
```

**File:** `compiler/src/Compiler/Monomorphize/Monomorphize.elm` (lines 80–84)

Same change:
```elm
rawGraph = assembleRawGraph finalState mainSpecIdVal
flattenedGraph = JoinpointFlatten.flattenGraphJoinpoints rawGraph
prunedGraph = Prune.pruneUnreachableSpecs finalState.ctx.globalTypeEnv flattenedGraph
```

Add `import Compiler.Monomorphize.JoinpointFlatten as JoinpointFlatten` to both files.

### Questions for Fix 4

1. **Decider vs If-style cases:** The `MonoCase` uses `Decider MonoChoice` with `Jump Int` leaves. But `MonoIf` also exists for conditional chains. Should the joinpoint flattening also handle `MonoIf` bodies where all branches return closures? Or is the joinpoint pattern always expressed via `MonoCase`?

2. **Nested joinpoints:** If an outer closure's body is a case where branches return closures whose bodies are also cases returning closures (nested joinpoints), should we flatten recursively? The recursive `flattenExpr` traversal would handle this naturally if `flattenJoinpointClosure` is called after recursing into the body.

3. **Capture recomputation:** After flattening, should we call `Closure.computeClosureCaptures` on the merged result to get correct captures? The inner closures may have captured variables from the outer closure's body that should now just be locals.

4. **Compatibility with GlobalOpt:** The `GlobalOpt` pass runs after monomorphization and handles function flattening (GOPT_001). Does joinpoint flattening interact with or duplicate any GlobalOpt behavior? Should the joinpoint pass run before or after GlobalOpt?

5. **`extractLambdaBranches` compatibility check:** What does "compatible params" mean exactly? Same number of params? Same types? Same names? For the flattening to be correct, the inner closures must all have the same parameter *types* (though names can differ — we'd pick one set of names). If any branch has different param types or count, we must bail out and not flatten.

---

## Implementation Order

1. **Fix 1** first — it underpins several failure categories and is a prerequisite for correctness of the other fixes.
2. **Fix 2** second — once types are correct, normalize the poly-let algorithm.
3. **Fix 3** third — small, targeted change to accessor robustness.
4. **Fix 4** last — new module, independent of the others, can be tested in isolation.

## Testing Strategy

- After each fix, run `cd compiler && npx elm-test-rs --project build-xhr --fuzz 1` to verify no regressions.
- After all fixes, run `cmake --build build --target check` for full E2E.
- The `MonoDirectComparisonTest.elm` suite (if it exists) should show reduced divergence between MonoDirect and the standard monomorphizer.
