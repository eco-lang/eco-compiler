module Compiler.GlobalOpt.Staging exposing (regroup, checkClosureStaging)

{-| Staging regroups function types so that each closure's type has as many
parameters in its first stage as the closure takes (GOPT\_001).

A function value can take its arguments in groups, called stages, and the list
of group sizes is its segmentation. Monomorphization keeps every function type
curried, one argument per stage; this pass rewrites the type of every
`MonoClosure` and `MonoTailFunc` so that its first stage takes exactly the
closure's parameters and the remaining arguments form one further stage
(`flattenTypeToArity`), and gives every `MonoDefine` the type of its rewritten
expression. It creates no values.

**History** (plans/staging-honesty-and-production-test-pipeline.md P3). This
module used to build a union-find over function producers and slots, pick a
segmentation per class by majority vote, and wrap the producers that
disagreed. Measured on 2026-10-06 it inserted no wrapper in the self-compile,
the E2E corpus or the elm-test programs: the graph never connected a `case`'s
inline branches, function arguments to parameters, or let-bound variables to
their producers, and pre-mono η-expansion dissolves the joins a vote could
have reconciled. Its one other output, the set of "dynamic" slots, was exactly
the function-typed parameters of tail functions, which
`MonoGlobalOptimize.isDynamicCallee` now computes directly. The vote and the
wrappers were removed; the type regrouping below is what remained in effect,
and the output is byte-identical. A join of differently staged lambdas keeps
its branches' own staging; GOPT\_003 makes no call claim more.

@docs regroup, checkClosureStaging

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Monomorphize.Closure as Closure
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Utils.Crash exposing (crash)



-- ============================================================================
-- REGROUP (GOPT_001)
-- ============================================================================


{-| Regroups the type of every closure and tail function in the graph to its
parameter count, and retypes every define to its rewritten expression.
-}
regroup : Mono.MonoGraph -> Mono.MonoGraph
regroup (Mono.MonoGraph mono0) =
    Mono.MonoGraph { mono0 | nodes = Array.map (Maybe.map regroupNode) mono0.nodes }


regroupNode : Mono.MonoNode -> Mono.MonoNode
regroupNode node =
    case node of
        Mono.MonoTailFunc params body monoType ->
            Mono.MonoTailFunc params (regroupExpr body) (flattenTypeToArity (List.length params) monoType)

        Mono.MonoDefine expr _ ->
            let
                newExpr =
                    regroupExpr expr
            in
            Mono.MonoDefine newExpr (Mono.typeOf newExpr)

        _ ->
            node


regroupExpr : Mono.MonoExpr -> Mono.MonoExpr
regroupExpr expr =
    case expr of
        Mono.MonoClosure closureInfo body monoType ->
            Mono.MonoClosure closureInfo
                (regroupExpr body)
                (flattenTypeToArity (List.length closureInfo.params) monoType)

        Mono.MonoIf branches elseExpr monoType ->
            Mono.MonoIf
                (List.map (\( cond, then_ ) -> ( regroupExpr cond, regroupExpr then_ )) branches)
                (regroupExpr elseExpr)
                monoType

        Mono.MonoCase name1 name2 decider branches monoType ->
            Mono.MonoCase name1
                name2
                (regroupDecider decider)
                (List.map (\( idx, branchExpr ) -> ( idx, regroupExpr branchExpr )) branches)
                monoType

        Mono.MonoLet def body monoType ->
            Mono.MonoLet (regroupDef def) (regroupExpr body) monoType

        Mono.MonoCall region callee args monoType callInfo ->
            Mono.MonoCall region (regroupExpr callee) (List.map regroupExpr args) monoType callInfo

        Mono.MonoRecordCreate fields monoType ->
            Mono.MonoRecordCreate (List.map (\( name, e ) -> ( name, regroupExpr e )) fields) monoType

        Mono.MonoRecordUpdate base fields monoType ->
            Mono.MonoRecordUpdate (regroupExpr base) (List.map (\( name, e ) -> ( name, regroupExpr e )) fields) monoType

        Mono.MonoTupleCreate region exprs monoType ->
            Mono.MonoTupleCreate region (List.map regroupExpr exprs) monoType

        Mono.MonoList region exprs monoType ->
            Mono.MonoList region (List.map regroupExpr exprs) monoType

        Mono.MonoRecordAccess inner name monoType ->
            Mono.MonoRecordAccess (regroupExpr inner) name monoType

        Mono.MonoDestruct destructor inner monoType ->
            Mono.MonoDestruct destructor (regroupExpr inner) monoType

        Mono.MonoTailCall name args monoType ->
            Mono.MonoTailCall name (List.map (\( argName, e ) -> ( argName, regroupExpr e )) args) monoType

        _ ->
            expr


regroupDef : Mono.MonoDef -> Mono.MonoDef
regroupDef def =
    case def of
        Mono.MonoDef name expr ->
            Mono.MonoDef name (regroupExpr expr)

        Mono.MonoTailDef name params expr ->
            Mono.MonoTailDef name params (regroupExpr expr)


regroupDecider : Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice
regroupDecider decider =
    case decider of
        Mono.Leaf (Mono.Inline expr) ->
            Mono.Leaf (Mono.Inline (regroupExpr expr))

        Mono.Leaf (Mono.Jump idx) ->
            Mono.Leaf (Mono.Jump idx)

        Mono.Chain tests success failure ->
            Mono.Chain tests (regroupDecider success) (regroupDecider failure)

        Mono.FanOut path edges fallback ->
            Mono.FanOut path
                (List.map (\( test, sub ) -> ( test, regroupDecider sub )) edges)
                (regroupDecider fallback)


{-| Flatten a function type to a given arity.
Flattens nested MFunction to match the target param count.
-}
flattenTypeToArity : Int -> Mono.MonoType -> Mono.MonoType
flattenTypeToArity targetArity monoType =
    let
        -- Rebuilder: all re-segmented stage arrows of one callable share the
        -- original head annotation (stages share provenance).
        anno =
            Mono.headAnno monoType

        ( allArgs, finalResult ) =
            Closure.flattenFunctionType monoType
    in
    if targetArity == 0 then
        -- Not a function type, return as-is
        monoType

    else if List.length allArgs == targetArity then
        -- Already correct arity
        Mono.mFunction anno allArgs finalResult

    else if List.length allArgs > targetArity then
        -- More args than params - take first N, nest the rest
        let
            ( firstArgs, restArgs ) =
                splitAt targetArity allArgs

            nestedResult =
                if List.isEmpty restArgs then
                    finalResult

                else
                    Mono.mFunction anno restArgs finalResult
        in
        Mono.mFunction anno firstArgs nestedResult

    else if List.isEmpty allArgs then
        -- Non-function type - return as-is
        monoType

    else
        -- Fewer args than params - mono graph is inconsistent
        crash
            ("flattenTypeToArity: paramCount ("
                ++ String.fromInt targetArity
                ++ ") > number of flattened args ("
                ++ String.fromInt (List.length allArgs)
                ++ "); mono graph is inconsistent"
            )


{-| Split a list at index n.
-}
splitAt : Int -> List a -> ( List a, List a )
splitAt n xs =
    ( List.take n xs, List.drop n xs )



-- ============================================================================
-- CHECK CLOSURE STAGING (GOPT_001)
-- ============================================================================


{-| GOPT\_001: every `MonoClosure` has as many parameters as its type's first
stage, and every tail function as many as its node type's first stage. Returns
one message per violation, naming the closure's lambda or the node's SpecId.
`Compiler.Pipeline.Steps.checkClosureStaging` runs it under `mono.validate`.
-}
checkClosureStaging : Mono.MonoGraph -> List String
checkClosureStaging (Mono.MonoGraph mono) =
    let
        firstStage t =
            List.length (Mono.stageParamTypes t)

        lambdaName (Mono.AnonymousLambda home uid) =
            ModuleName.toComparableCanonical home ++ " lambda " ++ String.fromInt uid

        step specId acc e =
            case e of
                Mono.MonoClosure info _ t ->
                    if List.length info.params == firstStage t then
                        acc

                    else
                        ("GOPT_001: SpecId "
                            ++ String.fromInt specId
                            ++ ": closure "
                            ++ lambdaName info.lambdaId
                            ++ " has "
                            ++ String.fromInt (List.length info.params)
                            ++ " params but its type's first stage takes "
                            ++ String.fromInt (firstStage t)
                        )
                            :: acc

                _ ->
                    acc

        node specId maybeNode acc =
            case maybeNode of
                Just (Mono.MonoDefine e _) ->
                    MonoTraverse.foldExprAccFirst (step specId) acc e

                Just (Mono.MonoTailFunc params e t) ->
                    MonoTraverse.foldExprAccFirst (step specId)
                        (if List.length params == firstStage t then
                            acc

                         else
                            ("GOPT_001: SpecId "
                                ++ String.fromInt specId
                                ++ ": tail function has "
                                ++ String.fromInt (List.length params)
                                ++ " params but its type's first stage takes "
                                ++ String.fromInt (firstStage t)
                            )
                                :: acc
                        )
                        e

                Just (Mono.MonoPortIncoming e _) ->
                    MonoTraverse.foldExprAccFirst (step specId) acc e

                Just (Mono.MonoPortOutgoing e _) ->
                    MonoTraverse.foldExprAccFirst (step specId) acc e

                _ ->
                    acc
    in
    Array.foldl (\maybeNode ( specId, acc ) -> ( specId + 1, node specId maybeNode acc )) ( 0, [] ) mono.nodes
        |> Tuple.second
        |> List.reverse



-- ============================================================================
-- ANNOTATE CALL STAGING
-- ============================================================================
