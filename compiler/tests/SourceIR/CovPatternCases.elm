module SourceIR.CovPatternCases exposing (expectSuite)

{-| Programs written so that the MLIR back end's pattern compilation
(`Compiler.GenerateMlir.Patterns`) meets parameters of tuple and
single-constructor types, which the back end may split into slots, matched by
`case` expressions.

These cases assert nothing themselves. Each one parses a program from source
text and hands it to the expectation function the caller supplies, so what is
checked, and at which stage, is decided by that function.

The programs are parsed as modules of elm/core (`Parse.Package Pkg.core`), so
they get no default imports and may name `Elm.Kernel.*` functions; every
import is written out in `header`. They compile against the mock interfaces of
`Compiler.Elm.Interface.Basic.testIfaces`. Each defines `testValue`.

The cases, by label:

  - "Split tuple and constructor parameters matched by case": functions whose
    triple, pair and single-constructor parameters are only matched by a `case`
    or a `let` destructuring, called with fresh values.

-}

import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.Elm.Package as Pkg
import Compiler.IR.Source as Src
import Compiler.Parse.Module as Parse
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Pattern codegen coverage " followed by `condStr`, that passes
when `expectFn` passes on every case's program and otherwise fails with the
label of the first case whose program it fails on.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Pattern codegen coverage " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case of `programs`, in order.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.map
        (\( label, body ) -> { label = label, run = \_ -> runSource expectFn body })
        programs


{-| Runs `expectFn` on the module parsed from `header` followed by `body`, or
fails when that source does not parse.
-}
runSource : (Src.Module -> Expectation) -> String -> Expectation
runSource expectFn body =
    case Parse.fromByteString (Parse.Package Pkg.core) (header ++ body) of
        Ok modul ->
            expectFn modul

        Err _ ->
            Expect.fail ("fixture does not parse:\n" ++ body)


{-| The module header shared by the programs: module `Test` and the imports
they use, all written out because an elm/core module gets no default imports.
-}
header : String
header =
    """module Test exposing (..)

import Basics exposing (..)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Tuple
import Char exposing (Char)

"""


{-| The programs, by label, as the source that follows `header`.
-}
programs : List ( String, String )
programs =
    [ ( "Split tuple and constructor parameters matched by case"
      , """
type P
    = P Int Float Int


type Q
    = Q Bool Int


f3 : ( Int, Float, Int ) -> Int
f3 t =
    case t of
        ( a, b, c ) ->
            a + c + round b


f2 : ( Int, Int ) -> Int
f2 t =
    case t of
        ( 0, b ) ->
            b

        ( a, b ) ->
            a * b


g : P -> Int
g p =
    case p of
        P a b c ->
            a + c + round b


h : Q -> Int
h q =
    case q of
        Q True n ->
            n

        Q False n ->
            -n


testValue k =
    ( ( f3 ( k, 1.5, 2 ), f2 ( k, 3 ) ), ( g (P k 2.5 3), h (Q (k > 1) k) ) )
"""
      )
    ]
