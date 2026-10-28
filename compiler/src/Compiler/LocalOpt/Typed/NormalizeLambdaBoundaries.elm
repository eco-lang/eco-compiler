module Compiler.LocalOpt.Typed.NormalizeLambdaBoundaries exposing
    ( LambdaKind
    , RenameCtx, RenameEnv
    , normalizeLocalGraph
    )

{-| A function written as a lambda whose body computes something and then
returns another lambda is, to everything downstream, a function of fewer
parameters that returns a closure. This module merges such lambdas into one
wider lambda where that is safe, so that later staging sees fewer curried stages
and the native back end builds fewer intermediate closures.

A _lambda boundary_ is a `let` or a `case` sitting between two layers of
lambda. The pass removes two kinds:

1.  A let boundary. `\x -> let t = e in \y -> body` becomes
    `\x y -> let t = e in body`. Any chain of nested `let`s may sit between the
    two lambdas.
2.  A case boundary. `\x -> case s of A -> \a -> e1; B -> \b -> e2` becomes
    `\x a_hl_0 -> case s of A -> e1[a := a_hl_0]; B -> e2[b := a_hl_0]`. This
    happens only when every branch of the `case` is a lambda, all with the same
    number of parameters and equal parameter types. The new parameters are named
    after the first branch's, with `_hl_` and a counter appended, and every
    branch body is renamed to use them. The counter is one supply per graph
    node, threaded through all of the node's expressions, so no two case
    boundaries of a node mint the same name. The `case`'s result type loses that
    many argument types; its type variable is left as it was.

Both rewrites move the `let` bindings and the `case` test under the merged
lambda, so they run once per full application instead of once per partial
application. Elm is pure, so only the cost changes, not the result.

The pass runs bottom-up over every expression in a module's local graph: the
body of a lambda is normalized first, then both rewrites are retried on the
lambda until neither applies. A merged lambda keeps the outer lambda's metadata,
whose type is unchanged, and has no lambda id. A merged `TrackedFunction` gives
every parameter the region of the outer lambda's first parameter.


# Lambda Kind

@docs LambdaKind


# Renaming Context

@docs RenameCtx, RenameEnv


# Transformation

@docs normalizeLocalGraph

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Reporting.Annotation as A
import Data.Map
import Dict exposing (Dict)



-- LAMBDA KIND


{-| The form a merged lambda is rebuilt in, matching the outer lambda it
replaces.

`PlainLambda` rebuilds a `TOpt.Function`. `TrackedLambda` rebuilds a
`TOpt.TrackedFunction`, and its region is given to every parameter.

-}
type LambdaKind
    = PlainLambda
    | TrackedLambda A.Region


{-| Builds a lambda of the given kind over `params` and `body`, carrying
`funcMeta` and no lambda id.
-}
rebuildLambda :
    LambdaKind
    -> List ( Name.Name, Can.Type Name )
    -> TOpt.Expr Name
    -> TOpt.Meta Name
    -> TOpt.Expr Name
rebuildLambda kind params body funcMeta =
    case kind of
        PlainLambda ->
            -- Lambda ids are stamped by a later pass, so none is given here.
            TOpt.Function Nothing params body funcMeta

        TrackedLambda region ->
            let
                locParams : List ( A.Located Name.Name, Can.Type Name )
                locParams =
                    List.map
                        (\( name, tipe ) -> ( A.At region name, tipe ))
                        params
            in
            TOpt.TrackedFunction Nothing locParams body funcMeta



-- FRESH NAME GENERATOR


{-| A renaming of local variables, from each original name to its replacement.
-}
type alias RenameEnv =
    Dict Name.Name Name.Name


{-| The state of fresh-name generation: the number the next fresh name will
end in.
-}
type alias RenameCtx =
    { nextId : Int
    }


{-| A renaming context whose first fresh name ends in 0.
-}
emptyRenameCtx : RenameCtx
emptyRenameCtx =
    { nextId = 0 }


{-| Returns `base` followed by `_hl_` and the context's counter, such as
`a_hl_0`, and the context with the counter advanced.

The name is unique only among names made from the same context, which is one
per graph node. Nothing checks it against the names already in scope, so a
source name that itself ends in `_hl_<n>` could still collide.

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


{-| Adds a renaming of `oldName` to `newName`, replacing any earlier renaming
of `oldName`.
-}
insertRename : Name.Name -> Name.Name -> RenameEnv -> RenameEnv
insertRename oldName newName env =
    Dict.insert oldName newName env


{-| Returns the replacement for `name`, or `name` itself when it is not renamed.
-}
lookupRename : RenameEnv -> Name.Name -> Name.Name
lookupRename env name =
    case Dict.get name env of
        Just newName ->
            newName

        Nothing ->
            name



-- RENAME EXPR


{-| Returns `expr` with names renamed by `env`.

Renamed are local variable uses, a `case`'s label and inspected variable, and
the root variable of a destructuring's path. Binders are never renamed (lambda
parameters, `let` and tail-definition names and parameters, destructured
names), and each one stops the renaming of its name below it: a use that refers
to a binder inside the renamed scope keeps its name. `VarCycle` and `VarDebug`
name globals (a cycle member, a `Debug` function), and `TailCall` names a
tail definition, so they are left alone too.

-}
renameExpr : RenameEnv -> TOpt.Expr Name -> TOpt.Expr Name
renameExpr env expr =
    let
        ren =
            renameExpr env
    in
    case expr of
        TOpt.Bool region value meta ->
            TOpt.Bool region value meta

        TOpt.Chr region value meta ->
            TOpt.Chr region value meta

        TOpt.Str region value meta ->
            TOpt.Str region value meta

        TOpt.Int region value meta ->
            TOpt.Int region value meta

        TOpt.Float region value meta ->
            TOpt.Float region value meta

        TOpt.VarLocal name meta ->
            TOpt.VarLocal (lookupRename env name) meta

        TOpt.TrackedVarLocal region name meta ->
            TOpt.TrackedVarLocal region (lookupRename env name) meta

        TOpt.VarGlobal region global meta ->
            TOpt.VarGlobal region global meta

        TOpt.VarEnum region global index meta ->
            TOpt.VarEnum region global index meta

        TOpt.VarBox region global meta ->
            TOpt.VarBox region global meta

        TOpt.VarCycle region home name meta ->
            TOpt.VarCycle region home name meta

        TOpt.VarDebug region name home maybeUnhandled meta ->
            TOpt.VarDebug region name home maybeUnhandled meta

        TOpt.VarKernel region kernelPrefix home name meta ->
            TOpt.VarKernel region kernelPrefix home name meta

        TOpt.List region entries meta ->
            TOpt.List region (List.map ren entries) meta

        TOpt.Function srcLam args body meta ->
            TOpt.Function srcLam args (renameExpr (removeNames (List.map Tuple.first args) env) body) meta

        TOpt.TrackedFunction srcLam args body meta ->
            TOpt.TrackedFunction srcLam args (renameExpr (removeNames (List.map (\( A.At _ n, _ ) -> n) args) env) body) meta

        TOpt.Call region func args meta ->
            TOpt.Call region (ren func) (List.map ren args) meta

        TOpt.TailCall name namedArgs meta ->
            let
                renPair ( argName, argExpr ) =
                    ( argName, ren argExpr )
            in
            TOpt.TailCall name (List.map renPair namedArgs) meta

        TOpt.If branches final meta ->
            let
                renBranch ( cond, br ) =
                    ( ren cond, ren br )
            in
            TOpt.If (List.map renBranch branches) (ren final) meta

        TOpt.Let def body meta ->
            TOpt.Let (renameDef env def) (renameExpr (removeNames [ defName def ] env) body) meta

        TOpt.Destruct destructor body meta ->
            let
                (TOpt.Destructor boundName _ _) =
                    destructor
            in
            TOpt.Destruct (renameDestructor env destructor) (renameExpr (removeNames [ boundName ] env) body) meta

        TOpt.Case label root decider jumps meta ->
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
            TOpt.Case newLabel newRoot newDecider newJumps meta

        TOpt.Accessor region fieldName meta ->
            TOpt.Accessor region fieldName meta

        TOpt.Access record region fieldName meta ->
            TOpt.Access (ren record) region fieldName meta

        TOpt.Update region record fields meta ->
            TOpt.Update region (ren record) (Data.Map.map (\_ e -> ren e) fields) meta

        TOpt.Record fields meta ->
            TOpt.Record (Dict.map (\_ e -> ren e) fields) meta

        TOpt.TrackedRecord region fields meta ->
            TOpt.TrackedRecord region (Data.Map.map (\_ e -> ren e) fields) meta

        TOpt.Unit meta ->
            TOpt.Unit meta

        TOpt.Tuple region a b cs meta ->
            TOpt.Tuple region (ren a) (ren b) (List.map ren cs) meta

        TOpt.Shader src attrs uniforms meta ->
            TOpt.Shader src attrs uniforms meta


{-| Returns `def` with its body renamed by `env`; a plain definition's own name
is renamed too, a tail definition's name and parameters are not.
-}
renameDef : RenameEnv -> TOpt.Def Name -> TOpt.Def Name
renameDef env def =
    case def of
        TOpt.Def region name bound tipe ->
            TOpt.Def region name (renameExpr env bound) tipe

        TOpt.TailDef region name args body tipe tvar ->
            TOpt.TailDef region name args (renameExpr (removeNames (name :: List.map (\( A.At _ n, _ ) -> n) args) env) body) tipe tvar


{-| The name a definition binds.
-}
defName : TOpt.Def Name -> Name.Name
defName def =
    case def of
        TOpt.Def _ name _ _ ->
            name

        TOpt.TailDef _ name _ _ _ _ ->
            name


{-| `env` without renamings of `names`: they are rebound, so uses below the
binder refer to the new binding.
-}
removeNames : List Name.Name -> RenameEnv -> RenameEnv
removeNames names env =
    List.foldl Dict.remove env names


{-| Returns the destructuring with its bound name and the root of its path
renamed by `env`.
-}
renameDestructor : RenameEnv -> TOpt.Destructor Name -> TOpt.Destructor Name
renameDestructor env (TOpt.Destructor name path meta) =
    TOpt.Destructor name (renamePath env path) meta


{-| Returns `path` with the variable at its root renamed by `env`.
-}
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


{-| Returns the decision tree with the branch bodies held inline in its leaves
renamed by `env`.
-}
renameDecider : RenameEnv -> TOpt.Decider (TOpt.Choice Name) -> TOpt.Decider (TOpt.Choice Name)
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


{-| Returns `choice` with an inline branch body renamed by `env`; a jump is
unchanged.
-}
renameChoice : RenameEnv -> TOpt.Choice Name -> TOpt.Choice Name
renameChoice env choice =
    case choice of
        TOpt.Inline expr ->
            TOpt.Inline (renameExpr env expr)

        TOpt.Jump idx ->
            TOpt.Jump idx



-- NORMALIZE LOCAL GRAPH


{-| Returns the graph with lambda boundaries removed from the expressions of
every definition, cycle and port node. Each node gets one fresh-name supply,
threaded through all of its expressions, so no two case boundaries of a node
mint the same parameter name.
-}
normalizeLocalGraph : TOpt.LocalGraph Name -> TOpt.LocalGraph Name
normalizeLocalGraph (TOpt.LocalGraph data) =
    TOpt.LocalGraph
        { data
            | nodes = Data.Map.map (\_ node -> normalizeNode node) data.nodes
        }


{-| Returns `node` with its expressions normalized. Nodes holding no
expression are returned unchanged.
-}
normalizeNode : TOpt.Node Name -> TOpt.Node Name
normalizeNode node =
    case node of
        TOpt.Define expr deps meta ->
            TOpt.Define (Tuple.first (normalizeExpr expr emptyRenameCtx)) deps meta

        TOpt.TrackedDefine region expr deps meta ->
            TOpt.TrackedDefine region (Tuple.first (normalizeExpr expr emptyRenameCtx)) deps meta

        TOpt.Cycle names values functions deps ->
            let
                ( newValues, ctx1 ) =
                    mapCtx (\( n, e ) c -> Tuple.mapFirst (Tuple.pair n) (normalizeExpr e c)) values emptyRenameCtx

                ( newFunctions, _ ) =
                    mapCtx normalizeDef functions ctx1
            in
            TOpt.Cycle names newValues newFunctions deps

        TOpt.PortIncoming expr deps meta ->
            TOpt.PortIncoming (Tuple.first (normalizeExpr expr emptyRenameCtx)) deps meta

        TOpt.PortOutgoing expr deps meta ->
            TOpt.PortOutgoing (Tuple.first (normalizeExpr expr emptyRenameCtx)) deps meta

        _ ->
            node


{-| Maps `f` over `items` left to right, threading the fresh-name supply.
-}
mapCtx : (a -> RenameCtx -> ( b, RenameCtx )) -> List a -> RenameCtx -> ( List b, RenameCtx )
mapCtx f items ctx0 =
    let
        ( revOut, ctxN ) =
            List.foldl
                (\item ( acc, c ) ->
                    let
                        ( out, c1 ) =
                            f item c
                    in
                    ( out :: acc, c1 )
                )
                ( [], ctx0 )
                items
    in
    ( List.reverse revOut, ctxN )


{-| Returns `def` with its body normalized.
-}
normalizeDef : TOpt.Def Name -> RenameCtx -> ( TOpt.Def Name, RenameCtx )
normalizeDef def ctx =
    case def of
        TOpt.Def region name expr tipe ->
            Tuple.mapFirst (\e -> TOpt.Def region name e tipe) (normalizeExpr expr ctx)

        TOpt.TailDef region name params expr tipe tvar ->
            Tuple.mapFirst (\e -> TOpt.TailDef region name params e tipe tvar) (normalizeExpr expr ctx)



-- NORMALIZE EXPR


{-| Returns `expr` with every lambda in it normalized, innermost first, and
the fresh-name supply after it.

Each lambda's body is normalized before the lambda itself has its boundaries
removed. A `TrackedFunction` with no parameters is rebuilt as a plain
`Function`.

-}
normalizeExpr : TOpt.Expr Name -> RenameCtx -> ( TOpt.Expr Name, RenameCtx )
normalizeExpr expr ctx =
    let
        norm =
            normalizeExpr

        normList =
            mapCtx normalizeExpr
    in
    case expr of
        TOpt.Function _ params body lambdaMeta ->
            let
                ( normalizedBody, ctx1 ) =
                    norm body ctx

                ( ( finalParams, finalBody ), ctx2 ) =
                    normalizeLambdaBodyFixpoint params normalizedBody ctx1
            in
            ( rebuildLambda PlainLambda finalParams finalBody lambdaMeta, ctx2 )

        TOpt.TrackedFunction _ params body lambdaMeta ->
            let
                ( normalizedBody, ctx1 ) =
                    norm body ctx

                kind =
                    case params of
                        ( A.At region _, _ ) :: _ ->
                            TrackedLambda region

                        [] ->
                            PlainLambda

                flatParams =
                    List.map (\( A.At _ n, t ) -> ( n, t )) params

                ( ( finalParams, finalBody ), ctx2 ) =
                    normalizeLambdaBodyFixpoint flatParams normalizedBody ctx1
            in
            ( rebuildLambda kind finalParams finalBody lambdaMeta, ctx2 )

        TOpt.Let def body letMeta ->
            let
                ( d, ctx1 ) =
                    normalizeDef def ctx

                ( b, ctx2 ) =
                    norm body ctx1
            in
            ( TOpt.Let d b letMeta, ctx2 )

        TOpt.Case label root decider jumps caseMeta ->
            let
                ( d, ctx1 ) =
                    normalizeDeciderExpr decider ctx

                ( js, ctx2 ) =
                    mapCtx (\( i, e ) c -> Tuple.mapFirst (Tuple.pair i) (norm e c)) jumps ctx1
            in
            ( TOpt.Case label root d js caseMeta, ctx2 )

        TOpt.Call region func args callMeta ->
            let
                ( f, ctx1 ) =
                    norm func ctx

                ( as_, ctx2 ) =
                    normList args ctx1
            in
            ( TOpt.Call region f as_ callMeta, ctx2 )

        TOpt.If branches final ifMeta ->
            let
                ( bs, ctx1 ) =
                    mapCtx
                        (\( c, b ) s0 ->
                            let
                                ( c1, s1 ) =
                                    norm c s0

                                ( b1, s2 ) =
                                    norm b s1
                            in
                            ( ( c1, b1 ), s2 )
                        )
                        branches
                        ctx

                ( fin, ctx2 ) =
                    norm final ctx1
            in
            ( TOpt.If bs fin ifMeta, ctx2 )

        TOpt.List region items listMeta ->
            Tuple.mapFirst (\is -> TOpt.List region is listMeta) (normList items ctx)

        TOpt.Tuple region a b rest tupleMeta ->
            case normList (a :: b :: rest) ctx of
                ( a1 :: b1 :: rest1, ctx1 ) ->
                    ( TOpt.Tuple region a1 b1 rest1 tupleMeta, ctx1 )

                ( _, ctx1 ) ->
                    ( expr, ctx1 )

        TOpt.Record fields recMeta ->
            let
                ( kvs, ctx1 ) =
                    mapCtx (\( k, e ) c -> Tuple.mapFirst (Tuple.pair k) (norm e c)) (Dict.toList fields) ctx
            in
            ( TOpt.Record (Dict.fromList kvs) recMeta, ctx1 )

        TOpt.TrackedRecord region fields recMeta ->
            let
                ( fs, ctx1 ) =
                    normMap fields ctx
            in
            ( TOpt.TrackedRecord region fs recMeta, ctx1 )

        TOpt.Update region base updates updateMeta ->
            let
                ( b, ctx1 ) =
                    norm base ctx

                ( us, ctx2 ) =
                    normMap updates ctx1
            in
            ( TOpt.Update region b us updateMeta, ctx2 )

        TOpt.Access inner region name accessMeta ->
            Tuple.mapFirst (\i -> TOpt.Access i region name accessMeta) (norm inner ctx)

        TOpt.Destruct destructor body destMeta ->
            Tuple.mapFirst (\b -> TOpt.Destruct destructor b destMeta) (norm body ctx)

        -- Var*, literals, Accessor, TailCall and Shader hold no lambda.
        _ ->
            ( expr, ctx )


{-| Normalizes every value of a `Data.Map`, in key order, threading the supply.
-}
normMap : Data.Map.Dict String (A.Located Name) (TOpt.Expr Name) -> RenameCtx -> ( Data.Map.Dict String (A.Located Name) (TOpt.Expr Name), RenameCtx )
normMap m ctx =
    mapCtx (\( k, e ) c -> Tuple.mapFirst (Tuple.pair k) (normalizeExpr e c)) (Data.Map.toList m) ctx
        |> Tuple.mapFirst (Data.Map.fromList A.toValue)


{-| Returns the decision tree with the branch bodies held inline in its leaves
normalized.
-}
normalizeDeciderExpr : TOpt.Decider (TOpt.Choice Name) -> RenameCtx -> ( TOpt.Decider (TOpt.Choice Name), RenameCtx )
normalizeDeciderExpr decider ctx =
    case decider of
        TOpt.Leaf choice ->
            Tuple.mapFirst TOpt.Leaf (normalizeChoiceExpr choice ctx)

        TOpt.Chain tests success failure ->
            let
                ( s, ctx1 ) =
                    normalizeDeciderExpr success ctx

                ( f, ctx2 ) =
                    normalizeDeciderExpr failure ctx1
            in
            ( TOpt.Chain tests s f, ctx2 )

        TOpt.FanOut path options fallback ->
            let
                ( os, ctx1 ) =
                    mapCtx (\( t, d ) c -> Tuple.mapFirst (Tuple.pair t) (normalizeDeciderExpr d c)) options ctx

                ( fb, ctx2 ) =
                    normalizeDeciderExpr fallback ctx1
            in
            ( TOpt.FanOut path os fb, ctx2 )


{-| Returns `choice` with an inline branch body normalized; a jump is unchanged.
-}
normalizeChoiceExpr : TOpt.Choice Name -> RenameCtx -> ( TOpt.Choice Name, RenameCtx )
normalizeChoiceExpr choice ctx =
    case choice of
        TOpt.Inline expr ->
            Tuple.mapFirst TOpt.Inline (normalizeExpr expr ctx)

        TOpt.Jump i ->
            ( TOpt.Jump i, ctx )



-- FIXPOINT ITERATION


{-| Returns the parameters and body of the lambda `\params -> body` after
removing let and case boundaries until neither rewrite applies.

A let boundary is tried before a case boundary at each step.

-}
normalizeLambdaBodyFixpoint :
    List ( Name.Name, Can.Type Name )
    -> TOpt.Expr Name
    -> RenameCtx
    -> ( ( List ( Name.Name, Can.Type Name ), TOpt.Expr Name ), RenameCtx )
normalizeLambdaBodyFixpoint params body ctx =
    case tryNormalizeLetBoundary params body of
        Just ( newParams, newBody ) ->
            normalizeLambdaBodyFixpoint newParams newBody ctx

        Nothing ->
            case tryNormalizeCaseBoundary params body ctx of
                Just ( ( newParams, newBody ), ctx1 ) ->
                    normalizeLambdaBodyFixpoint newParams newBody ctx1

                Nothing ->
                    ( ( params, body ), ctx )



-- LET-BOUNDARY NORMALIZATION


{-| Returns the definitions of the chain of `let`s at the top of `expr`,
outermost first and after those already in `acc`, and the first expression in
the chain that is not a `let`.

`acc` holds definitions in reverse order.

-}
peelLets : TOpt.Expr Name -> List (TOpt.Def Name) -> ( List (TOpt.Def Name), TOpt.Expr Name )
peelLets expr acc =
    case expr of
        TOpt.Let def inner _ ->
            peelLets inner (def :: acc)

        _ ->
            ( List.reverse acc, expr )


{-| Wraps `innerBody` in one `let` per definition, the first definition
outermost. Every `let` carries the metadata of the expression directly inside it.
-}
rebuildLets : List (TOpt.Def Name) -> TOpt.Expr Name -> TOpt.Expr Name
rebuildLets defs innerBody =
    List.foldr
        (\def body -> TOpt.Let def body (TOpt.metaOf body))
        innerBody
        defs


{-| Removes one let boundary from `\outerParams -> body`.

Returns `Nothing` unless `body` is one or more `let`s around a lambda. Otherwise
returns the outer parameters followed by the inner lambda's, and the `let`s
around the inner lambda's body.

-}
tryNormalizeLetBoundary :
    List ( Name.Name, Can.Type Name )
    -> TOpt.Expr Name
    -> Maybe ( List ( Name.Name, Can.Type Name ), TOpt.Expr Name )
tryNormalizeLetBoundary outerParams body =
    case peelLets body [] of
        ( defs, TOpt.Function _ innerParams innerBody _ ) ->
            if List.isEmpty defs then
                Nothing

            else
                Just
                    ( outerParams ++ innerParams
                    , rebuildLets defs innerBody
                    )

        ( defs, TOpt.TrackedFunction _ innerParams innerBody _ ) ->
            if List.isEmpty defs then
                Nothing

            else
                let
                    converted =
                        List.map (\( A.At _ n, t ) -> ( n, t )) innerParams
                in
                Just
                    ( outerParams ++ converted
                    , rebuildLets defs innerBody
                    )

        _ ->
            Nothing



-- CASE-BOUNDARY NORMALIZATION


{-| Moves every lambda held inline in a leaf of the decision tree into the jump
list, and returns the new tree and jump list.

Each such leaf becomes a `Jump` to a new index, numbered upwards from one above
the largest existing index, and the lambda is appended to `jumps0` under that
index. Inline leaves that are not lambdas are left in place.

-}
hoistInlineLambdaChoicesToJumps :
    TOpt.Decider (TOpt.Choice Name)
    -> List ( Int, TOpt.Expr Name )
    -> ( TOpt.Decider (TOpt.Choice Name), List ( Int, TOpt.Expr Name ) )
hoistInlineLambdaChoicesToJumps decider jumps0 =
    let
        maxIndex : Int
        maxIndex =
            jumps0
                |> List.map Tuple.first
                |> List.maximum
                |> Maybe.withDefault -1

        startIndex : Int
        startIndex =
            maxIndex + 1

        step :
            TOpt.Decider (TOpt.Choice Name)
            -> Int
            -> List ( Int, TOpt.Expr Name )
            -> ( TOpt.Decider (TOpt.Choice Name), Int, List ( Int, TOpt.Expr Name ) )
        step dec nextIdx accJumps =
            case dec of
                TOpt.Leaf choice ->
                    case choice of
                        TOpt.Inline expr ->
                            case expr of
                                TOpt.Function _ _ _ _ ->
                                    ( TOpt.Leaf (TOpt.Jump nextIdx)
                                    , nextIdx + 1
                                    , ( nextIdx, expr ) :: accJumps
                                    )

                                TOpt.TrackedFunction _ _ _ _ ->
                                    ( TOpt.Leaf (TOpt.Jump nextIdx)
                                    , nextIdx + 1
                                    , ( nextIdx, expr ) :: accJumps
                                    )

                                _ ->
                                    ( TOpt.Leaf (TOpt.Inline expr), nextIdx, accJumps )

                        TOpt.Jump idx ->
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

        ( newDecider, _, newJumpsRev ) =
            step decider startIndex []
    in
    ( newDecider, jumps0 ++ List.reverse newJumpsRev )


{-| Returns whether any leaf of the decision tree holds its branch body inline.
-}
hasAnyInline : TOpt.Decider (TOpt.Choice Name) -> Bool
hasAnyInline decider =
    case decider of
        TOpt.Leaf choice ->
            case choice of
                TOpt.Inline _ ->
                    True

                TOpt.Jump _ ->
                    False

        TOpt.Chain _ success failure ->
            hasAnyInline success || hasAnyInline failure

        TOpt.FanOut _ edges fallback ->
            List.any (\( _, d ) -> hasAnyInline d) edges || hasAnyInline fallback


{-| Removes one case boundary from `\outerParams -> body`.

Returns `Nothing` unless `body` is a `case` whose every branch, inline or in the
jump list, is a lambda, all with the same parameter count and equal parameter
types, and whose result type has at least that many argument types. Otherwise
returns the outer parameters followed by fresh ones, and the `case` with every
branch moved to the jump list and replaced by its body, renamed to the fresh
parameters, and with that many argument types removed from the result type.

-}
tryNormalizeCaseBoundary :
    List ( Name.Name, Can.Type Name )
    -> TOpt.Expr Name
    -> RenameCtx
    -> Maybe ( ( List ( Name.Name, Can.Type Name ), TOpt.Expr Name ), RenameCtx )
tryNormalizeCaseBoundary outerParams body ctx =
    case body of
        TOpt.Case label scrut decider jumps caseMeta ->
            let
                ( deciderWithJumps, allJumps ) =
                    hoistInlineLambdaChoicesToJumps decider jumps
            in
            -- An inline branch left here is not a lambda; changing the case's
            -- type would leave it with a type that no longer matches.
            if hasAnyInline deciderWithJumps then
                Nothing

            else
                case extractAndUnifyBranchParams allJumps ctx of
                    Nothing ->
                        Nothing

                    Just ( ( canonicalParams, renamedJumps, arityPeeled ), ctx1 ) ->
                        case peelLambdaTypes arityPeeled caseMeta.tipe of
                            Just newCaseTipe ->
                                Just
                                    ( ( outerParams ++ canonicalParams
                                      , TOpt.Case label scrut deciderWithJumps renamedJumps { caseMeta | tipe = newCaseTipe }
                                      )
                                    , ctx1
                                    )

                            Nothing ->
                                Nothing

        _ ->
            Nothing


{-| Returns fresh parameters shared by all the branches in `jumps`, the
branches' bodies renamed to use them, and the parameter count.

Returns `Nothing` when `jumps` is empty, or when any branch is not a lambda or
differs from the first in parameter count or parameter types. The fresh
parameters are the first branch's names with `_hl_` and their position
appended, and keep its types.

-}
extractAndUnifyBranchParams :
    List ( Int, TOpt.Expr Name )
    -> RenameCtx
    -> Maybe ( ( List ( Name.Name, Can.Type Name ), List ( Int, TOpt.Expr Name ), Int ), RenameCtx )
extractAndUnifyBranchParams jumps ctx =
    let
        extractBranch ( idx, expr ) =
            case expr of
                TOpt.Function _ params body _ ->
                    Just ( idx, params, body )

                TOpt.TrackedFunction _ params body _ ->
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
                                List.length params == arity && List.map Tuple.second params == firstTypes
                            )
                            rest
                in
                if not allCompatible then
                    Nothing

                else
                    let
                        ( revCanonicalParams, ctxAfter ) =
                            List.foldl
                                (\( name, tipe ) ( acc, c0 ) ->
                                    let
                                        ( freshN, ctx1 ) =
                                            freshName name c0
                                    in
                                    ( ( freshN, tipe ) :: acc, ctx1 )
                                )
                                ( [], ctx )
                                firstParams

                        canonicalParams =
                            List.reverse revCanonicalParams

                        canonicalNames =
                            List.map Tuple.first canonicalParams

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
                    Just ( ( canonicalParams, renamedJumps, arity ), ctxAfter )


{-| Returns what remains of `tipe` after removing its first `count` argument
types, or `Nothing` if it has fewer.

An alias of a function type is not expanded, so it counts as having none.

-}
peelLambdaTypes : Int -> Can.Type Name -> Maybe (Can.Type Name)
peelLambdaTypes count tipe =
    if count <= 0 then
        Just tipe

    else
        case tipe of
            Can.TLambda _ _ result ->
                peelLambdaTypes (count - 1) result

            _ ->
                Nothing
