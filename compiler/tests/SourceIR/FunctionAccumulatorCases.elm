module SourceIR.FunctionAccumulatorCases exposing (expectSuite)

{-| Two recursive functions whose result is a function and which are called
with one argument more than they have parameters (finding F6, fixed). Both are
tail functions whose body is a `case` with a tail call in one branch. Global
optimization used to read the stages of their result from the body's type and
stamp the call `remainingStageArities [1]`, through a join whose branches are
staged `[Nothing, Nothing]`, breaking GOPT\_003; it now reads the body as code
(`Compiler.MonoOpt.GlobalOptimize.closureBodyStageArities`) and claims no later
stages. They come from the former unit test
`Compiler.MonoOpt.FunctionAccumulatorCoverageTest`, whose check,
`TestLogic.Monomorphize.MonoCaseBranchResultType.expectHonestJoinStaging`,
already ran over the catalogue.

This module asserts nothing itself. `expectSuite` hands each program to the
caller's expectation, which decides what the program is run through and what
counts as passing.

Each program is the source text of a module named `Test`, parsed as an
application module, with the default imports of modules that
`Compiler.Elm.Interface.Basic.testIfaces` lacks dropped. The cases, by label:

  - "Closure accumulator": `compose fs acc` walks a list of `Int -> Int`
    functions, returning `acc` at the end of the list and otherwise calling
    itself with the rest and the closure `\x -> f (acc x)`. `testValue`
    composes three functions and applies the result to `2`.
  - "Function lookup": `lookup k entries` walks a list of pairs of a key and
    an `Int -> Int` function, returning the function of the first matching
    key, or `identity` at the end of the list. `testValue` applies the
    functions it finds to numbers.

-}

import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.Core.Annotation as A
import Compiler.Elm.Interface.Basic as Basic
import Compiler.IR.Source as Src
import Compiler.Parse.Module as Parse
import Dict
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Function accumulator programs " followed by `condStr`, that
passes `expectFn` each program in order through
`Compiler.BulkCheck.bulkCheck`, so the first failing program ends the test and
is the one reported.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Function accumulator programs " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns one case per program, each running `expectFn` on it.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.map (\( label, text ) -> { label = label, run = \_ -> runSource expectFn text }) programs


{-| Runs `expectFn` on the module parsed from `text` as an application module,
with the imports of modules the mock interfaces lack dropped, or fails when
`text` does not parse.
-}
runSource : (Src.Module -> Expectation) -> String -> Expectation
runSource expectFn text =
    case Parse.fromByteString Parse.Application text of
        Ok (Src.Module m) ->
            expectFn (Src.Module { m | imports = List.filter isMockImport m.imports })

        Err _ ->
            Expect.fail ("fixture does not parse:\n" ++ text)


{-| Whether an import names one of the mock interfaces.
-}
isMockImport : Src.Import -> Bool
isMockImport (Src.Import ( _, A.At _ name ) _ _) =
    Dict.member name Basic.testIfaces


{-| The programs, by label, as source text.
-}
programs : List ( String, String )
programs =
    [ ( "Closure accumulator"
      , """module Test exposing (..)


compose : List (Int -> Int) -> (Int -> Int) -> (Int -> Int)
compose fs acc =
    case fs of
        [] ->
            acc

        f :: rest ->
            compose rest (\\x -> f (acc x))


testValue : Int
testValue =
    compose [ \\x -> x + 1, \\x -> x * 3, identity ] identity 2
"""
      )
    , ( "Function lookup"
      , """module Test exposing (..)


table : List ( Int, Int -> Int )
table =
    [ ( 1, \\x -> x + 1 ), ( 2, \\x -> x * 2 ), ( 3, max 4 ) ]


lookup : Int -> List ( Int, Int -> Int ) -> (Int -> Int)
lookup k entries =
    case entries of
        [] ->
            identity

        ( key, f ) :: rest ->
            if key == k then
                f

            else
                lookup k rest


testValue : Int
testValue =
    lookup 2 table 5 + lookup 9 table 1 + lookup 3 table 0
"""
      )
    ]
