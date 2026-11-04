module Compiler.Monomorphize.Solver.EngineSpecWatchdogTest exposing (suite)

{-| Monomorphization paths reached only by a program the build rejects: the
spec watchdogs of the solver engine tripping more than once in one work item.

The program is `testValue = count 1 + count "s" + count 1.5`, with
`count : a -> Int`. Under a breadth limit of 1 (`Config.SpecLimits` with
`specBreadth = 1` and the type-node check off), translating `testValue`
creates three `count` specs: the second trips the breadth watchdog, and the
third trips it again while the first trip is still pending.

The program is written as Elm source text, parsed with
`Compiler.Parse.Module.fromByteString`, with its imports replaced by those of
`makeKernelModule`.

The test establishes that the solver engine, with `Config.defaultLss`, fails
with a message containing "specialization budget exceeded". Its group label
contains `coverage run`, so that the coverage loop's quick runs count it.

The polymorphic-recursion programs this module also held (finding F7, and the
growth through a pair, a record, a `Maybe` and a function, finding F13) are
now cases of `SourceIR.MonoFailsCases`, which
`TestLogic.Reporting.ExpectedRejectionTest` checks are rejected with a report
naming polymorphic recursion; its control, finite polymorphism that must
compile, is a program of `SourceIR.RejectionControlCases`. This test stays a
unit test because it needs a breadth limit of 1, which no catalogue run sets.

-}

import Compiler.AST.SourceBuilder exposing (makeKernelModule, unitExpr)
import Compiler.Config as Config
import Compiler.IR.Source as Src
import Compiler.Parse.Module as M
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The test, in a group labelled "coverage run: spec watchdogs".
-}
suite : Test
suite =
    Test.describe "coverage run: spec watchdogs"
        [ Test.test "two breadth trips in one work item" <|
            \_ ->
                case parse threeInstances of
                    Err msg ->
                        Expect.fail msg

                    Ok modul ->
                        case Pipeline.runSolverMonoWithLimits { specTypeNodes = 0, specBreadth = 1 } Config.defaultLss modul of
                            Ok _ ->
                                Expect.fail "expected the breadth watchdog to trip"

                            Err msg ->
                                if String.contains "specialization budget exceeded" msg then
                                    Expect.pass

                                else
                                    Expect.fail ("unexpected failure: " ++ msg)
        ]


{-| Parses `source`, replacing its imports with those of `makeKernelModule`.
-}
parse : String -> Result String Src.Module
parse source =
    case M.fromByteString M.Application source of
        Ok (Src.Module m) ->
            let
                (Src.Module template) =
                    makeKernelModule "unused" unitExpr
            in
            Ok (Src.Module { m | imports = template.imports })

        Err _ ->
            Err "fixture failed to parse"


{-| `count` used at three types in one body.
-}
threeInstances : String
threeInstances =
    """
module Test exposing (..)


count : a -> Int
count _ =
    1


testValue : Int
testValue =
    count 1 + count "s" + count 1.5
"""
