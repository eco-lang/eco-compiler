module SourceIR.MainFailsCases exposing (expectRejectedSuite, expectSuite)

{-| Programs whose `main` the typed optimizer must reject, each with the report
it must be rejected with: the `main` module of the negative catalogue
(`SourceIR.Suite.RejectedSuites`), from the former
`Compiler.Reporting.Render.TypePrintingCoverageTest`.

A program's `main` must be a plain value, not part of a cycle of definitions,
and its type a virtual DOM node or a `Platform.Program`; the typed optimizer
(`Compiler.LocalOpt.Typed.Module`) checks it and reports `BAD MAIN TYPE` or
`BAD MAIN` (`Compiler.LocalOpt.Error`). Each program here defines its own
`main`, so the test pipeline adds none.

`expectRejectedSuite` gives a check each program with its
`SourceIR.Suite.Rejection.Rejection`; `TestLogic.Reporting.ExpectedRejectionTest`
checks that typed optimization, and no earlier stage, rejects each program with
that report. `expectSuite` gives a check only the programs.

Each program is written as source text. The cases, by group:

  - "Bad main types": a `main` of each kind of type the optimizer rejects,
    `BAD MAIN TYPE` with the type printed by
    `Compiler.Reporting.Render.Type.canToDoc` as the fragment: `Int`, a
    function of two arguments, a list of a type variable, a record holding a
    triple, a function from an extensible record, unit, a nested `Maybe`, a
    function whose argument is a function, a custom type of three arguments,
    and a record alias.
  - "Recursive mains": a `main` in a cycle with another function, annotated and
    not, `BAD MAIN` with the cycle.

Among what is not tested: `BAD FLAGS`, since the mock interfaces have no
`Platform.Program`.

-}

import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import SourceIR.Suite.Rejection
    exposing
        ( RejectedCase
        , Rejection
        , expectRejectedSuiteOf
        , expectSuiteOf
        , fromSource
        , rejectedWithFragment
        )
import Test exposing (Test)


{-| Creates a group of tests, named "Main failure tests " followed by
`condStr`, with one test per group of cases (see `groups`). Each test applies
`expectFn` to the program of every case of its group in order, under
`Compiler.BulkCheck.bulkCheck`, so it passes only if every case passes, and a
failure names only the first failing case.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Main failure tests " ++ condStr)
        (List.map (\( name, cases ) -> expectSuiteOf (name ++ " " ++ condStr) cases expectFn) groups)


{-| `expectSuite`, giving `expectFn` the `Rejection` each case records as well.
-}
expectRejectedSuite : (Src.Module -> Rejection -> Expectation) -> String -> Test
expectRejectedSuite expectFn condStr =
    Test.describe ("Main failure tests " ++ condStr)
        (List.map (\( name, cases ) -> expectRejectedSuiteOf (name ++ " " ++ condStr) cases expectFn) groups)


{-| Every case in this module, by group, each group under the name its test
gets.
-}
groups : List ( String, List RejectedCase )
groups =
    [ ( "Bad main types", typeCases )
    , ( "Recursive mains", cycleCases )
    ]


{-| A `main` of each kind of type the typed optimizer rejects. The fragment is
the type as the report prints it (`Compiler.Reporting.Render.Type.canToDoc`).
-}
typeCases : List RejectedCase
typeCases =
    [ fromSource "Int main" (badMainType "Int") "main : Int\nmain = 1\n"
    , fromSource "function main" (badMainType "Int -> Int -> Int") "main : Int -> Int -> Int\nmain a b = a\n"
    , fromSource "type variable main" (badMainType "List a") "main = []\n"
    , fromSource "record main" (badMainType "{ a : Int, b : ( Int, Int, Int ) }") "main : { a : Int, b : ( Int, Int, Int ) }\nmain = { a = 1, b = ( 1, 2, 3 ) }\n"
    , fromSource "extensible record main" (badMainType "{ r | a : Int } -> Int") "main : { r | a : Int } -> Int\nmain r = r.a\n"
    , fromSource "unit main" (badMainType "()") "main : ()\nmain = ()\n"
    , fromSource "one-argument type main" (badMainType "Maybe (Maybe Int)") "main : Maybe (Maybe Int)\nmain = Nothing\n"
    , fromSource "function argument main" (badMainType "(Int -> Int) -> Int") "main : (Int -> Int) -> Int\nmain f = f 1\n"
    , fromSource "three-argument type main" (badMainType "T Int Int Int") "type T a b c = T a b c\n\nmain : T Int Int Int\nmain = T 1 2 3\n"
    , fromSource "alias main" (badMainType "M") "type alias M = { a : Int }\n\nmain : M\nmain = { a = 1 }\n"
    ]


{-| The rejection of a `main` of the type printed as `typeText`: a `BAD MAIN
TYPE` report quoting the type where it says what type it sees.
-}
badMainType : String -> Rejection
badMainType typeText =
    rejectedWithFragment "BAD MAIN TYPE" ("The type of `main` value I am seeing is: " ++ typeText ++ " I only know how to handle")


{-| A `main` in a cycle of definitions, annotated and not.
-}
cycleCases : List RejectedCase
cycleCases =
    [ fromSource "recursive main" (rejectedWithFragment "BAD MAIN" "it is involved in this cycle of definitions") "main : Int -> Int\nmain x = f x\n\nf : Int -> Int\nf x = main x\n"
    , fromSource "recursive unannotated main" (rejectedWithFragment "BAD MAIN" "it is involved in this cycle of definitions") "main x = f x\n\nf x = main x\n"
    ]
