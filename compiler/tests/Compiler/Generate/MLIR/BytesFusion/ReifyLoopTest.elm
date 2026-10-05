module Compiler.Generate.MLIR.BytesFusion.ReifyLoopTest exposing (suite)

{-| Tests for the `Bytes.Decode.loop` arm of
`Compiler.Generate.MLIR.BytesFusion.Reify.reifyDecoder`
(src/Compiler/Generate/MLIR/BytesFusion/Reify.elm).

elm/bytes 1.0.8 declares

    loop : state -> (state -> Decoder (Step state a)) -> Decoder a

    andThen : (a -> Decoder b) -> Decoder a -> Decoder b

The reifier used to match `loop`'s arguments step function first, and the
sentinel recogniser matched `andThen` decoder first, so no loop written against
the real package was ever fused; it also accepted `==` only as a kernel named
`eq`. Behind that, its count-loop recogniser looked only at the item decoder,
ignoring the `Done` expression, so `Done acc`, `Done (List.reverse acc)` and
`Done (List.length acc)`, three different values, would all have been fused to
the same list. `reifyLoop` now matches the real argument orders, `==` as
`Basics.eq` or the `Utils.equal` kernel, and only the whole idiom, recording the
order of the list the `Done` result builds.

The fixture programs are parsed from source text and run through
`TestLogic.TestPipeline.runToGlobalOpt`, against the mock interfaces of
`Compiler.Elm.Interface.Basic.testIfaces`. In that environment the elm/bytes
functions are externs with no body, so the `Bytes.Decode.loop`,
`Bytes.Decode.map` and `Bytes.Decode.andThen` calls survive as calls and reach
the reifier exactly as written. (In a real build the inliner inlines `map`,
`succeed` and `andThen`, a form the reifier also recognises; the E2E tests
`test/elm-bytes/src/BytesLoop*Test.elm` cover it.)

The tests:

  - "loop in elm/bytes argument order is recognised": the count loop
    `loop ( 3, [] ) step` reifies to operations containing a
    `LoopDecodeList`.
  - "sentinel loop with andThen in elm/bytes argument order is recognised":
    `loop [] (\acc -> andThen (\b -> ...) unsignedInt8)` with an `if b == 0`
    test reifies to operations containing a `LoopSentinelDecodeList`.
  - GUARD "Done variants are not reified identically": among the three `Done`
    variants, no two reify to the same operations (declining, `Nothing`, is
    allowed).
  - "each Done variant reifies to its own list order, or not at all":
    `Done acc` gives a loop in reverse read order, `Done (List.reverse acc)` one
    in read order, and `Done (List.length acc)` is not fused.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Generate.MLIR.BytesFusion.LoopIR as IR
import Compiler.Generate.MLIR.BytesFusion.Reify as Reify
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Compiler.Monomorphize.Registry as Registry
import Compiler.Parse.Module as Parse
import Dict
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The four tests the module docstring lists.
-}
suite : Test
suite =
    Test.describe "BytesFusion.Reify Decode.loop (argument order and soundness)"
        [ Test.test "loop in elm/bytes argument order (state first) is recognised as a count loop" <|
            \_ ->
                case reifyLoopIn (countLoopProgram "acc") of
                    Err e ->
                        Expect.fail e

                    Ok (Just ops) ->
                        if List.any isCountLoop ops then
                            Expect.pass

                        else
                            Expect.fail ("reified, but with no LoopDecodeList: " ++ Debug.toString ops)

                    Ok Nothing ->
                        Expect.fail "Bytes.Decode.loop ( 3, [] ) step, in elm/bytes argument order, was not reified"
        , Test.test "sentinel loop with andThen in elm/bytes argument order is recognised" <|
            \_ ->
                case reifyLoopIn sentinelLoopProgram of
                    Err e ->
                        Expect.fail e

                    Ok (Just ops) ->
                        if List.any isSentinelLoop ops then
                            Expect.pass

                        else
                            Expect.fail ("reified, but with no LoopSentinelDecodeList: " ++ Debug.toString ops)

                    Ok Nothing ->
                        Expect.fail "Bytes.Decode.loop [] step with an andThen sentinel test (`byte == 0`), in elm/bytes argument order, was not reified"
        , Test.test "GUARD: Done acc / Done (List.reverse acc) / Done (List.length acc) are not reified identically" <|
            \_ ->
                let
                    results =
                        List.map (\done -> ( done, reifyLoopIn (countLoopProgram done) )) [ "acc", "(List.reverse acc)", "(List.length acc)" ]

                    errors =
                        List.filterMap
                            (\( done, r ) ->
                                case r of
                                    Err e ->
                                        Just (done ++ ": " ++ e)

                                    Ok _ ->
                                        Nothing
                            )
                            results

                    reified =
                        List.filterMap
                            (\( done, r ) ->
                                case r of
                                    Ok (Just ops) ->
                                        Just ( done, ops )

                                    _ ->
                                        Nothing
                            )
                            results

                    clashes =
                        List.concatMap
                            (\( d1, ops1 ) ->
                                List.filterMap
                                    (\( d2, ops2 ) ->
                                        if d1 < d2 && ops1 == ops2 then
                                            Just (d1 ++ " = " ++ d2)

                                        else
                                            Nothing
                                    )
                                    reified
                            )
                            reified
                in
                Expect.equal ( [], [] ) ( errors, clashes )
        , Test.test "each Done variant reifies to its own list order, or not at all" <|
            \_ ->
                Expect.equal
                    [ Ok (Just [ IR.ReverseReadOrder ]), Ok (Just [ IR.InReadOrder ]), Ok Nothing ]
                    (List.map
                        (\done -> reifyLoopIn (countLoopProgram done) |> Result.map (Maybe.map (List.filterMap loopOrder)))
                        [ "acc", "(List.reverse acc)", "(List.length acc)" ]
                    )
        ]



-- ============================================================================
-- FIXTURES
-- ============================================================================


{-| The module header shared by the fixtures. They are parsed as modules of
elm/core, which get no default imports, so every import is written out.
-}
header : String
header =
    """module Test exposing (..)

import Basics exposing (..)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Bytes exposing (Bytes)
import Bytes.Decode as D

"""


{-| A count loop in elm/bytes argument order, `D.loop ( 3, [] ) step`, whose
step decodes one `unsignedInt8` per iteration, prepends it to the accumulator,
and ends with `D.Done <done>`.
-}
countLoopProgram : String -> String
countLoopProgram done =
    let
        resultType =
            if String.contains "length" done then
                "Int"

            else
                "(List Int)"
    in
    header
        ++ "\ntestValue : Bytes -> Maybe "
        ++ resultType
        ++ """
testValue b =
    D.decode
        (D.loop ( 3, [] )
            (\\( n, acc ) ->
                if n <= 0 then
                    D.succeed (D.Done """
        ++ done
        ++ """)

                else
                    D.map (\\x -> D.Loop ( n - 1, x :: acc )) D.unsignedInt8
            )
        )
        b
"""


{-| A null-terminated loop in elm/bytes argument order: `D.loop [] step`, where
the step reads an `unsignedInt8` and, through `D.andThen` (function first),
stops at `0`.
-}
sentinelLoopProgram : String
sentinelLoopProgram =
    header
        ++ """
testValue : Bytes -> Maybe (List Int)
testValue b =
    D.decode
        (D.loop []
            (\\acc ->
                D.andThen
                    (\\byte ->
                        if byte == 0 then
                            D.succeed (D.Done acc)

                        else
                            D.succeed (D.Loop (byte :: acc))
                    )
                    D.unsignedInt8
            )
        )
        b
"""



-- ============================================================================
-- HELPERS
-- ============================================================================


{-| Compiles `source` through `runToGlobalOpt`, finds its one call of
`Bytes.Decode.loop`, and returns what `Reify.reifyDecoder` makes of that call,
as decoder operations. An `Err` names a fixture that did not compile or has no
such call.
-}
reifyLoopIn : String -> Result String (Maybe (List IR.DecoderOp))
reifyLoopIn source =
    case Parse.fromByteString (Parse.Package Pkg.core) source of
        Err _ ->
            Err "fixture does not parse"

        Ok srcModule ->
            case Pipeline.runToGlobalOpt srcModule of
                Err e ->
                    Err ("fixture does not compile: " ++ e)

                Ok { optimizedMonoGraph } ->
                    let
                        (Mono.MonoGraph g) =
                            optimizedMonoGraph
                    in
                    case findLoopCalls g.registry g.nodes of
                        [ call ] ->
                            Ok (Maybe.map (Reify.decoderNodeToOps >> Tuple.first) (Reify.reifyDecoder g.registry Dict.empty call))

                        calls ->
                            Err ("expected one Bytes.Decode.loop call, found " ++ String.fromInt (List.length calls))


{-| Every call, in any node, whose function is the global `Bytes.Decode.loop`.
-}
findLoopCalls : Mono.SpecializationRegistry -> Array.Array (Maybe Mono.MonoNode) -> List Mono.MonoExpr
findLoopCalls registry nodes =
    let
        isLoop expr =
            case expr of
                Mono.MonoCall _ (Mono.MonoVarGlobal _ specId _) _ _ _ ->
                    case Registry.lookupSpecKey specId registry of
                        Just ( Mono.Global (ModuleName.Canonical pkg modName) name, _ ) ->
                            pkg == Pkg.bytes && modName == "Bytes.Decode" && name == "loop"

                        _ ->
                            False

                _ ->
                    False

        inExpr e acc =
            MonoTraverse.foldExpr
                (\sub a ->
                    if isLoop sub then
                        sub :: a

                    else
                        a
                )
                acc
                e
    in
    Array.foldl
        (\maybeNode acc ->
            case maybeNode of
                Just (Mono.MonoDefine e _) ->
                    inExpr e acc

                Just (Mono.MonoTailFunc _ e _) ->
                    inExpr e acc

                _ ->
                    acc
        )
        []
        nodes


{-| The list order of `op` when it is a count loop.
-}
loopOrder : IR.DecoderOp -> Maybe IR.ListOrder
loopOrder op =
    case op of
        IR.LoopDecodeList _ _ _ order _ ->
            Just order

        _ ->
            Nothing


{-| Whether `op` is a count loop.
-}
isCountLoop : IR.DecoderOp -> Bool
isCountLoop op =
    case op of
        IR.LoopDecodeList _ _ _ _ _ ->
            True

        _ ->
            False


{-| Whether `op` is a sentinel-terminated loop.
-}
isSentinelLoop : IR.DecoderOp -> Bool
isSentinelLoop op =
    case op of
        IR.LoopSentinelDecodeList _ _ _ _ _ ->
            True

        _ ->
            False
