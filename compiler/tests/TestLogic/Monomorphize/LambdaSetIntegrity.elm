module TestLogic.Monomorphize.LambdaSetIntegrity exposing (expectLambdaSetIntegrity)

{-| Test logic for invariant LSS\_002: lowering totality of lambda sets.

For every reachable `MonoClosure` whose `ClosureInfo.srcLambda` is
`Just m`, the head annotation of the closure's own `MonoType` must be
`LTop` or a set containing `m` — i.e. no closure instance can exist whose
own identity is missing from its arrow's claimed member set.

Runs the SOLVER engine with `lss.enabled = True` (the only pipeline that
produces real `LSet` annotations), then GlobalOpt, and checks the final
graph — so widening anywhere upstream (kernel poison, size budget,
LTop-stamping rebuilders) keeps the invariant satisfied via `LTop`.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Data.Id as Id
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Expect
import TestLogic.TestPipeline as Pipeline


{-| LSS\_002: every reachable closure's source identity is covered by its
head annotation.
-}
expectLambdaSetIntegrity : Src.Module -> Expect.Expectation
expectLambdaSetIntegrity srcModule =
    case Pipeline.runToGlobalOptLssOn srcModule of
        Err msg ->
            Expect.fail msg

        Ok { optimizedMonoGraph } ->
            let
                issues =
                    collectViolations optimizedMonoGraph
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)


collectViolations : Mono.MonoGraph -> List String
collectViolations (Mono.MonoGraph data) =
    Array.foldl
        (\maybeNode ( specId, acc ) ->
            case maybeNode of
                Nothing ->
                    ( specId + 1, acc )

                Just node ->
                    ( specId + 1
                    , List.foldl (checkExprTree specId) acc (nodeExprs node)
                    )
        )
        ( 0, [] )
        data.nodes
        |> Tuple.second


nodeExprs : Mono.MonoNode -> List Mono.MonoExpr
nodeExprs node =
    case node of
        Mono.MonoDefine expr _ ->
            [ expr ]

        Mono.MonoTailFunc _ expr _ ->
            [ expr ]

        Mono.MonoPortIncoming expr _ ->
            [ expr ]

        Mono.MonoPortOutgoing expr _ ->
            [ expr ]

        Mono.MonoCtor _ _ ->
            []

        Mono.MonoEnum _ _ ->
            []

        Mono.MonoExtern _ ->
            []

        Mono.MonoManagerLeaf _ _ ->
            []


checkExprTree : Int -> Mono.MonoExpr -> List String -> List String
checkExprTree specId root acc =
    MonoTraverse.foldExpr (checkOne specId) acc root


checkOne : Int -> Mono.MonoExpr -> List String -> List String
checkOne specId expr acc =
    case expr of
        Mono.MonoClosure info _ closType ->
            case info.srcLambda of
                Nothing ->
                    acc

                Just m ->
                    let
                        -- Fix B (LSS_017): the identity a closure's annotation
                        -- must cover is the id it was MINTED under —
                        -- spec-qualified for keyed-routed globals — not the
                        -- raw source id.
                        mid =
                            case info.lssMember of
                                Just q ->
                                    q

                                Nothing ->
                                    Id.toComparable m
                    in
                    case Mono.headAnno closType of
                        Mono.LTop ->
                            acc

                        Mono.LSet members ->
                            if List.member mid members then
                                acc

                            else
                                ("LSS_002 violation in spec "
                                    ++ String.fromInt specId
                                    ++ ": closure with srcLambda #"
                                    ++ String.fromInt mid
                                    ++ " has head annotation LSet ["
                                    ++ String.join "," (List.map String.fromInt members)
                                    ++ "] which does not contain it"
                                )
                                    :: acc

        _ ->
            acc
