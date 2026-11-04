module SourceIR.TailLoopMutualRecCases exposing (expectSuite)

{-| A tail-recursive function whose recursive branch defines two mutually
recursive local functions, so that the typed optimizer
(`Compiler.LocalOpt.Typed.Expression`) lowers a recursive `let` group of more
than one definition in tail position, and the MLIR back end's tail loop must
generate the two closures together (finding F5, fixed). It comes from the
former unit test `Compiler.LocalOpt.Typed.TailLoopMutualRecCoverageTest`,
whose checks, `TestLogic.Generate.CodeGen.LetRecSsaDefinedness` and
`TestLogic.Generate.CodeGen.SafepointRegionScoping`, already ran over the
catalogue. Before F5 was fixed the loop's step generated `isEven` and `isOdd`
one at a time, so the first closure captured an SSA value that was defined
nowhere; the step now generates the two together
(`Compiler.GenerateMlir.TailRec` `compileLetStep`, through
`Expr.splitMutualRecGroup`).

This module asserts nothing itself. `expectSuite` hands each program to the
caller's expectation, which decides what the program is run through and what
counts as passing.

The program is the source text of a module named `Test`, parsed as an
application module, with the default imports of modules that
`Compiler.Elm.Interface.Basic.testIfaces` lacks dropped. The case, by label:

  - "Mutual recursion inside a tail loop": `loop : Int -> Int -> Int` returns
    its accumulator when its counter reaches zero, and otherwise defines
    `isEven` and `isOdd`, each calling the other, and calls itself with an
    accumulator that depends on `isEven n`. `testValue = loop 4 0`.

-}

import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.Core.Annotation as A
import Compiler.Elm.Interface.Basic as Basic
import Compiler.IR.Source as Src
import Compiler.Parse.Module as Parse
import Dict
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Tail loop mutual recursion programs " followed by `condStr`, that
passes `expectFn` each program in order through
`Compiler.BulkCheck.bulkCheck`, so the first failing program ends the test and
is the one reported.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Tail loop mutual recursion programs " ++ condStr) <|
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
    [ ( "Mutual recursion inside a tail loop"
      , """module Test exposing (..)

loop : Int -> Int -> Int
loop n acc =
    if n <= 0 then
        acc

    else
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
        loop (n - 1)
            (if isEven n then
                acc + 1

             else
                acc
            )


testValue : Int
testValue =
    loop 4 0
"""
      )
    ]
