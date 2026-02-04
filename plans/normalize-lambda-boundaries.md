# Normalize Lambda Boundaries Implementation Plan

## Overview

This plan implements a **Lambda Boundary Normalization** pass that rewrites TypedOptimized (TOpt) lambdas to reduce spurious staging boundaries. By pulling lambda parameters across `let` and `case` boundaries when semantically safe, staged currying sees flatter lambdas, resulting in fewer intermediate closures and simpler ABIs.

**Phase**: Optimization (Type-Preserving)

**Pipeline Position**: After Typed Optimization (inside `optimizeTyped`), before Monomorphization

**Related Invariants**:
- **MONO_018** — All MonoCase branches must have compatible staged currying signatures
- This pass proactively reduces staging mismatches upstream

## Motivation

Elm code like:

```elm
\x -> let t = ... in \y -> body
\x -> case sel of A -> \y -> e1; B -> \y -> e2
```

Creates spurious staging boundaries (`[1,1]` instead of `[2]`) that force:
- Extra intermediate closures
- Eta-wrapping at case joinpoints (see `staged_currying_theory.md`)
- More complex ABIs

This pass normalizes these patterns to:

```elm
\x y -> let t = ... in body
\x y -> case sel of A -> e1; B -> e2
```

This is a restricted form of the "heapless" pipeline's η-expansion idea: we maximize lambda arity where lexically safe, giving monomorphization a flatter starting point.

## Affected Files

| Action | File |
|--------|------|
| **NEW** | `compiler/src/Compiler/Optimize/Typed/NormalizeLambdaBoundaries.elm` |
| **EDIT** | `compiler/src/Compiler/Optimize/Typed/Module.elm` (hook into `optimizeTyped`) |
| **EDIT** | `THEORY.md` or `design_docs/theory/` (pipeline documentation) |
| **NEW** | `compiler/tests/Compiler/Optimize/NormalizeLambdaBoundariesTest.elm` |

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Pass location | TOpt → TOpt, inside `optimizeTyped` before `finalizeLocalGraph` | Works on LocalGraph; sees fully-typed expressions before finalization |
| Let-boundary normalization | Enabled | `let` bindings don't depend on inner params (by scoping) |
| Case-boundary normalization | Enabled when all branches have same arity + types (names may differ) | Alpha-rename to unify names |
| Type handling | Preserve outer `lambdaType`, peel inner `caseType` | Lambda's type already spans all params; case type gets narrower |
| **TrackedFunction vs Function** | **Always keep outer lambda's variant** via `LambdaKind` | `rebuildLambda` uses outer kind; inner params converted |
| **Nested normalization** | **Local fixpoint per lambda** | Iterate let/case boundary lifting until no more changes |
| **Case branch params** | **Alpha-rename to canonical names** | Fresh names via `freshName` with `_hl_` suffix |
| Dict API | `Data.Map as Dict` with `identity` comparator for `Name` | Confirmed from codebase |
| **Inline hoisting** | **Permanent** (Inline→Jump at TOpt level) | Simpler than virtual approach; later passes can re-inline if needed |
| **Case eligibility** | **All-or-nothing** (all branches must be lambdas with matching arity+types) | Partial lifting would require eta-expansion, adding closures instead of removing them |
| **Metrics/logging** | **Optional debug API** via `normalizeLocalGraphWithStats` | Keep production code clean; stats only in tests |

## Transformation Rules

### Rule 1: Let-Boundary Normalization

**Pattern**:
```elm
Function params (Let def (Function innerParams innerBody _) letType) lambdaType
```

**Condition**: Always valid when pattern matches (inner params not in scope at `let`)

**Transform to**:
```elm
Function (params ++ convertedInnerParams) (Let def innerBody letType) lambdaType
```

Where `convertedInnerParams` are rebuilt using `rebuildLambda` with the outer `LambdaKind`.

**Rationale**: The `let`-bound expression cannot reference `innerParams` because they're only bound in the inner `Function`. Moving them out preserves evaluation order.

### Rule 2: Case-Boundary Normalization with Alpha-Renaming

**Pattern**:
```elm
Function outerParams (Case label scrut decider jumps caseType) lambdaType
```
where every branch (whether in `jumps` or as `Inline` in the `Decider`) is a lambda and all branches have:
- Same arity (number of params)
- Same `Can.Type` sequence for params
- Names may differ

**Inline Handling**: The case optimizer creates `Inline expr` choices for branches referenced exactly once, and `Jump idx` for shared branches. We first **hoist lambda inlines to the jumps table** via `hoistInlineLambdaChoicesToJumps`, converting `Leaf (Inline (\params -> body))` to `Leaf (Jump idx)` with a new jump entry. This allows `extractAndUnifyBranchParams` to see all branches uniformly. Non-lambda inlines are left as-is and cause the transformation to abort (preserving the original structure).

**Example Before**:
```elm
\x ->
  case sel of
    A -> \a b -> e1
    B -> \u v -> e2
```

**Transform to** (with alpha-renaming):
```elm
\x _a_hl_0 _b_hl_1 ->
  case sel of
    A -> e1[a↦_a_hl_0, b↦_b_hl_1]
    B -> e2[u↦_a_hl_0, v↦_u_hl_1]
```

Where:
- Fresh canonical names are generated via `freshName` using `base ++ "_hl_" ++ suffix` pattern
- Each branch body is alpha-renamed via `renameExpr`
- `newCaseType` = result type after peeling `TLambda`s from `caseType`

**Rationale**: The inner params are only bound inside branch bodies, not in `scrut` or the decider structure. Names are arbitrary; only types and positions matter. Alpha-renaming allows unification across branches with different naming conventions.

## Implementation Steps

### Step 1: Create NormalizeLambdaBoundaries.elm Module

Create `compiler/src/Compiler/Optimize/Typed/NormalizeLambdaBoundaries.elm`:

```elm
module Compiler.Optimize.Typed.NormalizeLambdaBoundaries exposing
    ( LambdaKind(..)
    , RenameEnv
    , RenameCtx
    , emptyRenameCtx
    , freshName
    , insertRename
    , lambdaKindOf
    , normalizeLocalGraph
    , rebuildLambda
    , renameDecider
    , renameExpr
    )

import Compiler.AST.Canonical as Can
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name as Name
import Compiler.Optimize.Typed.DecisionTree as DT
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
```

### Step 2: Define LambdaKind Type and Helpers

```elm
{-| Which variant of lambda to use when rebuilding merged lambdas.
    PlainLambda = TOpt.Function
    TrackedLambda = TOpt.TrackedFunction (carries region for Located names)
-}
type LambdaKind
    = PlainLambda
    | TrackedLambda A.Region


{-| Determine the LambdaKind of an expression (if it's a lambda).
-}
lambdaKindOf : TOpt.Expr -> Maybe LambdaKind
lambdaKindOf expr =
    case expr of
        TOpt.Function _ _ _ ->
            Just PlainLambda

        TOpt.TrackedFunction params _ _ ->
            case params of
                ( A.At region _, _ ) :: _ ->
                    Just (TrackedLambda region)

                [] ->
                    -- Should not happen in well-formed code, but be defensive.
                    Nothing

        _ ->
            Nothing


{-| Rebuild a lambda from flat (Name, Can.Type) params using the outer kind.
    This ensures we always preserve the outer lambda's variant (decision 1).
-}
rebuildLambda :
    LambdaKind
    -> List ( Name.Name, Can.Type )
    -> TOpt.Expr
    -> Can.Type
    -> TOpt.Expr
rebuildLambda kind params body funcType =
    case kind of
        PlainLambda ->
            TOpt.Function params body funcType

        TrackedLambda region ->
            let
                locParams : List ( A.Located Name.Name, Can.Type )
                locParams =
                    List.map
                        (\( name, tipe ) -> ( A.At region name, tipe ))
                        params
            in
            TOpt.TrackedFunction locParams body funcType
```

**Note**: This loses per-parameter location info when merging params from inner lambdas; that's consistent with "use the outer lambda's variant" and is acceptable.

### Step 3: Define Fresh Name Generator and RenameEnv

```elm
{-| Mapping from original variable name to renamed variable name.
    Uses Data.Map with `identity` comparator since Name = String.
-}
type alias RenameEnv =
    Dict Name.Name Name.Name


{-| Local state for alpha-renaming (unique suffix counter).
-}
type alias RenameCtx =
    { nextId : Int
    }


emptyRenameCtx : RenameCtx
emptyRenameCtx =
    { nextId = 0 }


{-| Generate a fresh name from a base name plus unique suffix.
    Pattern: base ++ "_hl_" ++ id (hl = heapless lambda)
-}
freshName : Name.Name -> RenameCtx -> ( Name.Name, RenameCtx )
freshName base ctx =
    let
        suffix =
            String.fromInt ctx.nextId

        newName =
            base ++ "_hl_" ++ suffix
    in
    ( newName, { ctx | nextId = ctx.nextId + 1 } )


{-| Insert a rename mapping into the environment.
-}
insertRename : Name.Name -> Name.Name -> RenameEnv -> RenameEnv
insertRename oldName newName env =
    Dict.insert identity oldName newName env


{-| Look up a name in the rename environment, returning original if not found.
-}
lookupRename : RenameEnv -> Name.Name -> Name.Name
lookupRename env name =
    case Dict.get identity name env of
        Just newName ->
            newName

        Nothing ->
            name
```

### Step 4: Implement renameExpr for TOpt.Expr

This function applies a closed rename environment: it renames occurrences of variables but does NOT introduce new bindings or generate fresh names. Alpha-renaming logic owns fresh name allocation and calls `renameExpr` with a mapping that does not conflict with inner binders.

```elm
renameExpr : RenameEnv -> TOpt.Expr -> TOpt.Expr
renameExpr env expr =
    let
        ren =
            renameExpr env
    in
    case expr of
        -- Literals: unchanged
        TOpt.Bool region value tipe ->
            TOpt.Bool region value tipe

        TOpt.Chr region value tipe ->
            TOpt.Chr region value tipe

        TOpt.Str region value tipe ->
            TOpt.Str region value tipe

        TOpt.Int region value tipe ->
            TOpt.Int region value tipe

        TOpt.Float region value tipe ->
            TOpt.Float region value tipe

        -- Local variables: apply rename
        TOpt.VarLocal name tipe ->
            TOpt.VarLocal (lookupRename env name) tipe

        TOpt.TrackedVarLocal region name tipe ->
            TOpt.TrackedVarLocal region (lookupRename env name) tipe

        -- Global/external variables: unchanged
        TOpt.VarGlobal region global tipe ->
            TOpt.VarGlobal region global tipe

        TOpt.VarEnum region global index tipe ->
            TOpt.VarEnum region global index tipe

        TOpt.VarBox region global tipe ->
            TOpt.VarBox region global tipe

        TOpt.VarCycle region home name tipe ->
            -- Local name refers to a binding; apply rename
            TOpt.VarCycle region home (lookupRename env name) tipe

        TOpt.VarDebug region name home maybeUnhandled tipe ->
            TOpt.VarDebug region (lookupRename env name) home maybeUnhandled tipe

        TOpt.VarKernel region home name tipe ->
            TOpt.VarKernel region home name tipe

        -- Collections: recurse
        TOpt.List region entries tipe ->
            TOpt.List region (List.map ren entries) tipe

        -- Lambdas: rename body only (params not touched here;
        -- alpha-renaming of params handled by normalization code via rebuildLambda)
        TOpt.Function args body tipe ->
            TOpt.Function args (ren body) tipe

        TOpt.TrackedFunction args body tipe ->
            TOpt.TrackedFunction args (ren body) tipe

        -- Calls
        TOpt.Call region func args tipe ->
            TOpt.Call region (ren func) (List.map ren args) tipe

        TOpt.TailCall name namedArgs tipe ->
            let
                renPair ( argName, argExpr ) =
                    ( argName, ren argExpr )
            in
            TOpt.TailCall name (List.map renPair namedArgs) tipe

        -- Control flow
        TOpt.If branches final tipe ->
            let
                renBranch ( cond, br ) =
                    ( ren cond, ren br )
            in
            TOpt.If (List.map renBranch branches) (ren final) tipe

        TOpt.Let def body tipe ->
            TOpt.Let (renameDef env def) (ren body) tipe

        TOpt.Destruct destructor body tipe ->
            TOpt.Destruct (renameDestructor env destructor) (ren body) tipe

        TOpt.Case label root decider jumps tipe ->
            let
                newLabel =
                    lookupRename env label

                newRoot =
                    lookupRename env root

                newDecider =
                    renameDecider env decider

                newJumps =
                    List.map (\( idx, e ) -> ( idx, ren e )) jumps
            in
            TOpt.Case newLabel newRoot newDecider newJumps tipe

        -- Records
        TOpt.Accessor region fieldName tipe ->
            TOpt.Accessor region fieldName tipe

        TOpt.Access record region fieldName tipe ->
            TOpt.Access (ren record) region fieldName tipe

        TOpt.Update region record fields tipe ->
            TOpt.Update region (ren record) (Dict.map (\_ e -> ren e) fields) tipe

        TOpt.Record fields tipe ->
            TOpt.Record (Dict.map (\_ e -> ren e) fields) tipe

        TOpt.TrackedRecord region fields tipe ->
            TOpt.TrackedRecord region (Dict.map (\_ e -> ren e) fields) tipe

        -- Other
        TOpt.Unit tipe ->
            TOpt.Unit tipe

        TOpt.Tuple region a b cs tipe ->
            TOpt.Tuple region (ren a) (ren b) (List.map ren cs) tipe

        TOpt.Shader src attrs uniforms tipe ->
            TOpt.Shader src attrs uniforms tipe
```

### Step 5: Implement Helper Renaming Functions

```elm
renameDef : RenameEnv -> TOpt.Def -> TOpt.Def
renameDef env def =
    case def of
        TOpt.Def region name bound tipe ->
            TOpt.Def region (lookupRename env name) (renameExpr env bound) tipe

        TOpt.TailDef region name args body tipe ->
            -- Do not alpha-rename TailDef params here;
            -- that should be done by a higher-level transformation.
            TOpt.TailDef region name args (renameExpr env body) tipe


renameDestructor : RenameEnv -> TOpt.Destructor -> TOpt.Destructor
renameDestructor env (TOpt.Destructor name path tipe) =
    TOpt.Destructor (lookupRename env name) (renamePath env path) tipe


renamePath : RenameEnv -> TOpt.Path -> TOpt.Path
renamePath env path =
    case path of
        TOpt.Index idx hint sub ->
            TOpt.Index idx hint (renamePath env sub)

        TOpt.ArrayIndex i sub ->
            TOpt.ArrayIndex i (renamePath env sub)

        TOpt.Field fieldName sub ->
            TOpt.Field fieldName (renamePath env sub)

        TOpt.Unbox sub ->
            TOpt.Unbox (renamePath env sub)

        TOpt.Root name ->
            TOpt.Root (lookupRename env name)


renameDecider : RenameEnv -> TOpt.Decider TOpt.Choice -> TOpt.Decider TOpt.Choice
renameDecider env decider =
    case decider of
        TOpt.Leaf choice ->
            TOpt.Leaf (renameChoice env choice)

        TOpt.Chain tests success failure ->
            TOpt.Chain tests
                (renameDecider env success)
                (renameDecider env failure)

        TOpt.FanOut path edges fallback ->
            let
                renEdge ( test, subDecider ) =
                    ( test, renameDecider env subDecider )
            in
            TOpt.FanOut path (List.map renEdge edges) (renameDecider env fallback)


renameChoice : RenameEnv -> TOpt.Choice -> TOpt.Choice
renameChoice env choice =
    case choice of
        TOpt.Inline expr ->
            TOpt.Inline (renameExpr env expr)

        TOpt.Jump idx ->
            TOpt.Jump idx
```

### Step 6: Implement Core Normalization Logic

```elm
{-| Normalize a LocalGraph by applying lambda boundary normalization to all nodes.
-}
normalizeLocalGraph : TOpt.LocalGraph -> TOpt.LocalGraph
normalizeLocalGraph (TOpt.LocalGraph data) =
    TOpt.LocalGraph
        { data
            | nodes = Dict.map (\_ node -> normalizeNode node) data.nodes
        }


normalizeNode : TOpt.Node -> TOpt.Node
normalizeNode node =
    case node of
        TOpt.Define expr deps tipe ->
            TOpt.Define (normalizeExpr expr) deps tipe

        TOpt.TrackedDefine region expr deps tipe ->
            TOpt.TrackedDefine region (normalizeExpr expr) deps tipe

        TOpt.Cycle names values functions deps ->
            TOpt.Cycle names
                (List.map (\( n, e ) -> ( n, normalizeExpr e )) values)
                (List.map normalizeDef functions)
                deps

        TOpt.PortIncoming expr deps tipe ->
            TOpt.PortIncoming (normalizeExpr expr) deps tipe

        TOpt.PortOutgoing expr deps tipe ->
            TOpt.PortOutgoing (normalizeExpr expr) deps tipe

        -- Ctor, Enum, Box, Link, Kernel, Manager: no expressions to normalize
        _ ->
            node


normalizeDef : TOpt.Def -> TOpt.Def
normalizeDef def =
    case def of
        TOpt.Def region name expr tipe ->
            TOpt.Def region name (normalizeExpr expr) tipe

        TOpt.TailDef region name params expr tipe ->
            TOpt.TailDef region name params (normalizeExpr expr) tipe
```

### Step 7: Implement normalizeExpr with Fixpoint

```elm
normalizeExpr : TOpt.Expr -> TOpt.Expr
normalizeExpr expr =
    case expr of
        TOpt.Function params body lambdaType ->
            let
                normalizedBody =
                    normalizeExpr body

                ( finalParams, finalBody ) =
                    normalizeLambdaBodyFixpoint PlainLambda params normalizedBody lambdaType
            in
            rebuildLambda PlainLambda finalParams finalBody lambdaType

        TOpt.TrackedFunction params body lambdaType ->
            let
                normalizedBody =
                    normalizeExpr body

                -- Extract kind from first param's region
                kind =
                    case params of
                        ( A.At region _, _ ) :: _ ->
                            TrackedLambda region

                        [] ->
                            PlainLambda

                -- Convert to flat params for normalization
                flatParams =
                    List.map (\( A.At _ n, t ) -> ( n, t )) params

                ( finalParams, finalBody ) =
                    normalizeLambdaBodyFixpoint kind flatParams normalizedBody lambdaType
            in
            rebuildLambda kind finalParams finalBody lambdaType

        -- Other cases: recurse on children
        TOpt.Let def body letType ->
            TOpt.Let (normalizeDef def) (normalizeExpr body) letType

        TOpt.Case label root decider jumps caseType ->
            TOpt.Case label root
                (normalizeDeciderExpr decider)
                (List.map (\( i, e ) -> ( i, normalizeExpr e )) jumps)
                caseType

        TOpt.Call region func args callType ->
            TOpt.Call region (normalizeExpr func) (List.map normalizeExpr args) callType

        TOpt.If branches final ifType ->
            TOpt.If
                (List.map (\( c, b ) -> ( normalizeExpr c, normalizeExpr b )) branches)
                (normalizeExpr final)
                ifType

        TOpt.List region items listType ->
            TOpt.List region (List.map normalizeExpr items) listType

        TOpt.Tuple region a b rest tupleType ->
            TOpt.Tuple region
                (normalizeExpr a)
                (normalizeExpr b)
                (List.map normalizeExpr rest)
                tupleType

        TOpt.Record fields recType ->
            TOpt.Record (Dict.map (\_ e -> normalizeExpr e) fields) recType

        TOpt.TrackedRecord region fields recType ->
            TOpt.TrackedRecord region (Dict.map (\_ e -> normalizeExpr e) fields) recType

        TOpt.Update region base updates updateType ->
            TOpt.Update region
                (normalizeExpr base)
                (Dict.map (\_ e -> normalizeExpr e) updates)
                updateType

        TOpt.Access inner region name accessType ->
            TOpt.Access (normalizeExpr inner) region name accessType

        TOpt.Destruct destructor body destType ->
            TOpt.Destruct destructor (normalizeExpr body) destType

        -- Leaf expressions: no recursion needed
        _ ->
            expr


normalizeDeciderExpr : TOpt.Decider TOpt.Choice -> TOpt.Decider TOpt.Choice
normalizeDeciderExpr decider =
    case decider of
        TOpt.Leaf choice ->
            TOpt.Leaf (normalizeChoiceExpr choice)

        TOpt.Chain tests success failure ->
            TOpt.Chain tests
                (normalizeDeciderExpr success)
                (normalizeDeciderExpr failure)

        TOpt.FanOut path options fallback ->
            TOpt.FanOut path
                (List.map (\( t, d ) -> ( t, normalizeDeciderExpr d )) options)
                (normalizeDeciderExpr fallback)


normalizeChoiceExpr : TOpt.Choice -> TOpt.Choice
normalizeChoiceExpr choice =
    case choice of
        TOpt.Inline expr ->
            TOpt.Inline (normalizeExpr expr)

        TOpt.Jump i ->
            TOpt.Jump i
```

### Step 8: Implement Local Fixpoint for Lambda Bodies

```elm
{-| Iterate let/case boundary lifting until no more changes.
-}
normalizeLambdaBodyFixpoint :
    LambdaKind
    -> List ( Name.Name, Can.Type )
    -> TOpt.Expr
    -> Can.Type
    -> ( List ( Name.Name, Can.Type ), TOpt.Expr )
normalizeLambdaBodyFixpoint kind params body lambdaType =
    case tryNormalizeLetBoundary params body of
        Just ( newParams, newBody ) ->
            -- Keep iterating
            normalizeLambdaBodyFixpoint kind newParams newBody lambdaType

        Nothing ->
            case tryNormalizeCaseBoundary params body lambdaType of
                Just ( newParams, newBody ) ->
                    normalizeLambdaBodyFixpoint kind newParams newBody lambdaType

                Nothing ->
                    ( params, body )
```

### Step 9: Implement Let-Boundary Helper

```elm
tryNormalizeLetBoundary :
    List ( Name.Name, Can.Type )
    -> TOpt.Expr
    -> Maybe ( List ( Name.Name, Can.Type ), TOpt.Expr )
tryNormalizeLetBoundary outerParams body =
    case body of
        TOpt.Let def inner letType ->
            case inner of
                TOpt.Function innerParams innerBody _ ->
                    Just
                        ( outerParams ++ innerParams
                        , TOpt.Let def innerBody letType
                        )

                TOpt.TrackedFunction innerParams innerBody _ ->
                    let
                        converted =
                            List.map (\( A.At _ n, t ) -> ( n, t )) innerParams
                    in
                    Just
                        ( outerParams ++ converted
                        , TOpt.Let def innerBody letType
                        )

                _ ->
                    Nothing

        _ ->
            Nothing
```

### Step 10: Implement Inline-Lambda Hoisting Helper

The case optimizer creates `Inline` choices for branches referenced only once, and `Jump` choices for shared branches. Our `extractAndUnifyBranchParams` only operates on the `jumps` list. To handle simple cases where all branches are `Inline`, we first hoist lambda inlines into the jumps table.

```elm
{-| Hoist inline lambda leaves in the Decider into the jump table.

We transform:
    Leaf (Inline (\params -> body))
into:
    Leaf (Jump idx)

and append (idx, \params -> body) to the jumps list, choosing fresh
indices above any existing ones.

Non-lambda Inline leaves are left as Inline; they will NOT be
considered for case-boundary normalization.
-}
hoistInlineLambdaChoicesToJumps :
    TOpt.Decider TOpt.Choice
    -> List ( Int, TOpt.Expr )
    -> ( TOpt.Decider TOpt.Choice, List ( Int, TOpt.Expr ) )
hoistInlineLambdaChoicesToJumps decider jumps0 =
    let
        -- Determine the starting index for new jumps.
        maxIndex : Int
        maxIndex =
            jumps0
                |> List.map Tuple.first
                |> List.maximum
                |> Maybe.withDefault -1

        startIndex : Int
        startIndex =
            maxIndex + 1

        -- Walk the Decider, hoisting lambda Inlines.
        step :
            TOpt.Decider TOpt.Choice
            -> Int
            -> List ( Int, TOpt.Expr )
            -> ( TOpt.Decider TOpt.Choice, Int, List ( Int, TOpt.Expr ) )
        step dec nextIdx accJumps =
            case dec of
                TOpt.Leaf choice ->
                    case choice of
                        TOpt.Inline expr ->
                            case expr of
                                TOpt.Function _ _ _ ->
                                    ( TOpt.Leaf (TOpt.Jump nextIdx)
                                    , nextIdx + 1
                                    , ( nextIdx, expr ) :: accJumps
                                    )

                                TOpt.TrackedFunction _ _ _ ->
                                    ( TOpt.Leaf (TOpt.Jump nextIdx)
                                    , nextIdx + 1
                                    , ( nextIdx, expr ) :: accJumps
                                    )

                                -- Non-lambda Inline: leave as-is.
                                _ ->
                                    ( TOpt.Leaf (TOpt.Inline expr), nextIdx, accJumps )

                        TOpt.Jump idx ->
                            -- Already a jump; do nothing.
                            ( TOpt.Leaf (TOpt.Jump idx), nextIdx, accJumps )

                TOpt.Chain tests success failure ->
                    let
                        ( success1, next1, acc1 ) =
                            step success nextIdx accJumps

                        ( failure1, next2, acc2 ) =
                            step failure next1 acc1
                    in
                    ( TOpt.Chain tests success1 failure1, next2, acc2 )

                TOpt.FanOut path edges fallback ->
                    let
                        stepEdge ( test, subDecider ) ( edgeAcc, n, js ) =
                            let
                                ( subDecider1, n1, js1 ) =
                                    step subDecider n js
                            in
                            ( ( test, subDecider1 ) :: edgeAcc, n1, js1 )

                        ( edgesRev, next1, acc1 ) =
                            List.foldl stepEdge ( [], nextIdx, accJumps ) edges

                        ( fallback1, next2, acc2 ) =
                            step fallback next1 acc1
                    in
                    ( TOpt.FanOut path (List.reverse edgesRev) fallback1, next2, acc2 )
    in
    let
        ( newDecider, _, newJumpsRev ) =
            step decider startIndex []
    in
    ( newDecider, jumps0 ++ List.reverse newJumpsRev )
```

**Why this is needed**: The case optimizer inlines small expressions (including lambdas) directly into `Leaf (Inline expr)` choices when they're referenced only once. Without hoisting, `extractAndUnifyBranchParams` sees an empty `jumps` list and returns `Nothing`, so case-boundary normalization never triggers.

### Step 11: Implement Case-Boundary Helper with Alpha-Renaming

```elm
tryNormalizeCaseBoundary :
    List ( Name.Name, Can.Type )
    -> TOpt.Expr
    -> Can.Type
    -> Maybe ( List ( Name.Name, Can.Type ), TOpt.Expr )
tryNormalizeCaseBoundary outerParams body _ =
    case body of
        TOpt.Case label scrut decider jumps caseType ->
            let
                -- Step 1: expose all lambda branches in the jump table.
                ( deciderWithJumps, allJumps ) =
                    hoistInlineLambdaChoicesToJumps decider jumps
            in
            case extractAndUnifyBranchParams allJumps of
                Nothing ->
                    -- Either some branch is not a lambda, or arities/types mismatch;
                    -- do not normalize this case boundary.
                    Nothing

                Just ( canonicalParams, renamedJumps, arityPeeled ) ->
                    -- Step 2: peel arityPeeled argument types off the case result type.
                    case peelLambdaTypes arityPeeled caseType of
                        Just newCaseType ->
                            -- Step 3: extend outer params and rebuild Case with:
                            --   - deciderWithJumps (now using Jump choices),
                            --   - renamed jump branch bodies,
                            --   - peeled case result type.
                            Just
                                ( outerParams ++ canonicalParams
                                , TOpt.Case label scrut deciderWithJumps renamedJumps newCaseType
                                )

                        Nothing ->
                            -- Case result type is not sufficiently-curried; abort.
                            Nothing

        _ ->
            Nothing


### Step 12: Branch Parameter Extraction and Unification

This function is unchanged from before - it extracts lambdas from the jump list, checks compatibility, and performs alpha-renaming:

```elm
extractAndUnifyBranchParams :
    List ( Int, TOpt.Expr )
    -> Maybe ( List ( Name.Name, Can.Type ), List ( Int, TOpt.Expr ), Int )
extractAndUnifyBranchParams jumps =
    let
        extractBranch ( idx, expr ) =
            case expr of
                TOpt.Function params body _ ->
                    Just ( idx, params, body )

                TOpt.TrackedFunction params body _ ->
                    Just ( idx, List.map (\( A.At _ n, t ) -> ( n, t )) params, body )

                _ ->
                    Nothing

        extracted =
            List.filterMap extractBranch jumps
    in
    if List.length extracted /= List.length jumps then
        Nothing
    else
        case extracted of
            [] ->
                Nothing

            ( _, firstParams, _ ) :: rest ->
                let
                    arity =
                        List.length firstParams

                    firstTypes =
                        List.map Tuple.second firstParams

                    allCompatible =
                        List.all
                            (\( _, params, _ ) ->
                                List.length params == arity
                                    && List.map Tuple.second params == firstTypes
                            )
                            rest
                in
                if not allCompatible then
                    Nothing
                else
                    let
                        -- Generate fresh canonical names
                        ( canonicalParams, _ ) =
                            List.foldl
                                (\( name, tipe ) ( acc, ctx ) ->
                                    let
                                        ( freshN, ctx1 ) =
                                            freshName name ctx
                                    in
                                    ( acc ++ [ ( freshN, tipe ) ], ctx1 )
                                )
                                ( [], emptyRenameCtx )
                                firstParams

                        canonicalNames =
                            List.map Tuple.first canonicalParams

                        -- Rename each branch body
                        renamedJumps =
                            List.map
                                (\( idx, branchParams, branchBody ) ->
                                    let
                                        oldNames =
                                            List.map Tuple.first branchParams

                                        renameEnv =
                                            List.foldl
                                                (\( old, new ) env -> insertRename old new env)
                                                Dict.empty
                                                (List.map2 Tuple.pair oldNames canonicalNames)

                                        renamedBody =
                                            renameExpr renameEnv branchBody
                                    in
                                    ( idx, renamedBody )
                                )
                                extracted
                    in
                    Just ( canonicalParams, renamedJumps, arity )


peelLambdaTypes : Int -> Can.Type -> Maybe Can.Type
peelLambdaTypes count tipe =
    if count <= 0 then
        Just tipe
    else
        case tipe of
            Can.TLambda _ result ->
                peelLambdaTypes (count - 1) result

            _ ->
                Nothing
```

### Step 13: Wire into optimizeTyped Pipeline

Edit `compiler/src/Compiler/Optimize/Typed/Module.elm`:

**Add import:**
```elm
import Compiler.Optimize.Typed.NormalizeLambdaBoundaries as LambdaNorm
```

**Change the final line of `optimizeTyped` from:**
```elm
        |> ReportingResult.map finalizeLocalGraph
```

**To:**
```elm
        |> ReportingResult.map (LambdaNorm.normalizeLocalGraph >> finalizeLocalGraph)
```

This ensures:
- Normalization runs on fully-typed `TOpt.LocalGraph`
- Finalization continues to do only the "identity on types" canonicalization
- Monomorphization sees normalized lambda boundaries

### Step 14: Update Documentation

Add to `THEORY.md` or create `design_docs/theory/pass_normalize_lambda_boundaries_theory.md`:

```markdown
## Normalize Lambda Boundaries Pass

**Phase**: Optimization (Type-Preserving)
**Position**: Inside optimizeTyped, before finalizeLocalGraph

**Purpose**: Pull lambda parameters across let/case boundaries to reduce spurious
staging for staged currying. Transforms `[1,1]` patterns into `[2]` patterns
where semantically safe.

**Transformations**:
1. `\x -> let t = e in \y -> body` → `\x y -> let t = e in body`
2. `\x -> case s of A -> \a -> e1; B -> \b -> e2` → `\x _a_hl_0 -> case s of A -> e1[a↦_a_hl_0]; B -> e2[b↦_a_hl_0]`
   (when all branches have same arity and param types; names are alpha-renamed)

**Key Design Points**:
- Outer lambda variant (Function vs TrackedFunction) is always preserved via LambdaKind
- Case branch params are unified via alpha-renaming to fresh canonical names (_hl_ suffix)
- Local fixpoint iteration handles nested let/case chains
- Runs before finalizeLocalGraph to work on fully-typed expressions
```

### Step 15: Add Tests

Create `compiler/tests/Compiler/Optimize/NormalizeLambdaBoundariesTest.elm` with test cases for:
1. Let-boundary normalization
2. Nested let-boundaries
3. Case-boundary with matching names
4. Case-boundary with different names (alpha-renaming)
5. Case-boundary with incompatible arities (should NOT flatten)
6. Outer Function variant preservation
7. Outer TrackedFunction variant preservation

### Step 16: Optional Stats/Debug API (for development/testing)

Add a debug-only variant that returns transformation statistics:

```elm
type alias Stats =
    { letBoundariesSeen : Int
    , letBoundariesTransformed : Int
    , caseBoundariesSeen : Int
    , caseCandidates : Int       -- All branches are lambdas
    , caseTransformed : Int       -- Transformed (matching arity+types)
    , caseSkippedMismatch : Int   -- Skipped due to arity/type mismatch
    , caseSkippedNonLambda : Int  -- Skipped due to non-lambda branch
    }


emptyStats : Stats
emptyStats =
    { letBoundariesSeen = 0
    , letBoundariesTransformed = 0
    , caseBoundariesSeen = 0
    , caseCandidates = 0
    , caseTransformed = 0
    , caseSkippedMismatch = 0
    , caseSkippedNonLambda = 0
    }


{-| Debug variant that returns transformation statistics.
    Use only in tests or analysis tools, not in production.
-}
normalizeLocalGraphWithStats : TOpt.LocalGraph -> ( TOpt.LocalGraph, Stats )
```

**Implementation notes:**
- Thread a `Stats` record through the transformation functions
- Increment counters in:
  - `tryNormalizeLetBoundary`: increment `letBoundariesSeen`, and `letBoundariesTransformed` on `Just`
  - `tryNormalizeCaseBoundary`: increment `caseBoundariesSeen`, and appropriate counter based on result
  - `hoistInlineLambdaChoicesToJumps`: track how many inlines were hoisted
- Wire into a test module (e.g. `LambdaBoundaryNormalizationStatsTest`) that asserts expected transformation counts
- Keep `normalizeLocalGraph` as the production entrypoint (discards stats)

**Rationale:** Stats help validate the pass is working as expected on real code, but should not be baked into production builds.

## Verification Plan

### Unit Tests
1. Let-boundary normalization fires correctly
2. Nested let-boundaries collapse in one pass (via fixpoint)
3. Case-boundary normalization fires when branches have same arity+types
4. Case-boundary with different param names works via alpha-renaming
5. Case-boundary does NOT fire when branches differ in arity or types
6. TrackedFunction/Function variant is preserved from outer lambda
7. Capture-avoiding renaming handles shadowing correctly
8. `renameExpr` covers all TOpt.Expr variants
9. `renamePath` correctly renames Root names

### Integration Tests
1. Run `npx elm-test-rs --fuzz 1` in compiler/
2. Run `cmake --build build --target check` for E2E tests
3. Manually verify staging signatures are flatter for test cases

### Expected Staging Improvements

Before normalization:
```
\x -> let t = ... in \y -> body           -- staging: [1,1]
\x -> case ... of A -> \a -> ...; B -> \b -> ...  -- staging: [1,1] with eta-wrapper
```

After normalization:
```
\x y -> let t = ... in body               -- staging: [2]
\x _a_hl_0 -> case ... of A -> ...; B -> ...  -- staging: [2], no wrapper needed
```

## Resolved Questions

| Question | Resolution |
|----------|------------|
| TrackedFunction merging | **Always keep outer lambda's variant** via `LambdaKind` type. `rebuildLambda` uses outer kind. |
| Decider inlines | **Hoist lambda inlines to jumps table** via `hoistInlineLambdaChoicesToJumps`. The case optimizer creates `Inline` choices for branches referenced once; we convert lambda inlines to `Jump` choices so `extractAndUnifyBranchParams` can process them. Non-lambda inlines stay as-is. |
| Hoisting style | **Permanent** (Inline→Jump at TOpt level). Simpler than virtual approach; `Inline` vs `Jump` is semantically equivalent. Later passes (codegen) can re-inline unique jumps if needed. |
| Case eligibility | **All-or-nothing**. All branches must be lambdas with matching arity and parameter types. No partial transformation—eta-expanding non-lambda branches would add closures instead of removing them. |
| Nested normalization | **Local fixpoint per lambda** via `normalizeLambdaBodyFixpoint`. |
| Parameter identity for case | **Alpha-rename to canonical names** via `freshName` with `_hl_` suffix. |
| Dict API | **`Data.Map as Dict`** with `identity` comparator for `Name`. |
| Name creation | Fresh names via `base ++ "_hl_" ++ String.fromInt id`. |
| `A.zero` existence | Confirmed: `A.zero = Region (Position 0 0) (Position 0 0)`. |
| `Can.Type` equality | Structural equality (`==`) works for comparing types within case branches. |
| Pipeline hook point | **Inside `optimizeTyped`** in Module.elm, composed before `finalizeLocalGraph`. |
| Works on | **`TOpt.LocalGraph`** (per-module), not GlobalGraph. |
| Metrics/logging | **Optional debug API** via `normalizeLocalGraphWithStats`. Keep production code clean; stats only for tests/analysis. |

## Assumptions

1. **Scoping correctness**: TOpt correctly ensures `let`-bound expressions cannot reference inner lambda parameters (standard lexical scoping).

2. **Type preservation**: The outer `lambdaType` already covers all parameters; we don't need to reconstruct it.

3. **Fresh name uniqueness**: Local uniqueness within a lambda body is sufficient. The `_hl_` prefix avoids collision with `_v` (from Names.elm) and `mono_inline_` (from MonoInlineSimplify).

4. **No side effects**: Elm's purity guarantees that reordering doesn't affect semantics as long as scoping is preserved.

5. **TrackedLambda region**: When converting params, we reuse the region from the first param of a TrackedFunction (via `lambdaKindOf`).

6. **Per-parameter location loss**: When merging inner params into outer lambda via `rebuildLambda`, per-parameter location info is lost. This is acceptable for generated code.

## Summary

| Step | Description | Complexity |
|------|-------------|------------|
| 1 | Create module structure | Low |
| 2 | LambdaKind type + helpers | Low |
| 3 | FreshCtx + RenameEnv | Low |
| 4 | renameExpr (full coverage) | Medium |
| 5 | Helper rename functions | Medium |
| 6 | Core normalization (node/def) | Low |
| 7 | normalizeExpr with recursion | Medium |
| 8 | Fixpoint iteration | Low |
| 9 | Let-boundary helper | Low |
| 10 | **Inline-lambda hoisting helper** | Medium |
| 11 | Case-boundary + alpha-rename | Medium |
| 12 | Branch param extraction/unification | Medium |
| 13 | Pipeline wiring (Module.elm) | Low |
| 14 | Documentation | Low |
| 15 | Tests | Medium |
| 16 | Optional Stats/Debug API | Low |

Total estimated code: ~650-700 lines of Elm for the pass (including full renameExpr coverage, inline hoisting, and optional stats API), plus ~150-200 lines of tests.
