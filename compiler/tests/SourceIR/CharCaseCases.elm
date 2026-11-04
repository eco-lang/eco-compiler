module SourceIR.CharCaseCases exposing
    ( expectSuite
    , multiBranchCharCase
    , simpleCharCase
    )

{-| Programs that `case` on a `Char`, so that code generation emits character
comparisons both ways: a `case` with one character literal and a catch-all
branch becomes a single test that compares the character with an
`arith.cmpi`, and a `case` with several character literals and a catch-all
branch becomes a fan-out, one `eco.case` on the character with `case_kind`
`"chr"`. They come from the former inline programs of
`Compiler.GenerateMlir.CmpiPredicateAttrTest`, whose check, that every
`arith.cmpi` carries a valid `predicate`, now runs over the whole catalogue as
`TestLogic.Generate.CodeGen.CmpiPredicateAttrTest`; that unit test keeps what
it pins for each program, and so imports the programs by name.

`expectSuite` asserts nothing itself: it hands each program to the caller's
expectation, which decides what the program is run through and what counts as
passing.

Each program is a module named `Test`, built with
`Compiler.AST.SourceBuilder.makeModuleWithTypedDefsUnionsAliases`, holding an
annotated function that matches its `Char` argument against character literals
and a catch-all branch binding a variable named `_` (built with `pVar "_"`),
and a `testValue` that calls it with one of those literals:

  - `simpleCharCase`: `classify : Char -> Int` matches `'a'` and otherwise the
    catch-all; `testValue = classify 'a'`.
  - `multiBranchCharCase`: `describeChar : Char -> String` matches `','`,
    `'{'` and `'}'` and otherwise the catch-all; `testValue = describeChar ','`.

-}

import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , callExpr
        , caseExpr
        , chrExpr
        , intExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pChr
        , pVar
        , strExpr
        , tLambda
        , tType
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Char case programs " followed by `condStr`, that
passes `expectFn` each program in order through `Compiler.BulkCheck.bulkCheck`,
so the first failing program ends the test and is the one reported.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Char case programs " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns one case per program, each running `expectFn` on it.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.map (\( label, modul ) -> { label = label, run = \_ -> expectFn modul })
        [ ( "single char literal and a catch-all", simpleCharCase )
        , ( "several char literals and a catch-all", multiBranchCharCase )
        ]


{-| One character literal branch and a catch-all:

    classify : Char -> Int
    classify c =
        case c of
            'a' ->
                1

            _ ->
                0

    testValue : Int
    testValue =
        classify 'a'

-}
simpleCharCase : Src.Module
simpleCharCase =
    let
        classifyDef : TypedDef
        classifyDef =
            { name = "classify"
            , args = [ pVar "c" ]
            , tipe = tLambda (tType "Char" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "c")
                    [ ( pChr "a", intExpr 1 )
                    , ( pVar "_", intExpr 0 )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "classify") [ chrExpr "a" ]
            }
    in
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ classifyDef, testValueDef ]
        []
        []


{-| Three character literal branches and a catch-all:

    describeChar : Char -> String
    describeChar c =
        case c of
            ',' ->
                "comma"

            '{' ->
                "open brace"

            '}' ->
                "close brace"

            _ ->
                "other"

    testValue : String
    testValue =
        describeChar ','

-}
multiBranchCharCase : Src.Module
multiBranchCharCase =
    let
        describeCharDef : TypedDef
        describeCharDef =
            { name = "describeChar"
            , args = [ pVar "c" ]
            , tipe = tLambda (tType "Char" []) (tType "String" [])
            , body =
                caseExpr (varExpr "c")
                    [ ( pChr ",", strExpr "comma" )
                    , ( pChr "{", strExpr "open brace" )
                    , ( pChr "}", strExpr "close brace" )
                    , ( pVar "_", strExpr "other" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body = callExpr (varExpr "describeChar") [ chrExpr "," ]
            }
    in
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ describeCharDef, testValueDef ]
        []
        []
