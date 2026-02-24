# Let-Polymorphism Multi-Specialization

## Problem

The current monomorphization produces **one** specialization for let-bound polymorphic functions, using `collectLocalCallSubst` to derive a single substitution from all call sites. When the same let-bound function is used at **two different concrete types** in one body:

```elm
let id x = x in (id 1, id "hello")
```

...the single-substitution approach picks one mapping (`a -> MInt` or `a -> MString`) and applies it everywhere. This produces a single `id` with a mixed/incorrect ABI: one call site's `papExtend` result type won't match the callee's return type (CGEN_056 violation).

## Solution

Clone the let-bound function **per distinct concrete instantiation**, giving each clone a fresh name, and rewrite calls in the body to target the appropriate clone.

Conceptually:
```elm
-- Before:
let id x = x in (id 1, id "hello")

-- After:
let id$0 : Int -> Int = \x -> x in
let id$1 : String -> String = \x -> x in
(id$0 1, id$1 "hello")
```

## File: `compiler/src/Compiler/Monomorphize/Specialize.elm`

All changes are in this single file.

---

### Step 1: Add `LocalFunInstance` type alias

Add near the top of the file (after the `ProcessedArg` type around line 40):

```elm
type alias LocalFunInstance =
    { origName : Name
    , freshName : Name
    , monoType : Mono.MonoType   -- The monomorphic function type (MFunction [...] ...)
    , subst : Substitution        -- The substitution used to specialize this instance
    }
```

### Step 2: Add `collectLocalInstantiations` function

Replace the existing `collectLocalCallSubst` + `collectCallSubstExpr` + `collectCallSubstFromCallSite` + `collectCallSubstDef` + `collectCallSubstDecider` + `collectCallSubstChoice` family of functions (~280 lines, lines 2056–2355) with a new `collectLocalInstantiations` function that returns a **list** of `(MonoType, Substitution)` pairs instead of a single merged substitution.

The new function traverses the body expression tree (same recursive structure as the existing `collectCallSubstExpr`), but instead of merging all call-site substitutions into one `Dict`, it **accumulates a list** of `(funcMonoType, callSubst)` pairs — one per call site that targets `defName`.

For each call `defName args` found in the body:
1. Compute `argTypes` by `List.map (\arg -> Mono.forceCNumberToInt (TypeSubst.applySubst outerSubst (TOpt.typeOf arg))) args`
2. Run `TypeSubst.unifyFuncCall defCanType argTypes callCanType outerSubst` to get `callSubst`
3. Derive `funcMonoType = Mono.forceCNumberToInt (TypeSubst.applySubst callSubst defCanType)`
4. Append `(funcMonoType, callSubst)` to the accumulator

After traversal, **deduplicate** by `funcMonoType` using `Mono.toComparableMonoType`.

The recursive structure mirrors the existing `collectCallSubstExpr` exactly — every branch recurses into subexpressions the same way, the only difference is the accumulator type (`List (MonoType, Substitution)` instead of `Substitution`) and the call-site handler (append to list instead of `Dict.union`).

### Step 3: Modify the `TOpt.Let` branch in `specializeExpr`

Replace lines 886–923 (the current `TOpt.Let` case) with new logic:

```elm
TOpt.Let def body canType ->
    let
        monoType =
            Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)

        defName =
            getDefName def

        defCanType =
            getDefCanonicalType def
    in
    case defCanType of
        Can.TLambda _ _ ->
            -- Function def: may need multi-specialization
            let
                instPairs =
                    collectLocalInstantiations defName defCanType body subst

                instances =
                    if List.isEmpty instPairs then
                        -- No calls found: single instance with outer subst
                        [ { origName = defName
                          , freshName = defName
                          , monoType = Mono.forceCNumberToInt (TypeSubst.applySubst subst defCanType)
                          , subst = subst
                          }
                        ]
                    else if List.length instPairs == 1 then
                        -- Single instantiation: keep original name
                        case instPairs of
                            [ ( funcMT, instSubst ) ] ->
                                [ { origName = defName
                                  , freshName = defName
                                  , monoType = funcMT
                                  , subst = instSubst
                                  }
                                ]
                            _ ->
                                -- unreachable
                                []
                    else
                        -- Multiple instantiations: generate fresh names
                        List.indexedMap
                            (\i ( funcMT, instSubst ) ->
                                { origName = defName
                                , freshName = defName ++ "$" ++ String.fromInt i
                                , monoType = funcMT
                                , subst = instSubst
                                }
                            )
                            instPairs

                -- Specialize each instance into a MonoDef
                ( instanceDefs, state1 ) =
                    List.foldl
                        (\inst ( defsAcc, stAcc ) ->
                            let
                                ( monoDef0, st1 ) =
                                    specializeDef def inst.subst stAcc

                                monoDef =
                                    renameMonoDef inst.freshName monoDef0
                            in
                            ( monoDef :: defsAcc, st1 )
                        )
                        ( [], state )
                        instances

                -- Register varTypes for all instances
                stateWithVars =
                    List.foldl
                        (\inst st ->
                            { st | varTypes = Dict.insert identity inst.freshName inst.monoType st.varTypes }
                        )
                        state1
                        instances

                -- Specialize the body under the outer subst
                ( monoBody, state2 ) =
                    specializeExpr body subst stateWithVars

                -- Rewrite MonoVarLocal/MonoCall references to use instance freshNames
                monoBodyRewritten =
                    if List.length instances > 1 then
                        rewriteLocalCalls instances monoBody
                    else
                        monoBody

                -- Build nested MonoLet chain
                finalExpr =
                    List.foldl
                        (\def_ accBody -> Mono.MonoLet def_ accBody (Mono.typeOf accBody))
                        monoBodyRewritten
                        instanceDefs
            in
            ( finalExpr, state2 )

        _ ->
            -- Non-function let: original behavior
            let
                ( monoDef, state1 ) =
                    specializeDef def subst state

                defMonoType =
                    Mono.forceCNumberToInt (TypeSubst.applySubst subst defCanType)

                stateWithVar =
                    { state1 | varTypes = Dict.insert identity defName defMonoType state1.varTypes }

                ( monoBody, state2 ) =
                    specializeExpr body subst stateWithVar
            in
            ( Mono.MonoLet monoDef monoBody monoType, state2 )
```

### Step 4: Add helper `renameMonoDef`

```elm
renameMonoDef : Name -> Mono.MonoDef -> Mono.MonoDef
renameMonoDef newName def =
    case def of
        Mono.MonoDef _ expr ->
            Mono.MonoDef newName expr

        Mono.MonoTailDef _ args expr ->
            Mono.MonoTailDef newName args expr
```

### Step 5: Add `rewriteLocalCalls`

This function walks the `MonoExpr` tree and replaces `MonoVarLocal origName monoType` with `MonoVarLocal freshName monoType` by matching the `origName` and `monoType` against the instance list.

The matching logic: for a given `MonoVarLocal name monoType`, find the first `LocalFunInstance` where `inst.origName == name` and `inst.monoType == monoType`, then replace `name` with `inst.freshName`.

The rewrite must recurse into all `MonoExpr` constructors (similar to `MonoTraverse` helpers or the pattern in `collectCallSubstExpr`). The key constructors to handle:

- `MonoVarLocal name t` → check & rewrite name
- `MonoCall region func args resultType callInfo` → rewrite func (if VarLocal), recurse into args
- `MonoLet def body t` → recurse into def body and body
- `MonoIf branches final t` → recurse
- `MonoCase` → recurse into branches
- `MonoClosure info body t` → recurse into body
- `MonoList`, `MonoTupleCreate`, `MonoRecordCreate`, `MonoRecordUpdate`, `MonoRecordAccess` → recurse
- `MonoDestruct` → recurse into body
- `MonoTailCall` → rewrite named args
- Literals, Unit, VarGlobal, VarKernel → return unchanged

For `MonoType` comparison, use structural equality (Elm's `==` on the MonoType ADT). This is safe because both the instance's `monoType` and the `MonoVarLocal`'s type were produced by the same `applySubst`/`forceCNumberToInt` pipeline.

### Step 6: Remove old `collectLocalCallSubst` family

Delete the following functions which are now replaced by `collectLocalInstantiations`:
- `collectLocalCallSubst` (lines 2071–2078)
- `collectCallSubstExpr` (lines 2081–2276)
- `collectCallSubstFromCallSite` (lines 2278–2303)
- `collectCallSubstDef` (lines 2305–2321)
- `collectCallSubstDecider` (lines 2323–2355)
- `collectCallSubstChoice` (lines 2357–end)

---

## Edge Cases

1. **Single instantiation**: When `instPairs` has length 1, we keep the original name — no rename needed, no rewrite needed. Behavior is identical to the current single-substitution approach but with the correct call-site-derived substitution.

2. **Zero call sites** (function defined but never called in body): `instPairs` is empty. Fallback to a single instance with `subst`, same as current behavior. The function will be dead code but that's fine.

3. **Higher-order uses** (passing `id` to another function without calling it directly): If `id` appears as `VarLocal` but NOT as the callee of a `Call`, `collectLocalInstantiations` won't find it. This is handled by the fallback: if there are zero call-site instantiations, we specialize once with `subst`. If there ARE call-site instantiations AND a higher-order use, the higher-order use gets the outer `subst`-derived type via `specializeExpr` on the `VarLocal` node — the rewrite pass will find the closest matching instance by type, or leave the name unchanged if no match.

4. **Non-function let bindings**: Handled by the `_ ->` branch — completely unchanged from current behavior.

5. **TailDef**: `specializeDef` already handles `TailDef` correctly. `renameMonoDef` handles both `MonoDef` and `MonoTailDef`. The fresh name propagates through `MonoTailCall` via the `rewriteLocalCalls` pass (which must also handle `MonoTailCall` name rewriting).

6. **Nested lets**: Each `TOpt.Let` is processed independently during `specializeExpr` recursion. Inner lets with polymorphic functions get their own `collectLocalInstantiations` call. The outer let's instances are already resolved by the time the inner let is processed.

---

## Questions for Implementation

1. **MonoType equality for matching**: Using Elm's structural `==` on `MonoType` should be correct since both sides come from the same `applySubst`/`forceCNumberToInt` pipeline. Should we use `toComparableMonoType` instead for robustness?

2. **`rewriteLocalCalls` scope**: The rewrite should only apply to instances from the current let, not interfere with any outer lets that might have the same original name. Since each let's instances have unique freshNames and we only rewrite when `origName` and `monoType` both match, this should be safe — but worth verifying.

3. **Interaction with `callSubst` in the `_ ->` Call branch**: When `specializeExpr` processes a `Call` to a local function (lines 828–861), it uses `callSubst` (from `unifyFuncCall`) to specialize the `func` expression. For `VarLocal`, this produces `MonoVarLocal name (applySubst callSubst canType)`. This is exactly the per-call-site `monoType` that `collectLocalInstantiations` computed. So the rewrite will find the right instance. **This is the critical linkage that makes the design work.**
