module SourceIR.CovGenerateMlirCases exposing (expectSuite)

{-| Programs written so that the MLIR back end (`Compiler.GenerateMlir.*`)
meets forms the rest of the catalogue does not give it: top-level constants
that the constant-thunk folding (`Compiler.GenerateMlir.ConstThunks`) admits
or refuses, and a `case` on `Char` literals spelled with escapes
(`Compiler.GenerateMlir.Patterns`).

These cases assert nothing themselves. Each one parses a program from source
text and hands it to the expectation function the caller supplies, so what is
checked, and at which stage, is decided by that function.

The programs are parsed as modules of elm/core (`Parse.Package Pkg.core`), so
they get no default imports; every import is written out in `header`. They
compile against the mock interfaces of
`Compiler.Elm.Interface.Basic.testIfaces`. Each defines `testValue`.

The cases, by label:

  - "Constant thunks of every intrinsic class": top-level constants built from
    `sqrt`, `negate`, `not`, `&&`, `||`, comparisons and `toFloat`, one whose
    body is an `if`, and one defined as a function.
  - "Case on escaped Char literals": a `case` on a `Char` with the patterns
    `'\r'`, `'\t'`, `'\n'`, `'\''`, `\u{...}` escapes with lowercase and
    uppercase hex digits, and an astral `\u{...}` escape.

-}

import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.Elm.Package as Pkg
import Compiler.IR.Source as Src
import Compiler.Parse.Module as Parse
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Generate MLIR coverage " followed by `condStr`,
that passes when `expectFn` passes on every case's program and otherwise fails
with the label of the first case whose program it fails on.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Generate MLIR coverage " ++ condStr) <|
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

"""


{-| The programs, by label, as the source that follows `header`.
-}
programs : List ( String, String )
programs =
    [ ( "Constant thunks of every intrinsic class"
      , """
root2 : Float
root2 =
    sqrt 2.0


negRoot : Float
negRoot =
    negate (sqrt 3.0)


notLess : Bool
notLess =
    not (1 < 2)


both : Bool
both =
    (1 < 2) && (3 > 2)


either : Bool
either =
    (1.5 < 2.5) || ('a' < 'b')


asFloat : Float
asFloat =
    toFloat 3 * 2.5


chosen : Int
chosen =
    if List.length [ 1 ] > 0 then
        1

    else
        2


fn : Int -> Int
fn =
    negate



testValue k =
    ( ( root2, negRoot, notLess )
    , ( both, either, asFloat )
    , ( chosen, fn k, fn )
    )
"""
      )
    , ( "Case on escaped Char literals"
      , """
testValue c =
    case c of
        '\\r' ->
            1

        '\\t' ->
            2

        '\\n' ->
            3

        '\\'' ->
            4

        '\\u{00e9}' ->
            5

        '\\u{1F600}' ->
            6

        '\\u{00C9}' ->
            7

        _ ->
            0
"""
      )
    ]
