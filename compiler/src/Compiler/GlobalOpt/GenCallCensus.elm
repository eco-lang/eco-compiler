module Compiler.GlobalOpt.GenCallCensus exposing (census, render, calleeTag)

{-| Why a call goes through the generic apply path
(plans/staging-honesty-and-production-test-pipeline.md P0.3).

After GlobalOpt every staged-curried call has a `CallKind`. The two generic
kinds, `CallSegmentationUnknown` and `CallGenericApply`, are applied by the
runtime reading the closure header, because the compiler could not prove the
callee's staging. This census tags each such call by the shape of its callee:

  - `param`: a parameter of a function in the same specialization;
  - `local`: any other local variable (let-bound or destructured);
  - `callResult`: the result of another call, applied again;
  - `field`: a record field read;
  - `join`: a `case` or `if` expression;
  - `global`: a global reference;
  - `other`: anything else.

It is a pure count over the graph, run only when the census is on.

@docs census, render, calleeTag

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name exposing (Name)
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Dict exposing (Dict)
import Set exposing (Set)


{-| The tag of a callee expression, given the parameter names bound in its
specialization.
-}
calleeTag : Set Name -> Mono.MonoExpr -> String
calleeTag params callee =
    case callee of
        Mono.MonoVarLocal name _ ->
            if Set.member name params then
                "param"

            else
                "local"

        Mono.MonoCall _ _ _ _ _ ->
            "callResult"

        Mono.MonoRecordAccess _ _ _ ->
            "field"

        Mono.MonoCase _ _ _ _ _ ->
            "join"

        Mono.MonoIf _ _ _ ->
            "join"

        Mono.MonoVarGlobal _ _ _ ->
            "global"

        _ ->
            "other"


{-| Counts generic calls by `<kind>:<tag>`, where kind is `segunk` or
`generic`.
-}
census : Mono.MonoGraph -> Dict String Int
census (Mono.MonoGraph mono) =
    let
        paramNames acc e =
            case e of
                Mono.MonoClosure info _ _ ->
                    List.foldl (\( n, _ ) a -> Set.insert n a) acc info.params

                Mono.MonoLet (Mono.MonoTailDef _ ps _) _ _ ->
                    List.foldl (\( n, _ ) a -> Set.insert n a) acc ps

                _ ->
                    acc

        count params acc e =
            case e of
                Mono.MonoCall _ callee _ _ info ->
                    case ( info.callModel, info.callKind ) of
                        ( Mono.StageCurried, Mono.CallSegmentationUnknown ) ->
                            bump ("segunk:" ++ calleeTag params callee) acc

                        ( Mono.StageCurried, Mono.CallGenericApply ) ->
                            bump ("generic:" ++ calleeTag params callee) acc

                        _ ->
                            acc

                _ ->
                    acc

        bump k acc =
            Dict.update k (\v -> Just (Maybe.withDefault 0 v + 1)) acc

        node params0 e acc =
            let
                params =
                    MonoTraverse.foldExprAccFirst paramNames params0 e
            in
            MonoTraverse.foldExprAccFirst (count params) acc e
    in
    Array.foldl
        (\maybeNode acc ->
            case maybeNode of
                Just (Mono.MonoDefine e _) ->
                    node Set.empty e acc

                Just (Mono.MonoTailFunc ps e _) ->
                    node (Set.fromList (List.map Tuple.first ps)) e acc

                Just (Mono.MonoPortIncoming e _) ->
                    node Set.empty e acc

                Just (Mono.MonoPortOutgoing e _) ->
                    node Set.empty e acc

                _ ->
                    acc
        )
        Dict.empty
        mono.nodes


{-| `k=v` pairs, sorted by key, space-separated.
-}
render : Dict String Int -> String
render d =
    Dict.toList d
        |> List.map (\( k, v ) -> k ++ "=" ++ String.fromInt v)
        |> String.join " "
