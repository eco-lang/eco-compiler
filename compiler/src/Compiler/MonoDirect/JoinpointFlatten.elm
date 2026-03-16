module Compiler.MonoDirect.JoinpointFlatten exposing (flattenGraphJoinpoints)

{-| Joinpoint flattening pass for MonoGraph.

Detects the pattern where a closure's body is a case expression whose jump
targets all return closures with compatible parameter lists, and flattens
the inner closures into the outer one by merging parameter lists.

This runs as a post-monomorphization pass before pruning.

@docs flattenGraphJoinpoints

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name exposing (Name)
import Compiler.Monomorphize.Closure as Closure


{-| Flatten joinpoint closures in all nodes of a MonoGraph.
-}
flattenGraphJoinpoints : Mono.MonoGraph -> Mono.MonoGraph
flattenGraphJoinpoints (Mono.MonoGraph record) =
    Mono.MonoGraph
        { record
            | nodes = Array.map (Maybe.map flattenNode) record.nodes
        }


flattenNode : Mono.MonoNode -> Mono.MonoNode
flattenNode node =
    case node of
        Mono.MonoDefine expr t ->
            Mono.MonoDefine (flattenExpr expr) t

        Mono.MonoTailFunc params expr t ->
            Mono.MonoTailFunc params (flattenExpr expr) t

        Mono.MonoPortIncoming expr t ->
            Mono.MonoPortIncoming (flattenExpr expr) t

        Mono.MonoPortOutgoing expr t ->
            Mono.MonoPortOutgoing (flattenExpr expr) t

        Mono.MonoCycle defs t ->
            Mono.MonoCycle (List.map (\( n, e ) -> ( n, flattenExpr e )) defs) t

        _ ->
            node


{-| Recursively flatten joinpoint closures in an expression (bottom-up).
-}
flattenExpr : Mono.MonoExpr -> Mono.MonoExpr
flattenExpr expr =
    case expr of
        Mono.MonoClosure info body funcType ->
            let
                flatBody =
                    flattenExpr body
            in
            flattenJoinpointClosure info flatBody funcType

        Mono.MonoLet def body t ->
            Mono.MonoLet (flattenDef def) (flattenExpr body) t

        Mono.MonoIf branches final t ->
            Mono.MonoIf
                (List.map (\( c, b ) -> ( flattenExpr c, flattenExpr b )) branches)
                (flattenExpr final)
                t

        Mono.MonoCase scrutName scrutVar decider jumps t ->
            Mono.MonoCase scrutName scrutVar
                (flattenDecider decider)
                (List.map (\( i, e ) -> ( i, flattenExpr e )) jumps)
                t

        Mono.MonoCall region callee args t callInfo ->
            Mono.MonoCall region (flattenExpr callee) (List.map flattenExpr args) t callInfo

        Mono.MonoList region elems t ->
            Mono.MonoList region (List.map flattenExpr elems) t

        Mono.MonoDestruct destructor body t ->
            Mono.MonoDestruct destructor (flattenExpr body) t

        Mono.MonoRecordCreate fields t ->
            Mono.MonoRecordCreate (List.map (\( n, e ) -> ( n, flattenExpr e )) fields) t

        Mono.MonoRecordAccess record fieldName t ->
            Mono.MonoRecordAccess (flattenExpr record) fieldName t

        Mono.MonoRecordUpdate record fields t ->
            Mono.MonoRecordUpdate (flattenExpr record) (List.map (\( n, e ) -> ( n, flattenExpr e )) fields) t

        Mono.MonoTupleCreate region elems t ->
            Mono.MonoTupleCreate region (List.map flattenExpr elems) t

        Mono.MonoTailCall name args t ->
            Mono.MonoTailCall name (List.map (\( n, e ) -> ( n, flattenExpr e )) args) t

        _ ->
            expr


flattenDef : Mono.MonoDef -> Mono.MonoDef
flattenDef def =
    case def of
        Mono.MonoDef name bound ->
            Mono.MonoDef name (flattenExpr bound)

        Mono.MonoTailDef name params bound ->
            Mono.MonoTailDef name params (flattenExpr bound)


flattenDecider : Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice
flattenDecider decider =
    case decider of
        Mono.Leaf choice ->
            Mono.Leaf (flattenChoice choice)

        Mono.Chain tests success failure ->
            Mono.Chain tests
                (flattenDecider success)
                (flattenDecider failure)

        Mono.FanOut path edges fallback ->
            Mono.FanOut path
                (List.map (\( test, d ) -> ( test, flattenDecider d )) edges)
                (flattenDecider fallback)


flattenChoice : Mono.MonoChoice -> Mono.MonoChoice
flattenChoice choice =
    case choice of
        Mono.Inline e ->
            Mono.Inline (flattenExpr e)

        Mono.Jump i ->
            Mono.Jump i


{-| Detect and flatten a joinpoint closure pattern.

Pattern:
    MonoClosure outerInfo (MonoCase ...) funcType
    where all jump targets are MonoClosure with compatible params

Flattened to:
    MonoClosure { params = outerParams ++ innerParams, ... }
        (MonoCase ... newJumps finalResultType)
        newFuncType
-}
flattenJoinpointClosure : Mono.ClosureInfo -> Mono.MonoExpr -> Mono.MonoType -> Mono.MonoExpr
flattenJoinpointClosure info body funcType =
    case body of
        Mono.MonoCase scrutName scrutVar decider jumps _ ->
            case extractLambdaBranches jumps of
                Just ( extraParams, newJumps, finalResultType ) ->
                    let
                        mergedParams =
                            info.params ++ extraParams

                        newBody =
                            Mono.MonoCase scrutName scrutVar decider newJumps finalResultType

                        captures =
                            Closure.computeClosureCaptures mergedParams newBody

                        newFuncType =
                            recomputeFunctionType mergedParams finalResultType

                        newInfo =
                            { info
                                | params = mergedParams
                                , captures = captures
                            }
                    in
                    Mono.MonoClosure newInfo newBody newFuncType

                Nothing ->
                    Mono.MonoClosure info body funcType

        _ ->
            Mono.MonoClosure info body funcType


{-| Check if all jump targets are closures with compatible params.
Returns the extra params, stripped jump targets, and the final result type.
-}
extractLambdaBranches :
    List ( Int, Mono.MonoExpr )
    -> Maybe ( List ( Name, Mono.MonoType ), List ( Int, Mono.MonoExpr ), Mono.MonoType )
extractLambdaBranches jumps =
    case jumps of
        [] ->
            Nothing

        ( firstIdx, firstExpr ) :: rest ->
            case firstExpr of
                Mono.MonoClosure innerInfo innerBody _ ->
                    let
                        refParams =
                            innerInfo.params

                        refParamTypes =
                            List.map Tuple.second refParams

                        finalResultType =
                            Mono.typeOf innerBody
                    in
                    if List.isEmpty refParams then
                        Nothing

                    else
                        let
                            checkRest =
                                List.foldl
                                    (\( idx, expr_ ) acc ->
                                        case acc of
                                            Nothing ->
                                                Nothing

                                            Just stripped ->
                                                case expr_ of
                                                    Mono.MonoClosure ci cb _ ->
                                                        if List.map Tuple.second ci.params == refParamTypes then
                                                            Just (stripped ++ [ ( idx, cb ) ])

                                                        else
                                                            Nothing

                                                    _ ->
                                                        Nothing
                                    )
                                    (Just [ ( firstIdx, innerBody ) ])
                                    rest
                        in
                        case checkRest of
                            Just newJumps ->
                                Just ( refParams, newJumps, finalResultType )

                            Nothing ->
                                Nothing

                _ ->
                    Nothing


{-| Build a function type from params and result type.
-}
recomputeFunctionType : List ( Name, Mono.MonoType ) -> Mono.MonoType -> Mono.MonoType
recomputeFunctionType params resultType =
    case params of
        [] ->
            resultType

        _ ->
            Mono.MFunction (List.map Tuple.second params) resultType
