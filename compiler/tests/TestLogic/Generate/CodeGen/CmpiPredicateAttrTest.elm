module TestLogic.Generate.CodeGen.CmpiPredicateAttrTest exposing (suite)

{-| Runs the `arith.cmpi` predicate check on two programs that `case` on a
`Char`, so that a character comparison emitted without a valid `predicate`
attribute is caught.

An `arith.cmpi` compares two integers, and its `predicate` attribute names the
comparison. The checks are in `TestLogic.Generate.CodeGen.CmpiPredicateAttr`:
every `arith.cmpi` in the generated MLIR must carry an integer `predicate` in
MLIR's range 0 to 9.

In code generation, a `case` with one character literal and a catch-all branch
becomes a single test that compares the character with an `arith.cmpi`. A
`case` with several character literals and a catch-all branch becomes a
fan-out: one `eco.case` on the character with `case_kind` `"chr"`, with no
`arith.cmpi` for its literals.

Each fixture is a module named `Test`, holding an annotated function that
matches its `Char` argument against character literals, and a `testValue` that
calls it with one of those literals.

The tests:

  - "Simple char case emits arith.cmpi with predicate" checks `classify`,
    which matches `'a'` and otherwise a catch-all, with
    `expectCmpiPresentWithPredicate`: at least one `arith.cmpi` must be
    generated, and every one must have a valid predicate.
  - "Multi-branch char case compiles to a chr eco.case" checks
    `describeChar`, which matches `','`, `'{'` and `'}'` and otherwise a
    catch-all: the MLIR must hold an `eco.case` with `case_kind` `"chr"`, and
    any `arith.cmpi` must have a valid predicate.

Among what is not tested: whether the predicate is the right comparison, and
character comparisons outside a `case`.

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
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.Generate.CodeGen.CmpiPredicateAttr exposing (expectCmpiPredicateAttr, expectCmpiPresentWithPredicate)
import TestLogic.Generate.CodeGen.Invariants exposing (findOpsNamed, getStringAttr)
import TestLogic.TestPipeline exposing (runToMlir)


{-| The two tests the module docstring describes.
-}
suite : Test
suite =
    Test.describe "arith.cmpi predicate attribute"
        [ Test.test "Simple char case emits arith.cmpi with predicate" <|
            simpleCharCaseTest expectCmpiPresentWithPredicate
        , Test.test "Multi-branch char case compiles to a chr eco.case" <|
            multiBranchCharCaseTest (\m -> Expect.all [ expectChrCase, expectCmpiPredicateAttr ] m)
        ]


{-| Passes when `srcModule` compiles to MLIR holding an `eco.case` whose
`case_kind` is `"chr"`.
-}
expectChrCase : Src.Module -> Expectation
expectChrCase srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            findOpsNamed "eco.case" mlirModule
                |> List.any (\op -> getStringAttr "case_kind" op == Just "chr")
                |> Expect.equal True
                |> Expect.onFail "Expected an eco.case with case_kind \"chr\""


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
