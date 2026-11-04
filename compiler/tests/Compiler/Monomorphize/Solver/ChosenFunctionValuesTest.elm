module Compiler.Monomorphize.Solver.ChosenFunctionValuesTest exposing (suite)

{-| Programs from the fourth round of the coverage loop on the solver
monomorphizer and the mono-level optimizations that compile through the whole
default pipeline but break an invariant checked elsewhere, so they are kept out
of the standard catalogue (whose every program each invariant suite runs).

Each program is written as Elm source text and parsed with
`Compiler.Parse.Module.fromByteString`; its imports, including the default ones
the parser adds, are replaced by those of `makeKernelModule`. Each is a module
named `Test` that defines `testValue`. The tests, by label:

  - "top-level function values chosen by if and case": `chooseIf` and
    `chooseCase` are top-level values, not functions, defined by an `if` and a
    `case` whose branches are two-parameter lambdas and whose tests call the
    recursive `sumTo`, so eta expansion leaves them values. It passes
    `expectCoverageRun`.
  - "F14 MONO\_005": the smallest such program, `chooseIf` called as
    `chooseIf 3 4` and also passed to `List.foldl`. The two uses demanded it
    at types differing only in lambda sets, so it got two specs, whose stored
    types then became equal: one (global, type) key had two specialization
    ids. The solver now merges such specs after its settle passes
    (`mergeConvergedSpecs`). It passes `expectSpecRegistryComplete`.
  - "function results drawn from the same parameter along several paths":
    `chooseA`, `chooseB` and `chooseC` return a function parameter from several
    branches, through a local alias and through `identity`, next to a second
    parameter and a lambda; `chooseC` returns a pair from an `if`. It passes
    `expectCoverageRun`.
  - "F15 CGEN\_040": `chooseC n f g = if n > 0 then ( f, g ) else ( g, f )`
    at `Int`, destructured in a `let`. The two alternatives of the `if`'s
    `eco.case` define values of the same names, an `i64` in one and an
    `eco.tuple2<i64, i64>` in the other, which MLIR allows, since a name
    defined in a region is not in scope in its sibling. The checker used to
    gather one type per name for the whole function and so reported the
    `eco.yield` of the first alternative; it now follows region scoping. It
    passes `expectOperandTypeConsistency`.

The group label contains `coverage run`, so that the coverage loop's quick runs
count these tests. The two findings were kept as `expectFailure` cases until
they were fixed (`compiler/coverage/findings.csv`, F14 and F15).

-}

import Compiler.AST.SourceBuilder exposing (makeKernelModule, unitExpr)
import Compiler.BulkCheck exposing (bulkCheck)
import Compiler.IR.Source as Src
import Compiler.Parse.Module as M
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.Generate.CodeGen.OperandTypeConsistency exposing (expectOperandTypeConsistency)
import TestLogic.Generate.MonoGraphIntegrity exposing (expectSpecRegistryComplete)
import TestLogic.TestPipeline exposing (expectCoverageRun)


{-| The group "coverage run: round-4 mono findings", one test per case.
-}
suite : Test
suite =
    Test.describe "coverage run: round-4 mono findings"
        (List.map
            (\tc -> Test.test tc.label <| \_ -> bulkCheck [ tc ])
            [ { label = "top-level function values chosen by if and case", run = \_ -> runSource expectCoverageRun topLevelFunctionValues }
            , { label = "F14 MONO_005", run = \_ -> runSource expectSpecRegistryComplete calledAndPassedValue }
            , { label = "function results drawn from the same parameter along several paths", run = \_ -> runSource expectCoverageRun signatureEdges }
            , { label = "F15 CGEN_040", run = \_ -> runSource expectOperandTypeConsistency tupleFromIf }
            ]
        )


{-| Runs `check` on the program `source` parses to, with its imports replaced
by those of `makeKernelModule`, or fails when it does not parse.
-}
runSource : (Src.Module -> Expectation) -> String -> Expectation
runSource check source =
    case M.fromByteString M.Application source of
        Ok (Src.Module m) ->
            let
                (Src.Module template) =
                    makeKernelModule "unused" unitExpr
            in
            check (Src.Module { m | imports = template.imports })

        Err _ ->
            Expect.fail "fixture failed to parse"


{-| `chooseIf` and `chooseCase`, top-level values defined by an `if` and a
`case` of two-parameter lambdas.
-}
topLevelFunctionValues : String
topLevelFunctionValues =
    """
module Test exposing (..)


sumTo : Int -> Int
sumTo n =
    if n <= 0 then
        0

    else
        n + sumTo (n - 1)


chooseIf : Int -> Int -> Int
chooseIf =
    if sumTo 10 > 20 then
        \\a b -> a * b + a * 3 + b * 5 + (a - b) * (a + b)

    else
        \\a b -> a - b - a * 7 + b * 11 - (a + b) * (a - b)


chooseCase : Int -> Int -> Int
chooseCase =
    case sumTo 2 of
        3 ->
            \\a b -> a * b + 9 + a * 37 + b * 41


        1 ->
            \\a b -> a * b + 1 + a * 13 + b * 17 + (a - b) * (a + b)

        2 ->
            \\a b -> a * b + 2 - a * 19 + b * 23 - (a + b) * (a - b)

        _ ->
            \\a b -> a + b + 3 + a * 29 - b * 31 + (a - b) * (a - b)


testValue : Int
testValue =
    chooseIf 3 4 + chooseCase 5 6 + List.foldl chooseIf 0 [ 1, 2 ]
"""


{-| F14: `chooseIf`, a top-level value defined by an `if` of lambdas,
called and also passed to `List.foldl`.
-}
calledAndPassedValue : String
calledAndPassedValue =
    """
module Test exposing (..)


sumTo : Int -> Int
sumTo n =
    if n <= 0 then
        0

    else
        n + sumTo (n - 1)


chooseIf : Int -> Int -> Int
chooseIf =
    if sumTo 10 > 20 then
        \\a b -> a * b

    else
        \\a b -> a - b


testValue : Int
testValue =
    chooseIf 3 4 + List.foldl chooseIf 0 [ 1, 2 ]
"""


{-| `chooseA`, `chooseB` and `chooseC`, whose results are function parameters
reached along several paths.
-}
signatureEdges : String
signatureEdges =
    """
module Test exposing (..)


chooseA : Int -> (Int -> Int) -> (Int -> Int) -> (Int -> Int)
chooseA n f g =
    if n > 10 then
        f

    else if n > 5 then
        g

    else if n > 2 then
        f

    else
        let
            h =
                f
        in
        h


chooseB : Int -> (Int -> Int) -> (Int -> Int)
chooseB n f =
    case n of
        0 ->
            f

        1 ->
            identity f

        2 ->
            (let
                k =
                    f
             in
             k
            )

        _ ->
            \\x -> f x + 1


chooseC : Int -> (Int -> Int) -> (Int -> Int) -> ( Int -> Int, Int -> Int )
chooseC n f g =
    if n > 0 then
        ( f, g )

    else
        ( g, f )


testValue : Int
testValue =
    let
        ( p, q ) =
            chooseC 1 (\\x -> x + 1) (\\x -> x * 2)
    in
    chooseA 3 (\\x -> x + 1) (\\x -> x - 1) 4 + chooseA 12 negate abs 5 + chooseB 2 (\\x -> x * 3) 6 + chooseB 1 (chooseA 7 p q) 7 + p 1 + q 2
"""


{-| F15: a pair of `Int`s returned from an `if` and destructured.
-}
tupleFromIf : String
tupleFromIf =
    """
module Test exposing (..)


chooseC : Int -> Int -> Int -> ( Int, Int )
chooseC n f g =
    if n > 0 then
        ( f, g )

    else
        ( g, f )


testValue : Int
testValue =
    let
        ( p, q ) =
            chooseC 1 3 4
    in
    p + q
"""
