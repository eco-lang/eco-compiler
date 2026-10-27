module Compiler.GlobalOpt.Staging exposing (regroup, checkClosureStaging)

{-| Code generation relies on a closure's type agreeing with the closure about
how many arguments it takes at once, and this module rewrites the types of the
closures in a monomorphized graph's define and tail function nodes so that they
do.

A function value can take its arguments in groups, called stages, and the list
of group sizes is its segmentation. A function type records a segmentation as
nested arrows, one arrow per stage, so the same closure can carry a type whose
first stage is shorter or longer than its parameter list.

`regroup` rewrites the type of each `MonoClosure` with at least one parameter
in a define or tail function node, other than closures inside a closure's
capture list, and of every `MonoTailFunc` node with at least one parameter, so
that its first stage takes exactly its parameters and any remaining arguments
form one further stage, and gives every `MonoDefine` the type of its rewritten
expression. Port nodes are left unchanged. It creates no values and changes no
expression's shape. Only these types change: a `case` or `if` whose branches
are differently staged closures keeps its own stored type, and its branches
keep their own staging.

`checkClosureStaging` checks this agreement on a graph and reports each closure
or tail function that breaks it.

@docs regroup, checkClosureStaging

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Monomorphize.Closure as Closure
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Utils.Crash exposing (crash)


{-| Returns the graph with the types of its defines' and tail functions'
closures and tail functions regrouped as the module documentation describes,
and every define retyped to its rewritten expression.

Port nodes, and closures inside them, are left as they are.

-}
regroup : Mono.MonoGraph -> Mono.MonoGraph
regroup (Mono.MonoGraph mono0) =
    Mono.MonoGraph { mono0 | nodes = Array.map (Maybe.map regroupNode) mono0.nodes }


{-| Returns a define or tail function node with its closures regrouped, and
any other node unchanged. A tail function's own type is regrouped to its
parameter count.
-}
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


{-| Returns `expr` with each closure in it that has at least one parameter
and is not inside a closure's capture list retyped so that its first stage
takes its parameters. Other expressions keep their stored types.
-}
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


{-| Returns a let-bound definition with its body regrouped.
-}
regroupDef : Mono.MonoDef -> Mono.MonoDef
regroupDef def =
    case def of
        Mono.MonoDef name expr ->
            Mono.MonoDef name (regroupExpr expr)

        Mono.MonoTailDef name params expr ->
            Mono.MonoTailDef name params (regroupExpr expr)


{-| Returns a decision tree with the expressions inlined in its leaves
regrouped. Jump leaves name a branch of the enclosing `MonoCase`, which
`regroupExpr` regroups separately.
-}
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


{-| Returns `monoType` re-staged so that its first stage takes `targetArity`
arguments and the rest, if any, form one second stage.

Every stage arrow of the result carries the lambda set annotation of
`monoType`'s outermost arrow; the annotations of its inner arrows are dropped.
A `targetArity` of zero, or a type that is not a function, gives `monoType`
unchanged. A function type with fewer arguments across all its stages than
`targetArity` crashes, because the graph is then inconsistent.

-}
flattenTypeToArity : Int -> Mono.MonoType -> Mono.MonoType
flattenTypeToArity targetArity monoType =
    let
        anno =
            Mono.headAnno monoType

        ( allArgs, finalResult ) =
            Closure.flattenFunctionType monoType
    in
    if targetArity == 0 then
        monoType

    else if List.length allArgs == targetArity then
        Mono.mFunction anno allArgs finalResult

    else if List.length allArgs > targetArity then
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
        monoType

    else
        crash
            ("flattenTypeToArity: paramCount ("
                ++ String.fromInt targetArity
                ++ ") > number of flattened args ("
                ++ String.fromInt (List.length allArgs)
                ++ "); mono graph is inconsistent"
            )


{-| Returns the first `n` elements of `xs` and the elements after them.
-}
splitAt : Int -> List a -> ( List a, List a )
splitAt n xs =
    ( List.take n xs, List.drop n xs )


{-| Returns one message, in node order, for each `MonoClosure` whose parameter
count differs from its type's first stage, and for each tail function node whose
parameter count differs from its node type's first stage. An empty list means
none was found.

Closures are looked for in define, tail function and port nodes. Each message
starts with the tag `GOPT_001:` and names the node's SpecId, and for a closure
its lambda.

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
