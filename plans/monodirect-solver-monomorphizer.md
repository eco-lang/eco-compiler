# MonoDirect: Solver-Variable-Aware Monomorphizer — Implementation Plan

## Status: Planning (Phases 1–4 done, Phase 5 stubs need real implementation)

This plan covers the **remaining implementation** of `MonoDirect.Monomorphize` and
`MonoDirect.Specialize`, plus prerequisites. Phases 1–4 and Phase 6 are already implemented.

**Constraint**: No fallback to TypeSubst or the existing monomorphizer. All type resolution
must flow through the solver snapshot. Missing tvars are hard errors during development.

---

## Current State

| Component | Status |
|-----------|--------|
| Solver output (nodeVars, solverState) | Done |
| SolverSnapshot module | Done |
| TypedCanonical tvar field | Done |
| TypedOptimized Meta type | Done |
| tvar propagation in LocalOpt | **NOT DONE** (90 sites hardcode `tvar = Nothing`) |
| tvar strictness (requireTVar) | **NOT DONE** |
| LocalView layout queries | **NOT DONE** |
| Annotation/body var split (FuncVars) | **NOT DONE** |
| MonoDirect.State | Done (has snapshot field, needs FuncVars) |
| MonoDirect.Monomorphize | **STUB** (delegates to BaseMono) |
| MonoDirect.Specialize | **STUB** (delegates to BaseSpecialize) |
| Test pipeline (runToMonoDirect) | Done |
| MonoDirect invariant tests | Done |

---

## Architecture: How Solver-Driven Specialization Works

### Existing approach (TypeSubst)

For a polymorphic `f : a -> List a -> a` specialized at `Int -> List Int -> Int`:

1. `TypeSubst.unify canType requestedMonoType` → `Substitution = {"a": MInt}`
2. For each sub-expression: `TypeSubst.applySubst {"a": MInt} exprCanType` → `MonoType`
3. At call sites: rename callee type vars to avoid string-name collisions, then unify args

### MonoDirect approach (solver variables)

1. Get the function's `tvar` → its solver variable `v_func`
2. Walk `v_func`'s descriptor tree, matching against `requestedMonoType`, to find rigid/flex vars
3. Create fresh solver variables encoding the concrete types in a **local state copy**
4. Unify each (rigid, concrete) pair in the local state
5. Now every `tvar` in the function body resolves to a concrete `MonoType` through the union-find
6. For each sub-expression: `view.monoTypeOf exprTvar` → `MonoType` directly

**Key simplifications over TypeSubst**:
- No string-based variable names → no renaming / collision issues
- No `SchemeInfo`, `buildRenameMap`, `unifyCallSiteWithRenaming`
- Single unification step resolves all types simultaneously
- No per-expression `applySubst` traversal

---

## Prerequisite P1: Propagate `tvar` Through LocalOpt

**Why**: MonoDirect needs `tvar` on TOpt expressions. Currently all 90 sites hardcode `Nothing`.

### P1.1: `LocalOpt.Typed.Expression.elm` (~37 sites)

Change the destructuring at line 108:
```elm
-- Before:
TCan.TypedExpr { expr, tipe } ->
    optimizeExpr ... region tipe expr

-- After:
TCan.TypedExpr { expr, tipe, tvar } ->
    optimizeExpr ... region { tipe = tipe, tvar = tvar } expr
```

Change `optimizeExpr` signature to accept `TOpt.Meta` instead of `Can.Type`:
```elm
optimizeExpr : ... -> A.Region -> TOpt.Meta -> Can.Expr_ -> Names.Tracker TOpt.Expr
```

For each expression construction site:
- **When the expression corresponds to the original canonical node**: use the incoming `meta`
  (preserves the tvar from the solver)
- **When constructing a synthetic expression** (e.g., registering a global, looking up kernel type,
  creating an accessor body): use `{ tipe = ..., tvar = Nothing }`
- **When recursing into sub-expressions**: sub-expressions have their own tvars from `TCan.TypedExpr`,
  so each recursive call to `optimize` naturally gets the right tvar

**Tightening rule (from Addendum A.4):** When the optimization does NOT change the semantic
type (renamed vars, constant folding, etc.), preserve `meta.tvar` intact. When it DOES change
the type (projection result, arithmetic op, etc.), set `tvar = Nothing`.

### P1.2: `LocalOpt.Typed.Module.elm` (~9 sites)

For `Define`/`TrackedDefine` node construction, propagate `tvar` from the definition's
top-level expression's TCan.TypedExpr.

### P1.3: `LocalOpt.Typed.Port.elm` (~37 sites)

Port optimization creates many synthetic expressions for JSON decoders/encoders.
These are genuinely synthetic (no canonical source) → `tvar = Nothing` is correct.

However, the top-level port expression DOES have a tvar. Thread it to the Port node's Meta.

### P1.4: `LocalOpt.Typed.Names.elm` (~6 sites)

`registerGlobal`, `registerCtor`, etc. create TOpt expression references to other globals.
These don't have expression-level tvars (they reference external definitions).
`tvar = Nothing` is correct here — MonoDirect resolves their types from the Meta on the
*use site* expression, not the reference itself.

### P1.5: `LocalOpt.Typed.Case.elm` (~1 site)

Decision tree construction. `tvar = Nothing` is correct for synthetic pattern-match nodes.

### P1 Risk

Low — additive change, tvar is ignored by all existing consumers. The existing monomorphizer
doesn't use tvar. Only MonoDirect reads it.

---

## Prerequisite P1a: Strict `tvar` Enforcement (Addendum A)

### Invariant SNAP_TVAR_001

> In the MonoDirect test pipeline, any `TOpt.Node` or `TOpt.Expr` that can influence
> specialization must have `Meta.tvar /= Nothing`. A missing `tvar` in these positions
> is a compiler bug and should make MonoDirect fail fast.

We do NOT fall back to `Can.Type` for specialization logic; `Can.Type` is only for error
messages or as a sanity check.

### P1a.1: Add strict helpers to `TypedOptimized.elm`

**File:** `compiler/src/Compiler/AST/TypedOptimized.elm`

Add non-partial accessors for the MonoDirect path:
```elm
requireTVar : Meta -> IO.Variable
requireTVar meta =
    case meta.tvar of
        Just var ->
            var

        Nothing ->
            Utils.Crash.crash "Missing tvar in TypedOptimized.Meta on MonoDirect path"


requireTVarExpr : Expr -> IO.Variable
requireTVarExpr expr =
    requireTVar (metaOf expr)
```

These are only called from MonoDirect code, never from the production pipeline.

### P1a.2: Add `requireExprVar` to `TypedCanonical.Build`

**File:** `compiler/src/Compiler/TypedCanonical/Build.elm`

Add a strict helper for the test-only pipeline:
```elm
requireExprVar : Int -> ExprVars -> IO.Variable
requireExprVar exprId exprVars =
    case Array.get exprId exprVars |> Maybe.andThen identity of
        Just var ->
            var

        Nothing ->
            Utils.Crash.crash
                ("Missing solver variable (ExprVars) for ExprId "
                    ++ String.fromInt exprId
                    ++ " in TypedCanonical.Build")
```

Add an alternate entry point for the test pipeline:
```elm
fromCanonicalWithRequiredVars : Can.Module -> ExprTypes -> ExprVars -> Module
```
This is identical to `fromCanonical` but uses `requireExprVar` for nodes that participate
in specialization (def bodies, lambda bodies, call sites).

### P1a.3: Validate at MonoDirect entry

**File:** `compiler/src/Compiler/MonoDirect/Monomorphize.elm`

Before seeding the worklist, validate all nodes in the global graph:
```elm
ensureSolverBackedNode : TOpt.Node -> TOpt.Node
ensureSolverBackedNode node =
    case node of
        TOpt.Define expr _ meta ->
            let
                _ = TOpt.requireTVar meta
                _ = TOpt.requireTVarExpr expr
            in
            node

        TOpt.TrackedDefine _ expr _ meta ->
            let
                _ = TOpt.requireTVar meta
                _ = TOpt.requireTVarExpr expr
            in
            node

        TOpt.PortIncoming expr _ meta ->
            let
                _ = TOpt.requireTVar meta
                _ = TOpt.requireTVarExpr expr
            in
            node

        TOpt.PortOutgoing expr _ meta ->
            let
                _ = TOpt.requireTVar meta
                _ = TOpt.requireTVarExpr expr
            in
            node

        _ ->
            -- Ctor, Enum, Box, Kernel, Manager, Link, Cycle: no tvar needed
            node
```

In `monomorphizeDirect`, run validation before proceeding:
```elm
monomorphizeDirect entryPointName globalTypeEnv snapshot (TOpt.GlobalGraph nodes ctorShapes mainInfo) =
    let
        nodesChecked =
            DMap.map TOpt.toComparableGlobal (\_ node -> ensureSolverBackedNode node) nodes
    in
    -- proceed with nodesChecked
```

This makes missing tvars a hard failure in the test pipeline, surfacing P1 gaps immediately.

---

## Prerequisite P2: Extend SolverSnapshot with `specializeFunction`

### P2.1: Fresh variable creation

Add to `SolverSnapshot.elm`:

```elm
{-| Create a fresh solver variable with a Structure descriptor in a local IO.State. -}
freshStructureVar : IO.FlatType -> IO.State -> ( TypeVar, IO.State )
freshStructureVar flatType st =
    let
        wIdx = Array.length st.ioRefsWeight
        dIdx = Array.length st.ioRefsDescriptor
        pIdx = Array.length st.ioRefsPointInfo
        descriptor = IO.Descriptor
            { content = IO.Structure flatType
            , rank = 0
            , mark = Type.noMark
            , copy = Nothing
            }
    in
    ( IO.Pt pIdx
    , { st
          | ioRefsWeight = Array.push 1 st.ioRefsWeight
          , ioRefsDescriptor = Array.push descriptor st.ioRefsDescriptor
          , ioRefsPointInfo = Array.push (IO.Info (IO.Pt wIdx) (IO.Pt dIdx)) st.ioRefsPointInfo
      }
    )

{-| Create a fresh unconstrained flex variable. -}
freshFlexVar : IO.State -> ( TypeVar, IO.State )
-- Same pattern but with FlexVar Nothing content
```

### P2.2: MonoType → solver variable tree

```elm
{-| Recursively create solver variables encoding a MonoType. -}
monoTypeToVar : Mono.MonoType -> IO.State -> ( TypeVar, IO.State )
monoTypeToVar monoType st =
    case monoType of
        Mono.MInt -> freshStructureVar (IO.App1 elmCoreBasics "Int" []) st
        Mono.MFloat -> freshStructureVar (IO.App1 elmCoreBasics "Float" []) st
        Mono.MBool -> freshStructureVar (IO.App1 elmCoreBasics "Bool" []) st
        Mono.MChar -> freshStructureVar (IO.App1 elmCoreChar "Char" []) st
        Mono.MString -> freshStructureVar (IO.App1 elmCoreString "String" []) st
        Mono.MUnit -> freshStructureVar IO.Unit1 st
        Mono.MList elemType ->
            let (elemVar, st1) = monoTypeToVar elemType st
            in freshStructureVar (IO.App1 elmCoreList "List" [elemVar]) st1
        Mono.MFunction args resultType ->
            monoFunctionToVar args resultType st
        Mono.MRecord fields ->
            monoRecordToVar fields st
        Mono.MTuple parts ->
            monoTupleToVar parts st
        Mono.MCustom canonical name args ->
            let (argVars, stN) = monoTypesToVars args st
            in freshStructureVar (IO.App1 canonical name argVars) stN
        Mono.MErased -> freshFlexVar st
        Mono.MVar _ _ -> freshFlexVar st

monoFunctionToVar : List Mono.MonoType -> Mono.MonoType -> IO.State -> ( TypeVar, IO.State )
monoFunctionToVar args resultType st =
    case args of
        [argType] ->
            let (argVar, st1) = monoTypeToVar argType st
                (resVar, st2) = monoTypeToVar resultType st1
            in freshStructureVar (IO.Fun1 argVar resVar) st2
        a :: rest ->
            let (argVar, st1) = monoTypeToVar a st
                (resVar, st2) = monoFunctionToVar rest resultType st1
            in freshStructureVar (IO.Fun1 argVar resVar) st2
        [] ->
            monoTypeToVar resultType st  -- degenerate: no args
```

### P2.3: Type structure walking and unification

The core algorithm: walk the solver's type structure in parallel with the requested MonoType,
unifying rigid vars with concrete types.

```elm
{-| Walk a solver variable's type structure in parallel with a MonoType,
    unifying rigid/flex vars with concrete types created from the MonoType.
    Returns the updated local IO.State.
-}
walkAndUnify : TypeVar -> Mono.MonoType -> IO.State -> IO.State
walkAndUnify var monoType st =
    let
        root = resolveVariableInState st.ioRefsPointInfo var
        desc = lookupDescriptorInState st root
    in
    case desc.content of
        IO.RigidVar _ ->
            unifyVarWithMono root monoType st
        IO.RigidSuper _ _ ->
            unifyVarWithMono root monoType st
        IO.FlexVar _ ->
            unifyVarWithMono root monoType st
        IO.FlexSuper _ _ ->
            unifyVarWithMono root monoType st
        IO.Structure flatType ->
            walkStructure flatType monoType st
        IO.Alias _ _ _ innerVar ->
            walkAndUnify innerVar monoType st
        IO.Error ->
            st

unifyVarWithMono : TypeVar -> Mono.MonoType -> IO.State -> IO.State
unifyVarWithMono var monoType st =
    let (concreteVar, st1) = monoTypeToVar monoType st
        (st2, _) = Unify.unify var concreteVar st1
    in st2

walkStructure : IO.FlatType -> Mono.MonoType -> IO.State -> IO.State
walkStructure flatType monoType st =
    case ( flatType, monoType ) of
        ( IO.Fun1 argVar resVar, Mono.MFunction [argMono] resMono ) ->
            st |> walkAndUnify argVar argMono |> walkAndUnify resVar resMono
        ( IO.Fun1 argVar resVar, Mono.MFunction (a :: rest) resMono ) ->
            st |> walkAndUnify argVar a |> walkAndUnify resVar (Mono.MFunction rest resMono)
        ( IO.App1 _ _ childVars, Mono.MList elemMono ) ->
            case childVars of
                [elemVar] -> walkAndUnify elemVar elemMono st
                _ -> st
        ( IO.App1 _ _ childVars, Mono.MCustom _ _ childMonos ) ->
            List.foldl (\(v, m) s -> walkAndUnify v m s) st (List.map2 Tuple.pair childVars childMonos)
        ( IO.Tuple1 a b rest, Mono.MTuple monos ) ->
            case monos of
                ma :: mb :: mrest ->
                    st
                    |> walkAndUnify a ma
                    |> walkAndUnify b mb
                    |> (\s -> List.foldl (\(v, m) s2 -> walkAndUnify v m s2) s (List.map2 Tuple.pair rest mrest))
                _ -> st
        ( IO.Record1 fields _, Mono.MRecord monoFields ) ->
            Dict.foldl (\name fieldVar s ->
                case Dict.get name monoFields of
                    Just fieldMono -> walkAndUnify fieldVar fieldMono s
                    Nothing -> s
            ) st fields
        ( IO.EmptyRecord1, _ ) -> st
        ( IO.Unit1, _ ) -> st
        _ ->
            -- Structure mismatch: force-unify the whole thing
            let root = ... -- need to get the root var for the structure
            in unifyVarWithMono root monoType st
```

**Design issue**: `walkStructure` doesn't have access to the root variable of the structure.
We need to restructure so `walkAndUnify` handles the Structure case directly.

### P2.4: High-level `specializeFunction`

```elm
{-| Set up a local unification context for specializing a function.

    Given a function's root tvar and the requested MonoType, creates a local
    copy of the solver state, walks the type structure to unify rigid params
    with concrete types, and provides a LocalView for type queries.
-}
specializeFunction :
    SolverSnapshot
    -> TypeVar              -- function's root tvar
    -> Mono.MonoType        -- requested concrete type
    -> (LocalView -> a)
    -> a
specializeFunction snap funcTvar requestedMonoType callback =
    let
        localState =
            { ioRefsWeight = snap.state.weights
            , ioRefsPointInfo = snap.state.pointInfo
            , ioRefsDescriptor = snap.state.descriptors
            , ioRefsMVector = Array.empty
            }

        -- Walk the type structure and unify rigids with concrete types
        stateAfterWalk = walkAndUnify funcTvar requestedMonoType localState

        -- Force unconstrained FlexSuper Number vars to Int
        stateAfterForce = forceUnconstrainedNumbers stateAfterWalk

        -- Build LocalView
        view = buildLocalView stateAfterForce
    in
    callback view

forceUnconstrainedNumbers : IO.State -> IO.State
-- Scan all descriptors; for FlexSuper Number that are still roots (not unified),
-- set them to Structure (App1 Int)

buildLocalView : IO.State -> LocalView
buildLocalView st =
    { typeOf = \var ->
        let (_, result) = Type.toCanTypeBatch (Array.fromList [Just var]) st
        in case Array.get 0 result of
            Just (Just t) -> t
            _ -> Can.TUnit
    , monoTypeOf = \var ->
        canTypeToMonoTypeDirect (typeOfVar var)
    }
```

### P2.5: `canTypeToMonoTypeDirect`

A version of Can.Type → MonoType that doesn't use a substitution dictionary (since the solver
already resolved all type variables). Any remaining `TVar` after solver resolution indicates
an unconstrained type variable that should become `MErased` (or `MVar _ CEcoValue`).

```elm
canTypeToMonoTypeDirect : Can.Type -> Mono.MonoType
canTypeToMonoTypeDirect canType =
    case canType of
        Can.TVar name ->
            -- If we get here, the solver left this var unresolved.
            -- This is a phantom/unconstrained type variable.
            Mono.MErased
        Can.TLambda from to ->
            Mono.MFunction [canTypeToMonoTypeDirect from] (canTypeToMonoTypeDirect to)
        Can.TType canonical name args ->
            -- Map known primitives
            if isPrimitive canonical name then
                mapPrimitive canonical name
            else
                Mono.MCustom canonical name (List.map canTypeToMonoTypeDirect args)
        Can.TRecord fields ext ->
            Mono.MRecord (Dict.map (\_ (Can.FieldType _ t) -> canTypeToMonoTypeDirect t) fields)
        Can.TTuple a b rest ->
            Mono.MTuple (List.map canTypeToMonoTypeDirect (a :: b :: rest))
        Can.TUnit -> Mono.MUnit
        Can.TAlias _ _ _ (Can.Filled inner) -> canTypeToMonoTypeDirect inner
        Can.TAlias _ _ args (Can.Holey inner) ->
            canTypeToMonoTypeDirect (applyAliasArgs args inner)
```

---

## Prerequisite P3: Extend `LocalView` with Layout Queries (Addendum B)

### Motivation

Roc's mono phase is layout-driven (`LayoutRepr`, `ProcLayout`, etc.) rather than purely
type-driven. To move towards this, MonoDirect should be able to ask the snapshot for
**shape/layout information** in addition to `MonoType`.

### P3.1: Layout representation

There is no `IO.RawLayout` type in the codebase. Instead, the solver's structural type
information (`IO.Content` / `IO.FlatType`) IS the layout information. We define a
layout type in `SolverSnapshot.elm` that wraps the solver's structural representation:

**File:** `compiler/src/Compiler/Type/SolverSnapshot.elm`

```elm
{-| Raw layout derived from solver descriptor structure.
    This interprets the solver's FlatType as layout information.
-}
type RawLayout
    = FunctionLayout TypeVar TypeVar              -- arg, result
    | RecordLayout (Dict String TypeVar)          -- field name → field type var
    | TupleLayout TypeVar TypeVar (List TypeVar)  -- a, b, rest
    | CustomLayout IO.Canonical String (List TypeVar)  -- module, name, type args
    | PrimitiveLayout PrimitiveKind
    | UnitLayout
    | UnknownLayout                               -- flex var, error, etc.

type PrimitiveKind
    = IntLayout | FloatLayout | BoolLayout | CharLayout | StringLayout
```

`RawLayout` is built by inspecting the resolved descriptor's `Content`:
```elm
rawLayoutOfVar : SolverSnapshot -> TypeVar -> RawLayout
rawLayoutOfVar snapshot var =
    let
        root = resolveVariable snapshot var
    in
    case lookupDescriptor snapshot root of
        Just (IO.Descriptor props) ->
            case props.content of
                IO.Structure (IO.Fun1 argVar resVar) ->
                    FunctionLayout argVar resVar
                IO.Structure (IO.Record1 fields _) ->
                    RecordLayout fields
                IO.Structure (IO.Tuple1 a b rest) ->
                    TupleLayout a b rest
                IO.Structure (IO.App1 canonical name args) ->
                    classifyApp canonical name args
                IO.Structure IO.EmptyRecord1 ->
                    RecordLayout Dict.empty
                IO.Structure IO.Unit1 ->
                    UnitLayout
                IO.Alias _ _ _ innerVar ->
                    rawLayoutOfVar snapshot innerVar  -- unwrap alias
                _ ->
                    UnknownLayout
        Nothing ->
            UnknownLayout

classifyApp : IO.Canonical -> String -> List TypeVar -> RawLayout
classifyApp canonical name args =
    -- Classify known primitives
    if isElmCoreInt canonical name then PrimitiveLayout IntLayout
    else if isElmCoreFloat canonical name then PrimitiveLayout FloatLayout
    else if isElmCoreBool canonical name then PrimitiveLayout BoolLayout
    else if isElmCoreChar canonical name then PrimitiveLayout CharLayout
    else if isElmCoreString canonical name then PrimitiveLayout StringLayout
    else CustomLayout canonical name args
```

### P3.2: Convenience wrappers

```elm
recordLayoutOfVar : SolverSnapshot -> TypeVar -> Result String (Dict String TypeVar)
recordLayoutOfVar snapshot var =
    case rawLayoutOfVar snapshot var of
        RecordLayout fields ->
            Ok fields
        other ->
            Err ("recordLayoutOfVar: expected record layout, got " ++ debugLayout other)

tupleLayoutOfVar : SolverSnapshot -> TypeVar -> Result String (List TypeVar)
tupleLayoutOfVar snapshot var =
    case rawLayoutOfVar snapshot var of
        TupleLayout a b rest ->
            Ok (a :: b :: rest)
        other ->
            Err ("tupleLayoutOfVar: expected tuple layout, got " ++ debugLayout other)

debugLayout : RawLayout -> String
debugLayout layout =
    case layout of
        FunctionLayout _ _ -> "Function"
        RecordLayout _ -> "Record"
        TupleLayout _ _ _ -> "Tuple"
        CustomLayout _ name _ -> "Custom(" ++ name ++ ")"
        PrimitiveLayout kind -> "Primitive(" ++ debugPrimitive kind ++ ")"
        UnitLayout -> "Unit"
        UnknownLayout -> "Unknown"
```

### P3.3: Extend `LocalView`

Update the `LocalView` type:
```elm
type alias LocalView =
    { typeOf : TypeVar -> Can.Type
    , monoTypeOf : TypeVar -> Mono.MonoType
    , rawLayoutOf : TypeVar -> RawLayout
    , recordLayoutOf : TypeVar -> Result String (Dict String TypeVar)
    , tupleLayoutOf : TypeVar -> Result String (List TypeVar)
    }
```

In `withLocalUnification` and `specializeFunction`, build the extended LocalView using
the local state:
```elm
buildLocalView : IO.State -> SolverState -> LocalView
buildLocalView localSt localSolverState =
    let
        localSnap = { state = localSolverState, nodeVars = Array.empty }
    in
    { typeOf = \v -> ... -- existing
    , monoTypeOf = \v -> ... -- existing
    , rawLayoutOf = \v -> rawLayoutOfVar localSnap v
    , recordLayoutOf = \v -> recordLayoutOfVar localSnap v
    , tupleLayoutOf = \v -> tupleLayoutOfVar localSnap v
    }
```

Note: `rawLayoutOfVar` operates on the *local* solver state (after unification), so
layout queries reflect the specialization context.

### P3.4: Using layout queries in MonoDirect.Specialize

**File:** `compiler/src/Compiler/MonoDirect/Specialize.elm`

For record access, layout queries give us the field's type var directly:
```elm
TOpt.Access recordExpr region fieldName meta ->
    let
        recordVar = TOpt.requireTVarExpr recordExpr
        fieldMonoType =
            case view.recordLayoutOf recordVar of
                Ok fieldMap ->
                    case Dict.get fieldName fieldMap of
                        Just fieldVar ->
                            view.monoTypeOf fieldVar
                        Nothing ->
                            Utils.Crash.crash
                                ("MonoDirect: unknown field " ++ fieldName)
                Err msg ->
                    Utils.Crash.crash ("MonoDirect: " ++ msg)

        ( monoRecordExpr, state1 ) = specializeExpr view recordExpr state
    in
    ( Mono.MonoRecordAccess monoRecordExpr fieldName fieldMonoType, state1 )
```

For tuple destructuring, layout queries give us element type vars:
```elm
-- In pattern/destructor specialization:
case view.tupleLayoutOf tupleVar of
    Ok [firstVar, secondVar] ->
        ( view.monoTypeOf firstVar, view.monoTypeOf secondVar )
    ...
```

Even though Eco's actual low-level layout is computed in MLIR/codegen, using solver-driven
layouts at specialization time gets closer to Roc's pattern where layout drives closure
conversion and pattern compilation.

---

## Prerequisite P4: Annotation vs Body Var Split (Addendum C)

### Motivation

Roc stores both `annotation : Variable` and `body_var : Variable` in `PartialProc`, using
them separately: `annotation` represents the declared type, `body_var` represents the
inferred type of the body expression. MonoDirect should track the same split.

### P4.1: `FuncVars` type

**File:** `compiler/src/Compiler/MonoDirect/State.elm`

Add:
```elm
type alias FuncVars =
    { annotation : SolverSnapshot.TypeVar
    , body : SolverSnapshot.TypeVar
    }
```

Add to `MonoDirectState`:
```elm
type alias MonoDirectState =
    { worklist : List WorkItem
    , nodes : Dict Int Mono.MonoNode
    , ...
    , snapshot : SolverSnapshot.SolverSnapshot
    , funcVars : Data.Map.Dict (List String) Mono.Global FuncVars  -- NEW
    , ...
    }
```

Note: `Mono.Global` isn't directly comparable in Elm, so we use `Data.Map.Dict` with
`Mono.toComparableGlobal` as the key function (same pattern as `toptNodes`).

### P4.2: Populate `funcVars` from `TOpt.GlobalGraph`

**File:** `compiler/src/Compiler/MonoDirect/Monomorphize.elm`

Pre-scan the global graph to extract annotation/body var pairs:
```elm
buildFuncVars :
    IO.Canonical
    -> Data.Map.Dict (List String) TOpt.Global TOpt.Node
    -> Data.Map.Dict (List String) Mono.Global FuncVars
buildFuncVars homeModule nodes =
    DMap.foldl TOpt.compareGlobal
        (\toptGlobal node acc ->
            case node of
                TOpt.Define expr _ meta ->
                    let
                        annotVar = TOpt.requireTVar meta
                        bodyVar = TOpt.requireTVarExpr expr
                        monoGlobal = toptGlobalToMono toptGlobal
                    in
                    DMap.insert Mono.toComparableGlobal monoGlobal
                        { annotation = annotVar, body = bodyVar } acc

                TOpt.TrackedDefine _ expr _ meta ->
                    let
                        annotVar = TOpt.requireTVar meta
                        bodyVar = TOpt.requireTVarExpr expr
                        monoGlobal = toptGlobalToMono toptGlobal
                    in
                    DMap.insert Mono.toComparableGlobal monoGlobal
                        { annotation = annotVar, body = bodyVar } acc

                _ ->
                    acc
        )
        (DMap.empty Mono.toComparableGlobal)
        nodes
```

### P4.3: Initialize `funcVars` in `monomorphizeDirect`

```elm
monomorphizeDirect entryPointName globalTypeEnv snapshot (TOpt.GlobalGraph nodes ctorShapes mainInfo) =
    let
        nodesChecked = DMap.map TOpt.toComparableGlobal (\_ n -> ensureSolverBackedNode n) nodes
        funcVars = buildFuncVars currentModule nodesChecked
        initialState = State.initStateWithFuncVars currentModule nodesChecked globalTypeEnv snapshot funcVars
    in
    ...
```

### P4.4: Use annotation vs body var in specialization

**File:** `compiler/src/Compiler/MonoDirect/Specialize.elm`

When specializing a global, look up its `FuncVars` and use both handles:
```elm
specializeGlobalWithFuncVars :
    SolverSnapshot -> Mono.Global -> Mono.MonoType -> TOpt.Node -> MonoDirectState
    -> ( Mono.MonoNode, MonoDirectState )
specializeGlobalWithFuncVars snapshot global requestedMonoType node state =
    case DMap.get Mono.toComparableGlobal global state.funcVars of
        Nothing ->
            -- Non-function node (Ctor, Enum, etc.) or missing entry
            specializeNode snapshot (globalName global) node requestedMonoType state

        Just { annotation, body } ->
            -- Roc-style: unify annotation with requested type, then specialize body
            Snapshot.specializeFunction snapshot annotation requestedMonoType
                (\view ->
                    let
                        -- The body var gives us the body's type in this specialization context
                        bodyMonoType = view.monoTypeOf body
                        ( monoExpr, state1 ) = specializeExprFromNode view node state
                    in
                    ( Mono.MonoDefine monoExpr bodyMonoType, state1 )
                )
```

The annotation var is used to drive unification with the requested type. The body var
gives us the body expression's type after that unification. If they happen to be the same
underlying solver variable (as is common for simple functions), the split is a no-op.
For functions where the annotation differs from the body type (e.g., with type annotations
that are more general than the inferred body type), the split gives us more precise control.

### P4.5: Why two variables?

In Roc, the distinction matters for:
1. **Type annotations that are more general than the body**: `f : a -> a` with body `\x -> x + 1`
   has `annotation = a -> a` but `body_var = number -> number`. The body is more constrained.
2. **Specialization precision**: Unifying with `annotation` gives us the function's public API
   type. Checking `body` gives us the implementation's actual type.
3. **Error reporting**: If annotation and body types diverge after specialization, it indicates
   a type error or annotation mismatch.

In MonoDirect, the same benefits apply. The split costs nothing (both vars already exist
in the solver state) and gives us an additional consistency check.

---

## Step 1: MonoDirect.Specialize Implementation

### 1.1 Module structure

```elm
module Compiler.MonoDirect.Specialize exposing (specializeNode)

import Compiler.Type.SolverSnapshot as Snapshot exposing (SolverSnapshot, LocalView, TypeVar)
```

### 1.2 Type resolution

Every expression resolves its type through the LocalView, using the strict `requireTVar`
helpers from Addendum A:

```elm
resolveType : LocalView -> TOpt.Meta -> Mono.MonoType
resolveType view meta =
    Mono.forceCNumberToInt (view.monoTypeOf (TOpt.requireTVar meta))
```

No `Maybe` check, no fallback. `requireTVar` crashes on missing tvars (SNAP_TVAR_001).
This surfaces P1 gaps immediately during testing.

### 1.3 Expression specialization

```elm
specializeExpr : LocalView -> TOpt.Expr -> MonoDirectState -> ( Mono.MonoExpr, MonoDirectState )
specializeExpr view expr state =
    case expr of
        -- Literals: fixed types, no solver needed
        TOpt.Bool _ value _ ->
            ( Mono.MonoLiteral (Mono.LBool value) Mono.MBool, state )
        TOpt.Chr _ value _ ->
            ( Mono.MonoLiteral (Mono.LChar value) Mono.MChar, state )
        TOpt.Str _ value _ ->
            ( Mono.MonoLiteral (Mono.LStr value) Mono.MString, state )

        -- Numeric literals: need solver to distinguish Int vs Float
        TOpt.Int _ value meta ->
            let monoType = resolveType view meta
            in case monoType of
                Mono.MFloat ->
                    ( Mono.MonoLiteral (Mono.LFloat (toFloat value)) monoType, state )
                _ ->
                    ( Mono.MonoLiteral (Mono.LInt value) monoType, state )

        -- Variables: resolve from solver
        TOpt.VarLocal name meta ->
            ( Mono.MonoVarLocal name (resolveType view meta), state )
        TOpt.TrackedVarLocal _ name meta ->
            ( Mono.MonoVarLocal name (resolveType view meta), state )

        -- Global references: resolve + enqueue
        TOpt.VarGlobal region global meta ->
            let
                monoType = resolveType view meta
                ( specId, state1 ) = enqueueSpec (toptGlobalToMono global) monoType Nothing state
            in
            ( Mono.MonoVarGlobal region specId monoType, state1 )

        -- Similarly for VarEnum, VarBox, VarCycle...

        -- Kernel references
        TOpt.VarKernel region home name meta ->
            let funcMonoType = deriveKernelAbiTypeDirect (home, name) meta view
            in ( Mono.MonoVarKernel region home name funcMonoType, state )

        -- Calls: THE KEY SIMPLIFICATION
        TOpt.Call region func args meta ->
            specializeCall view region func args meta state

        -- Functions/closures
        TOpt.Function params body meta ->
            specializeLambda view (TOpt.Function params body meta) meta state
        TOpt.TrackedFunction params body meta ->
            specializeLambda view (TOpt.TrackedFunction params body meta) meta state

        -- Control flow
        TOpt.If branches final meta ->
            let
                monoType = resolveType view meta
                ( monoBranches, state1 ) = specializeBranches view branches state
                ( monoFinal, state2 ) = specializeExpr view final state1
            in
            ( Mono.MonoIf monoBranches monoFinal monoType, state2 )

        TOpt.Let def body meta ->
            specializeLetDirect view def body meta state

        TOpt.Case name label decider jumps meta ->
            let
                monoType = resolveType view meta
                ( monoDecider, state1 ) = specializeDecider view decider state
                ( monoJumps, state2 ) = specializeJumps view jumps state1
            in
            ( Mono.MonoCase name label monoDecider monoJumps monoType, state2 )

        -- Collections
        TOpt.List region exprs meta ->
            let
                monoType = resolveType view meta
                ( monoExprs, state1 ) = specializeExprs view exprs state
            in
            ( Mono.MonoList region monoExprs monoType, state1 )

        -- Records
        TOpt.Record region fields meta ->
            let
                monoType = resolveType view meta
                ( monoFields, state1 ) = specializeNamedExprs view fields state
            in
            ( Mono.MonoRecordCreate monoFields monoType, state1 )

        TOpt.Access recordExpr region fieldName meta ->
            -- Use layout query (Addendum B) for record field type resolution
            let
                recordVar = TOpt.requireTVarExpr recordExpr
                fieldMonoType =
                    case view.recordLayoutOf recordVar of
                        Ok fieldMap ->
                            case Dict.get fieldName fieldMap of
                                Just fieldVar -> view.monoTypeOf fieldVar
                                Nothing ->
                                    Utils.Crash.crash ("MonoDirect: unknown field " ++ fieldName)
                        Err msg ->
                            -- Fallback: use the expression's own tvar
                            resolveType view meta

                ( monoExpr, state1 ) = specializeExpr view recordExpr state
            in
            ( Mono.MonoRecordAccess monoExpr fieldName fieldMonoType, state1 )

        TOpt.Update region expr fields meta ->
            let
                monoType = resolveType view meta
                ( monoExpr, state1 ) = specializeExpr view expr state
                ( monoFields, state2 ) = specializeNamedExprs view fields state1
            in
            ( Mono.MonoRecordUpdate monoExpr monoFields monoType, state2 )

        TOpt.Tuple region exprs meta ->
            let
                monoType = resolveType view meta
                ( monoExprs, state1 ) = specializeExprs view exprs state
            in
            ( Mono.MonoTupleCreate region monoExprs monoType, state1 )

        TOpt.Unit _ _ ->
            ( Mono.MonoUnit, state )

        -- ... remaining variants
```

### 1.4 Call specialization (the key difference)

No renaming. No SchemeInfo. The solver already knows all type relationships.

```elm
specializeCall : LocalView -> A.Region -> TOpt.Expr -> List TOpt.Expr -> TOpt.Meta -> MonoDirectState -> ( Mono.MonoExpr, MonoDirectState )
specializeCall view region func args meta state =
    let
        resultType = resolveType view meta
        ( monoArgs, state1 ) = specializeExprs view args state
    in
    case func of
        TOpt.VarGlobal funcRegion global funcMeta ->
            let
                funcMonoType = resolveType view funcMeta
                ( specId, state2 ) = enqueueSpec (toptGlobalToMono global) funcMonoType Nothing state1
                monoFunc = Mono.MonoVarGlobal funcRegion specId funcMonoType
            in
            ( Mono.MonoCall region monoFunc monoArgs resultType Mono.defaultCallInfo, state2 )

        TOpt.VarKernel funcRegion home name funcMeta ->
            let
                funcMonoType = deriveKernelAbiTypeDirect (home, name) funcMeta view
                monoFunc = Mono.MonoVarKernel funcRegion home name funcMonoType
            in
            ( Mono.MonoCall region monoFunc monoArgs resultType Mono.defaultCallInfo, state1 )

        TOpt.VarDebug funcRegion name _ _ funcMeta ->
            let
                funcMonoType = deriveKernelAbiTypeDirect ("Debug", name) funcMeta view
                monoFunc = Mono.MonoVarKernel funcRegion "Debug" name funcMonoType
            in
            ( Mono.MonoCall region monoFunc monoArgs resultType Mono.defaultCallInfo, state1 )

        _ ->
            -- Local/anonymous function call
            let ( monoFunc, state2 ) = specializeExpr view func state1
            in ( Mono.MonoCall region monoFunc monoArgs resultType Mono.defaultCallInfo, state2 )
```

### 1.5 Accessor specialization

Accessors are synthetic (no solver var). Handle same as existing:

```elm
specializeAccessorGlobal : Name -> Mono.MonoType -> MonoDirectState -> ( Mono.MonoNode, MonoDirectState )
-- Reuse existing logic from Monomorphize.specializeAccessorGlobal (no solver needed)
```

### 1.6 Lambda specialization

```elm
specializeLambda : LocalView -> TOpt.Expr -> TOpt.Meta -> MonoDirectState -> ( Mono.MonoExpr, MonoDirectState )
specializeLambda view lambdaExpr meta state =
    let
        funcMonoType = resolveType view meta
        ( params, body ) = extractParamsBody lambdaExpr
        ( paramMonoTypes, _ ) = Closure.flattenFunctionType funcMonoType
        monoParams = List.map2 Tuple.pair params (padOrTruncate paramMonoTypes (List.length params))

        stateWithParams = pushVarFrame monoParams state
        ( monoBody, state1 ) = specializeExpr view body stateWithParams
        state2 = popVarFrame state1

        captures = Closure.computeClosureCaptures monoParams monoBody
        closureInfo = buildClosureInfo monoParams captures funcMonoType
    in
    ( Mono.MonoClosure closureInfo monoBody funcMonoType, state2 )
```

### 1.7 Node specialization (with FuncVars, Addendum C)

Node specialization uses the annotation/body var split when available:

```elm
specializeNode : SolverSnapshot -> Name -> TOpt.Node -> Mono.MonoType -> MonoDirectState -> ( Mono.MonoNode, MonoDirectState )
specializeNode snapshot ctorName node requestedMonoType state =
    case node of
        TOpt.Define expr _ meta ->
            -- Use FuncVars if available (Roc-style annotation/body split)
            let
                annotVar = TOpt.requireTVar meta
                bodyVar = TOpt.requireTVarExpr expr
            in
            specializeDefine snapshot annotVar bodyVar expr requestedMonoType state

        TOpt.TrackedDefine _ expr _ meta ->
            let
                annotVar = TOpt.requireTVar meta
                bodyVar = TOpt.requireTVarExpr expr
            in
            specializeDefine snapshot annotVar bodyVar expr requestedMonoType state

        TOpt.Ctor index arity _ ->
            -- No solver var needed; Ctor type is determined by requestedMonoType
            let
                monoType = Mono.forceCNumberToInt requestedMonoType
                tag = Index.toMachine index
                shape = buildCtorShapeFromArity ctorName tag arity monoType
                ctorResultType = extractCtorResultType arity requestedMonoType
            in
            ( Mono.MonoCtor shape ctorResultType, state )

        TOpt.Enum tag _ ->
            ( Mono.MonoEnum (Index.toMachine tag) requestedMonoType, state )

        TOpt.Box _ ->
            let
                shape = buildCtorShapeFromArity ctorName 0 1 requestedMonoType
                ctorResultType = extractCtorResultType 1 requestedMonoType
            in
            ( Mono.MonoCtor shape ctorResultType, state )

        TOpt.Link linkedGlobal ->
            case lookupNode linkedGlobal state of
                Nothing -> ( Mono.MonoExtern requestedMonoType, state )
                Just linkedNode ->
                    specializeNode snapshot (globalName linkedGlobal) linkedNode requestedMonoType state

        TOpt.Kernel _ _ -> ( Mono.MonoExtern requestedMonoType, state )
        TOpt.Manager _ -> ( Mono.MonoManagerLeaf (homeModuleName state) requestedMonoType, state )

        TOpt.Cycle names valueDefs funcDefs _ ->
            specializeCycleDirect snapshot names valueDefs funcDefs requestedMonoType state

        TOpt.PortIncoming expr _ meta ->
            let annotVar = TOpt.requireTVar meta
            in Snapshot.specializeFunction snapshot annotVar requestedMonoType
                (\view ->
                    let ( monoExpr, state1 ) = specializeExpr view expr state
                    in ( Mono.MonoPortIncoming monoExpr requestedMonoType, state1 )
                )

        TOpt.PortOutgoing expr _ meta ->
            let annotVar = TOpt.requireTVar meta
            in Snapshot.specializeFunction snapshot annotVar requestedMonoType
                (\view ->
                    let ( monoExpr, state1 ) = specializeExpr view expr state
                    in ( Mono.MonoPortOutgoing monoExpr requestedMonoType, state1 )
                )

{-| Specialize a Define/TrackedDefine using Roc-style annotation/body var split.
    Unifies annotation with requestedMonoType to set up the LocalView,
    then reads body var to get the actual body type in this specialization context.
-}
specializeDefine : SolverSnapshot -> TypeVar -> TypeVar -> TOpt.Expr -> Mono.MonoType -> MonoDirectState -> ( Mono.MonoNode, MonoDirectState )
specializeDefine snapshot annotVar bodyVar expr requestedMonoType state =
    Snapshot.specializeFunction snapshot annotVar requestedMonoType
        (\view ->
            let
                -- Body var resolves to the body's type after annotation unification
                bodyMonoType = view.monoTypeOf bodyVar
                ( monoExpr, state1 ) = specializeExpr view expr state
                -- Use the body's actual type (may differ from annotation due to more specific inference)
                actualType = Mono.typeOf monoExpr
            in
            ( Mono.MonoDefine monoExpr actualType, state1 )
        )
```

---

## Step 2: MonoDirect.Monomorphize Implementation

### 2.1 Entry point

```elm
monomorphizeDirect :
    Name -> TypeEnv.GlobalTypeEnv -> SolverSnapshot -> TOpt.GlobalGraph
    -> Result String Mono.MonoGraph
monomorphizeDirect entryPointName globalTypeEnv snapshot (TOpt.GlobalGraph nodes _ _) =
    case findEntryPoint entryPointName nodes of
        Nothing -> Err ("No " ++ entryPointName ++ " function found")
        Just ( mainGlobal, mainNode ) ->
            let
                mainMonoType = resolveMainType snapshot mainNode
                ( finalState, mainSpecId ) =
                    runSpecialization mainGlobal mainMonoType globalTypeEnv snapshot nodes
                rawGraph = assembleRawGraph finalState mainSpecId
                prunedGraph = Prune.pruneUnreachableSpecs globalTypeEnv rawGraph
            in
            Ok prunedGraph
```

### 2.2 Main type resolution

```elm
resolveMainType : SolverSnapshot -> TOpt.Node -> Mono.MonoType
resolveMainType snapshot node =
    case nodeMetaTvar node of
        Just tvar ->
            -- Main is monomorphic; solver fully resolves it
            Snapshot.withLocalUnification snapshot [] []
                (\view -> view.monoTypeOf tvar)
        Nothing ->
            -- Fallback for main without tvar (shouldn't happen after P1)
            canTypeToMonoTypeDirect (nodeCanType node)
```

### 2.3 Worklist initialization

```elm
runSpecialization : TOpt.Global -> Mono.MonoType -> TypeEnv.GlobalTypeEnv -> SolverSnapshot
    -> DMap.Dict ... TOpt.Global TOpt.Node -> ( MonoDirectState, Mono.SpecId )
runSpecialization mainGlobal mainMonoType globalTypeEnv snapshot nodes =
    let
        currentModule = globalModule mainGlobal
        initialState = State.initState currentModule nodes globalTypeEnv snapshot
        ( mainSpecId, registryWithMain ) =
            Registry.getOrCreateSpecId (toptGlobalToMono mainGlobal) mainMonoType Nothing initialState.registry
        stateWithMain =
            { initialState
                | registry = registryWithMain
                , worklist = [ SpecializeGlobal mainSpecId ]
                , scheduled = BitSet.insertGrowing mainSpecId initialState.scheduled
            }
    in
    ( processWorklist snapshot stateWithMain, mainSpecId )
```

### 2.4 Worklist loop

Structurally identical to existing `processWorklist`. Key difference: passes `snapshot` to
`Specialize.specializeNode`.

```elm
processWorklist : SolverSnapshot -> MonoDirectState -> MonoDirectState
processWorklist snapshot state =
    case state.worklist of
        [] -> state
        (SpecializeGlobal specId) :: rest ->
            if BitSet.member specId state.inProgress then
                processWorklist snapshot { state | worklist = rest }
            else
                case Registry.lookupSpecKey specId state.registry of
                    Nothing ->
                        processWorklist snapshot { state | worklist = rest }
                    Just ( global, monoType, _ ) ->
                        let
                            state2 = prepareForSpec specId global rest state
                        in
                        case global of
                            Mono.Accessor fieldName ->
                                let ( node, s ) = specializeAccessorGlobal fieldName monoType state2
                                in processWorklist snapshot (finalizeSpec specId node s)

                            Mono.Global _ name ->
                                case lookupToptNode global state2 of
                                    Nothing ->
                                        processWorklist snapshot (finalizeExtern specId monoType state2)
                                    Just toptNode ->
                                        let ( node, s ) = Specialize.specializeNode snapshot name toptNode monoType state2
                                        in processWorklist snapshot (finalizeSpec specId node s)
```

### 2.5 Graph assembly

Extract the shared assembly logic from `Monomorphize.elm` into `Compiler.Monomorphize.Assemble.elm`:
- MVar erasure (dead-value, CEcoValue, CNumber)
- Registry patching (MONO_017)
- Graph construction

Both `Monomorphize.monomorphize` and `MonoDirect.monomorphizeDirect` call this shared module.

---

## Step 3: Let-polymorphism (localMulti / valueMulti)

### The problem

Let-bound polymorphic functions need multiple specializations:
```elm
let f x = x + 1
in (f 3, f 4.0)
```

The solver resolves `f`'s type to `number -> number`. But at call sites, `f` is used at
`Int -> Int` and `Float -> Float`. We need two distinct specializations.

### MonoDirect approach

At a `Let` binding with a polymorphic function def:
1. Check if the def's tvar (via solver) has rigid/flex vars → is polymorphic
2. Register in `localMulti` with the def's tvar
3. At each call site of the let-bound function:
   - The call's arg tvars are already unified with the function's param tvars in the OUTER LocalView
   - So `view.monoTypeOf funcTvar` gives us the function's type at THIS call site
   - Use this to create a specialized instance name
   - Specialize the function body under a NEW LocalView with the function's rigids further constrained

**Key insight**: In the solver approach, each call site already has its constraints applied to
the function's type through the outer LocalView. We don't need separate unification per call site
— the solver already did that work. We just need to read the function's type at each usage.

Wait — that's not quite right. The solver resolves `f`'s type to the MOST GENERAL unifier
across all call sites (e.g., `number -> number`). At each call site, the *argument's* type
is specific (Int or Float), but the *function reference's* type is still general.

**Revised approach**: At each call site, create a nested `specializeFunction` context:
1. Get the call-site arg types from the outer view
2. Call `specializeFunction` with the let-def's tvar and the concrete function type
3. Specialize the function body under this nested view

This naturally handles let-poly because each call site drives different unifications.

### Instance tracking

Same `localMulti` pattern as existing monomorphizer:
- Track `(defName, MonoType) -> instanceName` to avoid re-specializing
- Generate fresh names for distinct specializations
- Insert specialized defs before the body

---

## Step 4: Cycle specialization

### Value-only cycles

```elm
let a = ... b ...
    b = ... a ...
in a
```

Specialize all defs under the same LocalView. Same as existing but using solver types.

### Function cycles

Each function in the cycle gets its own `specializeFunction` call. The solver already unified
mutual references' types. Create separate specs per function, linked by `specId`.

---

## Step 5: Kernel ABI derivation

```elm
deriveKernelAbiTypeDirect : (String, String) -> TOpt.Meta -> LocalView -> Mono.MonoType
deriveKernelAbiTypeDirect (home, name) meta view =
    case meta.tvar of
        Just tvar ->
            let
                canType = view.typeOf tvar
                monoType = view.monoTypeOf tvar
            in
            KernelAbi.deriveFromCanAndMono (home, name) canType monoType
        Nothing ->
            -- Kernel reference without tvar (shouldn't happen after P1)
            Utils.Crash.crash ...
```

Need to add `KernelAbi.deriveFromCanAndMono` that takes pre-resolved Can.Type and MonoType
(no Substitution needed).

---

## Implementation Order

1. **P1**: tvar propagation in LocalOpt (~90 sites, mechanical)
2. **P1a**: Strict tvar enforcement (requireTVar, requireTVarExpr, ensureSolverBackedNode)
3. **P2**: SolverSnapshot extensions (freshStructureVar, monoTypeToVar, walkAndUnify, specializeFunction)
4. **P2a**: Alias-transparent resolution + numeric defaulting in SolverSnapshot
5. **P3**: LocalView layout queries (RawLayout, rawLayoutOfVar, recordLayoutOfVar with flattenRecordFields)
6. **P4**: FuncVars annotation/body split (FuncVars type, buildFuncVars, initStateWithFuncVars)
7. **P5**: Shared helpers module (`Compiler.Monomorphize.Shared`) + assembly extraction (`Compiler.Monomorphize.Assemble`)
8. **Step 5**: Kernel ABI adapter (deriveFromCanAndMono)
9. **Step 1**: MonoDirect.Specialize (expression + node specialization, using FuncVars + layout queries)
10. **Step 2**: MonoDirect.Monomorphize (worklist + assembly + funcVars init)
11. **Step 3**: Let-polymorphism (localMulti, nested withLocalUnification per call site)
12. **Step 4**: Cycle support
13. **Validation**: Run existing invariant tests on MonoDirect output via `runToMonoDirect`

---

## Resolved Design Decisions (Q1–Q10)

### Q1: Alias descriptors → Always unwrap (SNAP_ALIAS_001)

**Decision**: Always unwrap aliases. `MonoType` does not carry aliases, and layout queries
treat aliases as transparent. Alias handling belongs in type checker / PostSolve, not MonoDirect.

**Invariant SNAP_ALIAS_001**: All monomorphization-time unification and layout queries operate
on alias-free variables. Aliases are unwrapped at the `SolverSnapshot` boundary.

Implementation: `resolveVariable` chases both `Link` parents and `Alias` inner vars.
See Section 8.1 for details.

### Q2: Numeric defaulting → In local state before LocalView (SNAP_NUM_001)

**Decision**: Perform numeric defaulting in the local unification state, after walkAndUnify
but before exposing the `LocalView`. `view.monoTypeOf` never returns `MVar _ CNumber`.

**Invariant SNAP_NUM_001**: Within a `LocalView`, `monoTypeOf` never returns `MVar _ CNumber`
for any reachable function body variable.

Implementation: `defaultNumericVarsToInt` scans descriptors for `FlexSuper Number` and replaces
with `Structure (App1 Int)`. See Section 8.2 for details.

### Q3: MonoDirectState → Independent, share helpers via `Monomorphize.Shared`

**Decision**: Keep `MonoDirectState` independent. Extract shared helper operations (enqueueSpec,
VarEnv ops, Registry ops) into `Compiler.Monomorphize.Shared` using Elm record extensibility.
Both monomorphizers import from the shared module.

Implementation: See Section 9.1.

### Q4: Graph assembly → Extract to `Compiler.Monomorphize.Assemble`

**Decision**: Extract assembly logic (MVar erasure, registry patching, graph construction,
pruning) into a shared `Assemble.assembleGraph` function. Both monomorphizers construct an
`AssembleState` record and hand it to this function.

Implementation: See Section 9.2.

### Q5: `tvar = Nothing` → Hard crash in MonoDirect, fix upstream

**Decision**: For nodes that participate in specialization, missing tvar is a compiler bug.
`requireTVar` / `requireTVarExpr` crash immediately. `ensureSolverBackedNode` validates
all nodes before the worklist starts.

Legitimate `Nothing` cases (not specialization-relevant):
- `VarGlobal` wrappers from `Names.registerGlobal` (use-site expr has its own tvar)
- Accessor bodies (handled by `specializeAccessorGlobal`, not `specializeExpr`)

When `requireTVar` fires, fix the earlier pipeline (P1), don't weaken MonoDirect.

### Q6: `monoTypeOf` performance → Accept O(α(n)) cost

**Decision**: Accept per-expression union-find traversal cost. O(α(n)) ≈ O(1).
Typical functions have O(10²–10³) nodes. Profile later if needed.

Future option: add local memoization in `LocalView` keyed by `Pt Int` index.
See Section 11 for deferred caching design.

### Q7: Let-poly → Nested `withLocalUnification` per call site (required)

**Decision**: Cannot avoid nested specialization. Outer `LocalView` gives the function's
most general type. Each call site needs its own `withLocalUnification` scope to unify
parameter vars with call-site argument vars.

Implementation: See Section 8.3.

### Q8: `RawLayout` → Export fully

**Decision**: Export `RawLayout(..)` and all constructors. Future work (closure layout,
pattern compilation) may need raw structural access. Convenience wrappers are the primary
API for MonoDirect.Specialize.

### Q9: Annotation vs body vars → Keep split, add optional test invariant

**Decision**: Keep the split. Usually annotation and body resolve to the same root. When
they diverge (explicit type annotation more general than inferred body), the split catches
mismatches that would otherwise silently produce wrong specializations.

**Optional invariant SNAP_ANN_001**: For all globals in `funcVars`,
`resolveVariable annotation == resolveVariable body` after solving. If not, log a warning
(not a hard failure — divergence is valid for type-annotated functions).

Implementation: Test helper in `compiler/tests/TestLogic/Type/AnnotationVsBodyTest.elm`.
See Section 13.

### Q10: Record extensions → `flattenRecordFields` follows extension vars

**Decision**: `recordLayoutOfVar` must recursively follow extension variables. A standalone
`flattenRecordFields` helper walks `Record1 fields ext` → merges fields → follows ext →
stops at `EmptyRecord1` or non-record.

Implementation: See Section 12.2.

---

## Section 8: Solver-Driven Unification Details

### 8.1 Alias-Transparent Resolution (Q1 implementation)

**File:** `compiler/src/Compiler/Type/SolverSnapshot.elm`

The existing `resolveVariable` follows `Link` parents but does NOT unwrap `Alias`. Update it
to chase both:

```elm
resolveVariable : SolverSnapshot -> TypeVar -> TypeVar
resolveVariable snap var0 =
    resolveVariableHelp snap.state.pointInfo snap.state.descriptors var0

resolveVariableHelp : Array IO.PointInfo -> Array IO.Descriptor -> TypeVar -> TypeVar
resolveVariableHelp pointInfo descriptors var =
    case var of
        IO.Pt idx ->
            case Array.get idx pointInfo of
                Just (IO.Link parent) ->
                    -- Follow union-find parent
                    resolveVariableHelp pointInfo descriptors parent

                Just (IO.Info _ _) ->
                    -- Root node. Check for alias.
                    case Array.get idx descriptors of
                        Just (IO.Descriptor props) ->
                            case props.content of
                                IO.Alias _ _ _ innerVar ->
                                    -- Unwrap alias: follow inner variable
                                    resolveVariableHelp pointInfo descriptors innerVar

                                _ ->
                                    var  -- Non-alias root: done

                        Nothing ->
                            var

                Nothing ->
                    var
```

**Effect on `walkAndUnify`**: Always calls `resolveVariable` first, so the traversal never
encounters `Alias` nodes. The alias case in `walkAndUnify` becomes unreachable but can remain
as a defensive guard.

**Effect on `lookupDescriptor`**: Already calls `resolveVariable`, so it automatically benefits
from alias unwrapping.

### 8.2 Numeric Defaulting Placement (Q2 implementation)

**File:** `compiler/src/Compiler/Type/SolverSnapshot.elm`

Add a local numeric defaulting pass that runs on the IO.State BEFORE building LocalView:

```elm
{-| Default unconstrained FlexSuper Number vars to Int in a local IO.State.
    Must run AFTER walkAndUnify but BEFORE building LocalView.
-}
defaultNumericVarsToInt : IO.State -> IO.State
defaultNumericVarsToInt st =
    { st
        | ioRefsDescriptor =
            Array.map
                (\desc ->
                    case desc of
                        IO.Descriptor props ->
                            case props.content of
                                IO.FlexSuper IO.Number _ ->
                                    IO.Descriptor
                                        { props
                                            | content =
                                                IO.Structure
                                                    (IO.App1 elmCoreBasicsCanonical "Int" [])
                                        }

                                _ ->
                                    desc
                )
                st.ioRefsDescriptor
    }
```

Where `elmCoreBasicsCanonical` is:
```elm
elmCoreBasicsCanonical : IO.Canonical
elmCoreBasicsCanonical = IO.Canonical ("elm", "core") "Basics"
```

**Integration into `withLocalUnification`** (updated flow):
```elm
withLocalUnification snap rootsToRelax equalities callback =
    let
        -- 1. Build local IO.State from snapshot
        localState = snapshotToIoState snap.state

        -- 2. Relax rigid vars to flex
        stateAfterRelax = List.foldl relaxRigidVar localState rootsToRelax

        -- 3. Unify each pair
        stateAfterUnify = List.foldl unifyPair stateAfterRelax equalities

        -- 4. NEW: Default unconstrained numeric vars to Int
        stateAfterDefault = defaultNumericVarsToInt stateAfterUnify

        -- 5. Build LocalView from defaulted state
        view = buildLocalView stateAfterDefault
    in
    callback view
```

**Same pattern for `specializeFunction`**: walkAndUnify → defaultNumericVarsToInt → buildLocalView.

### 8.3 Let-Poly Nested Specialization (Q7 implementation)

**File:** `compiler/src/Compiler/MonoDirect/Specialize.elm`

At each call site of a let-bound polymorphic function, enter a nested `withLocalUnification`:

```elm
specializeLetPolyCall :
    SolverSnapshot -> LocalView -> TOpt.Expr -> List TOpt.Expr -> TOpt.Meta
    -> MonoDirectState -> ( Mono.MonoExpr, MonoDirectState )
specializeLetPolyCall snapshot outerView funcExpr args meta state =
    let
        funcVar = TOpt.requireTVarExpr funcExpr
        argVars = List.map TOpt.requireTVarExpr args
        resultVar = TOpt.requireTVar meta

        -- Build equalities: unify func's param vars with arg vars
        -- funcVar's structure is Fun1 paramVar resultVar; walk to extract params
        paramEqualities = buildParamEqualities snapshot funcVar argVars
    in
    SolverSnapshot.withLocalUnification
        snapshot
        [ funcVar ]  -- relax the function's rigid vars
        paramEqualities
        (\callView ->
            let
                resultMonoType = callView.monoTypeOf resultVar
                funcMonoType = callView.monoTypeOf funcVar

                -- Specialize args under the OUTER view (their types are already resolved)
                ( monoArgs, state1 ) = specializeExprs outerView args state

                -- The function reference resolves under the CALL view
                ( freshName, state2 ) = getOrCreateLocalInstance defName funcMonoType state1

                monoFunc = Mono.MonoVarLocal freshName funcMonoType
            in
            ( Mono.MonoCall region monoFunc monoArgs resultMonoType Mono.defaultCallInfo
            , state2
            )
        )

{-| Extract parameter vars from a function type's solver structure and pair
    them with argument vars for unification.
-}
buildParamEqualities : SolverSnapshot -> TypeVar -> List TypeVar -> List ( TypeVar, TypeVar )
buildParamEqualities snapshot funcVar argVars =
    let
        -- Walk the function's FlatType structure to extract param vars
        paramVars = extractFuncParamVars snapshot funcVar (List.length argVars)
    in
    List.map2 Tuple.pair paramVars argVars

extractFuncParamVars : SolverSnapshot -> TypeVar -> Int -> List TypeVar
extractFuncParamVars snapshot var n =
    if n <= 0 then
        []
    else
        case lookupDescriptor snapshot var of
            Just (IO.Descriptor { content }) ->
                case content of
                    IO.Structure (IO.Fun1 argVar resVar) ->
                        argVar :: extractFuncParamVars snapshot resVar (n - 1)
                    _ ->
                        []  -- Not a function structure; no more params
            Nothing ->
                []
```

Key insight: arguments are specialized under the **outer** LocalView (their types are
already determined by the enclosing context). Only the function reference and result type
are read from the **call-site** LocalView.

---

## Section 9: State and Graph Assembly Sharing

### 9.1 Shared Helper Module (Q3 implementation)

**File:** `compiler/src/Compiler/Monomorphize/Shared.elm` (new)

Extract state-mutation helpers that both monomorphizers need. Use Elm record extensibility
so they work with any state type that has the required fields:

```elm
module Compiler.Monomorphize.Shared exposing
    ( enqueueSpec
    , collectCallsFromNode
    , nodeHasEffects
    , toptGlobalToMono
    , monoGlobalToTOpt
    )

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.BitSet as BitSet
import Compiler.Monomorphize.Registry as Registry

{-| Enqueue a specialization, deduplicating via the scheduled BitSet.
    Works with any state that has worklist, registry, and scheduled fields.
-}
enqueueSpec :
    Mono.Global
    -> Mono.MonoType
    -> Maybe Mono.LambdaId
    -> { s | worklist : List WorkItem, registry : Mono.SpecializationRegistry, scheduled : BitSet.BitSet }
    -> ( Mono.SpecId, { s | worklist : List WorkItem, registry : Mono.SpecializationRegistry, scheduled : BitSet.BitSet } )
enqueueSpec global monoType maybeLambda state =
    let
        ( specId, newRegistry ) =
            Registry.getOrCreateSpecId global monoType maybeLambda state.registry
    in
    if BitSet.member specId state.scheduled then
        ( specId, { state | registry = newRegistry } )
    else
        ( specId
        , { state
            | registry = newRegistry
            , scheduled = BitSet.insertGrowing specId state.scheduled
            , worklist = SpecializeGlobal specId :: state.worklist
          }
        )
```

Note: Elm's record extensibility means this works with both `MonoState` and `MonoDirectState`
as long as they have `worklist`, `registry`, and `scheduled` fields. Both already do.

Similarly extract `collectCallsFromNode`, `nodeHasEffects`, and global conversion helpers
that are identical between the two monomorphizers.

**Changes in existing monomorphizer:**
- `Compiler.Monomorphize.Monomorphize` and `Compiler.Monomorphize.Specialize` import from
  `Shared` instead of defining their own copies.

**Changes in MonoDirect:**
- `MonoDirect.Monomorphize` and `MonoDirect.Specialize` import from `Shared`.

### 9.2 Shared Graph Assembly (Q4 implementation)

**File:** `compiler/src/Compiler/Monomorphize/Assemble.elm` (new)

```elm
module Compiler.Monomorphize.Assemble exposing (AssembleInput, assembleGraph)

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.Data.BitSet as BitSet
import Compiler.Monomorphize.Prune as Prune
import Dict exposing (Dict)

{-| Input record for graph assembly. Both monomorphizers construct this
    from their respective state types.
-}
type alias AssembleInput =
    { nodes : Dict Int Mono.MonoNode
    , registry : Mono.SpecializationRegistry
    , callEdges : Dict Int (List Int)
    , specHasEffects : BitSet.BitSet
    , specValueUsed : BitSet.BitSet
    , mainSpecId : Mono.SpecId
    , globalTypeEnv : TypeEnv.GlobalTypeEnv
    }

{-| Assemble the final MonoGraph from accumulated specialization state.
    Handles MVar erasure, registry patching (MONO_017), and pruning.
-}
assembleGraph : AssembleInput -> Mono.MonoGraph
assembleGraph input =
    let
        -- ... MVar erasure logic (dead-value, CEcoValue, CNumber)
        -- ... registry patching (reverseMapping + mapping rebuild)
        -- ... graph construction
        rawGraph = ...
    in
    Prune.pruneUnreachableSpecs input.globalTypeEnv rawGraph
```

**Migration**: Extract the ~130 lines of `assembleRawGraph` from `Monomorphize.elm` into
this module. The existing monomorphizer constructs `AssembleInput` from its `MonoState`;
MonoDirect constructs it from `MonoDirectState`. Both call `Assemble.assembleGraph`.

---

## Section 10: `tvar = Nothing` Validation (Q5 details)

Already covered by P1a (`ensureSolverBackedNode`, `requireTVar`, `requireTVarExpr`).

**Additional detail**: When `requireTVar` fires at runtime in tests, the fix is always
upstream in the earlier pipeline:

| Crash location | Fix location |
|---------------|-------------|
| Define/TrackedDefine node meta | `LocalOpt.Typed.Module.elm` — propagate tvar from def's body |
| Root body expression | `LocalOpt.Typed.Expression.elm` — propagate tvar through optimize |
| Port node meta | `LocalOpt.Typed.Port.elm` — thread tvar to port node Meta |
| Inner expression | `LocalOpt.Typed.Expression.elm` — specific branch losing tvar |

Never weaken MonoDirect to accept `Nothing`. Always fix P1 coverage.

---

## Section 11: `monoTypeOf` Performance (Q6 details)

Accept O(α(n)) cost per expression. No caching for initial implementation.

**Deferred caching design** (implement only if profiling shows hotspots):

```elm
type alias CachingLocalView =
    { base : LocalView
    , cache : Dict Int Mono.MonoType  -- keyed by Pt index
    }

cachedMonoTypeOf : CachingLocalView -> TypeVar -> ( Mono.MonoType, CachingLocalView )
cachedMonoTypeOf view (IO.Pt idx) =
    case Dict.get idx view.cache of
        Just cached ->
            ( cached, view )
        Nothing ->
            let result = view.base.monoTypeOf (IO.Pt idx)
            in ( result, { view | cache = Dict.insert idx result view.cache } )
```

This changes the `specializeExpr` signature to thread `CachingLocalView` instead of
`LocalView`. Deferred because it adds complexity and may not be needed.

---

## Section 12: `RawLayout` and Record Extensions (Q8, Q10 details)

### 12.1 `RawLayout` export policy (Q8)

Export `RawLayout(..)` fully from `SolverSnapshot.elm`:

```elm
module Compiler.Type.SolverSnapshot exposing
    ( SolverSnapshot, SolverState, TypeVar, LocalView
    , RawLayout(..), PrimitiveKind(..)
    , fromSolveResult, exprVarFromId, resolveVariable, lookupDescriptor
    , rawLayoutOfVar, recordLayoutOfVar, tupleLayoutOfVar
    , withLocalUnification, specializeFunction
    , freshStructureVar, freshFlexVar, monoTypeToVar
    , walkAndUnify, defaultNumericVarsToInt
    , flattenRecordFields
    )
```

### 12.2 Record extension flattening (Q10)

**File:** `compiler/src/Compiler/Type/SolverSnapshot.elm`

`IO.Record1` is `Record1 (Dict String String Variable) Variable` where the second `Variable`
is the extension. Must follow it to get complete field set.

```elm
{-| Recursively flatten record fields by following extension variables.
    Handles nested Record1/EmptyRecord1 structures.
-}
flattenRecordFields :
    Array IO.PointInfo -> Array IO.Descriptor
    -> Dict String TypeVar -> TypeVar
    -> Dict String TypeVar
flattenRecordFields pointInfo descriptors acc extVar =
    let
        root = resolveVariableHelp pointInfo descriptors extVar
    in
    case root of
        IO.Pt rootIdx ->
            case Array.get rootIdx descriptors of
                Just (IO.Descriptor props) ->
                    case props.content of
                        IO.Structure (IO.Record1 fields nextExt) ->
                            let
                                -- Merge fields into accumulator
                                -- IO.Record1 fields is Dict String String Variable
                                acc1 = Data.Map.foldl identity
                                    (\fieldName fieldVar dict -> Dict.insert fieldName fieldVar dict)
                                    acc fields
                            in
                            flattenRecordFields pointInfo descriptors acc1 nextExt

                        IO.Structure IO.EmptyRecord1 ->
                            acc  -- End of extension chain

                        IO.FlexVar _ ->
                            acc  -- Unconstrained extension; treat as closed

                        _ ->
                            acc  -- Non-record; stop

                Nothing ->
                    acc

{-| Get complete record fields for a variable, following all extensions. -}
recordLayoutOfVar : SolverSnapshot -> TypeVar -> Result String (Dict String TypeVar)
recordLayoutOfVar snapshot var =
    let
        root = resolveVariable snapshot var
    in
    case root of
        IO.Pt rootIdx ->
            case Array.get rootIdx snapshot.state.descriptors of
                Just (IO.Descriptor props) ->
                    case props.content of
                        IO.Structure (IO.Record1 fields extVar) ->
                            let
                                -- Start with direct fields, then follow extension
                                baseFields = Data.Map.foldl identity
                                    (\name fVar d -> Dict.insert name fVar d)
                                    Dict.empty fields
                                allFields = flattenRecordFields
                                    snapshot.state.pointInfo
                                    snapshot.state.descriptors
                                    baseFields extVar
                            in
                            Ok allFields

                        IO.Structure IO.EmptyRecord1 ->
                            Ok Dict.empty

                        _ ->
                            Err "recordLayoutOfVar: not a record type"

                Nothing ->
                    Err "recordLayoutOfVar: descriptor not found"
```

---

## Section 13: Annotation vs Body Vars (Q9 details)

### Divergence cases

| Scenario | annotation var | body var | Diverge? |
|----------|---------------|----------|----------|
| No type annotation | Same as body | body root | No |
| Annotation matches body | Unified to same root | Same root | No |
| Annotation more general than body | `a -> a` | `number -> number` | **Yes** |
| Optimizer changes body type | Original | Changed | **Yes** (bug) |

### Optional test invariant SNAP_ANN_001

**File:** `compiler/tests/TestLogic/Type/AnnotationVsBodyTest.elm` (new, optional)

```elm
{-| Check that annotation and body vars resolve to the same root.
    Divergence is valid for type-annotated functions but worth flagging.
-}
checkAnnotationBodyConsistency :
    SolverSnapshot -> Dict Mono.Global FuncVars -> List String
checkAnnotationBodyConsistency snapshot funcVars =
    DMap.foldl Mono.toComparableGlobal
        (\global { annotation, body } warnings ->
            let
                annotRoot = SolverSnapshot.resolveVariable snapshot annotation
                bodyRoot = SolverSnapshot.resolveVariable snapshot body
            in
            if annotRoot /= bodyRoot then
                ("Annotation/body divergence for " ++ Debug.toString global) :: warnings
            else
                warnings
        )
        []
        funcVars
```

This runs as a diagnostic, not a hard failure. Log divergences for investigation.

---

## Invariants Summary

| Invariant | Description | Enforced by |
|-----------|-------------|-------------|
| **SNAP_TVAR_001** | Specialization-relevant nodes must have `tvar /= Nothing` | `requireTVar`, `ensureSolverBackedNode` |
| **SNAP_ALIAS_001** | All mono-time queries operate on alias-free variables | `resolveVariable` unwraps aliases |
| **SNAP_NUM_001** | `LocalView.monoTypeOf` never returns `MVar _ CNumber` | `defaultNumericVarsToInt` before LocalView |
| **SNAP_ANN_001** | Annotation and body vars should resolve to same root (diagnostic) | Test helper, not hard failure |

---

## Risks

1. **tvar propagation gaps** (P1): Missing tvars cause crashes via SNAP_TVAR_001. P1a's
   validation pass surfaces these before the worklist starts.
2. **Solver state consistency**: Creating fresh vars in local state + running unify must work
   correctly with the snapshot's existing structure. The unifier may assume rank ordering or
   other properties we need to maintain.
3. **Unify.unify return value**: Currently returns `(IO.State, Result)`. If unification fails
   (type mismatch), we get an error. Need to handle gracefully — a type mismatch during
   specialization indicates a bug.
4. **walkAndUnify completeness**: Must handle all FlatType × MonoType combinations. Missing
   cases produce wrong types silently.
5. **Let-poly nesting depth**: Deeply nested let-poly requires nested LocalView copies.
   Each is O(1) (structural sharing), but the unification work compounds.
6. **Record extension chains** (Q10): `flattenRecordFields` must handle arbitrary nesting.
   Unconstrained extensions (flex vars) are treated as closed — correct after specialization
   unification, but verify no edge cases leak through.
7. **FuncVars population completeness** (P4): `buildFuncVars` only populates Define/TrackedDefine.
   Port nodes with expression bodies also need FuncVars entries if they participate in
   specialization. Cycle members need careful handling.
8. **Shared module extraction** (P5): Changing `enqueueSpec` and other helpers to use record
   extensibility requires that both state types have identically-named fields with compatible
   types. Verify field name alignment between `MonoState` and `MonoDirectState`.
9. **Numeric defaulting scope**: `defaultNumericVarsToInt` scans ALL descriptors, not just
   reachable ones. This is correct (unreachable vars don't affect output) but wasteful for
   large solver states. Not a concern for test-only pipeline.
