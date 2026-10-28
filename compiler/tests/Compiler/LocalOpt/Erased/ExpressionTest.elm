module Compiler.LocalOpt.Erased.ExpressionTest exposing (suite)

{-| Regression test for a bug in
`Compiler.LocalOpt.Erased.Expression.optimizeTail` (S2 list,
LocalOpt/Erased/Expression.elm lines 672 and 709-710).

Fixed 2026-10-28 (plans/review-bug-triage-fixes.md, item 3.8); the text
below describes the old behaviour.

In `optimizeTail`, the `Can.LetRec` arm with two or more (mutually recursive)
definitions folds the definitions around `optimize cycle body` instead of
`optimizeTail cycle rootName argNames body`. A self call of the enclosing
function in tail position inside that `let` body therefore comes out as an
ordinary `Call`, not a `TailCall`, and stack use grows with recursion depth.
The single-definition arm and the typed twin
(`Compiler.LocalOpt.Typed.Expression`) keep tail position.

The check: the erased-optimized node of `count` (below) contains a
`TailCall`. A control case with a single-definition `let` does already.

-}

import Compiler.AST.Optimized as Opt
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder exposing (makeModule, unitExpr)
import Compiler.LocalOpt.Erased.Module as ErasedOptimize
import Compiler.Parse.Module as M
import Compiler.Reporting.Result as RResult
import Data.Map
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "Regression: erased optimizeTail keeps tail position inside a multi-definition let rec"
        [ Test.test "control: single-definition let keeps the self tail call" <|
            \_ ->
                expectTailCall singleSource
        , Test.test "mutually recursive let: the self call in its body is a TailCall" <|
            \_ ->
                expectTailCall mutualSource
        ]


singleSource : String
singleSource =
    """module Test exposing (..)


count : Int -> Int
count n =
    let
        go k =
            if k == 0 then
                0

            else
                go (k - 1)
    in
    if n <= 0 then
        go n

    else
        count (n - 1)
"""


mutualSource : String
mutualSource =
    """module Test exposing (..)


count : Int -> Int
count n =
    let
        isEven k =
            if k == 0 then
                True

            else
                isOdd (k - 1)

        isOdd k =
            if k == 0 then
                False

            else
                isEven (k - 1)
    in
    if isEven n then
        0

    else
        count (n - 1)
"""


parse : String -> Result String Src.Module
parse source =
    case M.fromByteString M.Application source of
        Ok (Src.Module m) ->
            let
                (Src.Module template) =
                    makeModule "unused" unitExpr
            in
            Ok (Src.Module { m | imports = template.imports })

        Err _ ->
            Err "fixture failed to parse"


expectTailCall : String -> Expect.Expectation
expectTailCall source =
    case parse source |> Result.andThen Pipeline.runToTypeCheck of
        Err msg ->
            Expect.fail msg

        Ok { canonical, annotations } ->
            case RResult.run (ErasedOptimize.optimize annotations canonical) of
                ( _, Err _ ) ->
                    Expect.fail "erased optimization failed"

                ( _, Ok (Opt.LocalGraph _ nodes _) ) ->
                    let
                        rendered =
                            Data.Map.foldl (\_ node acc -> Debug.toString node :: acc) [] nodes
                                |> List.filter (String.contains "count")
                                |> String.join "\n"
                    in
                    if String.contains "TailCall" rendered then
                        Expect.pass

                    else
                        Expect.fail ("no TailCall in the optimized `count`:\n" ++ rendered)
