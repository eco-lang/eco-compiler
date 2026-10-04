module TestLogic.Generate.CodeGen.CmpiPredicateAttrTest exposing (suite)

{-| Runs the `arith.cmpi` predicate check on two programs that `case` on a
`Char`, so that a character comparison emitted without its `predicate`
attribute is caught.

An `arith.cmpi` compares two integers, and its `predicate` attribute names the
comparison. The check is `expectCmpiPredicateAttr`, and its module's docstring
says what it requires: compilation must succeed, and every `arith.cmpi` in the
generated MLIR must carry an integer `predicate`. A program that produces no
`arith.cmpi` passes.

In code generation, a `case` with one character literal and a catch-all branch
becomes a single test that compares the character with an `arith.cmpi`. A
`case` with several character literals and a catch-all branch becomes a
fan-out: one `eco.case` on the character, with no `arith.cmpi` for its
literals.

Each fixture is a module named `Test`, holding an annotated function that
matches its `Char` argument against character literals, and a `testValue` that
calls it with one of those literals.

The one test runs two cases through `bulkCheck`, in order, and reports only the
first that fails:

  - "Simple char case" checks `classify`, which matches `'a'` and otherwise a
    catch-all variable pattern named `_` (built with `pVar "_"`).
  - "Multi-branch char case" checks `describeChar`, which matches `','`, `'{'`
    and `'}'` and otherwise a catch-all variable pattern named `_` (built with
    `pVar "_"`). Its literals compile to an `eco.case` with no `arith.cmpi`, so
    this case fails only if compilation fails or another `arith.cmpi` lacks a
    predicate.

Among what is not tested: the value of a predicate, character comparisons
outside a `case`, and whether either program produces an `arith.cmpi` at all.

-}

import Compiler.AST.Source as Src
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
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.Generate.CodeGen.CmpiPredicateAttr exposing (expectCmpiPredicateAttr)


{-| The one test, which runs both cases with `expectCmpiPredicateAttr`.
-}
suite : Test
suite =
    Test.describe "arith.cmpi predicate attribute"
        [ Test.test "Char case expression emits arith.cmpi with predicate" <|
            \_ -> bulkCheck (testCases expectCmpiPredicateAttr)
        ]


{-| Returns the two cases, each of which builds its program and hands it to
`expectFn`.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Simple char case", run = simpleCharCaseTest expectFn }
    , { label = "Multi-branch char case", run = multiBranchCharCaseTest expectFn }
    ]


{-| Applies `expectFn` to a module holding one character literal branch and a
catch-all branch binding a variable named `_` (built with `pVar "_"`, shown as
`_` below):

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
simpleCharCaseTest : (Src.Module -> Expectation) -> (() -> Expectation)
simpleCharCaseTest expectFn _ =
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

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ classifyDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a module holding three character literal branches and
a catch-all branch binding a variable named `_` (built with `pVar "_"`, shown
as `_` below):

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
multiBranchCharCaseTest : (Src.Module -> Expectation) -> (() -> Expectation)
multiBranchCharCaseTest expectFn _ =
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

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ describeCharDef, testValueDef ]
                []
                []
    in
    expectFn modul
